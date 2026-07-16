#!/usr/bin/env bash
# drivers/driver.sh — transport driver dispatcher.
#
# Every protocol implements the same contract as functions prefixed with its
# name (gre_up, paqet_up, ...). The generic driver_* wrappers below look at
# TUN[PROTOCOL] and forward to the right implementation, so the rest of the
# codebase never hard-codes a protocol.
#
# Contract each driver MUST implement:
#   <p>_validate        validate TUN fields at add/edit time (0 ok / 1 bad)
#   <p>_up              create/bring up the tunnel (idempotent)
#   <p>_down            tear it down (idempotent, never fails hard)
#   <p>_render_unit     print a complete systemd unit file on stdout
#   <p>_status          print human-readable status lines
#   <p>_health NAME     return 0 if the tunnel is currently healthy
#   <p>_sample NAME     refresh RX/TX counters in state (best-effort)
#   <p>_wizard          interactive prompts populating TUN (add flow)

TM_SUPPORTED_PROTOCOLS=(gre paqet backhaul backpack rathole gost frp hysteria)

_driver_fn() {
    local proto="${TUN[PROTOCOL]:-}" fn="$1"
    [[ -n "$proto" ]] || { log_error "no protocol set on tunnel"; return 2; }
    local impl="${proto}_${fn}"
    if ! declare -F "$impl" >/dev/null; then
        log_error "driver '$proto' does not implement '$fn'"
        return 2
    fi
    "$impl" "${@:2}"
}

driver_validate()    { _driver_fn validate "$@"; }
driver_up()          { _driver_fn up "$@"; }
driver_down()        { _driver_fn down "$@"; }
driver_render_unit() { _driver_fn render_unit "$@"; }
driver_status()      { _driver_fn status "$@"; }
driver_wizard()      { _driver_fn wizard "$@"; }

# These two take a NAME and load their own profile/state as needed; they are
# called from the monitor where TUN may belong to another tunnel.
driver_health() {
    local name="$1"; load_tunnel "$name" || return 2
    _driver_fn health "$name"
}
driver_sample() {
    local name="$1"; load_tunnel "$name" || return 2
    _driver_fn sample "$name"
}

# is_protocol P — true if P is supported.
is_protocol() {
    local p
    for p in "${TM_SUPPORTED_PROTOCOLS[@]}"; do [[ "$p" == "$1" ]] && return 0; done
    return 1
}
