#!/usr/bin/env bash
# detail.sh — Generate and open a session detail HTML page.
#
# Usage: bash detail.sh <pid> <session_id>
#
# Generates /tmp/claude-widget-<pid>.html with conversation stream, tool-call
# detail, search/filter UI, token usage, MCP status, activity timeline, and
# 5s auto-refresh that preserves theme + search + scroll between reloads.

set -uo pipefail

# `--regen` mode: silently regenerate the HTML file (no browser, no daemon).
# Used by the background regenerator daemon so the file on disk stays fresh.
REGEN_ONLY=0
if [[ "${1:-}" == "--regen" ]]; then
    REGEN_ONLY=1
    shift
fi

PID="${1:-}"
SESSION_ID="${2:-}"
PROJECTS_DIR="${HOME}/.claude/projects"
OUTPUT="/tmp/claude-widget-${PID:-unknown}.html"
DAEMON_PID_FILE="/tmp/claude-widget-${PID:-unknown}.daemon"
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [[ -z "$PID" ]] && [[ -z "$SESSION_ID" ]]; then
    echo "Usage: detail.sh [--regen] <pid> [session_id]" >&2
    exit 1
fi

# Find the JSONL transcript for this session.
JSONL_FILE=""
if [[ -n "$SESSION_ID" ]]; then
    JSONL_FILE=$(find "$PROJECTS_DIR" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -1)
fi
if [[ -z "$JSONL_FILE" ]] && [[ -n "$PID" ]]; then
    CWD=$(lsof -p "$PID" -d cwd -Fn 2>/dev/null | grep "^n/" | head -1 | cut -c2-)
    if [[ -n "$CWD" ]]; then
        SLUG=$(echo "$CWD" | tr '/' '-' | sed 's/^-//')
        PROJ_DIR="${PROJECTS_DIR}/-${SLUG}"
        if [[ -d "$PROJ_DIR" ]]; then
            JSONL_FILE=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
        fi
    fi
fi

