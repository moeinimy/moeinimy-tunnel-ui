package service

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"time"
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
	nodeOnlineWindow = 15 * time.Second // last-seen within this ⇒ "online"
	nodeExecTimeout  = 20 * time.Second // how long Exec waits for a node result
	nodePollHold     = 25 * time.Second // long-poll hold when the queue is empty
)

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
	// Fill any empty *_SECRET now so BOTH ends of the tunnel share the exact same
	// value (if left blank, tunnelctl would generate a different one per side and
	// the tunnel would never authenticate).
	if setup != nil {
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
		if n != nil && len(n.queue) > 0 {
			cmds = n.queue
			n.queue = nil
			nodeReg.mu.Unlock()
			return cmds, true
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
