#!/usr/bin/env bash
# lib/common.sh — shared constants, paths, colors, logging and small helpers.
# This file is sourced by every entry point; it defines functions only and
# must not run side effects at source time.

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------
: "${TM_NAME:=Tunnel Manager}"
: "${TM_CONFIG_DIR:=/etc/tunnel-manager}"
: "${TM_STATE_DIR:=/var/lib/tunnel-manager}"
: "${TM_LOG_DIR:=/var/log/tunnel-manager}"
: "${TM_TUNNELS_DIR:=$TM_CONFIG_DIR/tunnels}"
: "${TM_PAQET_DIR:=$TM_CONFIG_DIR/paqet}"
: "${TM_BACKHAUL_DIR:=$TM_CONFIG_DIR/backhaul}"
: "${TM_BACKPACK_DIR:=$TM_CONFIG_DIR/backpack}"
: "${TM_HYSTERIA_DIR:=$TM_CONFIG_DIR/hysteria}"
: "${TM_RATHOLE_DIR:=$TM_CONFIG_DIR/rathole}"
: "${TM_GOST_DIR:=$TM_CONFIG_DIR/gost}"
: "${TM_FRP_DIR:=$TM_CONFIG_DIR/frp}"
: "${TM_STATE_TUNNELS:=$TM_STATE_DIR/state}"
: "${TM_BACKUP_DIR:=$TM_STATE_DIR/backups}"
: "${TM_BIN_DIR:=$TM_HOME/bin}"
: "${TM_LOG_FILE:=$TM_LOG_DIR/tunnel-manager.log}"
: "${TM_SETTINGS_FILE:=$TM_CONFIG_DIR/settings.conf}"
: "${TM_TELEGRAM_FILE:=$TM_CONFIG_DIR/telegram.conf}"
# Absolute path to the installed CLI (referenced by generated systemd units).
: "${TM_CTL:=/usr/local/bin/tunnelctl}"
# Peer-control agent port (served only over tunnel interfaces).
: "${TM_AGENT_PORT:=8271}"

# systemd unit prefix used for per-tunnel services.
TM_UNIT_PREFIX="tm-tunnel-"

# GitHub repository used for self-update (owner/name). Override in settings.conf.
: "${TM_REPO:=moeinimy/moeinimy-tunnel-ui}"

# ---------------------------------------------------------------------------
# Colors (disabled automatically when output is not a TTY or NO_COLOR is set)
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'; C_WHITE=$'\033[37m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_MAGENTA=''; C_CYAN=''; C_WHITE=''
fi

# ---------------------------------------------------------------------------
# Logging — structured line to file + colored line to stderr
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    # Best-effort file logging; never fail the caller because of logging.
    if [[ -n "${TM_LOG_DIR:-}" ]]; then
        mkdir -p "$TM_LOG_DIR" 2>/dev/null || true
        printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$TM_LOG_FILE" 2>/dev/null || true
    fi
}

