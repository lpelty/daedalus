#!/usr/bin/env bats
# Pins the misses promote computes (code-context design §9; Task 6): the files window 02 changed and the
# tests that failed in its gate runs, set against what its queries named; each miss logged with its kind,
# one line in the record paragraph, and promote never stopped by it.
bats_require_minimum_version 1.5.0
load fixtures/promote/setup.bash
setup() {
  promote_fixture
  # On trunk: A, B, D (imports B), E (a template naming B), the tests, a README.
  local o="$BATS_TEST_TMPDIR/base"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$o"
  mkdir -p "$o/pkg" "$o/templates" "$o/tests"
  printf 'def fa():\n    return None\n' > "$o/pkg/a.py"
  printf 'def fb():\n    return None\n' > "$o/pkg/b.py"
  printf 'import pkg.b\n' > "$o/pkg/d.py"
  printf 'Run {{APP}}/pkg/b.py\n' > "$o/templates/e.md.tmpl"
  printf 'from pkg.a import fa\n\n\ndef test_f():\n    assert fa() is None\n' > "$o/tests/test_f.py"
  printf 'def test_g():\n    pass\n' > "$o/tests/test_g.py"
  printf 'hello\n' > "$o/README.md"
  git -C "$o" add -A; git -C "$o" -c user.email=t@x -c user.name=t commit -q -m base; git -C "$o" push -q origin HEAD:main
  git -C "$T" fetch -q origin; git -C "$W2" merge -q --ff-only origin/main
  MISSES="$DAEDALUS_HOME/state/code-context/misses.jsonl"; mkdir -p "$DAEDALUS_HOME/state/code-context"
}
teardown() { teardown_live; }

# predict <file>... — one row in window 02's query log whose subject is these files and nothing else.
predict() {
  python3 - "$DAEDALUS_HOME" "$@" <<'PY'
import json, os, sys
home, files = sys.argv[1], sys.argv[2:]
lease = json.load(open(home + "/state/leases/02.json"))
os.makedirs(home + "/state/code-context/02", exist_ok=True)
row = {"at": "2026-10-16T12:00:00Z", "lease": "02", "lease_created": lease.get("created"), "session_id": "sC",
       "verb": "reach", "arg": files[0], "repo": "thing", "subject_files": files, "hits": [], "graph": "absent",
       "rules": [], "broad": False}
with open(home + "/state/code-context/02/queries.jsonl", "a") as fh:
    fh.write(json.dumps(row) + "\n")
PY
}
# fail_run <log text> — a FAIL gate run of window 02 (not a promote's), started after its lease was created.
fail_run() {
  python3 - "$DAEDALUS_HOME" "$1" <<'PY'
import json, os, sys, time, random
home, text = sys.argv[1:3]
rid = "20991231-000000-%06x" % random.randrange(1 << 24)
d = os.path.join(home, "state", "evidence", rid); os.makedirs(d)
log = os.path.join(d, "gate-1.log"); open(log, "w").write(text + "\n")
json.dump({"run_id": rid, "started": time.strftime("%Y-%m-%dT%H:%M:%S"), "lease": "02", "result": "FAIL",
           "gates": [{"n": 1, "command": "pytest", "exit": 1, "duration_s": 1, "log": log}]}, open(os.path.join(d, "run.json"), "w"))
PY
}
# the window's work: A changed, C added, D deleted, E changed, README changed, a new test added
the_work() {
  printf 'def fa():\n    return 1\n' > "$W2/pkg/a.py"
  printf 'def fc():\n    pass\n' > "$W2/pkg/c.py"
  git -C "$W2" rm -q pkg/d.py
  printf 'Run {{APP}}/pkg/b.py v2\n' > "$W2/templates/e.md.tmpl"
  printf 'hello again\n' > "$W2/README.md"
  printf 'def test_new():\n    assert False\n' > "$W2/tests/test_new.py"
  git -C "$W2" add -A; git -C "$W2" commit -q -m "the work"
}
LOG_ONE='tests/test_g.py .                                                   [ 33%]
tests/test_f.py F                                                   [ 66%]
tests/test_new.py F                                                 [100%]
FAILED tests/test_f.py::test_f - assert 1 is None
FAILED tests/test_new.py::test_new - assert False'
record_of() { printf '%s\n' "$output" | awk 'BEGIN{p=0} /^$/{p++; next} p==1'; }

