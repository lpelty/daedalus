#!/usr/bin/env bats
# Pins core/lease-board.py: rendering, the heartbeat and the reader's changed set — never binding (spec §4.3, §4.2).
# A wall-clock assertion lives in this file (the 40-lease render under 2 s): under the parallel
# full-suite gate (`bats --jobs 12`) its tests run one at a time, while other files run beside it.
# It missed the budget twice under parallel load in plan 2 (2.16 s, 2.72 s) and passed serially both times.
BATS_NO_PARALLELIZE_WITHIN_FILE=true
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
load fixtures/transcripts/setup.bash
load fixtures/tty/setup.bash
setup() { lease_fixture; LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }; }
teardown() { teardown_live; }
board() { printf '{"hook_event_name":"%s","session_id":"%s","prompt":"hello there"}' "${2:-UserPromptSubmit}" "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py"; }
ctx() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
bind_live() {  # bind_live <NN> <sid> [name] — claim with a live registry pid
  local pid; pid="$(live_pid)"; registry_entry "$pid" "$2" interactive cli "${3:-daedalus-$1}"
  env CLAUDE_CODE_SESSION_ID="$2" bash "$DAEDALUS_HOME/core/lease.sh" claim "$1" >/dev/null
}

@test "emits nothing when no leases exist" { run board sX; [ -z "$output" ]; }

@test "renders the reader's lease first with number, alias, prime mark, changed count and first three paths, last commit subject, note, base; other windows with last-seen; the message-the-holder line; peer name only when it differs" {
  LS create >/dev/null; LS create >/dev/null; LS create >/dev/null
  bind_live 01 sA; bind_live 02 sB; bind_live 03 sC daedalus-07
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  LS alias 02 poc-ui >/dev/null; LS note 02 "EX-024 capture error-field fix" >/dev/null
  W="$DAEDALUS_HOME/worktrees/02/thing"
  for f in one two three four; do printf 'x\n' > "$W/$f.txt"; done
  git -C "$W" add -A; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m "capture: read error before error_message"
  run board sB; [ "$status" -eq 0 ]
  c="$(ctx)"
  case "$c" in "Lease board (3 windows; you are window 02):"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 02 (you) (poc-ui) — 4 changed: four.txt, one.txt, three.txt, … (+1) — last commit \"capture: read error before error_message\" — note: EX-024 capture error-field fix — based on origin/main"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 01 — prime (holds the pen: hot.md, vault commits, promote) — 0 changed — no commits yet — last seen"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 03 — "*"peer name daedalus-07 (not a window number)"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"daedalus-01"*|*"daedalus-02"*) echo "peer names equal to daedalus-NN must not print: $c"; return 1 ;; *) : ;; esac
  case "$c" in *"If you need a file another window has changed, message that window (SendMessage to its peer name, from this board) before changing it."*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "heartbeat: the reader's .seen mtime moves, the JSON does not; the reader's .changed is recomputed and no other lease's" {
  LS create >/dev/null; LS create >/dev/null; bind_live 01 sA; bind_live 02 sB
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/01.seen" "$DAEDALUS_HOME/state/leases/02.seen"
  before="$(shasum -a 256 "$DAEDALUS_HOME/state/leases/01.json")"
  printf 'x\n' > "$DAEDALUS_HOME/worktrees/01/thing/new.txt"; printf 'y\n' > "$DAEDALUS_HOME/worktrees/02/thing/other.txt"
  run board sA
  [ "$(shasum -a 256 "$DAEDALUS_HOME/state/leases/01.json")" = "$before" ]
  [ "$DAEDALUS_HOME/state/leases/01.seen" -nt "$DAEDALUS_HOME/state/leases/02.seen" ]
  grep -q 'new.txt' "$DAEDALUS_HOME/state/leases/01.changed"
  ! grep -q 'other.txt' "$DAEDALUS_HOME/state/leases/02.changed"
}