# Read statusline (key=value lines from /tmp/claude-statusline-<pid>).
STATUSLINE_FILE="/tmp/claude-statusline-${PID}"
STATUSLINE_DATA="{}"
if [[ -f "$STATUSLINE_FILE" ]]; then
    STATUSLINE_DATA=$(python3 -c "
import json
metrics = {}
with open('$STATUSLINE_FILE') as f:
    for line in f:
        line = line.strip()
        if '=' in line:
            k, _, v = line.partition('=')
            metrics[k.strip()] = v.strip()
print(json.dumps(metrics))
" 2>/dev/null || echo '{}')
fi

# Generate the HTML.
python3 - "$JSONL_FILE" "$PID" "$STATUSLINE_DATA" "$OUTPUT" <<'PYEOF'
import sys, json, os, html, re
from datetime import datetime, timezone
from collections import Counter

jsonl_file  = sys.argv[1] if sys.argv[1] else None
pid         = sys.argv[2]
statusline  = json.loads(sys.argv[3]) if sys.argv[3] != '{}' else {}
output_path = sys.argv[4]

# ── Parse the JSONL transcript ────────────────────────────────────────────────

def short(s, n):
    if not s: return ''
    return s if len(s) <= n else s[:n-1] + '…'

def fmt_tokens(n):
    if n is None: return ''
    n = int(n)
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000:     return f"{n/1_000:.1f}K"
    return str(n)

def fmt_ts(iso):
    """HH:MM:SS in local time — displayed inline."""
    if not iso: return ''
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        return dt.astimezone().strftime('%H:%M:%S')
    except Exception:
        return ''

def fmt_ts_full(iso):
    """Full human-readable datetime — used as tooltip on the timestamp."""
    if not iso: return ''
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00')).astimezone()
        return dt.strftime('%a %b %d %Y · %H:%M:%S %Z')
    except Exception:
        return iso

def tool_preview(name, inp):
    """Compact one-line preview of a tool call's most diagnostic input."""
    if not isinstance(inp, dict):
        return ''
    if name == 'Bash':
        return short(inp.get('command', '').replace('\n', ' '), 100)
    if name in ('Read', 'Write'):
        return short(inp.get('file_path', ''), 80)
    if name == 'Edit':
        path = inp.get('file_path', '')
        old  = short(inp.get('old_string', '').replace('\n', '⏎'), 40)
        return f"{short(path, 50)}  ·  {old}"
    if name == 'Grep':
        return f"/{short(inp.get('pattern',''), 40)}/  in {short(inp.get('path',''), 40)}"
    if name == 'Glob':
        return short(inp.get('pattern', ''), 80)
    if name == 'WebFetch':
        return short(inp.get('url', ''), 80)
    if name in ('Task', 'Agent'):
        return short(inp.get('description', '') or inp.get('prompt', ''), 80)
    if name == 'TodoWrite':
        return f"{len(inp.get('todos', []))} item(s)"
    for k, v in inp.items():
        if isinstance(v, str) and v:
            return f"{k}: {short(v, 70)}"
    return ''

def file_paths_in_input(name, inp):
    """Return any file paths found in tool input — for click-to-copy markup."""
    if not isinstance(inp, dict): return []
    paths = []
    for k in ('file_path', 'path'):
        v = inp.get(k)
        if isinstance(v, str) and v:
            paths.append(v)
    return paths

LANG_BY_EXT = {
    'ts': 'typescript', 'tsx': 'typescript',
    'js': 'javascript', 'jsx': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
    'py': 'python', 'go': 'go', 'rs': 'rust', 'swift': 'swift',
    'sh': 'bash', 'bash': 'bash', 'zsh': 'bash',
    'json': 'json', 'md': 'markdown', 'mdx': 'markdown',
    'html': 'html', 'css': 'css', 'scss': 'scss',
    'yml': 'yaml', 'yaml': 'yaml',
    'toml': 'ini', 'ini': 'ini',
    'sql': 'sql', 'rb': 'ruby', 'php': 'php',
    'c': 'c', 'h': 'c', 'cpp': 'cpp', 'cc': 'cpp', 'hpp': 'cpp',
    'java': 'java', 'kt': 'kotlin', 'scala': 'scala',
    'xml': 'xml', 'svg': 'xml', 'lua': 'lua',
    'dart': 'dart', 'r': 'r',
}

def lang_from_path(path):
    """Map a file path to a highlight.js language hint via its extension."""
    if not path or '.' not in path: return ''
    ext = path.rsplit('.', 1)[-1].lower()
    return LANG_BY_EXT.get(ext, '')

messages = []           # list of dicts: {role, content_raw, ts, tokens_in/out, kind}
model = 'unknown'
total_input = 0
total_output = 0
total_cache_read = 0
session_id = ''
ai_title = ''           # auto-generated session title from `type: ai-title`
git_branch = ''         # cwd's git branch as reported on most recent event
permission_mode = ''    # current permission mode (auto / plan / default / ...)
pending_tools = []      # accumulator for consecutive tool-only assistant turns
tool_counter = Counter()
activity_dots = []      # one dot per turn for the timeline ribbon
hook_summaries = 0      # how many `stop_hook_summary` events have run
hook_errors_total = 0   # accumulated hook errors (red badge in header)

def flush_tools():
    global pending_tools
    if not pending_tools:
        return
    n = len(pending_tools)
    summary = f"🔧 {n} tool call{'s' if n != 1 else ''}"
    messages.append({
        'role': 'tools', 'kind': 'tools',
        'ts':      pending_tools[-1].get('ts', ''),
        'ts_full': pending_tools[-1].get('ts_full', ''),
        'tools': pending_tools,
        'summary': summary,
        'tokens_out': sum(t.get('tokens_out', 0) for t in pending_tools),
    })
    pending_tools = []

if jsonl_file and os.path.exists(jsonl_file):
    session_id = os.path.splitext(os.path.basename(jsonl_file))[0]
    size = os.path.getsize(jsonl_file)
    with open(jsonl_file, 'r', errors='replace') as f:
        if size > 1_000_000:
            f.seek(max(0, size - 800_000))
            f.readline()  # skip partial line

        for line in f:
            try:
                obj = json.loads(line.strip())
            except json.JSONDecodeError:
                continue

            msg_type = obj.get('type', '')
            ts_iso = obj.get('timestamp', '')
            ts = fmt_ts(ts_iso)
            ts_full = fmt_ts_full(ts_iso)
            sidechain = bool(obj.get('isSidechain', False))
            if obj.get('gitBranch'): git_branch = obj.get('gitBranch')

            # Lightweight events without a message body — surfaced as inline
            # markers in the stream so users can see the "ambient" things
            # (hooks running, mode toggles, generated titles) that previously
            # were invisible in the transcript view.
            if msg_type == 'ai-title':
                t = obj.get('aiTitle', '')
                if t: ai_title = t
                continue

            if msg_type == 'permission-mode':
                pm = obj.get('permissionMode', '')
                if pm and pm != permission_mode:
                    permission_mode = pm
                    flush_tools()
                    messages.append({
                        'role': 'mode-change', 'kind': 'event', 'ts': ts, 'ts_full': ts_full,
                        'text': f"🔓 permission mode → {pm}",
                        'cls': 'mode',
                    })
                continue

            if msg_type == 'system':
                subtype = obj.get('subtype', '')
                if subtype == 'stop_hook_summary':
                    hc = obj.get('hookCount') or 0
                    he = obj.get('hookErrors') or []
                    pc = obj.get('preventedContinuation') or False
                    if hc or he or pc:
                        hook_summaries += 1
                        hook_errors_total += len(he)
                        err_chunk = (
                            f' · {len(he)} error{"s" if len(he) != 1 else ""}'
                            if he else ''
                        )
                        prev_chunk = ' · prevented continuation' if pc else ''
                        cls = 'err' if (he or pc) else 'hooks'
                        flush_tools()
                        messages.append({
                            'role': 'hook-summary', 'kind': 'event', 'ts': ts, 'ts_full': ts_full,
                            'text': f"⚙ {hc} hook{'s' if hc != 1 else ''} ran{err_chunk}{prev_chunk}",
                            'cls': cls,
                            'errors': he,
                        })
                continue

            if msg_type == 'user':
                flush_tools()
                msg = obj.get('message', {})
                content = ''
                if isinstance(msg, dict):
                    for block in msg.get('content', []):
                        if isinstance(block, dict):
                            if block.get('type') == 'text':
                                content += block.get('text', '')
                        elif isinstance(block, str):
                            content += block
                elif isinstance(msg, str):
                    content = msg
                if content.strip():
                    messages.append({
                        'role': 'user', 'kind': 'user', 'ts': ts, 'ts_full': ts_full,
                        'content_raw': content.strip(),
                        'sidechain': sidechain,
                    })
                    activity_dots.append(('u', ts))

            elif msg_type == 'assistant':
                msg   = obj.get('message', {})
                m     = msg.get('model', '')
                if m: model = m
                usage = msg.get('usage', {})
                total_input      += usage.get('input_tokens', 0)
                total_output     += usage.get('output_tokens', 0)
                total_cache_read += usage.get('cache_read_input_tokens', 0)

                text_part = ''
                tool_calls = []
                for block in msg.get('content', []):
                    if isinstance(block, dict):
                        if block.get('type') == 'text':
                            text_part += block.get('text', '')
                        elif block.get('type') == 'tool_use':
                            tname = block.get('name', '?')
                            tinp  = block.get('input', {})
                            tool_counter[tname] += 1
                            tool_calls.append({
                                'name': tname,
                                'input': tinp,
                                'preview': tool_preview(tname, tinp),
                                'paths': file_paths_in_input(tname, tinp),
                                'ts': ts, 'ts_full': ts_full,
                                'tokens_out': usage.get('output_tokens', 0),
                            })

                if text_part.strip():
                    flush_tools()
                    messages.append({
                        'role': 'assistant', 'kind': 'assistant', 'ts': ts, 'ts_full': ts_full,
                        'content_raw': text_part.strip(),
                        'tokens_in':  usage.get('input_tokens', 0),
                        'tokens_out': usage.get('output_tokens', 0),
                        'sidechain': sidechain,
                    })
                    activity_dots.append(('a', ts))
                    if tool_calls:
                        pending_tools.extend(tool_calls)
                        activity_dots.append(('t', ts))
                else:
                    pending_tools.extend(tool_calls)
                    if tool_calls:
                        activity_dots.append(('t', ts))

flush_tools()

# Trim model name for display.
model_short = model
if 'opus'   in model.lower(): model_short = 'Opus'
elif 'sonnet' in model.lower(): model_short = 'Sonnet'
elif 'haiku'  in model.lower(): model_short = 'Haiku'

# ── Markdown is rendered CLIENT-SIDE via marked.js so we can support full
#    syntax (headings, lists, tables, blockquotes) and highlight.js for code.
#    Raw markdown is embedded in <script type="text/markdown"> tags; the
#    browser doesn't execute these and exposes their content unmolested via
#    .textContent. The only sequence we have to escape is the literal
#    "</script>" (would close the tag mid-content).

def safe_md(text):
    return text.replace('</script>', '<\\/script>')

# ── Tool detail HTML (full input JSON, with click-to-copy paths) ──────────────

def render_tool_detail(t):
    name  = t['name']
    inp   = t['input']
    paths = t['paths']

    # Click-to-copy chips for any file paths found in the input.
    paths_html = ''
    for p in paths:
        ep = html.escape(p)
        paths_html += f'<span class="copyable" data-copy="{ep}" title="Click to copy">{ep}</span>'

    # Special-case Edit: render old_string vs new_string side-by-side, with
    # syntax highlighting hinted by the file extension. hljs.highlightElement
    # is invoked at runtime for any pre>code with language-* class.
    extras_html = ''
    if name == 'Edit' and isinstance(inp, dict):
        old   = inp.get('old_string', '')
        new   = inp.get('new_string', '')
        lang  = lang_from_path(inp.get('file_path', ''))
        lcls  = f' class="language-{lang}"' if lang else ''
        extras_html = (
            '<div class="diff-pair">'
            f'<div class="diff-side"><div class="diff-label">old</div><pre><code{lcls}>{html.escape(old)}</code></pre></div>'
            f'<div class="diff-side"><div class="diff-label">new</div><pre><code{lcls}>{html.escape(new)}</code></pre></div>'
            '</div>'
        )

    # Bash: command + optional description.
    if name == 'Bash' and isinstance(inp, dict):
        cmd = inp.get('command', '')
        desc = inp.get('description', '')
        extras_html = (
            f'<pre class="bash-cmd"><code class="language-bash">{html.escape(cmd)}</code></pre>' +
            (f'<div class="bash-desc">— {html.escape(desc)}</div>' if desc else '')
        )

    # Full input JSON (pretty), collapsed by default.
    pretty = json.dumps(inp, indent=2, ensure_ascii=False) if isinstance(inp, dict) else str(inp)
    full_json_html = (
        f'<details class="tool-json">'
        f'<summary>full input</summary>'
        f'<pre><code class="language-json">{html.escape(pretty)}</code></pre>'
        f'</details>'
    )

    return (
        f'<li class="tool-item">'
        f'  <div class="tool-line">'
        f'    <span class="tool-name">{html.escape(name)}</span>'
        f'    {paths_html if paths_html else ""}'
        f'  </div>'
        f'  {extras_html}'
        f'  {full_json_html}'
        f'</li>'
    )

# ── Build per-message HTML ────────────────────────────────────────────────────

display_messages = messages[-100:]

msg_html = ''
for i, m in enumerate(display_messages):
    role = m['role']
    ts = m.get('ts', '')
    ts_full = m.get('ts_full', '')
    idx = i + 1                     # 1-based index in the displayed list
    idx_html = f'<span class="msg-idx" title="Block #{idx} of {len(display_messages)}">#{idx}</span>'
    # Timestamp shows HH:MM:SS, tooltip shows full human-readable datetime.
    if ts:
        ts_html = f'<span class="ts" title="{html.escape(ts_full) if ts_full else ts}">{ts}</span>'
    else:
        ts_html = ''

    sidechain = m.get('sidechain', False)
    sc_class = ' sidechain' if sidechain else ''
    sc_badge = '<span class="sidechain-badge" title="Subagent (Task tool sidechain)">↳ subagent</span>' if sidechain else ''

    if role == 'user':
        raw = m['content_raw']
        # Collapse <system-reminder> blocks (CLAUDE.md context, hooks, etc.)
        # into an expandable summary so they don't dwarf the actual prompt.
        sysrem_count = raw.count('<system-reminder>')
        sysrem_html = ''
        if sysrem_count > 0:
            sysrem_html = (
                f'<details class="sysrem"><summary>'
                f'ⓘ {sysrem_count} system-reminder block{"s" if sysrem_count != 1 else ""} '
                f'(CLAUDE.md context, hook injections, system-reminder)</summary>'
                f'<pre><code>{html.escape(raw)}</code></pre></details>'
            )
            # Strip them from the visible body so the user prompt is the focus.
            visible = re.sub(r'<system-reminder>.*?</system-reminder>', '', raw, flags=re.DOTALL).strip()
            raw_md = safe_md(visible) if visible else '<i class="dim">(only system-reminder content)</i>'
        else:
            raw_md = safe_md(raw)
        body = (
            f'<div class="content" data-md><script type="text/markdown">{raw_md}</script></div>'
            if not raw_md.startswith('<i') else
            f'<div class="content">{raw_md}</div>'
        )
        msg_html += (
            f'<div id="msg-{idx}" class="msg user{sc_class}" data-idx="{idx}" data-role="user" data-search="{html.escape(raw.lower())}">'
            f'  <div class="role"><span class="role-icon">👤</span><span>You</span>{sc_badge}{idx_html}{ts_html}</div>'
            f'  {body}{sysrem_html}'
            f'</div>\n'
        )
    elif role == 'assistant':
        raw = safe_md(m['content_raw'])
        tok_in  = fmt_tokens(m.get('tokens_in'))
        tok_out = fmt_tokens(m.get('tokens_out'))
        badge = ''
        if tok_out:
            badge = f'<span class="tok-badge">↑{tok_out}</span>'
            if tok_in:
                badge += f'<span class="tok-badge dim">↓{tok_in}</span>'
        msg_html += (
            f'<div id="msg-{idx}" class="msg assistant{sc_class}" data-idx="{idx}" data-role="assistant" data-search="{html.escape(m["content_raw"].lower())}">'
            f'  <div class="role"><span class="role-icon">✨</span><span>Claude ({model_short})</span>{sc_badge}{badge}{idx_html}{ts_html}</div>'
            f'  <div class="content" data-md><script type="text/markdown">{raw}</script></div>'
            f'</div>\n'
        )
    elif role == 'tools':
        tools_html = ''.join(render_tool_detail(t) for t in m['tools'])
        msg_html += (
            f'<div id="msg-{idx}" class="msg tools" data-idx="{idx}" data-role="tools" data-search="">'
            f'  <div class="role"><span class="role-icon">🔧</span><span class="dim">tools</span>{idx_html}{ts_html}</div>'
            f'  <div class="content">'
            f'    <details open>'
            f'      <summary>{m["summary"]}</summary>'
            f'      <ul class="tool-list">{tools_html}</ul>'
            f'    </details>'
            f'  </div>'
            f'</div>\n'
        )
    elif m.get('kind') == 'event':
        # Inline event row — hooks, mode changes, future event types.
        cls = m.get('cls', 'event')
        text = html.escape(m.get('text', ''))
        errors_html = ''
        if m.get('errors'):
            err_lines = '\n'.join(json.dumps(e) if not isinstance(e, str) else e for e in m['errors'])
            errors_html = (
                f'<details class="event-err"><summary>view errors</summary>'
                f'<pre><code>{html.escape(err_lines)}</code></pre></details>'
            )
        msg_html += (
            f'<div id="msg-{idx}" class="msg event event-{cls}" data-idx="{idx}" data-role="event" data-search="{text.lower()}">'
            f'  <div class="event-line">{text}{ts_html}</div>'
            f'  {errors_html}'
            f'</div>\n'
        )

# ── Tools-used breakdown ──────────────────────────────────────────────────────

tools_breakdown_html = ''
if tool_counter:
    total_tools = sum(tool_counter.values())
    rows = ''
    for name, count in tool_counter.most_common():
        pct = (count / total_tools) * 100
        rows += (
            f'<div class="tb-row">'
            f'  <span class="tb-name">{html.escape(name)}</span>'
            f'  <span class="tb-bar"><span class="tb-fill" style="width:{pct:.1f}%"></span></span>'
            f'  <span class="tb-count">{count}</span>'
            f'</div>'
        )
    tools_breakdown_html = f'<div class="tools-breakdown"><div class="section-title">Tools used ({total_tools})</div>{rows}</div>'

# ── Activity timeline ─────────────────────────────────────────────────────────
#
# Derived from display_messages so every dot's index matches a real msg-N id;
# the dot becomes a clickable button that scrolls to its message and briefly
# flashes a ring around it. Tooltip shows index + role + timestamp.

ROLE_TO_KIND = {
    'user': 'u', 'assistant': 'a', 'tools': 't',
    'mode-change': 'm', 'hook-summary': 'h',
}
KIND_TO_LABEL = {
    'u': 'You', 'a': 'Claude', 't': 'tools',
    'm': 'mode change', 'h': 'hooks', 'e': 'event',
}

timeline_html = ''
if display_messages:
    dot_html = ''
    for i, m in enumerate(display_messages):
        idx = i + 1
        kind = ROLE_TO_KIND.get(m['role'], 'e')
        label = KIND_TO_LABEL.get(kind, 'event')
        title_parts = [f'#{idx}', label]
        if m.get('ts'): title_parts.append(m.get('ts_full') or m['ts'])
        title = html.escape(' · '.join(title_parts))
        dot_html += (
            f'<button type="button" class="dot dot-{kind}" '
            f'data-target="msg-{idx}" title="{title}" '
            f'aria-label="Jump to {title}"></button>'
        )
    legend_items = (
        '<span><span class="dot dot-u"></span>You</span>'
        '<span><span class="dot dot-a"></span>Claude</span>'
        '<span><span class="dot dot-t"></span>Tools</span>'
        '<span><span class="dot dot-h"></span>Hooks</span>'
        '<span><span class="dot dot-m"></span>Mode</span>'
    )
    timeline_html = (
        '<div class="timeline">'
        f'<div class="section-title">━━ activity ({len(display_messages)} blocks) — click a dot to jump ━━</div>'
        f'<div class="dots">{dot_html}</div>'
        f'<div class="legend">{legend_items}</div>'
        '</div>'
    )

# ── Statusline metrics bar ────────────────────────────────────────────────────

sl_html = ''
if statusline:
    cpu  = statusline.get('proc_cpu', '0')
    mem  = statusline.get('proc_mem', '0')
    rss  = statusline.get('proc_rss', '0')
    mcp_h = statusline.get('mcp_healthy', '')
    mcp_d = statusline.get('mcp_down', '')
    ctx_r = statusline.get('ctx_remaining', '')
    cwd_now = statusline.get('cwd', '')
    ctx_chunk = ''
    if ctx_r and ctx_r != '0':
        ctx_int = int(ctx_r) if ctx_r.isdigit() else 0
        ctx_cls = 'err' if ctx_int < 30 else ('warn' if ctx_int < 60 else 'ok')
        ctx_chunk = f'<span class="metric"><b>CTX</b> <span class="{ctx_cls}">{ctx_r}%</span></span>'
    cwd_chunk = ''
    if cwd_now:
        ec = html.escape(cwd_now)
        cwd_chunk = f'<span class="metric"><b>CWD</b> <span class="copyable" data-copy="{ec}" title="Click to copy">{ec}</span></span>'
    sl_html = f'''
    <div class="metrics-bar">
        {ctx_chunk}
        <span class="metric"><b>CPU</b> {cpu}%</span>
        <span class="metric"><b>MEM</b> {mem}% ({rss}MB)</span>
        <span class="metric"><b>MCP</b> {mcp_h or "none"}</span>
        {f'<span class="metric warn"><b>DOWN</b> {mcp_d}</span>' if mcp_d else ''}
        {cwd_chunk}
    </div>'''

now = datetime.now(timezone.utc).strftime('%H:%M:%S UTC')

page_html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<!-- Auto-refresh removed: reload + CDN reparse + marked/hljs re-render every 5s
     caused a visible flicker. The background daemon refreshes the file on disk
     every 5 minutes; click ↻ Refresh (or ⌘R / F5) to pull in fresh content.
     Live-mode (background regen + JS DOM patch) is parked for follow-up. -->

<!-- Favicon + descriptive metadata. Favicon is the Anthropic Claude mark
     (externally linked — survives without local assets). theme-color makes
     the browser chrome match dark/light mode on platforms that honor it. -->
<link rel="icon" type="image/x-icon" href="https://claude.ai/favicon.ico">
<link rel="apple-touch-icon" href="https://claude.ai/apple-touch-icon.png">
<meta name="description" content="Claude transcript — {model_short} · PID {pid} · session {session_id[:8]}">
<meta name="theme-color" content="#0d1117" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#f6f8fa" media="(prefers-color-scheme: light)">
<meta name="generator" content="claude-instances/lib/detail.sh">
<meta name="claude-pid" content="{pid}">
<meta name="claude-session-id" content="{session_id}">
<meta name="claude-model" content="{model_short}">
<meta property="og:title" content="Claude {model_short} · {session_id[:12]}">
<meta property="og:description" content="Live transcript — {len(messages)} turns, {fmt_tokens(total_output)} output tokens">
<meta property="og:type" content="website">
<title>Claude — {model_short} · PID {pid}</title>

<!-- Restore theme BEFORE first paint to avoid the flash on every 5s reload. -->
<script>
(function() {{
    try {{
        var t = localStorage.getItem('claude-detail-theme');
        if (t === 'light') document.documentElement.classList.add('light');
    }} catch (e) {{}}
}})();
</script>

<!-- highlight.js — theme matched to current mode by JS at the bottom. -->
<link id="hljs-dark" rel="stylesheet"
      href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github-dark.min.css">
<link id="hljs-light" rel="stylesheet" disabled
      href="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/styles/github.min.css">

<style>
:root {{
    --bg: #0d1117; --surface: #161b22; --surface2: #1c2333;
    --text: #e6edf3; --dim: #7d8590; --accent: #58a6ff;
    --accent2: #3fb950; --warn: #d29922; --err: #f85149;
    --border: #30363d; --user-bg: #1a2332; --asst-bg: #161b22;
    --tools-bg: #1a1f2a;
}}
:root.light {{
    --bg: #f6f8fa; --surface: #fff; --surface2: #f0f3f6;
    --text: #1f2328; --dim: #656d76; --accent: #0969da;
    --accent2: #1a7f37; --warn: #9a6700; --err: #cf222e;
    --border: #d0d7de; --user-bg: #ddf4ff; --asst-bg: #fff;
    --tools-bg: #f0f3f6;
}}
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ height: 100%; }}
body {{
    font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI Variable",
                 "Segoe UI", "Helvetica Neue", system-ui, sans-serif;
    background: var(--bg); color: var(--text); font-size: 14px;
    text-rendering: optimizeLegibility;
    font-feature-settings: "kern", "liga", "calt";
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
}}
.theme-toggle {{
    position: fixed; top: 12px; right: 16px; z-index: 100;
    background: var(--surface); border: 1px solid var(--border); color: var(--text);
    border-radius: 6px; padding: 6px 12px; cursor: pointer; font-size: 14px;
}}

