#!/usr/bin/env bats

load fixtures/leases/setup.bash

# The target checkout in these fixtures is a real (empty, origin-less) `git
# init` repository, never a faked `mkdir target/thing/.git`: doctor asks git
# whether the directory is a work tree's root (lib.sh is_work_tree_root, the
# predicate fingerprint.sh and sync-target.sh use), and a bare directory named
# .git is not one. An origin-less repo makes the branch check a NOTE, not a
# problem, so the green fixtures stay green.
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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

@test "doctor accepts a target checkout whose .git is a file (a linked worktree) — the same root predicate as fingerprint.sh and sync-target.sh" {
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
  git init -q -b main "$BATS_TEST_TMPDIR/main-checkout"
  git -C "$BATS_TEST_TMPDIR/main-checkout" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$DAEDALUS_HOME/target"
  git -C "$BATS_TEST_TMPDIR/main-checkout" worktree add -q "$DAEDALUS_HOME/target/thing" -b lease/01 HEAD
  [ -f "$DAEDALUS_HOME/target/thing/.git" ]
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [[ "$output" == *"OK       target checkout: $DAEDALUS_HOME/target/thing"* ]]
  [[ "$output" != *"target checkout is not a git repo"* ]]
}

@test "doctor reports a target that lost its .git as MISSING even when the deployment root is itself a repository (git would answer there, but it is not the target)" {
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
  git init -q "$BATS_TEST_TMPDIR"          # the deployment root is itself a repository
  mkdir -p "$DAEDALUS_HOME/target/thing"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"*"target checkout is not a git repo"* ]]
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"
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
  git init -q "$DAEDALUS_HOME/target/thing"; mkdir -p "$DAEDALUS_HOME/vault/.git"
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
  git init -q "$DAEDALUS_HOME/target/thing"; mkdir -p "$DAEDALUS_HOME/vault/.git"
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
  git init -q "$DAEDALUS_HOME/target/thing"; mkdir -p "$DAEDALUS_HOME/vault/.git"
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

# --- target.branch vs the target's default branch (v0.6.1) ------------------

doctor_config_with_branch() {   # doctor_config_with_branch <branch>
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF2
target:
  repo: https://example.com/thing.git
  branch: $1
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF2
}

clone_target_with_default_branch() {   # clone_target_with_default_branch <default-branch> [other-branch...]
  # A bare origin whose HEAD points at the first branch (plus any others),
  # cloned the way sync-target.sh clones, so refs/remotes/origin/HEAD and
  # every origin/<branch> are recorded.
  local origin="$BATS_TEST_TMPDIR/origin.git" work="$BATS_TEST_TMPDIR/work" b
  git init -q --bare -b "$1" "$origin"
  git init -q -b "$1" "$work"
  printf 'x\n' > "$work/README.md"
  git -C "$work" add -A
  git -C "$work" -c user.email=t@x -c user.name=t commit -q -m i
  git -C "$work" push -q "$origin" "$1"
  for b in "${@:2}"; do
    git -C "$work" branch -q "$b"
    git -C "$work" push -q "$origin" "$b"
  done
  mkdir -p "$DAEDALUS_HOME/target"
  git clone -q --branch "$1" "$origin" "$DAEDALUS_HOME/target/thing"
  mkdir -p "$DAEDALUS_HOME/vault/.git"
  for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
}

@test "doctor turns red with ONE plain-language line when config target.branch names a branch origin does not have" {
  clone_target_with_default_branch mainline
  doctor_config_with_branch main
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'MISSING  config.yaml says target.branch: main but origin has no branch by that name (its default branch is mainline); fix target.branch in config.yaml')" -eq 1 ]
  # ONE line about the branch — not a MISSING plus a NOTE plus a hint.
  [ "$(printf '%s\n' "$output" | grep -c 'target.branch: main') " -eq 1 ]
  # The same with no origin/HEAD recorded: still red, the default just goes unnamed.
  git -C "$DAEDALUS_HOME/target/thing" symbolic-ref --delete refs/remotes/origin/HEAD
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'MISSING  config.yaml says target.branch: main but origin has no branch by that name; fix target.branch in config.yaml')" -eq 1 ]
}

