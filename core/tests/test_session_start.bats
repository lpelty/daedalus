#!/usr/bin/env bats
# SessionStart: the marker (root of trust for every later check) and, since
# v0.7.0, the binding that precedes it — DAEDALUS_LEASE, self-rebind,
# auto-numbering of terminal windows, first-up prime (spec §4.2, §4.8).
# Wall-clock assertions live in this file: under the parallel full-suite gate
# (`bats --jobs 12`) its tests run one at a time, while other files run beside it.
BATS_NO_PARALLELIZE_WITHIN_FILE=true
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; }
teardown() { teardown_live; }
start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"%s","transcript_path":"%s/transcripts/%s.jsonl"}' "$1" "$2" "$BATS_TEST_TMPDIR" "$1" | python3 "$DAEDALUS_HOME/core/session-start.py"; }
first_line() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"].splitlines()[0])'; }

@test "startup writes the marker with vault head, config sha, and protected snapshot; compact preserves it" {
  printf 'dirty\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run start s1 startup
  [ "$status" -eq 0 ]
  m="$DAEDALUS_HOME/state/session-s1.json"
  [ -f "$m" ]
  [ "$(grep -c '"vault_head"' "$m")" -eq 1 ]
  # CLAUDE.md appears three times by design: once in the protected_status
  # porcelain line, once as the protected_snapshot dict key, and once inside
  # that entry's own "line" field (the porcelain line kept alongside the hash).
  [ "$(grep -c 'CLAUDE.md' "$m")" -eq 3 ]
  [ "$(python3 -c "import json,sys; print('CLAUDE.md' in json.load(open('$m'))['protected_snapshot'])")" = "True" ]
  case "$output" in *"uncommitted changes"*) : ;; *) echo "no operator-dirt notice: $output"; return 1 ;; esac
  before="$(cat "$m")"
  git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m later
  git -C "$DAEDALUS_HOME" checkout -- CLAUDE.md
  run start s1 compact
  [ "$(cat "$m")" = "$before" ]
  case "$output" in *"CLAUDE.md"*) : ;; *) echo "compact notice lost the marker's protected snapshot: $output"; return 1 ;; esac
}

@test "session-start notes the stage is unarmed when vault/evidence is empty; clears once one evidence doc exists" {
  # Finding 1, session-start.py half: same NOTE as doctor.sh, surfaced in
  # additionalContext so it's the first thing the operator sees.
  run start s7 startup
  [ "$status" -eq 0 ]
  case "$output" in *"verify: stage unarmed"*"run core/gates.sh once to arm it"*) : ;; *) echo "expected the unarmed notice; got: $output"; return 1 ;; esac

  cat > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md" <<'EOF'
---
type: evidence
created: 2026-01-01T00:00:00
result: PASS
fingerprint: deadbeef
config-sha: deadbeef
---
EOF
  run start s8 startup
  [ "$status" -eq 0 ]
  case "$output" in *"stage unarmed"*) echo "notice should have cleared once evidence exists: $output"; return 1 ;; *) : ;; esac
}

@test "a second startup payload for the same session id never overwrites the marker" {
  # Finding 3: source used to gate whether an existing marker got
  # overwritten (startup/fork always rewrote), which meant a claim made
  # before a mid-session `startup`/`fork` payload could fall outside the
  # window it was actually made in. The marker is now written only when
  # absent for this session id, regardless of source.
  run start s6 startup
  [ "$status" -eq 0 ]
  m="$DAEDALUS_HOME/state/session-s6.json"
  [ -f "$m" ]
  before="$(cat "$m")"
  # Change tree state that would visibly alter a freshly-computed marker
  # (vault head moves, a new protected-file edit appears) so a rewrite would
  # not be byte-identical to the original by coincidence.
  git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m later
  printf 'more dirt\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run start s6 startup
  [ "$status" -eq 0 ]
  [ "$(cat "$m")" = "$before" ]
}

@test "a claim committed by a crashed session is still found; a cited-and-passing claim is not" {
  printf -- '---\ntype: evidence\nrun-id: 20260101-000000-abcdef\nresult: PASS\ncreated: 2026-01-01T00:00:00\n---\n' > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md"
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-02-01\n---\n# Committed\n' > "$DAEDALUS_HOME/vault/proposals/PROP-COMMITTED.md"
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-02-01\nevidence-run: 20260101-000000-abcdef\n---\n# Cited\n' > "$DAEDALUS_HOME/vault/proposals/PROP-CITED.md"
  git -C "$DAEDALUS_HOME/vault" add -A
  git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q -m "crashed session's claims"
  run start s3 startup
  [ "$status" -eq 0 ]
  case "$output" in *"PROP-COMMITTED.md"*"no evidence-run"*) : ;; *) echo "committed claim not announced: $output"; return 1 ;; esac
  case "$output" in *"PROP-CITED.md"*) echo "cited-and-passing claim wrongly flagged: $output"; return 1 ;; *) : ;; esac
}

@test "an unverified claim from a crashed session is announced at start" {
  printf -- '---\ntype: evidence\nrun-id: 20260101-000000-abcdef\nresult: PASS\ncreated: 2026-01-01T00:00:00\n---\n' > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md"
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-02-01\n---\n# P\n' > "$DAEDALUS_HOME/vault/proposals/PROP-9.md"
  run start s2 startup
  [ "$status" -eq 0 ]
  case "$output" in *"PROP-9.md"*"no evidence-run"*) : ;; *) echo "claim not announced: $output"; return 1 ;; esac
}

@test "a resume with an existing marker announces the original snapshot and the re-baseline path" {
  # PROP-017 finding 3: "restart the session — it re-snapshots" was false
  # under resume (--continue reuses the session id; the marker is write-once).
  # The marker stays write-once — the fix is saying so, with the operator's
  # actual escape named.
  run start sR startup
  [ "$status" -eq 0 ]
  run start sR resume
  [ "$status" -eq 0 ]
  case "$output" in *"resumed with its original snapshot"*"session-sR.json"*) : ;; *) echo "resume note missing: $output"; return 1 ;; esac
  # compact stays silent about it (mid-session, not an operator restart)
  run start sR compact
  case "$output" in *"resumed with its original snapshot"*) echo "compact must not carry the resume note: $output"; return 1 ;; *) : ;; esac
}

@test "startup (PROP-019): records target_branch and target_base from config; announces when origin/<branch> cannot be resolved" {
  # lease_fixture already built target/thing with origin/main; this case needs
  # an origin that has only mainline, so the target is rebuilt from scratch.
  T="$DAEDALUS_HOME/target/thing"; rm -rf "$T"; mkdir -p "$DAEDALUS_HOME/target"
  git init -q -b mainline "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q --bare "$BATS_TEST_TMPDIR/o.git"; git -C "$T" remote add origin "$BATS_TEST_TMPDIR/o.git"; git -C "$T" push -q origin mainline
  # config says main, origin only has mainline: the marker must record the failure by name and the hook must say so at start
  run start sA startup
  [ "$status" -eq 0 ]
  case "$output" in *"Promotion gate"*"origin/main"*) : ;; *) echo "start did not announce the unresolvable gate: $output"; return 1 ;; esac
  python3 - "$DAEDALUS_HOME/state/session-sA.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["target_branch"] == "main", m
import time; assert abs(float(m["started_epoch"]) - time.time()) < 120, m   # the absolute instant beside the local stamp
assert m["target_base"] == "", m
assert "main" in m["target_base_error"], m
PY
  # config fixed to mainline: the marker records the branch and its origin sha; no announcement
  sed -i.bak 's/^  branch: main$/  branch: mainline/' "$DAEDALUS_HOME/config.yaml"; rm -f "$DAEDALUS_HOME/config.yaml.bak"
  run start sB startup
  [ "$status" -eq 0 ]
  case "$output" in *"Promotion gate"*) echo "resolved gate must not announce: $output"; return 1 ;; *) : ;; esac
  python3 - "$DAEDALUS_HOME/state/session-sB.json" "$(git -C "$T" rev-parse origin/mainline)" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["target_branch"] == "mainline" and m["target_base"] == sys.argv[2] and m["target_base_error"] == "", m
PY
}

# --- v0.7.0: binding before the marker (spec §4.2 steps 1–7, §4.8, §8.2) -----

