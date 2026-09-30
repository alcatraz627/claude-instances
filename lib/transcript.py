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
import copy
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


# How much of a tool's output, or of a thinking block, rides along in /data.
# The rest is fetched on expand via /data?result=<id>.
RESULT_PREVIEW_CHARS = 300
THINKING_PREVIEW_CHARS = 200


def tool_result_text(content):
    """The readable text of a tool_result block's content.

    Content is either a plain string or a list of typed parts. Text parts are
    joined; images and tool references become a short bracketed marker, since
    a base64 image has no business in a text preview.
    """
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return '' if content is None else str(content)
    parts = []
    for p in content:
        if isinstance(p, str):
            parts.append(p)
        elif isinstance(p, dict):
            kind = p.get('type')
            if kind == 'text':
                parts.append(p.get('text', ''))
            elif kind == 'image':
                parts.append('[image]')
            elif kind == 'tool_reference':
                parts.append(f"[tool reference: {p.get('tool_name', '?')}]")
            else:
                parts.append(f"[{kind or 'part'}]")
    return '\n'.join(parts)


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

def mark_awaiting_results(records):
    """Mark the newest tools group open while its calls still await output,
    so a live reader is resent it and receives the results when they land.

    Claude answers only after every result is in, so any group followed by
    more of Claude's own output is complete (or was interrupted).
    """
    for rec in reversed(records):
        role = rec.get('role')
        if role in ('assistant', 'thinking'):
            return
        if role == 'tools':
            if any('result' not in t for t in rec['tools']):
                rec['open'] = True
            return

