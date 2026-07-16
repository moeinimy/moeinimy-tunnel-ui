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

: "${TM_NODE_CONF:=$TM_CONFIG_DIR/node.conf}"

# Same allowlist the panel enforces — read + safe control only.
_TM_NODE_ALLOW=" json list names fields start stop restart enable disable status logs create set remove optimize "

node_agent_run() {
    [[ -f "$TM_NODE_CONF" ]] || die "node agent: $TM_NODE_CONF not found (run the --iran installer)"
    # shellcheck source=/dev/null
    . "$TM_NODE_CONF"
    [[ -n "${PANEL_URL:-}" && -n "${NODE_TOKEN:-}" ]] || die "node agent: PANEL_URL/NODE_TOKEN missing in $TM_NODE_CONF"
    have curl || die "node agent: curl is required"
    have jq   || die "node agent: jq is required"

    local base="${PANEL_URL%/}"
    log_info "node agent: polling $base (token ${NODE_TOKEN:0:6}…)"

    while true; do
        _node_poll_once "$base" || sleep 3
    done
}

# One poll cycle: fetch queued commands, run the allowlisted ones, post results.
# curl -k tolerates the panel's self-signed certificate; the token authenticates
# and the channel is still TLS-encrypted.
_node_poll_once() {
    local base="$1" resp
    resp="$(curl -fsSk -m 40 -X POST "$base/node/poll" \
        -H 'Content-Type: application/json' \
        -d "{\"token\":\"$NODE_TOKEN\"}" 2>/dev/null)" || return 1

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
            out="$(TM_ASSUME_YES=1 NO_COLOR=1 tunnelctl "${args[@]}" 2>&1)"; rc=$?
            ok=true; [[ $rc -eq 0 ]] || ok=false
        fi

        curl -fsSk -m 20 -X POST "$base/node/result" \
            -H 'Content-Type: application/json' \
            -d "$(jq -cn --arg t "$NODE_TOKEN" --arg id "$id" --arg out "$out" --argjson ok "$ok" \
                  '{token:$t,id:$id,output:$out,success:$ok}')" \
            >/dev/null 2>&1 || true
    done < <(jq -c '.commands[]?' <<<"$resp" 2>/dev/null)
    return 0
}
