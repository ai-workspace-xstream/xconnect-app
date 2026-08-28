package usecase_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go_core/overlay/controlplane"
	"go_core/overlay/fault"
	"go_core/overlay/model"
	overlayruntime "go_core/overlay/runtime"
	"go_core/overlay/signedconfig"
	"go_core/overlay/state"
	"go_core/overlay/usecase"
)

type inviteControlPlaneFixture struct {
	*signedControlPlaneFixture
	exchangeCalls         int
	enrollmentConfigCalls int
	enrollmentAckCalls    int
	exchangedJoinTokens   []string
	enrollmentTokens      []string
	enrollmentAckErrors   []error
}

func newInviteControlPlaneFixture(t *testing.T) *inviteControlPlaneFixture {
	return &inviteControlPlaneFixture{signedControlPlaneFixture: newSignedControlPlaneFixture(t)}
}

func (f *inviteControlPlaneFixture) ExchangeJoinToken(_ context.Context, request controlplane.JoinTokenExchangeRequest) (controlplane.JoinTokenExchangeResponse, error) {
	f.exchangeCalls++
	f.exchangedJoinTokens = append(f.exchangedJoinTokens, request.JoinToken)
	token := opaqueUsecaseSecret("xenr_", byte(20+f.exchangeCalls))
	f.enrollmentTokens = append(f.enrollmentTokens, token)
	return controlplane.JoinTokenExchangeResponse{
		EnrollmentToken: token, TokenType: "Bearer", ExpiresAt: request.Now.Add(10 * time.Minute),
		Scope:   []string{"overlay:config:read", "overlay:config:ack", "overlay:device:revoke"},
		Device:  model.Device{ID: request.DeviceID, NetworkID: "net_private", Platform: request.Platform, WireGuardPublicKey: request.WireGuardPublicKey, WireGuardAddress: "10.77.0.10/32"},
		Network: model.Network{ID: "net_private", CIDR: "10.77.0.0/16"}, SigningKeys: append([]signedconfig.SigningKey(nil), f.keys.Keys...),
	}, nil
}

func (f *inviteControlPlaneFixture) GetEnrollmentSignedConfig(_ context.Context, enrollmentToken string, _ controlplane.SignedConfigRequest) (signedconfig.Config, error) {
	f.enrollmentConfigCalls++
	if len(f.enrollmentTokens) == 0 || enrollmentToken != f.enrollmentTokens[len(f.enrollmentTokens)-1] {
		return signedconfig.Config{}, fault.New(fault.CodeEnrollmentExpired, "invalid enrollment", nil)
	}
	return f.config, nil
}

func (f *inviteControlPlaneFixture) AckEnrollmentSignedConfig(_ context.Context, enrollmentToken string, request controlplane.SignedConfigAckRequest) (controlplane.SignedConfigAckResponse, error) {
	f.enrollmentAckCalls++
	if len(f.enrollmentTokens) == 0 || enrollmentToken != f.enrollmentTokens[len(f.enrollmentTokens)-1] {
		return controlplane.SignedConfigAckResponse{}, fault.New(fault.CodeEnrollmentExpired, "invalid enrollment", nil)
	}
	if len(f.enrollmentAckErrors) > 0 {
		err := f.enrollmentAckErrors[0]
		f.enrollmentAckErrors = f.enrollmentAckErrors[1:]
		if err != nil {
			return controlplane.SignedConfigAckResponse{}, err
		}
	}
	return controlplane.SignedConfigAckResponse{Acked: true, Ack: controlplane.SignedConfigAck{
		DeviceID: request.DeviceID, ConfigID: request.ConfigID, Generation: request.Generation,
		AppliedAt: request.AppliedAt.UTC(), ReceivedAt: request.AppliedAt.UTC(),
	}}, nil
}

func TestInviteJoinUsesAtomicExchangeAndSignedOnlyEnrollment(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	tunnelRuntime := &overlayruntime.Fake{}
	now := time.Date(2026, 8, 27, 12, 15, 0, 0, time.UTC)
	joiner, store := newInviteJoiner(t, controlPlane, tunnelRuntime, func() time.Time { return now })
	joinToken := opaqueUsecaseSecret("xjt_", 7)

	result, err := joiner.Join(t.Context(), inviteJoinRequest(joinToken))
	if err != nil {
		t.Fatalf("invite join: %v", err)
	}
	if result.Revision != "cfg_42" || controlPlane.exchangeCalls != 1 || controlPlane.registerCalls != 0 || controlPlane.legacyCalls != 0 || controlPlane.enrollmentConfigCalls != 1 || controlPlane.enrollmentAckCalls != 1 || tunnelRuntime.ApplyCalls != 1 {
		t.Fatalf("result=%#v exchange=%d register=%d legacy=%d config=%d ack=%d apply=%d", result, controlPlane.exchangeCalls, controlPlane.registerCalls, controlPlane.legacyCalls, controlPlane.enrollmentConfigCalls, controlPlane.enrollmentAckCalls, tunnelRuntime.ApplyCalls)
	}
	if _, err := os.Stat(store.EnrollmentSecretPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("completed enrollment secret remains: %v", err)
	}
	lastKnown, err := store.LoadLastKnown()
	if err != nil || lastKnown.ConfigContract != string(usecase.ConfigContractSigned) {
		t.Fatalf("lastKnown=%#v err=%v", lastKnown, err)
	}
	assertStateDoesNotContain(t, store.Directory(), joinToken)
	for _, token := range controlPlane.enrollmentTokens {
		assertStateDoesNotContain(t, store.Directory(), token)
	}
}

