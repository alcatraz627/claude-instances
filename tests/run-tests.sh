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

# ── T3.5 — provider seam: default field + codex fixture ─────────────────────

t_section "provider seam"
SEAM_OUT=$(mktemp)
bash lib/scan.sh > "$SEAM_OUT" 2>/dev/null
if [[ "$LIVE_COUNT" -gt 0 ]]; then
    if python3 -c "
import json,sys
inst = json.load(open('$SEAM_OUT'))['live'][0]
sys.exit(0 if inst.get('provider') == 'claude' else 1)" 2>/dev/null; then
        t_pass "scan.sh live[0] carries provider:'claude'"
    else
        t_fail "scan.sh live[0] missing/wrong 'provider'"
    fi
else
    t_log "  ${C_DIM}(skipping live provider check — no live Claude sessions)${C_RESET}"
fi
if python3 -c "
import json,sys
hist = json.load(open('$SEAM_OUT')).get('history', [])
sys.exit(0 if hist and hist[0].get('provider') == 'claude' else 1)" 2>/dev/null; then
    t_pass "scan.sh history[0] carries provider:'claude'"
else
    t_fail "scan.sh history[0] missing/wrong 'provider' (or history empty)"
fi
rm -f "$SEAM_OUT"

# Codex fixture: stage a real (redacted) rollout under today's date shard —
# inside codex_transcript_iter's 14-day window — run a real scan, confirm it
# surfaces as a 'codex' history entry, then clean up. A synthetic session_id
# (not the real on-disk codex session's id) keeps the assertions deterministic
# regardless of what real codex history this machine has.
CODEX_FIXTURE="$REPO_ROOT/tests/fixtures/sample-codex-session.jsonl"
CODEX_FIXTURE_SID="test-fixture-codex-0000000000001"
CODEX_SHARD="$HOME/.codex/sessions/$(date -u +%Y)/$(date -u +%m)/$(date -u +%d)"
CODEX_STAGED="$CODEX_SHARD/rollout-test-fixture-${CODEX_FIXTURE_SID}.jsonl"
mkdir -p "$CODEX_SHARD"
cp "$CODEX_FIXTURE" "$CODEX_STAGED"

CODEX_SCAN_OUT=$(mktemp)
bash lib/scan.sh > "$CODEX_SCAN_OUT" 2>/dev/null

CODEX_CHECK() {
    python3 -c "
import json,sys
hist = json.load(open('$CODEX_SCAN_OUT')).get('history', [])
match = next((s for s in hist if s.get('session_id') == '$CODEX_FIXTURE_SID'), None)
sys.exit(0 if match and match.get('$1') == '''$2''' else 1)" 2>/dev/null
}

if CODEX_CHECK provider codex; then
    t_pass "codex fixture surfaces in history with provider:'codex'"
else
    t_fail "codex fixture did not surface in history with provider:'codex'"
fi
if CODEX_CHECK model 'openai/0.142.5'; then
    t_pass "codex fixture model shown as model_provider/cli_version"
else
    t_fail "codex fixture model field wrong"
fi
if CODEX_CHECK project 'Claude/fastfetch-explorer'; then
    t_pass "codex fixture project derived from session_meta cwd"
else
    t_fail "codex fixture project field wrong"
fi
if python3 -c "
import json,sys
hist = json.load(open('$CODEX_SCAN_OUT')).get('history', [])
match = next((s for s in hist if s.get('session_id') == '$CODEX_FIXTURE_SID'), None)
sys.exit(0 if match and match.get('turns') == 2 else 1)" 2>/dev/null; then
    t_pass "codex fixture turn count (assistant messages)"
else
    t_fail "codex fixture turn count wrong"
fi

rm -f "$CODEX_SCAN_OUT" "$CODEX_STAGED"
rmdir "$CODEX_SHARD" 2>/dev/null || true
rmdir "$(dirname "$CODEX_SHARD")" 2>/dev/null || true
rmdir "$(dirname "$(dirname "$CODEX_SHARD")")" 2>/dev/null || true

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

# ── Cost reporting ───────────────────────────────────────────────────────────
#
# The dashboard once reported a fable session's $215 as $0.00: estimate_cost
# priced any model missing from COST_RATES at zero, which renders exactly like
# genuinely free. These pin the two halves of the contract — the daemon's own
# cost file wins, and an unpriced model says so instead of guessing zero.

