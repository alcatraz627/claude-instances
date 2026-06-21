#!/usr/bin/env bash
# tests/run-tests.sh — basic smoke tests for claude-instances.
#
# Covers the three things most likely to silently regress:
#   - swift bar compiles
#   - scan.sh emits valid JSON with the expected shape (full + --quick)
#   - detail.sh --regen against a fixture JSONL produces a non-empty HTML
#     with the expected runtime markers
#
# Not a comprehensive suite; intentionally bash + python3 stdlib only so it
# runs anywhere the bar itself runs. No external test framework.
#
# Exit codes: 0 = all green, 1 = at least one failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0

# ── tiny test harness ─────────────────────────────────────────────────────────

C_GREEN=$(tput setaf 2 2>/dev/null || echo '')
C_RED=$(tput setaf 1 2>/dev/null || echo '')
C_DIM=$(tput dim 2>/dev/null || echo '')
C_RESET=$(tput sgr0 2>/dev/null || echo '')

t_log() { printf '%b\n' "$@"; }
t_pass() { PASS=$((PASS+1)); t_log "  ${C_GREEN}✓${C_RESET} $*"; }
t_fail() { FAIL=$((FAIL+1)); t_log "  ${C_RED}✗${C_RESET} $*"; }
t_section() { t_log "\n${C_DIM}── $* ──${C_RESET}"; }

# Assert: name, command — stdout/exit captured. Pass if exit=0.
t_check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then t_pass "$name"
    else t_fail "$name (cmd failed: $*)"; fi
}

# Assert: name, expected, actual. Pass if equal.
t_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then t_pass "$name"
    else t_fail "$name — expected: $expected, got: $actual"; fi
}

# Assert: name, file, pattern. Pass if pattern found in file.
t_grep() {
    local name="$1" file="$2" pattern="$3"
    if rg -q -- "$pattern" "$file" 2>/dev/null; then t_pass "$name"
    else t_fail "$name — no match for /$pattern/ in $file"; fi
}

# ── T1 — bash syntax checks ──────────────────────────────────────────────────

t_section "syntax checks"
t_check "lib/scan.sh parses"        bash -n lib/scan.sh
t_check "lib/detail.sh parses"      bash -n lib/detail.sh
t_check "native/build.sh parses"    bash -n native/build.sh
t_check "tests/run-tests.sh parses" bash -n tests/run-tests.sh

# ── T2 — swift compile check ─────────────────────────────────────────────────

t_section "swift compile"
SWIFT_OUT=$(mktemp)
# The bar is split across logical files; compile them as one module (the build).
if /usr/bin/swiftc -O native/main.swift native/Models.swift native/Palette.swift \
        native/DesignKit.swift native/Actions.swift native/LiveRowView.swift \
        native/Bar.swift native/Dashboard.swift -o "$SWIFT_OUT" 2>&1; then
    t_pass "bar (split into logical files) compiles (-O)"
    rm -f "$SWIFT_OUT"
else
    t_fail "bar FAILED to compile"
    rm -f "$SWIFT_OUT"
fi

# ── Design primitives (P2 — the shared building blocks) ──────────────────────
t_section "design primitives"
t_grep "BarFont type scale"            native/ 'enum BarFont'
t_grep "seg() segment builder"         native/ 'func seg\('
t_grep "row() concatenator"            native/ 'func row\('
t_grep "columned() tab-stop alignment" native/ 'func columned\('
t_grep "middleTruncate path helper"    native/ 'func middleTruncate'
t_grep "tailTruncate id helper"        native/ 'func tailTruncate'
t_grep "clampLines prose helper"       native/ 'func clampLines'
t_grep "severity scale (closed set)"   native/ 'func severityToken'

# ── Live row P4 (ctx bar, truncation, submenu copies) ────────────────────────
t_section "live row (P4)"
t_grep "per-instance ctx bar helper"   native/ 'func appendBar'
t_grep "ctx bar wired in metrics row"  native/ 'appendBar\(to: metricsRow'
t_grep "cwd path middle-truncated"     native/ 'middleTruncate\(path'
t_grep "focus file middle-truncated"   native/ 'middleTruncate\(disp'
t_grep "copy directory path action"    native/ 'func copyDirPath'
t_grep "copy resume command action"    native/ 'func copyResumeCmd'

