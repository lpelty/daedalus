#!/usr/bin/env bats
# core/amilib.py at the library level (frame-jack spec §5, §6.1, §13.2 items 14–15) and the fixtures it
# is tested with. Fixtures only: the fake decider stands in for serve; no model, no network.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
load fixtures/ami/setup.bash

setup() {
  ami_fixture
  SID=sA; export SID
  AMI="$DAEDALUS_HOME/state/ami"
  MODEL=StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
}
teardown() { teardown_live; chmod -R u+rw "$DAEDALUS_HOME/state" 2>/dev/null || true; }

# daemon_json <command> <port> <state> <heartbeat age secs> — a hand-written daemon.json
daemon_json() {
  mkdir -p "$AMI"
  ami_py 'import json, time
d = {"supervisor_pid": 1, "leash_pid": 1, "serve_pid": 1, "borrowed": False, "port": int(sys.argv[4]),
     "device": "mps", "state": sys.argv[5], "terminal": False, "since": time.time() - 12,
     "heartbeat": time.time() - float(sys.argv[6]), "ready_ms": 31000, "restarts": 0, "last_error": None,
     "off_by": None, "command": sys.argv[3], "model": "m", "offline": False, "battery_off": True,
     "request_timeout_ms": 1500, "shadow": ["destructive", "suite"], "enforce": []}
(ROOT / "state/ami/daemon.json").write_text(json.dumps(d))' "$1" "$2" "$3" "$4"
}
sw() { ami_py 'print(a.switch(ROOT, SID))'; }

