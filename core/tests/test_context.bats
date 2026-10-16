#!/usr/bin/env bats
# Pins core/context.py's tree resolution, git grep, labels and output, without the graph
# (code-context design §5, §6; Task 2). The fixture's files are listed in fixtures/context/setup.bash.
bats_require_minimum_version 1.5.0
load fixtures/context/setup.bash
setup() { context_fixture; rm -f "$DAEDALUS_HOME/core/context-rules.json"; }   # the rules have their own file
teardown() { teardown_live; }

@test "outside a window, each verb's grep patterns find exactly the expected files, all labelled grep only; untracked found, ignored not, the subject never a hit" {
  cd "$DAEDALUS_HOME"
  run python3 "$CX" callers pkg/core.py::helper
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "callers pkg/core.py::helper — outside a window: grep and rules over target/thing; nothing recorded" ]
  expect_files README.md pkg/user.py sub/agent.py tests/test_core.py
  [ "$(printf '%s\n' "$output" | grep -c '^grep only ')" -eq 4 ]
  run python3 "$CX" importers pkg/core.py
  expect_files pkg/new_user.py pkg/other.py pkg/user.py sub/agent.py templates/job.md.tmpl tests/test_core.py tools/run.sh
  run python3 "$CX" tests pkg/core.py
  expect_files tests/test_core.py
  run python3 "$CX" tests pkg/core.py::helper
  expect_files tests/test_core.py
  run python3 "$CX" reach pkg/core.py
  expect_files pkg/new_user.py pkg/other.py pkg/user.py sub/agent.py templates/job.md.tmpl tests/test_core.py tools/run.sh
  run python3 "$CX" reach pkg/core.py::helper
  expect_files README.md pkg/user.py sub/agent.py templates/job.md.tmpl tests/test_core.py
  run python3 "$CX" callers helper
  expect_files README.md pkg/core.py pkg/user.py sub/agent.py tests/test_core.py
  run python3 "$CX" grep "pkg.core"
  expect_files pkg/new_user.py pkg/user.py sub/agent.py tests/test_core.py tools/run.sh
  case "$output" in *build/ignored.py*) echo "an ignored file was searched: $output"; return 1 ;; esac
  [ "${lines[${#lines[@]}-1]}" = "5 files: 0 both, 0 graph only, 5 grep only, 0 rule. These are candidates, not answers: read each file, and let the tests decide." ]
}

@test "plain lines show the first line number; an absolute subject path inside the tree is accepted; a nested file carries its nested path and names its repo" {
  cd "$DAEDALUS_HOME"
  run python3 "$CX" callers "$T/pkg/core.py::helper"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'grep only     pkg/user.py:1'
  printf '%s\n' "$output" | grep -qx 'grep only     sub/agent.py:1'
  run python3 "$CX" importers sub/agent.py --json
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["subject"] == {"files": ["sub/agent.py"], "symbol": None, "repo": "thing/sub"}, d' "$output"
}

@test "--json prints one object of the §5 shape; the graph is skipped outside a window" {
  cd "$DAEDALUS_HOME"
  run python3 "$CX" importers pkg/core.py --json
  [ "$status" -eq 0 ]
  python3 - "$output" "$T" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert set(d) == {"verb", "arg", "subject", "window", "tree", "graph", "hits", "rules_skipped", "counts", "truncated"}, sorted(d)
assert d["verb"] == "importers" and d["arg"] == "pkg/core.py" and d["window"] is None, d
assert d["tree"] == sys.argv[2], d["tree"]
assert d["subject"] == {"files": ["pkg/core.py"], "symbol": None, "repo": "thing"}, d["subject"]
assert d["graph"]["state"] == "skipped" and set(d["graph"]) == {"state", "version", "seconds", "note"}, d["graph"]
assert d["counts"] == {"both": 0, "graph only": 0, "grep only": 7, "rule": 0}, d["counts"]
h = {x["file"]: x for x in d["hits"]}
assert h["pkg/user.py"]["label"] == "grep only" and h["pkg/user.py"]["sources"] == ["grep"], h["pkg/user.py"]
assert h["pkg/user.py"]["lines"] == [1] and h["pkg/user.py"]["why"] == ["grep: pkg.core"], h["pkg/user.py"]
assert d["truncated"] == 0 and d["rules_skipped"] == [], d
PY
}

