#!/usr/bin/env bash
# The direct-call launcher's entry point (spec §8): one core, three callees —
# the target's own agent (--callee agent, named ONLY by config.yaml
# direct_call.callee_home / callee_name), this Daedalus called by an allowlisted
# agent (--callee self), and the fresh-context refuter Thing (--callee refuter,
# used by core/refute.sh). Answer on stdout, a two-line receipt on stderr,
# resume by call id; exit 0 / 2 refused / 3 orientation unverified / 124 timed
# out, else claude's own exit. Callers check the exit code AND a non-empty
# stdout, never the receipt line alone. See core/call_agent.py for the contract.
#
# bash 3.2: this file only sources lib.sh (which exports DAEDALUS_HOME and
# DAEDALUS_CONFIG — call_agent.py refuses either unless it is this deployment's)
# and execs the Python — exec, so a SIGTERM to the caller's
# process group reaches the launcher, whose handler kills claude's group.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib.sh"
set +e
command -v python3 >/dev/null 2>&1 || { printf 'daedalus: python3 not found on PATH — cannot launch the call\n' >&2; exit 2; }
# The Python beside this file, never "$DAEDALUS_HOME/core/…": DAEDALUS_HOME can
# be inherited, and the launcher refuses a home that is not its own (config_file).
exec python3 "$here/call_agent.py" "$@"