.header {{ padding: 18px 24px 12px; border-bottom: 1px solid var(--border); }}
.header h1 {{ font-size: 17px; margin-bottom: 4px; font-weight: 600; }}
.header .meta {{
    color: var(--dim); font-size: 12px;
    display: flex; flex-wrap: wrap; gap: 6px; align-items: center;
}}
.header .meta code {{ background: transparent; padding: 0; font-size: 11px; }}
.hpill {{
    background: var(--surface2); border: 1px solid var(--border);
    padding: 2px 8px; border-radius: 999px; font-size: 11px;
    font-family: ui-monospace, Menlo, monospace; color: var(--text);
    display: inline-flex; align-items: center; gap: 4px;
}}
.hpill.warn-pill {{ background: rgba(248, 81, 73, 0.12); color: var(--err); border-color: var(--err); }}
.hpill.dim-pill  {{ background: transparent; border: none; color: var(--dim); padding-left: 0; }}

.stats {{
    display: flex; gap: 24px; padding: 14px 24px; flex-wrap: wrap;
    border-bottom: 1px solid var(--border); background: var(--surface);
}}
.stat {{ text-align: center; }}
.stat .value {{ font-size: 20px; font-weight: 700; color: var(--accent); }}
.stat .label {{ font-size: 11px; color: var(--dim); }}

