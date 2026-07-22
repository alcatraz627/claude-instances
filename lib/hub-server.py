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
import collections
import time
import signal
import socket
import threading
import subprocess
import http.server
import socketserver
import urllib.parse
import zlib

# transcript.py lives next to this file — import it so /data can parse a session
# directly instead of shelling out per request.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
transcript_import_error = None
try:
    import transcript
except Exception as _e:            # a broken transcript.py must not stop the index
    transcript = None
    transcript_import_error = f"{type(_e).__name__}: {_e}"

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


_scan_refreshing = {"on": False}


def _do_scan():
    """One real scan.sh run, validated. Raises on anything unhealthy — a scan
    that died after printing still prints, and a crash that flushed valid JSON
    on its way out must stay distinguishable from a healthy scan."""
    proc = subprocess.run(["bash", SCAN_SCRIPT], capture_output=True,
                          text=True, timeout=20)
    if proc.returncode != 0:
        raise RuntimeError(f"scan.sh exited {proc.returncode}: "
                           f"{proc.stderr.strip()[:200]}")
    return json.loads(proc.stdout)


def _refresh_scan_async():
    """One background scan; on success it replaces the cache, on failure the
    stale result simply stays (a failed scan is not a machine with nothing
    running). Callers set the single-flight flag before spawning."""
    def worker():
        data = None
        try:
            try:
                data = _do_scan()
            except (OSError, subprocess.SubprocessError, ValueError,
                    RuntimeError) as e:
                # ValueError covers json.JSONDecodeError AND the
                # UnicodeDecodeError a text=True subprocess raises when the
                # scan emits invalid UTF-8 — the gate proved that class real.
                sys.stderr.write(f"hub: background scan failed ({type(e).__name__}); "
                                 f"keeping the last good result\n")
        finally:
            # The flag MUST clear on every exit, including exception classes
            # nobody predicted — a stuck flag would silently disable refresh
            # and serve stale forever.
            with _scan_lock:
                if data is not None:
                    _scan_cache["at"] = time.time()
                    _scan_cache["data"] = data
                _scan_refreshing["on"] = False
    threading.Thread(target=worker, daemon=True).start()


def run_scan(max_age=2.0):
    """The menu bar's scan output, served stale-while-revalidate so navigation
    is never punished by the scan's own latency.

    Fresh enough → serve it. Stale → serve the stale copy IMMEDIATELY and kick
    exactly one background refresh (single-flight flag; a burst of stale hits
    must not stampede N scans). Only a true-cold server — nothing cached at
    all, the first request of the process's life — blocks on the scan, and a
    cold-start failure returns the honest scan_error shape rather than caching
    an empty machine as fact.
    """
    with _scan_lock:
        if (_scan_cache["data"] is not None
                and time.time() - _scan_cache["at"] < max_age):
            return _scan_cache["data"]
        if _scan_cache["data"] is not None:
            if not _scan_refreshing["on"]:
                _scan_refreshing["on"] = True
                _refresh_scan_async()
            return _scan_cache["data"]
        try:
            data = _do_scan()
        except (OSError, subprocess.SubprocessError, ValueError,
                RuntimeError) as e:
            sys.stderr.write(f"hub: scan failed ({type(e).__name__}); "
                             f"nothing cached yet\n")
            return {"live": [], "history": [], "limits": {}, "aggregates": {},
                    "scan_error": type(e).__name__}
        _scan_cache["at"] = time.time()
        _scan_cache["data"] = data
        return data


_jsonl_paths = {}   # session id -> resolved transcript path


def resolve_session_jsonl(session_id):
    """Absolute path to a session's transcript .jsonl, or None.

    Sessions live at ~/.claude/projects/<project-slug>/<session-id>.jsonl. The
    id alone is unique, so a recursive glob finds it without knowing the slug.

    If that uniqueness ever breaks, take the freshest rather than whatever the
    filesystem happened to list first — glob order is not defined, so the old
    hits[0] could serve a different session's transcript on one request and its
    twin on the next, with nothing to show anything was wrong.
    """
    if not session_id or not re.match(r"^[\w-]+$", session_id):
        return None
    # A transcript never moves once written, so the recursive walk over the
    # whole projects tree is paid once per session, not once per request —
    # the index fires ~40 peek requests per navigation, and each was a full
    # tree glob. A vanished file falls through to a fresh walk.
    hit = _jsonl_paths.get(session_id)
    if hit and os.path.exists(hit):
        return hit
    hits = glob.glob(os.path.join(PROJECTS_DIR, "**", f"{session_id}.jsonl"),
                     recursive=True)
    # `**` follows symlinked directories, so a single planted link under
    # projects/ would make this server — reachable from every device on the
    # tailnet — serve any .jsonl on the disk. Resolve and re-check the root.
    root = os.path.realpath(PROJECTS_DIR)
    hits = [h for h in hits
            if os.path.realpath(h).startswith(root + os.sep)]
    if not hits:
        return None
    if len(hits) > 1:
        sys.stderr.write(f"hub: {len(hits)} transcripts share id {session_id}; "
                         f"serving the most recently written\n")
        hits.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    _jsonl_paths[session_id] = hits[0]
    return hits[0]


