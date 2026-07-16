#!/usr/bin/env bash
# scan.sh — enumerate live Claude Code instances + recent session history.
#
# Output: JSON to stdout with structure:
#   { "live": [...], "history": [...], "limits": {...}, "aggregates": {...} }
#
# Live instances: discovered via pgrep + process info + statusline metrics.
# History: enumerated from ~/.claude/projects/*/*.jsonl.
# Limits: read from cached ~/.claude/widgets/.limits.json if present.
# Aggregates: today/week session stats, model breakdown.
#
# Flags:
#   --quick   Skip history, events, aggregates (fast path for 5s polling)

set -uo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
LIMITS_CACHE="${HOME}/.claude/widgets/.limits.json"
EVENTS_FILE="${HOME}/.claude/events.jsonl"
STATUSLINE_DIR="/tmp"
QUICK_MODE=0
[[ "${1:-}" == "--quick" ]] && QUICK_MODE=1

python3 - "$PROJECTS_DIR" "$LIMITS_CACHE" "$EVENTS_FILE" "$STATUSLINE_DIR" "$QUICK_MODE" <<'PYEOF'
import sys, json, os, subprocess, re
from datetime import datetime, timezone, timedelta
from pathlib import Path

projects_dir = sys.argv[1]
limits_cache = sys.argv[2]
events_file = sys.argv[3]
statusline_dir = sys.argv[4]
quick_mode = sys.argv[5] == '1'

home = os.path.expanduser('~')

# ─── Statusline reader ─────────────────────────────────────────

def read_statusline(pid):
    """Read /tmp/claude-statusline-<pid> key=value file."""
    path = os.path.join(statusline_dir, f"claude-statusline-{pid}")
    metrics = {}
    if not os.path.exists(path):
        return metrics
    try:
        with open(path, 'r') as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    k, _, v = line.partition('=')
                    metrics[k.strip()] = v.strip()
    except OSError:
        pass
    return metrics

# ─── Context remaining % reader ────────────────────────────────

def read_context_remaining(pid):
    """Read /tmp/claude-ctx-<pid> for context window remaining %."""
    path = os.path.join(statusline_dir, f"claude-ctx-{pid}")
    try:
        if os.path.exists(path):
            with open(path, 'r') as f:
                val = f.read().strip()
                if val:
                    return val
    except OSError:
        pass
    return ''

# ─── Transcript path reader ────────────────────────────────────

def read_transcript_path(pid):
    """The transcript this PID actually owns, or '' if we can't tell.

    Claude Code hands the statusline its own transcript_path on every render,
    and statusline.sh forwards it to /tmp/claude-tpath-<pid>. That makes this
    the only PID→session mapping we don't have to guess at: it comes from the
    process itself, not from what happens to be newest on disk.

    Worth trusting over any cwd-derived answer, because a single cwd routinely
    hosts several concurrent sessions (~/.claude does) and they are otherwise
    indistinguishable from the outside.
    """
    path = os.path.join(statusline_dir, f"claude-tpath-{pid}")
    try:
        with open(path, 'r') as f:
            tpath = f.read().strip()
    except OSError:
        return ''
    # A dead session's file lingers until its daemon reaps it; requiring the
    # transcript to still exist keeps a stale pointer from winning.
    if tpath.endswith('.jsonl') and os.path.exists(tpath):
        return tpath
    return ''

# ─── Tab title reader ──────────────────────────────────────────

def read_tab_title(session_id):
    """Read tab title from /tmp/claude-tab-topic-<uuid> files.

    Tab topic files use the Claude session UUID as the key.
    We try to match by reading .session_id companion files.
    """
    if not session_id:
        return ''

    # Strategy: scan /tmp/claude-tab-topic-*.session_id files for matching session
    # Then read the corresponding topic file
    try:
        for f in os.listdir('/tmp'):
            if f.startswith('claude-tab-topic-') and f.endswith('.session_id'):
                sid_path = os.path.join('/tmp', f)
                try:
                    with open(sid_path, 'r') as sf:
                        stored_sid = sf.read().strip()
                    if stored_sid == session_id:
                        # Found match — read the topic file
                        topic_base = f[:-len('.session_id')]
                        topic_path = os.path.join('/tmp', topic_base)
                        if os.path.exists(topic_path):
                            with open(topic_path, 'r') as tf:
                                return tf.read().strip()[:60]
                except OSError:
                    continue
    except OSError:
        pass
    return ''

# ─── Per-cwd git enrichment ────────────────────────────────────
#
# Two cheap git lookups per FULL scan (skipped on --quick):
#   - branch name: `git rev-parse --abbrev-ref HEAD`  — ~5ms
#   - modified-file count: `git status --porcelain | wc -l` — ~10–30ms
#
# Both fail silently if the cwd isn't a git repo (returns empty/0).
#
# Cached per cwd within a single scan invocation so we don't shell out
# multiple times when the same project hosts multiple live instances.

_git_cache = {}

def git_branch(cwd):
    if not cwd or not os.path.isdir(cwd): return ''
    if cwd in _git_cache and 'branch' in _git_cache[cwd]:
        return _git_cache[cwd]['branch']
    try:
        r = subprocess.run(
            ['git', '-C', cwd, 'rev-parse', '--abbrev-ref', 'HEAD'],
            capture_output=True, text=True, timeout=2
        )
        out = r.stdout.strip() if r.returncode == 0 else ''
        # 'HEAD' from a detached state isn't useful; treat as empty.
        if out == 'HEAD': out = ''
    except (subprocess.TimeoutExpired, OSError):
        out = ''
    _git_cache.setdefault(cwd, {})['branch'] = out
    return out

def git_modified_count(cwd):
    if not cwd or not os.path.isdir(cwd): return 0
    if cwd in _git_cache and 'modified' in _git_cache[cwd]:
        return _git_cache[cwd]['modified']
    try:
        r = subprocess.run(
            ['git', '-C', cwd, 'status', '--porcelain'],
            capture_output=True, text=True, timeout=2
        )
        n = len([l for l in r.stdout.splitlines() if l.strip()]) if r.returncode == 0 else 0
    except (subprocess.TimeoutExpired, OSError):
        n = 0
    _git_cache.setdefault(cwd, {})['modified'] = n
    return n

