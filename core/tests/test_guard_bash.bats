#!/usr/bin/env bats
load fixtures/leases/setup.bash
load fixtures/transcripts/setup.bash
load fixtures/ami/setup.bash
teardown() { teardown_live; chmod -R u+w "$DAEDALUS_HOME/state" 2>/dev/null || true; }

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/state"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/guard-bash.py" "$DAEDALUS_HOME/core/"
  # the guard imports boundary-hook.py for the cross-lease helpers and leaselib for the leases (Task 11)
  cp "$SRC/leaselib.py" "$SRC/lease.sh" "$SRC/boundary-hook.py" "$SRC/transcriptlib.py" "$SRC/distcheck.py" "$SRC/update.py" "$DAEDALUS_HOME/core/"
  # the AMI tier (frame-jack spec §6.0): amilib beside the guard; lease-board.py records the operator's message
  cp "$SRC/amilib.py" "$SRC/lease-board.py" "$DAEDALUS_HOME/core/"
  AMI_FIX="$BATS_TEST_TMPDIR/fix/ami"; mkdir -p "$BATS_TEST_TMPDIR/fix"; cp -R "$BATS_TEST_DIRNAME/fixtures/ami" "$AMI_FIX"
  chmod +x "$AMI_FIX/fake-decider" "$AMI_FIX/fake-pmset"; export AMI_FIX
  unset DIRECT_CALL_ID AMI_TEST_DEADLINE_SECS
  printf '{"permissions":{"deny":["Edit(/core/**)","Edit(/CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
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
write_as() {  # write_as <session-id> <abs path> — the Edit/Write leg (boundary-hook.py) on the same fixture
  printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"
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
  run guard 'git push origin mainline' "$T"; denied; case "$output" in *"This push would move mainline. Trunk is reached only through promote."*) : ;; *) echo "message must name the configured trunk: $output"; return 1 ;; esac
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
  run guard 'git push origin HEAD:mainline' "$T"; denied; case "$output" in *"This push would move mainline. Trunk is reached only through promote."*) : ;; *) echo "message must name mainline: $output"; return 1 ;; esac
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
  # `git worktree remove` resolves a relative operand against the `-C` directory, and git tries the operand as a
  # path SUFFIX of every registered worktree before the path it resolves to (worktree.c find_worktree_by_suffix):
  # measured 2026-09-26, `git -C worktrees/01/thing worktree remove 02/thing` removed window 02's worktree.
  run guard_as sB 'git -C worktrees/02/thing worktree remove ../../01/thing'; denied; case "$output" in *"window 01's worktree"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git -C worktrees/02/thing worktree remove --force ../../01/thing'; denied
  run guard_as sB 'git worktree remove 01/thing' "$DAEDALUS_HOME/worktrees/02/thing"; denied; case "$output" in *"window 01's worktree"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git worktree remove ../../02/thing' "$DAEDALUS_HOME/worktrees/02/thing"; allowed   # its own
  run guard_as sB 'rm -rf worktrees/01/thing/a.txt'; denied
  # Ownership is judged from the PATH, not from whether a repository sits under the operand: the directory that
  # holds another window's worktree, worktrees/ itself and target/ itself were allowed while a file inside was denied.
  run guard_as sA 'rm -rf worktrees/02'; denied; case "$output" in *"This is window 02's worktree (worktrees/02). Your work goes in worktrees/01."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA 'rm -rf worktrees/02/'; denied
  run guard_as sA 'rm -rf worktrees'; denied; case "$output" in *"worktrees/ holds every window's worktree"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA 'rm -rf target'; denied; case "$output" in *"This is the prime's checkout (target)."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'rm -rf target/thing'; denied; case "$output" in *"This is the prime's checkout (target/thing)."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'echo x > target/notes.txt'; denied
  run guard_as sA 'rm -rf worktrees/01/scratch'; allowed   # its own window's directory
  # the Edit/Write leg says the same for a directory path (parity)
  run write_as sA "$DAEDALUS_HOME/worktrees/02"; denied; case "$output" in *"This is window 02's worktree (worktrees/02). Your work goes in worktrees/01."*) : ;; *) echo "$output"; return 1 ;; esac
  run write_as sA "$DAEDALUS_HOME/worktrees"; denied
  run write_as sB "$DAEDALUS_HOME/target"; denied; case "$output" in *"This is the prime's checkout (target)."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sZ 'git push origin HEAD:main' "$T"; denied; case "$output" in *"holds no window"*) : ;; *) echo "$output"; return 1 ;; esac
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

@test "a heredoc whose body shlex cannot tokenize (an apostrophe) is checked like a plain redirect: the prime's checkout, hot.md for a non-prime, the stop-once cross-lease warning; a body that only mentions a guarded path is allowed" {
  # Before: the ValueError fallback ran is_protected alone, so every lease-era rule was waved through for
  # one of the most common Bash shapes Claude Code emits.
  guard_leases; W="$DAEDALUS_HOME/worktrees/01/thing"
  run guard_as sB "cat > a.txt <<'EOF2'
it's
EOF2" "$T"; denied; case "$output" in *"This is the prime's checkout (target/thing)."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB "cat > hot.md <<'EOF2'
don't
EOF2" "$DAEDALUS_HOME/vault"; denied; case "$output" in *"Only the prime window commits the vault and writes hot.md"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA "cat > hooks/capture.py <<'EOF2'
it's
EOF2" "$W"; denied; case "$output" in *"changed in window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(k.endswith("hooks/capture.py") for k in d["warned"]), d' "$DAEDALUS_HOME/state/session-sA-boundary.json"
  run guard_as sA "cat > hooks/capture.py <<'EOF2'
it's
EOF2" "$W"; case "$output" in *'"permissionDecision"'*) echo "second must pass: $output"; return 1 ;; *"window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB "cat > hot.md <<'EOF2'
it's
EOF2" "$DAEDALUS_HOME/vault"; denied
  # a `<<-` heredoc, and a heredoc followed by another command on the next line
  run guard_as sB "cat > a.txt <<-EOF2
	it's
	EOF2
echo done" "$T"; denied
  run guard_as sB "cat <<'EOF2'
the prime's checkout target/thing/a.txt and hot.md are mentioned, not written
EOF2" "$T"; allowed
  run guard_as sA "cat > notes.txt <<'EOF2'
it's fine here
EOF2" "$W"; allowed
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

@test "when state/ cannot be written the first cross-lease Bash write and Edit are still denied with the warning, and stderr names the cause" {
  # Before: save_boundary raised, the hook's outer except swallowed it, and the write went through with no
  # output at all — on every attempt, not once. The safe failure is a stop that repeats.
  guard_leases; W="$DAEDALUS_HOME/worktrees/01/thing"
  chmod 500 "$DAEDALUS_HOME/state"
  run guard_as sA 'echo x > hooks/capture.py' "$W"; denied
  case "$output" in *"changed in window 02"*"This first attempt was stopped"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"daedalus: could not record the boundary warning in state/"*"the stop will repeat"*) : ;; *) echo "stderr must name the cause: $output"; return 1 ;; esac
  run guard_as sA 'echo x > hooks/capture.py' "$W"; denied   # repeats, since nothing was recorded
  run write_as sA "$W/hooks/capture.py"; denied   # (bats merges stderr ahead of stdout: two patterns, no order)
  case "$output" in *"changed in window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"daedalus: could not record the boundary warning in state/"*) : ;; *) echo "stderr must name the cause: $output"; return 1 ;; esac
  chmod 755 "$DAEDALUS_HOME/state"
  run guard_as sA 'echo x > hooks/capture.py' "$W"; denied   # first RECORDED stop
  run guard_as sA 'echo x > hooks/capture.py' "$W"; case "$output" in *'"permissionDecision"'*) echo "after the record the second must pass: $output"; return 1 ;; *"window 02"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a Bash write operand under the transcript directory — redirect, sed -i, tee, cp, mv, rm, an unparseable command — is denied by the absolute-path check (not is_protected, which is root-relative); auto memory is not" {
  P="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(cd "$DAEDALUS_HOME" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$P/memory"
  : > "$P/s1.jsonl"
  for c in "echo x >> $P/s1.jsonl" "sed -i '' s/a/b/ $P/s1.jsonl" "tee $P/s1.jsonl" "cp /tmp/x $P/s1.jsonl" \
           "mv $P/s1.jsonl /tmp/gone.jsonl" "rm -f $P/s1.jsonl" "echo it's > $P/s1.jsonl"; do
    run guard "$c"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *"the session transcript is the record of the operator's yes; nothing writes it."*) : ;; *) echo "$c: $output"; return 1 ;; esac
  done
  run guard "echo note >> $P/memory/MEMORY.md"; allowed
  run guard "cat $P/s1.jsonl"; allowed
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import verifylib as v; assert not v.is_protected(Path(sys.argv[2]), Path(sys.argv[3]))' \
    "$DAEDALUS_HOME/core" "$DAEDALUS_HOME" "$P/s1.jsonl"
}

@test "the transcript's parseable write shapes beyond redirect/sed/tee/cp/mv/rm — fd and clobber redirects, an attached redirect, a hard link, rsync, dd, truncate, perl -i, \$HOME and \$CLAUDE_CONFIG_DIR, rm -- of a slug, and removing or recursively copying onto an ancestor of the transcript directory — are denied; ordinary commands near it are not" {
  P="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(cd "$DAEDALUS_HOME" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$P/memory"
  S="${P##*/}"; R="${P#"$CLAUDE_CONFIG_DIR"/}"
  : > "$P/s1.jsonl"; mkdir -p "$BATS_TEST_TMPDIR/fake"
  for c in "echo x 2> $P/s1.jsonl" "echo x 1>> $P/s1.jsonl" "echo x >| $P/s1.jsonl" "echo x &>> $P/s1.jsonl" \
           "echo x>$P/s1.jsonl" "echo x 2>&1 >>$P/s1.jsonl" "ln -f /tmp/forged.jsonl $P/s1.jsonl" \
           "rsync -a $BATS_TEST_TMPDIR/fake/ $P/" "dd if=/tmp/f of=$P/s1.jsonl" "truncate -s 0 $P/s1.jsonl" \
           "perl -pi -e s/a/b/ $P/s1.jsonl" "echo x >> \$CLAUDE_CONFIG_DIR/$R/s1.jsonl" "echo x >> \${CLAUDE_CONFIG_DIR}/$R/s1.jsonl" \
           "cp -R $BATS_TEST_TMPDIR/fake/ $CLAUDE_CONFIG_DIR/projects/" "rsync -a $BATS_TEST_TMPDIR/fake/ $CLAUDE_CONFIG_DIR/projects/" \
           "mv $CLAUDE_CONFIG_DIR/projects /tmp/elsewhere" "rm -rf $CLAUDE_CONFIG_DIR/projects" "rm -rf $CLAUDE_CONFIG_DIR"; do
    run guard "$c"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *"the session transcript is the record of the operator's yes; nothing writes it."*) : ;; *) echo "$c: $output"; return 1 ;; esac
  done
  run guard "rm -rf -- $S" "$CLAUDE_CONFIG_DIR/projects"; denied
  case "$output" in *"nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
  HOME="$BATS_TEST_TMPDIR" run guard "echo x >> \$HOME/$R/s1.jsonl"; denied
  # near misses stay allowed: fd duplication, a quoted arrow, a copy into the home itself, a non-recursive copy, a sibling project
  for c in "echo x 2>&1 | cat" "ls 2>/dev/null" "echo 'a->b'" "cp $BATS_TEST_TMPDIR/fake/x $CLAUDE_CONFIG_DIR/projects/" \
           "rm -rf $CLAUDE_CONFIG_DIR/projects/-some-other-home" "rsync -a $BATS_TEST_TMPDIR/fake/ $BATS_TEST_TMPDIR/elsewhere/" \
           "echo x >> $P/memory/MEMORY.md" "cat $P/s1.jsonl 2>/dev/null"; do
    run guard "$c"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
  HOME="$CLAUDE_CONFIG_DIR" run guard "cp -R $BATS_TEST_TMPDIR/fake/ $CLAUDE_CONFIG_DIR/"; allowed
}

@test "an attached or fd-numbered redirect onto distribution code is a write operand, and cp's destination is found past a trailing redirect" {
  for c in "echo x>core/lib.sh" "echo x 2>core/lib.sh" "cp /tmp/x core/lib.sh 2>/dev/null" "ln -f /tmp/x core/lib.sh"; do
    run guard "$c"; denied || { echo "not denied: $c"; return 1; }
  done
}

