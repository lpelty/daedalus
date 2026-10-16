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

board_as() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"hello"}' "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py" \
  | python3 -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t.strip() else "")'; }
CLOSE="At its close, \`core/lease.sh log\` prints this session's log path; when no live session holds the pen, \`core/lease.sh prime take\` gives it the pen, for hot.md and \`core/vault-commit.sh\`."

@test "every message a session holding no window is shown while the upgrade is pending — the no-window sentence of each kind, the start, the board, the Stop, lease.sh and vault-commit.sh refusals — names commands that work for it, or the operator's own-shell command; the only refusal is the documented live-holder one" {
  cp "$SRC/promote.py" "$SRC/promote.sh" "$DAEDALUS_HOME/core/"; git -C "$DAEDALUS_HOME" add -A core; cmt "$DAEDALUS_HOME" -m "promote"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  M="$BATS_TEST_TMPDIR/messages"; : > "$M"
  start s1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' >> "$M"
  board_as s1 >> "$M"
  pick_up; [ "$status" -eq 0 ] || { echo "$output"; return 1; }; printf '%s\n' "$output" >> "$M"     # window 01 holds feat/x
  board_as s1 >> "$M"
  run --separate-stderr stop s1; [ "$status" -eq 2 ] || { echo "status $status: $stderr"; return 1; }
  printf '%s\n' "$stderr" >> "$M"
  case "$stderr" in *"$CLOSE"*) : ;; *) echo "the Stop does not name the close: $stderr"; return 1 ;; esac
  # nobody holds the pen yet: s1's vault commit takes it (a terminal session); hand it back, so s2 can take it below
  env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh" >> "$M" 2>&1
  grep -qF "Nobody held the pen; this session holds it now and commits the vault; promote waits until the upgrade finishes." "$M"
  rm "$DAEDALUS_HOME/state/leases/prime.json"
  run python3 - "$DAEDALUS_HOME/core" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import leaselib as ll
for p in (("0.7.0", "restart", ll.UPGRADE_NOT_RUN % "0.7.0"), ("0.7.0", "running", "x"),
          ("0.7.0", "stopped", "upgrade to 0.7.0 incomplete: the disk is full — free some space, then start a session again"), "0.7.0"):
    s = ll.no_window_pending(p)
    assert s.endswith(ll.WINDOWLESS_CLOSE), s
    print(s)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }; printf '%s\n' "$output" >> "$M"
  # a second windowless session takes the pen first: s1 is refused, and told what works
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli other-session
  env DAEDALUS_SESSION_ID=s2 bash "$DAEDALUS_HOME/core/lease.sh" prime take >> "$M" 2>&1
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" prime take; [ "$status" -ne 0 ]
  printf '%s\n' "$output" >> "$M"; case "$output" in *"held by a live session"*) : ;; *) echo "$output"; return 1 ;; esac
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh"; [ "$status" -eq 3 ]
  printf '%s\n' "$output" >> "$M"; case "$output" in *"which is live: its next vault commit carries every window's files"*) : ;; *) echo "$output"; return 1 ;; esac
  board_as s1 >> "$M"
  # every backticked command in what s1 was shown
  run python3 - "$M" "$DAEDALUS_HOME" "$DAEDALUS_HOME/core" <<'PY'
