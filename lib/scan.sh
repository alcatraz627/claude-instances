#!/usr/bin/env bash
# scan.sh — enumerate live Claude Code instances + recent session history.
#
# Output: JSON to stdout with structure:
#   { "live": [...], "history": [...], "limits": {...} }
#
# Live instances: discovered via pgrep + process info + statusline metrics.
# History: enumerated from ~/.claude/projects/*/*.jsonl.
# Limits: read from cached ~/.claude/widgets/.limits.json if present.

set -uo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
LIMITS_CACHE="${HOME}/.claude/widgets/.limits.json"
EVENTS_FILE="${HOME}/.claude/events.jsonl"
STATUSLINE_DIR="/tmp"

python3 - "$PROJECTS_DIR" "$LIMITS_CACHE" "$EVENTS_FILE" "$STATUSLINE_DIR" <<'PYEOF'
import sys, json, os, subprocess, re
from datetime import datetime, timezone
from pathlib import Path

projects_dir = sys.argv[1]
limits_cache = sys.argv[2]
events_file = sys.argv[3]
statusline_dir = sys.argv[4]

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

# ─── Session JSONL token aggregator ─────────────────────────────

def get_session_tokens(pid, cwd):
    """Find the active session JSONL for a PID and aggregate token usage."""
    result = {'model': 'unknown', 'input_tokens': 0, 'output_tokens': 0,
              'cache_read': 0, 'cache_create': 0, 'cost_usd': 0.0,
              'session_id': '', 'turns': 0}

    if not cwd or not os.path.isdir(projects_dir):
        return result

    # Derive project slug from CWD
    # ~/.claude/projects/ uses path-with-dashes as dir names
    slug = cwd.replace('/', '-').lstrip('-')
    proj_dir = os.path.join(projects_dir, '-' + slug)

    if not os.path.isdir(proj_dir):
        # Try without leading dash
        proj_dir = os.path.join(projects_dir, slug)
    if not os.path.isdir(proj_dir):
        return result

    # Find the most recently modified JSONL in this project
    jsonl_files = []
    try:
        for f in os.listdir(proj_dir):
            if f.endswith('.jsonl') and not f.startswith('.'):
                full = os.path.join(proj_dir, f)
                jsonl_files.append((os.path.getmtime(full), full, f))
    except OSError:
        return result

    if not jsonl_files:
        return result

    jsonl_files.sort(reverse=True)
    _, filepath, fname = jsonl_files[0]
    result['session_id'] = Path(filepath).stem

    # Read the file — aggregate usage from assistant messages
    # For large files, only read last 500 lines for speed
    try:
        size = os.path.getsize(filepath)
        lines = []
        if size > 500_000:
            # Tail approach for large files
            with open(filepath, 'rb') as f:
                f.seek(max(0, size - 500_000))
                f.readline()  # skip partial line
                lines = f.read().decode('utf-8', errors='replace').splitlines()
        else:
            with open(filepath, 'r', errors='replace') as f:
                lines = f.readlines()

        turn_count = 0
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

        result['turns'] = turn_count

    except OSError:
        pass

    return result

# ─── Live instances ──────────────────────────────────────────────

def get_live_instances():
    """Find running claude processes and extract metadata."""
    instances = []
    try:
        result = subprocess.run(
            ['pgrep', '-fl', 'claude'],
            capture_output=True, text=True, timeout=3
        )
        if result.returncode != 0:
            return instances

        for line in result.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            pid_str = parts[0]
            cmdline = parts[1]

            # Only match main claude CLI invocations
            if not (cmdline.startswith('claude ') or cmdline == 'claude'):
                continue
            if any(skip in cmdline for skip in ['emit-event', 'hook', 'esbuild', 'server.js']):
                continue

            pid = int(pid_str)

            # Get CWD via lsof — must match exact PID in output
            # lsof -Fn output: p<pid>\nfcwd\nn<path> for each process
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
                        # Moved past our PID to another process
                        break
            except (subprocess.TimeoutExpired, OSError):
                pass

            # Extract model from cmdline
            model_flag = 'unknown'
            if '--model' in cmdline:
                m = re.search(r'--model\s+(\S+)', cmdline)
                if m:
                    model_flag = m.group(1)

            # Check for --resume flag
            resume_id = ''
            if '--resume' in cmdline:
                m = re.search(r'--resume\s+(\S+)', cmdline)
                if m:
                    resume_id = m.group(1)

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

            # Get session tokens and model from JSONL
            session_data = get_session_tokens(pid, cwd)
            if model_flag == 'unknown' and session_data['model'] != 'unknown':
                model_flag = session_data['model']

            # Shorten model name for display
            model_display = model_flag
            if 'opus' in model_flag:
                model_display = 'opus'
            elif 'sonnet' in model_flag:
                model_display = 'sonnet'
            elif 'haiku' in model_flag:
                model_display = 'haiku'

            # Shorten CWD for display
            cwd_short = cwd.replace(os.path.expanduser('~'), '~') if cwd else '?'

            instances.append({
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
                },
            })
    except (subprocess.TimeoutExpired, OSError):
        pass

    return instances

