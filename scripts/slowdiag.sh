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
# The tunnel's listening port. One variable because two places need it and a
# hardcoded copy in each is a copy that drifts; override for a tunnel on another port.
TUNPORT="${TUNPORT:-3080}"
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
ss -tinm state established "( sport = :$TUNPORT or dport = :$TUNPORT )" 2>/dev/null | head -40

# One number for the whole tunnel, because nineteen socket dumps do not answer
# "is it better than last time" and adding them up by hand gets it wrong: a socket
# with no retransmissions omits bytes_retrans entirely, so any pairing of the two
# fields across lines silently misaligns and can report more retransmitted than
# sent. Both values are read from the SAME line, and a missing one counts as zero.
echo
ss -tin state established "( dport = :$TUNPORT or sport = :$TUNPORT )" 2>/dev/null | awk '
  /bytes_sent:/ {
    sv=0; rv=0
    for (i=1;i<=NF;i++) {
      if ($i ~ /^bytes_sent:/)    { split($i,a,":"); sv=a[2] }
      if ($i ~ /^bytes_retrans:/) { split($i,a,":"); rv=a[2] }
    }
    s+=sv; r+=rv; n++; if (rv==0) clean++
  }
  END {
    if (s>0)
      printf "TUNNEL TOTAL: %d sockets, %d of them with zero loss — retransmit %.1f%% (%.1f MB of %.1f MB)\n",
             n, clean, 100*r/s, r/1048576, s/1048576
    else
      print "TUNNEL TOTAL: no established tunnel sockets found"
  }'

s "6. NIC — drops the qdisc cannot fix"
ip -s -br link show 2>/dev/null | head
printf '\nqdisc:\n'; tc -s qdisc show 2>/dev/null | head -20
printf '\nsoftnet (per-CPU: 2nd col = dropped, 3rd = time_squeeze):\n'
cat /proc/net/softnet_stat 2>/dev/null
printf '\nrps per queue:\n'
for f in /sys/class/net/*/queues/rx-*/rps_cpus; do [ -e "$f" ] && printf '%s = %s\n' "$f" "$(cat "$f")"; done

