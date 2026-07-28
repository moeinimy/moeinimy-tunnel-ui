package sub

import (
	"encoding/json"
	"strconv"
	"strings"

	"github.com/mhsanaei/3x-ui/v2/database/model"
)

// The credential VPNs, spelled out for the subscriber.
//
// A VLESS customer needs a link and nothing else, so the subscription URL is the whole
// answer for them. An OpenVPN customer needs a username, a password, a server address, a
// port and — when the inbound also serves L2TP/IPsec — a pre-shared key, and none of that
// can travel in a link a proxy client would import. genConnectionCard already folds it
// into a trojan:// URI so the account HAS an entry in a subscription client (which is how
// the quota and expiry in the Subscription-Userinfo header find something to attach to),
// but that entry is a link label: unreadable to a person, and not what someone opening the
// page in a browser is looking for.
//
// So the browser view gets the same facts as fields. A customer holding only an OpenVPN
// account can open their subscription link, see how much traffic is left, and read off
// exactly what to type; a combined customer sees their VLESS link and their OpenVPN login
// on one page, because they are one person with one allowance.
//
// The subId is the only credential, exactly as for the subscription itself: accounts are
// looked up FROM it, never from anything the caller passes.

// SubAccountField is one label/value pair, in the order a person reads them.
type SubAccountField struct {
	Label string
	// Note qualifies the label without changing it: the operator's own name for an
	// external-proxy endpoint ("germany", "cdn"), which is the reason they configured
	// more than one and the only way a customer can tell two Server rows apart.
	Note  string
	Value string
	Mono  bool
}

// SubAccount is one credential-VPN account behind a subscription.
type SubAccount struct {
	Protocol string
	Label    string
	Fields   []SubAccountField
}

// Accounts returns the credential-VPN accounts the subscription holds, in inbound order.
// Link-based protocols are absent by design: their entry in the list above IS their
// credential, and repeating a UUID as a field invites someone to type it by hand.
//
// host is the address the subscriber reached the sub server on, used as the server
// address when the inbound does not listen on a specific one — the same rule the links
// and the config downloads follow, so a customer comparing them never sees them disagree.
func (s *SubService) Accounts(subId string, host string) []SubAccount {
	s.address = host
	inbounds, err := s.getInboundsBySubId(subId)
	if err != nil {
		return nil
	}

	var out []SubAccount
	for _, inbound := range inbounds {
		if !isCredentialVpn(inbound.Protocol) {
			continue
		}
		clients, err := s.inboundService.GetClients(inbound)
		if err != nil {
			continue
		}
		var settings map[string]any
		_ = json.Unmarshal([]byte(inbound.Settings), &settings)

		for _, client := range clients {
			if !client.Enable || client.SubID != subId {
				continue
			}
			fields := endpointFields(inbound, settings, host)
			// The login name is the account id, which is what the panel shows the
			// operator as the username and what the .ovpn profile prompts for. The
			// RADIUS backends accept the email too (service/radius.go), so a customer
			// who was given either can still connect.
			username := client.ID
			if username == "" {
				username = client.Email
			}
			fields = append(fields, SubAccountField{Label: "username", Value: username, Mono: true})
			if client.Password != "" {
				fields = append(fields, SubAccountField{Label: "password", Value: client.Password, Mono: true})
			}
			if psk := ipsecPskFor(inbound.Protocol, settings); psk != "" {
				fields = append(fields, SubAccountField{Label: "psk", Value: psk, Mono: true})
			}
			// An OpenVPN inbound can serve its accounts over L2TP/IPsec as well, with
			// the SAME username and password. The customer cannot tell from the account
			// that this is available, and the PSK they would need lives on the inbound.
			if inbound.Protocol == model.OPENVPN {
				if en, _ := settings["l2tpEnable"].(bool); en {
					fields = append(fields, SubAccountField{Label: "alsoL2tp", Value: ""})
					if psk, _ := settings["ipsecPsk"].(string); strings.TrimSpace(psk) != "" {
						fields = append(fields, SubAccountField{Label: "psk", Value: psk, Mono: true})
					}
				}
			}

			out = append(out, SubAccount{
				Protocol: string(inbound.Protocol),
				Label:    protocolLabel(inbound.Protocol) + labelSuffix(inbound.Remark),
				Fields:   fields,
			})
		}
	}
	return out
}

