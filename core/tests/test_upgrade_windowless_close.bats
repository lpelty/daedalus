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
