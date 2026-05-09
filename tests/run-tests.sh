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
if /usr/bin/swiftc -O native/claude-instances-bar.swift -o "$SWIFT_OUT" 2>&1; then
    t_pass "claude-instances-bar.swift compiles (-O)"
    rm -f "$SWIFT_OUT"
else
    t_fail "claude-instances-bar.swift FAILED to compile"
    rm -f "$SWIFT_OUT"
fi

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

# Markers expected in any well-formed transcript.
[[ -f "$DETAIL_OUT" ]] && {
    t_grep "doctype present"           "$DETAIL_OUT" '<!DOCTYPE html>'
    t_grep "marked CDN link"           "$DETAIL_OUT" 'marked.*\.min\.js'
    t_grep "highlight.js CDN link"     "$DETAIL_OUT" 'highlight\.min\.js'
    t_grep "favicon present"           "$DETAIL_OUT" 'rel="icon"'
    t_grep "ai-title applied to header" "$DETAIL_OUT" 'Test session for fixtures'
    t_grep "permission-mode pill"      "$DETAIL_OUT" '🔓.*auto'
    t_grep "msg-idx badges"            "$DETAIL_OUT" 'msg-idx'
    t_grep "data-target dot links"     "$DETAIL_OUT" 'data-target="msg-'
    t_grep "rebuildFlowArrows defined" "$DETAIL_OUT" 'function rebuildFlowArrows'
    t_grep "FLOW_ICONS before applyFilter (TDZ-safety check)" \
           "$DETAIL_OUT" 'const FLOW_ICONS'
    t_grep "autolinkTextNodes defined" "$DETAIL_OUT" 'function autolinkTextNodes'
    t_grep "hook-summary event row"    "$DETAIL_OUT" '3 hooks ran'
    t_grep "live poller present"       "$DETAIL_OUT" 'function livePoll'
    t_grep "/regen endpoint referenced" "$DETAIL_OUT" "fetch\\('/regen'"
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
t_grep "LiveRowView class defined" native/claude-instances-bar.swift 'class LiveRowView'
t_grep "intrinsicContentSize override (sizing fix)" native/claude-instances-bar.swift 'override var intrinsicContentSize'
t_grep "menuWillOpen tracks open state" native/claude-instances-bar.swift 'func menuWillOpen'
t_grep "refreshLiveRows wired to data refresh" native/claude-instances-bar.swift 'refreshLiveRows()'

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
