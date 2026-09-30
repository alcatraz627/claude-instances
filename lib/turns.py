"""Who wrote a user-role line in a Claude Code transcript.

Claude Code also writes slash commands, hook feedback, peer messages, task
notifications and skill bodies as user-role lines. scan.sh and transcript.py
both ask classify(), so cards, chapter titles and the "last:" line agree on
what the owner said. classify() returns None for non-turns (tool results,
sub-agent lines), else {kind, text, label, command, args}; the kinds are
OWNER (typed, shell, command), clear, HARNESS (hook, peer, task, system),
injected (skill bodies, image stubs) and hidden (caveats, command output).
"""

import re

HARNESS = frozenset({'hook', 'peer', 'task', 'system'})
OWNER = frozenset({'typed', 'shell', 'command'})

_REMINDER = re.compile(r'<system-reminder>.*?</system-reminder>', re.DOTALL)
_CMD_NAME = re.compile(r'<command-name>\s*(.*?)\s*</command-name>', re.DOTALL)
_CMD_ARGS = re.compile(r'<command-args>(.*?)</command-args>', re.DOTALL)
_BASH_IN = re.compile(r'<bash-input>(.*?)</bash-input>', re.DOTALL)
_TAG = re.compile(r'<[^>]+>')


def user_text(obj):
    """The text blocks of a user line joined, or None when it carries a tool result."""
    msg = obj.get('message', {})
    content = msg.get('content', []) if isinstance(msg, dict) else msg
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ''
    text = ''
    for block in content:
        if isinstance(block, dict):
            if block.get('type') == 'tool_result':
                return None
            if block.get('type') == 'text':
                text += block.get('text', '')
        elif isinstance(block, str):
            text += block
    return text


def _first_line(s):
    for line in s.splitlines():
        line = _TAG.sub(' ', line).strip()
        if line:
            return ' '.join(line.split())
    return ''


def _attr(s, name):
    m = re.search(name + r'="([^"]*)"', s)
    return m.group(1) if m else ''


def _tag(s, name):
    m = re.search(rf'<{name}>(.*?)</{name}>', s, re.DOTALL)
    return ' '.join(m.group(1).split()) if m else ''


# System lines Claude Code writes often, named in a few words for their chip.
_SYSTEM_NAMES = (
    ('A session-scoped Stop hook is now active', 'goal armed'),
    ('[Your previous response had no visible output', 'asked to reply visibly'),
    ('The user named this session', 'session renamed'),
    ('[Request interrupted by user', 'interrupted'),
)


def _short(s, n=80):
    """The first clause of s, or its first n characters cut at a word."""
    m = re.match(r'(.{8,}?)(?:[.:;!?](?:\s|$))', s)
    head = m.group(1) if m and len(m.group(1)) <= n else s
    if len(head) <= n:
        return head
    return head[:n].rsplit(' ', 1)[0] + '…'


def _turn(kind, text, label='', command='', args=''):
    if not label and kind == 'system':
        clean = _REMINDER.sub(lambda m: m.group(0)[len('<system-reminder>'):-len('</system-reminder>')], text).strip()
        label = next((name for prefix, name in _SYSTEM_NAMES if clean.startswith(prefix)), '') \
            or _short(_first_line(clean))
    return {'kind': kind, 'text': text, 'label': label or _first_line(text),
            'command': command, 'args': args}


def _task_label(s):
    summary = _tag(s, 'summary')
    if summary:
        return summary
    status = _tag(s, 'status')
    return f'task {status}' if status else 'task notification'


def classify(obj):
    if not isinstance(obj, dict) or obj.get('type') != 'user' or obj.get('isSidechain'):
        return None
    raw = user_text(obj)
    if raw is None:
        return None
    text = raw.strip()
    origin = obj.get('origin')
    okind = origin.get('kind') if isinstance(origin, dict) else None
    turn_origin = obj.get('turnOrigin')

    if okind == 'task-notification' or turn_origin == 'task_notification' \
            or text.startswith('<task-notification>'):
        return _turn('task', text, _task_label(text))
    if okind == 'auto-continuation' or turn_origin == 'auto_continuation':
        return _turn('system', text)
    if turn_origin == 'scheduled':
        return _turn('system', text, 'scheduled: ' + _short(_first_line(text), 60))

    if text.startswith('Base directory for this skill:'):   # meta flag not always set
        return _turn('injected', text)
    if obj.get('isMeta'):
        if text.startswith('[Image'):
            return _turn('injected', text)
        if text.startswith('<local-command-caveat>'):
            return _turn('hidden', text)
        if text.startswith('Stop hook feedback:'):
            body = text[len('Stop hook feedback:'):].strip()
            head = _first_line(body).split(' — ')[0]   # hook messages lead with a heading
            return _turn('hook', text, 'Stop hook: ' + (_short(head.lstrip('['), 60) or 'feedback'))
        return _turn('system', text)

    if text.startswith('Another Claude session sent a message:') or text.startswith('<teammate-message'):
        who = _attr(text, 'teammate_id')
        what = _attr(text, 'summary') or _first_line(_TAG.sub(' ', text.split(':', 1)[-1]))
        status = re.search(r'"type"\s*:\s*"([a-z_]+)_notification"', what)
        if status:   # a structured status ping, e.g. {"type":"idle_notification",...}
            what = status.group(1).replace('_', ' ')
        return _turn('peer', text, (f'{who}: ' if who else '') + what)
    if text.startswith('[Request interrupted by user'):
        return _turn('system', text)
    if text.startswith('<local-command-stdout>') or text.startswith('<local-command-stderr>') \
            or text.startswith('<bash-stdout>') or text.startswith('<bash-stderr>') \
            or text.startswith('<local-command-caveat>'):
        return _turn('hidden', text)

    cmd = _CMD_NAME.search(text)
    if cmd:
        name = cmd.group(1).strip()
        a = _CMD_ARGS.search(text)
        args = ' '.join(a.group(1).split()) if a else ''
        kind = 'clear' if name == '/clear' else 'command'
        return _turn(kind, (name + ' ' + args).strip(), command=name, args=args)
    bash = _BASH_IN.match(text)
    if bash:
        return _turn('shell', '! ' + bash.group(1).strip())

    clean = _REMINDER.sub('', text).strip()
    if not clean:
        return _turn('system', text)
    # a pasted block arrives wrapped (<pasted_content id="…">); the wrapper is not what was said
    clean = re.sub(r'^\s*</?pasted_content[^>]*>\s*$', '', clean, flags=re.M).strip() or clean
    return _turn('typed', clean)
