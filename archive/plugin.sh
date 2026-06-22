#!/usr/bin/env bash
# claude-instances SwiftBar plugin
# Symlink to SwiftBar plugins dir as: claude-instances.2s.sh
#
# Shows live Claude Code instances in the macOS menu bar with a dropdown
# for session details, history, and management actions.

set -uo pipefail

WIDGET_DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
if [[ "$WIDGET_DIR" != *"widgets/claude-instances"* ]]; then
    WIDGET_DIR="${HOME}/.claude/widgets/claude-instances"
fi

# ─── Auto-sync: if running from SwiftBar copy, update from source if stale ───
_SOURCE="${WIDGET_DIR}/plugin.sh"
_SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
if [[ "$_SELF" != "$_SOURCE" && -f "$_SOURCE" ]]; then
    if [[ "$_SOURCE" -nt "$_SELF" ]]; then
        cp "$_SOURCE" "$_SELF" 2>/dev/null && chmod +x "$_SELF" 2>/dev/null
    fi
fi
SCAN_SCRIPT="${WIDGET_DIR}/lib/scan.sh"
DETAIL_SCRIPT="${WIDGET_DIR}/lib/detail.sh"
CACHE_FILE="/tmp/claude-widget-scan.json"
ERROR_FILE="/tmp/claude-widget-error.log"
CACHE_MAX_AGE=4  # seconds
MAX_SCAN_RETRIES=2

# ─── Detect terminal emulator for a PID ────────────────────────
detect_terminal_app() {
    local pid="$1"
    local cur="$pid"
    # Walk up the process tree to find the terminal app
    for _ in 1 2 3 4 5; do
        cur=$(ps -p "$cur" -o ppid= 2>/dev/null | tr -d ' ')
        [[ -z "$cur" || "$cur" == "1" || "$cur" == "0" ]] && break
        local cmd
        cmd=$(ps -p "$cur" -o comm= 2>/dev/null)
        if [[ "$cmd" == *"ghostty"* ]]; then
            echo "Ghostty"
            return
        elif [[ "$cmd" == *"Terminal"* || "$cmd" == *"terminal"* ]]; then
            echo "Terminal"
            return
        elif [[ "$cmd" == *"iTerm"* || "$cmd" == *"iterm"* ]]; then
            echo "iTerm2"
            return
        elif [[ "$cmd" == *"Alacritty"* ]]; then
            echo "Alacritty"
            return
        elif [[ "$cmd" == *"WezTerm"* || "$cmd" == *"wezterm"* ]]; then
            echo "WezTerm"
            return
        fi
    done
    echo "Ghostty"  # default
}

# ─── Handle click actions ───────────────────────────────────────
# Uses positional params: $1=action, $2=pid, $3=session_id
# (param1/param2/param3 in SwiftBar menu output)

ACTION="${1:-${SWIFTBAR_ACTION:-}}"
ACTION_PID="${2:-${SWIFTBAR_ACTION_PID:-}}"
ACTION_SID="${3:-${SWIFTBAR_ACTION_SID:-}}"

if [[ "$ACTION" == "new_session" ]]; then
    terminal_app="Ghostty"
    osascript -e "tell application \"$terminal_app\" to activate" &>/dev/null
    exit 0
fi

if [[ "$ACTION" == "focus" ]]; then
    if [[ -n "$ACTION_PID" ]]; then
        terminal_app=$(detect_terminal_app "$ACTION_PID")
        osascript -e "tell application \"$terminal_app\" to activate" &>/dev/null
    fi
    exit 0
fi

if [[ "$ACTION" == "terminate" ]]; then
    if [[ -n "$ACTION_PID" ]]; then
        kill -TERM "$ACTION_PID" 2>/dev/null
        sleep 3
        kill -0 "$ACTION_PID" 2>/dev/null && kill -KILL "$ACTION_PID" 2>/dev/null
    fi
    exit 0
fi