# --- Every trunk-reaching git shape (spec §7.3, §11.1; plan 4 Task 13, Decisions 13, 14, 32, 33, 38) ---
# scratch_and_worktree — windows 01 (sA, prime) and 02 (sB) from guard_leases, plus a promote
# scratch worktree of target/thing, detached at main.
scratch_and_worktree() {
  guard_leases
  S="$DAEDALUS_HOME/state/promote/02-20260928-120000-abc/thing"
  git -C "$T" worktree add -q --detach "$S" main
  W1="$DAEDALUS_HOME/worktrees/01/thing"; W2="$DAEDALUS_HOME/worktrees/02/thing"
}

@test "the rewritten trunk messages: a trunk push, a forced push, an everything push, a commit on trunk in the prime's checkout and elsewhere — each says trunk is reached only through promote, never 'the operator merges'" {
  scratch_and_worktree
  run guard_as sB 'git push origin HEAD:main' "$W2"; denied
  case "$output" in *"This push would move main. Trunk is reached only through promote. Commit on your window's branch (lease/02); when it is ready, ask the prime to run promote 02."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git push --force origin lease/02' "$W2"; denied
  # the hook's JSON escapes the em dash (\u2014), so the sentence is matched on either side of it
  case "$output" in *"Trunk is reached only through promote. Commit on your window's branch (lease/02); when it is ready, ask the prime to run promote 02 "*" and never with --force: a forced push rewrites history."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git push --all origin' "$W2"; denied
  case "$output" in *"promote pushes one merge commit; nothing else pushes branches"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git commit -m x' "$T"; denied
  case "$output" in *"You are on main in the prime's checkout. Build in your window's worktree (worktrees/02/thing), not here."*|*"This is the prime's checkout"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git push origin HEAD:main' "$T"; denied
  case "$output" in *"operator merges"*) echo "$output"; return 1 ;; esac
}

@test "every refspec shape from a window's worktree and from the promote scratch: trunk pushes denied from the worktree, every push denied from the scratch as promote's job; --prune, -d and --delete denied everywhere under the home" {
  scratch_and_worktree
  for c in 'git push origin HEAD:main' 'git push origin lease/02:main' 'git push origin +HEAD:refs/heads/main' 'git push origin HEAD:master' 'git push origin :'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied from the worktree: $c"; return 1; }
  done
  run guard_as sB 'git push origin lease/02' "$W2"; allowed
  run guard_as sA 'git push origin HEAD:refs/heads/fix/x' "$S"; denied
  case "$output" in *"Pushes from the promote scratch are promote's job; run \`core/promote.sh <NN> --confirm\`."*) : ;; *) echo "$output"; return 1 ;; esac
  for c in 'git push --prune origin' 'git push -d origin fix/x' 'git push origin --delete fix/x' 'git push --mirror origin' 'git push --branches origin'; do
    for d in "$T" "$W2"; do run guard_as sB "$c" "$d"; denied || { echo "not denied in $d: $c"; return 1; }; done
  done
}

@test "a push reached any other way is the same push: bash -c, eval, \$( ), backticks, an env or VAR= prefix, a git alias from config, -c alias.X=push, a !-alias, and a push inside a python -c string" {
  scratch_and_worktree
  git -C "$W2" config alias.p push
  for c in "bash -c 'git push origin HEAD:main'" "sh -c \"git push origin HEAD:main\"" "eval git push origin HEAD:main" \
           'echo $(git push origin HEAD:main)' 'echo `git push origin HEAD:main`' 'env GIT_TRACE=1 git push origin HEAD:main' \
           'FOO=1 git push origin HEAD:main' 'git p origin HEAD:main' 'git -c alias.q=push q origin HEAD:main' \
           "git -c 'alias.r=!git push' r origin HEAD:main" "python3 -c \"import os; os.system('git push origin main')\""; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sB "bash -c 'git push origin lease/02'" "$W2"; allowed
  run guard_as sB 'git p origin lease/02' "$W2"; allowed
  run guard_as sB 'echo $(git log -1)' "$W2"; allowed
}

@test "unparseable refspecs, --no-verify, core.hooksPath and writes under .git/hooks are denied" {
  scratch_and_worktree
  for c in 'd=main; git push origin HEAD:$d' 'git push origin HEAD:`echo main`' 'git push origin HEAD:{main}'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  # a variable is a word the shell fills in: the git command cannot be read (critic finding 1); a literal brace can
  run guard_as sB 'git push origin HEAD:$d' "$W2"; case "$output" in *"I can't read this git command exactly"*"Write it out literally."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB "git push origin 'HEAD:{main}'" "$W2"; case "$output" in *"name the branch literally"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'git push --no-verify origin lease/02' "$W2"; denied
  run guard_as sB 'git commit --no-verify -m x' "$W2"; denied
  run guard_as sB 'git commit -n -m x' "$W2"; denied
  run guard_as sB 'git -c core.hooksPath=/dev/null push origin lease/02' "$W2"; denied
  run guard_as sB 'git config core.hooksPath /tmp/h' "$W2"; denied
  run guard_as sB "echo x > $T/.git/hooks/pre-push" "$W2"; denied
  case "$output" in *".git/hooks"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB 'rm -f ../../../target/thing/.git/hooks/pre-push' "$W2"; denied
}

@test "distribution code by every git route: in Daedalus's own checkout apply, am, cherry-pick, merge, pull, rebase, stash pop and apply, checkout <rev>, switch <branch> and restore --source are denied; patch < file in core/ is denied; the same verbs in a window's worktree are allowed" {
  scratch_and_worktree
  for c in 'git apply /tmp/x.patch' 'git am /tmp/x.mbox' 'git cherry-pick abc123' 'git merge other' 'git pull' 'git rebase main' \
           'git stash pop' 'git stash apply' 'git checkout abc123' 'git switch other' 'git restore --source=HEAD~1 core/lib.sh'; do
    run guard_as sA "git -C $DAEDALUS_HOME ${c#git }"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *"distribution code; write a proposal"*) : ;; *) echo "$c: $output"; return 1 ;; esac
  done
  run guard_as sA 'patch -p1 < /tmp/x.patch' "$DAEDALUS_HOME/core"; denied
  # plan 4 Decision 14 let a new branch at HEAD through; Task 9 review: `switch -c x <rev>` / `checkout -b x <rev>` move HEAD
  # past the §6.1 record, and a branch here only strands the checkout off the one its release pull follows — refused
  run guard_as sA "git -C $DAEDALUS_HOME switch -c proposal-branch"; denied
  run guard_as sA "git -C $DAEDALUS_HOME checkout -b proposal-branch"; denied
  run guard_as sB 'git rebase origin/main' "$W2"; allowed
  run guard_as sB 'git merge origin/main' "$W2"; allowed
}

@test "worktree removal and pruning under the promote scratch are the prime's: a non-prime window is denied, the prime is not" {
  scratch_and_worktree
  run guard_as sB "git -C $T worktree remove $S"; denied
  run guard_as sB "git -C $T worktree prune"; denied
  run guard_as sA "git -C $T worktree remove $S"; allowed
  run guard_as sA "git -C $T worktree prune"; allowed
}

@test "a prime that took the pen at a vault commit while the upgrade is pending does not remove or prune promote's worktrees until the upgrade finishes" {
  scratch_and_worktree
  printf '9.9.9\n' > "$DAEDALUS_HOME/VERSION"
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[],"taken_while_pending":"9.9.9"}'
  run guard_as sA "git -C $T worktree prune"; denied
  case "$output" in *"waits until the upgrade to 9.9.9 finishes"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA "git -C $T worktree remove $S"; denied
  printf '9.9.9\n' > "$DAEDALUS_HOME/state/upgraded-to"
  run guard_as sA "git -C $T worktree prune"; allowed
}

@test "abbreviated options are the options they abbreviate; update-ref and branch -f on a trunk; every other way to set the hooks path (Decision 33)" {
  scratch_and_worktree
  for c in 'git push --no-veri origin lease/02' 'git push --mirr origin' 'git push --prun origin' 'git push origin --delet fix/x' \
           'git push --forc origin lease/02' 'git push --force-with origin lease/02' 'git push --al origin' 'git commit --no-ver -m x' \
           'git update-ref refs/heads/main HEAD' 'git update-ref main HEAD' 'git update-ref --stdin' 'git branch -f main HEAD~1' \
           'git branch -M other main' 'git --config-env=core.hooksPath=HP push origin lease/02' \
           'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp git push origin lease/02'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sB 'git push --follow-tags origin lease/02' "$W2"; allowed
  run guard_as sB 'git branch -f fix/x HEAD' "$W2"; allowed
  run guard_as sB 'git update-ref refs/heads/fix/x HEAD' "$W2"; allowed
}

@test "a push from outside the home to the target's origin is in scope: a clone elsewhere, GIT_DIR pointed at the target, the origin named by path; a push to an unrelated remote is not (Decision 38)" {
  scratch_and_worktree
  O="$BATS_TEST_TMPDIR/origin.git"; X="$BATS_TEST_TMPDIR/outside"; git clone -q "$O" "$X"
  for c in 'git push origin HEAD:main' "git push $O HEAD:main" 'git push --mirr origin'; do
    run guard_as sB "$c" "$X"; denied || { echo "not denied from outside the home: $c"; return 1; }
  done
  run guard_as sB "GIT_DIR=$T/.git git push origin HEAD:main" "$BATS_TEST_TMPDIR"; denied
  run guard_as sB 'git push origin HEAD:refs/heads/fix/x' "$X"; allowed
  U="$BATS_TEST_TMPDIR/unrelated.git"; git init -q --bare "$U"; git -C "$X" remote add other "$U"
  run guard_as sB 'git push other HEAD:main' "$X"; allowed
}

@test "a program-made terminal cannot type the yes: script, expect, unbuffer, a python pty and the suite's tty helper in front of promote.sh or lease.sh are denied, as is the suite's seam variable anywhere (Decision 32)" {
  scratch_and_worktree
  for c in 'script -q /dev/null bash core/promote.sh 02 --confirm' 'expect -c "spawn core/promote.sh 02 --confirm"' \
           'unbuffer core/lease.sh prime take' "python3 -c 'import pty; pty.spawn([\"core/promote.sh\", \"02\", \"--confirm\"])'" \
           'python3 core/tests/fixtures/tty/type-into.py yes Type -- bash core/promote.sh 02 --confirm' \
           'DAEDALUS_TEST_TTY_ANCESTRY=skip bash core/promote.sh 02 --confirm' 'export DAEDALUS_TEST_TTY_ANCESTRY=skip' \
           'screen -dmS x bash core/promote.sh 02 --confirm' 'screen -S x -X stuff yes' 'tmux send-keys -t x yes Enter' \
           'tmux new -d -s x' '/usr/bin/login -pf someone bash core/promote.sh 02 --confirm'; do
    run guard_as sA "$c" "$DAEDALUS_HOME"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sA 'bash core/promote.sh 02' "$DAEDALUS_HOME"; allowed
  run guard_as sA 'script -q /dev/null ls' "$DAEDALUS_HOME"; allowed
}

# ---- Task 13 review: the shapes that got past the guard, each reproduced first ----

@test "git send-pack and other push plumbing are denied in every repo under the home and toward the target's origin from anywhere — git runs no pre-push hook for them; an unrelated send-pack outside the home is not (Task 13 review)" {
  scratch_and_worktree
  O="$BATS_TEST_TMPDIR/origin.git"; X="$BATS_TEST_TMPDIR/outside"; git clone -q "$O" "$X"
  for c in 'git send-pack ../../../../origin.git lease/02:refs/heads/main' "git send-pack $O lease/02:refs/heads/fix/x" \
           'git http-push https://example.com/thing.git main' "git-send-pack $O HEAD:refs/heads/main" \
           "/usr/libexec/git-core/git-send-pack $O HEAD:refs/heads/main" 'git remote-ext "git-receive-pack origin.git" x'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied in the home: $c"; return 1; }
  done
  case "$output" in *"pre-push hook"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB "git send-pack $O HEAD:refs/heads/main" "$X"; denied
  U="$BATS_TEST_TMPDIR/unrelated.git"; git init -q --bare "$U"
  run guard_as sB "git send-pack $U HEAD:refs/heads/main" "$X"; allowed
  # why the guard must: git runs a refusing pre-push hook for `git push`, never for `git send-pack`
  P="$BATS_TEST_TMPDIR/plain"; B="$BATS_TEST_TMPDIR/plain.git"; git init -q --bare -b main "$B"; git clone -q "$B" "$P" 2>/dev/null
  git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m a
  printf '#!/bin/sh\nexit 1\n' > "$P/.git/hooks/pre-push"; chmod +x "$P/.git/hooks/pre-push"
  run git -C "$P" push -q origin HEAD:main; [ "$status" -ne 0 ]
  run git -C "$P" send-pack "$B" HEAD:refs/heads/main; [ "$status" -eq 0 ]
  [ "$(git -C "$B" rev-parse main)" = "$(git -C "$P" rev-parse HEAD)" ]
}

