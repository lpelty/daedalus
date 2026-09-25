#!/usr/bin/env bats
#
# The refuter charter is distribution code: core/agents/refuter.md, under the
# same Edit(./core/**) deny rule as everything else in core/. refute.sh
# renders it with core/agentdef.py and hands the JSON to `claude --agents`.
# These tests pin the charter's shape (the restrictions that make it a
# second opinion and not a second author) and the renderer's grammar.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHARTER="$SRC/agents/refuter.md"
  RENDER="$SRC/agentdef.py"
  PITFALLS="$SRC/refute-pitfalls.py"
  FIX="$BATS_TEST_DIRNAME/fixtures/pitfalls"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/vault/pitfalls"
  cp "$SRC/lib.sh" "$SRC/pitfall-inject.py" "$SRC/refute-pitfalls.py" "$DAEDALUS_HOME/core/"
  cat > "$DAEDALUS_HOME/config.yaml" <<'CFG'
target:
  repo: https://example.com/thing.git
  branch: main
CFG
  export DAEDALUS_HOME
}

field() {   # field <json-path expression over the rendered refuter object>
  python3 "$RENDER" "$CHARTER" | python3 -c '
import json, sys
d = json.load(sys.stdin)["refuter"]
print(eval(sys.argv[1], {"d": d}))' "$1"
}

@test "the real charter renders: name refuter, read-only tools, no Bash/Edit/Write, a pinned model, bounded turns, omitClaudeMd requested, no memory" {
  run python3 "$RENDER" "$CHARTER"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | python3 -c 'import json,sys; print(list(json.load(sys.stdin)))')" = "['refuter']" ]
  [ "$(field 'sorted(d["tools"])')" = "['Glob', 'Grep', 'Read']" ]
  for t in Bash Edit Write; do
    [ "$(field "'$t' in d['tools']")" = "False" ]
    [ "$(field "'$t' in d['disallowedTools']")" = "True" ]
  done
  # A model is pinned (not inherited from whoever runs gates.sh); which one is
  # the charter's business, not an invariant of the reviewer.
  [ -n "$(field 'd["model"]')" ] && [ "$(field 'd["model"]')" != "inherit" ]
  [ "$(field 'isinstance(d["maxTurns"], int) and 15 <= d["maxTurns"] <= 40')" = "True" ]
  [ "$(field 'd["omitClaudeMd"]')" = "True" ]
  # Fresh context every run is the point: no persistent memory field.
  [ "$(field '"memory" in d')" = "False" ]
  [ "$(field 'len(d["description"]) > 20')" = "True" ]
}

@test "the charter's prompt carries the method, the rules, the rubric and the exact verdict grammar" {
  prompt="$(field 'd["prompt"]')"
  for needle in 'Never validate' 'Never summarize' 'Refuse to guess' 'overconfident' 'never STANDS' \
                'Correctness' 'Regression risk' 'Test honesty' 'Pitfall and boundary compliance' 'Claim' \
                'How to confirm' 'VERDICT: REFUTED' 'VERDICT: STANDS'; do
    [ "$(printf '%s\n' "$prompt" | grep -cF -- "$needle")" -ge 1 ] || { echo "charter prompt lacks: $needle"; return 1; }
  done
  # The frontmatter is not part of the prompt.
  [ "$(printf '%s\n' "$prompt" | grep -c '^model: ')" -eq 0 ]
  [ "$(printf '%s\n' "$prompt" | grep -c '^name: refuter')" -eq 0 ]
}

