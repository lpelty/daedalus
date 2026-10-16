#!/usr/bin/env bats
# Pins core/context.py's graph adapter (code-context design §5, §7; Task 3) with a fake code-review-graph
# (fixtures/context/fake-code-review-graph), and once with the real tool when CRG_TEST_VENV names a venv
# holding code-review-graph 2.3.9.
bats_require_minimum_version 1.5.0
load fixtures/context/setup.bash
setup() { context_fixture; rm -f "$DAEDALUS_HOME/core/context-rules.json"; window_02; cd "$DAEDALUS_HOME"; }   # rules: test_context_rules.bats
teardown() { teardown_live; pkill -f "$BATS_TEST_TMPDIR/crg/" 2>/dev/null || true; }

@test "the graph's environment is an allowlist: no API key, HOME and CRG_HOME and CRG_DATA_DIR under state/code-context/, the caller's git on PATH, cwd the repo root; every call is an allowed verb" {
  use_fake_graph
  mkdir -p "$BATS_TEST_TMPDIR/gitbin"; ln -s "$(command -v git)" "$BATS_TEST_TMPDIR/gitbin/git"
  run env PATH="$BATS_TEST_TMPDIR/gitbin:$PATH" OPENAI_API_KEY=k1 GOOGLE_API_KEY=k2 VOYAGE_API_KEY=k3 CRG_OPENAI_API_KEY=k4 \
    CLAUDE_CODE_SESSION_ID=sC python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '_API_KEY' "$CRG_LOG"
  H="$DAEDALUS_HOME/state/code-context/home"
  grep -qx "env HOME=$H" "$CRG_LOG"; grep -qx "env CRG_HOME=$H" "$CRG_LOG"
  grep -qx "env CRG_DATA_DIR=$DAEDALUS_HOME/state/code-context/02/thing" "$CRG_LOG"
  grep '^env PATH=' "$CRG_LOG" | grep -q "$BATS_TEST_TMPDIR/gitbin"
  [ -z "$(grep '^env ' "$CRG_LOG" | grep -vE '^env (PATH|HOME|CRG_HOME|CRG_DATA_DIR|LANG|LC_ALL|TMPDIR|PWD|SHLVL|OLDPWD|_)=')" ]
  grep -qx "cwd $W" "$CRG_LOG"
  for verb in $(crg_verbs); do
    case "$verb" in -v|build|update|query|impact) : ;; *) echo "not allowed: $verb"; return 1 ;; esac
  done
}

@test "the first query builds the index, later ones update it; the -v answer is cached; a new lease_created rebuilds" {
  use_fake_graph
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; case "${lines[0]}" in *"; graph built ("*" s)") : ;; *) echo "${lines[0]}"; return 1 ;; esac
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; case "${lines[0]}" in *"; graph updated ("*" s)") : ;; *) echo "${lines[0]}"; return 1 ;; esac
  [ "$(crg_verbs | tr '\n' ' ')" = "-v build query update query " ]
  M="$DAEDALUS_HOME/state/code-context/02/thing/meta.json"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["state"] == "ok" and m["lease"] == "02" and m["lease_created"] == "2026-10-16T10:00:00" and m["version"] == "2.3.9" and m["worktree"] == sys.argv[2], m' "$M" "$W"
  [ -f "$DAEDALUS_HOME/state/code-context/02/thing.lock" ]
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 \
    '{"lease":"02","session_id":"sC","worktree":"worktrees/02","branch":"lease/02","created":"2026-10-17T09:00:00","trunks":{"thing":"main","thing/sub":"main"}}'
  : > "$CRG_LOG"
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; [ "$(crg_verbs | tr '\n' ' ')" = "build query " ]
}

@test "the merge labels both, graph only and grep only exactly; graph paths come back tree-relative" {
  use_fake_graph
  run as_window python3 "$CX" callers pkg/core.py::helper --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 - "$output" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
lab = {h["file"]: h["label"] for h in d["hits"]}
assert lab == {"pkg/user.py": "both", "pkg/other.py": "graph only", "README.md": "grep only",
               "sub/agent.py": "grep only", "tests/test_core.py": "grep only"}, lab
u = next(h for h in d["hits"] if h["file"] == "pkg/user.py")
assert u["sources"] == ["graph", "grep"] and u["lines"] == [1, 3], u
assert d["graph"]["state"] == "present" and d["graph"]["version"] == "2.3.9", d["graph"]
assert d["counts"] == {"both": 1, "graph only": 1, "grep only": 3, "rule": 0}, d["counts"]
PY
  run as_window python3 "$CX" tests pkg/core.py
  expect_files tests/test_core.py
  printf '%s\n' "$output" | grep -qx 'both          tests/test_core.py:1'
  run as_window python3 "$CX" reach pkg/core.py
  printf '%s\n' "$output" | grep -qx 'both          pkg/other.py:1'
  grep -q '^argv impact --files pkg/core.py --depth 2 --max-results 500 --repo ' "$CRG_LOG"
  grep -q "^argv query callers_of $W/pkg/core.py::helper --repo $W\$" "$CRG_LOG"
}