@test "the trunk-push rule holds through ordinary shell shapes: a path to git, ( ), { }, if/then, !, prefix commands (sudo, nice, timeout, watch, xargs, find -exec), shell options before -c, a shell reading its script from a pipe or here-string, a function body, and --git-dir/--work-tree/--namespace in their space forms (Task 13 review)" {
  scratch_and_worktree
  for c in '/usr/bin/git push origin HEAD:main' '(git push origin HEAD:main)' '{ git push origin HEAD:main; }' \
           'if true; then git push origin HEAD:main; fi' '! git push origin HEAD:main' 'sudo git push origin HEAD:main' \
           'nice git push origin HEAD:main' 'nice -n 5 git push origin HEAD:main' 'timeout 5 git push origin HEAD:main' \
           'watch git push origin HEAD:main' "watch -n 1 'git push origin HEAD:main'" 'xargs git push origin <<< HEAD:main' \
           'echo HEAD:main | xargs git push origin' 'find . -maxdepth 0 -exec git push origin HEAD:main \;' \
           'bash -o errexit -c "git push origin HEAD:main"' 'sudo bash -c "git push origin HEAD:main"' \
           "echo 'git push origin HEAD:main' | bash" "bash <<< 'git push origin HEAD:main'" \
           'f() { git push origin HEAD:main; }; f' 'while true; do git push origin HEAD:main; done' \
           'git --git-dir ../../../target/thing/.git push origin HEAD:main' \
           'git --git-dir ../../../target/thing/.git --work-tree ../../../target/thing commit -m x' \
           'git --namespace x push origin HEAD:main' 'sudo env GIT_DIR=../../../target/thing/.git git commit -m x'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  for c in 'nice git push origin lease/02' 'sudo git status' 'echo git push origin HEAD:main' '(git status)' \
           'if true; then git log -1; fi' 'find . -name x -exec grep y {} \;' 'timeout 5 git fetch origin' \
           'bash -o errexit -c "git push origin lease/02"' 'git --git-dir .git status'; do
    run guard_as sB "$c" "$W2"; allowed || { echo "not allowed: $c"; return 1; }
  done
}

@test "chmod, chown and touch are writes: switching off or re-owning the pre-push hook or the hooks directory is denied; chmod elsewhere is not (Task 13 review)" {
  scratch_and_worktree
  [ -x "$T/.git/hooks/pre-push" ]
  for c in "chmod -x $T/.git/hooks/pre-push" 'chmod 000 ../../../target/thing/.git/hooks' 'chmod -R a-x ../../../target/thing/.git/hooks' \
           'chown nobody ../../../target/thing/.git/hooks/pre-push' 'touch ../../../target/thing/.git/hooks/post-checkout'; do
    run guard_as sA "$c" "$W1"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *".git/hooks"*) : ;; *) echo "$c: $output"; return 1 ;; esac
  done
  run guard_as sA 'chmod +x build.sh' "$W1"; allowed
  run guard_as sA 'chmod 755 build.sh' "$W1"; allowed
}

@test "a push to the target's origin from outside the home is judged by repository, not spelling: the path without .git, file://, a trailing slash, an insteadOf rewrite; ssh and https spellings of one network origin are one origin (Task 13 review)" {
  scratch_and_worktree
  O="$BATS_TEST_TMPDIR/origin.git"; X="$BATS_TEST_TMPDIR/outside"; git clone -q "$O" "$X"
  for c in "git push ${O%.git} HEAD:main" "git push file://$O HEAD:main" "git push $O/ HEAD:main" \
           "git -c url.$O.insteadOf=zz: push zz: HEAD:main" "git -c remote.other.url=$O push other HEAD:main"; do
    run guard_as sB "$c" "$X"; denied || { echo "not denied: $c"; return 1; }
  done
  git -C "$T" remote set-url --push origin git@github.com:acme/thing.git
  for u in https://github.com/acme/thing ssh://git@github.com/acme/thing.git git@github.com:acme/thing \
           https://user@GitHub.com/acme/thing.git/ ssh://git@github.com:22/acme/thing; do
    run guard_as sB "git push $u HEAD:main" "$X"; denied || { echo "not denied: $u"; return 1; }
  done
  run guard_as sB 'git push https://github.com/acme/other HEAD:main' "$X"; allowed
}

@test "a command that makes the guard fail is denied whole, never waved through: an empty alias before a trunk push (Task 13 review)" {
  scratch_and_worktree
  run guard_as sB "git -c 'alias.x= ' x; git push origin HEAD:main" "$W2"; denied
  run guard_as sB "git -c 'alias.x= ' x; git status" "$W2"; allowed
  # any error inside a segment, and any error the whole check raises, is a denial naming what could not be checked
  run python3 -c '
import importlib.util, io, json, sys
from pathlib import Path
home, cwd = sys.argv[1], sys.argv[2]
sys.path.insert(0, home + "/core")
spec = importlib.util.spec_from_file_location("gb", home + "/core/guard-bash.py")
gb = importlib.util.module_from_spec(spec); spec.loader.exec_module(gb)
def boom(*a, **k): raise IndexError("forced")
real = gb.check_git
gb.check_git = boom
g = gb.G(Path(home), gb.v._empty_lease_context(), Path(home) / "target" / "thing", "", "sB")
print("segment:", gb.check_command("git status", Path(cwd), g)[0])
gb.check_git, gb.check_command = real, boom
sys.stdin = io.StringIO(json.dumps({"session_id": "sB", "cwd": cwd, "tool_input": {"command": "git status"}}))
gb.main()
' "$DAEDALUS_HOME" "$W2"
  case "$output" in *"segment: The guard could not check this command (it failed on \`git status\`)"*'"permissionDecision": "deny"'*"could not check this command"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the hooks path by the global and include routes: GIT_CONFIG_GLOBAL/SYSTEM and the other GIT_CONFIG_* variables, -c include.path and includeIf, git config include*, and writes to ~/.gitconfig, ~/.config/git/config and a repo's .git/config — by Bash and by Edit|Write; GIT_CONFIG_NOSYSTEM, which can only remove configuration, is not (Task 13 review)" {
  scratch_and_worktree
  for c in "echo '[core] hooksPath=/tmp' >> ~/.gitconfig" 'GIT_CONFIG_GLOBAL=/tmp/g git push origin lease/02' \
           'GIT_CONFIG_SYSTEM=/tmp/g git status' 'export GIT_CONFIG_GLOBAL=/tmp/g' 'GIT_CONFIG_PARAMETERS="x" git status' \
           'git -c include.path=/tmp/inc push origin lease/02' 'git -c includeIf.gitdir:/.path=/tmp/inc push origin lease/02' \
           'git config --global include.path /tmp/inc' 'git config --global includeIf.onbranch:x.path /tmp/inc' \
           'echo x >> ../../../vault/.git/config' "sed -i '' s/a/b/ ~/.config/git/config" 'cp /tmp/c ../../../target/thing/.git/config'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  for p in "$HOME/.gitconfig" "$HOME/.config/git/config" "$DAEDALUS_HOME/vault/.git/config" "$DAEDALUS_HOME/vault/.git/hooks/pre-push"; do
    run write_as sA "$p"; denied || { echo "Edit|Write not denied: $p"; return 1; }
  done
  run guard_as sB 'GIT_CONFIG_NOSYSTEM=1 git status' "$W2"; allowed
  run guard_as sB 'git config user.name x' "$W2"; allowed
}

@test "a trunk push whose destination comes from config or git's name matching is the same push: remote.<name>.push by -c or already set, remote.<name>.mirror, push.default upstream or matching over the window's tracking, heads/<trunk>; git config and branch -u aiming at a trunk are denied (Task 13 review)" {
  scratch_and_worktree
  [ "$(git -C "$W2" config branch.lease/02.merge)" = refs/heads/main ]    # lease worktrees track the trunk
  for c in 'git -c remote.origin.push=HEAD:refs/heads/main push origin' 'git -c remote.origin.push=HEAD:refs/heads/main push origin lease/02' \
           'git -c remote.origin.push=HEAD:refs/heads/main push' 'git config remote.origin.push HEAD:refs/heads/main' \
           'git config --add remote.origin.push +refs/heads/lease/02:refs/heads/main' 'git config branch.lease/02.merge refs/heads/main' \
           'git -c push.default=upstream push' 'git -c push.default=tracking push origin' 'git -c push.default=matching push' \
           'git -c remote.origin.mirror=true push origin' 'git branch -u origin/main' 'git branch --set-upstream-to=origin/main' \
           'git branch --set-upstream-to origin/master lease/02' 'git push origin HEAD:heads/main' 'git push origin lease/02:heads/main' \
           "git --config-env=remote.origin.push=PUSHSPEC push origin" 'git -c url.x.pushInsteadOf=y push y HEAD:fix'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  git -C "$W2" config remote.origin.push HEAD:refs/heads/main
  for c in 'git push' 'git push origin' 'git push origin lease/02'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied with remote.origin.push set: $c"; return 1; }
  done
  git -C "$W2" config --unset remote.origin.push
  git -C "$W2" config push.default upstream
  run guard_as sB 'git push' "$W2"; denied
  git -C "$W2" config --unset push.default
  for c in 'git push' 'git push origin lease/02' 'git -c push.default=current push' 'git push origin HEAD:heads/fix/x' \
           'git config push.default current' 'git branch -u origin/fix/x'; do
    run guard_as sB "$c" "$W2"; allowed || { echo "not allowed: $c"; return 1; }
  done
}

# ---- Plan 4 completeness critic, finding 1: the guard fails CLOSED on a git command it cannot read ----

