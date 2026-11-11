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
