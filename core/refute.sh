#!/usr/bin/env bash
# Rung 2: a fresh-context refuter. Receives the acceptance criteria (the
# assignment file named in $2, if any), the evidence summary ($3, or the
# vault copy), the pitfalls that apply to the touched paths, and the diff
# against the base — assembled per repository, the target and each
# target.nested checkout, untracked files included — never the narrative. Writes the verdict beside the evidence and prints
# REFUTED or STANDS. Runs after every PASS unless config says
# `verify.refute: false` with a `verify.refute_off_reason` (gates.sh owns
# that switch).
#
# The reviewer is the charter at core/agents/refuter.md — a Claude Code
# subagent definition (Read/Grep/Glob only, no Bash, fresh context),
# rendered by core/agentdef.py and passed with `--agents`:
# `claude -p --agent <name>` resolves only from .claude/agents/ of the cwd,
# which is a write surface Daedalus could edit; core/ is not. The model is
# the charter's unless config verify.refute_model overrides it.
#
# claude runs from an EMPTY scratch directory with the target granted by
# --add-dir, and the prompt names the target's absolute path. Two reasons,
# both measured on Claude Code 2.1.282: (1) the charter's `omitClaudeMd`
# does not stop `claude -p --agent` from loading the cwd's CLAUDE.md (a
# sentinel placed there was quoted back by a tool-less refuter), while a
# CLAUDE.md under an --add-dir directory is not loaded — so the reviewer
# never sees Daedalus's or the target's project instructions; (2) the diff's
# paths are target-relative and the reviewer needs an address to Read them
# at (Read/Grep/Glob reach --add-dir paths by absolute path, verified).
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
charter="$DAEDALUS_HOME/core/agents/refuter.md"
[ -f "$charter" ] || {
  printf 'refuter charter missing at %s — cannot run the rung-2 refuter\n' "$charter" >&2
  exit 2
}
agent_json="$(mktemp)"
if ! python3 "$DAEDALUS_HOME/core/agentdef.py" "$charter" > "$agent_json" 2>/dev/null; then
  rm -f "$agent_json"
  printf 'refuter charter at %s does not render (python3 core/agentdef.py %s) — cannot run the rung-2 refuter\n' "$charter" "$charter" >&2
  exit 2
fi
agent_name="$(python3 -c 'import json,sys; print(next(iter(json.load(open(sys.argv[1])))))' "$agent_json" 2>/dev/null)"
[ -n "$agent_name" ] || {
  rm -f "$agent_json"
  printf 'refuter charter at %s names no agent — cannot run the rung-2 refuter\n' "$charter" >&2
  exit 2
}
refute_model="$(cfg verify.refute_model 2>/dev/null || true)"
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
  rm -f "$paths" "$diff_file" "$agent_json"
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
  rm -f "$paths" "$diff_file" "$pitfalls_err" "$agent_json"
  printf 'pitfall selector failed (python3 core/refute-pitfalls.py exited %s: %s) — cannot certify the run\n' "$pitfalls_rc" "${pitfalls_reason:-no message}" >&2
  exit 2
fi
rm -f "$pitfalls_err"
prompt="$(mktemp)"
{
  printf 'Adversarial review. Find what is wrong with this change. Do NOT validate. Do NOT summarize.\n'
  printf 'Assume the author is overconfident. End with a line VERDICT: REFUTED or VERDICT: STANDS.\n\n'
  printf 'The change lives in the git checkout at %s. Paths in the diff and in the pitfalls are relative to that directory; read them there, by absolute path, with Read, Grep and Glob.\n\n' "$target"
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
timeout_s="$(refute_timeout)" || { rm -f "$prompt" "$body" "$agent_json"; exit 2; }
timed_out="$body.timed-out"
# The empty working directory claude runs from (see the header): no
# CLAUDE.md, no .claude/, nothing of Daedalus's or the target's project
# context — the target is reachable through --add-dir only.
workdir="$(mktemp -d)"
python3 - "$timeout_s" "$prompt" "$body" "$timed_out" "$agent_json" "$agent_name" "$refute_model" "$target" "$workdir" <<'PY'
import os, signal, subprocess, sys
secs, prompt, body, marker = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
agent_json, agent_name, model, target, workdir = sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8], sys.argv[9]
# The charter is passed as a rendered --agents file and selected with
# --agent; hooks are off (the refuter is not the builder, and the builder's
# hooks would snapshot and block around it). --model only when the operator
# set verify.refute_model; otherwise the charter's model applies. --add-dir
# grants the read-only tools the target checkout from the empty cwd.
argv = ["claude", "-p", "--agent", agent_name, "--agents", agent_json,
        "--settings", '{"disableAllHooks": true}', "--add-dir", target]
if model:
    argv += ["--model", model]

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

# A SIGTERM or SIGHUP to this watchdog — a Bash tool timeout killing
# gates.sh's process group, a closed terminal — must ALSO run the finally
# below. Python's default action for both is to die at once, skipping every
# finally: the watchdog was gone and claude, in its own session, ran on
# unowned — measured with a stub claude that outlived the watchdog by the
# full length of its work. A handler that raises SystemExit unwinds through
# the finally instead, and the exit code is the bash convention (128+n).
for _sig, _code in ((signal.SIGTERM, 143), (signal.SIGHUP, 129)):
    signal.signal(_sig, lambda *_a, _c=_code: sys.exit(_c))

with open(prompt) as i, open(body, "w") as o:
    p = subprocess.Popen(argv, stdin=i, stdout=o, stderr=subprocess.DEVNULL, start_new_session=True, cwd=workdir)
timed_out = False
try:
    p.wait(timeout=secs)
except subprocess.TimeoutExpired:
    timed_out = True
finally:
    # Every exit that leaves the group possibly alive kills it: the timeout,
    # a Ctrl-C (claude sits in its own session now, so the terminal's SIGINT
    # reaches this watchdog but never claude), a SIGTERM/SIGHUP (handled
    # above), any exception. Nothing outlives the watchdog.
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
rm -f "$prompt" "$agent_json"
rm -rf "$workdir"
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
