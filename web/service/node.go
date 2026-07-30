package service

import (
	"crypto/ecdh"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"
)

// NodeService implements the Iran-node control plane.
//
// A node (typically the Iran server) runs a tiny bash+curl agent that DIALS OUT
// to this panel and long-polls for commands. Because the node initiates the
// connection over the panel's normal HTTPS port, it is DPI-resistant (looks like
// ordinary web traffic), works behind NAT/CGNAT, and needs no inbound port on
// the node. Commands are allowlisted `tunnelctl` subcommands; results come back
// over the same channel. No node state touches the x-ui database — the node
// registry is a small JSON file alongside the tunnel config.
type NodeService struct{}

// nodesFile is where the persistent registry (id/name/token) lives. Runtime
// state (last-seen, queued commands, results) is in-memory only.
func nodesFile() string {
	if p := os.Getenv("TUNNEL_NODES_FILE"); p != "" {
		return p
	}
	return "/etc/tunnel-manager/nodes.json"
}

const (
	nodeExecTimeout = 20 * time.Second // how long Exec waits for a node result
	nodePollHold    = 25 * time.Second // long-poll hold when the queue is empty

	// A node counts as online while its last poll is within this window. It MUST
	// stay comfortably larger than nodePollHold: an agent sitting inside a held
	// long-poll is *connected*, but it isn't issuing new requests, so a window
	// shorter than the hold marks a perfectly healthy node offline partway
	// through every cycle — which is exactly the online/offline flapping this
	// used to show (15s window vs. 25s hold). Poll also refreshes last-seen
	// while it holds, so this only has to cover a whole missed cycle plus jitter.
	nodeOnlineWindow = 75 * time.Second
)

// protoSecretKey maps each tunnel protocol to the field holding its shared
// secret, as named by that protocol's driver in tunnel/drivers/. Both ends of a
// tunnel MUST carry the same value, so auto-provisioning fills this key once and
// pushes it to both sides. Keep in sync with the drivers' "TUN keys" headers.
var protoSecretKey = map[string]string{
	"gost":     "GO_PASS",
	"backpack": "BP_TOKEN",
	"backhaul": "BH_TOKEN",
	"rathole":  "RH_TOKEN",
	"frp":      "FRP_TOKEN",
	"hysteria": "HY_PASS",
	"paqet":    "PAQET_SECRET",
	// gre authenticates by GRE_KEY, which the operator sets explicitly.
}

type nodeCommand struct {
	ID   string   `json:"id"`
	Args []string `json:"args"`
}

type nodeResult struct {
	Output  string
	Success bool
	at      time.Time
}

// NodeSetup is an optional tunnel the operator configured in the panel when
// adding the node. It is applied automatically the first time the node connects
// (see Provision) — the foreign side is created locally with the node's just-
// learned public IP, and the matching Iran side is pushed to the node.
type NodeSetup struct {
	Name     string            `json:"name"`
	Protocol string            `json:"protocol"`
	Fields   map[string]string `json:"fields"`
}

// nodeEntry is one registered node. The exported fields are persisted; the
// unexported ones are live runtime state.
type nodeEntry struct {
	ID          string     `json:"id"`
	Name        string     `json:"name"`
	Token       string     `json:"token"`
	Created     string     `json:"created"`
	Setup       *NodeSetup `json:"setup,omitempty"`
	Provisioned bool       `json:"provisioned"`

	lastSeen time.Time
	remoteIP string
	queue    []*nodeCommand
	results  map[string]*nodeResult
}

type nodeRegistry struct {
	mu     sync.Mutex
	nodes  map[string]*nodeEntry // keyed by ID
	loaded bool
}

var nodeReg = &nodeRegistry{nodes: map[string]*nodeEntry{}}

// ---- persistence -----------------------------------------------------------

