#!/usr/bin/env bash
# detail.sh — Generate and open a session detail HTML page.
#
# Usage: bash detail.sh <pid> <session_id>
#
# Generates /tmp/claude-widget-<pid>.html with conversation stream,
# token usage, context bar, and auto-refresh.

set -uo pipefail

PID="${1:-}"
SESSION_ID="${2:-}"
PROJECTS_DIR="${HOME}/.claude/projects"
OUTPUT="/tmp/claude-widget-${PID:-unknown}.html"

if [[ -z "$PID" ]] && [[ -z "$SESSION_ID" ]]; then
    echo "Usage: detail.sh <pid> [session_id]" >&2
    exit 1
fi

# Find the JSONL file
JSONL_FILE=""
if [[ -n "$SESSION_ID" ]]; then
    JSONL_FILE=$(find "$PROJECTS_DIR" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -1)
fi

# If no session_id, try to find by PID's CWD
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

# Read statusline
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

# Generate the HTML
python3 - "$JSONL_FILE" "$PID" "$STATUSLINE_DATA" "$OUTPUT" <<'PYEOF'
import sys, json, os, html
from datetime import datetime, timezone

jsonl_file = sys.argv[1] if sys.argv[1] else None
pid = sys.argv[2]
statusline = json.loads(sys.argv[3]) if sys.argv[3] != '{}' else {}
output_path = sys.argv[4]

# Parse conversation from JSONL
messages = []
model = 'unknown'
total_input = 0
total_output = 0
total_cache_read = 0
session_id = ''

if jsonl_file and os.path.exists(jsonl_file):
    session_id = os.path.splitext(os.path.basename(jsonl_file))[0]
    size = os.path.getsize(jsonl_file)

    # For large files, only read last portion
    with open(jsonl_file, 'r', errors='replace') as f:
        if size > 1_000_000:
            f.seek(max(0, size - 500_000))
            f.readline()  # skip partial

        for line in f:
            try:
                obj = json.loads(line.strip())
            except json.JSONDecodeError:
                continue

            msg_type = obj.get('type', '')

            if msg_type == 'user':
                msg = obj.get('message', {})
                content = ''
                if isinstance(msg, dict):
                    for block in msg.get('content', []):
                        if isinstance(block, dict) and block.get('type') == 'text':
                            content += block.get('text', '')
                        elif isinstance(block, str):
                            content += block
                elif isinstance(msg, str):
                    content = msg
                if content.strip():
                    messages.append({'role': 'user', 'content': content.strip()[:2000]})

            elif msg_type == 'assistant':
                msg = obj.get('message', {})
                m = msg.get('model', '')
                if m:
                    model = m
                usage = msg.get('usage', {})
                total_input += usage.get('input_tokens', 0)
                total_output += usage.get('output_tokens', 0)
                total_cache_read += usage.get('cache_read_input_tokens', 0)

                content = ''
                for block in msg.get('content', []):
                    if isinstance(block, dict):
                        if block.get('type') == 'text':
                            content += block.get('text', '')
                        elif block.get('type') == 'tool_use':
                            content += f"\n[Tool: {block.get('name', '?')}]\n"
                if content.strip():
                    messages.append({
                        'role': 'assistant',
                        'content': content.strip()[:3000],
                        'tokens_in': usage.get('input_tokens', 0),
                        'tokens_out': usage.get('output_tokens', 0),
                    })

# Shorten model for display
model_short = model
if 'opus' in model: model_short = 'Opus'
elif 'sonnet' in model: model_short = 'Sonnet'
elif 'haiku' in model: model_short = 'Haiku'

# Format token counts
def fmt_tokens(n):
    if n > 1_000_000: return f"{n/1_000_000:.1f}M"
    if n > 1_000: return f"{n/1_000:.1f}K"
    return str(n)

now = datetime.now(timezone.utc).strftime('%H:%M:%S UTC')

# Only show last 50 messages
display_messages = messages[-50:]

# Build message HTML
msg_html = ''
for msg in display_messages:
    role = msg['role']
    content = html.escape(msg['content'])
    # Simple line breaks
    content = content.replace('\n', '<br>')

    if role == 'user':
        msg_html += f'<div class="msg user"><div class="role">You</div><div class="content">{content}</div></div>\n'
    else:
        tok_info = ''
        if msg.get('tokens_out'):
            tok_info = f' <span class="tok-badge">{fmt_tokens(msg["tokens_out"])} out</span>'
        msg_html += f'<div class="msg assistant"><div class="role">Claude ({model_short}){tok_info}</div><div class="content">{content}</div></div>\n'

