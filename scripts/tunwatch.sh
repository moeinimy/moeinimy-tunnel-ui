#!/usr/bin/env bash
# tunwatch — what the tunnel is doing RIGHT NOW, sampled, not since boot.
#
# Every retransmit figure in this investigation was cumulative: bytes_retrans over
# a connection's whole life. That answers "has this connection ever had a bad
# time", which is not the question. A link that was saturated an hour ago and is
# fine now reads exactly the same as one that is failing this second, and a fix
# cannot show up at all until it outweighs all the damage before it.
#
# So: deltas between two samples. Throughput and loss for the interval just past.
#
# usage: tunwatch.sh [interval_seconds] [count]   (default: 10s, forever)
set -uo pipefail
PORT="${TUNPORT:-3080}"
INT="${1:-10}"
MAX="${2:-0}"

# --all: every tunnel on this box, side by side, in the same intervals.
#
# This is the measurement that answers "is it Iran, or is it this route". One box,
# one ISP, one moment, one kernel — the only thing that differs between the rows is
# which foreign endpoint the tunnel reaches. Two tunnels from the same Iranian
# server, one dropping its control channel 26 times a day and the other zero times,
# is not a claim that needs arguing about: it is a controlled experiment that is
# already running, and nobody had read it side by side.
if [[ "${1:-}" == "--all" ]]; then
    INT="${2:-10}"; MAX="${3:-0}"
    declare -A TPORT
    for f in /etc/tunnel-manager/*/*.toml; do
        [[ -f "$f" ]] || continue
        nm="$(basename "$f" .toml)"
        pt="$(grep -hoE '(bind_addr|remote_addr)[[:space:]]*=[[:space:]]*"[^"]*"' "$f" 2>/dev/null               | grep -oE ':[0-9]+"' | tr -d ':"' | head -1)"
        [[ -n "$pt" ]] && TPORT[$nm]="$pt"
    done
    [[ ${#TPORT[@]} -gt 0 ]] || { echo "no tunnel configs found under /etc/tunnel-manager"; exit 1; }

    echo "tunnels found:"
    for nm in "${!TPORT[@]}"; do
        printf '  %-10s port %-6s %s' "$nm" "${TPORT[$nm]}" "$(systemctl is-active "tm-tunnel-$nm.service" 2>/dev/null || echo unknown)"
        echo
    done
    echo

    snap() { # snap PORT -> "sent retrans recvd socks"
        ss -tin state established "( sport = :$1 or dport = :$1 )" 2>/dev/null | awk '
          /bytes_sent:/ { sv=0;rv=0;av=0
            for(i=1;i<=NF;i++){ if($i~/^bytes_sent:/){split($i,a,":");sv=a[2]}
                                if($i~/^bytes_retrans:/){split($i,a,":");rv=a[2]}
                                if($i~/^bytes_received:/){split($i,a,":");av=a[2]} }
            s+=sv;r+=rv;g+=av;n++ }
          END{ printf "%d %d %d %d", s+0,r+0,g+0,n+0 }'
    }

    declare -A PS PR PG
    for nm in "${!TPORT[@]}"; do read -r a b c d <<<"$(snap "${TPORT[$nm]}")"; PS[$nm]=$a; PR[$nm]=$b; PG[$nm]=$c; done
    printf '%-8s %-10s %11s %11s %9s %7s\n' time tunnel sent recvd retrans socks
    i=0
    while :; do
        sleep "$INT"
        for nm in "${!TPORT[@]}"; do
            read -r cs cr cg cn <<<"$(snap "${TPORT[$nm]}")"
            ds=$((cs-${PS[$nm]})); dr=$((cr-${PR[$nm]})); dg=$((cg-${PG[$nm]}))
            if (( cn == 0 )); then
                printf '%-8s %-10s %11s %11s %9s %7d   <- nothing connected\n' "$(date +%H:%M:%S)" "$nm" "—" "—" "—" 0
            elif (( ds < 0 || dr < 0 )); then
                printf '%-8s %-10s %11s %11s %9s %7d\n' "$(date +%H:%M:%S)" "$nm" "—" "—" "churn" "$cn"
            else
                pct="idle"; (( ds > 0 )) && pct="$(awk -v r="$dr" -v s="$ds" 'BEGIN{printf "%.1f%%",100*r/s}')"
                printf '%-8s %-10s %11s %11s %9s %7d\n' "$(date +%H:%M:%S)" "$nm"                     "$(awk -v b="$ds" -v t="$INT" 'BEGIN{printf "%.2f MB/s",b/t/1048576}')"                     "$(awk -v b="$dg" -v t="$INT" 'BEGIN{printf "%.2f MB/s",b/t/1048576}')" "$pct" "$cn"
            fi
            PS[$nm]=$cs; PR[$nm]=$cr; PG[$nm]=$cg
        done
        echo
        i=$((i+1)); [[ "$MAX" -gt 0 && "$i" -ge "$MAX" ]] && break
    done
    exit 0
fi

# Which side we are decides which end of the socket carries the tunnel port.
if ss -tln 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    FILTER="( sport = :$PORT )"; SIDE="server (this box listens)"
else
    FILTER="( dport = :$PORT )"; SIDE="client (this box dials out)"
fi

sample() {
    ss -tin state established "$FILTER" 2>/dev/null | awk '
      /bytes_sent:/ {
        sv=0; rv=0; av=0
        for (i=1;i<=NF;i++) {
          if ($i ~ /^bytes_sent:/)     { split($i,a,":"); sv=a[2] }
          if ($i ~ /^bytes_retrans:/)  { split($i,a,":"); rv=a[2] }
          if ($i ~ /^bytes_received:/) { split($i,a,":"); av=a[2] }
        }
        s+=sv; r+=rv; g+=av; n++
      }
      END { printf "%d %d %d %d\n", s+0, r+0, g+0, n+0 }'
}

# A tunnel that is DOWN and a tunnel that is IDLE both report zero. Reading three
# minutes of zeroes as "quiet" while the service was stopped is exactly the mistake
# this investigation kept repeating: a measurement that cannot tell you it is
# invalid is worse than no measurement, because it gets believed.
for _svc in $(systemctl list-units --type=service --no-legend 'tm-tunnel-*' 2>/dev/null | awk '{print $1}'); do
    _state="$(systemctl is-active "$_svc" 2>/dev/null)"
    printf '%-34s %s\n' "$_svc" "$_state"
    [[ "$_state" == active ]] || printf '  ^ NOT RUNNING — every zero below is this, not idleness\n'
done

printf 'tunwatch: %s, port %s, every %ss\n\n' "$SIDE" "$PORT" "$INT"
printf '%-8s %10s %10s %9s %8s\n' "time" "sent" "recvd" "retrans" "socks"

read -r ps pr pg pn <<<"$(sample)"
i=0
while :; do
    sleep "$INT"
    read -r cs cr cg cn <<<"$(sample)"
    # Zero sockets is not a quiet link; on a tunnel it means there is no tunnel.
    if (( cn == 0 )); then
        printf '%-8s %10s %10s %9s %8d   <- no tunnel sockets at all\n' "$(date +%H:%M:%S)" "—" "—" "—" 0
        ps=$cs; pr=$cr; pg=$cg; pn=$cn
        i=$((i+1)); [[ "$MAX" -gt 0 && "$i" -ge "$MAX" ]] && break
        continue
    fi
    # Connections come and go, so a counter can go DOWN as sockets close and take
    # their totals with them. A negative delta is not a reading; say so instead of
    # printing a number that looks like one.
    ds=$((cs-ps)); dr=$((cr-pr)); dg=$((cg-pg))
    if (( ds < 0 || dr < 0 )); then
        printf '%-8s %10s %10s %9s %8d\n' "$(date +%H:%M:%S)" "—" "—" "churn" "$cn"
    else
        pct="n/a"; (( ds > 0 )) && pct="$(awk -v r="$dr" -v s="$ds" 'BEGIN{printf "%.1f%%", 100*r/s}')"
        printf '%-8s %10s %10s %9s %8d\n' "$(date +%H:%M:%S)" \
            "$(awk -v b="$ds" -v t="$INT" 'BEGIN{printf "%.2f MB/s", b/t/1048576}')" \
            "$(awk -v b="$dg" -v t="$INT" 'BEGIN{printf "%.2f MB/s", b/t/1048576}')" \
            "$pct" "$cn"
    fi
    ps=$cs; pr=$cr; pg=$cg; pn=$cn
    i=$((i+1)); [[ "$MAX" -gt 0 && "$i" -ge "$MAX" ]] && break
done
