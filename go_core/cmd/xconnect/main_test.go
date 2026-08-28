package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"go_core/overlay/controlplane"
	"go_core/overlay/fault"
	"go_core/overlay/model"
	overlayruntime "go_core/overlay/runtime"
	"go_core/overlay/signedconfig"
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

func TestCLIInviteJoinUsesEnrollmentWithoutAccountTokenOrSecretOutput(t *testing.T) {
	server, joinToken, enrollmentToken, exchangeCalls, ackCalls := newCLIInviteServer(t)
	stateDirectory := t.TempDir()
	t.Setenv("XCONNECT_TOKEN", "account-token-must-not-be-used")
	invite := "xconnect://join/" + joinToken + "?controller=" + url.QueryEscape(server.URL)
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	fakeRuntime := &overlayruntime.Fake{}
	err := runWithRuntimeFactory(t.Context(), []string{
		"join", invite, "--allow-insecure-localhost", "--state-dir", stateDirectory, "--device-id", "dev_cli",
	}, &stdout, &stderr, server.Client(), func(string) overlayruntime.Interface { return fakeRuntime })
	if err != nil {
		t.Fatalf("invite join: %v", err)
	}
	if exchangeCalls.Load() != 1 || ackCalls.Load() != 1 || fakeRuntime.ApplyCalls != 1 {
		t.Fatalf("exchange=%d ack=%d apply=%d", exchangeCalls.Load(), ackCalls.Load(), fakeRuntime.ApplyCalls)
	}
	for _, output := range []string{stdout.String(), stderr.String()} {
		for _, secret := range []string{joinToken, enrollmentToken, "account-token-must-not-be-used"} {
			if strings.Contains(output, secret) {
				t.Fatalf("CLI output leaked secret: %s", output)
			}
		}
	}
	if _, err := os.Stat(state.NewStore(stateDirectory).EnrollmentSecretPath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("completed transient secret remains: %v", err)
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
	joinToken := "xjt_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	invite := "xconnect://join/" + joinToken + "?controller=" + url.QueryEscape(controller)

	target, err := resolveJoinTarget(invite, "", false)
	if err != nil {
		t.Fatalf("resolve invite: %v", err)
	}
	if target.Controller != controller || target.JoinToken != joinToken || target.NetworkID != "" || target.NodeID != "" {
		t.Fatalf("unexpected invite target: %#v", target)
	}
}

func TestJoinRejectsCredentialsInInviteURL(t *testing.T) {
	joinToken := "xjt_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	_, err := resolveJoinTarget("xconnect://join/"+joinToken+"?controller=https%3A%2F%2Faccounts.example&token=secret", "", false)
	if fault.Code(err) != fault.CodeJoinInviteInvalid {
		t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
	}
}

func TestJoinInviteParserRejectsAmbiguousOrInsecureURLs(t *testing.T) {
	joinToken := "xjt_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	tests := []string{
		"xconnect://join?controller=https%3A%2F%2Faccounts.example",
		"xconnect://user@join/" + joinToken + "?controller=https%3A%2F%2Faccounts.example",
		"xconnect://join/" + joinToken + "/extra?controller=https%3A%2F%2Faccounts.example",
		"xconnect://join/%78jt_invalid?controller=https%3A%2F%2Faccounts.example",
		"xconnect://join/" + joinToken + "?controller=https%3A%2F%2Faccounts.example#fragment",
		"xconnect://join/" + joinToken + "?controller=https%3A%2F%2Fuser%40accounts.example",
		"xconnect://join/" + joinToken + "?controller=https%3A%2F%2Faccounts.example%3Fx%3D1",
		"xconnect://join/" + joinToken + "?controller=http%3A%2F%2Faccounts.example",
		"xconnect://join/" + joinToken + "?controller=http%3A%2F%2Flocalhost%3A8080",
	}
	for _, invite := range tests {
		if _, err := resolveJoinTarget(invite, "", false); fault.Code(err) != fault.CodeJoinInviteInvalid {
			t.Fatalf("invite accepted %q: %v", invite, err)
		}
	}
	invite := "xconnect://join/" + joinToken + "?controller=http%3A%2F%2Flocalhost%3A8080"
	if target, err := resolveJoinTarget(invite, "", true); err != nil || target.Controller != "http://localhost:8080" {
		t.Fatalf("explicit localhost development invite = %#v, %v", target, err)
	}
}

func TestJoinRejectsUnknownConfigContractBeforeNetworkAccess(t *testing.T) {
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runWithRuntimeFactory(t.Context(), []string{
		"join", "https://accounts.example", "--config-contract", "future", "--state-dir", t.TempDir(), "--device-id", "dev_cli",
	}, &stdout, &stderr, http.DefaultClient, func(string) overlayruntime.Interface { return &overlayruntime.Fake{} })
	if fault.Code(err) != fault.CodeInvalidInput {
		t.Fatalf("error code = %q, err=%v", fault.Code(err), err)
	}
}