@test "an interactive SessionStart with no lease auto-numbers 01, creates the worktree bound to this session, first-ups prime, and its orientation line is the first line" {
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  run start sN startup; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ]
  case "$output" in *"You are window 01 and you hold the pen (prime): hot.md, vault commits, promote."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"/rename"*) echo "registry name already daedalus-01: no courtesy expected: $output"; return 1 ;; *) : ;; esac
  [ "$(lease_json 01 session_id)" = "sN" ]; [ "$(lease_json prime session_id)" = "sN" ]
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  python3 - "$DAEDALUS_HOME/state/session-sN.json" "$(git -C "$T" rev-parse origin/main)" <<'PY'
import json,sys; m=json.load(open(sys.argv[1]))
assert m["target_base"]==sys.argv[2] and m["target_base_error"]=="" and m["lease"]=="01", m
assert m["transcript_path"].endswith("/transcripts/sN.jsonl"), m
PY
}

@test "a second interactive window numbers 02 and does not take the pen; a derived registry name gets the one-time /rename courtesy" {
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; start sA startup >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-x7
  run start sB startup
  [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ]
  case "$output" in *"You are window 02."*"you may \`/rename daedalus-02\`"*"optional"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
}

@test "03 with 01 present and a swept 02 whose branch has unpromoted commits" {
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  W="$DAEDALUS_HOME/worktrees/02/thing"; printf 'w\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am waiting
  rm -f "$DAEDALUS_HOME/state/leases/02.json"
  p3="$(live_pid)"; registry_entry "$p3" sC
  run start sC startup; [ "$(first_line)" = "Daedalus session orientation: window 03, $DAEDALUS_HOME" ]
}

@test "DAEDALUS_LEASE=02 with a null lease binds it and the marker has target_base set and no error; bound to a live other session it is ignored with the message and an interactive window auto-numbers anyway" {
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null; bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  run env DAEDALUS_LEASE=02 bash -c "$(declare -f start); start sH startup"
  [ "$status" -eq 0 ]; [ "$(lease_json 02 session_id)" = "sH" ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["target_base"] and not m["target_base_error"], m' "$DAEDALUS_HOME/state/session-sH.json"
  pid="$(live_pid)"; registry_entry "$pid" sH interactive cli daedalus-02
  # The lease reads as bind would have written it for a registered session:
  # pid, proc_started AND peer_name (the refusal names the holder by peer name).
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["pid"]='"$pid"'; d["proc_started"]=json.load(open(sys.argv[2]))["startedAt"]; d["peer_name"]="daedalus-02"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json" "$BATS_TEST_TMPDIR/sessions/$pid.json")"
  p2="$(live_pid)"; registry_entry "$p2" sJ interactive cli daedalus-03
  run env DAEDALUS_LEASE=02 bash -c "$(declare -f start); start sJ startup"
  case "$output" in *"DAEDALUS_LEASE=02\` ignored: window 02 is held by a live session (peer name daedalus-02)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 02 session_id)" = "sH" ]; [ "$(lease_json 03 session_id)" = "sJ" ]
}

@test "a headless session (entrypoint sdk-cli, and separately kind bg) never auto-numbers or first-ups: state/leases stays empty and the unleased nag is injected; with DAEDALUS_LEASE=02 it binds 02 and nothing else" {
  # live pids: a dead pid is filtered out before kind/entrypoint are read, which would pass this test for the wrong reason
  pp="$(live_pid)"; registry_entry "$pp" sP interactive sdk-cli; run start sP startup
  [ -z "$(ls "$DAEDALUS_HOME/state/leases"/*.json 2>/dev/null)" ]
  [ "$(first_line)" = "Daedalus session orientation: unleased, $DAEDALUS_HOME" ]
  case "$output" in *"core/lease.sh create"*"claim"*) : ;; *) echo "$output"; return 1 ;; esac
  pq="$(live_pid)"; registry_entry "$pq" sQ bg cli; run start sQ startup
  [ -z "$(ls "$DAEDALUS_HOME/state/leases"/*.json 2>/dev/null)" ]
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null; bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  run env DAEDALUS_LEASE=02 bash -c "$(declare -f start); start sQ startup"
  [ "$(lease_json 02 session_id)" = "sQ" ]; [ "$(lease_json 01 session_id)" = "None" ]; [ ! -f "$DAEDALUS_HOME/state/leases/prime.json" ]
}

@test "a visitor (DIRECT_CALL_ID set) with no prime leaves state/leases empty and gets the visitor line" {
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f start); start sV startup"
  [ -z "$(ls "$DAEDALUS_HOME/state/leases"/*.json 2>/dev/null)" ]
  [ "$(first_line)" = "Daedalus session orientation: visitor, $DAEDALUS_HOME" ]
  case "$output" in *"This is a direct-call session; it holds no lease and cannot take the pen."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "with no registry, nothing numbers itself or takes the pen (there is no /dev/tty fallback: hooks cannot open it); DAEDALUS_LEASE binds and no prime.json appears" {
  # The pen on such a build comes from `core/lease.sh prime take` out of that
  # window's Bash tool — pinned in test_lease.bats once prime take exists (Task 7).
  rm -rf "$BATS_TEST_TMPDIR/sessions"
  run start sT startup
  [ -z "$(ls "$DAEDALUS_HOME/state/leases"/*.json 2>/dev/null)" ]
  [ "$(first_line)" = "Daedalus session orientation: unleased, $DAEDALUS_HOME" ]
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  run env DAEDALUS_LEASE=01 bash -c "$(declare -f start); start sT startup"
  [ "$(lease_json 01 session_id)" = "sT" ]; [ ! -f "$DAEDALUS_HOME/state/leases/prime.json" ]
  [ "$(first_line)" = "Daedalus session orientation: window 01, $DAEDALUS_HOME" ]
}

@test "a registry that is present but has no entry for this session id: not numbered, not first-upped, orientation unleased" {
  run start sM startup; [ "$status" -eq 0 ]
  [ -z "$(ls "$DAEDALUS_HOME/state/leases"/*.json 2>/dev/null)" ]
  [ "$(first_line)" = "Daedalus session orientation: unleased, $DAEDALUS_HOME" ]
}

@test "a second window's SessionStart does not deadlock on the lease lock: it returns in under 5 s" {
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; start sA startup >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02
  run python3 -c 'import os,subprocess,sys,time
t=time.time()
p=subprocess.run(["python3","core/session-start.py"],input=sys.argv[1],cwd=os.environ["DAEDALUS_HOME"],capture_output=True,text=True,timeout=10)
print(p.returncode, round(time.time()-t,2))' "$(printf '{"hook_event_name":"SessionStart","session_id":"sB","source":"startup","transcript_path":"%s/transcripts/sB.jsonl"}' "$BATS_TEST_TMPDIR")"
  [ "$status" -eq 0 ]; case "$output" in "0 "*) : ;; *) echo "exit/elapsed: $output"; return 1 ;; esac
  python3 -c 'import sys; assert float(sys.argv[1].split()[1]) < 5.0, sys.argv[1]' "$output"
  [ "$(lease_json 02 session_id)" = "sB" ]
}

@test "self-rebind: this session's id already in a lease with a dead pid and a live registry entry -> rebound, not renumbered" {
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sR"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  pid="$(live_pid)"; registry_entry "$pid" sR interactive cli daedalus-01
  run start sR resume
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ]
  [ "$(lease_json 01 pid)" = "$pid" ]; [ ! -f "$DAEDALUS_HOME/state/leases/02.json" ]
}

@test "two concurrent first-ups leave one prime.json with one session_id; two concurrent auto-numberings leave two numbers" {
  p1="$(live_pid)"; registry_entry "$p1" sA; p2="$(live_pid)"; registry_entry "$p2" sB
  ( start sA startup >/dev/null ) & ( start sB startup >/dev/null ) & wait
  [ "$(ls "$DAEDALUS_HOME/state/leases"/0*.json | wc -l | tr -d ' ')" -eq 2 ]
  case "$(lease_json prime session_id)" in sA|sB) : ;; *) echo "prime: $(cat "$DAEDALUS_HOME/state/leases/prime.json")"; return 1 ;; esac
}

@test "a session bound to nothing while leases exist gets target_base_error with the §4.4 sentence and the 'cannot be bound' line" {
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  pu="$(live_pid)"; registry_entry "$pu" sU interactive sdk-cli
  run start sU startup
  case "$output" in *"This session cannot be bound to a lease: This session holds no window"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert "holds no window" in m["target_base_error"] and m["target_base"]=="", m' "$DAEDALUS_HOME/state/session-sU.json"
}

