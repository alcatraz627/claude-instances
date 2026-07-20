#!/usr/bin/env bash
# scan.sh — enumerate live Claude Code instances + recent session history.
#
# Output: JSON to stdout with structure:
#   { "live": [...], "history": [...], "limits": {...}, "aggregates": {...} }
#
# Live instances: discovered via pgrep + process info + statusline metrics.
# History: enumerated from ~/.claude/projects/*/*.jsonl.
# Limits: read from cached ~/.claude/widgets/.limits.json if present.
# Aggregates: today/week session stats, model breakdown — computed over the
#   full window via the ~/.claude/widgets/.session-summaries.json cache, not
#   over the 20-row display list.
#
# Flags:
#   --quick   Skip history, events, aggregates (fast path for 5s polling)

set -uo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
LIMITS_CACHE="${HOME}/.claude/widgets/.limits.json"
EVENTS_FILE="${HOME}/.claude/events.jsonl"
STATUSLINE_DIR="/tmp"
SUMMARY_CACHE="${HOME}/.claude/widgets/.session-summaries.json"
QUICK_MODE=0
[[ "${1:-}" == "--quick" ]] && QUICK_MODE=1

python3 - "$PROJECTS_DIR" "$LIMITS_CACHE" "$EVENTS_FILE" "$STATUSLINE_DIR" "$QUICK_MODE" "$SUMMARY_CACHE" <<'PYEOF'
import sys, json, os, subprocess, re, math
from datetime import datetime, timezone, timedelta
from pathlib import Path

projects_dir = sys.argv[1]
limits_cache = sys.argv[2]
events_file = sys.argv[3]
statusline_dir = sys.argv[4]
quick_mode = sys.argv[5] == '1'
# Absent (probe contexts that predate it) means no persistence: the aggregate
# walk still works, it just re-parses every scan.
summary_cache = sys.argv[6] if len(sys.argv) > 6 else ''

home = os.path.expanduser('~')

# ─── Per-PID /tmp readers ──────────────────────────────────────
#
# A live session's daemon writes several small files to /tmp keyed by the
# claude process's pid. They are the only honest source for what a process is
# doing, and they are also untrusted input: /tmp is world-writable, so anything
# could be sitting at one of those paths.

def read_pid_file(pid, kind):
    """The contents of /tmp/claude-<kind>-<pid>, or '' if there isn't one.

    Every caller goes through here because of one trap: opening a FIFO blocks
    forever waiting for a writer, and a scan that blocks takes the whole
    dashboard down with it. os.path.exists() is True for a FIFO — only isfile()
    rules one out — so the obvious guard is no guard at all.
    """
    path = os.path.join(statusline_dir, f"claude-{kind}-{pid}")
    if not os.path.isfile(path):
        return ''
    try:
        with open(path, 'r') as f:
            return f.read()
    except OSError:
        return ''

def read_statusline(pid):
    """The daemon's key=value metrics for this pid (cpu, mem, mcp health, ...)."""
    metrics = {}
    for line in read_pid_file(pid, 'statusline').splitlines():
        line = line.strip()
        if '=' in line:
            k, _, v = line.partition('=')
            metrics[k.strip()] = v.strip()
    return metrics

def read_context_remaining(pid):
    """How much of this session's context window is left, as a percentage string."""
    return read_pid_file(pid, 'ctx').strip()

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
    tpath = read_pid_file(pid, 'tpath').strip()
    # A dead session's file lingers until its daemon reaps it; requiring the
    # transcript to still exist keeps a stale pointer from winning. And a
    # pointer file OLDER than the process itself cannot have come from this
    # process — that is a reused pid wearing its predecessor's tpath. The
    # process age is already primed (one batched ps per scan), so this costs
    # nothing extra.
    elapsed = _etime_seconds(_proc_elapsed.get(str(pid), ''))
    if elapsed is not None:
        try:
            f_mtime = os.path.getmtime(os.path.join(statusline_dir, f"claude-tpath-{pid}"))
            if f_mtime < datetime.now().timestamp() - elapsed - 120:
                return ''
        except OSError:
            pass
    if tpath.endswith('.jsonl') and os.path.isfile(tpath):
        return tpath
    return ''

def _etime_seconds(etime):
    """ps etime ('[[dd-]hh:]mm:ss') as seconds, or None if unparseable."""
    m = re.match(r'^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$', (etime or '').strip())
    if not m:
        return None
    d, h, mn, s = (int(x) if x else 0 for x in m.groups())
    return ((d * 24 + h) * 60 + mn) * 60 + s

# ─── Cost reader ───────────────────────────────────────────────

