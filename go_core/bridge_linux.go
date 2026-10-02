//go:build linux && !android

package main

/*
#cgo pkg-config: gtk+-3.0 x11
#include <stdlib.h>
#include <string.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

// All state and GTK calls below are confined to GTK's existing main loop.
static GtkWindow* trayWindow = NULL;
static gboolean trayInitialized = FALSE;
static gboolean trayWindowHidden = FALSE;
static gboolean trayQuitRequested = FALSE;
static GDBusConnection* notifierBus = NULL;

static gboolean restoreTrayWindow(gpointer unused) {
    if (trayWindow != NULL) {
        gtk_widget_show(GTK_WIDGET(trayWindow));
        gtk_window_deiconify(trayWindow);
        gtk_window_present(trayWindow);
        trayWindowHidden = FALSE;
    }
    return G_SOURCE_REMOVE;
}

static gboolean trayHostPresent() {
    if (!trayInitialized || trayWindow == NULL) return FALSE;
#ifdef GDK_WINDOWING_X11
    GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(trayWindow));
    if (!GDK_IS_X11_DISPLAY(display)) return FALSE;
    gchar* selection = g_strdup_printf("_NET_SYSTEM_TRAY_S%d",
        DefaultScreen(GDK_DISPLAY_XDISPLAY(display)));
    gboolean legacyHost = gdk_selection_owner_get_for_display(display,
        gdk_atom_intern(selection, FALSE)) != NULL;
    g_free(selection);
    if (legacyHost) return TRUE;
    if (notifierBus != NULL) {
        GVariant* reply = g_dbus_connection_call_sync(notifierBus,
            "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
            "org.freedesktop.DBus.Properties", "Get",
            g_variant_new("(ss)", "org.kde.StatusNotifierWatcher",
                          "IsStatusNotifierHostRegistered"),
            G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 200, NULL, NULL);
        if (reply != NULL) {
            GVariant* value = NULL;
            g_variant_get(reply, "(v)", &value);
            gboolean available = g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN)
                && g_variant_get_boolean(value);
            g_variant_unref(value);
            g_variant_unref(reply);
            return available;
        }
    }
#endif
    return FALSE;
}

static gboolean trayWindowStateEvent(GtkWidget* widget,
                                    GdkEventWindowState* event, gpointer unused) {
    if ((event->changed_mask & GDK_WINDOW_STATE_ICONIFIED) &&
        (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) &&
        trayHostPresent()) {
        gtk_widget_hide(widget);
        trayWindowHidden = TRUE;
    }
    return FALSE;
}

// Treat the window-manager close button like macOS window close: keep the
// process, tray and network runtime alive. A real tray host gets a hidden
// window; without one, iconify it so the app remains recoverable from the
// desktop task list instead of becoming invisible.
static gboolean trayWindowDeleteEvent(GtkWidget* widget,
                                     GdkEvent* event, gpointer unused) {
    if (trayQuitRequested) return FALSE;
    if (trayHostPresent()) {
        gtk_widget_hide(widget);
        trayWindowHidden = TRUE;
    } else {
        gtk_window_iconify(GTK_WINDOW(widget));
    }
    return TRUE;
}

static void registerTrayWindow(void* window) {
    trayWindow = GTK_WINDOW(window);
    g_object_add_weak_pointer(G_OBJECT(trayWindow), (gpointer*)&trayWindow);
    g_signal_connect(trayWindow, "window-state-event",
                     G_CALLBACK(trayWindowStateEvent), NULL);
    g_signal_connect(trayWindow, "delete-event",
                     G_CALLBACK(trayWindowDeleteEvent), NULL);
}

static void notifierAppeared(GDBusConnection* bus, const gchar* name,
                            const gchar* owner, gpointer unused) {
    g_set_object(&notifierBus, bus);
}

static void notifierVanished(GDBusConnection* bus, const gchar* name,
                            gpointer unused) {
    g_clear_object(&notifierBus);
    if (trayWindowHidden) restoreTrayWindow(NULL);
}

static gboolean ensureTrayWindowRecoverable(gpointer unused) {
    if (trayWindow == NULL) return G_SOURCE_REMOVE;
    if (trayWindowHidden && !trayHostPresent()) restoreTrayWindow(NULL);
    return G_SOURCE_CONTINUE;
}

static gboolean enableTrayWindowHiding(gpointer unused) {
    trayInitialized = TRUE;
    g_bus_watch_name(G_BUS_TYPE_SESSION, "org.kde.StatusNotifierWatcher",
        G_BUS_NAME_WATCHER_FLAGS_NONE, notifierAppeared, notifierVanished,
        NULL, NULL);
    g_timeout_add_seconds(2, ensureTrayWindowRecoverable, NULL);
    return G_SOURCE_REMOVE;
}

static gboolean closeTrayWindow(gpointer unused) {
    if (trayWindow != NULL) {
        trayQuitRequested = TRUE;
        gtk_window_close(trayWindow);
    }
    return G_SOURCE_REMOVE;
}

extern void InitializeLinuxTrayOnMainThread(void);
static gboolean initializeTrayOnMainThread(gpointer unused) {
    InitializeLinuxTrayOnMainThread();
    return G_SOURCE_REMOVE;
}

static void scheduleTrayInit() { g_idle_add(initializeTrayOnMainThread, NULL); }
static void scheduleTrayReady() { g_idle_add(enableTrayWindowHiding, NULL); }
static void scheduleTrayShow() { g_idle_add(restoreTrayWindow, NULL); }
static void scheduleTrayClose() { g_idle_add(closeTrayWindow, NULL); }
*/
import "C"
import (
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/getlantern/systray"
	"github.com/xtls/libxray/xray"
)