@test "a worktree add that hangs past the budget leaves worktree_ready false and the session is told to claim" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-slow" "$BATS_TEST_TMPDIR/bin/git"; chmod +x "$BATS_TEST_TMPDIR/bin/git"
  pid="$(live_pid)"; registry_entry "$pid" sW
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_GIT_SLEEP=3 LEASE_WORKTREE_TIMEOUT=1 run start sW startup
  [ "$(lease_json 01 worktree_ready)" = "False" ]
  case "$output" in *"window 01's worktree was not finished at start; run \`core/lease.sh claim 01\` to finish it"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a SessionStart whose lease resolution overlaps a neighbour's worktree add still records target_base: the seam waits inside the hook's budget instead of timing out at 5 s (Task 6 review)" {
  # Two registered windows 0.5 s apart under a slow git: A allocates (~2 s),
  # releases the lock, then resolves its target while B holds LOCK_EX for
  # ~6 s adding two worktrees. With a 5 s seam A's marker used to come out
  # with neither target_base nor target_base_error — the silent fail-open
  # §4.4 exists to remove — and every Stop then blocked with the wrong sentence.
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-slow" "$BATS_TEST_TMPDIR/bin/git"; chmod +x "$BATS_TEST_TMPDIR/bin/git"
  p1="$(live_pid)"; registry_entry "$p1" sA; p2="$(live_pid)"; registry_entry "$p2" sB
  ( PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_GIT_SLEEP=1 start sA startup > "$BATS_TEST_TMPDIR/outA" ) &
  sleep 0.5
  ( PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_GIT_SLEEP=3 start sB startup > "$BATS_TEST_TMPDIR/outB" ) &
  wait
  base="$(git -C "$T" rev-parse origin/main)"
  for s in sA sB; do
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["target_base"]==sys.argv[2] and m["target_base_error"]=="", (sys.argv[1], m)' "$DAEDALUS_HOME/state/session-$s.json" "$base"
  done
  case "$(cat "$BATS_TEST_TMPDIR/outA")" in *"cannot be bound"*|*"Promotion gate"*) echo "A: $(cat "$BATS_TEST_TMPDIR/outA")"; return 1 ;; *) : ;; esac
}

@test "a lease resolution that does not answer in time is Refused (fail-closed), never Unconfigured: the sentence says it did not answer" {
  # The seam's timeout is v.run's 127; before the Task 6 review it fell into
  # the Unconfigured branch, which plan 3 turns into 'notes, never denials'.
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT); fcntl.flock(fd,fcntl.LOCK_EX); time.sleep(6)' "$DAEDALUS_HOME/state/leases/.lock" 3>&- </dev/null >/dev/null 2>&1 &
  holder=$!; echo "$holder" >> "$BATS_TEST_TMPDIR/live-pids"
  sleep 0.3
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import verifylib as v
from pathlib import Path
r = v.resolve_target(Path(sys.argv[2]), "sX", timeout=1)
print(type(r).__name__); print(getattr(r, "sentence", getattr(r, "reason", "")))' "$DAEDALUS_HOME/core" "$DAEDALUS_HOME"
  [ "$status" -eq 0 ]
  case "$output" in "Refused"*"did not answer within 1 s"*) : ;; *) echo "$output"; return 1 ;; esac
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
}

@test "an unconfigured target is recorded in the marker as its reason and said at start — the marker is never a silent empty pair" {
  sed -i.bak '/^  repo: /d' "$DAEDALUS_HOME/config.yaml"; rm -f "$DAEDALUS_HOME/config.yaml.bak"
  run start sN startup; [ "$status" -eq 0 ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["target_base"]=="" and "target.repo is required" in m["target_base_error"], m' "$DAEDALUS_HOME/state/session-sN.json"
  case "$output" in *"The target did not resolve"*"target.repo is required"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Promotion gate"*) echo "an unconfigured target is not a promotion-gate refusal: $output"; return 1 ;; *) : ;; esac
}

@test "DAEDALUS_LEASE=prime is not a window number: prime.json is untouched and the line says it was ignored; a traversal value writes nothing outside state/leases/ (Task 6 review)" {
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  [ "$(lease_json prime session_id)" = "sA" ]
  before="$(cat "$DAEDALUS_HOME/state/leases/prime.json")"
  run env DAEDALUS_LEASE=prime bash -c "$(declare -f start); start sZ startup"
  [ "$status" -eq 0 ]
  [ "$(cat "$DAEDALUS_HOME/state/leases/prime.json")" = "$before" ]
  # the hook's output is JSON, where the en dash in "01–99" is escaped: match around it
  case "$output" in *"\`DAEDALUS_LEASE=prime\` is not a window number (two digits, 01"*"99); it was ignored."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"lease file for window prime"*) echo "the bad hint must be refused by name, not reported as a missing file: $output"; return 1 ;; *) : ;; esac
  # state/leases/../x.json is state/x.json — a valid lease body there used to be bound and rewritten.
  printf '{"lease":"x","session_id":null}' > "$DAEDALUS_HOME/state/x.json"
  run env DAEDALUS_LEASE=../x bash -c "$(declare -f start); start sY startup"
  [ "$(cat "$DAEDALUS_HOME/state/x.json")" = '{"lease":"x","session_id":null}' ]
  case "$output" in *"\`DAEDALUS_LEASE=../x\` is not a window number"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["lease"] is None and "not a window number" in m["target_base_error"], m' "$DAEDALUS_HOME/state/session-sY.json"
}

@test "a resumed session that already holds a window ignores a different DAEDALUS_LEASE: one lease, orientation and marker agree (Task 6 review)" {
  for i in 1 2 3; do bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null; done
  run env DAEDALUS_LEASE=02 bash -c "$(declare -f start); start sR startup"
  [ "$(lease_json 02 session_id)" = "sR" ]
  rm "$DAEDALUS_HOME/state/session-sR.json"       # a fresh marker, as after a restart with the variable still exported
  run env DAEDALUS_LEASE=03 bash -c "$(declare -f start); start sR resume"
  [ "$status" -eq 0 ]
  [ "$(lease_json 02 session_id)" = "sR" ]; [ "$(lease_json 03 session_id)" = "None" ]
  [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ]
  case "$output" in *"\`DAEDALUS_LEASE=03\` ignored: this session is already window 02 (the lease files are the truth)."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["lease"])' "$DAEDALUS_HOME/state/session-sR.json")" = "02" ]
}

@test "the tracked settings.json gives session-start.py 30 s" {
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); h=[x for g in d["hooks"]["SessionStart"] for x in g["hooks"] if "session-start.py" in x["command"]][0]
assert h["timeout"]==30, h' "$SRC/../.claude/settings.json"
}

