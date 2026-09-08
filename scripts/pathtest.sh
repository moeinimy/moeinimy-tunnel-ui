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
    have python3 || { echo "python3 not found — install python3"; exit 1; }
    echo "serving on $PORT. Leave this running."
    python3 - "$PORT" <<'PYEOF'
import socket, sys
port = int(sys.argv[1])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("0.0.0.0", port)); srv.listen(8)
print("  listening on %d — waiting for the other box" % port, flush=True)
chunk = b"x" * (1 << 20)
while True:
    conn, addr = srv.accept()
    print("  client connected: %s" % (addr,), flush=True)
    sent = 0
    try:
        # Send until the client has had enough and closes. The client decides when
        # to stop, because it is the one timing the measurement — a fixed byte count
        # here cannot finish at all on a link slow enough to be worth measuring.
        while True:
            conn.sendall(chunk); sent += len(chunk)
    except Exception:
        pass
    finally:
        conn.close()
        print("  client done after %d MB — re-listening" % (sent >> 20), flush=True)
PYEOF
    ;;

  test)
    HOST="${2:-}"; PORT="${3:-5201}"; SECS="${SECS:-15}"
    [[ -n "$HOST" ]] || { echo "usage: $0 test <foreign-ip> [port]"; exit 1; }
    have python3 || { echo "python3 not found — install python3"; exit 1; }
    echo "link the NIC claims:"; link_speed
    echo
    echo "measuring for ${SECS}s against ${HOST}:${PORT}, no tunnel in the path…"
    python3 - "$HOST" "$PORT" "$SECS" <<'PYEOF'
import socket, sys, time
host, port, secs = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
# Timed, not sized. The previous version pulled a fixed 300 MB, which on a link
# slow enough to be the thing under investigation simply never finished and
# reported nothing at all — measuring by volume when volume-per-second is the
# unknown. A fixed window always produces an answer, however slow the link.
try:
    s = socket.create_connection((host, port), timeout=20)
except Exception as e:
    print("\n  FAILED to connect: %s" % e)
    print("  Is 'pathtest.sh serve' running there, and the port open to this box?")
    sys.exit(1)
s.settimeout(5)
t0 = time.time(); n = 0; last = t0; lastn = 0
try:
    while time.time() - t0 < secs:
        b = s.recv(1 << 20)
        if not b:
            break
        n += len(b)
        now = time.time()
        if now - last >= 1.0:
            d = now - last
            print("    %5.1fs  %8.2f MB/s   %7.1f Mbit/s" %
                  (now - t0, (n - lastn) / 1048576 / d, (n - lastn) * 8 / d / 1e6), flush=True)
            last = now; lastn = n
except socket.timeout:
    print("    (no data for 5s — stalled)")
except Exception as e:
    print("    (stopped: %s)" % e)
s.close()
d = time.time() - t0
if n == 0:
    print("\n  FAILED — connected but received nothing.")
    sys.exit(1)
print("\n  RAW LINK over %.1fs: %.2f MB/s = %.1f Mbit/s   (%.1f MB total)"
      % (d, n/1048576/d, n*8/d/1e6, n/1048576))
PYEOF
    ;;
  *)
    echo "usage:"
    echo "  on the IRAN box (easiest, no setup):  $0 ssh root@<foreign-ip>"
    echo "  or, plain socket:"
    echo "    on the FOREIGN box:  $0 serve [port]"
    echo "    on the IRAN box:     $0 test <foreign-ip> [port]"
    exit 1 ;;
esac
