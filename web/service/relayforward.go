package service

import (
	"encoding/json"
	"fmt"
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
// It reads the inbound's real settings type rather than a local copy of the
// fields: an earlier version declared its own struct with a "proto" key that
// does not exist in the stored JSON, so it always saw the zero value, always
// concluded UDP was in use, and asked the relay for a UDP forward even on a
// TCP-only inbound.
func openvpnForwards(inbound *model.Inbound) []relayForward {
	var o openvpnSettings
	if json.Unmarshal([]byte(inbound.Settings), &o) != nil {
		return []relayForward{{"udp", inbound.Port}}
	}
	var out []relayForward
	// UDP always listens on the inbound's own port; TCP may share it or have its
	// own, which is what tcpListenPort decides.
	if o.udpEnabled() {
		out = append(out, relayForward{"udp", inbound.Port})
	}
	if o.tcpEnabled() {
		out = append(out, relayForward{"tcp", o.tcpListenPort(inbound.Port)})
	}
	// The same inbound may also answer L2TP/IPsec (l2tpEnable), and that half does
	// not live on the inbound's port at all: it negotiates on the fixed UDP 500 and
	// moves to 4500 behind NAT — which a relay always is. Without these the OpenVPN
	// half worked through the node and the L2TP half could not even begin, since
	// nothing carried the IKE packets. Same two ports the L2TP protocol's own case
	// asks for, for the same reason.
	if enabled, _ := o.l2tpServingSettings(); enabled {
		out = append(out, relayForward{"udp", 500}, relayForward{"udp", 4500})
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
			// `forwards` is passed whole so the node can keep ONE inbound's ports
			// together: a node with several tunnels must not scatter a service's
			// TCP port across one and its UDP ports across another.
			applied, err := nodeService.EnsureForward(dest, f.proto, f.port, forwards)
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

// tunnelPortSpec describes how one tunnel protocol expresses its client
// port-forwards, and whether it can carry UDP at all.
//
// GRE and Paqet keep a FORWARDS list of "proto:local:dest" and program iptables.
// The userspace relays keep a "<PREFIX>_PORTS" map of "local=dest", to which a
// "udp:" prefix may now be added ("udp:500=500"); an entry without one is TCP, so
// every list written before this stays exactly what it was.
//
// The udp flag is about the RELAY, not the syntax. It used to be false for all of
// them on the grounds that they "proxy TCP streams only", which was true of the
// configs this panel wrote and not of the programs:
//
//   - rathole takes type = "tcp" | "udp" PER SERVICE and carries both in one
//     tunnel — the driver simply always wrote "tcp".
//   - backhaul and backpack take accept_udp, "Enable transferring UDP connections
//     over TCP transport", and the driver hard-wrote accept_udp = false.
//
// So a customer's L2TP could not follow their VLESS down the same relay for a
// reason that was only ever a hardcoded literal. gost and frp are left false: gost
// needs a udp:// listener the driver does not emit yet, and frp needs its own
// per-proxy type — both are the same shape of change, neither is done here.
//
// Getting this flag wrong is silent, which is why it is conservative: a UDP service
// behind a relay that drops it presents as the relay listening, the client
// connecting, and the far end never seeing a packet.
//
// relayAll records whether the driver actually IMPLEMENTS FORWARD_MODE=all, and it
// is deliberately not assumed from the setting existing. The schema offers
// "none all ports" for every tunnel (tunnel/modules/schema.sh), but only the GRE
// driver acts on "all" — gre_relay_all() installs the blanket
// PREROUTING DNAT for tcp AND udp, minus FORWARD_EXCEPT. No other driver reads the
// value, so on those a tunnel set to "all" forwards NOTHING.
//
// That matters because EnsureForward treats "all" as "already relayed" and stops.
// On a paqet tunnel set to "all" that meant the panel quietly declined to add the
// port while the tunnel carried none of it: the operator sees a saved inbound, a
// configured tunnel, and a service nothing reaches.
type tunnelPortSpec struct {
	field     string // settings key holding the forward list
	protoForm bool   // true: "proto:local:dest"; false: "[udp:]local=dest"
	udp       bool   // can this tunnel carry UDP?
	relayAll  bool   // does this driver implement FORWARD_MODE=all?
}

func tunnelPortSpecFor(protocol string) (tunnelPortSpec, bool) {
	switch strings.ToLower(strings.TrimSpace(protocol)) {
	case "gre":
		return tunnelPortSpec{"FORWARDS", true, true, true}, true
	case "paqet":
		return tunnelPortSpec{"FORWARDS", true, true, false}, true
	case "hysteria":
		return tunnelPortSpec{"HY_PORTS", false, true, false}, true
	case "rathole":
		return tunnelPortSpec{"RH_PORTS", false, true, false}, true
	case "backhaul":
		return tunnelPortSpec{"BH_PORTS", false, true, false}, true
	case "backpack":
		return tunnelPortSpec{"BP_PORTS", false, true, false}, true
	case "gost":
		return tunnelPortSpec{"GO_PORTS", false, false, false}, true
	case "frp":
		return tunnelPortSpec{"FRP_PORTS", false, false, false}, true
	}
	return tunnelPortSpec{}, false
}

// entry renders one forward in this tunnel's own syntax.
//
// TCP entries keep the bare "local=dest" they have always had, so nothing has to
// rewrite a list that already exists; UDP is the new spelling and is marked.
func (s tunnelPortSpec) entry(proto string, port int) string {
	if s.protoForm {
		return fmt.Sprintf("%s:%d:%d", proto, port, port)
	}
	if proto == "udp" {
		return fmt.Sprintf("udp:%d=%d", port, port)
	}
	return fmt.Sprintf("%d=%d", port, port)
}
