package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"

	"github.com/mhsanaei/3x-ui/v2/logger"
)

// TunnelService bridges the panel to the vendored `tunnelctl` CLI.
//
// It NEVER re-implements tunnel logic. All reads go through `tunnelctl json …`
// and all mutations go through the existing lifecycle commands
// (create/start/stop/restart/enable/disable/remove/set/optimize). The bash
// project stays the single source of truth, and — critically — the x-ui SQLite
// database is never touched by any tunnel operation, so an unmodified 3x-ui
// backup restores cleanly on this panel.
type TunnelService struct{}

const tunnelCmdTimeout = 30 * time.Second

// Names/keys are constrained to exactly what tunnelctl itself accepts. Even
// though exec.Command does not spawn a shell (so there is no shell-injection
// surface), validating here stops a value like "--flag" from being read as an
// option and keeps error messages sane.
var (
	tunnelNameRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$`)
	fieldKeyRe   = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)
)

func validName(name string) bool { return tunnelNameRe.MatchString(name) }

// tunnelctlPath resolves the tunnelctl entry point, preferring the installed
// symlink, then the install dir, then PATH.
func tunnelctlPath() string {
	for _, p := range []string{"/usr/local/bin/tunnelctl", "/opt/tunnel-manager/tunnelctl"} {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return p
		}
	}
	if p, err := exec.LookPath("tunnelctl"); err == nil {
		return p
	}
	return "tunnelctl"
}

// Installed reports whether the tunnel backend is present on this host.
func (s *TunnelService) Installed() bool {
	for _, p := range []string{"/usr/local/bin/tunnelctl", "/opt/tunnel-manager/tunnelctl"} {
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() {
			return true
		}
	}
	_, err := exec.LookPath("tunnelctl")
	return err == nil
}

// run executes tunnelctl with args and returns stdout. stderr is captured and
// folded into the returned error on failure (tunnelctl prints JSON to stdout
// and human/log lines to stderr, so the two never mix).
func (s *TunnelService) run(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), tunnelCmdTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, tunnelctlPath(), args...)
	// TM_ASSUME_YES: tunnelctl gates destructive actions behind an interactive
	// confirm(). With no TTY the prompt reads EOF and falls back to "no", but the
	// command still exits 0 — so `remove` would report success while silently
	// doing nothing. The panel asks the operator for confirmation in the UI
	// (a-popconfirm) before it ever calls us, so auto-accept here.
	// NO_COLOR keeps ANSI escapes out of captured output.
	cmd.Env = append(os.Environ(), "NO_COLOR=1", "TM_ASSUME_YES=1")

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		logger.Warning("tunnelctl ", strings.Join(args, " "), " failed: ", msg)
		return stdout.Bytes(), errors.New(msg)
	}
	return stdout.Bytes(), nil
}

// runJSON runs `tunnelctl json <sub> [args]` and returns the raw JSON payload,
// validated so the controller can relay it to the browser verbatim.
func (s *TunnelService) runJSON(sub string, args ...string) (json.RawMessage, error) {
	out, err := s.run(append([]string{"json", sub}, args...)...)
	if err != nil {
		return nil, err
	}
	raw := json.RawMessage(bytes.TrimSpace(out))
	if !json.Valid(raw) {
		return nil, errors.New("tunnel backend returned invalid JSON")
	}
	return raw, nil
}

// ---- Reads -----------------------------------------------------------------

func (s *TunnelService) List() (json.RawMessage, error)      { return s.runJSON("list") }
func (s *TunnelService) Meta() (json.RawMessage, error)      { return s.runJSON("meta") }
func (s *TunnelService) Protocols() (json.RawMessage, error) { return s.runJSON("protocols") }

func (s *TunnelService) Tunnel(name string) (json.RawMessage, error) {
	if !validName(name) {
		return nil, errors.New("invalid tunnel name")
	}
	return s.runJSON("tunnel", name)
}

func (s *TunnelService) Fields(name string) (json.RawMessage, error) {
	if !validName(name) {
		return nil, errors.New("invalid tunnel name")
	}
	return s.runJSON("fields", name)
}

func (s *TunnelService) Logs(name string) (string, error) {
	if !validName(name) {
		return "", errors.New("invalid tunnel name")
	}
	out, err := s.run("logs", name)
	return string(out), err
}

// ---- Control ---------------------------------------------------------------

func (s *TunnelService) control(action, name string) error {
	if !validName(name) {
		return errors.New("invalid tunnel name")
	}
	_, err := s.run(action, name)
	return err
}

func (s *TunnelService) Start(name string) error   { return s.control("start", name) }
func (s *TunnelService) Stop(name string) error    { return s.control("stop", name) }
func (s *TunnelService) Restart(name string) error { return s.control("restart", name) }
func (s *TunnelService) Enable(name string) error  { return s.control("enable", name) }
func (s *TunnelService) Disable(name string) error { return s.control("disable", name) }
func (s *TunnelService) Remove(name string) error  { return s.control("remove", name) }

// SetField edits one KEY on a tunnel and lets tunnelctl re-apply/restart it.
func (s *TunnelService) SetField(name, key, value string) error {
	if !validName(name) {
		return errors.New("invalid tunnel name")
	}
	if !fieldKeyRe.MatchString(key) {
		return errors.New("invalid field key")
	}
	_, err := s.run("set", name, key, value)
	return err
}

// Create adds a tunnel non-interactively from a field map (NAME/PROTOCOL/ROLE/…).
// Empty *_SECRET fields and GRE inner addressing are filled in by tunnelctl.
func (s *TunnelService) Create(fields map[string]string) error {
	if !validName(fields["NAME"]) {
		return errors.New("invalid tunnel name")
	}
	if strings.TrimSpace(fields["PROTOCOL"]) == "" {
		return errors.New("protocol is required")
	}
	args := []string{"create"}
	for k, v := range fields {
		if !fieldKeyRe.MatchString(k) {
			continue
		}
		// A value must never contain a newline (it would corrupt the flat
		// KEY=VALUE profile file); reject rather than silently truncate.
		if strings.ContainsAny(v, "\n\r") {
			return errors.New("field " + k + " contains an illegal newline")
		}
		args = append(args, k+"="+v)
	}
	_, err := s.run(args...)
	return err
}

// Optimize applies/reverts the reversible network tuning (sysctl, ip_forward).
func (s *TunnelService) Optimize(action string) error {
	switch action {
	case "apply", "revert", "status":
	default:
		return errors.New("invalid optimize action")
	}
	_, err := s.run("optimize", action)
	return err
}
