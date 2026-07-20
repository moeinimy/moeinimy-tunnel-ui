#!/usr/bin/env bash
# modules/tunnel.sh — tunnel lifecycle: add / remove / edit / start / stop /
# restart / enable / disable / status, plus the internal __up/__down hooks that
# systemd invokes.

# pick_tunnel VAR — interactive selection; sets VAR to a tunnel name.
pick_tunnel() {
    local __v="$1" sel
    local -a t; mapfile -t t < <(list_tunnels)
    if [[ ${#t[@]} -eq 0 ]]; then log_warn "No tunnels defined yet."; return 1; fi
    ask_menu sel "Select a tunnel" "${t[@]}"
    printf -v "$__v" '%s' "$sel"
}

# ---------------------------------------------------------------------------
# Add
# ---------------------------------------------------------------------------
tunnel_add() {
    require_root
    ensure_dirs
    ui_title "Add tunnel"

    local name proto role
    while true; do
        ask_valid name "Tunnel name (a-z 0-9 - _)" is_tunnel_name
        if tunnel_exists "$name"; then log_warn "A tunnel named '$name' already exists."; continue; fi
        break
    done

    ask_menu proto "Protocol" gre paqet backhaul backpack rathole gost frp hysteria
    ask_menu role  "Role of THIS server" iran foreign

    # Initialise a fresh profile.
    TUN=()
    TUN[NAME]="$name"
    TUN[PROTOCOL]="$proto"
    TUN[ROLE]="$role"
    TUN[AUTOSTART]="no"
    TUN[CREATED_AT]="$(date '+%Y-%m-%d %H:%M:%S')"

    # Protocol-specific questions populate the rest of TUN.
    driver_wizard || { log_error "wizard aborted"; return 1; }

    # Generic bot/peer control (all userspace protocols). The client side of a
    # reverse tunnel already knows the server's public IP (REMOTE_IP); the server
    # side does not, because the client dials in — so its peer agent can't
    # authorise/firewall the incoming peer. Ask once here for ANY non-GRE tunnel
    # that has no REMOTE_IP yet, so simply giving the IP is all that's needed for
    # automatic peer control — no per-driver setup, works for every protocol.
    if [[ "$proto" != gre && ( -z "${TUN[REMOTE_IP]:-}" || "${TUN[REMOTE_IP]}" == 0.0.0.0 ) ]]; then
        local peer_ip=""
        ask peer_ip "Other server's public IP — enables automatic bot/peer control (blank to skip)" ""
        if [[ -n "$peer_ip" ]]; then
            if is_ipv4 "$peer_ip"; then TUN[REMOTE_IP]="$peer_ip"
            else log_warn "Not a valid IPv4 — skipping peer control for this tunnel."; fi
        fi
    fi

    if ! driver_validate; then
        log_error "Validation failed; tunnel not created."
        [[ -n "${TUN[IPAM_INDEX]:-}" ]] && ipam_free "$name"
        return 1
    fi
    if ! profile_conflicts "$name" "$proto" "${TUN[LOCAL_IP]:-}" "${TUN[REMOTE_IP]:-}" \
                           "${TUN[PAQET_PORT]:-}" "${TUN[GRE_KEY]:-}"; then
        log_error "Conflicting configuration; tunnel not created."
        [[ -n "${TUN[IPAM_INDEX]:-}" ]] && ipam_free "$name"
        return 1
    fi

    save_tunnel
    svc_install "$name"
    # Auto-register this tunnel's remote as a controllable peer (all protocols).
    agent_firewall ensure 2>/dev/null || true
    log_ok "Tunnel '$name' created."

    if confirm "Enable auto-start on boot?" yes; then
        TUN[AUTOSTART]="yes"; save_tunnel; svc_enable "$name"
    fi
    if confirm "Start the tunnel now?" yes; then
        tunnel_start "$name"
    fi
}

# ---------------------------------------------------------------------------
# Remove
# ---------------------------------------------------------------------------
tunnel_remove() {
    require_root
    local name="${1:-}"
    [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    confirm "Really remove tunnel '$name'? This tears it down." no || return 0

    load_tunnel "$name"
    svc_uninstall "$name"
    # Best-effort teardown in case the service was not running.
    driver_down 2>/dev/null || true
    [[ "${TUN[PROTOCOL]}" == paqet ]] && rm -f "$(paqet_cfg "$name")"
    [[ "${TUN[PROTOCOL]}" == backhaul ]] && rm -f "$(backhaul_cfg "$name")"
    [[ "${TUN[PROTOCOL]}" == backpack ]] && rm -f "$(backpack_cfg "$name")" "$(backpack_cert "$name")" "$(backpack_key "$name")"
    [[ "${TUN[PROTOCOL]}" == hysteria ]] && rm -f "$(hysteria_cfg "$name")" "$(hysteria_cert "$name")" "$(hysteria_key "$name")"
    [[ "${TUN[PROTOCOL]}" == rathole ]] && rm -f "$(rathole_cfg "$name")"
    [[ "${TUN[PROTOCOL]}" == gost ]] && rm -f "$(gost_wrapper "$name")"
    [[ "${TUN[PROTOCOL]}" == frp ]] && rm -f "$(frp_cfg "$name")"
    [[ -n "${TUN[IPAM_INDEX]:-}" ]] && ipam_free "$name"
    state_delete "$name"
    rm -f "$TM_STATE_DIR/history/${name}.hist"
    delete_tunnel_file "$name"
    agent_firewall ensure 2>/dev/null || true    # refresh peer whitelist
    log_ok "Tunnel '$name' removed."
    tg_notify "🗑️ Tunnel <b>$name</b> removed on $(hostname)"
}

# ---------------------------------------------------------------------------
# Edit (a focused subset of safely-editable fields)
# ---------------------------------------------------------------------------
# Internal profile keys the user should not edit directly.
_TM_NOEDIT_KEYS=" NAME PROTOCOL ROLE CREATED_AT IPAM_INDEX IFNAME INNER_LOCAL INNER_REMOTE INNER_CIDR PAQET_ROLE BH_ROLE BP_ROLE RH_ROLE GO_ROLE FRP_ROLE WW_ROLE HY_ROLE GO_USER "

# _field_label KEY — a friendly hint for known keys (helps identify ports).
_field_label() {
    case "$1" in
        MTU) echo "MTU (packet size)" ;;
        PAQET_PORT|BH_PORT|RH_PORT|GO_PORT|FRP_PORT|WW_PORT) echo "$1 (tunnel/control port)" ;;
        WW_USER_PORT) echo "WW_USER_PORT (local port users connect to)" ;;
        WW_TARGET_PORT|GO_TARGET) echo "$1 (destination on the exit side)" ;;
        FORWARDS|BH_PORTS|RH_PORTS|GO_PORTS|FRP_PORTS) echo "$1 (port map)" ;;
        *_SECRET|*_TOKEN|*_PASS|*_PASSWORD|GRE_KEY|WW_KEY) echo "$1 (secret — must match peer)" ;;
        *) echo "$1" ;;
    esac
}

