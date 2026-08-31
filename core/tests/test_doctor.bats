#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/doctor.sh" "$SRC/verifylib.py" "$SRC/verify-hook.py" "$DAEDALUS_HOME/core/"
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

@test "doctor notes the stage is unarmed when vault/evidence has no evidence yet; clears once one exists" {
  # Finding 1: claims() returns [] until vault/evidence/ has a dated *.md
  # file, which is also what forces the first gates.sh run to happen at
  # all — with none yet, the whole stage is inert and gives no signal that
  # it is. This pins the VISIBILITY half: a NOTE line that does not turn
  # doctor red (NOTE is not MISSING, so it must not count toward $problems).
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

  # No vault/evidence/ directory at all yet.
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"NOTE"*"verify: stage unarmed"*"run core/gates.sh once to arm it"*) : ;; *) echo "expected the unarmed NOTE; got: $output"; return 1 ;; esac

  # An empty vault/evidence/ directory (present, but no *.md yet) is the same case.
  mkdir -p "$DAEDALUS_HOME/vault/evidence"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"stage unarmed"*) : ;; *) echo "expected the unarmed NOTE for an empty evidence dir; got: $output"; return 1 ;; esac

  # One evidence doc arms the stage — the NOTE must clear.
  cat > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md" <<'EOF'
---
type: evidence
created: 2026-01-01T00:00:00
result: PASS
fingerprint: deadbeef
config-sha: deadbeef
---
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"stage unarmed"*) echo "NOTE should have cleared once evidence exists: $output"; return 1 ;; *) : ;; esac
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
  # Assert the SPECIFIC signal the on-disk check produces, not merely that
  # doctor failed. With the `-d` guard deleted, ls-files still reports the
  # vault as tracked, doctor takes the else branch, and its six "MISSING
  # vault/<subdir>" lines satisfied a loose *"MISSING"*"vault"* match — so
  # this test stayed green against exactly the mutant it exists to catch.
  [[ "$output" == *"vault is not a git repo and is not tracked by the parent repo"* ]]
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

@test "doctor blames a rejected target.dir on the config, not on a missing checkout" {
  # target_path rejects a target.dir carrying a path separator. doctor swallowed
  # that rejection with `|| true` and reported the generic "run
  # core/sync-target.sh" — a remedy that cannot help, since sync-target calls
  # the same function and hits the same rejection. The operator has to edit the
  # config, so the config is what the message must name.
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  dir: ../escape
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do
    mkdir -p "$DAEDALUS_HOME/vault/$d"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh" 2>&1
  [ "$status" -ne 0 ]
  # Names the offending config key...
  [[ "$output" == *"target.dir"* ]]
  # ...and does not send the operator to a script that cannot fix it.
  [[ "$output" != *"target checkout — run core/sync-target.sh"* ]]
  # ...and reaches its verdict rather than dying mid-run. `die` inside a
  # command substitution exits the whole script, which silently truncated
  # doctor after the config checks.
  [[ "$output" == *"problem(s) found"* ]]
}

@test "doctor keeps checking the rest of the deployment after a bad target.dir" {
  # doctor's contract is that one broken thing does not hide the others: it
  # names every problem in one run rather than aborting on the first. Surfacing
  # the config error must not turn into an early exit.
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  dir: ../escape
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  # No vault at all, so a surviving run must also report the vault problem.
  run bash "$DAEDALUS_HOME/core/doctor.sh" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"target.dir"* ]]
  [[ "$output" == *"MISSING"*"vault"* ]]
  [[ "$output" == *"problem(s) found"* ]]
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

