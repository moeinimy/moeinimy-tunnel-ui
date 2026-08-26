package service

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/mhsanaei/3x-ui/v2/logger"
)

// ReapStalePanels ends any OTHER instance of this panel still running.
//
// This is the fault behind "two Xrays serving half the config each". The second
// core was never the disease: each was a healthy child of its own PANEL. An
// update left the previous instance alive — same binary, same directory — and it
// went on managing an Xray of its own, so the ports were split between two
// processes that each believed they held the whole config.
//
// It also explains why killing the stray Xray only helped for a while: the panel
// that owned it noticed within a second and started another. Reaping Xray alone
// was treating the symptom, and losing to a process that was doing its job.
//
// Matched by executable path AND working directory, and only for the same binary
// this process runs — so an unrelated panel installed elsewhere on the box is
// never touched. The current process, and its own parent (systemd, or the shell
// that launched it), are excluded by construction.
func ReapStalePanels() {
	self := os.Getpid()
	parent := os.Getppid()

	exe, err := os.Executable()
	if err != nil {
		return
	}
	if resolved, rerr := filepath.EvalSymlinks(exe); rerr == nil {
		exe = resolved
	}
	base := filepath.Base(exe)

	cwd, err := os.Getwd()
	if err != nil {
		return
	}
	if resolved, rerr := filepath.EvalSymlinks(cwd); rerr == nil {
		cwd = resolved
	}

	entries, err := os.ReadDir("/proc")
	if err != nil {
		return
	}
	for _, e := range entries {
		pid, cerr := strconv.Atoi(e.Name())
		if cerr != nil || pid == self || pid == parent {
			continue
		}
		// The same binary, by the path it was launched from. A replaced file reads
		// back as "…(deleted)", which is exactly the case an update creates, so the
		// suffix is trimmed rather than compared.
		link, lerr := os.Readlink("/proc/" + e.Name() + "/exe")
		if lerr != nil {
			continue
		}
		link = strings.TrimSuffix(link, " (deleted)")
		if filepath.Base(link) != base {
			continue
		}
		// ...running from OUR directory, so a separate installation is left alone.
		other, cerr2 := os.Readlink("/proc/" + e.Name() + "/cwd")
		if cerr2 != nil || other != cwd {
			continue
		}

		logger.Warning("ending a previous instance of this panel that survived an update: pid ", pid,
			" — two panels each manage their own Xray, which splits the config's ports between them")
		proc, perr := os.FindProcess(pid)
		if perr != nil {
			continue
		}
		// Ask first: a clean exit lets it stop its own Xray, so nothing is left
		// orphaned for the next step to find.
		_ = proc.Signal(syscall.SIGTERM)
	}
}

// otherPanelNames are the executables of panels that manage an Xray of their own.
// Kept small and explicit: this list only ever produces a log line, so a name
// missing from it costs nothing, while a name wrongly on it would accuse an
// unrelated process.
var otherPanelNames = map[string]bool{
	"x-ui":         true,
	"3x-ui":        true,
	"vpn-ui":       true,
	"vpn-ui-amd64": true,
}

// ReportCoexistingPanels says once, at startup, that another panel is running
// here — and does nothing else about it.
//
// ReapStalePanels deliberately will not touch an installation in another
// directory, and that is right: on this fork's own foreign server an old x-ui in
// /usr/local/x-ui serves 443 and 2086 while vpn-ui in /opt/vpn-ui serves 2052,
// 2095, 8080 and 12308. The ports are disjoint, both are wanted, and reaping the
// other would drop every client on it.
//
// But it stayed invisible until someone read `ss -lntp` by hand during an
// outage, and it changes what the evidence means: two Xrays on the box is normal
// HERE and alarming elsewhere, and a port this panel cannot bind may simply
// belong to the other one. So it is worth one line in the log, and no more —
// this is information, not a fault.
func ReportCoexistingPanels() {
	self := os.Getpid()

	exe, err := os.Executable()
	if err != nil {
		return
	}
	if resolved, rerr := filepath.EvalSymlinks(exe); rerr == nil {
		exe = resolved
	}
	ourDir := filepath.Dir(exe)

	entries, err := os.ReadDir("/proc")
	if err != nil {
		return
	}
	for _, e := range entries {
		pid, cerr := strconv.Atoi(e.Name())
		if cerr != nil || pid == self {
			continue
		}
		link, lerr := os.Readlink("/proc/" + e.Name() + "/exe")
		if lerr != nil {
			continue
		}
		link = strings.TrimSuffix(link, " (deleted)")
		if !otherPanelNames[filepath.Base(link)] {
			continue
		}
		// Our own directory is ReapStalePanels' business, not this one's.
		if filepath.Dir(link) == ourDir {
			continue
		}
		logger.Info("another panel is running on this host: pid ", pid, " at ", link,
			" — left alone deliberately, since it is a separate installation with its own Xray and its own ports;",
			" expect two Xray processes here, and a port this panel cannot bind may belong to that one")
	}
}
