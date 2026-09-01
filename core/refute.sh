#!/usr/bin/env bash
# Rung 2: a fresh-context refuter. Receives the target diff against its base,
# the acceptance criteria (the assignment file named in $2, if any), and the
# evidence summary — never the narrative. Writes the verdict beside the
# evidence and prints REFUTED or STANDS. Enabled only by config `verify.refute: true`.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e
run_id="$1"; criteria="${2:-}"
target="$(target_path)"
base="$(cfg target.branch 2>/dev/null || printf main)"
ev="$DAEDALUS_HOME/vault/evidence"
command -v claude >/dev/null 2>&1 || {
  printf 'claude not found on PATH — cannot run the rung-2 refuter\n' >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  printf 'python3 not found on PATH — cannot run the rung-2 refuter watchdog\n' >&2
  exit 2
}
prompt="$(mktemp)"
{
  printf 'Adversarial review. Find what is wrong with this change. Do NOT validate. Do NOT summarize.\n'
  printf 'Assume the author is overconfident. End with a line VERDICT: REFUTED or VERDICT: STANDS.\n\n'
  printf '## Acceptance criteria\n'; [ -f "$criteria" ] && cat "$criteria" || printf '(none supplied)\n'
  printf '\n## Evidence\n'; cat "$ev/$run_id.md"
  printf '\n## Diff against %s\n' "$base"
  git -C "$target" diff "origin/$base"...HEAD 2>/dev/null || git -C "$target" diff "$base" 2>/dev/null
  git -C "$target" diff HEAD
} > "$prompt"
verdict_file="$ev/$run_id-review.md"
# The refuter's exit code and output are both load-bearing. A claude that is
# present but fails (or prints nothing) used to leave an empty verdict body,
# the REFUTED grep missed, and the run stayed PASS — a crashed checker
# reported as green, this repo's founding pitfall class. Unknown is exit 2,
# never STANDS.
body="$(mktemp)"
# A claude that never returns used to hang gates.sh forever — no verdict, no
# FAIL, no evidence, a stuck gate (the residual after crash and mute were
# made loud). Bound the invocation to verify.refute_timeout seconds
# (validated by lib.sh refute_timeout; gates.sh has already refused a bad
# value before running any gate — this is the belt to that brace). On expiry
# the whole process group is killed: claude spawns children (MCP servers,
# tool processes), and a single-pid kill would orphan them, still running,
# still writing to $body. The run then lands in the same uncertifiable exit 2
# below. python3 because macOS ships no `timeout` and bash 3.2 has no clean
# watchdog. The timeout is signalled by a marker file, not an exit code, so
# a claude that itself exits 124 within the deadline is not misreported.
timeout_s="$(refute_timeout)" || { rm -f "$prompt" "$body"; exit 2; }
timed_out="$body.timed-out"
python3 - "$timeout_s" "$prompt" "$body" "$timed_out" <<'PY'
import os, signal, subprocess, sys
secs, prompt, body, marker = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]

def kill_group(p):
    # TERM, a short grace, then KILL — unconditionally. The direct child is
    # a shim that answers TERM at once; the hung descendant this exists for
    # is exactly the process that may never service TERM (a node event loop
    # that is blocked, a tool ignoring signals). Stopping once the child is
    # reaped would report success while the group is still alive.
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(p.pid, sig)
        except ProcessLookupError:
            pass
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass

with open(prompt) as i, open(body, "w") as o:
    p = subprocess.Popen(["claude", "-p", "--settings", '{"disableAllHooks": true}'],
                         stdin=i, stdout=o, stderr=subprocess.DEVNULL, start_new_session=True)
timed_out = False
try:
    p.wait(timeout=secs)
except subprocess.TimeoutExpired:
    timed_out = True
finally:
    # Every exit that leaves the group possibly alive kills it: the timeout,
    # a Ctrl-C (claude sits in its own session now, so the terminal's SIGINT
    # reaches this watchdog but never claude), any exception. Nothing
    # outlives the watchdog.
    if p.poll() is None:
        kill_group(p)
if timed_out:
    open(marker, "w").close()
    sys.exit(124)
rc = p.returncode
# A signal death is negative here; report it bash-style (SIGKILL = 137, not 247).
sys.exit(128 - rc if rc < 0 else rc)
PY
claude_rc=$?
rm -f "$prompt"
if [ -e "$timed_out" ]; then
  rm -f "$body" "$timed_out"
  printf 'refuter timed out after %ss (verify.refute_timeout) — killed with its process group; cannot certify the run\n' "$timeout_s" >&2
  exit 2
fi
if [ "$claude_rc" -ne 0 ] || ! [ -s "$body" ]; then
  had_output="$([ -s "$body" ] && printf 'with' || printf 'no')"
  rm -f "$body"
  printf 'refuter CLI failed (exit %s, %s output) — cannot certify the run\n' \
    "$claude_rc" "$had_output" >&2
  exit 2
fi
{
  printf -- '---\ntype: evidence-review\nrun-id: %s\ncreated: %s\n---\n' "$run_id" "$(date +%Y-%m-%dT%H:%M:%S)"
  cat "$body"
} > "$verdict_file"
rm -f "$body"
printf '%s\n' "$verdict_file" >> "$ev/.manifest"
# Verdict grammar: markdown dressing allowed before the word (bold, heading,
# blockquote, list markers) and around the colon and verdict
# ("**VERDICT**: REFUTED", "> VERDICT: STANDS", "1. VERDICT: **REFUTED**"),
# and the line must END at the verdict — an echoed instruction line
# ("VERDICT: REFUTED or VERDICT: STANDS") must match neither.
V='^[*#>0-9.[:space:]-]*VERDICT[*[:space:]]*:?[*[:space:]]*'
E='[*[:space:].!]*$'
if grep -qE "${V}REFUTED${E}" "$verdict_file"; then printf 'REFUTED\n'; exit 1; fi
if grep -qE "${V}STANDS${E}" "$verdict_file"; then printf 'STANDS\n'; exit 0; fi
printf 'refuter wrote no VERDICT line — cannot certify the run (%s)\n' "$verdict_file" >&2
exit 2
