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

# rathole_prepare_transport — mint whatever the chosen transport needs, ONCE, and
# into the shared config so BOTH sides get it.
#
# That sharing is the whole difficulty. The server needs the noise private key and
# the client the matching public one; for tls the server needs a PKCS#12 identity
# and the client something that trusts it. Neither side can generate its half
# independently — they would not match — and the panel's provisioning copies
# VALUES between the two hosts, never files. So the material is generated once,
# both halves are stored here, and each side writes out only the file it needs
# (rathole_materialise_tls).
rathole_prepare_transport() {
    case "${TUN[RH_TRANSPORT]}" in
        noise)
            if [[ -z "${TUN[RH_NOISE_PRIV]:-}" || -z "${TUN[RH_NOISE_PUB]:-}" ]]; then
                local out
                # "Private Key:\n<b64>\n\nPublic Key:\n<b64>" — the base64 lines are
                # the only ones that are not a label or blank.
                out="$("$(rathole_bin)" --genkey 2>/dev/null | grep -v ':' | grep -v '^$')" || out=""
                TUN[RH_NOISE_PRIV]="$(printf '%s\n' "$out" | sed -n '1p')"
                TUN[RH_NOISE_PUB]="$(printf '%s\n' "$out" | sed -n '2p')"
                if [[ -z "${TUN[RH_NOISE_PRIV]}" || -z "${TUN[RH_NOISE_PUB]}" ]]; then
                    log_warn "rathole: could not generate a noise keypair; falling back to tcp transport"
                    TUN[RH_TRANSPORT]=tcp
                fi
            fi
            ;;
        tls|websocket)
            # A hostname the cert is issued for and the client verifies. Not a real
            # DNS name: nothing resolves it, the client is told to expect exactly it,
            # and a fixed string would be a fingerprint shared by every install.
            : "${TUN[RH_TLS_HOST]:=$(gen_secret 8).local}"
            if [[ -z "${TUN[RH_TLS_P12]:-}" || -z "${TUN[RH_TLS_CRT]:-}" ]]; then
                rathole_gen_selfsigned || {
                    log_warn "rathole: could not build a TLS identity (openssl missing?); falling back to tcp transport"
                    TUN[RH_TRANSPORT]=tcp
                }
            fi
            ;;
    esac
}

# rathole_gen_selfsigned — a self-signed cert for RH_TLS_HOST, stored in the config
# as base64: the PKCS#12 the server presents (RH_TLS_P12) and the PEM the client
# trusts (RH_TLS_CRT). Both travel as values, so provisioning carries them across.
rathole_gen_selfsigned() {
    command -v openssl >/dev/null 2>&1 || return 1
    local d; d="$(mktemp -d)" || return 1
    local pass; pass="$(gen_secret 16)"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -subj "/CN=${TUN[RH_TLS_HOST]}" \
        -addext "subjectAltName=DNS:${TUN[RH_TLS_HOST]}" \
        -keyout "$d/k.pem" -out "$d/c.pem" >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
    openssl pkcs12 -export -out "$d/id.p12" -inkey "$d/k.pem" -in "$d/c.pem" \
        -passout "pass:$pass" >/dev/null 2>&1 || { rm -rf "$d"; return 1; }
    TUN[RH_TLS_P12]="$(base64 -w0 <"$d/id.p12" 2>/dev/null || base64 <"$d/id.p12" | tr -d '\n')"
    TUN[RH_TLS_CRT]="$(base64 -w0 <"$d/c.pem" 2>/dev/null || base64 <"$d/c.pem" | tr -d '\n')"
    TUN[RH_TLS_PASS]="$pass"
    rm -rf "$d"
    [[ -n "${TUN[RH_TLS_P12]}" && -n "${TUN[RH_TLS_CRT]}" ]]
}

