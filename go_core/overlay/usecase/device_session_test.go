package usecase_test

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"go_core/overlay/credential"
	"go_core/overlay/fault"
	overlayruntime "go_core/overlay/runtime"
	"go_core/overlay/signedconfig"
	"go_core/overlay/state"
	"go_core/overlay/usecase"
)

func TestDeviceSyncMintsVerifiesAppliesAcknowledgesAndClearsBearer(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	now := controlPlane.config.IssuedAt.Time.Add(time.Minute)
	stateStore := state.NewStore(t.TempDir())
	lastKnown := lifecycleLastKnown()
	if err := stateStore.SaveLastKnown(lastKnown); err != nil {
		t.Fatal(err)
	}
	credentials := &credential.MemoryStore{}
	if err := credentials.Save(t.Context(), durableRecord(t, controlPlane.keys, now)); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &overlayruntime.Fake{}
	manager := usecase.NewDeviceSessionManager(controlPlane, stateStore, credentials, runtimeFake).WithClock(func() time.Time { return now })
	result, err := manager.Sync(t.Context())
	if err != nil {
		t.Fatalf("sync: %v", err)
	}
	if result.Generation != controlPlane.config.Generation || controlPlane.deviceSessionCalls != 1 || controlPlane.enrollmentConfigCalls != 1 || controlPlane.enrollmentAckCalls != 1 || runtimeFake.ApplyCalls != 1 {
		t.Fatalf("result=%#v mint=%d config=%d ack=%d apply=%d", result, controlPlane.deviceSessionCalls, controlPlane.enrollmentConfigCalls, controlPlane.enrollmentAckCalls, runtimeFake.ApplyCalls)
	}
	if _, err := os.Stat(stateStore.EnrollmentSecretPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("short bearer remains: %v", err)
	}
	if _, err := credentials.Load(t.Context()); err != nil {
		t.Fatalf("durable credential was removed: %v", err)
	}
}

func TestDeviceSyncRuntimeOrAckFailureDoesNotLoseCredentialOrReapply(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	now := controlPlane.config.IssuedAt.Time.Add(time.Minute)
	controlPlane.enrollmentAckErrors = []error{fault.New(fault.CodeControlPlaneUnavailable, "ack interrupted", nil), nil}
	stateStore := state.NewStore(t.TempDir())
	if err := stateStore.SaveLastKnown(lifecycleLastKnown()); err != nil {
		t.Fatal(err)
	}
	credentials := &credential.MemoryStore{}
	if err := credentials.Save(t.Context(), durableRecord(t, controlPlane.keys, now)); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &overlayruntime.Fake{}
	manager := usecase.NewDeviceSessionManager(controlPlane, stateStore, credentials, runtimeFake).WithClock(func() time.Time { return now })
	if _, err := manager.Sync(t.Context()); fault.Code(err) != fault.CodeControlPlaneUnavailable {
		t.Fatalf("first sync code=%q err=%v", fault.Code(err), err)
	}
	if _, err := manager.Sync(t.Context()); err != nil {
		t.Fatalf("resume sync: %v", err)
	}
	if runtimeFake.ApplyCalls != 1 || controlPlane.deviceSessionCalls != 1 || controlPlane.enrollmentAckCalls != 2 {
		t.Fatalf("apply=%d mint=%d ack=%d", runtimeFake.ApplyCalls, controlPlane.deviceSessionCalls, controlPlane.enrollmentAckCalls)
	}
	if _, err := credentials.Load(t.Context()); err != nil {
		t.Fatalf("credential lost: %v", err)
	}
}

func TestDeviceSyncFailedConfigCannotPoisonDurableSigningKeys(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	now := controlPlane.config.IssuedAt.Time.Add(time.Minute)
	previousUntil := signedconfig.CanonicalTime{Time: now.Add(24 * time.Hour)}
	old := controlPlane.keys.Keys[0]
	old.Status = "previous"
	old.NotAfter = &previousUntil
	controlPlane.sessionKeys = []signedconfig.SigningKey{old, {
		KeyID: "signing_key_untrusted", Algorithm: signedconfig.SignatureEd25519, PublicKey: "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=", Status: "current", NotBefore: signedconfig.CanonicalTime{Time: now.Add(-time.Hour)},
	}}
	controlPlane.enrollmentConfigError = fault.New(fault.CodeControlPlaneUnavailable, "config unavailable", nil)
	stateStore := state.NewStore(t.TempDir())
	if err := stateStore.SaveLastKnown(lifecycleLastKnown()); err != nil {
		t.Fatal(err)
	}
	credentials := &credential.MemoryStore{}
	original := durableRecord(t, controlPlane.keys, now)
	if err := credentials.Save(t.Context(), original); err != nil {
		t.Fatal(err)
	}
	manager := usecase.NewDeviceSessionManager(controlPlane, stateStore, credentials, &overlayruntime.Fake{}).WithClock(func() time.Time { return now })
	if _, err := manager.Sync(t.Context()); fault.Code(err) != fault.CodeControlPlaneUnavailable {
		t.Fatalf("code=%q err=%v", fault.Code(err), err)
	}
	stored, err := credentials.Load(t.Context())
	if err != nil || !reflect.DeepEqual(stored.SigningKeys, original.SigningKeys) {
		t.Fatalf("durable trust changed on failed config: stored=%#v original=%#v err=%v", stored.SigningKeys, original.SigningKeys, err)
	}
}

