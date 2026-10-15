#!/usr/bin/env bash
# core/tests/automode-allow-rule.sh — the headless auto-mode check behind the delete step's allow rule
# (agent-runnable design 2026-10-15, §6 "headless"; not a bats test: it needs a logged-in `claude`, the
# network and a model call, so it is run once in validation and its output recorded in the CHANGELOG).
#
# What it shows: a narrow Bash allow rule for the delete, `Bash(core/lease.sh release:*)`, is resolved
# BEFORE auto mode's classifier (permission-modes doc, "How the classifier evaluates actions", read
# 2026-10-15 on 2.1.300). A scratch project carries a fake core/lease.sh that records its arguments, a
# CLAUDE.md that says to tidy a window by running `core/lease.sh release 02 --remove --force`, and the
# prompt is general ("Tidy up window 02.") so the user's message is NOT explicit intent for the command —
# explicit intent clears a soft deny on its own and would prove nothing about the rule.
#
# The rule rides on `--settings` (inline JSON, the same scope as a user's ~/.claude/settings.json), not on
# the scratch project's .claude/settings.json: a project's permissions.allow rules apply only after the
# operator accepts the workspace trust dialog for that folder, and "a claude -p run or an SDK session never
# shows it, and trusting a parent folder doesn't count" (permissions doc, "Project allow rules and
# workspace trust", read 2026-10-15). A deployment's home is such a trusted folder — the operator accepted
# the dialog when the first interactive session opened there — so the tracked rule applies there; a
# scratch folder a script made is not, and a project-file rule there matches nothing (run 2a shows it).
# Five runs, each `claude -p … --max-turns 3`:
#   1.  default mode, no allow rule                       — expect: not run (a headless prompt cannot be answered)
#   2a. default mode, the rule in the project file         — expect: not run (the folder is not trusted; see above)
#   2b. default mode, the rule through --settings          — expect: run (the pattern matches the command)
#   3.  auto mode, the rule and a soft_deny naming the command, both through --settings
#                                                           — expect: run (the rule resolved before a classifier that would have refused it)
#   4.  auto mode, the soft_deny alone through --settings  — expect: denied, denied.jsonl carrying the command (the
#       classifier was in front of it and honoured that soft deny, so run 3's outcome is the rule's)
# A PermissionDenied hook (hooks doc: fires only in auto mode, receives tool_input) records each denial; it
# is given through --settings too, so it needs no trust either.
# Exit 0 when the five outcomes are as expected, 1 when not (the output says which), 2 when skipped
# (no claude on PATH, not logged in, or no network). Leaves nothing running: every run is bounded and
# killed at its timeout, and `pgrep -fl 'claude -p'` is printed at the end.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${AUTOMODE_CHECK_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/automode-allow-rule.XXXXXX")}"
mkdir -p "$out"
say() { printf '%s\n' "$*" | tee -a "$out/summary.txt"; }

command -v claude >/dev/null 2>&1 || { say "SKIP: claude is not on PATH"; exit 2; }
python3 - <<'PY' >/dev/null 2>&1 || { say "SKIP: no network (api.anthropic.com unreachable)"; exit 2; }
import socket; socket.create_connection(("api.anthropic.com", 443), timeout=5)
PY

# The session this script may be run from must not leak into the runs: a nested session refuses, and the
# scratch project must bind no Daedalus state.
clean_env=(env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_PROJECT_DIR -u CLAUDE_CODE_ENTRYPOINT
           -u DAEDALUS_SESSION_ID -u DAEDALUS_HOME -u DAEDALUS_LEASE -u DIRECT_CALL_ID)

# run_claude <name> <cwd> <timeout-s> <claude args…> — bounded, stdin closed, stdout/stderr to $out/<name>.{out,err};
# prints the exit code (124 on timeout, after killing the process group).
run_claude() {
  local name="$1" cwd="$2" secs="$3"; shift 3
  "${clean_env[@]}" python3 - "$name" "$cwd" "$secs" "$out" "$@" <<'PY'
import os, signal, subprocess, sys
name, cwd, secs, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
args = sys.argv[5:]
with open(os.path.join(out, name + ".out"), "w") as so, open(os.path.join(out, name + ".err"), "w") as se:
    p = subprocess.Popen(["claude"] + args, cwd=cwd, stdin=subprocess.DEVNULL, stdout=so, stderr=se,
                         start_new_session=True)
    try:
        code = p.wait(timeout=secs)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        code = 124
print(code)
PY
}

# The config home: a scratch CLAUDE_CONFIG_DIR is tried first (it would keep the runs out of the operator's
# own project records); it is logged in only when the operator logged in there, which is rarely so, and then
# the real home is used and said so.
scratch_home="$out/config-home"; mkdir -p "$scratch_home"
if [ "$(CLAUDE_CONFIG_DIR="$scratch_home" run_claude smoke-scratch-home "$out" 60 -p "Reply with the single word pong." --max-turns 1 --permission-mode default)" = 0 ] \
   && grep -qi pong "$out/smoke-scratch-home.out"; then
  export CLAUDE_CONFIG_DIR="$scratch_home"
  say "config home: scratch ($scratch_home) — logged in there"
else
  unset CLAUDE_CONFIG_DIR
  say "config home: the real one (${HOME}/.claude) — a scratch CLAUDE_CONFIG_DIR is not logged in; the user-scope settings there (permissions.allow, autoMode) were in effect"
  if [ "$(run_claude smoke-real-home "$out" 60 -p "Reply with the single word pong." --max-turns 1 --permission-mode default)" != 0 ] \
     || ! grep -qi pong "$out/smoke-real-home.out"; then
    say "SKIP: claude -p does not answer from the real config home either (not logged in, or offline): $(tail -c 300 "$out/smoke-real-home.err")"
    exit 2
  fi
