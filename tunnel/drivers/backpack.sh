#!/usr/bin/env bash
# drivers/backpack.sh — BackPack (userspace reverse tunnel) transport driver.
#
# BackPack (github.com/AminMGMT/BackPack) is a Go reverse-tunnel in the Backhaul
# lineage: a single static binary driven by a TOML config, run as
# `backpack -c <config.toml>`. It adds TLS websocket transports on top of the
# usual set: tcp / tcpmux / ws / wss / wsmux / wssmux (+ udp). For carrying
# xray/Reality across Iran's DPI the winning transport is **wssmux** — a
# persistent, multiplexed, TLS-wrapped websocket that looks like ordinary HTTPS
# and does not get the per-connection reset that plain tcp relays suffer.
#
# Model (identical to backhaul): the SERVER side owns the public port users
# connect to and defines the `ports` forwarding map; the CLIENT dials out. For
# the common Iran relay (users → Iran → foreign xray) use iran=server,
# foreign=client (the default mapping).
#
# TUN keys: BP_ROLE(server|client) BP_TRANSPORT BP_PORT BP_TOKEN REMOTE_IP
#           LOCAL_IP BP_PORTS(server; ';'-separated "listen=dest") BP_MUX(flag)
#           BP_EDGE(client ws only; CDN edge IP, optional)

: "${BACKPACK_REPO:=AminMGMT/BackPack}"
: "${BACKPACK_DEFAULT_VERSION:=v1.3.0}"
: "${TM_BACKPACK_DIR:=$TM_CONFIG_DIR/backpack}"

backpack_bin()      { printf '%s/backpack' "$TM_BIN_DIR"; }
backpack_cfg()      { printf '%s/%s.toml' "$TM_BACKPACK_DIR" "$1"; }
backpack_cert()     { printf '%s/certs/%s.crt' "$TM_BACKPACK_DIR" "$1"; }
backpack_key()      { printf '%s/certs/%s.key' "$TM_BACKPACK_DIR" "$1"; }

# backpack_is_mux TRANSPORT — true for smux-multiplexed transports.
backpack_is_mux() { case "$1" in tcpmux|wsmux|wssmux) return 0 ;; *) return 1 ;; esac; }
# backpack_is_tls TRANSPORT — true for transports that terminate TLS on server.
backpack_is_tls() { case "$1" in wss|wssmux) return 0 ;; *) return 1 ;; esac; }

backpack_ensure_binary() {
    local bin; bin="$(backpack_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local arch; arch="$(cpu_arch)"
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || { log_error "BackPack supports amd64/arm64 only (got $(uname -m))."; return 1; }

    # BackPack publishes a rolling "latest" release; use it directly (no API
    # dependency), falling back to a pinned tag if latest is unavailable.
    local asset tmp url
    asset="backpack_linux_${arch}.tar.gz"
    tmp="$(mktemp -d)"
    log_info "Downloading BackPack (${arch})…"
    for url in \
        "https://github.com/${BACKPACK_REPO}/releases/latest/download/${asset}" \
        "https://github.com/${BACKPACK_REPO}/releases/download/${BACKPACK_DEFAULT_VERSION}/${asset}"; do
        if curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/$asset" "$url"; then
            break
        fi
    done
    [[ -s "$tmp/$asset" ]] || { rm -rf "$tmp"; log_error "Download failed for BackPack asset"; return 1; }
    tar -xzf "$tmp/$asset" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "extract failed"; return 1; }
    local f found=""
    while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f | sort)
    [[ -n "$found" ]] || { rm -rf "$tmp"; log_error "no backpack binary in archive"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$found" "$bin"; rm -rf "$tmp"
    log_ok "Installed BackPack binary -> $bin"
}