tunnel_edit() {
    require_root
    local name="${1:-}"
    [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    load_tunnel "$name"

    # Build a protocol-aware list of editable KEY=VALUE fields.
    local -a labels=() ; local k
    while read -r k; do
        [[ "$_TM_NOEDIT_KEYS" == *" $k "* ]] && continue
        labels+=("$(_field_label "$k")  =  ${TUN[$k]}")
    done < <(printf '%s\n' "${!TUN[@]}" | sort)
    # Offer to set the peer IP on server-side userspace tunnels that don't have
    # one yet (retrofits automatic bot/peer control onto existing tunnels — just
    # give the IP, nothing else needed).
    if [[ "${TUN[PROTOCOL]}" != gre && ( -z "${TUN[REMOTE_IP]:-}" || "${TUN[REMOTE_IP]}" == 0.0.0.0 ) ]]; then
        labels+=("Set peer IP for bot control")
    fi
    labels+=("Toggle auto-start (now: ${TUN[AUTOSTART]:-no})" "Cancel")

    local sel
    ask_menu sel "Edit ${TUN[PROTOCOL]} tunnel '$name' — pick a setting" "${labels[@]}"
    case "$sel" in
        "Cancel") return 0 ;;
        "Set peer IP for bot control")
            ask_valid TUN[REMOTE_IP] "Other server's public IP (bot/peer control)" is_ipv4 ;;
        "Toggle auto-start"*)
            if [[ "${TUN[AUTOSTART]:-no}" == yes ]]; then TUN[AUTOSTART]=no; svc_disable "$name"
            else TUN[AUTOSTART]=yes; svc_enable "$name"; fi ;;
        *)
            # Recover the real key from the "LABEL  =  value" selection.
            local lbl="${sel%%  =  *}" key
            key="${lbl%% (*}"          # strip the "(hint)" suffix if present
            [[ -n "${TUN[$key]+x}" ]] || { log_error "Cannot map '$lbl' to a field."; return 1; }
            local newval
            case "$key" in
                MTU)          ask_valid newval "New MTU" is_mtu "${TUN[$key]}" ;;
                *PORT|*_PORT) ask_valid newval "New value for $key" is_port "${TUN[$key]}" ;;
                *)            ask newval "New value for $key" "${TUN[$key]}" ;;
            esac
            TUN[$key]="$newval"
            # Regenerate the protocol's config file if it keeps one out-of-band.
            case "${TUN[PROTOCOL]}" in
                paqet) paqet_generate_config ;;
                backhaul) backhaul_generate_config ;;
                backpack) backpack_generate_config ;;
                hysteria) hysteria_generate_config ;;
                rathole) rathole_generate_config ;;
                gost) gost_generate_config ;;
                frp) frp_generate_config ;;
            esac ;;
    esac
    save_tunnel
    svc_install "$name"
    # Refresh the peer agent firewall/authorisation in case REMOTE_IP changed.
    agent_firewall ensure 2>/dev/null || true
    log_ok "Updated '$name'. Restarting to apply…"
    tunnel_restart "$name"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
