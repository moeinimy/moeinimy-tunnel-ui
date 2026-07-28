package sub

import (
	"encoding/json"
	"testing"

	"github.com/mhsanaei/3x-ui/v2/database/model"
)

func settingsOf(t *testing.T, raw string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("settings: %v", err)
	}
	return m
}

func labels(fields []SubAccountField) []string {
	out := make([]string, 0, len(fields))
	for _, f := range fields {
		v := f.Label + "=" + f.Value
		if f.Note != "" {
			v += "(" + f.Note + ")"
		}
		out = append(out, v)
	}
	return out
}

func eq(t *testing.T, got, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range got {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

// An inbound with no external proxy hands out the address the subscriber reached the
// panel on, which is the same rule the links and the .ovpn downloads follow.
func TestEndpointFieldsFallsBackToTheRequestHost(t *testing.T) {
	in := &model.Inbound{Protocol: model.OPENVPN, Port: 1194, Listen: ""}
	s := settingsOf(t, `{"udpEnable":true,"tcpEnable":true}`)
	eq(t, labels(endpointFields(in, s, "vpn.example.com")), []string{
		"server=vpn.example.com",
		"port=1194/UDP  ·  1194/TCP",
	})
}

// A listen address that is not a wildcard is more specific than the request host, so it
// wins over it -- but still loses to an external proxy.
func TestEndpointFieldsPrefersAnExplicitListen(t *testing.T) {
	in := &model.Inbound{Protocol: model.L2TP, Port: 1701, Listen: "10.0.0.5"}
	eq(t, labels(endpointFields(in, settingsOf(t, `{}`), "vpn.example.com")), []string{
		"server=10.0.0.5",
		"port=1701",
	})
}

// The case this function exists for. The inbound listens on an origin the customer is
// not meant to reach; handing them that origin is an address that cannot connect.
func TestEndpointFieldsPrefersEveryExternalProxy(t *testing.T) {
	in := &model.Inbound{Protocol: model.OPENVPN, Port: 1194, Listen: "10.0.0.5"}
	s := settingsOf(t, `{"udpEnable":true,"tcpEnable":true,"externalProxy":[
		{"dest":"de.example.com","port":1195,"remark":"germany"},
		{"dest":"cdn.example.com","port":8443,"remark":""}]}`)
	eq(t, labels(endpointFields(in, s, "vpn.example.com")), []string{
		"server=de.example.com(germany)",
		"port=1195",
		"server=cdn.example.com",
		"port=8443",
	})
}

// A half-filled proxy row is skipped rather than published as a blank address, and if
// that leaves nothing the inbound's own address is used after all.
func TestEndpointFieldsIgnoresEmptyProxyEntries(t *testing.T) {
	in := &model.Inbound{Protocol: model.OPENVPN, Port: 1194}
	s := settingsOf(t, `{"externalProxy":[{"dest":"  ","port":1195,"remark":"x"}]}`)
	eq(t, labels(endpointFields(in, s, "vpn.example.com")), []string{
		"server=vpn.example.com",
		"port=1194/UDP  ·  1194/TCP",
	})
}

// A proxy row with no port of its own inherits the inbound's, rather than advertising 0.
func TestEndpointFieldsInheritsThePortFromTheInbound(t *testing.T) {
	in := &model.Inbound{Protocol: model.SSTP, Port: 443}
	s := settingsOf(t, `{"externalProxy":[{"dest":"edge.example.com"}]}`)
	eq(t, labels(endpointFields(in, s, "vpn.example.com")), []string{
		"server=edge.example.com",
		"port=443",
	})
}

func TestVpnPorts(t *testing.T) {
	tests := []struct {
		name     string
		protocol model.Protocol
		port     int
		settings string
		want     string
	}{
		{"non-openvpn is just the port", model.IKEV2, 500, `{}`, "500"},
		{"both transports share the port", model.OPENVPN, 1194,
			`{"udpEnable":true,"tcpEnable":true}`, "1194/UDP  ·  1194/TCP"},
		{"tcp can have its own", model.OPENVPN, 1194,
			`{"udpEnable":true,"tcpEnable":true,"separatePorts":true,"tcpPort":1195}`,
			"1194/UDP  ·  1195/TCP"},
		{"a disabled transport is not offered", model.OPENVPN, 1194,
			`{"udpEnable":false,"tcpEnable":true}`, "1194/TCP"},
		// Absent keys mean "on": that is what the panel's own form defaults to, and a
		// customer told a working transport is off cannot connect at all.
		{"absent keys default to on", model.OPENVPN, 1194, `{}`, "1194/UDP  ·  1194/TCP"},
		{"both off falls back to the port", model.OPENVPN, 1194,
			`{"udpEnable":false,"tcpEnable":false}`, "1194"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			in := &model.Inbound{Protocol: tt.protocol, Port: tt.port}
			if got := vpnPorts(in, settingsOf(t, tt.settings)); got != tt.want {
				t.Fatalf("got %q, want %q", got, tt.want)
			}
		})
	}
}

// Only the protocols a customer types a username and password into. VLESS and friends
// are absent by design: their link IS the credential.
func TestIsCredentialVpn(t *testing.T) {
	for _, p := range []model.Protocol{model.OPENVPN, model.L2TP, model.PPTP,
		model.SSTP, model.OPENCONNECT, model.IKEV2} {
		if !isCredentialVpn(p) {
			t.Errorf("%s should be a credential VPN", p)
		}
	}
	for _, p := range []model.Protocol{model.VLESS, model.VMESS, model.Trojan,
		model.WGC, model.AWG, model.SSH, model.MTPROTO} {
		if isCredentialVpn(p) {
			t.Errorf("%s should not be a credential VPN", p)
		}
	}
}
