package job

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
)

// TunnelHealthJob tells the operator when a relayed port stops being served.
//
// A tunnel can be perfectly healthy and carry nothing. The relay accepts the
// connection, hands it to the far end, and the far end finds nothing listening on
// the port it was told to deliver to — the only trace is a line in a daemon's
// journal that nobody reads:
//
//	local dialer: dial tcp -> 127.0.0.1:8080: connect: connection refused
//
// From the outside this is indistinguishable from the tunnel being down, which is
// why it costs an evening every time: the panel says up, the ping works, and the
// configs do not. This asks the question the operator would have to ask by hand —
// for every port a tunnel relays, is anything actually serving it here — and says
// so once when the answer changes.
type TunnelHealthJob struct {
	tunnelService service.TunnelService
	tgbot         service.Tgbot
}

func NewTunnelHealthJob() *TunnelHealthJob { return new(TunnelHealthJob) }

// tunnelHealth remembers the last verdict per port, so a broken port is reported
// once rather than every cycle, and a recovery is reported too.
var tunnelHealth = struct {
	sync.Mutex
	down map[string]bool
}{down: map[string]bool{}}

func (j *TunnelHealthJob) Run() {
	if !j.tunnelService.Installed() {
		return
	}
	raw, err := j.tunnelService.List()
	if err != nil {
		return
	}
	var list []struct {
		Name   string `json:"name"`
		Active bool   `json:"active"`
	}
	if json.Unmarshal(raw, &list) != nil {
		return
	}

	for _, t := range list {
		// A stopped tunnel has no ports to serve; reporting its ports as down
		// would be reporting the same thing twice.
		if !t.Active {
			continue
		}
		checks, err := j.tunnelService.CheckPorts(t.Name)
		if err != nil {
			continue
		}
		for _, c := range checks {
			j.report(t.Name, c)
		}
	}
}

// report announces a change of verdict for one port, and nothing otherwise.
func (j *TunnelHealthJob) report(tunnel string, c service.PortCheck) {
	key := fmt.Sprintf("%s/%s/%d", tunnel, c.Proto, c.Listen)

	tunnelHealth.Lock()
	wasDown := tunnelHealth.down[key]
	if c.OK {
		delete(tunnelHealth.down, key)
	} else {
		tunnelHealth.down[key] = true
	}
	tunnelHealth.Unlock()

	if c.OK == !wasDown {
		return // nothing changed
	}
	if !c.OK {
		logger.Warning("tunnel ", tunnel, ": nothing serves ", c.Proto, " ", c.Dest, " — ", c.Detail)
		j.tgbot.SendMsgToTgbotAdmins(strings.TrimSpace(fmt.Sprintf(
			"🔴 A relayed port is not being served\n"+
				"Tunnel: %s\n"+
				"Port: %s %d → %d\n"+
				"%s\n\n"+
				"The tunnel itself is up. Nothing is listening on the port it delivers to, "+
				"so every config behind it fails while everything looks healthy.",
			tunnel, c.Proto, c.Listen, c.Dest, c.Detail)))
		return
	}
	logger.Info("tunnel ", tunnel, ": ", c.Proto, " ", c.Dest, " is being served again")
	j.tgbot.SendMsgToTgbotAdmins(fmt.Sprintf(
		"🟢 Serving again\nTunnel: %s\nPort: %s %d → %d",
		tunnel, c.Proto, c.Listen, c.Dest))
}
