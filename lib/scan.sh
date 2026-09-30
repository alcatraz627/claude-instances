#!/usr/bin/env bash
# scan.sh — list live Claude Code sessions and recent session history.
#
# Output: JSON to stdout: { "ts", "live_count", "live": [...], "history": [...] }
#
# Live: one row per ~/.claude/sessions/<pid>.json whose pid is running with a
#   matching start time and kind "interactive" (see select_live).
# History: recent transcripts under ~/.claude/projects/*/*.jsonl, stubs hidden.
#
# Flags:
#   --quick   Skip history and git (fast path for the 5s poll)

set -uo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
STATUSLINE_DIR="/tmp"
QUICK_MODE=0
[[ "${1:-}" == "--quick" ]] && QUICK_MODE=1

# argv[2] and argv[3] are unused placeholders kept so callers that exec the
# embedded script (tests/fixtures/scan-probe.py) keep their positions.
python3 - "$PROJECTS_DIR" "" "" "$STATUSLINE_DIR" "$QUICK_MODE" <<'PYEOF'
import sys, json, os, subprocess, re, math
from datetime import datetime, timezone, timedelta
from pathlib import Path

projects_dir = sys.argv[1]
statusline_dir = sys.argv[4]
quick_mode = sys.argv[5] == '1'

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

# ─── Transcript reading ────────────────────────────────────────
#
# One pass over a live session's transcript yields everything a row shows:
# token totals, turns, tool calls, permission mode, last tool, last human
# prompt, and the tail entries the state guess reads. See read_transcript.

def _tool_target(name, inp):
    """The one argument that says what a tool call is about, max 60 chars."""
    if name == 'Bash':
        return (inp.get('command') or '').replace('\n', ' ')[:60]
    if name in ('Read', 'Write', 'Edit'):
        return inp.get('file_path') or ''
    if name in ('Grep', 'Glob'):
        return inp.get('pattern') or ''
    if name == 'WebFetch':
        return inp.get('url') or ''
    if name in ('Task', 'Agent'):
        return (inp.get('description') or inp.get('prompt') or '')[:60]
    if name == 'TodoWrite':
        return f"{len(inp.get('todos', []))} item(s)"
    for v in inp.values():
        if isinstance(v, str) and v:
            return v[:60]
    return ''

# User-type lines that are not something the owner typed.
_PROMPT_JUNK_PREFIXES = (
    '<task-notification>', 'Base directory for this skill', '<local-command-',
    '<bash-stdout>', '<bash-stderr>', 'Stop hook feedback:', 'Caveat:',
)

def human_prompt(obj):
    """The text the owner typed in this user line, or '' if it is not one.

    Skips meta lines (skill bodies, hook feedback), task notifications and
    command output. A slash command reads as "/name args", a shell escape as
    "! cmd".
    """
    if obj.get('type') != 'user' or obj.get('isSidechain') or obj.get('isMeta'):
        return ''
    origin = obj.get('origin')
    if isinstance(origin, dict) and origin.get('kind') not in (None, 'human'):
        return ''
    msg = obj.get('message', {})
    text = ''
    if isinstance(msg, dict):
        content = msg.get('content', [])
        if isinstance(content, str):
            text = content
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'text':
                    text += block.get('text', '')
                elif isinstance(block, str):
                    text += block
    elif isinstance(msg, str):
        text = msg
    text = re.sub(r'<system-reminder>.*?</system-reminder>', '', text, flags=re.DOTALL).strip()
    cmd = re.search(r'<command-name>(.*?)</command-name>', text, flags=re.DOTALL)
    if cmd:
        args = re.search(r'<command-args>(.*?)</command-args>', text, flags=re.DOTALL)
        text = (cmd.group(1).strip() + ' ' + (args.group(1).strip() if args else '')).strip()
    bash = re.match(r'<bash-input>(.*?)</bash-input>', text, flags=re.DOTALL)
    if bash:
        text = '! ' + bash.group(1).strip()
    if text.startswith(_PROMPT_JUNK_PREFIXES):
        return ''
    return text

