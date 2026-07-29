package realityscan

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"math/big"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/mhsanaei/3x-ui/v2/util/netsafe"
)

// The upstream suite covers the pure helpers and the refusals. What it never exercises is
// a probe that reaches a real server -- every test target is loopback or private, which
// the SSRF guard rejects before a socket is opened, so the entire handshake-reading half
// of probeAddr went untested. These tests stand up actual TLS servers and let the prober
// dial them, which is the only way to find out whether it reports what a server does.

// allowPrivate is what makes that possible: the guard reads the exemption from the
// context, and a test server can only live on loopback.
func allowPrivate() context.Context {
	return netsafeAllowPrivate(context.Background())
}

// testServer starts a TLS listener on loopback and returns its host and port.
// cfgFn customises the server's TLS config so a test can produce a server that fails
// exactly one of REALITY's requirements.
func testServer(t *testing.T, cfgFn func(*tls.Config)) (string, int) {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "probe.test"},
		DNSNames:     []string{"probe.test", "*.wild.test", "alt.test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IsCA:         true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("cert: %v", err)
	}

	cfg := &tls.Config{
		Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}},
		NextProtos:   []string{"h2", "http/1.1"},
		MinVersion:   tls.VersionTLS13,
	}
	if cfgFn != nil {
		cfgFn(cfg)
	}

	ln, err := tls.Listen("tcp", "127.0.0.1:0", cfg)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				// Drive the handshake, then hold the connection briefly so the
				// prober can finish reading state off it.
				if tc, ok := conn.(*tls.Conn); ok {
					_ = tc.HandshakeContext(context.Background())
				}
				time.Sleep(50 * time.Millisecond)
				conn.Close()
			}()
		}
	}()

	addr := ln.Addr().(*net.TCPAddr)
	return "127.0.0.1", addr.Port
}

func TestProbeReadsRealHandshake(t *testing.T) {
	host, port := testServer(t, nil)

	res := probeAddr(allowPrivate(), host, port, "probe.test", 5*time.Second, 0)

	if res.Reason != "" && !strings.Contains(res.Reason, "certificate not trusted") {
		t.Fatalf("unexpected reason: %s", res.Reason)
	}
	if !res.TLS13 {
		t.Errorf("TLS13 = false, want true (version reported %q)", res.TLSVersion)
	}
	if res.TLSVersion != "1.3" {
		t.Errorf("TLSVersion = %q, want \"1.3\"", res.TLSVersion)
	}
	if !res.H2 || res.ALPN != "h2" {
		t.Errorf("H2 = %v ALPN = %q, want true/h2", res.H2, res.ALPN)
	}
	if !res.X25519 {
		t.Errorf("X25519 = false, want true (curve %q)", res.CurveID)
	}
	if res.CertSubject != "probe.test" {
		t.Errorf("CertSubject = %q, want probe.test", res.CertSubject)
	}
	// A self-signed cert is genuinely untrusted, so this must be reported, not
	// waved through -- an operator picking a target needs the truth about the chain.
	if res.CertValid {
		t.Error("CertValid = true for a self-signed chain, want false")
	}
	if res.Feasible {
		t.Error("Feasible = true despite an untrusted chain")
	}
	// Wildcards can never be a REALITY serverName, so they must not be offered.
	for _, n := range res.ServerNames {
		if strings.HasPrefix(n, "*.") {
			t.Errorf("ServerNames contains wildcard %q", n)
		}
	}
	if len(res.ServerNames) != 2 {
		t.Errorf("ServerNames = %v, want the two non-wildcard names", res.ServerNames)
	}
	if res.LatencyMs < 0 {
		t.Errorf("LatencyMs = %d", res.LatencyMs)
	}
}

func TestProbeReportsMissingH2(t *testing.T) {
	host, port := testServer(t, func(c *tls.Config) { c.NextProtos = []string{"http/1.1"} })

	res := probeAddr(allowPrivate(), host, port, "probe.test", 5*time.Second, 0)

	if res.H2 {
		t.Error("H2 = true against an http/1.1-only server")
	}
	if res.ALPN != "http/1.1" {
		t.Errorf("ALPN = %q, want http/1.1", res.ALPN)
	}
	if res.Feasible {
		t.Error("Feasible = true without h2")
	}
	if res.Reason == "" {
		t.Error("a failing probe must say why")
	}
}

