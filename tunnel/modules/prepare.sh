#!/usr/bin/env bash
# modules/prepare.sh — non-interactive field derivation for `tunnelctl create`.
#
# The interactive wizards (drivers/<p>_wizard) derive a lot of fields the operator
# never types: the driver's own role, this host's IP, the WAN interface and
# gateway MAC, IPAM inner addressing, mux flags, targets and defaults.
# `tunnelctl create KEY=VALUE …` (used by the web panel and by node
# auto-provisioning) has no TTY, so each driver gets a <p>_prepare here that fills
# exactly what its wizard would have.
#
# Rules:
#   * Only fields left EMPTY are filled — anything the panel/operator supplied wins.
#   * Each function mirrors its driver's wizard; keep them in sync.
#
# CRITICAL — the role mapping is per-driver and NOT uniform. Mirrors `def_role`:
#   gost, hysteria, paqet      -> foreign = server, iran = client
#   backhaul, backpack,
#   rathole, frp               -> iran = server, foreign = client (users hit iran)
# Getting this backwards silently builds a tunnel that never connects.

_prep_role_foreign_server() { [[ "${TUN[ROLE]:-foreign}" == foreign ]] && printf server || printf client; }
_prep_role_iran_server()    { [[ "${TUN[ROLE]:-foreign}" == foreign ]] && printf client || printf server; }

# Default port map when the operator didn't specify one: listen on 443 here and
# forward to 443 on the far side (the usual xray/Reality inbound).
_PREP_DEFAULT_PORTS="443=443"

# _prep_common — fields every driver validates. LOCAL_IP is the big one: the
# wizards prompt for it with detect_local_ip as the default, so a non-interactive
# create left it empty and gre/paqet failed with "invalid LOCAL_IP".
_prep_common() {
    : "${TUN[LOCAL_IP]:=$(detect_local_ip)}"
}

# --- GRE (kernel; needs IPAM inner addressing) -------------------------------
gre_prepare() {
    _prep_common
    : "${TUN[MTU]:=1400}"
    : "${TUN[TTL]:=255}"
    : "${TUN[INNER_CIDR]:=30}"
    : "${TUN[IFNAME]:=$(gre_ifname "${TUN[NAME]}")}"
    # Allocate the /30 inner subnet exactly like the wizard does.
    if [[ -z "${TUN[IPAM_INDEX]:-}" ]]; then
        local idx; idx="$(ipam_alloc "${TUN[NAME]}")" || { log_error "gre: IPAM allocation failed"; return 1; }
        TUN[IPAM_INDEX]="$idx"
    fi
    local i="${TUN[IPAM_INDEX]}"
    if [[ "${TUN[ROLE]}" == iran ]]; then
        : "${TUN[INNER_LOCAL]:=$(ipam_addr "$i" iran)}"
        : "${TUN[INNER_REMOTE]:=$(ipam_addr "$i" foreign)}"
    else
        : "${TUN[INNER_LOCAL]:=$(ipam_addr "$i" foreign)}"
        : "${TUN[INNER_REMOTE]:=$(ipam_addr "$i" iran)}"
    fi
    # Keyless by default: many ISPs (Iran's border included) drop keyed GRE.
    : "${TUN[GRE_KEY]:=}"
    : "${TUN[ENABLE_NAT]:=no}"
    : "${TUN[FORWARD_MODE]:=none}"
    : "${TUN[FORWARDS]:=}"
    : "${TUN[FORWARD_EXCEPT]:=22}"
}

# --- Paqet (KCP/raw; foreign = server) ---------------------------------------
paqet_prepare() {
    _prep_common
    : "${TUN[PAQET_ROLE]:=$(_prep_role_foreign_server)}"
    [[ "${TUN[PAQET_ROLE]}" == server ]] && : "${TUN[REMOTE_IP]:=0.0.0.0}"
    : "${TUN[PAQET_PORT]:=4000}"
    [[ -n "${TUN[PAQET_SECRET]:-}" ]] || TUN[PAQET_SECRET]="$(gen_secret 32)"
    : "${TUN[PAQET_MODE]:=fast}"
    : "${TUN[PAQET_CIPHER]:=aes-128-gcm}"
    : "${TUN[PAQET_CONN]:=4}"
    : "${TUN[MTU]:=1350}"
    : "${TUN[PAQET_IFACE]:=$(detect_wan_iface)}"
    : "${TUN[PAQET_MAC]:=$(detect_gateway_mac)}"
    : "${TUN[PAQET_TARGET_HOST]:=127.0.0.1}"
    if [[ "${TUN[PAQET_ROLE]}" == client ]]; then
        : "${TUN[PAQET_TRAFFIC]:=port-forward}"
        if [[ "${TUN[PAQET_TRAFFIC]}" == socks5 ]]; then
            : "${TUN[PAQET_SOCKS_PORT]:=1080}"
        else
            : "${TUN[FORWARDS]:=tcp:443:443}"
        fi
    else
        TUN[PAQET_TRAFFIC]="server"
    fi
    : "${TUN[PAQET_SOCKS_PORT]:=}"
    : "${TUN[FORWARDS]:=}"
}

