#!/bin/bash
# Atone plugin — action dispatcher.
# Phase 5 ships no commands wired through the UI yet; this script is a
# placeholder for when commands land. Each command id is the first argv;
# remaining argv are command arguments.

set -euo pipefail

cmd="${1:-}"

case "${cmd}" in
  "")
    echo "no command id given" >&2
    exit 2
    ;;
  *)
    echo "atone actions.sh: command not implemented: ${cmd}" >&2
    exit 1
    ;;
esac
