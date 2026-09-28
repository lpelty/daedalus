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

@test "target_name is the checkout's directory name from config alone: repo basename, or target.dir under the same single-segment rule" {
  run target_name; [ "$status" -eq 0 ]; [ "$output" = "thing" ]
  cat > "$TESTCFG" <<'EOF'
target:
  repo: https://github.com/example/thing.git
  dir: other
  branch: main
vault:
  repo: https://github.com/example/thing-kb.git
gates:
  - echo one
proposals:
  budget: 5
EOF
  run target_name; [ "$output" = "other" ]
  run target_path; [ "$output" = "$DAEDALUS_HOME/target/other" ]
  sed -i '' 's#  dir: other#  dir: a/b#' "$TESTCFG"
  run target_name; [ "$status" -ne 0 ]; case "$output" in *"must be a single directory name"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- memory: block and memory_env (spec §4.7 "one place", §8.1) --------------
clear_mem_env() {
  unset TENANT_HOME TENANT_BANK HINDSIGHT_API_URL TRANSCRIPT_DIR CAPTURE_INTERVAL \
        HINDSIGHT_API_TENANT_API_KEY TENANT_USER_LABEL TENANT_ASSISTANT_LABEL
}

@test "memory_env: no memory: block and no TENANT_BANK -> returns 1, prints no export, and names memory.bank and TENANT_BANK" {
  clear_mem_env
  run memory_env
  [ "$status" -eq 1 ]
  case "$output" in *"memory.bank"*"TENANT_BANK"*"README"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"export "*) echo "printed exports: $output"; return 1 ;; *) : ;; esac
  run memory_configured; [ "$status" -ne 0 ]
}

