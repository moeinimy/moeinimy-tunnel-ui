#!/usr/bin/env bash
# modules/optimize.sh — reversible network/kernel tuning for high-throughput
# traffic forwarding.
#
# apply:  back up current sysctl values + NIC settings (once), drop a managed
#         sysctl.d file, enable BBR+fq, raise buffers/queues, tune the WAN NIC.
# revert: restore everything from the saved backups and remove managed files.

TM_SYSCTL_FILE="/etc/sysctl.d/99-tunnel-manager.conf"
TM_MODULES_FILE="/etc/modules-load.d/tunnel-manager.conf"
TM_OPT_BACKUP="$TM_STATE_DIR/optimize.sysctl.bak"
TM_OPT_NIC_BACKUP="$TM_STATE_DIR/optimize.nic.bak"
TM_OPT_MARKER="$TM_STATE_DIR/optimize.applied"

# Keys we manage (kept in one place so backup/restore stay in sync).
_opt_keys() {
    cat <<'EOF'
net.ipv4.ip_forward
net.ipv6.conf.all.forwarding
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.core.rmem_default
net.core.wmem_default
net.core.optmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.udp_rmem_min
net.ipv4.udp_wmem_min
net.core.netdev_max_backlog
net.core.netdev_budget
net.core.somaxconn
net.ipv4.tcp_max_syn_backlog
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_fastopen
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.ipv4.tcp_max_tw_buckets
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_window_scaling
net.ipv4.tcp_sack
net.ipv4.tcp_timestamps
net.ipv4.tcp_syncookies
net.ipv4.ip_local_port_range
net.ipv4.conf.all.rp_filter
net.ipv4.conf.default.rp_filter
fs.file-max
vm.swappiness
net.netfilter.nf_conntrack_max
EOF
}

# _opt_bbr_available — does the kernel offer BBR?
_opt_bbr_available() {
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr
}

# _opt_qdisc_ok NAME — is this qdisc usable? (probe on lo, which has no real queue)
_opt_qdisc_ok() {
    have tc || return 1
    modprobe "sch_$1" 2>/dev/null || true
    tc qdisc replace dev lo root "$1" 2>/dev/null || return 1
    tc qdisc del dev lo root 2>/dev/null || true
    return 0
}

# _opt_best_qdisc — the best AQM available for FORWARDED traffic.
#
# Why not plain `fq`: fq is a *pacing* qdisc for locally-generated TCP (it pairs
# with BBR on a server that terminates connections). A tunnel box mostly FORWARDS
# other people's packets — their TCP/congestion control lives on the endpoints, so
# fq applies no active queue management and the bottleneck queue is free to grow.
# That is textbook bufferbloat: fine while idle, but latency explodes under load
# (e.g. 120ms → 1800ms with many users). cake and fq_codel run CoDel on every
# flow, forwarded ones included, keeping queue delay bounded under full load.
_opt_best_qdisc() {
    local q
    for q in cake fq_codel; do
        _opt_qdisc_ok "$q" && { printf '%s' "$q"; return 0; }
    done
    printf 'fq_codel'
}

# _opt_managed_ifaces — the WAN plus any live tunnel interfaces.
_opt_managed_ifaces() {
    local w d
    w="$(detect_wan_iface)"; [[ -n "$w" && -d "/sys/class/net/$w" ]] && printf '%s\n' "$w"
    for d in /sys/class/net/tm*; do [[ -d "$d" ]] && printf '%s\n' "${d##*/}"; done
}

optimize_backup() {
    [[ -f "$TM_OPT_BACKUP" ]] && return 0   # never overwrite the pristine backup
    mkdir -p "$TM_STATE_DIR"
    local k v
    : >"$TM_OPT_BACKUP"
    while read -r k; do
        [[ -n "$k" ]] || continue
        v="$(sysctl -n "$k" 2>/dev/null || echo '__UNSET__')"
        printf '%s\t%s\n' "$k" "$v" >>"$TM_OPT_BACKUP"
    done < <(_opt_keys)
    log_debug "sysctl backup saved to $TM_OPT_BACKUP"
}

