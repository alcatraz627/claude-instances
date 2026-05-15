#!/bin/bash
# Build the V2 .app bundle from the SPM workspace.
#
# SPM emits a bare executable under .build/<config>/. macOS menu-bar apps need a
# .app bundle so LSUIElement is honored (otherwise the app shows in the Dock).
# This script wraps the executable into Contents/MacOS + Contents/Info.plist.
#
# Usage:
#   ./build.sh                  release build, assembles .app
#   ./build.sh debug            debug build
#   ./build.sh --run            build + open the .app

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
RUN_AFTER=0
for arg in "$@"; do
    case "$arg" in
        debug)    CONFIG="debug" ;;
        release)  CONFIG="release" ;;
        --run)    RUN_AFTER=1 ;;
        *) echo "Unknown arg: $arg"; exit 2 ;;
    esac
done

APP_NAME="claude-instances-v2"
APP_DIR="${APP_NAME}.app"
EXEC_NAME="${APP_NAME}"

echo "[build] Compiling HostShell (${CONFIG})"
swift build -c "${CONFIG}" --product HostShell

BIN_PATH=".build/${CONFIG}/HostShell"
test -x "${BIN_PATH}" || { echo "[build] FAIL: expected binary missing: ${BIN_PATH}"; exit 1; }

echo "[build] Assembling ${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp -f "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${EXEC_NAME}"
cp -f Resources/Info.plist "${APP_DIR}/Contents/Info.plist"

# Ad-hoc sign so macOS does not refuse to launch unsigned + quarantined.
codesign --force --sign - "${APP_DIR}" >/dev/null 2>&1 || true

echo "[build] OK -> ${APP_DIR}"
ls -la "${APP_DIR}/Contents/MacOS/"

if [[ "${RUN_AFTER}" -eq 1 ]]; then
    # macOS `open` brings an already-running app to foreground rather than
    # picking up a new binary. Kill any stale instance first so the user
    # actually sees the build they just made.
    pkill -f "${APP_DIR}/Contents/MacOS/${EXEC_NAME}" 2>/dev/null || true
    sleep 0.3
    echo "[build] Launching ${APP_DIR}"
    open "${APP_DIR}"
fi
