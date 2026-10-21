//go:build windows

package tun

import (
	"errors"
	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
	"testing"
)

func TestXConnectReusesAnAvailableAdapter(t *testing.T) {
	want := new(wintun.Adapter)
	got, err := openWithFunctions("XConnect", "Xray", func(string) (*wintun.Adapter, error) { return want, nil }, func(string, string, *windows.GUID) (*wintun.Adapter, error) {
		t.Fatal("reusable adapter was recreated")
		return nil, nil
	})
	if err != nil || got != want {
		t.Fatalf("got %p, %v", got, err)
	}
}
func TestXConnectAllocatesFreshIdentityOnlyForGUIDCollision(t *testing.T) {
	for _, failure := range []error{windows.ERROR_ALREADY_EXISTS, windows.ERROR_FILE_NOT_FOUND, windows.ERROR_ACCESS_DENIED} {
		collision := !errors.Is(failure, windows.ERROR_ACCESS_DENIED)
		calls := 0
		want := new(wintun.Adapter)
		got, err := openWithFunctions("XConnect", "Xray", func(string) (*wintun.Adapter, error) { return nil, windows.ERROR_FILE_NOT_FOUND }, func(name, desc string, guid *windows.GUID) (*wintun.Adapter, error) {
			calls++
			if calls == 1 {
				if guid == nil {
					t.Fatal("first creation lost stable identity")
				}
				return nil, failure
			}
			if name != "XConnect" || guid != nil {
				t.Fatal("collision fallback changed name or reused GUID")
			}
			return want, nil
		})
		if collision {
			if calls != 2 || err != nil || got != want {
				t.Fatalf("collision: calls=%d got=%p err=%v", calls, got, err)
			}
		} else if calls != 1 || !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
			t.Fatalf("access failure was retried: %d, %v", calls, err)
		}
	}
}

func TestXConnectOpenPermissionFailureDoesNotCreate(t *testing.T) {
	_, err := openWithFunctions("XConnect", "Xray", func(string) (*wintun.Adapter, error) { return nil, windows.ERROR_ACCESS_DENIED }, func(string, string, *windows.GUID) (*wintun.Adapter, error) {
		t.Fatal("permission failure caused creation")
		return nil, nil
	})
	if !errors.Is(err, windows.ERROR_ACCESS_DENIED) {
		t.Fatalf("got %v", err)
	}
}
