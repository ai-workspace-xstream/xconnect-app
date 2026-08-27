package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"go_core/overlay/controlplane"
	"go_core/overlay/fault"
	"go_core/overlay/model"
	overlayruntime "go_core/overlay/runtime"
	"go_core/overlay/state"
)

const cliTestToken = "cli-secret-token"

func TestJoinAcceptsControllerPositionallyAndKeepsSecretsOutOfOutput(t *testing.T) {
	var ackCalls atomic.Int32
	server := newCLITestServer(t, false, &ackCalls)
	stateDirectory := t.TempDir()
	t.Setenv("XCONNECT_TOKEN", cliTestToken)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	fakeRuntime := &overlayruntime.Fake{}
	newRuntime := func(string) overlayruntime.Interface { return fakeRuntime }

	err := runWithRuntimeFactory(t.Context(), []string{
		"join",
		server.URL,
		"--state-dir", stateDirectory,
		"--device-id", "dev_cli",
	}, &stdout, &stderr, server.Client(), newRuntime)
	if err != nil {
		t.Fatalf("join command: %v", err)
	}
	lastKnown, err := state.NewStore(stateDirectory).LoadLastKnown()
	if err != nil {
		t.Fatalf("load last-known state: %v", err)
	}
	for _, output := range []string{stdout.String(), stderr.String()} {
		if strings.Contains(output, cliTestToken) || strings.Contains(output, lastKnown.WireGuardPrivateKey) {
			t.Fatalf("command output leaked a secret: %s", output)
		}
	}
	entries, err := os.ReadDir(stateDirectory)
	if err != nil {
		t.Fatalf("read state directory: %v", err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(stateDirectory, entry.Name()))
		if err != nil {
			t.Fatalf("read state artifact: %v", err)
		}
		if bytes.Contains(raw, []byte(cliTestToken)) {
			t.Fatalf("token persisted in %s", entry.Name())
		}
	}

	stdout.Reset()
	if err := runWithRuntimeFactory(t.Context(), []string{"status", "--state-dir", stateDirectory}, &stdout, &stderr, server.Client(), newRuntime); err != nil {
		t.Fatalf("status command: %v", err)
	}
	if strings.Contains(stdout.String(), lastKnown.WireGuardPrivateKey) {
		t.Fatal("status output leaked private key")
	}

	stdout.Reset()
	if err := runWithRuntimeFactory(t.Context(), []string{"diagnose", "--state-dir", stateDirectory}, &stdout, &stderr, server.Client(), newRuntime); err != nil {
		t.Fatalf("diagnose command: %v", err)
	}
	if strings.Contains(stdout.String(), lastKnown.WireGuardPrivateKey) {
		t.Fatal("diagnose output leaked private key")
	}
}

func TestProductionJoinFailsClosedWithoutPlatformRuntimeAndDoesNotAck(t *testing.T) {
	var ackCalls atomic.Int32
	server := newCLITestServer(t, false, &ackCalls)
	stateDirectory := t.TempDir()
	t.Setenv("XCONNECT_TOKEN", cliTestToken)
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	err := run(t.Context(), []string{
		"join",
		server.URL,
		"--state-dir", stateDirectory,
		"--device-id", "dev_cli",
	}, &stdout, &stderr, server.Client())
	if fault.Code(err) != fault.CodeRuntimeUnavailable {
		t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
	}
	if ackCalls.Load() != 0 {
		t.Fatalf("ACK calls = %d, want 0", ackCalls.Load())
	}
	checkpoint, loadErr := state.NewStore(stateDirectory).LoadCheckpoint()
	if loadErr != nil {
		t.Fatalf("load checkpoint: %v", loadErr)
	}
	if checkpoint.Phase != state.PhaseConfigFetched || checkpoint.LastErrorCode != fault.CodeRuntimeUnavailable {
		t.Fatalf("unexpected checkpoint after unavailable runtime: %#v", checkpoint)
	}
}

func TestPlatformRuntimeSelectsLinuxOnlyExternalRuntime(t *testing.T) {
	linuxRuntime := platformRuntime("linux", t.TempDir())
	if _, ok := linuxRuntime.(*overlayruntime.Desktop); !ok {
		t.Fatalf("linux runtime = %T, want desktop runtime", linuxRuntime)
	}
	darwinRuntime := platformRuntime("darwin", t.TempDir())
	diagnostics, err := darwinRuntime.Diagnose(t.Context())
	if err != nil {
		t.Fatalf("darwin diagnose: %v", err)
	}
	if len(diagnostics) != 2 || diagnostics[1].Code != "protected_host_runtime_required" || !diagnostics[1].Healthy {
		t.Fatalf("darwin diagnostics = %#v", diagnostics)
	}
	if _, err := darwinRuntime.Apply(t.Context(), overlayruntime.ApplyRequest{}); fault.Code(err) != fault.CodeRuntimeUnavailable {
		t.Fatalf("darwin apply code = %q, err=%v", fault.Code(err), err)
	}
}

