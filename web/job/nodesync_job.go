package job

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/database/model"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
	"github.com/mhsanaei/3x-ui/v2/xray"
)

// NodeSyncJob is the node half of panel-to-panel sync: this panel is a foreign
// node of another one, and serves the inbounds that master assigns to it.
//
// The node DIALS OUT, exactly as the tunnel agent does. Nothing has to be open
// here, it works behind NAT, and to anything watching it is ordinary HTTPS to the
// master — the same properties that made the tunnel control channel usable from
// Iran, for the same reason.
//
// This panel is a full panel. It compiles its own Xray, holds its own accounting,
// certificates and speed limits, and enforces quota and expiry itself. That is the
// point of syncing rows rather than a rendered config: every feature works here
// because it is the same code, not a reimplementation. The master is the source of
// truth for WHAT to serve; how it is served is this panel's own job.
type NodeSyncJob struct {
	inboundService service.InboundService
	xrayService    service.XrayService

	// appliedVersion is the inbound-set version last applied, so an unchanged
	// master costs one comparison rather than a rewrite and an Xray restart.
	appliedVersion string
}

func NewNodeSyncJob() *NodeSyncJob { return new(NodeSyncJob) }

// nodeConfPath is where the installer records this node's master + token.
func nodeConfPath() string {
	if p := os.Getenv("TM_NODE_CONF"); p != "" {
		return p
	}
	return "/etc/tunnel-manager/node.conf"
}

// nodeConf is the master coordinates, or ok=false when this panel is not a node.
func nodeConf() (panelURL, token string, ok bool) {
	data, err := os.ReadFile(nodeConfPath())
	if err != nil {
		return "", "", false
	}
	role := ""
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		key, value, found := strings.Cut(line, "=")
		if !found || strings.HasPrefix(line, "#") {
			continue
		}
		value = strings.Trim(strings.TrimSpace(value), `"`)
		switch strings.TrimSpace(key) {
		case "PANEL_URL":
			panelURL = strings.TrimRight(value, "/")
		case "NODE_TOKEN":
			token = value
		case "NODE_ROLE":
			role = value
		}
	}
	// An Iran node runs the tunnel agent and no inbounds of its own; only a foreign
	// node serves accounts for its master.
	if role != service.NodeRoleForeign || panelURL == "" || token == "" {
		return "", "", false
	}
	return panelURL, token, true
}

// IsNode reports whether this panel is a foreign node of another one. Used to
// decide whether the sync job is worth scheduling at all.
func IsNode() bool {
	_, _, ok := nodeConf()
	return ok
}

// nodeHTTPClient tolerates the master's self-signed certificate, as the tunnel
// agent does: the token authenticates the node and the channel is still encrypted.
// A panel behind a real certificate is unaffected.
var nodeHTTPClient = &http.Client{
	Timeout:   30 * time.Second,
	Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
}

func (j *NodeSyncJob) Run() {
	panelURL, token, ok := nodeConf()
	if !ok {
		return
	}
	set, err := j.pull(panelURL, token)
	if err != nil {
		logger.Debug("node sync: could not reach the master panel: ", err)
		return
	}
	if set.Version != j.appliedVersion {
		if err := j.apply(set); err != nil {
			// Left unapplied on purpose, so the next tick retries rather than
			// treating a failed apply as the state the master asked for.
			logger.Warning("node sync: could not apply the master's inbounds: ", err)
		} else {
			j.appliedVersion = set.Version
			logger.Info("node sync: serving ", len(set.Inbounds), " inbound(s) from the master panel")
		}
	}
	// Every tick, NOT only when the set changed: the version deliberately ignores
	// traffic counters — otherwise a busy inbound would have this node reapplying
	// and restarting Xray continuously — so a reset moves no version at all. Checked
	// here, it is seen on the next tick whether anything else changed or not.
	j.adoptResets(set)

	if err := j.report(panelURL, token); err != nil {
		logger.Debug("node sync: could not report usage: ", err)
	}
}

