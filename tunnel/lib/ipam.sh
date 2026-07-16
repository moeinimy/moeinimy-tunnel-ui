#!/usr/bin/env bash
# lib/ipam.sh — automatic /30 allocation for tunnel inner addresses.
#
# Each tunnel gets a unique /30 carved from TM_IPAM_POOL (default 10.20.0.0/16).
# Index i maps to the i-th /30 block: base = pool_start + i*4.
#   host .1 -> foreign side, host .2 -> iran side.
# Allocations are recorded in $TM_STATE_DIR/ipam.db as "name<TAB>index".

: "${TM_IPAM_POOL_BASE:=10.20.0.0}"   # network start (must be /30-aligned start)
TM_IPAM_DB="$TM_STATE_DIR/ipam.db"

# _ip_to_int A.B.C.D -> integer
_ip_to_int() {
    local IFS=. a b c d; read -r a b c d <<<"$1"
    printf '%d' "$(( (a<<24) + (b<<16) + (c<<8) + d ))"
}

# _int_to_ip N -> A.B.C.D
_int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d' "$(( (n>>24)&255 ))" "$(( (n>>16)&255 ))" "$(( (n>>8)&255 ))" "$(( n&255 ))"
}

_ipam_used_indexes() {
    [[ -f "$TM_IPAM_DB" ]] || return 0
    awk -F'\t' '{print $2}' "$TM_IPAM_DB"
}

# ipam_index_for NAME -> prints stored index or empty.
ipam_index_for() {
    [[ -f "$TM_IPAM_DB" ]] || return 0
    awk -F'\t' -v n="$1" '$1==n {print $2; exit}' "$TM_IPAM_DB"
}

# ipam_alloc NAME -> prints a newly allocated index (lowest free), records it.
ipam_alloc() {
    local name="$1"
    mkdir -p "$TM_STATE_DIR"
    touch "$TM_IPAM_DB"
    # Reuse existing allocation if present (idempotent).
    local existing; existing="$(ipam_index_for "$name")"
    if [[ -n "$existing" ]]; then printf '%s' "$existing"; return 0; fi
    # Find lowest free index starting at 1 (index 0 reserved).
    local used i=1
    used="$(_ipam_used_indexes | sort -n | tr '\n' ' ')"
    while [[ " $used " == *" $i "* ]]; do i=$(( i + 1 )); done
    printf '%s\t%s\n' "$name" "$i" >>"$TM_IPAM_DB"
    printf '%s' "$i"
}

# ipam_free NAME — drop the allocation record.
ipam_free() {
    local name="$1"
    [[ -f "$TM_IPAM_DB" ]] || return 0
    local tmp; tmp="$(mktemp)"
    awk -F'\t' -v n="$name" '$1!=n' "$TM_IPAM_DB" >"$tmp" && mv -f "$tmp" "$TM_IPAM_DB"
}

# ipam_addr INDEX SIDE -> prints host IP for iran|foreign
ipam_addr() {
    local index="$1" side="$2" base offset
    base="$(_ip_to_int "$TM_IPAM_POOL_BASE")"
    offset=$(( index * 4 ))
    case "$side" in
        foreign) _int_to_ip "$(( base + offset + 1 ))" ;;   # .1
        iran)    _int_to_ip "$(( base + offset + 2 ))" ;;   # .2
        *) return 1 ;;
    esac
}

# ipam_network INDEX -> prints the /30 network address (for display).
ipam_network() {
    local base; base="$(_ip_to_int "$TM_IPAM_POOL_BASE")"
    _int_to_ip "$(( base + $1 * 4 ))"
}
