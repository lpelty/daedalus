#!/usr/bin/env bats
# Pins core/context.py's rules (code-context design §10; Task 4): the release rules in
# core/context-rules.json, deployment rules in vault/context-rules.json, add-only, each with its own test.
bats_require_minimum_version 1.5.0
load fixtures/context/setup.bash
setup() {
  context_fixture
  # the starter rules' real-shape lines, each naming pkg/core.py in a way grep for `helper` cannot see
  printf 'HOOK = ROOT / "pkg" / "core.py"\n' > "$T/tools/call.py"
  printf '#!/bin/bash\npython3 "$(dirname "${BASH_SOURCE[0]}")/core.py" "$@"\n' > "$T/pkg/run.sh"
  printf '#!/bin/bash\npython3 -m pkg.ghost\nGHOST = ROOT / "pkg" / "ghost.py"\n' > "$T/tools/ghost.sh"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m rules
  cd "$DAEDALUS_HOME"
}
teardown() { teardown_live; }

@test "rules --check runs every release rule's own test: four ok lines, the count line, exit 0" {
  run python3 "$CX" rules --check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "ok module-run
ok python-path-join
ok shell-beside
ok template-placeholder
4 rules, 0 fail" ]
}

@test "each starter rule finds its real-shape line and labels the file rule:<name> with the matched text; a candidate that names a missing file is no hit" {
  printf 'context:\n  placeholders: APP=.\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$CX" callers pkg/core.py::helper
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qx 'rule:module-run  tools/run.sh:2  python3 -m pkg.core'
  printf '%s\n' "$output" | grep -qx 'rule:python-path-join  tools/call.py:1  "pkg" / "core.py"'
  printf '%s\n' "$output" | grep -qx 'rule:shell-beside  pkg/run.sh:2  python3 "$(dirname "${BASH_SOURCE\[0\]}")/core.py'
  printf '%s\n' "$output" | grep -qx 'rule:template-placeholder  templates/job.md.tmpl:1  {{APP}}/pkg/core.py'
  case "$output" in *ghost*) echo "a missing module or file was a hit: $output"; return 1 ;; esac
  [ "${lines[${#lines[@]}-1]}" = "8 files: 0 both, 0 graph only, 4 grep only, 4 rule (module-run 1, python-path-join 1, shell-beside 1, template-placeholder 1). These are candidates, not answers: read each file, and let the tests decide." ]
  run python3 "$CX" importers pkg/core.py
  printf '%s\n' "$output" | grep -qx 'grep only     tools/run.sh:2  +rule:module-run'
}

@test "template-placeholder with no context.placeholders adds nothing; a deployment rule's inline map does" {
  run python3 "$CX" callers pkg/core.py::helper
  case "$output" in *templates/job.md.tmpl*) echo "$output"; return 1 ;; esac
  deploy_rules "[$(a_rule app-dir '{{APP}}' '\{\{APP\}\}/([\w./-]+)' '{1}' tree x.tmpl '{{APP}}/a/b.py' '["a/b.py"]')]"
  run python3 "$CX" callers pkg/core.py::helper
  printf '%s\n' "$output" | grep -qx 'rule:app-dir  templates/job.md.tmpl:1  {{APP}}/pkg/core.py'
  deploy_rules "[$(a_rule app-map '{{' '\{\{([A-Z]+)\}\}/([\w./-]+)' '{1:map}/{2}' tree x.tmpl '{{APP}}/b.py' '["src/b.py"]' '{"map": {"APP": "src"}}')]"
  printf 'Run: {{APP}}/core.py\n' > "$T/templates/two.md.tmpl"
  run python3 "$CX" callers pkg/core.py::helper
  case "$output" in *two.md.tmpl*) echo "$output"; return 1 ;; esac
  deploy_rules "[$(a_rule app-map '{{' '\{\{([A-Z]+)\}\}/([\w./-]+)' '{1:map}/{2}' tree x.tmpl '{{APP}}/b.py' '["pkg/b.py"]' '{"map": {"APP": "pkg"}}')]"
  run python3 "$CX" callers pkg/core.py::helper
  printf '%s\n' "$output" | grep -qx 'rule:app-map  templates/two.md.tmpl:1  {{APP}}/core.py'
}

