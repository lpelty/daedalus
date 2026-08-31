#!/usr/bin/env bats
#
# Pins the pitfall trigger's contract: block never depends on state, warn
# degrades visibly rather than to silence, and every negative assertion is
# paired with a positive control so a crashed hook cannot pass as precision.
# Assertions use [ ] only — a non-final [[ ]] is decorative under bash 3.2.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/vault/pitfalls" \
           "$DAEDALUS_HOME/target/thing/sub" "$DAEDALUS_HOME/state"
  cp "$SRC/lib.sh" "$SRC/pitfall-inject.py" "$DAEDALUS_HOME/core/"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  export DAEDALUS_HOME
  SCRIPT="$DAEDALUS_HOME/core/pitfall-inject.py"
  FIX="$BATS_TEST_DIRNAME/fixtures/pitfalls"
  TARGET="$DAEDALUS_HOME/target/thing"
}

# use_fixture <name>... — copy named fixture pitfalls into the fixture vault.
use_fixture() {
  local n
  for n in "$@"; do cp "$FIX/$n.md" "$DAEDALUS_HOME/vault/pitfalls/"; done
}

# hook <json> [session] [agent] — run the hook as Claude Code would.
hook() {
  printf '%s' "$1" | python3 "$SCRIPT"
}

bash_call() {   # bash_call <command> [session_id] [agent_id]
  local cmd="$1" sid="${2:-s1}" aid="${3:-}"
  local agent=""
  [ -n "$aid" ] && agent=", \"agent_id\": \"$aid\""
  printf '{"hook_event_name":"PreToolUse","session_id":"%s"%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$sid" "$agent" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$cmd")"
}

edit_call() {   # edit_call <abs-file-path> [session_id] [agent_id]
  local p="$1" sid="${2:-s1}" aid="${3:-}"
  local agent=""
  [ -n "$aid" ] && agent=", \"agent_id\": \"$aid\""
  printf '{"hook_event_name":"PreToolUse","session_id":"%s"%s,"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
    "$sid" "$agent" "$p"
}

count() {       # count <literal> — occurrences of <literal> in $output
  printf '%s\n' "$output" | grep -cF -- "$1"
}

denied() {      # denied — $output is a deny decision
  [ "$(count '"permissionDecision": "deny"')" -gt 0 ]
}

@test "--parse reads a plain pitfall: heading title, first paragraph, patterns, enforce" {
  run python3 "$SCRIPT" --parse "$FIX/aa-bad-timeout.md"
  [ "$status" -eq 0 ]
  [ "$(count '"title": "The timeout command is absent on this platform"')" -eq 1 ]
  [ "$(count '"first_paragraph": "Use a background process plus a polling loop instead."')" -eq 1 ]
  [ "$(count '"enforce": "warn"')" -eq 1 ]
  [ "$(count 'timeout\\s+')" -eq 1 ]
}

@test "--parse rejects a flow list and names the reason" {
  run python3 "$SCRIPT" --parse "$FIX/cc-flow-list.md"
  [ "$status" -eq 0 ]
  [ "$(count '"unparseable"')" -eq 1 ]
  [ "$(count 'flow list')" -eq 1 ]
}