@test "a git command the guard cannot resolve to literal words is denied: a subcommand, option or path from a variable, env -S, bash/zsh -c or eval of a variable, \$( ) or backticks in git's words, glob characters, a cd to a variable; GIT_COMMON_DIR is denied; literal feature pushes, reads, a message with a variable and pathspecs after -- are not (critic finding 1)" {
  scratch_and_worktree
  touch -- "$W2/--no-verify" "$W2/HEAD:main"      # what makes the glob spelling match (the critic's probe)
  for c in 'F=send-pack; git $F origin lease/02:main' 'F=--no-verify; git push $F origin lease/02' \
           "F='git push --no-verify origin HEAD:main'; bash -c \"\$F\"" "F='git push --no-verify origin HEAD:main'; eval \"\$F\"" \
           "F='git push --no-verify origin HEAD:main'; zsh -c \"\$F\"" "bash -c \"git push origin HEAD:\$B\"" \
           "env -S 'git push --no-verify origin HEAD:main'" "env --split-string='git push --no-verify origin HEAD:main'" \
           "env -S 'git send-pack origin lease/02:main'" 'git push --no-verif? origin HEAD:ma?n' 'git push origin HEAD:ma*' \
           'git push origin "$B"' 'git push origin HEAD:${B}' 'G=git; $G push origin HEAD:main' '"$G" push origin HEAD:main' \
           'git -C $D push origin HEAD:main' 'cd $D && git push origin HEAD:main' 'cd "$D"; git status' \
           'GIT_DIR=$D git push origin HEAD:main' 'sudo $G push origin HEAD:main' 'nice $G push origin HEAD:main' \
           'git $(echo push) origin HEAD:main' 'git `echo push` origin HEAD:main' 'git -c alias.x=$A x origin HEAD:main' \
           "git push \$'\\x2d\\x2dno-verify' origin lease/02" 'gi? push origin HEAD:main' 'git log $R' \
           'GIT_COMMON_DIR=/tmp/x git push origin lease/02' 'export GIT_COMMON_DIR=/tmp/x' 'env GIT_COMMON_DIR=/tmp/x git status'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sB 'F=--no-verify; git push $F origin lease/02' "$W2"
  case "$output" in *"I can't read this git command exactly, so I can't check it is not a push to trunk. Write it out literally."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sB "env -S 'git status'" "$W2"; denied
  run guard_as sB 'GIT_COMMON_DIR=/tmp/x git push origin lease/02' "$W2"
  case "$output" in *"GIT_COMMON_DIR"*"pre-push hook"*) : ;; *) echo "$output"; return 1 ;; esac
  for c in 'git push origin lease/02' 'git status' 'git log --oneline -5' "git log --format='%H \$x' -1" \
           'git commit -m "fix $thing"' 'git commit --message="note $x"' 'git add -- *.py' 'git diff HEAD~1 -- "$f"' \
           "bash -c 'git status'" 'echo $HOME' 'for f in *.md; do wc -l "$f"; done' 'git push origin lease/02 2>&1 | tail -1' \
           "git log -1 --format='\$(x)'" 'cd ../../01 && ls' '[ -f x ] && git status' 'git rev-parse HEAD@{1}'; do
    run guard_as sB "$c" "$W2"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
  # why the guard must: git runs no pre-push hook under --no-verify, under -c core.hooksPath, or with its hooks
  # directory moved by GIT_COMMON_DIR — measured on a plain repo whose hook refuses every push
  P="$BATS_TEST_TMPDIR/plain"; B="$BATS_TEST_TMPDIR/plain.git"; git init -q --bare -b main "$B"; git clone -q "$B" "$P" 2>/dev/null
  printf '#!/bin/sh\nexit 1\n' > "$P/.git/hooks/pre-push"; chmod +x "$P/.git/hooks/pre-push"; git clone -q --bare "$P" "$BATS_TEST_TMPDIR/x.git" 2>/dev/null
  for how in '' '--no-verify' '-c core.hooksPath=/dev/null' 'GIT_COMMON_DIR'; do
    git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m "m$how"
    case "$how" in
      '') run git -C "$P" push -q "$B" HEAD:main; [ "$status" -ne 0 ] ;;
      --no-verify) run git -C "$P" push -q --no-verify "$B" HEAD:main; [ "$status" -eq 0 ] ;;
      -c*) run git -C "$P" -c core.hooksPath=/dev/null push -q "$B" HEAD:main; [ "$status" -eq 0 ] ;;
      GIT_COMMON_DIR) git -C "$BATS_TEST_TMPDIR/x.git" fetch -q "$P" HEAD:refs/heads/main 2>/dev/null || true
                      run env GIT_COMMON_DIR="$BATS_TEST_TMPDIR/x.git" git -C "$P" push -q "$B" HEAD:main; [ "$status" -eq 0 ] ;;
    esac
  done
}

@test "a pattern refspec whose destination can land on a trunk is denied — refs/heads/x/*:refs/heads/*, refs/heads/*:refs/heads/*, refs/*:refs/*, a bare refs/heads/*, the + forms, and remote.<name>.push set to one; a glob-spelled refspec is denied (finding 1's rule); a pattern that cannot reach a trunk is not (critic finding 3)" {
  scratch_and_worktree
  touch -- "$W2/HEAD:main"
  for c in "git push origin 'refs/heads/x/*:refs/heads/*'" "git push origin 'refs/heads/*:refs/heads/*'" \
           "git push origin '+refs/heads/*:refs/heads/*'" "git push origin 'refs/*:refs/*'" "git push origin 'refs/heads/*'" \
           "git push origin 'refs/heads/lease/*:refs/heads/ma*'" "git push origin '*:*'" 'git push origin HEAD:ma?n' \
           "git -c 'remote.origin.push=refs/heads/*:refs/heads/*' push origin" "git config remote.origin.push 'refs/heads/*:refs/heads/*'"; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sB "git push origin 'refs/heads/x/*:refs/heads/*'" "$W2"
  case "$output" in *"refs/heads/x/*:refs/heads/*"*"main"*"Trunk is reached only through promote."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W2" config remote.origin.push 'refs/heads/*:refs/heads/*'
  run guard_as sB 'git push origin' "$W2"; denied
  git -C "$W2" config --unset remote.origin.push
  for c in "git push origin 'refs/heads/lease/02/*:refs/heads/lease/02/*'" "git push origin 'refs/heads/fix/*:refs/heads/fix/*'" \
           "git push origin 'refs/tags/*:refs/tags/*'"; do
    run guard_as sB "$c" "$W2"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
  # why: with no hook, the pattern moved the trunk (the critic's measurement, reproduced)
  P="$BATS_TEST_TMPDIR/plain"; B="$BATS_TEST_TMPDIR/plain.git"; git init -q --bare -b main "$B"; git clone -q "$B" "$P" 2>/dev/null
  git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m a; git -C "$P" push -q origin HEAD:main
  git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m b; git -C "$P" branch x/main HEAD
  run git -C "$P" push -q origin 'refs/heads/x/*:refs/heads/*'; [ "$status" -eq 0 ]
  [ "$(git -C "$B" rev-parse main)" = "$(git -C "$P" rev-parse HEAD)" ]
}

# ---- Plan 4 completeness critic, finding 2: a write whose target the guard cannot resolve ----

@test "a write whose target cannot be resolved to a literal path is denied when it could land under the transcript directory or Daedalus's own files — a glob, a variable, \$( ), a brace expansion, a relative path after cd to a variable, env -S; curl, wget, tar, unzip, ditto, install, patch, sqlite3, sort -o, git --output, awk, python -c, perl -e and ln toward the transcript are writes; ordinary writes elsewhere are not (critic finding 2)" {
  P="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(cd "$DAEDALUS_HOME" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$P/memory"
  S="${P##*/}"; G="$CLAUDE_CONFIG_DIR/proj?cts/$S"
  : > "$P/s1.jsonl"; printf 'x\n' > "$BATS_TEST_TMPDIR/p.patch"
  for c in "echo x >> $G/s1.jsonl" "echo x >> $P/s?.jsonl" "echo x >> $P/*.jsonl" "tee -a $G/s1.jsonl" "cp /tmp/x $G/s1.jsonl" \
           "echo x >> \"\$Q/s1.jsonl\"" 'echo x >> $(cat /tmp/where)' "tee $P/s{1,2}.jsonl" "cd \$Q && echo x >> s1.jsonl" \
           "dd if=/tmp/f of=\$Q" "mv /tmp/x \"\$Q\"" "env -S 'cp /tmp/x $P/s1.jsonl'" \
           "curl -o $P/s1.jsonl https://example.com/x" "curl --output $P/s1.jsonl https://example.com/x" \
           "curl -sSo $P/s1.jsonl https://example.com/x" "wget -O $P/s1.jsonl https://example.com/x" \
           "wget --output-document=$P/s1.jsonl https://example.com/x" "tar -xf /tmp/a.tar -C $P" "tar xf /tmp/a.tar -C $CLAUDE_CONFIG_DIR/projects" \
           "tar -cf $P/s1.jsonl /tmp/x" "unzip -o /tmp/a.zip -d $P" "ditto /tmp/x $P/s1.jsonl" "install -m 644 /dev/stdin $P/s1.jsonl" \
           "patch $P/s1.jsonl < $BATS_TEST_TMPDIR/p.patch" "sqlite3 /tmp/x.db '.output $P/s1.jsonl' 'select 1'" "sqlite3 $P/s1.jsonl 'select 1'" \
           "sort -o $P/s1.jsonl /tmp/x" "git -C /tmp log --output=$P/s1.jsonl -1" "awk '{print > \"$P/s1.jsonl\"}' /tmp/x" \
           "awk '{print >> f}' f=$P/s1.jsonl /tmp/x" "python3 -c \"import glob; open(glob.glob('$G/s1.jsonl')[0], 'a').write('x')\"" \
           "python3 -c \"from pathlib import Path; Path('$P/s1.jsonl').write_text('x')\"" "python3 -c \"import sys; open(sys.argv[1], 'a').write('x')\" $P/s1.jsonl" \
           "python3 -c \"import shutil; shutil.copy('/tmp/x', '$P/s1.jsonl')\"" "perl -e 'open(my \$f, \">>\", \$ARGV[0])' $P/s1.jsonl" \
           "ln -s $P $BATS_TEST_TMPDIR/link" "cp -t $P /tmp/x" "rm -f $CLAUDE_CONFIG_DIR/proj?cts/$S/*.jsonl"; do
    run guard "$c"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard "echo x >> $G/s1.jsonl"
  case "$output" in *"I can't tell exactly where this write lands"*"Write the path out literally."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard "curl -o $P/s1.jsonl https://example.com/x"
  case "$output" in *"the session transcript is the record of the operator's yes; nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
  # writes Daedalus's own files cannot be spelled around either
  for c in 'echo x > core/li?.sh' 'echo x > "$D/core/lib.sh"' 'tee core/*.sh' 'rm -f *' "curl -o core/lib.sh https://example.com/x"; do
    run guard "$c"; denied || { echo "not denied: $c"; return 1; }
  done
  # ordinary writes elsewhere stay allowed
  mkdir -p "$BATS_TEST_TMPDIR/w/build"
  for c in "echo x > /tmp/out.txt" "ls 2>/dev/null" "rm -f build/*.o" "curl -o /tmp/x https://example.com/x" "tar -xf /tmp/a.tar -C /tmp/y" \
           "tar -tf /tmp/a.tar" "tar -cf /tmp/a.tar build" "python3 -c \"open('/tmp/x', 'w').write('y')\"" "python3 -c \"import json; print(json.load(open('a.json')))\"" \
           "sort -o /tmp/s /tmp/x" "awk '\$1 > 5' /tmp/x" "echo x >> $P/memory/MEMORY.md" "cat $P/s1.jsonl" "cp a.txt build/" "git log --oneline -1"; do
    run guard "$c" "$BATS_TEST_TMPDIR/w"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
}

# ---- Plan 4 critic-fix review: routes past the finding 1–3 fixes ----

@test "HOME or XDG_CONFIG_HOME set in a command that runs git is denied — a prefix, through env, exported, or assigned, before git or around a function that runs it — since git reads its global configuration from there; a push whose configuration, read as it runs, sets core.hooksPath is denied; HOME= in front of a command that runs no git is not (critic-fix review, finding 1)" {
  scratch_and_worktree
  H="$BATS_TEST_TMPDIR/h"; mkdir -p "$H"
  printf '[core]\n\thooksPath = /dev/null\n[remote "origin"]\n\tpush = HEAD:refs/heads/main\n' > "$H/.gitconfig"
  for c in "HOME=$H git push origin" "env HOME=$H git push" "export HOME=$H; git push" "HOME=$H; git push origin lease/02" \
           "XDG_CONFIG_HOME=$H git push origin" "export XDG_CONFIG_HOME=$H && git status" "env -i HOME=$H PATH=/usr/bin git push" \
           "HOME=$H bash -c 'git push origin lease/02'" "declare -x HOME=$H; git push origin lease/02" \
           "HOME=$H sudo git push origin lease/02" "f() { git push origin lease/02; }; HOME=$H f" "git status; HOME=$H ls"; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sB "HOME=$H git push origin" "$W2"
  case "$output" in *"HOME is not set in front of a git command"*"pre-push hook"*) : ;; *) echo "$output"; return 1 ;; esac
  # anywhere in a command that runs git (a function defined before it runs git after it); a command running no git keeps them
  for c in "HOME=$H ls" "echo HOME=$H" "XDG_CONFIG_HOME=$H python3 -c 'print(1)'"; do
    run guard_as sB "$c" "$W2"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
  # the configuration git runs with already sets core.hooksPath (the hook's own HOME here, or the repo): no push
  run env HOME="$H" bash -c "$(declare -f guard_as); guard_as sB 'git push origin lease/02' '$W2'"
  case "$output" in *"core.hooksPath"*"pre-push hook"*) : ;; *) echo "global: $output"; return 1 ;; esac
  git -C "$W2" config core.hooksPath /dev/null
  run guard_as sB 'git push origin lease/02' "$W2"; denied
  git -C "$W2" config --unset core.hooksPath
  run guard_as sB 'git push origin lease/02' "$W2"; allowed
  # why: HOME= points git at another global configuration, whose core.hooksPath skips the refusing pre-push hook
  # and whose remote.origin.push lands the push on main — measured on a plain repo with a bare origin
  P="$BATS_TEST_TMPDIR/plain"; B="$BATS_TEST_TMPDIR/plain.git"; git init -q --bare -b main "$B"; git clone -q "$B" "$P" 2>/dev/null
  git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m a; git -C "$P" push -q origin HEAD:main
  printf '#!/bin/sh\nexit 1\n' > "$P/.git/hooks/pre-push"; chmod +x "$P/.git/hooks/pre-push"
  git -C "$P" switch -q -c fix/x; git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m b
  run git -C "$P" push -q origin HEAD:main; [ "$status" -ne 0 ]
  run env HOME="$H" git -C "$P" push -q origin; [ "$status" -eq 0 ]
  [ "$(git -C "$B" rev-parse main)" = "$(git -C "$P" rev-parse HEAD)" ]
}