@test "the renderer refuses a file that is not an agent definition, naming the reason" {
  printf 'no frontmatter here\n' > "$BATS_TEST_TMPDIR/a.md"
  run python3 "$RENDER" "$BATS_TEST_TMPDIR/a.md"
  [ "$status" -eq 1 ]; [ "$(printf '%s\n' "$output" | grep -c 'no frontmatter')" -eq 1 ]
  printf -- '---\ndescription: x\n---\nbody\n' > "$BATS_TEST_TMPDIR/b.md"
  run python3 "$RENDER" "$BATS_TEST_TMPDIR/b.md"
  [ "$status" -eq 1 ]; [ "$(printf '%s\n' "$output" | grep -c 'name is required')" -eq 1 ]
  printf -- '---\nname: r\ndescription: x\nmaxTurns: many\n---\nbody\n' > "$BATS_TEST_TMPDIR/c.md"
  run python3 "$RENDER" "$BATS_TEST_TMPDIR/c.md"
  [ "$status" -eq 1 ]; [ "$(printf '%s\n' "$output" | grep -c 'maxTurns must be an integer')" -eq 1 ]
  printf -- '---\nname: r\ndescription: x\n---\n\n' > "$BATS_TEST_TMPDIR/d.md"
  run python3 "$RENDER" "$BATS_TEST_TMPDIR/d.md"
  [ "$status" -eq 1 ]; [ "$(printf '%s\n' "$output" | grep -c 'prompt body is empty')" -eq 1 ]
  run python3 "$RENDER" "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 1 ]
}

@test "the renderer's grammar: comma lists, integers, booleans, quoted scalars, body verbatim" {
  cat > "$BATS_TEST_TMPDIR/e.md" <<'AGENT'
---
name: probe
description: "quoted: with a colon"
tools: Read,Grep , Glob
disallowedTools: Bash
maxTurns: 3
omitClaudeMd: false
---
line one

line two
AGENT
  run python3 "$RENDER" "$BATS_TEST_TMPDIR/e.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c '
import json, sys
d = json.load(sys.stdin)["probe"]
assert d["description"] == "quoted: with a colon", d
assert d["tools"] == ["Read", "Grep", "Glob"], d
assert d["disallowedTools"] == ["Bash"], d
assert d["maxTurns"] == 3 and d["omitClaudeMd"] is False, d
assert d["prompt"] == "line one\n\nline two\n", repr(d["prompt"])
assert "name" not in d
'
}

@test "refute-pitfalls picks path-matched pitfalls and applies-to-less pitfalls; skips bash-only and unparseable ones" {
  cp "$FIX/aa-bad-timeout.md" "$FIX/bb-bats-brackets.md" "$FIX/cc-flow-list.md" "$DAEDALUS_HOME/vault/pitfalls/"
  printf -- '---\ntype: pitfall\n---\n# Waits to be asked\n\nA lesson with no trigger.\n\nSecond paragraph too.\n' > "$DAEDALUS_HOME/vault/pitfalls/zz-no-trigger.md"
  printf 'core/tests/x.bats\nREADME.md\n' > "$BATS_TEST_TMPDIR/paths"
  run python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" "$BATS_TEST_TMPDIR/paths"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF '### Pitfall: A non-final double-bracket assertion is silently ignored')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF '### Pitfall: Waits to be asked')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'Second paragraph too.')" -eq 1 ]     # whole body, not the first paragraph
  [ "$(printf '%s\n' "$output" | grep -cF 'timeout command is absent')" -eq 0 ]  # bash-only: not about files
  [ "$(printf '%s\n' "$output" | grep -cF 'flow list')" -eq 0 ]                  # unparseable: skipped
  [ "$(printf '%s\n' "$output" | grep -c '^enforce:')" -eq 0 ]                  # frontmatter stripped
  # Positive control on the path match: a diff that touches no .bats file drops bb.
  printf 'README.md\n' > "$BATS_TEST_TMPDIR/paths2"
  run python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" "$BATS_TEST_TMPDIR/paths2"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'double-bracket')" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'Waits to be asked')" -eq 1 ]
  # An empty diff, no trigger-less pitfalls: nothing at all.
  rm "$DAEDALUS_HOME/vault/pitfalls/zz-no-trigger.md"
  : > "$BATS_TEST_TMPDIR/paths3"
  run python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" "$BATS_TEST_TMPDIR/paths3"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  run python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" "$BATS_TEST_TMPDIR/missing-paths-file"
  [ "$status" -eq 1 ]
}
