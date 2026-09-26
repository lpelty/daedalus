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
  printf 'trunk\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -q -am "trunk moved"; git -C "$T" push -q origin main
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
