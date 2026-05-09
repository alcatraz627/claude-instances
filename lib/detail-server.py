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
import http.server
import socketserver
import urllib.parse
import subprocess
import threading
import time

if len(sys.argv) < 4:
    sys.stderr.write("Usage: detail-server.py <port> <script_path> <pid> [<sid>]\n")
    sys.exit(2)

PORT    = int(sys.argv[1])
SCRIPT  = sys.argv[2]
PID     = sys.argv[3]
SID     = sys.argv[4] if len(sys.argv) > 4 else ""
SERVE_DIR = "/tmp"

DEADLINE = time.time() + 2 * 60 * 60  # 2-hour hard stop


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
        parsed = urllib.parse.urlparse(self.path)

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


def claude_alive():
    try:
        os.kill(int(PID), 0)
        return True
    except (OSError, ValueError):
        return False


def lifetime_watcher():
    """Exit when Claude PID dies or 2h passes."""
    while True:
        time.sleep(60)
        if not claude_alive():
            os._exit(0)
        if time.time() > DEADLINE:
            os._exit(0)


def scheduled_regen():
    """Background disk regen every 5 minutes. Keeps the file fresh even
    if the user has no transcript page open (matches the previous bash
    daemon's contract — disk-side stays current at a low-overhead
    cadence for any client that just reads the file)."""
    while True:
        time.sleep(300)
        if not claude_alive() or time.time() > DEADLINE:
            os._exit(0)
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
