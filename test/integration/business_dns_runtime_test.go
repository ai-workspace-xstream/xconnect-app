package integration_test

// Runs the Dart-generated policy against the pinned Xray core. All listeners,
// SOCKS relay traffic, and authenticated DoH responses stay on loopback. The
// TEST-NET destinations distinguish proxy traffic from accidental direct DNS.
import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
	_ "github.com/xtls/xray-core/main/distro/all"
	"golang.org/x/net/dns/dnsmessage"
)

type dnsRelay struct {
	tlsAddress string
	mu         sync.Mutex
	plain      int
	doh        map[string]int
	failDoH    bool
}

func dnsResponse(query []byte, address [4]byte) []byte {
	var message dnsmessage.Message
	if message.Unpack(query) != nil || len(message.Questions) != 1 {
		return nil
	}
	message.Response, message.RecursionAvailable = true, true
	q := message.Questions[0]
	if q.Type == dnsmessage.TypeA {
		message.Answers = []dnsmessage.Resource{{
			Header: dnsmessage.ResourceHeader{Name: q.Name, Type: q.Type, Class: q.Class, TTL: 30},
			Body:   &dnsmessage.AResource{A: address},
		}}
	} else if q.Type == dnsmessage.TypeTXT {
		message.Answers = []dnsmessage.Resource{{
			Header: dnsmessage.ResourceHeader{Name: q.Name, Type: q.Type, Class: q.Class, TTL: 30},
			Body:   &dnsmessage.TXTResource{TXT: []string{"original resolver"}},
		}}
	}
	response, _ := message.Pack()
	return response
}

func (relay *dnsRelay) original(query []byte) []byte {
	relay.mu.Lock()
	relay.plain++
	relay.mu.Unlock()
	return dnsResponse(query, [4]byte{198, 18, 0, 20})
}

func (relay *dnsRelay) handleSOCKS(conn net.Conn, udpPort int) {
	defer conn.Close()
	var header [2]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, err := io.ReadFull(conn, methods); err != nil {
		return
	}
	_, _ = conn.Write([]byte{5, 0})
	var request [4]byte
	if _, err := io.ReadFull(conn, request[:]); err != nil {
		return
	}
	var host string
	switch request[3] {
	case 1:
		var raw [4]byte
		if _, err := io.ReadFull(conn, raw[:]); err != nil {
			return
		}
		host = net.IP(raw[:]).String()
	case 3:
		var size [1]byte
		if _, err := io.ReadFull(conn, size[:]); err != nil {
			return
		}
		raw := make([]byte, int(size[0]))
		if _, err := io.ReadFull(conn, raw); err != nil {
			return
		}
		host = string(raw)
	default:
		return
	}
	var port [2]byte
	if _, err := io.ReadFull(conn, port[:]); err != nil {
		return
	}
	if request[1] == 3 {
		_, _ = conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, byte(udpPort >> 8), byte(udpPort)})
		_, _ = io.Copy(io.Discard, conn)
		return
	}
	if request[1] != 1 {
		return
	}
	_, _ = conn.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0})
	if host == "198.51.100.53" && binary.BigEndian.Uint16(port[:]) == 53 {
		for {
			if _, err := io.ReadFull(conn, port[:]); err != nil {
				return
			}
			query := make([]byte, int(binary.BigEndian.Uint16(port[:])))
			if _, err := io.ReadFull(conn, query); err != nil {
				return
			}
			response := relay.original(query)
			binary.BigEndian.PutUint16(port[:], uint16(len(response)))
			_, _ = conn.Write(append(port[:], response...))
		}
	}
	if (host != "203.0.113.53" && host != "203.0.113.54" && host != "203.0.113.55") || binary.BigEndian.Uint16(port[:]) != 443 {
		return
	}
	upstream, err := net.Dial("tcp", relay.tlsAddress)
	if err != nil {
		return
	}
	defer upstream.Close()
	go func() { _, _ = io.Copy(upstream, conn); _ = upstream.Close() }()
	_, _ = io.Copy(conn, upstream)
}

