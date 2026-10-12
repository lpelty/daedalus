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

@test "the prompt hook records each prompt Claude Code reports beside its transcript, and a yes it recorded is accepted while one it never saw is not (critic-fix review, finding 3)" {
  F="$(tx_path sP)"; T0="$(now)"
  tx "$F" operator "promote window 2" "$(plus "$T0" -60)" >/dev/null
  tx "$F" assistant "Ready to promote window 02's work onto main." "$(plus "$T0" 2)" >/dev/null
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"sP","transcript_path":"%s","prompt":"Yes, push it."}' "$F" \
    | python3 "$DAEDALUS_HOME/core/lease-board.py" >/dev/null
  [ -s "$F.daedalus-prompts" ]
  grep -q '"session_id": "sP"' "$F.daedalus-prompts"
  said="$(TX_RECORD=none tx "$F" operator "Yes, push it." "$(plus "$T0" 5)")"
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import transcriptlib as tl; print(tl.find_operator_words(sys.argv[2], "yes, push it", float(sys.argv[3]), True, "Ready to promote")["transcript_ref"]["uuid"])' \
    "$DAEDALUS_HOME/core" "$F" "$T0"
  [ "$output" = "$said" ] || { echo "$output"; return 1; }
  TX_RECORD=none tx "$F" assistant "Ready to promote window 02's work onto main." "$(plus "$T0" 6)" >/dev/null
  TX_RECORD=none tx "$F" operator "yes" "$(plus "$T0" 7)" >/dev/null
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import transcriptlib as tl
try: tl.find_operator_words(sys.argv[2], "yes", float(sys.argv[3]), True, "Ready to promote"); print("accepted")
except tl.NotSubmitted as e: print("refused:", e)' "$DAEDALUS_HOME/core" "$F" "$T0"
  case "$output" in "refused: "*"never reported"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the board's first line, on every prompt, is the upgrade's stop sentence until the stamp is written — even with no window open; then it is gone (spec §14)" {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"; mkdir -p "$DAEDALUS_HOME/state"
  s="upgrade to 0.7.0 incomplete: target/thing has uncommitted changes — commit them on their branch inside that checkout, then start a session again"
  python3 -c 'import json,sys; json.dump({"version": "0.7.0", "step": 6, "sentence": sys.argv[2]}, open(sys.argv[1], "w"))' "$DAEDALUS_HOME/state/upgrade-stopped.json" "$s"
  run board s1
  [ "$(ctx | head -1)" = "$s" ] || { echo "$output"; return 1; }
  run board s1
  [ "$(ctx | head -1)" = "$s" ]
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  run board s1
  [ -z "$output" ] || { echo "a line after the stamp: $output"; return 1; }
}

# --- board-json: the cheap read behind the on-screen band (lease-board spec §3) ----------------------------------
# The band in every window asks for this every 2 s, so it is the second reader of state/leases/ and must stay a
# reader: a shared lock for one pass over the lease files, the .seen and .changed sidecars, prime.json and the
# registry; no git, no heartbeat, no rebind, no sidecar recompute. The states come from the same liveness() the
# model-facing board uses, so the two can never disagree.
BJ() { python3 "$DAEDALUS_HOME/core/leaselib.py" board-json "$@"; }
# bj_check <python-expression> — true over the parsed object in $output as `o`; prints the object when it is not
bj_check() { printf '%s' "$output" | python3 -c 'import json,sys
o=json.loads(sys.stdin.read())
if not eval(sys.argv[1]): print("FAILED: %s\n%s" % (sys.argv[1], json.dumps(o, indent=1))); sys.exit(1)' "$1"; }
set_lease() {  # set_lease <NN> <python dict literal> — merge fields into a lease file through the fixture writer
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$1" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(eval(sys.argv[2])); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$1.json" "$2")"
}