func TestInviteJoinRuntimeFailureResumesWithoutReplayingInvite(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	tunnelRuntime := &overlayruntime.Fake{ApplyError: errors.New("runtime failed with hidden secret")}
	now := time.Date(2026, 8, 27, 12, 15, 0, 0, time.UTC)
	joiner, store := newInviteJoiner(t, controlPlane, tunnelRuntime, func() time.Time { return now })
	request := inviteJoinRequest(opaqueUsecaseSecret("xjt_", 7))

	if _, err := joiner.Join(t.Context(), request); fault.Code(err) != fault.CodeRuntimeApplyFailed {
		t.Fatalf("runtime error=%v", err)
	}
	if controlPlane.enrollmentAckCalls != 0 {
		t.Fatalf("runtime failure ACK calls=%d", controlPlane.enrollmentAckCalls)
	}
	if err := state.ValidatePermissions(store.EnrollmentSecretPath(), 0o600); err != nil {
		t.Fatalf("transient permissions: %v", err)
	}
	status, err := usecase.Status(t.Context(), store, tunnelRuntime)
	if err != nil || strings.Contains(strings.TrimSpace(toJSON(t, status)), controlPlane.enrollmentTokens[0]) {
		t.Fatalf("status leaked enrollment: %#v err=%v", status, err)
	}
	diagnostics, err := usecase.Diagnose(t.Context(), store, tunnelRuntime)
	if err != nil || strings.Contains(strings.TrimSpace(toJSON(t, diagnostics)), controlPlane.enrollmentTokens[0]) {
		t.Fatalf("diagnose leaked enrollment: %#v err=%v", diagnostics, err)
	}
	tunnelRuntime.ApplyError = nil
	if _, err := joiner.Join(t.Context(), request); err != nil {
		t.Fatalf("resume invite join: %v", err)
	}
	if controlPlane.exchangeCalls != 1 || tunnelRuntime.ApplyCalls != 2 || controlPlane.enrollmentAckCalls != 1 {
		t.Fatalf("resume exchange=%d apply=%d ack=%d", controlPlane.exchangeCalls, tunnelRuntime.ApplyCalls, controlPlane.enrollmentAckCalls)
	}
}

func TestExpiredAfterApplyRenewsWithNewInviteWithoutReapply(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	controlPlane.enrollmentAckErrors = []error{fault.New(fault.CodeControlPlaneUnavailable, "ack unavailable", nil)}
	tunnelRuntime := &overlayruntime.Fake{}
	clock := time.Date(2026, 8, 27, 12, 15, 0, 0, time.UTC)
	joiner, store := newInviteJoiner(t, controlPlane, tunnelRuntime, func() time.Time { return clock })
	firstInvite := opaqueUsecaseSecret("xjt_", 7)

	if _, err := joiner.Join(t.Context(), inviteJoinRequest(firstInvite)); fault.Code(err) != fault.CodeControlPlaneUnavailable {
		t.Fatalf("first ACK interruption=%v", err)
	}
	checkpoint, err := store.LoadCheckpoint()
	if err != nil || checkpoint.Phase != state.PhaseRuntimeApplied {
		t.Fatalf("checkpoint=%#v err=%v", checkpoint, err)
	}
	clock = clock.Add(11 * time.Minute)
	if _, err := joiner.Join(t.Context(), inviteJoinRequest("")); fault.Code(err) != fault.CodeEnrollmentExpired {
		t.Fatalf("expired without new invite code=%q err=%v", fault.Code(err), err)
	}
	if _, err := os.Stat(store.EnrollmentSecretPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expired transient was not removed: %v", err)
	}
	secondInvite := opaqueUsecaseSecret("xjt_", 8)
	if _, err := joiner.Join(t.Context(), inviteJoinRequest(secondInvite)); err != nil {
		t.Fatalf("renew enrollment: %v", err)
	}
	if controlPlane.exchangeCalls != 2 || tunnelRuntime.ApplyCalls != 1 || controlPlane.enrollmentConfigCalls != 1 || controlPlane.enrollmentAckCalls != 2 {
		t.Fatalf("renew exchange=%d apply=%d config=%d ack=%d", controlPlane.exchangeCalls, tunnelRuntime.ApplyCalls, controlPlane.enrollmentConfigCalls, controlPlane.enrollmentAckCalls)
	}
	if controlPlane.exchangedJoinTokens[0] != firstInvite || controlPlane.exchangedJoinTokens[1] != secondInvite {
		t.Fatalf("exchanged invites=%#v", controlPlane.exchangedJoinTokens)
	}
}

func newInviteJoiner(t *testing.T, controlPlane *inviteControlPlaneFixture, tunnelRuntime overlayruntime.Interface, clock func() time.Time) (*usecase.Joiner, *state.Store) {
	t.Helper()
	store := state.NewStore(t.TempDir())
	joiner := usecase.NewJoiner(controlPlane, store, tunnelRuntime).WithKeyGenerator(fixedKeys).WithClock(clock).WithConfigContract(usecase.ConfigContractSigned)
	return joiner, store
}

func inviteJoinRequest(joinToken string) usecase.JoinRequest {
	return usecase.JoinRequest{Server: "https://accounts.example", DeviceID: "dev_laptop", DeviceName: "Laptop", Platform: "linux", Hostname: "laptop", JoinToken: joinToken}
}

func opaqueUsecaseSecret(prefix string, fill byte) string {
	return prefix + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{fill}, 32))
}

func assertStateDoesNotContain(t *testing.T, directory, secret string) {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(directory, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(raw, []byte(secret)) {
			t.Fatalf("%s persisted in %s", secret[:5], entry.Name())
		}
	}
}

func toJSON(t *testing.T, value any) string {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
