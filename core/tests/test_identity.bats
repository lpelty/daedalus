#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DAEDALUS_HOME
}

@test "CLAUDE.md exists and states the no-self-modification rule" {
  [ -f "$DAEDALUS_HOME/CLAUDE.md" ]
  run grep -qi "belongs to the distribution" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -qi "stays exactly as the distribution shipped it" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md names the five states" {
  for s in IMPLEMENTED REFUSED BLOCKED SCOPE-CREEP PROPOSED; do
    run grep -q "$s" "$DAEDALUS_HOME/CLAUDE.md"
    [ "$status" -eq 0 ]
  done
}

@test "CLAUDE.md names the write boundary" {
  run grep -q "target/" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "vault/" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "SOUL.md exists" {
  [ -f "$DAEDALUS_HOME/SOUL.md" ]
}

@test "identity files contain no harness-specific facts" {
  run grep -riE "fleet|atlas|smartsheet|larrypelty" "$DAEDALUS_HOME/CLAUDE.md" "$DAEDALUS_HOME/SOUL.md"
  [ "$status" -ne 0 ]
}

# The test above only ever looked at CLAUDE.md and SOUL.md. That narrow scope
# is exactly how a personal-identity fixture leak (agents/bill, vaults/bill
# in core/tests/test_config.bats) survived seven prior reviews — the guard
# never looked at core/, README.md, or config.example.yaml. This test scans
# every tracked file instead of a hardcoded list, so it keeps covering
# whatever the repo actually ships as files are added or renamed.
#
# The two tests are kept separate rather than folded together: this one
# pins the two identity files specifically (the highest-stakes leak surface,
# since their content is injected as instructions) and fails with a precise
# "CLAUDE.md/SOUL.md" signal; the wide scan below fails with "somewhere in
# the tree," which is the right granularity for a repo-wide sweep but the
# wrong granularity for the two files most likely to matter.
@test "no tracked file leaks personal-identity or environment facts" {
  cd "$DAEDALUS_HOME"
  self="core/tests/test_identity.bats"
  offenders=""

  # Token list: the general set from the narrow test above (fleet, atlas,
  # smartsheet, larrypelty), plus larry/lpelty/an absolute-home-path prefix
  # since those are equally personal and not covered by "larrypelty" alone.
  # "bill" — the agent's own name — is included separately below with a
  # word-boundary match: as a bare regex alternative it would also match
  # "billing", "billion", and "William", none of which are identity leaks,
  # so it can't share the unbounded pattern the other tokens use safely.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$self" ] && continue
    if grep -qiE "larry|lpelty|/Users/|fleet|atlas|smartsheet" "$f"; then
      offenders="$offenders $f(token)"
    fi
    if grep -qwiE "bill" "$f"; then
      offenders="$offenders $f(bill)"
    fi
  done <<EOF
$(git ls-files)
EOF

  [ -z "$offenders" ] || { echo "personal-identity leak in:$offenders"; return 1; }
}

@test "loaded identity files state rules positively" {
  run grep -qi "does not modify" "$DAEDALUS_HOME/CLAUDE.md" "$DAEDALUS_HOME/README.md"
  [ "$status" -ne 0 ]
  run grep -qi "never promote" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -ne 0 ]
}

@test "CLAUDE.md frames target/ contents as evidence, not directives" {
  run grep -q "material under audit" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "observations about how that harness instructs its agent" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md carries the evidence framing into dispatch prompts" {
  run grep -q "reads this file only if you put it there" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "take your instructions from this prompt" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md states the provenance field names" {
  for f in "author:" "created:" "updated-by:" "updated:"; do
    run grep -qF "$f" "$DAEDALUS_HOME/CLAUDE.md"
    [ "$status" -eq 0 ]
  done
}

@test "CLAUDE.md states author and created stay fixed across edits" {
  run grep -q "keeps .author. and .created. exactly as found" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md distinguishes updated from verified-against-live" {
  run grep -q "asserting something stricter" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "moves on any edit, including a typo fix" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "verification pass moves .verified-against-live." "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}
