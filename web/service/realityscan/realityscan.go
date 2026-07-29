// Package realityscan tells an operator whether a domain will actually work as a REALITY
// target before they commit an inbound to it.
//
// Picking a target is guesswork otherwise. REALITY needs one that negotiates TLS 1.3,
// speaks h2, does an X25519 key exchange and presents a chain that verifies -- and a
// domain failing any of those does not announce itself, it just produces an inbound that
// is fingerprintable or does not connect, which is discovered later and blamed on
// something else. So this dials the candidate and reports what it really does.
//
// It lives in its own package rather than beside the rest of the services because those
// only build on Linux: they reach for syscall.Kill, SO_PEERCRED and /proc. None of that
// has anything to do with probing a TLS server, and having it in the way meant this code
// -- which handles operator-supplied hostnames and hand-rolls PROXY protocol frames, so
// precisely the code worth testing -- could not have a test run against it on a Windows
// or macOS workstation. Here `go test` works anywhere.
//
// Ported from upstream 3x-ui, with its test suite.
package realityscan

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/util/common"
	"github.com/mhsanaei/3x-ui/v2/util/netsafe"
)

const (
	scanTimeout     = 10 * time.Second
	discoverTimeout = 4 * time.Second
	scanConcurrency = 32
	discoverMaxIPs  = 256
	scanMaxTotal    = 512
)

var defaultCandidates = []string{
	"www.cloudflare.com:443",
	"www.microsoft.com:443",
	"www.amazon.com:443",
	"aws.amazon.com:443",
	"www.samsung.com:443",
	"www.nvidia.com:443",
	"www.amd.com:443",
	"www.intel.com:443",
	"www.sony.com:443",
	"dl.google.com:443",
}

type Result struct {
	Target      string   `json:"target" example:"www.cloudflare.com:443"`
	Host        string   `json:"host" example:"www.cloudflare.com"`
	IP          string   `json:"ip" example:"104.16.124.96"`
	Port        int      `json:"port" example:"443"`
	Feasible    bool     `json:"feasible" example:"true"`
	TLS13       bool     `json:"tls13" example:"true"`
	TLSVersion  string   `json:"tlsVersion" example:"1.3"`
	H2          bool     `json:"h2" example:"true"`
	ALPN        string   `json:"alpn" example:"h2"`
	X25519      bool     `json:"x25519" example:"true"`
	CurveID     string   `json:"curveID" example:"X25519"`
	CertValid   bool     `json:"certValid" example:"true"`
	CertSubject string   `json:"certSubject" example:"cloudflare.com"`
	CertIssuer  string   `json:"certIssuer" example:"Google Trust Services"`
	NotAfter    string   `json:"notAfter" example:"2026-08-01T00:00:00Z"`
	ServerNames []string `json:"serverNames"`
	LatencyMs   int      `json:"latencyMs" example:"180"`
	Reason      string   `json:"reason" example:""`
}

type probeTask struct {
	dialHost string
	port     int
	sni      string
	timeout  time.Duration
	bulk     bool
}

func tlsVersionName(v uint16) string {
	switch v {
	case tls.VersionTLS13:
		return "1.3"
	case tls.VersionTLS12:
		return "1.2"
	case tls.VersionTLS11:
		return "1.1"
	case tls.VersionTLS10:
		return "1.0"
	default:
		return "unknown"
	}
}

func curveName(id tls.CurveID) string {
	switch id {
	case tls.X25519:
		return "X25519"
	case tls.X25519MLKEM768:
		return "X25519MLKEM768"
	case tls.CurveP256:
		return "P-256"
	case tls.CurveP384:
		return "P-384"
	case tls.CurveP521:
		return "P-521"
	case 0:
		return ""
	default:
		return fmt.Sprintf("0x%04x", uint16(id))
	}
}

