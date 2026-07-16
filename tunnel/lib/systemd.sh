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
    systemctl daemon-reload
    log_debug "installed unit $path"
}

svc_uninstall() {
    local name="$1" path
    path="$(unit_path "$name")"
    systemctl disable --now "$(unit_name "$name")" >/dev/null 2>&1 || true
    rm -f "$path"
    systemctl daemon-reload
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
