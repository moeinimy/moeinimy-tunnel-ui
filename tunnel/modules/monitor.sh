#!/usr/bin/env bash
# modules/monitor.sh — health monitor + auto-recovery daemon (tm-monitor.service).
#
# Every TM_MONITOR_INTERVAL seconds it: samples per-tunnel counters and rates,
# probes latency/loss, restarts unhealthy tunnels with a bounded retry budget,
# alerts via Telegram, and watches system CPU/RAM/disk.

: "${TM_MONITOR_INTERVAL:=30}"     # seconds between ticks
: "${TM_MONITOR_RETRIES:=3}"       # restart attempts before alerting
: "${TM_CPU_ALERT:=90}"            # percent
: "${TM_RAM_ALERT:=90}"            # percent
: "${TM_DISK_ALERT:=90}"          # percent
: "${TM_ALERT_COOLDOWN:=1800}"     # seconds between repeat system alerts

TM_SYS_STATE="$TM_STATE_DIR/system.state"

monitor_run() {
    log_info "Monitor started (interval ${TM_MONITOR_INTERVAL}s, retries ${TM_MONITOR_RETRIES})."
    while true; do
        monitor_tick || log_warn "monitor tick error (continuing)"
        sleep "$TM_MONITOR_INTERVAL"
    done
}

monitor_tick() {
    local n
    while read -r n; do
        [[ -n "$n" ]] || continue
        monitor_tunnel "$n"
    done < <(list_tunnels)
    monitor_system
}

# monitor_tunnel NAME — one tunnel's sample + health + recovery.
monitor_tunnel() {
    local name="$1"
    load_tunnel "$name" || return 0
    state_load "$name"

    local enabled=no active=no
    svc_is_enabled "$name" && enabled=yes
    svc_is_active  "$name" && active=yes

    # --- counters & rates -------------------------------------------------
    local now rx tx prev_rx prev_tx prev_ts dt rxr=0 txr=0
    now="$(date +%s)"
    read -r rx tx <<<"$(driver_sample "$name")"
    prev_rx="${ST[RX_BYTES]:-0}"; prev_tx="${ST[TX_BYTES]:-0}"; prev_ts="${ST[SAMPLE_TS]:-0}"
    dt=$(( now - prev_ts ))
    if (( prev_ts > 0 && dt > 0 )); then
        (( rx >= prev_rx )) && rxr=$(( (rx - prev_rx) / dt )) || rxr=0
        (( tx >= prev_tx )) && txr=$(( (tx - prev_tx) / dt )) || txr=0
    fi
    ST[RX_BYTES]="$rx"; ST[TX_BYTES]="$tx"; ST[SAMPLE_TS]="$now"
    ST[RX_RATE]="$rxr"; ST[TX_RATE]="$txr"
    (( rxr > ${ST[PEAK_RX_RATE]:-0} )) && ST[PEAK_RX_RATE]="$rxr"
    (( txr > ${ST[PEAK_TX_RATE]:-0} )) && ST[PEAK_TX_RATE]="$txr"

    # Monotonic lifetime totals (survive interface counter resets on restart)
    # feed the historical usage windows (1h/24h/week/month/all).
    local drx=0 dtx=0
    if (( prev_ts > 0 )); then
        (( rx >= prev_rx )) && drx=$(( rx - prev_rx )) || drx=$rx
        (( tx >= prev_tx )) && dtx=$(( tx - prev_tx )) || dtx=$tx
    fi
    ST[ACCUM_RX]=$(( ${ST[ACCUM_RX]:-0} + drx ))
    ST[ACCUM_TX]=$(( ${ST[ACCUM_TX]:-0} + dtx ))
    traffic_record "$name" "$now"

    # --- latency / loss ---------------------------------------------------
    monitor_probe_latency "$name"

    # --- health & recovery ------------------------------------------------
    if [[ "$enabled" == no && "$active" == no ]]; then
        ST[STATUS]="down"; state_save "$name"; return 0   # intentionally off
    fi

    if driver_health "$name"; then
        # Recovered from a previous failure?
        if [[ "${ST[STATUS]:-}" == "down" || "${ST[FAIL_COUNT]:-0}" -gt 0 ]]; then
            log_ok "Tunnel '$name' recovered."
            tg_notify "🟢 Tunnel <b>$name</b> recovered on $(hostname)"
        fi
        ST[STATUS]="up"; ST[FAIL_COUNT]=0; ST[ALERTED]=0
        [[ -z "${ST[STARTED_AT]:-}" ]] && ST[STARTED_AT]="$now"
        state_save "$name"
        return 0
    fi

    # Unhealthy → attempt bounded recovery.
    local fails=$(( ${ST[FAIL_COUNT]:-0} + 1 ))
    ST[FAIL_COUNT]="$fails"; ST[STATUS]="down"; ST[STARTED_AT]=""
    log_warn "Tunnel '$name' unhealthy (attempt $fails/${TM_MONITOR_RETRIES})."
    if (( fails <= TM_MONITOR_RETRIES )); then
        systemctl restart "$(unit_name "$name")" >/dev/null 2>&1 || true
    elif [[ "${ST[ALERTED]:-0}" != 1 ]]; then
        ST[ALERTED]=1
        log_error "Tunnel '$name' still down after ${TM_MONITOR_RETRIES} attempts."
        tg_notify "🔴 Tunnel <b>$name</b> is DOWN on $(hostname) after ${TM_MONITOR_RETRIES} restart attempts."
    fi
    state_save "$name"
}

