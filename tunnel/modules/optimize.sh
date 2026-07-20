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
net.core.rps_sock_flow_entries
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

# ---------------------------------------------------------------------------
# RPS / RFS — spread packet processing across every core.
#
# Most VPS NICs expose a SINGLE rx queue, so all softirq packet work lands on one
# core. On a busy relay that core saturates while the others sit idle, and packets
# queue behind the CPU rather than behind a qdisc — latency explodes (seen here:
# one core at 74% softirq + 26% steal = 0% idle, ping 90ms -> 800ms, while the
# interface backlog stayed at 0). RPS hashes incoming flows across cores in
# software, which is exactly the fix for a single-queue NIC.
# ---------------------------------------------------------------------------

# _opt_cpu_mask — hex bitmask with one bit per online CPU.
_opt_cpu_mask() {
    local n; n="$(nproc 2>/dev/null || echo 1)"
    printf '%x' $(( (1 << n) - 1 ))
}

optimize_rps_apply() {
    local n mask dev q qcount
    n="$(nproc 2>/dev/null || echo 1)"
    if (( n < 2 )); then
        log_info "Single CPU — RPS not applicable."
        return 0
    fi
    mask="$(_opt_cpu_mask)"
    # Global flow table for RFS (keeps a flow on the core its socket lives on).
    sysctl -qw net.core.rps_sock_flow_entries=32768 2>/dev/null || true
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        qcount=0
        for q in /sys/class/net/"$dev"/queues/rx-*; do [[ -d "$q" ]] && qcount=$((qcount+1)); done
        (( qcount > 0 )) || continue
        for q in /sys/class/net/"$dev"/queues/rx-*; do
            [[ -d "$q" ]] || continue
            printf '%s' "$mask"              >"$q/rps_cpus"     2>/dev/null || true
            printf '%s' "$(( 32768 / qcount ))" >"$q/rps_flow_cnt" 2>/dev/null || true
        done
        # XPS: pick the transmit queue based on the sending core.
        for q in /sys/class/net/"$dev"/queues/tx-*; do
            [[ -d "$q" ]] || continue
            printf '%s' "$mask" >"$q/xps_cpus" 2>/dev/null || true
        done
        log_info "  $dev: RPS/RFS across ${n} cores (mask 0x${mask}, ${qcount} rx queue(s))"
    done < <(_opt_managed_ifaces)
}

