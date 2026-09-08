#!/usr/bin/env bash
# pathtest — how fast is the raw link between these two boxes, with nothing of
# ours in the way.
#
# This is the number every other measurement has been implicitly compared against,
# and it was never taken. A tunnel carrying 20 Mbit/s is a broken tunnel if the
# link does 200, and a perfect one if the link does 20 — the same reading, opposite
# conclusions, and a day was spent tuning without knowing which. No tunnel, no
# panel, no Xray: one TCP stream, straight down the wire.
#
#   on the FOREIGN box:  pathtest.sh serve [port]
#   on the IRAN box:     pathtest.sh test <foreign-ip> [port]
#
# Open the port on the foreign firewall for the Iran IP first, or the test will
# simply hang looking like a dead link.
set -uo pipefail
MODE="${1:-}"
PORT="${3:-${2:-5201}}"
[[ "$MODE" == test ]] && PORT="${3:-5201}"

link_speed() {
    for i in /sys/class/net/*/speed; do
        d="$(basename "$(dirname "$i")")"
        [[ "$d" == lo || "$d" == docker* || "$d" == veth* || "$d" == tun* || "$d" == wg* ]] && continue
        s="$(cat "$i" 2>/dev/null)"
        [[ -n "$s" && "$s" != "-1" ]] && printf '  %-8s reports %s Mbit/s\n' "$d" "$s"
    done
    # A virtual NIC often reports a nominal 1000/10000 that its plan does not honour,
    # so this is a hint about the card, never a measurement of what you actually get.
    echo "  (a NIC's own number is the card, not the plan — the transfer below is the truth)"
}

nc_listen() { # portable across the nc variants that ship on these distros
    if nc -h 2>&1 | grep -q '\-p port'; then nc -l -p "$PORT"; else nc -l "$PORT"; fi
}

case "$MODE" in
  serve)
    echo "link the NIC claims:"; link_speed
    echo
    echo "listening on $PORT — run the client on the other box now (Ctrl-C when done)"
    while :; do
        dd if=/dev/zero bs=1M count=400 2>/dev/null | nc_listen >/dev/null 2>&1
        echo "  … one run served"
    done
    ;;
  test)
    HOST="${2:-}"
    [[ -n "$HOST" ]] || { echo "usage: pathtest.sh test <foreign-ip> [port]"; exit 1; }
    echo "link the NIC claims:"; link_speed
    echo
    echo "pulling 400 MB from $HOST:$PORT with no tunnel in the path…"
    # dd prints the rate itself, measured over the whole transfer.
    nc "$HOST" "$PORT" 2>/dev/null | dd of=/dev/null bs=1M 2>&1 | tail -1
    echo
    echo "compare that with what the tunnel carries (tunwatch --all). If they match,"
    echo "the tunnel is already delivering the whole link and no setting will add more."
    ;;
  *)
    echo "usage:"
    echo "  on the FOREIGN box:  $0 serve [port]"
    echo "  on the IRAN box:     $0 test <foreign-ip> [port]"
    exit 1 ;;
esac
