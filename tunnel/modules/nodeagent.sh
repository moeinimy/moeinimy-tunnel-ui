#!/usr/bin/env bash
# modules/nodeagent.sh — Iran-node control agent.
#
# Runs on the Iran server. It DIALS OUT to the foreign panel over HTTPS and
# long-polls for commands, so:
#   * it needs no inbound port (works behind NAT/CGNAT),
#   * the traffic looks like ordinary HTTPS to the panel (DPI-resistant),
#   * no compiled binary is required — just curl + jq + tunnelctl.
#
# The panel queues allowlisted `tunnelctl` subcommands; this agent runs them and
# posts the output back over the same channel. Config comes from node.conf
# (PANEL_URL + NODE_TOKEN), written by scripts/install.sh --iran.
#
# The config is re-read on every cycle, NOT once at startup. Re-running the
# installer rewrites node.conf with a freshly issued token; a long-running agent
# that cached the old one would poll forever with a token the panel has since
# deleted, get 404 on every request, and sit in a silent retry loop looking
# perfectly "active" to systemd. Re-reading makes a re-install take effect
# immediately, with or without a restart.

: "${TM_NODE_CONF:=$TM_CONFIG_DIR/node.conf}"

# Same allowlist the panel enforces — read + safe control only.
_TM_NODE_ALLOW=" json list names fields start stop restart enable disable status logs create set remove optimize "

# _node_load_conf — (re)read PANEL_URL/NODE_TOKEN. Returns 1 if unusable.
_node_load_conf() {
    [[ -f "$TM_NODE_CONF" ]] || return 1
    # shellcheck source=/dev/null
    . "$TM_NODE_CONF" || return 1
    [[ -n "${PANEL_URL:-}" && -n "${NODE_TOKEN:-}" ]] || return 1
    TM_NODE_BASE="${PANEL_URL%/}"
    return 0
}

node_agent_run() {
    [[ -f "$TM_NODE_CONF" ]] || die "node agent: $TM_NODE_CONF not found (run the --iran installer)"
    have curl || die "node agent: curl is required"
    have jq   || die "node agent: jq is required"
    _node_load_conf || die "node agent: PANEL_URL/NODE_TOKEN missing in $TM_NODE_CONF"

    log_info "node agent: polling $TM_NODE_BASE (token ${NODE_TOKEN:0:6}…)"

    # _TM_NODE_LAST is the last outcome we logged. Only transitions are logged, so
    # a persistent failure states itself once instead of every 3s forever, and a
    # recovery is visible rather than silent.
    _TM_NODE_LAST=""
    while true; do
        if ! _node_load_conf; then
            _node_say conf "node agent: $TM_NODE_CONF is missing or has no PANEL_URL/NODE_TOKEN"
            sleep 5; continue
        fi
        _node_poll_once "$TM_NODE_BASE" || sleep 3
    done
}

# _node_say KEY MESSAGE — log MESSAGE only when the state KEY changed.
_node_say() {
    local key="$1"; shift
    [[ "$_TM_NODE_LAST" == "$key" ]] && return 0
    _TM_NODE_LAST="$key"
    case "$key" in
        ok) log_ok "$*" ;;
        *)  log_warn "$*" ;;
    esac
}

# One poll cycle: fetch queued commands, run the allowlisted ones, post results.
# curl -k tolerates the panel's self-signed certificate; the token authenticates
# and the channel is still TLS-encrypted.
#
# The HTTP status is captured explicitly instead of relying on curl -f, because
# "token rejected" (404) and "cannot reach the panel" (000) need very different
# operator action and previously looked identical: both just failed silently.
_node_poll_once() {
    local base="$1" code body tmp
    tmp="$(mktemp)"
    code="$(curl -sSk -m 40 -o "$tmp" -w '%{http_code}' -X POST "$base/node/poll" \
        -H 'Content-Type: application/json' \
        -d "{\"token\":\"$NODE_TOKEN\"}" 2>/dev/null)" || code="000"
    body="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"

    case "$code" in
        200) _node_say ok "node agent: connected to $base" ;;
        404)
            _node_say badtoken "node agent: panel rejected this token (node deleted, or the token was rotated by a re-install). Re-add the node in the panel and run its one-liner again."
            sleep 5; return 1 ;;
        000)
            _node_say unreachable "node agent: cannot reach $base — network, TLS or firewall. Retrying."
            return 1 ;;
        *)
            _node_say "http$code" "node agent: panel returned HTTP $code. Retrying."
            return 1 ;;
    esac

    # Iterate each command object.
    local cmd id rc out ok
    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        id="$(jq -r '.id' <<<"$cmd")"
        mapfile -t args < <(jq -r '.args[]?' <<<"$cmd")
        [[ ${#args[@]} -gt 0 ]] || continue

        if [[ "$_TM_NODE_ALLOW" != *" ${args[0]} "* ]]; then
            out="command not allowed on node: ${args[0]}"; ok=false
        else
            # TM_ASSUME_YES: destructive commands (remove/restore) prompt via
            # confirm(); with no TTY that silently answers "no" while still
            # exiting 0. The panel confirms with the operator before sending.
            log_info "node agent: running 'tunnelctl ${args[*]}'"
            out="$(TM_ASSUME_YES=1 NO_COLOR=1 tunnelctl "${args[@]}" 2>&1)"; rc=$?
            ok=true; [[ $rc -eq 0 ]] || ok=false
            [[ "$ok" == true ]] || log_warn "node agent: '${args[0]}' exited $rc"
        fi

        curl -fsSk -m 20 -X POST "$base/node/result" \
            -H 'Content-Type: application/json' \
            -d "$(jq -cn --arg t "$NODE_TOKEN" --arg id "$id" --arg out "$out" --argjson ok "$ok" \
                  '{token:$t,id:$id,output:$out,success:$ok}')" \
            >/dev/null 2>&1 || log_warn "node agent: could not post the result for '${args[0]}'"
    done < <(jq -c '.commands[]?' <<<"$body" 2>/dev/null)
    return 0
}
