package service

import (
	"encoding/json"
	"strings"

	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
)

// Relaying an inbound through an Iran node takes TWO halves. The panel has
// always done the first — an "external proxy" entry rewrites the address handed
// to clients so they dial the relay instead of this server. The second half,
// making the relay actually carry that port, was left to the operator on the
// Tunnels page, and nothing said so: clients reached the node and the connection
// died there.
//
// The trap was worst for the VPN protocols. The port-forward editor defaults to
// tcp, which is right for VLESS and wrong for OpenVPN — a tcp forward for a UDP
// service looks configured and carries nothing.
//
// So the forwards an inbound needs are derived from the inbound itself and
// applied to whichever node the external proxy points at.

// relayForward is one port the relay has to carry for an inbound.
type relayForward struct {
	proto string // "tcp" | "udp"
	port  int
}

// inboundForwards returns the ports a relay must carry for this inbound.
//
// The transport is taken from the protocol rather than assumed, because getting
// it wrong is silent. Protocols that genuinely run on both get both entries.
func inboundForwards(inbound *model.Inbound) []relayForward {
	port := inbound.Port
	if port <= 0 {
		return nil
	}
	both := []relayForward{{"tcp", port}, {"udp", port}}

	switch inbound.Protocol {
	case model.OPENVPN:
		return openvpnForwards(inbound)

	case model.WireGuard, model.AWG, model.WGC:
		// WireGuard and its obfuscated variants are UDP-only.
		return []relayForward{{"udp", port}}

	case model.L2TP, model.IKEV2:
		// L2TP/IPsec and IKEv2 negotiate on UDP 500 and, behind NAT, move to
		// UDP 4500 (NAT-T). Both are fixed IANA ports, not the inbound's own.
		// ESP (IP protocol 50) cannot be port-forwarded at all, which is exactly
		// why NAT-T exists and why 4500 is not optional here.
		return []relayForward{{"udp", 500}, {"udp", 4500}}

	case model.Hysteria, model.Hysteria2:
		// QUIC-based.
		return []relayForward{{"udp", port}}

	case model.PPTP:
		// PPTP's control channel is TCP 1723; its data channel is GRE, which no
		// port forward can carry. Relaying PPTP needs a GRE-capable path, so the
		// control port alone is all that can be expressed here.
		return []relayForward{{"tcp", 1723}}

	case model.VLESS, model.VMESS, model.Trojan, model.Shadowsocks, model.HTTP,
		model.Mixed, model.SSH, model.MTPROTO, model.SSTP, model.OPENCONNECT:
		// TCP by default. Shadowsocks and the xray protocols can carry UDP over
		// the same port when the client asks for it, so both are forwarded —
		// an unused UDP rule costs nothing.
		if inbound.Protocol == model.SSTP || inbound.Protocol == model.SSH {
			return []relayForward{{"tcp", port}}
		}
		return both

	default:
		return both
	}
}

// openvpnForwards reads the inbound's own transport settings: OpenVPN can run
// UDP, TCP, or both, optionally on a second port, and forwarding the wrong one
// leaves clients hanging.
func openvpnForwards(inbound *model.Inbound) []relayForward {
	var s struct {
		Proto         string `json:"proto"`
		TcpEnable     *bool  `json:"tcpEnable"`
		TcpPort       int    `json:"tcpPort"`
		SeparatePorts *bool  `json:"separatePorts"`
	}
	if json.Unmarshal([]byte(inbound.Settings), &s) != nil {
		return []relayForward{{"udp", inbound.Port}}
	}

	var out []relayForward
	if !strings.EqualFold(s.Proto, "tcp") {
		out = append(out, relayForward{"udp", inbound.Port})
	}
	// tcpEnable is nil-means-enabled, matching openvpnSettings.
	if s.TcpEnable == nil || *s.TcpEnable {
		tcpPort := inbound.Port
		// separatePorts nil means the legacy layout, where TCP used tcpPort.
		if (s.SeparatePorts == nil || *s.SeparatePorts) && s.TcpPort > 0 {
			tcpPort = s.TcpPort
		}
		out = append(out, relayForward{"tcp", tcpPort})
	}
	if len(out) == 0 {
		out = append(out, relayForward{"udp", inbound.Port})
	}
	return out
}

// externalProxyDests pulls the relay addresses out of an inbound, from either
// place the panel stores them: streamSettings for the xray protocols, settings
// for the VPN ones.
func externalProxyDests(inbound *model.Inbound) []string {
	type ep struct {
		Dest string `json:"dest"`
	}
	seen := map[string]bool{}
	var out []string

	collect := func(raw string) {
		if strings.TrimSpace(raw) == "" {
			return
		}
		var holder struct {
			ExternalProxy []ep `json:"externalProxy"`
		}
		if json.Unmarshal([]byte(raw), &holder) != nil {
			return
		}
		for _, e := range holder.ExternalProxy {
			d := strings.TrimSpace(e.Dest)
			if d != "" && !seen[d] {
				seen[d] = true
				out = append(out, d)
			}
		}
	}
	collect(inbound.Settings)
	collect(inbound.StreamSettings)
	return out
}

// SyncRelayForwards makes every node an inbound points at carry that inbound's
// ports. Never returns an error: an inbound must save even when the relay is
// offline or has no tunnel yet, so problems are logged rather than raised.
func (s *InboundService) SyncRelayForwards(inbound *model.Inbound) {
	if inbound == nil || !inbound.Enable {
		return
	}
	dests := externalProxyDests(inbound)
	if len(dests) == 0 {
		return
	}
	forwards := inboundForwards(inbound)
	if len(forwards) == 0 {
		return
	}

	var nodeService NodeService
	for _, dest := range dests {
		for _, f := range forwards {
			applied, err := nodeService.EnsureForward(dest, f.proto, f.port)
			switch {
			case err != nil:
				logger.Warningf("relay forward %s:%d for inbound %d (%s) not applied on %s: %v",
					f.proto, f.port, inbound.Id, inbound.Protocol, dest, err)
			case applied != "":
				logger.Info("relay forward added: ", applied,
					" (inbound ", inbound.Id, " ", inbound.Protocol, ")")
			}
		}
	}
}
