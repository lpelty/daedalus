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

@test "every builder path is denied for both Write and Edit" {
  cd "$DAEDALUS_HOME"
  for path in './core/**' './CLAUDE.md' './SOUL.md' './.claude/**' './config.example.yaml' './README.md'; do
    for verb in Write Edit; do
      run grep -qF "\"$verb($path)\"" .claude/settings.json
      [ "$status" -eq 0 ] || {
        echo "missing deny rule: $verb($path)"
        return 1
      }
    done
  done
}

@test "the deny list is exactly the 12 expected rules — no more, no fewer" {
  cd "$DAEDALUS_HOME"
  run bash -c "grep -cE '\"(Write|Edit)\\(' .claude/settings.json"
  [ "$output" = "12" ]
}
