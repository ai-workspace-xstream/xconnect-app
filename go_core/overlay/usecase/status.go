package usecase

import (
	"context"
	"errors"
	"time"

	"go_core/overlay/fault"
	"go_core/overlay/model"
	"go_core/overlay/runtime"
	"go_core/overlay/state"
)

type StatusResult struct {
	Joined      bool             `json:"joined"`
	DeviceID    string           `json:"device_id,omitempty"`
	NetworkID   string           `json:"network_id,omitempty"`
	Revision    string           `json:"revision,omitempty"`
	Generations GenerationStatus `json:"generations"`
	Runtime     runtime.Status   `json:"runtime"`
}

type GenerationStatus struct {
	State           uint64 `json:"state"`
	RuntimeRevision string `json:"runtime_revision,omitempty"`
	Policy          uint64 `json:"policy"`
	PolicyExpired   bool   `json:"policy_expired"`
}

type DiagnosticResult struct {
	Code       string `json:"code"`
	Healthy    bool   `json:"healthy"`
	Generation uint64 `json:"generation,omitempty"`
	Revision   string `json:"revision,omitempty"`
}

func Status(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface) (StatusResult, error) {
	lastKnown, err := store.LoadLastKnown()
	statePresent := err == nil
	if err != nil && !errors.Is(err, state.ErrNotFound) {
		return StatusResult{}, err
	}
	runtimeStatus, err := tunnelRuntime.Status(ctx)
	if err != nil {
		return StatusResult{}, fault.New(fault.CodeRuntimeStatusFailed, "read runtime status", err)
	}
	generations := GenerationStatus{State: lastKnown.SignedGeneration, RuntimeRevision: runtimeStatus.Revision}
	if !statePresent {
		return StatusResult{Generations: generations, Runtime: runtimeStatus}, nil
	}
	policyState, policyErr := store.LoadPolicyState()
	if policyErr == nil && policyState.NetworkID == lastKnown.NetworkID {
		generations.Policy = policyState.Generation
		generations.PolicyExpired = !policyState.ExpiresAt.After(time.Now().UTC())
	} else if policyErr != nil && !errors.Is(policyErr, state.ErrNotFound) {
		return StatusResult{}, policyErr
	}
	return StatusResult{
		Joined: lastKnown.Phase == state.PhaseAcknowledged &&
			runtimeStatus.Applied &&
			runtimeStatus.Revision == lastKnown.Config.Revision &&
			runtimeStatus.CoreID == model.CoreIDXray &&
			model.SupportedAdapterID(runtimeStatus.AdapterID),
		DeviceID:    lastKnown.DeviceID,
		NetworkID:   lastKnown.NetworkID,
		Revision:    lastKnown.Config.Revision,
		Generations: generations,
		Runtime:     runtimeStatus,
	}, nil
}

func Diagnose(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface) ([]DiagnosticResult, error) {
	results := make([]DiagnosticResult, 0, 6)
	lastKnown, err := store.LoadLastKnown()
	statePresent := err == nil
	if err != nil && !errors.Is(err, state.ErrNotFound) {
		return nil, err
	}
	results = append(results, DiagnosticResult{Code: "last_known_state_present", Healthy: statePresent})
	if statePresent {
		results = append(results,
			DiagnosticResult{Code: "state_file_permissions_0600", Healthy: state.ValidatePermissions(store.LastKnownPath(), 0o600) == nil},
			DiagnosticResult{Code: "proxy_core_xray", Healthy: lastKnown.Config.CoreID() == model.CoreIDXray},
			DiagnosticResult{Code: "state_generation", Healthy: lastKnown.SignedGeneration > 0 || lastKnown.ConfigContract == string(ConfigContractLegacy), Generation: lastKnown.SignedGeneration},
		)
	}
	runtimeDiagnostics, err := tunnelRuntime.Diagnose(ctx)
	if err != nil {
		return nil, fault.New(fault.CodeRuntimeStatusFailed, "diagnose runtime", err)
	}
	for _, item := range runtimeDiagnostics {
		results = append(results, DiagnosticResult{Code: item.Code, Healthy: item.Healthy})
	}
	runtimeStatus, statusErr := tunnelRuntime.Status(ctx)
	if statusErr != nil {
		return nil, fault.New(fault.CodeRuntimeStatusFailed, "diagnose runtime generation", statusErr)
	}
	results = append(results, DiagnosticResult{Code: "runtime_revision", Healthy: runtimeStatus.Revision != "", Revision: runtimeStatus.Revision})
	policyState, policyErr := store.LoadPolicyState()
	if errors.Is(policyErr, state.ErrNotFound) {
		results = append(results, DiagnosticResult{Code: "policy_generation", Healthy: false})
	} else if policyErr != nil {
		return nil, policyErr
	} else {
		healthy := statePresent && policyState.NetworkID == lastKnown.NetworkID && policyState.ExpiresAt.After(time.Now().UTC())
		results = append(results, DiagnosticResult{Code: "policy_generation", Healthy: healthy, Generation: policyState.Generation})
	}
	return results, nil
}