log_info()  { _log INFO  "$*"; printf '%s[i]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*" >&2; }
log_ok()    { _log INFO  "$*"; printf '%s[✓]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*" >&2; }
log_warn()  { _log WARN  "$*"; printf '%s[!]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { _log ERROR "$*"; printf '%s[✗]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
log_debug() { [[ -n "${TM_DEBUG:-}" ]] || return 0; _log DEBUG "$*"; printf '%s[d] %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

# die MESSAGE [EXIT_CODE]
die() {
    local code="${2:-1}"
    log_error "$1"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# require_root — abort unless running as uid 0.
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This action requires root privileges. Re-run with sudo."
    fi
}

# have CMD — true if command exists in PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# run CMD... — log then execute; return the command's exit status.
run() {
    log_debug "run: $*"
    "$@"
}

# run_quiet CMD... — execute discarding stdout/stderr, return status.
run_quiet() {
    log_debug "run_quiet: $*"
    "$@" >/dev/null 2>&1
}

# confirm PROMPT [default:yes|no] — interactive yes/no, honours TM_ASSUME_YES.
confirm() {
    local prompt="$1" def="${2:-no}" reply
    if [[ -n "${TM_ASSUME_YES:-}" ]]; then return 0; fi
    local hint="[y/N]"; [[ "$def" == "yes" ]] && hint="[Y/n]"
    read -r -p "$(printf '%s%s%s %s ' "$C_CYAN" "$prompt" "$C_RESET" "$hint")" reply || true
    reply="${reply:-$def}"
    [[ "$reply" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# ensure_dirs — create the runtime directory tree with sane permissions.
ensure_dirs() {
    local d
    for d in "$TM_CONFIG_DIR" "$TM_TUNNELS_DIR" "$TM_PAQET_DIR" "$TM_BACKHAUL_DIR" "$TM_BACKPACK_DIR" "$TM_HYSTERIA_DIR" "$TM_RATHOLE_DIR" "$TM_GOST_DIR" "$TM_FRP_DIR" \
             "$TM_STATE_DIR" "$TM_STATE_TUNNELS" "$TM_BACKUP_DIR" "$TM_LOG_DIR"; do
        mkdir -p "$d" 2>/dev/null || true
    done
    # Secrets live under config; keep them private.
    chmod 700 "$TM_CONFIG_DIR" 2>/dev/null || true
}

# load_settings — source optional settings.conf and telegram.conf if present.
load_settings() {
    [[ -f "$TM_SETTINGS_FILE" ]] && . "$TM_SETTINGS_FILE"
    return 0
}

# human_bytes N — format a byte count as a human readable string.
human_bytes() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.2f GiB", b/1073741824}'
    elif (( b >= 1048576 ));    then awk -v b="$b" 'BEGIN{printf "%.2f MiB", b/1048576}'
    elif (( b >= 1024 ));       then awk -v b="$b" 'BEGIN{printf "%.2f KiB", b/1024}'
    else printf '%d B' "$b"; fi
}

# human_duration SECONDS — format seconds as "1d 2h 3m".
human_duration() {
    local s="${1:-0}" d h m
    d=$(( s / 86400 )); s=$(( s % 86400 ))
    h=$(( s / 3600 ));  s=$(( s % 3600 ))
    m=$(( s / 60 ))
    local out=""
    (( d > 0 )) && out+="${d}d "
    (( h > 0 )) && out+="${h}h "
    out+="${m}m"
    printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Network auto-detection (best-effort; used to pre-fill wizard defaults)
# ---------------------------------------------------------------------------

# detect_wan_iface — primary interface toward the internet, fallback eth0.
detect_wan_iface() {
    local dev
    dev="$(ip -o route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
    [[ -n "$dev" ]] || dev="$(ip -o route show default 2>/dev/null | grep -oP 'dev \K\S+' | head -1)"
    printf '%s' "${dev:-eth0}"
}

# detect_local_ip — source IP used for outbound traffic.
detect_local_ip() {
    ip -o route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1
}

# detect_gateway_mac — MAC of the default gateway (needed by Paqet raw socket).
detect_gateway_mac() {
    local gw mac
    gw="$(ip -o route show default 2>/dev/null | grep -oP 'via \K\S+' | head -1)"
    [[ -n "$gw" ]] || return 1
    ping -c1 -W1 "$gw" >/dev/null 2>&1 || true
    mac="$(ip neigh show "$gw" 2>/dev/null | grep -oiP 'lladdr \K[0-9a-f:]{17}' | head -1)"
    printf '%s' "$mac"
}

# gen_secret [LEN] — random alphanumeric secret (default 32 chars).
gen_secret() {
    local len="${1:-32}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# is_elf FILE — true if FILE begins with the ELF magic (a real binary).
is_elf() {
    local f="$1" magic
    [[ -f "$f" ]] || return 1
    magic="$(head -c4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]]
}

# cpu_arch — normalised architecture: amd64|arm64|arm32|unsupported
cpu_arch() {
    case "$(uname -m)" in
        x86_64|amd64)       echo amd64 ;;
        aarch64|arm64)      echo arm64 ;;
        armv7l|armv7|armhf) echo arm32 ;;
        *)                  echo unsupported ;;
    esac
}

# --- TCP MSS clamping for userspace tunnels ---------------------------------
# Userspace tunnels (BackPack, Backhaul, GOST, rathole, frp, Paqet) carry user
# traffic inside an ordinary TCP connection between the two servers. That
# connection is bound by the path MTU, and on a path that both undersizes the
# MTU and drops the ICMP "fragmentation needed" replies — measured to be exactly
# the Iran<->EU case here — full-size segments vanish silently while small ones
# get through. The tunnel therefore looks perfectly healthy (ping fine, control
# connection up, Telegram fine) yet anything that needs sustained large segments
# stalls: pages hang, video buffers a few seconds and stops. Clients on mobile
# escape it because carriers already hand out a smaller MTU.
#
# net.ipv4.tcp_mtu_probing only recovers *after* a connection has stalled, which
# is why the failure shows up as "loads a little, then waits". Clamping the MSS
# up front avoids the stall instead of recovering from it.
#
# GRE is excluded: it clamps per-device in its own driver, where it can account
# for the 24-byte encapsulation overhead.
: "${TM_TUNNEL_MSS:=1360}"

# _tun_mss_port — the port of the tunnel's own inter-server connection. Found
# generically so this stays protocol-agnostic, like the rest of the driver
# contract: every driver names it <PREFIX>_PORT (BP_PORT, BH_PORT, PAQET_PORT).
# The match is deliberately anchored to a single-word prefix so that local-only
# listeners with a longer name — PAQET_SOCKS_PORT — are never picked instead;
# clamping those would put the rule on the wrong port. Keys are sorted so the
# choice cannot vary with bash's hash ordering.
_tun_mss_port() {
    local k
    while read -r k; do
        [[ "$k" =~ ^[A-Z0-9]+_PORT$ ]] || continue
        if [[ "${TUN[$k]}" =~ ^[0-9]+$ ]]; then printf '%s' "${TUN[$k]}"; return 0; fi
    done < <(printf '%s\n' "${!TUN[@]}" | sort)
    return 1
}

# tun_mss_apply / tun_mss_revert — add/remove the clamp for the loaded tunnel.
# Two rules cover both roles without needing to know which this server is: our
# SYN when we dial out (client) and our SYN-ACK when we accept (server). Scoping
# to the tunnel's own port keeps every other service on the box untouched.
tun_mss_apply() {
    if [[ "${TUN[PROTOCOL]:-}" == gre ]]; then return 0; fi
    if ! have iptables; then return 0; fi
    local port dir
    port="$(_tun_mss_port)" || return 0
    for dir in --dport --sport; do
        iptables -t mangle -C OUTPUT -p tcp "$dir" "$port" --tcp-flags SYN,RST SYN \
            -j TCPMSS --set-mss "$TM_TUNNEL_MSS" 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp "$dir" "$port" --tcp-flags SYN,RST SYN \
            -j TCPMSS --set-mss "$TM_TUNNEL_MSS" 2>/dev/null || true
    done
    return 0
}

tun_mss_revert() {
    if [[ "${TUN[PROTOCOL]:-}" == gre ]]; then return 0; fi
    if ! have iptables; then return 0; fi
    local port dir
    port="$(_tun_mss_port)" || return 0
    for dir in --dport --sport; do
        while iptables -t mangle -C OUTPUT -p tcp "$dir" "$port" --tcp-flags SYN,RST SYN \
                -j TCPMSS --set-mss "$TM_TUNNEL_MSS" 2>/dev/null; do
            iptables -t mangle -D OUTPUT -p tcp "$dir" "$port" --tcp-flags SYN,RST SYN \
                -j TCPMSS --set-mss "$TM_TUNNEL_MSS" 2>/dev/null || break
        done
    done
    return 0
}