# traffic_record NAME NOW — append a timestamped totals sample to the tunnel's
# history file (throttled), so usage over arbitrary windows can be computed.
traffic_record() {
    local name="$1" now="$2"
    local interval="${TM_HIST_INTERVAL:-300}"
    (( now - ${ST[HIST_TS]:-0} >= interval )) || return 0
    ST[HIST_TS]="$now"
    local dir="$TM_STATE_DIR/history" hist
    mkdir -p "$dir"; hist="$dir/${name}.hist"
    printf '%s %s %s\n' "$now" "${ST[ACCUM_RX]:-0}" "${ST[ACCUM_TX]:-0}" >>"$hist"
    # Bound growth (~40 days at the default 5-minute cadence).
    local lines; lines="$(wc -l <"$hist" 2>/dev/null || echo 0)"
    if (( lines > 12500 )); then tail -n 12000 "$hist" >"$hist.tmp" && mv -f "$hist.tmp" "$hist"; fi
}

# monitor_probe_latency NAME — record reachability latency/loss into state.
# ICMP is tried first, but many Iran transit paths drop ICMP *inside* GRE while
# passing TCP fine, so we fall back to a TCP round-trip probe. A closed port
# that answers with RST still proves the tunnel carries traffic.
monitor_probe_latency() {
    local name="$1" target dev out
    if [[ "${TUN[PROTOCOL]}" == gre ]]; then
        target="${TUN[INNER_REMOTE]}"; dev="${TUN[IFNAME]}"
    else
        target="${TUN[REMOTE_IP]}"; dev=""
    fi
    [[ -n "$target" && "$target" != 0.0.0.0 ]] || return 0

    # 1) ICMP attempt.
    local -a pcmd=(ping -c2 -W2 -q)
    [[ -n "$dev" && -d "/sys/class/net/$dev" ]] && pcmd+=(-I "$dev")
    out="$("${pcmd[@]}" "$target" 2>/dev/null)" || true
    local loss avg
    loss="$(printf '%s' "$out" | grep -oP '\d+(?=% packet loss)' | head -1)"
    avg="$(printf '%s'  "$out" | grep -oP 'rtt[^=]*= [0-9.]+/\K[0-9.]+' | head -1)"

    if [[ -n "$loss" && "$loss" != 100 ]]; then
        ST[LOSS_PCT]="$loss"; ST[LATENCY_MS]="${avg:-0}"; ST[PROBE]="icmp"
        return 0
    fi

    # 2) ICMP failed/filtered — try a TCP round-trip (the real signal).
    local ms
    if ms="$(tcp_rtt "$target")"; then
        ST[LOSS_PCT]=0; ST[LATENCY_MS]="$ms"; ST[PROBE]="tcp"
    else
        ST[LOSS_PCT]=100; ST[LATENCY_MS]="${avg:-0}"; ST[PROBE]="none"
    fi
}

