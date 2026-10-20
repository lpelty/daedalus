#!/usr/bin/env bats
# A session that started before the upgrade finished (spec §14: it stopped on unfinished work; "pick it up" made
# windows; the next session start finishes it) holds no window and can get none — create and claim are refused
# until the stamp is written. Seen on another deployment 2026-10-13: the Stop hook blocked every turn of such a
# session with "run `core/lease.sh create` and then `claim <NN>`", the one thing the release forbids, more than
# 15 times in a row; the operator lost the conversation under it. Here: the Stop says it once, as a block, in
# words that name the remedy the operator has (close this session; a new one finishes the upgrade), then only as
# a note; nothing in that state advises create or claim.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() { upgrade_fixture; export PYTHONDONTWRITEBYTECODE=1; }
teardown() { teardown_live; }

start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' "$1" "$BATS_TEST_TMPDIR" "$1" | python3 "$DAEDALUS_HOME/core/session-start.py"; }
stop() { printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s}' "$1" "${2:-false}" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
PENDING_SENTENCE="This session started before the upgrade to 0.7.0 finished, so it holds no window and none opens for it. Tell the operator to close this session and start a new one; that start finishes the upgrade."

# the session that pulled: started while the upgrade is pending, the upgrade stopped on an in-flight branch, then
# "pick it up" made window 01 — lease files now exist and none names this session
pre_upgrade_session_after_pick_up() {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  pick_up; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
}

@test "the pre-upgrade session's Stop after 'pick it up': blocks once with the close-and-restart sentence, passes afterwards with it as a note, and never advises create or claim" {
  pre_upgrade_session_after_pick_up
  run --separate-stderr stop s1
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"$PENDING_SENTENCE"*) : ;; *) echo "wrong reason: $stderr"; return 1 ;; esac
  case "$stderr" in *"lease.sh create"*|*"claim <NN>"*|*"Promotion check could not evaluate"*|*Traceback*) echo "$stderr"; return 1 ;; esac
  run --separate-stderr stop s1
  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$output" in *"$PENDING_SENTENCE"*) : ;; *) echo "the note is missing: $output"; return 1 ;; esac
  [ -z "$stderr" ] || { echo "the second Stop still blocks: $stderr"; return 1; }
  run --separate-stderr stop s1
  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; return 1; }
}