# ─── Last user prompt extraction ───────────────────────────────
#
# Walks the JSONL backwards looking for the most recent `type: user`
# message with non-empty text content. Returns the first 80 chars so the
# bar can render it inline as a "what is this session asking about" hint.
# Skips Task-tool sidechain user messages (those are agent prompts, not
# the human's typed prompt).

# ─── Permission mode + last tool from JSONL ──────────────────
#
# Two pieces of information surfaced from the transcript:
#   - permission_mode: latest "type":"permission-mode" event's value
#     (auto / plan / default / etc.). Useful for safety scanning.
#   - last_tool: the most recent tool_use block plus its primary target
#     (file_path / command preview) plus seconds since it ran. Drives
#     the "last: Edit src/foo.tsx · 4s ago" hint line on idle rows.
#
# Both walk the same JSONL once; bundled into a single function for
# efficiency (one open(), one parse pass).

def parse_jsonl_state(filepath):
    """Returns (permission_mode, last_tool_dict) extracted from the
    transcript JSONL. last_tool_dict shape:
        {'name': str, 'target': str, 'ago_seconds': int}
    Either field may be None if the JSONL doesn't yield it.
    """
    if not filepath or not os.path.isfile(filepath):
        return (None, None)
    perm = None
    last_tool = None
    last_tool_ts = None
    try:
        with open(filepath, 'r', errors='replace') as f:
            data = f.read()
        for line in data.splitlines():
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            t = obj.get('type', '')
            if t == 'permission-mode':
                pm = obj.get('permissionMode', '')
                if pm: perm = pm
                continue
            if t == 'assistant' and not obj.get('isSidechain'):
                msg = obj.get('message', {})
                if not isinstance(msg, dict): continue
                for block in msg.get('content', []):
                    if not isinstance(block, dict): continue
                    if block.get('type') != 'tool_use': continue
                    name = block.get('name', '?')
                    inp  = block.get('input', {}) if isinstance(block.get('input'), dict) else {}
                    # Primary target per tool — same logic as detail.sh
                    if name == 'Bash':
                        target = (inp.get('command') or '').replace('\n', ' ')[:60]
                    elif name in ('Read', 'Write', 'Edit'):
                        target = inp.get('file_path') or ''
                    elif name == 'Grep':
                        target = inp.get('pattern') or ''
                    elif name == 'Glob':
                        target = inp.get('pattern') or ''
                    elif name == 'WebFetch':
                        target = inp.get('url') or ''
                    elif name in ('Task', 'Agent'):
                        target = (inp.get('description') or inp.get('prompt') or '')[:60]
                    elif name == 'TodoWrite':
                        target = f"{len(inp.get('todos', []))} item(s)"
                    else:
                        # Fallback: first non-empty string field
                        target = ''
                        for v in inp.values():
                            if isinstance(v, str) and v: target = v[:60]; break
                    ts = obj.get('timestamp', '')
                    last_tool = {'name': name, 'target': target[:80]}
                    last_tool_ts = ts
        # Compute ago_seconds from the last-tool timestamp.
        if last_tool and last_tool_ts:
            try:
                # ISO8601 → epoch
                from datetime import datetime, timezone
                dt = datetime.fromisoformat(last_tool_ts.replace('Z', '+00:00'))
                ago = int((datetime.now(timezone.utc) - dt).total_seconds())
                last_tool['ago_seconds'] = max(0, ago)
            except Exception:
                last_tool['ago_seconds'] = 0
        return (perm, last_tool)
    except OSError:
        return (None, None)

def last_user_prompt(filepath):
    if not filepath or not os.path.isfile(filepath):
        return ''
    try:
        # Reading the whole file: typical session JSONL is <2MB, parse is ~10ms.
        # Tail-only scanning miss-fires when the recent window is all
        # tool_result messages and the human's last actual prompt is deeper.
        with open(filepath, 'r', errors='replace') as f:
            data = f.read()
        last_text = ''
        for line in data.splitlines():
            try:
                obj = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if obj.get('type') != 'user' or obj.get('isSidechain'):
                continue
            msg = obj.get('message', {})
            text = ''
            if isinstance(msg, dict):
                for block in msg.get('content', []):
                    if isinstance(block, dict) and block.get('type') == 'text':
                        text += block.get('text', '')
                    elif isinstance(block, str):
                        text += block
            elif isinstance(msg, str):
                text = msg
            # Strip <system-reminder> wrappers — those aren't human prompts.
            text = re.sub(r'<system-reminder>.*?</system-reminder>', '', text, flags=re.DOTALL).strip()
            if text:
                last_text = text  # keep updating; we want the LAST one
        if not last_text: return ''
        last = ' '.join(last_text.split())
        return last[:80] + ('…' if len(last) > 80 else '')
    except OSError:
        return ''

# ─── Subagent counter ──────────────────────────────────────────

def count_subagents(pid):
    """Count running child claude processes (subagents) for a PID."""
    try:
        result = subprocess.run(
            ['pgrep', '-P', str(pid), '-f', 'claude'],
            capture_output=True, text=True, timeout=2
        )
        if result.returncode == 0 and result.stdout.strip():
            return len(result.stdout.strip().split('\n'))
    except (subprocess.TimeoutExpired, OSError):
        pass
    return 0

# ─── Session state inference ───────────────────────────────────