# ── Rate limits + usage P5 (zones, column alignment) ─────────────────────────
t_section "rate zones + alignment (P5/#22)"
t_grep "danger zone threshold"         native/ 'dangerThreshold'
t_grep "zoneColor drives bars + icon"  native/ 'func zoneColor'
t_grep "two-slider zone submenu"       native/ 'func zoneSlider'
t_grep "rate bars drawn as views"      native/ 'fill.layer\?.backgroundColor = color'
t_grep "usage rows column-aligned"     native/ 'columned\(\[labelCell'

# ── Events + History collapse P6 ─────────────────────────────────────────────
t_section "events + history collapse (P6)"
t_grep "events collapsed to one row"   native/ 'Recent Events \('
t_grep "history collapsed to one row"  native/ 'for sess in history.prefix\(14\)'
t_grep "event rows column-aligned"     native/ 'columned\(cells, stops'
t_grep "history rows column-aligned"   native/ 'columned\(cells, stops: \[196'

# ── T3 — scan.sh full produces valid JSON ────────────────────────────────────

t_section "scan.sh full"
SCAN_OUT=$(mktemp)
bash lib/scan.sh > "$SCAN_OUT" 2>/dev/null
if python3 -c "import json,sys; json.load(open('$SCAN_OUT'))" 2>/dev/null; then
    t_pass "scan.sh emits valid JSON"
else
    t_fail "scan.sh output is not valid JSON"
fi
# Required top-level keys.
for key in live history limits aggregates; do
    if python3 -c "
import json,sys
d = json.load(open('$SCAN_OUT'))
sys.exit(0 if '$key' in d else 1)" 2>/dev/null; then
        t_pass "scan.sh full has '$key'"
    else
        t_fail "scan.sh full missing '$key'"
    fi
done
# Per-instance fields exist when there's at least one live instance.
LIVE_COUNT=$(python3 -c "import json; print(len(json.load(open('$SCAN_OUT')).get('live', [])))" 2>/dev/null || echo 0)
if [[ "$LIVE_COUNT" -gt 0 ]]; then
    for field in pid model cwd git_branch git_modified last_prompt; do
        if python3 -c "
import json,sys
inst = json.load(open('$SCAN_OUT'))['live'][0]
sys.exit(0 if '$field' in inst else 1)" 2>/dev/null; then
            t_pass "scan.sh live[0] has '$field'"
        else
            t_fail "scan.sh live[0] missing '$field'"
        fi
    done
else
    t_log "  ${C_DIM}(skipping per-instance field checks — no live Claude sessions)${C_RESET}"
fi
rm -f "$SCAN_OUT"

# ── T4 — scan.sh --quick produces valid JSON ─────────────────────────────────

t_section "scan.sh --quick"
QUICK_OUT=$(mktemp)
bash lib/scan.sh --quick > "$QUICK_OUT" 2>/dev/null
if python3 -c "import json; json.load(open('$QUICK_OUT'))" 2>/dev/null; then
    t_pass "scan.sh --quick emits valid JSON"
else
    t_fail "scan.sh --quick output is not valid JSON"
fi
# 'live' must be present even on --quick; history etc may be empty.
if python3 -c "
import json,sys
d = json.load(open('$QUICK_OUT'))
sys.exit(0 if 'live' in d else 1)" 2>/dev/null; then
    t_pass "scan.sh --quick has 'live'"
else
    t_fail "scan.sh --quick missing 'live'"
fi
rm -f "$QUICK_OUT"

# ── T5/T6 — detail.sh --regen produces HTML with markers ─────────────────────

t_section "detail.sh"
FIXTURE_JSONL="$REPO_ROOT/tests/fixtures/sample-session.jsonl"
FIXTURE_SID="00000000-0000-0000-0000-000000000001"
FIXTURE_PID="999999"
DETAIL_OUT="/tmp/claude-widget-${FIXTURE_PID}.html"

# Stage the fixture under the projects dir layout so detail.sh can find it
# via session-id lookup. Keeps the test isolated from any real session.
PROJ_DIR="$HOME/.claude/projects/-tmp-fixture"
mkdir -p "$PROJ_DIR"
cp "$FIXTURE_JSONL" "$PROJ_DIR/${FIXTURE_SID}.jsonl"

# --regen mode skips browser open and daemon spawn.
bash lib/detail.sh --regen "$FIXTURE_PID" "$FIXTURE_SID" >/dev/null 2>&1

if [[ -f "$DETAIL_OUT" ]] && [[ -s "$DETAIL_OUT" ]]; then
    t_pass "detail.sh wrote $DETAIL_OUT"
else
    t_fail "detail.sh did not produce output"
