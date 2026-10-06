#!/usr/bin/env bats
# Pins core/leaselib.py and core/lease.sh — the only writers of state/leases/.
# Wall-clock assertions live in this file: under the parallel full-suite gate
# (`bats --jobs 12`) its tests run one at a time, while other files run beside it.
BATS_NO_PARALLELIZE_WITHIN_FILE=true
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
load fixtures/transcripts/setup.bash
load fixtures/tty/setup.bash
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

@test "resolve refuses a DAEDALUS_LEASE that is not a window number by name — prime, an alias, a path — never as 'the lease file for window ../x is gone' (Task 6 review)" {
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","worktree":"worktrees/02","branch":"lease/02"}'
  for bad in prime ../x poc-ui 00; do
    run bash -c "DAEDALUS_SESSION_ID=sA DAEDALUS_LEASE=$bad python3 '$LL' resolve thing 2>&1 >/dev/null"
    [ "$status" -eq 3 ]
    case "$output" in *"\`DAEDALUS_LEASE=$bad\` is not a window number (two digits, 01–99)"*) : ;; *) echo "$bad: $output"; return 1 ;; esac
    case "$output" in *"is gone"*|*"this session is window"*) echo "$bad: wrong sentence: $output"; return 1 ;; *) : ;; esac
  done
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
  # Plain language: one window is "1 window live", never "1 windows" (Task 18 review).
  rm "$DAEDALUS_HOME/state/leases/03.json"
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u DAEDALUS_LEASE python3 '$LL' resolve thing 2>'$BATS_TEST_TMPDIR/err'"
  [ "$status" -eq 0 ]
  grep -q "no session — using the prime's checkout target/thing (1 window live)" "$BATS_TEST_TMPDIR/err"
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