# optimize_nic_backup — save current WAN txqueuelen (reversible NIC tuning).
optimize_nic_backup() {
    [[ -f "$TM_OPT_NIC_BACKUP" ]] && return 0
    local wan; wan="$(detect_wan_iface)"
    [[ -n "$wan" && -d "/sys/class/net/$wan" ]] || return 0
    local qlen; qlen="$(cat "/sys/class/net/$wan/tx_queue_len" 2>/dev/null || echo 1000)"
    printf '%s\t%s\n' "$wan" "$qlen" >"$TM_OPT_NIC_BACKUP"
}

# optimize_nic_apply QDISC — keep the device queue short and let the AQM qdisc do
# the work. A long txqueuelen (or maxed NIC rings) just parks packets in a dumb
# FIFO ahead of the qdisc, which is exactly what drives latency up under load.
# Optional shaping: set TM_SHAPE_MBIT in settings.conf to slightly BELOW your real
# uplink (e.g. 95%) and, with cake, the bottleneck queue moves onto this box where
# cake can actually control it — the definitive bufferbloat cure when the provider
# buffers upstream.
optimize_nic_apply() {
    local qdisc="${1:-fq_codel}" dev
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        ip link set dev "$dev" txqueuelen 1000 2>/dev/null || true
        if [[ "$qdisc" == cake && -n "${TM_SHAPE_MBIT:-}" ]]; then
            tc qdisc replace dev "$dev" root cake bandwidth "${TM_SHAPE_MBIT}mbit" 2>/dev/null \
                && log_info "  $dev: cake shaped to ${TM_SHAPE_MBIT}mbit" && continue
        fi
        tc qdisc replace dev "$dev" root "$qdisc" 2>/dev/null \
            && log_debug "  $dev: qdisc $qdisc" || true
    done < <(_opt_managed_ifaces)
}

optimize_nic_revert() {
    # Drop our managed qdiscs first (kernel falls back to its default).
    local dev
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        tc qdisc del dev "$dev" root 2>/dev/null || true
    done < <(_opt_managed_ifaces)
    [[ -f "$TM_OPT_NIC_BACKUP" ]] || return 0
    local wan qlen
    IFS=$'\t' read -r wan qlen <"$TM_OPT_NIC_BACKUP"
    [[ -n "$wan" && -d "/sys/class/net/$wan" ]] && ip link set dev "$wan" txqueuelen "${qlen:-1000}" 2>/dev/null || true
    rm -f "$TM_OPT_NIC_BACKUP"
}

# tm_aqm_ensure — (re)apply the AQM qdisc + sane queue length to the WAN and to
# any live tunnel interface. Called on EVERY tunnel start (any protocol), because
# the queue that hurts is shared: GRE has its own tm* device, while every
# userspace relay (backhaul/backpack/gost/frp/rathole/paqet/hysteria) egresses via
# the WAN. Idempotent and cheap, so it also self-heals a box that was optimized by
# an older version (which left `fq` + a 10000 txqueuelen behind). No-op unless
# optimization is applied, so `optimize revert` stays honoured.
tm_aqm_ensure() {
    [[ -f "$TM_OPT_MARKER" ]] || return 0
    have tc || return 0
    optimize_nic_apply "$(_opt_best_qdisc)"
}

