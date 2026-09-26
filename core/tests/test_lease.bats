#!/usr/bin/env bats
# Pins core/leaselib.py and core/lease.sh — the only writers of state/leases/.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; LL="$DAEDALUS_HOME/core/leaselib.py"; }
teardown() { teardown_live; }

@test "lease id and alias field rules: 00 refused, 1 refused, alias regex and deny list, trunk name refused" {
  run python3 "$LL" validate-id 02;   [ "$status" -eq 0 ]
  run python3 "$LL" validate-id 00;   [ "$status" -ne 0 ]
  run python3 "$LL" validate-id 1;    [ "$status" -ne 0 ]
  run python3 "$LL" validate-id poc;  [ "$status" -ne 0 ]
  run python3 "$LL" validate-alias poc-ui; [ "$status" -eq 0 ]
  for bad in prime main master target vault state Poc "a" "-x" "$(printf 'x%.0s' $(seq 1 40))"; do
    run python3 "$LL" validate-alias "$bad"; [ "$status" -ne 0 ] || { echo "alias '$bad' should be refused"; return 1; }
  done
  # The configured trunk name is its own deny entry, distinct from the static
  # list: with the trunk renamed to something the static list does not carry,
  # that name is refused and `main` still is (the static entry, not the config).
  run python3 "$LL" validate-alias trunk-x; [ "$status" -eq 0 ]
  sed -i '' 's/^  branch: main$/  branch: trunk-x/' "$DAEDALUS_HOME/config.yaml"
  grep -q '^  branch: trunk-x$' "$DAEDALUS_HOME/config.yaml"
  run python3 "$LL" validate-alias trunk-x; [ "$status" -ne 0 ]
  run python3 "$LL" validate-alias main;    [ "$status" -ne 0 ]
  run python3 "$LL" validate-alias poc-ui;  [ "$status" -eq 0 ]
}

@test "write_lease is tmp+replace; exclusive write refuses an existing file; heartbeat never rewrites the JSON" {
  run python3 "$LL" _test-write 02 '{"lease":"02","session_id":null}'
  [ "$status" -eq 0 ]; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
  run python3 "$LL" _test-write 02 '{"lease":"02"}' --exclusive
  [ "$status" -ne 0 ]; case "$output" in *"already exists"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  before="$(shasum -a 256 "$DAEDALUS_HOME/state/leases/02.json")"
  for i in $(seq 1 100); do python3 "$LL" heartbeat 02; done
  [ "$(shasum -a 256 "$DAEDALUS_HOME/state/leases/02.json")" = "$before" ]
  [ -f "$DAEDALUS_HOME/state/leases/02.seen" ]
  [ ! -s "$DAEDALUS_HOME/state/leases/02.seen" ]
}

@test "resolve: no leases -> target/<name>; my lease -> its worktree; prime+lease -> the lease's worktree; prime only -> target" {
  run env DAEDALUS_SESSION_ID=sA python3 "$LL" resolve thing
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/target/thing" ]
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02"}'
  run env DAEDALUS_SESSION_ID=sA python3 "$LL" resolve thing
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/worktrees/02/thing" ]
  python3 "$LL" _test-write prime '{"session_id":"sA","history":[]}'
  run env DAEDALUS_SESSION_ID=sA python3 "$LL" resolve thing
  [ "$output" = "$DAEDALUS_HOME/worktrees/02/thing" ]
  python3 "$LL" _test-write prime '{"session_id":"sP","history":[]}'
  run env DAEDALUS_SESSION_ID=sP python3 "$LL" resolve thing
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/target/thing" ]
}

