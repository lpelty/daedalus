#!/usr/bin/env bats

load fixtures/leases/setup.bash
load fixtures/ami/setup.bash

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
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
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
  mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees" "$DAEDALUS_HOME/state/promote" "$DAEDALUS_HOME/state/direct-calls"
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
  doctor_leases_fixture; mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees" "$DAEDALUS_HOME/state/promote" "$DAEDALUS_HOME/state/direct-calls"
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
  doctor_leases_fixture; mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees" "$DAEDALUS_HOME/state/promote" "$DAEDALUS_HOME/state/direct-calls"
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

@test "doctor names every problem in one run: a nested repo with no origin/HEAD does not hide the outer trunk ahead of origin" {
  doctor_promote_fixture
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"; printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  printf 'b\n' > "$T/b.txt"; git -C "$T" add b.txt; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m ahead
  git -C "$T/sub" remote set-head origin -d
  run D; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  nested repo sub has no origin/HEAD — run git -C target/thing/sub remote set-head origin -a"*) : ;; *) echo "nested row: $output"; return 1 ;; esac
  case "$output" in *"MISSING  target/thing main is 1 commit ahead of origin/main — trunk is reached only through promote; run core/lease.sh adopt main to move the commit to a window"*) : ;; *) echo "outer row dropped: $output"; return 1 ;; esac
  case "$output" in *"target/thing/sub"*"ahead of origin"*|*"target/thing/sub is on"*) echo "a row for the repo whose trunk cannot be told: $output"; return 1 ;; esac
}

# promote_prepared <dir-suffix> <json> — a prepared.json under state/promote/.
promote_prepared() {
  mkdir -p "$DAEDALUS_HOME/state/promote/$1"; printf '%s' "$2" > "$DAEDALUS_HOME/state/promote/$1/prepared.json"
}

@test "doctor: a promotion the window's current occupant prepared and never confirmed is a NOTE (not counted) naming the window and the time; a confirmed one is not" {
  doctor_promote_fixture
  mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/state/promote"; printf '{"created":"c1"}' > "$DAEDALUS_HOME/state/leases/02.json"
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

# ---- Plan 4 completeness critic, finding 4 (A12): transcript-shape drift is seen before a promotion ----

@test "doctor: this Claude Code build's transcript shape — NOTE (not counted) with no interactive transcript yet; OK naming the build when the newest interactive transcript of this deployment reads as the tested one; MISSING (counted), with the sentence, when its typed turns carry no origin or its entries do not link; a headless (sdk) transcript is not the measure; no line in tty mode (critic finding 4)" {
  doctor_promote_fixture
  B="$BATS_TEST_DIRNAME/fixtures/transcripts/build.py"
  X="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(cd "$DAEDALUS_HOME" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$X"
  run D; case "$output" in *"NOTE     promote: no interactive session transcript of this deployment yet, so this Claude Code build's transcript shape is not measured"*) : ;; *) echo "$output"; return 1 ;; esac
  base="$(problems)"
  python3 "$B" "$X/s1.jsonl" operator "hello" >/dev/null; python3 "$B" "$X/s1.jsonl" assistant "hi" >/dev/null
  run D; case "$output" in *"OK       promote: this Claude Code build's transcript shape (2.1.282) reads as the one Daedalus was tested against"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq "$base" ] || { echo "OK changed the count: $output"; return 1; }
  # a newer headless transcript (an sdk call: no origin by design) is not the measure
  python3 - "$B" "$X/s0.jsonl" <<'PY'
import json, subprocess, sys
subprocess.run(["python3", sys.argv[1], sys.argv[2], "no-origin", "Reply with OK"], check=True, capture_output=True)
rows = [json.loads(l) for l in open(sys.argv[2])]
rows[0].update(entrypoint="sdk-cli", promptSource="sdk")
open(sys.argv[2], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
  touch -t 203001010000 "$X/s0.jsonl"
  run D; case "$output" in *"OK       promote: this Claude Code build's transcript shape"*) : ;; *) echo "sdk: $output"; return 1 ;; esac
  # the drift the critic measured on 2.1.283: typed turns with no origin field
  python3 "$B" "$X/s2.jsonl" no-origin "hello again" >/dev/null; python3 "$B" "$X/s2.jsonl" assistant "hi" >/dev/null
  touch -t 203101010000 "$X/s2.jsonl"
  run D; case "$output" in *"MISSING  promote: this Claude Code build's transcript shape is not the one Daedalus was tested against; promote confirm will refuse until the fixture is refreshed — see core/tests/fixtures/transcripts/PROVENANCE.md ("*"no origin field"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq $((base + 1)) ] || { echo "expected $((base + 1)) problems: $output"; return 1; }
  # entries that do not link the way Claude Code writes them
  rm -f "$X/s2.jsonl"; python3 "$B" "$X/s3.jsonl" operator "x" >/dev/null
  python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; r[1]["parentUuid"]="nowhere"; open(sys.argv[1],"w").write("".join(json.dumps(x)+"\n" for x in r))' "$X/s3.jsonl"
  touch -t 203201010000 "$X/s3.jsonl"
  run D; case "$output" in *"MISSING  promote: this Claude Code build's transcript shape is not the one Daedalus was tested against"*"do not link"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run D; case "$output" in *"transcript shape"*) echo "tty mode reads no transcript: $output"; return 1 ;; esac
}

@test "doctor: VERSION is an OK line naming the release; absent, empty or not a version it is MISSING and counted (spec §14, §15)" {
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
  for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       version: 0.7.0"*) : ;; *) echo "$output"; return 1 ;; esac
  for bad in absent empty v0.7 seven; do
    case "$bad" in
      absent) rm -f "$DAEDALUS_HOME/VERSION" ;;
      empty) : > "$DAEDALUS_HOME/VERSION" ;;
      *) printf '%s\n' "$bad" > "$DAEDALUS_HOME/VERSION" ;;
    esac
    run bash "$DAEDALUS_HOME/core/doctor.sh"
    [ "$status" -ne 0 ] || { echo "$bad: doctor stayed green: $output"; return 1; }
    case "$output" in
      *"MISSING  VERSION — this checkout predates v0.7.0 (pull the release) or is corrupt"*"1 problem(s) found"*) : ;;
      *) echo "$bad: $output"; return 1 ;;
    esac
  done
}

# --- the rows plan 5 adds (spec §14, §15) --------------------------------------
# The registry test starts a live sleep; teardown kills it even when an assertion fails first (a leaked
# sleep 300 holds bats at the end of the file — fixtures/leases/setup.bash).
teardown() { teardown_live; }

