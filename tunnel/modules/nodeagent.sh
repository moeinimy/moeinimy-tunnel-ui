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

# Where a node's own Xray runtime lives. Everything here is placed by the agent
# on demand — the core binary, the geo files, the config and the unit — so a node
# that was installed before any of this existed grows the ability after a normal
# `tunnelctl update`, with nothing run on that server by hand.
: "${TM_XRAY_DIR:=$TM_STATE_DIR/xray}"
: "${TM_XRAY_BIN:=$TM_XRAY_DIR/xray}"
: "${TM_XRAY_CONF:=$TM_XRAY_DIR/config.json}"
: "${TM_XRAY_UNIT:=/etc/systemd/system/tm-xray.service}"

# Fetched beside the core because routing rules reference them by name; a missing
# geo file is not fatal (Xray only fails if a rule actually uses it), so these are
# best effort while the core itself is not.
_TM_XRAY_GEO="geoip.dat geosite.dat geoip_IR.dat geosite_IR.dat geoip_RU.dat geosite_RU.dat"

# _node_asset_fetch BASE NAME DEST [MODE] — download one panel-served asset.
#
# The panel hands out the very core it runs itself, so a node can never drift onto
# a different or unpatched build, and the operator never installs anything there.
# The local file's hash is offered up front and an unchanged asset answers 304, so
# a poll costs nothing once the node is current.
_node_asset_fetch() {
    local base="$1" name="$2" dest="$3" mode="${4:-0644}" have="" code tmp
    [[ -f "$dest" ]] && have="$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1)"
    tmp="$(mktemp)"
    code="$(curl -sSk -m 600 -o "$tmp" -w '%{http_code}' \
        -H "X-Node-Token: $NODE_TOKEN" -H "X-Have-Sha256: ${have:-none}" \
        "$base/node/asset/$name" 2>/dev/null)" || code="000"
    case "$code" in
        304) rm -f "$tmp"; return 0 ;;
        200)
            # An empty body would install a broken core over a working one.
            if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; return 1; fi
            install -m "$mode" "$tmp" "$dest" && rm -f "$tmp" && return 0
            rm -f "$tmp"; return 1 ;;
        *) rm -f "$tmp"; return 1 ;;
    esac
}