# tcp_rtt HOST — probe a few ports; print round-trip ms and return 0 if the host
# answers (SYN-ACK or RST) within the timeout. Uses bash /dev/tcp, no extra deps.
tcp_rtt() {
    local host="$1" port rc t0 t1 ms
    for port in 22 80 443 53; do
        t0=$(date +%s%N)
        timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; rc=$?
        t1=$(date +%s%N)
        ms=$(( (t1 - t0) / 1000000 ))
        # rc==0: connected. rc!=0 but fast: connection refused (RST) => reachable.
        # Only a full ~2000ms stall means the packet got no answer at all.
        if [[ $rc -eq 0 ]] || (( ms < 1500 )); then
            printf '%s' "$ms"; return 0
        fi
    done
    return 1
}

# monitor_system — CPU/RAM/disk sampling with cooldown-limited alerts.
monitor_system() {
    local cpu mem disk now
    now="$(date +%s)"
    cpu="$(monitor_cpu_pct)"
    mem="$(free | awk '/^Mem:/{printf "%d", ($2? ($2-$7)*100/$2 : 0)}')"
    disk="$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}')"

    # Persist latest sample for reports.
    {
        printf 'CPU_PCT=%s\n' "$cpu"
        printf 'MEM_PCT=%s\n' "$mem"
        printf 'DISK_PCT=%s\n' "$disk"
        printf 'TS=%s\n' "$now"
    } >"$TM_SYS_STATE"

    monitor_maybe_alert cpu  "$cpu"  "$TM_CPU_ALERT"  "CPU"  "$now"
    monitor_maybe_alert ram  "$mem"  "$TM_RAM_ALERT"  "RAM"  "$now"
    monitor_maybe_alert disk "$disk" "$TM_DISK_ALERT" "Disk" "$now"
}

# monitor_cpu_pct — CPU utilisation from two /proc/stat snapshots stored in state.
monitor_cpu_pct() {
    local cur idle total prev_total prev_idle dtotal didle pct=0
    read -r _ a b c d e f g _ < <(grep '^cpu ' /proc/stat)
    total=$(( a + b + c + d + e + f + g )); idle="$d"
    if [[ -f "$TM_STATE_DIR/cpu.prev" ]]; then
        read -r prev_total prev_idle <"$TM_STATE_DIR/cpu.prev"
        dtotal=$(( total - prev_total )); didle=$(( idle - prev_idle ))
        (( dtotal > 0 )) && pct=$(( (dtotal - didle) * 100 / dtotal ))
    fi
    printf '%s %s\n' "$total" "$idle" >"$TM_STATE_DIR/cpu.prev"
    printf '%d' "$pct"
}

# monitor_maybe_alert KIND VALUE THRESHOLD LABEL NOW
monitor_maybe_alert() {
    local kind="$1" val="$2" thr="$3" label="$4" now="$5"
    [[ "$val" =~ ^[0-9]+$ ]] || return 0
    local marker="$TM_STATE_DIR/alert.$kind"
    if (( val >= thr )); then
        local last=0; [[ -f "$marker" ]] && last="$(cat "$marker" 2>/dev/null || echo 0)"
        if (( now - last >= TM_ALERT_COOLDOWN )); then
            printf '%s' "$now" >"$marker"
            log_warn "High $label usage: ${val}% (threshold ${thr}%)"
            tg_notify "⚠️ High <b>$label</b> usage on $(hostname): <b>${val}%</b>"
        fi
    else
        rm -f "$marker" 2>/dev/null || true
    fi
}
