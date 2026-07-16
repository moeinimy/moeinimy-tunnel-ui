# Architecture

## Layers

```
                ┌─────────────────────────────────────────────┐
   tunnelctl →  │  CLI dispatch  +  interactive menu (lib/menu)│
                └───────────────┬─────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────────────┐
   modules/ (features)          │            lib/ (foundation)   │
   tunnel  optimize  monitor    │   common validate ui config    │
   telegram report backup       │   ipam state systemd deps      │
        └───────────┬───────────┘                                │
                    │  driver_* dispatch                         │
             drivers/driver.sh ──► gre.sh / paqet.sh             │
                    │                                            │
                    ▼                                            │
   Linux: ip / iptables / sysctl / systemd  · Paqet binary       │
```

The **core is protocol-agnostic**. Everything protocol-specific lives behind the
driver contract, so the menu, monitor, backup and reporting code work the same
whether a tunnel is GRE or Paqet.

## Driver contract

Each driver implements functions prefixed with its protocol name; the generic
`driver_*` wrappers in `drivers/driver.sh` forward based on `TUN[PROTOCOL]`:

| Function | Purpose |
|----------|---------|
| `<p>_wizard`       | interactive prompts that populate `TUN` during `add` |
| `<p>_validate`     | reject invalid field combinations (0 ok / 1 bad) |
| `<p>_up` / `<p>_down` | bring the tunnel up / tear it down (idempotent) |
| `<p>_render_unit`  | print a complete systemd unit on stdout |
| `<p>_status`       | human-readable status lines |
| `<p>_health NAME`  | return 0 if currently healthy (used by the monitor) |
| `<p>_sample NAME`  | print `"RX_BYTES TX_BYTES"` for rate calculation |

Add a new protocol = add one `drivers/<name>.sh` implementing these, and list it
in `TM_SUPPORTED_PROTOCOLS`. Nothing else changes.

## Data model

**Tunnel profile** — `/etc/tunnel-manager/tunnels/<name>.conf` (flat `KEY=VALUE`,
`chmod 600`). Loaded into the associative array `TUN`. Only `A-Z0-9_` keys are
read, so a profile file can never inject shell.

Common keys: `NAME PROTOCOL ROLE LOCAL_IP REMOTE_IP MTU AUTOSTART CREATED_AT`.
- GRE adds: `INNER_LOCAL INNER_REMOTE INNER_CIDR GRE_KEY TTL IFNAME IPAM_INDEX ENABLE_NAT FORWARDS`.
- Paqet adds: `PAQET_ROLE PAQET_PORT PAQET_SECRET PAQET_MODE PAQET_CIPHER PAQET_CONN PAQET_IFACE PAQET_MAC PAQET_TRAFFIC PAQET_SOCKS_PORT PAQET_TARGET_HOST FORWARDS`.

**Runtime state** — `/var/lib/tunnel-manager/state/<name>.state` (array `ST`).
Holds `STATUS FAIL_COUNT STARTED_AT RX_BYTES TX_BYTES RX_RATE TX_RATE
PEAK_RX_RATE PEAK_TX_RATE LATENCY_MS LOSS_PCT SAMPLE_TS ALERTED`. Kept separate
so statistics never rewrite immutable config.

**IPAM** — `/var/lib/tunnel-manager/ipam.db` maps `name → index`. Index *i* →
`/30` at `pool_base + i*4`; host `.1` = foreign side, `.2` = Iran side. Lowest
free index is reused after a tunnel is removed.

## Persistence & lifecycle

Each tunnel owns a systemd unit `tm-tunnel-<name>.service`:
- **GRE** → `Type=oneshot, RemainAfterExit=yes`; `ExecStart=tunnelctl __up`,
  `ExecStop=tunnelctl __down`. `__up` creates the interface, addresses, MTU,
  routes, NAT and forwards.
- **Paqet** → `Type=simple, Restart=always`; `ExecStartPre=tunnelctl __up`
  (applies NOTRACK/anti-RST rules), `ExecStart=paqet run -c <yaml>`.

`start/stop/restart/enable/disable` map directly onto `systemctl`, so behaviour
is identical for both protocols and survives reboot.

## Background services

| Unit | Role |
|------|------|
| `tm-monitor.service` | loop: sample stats, probe latency/loss, auto-recover with bounded retries, watch CPU/RAM/disk |
| `tm-bot.service`     | Telegram long-poll command bot (only when configured) |
| `tm-report.timer`    | fires `tunnelctl report daily --send` each morning |

## Failure handling

- Every `run`/rule helper is idempotent (`-C` before `-A`, delete-if-present).
- A failed `add` frees its IPAM allocation and writes nothing half-formed.
- The monitor only auto-recovers tunnels that are enabled or already active, so
  a manually-stopped tunnel is left alone.
- Optimization backs up original sysctl values before writing anything.