func (r *nodeRegistry) load() {
	if r.loaded {
		return
	}
	r.loaded = true
	data, err := os.ReadFile(nodesFile())
	if err != nil {
		return // no file yet ⇒ empty registry
	}
	var on struct {
		Nodes []*nodeEntry `json:"nodes"`
	}
	if json.Unmarshal(data, &on) != nil {
		return
	}
	for _, n := range on.Nodes {
		n.results = map[string]*nodeResult{}
		r.nodes[n.ID] = n
	}
}

func (r *nodeRegistry) save() {
	var on struct {
		Nodes []*nodeEntry `json:"nodes"`
	}
	for _, n := range r.nodes {
		on.Nodes = append(on.Nodes, n)
	}
	data, err := json.MarshalIndent(&on, "", "  ")
	if err != nil {
		return
	}
	tmp := nodesFile() + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, nodesFile())
	}
}

func randToken() string {
	b := make([]byte, 24)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func randID() string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// ---- panel-facing API (login-protected) ------------------------------------

// NodeInfo is the safe, UI-facing view of a node (no token).
type NodeInfo struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Online   bool   `json:"online"`
	RemoteIP string `json:"remoteIP"`
	LastSeen string `json:"lastSeen"`
	Created  string `json:"created"`
}

// List returns all registered nodes with live online status.
func (s *NodeService) List() []NodeInfo {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	out := make([]NodeInfo, 0, len(nodeReg.nodes))
	for _, n := range nodeReg.nodes {
		last := ""
		online := false
		if !n.lastSeen.IsZero() {
			last = n.lastSeen.UTC().Format(time.RFC3339)
			online = time.Since(n.lastSeen) < nodeOnlineWindow
		}
		out = append(out, NodeInfo{
			ID: n.ID, Name: n.Name, Online: online,
			RemoteIP: n.remoteIP, LastSeen: last, Created: n.Created,
		})
	}
	return out
}

// Create registers a new node and returns its id + one-time token. An optional
// setup (protocol + fields) is applied automatically on first connect.
func (s *NodeService) Create(name string, setup *NodeSetup) (id, token string) {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	// Fill the shared secret NOW so BOTH ends of the tunnel get the exact same
	// value. If left blank, each side's <p>_prepare would generate its own and the
	// tunnel would never authenticate. Note every driver names its secret
	// differently (GO_PASS, BP_TOKEN, …) — filling only "*_SECRET" would silently
	// leave all but paqet mismatched.
	if setup != nil {
		if setup.Fields == nil {
			setup.Fields = map[string]string{}
		}
		if key := protoSecretKey[setup.Protocol]; key != "" && setup.Fields[key] == "" {
			setup.Fields[key] = randToken()[:32]
		}
		// The rathole transport material, for the same reason and at the same
		// moment: both ends must receive ONE generation of it.
		if err := fillRatholeTransportFields(setup.Protocol, setup.Fields); err != nil {
			logger.Warning("node: could not prepare the rathole transport material: ", err)
		}
		for k, v := range setup.Fields {
			if v == "" && strings.HasSuffix(k, "_SECRET") {
				setup.Fields[k] = randToken()[:32]
			}
		}
	}
	id = randID()
	token = randToken()
	nodeReg.nodes[id] = &nodeEntry{
		ID: id, Name: name, Token: token,
		Created: time.Now().UTC().Format(time.RFC3339),
		Setup:   setup,
		results: map[string]*nodeResult{},
	}
	nodeReg.save()
	return id, token
}

// Provision is called on each node poll. The first time a node with a configured
// setup connects, it: (1) queues the Iran-side `tunnelctl create` for the node
// (REMOTE_IP = the foreign panel host the node reached), and (2) returns the
// foreign-side fields (REMOTE_IP = the node's just-learned public IP) for the
// caller to create locally. Returns ok=false when there's nothing to provision.
func (s *NodeService) Provision(token, iranIP, foreignHost string) (foreignFields map[string]string, ok bool) {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	n := s.byToken(token)
	if n == nil || n.Setup == nil || n.Provisioned || iranIP == "" {
		return nil, false
	}
	setup := n.Setup

	// Iran side (pushed to the node).
	args := []string{"create", "NAME=" + setup.Name, "PROTOCOL=" + setup.Protocol, "ROLE=iran", "REMOTE_IP=" + foreignHost}
	for k, v := range setup.Fields {
		args = append(args, k+"="+v)
	}
	n.queue = append(n.queue, &nodeCommand{ID: randID(), Args: args})
	n.Provisioned = true
	nodeReg.save()

	// Foreign side (created locally by the caller).
	ff := map[string]string{
		"NAME": setup.Name, "PROTOCOL": setup.Protocol,
		"ROLE": "foreign", "REMOTE_IP": iranIP,
	}
	for k, v := range setup.Fields {
		ff[k] = v
	}
	return ff, true
}

