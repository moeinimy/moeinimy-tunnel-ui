#!/usr/bin/env bash
# Bootstrap past a throttled GitHub: find a mirror that actually delivers, install
# through it, and record the working ones for future updates.
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

REPO="${TM_REPO:-moeinimy/moeinimy-tunnel-ui}"
URL="https://github.com/${REPO}/archive/refs/heads/main.tar.gz"
CONF=/etc/tunnel-manager/settings.conf
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Candidates are tried in order. Nothing is assumed to work: each is measured on
# THIS box, because which of these is reachable from a given network on a given
# day is not something that can be known from anywhere else.
CANDIDATES=(
  ""                                  # direct, in case it is fine now
  "https://gh-proxy.com/"
  "https://ghfast.top/"
  "https://ghproxy.net/"
  "https://github.moeyy.xyz/"
)

WORKING=()
echo "Testing mirrors (2 MB sample each, 25s budget)…"
for p in "${CANDIDATES[@]}"; do
  label="${p:-direct}"
  t0=$(date +%s%N)
  # A ranged sample rather than the whole archive: enough to measure throughput
  # without spending four minutes per candidate to find out one is dead.
  if curl -fsL --connect-timeout 8 --max-time 25 -r 0-2000000 \
       -o "$TMP/sample" "${p}${URL}" 2>/dev/null && [[ -s "$TMP/sample" ]]; then
    sz=$(stat -c%s "$TMP/sample")
    ms=$(( ($(date +%s%N) - t0) / 1000000 )); [[ $ms -lt 1 ]] && ms=1
    kbs=$(( sz / ms ))
    printf '  %-28s %6s KB in %5s ms  = %s KB/s\n' "$label" "$((sz/1024))" "$ms" "$kbs"
    [[ $kbs -ge 20 ]] && WORKING+=("$p")
  else
    printf '  %-28s unreachable\n' "$label"
  fi
done

[[ ${#WORKING[@]} -gt 0 ]] || { echo "No mirror delivered. Nothing changed."; exit 1; }
echo "Usable: ${WORKING[*]:-direct}"

# Install through the first one that worked.
BEST="${WORKING[0]}"
echo "Downloading via ${BEST:-direct} …"
curl -fL --connect-timeout 15 --speed-limit 2048 --speed-time 60 --retry 3 \
     -o "$TMP/src.tar.gz" "${BEST}${URL}" || { echo "download failed"; exit 1; }
tar -xzf "$TMP/src.tar.gz" -C "$TMP" || { echo "extract failed"; exit 1; }
ROOT="$(find "$TMP" -maxdepth 1 -type d -name '*-main' | head -1)"
SRC="$ROOT/tunnel"; [[ -f "$SRC/install.sh" ]] || SRC="$ROOT"
[[ -f "$SRC/tunnelctl" ]] || { echo "archive has no tunnelctl"; exit 1; }

# Record the mirrors BEFORE installing, so the new code picks them up from here on
# and this whole dance is never needed again.
mkdir -p "$(dirname "$CONF")"; touch "$CONF"
sed -i '/^TM_DOWNLOAD_MIRRORS=/d' "$CONF"
printf 'TM_DOWNLOAD_MIRRORS="%s"\n' "$(printf '%s ' "${WORKING[@]}" | sed 's/ *$//')" >> "$CONF"
echo "Recorded in $CONF:"; grep '^TM_DOWNLOAD_MIRRORS=' "$CONF"

bash "$SRC/install.sh" --update
