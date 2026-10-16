#!/usr/bin/env bats
# The stop-command rule (update-command design, Decisions 10 and 23). On another deployment (2026-10-15) an upgrade
# stop asked for cleanup whose supported command needed the prime window, and no window opens until the upgrade
# finishes: the operator removed worktrees by hand. So every command a stop sentence names must work in the state
# that stop leaves — upgrade not stamped, no window, no pen — run by whoever the sentence asks, and each sentence is
# worded for its caller: a session start, or the terminal of `daedalus update` (upgrade.py --caller update).
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() {
  upgrade_fixture; export PYTHONDONTWRITEBYTECODE=1
  cp "$SRC/promote.py" "$SRC/promote.sh" "$DAEDALUS_HOME/core/"
  git -C "$DAEDALUS_HOME" add -A core; cmt "$DAEDALUS_HOME" -m "promote"     # distribution code as shipped
}
teardown() { teardown_live; }

start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' "$1" "$BATS_TEST_TMPDIR" "$1" | python3 "$DAEDALUS_HOME/core/session-start.py"; }
REFUSALS='Only the prime window|no window opens|holds no window'

@test "stop commands: every stop sentence in upgrade.py has its entry in STOP_COMMANDS, and each entry names exactly what its sentence asks — a session start, core/upgrade.py, 'pick it up' — and nothing that needs a window" {
  run python3 - "$DAEDALUS_HOME/core" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
import upgrade as up
src = open(sys.argv[1] + "/upgrade.py").read()
found = set(re.findall(r'^([A-Z_]+) = \(?"(?:upgrade to %s incomplete|Daedalus has unfinished work)', src, re.M))
found |= set(re.findall(r'^(_?[A-Z_]+) = STOPPED_WHILE %', src, re.M))
assert found, "the grep found no stop sentence"
missing = sorted(found - set(up.STOP_COMMANDS))
assert not missing, "stops with no STOP_COMMANDS entry: %s" % missing
extra = sorted(set(up.STOP_COMMANDS) - found)
assert not extra, "entries for no stop sentence: %s" % extra
def has_start(s):
    return any(w in s for w in ("start a session again", "start a new session", "next session start",
                                "and start a session again"))
for name, cmds in up.STOP_COMMANDS.items():
    s = getattr(up, name)
    names = [c for _, c in cmds]
    assert all(w in ("operator", "agent", "both") for w, _ in cmds), name
    assert (up.START in names) == has_start(s), (name, "start a session", s)
    assert (up._UPGRADE_CLI in cmds) == ("python3 core/upgrade.py" in s), (name, s)
    assert (("agent", "core/lease.sh adopt --all-unfinished") in cmds) == ("pick it up" in s), (name, s)
    for bad in ("ship it", "the usual way", "core/lease.sh create", "claim <NN>", "take the pen"):
        assert bad not in s, (name, bad, s)
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "stop commands: with the upgrade pending and no window or pen, each operator command runs from a plain shell, each agent command passes guard-bash from a session holding no window and runs, and 'start a session again' reaches the upgrade" {
  # the session that pulled holds no window: the upgrade stopped on in-flight work, 'pick it up' made window 01
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pick_up; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$DAEDALUS_HOME/state/leases/01.json" ] && [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  [ -z "$(python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("prime") or {}).get("session_id") or "")' "$DAEDALUS_HOME/state/leases/prime.json" 2>/dev/null)" ]
  # what the commands act on: a pushed promotion of window 01, a local origin/main, a twin branch, a lock file, an
  # untracked file
  d="$DAEDALUS_HOME/state/promote/01-20261015-120000-aaa"; mkdir -p "$d"
  git -C "$T" worktree add -q --detach "$d/thing" origin/main
  printf '{"lease": "01", "promote_id": "01-20261015-120000-aaa", "prepared_ts": 1}\n' > "$d/prepared.json"
  printf '{"lease": "01"}\n' > "$d/pushed"
  om="$(git -C "$T" rev-parse refs/remotes/origin/main)"
  git -C "$T" branch twin-a "$om"; git -C "$T" branch origin/main "$om"
  : > "$T/.git/left.lock"; printf 'u\n' > "$T/u.txt"
  run python3 - "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR" "$REFUSALS" <<'PY'
import json, os, re, subprocess, sys
home, tmp, refusals = sys.argv[1], sys.argv[2], re.compile(sys.argv[3])
sys.path.insert(0, home + "/core")
import upgrade as up
sha = subprocess.run(["git", "-C", home + "/target/thing", "rev-parse", "refs/remotes/origin/main"], capture_output=True, text=True).stdout.strip()
fill = {"repo": "thing", "trunk": "main", "sha": sha, "path": "u.txt", "elsewhere": tmp + "/moved-u.txt",
        "locks": "target/thing/.git/left.lock", "cmd": "status", "nn": "01"}
per = {"UNBORN": {"branch": "put-back"}, "TWINS": {"branch": "twin-a", "new": "twin-b"},
       "SHADOW": {"new": "not-origin-main"}, "GITLINK": {"path": "u2.txt", "elsewhere": tmp + "/moved-u2.txt"}}
open(home + "/target/thing/u2.txt", "w").write("u2\n")
base = {k: v for k, v in os.environ.items() if k not in ("DAEDALUS_SESSION_ID", "CLAUDE_CODE_SESSION_ID", "CLAUDECODE", "CLAUDE_PID")}
ran, starts = 0, 0
# the plain git and file commands first: they undo the states the fixture made (a local origin/main would stop
# "pick it up", as it stops the upgrade)
order = sorted(up.STOP_COMMANDS.items(), key=lambda kv: any(w != "operator" for w, _ in kv[1]))
for name, cmds in order:
    for who, cmd in cmds:
        if cmd == up.START:
            starts += 1
            continue
        line = cmd.format(**dict(fill, **per.get(name, {})))
        if who in ("agent", "both"):
            payload = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "s1", "cwd": home,
                       "tool_input": {"command": line}}
            g = subprocess.run([sys.executable, home + "/core/guard-bash.py"], input=json.dumps(payload),
                               capture_output=True, text=True, env=base)
            said = g.stdout + g.stderr
            assert g.returncode == 0 and '"deny"' not in said and not refusals.search(said), (name, line, said)
            r = subprocess.run(["bash", "-c", line], cwd=home, capture_output=True, text=True,
                               env=dict(base, CLAUDECODE="1", CLAUDE_CODE_SESSION_ID="s1"), stdin=subprocess.DEVNULL)
            assert r.returncode == 0 and not refusals.search(r.stdout + r.stderr), (name, "agent", line, r.stdout, r.stderr)
        if who in ("operator", "both"):
            if line == up._UPGRADE_CLI[1]:
                line += " --dry-run"           # the real run is the start below; this one must not be refused
            r = subprocess.run(["bash", "-c", line], cwd=home, capture_output=True, text=True, env=base,
                               stdin=subprocess.DEVNULL)
            assert r.returncode == 0 and not refusals.search(r.stdout + r.stderr), (name, "operator", line, r.stdout, r.stderr)
        ran += 1