.metrics-bar {{
    display: flex; gap: 16px; padding: 8px 24px; font-size: 12px;
    font-family: ui-monospace, Menlo, monospace;
    border-bottom: 1px solid var(--border); color: var(--dim); flex-wrap: wrap;
}}
.metric b {{ color: var(--text); font-weight: 600; }}
.metric .ok   {{ color: var(--accent2); }}
.metric .warn {{ color: var(--warn); }}
.metric .err  {{ color: var(--err); }}
.metric.warn  {{ color: var(--err); }}

.section-title {{
    font-size: 11px; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.06em; color: var(--dim); margin-bottom: 6px;
}}

.tools-breakdown {{ padding: 12px 24px; border-bottom: 1px solid var(--border); }}
.tb-row {{
    display: grid; grid-template-columns: 110px 1fr 50px;
    align-items: center; gap: 10px; margin-bottom: 4px;
    font-family: ui-monospace, monospace; font-size: 12px;
}}
.tb-name  {{ color: var(--accent); font-weight: 600; }}
.tb-bar   {{ background: var(--surface2); border-radius: 3px; height: 8px; overflow: hidden; }}
.tb-fill  {{ display: block; background: var(--accent); height: 100%; }}
.tb-count {{ color: var(--text); text-align: right; }}

.timeline {{ padding: 14px 24px; border-bottom: 1px solid var(--border); }}
.timeline .section-title {{
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    color: var(--dim); margin-bottom: 8px;
    text-transform: none; letter-spacing: 0;
}}
.timeline .dots {{
    display: flex; flex-wrap: wrap;
    gap: 4px; padding: 4px 0;
    align-items: center;
}}
button.dot {{
    /* Each dot grows to fill row width, capped so they don't become
       grotesque on short transcripts. */
    flex: 1 1 8px;
    min-width: 6px;
    max-width: 22px;
    height: 14px;
    border-radius: 2px;
    border: 1px solid transparent;
    padding: 0; margin: 0;
    cursor: pointer;
    transition: transform 0.1s ease, box-shadow 0.1s ease, filter 0.1s ease;
}}
button.dot:hover {{
    transform: scaleY(1.3);
    filter: brightness(1.2);
    box-shadow: 0 0 0 2px var(--surface),
                0 0 0 3px currentColor;
    z-index: 5;
}}
button.dot:focus-visible {{
    outline: 2px solid var(--accent);
    outline-offset: 2px;
}}
.dot {{ /* legend swatches (non-button) */ display: inline-block; vertical-align: middle; }}
.legend .dot {{ width: 10px; height: 10px; border-radius: 2px; flex: none; }}
.dot-u {{ background: var(--accent);  color: var(--accent); }}
.dot-a {{ background: var(--accent2); color: var(--accent2); }}
.dot-t {{ background: var(--warn);    color: var(--warn); }}
.dot-h {{ background: #a78bfa;        color: #a78bfa; }}     /* hooks: violet */
.dot-m {{ background: var(--err);     color: var(--err); }}  /* mode: red */
.dot-e {{ background: var(--dim);     color: var(--dim); }}
.legend {{
    display: flex; flex-wrap: wrap; gap: 16px; margin-top: 8px;
    font-size: 11px; color: var(--dim);
    font-family: ui-monospace, monospace;
}}
.legend span {{ display: inline-flex; align-items: center; gap: 6px; }}

/* Flash a card briefly when scrolled to from the activity bar. */
.msg.flash {{
    animation: flash-ring 1.2s ease-out;
}}
@keyframes flash-ring {{
    0%   {{ box-shadow: 0 0 0 0   var(--accent); }}
    20%  {{ box-shadow: 0 0 0 4px var(--accent); }}
    100% {{ box-shadow: 0 0 0 0   transparent; }}
}}

/* Numbered block index next to the timestamp — terminal-style mono. */
.msg-idx {{
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 10px; color: var(--dim);
    background: var(--surface2);
    border: 1px solid var(--border);
    padding: 1px 6px; border-radius: 3px;
    margin-left: auto;
    letter-spacing: 0.02em;
}}
.msg-idx + .ts {{ margin-left: 6px; }}
.role .ts {{ margin-left: 0; }}  /* override: idx now takes auto-margin */

.toolbar {{
    position: sticky; top: 0; z-index: 50;
    display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
    padding: 10px 24px; background: var(--surface);
    border-bottom: 1px solid var(--border);
}}
.toolbar input[type=search] {{
    flex: 1; min-width: 180px; max-width: 380px;
    background: var(--bg); border: 1px solid var(--border); color: var(--text);
    border-radius: 6px; padding: 6px 10px; font-size: 13px; font-family: inherit;
}}
.toolbar input[type=search]:focus {{ outline: 1px solid var(--accent); border-color: var(--accent); }}
.chip {{
    display: inline-flex; align-items: center; gap: 4px;
    padding: 4px 10px; border-radius: 999px; font-size: 12px;
    background: var(--surface2); color: var(--text); cursor: pointer;
    border: 1px solid var(--border); user-select: none;
}}
.chip[aria-pressed="false"] {{ opacity: 0.45; }}
.chip:hover {{ border-color: var(--accent); }}
.toolbar .count {{ color: var(--dim); font-size: 12px; margin-left: auto; font-family: ui-monospace, monospace; }}
.toolbar .refresh-btn {{ background: var(--surface); }}
.toolbar .refresh-btn:active {{ transform: translateY(1px); }}
.toolbar .live-tag {{
    display: inline-flex; align-items: center; gap: 6px;
    font-size: 11px; color: var(--dim); font-family: ui-monospace, monospace;
}}
.toolbar .live-dot {{
    width: 8px; height: 8px; border-radius: 50%; background: var(--accent2);
    box-shadow: 0 0 0 0 rgba(63, 185, 80, 0.6);
    animation: live-pulse 2s ease-out infinite;
}}
@keyframes live-pulse {{
    0%   {{ box-shadow: 0 0 0 0 rgba(63, 185, 80, 0.6); }}
    70%  {{ box-shadow: 0 0 0 6px rgba(63, 185, 80, 0); }}
    100% {{ box-shadow: 0 0 0 0 rgba(63, 185, 80, 0); }}
}}

.messages {{ padding: 16px 24px 80px; max-width: 1100px; margin: 0 auto; }}
.msg {{
    padding: 10px 14px; margin-bottom: 10px;
    border-radius: 4px;                /* boxier — closer to terminal pane feel */
    border-left: 3px solid var(--border);
}}
.msg.user      {{ background: var(--user-bg);  border-left-color: var(--accent); }}
.msg.assistant {{ background: var(--asst-bg);  border-left-color: var(--accent2); }}
.msg.tools     {{ background: var(--tools-bg); border-left-color: var(--warn); }}
.msg.hidden    {{ display: none; }}

/* Sidechain (Task subagent) — visually offset so they don't read as the
   main conversation thread. */
.msg.sidechain {{
    margin-left: 32px;
    border-left-style: dashed;
    opacity: 0.92;
}}
.sidechain-badge {{
    background: rgba(168, 85, 247, 0.18); color: #c084fc;
    padding: 1px 7px; border-radius: 999px;
    font-size: 10px; font-weight: 600;
    font-family: ui-monospace, monospace;
}}

/* Role icon — small leading glyph that gives quick visual differentiation
   without relying on color alone (especially in light mode where bg colors
   are subtle). */
.role-icon {{
    display: inline-block; width: 18px; text-align: center;
    font-size: 12px; opacity: 0.85;
}}

/* Inline event rows — hooks, permission-mode changes, etc. Don't read as
   conversation; sit between turns as ambient signals. Smaller, mono, no
   bubble background. */
.msg.event {{
    background: transparent;
    border: none; border-left: 2px dashed var(--border);
    padding: 4px 14px; margin: 2px 0 2px 4px;
}}
.msg.event .event-line {{
    display: flex; align-items: center; gap: 10px;
    font-family: ui-monospace, Menlo, monospace; font-size: 11px;
    color: var(--dim);
}}
.msg.event-hooks .event-line {{ color: var(--accent2); }}
.msg.event-err   .event-line {{ color: var(--err); }}
.msg.event-mode  .event-line {{ color: var(--warn); }}
.msg.event .event-line .ts {{ margin-left: auto; }}
.msg.event .event-err {{ margin-top: 2px; padding-left: 24px; }}

/* CLAUDE.md / system-reminder collapse — keeps user prompt readable. */
details.sysrem {{
    margin-top: 8px; font-size: 11px; color: var(--dim);
    border-top: 1px solid var(--border); padding-top: 6px;
}}
details.sysrem summary {{ cursor: pointer; font-family: ui-monospace, monospace; }}
details.sysrem pre {{ margin-top: 4px; max-height: 360px; overflow: auto; }}

/* Long-message handling — cap height with fade-out + "show more" toggle.
   Without this a single 5000-char assistant turn can dominate the viewport. */
.msg .content {{ max-height: 720px; overflow: hidden; position: relative; }}
.msg.expanded .content {{ max-height: none; }}
.msg .content::after {{
    content: ''; position: absolute; bottom: 0; left: 0; right: 0; height: 60px;
    background: linear-gradient(to bottom, transparent, var(--asst-bg));
    pointer-events: none; opacity: 0; transition: opacity 0.15s;
}}
.msg.user .content::after {{ background: linear-gradient(to bottom, transparent, var(--user-bg)); }}
.msg.tools .content::after, .msg.event .content::after {{ display: none; }}
.msg.overflow .content::after {{ opacity: 1; }}
.msg.expanded .content::after {{ display: none; }}
.show-more-btn {{
    display: none; margin-top: 6px; background: var(--surface2);
    border: 1px solid var(--border); color: var(--text);
    border-radius: 6px; padding: 4px 12px; font-size: 11px; cursor: pointer;
}}
.msg.overflow .show-more-btn {{ display: inline-block; }}

/* Flow arrows between consecutive cards. Subtle dashed line on either side
   of a small circular badge containing the next speaker's icon, color-tinted
   per role. Border color hints at what kind of card comes next so you can
   skim the conversation rhythm at a glance. */
.flow-arrow {{
    display: flex; align-items: center; gap: 10px;
    padding: 2px 24px; margin: 1px 0;
}}
.arrow-line {{
    flex: 1; height: 0;
    border-top: 1px dashed var(--border);
}}
.arrow-icon {{
    flex: 0 0 auto;
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 50%;
    width: 22px; height: 22px;
    display: inline-flex; align-items: center; justify-content: center;
    font-size: 11px;
    line-height: 1;
}}
.flow-user      .arrow-icon {{ border-color: var(--accent);  background: rgba(88, 166, 255, 0.10); }}
.flow-assistant .arrow-icon {{ border-color: var(--accent2); background: rgba(63, 185, 80, 0.10); }}
.flow-tools     .arrow-icon {{ border-color: var(--warn);    background: rgba(210, 153, 34, 0.10); }}
.flow-event     .arrow-icon {{ border-color: var(--border);  background: var(--surface2); opacity: 0.7; }}
/* Hide arrows that ended up adjacent to a hidden msg (filter race) */
.flow-arrow + .msg.hidden + .flow-arrow {{ display: none; }}

.role {{
    display: flex; align-items: center; gap: 8px;
    font-size: 12px; font-weight: 600; color: var(--dim);
    margin-bottom: 6px;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    letter-spacing: 0.01em;
}}
/* Prompt-style label color per role — terminal-prompt feel. */
.msg.user      > .role > span:nth-of-type(2) {{ color: var(--accent); }}
.msg.assistant > .role > span:nth-of-type(2) {{ color: var(--accent2); }}
.msg.tools     > .role > span:nth-of-type(2) {{ color: var(--warn); }}
.role .ts {{ font-family: ui-monospace, monospace; font-size: 11px; color: var(--dim); }}
.role .dim {{ color: var(--dim); font-weight: 500; }}
.tok-badge {{
    background: var(--surface2); padding: 1px 7px; border-radius: 999px;
    font-size: 11px; font-family: ui-monospace, monospace; color: var(--text);
}}
.tok-badge.dim {{ color: var(--dim); }}

/* Markdown content. Sized for readable prose: 14.5px / 1.65 lh. Code blocks
   stay slightly smaller (mono fonts compensate). Headings get more breathing
   room than the previous tight rhythm. */
.content {{
    font-size: 14.5px; line-height: 1.65; word-break: break-word;
    color: var(--text);
}}
.content h1, .content h2, .content h3, .content h4 {{
    font-weight: 700; line-height: 1.3;
    margin: 18px 0 8px;
    letter-spacing: -0.01em;
}}
.content h1 {{ font-size: 20px; }}
.content h2 {{
    font-size: 17px; padding-bottom: 5px;
    border-bottom: 1px solid var(--border);
}}
.content h3 {{ font-size: 15px; }}
.content h4 {{ font-size: 14px; color: var(--dim); text-transform: none; }}
.content > *:first-child {{ margin-top: 0; }}
.content p  {{ margin: 10px 0; }}
.content ul, .content ol {{ margin: 10px 0 10px 24px; padding-left: 4px; }}
.content li {{ margin: 4px 0; }}
.content li > p {{ margin: 4px 0; }}
.content li::marker {{ color: var(--dim); }}
.content blockquote {{
    border-left: 3px solid var(--accent); padding: 6px 14px;
    color: var(--dim); margin: 12px 0;
    background: var(--surface2);
    border-radius: 0 4px 4px 0;
}}
.content blockquote p {{ margin: 4px 0; }}
.content table {{
    border-collapse: collapse; margin: 12px 0; font-size: 13px;
    width: 100%; max-width: max-content;
}}
.content th, .content td {{
    border: 1px solid var(--border); padding: 6px 10px; text-align: left;
    vertical-align: top;
}}
.content th {{ background: var(--surface2); font-weight: 600; }}
.content tr:nth-child(even) td {{ background: rgba(127,127,127,0.04); }}
.content code:not(pre code) {{
    background: var(--surface2); padding: 1px 6px; border-radius: 3px;
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    font-size: 0.88em; font-feature-settings: "calt" 0;
}}
.content pre {{
    background: var(--surface2); padding: 10px 12px; border-radius: 6px;
    overflow-x: auto; margin: 8px 0; border: 1px solid var(--border);
    position: relative;
}}
.content pre .code-copy {{
    position: absolute; top: 6px; right: 6px;
    background: var(--surface); border: 1px solid var(--border); color: var(--dim);
    border-radius: 4px; padding: 1px 8px; font-size: 10px; cursor: pointer;
    font-family: ui-monospace, monospace; opacity: 0; transition: opacity 0.15s;
}}
.content pre:hover .code-copy {{ opacity: 1; }}
.content pre .code-copy:hover {{ color: var(--text); border-color: var(--accent); }}
.content pre code {{
    background: transparent; padding: 0;
    font-size: 12.5px; line-height: 1.55;
    font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace;
    font-feature-settings: "calt" 0;
}}
.content a {{ color: var(--accent); text-decoration: none; }}
.content a:hover {{ text-decoration: underline; }}
.content hr {{ border: none; border-top: 1px solid var(--border); margin: 12px 0; }}

/* Tool list items */
.tool-list {{ list-style: none; padding-left: 0; margin-top: 6px; }}
.tool-item {{
    padding: 6px 8px; margin: 4px 0; border-radius: 5px;
    background: var(--surface); border: 1px solid var(--border);
}}
.tool-line {{
    display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px;
    font-family: ui-monospace, Menlo, monospace; font-size: 12px;
}}
.tool-name {{ color: var(--accent); font-weight: 600; }}
.tool-prev {{ color: var(--dim); }}
.tool-json {{ margin-top: 4px; }}
.tool-json summary {{ font-size: 11px; color: var(--dim); cursor: pointer; }}
.tool-json[open] summary {{ color: var(--text); }}
.tool-json pre {{
    margin-top: 4px; max-height: 240px; overflow: auto;
    font-size: 11px; line-height: 1.4;
}}
.bash-cmd {{ margin: 6px 0 4px !important; }}
.bash-desc {{ color: var(--dim); font-size: 12px; padding: 2px 4px; }}

/* Edit diff side-by-side. min-width:0 forces grid columns to respect the
   1fr 1fr split — without it, a <pre> with long lines balloons its column
   and crops the other side. Both axes scroll inside the pre. */
.diff-pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 6px 0; }}
.diff-side {{ min-width: 0; }}
.diff-label {{
    font-size: 10px; font-weight: 700; text-transform: uppercase;
    color: var(--dim); padding: 2px 4px;
}}
.diff-side pre {{
    max-height: 360px; overflow: auto;
    font-size: 11px; line-height: 1.5;
    white-space: pre;  /* prevent wrap so horizontal scroll works */
    border-left-width: 3px; border-left-style: solid;
}}
/* Tint each pane to telegraph removed-vs-added without doing full line-diff
   (which would compete with hljs syntax coloring). Subtle: 6% bg + colored
   border on the left edge. */
