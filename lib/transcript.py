#!/usr/bin/env python3
"""Turn a Claude Code session transcript into a clean, complete data model.

This is the data half of the claude-instances detail widget. It reads a
session's append-only `.jsonl` log in full — no truncation — and returns a
normalized list of conversation "blocks" (what a human reading the transcript
thinks of as turns: your message, Claude's reply, a group of tool calls, an
ambient event). The widget's browser front-end renders and searches over this
model; nothing here knows about HTML.

Three things make this more than a reformat of the raw log:

  1. Completeness. The old renderer seeked to the last 800 KB of the file and
     then kept only the last 100 blocks. This reads every line, so a four-day
     transcript shows its first day.

  2. Sub-agent linkage. A `Task` tool call dispatches a sub-agent whose full
     transcript lives in a sibling `subagents/agent-<id>.jsonl` file, tied back
     to the dispatching call by a shared tool-use id. We resolve that join so a
     dispatch can be labelled ("general-purpose: Code-truth: admin billing")
     and drilled into, instead of showing as an opaque payload.

  3. Telemetry. Token counts, model, and cache reads travel with each block so
     the front-end can show per-turn and cumulative cost consistently.

CLI:
    transcript.py <session.jsonl> [--since SEQ] [--agent AGENT_ID]
        --since SEQ   emit only blocks with seq > SEQ (incremental live tail)
        --agent ID    parse the sub-agent transcript agent-<ID>.jsonl that sits
                      under <session>/subagents/ instead of the parent
    Prints one JSON object: {"meta": {...}, "records": [...]}.
"""

import sys
import os
import json
import glob
import zlib
from collections import Counter
from datetime import datetime


# ── Small formatting helpers (presentation-neutral) ─────────────────────────

def _short(s, n):
    if not s:
        return ''
    return s if len(s) <= n else s[:n - 1] + '…'


def _fmt_ts(iso):
    """HH:MM:SS in local time, for the compact inline timestamp."""
    if not iso:
        return ''
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00'))
        return dt.astimezone().strftime('%H:%M:%S')
    except Exception:
        return ''


def _fmt_ts_full(iso):
    """Full local datetime, for the timestamp tooltip."""
    if not iso:
        return ''
    try:
        dt = datetime.fromisoformat(iso.replace('Z', '+00:00')).astimezone()
        return dt.strftime('%a %b %d %Y · %H:%M:%S %Z')
    except Exception:
        return iso


def tool_preview(name, inp):
    """One-line preview of a tool call's most diagnostic input.

    Kept identical in spirit to the old renderer so the front-end shows the
    same at-a-glance summary, but returned as data rather than baked markup.
    """
    if not isinstance(inp, dict):
        return ''
    if name == 'Bash':
        return _short(inp.get('command', '').replace('\n', ' '), 100)
    if name in ('Read', 'Write'):
        return _short(inp.get('file_path', ''), 80)
    if name == 'Edit':
        path = inp.get('file_path', '')
        old = _short(inp.get('old_string', '').replace('\n', '⏎'), 40)
        return f"{_short(path, 50)}  ·  {old}"
    if name == 'Grep':
        return f"/{_short(inp.get('pattern', ''), 40)}/  in {_short(inp.get('path', ''), 40)}"
    if name == 'Glob':
        return _short(inp.get('pattern', ''), 80)
    if name == 'WebFetch':
        return _short(inp.get('url', ''), 80)
    if name in ('Task', 'Agent'):
        return _short(inp.get('description', '') or inp.get('prompt', ''), 80)
    if name == 'TodoWrite':
        return f"{len(inp.get('todos', []))} item(s)"
    for k, v in inp.items():
        if isinstance(v, str) and v:
            return f"{k}: {_short(v, 70)}"
    return ''