@test "memory_env: the memory: block is the source — every field exported, TENANT_HOME is the Daedalus home, no key when none is configured" {
  clear_mem_env
  cat >> "$TESTCFG" <<'EOF'
memory:
  bank: testbank
  api_url: http://127.0.0.1:9
  capture_interval: 90
  transcript_dir: /tmp/transcripts-x
  user_label: OPERATOR
  assistant_label: Daedalus
EOF
  run memory_configured; [ "$status" -eq 0 ]
  run memory_env; [ "$status" -eq 0 ]
  eval "$output"
  [ "$TENANT_BANK" = testbank ]; [ "$HINDSIGHT_API_URL" = http://127.0.0.1:9 ]; [ "$CAPTURE_INTERVAL" = 90 ]
  [ "$TRANSCRIPT_DIR" = /tmp/transcripts-x ]; [ "$TENANT_USER_LABEL" = OPERATOR ]; [ "$TENANT_ASSISTANT_LABEL" = Daedalus ]
  [ "$TENANT_HOME" = "$DAEDALUS_HOME" ]
  [ -z "${HINDSIGHT_API_TENANT_API_KEY:-}" ]
}

@test "memory_env: an environment variable overrides its field, field by field" {
  clear_mem_env
  printf 'memory:\n  bank: testbank\n  api_url: http://127.0.0.1:9\n  capture_interval: 90\n' >> "$TESTCFG"
  export TENANT_BANK=envbank CAPTURE_INTERVAL=30
  run memory_env; [ "$status" -eq 0 ]
  clear_mem_env; eval "$output"
  [ "$TENANT_BANK" = envbank ]; [ "$CAPTURE_INTERVAL" = 30 ]; [ "$HINDSIGHT_API_URL" = http://127.0.0.1:9 ]
}

@test "memory_env: defaults — 127.0.0.1:8888, 120 s, and a transcript directory derived from the home (every character but letters and digits as -) under CLAUDE_CONFIG_DIR" {
  clear_mem_env
  printf 'memory:\n  bank: b\n' >> "$TESTCFG"
  export DAEDALUS_HOME=/srv/dae.home CLAUDE_CONFIG_DIR=/cfg
  run memory_env; [ "$status" -eq 0 ]
  eval "$output"
  [ "$HINDSIGHT_API_URL" = http://127.0.0.1:8888 ]; [ "$CAPTURE_INTERVAL" = 120 ]
  [ "$TRANSCRIPT_DIR" = /cfg/projects/-srv-dae-home ]; [ "$TENANT_HOME" = /srv/dae.home ]
}

@test "memory_env: the derived transcript directory follows Claude Code's rule on the physical path — every character but letters and digits becomes -" {
  clear_mem_env
  printf 'memory:\n  bank: b\n' >> "$TESTCFG"
  H="$BATS_TEST_TMPDIR/my_home.d"; mkdir -p "$H"
  export DAEDALUS_HOME="$H" CLAUDE_CONFIG_DIR=/cfg
  run memory_env; [ "$status" -eq 0 ]
  eval "$output"
  # An independent spelling of the rule (sed, not the implementation's), on
  # the resolved path: the bats temp dir sits behind /var -> /private/var.
  want="/cfg/projects/$(cd "$H" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
  [ "$TRANSCRIPT_DIR" = "$want" ] || { echo "$TRANSCRIPT_DIR != $want"; return 1; }
  case "$TRANSCRIPT_DIR" in */projects/*_*|*/projects/*.*) echo "kept punctuation: $TRANSCRIPT_DIR"; return 1 ;; *) : ;; esac
}

@test "memory_env: capture_interval must be whole seconds > 0" {
  clear_mem_env
  printf 'memory:\n  bank: b\n  capture_interval: 2m\n' >> "$TESTCFG"
  run memory_env; [ "$status" -eq 1 ]
  case "$output" in *"memory.capture_interval must be a whole number of seconds"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "memory_env: api_key_file is read from under the home when 0600; refused when others can read it, when absolute, with .., or missing" {
  clear_mem_env
  H="$BATS_TEST_TMPDIR/h"; mkdir -p "$H/state/hindsight"
  printf 'not-a-real-key\n' > "$H/state/hindsight/api-key"; chmod 600 "$H/state/hindsight/api-key"
  printf 'memory:\n  bank: b\n  api_key_file: state/hindsight/api-key\n' >> "$TESTCFG"
  export DAEDALUS_HOME="$H"
  run memory_env; [ "$status" -eq 0 ]
  eval "$output"; [ "$HINDSIGHT_API_TENANT_API_KEY" = not-a-real-key ]; unset HINDSIGHT_API_TENANT_API_KEY
  chmod 644 "$H/state/hindsight/api-key"
  run memory_env; [ "$status" -eq 1 ]
  case "$output" in *"memory.api_key_file state/hindsight/api-key is readable by others (mode 644); run chmod 600"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *not-a-real-key*) echo "the key leaked into a message: $output"; return 1 ;; *) : ;; esac
  for bad in /etc/key ../key state/../../key; do
    sed -i '' "s#^  api_key_file: .*#  api_key_file: $bad#" "$TESTCFG"
    run memory_env; [ "$status" -eq 1 ]
    case "$output" in *"must be a path under the Daedalus home"*) : ;; *) echo "$bad: $output"; return 1 ;; esac
  done
  sed -i '' 's#^  api_key_file: .*#  api_key_file: state/none#' "$TESTCFG"
  run memory_env; [ "$status" -eq 1 ]
  case "$output" in *"memory.api_key_file state/none does not exist"*) : ;; *) echo "$output"; return 1 ;; esac
  # A configured key file that yields no key is refused, never treated as "no key".
  sed -i '' 's#^  api_key_file: .*#  api_key_file: state/hindsight/api-key#' "$TESTCFG"
  chmod 600 "$H/state/hindsight/api-key"
  for body in '' '\nkey-on-second-line\n' '   \n'; do
    printf "$body" > "$H/state/hindsight/api-key"
    run memory_env; [ "$status" -eq 1 ] || { echo "body [$body] rc=$status: $output"; return 1; }
    case "$output" in *"memory.api_key_file state/hindsight/api-key is empty — put the REST API key on its first line"*) : ;; *) echo "body [$body]: $output"; return 1 ;; esac
    case "$output" in *HINDSIGHT_API_TENANT_API_KEY*|*key-on-second-line*) echo "body [$body] leaked: $output"; return 1 ;; *) : ;; esac
  done
}

@test "config.example.yaml ships a memory: block commented out, and memory_env reads it once uncommented" {
  clear_mem_env
  ex="$DAEDALUS_HOME/config.example.yaml"
  grep -q '^# memory:' "$ex"
  run grep -q '^memory:' "$ex"; [ "$status" -ne 0 ]
  { cat "$TESTCFG"; sed -n '/^# memory:/,/^$/p' "$ex" | sed 's/^# //'; } > "$BATS_TEST_TMPDIR/c2.yaml"
  H="$BATS_TEST_TMPDIR/h2"; mkdir -p "$H/state/hindsight"
  printf 'k\n' > "$H/state/hindsight/api-key"; chmod 600 "$H/state/hindsight/api-key"
  export DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/c2.yaml" DAEDALUS_HOME="$H"
  run memory_env; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  eval "$output"
  [ "$TENANT_BANK" = daedalus ]; [ "$CAPTURE_INTERVAL" = 120 ]; [ "$HINDSIGHT_API_URL" = http://127.0.0.1:8888 ]
  [ "$HINDSIGHT_API_TENANT_API_KEY" = k ]
}
