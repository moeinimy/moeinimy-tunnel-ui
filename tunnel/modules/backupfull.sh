#!/usr/bin/env bash
# modules/backupfull.sh — combined panel+tunnel backup/restore.
#
# The panel's own backup (a stock 3x-ui / vpn-ui .db file) keeps working
# untouched, so a stock 3x-ui backup still restores on this panel. THIS module
# adds a second, richer format: a .tar.gz bundling the panel database AND the
# tunnel-manager config, so our own backups carry everything.
#
# restore_full auto-detects what it was handed:
#   * a raw SQLite database  -> stock panel restore (DB only)
#   * our .tar.gz archive     -> panel DB + tunnel config together
#
# Paths default to the bundled installer's layout and are overridable via env
# (VPNUI_DIR / VPNUI_DB / VPNUI_UNIT) for custom installs.

: "${VPNUI_DIR:=/opt/vpn-ui}"
: "${VPNUI_DB:=$VPNUI_DIR/vpn-ui.db}"
: "${VPNUI_UNIT:=vpn-ui}"

# backup_full [OUTFILE] — write a combined archive; prints the resulting path.
backup_full() {
    local out="${1:-}"
    [[ -n "$out" ]] || out="$TM_BACKUP_DIR/full-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$(dirname "$out")"

    local work; work="$(mktemp -d)"
    mkdir -p "$work/panel" "$work/tunnel-manager"

    # Panel database (+ SQLite WAL/SHM sidecars for a consistent snapshot).
    if [[ -f "$VPNUI_DB" ]]; then
        cp -p "$VPNUI_DB" "$work/panel/" 2>/dev/null || true
        local s
        for s in wal shm; do
            [[ -f "$VPNUI_DB-$s" ]] && cp -p "$VPNUI_DB-$s" "$work/panel/" 2>/dev/null || true
        done
    fi

    # Tunnel-manager config tree (profiles, secrets, settings).
    if [[ -d "$TM_CONFIG_DIR" ]]; then
        cp -a "$TM_CONFIG_DIR/." "$work/tunnel-manager/" 2>/dev/null || true
    fi

    {
        echo "type=moeinimy-tunnel-ui-full"
        echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host=$(hostname 2>/dev/null || echo unknown)"
        echo "tunnel_version=$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)"
        echo "db_name=$(basename "$VPNUI_DB")"
    } > "$work/MANIFEST"

    tar -czf "$out" -C "$work" . || { rm -rf "$work"; die "backup-full: tar failed"; }
    rm -rf "$work"
    log_ok "Combined backup written: $out" >&2
    printf '%s\n' "$out"
}

# restore_panel_db FILE — stop the panel, swap in FILE as the panel DB (clearing
# stale WAL/SHM so the new DB is authoritative), then restart the panel.
restore_panel_db() {
    local src="$1"
    [[ -f "$src" ]] || { log_error "restore: DB file missing: $src"; return 1; }
    mkdir -p "$(dirname "$VPNUI_DB")"
    if have systemctl; then systemctl stop "$VPNUI_UNIT" 2>/dev/null || true; fi
    # Snapshot whatever is there now before overwriting.
    if [[ -f "$VPNUI_DB" ]]; then
        cp -p "$VPNUI_DB" "$VPNUI_DB.pre-restore-$(date +%s)" 2>/dev/null || true
    fi
    cp -f "$src" "$VPNUI_DB" || { log_error "restore: could not write $VPNUI_DB"; return 1; }
    rm -f "$VPNUI_DB-wal" "$VPNUI_DB-shm" 2>/dev/null || true
    if have systemctl; then systemctl start "$VPNUI_UNIT" 2>/dev/null || log_warn "restore: could not start $VPNUI_UNIT"; fi
    log_ok "Panel database restored from $(basename "$src")."
}

# restore_full FILE — auto-detect a stock DB vs our combined archive.
restore_full() {
    local file="${1:-}"
    [[ -f "$file" ]] || die "restore-full: file not found: $file"

    # A stock 3x-ui / vpn-ui backup is a raw SQLite database (magic string).
    local magic; magic="$(head -c16 "$file" 2>/dev/null | tr -d '\0')"
    if [[ "$magic" == "SQLite format 3" ]]; then
        log_info "Detected a stock panel database backup — restoring DB only."
        restore_panel_db "$file"
        return
    fi

    # Otherwise expect our .tar.gz.
    local work; work="$(mktemp -d)"
    if ! tar -xzf "$file" -C "$work" 2>/dev/null; then
        rm -rf "$work"; die "restore-full: not a SQLite DB and not a valid .tar.gz archive"
    fi
    if [[ ! -f "$work/MANIFEST" ]] || ! grep -q '^type=moeinimy-tunnel-ui-full' "$work/MANIFEST"; then
        rm -rf "$work"; die "restore-full: archive is missing the moeinimy-tunnel-ui MANIFEST"
    fi

    log_info "Detected a combined backup — restoring panel DB + tunnel config."

    # Tunnel-manager config.
    if [[ -d "$work/tunnel-manager" ]]; then
        ensure_dirs
        cp -a "$work/tunnel-manager/." "$TM_CONFIG_DIR/" 2>/dev/null || true
        chmod 700 "$TM_CONFIG_DIR" 2>/dev/null || true
        log_ok "Tunnel config restored."
    fi

    # Panel database.
    local dbf; dbf="$(find "$work/panel" -maxdepth 1 -name '*.db' 2>/dev/null | head -1)"
    [[ -n "$dbf" ]] && restore_panel_db "$dbf"

    # Re-install per-tunnel systemd units from the restored profiles so they can
    # start on this host (unit files are host-specific and not carried in-band).
    if declare -F svc_install >/dev/null 2>&1 && declare -F list_tunnels >/dev/null 2>&1; then
        local n
        while read -r n; do
            [[ -n "$n" ]] || continue
            load_tunnel "$n" || continue
            svc_install "$n" 2>/dev/null || true
            [[ "${TUN[AUTOSTART]:-no}" == yes ]] && svc_enable "$n" 2>/dev/null || true
        done < <(list_tunnels 2>/dev/null || true)
    fi

    rm -rf "$work"
    log_ok "Combined restore complete."
}
