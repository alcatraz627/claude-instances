#!/bin/bash
# Contract diff: a live digest response must be a superset of the vendored
# fixture's fields (meld plan section 11.8) — the pre-merge tripwire for the
# two repos deploying independently. Runs only where the peer's verb answers;
# otherwise SKIPPED, loudly, exit 0.
set -uo pipefail
BIN="${HUB_IPC_BIN:-$HOME/Code/Claude/claude-ipc/dist/claude-ipc}"
FIXTURE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ipc-digest-fixture.json"
[ -x "$BIN" ] || { echo "SKIPPED: no claude-ipc binary at $BIN"; exit 0; }

out=$("$BIN" digest --project "$PWD" --json 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
    echo "SKIPPED: digest verb absent (exit $rc) — contract diff waits for the peer"
    exit 0
fi

printf '%s' "$out" | python3 - "$FIXTURE" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    fx = json.load(fh)
try:
    live = json.load(sys.stdin)
except ValueError as e:
    print(f"digest emitted non-JSON: {e}")
    sys.exit(1)

missing = [k for k in fx if not k.startswith("_") and k not in live]
if "_unresolved" not in (live.get("sessions") or {}):
    missing.append("sessions._unresolved")

fx_sess = next(v for k, v in fx["sessions"].items() if k != "_unresolved")
live_sess = [v for k, v in (live.get("sessions") or {}).items()
             if k != "_unresolved" and isinstance(v, dict)]
if live_sess:
    have = set().union(*(set(s) for s in live_sess))
    missing += [f"sessions.<sid>.{k}" for k in fx_sess if k not in have]
    note = f"checked {len(live_sess)} live session block(s)"
else:
    note = "no live session blocks — top-level keys only"

if missing:
    print("CONTRACT DRIFT — live digest missing fixture fields: " + ", ".join(missing))
    sys.exit(1)
print(f"CONTRACT OK: live ⊇ fixture ({note})")
PY