func filterUsableSANs(dnsNames []string) []string {
	out := make([]string, 0, len(dnsNames))
	for _, n := range dnsNames {
		n = strings.TrimSpace(n)
		if n == "" || strings.HasPrefix(n, "*.") {
			continue
		}
		out = append(out, n)
	}
	return out
}

func firstUsableName(leaf *x509.Certificate) string {
	cn := strings.TrimSpace(leaf.Subject.CommonName)
	if cn != "" && !strings.HasPrefix(cn, "*.") {
		return cn
	}
	for _, n := range leaf.DNSNames {
		n = strings.TrimSpace(n)
		if n != "" && !strings.HasPrefix(n, "*.") {
			return n
		}
	}
	return ""
}

func splitTarget(target string) (string, int, error) {
	target = strings.TrimSpace(target)
	if target == "" {
		return "", 0, common.NewError("target is required")
	}
	host, portStr := target, "443"
	if h, p, err := net.SplitHostPort(target); err == nil {
		host, portStr = h, p
	}
	host, err := netsafe.NormalizeHost(host)
	if err != nil {
		return "", 0, common.NewError("invalid target host: ", err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 1 || port > 65535 {
		return "", 0, common.NewError("invalid target port")
	}
	return host, port, nil
}

func incIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}

func enumerateCIDR(cidr string, max int) ([]string, error) {
	_, ipnet, err := net.ParseCIDR(strings.TrimSpace(cidr))
	if err != nil {
		return nil, err
	}
	ips := make([]string, 0, max)
	for ip := ipnet.IP.Mask(ipnet.Mask); ipnet.Contains(ip); incIP(ip) {
		ips = append(ips, ip.String())
		if len(ips) >= max {
			break
		}
	}
	return ips, nil
}

func probeAddr(parent context.Context, dialHost string, port int, sni string, timeout time.Duration, xver int) *Result {
	addr := net.JoinHostPort(dialHost, strconv.Itoa(port))
	res := &Result{Port: port}
	if net.ParseIP(dialHost) != nil {
		res.IP = dialHost
	}
	if sni != "" {
		res.Host = sni
		res.Target = net.JoinHostPort(sni, strconv.Itoa(port))
	} else {
		res.Host = dialHost
		res.Target = addr
	}

	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()

	start := time.Now()
	conn, err := netsafe.SSRFGuardedDialContext(ctx, "tcp", addr)
	if err != nil {
		res.Reason = "connection failed: " + err.Error()
		return res
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(timeout))

	// A REALITY inbound with xver>=1 fronts a target that speaks the PROXY
	// protocol (e.g. an Nginx listener with `proxy_protocol`), so the probe
	// must lead with a PROXY header or the target resets the connection and
	// the scan reports a spurious handshake failure (#6082).
	if xver >= 1 {
		if err := writeProxyProtocolHeader(conn, xver); err != nil {
			res.Reason = "proxy protocol write failed: " + err.Error()
			return res
		}
	}

	cfg := &tls.Config{
		ServerName:         sni,
		InsecureSkipVerify: true,
		NextProtos:         []string{"h2", "http/1.1"},
		CurvePreferences:   []tls.CurveID{tls.X25519, tls.X25519MLKEM768},
		MinVersion:         tls.VersionTLS12,
	}
	tlsConn := tls.Client(conn, cfg)
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		res.Reason = "TLS handshake failed: " + err.Error()
		return res
	}
	res.LatencyMs = int(time.Since(start).Milliseconds())

	st := tlsConn.ConnectionState()
	res.TLS13 = st.Version == tls.VersionTLS13
	res.TLSVersion = tlsVersionName(st.Version)
	res.ALPN = st.NegotiatedProtocol
	res.H2 = st.NegotiatedProtocol == "h2"
	res.CurveID = curveName(st.CurveID)
	res.X25519 = st.CurveID == tls.X25519 || st.CurveID == tls.X25519MLKEM768

	verifyHost := sni
	if len(st.PeerCertificates) > 0 {
		leaf := st.PeerCertificates[0]
		res.CertSubject = leaf.Subject.CommonName
		if res.CertSubject == "" && len(leaf.DNSNames) > 0 {
			res.CertSubject = leaf.DNSNames[0]
		}
		if len(leaf.Issuer.Organization) > 0 {
			res.CertIssuer = leaf.Issuer.Organization[0]
		} else {
			res.CertIssuer = leaf.Issuer.CommonName
		}
		res.NotAfter = leaf.NotAfter.UTC().Format(time.RFC3339)
		res.ServerNames = filterUsableSANs(leaf.DNSNames)

		if sni == "" {
			if discovered := firstUsableName(leaf); discovered != "" {
				res.Host = discovered
				res.Target = net.JoinHostPort(discovered, strconv.Itoa(port))
				verifyHost = discovered
			}
		}

		if verifyHost != "" {
			opts := x509.VerifyOptions{DNSName: verifyHost, Intermediates: x509.NewCertPool()}
			for _, c := range st.PeerCertificates[1:] {
				opts.Intermediates.AddCert(c)
			}
			if _, verr := leaf.Verify(opts); verr == nil {
				res.CertValid = true
			} else {
				res.Reason = "certificate not trusted: " + verr.Error()
			}
		} else {
			res.Reason = "no usable domain in certificate"
		}
	} else {
		res.Reason = "no certificate presented"
	}

	res.Feasible = res.TLS13 && res.H2 && res.X25519 && res.CertValid
	if !res.Feasible && res.Reason == "" {
		switch {
		case !res.TLS13:
			res.Reason = "server does not negotiate TLS 1.3"
		case !res.H2:
			res.Reason = "server does not negotiate HTTP/2 (h2)"
		case !res.X25519:
			res.Reason = "server did not use X25519 key exchange"
		}
	}
	return res
}

