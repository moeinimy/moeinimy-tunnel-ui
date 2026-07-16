#!/usr/bin/env bash
# lib/ui.sh — terminal UI helpers: banners, boxes, prompts with validation.

# ui_banner — colorful program header (name + version).
ui_banner() {
    local ver; ver="$(cat "$TM_HOME/VERSION" 2>/dev/null | tr -d '[:space:]')"
    printf '%b' "${C_CYAN}${C_BOLD}"
    cat <<'EOF'
  ╔════════════════════════════════════════════════════════╗
  ║          m o e i n i m y   tunnel manager              ║
  ║   GRE · Paqet · Backhaul · Rathole · GOST · FRP        ║
  ╚════════════════════════════════════════════════════════╝
EOF
    printf '%b' "$C_RESET"
    printf '  %sv%s · 6 protocols · Iran ↔ foreign%s\n' "$C_DIM" "${ver:-?}" "$C_RESET"
}

# ui_title TEXT — section header line.
ui_title() { printf '\n%s%s── %s ──%s\n' "$C_BOLD" "$C_MAGENTA" "$1" "$C_RESET"; }

# ui_kv KEY VALUE — aligned key/value line.
ui_kv() { printf '  %s%-18s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }

# ui_pause — wait for Enter (skipped in non-interactive mode).
ui_pause() {
    [[ -n "${TM_ASSUME_YES:-}" ]] && return 0
    printf '\n%sPress Enter to continue…%s' "$C_DIM" "$C_RESET"
    read -r _ || true
}

# ask VAR PROMPT [DEFAULT] — read a value into the named variable.
# Usage: ask myvar "Enter port" 4000
ask() {
    local __var="$1" prompt="$2" def="${3:-}" input hint=""
    [[ -n "$def" ]] && hint=" ${C_DIM}[$def]${C_RESET}"
    read -r -p "$(printf '%s%s%s%s: ' "$C_CYAN" "$prompt" "$C_RESET" "$hint")" input || true
    input="${input:-$def}"
    printf -v "$__var" '%s' "$input"
}

# ask_valid VAR PROMPT VALIDATOR [DEFAULT] — re-prompt until VALIDATOR succeeds.
# VALIDATOR is the name of a function taking the value as $1.
ask_valid() {
    local __var="$1" prompt="$2" validator="$3" def="${4:-}" val
    while true; do
        ask val "$prompt" "$def"
        if "$validator" "$val"; then printf -v "$__var" '%s' "$val"; return 0; fi
        log_warn "Invalid value: '$val'. Please try again."
    done
}

# ask_menu VAR PROMPT OPTION... — numbered single choice; sets VAR to chosen text.
ask_menu() {
    local __var="$1" prompt="$2"; shift 2
    local -a opts=("$@")
    local i choice
    printf '\n%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET"
    for i in "${!opts[@]}"; do
        printf '  %s%2d)%s %s\n' "$C_CYAN" "$(( i + 1 ))" "$C_RESET" "${opts[$i]}"
    done
    while true; do
        read -r -p "$(printf 'Select [1-%d]: ' "${#opts[@]}")" choice || true
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#opts[@]} )); then
            printf -v "$__var" '%s' "${opts[$(( choice - 1 ))]}"
            return 0
        fi
        log_warn "Enter a number between 1 and ${#opts[@]}."
    done
}

# status_dot STATE — colored bullet for up/down/unknown.
status_dot() {
    case "$1" in
        up|active|running) printf '%s●%s' "$C_GREEN"  "$C_RESET" ;;
        down|failed|dead)  printf '%s●%s' "$C_RED"    "$C_RESET" ;;
        *)                 printf '%s●%s' "$C_YELLOW" "$C_RESET" ;;
    esac
}
