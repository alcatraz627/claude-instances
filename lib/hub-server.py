#!/usr/bin/env python3
"""The session hub — one server that makes every Claude session readable from
any device on your Tailscale network (your phone, a tablet, another laptop).

Where the old transcript viewer span up a throwaway server per Claude PID, bound
to loopback, on a port you had to already know — this is a single, long-lived
front door:

    http://<this-mac>:5400/            a live index of all your sessions
    http://<this-mac>:5400/s/<id>      one session's full transcript
    http://<this-mac>:5400/s/<id>/data the transcript as JSON (the SPA's feed)

It binds to the machine's Tailscale address by default, so it is reachable from
your other tailnet devices but NOT from the open network or a coffee-shop LAN.
With Tailscale down it falls back to localhost and behaves like the old local
viewer.

The data comes from two pieces already in this repo, reused in-process:
  - scan.sh  → the live/recent session list the menu bar already computes
  - transcript.py → the normalized per-session conversation model

CLI:
    hub-server.py [--host HOST] [--port PORT]
        --host   interface to bind. Default: the tailnet IP if up, else 127.0.0.1.
        --port   default 5400.
    Env overrides: CLAUDE_HUB_HOST, CLAUDE_HUB_PORT.
"""

import sys
import os
import re
import json
import glob
import time
import signal
import socket
import threading
import subprocess
import http.server
import socketserver
import urllib.parse

# transcript.py lives next to this file — import it so /data can parse a session
# directly (~64ms for a 10MB log) instead of shelling out per request.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import transcript
except Exception:
    transcript = None

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
SCAN_SCRIPT = os.path.join(HERE, "scan.sh")
APP_HTML = os.path.join(HERE, "transcript-app.html")
INDEX_HTML = os.path.join(HERE, "hub-index.html")

# A session id is a UUID; allow the loose [\w-] so older/odd ids still route.
SID_RE = re.compile(r"^/s/([\w-]+)(?:/(data))?/?$")


def _env(name, default):
    """The one place this server reads its environment. Two optional knobs,
    both with defaults; route any future reads through here too."""
    return os.environ.get(name, default)


# Find the address other tailnet devices can reach us at.

def tailnet_ip():
    """Return this machine's Tailscale IPv4 (100.64.0.0/10), or None if down.

    Tailscale hands every device a stable address in the CGNAT range
    100.64.x.x–100.127.x.x on a utun interface. Binding the server to that
    address (rather than 0.0.0.0) is what scopes it to the tailnet: peers on
    your tailnet can reach it; the local coffee-shop LAN cannot.
    """
    try:
        out = subprocess.run(["ifconfig"], capture_output=True, text=True,
                             timeout=4).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for m in re.finditer(r"inet (100\.\d+\.\d+\.\d+)", out):
        ip = m.group(1)
        second = int(ip.split(".")[1])
        if 64 <= second <= 127:          # the CGNAT slice Tailscale uses
            return ip
    return None


def resolve_host(requested):
    """Pick the bind address: explicit request → tailnet IP → loopback."""
    if requested and requested not in ("auto", ""):
        return requested
    return tailnet_ip() or "127.0.0.1"


# Session discovery — reuse scan.sh, the menu bar's own source of truth.

_scan_cache = {"at": 0.0, "data": None}
_scan_lock = threading.Lock()


def run_scan(max_age=2.0):
    """The menu bar's scan output, cached briefly so polling clients are cheap.

    A full scan is ~185ms; several phone/desktop clients polling the index a
    few times a second would otherwise stack up. One cache shared under a lock
    collapses that to one scan per `max_age` window.
    """
    now = time.time()
    with _scan_lock:
        if _scan_cache["data"] is not None and now - _scan_cache["at"] < max_age:
            return _scan_cache["data"]
    try:
        out = subprocess.run(["bash", SCAN_SCRIPT], capture_output=True,
                             text=True, timeout=12).stdout
        data = json.loads(out)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        data = {"live": [], "history": [], "limits": {}, "aggregates": {}}
    with _scan_lock:
        _scan_cache["at"] = time.time()
        _scan_cache["data"] = data
    return data


def resolve_session_jsonl(session_id):
    """Absolute path to a session's transcript .jsonl, or None.

    Sessions live at ~/.claude/projects/<project-slug>/<session-id>.jsonl. The
    id alone is unique, so a recursive glob finds it without knowing the slug.
    """
    if not session_id or not re.match(r"^[\w-]+$", session_id):
        return None
    hits = glob.glob(os.path.join(PROJECTS_DIR, "**", f"{session_id}.jsonl"),
                     recursive=True)
    return hits[0] if hits else None


