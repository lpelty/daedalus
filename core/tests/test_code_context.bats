#!/usr/bin/env bats
#
# Pins code-context: correct dependents via BOTH engines with ONE exclusion
# policy, module-name derivation, and a CLI that touches no state.
# Assertions use [ ] only.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  T="$DAEDALUS_HOME/target/thing"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" \
           "$T/pkg/sub" "$T/.hidden" "$T/fakevenv/sub"
  cp "$SRC/lib.sh" "$SRC/code-context.py" "$DAEDALUS_HOME/core/"
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
  # Known import graph — importers of pkg/core.py (5):
  #   pkg/user_a.py      import pkg.core
  #   pkg/user_b.py      from pkg import core
  #   pkg/rel_user.py    from . import core          (level-1 relative)
  #   pkg/sub/deep.py    from ..core import X        (level-2 relative, spec B-6)
  #   top.py             from pkg.core import X
  #   leaf.py            imports nothing, imported by nothing
  printf 'X = 1\n' > "$T/pkg/core.py"
  printf '' > "$T/pkg/__init__.py"
  printf '' > "$T/pkg/sub/__init__.py"
  printf 'import pkg.core\n' > "$T/pkg/user_a.py"
  printf 'from pkg import core\n' > "$T/pkg/user_b.py"
  printf 'from . import core\n' > "$T/pkg/rel_user.py"
  printf 'from ..core import X\n' > "$T/pkg/sub/deep.py"
  printf 'from pkg.core import X\n' > "$T/top.py"
  printf 'Y = 2\n' > "$T/leaf.py"
  # decoys: a venv (pyvenv.cfg) and a hidden dir that both import pkg.core —
  # ruff 0.16.5 does NOT skip these by default (verified); the post-filter must
  printf 'home = /usr\n' > "$T/fakevenv/pyvenv.cfg"
  printf 'import pkg.core\n' > "$T/fakevenv/sub/v.py"
  printf 'import pkg.core\n' > "$T/.hidden/h.py"
  export DAEDALUS_HOME
  SCRIPT="$DAEDALUS_HOME/core/code-context.py"
}

count() { printf '%s\n' "$output" | grep -cF -- "$1"; }

@test "CLI: dependents of pkg/core.py — 5 importers incl. level-2 relative, decoys excluded, no state" {
  run python3 "$SCRIPT" "$T/pkg/core.py"
  [ "$status" -eq 0 ]
  [ "$(count 'pkg/user_a.py')" -eq 1 ]
  [ "$(count 'pkg/user_b.py')" -eq 1 ]
  [ "$(count 'pkg/rel_user.py')" -eq 1 ]
  [ "$(count 'pkg/sub/deep.py')" -eq 1 ]
  [ "$(count 'top.py')" -eq 1 ]
  [ "$(count 'fakevenv')" -eq 0 ]
  [ "$(count '.hidden')" -eq 0 ]
  [ ! -f "$DAEDALUS_HOME/state/code-context-seen.json" ]
}