fi

# detail.sh now serves the data-first SPA (transcript-app.html) by default; the
# legacy baked-HTML generator stays behind CLAUDE_WIDGET_LEGACY=1 as a fallback.
# (The menu bar itself no longer uses this path — it opens the hub — so these
# guard the standalone detail.sh contract while the legacy generator lives on.)
[[ -f "$DETAIL_OUT" ]] && {
    t_grep "doctype present"           "$DETAIL_OUT" '<!DOCTYPE html>'
    t_grep "marked CDN link"           "$DETAIL_OUT" 'marked.*\.min\.js'
    t_grep "highlight.js CDN link"     "$DETAIL_OUT" 'highlight\.min\.js'
    t_grep "serves the data-first SPA" "$DETAIL_OUT" 'Search whole transcript'
    t_grep "SPA derives the hub /data base" "$DETAIL_OUT" 'const HUB ='
    t_grep "SPA renders Edit as a diff" "$DETAIL_OUT" 'function diffBlock'
}

# Legacy fallback still renders the baked HTML when explicitly opted in.
CLAUDE_WIDGET_LEGACY=1 bash lib/detail.sh --regen "$FIXTURE_PID" "$FIXTURE_SID" >/dev/null 2>&1
[[ -f "$DETAIL_OUT" ]] && {
    t_grep "legacy: baked live poller"  "$DETAIL_OUT" 'function livePoll'
    t_grep "legacy: /regen referenced"  "$DETAIL_OUT" "fetch\\('/regen'"
    t_grep "legacy: msg-idx badges"     "$DETAIL_OUT" 'msg-idx'
}

# ── T7 — detail-server.py syntax ─────────────────────────────────────────────

t_section "detail-server.py"
t_check "lib/detail-server.py compiles"  python3 -m py_compile lib/detail-server.py
t_grep "/regen endpoint defined"  lib/detail-server.py '/regen'
t_grep "exits on Claude PID death" lib/detail-server.py 'claude_alive'
t_grep "idle timeout (no leak when browser closes)" lib/detail-server.py 'IDLE_SECS'
t_grep "signal handlers (clean shutdown)" lib/detail-server.py 'SIGTERM'
t_grep "atomic write in regen"    lib/detail.sh 'os.replace\(tmp_path, output_path\)'
# LiveRowView (live menu rows): structural markers
t_grep "LiveRowView class defined" native/ 'class LiveRowView'
t_grep "intrinsicContentSize override (sizing fix)" native/ 'override var intrinsicContentSize'
t_grep "menuWillOpen tracks open state" native/ 'func menuWillOpen'
t_grep "refreshLiveRows wired to data refresh" native/ 'refreshLiveRows()'

# Session hub — the device-spanning transcript server (phone access over Tailscale).
t_section "session hub"
t_check "lib/hub-server.py compiles"   python3 -m py_compile lib/hub-server.py
t_check "lib/hub.sh parses"            bash -n lib/hub.sh
t_grep "binds tailnet IP (CGNAT 100.64/10)" lib/hub-server.py 'def tailnet_ip'
t_grep "session route /s/<id>"         lib/hub-server.py 'SID_RE'
t_grep "/data reuses transcript.py"    lib/hub-server.py 'parse_transcript'
t_grep "SPA derives hub API base"      lib/transcript-app.html 'const HUB ='
t_grep "index polls /api/sessions"     lib/hub-index.html '/api/sessions'
t_grep "Edit renders as a diff"        lib/transcript-app.html 'function diffBlock'
t_grep "copy works over insecure http" lib/transcript-app.html 'execCommand'
t_grep "bar opens hub transcript"      native/ 'func openHubTranscript'
t_grep "bar 'Sessions (phone)' action" native/ 'func openHubIndex'

# Functional: spin the hub in-process on an ephemeral port, hit /healthz, tear
# down — proves the routing wires up without leaving a socket behind.
HUB_FN=$(python3 - <<'PY' 2>/dev/null
import importlib.util, threading, time, urllib.request, http.server, os
lib = os.path.join(os.getcwd(), 'lib')
spec = importlib.util.spec_from_file_location('hub_server', os.path.join(lib, 'hub-server.py'))
hub = importlib.util.module_from_spec(spec); spec.loader.exec_module(hub)
srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), hub.HubHandler)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(0.2)
port = srv.server_address[1]
with urllib.request.urlopen(f'http://127.0.0.1:{port}/healthz', timeout=10) as r:
    ok = r.status == 200 and b'"ok"' in r.read()