def infer_session_state(filepath, pid):
    """Read last few JSONL entries to infer current session state.

    Returns: {'state': str, 'detail': str}
    States: thinking, responding, tool_use, tool_result, idle
    """
    result = {'state': 'idle', 'detail': ''}
    if not filepath or not os.path.exists(filepath):
        return result

    try:
        size = os.path.getsize(filepath)
        if size == 0:
            return result

        # Read last 8KB for recent entries
        with open(filepath, 'rb') as f:
            f.seek(max(0, size - 8192))
            if size > 8192:
                f.readline()  # skip partial line
            tail = f.read().decode('utf-8', errors='replace')

        # Parse last 3 valid JSON lines
        lines = [l.strip() for l in tail.strip().split('\n') if l.strip()]
        entries = []
        for line in reversed(lines):
            try:
                obj = json.loads(line)
                entries.append(obj)
                if len(entries) >= 3:
                    break
            except json.JSONDecodeError:
                continue

        if not entries:
            return result

        last = entries[0]
        msg_type = last.get('type', '')

        if msg_type == 'user':
            result['state'] = 'thinking'
            result['detail'] = 'processing prompt...'
        elif msg_type == 'assistant':
            msg = last.get('message', {})
            content = msg.get('content', [])
            # Check if last content block is tool_use
            if isinstance(content, list) and content:
                last_block = content[-1] if content else {}
                if isinstance(last_block, dict):
                    if last_block.get('type') == 'tool_use':
                        tool_name = last_block.get('name', '?')
                        tool_input = last_block.get('input', {})
                        detail = tool_name
                        # Extract useful detail per tool type
                        if tool_name in ('Read', 'Edit', 'Write', 'Glob', 'Grep'):
                            fp = tool_input.get('file_path', '') or tool_input.get('path', '') or tool_input.get('pattern', '')
                            if fp:
                                fp = fp.replace(home, '~')
                                if len(fp) > 35:
                                    fp = '...' + fp[-32:]
                                detail = f"{tool_name}: {fp}"
                        elif tool_name == 'Bash':
                            cmd = tool_input.get('command', '')[:40]
                            if cmd:
                                detail = f"Bash: {cmd}"
                        elif tool_name == 'Agent':
                            desc = tool_input.get('description', '')[:30]
                            detail = f"Agent: {desc}" if desc else 'Agent'
                        result['state'] = 'tool_use'
                        result['detail'] = detail
                    elif last_block.get('type') == 'text':
                        result['state'] = 'responding'
                        text = last_block.get('text', '')
                        if len(text) > 40:
                            result['detail'] = text[:37] + '...'
                        else:
                            result['detail'] = text[:40]
                    else:
                        result['state'] = 'responding'
                else:
                    result['state'] = 'responding'
            else:
                result['state'] = 'responding'
        elif msg_type == 'tool_result':
            result['state'] = 'tool_result'
            result['detail'] = 'processing result...'

    except OSError:
        pass

    return result

# ─── Session JSONL token aggregator ─────────────────────────────

# Cost rates per million tokens
COST_RATES = {
    'opus': (15.0, 75.0),
    'sonnet': (3.0, 15.0),
    'haiku': (0.25, 1.25),
}

def estimate_cost(model_short, input_tokens, output_tokens):
    rate_in, rate_out = COST_RATES.get(model_short, (0, 0))
    if input_tokens > 0 or output_tokens > 0:
        return round((input_tokens * rate_in + output_tokens * rate_out) / 1_000_000, 4)
    return 0.0

def _resolve_session_path(pid, cwd, prefer_sid=''):
    """Which transcript belongs to this PID? Absolute path, or '' if unknown.

    Three sources, best first:

      1. What the process itself reported — see read_transcript_path().
      2. An explicit `--resume <id>`, when that transcript is in this project.
      3. The newest transcript in the cwd's project dir.

    Source 3 is a guess and is wrong whenever one cwd hosts several live
    sessions: every one of them resolves to the same newest file, so the same
    conversation is rendered once per process while the others vanish. It stays
    only as a last resort, for a session whose statusline has never rendered.
    """
    tpath = read_transcript_path(pid)
    if tpath:
        return tpath

    if not cwd or not os.path.isdir(projects_dir):
        return ''

    # Derive project slug from CWD
    slug = re.sub(r'[/.]', '-', cwd).lstrip('-')
    proj_dir = os.path.join(projects_dir, '-' + slug)
    if not os.path.isdir(proj_dir):
        proj_dir = os.path.join(projects_dir, slug)
    if not os.path.isdir(proj_dir):
        return ''

    jsonl_files = []
    try:
        for f in os.listdir(proj_dir):
            if f.endswith('.jsonl') and not f.startswith('.'):
                full = os.path.join(proj_dir, f)
                jsonl_files.append((os.path.getmtime(full), full))
    except OSError:
        return ''
    if not jsonl_files:
        return ''

    jsonl_files.sort(reverse=True)
    if prefer_sid:
        for _, full in jsonl_files:
            if Path(full).stem == prefer_sid:
                return full
    return jsonl_files[0][1]

def get_session_tokens(pid, cwd, prefer_sid=''):
    """Find the active session JSONL for a PID and aggregate token usage."""
    result = {'model': 'unknown', 'input_tokens': 0, 'output_tokens': 0,
              'cache_read': 0, 'cache_create': 0, 'cost_usd': 0.0,
              'session_id': '', 'turns': 0, 'tool_calls': 0,
              'jsonl_path': ''}

    filepath = _resolve_session_path(pid, cwd, prefer_sid)
    if not filepath:
        return result
    result['session_id'] = Path(filepath).stem
    result['jsonl_path'] = filepath

    # Read the file — aggregate usage from assistant messages
    # For large files, only read last 500KB for speed
    try:
        size = os.path.getsize(filepath)
        lines = []
        if size > 500_000:
            with open(filepath, 'rb') as f:
                f.seek(max(0, size - 500_000))
                f.readline()  # skip partial line
                lines = f.read().decode('utf-8', errors='replace').splitlines()
        else:
            with open(filepath, 'r', errors='replace') as f:
                lines = f.readlines()

        turn_count = 0
        tool_call_count = 0
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get('type', '')
            if msg_type == 'assistant':
                turn_count += 1
                msg = obj.get('message', {})
                model = msg.get('model', '')
                if model:
                    result['model'] = model
                usage = msg.get('usage', {})
                if usage:
                    result['input_tokens'] += usage.get('input_tokens', 0)
                    result['output_tokens'] += usage.get('output_tokens', 0)
                    result['cache_read'] += usage.get('cache_read_input_tokens', 0)
                    result['cache_create'] += usage.get('cache_creation_input_tokens', 0)
                # Count tool_use blocks in content
                content = msg.get('content', [])
                if isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get('type') == 'tool_use':
                            tool_call_count += 1

        result['turns'] = turn_count
        result['tool_calls'] = tool_call_count

    except OSError:
        pass

    return result