doctor_upgrade_fixture() {
  doctor_leases_fixture
  cp "$SRC/upgrade.py" "$SRC/prepush.py" "$DAEDALUS_HOME/core/"
  mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees" "$DAEDALUS_HOME/state/promote" "$DAEDALUS_HOME/state/direct-calls"
}

@test "doctor: state/promote/ and state/direct-calls/ absent are MISSING, one line each, naming the fix; present, nothing" {
  doctor_upgrade_fixture
  rmdir "$DAEDALUS_HOME/state/promote" "$DAEDALUS_HOME/state/direct-calls"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  for d in state/promote state/direct-calls; do
    case "$output" in *"MISSING  $d/ — start a session (the upgrade runs at SessionStart) or run core/setup.sh"*) : ;; *) echo "$d: $output"; return 1 ;; esac
  done
  mkdir -p "$DAEDALUS_HOME/state/promote" "$DAEDALUS_HOME/state/direct-calls"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "doctor: the upgrade stamp — NOTE while it has not run, NOTE with the stop sentence when it stopped, OK naming the release when done; no line without VERSION" {
  doctor_upgrade_fixture
  rm -f "$DAEDALUS_HOME/VERSION"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"upgrade"*"state/upgraded-to"*|*"upgrade to "*) echo "a line without VERSION: $output"; return 1 ;; esac
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     upgrade to 0.7.0 has not run yet — it runs at the next session start in this home"*) : ;; *) echo "$output"; return 1 ;; esac
  s="upgrade to 0.7.0 incomplete: target/thing has uncommitted changes — commit them on their branch inside that checkout, then start a session again"
  python3 -c 'import json,sys; json.dump({"version": "0.7.0", "step": 6, "sentence": sys.argv[2]}, open(sys.argv[1], "w"))' "$DAEDALUS_HOME/state/upgrade-stopped.json" "$s"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     $s"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       upgrade: state/upgraded-to 0.7.0"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: target/ off its trunk — a branch with work is a NOTE naming the upgrade's stop and 'pick it up' (or adopt once it has run); a trunk ahead of origin is MISSING and counted; work already on trunk says it goes back; hot.md's session: is a NOTE until the upgrade" {
  doctor_upgrade_fixture
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  mkdir -p "$DAEDALUS_HOME/vault"; printf -- '---\ntype: rolling-state\nsession: 011\n---\n' > "$DAEDALUS_HOME/vault/hot.md"
  git -C "$T" checkout -q -b feat/example; printf 'e\n' > "$T/e.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m example
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"NOTE     target/thing is on feat/example, 1 commit past origin/main — the upgrade stops on it until it is picked up (core/lease.sh adopt --all-unfinished, or core/lease.sh adopt feat/example)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     vault/hot.md still carries session: — the upgrade renames it to leases: at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"NOTE     target/thing is on feat/example, 1 commit past origin/main — run core/lease.sh adopt feat/example to turn it into a window"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     vault/hot.md still carries session: — rename it to leases: in the prime's next vault commit"*) : ;; *) echo "stamped hot.md: $output"; return 1 ;; esac
  git -C "$T" checkout -q main; git -C "$T" merge -q --ff-only feat/example
  run bash "$DAEDALUS_HOME/core/doctor.sh"; base="$(problems)"
  case "$output" in *"MISSING  target/thing main is 1 commit ahead of origin/main — trunk is reached only through promote; run core/lease.sh adopt main to move the commit to a window"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/state/upgraded-to"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"MISSING  target/thing main is 1 commit ahead of origin/main — trunk is reached only through promote; the upgrade stops on the commit until it is picked up (core/lease.sh adopt --all-unfinished)"*) : ;; *) echo "pending: $output"; return 1 ;; esac
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  git -C "$T" push -q origin main
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$(problems)" -eq $((base - 1)) ] || { echo "not counted: $base -> $(problems): $output"; return 1; }
  git -C "$T" checkout -q feat/example
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"NOTE     target/thing is on feat/example, whose commits are already on origin/main — put it back with git -C target/thing checkout main"*) : ;; *) echo "$output"; return 1 ;; esac
  # the good cases: on its trunk at origin, and hot.md carrying leases:, say nothing
  git -C "$T" checkout -q main
  printf -- '---\ntype: rolling-state\nleases: (see the board)\n---\n' > "$DAEDALUS_HOME/vault/hot.md"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"target/thing is on"*|*"ahead of origin"*|*"hot.md still carries"*) echo "a line for a good state: $output"; return 1 ;; esac
}

@test "doctor: from a session the registry line names this session's kind and entrypoint; from a shell it counts the entries" {
  doctor_upgrade_fixture
  p="$(live_pid)"; registry_entry "$p" sR interactive cli daedalus-01
  run env CLAUDE_CODE_SESSION_ID=sR bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"OK       session registry: this session is kind=interactive entrypoint=cli"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"OK       session registry: "*"sessions/ present (1 entries)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: with a usable memory: block, a recall-inject.py line that still carries TENANT_* is a NOTE saying its prefixes can go; a bare one is not" {
  doctor_memory_fixture
  printf 'memory:\n  bank: testbank\n' >> "$DAEDALUS_HOME/config.yaml"
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/recall-inject.py"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     .claude/settings.local.json still runs recall-inject.py with TENANT_* on its hook line — it reads the memory: block in config.yaml now; that line's prefixes can be removed"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"python3 core/recall-inject.py"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"still runs recall-inject.py"*) echo "$output"; return 1 ;; esac
  # A block recall could not use (MISSING already) never says the prefixes can go: they are what still works.
  printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/recall-inject.py"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  printf '  capture_interval: 0\n' >> "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"MISSING"*"memory: memory.capture_interval"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"still runs recall-inject.py"*) echo "$output"; return 1 ;; esac
}

