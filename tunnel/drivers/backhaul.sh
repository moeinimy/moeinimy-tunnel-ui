#!/usr/bin/env bash
# drivers/backhaul.sh — Backhaul (userspace reverse tunnel) transport driver.
#
# Backhaul (github.com/Musixal/Backhaul) is a fast Go reverse-tunnel for NAT/
# firewall traversal with tcp/tcpmux/ws/wsmux transports and multiplexing. It is
# plain TCP on the wire, so no kernel/iptables work is needed — just a binary, a
# TOML config, and a systemd service.
#
# Model: the SERVER side owns the public port users connect to and defines the
# `ports` forwarding map; the CLIENT dials out to the server. For the common
# Iran relay (users → Iran → foreign service) use role iran=server,
# foreign=client. This is the default mapping, adjustable in the wizard.
#
# TUN keys: BH_ROLE(server|client) BH_TRANSPORT BH_PORT BH_TOKEN REMOTE_IP
#           LOCAL_IP BH_PORTS(server; ';'-separated "listen=dest") BH_MUX

: "${BACKHAUL_REPO:=Musixal/Backhaul}"
: "${BACKHAUL_DEFAULT_VERSION:=v0.7.2}"

backhaul_bin() { printf '%s/backhaul' "$TM_BIN_DIR"; }
backhaul_cfg() { printf '%s/%s.toml' "$TM_BACKHAUL_DIR" "$1"; }

: "${TM_BACKHAUL_DIR:=$TM_CONFIG_DIR/backhaul}"

backhaul_latest_version() {
    local v
    v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${BACKHAUL_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    printf '%s' "${v:-$BACKHAUL_DEFAULT_VERSION}"
}

backhaul_ensure_binary() {
    local bin; bin="$(backhaul_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local arch; arch="$(cpu_arch)"
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || { log_error "Backhaul supports amd64/arm64 only (got $(uname -m))."; return 1; }

    local ver asset url tmp
    ver="${BACKHAUL_VERSION:-$(backhaul_latest_version)}"
    asset="backhaul_linux_${arch}.tar.gz"
    url="https://github.com/${BACKHAUL_REPO}/releases/download/${ver}/${asset}"
    tmp="$(mktemp -d)"
    log_info "Downloading Backhaul ${ver} (${arch})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/$asset" "$url"; then
        rm -rf "$tmp"; log_error "Download failed: $url"; return 1
    fi
    tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "extract failed"; return 1; }
    local f found=""
    while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f | sort)
    [[ -n "$found" ]] || { rm -rf "$tmp"; log_error "no backhaul binary in archive"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$found" "$bin"; rm -rf "$tmp"
    log_ok "Installed Backhaul binary -> $bin"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
backhaul_wizard() {
    # Default role mapping for the Iran relay use case.
    local def_role="server"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="client"
    local role
    ask_menu role "Backhaul role for THIS server (server = users connect here; client = dials out)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[BH_ROLE]="$role"

    ask_menu TUN[BH_TRANSPORT] "Transport" tcp tcpmux ws wsmux
    ask_valid TUN[BH_PORT] "Tunnel port (control connection)" is_port 3080
    ask TUN[BH_TOKEN] "Shared token (blank = auto; MUST match the other side)" ""
    [[ -n "${TUN[BH_TOKEN]}" ]] || TUN[BH_TOKEN]="$(gen_secret 24)"

    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP] "This server's IP" is_ipv4 "$def_local"

    if [[ "$role" == server ]]; then
        TUN[BH_PORTS]=""
        log_info "Define which ports users hit here, and where they go on the client side."
        backhaul_wizard_ports
    else
        ask_valid TUN[REMOTE_IP] "Server (other side) public IP" is_ipv4
    fi
    case "${TUN[BH_TRANSPORT]}" in *mux) TUN[BH_MUX]=8 ;; *) TUN[BH_MUX]="" ;; esac
}

backhaul_wizard_ports() {
    local list="" lp dp
    while true; do
        ask_valid lp "Listen port (here, users connect to this)" is_port
        ask_valid dp "Destination port (on the client side)" is_port "$lp"
        list+="${list:+;}${lp}=${dp}"
        confirm "Add another port mapping?" no || break
    done
    TUN[BH_PORTS]="$list"
}

