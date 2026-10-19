#!/usr/bin/env bats
# `daedalus start` and which home a command means (daedalus-start design, 2026-10-19). Fixture homes only, under
# scratch: each is core/update.py, core/start.py and core/banner.txt from the tree under test, a fake core/status.py,
# a config.yaml and VERSION. HOME and XDG_CONFIG_HOME point at scratch, so the registry and the shim are scratch
# files; `claude` is a fake on PATH that prints where it ran, its pid, its arguments and DAEDALUS_LEASE. Every
# command runs from a scratch directory: an update.py run with no --home resolves from the current directory.
bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  B="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$B/home" XDG_CONFIG_HOME="$B/xdg"
  mkdir -p "$HOME" "$B/bin" "$B/out"
  unset DAEDALUS_LEASE DAEDALUS_HOME DAEDALUS_NO_COMMAND
  export SHELL=/nonexistent          # the shim install's login-shell check falls back to this PATH at once
  cat > "$B/bin/claude" <<'EOF'
#!/bin/bash
{ echo "cwd=$(pwd -P)"; echo "pid=$$"; echo "lease=${DAEDALUS_LEASE:-}"; printf 'arg=%s\n' "$@"; } > "$CLAUDE_OUT"
echo "claude ran"
EOF
  chmod +x "$B/bin/claude"
  export PATH="$B/bin:$PATH" CLAUDE_OUT="$B/out/claude"
  REG="$XDG_CONFIG_HOME/daedalus/homes.json"
  cd "$B"
}

# home <dir> [version] — a fixture Daedalus home; its status.py prints $STATUS_JSON (exit $STATUS_EXIT, after
# $STATUS_SLEEP seconds); start.pause 0 unless the test sets it
home() {
  local h="$1"
  mkdir -p "$h/core"
  cp "$REPO/core/update.py" "$REPO/core/start.py" "$REPO/core/banner.txt" "$h/core/"
  cat > "$h/core/status.py" <<'EOF'
import os, sys, time
time.sleep(float(os.environ.get("STATUS_SLEEP", "0")))
print(os.environ.get("STATUS_JSON", '{"services": [], "checked_at": "x"}'))
sys.exit(int(os.environ.get("STATUS_EXIT", "0")))
EOF
  printf '%s\n' "${2:-0.12.0}" > "$h/VERSION"
  printf 'start:\n  pause: 0\n' > "$h/config.yaml"
}

# registry <json> — writes homes.json as given
registry() { mkdir -p "$(dirname "$REG")"; printf '%s\n' "$1" > "$REG"; }

D() { python3 "$REPO/core/update.py" "$@" </dev/null; }
ran_in() { grep -qx "cwd=$1" "$CLAUDE_OUT" || { echo "claude ran in: $(cat "$CLAUDE_OUT" 2>/dev/null || echo nowhere)"; return 1; }; }

@test "which home: the current directory's — its root, a worktree deep under it — wins over the default; outside every home, the default" {
  home "$B/daedalus"; home "$B/daedalus-lares"
  mkdir -p "$B/daedalus-lares/worktrees/01/repo/src"
  registry "{\"default\": \"main\", \"homes\": {\"main\": \"$B/daedalus\", \"lares\": \"$B/daedalus-lares\"}}"
  cd "$B/daedalus-lares"; run D start
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  ran_in "$B/daedalus-lares"
  cd "$B/daedalus-lares/worktrees/01/repo/src"; run D start
  ran_in "$B/daedalus-lares"
  cd "$B"; run D start
  ran_in "$B/daedalus"
}

@test "which home: a name wins over the current directory; an unknown name is refused naming the valid ones, exit 2, and claude never runs" {
  home "$B/daedalus"; home "$B/daedalus-lares"
  registry "{\"default\": \"main\", \"homes\": {\"main\": \"$B/daedalus\", \"lares\": \"$B/daedalus-lares\"}}"
  cd "$B/daedalus"; run D start lares
  ran_in "$B/daedalus-lares"
  rm -f "$CLAUDE_OUT"
  run D start larse
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *'"larse"'*lares*main*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CLAUDE_OUT" ]
  run D update larse
  [ "$status" -eq 2 ]
}

