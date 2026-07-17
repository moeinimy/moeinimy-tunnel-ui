#!/usr/bin/env bash
# modules/schema.sh — machine-readable form schema for the web panel.
#
# `tunnelctl json schema` emits, for every protocol, the fields the operator can
# actually set — mirroring each driver's wizard prompts (drivers/<p>_wizard), so
# the panel renders the SAME questions the CLI asks instead of a hardcoded guess.
# Anything derived (driver role, IPAM inner IPs, mux flags, IFNAME) is NOT listed:
# <p>_prepare fills those. Keep in sync with the wizards.
#
# Every protocol has TWO kinds of port, which the labels keep distinct:
#   * the TUNNEL port  — the server<->server link itself (one number)
#   * the CLIENT ports — what users connect to, mapped to the far side
#                        ("listen=target"); type=portmap so the UI renders a
#                        pair of number inputs instead of a raw "443=443" string.
#
# Field object:
#   key      TUN key to send back in `tunnelctl create KEY=VALUE`
#   label    human label
#   type     text | port | number | select | password | ip | portmap | forwards
#            portmap  -> "listen=target[;listen=target...]"
#            forwards -> "proto:local:dest[;proto:local:dest...]"
#   default  prefilled value ("" = auto-generate for password)
#   options  [..] for type=select
#   side     both | iran | foreign   — which ROLE the field applies to; the panel
#            hides fields that don't apply to the chosen role
#   help     one-line hint

# Separators are emitted automatically: _sp_open resets the counter and _sf adds a
# comma before every field after the first. Doing it by hand is how you ship a
# schema that fails JSON.parse on one protocol only.
_SF_N=0
_SP_N=0

# _sf key label type default options side help  -> emit one field object
_sf() {
    local key="$1" label="$2" type="$3" def="$4" opts="$5" side="${6:-both}" help="${7:-}"
    if [[ $_SF_N -gt 0 ]]; then printf ','; fi
    _SF_N=$(( _SF_N + 1 ))
    printf '{"key":"%s","label":"%s","type":"%s","default":"%s","side":"%s","help":"%s","options":[' \
        "$(json_escape "$key")" "$(json_escape "$label")" "$(json_escape "$type")" \
        "$(json_escape "$def")" "$(json_escape "$side")" "$(json_escape "$help")"
    local first=1 o
    for o in $opts; do
        if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
        printf '"%s"' "$(json_escape "$o")"
    done
    printf ']}'
}

# _sp_open proto label — start a protocol block (and reset the field separator).
_sp_open() {
    if [[ $_SP_N -gt 0 ]]; then printf ','; fi
    _SP_N=$(( _SP_N + 1 ))
    _SF_N=0
    printf '"%s":{"label":"%s","fields":[' "$1" "$(json_escape "$2")"
}
_sp_close() { printf ']}'; }

_TUNNEL_PORT_HELP="The link between your two servers"
_CLIENT_PORTS_LABEL="Client ports (users connect here → far side)"

