#!/usr/bin/env bash
# update.sh — convenience wrapper: update the installed copy from GitHub.
set -euo pipefail
if [[ "$(id -u)" -ne 0 ]]; then echo "Run as root (sudo)." >&2; exit 1; fi
if command -v tunnelctl >/dev/null 2>&1; then
    exec tunnelctl update
fi
# Fallback if the CLI symlink is missing: re-run install in update mode.
_src="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$_src/install.sh" --update