def file_paths_in_input(name, inp):
    """File paths mentioned in a tool's input — front-end renders click-to-copy."""
    if not isinstance(inp, dict):
        return []
    paths = []
    for k in ('file_path', 'path'):
        v = inp.get(k)
        if isinstance(v, str) and v:
            paths.append(v)
    return paths


# ── Sub-agent correlation ───────────────────────────────────────────────────

def load_subagent_index(jsonl_file):
    """Map each dispatching tool-use id to the sub-agent it spawned.

    Claude Code writes a sidecar `subagents/agent-<id>.meta.json` next to each
    sub-agent transcript. Its `toolUseId` is the id of the `Task` tool_use in
    the parent that launched it — the join key. Returns:

        { toolUseId: {agentId, agentType, description, name, file, file_rel} }

    Empty dict when there is no subagents/ directory (older sessions, or a
    sub-agent transcript being parsed in its own right).
    """
    base, _ = os.path.splitext(jsonl_file)        # .../e25e3b92-...
    subdir = os.path.join(base, 'subagents')
    index = {}
    if not os.path.isdir(subdir):
        return index
    for meta_path in sorted(glob.glob(os.path.join(subdir, '*.meta.json'))):
        try:
            with open(meta_path, errors='replace') as fh:
                meta = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        tool_use_id = meta.get('toolUseId')
        if not tool_use_id:
            continue
        agent_file = meta_path[:-len('.meta.json')] + '.jsonl'
        agent_id = os.path.basename(agent_file)[len('agent-'):-len('.jsonl')] \
            if os.path.basename(agent_file).startswith('agent-') else None
        index[tool_use_id] = {
            'agentId': agent_id,
            'agentType': meta.get('agentType'),
            'description': meta.get('description'),
            'name': meta.get('name'),
            'file': agent_file,
            'file_rel': os.path.relpath(agent_file, os.path.dirname(jsonl_file)),
            'exists': os.path.exists(agent_file),
        }
    return index


# ── Core parse ──────────────────────────────────────────────────────────────

