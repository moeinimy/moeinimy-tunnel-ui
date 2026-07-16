#!/usr/bin/env bash
# modules/telegram.sh — optional Telegram notifications + interactive command bot
# with inline (glass) keyboards. The project works fully without Telegram; every
# notify call is a no-op unless a bot token and chat id are configured.

TG_API="https://api.telegram.org"

# tg_load — read telegram.conf into the environment (best-effort).
tg_load() {
    [[ -f "$TM_TELEGRAM_FILE" ]] && . "$TM_TELEGRAM_FILE"
    return 0
}

tg_enabled() {
    tg_load
    [[ "${TG_ENABLED:-no}" == yes && -n "${TG_BOT_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]]
}

# tg_send TEXT [CHAT] — plain HTML message.
tg_send() {
    local text="$1" chat="${2:-$TG_CHAT_ID}"
    [[ -n "${TG_BOT_TOKEN:-}" && -n "$chat" ]] || return 1
    curl -fsS --max-time 20 \
        -d "chat_id=${chat}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# tg_send_kb TEXT KEYBOARD_JSON [CHAT] — message with an inline keyboard.
tg_send_kb() {
    local text="$1" kb="$2" chat="${3:-$TG_CHAT_ID}"
    [[ -n "${TG_BOT_TOKEN:-}" && -n "$chat" ]] || return 1
    curl -fsS --max-time 20 \
        -d "chat_id=${chat}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        --data-urlencode "reply_markup=${kb}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# tg_send_force TEXT [CHAT] — message that forces the user's next message to be a
# reply to it (used by the button-based edit flow to collect a value).
tg_send_force() {
    local text="$1" chat="${2:-$TG_CHAT_ID}"
    [[ -n "${TG_BOT_TOKEN:-}" && -n "$chat" ]] || return 1
    curl -fsS --max-time 20 \
        -d "chat_id=${chat}" -d "parse_mode=HTML" -d "disable_web_page_preview=true" \
        --data-urlencode "text=${text}" \
        --data-urlencode 'reply_markup={"force_reply":true,"input_field_placeholder":"new value"}' \
        "${TG_API}/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# tg_set_commands — register the "/" command menu (shows next to the input box).
tg_set_commands() {
    [[ -n "${TG_BOT_TOKEN:-}" ]] || return 1
    curl -fsS --max-time 15 --data-urlencode \
        'commands=[{"command":"menu","description":"Open the button menu"},{"command":"status","description":"Tunnels status"},{"command":"tunnels","description":"Control a tunnel (restart/start/stop…)"},{"command":"bandwidth","description":"Live bandwidth"},{"command":"usage","description":"Traffic usage by period"},{"command":"system","description":"Server system info"},{"command":"peers","description":"Control other servers"},{"command":"report","description":"Daily report"},{"command":"update","description":"Update script (this server + Iran peers)"}]' \
        "${TG_API}/bot${TG_BOT_TOKEN}/setMyCommands" >/dev/null 2>&1
    # The "Menu" button next to the chat opens the command list (no /start needed).
    curl -fsS --max-time 15 --data-urlencode 'menu_button={"type":"commands"}' \
        "${TG_API}/bot${TG_BOT_TOKEN}/setChatMenuButton" >/dev/null 2>&1
}

# tg_reply_kb — a persistent keyboard that stays under the chat input box.
tg_reply_kb() {
    printf '%s' '{"keyboard":[["📊 Status","📈 Bandwidth"],["📅 Usage","🖥 System"],["🚇 Tunnels","🌐 Peers"]],"resize_keyboard":true,"is_persistent":true}'
}

# tg_answer_callback ID [TEXT] — acknowledge a button tap (stops the spinner).
tg_answer_callback() {
    local cid="$1" text="${2:-}"
    curl -fsS --max-time 10 \
        -d "callback_query_id=${cid}" --data-urlencode "text=${text}" \
        "${TG_API}/bot${TG_BOT_TOKEN}/answerCallbackQuery" >/dev/null 2>&1
}

# tg_notify TEXT — fire-and-forget notification; never fails the caller.
tg_notify() {
    tg_enabled || return 0
    tg_send "$1" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
tg_configure() {
    require_root
    ui_title "Telegram configuration"
    tg_load
    local token chat
    ask token "Bot token (from @BotFather)" "${TG_BOT_TOKEN:-}"
    ask chat  "Chat ID (numeric; from @userinfobot)" "${TG_CHAT_ID:-}"
    if [[ -z "$token" || -z "$chat" ]]; then
        log_warn "Both token and chat id are required; leaving Telegram disabled."
        return 1
    fi
    umask 077
    cat >"$TM_TELEGRAM_FILE" <<EOF
# Managed by Tunnel Manager. Keep this file private (chmod 600).
TG_ENABLED=yes
TG_BOT_TOKEN=$token
TG_CHAT_ID=$chat
EOF
    chmod 600 "$TM_TELEGRAM_FILE"
    tg_load
    if tg_send "✅ <b>Tunnel Manager</b> connected on $(hostname)."; then
        log_ok "Telegram configured and test message sent."
        tg_set_commands
        # Persistent keyboard under the input box + inline menu.
        tg_send_kb "Quick buttons are ready 👇" "$(tg_reply_kb)" >/dev/null 2>&1 || true
        tg_send_kb "Or use the full menu:" "$(tg_kb_main)" >/dev/null 2>&1 || true
        systemctl enable --now tm-bot.service >/dev/null 2>&1 || \
            log_warn "Could not start tm-bot.service (is it installed?)."
    else
        log_error "Test message failed — send /start to your bot first, then retry."
        return 1
    fi
}

tg_disable() {
    require_root
    [[ -f "$TM_TELEGRAM_FILE" ]] && sed -i 's/^TG_ENABLED=.*/TG_ENABLED=no/' "$TM_TELEGRAM_FILE"
    systemctl disable --now tm-bot.service >/dev/null 2>&1 || true
    log_ok "Telegram disabled."
}

# ---------------------------------------------------------------------------
# Inline keyboards
# ---------------------------------------------------------------------------
tg_kb_main() {
    printf '%s' '{"inline_keyboard":[[{"text":"📊 Status","callback_data":"status"},{"text":"🖥 System","callback_data":"system"}],[{"text":"📈 Bandwidth","callback_data":"bandwidth"},{"text":"📅 Usage","callback_data":"usage"}],[{"text":"🚇 Tunnels","callback_data":"tunnels"},{"text":"🔄 Restart","callback_data":"restart_menu"}],[{"text":"📋 Report","callback_data":"report"},{"text":"🌐 Peers","callback_data":"peers"}],[{"text":"⬆️ Update","callback_data":"update_confirm"},{"text":"♻️ Reboot","callback_data":"reboot_confirm"}]]}'
}

# tg_kb_tunnels ACTION — one button per tunnel with callback "ACTION:name".
tg_kb_tunnels() {
    local action="$1" name rows=""
    while read -r name; do
        [[ -n "$name" ]] || continue
        rows+="${rows:+,}[{\"text\":\"🚇 ${name}\",\"callback_data\":\"${action}:${name}\"}]"
    done < <(list_tunnels)
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"menu\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

tg_kb_peers() {
    local name rows=""
    while IFS=$'\t' read -r name _; do
        [[ -n "$name" ]] || continue
        rows+="${rows:+,}[{\"text\":\"🌐 ${name}\",\"callback_data\":\"peer:${name}\"}]"
    done < <(peer_list 2>/dev/null)
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"menu\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

# tg_kb_tun_actions NAME — full control menu for one LOCAL tunnel.
tg_kb_tun_actions() {
    local n="$1"
    printf '{"inline_keyboard":[[{"text":"🔄 Restart","callback_data":"tact:%s:restart"},{"text":"▶️ Start","callback_data":"tact:%s:start"},{"text":"⏹ Stop","callback_data":"tact:%s:stop"}],[{"text":"✅ Enable","callback_data":"tact:%s:enable"},{"text":"🚫 Disable","callback_data":"tact:%s:disable"}],[{"text":"✏️ Edit","callback_data":"tedit:%s"},{"text":"📜 Logs","callback_data":"tact:%s:logs"}],[{"text":"« Tunnels","callback_data":"tunnels"},{"text":"« Menu","callback_data":"menu"}]]}' \
        "$n" "$n" "$n" "$n" "$n" "$n" "$n"
}

# tg_kb_tun_fields NAME — one button per editable field of a LOCAL tunnel.
tg_kb_tun_fields() {
    local n="$1" k v rows=""
    if load_tunnel "$n" 2>/dev/null; then
        while read -r k; do
            [[ "$_TM_NOEDIT_KEYS" == *" $k "* ]] && continue
            v="${TUN[$k]}"; [[ ${#v} -gt 18 ]] && v="${v:0:18}…"
            rows+="${rows:+,}[{\"text\":\"✏️ ${k} = ${v}\",\"callback_data\":\"tsetk:${n}:${k}\"}]"
        done < <(printf '%s\n' "${!TUN[@]}" | sort)
    fi
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"tun:${n}\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

# tg_kb_peer_fields PEER TUN — one button per editable field of a REMOTE tunnel.
tg_kb_peer_fields() {
    local p="$1" t="$2" line k v rows=""
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        k="${line%%=*}"; v="${line#*=}"; [[ ${#v} -gt 18 ]] && v="${v:0:18}…"
        rows+="${rows:+,}[{\"text\":\"✏️ ${k} = ${v}\",\"callback_data\":\"psetk:${p}:${t}:${k}\"}]"
    done < <(peer_run "$p" fields "$t" 2>/dev/null | grep -viE 'unreachable|denied|forbidden|no such')
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"ptun:${p}:${t}\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

# tg_kb_peer NAME — control menu for a remote peer server.
tg_kb_peer() {
    local n="$1"
    printf '{"inline_keyboard":[[{"text":"📊 Overview","callback_data":"pov:%s"},{"text":"🚇 Manage tunnels","callback_data":"pnames:%s"}],[{"text":"« Peers","callback_data":"peers"},{"text":"« Menu","callback_data":"menu"}]]}' \
        "$n" "$n"
}

# tg_kb_peer_tuns PEER — one button per tunnel on the peer (queried live).
tg_kb_peer_tuns() {
    local peer="$1" t rows=""
    while read -r t; do
        [[ -n "$t" ]] || continue
        rows+="${rows:+,}[{\"text\":\"🚇 ${t}\",\"callback_data\":\"ptun:${peer}:${t}\"}]"
    done < <(peer_run "$peer" names 2>/dev/null | grep -viE 'unreachable|denied|forbidden')
    rows+="${rows:+,}[{\"text\":\"« Back\",\"callback_data\":\"peer:${peer}\"}]"
    printf '{"inline_keyboard":[%s]}' "$rows"
}

# tg_kb_peer_tun_actions PEER TUN — action menu for one remote tunnel.
tg_kb_peer_tun_actions() {
    local p="$1" t="$2"
    printf '{"inline_keyboard":[[{"text":"🔄 Restart","callback_data":"pact:%s:%s:restart"},{"text":"▶️ Start","callback_data":"pact:%s:%s:start"},{"text":"⏹ Stop","callback_data":"pact:%s:%s:stop"}],[{"text":"✅ Enable","callback_data":"pact:%s:%s:enable"},{"text":"🚫 Disable","callback_data":"pact:%s:%s:disable"}],[{"text":"✏️ Edit","callback_data":"pedit:%s:%s"},{"text":"📊 Status","callback_data":"pact:%s:%s:status"},{"text":"📜 Logs","callback_data":"pact:%s:%s:logs"}],[{"text":"« Back","callback_data":"pnames:%s"}]]}' \
        "$p" "$t" "$p" "$t" "$p" "$t" "$p" "$t" "$p" "$t" "$p" "$t" "$p" "$t" "$p" "$t" "$p"
}

# ---------------------------------------------------------------------------
# Bot loop (handles both text commands and button callbacks)
# ---------------------------------------------------------------------------
tg_bot_run() {
    tg_enabled || { log_warn "Telegram not configured; bot exiting."; return 0; }
    log_info "Telegram bot started."
    tg_set_commands || true
    local offset=0 resp n i chat text cb_id cb_chat cb_data rto
    while true; do
        resp="$(curl -fsS --max-time 60 \
            "${TG_API}/bot${TG_BOT_TOKEN}/getUpdates?timeout=50&offset=${offset}&allowed_updates=%5B%22message%22%2C%22callback_query%22%5D" 2>/dev/null)" || { sleep 3; continue; }
        n="$(printf '%s' "$resp" | jq '.result | length' 2>/dev/null || echo 0)"
        [[ "$n" =~ ^[0-9]+$ ]] || { sleep 2; continue; }
        for (( i=0; i<n; i++ )); do
            offset="$(( $(printf '%s' "$resp" | jq -r ".result[$i].update_id") + 1 ))"
            cb_id="$(printf '%s' "$resp" | jq -r ".result[$i].callback_query.id // empty")"
            if [[ -n "$cb_id" ]]; then
                cb_chat="$(printf '%s' "$resp" | jq -r ".result[$i].callback_query.message.chat.id // empty")"
                cb_data="$(printf '%s' "$resp" | jq -r ".result[$i].callback_query.data // empty")"
                tg_answer_callback "$cb_id"
                [[ "$cb_chat" == "$TG_CHAT_ID" ]] || { tg_send "⛔ Unauthorized." "$cb_chat"; continue; }
                tg_action "$cb_data" "$cb_chat"
                continue
            fi
            chat="$(printf '%s' "$resp" | jq -r ".result[$i].message.chat.id // empty")"
            text="$(printf '%s' "$resp" | jq -r ".result[$i].message.text // empty")"
            rto="$(printf '%s' "$resp" | jq -r ".result[$i].message.reply_to_message.text // empty")"
            [[ -n "$text" ]] || continue
            [[ "$chat" == "$TG_CHAT_ID" ]] || { tg_send "⛔ Unauthorized." "$chat"; continue; }
            # A reply to a "🔧 EDIT/PEER …" prompt carries the value for a button edit.
            if [[ "$rto" == *"🔧 EDIT "* || "$rto" == *"🔧 PEER "* ]]; then
                tg_apply_edit "$rto" "$text" "$chat"
            else
                tg_command "$text" "$chat"
            fi
        done
    done
}

# tg_apply_edit MARKER VALUE CHAT — a button-edit reply arrived. MARKER is the
# quoted prompt text containing "🔧 EDIT <tunnel> <key>" (local) or
# "🔧 PEER <peer> <tunnel> <key>" (remote); VALUE is the user's reply.
tg_apply_edit() {
    local marker="$1" value="$2" chat="$3" line
    line="$(printf '%s\n' "$marker" | grep -m1 '🔧 ')"
    line="${line#*🔧 }"
    # shellcheck disable=SC2086
    set -- $line
    case "$1" in
        EDIT)
            local n="$2" k="$3"
            if tunnel_set "$n" "$k" "$value" >/dev/null 2>&1; then
                tg_send "✏️ Set <b>${k}=${value}</b> on <b>${n}</b> (restarted)." "$chat"
            else tg_send "❌ Edit failed on <b>${n}</b> — check the value." "$chat"; fi ;;
        PEER)
            local p="$2" t="$3" k="$4"
            tg_send "🌐 <b>${p}</b>: setting ${k}…" "$chat"
            tg_send "<pre>$(peer_run "$p" set "$t" "$k" "$value" 2>&1 | tail -c 2500)</pre>" "$chat" ;;
        *)  tg_send "⚠️ Could not parse the edit target." "$chat" ;;
    esac
}

# tg_command "TEXT" CHAT — map a typed command to an action.
tg_command() {
    local line="$1" chat="$2" cmd arg
    # Persistent reply-keyboard buttons arrive as plain text — map them first.
    case "$line" in
        "📊 Status")    tg_action status "$chat";    return ;;
        "📈 Bandwidth") tg_action bandwidth "$chat"; return ;;
        "📅 Usage")     tg_action usage "$chat";     return ;;
        "🖥 System")    tg_action system "$chat";    return ;;
        "🚇 Tunnels")   tg_action tunnels "$chat";   return ;;
        "🌐 Peers")     tg_action peers "$chat";     return ;;
    esac
    cmd="${line%% *}"; cmd="${cmd%%@*}"
    arg="${line#"$cmd"}"; arg="${arg# }"
    case "$cmd" in
        /start|/menu|/help) tg_action menu "$chat" ;;
        /status)            tg_action status "$chat" ;;
        /tunnels)           tg_action tunnels "$chat" ;;
        /system)            tg_action system "$chat" ;;
        /bandwidth)         tg_action bandwidth "$chat" ;;
        /usage|/traffic)    tg_action usage "$chat" ;;
        /report)            tg_action report "$chat" ;;
        /peers)             tg_action peers "$chat" ;;
        /reboot)            tg_action reboot_confirm "$chat" ;;
        /update)            tg_action update_confirm "$chat" ;;
        /logs)              tg_action "logs:$arg" "$chat" ;;
        /restart)
            if [[ -n "$arg" ]]; then tg_action "restart:$arg" "$chat"
            else tg_action restart_menu "$chat"; fi ;;
        /set)
            # /set <tunnel> <KEY> <VALUE> — edit a local field non-interactively.
            local st sk sv; read -r st sk sv <<<"$arg"
            if [[ -n "$st" && -n "$sk" ]]; then
                if tunnel_set "$st" "$sk" "$sv" >/dev/null 2>&1; then tg_send "✏️ Set <b>${sk}=${sv}</b> on <b>${st}</b> (restarted)." "$chat"
                else tg_send "❌ set failed — check tunnel name and field." "$chat"; fi
            else tg_send "Usage: <code>/set &lt;tunnel&gt; &lt;KEY&gt; &lt;VALUE&gt;</code>" "$chat"; fi ;;
        /peer)
            # /peer <server> <cmd> [args] — control a remote peer (incl. set/edit).
            local psrv prem; psrv="${arg%% *}"; prem="${arg#"$psrv"}"; prem="${prem# }"
            if [[ -n "$psrv" && -n "$prem" ]]; then
                # shellcheck disable=SC2086
                tg_send "🌐 <b>${psrv}</b>:\n<pre>$(peer_run "$psrv" $prem 2>&1 | tail -c 3200)</pre>" "$chat"
            else tg_send "Usage: <code>/peer &lt;server&gt; &lt;list|status|restart|start|stop|enable|disable|set&gt; [args]</code>\nExample: <code>/peer iran set bp BP_PORT 9000</code>" "$chat"; fi ;;
        *) tg_send "Unknown command. Send /menu." "$chat" ;;
    esac
}

