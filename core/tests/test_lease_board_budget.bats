#!/usr/bin/env bats
# Pins v0.7.5 (PROP-025): the lease board stays drawn when git is slow — the unpromoted-work cache, a reclaimed window
# that costs nothing, and a partial board on a deadline (spec 2026-10-16-lease-board-budget-design).
# Wall-clock assertions throughout: the tests of this file run one at a time under the parallel full suite.
BATS_NO_PARALLELIZE_WITHIN_FILE=true
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }; export GIT_LOG="$BATS_TEST_TMPDIR/git.log"; }
teardown() { teardown_live; }
board() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"hello there"}' "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py"; }
ctx() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
bind_live() {  # bind_live <NN> <sid> — claim with a live registry pid
  local pid; pid="$(live_pid)"; registry_entry "$pid" "$2" interactive cli "daedalus-$1"
  env CLAUDE_CODE_SESSION_ID="$2" bash "$DAEDALUS_HOME/core/lease.sh" claim "$1" >/dev/null
}
now() { python3 -c 'import time; print(time.time())'; }
under() {  # under <t0> <t1> <secs> <what>
  python3 -c 'import sys; d=float(sys.argv[2])-float(sys.argv[1]); print("%s took %.2fs" % (sys.argv[4], d), file=sys.stderr); assert d < float(sys.argv[3]), "%s slow: %.2fs" % (sys.argv[4], d)' "$@"
}
# timed_board <sid> — one prompt through PATH (as set by the caller); $output, $status, and the wall time checked < 4.5 s
timed_board() {
  local t0 t1; t0="$(now)"; run board "$1"; t1="$(now)"
  [ "$status" -eq 0 ] || { echo "exit $status: $output"; return 1; }
  under "$t0" "$t1" 4.5 "prompt" || { ctx; return 1; }
}
# four_repos <NN>... — outer + sub, sub2, sub3; window 01 live (sA); the given windows created, then swept with work
four_repos() {
  add_nested sub2; add_nested sub3
  local n=$(( $# + 1 )) i
  for i in $(seq 1 "$n"); do LS create >/dev/null; done
  bind_live 01 sA
  swept_with_work "$@"
}

@test "PROP-025: 3 swept windows x 4 repos, every slow-listed git call sleeping 0.15 s — every prompt draws a board (never 'could not be rendered'), exit 0, within 4.5 s" {
  four_repos 02 03 04
  export PATH="$(count_git):$PATH" FAKE_GIT_SLEEP_ON="merge-base log for-each-ref" FAKE_GIT_SLEEP=0.15
  for p in 1 2 3 4 5; do
    timed_board sA
    c="$(ctx)"
    case "$c" in *"could not be rendered"*) echo "prompt $p: $c"; return 1 ;; esac
    case "$c" in "Lease board ("*) : ;; *) echo "prompt $p: $c"; return 1 ;; esac
  done
}
