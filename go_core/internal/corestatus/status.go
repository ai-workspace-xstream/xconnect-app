// Package corestatus carries startup state without connection credentials.
package corestatus

import (
	"encoding/json"
	"errors"
	"os"
	"syscall"
)

type Status struct {
	Phase        string `json:"phase"`
	WindowsError uint32 `json:"windowsError,omitempty"`
}

func Failure(err error) Status {
	status := Status{Phase: "core_start_failed"}
	var code syscall.Errno
	if errors.As(err, &code) {
		status.WindowsError = uint32(code)
	}
	return status
}

func Write(path string, status Status) error {
	data, err := json.Marshal(status)
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, data, 0600); err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		_ = os.Remove(temporary)
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func Read(path string) (Status, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Status{}, err
	}
	var status Status
	err = json.Unmarshal(data, &status)
	return status, err
}
