package corestatus

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestStatusReplacesPreviousGeneration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "startup.json")
	for _, want := range []Status{Failure(syscall.Errno(5)), {Phase: "ready"}} {
		if err := Write(path, want); err != nil {
			t.Fatal(err)
		}
		got, err := Read(path)
		if err != nil || got != want {
			t.Fatalf("got %+v, %v; want %+v", got, err, want)
		}
	}
}

func TestFailureDoesNotPersistConfiguration(t *testing.T) {
	status := Failure(fmt.Errorf("private-config-value: %w", syscall.Errno(5)))
	if status.WindowsError != 5 || status.Phase != "core_start_failed" {
		t.Fatalf("%+v", status)
	}
	path := filepath.Join(t.TempDir(), "startup.json")
	if err := Write(path, status); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "private-config-value") {
		t.Fatal("error details leaked")
	}
}
