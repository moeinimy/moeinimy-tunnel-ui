#!/usr/bin/env bash
# drivers/gost.sh — GOST v3 (go-gost) relay driver.
#
# GOST (github.com/go-gost/gost) is a very versatile tunnel/relay with many
# transports (tcp/tls/ws/wss/mws/mwss/grpc/quic/kcp…). Here we use a relay chain
# for the Iran-relay use case: the foreign side runs a relay listener; the Iran
# side listens locally and forwards each port THROUGH the relay to a target
# resolved on the foreign side. The Iran side dials out (Iran→foreign), the
# direction known to work.
#
# GOST is driven entirely by CLI args, so instead of a config file we render a
# 0700 wrapper script (keeps the relay password out of the 0644 unit file).
#
# TUN keys: GO_ROLE(server|client) GO_PROTO GO_PORT GO_USER GO_PASS REMOTE_IP
#           GO_PORTS(';'-separated "localport=targetport") GO_TARGET

: "${GOST_REPO:=go-gost/gost}"
: "${GOST_DEFAULT_VERSION:=v3.2.6}"
: "${TM_GOST_DIR:=$TM_CONFIG_DIR/gost}"

gost_bin()     { printf '%s/gost' "$TM_BIN_DIR"; }
gost_wrapper() { printf '%s/%s.sh' "$TM_GOST_DIR" "$1"; }

gost_latest_version() {
    local v
    v="$(curl -fsSL --max-time 15 "https://api.github.com/repos/${GOST_REPO}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null)"
    printf '%s' "${v:-$GOST_DEFAULT_VERSION}"
}

gost_ensure_binary() {
    local bin; bin="$(gost_bin)"
    is_elf "$bin" && return 0
    [[ -e "$bin" ]] && rm -f "$bin"
    local arch; arch="$(cpu_arch)"
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || { log_error "GOST supports amd64/arm64 only (got $(uname -m))."; return 1; }
    local ver asset url tmp
    ver="${GOST_VERSION:-$(gost_latest_version)}"
    asset="gost_${ver#v}_linux_${arch}.tar.gz"
    url="https://github.com/${GOST_REPO}/releases/download/${ver}/${asset}"
    tmp="$(mktemp -d)"
    log_info "Downloading GOST ${ver} (${arch})…"
    if ! curl -fsSL --max-time 180 --retry 3 --retry-delay 5 -o "$tmp/g.tar.gz" "$url"; then
        rm -rf "$tmp"; log_error "Download failed: $url"; return 1
    fi
    tar -xzf "$tmp/g.tar.gz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; log_error "extract failed"; return 1; }
    local f found=""
    while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f -name 'gost*' | sort)
    [[ -n "$found" ]] || while IFS= read -r f; do is_elf "$f" && { found="$f"; break; }; done < <(find "$tmp" -type f | sort)
    [[ -n "$found" ]] || { rm -rf "$tmp"; log_error "no gost binary in archive"; return 1; }
    mkdir -p "$TM_BIN_DIR"; install -m 0755 "$found" "$bin"; rm -rf "$tmp"
    log_ok "Installed GOST binary -> $bin"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
gost_wizard() {
    local def_role="client"; [[ "${TUN[ROLE]}" == foreign ]] && def_role="server"
    local role
    ask_menu role "GOST role for THIS server (server = relay/exit; client = entry that dials out)" \
        "$def_role" "$([[ "$def_role" == server ]] && echo client || echo server)"
    TUN[GO_ROLE]="$role"

    # mtls/mwss keep a persistent multiplexed, TLS-wrapped connection — low
    # latency and DPI-resistant (looks like HTTPS). Plain tcp opens a fresh
    # unencrypted connection per request, which Iran's DPI throttles/resets and
    # which breaks latency-sensitive handshakes like xray Reality. Default: mtls.
    ask_menu TUN[GO_PROTO] "Relay transport (mtls/mwss recommended for xray; tcp only for plain TCP)" \
        mtls mwss grpc wss tcp
    ask_valid TUN[GO_PORT] "Relay port" is_port 8443
    TUN[GO_USER]="tm"
    ask TUN[GO_PASS] "Relay password (blank = auto; MUST match the other side)" ""
    [[ -n "${TUN[GO_PASS]}" ]] || TUN[GO_PASS]="$(gen_secret 20)"

    if [[ "$role" == client ]]; then
        ask_valid TUN[REMOTE_IP] "Relay server (foreign) public IP" is_ipv4
        ask TUN[GO_TARGET] "Target host the relay dials (usually the foreign's localhost)" "127.0.0.1"
        log_info "Map local ports (users hit these here) to target ports on the relay side."
        gost_wizard_ports
    fi
}

