#!/usr/bin/env bash
# modules/selfupdate.sh — update the code from GitHub, preserving all config.
# Strategy: if TM_HOME is a git checkout, `git pull`; otherwise download the
# branch tarball. Then re-run the (idempotent) install.sh, which never touches
# existing configuration.

: "${TM_BRANCH:=main}"

selfupdate_run() {
    require_root
    ui_title "Update"
    local current latest remote
    current="$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)"
    log_info "Installed version: $current  (repo: $TM_REPO)"
    # Say WHERE the version was read from and what the branch is offering. When
    # "update" appeared to do nothing, the log gave no way to tell whether the
    # branch simply had nothing newer, whether TM_REPO pointed somewhere stale,
    # or whether TM_HOME was not the directory install.sh writes to.
    log_info "Reading version from: $TM_HOME/VERSION"
    if remote="$(selfupdate_check)"; then
        log_info "Branch ${TM_BRANCH} is offering: $remote"
    else
        log_info "Branch ${TM_BRANCH} reports the same version — refreshing the code anyway."
    fi

    if [[ -d "$TM_HOME/.git" ]] && have git; then
        log_info "Updating via git…"
        git -C "$TM_HOME" fetch --quiet origin "$TM_BRANCH" || die "git fetch failed"
        git -C "$TM_HOME" reset --hard "origin/$TM_BRANCH" || die "git reset failed"
        bash "$TM_HOME/install.sh" --update || die "reinstall failed"
    else
        selfupdate_tarball
    fi

    latest="$(cat "$TM_HOME/VERSION" 2>/dev/null || echo unknown)"
    # install.sh always writes to /opt/tunnel-manager. If tunnelctl is being run
    # from somewhere else (a source checkout, a stale symlink), the files DID
    # update but this VERSION never moves — which looks exactly like a broken
    # update button. Name both paths rather than leave that invisible.
    if [[ "$TM_HOME" != "/opt/tunnel-manager" && -f /opt/tunnel-manager/VERSION ]]; then
        log_warn "This tunnelctl runs from $TM_HOME, but the installer writes to /opt/tunnel-manager"
        log_warn "  (now $(cat /opt/tunnel-manager/VERSION 2>/dev/null)). Re-link with:"
        log_warn "  ln -sf /opt/tunnel-manager/tunnelctl /usr/local/bin/tunnelctl"
    fi
    # The version only moves when the backend's VERSION file does, but `update`
    # always refreshes the code from the branch tip. Reporting a bare
    # "3.0.0 -> 3.0.0" reads as "nothing happened" even though new code just
    # landed, so say which of the two actually occurred.
    if [[ "$current" == "$latest" ]]; then
        log_ok "Code refreshed from ${TM_REPO}@${TM_BRANCH} (version unchanged: $latest)"
    else
        log_ok "Updated: $current -> $latest"
    fi

    # New code is not new behaviour on its own. A driver's config file is written
    # when a tunnel is created or edited and never again, so a changed default sits
    # in the updated scripts while every existing tunnel keeps the file it was born
    # with. That is how the smux window fix in 3.9.5 reached no tunnel at all.
    log_info "Rewriting tunnel configs so the updated defaults take effect…"
    tunnel_regen_all

    # And the kernel side, for exactly the same reason. 3.9.6 taught this about the
    # drivers' config files; the sysctl file is the other half and was missed. An
    # update that changed tcp_mtu_probing would have shipped the new value into
    # optimize.sh and left every box running the old one until somebody happened to
    # run `optimize apply` by hand — which is indistinguishable from the fix not
    # working, and is how a correctly diagnosed fault survives its own correction.
    #
    # Only when optimization was already applied here: this re-applies a decision the
    # operator made, it does not make it for them.
    if [[ -f "$TM_OPT_MARKER" ]]; then
        log_info "Re-applying network optimization so updated kernel settings take effect…"
        optimize_apply
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
    if ! tm_fetch "$url" "$tmp/src.tar.gz"; then
        rm -rf "$tmp"
        die "Download failed. If this node is on a throttled link, set a mirror prefix as TM_DOWNLOAD_MIRRORS in $TM_SETTINGS_FILE; otherwise check TM_REPO there."
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
