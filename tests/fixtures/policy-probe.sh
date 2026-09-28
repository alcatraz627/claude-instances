#!/bin/bash
# Compiles and runs the agent-policy store probe against the shipping sources.
# Every write lands in a throwaway HOME; the real ~/.claude/policy is only read
# for its registry.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
OUT="$WORK/policy-probe"

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude/policy"
cp -f "$HOME/.claude/policy/registry.json" "$FAKE_HOME/.claude/policy/registry.json"
git init -q -b main "$WORK/repo"
git -C "$WORK/repo" commit -q --allow-empty -m x

cp -f "$ROOT/tests/fixtures/policy-probe.swift" "$WORK/main.swift"
if ! swiftc -o "$OUT" "$WORK/main.swift" "$ROOT/native/Policy.swift" > "$WORK/compile.log" 2>&1; then
  grep -E "error:" "$WORK/compile.log"
  echo "COMPILE FAILED"
  exit 1
fi

# CLAUDECODE is set on purpose: the panel must strip it before calling pol.sh.
env CLAUDECODE=1 PROBE_HOME="$FAKE_HOME" PROBE_REPO="$WORK/repo" "$OUT"
