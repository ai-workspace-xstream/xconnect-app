package state_test

import (
	"encoding/base64"
	"errors"
	"os"
	"testing"
	"time"

	"go_core/overlay/fault"
	"go_core/overlay/signedconfig"
	"go_core/overlay/state"
)

func TestCheckpointAndLastKnownUsePrivatePermissions(t *testing.T) {
	store := state.NewStore(t.TempDir() + "/nested")
	checkpoint := state.Checkpoint{
		Server:              "https://accounts.example",
		DeviceID:            "dev_laptop",
		WireGuardPrivateKey: "private",
		WireGuardPublicKey:  "public",
		Phase:               state.PhaseStarted,
		UpdatedAt:           time.Now().UTC(),
	}
	if err := store.SaveCheckpoint(checkpoint); err != nil {
		t.Fatalf("save checkpoint: %v", err)
	}
	if err := state.ValidatePermissions(store.CheckpointPath(), 0o600); err != nil {
		t.Fatalf("checkpoint permissions: %v", err)
	}
	info, err := os.Stat(store.Directory())
	if err != nil {
		t.Fatalf("stat state directory: %v", err)
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("state directory permissions = %04o", info.Mode().Perm())
	}
}

func TestSignedContractFloorIsPrivateMonotonicAndDowngradeLocked(t *testing.T) {
	store := state.NewStore(t.TempDir() + "/nested")
	now := time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC)
	const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if err := store.AcceptSignedConfig("https://accounts.example", "dev_laptop", "net_private", "cfg_42", digest, 42, now); err != nil {
		t.Fatalf("accept signed config: %v", err)
	}
	if err := store.AcceptSignedConfig("https://accounts.example", "dev_laptop", "net_private", "cfg_42", digest, 42, now); err != nil {
		t.Fatalf("repeat same signed config: %v", err)
	}
	locked, err := store.IsSignedLocked("https://accounts.example", "dev_laptop", "net_private")
	if err != nil || !locked {
		t.Fatal("signed config acceptance did not persist downgrade lock")
	}
	if err := state.ValidatePermissions(store.ContractStatePath(), 0o600); err != nil {
		t.Fatalf("contract floor permissions: %v", err)
	}
	for _, test := range []struct {
		name       string
		configID   string
		digest     string
		generation uint64
	}{
		{name: "older generation", configID: "cfg_41", digest: digest, generation: 41},
		{name: "same generation different config", configID: "cfg_other", digest: digest, generation: 42},
		{name: "same generation different payload", configID: "cfg_42", digest: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", generation: 42},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := store.AcceptSignedConfig("https://accounts.example", "dev_laptop", "net_private", test.configID, test.digest, test.generation, now)
			if fault.Code(err) != fault.CodeConfigReplay {
				t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
			}
		})
	}
}

func TestSigningKeyCacheIsScopedAndPrivate(t *testing.T) {
	store := state.NewStore(t.TempDir())
	notBefore := signedconfig.CanonicalTime{Time: time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)}
	notAfter := signedconfig.CanonicalTime{Time: time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)}
	cache := state.SigningKeyCache{
		Controller: "https://accounts.example",
		DeviceID:   "dev_laptop",
		ETag:       `"keys-1"`,
		FetchedAt:  time.Date(2026, 8, 27, 12, 0, 0, 0, time.UTC),
		Keys: signedconfig.SigningKeys{Keys: []signedconfig.SigningKey{{
			KeyID: "signing_key_01", Algorithm: signedconfig.SignatureEd25519,
			PublicKey: base64.StdEncoding.EncodeToString(make([]byte, 32)), Status: "current",
			NotBefore: notBefore, NotAfter: &notAfter,
		}}},
	}
	if err := store.SaveSigningKeyCache(cache); err != nil {
		t.Fatalf("save signing key cache: %v", err)
	}
	if err := state.ValidatePermissions(store.SigningKeyCachePath(), 0o600); err != nil {
		t.Fatalf("key cache permissions: %v", err)
	}
	loaded, err := store.LoadSigningKeyCache(cache.Controller, cache.DeviceID)
	if err != nil || loaded.ETag != cache.ETag || len(loaded.Keys.Keys) != 1 {
		t.Fatalf("loaded cache = %#v, err=%v", loaded, err)
	}
	if _, err := store.LoadSigningKeyCache(cache.Controller, "dev_other"); !errors.Is(err, state.ErrNotFound) {
		t.Fatalf("cross-device cache err=%v", err)
	}
}
