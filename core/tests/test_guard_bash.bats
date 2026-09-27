#!/usr/bin/env bats
load fixtures/leases/setup.bash
teardown() { teardown_live; }

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/state"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/guard-bash.py" "$DAEDALUS_HOME/core/"
  # the guard imports boundary-hook.py for the cross-lease helpers and leaselib for the leases (Task 11)
  cp "$SRC/leaselib.py" "$SRC/lease.sh" "$SRC/boundary-hook.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(./core/**)","Edit(./CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  printf 'x\n' > "$DAEDALUS_HOME/CLAUDE.md"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
EOF
  T="$DAEDALUS_HOME/target/thing"
  git init -q -b main "$T"; printf 'x\n' > "$T/CLAUDE.md"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q -b main "$DAEDALUS_HOME/vault"; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m i
  export DAEDALUS_HOME
  # Registry isolation: a present, empty session registry, so no hook run from
  # this fixture reads the developer's real ~/.claude/sessions/.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$BATS_TEST_TMPDIR/sessions"
}

guard() {  # guard <command> [cwd]
  local cwd="${2:-$DAEDALUS_HOME}"
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":%s}}' \
    "$cwd" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | python3 "$DAEDALUS_HOME/core/guard-bash.py"
}
guard_as() {  # guard_as <session-id> <command> [cwd] — the hook payload carries the session id (spec §4.2)
  local cwd="${3:-$DAEDALUS_HOME}"
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":%s}}' \
    "$1" "$cwd" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" | python3 "$DAEDALUS_HOME/core/guard-bash.py"
}
denied() { case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "expected deny: $output"; return 1 ;; esac; }
allowed() { [ -z "$output" ]; }

@test "push to main in the target is denied from cwd and via cd; branch push and vault push allowed" {
  run guard 'git push origin main' "$T"; denied
  run guard 'cd target/thing && git push origin main'; denied
  run guard 'git -C target/thing push --force origin fix/x'; denied
  run guard 'git push origin fix/x' "$T"; allowed
  run guard 'git -C vault push origin main'; allowed
}

@test "commit on target main denied unless a branch is created first; a raw vault commit is denied (§4.7)" {
  run guard 'git commit -m x' "$T"; denied
  run guard 'git -C target/thing commit -m x'; denied
  run guard 'git switch -c fix/x && git commit -m x' "$T"; allowed
  run guard 'git checkout -b fix/x && git commit -m x' "$T"; allowed
  run guard 'git -C vault commit -m x'; denied
  git -C "$T" switch -q -c fix/y
  run guard 'git commit -m x' "$T"; allowed
}

@test "destructive git denied; branch -D allowed" {
  run guard 'git reset --hard HEAD~1' "$T"; denied
  run guard 'git checkout -- .' "$T"; denied
  run guard 'git stash drop' "$T"; denied
  run guard 'git branch -D fix/old' "$T"; allowed
}

@test "writes to protected paths denied, including bash -c; target's same-named file allowed; reads allowed" {
  run guard 'sed -i "" s/a/b/ core/lib.sh'; denied
  run guard 'echo x > CLAUDE.md'; denied
  run guard 'bash -c "echo x > core/lib.sh"'; denied
  run guard 'cd target/thing && sed -i "" s/a/b/ ../../CLAUDE.md'; denied
  run guard 'python3 -c "open(\"core/lib.sh\",\"w\").write(\"x\")"'; denied
  run guard 'sed -i "" s/a/b/ CLAUDE.md' "$T"; allowed
  run guard 'cd target/thing && sed -i "" s/a/b/ CLAUDE.md'; allowed
  run guard 'cat core/lib.sh > /tmp/x'; allowed
  run guard 'python3 -c "open(\"core/lib.sh\").read()"'; allowed
  run guard 'grep -i x core/lib.sh'; allowed
  run guard 'sed -i "" s/a/b/ state/session-s1.json'; denied
  run guard 'rm state/session-s1.json'; denied
  run guard 'unlink state/session-s1.json'; denied
  run guard 'rm target/thing/scratch.txt'; allowed
}

@test "a heredoc with an apostrophe mentioning CLAUDE.md is allowed; one redirecting into it is denied" {
  run guard "cat <<'EOF'
the target's CLAUDE.md says hello
EOF"; allowed
  run guard "cat > CLAUDE.md <<'EOF'
it's replaced
EOF"; denied
}

