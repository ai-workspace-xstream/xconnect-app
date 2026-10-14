package main

import (
	"errors"
	"fmt"
	"math"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// A NEPacketTunnelProvider runs under a jetsam footprint cap far tighter than
// a normal app's, and Go's default GC pacing plus its lazy scavenger keep more
// resident than the extension can afford. While a tunnel is up we therefore
// pace the GC harder and hand idle spans back to the OS on a timer, then
// restore the process defaults on stop.
const (
	// A backstop against unbounded drift, deliberately above the footprint
	// observed on device: a soft limit below the live heap makes the collector
	// run continuously, which costs more than it saves. The footprint is
	// actually reduced by the GC pacing and the scavenger below; tighten this
	// only once a soak has shown the Go runtime's real share of the process.
	tunnelMemoryLimitBytesDefault int64 = 64 << 20
	tunnelGCPercentDefault              = 40
	tunnelScavengeInterval              = 20 * time.Second
	// Below this much reclaimable idle heap a forced collection costs more CPU
	// than the footprint it wins back.
	tunnelScavengeMinIdleBytes uint64 = 4 << 20

	// tunnelSettingUnset asks for the built-in default.
	tunnelSettingUnset = -1

	// Accepted ranges for explicit settings. The memory limit is a soft cap on
	// the Go runtime only, not the process footprint; on iOS the extension's
	// jetsam cap is far lower than the upper bound and decides what is safe.
	tunnelMemoryLimitMinMB = 32
	tunnelMemoryLimitMaxMB = 256
	tunnelGCPercentMin     = 20
	tunnelGCPercentMax     = 200
)

// tunnelGovernorSettings holds the resolved runtime tuning for one tunnel
// session. MemoryLimitBytes of math.MaxInt64 means no soft limit.
type tunnelGovernorSettings struct {
	MemoryLimitBytes int64
	GCPercent        int
}

// resolveTunnelGovernorSettings validates explicit settings. A negative value
// selects the default; a memory limit of 0 removes the soft limit.
func resolveTunnelGovernorSettings(memoryLimitMB, gcPercent int64) (tunnelGovernorSettings, error) {
	settings := tunnelGovernorSettings{
		MemoryLimitBytes: tunnelMemoryLimitBytesDefault,
		GCPercent:        tunnelGCPercentDefault,
	}
	switch {
	case memoryLimitMB < 0:
	case memoryLimitMB == 0:
		settings.MemoryLimitBytes = math.MaxInt64
	case memoryLimitMB >= tunnelMemoryLimitMinMB && memoryLimitMB <= tunnelMemoryLimitMaxMB:
		settings.MemoryLimitBytes = memoryLimitMB << 20
	default:
		return settings, fmt.Errorf("memory limit %d MB outside 0 or %d-%d", memoryLimitMB, tunnelMemoryLimitMinMB, tunnelMemoryLimitMaxMB)
	}
	switch {
	case gcPercent < 0:
	case gcPercent >= tunnelGCPercentMin && gcPercent <= tunnelGCPercentMax:
		settings.GCPercent = int(gcPercent)
	default:
		return settings, fmt.Errorf("GC percent %d outside %d-%d", gcPercent, tunnelGCPercentMin, tunnelGCPercentMax)
	}
	return settings, nil
}

// tunnelGovernorSettingsFromEnv keeps the developer overrides of the legacy
// entry point. Values the Go runtime cannot see (for example a C setenv after
// start) simply fall back to the defaults; invalid ones are ignored.
func tunnelGovernorSettingsFromEnv() tunnelGovernorSettings {
	read := func(name string) int64 {
		value, err := strconv.ParseInt(os.Getenv(name), 10, 64)
		if err != nil {
			return tunnelSettingUnset
		}
		return value
	}
	settings, err := resolveTunnelGovernorSettings(
		read("XCONNECT_TUNNEL_MEM_LIMIT_MB"),
		read("XCONNECT_TUNNEL_GC_PERCENT"),
	)
	if err != nil {
		settings, _ = resolveTunnelGovernorSettings(tunnelSettingUnset, tunnelSettingUnset)
	}
	return settings
}

var (
	memoryGovernorMu      sync.Mutex
	memoryGovernorStop    chan struct{}
	memoryGovernorPrevGC  int
	memoryGovernorPrevLim int64

	// Effective values while a tunnel session is active, for diagnostics.
	memoryGovernorActiveGC atomic.Int64
)

var errTunnelGovernorActive = errors.New("tunnel memory governor already active")

// startTunnelMemoryGovernor applies settings for one tunnel session and
// records what to restore. It refuses to run twice, so a repeated start can
// never change the pacing of a live session.
func startTunnelMemoryGovernor(settings tunnelGovernorSettings) error {
	memoryGovernorMu.Lock()
	defer memoryGovernorMu.Unlock()
	if memoryGovernorStop != nil {
		return errTunnelGovernorActive
	}

	memoryGovernorPrevGC = debug.SetGCPercent(settings.GCPercent)
	// SetMemoryLimit returns the previous limit; math.MaxInt64 disables it.
	memoryGovernorPrevLim = debug.SetMemoryLimit(settings.MemoryLimitBytes)
	memoryGovernorActiveGC.Store(int64(settings.GCPercent))

	stop := make(chan struct{})
	memoryGovernorStop = stop
	go runTunnelScavenger(stop)
	return nil
}

// stopTunnelMemoryGovernor restores the pacing the process had before the
// tunnel started, both after a session and after a failed start.
func stopTunnelMemoryGovernor() {
	memoryGovernorMu.Lock()
	defer memoryGovernorMu.Unlock()
	if memoryGovernorStop == nil {
		return
	}
	close(memoryGovernorStop)
	memoryGovernorStop = nil
	debug.SetGCPercent(memoryGovernorPrevGC)
	debug.SetMemoryLimit(memoryGovernorPrevLim)
	memoryGovernorActiveGC.Store(tunnelSettingUnset)
}

// tunnelGovernorSnapshot reports the limit and GC percent in effect. GC
// percent is -1 when no tunnel session owns the pacing.
func tunnelGovernorSnapshot() (memoryLimitBytes int64, gcPercent int64) {
	// A negative argument only reads the current limit.
	return debug.SetMemoryLimit(-1), memoryGovernorActiveGC.Load()
}

func init() {
	memoryGovernorActiveGC.Store(tunnelSettingUnset)
}

func runTunnelScavenger(stop <-chan struct{}) {
	ticker := time.NewTicker(tunnelScavengeInterval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			var stats runtime.MemStats
			runtime.ReadMemStats(&stats)
			if stats.HeapIdle-stats.HeapReleased >= tunnelScavengeMinIdleBytes {
				debug.FreeOSMemory()
			}
		}
	}
}
