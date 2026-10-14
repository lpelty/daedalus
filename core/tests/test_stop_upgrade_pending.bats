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
  [ "$output" = "$PENDING_SENTENCE" ] || { echo "$output"; return 1; }
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

@test "once the upgrade has finished (a later session stamped it), the old session's Stop goes back to the ordinary no-window refusal — the remedy it names is then possible, so a re-fired Stop still blocks" {
  pre_upgrade_session_after_pick_up
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run start s2; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  run --separate-stderr stop s1
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"This session holds no window"*"core/lease.sh create"*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"started before the upgrade"*) echo "$stderr"; return 1 ;; esac
  run --separate-stderr stop s1 true
  [ "$status" -eq 2 ] || { echo "a repairable refusal must block the re-fired Stop too — status $status: $output $stderr"; return 1; }
  case "$stderr" in *"core/lease.sh create"*) : ;; *) echo "$stderr"; return 1 ;; esac
}

@test "lease.sh in a home whose upgrade stamp is absent prints no shell error about the missing stamp" {
  # lib.sh upgrade_pending: `< file 2>/dev/null` reports the missing file before stderr is redirected
  rm -rf "$DAEDALUS_HOME/state/leases"
  run --separate-stderr bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$stderr" in *"No such file or directory"*) echo "$stderr"; return 1 ;; *) : ;; esac
  case "$stderr" in *"the upgrade has not run; start a session in this home"*) : ;; *) echo "$stderr"; return 1 ;; esac
}