# tg_action DATA CHAT — the single handler for buttons and commands.
tg_action() {
    local data="$1" chat="$2"
    case "$data" in
        menu)        tg_send_kb "🚇 <b>Tunnel Manager</b> — $(hostname)\nChoose an option:" "$(tg_kb_main)" "$chat" ;;
        status)      tg_send "$(tg_report_tunnels)" "$chat" ;;
        tunnels)     tg_send_kb "🚇 <b>Tunnels</b> — pick one to control:" "$(tg_kb_tunnels tun)" "$chat" ;;
        tun:*)
            local tsel="${data#tun:}"
            if tunnel_exists "$tsel"; then tg_send_kb "🚇 <b>${tsel}</b> — choose an action:" "$(tg_kb_tun_actions "$tsel")" "$chat"
            else tg_send "No such tunnel: $tsel" "$chat"; fi ;;
        tact:*)
            local trest="${data#tact:}" tn ta
            tn="${trest%%:*}"; ta="${trest##*:}"
            if ! tunnel_exists "$tn"; then tg_send "No such tunnel: $tn" "$chat"
            else case "$ta" in
                restart) tunnel_restart "$tn" >/dev/null 2>&1 && tg_send "🔄 Restarted <b>$tn</b>." "$chat" || tg_send "❌ Restart of <b>$tn</b> failed." "$chat" ;;
                start)   tunnel_start "$tn"   >/dev/null 2>&1 && tg_send "▶️ Started <b>$tn</b>." "$chat"   || tg_send "❌ Start of <b>$tn</b> failed." "$chat" ;;
                stop)    tunnel_stop "$tn"    >/dev/null 2>&1 && tg_send "⏹ Stopped <b>$tn</b>." "$chat" ;;
                enable)  tunnel_enable "$tn"  >/dev/null 2>&1 && tg_send "✅ Auto-start ON for <b>$tn</b>." "$chat" ;;
                disable) tunnel_disable "$tn" >/dev/null 2>&1 && tg_send "🚫 Auto-start OFF for <b>$tn</b>." "$chat" ;;
                logs)    local lb; lb="$(journalctl -u "$(unit_name "$tn")" -n 20 --no-pager 2>/dev/null | tail -c 3000)"; tg_send "<b>Logs ${tn}</b>\n<pre>${lb:-no logs}</pre>" "$chat" ;;
            esac; fi ;;
        system)      tg_send "$(tg_report_system)" "$chat" ;;
        bandwidth)   tg_send "$(tg_report_bandwidth)" "$chat" ;;
        usage)       tg_send "$(report_usage)" "$chat" ;;
        report)      tg_send "$(report_build daily)" "$chat" ;;
        peers)       tg_send_kb "🌐 <b>Peers</b> — tap to view a remote server:" "$(tg_kb_peers)" "$chat" ;;
        restart_menu)tg_send_kb "🔄 Pick a tunnel to restart:" "$(tg_kb_tunnels restart)" "$chat" ;;
        restart:*)
            local rn="${data#restart:}"
            if tunnel_exists "$rn"; then
                tunnel_restart "$rn" >/dev/null 2>&1 && tg_send "🔄 Restarted <b>$rn</b>." "$chat" || tg_send "❌ Restart of <b>$rn</b> failed." "$chat"
            else tg_send "No such tunnel: $rn" "$chat"; fi ;;
        logs:*)
            local ln="${data#logs:}" body
            body="$(journalctl -u "$(unit_name "$ln")" -n 20 --no-pager 2>/dev/null | tail -c 3500)"
            tg_send "<b>Logs ${ln}</b>\n<pre>${body:-no logs}</pre>" "$chat" ;;
        peer:*)
            local pn="${data#peer:}"
            tg_send_kb "🌐 <b>${pn}</b> — remote server control:" "$(tg_kb_peer "$pn")" "$chat" ;;
        pov:*)
            local pov="${data#pov:}"
            tg_send "🌐 Querying <b>$pov</b>…" "$chat"
            tg_send "<b>$pov</b>\n<pre>$(peer_run "$pov" list 2>&1 | tail -c 3200)</pre>" "$chat" ;;
        pnames:*)
            local pnm="${data#pnames:}"
            tg_send_kb "🚇 <b>${pnm}</b> tunnels — pick one:" "$(tg_kb_peer_tuns "$pnm")" "$chat" ;;
        ptun:*)
            local prest="${data#ptun:}" pp tt
            pp="${prest%%:*}"; tt="${prest#*:}"
            tg_send_kb "🚇 <b>${pp} / ${tt}</b> — choose an action:" "$(tg_kb_peer_tun_actions "$pp" "$tt")" "$chat" ;;
        pact:*)
            local arest="${data#pact:}" pp tt aa
            pp="${arest%%:*}"; arest="${arest#*:}"; tt="${arest%%:*}"; aa="${arest##*:}"
            tg_send "🌐 <b>${pp}</b>: ${aa} <b>${tt}</b>…" "$chat"
            tg_send "<pre>$(peer_run "$pp" "$aa" "$tt" 2>&1 | tail -c 3000)</pre>" "$chat" ;;
        tedit:*)
            local ten="${data#tedit:}"
            if tunnel_exists "$ten"; then tg_send_kb "✏️ <b>${ten}</b> — pick a field to edit:" "$(tg_kb_tun_fields "$ten")" "$chat"
            else tg_send "No such tunnel: $ten" "$chat"; fi ;;
        tsetk:*)
            local sr="${data#tsetk:}" sn sk cur=""
            sn="${sr%%:*}"; sk="${sr#*:}"
            if tunnel_exists "$sn"; then load_tunnel "$sn"; cur="${TUN[$sk]:-}"; fi
            tg_send_force "✏️ New value for <b>${sk}</b> on <b>${sn}</b>?\nCurrent: <code>${cur}</code>\n↩️ <i>Reply to this message with the new value.</i>\n🔧 EDIT ${sn} ${sk}" "$chat" ;;
        pedit:*)
            local per="${data#pedit:}" pp tt
            pp="${per%%:*}"; tt="${per#*:}"
            tg_send_kb "✏️ <b>${pp}/${tt}</b> — pick a field to edit:" "$(tg_kb_peer_fields "$pp" "$tt")" "$chat" ;;
        psetk:*)
            local qr="${data#psetk:}" pp tt kk
            pp="${qr%%:*}"; qr="${qr#*:}"; tt="${qr%%:*}"; kk="${qr##*:}"
            tg_send_force "✏️ New value for <b>${kk}</b> on <b>${pp}/${tt}</b>?\n↩️ <i>Reply to this message with the new value.</i>\n🔧 PEER ${pp} ${tt} ${kk}" "$chat" ;;
        reboot_confirm)
            tg_send_kb "♻️ Reboot <b>$(hostname)</b>?" '{"inline_keyboard":[[{"text":"✅ Yes, reboot","callback_data":"reboot_yes"},{"text":"« Cancel","callback_data":"menu"}]]}' "$chat" ;;
        reboot_yes)  tg_send "♻️ Rebooting $(hostname) in 3s…" "$chat"; ( sleep 3; systemctl reboot ) & ;;
        update_confirm)
            tg_send_kb "⬆️ Update <b>$(hostname)</b> to the latest script from GitHub?\nConnected Iran peers get updated too. The bot restarts at the end." \
                '{"inline_keyboard":[[{"text":"✅ Yes, update all","callback_data":"update_yes"},{"text":"« Cancel","callback_data":"menu"}]]}' "$chat" ;;
        update_yes)  tg_do_update "$chat" ;;
        *) tg_send "Unknown action." "$chat" ;;
    esac
}

