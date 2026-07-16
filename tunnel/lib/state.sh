#!/usr/bin/env bash
# lib/state.sh — per-tunnel runtime state (separate from immutable config so
# statistics never touch the profile file). One KEY=VALUE file per tunnel at
# $TM_STATE_TUNNELS/<name>.state.

declare -gA ST=()

state_file() { printf '%s/%s.state' "$TM_STATE_TUNNELS" "$1"; }

# state_load NAME — populate the ST array (empty if no state yet).
state_load() {
    local name="$1" file k v
    file="$(state_file "$name")"
    ST=()
    [[ -f "$file" ]] || return 0
    while IFS='=' read -r k v || [[ -n "$k" ]]; do
        [[ "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
        ST["$k"]="$v"
    done <"$file"
}

# state_save NAME — atomically persist the ST array.
state_save() {
    local name="$1" file tmp k
    file="$(state_file "$name")"
    mkdir -p "$TM_STATE_TUNNELS"
    tmp="$(mktemp "${file}.XXXXXX")"
    for k in "${!ST[@]}"; do printf '%s=%s\n' "$k" "${ST[$k]}"; done >"$tmp"
    mv -f "$tmp" "$file"
}

state_delete() { rm -f "$(state_file "$1")"; }

# state_get NAME KEY [DEFAULT]
state_get() {
    local name="$1" key="$2" def="${3:-}"
    state_load "$name"
    printf '%s' "${ST[$key]:-$def}"
}

# state_set NAME KEY VALUE [KEY VALUE ...] — merge and persist.
state_set() {
    local name="$1"; shift
    state_load "$name"
    while [[ $# -ge 2 ]]; do ST["$1"]="$2"; shift 2; done
    state_save "$name"
}
