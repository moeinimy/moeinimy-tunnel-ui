package service

import (
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database/model"
)

func has(t *testing.T, got []relayForward, proto string, port int) bool {
	t.Helper()
	for _, f := range got {
		if f.proto == proto && f.port == port {
			return true
		}
	}
	return false
}

// The bug this guards: an OpenVPN inbound relayed through an Iran node got a tcp
// forward (the editor's default) while OpenVPN was speaking UDP, so clients
// reached the relay and nothing carried them onward.
func TestOpenVPNForwardsFollowItsTransport(t *testing.T) {
	cases := []struct {
		name     string
		settings string
		port     int
		wantUDP  []int
		wantTCP  []int
	}{
		{
			name:     "default udp+tcp, separate tcp port",
			settings: `{"udpEnable":true,"tcpEnable":true,"tcpPort":1195,"separatePorts":true}`,
			port:     1194,
			wantUDP:  []int{1194},
			wantTCP:  []int{1195},
		},
		{
			name:     "udp only",
			settings: `{"udpEnable":true,"tcpEnable":false}`,
			port:     1194,
			wantUDP:  []int{1194},
		},
		{
			name:     "tcp only",
			settings: `{"udpEnable":false,"tcpEnable":true,"separatePorts":false}`,
			port:     443,
			wantTCP:  []int{443},
		},
		{
			name:     "both on one port",
			settings: `{"udpEnable":true,"tcpEnable":true,"separatePorts":false}`,
			port:     1194,
			wantUDP:  []int{1194},
			wantTCP:  []int{1194},
		},
		{
			name:     "udp off, tcp on a separate port (the reported case)",
			settings: `{"udpEnable":false,"tcpEnable":true,"tcpPort":2095,"separatePorts":true}`,
			port:     1195,
			wantTCP:  []int{2095},
		},
		{
			name:     "unparseable settings still forwards udp",
			settings: `not json`,
			port:     1194,
			wantUDP:  []int{1194},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := inboundForwards(&model.Inbound{
				Protocol: model.OPENVPN, Port: tc.port, Settings: tc.settings,
			})
			for _, p := range tc.wantUDP {
				if !has(t, got, "udp", p) {
					t.Errorf("missing udp:%d in %v", p, got)
				}
			}
			for _, p := range tc.wantTCP {
				if !has(t, got, "tcp", p) {
					t.Errorf("missing tcp:%d in %v", p, got)
				}
			}
			if len(tc.wantTCP) == 0 {
				for _, f := range got {
					if f.proto == "tcp" {
						t.Errorf("unexpected tcp forward %d in %v", f.port, got)
					}
				}
			}
		})
	}
}

// L2TP/IPsec and IKEv2 negotiate on fixed UDP ports, not the inbound's own, and
// fall back to 4500 behind NAT — which a relay always is.
func TestIpsecProtocolsForwardNatTraversalPorts(t *testing.T) {
	for _, proto := range []model.Protocol{model.L2TP, model.IKEV2} {
		got := inboundForwards(&model.Inbound{Protocol: proto, Port: 1701})
		if !has(t, got, "udp", 500) || !has(t, got, "udp", 4500) {
			t.Errorf("%s: want udp 500 and 4500, got %v", proto, got)
		}
	}
}

func TestUdpOnlyProtocols(t *testing.T) {
	for _, proto := range []model.Protocol{model.WireGuard, model.AWG, model.WGC, model.Hysteria2} {
		got := inboundForwards(&model.Inbound{Protocol: proto, Port: 51820})
		if len(got) != 1 || got[0].proto != "udp" || got[0].port != 51820 {
			t.Errorf("%s: want a single udp:51820, got %v", proto, got)
		}
	}
}

func TestVlessGetsTcpForward(t *testing.T) {
	got := inboundForwards(&model.Inbound{Protocol: model.VLESS, Port: 443})
	if !has(t, got, "tcp", 443) {
		t.Errorf("vless must forward tcp:443, got %v", got)
	}
}

func TestNoForwardsWithoutAPort(t *testing.T) {
	if got := inboundForwards(&model.Inbound{Protocol: model.VLESS, Port: 0}); got != nil {
		t.Errorf("port 0 must yield no forwards, got %v", got)
	}
}

// The relay address is read from whichever field the protocol stores it in:
// VPN inbounds keep externalProxy in settings, xray ones in streamSettings.
func TestExternalProxyDestsFromBothFields(t *testing.T) {
	in := &model.Inbound{
		Settings:       `{"externalProxy":[{"dest":"1.2.3.4","port":1194}]}`,
		StreamSettings: `{"externalProxy":[{"dest":"relay.example.com"},{"dest":"1.2.3.4"}]}`,
	}
	got := externalProxyDests(in)
	if len(got) != 2 {
		t.Fatalf("want 2 de-duplicated dests, got %v", got)
	}
	seen := map[string]bool{got[0]: true, got[1]: true}
	if !seen["1.2.3.4"] || !seen["relay.example.com"] {
		t.Errorf("unexpected dests: %v", got)
	}
}

func TestNoExternalProxyMeansNothingToDo(t *testing.T) {
	if got := externalProxyDests(&model.Inbound{Settings: `{"clients":[]}`}); len(got) != 0 {
		t.Errorf("want none, got %v", got)
	}
}
