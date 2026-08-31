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