# Parse results for the live tail, keyed by the bytes' identity. /data is
# polled every few seconds per open page, AND the index fires a peek probe
# per card on every navigation — ~40 requests across ~20 transcripts. The
# cache is LRU-bounded at roughly twice a busy fleet, so an ended
# transcript (whose key never changes again) parses once per server
# lifetime instead of once per visit; least-recently-watched entries age
# out. Per-target locks make concurrent peeks of one cold session share a
# single parse. Callers slice on copies, never on the cached object.
_PARSE_CACHE = collections.OrderedDict()   # target -> (key, result, src_bytes)
_PARSE_CACHE_MAX = 48
# Entries are whole parsed transcripts in RAM, so the entry cap alone is not a
# memory cap — a fleet of huge files needs a byte bound too. Measured by the
# SOURCE file size (the parsed form is larger but proportional).
_PARSE_CACHE_BYTES_MAX = 256 * 1024 * 1024
_parse_meta = threading.Lock()   # guards _PARSE_CACHE + _parse_locks
_parse_locks = {}


def _parse_cache_evict():
    """Drop least-recently-used entries until both bounds hold. Caller holds
    _parse_meta. The newest entry always survives, however large — evicting
    the thing just parsed would only re-parse it on the next poll."""
    while len(_PARSE_CACHE) > 1:
        total = sum(e[2] for e in _PARSE_CACHE.values())
        if len(_PARSE_CACHE) <= _PARSE_CACHE_MAX and total <= _PARSE_CACHE_BYTES_MAX:
            break
        gone, _ = _PARSE_CACHE.popitem(last=False)
        # A lock still HELD belongs to a parse in flight; dropping it would
        # let a second reader mint a fresh lock and parse the same file
        # concurrently. Held locks stay; the entry's next eviction cleans up.
        lk = _parse_locks.get(gone)
        if lk is None or not lk.locked():
            _parse_locks.pop(gone, None)

