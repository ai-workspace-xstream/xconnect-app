package usecase

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"time"

	"go_core/overlay/controlplane"
	"go_core/overlay/fault"
	"go_core/overlay/model"
	"go_core/overlay/runtime"
	"go_core/overlay/state"
)

type ControlPlane interface {
	RegisterDevice(context.Context, controlplane.RegisterDeviceRequest) (controlplane.RegisterDeviceResponse, error)
	GetConfig(context.Context, controlplane.ConfigRequest) (model.Config, error)
	AckConfig(context.Context, controlplane.ConfigAckRequest) (controlplane.ConfigAckResponse, error)
}

type KeyGenerator func() (privateKey string, publicKey string, err error)

type Joiner struct {
	controlPlane ControlPlane
	store        *state.Store
	runtime      runtime.Interface
	now          func() time.Time
	generateKey  KeyGenerator
}

type JoinRequest struct {
	Server     string
	DeviceID   string
	DeviceName string
	Platform   string
	Hostname   string
	NetworkID  string
	NodeID     string
}

type JoinResult struct {
	DeviceID      string `json:"device_id"`
	NetworkID     string `json:"network_id"`
	Revision      string `json:"revision"`
	AlreadyJoined bool   `json:"already_joined"`
}

func NewJoiner(controlPlane ControlPlane, store *state.Store, tunnelRuntime runtime.Interface) *Joiner {
	return &Joiner{
		controlPlane: controlPlane,
		store:        store,
		runtime:      tunnelRuntime,
		now:          time.Now,
		generateKey:  generateWireGuardKeyPair,
	}
}

func (j *Joiner) WithClock(now func() time.Time) *Joiner {
	j.now = now
	return j
}

func (j *Joiner) WithKeyGenerator(generator KeyGenerator) *Joiner {
	j.generateKey = generator
	return j
}

