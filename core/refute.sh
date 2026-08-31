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
{
  printf -- '---\ntype: evidence-review\nrun-id: %s\ncreated: %s\n---\n' "$run_id" "$(date +%Y-%m-%dT%H:%M:%S)"
  claude -p --settings '{"disableAllHooks": true}' < "$prompt"
} > "$verdict_file" 2>/dev/null
rm -f "$prompt"
printf '%s\n' "$verdict_file" >> "$ev/.manifest"
if grep -qE '^[*#[:space:]]*VERDICT:?\*{0,2}[[:space:]]*REFUTED' "$verdict_file"; then printf 'REFUTED\n'; exit 1; fi
printf 'STANDS\n'
