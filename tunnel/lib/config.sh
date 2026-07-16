#!/usr/bin/env bash
# lib/config.sh — tunnel profile persistence.
#
# A tunnel profile is a flat KEY=VALUE file at $TM_TUNNELS_DIR/<name>.conf.
# It is loaded into the global associative array TUN via load_tunnel(), and
# written back with save_tunnel(). Only whitelisted UPPER_SNAKE keys are read,
# so a profile file can never inject arbitrary shell.

declare -gA TUN=()

# cfg_tunnel_file NAME -> path
cfg_tunnel_file() { printf '%s/%s.conf' "$TM_TUNNELS_DIR" "$1"; }

# tunnel_exists NAME
tunnel_exists() { [[ -f "$(cfg_tunnel_file "$1")" ]]; }

# list_tunnels — print one profile name per line (sorted).
list_tunnels() {
    local f name
    shopt -s nullglob
    for f in "$TM_TUNNELS_DIR"/*.conf; do
        name="$(basename "$f" .conf)"
        printf '%s\n' "$name"
    done | sort
    shopt -u nullglob
}

# count_tunnels
count_tunnels() { list_tunnels | grep -c . || true; }

# load_tunnel NAME — populate the TUN array. Returns 1 if not found.
load_tunnel() {
    local name="$1" file k v
    file="$(cfg_tunnel_file "$name")"
    [[ -f "$file" ]] || return 1
    TUN=()
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        TUN["$k"]="$v"
    done <"$file"
    return 0
}

# save_tunnel — write the current TUN array back to disk (atomic).
# Requires TUN[NAME] to be set.
save_tunnel() {
    local name="${TUN[NAME]:-}"
    [[ -n "$name" ]] || { log_error "save_tunnel: TUN[NAME] is empty"; return 1; }
    local file tmp k
    file="$(cfg_tunnel_file "$name")"
    tmp="$(mktemp "${file}.XXXXXX")"
    {
        printf '# Tunnel Manager profile — generated %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        for k in $(printf '%s\n' "${!TUN[@]}" | sort); do
            printf '%s=%s\n' "$k" "${TUN[$k]}"
        done
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$file"
    log_debug "saved profile $name"
}

# delete_tunnel_file NAME
delete_tunnel_file() { rm -f "$(cfg_tunnel_file "$1")"; }

# tget KEY [DEFAULT] — read a value from the loaded TUN array.
tget() { local k="$1"; printf '%s' "${TUN[$k]:-${2:-}}"; }

# ---------------------------------------------------------------------------
# Conflict detection
# ---------------------------------------------------------------------------

# profile_conflicts NAME PROTOCOL LOCAL REMOTE PORT KEY
# Scans existing profiles for collisions. Prints human-readable reasons and
# returns 1 if any conflict is found. The candidate NAME is skipped (for edit).
profile_conflicts() {
    local cand="$1" proto="$2" local_ip="$3" remote_ip="$4" port="$5" gkey="$6"
    local other bad=0
    while read -r other; do
        [[ -z "$other" || "$other" == "$cand" ]] && continue
        load_tunnel "$other" || continue
        # Same GRE endpoint pair with same key = duplicate tunnel.
        if [[ "$proto" == gre && "${TUN[PROTOCOL]}" == gre ]]; then
            if [[ "${TUN[LOCAL_IP]}" == "$local_ip" && "${TUN[REMOTE_IP]}" == "$remote_ip" \
                  && "${TUN[GRE_KEY]:-}" == "$gkey" ]]; then
                log_error "conflict: GRE endpoint $local_ip->$remote_ip key='$gkey' already used by '$other'"
                bad=1
            fi
        fi
        # Same Paqet listen port on this host = collision.
        if [[ "$proto" == paqet && "${TUN[PROTOCOL]}" == paqet && -n "$port" ]]; then
            if [[ "${TUN[PAQET_PORT]:-}" == "$port" ]]; then
                log_error "conflict: Paqet port $port already used by '$other'"
                bad=1
            fi
        fi
    done < <(list_tunnels)
    return "$bad"
}
