//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	"go_core/internal/corestatus"

	"golang.org/x/sys/windows"
)

const (
	seeMaskNoCloseProcess     = 0x00000040
	processQueryLimitedInfo   = 0x1000
	processSynchronize        = 0x00100000
	waitObject0               = 0
	waitTimeout               = 258
	windowsShowHide           = 0
	windowsRouteFamilyIPv4    = windows.AF_INET
	coreProcessRecordFileName = "core-process.json"
	coreConfigFileName        = "xray.json"
	coreExecutableFileName    = "xconnect-core.exe"
)

type shellExecuteInfo struct {
	cbSize       uint32
	fMask        uint32
	hwnd         windows.Handle
	lpVerb       *uint16
	lpFile       *uint16
	lpParameters *uint16
	lpDirectory  *uint16
	nShow        int32
	hInstApp     windows.Handle
	lpIDList     uintptr
	lpClass      *uint16
	hkeyClass    windows.Handle
	dwHotKey     uint32
	hIcon        windows.Handle
	hProcess     windows.Handle
}

type desktopCoreProcessRecord struct {
	PID        uint32 `json:"pid"`
	Executable string `json:"executable"`
}

var (
	shell32                = windows.NewLazySystemDLL("shell32.dll")
	procShellExecuteEx     = shell32.NewProc("ShellExecuteExW")
	coreProcessMu          sync.Mutex
	coreProcessHandle      windows.Handle
	coreProcessPID         uint32
	coreStatsMu            sync.Mutex
	lastCoreCPUProcessTime uint64
	lastCoreCPUWallTime    time.Time
)

func xconnectCorePath() (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	path := filepath.Join(filepath.Dir(executable), "bin", coreExecutableFileName)
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("desktop core is not packaged at %s: %w", path, err)
	}
	return path, nil
}

func coreRunDirectory() (string, error) {
	configDir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(configDir, "XConnect", "run")
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", err
	}
	return dir, nil
}

func materializeCoreConfig(configJSON []byte) (string, error) {
	dir, err := coreRunDirectory()
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, coreConfigFileName)
	temporary := path + ".tmp"
	if err := os.WriteFile(temporary, configJSON, 0600); err != nil {
		return "", err
	}
	// Windows rename does not replace an existing file.  Remove the old
	// generation only after the temporary file has been fully written.
	_ = os.Remove(path)
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return "", err
	}
	return path, nil
}

func coreProcessRecordPath() (string, error) {
	dir, err := coreRunDirectory()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, coreProcessRecordFileName), nil
}

