package state_test

import (
	"os"
	"testing"
	"time"

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