@test "resolve fails closed: a session with no lease while leases exist dies with the §4.4 sentence; a hint that disagrees dies; a hint naming a missing file dies; worktree_ready false dies naming claim" {
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02"}'
  # --separate-stderr: bats merges stderr into $output by default, and the
  # assertion is that STDOUT is empty (the sentence goes to stderr only).
  run --separate-stderr env DAEDALUS_SESSION_ID=sZ python3 "$LL" resolve thing
  [ "$status" -eq 3 ]; [ -z "$output" ]
  run bash -c "DAEDALUS_SESSION_ID=sZ python3 '$LL' resolve thing 2>&1 >/dev/null"
  case "$output" in *"Several sessions are live and I cannot tell which tree is mine"*"core/lease.sh create"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  run bash -c "DAEDALUS_SESSION_ID=sA DAEDALUS_LEASE=03 python3 '$LL' resolve thing 2>&1 >/dev/null"
  [ "$status" -eq 3 ]; case "$output" in *"DAEDALUS_LEASE=03"*"this session is window 02"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  run bash -c "DAEDALUS_SESSION_ID=sZ DAEDALUS_LEASE=07 python3 '$LL' resolve thing 2>&1 >/dev/null"
  [ "$status" -eq 3 ]; case "$output" in *"lease file for window 07 is gone"*"claim 07"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02","worktree_ready":false}'
  run bash -c "DAEDALUS_SESSION_ID=sA python3 '$LL' resolve thing 2>&1 >/dev/null"
  [ "$status" -eq 3 ]; case "$output" in *"window 02's worktree was not finished at start"*"core/lease.sh claim 02"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "resolve fails closed on a lease file that exists but cannot be read: the holder and an unbound session both die naming the file, never target/<name>" {
  L="$DAEDALUS_HOME/state/leases"
  # A truncated file — the only lease on disk. Silently skipping it would
  # resolve everyone to the prime's checkout (the spec's §4.4 'because').
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02"}'
  printf '{"lease":"02","session_id":"sA",' > "$L/02.json"
  for sid in sA sZ; do
    run --separate-stderr env DAEDALUS_SESSION_ID=$sid python3 "$LL" resolve thing
    [ "$status" -eq 3 ] || { echo "$sid: status $status, out: $output"; return 1; }
    [ -z "$output" ]
    case "$stderr" in *"The lease file for window 02 cannot be read"*"core/lease.sh sweep"*) : ;; *) echo "$sid wrong: $stderr"; return 1 ;; esac
  done
  # A corrupt file beside a valid one: the holder is told its file is broken,
  # not that it holds no lease (the 'create' remedy would be wrong).
  python3 "$LL" _test-write 03 '{"lease":"03","session_id":"sB","worktree":"worktrees/03","branch":"lease/03"}'
  run --separate-stderr env DAEDALUS_SESSION_ID=sA python3 "$LL" resolve thing
  [ "$status" -eq 3 ]; case "$stderr" in *"lease file for window 02 cannot be read"*) : ;; *"Several sessions"*) echo "wrong remedy: $stderr"; return 1 ;; *) echo "wrong: $stderr"; return 1 ;; esac
  rm "$L/03.json"
  # Not a JSON object at all.
  printf '[1,2]' > "$L/02.json"
  run --separate-stderr env DAEDALUS_SESSION_ID=sA python3 "$LL" resolve thing
  [ "$status" -eq 3 ]; case "$stderr" in *"lease file for window 02 cannot be read"*) : ;; *) echo "wrong: $stderr"; return 1 ;; esac
  # Valid JSON the process cannot open (root reads through mode 000, so skip there).
  if [ "$(id -u)" -ne 0 ]; then
    python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02"}'
    chmod 000 "$L/02.json"
    run --separate-stderr env DAEDALUS_SESSION_ID=sA python3 "$LL" resolve thing
    chmod 644 "$L/02.json"
    [ "$status" -eq 3 ]; case "$stderr" in *"lease file for window 02 cannot be read"*) : ;; *) echo "wrong: $stderr"; return 1 ;; esac
  fi
  # prime.json broken: a session that may hold the pen cannot be told apart, so it dies too.
  printf '{"session_id":' > "$L/prime.json"
  run --separate-stderr env DAEDALUS_SESSION_ID=sP python3 "$LL" resolve thing
  [ "$status" -eq 3 ]; case "$stderr" in *"prime file"*"cannot be read"*) : ;; *) echo "wrong: $stderr"; return 1 ;; esac
  rm "$L/prime.json"
  # An operator shell still gets the prime's checkout, and the note names the broken file.
  printf '{"lease":"02",' > "$L/02.json"
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u DAEDALUS_LEASE python3 '$LL' resolve thing 2>'$BATS_TEST_TMPDIR/err'"
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/target/thing" ]
  grep -q "no session — using the prime's checkout target/thing" "$BATS_TEST_TMPDIR/err"
  grep -q "lease file for window 02 cannot be read" "$BATS_TEST_TMPDIR/err"
}

@test "resolve: an operator shell (no session variable at all) gets target/<name> and a stderr note naming the live-window count" {
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02"}'
  python3 "$LL" _test-write 03 '{"lease":"03","session_id":"sB","worktree":"worktrees/03","branch":"lease/03"}'
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u DAEDALUS_LEASE python3 '$LL' resolve thing 2>'$BATS_TEST_TMPDIR/err'"
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/target/thing" ]
  grep -q "no session — using the prime's checkout target/thing (2 windows live)" "$BATS_TEST_TMPDIR/err"
}