func TestProbeReportsOldTLS(t *testing.T) {
	host, port := testServer(t, func(c *tls.Config) {
		c.MinVersion = tls.VersionTLS12
		c.MaxVersion = tls.VersionTLS12
	})

	res := probeAddr(allowPrivate(), host, port, "probe.test", 5*time.Second, 0)

	if res.TLS13 {
		t.Error("TLS13 = true against a TLS1.2-capped server")
	}
	if res.TLSVersion != "1.2" {
		t.Errorf("TLSVersion = %q, want 1.2", res.TLSVersion)
	}
	if res.Feasible {
		t.Error("Feasible = true on TLS 1.2")
	}
	if res.Reason == "" {
		t.Error("a failing probe must say why")
	}
}

// A target behind an Nginx `proxy_protocol` listener resets any connection that does not
// lead with the header. The probe has to speak it or it reports a handshake failure that
// says nothing about whether the target is usable (upstream #6082).
func TestProbeSendsProxyProtocolBeforeHandshake(t *testing.T) {
	for _, xver := range []int{1, 2} {
		t.Run(fmt.Sprintf("v%d", xver), func(t *testing.T) {
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatalf("listen: %v", err)
			}
			defer ln.Close()

			got := make(chan []byte, 1)
			go func() {
				conn, err := ln.Accept()
				if err != nil {
					return
				}
				defer conn.Close()
				_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
				buf := make([]byte, 128)
				n, _ := bufio.NewReader(conn).Read(buf)
				got <- buf[:n]
			}()

			addr := ln.Addr().(*net.TCPAddr)
			// The handshake will fail -- there is no TLS server here. What is under
			// test is what went onto the wire first.
			probeAddr(allowPrivate(), "127.0.0.1", addr.Port, "probe.test", 2*time.Second, xver)

			select {
			case b := <-got:
				if xver == 1 {
					if !strings.HasPrefix(string(b), "PROXY TCP4 127.0.0.1 127.0.0.1 ") {
						t.Errorf("v1 header = %q", string(b))
					}
					if !strings.Contains(string(b), "\r\n") {
						t.Error("v1 header not CRLF-terminated")
					}
				} else {
					sig := []byte{0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A}
					if len(b) < len(sig)+4 {
						t.Fatalf("v2 header too short: %d bytes", len(b))
					}
					for i, c := range sig {
						if b[i] != c {
							t.Fatalf("v2 signature mismatch at %d", i)
						}
					}
					if b[12] != 0x21 {
						t.Errorf("v2 version/command = %#x, want 0x21", b[12])
					}
					if b[13] != 0x11 {
						t.Errorf("v2 family = %#x, want 0x11 (TCP over IPv4)", b[13])
					}
				}
			case <-time.After(3 * time.Second):
				t.Fatal("no PROXY header was sent")
			}
		})
	}
}

// Without a PROXY header the same listener sees TLS bytes straight away.
func TestProbeSendsNoProxyHeaderWhenXverZero(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	got := make(chan []byte, 1)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		buf := make([]byte, 64)
		n, _ := bufio.NewReader(conn).Read(buf)
		got <- buf[:n]
	}()

	addr := ln.Addr().(*net.TCPAddr)
	probeAddr(allowPrivate(), "127.0.0.1", addr.Port, "probe.test", 2*time.Second, 0)

	select {
	case b := <-got:
		if strings.HasPrefix(string(b), "PROXY") {
			t.Errorf("sent a PROXY header with xver=0: %q", string(b))
		}
		// 0x16 is a TLS handshake record.
		if len(b) > 0 && b[0] != 0x16 {
			t.Errorf("first byte = %#x, want a TLS handshake record", b[0])
		}
	case <-time.After(3 * time.Second):
		t.Fatal("nothing was sent")
	}
}

func TestProbeHonoursCancelledContext(t *testing.T) {
	host, port := testServer(t, nil)

	ctx, cancel := context.WithCancel(allowPrivate())
	cancel()

	start := time.Now()
	res := probeAddr(ctx, host, port, "probe.test", 10*time.Second, 0)
	elapsed := time.Since(start)

	if res.Feasible {
		t.Error("a cancelled probe reported a feasible target")
	}
	// The point of threading the context: an abandoned probe must not sit on the
	// socket for the full timeout.
	if elapsed > 3*time.Second {
		t.Errorf("cancelled probe took %v, expected to give up immediately", elapsed)
	}
}

