# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project follows
[Semantic Versioning](https://semver.org/).


## [3.0.0] - 2026-07-16

### Added
- **Full remote control of the Iran side from the foreign Telegram bot.** Every
  tunnel already auto-registers its remote as a controllable peer on creation
  (no extra step); the bot now exposes real control, not just read-only:
  - **Per-tunnel button menus** for local tunnels (🚇 Tunnels → pick → Restart /
    Start / Stop / Enable / Disable / Logs) and the same for **remote** tunnels
    (🌐 Peers → pick a server → Manage tunnels → per-tunnel actions).
  - **Button-based edit:** the per-tunnel menu has an **✏️ Edit** button → pick a
    field → the bot asks for the new value (force-reply) → you reply and it
    applies + restarts. Works for local tunnels and for **remote** (peer) tunnels
    the same way. Typed `/set` and `/peer … set …` remain as power-user shortcuts.
- **`tunnelctl set <name> <KEY> <VALUE>`** — non-interactive, scriptable field
  edit (regenerates the protocol config and restarts). **`tunnelctl names`** —
  list tunnel names.
- **Peer agent** allowlist extended from read-only+restart to
  `start/stop/restart/enable/disable/set/names/fields/update` (the source is
  still restricted to the authenticated tunnel peer), so the foreign bot can
  fully manage Iran.
- **⬆️ Update button** in the bot: pulls the latest script from GitHub for this
  server **and every connected Iran peer** (peers first over the agent with a
  longer timeout, then this box detached so its reinstall can restart the bot;
  the bot's own notify confirms when it's back). Also `/update`.

### Removed
- **Reality driver removed.** The experimental VLESS+REALITY dokodemo relay never
  completed the server-to-server handshake on the test setup (xray 26.3.27)
  despite correct keys/TCP/clock/dest; dropped to keep the tool to protocols that
  actually work. The proven TCP carriers are **BackPack (wssmux)** and **GOST
  (mtls)**, which already carry a Reality payload end-to-end.

### Notes
- Culmination release: 8 working protocol drivers, automatic bidirectional peer
  control, and a full button-driven Telegram bot (control **and** edit, local +
  remote).

## [2.3.2] - 2026-07-16

### Changed
- **Reality marked EXPERIMENTAL.** Live-tested on xray 26.3.27: TCP open, keys
  verified (foreign privkey derives exactly the client's pubkey),
  uuid/shortId/SNI/port match, clocks within 17s, camouflage dest reachable
  (HTTP/2 200), Vision removed — yet the foreign REALITY inbound never accepts
  the server-to-server relay handshake (Iran logs `in-443 >> reality-out` but the
  far end silently drops/redirects). Root cause unresolved; likely a double-
  REALITY relay quirk on this xray build. Driver kept (spec-correct, dry-run
  validated) but flagged experimental. Proven TCP carriers remain **BackPack
  (wssmux)** and **GOST (mtls)**, which already carry the user's Reality payload.

## [2.3.1] - 2026-07-16

### Changed
- **Reality: dropped XTLS-Vision** from the relay (plain VLESS+Reality). The
  tunnel doesn't need Vision — the user's own Reality payload already carries it
  end-to-end — and it removed one variable while debugging the relay handshake.

## [2.3.0] - 2026-07-16

### Added
- **VLESS + REALITY + Vision driver** (`drivers/reality.sh`) — the strongest
  anti-DPI **TCP** transport available (community-measured ~98% bypass in Iran,
  2026). REALITY makes the tunnel's TLS handshake byte-for-byte identical to a
  real HTTPS site (it borrows a genuine domain's cert/handshake — no self-signed
  cert, no novel fingerprint), and XTLS-Vision flattens the TLS-in-TLS length
  signature. Being TCP, it works even where the foreign provider blocks UDP
  (unlike Hysteria/TUIC).
  - Runs on **xray-core** (auto-downloaded). Real port-forward relay via
    **dokodemo-door**: foreign = VLESS+REALITY inbound + freedom outbound; Iran =
    one dokodemo inbound per user port → VLESS+REALITY+Vision outbound. So xray
    client → iran:<listen> → REALITY tunnel → foreign → 127.0.0.1:<target>.
  - **One-copy key coordination:** the server generates the x25519 keypair, UUID
    and shortId and prints a base64 **connection string**; the client just pastes
    it (uuid|publicKey|shortId|sni|port). Camouflage SNI is configurable
    (default `www.microsoft.com`).
  - Config self-tested with `xray run -test` before start; reuses the shared auto
    peer-control flow. Registered in all dispatch points.

## [2.2.0] - 2026-07-16

### Added
- **Hysteria 2 protocol driver** (`drivers/hysteria.sh`) — github.com/apernet/
  hysteria, a modern **QUIC/UDP** tunnel with TLS-native handshake (looks like
  HTTP/3), **Salamander** packet obfuscation, and **Brutal** congestion control
  that shrugs off packet loss — very effective on Iran's lossy/DPI'd links. This
  is the "Relay" engine the **Phormal** project is built around; added natively
  rather than porting Phormal's 6.4k-line shell orchestrator (whose other engines
  — gost + rathole — this project already ships).
  - Real **TCP (+UDP) port-forward** via Hysteria's `tcpForwarding`/`udpForwarding`
    so it fits the xray-on-foreign relay topology: xray client → iran:<listen> →
    QUIC → foreign → 127.0.0.1:<target> (xray Reality). Foreign = QUIC server,
    Iran = client that dials out.
  - Self-signed RSA-2048 TLS on the server (client uses `tls.insecure`); one
    shared secret used for both `auth` and Salamander obfs (printed on generation).
  - **Optimization:** QUIC receive windows (8 MB stream / 20 MB conn), Brutal CC
    target bandwidth (configurable up/down), `fastOpen`, 30s idle / 10s keepalive.
  - Registered in all dispatch points; reuses the shared auto peer-control flow.

### Note
- **Hedioum-Pool-Tunnel skipped** — source review showed it's a SOCKS5 forward-
  proxy over a Yamux pool with an SSRF guard that blocks loopback/private targets;
  it fits "xray on Iran, exit via foreign", the opposite of this project's relay
  topology, so it cannot carry the foreign's local xray. See docs/HANDOFF.md.

## [2.1.2] - 2026-07-16

### Changed
- **Automatic bot/peer control for ALL userspace protocols** (backhaul, backpack,
  gost, frp, rathole, paqet) — not just BackPack. The generic add flow now asks
  once for the other server's public IP on any non-GRE tunnel whose side doesn't
  already know it (empty or `0.0.0.0` REMOTE_IP). Giving the IP is the only step;
  the peer agent is authorised and firewalled automatically. The BackPack-specific
  prompt added in 2.1.1 was removed in favour of this shared path.
- **Retrofit existing tunnels:** `tunnelctl edit <name>` now offers **"Set peer IP
  for bot control"** for server-side userspace tunnels that lack a peer IP, and
  re-applies the agent firewall on any edit. So already-created tunnels gain
  automatic peer control by just supplying the IP — no remove/re-add needed.

## [2.1.1] - 2026-07-16

### Fixed (BackPack, from first live test on the servers)
- **Auto-generated token is now printed** during the wizard (`Generated token:
  …`) so it can be copied to the other server. Previously a blank-token entry
  produced a secret the user couldn't see.
- **Bot/peer control now works from the server (Iran) side.** The server role
  now optionally collects the other server's public IP (used only to authorise
  and firewall the peer-agent port 8271 — not written into the tunnel config),
  so the Telegram bot on the foreign box can reach the Iran peer instead of
  getting `(peer unreachable)`. Peer control is now symmetric. The same
  server-side gap exists for the other userspace drivers (backhaul/gost/frp/
  rathole) and can be retrofitted the same way.

