#!/usr/bin/env bash
# uninstall.sh — remove Tunnel Manager cleanly and revert system changes.

set -euo pipefail

INSTALL_DIR="/opt/tunnel-manager"
BIN_LINK="/usr/local/bin/tunnelctl"

if [[ "$(id -u)" -ne 0 ]]; then echo "Run as root (sudo)." >&2; exit 1; fi

TM_HOME="${INSTALL_DIR}"; export TM_HOME
if [[ -f "$INSTALL_DIR/lib/common.sh" ]]; then
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/lib/common.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/lib/config.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/lib/systemd.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/driver.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/gre.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/paqet.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/backhaul.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/backpack.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/rathole.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/gost.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/frp.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/drivers/hysteria.sh"
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/lib/ipam.sh"
else
    echo "Tunnel Manager does not appear to be installed at $INSTALL_DIR."
fi

log() { printf '[uninstall] %s\n' "$*"; }

# --- Confirmation -----------------------------------------------------------
if [[ -z "${TM_ASSUME_YES:-}" ]]; then
    read -r -p "Remove ALL tunnels, services and revert optimization? [y/N] " a || true
    [[ "$a" =~ ^[yY] ]] || { echo "Aborted."; exit 0; }
fi

# --- Tear down each tunnel --------------------------------------------------
if declare -F list_tunnels >/dev/null; then
    while read -r n; do
        [[ -n "$n" ]] || continue
        log "removing tunnel $n"
        if load_tunnel "$n"; then
            systemctl disable --now "$(unit_name "$n")" >/dev/null 2>&1 || true
            driver_down 2>/dev/null || true
            rm -f "$(unit_path "$n")"
        fi
    done < <(list_tunnels 2>/dev/null || true)
fi

# --- Revert optimization ----------------------------------------------------
if declare -F optimize_revert >/dev/null; then :; fi
if [[ -f "$INSTALL_DIR/modules/optimize.sh" ]]; then
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/modules/optimize.sh"
    optimize_revert 2>/dev/null || true
fi

# --- Stop and remove infra services ----------------------------------------
for u in tm-monitor.service tm-bot.service tm-report.service tm-report.timer \
         tm-agent.socket tm-agent@.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
done
systemctl daemon-reload 2>/dev/null || true
# Remove the agent firewall rules if the helper is available.
if [[ -f "$INSTALL_DIR/modules/peer.sh" ]]; then
    # shellcheck source=/dev/null
    . "$INSTALL_DIR/modules/peer.sh" 2>/dev/null || true
    agent_firewall remove 2>/dev/null || true
fi

# --- Remove files -----------------------------------------------------------
rm -f "$BIN_LINK"
rm -f /etc/logrotate.d/tunnel-manager

KEEP_CONFIG="no"
if [[ -z "${TM_ASSUME_YES:-}" ]]; then
    read -r -p "Keep configuration and backups in /etc/tunnel-manager and /var/lib/tunnel-manager? [y/N] " k || true
    [[ "$k" =~ ^[yY] ]] && KEEP_CONFIG="yes"
fi

rm -rf "$INSTALL_DIR"
if [[ "$KEEP_CONFIG" != yes ]]; then
    rm -rf /etc/tunnel-manager /var/lib/tunnel-manager /var/log/tunnel-manager
    log "removed configuration, state and logs"
else
    log "kept /etc/tunnel-manager and /var/lib/tunnel-manager"
fi

log "Tunnel Manager uninstalled."