func (j *Joiner) Join(ctx context.Context, request JoinRequest) (JoinResult, error) {
	request.Server = strings.TrimRight(strings.TrimSpace(request.Server), "/")
	request.DeviceID = strings.TrimSpace(request.DeviceID)
	if request.Server == "" || request.DeviceID == "" {
		return JoinResult{}, fault.New(fault.CodeInvalidInput, "join overlay", nil)
	}

	if lastKnown, err := j.store.LoadLastKnown(); err == nil {
		if lastKnown.Server == request.Server && lastKnown.DeviceID == request.DeviceID && lastKnown.Phase == state.PhaseAcknowledged {
			if requestedNetwork := strings.TrimSpace(request.NetworkID); requestedNetwork != "" && requestedNetwork != lastKnown.NetworkID {
				return JoinResult{}, fault.New(fault.CodeStateConflict, "join existing device", nil)
			}
			if requestedNode := strings.TrimSpace(request.NodeID); requestedNode != "" && requestedNode != lastKnown.NodeID {
				return JoinResult{}, fault.New(fault.CodeStateConflict, "join existing device", nil)
			}
			runtimeStatus, statusErr := j.runtime.Status(ctx)
			if statusErr != nil {
				return JoinResult{}, fault.New(fault.CodeRuntimeStatusFailed, "read existing runtime status", statusErr)
			}
			if !runtimeStatus.Applied || runtimeStatus.Revision != lastKnown.Config.Revision || runtimeStatus.CoreID != model.CoreIDXray || !model.SupportedAdapterID(runtimeStatus.AdapterID) {
				applyResult, applyErr := j.runtime.Apply(ctx, runtime.ApplyRequest{
					Config:              lastKnown.Config,
					WireGuardPrivateKey: lastKnown.WireGuardPrivateKey,
				})
				if applyErr == nil && (applyResult.Revision != lastKnown.Config.Revision || applyResult.CoreID != model.CoreIDXray || !model.SupportedAdapterID(applyResult.AdapterID)) {
					applyErr = fault.New(fault.CodeRuntimeApplyFailed, "validate recovered runtime", nil)
				}
				if applyErr != nil {
					return JoinResult{}, fault.New(runtimeApplyErrorCode(applyErr), "recover existing runtime", applyErr)
				}
			}
			return JoinResult{
				DeviceID:      lastKnown.DeviceID,
				NetworkID:     lastKnown.NetworkID,
				Revision:      lastKnown.Config.Revision,
				AlreadyJoined: true,
			}, nil
		}
	} else if !errors.Is(err, state.ErrNotFound) {
		return JoinResult{}, err
	}

	checkpoint, err := j.loadOrCreateCheckpoint(request)
	if err != nil {
		return JoinResult{}, err
	}

	if !phaseAtLeast(checkpoint.Phase, state.PhaseDeviceRegistered) {
		response, err := j.controlPlane.RegisterDevice(ctx, controlplane.RegisterDeviceRequest{
			DeviceID:           checkpoint.DeviceID,
			Name:               checkpoint.DeviceName,
			Platform:           checkpoint.Platform,
			Hostname:           checkpoint.Hostname,
			NetworkID:          checkpoint.NetworkID,
			WireGuardPublicKey: checkpoint.WireGuardPublicKey,
		})
		if err != nil {
			return JoinResult{}, err
		}
		if response.Device.ID == "" || response.Device.ID != checkpoint.DeviceID || response.Device.NetworkID == "" || response.Network.ID != response.Device.NetworkID {
			return JoinResult{}, fault.New(fault.CodeInvalidResponse, "register overlay device", nil)
		}
		checkpoint.NetworkID = response.Device.NetworkID
		checkpoint.Phase = state.PhaseDeviceRegistered
		checkpoint.LastErrorCode = ""
		checkpoint.UpdatedAt = j.now().UTC()
		if err := j.store.SaveCheckpoint(checkpoint); err != nil {
			return JoinResult{}, err
		}
	}

	if !phaseAtLeast(checkpoint.Phase, state.PhaseConfigFetched) {
		config, err := j.controlPlane.GetConfig(ctx, controlplane.ConfigRequest{
			DeviceID:  checkpoint.DeviceID,
			NetworkID: checkpoint.NetworkID,
			NodeID:    checkpoint.NodeID,
		})
		if err != nil {
			return JoinResult{}, err
		}
		if err := config.Validate(); err != nil {
			return JoinResult{}, err
		}
		if config.Device.ID != checkpoint.DeviceID || config.Device.NetworkID != checkpoint.NetworkID || config.Network.ID != checkpoint.NetworkID {
			return JoinResult{}, fault.New(fault.CodeInvalidConfig, "validate config ownership", nil)
		}
		checkpoint.Config = &config
		checkpoint.Phase = state.PhaseConfigFetched
		checkpoint.LastErrorCode = ""
		checkpoint.UpdatedAt = j.now().UTC()
		if err := j.store.SaveCheckpoint(checkpoint); err != nil {
			return JoinResult{}, err
		}
	}

	if checkpoint.Config == nil {
		return JoinResult{}, fault.New(fault.CodeStateIO, "resume join", nil)
	}
	if !phaseAtLeast(checkpoint.Phase, state.PhaseRuntimeApplied) {
		applyResult, err := j.runtime.Apply(ctx, runtime.ApplyRequest{
			Config:              *checkpoint.Config,
			WireGuardPrivateKey: checkpoint.WireGuardPrivateKey,
		})
		if err == nil && (applyResult.Revision != checkpoint.Config.Revision || applyResult.CoreID != model.CoreIDXray || !model.SupportedAdapterID(applyResult.AdapterID)) {
			err = fault.New(fault.CodeRuntimeApplyFailed, "validate runtime apply result", nil)
		}
		if err != nil {
			code := runtimeApplyErrorCode(err)
			checkpoint.LastErrorCode = code
			checkpoint.UpdatedAt = j.now().UTC()
			_ = j.store.SaveCheckpoint(checkpoint)
			return JoinResult{}, fault.New(code, "apply runtime profile", err)
		}
		checkpoint.Phase = state.PhaseRuntimeApplied
		checkpoint.LastErrorCode = ""
		checkpoint.UpdatedAt = j.now().UTC()
		if err := j.store.SaveCheckpoint(checkpoint); err != nil {
			return JoinResult{}, err
		}
	}

	if !phaseAtLeast(checkpoint.Phase, state.PhaseAcknowledged) {
		ack, err := j.controlPlane.AckConfig(ctx, controlplane.ConfigAckRequest{
			DeviceID:  checkpoint.DeviceID,
			NetworkID: checkpoint.NetworkID,
			Revision:  checkpoint.Config.Revision,
			Digest:    checkpoint.Config.Digest,
			AppliedAt: j.now().UTC(),
		})
		if err != nil {
			return JoinResult{}, err
		}
		if !ack.Acked || ack.DeviceID != checkpoint.DeviceID || ack.NetworkID != checkpoint.NetworkID || ack.Revision != checkpoint.Config.Revision {
			return JoinResult{}, fault.New(fault.CodeInvalidResponse, "acknowledge config", nil)
		}
		checkpoint.Phase = state.PhaseAcknowledged
		checkpoint.UpdatedAt = j.now().UTC()
		if err := j.store.SaveCheckpoint(checkpoint); err != nil {
			return JoinResult{}, err
		}
	}

	lastKnown := state.LastKnown{
		Server:              checkpoint.Server,
		DeviceID:            checkpoint.DeviceID,
		NetworkID:           checkpoint.NetworkID,
		NodeID:              checkpoint.NodeID,
		WireGuardPrivateKey: checkpoint.WireGuardPrivateKey,
		WireGuardPublicKey:  checkpoint.WireGuardPublicKey,
		Phase:               state.PhaseAcknowledged,
		Config:              *checkpoint.Config,
		UpdatedAt:           j.now().UTC(),
	}
	if err := j.store.SaveLastKnown(lastKnown); err != nil {
		return JoinResult{}, err
	}
	if err := j.store.ClearCheckpoint(); err != nil {
		return JoinResult{}, err
	}
	return JoinResult{
		DeviceID:  lastKnown.DeviceID,
		NetworkID: lastKnown.NetworkID,
		Revision:  lastKnown.Config.Revision,
	}, nil
}