# backpack_ensure_cert NAME — generate a self-signed cert/key for wss/wssmux.
# Clients skip verification (InsecureSkipVerify), so the name on the cert is
# cosmetic; we just need a valid P-256 pair the server can present.
backpack_ensure_cert() {
    local name="$1" crt key
    crt="$(backpack_cert "$name")"; key="$(backpack_key "$name")"
    [[ -s "$crt" && -s "$key" ]] && return 0
    have openssl || { log_error "openssl is required for wss/wssmux transports (install it: apt-get install -y openssl)"; return 1; }
    mkdir -p "$(dirname "$crt")"
    if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
            -keyout "$key" -out "$crt" -days 3650 \
            -subj "/CN=backpack/O=backpack" >/dev/null 2>&1; then
        log_error "openssl failed to generate self-signed certificate"; return 1
    fi
    chmod 600 "$key"; chmod 644 "$crt"
    log_ok "Generated self-signed TLS cert for '$name'"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
backpack_wizard() {
    # Default role mapping for the Iran relay use case (iran=server).
    local def_role="server"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="client"
    local role
    ask_menu role "BackPack role for THIS server (server = users connect here; client = dials out)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[BP_ROLE]="$role"

    # wssmux = TLS websocket + smux: DPI-resistant (looks like HTTPS), persistent
    # and multiplexed — the right default for carrying xray/Reality. Plain tcp is
    # offered only for non-DPI paths.
    ask_menu TUN[BP_TRANSPORT] "Transport (wssmux recommended for xray/Reality through DPI)" \
        wssmux wsmux wss ws tcpmux tcp
    ask_valid TUN[BP_PORT] "Tunnel port (control connection)" is_port 8443
    ask TUN[BP_TOKEN] "Shared token (blank = auto; MUST match the other side)" ""
    if [[ -z "${TUN[BP_TOKEN]}" ]]; then
        TUN[BP_TOKEN]="$(gen_secret 32)"
        log_ok "Generated token: ${TUN[BP_TOKEN]}"
        log_info "→ Use this SAME token when adding this tunnel on the other server."
    fi

    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP] "This server's IP" is_ipv4 "$def_local"

    if [[ "$role" == server ]]; then
        # NOTE: the server side does not collect the peer's public IP here — the
        # generic add flow (tunnel_add) asks for it once for every userspace
        # protocol so bot/peer control works with no per-driver setup.
        TUN[BP_PORTS]=""
        log_info "Define which ports users hit here, and where they go on the client side."
        backpack_wizard_ports
    else
        ask_valid TUN[REMOTE_IP] "Server (other side) public IP" is_ipv4
        # Optional CDN edge override for websocket transports (blank = direct).
        case "${TUN[BP_TRANSPORT]}" in
            ws|wss|wsmux|wssmux) ask TUN[BP_EDGE] "CDN edge IP to dial instead of server (optional, blank = direct)" "" ;;
            *) TUN[BP_EDGE]="" ;;
        esac
    fi
    backpack_is_mux "${TUN[BP_TRANSPORT]}" && TUN[BP_MUX]=8 || TUN[BP_MUX]=""
}

backpack_wizard_ports() {
    local list="" lp dp
    while true; do
        ask_valid lp "Listen port (here, users connect to this)" is_port
        ask_valid dp "Destination port (on the client side)" is_port "$lp"
        list+="${list:+;}${lp}=${dp}"
        confirm "Add another port mapping?" no || break
    done
    TUN[BP_PORTS]="$list"
}