# tunnel_set NAME KEY VALUE — non-interactive field edit (scriptable + remote-
# controllable via the peer agent / Telegram bot). Mirrors the interactive Edit:
# updates one field, regenerates the protocol config, and restarts to apply.
tunnel_set() {
    require_root
    local name="$1" key="$2" value="$3"
    [[ -n "$name" && -n "$key" ]] || { log_error "usage: set <tunnel> <KEY> <VALUE>"; return 1; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    load_tunnel "$name"
    if [[ "$_TM_NOEDIT_KEYS" == *" $key "* ]]; then log_error "Field '$key' is not editable."; return 1; fi
    # The key must already exist, except REMOTE_IP which may be added to enable
    # bot/peer control on a server-side tunnel that didn't have it.
    if [[ -z "${TUN[$key]+x}" && "$key" != REMOTE_IP ]]; then
        log_error "Unknown field '$key' for ${TUN[PROTOCOL]} tunnel '$name'."; return 1
    fi
    TUN[$key]="$value"
    case "${TUN[PROTOCOL]}" in
        paqet)    paqet_generate_config ;;
        backhaul) backhaul_generate_config ;;
        backpack) backpack_generate_config ;;
        rathole)  rathole_generate_config ;;
        gost)     gost_generate_config ;;
        frp)      frp_generate_config ;;
        hysteria) hysteria_generate_config ;;
    esac
    save_tunnel
    svc_install "$name"
    agent_firewall ensure 2>/dev/null || true
    log_ok "Set ${key}=${value} on '$name'. Restarting to apply…"
    tunnel_restart "$name"
}