@test "a deployment rule with a release rule's name is skipped with its line; a failing test skips that rule only; a malformed rule skips; rules --check exits 1 naming them" {
  good="$(a_rule tmpl-core 'pkg/core' '(pkg/core\.py)' '{1}' tree a.tmpl 'pkg/core.py' '["pkg/core.py"]')"
  dup="$(a_rule module-run '-m ' '(x)' '{1}' tree a.sh 'x' '["x"]')"
  bad="$(a_rule wrong-test 'pkg/core' '(pkg/core\.py)' '{1}' tree a.tmpl 'pkg/core.py' '["nope.py"]')"
  broken='{"name": "no-hint", "about": "x", "search": "(", "to": "{1}", "resolve": "tree"}'
  deploy_rules "[$good, $dup, $bad, $broken]"
  run python3 "$CX" callers pkg/core.py::helper
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'rule:tmpl-core  templates/job.md.tmpl:1  pkg/core.py'
  printf '%s\n' "$output" | grep -qx 'rule:module-run  tools/run.sh:2  python3 -m pkg.core'
  printf '%s\n' "$output" | grep -qx 'rule module-run skipped: a release rule has that name; rename it'
  printf '%s\n' "$output" | grep -qx 'rule wrong-test skipped: its own test fails (python3 core/context.py rules --check)'
  printf '%s\n' "$output" | grep -q '^rule no-hint skipped: '
  run python3 "$CX" rules --check
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qx 'ok tmpl-core'
  printf '%s\n' "$output" | grep -qx 'FAIL wrong-test: expected \["nope.py"\], got \["pkg/core.py"\]'
  printf '%s\n' "$output" | grep -qx 'FAIL module-run: a release rule has that name; rename it'
  printf '%s\n' "$output" | grep -q '^FAIL no-hint: '
  [ "${lines[${#lines[@]}-1]}" = "8 rules, 3 fail" ]
}

@test "an unreadable vault/context-rules.json skips the deployment rules only, with one line" {
  printf '{not json' > "$DAEDALUS_HOME/vault/context-rules.json"
  run python3 "$CX" callers pkg/core.py::helper
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'rule:module-run  tools/run.sh:2  python3 -m pkg.core'
  [ "$(printf '%s\n' "$output" | grep -c '^rules in vault/context-rules.json skipped: ')" -eq 1 ]
}

@test "the hint picks the files a rule reads: a line the regex would match in a file without the hint is not reported" {
  deploy_rules "[$(a_rule hinted 'CORE-LINK' '(pkg/core\.py)' '{1}' tree a.txt 'CORE-LINK pkg/core.py' '["pkg/core.py"]')]"
  printf 'CORE-LINK pkg/core.py\n' > "$T/with-hint.txt"
  printf 'pkg/core.py\n' > "$T/without-hint.txt"
  run python3 "$CX" callers pkg/core.py::helper
  printf '%s\n' "$output" | grep -qx 'rule:hinted  with-hint.txt:1  pkg/core.py'
  case "$output" in *without-hint.txt*) echo "$output"; return 1 ;; esac
}

@test "rules only add: for random rule sets, each answer's file set is a superset of the answer with no rules" {
  printf 'context:\n  placeholders: APP=.\n' >> "$DAEDALUS_HOME/config.yaml"
  cp "$DAEDALUS_HOME/core/context-rules.json" "$BATS_TEST_TMPDIR/release.json"
  rm "$DAEDALUS_HOME/core/context-rules.json"
  run python3 - "$CX" "$BATS_TEST_TMPDIR/release.json" "$DAEDALUS_HOME/vault/context-rules.json" <<'PY'
import json, random, subprocess, sys
cx, release, vault = sys.argv[1:4]
rules = json.load(open(release))["rules"]
extra = {"name": "tmpl-core", "about": "x", "hint": "pkg/core", "search": "(pkg/core\\.py)", "to": "{1}", "resolve": "tree",
         "origin": {"date": "2026-10-20", "window": "02", "why": "x"},
         "test": {"file": "a.tmpl", "text": "pkg/core.py", "expect": ["pkg/core.py"]}}
pool = [dict(r, name="d-" + r["name"]) for r in rules] + [extra]
def answer(verb, arg):
    out = subprocess.run(["python3", cx, verb, arg, "--json"], capture_output=True, text=True).stdout
    return {h["file"] for h in json.loads(out)["hits"]}
asks = [("callers", "pkg/core.py::helper"), ("importers", "pkg/core.py"), ("reach", "pkg/core.py")]
base = {a: answer(*a) for a in asks}
rng = random.Random(9)
for _ in range(6):
    chosen = rng.sample(pool, rng.randint(1, len(pool)))
    json.dump({"format": 1, "rules": chosen}, open(vault, "w"))
    for a in asks:
        got = answer(*a)
        assert base[a] <= got, (a, [r["name"] for r in chosen], base[a] - got)
print("ok")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a catastrophic deployment regex times out the rules worker: the answer still prints its grep hits and the timed-out line, inside the budget" {
  deploy_rules "[$(a_rule slow 'aaaa' '(a+)+$' '{1}' tree a.txt 'aaa' '["aaa"]')]"
  printf '%sb\n' "$(printf 'a%.0s' $(seq 1 40))" > "$T/slow.txt"
  t0=$(date +%s)
  run env DAEDALUS_CONTEXT_TEST_RULES_TIMEOUT=2 python3 "$CX" callers pkg/core.py::helper
  [ "$status" -eq 0 ]; [ $(( $(date +%s) - t0 )) -lt 8 ]
  printf '%s\n' "$output" | grep -q '^grep only     pkg/user.py:1$'
  printf '%s\n' "$output" | grep -qx 'rules timed out after 2 s, so this answer has no rule hits; python3 core/context.py rules --check lists them'
  sleep 0.2; [ -z "$(pgrep -f "$CX --rules-worker")" ]
}
