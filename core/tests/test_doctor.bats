#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/doctor.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
}

@test "doctor fails when config is missing" {
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
}

@test "doctor fails when the target checkout is absent" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"target"* ]]
}

@test "doctor passes when config, target, and vault are all present" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
}

@test "doctor reports a missing exchange directory by name" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"exchange"* ]]
}

@test "doctor reports a missing vault subdirectory by name" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pitfalls"* ]]
}

@test "doctor reports a blank config value as missing (not present-but-empty)" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo:
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"target.repo"* ]]
}

@test "doctor reports a target directory that is not a git checkout" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing"
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"not a git repo"* ]]
}

@test "cfg accepts proposals.budget: 0 as present (empty is not the same as falsy)" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 0
EOF
  run bash -c "export DAEDALUS_HOME='$DAEDALUS_HOME' DAEDALUS_CONFIG='$DAEDALUS_HOME/config.yaml'; source '$DAEDALUS_HOME/core/lib.sh'; cfg proposals.budget"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "doctor passes when the vault is tracked by the parent repo instead of being its own git checkout" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
    touch "$DAEDALUS_HOME/vault/$d/.keep"
  done
  # Absorb vault/ into DAEDALUS_HOME's own git history (subtree-style), with
  # no vault/.git of its own — a deployment that folded its vault into the
  # parent repo. Git doesn't track empty directories, so each subdir needs a
  # real file for `git add` to pick up.
  git -C "$DAEDALUS_HOME" init --quiet
  git -C "$DAEDALUS_HOME" -c user.email=t@t.com -c user.name=t add vault
  git -C "$DAEDALUS_HOME" -c user.email=t@t.com -c user.name=t commit --quiet -m "absorb vault"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
}

@test "doctor still reports a genuinely missing vault even inside a parent git repo" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  # DAEDALUS_HOME is a git repo, but vault/ was never created or tracked.
  git -C "$DAEDALUS_HOME" init --quiet
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"vault"* ]]
}

@test "doctor still reports a vault that is tracked in git history but absent from disk" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  touch "$DAEDALUS_HOME/vault/infrastructure/.keep"
  git -C "$DAEDALUS_HOME" init --quiet
  git -C "$DAEDALUS_HOME" -c user.email=t@t.com -c user.name=t add vault
  git -C "$DAEDALUS_HOME" -c user.email=t@t.com -c user.name=t commit --quiet -m "absorb vault"
  # Now delete the vault from disk without touching the git index — this is
  # the false-green ls-files alone would miss, since ls-files checks the
  # index, not the working tree.
  rm -rf "$DAEDALUS_HOME/vault"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"vault"* ]]
}

@test "doctor finds a target checkout whose directory name differs from its repo name via target.dir" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing-harness.git
  dir: thing
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/target/thing/.git"
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"*"target checkout: $DAEDALUS_HOME/target/thing"* ]]
}

@test "doctor reports the YAML null spellings (null, ~) as missing" {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: null
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"target.repo"* ]]

  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: ~
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"target.repo"* ]]
}
