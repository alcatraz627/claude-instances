#!/usr/bin/env python3
# detail-server.py — HTTP server backing the live transcript page.
#
# Spawned per-claude-PID by detail.sh. Replaces the previous bash-loop
# regen daemon: serves /tmp/ as a localhost site (so the page can fetch()
# itself — Chrome blocks fetch between two file:// URLs) and exposes a
# /regen endpoint the JS poller calls when it wants fresh content
# between scheduled disk regens.
#
# Usage:
#   python3 detail-server.py <port> <SCRIPT_PATH> <PID> [<SESSION_ID>]
#
# Lifetime:
#   - exits when the Claude PID dies (checked every 60s)
#   - 2-hour hard deadline
#   - exits silently if the port is already bound (another server is
#     handling this PID — detail.sh's preflight detects this and
#     reuses the existing instance)

import sys
import os
import glob
import json
import http.server
import socketserver
import urllib.parse
import subprocess
import threading
import time
import signal

# The data model lives next to this server. Import it in-process so /data can
# parse the transcript directly (~64ms for a 10MB file) without shelling out.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import transcript
except Exception:
    transcript = None

if len(sys.argv) < 4:
    sys.stderr.write("Usage: detail-server.py <port> <script_path> <pid> [<sid>]\n")
    sys.exit(2)

PORT    = int(sys.argv[1])
SCRIPT  = sys.argv[2]
PID     = sys.argv[3]
SID     = sys.argv[4] if len(sys.argv) > 4 else ""
SERVE_DIR = "/tmp"
PID_FILE  = f"/tmp/claude-widget-{PID}.server"
PROJECTS_DIR = os.path.expanduser("~/.claude/projects")


def resolve_jsonl():
    """Locate this session's transcript .jsonl on disk.

    Mirrors detail.sh's resolution: prefer the session id, fall back to the
    most-recently-touched transcript in the project the Claude PID is running
    in. Returns an absolute path or None.
    """
    if SID:
        hits = glob.glob(os.path.join(PROJECTS_DIR, "**", f"{SID}.jsonl"),
                         recursive=True)
        if hits:
            return hits[0]
    if PID and PID.isdigit():
        try:
            out = subprocess.run(["lsof", "-p", PID, "-d", "cwd", "-Fn"],
                                 capture_output=True, text=True, timeout=5).stdout
            cwd = next((l[1:] for l in out.splitlines() if l.startswith("n/")), "")
        except (OSError, subprocess.SubprocessError):
            cwd = ""
        if cwd:
            slug = cwd.replace("/", "-").lstrip("-")
            proj = os.path.join(PROJECTS_DIR, f"-{slug}")
            files = sorted(glob.glob(os.path.join(proj, "*.jsonl")),
                           key=os.path.getmtime, reverse=True)
            if files:
                return files[0]
    return None

# ── Lifetime caps ──────────────────────────────────────────────────────────
# DEADLINE  — 2-hour hard stop regardless of activity (was the only cap).
# IDLE_SECS — exit if no HTTP request arrives for this long. Catches the
#             "user closed the browser tab but Claude PID is still alive"
#             case, which previously kept the server polling forever.
DEADLINE  = time.time() + 2 * 60 * 60
IDLE_SECS = 10 * 60                       # 10 minutes of no traffic
last_request_at = time.time()             # bumped on every request

# ── Cleanup on any exit path ───────────────────────────────────────────────
def _remove_pidfile():
    try:
        if os.path.isfile(PID_FILE):
            with open(PID_FILE) as f:
                content = f.read().strip()
            # Only remove if file content is still our PID — avoids racing
            # with a fresh server that may have just spawned for this PID.
            if content == str(os.getpid()):
                os.unlink(PID_FILE)
    except OSError:
        pass

def _exit(code=0):
    _remove_pidfile()
    os._exit(code)

# Handle Ctrl-C and SIGTERM (e.g. when bar.app sends one on shutdown) so we
# don't leave a stale .server file that confuses the next detail.sh run.
def _on_signal(signum, frame):
    _exit(0)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    try: signal.signal(sig, _on_signal)
    except (OSError, ValueError): pass

# Write our own PID once we've started (overrides whatever bash put there).
try:
    with open(PID_FILE, 'w') as f:
        f.write(str(os.getpid()))