# rathole_materialise_tls — write this side's half of the shared TLS material to
# disk and echo the path. Server wants the PKCS#12 identity, client the PEM to
# trust. Both live in the config as base64 (see rathole_prepare_transport) because
# provisioning copies values between the hosts, never files.
rathole_materialise_tls() {
    local what="$1" b64 out
    case "$what" in
        p12) b64="${TUN[RH_TLS_P12]:-}"; out="$TM_RATHOLE_DIR/${TUN[NAME]}.p12" ;;
        crt) b64="${TUN[RH_TLS_CRT]:-}"; out="$TM_RATHOLE_DIR/${TUN[NAME]}.crt" ;;
        *) return 1 ;;
    esac
    [[ -n "$b64" ]] || return 1
    mkdir -p "$TM_RATHOLE_DIR"
    printf '%s' "$b64" | base64 -d >"$out" 2>/dev/null || return 1
    chmod 600 "$out"
    printf '%s' "$out"
}

# rathole_transport_block server|client — the [<side>.transport] TOML, or nothing
# for the plain tcp transport (rathole's own default, so the block is noise).
#
# The service type (tcp/udp) is INDEPENDENT of this: rathole forwards either
# protocol over any of these carriers, which is the whole reason it can give one
# tunnel both DPI cover and L2TP's UDP — something backhaul and backpack cannot,
# their accept_udp being wired to the plain TcpTransport alone.
rathole_transport_block() {
    local side="$1" t="${TUN[RH_TRANSPORT]:-tcp}" p
    [[ "$t" == tcp ]] && return 0
    printf '[%s.transport]\n' "$side"
    printf 'type = "%s"\n' "$t"
    case "$t" in
        noise)
            printf '[%s.transport.noise]\n' "$side"
            if [[ "$side" == server ]]; then
                printf 'local_private_key = "%s"\n\n' "${TUN[RH_NOISE_PRIV]}"
            else
                printf 'remote_public_key = "%s"\n\n' "${TUN[RH_NOISE_PUB]}"
            fi
            ;;
        websocket)
            # tls = true wraps the websocket in TlsTransport, which then reads the
            # SAME [transport.tls] block below — so both are emitted.
            printf '[%s.transport.websocket]\ntls = true\n' "$side"
            rathole_tls_block "$side"
            ;;
        tls)
            rathole_tls_block "$side"
            ;;
    esac
}

rathole_tls_block() {
    local side="$1" p
    printf '[%s.transport.tls]\n' "$side"
    if [[ "$side" == server ]]; then
        p="$(rathole_materialise_tls p12)" || { log_warn "rathole: TLS identity missing"; printf '\n'; return 0; }
        printf 'pkcs12 = "%s"\n' "$p"
        printf 'pkcs12_password = "%s"\n\n' "${TUN[RH_TLS_PASS]:-}"
    else
        p="$(rathole_materialise_tls crt)" || { log_warn "rathole: TLS cert missing"; printf '\n'; return 0; }
        printf 'trusted_root = "%s"\n' "$p"
        printf 'hostname = "%s"\n\n' "${TUN[RH_TLS_HOST]:-}"
    fi
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
    # Carries UDP on every one of these, unlike backhaul/backpack whose accept_udp
    # is wired to their plain TCP transport alone — so this is a free choice, not a
    # trade of DPI cover against being able to relay L2TP.
    ask_menu TUN[RH_TRANSPORT] \
        "Transport (websocket = looks like HTTPS; noise = encrypted, no certs; tcp = bare)" \
        "${TUN[RH_TRANSPORT]:-tcp}" \
        "$([[ "${TUN[RH_TRANSPORT]:-tcp}" == websocket ]] && echo tcp || echo websocket)" \
        noise tls
    ask TUN[RH_TOKEN] "Shared token (blank = auto; MUST match the other side)" ""
    [[ -n "${TUN[RH_TOKEN]}" ]] || TUN[RH_TOKEN]="$(gen_secret 24)"
    local def_local; def_local="$(detect_local_ip)"
    ask_valid TUN[LOCAL_IP] "This server's IP" is_ipv4 "$def_local"
    [[ "$role" == client ]] && ask_valid TUN[REMOTE_IP] "Server (other side) public IP" is_ipv4

    log_info "Enter the SAME port pairs on both sides (public port users hit = local service port)."
    rathole_wizard_ports
    # Mint the noise keypair / TLS identity the chosen transport needs. Both halves
    # are stored in the config so the OTHER side gets them too — they cannot be
    # generated independently and still match.
    rathole_prepare_transport
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
            rathole_transport_block server
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
            rathole_transport_block client
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