@test "first-up never rebinds a prime whose holder is live in the registry but holds only the pen (released its number): the new window numbers itself without the pen; once that holder's process is gone, the next window first-ups with 'previous holder gone'" {
  pa="$(live_pid)"; registry_entry "$pa" sA interactive cli daedalus-01
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","bound_at":"2026-01-01T00:00:00","history":[]}'
  pb="$(live_pid)"; registry_entry "$pb" sB interactive cli daedalus-02
  run start sB startup; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 01, $DAEDALUS_HOME" ]
  [ "$(lease_json 01 session_id)" = "sB" ]; [ "$(lease_json prime session_id)" = "sA" ]
  kill "$pa"; wait "$pa" 2>/dev/null || true
  pc="$(live_pid)"; registry_entry "$pc" sC interactive cli daedalus-03
  run start sC startup; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 02, prime, $DAEDALUS_HOME" ]
  [ "$(lease_json prime session_id)" = "sC" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==1 and h[0]["from"]=="sA" and h[0]["to"]=="sC" and "previous holder gone" in h[0]["reason"], h' "$DAEDALUS_HOME/state/leases/prime.json"
}

@test "the SessionStart context carries the board, rendered after binding: a second window sees 'you are window 02' and window 01 on its first read" {
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; start sA startup >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02
  run start sB startup
  c="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$c" in *"Lease board (2 windows; you are window 02):"*"- 02 (you)"*"- 01 — prime"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "the worktree adds share SessionStart's budget: with the budget cut to 16 s and every add taking 3 s, the outer add completes, the nested add is cut off at the deadline, the window is worktree_ready false, the hook returns well inside the budget, and claim finishes it" {
  # ADD_BUDGET = 16 - 5 (marker tail) - 5 (minimum resolve) = 6 s from the hook's start.
  # Plan 1 gave every add a fixed 20 s: the nested add finished at ~6.5 s and
  # the window came out ready — on a real 30 s budget two slow repos took 40 s.
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-slow" "$BATS_TEST_TMPDIR/bin/git"; chmod +x "$BATS_TEST_TMPDIR/bin/git"
  pid="$(live_pid)"; registry_entry "$pid" sW
  t0="$(date +%s)"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_GIT_SLEEP=3 LEASE_TEST_HOOK_BUDGET=16 run start sW startup
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$(lease_json 01 worktree_ready)" = "False" ]
  [ -f "$DAEDALUS_HOME/worktrees/01/thing/a.txt" ]              # the outer add finished
  [ ! -e "$DAEDALUS_HOME/worktrees/01/thing/sub/n.txt" ]        # the nested one was cut off at the deadline
  [ $((t1 - t0)) -lt 16 ] || { echo "the hook took $((t1 - t0)) s"; return 1; }
  CLAUDE_CODE_SESSION_ID=sW run bash "$DAEDALUS_HOME/core/lease.sh" claim 01
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/worktrees/01/thing/sub/n.txt" ]
  [ "$(lease_json 01 worktree_ready)" = "None" ]
}

@test "a DAEDALUS_LEASE bind that finishes an unfinished window spends only SessionStart's budget: out of time, the window stays worktree_ready false and claim finishes it" {
  # The hint path is how a registry-absent build binds (spec §4.8, corrected
  # 2026-09-27), and how a window left unfinished by an earlier cut-off start
  # comes back. Plan 1's bind() ran its adds with a fixed 20 s each and no
  # deadline: reproduced in review, two 9 s adds ran to completion inside the hook.
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  T="$DAEDALUS_HOME/target/thing"
  git -C "$T/sub" worktree remove --force "$DAEDALUS_HOME/worktrees/01/thing/sub"
  git -C "$T" worktree remove --force "$DAEDALUS_HOME/worktrees/01/thing"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["worktree_ready"]=False; open(p,"w").write(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json"
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-slow" "$BATS_TEST_TMPDIR/bin/git"; chmod +x "$BATS_TEST_TMPDIR/bin/git"
  t0="$(date +%s)"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" DAEDALUS_LEASE=01 FAKE_GIT_SLEEP=3 LEASE_TEST_HOOK_BUDGET=16 run start sH startup
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ "$(lease_json 01 worktree_ready)" = "False" ] || { echo "ready although the nested add had no time: $(cat "$DAEDALUS_HOME/state/leases/01.json")"; return 1; }
  [ ! -e "$DAEDALUS_HOME/worktrees/01/thing/sub/n.txt" ]
  [ $((t1 - t0)) -lt 16 ] || { echo "the hook took $((t1 - t0)) s"; return 1; }
  CLAUDE_CODE_SESSION_ID=sH run bash "$DAEDALUS_HOME/core/lease.sh" claim 01
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$DAEDALUS_HOME/worktrees/01/thing/sub/n.txt" ]
  [ "$(lease_json 01 worktree_ready)" = "None" ]
}

@test "the tracked settings.json budget and the hook's add budget agree: SessionStart's timeout in .claude/settings.json is session-start.py's HOOK_BUDGET_SECS (30), 20 of them for worktree adds" {
  # Reads the tracked file itself ($SRC/../.claude/settings.json, as the
  # "gives session-start.py 30 s" test does): a settings.json that dropped the
  # timeout to 10 must fail here, not only there.
  run python3 -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import importlib; m = importlib.import_module("session-start")
t = [h.get("timeout") for g in json.load(open(sys.argv[2]))["hooks"]["SessionStart"] for h in g["hooks"] if "session-start.py" in h["command"]]
assert t == [m.HOOK_BUDGET_SECS] and m.HOOK_BUDGET_SECS == 30 and m.ADD_BUDGET_SECS == 20, (t, m.HOOK_BUDGET_SECS, m.ADD_BUDGET_SECS)' "$DAEDALUS_HOME/core" "$SRC/../.claude/settings.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the lease lock held past the start budget: SessionStart does not wait for it — the bind writes nothing and says so, naming claim; the board says it renders at the next prompt; the marker is written; the hook returns inside the budget" {
  # Plan 1 waited for the lease lock with no bound: a lease.sh command in
  # another shell holding it through its adds held this start past its 30 s,
  # and Claude Code stopped the hook. Decision 18: both acquires are bounded.
  pid="$(live_pid)"; registry_entry "$pid" sL
  mkdir -p "$DAEDALUS_HOME/state/leases"
  # started in a command substitution, as live_pid does, so the kill at teardown
  # is not reported as a job of the test's own shell
  holder="$(python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(20)' "$DAEDALUS_HOME/state/leases/.lock" "$BATS_TEST_TMPDIR/held" 3>&- </dev/null >/dev/null 2>&1 & echo "$!")"
  printf '%s\n' "$holder" >> "$BATS_TEST_TMPDIR/live-pids"      # teardown_live kills the holder
  i=0; while [ ! -e "$BATS_TEST_TMPDIR/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  t0="$(date +%s)"
  LEASE_TEST_HOOK_BUDGET=16 run start sL startup
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ $((t1 - t0)) -lt 16 ] || { echo "the hook took $((t1 - t0)) s"; return 1; }
  # the orientation line's own read of the leases is bounded as well (found at
  # Task 3: unbounded, it alone held the hook until the holder let go, 19 s)
  case "$(first_line)" in "Daedalus session orientation: unleased, "*) : ;; *) first_line; return 1 ;; esac
  ctx="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$ctx" in *"This window was not bound at start: the lease lock stayed busy past the start budget"*"core/lease.sh claim"*) : ;; *) echo "$ctx"; return 1 ;; esac
  case "$ctx" in *"The lease board could not be rendered: the lease lock stayed busy past the start budget; the board renders at your next prompt"*) : ;; *) echo "$ctx"; return 1 ;; esac
  [ -z "$(ls "$DAEDALUS_HOME/state/leases")" ] || { ls -la "$DAEDALUS_HOME/state/leases"; return 1; }   # nothing written (ls hides .lock)
  [ -f "$DAEDALUS_HOME/state/session-sL.json" ]
}

@test "a SessionStart stopped with SIGTERM mid-add takes the add's checkout with it: no git child keeps writing after the hook is gone" {
  # _run_bounded puts each git call in its own session so a timeout can kill
  # the whole group; that also puts the checkout outside the hook's group, so
  # a signal to the hook no longer reached it (review, 2026-09-27). Decision 20.
  pid="$(live_pid)"; registry_entry "$pid" sT
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/w"
  real="$(command -v git)"
  { printf '#!/usr/bin/env bash\nreal=%q\n' "$real"
    cat <<'EOF'
case " $* " in *" worktree add "*)
  ( while :; do : > "$FAKE_W/f.$RANDOM"; sleep 0.1; done ) &
  printf '%s\n' "$!" > "$FAKE_W/child.pid"
  sleep 30
  exit 0 ;;
esac
exec "$real" "$@"
EOF
  } > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  printf '{"hook_event_name":"SessionStart","session_id":"sT","source":"startup","transcript_path":"%s/transcripts/sT.jsonl"}' "$BATS_TEST_TMPDIR" \
    | PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_W="$BATS_TEST_TMPDIR/w" python3 "$DAEDALUS_HOME/core/session-start.py" 3>&- >/dev/null 2>&1 &
  hook=$!
  i=0; while [ ! -s "$BATS_TEST_TMPDIR/w/child.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$BATS_TEST_TMPDIR/w/child.pid" ] || { kill "$hook" 2>/dev/null; echo "the add never started"; return 1; }
  child="$(cat "$BATS_TEST_TMPDIR/w/child.pid")"
  kill -TERM "$hook"; wait "$hook" 2>/dev/null || true
  sleep 0.5
  if kill -0 "$child" 2>/dev/null; then kill "$child"; echo "the checkout child $child outlived the hook"; return 1; fi
}

@test "the one-time 'memory: block absent' note: said when settings.local.json wires capture.py and config.yaml has no memory:, not again on a repeat start of the session, never with a memory: block or without the old wiring" {
  printf '{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"TENANT_BANK=b python3 core/capture.py capture"}]}]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  note="memory: block absent from config.yaml — Stop-cadence capture is off; a SessionEnd capture wired in .claude/settings.local.json still runs"
  run start sM startup; [ "$status" -eq 0 ]
  # The hook's JSON escapes the em dash (\u2014): compare the decoded context, not the raw output.
  ctx="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$ctx" in *"$note"*) : ;; *) echo "$ctx"; return 1 ;; esac
  run start sM startup
  case "$output" in *"memory: block absent"*) echo "repeated: $output"; return 1 ;; *) : ;; esac
  printf 'memory:\n  bank: b\n' >> "$DAEDALUS_HOME/config.yaml"
  run start sN startup
  case "$output" in *"memory: block absent"*) echo "said with a block: $output"; return 1 ;; *) : ;; esac
  rm "$DAEDALUS_HOME/.claude/settings.local.json"
  sed -i '' '/^memory:/,$d' "$DAEDALUS_HOME/config.yaml"
  run start sO startup
  case "$output" in *"memory: block absent"*) echo "said without the old wiring: $output"; return 1 ;; *) : ;; esac
}

