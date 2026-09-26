#!/usr/bin/env bats
# SessionStart: the marker (root of trust for every later check) and, since
# v0.7.0, the binding that precedes it — DAEDALUS_LEASE, self-rebind,
# auto-numbering of terminal windows, first-up prime (spec §4.2, §4.8).
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
  case "$output" in *"This session cannot be bound to a lease: Several sessions are live and I cannot tell which tree is mine"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert "cannot tell which tree" in m["target_base_error"] and m["target_base"]=="", m' "$DAEDALUS_HOME/state/session-sU.json"
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