def _parse_cached(target):
    try:
        st = os.stat(target)
    except OSError:
        return transcript.parse_transcript(target)
    key = (st.st_mtime_ns, st.st_size)
    with _parse_meta:
        hit = _PARSE_CACHE.get(target)
        if hit and hit[0] == key:
            _PARSE_CACHE.move_to_end(target)
            return hit[1]
        lock = _parse_locks.setdefault(target, threading.Lock())
    with lock:
        # A racer may have finished this exact parse while we waited.
        with _parse_meta:
            hit = _PARSE_CACHE.get(target)
            if hit and hit[0] == key:
                _PARSE_CACHE.move_to_end(target)
                return hit[1]
        result = transcript.parse_transcript(target)
        with _parse_meta:
            _PARSE_CACHE[target] = (key, result, st.st_size)
            _PARSE_CACHE.move_to_end(target)
            _parse_cache_evict()
        return result


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
            # Only claude transcripts are readable here — see _serve_app.
            "provider": inst.get("provider", "claude"),
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
            "ipc": inst.get("ipc"),
            "ctx_remaining": sl.get("ctx_remaining", ""),
            "mcp_down": sl.get("mcp_down", ""),
            "focus_file": sl.get("focus_file", ""),
        })
    recent = []
    for h in scan.get("history", []):
        recent.append({
            "session_id": h.get("session_id", ""),
            "provider": h.get("provider", "claude"),
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

    def _send(self, code, body, ctype, cache="no-store", etag=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        if etag:
            self.send_header("ETag", etag)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, obj, cache="no-store", etag=None):
        self._send(code, json.dumps(obj, ensure_ascii=False),
                   "application/json; charset=utf-8", cache=cache, etag=etag)

    def _html(self, code, html):
        self._send(code, html, "text/html; charset=utf-8")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        # keep_blank_values: without it `?since=` is dropped from the dict
        # entirely and reads as "no cursor given", so a client that sent an
        # empty cursor silently got the whole transcript instead of a 400.
        qs = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

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
        # (parse itself goes through _parse_cached — /data is the 5s live
        # tail, and every poll used to re-parse the whole file.)
        jsonl = resolve_session_jsonl(sid)
        if not jsonl:
            return self._json(404, {"error": f"no transcript for {sid}"})

        agent = (qs.get("agent") or [None])[0]
        target = jsonl
        if agent:
            target = transcript._resolve_agent_file(jsonl, agent)
            if not target:
                return self._json(404, {"error": f"no sub-agent {agent}"})
        # Conditional GET: the response is a pure function of (file bytes,
        # query), so the bytes' identity is an honest ETag and an unchanged
        # transcript answers 304 with no parse and no body. Ended sessions —
        # most of the index's peek traffic — never change again, making their
        # repeat peeks free. A stat race with the parse below can at worst
        # tag a response with a just-superseded etag; the next poll re-fetches.
        etag = None
        try:
            st = os.stat(target)
            # The query shapes the body (since/after_id/agent slicing), so it
            # belongs in the validator: an ETag naming only the file would let
            # any client that carries it across query strings receive a false
            # 304. Browsers key per-URL and never hit this; intermediaries and
            # hand-rolled clients can.
            qcrc = zlib.crc32(self.path.encode("utf-8", "surrogatepass"))
            etag = f'"{st.st_mtime_ns}-{st.st_size}-{qcrc:08x}"'
        except OSError:
            pass
        if etag and self.headers.get("If-None-Match") == etag:
            return self._send(304, b"", "application/json; charset=utf-8",
                              cache="no-cache", etag=etag)
        try:
            parsed = _parse_cached(target)
        except Exception as e:
            # The detail goes to the log, not the response — a parser exception
            # carries absolute paths and stack fragments.
            sys.stderr.write(f"hub: parse failed for {sid}: {type(e).__name__}: {e}\n")
            return self._json(500, {"error": "transcript could not be parsed"})
        # Slice on shallow copies only: the cached parse must never be mutated.
        result = {"meta": dict(parsed["meta"]), "records": parsed["records"]}

        since = (qs.get("since") or [None])[0]
        after_id = (qs.get("after_id") or [None])[0]
        if since is not None and after_id is not None:
            return self._json(400, {"error": "since and after_id are mutually exclusive"})
        if after_id is not None:
            if not after_id:
                return self._json(400, {"error": "after_id must be a record id"})
            recs = result["records"]
            idx = next((i for i, r in enumerate(recs) if r.get("id") == after_id), None)
            if idx is None:
                # The cursor names a record that no longer exists (a rewritten
                # transcript). Send everything, flagged, so the client
                # reconciles by id instead of trusting a broken cursor.
                result["meta"]["cursor_reset"] = True
            else:
                result["records"] = ([r for r in recs[:idx + 1] if r.get("open")]
                                     + recs[idx + 1:])
            result["meta"]["after_id"] = after_id
        if since is not None:
            try:
                s = int(since)
            except ValueError:
                return self._json(400, {"error": f"since must be an integer, got {since!r}"})
            # A tools group flushed at EOF keeps its seq while still gaining
            # tools, so `seq > s` alone would hide everything appended to a
            # group the client has already seen. Resend it and let the client
            # swap it in place.
            result["records"] = [r for r in result["records"]
                                 if r["seq"] > s or r.get("open")]
            result["meta"]["since"] = s
        self._json(200, result, cache="no-cache", etag=etag)


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
    if transcript is None:
        # Say it now. Otherwise the first person to open a session finds out,
        # via a 500, that transcripts have been dark since startup.
        sys.stderr.write(f"  WARNING: transcript.py failed to import — sessions "
                         f"will not open. {transcript_import_error}\n")
    if tn and host == tn:
        sys.stderr.write(f"  on your phone: http://{tn}:{port}/\n")

    # Also serve loopback so local links (the menu bar's http://127.0.0.1 URL, a
    # browser on this Mac) work even when the primary bind is the tailnet IP. A
    # second socket on a distinct address keeps the tailnet scoping intact —
    # unlike 0.0.0.0, it does NOT expose the hub to the LAN / public wifi.
    if host not in ("127.0.0.1", "0.0.0.0", "localhost"):
        import threading
        try:
            loop_httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), HubHandler)
            threading.Thread(target=loop_httpd.serve_forever, daemon=True).start()
            sys.stderr.write(f"  on this Mac:   http://127.0.0.1:{port}/\n")
        except OSError as e:
            sys.stderr.write(f"  (loopback co-bind failed: {e})\n")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
