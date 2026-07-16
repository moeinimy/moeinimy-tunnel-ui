#!/usr/bin/env bash
# scripts/install.sh — one-command installer for moeinimy-tunnel-ui.
#
# The SAME command is used on both servers; a role flag decides what gets set up.
#
#   Foreign server (control panel + tunnel backend):
#     bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/install.sh)
#
#   Iran node (tunnel backend only, driven remotely from the foreign panel):
#     bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/install.sh) \
#          --iran --panel https://PANEL_HOST:PORT/PATH --token NODE_TOKEN
#
# What it does:
#   foreign) installs/updates the vpn-ui panel (deploy.sh) AND the tunnel backend
#            (tunnel/install.sh, which also applies the reversible network tuning).
#   iran)    installs the tunnel backend only, records the node role + panel
#            coordinates, and enables the control agent so the foreign panel can
#            drive this node. No further SSH is needed on the Iran box.
set -euo pipefail

REPO="${VPNUI_REPO:-moeinimy/moeinimy-tunnel-ui}"
BRANCH="${VPNUI_BRANCH:-main}"
SRC_DIR="/opt/moeinimy-tunnel-ui-src"
TM_CONFIG_DIR="/etc/tunnel-manager"

ROLE="foreign"
PANEL_URL="${PANEL_URL:-}"
NODE_TOKEN="${NODE_TOKEN:-}"

# --- args -------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iran|--node)      ROLE="iran" ;;
        --foreign|--panel-server) ROLE="foreign" ;;
        --role)             shift; ROLE="${1:-foreign}" ;;
        --panel)            shift; PANEL_URL="${1:-}" ;;
        --token)            shift; NODE_TOKEN="${1:-}" ;;
        -h|--help)
            grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "warning: ignoring unknown argument '$1'" >&2 ;;
    esac
    shift
done

# --- root -------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -E bash "$0" \
        --role "$ROLE" ${PANEL_URL:+--panel "$PANEL_URL"} ${NODE_TOKEN:+--token "$NODE_TOKEN"}
fi

command -v systemctl >/dev/null 2>&1 || { echo "error: systemd is required." >&2; exit 1; }
if   command -v curl >/dev/null 2>&1; then DL=(curl -fsSL -o)
elif command -v wget >/dev/null 2>&1; then DL=(wget -qO)
else echo "error: need curl or wget." >&2; exit 1; fi

echo "==> moeinimy-tunnel-ui installer  (role: $ROLE, repo: $REPO@$BRANCH)"

# --- fetch source (tunnel/ + deploy.sh live in the repo) --------------------
fetch_source() {
    echo "==> Fetching source from $REPO ($BRANCH)"
    rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
    local tgz; tgz="$(mktemp)"
    "${DL[@]}" "$tgz" "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" \
        || { echo "error: could not download repo tarball." >&2; exit 1; }
    tar -xzf "$tgz" -C "$SRC_DIR" --strip-components=1
    rm -f "$tgz"
}

install_tunnel_backend() {
    echo "==> Installing tunnel backend (tunnelctl + network tuning)"
    bash "$SRC_DIR/tunnel/install.sh"
}

install_panel() {
    echo "==> Installing / updating the vpn-ui panel"
    # deploy.sh fetches the latest published release binary and installs the unit.
    VPNUI_REPO="$REPO" bash "$SRC_DIR/deploy.sh"
}

# --- role: foreign ----------------------------------------------------------
if [[ "$ROLE" == "foreign" ]]; then
    fetch_source
    install_panel
    install_tunnel_backend
    mkdir -p "$TM_CONFIG_DIR"; echo "foreign" > "$TM_CONFIG_DIR/role"
    echo
    echo "==> Done. Open the panel, sign in, and use the 'Tunnels' menu."
    echo "    Add the Iran node later with the one-liner printed in the panel."
    exit 0
fi

# --- role: iran -------------------------------------------------------------
if [[ "$ROLE" == "iran" ]]; then
    fetch_source
    install_tunnel_backend
    mkdir -p "$TM_CONFIG_DIR"
    echo "iran" > "$TM_CONFIG_DIR/role"
    # Record how to reach the controlling panel. The control agent (enabled by
    # tunnel/install.sh) uses these to register this node with the foreign panel.
    {
        echo "# moeinimy-tunnel-ui node config — written by the installer."
        echo "NODE_ROLE=iran"
        [[ -n "$PANEL_URL"  ]] && echo "PANEL_URL=$PANEL_URL"
        [[ -n "$NODE_TOKEN" ]] && echo "NODE_TOKEN=$NODE_TOKEN"
        echo "REGISTERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$TM_CONFIG_DIR/node.conf"
    chmod 600 "$TM_CONFIG_DIR/node.conf"

    echo
    echo "==> Iran node installed."
    if [[ -n "$PANEL_URL" && -n "$NODE_TOKEN" ]]; then
        echo "    Panel:  $PANEL_URL"
        echo "    This node is registered; manage it from the panel's Tunnels > Nodes."
    else
        echo "    NOTE: no --panel/--token given. Re-run with them, or add this node"
        echo "          from the foreign panel using its per-node one-liner."
    fi
    exit 0
fi

echo "error: unknown role '$ROLE' (use --foreign or --iran)." >&2
exit 1
