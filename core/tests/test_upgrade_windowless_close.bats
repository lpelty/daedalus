#!/usr/bin/env bats
# A session that started while the upgrade was pending holds no window (the upgrade's safety copy of target/ must
# read target/'s repositories before anything changes them), and it must still be able to close: its session-log
# number, the pen when no live session holds it, hot.md and the vault commit. Here: that close changes nothing the
# safety copy protects, and every message such a session is shown names a command that works for it.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() { upgrade_fixture; export PYTHONDONTWRITEBYTECODE=1; }
teardown() { teardown_live; }

# manifest — every path under target/ (each repository's .git/ included): path, mode, size, mtime, sha256
manifest() {
  python3 - "$DAEDALUS_HOME/target" <<'PY'
import hashlib, os, sys
base = sys.argv[1]
for d, dirs, files in os.walk(base):
    dirs.sort()
    for name in sorted(dirs + files):
        p = os.path.join(d, name); st = os.lstat(p)
        h = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) and not os.path.islink(p) else "-"
        print(os.path.relpath(p, base), oct(st.st_mode), st.st_size, st.st_mtime_ns, h)
PY
}

@test "the close of a session holding no window while the safety copy is not taken — lease.sh log, prime take, hot.md, core/vault-commit.sh — runs no git in target/ or worktrees/ and leaves every byte, mode and mtime under target/ as it was; no stamp, and create/claim stay refused" {
  mkdir -p "$DAEDALUS_HOME/state/leases"
  # the window that held the pen before the pull is gone (its process ended); its worktree is still there
  git -C "$T" worktree add -q -b lease/01 "$DAEDALUS_HOME/worktrees/01/thing" main
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 01 '{"lease":"01","session_id":"sOld","worktree":"worktrees/01","pid":999999,"proc_started":1,"trunks":{"thing":"main"}}'
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sOld","bound_at":"2026-01-01T00:00:00","history":[]}'
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import upgrade as up; from pathlib import Path; print(up.copy_missing(Path(sys.argv[1]).parent))' "$DAEDALUS_HOME/core"
  [ "$output" = True ] || { echo "the copy is not missing: $output"; return 1; }
  before="$(manifest)"
  real="$(command -v git)"; mkdir -p "$BATS_TEST_TMPDIR/shim"
  printf '#!/bin/bash\nprintf "%%s\\t%%s\\n" "$PWD" "$*" >> "%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/git.log" "$real" > "$BATS_TEST_TMPDIR/shim/git"
  chmod +x "$BATS_TEST_TMPDIR/shim/git"; : > "$BATS_TEST_TMPDIR/git.log"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  export PATH="$BATS_TEST_TMPDIR/shim:$PATH"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" log; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" prime take; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"holds the pen now, with no window"*"promote waits until the upgrade finishes"*) : ;; *) echo "$output"; return 1 ;; esac
  printf -- '---\ntype: rolling-state\n---\n\n# Hot\nthe stall, the cleanup owed\n' > "$DAEDALUS_HOME/vault/hot.md"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh" -m "close of a windowless session"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$DAEDALUS_HOME/vault" log -1 --format=%s)" = "close of a windowless session" ]
  run python3 - "$BATS_TEST_TMPDIR/git.log" "$DAEDALUS_HOME" <<'PY'
import os, sys
home = os.path.realpath(sys.argv[2]); bad = []
for line in open(sys.argv[1]):
    cwd, _, args = line.rstrip("\n").partition("\t")
    words = args.split(" "); where = cwd
    if "-C" in words and words.index("-C") + 1 < len(words):
        where = os.path.join(cwd, words[words.index("-C") + 1])
    where = os.path.realpath(where)
    if any(where == os.path.join(home, d) or where.startswith(os.path.join(home, d) + "/") for d in ("target", "worktrees")):
        bad.append(line.strip())
print("\n".join(bad) or "none")
PY
  [ "$output" = none ] || { echo "git ran in target/ or worktrees/: $output"; return 1; }
  [ "$(manifest)" = "$before" ] || { diff <(printf '%s\n' "$before") <(manifest); return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  [ "$(git -C "$T" worktree list | wc -l | tr -d ' ')" -eq 2 ]
  for c in create "claim 01"; do
    # shellcheck disable=SC2086
    run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" $c
    [ "$status" -ne 0 ] || { echo "$c was allowed: $output"; return 1; }
  done
  [ "$(manifest)" = "$before" ]
}