class TranscriptParser:
    """A transcript read so far, able to take more lines as the file grows.

    Transcripts are append-only, so a live session never needs a full re-read:
    `feed_file` parses only the bytes past the last read, and `snapshot` hands
    out a view that later feeding cannot change. `parse_transcript` is the
    one-shot form of the same thing.

    Records mirror how a reader segments the conversation: consecutive tool
    calls are grouped into one `tools` block, ambient lines (mode changes, hook
    summaries) become `event` blocks, thinking becomes a `thinking` block, and
    a `Task` call carries its resolved `subagent` when the transcript exists.
    """

    def __init__(self, jsonl_file, subagent_index=None):
        self.jsonl_file = jsonl_file
        self.subagent_index = (load_subagent_index(jsonl_file)
                               if subagent_index is None else subagent_index)
        self._index_given = subagent_index is not None
        self.offset = 0              # bytes of the file consumed so far
        self.records = []
        self.pending_tools = []      # consecutive tool calls not yet grouped
        self.last_line_uuid = ''     # anchor for records whose lines carry no uuid
        self.mode_id_counts = {}     # (anchor, mode) ordinals for repeated flips
        self.tool_counter = Counter()
        self.seq = 0
        # One assistant message is written as several lines (one per content
        # block) with the same `usage` on each; tally each message.id once.
        self.seen_usage_ids = set()
        # Resume and compaction re-emit a few turns verbatim; drop a call or a
        # thought already seen so nothing renders twice.
        self.seen_tool_ids = set()
        self.seen_thinking = set()
        # Each call by tool_use id, so a later tool_result finds its call.
        self.calls_by_id = {}
        # Full bodies kept out of /data (tool output, thinking), by id.
        self.blobs = {}
        # Task calls whose sub-agent transcript had not appeared yet.
        self.unresolved_agents = []
        self.meta = {
            'session_id': os.path.splitext(os.path.basename(jsonl_file))[0],
            'model': 'unknown',
            'ai_title': '',
            'git_branch': '',
            'permission_mode': '',
            'tokens': {'input': 0, 'output': 0, 'cache_read': 0},
            'counts': {'user': 0, 'assistant': 0, 'tools': 0, 'events': 0, 'subagents': 0},
            'hook_summaries': 0,
            'hook_errors': 0,
            'tool_results': 0,
            'tool_errors': 0,
            'thinking': 0,
            'thinking_hidden': 0,
        }


    def feed_file(self, final=False):
        """Parse the bytes appended since the last call.

        Only whole lines are consumed; a line still being written waits for
        the next call. `final` also takes an unterminated last line, for a
        one-shot read of a finished file.
        """
        with open(self.jsonl_file, 'rb') as f:
            f.seek(self.offset)
            data = f.read()
        if not data:
            return
        end = len(data) if final else data.rfind(b'\n') + 1
        if end <= 0:
            return
        for raw in data[:end].split(b'\n'):
            self.feed_line(raw.decode('utf-8', 'replace'))
        self.offset += end
        if self.unresolved_agents:
            self._resolve_late_agents()

    def feed_line(self, line):
        line = line.strip()
        if not line:
            return
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return
        if not isinstance(obj, dict):
            return
        meta = self.meta
        msg_type = obj.get('type', '')
        line_uuid = obj.get('uuid') or ''
        if line_uuid:
            self.last_line_uuid = line_uuid
        ts_iso = obj.get('timestamp', '')
        stamp = {'ts': _fmt_ts(ts_iso), 'ts_full': _fmt_ts_full(ts_iso), 'ts_iso': ts_iso}
        sidechain = bool(obj.get('isSidechain', False))
        if obj.get('gitBranch'):
            meta['git_branch'] = obj['gitBranch']

        if msg_type in ('ai-title', 'custom-title'):
            t = obj.get('aiTitle') or obj.get('customTitle') or ''
            if t:
                meta['ai_title'] = t
            return

        if msg_type in ('permission-mode', 'mode'):
            pm = obj.get('permissionMode') or obj.get('mode') or ''
            if pm and pm != meta['permission_mode']:
                meta['permission_mode'] = pm
                self._flush_tools()
                # Mode lines carry no uuid and no timestamp, so the identity
                # anchors to the last uuid-bearing line, plus an ordinal for
                # repeated identical flips under one anchor.
                mode_base = f"mode:{self.last_line_uuid}:{pm}"
                mode_n = self.mode_id_counts.get(mode_base, 0)
                self.mode_id_counts[mode_base] = mode_n + 1
                self._add({
                    'id': mode_base if mode_n == 0 else f"{mode_base}:{mode_n}",
                    'role': 'event', 'kind': 'event',
                    'event_type': 'mode-change', 'cls': 'mode',
                    'text': f"permission mode → {pm}",
                    **stamp, 'sidechain': sidechain,
                })
                meta['counts']['events'] += 1
            return

        if msg_type == 'system':
            if obj.get('subtype', '') == 'stop_hook_summary':
                hc = obj.get('hookCount') or 0
                he = obj.get('hookErrors') or []
                pc = obj.get('preventedContinuation') or False
                if hc or he or pc:
                    meta['hook_summaries'] += 1
                    meta['hook_errors'] += len(he)
                    self._flush_tools()
                    self._add({
                        'id': _rec_id(line_uuid, 'hook', ts_iso, f"{hc}:{len(he)}:{pc}"),
                        'role': 'event', 'kind': 'event',
                        'event_type': 'hook-summary',
                        'cls': 'err' if (he or pc) else 'hooks',
                        'hook_count': hc,
                        'errors': he,
                        'prevented_continuation': bool(pc),
                        **stamp, 'sidechain': sidechain,
                    })
                    meta['counts']['events'] += 1
            return

        if msg_type == 'user':
            self._flush_tools()
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
                            elif block.get('type') == 'tool_result':
                                self._attach_result(block)
                        elif isinstance(block, str):
                            content += block
            elif isinstance(msg, str):
                content = msg
            if content.strip():
                self._add({
                    'id': _rec_id(line_uuid, 'u', ts_iso, content),
                    'role': 'user', 'kind': 'user',
                    'text': content.strip(),
                    'system_reminders': content.count('<system-reminder>'),
                    **stamp, 'sidechain': sidechain,
                })
                meta['counts']['user'] += 1
            return

        if msg_type == 'assistant':
            self._assistant(obj, line_uuid, ts_iso, stamp, sidechain)
        # Other line types (attachment, file-history-snapshot) have no body.

    def _assistant(self, obj, line_uuid, ts_iso, stamp, sidechain):
        meta = self.meta
        msg = obj.get('message', {})
        if not isinstance(msg, dict):
            return
        m = msg.get('model', '')
        if m:
            meta['model'] = m
        msg_id = msg.get('id')
        usage = msg.get('usage') or {}
        # A missing id must never become a shared key, or the first id-less
        # message would swallow every later one's tokens.
        if not msg_id or msg_id not in self.seen_usage_ids:
            if msg_id:
                self.seen_usage_ids.add(msg_id)
            meta['tokens']['input'] += usage.get('input_tokens', 0)
            meta['tokens']['output'] += usage.get('output_tokens', 0)
            meta['tokens']['cache_read'] += usage.get('cache_read_input_tokens', 0)

        text_part = ''
        tool_calls = []
        for block in msg.get('content', []):
            if not isinstance(block, dict):
                continue
            kind = block.get('type')
            if kind == 'text':
                text_part += block.get('text', '')
            elif kind in ('thinking', 'redacted_thinking'):
                self._thinking(block, line_uuid, ts_iso, stamp, sidechain)
            elif kind == 'tool_use':
                call = self._tool_use(block, line_uuid, msg_id, usage, stamp, sidechain)
                if call:
                    tool_calls.append(call)

        if text_part.strip():
            self._flush_tools()
            self._add({
                'id': _rec_id(line_uuid, 'a', ts_iso, text_part),
                'role': 'assistant', 'kind': 'assistant',
                'text': text_part.strip(),
                'message_id': msg_id,
                'model': meta['model'],
                'tokens': {
                    'in': usage.get('input_tokens', 0),
                    'out': usage.get('output_tokens', 0),
                    'cache': usage.get('cache_read_input_tokens', 0),
                },
                **stamp, 'sidechain': sidechain,
            })
            meta['counts']['assistant'] += 1
        self.pending_tools.extend(tool_calls)

    def _thinking(self, block, line_uuid, ts_iso, stamp, sidechain):
        thought = (block.get('thinking') or '').strip()
        if not thought:
            self.meta['thinking_hidden'] += 1     # redacted: nothing to show
            return
        th_id = f"{_rec_id(line_uuid, 'th', ts_iso, thought)}:think"
        if th_id in self.seen_thinking:
            return
        self.seen_thinking.add(th_id)
        self._flush_tools()
        self.blobs[th_id] = thought
        self._add({
            'id': th_id,
            'role': 'thinking', 'kind': 'thinking',
            'preview': _short(thought.replace('\n', ' '), THINKING_PREVIEW_CHARS),
            'chars': len(thought),
            'words': len(thought.split()),
            **stamp, 'sidechain': sidechain,
        })
        self.meta['thinking'] += 1

    def _tool_use(self, block, line_uuid, msg_id, usage, stamp, sidechain):
        tid = block.get('id')
        if tid and tid in self.seen_tool_ids:
            return None
        if tid:
            self.seen_tool_ids.add(tid)
        tname = block.get('name', '?')
        tinp = block.get('input', {})
        self.tool_counter[tname] += 1
        call = {
            'name': tname,
            'id': tid,
            'line_uuid': line_uuid,
            'message_id': msg_id,
            'input': tinp,
            'preview': tool_preview(tname, tinp),
            'paths': file_paths_in_input(tname, tinp),
            **stamp,
            'tokens_out': usage.get('output_tokens', 0),
            'sidechain': sidechain,
        }
        if tname in ('Task', 'Agent'):
            sub = self.subagent_index.get(tid)
            if sub:
                call['subagent'] = sub
                self.meta['counts']['subagents'] += 1
            else:
                # No transcript on disk yet; label from the input meanwhile.
                call['subagent'] = {
                    'agentType': (tinp or {}).get('subagent_type'),
                    'description': (tinp or {}).get('description'),
                    'exists': False,
                }
                if tid:
                    self.unresolved_agents.append(call)
        if tid:
            self.calls_by_id[tid] = call
        return call

    def _resolve_late_agents(self):
        """A sub-agent's meta file can land after its Task line was read."""
        if self._index_given:
            return
        self.subagent_index = load_subagent_index(self.jsonl_file)
        still = []
        for call in self.unresolved_agents:
            sub = self.subagent_index.get(call['id'])
            if sub:
                call['subagent'] = sub
                self.meta['counts']['subagents'] += 1
            else:
                still.append(call)
        self.unresolved_agents = still

    def _add(self, rec):
        self.seq += 1
        rec['seq'] = self.seq
        self.records.append(rec)

    def _group(self, calls, seq):
        """One `tools` block from consecutive calls. Its identity is its first
        call, which never changes while the group grows."""
        first = calls[0]
        return {
            'seq': seq,
            'id': first.get('id') or _rec_id(first.get('line_uuid', ''), 't',
                                            first.get('ts_iso', ''), first.get('name', '')),
            'role': 'tools',
            'kind': 'tools',
            'ts': calls[-1].get('ts', ''),
            'ts_full': calls[-1].get('ts_full', ''),
            'ts_iso': calls[-1].get('ts_iso', ''),
            'tools': calls,
            'tokens': {'out': sum(t.get('tokens_out', 0) for t in calls)},
            'sidechain': any(t.get('sidechain') for t in calls),
        }

    def _flush_tools(self):
        if not self.pending_tools:
            return
        self.seq += 1
        self.records.append(self._group(self.pending_tools, self.seq))
        self.meta['counts']['tools'] += 1
        self.pending_tools = []

    def _attach_result(self, block):
        """Pair a tool_result with its call by tool_use id: the call gets a
        preview and an error flag, the full text goes to `blobs`."""
        tid = block.get('tool_use_id')
        if not tid:
            return
        text = tool_result_text(block.get('content'))
        is_error = bool(block.get('is_error'))
        self.blobs[tid] = text
        call = self.calls_by_id.get(tid)
        if call is None:
            return
        if 'result' not in call:
            self.meta['tool_results'] += 1
            if is_error:
                self.meta['tool_errors'] += 1
        call['result'] = {
            'preview': _short(text, RESULT_PREVIEW_CHARS),
            'chars': len(text),
            'lines': text.count('\n') + 1 if text else 0,
            'is_error': is_error,
        }
        if is_error:
            call['is_error'] = True
        else:
            call.pop('is_error', None)


    def snapshot(self):
        """{meta, records, blobs, calls} as of now.

        Tools records and their calls are copied, since later results attach
        to the live ones; everything else is never changed once added. A burst
        of calls nothing has closed yet is flushed `open`: it may still grow
        under the same seq, so a live reader must be resent it.
        """
        records = []
        for r in self.records:
            if r['role'] == 'tools':
                r = dict(r)
                r['tools'] = [dict(t) for t in r['tools']]
            records.append(r)
        meta = copy.deepcopy(self.meta)
        if self.pending_tools:
            grp = self._group([dict(t) for t in self.pending_tools], self.seq + 1)
            grp['open'] = True
            records.append(grp)
            meta['counts']['tools'] += 1
        mark_awaiting_results(records)
        base = os.path.splitext(self.jsonl_file)[0]
        # Count every sub-agent transcript on disk, including ones whose meta
        # file lacks the join key: they still ran.
        meta['subagent_count'] = len(glob.glob(os.path.join(base, 'subagents', 'agent-*.jsonl')))
        meta['subagent_linked'] = len(self.subagent_index)
        meta['tools_breakdown'] = [
            {'name': n, 'count': c} for n, c in self.tool_counter.most_common()
        ]
        meta['total_tool_calls'] = sum(self.tool_counter.values())
        meta['total_records'] = len(records)
        return {'meta': meta, 'records': records, 'blobs': self.blobs,
                'calls': self.calls_by_id}


def _rec_id(line_uuid, prefix, ts_iso, payload):
    """A record's identity, stable across re-parses whatever happens around
    it: the source line's uuid, else a crc of the content (never a salted
    hash). `seq` is only a position and renumbers on a mid-file rewrite."""
    if line_uuid:
        return line_uuid
    crc = zlib.crc32(str(payload).encode('utf-8', 'replace')) & 0xffffffff
    return f"{prefix}:{ts_iso}:{crc:08x}"


def parse_transcript(jsonl_file, subagent_index=None, with_parser=False):
    """Read a transcript .jsonl in full and return {meta, records, blobs, calls}.

    With `with_parser`, the result also carries the `parser`, which can take
    the lines appended later without re-reading the file.
    """
    parser = TranscriptParser(jsonl_file, subagent_index)
    parser.feed_file(final=not with_parser)
    result = parser.snapshot()
    if with_parser:
        result['parser'] = parser
    return result


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

    result.pop('blobs', None)
    result.pop('calls', None)
    json.dump(result, sys.stdout, ensure_ascii=False)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