srv.shutdown()
print('OK' if ok else 'FAIL')
PY
)
if [[ "$HUB_FN" == "OK" ]]; then t_pass "hub serves /healthz (in-process)"; else t_fail "hub /healthz failed"; fi

# Palette + Settings infrastructure — single source of truth for menu colors
# plus the Settings tab UI built on it.
t_section "palette + settings"
t_grep "PaletteToken enum defined"             native/ 'enum PaletteToken'
t_grep "PaletteStore singleton"                native/ 'final class PaletteStore'
t_grep "PaletteStore.set persists hex"         native/ 'func set\(_ token: PaletteToken, hex'
t_grep "PaletteStore.reset clears override"    native/ 'func reset\(_ token: PaletteToken\)'
t_grep "NSColor.fromHex parser"                native/ 'static func fromHex'
t_grep "NSColor.hexString writer"              native/ 'var hexString'
t_grep "all 12 tokens registered"              native/ 'metricMemory.*memory'
t_grep "modelDisplay reads PaletteStore"       native/ 'PaletteStore.shared.color\(for: .modelOpus\)'
t_grep "LiveRowViewRepresentable for SwiftUI"  native/ 'struct LiveRowViewRepresentable: NSViewRepresentable'
t_grep "SettingsTabView wired in dashboard"    native/ 'case .settings:'
t_grep "tailwindPalette table"                 native/ 'tailwindPalette: \[\(hue: String'
t_grep "PaletteEditorRow row component"        native/ 'struct PaletteEditorRow'
t_grep "TailwindPicker popover"                native/ 'struct TailwindPicker'
t_grep "PaletteStore.didChange notification"   native/ 'PaletteStore.didChangeNotification'
# Hover + reverse-highlight wiring (Settings ↔ preview bidirectional)
t_grep "tokenForLabel mapping in LiveRowView"  native/ 'tokenForLabel: \[NSTextField: PaletteToken\]'
t_grep "onHoverToken callback exposed"         native/ 'onHoverToken: \(\(PaletteToken'
t_grep "setHighlightedToken reverse-highlight" native/ 'func setHighlightedToken'
t_grep "tracking area for hover detection"     native/ 'NSTrackingArea'
# Appearance + menu-behavior sections
t_grep "AppearancePref enum (system/light/dark)" native/ 'enum AppearancePref'
t_grep "AppearanceSection view defined"        native/ 'struct AppearanceSection'
t_grep "MenuBehaviorSection view defined"      native/ 'struct MenuBehaviorSection'
t_grep "appearance applied at launch"          native/ 'applyAppearancePref\(loadAppearancePref'
# Menu Behavior settings are WIRED, not placeholders
t_grep "density read in LiveRowView.update"    native/ 'stack.spacing = densitySpacing\(\)'
t_grep "densitySpacing accessor"               native/ 'func densitySpacing'
t_grep "defaultTab honored in DashboardRootView" native/ 'UserDefaults.standard.string\(forKey: "defaultTab"\)'
t_grep "userTimeFormatter helper"              native/ 'func userTimeFormatter'
t_grep "AllSessions dateFmt reads user pref"   native/ 'userTimeFormatter\(includesDate: true\)'
t_grep "menuBehaviorDidChange notification"    native/ 'menuBehaviorDidChange'
t_grep "BarDelegate observes behavior change"  native/ 'forName: .menuBehaviorDidChange'
# Per-chip token tagging — covers EVERY palette token in the preview
t_grep "appendChip helper defined"             native/ 'private func appendChip'
t_grep "header chips: model badge tagged"      native/ 'token: modelToken'
t_grep "header chips: subagent tagged"         native/ 'token: .accentSubagent'
t_grep "header chips: branch tagged"           native/ 'token: .accentBranch'
t_grep "header chips: modified tagged"         native/ 'token: modToken'
t_grep "metrics chips: ctx tagged by severity" native/ 'token: ctxToken'
t_grep "metrics chips: cost tagged"            native/ 'token: .metricCost'
t_grep "metrics chips: tokens tagged"          native/ 'token: .metricTokens'
t_grep "metrics chips: memory tagged"          native/ 'token: .metricMemory'
# Layout-shift fix: drawsBackground set ONCE in addLine, never toggled
t_grep "drawsBackground = true in addLine"     native/ 'label.drawsBackground = true'
t_grep "applyHighlightedToken animates"        native/ 'NSAnimationContext.runAnimationGroup'
# Three new palette tokens for the previously-untagged metric chips
t_grep "metric.turns token"                    native/ 'case metricTurns'
t_grep "metric.tools token"                    native/ 'case metricTools'
t_grep "metric.speed token"                    native/ 'case metricSpeed'
t_grep "turns chip tagged"                     native/ 'token: .metricTurns'
t_grep "tools chip tagged"                     native/ 'token: .metricTools'
t_grep "speed chip tagged"                     native/ 'token: .metricSpeed'
# B1 — submenu keystrokes wired from a configurable store
t_grep "SubmenuAction enum"                    native/ 'enum SubmenuAction'
t_grep "keybindFor accessor"                   native/ 'func keybindFor'
t_grep "finder item reads keybind"             native/ 'keybindFor\(.openInFinder\)'
t_grep "transcript item reads keybind"         native/ 'keybindFor\(.viewTranscript\)'
t_grep "KeybindsSection UI present"            native/ 'struct KeybindsSection'
t_grep "KeybindRow editor"                     native/ 'struct KeybindRow'
# A3 — SF Symbol state icon
t_grep "stateSymbolName helper"                native/ 'func stateSymbolName'
t_grep "symbolAttributedString helper"         native/ 'func symbolAttributedString'
# C1 — permission mode
t_grep "permissionMode field on LiveInstance"  native/ 'permissionMode = "permission_mode"'
t_grep "permission_mode emitted in scan.sh"    lib/scan.sh "'permission_mode'"
t_grep "permissionPlan token defined"          native/ 'case permissionPlan'
t_grep "permission badge rendered"             native/ 'permLetter = "P"'
# C2 — last tool when idle
t_grep "LastTool struct"                       native/ 'struct LastTool'
t_grep "last_tool emitted in scan.sh"          lib/scan.sh "'last_tool'"
t_grep "parse_jsonl_state in scan.sh"          lib/scan.sh 'def parse_jsonl_state'
t_grep "formatAgo helper"                      native/ 'func formatAgo'
t_grep "last-tool line rendered when fresh"    native/ 'suppressBecauseStale'
# Transcript server lifecycle controls in the dashboard
t_grep "TranscriptServer struct"               native/ 'struct TranscriptServer'
t_grep "refreshTranscriptServers method"       native/ 'func refreshTranscriptServers'
t_grep "killAllTranscriptServers"              native/ 'func killAllTranscriptServers'
t_grep "sidebar shows transcript count"        native/ 'transcriptServers.isEmpty'
# detail.sh stale-server-pid cleanup + bind verification
t_grep "detail.sh cleans stale .server file"  lib/detail.sh 'Old server is dead'
t_grep "detail.sh waits for bind + errors"    lib/detail.sh 'did not bind to port'
# Refresh + warnings + row visibility — Settings UI plus reader sites
t_grep "RefreshAndWarningsSection view"        native/ 'struct RefreshAndWarningsSection'
t_grep "RowElement enum"                       native/ 'enum RowElement'
t_grep "rowShows accessor"                     native/ 'func rowShows'
t_grep "tab title gated by rowShows"           native/ 'rowShows\(.tabTitle\)'
t_grep "compaction-warn gated by rowShows"     native/ 'rowShows\(.compactionWarn\)'
t_grep "mcp-down gated by rowShows"            native/ 'rowShows\(.mcpDown\)'
t_grep "RowVisibilitySection view"             native/ 'struct RowVisibilitySection'
t_grep "RowToggleRow row component"            native/ 'struct RowToggleRow'
t_grep "menuBehavior notification restarts timer" native/ 'restartScanTimer\(\)'
t_grep "inline row uses centerY alignment"     native/ 'row.alignment = .centerY'
t_grep "state-icon uses SF Symbol now"         native/ 'symbolAttributedString'

# Cleanup fixture
rm -f "$PROJ_DIR/${FIXTURE_SID}.jsonl"
rmdir "$PROJ_DIR" 2>/dev/null || true
rm -f "$DETAIL_OUT" "/tmp/claude-widget-${FIXTURE_PID}.daemon"

# ── Summary ──────────────────────────────────────────────────────────────────

t_log ""
t_log "${C_DIM}────────────────────────────────${C_RESET}"
if [[ "$FAIL" -eq 0 ]]; then
    t_log "${C_GREEN}all green: $PASS passed${C_RESET}"
    exit 0
else
    t_log "${C_RED}$FAIL failed${C_RESET}, $PASS passed"
    exit 1
fi
