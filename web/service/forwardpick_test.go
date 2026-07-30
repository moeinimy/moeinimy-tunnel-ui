package service

import "testing"

// A node commonly runs SEVERAL tunnels — one shaped for xray, another carrying the
// VPN ports — and the panel has to send each forward to the one that can actually
// carry it. It used to decide on FORWARD_MODE, a GRE-ONLY field, so on the
// userspace relays every candidate scored the same and the first tunnel the node
// listed won. The case below is the one that broke in the field: UDP 500 aimed at a
// backhaul/tcpmux tunnel, refused for a real limit of the WRONG tunnel, while the
// rathole beside it — which holds the L2TP ports and carries UDP on any transport —
// was never considered.
func TestPickForwardingTunnel(t *testing.T) {
	backhaulMux := nodeTunnel{
		name: "Bp", protocol: "backhaul", transport: "tcpmux",
		forwards: "443=443;2087=2087",
	}
	backhaulTCP := nodeTunnel{
		name: "Bp", protocol: "backhaul", transport: "tcp",
		forwards: "443=443",
	}
	rathole := nodeTunnel{
		name: "Rh", protocol: "rathole",
		forwards: "1194=1194",
	}
	ratholeEmpty := nodeTunnel{name: "Rh", protocol: "rathole"}
	greAll := nodeTunnel{name: "Gr", protocol: "gre", mode: "all"}

	cases := []struct {
		name  string
		all   []nodeTunnel
		proto string
		port  int
		want  string
	}{
		{
			name:  "udp goes to the rathole, not the tcpmux backhaul listed first",
			all:   []nodeTunnel{backhaulMux, rathole},
			proto: "udp", port: 500, want: "Rh",
		},
		{
			name:  "udp still finds the rathole when it has no forwards yet",
			all:   []nodeTunnel{backhaulMux, ratholeEmpty},
			proto: "udp", port: 500, want: "Rh",
		},
		{
			name:  "a tcp port already forwarded stays where it is",
			all:   []nodeTunnel{backhaulMux, rathole},
			proto: "tcp", port: 443, want: "Bp",
		},
		{
			name:  "a tcp port the rathole already carries stays there",
			all:   []nodeTunnel{backhaulMux, rathole},
			proto: "tcp", port: 1194, want: "Rh",
		},
		{
			name:  "backhaul on plain tcp may carry udp itself",
			all:   []nodeTunnel{backhaulTCP},
			proto: "udp", port: 500, want: "Bp",
		},
		{
			name:  "gre in blanket mode carries udp with no entries at all",
			all:   []nodeTunnel{greAll},
			proto: "udp", port: 500, want: "Gr",
		},
		{
			// Nothing can carry it, so SOMETHING is returned: EnsureForward's refusal
			// then names a real tunnel and its real limit, which is far more useful
			// than "this node has no tunnel yet".
			name:  "no candidate still returns a tunnel so the error is specific",
			all:   []nodeTunnel{backhaulMux},
			proto: "udp", port: 500, want: "Bp",
		},
		{
			name:  "no tunnels at all",
			all:   nil,
			proto: "udp", port: 500, want: "",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := pickForwardingTunnel(tc.all, tc.proto, tc.port).name; got != tc.want {
				t.Errorf("picked %q, want %q", got, tc.want)
			}
		})
	}
}

// canCarry is what both the selection and the refusal consult, so a tunnel can
// never be chosen on one rule and rejected on another.
func TestNodeTunnelCanCarry(t *testing.T) {
	cases := []struct {
		tunnel nodeTunnel
		proto  string
		want   bool
	}{
		{nodeTunnel{protocol: "rathole"}, "udp", true},
		{nodeTunnel{protocol: "rathole"}, "tcp", true},
		{nodeTunnel{protocol: "gre"}, "udp", true},
		{nodeTunnel{protocol: "paqet"}, "udp", true},
		{nodeTunnel{protocol: "hysteria"}, "udp", true},
		// accept_udp is wired to these two relays' plain TCP transport alone.
		{nodeTunnel{protocol: "backhaul", transport: "tcp"}, "udp", true},
		{nodeTunnel{protocol: "backhaul", transport: "tcpmux"}, "udp", false},
		{nodeTunnel{protocol: "backhaul", transport: "wsmux"}, "udp", false},
		{nodeTunnel{protocol: "backpack", transport: "wssmux"}, "udp", false},
		{nodeTunnel{protocol: "backpack", transport: "tcp"}, "udp", true},
		// TCP is fine on all of them.
		{nodeTunnel{protocol: "backpack", transport: "wssmux"}, "tcp", true},
		// gost and frp emit no UDP listener yet.
		{nodeTunnel{protocol: "gost"}, "udp", false},
		{nodeTunnel{protocol: "frp"}, "udp", false},
		{nodeTunnel{protocol: "nonsense"}, "tcp", false},
	}
	for _, tc := range cases {
		if got := tc.tunnel.canCarry(tc.proto); got != tc.want {
			t.Errorf("%s/%s carrying %s: got %v, want %v",
				tc.tunnel.protocol, tc.tunnel.transport, tc.proto, got, tc.want)
		}
	}
}