// BuildPair prepares BOTH sides of a tunnel for a registered node: the foreign
// side (created locally on the panel host) and the Iran side (pushed to the
// node). They share one secret and each points at the other's public address.
//
// This is the whole product in one call: the operator configures the tunnel once
// in the panel and both servers get a matching, working half. Creating a single
// side from the panel — which is what the old "role" picker did — always produced
// a tunnel with nothing on the other end.
// schemaSides maps each field of a protocol to the side it belongs on
// ("both" | "iran" | "foreign"), as declared by `tunnelctl json schema`. The
// schema is the single source of truth for this: the CLI wizard only ever asks a
// side-specific question on the side it applies to, and the pair builder has to
// honour the same split.
func schemaSides(schemaRaw json.RawMessage, protocol string) map[string]string {
	var s map[string]struct {
		Fields []struct {
			Key  string `json:"key"`
			Side string `json:"side"`
		} `json:"fields"`
	}
	if len(schemaRaw) == 0 || json.Unmarshal(schemaRaw, &s) != nil {
		return nil
	}
	out := map[string]string{}
	for _, f := range s[protocol].Fields {
		out[f.Key] = f.Side
	}
	return out
}

// BuildPair derives the two halves of a tunnel from one form.
//
// schemaRaw carries the per-field side declarations; pass nil only if the schema
// is unavailable (fields then go to both sides, the old behaviour).
func (s *NodeService) BuildPair(id, name, protocol string, fields map[string]string, foreignHost string, schemaRaw json.RawMessage) (foreign, iran map[string]string, online bool, err error) {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()

	n := nodeReg.nodes[id]
	if n == nil {
		return nil, nil, false, errors.New("node not found")
	}
	if n.remoteIP == "" {
		return nil, nil, false, errors.New("this node has never connected — run its install one-liner first")
	}
	online = time.Since(n.lastSeen) < nodeOnlineWindow

	if fields == nil {
		fields = map[string]string{}
	}
	// One shared secret, stored under the driver's own key name. Left blank, each
	// side's <p>_prepare would mint its own and the two ends would never authenticate.
	if key := protoSecretKey[protocol]; key != "" && fields[key] == "" {
		fields[key] = randToken()[:32]
	}
	// Same rule, for the material rathole's non-TCP transports need. It is not one
	// field but a matched SET — a noise keypair, or a certificate and its key — and
	// the halves are useless unless they came from the same generation, so it is
	// minted here and pushed to both sides exactly as the token above is.
	//
	// Without this each host's rathole_prepare_transport mints its own on first
	// write and the two ends never complete a handshake: the tunnel comes up, stays
	// down, and the reason is a key neither side ever agreed to.
	if err := fillRatholeTransportFields(protocol, fields); err != nil {
		return nil, nil, false, err
	}

	sides := schemaSides(schemaRaw, protocol)

	side := func(role, remote string) map[string]string {
		m := map[string]string{}
		for k, v := range fields {
			// Only copy a field to the side it applies to. Side-specific options are
			// not merely useless on the wrong host — they are actively destructive:
			// FORWARD_MODE=all is an Iran-side relay, but landing it on the foreign
			// server made it DNAT every port it owns (bar SSH) to the node, taking
			// the panel itself offline. ENABLE_NAT is likewise foreign-only, which
			// is why "NAT works in the CLI but not the panel": the CLI wizard only
			// ever asks each question on the side that uses it.
			if sd := sides[k]; sd != "" && sd != "both" && sd != role {
				continue
			}
			m[k] = v
		}
		// Set the identity fields AFTER copying the form: a stray ROLE/REMOTE_IP in
		// the submitted fields must never be able to flip a side onto the wrong host.
		m["NAME"] = name
		m["PROTOCOL"] = protocol
		m["ROLE"] = role
		m["REMOTE_IP"] = remote
		return m
	}
	return side("foreign", n.remoteIP), side("iran", foreignHost), online, nil
}