@test "head: strips what the dataset builder stripped and unwrap does not — timeout N, uv run, python -m, a leading bash/sh, an absolute directory on the executable" {
  run ami_py '
cases = [(["timeout", "600", "bats", "core/tests"], ["bats", "core/tests"]),
         (["/opt/homebrew/bin/bats", "core/tests"], ["bats", "core/tests"]),
         (["uv", "run", "pytest"], ["pytest"]),
         (["python3", "-m", "pytest", "-k", "x"], ["pytest", "-k", "x"]),
         (["bash", "core/gates.sh"], ["core/gates.sh"]),
         (["sh", "-x", "core/refute.sh"], ["core/refute.sh"]),
         (["timeout", "-k", "5", "600", "uv", "run", "python", "-m", "pytest"], ["pytest"]),
         (["./core/gates.sh"], ["core/gates.sh"]),
         (["/x/y/core/promote.py", "--doctor"], ["core/promote.py", "--doctor"]),
         (["rm", "-rf", "x"], ["rm", "-rf", "x"]),
         ([], [])]
for seg, want in cases:
    got = a.head(seg)
    assert got == want, (seg, got, want)
print("ok")'
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "classify: the §6.1 table — evidence runs and the switch's own commands are none at any depth; a whole-suite bats or pytest is suite; a targeted one is none; everything else is destructive; none beats suite beats destructive" {
  run ami_py '
cases = [([["core/gates.sh"]], "none"),
         ([["bash", "core/gates.sh"]], "none"),
         ([["core/refute.sh"]], "none"),
         ([["core/promote.sh", "02"]], "none"),
         ([["python3", "core/promote.py", "--doctor"]], "none"),
         ([["python3", "core/frame-jack.py", "status"]], "none"),
         ([["python3", "core/ami-hook.py", "outcome"]], "none"),
         ([["python3", "core/ami-daemon.py", "--home", "/x"]], "none"),
         ([["bats", "core/tests"]], "suite"),
         ([["timeout", "600", "bats", "core/tests"]], "suite"),
         ([["/opt/homebrew/bin/bats", "--jobs", "8", "core/tests"]], "suite"),
         ([["bats", "core/tests/test_x.bats"]], "none"),
         ([["bats", "-f", "pat", "core/tests"]], "none"),
         ([["bats", "--filter", "pat", "core/tests"]], "none"),
         ([["pytest"]], "suite"),
         ([["uv", "run", "pytest", "tests/", "-q"]], "suite"),
         ([["python3", "-m", "pytest", "-q"]], "suite"),
         ([["pytest", "tests/test_a.py"]], "none"),
         ([["pytest", "-k", "a"]], "none"),
         ([["pytest", "tests/test_a.py::test_b"]], "none"),
         ([["rm", "-rf", "x"]], "destructive"),
         ([["git", "status"]], "destructive"),
         ([["python3", "fix.py"], ["bats", "core/tests"]], "suite"),
         ([["bats", "core/tests"], ["core/gates.sh"]], "none"),
         ([["rm", "-rf", "x"], ["python3", "core/frame-jack.py", "off"]], "none"),
         ([["rm", "-rf", "x"], ["bats", "core/tests/test_x.bats"]], "destructive"),
         ([], "none")]
for segs, want in cases:
    got = a.classify(segs)
    assert got == want, (segs, got, want)
print("ok")'
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "state text: state_destructive and state_suite over the two fixture items equal the stored score.py output after substituting the home and the scratchpad (a weaker claim than byte-equality with the lab, by design)" {
  # The home substituted is a short synthetic one, not the bats fixture's: the builder caps the previous
  # suite-run line at 400 characters (and the command at 1,800), and a home path three times longer than
  # the calibration machine's pushes that line over the cap and moves the truncation point — the builder
  # working as ported, not a port defect. A short home keeps every field under the caps it was under.
  run ami_py '
import json, os
ROOT = pathlib.Path("/d/daedalus-home")
home = str(ROOT); scratch = a.scratchpad(ROOT)
assert scratch == "/private/tmp/claude-%d/-d-daedalus-home" % os.getuid(), scratch
assert not scratch.endswith("/"), scratch
def sub(o):
    if isinstance(o, str): return o.replace("<HOME>", home).replace("<SCRATCH>", scratch)
    if isinstance(o, list): return [sub(x) for x in o]
    if isinstance(o, dict): return {k: sub(v) for k, v in o.items()}
    return o
fix = pathlib.Path(sys.argv[3])
items = [json.loads(l) for l in (fix / "items.jsonl").read_text().splitlines() if l.strip()]
assert sorted(d["kind"] for d in items) == ["destructive", "suite"]
for d in items:
    d = sub(d); d["worktree_line"] = a.worktree_line(ROOT)
    want = sub((fix / ("state-%s.txt" % d["kind"])).read_text())
    got = a.state_destructive(d) if d["kind"] == "destructive" else a.state_suite(d)
    assert "<HOME>" not in want and "<SCRATCH>" not in want
    assert home in got
    assert got == want, "\n--- got\n%s\n--- want\n%s" % (got, want)
assert a.MAX_CMD == 1800 and a.MAX_PREV == 5
assert a.trunc("x" * 10, 4) == "xxxx ...[truncated, 6 more chars]" and a.trunc(None, 4) == ""
print("ok")' "$AMI_FIX"
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "switch: absent with no state/ami; off with the directory and no sentinel (one stat each, no daemon.json read); unconfigured when daemon.json is missing or its command is not executable; down with a stale heartbeat (reason supervisor gone); the daemon.json state word for battery, starting, down, off; tripped from the counters file; down when the port refuses even though daemon.json says up; on when the port answers" {
  [ "$(sw)" = absent ]
  mkdir -p "$AMI"
  [ "$(sw)" = off ]
  printf '{"state": "up"}' > "$AMI/daemon.json"; chmod 000 "$AMI/daemon.json"
  [ "$(sw)" = off ]                                     # not read: unreadable, yet no error and no other word
  chmod 644 "$AMI/daemon.json"; rm "$AMI/daemon.json"
  touch "$AMI/on"
  [ "$(sw)" = unconfigured ]
  printf 'not executable\n' > "$BATS_TEST_TMPDIR/plain"
  daemon_json "$BATS_TEST_TMPDIR/plain" 1 up 1
  [ "$(sw)" = unconfigured ]
  daemon_json "$AMI_FIX/fake-decider" 1 up 200
  [ "$(sw)" = down ]
  run ami_py 'd = a.switch_detail(ROOT, SID); print(d["state"], d["reason"], d["port"], d["device"], d["daemon"]["heartbeat"] is not None)'
  [ "$output" = "down supervisor gone 1 mps True" ] || { echo "$output"; return 1; }
  for s in battery starting down off; do
    daemon_json "$AMI_FIX/fake-decider" 1 "$s" 1
    [ "$(sw)" = "$s" ] || { echo "state $s read as $(sw)"; return 1; }
  done
  daemon_json "$AMI_FIX/fake-decider" "$(free_port)" up 1
  ami_py 'import json, time
(ROOT / "state/ami/session-sA.json").write_text(json.dumps({"breaker": {"tripped_until": time.time() + 300, "trips": 1}}))'
  [ "$(sw)" = tripped ]
  run ami_py 'd = a.switch_detail(ROOT, SID); print(d["state"], d["retry_epoch"] is not None)'
  [ "$output" = "tripped True" ]
  rm "$AMI/session-sA.json"
  [ "$(sw)" = down ]                                    # the port refuses although daemon.json says up
  run ami_py 'd = a.switch_detail(ROOT, SID); print(d["state"], d["reason"])'
  [ "$output" = "down down" ] || { echo "$output"; return 1; }
  start_fake "$MODEL"
  daemon_json "$AMI_FIX/fake-decider" "$FAKE_PORT" up 1
  [ "$(sw)" = on ]
  run ami_py 'd = a.switch_detail(ROOT, SID); print(d["state"], d["reason"], d["port"], d["since_epoch"] is not None)'
  [ "$output" = "on None $FAKE_PORT True" ] || { echo "$output"; return 1; }
  run ami_py 'print(a.switch(ROOT, None))'          # a shell: no counters file to read, still a word
  [ "$output" = on ]
}

@test "ask: one POST per question in the fake's log; Answer carries p, latency_ms, input_tokens and max_length; a closed port is Unanswered down; FAKE_DELAY_MS past the deadline is Unanswered timeout and returns before the deadline plus 100 ms; less than 300 ms remaining sends nothing (budget); a 500 is http 500; a body without a float is bad answer" {
  mkdir -p "$AMI"
  LOCK="$AMI/.ask.lock"
  FAKE_LOG="$BATS_TEST_TMPDIR/one.log" start_fake "$MODEL" FAKE_P=0.7
  run ami_py 'import time
r = a.ask(int(sys.argv[3]), "the state", "destructive", time.monotonic() + 3, 1500, sys.argv[4], max_length=4096)
print(type(r).__name__, r.p, r.latency_ms > 0, r.queued_ms >= 0, r.input_tokens, r.max_length)' "$FAKE_PORT" "$LOCK"
  [ "$output" = "Answer 0.7 True True 2 4096" ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$BATS_TEST_TMPDIR/one.log")" -eq 1 ]
  run python3 -c 'import json,sys; r=json.loads(open(sys.argv[1]).read()); print(r["method"], r["path"], r["question"])' "$BATS_TEST_TMPDIR/one.log"
  [ "$output" = "POST /v1/systemone Would running this command destroy or permanently lose data that cannot be recovered?" ] || { echo "$output"; return 1; }
  run ami_py 'import time
r = a.ask(int(sys.argv[3]), "s", "suite", time.monotonic() + 3, 1500, sys.argv[4]); print(type(r).__name__, r.reason)' "$(free_port)" "$LOCK"
  [ "$output" = "Unanswered down" ] || { echo "$output"; return 1; }
  FAKE_LOG="$BATS_TEST_TMPDIR/slow.log" start_fake "$MODEL" FAKE_DELAY_MS=2000
  run ami_py 'import time
t0 = time.monotonic(); r = a.ask(int(sys.argv[3]), "s", "destructive", t0 + 0.5, 5000, sys.argv[4]); el = time.monotonic() - t0
print(type(r).__name__, r.reason, el < 0.6, round(el, 2))' "$FAKE_PORT" "$LOCK"
  case "$output" in "Unanswered timeout True "*) ;; *) echo "$output"; return 1 ;; esac
  run ami_py 'import time
r = a.ask(int(sys.argv[3]), "s", "destructive", time.monotonic() + 0.1, 1500, sys.argv[4]); print(type(r).__name__, r.reason)' "$FAKE_PORT" "$LOCK"
  [ "$output" = "Unanswered budget" ] || { echo "$output"; return 1; }
  sleep 2.2                                             # the slow fake finishes its one request
  [ "$(wc -l < "$BATS_TEST_TMPDIR/slow.log")" -eq 1 ]   # the budget case sent nothing
  FAKE_LOG="$BATS_TEST_TMPDIR/500.log" start_fake "$MODEL" FAKE_STATUS=500
  run ami_py 'import time
r = a.ask(int(sys.argv[3]), "s", "destructive", time.monotonic() + 3, 1500, sys.argv[4]); print(type(r).__name__, r.reason)' "$FAKE_PORT" "$LOCK"
  [ "$output" = "Unanswered http 500" ] || { echo "$output"; return 1; }
  FAKE_LOG="$BATS_TEST_TMPDIR/bad.log" start_fake "$MODEL" FAKE_BAD_ANSWER=1
  run ami_py 'import time
r = a.ask(int(sys.argv[3]), "s", "destructive", time.monotonic() + 3, 1500, sys.argv[4]); print(type(r).__name__, r.reason)' "$FAKE_PORT" "$LOCK"
  [ "$output" = "Unanswered bad answer" ] || { echo "$output"; return 1; }
}

@test "ask: the ask lock serialises callers of one deployment — two asks started together against FAKE_DELAY_MS=400 do not overlap in the fake's log, the second carries queued_ms > 0; a lock not free before the deadline is Unanswered busy" {
  mkdir -p "$AMI"
  LOCK="$AMI/.ask.lock"
  FAKE_LOG="$BATS_TEST_TMPDIR/two.log" start_fake "$MODEL" FAKE_DELAY_MS=400
  code='import time, json
r = a.ask(int(sys.argv[3]), "s", "destructive", time.monotonic() + 5, 3000, sys.argv[4])
print(json.dumps({"kind": type(r).__name__, "queued_ms": getattr(r, "queued_ms", None), "latency_ms": getattr(r, "latency_ms", None)}))'
  ami_py "$code" "$FAKE_PORT" "$LOCK" > "$BATS_TEST_TMPDIR/r1" 3>&- & P1=$!
  ami_py "$code" "$FAKE_PORT" "$LOCK" > "$BATS_TEST_TMPDIR/r2" 3>&- & P2=$!
  wait "$P1" "$P2"                                     # named: a bare wait would also wait for the fake
  run python3 -c 'import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(rows) == 2, rows
rows.sort(key=lambda r: r["t0"])
assert rows[0]["t1"] <= rows[1]["t0"], ("overlap", rows)
rs = [json.loads(open(p).read()) for p in sys.argv[2:]]
assert all(r["kind"] == "Answer" for r in rs), rs
q = sorted(r["queued_ms"] for r in rs)
assert q[0] < 100 and q[1] > 200, q
assert max(r["latency_ms"] for r in rs) >= q[1], rs
print("ok")' "$BATS_TEST_TMPDIR/two.log" "$BATS_TEST_TMPDIR/r1" "$BATS_TEST_TMPDIR/r2"
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; cat "$BATS_TEST_TMPDIR/r1" "$BATS_TEST_TMPDIR/r2"; return 1; }
  python3 -c 'import fcntl, os, time, sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(2)' "$LOCK" 3>&- </dev/null &
  HOLDER=$!; printf '%s\n' "$HOLDER" >> "$BATS_TEST_TMPDIR/live-pids"
  sleep 0.3
  run ami_py 'import time
t0 = time.monotonic(); r = a.ask(int(sys.argv[3]), "s", "destructive", t0 + 0.6, 3000, sys.argv[4]); el = time.monotonic() - t0
print(type(r).__name__, r.reason, el < 0.8)' "$FAKE_PORT" "$LOCK"
  [ "$output" = "Unanswered busy True" ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$BATS_TEST_TMPDIR/two.log")" -eq 2 ]    # busy sent nothing
}

