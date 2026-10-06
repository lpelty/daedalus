#!/usr/bin/env bats
# A v0.6.1 deployment built by v0.6.1's own setup and started once by its own session start, then pulled to the
# tree under test (spec §14): the session open through the pull keeps working under the new hooks, the first new
# session upgrades the home with nobody's hands on it, and the second changes nothing.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() { v061_fixture; }
teardown() { teardown_live; }

start_session() {   # start_session <session-id> — an interactive terminal window's SessionStart, as Claude Code runs it
  local p; p="$(live_pid)"; registry_entry "$p" "$1" interactive cli daedalus-xx
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' \
    "$1" "$B" "$1" | python3 "$H/core/session-start.py"
}
prompt_s0() {       # the session that pulled (started by v0.6.1) takes its next prompt under the new hooks
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"s0","prompt":"what changed?","transcript_path":"%s/transcripts/s0.jsonl"}' \
    "$B" | python3 "$H/core/lease-board.py"
}
stop_s0() {         # ... and its Stop
  printf '{"hook_event_name":"Stop","session_id":"s0","stop_hook_active":false,"transcript_path":"%s/transcripts/s0.jsonl"}' \
    "$B" | python3 "$H/core/boundary-hook.py"
}
ctx_of() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }

@test "v0.6.1, built and started by its own code, then pulled: the open session's next prompt says the upgrade has not run and its Stop passes, with no traceback; the first new session upgrades the home with nobody's hands on it — every §14 predicate holds; the old session's Stop then gives only the release's config.yaml reason (do not restore it; start a new session) and the promotion backstop; the second session changes nothing" {
  pull_current
  # the session that pulled keeps running: its board leads with the pending line; nothing is created by reading
  run --separate-stderr prompt_s0
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ "$(ctx_of "$output" | head -1)" = "upgrade to 0.7.0 has not run yet — it runs at the next session start in this home" ] || { echo "$output"; return 1; }
  [ ! -d "$H/state/leases" ]
  run --separate-stderr stop_s0
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ -z "$output" ] || { echo "the pulling session's Stop was blocked before any upgrade: $output"; return 1; }
  # the first new session
  run start_session s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to 0.7.0: complete."*"You are window 02 and you hold the pen"*) : ;; *) echo "$c"; return 1 ;; esac
  # VERSION and the stamp
  [ "$(cat "$H/VERSION")" = 0.7.0 ]; [ "$(cat "$H/state/upgraded-to")" = 0.7.0 ]
  # the in-flight branch is window 01; target/thing is the trunk mirror with no ahead
  [ "$(lease_json 01 adopted_from)" = fix/in-flight ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  case "$(git -C "$T" status -sb | head -1)" in *ahead*) echo "still ahead"; return 1 ;; esac
  run bash "$H/core/lease.sh" list
  case "$output" in *"- 01 "*"adopted from fix/in-flight"*) : ;; *) echo "$output"; return 1 ;; esac
  # the hook in Daedalus's own checkout, outer and nested
  run python3 "$H/core/prepush.py" status "$T" "$T/sub"
  [ "$(printf '%s\n' "$output" | cut -f2 | sort -u)" = installed ] || { echo "$output"; return 1; }
  # memory moved; the predicate resolves it with no TENANT_* in the environment
  grep -q '^memory:' "$H/config.yaml"; [ "$(stat -f %Lp "$H/state/hindsight/api-key")" = 600 ]
  run env -u TENANT_BANK -u TENANT_HOME -u TRANSCRIPT_DIR -u HINDSIGHT_API_TENANT_API_KEY bash "$H/core/capture-tick.sh" --dry-run </dev/null
  case "$output" in *"bank bank-one"*"transcript directory $BATS_TEST_TMPDIR/tx"*) : ;; *) echo "$output"; return 1 ;; esac
  # dedup gone, hot.md renamed
  [ ! -e "$H/state/pitfall-seen.json" ]; [ ! -e "$H/state/code-context-seen.json" ]
  [ "$(sed -n 3p "$H/vault/hot.md")" = "leases: (see the board; prime's copy at its last write)" ]
  # doctor: the version line and the upgrade stamp, and nothing MISSING about VERSION, leases or hooks
  run bash "$H/core/doctor.sh"
  case "$output" in *"OK       version: 0.7.0"*"OK       upgrade: state/upgraded-to 0.7.0"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"MISSING  VERSION"*|*"MISSING  state/"*|*"MISSING  worktrees/"*|*"MISSING  pre-push hook"*) echo "$output"; return 1 ;; esac
  # the old session's Stop after the upgrade blocks (exit 2, reasons on stderr) with only the reasons the spec gives
  # a session left open through an upgrade: config.yaml changed under it (the memory: block; Decision 11 — the
  # sentence tells the operator to restart it), and the promotion backstop, which cannot tell an unnumbered
  # session's tree now that two sessions are live. Never a traceback. (Measured on a scratch build of Tasks 2-5,
  # 2026-09-29: exactly these two lines.)
  run --separate-stderr stop_s0
  case "$status" in 0|2) : ;; *) echo "status $status: $output $stderr"; return 1 ;; esac
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  # Since the critic's finding 7 the config.yaml reason names the upgrade as the one that changed it and says not to
  # restore it; it blocks once (test_boundary_hook.bats), and here the promotion backstop still blocks on its own.
  case "$stderr" in *"config.yaml changed under this session, by the upgrade to 0.7.0 — not by this session. Do not restore it"*"tell the operator to close it and start a new session."*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"changed this session; restore it"*) echo "$stderr"; return 1 ;; esac
  [ -z "$(printf '%s\n' "$stderr" | grep -v -e '^$' -e '^config.yaml changed under this session, by the upgrade' -e '^Promotion check')" ] \
    || { echo "an unexpected Stop reason for the old session: $stderr"; return 1; }
  run --separate-stderr stop_s0
  case "$stderr" in *"changed this session; restore it"*) echo "$stderr"; return 1 ;; esac
  # the second session: nothing upgrades again
  before="$(cd "$H" && find config.yaml vault/hot.md state/hindsight state/upgraded-to -type f | sort | xargs shasum)"
  run start_session s2
  case "$output" in *"Upgrade to"*) echo "$output"; return 1 ;; esac
  [ "$(cd "$H" && find config.yaml vault/hot.md state/hindsight state/upgraded-to -type f | sort | xargs shasum)" = "$before" ]
}
