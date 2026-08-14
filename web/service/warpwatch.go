package service

import (
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"
)

// WarpWatchService keeps the WARP proxy actually connected.
//
// WARP is how a server reaches the services that refuse it directly — Spotify,
// most of Google — so when it stops, those stop, and nothing else does. That is
// why the failure reads as "it worked for two days and then Spotify broke": the
// panel still shows WARP installed, the SOCKS port is still there, and the
// outbound still points at it. What is gone is the daemon's connection to
// Cloudflare, which it does not always take back by itself after a network blip,
// a suspend, or a lease it failed to renew.
//
// Nothing here installs or configures anything. It reconnects what the operator
// already set up, which is the one thing that had to be done by hand every time.
type WarpWatchService struct{}

// warpWatch remembers what was last reported, so a healthy WARP is silent and a
// broken one states itself once rather than every couple of minutes.
var warpWatch = struct {
	sync.Mutex
	lastState string
	// reconnects is how many times in a row a reconnect was attempted without
	// reaching Connected. It escalates from "connect" to restarting the service.
	reconnects int
}{}

// warpCli runs a warp-cli subcommand, bounded so a hung daemon cannot wedge the
// job. --accept-tos keeps it non-interactive on a fresh registration.
func warpCli(args ...string) (string, error) {
	cmd := exec.Command("warp-cli", append([]string{"--accept-tos"}, args...)...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// Run checks WARP and reconnects it when it has dropped.
func (s *WarpWatchService) Run() {
	if !WarpSocksInstalled() {
		return // WARP was never set up here; nothing to watch
	}
	// A run in progress is an install or reinstall the operator started. Touching
	// the daemon underneath it would fight that.
	if WarpSocksState().Running {
		return
	}

	status, err := warpCli("status")
	if err != nil && status == "" {
		s.say("unreachable", "warp: the daemon did not answer; restarting it")
		s.restartDaemon()
		return
	}
	if strings.Contains(strings.ToLower(status), "connected") &&
		!strings.Contains(strings.ToLower(status), "disconnected") {
		warpWatch.Lock()
		warpWatch.reconnects = 0
		warpWatch.Unlock()
		s.say("ok", "warp: connected")
		return
	}

	// An operator who ran `warp-cli disconnect` meant it — most likely because they
	// moved to a WireGuard outbound and no longer want this daemon in the path.
	// Reconnecting it two minutes later would be the panel overruling them, which
	// is exactly what a watchdog must not do.
	if strings.Contains(status, "Manual Disconnection") {
		s.say("manual", "warp: disconnected by hand; leaving it alone")
		return
	}

	warpWatch.Lock()
	warpWatch.reconnects++
	attempts := warpWatch.reconnects
	warpWatch.Unlock()

	// Ask it to connect first; only if that keeps failing is the daemon itself the
	// problem worth restarting, which drops every connection currently using it.
	if attempts <= 3 {
		s.say("reconnecting", "warp: not connected ("+firstLine(status)+"); reconnecting")
		if out, cerr := warpCli("connect"); cerr != nil {
			logger.Warning("warp: connect failed: ", cerr, " ", firstLine(out))
		}
		return
	}
	// A licence that has been spent is the commonest reason WARP stops being worth
	// having, and it cannot be reconnected out of — so before restarting anything,
	// see whether the account has lapsed to the free tier and put a fresh key on it.
	var keys WarpKeyService
	if keys.AccountIsFree() {
		s.say("relicensing", "warp: the account is back on the free tier; looking for a fresh WARP+ key")
		keys.Scan(true, 25)
	}

	s.say("restarting", "warp: still not connected after several attempts; restarting the service")
	s.restartDaemon()
	warpWatch.Lock()
	warpWatch.reconnects = 0
	warpWatch.Unlock()
}

func (s *WarpWatchService) restartDaemon() {
	if err := exec.Command("systemctl", "restart", "warp-svc").Run(); err != nil {
		logger.Warning("warp: could not restart warp-svc: ", err)
		return
	}
	// The daemon needs a moment before it will accept a connect.
	time.Sleep(3 * time.Second)
	if out, err := warpCli("connect"); err != nil {
		logger.Warning("warp: connect after restart failed: ", err, " ", firstLine(out))
	}
}

// say logs only when the state changed, so a healthy WARP costs nothing in the
// log and a broken one is one line rather than a stream.
func (s *WarpWatchService) say(state, msg string) {
	warpWatch.Lock()
	changed := warpWatch.lastState != state
	warpWatch.lastState = state
	warpWatch.Unlock()
	if !changed {
		return
	}
	if state == "ok" {
		logger.Info(msg)
		return
	}
	logger.Warning(msg)
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
