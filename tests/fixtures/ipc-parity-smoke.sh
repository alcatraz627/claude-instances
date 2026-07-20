#!/bin/bash
# Count parity: shape is not truth — a digest can be valid JSON carrying wrong
# numbers, so its unread figure is cross-checked against the broker's own
# single-alias verb (meld plan section 11.7). The digest verb has not shipped
# on the peer's side yet; until it answers, this prints SKIPPED and exits 0 —
# loudly, so a green run never reads as "parity proven".
set -uo pipefail
BIN="${HUB_IPC_BIN:-$HOME/Code/Claude/claude-ipc/dist/claude-ipc}"
[ -x "$BIN" ] || { echo "SKIPPED: no claude-ipc binary at $BIN"; exit 0; }

out=$("$BIN" digest --project "$PWD" --json 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
    echo "SKIPPED: digest verb absent (exit $rc) — parity unproven until the peer ships it"
    exit 0
fi

printf '%s' "$out" | python3 - "$BIN" <<'PY'
import json, subprocess, sys
bin_ = sys.argv[1]
try:
    d = json.load(sys.stdin)
except ValueError as e:
    print(f"digest emitted non-JSON: {e}")
    sys.exit(1)
sessions = {k: v for k, v in (d.get("sessions") or {}).items()
            if k != "_unresolved" and isinstance(v, dict)
            and v.get("aliases") and isinstance(v.get("unread"), int)}
if not sessions:
    print("SKIPPED: digest answered but no resolvable session to cross-check")
    sys.exit(0)
sid, sess = next(iter(sorted(sessions.items())))
alias = sess["aliases"][0]
r = subprocess.run([bin_, "count", alias], capture_output=True, text=True, timeout=5)
digits = "".join(c for c in (r.stdout or "") if c.isdigit())
single = int(digits) if digits else 0
if sess["unread"] != single:
    print(f"PARITY MISMATCH: digest unread={sess['unread']} vs count={single} for {alias}")
    sys.exit(1)
print(f"PARITY OK: {alias} unread={single} agrees across both verbs")
PY