# --- The configured trunk (v0.6.1) ------------------------------------------
# A GitLab deployment whose trunk is `mainline` had a guard that denied `main`
# and let `mainline` through — the strings were hardcoded. The guard now reads
# config target.branch through verifylib.target_branch, the same reader the
# promotion gate uses since PROP-019.

use_mainline() {
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF2'
target:
  repo: https://example.com/thing.git
  branch: mainline
EOF2
  git -C "$T" branch -m main mainline
}

@test "trunk from config: pushing mainline is denied in every refspec shape, and the message names mainline" {
  use_mainline
  run guard 'git push origin mainline' "$T"; denied; case "$output" in *"not mainline"*) : ;; *) echo "message must name the configured trunk: $output"; return 1 ;; esac
  run guard 'git push origin HEAD:mainline' "$T"; denied
  run guard 'git push origin feature:mainline' "$T"; denied
  run guard 'git push -u origin mainline' "$T"; denied
  run guard 'git push --set-upstream origin mainline' "$T"; denied
  run guard 'git push origin +fix/x:refs/heads/mainline' "$T"; denied
  run guard 'cd target/thing && git push origin mainline'; denied
  run guard 'git -C target/thing push origin mainline'; denied
  # A refspec naming the current commit pushes the current branch — the most
  # common idiom after a bare branch name, and it was allowed on the trunk.
  run guard 'git push origin HEAD' "$T"; denied
  run guard 'git push -u origin HEAD' "$T"; denied
  run guard 'git push origin @' "$T"; denied
  # Every-branch pushes carry the trunk whatever is checked out.
  run guard 'git push --all origin' "$T"; denied
  run guard 'git push --mirror origin' "$T"; denied
  # The matching refspec `:` (and `+:`) pushes every branch that already
  # exists at the remote — the trunk among them — without naming any.
  run guard 'git push origin :' "$T"; denied; case "$output" in *"mainline"*) : ;; *) echo "message must name the trunk: $output"; return 1 ;; esac
  run guard 'git push origin +:' "$T"; denied
  # main and master stay denied under a mainline config (defense in depth).
  run guard 'git push origin main' "$T"; denied
  run guard 'git push origin master' "$T"; denied
  run guard 'git push origin HEAD:master' "$T"; denied
}

@test "trunk from config: pushing a feature branch is allowed, in every refspec shape" {
  use_mainline
  run guard 'git push origin fix/x' "$T"; allowed
  run guard 'git push -u origin fix/x' "$T"; allowed
  run guard 'git push --set-upstream origin fix/x' "$T"; allowed
  run guard 'git push origin HEAD:fix/x' "$T"; allowed
  run guard 'git push origin fix/x:fix/x' "$T"; allowed
  run guard 'git push origin fix/x:refs/heads/fix/x' "$T"; allowed
  run guard 'git push -o ci.skip origin fix/x' "$T"; allowed
  # A branch whose name merely CONTAINS the trunk's name is not the trunk.
  run guard 'git push origin fix/mainline-guard' "$T"; allowed
  run guard 'git push origin feature/main' "$T"; allowed
  # HEAD / @ resolve to the checked-out branch: allowed once that is a feature branch.
  git -C "$T" switch -q -c fix/y
  run guard 'git push origin HEAD' "$T"; allowed
  run guard 'git push -u origin HEAD' "$T"; allowed
  run guard 'git push origin @' "$T"; allowed
  # ...but --all/--mirror still push mainline from here.
  run guard 'git push --all origin' "$T"; denied
  run guard 'git push --mirror origin' "$T"; denied
  # ...and so does the matching refspec: measured with a bare origin, `git
  # push origin :` from fix/y moved origin's mainline to the local one.
  run guard 'git push origin :' "$T"; denied
  run guard 'git push origin +:' "$T"; denied
  # Positive control: an explicit source with an empty destination is the
  # same-named branch (git itself rejects the spelling), not an everything-push.
  run guard 'git push origin fix/y:' "$T"; allowed
}

@test "trunk from config: a forced push is denied whatever the branch" {
  use_mainline
  run guard 'git push --force origin fix/x' "$T"; denied
  run guard 'git push -f origin fix/x' "$T"; denied
  run guard 'git push --force-with-lease origin fix/x' "$T"; denied
}

@test "trunk from config: a bare git push is denied while on mainline and allowed from a feature branch" {
  use_mainline
  run guard 'git push' "$T"; denied
  git -C "$T" switch -q -c fix/y
  run guard 'git push' "$T"; allowed
}

