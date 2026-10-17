#!/usr/bin/env bats
#
# core/code-context.py was the edit-time hook; 0.9.0 removed it (code-context
# design §4) and keeps the file as a no-op (through 0.10.0), so a hook entry left in
# a home's .claude/settings.local.json cannot block edits (exit 2 from a
# PreToolUse hook blocks the tool call). Assertions use [ ] only.

@test "the retired hook is a no-op: exit 0 and no output on an Edit payload and on a PreCompact payload" {
  SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/code-context.py"
  run bash -c 'printf "%s" "$1" | python3 "$2"' _ \
    '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"/x/target/thing/pkg/core.py","old_string":"a","new_string":"b"}}' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c 'printf "%s" "$1" | python3 "$2"' _ '{"hook_event_name":"PreCompact","session_id":"s1"}' "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