# tunnel_names — print tunnel names, one per line (used by remote/bot menus).
tunnel_names() { list_tunnels; }

# tunnel_fields NAME — print editable KEY=VALUE lines (used by the bot's
# button-based edit menu, locally and over the peer agent).
tunnel_fields() {
    local name="$1"; tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    load_tunnel "$name"
    local k
    while read -r k; do
        [[ "$_TM_NOEDIT_KEYS" == *" $k "* ]] && continue
        printf '%s=%s\n' "$k" "${TUN[$k]}"
    done < <(printf '%s\n' "${!TUN[@]}" | sort)
}

tunnel_start() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    log_info "Starting '$name'…"
    if svc_start "$name"; then
        # Clear the manual-stop flag: the user wants this one running again.
        state_set "$name" STATUS up STARTED_AT "$(date +%s)" FAIL_COUNT 0 MANUAL_STOP 0
        log_ok "Tunnel '$name' started."
        tg_notify "🟢 Tunnel <b>$name</b> is UP on $(hostname)"
    else
        state_set "$name" STATUS down
        log_error "Failed to start '$name'. Check: journalctl -u $(unit_name "$name")"
        tg_notify "🔴 Tunnel <b>$name</b> FAILED to start on $(hostname)"
        return 1
    fi
}

tunnel_stop() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    svc_stop "$name" || true
    # MANUAL_STOP tells the monitor this is deliberate. Without it the monitor
    # sees an enabled-but-inactive tunnel, calls it unhealthy, and restarts it on
    # the next tick — so a stopped tunnel would not stay stopped.
    state_set "$name" STATUS down MANUAL_STOP 1
    log_ok "Tunnel '$name' stopped (stays down until you start it)."
    tg_notify "⏹️ Tunnel <b>$name</b> stopped on $(hostname)"
}

tunnel_restart() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    if svc_restart "$name"; then
        state_set "$name" STATUS up MANUAL_STOP 0
        log_ok "Tunnel '$name' restarted."
    else
        state_set "$name" STATUS down
        log_error "Restart of '$name' failed."
        return 1
    fi
}

tunnel_enable() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    load_tunnel "$name" || { log_error "No such tunnel: $name"; return 1; }
    svc_enable "$name"; TUN[AUTOSTART]=yes; save_tunnel
    log_ok "Auto-start enabled for '$name'."
}

tunnel_disable() {
    require_root
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    load_tunnel "$name" || { log_error "No such tunnel: $name"; return 1; }
    svc_disable "$name"; TUN[AUTOSTART]=no; save_tunnel
    log_ok "Auto-start disabled for '$name'."
}

# ---------------------------------------------------------------------------
# Internal hooks called by systemd units
# ---------------------------------------------------------------------------
tunnel_up_hook() {   # __up NAME
    local name="${1:-}"
    load_tunnel "$name" || die "unknown tunnel: $name"
    driver_up
    # Keep queue management right for EVERY protocol, on every start: GRE's own
    # tm* device plus the WAN that all the userspace relays share. Without an AQM
    # qdisc the bottleneck queue grows unbounded and latency explodes under load.
    declare -F tm_aqm_ensure >/dev/null && tm_aqm_ensure 2>/dev/null || true
    state_set "$name" STATUS up
}

tunnel_down_hook() { # __down NAME
    local name="${1:-}"
    load_tunnel "$name" || return 0
    driver_down
    state_set "$name" STATUS down
}

