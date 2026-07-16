#!/usr/bin/env bash
# drivers/gre.sh — GRE (kernel) transport driver.
#
# Creates a point-to-point GRE tunnel with a /30 inner subnet, made persistent
# through a oneshot systemd unit (ExecStart -> tunnelctl __up). Optional NAT
# (foreign side) and port-forwarding (either side) are managed idempotently.
#
# Relevant TUN keys:
#   ROLE(iran|foreign) LOCAL_IP REMOTE_IP INNER_LOCAL INNER_REMOTE INNER_CIDR
#   MTU GRE_KEY TTL IFNAME IPAM_INDEX ENABLE_NAT FORWARDS

# gre_ifname NAME -> a <=15 char interface name derived from the tunnel name.
gre_ifname() { printf 'tm%s' "$1" | tr -cd 'a-z0-9' | cut -c1-15; }

# ---------------------------------------------------------------------------
# Interactive wizard (protocol-specific part of "add")
# ---------------------------------------------------------------------------
gre_wizard() {
    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP]  "This server's public IP" is_ipv4 "$def_local"
    ask_valid TUN[REMOTE_IP] "Peer (remote) public IP"  is_ipv4
    ask_valid TUN[MTU]       "Tunnel MTU"               is_mtu 1400

    local idx; idx="$(ipam_alloc "${TUN[NAME]}")"
    TUN[IPAM_INDEX]="$idx"
    TUN[INNER_CIDR]=30
    TUN[TTL]=255
    TUN[IFNAME]="$(gre_ifname "${TUN[NAME]}")"
    # Inner addressing: this host uses its role's side, peer uses the other.
    if [[ "${TUN[ROLE]}" == iran ]]; then
        TUN[INNER_LOCAL]="$(ipam_addr "$idx" iran)"
        TUN[INNER_REMOTE]="$(ipam_addr "$idx" foreign)"
    else
        TUN[INNER_LOCAL]="$(ipam_addr "$idx" foreign)"
        TUN[INNER_REMOTE]="$(ipam_addr "$idx" iran)"
    fi

    # A GRE key allows multiple tunnels between the SAME endpoint pair, but many
    # ISPs (notably Iran's border) drop keyed GRE while passing plain GREv0.
    # Default is therefore keyless; only enable a key if you truly need several
    # tunnels between the same two public IPs.
    local usekey
    ask usekey "Use a GRE key? Only for multiple tunnels between the same IP pair [y/N]" "N"
    if [[ "$usekey" =~ ^([yY]|[yY][eE][sS])$ ]]; then
        ask_valid TUN[GRE_KEY] "GRE key (integer)" is_uint "$(( 1000 + idx ))"
    else
        TUN[GRE_KEY]=""
    fi

    # NAT: on the foreign side, let the Iran peer route its traffic out.
    TUN[ENABLE_NAT]=no
    if [[ "${TUN[ROLE]}" == foreign ]]; then
        if confirm "Enable NAT so the Iran peer can route internet through this server?" no; then
            TUN[ENABLE_NAT]=yes
        fi
    fi

    # Forwarding mode (how real traffic uses the tunnel) — Iran side only.
    TUN[FORWARDS]=""
    TUN[FORWARD_MODE]="none"
    TUN[FORWARD_EXCEPT]="22"
    [[ "${TUN[ROLE]}" == iran ]] && gre_wizard_forward_mode

    ui_kv "Inner network" "$(ipam_network "$idx")/30  (local ${TUN[INNER_LOCAL]} <-> peer ${TUN[INNER_REMOTE]})"
}

