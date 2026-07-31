package service

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"sync"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/xray"
)

// NodeXrayService keeps every foreign node's core in step with the inbounds
// assigned to it.
//
// The panel compiles one config per node from the same generator it uses for
// itself and pushes it down the node's control channel. Nothing about this is
// visible on the node: the operator assigns an inbound to a server in the panel
// and that server starts serving it.
//
// Pushing is deliberately OUT of the restart path. A first apply on a fresh node
// downloads the core before it answers, and an inbound must never take minutes to
// save — nor fail because a node was unreachable. So a change marks the world
// dirty and a single background worker catches up; the node's own copy on disk
// keeps it serving in the meantime.
type NodeXrayService struct{}

var nodeXray = struct {
	mu sync.Mutex
	// applied is the hash of the config each node last ACCEPTED, so an unchanged
	// config costs nothing and a rejected one is retried rather than assumed live.
	applied map[string]string
	// running guards the worker; pending records a change that arrived while it
	// was busy, so a burst of edits collapses into one more pass instead of one
	// pass each.
	running bool
	pending bool
}{applied: map[string]string{}}

// Sync brings every foreign node up to date, in the background.
func (s *NodeXrayService) Sync() {
	nodeXray.mu.Lock()
	if nodeXray.running {
		nodeXray.pending = true
		nodeXray.mu.Unlock()
		return
	}
	nodeXray.running = true
	nodeXray.mu.Unlock()

	go func() {
		for {
			s.syncOnce()
			nodeXray.mu.Lock()
			if !nodeXray.pending {
				nodeXray.running = false
				nodeXray.mu.Unlock()
				return
			}
			nodeXray.pending = false
			nodeXray.mu.Unlock()
		}
	}()
}

// syncOnce pushes to each foreign node whose config has changed.
func (s *NodeXrayService) syncOnce() {
	var nodeService NodeService
	var xrayService XrayService
	var inboundService InboundService

	inbounds, err := inboundService.GetAllInbounds()
	if err != nil {
		logger.Warning("node xray: could not read the inbounds: ", err)
		return
	}
	// Which nodes actually have work. A node with nothing assigned must be told to
	// stop rather than left serving accounts the panel no longer sends it.
	assigned := map[string]bool{}
	for _, inbound := range inbounds {
		if inbound.NodeId != "" && inbound.Enable {
			assigned[inbound.NodeId] = true
		}
	}

	for _, node := range nodeService.List() {
		if node.Role != NodeRoleForeign {
			continue
		}
		if !assigned[node.ID] {
			s.retire(&nodeService, node.ID, node.Name)
			continue
		}
		if !node.Online {
			// Not an error worth shouting about: the node keeps serving its stored
			// config, and the next pass picks it up when it comes back.
			logger.Debug("node xray: ", node.Name, " is offline; its config will follow when it reconnects")
			continue
		}
		config, err := xrayService.GetNodeXrayConfig(node.ID)
		if err != nil {
			logger.Warning("node xray: could not build the config for ", node.Name, ": ", err)
			continue
		}
		raw, err := json.MarshalIndent(config, "", "  ")
		if err != nil {
			logger.Warning("node xray: could not encode the config for ", node.Name, ": ", err)
			continue
		}
		sum := hashOf(raw)

		nodeXray.mu.Lock()
		unchanged := nodeXray.applied[node.ID] == sum
		nodeXray.mu.Unlock()
		if unchanged {
			continue
		}

		out, err := nodeService.ApplyXray(node.ID, raw)
		if err != nil {
			// Left unrecorded on purpose, so the next pass tries again instead of
			// treating a failed push as the node's live state.
			logger.Warning("node xray: ", node.Name, " did not accept its config: ", err, " ", out)
			continue
		}
		nodeXray.mu.Lock()
		nodeXray.applied[node.ID] = sum
		nodeXray.mu.Unlock()
		logger.Info("node xray: ", node.Name, " is serving its inbounds — ", out)
	}
}

// retire stops a node's core once nothing is assigned to it, and only when this
// panel had actually started one there.
func (s *NodeXrayService) retire(nodeService *NodeService, id, name string) {
	nodeXray.mu.Lock()
	had := nodeXray.applied[id] != ""
	nodeXray.mu.Unlock()
	if !had {
		return
	}
	if _, err := nodeService.StopXray(id); err != nil {
		logger.Warning("node xray: could not stop the core on ", name, ": ", err)
		return
	}
	nodeXray.mu.Lock()
	delete(nodeXray.applied, id)
	nodeXray.mu.Unlock()
	logger.Info("node xray: stopped the core on ", name, " — it has no inbounds left")
}

// CollectTraffic reads and RESETS the traffic counters of every foreign node that
// is serving inbounds, returning them in the shapes the panel's own accounting
// takes.
//
// This is what makes an account on a node a real account: quota, expiry and the
// disabling that follows all happen in InboundService.AddTraffic, and traffic that
// never arrives there is traffic nobody is billed for. Once a client is disabled
// there, the next config push simply omits it — the node stops serving it without
// anything else having to reach in.
//
// Best effort per node: one unreachable node must not cost the others their tick.
// Its counters are not lost, only deferred — they are only reset once handed over.
func (s *NodeXrayService) CollectTraffic() ([]*xray.Traffic, []*xray.ClientTraffic) {
	var nodeService NodeService
	var traffics []*xray.Traffic
	var clientTraffics []*xray.ClientTraffic

	nodeXray.mu.Lock()
	ids := make([]string, 0, len(nodeXray.applied))
	for id := range nodeXray.applied {
		ids = append(ids, id)
	}
	nodeXray.mu.Unlock()

	for _, id := range ids {
		raw, err := nodeService.Exec(id, []string{"xray-stats"})
		if err != nil {
			logger.Debug("node xray: no traffic from ", nodeService.NameOf(id), ": ", err)
			continue
		}
		t, ct, err := xray.ParseStatsJSON([]byte(strings.TrimSpace(raw)))
		if err != nil {
			logger.Warning("node xray: unreadable traffic from ", nodeService.NameOf(id), ": ", err)
			continue
		}
		traffics = append(traffics, t...)
		clientTraffics = append(clientTraffics, ct...)
	}
	return traffics, clientTraffics
}

func hashOf(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}
