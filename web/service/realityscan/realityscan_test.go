package realityscan

import (
	"context"
	"crypto/tls"
	"net"
	"testing"
)

func TestTLSVersionName(t *testing.T) {
	cases := map[uint16]string{
		tls.VersionTLS13: "1.3",
		tls.VersionTLS12: "1.2",
		tls.VersionTLS11: "1.1",
		tls.VersionTLS10: "1.0",
		0:                "unknown",
	}
	for in, want := range cases {
		if got := tlsVersionName(in); got != want {
			t.Errorf("tlsVersionName(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestRealityCurveName(t *testing.T) {
	cases := map[tls.CurveID]string{
		tls.X25519:         "X25519",
		tls.X25519MLKEM768: "X25519MLKEM768",
		tls.CurveP256:      "P-256",
		0:                  "",
	}
	for in, want := range cases {
		if got := curveName(in); got != want {
			t.Errorf("curveName(%d) = %q, want %q", in, got, want)
		}
	}
}

func TestFilterUsableSANs(t *testing.T) {
	got := filterUsableSANs([]string{"example.com", "*.example.com", "", " a.com "})
	want := []string{"example.com", "a.com"}
	if len(got) != len(want) {
		t.Fatalf("filterUsableSANs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("filterUsableSANs[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestSplitRealityTarget(t *testing.T) {
	okCases := []struct {
		in       string
		wantHost string
		wantPort int
	}{
		{"example.com", "example.com", 443},
		{"example.com:8443", "example.com", 8443},
		{"1.1.1.1:443", "1.1.1.1", 443},
	}
	for _, c := range okCases {
		host, port, err := splitTarget(c.in)
		if err != nil {
			t.Errorf("splitTarget(%q) unexpected error: %v", c.in, err)
			continue
		}
		if host != c.wantHost || port != c.wantPort {
			t.Errorf("splitTarget(%q) = (%q, %d), want (%q, %d)", c.in, host, port, c.wantHost, c.wantPort)
		}
	}

	badCases := []string{"", "  ", "example.com:0", "example.com:70000", "bad host!"}
	for _, in := range badCases {
		if _, _, err := splitTarget(in); err == nil {
			t.Errorf("splitTarget(%q) expected error, got nil", in)
		}
	}
}

func TestScanRealityTargetInputValidation(t *testing.T) {
	if _, err := Target(context.Background(), "", 0); err == nil {
		t.Error("Target(empty) expected error, got nil")
	}
}

func TestScanRealityTargetBlocksPrivate(t *testing.T) {
	res, err := Target(context.Background(), "127.0.0.1:443", 0)
	if err != nil {
		t.Fatalf("Target(loopback) unexpected error: %v", err)
	}
	if res.Feasible {
		t.Error("Target(loopback) should not be feasible")
	}
	if res.Reason == "" {
		t.Error("Target(loopback) should set a reason")
	}
}

func TestScanRealityTargetsHandlesPrivateAndBadInput(t *testing.T) {
	results, err := Targets(context.Background(), "127.0.0.1:443,10.0.0.1:443,bad host!")
	if err != nil {
		t.Fatalf("ScanRealityTargets unexpected error: %v", err)
	}
	if len(results) != 3 {
		t.Fatalf("ScanRealityTargets returned %d results, want 3", len(results))
	}
	for _, r := range results {
		if r.Feasible {
			t.Errorf("result %q unexpectedly feasible", r.Target)
		}
	}
}

func TestWriteProxyProtocolV1(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()

	local := &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 51234}
	remote := &net.TCPAddr{IP: net.ParseIP("203.0.113.5"), Port: 443}

	got := make(chan string, 1)
	go func() {
		buf := make([]byte, 128)
		n, _ := server.Read(buf)
		got <- string(buf[:n])
	}()

	if err := writeProxyProtocolV1(client, local, remote); err != nil {
		t.Fatalf("writeProxyProtocolV1: %v", err)
	}
	line := <-got
	want := "PROXY TCP4 192.0.2.10 203.0.113.5 51234 443\r\n"
	if line != want {
		t.Fatalf("v1 header = %q, want %q", line, want)
	}
}

func TestWriteProxyProtocolV2Signature(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()

	local := &net.TCPAddr{IP: net.ParseIP("192.0.2.10"), Port: 51234}
	remote := &net.TCPAddr{IP: net.ParseIP("203.0.113.5"), Port: 443}

	got := make(chan []byte, 1)
	go func() {
		buf := make([]byte, 128)
		n, _ := server.Read(buf)
		got <- append([]byte(nil), buf[:n]...)
	}()

	if err := writeProxyProtocolV2(client, local, remote); err != nil {
		t.Fatalf("writeProxyProtocolV2: %v", err)
	}
	hdr := <-got
	sig := []byte{0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A}
	if len(hdr) < 16 || string(hdr[:12]) != string(sig) {
		t.Fatalf("v2 header missing the protocol signature: %v", hdr)
	}
	if hdr[12] != 0x21 {
		t.Fatalf("v2 version/command byte = 0x%02x, want 0x21", hdr[12])
	}
	if hdr[13] != 0x11 {
		t.Fatalf("v2 family/protocol byte = 0x%02x, want 0x11 (TCP over IPv4)", hdr[13])
	}
}
