//go:build windows

package main

/*
#include <stdlib.h>
*/
import "C"
import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
	"unsafe"

	"github.com/getlantern/systray"
	"golang.org/x/sys/windows"
)

var procMap sync.Map
var instMu sync.Mutex

func clearNodeRegistry() {
	procMap.Range(func(key, value any) bool {
		procMap.Delete(key)
		return true
	})
}

type desktopRuntimeSnapshot struct {
	Running                   bool     `json:"running"`
	DownloadBytesPerSecond    *int     `json:"downloadBytesPerSecond,omitempty"`
	UploadBytesPerSecond      *int     `json:"uploadBytesPerSecond,omitempty"`
	MemoryBytes               *int64   `json:"memoryBytes,omitempty"`
	CPUPercent                *float64 `json:"cpuPercent,omitempty"`
	TunnelInterface           string   `json:"tunnelInterface,omitempty"`
	TunnelInterfaceUp         bool     `json:"tunnelInterfaceUp"`
	DefaultRouteThroughTunnel bool     `json:"defaultRouteThroughTunnel"`
	LastError                 string   `json:"lastError,omitempty"`
	UpdatedAt                 int64    `json:"updatedAt"`
}

const windowsTunnelInterfaceName = "XConnect"

type desktopIntegrationRequest struct {
	Action string `json:"action"`
}

type desktopIntegrationResponse struct {
	OK                 bool   `json:"ok"`
	Message            string `json:"message,omitempty"`
	DesktopEnvironment string `json:"desktopEnvironment,omitempty"`
	AutostartEnabled   bool   `json:"autostartEnabled,omitempty"`
	PrivilegeReady     bool   `json:"privilegeReady,omitempty"`
}

func desktopIntegrationResult(resp desktopIntegrationResponse) *C.char {
	data, err := json.Marshal(resp)
	if err != nil {
		return C.CString(`{"ok":false,"message":"failed to encode response"}`)
	}
	return C.CString(string(data))
}

// DesktopIntegrationCommand is a Linux-only desktop integration channel. The
// Dart FFI bindings load the symbol on every desktop platform, so Windows
// provides a harmless compatibility implementation rather than failing DLL
// initialization before a tunnel can be configured.
//
//export DesktopIntegrationCommand
func DesktopIntegrationCommand(requestC *C.char) *C.char {
	var req desktopIntegrationRequest
	if err := json.Unmarshal([]byte(C.GoString(requestC)), &req); err != nil {
		return desktopIntegrationResult(desktopIntegrationResponse{
			Message:            "invalid request: " + err.Error(),
			DesktopEnvironment: "windows",
		})
	}
	if req.Action == "getDesktopEnvironment" {
		return desktopIntegrationResult(desktopIntegrationResponse{
			OK:                 true,
			DesktopEnvironment: "windows",
			PrivilegeReady:     true,
		})
	}
	return desktopIntegrationResult(desktopIntegrationResponse{
		Message:            "desktop integration command is not supported on Windows",
		DesktopEnvironment: "windows",
	})
}

func windowsTunnelInterfaceState() (bool, bool, string) {
	iface, err := net.InterfaceByName(windowsTunnelInterfaceName)
	if err != nil {
		return false, false, "secure tunnel interface is unavailable"
	}
	if iface.Flags&net.FlagUp == 0 {
		return false, false, "secure tunnel interface is down"
	}

	if !windowsTunnelDefaultRoute(iface.Index) {
		return true, false, "secure tunnel default route is unavailable"
	}
	return true, true, ""
}

//export WriteConfigFiles
func WriteConfigFiles(xrayPath, xrayContent, servicePath, serviceContent, vpnPath, vpnContent, password *C.char) *C.char {
	if res := writeConfigFile(xrayPath, xrayContent); res != nil {
		return res
	}
	if res := writeConfigFile(servicePath, serviceContent); res != nil {
		return res
	}
	return updateVpnNodesConfig(vpnPath, vpnContent)
}

func writeConfigFile(pathC, contentC *C.char) *C.char {
	p := C.GoString(pathC)
	c := C.GoString(contentC)
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.WriteFile(p, []byte(c), 0644); err != nil {
		return C.CString("error:" + err.Error())
	}
	return nil
}

func updateVpnNodesConfig(pathC, contentC *C.char) *C.char {
	p := C.GoString(pathC)
	c := C.GoString(contentC)
	if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
		return C.CString("error:" + err.Error())
	}
	var nodes []map[string]interface{}
	if data, err := os.ReadFile(p); err == nil {
		json.Unmarshal(data, &nodes)
	}
	var newNodes []map[string]interface{}
	if err := json.Unmarshal([]byte(c), &newNodes); err != nil {
		return C.CString("error:" + err.Error())
	}
	nodes = append(nodes, newNodes...)
	out, err := json.MarshalIndent(nodes, "", "  ")
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.WriteFile(p, out, 0644); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("success")
}

//export CreateWindowsService
func CreateWindowsService(name, execPath, configPath *C.char) *C.char {
	return C.CString("error:not supported")
}