@test "doctor stays green with a NOTE when target.branch exists at origin but is not its default branch (a deliberate non-default trunk)" {
  # A GitLab target whose default branch is main but whose guarded trunk is
  # mainline: telling the operator to switch config to main would re-inert
  # every branch guard, and a red doctor blocks setup.sh. NOTE, not MISSING.
  clone_target_with_default_branch main mainline
  doctor_config_with_branch mainline
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'NOTE     target.branch: mainline exists at origin but is not its default branch (main)')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'MISSING.*target.branch')" -eq 0 ]
  # No prescription to change config to the default: that is the wrong remedy.
  [ "$(printf '%s\n' "$output" | grep -c 'change config.yaml')" -eq 0 ]
}

@test "doctor: the originating incident shape (config main, origin default mainline, main also at origin) is a NOTE that names both and says the guard covers the default" {
  # The shape sync-target.sh's `git clone --branch main` produced on the
  # deployment that prompted v0.6.1: config says main, origin's default is
  # mainline, and main exists at origin too. From the checkout alone this
  # is indistinguishable from a deliberately non-default trunk, so doctor
  # stays green with a NOTE (a red doctor would block setup.sh on the
  # legitimate shape). What makes that safe is the branch guard: it denies
  # pushes and commits to the remote default as well as the configured
  # trunk (test_guard_bash.bats), and the NOTE says so.
  clone_target_with_default_branch mainline main
  doctor_config_with_branch main
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'NOTE     target.branch: main exists at origin but is not its default branch (mainline)')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'the branch guard denies pushes and commits to mainline as well')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'MISSING.*target.branch')" -eq 0 ]
}

@test "doctor is green when config target.branch matches the target's default branch" {
  clone_target_with_default_branch mainline
  doctor_config_with_branch mainline
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'OK       target.branch: mainline is the target'"'"'s default branch')" -eq 1 ]
}

@test "doctor says 'cannot tell' rather than guessing when the branch exists but the target records no origin/HEAD, and stays green" {
  clone_target_with_default_branch mainline
  git -C "$DAEDALUS_HOME/target/thing" symbolic-ref --delete refs/remotes/origin/HEAD
  doctor_config_with_branch mainline
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'NOTE     target.branch: mainline exists at origin; cannot tell')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'MISSING.*target.branch')" -eq 0 ]
}

# --- Leases (spec §15, plan-1 rows) -------------------------------------------
# The default fixture copies neither leaselib.py nor a real target repo, so the
# leases block is skipped there (guard: core/leaselib.py present) and the older
# green-path tests stay green. These tests add both.
doctor_leases_fixture() {
  cp "$SRC/leaselib.py" "$DAEDALUS_HOME/core/"
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
  T="$DAEDALUS_HOME/target/thing"; git init -q -b main "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q --bare "$BATS_TEST_TMPDIR/o.git"; git -C "$T" remote add origin "$BATS_TEST_TMPDIR/o.git"; git -C "$T" push -q -u origin main; git -C "$T" remote set-head origin main
  mkdir -p "$DAEDALUS_HOME/vault/.git"; for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$BATS_TEST_TMPDIR/sessions"
  # These tests model an operator shell. Run from inside a Claude Code session
  # (its Bash tool exports CLAUDE_CODE_SESSION_ID and CLAUDE_PID), doctor would
  # instead resolve as an unleased SESSION and fail closed (§4.4) — correct,
  # but not what these cases test. The isolation must not depend on who runs bats.
  unset DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID
}