@test "which home: several homes and no default outside every home lists the names, exit 2; exactly one is the default; a gone path is listed as gone and never used" {
  home "$B/daedalus"; home "$B/daedalus-lares"
  registry "{\"homes\": {\"main\": \"$B/daedalus\", \"lares\": \"$B/daedalus-lares\", \"old\": \"$B/moved-away\"}}"
  run D start
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *lares*main*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CLAUDE_OUT" ]
  run D homes
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -E "^old +$B/moved-away +\(gone\)$" >/dev/null || { echo "$output"; return 1; }
  run D start old
  [ "$status" -eq 2 ]; case "$output" in *gone*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CLAUDE_OUT" ]
  rm -rf "$B/daedalus"          # one live home left (and two gone): it is the default
  run D start
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  ran_in "$B/daedalus-lares"
}

@test "homes rename and homes default edit the registry, and a bare command follows them; renaming onto a taken name is refused" {
  home "$B/daedalus"; home "$B/daedalus-lares"
  registry "{\"homes\": {\"main\": \"$B/daedalus\", \"lares\": \"$B/daedalus-lares\"}}"
  run D homes rename main work
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  run D homes rename work lares
  [ "$status" -eq 2 ]
  run D homes default work
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  run D start
  ran_in "$B/daedalus"
  run D homes default nosuch
  [ "$status" -eq 2 ]
  run D start work; ran_in "$B/daedalus"
}

@test "start: the banner (the home's own banner.txt, else the release's), the version line, one line per configured service, then claude in the home with --window as DAEDALUS_LEASE and the arguments after --" {
  home "$B/daedalus-lares"
  registry "{\"homes\": {\"lares\": \"$B/daedalus-lares\"}}"
  export STATUS_JSON='{"services": [{"stem": "hindsight", "name": "memory server", "state": "up", "detail": "answers"}, {"stem": "capture", "name": "memory capture", "state": "down", "detail": "last capture 40 min ago"}, {"stem": "ami", "name": "decider", "state": "not-set-up", "detail": "frame-jack is off"}], "checked_at": "x"}'
  run D start lares --window 3 -- --resume "two words"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  first="$(head -1 "$REPO/core/banner.txt")"
  [ "${lines[0]}" = "$first" ] || { echo "$output"; return 1; }
  case "$output" in *"Daedalus 0.12.0 · lares · $B/daedalus-lares"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"✓ memory server"*"✗ memory capture — last capture 40 min ago"*"claude ran") : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *decider*) echo "a not-set-up service was shown: $output"; return 1 ;; esac
  ran_in "$B/daedalus-lares"
  grep -qx "lease=03" "$CLAUDE_OUT"
  [ "$(grep '^arg=' "$CLAUDE_OUT")" = "$(printf 'arg=--resume\narg=two words')" ] || { cat "$CLAUDE_OUT"; return 1; }
  printf 'THIS HOME\n' > "$B/daedalus-lares/banner.txt"
  run D start lares
  [ "${lines[0]}" = "THIS HOME" ] || { echo "$output"; return 1; }
  grep -qx "lease=" "$CLAUDE_OUT"
  run D start lares --window 100
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
}

@test "start: a status.py that fails or hangs prints services: couldn't check, and claude still starts within about 2 seconds" {
  home "$B/daedalus"
  registry "{\"homes\": {\"main\": \"$B/daedalus\"}}"
  STATUS_EXIT=1 run D start
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"services: couldn't check"*"claude ran") : ;; *) echo "$output"; return 1 ;; esac
  rm "$CLAUDE_OUT"
  t0="$(python3 -c 'import time; print(time.time())')"
  STATUS_SLEEP=10 run D start
  t1="$(python3 -c 'import time; print(time.time())')"
  case "$output" in *"services: couldn't check"*"claude ran") : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 4 else 1)' "$t0" "$t1" \
    || { echo "took $t0 -> $t1"; return 1; }
}

@test "start: start.pause holds the screen that long before claude takes it; 0 skips the hold" {
  home "$B/daedalus"
  registry "{\"homes\": {\"main\": \"$B/daedalus\"}}"
  printf 'start:\n  pause: 1.2\n' > "$B/daedalus/config.yaml"
  t0="$(python3 -c 'import time; print(time.time())')"; run D start; t1="$(python3 -c 'import time; print(time.time())')"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) >= 1.2 else 1)' "$t0" "$t1" \
    || { echo "no hold: $t0 -> $t1"; return 1; }
  printf 'start:\n  pause: 0\n' > "$B/daedalus/config.yaml"
  t0="$(python3 -c 'import time; print(time.time())')"; run D start; t1="$(python3 -c 'import time; print(time.time())')"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 1.0 else 1)' "$t0" "$t1" \
    || { echo "held anyway: $t0 -> $t1"; return 1; }
}

