package state

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go_core/overlay/fault"
	"go_core/overlay/model"
	"go_core/overlay/signedconfig"
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
	ConfigContract      string        `json:"config_contract,omitempty"`
	SignedConfigID      string        `json:"signed_config_id,omitempty"`
	SignedGeneration    uint64        `json:"signed_generation,omitempty"`
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
	ConfigContract      string       `json:"config_contract,omitempty"`
	SignedConfigID      string       `json:"signed_config_id,omitempty"`
	SignedGeneration    uint64       `json:"signed_generation,omitempty"`
	UpdatedAt           time.Time    `json:"updated_at"`
}

type Store struct {
	dir string
}

type ContractBinding struct {
	Controller        string    `json:"controller"`
	DeviceID          string    `json:"device_id"`
	NetworkID         string    `json:"network_id"`
	SignedLocked      bool      `json:"signed_locked"`
	HighestGeneration uint64    `json:"highest_generation"`
	ConfigID          string    `json:"config_id"`
	PayloadSHA256     string    `json:"payload_sha256"`
	UpdatedAt         time.Time `json:"updated_at"`
}

type ContractState struct {
	SchemaVersion int               `json:"schema_version"`
	Bindings      []ContractBinding `json:"bindings"`
}

type SigningKeyCache struct {
	SchemaVersion int                      `json:"schema_version"`
	Controller    string                   `json:"controller"`
	DeviceID      string                   `json:"device_id"`
	ETag          string                   `json:"etag"`
	Keys          signedconfig.SigningKeys `json:"keys"`
	FetchedAt     time.Time                `json:"fetched_at"`
}

func NewStore(dir string) *Store { return &Store{dir: dir} }

func (s *Store) Directory() string { return s.dir }

func (s *Store) CheckpointPath() string {
	return filepath.Join(s.dir, "join-checkpoint.json")
}

func (s *Store) LastKnownPath() string {
	return filepath.Join(s.dir, "state.json")
}

func (s *Store) ContractStatePath() string {
	return filepath.Join(s.dir, "config-contract.json")
}

func (s *Store) SigningKeyCachePath() string {
	return filepath.Join(s.dir, "signing-keys.json")
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

func (s *Store) LoadContractState() (ContractState, error) {
	var contractState ContractState
	if err := readJSON(s.ContractStatePath(), &contractState); err != nil {
		return ContractState{}, err
	}
	if contractState.SchemaVersion != SchemaVersion {
		return ContractState{}, fault.New(fault.CodeStateIO, "load config-contract state", nil)
	}
	return contractState, nil
}

func (s *Store) IsSignedLocked(controller, deviceID, networkID string) (bool, error) {
	contractState, err := s.LoadContractState()
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	for _, binding := range contractState.Bindings {
		if binding.Controller == controller && binding.DeviceID == deviceID && binding.NetworkID == networkID {
			return binding.SignedLocked, nil
		}
	}
	return false, nil
}

func (s *Store) AcceptSignedConfig(controller, deviceID, networkID, configID, payloadSHA256 string, generation uint64, now time.Time) error {
	digest, digestErr := hex.DecodeString(payloadSHA256)
	if strings.TrimSpace(controller) == "" || strings.TrimSpace(deviceID) == "" || strings.TrimSpace(networkID) == "" || strings.TrimSpace(configID) == "" || generation == 0 || digestErr != nil || len(digest) != 32 || payloadSHA256 != strings.ToLower(payloadSHA256) {
		return fault.New(fault.CodeStateIO, "validate signed config floor", nil)
	}
	contractState, err := s.LoadContractState()
	if errors.Is(err, ErrNotFound) {
		contractState = ContractState{SchemaVersion: SchemaVersion}
	} else if err != nil {
		return err
	}
	for index := range contractState.Bindings {
		binding := &contractState.Bindings[index]
		if binding.Controller != controller || binding.DeviceID != deviceID || binding.NetworkID != networkID {
			continue
		}
		if generation < binding.HighestGeneration || generation == binding.HighestGeneration && (binding.ConfigID != configID || binding.PayloadSHA256 != payloadSHA256) {
			return fault.New(fault.CodeConfigReplay, "accept signed config generation", nil)
		}
		if generation > binding.HighestGeneration {
			binding.HighestGeneration = generation
			binding.ConfigID = configID
			binding.PayloadSHA256 = payloadSHA256
		}
		binding.SignedLocked = true
		binding.UpdatedAt = now.UTC()
		contractState.SchemaVersion = SchemaVersion
		return writeJSON0600(s.ContractStatePath(), contractState)
	}
	contractState.Bindings = append(contractState.Bindings, ContractBinding{
		Controller: controller, DeviceID: deviceID, NetworkID: networkID,
		SignedLocked: true, HighestGeneration: generation, ConfigID: configID, PayloadSHA256: payloadSHA256, UpdatedAt: now.UTC(),
	})
	contractState.SchemaVersion = SchemaVersion
	return writeJSON0600(s.ContractStatePath(), contractState)
}

func (s *Store) LoadSigningKeyCache(controller, deviceID string) (SigningKeyCache, error) {
	var cache SigningKeyCache
	if err := readJSON(s.SigningKeyCachePath(), &cache); err != nil {
		return SigningKeyCache{}, err
	}
	if cache.Controller != controller || cache.DeviceID != deviceID {
		return SigningKeyCache{}, ErrNotFound
	}
	if cache.SchemaVersion != SchemaVersion || strings.TrimSpace(cache.ETag) == "" {
		return SigningKeyCache{}, fault.New(fault.CodeStateIO, "load signing-key cache", nil)
	}
	if err := cache.Keys.Validate(); err != nil {
		return SigningKeyCache{}, fault.New(fault.CodeStateIO, "validate signing-key cache", err)
	}
	cache.Keys.ETag = cache.ETag
	return cache, nil
}

func (s *Store) SaveSigningKeyCache(cache SigningKeyCache) error {
	cache.SchemaVersion = SchemaVersion
	cache.Keys.ETag = ""
	return writeJSON0600(s.SigningKeyCachePath(), cache)
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
