package service

import (
	"encoding/json"
	"path/filepath"
	"testing"
	"time"
)

// The online window must outlast a held long-poll. An agent parked inside a hold
// is connected but deliberately silent — it issues no new request until the panel
// returns — so a window shorter than the hold ages a perfectly healthy node out
// partway through every cycle. That is exactly the online/offline flapping this
// shipped with (15s window vs. a 25s hold): the node went "offline" 15s into each
// hold and "online" again the moment the next poll landed.
func TestNodeOnlineWindowOutlastsPollHold(t *testing.T) {
	if nodeOnlineWindow <= nodePollHold {
		t.Fatalf("nodeOnlineWindow (%s) must exceed nodePollHold (%s), or nodes flap offline mid-hold",
			nodeOnlineWindow, nodePollHold)
	}
	// Also tolerate one entirely missed cycle (plus network jitter) before
	// declaring a node down, so a single dropped poll isn't a red badge.
	if nodeOnlineWindow < 2*nodePollHold {
		t.Errorf("nodeOnlineWindow (%s) should cover a missed cycle (2x nodePollHold = %s)",
			nodeOnlineWindow, 2*nodePollHold)
	}
}

// A node whose poll is currently being held must read as online the whole time.
func TestPollKeepsNodeOnlineWhileHeld(t *testing.T) {
	t.Setenv("TUNNEL_NODES_FILE", filepath.Join(t.TempDir(), "nodes.json"))
	nodeReg = &nodeRegistry{nodes: map[string]*nodeEntry{}}

	var s NodeService
	_, token := s.Create("iran", nil)

	go s.Poll(token, "203.0.113.9") // holds for nodePollHold; leaks harmlessly at test end

	// Sample well past the OLD 15s-vs-25s failure point would take too long, so
	// assert the mechanism instead: last-seen is refreshed during the hold.
	time.Sleep(1200 * time.Millisecond)

	nodes := s.List()
	if len(nodes) != 1 {
		t.Fatalf("expected 1 node, got %d", len(nodes))
	}
	if !nodes[0].Online {
		t.Error("node must read online while its long-poll is being held")
	}
	if nodes[0].RemoteIP != "203.0.113.9" {
		t.Errorf("remoteIP = %q; want the polling node's address", nodes[0].RemoteIP)
	}

	nodeReg.mu.Lock()
	n := s.byToken(token)
	age := time.Since(n.lastSeen)
	nodeReg.mu.Unlock()
	if age > time.Second {
		t.Errorf("last-seen is %s stale mid-hold; Poll should keep refreshing it", age)
	}
}

// Side-specific fields must land ONLY on the side that uses them.
//
// This is the bug that took the live panel offline: BuildPair copied every form
// field to both halves, so FORWARD_MODE=all — an Iran-side "relay all my ports
// to the peer" — was also written to the foreign server, where it DNAT'd every
// port it owned (bar SSH) to the node, including the panel's own port. The same
// blindness is why ENABLE_NAT "worked in the CLI but not the panel": the wizard
// only ever asks each question on the side that applies, and the pair builder
// has to honour that split.
func TestBuildPairRespectsFieldSides(t *testing.T) {
	t.Setenv("TUNNEL_NODES_FILE", filepath.Join(t.TempDir(), "nodes.json"))
	nodeReg = &nodeRegistry{nodes: map[string]*nodeEntry{}}

	var s NodeService
	id, token := s.Create("iran", nil)
	// Give the node a known address + make it look connected.
	s.authNode(token, "188.0.0.1")

	schema := json.RawMessage(`{"gre":{"label":"GRE","fields":[
		{"key":"ENABLE_NAT","side":"foreign"},
		{"key":"FORWARD_MODE","side":"iran"},
		{"key":"FORWARD_EXCEPT","side":"iran"},
		{"key":"GRE_KEY","side":"both"}
	]}}`)

	fields := map[string]string{
		"ENABLE_NAT":     "yes",
		"FORWARD_MODE":   "all",
		"FORWARD_EXCEPT": "22",
		"GRE_KEY":        "42",
	}
	foreign, iran, _, err := s.BuildPair(id, "t", "gre", fields, "213.0.0.1", schema)
	if err != nil {
		t.Fatalf("BuildPair: %v", err)
	}

	// The one that took the panel down.
	if _, ok := foreign["FORWARD_MODE"]; ok {
		t.Error("FORWARD_MODE is Iran-side; on the foreign server it DNATs every port (incl. the panel) to the node")
	}
	if _, ok := foreign["FORWARD_EXCEPT"]; ok {
		t.Error("FORWARD_EXCEPT is Iran-side and must not reach the foreign half")
	}
	if _, ok := iran["ENABLE_NAT"]; ok {
		t.Error("ENABLE_NAT is foreign-side and must not reach the Iran half")
	}

	// The fields that SHOULD be there.
	if foreign["ENABLE_NAT"] != "yes" {
		t.Error("ENABLE_NAT must reach the foreign half — without it NAT silently does nothing")
	}
	if iran["FORWARD_MODE"] != "all" {
		t.Error("FORWARD_MODE must reach the Iran half")
	}
	if foreign["GRE_KEY"] != "42" || iran["GRE_KEY"] != "42" {
		t.Error(`side:"both" fields must reach both halves`)
	}

	// Identity fields must be derived, never taken from the form.
	if foreign["ROLE"] != "foreign" || iran["ROLE"] != "iran" {
		t.Errorf("roles wrong: foreign=%q iran=%q", foreign["ROLE"], iran["ROLE"])
	}
	if foreign["REMOTE_IP"] != "188.0.0.1" {
		t.Errorf("foreign must point at the node's address, got %q", foreign["REMOTE_IP"])
	}
	if iran["REMOTE_IP"] != "213.0.0.1" {
		t.Errorf("iran must point at the panel host, got %q", iran["REMOTE_IP"])
	}
}