# ---------------------------------------------------------------------------
# Validation & config
# ---------------------------------------------------------------------------
backpack_validate() {
    is_port "${TUN[BP_PORT]:-}"  || { log_error "invalid tunnel port"; return 1; }
    [[ -n "${TUN[BP_TOKEN]:-}" ]] || { log_error "empty token"; return 1; }
    case "${TUN[BP_TRANSPORT]:-}" in
        tcp|tcpmux|ws|wss|wsmux|wssmux) ;;
        *) log_error "invalid transport '${TUN[BP_TRANSPORT]:-}'"; return 1 ;;
    esac
    if [[ "${TUN[BP_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }
    else
        [[ -n "${TUN[BP_PORTS]:-}" ]] || { log_error "server needs at least one port mapping"; return 1; }
    fi
    return 0
}

backpack_generate_config() {
    local file; file="$(backpack_cfg "${TUN[NAME]}")"
    local transport="${TUN[BP_TRANSPORT]}"
    mkdir -p "$TM_BACKPACK_DIR"
    local tmp; tmp="$(mktemp)"
    if [[ "${TUN[BP_ROLE]}" == server ]]; then
        {
            printf '[server]\n'
            printf 'bind_addr = "0.0.0.0:%s"\n' "${TUN[BP_PORT]}"
            printf 'transport = "%s"\n' "$transport"
            printf 'token = "%s"\n' "${TUN[BP_TOKEN]}"
            printf 'accept_udp = false\n'
            printf 'nodelay = true\n'
            printf 'keepalive_period = 75\n'
            printf 'heartbeat = 40\n'
            printf 'channel_size = 2048\n'
            # Throughput tuning (BackPack "Best-Performance" preset: 8MB buffers).
            printf 'so_rcvbuf = 8388608\n'
            printf 'so_sndbuf = 8388608\n'
            if backpack_is_tls "$transport"; then
                printf 'tls_cert = "%s"\n' "$(backpack_cert "${TUN[NAME]}")"
                printf 'tls_key = "%s"\n'  "$(backpack_key  "${TUN[NAME]}")"
            fi
            if backpack_is_mux "$transport"; then
                printf 'mux_con = %s\n'          "${TUN[BP_MUX]:-8}"
                printf 'mux_version = 2\n'
                printf 'mux_framesize = 32768\n'
                printf 'mux_recievebuffer = 4194304\n'
                printf 'mux_streambuffer = 65536\n'
            fi
            printf 'sniffer = false\n'
            printf 'web_port = 0\n'
            printf 'log_level = "info"\n'
            printf 'ports = [\n'
            local IFS=';' e lp dp
            for e in ${TUN[BP_PORTS]}; do
                IFS='=' read -r lp dp <<<"$e"
                printf '   "%s=%s",\n' "$lp" "$dp"
            done
            printf ']\n'
        } >"$tmp"
    else
        {
            printf '[client]\n'
            printf 'remote_addr = "%s:%s"\n' "${TUN[REMOTE_IP]}" "${TUN[BP_PORT]}"
            printf 'transport = "%s"\n' "$transport"
            printf 'token = "%s"\n' "${TUN[BP_TOKEN]}"
            printf 'connection_pool = 8\n'
            printf 'aggressive_pool = false\n'
            printf 'nodelay = true\n'
            printf 'keepalive_period = 75\n'
            printf 'retry_interval = 3\n'
            printf 'dial_timeout = 10\n'
            printf 'so_rcvbuf = 8388608\n'
            printf 'so_sndbuf = 8388608\n'
            [[ -n "${TUN[BP_EDGE]:-}" ]] && printf 'edge_ip = "%s"\n' "${TUN[BP_EDGE]}"
            if backpack_is_mux "$transport"; then
                printf 'mux_session = 1\n'
                printf 'mux_version = 2\n'
                printf 'mux_framesize = 32768\n'
                printf 'mux_recievebuffer = 4194304\n'
                printf 'mux_streambuffer = 65536\n'
            fi
            printf 'sniffer = false\n'
            printf 'web_port = 0\n'
            printf 'log_level = "info"\n'
        } >"$tmp"
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$file"
    log_debug "wrote backpack config $file"
}

# ---------------------------------------------------------------------------
# Lifecycle (userspace TCP/TLS — no kernel/iptables work needed)
# ---------------------------------------------------------------------------
backpack_up() {
    backpack_ensure_binary || return 1
    # wss/wssmux terminate TLS on the server side and need a cert pair.
    if [[ "${TUN[BP_ROLE]}" == server ]] && backpack_is_tls "${TUN[BP_TRANSPORT]}"; then
        backpack_ensure_cert "${TUN[NAME]}" || return 1
    fi
    backpack_generate_config
    log_ok "BackPack '${TUN[NAME]}' prepared"
}
backpack_down() { return 0; }

backpack_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (BackPack)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=$(backpack_bin) -c $(backpack_cfg "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

backpack_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
backpack_sample() { printf '0 0'; }

backpack_status() {
    ui_kv "Role"      "${TUN[BP_ROLE]}"
    ui_kv "Transport" "${TUN[BP_TRANSPORT]}"
    if [[ "${TUN[BP_ROLE]}" == server ]]; then
        ui_kv "Listen"  "0.0.0.0:${TUN[BP_PORT]}   maps: ${TUN[BP_PORTS]}"
        [[ -n "${TUN[REMOTE_IP]:-}" ]] && ui_kv "Peer (bot)" "${TUN[REMOTE_IP]}"
    else
        ui_kv "Server"  "${TUN[REMOTE_IP]}:${TUN[BP_PORT]}"
        [[ -n "${TUN[BP_EDGE]:-}" ]] && ui_kv "Edge IP" "${TUN[BP_EDGE]}"
    fi
    if is_elf "$(backpack_bin)"; then ui_kv "Binary" "$(backpack_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