.diff-side:nth-child(1) pre {{ border-left-color: var(--err);     background: rgba(248,  81,  73, 0.06); }}
.diff-side:nth-child(2) pre {{ border-left-color: var(--accent2); background: rgba( 63, 185,  80, 0.06); }}
.diff-side:nth-child(1) .diff-label {{ color: var(--err); }}
.diff-side:nth-child(2) .diff-label {{ color: var(--accent2); }}

details summary {{ cursor: pointer; font-size: 12px; color: var(--text); }}

/* Click-to-copy chips: underline-on-hover (no fill — the previous "fill the
   chip with the accent color" was visually too loud, especially around long
   file paths). Tooltip + flash on copy preserved. */
.copyable {{
    cursor: pointer; padding: 0 1px; border-radius: 2px;
    text-decoration: underline transparent;
    text-decoration-thickness: 1px; text-underline-offset: 2px;
    transition: text-decoration-color 0.12s;
    display: inline-flex; align-items: center; gap: 4px;
    position: relative;
}}
.copyable:hover {{ text-decoration-color: var(--accent); }}
.copyable::after {{
    content: 'Copy'; position: absolute;
    bottom: calc(100% + 4px); left: 50%; transform: translateX(-50%);
    background: var(--text); color: var(--bg);
    padding: 2px 8px; border-radius: 4px;
    font-size: 10px; font-family: -apple-system, system-ui, sans-serif;
    font-weight: 600; opacity: 0; pointer-events: none;
    white-space: nowrap; transition: opacity 0.15s;
    z-index: 200;
}}
.copyable:hover::after {{ opacity: 0.95; }}
.copyable.copied {{
    text-decoration-color: var(--accent2);
}}
.copyable.copied::after {{ content: '✓ Copied'; opacity: 1; background: var(--accent2); color: white; }}

