#!/usr/bin/env bash
# hub.sh — start/stop the session hub that makes your Claude transcripts
# readable from your phone (and any other device on your Tailscale network).
#
#   bash lib/hub.sh start     launch it, print the URL to open on your phone
#   bash lib/hub.sh stop      shut it down
#   bash lib/hub.sh restart   stop + start (run after Tailscale (re)connects)
#   bash lib/hub.sh status    is it running? where is it bound?
#   bash lib/hub.sh url        just print the phone URL
#
# It binds to this Mac's Tailscale address when Tailscale is up, so it is NOT
# reachable from a public/coffee-shop network. With Tailscale down it falls
# back to localhost and is only reachable from this machine.

set -euo pipefail

PORT="${CLAUDE_HUB_PORT:-5400}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$SCRIPT_DIR/hub-server.py"
PID_FILE="/tmp/claude-hub.pid"
LOG="/tmp/claude-hub.log"

c_dim=$'\033[2m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_cyn=$'\033[36m'; c_rst=$'\033[0m'

resolved_host() { python3 "$SERVER" --print-host --port "$PORT" 2>/dev/null || echo "127.0.0.1"; }

is_running() {
    [[ -f "$PID_FILE" ]] || return 1
    local pid; pid="$(cat "$PID_FILE" 2>/dev/null || echo)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

print_url() {
    local host; host="$(resolved_host)"
    if [[ "$host" == "127.0.0.1" ]]; then
        echo "${c_yel}Tailscale is down — hub is localhost-only.${c_rst}"
        echo "  this Mac:   ${c_cyn}http://127.0.0.1:${PORT}/${c_rst}"
        echo "  ${c_dim}Start Tailscale, then: bash lib/hub.sh restart  → phone URL appears.${c_rst}"
    else
        echo "  on your phone: ${c_grn}http://${host}:${PORT}/${c_rst}  ${c_dim}(same on any tailnet device)${c_rst}"
        echo "  this Mac:      ${c_cyn}http://127.0.0.1:${PORT}/${c_rst}"
    fi
}

cmd_start() {
    if is_running; then
        echo "${c_grn}hub already running${c_rst} (pid $(cat "$PID_FILE"))"
        print_url; return 0
    fi
    nohup python3 "$SERVER" --port "$PORT" >"$LOG" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    disown 2>/dev/null || true
    # Wait until OUR pid is the one listening. `nc -z` only proves somebody is:
    # when a stale hub already held the port, this one died on "address in use"
    # while nc succeeded instantly against the old one, and the start was
    # reported as a success that had actually served stale code for hours.
    local ok=""
    for _ in $(seq 1 40); do
        kill -0 "$pid" 2>/dev/null || break                     # it died; stop waiting
        if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -qx "$pid"; then
            ok=1; break
        fi
        sleep 0.1
    done
    if [[ -z "$ok" ]]; then
        local holder
        holder=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)
        echo "${c_yel}hub failed to start — see $LOG${c_rst}" >&2
        if [[ -n "$holder" && "$holder" != "$pid" ]]; then
            echo "  port $PORT is already held by pid $holder — stop it first" >&2
        fi
        tail -3 "$LOG" 2>/dev/null >&2 || true
        return 1
    fi
    echo "${c_grn}hub started${c_rst} (pid $pid)"
    print_url
}

cmd_stop() {
    if ! is_running; then echo "hub not running"; rm -f "$PID_FILE"; return 0; fi
    local pid; pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    echo "hub stopped"
}

cmd_status() {
    if is_running; then
        local host; host="$(resolved_host)"
        echo "${c_grn}● running${c_rst} (pid $(cat "$PID_FILE")) bound to ${host}:${PORT}"
        print_url
    else
        echo "${c_dim}○ not running${c_rst}"
    fi
}

case "${1:-status}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status)  cmd_status ;;
    url)     print_url ;;
    *) echo "usage: hub.sh {start|stop|restart|status|url}" >&2; exit 2 ;;
esac