# Statusline metrics bar
sl_html = ''
if statusline:
    cpu = statusline.get('proc_cpu', '0')
    mem = statusline.get('proc_mem', '0')
    rss = statusline.get('proc_rss', '0')
    mcp_h = statusline.get('mcp_healthy', '')
    mcp_d = statusline.get('mcp_down', '')
    sl_html = f'''
    <div class="metrics-bar">
        <span class="metric"><b>CPU</b> {cpu}%</span>
        <span class="metric"><b>MEM</b> {mem}% ({rss}MB)</span>
        <span class="metric"><b>MCP</b> {mcp_h or "none"}</span>
        {f'<span class="metric warn"><b>DOWN</b> {mcp_d}</span>' if mcp_d else ''}
    </div>'''

page_html = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5">
<title>Claude Session — PID {pid}</title>
<style>
:root {{
    --bg: #0d1117; --surface: #161b22; --surface2: #1c2333;
    --text: #e6edf3; --dim: #7d8590; --accent: #58a6ff;
    --accent2: #3fb950; --warn: #d29922; --err: #f85149;
    --border: #30363d; --user-bg: #1a2332; --asst-bg: #161b22;
}}
body.light {{
    --bg: #f6f8fa; --surface: #fff; --surface2: #f0f3f6;
    --text: #1f2328; --dim: #656d76; --accent: #0969da;
    --accent2: #1a7f37; --warn: #9a6700; --err: #cf222e;
    --border: #d0d7de; --user-bg: #ddf4ff; --asst-bg: #fff;
}}
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ font-family: -apple-system, sans-serif; background: var(--bg); color: var(--text); }}
.theme-toggle {{ position: fixed; top: 12px; right: 16px; z-index: 100;
    background: var(--surface); border: 1px solid var(--border); color: var(--text);
    border-radius: 6px; padding: 6px 12px; cursor: pointer; font-size: 14px; }}
.header {{ padding: 20px 24px; border-bottom: 1px solid var(--border); }}
.header h1 {{ font-size: 18px; margin-bottom: 8px; }}
.header .meta {{ color: var(--dim); font-size: 13px; }}
.stats {{ display: flex; gap: 24px; padding: 16px 24px; border-bottom: 1px solid var(--border);
    background: var(--surface); flex-wrap: wrap; }}
.stat {{ text-align: center; }}
.stat .value {{ font-size: 22px; font-weight: 700; color: var(--accent); }}
.stat .label {{ font-size: 11px; color: var(--dim); }}
.metrics-bar {{ display: flex; gap: 16px; padding: 8px 24px; font-size: 12px;
    font-family: Menlo, monospace; border-bottom: 1px solid var(--border); color: var(--dim); }}
.metric b {{ color: var(--text); }}
.metric.warn {{ color: var(--err); }}
.messages {{ padding: 16px 24px; max-height: calc(100vh - 220px); overflow-y: auto; }}
.msg {{ padding: 12px 16px; margin-bottom: 8px; border-radius: 8px; }}
.msg.user {{ background: var(--user-bg); border-left: 3px solid var(--accent); }}
.msg.assistant {{ background: var(--asst-bg); border-left: 3px solid var(--accent2); }}
.role {{ font-size: 12px; font-weight: 600; color: var(--dim); margin-bottom: 4px; }}
.content {{ font-size: 13px; line-height: 1.6; white-space: pre-wrap; word-break: break-word; }}
.tok-badge {{ background: var(--surface2); padding: 1px 6px; border-radius: 3px; font-size: 11px; }}
.empty {{ color: var(--dim); text-align: center; padding: 60px; font-style: italic; }}
</style>
</head>
<body>
<button class="theme-toggle" onclick="document.body.classList.toggle('light')">&#9728; / &#9790;</button>
<div class="header">
    <h1>PID {pid} — {model_short}</h1>
    <div class="meta">Session: {session_id[:12]}... · Last refresh: {now} · Auto-refresh: 5s</div>
</div>
<div class="stats">
    <div class="stat"><div class="value">{fmt_tokens(total_input)}</div><div class="label">Input Tokens</div></div>
    <div class="stat"><div class="value">{fmt_tokens(total_output)}</div><div class="label">Output Tokens</div></div>
    <div class="stat"><div class="value">{fmt_tokens(total_cache_read)}</div><div class="label">Cache Read</div></div>
    <div class="stat"><div class="value">{len(messages)}</div><div class="label">Messages</div></div>
</div>
{sl_html}
<div class="messages">
    {msg_html if msg_html else '<div class="empty">No messages found</div>'}
</div>
<script>
// Auto-scroll to bottom
const msgs = document.querySelector('.messages');
if (msgs) msgs.scrollTop = msgs.scrollHeight;
</script>
</body>
</html>'''

with open(output_path, 'w') as f:
    f.write(page_html)

print(f"Detail page written to: {output_path}")
PYEOF

# Open the file
open -a "Google Chrome" "$OUTPUT" 2>/dev/null || open "$OUTPUT" 2>/dev/null