@test "trunk from config: committing on mainline is denied and names the branch; a branch created first is allowed" {
  use_mainline
  run guard 'git commit -m x' "$T"; denied; case "$output" in *"on mainline"*) : ;; *) echo "message must name the branch: $output"; return 1 ;; esac
  run guard 'git -C target/thing commit -m x'; denied
  run guard 'git switch -c fix/x && git commit -m x' "$T"; allowed
  # A branch created and then left before the commit earns no credit.
  run guard 'git switch -c fix/x && git switch mainline && git commit -m x' "$T"; denied
  run guard 'git checkout -b fix/x && git checkout mainline && git commit -m x' "$T"; denied
  # `-` is the previous branch — the trunk, right after `switch -c` — and the
  # most common spelling of going back; `--detach` leaves the new branch too.
  run guard 'git switch -c fix/x && git switch - && git commit -m x' "$T"; denied
  run guard 'git switch -c fix/x && git checkout - && git commit -m x' "$T"; denied
  run guard 'git checkout -b fix/x && git checkout - && git commit -m x' "$T"; denied
  run guard 'git switch -c fix/x && git switch --detach && git commit -m x' "$T"; denied
  run guard 'git checkout -b fix/x && git checkout --detach && git commit -m x' "$T"; denied
  git -C "$T" switch -q -c fix/y
  run guard 'git commit -m x' "$T"; allowed
}

@test "trunk from config: an unreadable config fails CLOSED for push and commit inside target/, and only there" {
  use_mainline
  chmod 000 "$DAEDALUS_HOME/config.yaml"
  run guard 'git push origin mainline' "$T"; denied; case "$output" in *"config.yaml cannot be read"*) : ;; *) echo "message must name the cause: $output"; return 1 ;; esac
  run guard 'git push origin fix/x' "$T"; denied
  run guard 'git commit -m x' "$T"; denied
  run guard 'git -C vault commit -m x'; denied
  run guard 'git -C vault push origin main'; allowed
  chmod 644 "$DAEDALUS_HOME/config.yaml"
  run guard 'git push origin fix/x' "$T"; allowed
}

@test "trunk from config: the remote's default branch is denied too — the incident shape (config main, origin default mainline) cannot push or commit mainline" {
  # Config says main, origin's default is mainline, and main exists at
  # origin as well — the shape `git clone --branch main` produced on the
  # deployment that prompted v0.6.1. Doctor can only NOTE it (a deliberate
  # non-default trunk looks the same), so the guard reads
  # refs/remotes/origin/HEAD and denies the default branch alongside the
  # configured one. Before this, `git push origin HEAD:mainline` was allowed.
  rm -rf "$T"
  O="$BATS_TEST_TMPDIR/origin.git"; W="$BATS_TEST_TMPDIR/work"
  git init -q --bare -b mainline "$O"; git init -q -b mainline "$W"
  printf 'x\n' > "$W/README.md"; git -C "$W" add -A; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m i
  git -C "$W" push -q "$O" mainline; git -C "$W" branch -q main; git -C "$W" push -q "$O" main
  git clone -q --branch main "$O" "$T"      # exactly as core/sync-target.sh clones
  run guard 'git push origin HEAD:mainline' "$T"; denied; case "$output" in *"not mainline"*) : ;; *) echo "message must name mainline: $output"; return 1 ;; esac
  run guard 'git push origin mainline' "$T"; denied
  run guard 'git push origin fix/x:refs/heads/mainline' "$T"; denied
  run guard 'git push origin main' "$T"; denied
  run guard 'git push origin fix/x' "$T"; allowed
  git -C "$T" switch -q mainline
  run guard 'git commit -m x' "$T"; denied; case "$output" in *"on mainline"*) : ;; *) echo "message must name the branch: $output"; return 1 ;; esac
  run guard 'git push' "$T"; denied
  git -C "$T" switch -q -c fix/y
  run guard 'git commit -m x' "$T"; allowed
  run guard 'git push origin HEAD' "$T"; allowed
  # With no origin/HEAD recorded there is no default to add: the configured
  # names alone apply, and a feature branch is still free.
  git -C "$T" symbolic-ref --delete refs/remotes/origin/HEAD
  run guard 'git push origin fix/x' "$T"; allowed
  run guard 'git push origin main' "$T"; denied
}