# tg_do_update CHAT — update connected Iran peers first (while this bot is still
# alive), then update THIS server detached (its reinstall restarts the bot, whose
# own tg_notify sends the final ✅). Triggered by the ⬆️ Update button.
tg_do_update() {
    local chat="$1" pn pip any=0 out
    tg_send "⬆️ <b>Update</b> started on $(hostname)…" "$chat"
    local -A seen=()
    while IFS=$'\t' read -r pn pip; do
        [[ -n "$pn" && -n "$pip" ]] || continue
        [[ -n "${seen[$pip]:-}" ]] && continue      # one update per remote IP
        seen[$pip]=1; any=1
        tg_send "🌐 Updating peer <b>${pn}</b> (${pip})… up to ~2 min." "$chat"
        out="$(TQ_TIMEOUT=180 peer_run "$pn" update 2>&1 | tail -c 1200)"
        tg_send "🌐 <b>${pn}</b>:\n<pre>${out:-no response}</pre>" "$chat"
    done < <(peer_list 2>/dev/null)
    (( any )) || tg_send "ℹ️ No connected peers to update." "$chat"
    tg_send "⬆️ Updating <b>$(hostname)</b> now; the bot restarts and sends a ✅ when done." "$chat"
    setsid bash -c "'$TM_CTL' update" >/dev/null 2>&1 &
}

