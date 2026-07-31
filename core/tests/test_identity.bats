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