@test "the shim: installed once, it serves every home — daedalus version inside a home names that home, not the default; daedalus start becomes claude in the same process" {
  home "$B/daedalus"; home "$B/daedalus-lares"
  git init -q "$B/daedalus"; git init -q "$B/daedalus-lares"
  python3 "$B/daedalus/core/update.py" --install-shim --home "$B/daedalus" </dev/null >/dev/null
  python3 "$B/daedalus-lares/core/update.py" --install-shim --home "$B/daedalus-lares" </dev/null >/dev/null
  SHIM="$HOME/.local/bin/daedalus"
  run "$SHIM" homes
  printf '%s\n' "$output" | grep -qE "^main +$B/daedalus$" && printf '%s\n' "$output" | grep -qE "^lares +$B/daedalus-lares$" \
    || { echo "$output"; return 1; }
  "$SHIM" homes default main >/dev/null
  cd "$B/daedalus-lares"; run "$SHIM" version
  case "$output" in "Daedalus 0.12.0 (home $B/daedalus-lares"*) : ;; *) echo "$output"; return 1 ;; esac
  cd "$B"; run "$SHIM" version
  case "$output" in "Daedalus 0.12.0 (home $B/daedalus"[!-]*) : ;; *) echo "$output"; return 1 ;; esac
  run bash -c 'echo "outer=$$"; exec "$1" start lares' _ "$SHIM"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  ran_in "$B/daedalus-lares"
  [ "pid=${lines[0]#outer=}" = "$(grep '^pid=' "$CLAUDE_OUT")" ] || { echo "$output"; cat "$CLAUDE_OUT"; return 1; }
}

@test "the shim: an old single-home shim this install wrote, serving another live home still on the older release, becomes the one for every home with both registered and still reaches the older home, by name and from inside it; a file it did not write and a newer revision are never touched" {
  home "$B/daedalus"; home "$B/daedalus-lares" 0.11.0
  git -C "$REPO" show v0.11.0:core/update.py > "$B/daedalus-lares/core/update.py"     # the release before this one
  git init -q "$B/daedalus-lares"
  SHIM="$HOME/.local/bin/daedalus"; mkdir -p "$(dirname "$SHIM")"
  printf '#!/usr/bin/env bash\n# daedalus shim — installed by core/setup.sh for the home below; safe to delete\nexec python3 "%s/core/update.py" "$@" --home "%s"\n' \
    "$B/daedalus-lares" "$B/daedalus-lares" > "$SHIM"; chmod 755 "$SHIM"
  run python3 "$B/daedalus/core/update.py" --install-shim --home "$B/daedalus" </dev/null
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  ! grep -q "daedalus-lares" "$SHIM" || { cat "$SHIM"; return 1; }
  run "$SHIM" homes
  printf '%s\n' "$output" | grep -qE "^main +$B/daedalus$" && printf '%s\n' "$output" | grep -qE "^lares +$B/daedalus-lares$" \
    || { echo "$output"; return 1; }
  run "$SHIM" version lares
  case "$output" in "Daedalus 0.11.0 (home $B/daedalus-lares"*) : ;; *) echo "$output"; return 1 ;; esac
  mv "$B/daedalus/core/update.py" "$B/update.aside"      # only the older home left: from inside it, still reached
  cd "$B/daedalus-lares"; run "$SHIM" version
  case "$output" in "Daedalus 0.11.0 (home $B/daedalus-lares"*) : ;; *) echo "$output"; return 1 ;; esac
  cd "$B"; mv "$B/update.aside" "$B/daedalus/core/update.py"
  sed 's/^# revision [0-9]*\./# revision 99./' "$SHIM" > "$B/newer"; cp "$B/newer" "$SHIM"
  grep -q '^# revision 99\.' "$SHIM"
  run python3 "$B/daedalus/core/update.py" --install-shim --home "$B/daedalus" </dev/null
  cmp -s "$SHIM" "$B/newer" || { echo "a newer shim was rewritten: $output"; return 1; }
  printf '#!/bin/sh\necho mine\n' > "$SHIM"
  run python3 "$B/daedalus/core/update.py" --install-shim --home "$B/daedalus" </dev/null
  [ "$(cat "$SHIM")" = "$(printf '#!/bin/sh\necho mine')" ] || { echo "$output"; return 1; }
  case "$output" in *"not a shim daedalus wrote"*) : ;; *) echo "$output"; return 1 ;; esac
}