def _ago_seconds(ts):
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        return max(0, int((datetime.now(timezone.utc) - dt).total_seconds()))
    except (ValueError, TypeError, AttributeError):
        return 0

def _message_key(msg, line_no):
    """Which assistant message a transcript line belongs to.

    Claude Code writes one line per content block, and each line repeats its
    message's id and full usage, so turns and tokens are counted per message.
    A line with no id stands for itself.
    """
    mid = msg.get('id')
    return mid if isinstance(mid, str) and mid else f'line:{line_no}'

def read_transcript(filepath):
    """Everything a live row needs from one read of its transcript.

    Substring checks decide which lines are worth json.loads: a transcript is
    mostly huge tool_result lines, and parsing those was the scan's cost, not
    the file size.
    """
    import collections
    out = {'model': 'unknown', 'input_tokens': 0, 'output_tokens': 0,
           'cache_read': 0, 'cache_create': 0, 'turns': 0, 'tool_calls': 0,
           'permission_mode': '', 'last_tool': None, 'last_prompt': '',
           'tail': []}
    tail = collections.deque(maxlen=3)
    last_tool_ts = ''
    usage_by_msg = {}
    try:
        with open(filepath, 'r', errors='replace') as f:
            for n, line in enumerate(f):
                if line.strip():
                    tail.append(line)
                is_asst = '"assistant"' in line
                is_perm = '"permission-mode"' in line
                is_user = '"user"' in line and '"tool_result"' not in line
                if not (is_asst or is_perm or is_user):
                    continue
                try:
                    obj = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                t = obj.get('type', '')
                if t == 'permission-mode':
                    out['permission_mode'] = obj.get('permissionMode', '') or out['permission_mode']
                elif t == 'user':
                    p = human_prompt(obj)
                    if p:
                        out['last_prompt'] = p
                elif t == 'assistant':
                    msg = obj.get('message', {})
                    if not isinstance(msg, dict):
                        continue
                    if msg.get('model'):
                        out['model'] = msg['model']
                    usage_by_msg[_message_key(msg, n)] = msg.get('usage') or {}
                    content = msg.get('content', [])
                    if not isinstance(content, list):
                        continue
                    for block in content:
                        if not isinstance(block, dict) or block.get('type') != 'tool_use':
                            continue
                        out['tool_calls'] += 1
                        if obj.get('isSidechain'):
                            continue
                        name = block.get('name', '?')
                        inp = block.get('input') if isinstance(block.get('input'), dict) else {}
                        out['last_tool'] = {'name': name, 'target': _tool_target(name, inp)[:80]}
                        last_tool_ts = obj.get('timestamp', '')
    except OSError:
        return out
    out['turns'] = len(usage_by_msg)
    for usage in usage_by_msg.values():
        out['input_tokens'] += token_count(usage.get('input_tokens'))
        out['output_tokens'] += token_count(usage.get('output_tokens'))
        out['cache_read'] += token_count(usage.get('cache_read_input_tokens'))
        out['cache_create'] += token_count(usage.get('cache_creation_input_tokens'))
    if out['last_tool'] is not None:
        out['last_tool']['ago_seconds'] = _ago_seconds(last_tool_ts)
    if out['last_prompt']:
        last = ' '.join(out['last_prompt'].split())
        out['last_prompt'] = last[:80] + ('…' if len(last) > 80 else '')
    for line in reversed(tail):
        try:
            out['tail'].append(json.loads(line))
        except (json.JSONDecodeError, ValueError):
            continue
    return out

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