@test "stale renders STALE with the sweep/claim remedy; quiet renders quiet; resumed renders live and is rebound; kind bg renders spawned or background clone; finished, released, waiting, two-terminals lines" {
  for i in 1 2 3 4 5 6; do LS create >/dev/null; done
  bind_live 01 sA
  # The swept-and-waiting window first: sweep removes every stale lease too, so
  # 02's stale state (below) must be set AFTER the sweep or the sweep eats the
  # very line this test asserts; and 04's resumed state after it too, so the
  # BOARD is what rebinds 04, not the sweep.
  bind_live 06 sF; CLAUDE_CODE_SESSION_ID=sF LS release 06 >/dev/null
  W="$DAEDALUS_HOME/worktrees/06/thing"; printf 'w\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "waiting work"
  LS create >/dev/null; bind_live 07 sG; LS sweep >/dev/null   # removes 06 (released) -> its work waits
  [ ! -f "$DAEDALUS_HOME/state/leases/06.json" ]
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(session_id="sB",pid=1,proc_started=1,alias="electron"); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  bind_live 03 sC; touch -t 202001010940 "$DAEDALUS_HOME/state/leases/03.seen"
  pr="$(live_pid)"; registry_entry "$pr" sD
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 04 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(session_id="sD",pid=1,proc_started=1); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/04.json")"
  pb="$(live_pid)"; registry_entry "$pb" sE bg cli daedalus-05; CLAUDE_CODE_SESSION_ID=sE LS claim 05 >/dev/null
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 05 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(spawned=True,finished="2026-09-25T11:42:00",summary="did the thing"); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/05.json")"
  run board sA; c="$(ctx)"
  case "$c" in *"- 02 (electron) — STALE: no live session since"*"run \`core/lease.sh sweep\`, or say 'this is window 02' to a new window to continue it."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 03 — "*"quiet since 09:40 — its window is still open"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 04 — "*"last seen"*) : ;; *) echo "resumed must render live: $c"; return 1 ;; esac
  [ "$(lease_json 04 pid)" = "$pr" ]
  case "$c" in *"- 05 (spawned) — FINISHED at 11:42: did the thing — promote 05 or release 05"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 06 — swept, 1 unpromoted commit waiting (\"waiting work\"): say 'this is window 06' to a window to continue it, or 'delete 06's work'"*) : ;; *) echo "$c"; return 1 ;; esac
  # a second LIVE registry entry for sA (a dead pid beside it changes nothing — Task 2 review)
  registry_entry "$(live_pid)" sA
  run board sA; c="$(ctx)"; case "$c" in *"- 01 (you) — open in two terminals (pids"*"close one"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "a released reader is told it is done; a finished spawned lease with a dead pid renders 'never reported'" {
  LS create >/dev/null; bind_live 01 sA; CLAUDE_CODE_SESSION_ID=sA LS release 01 >/dev/null
  run board sA; c="$(ctx)"; case "$c" in *"Window 01 is released; this window is done — close it"*) : ;; *) echo "$c"; return 1 ;; esac
  LS create >/dev/null
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(session_id="sZ",pid=1,proc_started=1,spawned=True); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run board sA; c="$(ctx)"; case "$c" in *"- 02 (spawned) — STALE"*"a background clone that never reported — read its log with \`claude logs"*"before sweeping"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "never binds or numbers: a DAEDALUS_LEASE naming a null lease stays null; an unleased session gets the unleased warning; a visitor gets the read-only line" {
  LS create >/dev/null; bind_live 01 sA
  LS create >/dev/null
  run env DAEDALUS_LEASE=02 bash -c "$(declare -f board); board sB"
  [ "$(lease_json 02 session_id)" = "None" ]
  run board sB; c="$(ctx)"; case "$c" in *"This session holds no lease"*"core/lease.sh claim"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"- 02 — 0 changed"*) : ;; *) echo "the null 02 must render unmarked (no prime.json exists): $c"; return 1 ;; esac
  run env DIRECT_CALL_ID=x bash -c "$(declare -f board); board sV"; c="$(ctx)"
  case "$c" in *"This is a direct-call session; it holds no lease and cannot take the pen."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"This session holds no lease"*) echo "a visitor is never nagged: $c"; return 1 ;; *) : ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]
}