@test "doctor: missing state/leases and worktrees are MISSING lines naming the fix; present is OK with the live/stale counts" {
  doctor_leases_fixture
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  state/leases/ — start a session (the upgrade runs at SessionStart) or run core/setup.sh"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"MISSING  worktrees/"*) : ;; *) echo "$output"; return 1 ;; esac
  mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees"
  # a genuinely LIVE lease: the bats pid with its real start time (proc_started 1 would read as a re-used pid -> stale)
  ms="$(python3 -c 'import subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True).stdout.strip()
print(int(time.mktime(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000))' "$$")"
  printf '{"lease":"01","session_id":"sA","pid":%s,"proc_started":%s}' "$$" "$ms" > "$DAEDALUS_HOME/state/leases/01.json"; touch "$DAEDALUS_HOME/state/leases/01.seen"
  printf '{"lease":"03","session_id":"sC","alias":"electron","pid":1,"proc_started":1}' > "$DAEDALUS_HOME/state/leases/03.json"; touch -t 202001010940 "$DAEDALUS_HOME/state/leases/03.seen"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ]
  case "$output" in *"OK       leases: state/leases/ (1 window live, 1 stale)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     leases: 1 stale — 03 (electron; no live session since"*"run core/lease.sh sweep"*) : ;; *) echo "$output"; return 1 ;; esac
  # ONE live-window count per run. resolve's operator-shell courtesy note counts
  # every unreleased lease ("2 windows live" here, stale 03 included); the leases
  # line counts by liveness. Echoing the note as a NOTE put both in front of the
  # operator three lines apart (Task 18 review). The leases line is the only count.
  case "$output" in *"no session — using the prime's checkout"*) echo "resolve's courtesy note must not be a doctor line: $output"; return 1 ;; esac
  case "$output" in *"windows live)"*) echo "a second live-window count: $output"; return 1 ;; esac
}

@test "doctor: released and finished leases, swept numbers with waiting work, the registry, old shared dedup files — each a NOTE, none turns doctor red" {
  doctor_leases_fixture; mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees"
  printf '{"lease":"02","session_id":"sB","released":"2026-09-25T12:00:00"}' > "$DAEDALUS_HOME/state/leases/02.json"
  printf '{"lease":"04","session_id":"sD","spawned":true,"finished":"2026-09-25T11:42:00","summary":"done"}' > "$DAEDALUS_HOME/state/leases/04.json"
  git -C "$T" branch lease/05; git -C "$T" worktree add -q "$DAEDALUS_HOME/worktrees/05/thing" lease/05
  printf 'w\n' >> "$DAEDALUS_HOME/worktrees/05/thing/a.txt"; git -C "$DAEDALUS_HOME/worktrees/05/thing" -c user.email=t@x -c user.name=t commit -q -am "waiting one"
  printf '{}' > "$DAEDALUS_HOME/state/pitfall-seen.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ]
  case "$output" in *"NOTE     leases: 04 (spawned) FINISHED (promote 04 or release 04); 02 released (swept at next sweep)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     leases: 05 swept with 1 unpromoted commit waiting — say \"this is window 05\" to a window to continue it, or \"delete 05's work\""*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       session registry: "*"sessions/ present (0 entries)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     state/pitfall-seen.json is the pre-v0.7.0 shared file — the upgrade removes it at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  rm -rf "$BATS_TEST_TMPDIR/sessions"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"NOTE     session registry absent — liveness by heartbeat only on this build; peer names unknown; no window numbers itself and nobody takes the pen at start (launch each window with DAEDALUS_LEASE=<NN>; core/lease.sh prime take gives one the pen)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor from an operator shell with leases present runs to the end and reports the target checkout OK" {
  doctor_leases_fixture; mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees"
  printf '{"lease":"01","session_id":"sA","worktree":"worktrees/01"}' > "$DAEDALUS_HOME/state/leases/01.json"
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash '$DAEDALUS_HOME/core/doctor.sh'"
  # With lease files present the path comes from leaselib.py resolve, whose root
  # is realpath'd (verifylib.root_dir) — on macOS the bats tmpdir is under /var,
  # a symlink to /private/var — so compare against the physical path.
  real_home="$(cd "$DAEDALUS_HOME" && pwd -P)"
  case "$output" in *"OK       target checkout: $real_home/target/thing"*"deployment is wired correctly"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"no session — using the prime's checkout"*) echo "resolve's courtesy note must not be a doctor line: $output"; return 1 ;; esac
}

