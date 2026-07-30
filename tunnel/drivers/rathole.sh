#!/usr/bin/env bash
# drivers/rathole.sh — Rathole (userspace reverse tunnel, Rust) transport driver.
#
# Rathole (github.com/rapiz1/rathole) is a light, fast reverse tunnel with tcp/
# tls/noise/websocket transports. Plain userspace — no kernel/iptables work.
# The binary ships as a .zip, so unzip is required.
#
# Model mirrors Backhaul: the SERVER exposes public ports (bind_addr per
# service); the CLIENT dials out and maps each service to a local_addr. Service
# names must match on both ends — we derive them from the public port ("s<pub>")
# so both sides agree deterministically as long as the same port list is used.
#
# TUN keys: RH_ROLE(server|client) RH_PORT RH_TOKEN REMOTE_IP LOCAL_IP
#           RH_PORTS(';'-separated "pub=local")

: "${RATHOLE_REPO:=rapiz1/rathole}"
: "${RATHOLE_DEFAULT_VERSION:=v0.5.0}"
: "${TM_RATHOLE_DIR:=$TM_CONFIG_DIR/rathole}"

# rathole_split ENTRY — parse one RH_PORTS entry into _RH_PROTO/_RH_PUB/_RH_LOC
# and the service key _RH_KEY. Returns non-zero for an entry that is not a pair.
#
# The entry is "[udp:]pub=loc". rathole takes type = "tcp" | "udp" per SERVICE and
# carries both kinds in one tunnel, which is the whole reason a customer's L2TP can
# ride the same relay as their VLESS; this driver simply used to write "tcp" always.
#
# A bare entry stays TCP and keeps its historical "s<pub>" key, so every config
# written before UDP existed regenerates byte-identical — which matters because the
# two ends must agree on service names, and they are not upgraded at the same moment.
# UDP services are keyed "u<pub>" so tcp/500 and udp/500 can both exist.
rathole_split() {
    local e="$1"
    _RH_PROTO=tcp
    case "$e" in
        udp:*) _RH_PROTO=udp; e="${e#udp:}" ;;
        tcp:*) e="${e#tcp:}" ;;
    esac
    IFS='=' read -r _RH_PUB _RH_LOC <<<"$e"
    [[ -n "$_RH_PUB" && -n "$_RH_LOC" ]] || return 1
    if [[ "$_RH_PROTO" == udp ]]; then _RH_KEY="u$_RH_PUB"; else _RH_KEY="s$_RH_PUB"; fi
    return 0
}

rathole_bin() { printf '%s/rathole' "$TM_BIN_DIR"; }
rathole_cfg() { printf '%s/%s.toml' "$TM_RATHOLE_DIR" "$1"; }

# rathole_triple — Rust target triple for the current arch.
rathole_triple() {
    case "$(cpu_arch)" in
        amd64) echo x86_64-unknown-linux-gnu ;;
        arm64) echo aarch64-unknown-linux-musl ;;
        *)     echo unsupported ;;
    esac
}