@test "trunk from config: with target.branch unset the trunk is main; main and master stay denied as defense in depth" {
  printf 'target:\n  repo: https://example.com/thing.git\n' > "$DAEDALUS_HOME/config.yaml"
  run guard 'git push origin main' "$T"; denied
  run guard 'git push origin HEAD:main' "$T"; denied
  run guard 'git push origin master' "$T"; denied
  run guard 'git push origin fix/x' "$T"; allowed
  git -C "$T" branch -m main master
  run guard 'git commit -m x' "$T"; denied
}

@test "a prefix that strips a session variable is denied: env -u, env -i, unset, VAR= (spec §4.4 step 4)" {
  for c in 'env -u CLAUDE_CODE_SESSION_ID git status' 'env -i bash -c ls' 'unset CLAUDECODE; ls' 'CLAUDE_PID= ls' 'DAEDALUS_SESSION_ID="" ls'; do
    run guard "$c" "$T"; denied; case "$output" in *"scripts learn which session runs them from these variables; do not strip them"*) : ;; *) echo "wrong reason for '$c': $output"; return 1 ;; esac
  done
  run guard 'env FOO=1 ls' "$T"; allowed
  run guard 'CLAUDE_CODE_USE_BEDROCK=1 ls' "$T"; allowed
}

@test "a bound session whose lease resolution is refused cannot push or commit trunk from its worktree or the target, and the denial names the real reason (spec §4.4 tri-state: not-known fails closed)" {
  # The in-process read of state/leases/ binds sA cleanly; only the bash seam
  # sees the bad override. Before the fix that Refused was dropped to
  # target=None: the push from the worktree went through, and the one from
  # target/ was denied with the "config.yaml cannot be read" sentence.
  lease_fixture
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  CLAUDE_CODE_SESSION_ID=sA bash "$DAEDALUS_HOME/core/lease.sh" claim 01 >/dev/null
  W="$DAEDALUS_HOME/worktrees/01/thing"; [ -d "$W" ]
  run guard_as sA 'git push origin HEAD:feat/x' "$W"; allowed
  export DAEDALUS_TARGET_OVERRIDE=/tmp
  for cwd in "$W" "$T"; do
    for c in 'git push origin HEAD:main' 'git commit -m x'; do
      run guard_as sA "$c" "$cwd"; denied
      case "$output" in *'`DAEDALUS_TARGET_OVERRIDE` must point under state/promote/'*) : ;; *) echo "wrong reason for '$c' in $cwd: $output"; return 1 ;; esac
      case "$output" in *"config.yaml cannot be read"*) echo "misleading reason for '$c' in $cwd: $output"; return 1 ;; *) : ;; esac
    done
    run guard_as sA 'git status' "$cwd"; allowed
  done
  unset DAEDALUS_TARGET_OVERRIDE
}

# --- Bash write operands, other windows' worktrees, the vault rules (spec §4.6, §4.7, §3.1; Task 11) ---
# guard_as is defined above (Task 9). The lease fixture is what gives target/thing an origin/<trunk>
# ref for `lease.sh create` to cut worktrees from; it re-homes DAEDALUS_HOME (pwd -P) and T.

guard_leases() {   # 01=sA prime (live), 02=sB (live, changed hooks/capture.py)
  lease_fixture
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null; bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  for p in 01:sA 02:sB; do nn="${p%%:*}"; s="${p##*:}"; pid="$(live_pid)"; registry_entry "$pid" "$s" interactive cli "daedalus-$nn"
    env CLAUDE_CODE_SESSION_ID="$s" bash "$DAEDALUS_HOME/core/lease.sh" claim "$nn" >/dev/null; done
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  printf '{"thing":{"hooks/capture.py":"2026-09-25T10:31:04"}}' > "$DAEDALUS_HOME/state/leases/02.changed"
}

@test "Bash write to a path in another lease's changed set: first denied with the warning, second allowed with context; the same commands under the session's own untouched paths allowed" {
  guard_leases; W="$DAEDALUS_HOME/worktrees/01/thing"
  run guard_as sA 'echo x > hooks/capture.py' "$W"; denied; case "$output" in *"changed in window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA 'echo x > hooks/capture.py' "$W"; case "$output" in *'"permissionDecision"'*) echo "second must pass: $output"; return 1 ;; *"window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA 'sed -i "" s/a/b/ hooks/capture.py' "$W"; case "$output" in *'"permissionDecision"'*) echo "$output"; return 1 ;; *) : ;; esac
  run guard_as sA 'echo x > a.txt' "$W"; allowed
}