func (j *NodeSyncJob) pull(panelURL, token string) (*service.NodeInboundSet, error) {
	body, err := nodePost(panelURL+"/node/panel/pull", map[string]string{"token": token})
	if err != nil {
		return nil, err
	}
	var set service.NodeInboundSet
	if err := json.Unmarshal(body, &set); err != nil {
		return nil, err
	}
	return &set, nil
}

// apply makes this panel's inbounds match what the master sent.
//
// Matching is by TAG, which already carries the master's id for this node
// (model.InboundTag), so a tag is both a stable identity across syncs and the
// marker for "the master owns this one". An inbound created by hand on this
// panel carries no such prefix and is never touched — the master owning this node
// must not mean the master deleting whatever else is here.
func (j *NodeSyncJob) apply(set *service.NodeInboundSet) error {
	local, err := j.inboundService.GetAllInbounds()
	if err != nil {
		return err
	}
	byTag := map[string]*model.Inbound{}
	for _, in := range local {
		byTag[in.Tag] = in
	}
	wanted := map[string]bool{}

	for _, remote := range set.Inbounds {
		if remote.Tag == "" {
			continue
		}
		wanted[remote.Tag] = true
		existing := byTag[remote.Tag]
		if existing == nil {
			if err := j.create(remote); err != nil {
				return err
			}
			continue
		}
		if err := j.update(existing, remote); err != nil {
			return err
		}
	}

	// Anything the master used to own here and no longer sends.
	prefix := managedTagPrefix(set.Inbounds)
	if prefix != "" {
		for _, in := range local {
			if strings.HasPrefix(in.Tag, prefix) && !wanted[in.Tag] {
				if _, err := j.inboundService.DelInbound(in.Id); err != nil {
					logger.Warning("node sync: could not remove ", in.Tag, ": ", err)
				}
			}
		}
	}

	j.xrayService.SetToNeedRestart()
	return nil
}

// adoptResets takes the master's counters whenever they are LOWER than this
// node's.
//
// Usage flows the other way — this node counts, the master mirrors — so in normal
// running the master can only be behind or equal. Lower means something zeroed it
// there, which is what a traffic reset is. Adopting it propagates the reset with
// no second protocol for it, and without this node ever inventing traffic: a
// figure can only be lowered here, never raised.
//
// Without it a reset was undone within ten seconds. The master zeroed its row,
// this node reported its own untouched total, and that total was written back over
// the zero — so one half of a customer's shared allowance came back from the dead
// every time.
func (j *NodeSyncJob) adoptResets(set *service.NodeInboundSet) {
	db := database.GetDB()
	for _, remote := range set.Inbounds {
		for _, ct := range remote.ClientStats {
			if ct.Email == "" {
				continue
			}
			var local xray.ClientTraffic
			if err := db.Model(xray.ClientTraffic{}).
				Where("email = ?", ct.Email).First(&local).Error; err != nil {
				continue
			}
			if ct.Up+ct.Down >= local.Up+local.Down {
				continue // the master is not behind; nothing was reset
			}
			if err := db.Model(xray.ClientTraffic{}).
				Where("email = ?", ct.Email).
				Updates(map[string]any{"up": ct.Up, "down": ct.Down}).Error; err != nil {
				logger.Warning("node sync: could not adopt the master's reset for ", ct.Email, ": ", err)
				continue
			}
			logger.Info("node sync: adopted a traffic reset for ", ct.Email)
		}
	}
}

// managedTagPrefix derives "inbound-<nodeid>-" from what the master sent, so this
// panel can tell the master's inbounds from its own without being told separately.
// Empty when the master sent nothing, which is exactly when nothing may be
// deleted: an empty pull is far more likely to be a master mid-restart than an
// instruction to wipe this node.
func managedTagPrefix(inbounds []*model.Inbound) string {
	for _, in := range inbounds {
		parts := strings.SplitN(in.Tag, "-", 3)
		if len(parts) == 3 && parts[0] == "inbound" && parts[1] != "" {
			return "inbound-" + parts[1] + "-"
		}
	}
	return ""
}