rathole_latest_version() {
    local v
    v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${RATHOLE_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    printf '%s' "${v:-$RATHOLE_DEFAULT_VERSION}"
}

rathole_ensure_binary() {
    local bin; bin="$(rathole_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local triple; triple="$(rathole_triple)"
    [[ "$triple" == unsupported ]] && { log_error "Rathole supports amd64/arm64 only (got $(uname -m))."; return 1; }
    have unzip || { log_error "unzip is required for Rathole; install it (apt install unzip)."; return 1; }

    local ver asset url tmp
    ver="${RATHOLE_VERSION:-$(rathole_latest_version)}"
    asset="rathole-${triple}.zip"
    url="https://github.com/${RATHOLE_REPO}/releases/download/${ver}/${asset}"
    tmp="$(mktemp -d)"
    log_info "Downloading Rathole ${ver} (${triple})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/r.zip" "$url"; then
        rm -rf "$tmp"; log_error "Download failed: $url"; return 1
    fi
    unzip -o -q "$tmp/r.zip" -d "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "unzip failed"; return 1; }
    local f found=""
    while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f | sort)
    [[ -n "$found" ]] || { rm -rf "$tmp"; log_error "no rathole binary in archive"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$found" "$bin"; rm -rf "$tmp"
    log_ok "Installed Rathole binary -> $bin"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
rathole_wizard() {
    local def_role="server"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="client"
    local role
    ask_menu role "Rathole role for THIS server (server = users connect here; client = dials out)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[RH_ROLE]="$role"

    ask_valid TUN[RH_PORT] "Control port" is_port 2333
    ask TUN[RH_TOKEN] "Shared token (blank = auto; MUST match the other side)" ""
    [[ -n "${TUN[RH_TOKEN]}" ]] || TUN[RH_TOKEN]="$(gen_secret 24)"
    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP] "This server's IP" is_ipv4 "$def_local"
    [[ "$role" == client ]] && ask_valid TUN[REMOTE_IP] "Server (other side) public IP" is_ipv4

    log_info "Enter the SAME port pairs on both sides (public port users hit = local service port)."
    rathole_wizard_ports
}

rathole_wizard_ports() {
    local list="" pub loc
    while true; do
        ask_valid pub "Public port (server exposes this)" is_port
        ask_valid loc "Local service port (on the client)" is_port "$pub"
        list+="${list:+;}${pub}=${loc}"
        confirm "Add another port pair?" no || break
    done
    TUN[RH_PORTS]="$list"
}

rathole_validate() {
    is_port "${TUN[RH_PORT]:-}"   || { log_error "invalid control port"; return 1; }
    [[ -n "${TUN[RH_TOKEN]:-}" ]] || { log_error "empty token"; return 1; }
    [[ -n "${TUN[RH_PORTS]:-}" ]] || { log_error "at least one port pair required"; return 1; }
    [[ "${TUN[RH_ROLE]}" == client ]] && { is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid server IP"; return 1; }; }
    return 0
}

rathole_generate_config() {
    local file; file="$(rathole_cfg "${TUN[NAME]}")"
    mkdir -p "$TM_RATHOLE_DIR"
    local tmp; tmp="$(mktemp)"
    local IFS=';' e
    if [[ "${TUN[RH_ROLE]}" == server ]]; then
        {
            printf '[server]\n'
            printf 'bind_addr = "0.0.0.0:%s"\n' "${TUN[RH_PORT]}"
            printf 'default_token = "%s"\n\n' "${TUN[RH_TOKEN]}"
            for e in ${TUN[RH_PORTS]}; do
                rathole_split "$e" || continue
                printf '[server.services.%s]\n' "$_RH_KEY"
                printf 'type = "%s"\n' "$_RH_PROTO"
                printf 'bind_addr = "0.0.0.0:%s"\n\n' "$_RH_PUB"
            done
        } >"$tmp"
    else
        {
            printf '[client]\n'
            printf 'remote_addr = "%s:%s"\n' "${TUN[REMOTE_IP]}" "${TUN[RH_PORT]}"
            printf 'default_token = "%s"\n\n' "${TUN[RH_TOKEN]}"
            for e in ${TUN[RH_PORTS]}; do
                rathole_split "$e" || continue
                printf '[client.services.%s]\n' "$_RH_KEY"
                printf 'type = "%s"\n' "$_RH_PROTO"
                printf 'local_addr = "127.0.0.1:%s"\n\n' "$_RH_LOC"
            done
        } >"$tmp"
    fi
    chmod 600 "$tmp"; mv -f "$tmp" "$file"
    log_debug "wrote rathole config $file"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
rathole_up() {
    rathole_ensure_binary || return 1
    rathole_generate_config
    log_ok "Rathole '${TUN[NAME]}' prepared"
}
rathole_down() { return 0; }

rathole_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (Rathole)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=$(rathole_bin) $(rathole_cfg "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

rathole_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
rathole_sample() { svc_ip_sample "$1"; }

rathole_status() {
    ui_kv "Role" "${TUN[RH_ROLE]}"
    if [[ "${TUN[RH_ROLE]}" == server ]]; then
        ui_kv "Control" "0.0.0.0:${TUN[RH_PORT]}   exposes: ${TUN[RH_PORTS]}"
    else
        ui_kv "Server"  "${TUN[REMOTE_IP]}:${TUN[RH_PORT]}   maps: ${TUN[RH_PORTS]}"
    fi
    if is_elf "$(rathole_bin)"; then ui_kv "Binary" "$(rathole_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