func probeTarget(ctx context.Context, host string, port int, xver int) *Result {
	return probeAddr(ctx, host, port, host, scanTimeout, xver)
}

// Target probes one candidate. ctx carries the caller's cancellation -- an operator who
// closes the page should not leave a probe holding a socket open for its full timeout.
func Target(ctx context.Context, target string, xver int) (*Result, error) {
	host, port, err := splitTarget(target)
	if err != nil {
		return nil, err
	}
	return probeTarget(ctx, host, port, xver), nil
}

func Targets(ctx context.Context, targetsCSV string) ([]*Result, error) {
	var tokens []string
	for raw := range strings.SplitSeq(targetsCSV, ",") {
		if t := strings.TrimSpace(raw); t != "" {
			tokens = append(tokens, t)
		}
	}
	if len(tokens) == 0 {
		tokens = append(tokens, defaultCandidates...)
	}

	var tasks []probeTask
	var invalid []*Result
	for _, token := range tokens {
		if len(tasks) >= scanMaxTotal {
			break
		}
		if strings.Contains(token, "/") {
			ips, err := enumerateCIDR(token, discoverMaxIPs)
			if err != nil {
				invalid = append(invalid, &Result{Target: token, Reason: "invalid CIDR: " + err.Error()})
				continue
			}
			for _, ip := range ips {
				if len(tasks) >= scanMaxTotal {
					break
				}
				tasks = append(tasks, probeTask{dialHost: ip, port: 443, timeout: discoverTimeout, bulk: true})
			}
			continue
		}
		host, port, err := splitTarget(token)
		if err != nil {
			invalid = append(invalid, &Result{Target: token, Reason: err.Error()})
			continue
		}
		if net.ParseIP(host) != nil {
			tasks = append(tasks, probeTask{dialHost: host, port: port, timeout: discoverTimeout})
		} else {
			tasks = append(tasks, probeTask{dialHost: host, port: port, sni: host, timeout: scanTimeout})
		}
	}

	probed := make([]*Result, len(tasks))
	sem := make(chan struct{}, scanConcurrency)
	var wg sync.WaitGroup
	for i, task := range tasks {
		wg.Add(1)
		sem <- struct{}{}
		go func(idx int, tk probeTask) {
			defer wg.Done()
			defer func() { <-sem }()
			r := probeAddr(ctx, tk.dialHost, tk.port, tk.sni, tk.timeout, 0)
			if tk.bulk && r.TLSVersion == "" {
				return
			}
			probed[idx] = r
		}(i, task)
	}
	wg.Wait()

	results := dedupResults(append(probed, invalid...))
	sortResults(results)
	return results, nil
}

