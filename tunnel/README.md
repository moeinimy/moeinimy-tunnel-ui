# Tunnel Manager

**A unified, production-ready manager for high-performance tunnels between Iran
and foreign servers — eight pluggable protocols (kernel GRE plus seven userspace,
DPI-resistant transports) in one clean, modular tool, each chosen per-tunnel.**

Built from the ground up (inspired by, but not copied from,
[`vatanhost/gre`](https://github.com/vatanhost/gre),
[`vatanhost/multi-gre`](https://github.com/vatanhost/multi-gre) and
[`behzadea12/Paqet-Tunnel-Manager`](https://github.com/behzadea12/Paqet-Tunnel-Manager)),
fixing their biggest shared weaknesses: no persistence, no monitoring, no
multi-tunnel data model, and no reversible tuning.

---

## ✨ Features

| Area | What you get |
|------|--------------|
| **Eight protocols** | GRE, Paqet, Backhaul, BackPack, Rathole, GOST, FRP and Hysteria 2 — chosen per-tunnel (see the table below). |
| **Unlimited tunnels** | Independent profiles. One Iran ↔ many foreign, one foreign ↔ many Iran, or full mesh. |
| **Persistent** | Every tunnel is a `systemd` service — survives reboot, with enable/disable auto-start. |
| **Auto IP allocation** | Conflict-free `/30` inner subnets from a pool; duplicate/collision detection. |
| **Interactive menu** | Colorful CLI, plus a fully scriptable command interface. |
| **Reversible tuning** | BBR, fq, buffers, forwarding, queues — with a saved backup and one-command revert. |
| **Monitoring + recovery** | Latency, loss, bandwidth, CPU/RAM/disk; auto-restart with bounded retries and alerts. |
| **Telegram** | Optional notifications **and** a command bot (`/status`, `/restart`, `/report`, …). |
| **Reports** | Daily/weekly/monthly reports delivered to Telegram on a timer. |
| **Backup/Restore** | Portable backup of all config, keys and definitions — restore on another server. |
| **Self-update** | Update from GitHub while preserving all configuration. |

---

## 🔌 Protocols

All are selectable per-tunnel. For carrying **xray/Reality across DPI** over **TCP**
(needed when the foreign provider blocks UDP), the proven multiplexed-TLS
performers are **BackPack (wssmux)** and **GOST (mtls)**. Plain-TCP relays get
DPI-reset, so prefer these.

| Protocol | Layer / transport | Mux / TLS | Best for |
|----------|-------------------|-----------|----------|
| **GRE** | kernel L3 (proto 47) | — | Fastest, lowest overhead; needs `ip_gre` (KVM/dedicated, not OpenVZ/LXC) and GRE allowed. |
| **Paqet** | userspace KCP over raw socket | encrypted | DPI-resistant point-to-point; port-forward or SOCKS5. |
| **Backhaul** | userspace TCP reverse tunnel | tcpmux/wsmux | NAT/firewall traversal, port forwarding. |
| **BackPack** | userspace TCP reverse tunnel | **wss/wssmux + TLS** | ✅ **Top pick for xray over DPI** — persistent multiplexed TLS websocket. |
| **Rathole** | userspace TCP reverse tunnel | TLS/noise | Lightweight, high-performance reverse forwarding. |
| **GOST** | userspace relay | **mtls/mwss/grpc/wss** | ✅ Proven xray carrier (mtls); very versatile relay chains. |
| **FRP** | userspace reverse proxy | tcpmux/TLS | Mature reverse-proxy with many features. |
| **Hysteria 2** | **QUIC / UDP** + TLS + Salamander | Brutal CC | Excellent on lossy links — **but requires the foreign provider to allow inbound UDP.** |

> ⚠️ **Hysteria needs open UDP.** It's QUIC-based; if your foreign provider blocks
> inbound UDP (test with `tcpdump -ni any udp port <port>`), use a TCP transport
> such as BackPack (wssmux) or GOST (mtls) instead.

---

## 🚀 Installation

Ubuntu 20.04+ / Debian 11+ (tested target: **Ubuntu 24.04**). Run as root.

**From a clone (recommended):**
```bash
git clone https://github.com/moeinimy/tunnel-manager.git
cd tunnel-manager
sudo bash install.sh
```

**One-liner** (after you push the repo and set the URL):
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/moeinimy/tunnel-manager/main/install.sh)
```

Then edit `/etc/tunnel-manager/settings.conf` and set `TM_REPO=moeinimy/tunnel-manager`
so updates work.

### 🇮🇷 شروع سریع (فارسی)
```bash
git clone https://github.com/moeinimy/tunnel-manager.git
cd tunnel-manager && sudo bash install.sh
sudo tunnelctl                 # باز کردن منوی مدیریت
```
۱) از منو **Network optimization → Apply** بزن (روی هر دو سرور).
۲) **Add tunnel** → پروتکل را انتخاب کن (برای عبور xray از DPI: **BackPack با wssmux** یا **GOST با mtls**) و نقش سرور (ایران/خارج) را.
۳) همان تانل را روی سرور مقابل با نقش برعکس بساز.
۴) (اختیاری) **Telegram configuration** برای اعلان و گزارش روزانه.

---

## 🧭 Usage

Open the menu:
```bash
sudo tunnelctl
```

Or drive it from the command line (scriptable / automatable):
```bash
sudo tunnelctl add                       # wizard
sudo tunnelctl list                      # overview of all tunnels
sudo tunnelctl status chi1               # one tunnel in detail
sudo tunnelctl start|stop|restart chi1
sudo tunnelctl enable|disable chi1       # auto-start on boot
sudo tunnelctl logs chi1
sudo tunnelctl optimize apply|revert|status
sudo tunnelctl telegram config
sudo tunnelctl backup                    # create a backup
sudo tunnelctl restore <file.tar.gz>
sudo tunnelctl report daily              # print; add --send to push to Telegram
sudo tunnelctl update
sudo tunnelctl uninstall
```

---

## 🏗️ Architecture

```
tunnel-manager/
├── tunnelctl              # entry point: menu + scriptable CLI
├── install.sh / uninstall.sh / update.sh
├── lib/                   # common, ui, validate, config, ipam, state, systemd, deps, menu
├── drivers/               # driver.sh dispatcher + gre/paqet/backhaul/backpack/rathole/gost/frp/hysteria (pluggable protocols)
├── modules/               # tunnel, optimize, monitor, telegram, report, backup, selfupdate
├── systemd/               # tm-monitor / tm-bot / tm-report units + timer
└── docs/                  # ARCHITECTURE, TELEGRAM, TROUBLESHOOTING
```

**Runtime layout** (created on install):
- Code: `/opt/tunnel-manager/`  ·  CLI symlink: `/usr/local/bin/tunnelctl`
- Config (private): `/etc/tunnel-manager/` — `tunnels/*.conf`, `paqet/*.yaml`, `settings.conf`, `telegram.conf`
- State/stats: `/var/lib/tunnel-manager/` — IPAM db, per-tunnel state, backups
- Logs: `/var/log/tunnel-manager/`

**Driver model.** The core never hard-codes a protocol. Each protocol implements
the same contract (`up`, `down`, `render_unit`, `status`, `health`, `sample`,
`validate`, `wizard`); `drivers/driver.sh` dispatches on `TUN[PROTOCOL]`. Adding
WireGuard/VXLAN later is just a new driver file.

**A tunnel profile** is a flat `KEY=VALUE` file (`/etc/tunnel-manager/tunnels/<name>.conf`)
loaded into an associative array. Immutable definition lives there; live
statistics live separately under `state/` so stats never rewrite your config.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full data model and flow.

---

## 🌐 Examples

### One Iran server ↔ two foreign servers (GRE)
On **Iran** (`1.1.1.1`):
```
tunnelctl add   # name=de1  proto=gre  role=iran  remote=2.2.2.2
tunnelctl add   # name=nl1  proto=gre  role=iran  remote=3.3.3.3
```
On **foreign A** (`2.2.2.2`): `add → de1 · gre · role=foreign · remote=1.1.1.1`
On **foreign B** (`3.3.3.3`): `add → nl1 · gre · role=foreign · remote=1.1.1.1`

Each pair gets its own `/30` (e.g. `10.20.0.4/30`, `10.20.0.8/30`) automatically.

### DPI-resistant path (Paqet)
On **foreign** (server): `add → px1 · paqet · role=foreign` (listens on a port).
On **Iran** (client): `add → px1 · paqet · role=iran · remote=<foreign IP>`, then
choose **port-forward** (e.g. local `443` → server `127.0.0.1:8443`) or **SOCKS5**.

---

## 🤖 Telegram

Optional and off by default. See [docs/TELEGRAM.md](docs/TELEGRAM.md).
```bash
sudo tunnelctl telegram config     # paste bot token + numeric chat id
```
Run the bot on the **foreign** server (Iran usually can't reach api.telegram.org).
From that one bot you control **both servers**: every tunnel auto-registers its
remote end as a controllable **peer** the moment it's created — no extra setup.

- **Per-tunnel control (buttons):** 🚇 Tunnels → pick a tunnel → Restart / Start /
  Stop / Enable / Disable / Logs. Same menu for **remote** tunnels under 🌐 Peers →
  pick a server → Manage tunnels.
- **Edit (buttons):** each tunnel's menu has **✏️ Edit** → tap a field → the bot
  asks for the new value → reply and it applies + restarts. Works the same for
  **remote** (Iran-side) tunnels via 🌐 Peers. Typed shortcuts also exist:
  `/set <tunnel> <KEY> <VALUE>` locally, or
  `/peer <server> set <tunnel> <KEY> <VALUE>` (e.g. `/peer iran set bp BP_PORT 9000`).
- **⬆️ Update (button):** updates this server to the latest script from GitHub
  **and every connected Iran peer too** (peers first, then this box — the bot
  restarts at the end and confirms). Also `/update`.
- Commands: `/menu` `/status` `/tunnels` `/system` `/bandwidth` `/usage`
  `/report` `/peers` `/logs <name>` `/restart <name>` `/set …` `/peer …`
  `/update` `/reboot`.

The same actions are scriptable locally: `tunnelctl set <name> <KEY> <VALUE>`,
`tunnelctl names`, `tunnelctl peer run <name> <cmd>`.

---

## ⚙️ Network optimization

```bash
sudo tunnelctl optimize apply      # BBR+fq, buffers, forwarding, queues (reversible)
sudo tunnelctl optimize status
sudo tunnelctl optimize revert     # restores your original sysctl values
```
Original values are backed up to `/var/lib/tunnel-manager/optimize.sysctl.bak`
**before** any change, and only BBR-capable kernels get BBR enabled.

---

## 🔄 Updating

```bash
sudo tunnelctl update
```
Pulls the latest code from `TM_REPO` (git or tarball) and re-runs the idempotent
installer. **Your tunnels, keys and settings are preserved.**

## 🧹 Uninstalling

```bash
sudo tunnelctl uninstall
```
Tears down every tunnel, removes services, **reverts optimization**, and lets you
choose whether to keep or delete configuration/backups.

---

## ❓ FAQ

**GRE vs Paqet — which do I use?** GRE is faster and simpler but needs a routable
public IP, GRE protocol 47 allowed, and the `ip_gre` kernel module (KVM/dedicated
— **not** OpenVZ/LXC). Paqet is userspace, encrypted and DPI-resistant; use it
when GRE is blocked/throttled.

**GRE says the module isn't available.** Your VPS is likely OpenVZ/LXC. Use Paqet.

**Does it work without Telegram?** Yes — Telegram is fully optional.

**Where are secrets stored?** Under `/etc/tunnel-manager/` with `chmod 600`,
readable only by root. Back them up with `tunnelctl backup`.

**Paqet download failed.** Set `PAQET_VERSION`/`PAQET_REPO` in
`settings.conf`, or drop the binary at `/opt/tunnel-manager/bin/paqet`. See
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

---

## 🔒 Security & robustness
- All inputs validated (IPs, ports, MTU, names, MACs); duplicate/conflicting
  tunnels rejected before anything is created.
- Operations are idempotent and fail safe — a failed `add` frees its IP
  allocation and never leaves a half-built tunnel running.
- `set -euo pipefail` throughout; ShellCheck-clean structure.

## 📄 License
MIT — see [LICENSE](LICENSE).
