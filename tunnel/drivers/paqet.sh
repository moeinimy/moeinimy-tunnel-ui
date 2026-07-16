#!/usr/bin/env bash
# drivers/paqet.sh — Paqet (userspace, raw-socket KCP) transport driver.
#
# Paqet is a statically-linked Go binary (github.com/hanselime/paqet) that
# tunnels traffic as encrypted KCP-over-raw-TCP, resistant to DPI. It runs as a
# long-lived systemd service; this driver installs the binary, renders a YAML
# config, and manages the NOTRACK/anti-RST firewall rules it needs.
#
# Relevant TUN keys:
#   ROLE(iran->client|foreign->server) LOCAL_IP REMOTE_IP PAQET_PORT PAQET_SECRET
#   PAQET_MODE PAQET_CIPHER PAQET_CONN MTU PAQET_IFACE PAQET_MAC
#   PAQET_TRAFFIC(forward|socks5) FORWARDS PAQET_SOCKS_PORT PAQET_TARGET_HOST

: "${PAQET_REPO:=hanselime/paqet}"
: "${PAQET_DEFAULT_VERSION:=v1.0.0-alpha.20}"

paqet_bin() { printf '%s/paqet' "$TM_BIN_DIR"; }
paqet_cfg() { printf '%s/%s.yaml' "$TM_PAQET_DIR" "$1"; }

# paqet_arch -> amd64|arm64|arm32|unsupported
paqet_arch() {
    case "$(uname -m)" in
        x86_64|amd64)        echo amd64 ;;
        aarch64|arm64)       echo arm64 ;;
        armv7l|armv7|armhf)  echo arm32 ;;
        *)                   echo unsupported ;;
    esac
}

# paqet_latest_version — resolve latest release tag, fall back to pinned value.
paqet_latest_version() {
    local v=""
    v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${PAQET_REPO}/releases/latest" 2>/dev/null \
         | jq -r '.tag_name // empty' 2>/dev/null)"
    printf '%s' "${v:-$PAQET_DEFAULT_VERSION}"
}

# paqet_is_elf FILE — true if FILE begins with the ELF magic (0x7f 'E' 'L' 'F').
# This is the reliable test for a real binary; filename/execute-bit are not.
paqet_is_elf() {
    local f="$1" magic
    [[ -f "$f" ]] || return 1
    magic="$(head -c4 "$f" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')"
    [[ "$magic" == "7f454c46" ]]
}