# ── Live-tail cursor ─────────────────────────────────────────────────────────
#
# A tools group flushed mid-burst keeps its seq while still gaining tools, so
# `since=<seq>` filtering used to hide every tool appended after the client
# first saw that group — the transcript went quiet and the UI claimed the agent
# was done. The probe drives the real client loop against a growing fixture and
# checks both directions: the growth arrives, AND the session still goes idle
# once the burst actually stops.

t_section "live-tail cursor"

SINCE_OUT=$(python3 "$REPO_ROOT/tests/fixtures/since-probe.py" 2>&1)
t_eq "since-probe: all cases pass" "0" "$?"
for _case in "client catches up mid-burst" "grown group is delivered" \
             "growth counts as activity" "no duplicate records" \
             "goes idle when the burst stops" "post-close records still arrive"; do
    if grep -q "\[PASS\] $_case" <<< "$SINCE_OUT"; then t_pass "since: $_case"
    else t_fail "since: $_case — $(grep -A1 "\[FAIL\] $_case" <<< "$SINCE_OUT" | tail -1)"; fi
done

# A codex row used to look exactly like a claude row and 404 on click. The hub
# can only read claude transcripts: they live under ~/.claude/projects, and the
# reader keys on user/assistant lines a codex rollout doesn't have — pointing it
# at one would render an EMPTY session rather than fail, which is worse.
# /tmp is world-writable, so a per-PID path is untrusted input. Opening a FIFO
# blocks forever waiting for a writer and takes the whole scan with it — and
# os.path.exists() is True for a FIFO, so the idiom these readers used was no
# guard at all. The hard timeout IS the assertion: without isfile() the probe
# never returns.
_fifo_probe() {   # kind -> what the reader returns, or HUNG
    local kind="$1" pid=999883
    mkfifo "/tmp/claude-${kind}-${pid}" 2>/dev/null
    perl -e 'my $p=fork; if($p==0){setpgrp(0,0); exec(@ARGV)} local $SIG{ALRM}=sub{kill "KILL",-$p; print "HUNG\n"; exit 0}; alarm 8; waitpid($p,0)' \
        python3 "$SCAN_PROBE" read_pid_file "$pid" "$kind" 2>/dev/null
    trash "/tmp/claude-${kind}-${pid}" 2>/dev/null || true
}
for _k in statusline ctx tpath cost; do
    t_eq "a FIFO at claude-${_k} does not hang the scan" "" "$(_fifo_probe "$_k")"
done

# Hub hardening. Each of these reported something confident and false: a scan
# that failed cached "no sessions" as fact; a cache miss launched N scans
# instead of one; a broken transcript.py stayed silent until someone hit a 500;
# and hub.sh called a start successful when the port belonged to another
# process entirely — which served stale code for hours.
# Found by the adversarial pass, each a hole in a fix from this same session:
# a scan that crashed AFTER printing valid JSON was cached as truth; `?since=`
# (bare) skipped the validation entirely because parse_qs drops blank values;
# and `**` follows symlinks, so one planted link made a tailnet-reachable
# server hand out any .jsonl on the disk.
t_grep "a scan that exits nonzero is a failure" lib/hub-server.py 'scan.sh exited'
t_grep "blank query values are kept"        lib/hub-server.py 'keep_blank_values=True'
t_grep "symlinks cannot escape the root"    lib/hub-server.py 'startswith\(root \+ os.sep\)'
t_grep "a shrunk group is not frozen"       lib/transcript-app.html 'if \(after === before\) continue'

t_grep "scan runs under the lock, once"     lib/hub-server.py 'The lock covers the'
t_grep "a failed scan keeps the last good"  lib/hub-server.py 'keeping the last good result'
t_grep "broken transcript.py warns at boot" lib/hub-server.py 'WARNING: transcript.py failed to import'
t_grep "parser errors do not reach clients" lib/hub-server.py 'transcript could not be parsed'
t_grep "duplicate session ids are surfaced" lib/hub-server.py 'transcripts share id'
t_grep "detail.sh picks freshest on a tie"  lib/detail.sh 'sort -rn'
t_grep "hub.sh checks OUR pid holds it"     lib/hub.sh 'grep -qx "\$pid"'

t_grep "hub passes provider through (live)"   lib/hub-server.py '"provider": inst.get'
t_grep "hub passes provider through (recent)" lib/hub-server.py '"provider": h.get'
t_grep "unreadable rows carry no link"        lib/hub-index.html 'const openable'
t_grep "unreadable rows say why"              lib/hub-index.html "transcript isn't readable here"
t_grep "no prefetch of unreadable rows"       lib/hub-index.html '\.filter\(openable\)'