start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' "$1" "$BATS_TEST_TMPDIR" "$1" | python3 "$DAEDALUS_HOME/core/session-start.py"; }
stop() { printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
write_as() { printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
guard_as() { printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"%s","cwd":"%s","tool_input":{"command":%s}}' \
    "$1" "$3" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" | python3 "$DAEDALUS_HOME/core/guard-bash.py"; }
tp() { env DAEDALUS_SESSION_ID="$1" bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"; }
# the session that pulled: the upgrade stopped on an in-flight branch at its start, so it holds no window; it takes the pen
windowless_prime() {
  cp "$SRC/promote.py" "$SRC/promote.sh" "$SRC/sync-target.sh" "$DAEDALUS_HOME/core/"
  git -C "$DAEDALUS_HOME" add -A core; cmt "$DAEDALUS_HOME" -m "promote"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$DAEDALUS_HOME/state/leases" ] && [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" prime take; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
promotion() {   # promotion <id> [pushed] — a promotion of window 01 with its scratch worktree
  local d="$DAEDALUS_HOME/state/promote/$1"; mkdir -p "$d"
  git -C "$T" worktree add -q --detach "$d/thing" origin/main
  printf '{"lease": "01", "promote_id": "%s", "prepared_ts": 1}\n' "$1" > "$d/prepared.json"
  [ -z "${2:-}" ] || printf '{"lease": "01"}\n' > "$d/pushed"
}

@test "while the upgrade is pending the pen gives a session holding no window the vault, not a tree: target_path and sync-target refuse, a write in target/ is denied and hot.md allowed, worktree surgery in target/ is denied, promote waits, --clean removes only pushed scratch" {
  windowless_prime
  run --separate-stderr tp s1; [ "$status" -ne 0 ]
  case "$stderr" in *"started before the upgrade to 0.7.0 finished"*) : ;; *) echo "$stderr"; return 1 ;; esac
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]; case "$output" in *"started before the upgrade to 0.7.0 finished"*) : ;; *) echo "$output"; return 1 ;; esac
  run write_as s1 "$T/new.txt"; case "$output" in *'"deny"'*) : ;; *) echo "target/ write allowed: $output"; return 1 ;; esac
  run write_as s1 "$DAEDALUS_HOME/vault/hot.md"; case "$output" in *'"deny"'*) echo "hot.md denied: $output"; return 1 ;; *) : ;; esac
  run guard_as s1 "git worktree prune" "$T"; case "$output" in *'"deny"'*) : ;; *) echo "prune allowed: $output"; return 1 ;; esac
  run env DAEDALUS_SESSION_ID=s1 CLAUDECODE=1 bash "$DAEDALUS_HOME/core/promote.sh" 01
  [ "$status" -ne 0 ]
  case "$output" in *"This session holds the pen but no window, and the upgrade to 0.7.0 has not finished: promote changes target/, which the upgrade's safety copy protects, so it waits until the upgrade finishes. hot.md and \`core/vault-commit.sh\` work now."*) : ;; *) echo "$output"; return 1 ;; esac
  promotion 01-20261016-100000-aaa
  run env DAEDALUS_SESSION_ID=s1 CLAUDECODE=1 bash "$DAEDALUS_HOME/core/promote.sh" 01 --clean
  [ -d "$DAEDALUS_HOME/state/promote/01-20261016-100000-aaa/thing" ] || { echo "unpushed scratch removed: $output"; return 1; }
  promotion 01-20261016-110000-bbb pushed
  run env DAEDALUS_SESSION_ID=s1 CLAUDECODE=1 bash "$DAEDALUS_HOME/core/promote.sh" 01 --clean
  [ ! -d "$DAEDALUS_HOME/state/promote/01-20261016-110000-bbb/thing" ] || { echo "pushed scratch kept: $output"; return 1; }
  [ -d "$DAEDALUS_HOME/state/promote/01-20261016-100000-aaa/thing" ]
}

@test "after the stamp a session that took the pen without a window still builds in no tree until it claims one: target_path names claim and says it holds the pen, target/ stays denied, hot.md allowed, its Stop never reaches the trunk comparison; once it claims, it builds in its worktree and keeps the pen" {
  windowless_prime
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"; git -C "$T" checkout -q main
  run --separate-stderr tp s1; [ "$status" -ne 0 ]
  case "$stderr" in *"This session holds no window"*"It holds the pen: hot.md and \`core/vault-commit.sh\` are its"*"core/lease.sh create"*"claim <NN>"*) : ;; *) echo "$stderr"; return 1 ;; esac
  run write_as s1 "$T/new.txt"; case "$output" in *'"deny"'*) : ;; *) echo "target/ write allowed: $output"; return 1 ;; esac
  run write_as s1 "$DAEDALUS_HOME/vault/hot.md"; case "$output" in *'"deny"'*) echo "hot.md denied: $output"; return 1 ;; *) : ;; esac
  run --separate-stderr stop s1
  case "$output$stderr" in *"does not apply in a lease worktree"*|*"origin/main moved"*|*"commits on"*) echo "$output $stderr"; return 1 ;; esac
  case "$stderr" in *"It holds the pen"*"claim"*) : ;; *) echo "status $status: $output $stderr"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" create; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" claim 01; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run tp s1; [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/worktrees/01/thing" ] || { echo "$output"; return 1; }
  [ "$(lease_json prime session_id)" = s1 ]
}

@test "a session that kept the pen after releasing its window: while the upgrade is pending it builds in no tree either; after the stamp it resolves target/<name> as before" {
  mkdir -p "$DAEDALUS_HOME/state/leases"
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sP","history":[]}'
  run --separate-stderr tp sP; [ "$status" -ne 0 ]
  case "$stderr" in *"started before the upgrade to 0.7.0 finished"*) : ;; *) echo "$stderr"; return 1 ;; esac
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  run tp sP; [ "$status" -eq 0 ]; [ "$output" = "$T" ] || { echo "$output"; return 1; }
}