@test "a Bash write into the prime's checkout is denied for every window; git worktree remove of another window's worktree is denied; an unbindable session's trunk push is denied" {
  guard_leases
  run guard_as sA 'echo x > a.txt' "$T"; denied; case "$output" in *"This is the prime's checkout (target/thing). Your work goes in worktrees/01/thing."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'cp x a.txt' "$T"; denied
  run guard_as sB 'git -C target/thing worktree remove worktrees/01'; denied; case "$output" in *"window 01's worktree"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'rm -rf worktrees/01/thing/a.txt'; denied
  run guard_as sZ 'git push origin HEAD:main' "$T"; denied; case "$output" in *"cannot tell which tree is mine"*) : ;; *) echo "$output"; return 1 ;; esac
  # a released window's OWN worktree is closed to its Bash tool too (§4.2 "edits under it are denied")
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["released"]="2026-09-25T12:00:00"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run guard_as sB 'echo x > a.txt' "$DAEDALUS_HOME/worktrees/02/thing"; denied; case "$output" in *"this window is released; its worktree is closed"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "vault: git add / commit / commit -a / stash under vault/ denied from every session naming core/vault-commit.sh — a non-prime's commit or push also names the prime's window number; a write to vault/hot.md denied for a non-prime with the prime's window number; allowed for the prime" {
  guard_leases
  for c in 'git add -A' 'git commit -m x' 'git commit -am x' 'git stash'; do
    run guard_as sA "$c" "$DAEDALUS_HOME/vault"; denied; case "$output" in *"The vault is committed by \`core/vault-commit.sh\`, which checks every claim first"*) : ;; *) echo "'$c': $output"; return 1 ;; esac
    case "$output" in *"pen is held by"*) echo "the prime is not told about the pen: $output"; return 1 ;; *) : ;; esac
    run guard_as sB "$c" "$DAEDALUS_HOME/vault"; denied; done
  run guard_as sB 'git commit -m x' "$DAEDALUS_HOME/vault"; denied
  case "$output" in *"You are window 02; the pen is held by window 01"*"core/vault-commit.sh"*) : ;; *) echo "non-prime commit must name the prime's window: $output"; return 1 ;; esac
  run guard_as sB 'git push origin main' "$DAEDALUS_HOME/vault"; denied; case "$output" in *"You are window 02; the pen is held by window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'echo x > hot.md' "$DAEDALUS_HOME/vault"; denied; case "$output" in *"Only the prime window commits the vault and writes hot.md"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA 'git push origin main' "$DAEDALUS_HOME/vault"; allowed
  run guard_as sA 'echo x > hot.md' "$DAEDALUS_HOME/vault"; allowed
  run guard_as sB 'echo x > proposals/PROP-9.md' "$DAEDALUS_HOME/vault"; allowed
}

@test "with no lease files the vault rules still deny raw commits (every session), and nothing else changes" {
  run guard 'git -C vault commit -m x'; denied
  run guard 'git -C vault push origin main'; allowed
}

@test "a semicolon with no space before it, and a newline, separate commands the way && does: trunk push, vault commit and cd target/thing; ... are all denied; a quoted semicolon does not split" {
  # shlex.split keeps a glued `;` on the word (`vault;`), so `cd vault; git commit -m x` was one cd segment
  # and the git command was never examined — every rule in the guard was bypassed by the commonest spelling.
  run guard 'cd target/thing; git push origin main'; denied
  run guard 'cd target/thing;git push origin main'; denied
  run guard 'cd vault; git commit -m x'; denied; case "$output" in *"core/vault-commit.sh"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard 'cd vault; git add -A; git commit -m x'; denied
  run guard "cd target/thing
git push origin main"; denied
  run guard 'true; git commit -m x' "$T"; denied
  run guard 'git switch -c fix/x; git commit -m x' "$T"; allowed
  run guard 'true; git push origin fix/x' "$T"; allowed
  run guard 'echo "cd vault; git commit -m x" > /tmp/x' "$T"; allowed
  run guard 'git commit -m "a; b"' "$T"; denied
  guard_leases
  run guard_as sB 'cd vault; git push origin main'; denied; case "$output" in *"pen is held by window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'cd vault; echo x > hot.md'; denied
  run guard_as sB 'cd worktrees/02/thing; git worktree remove ../../01/thing'; denied
  run guard_as sA 'cd worktrees/01/thing; echo x > hooks/capture.py'; denied; case "$output" in *"changed in window 02"*) : ;; *) echo "$output"; return 1 ;; esac
}
