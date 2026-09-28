#!/usr/bin/env bats
# Distribution integrity against git's own hiding mechanisms (spec §6.1): the
# check compares the files on disk under core/, CLAUDE.md and
# .claude/settings.json with HEAD's tree by content, so no index flag, git
# config, exclude file or GIT_* variable can make a modified distribution read
# as clean. Each case: the launcher refuses with exit 2 and claude never starts.
# A fake claude (fixtures/caller/bin/claude) is first on PATH.
bats_require_minimum_version 1.5.0
load fixtures/caller/setup.bash
setup() { caller_fixture; direct_call "callers: Peer"; }
teardown() { teardown_live; }

# refused <path fragment> — the call is refused as modified naming the path,
# nothing launched, no receipt; doctor reports it MISSING.
refused() {
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ] || { echo "exit $status: $output"; return 1; }
  case "$output" in *"Distribution code is modified ("*"$1"*"); restore it"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
  [ ! -d "$DAEDALUS_HOME/state/direct-calls" ]
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"MISSING  distribution code is modified: "*"$1"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a tracked file hidden by skip-worktree is still modified" {
  git -C "$DAEDALUS_HOME" update-index --skip-worktree core/agents/refuter.md
  printf '# local patch\n' >> "$DAEDALUS_HOME/core/agents/refuter.md"
  [ -z "$(git -C "$DAEDALUS_HOME" status --porcelain)" ]   # git status is blind to it
  refused core/agents/refuter.md
}

@test "a tracked file hidden by assume-unchanged is still modified" {
  git -C "$DAEDALUS_HOME" update-index --assume-unchanged core/agents/refuter.md
  printf '# local patch\n' >> "$DAEDALUS_HOME/core/agents/refuter.md"
  [ -z "$(git -C "$DAEDALUS_HOME" status --porcelain)" ]
  refused core/agents/refuter.md
}

@test "a new file hidden by status.showUntrackedFiles=no is still modified" {
  git -C "$DAEDALUS_HOME" config status.showUntrackedFiles no
  printf 'extra\n' > "$DAEDALUS_HOME/core/agents/extra.md"
  [ -z "$(git -C "$DAEDALUS_HOME" status --porcelain)" ]
  refused core/agents/extra.md
}

@test "a new file hidden by .git/info/exclude, or by a core/.gitignore that ignores itself, is still modified" {
  printf 'core/agents/extra.md\n' >> "$DAEDALUS_HOME/.git/info/exclude"
  printf 'extra\n' > "$DAEDALUS_HOME/core/agents/extra.md"
  [ -z "$(git -C "$DAEDALUS_HOME" status --porcelain)" ]
  refused core/agents/extra.md
  rm "$DAEDALUS_HOME/core/agents/extra.md"
  printf '.gitignore\nsneak.sh\n' > "$DAEDALUS_HOME/core/.gitignore"
  printf 'echo hi\n' > "$DAEDALUS_HOME/core/sneak.sh"
  [ -z "$(git -C "$DAEDALUS_HOME" status --porcelain)" ]
  refused core/sneak.sh
}

@test "an ignored module that Python would import ahead of the source (a .pyc or .so beside it) is modified" {
  printf 'x' > "$DAEDALUS_HOME/core/verifylib.pyc"
  refused core/verifylib.pyc
  rm "$DAEDALUS_HOME/core/verifylib.pyc"
  printf 'x' > "$DAEDALUS_HOME/core/verifylib.cpython-39-darwin.so"
  refused core/verifylib.cpython-39-darwin.so
}

@test "GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE in the caller's environment cannot point the check at another repository" {
  printf '# local patch\n' >> "$DAEDALUS_HOME/core/agents/refuter.md"
  # A decoy repository whose HEAD holds the patched home.
  decoy="$BATS_TEST_TMPDIR/decoy"; git clone -q "$DAEDALUS_HOME" "$decoy"
  cp -R "$DAEDALUS_HOME/core/." "$decoy/core/"
  git -C "$decoy" add -A && git -C "$decoy" -c user.email=t@x -c user.name=t commit -q -m decoy
  GIT_DIR="$decoy/.git" GIT_WORK_TREE="$DAEDALUS_HOME" run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ] || { echo "exit $status: $output"; return 1; }
  case "$output" in *"Distribution code is modified (core/agents/refuter.md)"*) : ;; *) echo "$output"; return 1 ;; esac
  GIT_INDEX_FILE="$BATS_TEST_TMPDIR/idx" run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  [ "$(calls)" -eq 0 ]
}

@test "Python bytecode caches and Finder metadata are not distribution code, and nothing the launcher runs reads them: the call launches with bytecode off and the cache redirected" {
  mkdir -p "$DAEDALUS_HOME/core/__pycache__"
  printf 'x' > "$DAEDALUS_HOME/core/__pycache__/verifylib.cpython-39.pyc"
  printf 'x' > "$DAEDALUS_HOME/core/agents/.DS_Store"   # Finder metadata, loaded by nothing
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"OK       distribution code: core/, CLAUDE.md, .claude/settings.json unmodified"*) : ;; *) echo "$output"; return 1 ;; esac
  run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$(calls)" -eq 1 ]
  python3 - "$FAKE_CLAUDE_DIR/1.env.json" <<'PY'
import json, sys
env = json.load(open(sys.argv[1]))
assert env.get("PYTHONDONTWRITEBYTECODE") == "1", env
prefix = env.get("PYTHONPYCACHEPREFIX") or ""
assert prefix.startswith("/dev/null/"), env
PY
}

@test "a tracked file deleted from disk and hidden by skip-worktree is modified" {
  rm "$DAEDALUS_HOME/core/agents/refuter.md"
  git -C "$DAEDALUS_HOME" update-index --skip-worktree core/agents/refuter.md
  refused core/agents/refuter.md
}

@test "the integrity check is the first distribution code a call runs: a modified lib.sh or verifylib.py that would leave a mark when run is refused before it runs" {
  printf 'touch "%s/lib-ran"\n' "$BATS_TEST_TMPDIR" >> "$DAEDALUS_HOME/core/lib.sh"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"Distribution code is modified (core/lib.sh); restore it"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$BATS_TEST_TMPDIR/lib-ran" ] || { echo "lib.sh ran before the integrity check"; return 1; }
  git -C "$DAEDALUS_HOME" checkout -q -- core/lib.sh
  printf '\nopen("%s/py-ran", "w").close()\n' "$BATS_TEST_TMPDIR" >> "$DAEDALUS_HOME/core/verifylib.py"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"Distribution code is modified (core/verifylib.py); restore it"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$BATS_TEST_TMPDIR/py-ran" ] || { echo "verifylib.py was imported before the integrity check"; return 1; }
  [ "$(calls)" -eq 0 ]
}

@test "the checker is checked before it runs: a distcheck.py rewritten to pass everything is refused by git alone, and nothing after it runs" {
  printf 'import sys\nsys.exit(0)\n' > "$DAEDALUS_HOME/core/distcheck.py"
  printf 'touch "%s/lib-ran"\n' "$BATS_TEST_TMPDIR" >> "$DAEDALUS_HOME/core/lib.sh"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"Distribution code is modified (core/distcheck.py); restore it"*"Nothing was launched."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$BATS_TEST_TMPDIR/lib-ran" ]; [ "$(calls)" -eq 0 ]
}