# --- episodic capture: the memory: block (spec §15) -------------------------
doctor_memory_fixture() {
  clone_target_with_default_branch main
  doctor_config_with_branch main
  mkdir -p "$DAEDALUS_HOME/.claude"
  unset TENANT_HOME TENANT_BANK HINDSIGHT_API_URL TRANSCRIPT_DIR CAPTURE_INTERVAL \
        HINDSIGHT_API_TENANT_API_KEY TENANT_USER_LABEL TENANT_ASSISTANT_LABEL
}

@test "doctor: no memory: block is a NOTE — worded for a settings.local.json that still wires capture.py — and doctor stays green" {
  doctor_memory_fixture
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'NOTE     memory: block absent from config.yaml — episodic capture is off (optional; see "Episodic memory capture" in README.md)'*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/capture.py capture"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ]
  case "$output" in *"NOTE     memory: block absent from config.yaml — Stop-cadence capture is off; a SessionEnd capture wired in .claude/settings.local.json still runs"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: a usable memory: block is OK with its bank and interval; a missing transcript directory is a NOTE; a leftover capture line with TENANT_* is a NOTE; doctor stays green" {
  doctor_memory_fixture
  mkdir -p "$BATS_TEST_TMPDIR/tx"
  printf 'memory:\n  bank: testbank\n  capture_interval: 90\n  transcript_dir: %s\n' "$BATS_TEST_TMPDIR/tx" >> "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       memory: bank testbank, capture every 90 s"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"transcript directory"*|*"settings.local.json"*) echo "unexpected note: $output"; return 1 ;; *) : ;; esac
  rmdir "$BATS_TEST_TMPDIR/tx"
  printf '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/capture.py capture"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/recall-inject.py"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ]
  case "$output" in *"NOTE     memory: transcript directory $BATS_TEST_TMPDIR/tx does not exist — set memory.transcript_dir in config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     .claude/settings.local.json still runs capture.py with TENANT_* on its hook line — the memory: block in config.yaml now carries them and the tracked SessionEnd hook flushes; that line can be removed"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: the leftover-capture NOTE judges each hook command alone — a one-line settings.local.json whose TENANT_* prefix belongs to recall-inject.py and whose capture.py line has none is not flagged" {
  doctor_memory_fixture
  printf 'memory:\n  bank: testbank\n' >> "$DAEDALUS_HOME/config.yaml"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/recall-inject.py"}]}],"SessionEnd":[{"hooks":[{"type":"command","command":"python3 core/capture.py capture"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"still runs capture.py with TENANT_*"*) echo "flagged the recall line: $output"; return 1 ;; *) : ;; esac
}

@test "doctor: a memory: block it cannot use is MISSING with the reason — no bank; a key file others can read — even when the operator's shell exports TENANT_BANK" {
  doctor_memory_fixture
  printf 'memory:\n  api_url: http://127.0.0.1:9\n' >> "$DAEDALUS_HOME/config.yaml"
  export TENANT_BANK=fromshell
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  memory: episodic capture needs memory.bank in config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  unset TENANT_BANK
  mkdir -p "$DAEDALUS_HOME/state/hindsight"; printf 'k\n' > "$DAEDALUS_HOME/state/hindsight/api-key"; chmod 644 "$DAEDALUS_HOME/state/hindsight/api-key"
  printf '  bank: b\n  api_key_file: state/hindsight/api-key\n' >> "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  memory: memory.api_key_file state/hindsight/api-key is readable by others (mode 644); run chmod 600 state/hindsight/api-key"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- Promote (spec §15, plan-4 rows) -----------------------------------------
# lease_fixture's target has a nested repo (sub) and bare origins for both; the
# promote block runs only when core/promote.py is present, so every older test
# above (which copies none) is unchanged.
doctor_promote_fixture() {
  lease_fixture
  cp "$SRC/doctor.sh" "$SRC/promote.py" "$SRC/prepush.py" "$SRC/distcheck.py" "$SRC/transcriptlib.py" "$SRC/verify-hook.py" "$DAEDALUS_HOME/core/"
  unset DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDECODE
  D() { bash "$DAEDALUS_HOME/core/doctor.sh"; }
}

# The doctor's problem count after `run D` — lease_fixture already carries
# MISSING lines of its own (vault.repo, the lease directories, …), so a bare
# non-zero status proves nothing about promote's lines: each test takes the
# count in a good state and asserts exactly one more in each bad one.
problems() {
  local n
  n="$(printf '%s\n' "$output" | sed -n 's/.* \([0-9][0-9]*\) problem(s) found.*/\1/p' | tail -1)"
  printf '%s\n' "${n:-0}"
}

@test "doctor: promote.confirm is OK when transcribed (the default) or tty, MISSING — and counted — when anything else" {
  doctor_promote_fixture
  run D; case "$output" in *"OK       promote: the operator's yes is transcribed and checked against the session transcript"*) : ;; *) echo "$output"; return 1 ;; esac
  base="$(problems)"
  printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run D; case "$output" in *"OK       promote: the operator types yes in a terminal (tty)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq "$base" ] || { echo "tty changed the count: $output"; return 1; }
  sed -i '' 's/confirm: tty/confirm: maybe/' "$DAEDALUS_HOME/config.yaml"
  run D; [ "$status" -ne 0 ]; case "$output" in *"MISSING  promote.confirm must be transcribed or tty (got: maybe)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq $((base + 1)) ] || { echo "expected $((base + 1)) problems: $output"; return 1; }
}