// SetSetup stores/replaces a node's pending auto-provision setup, so a tunnel
// configured before the node ever connects is applied on its first poll.
func (s *NodeService) SetSetup(id string, setup *NodeSetup) error {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	n := nodeReg.nodes[id]
	if n == nil {
		return errors.New("node not found")
	}
	n.Setup = setup
	n.Provisioned = false // let it fire again for the new setup
	nodeReg.save()
	return nil
}

// OnlineIDs lists the nodes currently reachable (their agent is polling).
func (s *NodeService) OnlineIDs() []string {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	var ids []string
	for id, n := range nodeReg.nodes {
		if !n.lastSeen.IsZero() && time.Since(n.lastSeen) < nodeOnlineWindow {
			ids = append(ids, id)
		}
	}
	return ids
}

// NameOf returns a node's display name (empty when unknown).
func (s *NodeService) NameOf(id string) string {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	if n := nodeReg.nodes[id]; n != nil {
		return n.Name
	}
	return ""
}

// RemoveTunnelEverywhere asks every online node to drop the tunnel called name,
// and reports the nodes where one was actually removed.
//
// A tunnel is a PAIR created under a single name, so deleting only the local half
// strands the node's half: still running, still holding its port, crash-looping
// against an endpoint that no longer exists. That is how a node silently
// accumulates dead tunnels that block the ports of every new one.
//
// Best effort by design: a node that never had this tunnel just answers "No such
// tunnel", and an offline node must not block deleting the local side.
func (s *NodeService) RemoveTunnelEverywhere(name string) []string {
	var removed []string
	for _, id := range s.OnlineIDs() {
		out, err := s.Exec(id, []string{"remove", name})
		if err != nil || strings.Contains(out, "No such tunnel") {
			continue
		}
		if n := s.NameOf(id); n != "" {
			removed = append(removed, n)
		}
	}
	return removed
}

