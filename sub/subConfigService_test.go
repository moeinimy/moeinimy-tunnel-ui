package sub

import (
	"strings"
	"testing"
)

// The renderer's Remark already carries the device number and endpoint label, so the
// button text must not compose its own: that produced "WireGuard Device 1 Device 1 - edge".
func TestWgLabelUsesRendererRemarkAsIs(t *testing.T) {
	cases := []struct {
		name, proto, cfgRemark, inboundRemark, want string
	}{
		{"device and endpoint", "WireGuard", "Device 2 - edge", "home",
			"WireGuard Device 2 - edge (home)"},
		{"endpoint only", "AmneziaWG", "edge", "home", "AmneziaWG edge (home)"},
		{"single config", "WireGuard", "", "home", "WireGuard config (home)"},
		{"no inbound remark", "WireGuard", "", "", "WireGuard config"},
		{"remark is whitespace", "AmneziaWG", "  ", "  ", "AmneziaWG config"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := wgLabel(c.proto, c.cfgRemark, c.inboundRemark); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// The filename lands in a Content-Disposition header and is built from admin-supplied
// text (inbound remarks, external-proxy labels), so it has to come out as a plain,
// single-token name whatever goes in.
func TestConfigFilenameIsSafe(t *testing.T) {
	cases := []struct {
		name, remark, proto, variant, ext, want string
	}{
		{"plain", "home", "wg", "Device 2 - edge", "conf", "home-Device-2-edge.conf"},
		{"empty remark falls back to protocol", "", "openvpn", "udp", "ovpn", "openvpn-udp.ovpn"},
		{"path separators dropped", "../../etc/passwd", "wg", "1", "conf", "etcpasswd-1.conf"},
		{"quotes and spaces dropped", `my "vpn" box`, "awg", "1", "conf", "my-vpn-box-1.conf"},
		{"non-ascii dropped", "خانه", "wg", "2", "conf", "wg-2.conf"},
		{"crlf dropped", "a\r\nb", "wg", "1", "conf", "ab-1.conf"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := configFilename(c.remark, c.proto, c.variant, c.ext)
			if got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
			for _, bad := range []string{"/", "\\", `"`, " ", "\r", "\n", ".."} {
				if strings.Contains(got, bad) {
					t.Fatalf("filename %q still contains %q", got, bad)
				}
			}
		})
	}
}
