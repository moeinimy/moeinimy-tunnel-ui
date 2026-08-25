package job

import (
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
)

// CheckInboundPortsJob keeps Xray's inbound ports bound.
//
// The sibling of CheckVpnDokodemoJob, for the ports accounts actually connect to.
// Xray can come up having bound only some of the ports it was given — after a
// reboot, or a restart that raced whatever held a port a moment earlier — and it
// says nothing: the process is healthy, the panel reports one running core, and
// only the accounts on the skipped port stop working. It cost an evening the last
// time, and the first real clue was the relay complaining that the far end refused
// a connection on a port this machine was supposed to be serving.
//
// Both guards here matter more than the check does. The streak means a restart
// already in progress is not read as a failure, and the attempt cap means a port
// that cannot be bound at all is reported and left alone rather than restarting
// Xray every half minute for the rest of the day.
type CheckInboundPortsJob struct {
	coreService  service.CoreService
	xrayService  service.XrayService
	missStreak   int // consecutive checks with an unbound inbound port
	healAttempts int // restarts spent since the ports were last all bound
}

// NewCheckInboundPortsJob creates a new inbound port health-check job.
func NewCheckInboundPortsJob() *CheckInboundPortsJob { return new(CheckInboundPortsJob) }

// Run restarts Xray when an inbound port has been unbound for two checks running.
func (j *CheckInboundPortsJob) Run() {
	// A stopped core is not this job's business: a crash belongs to
	// CheckXrayRunningJob, and a deliberate stop from Core Settings must stay
	// stopped.
	if !j.xrayService.IsXrayRunning() {
		j.missStreak = 0
		return
	}

	missing := j.coreService.MissingInboundPorts()
	if len(missing) == 0 {
		j.missStreak = 0
		j.healAttempts = 0
		return
	}

	j.missStreak++
	if j.missStreak < 2 {
		return
	}
	j.missStreak = 0

	if j.healAttempts >= 3 {
		logger.Error("inbound ports still unbound after 3 restart attempts; leaving them until something changes:", missing)
		return
	}
	j.healAttempts++
	// Forced, because a plain restart no-ops when the on-disk config has not
	// changed — and it has not. The config is right; it is the running process
	// that is missing a listener.
	logger.Warning("inbound ports unbound, restarting Xray to rebind:", missing)
	if err := j.xrayService.RestartXray(true); err != nil {
		logger.Error("inbound port health check: restart xray failed:", err)
	}
}
