package usecase_test

import (
	"context"
	"encoding/base64"
	"errors"
	"sync"
	"testing"

	"go_core/overlay/fault"
	"go_core/overlay/runtime"
	"go_core/overlay/state"
	"go_core/overlay/usecase"
)

type fakeDeviceLifecycle struct {
	mu    sync.Mutex
	calls int
	err   error
}

func (f *fakeDeviceLifecycle) RevokeDevice(_ context.Context, _ usecase.DeviceLifecycleRequest) (usecase.DeviceLifecycleResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	if f.err != nil {
		return usecase.DeviceLifecycleResponse{}, f.err
	}
	return usecase.DeviceLifecycleResponse{Revoked: true, Duplicate: f.calls > 1}, nil
}

func lifecycleLastKnown() state.LastKnown {
	config := validConfig()
	return state.LastKnown{
		Server: "https://accounts.example", DeviceID: "dev_laptop", NetworkID: "net_private",
		WireGuardPrivateKey: base64.StdEncoding.EncodeToString(make([]byte, 32)),
		WireGuardPublicKey:  base64.StdEncoding.EncodeToString(make([]byte, 32)),
		Phase:               state.PhaseAcknowledged, Config: config, ConfigContract: string(usecase.ConfigContractSigned),
		SignedConfigID: "cfg_42", SignedGeneration: 42,
	}
}

func TestUpDownAreIdempotentAndDoNotAcknowledgeAgain(t *testing.T) {
	store := state.NewStore(t.TempDir())
	lastKnown := lifecycleLastKnown()
	if err := store.SaveLastKnown(lastKnown); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &runtime.Fake{}
	up, err := usecase.Up(t.Context(), store, runtimeFake)
	if err != nil || up.State != "up" || runtimeFake.ApplyCalls != 1 {
		t.Fatalf("up=%#v err=%v calls=%d", up, err, runtimeFake.ApplyCalls)
	}
	up, err = usecase.Up(t.Context(), store, runtimeFake)
	if err != nil || !up.AlreadyInState || runtimeFake.ApplyCalls != 1 {
		t.Fatalf("repeat up=%#v err=%v calls=%d", up, err, runtimeFake.ApplyCalls)
	}
	down, err := usecase.Down(t.Context(), store, runtimeFake)
	if err != nil || down.State != "down" || runtimeFake.DownCalls != 1 {
		t.Fatalf("down=%#v err=%v calls=%d", down, err, runtimeFake.DownCalls)
	}
	down, err = usecase.Down(t.Context(), store, runtimeFake)
	if err != nil || !down.AlreadyInState || runtimeFake.DownCalls != 1 {
		t.Fatalf("repeat down=%#v err=%v calls=%d", down, err, runtimeFake.DownCalls)
	}
}

func TestLeaveRequiresStableServerContractUnlessExplicitLocalOnly(t *testing.T) {
	store := state.NewStore(t.TempDir())
	if err := store.SaveLastKnown(lifecycleLastKnown()); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &runtime.Fake{}
	if _, err := usecase.Leave(t.Context(), store, runtimeFake, nil, false); fault.Code(err) != fault.CodeDeviceLifecyclePending {
		t.Fatalf("code=%q err=%v", fault.Code(err), err)
	}
	if runtimeFake.DownCalls != 0 || runtimeFake.CleanupCalls != 0 {
		t.Fatal("local state changed before revocation contract")
	}
	result, err := usecase.Leave(t.Context(), store, runtimeFake, nil, true)
	if err != nil || !result.LocalOnly || runtimeFake.DownCalls != 1 || runtimeFake.CleanupCalls != 1 {
		t.Fatalf("leave=%#v err=%v", result, err)
	}
	if _, err := store.LoadLastKnown(); !errors.Is(err, state.ErrNotFound) {
		t.Fatalf("state remains: %v", err)
	}
	repeat, err := usecase.Leave(t.Context(), store, runtimeFake, nil, true)
	if err != nil || !repeat.AlreadyInState {
		t.Fatalf("repeat=%#v err=%v", repeat, err)
	}
}

func TestDefaultLeaveNeverClaimsRemoteRevocationWithoutDurableCredential(t *testing.T) {
	store := state.NewStore(t.TempDir())
	result, err := usecase.Leave(t.Context(), store, &runtime.Fake{}, nil, false)
	if fault.Code(err) != fault.CodeDeviceLifecyclePending || result.State != "" {
		t.Fatalf("leave=%#v code=%q err=%v", result, fault.Code(err), err)
	}
}