t_grep "EOF flush marks the group open" lib/transcript.py 'flush_tools\(still_open=True\)'
t_grep "reader resends the open group"  lib/hub-server.py 'r\.get\("open"\)'
t_grep "bad since is rejected, not ignored" lib/hub-server.py 'since must be an integer'
t_grep "client swaps the open group"    lib/transcript-app.html 'function refreshOpen'

t_section "cost reporting"

SCAN_PROBE="$REPO_ROOT/tests/fixtures/scan-probe.py"
COST_PID=999424

t_eq "priced model still prices"      "90.0"  "$(python3 "$SCAN_PROBE" estimate opus 1000000 1000000)"
t_eq "sonnet rate intact"             "18.0"  "$(python3 "$SCAN_PROBE" estimate sonnet 1000000 1000000)"
t_eq "unpriced model is None, not 0"  "None"  "$(python3 "$SCAN_PROBE" estimate fable 1000000 1000000)"
t_eq "full model id normalizes"       "90.0"  "$(python3 "$SCAN_PROBE" estimate claude-opus-4-8 1000000 1000000)"
t_eq "empty model is None"            "None"  "$(python3 "$SCAN_PROBE" estimate '' 1000000 1000000)"
# A name that merely contains a family word must not inherit its rates.
t_eq "octopus is not opus"            "None"  "$(python3 "$SCAN_PROBE" estimate octopus 1000000 1000000)"
t_eq "full haiku id still prices"     "1.5"   "$(python3 "$SCAN_PROBE" estimate claude-haiku-4-5-20251001 1000000 1000000)"
t_eq "zero tokens costs nothing"      "0.0"   "$(python3 "$SCAN_PROBE" estimate opus 0 0)"
# json.loads accepts a bare Infinity, so a corrupt transcript's usage counts can
# arrive as inf. An infinite cost serializes as a non-JSON literal and takes the
# whole scan down — including every other session, via the aggregates.
t_eq "infinite input tokens are None" "None"  "$(python3 "$SCAN_PROBE" estimate opus inf 100)"
t_eq "infinite output tokens are None" "None" "$(python3 "$SCAN_PROBE" estimate opus 100 inf)"
t_eq "NaN tokens are None"            "None"  "$(python3 "$SCAN_PROBE" estimate opus nan 100)"

# read_cost trusts the daemon's file, but never a malformed one.
printf '215.3312241500002\n' > "/tmp/claude-cost-${COST_PID}"
t_eq "reads the daemon's cost file"   "215.3312"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
printf '' > "/tmp/claude-cost-${COST_PID}"
t_eq "empty cost file is None"        "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
printf '   \n' > "/tmp/claude-cost-${COST_PID}"
t_eq "whitespace cost file is None"   "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
printf 'not-a-number\n' > "/tmp/claude-cost-${COST_PID}"
t_eq "garbage cost file is None"      "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
printf -- '-5\n' > "/tmp/claude-cost-${COST_PID}"
t_eq "negative cost is None"          "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
# float() parses these, and json.dumps would emit the bare literal Infinity —
# not JSON, so every consumer of the scan breaks, not just one card.
printf 'inf\n' > "/tmp/claude-cost-${COST_PID}"
t_eq "infinite cost is None"          "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
printf 'nan\n' > "/tmp/claude-cost-${COST_PID}"
t_eq "NaN cost is None"               "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
printf '1e400\n' > "/tmp/claude-cost-${COST_PID}"
t_eq "overflow-to-inf cost is None"   "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
trash "/tmp/claude-cost-${COST_PID}" 2>/dev/null || true
t_eq "missing cost file is None"      "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
mkdir -p "/tmp/claude-cost-${COST_PID}"
t_eq "a directory is not a cost"      "None"  "$(python3 "$SCAN_PROBE" read_cost "$COST_PID")"
rmdir "/tmp/claude-cost-${COST_PID}" 2>/dev/null || true

# /tmp is world-writable: a FIFO here blocks open() forever waiting for a
# writer, stalling every scan. The hard timeout is the assertion — without the
# isfile() guard this never returns.
mkfifo "/tmp/claude-cost-${COST_PID}" 2>/dev/null
_fifo_read=$(perl -e 'my $p=fork; if($p==0){setpgrp(0,0); exec(@ARGV)} local $SIG{ALRM}=sub{kill "KILL",-$p; print "HUNG\n"; exit 0}; alarm 8; waitpid($p,0)' \
    python3 "$SCAN_PROBE" read_cost "$COST_PID" 2>/dev/null)
