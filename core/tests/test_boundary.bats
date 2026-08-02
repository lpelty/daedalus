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
  for path in './core/**' './CLAUDE.md' './SOUL.md' './.claude/settings.json' './config.example.yaml' './README.md'; do
    for verb in Write Edit; do
      run grep -qF "\"$verb($path)\"" .claude/settings.json
      [ "$status" -eq 0 ] || {
        echo "missing deny rule: $verb($path)"
        return 1
      }
    done
  done
}

@test "the deny list is exactly the 14 expected rules — no more, no fewer" {
  cd "$DAEDALUS_HOME"
  run bash -c "grep -cE '\"(Write|Edit)\\(' .claude/settings.json"
  [ "$output" = "14" ]
}

@test "the deny list does not block .claude/skills/**" {
  cd "$DAEDALUS_HOME"
  run grep -qF '.claude/skills' .claude/settings.json
  [ "$status" -ne 0 ]
}

@test ".claude/settings.local.json is gitignored by the repo's own rules" {
  cd "$DAEDALUS_HOME"
  # Override core.excludesfile to neutralize any operator's global gitignore
  # (e.g. ~/.gitignore_global) so this only exercises the repo's own
  # .gitignore. Without this override the test could pass for the wrong
  # reason on a machine whose global config happens to cover this path.
  run git -c core.excludesfile=/dev/null check-ignore -q .claude/settings.local.json
  [ "$status" -eq 0 ]
}

@test "state/ and .capture.log are gitignored by the repo's own rules" {
  cd "$DAEDALUS_HOME"
  # Override core.excludesfile to neutralize any operator's global gitignore
  # so this only exercises the repo's own .gitignore.
  run git -c core.excludesfile=/dev/null check-ignore -q state/hindsight/offsets.json
  [ "$status" -eq 0 ]
  run git -c core.excludesfile=/dev/null check-ignore -q .capture.log
  [ "$status" -eq 0 ]
}

@test "both settings files are protected, local included" {
  cd "$DAEDALUS_HOME"
  # settings.local.json holds a deployment's own deny rules. An agent able to
  # rewrite its own permission surface can lift every other restriction, so it
  # is protected alongside the tracked settings file. The broad ./.claude/**
  # rule used to cover it incidentally; narrowing that rule to unblock skills
  # removed the coverage, and this test pins it back.
  for f in settings.json settings.local.json; do
    for verb in Write Edit; do
      run grep -qF "\"$verb(./.claude/$f)\"" .claude/settings.json
      [ "$status" -eq 0 ] || {
        echo "missing deny rule: $verb(./.claude/$f)"
        return 1
      }
    done
  done
}