# ─── Provider interface ──────────────────────────────────────────
#
# Every agentic CLI this scanner watches (claude today, codex, aider/
# antigravity later) plugs in as one dict of four capabilities. Adding a new
# runtime means writing these four functions and appending to PROVIDERS.
# One residual seam: get_live_instances still routes claude-specific
# enrichment (statusline metrics, token files) by provider name — a new
# provider gets the generic path until that enrichment is lifted into the
# provider dict.
#
#   name            stamped onto every instance/session this provider yields
#   proc_match      (argv0_basename, cmdline) -> bool: is this ps line ours?
#   transcript_iter () -> iterator of this provider's session file paths
#   parse_session   (path) -> summary dict, or None if unreadable/foreign
#   proc_meta       (cmdline) -> {'model_hint': str, 'resume_id': str}

def claude_proc_match(basename, cmdline):
    """Main claude CLI only: argv[0]'s basename is exactly 'claude', whether
    invoked bare (`claude …`) or by absolute path (`/…/.local/bin/claude …`,
    which is how the gcc-schedule launcher execs it). Basename-matching
    excludes claude-ipc / claude-instances-bar / other `claude-*` helpers.
    """
    if basename != 'claude':
        return False
    return not any(skip in cmdline for skip in ('emit-event', 'hook', 'esbuild', 'server.js'))

def claude_proc_meta(cmdline):
    model_hint = 'unknown'
    if '--model' in cmdline:
        m = re.search(r'--model\s+(\S+)', cmdline)
        if m:
            model_hint = m.group(1)
    resume_id = ''
    if '--resume' in cmdline:
        m = re.search(r'--resume\s+(\S+)', cmdline)
        if m:
            resume_id = m.group(1)
    return {'model_hint': model_hint, 'resume_id': resume_id}

def claude_transcript_iter():
    """Yield every claude session transcript path (~/.claude/projects/*/*.jsonl)."""
    if not os.path.isdir(projects_dir):
        return
    for root, dirs, files in os.walk(projects_dir):
        for f in files:
            if f.endswith('.jsonl') and not f.startswith('.'):
                yield os.path.join(root, f)

def claude_parse_session(filepath):
    """Read one claude transcript's summary stats for the history list: model,
    a rough turn count (every JSONL line, matching this scanner's long-
    standing convention elsewhere), and the final assistant message's token
    usage. Read-once and cheap — history only needs a summary, not the full
    per-session aggregation get_session_tokens() does for live instances.
    """
    model = 'unknown'
    turn_count = 0
    total_input = 0
    total_output = 0
    last_line = ''
    try:
        with open(filepath, 'r', errors='replace') as f:
            first_lines = []
            for i, line in enumerate(f):
                if i < 50:
                    first_lines.append(line.strip())
                turn_count += 1
                last_line = line.strip()

        for line in first_lines:
            try:
                obj = json.loads(line)
                msg_type = obj.get('type', '')
                if msg_type == 'assistant':
                    m = obj.get('message', {}).get('model', '')
                    if m:
                        model = m
                        break
                elif msg_type == 'result':
                    # obj['result'] is usually the result TEXT (a str), not a
                    # dict — guard before .get() or it throws AttributeError.
                    res = obj.get('result')
                    m = obj.get('model', '') or (res.get('model', '') if isinstance(res, dict) else '')
                    if m:
                        model = m
                        break
                elif msg_type == 'system' and obj.get('model'):
                    model = obj['model']
                    break
            except json.JSONDecodeError:
                pass

        if last_line:
            try:
                obj = json.loads(last_line)
                if obj.get('type') == 'assistant':
                    usage = obj.get('message', {}).get('usage', {})
                    total_input = usage.get('input_tokens', 0)
                    total_output = usage.get('output_tokens', 0)
            except json.JSONDecodeError:
                pass
    except OSError:
        return None

    return {
        'id': Path(filepath).stem,
        'model': model,
        'turns': turn_count,
        'tokens_in': total_input,
        'tokens_out': total_output,
    }

def codex_proc_match(basename, cmdline):
    return basename == 'codex'

def codex_proc_meta(cmdline):
    # codex doesn't expose --model/--resume on argv the way claude does;
    # the session_meta line (read once the transcript is found) is the real
    # source for model info — see codex_parse_session.
    return {'model_hint': 'unknown', 'resume_id': ''}

def codex_transcript_iter():
    """Yield codex rollout transcript paths from the last 14 days of date shards.

    Codex shards sessions by day (YYYY/MM/DD/rollout-*.jsonl); an unbounded
    walk would grow with the user's entire codex history, so this caps to a
    recent window matching the "recent sessions" framing get_session_history
    already applies to claude via max_sessions.
    """
    base = os.path.join(home, '.codex', 'sessions')
    if not os.path.isdir(base):
        return
    now = datetime.now(timezone.utc)
    for days_back in range(15):
        day = now - timedelta(days=days_back)
        shard = os.path.join(base, day.strftime('%Y'), day.strftime('%m'), day.strftime('%d'))
        if not os.path.isdir(shard):
            continue
        try:
            for f in os.listdir(shard):
                if f.startswith('rollout-') and f.endswith('.jsonl'):
                    yield os.path.join(shard, f)
        except OSError:
            continue