@test "cd and pushd with options are read as the shell reads them — -L, -P, -e, -@ and -- before the directory, which is the first operand after them; any other option, a missing operand, popd, and a cd through builtin are placed too, so a trunk push or commit after them is denied (critic-fix review, finding 2)" {
  scratch_and_worktree
  for c in 'cd -P "$D" && git push origin HEAD:main' 'cd -P "$D" && git commit -m x' 'cd -- "$D" && git commit -m x' \
           'cd -L "$D"; git status' 'cd -LP "$D" && git status' 'pushd -n "$D" && git status' 'cd -X x && git status' \
           'cd -P && git status' 'popd && git status' 'builtin cd "$D" && git push origin HEAD:main'; do
    run guard_as sB "$c" /tmp; denied || { echo "not denied: $c"; return 1; }
  done
  for c in 'cd -P target/thing && git push origin HEAD:main' 'cd -- target/thing && git push origin HEAD:main' \
           'cd -P target/thing && git commit -m x' 'cd -e -P target/thing && git commit -m x' 'cd -LP target/thing && git commit -m x' \
           'cd -- target/thing && git commit -m x' 'builtin cd target/thing && git commit -m x' 'command cd -P target/thing && git commit -m x' \
           'pushd -- target/thing && git commit -m x'; do
    run guard_as sB "$c" "$DAEDALUS_HOME"; denied || { echo "not denied from the home: $c"; return 1; }
  done
  run guard_as sB 'cd -P target/thing && git commit -m x' "$DAEDALUS_HOME"
  case "$output" in *"You are on main in the prime's checkout"*) : ;; *) echo "$output"; return 1 ;; esac
  for c in 'cd -P worktrees/02/thing && git push origin lease/02' 'cd -- worktrees/02/thing && git status' 'cd -P target && ls' \
           'cd -- vault && ls'; do
    run guard_as sB "$c" "$DAEDALUS_HOME"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
}

@test "git push --repo=<remote> (and --repo <remote>, --rep=<remote>) is the remote a push with no repository argument goes to: its remote.<name>.push and .mirror are read, and a push toward the target's origin from outside the home is in scope; a repository argument still wins over it (critic-fix review, finding 4)" {
  scratch_and_worktree
  git -C "$W2" remote add up "$BATS_TEST_TMPDIR/origin.git"
  for c in 'git -c remote.up.push=HEAD:refs/heads/main push --repo=up' 'git -c remote.up.push=HEAD:refs/heads/main push --repo up' \
           'git -c remote.up.mirror=true push --repo=up' 'git -c remote.up.push=HEAD:refs/heads/main push --rep=up' \
           'git -c remote.up.push=HEAD:refs/heads/main push --rep up'; do
    run guard_as sB "$c" "$W2"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard_as sB 'git -c remote.up.push=HEAD:refs/heads/main push --repo=up' "$W2"
  case "$output" in *"remote.up.push sends it there"*) : ;; *) echo "$output"; return 1 ;; esac
  for c in 'git push --repo=up' 'git -c remote.up.push=HEAD:refs/heads/main push --repo=up origin lease/02'; do
    run guard_as sB "$c" "$W2"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
  # from a clone outside the home whose origin is elsewhere: --repo=up names the target's origin
  C="$BATS_TEST_TMPDIR/outside"; E="$BATS_TEST_TMPDIR/else.git"; git init -q --bare -b main "$E"; git clone -q "$E" "$C" 2>/dev/null
  git -C "$C" remote add up "$BATS_TEST_TMPDIR/origin.git"
  run guard_as sB 'git -c remote.up.push=HEAD:refs/heads/main push --repo=up' "$C"; denied
  # why: with no hook, --repo=up with remote.up.push moved the trunk (the reviewer's measurement, reproduced)
  P="$BATS_TEST_TMPDIR/plain"; B="$BATS_TEST_TMPDIR/plain.git"; git init -q --bare -b main "$B"; git clone -q "$B" "$P" 2>/dev/null
  git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m a; git -C "$P" push -q origin HEAD:main
  git -C "$P" remote add up "$B"; git -C "$P" switch -q -c fix/x; git -C "$P" -c user.email=t@x -c user.name=t commit -q --allow-empty -m b
  run git -C "$P" -c remote.up.push=HEAD:refs/heads/main push -q --repo=up; [ "$status" -eq 0 ]
  [ "$(git -C "$B" rev-parse main)" = "$(git -C "$P" rev-parse HEAD)" ]
}

@test "the whole-file writers past the finding 2 fix are writes toward the transcript — a writer named by its path (/bin/cp, /usr/bin/tee, /usr/bin/sed -i), sed's w and W commands and s///w, base64 -o, openssl -out, xxd -r, split and csplit prefixes, plutil -o, scp, ex/vim commands, say -o, awk's system() and command pipes, osascript's do shell script; ordinary uses of each are not (critic-fix review, finding 3)" {
  P="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(cd "$DAEDALUS_HOME" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$P"
  T1="$P/s1.jsonl"; : > "$T1"
  for c in "/bin/cp /tmp/x $T1" "/usr/bin/tee -a $T1" "/usr/bin/sed -i '' 's/a/b/' $T1" "sudo /bin/mv /tmp/x $T1" \
           "sed -n 'w $T1' /tmp/x" "sed -e '1w $T1' /tmp/x" "sed -n '/x/W $T1' /tmp/x" "sed 's/a/b/w $T1' /tmp/x" \
           "sed -n -e p -e '\$w $T1' /tmp/x" "sed --expression='1,3w $T1' /tmp/x" "sed 's/a/b/e' /tmp/x" "sed '1e echo x' /tmp/x" \
           "base64 -d -o $T1 /tmp/x" "base64 --decode --output=$T1 -i /tmp/x" "openssl enc -d -base64 -in /tmp/x -out $T1" \
           "openssl base64 -d -in /tmp/x -out $T1" "xxd -r /tmp/x $T1" "xxd -r -p /tmp/x $T1" "split -l 1 /tmp/x $P/s" \
           "csplit -f $P/x /tmp/x 1" "csplit --prefix=$P/x /tmp/x 1" "plutil -convert json -o $T1 /tmp/x.plist" "plutil -convert json $T1" \
           "scp /tmp/x $T1" "scp -P 22 host:/tmp/x $T1" "ex -sc 'wq! $T1' /tmp/x" "vim -es -c 'w! $T1' -c q /tmp/x" \
           "vim -es -c '%s/a/b/' -c wq $T1" "vim -es +'w $T1' +q /tmp/x" "nvim --headless -c 'saveas $T1' -c q /tmp/x" \
           "vim -es -c '!echo x >> $T1' -c q /tmp/x" "vim -es -c 'e $T1' -c '%s/a/b/' -c wq" "vim -es -c 'redir > $T1' -c q" \
           "vim -es -c 'set backupdir=$P' -c wq /tmp/x" "vim -es -S /tmp/script.vim /tmp/x" "vim -es -c '%s/a/\\=system(\"x\")/' -c wq /tmp/x" \
           "say -o $T1 hi" "say --output-file=$T1 hi" "awk 'BEGIN{system(\"echo x >> $T1\")}'" \
           "awk 'BEGIN{print \"x\" | \"cat >> $T1\"}'" "awk 'BEGIN{c=\"cat >> $T1\"; print \"x\" | c}'" "awk 'BEGIN{system(c)}'" \
           "awk 'BEGIN{\"cp /tmp/x $T1\" | getline}'" "gawk -i inplace '{print}' $T1" \
           "osascript -e 'do shell script \"echo x >> $T1\"'" "osascript -e 'do shell script \"echo \" & x'" \
           "osascript -e 'set f to open for access POSIX file \"$T1\" with write permission'"; do
    run guard "$c"; denied || { echo "not denied: $c"; return 1; }
  done
  run guard "sed -n 'w $T1' /tmp/x"
  case "$output" in *"the session transcript is the record of the operator's yes; nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard "awk 'BEGIN{system(c)}'"
  case "$output" in *"I can't tell exactly where this awk code writes"*) : ;; *) echo "$output"; return 1 ;; esac
  mkdir -p "$BATS_TEST_TMPDIR/w"
  for c in "/bin/cp a.txt /tmp/b.txt" "sed -n '/w/p' a.txt" "sed 's/a/w/' a.txt" "sed 'y/abc/xyz/' a.txt" "sed -n 'w /tmp/out' a.txt" \
           "sed -i '' 's/a/b/' a.txt" "sed -n p env.txt" "base64 -i a.txt -o /tmp/b64" "base64 a.txt" "openssl dgst -sha256 a.txt" \
           "openssl enc -in a.txt -out /tmp/enc" "xxd a.txt" "xxd -l 16 $T1" "split -l 100 a.txt /tmp/part" "csplit -f /tmp/xx a.txt 5" \
           "plutil -lint a.plist" "plutil -convert json -o /tmp/a.json a.plist" "scp a.txt host:/tmp/" "vim -es -c '%s/a/b/g' -c wq a.txt" \
           "ex -sc 'g/^#/d' -c 'wq' a.txt" "say hello" "awk '{print \$1}' a.txt" "awk '{print | \"sort\"}' a.txt" \
           "osascript -e 'display notification \"done\"'" "osascript -e 'do shell script \"ls /tmp\"'" "cat $T1"; do
    run guard "$c" "$BATS_TEST_TMPDIR/w"; allowed || { echo "not allowed: $c: $output"; return 1; }
  done
}

product_home() {  # Daedalus's own checkout (lease_fixture made it a repo on main) tracking origin/main, a release ahead on origin
  H="$DAEDALUS_HOME"; O="$BATS_TEST_TMPDIR/dae-origin.git"
  git clone -q --bare "$H" "$O"; git -C "$H" remote add origin "$O"; git -C "$H" fetch -q origin; git -C "$H" branch -q -u origin/main
  git clone -q "$O" "$BATS_TEST_TMPDIR/rel"; printf 'y\n' >> "$BATS_TEST_TMPDIR/rel/CLAUDE.md"
  git -C "$BATS_TEST_TMPDIR/rel" -c user.email=t@x -c user.name=t commit -q -am v2; git -C "$BATS_TEST_TMPDIR/rel" push -q origin main
  # the guard reads the effective configuration: an empty global file and no system file, never the developer's own
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/global.gitconfig" GIT_CONFIG_NOSYSTEM=1; : > "$GIT_CONFIG_GLOBAL"
}

@test "the release pull: in Daedalus's own checkout exactly 'git pull --ff-only' (with -q or --quiet, through -C or the cwd) is allowed; any other word, any other global option (--git-dir, --work-tree, --namespace, --exec-path), a -c pair, --config-env or a GIT_* prefix and it is denied (plan 5 Decision 17; Task 9 review, finding 2)" {
  scratch_and_worktree; product_home
  for c in 'pull --ff-only' 'pull --ff-only -q' 'pull --quiet --ff-only'; do
    run guard_as sA "git -C $H $c"; allowed || { echo "denied: git $c: $output"; return 1; }
  done
  run guard_as sA 'git pull --ff-only' "$H/core"; allowed
  for c in "-C $H pull" "-C $H pull --ff-only origin main" "-C $H pull --ff-only /tmp/other" "-C $H pull --ff-only --rebase" \
           "-C $H pull --ff-only --no-verify" "-C $H pull --ff" "-C $H -c remote.origin.url=/tmp/x pull --ff-only" \
           "-C $H --config-env=remote.origin.url=X pull --ff-only" \
           "--git-dir=$H/.git --work-tree=$BATS_TEST_TMPDIR/elsewhere pull --ff-only" "--git-dir=$H/.git pull --ff-only" \
           "-C $H --work-tree=$BATS_TEST_TMPDIR/elsewhere pull --ff-only" "-C $H --namespace=x pull --ff-only" \
           "-C $H --exec-path=$BATS_TEST_TMPDIR pull --ff-only"; do
    run guard_as sA "git $c"; denied || { echo "not denied: git $c: $output"; return 1; }
  done
  run guard_as sA "GIT_SSH_COMMAND=/tmp/x git -C $H pull --ff-only"; denied
  run guard_as sA "GIT_WORK_TREE=$BATS_TEST_TMPDIR/elsewhere git pull --ff-only" "$H"; denied
  run guard_as sA "git -C $H --work-tree=$BATS_TEST_TMPDIR/elsewhere status"; allowed   # reading, wherever the files are
  run guard_as sB 'git pull --ff-only' "$W2"; allowed      # a window's worktree is not the product repo: unchanged
}