func TestInviteJoinRejectsLegacyContractBeforeNetworkAccess(t *testing.T) {
	joinToken := "xjt_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	invite := "xconnect://join/" + joinToken + "?controller=https%3A%2F%2Faccounts.example"
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	err := runWithRuntimeFactory(t.Context(), []string{
		"join", invite, "--config-contract", "legacy", "--state-dir", t.TempDir(), "--device-id", "dev_cli",
	}, &stdout, &stderr, http.DefaultClient, func(string) overlayruntime.Interface { return &overlayruntime.Fake{} })
	if fault.Code(err) != fault.CodeConfigDowngradeBlocked {
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
		case "/api/overlay/v1/signing-keys", "/api/overlay/v1/signed-config":
			writer.WriteHeader(http.StatusNotFound)
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

func newCLIInviteServer(t *testing.T) (*httptest.Server, string, string, *atomic.Int32, *atomic.Int32) {
	t.Helper()
	joinToken := "xjt_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))
	enrollmentToken := "xenr_" + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	now := time.Now().UTC().Truncate(time.Second)
	privateKey := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{11}, ed25519.SeedSize))
	notAfter := signedconfig.CanonicalTime{Time: now.Add(24 * time.Hour)}
	keys := []signedconfig.SigningKey{{
		KeyID: "signing_key_01", Algorithm: signedconfig.SignatureEd25519,
		PublicKey: base64.StdEncoding.EncodeToString(privateKey.Public().(ed25519.PublicKey)), Status: "current",
		NotBefore: signedconfig.CanonicalTime{Time: now.Add(-time.Hour)}, NotAfter: &notAfter,
	}}
	config := signedconfig.Config{
		SchemaVersion: 1, ConfigID: "cfg_cli_invite", NetworkID: "net_private", DeviceID: "dev_cli", Generation: 1,
		IssuedAt: signedconfig.CanonicalTime{Time: now.Add(-time.Minute)}, ExpiresAt: signedconfig.CanonicalTime{Time: now.Add(time.Hour)},
		ProxyCore: signedconfig.ProxyCoreXray,
		Transport: signedconfig.Transport{Kind: signedconfig.TransportVLESS, Loopback: signedconfig.Endpoint{Host: "127.0.0.1", Port: 51830}, Remote: signedconfig.RemoteEndpoint{Host: "gateway.example.net", Port: 443, ServerName: "gateway.example.net"}, AuthID: "11111111-1111-1111-1111-111111111111"},
		WireGuard: signedconfig.WireGuard{InterfaceName: "wg-xco", Addresses: []string{"10.77.0.20/32"}, MTU: 1280, Peers: []signedconfig.Peer{{GatewayID: "gw_tokyo_01", PublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", AllowedIPs: []string{"10.77.0.0/16"}, Endpoint: signedconfig.Endpoint{Host: "127.0.0.1", Port: 51830}, PersistentKeepaliveSeconds: 25}}},
		Signature: signedconfig.Signature{Algorithm: signedconfig.SignatureEd25519, KeyID: "signing_key_01"},
	}
	payload, err := config.SigningBytes()
	if err != nil {
		t.Fatal(err)
	}
	config.Signature.Value = base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload))
	var exchangeCalls atomic.Int32
	var ackCalls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch request.URL.Path {
		case "/api/overlay/v1/join-tokens/exchange":
			exchangeCalls.Add(1)
			if request.Header.Get("Authorization") != "" {
				t.Errorf("public exchange sent account bearer")
			}
			var exchange controlplane.JoinTokenExchangeRequest
			if err := json.NewDecoder(request.Body).Decode(&exchange); err != nil {
				t.Errorf("decode exchange: %v", err)
				writer.WriteHeader(http.StatusBadRequest)
				return
			}
			if exchange.JoinToken != joinToken || exchange.DeviceID != "dev_cli" {
				t.Errorf("unexpected exchange request")
			}
			writer.Header().Set("Cache-Control", "no-store")
			_ = json.NewEncoder(writer).Encode(controlplane.JoinTokenExchangeResponse{
				EnrollmentToken: enrollmentToken, TokenType: "Bearer", ExpiresAt: now.Add(10 * time.Minute),
				Scope:   []string{"overlay:config:read", "overlay:config:ack"},
				Device:  model.Device{ID: "dev_cli", NetworkID: "net_private", Platform: runtime.GOOS, WireGuardPublicKey: exchange.WireGuardPublicKey, WireGuardAddress: "10.77.0.20/32"},
				Network: model.Network{ID: "net_private", CIDR: "10.77.0.0/16"}, SigningKeys: keys,
			})
		case "/api/overlay/v1/enrollment/signed-config":
			if request.Header.Get("Authorization") != "Bearer "+enrollmentToken {
				t.Errorf("signed config missing enrollment bearer")
			}
			writer.Header().Set("Cache-Control", "private, no-store")
			writer.Header().Set("ETag", `"cfg_cli_invite"`)
			_ = json.NewEncoder(writer).Encode(config)
		case "/api/overlay/v1/enrollment/signed-config/1/ack":
			ackCalls.Add(1)
			if request.Header.Get("Authorization") != "Bearer "+enrollmentToken {
				t.Errorf("ACK missing enrollment bearer")
			}
			_ = json.NewEncoder(writer).Encode(controlplane.SignedConfigAckResponse{Acked: true, Ack: controlplane.SignedConfigAck{
				DeviceID: "dev_cli", ConfigID: "cfg_cli_invite", Generation: 1, AppliedAt: now, ReceivedAt: now.Add(time.Millisecond),
			}})
		default:
			t.Errorf("unexpected invite API path %s", request.URL.Path)
			writer.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server, joinToken, enrollmentToken, &exchangeCalls, &ackCalls
}