@test "doctor: the pre-push hook is MISSING (counted) per repo until installed, OK naming both repos after, NOTE (not counted) when its content differs, MISSING when it is not executable or core.hooksPath is set" {
  doctor_promote_fixture
  run D; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  pre-push hook in target/thing — run core/setup.sh (the trunk is unguarded in git until it is installed)"*"MISSING  pre-push hook in target/thing/sub — run core/setup.sh"*) : ;; *) echo "$output"; return 1 ;; esac
  before="$(problems)"
  python3 "$DAEDALUS_HOME/core/prepush.py" install "$T" "$T/sub" >/dev/null
  run D; case "$output" in *"OK       pre-push hook: target/thing, target/thing/sub"*) : ;; *) echo "$output"; return 1 ;; esac
  base="$(problems)"
  [ "$before" -eq $((base + 2)) ] || { echo "two missing hooks should count two: $before vs $base"; return 1; }
  cp "$T/.git/hooks/pre-push" "$BATS_TEST_TMPDIR/hook.good"
  printf '# edited\n' >> "$T/.git/hooks/pre-push"
  run D; case "$output" in *"NOTE     pre-push hook in target/thing differs from this release's — run core/setup.sh to refresh it"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq "$base" ] || { echo "a content drift is a NOTE, not a problem: $output"; return 1; }
  cp "$BATS_TEST_TMPDIR/hook.good" "$T/.git/hooks/pre-push"; chmod -x "$T/.git/hooks/pre-push"
  run D; case "$output" in *"MISSING  pre-push hook in target/thing is not executable, so git never runs it — run core/setup.sh (the trunk is unguarded in git until it is)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing differs"*) echo "a hook git skips is not a drift: $output"; return 1 ;; esac
  [ "$(problems)" -eq $((base + 1)) ] || { echo "expected $((base + 1)) problems: $output"; return 1; }
  python3 "$DAEDALUS_HOME/core/prepush.py" install "$T" >/dev/null; [ -x "$T/.git/hooks/pre-push" ]
  git -C "$T/sub" config core.hooksPath /tmp/elsewhere
  run D; case "$output" in *"MISSING  target/thing/sub sets core.hooksPath (/tmp/elsewhere), so its pre-push hook never runs"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq $((base + 1)) ] || { echo "expected $((base + 1)) problems: $output"; return 1; }
}

@test "doctor: each repo's trunk is OK by name; a nested repo with no origin/HEAD is MISSING with the remedy, and counted" {
  doctor_promote_fixture
  run D; case "$output" in *"OK       trunk: thing=main, thing/sub=main"*) : ;; *) echo "$output"; return 1 ;; esac
  base="$(problems)"
  git -C "$T/sub" symbolic-ref --delete refs/remotes/origin/HEAD
  run D; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  nested repo sub has no origin/HEAD — run git -C target/thing/sub remote set-head origin -a"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq $((base + 1)) ] || { echo "expected $((base + 1)) problems: $output"; return 1; }
}