# Write the unit that runs this node's core. Regenerated on every apply so a fix
# to it ships with an agent update rather than needing a visit to the server.
_node_xray_unit() {
    cat >"$TM_XRAY_UNIT" <<EOF
[Unit]
Description=Xray for a moeinimy-tunnel-ui node
After=network.target nss-lookup.target

[Service]
Type=simple
WorkingDirectory=$TM_XRAY_DIR
ExecStart=$TM_XRAY_BIN run -c $TM_XRAY_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# node_xray_apply BASE B64CONFIG — install/refresh the core and run this config.
#
# The previous config is kept until the new one is proven to run. Xray exits on a
# config it cannot parse, so a bad push would otherwise leave the node with no core
# at all and the panel reporting success — the failure would surface as every
# account on that server going dark.
node_xray_apply() {
    local base="$1" b64="$2" prev=""
    mkdir -p "$TM_XRAY_DIR"

    if ! printf '%s' "$b64" | base64 -d > "$TM_XRAY_CONF.new" 2>/dev/null; then
        rm -f "$TM_XRAY_CONF.new"
        echo "node xray: the pushed config was not valid base64"; return 1
    fi
    [[ -s "$TM_XRAY_CONF.new" ]] || { rm -f "$TM_XRAY_CONF.new"; echo "node xray: empty config"; return 1; }

    _node_asset_fetch "$base" xray "$TM_XRAY_BIN" 0755 \
        || { rm -f "$TM_XRAY_CONF.new"; echo "node xray: could not fetch the core from the panel"; return 1; }
    local g
    for g in $_TM_XRAY_GEO; do _node_asset_fetch "$base" "$g" "$TM_XRAY_DIR/$g" || true; done

    [[ -f "$TM_XRAY_CONF" ]] && prev="$(cat "$TM_XRAY_CONF")"
    mv "$TM_XRAY_CONF.new" "$TM_XRAY_CONF"

    _node_xray_unit
    systemctl enable tm-xray >/dev/null 2>&1 || true
    systemctl restart tm-xray >/dev/null 2>&1 || true

    # Give it a moment to fail: an unparsable config makes Xray exit immediately.
    sleep 1
    if systemctl is-active --quiet tm-xray; then
        echo "node xray: running ($("$TM_XRAY_BIN" version 2>/dev/null | head -n1))"
        return 0
    fi
    if [[ -n "$prev" ]]; then
        printf '%s' "$prev" > "$TM_XRAY_CONF"
        systemctl restart tm-xray >/dev/null 2>&1 || true
        echo "node xray: the new config did not start, so the previous one was restored"
    else
        echo "node xray: did not start"
    fi
    journalctl -u tm-xray -n 15 --no-pager 2>/dev/null | tail -n 15
    return 1
}

# node_xray_stop — take this node out of service as a config host.
node_xray_stop() {
    systemctl disable --now tm-xray >/dev/null 2>&1 || true
    echo "node xray: stopped"
}

# node_xray_stats — hand the panel this node's traffic counters, and reset them.
#
# The panel cannot reach this core's API itself: the node dials out and accepts
# nothing inbound. So the counters are read here and shipped back over the same
# channel, in the CLI's own JSON, which the panel feeds into the one accounting
# path it uses for its own core. Without this, accounts served by this node would
# use traffic that no quota ever saw.
#
# The API port is read from the config the panel pushed, so the two can never
# disagree about it.
node_xray_stats() {
    local port
    port="$(jq -r '.inbounds[]?|select(.tag=="api")|.port' "$TM_XRAY_CONF" 2>/dev/null | head -n1)"
    if [[ -z "$port" || "$port" == null ]]; then
        echo '{"stat":[]}'; return 0
    fi
    # -reset: the panel BILLS what it receives, so the counters must not be
    # counted twice on the next tick.
    "$TM_XRAY_BIN" api statsquery --server="127.0.0.1:$port" -reset 2>/dev/null \
        || echo '{"stat":[]}'
}

# node_xray_status — one line the panel can show.
node_xray_status() {
    local state; state="$(systemctl is-active tm-xray 2>/dev/null || true)"
    printf '{"active":%s,"version":"%s"}\n' \
        "$([[ "$state" == active ]] && echo true || echo false)" \
        "$("$TM_XRAY_BIN" version 2>/dev/null | head -n1 | tr -d '"')"
}

# Same allowlist the panel enforces — read + safe control only.
# `update` is included so the panel's backend-update button can bring this node
# up to the same version instead of leaving it silently behind; see the detached
# handling in the command loop for why it cannot be run inline.
_TM_NODE_ALLOW=" json list names fields start stop restart enable disable status logs create set remove optimize update "

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

        # Agent-native verbs first. These are NOT tunnelctl subcommands — they run
        # this node's own Xray, which the panel drives so that an inbound assigned
        # to this server needs nothing done on it by hand.
        if [[ "${args[0]}" == xray-apply ]]; then
            out="$(node_xray_apply "$base" "${args[1]:-}" 2>&1)"; rc=$?
            ok=true; [[ $rc -eq 0 ]] || ok=false
        elif [[ "${args[0]}" == xray-stop ]]; then
            out="$(node_xray_stop 2>&1)"; ok=true
        elif [[ "${args[0]}" == xray-status ]]; then
            out="$(node_xray_status 2>&1)"; ok=true
        elif [[ "${args[0]}" == xray-stats ]]; then
            out="$(node_xray_stats 2>&1)"; ok=true
        elif [[ "$_TM_NODE_ALLOW" != *" ${args[0]} "* ]]; then
            out="command not allowed on node: ${args[0]}"; ok=false
        elif [[ "${args[0]}" == update ]]; then
            # `tunnelctl update` reinstalls the code and restarts tm-node-agent —
            # this very process. Run inline, it would kill the agent before it
            # could post a result, so the panel would report a timeout on every
            # successful update. Detach it and answer immediately; the node comes
            # back on the new code and resumes polling by itself.
            log_info "node agent: starting detached 'tunnelctl update'"
            setsid bash -c "TM_ASSUME_YES=1 NO_COLOR=1 '$TM_CTL' update \
                >>'$TM_LOG_DIR/node-update.log' 2>&1" </dev/null >/dev/null 2>&1 &
            out="update started on the node; it reconnects on the new code (log: $TM_LOG_DIR/node-update.log)"
            ok=true
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