# paqet_ensure_binary — download & install the Paqet binary if missing/invalid.
paqet_ensure_binary() {
    local bin; bin="$(paqet_bin)"
    # Accept an existing binary only if it is a genuine ELF; otherwise replace it.
    if paqet_is_elf "$bin"; then return 0; fi
    [[ -e "$bin" ]] && { log_warn "Existing $bin is not a valid ELF binary — replacing it."; rm -f "$bin"; }

    local arch; arch="$(paqet_arch)"
    [[ "$arch" == unsupported ]] && { log_error "unsupported CPU architecture: $(uname -m)"; return 1; }

    local ver asset url tmp
    ver="${PAQET_VERSION:-$(paqet_latest_version)}"
    asset="paqet-linux-${arch}-${ver}.tar.gz"
    url="https://github.com/${PAQET_REPO}/releases/download/${ver}/${asset}"
    tmp="$(mktemp -d)"

    log_info "Downloading Paqet ${ver} (${arch})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/$asset" "$url"; then
        rm -rf "$tmp"
        log_error "Failed to download Paqet from $url"
        log_error "Set PAQET_VERSION/PAQET_REPO in $TM_SETTINGS_FILE or place the binary at $bin manually."
        return 1
    fi
    if ! tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"; log_error "Archive is not a valid tar.gz (download may have returned an error page)."; return 1
    fi

    # Pick the first extracted file that is actually an ELF binary — robust to
    # whatever the archive names it (paqet_linux_amd64, paqet, etc.).
    local f found=""
    while IFS= read -r f; do
        if paqet_is_elf "$f"; then found="$f"; break; fi
    done < <(find "$tmp" -type f | sort)
    if [[ -z "$found" ]]; then
        rm -rf "$tmp"; log_error "No ELF binary found inside the Paqet archive."; return 1
    fi

    mkdir -p "$TM_BIN_DIR"
    install -m 0755 "$found" "$bin"
    rm -rf "$tmp"
    if ! paqet_is_elf "$bin"; then log_error "Installed file failed ELF validation."; return 1; fi
    log_ok "Installed Paqet binary -> $bin"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
paqet_wizard() {
    local mode_role="server"
    [[ "${TUN[ROLE]}" == iran ]] && mode_role="client"
    TUN[PAQET_ROLE]="$mode_role"

    local def_local def_iface def_mac
    def_local="$(detect_local_ip)"
    def_iface="$(detect_wan_iface)"
    def_mac="$(detect_gateway_mac)"

    ask_valid TUN[LOCAL_IP] "This server's public IP" is_ipv4 "$def_local"
    if [[ "$mode_role" == client ]]; then
        ask_valid TUN[REMOTE_IP] "Server (foreign) public IP" is_ipv4
    else
        TUN[REMOTE_IP]="${TUN[REMOTE_IP]:-0.0.0.0}"
    fi
    ask_valid TUN[PAQET_PORT] "Paqet port" is_port 4000
    ask TUN[PAQET_SECRET] "Shared secret (blank = auto-generate)" ""
    [[ -n "${TUN[PAQET_SECRET]}" ]] || TUN[PAQET_SECRET]="$(gen_secret 32)"

    ask_menu TUN[PAQET_MODE]   "KCP mode"        fast normal fast2 fast3
    ask_menu TUN[PAQET_CIPHER] "Encryption"      aes-128-gcm aes-256-gcm none
    ask_valid TUN[PAQET_CONN]  "Parallel connections (1-32)" is_uint 4
    ask_valid TUN[MTU]         "Tunnel MTU"      is_mtu 1350

    ask_valid TUN[PAQET_IFACE] "Network interface" is_iface "$def_iface"
    ask_valid TUN[PAQET_MAC]   "Gateway MAC address" is_mac "$def_mac"

    TUN[FORWARDS]=""
    TUN[PAQET_SOCKS_PORT]=""
    TUN[PAQET_TARGET_HOST]="127.0.0.1"
    if [[ "$mode_role" == client ]]; then
        ask_menu TUN[PAQET_TRAFFIC] "Traffic type" "port-forward" "socks5"
        if [[ "${TUN[PAQET_TRAFFIC]}" == socks5 ]]; then
            ask_valid TUN[PAQET_SOCKS_PORT] "Local SOCKS5 port" is_port 1080
        else
            paqet_wizard_forwards
        fi
    else
        TUN[PAQET_TRAFFIC]="server"
    fi
}

paqet_wizard_forwards() {
    local list="" proto lp dp
    ask TUN[PAQET_TARGET_HOST] "Target host on the server side" "127.0.0.1"
    while true; do
        ask_menu proto "Protocol" tcp udp
        ask_valid lp "Local listen port (Iran side)" is_port
        ask_valid dp "Target port (server side)" is_port "$lp"
        list+="${list:+;}${proto}:${lp}:${dp}"
        confirm "Add another forward?" no || break
    done
    TUN[FORWARDS]="$list"
}

# ---------------------------------------------------------------------------
# Validation & config
# ---------------------------------------------------------------------------
paqet_validate() {
    is_ipv4 "${TUN[LOCAL_IP]:-}"  || { log_error "invalid LOCAL_IP"; return 1; }
    is_port "${TUN[PAQET_PORT]:-}" || { log_error "invalid PAQET_PORT"; return 1; }
    is_mtu  "${TUN[MTU]:-}"        || { log_error "invalid MTU"; return 1; }
    is_iface "${TUN[PAQET_IFACE]:-}" || { log_error "interface '${TUN[PAQET_IFACE]:-}' not found"; return 1; }
    is_mac  "${TUN[PAQET_MAC]:-}"  || { log_error "invalid gateway MAC"; return 1; }
    if [[ "${TUN[PAQET_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid REMOTE_IP (server)"; return 1; }
    fi
    return 0
}

paqet_generate_config() {
    local file; file="$(paqet_cfg "${TUN[NAME]}")"
    mkdir -p "$TM_PAQET_DIR"
    local tmp; tmp="$(mktemp)"
    # Schema matches the upstream examples (github.com/hanselime/paqet).
    {
        printf 'role: "%s"\n' "${TUN[PAQET_ROLE]}"
        printf 'log:\n  level: "info"\n'
        if [[ "${TUN[PAQET_ROLE]}" == server ]]; then
            printf 'listen:\n  addr: ":%s"\n' "${TUN[PAQET_PORT]}"
        else
            # Client egress declared near the top, like the upstream example.
            if [[ "${TUN[PAQET_TRAFFIC]}" == socks5 ]]; then
                printf 'socks5:\n  - listen: "127.0.0.1:%s"\n' "${TUN[PAQET_SOCKS_PORT]}"
            elif [[ -n "${TUN[FORWARDS]:-}" ]]; then
                printf 'forward:\n'
                local IFS=';' entry proto lp dp
                for entry in ${TUN[FORWARDS]}; do
                    IFS=':' read -r proto lp dp <<<"$entry"
                    printf '  - listen: "0.0.0.0:%s"\n' "$lp"
                    printf '    target: "%s:%s"\n' "${TUN[PAQET_TARGET_HOST]:-127.0.0.1}" "$dp"
                    printf '    protocol: "%s"\n' "$proto"
                done
            fi
        fi
        printf 'network:\n'
        printf '  interface: "%s"\n' "${TUN[PAQET_IFACE]}"
        printf '  ipv4:\n'
        if [[ "${TUN[PAQET_ROLE]}" == server ]]; then
            printf '    addr: "%s:%s"\n' "${TUN[LOCAL_IP]}" "${TUN[PAQET_PORT]}"
        else
            printf '    addr: "%s:0"\n' "${TUN[LOCAL_IP]}"
        fi
        printf '    router_mac: "%s"\n' "${TUN[PAQET_MAC]}"
        # TCP flags used for packet crafting (matches upstream defaults/examples).
        printf '  tcp:\n'
        printf '    local_flag: ["PA"]\n'
        [[ "${TUN[PAQET_ROLE]}" == client ]] && printf '    remote_flag: ["PA"]\n'
        # Client needs the server address to connect to.
        if [[ "${TUN[PAQET_ROLE]}" == client ]]; then
            printf 'server:\n  addr: "%s:%s"\n' "${TUN[REMOTE_IP]}" "${TUN[PAQET_PORT]}"
        fi
        printf 'transport:\n'
        printf '  protocol: "kcp"\n'
        printf '  conn: %s\n' "${TUN[PAQET_CONN]:-4}"
        printf '  kcp:\n'
        printf '    key: "%s"\n' "${TUN[PAQET_SECRET]}"
        printf '    mode: "%s"\n' "${TUN[PAQET_MODE]:-fast}"
        printf '    block: "%s"\n' "${TUN[PAQET_CIPHER]:-aes-128-gcm}"
        printf '    mtu: %s\n' "${TUN[MTU]}"
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
    log_debug "wrote paqet config $file"
}

# ---------------------------------------------------------------------------
# Bring up / tear down (firewall rules; the binary itself runs via systemd)
# ---------------------------------------------------------------------------
paqet_up() {
    paqet_ensure_binary || return 1
    paqet_generate_config
    paqet_rules_up
    log_ok "Paqet '${TUN[NAME]}' prepared (rules + config)"
}

paqet_down() {
    paqet_rules_down
    log_ok "Paqet '${TUN[NAME]}' rules removed"
}

# Paqet crafts/receives raw TCP on the tunnel port. We must stop the kernel's
# conntrack and RST generation from interfering. A server sees the port as its
# dport (in) / sport (out); a client sees it as its dport (out) / sport (in).
# We therefore apply the full both-directions set, scoped to the port, so the
# same rules are correct for either role.
paqet_rules_up()   { paqet_rules apply; }
paqet_rules_down() { paqet_rules remove; }

paqet_rules() {
    local action="$1" port="${TUN[PAQET_PORT]}"
    local fn=_ipt_ensure; [[ "$action" == remove ]] && fn=_ipt_remove
    # NOTRACK the port in both chains and both directions.
    "$fn" raw PREROUTING -p tcp --dport "$port" -j NOTRACK
    "$fn" raw PREROUTING -p tcp --sport "$port" -j NOTRACK
    "$fn" raw OUTPUT     -p tcp --dport "$port" -j NOTRACK
    "$fn" raw OUTPUT     -p tcp --sport "$port" -j NOTRACK
    # Drop kernel-generated RSTs touching the port (both directions).
    "$fn" mangle OUTPUT     -p tcp --sport "$port" --tcp-flags RST RST -j DROP
    "$fn" mangle OUTPUT     -p tcp --dport "$port" --tcp-flags RST RST -j DROP
    "$fn" mangle PREROUTING -p tcp --sport "$port" --tcp-flags RST RST -j DROP
    "$fn" mangle PREROUTING -p tcp --dport "$port" --tcp-flags RST RST -j DROP
}

# ---------------------------------------------------------------------------
# systemd unit — long-lived binary; __up/__down run as pre/post hooks.
# ---------------------------------------------------------------------------
paqet_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (Paqet)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=$(paqet_bin) run -c $(paqet_cfg "${TUN[NAME]}")
ExecStopPost=${TM_CTL} __down ${TUN[NAME]}
Restart=always
RestartSec=5
LimitNOFILE=1048576
Environment=GOMAXPROCS=0

[Install]
WantedBy=multi-user.target
EOF
}

# ---------------------------------------------------------------------------
# Health, counters, status
# ---------------------------------------------------------------------------
# paqet_health NAME — healthy if the systemd unit is active.
paqet_health() {
    systemctl is-active --quiet "$(unit_name "$1")"
}

# paqet_sample NAME — Paqet has no kernel interface; byte accounting is not
# available without extra tooling, so report zeros (bandwidth shown as N/A).
paqet_sample() { printf '0 0'; }

paqet_status() {
    ui_kv "Role"       "${TUN[PAQET_ROLE]}"
    if [[ "${TUN[PAQET_ROLE]}" == client ]]; then
        ui_kv "Server"   "${TUN[REMOTE_IP]}:${TUN[PAQET_PORT]}"
        ui_kv "Egress"   "${TUN[PAQET_TRAFFIC]}${TUN[PAQET_SOCKS_PORT]:+ (socks :${TUN[PAQET_SOCKS_PORT]})}"
        [[ -n "${TUN[FORWARDS]:-}" ]] && ui_kv "Forwards" "${TUN[FORWARDS]} -> ${TUN[PAQET_TARGET_HOST]}"
    else
        ui_kv "Listen"   "${TUN[LOCAL_IP]}:${TUN[PAQET_PORT]}"
    fi
    ui_kv "KCP"        "mode=${TUN[PAQET_MODE]} cipher=${TUN[PAQET_CIPHER]} conn=${TUN[PAQET_CONN]} mtu=${TUN[MTU]}"
    ui_kv "Capture"    "${TUN[PAQET_IFACE]} via gw ${TUN[PAQET_MAC]}"
    if [[ -x "$(paqet_bin)" ]]; then
        ui_kv "Binary"   "$(paqet_bin)"
    else
        ui_kv "Binary"   "$(status_dot down) not installed"
    fi
}