if [[ "$ACTION" == "terminate_all" ]]; then
    pgrep -fl 'claude' 2>/dev/null | while read -r pid cmd; do
        if [[ "$cmd" == "claude "* ]] || [[ "$cmd" == "claude" ]]; then
            if ! echo "$cmd" | grep -qE 'emit-event|hook|esbuild|server\.js'; then
                kill -TERM "$pid" 2>/dev/null
            fi
        fi
    done
    exit 0
fi

if [[ "$ACTION" == "open_dashboard" ]]; then
    bash "${WIDGET_DIR}/render.sh" &>/dev/null
    open "${WIDGET_DIR}/dashboard.html" &>/dev/null
    exit 0
fi

if [[ "$ACTION" == "open_detail" ]]; then
    if [[ -f "$DETAIL_SCRIPT" ]]; then
        bash "$DETAIL_SCRIPT" "$ACTION_PID" "$ACTION_SID" &>/dev/null
    fi
    exit 0
fi

if [[ "$ACTION" == "clear_cache" ]]; then
    rm -f "$CACHE_FILE" "$ERROR_FILE" 2>/dev/null
    exit 0
fi

if [[ "$ACTION" == "copy_pid" ]]; then
    echo -n "$ACTION_PID" | pbcopy
    exit 0
fi

# ─── Scan (with caching + error recovery) ──────────────────────

scan_data=""
scan_error=""

if [[ -f "$CACHE_FILE" ]]; then
    cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
    if (( cache_age < CACHE_MAX_AGE )); then
        scan_data=$(cat "$CACHE_FILE" 2>/dev/null)
    fi
fi

if [[ -z "$scan_data" ]]; then
    for attempt in $(seq 1 $MAX_SCAN_RETRIES); do
        scan_data=$(bash "$SCAN_SCRIPT" 2>"$ERROR_FILE") && break
        scan_data=""
        sleep 0.5
    done
    if [[ -z "$scan_data" ]]; then
        scan_error=$(cat "$ERROR_FILE" 2>/dev/null | tail -3)
        scan_data='{"live_count":0,"live":[],"history":[],"recent_events":[]}'
    fi
    echo "$scan_data" > "$CACHE_FILE" 2>/dev/null
fi

# ─── Render menu bar + dropdown ──────────────────────────────────

python3 - "$scan_data" "$WIDGET_DIR/plugin.sh" "$scan_error" <<'PYEOF'
import sys, json
from datetime import datetime, timezone

SCRIPT = sys.argv[2] if len(sys.argv) > 2 else sys.argv[0]
SCAN_ERROR = sys.argv[3] if len(sys.argv) > 3 else ''

try:
    data = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    print("? | sfimage=sparkles sfcolor=#D97757")
    print("---")
    print("Scanner error | color=red")
    print(f"Retry | bash={SCRIPT} param1=clear_cache terminal=false refresh=true")
    sys.exit(0)

live = data.get('live', [])
history = data.get('history', [])
events = data.get('recent_events', [])
limits = data.get('limits', None)
live_count = len(live)

# ─── Helpers ───────────────────────────────────────────────────

def safe_int(v):
    try: return int(str(v).split()[0]) if v else 0
    except (ValueError, TypeError): return 0

def ftok(n):
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.0f}K"
    return str(n)

def reltime(modified):
    if not modified: return '?'
    try:
        t = datetime.fromisoformat(modified.replace('Z', '+00:00'))
        s = (datetime.now(timezone.utc) - t).total_seconds()
        if s < 60: return 'now'
        if s < 3600: return f'{int(s/60)}m'
        if s < 86400: return f'{int(s/3600)}h'
        return f'{int(s/86400)}d'
    except ValueError: return '?'

def spath(p, n=32):
    if not p or len(p) <= n: return p or '?'
    return '…' + p[-(n-1):]

