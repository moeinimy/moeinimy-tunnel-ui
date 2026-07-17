#!/usr/bin/env bash
# install.sh — install (or update) Tunnel Manager.
#
#   Local:      git clone … && sudo bash install.sh
#   One-liner:  bash <(curl -fsSL https://raw.githubusercontent.com/<repo>/main/install.sh)
#
# Idempotent: re-running upgrades code and infra units without touching config.

set -euo pipefail

INSTALL_DIR="/opt/tunnel-manager"
BIN_LINK="/usr/local/bin/tunnelctl"
UPDATE_MODE="no"
[[ "${1:-}" == "--update" ]] && UPDATE_MODE="yes"

# --- Locate source (bootstrap-download if run standalone via curl) ----------
_src="${BASH_SOURCE[0]}"
SRC_DIR="$(cd -P "$(dirname "$_src")" >/dev/null 2>&1 && pwd)"

if [[ ! -f "$SRC_DIR/tunnelctl" ]]; then
    : "${TM_REPO:=moeinimy/moeinimy-tunnel-ui}"
    : "${TM_BRANCH:=main}"
    echo "Fetching Tunnel Manager source from $TM_REPO ($TM_BRANCH)…"
    _tmp="$(mktemp -d)"
    if ! curl -fsSL --max-time 120 -o "$_tmp/src.tar.gz" \
        "https://github.com/${TM_REPO}/archive/refs/heads/${TM_BRANCH}.tar.gz"; then
        echo "ERROR: could not download source. Set TM_REPO to your repository." >&2
        exit 1
    fi
    tar -xzf "$_tmp/src.tar.gz" -C "$_tmp"
    _root="$(find "$_tmp" -maxdepth 1 -type d -name '*-*' | head -1)"
    # The backend now lives in the panel monorepo under tunnel/; fall back to the
    # archive root so a standalone tunnel-manager checkout still installs.
    if [[ -f "$_root/tunnel/tunnelctl" ]]; then
        SRC_DIR="$_root/tunnel"
    else
        SRC_DIR="$_root"
    fi
    exec bash "$SRC_DIR/install.sh" "$@"
fi

# --- Root check -------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: install must run as root (use sudo)." >&2
    exit 1
fi

# Source shared helpers for logging/deps (TM_HOME points at the source tree).
TM_HOME="$SRC_DIR"; export TM_HOME
# shellcheck source=/dev/null
. "$SRC_DIR/lib/common.sh"
# shellcheck source=/dev/null
. "$SRC_DIR/lib/deps.sh"

log_info "Installing Tunnel Manager (update mode: $UPDATE_MODE)…"

# --- Dependencies -----------------------------------------------------------
deps_install

# --- Copy code into place ---------------------------------------------------
mkdir -p "$INSTALL_DIR"
# Skip the copy when the source already IS the install dir (e.g. git-based
# self-update, which updates files in place) — otherwise we would delete our
# own source before copying it back.
if [[ "$SRC_DIR" != "$INSTALL_DIR" ]]; then
    for item in tunnelctl install.sh uninstall.sh update.sh VERSION LICENSE \
                README.md CHANGELOG.md lib drivers modules systemd docs; do
        [[ -e "$SRC_DIR/$item" ]] || continue
        rm -rf "${INSTALL_DIR:?}/$item"
        cp -a "$SRC_DIR/$item" "$INSTALL_DIR/"
    done