@test "no prime.json: an unclaimed (null) lease is never marked prime — the board asserts no pen-holder that does not exist (§4.8: prime.json is the authority); on a registry-absent build the list shows no prime mark until prime take" {
  LS create >/dev/null; bind_live 01 sA
  LS create >/dev/null                                   # 02 stays null (session_id: null), no prime.json anywhere
  [ ! -f "$DAEDALUS_HOME/state/leases/prime.json" ]
  run board sA; c="$(ctx)"
  case "$c" in *"prime (holds the pen"*) echo "a null lease read as prime: $c"; return 1 ;; *) : ;; esac
  case "$c" in *"- 02 — 0 changed"*) : ;; *) echo "$c"; return 1 ;; esac
  rm -rf "$BATS_TEST_TMPDIR/sessions"                    # registry-absent build (§3.1/A2): create, create, nobody takes the pen at start
  rm -rf "$DAEDALUS_HOME/state/leases"; LS create >/dev/null; LS create >/dev/null
  run LS list; case "$output" in *"prime (holds the pen"*) echo "phantom prime on a registry-absent list: $output"; return 1 ;; *) : ;; esac
  case "$output" in *"nobody takes the pen"*) : ;; *) echo "$output"; return 1 ;; esac
  CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  run LS list; case "$output" in *"- 02 — prime"*) echo "the unclaimed 02 still reads as prime after 01 claimed: $output"; return 1 ;; *) : ;; esac
  CLAUDE_CODE_SESSION_ID=sA LS prime take >/dev/null
  run LS list; case "$output" in *"- 01 — prime (holds the pen"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"- 02 — prime"*) echo "$output"; return 1 ;; *) : ;; esac
}

@test "a lease file that cannot be read does not make the board vanish: the prompt hook and SessionStart both carry the sentence naming the file and the fix (lease.sh refuses loudly in the same state)" {
  LS create >/dev/null; bind_live 01 sA
  LS create >/dev/null; printf 'not json\n' > "$DAEDALUS_HOME/state/leases/02.json"
  run board sA; [ "$status" -eq 0 ]; [ -n "$output" ]; c="$(ctx)"
  case "$c" in "The lease board could not be rendered: The lease file for window 02 cannot be read (not valid JSON"*"run \`core/lease.sh sweep\` before building."*) : ;; *) echo "$c"; return 1 ;; esac
  run LS list; [ "$status" -eq 1 ]; case "$output" in *"The lease file for window 02 cannot be read"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"hook_event_name":"SessionStart","session_id":"sA","source":"startup","transcript_path":"%s/transcripts/sA.jsonl"}' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/start.json"
  run bash -c "python3 '$DAEDALUS_HOME/core/session-start.py' < '$BATS_TEST_TMPDIR/start.json'"; [ "$status" -eq 0 ]; c="$(ctx)"
  case "$c" in *"The lease board could not be rendered: The lease file for window 02 cannot be read (not valid JSON"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "emitted on every prompt: two prompts, unchanged leases, two emissions, each tagged UserPromptSubmit" {
  LS create >/dev/null; bind_live 01 sA
  run board sA; [ -n "$output" ]; run board sA; [ -n "$output" ]
  case "$output" in *'"hookEventName": "UserPromptSubmit"'*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "peer name is re-read from the registry at every render — another window's rename shows on the reader's board without that window doing anything" {
  LS create >/dev/null; bind_live 01 sA daedalus-01; LS create >/dev/null; bind_live 02 sB daedalus-02
  run board sA; c="$(ctx)"; case "$c" in *"(not a window number)"*) echo "$c"; return 1 ;; *) : ;; esac   # the footer says "peer name" too
  pid="$(lease_json 02 pid)"; registry_entry "$pid" sB interactive cli daedalus-02-graceful-unicorn
  run board sA; c="$(ctx)"; case "$c" in *"- 02 — "*"peer name daedalus-02-graceful-unicorn (not a window number)"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(lease_json 02 peer_name)" = "daedalus-02-graceful-unicorn" ]    # the file agrees with the board
}

