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