@test "the misses are D (other), E (template path), the failed linked test (other) and README (unasked); C, a test on a passing line and a test the merge adds are not; the record paragraph ends with the line; the rows and the summary are logged" {
  the_work; predict pkg/a.py; predict pkg/b.py; fail_run "$LOG_ONE"
  run as_prime bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  want="Code context: 3 changed files and 1 failed test no query named — pkg/d.py (other), templates/e.md.tmpl (template path), tests/test_f.py (other) and 1 more; the log is state/code-context/misses.jsonl."
  [ "$(record_of | tail -1)" = "$want" ] || { echo "$output"; return 1; }
  [ "$(record_of | wc -l | tr -d ' ')" -eq 4 ]
  [ "$(pj context_line)" = "$want" ]
  python3 - "$MISSES" "$(prepared)" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
p = json.load(open(sys.argv[2]))
miss = {r["file"]: (r["source"], r["kind"]) for r in rows if r["kind"] != "summary"}
assert miss == {"pkg/d.py": ("changed", "other"), "templates/e.md.tmpl": ("changed", "template path"),
                "tests/test_f.py": ("failed-test", "other"), "README.md": ("changed", "unasked")}, miss
m = next(r for r in rows if r.get("file") == "templates/e.md.tmpl")
assert m["promote_id"] == p["promote_id"] and m["lease"] == "02" and m["lease_created"] == p["lease_created"], m
assert m["repo"] == "thing" and m["queries"] == 2 and m["evidence"] == "templates/e.md.tmpl", m
s = [r for r in rows if r["kind"] == "summary"]
assert len(s) == 1, s
s = s[0]
for k, want in (("queries", 2), ("predicted", 2), ("predicted_rule_only", 0), ("broad_queries", 0), ("changed", 4),
                ("failed_tests", 1), ("misses", 4), ("runs_too_broad", 0)):
    assert s[k] == want, (k, s)
assert p["context_misses"] == {"count": 4, "kinds": {"other": 2, "template path": 1, "unasked": 1}}, p["context_misses"]
PY
}

@test "a kind missed in another window is counted: also missed in 1 earlier window; retries of one window count once" {
  for i in 1 2; do
    printf '{"kind": "template path", "lease": "03", "lease_created": "2026-10-01T00:00:00", "file": "x.tmpl", "source": "changed"}\n' >> "$MISSES"
  done
  printf '{"kind": "unasked", "lease": "04", "lease_created": "2026-10-01T00:00:00", "file": "README.md", "source": "changed"}\n' >> "$MISSES"
  the_work; predict pkg/a.py; predict pkg/b.py
  run as_prime bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$(record_of | tail -1)" in *"templates/e.md.tmpl (template path, also missed in 1 earlier window), "*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the stored line is what decision_block renders, even after other windows' misses are appended; a pre-0.9.0 prepared.json renders as before; confirm with a transcribed yes still succeeds" {
  the_work; predict pkg/a.py; predict pkg/b.py
  run as_prime bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  line="$(pj context_line)"
  printf '{"kind": "template path", "lease": "05", "lease_created": "2026-10-02T00:00:00", "file": "y.tmpl", "source": "changed"}\n' >> "$MISSES"
  run python3 - "$DAEDALUS_HOME" "$(prepared)" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1] + "/core")
import promote
from pathlib import Path
p = json.load(open(sys.argv[2]))
_, rec = promote.decision_block(Path(sys.argv[1]), p)
print(rec.splitlines()[-1])
del p["context_line"]
_, rec = promote.decision_block(Path(sys.argv[1]), p)
print(len(rec.splitlines()))
print(rec.splitlines()[-1])
PY
  [ "${lines[0]}" = "$line" ]
  [ "${lines[1]}" = 3 ]
  case "${lines[2]}" in "fingerprint of what will be pushed "*) : ;; *) echo "$output"; return 1 ;; esac
  shown_then_said "Yes, push it."
  run --separate-stderr as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes, push it"
  [ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
  [ "$(origin_main)" = "$(pj merge_sha)" ]
}

