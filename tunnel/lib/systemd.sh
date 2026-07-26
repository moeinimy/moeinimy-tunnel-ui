#!/usr/bin/env bash
# lib/systemd.sh — thin wrappers around systemctl for per-tunnel services.
# The unit *content* is produced by the active driver (driver_render_unit),
# keeping this file protocol-agnostic.

# unit_name NAME -> systemd unit name for a tunnel.
unit_name() { printf '%s%s.service' "$TM_UNIT_PREFIX" "$1"; }

# unit_path NAME -> full path of the unit file.
unit_path() { printf '/etc/systemd/system/%s' "$(unit_name "$1")"; }

# svc_install NAME — write the unit file for a loaded tunnel (TUN populated).
# Delegates content to driver_render_unit which must print a full unit file.
svc_install() {
    local name="$1" path tmp
    path="$(unit_path "$name")"
    tmp="$(mktemp)"
    driver_render_unit >"$tmp" || { rm -f "$tmp"; return 1; }
    install -m 0644 "$tmp" "$path"
    rm -f "$tmp"
    svc_accounting_dropin "$name"
    systemctl daemon-reload
    log_debug "installed unit $path"
}

# svc_accounting_dropin NAME — turn on systemd's per-unit IP accounting.
# Written as a drop-in rather than baked into each driver's unit so it applies
# to every protocol from one place. Takes effect when the unit next starts.
svc_accounting_dropin() {
    local dir
    dir="$(unit_path "$1").d"
    mkdir -p "$dir"
    cat >"$dir/10-accounting.conf" <<'EOF'
# Managed by Tunnel Manager — enables the byte counters the bot reports.
[Service]
IPAccounting=yes
EOF
    chmod 0644 "$dir/10-accounting.conf"
    # Also apply it live, so a tunnel that is already running starts counting
    # without being restarted (dropping user connections). The drop-in above is
    # what makes it stick across reboots.
    if systemctl is-active --quiet "$(unit_name "$1")" 2>/dev/null; then
        systemctl set-property --runtime "$(unit_name "$1")" IPAccounting=yes >/dev/null 2>&1 || true
    fi
}

svc_uninstall() {
    local name="$1" path
    path="$(unit_path "$name")"
    systemctl disable --now "$(unit_name "$name")" >/dev/null 2>&1 || true
    rm -f "$path"
    rm -rf "${path}.d"
    systemctl daemon-reload
}

# svc_ip_sample NAME -> "RX TX" total bytes, from systemd's IP accounting.
# Userspace tunnels own no network interface, so the kernel keeps no netdev
# counters for them (that is why every non-GRE driver used to report 0/0).
# IPAccounting attaches a BPF filter to the unit's cgroup and counts every byte
# the process sends and receives — for a tunnel process, that IS the tunnel
# traffic. Counters restart with the unit; the monitor already treats a counter
# going backwards as a restart and keeps its own lifetime totals.
svc_ip_sample() {
    local unit rx tx
    unit="$(unit_name "$1")"
    rx="$(systemctl show "$unit" -p IPIngressBytes --value 2>/dev/null)"
    tx="$(systemctl show "$unit" -p IPEgressBytes  --value 2>/dev/null)"
    # systemd reports "[not set]" — or its UINT64_MAX sentinel — when accounting
    # is off or the kernel lacks BPF cgroup support. Both mean "no data", so
    # report zero instead of a bogus 18-exabyte reading.
    [[ "$rx" =~ ^[0-9]+$ && "$rx" != 18446744073709551615 ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ && "$tx" != 18446744073709551615 ]] || tx=0
    # A relay touches every byte twice: it reads a byte off one socket and
    # writes it to the other. So the cgroup counts an upload byte once as
    # ingress (from the user) and once as egress (to the peer), and a download
    # byte the same way — leaving both counters at upload+download, i.e. double
    # the real volume. Halving makes the reported total exact. The per-direction
    # split is necessarily an estimate: cgroup accounting cannot tell a user
    # socket from a peer socket. GRE is unaffected — it reads netdev counters,
    # which see each packet once.
    printf '%s %s' "$(( rx / 2 ))" "$(( tx / 2 ))"
}

svc_start()   { systemctl start   "$(unit_name "$1")"; }
svc_stop()    { systemctl stop    "$(unit_name "$1")"; }
svc_restart() { systemctl restart "$(unit_name "$1")"; }
svc_enable()  { systemctl enable  "$(unit_name "$1")" >/dev/null 2>&1; }
svc_disable() { systemctl disable "$(unit_name "$1")" >/dev/null 2>&1; }

# svc_is_active NAME
svc_is_active()  { systemctl is-active  --quiet "$(unit_name "$1")"; }
svc_is_enabled() { systemctl is-enabled --quiet "$(unit_name "$1")" 2>/dev/null; }

# svc_state NAME -> active|inactive|failed|...
svc_state() { systemctl is-active "$(unit_name "$1")" 2>/dev/null || true; }