def infer_session_state(entries):
    """Guess what a session is doing from its newest transcript entries.

    `entries` is newest first (read_transcript's 'tail'). Returns
    {'state': str, 'detail': str}; states: thinking, responding, tool_use, idle.
    Claude Code's own status in the session file is the better signal; this
    only supplies the detail.
    """
    result = {'state': 'idle', 'detail': ''}
    if not entries:
        return result
    last = entries[0]
    msg_type = last.get('type', '')
    if msg_type == 'user':
        result['state'] = 'thinking'
        result['detail'] = 'processing prompt...'
    elif msg_type == 'assistant':
        msg = last.get('message', {})
        content = msg.get('content', []) if isinstance(msg, dict) else []
        last_block = content[-1] if isinstance(content, list) and content else {}
        result['state'] = 'responding'
        if isinstance(last_block, dict) and last_block.get('type') == 'tool_use':
            tool_name = last_block.get('name', '?')
            tool_input = last_block.get('input', {}) if isinstance(last_block.get('input'), dict) else {}
            detail = tool_name
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
        elif isinstance(last_block, dict) and last_block.get('type') == 'text':
            text = last_block.get('text', '')
            result['detail'] = text[:37] + '...' if len(text) > 40 else text[:40]
    return result

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

def _find_transcript(cwd, sid):
    """Absolute path of transcript <sid>.jsonl, or '' if it is not on disk.

    Looks in the cwd's project dir first, then every project dir, since a
    session's transcript lives under the cwd it started in.
    """
    if not sid or '/' in sid or not os.path.isdir(projects_dir):
        return ''
    if cwd:
        slug = re.sub(r'[/.]', '-', cwd).lstrip('-')
        for d in ('-' + slug, slug):
            p = os.path.join(projects_dir, d, f"{sid}.jsonl")
            if os.path.isfile(p):
                return p
    try:
        for e in os.scandir(projects_dir):
            p = os.path.join(e.path, f"{sid}.jsonl")
            if e.is_dir() and os.path.isfile(p):
                return p
    except OSError:
        pass
    return ''

def _resolve_session_path(pid, cwd, prefer_sid='', file_sid=''):
    """Which transcript belongs to this PID? Absolute path, or '' if unknown.

    The session file's id wins when there is one. Otherwise, for a process
    that has not written its file yet: what the process reported through the
    statusline (read_transcript_path), then an explicit `--resume <id>`.
    Never "the newest transcript in the cwd": one cwd often hosts several
    live sessions, and that guess gave them all the same conversation.
    """
    if file_sid:
        return _find_transcript(cwd, file_sid)
    tpath = read_transcript_path(pid)
    if tpath:
        return tpath
    return _find_transcript(cwd, prefer_sid)

def get_session_tokens(pid, cwd, prefer_sid='', file_sid=''):
    """Find this PID's transcript and read it once (see read_transcript).

    Every line is streamed, not a tail window: a tail made turn counts a
    fiction (a 58MB session once read 44 of its 4488 turns).
    """
    result = {'model': 'unknown', 'input_tokens': 0, 'output_tokens': 0,
              'cache_read': 0, 'cache_create': 0, 'cost_usd': 0.0,
              'session_id': file_sid, 'turns': 0, 'tool_calls': 0,
              'jsonl_path': '', 'permission_mode': '', 'last_tool': None,
              'last_prompt': '', 'tail': []}

    filepath = _resolve_session_path(pid, cwd, prefer_sid, file_sid)
    if not filepath:
        return result
    result['session_id'] = Path(filepath).stem
    result['jsonl_path'] = filepath
    result.update(read_transcript(filepath))
    return result

# ─── Provider interface ──────────────────────────────────────────
#
# The scanner's one CLI (claude) is described as a dict of capabilities.
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
    usage_by_msg = {}
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
                msg = obj.get('message')
                if not isinstance(msg, dict):
                    msg = {}
                usage_by_msg[_message_key(msg, i)] = msg.get('usage') or {}
        turn_count = len(usage_by_msg)
        total_input = sum(token_count(u.get('input_tokens')) for u in usage_by_msg.values())
        total_output = sum(token_count(u.get('output_tokens')) for u in usage_by_msg.values())

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

claude_provider = {
    'name': 'claude',
    'proc_match': claude_proc_match,
    'transcript_iter': claude_transcript_iter,
    'parse_session': claude_parse_session,
    'proc_meta': claude_proc_meta,
}