# --- GOST (foreign = server/relay; iran = client that dials out) -------------
gost_prepare() {
    _prep_common
    : "${TUN[GO_ROLE]:=$(_prep_role_foreign_server)}"
    : "${TUN[GO_PROTO]:=mtls}"
    : "${TUN[GO_PORT]:=8443}"
    : "${TUN[GO_USER]:=tm}"
    : "${TUN[MTU]:=1400}"
    [[ -n "${TUN[GO_PASS]:-}" ]] || TUN[GO_PASS]="$(gen_secret 20)"
    if [[ "${TUN[GO_ROLE]}" == client ]]; then
        : "${TUN[GO_TARGET]:=127.0.0.1}"
        : "${TUN[GO_PORTS]:=$_PREP_DEFAULT_PORTS}"
    fi
}

# --- BackPack (iran = server users hit; foreign = client) --------------------
backpack_prepare() {
    _prep_common
    : "${TUN[BP_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[BP_TRANSPORT]:=wssmux}"
    : "${TUN[BP_PORT]:=8443}"
    : "${TUN[MTU]:=1400}"
    [[ -n "${TUN[BP_TOKEN]:-}" ]] || TUN[BP_TOKEN]="$(gen_secret 32)"
    [[ "${TUN[BP_ROLE]}" == server ]] && : "${TUN[BP_PORTS]:=$_PREP_DEFAULT_PORTS}"
    case "${TUN[BP_TRANSPORT]}" in *mux) TUN[BP_MUX]=8 ;; *) TUN[BP_MUX]="" ;; esac
    : "${TUN[BP_EDGE]:=}"
    : "${TUN[BP_PORTS]:=}"
}

# --- Backhaul (iran = server; foreign = client) ------------------------------
backhaul_prepare() {
    _prep_common
    : "${TUN[BH_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[BH_TRANSPORT]:=tcpmux}"
    : "${TUN[BH_PORT]:=3080}"
    : "${TUN[MTU]:=1400}"
    [[ -n "${TUN[BH_TOKEN]:-}" ]] || TUN[BH_TOKEN]="$(gen_secret 32)"
    [[ "${TUN[BH_ROLE]}" == server ]] && : "${TUN[BH_PORTS]:=$_PREP_DEFAULT_PORTS}"
    case "${TUN[BH_TRANSPORT]}" in *mux) TUN[BH_MUX]=8 ;; *) TUN[BH_MUX]="" ;; esac
    : "${TUN[BH_PORTS]:=}"
}

# --- Rathole (iran = server; foreign = client) -------------------------------
rathole_prepare() {
    _prep_common
    : "${TUN[RH_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[RH_PORT]:=2333}"
    : "${TUN[MTU]:=1400}"
    [[ -n "${TUN[RH_TOKEN]:-}" ]] || TUN[RH_TOKEN]="$(gen_secret 32)"
    : "${TUN[RH_PORTS]:=$_PREP_DEFAULT_PORTS}"
}

# --- FRP (iran = server/frps; foreign = client/frpc) -------------------------
frp_prepare() {
    _prep_common
    : "${TUN[FRP_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[FRP_PORT]:=7000}"
    : "${TUN[MTU]:=1400}"
    [[ -n "${TUN[FRP_TOKEN]:-}" ]] || TUN[FRP_TOKEN]="$(gen_secret 32)"
    : "${TUN[FRP_PORTS]:=$_PREP_DEFAULT_PORTS}"
}

# --- Hysteria (QUIC/UDP; foreign = server/exit; iran = client) ---------------
# NOTE: UDP. Dead on paths where the provider blocks inbound UDP — prefer a TCP
# carrier (GOST/BackPack) unless UDP is proven open end-to-end.
hysteria_prepare() {
    _prep_common
    : "${TUN[HY_ROLE]:=$(_prep_role_foreign_server)}"
    : "${TUN[HY_PORT]:=8443}"
    : "${TUN[HY_OBFS]:=on}"
    : "${TUN[HY_UP]:=100}"
    : "${TUN[HY_DOWN]:=100}"
    : "${TUN[MTU]:=1400}"
    [[ -n "${TUN[HY_PASS]:-}" ]] || TUN[HY_PASS]="$(gen_secret 32)"
    if [[ "${TUN[HY_ROLE]}" == client ]]; then
        : "${TUN[HY_TARGET]:=127.0.0.1}"
        : "${TUN[HY_PORTS]:=$_PREP_DEFAULT_PORTS}"
    fi
}
