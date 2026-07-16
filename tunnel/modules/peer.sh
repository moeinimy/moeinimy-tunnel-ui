#!/usr/bin/env bash
# modules/peer.sh — zero-config multi-server control over the tunnel.
#
# Iran boxes usually can't reach api.telegram.org, so the bot runs on the
# foreign server. To let that one bot see/control the Iran side too, every
# server runs a tiny "peer agent" (systemd socket + this handler) that answers
# a small allowlist of tunnelctl commands — but ONLY when the request comes in
# over a tunnel interface, from the connected tunnel peer's inner IP. Because
# the tunnel is a private point-to-point link, no keys or manual setup are
# needed: as soon as a tunnel is up, its remote end is controllable.

TM_AGENT_ALLOW=(list names fields status bandwidth report logs)   # read-only + control below
: "${TM_AGENT_PORT:=8271}"

# _peer_ip — the address to reach a tunnel's remote agent: the private inner IP
# for GRE (stays on the tunnel), or the peer's public IP for userspace tunnels.
_peer_ip() {
    if [[ "${TUN[PROTOCOL]:-}" == gre && -n "${TUN[INNER_REMOTE]:-}" ]]; then
        printf '%s' "${TUN[INNER_REMOTE]}"
    else
        printf '%s' "${TUN[REMOTE_IP]:-}"
    fi
}

# peer_ips_all — every configured peer address (deduplicated), for firewalling.
peer_ips_all() {
    local n ip
    while read -r n; do
        [[ -n "$n" ]] || continue
        load_tunnel "$n" 2>/dev/null || continue
        ip="$(_peer_ip)"
        [[ -n "$ip" && "$ip" != 0.0.0.0 ]] && printf '%s\n' "$ip"
    done < <(list_tunnels) | sort -u
}

# ---------------------------------------------------------------------------
# Server side — invoked per connection by tm-agent@.service (Accept=yes).
# ---------------------------------------------------------------------------
agent_serve() {
    local src="${REMOTE_ADDR:-}" line
    src="${src#::ffff:}"                     # normalise IPv4-mapped IPv6
    read -r line || return 0

    # Authorise: source must be a configured tunnel peer (inner IP for GRE, or
    # the peer's public IP for userspace tunnels).
    local ok=no ip
    while read -r ip; do
        [[ "$ip" == "$src" ]] && { ok=yes; break; }
    done < <(peer_ips_all)
    if [[ "$ok" != yes ]]; then printf 'forbidden (source %s)\n' "$src"; return 0; fi

    # Allowlist the command; arguments are passed to tunnelctl as argv (never
    # shell-evaluated), so there is no injection surface.
    # shellcheck disable=SC2086
    set -- $line
    local cmd="${1:-}"
    # Read-only + tunnel control + non-interactive edit (set). The source is
    # already restricted to the authenticated tunnel peer, so control ops are
    # safe; `set`/edit is intentional so the foreign bot can manage the Iran side.
    case "$cmd" in
        list|names|fields|status|bandwidth|usage|traffic|report|logs|\
        restart|start|stop|enable|disable|set|update)
            NO_COLOR=1 "$TM_CTL" "$@" 2>&1 ;;
        *)  printf 'denied: %s\n' "$cmd" ;;
    esac
}

# agent_firewall ensure|remove — the agent port is reachable only from the
# GRE tunnel interfaces (tm*) and from each configured peer's IP; dropped
# everywhere else. Rebuilt from scratch each call so newly-added peers are
# whitelisted (ACCEPTs inserted before the DROP).
agent_firewall() {
    local action="${1:-ensure}" p ip
    # Always clear our managed rules first.
    while iptables -C INPUT -p tcp --dport "$TM_AGENT_PORT" -i 'tm+' -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$TM_AGENT_PORT" -i 'tm+' -j ACCEPT 2>/dev/null || break; done
    while iptables -C INPUT -p tcp --dport "$TM_AGENT_PORT" -j DROP 2>/dev/null; do
        iptables -D INPUT -p tcp --dport "$TM_AGENT_PORT" -j DROP 2>/dev/null || break; done
    while read -r ip; do
        [[ -n "$ip" ]] || continue
        while iptables -C INPUT -p tcp -s "$ip" --dport "$TM_AGENT_PORT" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp -s "$ip" --dport "$TM_AGENT_PORT" -j ACCEPT 2>/dev/null || break; done
    done < <(peer_ips_all)
    [[ "$action" == remove ]] && return 0

    # Rebuild: peer IPs + tunnel interfaces ACCEPT (inserted on top), then DROP.
    iptables -I INPUT 1 -p tcp --dport "$TM_AGENT_PORT" -i 'tm+' -j ACCEPT
    while read -r ip; do
        [[ -n "$ip" ]] || continue
        iptables -I INPUT 1 -p tcp -s "$ip" --dport "$TM_AGENT_PORT" -j ACCEPT
    done < <(peer_ips_all)
    iptables -A INPUT -p tcp --dport "$TM_AGENT_PORT" -j DROP
}

# ---------------------------------------------------------------------------
# Client side — query a peer over the tunnel.
# ---------------------------------------------------------------------------
# agent_query IP CMD... — send CMD to the agent at IP, print its reply. Override
# the round-trip timeout with TQ_TIMEOUT (seconds) for slow ops like `update`.
agent_query() {
    local ip="$1"; shift
    TQ_IP="$ip" TQ_PORT="$TM_AGENT_PORT" TQ_CMD="$*" timeout "${TQ_TIMEOUT:-8}" bash -c '
        exec 3<>"/dev/tcp/$TQ_IP/$TQ_PORT" || exit 1
        printf "%s\n" "$TQ_CMD" >&3
        cat <&3
    ' 2>/dev/null || { echo "(peer unreachable)"; return 1; }
}

# Peers are auto-derived from tunnels: each tunnel's remote inner IP is a peer.
# peer_list -> lines "tunnelname<TAB>inner_remote"
peer_list() {
    local n ip
    while read -r n; do
        [[ -n "$n" ]] || continue
        load_tunnel "$n" 2>/dev/null || continue
        ip="$(_peer_ip)"
        [[ -n "$ip" && "$ip" != 0.0.0.0 ]] && printf '%s\t%s\n' "$n" "$ip"
    done < <(list_tunnels)
}

# peer_run NAME CMD... — run a command on the peer reached via tunnel NAME.
# NAME may be a tunnel name or a raw peer IP.
peer_run() {
    local name="$1"; shift
    local ip="$name"
    if tunnel_exists "$name"; then load_tunnel "$name"; ip="$(_peer_ip)"; fi
    [[ -n "$ip" ]] || { echo "unknown peer: $name"; return 1; }
    agent_query "$ip" "$@"
}

# peer_overview — list auto-discovered peers and their reachability.
peer_overview() {
    ui_title "Peers (auto-discovered from tunnels)"
    local any=0 name ip
    while IFS=$'\t' read -r name ip; do
        [[ -n "$name" ]] || continue
        any=1
        local reply; reply="$(agent_query "$ip" list 2>/dev/null | head -1)"
        if [[ -n "$reply" && "$reply" != "(peer unreachable)" ]]; then
            ui_kv "$name" "$ip  ($(status_dot up) agent reachable)"
        else
            ui_kv "$name" "$ip  ($(status_dot down) no agent — update the peer to v1.2+)"
        fi
    done < <(peer_list)
    (( any )) || printf '  %sNo tunnels yet — peers appear automatically once a tunnel is up.%s\n' "$C_DIM" "$C_RESET"
}