func TestEnumerateCIDR(t *testing.T) {
	ips, err := enumerateCIDR("192.0.2.0/30", 256)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"192.0.2.0", "192.0.2.1", "192.0.2.2", "192.0.2.3"}
	if len(ips) != len(want) {
		t.Fatalf("got %v, want %v", ips, want)
	}
	for i := range want {
		if ips[i] != want[i] {
			t.Errorf("ips[%d] = %s, want %s", i, ips[i], want[i])
		}
	}

	// The cap is what stops a /8 from turning one click into sixteen million dials.
	capped, err := enumerateCIDR("10.0.0.0/8", 5)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(capped) != 5 {
		t.Errorf("cap not applied: got %d addresses", len(capped))
	}

	if _, err := enumerateCIDR("not-a-cidr", 8); err == nil {
		t.Error("expected an error for a malformed CIDR")
	}
}

func TestDedupKeepsTheBetterResult(t *testing.T) {
	slow := &Result{Target: "a:443", Feasible: true, LatencyMs: 300}
	fast := &Result{Target: "a:443", Feasible: true, LatencyMs: 90}
	broken := &Result{Target: "b:443", Feasible: false, LatencyMs: 10}

	out := dedupResults([]*Result{slow, fast, broken, nil})

	if len(out) != 2 {
		t.Fatalf("got %d results, want 2", len(out))
	}
	// First-seen order is preserved by dedup; a:443 stays first.
	if out[0].Target != "a:443" || out[0].LatencyMs != 90 {
		t.Errorf("kept %+v, want the 90ms probe of a:443", out[0])
	}
}

func TestDedupPrefersFeasibleOverFaster(t *testing.T) {
	// A fast failure must never displace a slower success: the operator is choosing a
	// target that works, not the one that refused them quickest.
	fastFail := &Result{Target: "a:443", Feasible: false, LatencyMs: 5}
	slowOK := &Result{Target: "a:443", Feasible: true, LatencyMs: 400}

	out := dedupResults([]*Result{fastFail, slowOK})

	if len(out) != 1 {
		t.Fatalf("got %d results, want 1", len(out))
	}
	if !out[0].Feasible {
		t.Error("dedup kept the fast failure over the working target")
	}
}

func TestSortPutsFeasibleAndFastFirst(t *testing.T) {
	results := []*Result{
		{Target: "slow-ok", Feasible: true, LatencyMs: 500},
		{Target: "bad-fast", Feasible: false, LatencyMs: 1},
		{Target: "fast-ok", Feasible: true, LatencyMs: 20},
	}

	sortResults(results)

	want := []string{"fast-ok", "slow-ok", "bad-fast"}
	for i, w := range want {
		if results[i].Target != w {
			t.Errorf("results[%d] = %s, want %s", i, results[i].Target, w)
		}
	}
}

func TestFirstUsableNameSkipsWildcards(t *testing.T) {
	cases := []struct {
		name string
		cert *x509.Certificate
		want string
	}{
		{"common name wins", &x509.Certificate{
			Subject: pkix.Name{CommonName: "cn.test"}, DNSNames: []string{"san.test"}}, "cn.test"},
		{"wildcard common name is skipped", &x509.Certificate{
			Subject: pkix.Name{CommonName: "*.cn.test"}, DNSNames: []string{"san.test"}}, "san.test"},
		{"wildcard SANs are skipped", &x509.Certificate{
			DNSNames: []string{"*.a.test", "b.test"}}, "b.test"},
		{"nothing usable", &x509.Certificate{DNSNames: []string{"*.a.test"}}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := firstUsableName(c.cert); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
}

// A batch scan of a private range must come back empty rather than reporting on the
// panel's own neighbours -- the guard is what the whole batch path rests on.
func TestTargetsRefusesPrivateCIDR(t *testing.T) {
	results, err := Targets(context.Background(), "10.0.0.0/29")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, r := range results {
		if r.Feasible {
			t.Errorf("private address %s reported feasible", r.Target)
		}
	}
}

func TestTargetsReportsBadCIDR(t *testing.T) {
	results, err := Targets(context.Background(), "192.0.2.0/nope")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(results) != 1 {
		t.Fatalf("got %d results, want 1", len(results))
	}
	if !strings.Contains(results[0].Reason, "invalid CIDR") {
		t.Errorf("reason = %q, want it to name the bad CIDR", results[0].Reason)
	}
}

// netsafeAllowPrivate is a thin alias so the intent reads at the call site: these tests
// need loopback, which is exactly what the guard exists to refuse everywhere else.
func netsafeAllowPrivate(ctx context.Context) context.Context {
	return netsafe.ContextWithAllowPrivate(ctx, true)
}
