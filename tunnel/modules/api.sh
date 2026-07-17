#!/usr/bin/env bash
# modules/api.sh — machine-readable (JSON) interface for the web panel.
#
# The vpn-ui panel does NOT re-implement any tunnel logic; it shells out to
# `tunnelctl json <sub>` for reads and to the existing lifecycle commands
# (start/stop/restart/enable/disable/set) for control. Everything here only
# READS the same TUN/ST arrays the CLI already uses, plus one non-interactive
# create path (`tunnelctl create KEY=VALUE ...`) so the panel can add tunnels
# without an interactive TTY.
#
# Design rules:
#   * Pure bash JSON emission (no jq dependency).
#   * Every value is emitted as a JSON string unless it is a known boolean.
#   * Never fail hard: a missing tunnel yields an object with "error", not exit 1.

# --- JSON string escaping (pure bash, fast) ---------------------------------
json_escape() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# json_from_assoc ARRAYNAME — emit an assoc array as a JSON object of strings.
json_from_assoc() {
    local -n _arr="$1"
    local first=1 k
    printf '{'
    for k in $(printf '%s\n' "${!_arr[@]}" | sort); do
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        printf '"%s":"%s"' "$(json_escape "$k")" "$(json_escape "${_arr[$k]}")"
    done
    printf '}'
}

# --- Single tunnel object ---------------------------------------------------
# api_tunnel_obj NAME — {name, active, enabled, service_state, config{}, state{}}
api_tunnel_obj() {
    local name="$1"
    if ! load_tunnel "$name"; then
        printf '{"name":"%s","error":"not found"}' "$(json_escape "$name")"
        return 0
    fi
    state_load "$name"
    local active=false enabled=false sstate=""
    if svc_is_active  "$name"; then active=true;  fi
    if svc_is_enabled "$name"; then enabled=true; fi
    sstate="$(svc_state "$name" 2>/dev/null || true)"
    printf '{"name":"%s","active":%s,"enabled":%s,"service_state":"%s","config":%s,"state":%s}' \
        "$(json_escape "$name")" "$active" "$enabled" "$(json_escape "$sstate")" \
        "$(json_from_assoc TUN)" "$(json_from_assoc ST)"
}

# api_list — JSON array of every tunnel object.
api_list() {
    local -a t; mapfile -t t < <(list_tunnels)
    local first=1 n
    printf '['
    for n in "${t[@]}"; do
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        api_tunnel_obj "$n"
    done
    printf ']\n'
}

# api_protocols — JSON array of supported protocol ids.
api_protocols() {
    local first=1 p
    printf '['
    for p in "${TM_SUPPORTED_PROTOCOLS[@]}"; do
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        printf '"%s"' "$(json_escape "$p")"
    done
    printf ']\n'
}

# api_fields NAME — JSON array of editable {key,value} pairs.
api_fields() {
    local name="$1"
    if ! tunnel_exists "$name"; then printf '[]\n'; return 0; fi
    load_tunnel "$name"
    local first=1 k
    printf '['
    for k in $(printf '%s\n' "${!TUN[@]}" | sort); do
        [[ "${_TM_NOEDIT_KEYS:-}" == *" $k "* ]] && continue
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        printf '{"key":"%s","value":"%s"}' "$(json_escape "$k")" "$(json_escape "${TUN[$k]}")"
    done
    printf ']\n'
}

# api_meta — panel-level metadata (version, role, counts, optimize state).
api_meta() {
    local ver opt count role
    ver="$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)"
    count="$(count_tunnels 2>/dev/null || echo 0)"
    role="$(cat "$TM_CONFIG_DIR/role" 2>/dev/null || echo foreign)"
    # Optimization is "applied" iff the optimize marker file exists (same signal
    # optimize_status uses). TM_OPT_MARKER is defined in modules/optimize.sh.
    if [[ -n "${TM_OPT_MARKER:-}" && -f "${TM_OPT_MARKER:-}" ]]; then
        opt="applied"
    else
        opt="reverted"
    fi
    printf '{"version":"%s","node_role":"%s","tunnel_count":%s,"optimize":"%s","agent_port":%s,"protocols":%s}\n' \
        "$(json_escape "$ver")" "$(json_escape "$role")" "${count:-0}" \
        "$(json_escape "$opt")" "${TM_AGENT_PORT:-8271}" "$(api_protocols | tr -d '\n')"
}

# --- Port ownership ---------------------------------------------------------
# Each protocol keeps its server<->server port under a different TUN key, so a
# generic "is this port taken" check has to know the mapping. GRE is absent on
# purpose: it is a kernel tunnel and binds no port.
_tm_port_key() {
    case "$1" in
        gost)     printf 'GO_PORT' ;;
        backpack) printf 'BP_PORT' ;;
        backhaul) printf 'BH_PORT' ;;
        rathole)  printf 'RH_PORT' ;;
        frp)      printf 'FRP_PORT' ;;
        hysteria) printf 'HY_PORT' ;;
        paqet)    printf 'PAQET_PORT' ;;
        *)        printf '' ;;
    esac
}

