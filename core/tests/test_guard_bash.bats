#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/state"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/guard-bash.py" "$DAEDALUS_HOME/core/"
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
}

guard() {  # guard <command> [cwd]
  local cwd="${2:-$DAEDALUS_HOME}"
  printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":%s}}' \
    "$cwd" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | python3 "$DAEDALUS_HOME/core/guard-bash.py"
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

@test "commit on target main denied unless a branch is created first; vault commit allowed" {
  run guard 'git commit -m x' "$T"; denied
  run guard 'git -C target/thing commit -m x'; denied
  run guard 'git switch -c fix/x && git commit -m x' "$T"; allowed
  run guard 'git checkout -b fix/x && git commit -m x' "$T"; allowed
  run guard 'git -C vault commit -m x'; allowed
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
  run guard 'git -C vault commit -m x'; allowed
  run guard 'git -C vault push origin main'; allowed
  chmod 644 "$DAEDALUS_HOME/config.yaml"
  run guard 'git push origin fix/x' "$T"; allowed
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