@test "CLI: leaf file prints nothing; file outside the roots prints nothing" {
  run python3 "$SCRIPT" "$T/leaf.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run python3 "$SCRIPT" /etc/hosts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

edit_call() {   # edit_call <abs-file-path> [session_id] [agent_id]
  local p="$1" sid="${2:-s1}" aid="${3:-}"
  local agent=""
  [ -n "$aid" ] && agent=", \"agent_id\": \"$aid\""
  printf '{"hook_event_name":"PreToolUse","session_id":"%s"%s,"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' \
    "$sid" "$agent" "$p"
}

hook() { printf '%s' "$1" | python3 "$SCRIPT"; }

@test "hook: dependents banner with derived module name; decoys absent; leaf/non-py/outside silent" {
  run hook "$(edit_call "$T/pkg/core.py")"
  [ "$status" -eq 0 ]
  [ "$(count '5 files import pkg.core')" -eq 1 ]
  [ "$(count 'additionalContext')" -eq 1 ]
  [ "$(count 'fakevenv')" -eq 0 ]
  run hook "$(edit_call "$T/leaf.py" s2)"
  [ -z "$output" ]
  run hook "$(edit_call "$T/pkg/core.txt" s3)"
  [ -z "$output" ]
  run hook "$(edit_call /etc/hosts s4)"
  [ -z "$output" ]
}

@test "hook: dedup per session-key; new key fires; PreCompact resets" {
  run hook "$(edit_call "$T/pkg/core.py" sX)"
  [ "$(count 'pkg.core')" -eq 1 ]
  run hook "$(edit_call "$T/pkg/core.py" sX)"
  [ -z "$output" ]
  run hook "$(edit_call "$T/pkg/core.py" sY)"
  [ "$(count 'pkg.core')" -eq 1 ]
  printf '{"hook_event_name":"PreCompact","session_id":"sX"}' | python3 "$SCRIPT"
  run hook "$(edit_call "$T/pkg/core.py" sX)"
  [ "$(count 'pkg.core')" -eq 1 ]
}

@test "hook: die-before-emit does not mark seen — the next edit fires" {
  DAEDALUS_CODE_CONTEXT_TEST_DIE=render run hook "$(edit_call "$T/pkg/core.py" sZ)"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run hook "$(edit_call "$T/pkg/core.py" sZ)"
  [ "$(count 'pkg.core')" -eq 1 ]
}

@test "hook: silence on malformed stdin and forced stall; unreadable state DEGRADES to repetition" {
  run bash -c "printf 'not json' | python3 '$SCRIPT'"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  DAEDALUS_CODE_CONTEXT_TEST_SLEEP=5 run hook "$(edit_call "$T/pkg/core.py" sW)"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  # unreadable state/: banner still emits, and emits AGAIN (dedup degraded,
  # not the hook dead) — spec B-4 as amended: repetition, never silence
  chmod 000 "$DAEDALUS_HOME/state"
  run hook "$(edit_call "$T/pkg/core.py" sQ)"
  [ "$status" -eq 0 ]
  [ "$(count 'pkg.core')" -eq 1 ]
  run hook "$(edit_call "$T/pkg/core.py" sQ)"
  [ "$(count 'pkg.core')" -eq 1 ]
  chmod 755 "$DAEDALUS_HOME/state"
}

add_ruff_config() {  # add_ruff_config <ruff-cmd>
  printf 'recall:\n  ruff: '"'"'%s'"'"'\n' "$1" >> "$DAEDALUS_HOME/config.yaml"
}

require_ruff() {
  "$HOME/.local/bin/uvx" ruff@0.16.5 --version >/dev/null 2>&1 || skip "uvx ruff unavailable"
  # guard against the vacuous-parity trap: ruff must complete on this fixture
  # standalone, or the "ruff engine" side would silently be the ast answer
  ( cd "$T" && "$HOME/.local/bin/uvx" ruff@0.16.5 analyze graph --direction dependents >/dev/null 2>&1 ) \
    || skip "ruff cannot analyze the fixture on this machine"
}

@test "engine parity: real ruff gives the ast answer INCLUDING exclusions" {
  require_ruff
  ast_out="$(python3 "$SCRIPT" "$T/pkg/core.py" | sort)"
  add_ruff_config "$HOME/.local/bin/uvx ruff@0.16.5"
  ruff_out="$(python3 "$SCRIPT" "$T/pkg/core.py" | sort)"
  [ "$ast_out" = "$ruff_out" ]
  [ -n "$ast_out" ]                       # positive control: parity of nothing proves nothing
  [ "$(printf '%s\n' "$ruff_out" | grep -cF 'fakevenv')" -eq 0 ]   # post-filter, not ruff defaults
}

@test "broken ruff engine: ast answer, silently" {
  add_ruff_config "/bin/false"
  run python3 "$SCRIPT" "$T/pkg/core.py"
  [ "$status" -eq 0 ]
  [ "$(count 'pkg/user_a.py')" -eq 1 ]
}

@test "symlinked DAEDALUS_HOME: same answer under the ruff engine" {
  require_ruff
  add_ruff_config "$HOME/.local/bin/uvx ruff@0.16.5"
  ln -s "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR/link-home"
  direct="$(python3 "$SCRIPT" "$T/pkg/core.py" | sort)"
  linked="$(DAEDALUS_HOME="$BATS_TEST_TMPDIR/link-home" python3 "$SCRIPT" "$BATS_TEST_TMPDIR/link-home/target/thing/pkg/core.py" | sort)"
  [ "$direct" = "$linked" ]
  [ -n "$direct" ]
}

@test "banner caps: >20 dependents lists 20 + (+N more)" {
  for i in $(seq 1 25); do
    printf 'import pkg.core\n' > "$T/pkg/dep$i.py"
  done
  run hook "$(edit_call "$T/pkg/core.py" scap)"
  [ "$(count '(+' )" -eq 1 ]
  n="$(printf '%s' "$output" | python3 -c '
import json,sys
t = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
line = t.split("\n")[1]
print(line.count(".py,") + 1)
')"
  [ "$n" -eq 20 ]
}