func TestDeviceCredentialRotationPersistsPendingAndRecoversLostResponse(t *testing.T) {
	now := time.Date(2026, 8, 28, 12, 0, 0, 0, time.UTC)
	controlPlane := newInviteControlPlaneFixture(t)
	controlPlane.rotateErrors = []error{fault.New(fault.CodeControlPlaneUnavailable, "response lost", nil)}
	credentials := &credential.MemoryStore{}
	original := durableRecord(t, controlPlane.keys, now)
	if err := credentials.Save(t.Context(), original); err != nil {
		t.Fatal(err)
	}
	manager := usecase.NewDeviceSessionManager(controlPlane, state.NewStore(t.TempDir()), credentials, &overlayruntime.Fake{}).WithClock(func() time.Time { return now })
	if _, err := manager.Rotate(t.Context()); fault.Code(err) != fault.CodeControlPlaneUnavailable {
		t.Fatalf("lost response code=%q err=%v", fault.Code(err), err)
	}
	pending, err := credentials.Load(t.Context())
	if err != nil || pending.Pending == nil || pending.CredentialID != original.CredentialID {
		t.Fatalf("pending=%#v err=%v", pending.Pending, err)
	}
	result, err := manager.Rotate(t.Context())
	if err != nil || !result.Recovered || result.CredentialID != pending.Pending.CredentialID {
		t.Fatalf("result=%#v err=%v", result, err)
	}
	promoted, err := credentials.Load(t.Context())
	if err != nil || promoted.Pending != nil || promoted.CredentialID != result.CredentialID {
		t.Fatalf("promoted=%#v err=%v", promoted, err)
	}
	if strings.Contains(result.CredentialID, promoted.Credential) {
		t.Fatal("rotation output exposed raw credential")
	}
}

func TestStatusAndDiagnoseExposeMetadataWithoutCredentialSecret(t *testing.T) {
	controlPlane := newInviteControlPlaneFixture(t)
	now := time.Now().UTC().Truncate(time.Second)
	stateStore := state.NewStore(t.TempDir())
	if err := stateStore.SaveLastKnown(lifecycleLastKnown()); err != nil {
		t.Fatal(err)
	}
	credentials := &credential.MemoryStore{}
	record := durableRecord(t, controlPlane.keys, now)
	if err := credentials.Save(t.Context(), record); err != nil {
		t.Fatal(err)
	}
	runtimeFake := &overlayruntime.Fake{}
	status, err := usecase.StatusWithCredential(t.Context(), stateStore, runtimeFake, credentials)
	if err != nil || !status.Credential.Present || status.Credential.CredentialID != record.CredentialID {
		t.Fatalf("status=%#v err=%v", status, err)
	}
	diagnostics, err := usecase.DiagnoseWithCredential(t.Context(), stateStore, runtimeFake, credentials)
	if err != nil {
		t.Fatalf("diagnose: %v", err)
	}
	raw, _ := json.Marshal(struct {
		Status      usecase.StatusResult       `json:"status"`
		Diagnostics []usecase.DiagnosticResult `json:"diagnostics"`
	}{status, diagnostics})
	if bytes.Contains(raw, []byte(record.Credential)) {
		t.Fatalf("metadata leaked protected credential: %s", raw)
	}
}

func durableRecord(t *testing.T, keys signedconfig.SigningKeys, now time.Time) credential.Record {
	t.Helper()
	secret, err := credential.GenerateWithReader(bytes.NewReader(bytes.Repeat([]byte{0x33}, 48)))
	if err != nil {
		t.Fatal(err)
	}
	return credential.Record{
		SchemaVersion: credential.SchemaVersion, Controller: "https://accounts.example", DeviceID: "dev_laptop", NetworkID: "net_private", Platform: "linux",
		WireGuardPublicKey: lifecycleLastKnown().WireGuardPublicKey, CredentialID: secret.CredentialID, Credential: secret.Value,
		IssuedAt: now.Add(-time.Minute), ExpiresAt: now.Add(30 * 24 * time.Hour), Scope: []string{credential.ScopeSessionMint, credential.ScopeRotate, credential.ScopeDeviceRevoke}, SigningKeys: keys,
	}
}
