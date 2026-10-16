#!/usr/bin/env bats
# Pins core/context.py's query log and pruning (code-context design §7 Pruning, §8; Task 5).
bats_require_minimum_version 1.5.0
load fixtures/context/setup.bash
setup() { context_fixture; window_02; cd "$DAEDALUS_HOME"; Q="$DAEDALUS_HOME/state/code-context/02/queries.jsonl"; }
teardown() { teardown_live; chmod -R u+w "$DAEDALUS_HOME/state" 2>/dev/null || true; }

@test "a query in a window appends one row with every §8 field; no row is written outside a window" {
  run as_window python3 "$CX" reach pkg/core.py
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$Q" | tr -d ' ')" -eq 1 ]
  python3 - "$Q" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
r = rows[0]
want = {"at", "lease", "lease_created", "session_id", "verb", "arg", "repo", "subject_files", "hits", "graph", "rules", "broad"}
assert set(r) == want, sorted(set(r) ^ want)
assert r["lease"] == "02" and r["lease_created"] == "2026-10-16T10:00:00" and r["session_id"] == "sC", r
assert r["verb"] == "reach" and r["arg"] == "pkg/core.py" and r["repo"] == "thing" and r["subject_files"] == ["pkg/core.py"], r
assert ["pkg/user.py", "grep only"] in r["hits"] and ["tools/run.sh", "grep only"] in r["hits"], r["hits"]
assert ["templates/job.md.tmpl", "grep only"] in r["hits"], r["hits"]
assert r["graph"] == "absent" and r["broad"] is False, r
assert r["rules"] == ["module-run", "python-path-join", "shell-beside", "template-placeholder"], r["rules"]
assert r["at"].endswith("Z"), r
PY
  run as_window python3 "$CX" grep NOWHERE_IN_THE_TREE
  [ "$(wc -l < "$Q" | tr -d ' ')" -eq 2 ]
  python3 -c 'import json,sys; r=[json.loads(l) for l in open(sys.argv[1])][1]; assert r["hits"] == [] and r["subject_files"] == [], r' "$Q"
  rm -rf "$DAEDALUS_HOME/state/code-context"
  run python3 "$CX" reach pkg/core.py
  [ ! -e "$DAEDALUS_HOME/state/code-context" ]
}

@test "two parallel queries leave two valid rows" {
  as_window python3 "$CX" reach pkg/core.py > /dev/null 3>&- &
  a=$!
  as_window python3 "$CX" callers pkg/core.py::helper > /dev/null 3>&- &
  b=$!
  wait "$a"; wait "$b"
  [ "$(wc -l < "$Q" | tr -d ' ')" -eq 2 ]
  python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; assert sorted(r["verb"] for r in rows) == ["callers", "reach"], rows' "$Q"
}

@test "an unwritable window directory still prints the answer, plus the not-recorded line" {
  mkdir -p "$DAEDALUS_HOME/state/code-context/02"; chmod 555 "$DAEDALUS_HOME/state/code-context/02"
  run as_window python3 "$CX" reach pkg/core.py
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q '^grep only     pkg/user.py:1$'
  case "${lines[${#lines[@]}-1]}" in "This query was not recorded ("*"); promote will count its files as unpredicted.") : ;; *) echo "$output"; return 1 ;; esac
}

@test "pruning removes a swept window's directory and a reissued number's old one, keeps a released-but-unswept window's, never touches a live one's; only a window prunes" {
  CC="$DAEDALUS_HOME/state/code-context"
  for nn in 03 04 05 06; do mkdir -p "$CC/$nn/thing"; done
  printf '{"lease":"03","lease_created":"2026-10-01T00:00:00"}\n' > "$CC/03/queries.jsonl"
  printf '{"lease":"04","lease_created":"2026-10-02T00:00:00"}\n' > "$CC/04/queries.jsonl"
  printf '{"lease":"05","lease_created":"2026-10-03T00:00:00"}\n' > "$CC/05/queries.jsonl"
  printf '{"lease":"06","lease_created":"2026-10-04T00:00:00"}\n' > "$CC/06/queries.jsonl"
  LL="$DAEDALUS_HOME/core/leaselib.py"
  python3 "$LL" _test-write 03 '{"lease":"03","session_id":"s3","worktree":"worktrees/03","branch":"lease/03","created":"2026-10-15T00:00:00"}'
  python3 "$LL" _test-write 04 '{"lease":"04","session_id":"s4","worktree":"worktrees/04","branch":"lease/04","created":"2026-10-02T00:00:00","released":true}'
  python3 "$LL" _test-write 06 '{"lease":"06","session_id":"s6","worktree":"worktrees/06","branch":"lease/06","created":"2026-10-04T00:00:00"}'
  run python3 "$CX" reach pkg/core.py
  [ -d "$CC/03" ] && [ -d "$CC/05" ]
  run env DIRECT_CALL_ID=c1 CLAUDE_CODE_SESSION_ID=sC python3 "$CX" reach pkg/core.py
  [ -d "$CC/03" ] && [ -d "$CC/05" ]
  run as_window python3 "$CX" reach pkg/core.py
  [ "$status" -eq 0 ]
  [ ! -e "$CC/03" ]; [ ! -e "$CC/05" ]
  [ -f "$CC/04/queries.jsonl" ]; [ -f "$CC/06/queries.jsonl" ]; [ -f "$CC/02/queries.jsonl" ]
}

@test "a row records every hit when the plain output is truncated; a grep answer over 200 files is marked broad, other verbs never" {
  mkdir -p "$W/many"
  for i in $(seq 1 205); do printf 'import pkg.core\n' > "$W/many/m$i.py"; done
  run as_window python3 "$CX" importers pkg/core.py
  printf '%s\n' "$output" | grep -q '^+.* more — run it again with --json for all of them$'
  run as_window python3 "$CX" grep "import pkg.core"
  python3 - "$Q" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
imp, gr = rows
assert len(imp["hits"]) >= 210 and imp["broad"] is False, (len(imp["hits"]), imp["broad"])
assert len(gr["hits"]) > 200 and gr["broad"] is True, (len(gr["hits"]), gr["broad"])
PY
}
