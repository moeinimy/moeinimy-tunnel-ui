#!/usr/bin/env bash
# pathtest — how fast is the raw link between these two boxes, with nothing of
# ours in the way.
#
# A tunnel carrying 20 Mbit/s is broken if the link does 200 and perfect if the
# link does 20: same reading, opposite conclusions. Everything else was tuned
# without this number.
#
# Preferred, needs no second service and no firewall change:
#   on the IRAN box:   pathtest.sh ssh root@<foreign-ip>
#
# Or a plain socket, if ssh between them is not set up:
#   on the FOREIGN box:  pathtest.sh serve [port]
#   on the IRAN box:     pathtest.sh test <foreign-ip> [port]
set -uo pipefail
MODE="${1:-}"
MB="${MB:-300}"

link_speed() {
    for i in /sys/class/net/*/speed; do
        d="$(basename "$(dirname "$i")")"
        case "$d" in lo|docker*|veth*|tun*|wg*|gre*|erspan*) continue ;; esac
        s="$(cat "$i" 2>/dev/null)"
        [[ -n "$s" && "$s" != "-1" ]] && printf '  %-8s reports %s Mbit/s\n' "$d" "$s"
    done
    echo "  (that is the card, not the plan behind it — the transfer below is the truth)"
}

report() { # report BYTES SECONDS
    awk -v b="$1" -v t="$2" 'BEGIN{
        if (t <= 0) { print "  no time elapsed — nothing transferred"; exit }
        printf "\n  RAW LINK: %.2f MB/s  =  %.1f Mbit/s   (%d MB in %.1fs)\n", b/1048576/t, b*8/t/1e6, b/1048576, t
    }'
}

have() { command -v "$1" >/dev/null 2>&1; }

case "$MODE" in
  ssh)
    HOST="${2:-}"
    [[ -n "$HOST" ]] || { echo "usage: $0 ssh root@<foreign-ip>"; exit 1; }
    have ssh || { echo "ssh not installed here"; exit 1; }
    echo "link the NIC claims:"; link_speed
    echo
    echo "pulling ${MB} MB from $HOST over ssh, no tunnel in the path…"
    echo "(ssh encrypts, so this reads slightly LOW — a floor for the link, never a ceiling)"
    t0=$(date +%s.%N)
    bytes="$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new \
        "$HOST" "dd if=/dev/zero bs=1M count=$MB 2>/dev/null" 2>/dev/null | wc -c)"
    rc=$?
    t1=$(date +%s.%N)
    if [[ "${bytes:-0}" -lt 1048576 ]]; then
        echo
        echo "  FAILED — only ${bytes:-0} bytes arrived (ssh exit $rc)."
        echo "  Most likely: no key-based login to $HOST from here. Test it with:"
        echo "      ssh -o BatchMode=yes $HOST true"
        echo "  If that prompts for a password, set up a key or use the serve/test mode instead."
        exit 1
    fi
    report "$bytes" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
    ;;

  serve)
    PORT="${2:-5201}"
    have nc || { echo "nc not installed — apt-get install -y netcat-openbsd, or use: $0 ssh root@<ip>"; exit 1; }
    echo "link the NIC claims:"; link_speed
    echo
    echo "serving on $PORT. Leave this running; start the client on the other box."
    echo "If the client hangs, this port is blocked by a firewall between them."
    while :; do
        if nc -h 2>&1 | grep -q -- '-p port'; then
            dd if=/dev/zero bs=1M count="$MB" 2>/dev/null | nc -l -p "$PORT" >/dev/null 2>&1
        else
            dd if=/dev/zero bs=1M count="$MB" 2>/dev/null | nc -l "$PORT" >/dev/null 2>&1
        fi
        echo "  … served one run at $(date +%H:%M:%S) — re-listening"
    done
    ;;

  test)
    HOST="${2:-}"; PORT="${3:-5201}"
    [[ -n "$HOST" ]] || { echo "usage: $0 test <foreign-ip> [port]"; exit 1; }
    have nc || { echo "nc not installed — apt-get install -y netcat-openbsd, or use: $0 ssh root@$HOST"; exit 1; }
    echo "link the NIC claims:"; link_speed
    echo
    # No separate reachability probe. The previous version opened a connection just
    # to check the port, and the server answers ONE connection per run — so the probe
    # ate the transfer and the real attempt landed in the gap before the next listen.
    # It reported "yes" and then zero bytes, which is a tool inventing its own
    # failure. The transfer proves reachability by arriving; that is the whole test.
    echo "pulling ${MB} MB with no tunnel in the path…"
    t0=$(date +%s.%N)
    bytes="$(timeout 180 nc "$HOST" "$PORT" 2>/dev/null | wc -c)"
    t1=$(date +%s.%N)
    if [[ "${bytes:-0}" -lt 1048576 ]]; then
        echo
        echo "  FAILED — only ${bytes:-0} bytes arrived."
        echo
        echo "  Check, in this order:"
        echo "    1. 'pathtest.sh serve' is running on $HOST RIGHT NOW. It serves one"
        echo "       connection per run, so start it fresh and run this immediately."
        echo "    2. The port is open to this box:"
        echo "         ufw allow from $(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}') to any port $PORT proto tcp"
        echo "    3. netcat is the same flavour on both ends; if serve logs errors,"
        echo "       install netcat-openbsd on both."
        exit 1
    fi
    report "$bytes" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
    ;;

  *)
    echo "usage:"
    echo "  on the IRAN box (easiest, no setup):  $0 ssh root@<foreign-ip>"
    echo "  or, plain socket:"
    echo "    on the FOREIGN box:  $0 serve [port]"
    echo "    on the IRAN box:     $0 test <foreign-ip> [port]"
    exit 1 ;;
esac