# Critic finding 5: config.yaml is the operator's (the agent's Edit of it is denied, a write trips the Stop check), so
# the lines a release needs there are shown by doctor as one paste — exact where the answer is known, a <...> with its
# question where only the operator knows it, and never an invented grant.
@test "doctor: the config.yaml lines only the operator writes are one paste — release_note exact when update_command says a promote is a release, a question otherwise; callers never invented; refute_model on a cloud provider; pasted at the end, they are read and the note is gone (critic finding 5)" {
  doctor_upgrade_fixture
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX
  note="NOTE     config.yaml lacks lines only the operator may write (the agent may not edit config.yaml) — one paste: add the lines below to the end of config.yaml, replace each <...> with your answer, then start a new session"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
  paste="$(printf '%s\n' "$output" | grep -v '^daedalus: ')"
  [ "$paste" = "promote:
  # true if this target's users receive its trunk through an update command (a promote is then a release), false if not
  release_note: <true or false>
  # the command this target's users run to receive its trunk; leave this line out if release_note is false
  update_command: '<the update command>'
direct_call:
  # the agents allowed to ask this Daedalus a question, comma separated; leave these two lines out to allow none
  callers: <agent names>" ] || { echo "$output"; return 1; }
  printf 'promote:\n  update_command: '"'"'thing update'"'"'\n' >> "$DAEDALUS_HOME/config.yaml"
  run env CLAUDE_CODE_USE_BEDROCK=1 bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  paste="$(printf '%s\n' "$output" | grep -v '^daedalus: ')"
  [ "$paste" = "promote:
  # a promote here is a release: update_command is set
  release_note: true
direct_call:
  # the agents allowed to ask this Daedalus a question, comma separated; leave these two lines out to allow none
  callers: <agent names>
verify:
  # the model id the reviewer runs on with this provider; the charter's short name may not resolve here
  refute_model: <your provider's model id>" ] || { echo "$output"; return 1; }
  # the paste, answered, at the end of a config.yaml that already has a promote: block (update_command, above)
  printf '%s\n' "$paste" | sed -e 's/<agent names>/caller-a/' -e "s/<your provider's model id>/provider-model/" >> "$DAEDALUS_HOME/config.yaml"
  for kv in promote.release_note=true promote.update_command="thing update" direct_call.callers=caller-a verify.refute_model=provider-model; do
    [ "$(bash -c 'source "$1/core/lib.sh"; cfg "$2"' _ "$DAEDALUS_HOME" "${kv%%=*}")" = "${kv#*=}" ] || { echo "cfg ${kv%%=*}"; return 1; }
  done
  run env CLAUDE_CODE_USE_BEDROCK=1 bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"lacks lines only the operator"*) echo "$output"; return 1 ;; esac
  # a <...> left unanswered is still missing
  sed -i.bak 's/^  callers: caller-a$/  callers: <agent names>/' "$DAEDALUS_HOME/config.yaml"; rm -f "$DAEDALUS_HOME/config.yaml.bak"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  case "$output" in *"$note"*"  callers: <agent names>"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- the registry's shape (lease-board spec §5) ----------------------------------------------------------------
# ~/.claude/sessions/<pid>.json is undocumented; on 2026-10-10 startedAt changed meaning and every window read dead with
# nothing in doctor saying so. The check judges only this home's live window entries (a lease names the session, or
# its cwd is this home) and is a NOTE, never MISSING: liveness has a fallback for each field it names.
@test "doctor: registry shape — OK naming the seven fields when every live window entry carries them and procStart parses; a NOTE naming the entry, its window and the field when procStart is missing or does not parse" {
  doctor_upgrade_fixture
  p="$(live_pid)"; ms="$(ps_ms "$p")"
  printf '{"lease":"01","session_id":"sR","pid":%s,"proc_started":%s}' "$p" "$ms" > "$DAEDALUS_HOME/state/leases/01.json"; touch "$DAEDALUS_HOME/state/leases/01.seen"
  registry_entry "$p" sR interactive cli daedalus-01 "" "$(utc_lstart "$ms")"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       registry shape: 1 live window entry carries pid, sessionId, startedAt, procStart, kind, entrypoint, name; procStart parses"*) : ;; *) echo "$output"; return 1 ;; esac
  registry_entry "$p" sR interactive cli daedalus-01                     # the fixture default: no procStart (2.1.282)
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) lacks procStart — liveness falls back to startedAt for it"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       registry shape"*) echo "an OK beside the NOTE: $output"; return 1 ;; *) : ;; esac
  registry_entry "$p" sR interactive cli daedalus-01 "" "Oct 10 14:48:45"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) has procStart \"Oct 10 14:48:45\" that does not parse as \"%a %b %d %H:%M:%S %Y\" UTC — liveness falls back to startedAt for it"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: registry shape — an entry lacking kind and entrypoint is one NOTE naming both; a live entry of another project (cwd elsewhere, no lease names it) is not judged; one whose cwd is this home is; a file that is not JSON is counted" {
  doctor_upgrade_fixture
  p="$(live_pid)"; ms="$(ps_ms "$p")"
  printf '{"lease":"01","session_id":"sR","pid":%s,"proc_started":%s}' "$p" "$ms" > "$DAEDALUS_HOME/state/leases/01.json"; touch "$DAEDALUS_HOME/state/leases/01.seen"
  printf '{"pid":%s,"sessionId":"sR","startedAt":%s,"procStart":"%s","name":"daedalus-01"}\n' "$p" "$ms" "$(utc_lstart "$ms")" > "$BATS_TEST_TMPDIR/sessions/$p.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) lacks kind, entrypoint — this session cannot be told from a headless one; it will not number itself or take the pen"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/state/leases/01.json" "$BATS_TEST_TMPDIR/sessions/$p.json"
  q="$(live_pid)"; registry_entry "$q" sQ
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["cwd"]=sys.argv[2]; json.dump(d, open(p, "w"))' "$BATS_TEST_TMPDIR/sessions/$q.json" "/elsewhere/project"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       registry shape: no live window entries to check"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["cwd"]=sys.argv[2]; json.dump(d, open(p, "w"))' "$BATS_TEST_TMPDIR/sessions/$q.json" "$DAEDALUS_HOME"
  printf 'not json\n' > "$BATS_TEST_TMPDIR/sessions/123.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$q.json lacks procStart — liveness falls back to startedAt for it"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     registry shape: 1 registry file is not JSON (sessions/123.json)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: registry shape — an absent registry is a NOTE naming the path, beside the existing absent-registry NOTE; doctor stays green" {
  doctor_upgrade_fixture
  rm -rf "$BATS_TEST_TMPDIR/sessions"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: $BATS_TEST_TMPDIR/sessions is absent — nothing to check"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     session registry absent — liveness by heartbeat only on this build"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: registry shape — a live pid that fails the recorded-process test is judged, not skipped: startedAt in seconds (the 2026-10-10 class) is a NOTE naming the values and that its window reads dead; so is a complete entry whose procStart is an hour off; an entry whose pid key is gone lacks pid; one with neither startedAt nor procStart names both; a dead left-behind pid is skipped (review 2026-10-11, finding 1)" {
  doctor_upgrade_fixture
  p="$(live_pid)"; ms="$(ps_ms "$p")"
  # the lease's own recorded pid is dead, so liveness(01) is decided by the registry entry for sR
  printf '{"lease":"01","session_id":"sR","pid":1,"proc_started":1}' > "$DAEDALUS_HOME/state/leases/01.json"; touch "$DAEDALUS_HOME/state/leases/01.seen"
  # six fields, startedAt in SECONDS, no procStart: pid_is_recorded_process fails and the window reads dead
  secs=$((ms / 1000))
  registry_entry "$p" sR interactive cli daedalus-01 "$secs"
  [ "$(python3 "$DAEDALUS_HOME/core/leaselib.py" liveness 01)" = "stale" ]
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) lacks procStart — liveness falls back to startedAt for it; and is a live pid that fails the recorded-process test (startedAt=$secs, procStart=null) — the registry may have changed meaning, or its process ended and the pid was reused; its window reads dead"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"no live window entries to check"*) echo "skipped as unjudged: $output"; return 1 ;; *) : ;; esac
  # all seven fields and procStart parses, but it is an hour off (the string in local time, say): the standalone NOTE
  off="$(utc_lstart $((ms - 3600000)))"
  registry_entry "$p" sR interactive cli daedalus-01 "$ms" "$off"
  [ "$(python3 "$DAEDALUS_HOME/core/leaselib.py" liveness 01)" = "stale" ]
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) is a live pid that fails the recorded-process test (startedAt=$ms, procStart=\"$off\") — the registry may have changed meaning, or its process ended and the pid was reused; its window reads dead"*) : ;; *) echo "$output"; return 1 ;; esac
  # the pid key renamed: the entry is this home's (a lease names its session) and lacks pid
  printf '{"processId":%s,"sessionId":"sR","startedAt":%s,"kind":"interactive","entrypoint":"cli","name":"daedalus-01"}\n' "$p" "$ms" > "$BATS_TEST_TMPDIR/sessions/$p.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) lacks pid, procStart — "*"liveness cannot check its process"*) : ;; *) echo "$output"; return 1 ;; esac
  # neither startedAt nor procStart, pid live and named by the lease: one NOTE naming both, and that it reads dead
  printf '{"pid":%s,"sessionId":"sR","kind":"interactive","entrypoint":"cli","name":"daedalus-01"}\n' "$p" > "$BATS_TEST_TMPDIR/sessions/$p.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: sessions/$p.json (window 01) lacks startedAt, procStart — "*"; and is a live pid that fails the recorded-process test (startedAt=null, procStart=null)"*) : ;; *) echo "$output"; return 1 ;; esac
  # a left-behind entry whose pid is DEAD is an ended session's file: skipped, as before
  printf '{"pid":1999999,"sessionId":"sR","startedAt":%s,"kind":"interactive","entrypoint":"cli","name":"daedalus-01"}\n' "$ms" > "$BATS_TEST_TMPDIR/sessions/$p.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       registry shape: no live window entries to check"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: registry shape — a registry directory that cannot be read is a NOTE naming the directory and the error, not an OK with nothing to check (review 2026-10-11, finding 7)" {
  doctor_upgrade_fixture
  chmod 000 "$BATS_TEST_TMPDIR/sessions"
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  chmod 755 "$BATS_TEST_TMPDIR/sessions"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     registry shape: $BATS_TEST_TMPDIR/sessions cannot be read (Permission denied) — liveness has no registry on this build"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       registry shape"*) echo "an OK beside the NOTE: $output"; return 1 ;; *) : ;; esac
}