# ---------------------------------------------------------------------------
# Status / overview
# ---------------------------------------------------------------------------
tunnel_status() {
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    load_tunnel "$name" || { log_error "No such tunnel: $name"; return 1; }
    state_load "$name"

    ui_title "Tunnel: $name"
    local active="down"; svc_is_active "$name" && active="up"
    ui_kv "Service"    "$(status_dot "$active") $(svc_state "$name")  (autostart: $(svc_is_enabled "$name" && echo yes || echo no))$([[ "${ST[MANUAL_STOP]:-0}" == 1 ]] && printf '  [stopped by you — monitor will not restart it]')"
    ui_kv "Protocol"   "${TUN[PROTOCOL]}   role: ${TUN[ROLE]}"
    driver_status
    # Live stats gathered by the monitor.
    local up_since="${ST[STARTED_AT]:-}"
    if [[ -n "$up_since" && "$active" == up ]]; then
        ui_kv "Uptime"  "$(human_duration "$(( $(date +%s) - up_since ))")"
    fi
    [[ -n "${ST[LATENCY_MS]:-}" ]] && ui_kv "Reachability" "${ST[LATENCY_MS]} ms  loss ${ST[LOSS_PCT]:-?}%  (${ST[PROBE]:-icmp} probe)"
    [[ -n "${ST[RX_RATE]:-}" ]]    && ui_kv "Rate"     "↓ $(human_bytes "${ST[RX_RATE]:-0}")/s   ↑ $(human_bytes "${ST[TX_RATE]:-0}")/s"
    [[ -n "${ST[RX_BYTES]:-}" ]]   && ui_kv "Total"    "↓ $(human_bytes "${ST[RX_BYTES]:-0}")   ↑ $(human_bytes "${ST[TX_BYTES]:-0}")"
}

# tunnel_overview — compact table of every tunnel.
tunnel_overview() {
    local -a t; mapfile -t t < <(list_tunnels)
    ui_title "Tunnels (${#t[@]})"
    if [[ ${#t[@]} -eq 0 ]]; then printf '  %sNo tunnels configured.%s\n' "$C_DIM" "$C_RESET"; return 0; fi
    printf '  %s%-16s %-7s %-8s %-8s %-22s%s\n' "$C_BOLD" "NAME" "PROTO" "ROLE" "STATE" "PEER" "$C_RESET"
    local n active peer
    for n in "${t[@]}"; do
        load_tunnel "$n"
        active="down"; svc_is_active "$n" && active="up"
        peer="${TUN[REMOTE_IP]:-?}"
        printf '  %-16s %-7s %-8s %s%-7s%s %-22s\n' \
            "$n" "${TUN[PROTOCOL]}" "${TUN[ROLE]}" "$(status_dot "$active")" " $active" "" "$peer"
    done
}

# tunnel_bandwidth — per-tunnel traffic table (current rate, peak, totals).
tunnel_bandwidth() {
    local -a t; mapfile -t t < <(list_tunnels)
    ui_title "Bandwidth"
    if [[ ${#t[@]} -eq 0 ]]; then printf '  %sNo tunnels.%s\n' "$C_DIM" "$C_RESET"; return 0; fi
    printf '  %s%-14s %-11s %-11s %-11s %-11s%s\n' "$C_BOLD" "NAME" "↓ now/s" "↑ now/s" "↓ total" "↑ total" "$C_RESET"
    local n
    for n in "${t[@]}"; do
        state_load "$n"
        printf '  %-14s %-11s %-11s %-11s %-11s\n' "$n" \
            "$(human_bytes "${ST[RX_RATE]:-0}")" "$(human_bytes "${ST[TX_RATE]:-0}")" \
            "$(human_bytes "${ST[RX_BYTES]:-0}")" "$(human_bytes "${ST[TX_BYTES]:-0}")"
    done
}

# tunnel_logs NAME — recent journal for the tunnel's unit.
tunnel_logs() {
    local name="${1:-}"; [[ -n "$name" ]] || { pick_tunnel name || return 0; }
    tunnel_exists "$name" || { log_error "No such tunnel: $name"; return 1; }
    journalctl -u "$(unit_name "$name")" -n 40 --no-pager 2>/dev/null || \
        log_warn "journalctl unavailable."
}