@test "a window that ran no queries gives the no-queries line and its one row; every changed file named gives the all-named line" {
  the_work
  run as_prime bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(record_of | tail -1)" = "Code context: window 02 ran no code-context queries, so there is nothing to compare." ]
  python3 -c 'import json,sys; rows=[json.loads(l) for l in open(sys.argv[1])]; k=[r["kind"] for r in rows]; assert k == ["no-queries", "summary"], k; assert rows[0]["queries"] == 0' "$MISSES"
  predict pkg/a.py pkg/d.py templates/e.md.tmpl README.md
  run as_prime bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(record_of | tail -1)" = "Code context: every changed file and failed test was named by window 02's 1 query." ]
}

@test "an exception inside misses() gives the not-computed line, and promote still prints the block and exits 0" {
  the_work; predict pkg/a.py
  run env DAEDALUS_CONTEXT_TEST_DIE=misses CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sP bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(record_of | tail -1)" = "Code context: misses not computed (test knob); promote is unaffected." ]
  case "$output" in *"Say yes to push window 02's work to main."*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- the classifier and the budgets, on a scratch tree built by hand -----------------------------------

# scratch <file>=<text>... — state/promote/px/thing: a repo whose first commit (the trunk) holds the files
# named; changes come after, then `merged` commits them. P_ARGS is the prepared record misses() reads.
scratch() {
  S="$DAEDALUS_HOME/state/promote/px/thing"; mkdir -p "$S"; git init -q -b main "$S"
  local kv
  for kv in "$@"; do mkdir -p "$S/$(dirname "${kv%%=*}")"; printf '%s\n' "${kv#*=}" > "$S/${kv%%=*}"; done
  git -C "$S" add -A; git -C "$S" -c user.email=t@x -c user.name=t commit -q -m trunk
  BASE="$(git -C "$S" rev-parse HEAD)"
}
merged() { git -C "$S" add -A; git -C "$S" -c user.email=t@x -c user.name=t commit -q -m merge; HEADSHA="$(git -C "$S" rev-parse HEAD)"; }
call_misses() {
  python3 - "$DAEDALUS_HOME" "$BASE" "$HEADSHA" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("created"))' "$DAEDALUS_HOME/state/leases/02.json")" <<'PY'
import json, sys
from pathlib import Path
home, base, head, created = sys.argv[1:5]
sys.path.insert(0, home + "/core")
import context as cc
p = {"promote_id": "02-px", "lease": "02", "lease_created": created, "repo": "thing",
     "trunk_sha_at_prepare": base, "merge_sha": head}
line, info = cc.misses(Path(home), p, Path(home) / "state" / "promote" / "px")
print(line)
print(json.dumps(info))
PY
}
kind_of() {   # kind_of <miss> [predicted...] — the kind and evidence the classifier gives <miss> in the scratch
  python3 - "$DAEDALUS_HOME" "$S" "$@" <<'PY'
import sys
from pathlib import Path
home, s, m = sys.argv[1:4]
sys.path.insert(0, home + "/core")
import context as cc
tree = cc.Tree(Path(s), "thing", [])
kind, ev = cc.kind_of(tree, m, set(sys.argv[4:]), cc.module_roots(tree, cc.Cfg()))
print("%s|%s" % (kind, ev))
PY
}

