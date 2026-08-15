package service

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/xray"
)

// NodePanelService is the master half of panel-to-panel sync.
//
// A foreign node runs THIS SAME PANEL, not a stripped-down worker. That choice is
// what makes every feature available on a node without being rebuilt there: speed
// limits, IP limits, certificates, subscriptions, quota and expiry are already
// implemented for the machine a panel runs on, and a node is such a machine. The
// master's job is therefore small — hand the node the inbounds it owns, and take
// back what they used.
//
// Enforcement stays on the node ON PURPOSE. An account belongs to one inbound,
// which lives on one server, so that server sees ALL of its traffic: its local
// accounting is complete rather than a shard, and quota, expiry and disabling can
// be decided there with no round trip. The usage that comes back is for the
// master's own display and history — not a second enforcement point that could
// disagree with the first.
type NodePanelService struct{}

// NodeInboundSet is what a node pulls: the inbounds it is to serve, plus a
// version that changes only when they do, so an unchanged pull costs the node
// nothing but a comparison.
type NodeInboundSet struct {
	Version  string           `json:"version"`
	Inbounds []*model.Inbound `json:"inbounds"`
}

// InboundsFor returns the inbound set assigned to one node.
func (s *NodePanelService) InboundsFor(nodeId string) (*NodeInboundSet, error) {
	if nodeId == "" {
		return nil, nil
	}
	db := database.GetDB()
	var inbounds []*model.Inbound
	if err := db.Model(model.Inbound{}).
		Preload("ClientStats").
		Where("node_id = ?", nodeId).
		Find(&inbounds).Error; err != nil {
		return nil, err
	}
	// A node enforces from what it can see, and what it can see is its own half of
	// a shared allowance. So the master withholds the accounts that must not be
	// served at all.
	withholdSpentAccounts(inbounds)

	set := &NodeInboundSet{Inbounds: inbounds}
	set.Version = versionOfInbounds(inbounds)
	return set, nil
}

// withholdSpentAccounts strips from the pushed set every client that has no
// business being served: disabled accounts, and members of a shared quota that
// the customer has already spent.
//
// This is the one thing a node cannot decide for itself. Enforcement lives on the
// node because one account lives on one server, so that server sees all of its
// traffic — true for a plain account, and NOT true for a shared allowance. A
// customer with VLESS here and VLESS on a node draws both halves from one pool;
// each server sees only its own half, finds room left in what it can see, and
// keeps serving. The account pings, works, and has nothing left — which is
// exactly the report this comes from.
//
// The master is the only place that can add the halves up, so it decides, and the
// node simply never receives the client. Within one pull the account stops
// working there, with no new enforcement path to disagree with the existing one.
func withholdSpentAccounts(inbounds []*model.Inbound) {
	spent := spentGroups()

	for _, inbound := range inbounds {
		// Which of this inbound's accounts are already switched off, by email.
		off := map[string]bool{}
		for _, ct := range inbound.ClientStats {
			if !ct.Enable || (ct.GroupId != 0 && spent[ct.GroupId]) {
				off[ct.Email] = true
			}
		}
		if len(off) == 0 {
			continue
		}
		settings := map[string]any{}
		if json.Unmarshal([]byte(inbound.Settings), &settings) != nil {
			continue
		}
		clients, ok := settings["clients"].([]any)
		if !ok {
			continue
		}
		kept := make([]any, 0, len(clients))
		for _, c := range clients {
			cm, ok := c.(map[string]any)
			if !ok {
				continue
			}
			if email, _ := cm["email"].(string); off[email] {
				continue
			}
			kept = append(kept, c)
		}
		if len(kept) == len(clients) {
			continue
		}
		settings["clients"] = kept
		if raw, err := json.Marshal(settings); err == nil {
			inbound.Settings = string(raw)
		}
	}
}

// spentGroups is the set of shared allowances with nothing left, counting every
// member wherever it is served plus what departed members already used.
func spentGroups() map[int]bool {
	db := database.GetDB()
	var groups []*model.ClientGroup
	if err := db.Model(model.ClientGroup{}).Where("total > 0").Find(&groups).Error; err != nil {
		logger.Warning("node sync: could not read the shared allowances: ", err)
		return nil
	}
	out := map[int]bool{}
	for _, g := range groups {
		var agg struct{ Used int64 }
		if err := db.Model(xray.ClientTraffic{}).
			Select("COALESCE(SUM(up),0) + COALESCE(SUM(down),0) as used").
			Where("group_id = ?", g.Id).Scan(&agg).Error; err != nil {
			continue
		}
		if agg.Used+g.UsedCarry >= g.Total {
			out[g.Id] = true
		}
	}
	return out
}