func runtimeApplyErrorCode(err error) string {
	switch fault.Code(err) {
	case fault.CodeRuntimeUnavailable,
		fault.CodeRuntimeDependency,
		fault.CodeRuntimePermission,
		fault.CodeRuntimeProcessStale,
		fault.CodeRuntimeRollbackFailed:
		return fault.Code(err)
	default:
		return fault.CodeRuntimeApplyFailed
	}
}

func (j *Joiner) loadOrCreateCheckpoint(request JoinRequest) (state.Checkpoint, error) {
	checkpoint, err := j.store.LoadCheckpoint()
	if err == nil {
		if checkpoint.Server != request.Server || checkpoint.DeviceID != request.DeviceID {
			return state.Checkpoint{}, fault.New(fault.CodeStateConflict, "resume join", nil)
		}
		return checkpoint, nil
	}
	if !errors.Is(err, state.ErrNotFound) {
		return state.Checkpoint{}, err
	}
	privateKey, publicKey, err := j.generateKey()
	if err != nil {
		return state.Checkpoint{}, fault.New(fault.CodeInvalidConfig, "generate WireGuard key", err)
	}
	checkpoint = state.Checkpoint{
		Server:              request.Server,
		DeviceID:            request.DeviceID,
		DeviceName:          strings.TrimSpace(request.DeviceName),
		Platform:            strings.TrimSpace(request.Platform),
		Hostname:            strings.TrimSpace(request.Hostname),
		NetworkID:           strings.TrimSpace(request.NetworkID),
		NodeID:              strings.TrimSpace(request.NodeID),
		WireGuardPrivateKey: privateKey,
		WireGuardPublicKey:  publicKey,
		Phase:               state.PhaseStarted,
		UpdatedAt:           j.now().UTC(),
	}
	if err := j.store.SaveCheckpoint(checkpoint); err != nil {
		return state.Checkpoint{}, err
	}
	return checkpoint, nil
}

func generateWireGuardKeyPair() (string, string, error) {
	privateKey, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(privateKey.Bytes()), base64.StdEncoding.EncodeToString(privateKey.PublicKey().Bytes()), nil
}

func phaseAtLeast(current, target state.Phase) bool {
	order := map[state.Phase]int{
		state.PhaseStarted:          1,
		state.PhaseDeviceRegistered: 2,
		state.PhaseConfigFetched:    3,
		state.PhaseRuntimeApplied:   4,
		state.PhaseAcknowledged:     5,
	}
	return order[current] >= order[target]
}
