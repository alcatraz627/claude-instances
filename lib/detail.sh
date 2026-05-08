#!/usr/bin/env bash
# detail.sh — Generate and open a session detail HTML page.
#
# Usage: bash detail.sh <pid> <session_id>
#
# Generates /tmp/claude-widget-<pid>.html with conversation stream, tool-call
# detail, search/filter UI, token usage, MCP status, activity timeline, and
# 5s auto-refresh that preserves theme + search + scroll between reloads.

set -uo pipefail

PID="${1:-}"
SESSION_ID="${2:-}"
PROJECTS_DIR="${HOME}/.claude/projects"
OUTPUT="/tmp/claude-widget-${PID:-unknown}.html"

if [[ -z "$PID" ]] && [[ -z "$SESSION_ID" ]]; then
    echo "Usage: detail.sh <pid> [session_id]" >&2
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
    if not iso: return ''
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        return dt.astimezone().strftime('%H:%M:%S')
    except Exception:
        return ''

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

messages = []           # list of dicts: {role, content_raw, ts, tokens_in/out, kind}
model = 'unknown'
total_input = 0
total_output = 0
total_cache_read = 0
session_id = ''
pending_tools = []      # accumulator for consecutive tool-only assistant turns
tool_counter = Counter()
activity_dots = []      # one dot per turn for the timeline ribbon

