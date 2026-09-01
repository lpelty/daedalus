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
claude -p --settings '{"disableAllHooks": true}' < "$prompt" > "$body" 2>/dev/null
claude_rc=$?
rm -f "$prompt"
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