# Claude only. Codex was a provider here once; every `codex` process
# (app-server daemons included) became a ghost live row, so it was dropped.
PROVIDERS = [claude_provider]

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

# Env override so a scratch hub or validator run keeps its streaks apart.
_IPC_DISAGREE_STATE = os.environ.get('HUB_IPC_DISAGREE_STATE') or os.path.expanduser(
    '~/.claude/widgets/.ipc-disagreement-state.json')
# Consecutive full scans a disagreement must hold before its card is flagged.
# Six is about 30 s at the hub's cadence: long enough that a session in a long
# turn or a registration race never flashes a warning.
DISAGREE_DEBOUNCE = 6

def run_ipc_disagreement_pass(live):
    """Where the two systems' views of liveness differ, say so, never decide.

    The scan's process table is the physical authority; the digest carries
    ipc's heartbeat-based view. A card is flagged once the same disagreement
    holds for DISAGREE_DEBOUNCE consecutive scans. Nothing is logged: a raw
    ledger for a planned oracle grew to 69 MB with no reader, and was removed.

    Runs only when at least one cwd produced a usable digest this scan, since a
    dark or unreachable bridge is no evidence of agreement and must not reset
    anyone's streak."""
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
        if streak >= DISAGREE_DEBOUNCE:
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


def _ms_to_iso(ms):
    """Epoch milliseconds from a session file as ISO-UTC, or '' if not a number."""
    if isinstance(ms, bool) or not isinstance(ms, (int, float)) or not math.isfinite(ms):
        return ''
    try:
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    except (OverflowError, OSError, ValueError):
        return ''

def _last_activity(sess, jsonl_path):
    """Newer of the session file's updatedAt and the transcript's mtime.

    updatedAt moves only when the status changes, so a long busy stretch
    would otherwise read as no activity at all.
    """
    best = (sess or {}).get('updatedAt')
    best = best / 1000 if isinstance(best, (int, float)) and not isinstance(best, bool) else 0
    try:
        best = max(best, os.path.getmtime(jsonl_path)) if jsonl_path else best
    except OSError:
        pass
    return _ms_to_iso(best * 1000) if best else ''

def _str_field(sess, key):
    v = sess.get(key) if sess else None
    return v if isinstance(v, str) else ''

def _build_claude_instance(pid, cmdline, provider, sess=None):
    """Build the full live-instance row for one live session.

    `sess` is the session's ~/.claude/sessions/<pid>.json when it has one;
    its session id and cwd win over anything derived from the process.
    """
    pid_str = str(pid)
    meta = provider['proc_meta'](cmdline)
    model_flag = meta['model_hint']
    resume_id = meta['resume_id']
    file_sid = _str_field(sess, 'sessionId')

    # cwd and uptime come from the batched lookup; the per-pid calls below only
    # run for a process that appeared after it (a session started mid-scan).
    cwd = _str_field(sess, 'cwd') or _proc_cwds.get(pid_str, '')
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
    session_data = get_session_tokens(pid, cwd, prefer_sid=resume_id, file_sid=file_sid)
    if model_flag == 'unknown' and session_data['model'] != 'unknown':
        model_flag = session_data['model']

    # Read tab title
    tab_title = read_tab_title(session_data['session_id'])

    # Count subagents
    subagent_count = count_subagents(pid)

    # Prompt, permission mode and last tool came out of the one transcript
    # read above. Git is full-scan only (skipped on --quick for the 5s tick).
    last_prompt    = session_data['last_prompt']
    perm_mode      = session_data['permission_mode']
    last_tool_info = session_data['last_tool']
    if not quick_mode:
        branch         = git_branch(cwd)
        modified_files = git_modified_count(cwd)
    else:
        branch, modified_files = '', 0

    session_state = infer_session_state(session_data['tail'])

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
        # 'interactive' from the session file; 'pending' for a young process
        # that has not written its file yet.
        'kind': _str_field(sess, 'kind') or 'pending',
        'name': _str_field(sess, 'name'),
        'status': _str_field(sess, 'status'),
        'status_since': _ms_to_iso((sess or {}).get('statusUpdatedAt')),
        'last_activity': _last_activity(sess, session_data['jsonl_path']),
        'ipc': get_ipc_info(session_data['session_id'], quick_mode, cwd),
    }

