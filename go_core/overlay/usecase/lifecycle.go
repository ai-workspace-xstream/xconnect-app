package usecase

import (
	"context"
	"errors"

	"go_core/overlay/fault"
	"go_core/overlay/model"
	"go_core/overlay/runtime"
	"go_core/overlay/state"
)

type DeviceLifecycleRequest struct {
	Controller string
	DeviceID   string
	NetworkID  string
}

type DeviceLifecycleResponse struct {
	Revoked   bool
	Duplicate bool
}

// DeviceLifecycleControlPlane intentionally has no HTTP path in the client.
// Accounts Batch 07 owns that contract; the CLI wires an implementation only
// after its versioned route and response become canonical.
type DeviceLifecycleControlPlane interface {
	RevokeDevice(context.Context, DeviceLifecycleRequest) (DeviceLifecycleResponse, error)
}

type LifecycleResult struct {
	State          string   `json:"state"`
	DeviceID       string   `json:"device_id,omitempty"`
	NetworkID      string   `json:"network_id,omitempty"`
	Revision       string   `json:"revision,omitempty"`
	AlreadyInState bool     `json:"already_in_state"`
	LocalOnly      bool     `json:"local_only,omitempty"`
	Removed        []string `json:"removed,omitempty"`
	RetainedFiles  bool     `json:"retained_unknown_files,omitempty"`
}

func Up(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface) (LifecycleResult, error) {
	lock, err := store.AcquireOperation(ctx, "up")
	if err != nil {
		return LifecycleResult{}, err
	}
	defer lock.Release()
	lastKnown, err := store.LoadLastKnown()
	if errors.Is(err, state.ErrNotFound) {
		return LifecycleResult{}, fault.New(fault.CodeNotJoined, "start overlay", nil)
	}
	if err != nil {
		return LifecycleResult{}, err
	}
	status, err := tunnelRuntime.Status(ctx)
	if err != nil {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeStatusFailed, "read runtime status", err)
	}
	result := lifecycleResult("up", lastKnown)
	if runtimeMatches(status, lastKnown) {
		result.AlreadyInState = true
		return result, nil
	}
	apply, err := tunnelRuntime.Apply(ctx, runtime.ApplyRequest{Config: lastKnown.Config, WireGuardPrivateKey: lastKnown.WireGuardPrivateKey})
	if err != nil {
		return LifecycleResult{}, fault.New(runtimeApplyErrorCode(err), "start overlay runtime", err)
	}
	if apply.Revision != lastKnown.Config.Revision || apply.CoreID != model.CoreIDXray || !model.SupportedAdapterID(apply.AdapterID) {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeApplyFailed, "validate started runtime", nil)
	}
	return result, nil
}

func Down(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface) (LifecycleResult, error) {
	lock, err := store.AcquireOperation(ctx, "down")
	if err != nil {
		return LifecycleResult{}, err
	}
	defer lock.Release()
	lastKnown, err := store.LoadLastKnown()
	statePresent := err == nil
	if err != nil && !errors.Is(err, state.ErrNotFound) {
		return LifecycleResult{}, err
	}
	result := LifecycleResult{State: "down"}
	if statePresent {
		result = lifecycleResult("down", lastKnown)
	}
	status, err := tunnelRuntime.Status(ctx)
	if err != nil {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeStatusFailed, "read runtime status", err)
	}
	if !status.Applied {
		if statePresent && !status.Available {
			return LifecycleResult{}, fault.New(fault.CodeRuntimeUnavailable, "stop overlay runtime", nil)
		}
		result.AlreadyInState = true
		return result, nil
	}
	if !status.Available {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeUnavailable, "stop overlay runtime", nil)
	}
	lifecycle, ok := tunnelRuntime.(runtime.Lifecycle)
	if !ok {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeUnavailable, "stop overlay runtime", nil)
	}
	if err := lifecycle.Down(ctx); err != nil {
		return LifecycleResult{}, err
	}
	return result, nil
}