@test "--parse: title field wins over heading; both quote styles; bare-item comment stripped" {
  run python3 "$SCRIPT" --parse "$FIX/dd-quotes.md"
  [ "$status" -eq 0 ]
  [ "$(count '"title": "A title: with a colon"')" -eq 1 ]
  [ "$(count "it's #not a comment")" -eq 1 ]
  [ "$(count 'back\\slash \"quoted\"')" -eq 1 ]
  [ "$(count '"plain"')" -eq 1 ]
  [ "$(count 'this comment is stripped')" -eq 0 ]
  [ "$(count '"first_paragraph": "First paragraph line one line two."')" -eq 1 ]
}

@test "--parse: CRLF and BOM are stripped; duplicate key and unknown enforce are unparseable" {
  printf '\xEF\xBB\xBF---\r\ntype: pitfall\r\nenforce: inject\r\n---\r\n# T\r\n\r\nP.\r\n' > "$BATS_TEST_TMPDIR/crlf.md"
  run python3 "$SCRIPT" --parse "$BATS_TEST_TMPDIR/crlf.md"
  [ "$(count '"title": "T"')" -eq 1 ]
  printf -- '---\ntype: pitfall\ntype: pitfall\n---\n# T\n' > "$BATS_TEST_TMPDIR/dup.md"
  run python3 "$SCRIPT" --parse "$BATS_TEST_TMPDIR/dup.md"
  [ "$(count 'duplicate key')" -eq 1 ]
  printf -- '---\nenforce: sometimes\n---\n# T\n' > "$BATS_TEST_TMPDIR/enf.md"
  run python3 "$SCRIPT" --parse "$BATS_TEST_TMPDIR/enf.md"
  [ "$(count 'enforce')" -gt 0 ]
  [ "$(count '"unparseable"')" -eq 1 ]
}

@test "glob table: positives and negatives per row" {
  cat > "$DAEDALUS_HOME/vault/pitfalls/gg-globs.md" <<'EOF'
---
type: pitfall
applies-to:
  path:
    - '**/*.bats'
    - '**/hooks/**'
    - 'a/**/b'
    - 'settings*.json'
    - 'x?y'
---
# Globs

Body.
EOF
  run python3 "$SCRIPT" --parse "$DAEDALUS_HOME/vault/pitfalls/gg-globs.md"
  [ "$status" -eq 0 ]
  [ "$(count '"unparseable"')" -eq 0 ]
  # Positives, then negatives, through --match-glob <glob> <relpath>.
  for pair in '**/*.bats|x.bats' '**/*.bats|a/b/x.bats' '**/hooks/**|x/hooks' \
              '**/hooks/**|x/hooks/capture.py' 'a/**/b|a/b' 'a/**/b|a/x/y/b' \
              'settings*.json|settings.json' 'settings*.json|settings.local.json' 'x?y|xzy'; do
    run python3 "$SCRIPT" --match-glob "${pair%%|*}" "${pair#*|}"
    [ "$output" = "match" ]
  done
  for pair in '**/*.bats|x.batsx' '*.bats|a/x.bats' '**/hooks/**|x/hooksy' 'a/**/b|a/bb' \
              'settings*.json|settingsXjson' 'x?y|x/y'; do
    run python3 "$SCRIPT" --match-glob "${pair%%|*}" "${pair#*|}"
    [ "$output" = "no match" ]
  done
}

@test "glob table: brackets, braces, bare **, leading slash are unparseable and named" {
  for g in '**/*.{py,sh}' 'a[bc]' 'a**b' '/abs/x' './rel/x'; do
    run python3 "$SCRIPT" --match-glob "$g" "anything"
    [ "$(count 'unparseable')" -eq 1 ]
  done
}

@test "path relativity: target root from lib.sh target_path, resolved through symlinks" {
  ln -s "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR/link"
  export DAEDALUS_HOME="$BATS_TEST_TMPDIR/link"
  # A lexically earlier directory under target/ must not win.
  mkdir -p "$BATS_TEST_TMPDIR/link/target/aaa/.git"
  run python3 "$SCRIPT" --match-path "$BATS_TEST_TMPDIR/link/target/thing/sub/x.bats"
  [ "$output" = "sub/x.bats" ]
  run python3 "$SCRIPT" --match-path "$TARGET/x.bats"
  [ "$output" = "x.bats" ]
  run python3 "$SCRIPT" --match-path "$BATS_TEST_TMPDIR/link/vault/hot.md"
  [ "$output" = "vault/hot.md" ]
  run python3 "$SCRIPT" --match-path "$BATS_TEST_TMPDIR/elsewhere/x.bats"
  [ "$output" = "outside" ]
  run python3 "$SCRIPT" --match-path "relative/x.bats"
  [ "$output" = "outside" ]
}

@test "warn: denied with trailer, retry allowed and injected, new session denied again" {
  use_fixture aa-bad-timeout
  run hook "$(bash_call 'timeout 30 sleep 1')"
  [ "$status" -eq 0 ]
  denied
  [ "$(count 'The timeout command is absent on this platform')" -gt 0 ]
  [ "$(count 'One-time warning for this session')" -eq 1 ]
  run hook "$(bash_call 'timeout 30 sleep 1')"
  [ "$(count '"permissionDecision"')" -eq 0 ]
  [ "$(count '"additionalContext"')" -eq 1 ]
  [ "$(count 'Pitfall: The timeout command is absent on this platform')" -eq 1 ]
  run hook "$(bash_call 'timeout 30 sleep 1' s2)"
  denied
}

@test "precision with control: connect-timeout allowed; -k form and \$N form denied" {
  use_fixture aa-bad-timeout
  run hook "$(bash_call 'curl --connect-timeout 5 http://x')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run hook "$(bash_call 'timeout -k 5 10 x')"
  denied
  run hook "$(bash_call 'timeout $N x' s3)"
  denied
}

@test "block ignores state: seeded injected, seeded warned, unwritable state" {
  cat > "$DAEDALUS_HOME/vault/pitfalls/ee-block.md" <<'EOF'
---
type: pitfall
applies-to:
  bash:
    - 'rm -rf /'
enforce: block
---
# Never remove the root

Body.
EOF
  f="$DAEDALUS_HOME/vault/pitfalls/ee-block.md"
  for stage in injected warned; do
    printf '{"s1:main": {"%s": {"stage": "%s", "touched": "2026-01-01T00:00:00"}}}' "$f" "$stage" \
      > "$DAEDALUS_HOME/state/pitfall-seen.json"
    run hook "$(bash_call 'rm -rf /')"
    denied
    [ "$(count 'Never remove the root')" -gt 0 ]
  done
  chmod 500 "$DAEDALUS_HOME/state"
  run hook "$(bash_call 'rm -rf /')"
  chmod 700 "$DAEDALUS_HOME/state"
  denied
}

@test "warn without state degrades to a visible inject, never silence, never a second deny" {
  use_fixture aa-bad-timeout
  rm -rf "$DAEDALUS_HOME/state"
  touch "$DAEDALUS_HOME/state"          # a file where the directory should be: mkdir -p fails
  run hook "$(bash_call 'timeout 30 sleep 1')"
  [ "$status" -eq 0 ]
  [ "$(count '"permissionDecision"')" -eq 0 ]
  [ "$(count 'Pitfall: The timeout command is absent')" -eq 1 ]
  [ "$(count 'warn degraded: state/ unwritable')" -eq 1 ]
  rm -f "$DAEDALUS_HOME/state"
}

@test "path edit fires the bats pitfall at root and nested; outside both roots is silent (with control)" {
  use_fixture bb-bats-brackets
  run hook "$(edit_call "$TARGET/x.bats")"
  denied
  run hook "$(edit_call "$TARGET/sub/deep/x.bats" s2)"
  denied
  run hook "$(edit_call "$BATS_TEST_TMPDIR/elsewhere/x.bats" s3)"
  [ -z "$output" ]
  run hook "$(edit_call "$TARGET/x.bats" s3)"
  denied
}

@test "subagent isolation: seen for main still fires for a subagent" {
  use_fixture aa-bad-timeout
  run hook "$(bash_call 'timeout 30 x')"
  run hook "$(bash_call 'timeout 30 x')"
  [ "$(count '"permissionDecision"')" -eq 0 ]
  run hook "$(bash_call 'timeout 30 x' s1 sub-1)"
  denied
}

@test "cap and order: five injects yield exactly the first three by filename" {
  local n
  for n in 1 2 3 4 5; do
    cat > "$DAEDALUS_HOME/vault/pitfalls/p$n.md" <<EOF
---
type: pitfall
applies-to:
  bash:
    - 'echo'
---
# Pitfall number $n

Body $n.
EOF
  done
  run hook "$(bash_call 'echo hi')"
  [ "$(count 'Pitfall: Pitfall number 1')" -eq 1 ]
  [ "$(count 'Pitfall: Pitfall number 2')" -eq 1 ]
  [ "$(count 'Pitfall: Pitfall number 3')" -eq 1 ]
  [ "$(count 'Pitfall number 4')" -eq 0 ]
  [ "$(count 'Pitfall number 5')" -eq 0 ]
  run hook "$(bash_call 'echo hi')"
  [ "$(count 'Pitfall number 4')" -eq 1 ]
  [ "$(count 'Pitfall number 5')" -eq 1 ]
}

@test "two warns on one call: one deny naming both; retry injects both" {
  use_fixture aa-bad-timeout
  cat > "$DAEDALUS_HOME/vault/pitfalls/ff-second-warn.md" <<'EOF'
---
type: pitfall
applies-to:
  bash:
    - 'sleep'
enforce: warn
---
# Sleeping in a hook stalls every call

Body.
EOF
  run hook "$(bash_call 'timeout 30 sleep 1')"
  denied
  [ "$(count '"permissionDecision": "deny"')" -eq 1 ]
  [ "$(count 'The timeout command is absent')" -gt 0 ]
  [ "$(count 'Sleeping in a hook')" -gt 0 ]
  run hook "$(bash_call 'timeout 30 sleep 1')"
  [ "$(count '"permissionDecision"')" -eq 0 ]
  [ "$(count 'Pitfall: The timeout command')" -eq 1 ]
  [ "$(count 'Pitfall: Sleeping in a hook')" -eq 1 ]
}

@test "bad input with controls: malformed stdin silent; no session_id still blocks; broken sibling skipped" {
  run hook 'not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cat > "$DAEDALUS_HOME/vault/pitfalls/ee-block.md" <<'EOF'
---
type: pitfall
applies-to:
  bash:
    - 'rm -rf /'
enforce: block
---
# Never remove the root

Body.
EOF
  run hook '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
  denied
  printf -- '---\napplies-to:\n  bash:\n    - "[unclosed"\nenforce: block\n---\n# Broken\n\nB.\n' \
    > "$DAEDALUS_HOME/vault/pitfalls/ab-broken.md"
  use_fixture cc-flow-list
  printf -- '---\nenforce: sometimes\napplies-to:\n  bash:\n    - "rm"\n---\n# Bad enforce\n\nB.\n' \
    > "$DAEDALUS_HOME/vault/pitfalls/ac-bad-enforce.md"
  run hook "$(bash_call 'rm -rf /' s9)"
  denied
  [ "$(count 'Never remove the root')" -gt 0 ]
}

@test "block stage stays reachable when file_path is unresolvable (embedded NUL); bash-pattern block still fires" {
  cat > "$DAEDALUS_HOME/vault/pitfalls/ee-block.md" <<'EOF'
---
type: pitfall
applies-to:
  bash:
    - 'rm -rf /'
enforce: block
---
# Never remove the root

Body.
EOF
  cat > "$DAEDALUS_HOME/vault/pitfalls/eg-path-block.md" <<'EOF'
---
type: pitfall
applies-to:
  path:
    - '**/*.bats'
enforce: block
---
# Bats files are off limits

Body.
EOF
  payload="$(python3 -c '
import json
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "session_id": "s1",
    "tool_name": "Edit",
    "tool_input": {"file_path": "/a\x00b/x.bats", "old_string": "a", "new_string": "b"},
}))
')"
  run hook "$payload"
  [ "$status" -eq 0 ]
  run hook "$(bash_call 'rm -rf /' s9)"
  denied
  [ "$(count 'Never remove the root')" -gt 0 ]
}