// versionOfInbounds hashes everything a node would act on.
//
// Deliberately blind to traffic counters: those change every few seconds on a
// busy inbound, and a version that moved with them would have every node
// reapplying its whole set — and restarting Xray — continuously.
func versionOfInbounds(inbounds []*model.Inbound) string {
	type shape struct {
		Tag             string
		Remark          string
		Enable          bool
		Listen          string
		Port            int
		Protocol        string
		Settings        string
		StreamSettings  string
		Sniffing        string
		ExpiryTime      int64
		Total           int64
		SpeedLimit      [5]int64
		IPLimit         int
		IPLimitStrategy string
	}
	shapes := make([]shape, 0, len(inbounds))
	for _, i := range inbounds {
		shapes = append(shapes, shape{
			Tag: i.Tag, Remark: i.Remark, Enable: i.Enable,
			Listen: i.Listen, Port: i.Port, Protocol: string(i.Protocol),
			Settings: i.Settings, StreamSettings: i.StreamSettings, Sniffing: i.Sniffing,
			ExpiryTime: i.ExpiryTime, Total: i.Total,
			SpeedLimit: [5]int64{
				boolToInt64(i.SpeedLimitEnable), boolToInt64(i.SpeedLimitSeparate),
				int64(i.SpeedLimitDown), int64(i.SpeedLimitUp), i.SpeedLimitAfter,
			},
			IPLimit: i.IPLimit, IPLimitStrategy: i.IPLimitStrategy,
		})
	}
	raw, err := json.Marshal(shapes)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func boolToInt64(b bool) int64 {
	if b {
		return 1
	}
	return 0
}

// NodeUsage is one node's report of what its inbounds have carried. The figures
// are TOTALS as that node knows them, not deltas: it is the only server that sees
// this traffic, so its numbers are the truth rather than an increment to apply on
// top of whatever the master happened to hold.
type NodeUsage struct {
	Inbounds []struct {
		Tag  string `json:"tag"`
		Up   int64  `json:"up"`
		Down int64  `json:"down"`
	} `json:"inbounds"`
	Clients []struct {
		Email  string `json:"email"`
		Up     int64  `json:"up"`
		Down   int64  `json:"down"`
		Enable bool   `json:"enable"`
	} `json:"clients"`
}

// ApplyUsage records what a node reported, so the master's numbers are the ones
// the operator already understands.
//
// Totals are written, not added. A node re-reporting after a master restart, a
// missed cycle or a retry then lands on the same figure instead of billing the
// same bytes twice — which an "add the difference" protocol gets wrong precisely
// when something has gone wrong.
func (s *NodePanelService) ApplyUsage(nodeId string, usage *NodeUsage) error {
	if nodeId == "" || usage == nil {
		return nil
	}
	db := database.GetDB()

	for _, in := range usage.Inbounds {
		if in.Tag == "" {
			continue
		}
		if err := db.Model(model.Inbound{}).
			Where("node_id = ? AND tag = ?", nodeId, in.Tag).
			Updates(map[string]any{"up": in.Up, "down": in.Down}).Error; err != nil {
			logger.Warning("node sync: could not record usage for ", in.Tag, ": ", err)
		}
	}

	for _, cl := range usage.Clients {
		if cl.Email == "" {
			continue
		}
		// Scoped to this node's inbounds so a report can only ever touch accounts
		// that node actually serves.
		var ids []int
		if err := db.Model(model.Inbound{}).Where("node_id = ?", nodeId).
			Pluck("id", &ids).Error; err != nil || len(ids) == 0 {
			break
		}
		if err := db.Model(xray.ClientTraffic{}).
			Where("email = ? AND inbound_id IN ?", cl.Email, ids).
			Updates(map[string]any{"up": cl.Up, "down": cl.Down, "enable": cl.Enable}).Error; err != nil {
			logger.Warning("node sync: could not record usage for ", cl.Email, ": ", err)
		}
	}
	return nil
}