// EnsureForward makes the node reachable at dest relay port/proto to the panel.
//
// Setting an "external proxy" on an inbound only rewrites the address handed to
// clients — it points them at the Iran node but nothing there listens on that
// port, so the connection dies at the relay. This closes that half: the node's
// port-forwarding tunnel learns the port, with the protocol the inbound actually
// speaks (OpenVPN is UDP; a tcp-only forward carries nothing).
//
// Best effort by design: it needs the node online, and an inbound must still
// save when the relay is unreachable. The returned string says what happened so
// the caller can surface it; err is only for a genuine failure to apply.
func (s *NodeService) EnsureForward(dest, proto string, port int) (string, error) {
	if port <= 0 || dest == "" {
		return "", nil
	}
	switch proto {
	case "tcp", "udp":
	default:
		return "", fmt.Errorf("unsupported forward protocol %q", proto)
	}

	id := s.idForAddress(dest)
	if id == "" {
		// dest is not one of our nodes (a CDN, a third-party relay); the operator
		// owns that path, so there is nothing for us to configure.
		return "", nil
	}

	// The forward being asked for decides WHICH tunnel gets it: a node running one
	// relay for xray and another for the VPN ports has to send each port to the one
	// that can actually carry it.
	t, err := s.forwardingTunnel(id, proto, port)
	if err != nil {
		return "", err
	}
	if t.name == "" {
		return "", errors.New("this node has no tunnel yet — create one on the Tunnels page first")
	}
	spec, known := tunnelPortSpecFor(t.protocol)
	if !known {
		return "", fmt.Errorf("tunnel %q uses protocol %q, which this panel cannot configure forwards for",
			t.name, t.protocol)
	}
	// FORWARD_MODE=all already relays every port, so there is no entry to add — but
	// only where the driver IMPLEMENTS it (spec.relayAll; today that is GRE alone,
	// whose gre_relay_all installs the blanket tcp+udp DNAT). This used to trust the
	// setting for every protocol, so a paqet tunnel left on "all" — which its driver
	// never reads — got no forward from the panel either, and carried nothing.
	if t.mode == "all" && spec.relayAll {
		return "", nil
	}
	// Saying this plainly is the whole point: a UDP service behind a TCP-only
	// relay fails as "connection refused" on the far side, with nothing in the
	// panel hinting that the tunnel was never able to carry it.
	if proto == "udp" && !spec.udp {
		return "", fmt.Errorf("tunnel %q (%s) carries TCP only, so it cannot relay UDP port %d — "+
			"use GRE, Paqet, Hysteria, rathole, backhaul or backpack for that, "+
			"or run the service over TCP",
			t.name, t.protocol, port)
	}
	// backhaul and backpack carry UDP with accept_udp, which upstream documents for
	// the plain `tcp` transport. On tcpmux/ws/wsmux the ports array is shared between
	// both protocols, so the entry would be accepted and listed while the UDP half
	// went nowhere — the exact silent shape this refusal exists to prevent. rathole
	// needs no such check: its type is per service and applies on every transport.
	if proto == "udp" && (t.protocol == "backhaul" || t.protocol == "backpack") &&
		strings.ToLower(strings.TrimSpace(t.transport)) != "tcp" {
		return "", fmt.Errorf("tunnel %q (%s) is on the %q transport, which carries TCP only — "+
			"UDP port %d needs its transport set to \"tcp\" (accept_udp applies there), "+
			"or a rathole/GRE/Paqet tunnel instead",
			t.name, t.protocol, t.transport, port)
	}

	entry := spec.entry(proto, port)
	sep := ";"
	for _, f := range strings.Split(t.forwards, sep) {
		if strings.TrimSpace(f) == entry {
			return "", nil // already forwarded
		}
	}
	updated := entry
	if strings.TrimSpace(t.forwards) != "" {
		updated = strings.TrimRight(t.forwards, sep) + sep + entry
	}
	if _, err := s.Exec(id, []string{"set", t.name, spec.field, updated}); err != nil {
		return "", err
	}
	// The relay only picks up a new port map on restart.
	if _, err := s.Exec(id, []string{"restart", t.name}); err != nil {
		return "", err
	}
	return fmt.Sprintf("%s → %s on %s", entry, t.name, s.NameOf(id)), nil
}

// idForAddress resolves a node by the address an operator typed into an external
// proxy: its dialled-in IP, or a hostname that resolves to it.
func (s *NodeService) idForAddress(addr string) string {
	addr = strings.TrimSpace(addr)
	if addr = strings.Trim(addr, "[]"); addr == "" {
		return ""
	}
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	for id, n := range nodeReg.nodes {
		if n.remoteIP != "" && strings.EqualFold(n.remoteIP, addr) {
			return id
		}
	}
	// A domain pointing at one of our nodes is the common case, so resolve it.
	if ips, err := net.LookupHost(addr); err == nil {
		for _, ip := range ips {
			for id, n := range nodeReg.nodes {
				if n.remoteIP != "" && n.remoteIP == ip {
					return id
				}
			}
		}
	}
	return ""
}

// nodeTunnel is the relaying tunnel found on a node.
type nodeTunnel struct {
	name     string
	protocol string
	mode     string
	forwards string
	// transport is the relay's own carrier (backhaul/backpack: tcp, tcpmux, ws,
	// wsmux, …). It decides whether UDP can ride along: accept_udp is documented
	// for the plain tcp transport only.
	transport string
}