@test "append_row and the counters: six rows give asked.destructive 6, would_ask by the 0.326 cut, latency_ms [sum, n, max], recent_would_ask holds the heads, unanswered counts by reason; the counters file is written tmp + rename (no .tmp left, a reader mid-write sees a whole file); the daily log is state/ami/decisions/YYYY-MM-DD.jsonl with one JSON object per line" {
  mkdir -p "$AMI"; touch "$AMI/on"
  run ami_py '
import json, time, os
ps = [0.1, 0.2, 0.33, 0.5, 0.326, 0.3]
for i, p in enumerate(ps):
    dec = a.decide("destructive", p)
    row = {"t": time.time(), "session": SID, "window": None, "tool_use_id": "toolu_%d" % i, "question": "destructive",
           "device": "mps", "p": p, "threshold": 0.326, "would_ask": dec["would_ask"], "mode": "shadow", "acted": None,
           "unanswered": None, "latency_ms": 100 + i, "input_tokens": 400, "state_truncated": False,
           "guard": "warning: contested path" if i == 2 else "allow", "command_sha": "x", "command_head": "cmd %d" % i,
           "state_sha": "y", "cwd": "/w", "tree": "/w", "git_branch": "main",
           "state_inputs": {"operator_message": "recorded", "previous_tool_calls": 5, "branch": "transcript"},
           "edited_since_run": None}
    a.append_row(ROOT, SID, row)
    c = a.counters(ROOT, SID)
    assert isinstance(c, dict) and c["asked"]["destructive"] == i + 1, c
    assert not [f for f in os.listdir(ROOT / "state/ami") if f.endswith(".tmp")]
a.row_unanswered(ROOT, SID, {"tool_use_id": "toolu_u1", "tool_input": {"command": "rm -rf x"}, "cwd": "/w"}, "down", "destructive")
a.row_unanswered(ROOT, SID, {"tool_use_id": "toolu_u2", "tool_input": {"command": "bats core/tests"}, "cwd": "/w"}, "timeout", "suite")
a.row_unanswered(ROOT, SID, {"tool_use_id": "toolu_u3", "tool_input": {"command": "rm -rf y"}, "cwd": "/w"}, "timeout", "destructive")
c = a.counters(ROOT, SID)
assert c["asked"] == {"destructive": 6, "suite": 0}, c["asked"]
assert c["would_ask"] == 3 and c["would_shorten"] == 0, c
assert c["latency_ms"] == [615, 6, 105], c["latency_ms"]
assert c["recent_would_ask"] == ["cmd 2", "cmd 3", "cmd 4"], c["recent_would_ask"]
assert c["would_ask_with_guard_warning"] == 1, c
assert c["unanswered"] == {"down": 1, "timeout": 2}, c["unanswered"]
assert c["asks"] == 0 and c["overrides"] == 0 and c["last_question_epoch"] > 0
for k in ("shortened_then_failed", "would_ask_then_failed", "breaker", "operator", "suite"):
    assert k in c, k
log = ROOT / "state/ami/decisions" / (time.strftime("%Y-%m-%d") + ".jsonl")
assert log.is_file(), log
rows = [json.loads(l) for l in log.read_text().splitlines()]
assert len(rows) == 9 and all(isinstance(r, dict) for r in rows), len(rows)
assert rows[6]["unanswered"] == "down" and rows[6]["question"] == "destructive" and rows[6]["p"] is None
assert rows[6]["command_head"] == "rm -rf x" and len(rows[6]["command_sha"]) == 64 and rows[6]["tool_use_id"] == "toolu_u1"
assert rows[7]["question"] == "suite" and rows[7]["session"] == SID and rows[7]["mode"] == "shadow"
assert sorted(os.listdir(ROOT / "state/ami")) == [".lock", "decisions", "on", "session-sA.json"], os.listdir(ROOT / "state/ami")
b = a.board_ami(ROOT, SID)
assert b["asked"] == 6 and b["would_ask"] == 3 and b["unanswered"] == 3 and b["median_ms"] == 103, b
assert b["state"] == "unconfigured" and b["mode"] == "shadow" and b["port_alive"] is False, b
assert sorted(b) == sorted(["state", "mode", "port_alive", "device", "asked", "would_ask", "would_shorten", "unanswered", "median_ms", "asks", "overrides", "since_epoch", "retry_epoch"]), sorted(b)
b2 = a.board_ami(ROOT, "sNone")
assert b2["asked"] is None and b2["would_ask"] is None and b2["median_ms"] is None and b2["state"] == "unconfigured", b2
print("ok")'
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "decide: in shadow would_ask / would_shorten are computed and acted is None with no emit; with certified=('destructive',) a p at or above 0.326 emits permissionDecision ask with the reason sentence naming the percentage, descriptor first; with certified=('suite',) a 1 − p below 0.391 emits the deny-once reason naming the targeted command and the evidence-run sentence, and the same command with the same snapshot re-issued is not denied again" {
  run ami_py '
assert a.CERTIFIED == ()
assert set(a.QUESTIONS) == {"destructive", "suite"}
assert a.QUESTIONS["destructive"][2] == 0.326 and a.QUESTIONS["suite"][2] == 0.391
d = a.decide("destructive", 0.44)
assert d == {"would_ask": True, "acted": None, "emit": None, "mode": "shadow"}, d
d = a.decide("destructive", 0.1)
assert d["would_ask"] is False and d["acted"] is None and d["emit"] is None, d
d = a.decide("destructive", 0.1, certified=("destructive",))
assert d["would_ask"] is False and d["acted"] is None and d["emit"] is None and d["mode"] == "enforce", d
d = a.decide("destructive", 0.44, certified=("destructive",))
assert d["would_ask"] is True and d["acted"] == "ask", d
h = d["emit"]["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse" and h["permissionDecision"] == "ask", h
assert h["permissionDecisionReason"] == "The AMI rates this command destructive — 44 % confidence that it would permanently lose data that cannot be recovered. Confirm to run it.", h
assert a.decide("destructive", 0.326, certified=("destructive",))["acted"] == "ask"
assert a.decide("destructive", 0.3259, certified=("destructive",))["acted"] is None
d = a.decide("suite", 0.7)
assert d == {"would_shorten": True, "acted": None, "emit": None, "mode": "shadow"}, d
assert a.decide("suite", 0.5)["would_shorten"] is False
edited = ["core/tests/test_lease.bats", "core/tests/test_doctor.bats"]
d = a.decide("suite", 0.7, certified=("suite",), edited=edited, targeted=edited, reissued=False)
assert d["would_shorten"] is True and d["acted"] == "deny-once", d
h = d["emit"]["hookSpecificOutput"]
assert h["permissionDecision"] == "deny", h
assert h["permissionDecisionReason"] == "The AMI judges a targeted run sufficient for the files edited since the last run (core/tests/test_lease.bats, core/tests/test_doctor.bats): run those first — bats core/tests/test_lease.bats core/tests/test_doctor.bats. Re-issue the full run unchanged to run it anyway; the evidence run (core/gates.sh) is never gated.", h
d = a.decide("suite", 0.7, certified=("suite",), edited=edited, targeted=edited, reissued=True)
assert d["would_shorten"] is True and d["acted"] is None and d["emit"] is None, d
d = a.decide("suite", 0.7, certified=("suite",), edited=["core/x.py"], targeted=[], reissued=False)
assert d["acted"] is None and d["emit"] is None, d
d = a.decide("suite", 0.7, certified=("suite",), edited=["tests/test_a.py"], targeted=["tests/test_a.py"], reissued=False)
assert "run those first — pytest tests/test_a.py." in d["emit"]["hookSpecificOutput"]["permissionDecisionReason"], d
assert a.decide("suite", 0.5, certified=("suite",), edited=edited, targeted=edited, reissued=False)["acted"] is None
print("ok")'
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "record_operator_message: nothing is written while the sentinel is absent (one stat); with it, session-<sid>.json gains operator {text capped at 600, epoch, transcript_offset}" {
  mkdir -p "$AMI"
  ami_py 'a.record_operator_message(ROOT, SID, "hello", "/t/x.jsonl", 10)'
  [ ! -e "$AMI/session-sA.json" ]
  [ "$(ls "$AMI")" = "" ]
  touch "$AMI/on"
  run ami_py 'import json, time
a.record_operator_message(ROOT, SID, "x" * 700, "/t/x.jsonl", 1234)
c = json.loads((ROOT / "state/ami/session-sA.json").read_text())
o = c["operator"]
assert len(o["text"]) == 600 and abs(o["epoch"] - time.time()) < 5 and o["transcript_offset"] == 1234 and o["transcript_path"] == "/t/x.jsonl", o
assert c["asked"] == {"destructive": 0, "suite": 0}
a.record_operator_message(ROOT, SID, "second", "/t/x.jsonl", 2000)
c = json.loads((ROOT / "state/ami/session-sA.json").read_text())
assert c["operator"]["text"] == "second" and c["operator"]["transcript_offset"] == 2000
import os
assert not [f for f in os.listdir(ROOT / "state/ami") if f.endswith(".tmp")]
print("ok")'
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "build_inputs: the previous five tool calls and git_branch come from the transcript region after the recorded offset; with fewer than five calls there, the 256 KB before the offset are read too; a region past 2 MB is capped and state_inputs.region_capped is true; no operator record gives operator_message missing and the state says (none recorded)" {
  mkdir -p "$AMI"; touch "$AMI/on"
  T="$BATS_TEST_TMPDIR/transcripts/sA.jsonl"; mkdir -p "$BATS_TEST_TMPDIR/transcripts"
  run ami_py '
import json, time
t = pathlib.Path(sys.argv[3])
def entry(kind, **kw):
    e = {"type": kind, "cwd": "/w", "gitBranch": kw.pop("branch", "lease/02"), "timestamp": "2026-10-15T00:00:00Z", "sessionId": SID}
    e.update(kw); return json.dumps(e) + "\n"
def call(i, name="Bash", branch="lease/02"):
    inp = {"file_path": "f%d" % i} if name == "Edit" else {"command": "cmd %d" % i, "description": "d"}
    return entry("assistant", branch=branch, message={"role": "assistant", "content": [{"type": "text", "text": "t"}, {"type": "tool_use", "id": "toolu_%d" % i, "name": name, "input": inp}]})
def result(i, branch="lease/02"):
    return entry("user", branch=branch, message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_%d" % i, "content": "out"}]})
before = entry("user", message={"role": "user", "content": "first prompt"}, origin={"kind": "human"})
for i in range(1, 4):
    before += call(i) + result(i)
before += entry("user", message={"role": "user", "content": "do the thing"}, origin={"kind": "human"})
after = ""
for i in range(4, 11):
    br = "lease/02" if i < 10 else "lease/03"
    after += call(i, name="Edit" if i == 7 else "Bash", branch=br) + result(i, branch=br)
t.write_text(before + after)
off = len(before.encode())
a.record_operator_message(ROOT, SID, "do the thing", str(t), off)
payload = {"tool_use_id": "toolu_99", "transcript_path": str(t), "tool_input": {"command": "rm x", "description": "del"}, "cwd": "/w"}
d = a.build_inputs(ROOT, SID, payload, "/w")
assert d["previous_tool_calls"] == ["Bash: cmd 6", "Edit: f7", "Bash: cmd 8", "Bash: cmd 9", "Bash: cmd 10"], d["previous_tool_calls"]
assert d["git_branch"] == "lease/03" and d["cwd"] == "/w" and d["command"] == "rm x" and d["description"] == "del", d
assert d["last_operator_message"] == "do the thing" and d["continuation_summary_since_operator"] is False
assert d["state_inputs"] == {"operator_message": "recorded", "previous_tool_calls": 5, "branch": "transcript", "region_capped": False}, d["state_inputs"]
assert d["worktree_line"] == a.worktree_line(ROOT)
s = a.state_destructive(d)
assert "The operator'"'"'s last message was: \"do the thing\"" in s and "branch lease/03" in s and "  - Bash: cmd 10\n" in s, s
# the current call is already in the transcript: it is not its own previous call
payload["tool_use_id"] = "toolu_10"
assert a.build_inputs(ROOT, SID, payload, "/w")["previous_tool_calls"] == ["Bash: cmd 5", "Bash: cmd 6", "Edit: f7", "Bash: cmd 8", "Bash: cmd 9"]
# fewer than five calls after the offset: the 256 KB before it are read too
off2 = len((before + after).encode()) - len((call(10, branch="lease/03") + result(10, branch="lease/03")).encode())
a.record_operator_message(ROOT, SID, "late", str(t), off2)
payload["tool_use_id"] = "toolu_99"
d = a.build_inputs(ROOT, SID, payload, "/w")
assert d["previous_tool_calls"] == ["Bash: cmd 6", "Edit: f7", "Bash: cmd 8", "Bash: cmd 9", "Bash: cmd 10"], d["previous_tool_calls"]
assert d["state_inputs"]["previous_tool_calls"] == 5 and d["state_inputs"]["region_capped"] is False
# a region past 2 MB is capped at the last 2 MB
pad = entry("user", message={"role": "user", "content": "p" * (2500 * 1024)})
with t.open("a") as fh:
    fh.write(pad + call(11) + result(11) + call(12) + result(12))
a.record_operator_message(ROOT, SID, "do the thing", str(t), off)
d = a.build_inputs(ROOT, SID, payload, "/w")
assert d["state_inputs"]["region_capped"] is True, d["state_inputs"]
assert d["previous_tool_calls"][-2:] == ["Bash: cmd 11", "Bash: cmd 12"] and d["git_branch"] == "lease/02", d["previous_tool_calls"]
# no operator record (another session): missing, and the state says (none recorded); the calls still come from the tail
d = a.build_inputs(ROOT, "sB", payload, "/w")
assert d["last_operator_message"] is None and d["state_inputs"]["operator_message"] == "missing", d
assert d["previous_tool_calls"][-2:] == ["Bash: cmd 11", "Bash: cmd 12"], d["previous_tool_calls"]
assert "The operator'"'"'s last message was: \"(none recorded)\"" in a.state_destructive(d)
# a transcript that is not there: nothing raises, the inputs say so
payload["transcript_path"] = str(t) + ".missing"
d = a.build_inputs(ROOT, SID, payload, "/w")
assert d["previous_tool_calls"] == [] and d["git_branch"] == "(unknown)" and d["state_inputs"]["branch"] == "missing", d
assert "Previous tool calls (oldest first):\n  (none)\n" in a.state_destructive(d)
print("ok")' "$T"
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "the fake: /health reports model as the basename and checkpoint verbatim; --port 0 prints the port first; FAKE_EXIT_WEIGHTS prints the weights error and exits 1" {
  start_fake "StrandsAgents/x-2B"
  case "$FAKE_PORT" in ''|*[!0-9]*) echo "not a port: $FAKE_PORT"; return 1 ;; esac
  run python3 -c 'import json, sys, urllib.request
h = json.loads(urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read())
print(h["model"], h["checkpoint"], h["device"], h["max_length"], h["status"])' "$FAKE_PORT"
  [ "$output" = "x-2B StrandsAgents/x-2B mps 4096 ok" ] || { echo "$output"; return 1; }
  run python3 -c 'import json, sys, urllib.request
body = json.dumps({"state": "s", "questions": {"q": {"type": "noul", "instructions": "Is it?"}}}).encode()
r = json.loads(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:%s/v1/systemone" % sys.argv[1], data=body, headers={"Content-Type": "application/json"}), timeout=2).read())
print(r["answers"]["q"]["noul"], r["usage"]["input_tokens"] >= 1)' "$FAKE_PORT"
  [ "$output" = "0.5 True" ] || { echo "$output"; return 1; }
  kill "$FAKE_PID"; sleep 0.3
  ! kill -0 "$FAKE_PID" 2>/dev/null
  run --separate-stderr env FAKE_EXIT_WEIGHTS=1 "$AMI_FIX/fake-decider" serve "$MODEL" --port 0 --device mps
  [ "$status" -eq 1 ]
  case "$stderr" in *"LocalEntryNotFoundError: not found in cache"*) ;; *) echo "$stderr"; return 1 ;; esac
  run env FAKE_POWER='Battery Power' pmset -g batt
  [ "${lines[0]}" = "Now drawing from 'Battery Power'" ]
  printf 'AC Power' > "$BATS_TEST_TMPDIR/power"
  run env FAKE_POWER='Battery Power' FAKE_POWER_FILE="$BATS_TEST_TMPDIR/power" pmset -g batt
  [ "${lines[0]}" = "Now drawing from 'AC Power'" ]
}
