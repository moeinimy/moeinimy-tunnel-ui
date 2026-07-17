package service

import (
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
