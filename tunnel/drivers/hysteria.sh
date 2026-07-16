#!/usr/bin/env bash
# drivers/hysteria.sh — Hysteria 2 (QUIC) transport driver.
#
# Hysteria 2 (github.com/apernet/hysteria) is a modern QUIC/UDP tunnel with a
# TLS-native handshake (looks like HTTP/3), Salamander packet obfuscation, and
# the "Brutal" congestion control that shrugs off packet loss — which makes it
# very effective on Iran's lossy, DPI'd links. This is the strong "Relay" engine
# the Phormal project is built around; we add it natively instead of porting
# Phormal's shell orchestrator (whose other engines, gost + rathole, we already
# ship).
#
# Model fits the Iran relay use case as a real TCP port-forward: the FOREIGN side
# runs the QUIC server (exit); the IRAN side runs the client and forwards local
# TCP ports through the tunnel to a target resolved on the foreign side (its own
# localhost xray). So: xray client → iran:<listen> → QUIC → foreign → 127.0.0.1:
# <target> (xray Reality). The client dials out (Iran→foreign), the proven dir.
#
# TUN keys: HY_ROLE(server|client) HY_PORT HY_PASS HY_OBFS(on|off) HY_UP HY_DOWN
#           HY_PORTS(client; ';'-separated "listen=target") HY_TARGET REMOTE_IP
#           LOCAL_IP

: "${HYSTERIA_REPO:=apernet/hysteria}"
: "${HYSTERIA_DEFAULT_TAG:=app/v2.9.2}"
: "${TM_HYSTERIA_DIR:=$TM_CONFIG_DIR/hysteria}"

hysteria_bin()  { printf '%s/hysteria' "$TM_BIN_DIR"; }
hysteria_cfg()  { printf '%s/%s.yaml' "$TM_HYSTERIA_DIR" "$1"; }
hysteria_cert() { printf '%s/certs/%s.crt' "$TM_HYSTERIA_DIR" "$1"; }
hysteria_key()  { printf '%s/certs/%s.key' "$TM_HYSTERIA_DIR" "$1"; }