@test "a malformed graph answer gives graph state failed for that answer while the grep hits still print" {
  use_fake_graph; crg_knob MALFORMED=1
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]
  case "${lines[0]}" in *"graph: the graph answer could not be read"*"so these answers come from git grep and rules") : ;; *) echo "${lines[0]}"; return 1 ;; esac
  printf '%s\n' "$output" | grep -q '^grep only     pkg/user.py:1$'
}

@test "-v answering another version is absent, with the version named; a context.graph that is not executable is absent" {
  use_fake_graph; crg_knob VERSION=2.4.0
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "importers pkg/core.py — window 02, repo thing; graph: $CRG_DIR/code-review-graph is code-review-graph 2.4.0, not the pinned 2.3.9, so these answers come from git grep and rules" ]
  [ "$(crg_verbs | tr '\n' ' ')" = "-v " ]
  chmod -x "$CRG_DIR/code-review-graph"
  run as_window python3 "$CX" importers pkg/core.py
  [ "${lines[0]}" = "importers pkg/core.py — window 02, repo thing; graph: context.graph is $CRG_DIR/code-review-graph, which is not an executable file, so these answers come from git grep and rules" ]
}

@test "a build that times out writes build-failed; the next query skips the graph without calling it; rebuild --timeout builds again" {
  use_fake_graph 30 1; crg_knob SLEEP_BUILD=5
  t0=$(date +%s)
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; [ $(( $(date +%s) - t0 )) -lt 4 ]
  case "${lines[0]}" in *"graph: the first index build failed at "[0-9][0-9]:[0-9][0-9]" (timed out after 1 s); python3 core/context.py rebuild --timeout 600 tries again (give that Bash call a 600 s timeout)") : ;; *) echo "${lines[0]}"; return 1 ;; esac
  printf '%s\n' "$output" | grep -q '^grep only     pkg/user.py:1$'
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["state"] == "build-failed" and m["failed_reason"] == "timed out after 1 s", m' \
    "$DAEDALUS_HOME/state/code-context/02/thing/meta.json"
  [ -z "$(pgrep -f "$CRG_DIR")" ]
  : > "$CRG_LOG"
  run as_window python3 "$CX" importers pkg/core.py --json
  [ "$status" -eq 0 ]; [ ! -s "$CRG_LOG" ]
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["graph"]["state"] == "failed", d["graph"]' "$output"
  crg_knob SLEEP_BUILD=0
  run as_window python3 "$CX" rebuild --timeout 20
  [ "$status" -eq 0 ]
  case "$output" in "Rebuilt the code-context index for thing in window 02 (7 files, "*" s).") : ;; *) echo "$output"; return 1 ;; esac
  run as_window python3 "$CX" importers pkg/core.py
  case "${lines[0]}" in *"; graph updated ("*) : ;; *) echo "${lines[0]}"; return 1 ;; esac
}

@test "a build sleeping past graph_budget returns inside the budget with the grep hits; nothing is left running" {
  use_fake_graph 2; crg_knob SLEEP_BUILD=30
  t0=$(date +%s)
  run as_window python3 "$CX" importers pkg/core.py --json
  [ "$status" -eq 0 ]; [ $(( $(date +%s) - t0 )) -lt 6 ]
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["graph"]["state"] in ("failed", "skipped"), d["graph"]; assert any(h["file"] == "pkg/user.py" for h in d["hits"])' "$output"
  sleep 0.2; [ -z "$(pgrep -f "$CRG_DIR")" ]
}

@test "a meta.json left at building by a stopped process becomes build-failed and is not retried" {
  use_fake_graph
  mkdir -p "$DAEDALUS_HOME/state/code-context/02/thing"
  printf '{"lease":"02","lease_created":"2026-10-16T10:00:00","worktree":"%s","version":"2.3.9","state":"building","pid":999999,"built_at":null}' "$W" \
    > "$DAEDALUS_HOME/state/code-context/02/thing/meta.json"
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]
  case "${lines[0]}" in *"graph: the first index build failed at "*"(did not finish (the process was stopped)); python3 core/context.py rebuild --timeout 600 tries again"*) : ;; *) echo "${lines[0]}"; return 1 ;; esac
  [ "$(crg_verbs | tr '\n' ' ')" = "-v " ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["state"] == "build-failed", m' "$DAEDALUS_HOME/state/code-context/02/thing/meta.json"
}

