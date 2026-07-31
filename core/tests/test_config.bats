#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DAEDALUS_HOME
  TESTCFG="$BATS_TEST_TMPDIR/config.yaml"
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
  - echo two
proposals:
  budget: 5
EOF
  export DAEDALUS_CONFIG="$TESTCFG"
  source "$DAEDALUS_HOME/core/lib.sh"
}

@test "cfg reads a nested scalar" {
  run cfg target.repo
  [ "$status" -eq 0 ]
  [ "$output" = "https://github.com/example/thing.git" ]
}

@test "cfg reads a second nested scalar" {
  run cfg vault.repo
  [ "$output" = "https://github.com/example/thing-kb.git" ]
}

@test "cfg reads a numeric value" {
  run cfg proposals.budget
  [ "$output" = "5" ]
}

@test "cfg fails on a missing key" {
  run cfg target.nonexistent
  [ "$status" -eq 1 ]
}

@test "cfg_list reads a list" {
  run cfg_list gates
  [ "${lines[0]}" = "echo one" ]
  [ "${lines[1]}" = "echo two" ]
}

@test "die exits 1 with the message on stderr" {
  run bash -c "source '$DAEDALUS_HOME/core/lib.sh'; die 'boom' 2>&1"
  [ "$status" -eq 1 ]
  case "$output" in
    *boom*) : ;;
    *) echo "expected 'boom' in output; got: $output"; return 1 ;;
  esac
}