var procMap sync.Map
var instMu sync.Mutex

const linuxTunnelInterfaceName = "xconnect-tun0"

type desktopRuntimeSnapshot struct {
	Running                   bool   `json:"running"`
	TunnelInterface           string `json:"tunnelInterface,omitempty"`
	TunnelInterfaceUp         bool   `json:"tunnelInterfaceUp"`
	DefaultRouteThroughTunnel bool   `json:"defaultRouteThroughTunnel"`
	LastError                 string `json:"lastError,omitempty"`
	UpdatedAt                 int64  `json:"updatedAt"`
}

func linuxTunnelInterfaceState() (bool, bool, string) {
	iface, err := net.InterfaceByName(linuxTunnelInterfaceName)
	if err != nil {
		return false, false, "secure tunnel interface is unavailable"
	}
	if iface.Flags&net.FlagUp == 0 {
		return false, false, "secure tunnel interface is down"
	}

	// Xray's automatic route mode can use a policy table, so inspect every
	// table rather than assuming that the main table owns the default route.
	output, err := runOutput("ip", "route", "show", "table", "all", "default", "dev", linuxTunnelInterfaceName)
	if err != nil || strings.TrimSpace(output) == "" {
		return true, false, "secure tunnel default route is unavailable"
	}
	return true, true, ""
}

type desktopIntegrationRequest struct {
	Action   string `json:"action"`
	Enable   bool   `json:"enable,omitempty"`
	ExecPath string `json:"execPath,omitempty"`
	Title    string `json:"title,omitempty"`
	Body     string `json:"body,omitempty"`
	Mode     string `json:"mode,omitempty"`
}

type desktopIntegrationResponse struct {
	OK                 bool   `json:"ok"`
	Message            string `json:"message,omitempty"`
	DesktopEnvironment string `json:"desktopEnvironment,omitempty"`
	AutostartEnabled   bool   `json:"autostartEnabled,omitempty"`
	PrivilegeReady     bool   `json:"privilegeReady,omitempty"`
	HelperPath         string `json:"helperPath,omitempty"`
}

func startXrayInternal(cfgData []byte) error {
	if xray.GetXrayState() {
		return errors.New("already running")
	}
	return xray.RunXrayFromJSON(string(cfgData))
}

func stopXrayInternal() error {
	if !xray.GetXrayState() {
		return errors.New("not running")
	}
	return xray.StopXray()
}

func clearNodeRegistry() {
	procMap.Range(func(key, value any) bool {
		procMap.Delete(key)
		return true
	})
}

func desktopIntegrationResult(resp desktopIntegrationResponse) *C.char {
	data, err := json.Marshal(resp)
	if err != nil {
		return C.CString(`{"ok":false,"message":"failed to encode response"}`)
	}
	return C.CString(string(data))
}

