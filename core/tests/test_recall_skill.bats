#!/usr/bin/env bats
#
# Pins the recall skill's contract. The skill is prose, so these tests
# assert the things whose absence makes it useless: that it names the real
# command, carries every variable that command requires, and says when to
# reach for it.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SKILL="$ROOT/.claude/skills/recall/SKILL.md"
}

@test "the recall skill exists" {
  [ -f "$SKILL" ]
}

@test "the skill carries name and description frontmatter" {
  run grep -qE '^name: recall$' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -qE '^description: .' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the skill names the command that performs the query" {
  run grep -qF "capture.py recall" "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the skill carries every variable capture.py requires" {
  # REQUIRED_ENV in core/capture.py. Omitting any one makes the documented
  # invocation exit before it queries.
  for v in TENANT_HOME TENANT_BANK TRANSCRIPT_DIR; do
    run grep -qF "$v" "$SKILL"
    [ "$status" -eq 0 ] || { echo "skill omits required env var: $v"; return 1; }
  done
}

@test "the skill's required-variable list matches capture.py" {
  # Guards against capture.py gaining a required variable the skill never
  # learns about. Extracts REQUIRED_ENV and checks each name appears.
  names="$(grep -E '^REQUIRED_ENV = ' "$ROOT/core/capture.py" | tr -cd 'A-Z_ ' | tr ' ' '\n' | grep -E '^[A-Z_]{4,}$' | grep -v '^REQUIRED_ENV$')"
  [ -n "$names" ]
  for v in $names; do
    run grep -qF "$v" "$SKILL"
    [ "$status" -eq 0 ] || { echo "capture.py requires $v; the skill omits it"; return 1; }
  done
}

@test "the skill states when to reach for recall" {
  run grep -qiE "prior|past|earlier|previous|before" "$SKILL"
  [ "$status" -eq 0 ]
}

@test "the skill documents the types filter" {
  run grep -qF -- "--types" "$SKILL"
  [ "$status" -eq 0 ]
}
