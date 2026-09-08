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

printf 'tunwatch: %s, port %s, every %ss\n\n' "$SIDE" "$PORT" "$INT"
printf '%-8s %10s %10s %9s %8s\n' "time" "sent" "recvd" "retrans" "socks"

read -r ps pr pg pn <<<"$(sample)"
i=0
while :; do
    sleep "$INT"
    read -r cs cr cg cn <<<"$(sample)"
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
