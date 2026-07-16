#!/usr/bin/env bash
# modules/backup.sh — backup & restore of all configuration (portable across
# servers). State/statistics are intentionally excluded; only definitions,
# keys, IPAM allocations and settings are captured.

backup_create() {
    require_root
    mkdir -p "$TM_BACKUP_DIR"
    local ts file
    ts="$(date '+%Y%m%d-%H%M%S')"
    file="${1:-$TM_BACKUP_DIR/tunnel-manager-backup-$ts.tar.gz}"

    # Collect config + ipam allocation table (relative paths for portability).
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$tmp/config"
    cp -a "$TM_CONFIG_DIR/." "$tmp/config/" 2>/dev/null || true
    [[ -f "$TM_IPAM_DB" ]] && cp -a "$TM_IPAM_DB" "$tmp/ipam.db"
    printf '%s\n' "$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)" >"$tmp/VERSION"

    tar -czf "$file" -C "$tmp" . 2>/dev/null
    chmod 600 "$file"
    rm -rf "$tmp"
    log_ok "Backup written: $file"
    printf '%s\n' "$file"
}

backup_list() {
    ui_title "Backups"
    shopt -s nullglob
    local f found=0
    for f in "$TM_BACKUP_DIR"/*.tar.gz; do
        found=1
        printf '  %s  (%s)\n' "$f" "$(du -h "$f" | cut -f1)"
    done
    shopt -u nullglob
    (( found )) || printf '  %sNo backups yet.%s\n' "$C_DIM" "$C_RESET"
}

# backup_restore FILE — restore config and re-install services.
backup_restore() {
    require_root
    local file="${1:-}"
    [[ -n "$file" ]] || { pick_backup file || return 0; }
    [[ -f "$file" ]] || { log_error "Backup not found: $file"; return 1; }
    confirm "Restore from '$file'? Existing config will be overwritten." no || return 0

    local tmp; tmp="$(mktemp -d)"
    tar -xzf "$file" -C "$tmp" || { rm -rf "$tmp"; die "Failed to extract backup."; }
    ensure_dirs
    cp -a "$tmp/config/." "$TM_CONFIG_DIR/" 2>/dev/null || true
    [[ -f "$tmp/ipam.db" ]] && { mkdir -p "$TM_STATE_DIR"; cp -a "$tmp/ipam.db" "$TM_IPAM_DB"; }
    chmod 700 "$TM_CONFIG_DIR" 2>/dev/null || true
    [[ -f "$TM_TELEGRAM_FILE" ]] && chmod 600 "$TM_TELEGRAM_FILE"
    rm -rf "$tmp"

    # Re-create per-tunnel systemd units and honour their autostart flag.
    local n
    while read -r n; do
        [[ -n "$n" ]] || continue
        load_tunnel "$n" || continue
        svc_install "$n"
        [[ "${TUN[AUTOSTART]:-no}" == yes ]] && svc_enable "$n"
    done < <(list_tunnels)
    systemctl daemon-reload
    log_ok "Restore complete. Start tunnels from the menu or: tunnelctl start <name>"
}

pick_backup() {
    local __v="$1" sel
    local -a b; mapfile -t b < <(find "$TM_BACKUP_DIR" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | sort -r)
    if [[ ${#b[@]} -eq 0 ]]; then log_warn "No backups found."; return 1; fi
    ask_menu sel "Select a backup" "${b[@]}"
    printf -v "$__v" '%s' "$sel"
}