@test "two concurrent queries both answer and build once (the lock); the lock sits beside the index; a query waiting on a rebuild runs after it" {
  use_fake_graph; crg_knob SLEEP_BUILD=1
  as_window python3 "$CX" importers pkg/core.py > "$BATS_TEST_TMPDIR/a.out" 3>&- &
  a=$!
  as_window python3 "$CX" importers pkg/core.py > "$BATS_TEST_TMPDIR/b.out" 3>&- &
  b=$!
  wait "$a"; wait "$b"
  grep -q '^grep only     pkg/user.py:1$' "$BATS_TEST_TMPDIR/a.out" || grep -q '^both          pkg/user.py:1$' "$BATS_TEST_TMPDIR/a.out"
  grep -q 'pkg/user.py:1$' "$BATS_TEST_TMPDIR/b.out"
  [ "$(crg_verbs | grep -c '^build$')" -eq 1 ]
  [ -f "$DAEDALUS_HOME/state/code-context/02/thing.lock" ]; [ ! -e "$DAEDALUS_HOME/state/code-context/02/thing/thing.lock" ]
  crg_knob SLEEP_BUILD=2; : > "$CRG_LOG"
  as_window python3 "$CX" rebuild --timeout 20 > "$BATS_TEST_TMPDIR/r.out" 3>&- &
  r=$!
  sleep 0.7
  run as_window python3 "$CX" importers pkg/core.py
  wait "$r"
  [ "$status" -eq 0 ]
  # the waiter's update starts after the rebuild's build has ended
  [ "$(grep -E '^(argv (build|update)|end (build|update))' "$CRG_LOG" | awk '{print $1, $2}' | tr '\n' ',')" = "argv build,end build,argv update,end update," ]
}

@test "the real code-review-graph 2.3.9 (when CRG_TEST_VENV names it): build on the fixture, callers_of finds the .py caller; the worktree and HOME are untouched" {
  [ -n "${CRG_TEST_VENV:-}" ] && [ "$("$CRG_TEST_VENV/bin/code-review-graph" -v 2>/dev/null)" = "code-review-graph 2.3.9" ] \
    || skip "CRG_TEST_VENV does not name a venv holding code-review-graph 2.3.9"
  printf 'context:\n  graph: %s\n' "$CRG_TEST_VENV/bin/code-review-graph" >> "$DAEDALUS_HOME/config.yaml"
  st="$(git -C "$W" status --porcelain --ignored)"; files="$(cd "$W" && find . -path ./.git -prune -o -print | sort)"
  FH="$BATS_TEST_TMPDIR/fakehome"; mkdir -p "$FH"
  run env HOME="$FH" CLAUDE_CODE_SESSION_ID=sC python3 "$CX" callers pkg/core.py::helper --json
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["graph"]["state"] == "present", d["graph"]; lab={h["file"]: h["label"] for h in d["hits"]}; assert lab.get("pkg/user.py") == "both", lab' "$output"
  [ "$(git -C "$W" status --porcelain --ignored)" = "$st" ]
  [ "$(cd "$W" && find . -path ./.git -prune -o -print | sort)" = "$files" ]
  [ -z "$(ls -A "$FH")" ]
  [ ! -e "$FH/.code-review-graph" ]
}