@test "resolve: DAEDALUS_TARGET_OVERRIDE wins only under state/promote/" {
  mkdir -p "$DAEDALUS_HOME/state/promote/x/thing"
  run env DAEDALUS_SESSION_ID=sA DAEDALUS_TARGET_OVERRIDE="$DAEDALUS_HOME/state/promote/x/thing" python3 "$LL" resolve thing
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/state/promote/x/thing" ]
  run bash -c "DAEDALUS_SESSION_ID=sA DAEDALUS_TARGET_OVERRIDE=/tmp/elsewhere python3 '$LL' resolve thing 2>&1 >/dev/null"
  [ "$status" -eq 3 ]; case "$output" in *"DAEDALUS_TARGET_OVERRIDE"*"must point under state/promote/"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "the product .gitignore lists worktrees/" {
  grep -qx 'worktrees/' "$SRC/../.gitignore"
}

# --- Liveness (spec §4.5), registry lookup (§4.8), leases.stale_after (§8.1) ---

@test "liveness: a live pid with matching proc_started is live; a dead pid is stale; a LIVE pid with a non-matching proc_started is stale (pid reuse — the mismatch branch, not the dead-pid branch); pid 1 (another user's process: kill(1,0) is EPERM) counts as alive; a stale heartbeat with a live pid is quiet" {
  pid="$(live_pid)"
  python3 "$LL" _test-write 02 "{\"lease\":\"02\",\"session_id\":\"sA\",\"pid\":$pid,\"proc_started\":$(ps_ms "$pid")}"
  python3 "$LL" heartbeat 02
  run python3 "$LL" liveness 02; [ "$output" = "live" ]
  pidr="$(live_pid)"     # alive, but the lease says it started at epoch 1: a re-used pid
  python3 "$LL" _test-write 03 "{\"lease\":\"03\",\"session_id\":\"sB\",\"pid\":$pidr,\"proc_started\":1}"
  python3 "$LL" heartbeat 03
  run python3 "$LL" liveness 03; [ "$output" = "stale" ]
  run python3 "$LL" pid-alive 1; [ "$status" -eq 0 ]          # EPERM is "exists", never "dead"
  run python3 "$LL" pid-alive 4194304; [ "$status" -ne 0 ]    # past pid_max on macOS: ESRCH
  kill "$pid"; wait "$pid" 2>/dev/null || true
  run python3 "$LL" liveness 02; [ "$output" = "stale" ]
  pid2="$(live_pid)"
  python3 "$LL" _test-write 04 "{\"lease\":\"04\",\"session_id\":\"sC\",\"pid\":$pid2,\"proc_started\":$(ps_ms "$pid2")}"
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/04.seen"
  run python3 "$LL" liveness 04; [ "$output" = "quiet" ]
}

@test "liveness: a recorded pid that is no longer that process, whose session id is live in the registry under a new pid, is 'resumed', never stale; two registry entries for one session id are reported" {
  pid="$(live_pid)"
  registry_entry "$pid" sA
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","pid":1,"proc_started":1}'
  run python3 "$LL" liveness 02; [ "$output" = "resumed" ]
  registry_entry 99999 sA
  run python3 "$LL" registry-pids sA
  case "$output" in *"$pid"*99999*|*99999*"$pid"*) : ;; *) echo "expected both pids: $output"; return 1 ;; esac
}

@test "liveness with no registry and no recorded pid falls back to the heartbeat alone" {
  rm -rf "$BATS_TEST_TMPDIR/sessions"
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA"}'
  python3 "$LL" heartbeat 02
  run python3 "$LL" liveness 02; [ "$output" = "live" ]
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/02.seen"
  run python3 "$LL" liveness 02; [ "$output" = "stale" ]
}

@test "stale_after: default 4h; m/h/d suffixes; anything else falls back to the default with a note" {
  run python3 "$LL" stale-after; [ "$output" = "14400" ]
  printf 'leases:\n  stale_after: 90m\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$LL" stale-after; [ "$output" = "5400" ]
  sed -i '' 's/90m/2d/' "$DAEDALUS_HOME/config.yaml"
  run python3 "$LL" stale-after; [ "$output" = "172800" ]
  sed -i '' 's/2d/soon/' "$DAEDALUS_HOME/config.yaml"
  # --separate-stderr: the note goes to stderr, which run merges into $output by default.
  run --separate-stderr python3 "$LL" stale-after; [ "$output" = "14400" ]
  run bash -c "python3 '$LL' stale-after 2>&1 >/dev/null"; case "$output" in *"stale_after"*"soon"*) : ;; *) echo "no note: $output"; return 1 ;; esac
}

@test "the real config.example.yaml carries a leases: block whose stale_after parses" {
  DAEDALUS_CONFIG="$SRC/../config.example.yaml" run python3 "$LL" stale-after
  [ "$output" = "14400" ]
}