## [2.1.0] - 2026-07-15

### Added
- **BackPack protocol driver** (`drivers/backpack.sh`) — github.com/AminMGMT/BackPack,
  a Go reverse-tunnel in the Backhaul lineage (`backpack -c <config>.toml`). It
  adds TLS websocket transports on top of the usual set: **tcp / tcpmux / ws /
  wss / wsmux / wssmux** (+ udp). Same server/client model as Backhaul (server
  owns the public port + `ports` map, client dials out).
  - **Default transport `wssmux`** — a persistent, multiplexed, TLS-wrapped
    websocket that looks like ordinary HTTPS. This is the DPI-resistant winner
    for carrying xray/Reality across Iran (plain tcp relays get per-connection
    reset). smux enabled on all `*mux` transports (`mux_version = 2`, 8 conns).
  - **Self-signed TLS** auto-generated for `wss`/`wssmux` on the server side via
    openssl (EC P-256); clients skip verification, matching upstream.
  - **Throughput optimization** applied per BackPack's "Best-Performance" preset:
    `nodelay`, 8 MB socket buffers (`so_rcvbuf`/`so_sndbuf`), connection pool 8,
    tuned smux frame/stream buffers.
  - Optional CDN `edge_ip` override for websocket client transports.
  - Registered in all dispatch points; `openssl` added to optional deps.