optimize_apply() {
    require_root
    ui_title "Network optimization"
    optimize_backup
    optimize_nic_backup

    # conntrack table can be tiny by default; raise it for many-connection relays.
    modprobe nf_conntrack 2>/dev/null || true

    local cc="cubic" qdisc
    qdisc="$(_opt_best_qdisc)"
    if _opt_bbr_available; then
        cc="bbr"
        printf 'tcp_bbr\n' >"$TM_MODULES_FILE"
        log_info "BBR available — enabling bbr + ${qdisc}."
    else
        log_warn "BBR not available on this kernel — keeping current congestion control."
        cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
    fi
    log_info "Queue discipline: ${qdisc} (active queue management for forwarded traffic)."

    cat >"$TM_SYSCTL_FILE" <<EOF
# Managed by Tunnel Manager — do not edit by hand.
# Remove via: tunnelctl optimize revert

# --- Forwarding ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# --- Congestion control / qdisc ---
net.core.default_qdisc = $qdisc
net.ipv4.tcp_congestion_control = $cc

# --- Socket buffers (64 MiB ceilings) for high-BDP tunnels ---
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 1048576 67108864
net.ipv4.tcp_wmem = 4096 1048576 67108864
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- Queues / backlog / packet processing ---
# Generous but NOT bloated: an oversized backlog is just a latency buffer. The
# AQM qdisc above is what protects throughput; a huge backlog only adds delay.
net.core.netdev_max_backlog = 16384
net.core.netdev_budget = 600
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 8192

# --- TCP behaviour tuned for latency + throughput ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 120
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.ip_local_port_range = 1024 65535

# --- Loose reverse-path filtering (asymmetric tunnel routing) ---
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# --- Limits ---
fs.file-max = 1000000
vm.swappiness = 10
net.netfilter.nf_conntrack_max = 1048576
EOF

    if sysctl -p "$TM_SYSCTL_FILE" >/dev/null 2>&1; then
        log_ok "Applied sysctl tuning (congestion=$cc, qdisc=$qdisc)."
    else
        log_warn "Some sysctl keys were rejected by this kernel (applied the rest)."
    fi

    optimize_nic_apply "$qdisc"
    touch "$TM_OPT_MARKER"
    log_ok "Optimization applied. Reversible with: tunnelctl optimize revert"
}

optimize_revert() {
    require_root
    optimize_nic_revert
    if [[ ! -f "$TM_OPT_BACKUP" ]]; then
        log_warn "No optimization backup found; nothing to revert."
        rm -f "$TM_SYSCTL_FILE" "$TM_MODULES_FILE" "$TM_OPT_MARKER"
        return 0
    fi
    rm -f "$TM_SYSCTL_FILE" "$TM_MODULES_FILE"
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -n "$k" ]] || continue
        [[ "$v" == "__UNSET__" ]] && continue
        sysctl -w "$k=$v" >/dev/null 2>&1 || true
    done <"$TM_OPT_BACKUP"
    sysctl --system >/dev/null 2>&1 || true
    rm -f "$TM_OPT_BACKUP" "$TM_OPT_MARKER"
    log_ok "Reverted network optimization to original values."
}

optimize_status() {
    ui_title "Optimization status"
    if [[ -f "$TM_OPT_MARKER" ]]; then
        ui_kv "State" "$(status_dot up) applied"
    else
        ui_kv "State" "$(status_dot down) not applied"
    fi
    ui_kv "Congestion" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    ui_kv "Qdisc (default)" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    ui_kv "ip_forward" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    ui_kv "rmem_max"   "$(sysctl -n net.core.rmem_max 2>/dev/null)"
    ui_kv "backlog"    "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)"
    ui_kv "conntrack"  "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
    [[ -n "${TM_SHAPE_MBIT:-}" ]] && ui_kv "Shaping" "${TM_SHAPE_MBIT} mbit (cake)"
    # The live per-interface qdisc is what actually controls latency under load.
    local dev q
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        q="$(tc qdisc show dev "$dev" 2>/dev/null | head -1 | awk '{print $2}')"
        ui_kv "  $dev" "qdisc ${q:-?}   txqueuelen $(cat "/sys/class/net/$dev/tx_queue_len" 2>/dev/null)"
    done < <(_opt_managed_ifaces)
}