# ─── Liveness: Claude Code's own session registry ───────────────
#
# Claude Code writes ~/.claude/sessions/<pid>.json for each session it runs.
# A live row exists iff that file exists, its pid is running, the file's
# procStart matches the running process's start time (a reused pid fails
# this), and kind == "interactive" (headless `claude -p` workers fail it).

SESSIONS_DIR = os.environ.get('HUB_SESSIONS_DIR') or os.path.join(home, '.claude', 'sessions')

# A claude process with no session file yet is shown only this long; an
# interactive session writes its file at startup, so an older one is not one.
FALLBACK_GRACE_S = 60

_HEADLESS_FLAGS = ('-p', '--print', '--output-format', '--input-format')

def _ps_snapshot():
    """Raw `ps` text: pid, controlling tty, start time, argv for every process.

    `ps`, not `pgrep -f`: the compiled claude binary's argv is not readable
    through pgrep on this machine, so pgrep silently finds no sessions.
    """
    r = subprocess.run(['ps', '-Ao', 'pid=,tty=,lstart=,args='],
                       capture_output=True, text=True, timeout=3)
    return r.stdout if r.returncode == 0 else ''

def _parse_start(text, utc):
    """A ps-style start time ('Wed Sep 23 18:07:15 2026') as epoch seconds."""
    import time, calendar
    try:
        st = time.strptime(' '.join((text or '').split()), '%a %b %d %H:%M:%S %Y')
    except ValueError:
        return None
    return calendar.timegm(st) if utc else time.mktime(st)

def parse_ps(text):
    """pid -> (start_epoch, cmdline, tty) from `ps -Ao pid=,tty=,lstart=,args=` text.

    tty is '' for a process with no controlling terminal (ps prints '??').
    """
    procs = {}
    for line in text.splitlines():
        parts = line.split(None, 7)
        if len(parts) < 8 or not parts[0].isdigit():
            continue
        tty = '' if parts[1] in ('??', '?', '-') else parts[1]
        procs[int(parts[0])] = (_parse_start(' '.join(parts[2:7]), utc=False), parts[7], tty)
    return procs

def read_session_files(d=None):
    """pid -> parsed ~/.claude/sessions/<pid>.json. Unreadable files are skipped."""
    d = d or SESSIONS_DIR
    out = {}
    try:
        names = os.listdir(d)
    except OSError:
        return out
    for n in names:
        stem, ext = os.path.splitext(n)
        if ext != '.json' or not stem.isdigit():
            continue
        p = os.path.join(d, n)
        if not os.path.isfile(p):
            continue
        try:
            with open(p) as f:
                obj = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(obj, dict):
            out[int(stem)] = obj
    return out

def _proc_start_matches(proc_start, actual_epoch):
    """Does the file's procStart name this process's start time?

    The file's clock has been UTC on this machine while ps prints local time,
    so either reading within two seconds counts as a match.
    """
    if actual_epoch is None or not isinstance(proc_start, str):
        return False
    for utc in (True, False):
        t = _parse_start(proc_start, utc)
        if t is not None and abs(t - actual_epoch) <= 2:
            return True
    return False

def _is_headless(cmdline):
    return any(tok in _HEADLESS_FLAGS or tok.startswith('--print=')
               for tok in cmdline.split())