hysteria_ensure_binary() {
    local bin; bin="$(hysteria_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local arch; arch="$(cpu_arch)"
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || { log_error "Hysteria supports amd64/arm64 only (got $(uname -m))."; return 1; }
    # Hysteria ships a RAW static binary per arch (not an archive).
    local tag url tmp
    tag="${HYSTERIA_TAG:-$HYSTERIA_DEFAULT_TAG}"
    url="https://github.com/${HYSTERIA_REPO}/releases/download/${tag}/hysteria-linux-${arch}"
    tmp="$(mktemp)"
    log_info "Downloading Hysteria ${tag} (${arch})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp" "$url"; then
        rm -f "$tmp"; log_error "Download failed: $url"; return 1
    fi
    is_elf "$tmp" || { rm -f "$tmp"; log_error "downloaded file is not a valid binary"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$tmp" "$bin"; rm -f "$tmp"
    log_ok "Installed Hysteria binary -> $bin"
}

# hysteria_ensure_cert NAME — self-signed cert/key for the QUIC server (client
# uses tls.insecure, so the name is cosmetic). RSA-2048 to match Hysteria's
# widely-tested setup.
hysteria_ensure_cert() {
    local name="$1" crt key
    crt="$(hysteria_cert "$name")"; key="$(hysteria_key "$name")"
    [[ -s "$crt" && -s "$key" ]] && return 0
    have openssl || { log_error "openssl is required for the Hysteria TLS certificate (apt-get install -y openssl)"; return 1; }
    mkdir -p "$(dirname "$crt")"
    if ! openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$key" -out "$crt" -days 3650 -subj "/CN=hysteria" >/dev/null 2>&1; then
        log_error "openssl failed to generate self-signed certificate"; return 1
    fi
    chmod 600 "$key"; chmod 644 "$crt"
    log_ok "Generated self-signed TLS cert for '$name'"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
hysteria_wizard() {
    # foreign = QUIC server (exit); iran = client (forwards ports out).
    local def_role="client"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="server"
    local role
    ask_menu role "Hysteria role for THIS server (server = QUIC exit on foreign; client = entry on Iran that dials out)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[HY_ROLE]="$role"

    ask_valid TUN[HY_PORT] "QUIC port (UDP)" is_port 8443
    ask TUN[HY_PASS] "Shared secret (auth + obfs; blank = auto; MUST match the other side)" ""
    if [[ -z "${TUN[HY_PASS]}" ]]; then
        TUN[HY_PASS]="$(gen_secret 32)"
        log_ok "Generated shared secret: ${TUN[HY_PASS]}"
        log_info "→ Use this SAME secret when adding this tunnel on the other server."
    fi
    ask_menu TUN[HY_OBFS] "Salamander packet obfuscation (recommended vs DPI; must match both sides)" on off

    # Brutal congestion control uses these as the target link speed. Rough is
    # fine; higher = more aggressive (ignores loss). Same values are OK on both.
    ask TUN[HY_UP]   "Link upload speed to target (mbps)"   100
    ask TUN[HY_DOWN] "Link download speed to target (mbps)" 100

    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP] "This server's IP" is_ipv4 "$def_local"

    if [[ "$role" == client ]]; then
        ask_valid TUN[REMOTE_IP] "Server (foreign) public IP" is_ipv4
        ask TUN[HY_TARGET] "Target host the exit forwards to (usually the foreign's localhost)" "127.0.0.1"
        log_info "Map local ports (users/xray hit these on Iran) to target ports on the exit side."
        hysteria_wizard_ports
    fi
    # server side: peer IP for bot control is collected by the generic add flow.
}

hysteria_wizard_ports() {
    local list="" lp tp
    while true; do
        ask_valid lp "Local listen port (here, users connect to this)" is_port
        ask_valid tp "Target port (on the exit/foreign side)" is_port "$lp"
        list+="${list:+;}${lp}=${tp}"
        confirm "Add another port?" no || break
    done
    TUN[HY_PORTS]="$list"
}

# ---------------------------------------------------------------------------
# Validation & config
# ---------------------------------------------------------------------------
hysteria_validate() {
    is_port "${TUN[HY_PORT]:-}" || { log_error "invalid QUIC port"; return 1; }
    [[ -n "${TUN[HY_PASS]:-}" ]] || { log_error "empty shared secret"; return 1; }
    if [[ "${TUN[HY_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }
        [[ -n "${TUN[HY_PORTS]:-}" ]] || { log_error "at least one port mapping required"; return 1; }
    fi
    return 0
}

# Shared QUIC receive-window / timeout tuning (matches Phormal's relay preset).
hysteria_quic_block() {
    printf 'quic:\n'
    printf '  initStreamReceiveWindow: 8388608\n'
    printf '  maxStreamReceiveWindow: 8388608\n'
    printf '  initConnReceiveWindow: 20971520\n'
    printf '  maxConnReceiveWindow: 20971520\n'
    printf '  maxIdleTimeout: 30s\n'
    printf '  keepAlivePeriod: 10s\n'
    printf '  disablePathMTUDiscovery: false\n'
}

hysteria_generate_config() {
    local file; file="$(hysteria_cfg "${TUN[NAME]}")"
    mkdir -p "$TM_HYSTERIA_DIR"
    local tmp; tmp="$(mktemp)"
    local obfs_on="${TUN[HY_OBFS]:-on}"
    if [[ "${TUN[HY_ROLE]}" == server ]]; then
        {
            printf 'listen: :%s\n\n' "${TUN[HY_PORT]}"
            printf 'tls:\n'
            printf '  cert: %s\n' "$(hysteria_cert "${TUN[NAME]}")"
            printf '  key: %s\n\n' "$(hysteria_key "${TUN[NAME]}")"
            printf 'auth:\n'
            printf '  type: password\n'
            printf '  password: %s\n\n' "${TUN[HY_PASS]}"
            if [[ "$obfs_on" == on ]]; then
                printf 'obfs:\n'
                printf '  type: salamander\n'
                printf '  salamander:\n'
                printf '    password: %s\n\n' "${TUN[HY_PASS]}"
            fi
            printf 'bandwidth:\n'
            printf '  up: %s mbps\n' "${TUN[HY_UP]:-100}"
            printf '  down: %s mbps\n\n' "${TUN[HY_DOWN]:-100}"
            hysteria_quic_block
        } >"$tmp"
    else
        {
            printf 'server: %s:%s\n\n' "${TUN[REMOTE_IP]}" "${TUN[HY_PORT]}"
            printf 'auth: %s\n\n' "${TUN[HY_PASS]}"
            printf 'tls:\n'
            printf '  insecure: true\n\n'
            if [[ "$obfs_on" == on ]]; then
                printf 'obfs:\n'
                printf '  type: salamander\n'
                printf '  salamander:\n'
                printf '    password: %s\n\n' "${TUN[HY_PASS]}"
            fi
            printf 'bandwidth:\n'
            printf '  up: %s mbps\n' "${TUN[HY_UP]:-100}"
            printf '  down: %s mbps\n\n' "${TUN[HY_DOWN]:-100}"
            hysteria_quic_block
            printf '\nfastOpen: true\n\n'
            local tgt="${TUN[HY_TARGET]:-127.0.0.1}"
            printf 'tcpForwarding:\n'
            local IFS=';' e lp tp
            for e in ${TUN[HY_PORTS]}; do
                IFS='=' read -r lp tp <<<"$e"
                printf '  - listen: :%s\n' "$lp"
                printf '    remote: %s:%s\n' "$tgt" "$tp"
            done
            printf 'udpForwarding:\n'
            for e in ${TUN[HY_PORTS]}; do
                IFS='=' read -r lp tp <<<"$e"
                printf '  - listen: :%s\n' "$lp"
                printf '    remote: %s:%s\n' "$tgt" "$tp"
                printf '    timeout: 60s\n'
            done
        } >"$tmp"
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$file"
    log_debug "wrote hysteria config $file"
}

# ---------------------------------------------------------------------------
# Lifecycle (userspace QUIC/UDP — no kernel/iptables work needed)
# ---------------------------------------------------------------------------
hysteria_up() {
    hysteria_ensure_binary || return 1
    if [[ "${TUN[HY_ROLE]}" == server ]]; then
        hysteria_ensure_cert "${TUN[NAME]}" || return 1
    fi
    hysteria_generate_config
    log_ok "Hysteria '${TUN[NAME]}' prepared"
}
hysteria_down() { return 0; }

hysteria_render_unit() {
    local mode="client"; [[ "${TUN[HY_ROLE]}" == server ]] && mode="server"
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (Hysteria2)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=$(hysteria_bin) ${mode} -c $(hysteria_cfg "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

hysteria_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
hysteria_sample() { printf '0 0'; }

hysteria_status() {
    ui_kv "Role"      "${TUN[HY_ROLE]}"
    ui_kv "Transport" "QUIC/UDP + TLS$([[ "${TUN[HY_OBFS]:-on}" == on ]] && echo ' + salamander')"
    if [[ "${TUN[HY_ROLE]}" == server ]]; then
        ui_kv "Listen"  "0.0.0.0:${TUN[HY_PORT]}/udp"
        [[ -n "${TUN[REMOTE_IP]:-}" ]] && ui_kv "Peer (bot)" "${TUN[REMOTE_IP]}"
    else
        ui_kv "Server"  "${TUN[REMOTE_IP]}:${TUN[HY_PORT]}/udp   maps: ${TUN[HY_PORTS]} → ${TUN[HY_TARGET]:-127.0.0.1}"
    fi
    ui_kv "Bandwidth" "up ${TUN[HY_UP]:-100} / down ${TUN[HY_DOWN]:-100} mbps"
    if is_elf "$(hysteria_bin)"; then ui_kv "Binary" "$(hysteria_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