assert ran >= 10 and starts >= 10, (ran, starts)
assert not os.path.exists(home + "/state/promote/01-20261015-120000-aaa/thing"), "promote --clean removed nothing"
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
  # "start a session again": a new session's start runs the upgrade
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run start s2; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to" 2>/dev/null)" = 0.7.0 ] || { echo "$output"; cat "$DAEDALUS_HOME/state/upgrade-stopped.json"; return 1; }
}

@test "stop wording: upgrade.py --caller update says each stop with 'then run daedalus update again' and never 'start a session' (over the limit, short of disk, untracked files); records both wordings; without --caller the session wording is unchanged" {
  python3 -c 'import sys; open(sys.argv[1], "wb").truncate(3 << 20)' "$T/big.bin"
  printf 'upgrade:\n  snapshot_max_mb: 1\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP" --caller update
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  last="$(printf '%s\n' "$output" | tail -1)"
  case "$last" in "upgrade to 0.7.0 incomplete: before it changes anything in target/"*"over the 1 MB limit"*"then run daedalus update again") : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"start a session"*|*"session start"*) echo "$output"; return 1 ;; esac
  run python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["sentence"].endswith("then start a session again"), d["sentence_update"].endswith("then run daedalus update again"))' "$DAEDALUS_HOME/state/upgrade-stopped.json"
  [ "$output" = "True True" ] || { echo "$output"; return 1; }
  run python3 "$UP"
  case "$(printf '%s\n' "$output" | tail -1)" in *"over the 1 MB limit"*"then start a session again") : ;; *) echo "$output"; return 1 ;; esac
  # short of disk
  sed -i '' 's/snapshot_max_mb: 1$/snapshot_max_mb: 100/' "$DAEDALUS_HOME/config.yaml"
  run python3 - "$DAEDALUS_HOME/core" <<'PY'