def codex_parse_session(filepath):
    """Read a codex rollout's session_meta (line 1 — session id/cwd/model
    come free, no scanning needed) plus a cheap one-pass tally of assistant
    turns and tool calls from the rest of the file.

    Unlike claude (one project dir per cwd), codex shards by date — so
    `project_display` here comes from the payload's actual cwd, not the
    containing directory name (which would just be a date like "05").
    """
    session_id, cwd = '', ''
    model_provider, cli_version = '', ''
    turns = 0
    tool_calls = 0
    try:
        with open(filepath, 'r', errors='replace') as f:
            try:
                meta = json.loads(f.readline())
            except json.JSONDecodeError:
                return None
            if meta.get('type') != 'session_meta':
                return None
            payload = meta.get('payload') or {}
            session_id = payload.get('session_id', '') or Path(filepath).stem
            cwd = payload.get('cwd', '') or ''
            model_provider = payload.get('model_provider', '')
            cli_version = payload.get('cli_version', '')

            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get('type') != 'response_item':
                    continue
                p = obj.get('payload') or {}
                ptype = p.get('type', '')
                if ptype == 'message' and p.get('role') == 'assistant':
                    turns += 1
                elif ptype in ('function_call', 'custom_tool_call'):
                    tool_calls += 1
    except OSError:
        return None

    if not session_id:
        return None

    segs = [s for s in cwd.split('/') if s]
    project_display = '/'.join(segs[-2:]) if segs else cwd

    return {
        'id': session_id,
        'cwd': cwd,
        'model': f"{model_provider}/{cli_version}" if (model_provider or cli_version) else 'unknown',
        'turns': turns,
        'tool_calls': tool_calls,
        'tokens_in': 0,
        'tokens_out': 0,
        'project_display': project_display,
    }

claude_provider = {
    'name': 'claude',
    'proc_match': claude_proc_match,
    'transcript_iter': claude_transcript_iter,
    'parse_session': claude_parse_session,
    'proc_meta': claude_proc_meta,
}

codex_provider = {
    'name': 'codex',
    'proc_match': codex_proc_match,
    'transcript_iter': codex_transcript_iter,
    'parse_session': codex_parse_session,
    'proc_meta': codex_proc_meta,
}

PROVIDERS = [claude_provider, codex_provider]

# ─── Live instances ──────────────────────────────────────────────

# ── claude-ipc join (A1) ─────────────────────────────────────────────────────
# ipc is Claude's agent-to-agent messaging layer; this widget is the HUMAN's
# monitoring surface. They share one key: the session UUID. So we join ipc's view
# of a session (its alias + unread mail) onto each live instance the human sees —
# read-only, optional, and it NEVER breaks the scan if ipc is absent.
#
# Alias comes from the canonical per-session SIDE-FILE (~/.claude-ipc/alias-by-sid/
# <uuid>), NOT a reverse-map of the broker registry: a sub-agent that registers an
# ipc alias inherits the parent's session UUID, so the registry can hold several
# aliases for one UUID (a known ipc flaw). The side-file is the session's own,
# authoritative alias.
#
# We deliberately do NOT report the broker's liveness/status: it is heartbeat-based
# and goes stale for a session in a long turn (reads "offline" while actively
# working). This widget's own process-liveness is more accurate — closing that gap
# by feeding it back to the broker is Direction B.
_IPC_BIN = os.path.expanduser('~/Code/Claude/claude-ipc/dist/claude-ipc')
_IPC_ALIAS_DIR = os.path.expanduser('~/.claude-ipc/alias-by-sid')

def _ipc_inbox_count(alias):
    try:
        r = subprocess.run([_IPC_BIN, 'count', alias], capture_output=True, text=True, timeout=2)
        digits = ''.join(ch for ch in (r.stdout or '') if ch.isdigit())
        return int(digits) if digits else 0
    except Exception:
        return 0

def get_ipc_info(session_id, quick):
    """This session's ipc identity for the human's widget: its alias (canonical,
    from the side-file) and unread mail count (full-scan only). None if the session
    isn't on ipc. Broker liveness is intentionally omitted — the widget's own
    process-liveness is truer (Direction B)."""
    if not session_id or not os.path.exists(_IPC_BIN):
        return None
    try:
        with open(os.path.join(_IPC_ALIAS_DIR, session_id)) as f:
            alias = f.read().strip()
    except OSError:
        return None
    if not alias:
        return None
    out = {'alias': alias}
    if not quick:
        out['inbox'] = _ipc_inbox_count(alias)
    return out


