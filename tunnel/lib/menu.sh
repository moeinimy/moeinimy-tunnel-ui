#!/usr/bin/env bash
# lib/menu.sh — the interactive, colorful management menu.

menu_main() {
    require_root
    ensure_dirs
    # The menu tolerates individual action failures without exiting.
    set +e
    local choice
    while true; do
        clear 2>/dev/null || true
        ui_banner
        tunnel_overview
        menu_print
        read -r -p "$(printf '\n%sChoose an option:%s ' "$C_BOLD" "$C_RESET")" choice || { echo; break; }
        echo
        case "$choice" in
            1)  tunnel_add ;;
            2)  tunnel_remove ;;
            3)  tunnel_edit ;;
            4)  tunnel_start ;;
            5)  tunnel_stop ;;
            6)  tunnel_restart ;;
            7)  tunnel_enable ;;
            8)  tunnel_disable ;;
            9)  tunnel_status ;;
            10) tunnel_logs ;;
            11) menu_optimize ;;
            12) menu_telegram ;;
            13) backup_create ;;
            14) backup_restore ;;
            15) menu_reports ;;
            16) selfupdate_run ;;
            17) menu_uninstall ;;
            18) tunnel_bandwidth ;;
            19) menu_peers ;;
            0|q|Q) printf 'Bye.\n'; break ;;
            *)  log_warn "Invalid option." ;;
        esac
        [[ "$choice" =~ ^(0|q|Q)$ ]] || ui_pause
    done
    set -e
}

menu_print() {
    cat <<EOF

${C_BOLD}${C_CYAN}Tunnels${C_RESET}                  ${C_BOLD}${C_CYAN}System${C_RESET}
  ${C_GREEN}1${C_RESET}) Add tunnel             ${C_GREEN}11${C_RESET}) Network optimization
  ${C_GREEN}2${C_RESET}) Remove tunnel          ${C_GREEN}12${C_RESET}) Telegram configuration
  ${C_GREEN}3${C_RESET}) Edit tunnel            ${C_GREEN}13${C_RESET}) Backup
  ${C_GREEN}4${C_RESET}) Start tunnel           ${C_GREEN}14${C_RESET}) Restore
  ${C_GREEN}5${C_RESET}) Stop tunnel            ${C_GREEN}15${C_RESET}) Reports
  ${C_GREEN}6${C_RESET}) Restart tunnel         ${C_GREEN}16${C_RESET}) Update
  ${C_GREEN}7${C_RESET}) Enable auto-start      ${C_GREEN}17${C_RESET}) Uninstall
  ${C_GREEN}8${C_RESET}) Disable auto-start     ${C_GREEN}18${C_RESET}) Bandwidth / traffic
  ${C_GREEN}9${C_RESET}) View status            ${C_GREEN}19${C_RESET}) Peers (multi-server)
 ${C_GREEN}10${C_RESET}) View logs
                                  ${C_GREEN}0${C_RESET}) Quit
EOF
}

menu_peers() {
    local c sel
    ask_menu c "Peers (auto-discovered from tunnels; controlled over the tunnel)" \
        "List / reachability" "Query a peer" "Back"
    case "$c" in
        "List / reachability") peer_overview ;;
        "Query a peer")
            local -a p; mapfile -t p < <(peer_list | cut -f1)
            [[ ${#p[@]} -gt 0 ]] || { log_warn "No peers yet (bring up a tunnel first)."; return 0; }
            ask_menu sel "Select a peer" "${p[@]}"
            printf '\n'; peer_run "$sel" list ;;
        *) : ;;
    esac
}

menu_optimize() {
    local c
    ask_menu c "Network optimization" "Apply" "Revert" "Status" "Back"
    case "$c" in
        Apply)  optimize_apply ;;
        Revert) optimize_revert ;;
        Status) optimize_status ;;
        *) : ;;
    esac
}

menu_telegram() {
    local c
    ask_menu c "Telegram" "Configure" "Send test" "Disable" "Back"
    case "$c" in
        Configure)   tg_configure ;;
        "Send test") tg_load; tg_send "🔔 Test from $(hostname)" && log_ok "Sent." || log_error "Failed (check config)." ;;
        Disable)     tg_disable ;;
        *) : ;;
    esac
}

menu_reports() {
    local c
    ask_menu c "Reports" "Show daily" "Show weekly" "Show monthly" "Send daily to Telegram" "Back"
    case "$c" in
        "Show daily")   report_show daily ;;
        "Show weekly")  report_show weekly ;;
        "Show monthly") report_show monthly ;;
        "Send daily to Telegram") report_send daily ;;
        *) : ;;
    esac
}

menu_uninstall() {
    if confirm "Uninstall Tunnel Manager, remove all tunnels and revert optimization?" no; then
        bash "$TM_HOME/uninstall.sh"
        exit 0
    fi
}
