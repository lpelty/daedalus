#!/usr/bin/env bash
# Episodic capture on a Stop cadence (spec §4.7 "Capture, incremental").
# The tracked .claude/settings.json runs this on every Stop (throttled per
# transcript to memory.capture_interval) and on SessionEnd with --final (the
# tail flush: no throttle; waits out a Stop tick still in flight for as long as
# that tick's claim can honestly last — its own recorded ceiling, not a fixed
# 90 s, because nothing re-ticks an ended session and the flush is detached,
# so the wait holds no one up). Claude Code
# runs an event's hooks in parallel, so its place in the Stop list is cosmetic.
#
# Reads the hook payload on stdin. Exits 0 on every path, and silently when
# config.yaml has no memory: block — a deployment without memory loses
# nothing, and a turn never waits on memory. capture.py runs DETACHED: its own
# session (python3's os.setsid; bash 3.2 has no setsid), stdin from /dev/null,
# output appended to .capture.log, so this hook returns in milliseconds while
# the push and its polling run on. The transcript is the payload's
# transcript_path, else the payload's session id (capture.py resolves it
# through this session's SessionStart marker, spec A7) — never the newest file.
# --dry-run: print what a tick would do and exit; nothing is written.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
set +e
final=0; dry=0
for a in "$@"; do
  case "$a" in
    --final) final=1 ;;
    --dry-run) dry=1 ;;   # prints what a tick would do; touches nothing (the upgrade predicate, spec §14 step 5)
  esac
done
if [ "$dry" -eq 1 ]; then
  # A dry run is typed at a shell or a Bash tool, whose stdin may never close:
  # wait at most a second for a payload, as capture.py does.
  payload="$(python3 -c 'import select, sys
r, _, _ = select.select([sys.stdin], [], [], 1.0)
sys.stdout.write(sys.stdin.read() if r else "")' 2>/dev/null)"
else
  payload="$(cat)"
fi
if ! memory_configured; then
  [ "$dry" -eq 1 ] && printf 'capture-tick (dry run): no memory: block in config.yaml — a tick would do nothing.\n'
  exit 0
fi
logf="$DAEDALUS_HOME/.capture.log"
if [ "$dry" -eq 1 ]; then
  env_lines="$(memory_env 2>&1)" || { printf 'capture-tick (dry run): %s — a tick would do nothing.\n' "${env_lines#daedalus: }"; exit 0; }
else
  env_lines="$(memory_env 2>>"$logf")" || exit 0
fi
eval "$env_lines"
fields="$(printf '%s' "$payload" | python3 -c 'import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
except ValueError:
    d = {}
if not isinstance(d, dict):
    d = {}
print(d.get("transcript_path") or "")
print(d.get("session_id") or "")
print(",".join(sorted(d)))' 2>/dev/null)"
transcript="$(printf '%s\n' "$fields" | sed -n 1p)"
sid="$(printf '%s\n' "$fields" | sed -n 2p)"
keys="$(printf '%s\n' "$fields" | sed -n 3p)"
if [ "$dry" -eq 1 ]; then
  printf 'capture-tick (dry run): bank %s, server %s, transcript directory %s, one capture per transcript every %s s\n' \
    "$TENANT_BANK" "$HINDSIGHT_API_URL" "$TRANSCRIPT_DIR" "$CAPTURE_INTERVAL"
  if [ -n "$transcript" ]; then what="$transcript"
  elif [ -n "$sid" ]; then what="session $sid (its SessionStart marker's transcript, else $TRANSCRIPT_DIR/$sid.jsonl)"
  else what=""; fi
  if [ -z "$what" ]; then
    printf 'capture-tick (dry run): no hook payload names a transcript — a real tick takes it from its payload\n'
  elif [ "$final" -eq 1 ]; then
    printf 'capture-tick (dry run): would flush %s, waiting out a capture in flight\n' "$what"
  else
    printf 'capture-tick (dry run): would capture %s unless it was captured in the last %s s\n' "$what" "$CAPTURE_INTERVAL"
  fi
  exit 0
fi
# A7: the first payload's keys, once per deployment, so a build whose Stop
# payload lacks transcript_path is visible in the log rather than guessed at.
stamp="$DAEDALUS_HOME/state/hindsight/tick-payload-keys"
if [ ! -f "$stamp" ]; then
  mkdir -p "$(dirname "$stamp")" && printf '%s\n' "$keys" > "$stamp"
  printf 'capture-tick: first hook payload keys: %s\n' "$keys" >> "$logf"
fi
if [ -n "$transcript" ]; then
  set -- --transcript "$transcript"
elif [ -n "$sid" ]; then
  set -- --session-id "$sid"
else
  printf 'capture-tick: the hook payload named neither transcript_path nor session_id (keys: %s); nothing captured\n' "$keys" >> "$logf"
  exit 0
fi
if [ "$final" -eq 1 ]; then
  set -- "$@" --wait-out-claim
else
  set -- "$@" --throttle "$CAPTURE_INTERVAL"
fi
# setsid fails (EPERM) only for a process-group leader, which a background job
# of this non-interactive script is not; the try keeps an odd shell harmless.
python3 -c 'import os, sys
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])' python3 "$DAEDALUS_HOME/core/capture.py" capture "$@" \
  </dev/null >>"$logf" 2>&1 &
exit 0