## [2.0.0] - 2026-07-11

### Removed
- **WaterWall protocol removed.** Its node graph established the link but
  corrupted the byte stream on v1.46.3 (even transparent), so xray never worked
  through it despite the other six protocols working on the identical path. Not
  worth keeping. Six protocols remain: GRE, Paqet, Backhaul, Rathole, GOST, FRP.

## [1.9.2] - 2026-07-11

### Added
- **Auto-peer for all protocols.** The controllable-peer whitelist now includes
  userspace tunnels (Backhaul/Rathole/GOST/FRP/WaterWall) via the peer's public
  IP, not just GRE inner IPs. The agent firewall is rebuilt (and peers
  registered) automatically whenever a tunnel is added or removed.
- **Universal, protocol-aware Edit Tunnel.** Editing a tunnel now lists that
  protocol's actual fields with current values — MTU, tunnel/control port, user
  port, target port, tokens/passwords, port maps — and regenerates the config +
  restarts on change.

### Changed
- **Rebranded to "moeinimy tunnel manager"** with the version shown in the banner.

## [1.9.0] - 2026-07-11

### Changed
- **WaterWall now uses real encryption (`EncryptionClient/Server`,
  chacha20-poly1305) instead of the XOR obfuscator.** The XOR obfuscator dropped
  connections and plain transparent links get DPI-throttled; a proper encrypted
  link (shared password) masks the tunnel and forwards reliably — the WaterWall
  equivalent of GOST's mtls. Encryption is on by default (password prompted).

## [1.8.3] - 2026-07-11

### Changed
- **WaterWall XOR obfuscation is now optional and OFF by default.** The default
  is a transparent TcpListener→TcpConnector tunnel, which carries xray/Reality
  reliably (Reality already camouflages itself; the XOR obfuscator was dropping
  those connections). Enable XOR only for plain, non-camouflaged traffic.

## [1.8.2] - 2026-07-11

### Fixed
- **Critical: `update` rendered per-tunnel units with the temp extraction path.**
  During `install.sh --update`, `TM_BIN_DIR` kept its value from the temporary
  source tree, so every userspace tunnel's `ExecStart` pointed at
  `/tmp/…/bin/<binary>` and failed (status 127) on the next restart/reboot.
  `TM_BIN_DIR` is now unset and recomputed to `/opt/tunnel-manager/bin`. Re-run
  `tunnelctl update` on each server to repair existing units.

## [1.8.1] - 2026-07-11

### Fixed
- **WaterWall service failed to start (status=200/CHDIR).** systemd applied
  `WorkingDirectory` before `ExecStartPre` could create it, so the service never
  started. Removed `WorkingDirectory`; `ExecStart` now `cd`s into the prepared
  directory itself.

## [1.8.0] - 2026-07-11

### Added
- **WaterWall transport driver (7th protocol).** radkesvat/WaterWall — a C++
  network core configured as a node graph. The driver generates a proven simple
  reverse-tunnel profile (TcpListener → XOR Obfuscator → TcpConnector) that masks
  the stream against DPI. Auto binary download (old-cpu build by default for max
  VPS compatibility), core.json + config.json, systemd with WorkingDirectory.

### Notes
- Seven selectable protocols now ship: **GRE, Paqet, Backhaul, Rathole, GOST,
  FRP, WaterWall.** (ReverseTlsTunnel is merged upstream into WaterWall.)

## [1.7.0] - 2026-07-11

### Added
- **FRP transport driver (6th protocol).** fatedier/frp — a mature reverse proxy.
  Installs both frps/frpc, generates TOML config with `transport.tls.enable`,
  and runs the right binary per role (server=frps on Iran exposing ports,
  client=frpc on foreign mapping them to local services). TLS on by default.

