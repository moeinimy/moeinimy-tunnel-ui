#!/usr/bin/env bash
# scripts/install.sh — one-command installer for moeinimy-tunnel-ui.
#
# The SAME command is used on every server; a role flag decides what gets set up.
#
#   Panel server (control panel + tunnel backend) — this is the foreign server
#   you administer from:
#     bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/install.sh)
#
#   Iran node (tunnel backend only, driven remotely from the panel):
#     bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/install.sh) \
#          --iran --panel https://PANEL_HOST:PORT/PATH --token NODE_TOKEN
#
#   Foreign node (another foreign server, driven entirely from the first panel):
#     bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/install.sh) \
#          --foreign-node --panel https://PANEL_HOST:PORT/PATH --token NODE_TOKEN
#
# What it does:
#   foreign)      installs/updates the vpn-ui panel (deploy.sh) AND the tunnel
#                 backend (tunnel/install.sh, which also applies the reversible
#                 network tuning).
#   iran)         installs the tunnel backend only, records the node role + panel
#                 coordinates, and enables the control agent so the panel can
#                 drive this node. No further SSH is needed on that box.
#   foreign-node) the same, PLUS the full panel. It is not a stripped-down worker:
#                 it compiles its own Xray, holds its own certificates, speed
#                 limits and accounting, and enforces quota and expiry itself — so
#                 every feature works there because it is the same code. It simply
#                 takes its inbounds from the first panel instead of an operator,
#                 which is why one command here is all there is to do.
#
# All node roles run the same tunnel agent; the role says which END of a tunnel
# the panel may put this server on, and whether it also serves inbounds.
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
        --foreign-node|--foreign-agent) ROLE="foreign-node" ;;
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

# install_panel [unattended]
#
# unattended=1 answers every question deploy.sh would ask with its default. A node
# is installed by a one-liner the master printed, so there is nobody at that
# terminal to answer them — and the whole promise is that this server takes one
# command and nothing else.
install_panel() {
    echo "==> Installing / updating the vpn-ui panel"
    # deploy.sh fetches the latest published release binary and installs the unit.
    if [[ "${1:-}" == "unattended" ]]; then
        VPNUI_REPO="$REPO" VPNUI_NONINTERACTIVE=1 bash "$SRC_DIR/deploy.sh"
    else
        VPNUI_REPO="$REPO" bash "$SRC_DIR/deploy.sh"
    fi
}

# --- role: foreign ----------------------------------------------------------
if [[ "$ROLE" == "foreign" ]]; then
    fetch_source
    install_panel
    install_tunnel_backend
    mkdir -p "$TM_CONFIG_DIR"; echo "foreign" > "$TM_CONFIG_DIR/role"
    echo
    echo "==> Done. Open the panel, sign in, and use the 'Tunnels' menu."
    echo "    Add your Iran and foreign nodes later with the one-liners the panel prints."
    exit 0
fi

# --- role: iran | foreign-node ----------------------------------------------
# Both are the same install — the tunnel backend plus the control agent. Only the
# recorded role differs, and it exists so the panel knows which END of a tunnel
# this server may be put on.
if [[ "$ROLE" == "iran" || "$ROLE" == "foreign-node" ]]; then
    NODE_ROLE="iran"
    [[ "$ROLE" == "foreign-node" ]] && NODE_ROLE="foreign"

    fetch_source
    install_tunnel_backend
    mkdir -p "$TM_CONFIG_DIR"
    echo "$NODE_ROLE" > "$TM_CONFIG_DIR/role"
    # Record how to reach the controlling panel. The control agent (enabled by
    # tunnel/install.sh) uses these to register this node with the panel.
    {
        echo "# moeinimy-tunnel-ui node config — written by the installer."
        echo "NODE_ROLE=$NODE_ROLE"
        [[ -n "$PANEL_URL"  ]] && echo "PANEL_URL=$PANEL_URL"
        [[ -n "$NODE_TOKEN" ]] && echo "NODE_TOKEN=$NODE_TOKEN"
        echo "REGISTERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$TM_CONFIG_DIR/node.conf"
    chmod 600 "$TM_CONFIG_DIR/node.conf"

    # A foreign node runs the FULL panel, not a cut-down worker: it compiles its
    # own Xray and owns its certificates, speed limits, accounting and quota
    # enforcement, so every feature works there because it is the same code. It
    # takes its inbounds from the master panel instead of from an operator, which
    # is why this one command is all there is to do on this server. An Iran node
    # relays and serves nothing, so it gets no panel.
    #
    # AFTER node.conf is written: the panel decides at startup whether it is a node
    # and only then schedules the sync, so installing it first would leave it idle
    # until something restarted it.
    if [[ "$NODE_ROLE" == "foreign" ]]; then
        install_panel unattended
    fi

    # jq is required by the node agent to parse the panel's command payloads.
    if ! command -v jq >/dev/null 2>&1; then
        echo "==> Installing jq"
        (apt-get update -y && apt-get install -y jq) >/dev/null 2>&1 \
            || yum install -y jq >/dev/null 2>&1 \
            || dnf install -y jq >/dev/null 2>&1 \
            || echo "warning: could not auto-install jq — install it manually." >&2
    fi

    # Install + start the control agent so the node connects to the panel and is
    # driven remotely (no further SSH needed on this box).
    if [[ -f "$SRC_DIR/tunnel/systemd/tm-node-agent.service" ]]; then
        install -m 0644 "$SRC_DIR/tunnel/systemd/tm-node-agent.service" \
            /etc/systemd/system/tm-node-agent.service
        systemctl daemon-reload
        if [[ -n "$PANEL_URL" && -n "$NODE_TOKEN" ]]; then
            # enable --now is a NO-OP when the agent is already running, so a
            # re-install would leave the old process alive holding the PREVIOUS
            # token — which the panel has since deleted. It then 404s forever while
            # systemd still reports "active". Always restart so the token we just
            # wrote is the one actually in use.
            systemctl enable tm-node-agent.service >/dev/null 2>&1 || true
            if systemctl restart tm-node-agent.service; then
                echo "==> Node agent (re)started — connecting to the panel."
            else
                echo "warning: could not start tm-node-agent (check: journalctl -u tm-node-agent -e)" >&2
            fi
        fi
    fi

    echo
    echo "==> ${NODE_ROLE^} node installed."
    if [[ -n "$PANEL_URL" && -n "$NODE_TOKEN" ]]; then
        echo "    Panel:  $PANEL_URL"
        echo "    This node dials out to the panel — manage it from Tunnels > Nodes."
        echo "    Agent status:  systemctl status tm-node-agent"
    else
        echo "    NOTE: no --panel/--token given. Add this node from the panel"
        echo "          (Tunnels > Nodes > Add) and run the one-liner it shows."
    fi
    exit 0
fi

echo "error: unknown role '$ROLE' (use --foreign, --iran or --foreign-node)." >&2
exit 1