# gre_wizard_forward_mode — choose how traffic uses the tunnel (Iran side).
gre_wizard_forward_mode() {
    local fmode
    ask_menu fmode "How should traffic use this tunnel?" \
        "relay ALL ports to peer (full relay)" \
        "specific ports only" \
        "none (just the private link)"
    case "$fmode" in
        relay*)
            TUN[FORWARD_MODE]="all"; TUN[FORWARDS]=""
            ask TUN[FORWARD_EXCEPT] "Ports to keep LOCAL here (comma-sep; keep your SSH port!)" "${TUN[FORWARD_EXCEPT]:-22}" ;;
        specific*)
            TUN[FORWARD_MODE]="ports"; gre_wizard_forwards ;;
        *)  TUN[FORWARD_MODE]="none"; TUN[FORWARDS]="" ;;
    esac
}

# gre_wizard_forwards — collect proto:localport:destport entries into FORWARDS.
gre_wizard_forwards() {
    local list="" proto lp dp more
    while true; do
        ask_menu proto "Protocol for this forward" tcp udp
        ask_valid lp "Local port (on this server)" is_port
        ask_valid dp "Destination port (on peer inner IP ${TUN[INNER_REMOTE]})" is_port "$lp"
        list+="${list:+;}${proto}:${lp}:${dp}"
        confirm "Add another forward?" no || break
    done
    TUN[FORWARDS]="$list"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
gre_validate() {
    is_ipv4 "${TUN[LOCAL_IP]:-}"   || { log_error "invalid LOCAL_IP";  return 1; }
    is_ipv4 "${TUN[REMOTE_IP]:-}"  || { log_error "invalid REMOTE_IP"; return 1; }
    is_mtu  "${TUN[MTU]:-}"        || { log_error "invalid MTU";        return 1; }
    is_ipv4 "${TUN[INNER_LOCAL]:-}"  || { log_error "invalid INNER_LOCAL";  return 1; }
    is_ipv4 "${TUN[INNER_REMOTE]:-}" || { log_error "invalid INNER_REMOTE"; return 1; }
    [[ "${TUN[LOCAL_IP]}" != "${TUN[REMOTE_IP]}" ]] || { log_error "local and remote IP are identical"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Bring up / tear down
# ---------------------------------------------------------------------------
gre_preflight() {
    modprobe ip_gre 2>/dev/null || true
    if ! lsmod 2>/dev/null | grep -q '^ip_gre' && [[ ! -d /sys/module/ip_gre ]]; then
        log_warn "ip_gre kernel module not loaded — GRE may be unavailable on this host (OpenVZ/LXC?)."
    fi
}

gre_up() {
    local dev="${TUN[IFNAME]}"
    gre_preflight
    # Idempotent: remove any prior tunnel/link with this name.
    ip tunnel del "$dev" 2>/dev/null || ip link del "$dev" 2>/dev/null || true
    # Use the classic `ip tunnel add ... mode gre` form. This is what the proven
    # Iran tunnels (vatanhost, Azumi) use; the newer `ip link add type gre`
    # produced tunnels that some Iran transit paths dropped on the return leg.
    local -a add=(ip tunnel add "$dev" mode gre local "${TUN[LOCAL_IP]}" remote "${TUN[REMOTE_IP]}" ttl "${TUN[TTL]:-255}")
    [[ -n "${TUN[GRE_KEY]:-}" ]] && add+=(key "${TUN[GRE_KEY]}")
    "${add[@]}" || { log_error "failed to create GRE tunnel $dev"; return 1; }
    ip link set "$dev" up
    ip addr add "${TUN[INNER_LOCAL]}/${TUN[INNER_CIDR]:-30}" dev "$dev"
    [[ -n "${TUN[MTU]:-}" ]] && ip link set "$dev" mtu "${TUN[MTU]}" 2>/dev/null || true
    gre_rules_up
    log_ok "GRE tunnel '${TUN[NAME]}' up on $dev (${TUN[INNER_LOCAL]} <-> ${TUN[INNER_REMOTE]})"
}

gre_down() {
    local dev="${TUN[IFNAME]}"
    gre_rules_down
    ip link set "$dev" down 2>/dev/null || true
    ip tunnel del "$dev" 2>/dev/null || ip link del "$dev" 2>/dev/null || true
    log_ok "GRE tunnel '${TUN[NAME]}' down"
}

# gre_rules_up — enable forwarding + NAT + port-forwards (all idempotent).
gre_rules_up() {
    local dev="${TUN[IFNAME]}" wan net
    net="$(ipam_network "${TUN[IPAM_INDEX]}")/30"

    if [[ "${TUN[ENABLE_NAT]:-no}" == yes || -n "${TUN[FORWARDS]:-}" \
          || "${TUN[FORWARD_MODE]:-none}" != none ]]; then
        sysctl -qw net.ipv4.ip_forward=1 || true
    fi

    if [[ "${TUN[ENABLE_NAT]:-no}" == yes ]]; then
        wan="$(detect_wan_iface)"
        _ipt_ensure nat POSTROUTING -s "$net" -o "$wan" -j MASQUERADE
        _ipt_ensure filter FORWARD -i "$dev" -o "$wan" -j ACCEPT
        _ipt_ensure filter FORWARD -i "$wan" -o "$dev" -m state --state RELATED,ESTABLISHED -j ACCEPT
    fi

    gre_forwards_apply ensure
    [[ "${TUN[FORWARD_MODE]:-none}" == all ]] && gre_relay_all ensure
    return 0
}

gre_rules_down() {
    local dev="${TUN[IFNAME]}" wan net
    net="$(ipam_network "${TUN[IPAM_INDEX]}")/30"
    wan="$(detect_wan_iface)"
    _ipt_remove nat POSTROUTING -s "$net" -o "$wan" -j MASQUERADE
    _ipt_remove filter FORWARD -i "$dev" -o "$wan" -j ACCEPT
    _ipt_remove filter FORWARD -i "$wan" -o "$dev" -m state --state RELATED,ESTABLISHED -j ACCEPT
    gre_forwards_apply remove
    gre_relay_all remove
    return 0
}

# gre_relay_all ensure|remove — relay ALL client ports arriving on the WAN to
# the peer's inner IP, except a protected set (SSH etc.). Iran-side only.
gre_relay_all() {
    local action="$1" dev="${TUN[IFNAME]}" wan p
    local fn=_ipt_ensure; [[ "$action" == remove ]] && fn=_ipt_remove
    wan="$(detect_wan_iface)"
    # Keep excepted ports (SSH, local panels) on this host — RETURN before DNAT.
    local IFS=','
    for p in ${TUN[FORWARD_EXCEPT]:-22}; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        "$fn" nat PREROUTING -i "$wan" -p tcp --dport "$p" -j RETURN
        "$fn" nat PREROUTING -i "$wan" -p udp --dport "$p" -j RETURN
    done
    unset IFS
    # DNAT everything else arriving on the WAN to the peer inner IP.
    "$fn" nat PREROUTING -i "$wan" -p tcp -j DNAT --to-destination "${TUN[INNER_REMOTE]}"
    "$fn" nat PREROUTING -i "$wan" -p udp -j DNAT --to-destination "${TUN[INNER_REMOTE]}"
    # SNAT so the peer's replies come back through the tunnel.
    "$fn" nat POSTROUTING -o "$dev" -j SNAT --to-source "${TUN[INNER_LOCAL]}"
    # Permit the forwarding both ways.
    "$fn" filter FORWARD -o "$dev" -j ACCEPT
    "$fn" filter FORWARD -i "$dev" -j ACCEPT
}

# gre_forwards_apply ensure|remove — DNAT/SNAT rules for TUN[FORWARDS].
gre_forwards_apply() {
    local action="$1" entry proto lp dp
    [[ -n "${TUN[FORWARDS]:-}" ]] || return 0
    local fn=_ipt_ensure; [[ "$action" == remove ]] && fn=_ipt_remove
    local IFS=';'
    for entry in ${TUN[FORWARDS]}; do
        IFS=':' read -r proto lp dp <<<"$entry"
        [[ -n "$proto" && -n "$lp" && -n "$dp" ]] || continue
        "$fn" nat PREROUTING  -p "$proto" --dport "$lp" -j DNAT --to-destination "${TUN[INNER_REMOTE]}:$dp"
        "$fn" nat POSTROUTING -p "$proto" -d "${TUN[INNER_REMOTE]}" --dport "$dp" -j SNAT --to-source "${TUN[INNER_LOCAL]}"
        "$fn" filter FORWARD  -p "$proto" -d "${TUN[INNER_REMOTE]}" --dport "$dp" -j ACCEPT
    done
}

# _ipt_ensure TABLE CHAIN RULE... — add a rule if not already present.
_ipt_ensure() {
    local table="$1" chain="$2"; shift 2
    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
}
# _ipt_remove TABLE CHAIN RULE... — delete a rule if present (best-effort).
_ipt_remove() {
    local table="$1" chain="$2"; shift 2
    while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || break
    done
}

# ---------------------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------------------
gre_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (GRE)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${TM_CTL} __up ${TUN[NAME]}
ExecStop=${TM_CTL} __down ${TUN[NAME]}

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# Health, counters, status
# ---------------------------------------------------------------------------
# gre_health NAME — 0 if the local tunnel interface exists and is UP.
# We deliberately do NOT ping the peer here: a peer being unreachable does not
# mean the local endpoint is broken, and restarting a healthy interface every
# cycle just causes flapping. Peer reachability is tracked separately as
# latency/loss metrics by the monitor.
gre_health() {
    local dev="${TUN[IFNAME]}" flags
    [[ -d "/sys/class/net/$dev" ]] || return 1
    flags="$(cat "/sys/class/net/$dev/flags" 2>/dev/null || echo 0x0)"
    (( (flags & 0x1) != 0 ))   # IFF_UP
}

# gre_sample NAME — print "RX_BYTES TX_BYTES" from kernel interface counters.
gre_sample() {
    local dev="${TUN[IFNAME]}" rx=0 tx=0
    [[ -r "/sys/class/net/$dev/statistics/rx_bytes" ]] && rx="$(cat "/sys/class/net/$dev/statistics/rx_bytes")"
    [[ -r "/sys/class/net/$dev/statistics/tx_bytes" ]] && tx="$(cat "/sys/class/net/$dev/statistics/tx_bytes")"
    printf '%s %s' "$rx" "$tx"
}

gre_status() {
    local dev="${TUN[IFNAME]}"
    ui_kv "Interface"    "$dev"
    ui_kv "Endpoints"    "${TUN[LOCAL_IP]} -> ${TUN[REMOTE_IP]} (ttl ${TUN[TTL]:-255}${TUN[GRE_KEY]:+, key ${TUN[GRE_KEY]}})"
    ui_kv "Inner"        "${TUN[INNER_LOCAL]} <-> ${TUN[INNER_REMOTE]} /${TUN[INNER_CIDR]:-30}"
    ui_kv "MTU"          "${TUN[MTU]}"
    ui_kv "NAT"          "${TUN[ENABLE_NAT]:-no}"
    case "${TUN[FORWARD_MODE]:-none}" in
        all)   ui_kv "Forwarding" "ALL ports → ${TUN[INNER_REMOTE]} (except: ${TUN[FORWARD_EXCEPT]:-22})" ;;
        ports) ui_kv "Forwarding" "ports: ${TUN[FORWARDS]}" ;;
    esac
    if [[ -d "/sys/class/net/$dev" ]]; then
        local rx tx; read -r rx tx <<<"$(gre_sample "${TUN[NAME]}")"
        ui_kv "Link"     "$(status_dot up) present  RX $(human_bytes "$rx")  TX $(human_bytes "$tx")"
    else
        ui_kv "Link"     "$(status_dot down) absent"
    fi
}
