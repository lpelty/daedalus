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
phases=1; [ "$commit" -eq 1 ] && phases=2

log "phase 1/$phases: episodic capture"
# PROP-002: verify extraction, do not just queue it. The server returns 202 on
# acceptance and extracts afterwards; without this, a failed extraction left
# the offset advanced past the lost span and this script still printed
# "close complete". Waiting costs a few seconds and is the only thing that
# makes the header comment above true rather than aspirational.
# The transcript (spec §4.7 (2)): --transcript when given; else capture.py
# resolves it from CLAUDE_CODE_SESSION_ID (the SessionStart marker, then the
# derivation) and refuses when there is nothing to go on. </dev/null:
# close.sh never carries a hook payload, and a Bash tool's stdin may be a
# socket that never closes.
CAPTURE_VERIFY_EXTRACTION=1 \
python3 "$DAEDALUS_HOME/core/capture.py" capture ${transcript:+--transcript "$transcript"} </dev/null \
  || die "capture failed — the session is unrecorded"
# --commit: the prime's vault commit (spec §4.7) runs only after the capture
# succeeded — a failed capture stops the close before anything is committed.
if [ "$commit" -eq 1 ]; then
  log "phase 2/2: vault commit"
  bash "$DAEDALUS_HOME/core/vault-commit.sh" || die "vault commit failed"
fi
log "close complete"
