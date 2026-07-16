#!/usr/bin/env bash
# modules/report.sh — daily/weekly/monthly reports (text/HTML), sent to Telegram
# and printed on the CLI.

# report_build PERIOD -> prints an HTML report suitable for Telegram.
report_build() {
    local period="${1:-daily}" out title
    case "$period" in
        weekly)  title="Weekly report" ;;
        monthly) title="Monthly report" ;;
        *)       title="Daily report"; period=daily ;;
    esac

    # System snapshot (from monitor state, with live fallback).
    local cpu mem disk up
    if [[ -f "$TM_SYS_STATE" ]]; then . "$TM_SYS_STATE"; fi
    cpu="${CPU_PCT:-$(monitor_cpu_pct 2>/dev/null || echo 0)}"
    mem="${MEM_PCT:-$(free | awk '/^Mem:/{printf "%d", ($2? ($2-$7)*100/$2:0)}')}"
    disk="${DISK_PCT:-$(df / | awk 'NR==2{gsub(/%/,"",$5);print $5}')}"
    up="$(human_duration "$(cut -d. -f1 /proc/uptime)")"

    out="📊 <b>${title} — $(hostname)</b>\n"
    out+="🗓️ $(date '+%Y-%m-%d %H:%M')\n"
    out+="🖥️ Uptime ${up} | CPU ${cpu}% | RAM ${mem}% | Disk ${disk}%\n"
    out+="────────────────────\n"

    local -a t; mapfile -t t < <(list_tunnels)
    if [[ ${#t[@]} -eq 0 ]]; then
        out+="No tunnels configured.\n"
    else
        local n active
        for n in "${t[@]}"; do
            load_tunnel "$n"; state_load "$n"
            active="🔴"; svc_is_active "$n" && active="🟢"
            out+="${active} <b>${n}</b> (${TUN[PROTOCOL]}/${TUN[ROLE]})\n"
            out+="   ↓ $(human_bytes "${ST[RX_BYTES]:-0}")  ↑ $(human_bytes "${ST[TX_BYTES]:-0}")\n"
            out+="   peak ↓ $(human_bytes "${ST[PEAK_RX_RATE]:-0}")/s ↑ $(human_bytes "${ST[PEAK_TX_RATE]:-0}")/s\n"
            out+="   latency ${ST[LATENCY_MS]:-?}ms  loss ${ST[LOSS_PCT]:-?}%\n"
        done
    fi
    printf '%b' "$out"
}

# report_send PERIOD — build + deliver to Telegram (and log).
report_send() {
    local period="${1:-daily}" body
    body="$(report_build "$period")"
    if tg_enabled; then
        tg_send "$body" && log_ok "Sent $period report to Telegram." || log_warn "Failed to send $period report."
    else
        log_info "$period report generated (Telegram disabled)."
    fi
    # Reset peak counters at the start of each new daily cycle.
    if [[ "$period" == daily ]]; then
        local n
        while read -r n; do
            [[ -n "$n" ]] || continue
            state_set "$n" PEAK_RX_RATE 0 PEAK_TX_RATE 0
        done < <(list_tunnels)
    fi
}

# traffic_window NAME SECONDS -> prints "RX TX" bytes used in the last SECONDS.
# SECONDS may be the literal "all" for lifetime totals.
traffic_window() {
    local name="$1" secs="$2"
    local hist="$TM_STATE_DIR/history/${name}.hist"
    state_load "$name"
    local cur_rx="${ST[ACCUM_RX]:-0}" cur_tx="${ST[ACCUM_TX]:-0}" now
    now="$(date +%s)"
    if [[ "$secs" == all || ! -s "$hist" ]]; then
        printf '%s %s' "$cur_rx" "$cur_tx"; return
    fi
    local cutoff=$(( now - secs )) base_rx base_tx
    read -r base_rx base_tx < <(awk -v c="$cutoff" '
        { if ($1<=c){ brx=$2; btx=$3; f=1 } else if(!s){ frx=$2; ftx=$3; s=1 } }
        END{ if(f) print brx, btx; else print (s?frx:0), (s?ftx:0) }' "$hist")
    printf '%s %s' "$(( cur_rx - ${base_rx:-0} ))" "$(( cur_tx - ${base_tx:-0} ))"
}

# report_usage — per-tunnel traffic used across time windows (HTML for Telegram).
report_usage() {
    local out="📅 <b>Traffic usage — $(hostname)</b>\n" n rx tx
    local -a t; mapfile -t t < <(list_tunnels)
    [[ ${#t[@]} -eq 0 ]] && { printf 'No tunnels.'; return; }
    local -a wins=(3600 43200 86400 604800 2592000 all)
    local -a labs=("1h" "12h" "24h" "7d" "30d" "all")
    for n in "${t[@]}"; do
        out+="\n<b>${n}</b>\n"
        local i
        for i in "${!wins[@]}"; do
            read -r rx tx <<<"$(traffic_window "$n" "${wins[$i]}")"
            out+="  ${labs[$i]}: ↓ $(human_bytes "$rx")  ↑ $(human_bytes "$tx")\n"
        done
    done
    printf '%b' "$out"
}

# report_show PERIOD — print report to the terminal (strip simple HTML tags).
report_show() {
    report_build "${1:-daily}" | sed -e 's/<[^>]*>//g'
    echo
}
