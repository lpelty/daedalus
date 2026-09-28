#!/usr/bin/env bash
# End a working session: flush episodic capture explicitly; with --commit,
# then run the one sanctioned vault commit (core/vault-commit.sh, spec §4.7).
#
# The SessionEnd hook runs capture too, and capture is offset-tracked, so
# running both is safe and never double-captures. This exists because a
# session that ends uncleanly never fires that hook — and the conversation is
# gone from working memory either way, so an unrecorded session is lost
# rather than merely delayed.
#
# Exits non-zero when the flush failed. A close that reports success while
# the session went unrecorded is worse than no close at all.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Capture's configuration (spec §4.7): the memory: block in config.yaml, each
# field overridable by an environment variable of the same meaning. A Bash
# tool carries none of those variables, which is why close.sh from a session
# used to die here unless the operator had exported them. memory_env's own
# sentence names what is missing; this line says what did not happen.
env_lines="$(memory_env)" || die "episodic capture is not configured — nothing was flushed"
eval "$env_lines"

# --transcript <path>: an operator shell names the session to flush (spec
# §4.7 (2)); from a session capture.py finds it by CLAUDE_CODE_SESSION_ID.
commit=0
transcript=""
usage="usage: core/close.sh [--transcript <path>] [--commit]"
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) commit=1 ;;
    --transcript)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || die "$usage"
      transcript="$2"; shift ;;
    *) die "$usage" ;;
  esac
  shift
done
# A path the operator typed that is not there is a typo, not an empty
# session: stop before capture, and so before any vault commit. (capture.py
# refuses it too; this says it in close's own words.)
[ -z "$transcript" ] || [ -f "$transcript" ] \
  || die "no transcript at $transcript — nothing was flushed"
phases=1; [ "$commit" -eq 1 ] && phases=2

log "phase 1/$phases: episodic capture"
# PROP-002: verify extraction, do not just queue it. The server returns 202 on
# acceptance and extracts afterwards; without this, a failed extraction left
# the offset advanced past the lost span and this script still printed
# "close complete". Waiting costs a few seconds and is the only thing that
# makes the header comment above true rather than aspirational.
# The transcript (spec §4.7 (2)): --transcript when given; else capture.py
# resolves it from CLAUDE_CODE_SESSION_ID (the SessionStart marker, then the
# derivation) and refuses when there is nothing to go on.
# A Stop tick or the session-end flush may still be sending this session
# (spec §4.7): wait for it, then capture. Past the limit capture prints "a
# capture is still in flight after N s; wait and close again" and this dies —
# a close never reports a session it did not flush. Verification covers the
# whole session: the spans earlier Stop captures sent are waited out too, and
# while one is unconfirmed capture says which and fails (plan 2 Decision 15).
wait_secs="${CLOSE_WAIT_IN_FLIGHT_SECS:-90}"
case "$wait_secs" in
  ''|*[!0-9]*) die "CLOSE_WAIT_IN_FLIGHT_SECS must be a whole number of seconds (got: $wait_secs)" ;;
esac
# </dev/null: close.sh never carries a hook payload, and a Bash tool's stdin
# may be a socket that never closes.
CAPTURE_VERIFY_EXTRACTION=1 \
python3 "$DAEDALUS_HOME/core/capture.py" capture ${transcript:+--transcript "$transcript"} --wait-in-flight "$wait_secs" </dev/null \
  || die "capture failed or is not yet confirmed — the session is not recorded yet; see the capture lines above and close again"
# --commit: the prime's vault commit (spec §4.7) runs only after the capture
# succeeded — a failed capture stops the close before anything is committed.
if [ "$commit" -eq 1 ]; then
  log "phase 2/2: vault commit"
  bash "$DAEDALUS_HOME/core/vault-commit.sh" || die "vault commit failed"
fi
log "close complete"