func detectDesktopEnvironment() string {
	candidates := []string{
		strings.ToLower(os.Getenv("XDG_CURRENT_DESKTOP")),
		strings.ToLower(os.Getenv("DESKTOP_SESSION")),
		strings.ToLower(os.Getenv("XDG_SESSION_DESKTOP")),
	}
	for _, candidate := range candidates {
		switch {
		case strings.Contains(candidate, "gnome"), strings.Contains(candidate, "ubuntu"), strings.Contains(candidate, "unity"):
			return "gnome"
		case strings.Contains(candidate, "kde"), strings.Contains(candidate, "plasma"):
			return "kde"
		}
	}
	return "unknown"
}

func runOutput(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(output)), err
}

func linuxConfigDir() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".config", "xconnect")
	}
	return filepath.Join(dir, "xconnect")
}

func linuxAutostartDesktopFile() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".config", "autostart", "xconnect.desktop")
	}
	return filepath.Join(dir, "autostart", "xconnect.desktop")
}

func linuxProxySnapshotPath() string {
	return filepath.Join(linuxConfigDir(), "linux_proxy_snapshot.json")
}

func linuxTunnelHelperPath() string {
	candidates := []string{
		"/usr/libexec/xconnect/xconnect-net-helper",
		filepath.Join(filepath.Dir(os.Args[0]), "xconnect-net-helper"),
		filepath.Join(filepath.Dir(os.Args[0]), "..", "libexec", "xconnect", "xconnect-net-helper"),
		"scripts/linux/xconnect-net-helper",
	}
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}

func notifyDesktop(title, body string) error {
	if _, err := exec.LookPath("notify-send"); err != nil {
		return err
	}
	_, err := runOutput("notify-send", title, body)
	return err
}