t_eq "a FIFO does not hang the scan"  "None"  "$_fifo_read"
trash "/tmp/claude-cost-${COST_PID}" 2>/dev/null || true

# An unpriced session must not take the aggregates down with it.
t_eq "aggregates survive a None cost" "1.5"   "$(python3 "$SCAN_PROBE" agg_sum '[1.5, null]')"

# Transcripts are just files on disk and json.loads accepts a bare Infinity, so
# usage counts are untrusted input. Guard at the boundary they enter through.
t_eq "Infinity token count is 0"      "0"     "$(python3 "$SCAN_PROBE" tokens 'Infinity')"
t_eq "NaN token count is 0"           "0"     "$(python3 "$SCAN_PROBE" tokens 'NaN')"
t_eq "string token count is 0"        "0"     "$(python3 "$SCAN_PROBE" tokens '"lots"')"
t_eq "null token count is 0"          "0"     "$(python3 "$SCAN_PROBE" tokens 'null')"
t_eq "bool token count is 0"          "0"     "$(python3 "$SCAN_PROBE" tokens 'true')"
t_eq "real token count survives"      "1234"  "$(python3 "$SCAN_PROBE" tokens '1234')"

# The unit guards above all passed while the scan still emitted a bare Infinity
# through tokens_in, so assert on the whole scan's real output too.
t_eq "poisoned transcript keeps the scan valid JSON" "STRICT_JSON_OK" \
     "$(python3 "$SCAN_PROBE" poison_scan)"

# ── Session counts ───────────────────────────────────────────────────────────
#
# Reading only the last 500KB made turns/tool_calls a fiction on any real
# session: transcripts are mostly huge tool_result lines, so a 58MB session
# reported 44 of its 4488 turns — and shipped that as the total.

t_section "session counts"

t_eq "counts every turn past the old window" "40:40:True" \
     "$(python3 "$SCAN_PROBE" turns_big 40)"
t_eq "counts a small session exactly"        "3:3:False" \
     "$(python3 "$SCAN_PROBE" turns_big 3)"

# History used to count every JSONL line as a turn (so 12 turns read as 25) and
# take its tokens from the last line, which is nearly always a tool_result —
# hence a day of real work totalling 6 input tokens.
t_eq "history counts turns like live does"   "12:120:60" \
     "$(python3 "$SCAN_PROBE" history_session 12)"

# ── Day boundaries ───────────────────────────────────────────────────────────
#
# "Today" means the reader's today. Bucketing by UTC is self-consistent and
# still wrong everywhere but UTC: at +05:30 a night's work carried yesterday's
# UTC date and dropped out of `today` the moment UTC rolled over. The zones are
# pinned because this bug is invisible in UTC — the tests must fail wherever
# they run, not only where they were written.

# ── Scan cost ────────────────────────────────────────────────────────────────
#
# The scan's expense was never the files — it was spawning lsof and ps once per
# live session. Both cost far more to start than to answer (one lsof about
# eight processes takes the same ~0.3s as one about a single process), so 25
# spawns burned 2.7s of a 2.8s scan. These pin the batching, and the tail read
# that replaced loading a 26MB log to keep its last 500 lines.

t_section "scan cost"

# -a is load-bearing: lsof ORs its selection flags, so `-p <pids> -d cwd` means
# "these pids OR any cwd" and dumps the whole process table — ~2400 lines for a
# pid that doesn't even exist, and the cache then held every process on the box.
t_grep "lsof ANDs its selection flags"  lib/scan.sh "'lsof', '-a', '-p'"
t_check "lsof -a really filters"        bash -c '[ "$(lsof -a -p 999999 -d cwd -Fn 2>/dev/null | wc -l | tr -d " ")" = "0" ]'
t_grep "only requested pids are cached" lib/scan.sh 'cur in want'