func TestLeaveDoesNotClearStateWhenRuntimeCleanupFails(t *testing.T) {
	store := state.NewStore(t.TempDir())
	if err := store.SaveLastKnown(lifecycleLastKnown()); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &runtime.Fake{CleanupError: fault.New(fault.CodeRuntimeApplyFailed, "cleanup", nil)}
	_, err := usecase.Leave(t.Context(), store, runtimeFake, nil, true)
	if fault.Code(err) != fault.CodeRuntimeApplyFailed {
		t.Fatalf("code=%q err=%v", fault.Code(err), err)
	}
	if _, loadErr := store.LoadLastKnown(); loadErr != nil {
		t.Fatalf("state cleared after failure: %v", loadErr)
	}
}

func TestLeaveRetriesIdempotentRevocationAfterRuntimeInterruption(t *testing.T) {
	store := state.NewStore(t.TempDir())
	if err := store.SaveLastKnown(lifecycleLastKnown()); err != nil {
		t.Fatal(err)
	}
	revoker := &fakeDeviceLifecycle{}
	runtimeFake := &runtime.Fake{DownError: fault.New(fault.CodeRuntimeApplyFailed, "down", nil)}
	if _, err := usecase.Leave(t.Context(), store, runtimeFake, revoker, false); fault.Code(err) != fault.CodeRuntimeApplyFailed {
		t.Fatalf("first leave code=%q err=%v", fault.Code(err), err)
	}
	if revoker.calls != 1 {
		t.Fatalf("revoke calls=%d", revoker.calls)
	}
	runtimeFake.DownError = nil
	result, err := usecase.Leave(t.Context(), store, runtimeFake, revoker, false)
	if err != nil || result.State != "left" || revoker.calls != 2 {
		t.Fatalf("retry=%#v err=%v revoke=%d", result, err, revoker.calls)
	}
}

func TestDownAndStatusRecoverOwnedRuntimeWithoutLastKnownState(t *testing.T) {
	store := state.NewStore(t.TempDir())
	runtimeFake := &runtime.Fake{StatusResult: runtime.Status{
		Available: true, Applied: true, Revision: "revision-orphan",
		CoreID: "xray", AdapterID: "xray-core",
	}}
	status, err := usecase.Status(t.Context(), store, runtimeFake)
	if err != nil || status.Joined || !status.Runtime.Applied || status.Generations.RuntimeRevision != "revision-orphan" {
		t.Fatalf("status=%#v err=%v", status, err)
	}
	result, err := usecase.Down(t.Context(), store, runtimeFake)
	if err != nil || result.AlreadyInState || runtimeFake.DownCalls != 1 {
		t.Fatalf("down=%#v err=%v calls=%d", result, err, runtimeFake.DownCalls)
	}
}

func TestLocalLeaveClearsInterruptedJoinWithoutClaimingServerRevocation(t *testing.T) {
	store := state.NewStore(t.TempDir())
	if err := store.SaveCheckpoint(state.Checkpoint{Server: "https://accounts.example", DeviceID: "dev_partial", Phase: state.PhaseDeviceRegistered}); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &runtime.Fake{}
	if _, err := usecase.Leave(t.Context(), store, runtimeFake, nil, false); fault.Code(err) != fault.CodeDeviceLifecyclePending {
		t.Fatalf("default leave code=%q err=%v", fault.Code(err), err)
	}
	if _, err := store.LoadCheckpoint(); err != nil {
		t.Fatalf("default leave removed partial state: %v", err)
	}
	result, err := usecase.Leave(t.Context(), store, runtimeFake, nil, true)
	if err != nil || !result.LocalOnly || result.AlreadyInState {
		t.Fatalf("local leave=%#v err=%v", result, err)
	}
	if _, err := store.LoadCheckpoint(); !errors.Is(err, state.ErrNotFound) {
		t.Fatalf("checkpoint remains: %v", err)
	}
	repeat, err := usecase.Leave(t.Context(), store, runtimeFake, nil, true)
	if err != nil || !repeat.AlreadyInState {
		t.Fatalf("repeat=%#v err=%v", repeat, err)
	}
}