@test "the 'memory: block absent' note is not said when settings.local.json mentions capture.py only in a permission rule — a hook is judged as JSON, as doctor judges it" {
  # A text search for "capture.py" counted an allow rule as a wired SessionEnd
  # capture and told the agent one still runs (review, 2026-09-27).
  printf '{"permissions":{"allow":["Bash(python3 core/capture.py status)"]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run start sP startup; [ "$status" -eq 0 ]
  case "$output" in *"memory: block absent"*) echo "said for a permission rule: $output"; return 1 ;; *) : ;; esac
}

# --- the upgrade at step 0 (spec §14; plan 5 Task 4) -------------------------------

@test "step 0: a home that pulled 0.7.0 with an in-flight branch stops the upgrade at the first interactive start, changing nothing in target/ — this window gets no number and is told the stop and that no window opens until the upgrade finishes; 'pick it up' makes the branch window 01; the next start completes the upgrade, numbers itself 02 and takes the pen, the marker records the trunk base; the context says each step once" {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1 startup
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch feat/x (1 commit not on origin). Nothing was changed. Say 'pick it up' to move it into windows, then start a new session."*"No window opens until the upgrade finishes."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"You are window"*|*"hold the pen"*|*"a session started after that is numbered"*) echo "$c"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ "$(git -C "$T" branch --show-current)" = feat/x ]
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -e "$DAEDALUS_HOME/state/leases/prime.json" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/lease/01 >/dev/null; [ ! -e "$T/.git/hooks/pre-push" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds feat/x from target/thing (1 commit: \"in flight\")"*) : ;; *) echo "$output"; return 1 ;; esac
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run start s2 startup
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')"
  case "$c" in *"Upgrade to 0.7.0: complete."*"You are window 02 and you hold the pen"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  [ "$(lease_json 01 adopted_from)" = feat/x ]; [ "$(lease_json 02 session_id)" = s2 ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["target_base"] and not m["target_base_error"], m' "$DAEDALUS_HOME/state/session-s2.json"
  P3="$(live_pid)"; registry_entry "$P3" s3 interactive cli daedalus-xx
  run start s3 startup
  case "$output" in *"Upgrade to"*) echo "a later start said an upgrade line: $output"; return 1 ;; esac
}

@test "step 0: a home whose stamp equals VERSION never loads the upgrade (a stub that records its import stays silent); a home with no VERSION neither" {
  printf 'import pathlib\npathlib.Path(%s).write_text("imported")\ndef run(*a, **k): return [], None\n' \
    "'$BATS_TEST_TMPDIR/imported'" > "$DAEDALUS_HOME/core/upgrade.py"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"; mkdir -p "$DAEDALUS_HOME/state"; printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1 startup
  [ "$status" -eq 0 ]; [ ! -e "$BATS_TEST_TMPDIR/imported" ]
  rm "$DAEDALUS_HOME/VERSION" "$DAEDALUS_HOME/state/upgraded-to"
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run start s2 startup
  [ "$status" -eq 0 ]; [ ! -e "$BATS_TEST_TMPDIR/imported" ]
}

@test "step 0: a visitor never runs the upgrade — no stamp, no window directories, no lease — and a stop is said at an interactive start and not stamped" {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  run env DIRECT_CALL_ID=c1 bash -c "$(declare -f start); start v1 startup"
  [ "$status" -eq 0 ]; [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  [ ! -d "$DAEDALUS_HOME/worktrees" ]; [ ! -d "$DAEDALUS_HOME/state/promote" ]
  [ ! -d "$DAEDALUS_HOME/state/leases" ]      # a reader's shared lock no longer makes the directory (Decision 13)
  printf 'dirt\n' >> "$T/a.txt"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1 startup
  case "$output" in *"Daedalus has unfinished work in target/thing: 1 unsaved file."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
}

@test "step 0: while another start's upgrade holds the lock past this start's share, this window does not number itself — no state/leases/, no lease — and says the upgrade has not run; the start stays inside its budget" {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"; mkdir -p "$DAEDALUS_HOME/state"
  python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(12)' "$DAEDALUS_HOME/state/.upgrade.lock" 3>&- &
  holder=$!; sleep 0.3
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  t0=$(date +%s)
  run env LEASE_TEST_HOOK_BUDGET=15 bash -c "$(declare -f start); start s1 startup"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(( $(date +%s) - t0 ))" -le 8 ]
  case "$output" in *"upgrade to 0.7.0 has not run yet"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"You are window"*) echo "numbered before the upgrade: $output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/leases" ]
}

@test "step 0: a fetch that hangs costs the upgrade its judgement, never this window its worktree — the upgrade keeps to its share and the bind keeps the rest" {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m "shipped"
  git -C "$T" push -q origin feat/x:main            # its work is on origin as last fetched: nothing unfinished
  real="$(command -v git)"; mkdir -p "$BATS_TEST_TMPDIR/slowgit"
  printf '#!/bin/bash\ncase " $* " in *" fetch "*) sleep 60 ;; esac\nexec "%s" "$@"\n' "$real" > "$BATS_TEST_TMPDIR/slowgit/git"
  chmod +x "$BATS_TEST_TMPDIR/slowgit/git"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  t0=$(date +%s)
  run env LEASE_TEST_HOOK_BUDGET=20 PATH="$BATS_TEST_TMPDIR/slowgit:$PATH" bash -c "$(declare -f start); start s1 startup"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(( $(date +%s) - t0 ))" -le 12 ]
  case "$output" in *"target/thing was on feat/x, whose work is already on origin/main; it is back on main and feat/x is left as it was. (judged against origin/main as last fetched"*"the fetch did not finish)"*"You are window 01 and you hold the pen"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = s1 ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("worktree_ready", True) is not False, d' "$DAEDALUS_HOME/state/leases/01.json"
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]
}

@test "step 0: the upgrade is given its own share of the start, never the whole worktree budget — 12 s of 20 at the default, so the bind always keeps at least 8 s; the share shrinks with the budget" {
  # A stand-in upgrade records how far away the deadline it was given is. With the share set back to the
  # whole worktree budget (review, 2026-09-29) every other step-0 test still passed: their fetch cap and
  # lock hold end long before either deadline. This one reads the deadline itself.
  printf 'import pathlib, time\ndef run(root, dry=False, deadline=None, upto=6):\n    pathlib.Path(%s).write_text("%%.3f" %% (deadline - time.time()))\n    return [], None\ndef pending_line(root): return None\n' \
    "'$BATS_TEST_TMPDIR/share'" > "$DAEDALUS_HOME/core/upgrade.py"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1 startup                                    # the default: 30 s hook, 20 s worktree budget
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 -c 'import sys; x=float(open(sys.argv[1]).read()); assert 10.5 < x <= 12.0, "the upgrade was given %.3f s, not its 12 s share of 20 (the bind must keep at least 8 s)" % x' "$BATS_TEST_TMPDIR/share"
  rm "$BATS_TEST_TMPDIR/share"
  P2="$(live_pid)"; registry_entry "$P2" s2 interactive cli daedalus-xx
  run env LEASE_TEST_HOOK_BUDGET=20 bash -c "$(declare -f start); start s2 startup"   # 10 s worktree budget
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 -c 'import sys; x=float(open(sys.argv[1]).read()); assert 4.5 < x <= 6.0, "the upgrade was given %.3f s, not its 6 s share of 10" % x' "$BATS_TEST_TMPDIR/share"
}

@test "the morning terminal: yesterday's window 01 (its process ended with the OS restart, worktree clean, nothing unpromoted, holding the pen) is reclaimed by the first terminal up — it is window 01 again and holds the pen, with nothing typed; a resume of the old session id afterwards gets a fresh number" {
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01
  run start sA startup; [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ]
  kill "$p1"; wait "$p1" 2>/dev/null || true            # the OS restart; the registry file is left behind, as a crash leaves it
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-01
  run start sB startup; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sB" ]; [ "$(lease_json 01 pid)" = "$p2" ]
  [ "$(lease_json prime session_id)" = "sB" ]; [ ! -f "$DAEDALUS_HOME/state/leases/02.json" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==1 and h[0]["from"]=="sA" and h[0]["to"]=="sB" and "previous holder gone" in h[0]["reason"], h' "$DAEDALUS_HOME/state/leases/prime.json"
  case "$output" in *"You are window 01 and you hold the pen"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 01"*"reclaimed"*|*"Reclaimed window 01"*) : ;; *) echo "no reclaim sentence: $output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" rev-parse --abbrev-ref HEAD)" = "lease/01" ]
  # The old session comes back by id later (claude --resume): its number is taken, so it is numbered afresh, not refused.
  p3="$(live_pid)"; registry_entry "$p3" sA interactive cli daedalus-01
  run start sA resume; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sB" ]; [ "$(lease_json prime session_id)" = "sB" ]
}