# --- the lease board on screen (lease-board spec §5.3) ---------------------------------------------------------
# The band above the prompt is a mod each deployment installs once, at local scope, so the absolute path lands in
# the gitignored .claude/settings.local.json. doctor says whether this deployment has done that. NOTE, never
# MISSING: the deployment works without the band; the model-facing board is unchanged.
@test "doctor: lease board on screen — NOTE naming the two install commands while .claude/settings.local.json does not enable lease-board@daedalus-mods; OK when it does; a disabled entry is a NOTE naming the enable command; doctor stays green" {
  doctor_upgrade_fixture
  note='NOTE     lease board on screen: not installed for this deployment — run `claude plugin marketplace add ./mods --scope local` then `claude plugin install lease-board@daedalus-mods --scope local` in the Daedalus home, then open a new terminal'
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
  mkdir -p "$DAEDALUS_HOME/.claude"
  printf '{"enabledPlugins":{"other@elsewhere":true}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"extraKnownMarketplaces":{"daedalus-mods":{"source":{"source":"directory","path":"%s/mods"}}},"enabledPlugins":{"lease-board@daedalus-mods":true}}\n' "$DAEDALUS_HOME" > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       lease board on screen: lease-board@daedalus-mods is enabled in .claude/settings.local.json"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     lease board on screen: not installed"*) echo "a NOTE beside the OK: $output"; return 1 ;; *) : ;; esac
  printf '{"enabledPlugins":{"lease-board@daedalus-mods":false}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'NOTE     lease board on screen: lease-board@daedalus-mods is disabled in .claude/settings.local.json — `claude plugin enable lease-board@daedalus-mods --scope local` turns it back on'*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'not json\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: lease board on screen — a plugin enabled at user scope (~/.claude/settings.json) is OK naming that file, not the not-installed NOTE (review 2026-10-11, finding 14)" {
  doctor_upgrade_fixture
  printf '{"enabledPlugins":{"lease-board@daedalus-mods":true}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       lease board on screen: lease-board@daedalus-mods is enabled in $CLAUDE_CONFIG_DIR/settings.json"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"lease board on screen: not installed"*) echo "a NOTE beside the OK: $output"; return 1 ;; *) : ;; esac
  # local beats user: a local false is the disabled NOTE even with the user-scope true
  mkdir -p "$DAEDALUS_HOME/.claude"; printf '{"enabledPlugins":{"lease-board@daedalus-mods":false}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     lease board on screen: lease-board@daedalus-mods is disabled in .claude/settings.local.json"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: lease board on screen — this machine's one daedalus-mods marketplace record pointing at another checkout's mods/ is a NOTE naming both paths; pointing here, no line (review 2026-10-11, findings 12, 18)" {
  doctor_upgrade_fixture
  export CLAUDE_CODE_PLUGIN_CACHE_DIR="$BATS_TEST_TMPDIR/plugins"; mkdir -p "$CLAUDE_CODE_PLUGIN_CACHE_DIR"
  printf '{"daedalus-mods":{"source":{"source":"directory","path":"/elsewhere/daedalus/mods"},"installLocation":"/elsewhere/daedalus/mods"}}\n' > "$CLAUDE_CODE_PLUGIN_CACHE_DIR/known_marketplaces.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     lease board on screen: this machine's daedalus-mods marketplace points at /elsewhere/daedalus/mods, not $DAEDALUS_HOME/mods — one machine holds one record of that name, so a window here would load the other checkout's board; remove it there (\`claude plugin marketplace remove daedalus-mods\`) before installing here"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"daedalus-mods":{"source":{"source":"directory","path":"%s/mods"},"installLocation":"%s/mods"}}\n' "$DAEDALUS_HOME" "$DAEDALUS_HOME" > "$CLAUDE_CODE_PLUGIN_CACHE_DIR/known_marketplaces.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"marketplace points at"*) echo "a NOTE for a matching record: $output"; return 1 ;; *) : ;; esac
  printf 'not json\n' > "$CLAUDE_CODE_PLUGIN_CACHE_DIR/known_marketplaces.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"marketplace points at"*) echo "a NOTE for an unreadable record: $output"; return 1 ;; *) : ;; esac
}

