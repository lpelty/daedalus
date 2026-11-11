#!/usr/bin/env bats
# Sibling target repos (v0.13.0): repos checked out BESIDE the primary under target/, each a single repo of its
# own with its own trunk, gates and promotions (spec 2026-11-11, plan v0130). The fixture helper `add_sibling`
# lives beside `add_nested` in fixtures/leases/setup.bash.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; LL="$DAEDALUS_HOME/core/leaselib.py"; }

lib() { ( cd "$DAEDALUS_HOME" && source core/lib.sh && "$@" ); }

@test "add_sibling: a clone beside the primary on its trunk, its bare origin with origin/HEAD, target.siblings and gates_<name> in config" {
  add_sibling portico
  [ -d "$DAEDALUS_HOME/target/portico/.git" ]
  [ ! -e "$DAEDALUS_HOME/target/thing/portico" ]
  [ "$(git -C "$DAEDALUS_HOME/target/portico" branch --show-current)" = main ]
  [ "$(git -C "$DAEDALUS_HOME/target/portico" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/main ]
  run lib cfg_pairs target.siblings
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "portico	$BATS_TEST_TMPDIR/portico-origin.git" ]
  run lib cfg_list gates_portico
  [ "${lines[0]}" = "true" ]
  # the primary's own config is untouched
  run lib cfg_pairs target.nested
  [ "${lines[0]}" = "sub	https://example.com/sub.git" ]
}

@test "add_sibling NO_GATES=1: the sibling has no gates_<name> list" {
  NO_GATES=1 add_sibling portico
  run lib cfg_list gates_portico
  [ -z "$output" ]
}

LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }
lease_json() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$DAEDALUS_HOME/state/leases/$1.json" "$2"; }

@test "repos_of / trunks_of: a sibling is in the repo set by its bare name with its origin/HEAD as trunk; without one it is Refused with the remedy" {
  add_sibling portico
  run python3 - "$DAEDALUS_HOME" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + "/core"); from pathlib import Path; import leaselib as ll
r = Path(sys.argv[1]); print(ll.repos_of(r)); print(ll.trunks_of(r, r / "target"))
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "['thing', 'thing/sub', 'portico']" ]
  [ "${lines[1]}" = "{'thing': 'main', 'thing/sub': 'main', 'portico': 'main'}" ]
  git -C "$DAEDALUS_HOME/target/portico" symbolic-ref --delete refs/remotes/origin/HEAD
  run python3 - "$DAEDALUS_HOME" <<'PY'
import sys; sys.path.insert(0, sys.argv[1] + "/core"); from pathlib import Path; import leaselib as ll
r = Path(sys.argv[1])
try: ll.trunks_of(r, r / "target"); print("no refusal")
except ll.Refused as e: print("Refused:", e)
PY
  [ "$output" = "Refused: sibling repo portico has no origin/HEAD — run git -C target/portico remote set-head origin -a" ]
}

@test "a window cuts a worktree of the sibling at worktrees/NN/<name> on lease/NN, beside the primary's, and records it in trunks" {
  add_sibling portico
  LS create >/dev/null
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/portico" branch --show-current)" = lease/01 ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/portico" rev-parse HEAD)" = "$(git -C "$DAEDALUS_HOME/target/portico" rev-parse origin/main)" ]
  [ ! -e "$DAEDALUS_HOME/worktrees/01/thing/portico" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["trunks"] == {"thing": "main", "thing/sub": "main", "portico": "main"}, d' "$DAEDALUS_HOME/state/leases/01.json"
  [ -x "$DAEDALUS_HOME/target/portico/.git/hooks/pre-push" ]
}

@test "split 02 --repo <sibling>: the sibling's commits move to a new window; the refusal for an unknown repo names the window's other repos" {
  add_sibling portico
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  LS create >/dev/null; LS create >/dev/null
  W="$DAEDALUS_HOME/worktrees/02"
  printf 'o\n' >> "$W/thing/a.txt"; git -C "$W/thing" -c user.email=t@x -c user.name=t commit -q -am "outer work"
  printf 'p\n' >> "$W/portico/s.txt"; git -C "$W/portico" -c user.email=t@x -c user.name=t commit -q -am "portico one"
  run LS split 02 --repo other; [ "$status" -ne 0 ]
  case "$output" in *"Window 02 has no repo other (its other repos: thing/sub, portico)."*) : ;; *) echo "$output"; return 1 ;; esac
  run LS split 02 --repo portico; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 03 now holds window 02's commits in portico (1: \"portico one\"); window 02 keeps its other commits."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/worktrees/03/portico" log -1 --format=%s)" = "portico one" ]
  [ "$(git -C "$W/portico" rev-parse HEAD)" = "$(git -C "$DAEDALUS_HOME/target/portico" rev-parse origin/main)" ]
  [ "$(git -C "$W/thing" log -1 --format=%s)" = "outer work" ]
  python3 -c 'import json,sys; b=json.load(open(sys.argv[1])); assert b["split_from"]["lease"] == "02" and b["split_from"]["repo"] == "portico", b' "$DAEDALUS_HOME/state/leases/03.json"
}

@test "adopt <branch> --repo <sibling>: a branch in target/<sibling> becomes a window, the sibling back on its trunk" {
  add_sibling portico
  S="$DAEDALUS_HOME/target/portico"
  git -C "$S" checkout -q -b feat/p; printf 'p\n' > "$S/p.txt"; git -C "$S" add -A; git -C "$S" -c user.email=t@x -c user.name=t commit -q -m "p work"
  tip="$(git -C "$S" rev-parse feat/p)"
  run LS adopt feat/p --repo portico
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds feat/p from target/portico (1 commit: \"p work\") on branch lease/01; target/portico is on main at origin/main."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$S" branch --show-current)" = main ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/01/portico" rev-parse HEAD)" = "$tip" ]
  [ "$(lease_json 01 adopted_repo)" = portico ]
}

@test "sweep (stale windows): one whose sibling worktree is clean loses its worktree and branch; one with unpromoted sibling commits keeps them, and unpromoted names the sibling's commit" {
  add_sibling portico
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  LS create >/dev/null; LS create >/dev/null
  printf 'p\n' >> "$DAEDALUS_HOME/worktrees/02/portico/s.txt"
  git -C "$DAEDALUS_HOME/worktrees/02/portico" -c user.email=t@x -c user.name=t commit -q -am "portico work"
  for nn in 01 02; do   # both stale: a dead pid and a session nothing knows
    python3 "$LL" _test-write $nn "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["session_id"]="s'$nn'"; d["pid"]=1; d["proc_started"]=1; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$nn.json")"
  done
  run LS sweep; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/worktrees/01" ]
  ! git -C "$DAEDALUS_HOME/target/portico" rev-parse -q --verify lease/01 >/dev/null
  [ -d "$DAEDALUS_HOME/worktrees/02/portico" ]
  git -C "$DAEDALUS_HOME/target/portico" rev-parse -q --verify lease/02 >/dev/null
  run LS unpromoted 02
  case "$output" in *"1 unpromoted commit: \"portico work\""*) : ;; *) echo "$output"; return 1 ;; esac
}