@test "liveness: a registry entry is 'live' only when its pid is still the process it recorded (startedAt within 2 s of ps lstart) — a left-behind sessions/<pid>.json whose pid was recycled by another process does not make a dead lease 'resumed'" {
  # The lease's own pid check closes the pid-recycling hole (§4.5); the
  # registry-side check must close the same hole, or a crashed session's
  # stale registry file plus one long-lived process on that pid would keep
  # a dead lease unsweepable forever (sweep never removes a "resumed" lease).
  rm -f "$BATS_TEST_TMPDIR/sessions"/*.json
  pid="$(live_pid)"
  registry_entry "$pid" sA interactive cli daedalus-xx 1      # alive, but startedAt says epoch 1: a re-used pid
  python3 "$LL" _test-write 02 '{"lease":"02","session_id":"sA","pid":4194304,"proc_started":1}'
  run python3 "$LL" liveness 02; [ "$output" = "stale" ] || { echo "recycled registry pid read as: $output"; return 1; }
  registry_entry "$pid" sA                                    # the same pid with its real start time: resumed
  run python3 "$LL" liveness 02; [ "$output" = "resumed" ]
  run python3 "$LL" registry-live-pids sA; [ "$output" = "$pid" ]
  registry_entry 99999 sA                                     # a dead pid beside it changes nothing
  run python3 "$LL" registry-live-pids sA; [ "$output" = "$pid" ]
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
  # The default is also 4h, so "prints 14400" alone would pass with the block
  # deleted or the file unreadable (the cfg failure is swallowed). Pin the raw
  # value through cfg first, with the file's own path, then the parse.
  DAEDALUS_CONFIG="$SRC/../config.example.yaml" run bash -c "source '$SRC/lib.sh'; cfg leases.stale_after"
  [ "$status" -eq 0 ]; [ "$output" = "4h" ] || { echo "cfg leases.stale_after from config.example.yaml: '$output'"; return 1; }
  DAEDALUS_CONFIG="$SRC/../config.example.yaml" run --separate-stderr python3 "$LL" stale-after
  [ "$output" = "14400" ]; [ -z "$stderr" ]
  # And the guard itself: with the block gone the cfg leg fails, so the test would.
  sed '/^leases:/,$d' "$SRC/../config.example.yaml" > "$BATS_TEST_TMPDIR/no-leases.yaml"
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/no-leases.yaml" run bash -c "source '$SRC/lib.sh'; cfg leases.stale_after"
  [ "$status" -ne 0 ]
}

# --- Allocation (spec §4.2 Numbering / Allocation / Re-use or refuse), lease.sh create ---

LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }

@test "create allocates 01 on an empty directory with session_id null, worktrees for main and nested at mirrored paths on lease/01 from origin/main, scaffold dirs, an empty .changed, and prints the launch line" {
  # target.scaffold must sit inside the target: block (cfg's block parser),
  # so it is inserted after target.nested rather than appended to the file.
  python3 - "$DAEDALUS_HOME/config.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("  nested: sub=https://example.com/sub.git\n", "  nested: sub=https://example.com/sub.git\n  scaffold: vaults/a=https://example.com/v.git\n")
open(p,"w").write(s)
PY
  run LS create --note "first thing"
  [ "$status" -eq 0 ]
  case "$output" in *"Window 01 is ready (not bound to any session yet)."*"DAEDALUS_LEASE=01 claude --bg --name daedalus-01"*"DAEDALUS_LEASE=01 claude --name daedalus-01"*) : ;; *) echo "launch line: $output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = "None" ]
  [ "$(lease_json 01 note)" = "first thing" ]
  [ "$(lease_json 01 worktree)" = "worktrees/01" ]
  [ "$(lease_json 01 branch)" = "lease/01" ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" rev-parse --abbrev-ref HEAD)" = "lease/01" ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" rev-parse HEAD)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing/sub" rev-parse --abbrev-ref HEAD)" = "lease/01" ]
  [ -d "$DAEDALUS_HOME/worktrees/01/thing/vaults/a" ]
  [ "$(cat "$DAEDALUS_HOME/state/leases/01.changed")" = "{}" ]
  python3 - "$DAEDALUS_HOME/state/leases/01.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d["repos"]==["thing","thing/sub"], d; assert d["trunks"]=={"thing":"main","thing/sub":"main"}, d
assert d["created"] and d["promoted"]==[], d
PY
}

@test "the launch line's closing sentence depends on the registry: present -> 'numbers itself'; absent -> 'every terminal window needs the line above'" {
  run LS create; case "$output" in *"a plain \`claude\` window numbers itself"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  rm -rf "$BATS_TEST_TMPDIR/sessions"
  run LS create; case "$output" in *"This build has no session registry: every terminal window needs the line above."*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "numbering: 03 with 01 live and 02 stale-but-unswept; 03 with 01 live and a swept 02 whose lease/02 has unpromoted commits (the number is not free); a swept, merged 02 is re-used and fast-forwarded" {
  LS create >/dev/null; LS create >/dev/null           # 01, 02
  W="$DAEDALUS_HOME/worktrees/02/thing"
  printf 'w\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "capture: read error before error_message"
  rm -f "$DAEDALUS_HOME/state/leases/02.json"          # "swept": work waits under lease/02
  run LS create; case "$output" in *"Window 03 is ready"*) : ;; *) echo "expected 03: $output"; return 1 ;; esac
  run python3 "$LL" waiting-work 02; case "$output" in *"capture: read error before error_message"*) : ;; *) echo "waiting: $output"; return 1 ;; esac
  # now 04 is next; make lease/03 merged (it already equals trunk) and sweep it -> 03 is re-used, in place
  rm -f "$DAEDALUS_HOME/state/leases/03.json"
  run LS create; case "$output" in *"Window 03 is ready"*) : ;; *) echo "expected 03 re-used: $output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/worktrees/03/thing" rev-parse --abbrev-ref HEAD)" = "lease/03" ]
  # a hand-deleted directory that git still registers is pruned and adopted
  rm -rf "$DAEDALUS_HOME/worktrees/03"; rm -f "$DAEDALUS_HOME/state/leases/03.json"
  run LS create; [ "$status" -eq 0 ]; case "$output" in *"Window 03 is ready"*) : ;; *) echo "prune+adopt: $output"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/worktrees/03/thing/a.txt" ]
}

@test "a directory at worktrees/<NN>/<repo> that git does not know is refused by name" {
  mkdir -p "$DAEDALUS_HOME/worktrees/01/thing"; printf 'stray\n' > "$DAEDALUS_HOME/worktrees/01/thing/x"
  run LS create; [ "$status" -ne 0 ]
  case "$output" in *"worktrees/01/thing exists but is not a worktree of target/thing; move it aside."*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]
}

@test "allocation fails closed when a nested repo has no origin/HEAD" {
  git -C "$T/sub" symbolic-ref --delete refs/remotes/origin/HEAD
  run LS create; [ "$status" -ne 0 ]
  case "$output" in *"sub has no origin/HEAD"*"remote set-head origin -a"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "two concurrent allocations that computed one number leave two leases with two numbers (O_EXCL + recompute)" {
  ( LS create >/dev/null ) & ( LS create >/dev/null ) & wait
  [ -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
  [ "$(ls "$DAEDALUS_HOME/state/leases"/*.json | wc -l | tr -d ' ')" -eq 2 ]
}

@test "a worktree add that hangs past the budget leaves the lease with worktree_ready false; claim finishes it" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-slow" "$BATS_TEST_TMPDIR/bin/git"; chmod +x "$BATS_TEST_TMPDIR/bin/git"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_GIT_SLEEP=3 LEASE_WORKTREE_TIMEOUT=1 run LS create
  [ "$status" -eq 0 ]
  [ "$(lease_json 01 worktree_ready)" = "False" ]
  case "$output" in *"worktree was not finished"*"claim 01"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "allocation never consults the leases for the target's name: an UNBOUND session (a session id that holds no lease, with 01 bound to another session and the pen held) can still create 02, and its worktree lands at worktrees/02/thing" {
  LS create >/dev/null
  python3 "$LL" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sA"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  python3 "$LL" _test-write prime '{"session_id":"sA","history":[]}'
  # LS is a shell function, so the variable is set on the run, not through env(1).
  DAEDALUS_SESSION_ID=sZ run LS create              # sZ would be Refused by target_path; create must not care
  [ "$status" -eq 0 ]; case "$output" in *"Window 02 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/worktrees/02/thing" ]; [ "$(lease_json 02 worktree)" = "worktrees/02" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repos"]==["thing","thing/sub"], d' "$DAEDALUS_HOME/state/leases/02.json"
  DAEDALUS_SESSION_ID=sZ run LS create; case "$output" in *"Window 03 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "allocation fails closed when lib.sh target_name cannot answer: an invalid target.dir refuses with lib.sh's own sentence, writes no lease, creates no worktrees/, and never cuts a worktree of the PRODUCT repo (the empty-name fallback would allocate against target/ itself)" {
  # No nested repo: with the name empty, target/ + "" is the product's own
  # tree, and git would happily cut worktrees/01 from it and report success.
  python3 - "$DAEDALUS_HOME/config.yaml" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("  nested: sub=https://example.com/sub.git\n", "  dir: a/b\n")
open(p,"w").write(s)
PY
  git -C "$DAEDALUS_HOME" remote add origin "$BATS_TEST_TMPDIR/origin.git"   # so a product-repo worktree add could succeed
  run LS create; [ "$status" -ne 0 ] || { echo "create succeeded: $output"; return 1; }
  case "$output" in *"config target.dir: a/b must be a single directory name, not a path"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]
  [ ! -d "$DAEDALUS_HOME/worktrees" ]
  [ "$(git -C "$DAEDALUS_HOME" worktree list | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(git -C "$T" worktree list | wc -l | tr -d ' ')" -eq 1 ]
  # The same misconfiguration with the nested repo present must name the
  # config problem, not send the operator to fix the nested repo's origin/HEAD.
  sed -i '' 's|^  dir: a/b$|  dir: a/b\n  nested: sub=https://example.com/sub.git|' "$DAEDALUS_HOME/config.yaml"
  run LS create; [ "$status" -ne 0 ]
  case "$output" in *"origin/HEAD"*) echo "wrong diagnosis: $output"; return 1 ;; *"config target.dir: a/b must be a single directory name"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  # waiting-work goes through the same wrapper and must not fall through to a traceback or target/.
  run python3 "$LL" waiting-work 01; [ "$status" -ne 0 ]; case "$output" in *"config target.dir: a/b"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "allocation fails closed when lib.sh target_name answers nothing or does not answer in time: an empty name and a 5 s timeout both refuse in plain words, and nothing is allocated" {
  cp "$DAEDALUS_HOME/core/lib.sh" "$BATS_TEST_TMPDIR/lib.sh.orig"
  printf '\ntarget_name() { :; }\n' >> "$DAEDALUS_HOME/core/lib.sh"          # exit 0, prints nothing
  run LS create; [ "$status" -ne 0 ] || { echo "create succeeded on an empty name: $output"; return 1; }
  case "$output" in *"could not read the target's name from config"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -d "$DAEDALUS_HOME/worktrees" ]
  cp "$BATS_TEST_TMPDIR/lib.sh.orig" "$DAEDALUS_HOME/core/lib.sh"
  printf '\ntarget_name() { sleep 7; printf "thing\\n"; }\n' >> "$DAEDALUS_HOME/core/lib.sh"   # past the 5 s budget
  run LS create; [ "$status" -ne 0 ] || { echo "create succeeded on a timeout: $output"; return 1; }
  case "$output" in *"could not read the target's name from config"*"did not answer"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -d "$DAEDALUS_HOME/worktrees" ]
}

@test "numbering fails closed when origin/<trunk> cannot be resolved: a swept number with unpromoted commits is NOT re-used over them, and a fresh number is not cut from a guessed ref — both refuse naming target.branch, and no lease is written" {
  LS create >/dev/null                                  # 01
  W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'w\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "unpromoted work on 01"
  rm -f "$DAEDALUS_HOME/state/leases/01.json"           # swept; work waits under lease/01
  run LS create; case "$output" in *"Window 02 is ready"*) : ;; *) echo "control: $output"; return 1 ;; esac
  rm -rf "$DAEDALUS_HOME/worktrees/02" "$DAEDALUS_HOME/state/leases/02.json"
  git -C "$T" worktree prune; git -C "$T" branch -D lease/02 -q; git -C "$T/sub" worktree prune; git -C "$T/sub" branch -D lease/02 -q
  sed -i '' 's/^  branch: main$/  branch: trunk-x/' "$DAEDALUS_HOME/config.yaml"
  run LS create; [ "$status" -ne 0 ] || { echo "create succeeded with no origin/trunk-x: $output"; return 1; }
  case "$output" in *"target/thing has no origin/trunk-x"*"target.branch"*"fetch origin"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  case "$output" in *"fatal: invalid reference"*) echo "raw git fatal leaked: $output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -f "$DAEDALUS_HOME/state/leases/02.json" ]
  [ "$(git -C "$W" log --format=%s -1)" = "unpromoted work on 01" ]
  # The helper itself refuses rather than answering "nothing waiting".
  run python3 "$LL" waiting-work 01; [ "$status" -ne 0 ]; case "$output" in *"no origin/trunk-x"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  # A dangling origin/HEAD on the nested repo (points at a branch that is gone) is the same hole on the other repo kind.
  sed -i '' 's/^  branch: trunk-x$/  branch: main/' "$DAEDALUS_HOME/config.yaml"
  git -C "$T/sub" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
  run LS create; [ "$status" -ne 0 ]
  case "$output" in *"target/thing/sub has no origin/gone"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
}

@test "an adopted lease branch whose fast-forward to origin/<trunk> fails says so on stderr instead of staying silently behind" {
  LS create >/dev/null                                  # 01 at origin/main; lease/01 stays an ancestor (merged), so 01 is free once swept
  trunk_moves a.txt "trunk moved"
  W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'local edit\n' >> "$W/a.txt"                  # uncommitted, on the same file: ff-only refuses to overwrite it
  rm -f "$DAEDALUS_HOME/state/leases/01.json"
  run --separate-stderr LS create; [ "$status" -eq 0 ]; case "$output" in *"Window 01 is ready"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  case "$stderr" in *"window 01: thing could not be fast-forwarded to origin/main"*"rebase it before promoting"*) : ;; *) echo "no ff note: $stderr"; return 1 ;; esac
  [ "$(git -C "$W" rev-parse HEAD)" != "$(git -C "$T" rev-parse origin/main)" ]
}

# --- Binding and the lifecycle commands (spec §4.2 claim / alias / note / release / done / spawn, §4.5 sweep, §4.1 alias rules) ---
# LS is a shell function, so a session id is set on the run (VAR=x run LS ...),
# never through env(1), which cannot exec a function.

@test "claim binds a null lease using CLAUDE_CODE_SESSION_ID, records pid/proc_started/peer_name from the registry, and is idempotent; a live-bound lease is refused with the holder's peer name; a resumed holder still counts as live; a stale-bound one is taken over" {
  LS create >/dev/null
  pid="$(live_pid)"; registry_entry "$pid" sA interactive cli daedalus-01
  CLAUDE_CODE_SESSION_ID=sA run LS claim 01
  [ "$status" -eq 0 ]; case "$output" in *"window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = "sA" ]; [ "$(lease_json 01 pid)" = "$pid" ]; [ "$(lease_json 01 peer_name)" = "daedalus-01" ]
  [ "$(lease_json 01 proc_started)" = "$(ps_ms "$pid")" ]
  CLAUDE_CODE_SESSION_ID=sA run LS claim 01; [ "$status" -eq 0 ]
  # One lease per session id (§4.2 — a lease names one session, resolve/board/done assume it): the holder of 01 cannot take 02 too.
  LS create >/dev/null
  CLAUDE_CODE_SESSION_ID=sA run LS claim 02
  [ "$status" -ne 0 ]; case "$output" in *"This session is already window 01; say 'release 01' first."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 02 session_id)" = "None" ]; [ "$(lease_json 01 session_id)" = "sA" ]
  CLAUDE_CODE_SESSION_ID=sB run LS claim 01
  [ "$status" -ne 0 ]; case "$output" in *"Window 01 is held by a live session (peer name daedalus-01)"*) : ;; *) echo "$output"; return 1 ;; esac
  # A dead recorded pid whose session id is still live in the registry is a
  # RESUMED holder (§4.2), and a resumed window is held: still refused.
  python3 "$LL" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  CLAUDE_CODE_SESSION_ID=sB run LS claim 01
  [ "$status" -ne 0 ]; case "$output" in *"Window 01 is held by a live session"*) : ;; *) echo "$output"; return 1 ;; esac
  # With the holder's registry entry gone the lease is stale: taken over.
  rm -f "$BATS_TEST_TMPDIR/sessions/$pid.json"
  CLAUDE_CODE_SESSION_ID=sB run LS claim 01; [ "$status" -eq 0 ]; [ "$(lease_json 01 session_id)" = "sB" ]
  [ "$(lease_json 01 pid)" = "None" ]
}

@test "claim over a finished window whose clone has exited takes it over with the clone's report cleared: finished, summary and spawned are gone, the takeover names the old report, and a later sweep sees a plain lease instead of FINISHED forever" {
  LS create >/dev/null
  CLAUDE_CODE_SESSION_ID=sE LS claim 01 >/dev/null; CLAUDE_CODE_SESSION_ID=sE LS done 01 --summary "did the thing" >/dev/null
  python3 "$LL" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["spawned"]=True; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  CLAUDE_CODE_SESSION_ID=sB run LS claim 01
  [ "$status" -eq 0 ]; case "$output" in *"This is window 01."*"finished"*"did the thing"*"cleared"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = "sB" ]
  [ "$(lease_json 01 finished)" = "None" ]; [ "$(lease_json 01 summary)" = "None" ]; [ "$(lease_json 01 spawned)" = "None" ]
  # A released-but-unswept finished lease whose holder is gone is taken over the same way.
  CLAUDE_CODE_SESSION_ID=sB LS done 01 --summary "again" >/dev/null; CLAUDE_CODE_SESSION_ID=sB LS release 01 >/dev/null
  python3 "$LL" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  CLAUDE_CODE_SESSION_ID=sC run LS claim 01; [ "$status" -eq 0 ]
  [ "$(lease_json 01 finished)" = "None" ]; [ "$(lease_json 01 released)" = "None" ]; [ "$(lease_json 01 session_id)" = "sC" ]
  # The clone's OWN binding of a spawned lease (session_id null -> the clone) keeps spawned: true.
  LS create --spawned >/dev/null
  CLAUDE_CODE_SESSION_ID=sD run LS claim 02; [ "$status" -eq 0 ]; [ "$(lease_json 02 spawned)" = "True" ]
  # Re-claiming one's own finished window (idempotent claim) keeps the report.
  CLAUDE_CODE_SESSION_ID=sD LS done 02 --summary "mine" >/dev/null
  CLAUDE_CODE_SESSION_ID=sD run LS claim 02; [ "$status" -eq 0 ]; [ "$(lease_json 02 summary)" = "mine" ]
}

@test "claim needs a session: an operator shell is refused naming DAEDALUS_SESSION_ID" {
  LS create >/dev/null
  run LS claim 01; [ "$status" -ne 0 ]
  case "$output" in *"claim needs a session"*"DAEDALUS_SESSION_ID"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = "None" ]
}

@test "claim over a swept number with unpromoted commits adopts the work and prints the subjects" {
  LS create >/dev/null
  W="$DAEDALUS_HOME/worktrees/01/thing"; printf 'w\n' >> "$W/a.txt"
  git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "test: error field fallback"
  rm -f "$DAEDALUS_HOME/state/leases/01.json"
  CLAUDE_CODE_SESSION_ID=sA run LS claim 01
  [ "$status" -eq 0 ]; case "$output" in *"Window 01 continues 1 unpromoted commit"*"test: error field fallback"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = "sA" ]
  [ "$(git -C "$W" log --format=%s -1)" = "test: error field fallback" ]
  [ -f "$DAEDALUS_HOME/state/leases/01.changed" ]; [ -f "$DAEDALUS_HOME/state/leases/01.seen" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["repos"]==["thing","thing/sub"], d; assert d["worktree"]=="worktrees/01", d' "$DAEDALUS_HOME/state/leases/01.json"
}

@test "claim refuses while the registry shows the caller's session id in two terminals" {
  LS create >/dev/null
  p1="$(live_pid)"; registry_entry "$p1" sA; p2="$(live_pid)"; registry_entry "$p2" sA
  CLAUDE_CODE_SESSION_ID=sA run LS claim 01
  [ "$status" -ne 0 ]; case "$output" in *"open in two terminals at once (pids"*"close one"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"$p1"*"$p2"*|*"$p2"*"$p1"*) : ;; *) echo "expected both pids: $output"; return 1 ;; esac
  [ "$(lease_json 01 session_id)" = "None" ]
  kill "$p1" 2>/dev/null; true
}

@test "alias and note write their fields; an alias in a lease-id position is refused naming the number; a reserved or duplicate alias is refused; --clear removes it" {
  LS create >/dev/null; LS create >/dev/null
  run LS alias 01 poc-ui; [ "$status" -eq 0 ]; [ "$(lease_json 01 alias)" = "poc-ui" ]
  case "$output" in *"Window 01 is now shown as poc-ui on the board."*) : ;; *) echo "$output"; return 1 ;; esac
  run LS alias 02 poc-ui; [ "$status" -ne 0 ]; case "$output" in *"poc-ui"*"window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  run LS alias 02 main; [ "$status" -ne 0 ]
  run LS note poc-ui "x"; [ "$status" -ne 0 ]; case "$output" in *"poc-ui is an alias; window 01 carries it — say \`note 01\`"*) : ;; *) echo "$output"; return 1 ;; esac
  run LS note 01 "EX-024 capture error-field fix"; [ "$status" -eq 0 ]; [ "$(lease_json 01 note)" = "EX-024 capture error-field fix" ]
  run LS note 07 "x"; [ "$status" -ne 0 ]; case "$output" in *"There is no window 07."*) : ;; *) echo "$output"; return 1 ;; esac
  run LS note 7 "x"; [ "$status" -ne 0 ]; case "$output" in *"7 is not a window number"*) : ;; *) echo "$output"; return 1 ;; esac
  run LS alias 01 --clear; [ "$status" -eq 0 ]; [ "$(lease_json 01 alias)" = "None" ]
  printf 'x\n' > "$BATS_TEST_TMPDIR/crit.md"
  run LS update 01 --criteria "$BATS_TEST_TMPDIR/crit.md"; [ "$status" -eq 0 ]; [ "$(lease_json 01 criteria)" = "$BATS_TEST_TMPDIR/crit.md" ]
}

@test "release: by a non-holder of a live lease refused with the holder's peer name; by the holder marks released; of a stale lease succeeds from anywhere; --remove refuses unmerged commits without --force and deletes worktree and branch with it" {
  LS create >/dev/null
  pid="$(live_pid)"; registry_entry "$pid" sA interactive cli daedalus-01
  CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS release 01
  [ "$status" -ne 0 ]; case "$output" in *"Window 01 is held by a live session (peer name daedalus-01). Say 'release 01' to that window, or close it first."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 released)" = "None" ]
  CLAUDE_CODE_SESSION_ID=sA run LS release 01
  [ "$status" -eq 0 ]; [ "$(lease_json 01 released)" != "None" ]
  case "$output" in *"Window 01 released; this window is done — close it."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  LS create >/dev/null   # 02 (01 is held-but-released until sweep)
  [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
  W="$DAEDALUS_HOME/worktrees/02/thing"; printf 'w\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "unmerged work"
  python3 "$LL" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sZ"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  CLAUDE_CODE_SESSION_ID=sB run LS release 02 --remove
  [ "$status" -ne 0 ]; case "$output" in *"unmerged work"*"--force"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$W" ]; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
  # Uncommitted work (a modified tracked file and an untracked one) is refused
  # the same way, named by path — git's own refusal is never bypassed silently
  # (§4.5: work is never deleted by a cleanup; --remove is the explicit path).
  printf 'd\n' >> "$W/a.txt"; printf 'u\n' > "$W/untracked.txt"
  CLAUDE_CODE_SESSION_ID=sB run LS release 02 --remove
  [ "$status" -ne 0 ]; case "$output" in *"unmerged work"*"has uncommitted changes in worktrees/02/thing (2 files: a.txt, untracked.txt)"*"Add --force to delete them."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$W" ]; [ -f "$W/untracked.txt" ]; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
  CLAUDE_CODE_SESSION_ID=sB run LS release 02 --remove --force
  [ "$status" -eq 0 ]; case "$output" in *"unmerged work"*) : ;; *) echo "must repeat the subjects: $output"; return 1 ;; esac
  case "$output" in *"Deleting window 02's uncommitted changes in worktrees/02/thing: a.txt, untracked.txt"*) : ;; *) echo "must name the files being deleted: $output"; return 1 ;; esac
  [ ! -d "$W" ]; run git -C "$T" rev-parse --verify -q lease/02; [ "$status" -ne 0 ]
  run git -C "$T/sub" rev-parse --verify -q lease/02; [ "$status" -ne 0 ]
  [ ! -f "$DAEDALUS_HOME/state/leases/02.json" ]; [ ! -f "$DAEDALUS_HOME/state/leases/02.seen" ]; [ ! -f "$DAEDALUS_HOME/state/leases/02.changed" ]
  # An operator shell (no session) may release a stale lease too — and a dirty
  # NESTED worktree with no commits at all is still refused without --force.
  printf 'z\n' >> "$DAEDALUS_HOME/worktrees/01/thing/sub/n.txt"
  run LS release 01 --remove
  [ "$status" -ne 0 ]; case "$output" in *"Window 01 has uncommitted changes in worktrees/01/thing/sub (1 file: n.txt). Add --force to delete them."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]; [ -f "$DAEDALUS_HOME/state/leases/01.json" ]
  run LS release 01 --remove --force; [ "$status" -eq 0 ]; [ ! -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  case "$output" in *"uncommitted changes in worktrees/01/thing/sub: n.txt"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "done: from the holder writes finished and summary; from another session refused" {
  LS create >/dev/null
  CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS done 01 --summary "x"; [ "$status" -ne 0 ]
  case "$output" in *"Only window 01's own session may mark it done."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 finished)" = "None" ]
  CLAUDE_CODE_SESSION_ID=sA run LS done 01 --summary "changed a.txt; untested"; [ "$status" -eq 0 ]
  [ "$(lease_json 01 finished)" != "None" ]; [ "$(lease_json 01 summary)" = "changed a.txt; untested" ]
  case "$output" in *"This is window 01"*"finished: changed a.txt; untested"*"Promote or release it."*) : ;; *) echo "$output"; return 1 ;; esac
  # A script cannot call SendMessage (recorded deviation): the line to send and the prime's peer name are printed.
  case "$output" in *"SendMessage"*) : ;; *) echo "no send instruction: $output"; return 1 ;; esac
}

@test "sweep removes stale and released leases, refuses a quiet one without --force, keeps a finished one until promote or release, never touches a worktree, and rebinds a resumed session instead of removing it" {
  LS create >/dev/null; LS create >/dev/null; LS create >/dev/null; LS create >/dev/null; LS create >/dev/null
  python3 "$LL" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sA"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  pid="$(live_pid)"; registry_entry "$pid" sB
  python3 "$LL" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="sB"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  CLAUDE_CODE_SESSION_ID=sC LS claim 03 >/dev/null; CLAUDE_CODE_SESSION_ID=sC LS release 03 >/dev/null
  pid4="$(live_pid)"; registry_entry "$pid4" sD; CLAUDE_CODE_SESSION_ID=sD LS claim 04 >/dev/null
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/04.seen"
  # 05: a spawned clone that reported and exited — finished, dead pid (§4.2 "quiet-by-design").
  CLAUDE_CODE_SESSION_ID=sE LS claim 05 >/dev/null; CLAUDE_CODE_SESSION_ID=sE LS done 05 --summary "did the thing" >/dev/null
  python3 "$LL" _test-write 05 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["spawned"]=True; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/05.json")"
  run LS sweep; [ "$status" -eq 0 ]
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]
  [ ! -f "$DAEDALUS_HOME/state/leases/01.seen" ]; [ ! -f "$DAEDALUS_HOME/state/leases/01.changed" ]
  case "$output" in *"window 01"*"stale"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 03"*"released"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/leases/02.json" ]; [ "$(lease_json 02 pid)" = "$pid" ]
  case "$output" in *"resumed in pid $pid; rebinding instead"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/leases/04.json" ]; case "$output" in *"04"*"quiet"*"--force"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/leases/05.json" ]; case "$output" in *"window 05"*"finished"*"promote 05 or release 05"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/worktrees/01/thing" ]; [ -d "$DAEDALUS_HOME/worktrees/03/thing" ]
  run git -C "$T" rev-parse --verify -q lease/01; [ "$status" -eq 0 ]
  run LS sweep --force 04; [ "$status" -eq 0 ]; [ ! -f "$DAEDALUS_HOME/state/leases/04.json" ]
  [ -f "$DAEDALUS_HOME/state/leases/02.json" ]; [ -f "$DAEDALUS_HOME/state/leases/05.json" ]
  run LS sweep --force 05; [ ! -f "$DAEDALUS_HOME/state/leases/05.json" ]
  run LS sweep --force 02; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]     # a live session id is never removed, even forced
  case "$output" in *"window 02 is live in pid $pid"*"not removed"*"release 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run LS sweep; [ -f "$DAEDALUS_HOME/state/leases/02.json" ]; [ "$(lease_json 02 pid)" = "$pid" ]   # rebound once: now plainly live, left alone
  case "$output" in *"window 02"*) echo "a live lease should be silent: $output"; return 1 ;; *) : ;; esac
  # --force takes a NUMBER like every other lease position (§4.2, §4.1): an
  # alias is refused naming the number, a number with no lease is refused —
  # never silently ignored with exit 0.
  LS alias 02 poc-ui >/dev/null
  run LS sweep --force poc-ui; [ "$status" -ne 0 ]
  case "$output" in *"poc-ui is an alias; window 02 carries it — say \`sweep --force 02\`"*) : ;; *) echo "$output"; return 1 ;; esac
  run LS sweep --force 07; [ "$status" -ne 0 ]; case "$output" in *"There is no window 07."*) : ;; *) echo "$output"; return 1 ;; esac
  run LS sweep --force 7; [ "$status" -ne 0 ]; case "$output" in *"7 is not a window number"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/leases/02.json" ]
}

@test "spawn allocates the next free number marked spawned and launches claude --bg with DAEDALUS_LEASE and a task ending in the done instruction" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-claude" "$BATS_TEST_TMPDIR/bin/claude"; chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  export FAKE_CLAUDE_LOG="$BATS_TEST_TMPDIR/claude.log"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run LS spawn "fix the thing" --note "bg"
  [ "$status" -eq 0 ]; case "$output" in *"Window 01 is a background clone working on fix the thing"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 spawned)" = "True" ]; [ "$(lease_json 01 note)" = "bg" ]; [ "$(lease_json 01 session_id)" = "None" ]
  # The launch is detached; give the fake up to 5 s to write its record.
  for i in $(seq 1 50); do [ -s "$FAKE_CLAUDE_LOG" ] && break; sleep 0.1; done
  grep -q 'DAEDALUS_LEASE=01' "$FAKE_CLAUDE_LOG"
  grep -q -- '--bg --name daedalus-01' "$FAKE_CLAUDE_LOG"
  grep -q 'run `core/lease.sh done 01 --summary' "$FAKE_CLAUDE_LOG"
  grep -q 'ARGV: --bg --name daedalus-01 fix the thing' "$FAKE_CLAUDE_LOG"
}

@test "spawn with no claude on PATH refuses in plain words and holds no number" {
  mkdir -p "$BATS_TEST_TMPDIR/emptybin"
  PATH="$BATS_TEST_TMPDIR/emptybin:/usr/bin:/bin" run LS spawn "fix the thing"
  [ "$status" -ne 0 ]; case "$output" in *"could not start"*"claude"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/01.json" ]
}

@test "the .changed sidecar reflects committed, staged, unstaged and untracked paths per repo, keeps a path's first-seen stamp across recomputations, and drops a reverted path" {
  LS create >/dev/null
  W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'c\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am committed
  printf 's\n' > "$W/staged.txt"; git -C "$W" add staged.txt
  printf 'u\n' > "$W/untracked.txt"
  printf 'n\n' >> "$W/sub/n.txt"
  run python3 "$LL" changed 01; [ "$status" -eq 0 ]
  python3 - "$DAEDALUS_HOME/state/leases/01.changed" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert set(d["thing"])=={"a.txt","staged.txt","untracked.txt"}, d
assert set(d["thing/sub"])=={"n.txt"}, d
PY
  first="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["thing"]["a.txt"])' "$DAEDALUS_HOME/state/leases/01.changed")"
  sleep 1; printf 'again\n' >> "$W/a.txt"
  python3 "$LL" changed 01 >/dev/null
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["thing"]["a.txt"])' "$DAEDALUS_HOME/state/leases/01.changed")" = "$first" ]
  rm "$W/untracked.txt"; git -C "$W" checkout -q -- sub/n.txt 2>/dev/null || git -C "$W/sub" checkout -q -- n.txt
  python3 "$LL" changed 01 >/dev/null
  python3 - "$DAEDALUS_HOME/state/leases/01.changed" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert "untracked.txt" not in d["thing"], d; assert d.get("thing/sub",{})=={}, d
PY
}

@test "the .changed sidecar keys non-ASCII, quoted and backslashed paths literally — never git's C-quoted form — so the boundary check can match them" {
  LS create >/dev/null
  W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'x\n' > "$W/café.txt"; printf 'x\n' > "$W/say \"hi\".txt"; printf 'x\n' > "$W/back\\slash.txt"
  printf 'x\n' > "$W/naïve — dash.txt"; git -C "$W" add "naïve — dash.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m accents
  printf 'x\n' > "$W/sub/résumé.txt"
  run python3 "$LL" changed 01; [ "$status" -eq 0 ]
  python3 - "$DAEDALUS_HOME/state/leases/01.changed" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert set(d["thing"])=={"café.txt", 'say "hi".txt', "back\\slash.txt", "naïve — dash.txt"}, d
assert set(d["thing/sub"])=={"résumé.txt"}, d
PY
}

@test "a git listing that fails never empties a sidecar: the direct recompute refuses in plain words and keeps the last set; a lifecycle command keeps it, says so, and still runs" {
  LS create >/dev/null
  W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'c\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am committed
  printf 'u\n' > "$W/untracked.txt"
  python3 "$LL" changed 01 >/dev/null
  before="$(cat "$DAEDALUS_HOME/state/leases/01.changed")"
  case "$before" in *'"a.txt"'*'"untracked.txt"'*) : ;; *) echo "$before"; return 1 ;; esac
  # The trunk ref vanishes: merge-base has no answer, and "no committed work" would be a guess.
  git -C "$W" update-ref -d refs/remotes/origin/main
  run python3 "$LL" changed 01; [ "$status" -ne 0 ]
  case "$output" in *"window 01's changed set could not be recomputed"*"git merge-base origin/main HEAD failed"*"the last computed set is kept"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/leases/01.changed")" = "$before" ]
  # When git recovers, the paths carry the stamps they had before the outage.
  git -C "$W" fetch -q origin
  run python3 "$LL" changed 01; [ "$status" -eq 0 ]
  [ "$(cat "$DAEDALUS_HOME/state/leases/01.changed")" = "$before" ]
  # Every git call fails (a held index lock): `note` still records the note, names the window it could not read, and wipes nothing.
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cp "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-fail" "$BATS_TEST_TMPDIR/bin/git"; chmod +x "$BATS_TEST_TMPDIR/bin/git"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run LS note 01 x
  [ "$status" -eq 0 ]
  case "$output" in *"Noted for window 01."*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  case "$output" in *"window 01's changed set could not be recomputed"*"index.lock"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/leases/01.changed")" = "$before" ]
  [ "$(lease_json 01 note)" = "x" ]
}

@test "every lifecycle command recomputes every unswept window's sidecar, and a lease file that cannot be read stops the command before it changes anything" {
  LS create >/dev/null; LS create >/dev/null
  printf 'one\n' > "$DAEDALUS_HOME/worktrees/01/thing/one.txt"
  printf 'two\n' > "$DAEDALUS_HOME/worktrees/02/thing/two.txt"
  run LS note 01 x; [ "$status" -eq 0 ]
  python3 - "$DAEDALUS_HOME/state/leases" <<'PY'
import json,sys,os; L=sys.argv[1]
one=json.load(open(os.path.join(L,"01.changed"))); two=json.load(open(os.path.join(L,"02.changed")))
assert set(one["thing"])=={"one.txt"}, one; assert set(two["thing"])=={"two.txt"}, two
PY
  printf '{' > "$DAEDALUS_HOME/state/leases/02.json"
  run LS note 01 y; [ "$status" -eq 1 ]
  case "$output" in *"The lease file for window 02 cannot be read"*) : ;; *) echo "wrong: $output"; return 1 ;; esac
  [ "$(lease_json 01 note)" = "x" ]
}

@test "prime take: refuses a live holder without a reason, succeeds with one and appends history; a stale holder needs no reason; a take whose read session_id is stale is refused (CAS)" {
  LS create >/dev/null; LS create >/dev/null
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02; CLAUDE_CODE_SESSION_ID=sB LS claim 02 >/dev/null
  python3 "$LL" _test-write prime '{"session_id":"sA","bound_at":"2026-01-01T00:00:00","history":[]}'
  # LS is a shell function: the session id is set on the run, not through env(1).
  CLAUDE_CODE_SESSION_ID=sB run LS prime take
  [ "$status" -ne 0 ]; case "$output" in *"window 01"*"--reason"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
  tx "$(tx_path sB)" operator "the operator asked window 02 to close out the day" >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "the operator asked window 02 to close out the day"
  [ "$status" -eq 0 ]; [ "$(lease_json prime session_id)" = "sB" ]
  case "$output" in *"Window 02 holds the pen now (prime)"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==1 and h[-1]["from"]=="sA" and h[-1]["to"]=="sB" and "close out the day" in h[-1]["reason"], h' "$DAEDALUS_HOME/state/leases/prime.json"
  # The holder's process is gone: its lease reads stale, so the take needs no reason and history grows, never shrinks.
  kill "$p2"; wait "$p2" 2>/dev/null || true
  CLAUDE_CODE_SESSION_ID=sA run LS prime take; [ "$status" -eq 0 ]; [ "$(lease_json prime session_id)" = "sA" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==2 and h[0]["to"]=="sB" and h[-1]["from"]=="sB" and h[-1]["to"]=="sA", h' "$DAEDALUS_HOME/state/leases/prime.json"
  # CAS: the session_id the taker read (simulated by the test knob) is not what the file holds now.
  tx "$(tx_path sB)" operator "x" >/dev/null   # the reason check runs first and must pass; the CAS refusal is what this test sees
  CLAUDE_CODE_SESSION_ID=sB LEASE_TEST_CAS_EXPECT=sZ run LS prime take --reason x
  [ "$status" -ne 0 ]; case "$output" in *"prime\` changed under you — re-read the board"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
}

@test "prime take from a session that holds no numbered lease is refused (every prime is a window)" {
  LS create >/dev/null; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  CLAUDE_CODE_SESSION_ID=sQ run LS prime take --reason x
  [ "$status" -ne 0 ]; case "$output" in *"holds no window"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/prime.json" ]
}

@test "prime take with no prime.json (registry-absent path): a window takes the pen and the file is created with one history entry" {
  LS create >/dev/null; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  [ ! -f "$DAEDALUS_HOME/state/leases/prime.json" ]
  CLAUDE_CODE_SESSION_ID=sA run LS prime take
  [ "$status" -eq 0 ]; [ "$(lease_json prime session_id)" = "sA" ]
  case "$output" in *"Window 01 holds the pen now (prime)"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==1 and h[0]["from"] is None and h[0]["to"]=="sA", h' "$DAEDALUS_HOME/state/leases/prime.json"
}

@test "prime take refuses while the registry shows the taker's session id in two terminals, even with a reason; prime.json is unchanged (§4.5 names prime take beside claim)" {
  LS create >/dev/null; LS create >/dev/null
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02; CLAUDE_CODE_SESSION_ID=sB LS claim 02 >/dev/null
  python3 "$LL" _test-write prime '{"session_id":"sA","bound_at":"2026-01-01T00:00:00","history":[]}'
  p3="$(live_pid)"; registry_entry "$p3" sB interactive cli daedalus-02     # the same session id, open in a second terminal
  run python3 "$LL" registry-live-pids sB; [ "$(printf '%s\n' $output | wc -l | tr -d ' ')" -eq 2 ]
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "hand it over"
  [ "$status" -ne 0 ]; case "$output" in *"open in two terminals at once (pids"*"close one"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert h==[], h' "$DAEDALUS_HOME/state/leases/prime.json"
}

@test "prime take over a holder that is live in the registry but holds only the pen (released its number, §4.4) needs --reason like any live holder; 'previous holder gone' is recorded only when neither a live lease nor a live registry entry exists" {
  LS create >/dev/null
  pa="$(live_pid)"; registry_entry "$pa" sA interactive cli daedalus-01
  python3 "$LL" _test-write prime '{"session_id":"sA","bound_at":"2026-01-01T00:00:00","history":[]}'
  pb="$(live_pid)"; registry_entry "$pb" sB interactive cli daedalus-02; CLAUDE_CODE_SESSION_ID=sB LS claim 01 >/dev/null
  run python3 "$LL" registry-live-pids sA; [ "$output" = "$pa" ]
  CLAUDE_CODE_SESSION_ID=sB run LS prime take
  [ "$status" -ne 0 ]; case "$output" in *"held by a live session"*"holds no window"*"daedalus-01"*"--reason"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
  tx "$(tx_path sB)" operator "the operator asked for the pen" >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "the operator asked for the pen"
  [ "$status" -eq 0 ]; [ "$(lease_json prime session_id)" = "sB" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert len(h)==1 and h[0]["from"]=="sA" and "asked for the pen" in h[0]["reason"], h' "$DAEDALUS_HOME/state/leases/prime.json"
  # Now the prime-only holder's process is gone: no lease, no live registry entry — the take needs no reason.
  python3 "$LL" _test-write prime '{"session_id":"sA","bound_at":"2026-01-01T00:00:00","history":[]}'
  kill "$pa"; wait "$pa" 2>/dev/null || true
  CLAUDE_CODE_SESSION_ID=sB run LS prime take; [ "$status" -eq 0 ]; [ "$(lease_json prime session_id)" = "sB" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"]; assert h[-1]["reason"]=="previous holder gone", h' "$DAEDALUS_HOME/state/leases/prime.json"
}

@test "a visitor (DIRECT_CALL_ID set) never creates, claims, spawns, changes or sweeps a window and cannot take the pen: each refused in plain words before anything is written; list still works" {
  # A claude that only leaves a mark: if `spawn` ever dropped out of the
  # refused list, this test must not start a real `claude --bg` (leaselib's
  # spawn() runs `claude` from PATH).
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\n: > "%s/claude-ran"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  LS create >/dev/null                        # window 01, unbound, made from an operator shell
  snap() { ( cd "$DAEDALUS_HOME/state/leases" && ls -A | sort && cat ./*.json ./*.changed 2>/dev/null ) | shasum; }
  before="$(snap)"
  for args in "create" "claim 01" "spawn do-a-thing" "prime take" "alias 01 poc" "note 01 x" "update 01 --criteria c.md" "release 01" "done 01 --summary s" "sweep"; do
    DIRECT_CALL_ID=call-1 CLAUDE_CODE_SESSION_ID=sV run LS $args
    [ "$status" -eq 1 ] || { echo "$args -> status $status: $output"; return 1; }
    case "$output" in
      *"This is a direct-call session (a visitor): it never creates, claims or changes a window and cannot take the pen."*"core/lease.sh ${args%% *}"*) : ;;
      *) echo "$args: $output"; return 1 ;;
    esac
  done
  [ "$(snap)" = "$before" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-ran" ] || { echo "a claude was started"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]; [ ! -e "$DAEDALUS_HOME/state/leases/prime.json" ]
  DIRECT_CALL_ID=call-1 CLAUDE_CODE_SESSION_ID=sV run LS list
  [ "$status" -eq 0 ]
}

# fake_git '<bash snippet>' — a git on $BATS_TEST_TMPDIR/bin that runs the
# snippet (it sees "$@" and $real, the real git) and then the real git. Put
# the directory first on PATH for the command under test only.
fake_git() {
  local real; real="$(command -v git)"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  { printf '#!/usr/bin/env bash\nreal=%q\n' "$real"; printf '%s\n' "$1"; printf 'exec "$real" "$@"\n'; } > "$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
}

@test "add_worktrees recomputes what is left before every git call: with prune and rev-parse taking 3 s each and 4 s left, it stops after the prune instead of running rev-parse on a stale timeout" {
  # Review reproduction of the first draft: `left` computed once per repo and
  # reused for prune, list, remove and rev-parse returned after 6.0 s against
  # a deadline 4.0 s away — at production values, prune 20 s + rev-parse 20 s.
  fake_git 'case " $* " in *" prune "*|*" rev-parse "*) sleep 3 ;; esac'
  run python3 - "$DAEDALUS_HOME/core" "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR/bin" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1])
import leaselib as ll
from pathlib import Path
root = Path(sys.argv[2])
trunks = ll.trunks_of(root, root / "target")          # with the real git
os.environ["PATH"] = sys.argv[3] + os.pathsep + os.environ["PATH"]
t0 = time.time()
ok = ll.add_worktrees(root, "07", trunks, timeout=20, deadline=t0 + 4)
took = time.time() - t0
print("returned %s after %.1f s" % (ok, took))
assert ok is False and took < 4.5, (ok, took)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a git add cut off at its timeout takes its whole process group with it: the checkout child it started does not keep writing" {
  # git worktree add checks out through a child (git reset --hard); v.run
  # killed only the parent and the child kept writing the tree (review,
  # git 2.50.1). The fake add starts a writer child, records its pid, and hangs.
  mkdir -p "$BATS_TEST_TMPDIR/w"
  fake_git 'case " $* " in *" worktree add "*)
  ( while :; do : > "$FAKE_W/f.$RANDOM"; sleep 0.1; done ) &
  printf "%s\n" "$!" > "$FAKE_W/child.pid"
  sleep 30
  exit 0 ;;
esac'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_W="$BATS_TEST_TMPDIR/w" LEASE_WORKTREE_TIMEOUT=1 run LS create
  child="$(cat "$BATS_TEST_TMPDIR/w/child.pid")"
  sleep 0.5
  if kill -0 "$child" 2>/dev/null; then kill "$child"; echo "the checkout child $child outlived the timeout"; return 1; fi
  [ "$(lease_json 01 worktree_ready)" = "False" ]
}

@test "an add interrupted mid-checkout (registered, locked 'initializing', half-written) whose add is no longer running is removed and re-added from its branch by claim at once, a fresh index.lock notwithstanding — never adopted as it stands" {
  # Measured 2026-09-27 (git 2.50.1): a worktree add killed mid-checkout leaves
  # the worktree registered, locked with reason "initializing", its branch
  # created, and a tree whose status lists every file deleted. Plan 1 adopted
  # any registered worktree and fast-forwarded it.
  LS create >/dev/null
  wt="$DAEDALUS_HOME/worktrees/01/thing"
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)"
  printf 'initializing\n' > "$gd/locked"; rm -f "$wt/a.txt" "$gd/index"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["worktree_ready"]=False; open(p,"w").write(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json"
  : > "$gd/index.lock"      # left by the killed checkout; no `worktree add` process is alive, so nothing is writing
  CLAUDE_CODE_SESSION_ID=sC run LS claim 01
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$wt/a.txt" ]
  [ -f "$wt/sub/n.txt" ]      # the nested worktree lives inside the outer one; remove -f -f took it, the nested pass re-adds it
  run git -C "$DAEDALUS_HOME/target/thing" worktree list --porcelain
  case "$output" in *"locked initializing"*) echo "still locked: $output"; return 1 ;; *) : ;; esac
  [ -z "$(git -C "$wt" status --porcelain)" ]
  [ "$(lease_json 01 worktree_ready)" = "None" ]
}

# slow_checkout — commit slow.txt to the target under a smudge filter that
# sleeps $SLOW_SMUDGE seconds (default 0), so a `worktree add` spends that
# long mid-checkout — its index.lock held, its tree half-written — in a
# grandchild of the add, in the add's own process group. One file stands in
# for the 40k-file repo the review measured on.
slow_checkout() {
  local T="$DAEDALUS_HOME/target/thing"
  git -C "$T" config filter.slow.smudge 'sleep "${SLOW_SMUDGE:-0}"; cat'
  git -C "$T" config filter.slow.clean cat
  printf 'slow.txt filter=slow\n' > "$T/.gitattributes"; printf 's\n' > "$T/slow.txt"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m slow; git -C "$T" push -q origin main
}

@test "a checkout Daedalus cut off at its own budget is dead, not still writing: an immediate claim removes the half-written tree and re-adds it, with no minute's wait" {
  # Review reproduction (git 2.50.1): the kill leaves the worktree's index.lock
  # behind, and plan 2's lock-age test refused this claim for up to 60 s with
  # "still being checked out" although no git process was alive.
  slow_checkout
  SLOW_SMUDGE=5 LEASE_WORKTREE_TIMEOUT=1 run LS create
  [ "$status" -eq 0 ]; [ "$(lease_json 01 worktree_ready)" = "False" ]
  wt="$DAEDALUS_HOME/worktrees/01/thing"
  run git -C "$DAEDALUS_HOME/target/thing" worktree list --porcelain
  case "$output" in *"locked initializing"*) : ;; *) echo "the add was not cut off mid-checkout: $output"; return 1 ;; esac
  ls "$DAEDALUS_HOME/target/thing/.git/worktrees/thing/index.lock"     # the orphaned lock is there
  CLAUDE_CODE_SESSION_ID=sC run LS claim 01
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$wt/slow.txt" ]; [ -f "$wt/a.txt" ]; [ -f "$wt/sub/n.txt" ]
  [ -z "$(git -C "$wt" status --porcelain)" ]
  [ "$(lease_json 01 worktree_ready)" = "None" ]
}

@test "an add whose caller was SIGKILLed keeps checking out in its own session: claim refuses while that add is alive, however old its index.lock, and finishes the window once it is gone" {
  # The lock's mtime is set when the checkout opens it and does not move until
  # the index is written at the end (measured 2026-09-28, git 2.50.1), so a
  # lock-age test called a checkout longer than 60 s dead under its writer.
  slow_checkout
  wt="$DAEDALUS_HOME/worktrees/01/thing"; gd="$DAEDALUS_HOME/target/thing/.git/worktrees/thing"
  SLOW_SMUDGE=30 LEASE_WORKTREE_TIMEOUT=60 bash "$DAEDALUS_HOME/core/lease.sh" create </dev/null >/dev/null 2>&1 3>&- &
  caller=$!
  for _ in $(seq 50); do [ -e "$gd/index.lock" ] && break; sleep 0.1; done
  [ -e "$gd/index.lock" ] || { kill -KILL "$caller"; echo "the checkout never started"; return 1; }
  kill -KILL "$caller"; wait "$caller" 2>/dev/null || true
  adder="$(pgrep -f "worktree add $wt " | head -1)"
  [ -n "$adder" ] || { echo "the add died with its caller"; return 1; }
  touch -t 200001010000 "$gd/index.lock"      # a lock-age test would call this writer long gone
  CLAUDE_CODE_SESSION_ID=sC run LS claim 01
  st=$status; out=$output
  kill -KILL -- "-$adder" 2>/dev/null; for _ in $(seq 50); do kill -0 "$adder" 2>/dev/null || break; sleep 0.1; done
  [ "$st" -ne 0 ] || { echo "claimed under a live add: $out"; return 1; }
  case "$out" in *"window 01 is still being checked out"*) : ;; *) echo "$out"; return 1 ;; esac
  [ -d "$wt" ]
  CLAUDE_CODE_SESSION_ID=sC run LS claim 01
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$wt/slow.txt" ]; [ -f "$wt/sub/n.txt" ]; [ -z "$(git -C "$wt" status --porcelain)" ]
}

@test "when git deregisters a half-finished worktree but cannot delete its directory, claim deletes the leftover itself and re-adds" {
  # Review reproduction: `remove -f -f` under a live checkout exits 255
  # "Directory not empty" AFTER deregistering the worktree; every later add
  # then refused "exists but is not a worktree". The fake remove does the real
  # remove, then leaves a file behind and fails the same way.
  LS create >/dev/null
  wt="$DAEDALUS_HOME/worktrees/01/thing"
  gd="$(git -C "$wt" rev-parse --absolute-git-dir)"
  printf 'initializing\n' > "$gd/locked"; rm -f "$wt/a.txt" "$gd/index"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["worktree_ready"]=False; open(p,"w").write(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json"
  fake_git 'case " $* " in *" worktree remove "*)
  "$real" "$@"
  mkdir -p "$FAKE_DEST" && : > "$FAKE_DEST/straggler"
  echo "error: failed to delete: Directory not empty" >&2
  exit 255 ;;
esac'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FAKE_DEST="$wt" CLAUDE_CODE_SESSION_ID=sC run LS claim 01
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$wt/a.txt" ]; [ ! -e "$wt/straggler" ]
  [ -z "$(git -C "$wt" status --porcelain)" ]
  [ "$(lease_json 01 worktree_ready)" = "None" ]
}

@test "claim of a number with no lease file whose add is cut off leaves the window worktree_ready false — never ready over a missing tree" {
  # Plan 1's claim discarded add_worktrees' False on this path (leaselib.py
  # :805-808): the lease was written ready while its tree was missing, and
  # nothing ever finished it. This task makes False more common. 127 is what
  # _run_bounded reports for a git call cut off at its timeout.
  fake_git 'case " $* " in *" worktree add "*) exit 127 ;; esac'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" CLAUDE_CODE_SESSION_ID=sF run LS claim 01
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(lease_json 01 worktree_ready)" = "False" ] || { cat "$DAEDALUS_HOME/state/leases/01.json"; return 1; }
  [ ! -e "$DAEDALUS_HOME/worktrees/01/thing/a.txt" ]
}

# two_windows_prime_01 — windows 01 (sA, holds the pen) and 02 (sB), both live.
two_windows_prime_01() {
  LS create >/dev/null; LS create >/dev/null
  p1="$(live_pid)"; registry_entry "$p1" sA interactive cli daedalus-01; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  p2="$(live_pid)"; registry_entry "$p2" sB interactive cli daedalus-02; CLAUDE_CODE_SESSION_ID=sB LS claim 02 >/dev/null
  python3 "$LL" _test-write prime "{\"session_id\":\"sA\",\"bound_at\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"bound_epoch\":$(now),\"history\":[]}"
  sleep 1   # every transcript entry below is clearly after the holder's bound_epoch
}

@test "prime take --reason over a live holder (transcribed): words not in the taker's transcript, or typed before the holder's bound_at, or only in a tool result, are refused and the pen does not move; typed after, the take records the transcript entry" {
  two_windows_prime_01; X="$(tx_path sB)"
  tx "$X" operator "something else entirely" >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "hand the pen to window 02"
  [ "$status" -ne 0 ]; case "$output" in *"I could not find those words as something the operator typed in this window since the pen was last taken. The pen did not move."*) : ;; *) echo "$output"; return 1 ;; esac
  tx "$X" operator "hand the pen to window 02" "$(plus "$(now)" -3600)" >/dev/null
  tx "$X" tool-result "hand the pen to window 02" >/dev/null
  tx "$X" operator "please do not hand the pen to window 02 yet" >/dev/null   # a fragment of a longer turn is not the words (Decision 30)
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "hand the pen to window 02"
  [ "$status" -ne 0 ]; [ "$(lease_json prime session_id)" = "sA" ]
  said="$(tx "$X" operator "Hand the pen to window 02.")"
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "hand the pen to window 02"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }; [ "$(lease_json prime session_id)" = "sB" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"][-1]; assert h["transcript_ref"]["uuid"]==sys.argv[2] and h["reason"]=="hand the pen to window 02", h' "$DAEDALUS_HOME/state/leases/prime.json" "$said"
}

@test "prime take --reason (transcribed): an unreadable transcript is refused naming promote.confirm: tty; a missing one names memory.transcript_dir; one outside every protected directory is not evidence; a stale holder needs no reason and no transcript" {
  two_windows_prime_01; X="$(tx_path sB)"
  tx "$X" operator "take it" >/dev/null; tx "$X" malformed "x" >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "take it"
  [ "$status" -ne 0 ]; case "$output" in *"I cannot read this build's transcript format ("*"The pen did not move."*"promote.confirm: tty"*) : ;; *) echo "$output"; return 1 ;; esac
  rm -f "$X"
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "take it"
  [ "$status" -ne 0 ]; case "$output" in *"I cannot find this window's transcript ("*"memory.transcript_dir"*) : ;; *) echo "$output"; return 1 ;; esac
  # Decision 36: a marker pointing at a transcript nothing protects is not evidence, even when the words are in it.
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"; tx "$BATS_TEST_TMPDIR/elsewhere/sB.jsonl" operator "take it" >/dev/null
  printf '{"session_id":"sB","transcript_path":"%s"}' "$BATS_TEST_TMPDIR/elsewhere/sB.jsonl" > "$DAEDALUS_HOME/state/session-sB.json"
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "take it"
  [ "$status" -ne 0 ]; case "$output" in *"is outside every directory nothing may write, so it is not evidence"*"The pen did not move."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
  kill "$p1"; wait "$p1" 2>/dev/null || true
  CLAUDE_CODE_SESSION_ID=sB run LS prime take; [ "$status" -eq 0 ]; [ "$(lease_json prime session_id)" = "sB" ]
}

@test "prime take in tty mode: --reason is refused; with no terminal the refusal hands over a paste line carrying the taker's session id; typed at a terminal, the take records that it was typed" {
  two_windows_prime_01
  printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "x"
  [ "$status" -ne 0 ]; case "$output" in *"typed in a terminal, not passed as --reason"*) : ;; *) echo "$output"; return 1 ;; esac
  run no_tty env CLAUDE_CODE_SESSION_ID=sB bash "$DAEDALUS_HOME/core/lease.sh" prime take
  [ "$status" -ne 0 ]; case "$output" in *"must be typed by a person in a terminal"*"cd $DAEDALUS_HOME && DAEDALUS_SESSION_ID=sB core/lease.sh prime take"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json prime session_id)" = "sA" ]
  run type_into "the operator wants window 02 to hold it" "the operator's words" env DAEDALUS_SESSION_ID=sB bash "$DAEDALUS_HOME/core/lease.sh" prime take
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }; [ "$(lease_json prime session_id)" = "sB" ]
  python3 -c 'import json,sys; h=json.load(open(sys.argv[1]))["history"][-1]; assert h["reason_typed_at_terminal"] is True and "window 02 to hold it" in h["reason"], h' "$DAEDALUS_HOME/state/leases/prime.json"
}

# The cut-off is an absolute instant (bound_epoch), never a local stamp the
# taker's own process parses: TZ is the taker's to set, and a zone-less
# bound_at read under TZ=Etc/GMT-14 lands ~19 hours early (Task 3 review).
@test "prime take --reason (transcribed): the taker's TZ does not move the cut-off — words typed before the holder took the pen stay refused under TZ=Etc/GMT-14 and TZ=XXX-24" {
  export TZ=America/Chicago
  two_windows_prime_01; X="$(tx_path sB)"
  tx "$X" operator "old words from this morning" "$(plus "$(now)" -36000)" >/dev/null
  for zone in Etc/GMT-14 XXX-24; do
    TZ="$zone" CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "old words from this morning"
    [ "$status" -ne 0 ] || { echo "$zone: $output"; return 1; }
    case "$output" in *"I could not find those words as something the operator typed in this window since the pen was last taken. The pen did not move."*) : ;; *) echo "$zone: $output"; return 1 ;; esac
    [ "$(lease_json prime session_id)" = "sA" ]
  done
}

@test "prime take --reason (transcribed): a take made under a shifted TZ does not write a future cut-off — the next live-holder take with words typed after it goes through" {
  export TZ=America/Chicago
  two_windows_prime_01; XB="$(tx_path sB)"; XA="$(tx_path sA)"
  tx "$XB" operator "window 02 takes the pen" >/dev/null
  TZ=Etc/GMT-14 CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "window 02 takes the pen"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }; [ "$(lease_json prime session_id)" = "sB" ]
  sleep 1
  tx "$XA" operator "window 01 takes it back" >/dev/null
  CLAUDE_CODE_SESSION_ID=sA run LS prime take --reason "window 01 takes it back"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }; [ "$(lease_json prime session_id)" = "sA" ]
  python3 -c 'import json,sys,time; d=json.load(open(sys.argv[1])); assert abs(d["bound_epoch"]-time.time())<60, d' "$DAEDALUS_HOME/state/leases/prime.json"
}

@test "prime take --reason (transcribed): a prime.json from an older build with no bound_epoch is cut off at the file's own modification time, not its local stamp" {
  export TZ=America/Chicago
  two_windows_prime_01; X="$(tx_path sB)"
  python3 "$LL" _test-write prime "{\"session_id\":\"sA\",\"bound_at\":\"$(date +%Y-%m-%dT%H:%M:%S)\",\"history\":[]}"
  sleep 1
  tx "$X" operator "old words from this morning" "$(plus "$(now)" -36000)" >/dev/null
  TZ=Etc/GMT-14 CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "old words from this morning"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }; [ "$(lease_json prime session_id)" = "sA" ]
  tx "$X" operator "new words after the pen was taken" >/dev/null
  TZ=Etc/GMT-14 CLAUDE_CODE_SESSION_ID=sB run LS prime take --reason "new words after the pen was taken"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }; [ "$(lease_json prime session_id)" = "sB" ]
}

@test "rebase: a clean lease fast-forwards onto a moved trunk; a lease with commits has them replayed onto it, subjects kept" {
  LS create >/dev/null; W="$DAEDALUS_HOME/worktrees/01/thing"
  # The move is not fetched into target/thing: only rebase's own fetch (§7.1 step 4) brings it.
  TRUNK_MOVES_NO_FETCH=1 trunk_moves b.txt "trunk moved"
  run LS rebase 01; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 is up to date with trunk (thing fast-forwarded to origin/main; thing/sub already up to date). Run core/gates.sh before asking for promote."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$T" rev-parse origin/main)" ]
  printf 'mine\n' > "$W/c.txt"; git -C "$W" add -A; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m "window work"
  TRUNK_MOVES_NO_FETCH=1 trunk_moves b.txt "trunk again"
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x run LS rebase 01; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"thing: 1 commit replayed onto origin/main"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W" rev-parse HEAD^)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$W" log -1 --format=%s)" = "window work" ]
}

@test "rebase: a nested repo whose trunk moved is fast-forwarded too; a conflict there names thing/sub and its path" {
  LS create >/dev/null; S="$DAEDALUS_HOME/worktrees/01/thing/sub"
  TRUNK_MOVES_NO_FETCH=1 sub_moves m.txt "sub trunk moved"
  run LS rebase 01; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 is up to date with trunk (thing already up to date; thing/sub fast-forwarded to origin/main)."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$S" rev-parse HEAD)" = "$(git -C "$T/sub" rev-parse origin/main)" ]
  [ -f "$S/m.txt" ]
  printf 'window line\n' >> "$S/n.txt"; git -C "$S" -c user.email=t@x -c user.name=t commit -q -am "window edits n.txt"
  TRUNK_MOVES_NO_FETCH=1 sub_moves n.txt "sub trunk edits n.txt"
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"Window 01's rebase stopped on a conflict in thing/sub: n.txt. Resolve it in worktrees/01/thing/sub,"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "rebase: an origin that cannot be fetched stops before any worktree moves, naming the repo, exit non-zero" {
  LS create >/dev/null; W="$DAEDALUS_HOME/worktrees/01/thing"; before="$(git -C "$W" rev-parse HEAD)"
  git -C "$T" remote set-url origin "$BATS_TEST_TMPDIR/no-such-origin.git"
  run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"could not fetch origin in target/thing ("*"); window 01 was not rebased"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W" rev-parse HEAD)" = "$before" ]
}

@test "rebase never calls a window up to date when it cannot tell: a missing worktree, an unfinished one, and a trunk git cannot count against are refused" {
  LS create >/dev/null
  mv "$DAEDALUS_HOME/worktrees/01/thing/sub" "$BATS_TEST_TMPDIR/sub-away"
  run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"worktrees/01/thing/sub is missing; run \`core/lease.sh claim 01\` to finish window 01's worktree, then rebase"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"up to date"*) echo "$output"; return 1 ;; esac
  mv "$BATS_TEST_TMPDIR/sub-away" "$DAEDALUS_HOME/worktrees/01/thing/sub"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["worktree_ready"]=False; json.dump(d,open(p,"w"))' "$DAEDALUS_HOME/state/leases/01.json"
  run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"window 01's worktree was not finished at start; run \`core/lease.sh claim 01\` to finish it"*) : ;; *) echo "$output"; return 1 ;; esac
  # The nested repo's trunk is the unknown one while the outer's has moved:
  # the refusal comes before the outer worktree is touched.
  W="$DAEDALUS_HOME/worktrees/01/thing"; before="$(git -C "$W" rev-parse HEAD)"; trunk_moves b.txt "trunk moved"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("worktree_ready"); d["trunks"]={"thing":"main","thing/sub":"nosuch"}; json.dump(d,open(p,"w"))' "$DAEDALUS_HOME/state/leases/01.json"
  run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"cannot tell whether worktrees/01/thing/sub is behind origin/nosuch ("*"); window 01 was not rebased"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"up to date"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W" rev-parse HEAD)" = "$before" ]
}

@test "rebase: a conflict stops with the path named and a non-zero exit, and the worktree is left mid-rebase for the window to resolve" {
  LS create >/dev/null; W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'window line\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "window edits a.txt"
  trunk_moves a.txt "trunk edits a.txt"
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"Window 01's rebase stopped on a conflict in thing: a.txt. Resolve it in worktrees/01/thing, \`git add\` the file, then \`git rebase --continue\`; run core/gates.sh when it finishes."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$(git -C "$W" rev-parse --git-path rebase-merge)" ] || [ -d "$(git -C "$W" rev-parse --git-path rebase-apply)" ]
}

@test "rebase refuses uncommitted work (naming it), another live window's lease (naming its peer), an alias (naming the number) and a visitor" {
  LS create >/dev/null; W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'dirty\n' >> "$W/a.txt"
  run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"Window 01 has uncommitted changes in worktrees/01/thing (a.txt). Commit them on lease/01 first; rebase moves commits only."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W" checkout -q -- a.txt
  p="$(live_pid)"; registry_entry "$p" sA interactive cli daedalus-01; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  CLAUDE_CODE_SESSION_ID=sZ run LS rebase 01; [ "$status" -ne 0 ]
  case "$output" in *"Window 01 is held by a live session (peer name daedalus-01)"*) : ;; *) echo "$output"; return 1 ;; esac
  CLAUDE_CODE_SESSION_ID=sA LS alias 01 poc >/dev/null
  run LS rebase poc; [ "$status" -ne 0 ]; case "$output" in *"poc is an alias; window 01 carries it — say \`rebase 01\`"*) : ;; *) echo "$output"; return 1 ;; esac
  DIRECT_CALL_ID=x run LS rebase 01; [ "$status" -ne 0 ]; case "$output" in *"(a visitor)"*"core/lease.sh rebase"*) : ;; *) echo "$output"; return 1 ;; esac
}

# window_02_both_repos — windows 01 and 02; window 02 has one commit in thing and two in thing/sub.
window_02_both_repos() {
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  LS create >/dev/null; LS create >/dev/null
  W="$DAEDALUS_HOME/worktrees/02/thing"
  printf 'o\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "outer work"
  printf 'n1\n' >> "$W/sub/n.txt"; git -C "$W/sub" -c user.email=t@x -c user.name=t commit -q -am "nested one"
  printf 'n2\n' >> "$W/sub/n.txt"; git -C "$W/sub" -c user.email=t@x -c user.name=t commit -q -am "nested two"
}

@test "split: window 02's nested-repo commits move to a new window with no session, window 02 keeps its outer commits, the old nested tip is kept under refs/daedalus/split/ until release --remove, both lease files record it" {
  window_02_both_repos; old="$(git -C "$W/sub" rev-parse HEAD)"
  run LS split 02 --repo sub; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 03 now holds window 02's commits in thing/sub (2: \"nested one\", \"nested two\"); window 02 keeps its other commits."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "${lines[${#lines[@]}-1]}" = "03" ]
  N="$DAEDALUS_HOME/worktrees/03/thing/sub"
  [ "$(git -C "$N" log --format=%s -2 | tr '\n' '|')" = "nested two|nested one|" ]
  [ "$(git -C "$N" rev-parse HEAD~2)" = "$(git -C "$T/sub" rev-parse origin/main)" ]
  [ "$(git -C "$W/sub" rev-parse HEAD)" = "$(git -C "$T/sub" rev-parse origin/main)" ]
  [ "$(git -C "$W" log -1 --format=%s)" = "outer work" ]
  ref="$(git -C "$T/sub" for-each-ref --format='%(refname)' 'refs/daedalus/split/02-*')"; [ -n "$ref" ]
  [ "$(git -C "$T/sub" rev-parse "$ref")" = "$old" ]
  [ "$(lease_json 03 session_id)" = "None" ]
  python3 - "$DAEDALUS_HOME/state/leases" "$ref" <<'PY'
import json, sys
d = sys.argv[1]; a = json.load(open(d + "/02.json")); b = json.load(open(d + "/03.json"))
t = a["split_to"][-1]
assert t["lease"] == "03" and t["repo"] == "thing/sub" and t["commits"] == 2 and t["kept"] == sys.argv[2], a
assert b["split_from"]["lease"] == "02" and b["split_from"]["repo"] == "thing/sub", b
PY
  run LS release 02 --remove --force; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(git -C "$T/sub" for-each-ref --format='%(refname)' 'refs/daedalus/split/02-*')" ]
}

@test "split refuses: a repo that is not one of the window's nested repos, a nested repo with nothing to split, uncommitted work, another live window's lease, an alias — and allocates nothing" {
  window_02_both_repos
  run LS split 02 --repo other; [ "$status" -ne 0 ]; case "$output" in *"Window 02 has no nested repo other"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W/sub" reset -q --hard origin/main
  run LS split 02 --repo sub; [ "$status" -ne 0 ]; case "$output" in *"Window 02 has no commits in thing/sub that are not already on main; nothing to split."*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'n3\n' >> "$W/sub/n.txt"; git -C "$W/sub" -c user.email=t@x -c user.name=t commit -q -am "nested three"
  printf 'dirty\n' >> "$W/a.txt"
  run LS split 02 --repo sub; [ "$status" -ne 0 ]; case "$output" in *"Window 02 has uncommitted changes in worktrees/02/thing (a.txt). Commit them first; split moves commits only."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W" checkout -q -- a.txt
  p="$(live_pid)"; registry_entry "$p" sB interactive cli daedalus-02; CLAUDE_CODE_SESSION_ID=sB LS claim 02 >/dev/null
  CLAUDE_CODE_SESSION_ID=sZ run LS split 02 --repo sub; [ "$status" -ne 0 ]; case "$output" in *"held by a live session (peer name daedalus-02)"*) : ;; *) echo "$output"; return 1 ;; esac
  CLAUDE_CODE_SESSION_ID=sB LS alias 02 poc >/dev/null
  CLAUDE_CODE_SESSION_ID=sB run LS split poc --repo sub; [ "$status" -ne 0 ]; case "$output" in *"poc is an alias; window 02 carries it — say \`split 02\`"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]
}

@test "split: nested commits that do not apply onto the moved trunk roll the new window back — no lease file, worktree or branch — and window 02 is unchanged; a visitor is refused" {
  window_02_both_repos; before="$(git -C "$W/sub" rev-parse HEAD)"
  # The move is not fetched into target/thing/sub: only split's own fetch brings it.
  TRUNK_MOVES_NO_FETCH=1 sub_moves n.txt "sub trunk edits n.txt"
  run LS split 02 --repo sub; [ "$status" -ne 0 ]
  case "$output" in *"Window 02's commits in thing/sub do not apply cleanly onto current main"*"nothing was split. Run \`core/lease.sh rebase 02\` first, then split again."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]; [ ! -e "$DAEDALUS_HOME/worktrees/03/thing" ]
  ! git -C "$T" rev-parse --verify -q lease/03 >/dev/null
  ! git -C "$T/sub" rev-parse --verify -q lease/03 >/dev/null
  [ "$(git -C "$W/sub" rev-parse HEAD)" = "$before" ]
  [ -z "$(git -C "$T/sub" for-each-ref --format='%(refname)' 'refs/daedalus/split/')" ]
  [ "$(python3 -c 'import json,sys; print("split_to" in json.load(open(sys.argv[1])))' "$DAEDALUS_HOME/state/leases/02.json")" = "False" ]
  DIRECT_CALL_ID=x run LS split 02 --repo sub; [ "$status" -ne 0 ]; case "$output" in *"(a visitor)"*"core/lease.sh split"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "split refuses a nested worktree that is not on lease/<NN> — a detached HEAD, or a rebase stopped on a conflict and resolved with nothing left to commit — naming the state, and leaves lease/02's commits where they were" {
  window_02_both_repos; tip="$(git -C "$T/sub" rev-parse lease/02)"
  git -C "$W/sub" checkout -q --detach HEAD
  run LS split 02 --repo sub; [ "$status" -ne 0 ]
  case "$output" in *"worktrees/02/thing/sub is not on branch lease/02 (its HEAD is detached)"*"git checkout lease/02"*"then split"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]; [ "$(git -C "$T/sub" rev-parse lease/02)" = "$tip" ]
  git -C "$W/sub" checkout -q lease/02
  # A rebase that stops on a conflict, resolved by keeping trunk's side: the
  # worktree is mid-rebase with a detached HEAD and `git status` shows nothing.
  sub_moves n.txt "sub trunk edits n.txt"
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x run LS rebase 02; [ "$status" -ne 0 ]
  git -C "$W/sub" checkout -q --ours n.txt; git -C "$W/sub" add n.txt
  [ -z "$(git -C "$W/sub" status --porcelain)" ]
  run LS split 02 --repo sub; [ "$status" -ne 0 ]
  case "$output" in *"worktrees/02/thing/sub is in the middle of a rebase"*"git rebase --continue"*"git rebase --abort"*"then split"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]; [ "$(git -C "$T/sub" rev-parse lease/02)" = "$tip" ]
  [ -z "$(git -C "$T/sub" for-each-ref --format='%(refname)' 'refs/daedalus/split/')" ]
}

@test "split fetches with the lease lock free: a Bash or Edit|Write check in another window is never held behind split's network fetch; what changed during the fetch is checked again under the lock" {
  window_02_both_repos
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/git" <<'SH'
#!/usr/bin/env bash
# On `fetch`, record whether the lease lock can be taken exclusively right now
# (free) or not (held), then run the real git.
self="$(cd "$(dirname "$0")" && pwd -P)"; real=""
IFS=: ; for d in $PATH; do [ -n "$d" ] || continue; [ "$(cd "$d" 2>/dev/null && pwd -P)" = "$self" ] && continue
  if [ -x "$d/git" ]; then real="$d/git"; break; fi; done; unset IFS
for a in "$@"; do if [ "$a" = fetch ]; then
  python3 -c 'import fcntl,os,sys
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o644)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); print("free")
except BlockingIOError:
    print("held")' "$DAEDALUS_HOME/state/leases/.lock" >> "$FETCH_PROBE"
  [ -z "${FETCH_DIRTIES:-}" ] || printf 'during fetch\n' >> "$FETCH_DIRTIES"; break; fi; done
exec "$real" "$@"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  # The window edits a file while split fetches: the check under the lock sees it.
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FETCH_PROBE="$BATS_TEST_TMPDIR/probe" FETCH_DIRTIES="$W/a.txt" run LS split 02 --repo sub
  [ "$status" -ne 0 ]; case "$output" in *"Window 02 has uncommitted changes in worktrees/02/thing (a.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]
  git -C "$W" checkout -q -- a.txt
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" FETCH_PROBE="$BATS_TEST_TMPDIR/probe" run LS split 02 --repo sub
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -s "$BATS_TEST_TMPDIR/probe" ]
  ! grep -q held "$BATS_TEST_TMPDIR/probe" || { cat "$BATS_TEST_TMPDIR/probe"; return 1; }
}

# --- adopt (spec §4.2, §14 step 6; plan 5 Task 2) -----------------------------

cmt() { git -C "$1" -c user.email=t@x -c user.name=t commit -q "${@:2}"; }
on_feat() {   # on_feat <repo dir> <branch> <n> — n commits on a new branch, checked out
  git -C "$1" checkout -q -b "$2"
  local i f; f="f-$(printf '%s' "$2" | tr / -).txt"     # a branch name may hold a slash; a file name may not
  for i in $(seq 1 "$3"); do printf '%s %s\n' "$2" "$i" >> "$1/$f"; git -C "$1" add -A; cmt "$1" -m "$2 work $i"; done
}

@test "adopt: a branch checked out in target/thing with two commits past trunk becomes window 01 — target/thing back on main at origin/main, the branch renamed lease/01 and checked out at worktrees/01/thing, the nested repo at its trunk, the lease file carrying adopted_from, the board naming it" {
  on_feat "$T" feat/x 2
  tip="$(git -C "$T" rev-parse feat/x)"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x --note "the old branch"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds feat/x from target/thing (2 commits: \"feat/x work 1\", \"feat/x work 2\") on branch lease/01; target/thing is on main at origin/main."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"DAEDALUS_LEASE=01"*) : ;; *) echo "no launch line: $output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/feat/x >/dev/null
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" branch --show-current)" = lease/01 ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing/sub" rev-parse HEAD)" = "$(git -C "$T/sub" rev-parse origin/main)" ]
  [ "$(lease_json 01 adopted_from)" = feat/x ]
  [ "$(lease_json 01 adopted_repo)" = thing ]
  [ "$(lease_json 01 adopted_tip)" = "$tip" ]
  [ "$(lease_json 01 session_id)" = None ]
  [ "$(lease_json 01 note)" = "the old branch" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["trunks"] == {"thing": "main", "thing/sub": "main"}, d' "$DAEDALUS_HOME/state/leases/01.json"
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"- 01 "*"adopted from feat/x"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "adopt run twice is a no-op the second time: no second lease, the sentence names the window it already is" {
  on_feat "$T" feat/x 1
  bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x >/dev/null
  before="$(ls "$DAEDALUS_HOME/state/leases" | sort | tr '\n' ' ')"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"feat/x in target/thing is already window 01; nothing to do."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(ls "$DAEDALUS_HOME/state/leases" | sort | tr '\n' ' ')" = "$before" ]
}

@test "adopt refuses a dirty target/thing, and a branch with nothing past trunk (merged or cherry-picked counts as on trunk); nothing changes" {
  on_feat "$T" feat/x 1
  printf 'uncommitted\n' >> "$T/a.txt"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has uncommitted changes — commit them on their branch inside that checkout, then run adopt again."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = feat/x ]
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  git -C "$T" checkout -q -- a.txt
  git -C "$T" checkout -q main
  git -C "$T" branch feat/empty main
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/empty
  [ "$status" -ne 0 ]
  case "$output" in *"feat/empty in target/thing has no commits that are not already on origin/main — nothing to adopt."*) : ;; *) echo "$output"; return 1 ;; esac
  # the same change landed on trunk under another sha: git cherry sees it as on trunk
  git -C "$T" checkout -q -b feat/dup main
  printf 'trunk moved\n' >> "$T/b.txt"; git -C "$T" add -A; cmt "$T" -m "the same change"
  git -C "$T" checkout -q main
  trunk_moves b.txt "trunk moved"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/dup
  [ "$status" -ne 0 ]
  case "$output" in *"nothing to adopt"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
}

@test "adopt main when the trunk is ahead of origin: the commits move to a window, the trunk is reset to origin/main, no commit is lost" {
  printf 'local\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk by hand"
  tip="$(git -C "$T" rev-parse main)"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
  case "$(lease_json 01 adopted_from)" in daedalus/upgrade-*) : ;; *) echo "adopted_from: $(lease_json 01 adopted_from)"; return 1 ;; esac
  [ -z "$(git -C "$T" branch --list 'daedalus/upgrade-*')" ]
  case "$output" in *"left alone"*) echo "a note about origin for a moved trunk: $output"; return 1 ;; esac
  # and again: the trunk is now at origin/main, so there is nothing to adopt — never "already window 01"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -ne 0 ]
  case "$output" in *"has no commits that are not already on origin/main — nothing to adopt."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "adopt of a branch that was pushed: the same-named branch on origin is left alone, and the sentence says so" {
  on_feat "$T" feat/p 1
  git -C "$T" push -q origin feat/p
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/p
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds feat/p"*" Note: a branch named feat/p on origin was left alone."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse -q --verify refs/heads/feat/p >/dev/null
}

@test "adopt --repo sub: a nested repo's branch becomes the window's branch in sub; the outer repo's worktree is cut at its trunk" {
  on_feat "$T/sub" feat/n 1
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/n --repo sub
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"from target/thing/sub (1 commit:"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T/sub" branch --show-current)" = main ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing/sub" branch --show-current)" = lease/01 ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" rev-parse HEAD)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(lease_json 01 adopted_repo)" = thing/sub ]
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/n --repo elsewhere
  [ "$status" -ne 0 ]
  case "$output" in *"elsewhere is not one of this target's repos (thing, thing/sub)."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "adopt is refused to a visitor, and a missing branch is named" {
  run env DIRECT_CALL_ID=c1 bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -ne 0 ]
  case "$output" in *"direct-call session"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/none
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has no branch feat/none."*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- adopt: refusals leave everything where it was (plan 5 Task 2 review, findings 1-3) ---

@test "adopt of a branch refused by the worktree add leaves target/thing on the branch it was on and the branch under its own name — no lease/01, no lease file; adopt then works once the directory is moved aside" {
  on_feat "$T" feat/x 1
  tip="$(git -C "$T" rev-parse feat/x)"
  mkdir -p "$DAEDALUS_HOME/worktrees/01/thing"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -ne 0 ]
  case "$output" in *"worktrees/01/thing exists but is not a worktree of target/thing; move it aside."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = feat/x ]
  [ "$(git -C "$T" rev-parse feat/x)" = "$tip" ]
  git -C "$T" rev-parse -q --verify refs/heads/lease/01 >/dev/null && { echo "refs/heads/lease/01 is left"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  # a branch that is not the checked-out one: the checkout stays where it was, too
  git -C "$T" checkout -q -b feat/other main
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -ne 0 ]
  [ "$(git -C "$T" branch --show-current)" = feat/other ]
  [ "$(git -C "$T" rev-parse feat/x)" = "$tip" ]
  mv "$DAEDALUS_HOME/worktrees/01/thing" "$BATS_TEST_TMPDIR/aside"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
}

@test "adopt main refused by the worktree add leaves the trunk at its own tip and no daedalus/upgrade-* or lease/01 branch; adopt main then works once the directory is moved aside" {
  printf 'local\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk by hand"
  tip="$(git -C "$T" rev-parse main)"
  mkdir -p "$DAEDALUS_HOME/worktrees/01/thing"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -ne 0 ]
  case "$output" in *"move it aside."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse main)" = "$tip" ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ -z "$(git -C "$T" branch --list 'daedalus/upgrade-*')" ]
  git -C "$T" rev-parse -q --verify refs/heads/lease/01 >/dev/null && { echo "refs/heads/lease/01 is left"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  mv "$DAEDALUS_HOME/worktrees/01/thing" "$BATS_TEST_TMPDIR/aside"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
}

@test "adopt main finishes a run cut off after the window was made but before the trunk was reset: the trunk is reset, no second window is made" {
  printf 'local\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk by hand"
  tip="$(git -C "$T" rev-parse main)"
  bash "$DAEDALUS_HOME/core/lease.sh" adopt main >/dev/null
  git -C "$T" reset -q --hard "$tip"     # the state a kill between the window and the reset leaves
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"is already window 01"*"reset to origin/main"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
}

@test "adopt main refuses while an untracked file sits where resetting main to origin/main would write — a reset deletes it silently — and changes nothing; the file is kept" {
  printf 'local\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk by hand"
  tip="$(git -C "$T" rev-parse main)"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  printf 'gen\n' > "$BATS_TEST_TMPDIR/hand/gen.txt"; git -C "$BATS_TEST_TMPDIR/hand" add -A; cmt "$BATS_TEST_TMPDIR/hand" -m "generated file"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  printf 'mine\n' > "$T/gen.txt"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has untracked files that resetting main to origin/main would overwrite (gen.txt) — move them out of that checkout, or commit them, then run adopt again; nothing was adopted."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/gen.txt")" = mine ]; [ "$(git -C "$T" rev-parse main)" = "$tip" ]
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ -z "$(git -C "$T" branch --list 'lease/*')" ]
}

@test "adopt refuses while target/thing is on a detached HEAD whose commits no branch holds, and changes nothing; a detached HEAD on trunk is no obstacle" {
  on_feat "$T" feat/x 1
  git -C "$T" checkout -q --detach main
  printf 'detached\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "detached work"
  head="$(git -C "$T" rev-parse HEAD)"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing is on a detached HEAD ("*") holding commits no branch has"*"then run adopt again."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse HEAD)" = "$head" ]
  [ -z "$(git -C "$T" branch --show-current)" ]
  git -C "$T" rev-parse -q --verify refs/heads/feat/x >/dev/null
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  git -C "$T" checkout -q --detach main
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" branch --show-current)" = main ]
}

@test "adopt fast-forwards a trunk that is behind origin: target/thing ends at origin/main" {
  on_feat "$T" feat/x 1
  git -C "$T" checkout -q main
  trunk_moves b.txt "trunk moved"
  [ "$(git -C "$T" rev-parse main)" != "$(git -C "$T" rev-parse origin/main)" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
}

@test "adopt lease/01 is refused (it is already a window's branch) and changes nothing; an untracked file in target/thing does not block adopt" {
  on_feat "$T" feat/x 1
  printf 'scratch\n' > "$T/untracked-note.txt"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  before="$(ls "$DAEDALUS_HOME/state/leases" | sort | tr '\n' ' ')"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt lease/01
  [ "$status" -ne 0 ]
  case "$output" in *"lease/01 is already a window's branch; nothing to adopt."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(ls "$DAEDALUS_HOME/state/leases" | sort | tr '\n' ' ')" = "$before" ]
}

@test "adopt takes the next number when a swept window's merged lease/01 branch is still there, instead of failing on the rename" {
  git -C "$T" branch lease/01 origin/main
  on_feat "$T" feat/x 1
  tip="$(git -C "$T" rev-parse feat/x)"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/x
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 02 now holds feat/x"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse lease/02)" = "$tip" ]
  [ "$(git -C "$T" rev-parse lease/01)" = "$(git -C "$T" rev-parse origin/main)" ]
}

@test "adopt --repo sub refused by its own worktree add, after the outer repo's worktree was made: both are undone — no lease/01 in either repo, no worktree left, sub's branch under its own name and checked out" {
  on_feat "$T/sub" feat/n 1
  tip="$(git -C "$T/sub" rev-parse feat/n)"
  # git refuses the nested repo's worktree add only; the outer one goes through first
  fake_git 'case "$*" in *"/target/thing/sub worktree add"*) echo "fatal: simulated failure" >&2; exit 128 ;; esac'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/n --repo sub
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  case "$output" in *"git worktree add for window 01 (thing/sub) failed: fatal: simulated failure"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T/sub" branch --show-current)" = feat/n ]
  [ "$(git -C "$T/sub" rev-parse feat/n)" = "$tip" ]
  git -C "$T/sub" rev-parse -q --verify refs/heads/lease/01 >/dev/null && { echo "refs/heads/lease/01 is left"; return 1; }
  git -C "$T" rev-parse -q --verify refs/heads/lease/01 >/dev/null && { echo "refs/heads/lease/01 is left"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  git -C "$T" worktree list --porcelain | grep -q "worktrees/01/thing\$" && { echo "worktree left"; return 1; }
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/n --repo sub
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T/sub" rev-parse lease/01)" = "$tip" ]
}

@test "lease.sh refuses in plain words while the upgrade has not made state/leases/ (a home with VERSION and no stamp); a home with no VERSION is untouched by the rule" {
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  [ "$status" -ne 0 ]
  case "$output" in *"the upgrade has not run; start a session in this home"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/leases" ]
  rm "$DAEDALUS_HOME/VERSION"
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a lease write cut off after its number is reserved leaves no file, and an empty lease file an earlier build left is cleared: create, sweep and the board work over it (release-candidate review 3, finding 7)" {
  run python3 -c 'import sys
sys.path.insert(0, sys.argv[1])
import leaselib as ll
from pathlib import Path
def cut(*a, **kw):
    raise SystemExit(143)          # a SIGTERM, as session-start.py turns it
ll.json.dump = cut
try:
    ll.write_lease(Path(sys.argv[2]), "01", {"lease": "01"}, exclusive=True)
except SystemExit:
    pass
print(sorted(p.name for p in (Path(sys.argv[2]) / "state" / "leases").iterdir() if not p.name.startswith(".")))' \
    "$DAEDALUS_HOME/core" "$DAEDALUS_HOME"
  [ "$output" = "[]" ] || { echo "a cut-off reservation left: $output"; return 1; }
  : > "$DAEDALUS_HOME/state/leases/01.json"; : > "$DAEDALUS_HOME/state/leases/prime.json"
  run LS sweep
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -e "$DAEDALUS_HOME/state/leases/prime.json" ]
  : > "$DAEDALUS_HOME/state/leases/01.json"
  run LS create
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 lease)" = 01 ]
  run python3 "$LL" doctor-lines
  case "$output" in *MISSING*) echo "$output"; return 1 ;; esac
}

@test "a worktree add cut off so early that git cannot remove what it left — a record locked 'initializing' over a directory with no usable .git file, over a missing directory in the nested repo, or a window branch's .lock — never wedges a number: create clears it and makes the window (release-candidate review 3, findings 8, 11)" {
  W="$DAEDALUS_HOME/worktrees"
  # the outer repo: the .git file not written yet (git: "is not a .git file"), then not there at all
  git -C "$T" worktree add -q --lock --reason initializing "$W/01/thing" -b lease/01 origin/main; : > "$W/01/thing/.git"
  run LS create
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W/01/thing" branch --show-current)" = lease/01 ]; [ "$(git -C "$W/01/thing/sub" branch --show-current)" = lease/01 ]
  git -C "$T" worktree add -q --lock --reason initializing "$W/02/thing" -b lease/02 origin/main; rm "$W/02/thing/.git"
  run LS create
  case "$output" in *"Window 02 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W/02/thing" branch --show-current)" = lease/02 ]
  # the nested repo: its record locked over a directory that is gone, with orphan lease/03 branches at trunk
  git -C "$T" branch lease/03 origin/main
  git -C "$T/sub" worktree add -q --lock --reason initializing "$W/03/thing/sub" -b lease/03 origin/main; rm -rf "$W/03"
  run LS create
  case "$output" in *"Window 03 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W/03/thing/sub" branch --show-current)" = lease/03 ]
  # a cut-off `worktree add -b` left the window branch's lock file
  : > "$T/.git/refs/heads/lease/04.lock"
  run LS create
  case "$output" in *"Window 04 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$T/.git/refs/heads/lease/04.lock" ]
}

@test "allocating a window never prunes a worktree the operator made outside the home: one on a volume not mounted at that moment keeps its record, its index and its detached commits (release-candidate review 3, finding 2)" {
  V="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/vol"
  git -C "$T" worktree add -q --detach "$V/exp" main
  printf 'e\n' > "$V/exp/e.txt"; git -C "$V/exp" add -A; git -C "$V/exp" -c user.email=t@x -c user.name=t commit -q -m "exp-only"
  sha="$(git -C "$V/exp" rev-parse HEAD)"; printf 'staged\n' > "$V/exp/s.txt"; git -C "$V/exp" add s.txt
  mv "$V" "$V-unmounted"
  run LS create
  case "$output" in *"Window 01 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  mv "$V-unmounted" "$V"
  [ "$(git -C "$V/exp" rev-parse HEAD)" = "$sha" ] || { git -C "$V/exp" status; return 1; }
  [ "$(git -C "$V/exp" show :s.txt)" = staged ]
  # a window's own worktree whose directory is gone is still pruned, so its number can be cut again
  rm -rf "$DAEDALUS_HOME/worktrees/01"; rm -f "$DAEDALUS_HOME/state/leases/01".*
  run LS create
  case "$output" in *"Window 01 is ready"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$V/exp" rev-parse HEAD)" = "$sha" ]
}
