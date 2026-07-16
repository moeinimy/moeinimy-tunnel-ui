#!/usr/bin/env bash
# lib/validate.sh — input validation helpers. All return 0 (valid) / 1 (invalid).

# is_ipv4 ADDR — strict dotted-quad validation, each octet 0-255.
is_ipv4() {
    local ip="$1" o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"
    o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
    local o
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# is_public_ipv4 ADDR — valid IPv4 that is not obviously private/reserved.
# Used only for warnings, never to hard-block (some setups use private WAN).
is_public_ipv4() {
    is_ipv4 "$1" || return 1
    case "$1" in
        10.*|127.*|0.*|169.254.*|192.168.*) return 1 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
    esac
    return 0
}

# is_port N — integer in 1..65535.
is_port() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( $1 >= 1 && $1 <= 65535 ))
}

# is_mtu N — reasonable tunnel MTU range.
is_mtu() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    (( $1 >= 576 && $1 <= 9000 ))
}

# is_tunnel_name NAME — lowercase alnum, dash, underscore; 1..24 chars.
is_tunnel_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,23}$ ]]
}

# is_mac ADDR — colon-separated hex MAC.
is_mac() {
    [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]
}

# is_uint N — non-negative integer.
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# is_iface NAME — interface exists on this host.
is_iface() { [[ -d "/sys/class/net/$1" ]]; }