// forwardingTunnel picks the tunnel on a node that relays client ports.
// canCarry reports whether this tunnel is able to relay proto at all.
//
// Shared by the SELECTION in forwardingTunnel and by EnsureForward's refusal, so a
// tunnel can never be chosen on one rule and then rejected on another.
func (t nodeTunnel) canCarry(proto string) bool {
	spec, known := tunnelPortSpecFor(t.protocol)
	if !known {
		return false
	}
	if proto != "udp" {
		return true
	}
	if !spec.udp {
		return false
	}
	// accept_udp is wired to these two relays' plain TCP transport alone.
	if t.protocol == "backhaul" || t.protocol == "backpack" {
		return strings.EqualFold(strings.TrimSpace(t.transport), "tcp")
	}
	return true
}

// relaysPorts reports whether this tunnel is the one carrying client ports: it has
// entries already, or GRE's blanket mode is on.
func (t nodeTunnel) relaysPorts() bool {
	if strings.TrimSpace(t.forwards) != "" {
		return true
	}
	spec, known := tunnelPortSpecFor(t.protocol)
	return t.mode == "ports" || (t.mode == "all" && known && spec.relayAll)
}

func (t nodeTunnel) hasForward(entry string) bool {
	for _, f := range strings.Split(t.forwards, ";") {
		if strings.TrimSpace(f) == entry {
			return true
		}
	}
	return false
}

