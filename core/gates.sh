#!/usr/bin/env bash
# Run the target harness's gate commands. Green is an exit code.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

target="$(target_path)"
[ -d "$target" ] || die "no target checkout at $target — run core/sync-target.sh"

failed=0
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  if ( cd "$target" && eval "$gate" ) >/dev/null 2>&1; then
    log "PASS  $gate"
  else
    log "FAIL  $gate"
    failed=1
  fi
done <<EOF
$(cfg_list gates)
EOF

if [ "$failed" -ne 0 ]; then
  die "one or more gates failed"
fi
log "all gates passed"