@test "the lease resolution for that session says the same sentence — the per-prompt context and lib.sh target_path never advise create or claim while the upgrade is pending" {
  pre_upgrade_session_after_pick_up
  run --separate-stderr env DAEDALUS_SESSION_ID=s1 bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"
  [ "$status" -ne 0 ]
  case "$stderr" in *"daedalus: $PENDING_SENTENCE"*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"lease.sh create"*|*"claim <NN>"*) echo "$stderr"; return 1 ;; esac
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import verifylib as v; from pathlib import Path; print(v.lease_context(Path(sys.argv[1]).parent, "s1")["refused"])' "$DAEDALUS_HOME/core"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$PENDING_SENTENCE At its close, \`core/lease.sh log\` prints this session's log path; when no live session holds the pen, \`core/lease.sh prime take\` gives it the pen, for hot.md and \`core/vault-commit.sh\`." ] || { echo "$output"; return 1; }
}

@test "the board for that session — lease-board.py's per-prompt context and \`core/lease.sh list\` — says the same sentence in place of the create/claim nag" {
  pre_upgrade_session_after_pick_up
  run bash -c "printf '{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"hello\"}' | python3 '$DAEDALUS_HOME/core/lease-board.py'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$c" in *"$PENDING_SENTENCE"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"This session holds no lease"*|*"lease.sh create"*|*"claim <NN>"*) echo "$c"; return 1 ;; esac
  DAEDALUS_SESSION_ID=s1 run bash "$DAEDALUS_HOME/core/lease.sh" list
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$PENDING_SENTENCE"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"This session holds no lease"*|*"lease.sh create"*|*"claim <NN>"*) echo "$output"; return 1 ;; esac
}

@test "once the upgrade has finished (a later session stamped it), the old session's Stop goes back to the ordinary no-window refusal — once a turn: a re-fired Stop notes it (v0.12.4), the next turn's Stop blocks again" {
  pre_upgrade_session_after_pick_up
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run start s2; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  run --separate-stderr stop s1
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"This session holds no window"*"core/lease.sh create"*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"started before the upgrade"*) echo "$stderr"; return 1 ;; esac
  # No Stop hook may lock a session (v0.12.4): re-fired, the same reason is a note and the turn ends.
  run --separate-stderr stop s1 true
  [ "$status" -eq 0 ] || { echo "a re-fired Stop must not block twice for one reason — status $status: $output $stderr"; return 1; }
  case "$output" in *"core/lease.sh create"*) : ;; *) echo "$output"; return 1 ;; esac
  run --separate-stderr stop s1
  [ "$status" -eq 2 ] || { echo "the next turn's Stop must block once more — status $status: $output $stderr"; return 1; }
}

@test "lease.sh in a home whose upgrade stamp is absent prints no shell error about the missing stamp" {
  # lib.sh upgrade_pending: `< file 2>/dev/null` reports the missing file before stderr is redirected
  rm -rf "$DAEDALUS_HOME/state/leases"
  run --separate-stderr bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$stderr" in *"No such file or directory"*) echo "$stderr"; return 1 ;; *) : ;; esac
  case "$stderr" in *"the upgrade has not run; start a session in this home"*) : ;; *) echo "$stderr"; return 1 ;; esac
}

# --- the recorded stop on every session-facing line (update-command design, Decision 9) ---

BIG="upgrade to 0.7.0 incomplete: before it changes anything in target/ it keeps a safety copy of it, and that copy would be about 16100 MB, over the 10000 MB limit (upgrade.snapshot_max_mb in config.yaml); the largest is target/thing/engine/.venv (1800 MB) — raise the limit, or remove files target/ does not need (ignored build output counts), then start a session again"
BIG_BODY="before it changes anything in target/ it keeps a safety copy of it, and that copy would be about 16100 MB, over the 10000 MB limit (upgrade.snapshot_max_mb in config.yaml); the largest is target/thing/engine/.venv (1800 MB) — raise the limit, or remove files target/ does not need (ignored build output counts), then start a session again."
# background_stopped — what background_main leaves when its copy stopped: the stop recorded without the background
# mark (_stopped), and the run's own record ended, not copied
background_stopped() {
  python3 -c 'import json,sys; json.dump({"version": "0.7.0", "step": 2, "sentence": sys.argv[2], "at": "2026-10-15T12:00:00"}, open(sys.argv[1], "w"))' \
    "$DAEDALUS_HOME/state/upgrade-stopped.json" "$BIG"
  printf '{"pid": null, "version": "0.7.0", "running": false, "copied": false, "at": "2026-10-15T12:00:01"}\n' > "$DAEDALUS_HOME/state/upgrade-background.json"
}
board_of() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"hello"}' "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }

@test "stop sentence: a session open while the background copy ran, which then stopped over the limit — its Stop, its board and the lease commands say that stop's own sentence, never 'close this session and start a new one'" {
  pre_upgrade_session_after_pick_up
  background_stopped
  run --separate-stderr stop s1
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"This session started before the upgrade to 0.7.0 finished, so it holds no window and none opens for it. The upgrade stopped: $BIG_BODY"*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"close this session"*|*"lease.sh create"*) echo "$stderr"; return 1 ;; esac
  run --separate-stderr stop s1
  [ "$status" -eq 0 ] && [ -z "$stderr" ] || { echo "status $status: $output $stderr"; return 1; }
  run board_of s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$BIG"*"No window opens until the upgrade finishes."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"The upgrade stopped: $BIG_BODY"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"close this session"*) echo "$output"; return 1 ;; esac
  run --separate-stderr env DAEDALUS_SESSION_ID=s1 bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"
  case "$stderr" in *"The upgrade stopped: $BIG_BODY"*) : ;; *) echo "$stderr"; return 1 ;; esac
}

@test "stop sentence: a session start whose own upgrade stops over the limit says the stop and that no window opens, never that a session started after it is numbered; its Stop says the same stop" {
  pre_upgrade_session_after_pick_up
  python3 -c 'import sys; open(sys.argv[1], "wb").truncate(3 << 20)' "$T/big.bin"
  printf 'upgrade:\n  snapshot_max_mb: 1\n' >> "$DAEDALUS_HOME/config.yaml"
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run start s2; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$c" in *"over the 1 MB limit"*"then start a session again"*"No window opens until the upgrade finishes."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"a session started after that is numbered"*|*"close this session"*) echo "$c"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  run --separate-stderr stop s2
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"The upgrade stopped: before it changes anything in target/"*"over the 1 MB limit"*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"close this session"*) echo "$stderr"; return 1 ;; esac
}

@test "stop sentence: while the background run is going the line says it is taking the copy; once it took the copy, the restart line; leaselib.pending_stop agrees with upgrade.pending_line on every recorded shape" {
  pre_upgrade_session_after_pick_up
  sleep 300 3>&- </dev/null >/dev/null 2>&1 & bgpid=$!; printf '%s\n' "$bgpid" >> "$BATS_TEST_TMPDIR/live-pids"
  run python3 - "$DAEDALUS_HOME" "$bgpid" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, str(root / "core"))
import leaselib as ll, upgrade as up
st, bg = root / "state" / "upgrade-stopped.json", root / "state" / "upgrade-background.json"
for name in ("SNAP_BG_COPIED", "SNAP_BG_GONE"):
    assert getattr(ll, name) == getattr(up, name), name
running = {"ps": False}
up._bg_running = lambda r: running["ps"]          # what ps says, both modules asked the same
ll._bg_running = lambda r: running["ps"]
def put(rec, b):
    for f, d in ((st, rec), (bg, b)):
        if d is None:
            f.unlink() if f.exists() else None
        else:
            f.write_text(json.dumps(d))
big = up.SNAP_BIG % ("0.7.0", "3 MB", 1, "")
shapes = [
    ("not run", None, None, False, "restart", ll.NO_WINDOW_PENDING % "0.7.0"),
    ("other version", {"version": "0.6.9", "sentence": big}, None, False, "restart", None),
    ("stopped", {"version": "0.7.0", "step": 2, "sentence": big}, None, False, "stopped", None),
    ("background stopped", {"version": "0.7.0", "step": 2, "sentence": big}, {"running": False, "copied": False, "version": "0.7.0"}, False, "stopped", None),
    ("running", {"version": "0.7.0", "step": 2, "sentence": up.SNAP_BG % "0.7.0", "background": True}, {"running": True, "pid": int(sys.argv[2]), "version": "0.7.0"}, True, "running", ll.NO_WINDOW_RUNNING % "0.7.0"),
    ("copied", {"version": "0.7.0", "step": 2, "sentence": up.SNAP_BG % "0.7.0", "background": True}, {"running": False, "copied": True, "version": "0.7.0"}, False, "restart", ll.NO_WINDOW_PENDING % "0.7.0"),
    ("gone", {"version": "0.7.0", "step": 2, "sentence": up.SNAP_BG % "0.7.0", "background": True}, {"running": False, "copied": False, "version": "0.7.0"}, False, "stopped", None),
    ("gone after copying another version", {"version": "0.7.0", "step": 2, "sentence": up.SNAP_BG % "0.7.0", "background": True}, {"running": False, "copied": True, "version": "0.6.9"}, False, "stopped", None),
]
for name, rec, b, ps, kind, nowin in shapes:
    put(rec, b); running["ps"] = ps
    p = ll.pending_stop(root)
    assert p is not None and p[0] == "0.7.0" and p[1] == kind, (name, p)
    assert p[2] == up.pending_line(root), (name, p[2], up.pending_line(root))
    said = ll.no_window_pending(p)
    assert said.startswith("This session started before the upgrade to 0.7.0 finished"), (name, said)
    if nowin:
        assert said == nowin + " " + ll.WINDOWLESS_CLOSE, (name, said)     # every kind ends with the close that works
    if kind == "stopped":
        assert "close this session" not in said and said.startswith(ll.NO_WINDOW_STOPPED.split("%s")[0]), (name, said)
        assert p[2].split(": ", 1)[-1].rstrip(".") in said, (name, said)
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "stop sentence: 'pick it up' that leaves nothing behind clears the recorded unfinished-work stop, so the lines go back to the restart advice" {
  pre_upgrade_session_after_pick_up
  [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import leaselib as ll; from pathlib import Path; print(ll.pending_stop(Path(sys.argv[1]).parent)[1])' "$DAEDALUS_HOME/core"
  [ "$output" = restart ] || { echo "$output"; return 1; }
}
