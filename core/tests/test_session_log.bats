#!/usr/bin/env bats
# Session logs carry one global counter per vault (YYYY-MM-DD-NNN.md). The
# number is reserved in the session's lease file under the lease lock —
# at session start, and by `core/lease.sh log` — never computed by listing
# the directory at close, where two windows on one day both count the same
# next number (spec D7's collision; the operator's ruling of 2026-10-14 keeps the
# counter they navigate by and puts the window in the frontmatter only).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() {
  lease_fixture; export PYTHONDONTWRITEBYTECODE=1
  mkdir -p "$DAEDALUS_HOME/state/leases"
  for p in 01:sA 02:sB; do nn="${p%%:*}"; s="${p##*:}"; pid="$(live_pid)"; registry_entry "$pid" "$s"
    printf '{"lease":"%s","session_id":"%s","worktree":"worktrees/%s","pid":1,"proc_started":1}' "$nn" "$s" "$nn" > "$DAEDALUS_HOME/state/leases/$nn.json"; touch "$DAEDALUS_HOME/state/leases/$nn.seen"; done
  printf '{"session_id":"sA","history":[]}' > "$DAEDALUS_HOME/state/leases/prime.json"
  TODAY="$(date +%Y-%m-%d)"; YM="$(date +%Y/%m)"
}
teardown() { teardown_live; }
log_of() { env DAEDALUS_SESSION_ID="$1" bash "$DAEDALUS_HOME/core/lease.sh" log; }
start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"%s","transcript_path":"%s/transcripts/%s.jsonl"}' "$1" "${2:-startup}" "$BATS_TEST_TMPDIR" "$1" | python3 "$DAEDALUS_HOME/core/session-start.py"; }

@test "two windows on one day get consecutive numbers; asking again gives the same path; the reservation sits in the lease file" {
  run log_of sA; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-001.md" ]
  run log_of sB; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-002.md" ]
  run log_of sA; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-001.md" ]
  [ "$(lease_json 01 logs)" = "{'$TODAY': 1}" ]
  [ "$(lease_json 02 logs)" = "{'$TODAY': 2}" ]
  [ ! -e "$DAEDALUS_HOME/vault/sessions/$YM/$TODAY-001.md" ]   # reserved, not written: the session writes its log
}

@test "logs already in the vault set the floor; a window-numbered log (two digits) and a prime log are not counted" {
  mkdir -p "$DAEDALUS_HOME/vault/sessions/2026/09" "$DAEDALUS_HOME/vault/sessions/2026/10"
  touch "$DAEDALUS_HOME/vault/sessions/2026/09/2026-09-21-046.md" "$DAEDALUS_HOME/vault/sessions/2026/09/2026-09-01-009.md" \
        "$DAEDALUS_HOME/vault/sessions/2026/10/2026-10-08-01.md" "$DAEDALUS_HOME/vault/sessions/2026/10/2026-10-09-prime.md" \
        "$DAEDALUS_HOME/vault/sessions/_template.md"
  run log_of sA; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-047.md" ]
}

@test "a number another window reserved but has not written yet is skipped, whatever day it was reserved for" {
  python3 - "$DAEDALUS_HOME/state/leases/02.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["logs"]={"2026-01-01": 46}; json.dump(d, open(p,"w"))
PY
  run log_of sA; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-047.md" ]
}

@test "across midnight a running session keeps the path it opened with; a new start on the new day gets the next number; a corrupt reservation is treated as absent" {
  run python3 - "$DAEDALUS_HOME" <<'PY'
import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1] + "/core"); import leaselib as ll
root = Path(sys.argv[1])
print(ll.log_path(root, "sA", today="2026-10-14"))                      # opened 10-14: 001
print(ll.log_path(root, "sA", today="2026-10-15"))                      # still running after midnight: the same file
with ll.lock(root):
    print(ll.log_path_locked(root, "01", ll.read_all(root), "2026-10-15", new_day=True))   # a new start on 10-15: 002
print(ll.log_path(root, "sA", today="2026-10-15"))                      # and from then on, that is the path
with ll.lock(root):
    print(ll.log_path_locked(root, "01", ll.read_all(root), "2026-10-14", new_day=True))   # a start keyed to a reserved day: that day's path
