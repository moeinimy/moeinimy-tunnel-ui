# Session handoff — moeinimy tunnel manager

Continuation notes for a fresh session. Read this first.

## Repo & environment
- **Repo:** https://github.com/moeinimy/tunnel-manager (public). Owner: `moeinimy`.
- **Local working copy:** `D:\claude projects\tunnel-manager` (Windows; use Git Bash / `bash -n` for syntax checks — cannot run Linux tunnel binaries locally).
- **Current version:** 2.0.0 (see `VERSION`).
- **Install on servers:** `bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/tunnel-manager/main/install.sh)`
- **User's test servers:** Iran `188.213.196.205` (client side, runs xray + tunnel clients), foreign `213.182.213.112` (server side, xray on :443). Ubuntu 24 / 22, KVM, amd64.
- **Pushing:** the GitHub push in this project used a PAT the user pasted in chat via an inline credential helper:
  `git -c credential.helper= -c credential.helper='!f(){ echo username=moeinimy; echo "password=$GH_TOKEN"; }; f' push`.
  A new session will NOT have that token — ask the user to provide push access again, or have them push. (Tell them to REVOKE the old PAT — it's exposed in chat history.)

## Reality driver — REMOVED (v3.0.0)
The experimental VLESS+REALITY dokodemo relay was removed after it never completed
the server-to-server handshake on the live test (details below, kept for anyone who
revisits it). All `reality`/`RE_*`/`TM_REALITY_DIR`/xray-core references were pulled
from the drivers, dispatcher, tunnel menu, common.sh, install/uninstall. 8 protocols
remain. Bot gained BUTTON-BASED edit (✏️ Edit → pick field → force-reply value),
`tunnelctl set/names/fields`, and peer-agent control (start/stop/restart/enable/
disable/set/fields/names).

## (history) Reality driver — EXPERIMENTAL (did not complete on the user's live test)
Live-tested v2.3.0/2.3.1 on the servers (xray **26.3.27**). Everything checks out
individually: TCP to foreign:8443 open; keys verified (foreign privkey derives
exactly the client's pubkey); uuid/shortId/SNI/port match; clocks within 17s;
dest www.microsoft.com:443 reachable from foreign (HTTP/2 200); Vision removed to
rule it out. YET the foreign REALITY inbound never logs an `accepted` for the
tunnel connection — Iran logs `in-443 >> reality-out` but the far end silently
drops/redirects. Root cause not found; looks like a server-to-server double-
REALITY relay quirk on xray 26.3.27. Left in the tree as EXPERIMENTAL (spec-
correct, dry-run validated). To revisit: capture a real handshake with
`tcpdump -ni any tcp port 8443 -A` on foreign and check for ClientHello/
ServerHello/reset; try an older xray; try a non-relay direct VLESS+Reality to
isolate the relay layer. The proven TCP carriers remain BackPack (wssmux) + GOST
(mtls) — they already carry the user's Reality payload fine.

## Older (v2.3.0): Reality driver added
Added **VLESS+REALITY+Vision** (`drivers/reality.sh`) on xray-core — the strongest
anti-DPI TCP transport, works where UDP is blocked. Relay via dokodemo-door
(foreign=vless+reality inbound+freedom; iran=dokodemo per port → vless+reality+
vision outbound → foreign 127.0.0.1:target). Server prints a base64 connection
string (uuid|pubkey|shortId|sni|port); client pastes it. JSON dry-run validated
(both roles parse). AWAITING LIVE TEST. If it connects but stalls, try dropping
Vision (empty `flow`) — Vision over dokodemo relay is the one uncertain bit.

## What works (6 protocols tested with the user's real xray; BackPack code-complete, awaiting live test)
GRE, Paqet, Backhaul, Rathole, **GOST (mtls)**, FRP. **BackPack** (added v2.1.0)
was live-tested on the servers — tunnel carries xray over wssmux. From that test:
auto-generated token is now printed, and **bot/peer control was generalised to
all userspace protocols** (v2.1.2): the add flow asks once for the peer's public
IP on any non-GRE server-side tunnel (empty/0.0.0.0 REMOTE_IP), and `edit` offers
"Set peer IP for bot control" to retrofit existing tunnels. Peer agent is then
authorised+firewalled automatically. Plus: colorful menu + scriptable CLI, reversible network optimization (auto-applied on install), per-tunnel systemd persistence, GRE relay-all + port forwards, monitor + auto-recovery with TCP-fallback reachability probe, Telegram bot with **inline buttons + persistent keyboard + `/` command menu**, multi-server **auto-peer** (agent over tunnel; GRE inner IP or public REMOTE_IP), **traffic usage over 1h/12h/24h/7d/30d/all**, backup/restore, self-update, universal protocol-aware **Edit Tunnel** (MTU + all ports + secrets).

## Architecture — how to add a protocol driver
A tunnel profile is loaded into the global assoc array `TUN`. Each protocol is a file `drivers/<name>.sh` implementing this contract, with functions named EXACTLY `<name>_<fn>` (the dispatcher calls `${TUN[PROTOCOL]}_<fn>`):
`<name>_wizard`, `<name>_validate`, `<name>_up`, `<name>_down`, `<name>_render_unit`, `<name>_status`, `<name>_health <NAME>`, `<name>_sample <NAME>` (prints "RX TX").
Helpers may use any prefix. **Registration checklist (grep an existing userspace driver like backhaul):**
1. `drivers/<name>.sh` — model on `drivers/backhaul.sh` (binary download + config + systemd) or `gost.sh` (CLI wrapper).
2. `drivers/driver.sh` → add to `TM_SUPPORTED_PROTOCOLS`.
3. `tunnelctl` → add `drivers/<name>.sh` to the source loop.
4. `modules/tunnel.sh` → add to the `ask_menu proto` list (in `tunnel_add`) and the `tunnel_remove` config-cleanup line.
5. `lib/common.sh` → add `TM_<NAME>_DIR` default + to `ensure_dirs`.
6. `install.sh` → add `drivers/<name>.sh` to the update-mode source loop.
7. `uninstall.sh` → add its source line.
8. If it ships as a `.zip`, ensure `unzip` (already in optional deps).
Test: `bash -n`, then source libs+driver and dry-run `<name>_generate_config`/`render_unit`; validate JSON/TOML.

## Hard-won gotchas (DON'T repeat these)
- **Contract fn naming:** must be `<protocol>_<fn>`. A short prefix (e.g. `ww_render_unit`) makes the dispatcher fail with "does not implement".
- **install.sh `--update`:** after switching `TM_HOME` to `/opt/tunnel-manager`, `unset TM_BIN_DIR` before re-sourcing, else units bake the temp `/tmp/.../bin` path → status=127 on restart. (Already fixed; keep it.)
- **systemd:** never point `WorkingDirectory` at a dir that `ExecStartPre` creates — CHDIR runs first and fails. `cd` inside `ExecStart` via `bash -c` instead.
- **Binary install:** validate ELF magic (`is_elf` in common.sh); handle zip vs tar.gz; pick the ELF file, not README.
- **xray/Reality over a tunnel:** plain `tcp` relay gets DPI-reset (~10s stalls / EOF). Persistent **multiplexed + TLS** transport works (GOST `mtls` is the proven one). **Prefer mux/TLS transports.**
- **Testing:** don't use `python3 -m http.server` on 443/9099 — xray already owns those (`Address already in use`), and even a free port only proves forwarding, not xray compat. Test with the user's REAL xray client pointing at `188.213.196.205:<port>`. Use DEBUG logs where a tool has them.
- **GRE:** inbound to Iran is filtered for ICMP (ping shows 100% loss) but TCP works; keyed GRE dropped, keyless works; use `ip tunnel add mode gre` (not `ip link add type gre`). Monitor uses a TCP reachability probe.
- **WaterWall was removed** (v2.0.0): its node graph established the link but corrupted the byte stream on v1.46.3 even transparent — xray never worked through it. Do not re-add without hands-on binary testing.

## NEXT TASK — add these tunnels (user request)
Read each repo's README + source, watch the linked video if helpful, then add a driver following the checklist above. **Use mux where the tool supports it and it doesn't break the tunnel.** Verify each on the user's servers with their real xray before moving on (one at a time). Per-tunnel optimization applied where each tool supports it.

Evaluation done this session (2026-07-15):
2. **BackPack** — ✅ DONE (driver `drivers/backpack.sh`, v2.1.0). Go/Backhaul
   lineage. Default `wssmux` (confirmed user's wss+mux suggestion is optimal).
   Needs the live xray test on the servers.
1. **Hedioum-Pool-Tunnel** — ❌ SKIPPED (2026-07-16). Source review shows it's a
   **SOCKS5 forward-proxy over a Yamux pool**, not a port-forward: the Iran hub
   only exposes a SOCKS5 port, and the foreign egress dials the SOCKS-requested
   destination on the OPEN internet with an SSRF guard that **blocks loopback/
   private IPs**. It fits "xray/X-UI ON IRAN, exit via foreign" — the OPPOSITE of
   this project's topology (xray Reality inbound on foreign:443, Iran relays a TCP
   port). It cannot relay to the foreign's local xray, so it doesn't fit the
   driver's port-map contract or the real-xray test. User agreed to skip.
3. **Phormal** — ✅ RESOLVED via Hysteria (2026-07-16). Source review showed
   Phormal is a 6.4k-line Bash ORCHESTRATOR, not its own protocol: Bridge=gost,
   Reverse=rathole (both already shipped), Relay=**Hysteria 2** (QUIC) with
   `tcpForwarding`, Echo/Raw=udp2raw/ssh/socat. Rather than port the wrapper, we
   added a native **Hysteria 2 driver** (`drivers/hysteria.sh`, v2.2.0) — the
   valuable QUIC engine, fits the port-forward relay model. Driver verified
   CORRECT on the servers (server listens on UDP, client sends valid QUIC initials,
   secrets match) BUT **the user's foreign provider blocks ALL inbound UDP** —
   tcpdump on foreign shows 0 packets on udp/8443, udp/9099 AND udp/443 while
   Iran is confirmed sending 1288-byte QUIC packets out. So Hysteria cannot work
   on THIS path; it stays in the codebase for any UDP-open foreign server. This
   also means **any UDP-based tunnel is dead on this path** (see packet-tunnel).
4. **packet-tunnel** — Python/Flask panel wrapping **KCP (UDP)**. ❌ Effectively
   DEAD on this user's path: their foreign provider blocks inbound UDP (proven via
   the Hysteria test), so a UDP/KCP tunnel would fail identically. No TLS/mux,
   heavy Python panel. SKIP.
5. **tunnelforge** — SSH tunnels + stunnel + ControlMaster mux. TCP-based so it
   WOULD connect on this path, but SSH transport is a downgrade vs backpack
   (wssmux) / gost (mtls) for high-throughput xray, and the user flagged it as
   "probably not great". RECOMMEND SKIP unless the user specifically wants an SSH
   fallback.

Outcome: BackPack ✅ live-tested (TCP/wssmux carries xray). Hysteria ✅ built,
blocked by provider UDP filtering on this path. Hedioum ❌ wrong topology.
Phormal ✅ resolved (its engines are gost/rathole/Hysteria — all covered).
packet-tunnel ❌ UDP-dead here. tunnelforge ⚠ SSH downgrade. The proven, reliable
performers for this user are the TCP relays: **BackPack (wssmux)** and **GOST
(mtls)**.