func TestJoinAcceptsInviteURLControllerAndSelection(t *testing.T) {
	controller := "https://accounts.example"
	invite := "xconnect://join?controller=" + url.QueryEscape(controller) + "&network_id=net_private&node_id=gw_tokyo"

	target, err := resolveJoinTarget(invite, "")
	if err != nil {
		t.Fatalf("resolve invite: %v", err)
	}
	if target.Controller != controller || target.NetworkID != "net_private" || target.NodeID != "gw_tokyo" {
		t.Fatalf("unexpected invite target: %#v", target)
	}
}

func TestJoinRejectsCredentialsInInviteURL(t *testing.T) {
	_, err := resolveJoinTarget("xconnect://join?controller=https%3A%2F%2Faccounts.example&token=secret", "")
	if fault.Code(err) != fault.CodeInvalidInput {
		t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
	}
}

func TestJoinAuthenticationErrorDoesNotExposeTokenOrResponseBody(t *testing.T) {
	var ackCalls atomic.Int32
	server := newCLITestServer(t, true, &ackCalls)
	t.Setenv("XCONNECT_TOKEN", cliTestToken)
	var stdout bytes.Buffer
	var stderr bytes.Buffer

	err := run(t.Context(), []string{
		"join",
		server.URL,
		"--state-dir", t.TempDir(),
		"--device-id", "dev_cli",
	}, &stdout, &stderr, server.Client())
	if fault.Code(err) != fault.CodeAuthenticationFailed {
		t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
	}
	if strings.Contains(err.Error(), cliTestToken) || strings.Contains(err.Error(), "token_expired") {
		t.Fatalf("authentication error leaked details: %v", err)
	}
}

func newCLITestServer(t *testing.T, unauthorized bool, ackCalls *atomic.Int32) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		if unauthorized || request.Header.Get("Authorization") != "Bearer "+cliTestToken {
			writer.WriteHeader(http.StatusUnauthorized)
			_, _ = writer.Write([]byte(`{"error":"token_expired","message":"cli-secret-token"}`))
			return
		}
		switch request.URL.Path {
		case "/api/overlay/v1/devices/register":
			var payload controlplane.RegisterDeviceRequest
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Errorf("decode register request: %v", err)
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(writer).Encode(controlplane.RegisterDeviceResponse{
				Device: model.Device{
					ID:                 payload.DeviceID,
					NetworkID:          "net_private",
					WireGuardPublicKey: payload.WireGuardPublicKey,
					WireGuardAddress:   "10.77.0.20/32",
				},
				Network: model.Network{ID: "net_private", DisplayName: "Private", CIDR: "10.77.0.0/16"},
			})
		case "/api/overlay/v1/config":
			_ = json.NewEncoder(writer).Encode(cliTestConfig())
		case "/api/overlay/v1/config/ack":
			ackCalls.Add(1)
			var payload controlplane.ConfigAckRequest
			if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
				t.Errorf("decode ack request: %v", err)
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			_ = json.NewEncoder(writer).Encode(controlplane.ConfigAckResponse{
				Acked:     true,
				DeviceID:  payload.DeviceID,
				NetworkID: payload.NetworkID,
				Revision:  payload.Revision,
			})
		default:
			t.Errorf("unexpected API path %s", request.URL.Path)
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
}

func cliTestConfig() model.Config {
	return model.Config{
		SchemaVersion: 1,
		Revision:      "revision-cli",
		Digest:        "digest-cli",
		Network:       model.Network{ID: "net_private", DisplayName: "Private", CIDR: "10.77.0.0/16"},
		Device:        model.Device{ID: "dev_cli", NetworkID: "net_private", WireGuardAddress: "10.77.0.20/32"},
		WireGuard: model.WireGuardConfig{
			Interface:            "wg-xco",
			Address:              "10.77.0.20/32",
			MTU:                  1280,
			PrivateKeyRef:        "local-keychain",
			LocalProxyEndpoint:   "127.0.0.1:51830",
			PeerPublicKey:        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
			PeerAllowedIPs:       []string{"10.77.0.0/16"},
			PeerEndpoint:         "127.0.0.1:51830",
			GatewayWireGuardIP:   "10.77.0.1",
			GatewayWireGuardCIDR: "10.77.0.1/32",
		},
		Transport: model.TransportConfig{
			Runtime:        model.WireRuntimeXrayCore,
			Type:           model.TransportVLESSTLS,
			Security:       model.TransportSecurityTLS,
			Server:         "gateway.example.net",
			Port:           443,
			UUID:           "11111111-1111-1111-1111-111111111111",
			PacketEncoding: model.PacketEncodingXUDP,
			LocalPort:      51830,
		},
	}
}
