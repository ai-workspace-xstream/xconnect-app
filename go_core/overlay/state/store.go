package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"go_core/overlay/fault"
	"go_core/overlay/model"
)

const SchemaVersion = 1

var ErrNotFound = errors.New("overlay state not found")

type Phase string

const (
	PhaseStarted          Phase = "started"
	PhaseDeviceRegistered Phase = "device_registered"
	PhaseConfigFetched    Phase = "config_fetched"
	PhaseRuntimeApplied   Phase = "runtime_applied"
	PhaseAcknowledged     Phase = "acknowledged"
)

type Checkpoint struct {
	SchemaVersion       int           `json:"schema_version"`
	Server              string        `json:"server"`
	DeviceID            string        `json:"device_id"`
	DeviceName          string        `json:"device_name,omitempty"`
	Platform            string        `json:"platform,omitempty"`
	Hostname            string        `json:"hostname,omitempty"`
	NetworkID           string        `json:"network_id,omitempty"`
	NodeID              string        `json:"node_id,omitempty"`
	WireGuardPrivateKey string        `json:"wireguard_private_key"`
	WireGuardPublicKey  string        `json:"wireguard_public_key"`
	Phase               Phase         `json:"phase"`
	Config              *model.Config `json:"config,omitempty"`
	LastErrorCode       string        `json:"last_error_code,omitempty"`
	UpdatedAt           time.Time     `json:"updated_at"`
}

type LastKnown struct {
	SchemaVersion       int          `json:"schema_version"`
	Server              string       `json:"server"`
	DeviceID            string       `json:"device_id"`
	NetworkID           string       `json:"network_id"`
	NodeID              string       `json:"node_id,omitempty"`
	WireGuardPrivateKey string       `json:"wireguard_private_key"`
	WireGuardPublicKey  string       `json:"wireguard_public_key"`
	Phase               Phase        `json:"phase"`
	Config              model.Config `json:"config"`
	UpdatedAt           time.Time    `json:"updated_at"`
}

type Store struct {
	dir string
}

func NewStore(dir string) *Store { return &Store{dir: dir} }

func (s *Store) Directory() string { return s.dir }

func (s *Store) CheckpointPath() string {
	return filepath.Join(s.dir, "join-checkpoint.json")
}

func (s *Store) LastKnownPath() string {
	return filepath.Join(s.dir, "state.json")
}

func (s *Store) LoadCheckpoint() (Checkpoint, error) {
	var checkpoint Checkpoint
	if err := readJSON(s.CheckpointPath(), &checkpoint); err != nil {
		return Checkpoint{}, err
	}
	if checkpoint.SchemaVersion != SchemaVersion {
		return Checkpoint{}, fault.New(fault.CodeStateIO, "load join checkpoint", nil)
	}
	return checkpoint, nil
}

func (s *Store) SaveCheckpoint(checkpoint Checkpoint) error {
	checkpoint.SchemaVersion = SchemaVersion
	return writeJSON0600(s.CheckpointPath(), checkpoint)
}

func (s *Store) ClearCheckpoint() error {
	err := os.Remove(s.CheckpointPath())
	if err == nil || errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return fault.New(fault.CodeStateIO, "clear join checkpoint", err)
}

func (s *Store) LoadLastKnown() (LastKnown, error) {
	var lastKnown LastKnown
	if err := readJSON(s.LastKnownPath(), &lastKnown); err != nil {
		return LastKnown{}, err
	}
	if lastKnown.SchemaVersion != SchemaVersion {
		return LastKnown{}, fault.New(fault.CodeStateIO, "load last-known state", nil)
	}
	return lastKnown, nil
}

func (s *Store) SaveLastKnown(lastKnown LastKnown) error {
	lastKnown.SchemaVersion = SchemaVersion
	return writeJSON0600(s.LastKnownPath(), lastKnown)
}

func readJSON(path string, target any) error {
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	}
	if err != nil {
		return fault.New(fault.CodeStateIO, "open overlay state", err)
	}
	defer file.Close()
	decoder := json.NewDecoder(io.LimitReader(file, 2<<20))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return fault.New(fault.CodeStateIO, "decode overlay state", err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return fault.New(fault.CodeStateIO, "decode overlay state", err)
	}
	return nil
}

func writeJSON0600(path string, value any) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fault.New(fault.CodeStateIO, "create overlay state directory", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fault.New(fault.CodeStateIO, "secure overlay state directory", err)
	}
	temporary, err := os.CreateTemp(dir, ".xconnect-state-*")
	if err != nil {
		return fault.New(fault.CodeStateIO, "create overlay state file", err)
	}
	temporaryPath := temporary.Name()
	committed := false
	defer func() {
		_ = temporary.Close()
		if !committed {
			_ = os.Remove(temporaryPath)
		}
	}()
	if err := temporary.Chmod(0o600); err != nil {
		return fault.New(fault.CodeStateIO, "secure overlay state file", err)
	}
	encoder := json.NewEncoder(temporary)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(value); err != nil {
		return fault.New(fault.CodeStateIO, "encode overlay state", err)
	}
	if err := temporary.Sync(); err != nil {
		return fault.New(fault.CodeStateIO, "sync overlay state", err)
	}
	if err := temporary.Close(); err != nil {
		return fault.New(fault.CodeStateIO, "close overlay state", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fault.New(fault.CodeStateIO, "commit overlay state", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		return fault.New(fault.CodeStateIO, "secure committed overlay state", err)
	}
	committed = true
	return nil
}

func ValidatePermissions(path string, expected os.FileMode) error {
	info, err := os.Stat(path)
	if err != nil {
		return err
	}
	if got := info.Mode().Perm(); got != expected {
		return fmt.Errorf("permissions are %04o, want %04o", got, expected)
	}
	return nil
}