## [1.6.1] - 2026-07-11

### Changed
- **GOST default transport is now `mtls`** (multiplexed TLS) instead of `tcp`.
  Plain `relay+tcp` opens a fresh unencrypted connection per request, which
  Iran's DPI throttles/resets and which breaks latency-sensitive handshakes
  (e.g. xray Reality — seen as ~10s stalls with no response). `mtls`/`mwss` keep
  a persistent multiplexed, HTTPS-looking connection like Backhaul/Rathole do.

## [1.6.0] - 2026-07-11

### Added
- **GOST v3 relay driver (5th protocol).** go-gost/gost — a versatile relay with
  tcp/wss/mwss/grpc transports. Iran side listens locally and forwards ports
  through a relay chain to the foreign side (Iran→foreign). Auto binary download;
  the relay command (with credentials) is rendered into a `0700` wrapper script
  so secrets stay out of the world-readable unit file.

## [1.5.0] - 2026-07-11

### Added
- **Rathole transport driver (4th protocol).** rapiz1/rathole — a lightweight,
  fast Rust reverse tunnel. Auto binary download (zip), TOML config, systemd.
  Service names are derived from the public port so both ends match
  deterministically. Adds `unzip` as a dependency.

## [1.4.0] - 2026-07-11

### Added
- **Backhaul transport driver (3rd protocol).** Musixal/Backhaul — a fast
  Iranian reverse tunnel for NAT/firewall traversal with tcp/tcpmux/ws/wsmux
  transports and multiplexing. Selectable per-tunnel like GRE/Paqet: auto binary
  download, TOML config generation, systemd service. Server side owns the public
  ports + forwarding map; client dials out.

## [1.3.1] - 2026-07-11

### Added
- **Persistent Telegram keyboard** under the chat input + `/` command menu
  (no `/start` needed each time).
### Fixed
- Updates now restart `tm-monitor`/`tm-bot` so new code (traffic accounting, bot
  UI) takes effect immediately — fixes usage showing all zeros after an update.

## [1.3.0] - 2026-07-11

### Added
- **Historical traffic usage over time windows.** The monitor now records
  monotonic per-tunnel totals (surviving interface counter resets) and periodic
  history samples, so you can see data used in the **last 1h / 12h / 24h / 7d /
  30d / all-time**. Available as `tunnelctl usage`, in the menu, and via the
  bot's new **📅 Usage** button / `/usage` command. History is bounded (~40 days)
  and removed with the tunnel.

## [1.2.0] - 2026-07-11

### Added
- **Zero-config multi-server control.** Every server now runs a tiny peer agent
  (systemd socket + handler) that answers a small allowlist of commands
  (`list/status/bandwidth/report/logs/restart`) — but ONLY for requests arriving
  over a tunnel interface from the connected peer's inner IP. No SSH keys, no
  manual `peer add`: as soon as a tunnel is up, the foreign bot/CLI can see and
  control the Iran side automatically. Peers are auto-discovered from tunnels.
  Firewalled to tunnel interfaces (`tm+`) and re-checked per request.

### Changed
- Peer management is now automatic; the old SSH-key-based `peer add` flow is
  removed in favour of the agent. `tunnelctl peer list` / `peer run <tunnel>
  <cmd>` and the bot's 🌐 Peers button use it.

## [1.1.0] - 2026-07-11

### Added
- **Interactive Telegram bot with inline (glass) buttons.** `/menu` opens a
  button panel: Status, System, Bandwidth, Tunnels, Restart (per-tunnel picker),
  Report, Peers, Reboot (with confirm). Buttons and typed commands share one
  handler.