# ---------------------------------------------------------------------------
# Validation & config
# ---------------------------------------------------------------------------
backhaul_validate() {
    is_port "${TUN[BH_PORT]:-}"  || { log_error "invalid tunnel port"; return 1; }
    [[ -n "${TUN[BH_TOKEN]:-}" ]] || { log_error "empty token"; return 1; }
    if [[ "${TUN[BH_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }
    else
        [[ -n "${TUN[BH_PORTS]:-}" ]] || { log_error "server needs at least one port mapping"; return 1; }
    fi
    return 0
}

backhaul_generate_config() {
    local file; file="$(backhaul_cfg "${TUN[NAME]}")"
    mkdir -p "$TM_BACKHAUL_DIR"
    local tmp; tmp="$(mktemp)"
    if [[ "${TUN[BH_ROLE]}" == server ]]; then
        {
            printf '[server]\n'
            printf 'bind_addr = "0.0.0.0:%s"\n' "${TUN[BH_PORT]}"
            printf 'transport = "%s"\n' "${TUN[BH_TRANSPORT]}"
            printf 'accept_udp = false\n'
            printf 'token = "%s"\n' "${TUN[BH_TOKEN]}"
            printf 'keepalive_period = 75\n'
            printf 'nodelay = true\n'
            printf 'heartbeat = 40\n'
            printf 'channel_size = 2048\n'
            [[ -n "${TUN[BH_MUX]:-}" ]] && printf 'mux_con = %s\n' "${TUN[BH_MUX]}"
            printf 'sniffer = false\n'
            printf 'web_port = 0\n'
            printf 'log_level = "info"\n'
            printf 'ports = [\n'
            local IFS=';' e lp dp
            for e in ${TUN[BH_PORTS]}; do
                IFS='=' read -r lp dp <<<"$e"
                printf '   "%s=%s",\n' "$lp" "$dp"
            done
            printf ']\n'
        } >"$tmp"
    else
        {
            printf '[client]\n'
            printf 'remote_addr = "%s:%s"\n' "${TUN[REMOTE_IP]}" "${TUN[BH_PORT]}"
            printf 'transport = "%s"\n' "${TUN[BH_TRANSPORT]}"
            printf 'token = "%s"\n' "${TUN[BH_TOKEN]}"
            printf 'connection_pool = 8\n'
            printf 'aggressive_pool = false\n'
            printf 'keepalive_period = 75\n'
            printf 'nodelay = true\n'
            printf 'retry_interval = 3\n'
            printf 'dial_timeout = 10\n'
            [[ -n "${TUN[BH_MUX]:-}" ]] && printf 'mux_version = 1\n'
            printf 'sniffer = false\n'
            printf 'web_port = 0\n'
            printf 'log_level = "info"\n'
        } >"$tmp"
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$file"
    log_debug "wrote backhaul config $file"
}

# ---------------------------------------------------------------------------
# Lifecycle (userspace TCP — no kernel/iptables work needed)
# ---------------------------------------------------------------------------
backhaul_up() {
    backhaul_ensure_binary || return 1
    backhaul_generate_config
    log_ok "Backhaul '${TUN[NAME]}' prepared"
}
backhaul_down() { return 0; }

backhaul_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (Backhaul)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=$(backhaul_bin) -c $(backhaul_cfg "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

backhaul_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
backhaul_sample() { printf '0 0'; }

backhaul_status() {
    ui_kv "Role"      "${TUN[BH_ROLE]}"
    ui_kv "Transport" "${TUN[BH_TRANSPORT]}"
    if [[ "${TUN[BH_ROLE]}" == server ]]; then
        ui_kv "Listen"  "0.0.0.0:${TUN[BH_PORT]}   maps: ${TUN[BH_PORTS]}"
    else
        ui_kv "Server"  "${TUN[REMOTE_IP]}:${TUN[BH_PORT]}"
    fi
    if is_elf "$(backhaul_bin)"; then ui_kv "Binary" "$(backhaul_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