.empty {{ color: var(--dim); text-align: center; padding: 60px; font-style: italic; }}
</style>
</head>
<body>
<button class="theme-toggle" id="themeToggle" title="Toggle light/dark">☀ / ☾</button>

<div class="header">
    <h1>{html.escape(ai_title) if ai_title else f"Claude {model_short}"}</h1>
    <div class="meta">
        <span class="hpill">{model_short}</span>
        <span class="hpill">PID {pid}</span>
        <span class="hpill">Session <code class="copyable" data-copy="{session_id}" title="Click to copy">{session_id[:12]}{'…' if len(session_id) > 12 else ''}</code></span>
        {f'<span class="hpill">⎇ {html.escape(git_branch)}</span>' if git_branch else ''}
        {f'<span class="hpill">🔓 {html.escape(permission_mode)}</span>' if permission_mode else ''}
        {f'<span class="hpill warn-pill">⚠ {hook_errors_total} hook error{"s" if hook_errors_total != 1 else ""}</span>' if hook_errors_total else ''}
        <span class="hpill dim-pill">refresh {now}</span>
    </div>
</div>

<div class="stats">
    <div class="stat"><div class="value">{fmt_tokens(total_input)}</div><div class="label">Input</div></div>
    <div class="stat"><div class="value">{fmt_tokens(total_output)}</div><div class="label">Output</div></div>
    <div class="stat"><div class="value">{fmt_tokens(total_cache_read)}</div><div class="label">Cache Read</div></div>
    <div class="stat"><div class="value">{len(messages)}</div><div class="label">Turns</div></div>
</div>
{sl_html}
{tools_breakdown_html}
{timeline_html}

<div class="toolbar">
    <input type="search" id="q" placeholder="Search messages…" autocomplete="off">
    <button class="chip" data-filter="user"      aria-pressed="true">You</button>
    <button class="chip" data-filter="assistant" aria-pressed="true">Claude</button>
    <button class="chip" data-filter="tools"     aria-pressed="true">Tools</button>
    <button class="chip refresh-btn" id="refreshBtn"
            title="Reload page — file regenerates every 5 minutes in the background">↻ Refresh</button>
    <span class="live-tag" title="Background regenerator runs every 5 minutes — click ↻ for fresh content sooner">
        <span class="live-dot"></span>
        <span class="live-label">5m</span>
    </span>
    <span class="count" id="count"></span>
</div>

<div class="messages" id="msgs">
    {msg_html if msg_html else '<div class="empty">No messages found</div>'}
</div>

<!-- Markdown + syntax highlighting via CDN. ~60KB total, gzipped. -->
<script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
<script src="https://cdn.jsdelivr.net/gh/highlightjs/cdn-release@11.9.0/build/highlight.min.js"></script>

<script>
// ── Theme ─────────────────────────────────────────────────────────────────────
function applyHljsTheme() {{
    const isLight = document.documentElement.classList.contains('light');
    document.getElementById('hljs-dark').disabled  = isLight;
    document.getElementById('hljs-light').disabled = !isLight;
}}
applyHljsTheme();

document.getElementById('themeToggle').addEventListener('click', () => {{
    const isLight = document.documentElement.classList.toggle('light');
    try {{ localStorage.setItem('claude-detail-theme', isLight ? 'light' : 'dark'); }} catch (e) {{}}
    applyHljsTheme();
}});

// Manual refresh — file is being regenerated every 5s by the background
// daemon spawned in detail.sh, so location.reload() pulls in fresh content.
document.getElementById('refreshBtn').addEventListener('click', () => {{
    location.reload();
}});

// ── Markdown rendering (marked + hljs) ────────────────────────────────────────
if (window.marked) {{
    marked.setOptions({{
        gfm: true, breaks: false,
        highlight: (code, lang) => {{
            try {{
                if (lang && hljs.getLanguage(lang)) return hljs.highlight(code, {{ language: lang }}).value;
                return hljs.highlightAuto(code).value;
            }} catch (e) {{ return code; }}
        }}
    }});
    document.querySelectorAll('.content[data-md]').forEach(el => {{
        const sc = el.querySelector('script[type="text/markdown"]');
        if (!sc) return;
        const md = sc.textContent;
        el.innerHTML = marked.parse(md);
        // Tag any orphan <pre><code> for hljs (in case marked highlight= didn't fire)
        el.querySelectorAll('pre code').forEach(b => {{
            if (!b.classList.contains('hljs')) hljs.highlightElement(b);
        }});
        // Auto-link bare URLs in text nodes. marked@12 with gfm only handles
        // <bracketed> form; anything pasted plain stays plain. We walk text
        // nodes, skipping anything inside code/pre/a, and split on URL matches.
        autolinkTextNodes(el);
    }});
}}

