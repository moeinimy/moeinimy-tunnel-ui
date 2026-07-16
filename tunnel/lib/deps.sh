#!/usr/bin/env bash
# lib/deps.sh — dependency detection and installation (Debian/Ubuntu focused,
# with best-effort support for RHEL-family via dnf/yum).

# pkg_manager — echo apt|dnf|yum|unknown
pkg_manager() {
    if   have apt-get; then echo apt
    elif have dnf;     then echo dnf
    elif have yum;     then echo yum
    else echo unknown; fi
}

# Map of required commands -> package name (apt names; close enough for dnf/yum).
# libpcap is only needed for Paqet; ethtool only for NIC tuning.
TM_REQUIRED_CMDS=(curl jq ip iptables tar gzip awk sed grep)
TM_OPTIONAL_CMDS=(ethtool ss ping ssh ssh-keygen unzip openssl)

# deps_missing — print required commands that are absent.
deps_missing() {
    local c
    for c in "${TM_REQUIRED_CMDS[@]}"; do
        have "$c" || printf '%s\n' "$c"
    done
}

# _cmd_to_pkg CMD -> package name
_cmd_to_pkg() {
    case "$1" in
        ip)         echo iproute2 ;;
        ss)         echo iproute2 ;;
        ping)       echo iputils-ping ;;
        iptables)   echo iptables ;;
        ssh)        echo openssh-client ;;
        ssh-keygen) echo openssh-client ;;
        *)          echo "$1" ;;
    esac
}

# deps_install — install any missing required/optional packages.
deps_install() {
    require_root
    local pm; pm="$(pkg_manager)"
    local -a pkgs=() c
    for c in "${TM_REQUIRED_CMDS[@]}" "${TM_OPTIONAL_CMDS[@]}"; do
        have "$c" || pkgs+=("$(_cmd_to_pkg "$c")")
    done
    # libpcap runtime is required by the Paqet binary.
    pkgs+=(libpcap0.8)
    # De-duplicate.
    local -A seen=(); local -a uniq=()
    for c in "${pkgs[@]}"; do [[ -n "${seen[$c]:-}" ]] || { uniq+=("$c"); seen[$c]=1; }; done

    if [[ ${#uniq[@]} -eq 0 ]]; then
        log_ok "All dependencies already present."
        return 0
    fi

    log_info "Installing packages: ${uniq[*]}"
    case "$pm" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y >/dev/null 2>&1 || log_warn "apt-get update failed (continuing)"
            apt-get install -y "${uniq[@]}" || die "Package installation failed."
            ;;
        dnf) dnf install -y "${uniq[@]}" || die "Package installation failed." ;;
        yum) yum install -y "${uniq[@]}" || die "Package installation failed." ;;
        *)   log_warn "Unknown package manager; please install manually: ${uniq[*]}" ;;
    esac
    log_ok "Dependencies installed."
}

# deps_check — verify required commands, offer to install if missing.
deps_check() {
    local missing; missing="$(deps_missing)"
    if [[ -z "$missing" ]]; then return 0; fi
    log_warn "Missing required commands:"$'\n'"$missing"
    if confirm "Install missing dependencies now?" yes; then
        deps_install
    else
        die "Cannot continue without required dependencies."
    fi
}