@test "board-json: one JSON line; this window first, then by number; released, then finished, then liveness decide the state; the pen and this-window marks; alias, note, last seen, changed count, peer name" {
  for i in 1 2 3 4 5; do LS create >/dev/null; done
  bind_live 01 sA; bind_live 03 sC; bind_live 04 sD; bind_live 05 sE
  set_lease 02 'dict(session_id="sB", pid=1, proc_started=1, alias="electron")'              # dead recorded pid, nobody resumed it: stale
  touch -t 202001010940 "$DAEDALUS_HOME/state/leases/03.seen"                                  # live pid, old heartbeat: quiet
  set_lease 04 'dict(spawned=True, finished="2026-09-25T11:42:00", summary="did the thing")'
  CLAUDE_CODE_SESSION_ID=sE LS release 05 >/dev/null
  LS note 01 "EX-024 capture error-field fix" >/dev/null
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  W="$DAEDALUS_HOME/worktrees/01/thing"; for f in one two three four; do printf 'x\n' > "$W/$f.txt"; done
  git -C "$W" add -A; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m "four files"
  python3 "$DAEDALUS_HOME/core/leaselib.py" changed 01 >/dev/null     # the sidecar is written here; board-json only reads it
  run --separate-stderr BJ --session sC; [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ] || { echo "not one line: $output"; return 1; }
  bj_check 'o["this_window"] == "03" and o["prime_window"] == "01"'
  bj_check '[w["nn"] for w in o["windows"]] == ["03", "01", "02", "04", "05"]'
  bj_check '[w["state"] for w in o["windows"]] == ["quiet", "live", "stale", "finished", "released"]'
  bj_check 'o["windows"][0]["is_this"] and not o["windows"][0]["is_prime"]'
  bj_check 'o["windows"][1]["is_prime"] and not o["windows"][1]["is_this"]'
  bj_check 'sum(w["is_this"] for w in o["windows"]) == 1 and sum(w["is_prime"] for w in o["windows"]) == 1'
  bj_check 'o["windows"][2]["alias"] == "electron" and o["windows"][0]["alias"] is None'
  bj_check 'o["windows"][1]["note"] == "EX-024 capture error-field fix" and o["windows"][0]["note"] is None'
  bj_check 'o["windows"][1]["changed_count"] == 4 and o["windows"][2]["changed_count"] == 0'
  seen="$(stat -f %m "$DAEDALUS_HOME/state/leases/03.seen")"
  bj_check "abs(o['windows'][0]['last_seen_epoch'] - $seen) < 1.0"
  bj_check 'o["windows"][1]["peer_name"] == "daedalus-01" and o["windows"][2]["peer_name"] is None'
  bj_check 'isinstance(o["generated_epoch"], float) and o["generated_epoch"] > 1.7e9'
  bj_check 'all(isinstance(w["changed_count"], int) and w["nn"].isdigit() and len(w["nn"]) == 2 for w in o["windows"])'
}

@test "board-json: exactly the four top-level keys and exactly the nine window keys the contract names, nothing more" {
  LS create >/dev/null; LS create >/dev/null; bind_live 01 sA
  run --separate-stderr BJ --session sA; [ "$status" -eq 0 ]
  bj_check 'sorted(o) == ["generated_epoch", "prime_window", "this_window", "windows"]'
  bj_check 'len(o["windows"]) == 2 and all(sorted(w) == ["alias", "changed_count", "is_prime", "is_this", "last_seen_epoch", "nn", "note", "peer_name", "state"] for w in o["windows"])'
  bj_check 'o["windows"][1]["nn"] == "02" and o["windows"][1]["peer_name"] is None and o["windows"][1]["alias"] is None'   # created, never claimed
  rm -f "$DAEDALUS_HOME/state/leases/02.seen"
  run --separate-stderr BJ --session sA; [ "$status" -eq 0 ]
  bj_check 'o["windows"][1]["last_seen_epoch"] is None and isinstance(o["windows"][0]["last_seen_epoch"], float)'   # null means no .seen file
}