// Walk every text descendant of `root`, replacing bare URLs with <a> nodes.
// Skips anything inside <code>, <pre>, or already-anchored <a> to avoid
// double-linking and to preserve syntax-highlighted code.
function autolinkTextNodes(root) {{
    const URL_RE = /https?:\/\/[^\s<>"'`]+[^\s<>"'`.,;!?:)\]]/g;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {{
        acceptNode(n) {{
            for (let p = n.parentElement; p && p !== root; p = p.parentElement) {{
                const tag = p.tagName;
                if (tag === 'CODE' || tag === 'PRE' || tag === 'A') {{
                    return NodeFilter.FILTER_REJECT;
                }}
            }}
            return URL_RE.test(n.nodeValue) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
        }}
    }});
    const targets = [];
    let n; while (n = walker.nextNode()) targets.push(n);
    for (const node of targets) {{
        const text = node.nodeValue;
        const frag = document.createDocumentFragment();
        let lastIndex = 0;
        URL_RE.lastIndex = 0;  // reset because we used .test() above
        let m;
        while ((m = URL_RE.exec(text)) !== null) {{
            if (m.index > lastIndex) {{
                frag.appendChild(document.createTextNode(text.slice(lastIndex, m.index)));
            }}
            const a = document.createElement('a');
            a.href = m[0]; a.target = '_blank'; a.rel = 'noopener noreferrer';
            a.textContent = m[0];
            frag.appendChild(a);
            lastIndex = URL_RE.lastIndex;
        }}
        if (lastIndex < text.length) {{
            frag.appendChild(document.createTextNode(text.slice(lastIndex)));
        }}
        if (frag.childNodes.length > 0) {{
            node.parentNode.replaceChild(frag, node);
        }}
    }}
}}

// Highlight any pre>code with a language-* class that didn't go through marked
// (tool-detail JSON, bash, and now Edit-diff old/new panes).
document.querySelectorAll('pre code[class*="language-"]').forEach(b => {{
    if (b.classList.contains('hljs')) return;
    try {{ hljs.highlightElement(b); }} catch (e) {{}}
}});

// ── Click-to-copy ────────────────────────────────────────────────────────────
document.addEventListener('click', e => {{
    const el = e.target.closest('[data-copy]');
    if (!el) return;
    const text = el.dataset.copy || el.textContent;
    navigator.clipboard.writeText(text).then(() => {{
        el.classList.add('copied');
        setTimeout(() => el.classList.remove('copied'), 1200);
    }}).catch(() => {{}});
}});

// ── Flow arrows between visible messages ────────────────────────────────────
// Defined BEFORE applyFilter so the initial render doesn't hit a temporal
// dead zone on FLOW_ICONS. (Earlier this block lived after applyFilter() and
// the const-TDZ inside rebuildFlowArrows halted the entire script.)
const FLOW_ICONS = {{
    user: '👤', assistant: '✨', tools: '🔧', event: 'ⓘ'
}};
const FLOW_LABELS = {{
    user: 'You', assistant: 'Claude', tools: 'tools', event: 'event'
}};

function rebuildFlowArrows() {{
    document.querySelectorAll('.flow-arrow').forEach(a => a.remove());
    const visible = Array.from(document.querySelectorAll('#msgs > .msg:not(.hidden)'));
    for (let i = 0; i < visible.length - 1; i++) {{
        const cur = visible[i];
        const nxt = visible[i + 1];
        if (cur.classList.contains('event') && nxt.classList.contains('event')) continue;
        const role = nxt.dataset.role;
        const icon = FLOW_ICONS[role] || '·';
        const label = FLOW_LABELS[role] || '';
        const arrow = document.createElement('div');
        arrow.className = `flow-arrow flow-${{role}}`;
        arrow.innerHTML = `
            <span class="arrow-line"></span>
            <span class="arrow-icon" title="next: ${{label}}">${{icon}}</span>
            <span class="arrow-line"></span>`;
        cur.insertAdjacentElement('afterend', arrow);
    }}
}}

// ── Search + role filter (state persisted to survive 5s reloads) ─────────────
const msgs = Array.from(document.querySelectorAll('.msg'));
const q = document.getElementById('q');
const count = document.getElementById('count');
const chips = Array.from(document.querySelectorAll('.chip[data-filter]'));

const SS_KEY = 'claude-detail-state-{pid}';
let state = {{ q: '', roles: ['user', 'assistant', 'tools'] }};
try {{ const s = sessionStorage.getItem(SS_KEY); if (s) state = JSON.parse(s); }} catch (e) {{}}

q.value = state.q || '';
const enabledRoles = new Set(state.roles || ['user', 'assistant', 'tools']);
chips.forEach(c => c.setAttribute('aria-pressed', enabledRoles.has(c.dataset.filter) ? 'true' : 'false'));

function persist() {{
    try {{
        sessionStorage.setItem(SS_KEY, JSON.stringify({{
            q: q.value, roles: Array.from(enabledRoles)
        }}));
    }} catch (e) {{}}
}}

function applyFilter() {{
    const term = (q.value || '').trim().toLowerCase();
    let shown = 0;
    for (const el of msgs) {{
        const role = el.dataset.role;
        const text = el.dataset.search || el.textContent.toLowerCase();
        const ok = enabledRoles.has(role) && (!term || text.includes(term));
        el.classList.toggle('hidden', !ok);
        if (ok) shown++;
    }}
    count.textContent = `${{shown}} / ${{msgs.length}}`;
    persist();
    if (typeof rebuildFlowArrows === 'function') rebuildFlowArrows();
}}

q.addEventListener('input', applyFilter);
chips.forEach(c => c.addEventListener('click', () => {{
    const role = c.dataset.filter;
    if (enabledRoles.has(role)) {{ enabledRoles.delete(role); c.setAttribute('aria-pressed', 'false'); }}
    else                        {{ enabledRoles.add(role);    c.setAttribute('aria-pressed', 'true');  }}
    applyFilter();
}}));
applyFilter();

// applyFilter() calls rebuildFlowArrows() at its end; this is now redundant
// but cheap and a safety net.
rebuildFlowArrows();

// ── Activity bar: click a dot to jump to that message + flash it ─────────────
document.querySelectorAll('button.dot[data-target]').forEach(dot => {{
    dot.addEventListener('click', () => {{
        const target = document.getElementById(dot.dataset.target);
        if (!target) return;
        target.scrollIntoView({{ behavior: 'smooth', block: 'center' }});
        target.classList.remove('flash');
        // Force reflow so the animation re-runs even when re-clicking the same dot.
        void target.offsetWidth;
        target.classList.add('flash');
        setTimeout(() => target.classList.remove('flash'), 1300);
    }});
}});

// ── Long-message overflow → "show more" toggle ───────────────────────────────
// After markdown is rendered we know the real height. If the rendered content
// is taller than the CSS max-height (720px), mark the message .overflow so the
// fade-out + button appear; click to expand.
function annotateOverflow() {{
    document.querySelectorAll('.msg').forEach(msg => {{
        const c = msg.querySelector('.content');
        if (!c) return;
        if (msg.classList.contains('event') || msg.classList.contains('tools')) return;
        if (c.scrollHeight > c.clientHeight + 4) {{
            msg.classList.add('overflow');
            if (!msg.querySelector('.show-more-btn')) {{
                const btn = document.createElement('button');
                btn.className = 'show-more-btn';
                btn.textContent = 'Show full message';
                btn.addEventListener('click', () => {{
                    msg.classList.toggle('expanded');
                    btn.textContent = msg.classList.contains('expanded') ? 'Collapse' : 'Show full message';
                }});
                msg.appendChild(btn);
            }}
        }}
    }});
}}
// Run after markdown render (next animation frame to let layout settle).
requestAnimationFrame(annotateOverflow);

// ── Code-block copy button ───────────────────────────────────────────────────
// Each <pre> in rendered markdown gets a small "copy" button in the top-right
// that lifts the code text without surrounding markdown noise.
document.querySelectorAll('.content pre').forEach(pre => {{
    if (pre.querySelector('.code-copy')) return;
    pre.style.position = pre.style.position || 'relative';
    const btn = document.createElement('button');
    btn.className = 'code-copy';
    btn.textContent = 'copy';
    btn.title = 'Copy code';
    btn.addEventListener('click', e => {{
        e.stopPropagation();
        const code = pre.querySelector('code');
        const text = code ? code.textContent : pre.textContent;
        navigator.clipboard.writeText(text).then(() => {{
            btn.textContent = '✓';
            setTimeout(() => {{ btn.textContent = 'copy'; }}, 1200);
        }}).catch(() => {{}});
    }});
    pre.appendChild(btn);
}});

// ── Scroll position preservation across the 5s meta-refresh ──────────────────
const SCROLL_KEY = 'claude-detail-scroll-{pid}';
const savedScroll = parseInt(sessionStorage.getItem(SCROLL_KEY) || '0', 10);
if (savedScroll > 0) {{
    window.scrollTo(0, savedScroll);
}} else {{
    window.scrollTo(0, document.body.scrollHeight);
}}
let scrollTick = null;
window.addEventListener('scroll', () => {{
    if (scrollTick) return;
    scrollTick = setTimeout(() => {{
        sessionStorage.setItem(SCROLL_KEY, String(window.scrollY));
        scrollTick = null;
    }}, 200);
}}, {{ passive: true }});

