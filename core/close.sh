#!/usr/bin/env bash
# End a working session: flush episodic capture explicitly, then commit the vault
# with the one sanctioned vault commit (core/vault-commit.sh, spec §4.7) unless
# --no-commit. (--commit, the old opt-in, is still accepted and changes nothing.)
# When another live session holds the pen, vault-commit.sh says so in one line
# and exits 3: that session's next commit carries this one's files, and the
# close still succeeds. When the pen's holder has ended, this session takes the
# pen there and commits.
#
# The SessionEnd hook runs capture too, and capture is offset-tracked, so
# running both is safe and never double-captures. This exists because a
# session that ends uncleanly never fires that hook — and the conversation is
# gone from working memory either way, so an unrecorded session is lost
# rather than merely delayed.
#
# Exits 1 when the flush failed: a close that reports success while the session
# went unrecorded is worse than no close at all. Exits 4 when the session is
# recorded but the vault commit did not run: fix what its line names, then run
# core/vault-commit.sh — never the whole close again.
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
commit=1
transcript=""
usage="usage: core/close.sh [--transcript <path>] [--no-commit]"
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) commit=1 ;;      # the default now; accepted so older briefs and deployment skills keep working
    --no-commit) commit=0 ;;
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
# Phase 2, the vault commit (spec §4.7), runs only after the capture succeeded —
# a failed capture stops the close before anything is committed.
# rc=0 … || rc=$?: lib.sh sets -e, and `|| die` alone cannot tell exit 3 from exit 1.
if [ "$commit" -eq 1 ]; then
  log "phase 2/2: vault commit"
  # Its lines pass through as it writes them, each on its own stream, in its order; stderr is also kept
  # (tee) for the failure's line — vault-commit.sh says why it failed last on stderr.
  errf="$(mktemp)"
  rc=0
  { bash "$DAEDALUS_HOME/core/vault-commit.sh" 2>&1 1>&3 3>&- | tee "$errf" >&2 3>&- || rc=${PIPESTATUS[0]}; } 3>&1
  err="$(cat "$errf")"; rm -f "$errf"
  case $rc in
    0) : ;;
    3) log "close complete (the vault is the pen holder's to commit)"; exit 0 ;;
    *) last="$(printf '%s\n' "$err" | sed '/^$/d' | tail -1)"; last="${last#daedalus: }"
       printf 'daedalus: %s\n' "the session is recorded; the vault commit did not run: ${last:-core/vault-commit.sh exited $rc}" >&2
       exit 4 ;;
  esac
fi
log "close complete"
