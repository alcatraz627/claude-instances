#!/usr/bin/env bash
# detail.sh — Generate and open a session detail HTML page.
#
# Usage: bash detail.sh <pid> <session_id>
#
# Generates /tmp/claude-widget-<pid>.html with conversation stream, tool-call
# detail, search/filter UI, token usage, MCP status, and 5s auto-refresh.

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

jsonl_file  = sys.argv[1] if sys.argv[1] else None
pid         = sys.argv[2]
statusline  = json.loads(sys.argv[3]) if sys.argv[3] != '{}' else {}
output_path = sys.argv[4]

# ── Parse the JSONL transcript ────────────────────────────────────────────────
#
# Each assistant message in the transcript can contain multiple content blocks.
# A "tool-only" assistant turn (no text, just tool_use blocks) used to render
# as N separate "[Tool: X]" rows — visual spam. We now coalesce consecutive
# tool-only assistant turns into a single "tools" group with input previews.

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
    """Convert JSONL timestamp to a short HH:MM:SS in local time."""
    if not iso: return ''
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        return dt.astimezone().strftime('%H:%M:%S')
    except Exception:
        return ''

def tool_preview(name, inp):
    """Return a compact one-line preview of a tool call's inputs.
    Tailored to the most common tools so a glance tells you what happened."""
    if not isinstance(inp, dict):
        return ''
    if name in ('Bash',):
        return short(inp.get('command', '').replace('\n', ' '), 100)
    if name in ('Read', 'Write'):
        return short(inp.get('file_path', ''), 80)
    if name == 'Edit':
        path = inp.get('file_path', '')
        old  = short(inp.get('old_string', '').replace('\n', '⏎'), 40)
        return f"{short(path, 50)}  ·  {old}"
    if name == 'Grep':
        pat  = inp.get('pattern', '')
        path = inp.get('path', '')
        return f"/{short(pat, 40)}/  in {short(path, 40)}"
    if name == 'Glob':
        return short(inp.get('pattern', ''), 80)
    if name == 'WebFetch':
        return short(inp.get('url', ''), 80)
    if name in ('Task', 'Agent'):
        return short(inp.get('description', '') or inp.get('prompt', ''), 80)
    if name == 'TodoWrite':
        todos = inp.get('todos', [])
        return f"{len(todos)} item(s)"
    # Generic fallback: first short string-ish field.
    for k, v in inp.items():
        if isinstance(v, str) and v:
            return f"{k}: {short(v, 70)}"
    return ''

messages = []         # list of dicts: {role, content_html, ts, tokens_in, tokens_out, kind}
model = 'unknown'
total_input = 0
total_output = 0
total_cache_read = 0
session_id = ''
pending_tools = []    # accumulator for consecutive tool-only assistant turns

