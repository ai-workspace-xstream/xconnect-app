package main

import (
	"math"
	"runtime/debug"
	"testing"
)

func currentGCPercent() int {
	previous := debug.SetGCPercent(100)
	debug.SetGCPercent(previous)
	return previous
}

func TestResolveTunnelGovernorSettings(t *testing.T) {
	cases := []struct {
		name        string
		limitMB, gc int64
		wantLimit   int64
		wantGC      int
		wantErr     bool
	}{
		{name: "defaults", limitMB: -1, gc: -1, wantLimit: 64 << 20, wantGC: 40},
		{name: "zero removes the limit", limitMB: 0, gc: -1, wantLimit: math.MaxInt64, wantGC: 40},
		{name: "lower bounds", limitMB: 32, gc: 20, wantLimit: 32 << 20, wantGC: 20},
		{name: "upper bounds", limitMB: 256, gc: 200, wantLimit: 256 << 20, wantGC: 200},
		{name: "limit too small", limitMB: 31, gc: -1, wantErr: true},
		{name: "limit too large", limitMB: 257, gc: -1, wantErr: true},
		{name: "GC too small", limitMB: -1, gc: 19, wantErr: true},
		{name: "GC zero is not off", limitMB: -1, gc: 0, wantErr: true},
		{name: "GC too large", limitMB: -1, gc: 201, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveTunnelGovernorSettings(tc.limitMB, tc.gc)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %+v", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got.MemoryLimitBytes != tc.wantLimit || got.GCPercent != tc.wantGC {
				t.Fatalf("got %+v", got)
			}
		})
	}
}

func TestTunnelGovernorAppliesAndRestores(t *testing.T) {
	// A finite limit already in place must be lifted by "0", which
	// SetMemoryLimit(-1) cannot do: it only reads the current value.
	baselineLimit := int64(100 << 20)
	prevLimit := debug.SetMemoryLimit(baselineLimit)
	prevGC := debug.SetGCPercent(90)
	t.Cleanup(func() {
		stopTunnelMemoryGovernor()
		debug.SetMemoryLimit(prevLimit)
		debug.SetGCPercent(prevGC)
	})

	if err := startTunnelMemoryGovernor(tunnelGovernorSettings{
		MemoryLimitBytes: math.MaxInt64,
		GCPercent:        30,
	}); err != nil {
		t.Fatal(err)
	}
	if limit, gc := tunnelGovernorSnapshot(); limit != math.MaxInt64 || gc != 30 {
		t.Fatalf("active snapshot: limit=%d gc=%d", limit, gc)
	}
	if got := currentGCPercent(); got != 30 {
		t.Fatalf("GC percent = %d", got)
	}

	// A repeated start must not change the live session's pacing.
	err := startTunnelMemoryGovernor(tunnelGovernorSettings{
		MemoryLimitBytes: 48 << 20,
		GCPercent:        150,
	})
	if err != errTunnelGovernorActive {
		t.Fatalf("second start: %v", err)
	}
	if limit, gc := tunnelGovernorSnapshot(); limit != math.MaxInt64 || gc != 30 {
		t.Fatalf("second start changed the session: limit=%d gc=%d", limit, gc)
	}

	stopTunnelMemoryGovernor()
	if limit, gc := tunnelGovernorSnapshot(); limit != baselineLimit || gc != tunnelSettingUnset {
		t.Fatalf("after stop: limit=%d gc=%d", limit, gc)
	}
	if got := currentGCPercent(); got != 90 {
		t.Fatalf("GC percent not restored: %d", got)
	}
	// Stopping twice is harmless.
	stopTunnelMemoryGovernor()
}

func TestTunnelGovernorEnvFallsBackToDefaults(t *testing.T) {
	t.Setenv("XCONNECT_TUNNEL_MEM_LIMIT_MB", "9999")
	t.Setenv("XCONNECT_TUNNEL_GC_PERCENT", "50")
	got := tunnelGovernorSettingsFromEnv()
	if got.MemoryLimitBytes != tunnelMemoryLimitBytesDefault || got.GCPercent != tunnelGCPercentDefault {
		t.Fatalf("invalid env must fall back to defaults, got %+v", got)
	}

	t.Setenv("XCONNECT_TUNNEL_MEM_LIMIT_MB", "0")
	t.Setenv("XCONNECT_TUNNEL_GC_PERCENT", "60")
	got = tunnelGovernorSettingsFromEnv()
	if got.MemoryLimitBytes != math.MaxInt64 || got.GCPercent != 60 {
		t.Fatalf("valid env overrides lost: %+v", got)
	}
}
