#!/usr/bin/env bash
# The direct-call launcher's entry point (spec §8): one core, three callees —
# the target's own agent (--callee agent, named ONLY by config.yaml
# direct_call.callee_home / callee_name), this Daedalus called by an allowlisted
# agent (--callee self), and the fresh-context refuter Thing (--callee refuter,
# used by core/refute.sh). Answer on stdout, a two-line receipt on stderr,
# resume by call id; exit 0 / 2 refused / 3 answered, orientation unverified /
# 124 timed out, else claude's own exit (1 for a child's 3 with no answer).
# Callers check the exit code AND a non-empty stdout, never the receipt line
# alone. See core/call_agent.py for the contract.
#
# bash 3.2: after the integrity check (below), this file only sources lib.sh (which exports DAEDALUS_HOME and
# DAEDALUS_CONFIG — call_agent.py refuses either unless it is this deployment's)
# and execs the Python — exec, so a SIGTERM to the caller's
# process group reaches the launcher, whose handler kills claude's group.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { printf 'daedalus: python3 not found on PATH — cannot launch the call\n' >&2; exit 2; }
# The integrity check FIRST (spec §6.1): before lib.sh is sourced and before
# call_agent.py imports anything, so modified distribution code never runs.
# Isolated python (-I: no PYTHON* variables, no script directory or user site
# on sys.path; -B: no bytecode written). call_agent.py repeats the check at the
# points the spec names (before the launch, after the review).
# distcheck.py is distribution code too, so git alone checks it first, under a
# cleared environment so no GIT_* variable can point it elsewhere, with
# replacement objects off and no clean filter applied, so the blob compared is
# the file's raw bytes against this checkout's committed tree — as distcheck.py
# itself compares (plan 4 Decision 41). `./` makes the path relative to the
# home, not the repo root.
dc_git() { env -i PATH="$PATH" HOME="${HOME:-}" GIT_NO_REPLACE_OBJECTS=1 git -C "$here/.." "$@" 2>/dev/null; }
dc_head="$(dc_git rev-parse -q --verify HEAD:./core/distcheck.py)"
if [ -z "$dc_head" ]; then
  printf 'daedalus: Cannot tell whether distribution code is modified: core/distcheck.py is not in a committed tree here (is this home a git checkout?). Nothing was launched.\n' >&2; exit 2
fi
if [ "$(dc_git hash-object --no-filters core/distcheck.py)" != "$dc_head" ]; then
  printf 'daedalus: Distribution code is modified (core/distcheck.py); restore it before a review or a promote runs. Nothing was launched.\n' >&2; exit 2
fi
python3 -I -B "$here/distcheck.py" "$here/.." --for launch || exit 2
source "$here/lib.sh"
set +e
# The Python beside this file, never "$DAEDALUS_HOME/core/…": DAEDALUS_HOME can
# be inherited, and the launcher refuses a home that is not its own (config_file).
exec python3 "$here/call_agent.py" "$@"
