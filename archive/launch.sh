#!/usr/bin/env bash
# launch.sh — Render and open the Claude instances dashboard.
#
# Usage:
#   bash launch.sh          # render + open in browser
#   bash launch.sh --render # render only (for cron/automation)

set -uo pipefail

WIDGET_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_SCRIPT="${WIDGET_DIR}/render.sh"
OUTPUT_FILE="${WIDGET_DIR}/dashboard.html"

bash "$RENDER_SCRIPT" || { echo "launch: render failed" >&2; exit 1; }

if [[ "${1:-}" != "--render" ]]; then
    open "$OUTPUT_FILE"
fi