def select_live(procs, sessions, now=None):
    """Which processes are live interactive Claude sessions.

    Returns [(pid, cmdline, session_dict_or_None)]. The session file is the
    authority; a claude process without a valid file is kept only while it is
    young enough to still be writing one, and only if it owns a terminal (a
    claude run by a tool or script has none).
    """
    import time
    now = now if now is not None else time.time()
    rows, claimed = [], set()
    for pid, sess in sorted(sessions.items()):
        proc = procs.get(pid)
        if proc is None:
            continue                      # stale file: pid is gone
        if not _proc_start_matches(sess.get('procStart'), proc[0]):
            continue                      # pid reused by another process
        claimed.add(pid)                  # this file speaks for this process
        if sess.get('kind') != 'interactive':
            continue                      # headless worker, or anything else
        rows.append((pid, proc[1], sess))
    for pid, (start, cmdline, tty) in sorted(procs.items()):
        if pid in claimed or not tty:
            continue
        basename = os.path.basename(cmdline.split(None, 1)[0]) if cmdline.strip() else ''
        if not claude_proc_match(basename, cmdline) or _is_headless(cmdline):
            continue
        if start is None or now - start > FALLBACK_GRACE_S:
            continue
        rows.append((pid, cmdline, None))
    return rows

def get_live_instances():
    """One row per live interactive Claude session (see select_live)."""
    instances = []
    try:
        procs = parse_ps(_ps_snapshot())
        selected = select_live(procs, read_session_files())

        # Ask about the whole fleet once, before building any row.
        prime_process_info([p for p, _, _ in selected])

        # All digest calls launch together under one shared deadline, so the
        # per-cwd cache is warm before any card asks for it.
        if not quick_mode and _IPC_OVERLAY and _IPC_DIGEST_ON and os.path.exists(_IPC_BIN):
            cwds = {(s or {}).get('cwd') or _proc_cwds.get(str(p), '')
                    for p, _, s in selected}
            _ipc_digest_prefetch(sorted(c for c in cwds if c))

        for pid, cmdline, sess in selected:
            instance = _build_claude_instance(pid, cmdline, claude_provider, sess)
            if instance:
                instances.append(instance)
    except (subprocess.TimeoutExpired, OSError):
        pass

    return instances

# ─── Session history ─────────────────────────────────────────────

# Sessions with fewer assistant turns than this are stubs (opened and closed,
# or a one-shot helper) and are left out of the ended list.
MIN_HISTORY_TURNS = 4

def get_session_history(max_sessions=20):
    """The most recent ended-or-live sessions worth listing, newest first.

    Stubs under MIN_HISTORY_TURNS are skipped, so up to 3x max_sessions files
    are read to fill the list.
    """
    sessions = []
    files = []
    for provider in PROVIDERS:
        for filepath in provider['transcript_iter']():
            try:
                files.append((os.path.getmtime(filepath), filepath, provider))
            except OSError:
                continue
    files.sort(key=lambda t: t[0], reverse=True)

    for mtime, filepath, provider in files[:max_sessions * 3]:
        if len(sessions) >= max_sessions:
            break
        parsed = provider['parse_session'](filepath)
        if not parsed:
            continue
        turn_count = parsed.get('turns', 0)
        if turn_count < MIN_HISTORY_TURNS:
            continue

        session_id = parsed.get('id') or Path(filepath).stem
        model = parsed.get('model', 'unknown')
        total_input = parsed.get('tokens_in', 0)
        total_output = parsed.get('tokens_out', 0)

        # Project display decodes the project dir name.
        project_display = Path(filepath).parent.name.replace('-', '/').lstrip('/')
        segs = [s for s in project_display.split('/') if s]
        if len(segs) > 2:
            project_display = '/'.join(segs[-2:])

        model_short = short_model(model)
        # `or 0`: a token count may be None (unknown), never a crash.
        cost_usd = estimate_cost(model_short, total_input or 0, total_output or 0)


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

def short_model(model):
    """Family name ('opus') out of a full model id ('claude-opus-4-8')."""
    for family in ('opus', 'sonnet', 'haiku'):
        if family in model:
            return family
    return model

# ─── Assemble ────────────────────────────────────────────────────

live = get_live_instances()
if not quick_mode:
    run_ipc_disagreement_pass(live)

output = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'live_count': len(live),
    'live': live,
    # History is a full-scan read; --quick leaves it empty.
    'history': [] if quick_mode else get_session_history(),
}

print(json.dumps(output))
PYEOF
