// Package job provides background job implementations for the vpn-ui web panel,
// including traffic monitoring, system checks, and periodic maintenance tasks.
package job

import (
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
)

// CheckXrayRunningJob monitors Xray process health and restarts it if it crashes.
type CheckXrayRunningJob struct {
	xrayService service.XrayService
	tgbot       service.Tgbot
	checkTime   int
}

// NewCheckXrayRunningJob creates a new Xray health check job instance.
func NewCheckXrayRunningJob() *CheckXrayRunningJob {
	return new(CheckXrayRunningJob)
}

// xrayDownState remembers whether the core is currently being reported as down, so a
// crash is announced once and its recovery once — rather than every second, which on a
// job at this interval would be 3600 messages an hour and a bot nobody reads.
var xrayDownState = struct {
	sync.Mutex
	down bool
}{}

// Run checks if Xray has crashed and restarts it after confirming it's down for 2 consecutive checks.
func (j *CheckXrayRunningJob) Run() {
	if !j.xrayService.DidXrayCrash() {
		j.checkTime = 0
		j.announceUp()
		return
	}
	j.checkTime++
	// only restart if it's down 2 times in a row
	if j.checkTime > 1 {
		err := j.xrayService.RestartXray(false)
		j.checkTime = 0
		if err != nil {
			logger.Error("Restart xray failed:", err)
		}
		// After the restart attempt, not before: a core that came straight back is not
		// worth waking anybody for, and this job runs every second, so nearly all of
		// them do. Only one that is still down has actually cost the customers
		// anything.
		if j.xrayService.DidXrayCrash() {
			j.announceDown(err)
		}
	}
}

// announceDown reports a core that would not come back, with the reason.
//
// The reason is the point. A bare "Xray is down" is another line to ignore; the text
// the core itself refused with is what tells an operator whether to wait, look at a
// port, or look at a config — and until now it existed only in a log on the server,
// which is no use to somebody who finds out because customers complain.
func (j *CheckXrayRunningJob) announceDown(restartErr error) {
	xrayDownState.Lock()
	already := xrayDownState.down
	xrayDownState.down = true
	xrayDownState.Unlock()
	if already {
		return
	}

	reason := ""
	if restartErr != nil {
		reason = restartErr.Error()
	}
	if e := j.xrayService.GetXrayErr(); e != nil {
		reason = strings.TrimSpace(reason + " " + e.Error())
	}
	// The core's own last words, which carry the bind failures and config errors that
	// the Go-side error never sees.
	if out := strings.TrimSpace(j.xrayService.GetXrayResult()); out != "" {
		reason = strings.TrimSpace(reason + "\n" + out)
	}
	if reason == "" {
		reason = "no reason reported by the core"
	}
	if len(reason) > 900 {
		reason = reason[:900] + "…"
	}

	host, _ := os.Hostname()
	logger.Error("Xray is down and did not restart: ", reason)
	j.tgbot.SendMsgToTgbotAdmins(fmt.Sprintf(
		"🔴 Xray is down on %s\n\nIt did not come back after a restart, so every account on this server is offline until it does.\n\n%s",
		host, reason))
}

// announceUp reports the recovery, but only to whoever was told about the outage.
func (j *CheckXrayRunningJob) announceUp() {
	xrayDownState.Lock()
	wasDown := xrayDownState.down
	xrayDownState.down = false
	xrayDownState.Unlock()
	if !wasDown {
		return
	}
	host, _ := os.Hostname()
	logger.Info("Xray is running again")
	j.tgbot.SendMsgToTgbotAdmins(fmt.Sprintf("🟢 Xray is running again on %s", host))
}