// ── Live polling: fetch self → swap #msgs in place ──────────────────────────
//
// Now that the page is served from http://127.0.0.1:<port>/ instead of
// file://, fetch-from-self works. Every LIVE_POLL_MS the JS:
//   1. Calls /regen (server runs detail.sh --regen synchronously)
//   2. Fetches the freshly-regenerated page
//   3. DOMParser-extracts #msgs and replaces the current one in place
//   4. Re-runs marked + hljs on the new content (autolink too)
//   5. Updates the stat row + tools breakdown + activity timeline
//
// Theme, search, chip toggles, scroll, expanded <details> all stay because
// nothing outside the swapped regions is touched.

const LIVE_POLL_MS = 30 * 1000;  // 30s — frequent enough to feel live
const liveServerOK = window.location.protocol === 'http:';
let liveTimer = null;
let lastMsgsHTML = document.getElementById('msgs')?.innerHTML || '';

async function livePoll() {{
    if (!liveServerOK) return;
    try {{
        // Trigger regen on the server, wait for it, then fetch HTML.
        await fetch('/regen', {{ cache: 'no-store' }});
        const r = await fetch(window.location.pathname, {{ cache: 'no-store' }});
        if (!r.ok) return;
        const text = await r.text();
        const doc = new DOMParser().parseFromString(text, 'text/html');
        const newMsgs = doc.getElementById('msgs');
        if (!newMsgs) return;
        const newHTML = newMsgs.innerHTML;
        if (newHTML === lastMsgsHTML) return;  // no change, no DOM thrash

        // Patch the messages region only.
        const cur = document.getElementById('msgs');
        cur.innerHTML = newHTML;
        lastMsgsHTML = newHTML;

        // Re-render markdown + highlight on freshly-injected content.
        if (window.marked) {{
            cur.querySelectorAll('.content[data-md]').forEach(el => {{
                const sc = el.querySelector('script[type="text/markdown"]');
                if (!sc) return;
                el.innerHTML = marked.parse(sc.textContent);
                el.querySelectorAll('pre code').forEach(b => {{
                    if (!b.classList.contains('hljs')) hljs.highlightElement(b);
                }});
                if (typeof autolinkTextNodes === 'function') autolinkTextNodes(el);
            }});
        }}
        cur.querySelectorAll('pre code[class*="language-"]').forEach(b => {{
            if (!b.classList.contains('hljs')) {{
                try {{ hljs.highlightElement(b); }} catch(e) {{}}
            }}
        }});

        // Patch the smaller summary regions if their content changed.
        ['stats', 'tools-breakdown', 'timeline'].forEach(cls => {{
            const newEl = doc.querySelector('.' + cls);
            const curEl = document.querySelector('.' + cls);
            if (newEl && curEl && newEl.innerHTML !== curEl.innerHTML) {{
                curEl.innerHTML = newEl.innerHTML;
            }}
        }});
        // Header refresh-time chip
        const newRef = doc.querySelector('.dim-pill');
        const curRef = document.querySelector('.dim-pill');
        if (newRef && curRef) curRef.textContent = newRef.textContent;

        // After patching messages, recompute flow arrows and re-bind
        // dot-click handlers (the new dots are fresh DOM nodes).
        if (typeof rebuildFlowArrows === 'function') rebuildFlowArrows();
        document.querySelectorAll('button.dot[data-target]').forEach(dot => {{
            if (dot._wired) return;
            dot._wired = true;
            dot.addEventListener('click', () => {{
                const target = document.getElementById(dot.dataset.target);
                if (!target) return;
                target.scrollIntoView({{ behavior: 'smooth', block: 'center' }});
                target.classList.remove('flash');
                void target.offsetWidth;
                target.classList.add('flash');
                setTimeout(() => target.classList.remove('flash'), 1300);
            }});
        }});

        // Update live-tag label briefly to show a tick happened.
        const lt = document.querySelector('.live-tag .live-label');
        if (lt) {{
            lt.textContent = '✓ live';
            setTimeout(() => {{ lt.textContent = '5m'; }}, 800);
        }}
    }} catch (e) {{
        // Swallow network blips — next tick will retry.
    }}
}}

if (liveServerOK) {{
    liveTimer = setInterval(livePoll, LIVE_POLL_MS);
    // First tick happens after the interval; do an immediate one so the
    // user sees fresh content within a second of opening the page.
    setTimeout(livePoll, 1500);
}}
</script>
</body>
</html>'''

# Atomic write: write to .tmp first, then os.replace() — guarantees the
# JS poller never reads a half-written file. Critical now that fetch()
# can race with disk regen.
tmp_path = output_path + '.tmp'
with open(tmp_path, 'w') as f:
    f.write(page_html)
os.replace(tmp_path, output_path)

print(f"Detail page written to: {output_path}")
PYEOF

# Serve the data-first viewer (transcript-app.html) in place of the baked HTML
# above. It is static — it pulls the transcript live from the server's /data
# endpoint — so a one-time copy is enough and --regen ticks just refresh it
# harmlessly. The legacy generator still runs above as a fallback; remove it
# once the new viewer is confirmed. Set CLAUDE_WIDGET_LEGACY=1 to opt back out.
APP_TEMPLATE="$(dirname "$SCRIPT_PATH")/transcript-app.html"
if [[ "${CLAUDE_WIDGET_LEGACY:-0}" != "1" && -f "$APP_TEMPLATE" ]]; then
    cp -f "$APP_TEMPLATE" "$OUTPUT"
fi

# In regen-only mode, we're done — server / daemon own this branch.
if [[ "$REGEN_ONLY" == "1" ]]; then
    exit 0
fi

# ── Live-update HTTP server ─────────────────────────────────────────────────
#
# The page now opens via http://127.0.0.1:<port>/... so it can fetch() its
# own URL (file:// → file:// fetch is CORS-blocked in Chrome since 2018).
# Server replaces the previous bash regen daemon: it does both the static
# file serving AND a /regen endpoint the JS poller can call to trigger an
# on-demand regen between the 5-minute scheduled ticks. See
# lib/detail-server.py for full lifecycle (claude-pid death + 2h timeout).
#
# Per-pid port allocation: 5400 + (pid % 500). With 500 unique slots and
# typical per-user pid count well under that, collisions are vanishingly
# rare. Port-in-use just means a server is already running for this pid;
# the preflight check below catches that and reuses it.

SERVER_SCRIPT="$(dirname "$SCRIPT_PATH")/detail-server.py"
PORT=$(( 5400 + (PID % 500) ))
SERVER_PID_FILE="/tmp/claude-widget-${PID}.server"

is_server_alive_on_port() {
    nc -z 127.0.0.1 "$PORT" 2>/dev/null
}

# Stale PID file from a previous server that hit idle/death timeout:
# clear it BEFORE the port check so we don't get fooled into thinking
# a server is running when only the file remains.
if [[ -f "$SERVER_PID_FILE" ]]; then
    OLD_SRV_PID=$(cat "$SERVER_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$OLD_SRV_PID" ]] && ! kill -0 "$OLD_SRV_PID" 2>/dev/null; then
        # Old server is dead — file is stale, remove.
        rm -f "$SERVER_PID_FILE"
    fi
fi

# Spawn iff port isn't already bound by a healthy server.
if ! is_server_alive_on_port; then
    SERVER_LOG="/tmp/claude-widget-${PID}.server.log"
    nohup python3 "$SERVER_SCRIPT" "$PORT" "$SCRIPT_PATH" "$PID" "$SESSION_ID" \
        >"$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$SERVER_PID_FILE"
    disown 2>/dev/null || true

    # Wait for the server to bind. 15 retries × 100ms = 1.5s max — gives
    # Python's http.server startup enough room on slower machines without
    # making the user wait if it's quick.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if is_server_alive_on_port; then break; fi
        sleep 0.1
    done

    # If still not bound, surface the failure in the log + bail with a
    # clear error so the bar's openDetail log shows what happened.
    if ! is_server_alive_on_port; then
        echo "ERROR: detail-server.py did not bind to port $PORT after 1.5s" >&2
        echo "  Check $SERVER_LOG for the Python error." >&2
        exit 1
    fi
fi

# ── Compatibility: keep the legacy DAEMON_PID_FILE clean ────────────────────
#
# Older code paths watch /tmp/claude-widget-<pid>.daemon. The python server
# subsumes that role; nuke the legacy file so stale watchers don't confuse
# themselves.
rm -f "$DAEMON_PID_FILE" 2>/dev/null || true

# Open in default browser via http://127.0.0.1 — fetch-from-self now works.
URL="http://127.0.0.1:${PORT}/$(basename "$OUTPUT")"
open -a "Google Chrome" "$URL" 2>/dev/null || open "$URL" 2>/dev/null
