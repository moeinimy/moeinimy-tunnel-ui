#!/usr/bin/env bash
# modules/prepare.sh — non-interactive field derivation for `tunnelctl create`.
#
# The interactive wizards (drivers/<p>_wizard) derive a lot of fields that the
# operator never types: the driver's own role (server/client), the relay user,
# mux flags, targets and defaults. `tunnelctl create KEY=VALUE …` (used by the
# web panel and by node auto-provisioning) has no TTY, so each driver gets a
# <p>_prepare here that fills exactly what its wizard would have.
#
# CRITICAL — the role mapping is per-driver and NOT uniform. Each function below
# mirrors the `def_role` line in its own driver:
#   gost, hysteria            -> foreign = server, iran = client   (iran dials the relay)
#   backhaul, backpack,
#   rathole, frp              -> iran = server, foreign = client   (users connect to iran)
# Getting this backwards silently builds a tunnel that never connects, so keep
# each mapping in sync with its driver's wizard.
#
# Only fields left empty are filled — anything the panel/operator supplied wins.

# Role helpers, named for the convention they implement.
_prep_role_foreign_server() { [[ "${TUN[ROLE]:-foreign}" == foreign ]] && printf server || printf client; }
_prep_role_iran_server()    { [[ "${TUN[ROLE]:-foreign}" == foreign ]] && printf client || printf server; }

# Default port map used when the operator didn't specify one: listen on 443 here
# and forward to 443 on the far side (the usual xray/Reality inbound).
_PREP_DEFAULT_PORTS="443=443"

# --- GOST (foreign = server/relay; iran = client that dials out) -------------
gost_prepare() {
    : "${TUN[GO_ROLE]:=$(_prep_role_foreign_server)}"
    : "${TUN[GO_PROTO]:=mtls}"
    : "${TUN[GO_PORT]:=8443}"
    : "${TUN[GO_USER]:=tm}"
    [[ -n "${TUN[GO_PASS]:-}" ]] || TUN[GO_PASS]="$(gen_secret 20)"
    if [[ "${TUN[GO_ROLE]}" == client ]]; then
        : "${TUN[GO_TARGET]:=127.0.0.1}"
        : "${TUN[GO_PORTS]:=$_PREP_DEFAULT_PORTS}"
    fi
}

# --- BackPack (iran = server users hit; foreign = client that dials out) -----
backpack_prepare() {
    : "${TUN[BP_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[BP_TRANSPORT]:=wssmux}"
    : "${TUN[BP_PORT]:=8443}"
    [[ -n "${TUN[BP_TOKEN]:-}" ]] || TUN[BP_TOKEN]="$(gen_secret 32)"
    [[ "${TUN[BP_ROLE]}" == server ]] && : "${TUN[BP_PORTS]:=$_PREP_DEFAULT_PORTS}"
    case "${TUN[BP_TRANSPORT]}" in *mux) TUN[BP_MUX]=8 ;; *) TUN[BP_MUX]="" ;; esac
    : "${TUN[BP_EDGE]:=}"
}

# --- Backhaul (iran = server; foreign = client) ------------------------------
backhaul_prepare() {
    : "${TUN[BH_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[BH_TRANSPORT]:=tcpmux}"
    : "${TUN[BH_PORT]:=3080}"
    [[ -n "${TUN[BH_TOKEN]:-}" ]] || TUN[BH_TOKEN]="$(gen_secret 32)"
    [[ "${TUN[BH_ROLE]}" == server ]] && : "${TUN[BH_PORTS]:=$_PREP_DEFAULT_PORTS}"
    case "${TUN[BH_TRANSPORT]}" in *mux) TUN[BH_MUX]=8 ;; *) TUN[BH_MUX]="" ;; esac
}

# --- Rathole (iran = server; foreign = client) -------------------------------
rathole_prepare() {
    : "${TUN[RH_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[RH_PORT]:=2333}"
    [[ -n "${TUN[RH_TOKEN]:-}" ]] || TUN[RH_TOKEN]="$(gen_secret 32)"
    : "${TUN[RH_PORTS]:=$_PREP_DEFAULT_PORTS}"
}

# --- FRP (iran = server/frps; foreign = client/frpc) -------------------------
frp_prepare() {
    : "${TUN[FRP_ROLE]:=$(_prep_role_iran_server)}"
    : "${TUN[FRP_PORT]:=7000}"
    [[ -n "${TUN[FRP_TOKEN]:-}" ]] || TUN[FRP_TOKEN]="$(gen_secret 32)"
    : "${TUN[FRP_PORTS]:=$_PREP_DEFAULT_PORTS}"
}

# --- Hysteria (foreign = server/exit; iran = client) -------------------------
# NOTE: QUIC/UDP. Known not to work on paths where the provider blocks inbound
# UDP — prefer a TCP carrier (GOST/BackPack) unless UDP is proven open.
hysteria_prepare() {
    : "${TUN[HY_ROLE]:=$(_prep_role_foreign_server)}"
    : "${TUN[HY_PORT]:=8443}"
    : "${TUN[HY_OBFS]:=on}"
    : "${TUN[HY_UP]:=100}"
    : "${TUN[HY_DOWN]:=100}"
    [[ -n "${TUN[HY_PASS]:-}" ]] || TUN[HY_PASS]="$(gen_secret 32)"
    if [[ "${TUN[HY_ROLE]}" == client ]]; then
        : "${TUN[HY_TARGET]:=127.0.0.1}"
        : "${TUN[HY_PORTS]:=$_PREP_DEFAULT_PORTS}"
    fi
}