# Model config — no color on model labels, just the badge character
# Color is ONLY used on the model badge row
MODELS = {
    'opus':   {'badge': '◆', 'label': 'Opus'},
    'sonnet': {'badge': '●', 'label': 'Sonnet'},
    'haiku':  {'badge': '○', 'label': 'Haiku'},
}
DEF_MODEL = {'badge': '·', 'label': '?'}

def mdl(m):
    return MODELS.get(m, DEF_MODEL)

# ═══════════════════════════════════════════════════════════════
# MENU BAR — SF Symbol "sparkles" with Anthropic coral tint
# ═══════════════════════════════════════════════════════════════

has_perm = any(e.get('event') == 'PermissionRequest' for e in events[-3:])
bar_text = f"⚠ {live_count}" if has_perm else (str(live_count) if live_count else "–")
print(f"{bar_text} | sfimage=sparkles sfcolor=#D97757")
print("---")

# ═══════════════════════════════════════════════════════════════
# DROPDOWN — system font, no color= on most items (uses system default)
# Only color the model badge lines and alerts.
# System default = white text on dark vibrancy = maximum readability.
# ═══════════════════════════════════════════════════════════════

if SCAN_ERROR:
    print(f"⚠ Scanner error (stale data) | color=red size=13")
    print(f"--Retry | bash={SCRIPT} param1=clear_cache terminal=false refresh=true")
    print("---")

# ─── Summary ──────────────────────────────────────────────────

if live_count > 0:
    total_out = sum(i.get('output_tokens', 0) for i in live)
    total_cache = sum(i.get('cache_read', 0) for i in live)
    total_turns = sum(i.get('turns', 0) for i in live)
    total_rss = sum(safe_int(i.get('statusline', {}).get('rss_mb', 0)) for i in live)

    parts = [f"{live_count} live"]
    if total_turns: parts.append(f"{total_turns} turns")
    if total_rss: parts.append(f"{total_rss} MB")
    if total_out: parts.append(f"↑{ftok(total_out)}")
    if total_cache: parts.append(f"cached {ftok(total_cache)}")
    # No color= — uses system default (white on dark, black on light)
    print(f"{' · '.join(parts)} | size=13")
    print("---")

# ─── Usage limits ──────────────────────────────────────────────

if limits:
    for key in ['5h', 'week']:
        lim = limits.get(key, {})
        pct = lim.get('pct', 0)
        used = lim.get('used', 0)
        cap = lim.get('cap', 0)
        filled = round(pct / 100 * 12)
        bar = '█' * filled + '░' * (12 - filled)
        color = '' if pct < 75 else (' color=#eab308' if pct < 90 else ' color=red')
        u = f"{used/1e6:.1f}M" if used > 999_999 else f"{used/1000:.0f}K"
        c = f"{cap/1e6:.1f}M" if cap > 999_999 else f"{cap/1000:.0f}K"
        lbl = '5hr' if key == '5h' else 'Week'
        print(f"  {lbl}  {bar}  {pct}%  ({u}/{c}) | font=Menlo size=12{color}")
    print("---")

# ─── Live instances ────────────────────────────────────────────

if live_count == 0:
    print("No live instances | size=13 color=gray")
    print("---")