import os, re, subprocess, sys
msgs, home = open(sys.argv[1]).read(), sys.argv[2]
sys.path.insert(0, sys.argv[3]); import upgrade as up
stop_cmds = {c for cmds in up.STOP_COMMANDS.values() for _, c in cmds}
base = {k: v for k, v in os.environ.items() if k not in ("DAEDALUS_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "CLAUDE_PID")}
seen = sorted(set(re.findall(r"`([^`]+)`", msgs)))
assert "core/lease.sh log" in seen and "core/lease.sh prime take" in seen and "core/vault-commit.sh" in seen, seen
def run(line, sid):
    env = dict(base, DAEDALUS_SESSION_ID=sid) if sid else base
    return subprocess.run(["bash", "-c", line], cwd=home, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL)
out = []
for cmd in seen:
    if cmd.startswith("cd %s && " % home):                          # the operator's own shell
        r = run(cmd, None); assert r.returncode == 0, (cmd, r.stdout, r.stderr); out.append("operator ok: " + cmd)
    elif cmd == "core/lease.sh log":
        r = run(cmd, "s1"); assert r.returncode == 0 and r.stdout.startswith("vault/sessions/"), (cmd, r.stdout, r.stderr)
        out.append("s1 ok: " + cmd)
    elif cmd in ("core/lease.sh prime take", "core/vault-commit.sh"):
        out.append("held by live s2, documented: " + cmd)      # run below, once the holder is gone
    elif cmd.startswith("## "):
        out.append("a heading the log carries, not a command: " + cmd)
    elif cmd in stop_cmds or cmd.startswith("python3 core/upgrade.py"):
        out.append("stop command (its own audit): " + cmd)
    else:
        raise AssertionError("a command no audit covers: %r" % cmd)
print("\n".join(out))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # the holder goes: the two commands the refusals named work for s1 now
  kill "$P2"; wait "$P2" 2>/dev/null || true
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" prime take; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'h\n' > "$DAEDALUS_HOME/vault/hot.md"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # the Stop blocked once; it does not block again after the pen moved
  run --separate-stderr stop s1; [ "$status" -eq 0 ] || { echo "re-blocked: $stderr"; return 1; }
  case "$output" in *"$CLOSE"*) : ;; *) echo "the note is missing: $output"; return 1 ;; esac
}

@test "vault-commit.sh for a session holding no window: behind a live holder it is told in one line that the holder's commit carries its files (exit 3); once the holder has ended, or when nobody holds the pen, it takes the pen and commits" {
  mkdir -p "$DAEDALUS_HOME/state/leases"
  P="$(live_pid)"; registry_entry "$P" s1
  pa="$(live_pid)"; registry_entry "$pa" sA interactive cli holder-a
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 01 "{\"lease\":\"01\",\"session_id\":\"sA\",\"worktree\":\"worktrees/01\",\"pid\":$pa,\"proc_started\":$(ps_ms "$pa")}"
  touch "$DAEDALUS_HOME/state/leases/01.seen"
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh"; [ "$status" -eq 3 ]
  [ "$output" = "daedalus: The vault is left for the pen's holder, window 01, which is live: its next vault commit carries every window's files, this session's included, and once it ends the next close takes the pen and commits them." ] || { echo "$output"; return 1; }
  kill "$pa"; wait "$pa" 2>/dev/null || true
  printf 'h\n' > "$DAEDALUS_HOME/vault/hot.md"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in "daedalus: The pen's holder, window 01, has ended; this session holds the pen now and commits the vault; promote waits until the upgrade finishes."*"committed: "*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("taken_without_window"))' "$DAEDALUS_HOME/state/leases/prime.json")" = s1 ]
  rm "$DAEDALUS_HOME/state/leases/prime.json"; printf 'h2\n' > "$DAEDALUS_HOME/vault/hot.md"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/vault-commit.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in "daedalus: Nobody held the pen; this session holds it now and commits the vault"*"committed: "*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the board: with no window open, the lead names the close for a session holding no window once; a window sees why the pen is not its — 'held by a session holding no window'; lease.sh log and prime take with no state/leases/ yet name what works" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli first-one
  run start s1; [ "$status" -eq 0 ]
  run board_as s1; [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF "$CLOSE")" -eq 1 ] || { echo "$output"; return 1; }
  env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" prime take >/dev/null
  pick_up; [ "$status" -eq 0 ] || { echo "$output"; return 1; }           # window 01 now exists
  run board_as s1
  [ "$(printf '%s\n' "$output" | grep -cF "$CLOSE")" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"You hold the pen, with no window: hot.md and \`core/vault-commit.sh\` are yours."*) : ;; *) echo "$output"; return 1 ;; esac
  run env DAEDALUS_SESSION_ID=sZ bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"The pen is held by a session holding no window (peer name first-one)."*) : ;; *) echo "$output"; return 1 ;; esac
  rm -rf "$DAEDALUS_HOME/state/leases"
  for c in log "prime take"; do
    # shellcheck disable=SC2086
    run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" $c; [ "$status" -ne 0 ]
    case "$output" in *"the upgrade has not run, so no session-log number can be reserved yet; hot.md and \`core/vault-commit.sh\` work now. Ask the operator to start a session in this home, then run \`core/lease.sh log\` again."*) : ;; *) echo "$c: $output"; return 1 ;; esac
  done
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" list; [ "$status" -ne 0 ]
  case "$output" in *"the upgrade has not run; start a session in this home"*) : ;; *) echo "$output"; return 1 ;; esac
}