@test "doctor: lease board on screen — a claude older than 2.1.287 is a NOTE naming the version mods need; a claude that is new enough adds no line; no claude on PATH is a NOTE saying the version was not checked" {
  doctor_upgrade_fixture
  fake="$BATS_TEST_TMPDIR/fakeclaude"; mkdir -p "$fake"
  printf '#!/bin/sh\necho "2.1.282 (Claude Code)"\n' > "$fake/claude"; chmod +x "$fake/claude"
  PATH="$fake:$PATH" run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     lease board on screen: claude 2.1.282 is older than 2.1.287, which mods need — update Claude Code"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '#!/bin/sh\necho "2.1.296 (Claude Code)"\n' > "$fake/claude"
  PATH="$fake:$PATH" run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"lease board on screen: claude 2.1.296"*) echo "a version line for a new-enough claude: $output"; return 1 ;; *) : ;; esac
  # the system paths alone: python3, git, ps and awk are there; claude is not
  PATH=/usr/bin:/bin:/usr/sbin:/sbin run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     lease board on screen: claude is not on PATH here, so its version was not checked (mods need 2.1.287 or later)"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- CLAUDE.md's deny rule and auto mode's classifyAllShell (agent-runnable design 2026-10-15, §4.6) ----------
@test "doctor: CLAUDE.md — OK naming the project file when the tracked Edit(/CLAUDE.md) rule is present; OK naming settings.local.json when only it carries Edit(//<home>/CLAUDE.md); the user file is read through CLAUDE_CONFIG_DIR; a NOTE pointing at daedalus update and the README's brief section when no deny rule in the three files covers it; doctor stays green" {
  doctor_upgrade_fixture
  mkdir -p "$DAEDALUS_HOME/.claude"
  printf '{"permissions":{"deny":["Edit(/core/**)","Edit(/CLAUDE.md)"]}}\n' > "$DAEDALUS_HOME/.claude/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       CLAUDE.md: edits denied (.claude/settings.json)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"CLAUDE.md: no deny rule covers it"*) echo "a NOTE beside the OK: $output"; return 1 ;; *) : ;; esac
  printf '{"permissions":{"deny":["Edit(/core/**)"]}}\n' > "$DAEDALUS_HOME/.claude/settings.json"
  note='NOTE     CLAUDE.md: no deny rule covers it in the settings read (project, local, user) — the release denies it, and local brief text belongs in CLAUDE.local.md; run daedalus update, which puts the rule back and keeps the choice as boundary.edit_brief: true (README, "Letting Daedalus edit its own brief")'
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"permissions":{"deny":["Edit(//%s/CLAUDE.md)"]}}\n' "$DAEDALUS_HOME" > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       CLAUDE.md: edits denied (.claude/settings.local.json)"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/.claude/settings.local.json"
  printf '{"permissions":{"deny":["Edit(CLAUDE.md)"]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       CLAUDE.md: edits denied ($CLAUDE_CONFIG_DIR/settings.json)"*) : ;; *) echo "$output"; return 1 ;; esac
  # a rule for another file, or a file that is not JSON, covers nothing
  printf '{"permissions":{"deny":["Edit(/SOUL.md)"]}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'not json\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$note"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: auto mode — a NOTE when the user settings set autoMode.classifyAllShell (the allow rule for core/lease.sh release is suspended, the classifier judges the delete); absent otherwise, and absent when it is set only in the project files the classifier never reads" {
  doctor_upgrade_fixture
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"classifyAllShell"*) echo "a NOTE with nothing set: $output"; return 1 ;; *) : ;; esac
  printf '{"autoMode":{"classifyAllShell":true}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     auto mode: classifyAllShell is set in $CLAUDE_CONFIG_DIR/settings.json, so the allow rule for core/lease.sh release is suspended and the classifier judges the delete (README, \"Windows (leases)\")"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"autoMode":{"classifyAllShell":false}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"classifyAllShell"*) echo "a NOTE for false: $output"; return 1 ;; *) : ;; esac
  rm "$CLAUDE_CONFIG_DIR/settings.json"
  mkdir -p "$DAEDALUS_HOME/.claude"; printf '{"autoMode":{"classifyAllShell":true}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"classifyAllShell"*) echo "a NOTE for a project file the classifier never reads: $output"; return 1 ;; *) : ;; esac
}