def _build_claude_instance(pid, cmdline, provider):
    """Build the full live-instance row for a matched claude process —
    everything downstream of proc_match (cwd, tokens, git, tab title, ...).
    """
    pid_str = str(pid)
    meta = provider['proc_meta'](cmdline)
    model_flag = meta['model_hint']
    resume_id = meta['resume_id']

    # Get CWD via lsof
    cwd = ''
    try:
        lsof = subprocess.run(
            ['lsof', '-p', pid_str, '-d', 'cwd', '-Fn'],
            capture_output=True, text=True, timeout=2
        )
        lines = lsof.stdout.split('\n')
        target_marker = f'p{pid_str}'
        found_pid = False
        for lline in lines:
            if lline == target_marker:
                found_pid = True
            elif found_pid and lline.startswith('n/'):
                cwd = lline[1:]
                break
            elif found_pid and lline.startswith('p'):
                break
    except (subprocess.TimeoutExpired, OSError):
        pass

    # Get elapsed time
    elapsed = '?'
    try:
        ps_result = subprocess.run(
            ['ps', '-p', pid_str, '-o', 'etime='],
            capture_output=True, text=True, timeout=2
        )
        elapsed = ps_result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError):
        pass

    # Read statusline metrics
    statusline = read_statusline(pid)

    # Read context remaining %
    ctx_remaining = read_context_remaining(pid)

    # Get session tokens and model from JSONL
    session_data = get_session_tokens(pid, cwd, prefer_sid=resume_id)
    if model_flag == 'unknown' and session_data['model'] != 'unknown':
        model_flag = session_data['model']

    # Read tab title
    tab_title = read_tab_title(session_data['session_id'])

    # Count subagents
    subagent_count = count_subagents(pid)

    # Git enrichment + last user prompt + permission mode + last tool
    # — full-scan only (skipped on --quick to keep the 5s tick fast).
    if not quick_mode:
        jsonl_path     = session_data.get('jsonl_path', '')
        branch         = git_branch(cwd)
        modified_files = git_modified_count(cwd)
        last_prompt    = last_user_prompt(jsonl_path)
        perm_mode, last_tool_info = parse_jsonl_state(jsonl_path)
    else:
        branch, modified_files, last_prompt = '', 0, ''
        perm_mode, last_tool_info = '', None

    # Infer session state
    session_state = infer_session_state(session_data['jsonl_path'], pid)

    # Shorten model name for display
    model_display = model_flag
    if 'opus' in model_flag:
        model_display = 'opus'
    elif 'sonnet' in model_flag:
        model_display = 'sonnet'
    elif 'haiku' in model_flag:
        model_display = 'haiku'

    # Estimate cost
    cost_usd = estimate_cost(model_display,
                              session_data['input_tokens'],
                              session_data['output_tokens'])

    # Shorten CWD for display
    cwd_short = cwd.replace(home, '~') if cwd else '?'

    return {
        'pid': pid,
        'model': model_display,
        'model_full': model_flag,
        'cwd': cwd,
        'cwd_short': cwd_short,
        'elapsed': elapsed,
        'resume_id': resume_id,
        'session_id': session_data['session_id'],
        'input_tokens': session_data['input_tokens'],
        'output_tokens': session_data['output_tokens'],
        'cache_read': session_data['cache_read'],
        'turns': session_data['turns'],
        'tool_calls': session_data['tool_calls'],
        'cost_usd': cost_usd,
        'tab_title': tab_title,
        'subagent_count': subagent_count,
        'session_state': session_state,
        'git_branch': branch,
        'git_modified': modified_files,
        'last_prompt': last_prompt,
        'permission_mode': perm_mode or '',
        'last_tool': last_tool_info,
        'statusline': {
            'cpu': statusline.get('proc_cpu', ''),
            'mem': statusline.get('proc_mem', ''),
            'rss_mb': statusline.get('proc_rss', ''),
            'tok_speed': statusline.get('tok_speed', ''),
            'cost_vel': statusline.get('cost_vel_cpm', ''),
            'mcp_healthy': statusline.get('mcp_healthy', ''),
            'mcp_down': statusline.get('mcp_down', ''),
            'focus_file': statusline.get('focus_file', ''),
            'wal_since_cp': statusline.get('wal_since_checkpoint', ''),
            'ctx_remaining': ctx_remaining,
            'scratchpad_count': statusline.get('scratchpad_count', ''),
            'pm2_online': statusline.get('pm2_online', ''),
            'pm2_errored': statusline.get('pm2_errored', ''),
        },
        'provider': provider['name'],
        'ipc': get_ipc_info(session_data['session_id'], quick_mode),
    }

def _build_codex_instance(pid, cmdline, provider):
    """Minimal live-instance row for a running codex process.

    Codex doesn't have claude's per-pid statusline file or tab-title
    registry, so this stays a thin row (pid, cwd, model) rather than
    forcing codex data through fields it has no source for. Model comes
    from pairing this process's cwd against a recent codex transcript
    (transcript_iter is already capped to 14 days, so this stays cheap).
    """
    pid_str = str(pid)
    meta = provider['proc_meta'](cmdline)

    cwd = ''
    try:
        lsof = subprocess.run(
            ['lsof', '-p', pid_str, '-d', 'cwd', '-Fn'],
            capture_output=True, text=True, timeout=2
        )
        lines = lsof.stdout.split('\n')
        target_marker = f'p{pid_str}'
        found_pid = False
        for lline in lines:
            if lline == target_marker:
                found_pid = True
            elif found_pid and lline.startswith('n/'):
                cwd = lline[1:]
                break
            elif found_pid and lline.startswith('p'):
                break
    except (subprocess.TimeoutExpired, OSError):
        pass

    elapsed = '?'
    try:
        ps_result = subprocess.run(
            ['ps', '-p', pid_str, '-o', 'etime='],
            capture_output=True, text=True, timeout=2
        )
        elapsed = ps_result.stdout.strip()
    except (subprocess.TimeoutExpired, OSError):
        pass

    model_display = 'unknown'
    session_id = ''
    if cwd:
        for filepath in provider['transcript_iter']():
            parsed = provider['parse_session'](filepath)
            if parsed and parsed.get('cwd') == cwd:
                model_display = parsed.get('model', 'unknown')
                session_id = parsed.get('id', '')
                break

    cwd_short = cwd.replace(home, '~') if cwd else '?'

    return {
        'pid': pid,
        'model': model_display,
        'model_full': model_display,
        'cwd': cwd,
        'cwd_short': cwd_short,
        'elapsed': elapsed,
        'resume_id': meta['resume_id'],
        'session_id': session_id,
        'input_tokens': 0,
        'output_tokens': 0,
        'cache_read': 0,
        'turns': 0,
        'tool_calls': 0,
        'cost_usd': 0.0,
        'tab_title': '',
        'subagent_count': 0,
        'session_state': {'state': 'idle', 'detail': ''},
        'git_branch': git_branch(cwd),
        'git_modified': git_modified_count(cwd),
        'last_prompt': '',
        'permission_mode': '',
        'last_tool': None,
        'statusline': {},
        'provider': provider['name'],
    }