func setAutostartEnabled(enable bool, execPath string) error {
	desktopFile := linuxAutostartDesktopFile()
	if enable {
		if execPath == "" {
			execPath = "/opt/xconnect/xconnect"
		}
		if err := os.MkdirAll(filepath.Dir(desktopFile), 0755); err != nil {
			return err
		}
		content := strings.Join([]string{
			"[Desktop Entry]",
			"Type=Application",
			"Version=1.0",
			"Name=XConnect",
			"Comment=XConnect desktop launcher",
			"Exec=" + execPath,
			"Icon=xconnect",
			"Terminal=false",
			"Categories=Network;Utility;",
			"X-GNOME-Autostart-enabled=true",
			"",
		}, "\n")
		return os.WriteFile(desktopFile, []byte(content), 0644)
	}
	if err := os.Remove(desktopFile); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func isAutostartEnabled() bool {
	_, err := os.Stat(linuxAutostartDesktopFile())
	return err == nil
}

func writeProxySnapshot(data map[string]string) error {
	if err := os.MkdirAll(filepath.Dir(linuxProxySnapshotPath()), 0755); err != nil {
		return err
	}
	raw, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(linuxProxySnapshotPath(), raw, 0644)
}

func readProxySnapshot() map[string]string {
	raw, err := os.ReadFile(linuxProxySnapshotPath())
	if err != nil {
		return map[string]string{}
	}
	var data map[string]string
	if err := json.Unmarshal(raw, &data); err != nil {
		return map[string]string{}
	}
	return data
}

func gsettingsGet(schema string, key string) string {
	output, err := runOutput("gsettings", "get", schema, key)
	if err != nil {
		return ""
	}
	return output
}

func gsettingsSet(schema string, key string, value string) error {
	_, err := runOutput("gsettings", "set", schema, key, value)
	return err
}

func kdeConfigTool() string {
	for _, candidate := range []string{"kwriteconfig6", "kwriteconfig5", "kwriteconfig"} {
		if _, err := exec.LookPath(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func kreadConfigTool() string {
	for _, candidate := range []string{"kreadconfig6", "kreadconfig5", "kreadconfig"} {
		if _, err := exec.LookPath(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func reloadKDEProxy() {
	if _, err := exec.LookPath("qdbus"); err == nil {
		_, _ = runOutput("qdbus", "org.kde.KIO.Scheduler", "/KIO/Scheduler", "org.kde.KIO.Scheduler.reparseSlaveConfiguration", "")
		return
	}
	if _, err := exec.LookPath("dbus-send"); err == nil {
		_, _ = runOutput("dbus-send", "--session", "--dest=org.kde.KIO.Scheduler", "--type=method_call", "/KIO/Scheduler", "org.kde.KIO.Scheduler.reparseSlaveConfiguration")
	}
}

func setLinuxProxy(enable bool) error {
	desktop := detectDesktopEnvironment()
	switch desktop {
	case "gnome":
		if enable {
			snapshot := map[string]string{
				"desktop":   "gnome",
				"mode":      gsettingsGet("org.gnome.system.proxy", "mode"),
				"socksHost": gsettingsGet("org.gnome.system.proxy.socks", "host"),
				"socksPort": gsettingsGet("org.gnome.system.proxy.socks", "port"),
				"httpHost":  gsettingsGet("org.gnome.system.proxy.http", "host"),
				"httpPort":  gsettingsGet("org.gnome.system.proxy.http", "port"),
			}
			if err := writeProxySnapshot(snapshot); err != nil {
				return err
			}
			for _, op := range []struct {
				schema string
				key    string
				value  string
			}{
				{"org.gnome.system.proxy", "mode", "'manual'"},
				{"org.gnome.system.proxy.socks", "host", "'127.0.0.1'"},
				{"org.gnome.system.proxy.socks", "port", "1080"},
				{"org.gnome.system.proxy.http", "host", "'127.0.0.1'"},
				{"org.gnome.system.proxy.http", "port", "1081"},
			} {
				if err := gsettingsSet(op.schema, op.key, op.value); err != nil {
					return err
				}
			}
			return nil
		}
		snapshot := readProxySnapshot()
		mode := snapshot["mode"]
		if mode == "" {
			mode = "'none'"
		}
		for _, op := range []struct {
			schema string
			key    string
			value  string
		}{
			{"org.gnome.system.proxy", "mode", mode},
			{"org.gnome.system.proxy.socks", "host", "'" + strings.Trim(snapshot["socksHost"], "'") + "'"},
			{"org.gnome.system.proxy.socks", "port", defaultIfEmpty(snapshot["socksPort"], "0")},
			{"org.gnome.system.proxy.http", "host", "'" + strings.Trim(snapshot["httpHost"], "'") + "'"},
			{"org.gnome.system.proxy.http", "port", defaultIfEmpty(snapshot["httpPort"], "0")},
		} {
			if op.value == "" {
				continue
			}
			if err := gsettingsSet(op.schema, op.key, op.value); err != nil {
				return err
			}
		}
		return nil
	case "kde":
		writer := kdeConfigTool()
		reader := kreadConfigTool()
		if writer == "" {
			return errors.New("kwriteconfig is required for KDE proxy integration")
		}
		if enable {
			snapshot := map[string]string{"desktop": "kde"}
			if reader != "" {
				for _, item := range []struct {
					key   string
					group string
					name  string
				}{
					{"ProxyType", "Proxy Settings", "ProxyType"},
					{"httpProxy", "Proxy Settings", "httpProxy"},
					{"socksProxy", "Proxy Settings", "socksProxy"},
				} {
					value, _ := runOutput(reader, "--file", "kioslaverc", "--group", item.group, "--key", item.name)
					snapshot[item.key] = value
				}
			}
			if err := writeProxySnapshot(snapshot); err != nil {
				return err
			}
			for _, args := range [][]string{
				{"--file", "kioslaverc", "--group", "Proxy Settings", "--key", "ProxyType", "1"},
				{"--file", "kioslaverc", "--group", "Proxy Settings", "--key", "httpProxy", "http://127.0.0.1 1081"},
				{"--file", "kioslaverc", "--group", "Proxy Settings", "--key", "socksProxy", "socks://127.0.0.1 1080"},
			} {
				if _, err := runOutput(writer, args...); err != nil {
					return err
				}
			}
			reloadKDEProxy()
			return nil
		}
		snapshot := readProxySnapshot()
		proxyType := defaultIfEmpty(snapshot["ProxyType"], "0")
		httpProxy := snapshot["httpProxy"]
		socksProxy := snapshot["socksProxy"]
		for _, args := range [][]string{
			{"--file", "kioslaverc", "--group", "Proxy Settings", "--key", "ProxyType", proxyType},
			{"--file", "kioslaverc", "--group", "Proxy Settings", "--key", "httpProxy", httpProxy},
			{"--file", "kioslaverc", "--group", "Proxy Settings", "--key", "socksProxy", socksProxy},
		} {
			if _, err := runOutput(writer, args...); err != nil {
				return err
			}
		}
		reloadKDEProxy()
		return nil
	default:
		return errors.New("unsupported desktop environment")
	}
}

func defaultIfEmpty(value string, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func handleTunnelHelper(action string, mode string) (string, error) {
	helper := linuxTunnelHelperPath()
	if helper == "" {
		return "", errors.New("xconnect-net-helper not found")
	}
	if _, err := exec.LookPath("pkexec"); err != nil {
		return helper, errors.New("pkexec not found")
	}
	args := []string{helper, action}
	if mode != "" {
		args = append(args, "--mode", mode)
	}
	output, err := runOutput("pkexec", args...)
	if err != nil {
		return helper, errors.New(strings.TrimSpace(output))
	}
	return helper, nil
}

//export DesktopIntegrationCommand
func DesktopIntegrationCommand(requestC *C.char) *C.char {
	var req desktopIntegrationRequest
	if err := json.Unmarshal([]byte(C.GoString(requestC)), &req); err != nil {
		return desktopIntegrationResult(desktopIntegrationResponse{
			OK:      false,
			Message: "invalid request: " + err.Error(),
		})
	}

	resp := desktopIntegrationResponse{
		OK:                 true,
		DesktopEnvironment: detectDesktopEnvironment(),
		AutostartEnabled:   isAutostartEnabled(),
	}

	switch req.Action {
	case "getDesktopEnvironment":
		resp.PrivilegeReady = linuxTunnelHelperPath() != ""
	case "setSystemProxy":
		if err := setLinuxProxy(true); err != nil {
			resp.OK = false
			resp.Message = err.Error()
		} else {
			resp.Message = "system proxy enabled"
		}
	case "clearSystemProxy":
		if err := setLinuxProxy(false); err != nil {
			resp.OK = false
			resp.Message = err.Error()
		} else {
			resp.Message = "system proxy restored"
		}
	case "setAutostartEnabled":
		if err := setAutostartEnabled(req.Enable, req.ExecPath); err != nil {
			resp.OK = false
			resp.Message = err.Error()
		} else {
			resp.AutostartEnabled = req.Enable
			resp.Message = "autostart updated"
		}
	case "isAutostartEnabled":
		resp.Message = "autostart status loaded"
	case "ensureTunnelPrivileges":
		helper := linuxTunnelHelperPath()
		resp.HelperPath = helper
		if helper == "" {
			resp.OK = false
			resp.Message = "xconnect-net-helper not found"
			break
		}
		if _, err := exec.LookPath("pkexec"); err != nil {
			resp.OK = false
			resp.Message = "pkexec not found"
			break
		}
		resp.PrivilegeReady = true
		resp.Message = "tunnel privileges ready"
	case "startTunnelHelper":
		helper, err := handleTunnelHelper("start", req.Mode)
		resp.HelperPath = helper
		if err != nil {
			resp.OK = false
			resp.Message = err.Error()
		} else {
			resp.PrivilegeReady = true
			resp.Message = "tunnel helper started"
		}
	case "stopTunnelHelper":
		helper, err := handleTunnelHelper("stop", req.Mode)
		resp.HelperPath = helper
		if err != nil {
			resp.OK = false
			resp.Message = err.Error()
		} else {
			resp.Message = "tunnel helper stopped"
		}
	case "notify":
		if err := notifyDesktop(defaultIfEmpty(req.Title, "XConnect"), req.Body); err != nil {
			resp.OK = false
			resp.Message = err.Error()
		} else {
			resp.Message = "notification sent"
		}
	default:
		resp.OK = false
		resp.Message = "unsupported action"
	}

	resp.AutostartEnabled = isAutostartEnabled()
	return desktopIntegrationResult(resp)
}

//export WriteConfigFiles
func WriteConfigFiles(xrayPathC, xrayContentC, servicePathC, serviceContentC, vpnPathC, vpnContentC, passwordC *C.char) *C.char {
	xrayPath := C.GoString(xrayPathC)
	xrayContent := C.GoString(xrayContentC)
	servicePath := C.GoString(servicePathC)
	serviceContent := C.GoString(serviceContentC)
	vpnPath := C.GoString(vpnPathC)
	vpnContent := C.GoString(vpnContentC)
	_ = passwordC

	if err := os.MkdirAll(filepath.Dir(xrayPath), 0755); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.WriteFile(xrayPath, []byte(xrayContent), 0644); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.MkdirAll(filepath.Dir(servicePath), 0755); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.WriteFile(servicePath, []byte(serviceContent), 0644); err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := os.MkdirAll(filepath.Dir(vpnPath), 0755); err != nil {
		return C.CString("error:" + err.Error())
	}
	var existing []map[string]interface{}
	if data, err := os.ReadFile(vpnPath); err == nil {
		json.Unmarshal(data, &existing)
	}
	var newNodes []map[string]interface{}
	if err := json.Unmarshal([]byte(vpnContent), &newNodes); err == nil {
		existing = append(existing, newNodes...)
	} else {
		return C.CString("error:invalid vpn node content")
	}
	updated, _ := json.MarshalIndent(existing, "", "  ")
	if err := os.WriteFile(vpnPath, updated, 0644); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("success")
}

//export CreateWindowsService
func CreateWindowsService(name, execPath, configPath *C.char) *C.char {
	_ = name
	_ = execPath
	_ = configPath
	return C.CString("error:not supported")
}

//export StartNodeService
func StartNodeService(name *C.char) *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok && xray.GetXrayState() {
		return C.CString("success")
	}
	if xray.GetXrayState() {
		return C.CString("error:already running")
	}

	configPath := filepath.Join(os.TempDir(), node+".json")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return C.CString("error:" + err.Error())
	}
	if err := startXrayInternal(data); err != nil {
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
		if xray.GetXrayState() {
			if err := stopXrayInternal(); err != nil {
				return C.CString("error:" + err.Error())
			}
		}
		procMap.Delete(node)
		return C.CString("success")
	}
	if xray.GetXrayState() {
		if err := stopXrayInternal(); err != nil {
			return C.CString("error:" + err.Error())
		}
	}
	clearNodeRegistry()
	return C.CString("success")
}

//export CheckNodeStatus
func CheckNodeStatus(name *C.char) C.int {
	node := C.GoString(name)
	if _, ok := procMap.Load(node); ok && xray.GetXrayState() {
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

	if xray.GetXrayState() {
		return C.CString("error:already running")
	}
	cfgData := []byte(C.GoString(configC))
	if err := startXrayInternal(cfgData); err != nil {
		return C.CString("error:" + err.Error())
	}
	return C.CString("success")
}

//export StopXray
func StopXray() *C.char {
	instMu.Lock()
	defer instMu.Unlock()

	if !xray.GetXrayState() {
		return C.CString("error:not running")
	}
	if err := stopXrayInternal(); err != nil {
		return C.CString("error:" + err.Error())
	}
	clearNodeRegistry()
	return C.CString("success")
}

//export GetDesktopRuntimeSnapshot
func GetDesktopRuntimeSnapshot() *C.char {
	interfaceUp, defaultRoute, lastError := linuxTunnelInterfaceState()
	if !xray.GetXrayState() {
		interfaceUp = false
		defaultRoute = false
		lastError = ""
	}
	payload, err := json.Marshal(desktopRuntimeSnapshot{
		Running:                   xray.GetXrayState(),
		TunnelInterface:           linuxTunnelInterfaceName,
		TunnelInterfaceUp:         interfaceUp,
		DefaultRouteThroughTunnel: defaultRoute,
		LastError:                 lastError,
		UpdatedAt:                 time.Now().UnixMilli(),
	})
	if err != nil {
		return C.CString("{}")
	}
	return C.CString(string(payload))
}

// ---- System tray integration ----

var trayOnce sync.Once

//export RegisterLinuxWindow
func RegisterLinuxWindow(window unsafe.Pointer) {
	C.registerTrayWindow(window)
}

//export InitTray
func InitTray() {
	trayOnce.Do(func() {
		C.scheduleTrayInit()
	})
}

//export InitializeLinuxTrayOnMainThread
func InitializeLinuxTrayOnMainThread() {
	// Flutter already owns the GTK event loop. Register an indicator in that
	// loop instead of running a second gtk_main() on a Go thread.
	systray.Register(func() {
		iconReady := false
		if executable, err := os.Executable(); err == nil {
			iconPath := filepath.Join(filepath.Dir(executable), "data", "flutter_assets", "assets", "logo.png")
			if icon, err := os.ReadFile(iconPath); err == nil && len(icon) > 0 {
				systray.SetIcon(icon)
				iconReady = true
			}
		}
		mShow := systray.AddMenuItem("Show", "Show window")
		mQuit := systray.AddMenuItem("Quit", "Quit")
		if iconReady {
			C.scheduleTrayReady()
		}
		go func() {
			for {
				select {
				case <-mShow.ClickedCh:
					C.scheduleTrayShow()
				case <-mQuit.ClickedCh:
					C.scheduleTrayClose()
					return
				}
			}
		}()
	}, nil)
}
