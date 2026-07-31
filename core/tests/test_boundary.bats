#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DAEDALUS_HOME
}

@test "target/ is gitignored" {
  cd "$DAEDALUS_HOME"
  run git check-ignore -q target/anything
  [ "$status" -eq 0 ]
}

@test "vault/ is gitignored" {
  cd "$DAEDALUS_HOME"
  run git check-ignore -q vault/anything
  [ "$status" -eq 0 ]
}

@test "config.yaml is gitignored but config.example.yaml is not" {
  cd "$DAEDALUS_HOME"
  run git check-ignore -q config.yaml
  [ "$status" -eq 0 ]
  run git check-ignore -q config.example.yaml
  [ "$status" -ne 0 ]
}

@test "settings.json denies writes outside target/ and vault/" {
  cd "$DAEDALUS_HOME"
  run grep -c 'Write(./core/\*\*)' .claude/settings.json
  [ "$status" -eq 0 ]
}