# ---------------------------------------------------------------------------
# Report builders
# ---------------------------------------------------------------------------
tg_report_tunnels() {
    local out="🚇 <b>Tunnels — $(hostname)</b>\n" n active
    local -a t; mapfile -t t < <(list_tunnels)
    [[ ${#t[@]} -eq 0 ]] && { printf 'No tunnels configured.'; return; }
    for n in "${t[@]}"; do
        load_tunnel "$n"; state_load "$n"
        active="🔴"; svc_is_active "$n" && active="🟢"
        out+="${active} <b>${n}</b> ${TUN[PROTOCOL]}/${TUN[ROLE]} → ${TUN[REMOTE_IP]:-?}"
        out+="  (${ST[LATENCY_MS]:-?}ms, loss ${ST[LOSS_PCT]:-?}%)\n"
    done
    printf '%b' "$out"
}

tg_report_system() {
    local load mem disk up cpu
    load="$(cut -d' ' -f1-3 /proc/loadavg)"
    mem="$(free -m | awk '/^Mem:/{printf "%d/%d MiB (%d%%)", $3, $2, ($2?$3*100/$2:0)}')"
    disk="$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    up="$(human_duration "$(cut -d. -f1 /proc/uptime)")"
    [[ -f "$TM_SYS_STATE" ]] && cpu="$(. "$TM_SYS_STATE"; echo "${CPU_PCT:-?}")"
    printf '🖥 <b>System — %s</b>\nUptime: %s\nCPU: %s%%   Load: %s\nRAM: %s\nDisk /: %s' \
        "$(hostname)" "$up" "${cpu:-?}" "$load" "$mem" "$disk"
}

tg_report_bandwidth() {
    local out="📈 <b>Bandwidth — $(hostname)</b>\n" n
    local -a t; mapfile -t t < <(list_tunnels)
    [[ ${#t[@]} -eq 0 ]] && { printf 'No tunnels.'; return; }
    for n in "${t[@]}"; do
        state_load "$n"
        out+="<b>${n}</b>\n"
        out+="  now  ↓ $(human_bytes "${ST[RX_RATE]:-0}")/s  ↑ $(human_bytes "${ST[TX_RATE]:-0}")/s\n"
        out+="  peak ↓ $(human_bytes "${ST[PEAK_RX_RATE]:-0}")/s  ↑ $(human_bytes "${ST[PEAK_TX_RATE]:-0}")/s\n"
        out+="  total ↓ $(human_bytes "${ST[RX_BYTES]:-0}")  ↑ $(human_bytes "${ST[TX_BYTES]:-0}")\n"
    done
    printf '%b' "$out"
}
