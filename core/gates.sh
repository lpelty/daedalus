#!/usr/bin/env bash
# Run the target harness's gate commands. Green is an exit code.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

target="$(target_path)"
[ -d "$target" ] || die "no target checkout at $target — run core/sync-target.sh"

failed=0
gate_count=0
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  gate_count=$((gate_count + 1))
  # Gate commands come from operator-authored config.yaml and are deliberately
  # trusted — eval is intentional here, not a place to route untrusted input.
  # stdin is redirected from /dev/null so a gate that reads stdin (e.g. a test
  # runner piping through `cat`) can't consume the remaining unread gate lines
  # off this loop's heredoc and silently skip them.
  if ( cd "$target" && eval "$gate" ) </dev/null >/dev/null 2>&1; then
    log "PASS  $gate"
  else
    log "FAIL  $gate"
    failed=1
  fi
done <<EOF
$(cfg_list gates)
EOF

if [ "$gate_count" -eq 0 ]; then
  die "no gates configured — refusing to report success (check the gates: list in config.yaml)"
fi

if [ "$failed" -ne 0 ]; then
  die "one or more gates failed"
fi
log "all gates passed"