@test "a session that only talks, plans and writes a spec runs no code-context layer: every hook in the release's settings.json fires, and the graph is never called and state/code-context/ never appears" {
  use_fake_graph
  cp "$BATS_TEST_DIRNAME/../../.claude/settings.json" "$DAEDALUS_HOME/.claude/settings.json"
  mkdir -p "$DAEDALUS_HOME/vault/specs"
  run python3 - "$DAEDALUS_HOME" <<'PY'
import json, os, subprocess, sys
home = sys.argv[1]
cfg = json.load(open(os.path.join(home, ".claude", "settings.json")))
env = dict(os.environ, CLAUDE_PROJECT_DIR=home, DAEDALUS_HOME=home)
spec = os.path.join(home, "vault", "specs", "plan.md")
base = {"session_id": "sC", "transcript_path": os.path.join(home, "no-transcript.jsonl"), "cwd": home}
payloads = {
    "SessionStart": [dict(base, source="startup")],
    "UserPromptSubmit": [dict(base, prompt="let us brainstorm and plan the spec before any code")],
    "PreToolUse": [dict(base, tool_name="Bash", tool_input={"command": "ls vault/specs"}),
                   dict(base, tool_name="Write", tool_input={"file_path": spec, "content": "# plan\n"})],
    "PostToolUse": [dict(base, tool_name="Bash", tool_input={"command": "ls vault/specs"}, tool_response={"stdout": ""})],
    "PostToolUseFailure": [dict(base, tool_name="Bash", tool_input={"command": "false"})],
    "Stop": [dict(base, stop_hook_active=False)],
    "SessionEnd": [dict(base, reason="exit")],
    "PreCompact": [dict(base, trigger="auto")],
}
ran = 0
for event, entries in cfg["hooks"].items():
    for e in entries:
        for h in e["hooks"]:
            for p in payloads.get(event, [dict(base)]):
                try:
                    subprocess.run(["bash", "-c", h["command"]], input=json.dumps(dict(p, hook_event_name=event)),
                                   capture_output=True, text=True, env=env, timeout=60)
                except subprocess.TimeoutExpired:
                    pass
                ran += 1
print(ran)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" -ge 14 ]
  [ ! -s "$CRG_LOG" ] || { echo "the graph was called:"; cat "$CRG_LOG"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/code-context" ]
}

@test "a rebuild cut short by what is left of graph_budget is skipped, not build-failed: the next query builds; a rebuild that fails on its own is named a rebuild" {
  use_fake_graph 4 3.5
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; case "${lines[0]}" in *"; graph built ("*) : ;; *) echo "${lines[0]}"; return 1 ;; esac
  crg_knob SLEEP_UPDATE=2; crg_knob FAIL_UPDATE=1; crg_knob SLEEP_BUILD=3
  run as_window python3 "$CX" importers pkg/core.py --json
  [ "$status" -eq 0 ]
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["graph"]["state"] == "skipped", d["graph"]' "$output"
  ! python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m.get("state") == "build-failed", m' "$DAEDALUS_HOME/state/code-context/02/thing/meta.json" 2>/dev/null
  sleep 0.2; [ -z "$(pgrep -f "$CRG_DIR")" ]
  : > "$CRG_DIR/fake-crg.env"
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; case "${lines[0]}" in *"; graph built ("*) : ;; *) echo "${lines[0]}"; return 1 ;; esac
  crg_knob FAIL_UPDATE=1; crg_knob FAIL_BUILD=1
  run as_window python3 "$CX" importers pkg/core.py
  case "${lines[0]}" in *"graph: the index rebuild after a failed update failed at "[0-9][0-9]:[0-9][0-9]" (exited 1: "*"); python3 core/context.py rebuild --timeout 600 tries again (give that Bash call a 600 s timeout)") : ;; *) echo "${lines[0]}"; return 1 ;; esac
}

@test "killing the query's process group stops code-review-graph with it: nothing is left running" {
  use_fake_graph; crg_knob SLEEP_BUILD=20
  python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' env CLAUDE_CODE_SESSION_ID=sC python3 "$CX" importers pkg/core.py </dev/null >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do grep -q '^argv build' "$CRG_LOG" && break; sleep 0.1; done
  grep -q '^argv build' "$CRG_LOG"
  kill -KILL -- "-$pid"
  sleep 0.5
  [ -z "$(pgrep -f "$CRG_DIR")" ] || { ps -o pid,pgid,command -p $(pgrep -f "$CRG_DIR" | tr '\n' ' '); return 1; }
}

@test "a SIGTERM to the query process alone stops code-review-graph too" {
  use_fake_graph; crg_knob SLEEP_BUILD=20
  env CLAUDE_CODE_SESSION_ID=sC python3 "$CX" importers pkg/core.py </dev/null >/dev/null 2>&1 &
  pid=$!
  for _ in $(seq 50); do grep -q '^argv build' "$CRG_LOG" && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid" || true
  sleep 0.3
  [ -z "$(pgrep -f "$CRG_DIR")" ]
}

@test "the -v cache is keyed on the installed package too: an upgrade in place that leaves the wrapper untouched is seen" {
  use_fake_graph
  SP="$BATS_TEST_TMPDIR/crg/lib/python3.12/site-packages"; mkdir -p "$SP/code_review_graph-2.3.9.dist-info"
  run as_window python3 "$CX" importers pkg/core.py
  [ "$status" -eq 0 ]; case "${lines[0]}" in *"; graph built ("*) : ;; *) echo "${lines[0]}"; return 1 ;; esac
  rm -rf "$SP/code_review_graph-2.3.9.dist-info"; mkdir -p "$SP/code_review_graph-2.4.0.dist-info"; crg_knob VERSION=2.4.0
  run as_window python3 "$CX" importers pkg/core.py
  case "${lines[0]}" in *"is code-review-graph 2.4.0, not the pinned 2.3.9"*) : ;; *) echo "${lines[0]}"; return 1 ;; esac
}