@test "the scripts the operator and the agent run by path keep the executable bit in git (mode 100755): doctor.sh, every core/*.sh, guard-bash.py, update.py (the shim runs it), upgrade.py and the headless auto-mode check — a mode change ships to every deployment that pulls" {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  bad=""
  for f in core/*.sh core/guard-bash.py core/update.py core/upgrade.py core/tests/automode-allow-rule.sh; do
    mode="$(git -C "$REPO" ls-files -s -- "$f" | cut -c1-6)"
    [ "$mode" = "100755" ] || bad="$bad $f($mode)"
  done
  [ -z "$bad" ] || { echo "not executable in git:$bad"; return 1; }
}

@test "doctor prints the last automatic index run as a NOTE (from vault-search --check): the finished frame's time, kicker and counts; with no log, that none is recorded yet; doctor stays green" {
  cp "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
  cat > "$DAEDALUS_HOME/q.sh" <<'EOF2'
#!/bin/bash
echo '[]'
EOF2
  chmod +x "$DAEDALUS_HOME/q.sh"
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF2
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
recall:
  vault-query: '$DAEDALUS_HOME/q.sh "\$1"'
  vault-index: 'true'
  store: state/chroma
EOF2
  git init -q "$DAEDALUS_HOME/target/thing"
  mkdir -p "$DAEDALUS_HOME/vault/.git" "$DAEDALUS_HOME/state/chroma"
  for d in infrastructure specs plans proposals pitfalls exchange; do mkdir -p "$DAEDALUS_HOME/vault/$d"; done
  printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  printf 'started 2026-10-15T09:00:00 by vault-commit\nfinished 2026-10-15T09:00:04 indexed=3 purged=1\n' > "$DAEDALUS_HOME/state/recall-index.log"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'NOTE     document recall: last automatic index 2026-10-15T09:00:00 by vault-commit: indexed=3 purged=1')" -eq 1 ]
  rm "$DAEDALUS_HOME/state/recall-index.log"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'NOTE     document recall: no automatic index run recorded yet')" -eq 1 ]
}

# --- update-command design §4.5: the brief, the command, local edits in tracked files, leftover promote scratch ------
@test "doctor: brief — OK naming boundary.edit_brief false and whether CLAUDE.local.md is there; a NOTE when it is true; doctor stays green" {
  doctor_upgrade_fixture
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       brief: boundary.edit_brief false — CLAUDE.local.md is the operator's (absent)"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'local line\n' > "$DAEDALUS_HOME/CLAUDE.local.md"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       brief: boundary.edit_brief false — CLAUDE.local.md is the operator's (present)"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'boundary:\n  edit_brief: true\n' >> "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     brief: boundary.edit_brief true — Daedalus may edit CLAUDE.local.md"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       brief:"*) echo "$output"; return 1 ;; esac
}

@test "doctor: core/update.py --doctor's lines are relayed — a local edit to CLAUDE.md is MISSING and counted, the command's NOTE is shown (scratch HOME and login shell); absent update.py, no line" {
  doctor_upgrade_fixture
  rm -f "$DAEDALUS_HOME/core/update.py"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"tracked files"*|*"     command:"*) echo "$output"; return 1 ;; esac
  cp "$SRC/update.py" "$DAEDALUS_HOME/core/"
  printf 'brief\n' > "$DAEDALUS_HOME/CLAUDE.md"; mkdir -p "$DAEDALUS_HOME/.claude"
  printf '{"permissions":{"deny":["Edit(/CLAUDE.md)"]}}\n' > "$DAEDALUS_HOME/.claude/settings.json"
  printf 'target/\nvault/\nstate/\nworktrees/\nconfig.yaml\n' > "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" init -q -b main; git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m i
  printf 'more\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  S="$BATS_TEST_TMPDIR/scratch-home"; mkdir -p "$S"
  printf '#!/bin/sh\nPATH="/usr/bin:/bin" exec /bin/sh -c "$3"\n' > "$BATS_TEST_TMPDIR/zsh"; chmod +x "$BATS_TEST_TMPDIR/zsh"
  run env -u DAEDALUS_NO_COMMAND HOME="$S" SHELL="$BATS_TEST_TMPDIR/zsh" bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  case "$output" in *"MISSING  local edits in tracked files: CLAUDE.md — run daedalus update, which moves them into the local layer"*"1 problem(s) found"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     command: ~/.local/bin/daedalus is absent; core/setup.sh installs it"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q CLAUDE.md
  run env -u DAEDALUS_NO_COMMAND HOME="$S" SHELL="$BATS_TEST_TMPDIR/zsh" bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       tracked files: CLAUDE.md and .claude/settings.json carry no local edits"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: a pushed promotion that still holds scratch is a NOTE naming it and core/promote.sh NN --clean; records alone, or an unpushed promotion's scratch, are not; doctor stays green" {
  doctor_promote_fixture
  mkdir -p "$DAEDALUS_HOME/state/promote"
  run D; base="$(problems)"
  case "$output" in *"promote scratch"*) echo "$output"; return 1 ;; esac
  promote_prepared 04-20261015-100000-abc '{"lease":"04","confirmed_at":"y"}'
  : > "$DAEDALUS_HOME/state/promote/04-20261015-100000-abc/pushed"
  run D; case "$output" in *"promote scratch"*) echo "records alone: $output"; return 1 ;; esac
  mkdir -p "$DAEDALUS_HOME/state/promote/04-20261015-100000-abc/thing"
  promote_prepared 01-20261015-090000-def '{"lease":"01"}'; mkdir -p "$DAEDALUS_HOME/state/promote/01-20261015-090000-def/thing"
  run D
  case "$output" in *"NOTE     promote scratch: 1 pushed promotion still holds scratch (04-20261015-100000-abc) — core/promote.sh NN --clean removes it (NN its window: 04)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(problems)" -eq "$base" ] || { echo "$output"; return 1; }
}

# --- frame-jack (frame-jack spec §10; plan Task 6) ---------------------------------------------------
# doctor_fj_fixture — the upgrade fixture plus core/frame-jack.py and amilib.py (leaselib.py is already
# there), the ami fixture directory (the fake decider as the command), an empty weights cache, an empty
# prepared ps listing (AMI_TEST_PS), and config.yaml without an ami: block saved as base.yaml.
doctor_fj_fixture() {
  doctor_upgrade_fixture
  cp "$SRC/frame-jack.py" "$SRC/amilib.py" "$DAEDALUS_HOME/core/"
  AMI_FIX="$BATS_TEST_TMPDIR/fix/ami"; mkdir -p "$BATS_TEST_TMPDIR/fix"
  cp -R "$BATS_TEST_DIRNAME/fixtures/ami" "$AMI_FIX"; chmod +x "$AMI_FIX/fake-decider"
  export AMI_FIX
  export AMI_TEST_HF_HOME="$BATS_TEST_TMPDIR/hf"; mkdir -p "$AMI_TEST_HF_HOME/hub"
  : > "$BATS_TEST_TMPDIR/ps.txt"; export AMI_TEST_PS="cat $BATS_TEST_TMPDIR/ps.txt"
  unset CLAUDECODE DAEDALUS_LEASE DAEDALUS_TARGET_OVERRIDE DAEDALUS_PROMOTE_ID DIRECT_CALL_ID HF_HOME
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/base.yaml"
  MODEL=StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
  AMI="$DAEDALUS_HOME/state/ami"
}
# fj_config <port> <device> <offline> [extra yaml line ...] — config.yaml is base.yaml plus an ami: block
fj_config() {
  cp "$BATS_TEST_TMPDIR/base.yaml" "$DAEDALUS_HOME/config.yaml"
  write_ami_config "$1" "$2" "$3"
  shift 3
  for l in "$@"; do printf '  %s\n' "$l" >> "$DAEDALUS_HOME/config.yaml"; done
}
# fj_weights <hub> — both model folders in the huggingface_hub layout: snapshot entries are links into the
# shared blob store hub/blobs/<2hex>/<sha>; the base model's blob is a sparse 2.5 GB file
fj_weights() {
  python3 - "$1" <<'PY'
import os, sys
hub = sys.argv[1]
for name, sha, size in (("models--Qwen--Qwen3.5-2B-Base", "6c" + "a" * 62, 2_500_000_000),
                        ("models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610", "47" + "b" * 62, 1000)):
    blob = os.path.join(hub, "blobs", sha[:2], sha)
    os.makedirs(os.path.dirname(blob), exist_ok=True)
    with open(blob, "wb") as fh:
        fh.seek(size - 1); fh.write(b"\0")
    snap = os.path.join(hub, name, "snapshots", "rev1")
    os.makedirs(snap, exist_ok=True)
    os.makedirs(os.path.join(hub, name, "blobs"), exist_ok=True)
    os.symlink(os.path.relpath(blob, snap), os.path.join(snap, "model.safetensors"))
    open(os.path.join(snap, "config.json"), "w").write("{}")
PY
}
# fj_daemon <json fields> — writes the sentinel and a daemon.json (heartbeat now unless given) for $FJ_PORT
fj_daemon() {
  mkdir -p "$AMI/decisions"
  printf '2026-10-15T09:12:00+0000 session sA\n' > "$AMI/on"
  python3 - "$AMI/daemon.json" "$AMI_FIX/fake-decider" "$MODEL" "$FJ_PORT" "$1" <<'PY'
import json, sys, time
p, cmd, model, port, extra = sys.argv[1:]
d = {"supervisor_pid": None, "leash_pid": None, "serve_pid": None, "borrowed": False, "port": int(port),
     "device": "mlx", "state": "up", "terminal": False, "since": time.time() - 600, "heartbeat": time.time() - 4,
     "ready_ms": 31000, "restarts": 0, "last_error": None, "off_by": None, "command": cmd, "model": model,
     "offline": False, "battery_off": True, "request_timeout_ms": 1500, "questions": {"destructive": True, "suite": True},
     "enforce": []}
for k, v in json.loads(extra).items():
    d[k] = time.time() - v if k == "heartbeat_age" else v
if "heartbeat_age" in d:
    d["heartbeat"] = d.pop("heartbeat_age")
json.dump(d, open(p, "w"))
PY
}

@test "doctor frame-jack: no ami: block is a NOTE naming README; a good block with the fake command is OK; a non-executable command, a bad device and an enforce request are MISSING and counted" {
  doctor_fj_fixture
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'NOTE     frame-jack: no ami: block in config.yaml — the AMI cannot be switched on (optional; see "Frame-jack" in README.md)'*) : ;; *) echo "$output"; return 1 ;; esac
  P="$(free_port)"
  fj_config "$P" mlx true
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack: strands-decider at $AMI_FIX/fake-decider, model $MODEL, device mlx, port $P, offline"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"MISSING  frame-jack"*) echo "a MISSING for a good block: $output"; return 1 ;; *) : ;; esac
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/not-exec"; chmod -x "$BATS_TEST_TMPDIR/not-exec"
  fj_config "$P" mlx false
  sed -i '' "s|^  command: .*|  command: $BATS_TEST_TMPDIR/not-exec|" "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  frame-jack: ami.command $BATS_TEST_TMPDIR/not-exec is not an executable file — install strands-decider into a virtual environment and name its strands-decider here"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"1 problem(s) found"*) : ;; *) echo "not counted: $output"; return 1 ;; esac
  fj_config "$P" cuda false
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  frame-jack: ami.device must be mlx, mps or cpu (got cuda)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       frame-jack: strands-decider at"*) echo "an OK beside a MISSING: $output"; return 1 ;; *) : ;; esac
  fj_config "$P" mlx false "enforce: destructive"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  frame-jack: ami.enforce names destructive, which no release has certified to act — remove it; the question stays in shadow mode"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"1 problem(s) found"*) : ;; *) echo "not counted: $output"; return 1 ;; esac
}

@test "doctor frame-jack weights: both snapshots present is OK with the size; a missing snapshot is a NOTE whose remedy differs by ami.offline; a snapshot whose symlinks point into a missing blob store is the copied-without-blobs NOTE; regular files in blobs/ are OK" {
  doctor_fj_fixture
  P="$(free_port)"; HUB="$AMI_TEST_HF_HOME/hub"
  fj_weights "$HUB"
  fj_config "$P" mlx true
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack weights: both snapshots present (2.50 GB)"*) : ;; *) echo "$output"; return 1 ;; esac
  # the decider's folder gone: offline true says copy by hand only; offline false says the first start may download it
  rm -rf "$HUB/models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack weights: the model snapshot is missing under $HUB (models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610) — copy it by hand (README \"Weights by hand\"); ami.offline is true, so the daemon will not download it"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_config "$P" mlx false
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack weights: the model snapshot is missing under $HUB (models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610) — copy it by hand (README \"Weights by hand\") or let the first start download it (ami.offline is false)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"both snapshots present"*) echo "an OK with one missing: $output"; return 1 ;; *) : ;; esac
  # copied without the blobs: the base model's links point into a store that is not there
  rm -rf "$HUB"; mkdir -p "$HUB"; fj_weights "$HUB"; rm -rf "$HUB/blobs"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'NOTE     frame-jack weights: models--Qwen--Qwen3.5-2B-Base has links into a blob store that is not there — the folders were copied without the blobs; copy with the tarball in README "Weights by hand"'*) : ;; *) echo "$output"; return 1 ;; esac
  # the older layout: regular files in each model's own blobs/, the snapshot links resolving into them
  rm -rf "$HUB"; mkdir -p "$HUB"
  for m in models--Qwen--Qwen3.5-2B-Base models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610; do
    mkdir -p "$HUB/$m/blobs" "$HUB/$m/snapshots/rev1"
    printf 'weights\n' > "$HUB/$m/blobs/abc123"
    ln -s ../../blobs/abc123 "$HUB/$m/snapshots/rev1/model.safetensors"
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack weights: both snapshots present ("*) : ;; *) echo "$output"; return 1 ;; esac
  # ami.weights_cache names the cache: the hub under it is the one read
  WC="$BATS_TEST_TMPDIR/wc"; mkdir -p "$WC/hub"
  fj_config "$P" mlx true "weights_cache: $WC"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"the model snapshot is missing under $WC/hub (models--Qwen--Qwen3.5-2B-Base)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor frame-jack daemon: off; on and up from a prepared daemon.json; down with the last error; down for good naming the snapshot; supervisor gone with the heartbeat age and the serve pid; paused on battery; the port held by something else; a second serve on the machine from a prepared ps listing" {
  doctor_fj_fixture
  start_fake "$MODEL"; FJ_PORT="$FAKE_PORT"
  fj_config "$FJ_PORT" mlx true
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack: off (the sentinel is absent; /frame-jack on starts the AMI)"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"t": 1, "session": "sA"}\n{"t": 2, "session": "sA"}\n{"t": 3, "session": "sB"}\n' > "$BATS_TEST_TMPDIR/rows"
  fj_daemon "{\"serve_pid\": $FAKE_PID}"
  cp "$BATS_TEST_TMPDIR/rows" "$AMI/decisions/$(date +%Y-%m-%d).jsonl"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack: on — daemon up on port $FJ_PORT (serve pid $FAKE_PID, device mlx, supervisor heartbeat "*" s ago), shadow mode, 3 decisions logged today"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_daemon '{"state": "down", "last_error": "serve exited with code 1: boom"}'
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack: on but the daemon is down (last error: serve exited with code 1: boom) — /frame-jack on starts it again"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_daemon '{"state": "down", "terminal": true, "last_error": "the weights are missing (models--Qwen--Qwen3.5-2B-Base) — copy them (README \"Weights by hand\"), then /frame-jack on"}'
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'NOTE     frame-jack: on but the daemon stopped for good: the weights are missing (models--Qwen--Qwen3.5-2B-Base) — copy them (README "Weights by hand"), then /frame-jack on'*) : ;; *) echo "$output"; return 1 ;; esac
  fj_daemon "{\"serve_pid\": $FAKE_PID, \"heartbeat_age\": 365}"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack: on but its supervisor is gone (heartbeat 6 min ago; serve pid $FAKE_PID still running) — /frame-jack off, then on"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_daemon '{"state": "battery"}'
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack: on, paused on battery"*) : ;; *) echo "$output"; return 1 ;; esac
  # the port answers, but not as the AMI: a fake with another checkpoint
  OWN_PID="$FAKE_PID"
  start_fake other/model; FJ_PORT="$FAKE_PORT"
  fj_config "$FJ_PORT" mlx true
  fj_daemon '{}'
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack: port $FJ_PORT is held by something that is not the AMI — change ami.port in config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  # a second serve: the listing holds this deployment's serve (not reported) and another on another port
  printf '%s /venv/bin/python3 %s serve %s --port %s --device mlx\n70012 /venv/bin/python3 /venv/bin/strands-decider serve %s --port 8762 --device mlx\n70013 /bin/zsh -c grep strands-decider serve\n' \
    "$OWN_PID" "$AMI_FIX/fake-decider" "$MODEL" "$FJ_PORT" "$MODEL" > "$BATS_TEST_TMPDIR/ps.txt"
  fj_daemon "{\"serve_pid\": $OWN_PID}"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack: a second strands-decider serve is running on this machine (pid 70012, port 8762, not this deployment's) — two daemons cost twice 5.3 GB; name the same ami.port in both deployments so one borrows the other"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"(pid $OWN_PID,"*|*"(pid 70013,"*) echo "this deployment's serve, or a non-serve line, reported: $output"; return 1 ;; *) : ;; esac
}

@test "doctor: the block is skipped when core/frame-jack.py is absent, so a fixture home without it prints no frame-jack line" {
  doctor_upgrade_fixture
  cat >> "$DAEDALUS_HOME/config.yaml" <<'EOF'
ami:
  command: /nonexistent/strands-decider
  model: StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
  device: cuda
EOF
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"frame-jack"*) echo "a frame-jack line without frame-jack.py: $output"; return 1 ;; *) : ;; esac
  # and with it, the same home reports the block (so the skip is the file, not the block)
  cp "$SRC/frame-jack.py" "$SRC/amilib.py" "$DAEDALUS_HOME/core/"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -ne 0 ]
  case "$output" in *"MISSING  frame-jack: ami.device must be mlx, mps or cpu (got cuda)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor frame-jack questions: no ask_ keys is OK naming suite asked and the destructive question off by default; ask_destructive true names both; both false is a NOTE saying the daemon would hold its memory for nothing; a leftover ami.shadow line is a NOTE saying it is no longer read" {
  doctor_fj_fixture
  P="$(free_port)"
  fj_config "$P" mlx false
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack questions: suite asked; destructive not asked (ami.ask_destructive is false — the default)"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_config "$P" mlx false "ask_destructive: true"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack questions: destructive and suite asked"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_config "$P" mlx false "ask_destructive: false" "ask_suite: false"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack questions: none asked (ami.ask_destructive and ami.ask_suite are both false) — switched on, the daemon would hold about 5.2 GB for nothing; leave frame-jack off"*) : ;; *) echo "$output"; return 1 ;; esac
  fj_config "$P" mlx false "shadow: destructive, suite"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"NOTE     frame-jack: ami.shadow is no longer read — ami.ask_destructive and ami.ask_suite say which questions are asked; remove the shadow line"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor frame-jack device: no device line defaults to mlx on Apple silicon (cpu elsewhere) and the OK line says so; device mps is a NOTE naming the crash two overlapping questions caused and pointing at mlx; device mlx has no such NOTE" {
  doctor_fj_fixture
  P="$(free_port)"
  if [ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ]; then want=mlx; else want=cpu; fi
  fj_config "$P" mlx false
  sed -i '' '/^  device: /d' "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"OK       frame-jack: strands-decider at $AMI_FIX/fake-decider, model $MODEL, device $want, port $P,"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"device mps"*) echo "an mps NOTE without mps: $output"; return 1 ;; *) : ;; esac
  fj_config "$P" mps false
  run bash "$DAEDALUS_HOME/core/doctor.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'NOTE     frame-jack: device mps — two overlapping questions crashed the MPS daemon in the lab (a Metal assertion, twice); MLX queues them, about 27 questions a second in the same 5.2 GB — set ami.device: mlx (README "Frame-jack" installs the mlx extra)'*) : ;; *) echo "$output"; return 1 ;; esac
}