# ─── Session history ─────────────────────────────────────────────

def get_session_history(max_sessions=20):
    """Enumerate recent sessions from JSONL project files."""
    sessions = []
    if not os.path.isdir(projects_dir):
        return sessions

    jsonl_files = []
    for root, dirs, files in os.walk(projects_dir):
        for f in files:
            if f.endswith('.jsonl') and not f.startswith('.'):
                full = os.path.join(root, f)
                try:
                    mtime = os.path.getmtime(full)
                    jsonl_files.append((mtime, full))
                except OSError:
                    pass

    jsonl_files.sort(reverse=True)

    for mtime, filepath in jsonl_files[:max_sessions]:
        session_id = Path(filepath).stem
        project_dir_name = Path(filepath).parent.name

        model = 'unknown'
        turn_count = 0
        total_input = 0
        total_output = 0

        try:
            size = os.path.getsize(filepath)
            # Read first 50 lines for model detection + count all lines
            with open(filepath, 'r', errors='replace') as f:
                first_lines = []
                for i, line in enumerate(f):
                    if i < 50:
                        first_lines.append(line.strip())
                    turn_count += 1
                    last_line = line.strip()

            # Extract model from first assistant/result message with model info
            for line in first_lines:
                try:
                    obj = json.loads(line)
                    msg_type = obj.get('type', '')
                    # Check assistant messages
                    if msg_type == 'assistant':
                        m = obj.get('message', {}).get('model', '')
                        if m:
                            model = m
                            break
                    # Check result messages (some sessions log model in result)
                    elif msg_type == 'result':
                        m = obj.get('model', '') or obj.get('result', {}).get('model', '')
                        if m:
                            model = m
                            break
                    # Check system messages that may reference model
                    elif msg_type == 'system' and obj.get('model'):
                        model = obj['model']
                        break
                except json.JSONDecodeError:
                    pass

            # Extract token totals from last line if it has usage
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
            continue

        # Prettify project name
        project_display = project_dir_name.replace('-', '/')
        if project_display.startswith('/'):
            project_display = project_display[1:]
        # Take last 2 meaningful segments
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

        # Estimate cost from model + tokens (per-million pricing)
        # Approximate rates: opus $15/M in + $75/M out, sonnet $3/M in + $15/M out, haiku $0.25/M in + $1.25/M out
        cost_usd = 0.0
        rate_in, rate_out = 0.0, 0.0
        if model_short == 'opus':
            rate_in, rate_out = 15.0, 75.0
        elif model_short == 'sonnet':
            rate_in, rate_out = 3.0, 15.0
        elif model_short == 'haiku':
            rate_in, rate_out = 0.25, 1.25
        if total_input > 0 or total_output > 0:
            cost_usd = round((total_input * rate_in + total_output * rate_out) / 1_000_000, 4)

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
        })

    return sessions

# ─── Recent events ───────────────────────────────────────────────

def get_recent_events(max_events=10):
    """Get the most recent notable events."""
    events = []
    if not os.path.exists(events_file):
        return events
    try:
        with open(events_file, 'r') as f:
            lines = f.readlines()
        for line in lines[-200:]:
            try:
                obj = json.loads(line.strip())
                event = obj.get('event', '')
                if event in ('SessionStart', 'Stop', 'PermissionRequest', 'PostCompact'):
                    events.append({
                        'ts': obj.get('ts', ''),
                        'event': event,
                        'project': obj.get('project', ''),
                        'session_id': obj.get('session_id', ''),
                    })
            except json.JSONDecodeError:
                pass
    except OSError:
        pass
    return events[-max_events:]

# ─── Limits ──────────────────────────────────────────────────────

def get_limits():
    if os.path.exists(limits_cache):
        try:
            with open(limits_cache, 'r') as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            pass
    return None

# ─── Assemble ────────────────────────────────────────────────────

live = get_live_instances()
history = get_session_history()
events = get_recent_events()
limits = get_limits()

output = {
    'ts': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'live_count': len(live),
    'live': live,
    'history': history,
    'recent_events': events,
}
if limits:
    output['limits'] = limits

print(json.dumps(output))
PYEOF
