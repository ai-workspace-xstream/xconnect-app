package usecase

import (
	"context"
	"errors"

	"go_core/overlay/fault"
	"go_core/overlay/model"
	"go_core/overlay/runtime"
	"go_core/overlay/state"
)

type StatusResult struct {
	Joined    bool           `json:"joined"`
	DeviceID  string         `json:"device_id,omitempty"`
	NetworkID string         `json:"network_id,omitempty"`
	Revision  string         `json:"revision,omitempty"`
	Runtime   runtime.Status `json:"runtime"`
}

type DiagnosticResult struct {
	Code    string `json:"code"`
	Healthy bool   `json:"healthy"`
}

func Status(ctx context.Context, store *state.Store, tunnelRuntime runtime.Interface) (StatusResult, error) {
	lastKnown, err := store.LoadLastKnown()
	if errors.Is(err, state.ErrNotFound) {
		return StatusResult{Runtime: runtime.Status{}}, nil
	}
	if err != nil {
		return StatusResult{}, err
	}
	runtimeStatus, err := tunnelRuntime.Status(ctx)
	if err != nil {
		return StatusResult{}, fault.New(fault.CodeRuntimeStatusFailed, "read runtime status", err)
	}
	return StatusResult{
		Joined:    lastKnown.Phase == state.PhaseAcknowledged,
		DeviceID:  lastKnown.DeviceID,
		NetworkID: lastKnown.NetworkID,
		Revision:  lastKnown.Config.Revision,
		Runtime:   runtimeStatus,
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
		)
	}
	runtimeDiagnostics, err := tunnelRuntime.Diagnose(ctx)
	if err != nil {
		return nil, fault.New(fault.CodeRuntimeStatusFailed, "diagnose runtime", err)
	}
	for _, item := range runtimeDiagnostics {
		results = append(results, DiagnosticResult{Code: item.Code, Healthy: item.Healthy})
	}
	return results, nil
}
