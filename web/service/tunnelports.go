package service

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// Checking a tunnel's forwarded ports from the panel.
//
// A relay forward fails in a way neither end reports usefully. The relay accepts
// the client's connection, tries to hand it to the far side, and logs something
// like
//
//	local dialer: dial tcp 127.0.0.1:2095: connect: connection refused
//
// in its own journal — while the panel shows a healthy tunnel and the client
// just hangs. Every part is working as configured; the service the forward
// points at simply is not there. This makes that answerable from the UI.

// PortCheck is one forwarded port and what was found behind it.
type PortCheck struct {
	Proto string `json:"proto"`
	// Listen is the port users connect to on the relay; Dest is the port the
	// traffic is handed to on this server.
	Listen int    `json:"listen"`
	Dest   int    `json:"dest"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// CheckPorts reports, for each of a tunnel's forwarded ports, whether anything
// on THIS server is actually listening on the destination — the check the relay
// itself performs every time a client arrives.
func (s *TunnelService) CheckPorts(name string) ([]PortCheck, error) {
	raw, err := s.Tunnel(name)
	if err != nil {
		return nil, err
	}
	var d map[string]any
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, fmt.Errorf("could not read tunnel %q: %w", name, err)
	}
	cfg := tunnelConfigOf(d)
	str := func(k string) string {
		v, _ := cfg[k].(string)
		return v
	}

	protocol := str("PROTOCOL")
	spec, known := tunnelPortSpecFor(protocol)
	if !known {
		return nil, fmt.Errorf("protocol %q has no port-forward list this panel understands", protocol)
	}

	mode := str("FORWARD_MODE")
	if mode == "" {
		mode = str("TRAFFIC_TYPE")
	}
	if mode == "all" {
		// Every port is relayed, so there is no list to walk and nothing to
		// single out as missing.
		return nil, nil
	}

	list := str(spec.field)
	if strings.TrimSpace(list) == "" {
		// The port map belongs to whichever half ACCEPTS client connections — the
		// Iran side. This panel runs the other half, whose config carries no list
		// at all, so reading only the local tunnel showed "nothing to check" for a
		// pair that was forwarding perfectly well. Ask the node for its half.
		if remote, err := (&NodeService{}).remotePortList(name, spec.field); err == nil {
			list = remote
		}
	}
	entries := parsePortEntries(list, spec.protoForm)
	if len(entries) == 0 {
		return nil, nil
	}

	out := make([]PortCheck, 0, len(entries))
	for _, e := range entries {
		out = append(out, checkLocalPort(e))
	}
	return out, nil
}

// parsePortEntries splits a tunnel's forward list into checks. The two syntaxes
// are the ones the drivers use: "proto:local:dest" for GRE/Paqet, "local=dest"
// for the userspace relays (which are TCP-only, hence the default).
func parsePortEntries(list string, protoForm bool) []PortCheck {
	var out []PortCheck
	for _, item := range strings.Split(list, ";") {
		item = strings.TrimSpace(item)
		if item == "" {
			continue
		}
		if protoForm {
			parts := strings.Split(item, ":")
			if len(parts) != 3 {
				continue
			}
			lp, err1 := strconv.Atoi(strings.TrimSpace(parts[1]))
			dp, err2 := strconv.Atoi(strings.TrimSpace(parts[2]))
			if err1 != nil || err2 != nil {
				continue
			}
			out = append(out, PortCheck{Proto: strings.ToLower(strings.TrimSpace(parts[0])), Listen: lp, Dest: dp})
			continue
		}
		parts := strings.SplitN(item, "=", 2)
		lp, err1 := strconv.Atoi(strings.TrimSpace(parts[0]))
		if err1 != nil {
			continue
		}
		dp := lp
		if len(parts) == 2 {
			if v, err := strconv.Atoi(strings.TrimSpace(parts[1])); err == nil {
				dp = v
			}
		}
		out = append(out, PortCheck{Proto: "tcp", Listen: lp, Dest: dp})
	}
	return out
}

// checkLocalPort fills in whether the destination port is served here.
//
// TCP is confirmed by actually connecting, because that is what the relay does
// and a bound-but-wedged socket should not read as healthy. UDP has no
// handshake to complete, so the kernel's socket table is the only honest
// answer — it says a socket is bound, not that the service replies.
func checkLocalPort(c PortCheck) PortCheck {
	if c.Proto == "udp" {
		if listeningOn("udp", c.Dest) {
			c.OK, c.Detail = true, "a UDP socket is bound (UDP has no handshake, so traffic is not proven)"
		} else {
			c.Detail = fmt.Sprintf("nothing is bound to UDP %d on this server", c.Dest)
		}
		return c
	}

	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(c.Dest))
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err == nil {
		_ = conn.Close()
		c.OK, c.Detail = true, "accepting connections"
		return c
	}
	// Distinguish the two failures that look identical in a relay's log.
	if listeningOn("tcp", c.Dest) {
		c.Detail = fmt.Sprintf("a socket is bound to TCP %d but the connection failed: %v", c.Dest, err)
	} else {
		c.Detail = fmt.Sprintf("nothing is listening on TCP %d — the relay will report "+
			"\"connection refused\" for every client", c.Dest)
	}
	return c
}

// listeningOn reports whether any local socket of the given protocol is bound to
// the port, reading the kernel's tables directly so it sees sockets owned by any
// process and needs no external tool.
func listeningOn(proto string, port int) bool {
	for _, f := range []string{"/proc/net/" + proto, "/proc/net/" + proto + "6"} {
		if scanProcNet(f, proto, port) {
			return true
		}
	}
	return false
}

func scanProcNet(path, proto string, port int) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	want := fmt.Sprintf("%04X", port)
	sc := bufio.NewScanner(f)
	sc.Scan() // header
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) < 4 {
			continue
		}
		// local_address is "HEXIP:HEXPORT".
		addr := fields[1]
		i := strings.LastIndex(addr, ":")
		if i < 0 || !strings.EqualFold(addr[i+1:], want) {
			continue
		}
		// TCP state 0A is LISTEN. UDP sockets have no listen state, so any bound
		// socket on the port counts.
		if proto == "tcp" && fields[3] != "0A" {
			continue
		}
		return true
	}
	return false
}

// FieldsMerged is Fields with the port list filled in from the node's half when
// this side has none.
//
// Only the client-accepting half (Iran) stores the port map, so the edit dialog
// opened on an empty field: existing ports were invisible and adding one wrote a
// list containing just the new port, silently dropping the rest.
func (s *TunnelService) FieldsMerged(name string) (json.RawMessage, error) {
	raw, err := s.Fields(name)
	if err != nil {
		return nil, err
	}
	var fields []struct {
		Key   string `json:"key"`
		Value string `json:"value"`
	}
	if json.Unmarshal(raw, &fields) != nil {
		return raw, nil // hand back what we have rather than fail the dialog
	}
	for i, f := range fields {
		if !strings.HasSuffix(f.Key, "_PORTS") && f.Key != "FORWARDS" {
			continue
		}
		// The NODE's answer wins, and it is not merely a fallback for a blank local
		// value. The port map belongs to the half that accepts client connections;
		// the half this panel runs on does not use it, and any value sitting there
		// is a leftover from when edits were written locally and went nowhere.
		//
		// Preferring the local value "when it is not empty" therefore showed the
		// leftover — one stale row where the node had the real list — and that was
		// merely confusing until edits started reaching the node. Then saving the
		// dialog wrote what the dialog was SHOWING, and the leftover overwrote the
		// customer's actual forwards. A display bug became data loss because the
		// write path was fixed and the read path was not.
		//
		// An unreachable node leaves the local value in place so the dialog is not
		// blank; it cannot cause the same loss, because SetFieldEverywhere refuses
		// to save a far-side field that reached no node.
		if remote, rerr := (&NodeService{}).remotePortList(name, f.Key); rerr == nil &&
			strings.TrimSpace(remote) != "" {
			fields[i].Value = remote
		}
	}
	merged, merr := json.Marshal(fields)
	if merr != nil {
		return raw, nil
	}
	return merged, nil
}

// tunnelConfigOf pulls the settings map out of a `tunnelctl json tunnel` object.
//
// That command returns {"name":…,"active":…,"config":{…},"state":{…}} — the
// KEY=VALUE settings live under "config", not at the top level. Reading the top
// level instead yielded an empty PROTOCOL and an empty port list, so every
// port-related feature failed the same way: "protocol \"\" has no port-forward
// list this panel understands", and the auto-forward quietly had nothing to
// write. The flat fallback keeps older/plain payloads working.
func tunnelConfigOf(d map[string]any) map[string]any {
	if cfg, ok := d["config"].(map[string]any); ok {
		return cfg
	}
	return d
}
