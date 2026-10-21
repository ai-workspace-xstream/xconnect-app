//go:build windows

package main

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go_core/internal/corestatus"
	"golang.org/x/sys/windows"
)

func TestCoreReadyRequiresAcknowledgement(t *testing.T) {
	path := filepath.Join(t.TempDir(), "startup.json")
	handle := windows.CurrentProcess()
	if err := waitForCoreReady(handle, path, 60*time.Millisecond); err == nil {
		t.Fatal("a live process without acknowledgement was accepted")
	}
	if err := corestatus.Write(path, corestatus.Status{Phase: "ready"}); err != nil {
		t.Fatal(err)
	}
	if err := waitForCoreReady(handle, path, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestCoreStartupFailureReturnsSystemCode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "startup.json")
	if err := corestatus.Write(path, corestatus.Status{Phase: "core_start_failed", WindowsError: 5}); err != nil {
		t.Fatal(err)
	}
	err := waitForCoreReady(windows.CurrentProcess(), path, time.Second)
	if err == nil || !strings.Contains(err.Error(), "Windows error 5") {
		t.Fatalf("got %v", err)
	}
}

func TestCoreStartupMalformedStatusDoesNotReportSuccess(t *testing.T) {
	path := filepath.Join(t.TempDir(), "startup.json")
	if err := corestatus.Write(path, corestatus.Status{Phase: "unknown"}); err != nil {
		t.Fatal(err)
	}
	if err := waitForCoreReady(windows.CurrentProcess(), path, 60*time.Millisecond); err == nil {
		t.Fatal("unknown state accepted")
	}
}