@test "reclaim never touches a window with anything to lose: unpromoted commits and uncommitted changes each keep their number on a dead window, and the new terminal is numbered after it; a dead clean window beside them is reclaimed" {
  T1="$DAEDALUS_HOME/worktrees/01/thing"
  # 1. unpromoted commits on a dead window: kept (the board's STALE line says how to continue it).
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  printf 'w\n' >> "$T1/a.txt"; git -C "$T1" -c user.email=t@x -c user.name=t commit -q -am waiting
  kill "$p1"; wait "$p1" 2>/dev/null || true
  p2="$(live_pid)"; registry_entry "$p2" sB
  run start sB startup; [ "$(first_line)" = "Daedalus session orientation: window 02, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sA" ]
  case "$output" in *"01"*"STALE"*) : ;; *) echo "no STALE line for 01: $output"; return 1 ;; esac
  # 2. uncommitted changes on a dead window: kept. Window 02 (dead, clean) beside it is reclaimed: the new terminal is 02, not 03.
  git -C "$T1" reset -q --hard origin/main; printf 'u\n' > "$T1/u.txt"
  kill "$p2"; wait "$p2" 2>/dev/null || true
  p3="$(live_pid)"; registry_entry "$p3" sC
  run start sC startup; [ "$(first_line)" = "Daedalus session orientation: window 02, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sA" ]; [ "$(lease_json 02 session_id)" = "sC" ]; [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]
  case "$output" in *"01"*"STALE"*) : ;; *) echo "no STALE line for 01: $output"; return 1 ;; esac
}

@test "reclaim keeps a quiet window (process alive, heartbeat old), a finished clone, a dead spawned clone that never reported done, a lease with no recorded pid, and a released window whose session is still open (its hooks may still read it)" {
  T1="$DAEDALUS_HOME/worktrees/01/thing"
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  # quiet: the process is alive, the heartbeat is a day old
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/01.seen"
  p2="$(live_pid)"; registry_entry "$p2" sB
  run start sB startup; [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sA" ]
  # finished: a dead spawned clone that reported done is kept until promote or release
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["pid"]=1; d["proc_started"]=1; d["finished"]="2026-01-01T00:00:00"; d["summary"]="done"; d["spawned"]=True; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  # no recorded pid: liveness is by heartbeat alone; a day-old heartbeat is not proof the process is gone
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null       # 03, unbound (pid null)
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/03.seen"
  # a spawned clone that died (dead pid) without `done`: kept, so the board's STALE line can say to read its log (spec §4.2)
  bash "$DAEDALUS_HOME/core/lease.sh" create --spawned --note "index the docs" >/dev/null    # 04
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 04 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sX"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/04.json")"
  [ "$(lease_json 04 spawned)" = "True" ]
  p4="$(live_pid)"; registry_entry "$p4" sD
  run start sD startup; [ "$(first_line)" = "Daedalus session orientation: window 05, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sA" ]; [ "$(lease_json 02 finished)" = "2026-01-01T00:00:00" ]; [ "$(lease_json 03 session_id)" = "None" ]
  [ "$(lease_json 04 spawned)" = "True" ]; [ "$(lease_json 04 session_id)" = "sX" ]
  case "$output" in *"04"*"STALE"*) : ;; *) echo "no STALE line for the dead clone: $output"; return 1 ;; esac
  bash "$DAEDALUS_HOME/core/lease.sh" release 04 --remove --force >/dev/null
  # released, its session still open: kept — its holder's hooks may still be reading it (swept once the session ends)
  DAEDALUS_SESSION_ID=sD bash "$DAEDALUS_HOME/core/lease.sh" release 05 >/dev/null
  p5="$(live_pid)"; registry_entry "$p5" sE
  run start sE startup; [ "$(first_line)" = "Daedalus session orientation: window 04, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 05 session_id)" = "sD" ]; [ "$(lease_json 05 released)" != "None" ]
}

# --- released windows are swept without the operator (the operator, 2026-10-19: "I don't want to have to keep those extra
# steps"): a released lease whose session has ended goes at the next terminal start, as reclaim removes an idle one.

@test "a released window whose session has ended is swept by the next terminal start, with no sweep typed: its number comes back when nothing is unpromoted; while its session is open it is kept" {
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  DAEDALUS_SESSION_ID=sA bash "$DAEDALUS_HOME/core/lease.sh" release 01 >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB
  run start sB startup; [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sA" ]; [ "$(lease_json 01 released)" != "None" ]     # its session is open: kept
  kill "$p1"; wait "$p1" 2>/dev/null || true
  p3="$(live_pid)"; registry_entry "$p3" sC
  run start sC startup; [ "$status" -eq 0 ]
  # the pen's holder (sA) has ended, so the new terminal takes it too
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 session_id)" = "sC" ]; [ "$(lease_json 01 released)" = "None" ]
  case "$output" in *"Swept window 01: it was released and its session has ended"*) : ;; *) echo "no sweep sentence: $output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" rev-parse --abbrev-ref HEAD)" = "lease/01" ]
}

@test "a released window with unpromoted commits is swept once its session ends, but its number stays with the work: the new terminal is numbered after it and its start says why the lower number was skipped" {
  T1="$DAEDALUS_HOME/worktrees/01/thing"
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  printf 'w\n' >> "$T1/a.txt"; git -C "$T1" -c user.email=t@x -c user.name=t commit -q -am "kept work"
  DAEDALUS_SESSION_ID=sA bash "$DAEDALUS_HOME/core/lease.sh" release 01 >/dev/null
  kill "$p1"; wait "$p1" 2>/dev/null || true
  p2="$(live_pid)"; registry_entry "$p2" sB
  run start sB startup; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 02, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T1" log -1 --format=%s lease/01)" = "kept work" ]
  case "$output" in *"Swept window 01"*) : ;; *) echo "no sweep sentence: $output"; return 1 ;; esac
  case "$output" in *"Numbered 02, not a lower number: 01 has unpromoted commits on lease/01"*) : ;; *) echo "no skip sentence: $output"; return 1 ;; esac
}

@test "a released lease that recorded no pid is not swept at start on heartbeat age — an old heartbeat is not proof its terminal closed (review 2026-10-19, finding 3)" {
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null                 # 01, never bound: pid null
  bash "$DAEDALUS_HOME/core/lease.sh" release 01 >/dev/null
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/01.seen"
  p1="$(live_pid)"; registry_entry "$p1" sA
  run start sA startup; [ "$(first_line)" = "Daedalus session orientation: window 02, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 released)" != "None" ]
}

@test "the skip sentence names a released window still open, and is silent when the only lower numbers are open windows" {
  p1="$(live_pid)"; registry_entry "$p1" sA; start sA startup >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB
  run start sB startup; [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  case "$output" in *"not a lower number"*) echo "a live 01 needs no explaining: $output"; return 1 ;; esac
  DAEDALUS_SESSION_ID=sB bash "$DAEDALUS_HOME/core/lease.sh" release 02 >/dev/null
  p3="$(live_pid)"; registry_entry "$p3" sC
  run start sC startup; [ "$(first_line)" = "Daedalus session orientation: window 03, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  case "$output" in *"Numbered 03, not a lower number: 02 is released and its session is still open"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"lower number: 01"*|*"; 01 "*) echo "the open 01 is named: $output"; return 1 ;; esac
}

@test "a resumed window reclaims too: the operator resumes yesterday's window 02 by session id while window 01's process is gone and clean — 02 stays 02, 01's lease is gone, and the pen moves to 02 (previous holder gone); a headless start never reclaims" {
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; start sA startup >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02; start sB startup >/dev/null
  [ "$(lease_json prime session_id)" = "sA" ]
  kill "$p1"; wait "$p1" 2>/dev/null || true; kill "$p2"; wait "$p2" 2>/dev/null || true
  # a headless start (sdk-cli) is not a terminal window: it binds nothing and reclaims nothing
  p3="$(live_pid)"; registry_entry "$p3" sH interactive sdk-cli
  run start sH startup; [ -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
  # the operator resumes window 02 (same session id, new pid)
  p4="$(live_pid)"; registry_entry "$p4" sB interactive cli daedalus-02
  run start sB resume; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 02, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ "$(lease_json 02 session_id)" = "sB" ]; [ "$(lease_json 02 pid)" = "$p4" ]
  [ "$(lease_json prime session_id)" = "sB" ]
  case "$output" in *"Reclaimed window 01"*) : ;; *) echo "no reclaim sentence: $output"; return 1 ;; esac
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==1 and h[0]["from"]=="sA" and h[0]["to"]=="sB" and "previous holder gone" in h[0]["reason"], h' "$DAEDALUS_HOME/state/leases/prime.json"
  # 01's worktree and branch are kept; the next window to be numbered re-uses them
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  p5="$(live_pid)"; registry_entry "$p5" sC interactive cli daedalus-01
  run start sC startup; [ "$(first_line)" = "Daedalus session orientation: window 01, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
}