//export StartNodeService
func StartNodeService(name *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok && desktopCoreRunning() {
		return C.CString("success")
	}
	if desktopCoreRunning() {
		return C.CString("error:already running")
	}

	configPath := filepath.Join(os.TempDir(), node+".json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	// Proxy mode does not need a UAC transition.  TUN mode uses StartXray
	// below, which launches the same libXray helper with the "runas" verb.
	if err := startDesktopCoreWithVerb(data, "open"); err != nil {
		return C.CString("error:" + err.Error())
	}
	procMap.Store(node, true)
	return C.CString("success")
}

//export StopNodeService
func StopNodeService(name *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok {
		if desktopCoreRunning() {
			if err := stopDesktopCore(); err != nil {
				return C.CString("error:" + err.Error())
			}
		}
		procMap.Delete(node)
		return C.CString("success")
	}
	if desktopCoreRunning() {
		if err := stopDesktopCore(); err != nil {
			return C.CString("error:" + err.Error())
		}
	}
	clearNodeRegistry()
	return C.CString("success")
}

//export CheckNodeStatus
func CheckNodeStatus(name *C.char) C.int {
	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok && desktopCoreRunning() {
		return 1
	}
	return 0
}

//export PerformAction
func PerformAction(action, password *C.char) *C.char {
	act := C.GoString(action)
	if act == "isXrayDownloading" {
		return C.CString("0")
	}
	return C.CString("error:unsupported")
}

//export IsXrayDownloading
func IsXrayDownloading() C.int { return 0 }

//export StartXray
func StartXray(configC *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	cfgData := []byte(C.GoString(configC))
	if err := startDesktopCore(cfgData); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("success")
}

//export StopXray
func StopXray() *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	if !desktopCoreRunning() {
		return C.CString("error:not running")
	}
	if err := stopDesktopCore(); err != nil {
		return C.CString("error:" + err.Error())
	}
	clearNodeRegistry()
	return C.CString("success")
}

//export GetDesktopRuntimeSnapshot
func GetDesktopRuntimeSnapshot() *C.char {
	interfaceUp, defaultRoute, lastError := windowsTunnelInterfaceState()
	running := desktopCoreRunning()
	if !running {
		interfaceUp = false
		defaultRoute = false
		lastError = ""
	}
	snapshot := desktopRuntimeSnapshot{
		Running:                   running,
		MemoryBytes:               desktopCoreWorkingSetBytes(),
		CPUPercent:                desktopCoreCPUPercent(),
		TunnelInterface:           windowsTunnelInterfaceName,
		TunnelInterfaceUp:         interfaceUp,
		DefaultRouteThroughTunnel: defaultRoute,
		LastError:                 lastError,
		UpdatedAt:                 time.Now().UnixMilli(),
	}
	payload, err := json.Marshal(snapshot)
	if err != nil {
		return C.CString("{}")
	}
	return C.CString(string(payload))
}

// ---- System tray integration ----

var trayOnce sync.Once
var windowHandle windows.Handle

var (
	user32                  = windows.NewLazySystemDLL("user32.dll")
	procFindWindowW         = user32.NewProc("FindWindowW")
	procShowWindow          = user32.NewProc("ShowWindow")
	procGetWindowPlacement  = user32.NewProc("GetWindowPlacement")
	procSetForegroundWindow = user32.NewProc("SetForegroundWindow")
)

type point struct {
	X int32
	Y int32
}

type rect struct {
	Left   int32
	Top    int32
	Right  int32
	Bottom int32
}

type windowPlacement struct {
	Length         uint32
	Flags          uint32
	ShowCmd        uint32
	MinPosition    point
	MaxPosition    point
	NormalPosition rect
}

func findMainWindow() windows.Handle {
	title, _ := windows.UTF16PtrFromString("xconnect")
	h, _, _ := procFindWindowW.Call(0, uintptr(unsafe.Pointer(title)))
	return windows.Handle(h)
}

func showWindow(h windows.Handle, cmd int32) {
	procShowWindow.Call(uintptr(h), uintptr(cmd))
}

func getPlacement(h windows.Handle, wp *windowPlacement) bool {
	r, _, _ := procGetWindowPlacement.Call(uintptr(h), uintptr(unsafe.Pointer(wp)))
	return r != 0
}

func monitorMinimize() {
	for {
		if windowHandle == 0 {
			windowHandle = findMainWindow()
		}
		if windowHandle != 0 {
			var wp windowPlacement
			wp.Length = uint32(unsafe.Sizeof(wp))
			if getPlacement(windowHandle, &wp) {
				if wp.ShowCmd == windows.SW_SHOWMINIMIZED {
					showWindow(windowHandle, windows.SW_HIDE)
				}
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
}

func onTrayReady() {
	icon, err := os.ReadFile("data/flutter_assets/assets/logo.png")
	if err == nil {
		systray.SetIcon(icon)
	}
	mShow := systray.AddMenuItem("Show", "Show window")
	mQuit := systray.AddMenuItem("Quit", "Quit")
	go func() {
		for {
			select {
			case <-mShow.ClickedCh:
				if windowHandle == 0 {
					windowHandle = findMainWindow()
				}
				if windowHandle != 0 {
					showWindow(windowHandle, windows.SW_RESTORE)
					procSetForegroundWindow.Call(uintptr(windowHandle))
				}
			case <-mQuit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
	go monitorMinimize()
}

//export InitTray
func InitTray() {
	trayOnce.Do(func() {
		go func() {
			runtime.LockOSThread()
			systray.Run(onTrayReady, func() {})
		}()
	})
}