// forwardingTunnel picks which of a node's tunnels should carry one forward.
//
// A node commonly runs SEVERAL — one shaped for xray (a muxed websocket, say) and
// another carrying the VPN ports — and the old version could not tell them apart.
// It looked for FORWARD_MODE, which is a GRE-ONLY field: on backhaul, rathole and
// the rest it is simply absent, so every candidate scored the same and the FIRST
// tunnel the node happened to list won. With a backhaul and a rathole side by side
// that meant UDP 500 was aimed at the backhaul — refused, because its transport
// cannot carry UDP — while the rathole tunnel actually holding the L2TP ports was
// never considered. The refusal named a real limit of the wrong tunnel, which is
// what made it so convincing.
//
// Now the choice is about the forward being asked for, most specific first:
// the tunnel that already carries it, then one that CAN carry it and is the one
// relaying client ports, then any that can carry it, and only then whatever exists
// so the error names something real.
func (s *NodeService) forwardingTunnel(id, proto string, port int) (nodeTunnel, error) {
	var found nodeTunnel
	raw, err := s.Exec(id, []string{"json", "list"})
	if err != nil {
		return found, err
	}
	var list []struct {
		Name string `json:"name"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &list); err != nil {
		return found, fmt.Errorf("could not read the node's tunnel list: %w", err)
	}
	var all []nodeTunnel
	for _, item := range list {
		detail, derr := s.Exec(id, []string{"json", "tunnel", item.Name})
		if derr != nil {
			continue
		}
		var d map[string]any
		if json.Unmarshal([]byte(strings.TrimSpace(detail)), &d) != nil {
			continue
		}
		cfg := tunnelConfigOf(d)
		str := func(k string) string {
			v, _ := cfg[k].(string)
			return v
		}
		protocol := str("PROTOCOL")
		spec, known := tunnelPortSpecFor(protocol)
		mode := str("FORWARD_MODE")
		if mode == "" {
			mode = str("TRAFFIC_TYPE")
		}
		if mode == "port-forward" {
			mode = "ports"
		}
		forwards := ""
		if known {
			forwards = str(spec.field)
		}
		transport := str("BH_TRANSPORT")
		if transport == "" {
			transport = str("BP_TRANSPORT")
		}
		all = append(all, nodeTunnel{item.Name, protocol, mode, forwards, transport})
	}

	return pickForwardingTunnel(all, proto, port), nil
}

// pickForwardingTunnel chooses which tunnel carries one forward, most specific
// first. Split out from the node round-trip so the choice itself is testable.
func pickForwardingTunnel(all []nodeTunnel, proto string, port int) nodeTunnel {
	// 1. Already carries this exact forward — definitively the right tunnel, and
	//    EnsureForward will then find nothing to add.
	for _, t := range all {
		if sp, ok := tunnelPortSpecFor(t.protocol); ok && t.hasForward(sp.entry(proto, port)) {
			return t
		}
	}
	// 2. Can carry it AND is the one relaying client ports.
	for _, t := range all {
		if t.canCarry(proto) && t.relaysPorts() {
			return t
		}
	}
	// 3. Can carry it.
	for _, t := range all {
		if t.canCarry(proto) {
			return t
		}
	}
	// 4. Nothing can: return one anyway so the refusal names a real tunnel and its
	//    real limit rather than "this node has no tunnel yet".
	if len(all) > 0 {
		return all[0]
	}
	return nodeTunnel{}
}

// Remove deletes a node.
func (s *NodeService) Remove(id string) error {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	if _, ok := nodeReg.nodes[id]; !ok {
		return errors.New("node not found")
	}
	delete(nodeReg.nodes, id)
	nodeReg.save()
	return nil
}

// Exec queues an allowlisted tunnelctl command on a node and waits (bounded) for
// its result. Returns the command output.
func (s *NodeService) Exec(id string, args []string) (string, error) {
	nodeReg.mu.Lock()
	nodeReg.load()
	n := nodeReg.nodes[id]
	if n == nil {
		nodeReg.mu.Unlock()
		return "", errors.New("node not found")
	}
	cmdID := randID()
	n.queue = append(n.queue, &nodeCommand{ID: cmdID, Args: args})
	nodeReg.mu.Unlock()

	deadline := time.Now().Add(nodeExecTimeout)
	for time.Now().Before(deadline) {
		nodeReg.mu.Lock()
		res := n.results[cmdID]
		if res != nil {
			delete(n.results, cmdID)
			nodeReg.mu.Unlock()
			if !res.Success {
				return res.Output, errors.New("node reported command failure")
			}
			return res.Output, nil
		}
		nodeReg.mu.Unlock()
		time.Sleep(200 * time.Millisecond)
	}
	return "", errors.New("node did not respond in time (is it online?)")
}

// ---- node-facing API (token-authed, no session) ----------------------------

// authNode resolves a node by its token, updating last-seen + remote IP.
func (s *NodeService) authNode(token, remoteIP string) *nodeEntry {
	if token == "" {
		return nil
	}
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	for _, n := range nodeReg.nodes {
		if n.Token == token {
			n.lastSeen = time.Now()
			if remoteIP != "" {
				n.remoteIP = remoteIP
			}
			return n
		}
	}
	return nil
}

// Poll is called by the node agent. It returns any queued commands, holding the
// request briefly (long-poll) when the queue is empty so latency stays low
// without a tight request loop. Returns nil (and ok=false) for a bad token.
func (s *NodeService) Poll(token, remoteIP string) (cmds []*nodeCommand, ok bool) {
	if s.authNode(token, remoteIP) == nil {
		return nil, false
	}
	deadline := time.Now().Add(nodePollHold)
	for {
		nodeReg.mu.Lock()
		nodeReg.load()
		n := s.byToken(token)
		if n != nil {
			// Keep last-seen fresh FOR THE DURATION of the hold. The agent is
			// connected the whole time it is parked here, but it issues no new
			// request until we return, so without this the node would age out
			// mid-hold and flap offline->online on every cycle.
			n.lastSeen = time.Now()
			if len(n.queue) > 0 {
				cmds = n.queue
				n.queue = nil
				nodeReg.mu.Unlock()
				return cmds, true
			}
		}
		nodeReg.mu.Unlock()
		if time.Now().After(deadline) {
			return []*nodeCommand{}, true
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// byToken must be called with the registry mutex held.
func (s *NodeService) byToken(token string) *nodeEntry {
	for _, n := range nodeReg.nodes {
		if n.Token == token {
			return n
		}
	}
	return nil
}

// Result records a command's output posted back by the node agent.
func (s *NodeService) Result(token, cmdID, output string, success bool) bool {
	nodeReg.mu.Lock()
	defer nodeReg.mu.Unlock()
	nodeReg.load()
	n := s.byToken(token)
	if n == nil {
		return false
	}
	if n.results == nil {
		n.results = map[string]*nodeResult{}
	}
	n.results[cmdID] = &nodeResult{Output: output, Success: success, at: time.Now()}
	return true
}

// remotePortList reads a tunnel's forward list from the node's half of the pair.
//
// Only the side that accepts client connections (Iran) carries the port map;
// the side this panel runs is the other end and stores none. Anything reading
// only the local half therefore sees an empty list for a working forward.
func (s *NodeService) remotePortList(tunnelName, field string) (string, error) {
	for _, id := range s.OnlineIDs() {
		raw, err := s.Exec(id, []string{"json", "tunnel", tunnelName})
		if err != nil {
			continue
		}
		var d map[string]any
		if json.Unmarshal([]byte(strings.TrimSpace(raw)), &d) != nil {
			continue
		}
		if v, _ := tunnelConfigOf(d)[field].(string); strings.TrimSpace(v) != "" {
			return v, nil
		}
	}
	return "", errors.New("no node reported a port list for " + tunnelName)
}

// fillRatholeTransportFields mints the shared material a rathole transport needs,
// once, so BuildPair can hand both ends the same values.
//
// The panel is the only place this can happen. Each host's own
// rathole_prepare_transport generates when the fields are empty, which is right for
// a hand-made tunnel on one box and wrong for a provisioned pair: run on both, it
// produces two unrelated keypairs. Filling them here means the drivers find them
// already set and leave them alone.
//
// The certificate is emitted as PEM rather than PKCS#12 so no PKCS#12 encoder is
// needed here; the server side builds the .p12 from these two with openssl, which
// it already has. Both sides receive both PEMs and each writes only what it uses.
func fillRatholeTransportFields(protocol string, fields map[string]string) error {
	if protocol != "rathole" {
		return nil
	}
	switch fields["RH_TRANSPORT"] {
	case "noise":
		if fields["RH_NOISE_PRIV"] != "" && fields["RH_NOISE_PUB"] != "" {
			return nil
		}
		// Raw X25519, which is what snowstorm's Noise_*_25519_* patterns take and
		// what `rathole --genkey` prints.
		priv, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			return fmt.Errorf("rathole: generating a noise keypair: %w", err)
		}
		fields["RH_NOISE_PRIV"] = base64.StdEncoding.EncodeToString(priv.Bytes())
		fields["RH_NOISE_PUB"] = base64.StdEncoding.EncodeToString(priv.PublicKey().Bytes())
	case "tls", "websocket":
		if fields["RH_TLS_CRT"] != "" && fields["RH_TLS_KEY"] != "" {
			return nil
		}
		if fields["RH_TLS_HOST"] == "" {
			// Nothing resolves this; the client is told to expect exactly it. Random
			// per tunnel so it is not a string every install shares.
			fields["RH_TLS_HOST"] = randToken()[:10] + ".local"
		}
		crt, key, err := selfSignedPEM(fields["RH_TLS_HOST"])
		if err != nil {
			return fmt.Errorf("rathole: generating a TLS identity: %w", err)
		}
		fields["RH_TLS_CRT"] = base64.StdEncoding.EncodeToString(crt)
		fields["RH_TLS_KEY"] = base64.StdEncoding.EncodeToString(key)
		if fields["RH_TLS_PASS"] == "" {
			fields["RH_TLS_PASS"] = randToken()[:16]
		}
	}
	return nil
}

// selfSignedPEM returns a self-signed certificate and its private key, both PEM.
// Ten years: nothing renews it, and an expiry is a tunnel that stops one day for a
// reason nobody will connect to a certificate.
func selfSignedPEM(host string) (certPEM, keyPEM []byte, err error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return nil, nil, err
	}
	tmpl := x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: host},
		DNSNames:              []string{host},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return nil, nil, err
	}
	certPEM = pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM = pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: func() []byte {
		b, _ := x509.MarshalPKCS8PrivateKey(key)
		return b
	}()})
	return certPEM, keyPEM, nil
}
