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
    echo "link the NIC claims:"; link_speed
    echo
    # python3 rather than nc. The netcat that ships on these distros comes in
    # flavours that disagree about whether "-l -p PORT" is even legal, and picking
    # the wrong one leaves a listener that accepts and sends nothing — which is
    # indistinguishable from a dead link at the far end, and cost two rounds here.
    # python3 is on both boxes and behaves the same on both.
    if have python3; then
        echo "serving on $PORT (python3). Leave this running."
        python3 - "$PORT" "$MB" <<'PYEOF'
import socket, sys
port, mb = int(sys.argv[1]), int(sys.argv[2])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port)); srv.listen(8)
print("  listening on %d — waiting for the other box" % port, flush=True)
chunk = b"x" * (1 << 20)
while True:
    conn, addr = srv.accept()
    print("  client connected: %s" % (addr,), flush=True)
    try:
        for _ in range(mb):
            conn.sendall(chunk)
        print("  sent %d MB" % mb, flush=True)
    except Exception as e:
        print("  client went away: %s" % e, flush=True)
    finally:
        conn.close()
PYEOF
    else
        echo "python3 not found; falling back to nc"
        have nc || { echo "no python3 and no nc — install one"; exit 1; }
        while :; do dd if=/dev/zero bs=1M count="$MB" 2>/dev/null | nc -l "$PORT" >/dev/null 2>&1; echo "  … served one run"; done
    fi
    ;;

  test)
    HOST="${2:-}"; PORT="${3:-5201}"
    [[ -n "$HOST" ]] || { echo "usage: $0 test <foreign-ip> [port]"; exit 1; }
    echo "link the NIC claims:"; link_speed
    echo
    echo "pulling up to ${MB} MB from ${HOST}:${PORT}, no tunnel in the path…"
    if have python3; then
        python3 - "$HOST" "$PORT" <<'PYEOF'
import socket, sys, time
host, port = sys.argv[1], int(sys.argv[2])
try:
    s = socket.create_connection((host, port), timeout=20)
except Exception as e:
    print("\n  FAILED to connect: %s" % e)
    print("  Is 'pathtest.sh serve' running on that box, and the port open to this one?")
    sys.exit(1)
s.settimeout(30)
t0 = time.time(); n = 0
try:
    while True:
        b = s.recv(1 << 20)
        if not b:
            break
        n += len(b)
except socket.timeout:
    print("  (stalled — reporting what arrived)")
except Exception:
    pass
d = time.time() - t0
if n < (1 << 20) or d <= 0:
    print("\n  FAILED — only %d bytes arrived." % n)
    print("  Start 'pathtest.sh serve' on the other box and run this again.")
    sys.exit(1)
print("\n  RAW LINK: %.2f MB/s  =  %.1f Mbit/s   (%.0f MB in %.1fs)"
      % (n/1048576/d, n*8/d/1e6, n/1048576, d))
PYEOF
    else
        have nc || { echo "no python3 and no nc — install one"; exit 1; }
        t0=$(date +%s.%N); bytes="$(timeout 180 nc "$HOST" "$PORT" 2>/dev/null | wc -c)"; t1=$(date +%s.%N)
        [[ "${bytes:-0}" -lt 1048576 ]] && { echo "  FAILED — only ${bytes:-0} bytes arrived."; exit 1; }
        report "$bytes" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
    fi
    ;;

  *)
    echo "usage:"
    echo "  on the IRAN box (easiest, no setup):  $0 ssh root@<foreign-ip>"
    echo "  or, plain socket:"
    echo "    on the FOREIGN box:  $0 serve [port]"
    echo "    on the IRAN box:     $0 test <foreign-ip> [port]"
    exit 1 ;;
esac