# promote_prepared <dir-suffix> <json> — a prepared.json under state/promote/.
promote_prepared() {
  mkdir -p "$DAEDALUS_HOME/state/promote/$1"; printf '%s' "$2" > "$DAEDALUS_HOME/state/promote/$1/prepared.json"
}

@test "doctor: a promotion the window's current occupant prepared and never confirmed is a NOTE (not counted) naming the window and the time; a confirmed one is not" {
  doctor_promote_fixture
  mkdir -p "$DAEDALUS_HOME/state/leases"; printf '{"created":"c1"}' > "$DAEDALUS_HOME/state/leases/02.json"
  run D; base="$(problems)"
  ts="$(python3 -c 'import time; print(time.mktime(time.strptime("2026-09-28 11:31", "%Y-%m-%d %H:%M")))')"
  promote_prepared 02-20260928-113100-abc "{\"lease\":\"02\",\"lease_created\":\"c1\",\"prepared_ts\":$ts,\"prepared_at\":\"x\"}"
  run D; case "$output" in *"NOTE     promote: window 02 prepared at 11:31, not confirmed — say yes to the prime or run promote again"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq "$base" ] || { echo "a prepared promotion is a NOTE, not a problem: $output"; return 1; }
  promote_prepared 02-20260928-113100-abc "{\"lease\":\"02\",\"lease_created\":\"c1\",\"prepared_ts\":$ts,\"prepared_at\":\"x\",\"confirmed_at\":\"y\"}"
  : > "$DAEDALUS_HOME/state/promote/02-20260928-113100-abc/pushed"
  run D; case "$output" in *"window 02 prepared at"*) echo "$output"; return 1 ;; esac
}

@test "doctor: a prepare the review refuted is not offered for a yes — the NOTE says confirm will refuse it and names the two ways on" {
  doctor_promote_fixture
  mkdir -p "$DAEDALUS_HOME/state/leases"; printf '{"created":"c1"}' > "$DAEDALUS_HOME/state/leases/02.json"
  ts="$(python3 -c 'import time; print(time.mktime(time.strptime("2026-09-28 11:31", "%Y-%m-%d %H:%M")))')"
  promote_prepared 02-20260928-113100-abc "{\"lease\":\"02\",\"lease_created\":\"c1\",\"prepared_ts\":$ts,\"prepared_at\":\"x\",\"review\":{\"verdict\":\"REFUTED\"}}"
  run D
  case "$output" in *"say yes to the prime"*) echo "offered a yes confirm refuses: $output"; return 1 ;; esac
  case "$output" in *"NOTE     promote: window 02's last prepare (11:31) was refuted by the review, so it cannot be confirmed — fix the work and run promote 02 again, or promote it without the review with a written reason (promote 02 --skip-review --reason \"...\")"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: prepares from an earlier occupant of the window, or of a window no longer live, are not reported" {
  doctor_promote_fixture
  ts="$(python3 -c 'import time; print(time.time())')"
  promote_prepared 02-20260928-113100-abc "{\"lease\":\"02\",\"lease_created\":\"old\",\"prepared_ts\":$ts,\"prepared_at\":\"x\"}"
  run D; case "$output" in *"promote: window 02"*) echo "a released window's prepare was reported: $output"; return 1 ;; esac
  mkdir -p "$DAEDALUS_HOME/state/leases"; printf '{"created":"new"}' > "$DAEDALUS_HOME/state/leases/02.json"
  run D; case "$output" in *"promote: window 02"*) echo "an earlier occupant's prepare was reported: $output"; return 1 ;; esac
  promote_prepared 02-20260928-120000-def "{\"lease\":\"02\",\"lease_created\":\"new\",\"prepared_ts\":$ts,\"prepared_at\":\"x\"}"
  run D; case "$output" in *"NOTE     promote: window 02 prepared at"*", not confirmed"*) : ;; *) echo "the current occupant's prepare was not reported: $output"; return 1 ;; esac
}