def flush_tools():
    """Emit accumulated tool-only turns as a single grouped message."""
    global pending_tools
    if not pending_tools:
        return
    items_html = ''
    for t in pending_tools:
        prev = html.escape(t['preview']) if t['preview'] else ''
        prev_html = f'<span class="tool-prev">{prev}</span>' if prev else ''
        items_html += f'<li><span class="tool-name">{html.escape(t["name"])}</span> {prev_html}</li>'
    n = len(pending_tools)
    summary = f"🔧 {n} tool call{'s' if n != 1 else ''}"
    messages.append({
        'role': 'tools',
        'kind': 'tools',
        'ts': pending_tools[-1].get('ts', ''),
        'content_html': (
            f'<details><summary>{summary}</summary>'
            f'<ul class="tool-list">{items_html}</ul></details>'
        ),
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
                            elif block.get('type') == 'tool_result':
                                # Tool results are usually system-emitted; skip
                                # unless the user clearly typed something.
                                pass
                        elif isinstance(block, str):
                            content += block
                elif isinstance(msg, str):
                    content = msg
                if content.strip():
                    messages.append({
                        'role': 'user', 'kind': 'user', 'ts': ts,
                        'content_raw': content.strip(),
                    })

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
                            tool_calls.append({
                                'name': block.get('name', '?'),
                                'preview': tool_preview(block.get('name', ''), block.get('input', {})),
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
                    # Tool calls in the SAME assistant message as text get their
                    # own grouped entry right after.
                    if tool_calls:
                        pending_tools.extend(tool_calls)
                else:
                    pending_tools.extend(tool_calls)

flush_tools()

# Trim model name for display.
model_short = model
if 'opus'   in model.lower(): model_short = 'Opus'
elif 'sonnet' in model.lower(): model_short = 'Sonnet'
elif 'haiku'  in model.lower(): model_short = 'Haiku'

# ── Markdown rendering ────────────────────────────────────────────────────────
#
# Lightweight regex-based subset: triple-backtick code blocks, inline code,
# bold, italic, and explicit line breaks. Anything fancier (tables, lists,
# headings) is out of scope — we keep messages readable, not perfectly
# rendered.

CODE_BLOCK_RE = re.compile(r'```([a-zA-Z0-9_+-]*)\n(.*?)```', re.DOTALL)
INLINE_CODE_RE = re.compile(r'`([^`\n]+)`')
BOLD_RE   = re.compile(r'\*\*([^*\n]+)\*\*')
ITALIC_RE = re.compile(r'(?<!\*)\*([^*\n]+)\*(?!\*)')

def render_md(text):
    placeholders = []  # (key, html) — preserve code from later substitutions

    def stash(h):
        key = f'\x00{len(placeholders)}\x00'
        placeholders.append((key, h))
        return key

    def repl_code_block(m):
        lang = m.group(1)
        body = html.escape(m.group(2))
        cls = f' class="lang-{html.escape(lang)}"' if lang else ''
        return stash(f'<pre><code{cls}>{body}</code></pre>')

    def repl_inline_code(m):
        return stash(f'<code>{html.escape(m.group(1))}</code>')

    text = CODE_BLOCK_RE.sub(repl_code_block, text)
    text = INLINE_CODE_RE.sub(repl_inline_code, text)
    text = html.escape(text)
    text = BOLD_RE.sub(r'<b>\1</b>', text)
    text = ITALIC_RE.sub(r'<i>\1</i>', text)
    text = text.replace('\n', '<br>')
    for key, h in placeholders:
        text = text.replace(html.escape(key), h)
    return text

# ── Build per-message HTML ────────────────────────────────────────────────────

display_messages = messages[-100:]  # cap at 100 most recent for page size

msg_html = ''
for i, m in enumerate(display_messages):
    role = m['role']
    ts = m.get('ts', '')
    ts_html = f'<span class="ts">{ts}</span>' if ts else ''
    if role == 'user':
        body = render_md(m['content_raw'])
        msg_html += (
            f'<div class="msg user" data-role="user" data-search="{html.escape(m["content_raw"].lower())}">'
            f'  <div class="role"><span>You</span>{ts_html}</div>'
            f'  <div class="content">{body}</div>'
            f'</div>\n'
        )
    elif role == 'assistant':
        body = render_md(m['content_raw'])
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
            f'  <div class="content">{body}</div>'
            f'</div>\n'
        )
    elif role == 'tools':
        msg_html += (
            f'<div class="msg tools" data-role="tools" data-search="">'
            f'  <div class="role"><span class="dim">tools</span>{ts_html}</div>'
            f'  <div class="content">{m["content_html"]}</div>'
            f'</div>\n'
        )

# ── Statusline metrics bar (top of page) ─────────────────────────────────────

sl_html = ''
if statusline:
    cpu  = statusline.get('proc_cpu', '0')
    mem  = statusline.get('proc_mem', '0')
    rss  = statusline.get('proc_rss', '0')
    mcp_h = statusline.get('mcp_healthy', '')
    mcp_d = statusline.get('mcp_down', '')
    ctx_r = statusline.get('ctx_remaining', '')
    ctx_chunk = ''
    if ctx_r and ctx_r != '0':
        ctx_int = int(ctx_r) if ctx_r.isdigit() else 0
        ctx_cls = 'err' if ctx_int < 30 else ('warn' if ctx_int < 60 else 'ok')
        ctx_chunk = f'<span class="metric"><b>CTX</b> <span class="{ctx_cls}">{ctx_r}%</span></span>'
    sl_html = f'''
    <div class="metrics-bar">
        {ctx_chunk}
        <span class="metric"><b>CPU</b> {cpu}%</span>
        <span class="metric"><b>MEM</b> {mem}% ({rss}MB)</span>
        <span class="metric"><b>MCP</b> {mcp_h or "none"}</span>
        {f'<span class="metric warn"><b>DOWN</b> {mcp_d}</span>' if mcp_d else ''}
    </div>'''

now = datetime.now(timezone.utc).strftime('%H:%M:%S UTC')

page_html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Claude — {model_short} · PID {pid}</title>
<style>
:root {{
    --bg: #0d1117; --surface: #161b22; --surface2: #1c2333;
    --text: #e6edf3; --dim: #7d8590; --accent: #58a6ff;
    --accent2: #3fb950; --warn: #d29922; --err: #f85149;
    --border: #30363d; --user-bg: #1a2332; --asst-bg: #161b22;
    --tools-bg: #1a1f2a;
}}
body.light {{
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

.toolbar {{
    position: sticky; top: 0; z-index: 50;
    display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
    padding: 10px 24px; background: var(--surface);
    border-bottom: 1px solid var(--border);
}}
.toolbar input[type=search] {{
    flex: 1; min-width: 180px; max-width: 380px;
    background: var(--bg); border: 1px solid var(--border); color: var(--text);
    border-radius: 6px; padding: 6px 10px; font-size: 13px;
    font-family: inherit;
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

.content {{ font-size: 13px; line-height: 1.55; word-break: break-word; }}
.content code {{
    background: var(--surface2); padding: 1px 5px; border-radius: 3px;
    font-family: ui-monospace, Menlo, monospace; font-size: 12px;
}}
.content pre {{
    background: var(--surface2); padding: 10px 12px; border-radius: 6px;
    overflow-x: auto; margin: 8px 0; border: 1px solid var(--border);
}}
.content pre code {{ background: transparent; padding: 0; font-size: 12px; line-height: 1.5; }}
.content b {{ font-weight: 700; color: var(--text); }}
.content i {{ font-style: italic; }}

.tool-list {{ list-style: none; padding-left: 12px; margin-top: 6px; }}
.tool-list li {{ padding: 2px 0; font-size: 12px; font-family: ui-monospace, Menlo, monospace; }}
.tool-list .tool-name {{ color: var(--accent); font-weight: 600; }}
.tool-list .tool-prev {{ color: var(--dim); margin-left: 8px; }}
details summary {{ cursor: pointer; font-size: 12px; font-family: ui-monospace, monospace; color: var(--dim); }}
details[open] summary {{ color: var(--text); }}

.empty {{ color: var(--dim); text-align: center; padding: 60px; font-style: italic; }}
</style>
</head>
<body>
<button class="theme-toggle" onclick="document.body.classList.toggle('light')">☀ / ☾</button>

<div class="header">
    <h1>Claude {model_short} · PID {pid}</h1>
    <div class="meta">
        Session <code>{session_id[:12]}{'…' if len(session_id) > 12 else ''}</code>
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

<script>
const msgs = Array.from(document.querySelectorAll('.msg'));
const q = document.getElementById('q');
const count = document.getElementById('count');
const chips = Array.from(document.querySelectorAll('.chip[data-filter]'));
const enabledRoles = new Set(chips.map(c => c.dataset.filter));

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
}}

q.addEventListener('input', applyFilter);
chips.forEach(c => c.addEventListener('click', () => {{
    const role = c.dataset.filter;
    if (enabledRoles.has(role)) {{
        enabledRoles.delete(role);
        c.setAttribute('aria-pressed', 'false');
    }} else {{
        enabledRoles.add(role);
        c.setAttribute('aria-pressed', 'true');
    }}
    applyFilter();
}}));

applyFilter();

// Auto-scroll to bottom on first paint (preserve scroll on subsequent refreshes
// when user has scrolled up to read).
const container = document.getElementById('msgs');
if (container && !sessionStorage.getItem('claude-detail-scrolled-' + {pid})) {{
    container.scrollIntoView({{ block: 'end' }});
    window.scrollTo(0, document.body.scrollHeight);
}}
window.addEventListener('scroll', () => {{
    sessionStorage.setItem('claude-detail-scrolled-' + {pid}, '1');
}});
</script>
</body>
</html>'''

with open(output_path, 'w') as f:
    f.write(page_html)

print(f"Detail page written to: {output_path}")
PYEOF

# Open in default browser (Chrome preferred for live-reload behavior).
open -a "Google Chrome" "$OUTPUT" 2>/dev/null || open "$OUTPUT" 2>/dev/null