// endpointFields is the address half of an account: where to connect, and on what port.
//
// An external proxy WINS over the inbound's own address whenever one is configured. That
// is the entire point of the setting — the inbound listens on an origin the customer is
// not meant to reach, and the proxy is the address that actually works from where they
// are. Handing out the origin instead is not a cosmetic difference; it is a config that
// cannot connect. Every entry is listed, because an operator configures several so the
// customer can fall back between them.
func endpointFields(inbound *model.Inbound, settings map[string]any, host string) []SubAccountField {
	proxies, _ := settings["externalProxy"].([]any)
	var fields []SubAccountField
	for _, raw := range proxies {
		ep, _ := raw.(map[string]any)
		dest, _ := ep["dest"].(string)
		dest = strings.TrimSpace(dest)
		if dest == "" {
			continue
		}
		note, _ := ep["remark"].(string)
		note = strings.TrimSpace(note)
		port := inbound.Port
		if p, ok := ep["port"].(float64); ok && int(p) > 0 {
			port = int(p)
		}
		fields = append(fields,
			SubAccountField{Label: "server", Note: note, Value: dest, Mono: true},
			SubAccountField{Label: "port", Value: strconv.Itoa(port), Mono: true},
		)
	}
	if len(fields) > 0 {
		return fields
	}

	server := host
	if l := strings.TrimSpace(inbound.Listen); l != "" && l != "0.0.0.0" && l != "::" {
		server = l
	}
	return []SubAccountField{
		{Label: "server", Value: server, Mono: true},
		{Label: "port", Value: vpnPorts(inbound, settings), Mono: true},
	}
}

// isCredentialVpn reports whether a protocol authenticates with a username and password
// the customer types in, rather than with a link or a config file they import.
func isCredentialVpn(p model.Protocol) bool {
	switch p {
	case model.OPENVPN, model.L2TP, model.PPTP, model.SSTP, model.OPENCONNECT, model.IKEV2:
		return true
	}
	return false
}

// vpnPorts is the port (or ports) the customer can actually reach the inbound on. Only
// OpenVPN has more than one: its TCP transport can be given a port of its own, and either
// transport can be switched off.
func vpnPorts(inbound *model.Inbound, settings map[string]any) string {
	if inbound.Protocol != model.OPENVPN {
		return strconv.Itoa(inbound.Port)
	}
	boolOr := func(key string, def bool) bool {
		if v, ok := settings[key].(bool); ok {
			return v
		}
		return def
	}
	var parts []string
	if boolOr("udpEnable", true) {
		parts = append(parts, strconv.Itoa(inbound.Port)+"/UDP")
	}
	if boolOr("tcpEnable", true) {
		port := inbound.Port
		if boolOr("separatePorts", false) {
			if p, ok := settings["tcpPort"].(float64); ok && int(p) > 0 {
				port = int(p)
			}
		}
		parts = append(parts, strconv.Itoa(port)+"/TCP")
	}
	if len(parts) == 0 {
		return strconv.Itoa(inbound.Port)
	}
	return strings.Join(parts, "  ·  ")
}

// ipsecPskFor returns the inbound's pre-shared key when the protocol is configured to use
// one. Mirrors genConnectionCard so the card and the page cannot disagree about whether a
// key is in play.
func ipsecPskFor(p model.Protocol, settings map[string]any) string {
	switch p {
	case model.L2TP:
		if en, _ := settings["ipsecEnable"].(bool); en {
			if psk, _ := settings["ipsecPsk"].(string); strings.TrimSpace(psk) != "" {
				return psk
			}
		}
	case model.IKEV2:
		if mode, _ := settings["authMode"].(string); mode == "psk" {
			if psk, _ := settings["psk"].(string); strings.TrimSpace(psk) != "" {
				return psk
			}
		}
	}
	return ""
}