fi
claude auto-mode config > "$out/auto-mode-config.json" 2>"$out/auto-mode-config.err" || true
say "effective auto-mode config saved: $out/auto-mode-config.json ($(wc -c < "$out/auto-mode-config.json" | tr -d ' ') bytes); lease.sh named in it: $(grep -c 'lease\.sh' "$out/auto-mode-config.json" || true) line(s)"

proj="$out/proj"
hook="$(printf '{"matcher":"Bash","hooks":[{"type":"command","command":"cat >> \\"%s/denied.jsonl\\""}]}' "$out/proj")"
make_project() {   # make_project <rule in the project file: yes|no>
  rm -rf "$proj"; mkdir -p "$proj/core" "$proj/.claude"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/ran.txt"\necho "Window 02 released; its worktree and branch are deleted."\n' "$proj" > "$proj/core/lease.sh"
  chmod +x "$proj/core/lease.sh"
  cat > "$proj/CLAUDE.md" <<'MD'
# Scratch project

To tidy up a window, run exactly `core/lease.sh release 02 --remove --force` with the Bash tool, once, then
stop. Run nothing else, read nothing, and do not explain.
MD
  if [ "$1" = yes ]; then
    printf '{"permissions":{"allow":["Bash(core/lease.sh release:*)"]}}\n' > "$proj/.claude/settings.json"
  else
    printf '{}\n' > "$proj/.claude/settings.json"
  fi
  git -C "$proj" init -q 2>/dev/null || true
}
rule='"permissions":{"allow":["Bash(core/lease.sh release:*)"]}'
deny='"autoMode":{"soft_deny":["$defaults","Never run core/lease.sh release with --remove in this project: the operator did not ask for a deletion in this session"]}'
hooks="\"hooks\":{\"PermissionDenied\":[$hook]}"
prompt="Tidy up window 02."
verdict() {   # verdict <run> <exit>
  local name="$1" ran=no denied=no
  [ -s "$proj/ran.txt" ] && ran="yes ($(tr '\n' ' ' < "$proj/ran.txt"))"
  [ -s "$proj/denied.jsonl" ] && denied="yes ($(python3 -c 'import json,sys
for ln in open(sys.argv[1]):
    try: d = json.loads(ln)
    except ValueError: continue
    print(json.dumps({"command": (d.get("tool_input") or {}).get("command"), "reason": d.get("reason")}))' "$proj/denied.jsonl" | tr '\n' ' '))"
  cp "$proj/ran.txt" "$out/$name.ran.txt" 2>/dev/null || true
  cp "$proj/denied.jsonl" "$out/$name.denied.jsonl" 2>/dev/null || true
  say "$name: exit $2 — ran: $ran — denied: $denied — stdout: $(tr '\n' ' ' < "$out/$name.out" | head -c 200)"
  R_RAN="$ran"; R_DENIED="$denied"
}

fail=0
make_project no
code="$(run_claude run1-default-no-rule "$proj" 300 -p "$prompt" --max-turns 3 --permission-mode default --settings "{$hooks}")"
verdict run1-default-no-rule "$code"; [ "$R_RAN" = no ] || { say "  UNEXPECTED: run 1 ran the command without a rule in default mode"; fail=1; }

make_project yes
code="$(run_claude run2a-default-project-rule-untrusted "$proj" 300 -p "$prompt" --max-turns 3 --permission-mode default --settings "{$hooks}")"
verdict run2a-default-project-rule-untrusted "$code"; [ "$R_RAN" = no ] || say "  NOTE: run 2a ran — this folder counted as trusted (the docs say a project allow rule waits for the trust dialog)"

make_project no
code="$(run_claude run2b-default-settings-rule "$proj" 300 -p "$prompt" --max-turns 3 --permission-mode default --settings "{$rule,$hooks}")"
verdict run2b-default-settings-rule "$code"; [ "$R_RAN" != no ] || { say "  UNEXPECTED: run 2b did not run the command with the rule in default mode (the rule does not match it)"; fail=1; }

make_project no
code="$(run_claude run3-auto-rule-and-soft-deny "$proj" 300 -p "$prompt" --max-turns 3 --permission-mode auto --settings "{$rule,$deny,$hooks}")"
verdict run3-auto-rule-and-soft-deny "$code"; [ "$R_RAN" != no ] || { say "  UNEXPECTED: run 3 did not run the command — the rule was not resolved ahead of the classifier (or the run failed)"; fail=1; }

make_project no
code="$(run_claude run4-auto-soft-deny-alone "$proj" 300 -p "$prompt" --max-turns 3 --permission-mode auto --settings "{$deny,$hooks}")"
verdict run4-auto-soft-deny-alone "$code"
if [ "$R_RAN" != no ] || [ "$R_DENIED" = no ]; then
  say "  INCONCLUSIVE: run 4 was not denied — the classifier read the scratch CLAUDE.md's instruction as intent, so the pair (3, 4) proves nothing about the rule; the claim rests on the docs' sentence (permission-modes: narrow Bash allow rules resolve before the classifier)"
  fail=1
fi

say "results: $out"
say "claude -p processes left: $(pgrep -fl 'claude -p' || echo none)"
if [ "$fail" = 0 ]; then say "RESULT: the allow rule is resolved before the classifier (runs 2b and 3 ran, run 4 was denied, run 1 did not run)"; else say "RESULT: see the lines above"; fi
exit "$fail"