else:
    for idx, inst in enumerate(live):
        pid = inst['pid']
        model = inst.get('model', '?')
        cwd = inst.get('cwd_short', '?')
        elapsed = inst.get('elapsed', '?').strip()
        turns = inst.get('turns', 0)
        out_tok = inst.get('output_tokens', 0)
        cache = inst.get('cache_read', 0)
        sl = inst.get('statusline', {})
        rss = sl.get('rss_mb', '')
        focus = sl.get('focus_file', '')
        mcp_down = sl.get('mcp_down', '')
        session_id = inst.get('session_id', '')
        m = mdl(model)

        # Row 1: Model + path — this is the ONLY colored line per instance
        print(f"{m['badge']} {m['label']}  {spath(cwd, 30)} | size=14 font=Menlo-Bold")

        # Row 2: metadata — system default color (no color=)
        meta = [f"PID {pid}", elapsed]
        if rss and rss != '0': meta.append(f"{rss} MB")
        if turns: meta.append(f"{turns}t")
        if out_tok: meta.append(f"↑{ftok(out_tok)}")
        print(f"  {'  ·  '.join(meta)} | size=12 font=Menlo")

        # Row 3: Focus file — only if present
        if focus:
            cwd_full = inst.get('cwd', '')
            fs = focus.replace(cwd_full, '.') if cwd_full else focus.replace('/Users/alcatraz627', '~')
            if cwd_full: fs = fs.replace('/Users/alcatraz627', '~')
            print(f"  → {spath(fs, 40)} | size=12 font=Menlo")

        if mcp_down:
            print(f"  ⚠ MCP down: {mcp_down} | size=12 color=red")

        # Actions submenu — use param1/param2/param3 (BitBar-compatible positional args)
        print(f"--Focus terminal | bash={SCRIPT} param1=focus param2={pid} terminal=false refresh=false sfimage=terminal")
        if session_id:
            print(f"--Detail page | bash={SCRIPT} param1=open_detail param2={pid} param3={session_id} terminal=false refresh=false sfimage=doc.text.magnifyingglass")
        print(f"--Copy PID | bash={SCRIPT} param1=copy_pid param2={pid} terminal=false refresh=false sfimage=doc.on.clipboard")
        print("-----")
        print(f"--Terminate | bash={SCRIPT} param1=terminate param2={pid} terminal=false color=red sfimage=xmark.circle")

        if idx < live_count - 1:
            print("---")

    print("---")

# ─── Events ───────────────────────────────────────────────────

if events:
    EVT_LABEL = {'SessionStart': 'Started', 'Stop': 'Stopped',
                 'PermissionRequest': 'Permission', 'PostCompact': 'Compacted'}
    print(f"Events | size=12 sfimage=clock")
    for evt in reversed(events[-5:]):
        ev = evt.get('event', '?')
        ts = evt.get('ts', '?')
        if 'T' in ts: ts = ts.split('T')[1][:5]
        project = evt.get('project', '')
        if len(project) > 20: project = '…' + project[-19:]
        label = EVT_LABEL.get(ev, ev)
        print(f"--{ts}  {label:10s}  {project} | font=Menlo size=12")
    print("---")

# ─── History ──────────────────────────────────────────────────

if history:
    print(f"History ({len(history)}) | size=12 sfimage=clock.arrow.circlepath")
    for sess in history[:8]:
        sid = sess.get('session_id', '?')
        project = sess.get('project', '?')
        model = sess.get('model', '?')
        turns = sess.get('turns', 0)
        modified = sess.get('modified', '')
        size_kb = sess.get('size_kb', 0)
        m = mdl(model)
        rel = reltime(modified)
        sz = f"{size_kb/1024:.1f}M" if size_kb > 1024 else f"{int(size_kb)}K"
        lbl = "↳ agent" if sid.startswith('agent-') else project
        print(f"--{lbl:16s} {m['badge']}  {turns:>5}t  {sz:>6}  {rel:>4} | font=Menlo size=12")
    print("---")

# ─── Actions ──────────────────────────────────────────────────

print(f"New Session | bash={SCRIPT} param1=new_session terminal=false refresh=true sfimage=plus.circle")
print(f"Dashboard | bash={SCRIPT} param1=open_dashboard terminal=false refresh=false sfimage=chart.bar.xaxis.ascending")
if live_count > 0:
    print("---")
    print(f"Terminate All ({live_count}) | bash={SCRIPT} param1=terminate_all terminal=false refresh=true color=red sfimage=xmark.circle")
print("---")
print(f"Refresh | bash={SCRIPT} param1=clear_cache terminal=false refresh=true sfimage=arrow.clockwise")
PYEOF