# --- 'this is window NN' from a new terminal (reported 2026-10-19): the start numbers every terminal, so the claim
# must give up that fresh, empty number — the old refusal sent the operator to yet another terminal, numbered again.
two_stale_windows() {   # 01 and 02 each hold an unpromoted commit and their sessions have ended; sC starts as 03
  local nn p
  for nn in 01 02; do
    p="$(live_pid)"; registry_entry "$p" "s$nn" interactive cli "daedalus-$nn"; start "s$nn" startup >/dev/null
    [ "$(lease_json "$nn" session_id)" = "s$nn" ] || { echo "setup: $nn not bound"; return 1; }
    printf 'w%s\n' "$nn" >> "$DAEDALUS_HOME/worktrees/$nn/thing/a.txt"
    git -C "$DAEDALUS_HOME/worktrees/$nn/thing" -c user.email=t@x -c user.name=t commit -q -am "work on $nn"
    kill "$p"; wait "$p" 2>/dev/null || true
  done
  PC="$(live_pid)"; registry_entry "$PC" sC interactive cli daedalus-03
  run start sC startup; [ "$(first_line)" = "Daedalus session orientation: window 03, prime, $DAEDALUS_HOME" ] || { echo "$output"; return 1; }
  START_LOG="$(lease_json 03 logs)"; [ "$START_LOG" != "None" ]
}

@test "'this is window 01' from a new terminal numbered 03 at start: claim 01 gives up the empty 03 (its lease files go, its number is free for the next allocation, its worktree kept as reclaim keeps it) and binds 01, whose unpromoted commit is intact; the session keeps the log number its start told it" {
  two_stale_windows
  T="$DAEDALUS_HOME/target/thing"
  CLAUDE_CODE_SESSION_ID=sC run bash "$DAEDALUS_HOME/core/lease.sh" claim 01 </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"This session was window 03, which had nothing to lose (clean, nothing unpromoted); its lease is given up."*"This is window 01."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/03.json" ]; [ ! -e "$DAEDALUS_HOME/state/leases/03.seen" ]; [ ! -e "$DAEDALUS_HOME/state/leases/03.changed" ]
  [ "$(lease_json 01 session_id)" = "sC" ]; [ "$(lease_json 01 pid)" = "$PC" ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" log -1 --format=%s)" = "work on 01" ]
  [ "$(git -C "$T" log -1 --format=%s lease/01)" = "work on 01" ]
  [ "$(lease_json 01 logs)" = "$START_LOG" ] || { echo "logs: $(lease_json 01 logs) vs $START_LOG"; return 1; }
  [ "$(lease_json 02 session_id)" = "s02" ]                       # the other stale window is untouched
  [ "$(DAEDALUS_SESSION_ID=sC python3 "$DAEDALUS_HOME/core/leaselib.py" my-lease)" = "01" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" create </dev/null       # 03 is free again: the next allocation re-uses it
  case "$output" in *"Window 03 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "claim from a window that has work refuses, naming the work and a path that works (a new terminal); nothing moves. A released empty window is given up the same way" {
  two_stale_windows
  W3="$DAEDALUS_HOME/worktrees/03/thing"
  printf 'w3\n' >> "$W3/a.txt"; git -C "$W3" -c user.email=t@x -c user.name=t commit -q -am "work on 03"
  CLAUDE_CODE_SESSION_ID=sC run bash "$DAEDALUS_HOME/core/lease.sh" claim 01 </dev/null
  [ "$status" -ne 0 ]
  case "$output" in *"This session is already window 03, which has 1 unpromoted commit: \"work on 03\", so it cannot also be window 01. To continue window 01, say 'this is window 01' in a new terminal (or start it with \`DAEDALUS_LEASE=01 claude\`); this one stays window 03."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"say 'release"*) echo "dead path named: $output"; return 1 ;; esac
  [ "$(lease_json 03 session_id)" = "sC" ]; [ "$(lease_json 01 session_id)" = "s01" ]; [ -d "$W3" ]
  # released with work: still refused, with the same working path
  CLAUDE_CODE_SESSION_ID=sC bash "$DAEDALUS_HOME/core/lease.sh" release 03 >/dev/null </dev/null
  CLAUDE_CODE_SESSION_ID=sC run bash "$DAEDALUS_HOME/core/lease.sh" claim 01 </dev/null
  [ "$status" -ne 0 ]
  case "$output" in *"This session was window 03 and released it, and it still has 1 unpromoted commit: \"work on 03\"; this window is done — close it. To continue window 01, say 'this is window 01' in a new terminal"*) : ;; *) echo "$output"; return 1 ;; esac
  # released and empty: given up, and 01 is bound
  git -C "$W3" reset -q --hard origin/main
  CLAUDE_CODE_SESSION_ID=sC run bash "$DAEDALUS_HOME/core/lease.sh" claim 01 </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"This session was window 03, which had nothing to lose"*"This is window 01."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/03.json" ]
  [ "$(lease_json 01 session_id)" = "sC" ]; [ "$(lease_json 01 released)" = "None" ]
}

# --- the document index follows the vault (reindex design 2026-10-15, §3.5) ---
# recall_engine <body...> — vault-search.py in the home and a recall: block naming a fake index
# engine that creates the store, then runs the body. Only these tests have the script: every other
# start in this file finds no core/vault-search.py and kicks nothing.
recall_engine() {
  cp "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
  { printf '#!/bin/bash\nmkdir -p "$DAEDALUS_RECALL_STORE"\n'; printf '%s\n' "$@"; } > "$BATS_TEST_TMPDIR/eng.sh"
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  printf "recall:\n  vault-query: 'echo []'\n  vault-index: '%s'\n  store: state/chroma\n" "$BATS_TEST_TMPDIR/eng.sh" >> "$DAEDALUS_HOME/config.yaml"
}
REINDEX_NOTE="The document index is older than the vault; rebuilding it in the background (state/recall-index.log)."
ctx() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
wait_log() {   # wait_log <text> — up to 8 s for the log's last line to carry <text>
  local i=0
  while [ "$i" -lt 80 ]; do
    if [ -f "$DAEDALUS_HOME/state/recall-index.log" ] && tail -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -qF -- "$1"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  echo "log never reached '$1':"; cat "$DAEDALUS_HOME/state/recall-index.log" 2>/dev/null; return 1
}

@test "the window that takes the pen at startup with a stale document index is told it is rebuilding, and the log and stamp appear; the hook returns while the engine still sleeps" {
  recall_engine 'sleep 2' 'echo "indexed=5 purged=0"'
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  t0="$(date +%s)"; run start sN startup; t1="$(date +%s)"; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ]
  case "$(ctx)" in *"$REINDEX_NOTE"*) : ;; *) ctx; return 1 ;; esac
  [ $((t1 - t0)) -lt 5 ] || { echo "the hook waited for the engine: $((t1 - t0)) s"; return 1; }
  wait_log "finished"
  head -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -q ' by session-start$'
  [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
}

@test "a second window (no pen) kicks nothing and is not told; a fresh index, a compaction and a visitor are silent too" {
  recall_engine 'echo "indexed=5 purged=0"'
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; run start sA startup
  case "$(ctx)" in *"$REINDEX_NOTE"*) : ;; *) ctx; return 1 ;; esac
  wait_log "finished"; rm -f "$DAEDALUS_HOME/state/recall-index.log"
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02; run start sB startup
  [ "$(first_line)" = "Daedalus session orientation: window 02, $DAEDALUS_HOME" ]
  case "$(ctx)" in *"document index"*) ctx; return 1 ;; *) : ;; esac
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  run start sA resume                                   # the prime again, the index fresh now: nothing to say
  case "$(ctx)" in *"document index"*) ctx; return 1 ;; *) : ;; esac
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  mkdir -p "$DAEDALUS_HOME/vault/specs"; sleep 1; printf '# new' > "$DAEDALUS_HOME/vault/specs/new.md"   # stale again
  run start sA compact                                  # a compaction is not a start
  case "$(ctx)" in *"document index"*) ctx; return 1 ;; *) : ;; esac
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  DIRECT_CALL_ID=call-1 run start sV startup            # a visitor binds nothing and kicks nothing
  case "$(ctx)" in *"document index"*) ctx; return 1 ;; *) : ;; esac
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  run start sA resume                                   # the prime's resume with a stale index: the note
  case "$(ctx)" in *"$REINDEX_NOTE"*) : ;; *) ctx; return 1 ;; esac
  wait_log "finished"
}