def read_cost(pid):
    """What this session has actually cost so far, or None if it hasn't said.

    Claude Code knows its own running total and hands it to the statusline,
    which forwards it to /tmp/claude-cost-<pid> (statusline.sh:771). That is the
    real number. estimate_cost() below only guesses from token counts against a
    rate table that cannot know every model, so prefer this whenever it exists.
    """
    try:
        val = float(read_pid_file(pid, 'cost').strip())
    except ValueError:
        return None
    # float() also accepts 'inf' and 'nan'. An infinite cost would serialize as
    # the bare literal Infinity, which is not JSON — it would take down every
    # consumer of this scan, not just one card. A negative total is garbage too.
    if not math.isfinite(val) or val < 0:
        return None
    return val

# ─── Tab title reader ──────────────────────────────────────────

_tab_topics = None

def read_tab_title(session_id):
    """Tab title for a session, from the /tmp/claude-tab-topic-* registry.

    The registry is scanned ONCE per process and reused — a scan is a fresh
    process, so it can never go stale across scans. It used to re-list all of
    /tmp per live instance and again per event.
    """
    global _tab_topics
    if not session_id:
        return ''
    if _tab_topics is None:
        _tab_topics = {}
        try:
            for f in os.listdir('/tmp'):
                if not (f.startswith('claude-tab-topic-') and f.endswith('.session_id')):
                    continue
                try:
                    with open(os.path.join('/tmp', f), 'r') as sf:
                        stored_sid = sf.read().strip()
                    topic_path = os.path.join('/tmp', f[:-len('.session_id')])
                    # isfile, not exists: /tmp is world-writable and a FIFO
                    # here would block the scan forever.
                    if stored_sid and os.path.isfile(topic_path):
                        with open(topic_path, 'r') as tf:
                            _tab_topics[stored_sid] = tf.read().strip()[:60]
                except OSError:
                    continue
        except OSError:
            pass
    return _tab_topics.get(session_id, '')

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
def tail_lines(path, n, avg_line=400):
    """The last n lines of a file, without reading the rest of it.

    These logs are append-only and only their tail is ever wanted, but they grow
    without bound — events.jsonl is 26MB and 110k lines here, and reading all of
    it to keep 500 lines cost more than everything else on the fast path put
    together. Seeks back a guessed span and widens if it undershot.
    """
    try:
        size = os.path.getsize(path)
    except OSError:
        return []
    span = min(size, n * avg_line)
    while True:
        try:
            with open(path, 'r', errors='replace') as f:
                f.seek(max(0, size - span))
                if span < size:
                    f.readline()      # drop the partial line the seek landed in
                lines = f.readlines()
        except OSError:
            return []
        if len(lines) >= n or span >= size:
            return lines[-n:]
        span = min(size, span * 4)

# ─── Batched process lookups ───────────────────────────────────
#
# lsof and ps cost far more to start than to answer, so asking once per session
# made the scan's largest expense scale with the number of sessions — 25 spawns,
# 2.7s of a 2.8s scan. These prime one answer for everybody.

_proc_cwds = {}
_proc_elapsed = {}

