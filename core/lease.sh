#!/usr/bin/env bash
# Leases: one numbered window per Daedalus session (spec §4.2). Every write to
# state/leases/ goes through core/leaselib.py; this file only names the
# calling session and hands over. Usage:
#   core/lease.sh create [--note "..."] [--criteria <file>]
#   core/lease.sh claim <NN> | alias <NN> <word> [--clear] | note <NN> "..." | update <NN> --criteria <file>
#   core/lease.sh spawn "<task>" [--note "..."] | list [--stale] | status
#   core/lease.sh release <NN> [--remove [--force]] | done <NN> --summary "..." | sweep [--force <NN>]
#   core/lease.sh prime take [--reason "..."]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -ge 1 ] || die "usage: core/lease.sh <create|claim|alias|note|update|spawn|list|status|release|done|sweep|prime> ..."
cmd="$1"; shift
case "$cmd" in
  create|claim|alias|note|update|spawn|list|status|release|done|sweep|prime) ;;
  rebase|split|adopt) die "core/lease.sh $cmd is not in this release yet" ;;
  *) die "unknown command: $cmd" ;;
esac
exec python3 "$DAEDALUS_HOME/core/leaselib.py" "$cmd" "$@"