@test "the classifier: one unit test per kind, first match wins" {
  scratch 'x/run.py=print(1)' 'gen/job.md.tmpl=python3 {{ENGINE}}/x/run.py' 'app/pkg/tool.py=X=1' 'bin/go.sh=cd app && uv run -m pkg.tool' \
          'hooks/cap.py=Y=1' 'conf/hooks.yaml=script: hooks/cap.py' 'lib/w.py=W=1' 'tools/call.py=H = ROOT / "lib" / "w.py"' \
          'bin/s.py=S=1' 'bin/runner.sh=python3 bin/s.py' 'bin/t.py=T=1' 'bin/launch=#!/bin/bash' 'z/other.py=Z=1' 'z/notes.md=see z/other.py' \
          'gen/x.md.tmpl=just text' 'conf/z.toml=k = 1'
  printf '#!/bin/bash\npython3 bin/t.py "$@"\n' > "$S/bin/launch"; git -C "$S" add -A; git -C "$S" -c user.email=t@x -c user.name=t commit -q -m launch
  [ "$(kind_of x/run.py)" = "template path|gen/job.md.tmpl:1" ]
  [ "$(kind_of gen/x.md.tmpl)" = "template path|gen/x.md.tmpl" ]
  [ "$(kind_of app/pkg/tool.py)" = "uv run -m|bin/go.sh:1" ]
  [ "$(kind_of hooks/cap.py)" = "manifest/config key|conf/hooks.yaml:1" ]
  [ "$(kind_of conf/z.toml)" = "manifest/config key|conf/z.toml" ]
  [ "$(kind_of lib/w.py)" = "python path join|tools/call.py:1" ]
  [ "$(kind_of bin/s.py)" = "shell python invocation|bin/runner.sh:1" ]
  [ "$(kind_of bin/t.py)" = "shell python invocation|bin/launch:2" ]
  [ "$(kind_of z/other.py)" = "other|" ]
}

@test "classifying stops after 50 misses: the rest are other, not classified (budget)" {
  local kv=() i
  kv+=('pkg/hub.py=H=1')
  for i in $(seq 1 55); do kv+=("pkg/m$i.py=import pkg.hub"); done
  scratch "${kv[@]}"
  for i in $(seq 1 55); do printf 'import pkg.hub\nX = %s\n' "$i" > "$S/pkg/m$i.py"; done
  merged
  predict pkg/hub.py
  run call_misses
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 - "$MISSES" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["kind"] != "summary"]
assert len(rows) == 55, len(rows)
budget = [r for r in rows if r["evidence"] == "not classified (budget)"]
assert len(budget) == 5 and all(r["kind"] == "other" for r in budget), budget
PY
}

@test "a gate run naming more than 10 failing test files is dropped whole and counted in runs_too_broad" {
  local kv=() i
  kv+=('pkg/hub.py=H=1')
  for i in $(seq 1 11); do kv+=("tests/test_t$i.py=import pkg.hub"); done
  scratch "${kv[@]}"
  printf 'H = 2\n' > "$S/pkg/hub.py"; merged
  predict pkg/hub.py
  log=""; for i in $(seq 1 11); do log="$log
FAILED tests/test_t$i.py::test_x - boom"; done
  fail_run "$log"
  run call_misses
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Code context: every changed file and failed test was named by window 02's 1 query." ]
  python3 -c 'import json,sys; s=[json.loads(l) for l in open(sys.argv[1])][-1]; assert s["kind"] == "summary" and s["runs_too_broad"] == 1 and s["failed_tests"] == 0, s' "$MISSES"
}

@test "when every miss is unasked the line says no query was near; more than half the predicted set from rules alone is noted" {
  scratch 'pkg/hub.py=H=1' 'README.md=hello' 'docs/x.md=notes' 'pkg/r1.py=R=1' 'pkg/r2.py=R=2' 'pkg/r3.py=R=3'
  printf 'hello again\n' > "$S/README.md"; printf 'more notes\n' > "$S/docs/x.md"; merged
  python3 - "$DAEDALUS_HOME" <<'PY'
import json, os, sys
home = sys.argv[1]
lease = json.load(open(home + "/state/leases/02.json"))
os.makedirs(home + "/state/code-context/02", exist_ok=True)
row = {"lease": "02", "lease_created": lease.get("created"), "verb": "reach", "subject_files": ["pkg/hub.py"],
       "hits": [["pkg/r1.py", "rule:module-run"], ["pkg/r2.py", "rule:module-run"], ["pkg/r3.py", "rule:shell-beside"]],
       "broad": False}
open(home + "/state/code-context/02/queries.jsonl", "a").write(json.dumps(row) + "\n")
PY
  run call_misses
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Code context: 2 changed files no query was near (unasked) — README.md, docs/x.md (3 of 4 predicted files came from rules alone); the log is state/code-context/misses.jsonl." ]
}