@test "plain output stops at 200 file lines with the +N more line; --json carries all of them" {
  cd "$DAEDALUS_HOME"
  mkdir -p "$T/many"
  for i in $(seq 1 205); do printf 'MANYTOKEN\n' > "$T/many/f$i.txt"; done
  run python3 "$CX" grep MANYTOKEN
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^grep only ')" -eq 200 ]
  printf '%s\n' "$output" | grep -qx '+5 more — run it again with --json for all of them'
  run python3 "$CX" grep MANYTOKEN --json
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert len(d["hits"]) == 205 and d["truncated"] == 0, len(d["hits"])' "$output"
}

@test "zero hits exit 0; usage errors exit 2; a Refused resolution prints its sentence and exits 2" {
  cd "$DAEDALUS_HOME"
  run python3 "$CX" grep NOWHERE_IN_THE_TREE
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "0 files: 0 both, 0 graph only, 0 grep only, 0 rule. These are candidates, not answers: read each file, and let the tests decide." ]
  run python3 "$CX" frobnicate x; [ "$status" -eq 2 ]
  run python3 "$CX" importers pkg/nope.py; [ "$status" -eq 2 ]
  case "$output" in *"pkg/nope.py"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$CX" importers pkg/core.py::helper; [ "$status" -eq 2 ]
  run python3 "$CX" importers /etc/hosts; [ "$status" -eq 2 ]
  window_02
  run env CLAUDE_CODE_SESSION_ID=sZ python3 "$CX" importers pkg/core.py
  [ "$status" -eq 2 ]
  case "$output" in *"This session holds no window"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "in a window it searches the window's worktree; the header names the window and repo and says once that the graph is absent" {
  window_02
  printf 'from pkg.core import helper\n' > "$W/pkg/window_only.py"
  cd "$DAEDALUS_HOME"
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "importers pkg/core.py — window 02, repo thing; graph: not installed (context.graph in config.yaml), so these answers come from git grep and rules" ]
  [ "$(printf '%s\n' "$output" | grep -c 'graph: ')" -eq 1 ]
  printf '%s\n' "$output" | grep -q '^grep only     pkg/window_only.py:1$'
  run as_window python3 "$CX" importers pkg/core.py --json
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["window"] == "02" and d["tree"] == sys.argv[2] and d["graph"]["state"] == "absent", d' "$output" "$W"
}

@test "outside a window, as a visitor, and with DAEDALUS_TARGET_OVERRIDE nothing is written under state/, and a stale window directory survives" {
  window_02
  mkdir -p "$DAEDALUS_HOME/state/code-context/07"; printf '{"lease":"07"}\n' > "$DAEDALUS_HOME/state/code-context/07/queries.jsonl"
  git -C "$T" worktree add -q --detach "$DAEDALUS_HOME/state/promote/p1/thing" main
  printf 'from pkg.core import helper\n' > "$DAEDALUS_HOME/state/promote/p1/thing/pkg/promote_only.py"
  cd "$DAEDALUS_HOME"
  before="$(state_listing)"
  run python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; [ "$(state_listing)" = "$before" ]
  run env DIRECT_CALL_ID=c1 CLAUDE_CODE_SESSION_ID=sC python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "importers pkg/core.py — outside a window: grep and rules over target/thing; nothing recorded" ]
  [ "$(state_listing)" = "$before" ]
  run env DAEDALUS_TARGET_OVERRIDE="$DAEDALUS_HOME/state/promote/p1/thing" CLAUDE_CODE_SESSION_ID=sC python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "importers pkg/core.py — outside a window: grep and rules over state/promote/p1/thing; nothing recorded" ]
  printf '%s\n' "$output" | grep -q '^grep only     pkg/promote_only.py:1$'
  [ "$(state_listing)" = "$before" ]
  [ -f "$DAEDALUS_HOME/state/code-context/07/queries.jsonl" ]
  git -C "$T" worktree remove --force "$DAEDALUS_HOME/state/promote/p1/thing"
}

@test "importers of a one-segment module (e.py at the tree root) is not a substring search: only its importers and the files naming its basename are hits" {
  cd "$DAEDALUS_HOME"
  printf 'def f():\n    return 2\n' > "$T/e.py"
  printf 'import e\n\ne.f()\n' > "$T/pkg/uses_e.py"
  printf 'from e import f\n' > "$T/pkg/from_e.py"
  printf 'Run python3 e.py once; see also make-e.py and line.py.\n' > "$T/notes.md"
  run python3 "$CX" importers e.py
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  expect_files notes.md pkg/from_e.py pkg/uses_e.py
}