@test "an unconfigured recall block says nothing at start (recall is optional; doctor names it); a rebuild already running is reported in the script's own words" {
  cp "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  run start sN startup; [ "$status" -eq 0 ]
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ]
  case "$(ctx)" in *"document index"*) ctx; return 1 ;; *) : ;; esac
  printf "recall:\n  vault-query: 'echo []'\n  vault-index: 'true'\n  store: state/chroma\n" >> "$DAEDALUS_HOME/config.yaml"
  python3 -c "import fcntl,os,time; fd=os.open('$DAEDALUS_HOME/state/recall-index.lock',os.O_RDWR|os.O_CREAT); fcntl.flock(fd,fcntl.LOCK_EX); time.sleep(4)" 3>&- </dev/null >/dev/null 2>&1 &
  sleep 0.5
  run start sN resume
  case "$(ctx)" in *"document index: a rebuild is already running; it will run again when done (state/recall-index.log)"*) : ;; *) ctx; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/recall-index.rerun" ]
  wait
}

@test "a start whose budget is nearly spent after the bind kicks nothing and still emits its context; the lease lock held exclusively for the whole run: the hook returns inside its budget" {
  recall_engine 'echo "indexed=5 purged=0"'
  pid="$(live_pid)"; registry_entry "$pid" sN interactive cli daedalus-01
  LEASE_TEST_HOOK_BUDGET=9 run start sN startup; [ "$status" -eq 0 ]    # 9 - 5 (marker tail) leaves under 4 s: no kick
  [ "$(first_line)" = "Daedalus session orientation: window 01, prime, $DAEDALUS_HOME" ]
  [ "$(lease_json prime session_id)" = "sN" ]                             # the pen was taken: the budget is the only reason
  case "$(ctx)" in *"document index"*) ctx; return 1 ;; *) : ;; esac
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  holder="$(python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(20)' "$DAEDALUS_HOME/state/leases/.lock" "$BATS_TEST_TMPDIR/held" 3>&- </dev/null >/dev/null 2>&1 & echo "$!")"
  printf '%s\n' "$holder" >> "$BATS_TEST_TMPDIR/live-pids"
  i=0; while [ ! -e "$BATS_TEST_TMPDIR/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  t0="$(date +%s)"
  LEASE_TEST_HOOK_BUDGET=16 run start sN resume
  t1="$(date +%s)"; [ "$status" -eq 0 ]
  [ $((t1 - t0)) -lt 16 ] || { echo "the hook took $((t1 - t0)) s"; return 1; }
  case "$(first_line)" in "Daedalus session orientation: "*) : ;; *) first_line; return 1 ;; esac
}

ctx() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
# a home that pulled 0.7.0 whose upgrade stops on an in-flight branch at the first start: state/leases/ exists, no stamp
pending_stopped_home() {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m "in flight"
}

@test "a start while the upgrade is pending holds no window but is told its session log — reserved under the lease lock — and that it can take the pen at the close when none is live; no window file, no lease branch, no worktree is made" {
  pending_stopped_home
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1 startup; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx)"
  case "$c" in *"Your session log for today is vault/sessions/$(date +%Y/%m)/$(date +%Y-%m-%d)-001.md"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"At the close, when no live session holds the pen, \`core/lease.sh prime take\` gives this session the pen for hot.md and \`core/vault-commit.sh\` — no window is made."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"You are window"*) echo "$c"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/state/leases" ]
  [ -z "$(cd "$DAEDALUS_HOME/state/leases" && ls | grep -v '^unwindowed.json$')" ] || { ls "$DAEDALUS_HOME/state/leases"; return 1; }
  grep -q '"s1"' "$DAEDALUS_HOME/state/leases/unwindowed.json"
  ! git -C "$T" rev-parse -q --verify refs/heads/lease/01 >/dev/null
  [ -z "$(ls "$DAEDALUS_HOME/worktrees" 2>/dev/null)" ]
  [ "$(git -C "$T" worktree list | wc -l | tr -d ' ')" -eq 1 ]
  run start s1 compact; c="$(ctx)"
  case "$c" in *"-001.md"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "a headless session (entrypoint sdk-cli) that starts while the upgrade is pending reserves no session-log number and is not offered the pen, as outside a pending upgrade" {
  pending_stopped_home
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run start s1 startup; [ "$status" -eq 0 ] || { echo "$output"; return 1; }   # the interactive start the stop needs
  H="$(live_pid)"; registry_entry "$H" sH interactive sdk-cli
  run start sH startup; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx)"
  case "$c" in *"Your session log for today is"*|*"At the close, when no live session holds the pen"*) echo "$c"; return 1 ;; esac
  ! grep -q '"sH"' "$DAEDALUS_HOME/state/leases/unwindowed.json"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/lease.sh" log
  [ "$output" = "vault/sessions/$(date +%Y/%m)/$(date +%Y-%m-%d)-001.md" ] || { echo "$output"; return 1; }   # no gap left by the headless start
}

@test "a start while the upgrade is pending and state/leases/ does not exist yet reserves nothing and creates nothing; it says no number can be reserved yet and that hot.md and the vault commit work now" {
  cp "$BATS_TEST_DIRNAME/../upgrade.py" "$DAEDALUS_HOME/core/"
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"; mkdir -p "$DAEDALUS_HOME/state"
  python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(12)' "$DAEDALUS_HOME/state/.upgrade.lock" 3>&- &
  holder=$!; sleep 0.3
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run env LEASE_TEST_HOOK_BUDGET=15 bash -c "$(declare -f start); start s1 startup"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -d "$DAEDALUS_HOME/state/leases" ]
  c="$(ctx)"
  case "$c" in *"Your session log for today is"*) echo "$c"; return 1 ;; esac
  case "$c" in *"no session-log number can be reserved yet; hot.md and \`core/vault-commit.sh\` work now"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "a start while the upgrade is pending whose lease lock stays busy past the start budget writes no reservation and says so, naming core/lease.sh log — not claim, which is refused until the upgrade finishes" {
  pending_stopped_home
  mkdir -p "$DAEDALUS_HOME/state/leases"
  holder="$(python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close(); time.sleep(25)' "$DAEDALUS_HOME/state/leases/.lock" "$BATS_TEST_TMPDIR/held" 3>&- </dev/null >/dev/null 2>&1 & echo "$!")"
  printf '%s\n' "$holder" >> "$BATS_TEST_TMPDIR/live-pids"
  i=0; while [ ! -e "$BATS_TEST_TMPDIR/held" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  LEASE_TEST_HOOK_BUDGET=16 run start s1 startup
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx)"
  case "$c" in *"Your session log was not reserved at start: the lease lock stayed busy past the start budget"*"\`core/lease.sh log\`"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"Your session log for today is"*) echo "$c"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/unwindowed.json" ]
}

@test "the start's seven-day sweep also prunes state/ami/session-*.json" {
  mkdir -p "$DAEDALUS_HOME/state/ami/decisions"
  printf '{}' > "$DAEDALUS_HOME/state/ami/session-old.json"; touch -t 202001010000 "$DAEDALUS_HOME/state/ami/session-old.json"
  printf '{}' > "$DAEDALUS_HOME/state/ami/session-new.json"
  printf '{}' > "$DAEDALUS_HOME/state/ami/daemon.json"; touch -t 202001010000 "$DAEDALUS_HOME/state/ami/daemon.json"
  printf '{}' > "$DAEDALUS_HOME/state/session-old.json"; touch -t 202001010000 "$DAEDALUS_HOME/state/session-old.json"
  run start sS startup
  [ "$status" -eq 0 ]
  [ ! -e "$DAEDALUS_HOME/state/session-old.json" ]
  [ ! -e "$DAEDALUS_HOME/state/ami/session-old.json" ]
  [ -e "$DAEDALUS_HOME/state/ami/session-new.json" ]
  [ -e "$DAEDALUS_HOME/state/ami/daemon.json" ]          # only session files are swept
}
