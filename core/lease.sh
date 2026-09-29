#!/usr/bin/env bash
# Leases: one numbered window per Daedalus session (spec §4.2). Every write to
# state/leases/ goes through core/leaselib.py; this file only names the
# calling session and hands over. Usage:
#   core/lease.sh create [--note "..."] [--criteria <file>]
#   core/lease.sh claim <NN> | alias <NN> <word> [--clear] | note <NN> "..." | update <NN> --criteria <file>
#   core/lease.sh spawn "<task>" [--note "..."] | list [--stale] | status
#   core/lease.sh release <NN> [--remove [--force]] | done <NN> --summary "..." | sweep [--force <NN>]
#   core/lease.sh prime take [--reason "..."] | rebase <NN> | split <NN> --repo <nested>
#   core/lease.sh adopt <branch> [--repo <nested>] [--note "..."]
# A direct-call session (DIRECT_CALL_ID set — spec §4.8, a visitor) is refused
# every command that changes state/leases/; list and status still work.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -ge 1 ] || die "usage: core/lease.sh <create|claim|alias|note|update|spawn|list|status|release|done|sweep|prime|rebase|split|adopt> ..."
cmd="$1"; shift
case "$cmd" in
  create|claim|alias|note|update|spawn|list|status|release|done|sweep|prime|rebase|split|adopt) ;;
  *) die "unknown command: $cmd" ;;
esac
# Spec §14: a home that pulled a release and has not started a session since has no state/leases/ yet; the
# upgrade makes it at the next session start. Only when VERSION says a release is waiting (plan 5 Decision 13).
if [ ! -d "$DAEDALUS_HOME/state/leases" ] && ver="$(daedalus_version)" \
   && [ "$(cat "$DAEDALUS_HOME/state/upgraded-to" 2>/dev/null)" != "$ver" ]; then
  die "the upgrade has not run; start a session in this home"
fi
exec python3 "$DAEDALUS_HOME/core/leaselib.py" "$cmd" "$@"