- **Multi-server control (peers).** Register another server (e.g. the Iran box,
  reachable over the tunnel's inner IP) with `tunnelctl peer add`; the foreign
  bot/CLI can then view it — solving the "Iran can't reach Telegram" problem.
  Uses a dedicated SSH key over the private tunnel link.
- **`tunnelctl bandwidth`** — per-tunnel traffic table (current rate, totals),
  also available in the menu and via the bot.
- Telegram `/bandwidth`, `/traffic`, `/peers`, `/menu` commands.

### Improved
- **Network optimization is much more thorough**: ~40 tuned sysctl keys (TCP
  keepalive/timeouts, window scaling, SACK, conntrack table size, local port
  range, swappiness, IPv6 forwarding, netdev budget…) plus reversible NIC tuning
  (tx queue length and NIC ring buffers). All still fully reverted by
  `optimize revert`.

## [1.0.7] - 2026-07-11

### Added
- **Full-relay forwarding mode for GRE.** When adding/editing an Iran-side GRE
  tunnel you can now pick: relay **ALL** ports to the peer (except a protected
  set like SSH), specific ports only, or none. The relay rules (ip_forward,
  DNAT, SNAT, FORWARD) are applied automatically and persist across reboots via
  the tunnel's systemd unit — no more manual iptables.

### Changed
- **Installer now auto-applies network optimization** (reversible) and enables
  IP forwarding, so forwarding tunnels work out of the box. Post-install steps
  reduced to just "Add tunnel". Pass `--no-optimize` to skip.

## [1.0.6] - 2026-07-11

### Fixed
- **Reachability probe no longer reports false 100% loss for GRE.** Many Iran
  transit paths drop ICMP *inside* GRE while carrying TCP normally, so `ping`
  wrongly showed a healthy tunnel as down. The monitor now falls back to a TCP
  round-trip probe (a RST from a closed port still proves connectivity) and
  `status` shows which probe was used (`icmp`/`tcp`).

## [1.0.5] - 2026-07-11

### Changed
- **GRE tunnels are now created with the classic `ip tunnel add ... mode gre`**
  form instead of `ip link add ... type gre`. Both proven Iran tunnel tools
  (vatanhost, Azumi 6TO4-GRE-IPIP-SIT) use the classic form; the newer form
  produced tunnels whose return traffic was dropped on some Iran transit paths.
  Teardown now uses `ip tunnel del` accordingly.

## [1.0.4] - 2026-07-11

### Fixed
- **Paqet client firewall rules were one-directional (server-only).** NOTRACK
  and RST-drop are now applied for both directions of the tunnel port, so the
  client (Iran) side no longer has its raw packets mangled by conntrack/RST.
- **Paqet binary validated by ELF magic** and self-healed if a previous run
  installed a non-binary (fixes `Exec format error` / `status=203/EXEC`).
- **Paqet config now matches the upstream schema exactly**: added `log.level`
  and `network.tcp.local_flag`/`remote_flag`, matching hanselime/paqet examples.

### Changed
- **GRE now defaults to keyless.** Iran's border commonly drops keyed GRE while
  passing plain GREv0; keys are only needed for multiple tunnels between the
  same IP pair.
- GRE health is based on interface UP state, not peer ping, to stop the monitor
  from restart-flapping when the remote peer is temporarily unreachable.

## [1.0.1] - 2026-07-11

### Fixed
- `unbound variable: $1` error when invoking tunnel actions (remove, edit,
  start/stop/restart, enable/disable, status, logs) and restore from the
  interactive menu (functions are called with no argument under `set -u`).
  This also blocked removing tunnels from the menu.

## [1.0.0] - 2026-07-10

### Added
- Unified tunnel manager supporting **GRE** (kernel) and **Paqet** (userspace
  raw-socket KCP) as first-class, per-tunnel selectable protocols.
- Pluggable transport-driver architecture (`drivers/driver.sh` dispatcher).
- Unlimited independent tunnel profiles; automatic `/30` IPAM allocation with
  conflict/duplicate detection; hub, spoke and mesh topologies.
- Persistent per-tunnel `systemd` units (survive reboot) with enable/disable
  auto-start.
- Interactive colorful CLI menu plus a fully scriptable command interface.
- Reversible network optimization (BBR/fq, buffers, forwarding, queues) with a
  saved backup of original sysctl values.
- Health monitor daemon with latency/loss/bandwidth sampling and bounded
  auto-recovery (retry with alerting).
- Optional Telegram integration: notifications + command bot
  (`/status /tunnels /system /bandwidth /report /logs /restart /reboot`).
- Daily/weekly/monthly reports (systemd timer) delivered to Telegram.
- Backup & restore of all configuration, portable across servers.
- One-command installer, self-update from GitHub, and clean uninstall that
  reverts optimization.
- Structured logging with logrotate.