// create adds one of the master's inbounds to this panel.
func (j *NodeSyncJob) create(remote *model.Inbound) error {
	in := copyForLocal(remote)
	in.Id = 0
	in.UserId = localAdminID()
	if _, _, err := j.inboundService.AddInbound(in); err != nil {
		return err
	}
	// AddInbound derives the tag from this panel's point of view, where the
	// inbound is local; the master's tag has to survive, because it is the
	// identity both ends match on.
	return database.GetDB().Model(model.Inbound{}).
		Where("id = ?", in.Id).Update("tag", remote.Tag).Error
}

// update brings one inbound in line with the master's copy.
func (j *NodeSyncJob) update(existing, remote *model.Inbound) error {
	in := copyForLocal(remote)
	in.Id = existing.Id
	in.UserId = existing.UserId
	if _, _, err := j.inboundService.UpdateInbound(in); err != nil {
		return err
	}
	return database.GetDB().Model(model.Inbound{}).
		Where("id = ?", existing.Id).Update("tag", remote.Tag).Error
}

// copyForLocal is the master's row as it must look HERE: served by this panel,
// carrying no traffic figures of the master's own.
//
// NodeId is cleared deliberately. It means "some other server serves this", which
// is true on the master and false here — left set, this panel would faithfully
// exclude the inbound from its own config and serve nothing at all.
func copyForLocal(remote *model.Inbound) *model.Inbound {
	in := *remote
	in.NodeId = ""
	in.ClientStats = nil
	in.Up, in.Down = 0, 0
	return &in
}

// localAdminID is the account new inbounds are filed under on this panel. A node
// has exactly one admin — the installer's — so the first is the right one.
func localAdminID() int {
	var id int
	if err := database.GetDB().Model(model.User{}).Order("id asc").Limit(1).
		Pluck("id", &id).Error; err != nil || id == 0 {
		return 1
	}
	return id
}

// report hands the master what this node's inbounds have carried.
//
// Totals, not deltas: this node is the only server that sees this traffic, so its
// figures ARE the answer. A master that missed a cycle, restarted, or is retrying
// then lands on the same number instead of counting the same bytes twice.
func (j *NodeSyncJob) report(panelURL, token string) error {
	inbounds, err := j.inboundService.GetAllInbounds()
	if err != nil {
		return err
	}
	usage := service.NodeUsage{}
	for _, in := range inbounds {
		if !strings.HasPrefix(in.Tag, "inbound-") || strings.Count(in.Tag, "-") < 2 {
			continue // not one of the master's; see managedTagPrefix
		}
		usage.Inbounds = append(usage.Inbounds, struct {
			Tag  string `json:"tag"`
			Up   int64  `json:"up"`
			Down int64  `json:"down"`
		}{Tag: in.Tag, Up: in.Up, Down: in.Down})

		for _, ct := range in.ClientStats {
			usage.Clients = append(usage.Clients, struct {
				Email  string `json:"email"`
				Up     int64  `json:"up"`
				Down   int64  `json:"down"`
				Enable bool   `json:"enable"`
			}{Email: ct.Email, Up: ct.Up, Down: ct.Down, Enable: ct.Enable})
		}
	}
	if len(usage.Inbounds) == 0 && len(usage.Clients) == 0 {
		return nil
	}
	_, err = nodePost(panelURL+"/node/panel/usage", map[string]any{"token": token, "usage": usage})
	return err
}

// nodePost sends one JSON request to the master and returns its body.
func nodePost(url string, payload any) ([]byte, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := nodeHTTPClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 32<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, &nodeHTTPError{Status: resp.StatusCode}
	}
	return body, nil
}

type nodeHTTPError struct{ Status int }

func (e *nodeHTTPError) Error() string {
	if e.Status == http.StatusNotFound {
		// The one an operator can act on: the master no longer knows this token.
		return "the master panel rejected this node's token — re-add the node there and run its one-liner again"
	}
	return "the master panel answered HTTP " + http.StatusText(e.Status)
}
