#!/usr/bin/env bash
# End a working session: flush episodic capture explicitly.
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

for v in TENANT_HOME TENANT_BANK TRANSCRIPT_DIR; do
  # bash 3.2 supports ${!v} indirect expansion — verified on the target
  # shell (GNU bash 3.2.57, arm64-apple-darwin25), so no eval is needed.
  [ -n "${!v:-}" ] || die "episodic capture needs $v — see the capture section of README.md"
done

log "phase 1/1: episodic capture"
python3 "$DAEDALUS_HOME/core/capture.py" capture \
  || die "capture failed — the session is unrecorded"
log "close complete"