except OSError:
    pass


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=SERVE_DIR, **k)

    def log_message(self, *a, **k):
        pass  # silence the default per-request access log

    def end_headers(self):
        # Cache-busting on every response: JS poller sees fresh bytes
        # without per-request `?_=Date.now()` hacks.
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Pragma", "no-cache")
        super().end_headers()

    def do_GET(self):
        global last_request_at
        last_request_at = time.time()
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/data":
            # Normalized transcript model as JSON. Query params:
            #   since=<seq>   only blocks after this seq (incremental live tail)
            #   agent=<id>    a sub-agent's own transcript instead of the parent
            self._serve_data(urllib.parse.parse_qs(parsed.query))
            return

        if parsed.path == "/regen":
            # Synchronous regen so JS can fetch the HTML right after the
            # /regen call returns 200 and know it's reading fresh content.
            try:
                args = ["bash", SCRIPT, "--regen", PID]
                if SID: args.append(SID)
                subprocess.run(args,
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL,
                               timeout=15, check=False)
                body = b"OK"
                code = 200
            except (subprocess.TimeoutExpired, OSError):
                body = b"regen timeout"
                code = 504
            self.send_response(code)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)
            return

        # Static file serving for /claude-widget-<pid>.html and friends.
        super().do_GET()

    def _serve_data(self, qs):
        """Parse the transcript and return the normalized model as JSON."""
        def fail(code, msg):
            body = json.dumps({"error": msg}).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.end_headers()
            self.wfile.write(body)

        if transcript is None:
            return fail(500, "transcript module unavailable")
        jsonl = resolve_jsonl()
        if not jsonl or not os.path.exists(jsonl):
            return fail(404, "transcript not found")

        agent = (qs.get("agent") or [None])[0]
        target = jsonl
        if agent:
            target = transcript._resolve_agent_file(jsonl, agent)
            if not target:
                return fail(404, f"no sub-agent transcript for id {agent}")
        try:
            result = transcript.parse_transcript(target)
        except Exception as e:
            return fail(500, f"parse failed: {e}")

        since = (qs.get("since") or [None])[0]
        if since is not None:
            try:
                s = int(since)
                result["records"] = [r for r in result["records"] if r["seq"] > s]
                result["meta"]["since"] = s
            except ValueError:
                pass

        body = json.dumps(result, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)


def claude_alive():
    try:
        os.kill(int(PID), 0)
        return True
    except (OSError, ValueError):
        return False


def lifetime_watcher():
    """Exit when any of the shutdown conditions are met:
       - Claude PID dies
       - 2-hour hard deadline passes
       - No HTTP request received in IDLE_SECS (browser tab closed)
    """
    while True:
        time.sleep(30)
        if not claude_alive():
            _exit(0)
        if time.time() > DEADLINE:
            _exit(0)
        if time.time() - last_request_at > IDLE_SECS:
            _exit(0)


def scheduled_regen():
    """Background disk regen every 5 minutes. Keeps the file fresh even
    if the user has no transcript page open (matches the previous bash
    daemon's contract — disk-side stays current at a low-overhead
    cadence for any client that just reads the file).

    Skipped when idle: if no requests in IDLE_SECS, the lifetime_watcher
    is about to kill us anyway, so don't waste a regen cycle."""
    while True:
        time.sleep(300)
        if not claude_alive() or time.time() > DEADLINE:
            _exit(0)
        if time.time() - last_request_at > IDLE_SECS:
            continue  # let watcher exit cleanly
        try:
            args = ["bash", SCRIPT, "--regen", PID]
            if SID: args.append(SID)
            subprocess.run(args,
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,
                           timeout=15, check=False)
        except Exception:
            pass


threading.Thread(target=lifetime_watcher, daemon=True).start()
threading.Thread(target=scheduled_regen, daemon=True).start()

socketserver.TCPServer.allow_reuse_address = True
try:
    with socketserver.TCPServer(("127.0.0.1", PORT), Handler) as httpd:
        httpd.serve_forever()
except OSError:
    # Port collision — another server already serving this PID.
    # detail.sh's preflight should have detected it; if it didn't, just
    # exit and let the existing one handle the page.
    sys.exit(0)
except KeyboardInterrupt:
    sys.exit(0)
