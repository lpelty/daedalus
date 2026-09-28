#!/usr/bin/env bash
# Rung 2: a fresh-context refuter. Receives the acceptance criteria (the
# assignment file named in $2, if any), the evidence summary ($3, or the
# vault copy), the pitfalls that apply to the touched paths, and the diff
# against the base — assembled per repository, the target and each
# target.nested checkout, untracked files included — never the narrative.
# Prints REFUTED or STANDS; exit 1 / 0, or 2 when the run cannot be
# certified. Runs after every PASS unless config says `verify.refute: false`
# with a `verify.refute_off_reason` (gates.sh owns that switch).
#
# This file ASSEMBLES the review; the direct-call launcher RUNS it (spec §6.1,
# §8): `core/call-agent.sh --callee refuter --tree <checkout> --request-file
# <prompt> --tag <run-id> --verdict-file vault/evidence/<run-id>-review.md`.
# The launcher renders the charter (core/agents/refuter.md, through
# core/agentdef.py), refuses while distribution code is modified, runs claude
# from an empty temporary directory with the checkout granted by --add-dir,
# user-level CLAUDE.md and auto memory excluded by --settings, no MCP and
# Read/Grep/Glob only; owns the watchdog (verify.refute_timeout, the whole
# process group killed on expiry), the receipt under state/direct-calls/, and
# the write-once verdict file, whose frontmatter records call-id, fingerprint,
# mode, request-sha, core-tree and charter-sha. Why the empty directory: the
# charter's `omitClaudeMd` does not stop `claude -p --agent` from loading the
# cwd's CLAUDE.md (measured on Claude Code 2.1.282), while a CLAUDE.md under an
# --add-dir directory is not loaded; the prompt names the checkout's absolute
# path so Read/Grep/Glob have an address.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e
run_id="$1"; criteria="${2:-}"
target="$(target_path)"
base="$(cfg target.branch 2>/dev/null || printf main)"
ev="$DAEDALUS_HOME/vault/evidence"
# The evidence summary to review: the file gates.sh hands over in $3, or the
# vault copy. gates.sh passes a file OUTSIDE the evidence tree, because the
# vault summary is written only after the verdict — a summary written
# before it, with `result: PASS`, is a PASS-labelled evidence file with no
# manifest line and no run.json for as long as the review runs, and a
# review killed from outside (a tool timeout) left it there for good.
evidence_file="${3:-$ev/$run_id.md}"
[ -f "$evidence_file" ] || {
  printf 'evidence summary missing at %s — cannot run the rung-2 refuter\n' "$evidence_file" >&2
  exit 2
}
command -v claude >/dev/null 2>&1 || {
  printf 'claude not found on PATH — cannot run the rung-2 refuter\n' >&2
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  printf 'python3 not found on PATH — cannot run the rung-2 refuter watchdog\n' >&2
  exit 2
}
# --- The diff, assembled per repository ------------------------------------
# The target's write surface may be a nested repository (config
# target.nested): on one deployment every change Daedalus makes lands in
# one, and the outer `git diff` never showed it — gitignored, the nested
# path is invisible to the outer repo; tracked as a gitlink, it is a
# one-line `Subproject commit …-dirty` stamp with no content. Default-on
# then made an opus review of an EMPTY diff mandatory on every PASS. So the
# diff is assembled per repository — the outer checkout, then each nested
# path — each against its own base, with the nested relpath prefixed onto
# every path (--src-prefix/--dst-prefix and on the name list) so the
# reviewer reads target-relative paths and the pitfalls' `applies-to:
# path:` globs match them. Untracked files are in it too: a temporary
# index seeded from the repo's own and brought up to date with `git add
# -A` (fingerprint.sh's technique), diffed against HEAD, shows a new file
# as a hunk, where `git diff HEAD` never showed a new file at all. An
# empty assembled diff is uncertifiable (exit 2), never handed to the
# model: a review of nothing that says STANDS is this repo's founding
# pitfall class.
#
# Bases: the outer repo's is `origin/<target.branch>`, falling back to the
# local branch (three-dot, since the merge base — a two-dot `diff $base`
# compares the working tree and showed every uncommitted hunk twice). A
# nested repo's is the branch sync-target.sh cloned and fast-forwards:
# origin's default (refs/remotes/origin/HEAD), then its upstream, then the
# outer names. A repo with no resolvable base contributes its uncommitted
# work only.
base_ref() {   # base_ref <repo> <candidate>... — the first that resolves
  local repo="$1" c; shift
  for c in "$@"; do
    [ -n "$c" ] || continue
    if git -C "$repo" rev-parse --verify -q "$c^{commit}" >/dev/null 2>&1; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}