fi
chmod +x "$INSTALL_DIR/tunnelctl" "$INSTALL_DIR"/*.sh 2>/dev/null || true
ln -sf "$INSTALL_DIR/tunnelctl" "$BIN_LINK"

# Switch runtime paths to the installed location and load the libs needed for
# the update-mode re-install loop below. TM_BIN_DIR was already resolved from
# the (temporary) source TM_HOME when common.sh was first sourced, so it MUST be
# unset here — otherwise generated units would point ExecStart at the temp
# extraction dir and break on the next restart.
TM_HOME="$INSTALL_DIR"; export TM_HOME
unset TM_BIN_DIR
# lib/ui.sh is needed even though the installer prints no menus: optimize_apply
# (run below) calls ui_title/ui_kv, which otherwise fail with
# "ui_title: command not found" mid-install.
for _lib in lib/common.sh lib/validate.sh lib/ui.sh lib/config.sh lib/ipam.sh \
            lib/systemd.sh drivers/driver.sh drivers/gre.sh drivers/paqet.sh \
            drivers/backhaul.sh drivers/backpack.sh drivers/rathole.sh drivers/gost.sh drivers/frp.sh drivers/hysteria.sh \
            modules/peer.sh; do
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/$_lib"
done
ensure_dirs

# --- Default settings (created once, never overwritten) ---------------------
if [[ ! -f "$TM_SETTINGS_FILE" ]]; then
    cat >"$TM_SETTINGS_FILE" <<EOF
# Tunnel Manager settings — edit and restart services to apply.
TM_REPO=${TM_REPO:-moeinimy/moeinimy-tunnel-ui}
TM_BRANCH=main

# Paqet binary source (see docs if downloads fail)
PAQET_REPO=hanselime/paqet
# PAQET_VERSION=v1.0.0-alpha.20    # pin a version; unset = latest release

# IPAM pool base for tunnel /30 inner subnets
TM_IPAM_POOL_BASE=10.20.0.0

# Monitor
TM_MONITOR_INTERVAL=30
TM_MONITOR_RETRIES=3
TM_CPU_ALERT=90
TM_RAM_ALERT=90
TM_DISK_ALERT=90
EOF
    chmod 600 "$TM_SETTINGS_FILE"
    log_ok "Wrote default settings to $TM_SETTINGS_FILE"
else
    # Migration: settings.conf is written once and never overwritten, so an install
    # from before the panel merge still pins the standalone tunnel-manager repo.
    # Left alone, `tunnelctl update` would pull that repo and DOWNGRADE the backend
    # (no api.sh/prepare.sh/nodeagent.sh), silently breaking the panel integration.
    if grep -q '^TM_REPO=moeinimy/tunnel-manager[[:space:]]*$' "$TM_SETTINGS_FILE" 2>/dev/null; then
        sed -i 's|^TM_REPO=moeinimy/tunnel-manager[[:space:]]*$|TM_REPO=moeinimy/moeinimy-tunnel-ui|' "$TM_SETTINGS_FILE"
        log_ok "Migrated TM_REPO in $TM_SETTINGS_FILE to the panel monorepo."
    fi
fi

# --- Infra systemd units ----------------------------------------------------
install -m 0644 "$INSTALL_DIR/systemd/tm-monitor.service" /etc/systemd/system/tm-monitor.service
install -m 0644 "$INSTALL_DIR/systemd/tm-bot.service"     /etc/systemd/system/tm-bot.service
install -m 0644 "$INSTALL_DIR/systemd/tm-report.service"  /etc/systemd/system/tm-report.service
install -m 0644 "$INSTALL_DIR/systemd/tm-report.timer"    /etc/systemd/system/tm-report.timer
install -m 0644 "$INSTALL_DIR/systemd/tm-agent.socket"    /etc/systemd/system/tm-agent.socket
install -m 0644 "$INSTALL_DIR/systemd/tm-agent@.service"  /etc/systemd/system/tm-agent@.service
systemctl daemon-reload
systemctl enable --now tm-monitor.service >/dev/null 2>&1 || log_warn "Could not start tm-monitor."
systemctl enable --now tm-report.timer   >/dev/null 2>&1 || log_warn "Could not enable tm-report.timer."
# Peer control agent (zero-config multi-server over the tunnel).
systemctl enable --now tm-agent.socket   >/dev/null 2>&1 || log_warn "Could not enable tm-agent.socket."
agent_firewall ensure 2>/dev/null || true

# Restart long-running services so updated code (monitor accounting, bot UI)
# takes effect immediately. try-restart only acts if the unit is running.
systemctl try-restart tm-monitor.service >/dev/null 2>&1 || true
systemctl try-restart tm-bot.service     >/dev/null 2>&1 || true
# Start the bot only if Telegram is already configured.
if [[ -f "$TM_TELEGRAM_FILE" ]] && grep -q '^TG_ENABLED=yes' "$TM_TELEGRAM_FILE" 2>/dev/null; then
    systemctl enable --now tm-bot.service >/dev/null 2>&1 || true
fi

# --- Log rotation -----------------------------------------------------------
cat >/etc/logrotate.d/tunnel-manager <<EOF
$TM_LOG_DIR/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

# Apply network optimization automatically (reversible) unless opted out. This
# also guarantees ip_forward is on, so forwarding tunnels work out of the box.
if [[ "${1:-}" != "--no-optimize" && "${2:-}" != "--no-optimize" ]]; then
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/modules/optimize.sh"
    TM_ASSUME_YES=1 optimize_apply || log_warn "Optimization step reported issues (continuing)."
fi

# Re-install per-tunnel units on update (their contents may have changed).
if [[ "$UPDATE_MODE" == yes ]]; then
    while read -r n; do
        [[ -n "$n" ]] || continue
        load_tunnel "$n" || continue
        svc_install "$n" || true
    done < <(list_tunnels 2>/dev/null || true)
fi

log_ok "Tunnel Manager installed."
if [[ "$UPDATE_MODE" != yes ]]; then
    cat <<EOF

${C_GREEN}${C_BOLD}Done!${C_RESET} Network stack tuned, forwarding enabled. Launch:

    ${C_CYAN}sudo tunnelctl${C_RESET}

Then just: ${C_CYAN}Add tunnel${C_RESET} (pick GRE or Paqet, and a forwarding mode).
Telegram is optional: ${C_CYAN}sudo tunnelctl telegram config${C_RESET}
EOF
fi
