# moeinimy-tunnel-ui — Integration notes

This repository merges two projects into one panel:

- **vpn-ui** (base) — a Go fork of [3x-ui](https://github.com/MHSanaei/3x-ui) 2.9.3
  by [Sir-MmD](https://github.com/Sir-MmD/vpn-ui). Provides the whole web panel,
  Xray/VPN cores, database, auth, i18n. **GPL-3.0.**
- **tunnel-manager** (vendored under [`tunnel/`](tunnel/)) — the modular
  GRE/Paqet/BackPack/GOST/… tunnel manager (`tunnelctl`). **MIT.**

The goal: manage server-to-server tunnels **from the panel UI** instead of SSH,
with a **one-liner Iran node**, while keeping stock **3x-ui backups restorable**.

## Design principle: the panel never re-implements tunnel logic

The Go panel is a **thin bridge** to the vendored `tunnelctl` CLI:

```
Browser (Vue)  ──HTTP──▶  web/controller/tunnel.go
                          web/service/tunnel.go  ──exec──▶  tunnelctl json …   (reads)
                                                            tunnelctl start/…  (control)
                                                            tunnelctl create … (add)
```

Consequences:

- **`x-ui.db` is never touched by any tunnel operation.** Tunnel config lives in
  `/etc/tunnel-manager` (flat KEY=VALUE files), exactly as the CLI already stores
  it. A stock 3x-ui `.db` backup therefore restores here unchanged. ✅ (critical
  constraint)
- The bash project stays the single source of truth; the UI and CLI can be used
  interchangeably.

## What was added

| Area | File(s) |
|------|---------|
| JSON contract for the panel | `tunnel/modules/api.sh` (`tunnelctl json list/tunnel/protocols/fields/meta`, `tunnelctl create KEY=VALUE…`) |
| Backend service | `web/service/tunnel.go` |
| Backend controller + routes | `web/controller/tunnel.go`, wired in `web/controller/xui.go` (`/panel/tunnel/*`) |
| Frontend page | `web/html/tunnel.html` (list, live stats, start/stop/restart, enable/disable, create wizard, per-field edit, logs, optimize) |
| Nav entry | `web/html/component/aSidebar.html` |
| i18n | `web/translation/translate.en_US.toml`, `translate.fa_IR.toml` (+ parity baseline in `web/i18n_toml_test.go`) |

### API surface (`/panel/tunnel`)

Reads: `GET /meta`, `/list`, `/protocols`, `/tunnel/:name`, `/fields/:name`, `/logs/:name`.
Control: `POST /create`, `/remove/:name`, `/start|stop|restart|enable|disable/:name`,
`/set/:name`, `/optimize/:action`.

## Build & verify (needs a Linux box with Go)

```bash
./build.sh                    # builds build/out/vpn-ui-<arch> with everything embedded
# then run the binary; open the panel; the "Tunnels" menu appears in the sidebar.
go test ./web/...             # includes the i18n TOML parity tests
```

> Go is not available on the author's dev machine, so the Go/HTML was written to
> match the existing `Core` controller/service/page patterns exactly. Final
> compile + runtime verification must run on a build host (`./build.sh`).

## Roadmap

- [x] Tunnel management section in the UI (local host)
- [x] Unified installer (`scripts/install.sh`): one command installs the panel
      **and** the tunnel backend (foreign role)
- [x] Combined backup/restore (`tunnelctl backup-full` / `restore-full`): bundles
      panel DB + tunnel config, and auto-detects a stock `.db` vs. our archive
- [~] Iran **one-liner node** (`scripts/install.sh --iran`): installs + registers
      the node today. The **reverse-connect control plane** (below) is the part
      still to build so the node is fully driven from the panel with no SSH.
- [ ] **Reverse-WSS node control plane** — the final phase. Design:
  - Panel binary gains a node mode (`vpn-ui tunnel-node --panel URL --token T`),
    reusing the same release binary on the Iran box.
  - The node **dials out** to the panel over **WSS** (the panel's existing HTTPS
    port) — DPI-resistant (looks like normal HTTPS), NAT-friendly, only the
    foreign port is open. Authenticated by the one-time `NODE_TOKEN`.
  - Panel keeps a node registry + a `/panel/tunnel/nodes` UI; tunnel operations
    can target `local` or a specific node, executed as allowlisted `tunnelctl`
    calls over the WSS channel and returned as JSON.
  - Requires a Go build environment + two test servers to implement/validate
    the handshake safely, so it is intentionally left for that environment.

## Attribution / license

vpn-ui and 3x-ui are GPL-3.0; this repository stays **GPL-3.0** (see `LICENSE`).
The vendored `tunnel/` retains its own MIT `LICENSE`.
