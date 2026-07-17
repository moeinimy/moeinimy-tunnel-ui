#!/usr/bin/env bash
# modules/selfupdate.sh — update the code from GitHub, preserving all config.
# Strategy: if TM_HOME is a git checkout, `git pull`; otherwise download the
# branch tarball. Then re-run the (idempotent) install.sh, which never touches
# existing configuration.

: "${TM_BRANCH:=main}"

selfupdate_run() {
    require_root
    ui_title "Update"
    local current latest
    current="$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)"
    log_info "Installed version: $current  (repo: $TM_REPO)"

    if [[ -d "$TM_HOME/.git" ]] && have git; then
        log_info "Updating via git…"
        git -C "$TM_HOME" fetch --quiet origin "$TM_BRANCH" || die "git fetch failed"
        git -C "$TM_HOME" reset --hard "origin/$TM_BRANCH" || die "git reset failed"
        bash "$TM_HOME/install.sh" --update || die "reinstall failed"
    else
        selfupdate_tarball
    fi

    latest="$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)"
    # The version only moves when the backend's VERSION file does, but `update`
    # always refreshes the code from the branch tip. Reporting a bare
    # "3.0.0 -> 3.0.0" reads as "nothing happened" even though new code just
    # landed, so say which of the two actually occurred.
    if [[ "$current" == "$latest" ]]; then
        log_ok "Code refreshed from ${TM_REPO}@${TM_BRANCH} (version unchanged: $latest)"
    else
        log_ok "Updated: $current -> $latest"
    fi
    # The node agent is long-running: without a restart it keeps executing the
    # code that was on disk when it started. install.sh try-restarts it; say so,
    # since that is the whole point of updating a node.
    if systemctl is-active --quiet tm-node-agent.service 2>/dev/null; then
        log_ok "Node control agent restarted on the new code."
    fi
    tg_notify "⬆️ Tunnel Manager updated on $(hostname): $current → $latest"
}

selfupdate_tarball() {
    local tmp url dir src
    tmp="$(mktemp -d)"
    url="https://github.com/${TM_REPO}/archive/refs/heads/${TM_BRANCH}.tar.gz"
    log_info "Downloading $url"
    if ! curl -fsSL --max-time 120 -o "$tmp/src.tar.gz" "$url"; then
        rm -rf "$tmp"; die "Download failed. Check TM_REPO in $TM_SETTINGS_FILE."
    fi
    tar -xzf "$tmp/src.tar.gz" -C "$tmp" || { rm -rf "$tmp"; die "extract failed"; }
    dir="$(find "$tmp" -maxdepth 1 -type d -name '*-*' | head -1)"
    [[ -d "$dir" ]] || { rm -rf "$tmp"; die "unexpected archive layout"; }
    # The backend ships inside the panel monorepo under tunnel/; fall back to the
    # archive root for a standalone tunnel-manager repo.
    if [[ -f "$dir/tunnel/install.sh" ]]; then src="$dir/tunnel"; else src="$dir"; fi
    [[ -f "$src/tunnelctl" ]] || { rm -rf "$tmp"; die "archive has no tunnelctl (wrong TM_REPO?)"; }
    bash "$src/install.sh" --update || { rm -rf "$tmp"; die "reinstall failed"; }
    rm -rf "$tmp"
}

# selfupdate_check — compare local VERSION against remote (best-effort, for alerts).
selfupdate_check() {
    local remote
    # Monorepo layout first (tunnel/VERSION), then a standalone repo's root.
    remote="$(curl -fsSL --max-time 15 \
        "https://raw.githubusercontent.com/${TM_REPO}/${TM_BRANCH}/tunnel/VERSION" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$remote" ]] || remote="$(curl -fsSL --max-time 15 \
        "https://raw.githubusercontent.com/${TM_REPO}/${TM_BRANCH}/VERSION" 2>/dev/null | tr -d '[:space:]')"
    local local_v; local_v="$(cat "$TM_HOME/VERSION" 2>/dev/null | tr -d '[:space:]')"
    [[ -n "$remote" && -n "$local_v" && "$remote" != "$local_v" ]] || return 1
    printf '%s' "$remote"
}