@test "board-json: a reader only — every file under state/leases/ is byte-identical after two runs, no .seen or .lock mtime moves, an empty 07.json is kept and not listed (the model-facing board still prunes it)" {
  LS create >/dev/null; LS create >/dev/null; bind_live 01 sA; bind_live 02 sB
  L="$DAEDALUS_HOME/state/leases"
  touch -t 202001010000 "$L/01.seen" "$L/02.seen"
  : > "$L/07.json"
  before="$(cd "$L" && shasum -a 256 * .lock | sort)"; mt_before="$(cd "$L" && stat -f '%N %Fm' * .lock | sort)"
  run --separate-stderr BJ --session sA; [ "$status" -eq 0 ]
  run --separate-stderr BJ --session sB; [ "$status" -eq 0 ]
  bj_check '"07" not in [w["nn"] for w in o["windows"]] and [w["nn"] for w in o["windows"]] == ["02", "01"]'
  [ "$(cd "$L" && shasum -a 256 * .lock | sort)" = "$before" ] || { echo "a file changed"; diff <(printf '%s\n' "$before") <(cd "$L" && shasum -a 256 * .lock | sort); return 1; }
  [ "$(cd "$L" && stat -f '%N %Fm' * .lock | sort)" = "$mt_before" ] || { echo "an mtime moved"; diff <(printf '%s\n' "$mt_before") <(cd "$L" && stat -f '%N %Fm' * .lock | sort); return 1; }
  [ -f "$L/07.json" ] && [ ! -s "$L/07.json" ]
  run board sA; [ ! -f "$L/07.json" ]       # read_all's default is unchanged: the model-facing board removes the interrupted reservation
}

@test "board-json: never runs git — with a failing git first on PATH that also records every call, the command succeeds and nothing was recorded (the model-facing board in the same state does hit it)" {
  LS create >/dev/null; bind_live 01 sA; printf 'z\n' > "$DAEDALUS_HOME/worktrees/01/thing/z.txt"
  shim="$BATS_TEST_TMPDIR/shim"; mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "git $*" >> "%s/GIT-CALLED"\nexec "%s/fixtures/leases/fake-git-fail" "$@"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_DIRNAME" > "$shim/git"; chmod +x "$shim/git"
  run --separate-stderr env PATH="$shim:$PATH" python3 "$DAEDALUS_HOME/core/leaselib.py" board-json --session sA
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; return 1; }
  bj_check 'o["this_window"] == "01" and o["windows"][0]["state"] == "live"'
  [ ! -e "$BATS_TEST_TMPDIR/GIT-CALLED" ] || { echo "git was run:"; cat "$BATS_TEST_TMPDIR/GIT-CALLED"; return 1; }
  run env PATH="$shim:$PATH" bash -c "$(declare -f board); board sA"       # control: the shim is on the path the model-facing board takes
  [ -e "$BATS_TEST_TMPDIR/GIT-CALLED" ] || { echo "the control did not reach the shim: $output"; return 1; }
}

@test "board-json: --session beats the environment; with neither, this_window is null and no window is marked (an operator shell); a bad flag is exit 2" {
  LS create >/dev/null; LS create >/dev/null; bind_live 01 sA; bind_live 02 sB
  run --separate-stderr env CLAUDE_CODE_SESSION_ID=sA python3 "$DAEDALUS_HOME/core/leaselib.py" board-json --session sB
  [ "$status" -eq 0 ]; bj_check 'o["this_window"] == "02" and o["windows"][0]["nn"] == "02" and o["windows"][0]["is_this"]'
  run --separate-stderr env CLAUDE_CODE_SESSION_ID=sA python3 "$DAEDALUS_HOME/core/leaselib.py" board-json
  [ "$status" -eq 0 ]; bj_check 'o["this_window"] == "01"'
  run --separate-stderr BJ
  [ "$status" -eq 0 ]; bj_check 'o["this_window"] is None and not any(w["is_this"] for w in o["windows"]) and [w["nn"] for w in o["windows"]] == ["01", "02"]'
  run --separate-stderr BJ --bogus; [ "$status" -eq 2 ]; [ -z "$output" ]; [ -n "$stderr" ]
  run --separate-stderr BJ --session; [ "$status" -eq 2 ]; [ -z "$output" ]
}

@test "board-json: prime_window is null when prime.json is absent, unclaimed, or names a session holding no window; it never marks an unclaimed lease" {
  LS create >/dev/null; LS create >/dev/null; bind_live 01 sA
  run --separate-stderr BJ --session sA; bj_check 'o["prime_window"] is None and not any(w["is_prime"] for w in o["windows"])'
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":null,"history":[]}'
  run --separate-stderr BJ --session sA; bj_check 'o["prime_window"] is None and not any(w["is_prime"] for w in o["windows"])'
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sGone","history":[]}'
  run --separate-stderr BJ --session sA; bj_check 'o["prime_window"] is None and not any(w["is_prime"] for w in o["windows"])'
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  run --separate-stderr BJ --session sB; bj_check 'o["prime_window"] == "01" and o["this_window"] is None and o["windows"][0]["is_prime"]'
}