@test "the release pull reads where it pulls from as git will when it runs: an address rewrite (insteadOf) or a second address from settings outside the checkout, an upload-pack or remote helper, a branch that tracks another name or another remote, a detached HEAD — each refuses it in one sentence (Task 9 review, finding 1)" {
  scratch_and_worktree; product_home
  run guard_as sA "git -C $H pull --ff-only"; allowed
  git config --file "$GIT_CONFIG_GLOBAL" "url.$BATS_TEST_TMPDIR/evil.git.insteadOf" "$O"
  run guard_as sA "git -C $H pull --ff-only"; denied
  case "$output" in *"The release pull is refused"*"address rewrite"*"$BATS_TEST_TMPDIR/evil.git"*"pull the release in a shell"*) : ;; *) echo "$output"; return 1 ;; esac
  : > "$GIT_CONFIG_GLOBAL"; git config --file "$GIT_CONFIG_GLOBAL" remote.origin.url "$BATS_TEST_TMPDIR/evil.git"
  run guard_as sA "git -C $H pull --ff-only"; denied; case "$output" in *"outside this checkout"*) : ;; *) echo "$output"; return 1 ;; esac
  : > "$GIT_CONFIG_GLOBAL"; git config --file "$GIT_CONFIG_GLOBAL" remote.origin.uploadpack "/tmp/x"
  run guard_as sA "git -C $H pull --ff-only"; denied; case "$output" in *"remote.origin.uploadpack"*) : ;; *) echo "$output"; return 1 ;; esac
  : > "$GIT_CONFIG_GLOBAL"; git -C "$H" config remote.origin.vcs evil
  run guard_as sA "git -C $H pull --ff-only"; denied; case "$output" in *"remote.origin.vcs"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$H" config --unset remote.origin.vcs
  git -C "$H" config branch.main.merge refs/heads/other
  run guard_as sA "git -C $H pull --ff-only"; denied; case "$output" in *"does not follow main on its remote"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$H" config branch.main.merge refs/heads/main; git -C "$H" config branch.main.remote .
  run guard_as sA "git -C $H pull --ff-only"; denied
  git -C "$H" config branch.main.remote origin
  run guard_as sA "git -C $H pull --ff-only"; allowed
  git -C "$H" checkout -q --detach
  run guard_as sA "git -C $H pull --ff-only"; denied; case "$output" in *"not on a branch"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "Daedalus's own checkout takes reading git and the release pull, nothing else: every command that moves its HEAD, index or files, or repoints where the pull reads from, is denied — the repoint-then-pull chain in one call included; reading is allowed (Task 9 review, finding 1)" {
  scratch_and_worktree; product_home
  E="$BATS_TEST_TMPDIR/evil.git"
  for c in "remote set-url origin $E" "remote add evil $E" "remote rename origin old" "remote remove origin" \
           "config remote.origin.url $E" "config branch.main.remote evil" "config --add remote.origin.url $E" \
           "config url.$E.insteadOf $O" "config set remote.origin.url $E" "config --unset branch.main.merge" "config -e" \
           "branch -u evil/main" "branch --set-upstream-to=evil/main" "branch -f main FETCH_HEAD" "branch x FETCH_HEAD" \
           "checkout -b x FETCH_HEAD" "checkout -B main FETCH_HEAD" "checkout FETCH_HEAD -- core" "switch -c x FETCH_HEAD" \
           "reset --soft FETCH_HEAD" "reset FETCH_HEAD" "update-ref refs/heads/main FETCH_HEAD" "symbolic-ref HEAD refs/heads/x" \
           "read-tree -u -m FETCH_HEAD" "fetch --update-head-ok $E main:main" "fetch -u $E main:main" "fetch --upload-pack=/tmp/x origin" \
           "commit -am x" "commit --amend --no-edit" "add core" "stash" "worktree add $BATS_TEST_TMPDIR/wt FETCH_HEAD" \
           "replace HEAD FETCH_HEAD" "bisect start" "notes add -m x" "tag -f v9 FETCH_HEAD"; do
    run guard_as sA "git -C $H $c"; denied || { echo "not denied: git $c: $output"; return 1; }
  done
  run guard_as sA "git -C $H remote set-url origin $E && git -C $H pull --ff-only"; denied
  case "$output" in *"Daedalus's own checkout"*) : ;; *) echo "$output"; return 1 ;; esac
  for c in status log "log --oneline -3" diff "show HEAD" fetch "fetch origin" "fetch -q --tags origin" "remote" "remote -v" \
           "remote get-url origin" "remote show origin" branch "branch -a" "branch --show-current" "branch -vv" \
           "config --get remote.origin.url" "config --list" "config get remote.origin.url" "stash list" "rev-parse HEAD" \
           "worktree list" "tag" "tag -l" "ls-remote origin" "ls-files core" "describe --tags --always" "blame CLAUDE.md"; do
    run guard_as sA "git -C $H $c"; allowed || { echo "denied: git $c: $output"; return 1; }
  done
}

@test "git settings that decide where a pull reads from are not set from any window at the global or system scope or in a named file — they reach Daedalus's own checkout too; other global settings and every read stay allowed (Task 9 review, finding 1)" {
  scratch_and_worktree; product_home
  for c in "config --global url./tmp/evil.insteadOf https://example.com/" "config --global remote.origin.url /tmp/evil" \
           "config --system branch.main.remote evil" "config --file $HOME/.gitconfig branch.main.merge refs/heads/x" \
           "config -f $BATS_TEST_TMPDIR/x.cfg pull.rebase true" "config --global http.sslVerify false" \
           "config --global http.proxy http://127.0.0.1:9" "config --global core.sshCommand /tmp/x" \
           "config --global protocol.file.allow always" "config --global submodule.recurse true" "config --global --edit"; do
    run guard_as sA "git $c" "$W1"; denied || { echo "not denied: git $c: $output"; return 1; }
  done
  for c in "config --global user.name x" "config --global --get url.x.insteadof" "config --global --list" \
           "config --local pull.rebase true" "config branch.lease/01.description x"; do
    run guard_as sA "git $c" "$W1"; allowed || { echo "denied: git $c: $output"; return 1; }
  done
}

# --- Deleting a window's work: the guard's early refusal (agent-runnable design 2026-10-15, §4.3) ---------------
# The tracked settings allow `core/lease.sh release:*` ahead of auto mode's classifier; this hook is what decides
# whether the delete runs, in every mode, and leaselib.release backstops the forms it cannot read.
# delete_guard — windows 01 (sA, holds the pen, live) and 02 (stale, one unpromoted commit); sA's transcript at the
# path transcriptlib reads and its SessionStart marker naming it. W is 02's worktree.
delete_guard() {
  guard_leases
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sZ"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  W="$DAEDALUS_HOME/worktrees/02/thing"
  printf 'w\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "unmerged work"
  TX="$(tx_path sA)"; : > "$TX"
  python3 - "$DAEDALUS_HOME/state/session-sA.json" "$TX" <<'PY'
import json, sys, time
json.dump({"session_id": "sA", "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "started_epoch": time.time(),
           "transcript_path": sys.argv[2], "lease": "01"}, open(sys.argv[1], "w"), indent=2)
PY
  M="$DAEDALUS_HOME/state/release-asked/02.json"
  export W TX M
}
asked_by_sA() { DAEDALUS_SESSION_ID=sA bash "$DAEDALUS_HOME/core/lease.sh" unpromoted 02; }
LINE02="Say yes to delete window 02's work."
DEL='core/lease.sh release 02 --remove --force'
ASK_FIRST="Run core/lease.sh unpromoted 02 first, repeat its report to the operator word for word, and ask; the delete runs only after their yes."
# shown_then_yes <words> [shown text] — the report's tool result, the assistant turn that showed it (the whole
# report by default), then the operator's words, all after the ask; sets P. The entries are stamped a few seconds
# ahead of the clock (tx), and each ask moves the cut-off to the clock: a SECOND ask in one test must wait until
# the clock has passed the earlier entries (settle), or they would land after the new cut-off too.
settle() { [ -z "${P:-}" ] || python3 -c 'import sys,time; time.sleep(max(0.0, float(sys.argv[1]) - time.time()))' "$(plus "$P" 4)"; }
shown_then_yes() {
  local R; settle; R="$(asked_by_sA)"; P="$(now)"
  tx "$TX" tool-result "$R" "$(plus "$P" 1)" >/dev/null
  tx "$TX" assistant "${2:-$R}" "$(plus "$P" 2)" >/dev/null
  tx "$TX" operator "$1" "$(plus "$P" 3)" >/dev/null
}

@test "delete gate: core/lease.sh release 02 --remove is denied without the report, without --operator-said, with words not beginning with yes, with a reply of two lines or carrying a \$ (the one-word-yes sentence), and when only a tool result or the report's first sentence carried the line; nothing else about lease.sh is gated" {
  delete_guard
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"$ASK_FIRST"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA 'core/lease.sh release 02 --remove --operator-said yes'; denied; case "$output" in *"$ASK_FIRST"*) : ;; *) echo "$output"; return 1 ;; esac   # without --force too
  run guard_as sA 'core/lease.sh release 02'; allowed
  run guard_as sA 'core/lease.sh unpromoted 02'; allowed
  run guard_as sA 'core/lease.sh list'; allowed
  R="$(asked_by_sA)"
  run guard_as sA "$DEL"; denied; case "$output" in *"Record what the operator said: add --operator-said"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA "$DEL --operator-said ok"; denied; case "$output" in *"do not begin with yes"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA "$DEL --operator-said \"yes \$HOME\""; denied; case "$output" in *"Ask the operator for a one-word yes and record that"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA "$DEL --operator-said \"yes
please\""; denied; case "$output" in *"Ask the operator for a one-word yes and record that"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as sA "$DEL --operator-said 'yes \`date\`'"; denied
  # the line only in a tool result (never said to the operator), then only the first sentence in a reply
  P="$(now)"
  tx "$TX" tool-result "$R" "$(plus "$P" 1)" >/dev/null
  tx "$TX" operator "yes" "$(plus "$P" 2)" >/dev/null
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"The delete line was not shown to the operator before that yes"*) : ;; *) echo "$output"; return 1 ;; esac
  tx "$TX" assistant "${R%%$'\n'*}" "$(plus "$P" 3)" >/dev/null
  tx "$TX" operator "yes" "$(plus "$P" 4)" >/dev/null
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"The delete line was not shown to the operator before that yes"*"$LINE02"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$W" ]
}

@test "delete gate: allowed when the reply ended with the line and the operator's next turn is the yes (empty output, nothing deleted by the hook); allowed when the operator asked first and the answer ended with the line" {
  delete_guard
  shown_then_yes "yes"
  run guard_as sA "$DEL --operator-said yes"; allowed
  [ -d "$W" ]      # the hook decides; it deletes nothing itself
  # the operator asks first; the prime's answer ends with the line
  tx "$TX" operator "What is in it?" "$(plus "$P" 4)" >/dev/null
  tx "$TX" assistant "One commit on a.txt. $LINE02" "$(plus "$P" 5)" >/dev/null
  tx "$TX" operator "Yes, go ahead." "$(plus "$P" 6)" >/dev/null
  run guard_as sA "$DEL --operator-said 'Yes, go ahead.'"; allowed
}

