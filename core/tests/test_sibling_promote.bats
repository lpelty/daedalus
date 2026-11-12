#!/usr/bin/env bats
# Promoting a sibling repo (v0.13.0, plan v0130 Task 5) and promote as a tagged release (Task 6). The fixture is
# test_promote.bats's with one sibling, portico, cut into every window (PROMOTE_SIBLING).
bats_require_minimum_version 1.5.0
load fixtures/promote/setup.bash
setup() {
  PROMOTE_SIBLING=portico promote_fixture
  W2S="$DAEDALUS_HOME/worktrees/02/portico"; S="$DAEDALUS_HOME/target/portico"; SO="$BATS_TEST_TMPDIR/portico-origin.git"
  export W2S S SO
}
teardown() { teardown_live; }

work_on_02_sibling() {
  printf 'p1\n' > "$W2S/p.txt"; git -C "$W2S" add -A; git -C "$W2S" commit -q -m "portico: first"
}
sibling_gate() {   # sibling_gate <command> — replace the sibling's gates list with one command
  python3 - "$DAEDALUS_HOME/config.yaml" "$1" <<'PY'
import re, sys
p, cmd = sys.argv[1:3]; s = open(p).read()
s = re.sub(r"gates_portico:\n(  - .*\n)+", "gates_portico:\n  - %s\n" % cmd, s)
open(p, "w").write(s)
PY
}

@test "a sibling window promotes in its own scratch: the gates run in state/promote/<id>/portico, prepared.json names the repo, confirm pushes the sibling's origin and leaves the primary's untouched, target/portico is fast-forwarded" {
  work_on_02_sibling; sibling_gate "pwd > $BATS_TEST_TMPDIR/gate-cwd"
  outer_before="$(origin_main)"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Ready to promote window 02's work onto main." ]
  [ "$(pj repo)" = portico ]; pid="$(pj promote_id)"; m="$(pj merge_sha)"
  [ "$(cd "$(cat "$BATS_TEST_TMPDIR/gate-cwd")" && pwd -P)" = "$(cd "$DAEDALUS_HOME/state/promote/$pid/portico" && pwd -P)" ] || { echo "gate ran in $(cat "$BATS_TEST_TMPDIR/gate-cwd")"; return 1; }
  [ "$(git -C "$DAEDALUS_HOME/state/promote/$pid/portico" rev-parse HEAD)" = "$m" ]
  [ "$(git -C "$DAEDALUS_HOME/state/promote/$pid/thing" rev-parse HEAD)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(pj fp_merged)" != null ]
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["repo"]=="portico" and r["tree_repo"]=="portico" and r["merge_sha"]==sys.argv[2], r' \
    "$DAEDALUS_HOME/state/evidence/$(pj run_id)/run.json" "$m"
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$SO" rev-parse main)" = "$m" ]; [ "$(origin_main)" = "$outer_before" ]
  [ "$(git -C "$S" rev-parse HEAD)" = "$m" ]
}

@test "the window's own gate run of the sibling tree (gates.sh --repo portico, clean worktree) is the run promote reuses" {
  work_on_02_sibling
  run env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sC bash "$DAEDALUS_HOME/core/gates.sh" --repo portico
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  first="$(ls -t "$DAEDALUS_HOME"/state/evidence/*/run.json | head -1)"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj gates.reused_from)" = "$(basename "$(dirname "$first")")" ] || { echo "not reused: $(pj gates.reused_from); $output"; return 1; }
  case "$output" in *"this exact tree already passed them, nothing re-ran"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "commits in the primary and a sibling are refused with the split remedy naming the sibling by its bare name; nothing is cut" {
  work_on_02; work_on_02_sibling
  run as_prime bash "$PROMOTE" 02; refused "Window 02 has commits in both thing and portico. v1 promotes one repo per run."
  case "$output" in *"core/lease.sh split 02 --repo portico"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
}

@test "a sibling removed from config after the window was cut is refused by name (config drift names target.siblings)" {
  work_on_02_sibling
  sed -i '' '/^  siblings: /d' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02
  refused "Window 02 was cut for the repos portico, thing, thing/sub, but config now names thing, thing/sub."
  case "$output" in *"Put config target.nested or target.siblings back"*) : ;; *) echo "$output"; return 1 ;; esac
}

bg_json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))' "$DAEDALUS_HOME/state/promote/$1/background.json" "$2"; }
wait_bg() {   # wait_bg <promote-id> — up to 90 s for the background full run; prints its state
  local i=0
  while [ "$i" -lt 900 ]; do
    [ "$(bg_json "$1" state 2>/dev/null)" = running ] || { bg_json "$1" state; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  echo "the background run of $1 never finished:"; cat "$DAEDALUS_HOME/state/promote/$1/background.log" 2>/dev/null; return 1
}

@test "a quick promote of a sibling: the background full run runs the SIBLING's gates in the sibling's scratch, never the primary's (review finding 1)" {
  sibling_gate "pwd > $BATS_TEST_TMPDIR/bg-cwd"
  RAN="$BATS_TEST_TMPDIR/primary-ran"; sed -i '' "s|^gates:\$|gates:\\
  - echo ran >> $RAN|" "$DAEDALUS_HOME/config.yaml"; sed -i '' '/^gates:$/{n;/^  - true$/d;}' "$DAEDALUS_HOME/config.yaml" 2>/dev/null || true
  printf 'gates_quick_portico: echo quick {files} >> %s\n' "$BATS_TEST_TMPDIR/quick-ran" >> "$DAEDALUS_HOME/config.yaml"
  mkdir -p "$W2S/tests"; printf 't\n' > "$W2S/tests/test_p.bats"; git -C "$W2S" add -A; git -C "$W2S" commit -q -m "test: p"
  tx "$TXP" operator "This is tiny — push it, skip the full run." "$(now)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --quick --reason "skip the full run"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pid="$(pj promote_id)"; m="$(pj merge_sha)"
  [ "$(git -C "$SO" rev-parse main)" = "$m" ]
  grep -q 'quick tests/test_p.bats' "$BATS_TEST_TMPDIR/quick-ran"
  [ "$(wait_bg "$pid")" = PASS ] || { cat "$DAEDALUS_HOME/state/promote/$pid/background.log"; return 1; }
  brid="$(bg_json "$pid" run_id)"
  [ "$(cd "$(cat "$BATS_TEST_TMPDIR/bg-cwd")" && pwd -P)" = "$(cd "$DAEDALUS_HOME/state/promote/$pid/portico" 2>/dev/null && pwd -P || echo gone)" ] \
    || case "$(cat "$BATS_TEST_TMPDIR/bg-cwd")" in */state/promote/$pid/portico) : ;; *) echo "the background gate ran in $(cat "$BATS_TEST_TMPDIR/bg-cwd")"; return 1 ;; esac
  [ ! -e "$RAN" ] || { echo "the primary's gates ran in the background for a sibling promote"; return 1; }
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["tree_repo"]=="portico" and r["repo"]=="portico", r' "$DAEDALUS_HOME/state/evidence/$brid/run.json"
}

@test "trunk_of classifies a repo in Python (the primary by name, nested by its slash, else a sibling): a failing bash reader cannot move the primary onto its origin/HEAD (review finding 6)" {
  run python3 - "$DAEDALUS_HOME" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + "/core"); from pathlib import Path; import leaselib as ll, verifylib as v
v.repo_kind = lambda root, key: ""          # the bash reader answers nothing (a timeout, a missing lib.sh)
r = Path(sys.argv[1]); print(ll.trunks_of(r, r / "target"))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "{'thing': 'main', 'thing/sub': 'main', 'portico': 'main'}" ]
}