import collections, sys
sys.path.insert(0, sys.argv[1])
import upgrade as up
du = collections.namedtuple("du", "total used free")
up.shutil.disk_usage = lambda p: du(1 << 30, 1 << 30, 1 << 20)
sys.exit(up.main(["upgrade.py", "--caller", "update"]))
PY
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$(printf '%s\n' "$output" | tail -1)" in "upgrade to 0.7.0 incomplete:"*"and the disk has "*" free — free some space, then run daedalus update again") : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"start a session"*) echo "$output"; return 1 ;; esac
  rm -f "$T/big.bin"
  # untracked files the fast-forward would overwrite
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  mkdir -p "$BATS_TEST_TMPDIR/hand/build"; printf 'k\n' > "$BATS_TEST_TMPDIR/hand/build/keep.txt"
  git -C "$BATS_TEST_TMPDIR/hand" add -A; cmt "$BATS_TEST_TMPDIR/hand" -m "build/keep.txt"; git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  printf 'build/\n' >> "$T/.git/info/exclude"; mkdir -p "$T/build"; git -C "$T" fetch -q origin
  printf 'MY BUILD KEEP\n' > "$T/build/keep.txt"
  run python3 "$UP" --caller update
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that fast-forwarding main to origin/main would overwrite (build/keep.txt) — move them out of that checkout, or commit them on its branch, then run daedalus update again" ] || { echo "$output"; return 1; }
  case "$output" in *"start a session"*) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  case "$(printf '%s\n' "$output" | tail -1)" in *"(build/keep.txt) — move them out of that checkout, or commit them on its branch, then start a session again") : ;; *) echo "$output"; return 1 ;; esac
}

@test "stop wording: every stop a terminal can reach, in its --caller update wording, names daedalus update where it named a session start, and no stop of any caller asks for a window" {
  run python3 - "$DAEDALUS_HOME/core" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import upgrade as up
for name in up.STOP_COMMANDS:
    s = getattr(up, name)
    u = up._for_update(s)
    if name in up.SESSION_ONLY:
        continue
    for w in ("start a session", "start a new session", "session start"):
        assert w not in u, (name, w, u)
    if up.START in [c for _, c in up.STOP_COMMANDS[name]]:
        assert "daedalus update" in u, (name, u)
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "stop wording: over the limit, a largest part in a pushed promotion's scratch names core/promote.sh NN --clean, which works with no window; an unpushed one's is not named, since only the prime removes it" {
  run python3 - "$DAEDALUS_HOME" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, str(root / "core"))
import upgrade as up
for pid, pushed in (("04-20261015-160828-526", True), ("05-20261015-170000-abc", False)):
    d = root / "state" / "promote" / pid; d.mkdir(parents=True)
    if pushed:
        (d / "pushed").write_text("{}\n")
assert up._scratch_clean(root, "state/promote/04-20261015-160828-526/thing/engine/.venv") == ", pushed: core/promote.sh 04 --clean removes it"
assert up._scratch_clean(root, "state/promote/05-20261015-170000-abc/thing/engine/.venv") == ""
assert up._scratch_clean(root, "target/thing/engine/.venv") == ""
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}