optimize_rps_revert() {
    local dev q
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        for q in /sys/class/net/"$dev"/queues/rx-*; do
            [[ -d "$q" ]] || continue
            printf '0' >"$q/rps_cpus"     2>/dev/null || true
            printf '0' >"$q/rps_flow_cnt" 2>/dev/null || true
        done
        for q in /sys/class/net/"$dev"/queues/tx-*; do
            [[ -d "$q" ]] || continue
            printf '0' >"$q/xps_cpus" 2>/dev/null || true
        done
    done < <(_opt_managed_ifaces)
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
#
# cake vs fq_codel: cake manages queues better, but costs noticeably more CPU per
# packet (per-flow hashing + shaping maths). On a CPU-starved forwarder that extra
# cost lands on the very core that is already saturated and makes latency WORSE.
# So prefer cake only on boxes with cores to spare (>=4), and fq_codel — which is
# much cheaper and still proper AQM — on small VPSes. Override with TM_QDISC.
_opt_best_qdisc() {
    local q
    if [[ -n "${TM_QDISC:-}" ]]; then
        _opt_qdisc_ok "$TM_QDISC" && { printf '%s' "$TM_QDISC"; return 0; }
        log_warn "TM_QDISC='$TM_QDISC' not usable on this kernel — auto-selecting."
    fi
    local cores; cores="$(nproc 2>/dev/null || echo 1)"
    if (( cores >= 4 )); then
        for q in cake fq_codel; do
            _opt_qdisc_ok "$q" && { printf '%s' "$q"; return 0; }
        done
    else
        for q in fq_codel cake; do
            _opt_qdisc_ok "$q" && { printf '%s' "$q"; return 0; }
        done
    fi
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
#
# Optional shaping (cake only). An *unlimited* cake can only manage a queue that
# forms on THIS box; if the real bottleneck is upstream (a provider rate limiter,
# or a congested international path) the queue builds there and cake never sees it
# — latency spikes while our backlog reads 0. Shaping slightly BELOW the real
# capacity pulls that queue back onto this box, where cake can control it.
#
#   TM_TUNNEL_SHAPE_MBIT — shape the TUNNEL interfaces only. This is the one to use
#     for an Iran relay: the cross-border tunnel path is the slow leg, while the
#     WAN also carries fast domestic client traffic that must NOT be throttled.
#     Set it on BOTH servers (each shapes its own egress → controls one direction:
#     Iran = users' upload, foreign = users' download).
#   TM_SHAPE_MBIT — shape the WAN itself. Only when the whole uplink is the
#     bottleneck; on a relay this also throttles domestic traffic.
optimize_nic_apply() {
    local qdisc="${1:-fq_codel}" dev shape wan
    wan="$(detect_wan_iface)"
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        ip link set dev "$dev" txqueuelen 1000 2>/dev/null || true
        # Pick the shaping rate that applies to this device, if any.
        shape=""
        if [[ "$dev" == "$wan" ]]; then shape="${TM_SHAPE_MBIT:-}"
        else                            shape="${TM_TUNNEL_SHAPE_MBIT:-}"; fi
        if [[ "$qdisc" == cake && -n "$shape" ]]; then
            if tc qdisc replace dev "$dev" root cake bandwidth "${shape}mbit" 2>/dev/null; then
                log_info "  $dev: cake shaped to ${shape}mbit"; continue
            fi
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

    # Shaping is a HARD CEILING on throughput — worth saying out loud, because it
    # is easy to set it low while chasing latency and then wonder where the speed
    # went. Only useful when the bottleneck queue is upstream of this box.
    if [[ -n "${TM_TUNNEL_SHAPE_MBIT:-}${TM_SHAPE_MBIT:-}" ]]; then
        log_warn "Shaping is ON — throughput is capped at ${TM_TUNNEL_SHAPE_MBIT:-${TM_SHAPE_MBIT}} mbit."
        log_warn "  Remove TM_TUNNEL_SHAPE_MBIT / TM_SHAPE_MBIT from $TM_SETTINGS_FILE to uncap."
    fi
    if [[ "$cc" == bbr ]]; then
        log_ok "Congestion control: BBR — the right choice on a lossy path (it does"
        log_ok "  not treat packet loss as congestion the way CUBIC does)."
    fi

    optimize_nic_apply "$qdisc"
    # Spread packet processing across cores — on a single-queue NIC this is often
    # the single biggest latency win, far bigger than any sysctl.
    optimize_rps_apply
    touch "$TM_OPT_MARKER"
    log_ok "Optimization applied. Reversible with: tunnelctl optimize revert"
}

optimize_revert() {
    require_root
    optimize_rps_revert
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
    [[ -n "${TM_SHAPE_MBIT:-}" ]]        && ui_kv "Shaping (WAN)"    "${TM_SHAPE_MBIT} mbit  ⚠ CAPS THROUGHPUT"
    [[ -n "${TM_TUNNEL_SHAPE_MBIT:-}" ]] && ui_kv "Shaping (tunnel)" "${TM_TUNNEL_SHAPE_MBIT} mbit  ⚠ CAPS THROUGHPUT"
    [[ -z "${TM_SHAPE_MBIT:-}${TM_TUNNEL_SHAPE_MBIT:-}" ]] && ui_kv "Shaping" "off (uncapped)"
    ui_kv "CPU cores" "$(nproc 2>/dev/null || echo '?')"
    # The live per-interface qdisc + RPS mask are what actually control latency.
    local dev q rps
    while read -r dev; do
        [[ -n "$dev" ]] || continue
        q="$(tc qdisc show dev "$dev" 2>/dev/null | head -1 | awk '{print $2}')"
        rps="$(cat "/sys/class/net/$dev/queues/rx-0/rps_cpus" 2>/dev/null || echo -)"
        ui_kv "  $dev" "qdisc ${q:-?}   rps 0x${rps}   txqueuelen $(cat "/sys/class/net/$dev/tx_queue_len" 2>/dev/null)"
    done < <(_opt_managed_ifaces)
}
