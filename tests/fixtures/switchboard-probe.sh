#!/bin/bash
# Compiles and runs the Switchboard state probe against the shipping sources.
# Mutations run in a temp fixture tree; the only real-config touch is read-only.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
OUT="$WORK/sb-probe"

# swiftc allows top-level statements only in a file literally named main.swift.
cp -f "$ROOT/tests/fixtures/switchboard-probe.swift" "$WORK/main.swift"

swiftc -o "$OUT" \
    "$WORK/main.swift" \
    "$ROOT/native/Switchboard.swift" \
    "$ROOT/native/DesignKit.swift" \
    "$ROOT/native/Palette.swift" \
    "$ROOT/native/Models.swift" 2>&1 | grep -E "error:" && { echo "COMPILE FAILED"; exit 1; }

"$OUT"
