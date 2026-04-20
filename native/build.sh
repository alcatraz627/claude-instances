#!/usr/bin/env bash
# build.sh — Compile and manage the Claude Instances menu bar widget.
#
# Usage:
#   bash build.sh              # compile + launch (replaces running instance)
#   bash build.sh --install    # compile + register LaunchAgent (auto-start on login)
#   bash build.sh --uninstall  # remove LaunchAgent + kill widget
#   bash build.sh --logs       # tail the widget debug log
#   bash build.sh --status     # show running instances + plist status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/claude-instances-bar.swift"
OUTPUT="$SCRIPT_DIR/claude-instances-bar"
LABEL="dev.claude-instances.menubar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DEBUG_LOG="/tmp/claude-instances-bar.log"

MODE="${1:-}"

# ── Quick helpers ───────────────────────────────────────────────────────────

case "$MODE" in
  --logs)
    echo "-> tailing $DEBUG_LOG  (Ctrl+C to stop)"
    tail -f "$DEBUG_LOG"
    exit 0
    ;;
  --status)
    echo "Running instances:"
    pgrep -la "claude-instances-bar" 2>/dev/null || echo "  (none)"
    echo ""
    echo "LaunchAgent ($LABEL):"
    if launchctl list "$LABEL" 2>/dev/null | grep -q PID; then
      launchctl list "$LABEL" 2>/dev/null
    else
      echo "  (not registered)"
    fi
    echo ""
    echo "Build info:"
    BUILD_INFO_FILE="$SCRIPT_DIR/.build-info"
    if [[ -f "$BUILD_INFO_FILE" ]]; then
      BUILT_COMMIT=$(grep "^commit=" "$BUILD_INFO_FILE" | cut -d= -f2)
      BUILT_HASH=$(grep "^src_hash=" "$BUILD_INFO_FILE" | cut -d= -f2)
      BUILT_AT=$(grep "^built_at=" "$BUILD_INFO_FILE" | cut -d= -f2)
      CURRENT_HASH=$(md5 "$SOURCE" | awk '{print substr($NF,1,8)}')
      echo "  Built:   $BUILT_AT  (commit: $BUILT_COMMIT)"
      if [[ "$CURRENT_HASH" == "$BUILT_HASH" ]]; then
        echo "  Source:  binary matches source (hash: $CURRENT_HASH)"
      else
        echo "  Source:  SOURCE HAS CHANGED — binary is stale!"
        echo "           source now:  $CURRENT_HASH"
        echo "           binary from: $BUILT_HASH"
        echo "           -> run: bash build.sh"
      fi
    else
      echo "  (no .build-info — binary predates hash tracking)"
    fi
    exit 0
    ;;
  --uninstall)
    echo "Uninstalling LaunchAgent..."
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "  Unregistered" || echo "  (was not registered)"
    [[ -f "$PLIST" ]] && { rm -f "$PLIST"; echo "  Removed $PLIST"; }
    pkill -x "claude-instances-bar" 2>/dev/null && echo "  Killed running instance" || echo "  (no instance running)"
    exit 0
    ;;
esac

# ── Kill any existing instances ─────────────────────────────────────────────

echo "Stopping any running claude-instances-bar instances..."
LAUNCHD_WAS_REGISTERED=false
if launchctl list "$LABEL" &>/dev/null; then
    LAUNCHD_WAS_REGISTERED=true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    echo "  Suspended LaunchAgent (will re-register after compile)"
fi
KILLED=0
while pgrep -x "claude-instances-bar" &>/dev/null; do
    pkill -x "claude-instances-bar" 2>/dev/null || true
    sleep 0.3
    KILLED=$((KILLED+1))
    [[ $KILLED -ge 5 ]] && { echo "  Could not stop all instances; continuing anyway"; break; }
done
[[ $KILLED -gt 0 ]] && echo "  Stopped (killed $KILLED time(s))" || echo "  (none were running)"

# ── Compile ─────────────────────────────────────────────────────────────────

echo "Generating build-info..."
COMMIT=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
SRC_HASH=$(md5 "$SOURCE" | awk '{print substr($NF,1,8)}')
BUILD_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Compiling..."
rm -f "$OUTPUT"
/usr/bin/swiftc -O "$SOURCE" -o "$OUTPUT" 2>&1
echo "  Built: $OUTPUT"

# Record build metadata
printf "commit=%s\nsrc_hash=%s\nbuilt_at=%s\n" "$COMMIT" "$SRC_HASH" "$BUILD_TS" > "$SCRIPT_DIR/.build-info"

# Ad-hoc sign
echo "Signing (ad-hoc)..."
/usr/bin/codesign --sign - --force "$OUTPUT" 2>&1 && echo "  Signed" || echo "  Signing failed"

# ── Install or launch ───────────────────────────────────────────────────────

if [[ "$MODE" == "--install" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

    mkdir -p "$(dirname "$PLIST")"
    cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$OUTPUT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>StandardOutPath</key>
    <string>$DEBUG_LOG</string>
    <key>StandardErrorPath</key>
    <string>$DEBUG_LOG</string>
</dict>
</plist>
EOF

    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "  Registered LaunchAgent: $LABEL"
    echo "  Widget will start now and auto-start on every login"
    echo ""
    echo "  Debug logs:  bash build.sh --logs"
    echo "  Status:      bash build.sh --status"
    echo "  Uninstall:   bash build.sh --uninstall"

else
    echo "Launching..."
    if [[ "$LAUNCHD_WAS_REGISTERED" == "true" ]]; then
        launchctl bootstrap "gui/$(id -u)" "$PLIST"
        echo "  Re-registered LaunchAgent: $LABEL"
    else
        nohup "$OUTPUT" >> "$DEBUG_LOG" 2>&1 &
        disown
    fi
    sleep 0.8
    if pgrep -x "claude-instances-bar" &>/dev/null; then
        PID=$(pgrep -x "claude-instances-bar" | head -1)
        echo "  Running (PID $PID)"
    else
        echo "  Process did not appear — check $DEBUG_LOG"
    fi
    echo ""
    echo "  Debug logs:  bash build.sh --logs"
    echo "  Auto-start:  bash build.sh --install"
fi
