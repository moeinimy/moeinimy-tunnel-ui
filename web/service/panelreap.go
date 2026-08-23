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