@test "path patterns run under the same per-pattern alarm as bash patterns (unit-level via search())" {
  # The glob dialect (glob_to_regex) only ever emits [^/]*, [^/], (?:[^/]+/)*,
  # (?:/.*)? and escaped literals — none of which can catastrophically
  # backtrack, so a pathological path_regex cannot be produced from
  # frontmatter through the shipped grammar. This checks search()'s
  # full=True branch directly (the function match_pitfall's path arm now
  # calls), proving the alarm guard applies there too, independent of
  # whether the glob dialect can ever hand it a stalling pattern.
  run python3 -c "
import importlib.util, time
spec = importlib.util.spec_from_file_location('pitfall_inject', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
t0 = time.time()
r = m.search(r'(a+)+\$', 'a' * 30 + 'b', full=True)
elapsed = time.time() - t0
assert r is None, 'expected a stall (None), got %r' % (r,)
assert elapsed < 3, 'alarm did not bound the stall: %.2fs' % elapsed
print('guarded', elapsed)
"
  [ "$status" -eq 0 ]
  [ "$(count 'guarded')" -eq 1 ]
}

@test "deny-plus-announcement: an unparseable block-declaring sibling rides the block deny reason, then is announced once on a later call, not marked seen by the deny" {
  # cc-flow-list.md declares `enforce: block` but its bash pattern is a flow
  # list (`['never']`) — genuinely Unparseable, unlike a pitfall whose
  # pattern merely fails to compile as regex (still a parsed, "good" pitfall
  # per load_pitfalls). This is the fixture load_pitfalls's skip path
  # actually exercises with a non-empty raw_enforce.
  cat > "$DAEDALUS_HOME/vault/pitfalls/ee-block.md" <<'EOF'
---
type: pitfall
applies-to:
  bash:
    - 'rm -rf /'
enforce: block
---
# Never remove the root

Body.
EOF
  use_fixture cc-flow-list
  run hook "$(bash_call 'rm -rf /')"
  denied
  [ "$(count 'Never remove the root')" -gt 0 ]
  [ "$(count 'Note:')" -gt 0 ]
  [ "$(count 'cc-flow-list.md')" -gt 0 ]
  run hook "$(bash_call 'echo fine')"
  [ "$(count '"permissionDecision"')" -eq 0 ]
  [ "$(count '"additionalContext"')" -eq 1 ]
  [ "$(count 'cc-flow-list.md')" -gt 0 ]
}

@test "stall isolation: a pathological block pattern before a matching one still denies, and is announced" {
  printf -- '---\napplies-to:\n  bash:\n    - "(a+)+$"\nenforce: block\n---\n# Pathological\n\nB.\n' \
    > "$DAEDALUS_HOME/vault/pitfalls/aa-patho.md"
  printf -- '---\napplies-to:\n  bash:\n    - "rm -rf"\nenforce: block\n---\n# Real block\n\nB.\n' \
    > "$DAEDALUS_HOME/vault/pitfalls/zz-real.md"
  start=$(date +%s)
  run hook "$(bash_call 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab rm -rf x')"
  end=$(date +%s)
  denied
  [ "$(count 'Real block')" -gt 0 ]
  [ $((end - start)) -lt 3 ]
  # By the Task 3 ruling, an announcement rides the SAME call's deny reason —
  # there is no next call for the stall to appear on.
  [ "$(count 'has a pattern that stalled')" -eq 1 ]
}

@test "dark block announced once per session key" {
  use_fixture cc-flow-list
  run hook "$(bash_call 'echo fine')"
  [ "$(count 'is unparseable')" -eq 1 ]
  [ "$(count 'would block')" -eq 1 ]
  run hook "$(bash_call 'echo fine')"
  [ "$(count 'is unparseable')" -eq 0 ]
  run hook "$(bash_call 'echo fine' s2)"
  [ "$(count 'is unparseable')" -eq 1 ]
}

@test "PreCompact clears the session's seen-state so pitfalls fire again" {
  use_fixture aa-bad-timeout
  run hook "$(bash_call 'timeout 30 x')"
  run hook "$(bash_call 'timeout 30 x')"
  [ "$(count 'Pitfall: The timeout command')" -eq 1 ]
  run hook "$(bash_call 'timeout 30 x')"
  [ -z "$output" ]
  run hook '{"hook_event_name":"PreCompact","session_id":"s1","trigger":"auto"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run hook "$(bash_call 'timeout 30 x')"
  denied
}

@test "--check names cannot-fire, unparseable, and an unwritable state dir" {
  use_fixture aa-bad-timeout cc-flow-list
  printf -- '---\ntype: pitfall\n---\n# No trigger\n\nB.\n' > "$DAEDALUS_HOME/vault/pitfalls/nn-none.md"
  printf -- '---\napplies-to:\n  bash:\n---\n# Empty list\n\nB.\n' > "$DAEDALUS_HOME/vault/pitfalls/oo-empty.md"
  run python3 "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [ "$(count 'pitfalls: 4 total, 2 cannot fire, 1 unparseable')" -eq 1 ]
  [ "$(count 'nn-none.md: no applies-to')" -eq 1 ]
  [ "$(count 'oo-empty.md: applies-to has no patterns')" -eq 1 ]
  [ "$(count 'cc-flow-list.md: applies-to.bash: flow list')" -eq 1 ]
  [ "$(count 'state/ unwritable')" -eq 0 ]
  chmod 500 "$DAEDALUS_HOME/state"
  run python3 "$SCRIPT" --check
  chmod 700 "$DAEDALUS_HOME/state"
  [ "$(count 'state/ unwritable')" -eq 1 ]
  rm -rf "$DAEDALUS_HOME/state"
  run python3 "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [ "$(count 'state/ absent')" -eq 1 ]
  [ ! -e "$DAEDALUS_HOME/state" ]
  mkdir -p "$DAEDALUS_HOME/state"
  run python3 "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [ "$(count 'state/ absent')" -eq 0 ]
  [ "$(count 'state/ unwritable')" -eq 0 ]
}

@test "template never fires even with live patterns" {
  cp "$SRC/templates/pitfall.md" "$DAEDALUS_HOME/vault/pitfalls/_template.md"
  run python3 "$SCRIPT" --parse "$DAEDALUS_HOME/vault/pitfalls/_template.md"
  [ "$(count '"unparseable"')" -eq 0 ]
  run hook "$(bash_call 'timeout 30 x')"
  [ -z "$output" ]
  use_fixture aa-bad-timeout
  run hook "$(bash_call 'timeout 30 x')"
  denied
}