@test "delete gate: denied when a later question cleared the line; denied for another session's marker, for a marker older than the window, and for a yes typed before the window existed with the marker's time forged to 0 (the lease file's own times hold the cut-off)" {
  delete_guard
  R="$(asked_by_sA)"; P="$(now)"
  tx "$TX" assistant "$R" "$(plus "$P" 1)" >/dev/null
  tx "$TX" operator "And the nested repo?" "$(plus "$P" 2)" >/dev/null
  tx "$TX" assistant "Nothing in it — did you mean window 03?" "$(plus "$P" 3)" >/dev/null
  tx "$TX" operator "yes" "$(plus "$P" 4)" >/dev/null
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"The delete line was not shown to the operator before that yes"*) : ;; *) echo "$output"; return 1 ;; esac
  # another session's marker is no witness for sA, even with the line shown and a yes after it
  python3 - "$M" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["session_id"] = "sB"; json.dump(d, open(sys.argv[1], "w"))
PY
  tx "$TX" assistant "$LINE02" "$(plus "$P" 5)" >/dev/null
  tx "$TX" operator "yes" "$(plus "$P" 6)" >/dev/null
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"$ASK_FIRST"*) : ;; *) echo "$output"; return 1 ;; esac
  # a marker older than the window's own created time
  python3 - "$M" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["session_id"] = "sA"; d["at"] = 1.0; json.dump(d, open(sys.argv[1], "w"))
PY
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"$ASK_FIRST"*) : ;; *) echo "$output"; return 1 ;; esac
  # the forged-marker case: the yes typed before the window existed, the marker's time 0 — refused
  created="$(python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); print(time.mktime(time.strptime(d["created"], "%Y-%m-%dT%H:%M:%S")))' "$DAEDALUS_HOME/state/leases/02.json")"
  : > "$TX"
  tx "$TX" assistant "$LINE02" "$(plus "$created" -20)" >/dev/null
  tx "$TX" operator "yes" "$(plus "$created" -10)" >/dev/null
  python3 - "$M" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["at"] = 0.0; json.dump(d, open(sys.argv[1], "w"))
PY
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"$ASK_FIRST"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$W" ]
}

@test "delete gate: denied after a new commit in the worktree and after an append to a dirty file (the work changed since the report); denied in tty mode with the paste line for the operator's own shell; denied with no session (an operator shell is never the guard's caller)" {
  delete_guard
  shown_then_yes "yes"
  printf 'x\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "another"
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"Window 02's work changed since the report"*"run core/lease.sh unpromoted 02 again and ask again"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'd\n' >> "$W/a.txt"
  shown_then_yes "yes"
  run guard_as sA "$DEL --operator-said yes"; allowed
  printf 'd2\n' >> "$W/a.txt"
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"Window 02's work changed since the report"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  shown_then_yes "yes"
  run guard_as sA "$DEL --operator-said yes"; denied; case "$output" in *"This deployment confirms at the terminal (promote.confirm: tty). Paste this line in your own shell: cd $DAEDALUS_HOME && core/lease.sh release 02 --remove --force"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard "$DEL --operator-said yes"; denied; case "$output" in *"The delete runs from a window: this command carries no session."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "delete gate: judged wherever lease.sh stands — inside bash -c, as bash core/lease.sh, behind each wrapper Claude Code strips for the allow rule (timeout, time, nice, nohup, stdbuf, command, builtin, noglob), behind sudo and flock, from a worktree's copy or any path; xargs and parallel refused outright; an alias or a variable for the number refused naming the number" {
  delete_guard
  for c in "bash -c '$DEL --operator-said yes'" "bash $DEL --operator-said yes" "eval $DEL --operator-said yes" \
           "timeout 30 $DEL --operator-said yes" "time $DEL --operator-said yes" "nice -n 5 $DEL --operator-said yes" \
           "nohup $DEL --operator-said yes" "stdbuf -oL $DEL --operator-said yes" "command $DEL --operator-said yes" \
           "builtin $DEL --operator-said yes" "noglob $DEL --operator-said yes" "sudo $DEL --operator-said yes" \
           "flock /tmp/x.lock $DEL --operator-said yes" "caffeinate -i $DEL --operator-said yes" \
           "worktrees/02/core/lease.sh release 02 --remove --force --operator-said yes" \
           "/tmp/copy/lease.sh release 02 --remove --force --operator-said yes" \
           "$DAEDALUS_HOME/core/lease.sh release 02 --remove --force --operator-said yes" \
           "cd worktrees/02 && ../../core/lease.sh release 02 --remove --force --operator-said yes" \
           "true && $DEL --operator-said yes" "$DEL --operator-said yes 2>&1 | cat"; do
    run guard_as sA "$c"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *"$ASK_FIRST"*) : ;; *) echo "wrong reason for '$c': $output"; return 1 ;; esac
  done
  for c in "xargs $DEL" "echo 'release 02 --remove --force' | xargs core/lease.sh" "xargs -n1 $DEL" "parallel core/lease.sh ::: release" \
           "printf '02' | xargs -I{} core/lease.sh release {} --remove --force"; do
    run guard_as sA "$c"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *"A delete takes its arguments on the command line, never from xargs or parallel"*) : ;; *) echo "wrong reason for '$c': $output"; return 1 ;; esac
  done
  for c in 'core/lease.sh release poc-ui --remove --force --operator-said yes' 'core/lease.sh release $NN --remove --force --operator-said yes' \
           'NN=02; core/lease.sh release "$NN" --remove --force --operator-said yes'; do
    run guard_as sA "$c"; denied || { echo "not denied: $c"; return 1; }
    case "$output" in *"Name the window by its number (core/lease.sh release 02 --remove"*) : ;; *) echo "wrong reason for '$c': $output"; return 1 ;; esac
  done
  # data commands that only mention the delete are not the delete
  run guard_as sA "echo $DEL"; allowed
  run guard_as sA "grep -n 'release 02 --remove' CLAUDE.md"; allowed
}

@test "delete gate: the guard's ALLOW_RULE_WRAPPERS is the wrapper list the permissions doc says Claude Code strips before matching an allow rule (read 2026-10-15) — when the docs' list grows, this constant and the wrapper cases above grow with it" {
  run python3 - "$DAEDALUS_HOME/core/guard-bash.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("guard_bash", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.ALLOW_RULE_WRAPPERS == ("timeout", "time", "nice", "nohup", "stdbuf", "command", "builtin", "noglob", "xargs"), m.ALLOW_RULE_WRAPPERS
assert m.LEASE_HEADS == {"lease.sh"}, m.LEASE_HEADS
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- The local layer on the Bash leg (update design §4.4; Decisions 3, 22) ---

brief_bash_checks() {   # brief_bash_checks <session-id> — the same sentences as the Edit leg
  run guard_as "$1" 'echo x > CLAUDE.md'; denied
  case "$output" in *"CLAUDE.md is distribution code; local brief text goes in CLAUDE.local.md"*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as "$1" 'echo x >> CLAUDE.local.md'; denied
  case "$output" in *"CLAUDE.local.md is the operator's brief; boundary.edit_brief is false in config.yaml."*) : ;; *) echo "$output"; return 1 ;; esac
  run guard_as "$1" 'rm -f CLAUDE.local.md'; denied
  run guard_as "$1" 'sed -i "" s/a/b/ CLAUDE.local.md'; denied
  run guard_as "$1" 'cat CLAUDE.local.md'; allowed
  printf 'boundary:\n  edit_brief: true\n' >> "$DAEDALUS_HOME/config.yaml"
  run guard_as "$1" 'echo x >> CLAUDE.local.md'; allowed
  run guard_as "$1" 'echo x > CLAUDE.md'; denied
  sed -i '' '/^boundary:/,$d' "$DAEDALUS_HOME/config.yaml"
}

@test "settings.local and the brief on the Bash leg, no leases held: CLAUDE.local.md is the operator's while edit_brief is false and Daedalus's when true; CLAUDE.md is always distribution code; an Edit(...) deny in settings.local.json refuses a Bash write" {
  brief_bash_checks s1
  printf '{"permissions":{"deny":["Edit(/notes/**)"]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run guard_as s1 'echo x > notes/a.md'; denied
  run guard_as s1 'cp /etc/hosts notes/'; denied
  run guard_as s1 'echo x > other.md'; allowed
}

@test "settings.local and the brief on the Bash leg, with windows held: the same answers for the prime and a clone, from the home" {
  guard_leases
  brief_bash_checks sA
  brief_bash_checks sB
  printf '{"permissions":{"deny":["Edit(./notes/**)"]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run guard_as sB 'echo x > notes/a.md'; denied
}

# ---------------------------------------------------------------------------------------------------------
# The AMI tier (frame-jack spec §6.0, §6.3–6.5, §5.5; §13.2 items 1–3, 5–11): after check_command, under the
# absolute deadline, shadow only. Fixtures only: the fake decider stands in for serve; no model, no network.
AMI_DIR_OF() { printf '%s/state/ami' "$DAEDALUS_HOME"; }
guard_ami() {  # guard_ami <session-id> <command> [cwd] — the payload a real Bash call carries: session_id, tool_use_id, transcript_path, cwd
  local cwd="${3:-$DAEDALUS_HOME}"
  hook_json PreToolUse "$1" "\"tool_name\":\"Bash\",\"cwd\":\"$cwd\",\"tool_input\":{\"command\":$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2"),\"description\":\"d\"}" \
    | python3 "$DAEDALUS_HOME/core/guard-bash.py"
}
prompt_as() {  # prompt_as <session-id> <text> — a UserPromptSubmit through lease-board.py, the transcript beside it
  mkdir -p "$BATS_TEST_TMPDIR/transcripts"
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","transcript_path":"%s/transcripts/%s.jsonl","prompt":%s}' \
    "$1" "$BATS_TEST_TMPDIR" "$1" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" \
    | python3 "$DAEDALUS_HOME/core/lease-board.py" >/dev/null
}
ami_daemon_json() {  # ami_daemon_json <port> <state> [heartbeat age secs] [request_timeout_ms] — a hand-written daemon.json, the fake as command
  mkdir -p "$(AMI_DIR_OF)"
  python3 - "$(AMI_DIR_OF)/daemon.json" "$AMI_FIX/fake-decider" "$1" "$2" "${3:-1}" "${4:-1500}" <<'PY'
import json, sys, time
d = {"supervisor_pid": 1, "leash_pid": 1, "serve_pid": 1, "borrowed": False, "port": int(sys.argv[3]), "device": "mps",
     "state": sys.argv[4], "terminal": False, "since": time.time() - 12, "heartbeat": time.time() - float(sys.argv[5]),
     "ready_ms": 31000, "restarts": 0, "last_error": None, "off_by": None, "command": sys.argv[2], "model": "m",
     "offline": False, "battery_off": True, "request_timeout_ms": int(sys.argv[6]), "shadow": ["destructive", "suite"], "enforce": []}
open(sys.argv[1], "w").write(json.dumps(d))
PY
}
ami_rows() {  # the day's decision rows as JSON lines (empty when there is no log)
  cat "$(AMI_DIR_OF)/decisions/$(date +%Y-%m-%d).jsonl" 2>/dev/null || true
}
ami_row() {  # ami_row <n> <python expression over r> — field of the nth row (1-based; -1 the last)
  ami_rows | python3 -c 'import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
r = rows[int(sys.argv[1]) - 1] if int(sys.argv[1]) > 0 else rows[int(sys.argv[1])]
print(eval(sys.argv[2]))' "$1" "$2"
}
ami_rows_count() { ami_rows | grep -c . || true; }
fake_requests() { [ -f "${FAKE_LOG:-$BATS_TEST_TMPDIR/fake.log}" ] && grep -c '"POST"' "${FAKE_LOG:-$BATS_TEST_TMPDIR/fake.log}" || echo 0; }
secs() { python3 -c 'import time; print(time.time())'; }
ami_on_with_fake() {  # sentinel + daemon.json up on a live fake; FAKE_* in the environment reach the fake
  start_fake StrandsAgents/strands-decider-2B-qwen3.5-v1-2610 "$@"
  mkdir -p "$(AMI_DIR_OF)"; touch "$(AMI_DIR_OF)/on"
  ami_daemon_json "$FAKE_PORT" up
}

@test "AMI: with no state/ami, and then with the directory but no sentinel, a Bash call makes no request and writes nothing under state/ami" {
  start_fake StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
  run guard_ami sA 'ls'; [ "$status" -eq 0 ]; allowed
  [ ! -e "$(AMI_DIR_OF)" ]
  mkdir -p "$(AMI_DIR_OF)"
  run guard_ami sA 'ls'; [ "$status" -eq 0 ]; allowed
  [ -z "$(ls -A "$(AMI_DIR_OF)")" ]
  [ "$(fake_requests)" -eq 0 ]
}