def flush_tools():
    global pending_tools
    if not pending_tools:
        return
    n = len(pending_tools)
    summary = f"🔧 {n} tool call{'s' if n != 1 else ''}"
    messages.append({
        'role': 'tools', 'kind': 'tools',
        'ts': pending_tools[-1].get('ts', ''),
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
            ts = fmt_ts(obj.get('timestamp', ''))

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
                        'role': 'user', 'kind': 'user', 'ts': ts,
                        'content_raw': content.strip(),
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
                                'ts': ts,
                                'tokens_out': usage.get('output_tokens', 0),
                            })

                if text_part.strip():
                    flush_tools()
                    messages.append({
                        'role': 'assistant', 'kind': 'assistant', 'ts': ts,
                        'content_raw': text_part.strip(),
                        'tokens_in':  usage.get('input_tokens', 0),
                        'tokens_out': usage.get('output_tokens', 0),
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

    # Special-case Edit: render old_string vs new_string side-by-side.
    extras_html = ''
    if name == 'Edit' and isinstance(inp, dict):
        old = inp.get('old_string', '')
        new = inp.get('new_string', '')
        extras_html = (
            '<div class="diff-pair">'
            f'<div class="diff-side"><div class="diff-label">old</div><pre><code>{html.escape(old)}</code></pre></div>'
            f'<div class="diff-side"><div class="diff-label">new</div><pre><code>{html.escape(new)}</code></pre></div>'
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
    ts_html = f'<span class="ts">{ts}</span>' if ts else ''

    if role == 'user':
        raw = safe_md(m['content_raw'])
        msg_html += (
            f'<div class="msg user" data-role="user" data-search="{html.escape(m["content_raw"].lower())}">'
            f'  <div class="role"><span>You</span>{ts_html}</div>'
            f'  <div class="content" data-md><script type="text/markdown">{raw}</script></div>'
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
            f'<div class="msg assistant" data-role="assistant" data-search="{html.escape(m["content_raw"].lower())}">'
            f'  <div class="role"><span>Claude ({model_short})</span>{badge}{ts_html}</div>'
            f'  <div class="content" data-md><script type="text/markdown">{raw}</script></div>'
            f'</div>\n'
        )
    elif role == 'tools':
        tools_html = ''.join(render_tool_detail(t) for t in m['tools'])
        msg_html += (
            f'<div class="msg tools" data-role="tools" data-search="">'
            f'  <div class="role"><span class="dim">tools</span>{ts_html}</div>'
            f'  <div class="content">'
            f'    <details open>'
            f'      <summary>{m["summary"]}</summary>'
            f'      <ul class="tool-list">{tools_html}</ul>'
            f'    </details>'
            f'  </div>'
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

timeline_html = ''
if activity_dots:
    dot_html = ''
    for kind, ts in activity_dots[-120:]:
        dot_html += f'<span class="dot dot-{kind}" title="{ts}"></span>'
    timeline_html = (
        '<div class="timeline">'
        '  <div class="section-title">Activity (most recent →)</div>'
        f'  <div class="dots">{dot_html}</div>'
        '  <div class="legend">'
        '    <span><span class="dot dot-u"></span>You</span>'
        '    <span><span class="dot dot-a"></span>Claude</span>'
        '    <span><span class="dot dot-t"></span>Tools</span>'
        '  </div>'
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
<meta http-equiv="refresh" content="5">
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
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    background: var(--bg); color: var(--text); font-size: 14px;
}}
.theme-toggle {{
    position: fixed; top: 12px; right: 16px; z-index: 100;
    background: var(--surface); border: 1px solid var(--border); color: var(--text);
    border-radius: 6px; padding: 6px 12px; cursor: pointer; font-size: 14px;
}}

.header {{ padding: 18px 24px 12px; border-bottom: 1px solid var(--border); }}
.header h1 {{ font-size: 17px; margin-bottom: 4px; font-weight: 600; }}
.header .meta {{ color: var(--dim); font-size: 12px; }}
.header .meta code {{ background: var(--surface2); padding: 1px 5px; border-radius: 3px; font-size: 11px; }}

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

.timeline {{ padding: 12px 24px; border-bottom: 1px solid var(--border); }}
.timeline .dots {{ display: flex; flex-wrap: wrap; gap: 3px; padding: 4px 0; }}
.dot {{
    width: 8px; height: 8px; border-radius: 2px;
    display: inline-block; vertical-align: middle;
}}
.dot-u {{ background: var(--accent); }}
.dot-a {{ background: var(--accent2); }}
.dot-t {{ background: var(--warn); }}
.legend {{ display: flex; gap: 14px; margin-top: 6px; font-size: 11px; color: var(--dim); }}
.legend span {{ display: inline-flex; align-items: center; gap: 6px; }}

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

.messages {{ padding: 16px 24px 80px; max-width: 1100px; margin: 0 auto; }}
.msg {{
    padding: 10px 14px; margin-bottom: 10px; border-radius: 8px;
    border-left: 3px solid var(--border);
}}
.msg.user      {{ background: var(--user-bg);  border-left-color: var(--accent); }}
.msg.assistant {{ background: var(--asst-bg);  border-left-color: var(--accent2); }}
.msg.tools     {{ background: var(--tools-bg); border-left-color: var(--warn); }}
.msg.hidden    {{ display: none; }}

.role {{
    display: flex; align-items: center; gap: 8px;
    font-size: 12px; font-weight: 600; color: var(--dim); margin-bottom: 4px;
}}
.role .ts {{ font-family: ui-monospace, monospace; font-size: 11px; color: var(--dim); margin-left: auto; }}
.role .dim {{ color: var(--dim); font-weight: 500; }}
.tok-badge {{
    background: var(--surface2); padding: 1px 7px; border-radius: 999px;
    font-size: 11px; font-family: ui-monospace, monospace; color: var(--text);
}}
.tok-badge.dim {{ color: var(--dim); }}

/* Markdown content (rendered by marked + hljs at runtime) */
.content {{ font-size: 13px; line-height: 1.55; word-break: break-word; }}
.content h1, .content h2, .content h3, .content h4 {{
    font-weight: 700; margin: 14px 0 6px; line-height: 1.25;
}}
.content h1 {{ font-size: 18px; }}
.content h2 {{ font-size: 16px; border-bottom: 1px solid var(--border); padding-bottom: 4px; }}
.content h3 {{ font-size: 14px; }}
.content h4 {{ font-size: 13px; color: var(--dim); }}
.content p  {{ margin: 6px 0; }}
.content ul, .content ol {{ margin: 6px 0 6px 22px; }}
.content li {{ margin: 2px 0; }}
.content blockquote {{
    border-left: 3px solid var(--border); padding: 4px 12px;
    color: var(--dim); margin: 8px 0;
}}
.content table {{ border-collapse: collapse; margin: 8px 0; font-size: 12px; }}
.content th, .content td {{
    border: 1px solid var(--border); padding: 4px 8px; text-align: left;
}}
.content th {{ background: var(--surface2); font-weight: 600; }}
.content code:not(pre code) {{
    background: var(--surface2); padding: 1px 5px; border-radius: 3px;
    font-family: ui-monospace, Menlo, monospace; font-size: 12px;
}}
.content pre {{
    background: var(--surface2); padding: 10px 12px; border-radius: 6px;
    overflow-x: auto; margin: 8px 0; border: 1px solid var(--border);
}}
.content pre code {{
    background: transparent; padding: 0; font-size: 12px; line-height: 1.5;
    font-family: ui-monospace, Menlo, monospace;
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

/* Edit diff side-by-side */
.diff-pair {{ display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 6px 0; }}
.diff-side {{ }}
.diff-label {{
    font-size: 10px; font-weight: 700; text-transform: uppercase;
    color: var(--dim); padding: 2px 4px;
}}
.diff-side pre {{ max-height: 200px; overflow: auto; font-size: 11px; }}

details summary {{ cursor: pointer; font-size: 12px; color: var(--text); }}

/* Click-to-copy chips with hover tooltip */
.copyable {{
    cursor: pointer; padding: 1px 4px; border-radius: 3px;
    transition: background 0.12s, color 0.12s;
    display: inline-flex; align-items: center; gap: 4px;
    position: relative;
}}
.copyable:hover {{ background: var(--accent); color: var(--bg); }}
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
.copyable.copied::after {{ content: '✓ Copied'; opacity: 1; background: var(--accent2); color: white; }}

.empty {{ color: var(--dim); text-align: center; padding: 60px; font-style: italic; }}
</style>
</head>
<body>
<button class="theme-toggle" id="themeToggle" title="Toggle light/dark">☀ / ☾</button>

<div class="header">
    <h1>Claude {model_short} · PID {pid}</h1>
    <div class="meta">
        Session <code class="copyable" data-copy="{session_id}" title="Click to copy session id">{session_id[:12]}{'…' if len(session_id) > 12 else ''}</code>
        · Last refresh {now}
        · Auto-refresh 5s
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
    }});
}}

// Highlight tool-detail JSON / bash blocks (these were emitted directly).
document.querySelectorAll('pre code.language-json, pre code.language-bash').forEach(b => {{
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
}}

q.addEventListener('input', applyFilter);
chips.forEach(c => c.addEventListener('click', () => {{
    const role = c.dataset.filter;
    if (enabledRoles.has(role)) {{ enabledRoles.delete(role); c.setAttribute('aria-pressed', 'false'); }}
    else                        {{ enabledRoles.add(role);    c.setAttribute('aria-pressed', 'true');  }}
    applyFilter();
}}));
applyFilter();

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
</script>
</body>
</html>'''

with open(output_path, 'w') as f:
    f.write(page_html)

print(f"Detail page written to: {output_path}")
PYEOF

# Open in default browser (Chrome preferred for live-reload behavior).
open -a "Google Chrome" "$OUTPUT" 2>/dev/null || open "$OUTPUT" 2>/dev/null