api_schema() {
    _SP_N=0
    printf '{'

    # ---- GOST: foreign = relay server, iran = client that dials out ---------
    _sp_open gost "GOST (TCP relay)"
    _sf GO_PROTO  "Relay transport" select mtls "mtls mwss grpc wss tcp" both \
        "mtls/mwss look like HTTPS and survive DPI; tcp only for clean paths"
    _sf GO_PORT   "Tunnel port (server ↔ server)" port 8443 "" both "$_TUNNEL_PORT_HELP — the foreign relay listens here"
    _sf GO_PASS   "Relay password" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf GO_PORTS  "$_CLIENT_PORTS_LABEL" portmap "443=443" "" iran \
        "Ports users hit on the Iran side, mapped to ports on the relay side"
    _sf GO_TARGET "Target host" ip "127.0.0.1" "" iran "Host the relay dials on the foreign side"
    _sp_close

    # ---- BackPack: iran = server users hit, foreign = client ----------------
    _sp_open backpack "BackPack (wssmux)"
    _sf BP_TRANSPORT "Transport" select wssmux "wssmux wsmux wss ws tcpmux tcp" both \
        "wssmux = TLS websocket + mux: DPI-resistant, best for xray/Reality"
    _sf BP_PORT "Tunnel port (server ↔ server)" port 8444 "" both "$_TUNNEL_PORT_HELP"
    _sf BP_TOKEN "Shared token" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf BP_PORTS "$_CLIENT_PORTS_LABEL" portmap "443=443" "" iran \
        "Ports users connect to on the Iran side, forwarded over the tunnel"
    _sf BP_EDGE "CDN edge IP" ip "" "" foreign "Optional: dial this edge instead of the server (ws/wss only)"
    _sp_close

    # ---- Backhaul: iran = server, foreign = client --------------------------
    _sp_open backhaul "Backhaul"
    _sf BH_TRANSPORT "Transport" select tcpmux "tcp tcpmux ws wsmux" both ""
    _sf BH_PORT "Tunnel port (server ↔ server)" port 3080 "" both "$_TUNNEL_PORT_HELP"
    _sf BH_TOKEN "Shared token" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf BH_PORTS "$_CLIENT_PORTS_LABEL" portmap "443=443" "" iran "Ports users connect to on the Iran side"
    _sp_close

    # ---- Rathole: iran = server, foreign = client ---------------------------
    _sp_open rathole "Rathole"
    _sf RH_PORT "Tunnel port (server ↔ server)" port 2333 "" both "$_TUNNEL_PORT_HELP"
    _sf RH_TOKEN "Shared token" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf RH_PORTS "Client ports (public on Iran → local on foreign)" portmap "443=443" "" both ""
    _sp_close

    # ---- FRP: iran = frps server, foreign = frpc client ---------------------
    _sp_open frp "FRP"
    _sf FRP_PORT "Tunnel port (server ↔ server)" port 7000 "" both "frps bindPort — $_TUNNEL_PORT_HELP"
    _sf FRP_TOKEN "Shared token" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf FRP_PORTS "Client ports (remote on Iran → local on foreign)" portmap "443=443" "" both ""
    _sp_close

    # ---- Hysteria: QUIC/UDP, foreign = server ------------------------------
    _sp_open hysteria "Hysteria 2 (QUIC/UDP)"
    _sf HY_PORT "Tunnel port (server ↔ server, UDP)" port 8445 "" both \
        "QUIC/UDP — dead if your provider blocks inbound UDP"
    _sf HY_PASS "Password" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf HY_OBFS "Salamander obfuscation" select on "on off" both "Recommended vs DPI; must match both sides"
    _sf HY_UP "Upload speed (mbps)" number 100 "" both ""
    _sf HY_DOWN "Download speed (mbps)" number 100 "" both ""
    _sf HY_PORTS "$_CLIENT_PORTS_LABEL" portmap "443=443" "" iran ""
    _sf HY_TARGET "Target host" ip "127.0.0.1" "" iran "Host the exit forwards to on the foreign side"
    _sp_close

    # ---- Paqet: KCP/raw socket, foreign = server ---------------------------
    _sp_open paqet "Paqet (KCP/raw)"
    _sf PAQET_PORT "Tunnel port (server ↔ server)" port 4000 "" both "$_TUNNEL_PORT_HELP"
    _sf PAQET_SECRET "Shared secret" password "" "" both "Blank = auto-generate; must match on both sides"
    _sf PAQET_MODE "KCP mode" select fast "fast normal fast2 fast3" both ""
    _sf PAQET_CIPHER "Encryption" select aes-128-gcm "aes-128-gcm aes-256-gcm none" both ""
    _sf PAQET_CONN "Parallel connections" number 4 "" both "1-32"
    _sf PAQET_IFACE "Network interface" text "" "" both "Blank = auto-detect the WAN interface"
    _sf PAQET_MAC "Gateway MAC" text "" "" both "Blank = auto-detect (Paqet's raw socket needs it)"
    _sf PAQET_TRAFFIC "Traffic type" select port-forward "port-forward socks5" iran ""
    _sf PAQET_SOCKS_PORT "Local SOCKS5 port" port 1080 "" iran "Only when traffic type = socks5"
    _sf FORWARDS "$_CLIENT_PORTS_LABEL" forwards "tcp:443:443" "" iran "Only when traffic type = port-forward"
    _sf PAQET_TARGET_HOST "Target host" ip "127.0.0.1" "" iran ""
    _sp_close

    # ---- GRE: kernel tunnel with a /30 inner subnet -------------------------
    _sp_open gre "GRE (kernel)"
    _sf GRE_KEY "GRE key" text "" "" both \
        "Blank = keyless (recommended: many ISPs drop keyed GRE). Only for several tunnels between the same IP pair"
    _sf ENABLE_NAT "Enable NAT" select no "no yes" foreign "Let the Iran peer route internet out through this server"
    _sf FORWARD_MODE "Forwarding mode" select none "none all ports" iran "How traffic uses the tunnel"
    _sf FORWARD_EXCEPT "Keep local (ports)" text "22" "" iran "Only for mode=all — KEEP YOUR SSH PORT here"
    _sf FORWARDS "$_CLIENT_PORTS_LABEL" forwards "" "" iran "Only when forwarding mode = ports"
    _sp_close

    printf '}\n'
}
