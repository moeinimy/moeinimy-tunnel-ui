#!/usr/bin/env bash
# drivers/frp.sh — FRP (Fast Reverse Proxy) driver.
#
# FRP (github.com/fatedier/frp) is a mature reverse proxy: frps (server) exposes
# ports; frpc (client) sits next to the real service and dials the server. TLS
# between frpc/frps is on by default. Plain userspace TCP — no kernel/iptables.
#
# Model: server = the side users connect to (Iran) → runs frps and exposes the
# remote ports; client = the side with the service (foreign) → runs frpc and
# maps each remote port to a local service port. frpc dials frps (foreign→Iran).
#
# TUN keys: FRP_ROLE(server|client) FRP_PORT FRP_TOKEN REMOTE_IP
#           FRP_PORTS(';'-separated "remote=local")

: "${FRP_REPO:=fatedier/frp}"
: "${FRP_DEFAULT_VERSION:=v0.70.0}"
: "${TM_FRP_DIR:=$TM_CONFIG_DIR/frp}"

frps_bin() { printf '%s/frps' "$TM_BIN_DIR"; }
frpc_bin() { printf '%s/frpc' "$TM_BIN_DIR"; }
frp_cfg()  { printf '%s/%s.toml' "$TM_FRP_DIR" "$1"; }

frp_latest_version() {
    local v
    v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${FRP_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    printf '%s' "${v:-$FRP_DEFAULT_VERSION}"
}

# frp_ensure_binary — install BOTH frps and frpc from the release tarball.
frp_ensure_binary() {
    is_elf "$(frps_bin)" && is_elf "$(frpc_bin)" && return 0
    local arch; arch="$(cpu_arch)"
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || { log_error "FRP supports amd64/arm64 only (got $(uname -m))."; return 1; }
    local ver asset url tmp
    ver="${FRP_VERSION:-$(frp_latest_version)}"
    asset="frp_${ver#v}_linux_${arch}.tar.gz"
    url="https://github.com/${FRP_REPO}/releases/download/${ver}/${asset}"
    tmp="$(mktemp -d)"
    log_info "Downloading FRP ${ver} (${arch})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/f.tar.gz" "$url"; then
        rm -rf "$tmp"; log_error "Download failed: $url"; return 1
    fi
    tar -xzf "$tmp/f.tar.gz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "extract failed"; return 1; }
    local s c
    s="$(find "$tmp" -type f -name frps | head -1)"
    c="$(find "$tmp" -type f -name frpc | head -1)"
    if ! is_elf "$s" || ! is_elf "$c"; then rm -rf "$tmp"; log_error "frps/frpc not found in archive"; return 1; fi
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$s" "$(frps_bin)"; install -m 0755 "$c" "$(frpc_bin)"
    rm -rf "$tmp"
    log_ok "Installed FRP binaries -> $(frps_bin), $(frpc_bin)"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
frp_wizard() {
    local def_role="server"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="client"
    local role
    ask_menu role "FRP role for THIS server (server = users connect here; client = has the service)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[FRP_ROLE]="$role"

    ask_valid TUN[FRP_PORT] "Control port (frps bindPort)" is_port 7000
    ask TUN[FRP_TOKEN] "Shared token (blank = auto; MUST match the other side)" ""
    [[ -n "${TUN[FRP_TOKEN]}" ]] || TUN[FRP_TOKEN]="$(gen_secret 24)"

    if [[ "$role" == client ]]; then
        ask_valid TUN[REMOTE_IP] "Server (other side, frps) public IP" is_ipv4
        log_info "Map remote ports (users hit these on the server) to local service ports here."
        frp_wizard_ports
    fi
}

frp_wizard_ports() {
    local list="" rp lp
    while true; do
        ask_valid rp "Remote port (exposed on the server)" is_port
        ask_valid lp "Local service port (here)" is_port "$rp"
        list+="${list:+;}${rp}=${lp}"
        confirm "Add another port?" no || break
    done
    TUN[FRP_PORTS]="$list"
}

frp_validate() {
    is_port "${TUN[FRP_PORT]:-}"  || { log_error "invalid control port"; return 1; }
    [[ -n "${TUN[FRP_TOKEN]:-}" ]] || { log_error "empty token"; return 1; }
    if [[ "${TUN[FRP_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }
        [[ -n "${TUN[FRP_PORTS]:-}" ]] || { log_error "at least one port mapping required"; return 1; }
    fi
    return 0
}

frp_generate_config() {
    local file; file="$(frp_cfg "${TUN[NAME]}")"
    mkdir -p "$TM_FRP_DIR"
    local tmp; tmp="$(mktemp)"
    if [[ "${TUN[FRP_ROLE]}" == server ]]; then
        {
            printf 'bindPort = %s\n' "${TUN[FRP_PORT]}"
            printf 'auth.token = "%s"\n' "${TUN[FRP_TOKEN]}"
        } >"$tmp"
    else
        {
            printf 'serverAddr = "%s"\n' "${TUN[REMOTE_IP]}"
            printf 'serverPort = %s\n' "${TUN[FRP_PORT]}"
            printf 'auth.token = "%s"\n' "${TUN[FRP_TOKEN]}"
            printf 'transport.tls.enable = true\n\n'
            local IFS=';' e rp lp
            for e in ${TUN[FRP_PORTS]}; do
                IFS='=' read -r rp lp <<<"$e"
                printf '[[proxies]]\n'
                printf 'name = "p%s"\n' "$rp"
                printf 'type = "tcp"\n'
                printf 'localIP = "127.0.0.1"\n'
                printf 'localPort = %s\n' "$lp"
                printf 'remotePort = %s\n\n' "$rp"
            done
        } >"$tmp"
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$file"
    log_debug "wrote frp config $file"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
frp_up() {
    frp_ensure_binary || return 1
    frp_generate_config
    log_ok "FRP '${TUN[NAME]}' prepared"
}
frp_down() { return 0; }

frp_render_unit() {
    local exe; exe="$(frpc_bin)"; [[ "${TUN[FRP_ROLE]}" == server ]] && exe="$(frps_bin)"
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (FRP ${TUN[FRP_ROLE]})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=${exe} -c $(frp_cfg "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

frp_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
frp_sample() { printf '0 0'; }

frp_status() {
    ui_kv "Role" "${TUN[FRP_ROLE]} ($([[ "${TUN[FRP_ROLE]}" == server ]] && echo frps || echo frpc))"
    if [[ "${TUN[FRP_ROLE]}" == server ]]; then
        ui_kv "Control" "bindPort ${TUN[FRP_PORT]}"
    else
        ui_kv "Server"  "${TUN[REMOTE_IP]}:${TUN[FRP_PORT]}   maps: ${TUN[FRP_PORTS]} (TLS on)"
    fi
    if is_elf "$(frps_bin)"; then ui_kv "Binary" "$(frps_bin) / $(frpc_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