@test "handover: the displaced holder is told on its next board who took the pen, when, and why" {
  LS create >/dev/null; bind_live 01 sA; LS create >/dev/null; bind_live 02 sB; LS alias 02 electron >/dev/null
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","bound_at":"2026-01-01T00:00:00","history":[]}'
  tx "$(tx_path sB)" operator "the operator asked the electron window to close out the day" >/dev/null
  CLAUDE_CODE_SESSION_ID=sB LS prime take --reason "the operator asked the electron window to close out the day" >/dev/null
  run board sA; c="$(ctx)"
  case "$c" in *"You no longer hold the pen; window 02 (electron) took it at "*" (reason: 'the operator asked the electron window to close out the day')"*) : ;; *) echo "$c"; return 1 ;; esac
  run board sB; c="$(ctx)"; case "$c" in *"You no longer hold the pen"*) echo "the taker must not see it: $c"; return 1 ;; *"- 02 (you) (electron) — prime"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "runs under 2 s with 40 LIVE leases, each with a real worktree (the per-lease git path is what is timed)" {
  for i in $(seq 1 40); do LS create >/dev/null; done
  for i in $(seq 1 40); do nn="$(printf '%02d' "$i")"
    python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$nn" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(session_id="s"+sys.argv[2],pid=int(sys.argv[3]),proc_started=int(sys.argv[4])); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$nn.json" "$nn" "$$" "$(ps_ms $$)")"
    python3 "$DAEDALUS_HOME/core/leaselib.py" heartbeat "$nn"; done
  run python3 "$DAEDALUS_HOME/core/leaselib.py" liveness 17; [ "$output" = "live" ]
  t0="$(python3 -c 'import time; print(time.time())')"; run board s01; t1="$(python3 -c 'import time; print(time.time())')"
  [ "$status" -eq 0 ]; python3 -c 'import sys; d=float(sys.argv[2])-float(sys.argv[1]); print("render took %.2fs" % d, file=sys.stderr); assert d < 2.0, "slow: %.2fs" % d' "$t0" "$t1"
  c="$(ctx)"; case "$c" in *"- 40 — "*"last seen"*) : ;; *) echo "all 40 must render live: $c"; return 1 ;; esac
}
# Budget arithmetic, measured 2026-09-26 on Apple silicon: one `ps` 2.8 ms, one git spawn ~6 ms, one bash `cfg` 5 ms
# (now once per render), python + imports ~25 ms. 40 live leases ≈ 40 ps + 80 `git log` (two repos each, no commits)
# ≈ 0.6–0.7 s. If this test misses the 2 s budget on a slower disk, the lever is last_commit_subject: stop at the
# outer repo when the lease's changed set is empty, before reaching for the sidecar cache — never the budget itself.

@test "lease.sh list prints the same shape for a shell (no nag: a person at a shell holds no lease by design) and recomputes every changed set; the tracked settings.json wires the board on UserPromptSubmit only, and SessionStart stays one hook" {
  LS create >/dev/null; bind_live 01 sA; printf 'z\n' > "$DAEDALUS_HOME/worktrees/01/thing/z.txt"
  run LS list; case "$output" in "Lease board (1 window; you hold no lease):"*"- 01 — "*"1 changed: z.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"This session holds no lease"*) echo "an operator shell is not nagged: $output"; return 1 ;; *) : ;; esac
  run LS status; [ "$status" -eq 0 ]
  python3 - "$SRC/../.claude/settings.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
ss=[h["command"] for g in d["hooks"]["SessionStart"] for h in g["hooks"]]
assert len(ss)==1 and "session-start.py" in ss[0], ss      # hooks of one event run in parallel: the board rides inside session-start.py
ups=[h for g in d["hooks"]["UserPromptSubmit"] for h in g["hooks"]]
assert any("lease-board.py" in h["command"] and h["timeout"]==5 for h in ups), ups
PY
}
