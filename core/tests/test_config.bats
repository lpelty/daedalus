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

@test "cfg_pairs splits a single path=url mapping" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  nested: agents/one=https://example.com/id.git
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "agents/one	https://example.com/id.git" ]
}

@test "cfg_pairs splits several mappings and trims spaces" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  nested: agents/one=https://example.com/id.git, vaults/one=https://example.com/v.git
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "agents/one	https://example.com/id.git" ]
  [ "${lines[1]}" = "vaults/one	https://example.com/v.git" ]
}

@test "cfg_pairs fails when the key is absent" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  repo: https://example.com/ship.git
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -ne 0 ]
}

@test "cfg_pairs rejects a mapping with no equals sign" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  nested: agents/one
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -ne 0 ]
}

@test "cfg_pairs rejects an entry with an empty url" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  nested: agents/one=
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -ne 0 ]
}

@test "cfg_pairs rejects an entry with an empty path" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  nested: =https://example.com/x.git
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -ne 0 ]
}

@test "cfg_pairs accepts a single-character path and url" {
  cat > "$BATS_TEST_TMPDIR/c.yaml" <<'EOF'
target:
  nested: a=b
EOF
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c.yaml" run cfg_pairs target.nested
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "a	b" ]
}

@test "target_path uses the repo URL basename when target.dir is absent" {
  run target_path
  [ "$status" -eq 0 ]
  [ "$output" = "$DAEDALUS_HOME/target/thing" ]
}

@test "target_path honors target.dir when a deployment names its checkout differently than its repo" {
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing-harness.git
  dir: thing
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_path
  [ "$status" -eq 0 ]
  [ "$output" = "$DAEDALUS_HOME/target/thing" ]
}

@test "target_path falls back to the basename when target.dir is blank" {
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  dir:
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_path
  [ "$status" -eq 0 ]
  [ "$output" = "$DAEDALUS_HOME/target/thing" ]
}

@test "target_path falls back to the basename when target.dir is null" {
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  dir: null
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_path
  [ "$status" -eq 0 ]
  [ "$output" = "$DAEDALUS_HOME/target/thing" ]
}

@test "target_path rejects a target.dir that attempts a parent-directory escape" {
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  dir: ../../escaped
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_path
  [ "$status" -ne 0 ]
}

@test "target_path rejects a bare .. target.dir with no slash" {
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  dir: ..
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_path
  [ "$status" -ne 0 ]
}

@test "target_path rejects an absolute target.dir" {
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  dir: /tmp/daedalus-abs-escape
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_path
  [ "$status" -ne 0 ]
}