def parse_transcript(jsonl_file, subagent_index=None):
    """Read a transcript .jsonl in full and return {meta, records}.

    `records` is the ordered list of conversation blocks. Blocks mirror how a
    reader segments the conversation: consecutive tool-only assistant turns are
    grouped into one `tools` block (matching the old renderer's flush_tools),
    ambient lines (mode changes, hook summaries) become `event` blocks, and a
    `Task` tool call carries a resolved `subagent` object when its sub-agent
    transcript is on disk.

    `meta` carries session-level rollups (model, token totals, tool histogram,
    git branch, permission mode, counts) the header needs.
    """
    if subagent_index is None:
        subagent_index = load_subagent_index(jsonl_file)

    # Count every sub-agent transcript on disk, not just the ones whose meta.json
    # carries a toolUseId join key — some sessions write metas without it, and
    # those sub-agents still ran and still deserve to be counted/listed.
    _base = os.path.splitext(jsonl_file)[0]
    agent_transcripts = glob.glob(os.path.join(_base, 'subagents', 'agent-*.jsonl'))

    records = []
    pending_tools = []           # consecutive tool-only turns, grouped on flush
    last_line_uuid = ''          # anchor for records whose lines carry no uuid
    mode_id_counts = {}          # (anchor, mode) ordinals for repeated flips
    tool_counter = Counter()
    seq = 0

    # One logical assistant message is written as several JSONL lines — one per
    # content block (thinking, text, each tool_use) — and `usage` is repeated
    # identically on every one of those lines. Counting usage per line would
    # multiply token totals by the block count, so we tally each message.id once.
    seen_usage_ids = set()

    # On resume/compaction a handful of turns are re-emitted verbatim, repeating
    # their tool_use blocks. tool_use ids are unique per call, so we drop a call
    # whose id we have already emitted — otherwise the same card renders twice.
    seen_tool_ids = set()

    meta = {
        'session_id': os.path.splitext(os.path.basename(jsonl_file))[0],
        'model': 'unknown',
        'ai_title': '',
        'git_branch': '',
        'permission_mode': '',
        'tokens': {'input': 0, 'output': 0, 'cache_read': 0},
        'counts': {'user': 0, 'assistant': 0, 'tools': 0, 'events': 0, 'subagents': 0},
        'hook_summaries': 0,
        'hook_errors': 0,
        'subagent_count': len(agent_transcripts),
        'subagent_linked': len(subagent_index),
    }

    def next_seq():
        nonlocal seq
        seq += 1
        return seq

    def rec_id(line_uuid, prefix, ts_iso, payload):
        """A record's identity, stable across re-parses whatever happens to the
        file around it. `seq` is positional and renumbers on any mid-file
        rewrite; identity comes from the source line's uuid, or failing that
        from the content itself (crc, never a per-process salted hash)."""
        if line_uuid:
            return line_uuid
        crc = zlib.crc32(str(payload).encode('utf-8', 'replace')) & 0xffffffff
        return f"{prefix}:{ts_iso}:{crc:08x}"

    def flush_tools(still_open=False):
        """Emit accumulated tool calls as one grouped `tools` block.

        `still_open` marks a group we flushed only because the file ended, not
        because anything closed the burst. That group can still gain tools on a
        later read while keeping this same seq — so a live-tailing client, which
        asks for `seq > n`, would never hear about the rest of it. Marking it
        lets the reader resend it; see `open` in the /data contract.
        """
        nonlocal pending_tools
        if not pending_tools:
            return
        # The group's identity is its FIRST member: a group flushed `open`
        # keeps gaining tools, but in an append-only file its first member
        # never changes — so the id stays put while the group grows.
        first = pending_tools[0]
        rec = {
            'seq': next_seq(),
            'id': first.get('id') or rec_id(first.get('line_uuid', ''), 't',
                                            first.get('ts_iso', ''), first.get('name', '')),
            'role': 'tools',
            'kind': 'tools',
            'ts': pending_tools[-1].get('ts', ''),
            'ts_full': pending_tools[-1].get('ts_full', ''),
            'ts_iso': pending_tools[-1].get('ts_iso', ''),
            'tools': pending_tools,
            'tokens': {'out': sum(t.get('tokens_out', 0) for t in pending_tools)},
            'sidechain': any(t.get('sidechain') for t in pending_tools),
        }
        if still_open:
            rec['open'] = True
        records.append(rec)
        meta['counts']['tools'] += 1
        pending_tools = []

    with open(jsonl_file, 'r', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get('type', '')
            line_uuid = obj.get('uuid') or ''
            if line_uuid:
                last_line_uuid = line_uuid
            ts_iso = obj.get('timestamp', '')
            ts = _fmt_ts(ts_iso)
            ts_full = _fmt_ts_full(ts_iso)
            sidechain = bool(obj.get('isSidechain', False))
            if obj.get('gitBranch'):
                meta['git_branch'] = obj['gitBranch']

            # ── Ambient / lightweight events ────────────────────────────────
            if msg_type in ('ai-title', 'custom-title'):
                t = obj.get('aiTitle') or obj.get('customTitle') or ''
                if t:
                    meta['ai_title'] = t
                continue

            if msg_type in ('permission-mode', 'mode'):
                pm = obj.get('permissionMode') or obj.get('mode') or ''
                if pm and pm != meta['permission_mode']:
                    meta['permission_mode'] = pm
                    flush_tools()
                    # mode lines carry no uuid AND no timestamp (verified on
                    # real transcripts: {type, mode, sessionId} only), so the
                    # identity anchors to the last uuid-bearing line, with an
                    # ordinal for repeated identical flips under one anchor.
                    mode_base = f"mode:{last_line_uuid}:{pm}"
                    mode_n = mode_id_counts.get(mode_base, 0)
                    mode_id_counts[mode_base] = mode_n + 1
                    records.append({
                        'seq': next_seq(),
                        'id': mode_base if mode_n == 0 else f"{mode_base}:{mode_n}",
                        'role': 'event', 'kind': 'event',
                        'event_type': 'mode-change', 'cls': 'mode',
                        'text': f"permission mode → {pm}",
                        'ts': ts, 'ts_full': ts_full, 'ts_iso': ts_iso,
                        'sidechain': sidechain,
                    })
                    meta['counts']['events'] += 1
                continue

            if msg_type == 'system':
                subtype = obj.get('subtype', '')
                if subtype == 'stop_hook_summary':
                    hc = obj.get('hookCount') or 0
                    he = obj.get('hookErrors') or []
                    pc = obj.get('preventedContinuation') or False
                    if hc or he or pc:
                        meta['hook_summaries'] += 1
                        meta['hook_errors'] += len(he)
                        flush_tools()
                        records.append({
                            'seq': next_seq(),
                            'id': rec_id(line_uuid, 'hook', ts_iso, f"{hc}:{len(he)}:{pc}"),
                            'role': 'event', 'kind': 'event',
                            'event_type': 'hook-summary',
                            'cls': 'err' if (he or pc) else 'hooks',
                            'hook_count': hc,
                            'errors': he,
                            'prevented_continuation': bool(pc),
                            'ts': ts, 'ts_full': ts_full, 'ts_iso': ts_iso,
                            'sidechain': sidechain,
                        })
                        meta['counts']['events'] += 1
                continue

            # ── User turns ──────────────────────────────────────────────────
            if msg_type == 'user':
                flush_tools()
                msg = obj.get('message', {})
                content = ''
                if isinstance(msg, dict):
                    blocks = msg.get('content', [])
                    if isinstance(blocks, str):
                        content = blocks          # plain-string content (slash-commands, prose)
                    else:
                        for block in blocks:
                            if isinstance(block, dict):
                                if block.get('type') == 'text':
                                    content += block.get('text', '')
                            elif isinstance(block, str):
                                content += block
                elif isinstance(msg, str):
                    content = msg
                if content.strip():
                    sysrem = content.count('<system-reminder>')
                    records.append({
                        'seq': next_seq(),
                        'id': rec_id(line_uuid, 'u', ts_iso, content),
                        'role': 'user', 'kind': 'user',
                        'text': content.strip(),
                        'system_reminders': sysrem,
                        'ts': ts, 'ts_full': ts_full, 'ts_iso': ts_iso,
                        'sidechain': sidechain,
                    })
                    meta['counts']['user'] += 1
                continue

            # ── Assistant turns ─────────────────────────────────────────────
            if msg_type == 'assistant':
                msg = obj.get('message', {})
                m = msg.get('model', '')
                if m:
                    meta['model'] = m
                msg_id = msg.get('id')
                usage = msg.get('usage', {})
                # Count usage once per message.id. A missing id (None) must never
                # become a shared key — otherwise the first id-less message would
                # swallow every later id-less message's tokens.
                if not msg_id or msg_id not in seen_usage_ids:
                    if msg_id:
                        seen_usage_ids.add(msg_id)
                    meta['tokens']['input'] += usage.get('input_tokens', 0)
                    meta['tokens']['output'] += usage.get('output_tokens', 0)
                    meta['tokens']['cache_read'] += usage.get('cache_read_input_tokens', 0)

                text_part = ''
                tool_calls = []
                for block in msg.get('content', []):
                    if not isinstance(block, dict):
                        continue
                    if block.get('type') == 'text':
                        text_part += block.get('text', '')
                    elif block.get('type') == 'tool_use':
                        tid = block.get('id')
                        if tid and tid in seen_tool_ids:
                            continue
                        if tid:
                            seen_tool_ids.add(tid)
                        tname = block.get('name', '?')
                        tinp = block.get('input', {})
                        tool_counter[tname] += 1
                        call = {
                            'name': tname,
                            'id': block.get('id'),
                            'line_uuid': line_uuid,
                            'message_id': msg_id,
                            'input': tinp,
                            'preview': tool_preview(tname, tinp),
                            'paths': file_paths_in_input(tname, tinp),
                            'ts': ts, 'ts_full': ts_full, 'ts_iso': ts_iso,
                            'tokens_out': usage.get('output_tokens', 0),
                            'sidechain': sidechain,
                        }
                        # Resolve a Task dispatch to the sub-agent it launched.
                        if tname in ('Task', 'Agent'):
                            sub = subagent_index.get(block.get('id'))
                            if sub:
                                call['subagent'] = sub
                                meta['counts']['subagents'] += 1
                            else:
                                # No transcript on disk — still label from input.
                                call['subagent'] = {
                                    'agentType': (tinp or {}).get('subagent_type'),
                                    'description': (tinp or {}).get('description'),
                                    'exists': False,
                                }
                        tool_calls.append(call)

                if text_part.strip():
                    flush_tools()
                    records.append({
                        'seq': next_seq(),
                        'id': rec_id(line_uuid, 'a', ts_iso, text_part),
                        'role': 'assistant', 'kind': 'assistant',
                        'text': text_part.strip(),
                        'message_id': msg_id,
                        'model': meta['model'],
                        'tokens': {
                            'in': usage.get('input_tokens', 0),
                            'out': usage.get('output_tokens', 0),
                            'cache': usage.get('cache_read_input_tokens', 0),
                        },
                        'ts': ts, 'ts_full': ts_full, 'ts_iso': ts_iso,
                        'sidechain': sidechain,
                    })
                    meta['counts']['assistant'] += 1
                    pending_tools.extend(tool_calls)
                else:
                    pending_tools.extend(tool_calls)
                continue

            # Line types without a conversation body of their own (attachment,
            # tool_result, file-history-snapshot) are not emitted as blocks. The
            # informative ones surface as typed `event` records once modelled.

    # Nothing closed this burst — the file just ended. It may still be growing.
    flush_tools(still_open=True)

    # Tool histogram, most-used first.
    meta['tools_breakdown'] = [
        {'name': n, 'count': c} for n, c in tool_counter.most_common()
    ]
    meta['total_tool_calls'] = sum(tool_counter.values())
    meta['total_records'] = len(records)
    return {'meta': meta, 'records': records}


# ── CLI ─────────────────────────────────────────────────────────────────────

def _resolve_agent_file(parent_jsonl, agent_id):
    """Locate a sub-agent transcript by id under the parent's subagents/ dir."""
    base, _ = os.path.splitext(parent_jsonl)
    cand = os.path.join(base, 'subagents', f'agent-{agent_id}.jsonl')
    return cand if os.path.exists(cand) else None


def main(argv):
    args = list(argv)
    since = None
    agent_id = None
    positional = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '--since':
            since = int(args[i + 1]); i += 2; continue
        if a == '--agent':
            agent_id = args[i + 1]; i += 2; continue
        positional.append(a); i += 1

    if not positional:
        sys.stderr.write("usage: transcript.py <session.jsonl> [--since SEQ] [--agent ID]\n")
        return 2

    jsonl_file = positional[0]
    if not os.path.exists(jsonl_file):
        sys.stderr.write(f"transcript: no such file: {jsonl_file}\n")
        return 1

    target = jsonl_file
    if agent_id:
        target = _resolve_agent_file(jsonl_file, agent_id)
        if not target:
            sys.stderr.write(f"transcript: no sub-agent transcript for id {agent_id}\n")
            return 1

    result = parse_transcript(target)
    if since is not None:
        # Same contract as the hub's /data: a group flushed open keeps its
        # seq while still growing, so the tail must resend it.
        result['records'] = [r for r in result['records']
                             if r['seq'] > since or r.get('open')]
        result['meta']['since'] = since

    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