import json; p = root / "state/leases/02.json"; d = json.loads(p.read_text()); d["logs"] = {"2026-10-15": "abc"}; p.write_text(json.dumps(d))
print(ll.log_path(root, "sB", today="2026-10-15"))                      # a corrupt value is not a reservation: the next number, re-reserved
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "vault/sessions/2026/10/2026-10-14-001.md" ]
  [ "${lines[1]}" = "vault/sessions/2026/10/2026-10-14-001.md" ]
  [ "${lines[2]}" = "vault/sessions/2026/10/2026-10-15-002.md" ]
  [ "${lines[3]}" = "vault/sessions/2026/10/2026-10-15-002.md" ]
  [ "${lines[4]}" = "vault/sessions/2026/10/2026-10-14-001.md" ]
  [ "${lines[5]}" = "vault/sessions/2026/10/2026-10-15-003.md" ]
}

@test "a session with no window is refused with the no-window sentence; an operator shell is told it needs a session" {
  run --separate-stderr log_of sZ; [ "$status" -eq 1 ]
  case "$stderr" in *"This session holds no window"*) : ;; *) echo "$stderr"; return 1 ;; esac
  run --separate-stderr bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash '$DAEDALUS_HOME/core/lease.sh' log"; [ "$status" -eq 1 ]
  case "$stderr" in *"session"*) : ;; *) echo "$stderr"; return 1 ;; esac
}

@test "a session that holds only the pen logs with a number reserved in prime.json" {
  printf '{"session_id":"sP","history":[]}' > "$DAEDALUS_HOME/state/leases/prime.json"
  run log_of sP; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-001.md" ]
  [ "$(lease_json prime logs)" = "{'$TODAY': 1}" ]
  run log_of sA; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-002.md" ]
}

@test "session start reserves the number and tells the window its log path; a restart the same day is told the same path" {
  rm -f "$DAEDALUS_HOME/state/leases/"*; teardown_live
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  run start sN; [ "$status" -eq 0 ]
  case "$output" in *"Your session log for today is vault/sessions/$YM/$TODAY-001.md"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 logs)" = "{'$TODAY': 1}" ]
  run start sN; [ "$status" -eq 0 ]
  case "$output" in *"Your session log for today is vault/sessions/$YM/$TODAY-001.md"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 logs)" = "{'$TODAY': 1}" ]
}

@test "a compaction after midnight keeps the path the session opened with; a startup or resume on the new day gets the next number" {
  rm -f "$DAEDALUS_HOME/state/leases/"*; teardown_live
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  start sN >/dev/null
  python3 - "$DAEDALUS_HOME/state/leases/01.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["logs"]={"2026-01-02": 7}; json.dump(d, open(p,"w"))
PY
  run start sN compact; [ "$status" -eq 0 ]
  case "$output" in *"Your session log for today is vault/sessions/2026/01/2026-01-02-007.md"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 logs)" = "{'2026-01-02': 7}" ]
  run start sN resume; [ "$status" -eq 0 ]
  case "$output" in *"Your session log for today is vault/sessions/$YM/$TODAY-008.md"*) : ;; *) echo "$output"; return 1 ;; esac
  run start sN compact; [ "$status" -eq 0 ]
  case "$output" in *"Your session log for today is vault/sessions/$YM/$TODAY-008.md"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a window taken over from a dead holder with claim does not inherit its log reservation: the new session gets today's next number" {
  python3 - "$DAEDALUS_HOME/state/leases/02.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.update({"session_id": "sX", "pid": 999999, "proc_started": 1, "logs": {"2026-10-13": 5}}); json.dump(d, open(p,"w"))
PY
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/02.seen"
  pid="$(live_pid)"; registry_entry "$pid" sN
  run env DAEDALUS_SESSION_ID=sN bash "$DAEDALUS_HOME/core/lease.sh" claim 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run log_of sN; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-001.md" ] || { echo "$output"; return 1; }
  [ "$(lease_json 02 logs)" = "{'$TODAY': 1}" ]
}

@test "the pen taken from a dead holder (first-up) does not carry that holder's log reservation" {
  python3 - "$DAEDALUS_HOME/state/leases/prime.json" <<'PY'
import json,sys; p=sys.argv[1]; json.dump({"session_id": "sX", "history": [], "logs": {"2026-10-13": 5}}, open(p,"w"))
PY
  rm -f "$DAEDALUS_HOME/state/leases/"0*; teardown_live
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  run start sN; [ "$status" -eq 0 ]
  case "$output" in *"you hold the pen (prime)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime logs)" = "None" ] || { lease_json prime logs; return 1; }
  run log_of sN; [ "$status" -eq 0 ]; [ "$output" = "vault/sessions/$YM/$TODAY-001.md" ] || { echo "$output"; return 1; }
}