func dedupResults(results []*Result) []*Result {
	best := make(map[string]*Result)
	order := make([]string, 0, len(results))
	for _, r := range results {
		if r == nil {
			continue
		}
		if ex, ok := best[r.Target]; !ok {
			best[r.Target] = r
			order = append(order, r.Target)
		} else if betterResult(r, ex) {
			best[r.Target] = r
		}
	}
	out := make([]*Result, 0, len(order))
	for _, k := range order {
		out = append(out, best[k])
	}
	return out
}

func betterResult(a, b *Result) bool {
	if a.Feasible != b.Feasible {
		return a.Feasible
	}
	return a.LatencyMs > 0 && (b.LatencyMs == 0 || a.LatencyMs < b.LatencyMs)
}

func sortResults(results []*Result) {
	slices.SortStableFunc(results, func(a, b *Result) int {
		if a.Feasible != b.Feasible {
			if a.Feasible {
				return -1
			}
			return 1
		}
		return a.LatencyMs - b.LatencyMs
	})
}

// writeProxyProtocolHeader emits a PROXY protocol header describing the local
// connection so a target that requires it (Nginx `proxy_protocol`, matching a
// REALITY inbound's xver) accepts the probe instead of resetting it. xver 1
// sends the human-readable v1 header; xver 2 sends the binary v2 header. The
// addresses come from the already-dialed connection, so they are always a
// consistent, real (src, dst) pair.
func writeProxyProtocolHeader(conn net.Conn, xver int) error {
	local, lok := conn.LocalAddr().(*net.TCPAddr)
	remote, rok := conn.RemoteAddr().(*net.TCPAddr)
	if !lok || !rok {
		return fmt.Errorf("connection has no TCP addresses")
	}
	if xver >= 2 {
		return writeProxyProtocolV2(conn, local, remote)
	}
	return writeProxyProtocolV1(conn, local, remote)
}

func writeProxyProtocolV1(conn net.Conn, local, remote *net.TCPAddr) error {
	fam := "TCP4"
	if local.IP.To4() == nil || remote.IP.To4() == nil {
		fam = "TCP6"
	}
	header := fmt.Sprintf("PROXY %s %s %s %d %d\r\n", fam, local.IP.String(), remote.IP.String(), local.Port, remote.Port)
	_, err := conn.Write([]byte(header))
	return err
}

func writeProxyProtocolV2(conn net.Conn, local, remote *net.TCPAddr) error {
	buf := []byte{0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A}
	buf = append(buf, 0x21)

	src4, dst4 := local.IP.To4(), remote.IP.To4()
	if src4 != nil && dst4 != nil {
		buf = append(buf, 0x11)
		buf = append(buf, 0x00, 12)
		buf = append(buf, src4...)
		buf = append(buf, dst4...)
		buf = append(buf, byte(local.Port>>8), byte(local.Port))
		buf = append(buf, byte(remote.Port>>8), byte(remote.Port))
	} else {
		buf = append(buf, 0x21)
		buf = append(buf, 0x00, 36)
		buf = append(buf, local.IP.To16()...)
		buf = append(buf, remote.IP.To16()...)
		buf = append(buf, byte(local.Port>>8), byte(local.Port))
		buf = append(buf, byte(remote.Port>>8), byte(remote.Port))
	}
	_, err := conn.Write(buf)
	return err
}