func TestBusinessDnsRuntime(t *testing.T) {
	fixture := os.Getenv("XCONNECT_BUSINESS_DNS_FIXTURE")
	if fixture == "" {
		t.Skip("set XCONNECT_BUSINESS_DNS_FIXTURE to the Dart-generated fixture")
	}
	// Full TLS validation with a test-only CA, never an insecure TLS callback.
	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	certificate := &x509.Certificate{
		SerialNumber: big.NewInt(1), IsCA: true, BasicConstraintsValid: true,
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		KeyUsage:    x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses: []net.IP{net.ParseIP("203.0.113.53"), net.ParseIP("203.0.113.54")},
	}
	der, err := x509.CreateCertificate(rand.Reader, certificate, certificate, &private.PublicKey, private)
	if err != nil {
		t.Fatal(err)
	}
	root, _ := x509.ParseCertificate(der)
	pool := x509.NewCertPool()
	pool.AddCert(root)
	t.Setenv("GODEBUG", "x509usefallbackroots=1")
	x509.SetFallbackRoots(pool)
	relay := &dnsRelay{doh: make(map[string]int)}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		relay.mu.Lock()
		relay.doh[r.Host]++
		fail := relay.failDoH
		relay.mu.Unlock()
		if fail {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		var query []byte
		if r.Method == "GET" {
			query, _ = base64.RawURLEncoding.DecodeString(r.URL.Query().Get("dns"))
		} else {
			query, _ = io.ReadAll(io.LimitReader(r.Body, 4096))
		}
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(dnsResponse(query, [4]byte{198, 18, 0, 10}))
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: private}}, MinVersion: tls.VersionTLS12}
	server.EnableHTTP2 = true
	server.StartTLS()
	defer server.Close()
	relay.tlsAddress = server.Listener.Addr().String()
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	go func() {
		buffer := make([]byte, 4096)
		for {
			n, peer, err := udp.ReadFromUDP(buffer)
			if err != nil {
				return
			}
			if n < 10 || buffer[2] != 0 || buffer[3] != 1 || net.IP(buffer[4:8]).String() != "198.51.100.53" {
				continue
			}
			response := append(append([]byte{}, buffer[:10]...), relay.original(buffer[10:n])...)
			_, _ = udp.WriteToUDP(response, peer)
		}
	}()
	socks, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer socks.Close()
	go func() {
		for {
			conn, err := socks.Accept()
			if err != nil {
				return
			}
			go relay.handleSOCKS(conn, udp.LocalAddr().(*net.UDPAddr).Port)
		}
	}()
	socksPort := socks.Addr().(*net.TCPAddr).Port

	cases := []struct {
		name, domain, network, primary string
		qtype                          dnsmessage.Type
		forward, disabled, fail        bool
	}{
		{name: "global A UDP", domain: "unlisted.business.example", network: "udp", qtype: 1},
		{name: "global A TCP", domain: "unlisted.business.example", network: "tcp", qtype: 1},
		{name: "node exception", domain: "edge.google.com", network: "udp", qtype: 1, forward: true},
		{name: "direct exception", domain: "github.com", network: "udp", qtype: 1, forward: true},
		{name: "private exception", domain: "printer.home.arpa", network: "udp", qtype: 1, forward: true},
		{name: "custom direct exception", domain: "svc.corp.example", network: "udp", qtype: 1, forward: true},
		{name: "TXT TCP", domain: "business.example", network: "tcp", qtype: 16, forward: true},
		{name: "MX", domain: "business.example", network: "udp", qtype: 15, forward: true},
		{name: "SRV", domain: "business.example", network: "udp", qtype: 33, forward: true},
		{name: "HTTPS", domain: "business.example", network: "udp", qtype: 65, forward: true},
		{name: "SVCB", domain: "business.example", network: "udp", qtype: 64, forward: true},
		{name: "AAAA unchanged", domain: "business.example", network: "udp", qtype: 28, forward: true},
		{name: "certificate failure uses secondary", domain: "business.example", network: "udp", qtype: 1, primary: "203.0.113.55"},
		{name: "DoH off restores forwarding", domain: "business.example", network: "udp", qtype: 1, forward: true, disabled: true},
		{name: "both DoH fail without plaintext downgrade", domain: "business.example", network: "udp", qtype: 1, fail: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := fixture
			if tc.disabled {
				path += ".off"
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var config map[string]any
			if err := json.Unmarshal(data, &config); err != nil {
				t.Fatal(err)
			}
			// Adapt the generated Packet Tunnel fixture to loopback ingress and
			// a mock gateway. Production DNS policy/routing is used unchanged.
			listener, _ := net.Listen("tcp4", "127.0.0.1:0")
			port := listener.Addr().(*net.TCPAddr).Port
			_ = listener.Close()
			config["log"] = map[string]any{"loglevel": "none"}
			config["inbounds"] = []any{map[string]any{
				"tag": "tun-in", "listen": "127.0.0.1", "port": port, "protocol": "dokodemo-door",
				"settings": map[string]any{"address": "198.51.100.53", "port": 53, "network": "tcp,udp"},
			}}
			for _, value := range config["outbounds"].([]any) {
				outbound := value.(map[string]any)
				if outbound["tag"] == "proxy" {
					delete(outbound, "streamSettings")
					outbound["protocol"] = "socks"
					outbound["settings"] = map[string]any{"servers": []any{map[string]any{"address": "127.0.0.1", "port": socksPort}}}
				}
			}
			primary := "203.0.113.53"
			if tc.primary != "" {
				primary = tc.primary
			}
			for _, value := range config["dns"].(map[string]any)["servers"].([]any) {
				upstream := value.(map[string]any)
				switch upstream["tag"] {
				case "dns-proxy-primary":
					upstream["address"] = "https://" + primary + "/dns-query"
				case "dns-proxy-secondary":
					upstream["address"] = "https://203.0.113.54/dns-query"
				}
			}
			relay.mu.Lock()
			relay.plain, relay.failDoH, relay.doh = 0, tc.fail, make(map[string]int)
			relay.mu.Unlock()
			encoded, _ := json.Marshal(config)
			loaded, err := core.LoadConfig("json", strings.NewReader(string(encoded)))
			if err != nil {
				t.Fatal(err)
			}
			instance, err := core.New(loaded)
			if err != nil {
				t.Fatal(err)
			}
			if err := instance.Start(); err != nil {
				t.Fatal(err)
			}
			defer instance.Close()
			name, _ := dnsmessage.NewName(tc.domain + ".")
			query, _ := (&dnsmessage.Message{
				Header:    dnsmessage.Header{ID: 1234, RecursionDesired: true},
				Questions: []dnsmessage.Question{{Name: name, Type: tc.qtype, Class: dnsmessage.ClassINET}},
			}).Pack()
			conn, err := net.Dial(tc.network, net.JoinHostPort("127.0.0.1", big.NewInt(int64(port)).String()))
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			deadline := 5 * time.Second
			if tc.fail {
				deadline = 2 * time.Second
			}
			_ = conn.SetDeadline(time.Now().Add(deadline))
			var response []byte
			if tc.network == "tcp" {
				var size [2]byte
				binary.BigEndian.PutUint16(size[:], uint16(len(query)))
				_, err = conn.Write(append(size[:], query...))
				if err == nil {
					_, err = io.ReadFull(conn, size[:])
					response = make([]byte, int(binary.BigEndian.Uint16(size[:])))
					if err == nil {
						_, err = io.ReadFull(conn, response)
					}
				}
			} else {
				_, err = conn.Write(query)
				response = make([]byte, 4096)
				if err == nil {
					var n int
					n, err = conn.Read(response)
					response = response[:n]
				}
			}
			if err != nil {
				relay.mu.Lock()
				plain, providers := relay.plain, len(relay.doh)
				relay.mu.Unlock()
				// The pinned core may leave transport-level upstream failures
				// unanswered. Verify the failure uses both encrypted providers
				// and never sends the query to the plaintext resolver.
				if timeout, ok := err.(net.Error); tc.fail && ok && timeout.Timeout() && plain == 0 && providers == 2 {
					return
				}
				t.Fatalf("%v (plain=%d DoH providers=%d)", err, plain, providers)
			}
			var reply dnsmessage.Message
			if err := reply.Unpack(response); err != nil {
				t.Fatal(err)
			}
			relay.mu.Lock()
			defer relay.mu.Unlock()
			if reply.ID != 1234 || !reply.Response || len(reply.Questions) != 1 || reply.Questions[0].Type != tc.qtype {
				t.Fatalf("query identity was not preserved: %+v", reply)
			}
			if tc.forward {
				if relay.plain == 0 || len(relay.doh) != 0 {
					t.Fatalf("original query did not stay on proxy forwarding: plain=%d doh=%v", relay.plain, relay.doh)
				}
			} else {
				if relay.plain != 0 || len(relay.doh) == 0 {
					t.Fatalf("query did not use proxied DoH: plain=%d doh=%v", relay.plain, relay.doh)
				}
				if tc.primary != "" && relay.doh["203.0.113.54"] == 0 {
					t.Fatal("secondary DoH did not recover from certificate mismatch")
				}
			}
			if tc.fail {
				if reply.RCode != dnsmessage.RCodeServerFailure || len(relay.doh) != 2 {
					t.Fatalf("expected failure after both encrypted upstreams: rcode=%v doh=%v", reply.RCode, relay.doh)
				}
			} else if tc.qtype == dnsmessage.TypeA {
				expected := [4]byte{198, 18, 0, 10}
				if tc.forward {
					expected[3] = 20
				}
				if len(reply.Answers) != 1 || reply.Answers[0].Body.(*dnsmessage.AResource).A != expected {
					t.Fatalf("unexpected A result: %+v", reply.Answers)
				}
			}
		})
	}
}