func writeCoreProcessRecord(record desktopCoreProcessRecord) error {
	path, err := coreProcessRecordPath()
	if err != nil {
		return err
	}
	temporary := path + ".tmp"
	payload, err := json.Marshal(record)
	if err != nil {
		return err
	}
	if err := os.WriteFile(temporary, payload, 0600); err != nil {
		return err
	}
	_ = os.Remove(path)
	if err := os.Rename(temporary, path); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func readCoreProcessRecord() (desktopCoreProcessRecord, error) {
	path, err := coreProcessRecordPath()
	if err != nil {
		return desktopCoreProcessRecord{}, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return desktopCoreProcessRecord{}, err
	}
	var record desktopCoreProcessRecord
	if err := json.Unmarshal(data, &record); err != nil {
		return desktopCoreProcessRecord{}, err
	}
	return record, nil
}

func clearCoreProcessRecord(pid uint32) {
	path, err := coreProcessRecordPath()
	if err != nil {
		return
	}
	if pid != 0 {
		if record, err := readCoreProcessRecord(); err == nil && record.PID != pid {
			return
		}
	}
	_ = os.Remove(path)
}

func launchCore(corePath, configPath, statusPath, verbValue string) (windows.Handle, uint32, error) {
	verb, err := windows.UTF16PtrFromString(verbValue)
	if err != nil {
		return 0, 0, err
	}
	file, err := windows.UTF16PtrFromString(corePath)
	if err != nil {
		return 0, 0, err
	}
	parameters, err := windows.UTF16PtrFromString("-config " + windows.EscapeArg(configPath) + " -startup-status " + windows.EscapeArg(statusPath))
	if err != nil {
		return 0, 0, err
	}
	directory, err := windows.UTF16PtrFromString(filepath.Dir(corePath))
	if err != nil {
		return 0, 0, err
	}
	info := shellExecuteInfo{
		cbSize:       uint32(unsafe.Sizeof(shellExecuteInfo{})),
		fMask:        seeMaskNoCloseProcess,
		lpVerb:       verb,
		lpFile:       file,
		lpParameters: parameters,
		lpDirectory:  directory,
		nShow:        windowsShowHide,
	}
	result, _, callErr := procShellExecuteEx.Call(uintptr(unsafe.Pointer(&info)))
	if result == 0 {
		if callErr != nil && callErr != windows.ERROR_SUCCESS {
			return 0, 0, callErr
		}
		return 0, 0, windows.GetLastError()
	}
	if info.hProcess == 0 {
		return 0, 0, errors.New("ShellExecuteEx did not return a process handle")
	}
	pid, err := windows.GetProcessId(info.hProcess)
	if err != nil {
		_ = windows.CloseHandle(info.hProcess)
		return 0, 0, err
	}
	if pid == 0 {
		_ = windows.CloseHandle(info.hProcess)
		return 0, 0, windows.GetLastError()
	}
	return info.hProcess, pid, nil
}

func openCoreProcess(pid uint32) (windows.Handle, error) {
	if pid == 0 {
		return 0, nil
	}
	handle, err := windows.OpenProcess(
		processQueryLimitedInfo|processSynchronize,
		false,
		pid,
	)
	if errors.Is(err, windows.ERROR_INVALID_PARAMETER) {
		return 0, nil
	}
	return handle, err
}

func processIsRunning(handle windows.Handle) bool {
	if handle == 0 {
		return false
	}
	result, _ := windows.WaitForSingleObject(handle, 0)
	return result == waitTimeout
}

func processImagePath(handle windows.Handle) string {
	if handle == 0 {
		return ""
	}
	buffer := make([]uint16, windows.MAX_PATH)
	size := uint32(len(buffer))
	if err := windows.QueryFullProcessImageName(handle, 0, &buffer[0], &size); err != nil {
		return ""
	}
	return windows.UTF16ToString(buffer[:size])
}

func terminateCoreProcess(handle windows.Handle, pid uint32) error {
	if handle == 0 || !processIsRunning(handle) {
		return nil
	}
	if err := windows.TerminateProcess(handle, 0); err != nil {
		// The core is elevated for TUN setup.  A non-elevated UI may not have
		// PROCESS_TERMINATE access, so use the same elevated taskkill fallback
		// as OneXray's Windows implementation.
		if fallbackErr := terminateCorePIDElevated(pid); fallbackErr != nil {
			return fmt.Errorf("terminate core: %w; elevated fallback: %v", err, fallbackErr)
		}
	}
	result, _ := windows.WaitForSingleObject(handle, 5000)
	if result != waitObject0 {
		return errors.New("timed out waiting for desktop core to exit")
	}
	return nil
}

func terminateCorePIDElevated(pid uint32) error {
	taskkill, err := windows.UTF16PtrFromString(filepath.Join(os.Getenv("SystemRoot"), "System32", "taskkill.exe"))
	if err != nil {
		return err
	}
	parameters, err := windows.UTF16PtrFromString(fmt.Sprintf("/PID %d /T /F", pid))
	if err != nil {
		return err
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	info := shellExecuteInfo{
		cbSize:       uint32(unsafe.Sizeof(shellExecuteInfo{})),
		fMask:        seeMaskNoCloseProcess,
		lpVerb:       verb,
		lpFile:       taskkill,
		lpParameters: parameters,
		nShow:        windowsShowHide,
	}
	result, _, callErr := procShellExecuteEx.Call(uintptr(unsafe.Pointer(&info)))
	if result == 0 || info.hProcess == 0 {
		if callErr != nil && callErr != windows.ERROR_SUCCESS {
			return callErr
		}
		return windows.GetLastError()
	}
	defer windows.CloseHandle(info.hProcess)
	waitResult, _ := windows.WaitForSingleObject(info.hProcess, 5000)
	if waitResult != waitObject0 {
		return errors.New("timed out waiting for elevated taskkill")
	}
	var exitCode uint32
	if err := windows.GetExitCodeProcess(info.hProcess, &exitCode); err != nil {
		return err
	}
	if exitCode != 0 {
		return fmt.Errorf("elevated taskkill exited with code %d", exitCode)
	}
	return nil
}

func stopDesktopCoreLocked() error {
	handle := coreProcessHandle
	pid := coreProcessPID
	if handle == 0 {
		record, err := readCoreProcessRecord()
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("read recorded core: %w", err)
		}
		if err == nil {
			pid = record.PID
			handle, err = openCoreProcess(pid)
			if err != nil {
				return fmt.Errorf("open recorded core: %w", err)
			}
			if handle != 0 && processIsRunning(handle) {
				expected, pathErr := xconnectCorePath()
				image := processImagePath(handle)
				if pathErr != nil || image == "" {
					_ = windows.CloseHandle(handle)
					return errors.New("cannot verify recorded core process identity")
				}
				if !strings.EqualFold(image, record.Executable) {
					// The PID was reused by another executable.
					_ = windows.CloseHandle(handle)
					handle = 0
				} else if !strings.EqualFold(image, expected) {
					_ = windows.CloseHandle(handle)
					return errors.New("recorded core belongs to a different installation; stop that instance first")
				}
			}
		}
	}
	if handle == 0 {
		clearCoreProcessRecord(pid)
		return nil
	}
	// Retain ownership on a failed stop so the same handle can be retried.
	coreProcessHandle = handle
	coreProcessPID = pid
	if err := terminateCoreProcess(handle, pid); err != nil {
		return err
	}
	_ = windows.CloseHandle(handle)
	coreProcessHandle = 0
	coreProcessPID = 0
	clearCoreProcessRecord(pid)
	resetCoreCPUStats()
	return nil
}

func startDesktopCoreWithVerb(configJSON []byte, verb string) error {
	coreProcessMu.Lock()
	defer coreProcessMu.Unlock()
	if err := stopDesktopCoreLocked(); err != nil {
		return err
	}
	corePath, err := xconnectCorePath()
	if err != nil {
		return err
	}
	configPath, err := materializeCoreConfig(configJSON)
	if err != nil {
		return err
	}
	statusPath := filepath.Join(filepath.Dir(configPath), "startup.json")
	if err := os.Remove(statusPath); err != nil && !os.IsNotExist(err) {
		return err
	}
	if verb == "runas" {
		driver := filepath.Join(filepath.Dir(corePath), "wintun.dll")
		if info, err := os.Stat(driver); err != nil || info.IsDir() {
			return errors.New("packaged wintun.dll is missing beside the desktop core")
		}
	}
	handle, pid, err := launchCore(corePath, configPath, statusPath, verb)
	if err != nil {
		return err
	}
	coreProcessHandle = handle
	coreProcessPID = pid
	resetCoreCPUStats()
	if err := writeCoreProcessRecord(desktopCoreProcessRecord{PID: pid, Executable: corePath}); err != nil {
		_ = terminateCoreProcess(handle, pid)
		_ = windows.CloseHandle(handle)
		coreProcessHandle = 0
		coreProcessPID = 0
		return err
	}
	// A live process may still be initializing its native network resources.
	// Only the helper can acknowledge that RunXray completed successfully.
	// Snapshot polling must remain responsive while the helper initializes.
	// Exported start/stop operations are already serialized by instMu.
	// Polling can close the shared handle when a failed helper exits. Keep an
	// independent reference so startup can still retrieve its exit code.
	var startupHandle windows.Handle
	if err := windows.DuplicateHandle(windows.CurrentProcess(), handle,
		windows.CurrentProcess(), &startupHandle, 0, false, windows.DUPLICATE_SAME_ACCESS); err != nil {
		if stopErr := stopDesktopCoreLocked(); stopErr != nil {
			return fmt.Errorf("duplicate core handle: %w; cleanup: %v", err, stopErr)
		}
		return err
	}
	coreProcessMu.Unlock()
	startupErr := waitForCoreReady(startupHandle, statusPath, 12*time.Second)
	_ = windows.CloseHandle(startupHandle)
	coreProcessMu.Lock()
	if startupErr != nil {
		if stopErr := stopDesktopCoreLocked(); stopErr != nil {
			return fmt.Errorf("%w; cleanup: %v", startupErr, stopErr)
		}
		return startupErr
	}
	return nil
}

func waitForCoreReady(handle windows.Handle, statusPath string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		status, err := corestatus.Read(statusPath)
		running := processIsRunning(handle)
		if err == nil {
			if status.Phase == "ready" && running {
				return nil
			}
			if status.Phase == "core_start_failed" {
				return fmt.Errorf("core_start_failed (Windows error %d)", status.WindowsError)
			}
		}
		if !running {
			var code uint32
			if err := windows.GetExitCodeProcess(handle, &code); err != nil {
				return err
			}
			return fmt.Errorf("desktop core exited while starting (exit code %d)", code)
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("desktop core startup acknowledgement timed out")
}

func startDesktopCore(configJSON []byte) error {
	return startDesktopCoreWithVerb(configJSON, "runas")
}

func stopDesktopCore() error {
	coreProcessMu.Lock()
	defer coreProcessMu.Unlock()
	return stopDesktopCoreLocked()
}

func desktopCoreRunning() bool {
	coreProcessMu.Lock()
	defer coreProcessMu.Unlock()
	if coreProcessHandle != 0 {
		if processIsRunning(coreProcessHandle) {
			return true
		}
		_ = windows.CloseHandle(coreProcessHandle)
		clearCoreProcessRecord(coreProcessPID)
		coreProcessHandle = 0
		coreProcessPID = 0
		resetCoreCPUStats()
	}
	return false
}

type coreProcessMemoryCounters struct {
	CB                         uint32
	PageFaultCount             uint32
	PeakWorkingSetSize         uintptr
	WorkingSetSize             uintptr
	QuotaPeakPagedPoolUsage    uintptr
	QuotaPagedPoolUsage        uintptr
	QuotaPeakNonPagedPoolUsage uintptr
	QuotaNonPagedPoolUsage     uintptr
	PagefileUsage              uintptr
	PeakPagefileUsage          uintptr
}

func desktopCoreWorkingSetBytes() *int64 {
	coreProcessMu.Lock()
	defer coreProcessMu.Unlock()
	handle := coreProcessHandle
	if handle == 0 || !processIsRunning(handle) {
		return nil
	}
	psapi := windows.NewLazySystemDLL("psapi.dll")
	proc := psapi.NewProc("GetProcessMemoryInfo")
	counters := coreProcessMemoryCounters{CB: uint32(unsafe.Sizeof(coreProcessMemoryCounters{}))}
	result, _, _ := proc.Call(
		uintptr(handle),
		uintptr(unsafe.Pointer(&counters)),
		uintptr(counters.CB),
	)
	if result == 0 {
		return nil
	}
	value := int64(counters.WorkingSetSize)
	return &value
}

func filetimeToUint64(value windows.Filetime) uint64 {
	return uint64(value.HighDateTime)<<32 | uint64(value.LowDateTime)
}

func resetCoreCPUStats() {
	coreStatsMu.Lock()
	defer coreStatsMu.Unlock()
	lastCoreCPUProcessTime = 0
	lastCoreCPUWallTime = time.Time{}
}

func desktopCoreCPUPercent() *float64 {
	coreProcessMu.Lock()
	defer coreProcessMu.Unlock()
	handle := coreProcessHandle
	if handle == 0 || !processIsRunning(handle) {
		return nil
	}
	var creation, exit, kernel, user windows.Filetime
	if err := windows.GetProcessTimes(handle, &creation, &exit, &kernel, &user); err != nil {
		return nil
	}
	processTime := filetimeToUint64(kernel) + filetimeToUint64(user)
	now := time.Now()
	coreStatsMu.Lock()
	defer coreStatsMu.Unlock()
	if lastCoreCPUWallTime.IsZero() {
		lastCoreCPUWallTime = now
		lastCoreCPUProcessTime = processTime
		return nil
	}
	wallDelta := now.Sub(lastCoreCPUWallTime)
	processDelta := processTime - lastCoreCPUProcessTime
	lastCoreCPUWallTime = now
	lastCoreCPUProcessTime = processTime
	if wallDelta <= 0 {
		return nil
	}
	wallTicks := float64(wallDelta.Nanoseconds()) / 100
	if wallTicks <= 0 {
		return nil
	}
	percent := (float64(processDelta) / wallTicks) * 100
	if cpus := runtime.NumCPU(); cpus > 0 {
		percent /= float64(cpus)
	}
	if percent < 0 {
		percent = 0
	}
	return &percent
}

func windowsTunnelDefaultRoute(interfaceIndex int) bool {
	var table *windows.MibIpForwardTable2
	if errcode := windows.GetIpForwardTable2(windowsRouteFamilyIPv4, &table); errcode != nil || table == nil {
		return false
	}
	defer windows.FreeMibTable(unsafe.Pointer(table))
	for _, row := range table.Rows() {
		if row.InterfaceIndex != uint32(interfaceIndex) ||
			row.DestinationPrefix.PrefixLength != 0 ||
			row.DestinationPrefix.Prefix.Family != windows.AF_INET {
			continue
		}
		prefix := (*windows.RawSockaddrInet4)(unsafe.Pointer(&row.DestinationPrefix.Prefix))
		if prefix.Addr == [4]byte{} {
			return true
		}
	}
	return false
}