# _tm_port_owner PORT [SKIP] — print the name of another tunnel already holding
# PORT (returns 1 when nobody does). Loads other profiles, so callers must not
# rely on TUN afterwards.
_tm_port_owner() {
    local port="$1" skip="${2:-}" other key val
    [[ -n "$port" ]] || return 1
    local -a names; mapfile -t names < <(list_tunnels)
    local saved_name="${TUN[NAME]:-}"
    local -A saved=(); for key in "${!TUN[@]}"; do saved["$key"]="${TUN[$key]}"; done
    local found=""
    for other in "${names[@]}"; do
        [[ -z "$other" || "$other" == "$skip" ]] && continue
        load_tunnel "$other" || continue
        key="$(_tm_port_key "${TUN[PROTOCOL]:-}")"
        [[ -n "$key" ]] || continue
        val="${TUN[$key]:-}"
        if [[ -n "$val" && "$val" == "$port" ]]; then found="$other"; break; fi
    done
    # Restore the caller's profile — load_tunnel clobbers the global TUN.
    TUN=(); for key in "${!saved[@]}"; do TUN["$key"]="${saved[$key]}"; done
    [[ -n "$saved_name" ]] && TUN[NAME]="$saved_name"
    [[ -n "$found" ]] || return 1
    printf '%s' "$found"
}

# api_ports — which server<->server port each tunnel holds, so the panel can show
# what is taken instead of letting the operator pick a doomed one.
api_ports() {
    local -a t; mapfile -t t < <(list_tunnels)
    local first=1 n key val
    printf '['
    for n in "${t[@]}"; do
        load_tunnel "$n" || continue
        key="$(_tm_port_key "${TUN[PROTOCOL]:-}")"
        [[ -n "$key" ]] || continue
        val="${TUN[$key]:-}"
        [[ -n "$val" ]] || continue
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        printf '{"name":"%s","protocol":"%s","port":"%s"}' \
            "$(json_escape "$n")" "$(json_escape "${TUN[PROTOCOL]}")" "$(json_escape "$val")"
    done
    printf ']\n'
}

# --- Non-interactive create -------------------------------------------------
# tunnel_add_kv KEY=VALUE... — create a tunnel from explicit fields (no TTY).
# The panel builds these args from its form. Secrets/ports left empty are
# auto-generated; GRE inner addressing is IPAM-allocated. Mirrors the wizard's
# persistence path (validate -> save -> install -> enable/start).
tunnel_add_kv() {
    require_root
    TUN=()
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        TUN["$k"]="$v"
    done

    local name="${TUN[NAME]:-}"
    [[ -n "$name" ]] || die "create: NAME is required"
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]] || die "create: invalid tunnel name '$name'"
    tunnel_exists "$name" && die "create: tunnel '$name' already exists"
    is_protocol "${TUN[PROTOCOL]:-}" || die "create: unknown protocol '${TUN[PROTOCOL]:-}'"

    : "${TUN[ROLE]:=foreign}"
    : "${TUN[AUTOSTART]:=yes}"
    TUN[CREATED_AT]="$(date '+%Y-%m-%d %H:%M:%S')"
    # NOTE: MTU is deliberately NOT defaulted here — each driver's <p>_prepare
    # sets its own (paqet wants 1350, others 1400), and ":=" would make a generic
    # value stick and silently override that.

    # Driver-specific derivation (IPAM for GRE, secrets/ports for userspace).
    # A driver may provide <p>_prepare for non-interactive field completion;
    # otherwise the generic secret/port fill below covers the common cases.
    if declare -F "${TUN[PROTOCOL]}_prepare" >/dev/null 2>&1; then
        "${TUN[PROTOCOL]}_prepare" || die "create: ${TUN[PROTOCOL]}_prepare failed"
    fi
    # Generic fill: any *_SECRET left empty gets a strong random value.
    for k in "${!TUN[@]}"; do
        if [[ "$k" == *_SECRET && -z "${TUN[$k]}" ]]; then
            TUN["$k"]="$(gen_secret 32)"
        fi
    done

    if declare -F driver_validate >/dev/null 2>&1; then
        driver_validate || die "create: validation failed for '$name'"
    fi

    # Port sanity. Two tunnels cannot bind the same port: the loser dies with
    # "address already in use" and systemd crash-loops it forever, while the
    # profile still looks fine. Without this the panel happily created tunnels
    # that could never come up, and it looked like "only some protocols work".
    # Deliberately an error, not an auto-shift: both ends of a tunnel must agree
    # on the port, so silently moving one side would break the pair instead.
    local _pkey _want _owner
    _pkey="$(_tm_port_key "${TUN[PROTOCOL]}")"
    if [[ -n "$_pkey" ]]; then
        _want="${TUN[$_pkey]:-}"
        if [[ -n "$_want" ]] && _owner="$(_tm_port_owner "$_want" "$name")"; then
            die "create: port $_want is already used by tunnel '$_owner' on this server. Pick a different ${_pkey}."
        fi
    fi

    save_tunnel
    if declare -F svc_install >/dev/null 2>&1; then
        svc_install "$name" || die "create: could not install service for '$name'"
    fi
    if [[ "${TUN[AUTOSTART]}" == yes ]]; then
        svc_enable "$name" 2>/dev/null || true
        if svc_start "$name"; then
            state_set "$name" STATUS up STARTED_AT "$(date +%s)" FAIL_COUNT 0
        else
            state_set "$name" STATUS down
            log_warn "create: '$name' saved but failed to start (check logs)."
        fi
    fi
    log_ok "Tunnel '$name' created."
}

# --- Dispatcher -------------------------------------------------------------
# api_dispatch SUB [args] — routes `tunnelctl json <sub>`.
api_dispatch() {
    local sub="${1:-list}"; shift || true
    case "$sub" in
        list)       api_list ;;
        tunnel)     api_tunnel_obj "${1:?tunnel name}"; echo ;;
        protocols)  api_protocols ;;
        schema)     api_schema ;;
        ports)      api_ports ;;
        fields)     api_fields "${1:?tunnel name}" ;;
        meta)       api_meta ;;
        *)          printf '{"error":"unknown json subcommand: %s"}\n' "$(json_escape "$sub")"; return 1 ;;
    esac
}