@test "doctor reports an unverified claim (IMPLEMENTED with no evidence-run) and clears once cited" {
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

  # First evidence for the deployment — claims.py only considers a doctor-
  # scanned document a claim once at least one evidence record exists.
  mkdir -p "$DAEDALUS_HOME/vault/evidence"
  cat > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md" <<'EOF'
---
type: evidence
created: 2026-01-01T00:00:00
result: PASS
fingerprint: deadbeef
config-sha: deadbeef
---
EOF

  # A completion claim recorded after that first evidence, with no
  # evidence-run citing a PASS gate run for this deployment.
  cat > "$DAEDALUS_HOME/vault/proposals/PROP-1.md" <<'EOF'
---
type: proposal
status: IMPLEMENTED
author: daedalus
updated-by: daedalus
created: 2026-02-01
---
EOF

  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"unverified claim"*"PROP-1.md"* ]]

  # Cite an evidence-run — doctor's --doctor pass is offline (live=False), so
  # it checks only that evidence-run is present and that record's result is
  # PASS; it does not re-verify fingerprint/config-sha against a live tree.
  cat > "$DAEDALUS_HOME/vault/proposals/PROP-1.md" <<'EOF'
---
type: proposal
status: IMPLEMENTED
author: daedalus
updated-by: daedalus
created: 2026-02-01
evidence-run: 20260101-000000-abcdef
---
EOF

  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
}

@test "a crashing verify-hook.py --doctor turns doctor red instead of silently green" {
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

  # Otherwise-healthy fixture, no claims at all — the empty stdout from a
  # crashing verify-hook.py must not be mistaken for "no unverified claims".
  # Stub prints nothing and exits 3, standing in for a real crash (e.g. a
  # traceback on stderr, which is discarded by doctor's 2>/dev/null exactly
  # as a real crash's traceback would be).
  cat > "$DAEDALUS_HOME/core/verify-hook.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.exit(3)
EOF

  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"check failed"* ]]
  [[ "$output" == *"exited 3"* ]]
  [[ "$output" != *"Traceback"* ]]

  # Positive control: restore the real verify-hook.py (copied by setup() from
  # the source tree) and confirm doctor goes back to green on the same,
  # still-claim-free fixture.
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/verify-hook.py" "$DAEDALUS_HOME/core/verify-hook.py"

  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
}

@test "doctor notes that the pitfall check is skipped when the script is absent, and stays green" {
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
  mkdir -p "$DAEDALUS_HOME/target/thing/.git" "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'NOTE     pitfalls: check skipped')" -eq 1 ]
}

@test "doctor runs the pitfall check from another cwd and prefixes NOTE" {
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
  mkdir -p "$DAEDALUS_HOME/target/thing/.git" "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
  cp "$SRC/pitfall-inject.py" "$DAEDALUS_HOME/core/"
  printf -- '---\ntype: pitfall\n---\n# No trigger\n\nB.\n' > "$DAEDALUS_HOME/vault/pitfalls/nn.md"
  cd "$BATS_TEST_TMPDIR"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'NOTE     pitfalls: 1 total, 1 cannot fire')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'NOTE       nn.md: no applies-to')" -eq 1 ]
}


@test "doctor survives a crashing pitfall-inject.py --check quietly, exit status unchanged" {
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
  mkdir -p "$DAEDALUS_HOME/target/thing/.git" "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
  cat > "$DAEDALUS_HOME/core/pitfall-inject.py" <<'EOF'
import sys
sys.exit(3)
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'NOTE     pitfalls: check failed (core/pitfall-inject.py --check exited 3)')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'Traceback')" -eq 0 ]
}

@test "doctor NOTEs vault-search --check lines; absent script -> skipped line" {
  cp "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
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
  mkdir -p "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -cF 'NOTE     document recall:')" -gt 0 ]
  rm "$DAEDALUS_HOME/core/vault-search.py"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -cF 'document recall: check skipped')" -eq 1 ]
}

@test "doctor NOTEs code-context --check; absent script -> skipped line" {
  cp "$SRC/code-context.py" "$DAEDALUS_HOME/core/"
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
  mkdir -p "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -cF 'NOTE     code context:')" -gt 0 ]
  rm "$DAEDALUS_HOME/core/code-context.py"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$(printf '%s\n' "$output" | grep -cF 'code context: check skipped')" -eq 1 ]
}