@test "board-json: a lease file that cannot be read is reported in the object's error field and every other window still renders (exit 0: the band never goes blank over one bad file); no state/leases/ is exit 0 with no windows, and the directory stays absent" {
  LS create >/dev/null; LS create >/dev/null; LS create >/dev/null; bind_live 01 sA
  printf 'not json\n' > "$DAEDALUS_HOME/state/leases/02.json"
  run --separate-stderr BJ --session sA; [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; return 1; }
  bj_check 'sorted(o) == ["error", "generated_epoch", "prime_window", "this_window", "windows"]'
  bj_check '"The lease file for window 02 cannot be read (not valid JSON" in o["error"] and "core/lease.sh sweep" in o["error"]'
  bj_check '[w["nn"] for w in o["windows"]] == ["01", "03"] and o["this_window"] == "01"'
  [ -f "$DAEDALUS_HOME/state/leases/02.json" ]                      # reported, never removed: that is sweep's job
  rm -rf "$DAEDALUS_HOME/state/leases"
  run --separate-stderr BJ --session sA; [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; return 1; }
  bj_check 'o["windows"] == [] and o["this_window"] is None and o["prime_window"] is None and "error" not in o'
  [ ! -d "$DAEDALUS_HOME/state/leases" ]
}

@test "board-json: a resumed session (dead recorded pid, the same session live under another pid) reads live, and the lease file is not rebound" {
  LS create >/dev/null; pr="$(live_pid)"; registry_entry "$pr" sD
  set_lease 01 'dict(session_id="sD", pid=1, proc_started=1)'
  before="$(shasum -a 256 "$DAEDALUS_HOME/state/leases/01.json")"
  run --separate-stderr BJ --session sD; [ "$status" -eq 0 ]
  bj_check 'o["this_window"] == "01" and o["windows"][0]["state"] == "live" and o["windows"][0]["peer_name"] == "daedalus-xx"'
  [ "$(shasum -a 256 "$DAEDALUS_HOME/state/leases/01.json")" = "$before" ]; [ "$(lease_json 01 pid)" = "1" ]
  run board sD; [ "$(lease_json 01 pid)" = "$pr" ]       # the model-facing board is what rebinds
}

@test "board-json: a visitor (direct-call session) may read — exit 0, no window is its own" {
  LS create >/dev/null; bind_live 01 sA
  run --separate-stderr env DIRECT_CALL_ID=x python3 "$DAEDALUS_HOME/core/leaselib.py" board-json --session sV
  [ "$status" -eq 0 ] || { echo "$output"; echo "$stderr"; return 1; }
  bj_check 'o["this_window"] is None and [w["nn"] for w in o["windows"]] == ["01"]'
}

@test "board-json: runs under 1 s with 40 LIVE leases (one ps per lease; no git at all)" {
  for i in $(seq 1 40); do LS create >/dev/null; done
  for i in $(seq 1 40); do nn="$(printf '%02d' "$i")"
    set_lease "$nn" "dict(session_id='s$nn', pid=$$, proc_started=$(ps_ms $$))"
    python3 "$DAEDALUS_HOME/core/leaselib.py" heartbeat "$nn"; done
  t0="$(python3 -c 'import time; print(time.time())')"; run --separate-stderr BJ --session s01; t1="$(python3 -c 'import time; print(time.time())')"
  [ "$status" -eq 0 ]; python3 -c 'import sys; d=float(sys.argv[2])-float(sys.argv[1]); print("board-json took %.3fs" % d, file=sys.stderr); assert d < 1.0, "slow: %.2fs" % d' "$t0" "$t1"
  bj_check 'len(o["windows"]) == 40 and all(w["state"] == "live" for w in o["windows"]) and o["windows"][0]["nn"] == "01"'
}