@test "AMI shadow: sentinel present, fake up — rm -rf x writes a destructive row with p from FAKE_P, would_ask by the 0.326 cut, guard allow, mode shadow, acted null, state_inputs.operator_message recorded after a prior prompt through lease-board.py; nothing is emitted (the command goes through)" {
  ami_on_with_fake FAKE_P=0.4
  mkdir -p "$BATS_TEST_TMPDIR/transcripts"
  printf '{"type":"user","cwd":"/w","gitBranch":"fix/x","message":{"role":"user","content":"clean up the scratch files"}}\n' > "$BATS_TEST_TMPDIR/transcripts/sA.jsonl"
  prompt_as sA "clean up the scratch files"
  run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]; allowed
  [ "$(fake_requests)" -eq 1 ]
  [ "$(ami_rows_count)" -eq 1 ]
  run ami_row 1 '(r["question"], r["p"], r["threshold"], r["would_ask"], r["guard"], r["mode"], r["acted"], r["unanswered"], r["device"], r["session"], r["command_head"], r["state_inputs"]["operator_message"], r["git_branch"], r["latency_ms"] > 0, r["input_tokens"] >= 1, r["state_truncated"], len(r["state_sha"]), r["tool_use_id"])'
  [ "$output" = "('destructive', 0.4, 0.326, True, 'allow', 'shadow', None, None, 'mps', 'sA', 'rm -rf x', 'recorded', 'fix/x', True, True, False, 64, 'toolu_sA')" ] || { echo "$output"; return 1; }
  FAKE_LOG="$BATS_TEST_TMPDIR/low.log" ami_on_with_fake FAKE_P=0.1
  run guard_ami sA 'rm -rf x'; allowed
  run ami_row 2 '(r["p"], r["would_ask"])'
  [ "$output" = "(0.1, False)" ] || { echo "$output"; return 1; }
}

@test "AMI: a denied command (git push origin main in target/) is denied and no request reaches the fake — the tier runs after the deterministic guard" {
  ami_on_with_fake FAKE_P=0.4
  run guard_ami sA 'git push origin main' "$T"; denied
  [ "$(fake_requests)" -eq 0 ]
  [ "$(ami_rows_count)" -eq 0 ]
}

@test "AMI: a visitor (DIRECT_CALL_ID) makes no request and writes no row" {
  ami_on_with_fake FAKE_P=0.4
  DIRECT_CALL_ID=dc1 run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]; allowed
  [ "$(fake_requests)" -eq 0 ]
  [ "$(ami_rows_count)" -eq 0 ]
  [ ! -e "$(AMI_DIR_OF)/session-sA.json" ]
}

@test "AMI off is conservative and loud once: port closed — row unanswered down, the command goes through, the emitted JSON carries systemMessage and additionalContext with the once sentence; the second call carries neither; a stale heartbeat gives supervisor gone in both" {
  mkdir -p "$(AMI_DIR_OF)"; touch "$(AMI_DIR_OF)/on"
  ami_daemon_json "$(free_port)" up
  run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]
  case "$output" in *'"permissionDecision"'*) echo "must go through: $output"; return 1 ;; esac
  run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["systemMessage"]); print(d["hookSpecificOutput"]["additionalContext"])' "$output"
  [ "${lines[0]}" = "The AMI is on but its daemon is not answering (down) — /frame-jack on starts it again" ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "${lines[0]}" ]
  run ami_row 1 '(r["question"], r["unanswered"], r["p"], r["guard"])'
  [ "$output" = "('destructive', 'down', None, 'allow')" ] || { echo "$output"; return 1; }
  run guard_ami sA 'rm -rf y'; [ "$status" -eq 0 ]; allowed        # warned once: nothing emitted now
  run ami_row 2 'r["unanswered"]'; [ "$output" = down ]
  python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); assert c["unanswered"]=={"down": 2} and "down" in c["warned"], c' "$(AMI_DIR_OF)/session-sA.json"
  ami_daemon_json "$(free_port)" up 200                              # the supervisor stopped writing its heartbeat
  run guard_ami sA 'rm -rf z'; [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["systemMessage"]); print(d["hookSpecificOutput"]["additionalContext"])' "$output"
  [ "${lines[0]}" = "The AMI is on but its supervisor is gone — /frame-jack off, then /frame-jack on" ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "${lines[0]}" ]
  run ami_row 3 'r["unanswered"]'; [ "$output" = "supervisor gone" ]
  run guard_ami sA 'rm -rf z'; allowed
  run ami_row 4 'r["unanswered"]'; [ "$output" = "supervisor gone" ]
}

@test "AMI: daemon.json state battery — row unanswered battery, no request; starting — unanswered starting" {
  ami_on_with_fake FAKE_P=0.4
  ami_daemon_json "$FAKE_PORT" battery
  run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]; allowed
  run ami_row 1 '(r["question"], r["unanswered"])'; [ "$output" = "('destructive', 'battery')" ] || { echo "$output"; return 1; }
  ami_daemon_json "$FAKE_PORT" starting
  run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]; allowed
  run ami_row 2 'r["unanswered"]'; [ "$output" = starting ]
  [ "$(fake_requests)" -eq 0 ]
}

@test "AMI: FAKE_DELAY_MS=3000 with request_timeout_ms 500 — unanswered timeout and the hook finishes under 2 s; three in a row trip the breaker: the fourth is unanswered tripped with no request and the counters carry breaker.tripped_until" {
  ami_on_with_fake FAKE_DELAY_MS=3000
  ami_daemon_json "$FAKE_PORT" up 1 500
  t0="$(secs)"
  run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]; allowed
  t1="$(secs)"
  python3 -c 'import sys; el=float(sys.argv[2])-float(sys.argv[1]); assert el < 2, el' "$t0" "$t1"
  run ami_row 1 '(r["question"], r["unanswered"])'; [ "$output" = "('destructive', 'timeout')" ] || { echo "$output"; return 1; }
  run guard_ami sA 'rm -rf x'; allowed
  run guard_ami sA 'rm -rf x'; allowed
  run ami_row 3 'r["unanswered"]'; [ "$output" = timeout ]
  run guard_ami sA 'rm -rf x'; allowed
  run ami_row 4 'r["unanswered"]'; [ "$output" = tripped ]
  python3 -c 'import json,sys,time; c=json.load(open(sys.argv[1])); b=c["breaker"]
assert b["tripped_until"] > time.time() + 200 and b["trips"] == 1, b
assert c["unanswered"] == {"timeout": 3, "tripped": 1}, c["unanswered"]' "$(AMI_DIR_OF)/session-sA.json"
  sleep 3.5                                                           # the three slow requests finish in the fake
  [ "$(fake_requests)" -eq 3 ]                                        # the fourth call sent nothing
}

@test "AMI budget: AMI_TEST_DEADLINE_SECS=0.2 — unanswered budget, no request, and the guard's own additionalContext warning for a contested-path command is still emitted" {
  guard_leases; W="$DAEDALUS_HOME/worktrees/01/thing"
  ami_on_with_fake FAKE_P=0.4
  run guard_ami sA 'echo x > hooks/capture.py' "$W"; denied        # the first cross-lease stop
  [ "$(fake_requests)" -eq 0 ]
  AMI_TEST_DEADLINE_SECS=0.2 run guard_ami sA 'echo x > hooks/capture.py' "$W"; [ "$status" -eq 0 ]
  case "$output" in *'"permissionDecision"'*) echo "second must pass: $output"; return 1 ;; *"window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run ami_row -1 '(r["question"], r["unanswered"], r["guard"] != "allow")'
  [ "$output" = "('destructive', 'budget', True)" ] || { echo "$output"; return 1; }
  [ "$(fake_requests)" -eq 0 ]
}

@test "AMI: two guard hooks at once against FAKE_DELAY_MS=400 do not overlap in the fake's log; the second row's queued_ms is above zero" {
  ami_on_with_fake FAKE_DELAY_MS=400
  guard_ami sA 'rm -rf x' > "$BATS_TEST_TMPDIR/o1" 2>&1 3>&- & P1=$!
  guard_ami sA 'rm -rf y' > "$BATS_TEST_TMPDIR/o2" 2>&1 3>&- & P2=$!
  wait "$P1" "$P2"
  [ ! -s "$BATS_TEST_TMPDIR/o1" ] && [ ! -s "$BATS_TEST_TMPDIR/o2" ]
  run python3 -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, rows
rows.sort(key=lambda r: r["t0"])
assert rows[0]["t1"] <= rows[1]["t0"], ("overlap", rows)
dec = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
assert len(dec) == 2 and all(r["unanswered"] is None and r["question"] == "destructive" for r in dec), dec
q = sorted(r["queued_ms"] for r in dec)
assert q[1] > 0, q
print("ok")' "$BATS_TEST_TMPDIR/fake.log" "$(AMI_DIR_OF)/decisions/$(date +%Y-%m-%d).jsonl"
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "AMI counters: after six calls asked.destructive is 6, no .tmp is left under state/ami, and the band object from amilib.board_ami reads the same numbers" {
  ami_on_with_fake FAKE_P=0.5
  for i in 1 2 3 4 5 6; do run guard_ami sA "rm -rf x$i"; [ "$status" -eq 0 ]; allowed; done
  [ "$(fake_requests)" -eq 6 ]
  run python3 -c 'import json, os, sys
sys.path.insert(0, sys.argv[1]); import amilib as a
from pathlib import Path
root = Path(sys.argv[1]).parent
c = json.load(open(root / "state/ami/session-sA.json"))
assert c["asked"] == {"destructive": 6, "suite": 0} and c["would_ask"] == 6, c
assert c["latency_ms"][1] == 6 and c["latency_ms"][0] > 0, c["latency_ms"]
assert not [f for f in os.listdir(root / "state/ami") if f.endswith(".tmp")]
b = a.board_ami(root, "sA")
assert b["asked"] == 6 and b["would_ask"] == 6 and b["unanswered"] == 0 and b["state"] == "on" and b["median_ms"] > 0, b
print("ok")' "$DAEDALUS_HOME/core"
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "AMI: an exception inside amilib (a counters file that is a directory) leaves the guard's decision standing, writes an unanswered error row and one stderr line; the hook exits 0" {
  ami_on_with_fake FAKE_P=0.4
  mkdir -p "$(AMI_DIR_OF)/session-sA.json"
  run guard_ami sA 'rm -rf x'; [ "$status" -eq 0 ]
  case "$output" in *'"permissionDecision"'*) echo "the guard's decision must stand: $output"; return 1 ;; esac
  case "$output" in *"daedalus: the AMI tier could not run"*) : ;; *) echo "stderr must say so: $output"; return 1 ;; esac
  [ "$(printf '%s' "$output" | grep -c 'the AMI tier could not run')" -eq 1 ]
  run ami_row -1 '(r["question"], r["unanswered"].startswith("error "))'
  [ "$output" = "('destructive', True)" ] || { echo "$output"; return 1; }
}

@test "the operator message is recorded at UserPromptSubmit by lease-board.py with the transcript offset record_prompt computed, only while the sentinel is present" {
  mkdir -p "$(AMI_DIR_OF)" "$BATS_TEST_TMPDIR/transcripts"
  printf '{"type":"user","message":{"role":"user","content":"first"}}\n{"type":"assistant","message":{"role":"assistant","content":[]}}\npartial' > "$BATS_TEST_TMPDIR/transcripts/sA.jsonl"
  prompt_as sA "do the thing"
  [ ! -e "$(AMI_DIR_OF)/session-sA.json" ]
  [ -s "$BATS_TEST_TMPDIR/transcripts/sA.jsonl.daedalus-prompts" ]    # record_prompt still ran
  touch "$(AMI_DIR_OF)/on"
  prompt_as sA "do the thing"
  run python3 -c 'import json, sys
c = json.load(open(sys.argv[1])); o = c["operator"]
data = open(sys.argv[2], "rb").read(); size = data.rfind(b"\n") + 1
rec = [json.loads(l) for l in open(sys.argv[2] + ".daedalus-prompts") if l.strip()][-1]
assert o["text"] == "do the thing" and o["transcript_offset"] == size == rec["size"] and o["transcript_path"] == sys.argv[2], (o, size, rec)
print("ok")' "$(AMI_DIR_OF)/session-sA.json" "$BATS_TEST_TMPDIR/transcripts/sA.jsonl"
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}