def sessions_payload():
    """Reshape scan output into the index page's feed: live first, then recent.

    Live rows carry the rich at-a-glance fields (ctx, state, last prompt, cost);
    history rows are leaner. Both expose the session_id the index links to.
    """
    scan = run_scan()
    live = []
    for inst in scan.get("live", []):
        sl = inst.get("statusline") or {}
        live.append({
            "session_id": inst.get("session_id", ""),
            "pid": inst.get("pid"),
            "model": inst.get("model", ""),
            "cwd_short": inst.get("cwd_short", ""),
            "cwd": inst.get("cwd", ""),
            "elapsed": inst.get("elapsed", ""),
            "turns": inst.get("turns", 0),
            "tool_calls": inst.get("tool_calls", 0),
            "input_tokens": inst.get("input_tokens", 0),
            "output_tokens": inst.get("output_tokens", 0),
            "cost_usd": inst.get("cost_usd", 0),
            "git_branch": inst.get("git_branch", ""),
            "git_modified": inst.get("git_modified", 0),
            "subagent_count": inst.get("subagent_count", 0),
            "last_prompt": inst.get("last_prompt", ""),
            "tab_title": inst.get("tab_title", ""),
            "state": (inst.get("session_state") or {}).get("state", ""),
            "state_detail": (inst.get("session_state") or {}).get("detail", ""),
            "ctx_remaining": sl.get("ctx_remaining", ""),
            "mcp_down": sl.get("mcp_down", ""),
            "focus_file": sl.get("focus_file", ""),
        })
    recent = []
    for h in scan.get("history", []):
        recent.append({
            "session_id": h.get("session_id", ""),
            "model": h.get("model", ""),
            "cwd_short": h.get("project", ""),
            "turns": h.get("turns", 0),
            "modified": h.get("modified", ""),
            "size_kb": h.get("size_kb", 0),
            "cost_usd": h.get("cost_usd", 0),
        })
    return {
        "ts": scan.get("ts", ""),
        "host": socket.gethostname(),
        "live": live,
        "recent": recent,
        "limits": scan.get("limits", {}),
        "aggregates": scan.get("aggregates", {}),
    }


def _read_file(path):
    with open(path, "rb") as fh:
        return fh.read()


class HubHandler(http.server.BaseHTTPRequestHandler):
    """Routes the hub's three surfaces: the index, a session's SPA, its JSON."""

    server_version = "ClaudeHub/1.0"

    def log_message(self, *a):
        pass  # quiet; the hub is a background service

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, ensure_ascii=False),
                   "application/json; charset=utf-8")

    def _html(self, code, html):
        self._send(code, html, "text/html; charset=utf-8")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        qs = urllib.parse.parse_qs(parsed.query)

        if path in ("/", "/index.html"):
            return self._serve_index()
        if path == "/api/sessions":
            return self._json(200, sessions_payload())
        if path == "/healthz":
            return self._json(200, {"ok": True, "host": socket.gethostname()})
        if path == "/favicon.ico":
            return self._send(204, b"", "image/x-icon")

        m = SID_RE.match(path)
        if m:
            sid, is_data = m.group(1), m.group(2)
            if is_data:
                return self._serve_data(sid, qs)
            return self._serve_app(sid)

        self._send(404, "Not found", "text/plain; charset=utf-8")

    do_HEAD = do_GET

    def _serve_index(self):
        try:
            self._html(200, _read_file(INDEX_HTML))
        except OSError:
            self._html(500, "<h1>hub-index.html missing</h1>")

    def _serve_app(self, sid):
        if not resolve_session_jsonl(sid):
            return self._html(404, f"<h1>No session {sid}</h1>")
        try:
            self._html(200, _read_file(APP_HTML))
        except OSError:
            self._html(500, "<h1>transcript-app.html missing</h1>")

    def _serve_data(self, sid, qs):
        if transcript is None:
            return self._json(500, {"error": "transcript module unavailable"})
        jsonl = resolve_session_jsonl(sid)
        if not jsonl:
            return self._json(404, {"error": f"no transcript for {sid}"})

        agent = (qs.get("agent") or [None])[0]
        target = jsonl
        if agent:
            target = transcript._resolve_agent_file(jsonl, agent)
            if not target:
                return self._json(404, {"error": f"no sub-agent {agent}"})
        try:
            result = transcript.parse_transcript(target)
        except Exception as e:
            return self._json(500, {"error": f"parse failed: {e}"})

        since = (qs.get("since") or [None])[0]
        if since is not None:
            try:
                s = int(since)
                result["records"] = [r for r in result["records"] if r["seq"] > s]
                result["meta"]["since"] = s
            except ValueError:
                pass
        self._json(200, result)


def main(argv):
    host_req = _env("CLAUDE_HUB_HOST", "auto")
    port = int(_env("CLAUDE_HUB_PORT", "5400"))
    print_host = False
    i = 0
    while i < len(argv):
        if argv[i] == "--host":
            host_req = argv[i + 1]; i += 2; continue
        if argv[i] == "--port":
            port = int(argv[i + 1]); i += 2; continue
        if argv[i] == "--print-host":
            print_host = True; i += 1; continue
        i += 1

    host = resolve_host(host_req)

    # hub.sh asks for the resolved bind address (so it shows the same URL the
    # server will actually use) without starting the server.
    if print_host:
        print(host)
        return 0

    def _bye(*_):
        os._exit(0)
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        try: signal.signal(s, _bye)
        except (OSError, ValueError): pass

    socketserver.TCPServer.allow_reuse_address = True
    httpd = http.server.ThreadingHTTPServer((host, port), HubHandler)
    tn = tailnet_ip()
    scope = "tailnet (reachable from your other devices)" if host == tn \
        else "localhost only (Tailscale down — start it for phone access)"
    sys.stderr.write(f"claude hub: http://{host}:{port}/  — {scope}\n")
    if tn and host == tn:
        sys.stderr.write(f"  on your phone: http://{tn}:{port}/\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