s "7. RAW INTERNET PATH — excludes everything of ours"
# Measured against the TUNNEL PEER first, because that is the path the traffic
# actually takes. This defaulted to a fixed reference box for a long time, which
# meant a report could show a clean path while the link that carries every packet
# was losing a fifth of them — 21% retransmitted in one direction, unexplained
# across three rounds of diagnosis, because nothing here was looking at it.
#
# Discovered from the running tunnel rather than assumed: the client config names
# the server it dials, and failing that the busiest established peer is it.
tunnel_peer() {
    grep -hoE '(remote_addr|server_addr|edge_ip)[[:space:]]*=[[:space:]]*"[^"]+"'         /etc/tunnel-manager/*/*.toml 2>/dev/null         | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -2
    ss -tn state established 2>/dev/null | awk 'NR>1{print $NF}'         | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'         | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}
if command -v mtr >/dev/null; then
    for tgt in $(tunnel_peer | sort -u); do
        echo "--- tunnel peer: $tgt (the path that carries the traffic) ---"
        mtr -rwzbc 30 "$tgt" 2>&1 | tail -22
    done
    echo "--- reference: $PEER (a path of ours that is NOT the tunnel) ---"
    mtr -rwzbc 30 "$PEER" 2>&1 | tail -22
else
    echo "mtr not installed: apt-get install -y mtr-tiny"
fi

s "8. SOCKET AND CONNTRACK TOTALS"
ss -s 2>/dev/null
printf '\nconntrack: count=%s max=%s\n' \
  "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)" \
  "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"

s "9. FIREWALL SIZE — rules are walked per packet"
printf 'filter/nat rule counts:\n'
for t in filter nat mangle; do printf '%-8s %s\n' "$t" "$(iptables -t $t -S 2>/dev/null | wc -l)"; done

s "10. IS THE BUFFER CEILING ACTUALLY APPLIED"
# The fix is only real if the kernel holds it. It has been written correctly and
# then lost at boot twice, to file ordering, so this reads the live value rather
# than any file. Third field should be 4194304.
printf 'tcp_rmem: %s
' "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '	' ' ')"
printf 'tcp_wmem: %s
' "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '	' ' ')"
printf 'tunnel version: %s
' "$(cat /opt/tunnel-manager/VERSION 2>/dev/null || echo '?')"
printf '
Who else sets these:
'
grep -rn 'tcp_rmem\|tcp_wmem' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null

s "10b. THE TUNNEL'S OWN BUFFERS — the layer the kernel ceiling does not cover"
# A driver default only reaches a tunnel when its config is REGENERATED. Updating
# the scripts does not do that, which is how the 3.9.5 smux fix reached no tunnel
# at all and the queue simply moved from the kernel into userspace. So read the
# files the daemons are actually running, not the defaults in the code.
# Want: mux_streambuffer 262144, mux_recievebuffer 2097152 (tunnel >= 3.9.6).
for f in /etc/tunnel-manager/backhaul/*.toml /etc/tunnel-manager/backpack/*.toml; do
  [ -f "$f" ] || continue
  printf -- '--- %s ---\n' "$f"
  grep -E 'mux|transport|connection_pool|channel_size|heartbeat|keepalive' "$f" 2>/dev/null
done

s "11. TUNNEL DROPS — every one of these is a visible outage"
# A closed control channel tears down the whole connection pool at once, so each
# line here is every user through the tunnel being disconnected together. This is
# what "momentary drops" looks like from the relay's side.
for u in $(systemctl list-units --plain --no-legend 'tm-tunnel-*' 2>/dev/null | awk '{print $1}'); do
  printf -- '--- %s ---
' "$u"
  printf 'control-channel closures, last 24h: %s
'     "$(journalctl -u "$u" --since '24 hours ago' --no-pager 2>/dev/null | grep -ci 'control channel has been closed')"
  printf 'client restarts, last 24h:          %s
'     "$(journalctl -u "$u" --since '24 hours ago' --no-pager 2>/dev/null | grep -ci 'restarting client')"
  printf 'most recent:
'
  journalctl -u "$u" --since '24 hours ago' --no-pager 2>/dev/null     | grep -iE 'control channel has been closed|restarting client' | tail -8
done

s "13. LOG FLOOD — CPU spent writing about work instead of doing it"
# Measured on a 2-core relay while slow: systemd-journal 43.8% and rsyslogd 18.8%,
# with 11.8% of the box idle. That is well over half a core describing work, taken
# from the two cores that have to forward the traffic. It is invisible in every
# network reading, because nothing about it is a network problem.
n=$(journalctl --since "60 seconds ago" --no-pager -q 2>/dev/null | wc -l)
echo "journal lines in the last 60s: $n  (~$((n/60))/s)"
echo
echo "What is repeating (5 min, numbers and hex folded so variants group):"
journalctl --since "5 min ago" --no-pager -q 2>/dev/null   | sed -E 's/^[A-Za-z]{3} [0-9 ]{2} [0-9:]{8} [^ ]+ //; s/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/IP/g; s/[0-9a-f:]{6,}:[0-9a-f:]+/IP6/g; s/[0-9]{2,}/N/g; s/[0-9a-f]{8,}/HEX/g'   | sort | uniq -c | sort -rn | head -12
echo
# ForwardToSyslog is what makes rsyslogd process a second copy of everything the
# journal already stored — two daemons, one stream, double the CPU.
echo "journald/rsyslog config:"
grep -hE '^[^#]*(Storage|RateLimit|ForwardToSyslog|MaxLevel|SystemMaxUse)'   /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null | sed 's/^/  /'
echo "  journal on disk: $(journalctl --disk-usage 2>/dev/null | sed 's/^.*take up //')"
echo
# A verbose Xray logs a line per connection. With thousands of connections that is
# the flood, and it is set in the panel's generated config rather than anywhere here.
echo "Xray log level, per panel:"
for c in /opt/vpn-ui/bin/config.json /usr/local/x-ui/bin/config.json; do
  [ -f "$c" ] || continue
  printf '  %s: ' "$c"
  grep -o '"loglevel"[[:space:]]*:[[:space:]]*"[a-z]*"' "$c" | head -1 || echo "(none found)"
done

s "12. KERNEL COMPLAINTS"
dmesg -T 2>/dev/null | tail -25
} 2>&1 | tee "$OUT"

printf '\n\nSaved: %s\n' "$OUT"