gost_wizard_ports() {
    local list="" lp tp
    while true; do
        ask_valid lp "Local listen port (here)" is_port
        ask_valid tp "Target port (on the relay/foreign side)" is_port "$lp"
        list+="${list:+;}${lp}=${tp}"
        confirm "Add another port?" no || break
    done
    TUN[GO_PORTS]="$list"
}

gost_validate() {
    is_port "${TUN[GO_PORT]:-}"  || { log_error "invalid relay port"; return 1; }
    [[ -n "${TUN[GO_PASS]:-}" ]] || { log_error "empty password"; return 1; }
    if [[ "${TUN[GO_ROLE]}" == client ]]; then
        is_ipv4 "${TUN[REMOTE_IP]:-}" || { log_error "invalid relay server IP"; return 1; }
        [[ -n "${TUN[GO_PORTS]:-}" ]] || { log_error "at least one port mapping required"; return 1; }
    fi
    return 0
}

# gost_generate_config — render the 0700 wrapper script that runs gost.
gost_generate_config() {
    local file; file="$(gost_wrapper "${TUN[NAME]}")"
    mkdir -p "$TM_GOST_DIR"
    local tmp; tmp="$(mktemp)"
    local proto="${TUN[GO_PROTO]}" cred="${TUN[GO_USER]}:${TUN[GO_PASS]}"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by Tunnel Manager — do not edit.\n'
        if [[ "${TUN[GO_ROLE]}" == server ]]; then
            printf 'exec %s -L "relay+%s://%s@:%s"\n' "$(gost_bin)" "$proto" "$cred" "${TUN[GO_PORT]}"
        else
            printf 'exec %s \\\n' "$(gost_bin)"
            local IFS=';' e lp tp
            for e in ${TUN[GO_PORTS]}; do
                IFS='=' read -r lp tp <<<"$e"
                printf '  -L "tcp://:%s/%s:%s" \\\n' "$lp" "${TUN[GO_TARGET]:-127.0.0.1}" "$tp"
            done
            printf '  -F "relay+%s://%s@%s:%s"\n' "$proto" "$cred" "${TUN[REMOTE_IP]}" "${TUN[GO_PORT]}"
        fi
    } >"$tmp"
    chmod 700 "$tmp"; mv -f "$tmp" "$file"; chmod 700 "$file"
    log_debug "wrote gost wrapper $file"
}

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
gost_up() {
    gost_ensure_binary || return 1
    gost_generate_config
    log_ok "GOST '${TUN[NAME]}' prepared"
}
gost_down() { return 0; }

gost_render_unit() {
    cat <<EOF
[Unit]
Description=Tunnel Manager - ${TUN[NAME]} (GOST)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=${TM_CTL} __up ${TUN[NAME]}
ExecStart=/usr/bin/env bash $(gost_wrapper "${TUN[NAME]}")
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

gost_health() { systemctl is-active --quiet "$(unit_name "$1")"; }
gost_sample() { printf '0 0'; }

gost_status() {
    ui_kv "Role"      "${TUN[GO_ROLE]}"
    ui_kv "Transport" "relay+${TUN[GO_PROTO]}"
    if [[ "${TUN[GO_ROLE]}" == server ]]; then
        ui_kv "Listen"  ":${TUN[GO_PORT]}"
    else
        ui_kv "Relay"   "${TUN[REMOTE_IP]}:${TUN[GO_PORT]}   maps: ${TUN[GO_PORTS]} → ${TUN[GO_TARGET]:-127.0.0.1}"
    fi
    if is_elf "$(gost_bin)"; then ui_kv "Binary" "$(gost_bin)"; else ui_kv "Binary" "$(status_dot down) not installed"; fi
}
