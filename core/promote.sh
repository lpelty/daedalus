#!/usr/bin/env bash
# core/promote.sh — the one way a window's work reaches trunk (spec §7); the
# contract is in core/promote.py. bash 3.2.
#
# The integrity check runs FIRST (spec §6.1), in both phases: before lib.sh is
# sourced and before promote.py imports anything, so no modified distribution
# code runs after this point — this file itself is outside it (bash has read
# it; plan 4 Decision 41) — core/distcheck.py under an isolated python (-I: no
# PYTHON* variables, no script directory or user site on sys.path; -B: no
# bytecode).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'daedalus: python3 not found on PATH — promote did nothing. Nothing was pushed.\n' >&2; exit 2; }
# distcheck.py is distribution code too: git alone checks it first, under a cleared
# environment (plan 4 Decision 41) — the same lines as core/call-agent.sh.
dc_git() { env -i PATH="$PATH" HOME="${HOME:-}" GIT_NO_REPLACE_OBJECTS=1 git -C "$here/.." "$@" 2>/dev/null; }
dc_head="$(dc_git rev-parse -q --verify HEAD:./core/distcheck.py)"
if [ -z "$dc_head" ]; then
  printf 'daedalus: Cannot tell whether distribution code is modified: core/distcheck.py is not in a committed tree here (is this home a git checkout?). Nothing was pushed.\n' >&2; exit 2
fi
if [ "$(dc_git hash-object --no-filters core/distcheck.py)" != "$dc_head" ]; then
  printf 'daedalus: Distribution code is modified (core/distcheck.py); restore it before a review or a promote runs. Nothing was pushed.\n' >&2; exit 2
fi
python3 -I -B "$here/distcheck.py" "$here/.." --for promote || exit 2
source "$here/lib.sh"
set +e
exec python3 "$here/promote.py" "$@"
