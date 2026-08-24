#!/usr/bin/env bash
# slowdiag.sh — one read-only snapshot for the recurring slowdown.
#
# Run it TWICE on each server: once while things are FAST (just after a reboot)
# and once while they are SLOW. The pair is the evidence; a single run on a slow
# box proves nothing, because none of these numbers has a known-good value on
# their own.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/slowdiag.sh) fast
#   bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/moeinimy-tunnel-ui/main/scripts/slowdiag.sh) slow
#
# Writes /root/slowdiag-<label>-<host>-<time>.txt and prints it.
#
# It CHANGES NOTHING. Every command here reads state; none restarts, kills,
# tunes, or writes outside the report file.
set -uo pipefail

LABEL="${1:-unlabelled}"
PEER="${PEER:-212.74.39.212}"   # the second foreign node — a raw-internet reference
OUT="/root/slowdiag-${LABEL}-$(hostname -s)-$(date +%H%M).txt"

s() { printf '\n===== %s =====\n' "$*"; }

{
printf 'slowdiag %s  host=%s  %s\n' "$LABEL" "$(hostname)" "$(date -Is)"
printf 'uptime: %s\n' "$(uptime -p 2>/dev/null)"

s "1. LOAD — is a core saturated, and by what"
# 3 cores means load 3.0 is full. Compare load against nproc, not against 1.
printf 'cores: %s\n' "$(nproc)"
cat /proc/loadavg
top -bn1 | head -12

s "2. THE ACCUMULATION — how much memory, and is it swapping"
# Swap in use at all on a box with this much RAM is the finding. Once the
# tunnel's mux buffers push into swap, everything on the box crawls, and only
# a restart gives it back — which is exactly the reboot-fixes-it symptom.
free -m
printf '\nTop 8 by RSS:\n'
ps -eo rss,pid,ppid,comm --sort=-rss | head -9 | awk '{printf "%8.1f MB  pid=%-7s ppid=%-7s %s\n", $1/1024, $2, $3, $4}'

s "3. DUPLICATE PROCESSES — is the two-panel bug back (suspect a)"
# ppid matters: two cores that are children of two different panels is the bug
# 2.25.43 closed. Two of anything here means it is not closed.
for p in xray vpn-ui backhaul; do
  printf -- '--- %s ---\n' "$p"
  pgrep -a "$p" 2>/dev/null | while read -r pid rest; do
    printf 'pid=%-7s ppid=%-7s %s\n' "$pid" "$(awk '{print $4}' /proc/$pid/stat 2>/dev/null)" "$rest"
  done
  printf 'count: %s\n' "$(pgrep -c "$p" 2>/dev/null || echo 0)"
done

s "4. FILE DESCRIPTORS — the other thing that accumulates"
for p in vpn-ui backhaul xray; do
  for pid in $(pgrep "$p" 2>/dev/null); do
    printf '%-10s pid=%-7s fds=%s threads=%s\n' "$p" "$pid" \
      "$(ls /proc/$pid/fd 2>/dev/null | wc -l)" \
      "$(awk '/^Threads:/{print $2}' /proc/$pid/status 2>/dev/null)"
  done
done

s "5. THE TUNNEL SOCKET — retransmits and window inside our own path"
# retrans on the tunnel's own connections is the TCP-over-TCP story (suspect b).
ss -tinm state established '( sport = :3080 or dport = :3080 )' 2>/dev/null | head -40

s "6. NIC — drops the qdisc cannot fix"
ip -s -br link show 2>/dev/null | head
printf '\nqdisc:\n'; tc -s qdisc show 2>/dev/null | head -20
printf '\nsoftnet (per-CPU: 2nd col = dropped, 3rd = time_squeeze):\n'
cat /proc/net/softnet_stat 2>/dev/null
printf '\nrps per queue:\n'
for f in /sys/class/net/*/queues/rx-*/rps_cpus; do [ -e "$f" ] && printf '%s = %s\n' "$f" "$(cat "$f")"; done

s "7. RAW INTERNET PATH — excludes everything of ours"
# If loss shows up HERE, no amount of panel or tunnel tuning is the answer.
command -v mtr >/dev/null && mtr -rwzbc 30 "$PEER" 2>&1 | tail -25 || echo "mtr not installed: apt-get install -y mtr-tiny"

s "8. SOCKET AND CONNTRACK TOTALS"
ss -s 2>/dev/null
printf '\nconntrack: count=%s max=%s\n' \
  "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)" \
  "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"

s "9. FIREWALL SIZE — rules are walked per packet"
printf 'filter/nat rule counts:\n'
for t in filter nat mangle; do printf '%-8s %s\n' "$t" "$(iptables -t $t -S 2>/dev/null | wc -l)"; done

s "10. KERNEL COMPLAINTS"
dmesg -T 2>/dev/null | tail -25
} 2>&1 | tee "$OUT"

printf '\n\nSaved: %s\n' "$OUT"