func Leave(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface, deviceLifecycle DeviceLifecycleControlPlane, localOnly bool) (LifecycleResult, error) {
	lock, err := store.AcquireOperation(ctx, "leave")
	if err != nil {
		return LifecycleResult{}, err
	}
	defer lock.Release()
	if !localOnly && deviceLifecycle == nil {
		return LifecycleResult{}, fault.New(fault.CodeDeviceLifecyclePending, "revoke overlay device", nil)
	}
	lastKnown, err := store.LoadLastKnown()
	if errors.Is(err, state.ErrNotFound) {
		return leaveWithoutLastKnown(ctx, store, tunnelRuntime, localOnly)
	}
	if err != nil {
		return LifecycleResult{}, err
	}
	if !localOnly {
		response, revokeErr := deviceLifecycle.RevokeDevice(ctx, DeviceLifecycleRequest{Controller: lastKnown.Server, DeviceID: lastKnown.DeviceID, NetworkID: lastKnown.NetworkID})
		if revokeErr != nil {
			return LifecycleResult{}, revokeErr
		}
		if !response.Revoked {
			return LifecycleResult{}, fault.New(fault.CodeInvalidResponse, "validate device revocation", nil)
		}
	}
	lifecycle, ok := tunnelRuntime.(runtime.Lifecycle)
	if !ok {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeUnavailable, "leave overlay runtime", nil)
	}
	if err := lifecycle.Down(ctx); err != nil {
		return LifecycleResult{}, err
	}
	if err := lifecycle.Cleanup(ctx); err != nil {
		return LifecycleResult{}, err
	}
	cleaned, err := store.ClearOwnedState()
	if err != nil {
		return LifecycleResult{}, err
	}
	result := lifecycleResult("left", lastKnown)
	result.LocalOnly = localOnly
	result.Removed = append([]string(nil), cleaned.Removed...)
	result.RetainedFiles = cleaned.Retained
	return result, nil
}

func leaveWithoutLastKnown(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface, localOnly bool) (LifecycleResult, error) {
	_, checkpointErr := store.LoadCheckpoint()
	partialState := checkpointErr == nil
	if checkpointErr != nil && !errors.Is(checkpointErr, state.ErrNotFound) {
		return LifecycleResult{}, checkpointErr
	}
	if !localOnly {
		if partialState {
			return LifecycleResult{}, fault.New(fault.CodeDeviceLifecyclePending, "revoke partial overlay enrollment", nil)
		}
		return LifecycleResult{State: "left", AlreadyInState: true}, nil
	}
	status, err := tunnelRuntime.Status(ctx)
	if err != nil {
		return LifecycleResult{}, fault.New(fault.CodeRuntimeStatusFailed, "read runtime status", err)
	}
	if status.Applied || status.Revision != "" {
		lifecycle, ok := tunnelRuntime.(runtime.Lifecycle)
		if !ok {
			return LifecycleResult{}, fault.New(fault.CodeRuntimeUnavailable, "leave partial overlay runtime", nil)
		}
		if status.Applied {
			if err := lifecycle.Down(ctx); err != nil {
				return LifecycleResult{}, err
			}
		}
		if err := lifecycle.Cleanup(ctx); err != nil {
			return LifecycleResult{}, err
		}
	}
	cleaned, err := store.ClearOwnedState()
	if err != nil {
		return LifecycleResult{}, err
	}
	return LifecycleResult{State: "left", AlreadyInState: !partialState && len(cleaned.Removed) == 0, LocalOnly: true, Removed: cleaned.Removed, RetainedFiles: cleaned.Retained}, nil
}

func lifecycleResult(value string, lastKnown state.LastKnown) LifecycleResult {
	return LifecycleResult{State: value, DeviceID: lastKnown.DeviceID, NetworkID: lastKnown.NetworkID, Revision: lastKnown.Config.Revision}
}

func runtimeMatches(status runtime.Status, lastKnown state.LastKnown) bool {
	return status.Applied && status.Revision == lastKnown.Config.Revision && status.CoreID == model.CoreIDXray && model.SupportedAdapterID(status.AdapterID)
}