def prime_process_info(pids):
    """Look up every live pid's cwd and uptime in one lsof and one ps.

    The `-a` matters: lsof ORs its selection flags, so `-p <pids> -d cwd` alone
    means "these pids OR any cwd" and dumps the whole process table — ~2400
    lines for a pid that doesn't exist. `-a` ANDs them into the question we
    actually meant.
    """
    pids = [str(p) for p in pids]
    if not pids:
        return
    want = set(pids)
    try:
        out = subprocess.run(['lsof', '-a', '-p', ','.join(pids), '-d', 'cwd', '-Fn'],
                             capture_output=True, text=True, timeout=10).stdout
        cur = ''
        for line in out.splitlines():
            if line.startswith('p'):
                cur = line[1:]
            elif line.startswith('n/') and cur in want and cur not in _proc_cwds:
                _proc_cwds[cur] = line[1:]
    except (subprocess.TimeoutExpired, OSError):
        pass
    try:
        out = subprocess.run(['ps', '-p', ','.join(pids), '-o', 'pid=,etime='],
                             capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                _proc_elapsed[parts[0].strip()] = parts[1].strip()
    except (subprocess.TimeoutExpired, OSError):
        pass

def token_count(v):
    """A usage number from a transcript, or 0 if it isn't one.

    Transcripts are just files on disk, and json.loads happily turns a bare
    Infinity or NaN into a float. Those survive arithmetic and then serialize
    back out as literals no JSON parser accepts, so one corrupt session would
    take down every consumer of this scan. Anything that isn't a finite number
    counts as nothing.
    """
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    return int(v) if math.isfinite(v) else 0

COST_RATES = {
    'opus': (15.0, 75.0),
    'sonnet': (3.0, 15.0),
    'haiku': (0.25, 1.25),
}

def estimate_cost(model_short, input_tokens, output_tokens):
    """Guess a session's cost from its token counts, or None if we can't.

    None is the important half. Every model outside COST_RATES — fable, a codex
    session, whatever ships next — used to price at $0.00, which is
    indistinguishable from genuinely free and let a $215 session render as free.
    An unknown model must say it is unknown; callers render that, they don't
    total it.

    Matches the family as a whole word, so a full id ('claude-opus-4-8') prices
    the same as the short name a --model flag gives, while a name that merely
    contains one ('octopus') doesn't inherit its rates.
    """
    m = (model_short or '').lower()
    rates = next((r for family, r in COST_RATES.items()
                  if re.search(rf'\b{family}\b', m)), None)
    if rates is None:
        return None
    # json.loads accepts a bare Infinity, so a corrupt transcript's usage counts
    # can arrive as inf and multiply straight through to an infinite cost. That
    # would serialize as the literal Infinity, which is not JSON, and take every
    # consumer of this scan down with it — and via the aggregates it would take
    # every other session's total too, not just the poisoned row.
    if not (math.isfinite(input_tokens) and math.isfinite(output_tokens)):
        return None
    if input_tokens > 0 or output_tokens > 0:
        cost = round((input_tokens * rates[0] + output_tokens * rates[1]) / 1_000_000, 4)
        return cost if math.isfinite(cost) else None
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

    # Every assistant message in the session, streamed.
    #
    # This used to read only the last 500KB, which made these counts a fiction:
    # a transcript is mostly enormous tool_result lines, so on a 58MB session the
    # window held 44 of 4488 turns and shipped that as the total. Reading it all
    # costs ~14ms more per scan (measured across the live sessions, whose
    # transcripts run 1.6-8MB) because the substring check below skips the huge
    # lines without paying json.loads on them — that parse, not the file size,
    # was the expense.
    try:
        turn_count = 0
        tool_call_count = 0
        with open(filepath, 'r', errors='replace') as f:
            for line in f:
                if '"assistant"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # The substring check above also passes a user message that
                # merely says "assistant", so the type still decides.
                if obj.get('type') != 'assistant':
                    continue

                turn_count += 1
                msg = obj.get('message', {})
                model = msg.get('model', '')
                if model:
                    result['model'] = model
                usage = msg.get('usage', {})
                if usage:
                    result['input_tokens'] += token_count(usage.get('input_tokens'))
                    result['output_tokens'] += token_count(usage.get('output_tokens'))
                    result['cache_read'] += token_count(usage.get('cache_read_input_tokens'))
                    result['cache_create'] += token_count(usage.get('cache_creation_input_tokens'))
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
    """Yield every claude session transcript path (~/.claude/projects/<dir>/<sid>.jsonl).

    Top level of each project dir only, deliberately: a session's own
    directory tree holds sub-agent transcripts (<sid>/subagents/**.jsonl).
    Those are workers inside a session, not sessions — recursing counted
    hundreds of them as sessions and their tokens twice.
    """
    if not os.path.isdir(projects_dir):
        return
    try:
        project_dirs = list(os.scandir(projects_dir))
    except OSError:
        return
    for proj in project_dirs:
        if not proj.is_dir():
            continue
        try:
            entries = list(os.scandir(proj.path))
        except OSError:
            continue
        for e in entries:
            if e.is_file() and e.name.endswith('.jsonl') and not e.name.startswith('.'):
                yield e.path

def claude_parse_session(filepath):
    """One finished session's summary for the history list: model, turns, tokens.

    Counts and totals mean the same thing here as they do for a live instance —
    a turn is an assistant message, and the tokens are the session's. They used
    to disagree: this counted every line (so a 102-turn session read as 1089)
    and took its tokens from the last line alone, which is almost always a
    tool_result, so a session that spent 868K output tokens reported zero and
    the day's total read as a couple of thousand.
    """
    model = 'unknown'
    turn_count = 0
    total_input = 0
    total_output = 0
    try:
        first_lines = []
        with open(filepath, 'r', errors='replace') as f:
            for i, line in enumerate(f):
                if i < 50:
                    first_lines.append(line.strip())
                if '"assistant"' not in line:
                    continue
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if obj.get('type') != 'assistant':
                    continue
                turn_count += 1
                usage = (obj.get('message') or {}).get('usage') or {}
                total_input += token_count(usage.get('input_tokens'))
                total_output += token_count(usage.get('output_tokens'))

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
        # The codex format carries no usage keys at all (verified against real
        # rollouts). None means "unknown", which is a different fact from 0
        # ("used nothing") — same doctrine as cost_usd.
        'tokens_in': None,
        'tokens_out': None,
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
# HUB_IPC_BIN lets a scratch hub or an end-to-end test stand in a stub binary
# without touching the live broker (validator-isolation doctrine).
_IPC_BIN = os.environ.get('HUB_IPC_BIN') or os.path.expanduser('~/Code/Claude/claude-ipc/dist/claude-ipc')
_IPC_ALIAS_DIR = os.path.expanduser('~/.claude-ipc/alias-by-sid')

# ── ipc digest consumer (meld bridge, Phase 0) ──────────────────────────────
# The consumer half of the digest contract (docs/20260718-meld-unified-plan.md
# section 5.1/7) exists BEFORE the producer verb ships: the state machine and
# its guards are testable entirely from fixtures, so Phase 2 is only wiring a
# spawn. Doctrine: a payload is untrusted until classified; unknown is never 0.

IPC_CONTRACT_VERSION = 1
IPC_DIGEST_FRESH_S = 30
IPC_DIGEST_STALE_S = 120

def parse_ipc_digest(raw, now_ts=None):
    """Classify a digest payload before any value in it is trusted.

    Returns (state, sessions): state is fresh|stale|skew|unknown, and
    sessions is populated only for fresh/stale. A version outside {N, N-1}
    is SKEW — a distinct fact from unknown, because the operator's fix
    differs (redeploy the stale side vs investigate). Never raises; a bare
    Infinity/NaN in the bytes is poison, not data.
    """
    try:
        d = json.loads(raw, parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
    except (ValueError, TypeError):
        return ('unknown', {})
    if not isinstance(d, dict):
        return ('unknown', {})
    cv = d.get('contract_version')
    if not isinstance(cv, int) or isinstance(cv, bool) \
            or cv not in (IPC_CONTRACT_VERSION, IPC_CONTRACT_VERSION - 1):
        return ('skew', {})
    try:
        dt = datetime.fromisoformat((d.get('ts') or '').replace('Z', '+00:00'))
        now = now_ts if now_ts is not None else datetime.now(timezone.utc).timestamp()
        age = now - dt.timestamp()
    except (ValueError, TypeError, AttributeError):
        return ('unknown', {})
    # A timestamp more than a minute in the future is a lying clock, and a
    # payload past the stale ceiling is history; neither may render as now.
    if age < -60 or age > IPC_DIGEST_STALE_S:
        return ('unknown', {})
    sessions = d.get('sessions')
    if not isinstance(sessions, dict):
        return ('unknown', {})
    return ('fresh' if age <= IPC_DIGEST_FRESH_S else 'stale', sessions)

# ── ipc digest spawn (meld bridge, the wiring onto the consumer above) ───────
# One digest call per distinct project cwd per full scan replaces the
# per-alias `count` subprocess — once the peer's verb answers. Until then the
# verb fast-fails (help + exit 2) and the feature stays DARK: the count path
# below keeps running unchanged, so the card never claims "unreachable" while
# the broker is actually fine. A TIMEOUT is different: the broker consumed our
# budget, so it renders as 'unreachable' and no count attempt is stacked on
# top of the already-spent 2 seconds.

IPC_DIGEST_TIMEOUT_S = 2

# Digest sourcing kill switch: =0 keeps the retired per-alias count path
# (retirement stays reversible; HUB_IPC_OVERLAY=0 below outranks both).
_IPC_DIGEST_ON = os.environ.get('HUB_IPC_DIGEST', '1') != '0'

_ipc_digest_cache = {}   # cwd -> (state, sessions, age_s) for this scan

def _digest_age_s(raw):
    """Age of a digest payload's own timestamp, for the dimmed 'as of Ns'
    render on stale reads. None when the stamp can't be read."""
    try:
        d = json.loads(raw)
        dt = datetime.fromisoformat((d.get('ts') or '').replace('Z', '+00:00'))
        return max(0, int(datetime.now(timezone.utc).timestamp() - dt.timestamp()))
    except (ValueError, TypeError, AttributeError):
        return None

def _ipc_digest_classify(rc, out):
    if rc != 0:
        return ('dark', {}, None)
    state, sessions = parse_ipc_digest(out)
    age = _digest_age_s(out) if state in ('fresh', 'stale') else None
    return (state, sessions, age)

def _ipc_digest_prefetch(cwds):
    """Spawn every digest call at once under ONE shared deadline, so K slow
    cwds cost the scan ~2s total, not 2s each. The cap kills the PROCESS
    GROUP: the CLI is a node tree, and killing only the direct child leaves
    grandchildren holding the pipe past the deadline (macOS has no timeout(1)).
    """
    import signal
    import time as _t
    procs = {}
    for cwd in cwds:
        if not cwd or cwd in _ipc_digest_cache:
            continue
        try:
            procs[cwd] = subprocess.Popen(
                [_IPC_BIN, 'digest', '--project', cwd, '--json'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                text=True, start_new_session=True)
        except OSError:
            _ipc_digest_cache[cwd] = ('dark', {}, None)
    deadline = _t.time() + IPC_DIGEST_TIMEOUT_S
    for cwd, p in procs.items():
        try:
            out, _ = p.communicate(timeout=max(0.05, deadline - _t.time()))
            _ipc_digest_cache[cwd] = _ipc_digest_classify(p.returncode, out)
        except subprocess.TimeoutExpired:
            # killpg by p.pid directly: start_new_session makes the child its
            # own group leader, so its pid IS the pgid — and stays valid while
            # ANY member lives. Resolving getpgid(p.pid) here instead would
            # raise on the child-already-a-zombie case (fast exit, grandchild
            # holding the pipe), skip the kill, and orphan the grandchild.
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass
            try:
                p.communicate(timeout=1)
            except Exception:
                pass
            _ipc_digest_cache[cwd] = ('unreachable', {}, None)

def _ipc_digest_for(cwd):
    if cwd not in _ipc_digest_cache:
        _ipc_digest_prefetch([cwd])
    return _ipc_digest_cache.get(cwd, ('dark', {}, None))

def _nn_int(v, cap):
    """A number from another process is untrusted twice over: right type
    (int, not bool) AND sane range, or it renders as unknown — never as a
    fabricated figure."""
    return v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= cap else None

def _ipc_from_digest(out, state, sess, age):
    """Card fields from a classified digest block (plan section 5.3; wire
    keeps the shipped name 'inbox' where 5.3 says 'unread' — the page reads
    inbox). Values flow only for fresh/stale; the obligations fields render
    only from owed entries that carry a real ask_state, which is what keeps
    them dark until the producer actually ships that field."""
    out['source'] = 'digest'
    out['state'] = state
    if state not in ('fresh', 'stale') or not isinstance(sess, dict):
        out['inbox'] = None
        return out
    if age is not None:
        out['age_s'] = age
    out['inbox'] = _nn_int(sess.get('unread'), 10**6)
    out['waiting_on'] = _nn_int(sess.get('waiting_on'), 10**6)
    out['deadline_s'] = _nn_int(sess.get('oldest_deadline_s'), 10**9)
    role = sess.get('role')
    out['role'] = role if isinstance(role, str) else None
    owed = sess.get('owed')
    if isinstance(owed, list):
        # Known-open-set, not everything-but-terminal: an ask_state this
        # consumer doesn't recognize is ignored until a deliberate contract
        # bump, per the coworker-rebuild freeze in the plan's handshake.
        counted = [e for e in owed if isinstance(e, dict)
                   and e.get('ask_state') in ('open', 'parked')]
        if counted or not owed:
            out['owes'] = len(counted)
            ages = [a for a in (_nn_int(e.get('age_s'), 10**9) for e in counted)
                    if a is not None]
            out['oldest_owed_age_s'] = max(ages) if ages else None
    return out

# Meld Phase 1 kill switch: =0 restores the legacy join shape exactly.
_IPC_OVERLAY = os.environ.get('HUB_IPC_OVERLAY', '1') != '0'

def _ipc_inbox_count(alias):
    """Unread count for an alias, honestly: (count, 'fresh') when the broker
    answered, (None, 'unreachable') when it did not. The old silent 0 made a
    dead broker indistinguishable from an empty inbox — different facts, and
    the card must be able to say which one it is showing.
    """
    try:
        r = subprocess.run([_IPC_BIN, 'count', alias], capture_output=True, text=True, timeout=2)
        if r.returncode != 0:
            return (None, 'unreachable')
        digits = ''.join(ch for ch in (r.stdout or '') if ch.isdigit())
        return (int(digits) if digits else 0, 'fresh')
    except Exception:
        return (None, 'unreachable')

def get_ipc_info(session_id, quick, cwd=''):
    """This session's ipc identity for the human's widget: its alias (canonical,
    from the side-file) and mail state (full-scan only). None if the session
    isn't on ipc. Mail sourcing is a lattice: the digest contract when the
    peer's verb answers, the per-alias count when it doesn't (dark), the
    legacy silent-zero shape under HUB_IPC_OVERLAY=0. The broker's liveness
    opinion never drives the card — it only feeds the disagreement pass."""
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
    if quick:
        return out
    if _IPC_OVERLAY and _IPC_DIGEST_ON and cwd:
        state, sessions, age = _ipc_digest_for(cwd)
        if state != 'dark':
            return _ipc_from_digest(out, state, sessions.get(session_id), age)
    count, cstate = _ipc_inbox_count(alias)
    if _IPC_OVERLAY:
        out['inbox'] = count          # None means the broker didn't say
        out['state'] = cstate
    else:
        out['inbox'] = count or 0     # legacy shape: silent zero, no state
    return out

# ── ipc disagreement pass (plan section 8.4) ─────────────────────────────────

# Both paths take env overrides so a scratch hub or validator run can stub the
# broker without its disagreement records landing in the live ledger.
_IPC_DISAGREE_LOG = os.environ.get('HUB_IPC_DISAGREE_LOG') or os.path.expanduser(
    '~/.claude/widgets/.ipc-disagreements.jsonl')
_IPC_DISAGREE_STATE = os.environ.get('HUB_IPC_DISAGREE_STATE') or os.path.expanduser(
    '~/.claude/widgets/.ipc-disagreement-state.json')

def run_ipc_disagreement_pass(live):
    """Where the two systems' views of liveness differ, say so — never decide.
    The scan's process table is the physical authority; the digest carries
    ipc's heartbeat-based view. Every disagreement lands as one RAW jsonl
    line (the deferred-oracle gate of plan section 13 reads that stream); a
    card is only flagged once the same disagreement holds for 2 consecutive
    scans, so registration races don't flash warnings at the owner.

    Runs only when at least one cwd produced a usable digest this scan — a
    dark or unreachable bridge is no evidence of agreement, so it must not
    reset anyone's streak."""
    usable = {c: v for c, v in _ipc_digest_cache.items()
              if v[0] in ('fresh', 'stale')}
    if not usable:
        return
    live_sids = {i.get('session_id') for i in live if i.get('session_id')}
    events = []   # (sid, pid_truth, claim, kind)
    for cwd, (state, sessions, _age) in usable.items():
        for sid, sess in sessions.items():
            if sid == '_unresolved' or not isinstance(sess, dict):
                continue
            claim = sess.get('liveness_claim')
            if claim not in ('live', 'idle', 'offline'):
                continue
            if sid in live_sids and claim == 'offline':
                events.append((sid, 'live', claim, 'stale-registration'))
            elif sid not in live_sids and claim in ('live', 'idle'):
                events.append((sid, 'gone', claim, 'stale-registration'))
    for inst in live:
        sid = inst.get('session_id')
        ipc = inst.get('ipc') or {}
        if not sid or not ipc.get('alias') or ipc.get('source') != 'digest':
            continue
        entry = usable.get(inst.get('cwd', ''))
        if entry and entry[0] == 'fresh' and sid not in entry[1]:
            events.append((sid, 'live', None, 'unregistered-session'))
    if events:
        now_iso = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        try:
            with open(_IPC_DISAGREE_LOG, 'a') as fh:
                for sid, truth, claim, kind in events:
                    fh.write(json.dumps({
                        'ts': now_iso, 'sid': sid, 'pid_truth': truth,
                        'ipc_claim': claim, 'kind': kind, 'raw': True}) + '\n')
        except OSError:
            pass
    try:
        with open(_IPC_DISAGREE_STATE) as fh:
            prev = json.load(fh)
        if not isinstance(prev, dict):
            prev = {}
    except (OSError, ValueError):
        prev = {}
    cur = {}
    for sid, truth, claim, kind in events:
        if sid not in live_sids:
            continue
        p = prev.get(sid)
        streak = p.get('streak', 0) if isinstance(p, dict) else 0
        # bool excluded explicitly: JSON true satisfies isinstance(int) and
        # true+1 == 2, which would buy a first-scan flag past the debounce.
        if not isinstance(streak, int) or isinstance(streak, bool) \
                or not 0 <= streak < 10**6:
            streak = 0
        streak += 1
        cur[sid] = {'claim': claim, 'kind': kind, 'streak': streak}
        if streak >= 2:
            for inst in live:
                if inst.get('session_id') == sid and inst.get('ipc'):
                    inst['ipc']['disagree'] = {'claim': claim, 'kind': kind,
                                               'scans': streak}
    tmp = _IPC_DISAGREE_STATE + '.tmp.' + str(os.getpid())
    try:
        with open(tmp, 'w') as fh:
            json.dump(cur, fh)
        os.replace(tmp, _IPC_DISAGREE_STATE)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _build_claude_instance(pid, cmdline, provider):
    """Build the full live-instance row for a matched claude process —
    everything downstream of proc_match (cwd, tokens, git, tab title, ...).
    """
    pid_str = str(pid)
    meta = provider['proc_meta'](cmdline)
    model_flag = meta['model_hint']
    resume_id = meta['resume_id']

    # cwd and uptime come from the batched lookup; the per-pid calls below only
    # run for a process that appeared after it (a session started mid-scan).
    cwd = _proc_cwds.get(pid_str, '')
    if not cwd:
        try:
            lsof = subprocess.run(
                ['lsof', '-p', pid_str, '-d', 'cwd', '-Fn'],
                capture_output=True, text=True, timeout=2
            )
            for lline in lsof.stdout.splitlines():
                if lline.startswith('n/'):
                    cwd = lline[1:]
                    break
        except (subprocess.TimeoutExpired, OSError):
            pass

    elapsed = _proc_elapsed.get(pid_str, '')
    if not elapsed:
        try:
            ps_result = subprocess.run(
                ['ps', '-p', pid_str, '-o', 'etime='],
                capture_output=True, text=True, timeout=2
            )
            elapsed = ps_result.stdout.strip() or '?'
        except (subprocess.TimeoutExpired, OSError):
            elapsed = '?'

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

    # What it cost, straight from the process; the estimate is only a fallback
    # for a session whose statusline has never rendered.
    cost_usd = read_cost(pid)
    if cost_usd is None:
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
        'ipc': get_ipc_info(session_data['session_id'], quick_mode, cwd),
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

    cwd = _proc_cwds.get(pid_str, '')
    if not cwd:
        try:
            lsof = subprocess.run(
                ['lsof', '-p', pid_str, '-d', 'cwd', '-Fn'],
                capture_output=True, text=True, timeout=2
            )
            for lline in lsof.stdout.splitlines():
                if lline.startswith('n/'):
                    cwd = lline[1:]
                    break
        except (subprocess.TimeoutExpired, OSError):
            pass

    elapsed = _proc_elapsed.get(pid_str, '?')
    if elapsed == '?':
        try:
            ps_result = subprocess.run(
                ['ps', '-p', pid_str, '-o', 'etime='],
                capture_output=True, text=True, timeout=2
            )
            elapsed = ps_result.stdout.strip() or '?'
        except (subprocess.TimeoutExpired, OSError):
            elapsed = '?'

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
        # Nobody prices a codex session here, and $0.00 would read as free.
        'cost_usd': None,
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

        matched = []
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
            matched.append((int(pid_str), cmdline, provider))

        # Ask about the whole fleet once, before building any row.
        prime_process_info([p for p, _, _ in matched])

        # All digest calls launch together under one shared deadline, so the
        # per-cwd cache is warm before any card asks for it.
        if not quick_mode and _IPC_OVERLAY and _IPC_DIGEST_ON and os.path.exists(_IPC_BIN):
            cwds = {_proc_cwds.get(str(p), '')
                    for p, _, prov in matched if prov['name'] == 'claude'}
            _ipc_digest_prefetch(sorted(c for c in cwds if c))

        for pid, cmdline, provider in matched:
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

        model_short = short_model(model)
        # `or 0` because a .get(key, 0) default never fires for codex — the
        # key exists holding None. Today an unpriced model returns before
        # touching the counts; this stops relying on that ordering accident.
        cost_usd = estimate_cost(model_short, total_input or 0, total_output or 0)

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
        all_events = []
        for line in tail_lines(events_file, 500):
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

def local_day(iso_utc):
    """The local calendar day an ISO-UTC timestamp fell on, or '' if unreadable.

    A day means the reader's day. Work at 01:00 belongs to the date they would
    call today, whatever UTC happened to be doing at the time.
    """
    # fromisoformat, not a fixed strptime pattern: the stamp this is fed today
    # has no fractional seconds, but a parse failure here doesn't error — it
    # returns '' and the session quietly disappears from every bucket. Accept
    # the whole ISO family so a change upstream can't silently delete a day.
    try:
        dt = datetime.fromisoformat((iso_utc or '').replace('Z', '+00:00'))
    except (ValueError, TypeError, AttributeError):
        return ''
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone().strftime('%Y-%m-%d')

def compute_aggregates(history):
    """Compute today/week session stats and model breakdown.

    Buckets by the local day, not UTC. History stamps `modified` in UTC, and
    comparing that against a UTC "today" is self-consistent and still wrong for
    anyone east or west of it: at +05:30 the day's first five and a half hours
    carry yesterday's UTC date, so a night's work vanished from `today` the
    moment UTC rolled over.
    """
    now = datetime.now().astimezone()
    today_str = now.strftime('%Y-%m-%d')
    week_ago = (now - timedelta(days=7)).strftime('%Y-%m-%d')

    today_sessions = []
    week_sessions = []
    model_counts = {}

    for s in history:
        mod = local_day(s.get('modified', ''))
        if mod == today_str:
            today_sessions.append(s)
            # Today's bucket only: the bar renders model_breakdown on its
            # "Today" row (native/Bar.swift), so an unfiltered count over
            # the window walk would show the week's mix under a Today label.
            model = s.get('model', 'unknown')
            model_counts[model] = model_counts.get(model, 0) + 1
        if mod >= week_ago:
            week_sessions.append(s)

    def summarize(sessions):
        return {
            'sessions': len(sessions),
            'turns': sum(s.get('turns', 0) for s in sessions),
            # `or 0` skips unknown token counts (codex sessions carry None)
            # rather than crashing the sum — same shape as cost below.
            'tokens_in': sum(s.get('tokens_in') or 0 for s in sessions),
            'tokens_out': sum(s.get('tokens_out') or 0 for s in sessions),
            # `or 0` skips unpriced sessions rather than crashing the sum on a
            # None. The total is therefore a floor when any model has no rate.
            'cost_usd': round(sum(s.get('cost_usd') or 0 for s in sessions), 4),
        }

    return {
        'today': summarize(today_sessions),
        'week': summarize(week_sessions),
        'model_breakdown': model_counts,
    }

# ─── Aggregate window (summary cache) ────────────────────────────
#
# The history list caps at 20 because it is a list of rows; totals labeled
# "today" and "week" must see every session in their window or they are
# confident falsehoods (148 real sessions once read as 19). Walking the whole
# window is only affordable through a per-file summary cache: parse results
# keyed by (mtime_ns, size), so unchanged transcripts never re-parse.
#
# The cache is a file on disk and therefore untrusted input, same doctrine as
# token_count: any damage — bad JSON, wrong shape, non-int counts — means
# re-parsing the real transcript, never crashing and never trusting garbage.

def short_model(model):
    """Family name ('opus') out of a full model id ('claude-opus-4-8')."""
    for family in ('opus', 'sonnet', 'haiku'):
        if family in model:
            return family
    return model

def _valid_summary(s):
    """A cached summary the scan may trust: right shape, right types, sane
    ranges. Type-valid but range-invalid ints (negative, absurd) re-parse —
    isinstance alone let tokens_out: 10**300 straight into the day's total.
    None is legitimate for token counts (codex carries no usage keys):
    "unknown" is a different fact from 0, and stays distinct in the cache."""
    if not isinstance(s, dict) or not isinstance(s.get('model'), str):
        return False
    v = s.get('turns')
    if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= 10**12:
        return False
    for k in ('tokens_in', 'tokens_out'):
        v = s.get(k)
        if v is None:
            continue
        if not isinstance(v, int) or isinstance(v, bool) or not 0 <= v <= 10**12:
            return False
    return True

def load_summary_cache():
    """Last scan's per-file summaries, or {} when absent or damaged."""
    try:
        with open(summary_cache, 'r') as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}

def save_summary_cache(cache):
    """Write the cache atomically (tmp + rename), best-effort.

    A failed write costs the next scan a re-parse; it must never cost the
    scan its output, so errors are swallowed and the tmp file cleaned up.
    """
    if not summary_cache:
        return
    tmp = f"{summary_cache}.tmp.{os.getpid()}"
    try:
        os.makedirs(os.path.dirname(summary_cache), exist_ok=True)
        with open(tmp, 'w') as f:
            json.dump(cache, f)
        os.replace(tmp, summary_cache)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass

def get_aggregate_history(window_days=7):
    """Every provider session in the aggregate window, as minimal rows for
    compute_aggregates. Only new or changed files pay a parse, where
    "changed" means a different (mtime_ns, size) — a same-size rewrite
    forged to the same mtime would serve the stale summary. That is the
    tradeoff make and rsync accept, and transcripts only ever append."""
    now_local = datetime.now().astimezone()
    cutoff = (now_local - timedelta(days=window_days)).replace(
        hour=0, minute=0, second=0, microsecond=0)
    # An hour of slack so a DST-shifted midnight can't exclude a session that
    # compute_aggregates would still bucket into the week.
    cutoff_epoch = cutoff.timestamp() - 3600

    cache = load_summary_cache()
    fresh = {}
    rows = []
    for provider in PROVIDERS:
        for filepath in provider['transcript_iter']():
            try:
                st = os.stat(filepath)
            except OSError:
                continue
            if st.st_mtime < cutoff_epoch:
                continue
            ent = cache.get(filepath)
            summary = None
            if (isinstance(ent, dict) and ent.get('mtime_ns') == st.st_mtime_ns
                    and ent.get('size') == st.st_size
                    and _valid_summary(ent.get('summary'))):
                summary = ent['summary']
            if summary is None:
                parsed = provider['parse_session'](filepath)
                if not parsed:
                    continue
                summary = {
                    'model': parsed.get('model') or 'unknown',
                    'turns': parsed.get('turns', 0),
                    'tokens_in': parsed.get('tokens_in', 0),
                    'tokens_out': parsed.get('tokens_out', 0),
                }
            fresh[filepath] = {'mtime_ns': st.st_mtime_ns, 'size': st.st_size,
                               'summary': summary}
            model_short = short_model(summary['model'])
            rows.append({
                'modified': datetime.fromtimestamp(st.st_mtime, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                'model': model_short,
                'turns': summary['turns'],
                'tokens_in': summary['tokens_in'],
                'tokens_out': summary['tokens_out'],
                'cost_usd': estimate_cost(model_short, summary['tokens_in'] or 0,
                                          summary['tokens_out'] or 0),
            })
    # Rewriting from scratch prunes files that are gone or aged out; skip the
    # write when nothing changed (this runs on every dashboard poll).
    if fresh != cache:
        save_summary_cache(fresh)
    return rows

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
            exits = []
            for line in tail_lines(CLAUDEW_EVENTS, 50):
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
            # Read the reason field rather than grepping the raw line: the
            # substring matched anywhere, including inside a message quoting it.
            reasons = []
            for l in tail_lines(resume_exits_path, 50):
                try:
                    reasons.append(json.loads(l).get('reason', ''))
                except (json.JSONDecodeError, ValueError, AttributeError):
                    continue
            rate_limits = reasons.count('RATE_LIMIT')
            api_errors = reasons.count('API_ERROR')
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
if not quick_mode:
    run_ipc_disagreement_pass(live)

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
    # Not compute_aggregates(history): totals must see past the display cap.
    aggregates = compute_aggregates(get_aggregate_history())

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