t_grep "process info is batched"        lib/scan.sh 'def prime_process_info'
t_grep "batched before any row is built" lib/scan.sh 'prime_process_info\(\[p for p'
t_grep "logs are tailed, not slurped"   lib/scan.sh 'def tail_lines'
# Exactly one readlines() may remain: the one inside tail_lines, which reads
# only the span it seeked to. Any second one is a whole-file slurp again.
t_eq "only tail_lines slurps"           "1"   "$(rg -c 'readlines\(\)' lib/scan.sh)"
t_eq "tail_lines returns the last n"    "3" \
     "$(printf 'a\nb\nc\nd\ne\n' > /tmp/tl-test.txt; python3 "$SCAN_PROBE" tail /tmp/tl-test.txt 3; trash /tmp/tl-test.txt 2>/dev/null)"

t_section "day boundaries"

t_eq "19:00Z is next-day in +05:30"  "2026-07-17" \
     "$(TZ=Asia/Kolkata python3 "$SCAN_PROBE" local_day '2026-07-16T19:00:00Z')"
t_eq "19:00Z is same-day in UTC"     "2026-07-16" \
     "$(TZ=UTC python3 "$SCAN_PROBE" local_day '2026-07-16T19:00:00Z')"
t_eq "19:00Z is same-day in -07:00"  "2026-07-16" \
     "$(TZ=America/Los_Angeles python3 "$SCAN_PROBE" local_day '2026-07-16T19:00:00Z')"
t_eq "malformed stamp is not a day"  "" \
     "$(python3 "$SCAN_PROBE" local_day 'not-a-timestamp')"
t_eq "01:00 local counts as today (+05:30)" "1:1" \
     "$(TZ=Asia/Kolkata python3 "$SCAN_PROBE" buckets)"
t_eq "01:00 local counts as today (UTC)"    "1:1" \
     "$(TZ=UTC python3 "$SCAN_PROBE" buckets)"
t_eq "01:00 local counts as today (+12:00)" "1:1" \
     "$(TZ=Pacific/Auckland python3 "$SCAN_PROBE" buckets)"

# ── Aggregate window (R1) ────────────────────────────────────────────────────
#
# The header's totals used to be computed over the 20-row display list, so
# "today: 19 sessions" really meant "however many of the newest 20 were
# today's" — 148 real sessions read as 19. The aggregates now walk the whole
# window through a per-file summary cache; the display list stays capped
# because it is a list of rows, not a total.

t_section "aggregate window (R1)"

t_eq "aggregates see past the display cap"  "25:20:25:125" \
     "$(python3 "$SCAN_PROBE" agg_window 25)"
t_eq "the shipped output walks the window"  "25:20" \
     "$(python3 "$SCAN_PROBE" agg_e2e 25)"
t_eq "sub-agent transcripts are not sessions" "3:3:15" \
     "$(python3 "$SCAN_PROBE" agg_sessions_only)"
# The bar renders model_breakdown on its "Today" row; an unfiltered count over
# the window walk showed the week's model mix wearing a Today label.
t_eq "model badges count today, not the window" '2:3:{"opus": 2}' \
     "$(python3 "$SCAN_PROBE" agg_models_today)"
t_eq "unchanged files come from the cache"  "3:0:1:3" \
     "$(python3 "$SCAN_PROBE" agg_cache_reuse 3)"
t_eq "corrupt cache rebuilds and repairs"   "3:REPAIRED" \
     "$(python3 "$SCAN_PROBE" agg_cache_corrupt 3)"
t_eq "wrong-shape cache entries re-parse"   "3:15:PRUNED" \
     "$(python3 "$SCAN_PROBE" agg_cache_shape 3)"
t_eq "cache write is atomic, tmp cleaned"   "ATOMIC:CLEAN" \
     "$(python3 "$SCAN_PROBE" agg_cache_atomic 3)"

t_section "small truths (R3)"

t_eq "codex unknown tokens are None, and total"  "None:None:1:0:1" \
     "$(python3 "$SCAN_PROBE" codex_none)"
t_eq "stale tpath pointers are ignored"          "OK:STALE_IGNORED" \
     "$(python3 "$SCAN_PROBE" tpath_stale)"
t_grep "hub pidfile is port-scoped"      lib/hub.sh 'claude-hub-\$\{PORT\}\.pid'
t_grep "hub start verifies the loopback" lib/hub.sh 'healthz'
t_grep "/data parses through the cache"  lib/hub-server.py 'def _parse_cached'
t_check "/data cache behaves under real HTTP (isolation, no mutation, eviction)" \
        python3 "$REPO_ROOT/tests/fixtures/hub-cache-probe.py"
t_grep "tab titles primed once per scan" lib/scan.sh '_tab_topics'

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