def get_live_instances():
    """Find running agentic-CLI processes (any registered provider) and
    build a live-instance row for each, keyed off one shared `ps` pass.
    """
    instances = []
    try:
        # Enumerate with `ps`, NOT `pgrep -f`: the compiled (Bun) claude binary's
        # argv is not readable through pgrep / KERN_PROCARGS on this machine, so a
        # `pgrep -fl claude` scan silently returns ZERO live sessions (verified
        # 2026-07-06 — `pgrep -f` matched none of a live session's tokens while
        # `ps -o args` showed them). ps reads the accounting args reliably, and
        # doing it once here covers every registered provider.
        result = subprocess.run(
            ['ps', '-Ao', 'pid=,args='],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return instances

        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.strip().split(None, 1)
            if len(parts) < 2:
                continue
            pid_str = parts[0]
            cmdline = parts[1]
            basename = os.path.basename(cmdline.split(None, 1)[0])

            provider = next((p for p in PROVIDERS if p['proc_match'](basename, cmdline)), None)
            if provider is None:
                continue

            pid = int(pid_str)
            if provider['name'] == 'claude':
                instance = _build_claude_instance(pid, cmdline, provider)
            else:
                instance = _build_codex_instance(pid, cmdline, provider)
            if instance:
                instances.append(instance)
    except (subprocess.TimeoutExpired, OSError):
        pass

    return instances

# ─── Session model cache (for event enrichment) ────────────────

_session_model_cache = {}

def get_session_model(session_id):
    """Look up model for a session ID from JSONL first-lines cache."""
    if session_id in _session_model_cache:
        return _session_model_cache[session_id]

    if not os.path.isdir(projects_dir):
        return ''

    # Search all project dirs for this session's JSONL
    try:
        for d in os.listdir(projects_dir):
            path = os.path.join(projects_dir, d, f"{session_id}.jsonl")
            if os.path.exists(path):
                try:
                    with open(path, 'r', errors='replace') as f:
                        for i, line in enumerate(f):
                            if i > 30:
                                break
                            try:
                                obj = json.loads(line.strip())
                                if obj.get('type') == 'assistant':
                                    model = obj.get('message', {}).get('model', '')
                                    if model:
                                        short = model
                                        if 'opus' in model: short = 'opus'
                                        elif 'sonnet' in model: short = 'sonnet'
                                        elif 'haiku' in model: short = 'haiku'
                                        _session_model_cache[session_id] = short
                                        return short
                            except json.JSONDecodeError:
                                continue
                except OSError:
                    pass
                break
    except OSError:
        pass

    _session_model_cache[session_id] = ''
    return ''

# ─── Session history ─────────────────────────────────────────────

def get_session_history(max_sessions=20):
    """Enumerate recent sessions across every registered provider.

    Each provider supplies transcript_iter() (where its session files live)
    and parse_session() (model/turns/tokens out of one file). What's shared
    across providers lives here: recency sort, project-name display, and
    cost estimation.
    """
    sessions = []

    # Each provider's own files, most-recent first — kept separate (instead
    # of merging up front) so a low-volume provider's latest session gets a
    # guaranteed slot below rather than being crowded out of the merged
    # top-N by a high-volume one (many active claude sessions vs. one
    # recent codex session, say).
    per_provider = []
    for provider in PROVIDERS:
        files = []
        for filepath in provider['transcript_iter']():
            try:
                mtime = os.path.getmtime(filepath)
            except OSError:
                continue
            files.append((mtime, filepath, provider))
        files.sort(key=lambda t: t[0], reverse=True)
        if files:
            per_provider.append(files)

    guaranteed = [files[0] for files in per_provider]
    rest = sorted(
        (f for files in per_provider for f in files[1:]),
        key=lambda t: t[0], reverse=True
    )
    remaining = max(0, max_sessions - len(guaranteed))
    all_files = sorted(guaranteed + rest[:remaining], key=lambda t: t[0], reverse=True)

    for mtime, filepath, provider in all_files:
        parsed = provider['parse_session'](filepath)
        if not parsed:
            continue

        session_id = parsed.get('id') or Path(filepath).stem
        model = parsed.get('model', 'unknown')
        turn_count = parsed.get('turns', 0)
        total_input = parsed.get('tokens_in', 0)
        total_output = parsed.get('tokens_out', 0)

        # Project display: providers that can supply one directly (codex —
        # storage is date-sharded, not project-sharded) do so via
        # 'project_display'; claude falls back to decoding the project dir
        # name, same as this scanner has always done.
        project_display = parsed.get('project_display')
        if project_display is None:
            project_dir_name = Path(filepath).parent.name
            project_display = project_dir_name.replace('-', '/')
            if project_display.startswith('/'):
                project_display = project_display[1:]
            segs = [s for s in project_display.split('/') if s]
            if len(segs) > 2:
                project_display = '/'.join(segs[-2:])

        # Shorten model
        model_short = model
        if 'opus' in model:
            model_short = 'opus'
        elif 'sonnet' in model:
            model_short = 'sonnet'
        elif 'haiku' in model:
            model_short = 'haiku'

        cost_usd = estimate_cost(model_short, total_input, total_output)

        # Cache model for event enrichment
        _session_model_cache[session_id] = model_short

        try:
            size = os.path.getsize(filepath)
        except OSError:
            size = 0

        modified = datetime.fromtimestamp(mtime, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

        sessions.append({
            'session_id': session_id,
            'project': project_display,
            'model': model_short,
            'turns': turn_count,
            'modified': modified,
            'size_kb': round(size / 1024, 1) if size else 0,
            'tokens_in': total_input,
            'tokens_out': total_output,
            'cost_usd': cost_usd,
            'provider': provider['name'],
        })

    return sessions

# ─── Recent events ───────────────────────────────────────────────

# Expanded event types
TRACKED_EVENTS = {
    'SessionStart', 'Stop', 'PermissionRequest', 'PostCompact', 'PreCompact',
    'SubagentStart', 'SubagentStop', 'Notification',
    'PostToolUse',
}

# Tool types worth showing in events (skip noisy reads/searches)
NOTABLE_TOOLS = {'Edit', 'Write', 'Bash', 'Agent'}

def get_recent_events(max_events=10, deep_max=50):
    """Get the most recent notable events with model + tab title enrichment."""
    events = []
    if not os.path.exists(events_file):
        return events, []
    try:
        with open(events_file, 'r') as f:
            lines = f.readlines()

        all_events = []
        for line in lines[-500:]:
            try:
                obj = json.loads(line.strip())
                event = obj.get('event', '')
                if event not in TRACKED_EVENTS:
                    continue
                # Filter PostToolUse to only notable tools
                if event == 'PostToolUse':
                    tool = obj.get('tool', '')
                    if tool not in NOTABLE_TOOLS:
                        continue

                sid = obj.get('session_id', '')
                evt = {
                    'ts': obj.get('ts', ''),
                    'event': event,
                    'project': obj.get('project', ''),
                    'session_id': sid,
                    'model': get_session_model(sid) if sid else '',
                    'tab_title': read_tab_title(sid) if sid else '',
                    'tool': obj.get('tool', ''),
                }
                all_events.append(evt)
            except json.JSONDecodeError:
                pass

        # Recent events (for main menu display)
        recent = all_events[-max_events:]
        # Deep events (for submenu)
        deep = all_events[-deep_max:]

        return recent, deep
    except OSError:
        pass
    return [], []

# ─── Aggregates ──────────────────────────────────────────────────

def compute_aggregates(history):
    """Compute today/week session stats and model breakdown."""
    now = datetime.now(timezone.utc)
    today_str = now.strftime('%Y-%m-%d')
    week_ago = (now - timedelta(days=7)).strftime('%Y-%m-%d')

    today_sessions = []
    week_sessions = []
    model_counts = {}

    for s in history:
        mod = s.get('modified', '')[:10]
        model = s.get('model', 'unknown')
        model_counts[model] = model_counts.get(model, 0) + 1

        if mod == today_str:
            today_sessions.append(s)
        if mod >= week_ago:
            week_sessions.append(s)

    def summarize(sessions):
        return {
            'sessions': len(sessions),
            'turns': sum(s.get('turns', 0) for s in sessions),
            'tokens_in': sum(s.get('tokens_in', 0) for s in sessions),
            'tokens_out': sum(s.get('tokens_out', 0) for s in sessions),
            'cost_usd': round(sum(s.get('cost_usd', 0) for s in sessions), 4),
        }

    return {
        'today': summarize(today_sessions),
        'week': summarize(week_sessions),
        'model_breakdown': model_counts,
    }

# ─── Limits ──────────────────────────────────────────────────────

def get_limits():
    if os.path.exists(limits_cache):
        try:
            with open(limits_cache, 'r') as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            pass
    return None

# ─── claudew metrics ─────────────────────────────────────────────

CLAUDEW_EVENTS = os.path.join(home, '.claude', 'claudew', 'events.jsonl')
CLAUDEW_STATE = os.path.join(home, '.claude', 'claudew', 'state')

def get_claudew_metrics():
    """Read claudew lifecycle events and plugin state for widget display."""
    metrics = {
        'recent_exits': [],
        'recovery_attempts': 0,
        'total_exits': 0,
        'last_class': '',
        'enabled_plugins': [],
    }

    # Read host events (last 50 lines)
    if os.path.exists(CLAUDEW_EVENTS):
        try:
            with open(CLAUDEW_EVENTS, 'r') as f:
                lines = f.readlines()
            exits = []
            for line in lines[-50:]:
                try:
                    obj = json.loads(line.strip())
                    if obj.get('event') == 'exit':
                        exits.append({
                            'ts': obj.get('ts', ''),
                            'class': obj.get('class', ''),
                            'exit_code': obj.get('exit_code', 0),
                            'retry': obj.get('retry', 0),
                        })
                except json.JSONDecodeError:
                    continue
            metrics['recent_exits'] = exits[-10:]  # last 10
            metrics['total_exits'] = len(exits)
            metrics['recovery_attempts'] = sum(1 for e in exits if e.get('retry', 0) > 0)
            if exits:
                metrics['last_class'] = exits[-1].get('class', '')
        except OSError:
            pass

    # Read auto-resume plugin state
    resume_exits_path = os.path.join(CLAUDEW_STATE, '00-auto-resume', 'exits.jsonl')
    if os.path.exists(resume_exits_path):
        try:
            with open(resume_exits_path, 'r') as f:
                resume_lines = f.readlines()
            rate_limits = sum(1 for l in resume_lines[-50:]
                              if '"RATE_LIMIT"' in l)
            api_errors = sum(1 for l in resume_lines[-50:]
                             if '"API_ERROR"' in l)
            metrics['rate_limit_exits'] = rate_limits
            metrics['api_error_exits'] = api_errors
        except OSError:
            pass

    # Read enabled plugins from config.toml
    config_path = os.path.join(home, '.claude', 'claudew', 'config.toml')
    if os.path.exists(config_path):
        try:
            with open(config_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('enabled'):
                        # Parse single-line array: enabled = ["00-auto-resume", ...]
                        m = re.search(r'\[(.+)\]', line)
                        if m:
                            raw = m.group(1)
                            plugins = [p.strip().strip('"').strip("'")
                                       for p in raw.split(',') if p.strip()]
                            metrics['enabled_plugins'] = plugins
                        break
        except OSError:
            pass

    return metrics

# ─── Assemble ────────────────────────────────────────────────────

live = get_live_instances()

output = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'live_count': len(live),
    'live': live,
}

if quick_mode:
    # Quick mode: only live data, skip expensive operations
    output['history'] = []
    output['recent_events'] = []
    output['deep_events'] = []
    output['aggregates'] = {'today': {}, 'week': {}, 'model_breakdown': {}}
    # Limits are a trivial file read — always include them
    limits = get_limits()
    if limits:
        output['limits'] = limits
else:
    # Full scan: include everything
    history = get_session_history()
    recent_events, deep_events = get_recent_events()
    limits = get_limits()
    aggregates = compute_aggregates(history)

    output['history'] = history
    output['recent_events'] = recent_events
    output['deep_events'] = deep_events
    output['aggregates'] = aggregates
    if limits:
        output['limits'] = limits

# claudew metrics — lightweight file reads, include in both modes
claudew = get_claudew_metrics()
if claudew.get('total_exits', 0) > 0 or claudew.get('enabled_plugins'):
    output['claudew'] = claudew

print(json.dumps(output))
PYEOF