nested_head() {   # nested_head <repo> — origin's default branch, short, or nothing
  local h
  h="$(git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)" || return 1
  [ -n "$h" ] && printf '%s\n' "$h"
}
# repo_diff <repo> <prefix> <names-out> <diff-out> <base-or-empty> [exclude-relpath...]
repo_diff() {
  local repo="$1" prefix="$2" names="$3" out="$4" base="$5" idx real n; shift 5
  local ex=()
  for n in "$@"; do ex+=(":(exclude)$n"); done
  local pfx=("--src-prefix=a/$prefix" "--dst-prefix=b/$prefix")
  if [ -n "$base" ]; then
    git -C "$repo" diff --name-only "$base"...HEAD -- . ${ex[@]+"${ex[@]}"} 2>/dev/null | sed "s|^|$prefix|" >> "$names"
    git -C "$repo" diff "${pfx[@]}" "$base"...HEAD -- . ${ex[@]+"${ex[@]}"} 2>/dev/null >> "$out"
  fi
  # Uncommitted AND untracked work against HEAD, through a temporary index:
  # seeded from the real one (so a tracked gitlink is not reported deleted),
  # then `add -A` brings it to the working tree. The real index is untouched.
  idx="$(mktemp -u)" || return 1
  real="$(git -C "$repo" rev-parse --git-path index 2>/dev/null)"
  case "$real" in /*) : ;; *) real="$repo/$real" ;; esac
  [ -f "$real" ] && cp "$real" "$idx"
  if GIT_INDEX_FILE="$idx" git -C "$repo" -c advice.addEmbeddedRepo=false add -A -- . ${ex[@]+"${ex[@]}"} >/dev/null 2>&1; then
    GIT_INDEX_FILE="$idx" git -C "$repo" diff --cached --name-only HEAD -- . ${ex[@]+"${ex[@]}"} 2>/dev/null | sed "s|^|$prefix|" >> "$names"
    GIT_INDEX_FILE="$idx" git -C "$repo" diff --cached "${pfx[@]}" HEAD -- . ${ex[@]+"${ex[@]}"} 2>/dev/null >> "$out"
  else
    # The temp index could not be built (an index.lock, an unreadable tree):
    # the working-tree diff, which at least carries the edits to tracked files.
    git -C "$repo" diff --name-only HEAD -- . ${ex[@]+"${ex[@]}"} 2>/dev/null | sed "s|^|$prefix|" >> "$names"
    git -C "$repo" diff "${pfx[@]}" HEAD -- . ${ex[@]+"${ex[@]}"} 2>/dev/null >> "$out"
  fi
  rm -f "$idx" "$idx.lock"
}
nested_rel=()   # bash 3.2: no mapfile
if cfg target.nested >/dev/null 2>&1; then
  while IFS="$(printf '\t')" read -r rel _url; do
    [ -n "$rel" ] || continue
    nested_rel+=("$rel")
  done <<EOF
$(cfg_pairs target.nested 2>/dev/null)
EOF
fi
# Exclude pathspecs only for nested paths the outer repo can SEE: naming a
# gitignored path in an explicit :(exclude) makes `git add` treat it as
# requested and error ("Use -f") — the trap fingerprint.sh already met.
outer_excl=()
for rel in ${nested_rel[@]+"${nested_rel[@]}"}; do
  git -C "$target" check-ignore -q "$rel" 2>/dev/null && continue
  outer_excl+=("$rel")
done
paths="$(mktemp)"; names_raw="$(mktemp)"; diff_file="$(mktemp)"
outer_base="$(base_ref "$target" "origin/$base" "$base" || true)"
printf '### . (against %s)\n' "${outer_base:-HEAD only — no base ref resolves}" >> "$diff_file"
repo_diff "$target" "" "$names_raw" "$diff_file" "$outer_base" ${outer_excl[@]+"${outer_excl[@]}"}
for rel in ${nested_rel[@]+"${nested_rel[@]}"}; do
  nrepo="$target/$rel"
  [ -d "$nrepo" ] || continue
  git -C "$nrepo" rev-parse --git-dir >/dev/null 2>&1 || continue
  nbase="$(base_ref "$nrepo" "$(nested_head "$nrepo" || true)" "@{u}" "origin/$base" "$base" || true)"
  printf '\n### %s (against %s)\n' "$rel" "${nbase:-HEAD only — no base ref resolves}" >> "$diff_file"
  repo_diff "$nrepo" "$rel/" "$names_raw" "$diff_file" "$nbase"
done
sort -u "$names_raw" > "$paths"; rm -f "$names_raw"
if ! grep -q '^diff --git ' "$diff_file"; then
  rm -f "$paths" "$diff_file"
  printf 'nothing to review — %s has no change against %s (committed, uncommitted or untracked%s); cannot certify a run with an empty diff\n' \
    "$target" "${outer_base:-$base}" "$([ "${#nested_rel[@]}" -gt 0 ] && printf ', in it or in %s' "${nested_rel[*]}")" >&2
  exit 2
fi
# The pitfall selector is an input, not a decoration: a selector that
# crashed or is missing used to render as "(none)" — byte-identical to "no
# pitfalls apply" — and the run could still STAND on a review that never
# saw the pitfalls. A non-zero exit is uncertifiable, like a charter that
# does not render (exit 2), and the reason reaches the operator.
pitfalls_err="$(mktemp)"
pitfalls_text="$(python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" "$paths" 2>"$pitfalls_err")"
pitfalls_rc=$?
if [ "$pitfalls_rc" -ne 0 ]; then
  pitfalls_reason="$(tr '\n' ' ' < "$pitfalls_err" | tail -c 400)"
  rm -f "$paths" "$diff_file" "$pitfalls_err"
  printf 'pitfall selector failed (python3 core/refute-pitfalls.py exited %s: %s) — cannot certify the run\n' "$pitfalls_rc" "${pitfalls_reason:-no message}" >&2
  exit 2
fi
rm -f "$pitfalls_err"
prompt="$(mktemp)"
{
  printf 'Adversarial review. Find what is wrong with this change. Do NOT validate. Do NOT summarize.\n'
  printf 'Assume the author is overconfident. End with a line VERDICT: REFUTED or VERDICT: STANDS.\n\n'
  printf 'The change lives in the git checkout at %s. Paths in the diff and in the pitfalls are relative to that directory; read them there, by absolute path, with Read, Grep and Glob.\n' "$target"
  printf 'Review mode: branch — one window'"'"'s branch: its commits since the base, then its uncommitted and untracked work.\n\n'
  printf '## Acceptance criteria\n'; [ -f "$criteria" ] && cat "$criteria" || printf '(none supplied)\n'
  printf '\n## Evidence\n'; cat "$evidence_file"
  printf '\n## Pitfalls that apply to the touched paths\n'
  if [ -n "$pitfalls_text" ]; then printf '%s\n' "$pitfalls_text"; else printf '(none)\n'; fi
  printf '\n## Diff against %s\n' "$base"
  # One section per repository (assembled above): committed work since the
  # merge base, then uncommitted and untracked work against HEAD.
  cat "$diff_file"
} > "$prompt"
rm -f "$paths" "$diff_file"
verdict_file="$ev/$run_id-review.md"
# The launcher's exit code is load-bearing, and so is who spoke. 0 = the
# verdict file was written. 124 with "timed out after" on its stderr = the
# watchdog killed the reviewer. A refusal before launch (exit 2, no receipt
# line) carries its own sentence — a missing or unrenderable charter,
# modified distribution code, a review that already exists — and is passed on
# as it is. Anything else is claude's own failure. All of them are exit 2
# here: unknown is never STANDS.
launch_err="$(mktemp)"
bash "$DAEDALUS_HOME/core/call-agent.sh" --callee refuter --tree "$target" --request-file "$prompt" \
  --tag "$run_id" --verdict-file "$verdict_file" --mode branch >/dev/null 2>"$launch_err"
launch_rc=$?
rm -f "$prompt"
if [ "$launch_rc" -ne 0 ]; then
  if [ "$launch_rc" -eq 124 ] && grep -q 'timed out after' "$launch_err"; then
    printf 'refuter timed out after %ss (verify.refute_timeout) — killed with its process group; cannot certify the run\n' "$(refute_timeout 2>/dev/null || printf '?')" >&2
  elif ! grep -q ' call [0-9a-f-]*.*; receipt ' "$launch_err"; then
    sed 's/^daedalus: //' "$launch_err" >&2
  else
    printf 'refuter CLI failed (exit %s, %s output) — cannot certify the run; receipt: %s\n' "$launch_rc" \
      "$(grep -q '(with output)' "$launch_err" && printf with || printf no)" \
      "$(sed -n 's/^.*; receipt //p' "$launch_err" | head -1)" >&2
  fi
  rm -f "$launch_err"
  exit 2
fi
rm -f "$launch_err"
# Under the manifest lock, one write (spec §4.9): a bare `>>` interleaved with
# another window's gates run. The review file is written and manifested in the
# same breath, so the RUNNING excuse covers the negligible window between.
# A failed append is exit 2 — cannot certify — like every other failure here,
# NEVER die (exit 1): gates.sh reads 1 as REFUTED with the review file as the
# fail_log, so a STANDS review whose manifest line failed was recorded as a
# refutation and the append's own error never reached the operator. The review
# file is removed rather than left unmanifested under vault/evidence, a
# protected path Daedalus cannot clean; the verdict was not certified anyway.
python3 "$DAEDALUS_HOME/core/manifest-append.py" "$verdict_file" || {
  rm -f "$verdict_file"
  printf 'cannot append the review file to the evidence manifest — cannot certify the run; the review file was removed rather than left unmanifested (%s)\n' "$verdict_file" >&2
  exit 2
}
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
