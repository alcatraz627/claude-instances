#!/bin/bash
# Install (or reinstall) the launchd agent that auto-starts V2 on login.
# Idempotent — safe to re-run after a fresh git clone or after editing
# the plist template.
#
# Usage:
#   ./setup/install.sh          # install + load
#   ./setup/install.sh --uninstall

set -euo pipefail
cd "$(dirname "$0")/.."

PLIST_NAME="dev.claude-instances-v2.menubar.plist"
PLIST_LABEL="dev.claude-instances-v2.menubar"
SRC="setup/${PLIST_NAME}"
DST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
APP="${PWD}/claude-instances-v2.app"

if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[install] unloading + removing plist"
    launchctl bootout "gui/$(id -u)" "${DST}" 2>/dev/null || true
    rm -f "${DST}"
    echo "[install] V2 will not auto-launch on next login."
    exit 0
fi

if [[ ! -d "${APP}" ]]; then
    echo "[install] ${APP} not found — run ./build.sh release first."
    exit 1
fi

# Rewrite the binary path in the plist for whatever the worktree is. The
# committed plist uses an absolute path that may not match the user's
# install location; this command keeps both correct.
sed "s|/Users/alcatraz627/.claude/widgets/claude-instances-v2|${PWD}|g" "${SRC}" > "${DST}"
echo "[install] wrote ${DST}"

# Unload first if already loaded; then load.
launchctl bootout "gui/$(id -u)" "${DST}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "${DST}"
echo "[install] loaded launchd job ${PLIST_LABEL}"

echo ""
echo "V2 will now auto-launch on every login."
echo "To stop: ./setup/install.sh --uninstall"
echo "Current state:"
launchctl list | grep claude-instances || true
