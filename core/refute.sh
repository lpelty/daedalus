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
# The verdict grammar — one definition, used below for this run and by promote's
# confirm to re-parse a review (spec §7.2 step 3). Markdown dressing allowed before
# the word (bold, heading, blockquote, list markers) and around the colon and verdict
# ("**VERDICT**: REFUTED", "> VERDICT: STANDS", "1. VERDICT: **REFUTED**"), and the
# line must END at the verdict — an echoed instruction line ("VERDICT: REFUTED or
# VERDICT: STANDS") must match neither.
V='^[*#>0-9.[:space:]-]*VERDICT[*[:space:]]*:?[*[:space:]]*'
E='[*[:space:].!]*$'
# verdict_of <review file> — the verdict, from the file alone: STANDS (exit 0), REFUTED (1), NONE (2), the word on
# stdout and the findings it did or did not count on stderr. The one place a review becomes a verdict: this run's
# end and promote's re-read (--verdict-of) both call it, so the two can never disagree.
#
# The bar (2026-10-19). A reviewer told only "find what is wrong" always finds something in code that reads an
# outside service's replies — a field that is a list, a number where text goes — and every such finding refuted as
# hard as a real one, so a 40-line fix was refuted five runs running and grew to 250 lines answering inputs no
# account had sent. So each finding carries labels in its heading (charter, "Output format"): a severity (HIGH,
# MEDIUM, LOW), its input's standing (observed — in the evidence, fixtures, criteria or the target's own code paths;
# plausible — a stated, specific reason it could occur; hypothetical — possible, nothing points to it), its scope (in
# scope or out of scope of the criteria) and, since v0.12.4, its reach.
#
# Reach (v0.12.4). The 2026-10-19 bar judged the mechanism, not who meets it: a 3,000-line change was refuted three
# times on about 30 findings, half of them edge cases no ordinary use reaches, and the third refutation was one of
# them. So a heading names its reach — `reach: user` (an ordinary action of the person using the feature meets it),
# `reach: routine` (a path the system runs on its own in ordinary operation: a schedule, a hook, startup, an update)
# or `reach: none` (only an unusual input, timing or configuration) — and may carry the flags `data` (loses or
# corrupts the person's data) and `trust` (crosses a trust boundary or weakens a guard), which stand in for reach.
# What refutes: an observed HIGH at any reach; a finding marked `regressed L<n>` or carried unchecked from the
# ledger; an in-scope observed or plausible HIGH or MEDIUM that has reach user or routine, or a flag. A finding
# flagged `live-only` (only a live run can settle it) never counts and never passes: the ledger keeps it as a
# required live check and promote lists it. On a later review of a branch, a new finding outside the part changed
# since the last review is labelled `missed earlier` by core/review-lenses.py's merge — never by the reviewer: it
# is honoured only in a file whose frontmatter carries the merge's `new-ground:` line — and counts only as an
# observed HIGH with a flag. Everything else is a backlog candidate, listed on stderr with its labels; the review
# file keeps the reasoning. The reviewer's own VERDICT line is still required — it is how a truncated review is
# told from a finished one — but in a labelled review the labels decide, in both directions.
#
# Fail closed: a labelled review in which any finding heading lacks a label, carries an unknown one or two of one
# kind, or that has no verdict line, is NONE (exit 2) — never STANDS. A heading without its reach is unlabelled too,
# except one the merge wrote for the reviewer (carried, unlabelled refutation), which counts on its own. Re-read (by
# promote or --verdict-of), a review written before a label keeps the bar it was written for: no labelled finding
# heading at all, the reviewer's own VERDICT line, REFUTED first; labelled headings and no reach on any of them, the
# 2026-10-19 bar.
verdict_of() {   # verdict_of <review file> run|reread|counts
  python3 - "$1" "$2" <<'PY'
import json, re, sys
path, mode = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
V = r"^[*#>0-9.\s-]*VERDICT[*\s]*:?[*\s]*"
E = r"[*\s.!]*$"
said = ("REFUTED" if re.search(V + "REFUTED" + E, text, re.M) else
        "STANDS" if re.search(V + "STANDS" + E, text, re.M) else None)
# A finding heading: F<n> at the start of a line after any number of #s or in bold, then a separator — so a
# level-5 heading or a bold line is read as the finding it is, never skipped (review 2026-10-19, F1).
# A heading is marked as one (#s or bold); a plain "F1 — nothing found." is prose.
HEAD = re.compile(r"^[ \t>]*(?:#{1,6}[ \t]*(?:\*\*|__)?|\*\*|__)[ \t]*F(\d+)\b(?:\*\*|__)?[ \t]*([\u2014\u2013:|-].*)$", re.M)
SEV, STAND = ("HIGH", "MEDIUM", "LOW"), ("observed", "plausible", "hypothetical")
FLAGS = ("data", "trust", "live-only")
found = list(HEAD.finditer(text))
heads = [(m.group(1), [p.strip(" *`_:").lower() for p in re.split(r"\s*[\u2014\u2013|]+\s*|\s+-+\s+|^-+\s*|^:\s*", m.group(2))])
         for m in found]
def labels(parts):
    sev = [p.upper() for p in parts if p.upper() in SEV]
    st = [p for p in parts if p in STAND]
    sc = ["in" if p in ("in scope", "in-scope") else "out" for p in parts
          if p in ("in scope", "in-scope", "out of scope", "out-of-scope")]
    return sev, st, sc
def reach_of(parts):
    return [m.group(1) for m in (re.match(r"^reach\s*[:=]?\s*(user|routine|none)$", p) for p in parts) if m]
def flags_of(parts):
    out = set()
    for p in parts:
        toks = [("live-only" if t == "live only" else t) for t in re.split(r"\s*[,+]\s*|\s+and\s+", p) if t]
        if toks and all(t in FLAGS for t in toks):
            out.update(toks)
    return out
def what_of(i):
    end = found[i + 1].start() if i + 1 < len(found) else len(text)
    m = re.search(r"^\s*What is wrong:\s*(.*)$", text[found[i].end():end], re.M)
    return m.group(1).strip() if m else ""
# The merge's own frontmatter — the launcher writes the frontmatter of a reviewer's file, so a reviewer cannot.
fm = re.match(r"^---\n(.*?)\n---\n", text, re.S)
new_ground = bool(fm and re.search(r"^new-ground:", fm.group(1), re.M))
labelled = [h for h in heads if labels(h[1])[1] or labels(h[1])[2]]
v123 = mode != "run" and not any(reach_of(parts) for _, parts in heads)   # re-read: a review from before reach
def done(word, code, counts=None):
    if mode == "counts":
        print(json.dumps(counts or {"high": 0, "medium": 0, "low": 0, "set_aside": 0}))
        sys.exit(0)
    print(word)
    sys.exit(code)
def legacy():
    sev = [s for _, parts in heads for s in labels(parts)[0][:1]]
    c = {s.lower(): sev.count(s) for s in SEV}
    c["set_aside"] = 0
    if said == "REFUTED":
        done("REFUTED", 1, c)
    if said == "STANDS":
        done("STANDS", 0, c)
    done("NONE", 2, c)
if not labelled and mode != "run":
    legacy()                       # a review written before the labels (promote re-reads it): its own verdict line
bad, counted, listed, live, live_checks = [], [], [], [], []
real = {"high": 0, "medium": 0, "low": 0}
for i, (n, parts) in enumerate(heads):
    sev, st, sc = labels(parts)
    if len(sev) != 1 or len(st) != 1 or len(sc) != 1:
        bad.append("F%s (needs one severity, one of observed/plausible/hypothetical, and in or out of scope)" % n)
        continue
    # A finding the reviewer marks `regressed L<n>` — an earlier finding's fix broke something (the findings ledger,
    # core/review-lenses.py) — refutes whatever its labels: a fix that breaks what it fixed is not set aside. One the
    # merge carried unchecked from the ledger was counted when it was found, and still is.
    regressed = any(re.match(r"regressed l\d+\b", p) for p in parts)
    carried = any(re.match(r"carried l\d+\b", p) for p in parts)
    merged = carried or any(p.startswith("unlabelled refutation") for p in parts)
    rc, fl = reach_of(parts), flags_of(parts)
    if not v123 and not merged and len(rc) != 1:
        bad.append("F%s (needs one reach: user, routine or none)" % n)
        continue
    tag = "F%s %s, %s, %s" % (n, sev[0], st[0], "in scope" if sc[0] == "in" else "out of scope")
    tag += "".join(", " + x for x in (["reach: " + rc[0]] if rc else []) + sorted(fl))
    observed_high = st[0] == "observed" and sev[0] == "HIGH"
    real_bar = sc[0] == "in" and st[0] in ("observed", "plausible") and sev[0] in ("HIGH", "MEDIUM")
    missed = new_ground and any(p.startswith("missed earlier") for p in parts)
    if v123:
        refutes = real_bar or observed_high or regressed
    elif regressed or merged:
        refutes = True
    elif "live-only" in fl:
        refutes = False
    elif missed:
        refutes = observed_high and bool(fl & {"data", "trust"})
    else:
        refutes = observed_high or (real_bar and (rc[0] in ("user", "routine") or bool(fl & {"data", "trust"})))
    if regressed:
        tag += ", regressed"
    if missed:
        tag += ", missed earlier"
    if v123:
        if refutes or (sc[0] == "in" and st[0] != "hypothetical"):
            real[sev[0].lower()] += 1
    elif refutes:
        real[sev[0].lower()] += 1
    if not refutes and "live-only" in fl and not v123:
        live.append(tag)
        loc = next((p for p in parts if re.match(r"^\S+:\d+", p)), parts[0] if parts else "?")
        live_checks.append("%s — %s" % (loc, what_of(i) or "(see the review)"))
        continue
    (counted if refutes else listed).append(tag)
if v123:
    counts = dict(real, set_aside=len(heads) - len(bad) - sum(real.values()))
else:
    counts = dict(real, backlog=len(listed), live=len(live), live_checks=live_checks)
if bad:
    sys.stderr.write("review findings without their labels: %s — cannot certify the run\n" % "; ".join(bad))
    done("NONE", 2, counts)
if said is None:
    sys.stderr.write("review has no VERDICT line (a truncated review?) — cannot certify the run\n")
    done("NONE", 2, counts)
if not heads and said == "REFUTED":
    done("REFUTED", 1, counts)     # names no finding: a fail either way, and the reviewer's word is the safe one
if counted:
    sys.stderr.write("counted: %s\n" % "; ".join(counted))
if listed and v123:
    sys.stderr.write("%d finding%s not counted (hypothetical, out of scope or LOW): %s\n"
                     % (len(listed), "" if len(listed) == 1 else "s", "; ".join(listed)))
elif listed:
    sys.stderr.write("%d backlog candidate%s, not counted (reach none, hypothetical, out of scope, LOW or missed "
                     "earlier): %s\n" % (len(listed), "" if len(listed) == 1 else "s", "; ".join(listed)))
if live:
    sys.stderr.write("%d live check%s, not counted — only a live run can settle %s: %s\n"
                     % (len(live), "" if len(live) == 1 else "s", "it" if len(live) == 1 else "them", "; ".join(live)))
if not counted:
    # The rubric is the audit trail, not a second verdict (2026-10-19): a dimension scored FAIL with no finding
    # that counts behind it is set aside like its findings, and said so.
    fails = re.findall(r"^[\s*#>-]*\**(Correctness|Regression risk|Test honesty|Pitfall and boundary compliance|"
                       r"Claim[^:*]*)\**\s*[:\u2014-]+\s*\**FAIL\b", text, re.M)
    if fails:
        sys.stderr.write("rubric FAIL on %s set aside: no finding that counts supports it\n" % ", ".join(fails))
done("REFUTED", 1, counts) if counted else done("STANDS", 0, counts)
PY
}
# refute.sh --verdict-of <review file>: STANDS (exit 0), REFUTED (1), NONE (2). Runs nothing. A re-read: a review
# written before the labels keeps its own verdict line; one written since gives the verdict its run gave.
if [ "${1:-}" = "--verdict-of" ]; then
  f="${2:-}"
  [ -f "$f" ] || { printf 'refute.sh --verdict-of: no review file at %s\n' "$f" >&2; exit 2; }
  verdict_of "$f" reread
  exit $?
fi
# refute.sh --counts-of <review file>: one JSON line — high, medium and low among the findings that are real (in
# scope and observed or plausible, or an observed HIGH), and how many were set aside — for promote's decision block,
# so the counts the operator reads and the verdict come from the same reading.
if [ "${1:-}" = "--counts-of" ]; then
  f="${2:-}"
  [ -f "$f" ] || { printf 'refute.sh --counts-of: no review file at %s\n' "$f" >&2; exit 2; }
  verdict_of "$f" counts
  exit $?
fi
# refute.sh <run-id> [criteria] [evidence-file] [--mode branch|promote] [--render-only]
# --mode promote (spec §6.1, used by promote's prepare): the diff is the merge
# that will be pushed, trunk_sha_at_prepare..merge_sha from the promotion's
# run.json, in the merged tree (DAEDALUS_TARGET_OVERRIDE), with no uncommitted
# part; the criteria come from the window's lease file, never argv; and the
# inputs are pinned in run.json (core/review-inputs.py). --render-only prints
# that prompt again, byte for byte, and runs nothing — confirm compares its
# sha256 with the one the launcher recorded.
mode=branch; render_only=0; pos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
    --render-only) render_only=1; shift ;;
    --*) printf 'refute.sh: unknown flag %s\n' "$1" >&2; exit 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
case "$mode" in branch|promote) : ;; *) printf 'refute.sh: --mode is branch or promote (got: %s)\n' "$mode" >&2; exit 2 ;; esac
if [ "$render_only" -eq 1 ] && [ "$mode" != promote ]; then
  printf 'refute.sh: --render-only re-renders a promote review; pass --mode promote\n' >&2; exit 2
fi
run_id="${pos[0]:-}"; criteria="${pos[1]:-}"
[ -n "$run_id" ] || { printf 'usage: refute.sh <run-id> [criteria] [evidence-file] [--mode branch|promote] [--render-only]\n' >&2; exit 2; }
target="$(target_path)"
base="$(cfg target.branch 2>/dev/null || printf main)"
ev="$DAEDALUS_HOME/vault/evidence"
# The evidence summary to review: the file gates.sh hands over in $3, or the
# vault copy. gates.sh passes a file OUTSIDE the evidence tree, because the
# vault summary is written only after the verdict — a summary written
# before it, with `result: PASS`, is a PASS-labelled evidence file with no
# manifest line and no run.json for as long as the review runs, and a
# review killed from outside (a tool timeout) left it there for good.
evidence_file="${pos[2]:-$ev/$run_id.md}"
if [ "$mode" = promote ]; then
  if [ -n "$criteria" ]; then
    printf 'refute.sh --mode promote takes no criteria argument: a promotion'"'"'s criteria come from the window'"'"'s lease file (core/lease.sh update <NN> --criteria <file>)\n' >&2
    exit 2
  fi
  run_json="$DAEDALUS_HOME/state/evidence/$run_id/run.json"
  inputs="$(python3 "$DAEDALUS_HOME/core/review-inputs.py" shas "$run_json")" || exit 2
  eval "$inputs"      # base_sha merge_sha lease_nn criteria (shell-quoted by review-inputs.py)
  evidence_file="$ev/$run_id.md"
fi
[ -f "$evidence_file" ] || {
  printf 'evidence summary missing at %s — cannot run the rung-2 refuter\n' "$evidence_file" >&2
  exit 2
}
[ "$render_only" -eq 1 ] || command -v claude >/dev/null 2>&1 || {
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
# ground_diff <repo> <prefix> <sha> <out> [exclude-relpath...] — the working tree, untracked files included, against
# <sha> in one diff, so every hunk's new-side line numbers are the working tree's — the lines the reviewer reads.
# repo_diff's two parts (committed since <sha>, then uncommitted against HEAD) number their hunks against two different
# trees, and a file changed in both would put the committed ranges in the wrong place (review 2026-10-20, F4).
ground_diff() {
  local repo="$1" prefix="$2" sha="$3" out="$4" idx real n; shift 4
  local ex=()
  for n in "$@"; do ex+=(":(exclude)$n"); done
  idx="$(mktemp -u)" || return 1
  real="$(git -C "$repo" rev-parse --git-path index 2>/dev/null)"
  case "$real" in /*) : ;; *) real="$repo/$real" ;; esac
  [ -f "$real" ] && cp "$real" "$idx"
  if GIT_INDEX_FILE="$idx" git -C "$repo" -c advice.addEmbeddedRepo=false add -A -- . ${ex[@]+"${ex[@]}"} >/dev/null 2>&1; then
    GIT_INDEX_FILE="$idx" git -C "$repo" -c core.quotePath=false diff --cached -U0 "--src-prefix=a/$prefix" "--dst-prefix=b/$prefix" \
      "$sha" -- . ${ex[@]+"${ex[@]}"} 2>/dev/null >> "$out"
  else
    git -C "$repo" -c core.quotePath=false diff -U0 "--src-prefix=a/$prefix" "--dst-prefix=b/$prefix" "$sha" -- . \
      ${ex[@]+"${ex[@]}"} 2>/dev/null >> "$out"
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
if [ "$mode" = promote ]; then
  # What will be pushed, fixed by two shas per repository: no working tree,
  # no index, nothing uncommitted (the merged tree is clean by construction).
  outer_base="$base_sha"
  promote_diff() {   # promote_diff <repo> <prefix> <base> <merge>
    # A blank line before a nested repository's section, as in branch mode (a
    # command substitution would strip it).
    [ -z "$2" ] || printf '\n' >> "$diff_file"
    printf '### %s (%s..%s)\n' "${2:-.}" "$3" "$4" >> "$diff_file"
    git -C "$1" diff --name-only "$3" "$4" 2>/dev/null | sed "s|^|$2|" >> "$names_raw"
    git -C "$1" diff "--src-prefix=a/$2" "--dst-prefix=b/$2" "$3" "$4" 2>/dev/null >> "$diff_file"
  }
  promote_diff "$target" "" "$base_sha" "$merge_sha"
  while IFS="$(printf '\t')" read -r rel nb nm; do
    [ -n "$rel" ] || continue
    promote_diff "$target/$rel" "${rel%/}/" "$nb" "$nm"
  done <<EOF
$(python3 "$DAEDALUS_HOME/core/review-inputs.py" nested "$run_json")
EOF
else
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
fi
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
pitfalls_err="$(mktemp)"; pinned="$(mktemp)"
if [ "$mode" = promote ] && [ "$render_only" -eq 1 ]; then
  # The pitfalls this review showed, exactly — refused if one has changed.
  python3 "$DAEDALUS_HOME/core/review-inputs.py" verify "$run_json" "$evidence_file" "$criteria" "$pinned" \
    || { rm -f "$paths" "$diff_file" "$pitfalls_err" "$pinned"; exit 2; }
  pitfalls_text="$(python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" --only "$pinned" "$paths" 2>"$pitfalls_err")"
else
  pitfalls_text="$(python3 "$DAEDALUS_HOME/core/refute-pitfalls.py" --list-out "$pinned" "$paths" 2>"$pitfalls_err")"
fi
pitfalls_rc=$?
if [ "$pitfalls_rc" -ne 0 ]; then
  pitfalls_reason="$(tr '\n' ' ' < "$pitfalls_err" | tail -c 400)"
  rm -f "$paths" "$diff_file" "$pitfalls_err" "$pinned"
  printf 'pitfall selector failed (python3 core/refute-pitfalls.py exited %s: %s) — cannot certify the run\n' "$pitfalls_rc" "${pitfalls_reason:-no message}" >&2
  exit 2
fi
rm -f "$pitfalls_err"
if [ "$mode" = promote ] && [ "$render_only" -eq 0 ]; then
  # Pinned before the launcher runs; an attempt it refuses may pin again
  # (review-inputs.py refuses only once the verdict or prepared.json exists).
  python3 "$DAEDALUS_HOME/core/review-inputs.py" record "$run_json" "$evidence_file" "$criteria" "$pinned" \
      "$ev/$run_id-review.md" \
    || { rm -f "$paths" "$diff_file" "$pinned"; exit 2; }
fi
rm -f "$pinned"
# --- Lenses and the findings ledger (branch mode only; core/review-lenses.py says why) -----------------------------
# A large change gets one fresh reviewer per lens (verify.lenses), run at once and merged; a small one keeps one
# reviewer. "Large": at least verify.lens_lines changed lines or verify.lens_files files (defaults 800 and 25 — a
# 250-line fix stays with one reviewer, a 60-commit branch gets the lenses). Every window's branch keeps a ledger of
# the findings its reviews counted (state/review-ledger/<NN>.json, started again on a new lease or a promote, as the
# refutation count is): the next review is told them to check first, and the part of the change since the last
# review to hunt in. Promote's review is the last gate and takes neither: one fresh reviewer, no earlier findings.
lenses=(); section=""; delta_file=""; heads_now=""; earlier_json="-"; earlier_n=0; last_run="-"; hunks_json="-"
RL="$DAEDALUS_HOME/core/review-lenses.py"
plural() { if [ "$1" -eq 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %ss' "$1" "$2"; fi; }
if [ "$mode" = branch ]; then
  lease_nn="$(python3 "$DAEDALUS_HOME/core/leaselib.py" my-lease 2>/dev/null || true)"
  tbranch="$(git -C "$target" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  size="$(python3 "$RL" size "$diff_file" "$paths")" || { rm -f "$paths" "$diff_file"; exit 2; }
  n_lines="${size% *}"; n_files="${size#* }"
  lens_lines="$(cfg verify.lens_lines 2>/dev/null || printf 800)"
  lens_files="$(cfg verify.lens_files 2>/dev/null || printf 25)"
  case "$lens_lines" in ''|*[!0-9]*) lens_bad=1 ;; *) lens_bad=0 ;; esac
  case "$lens_files" in ''|*[!0-9]*) lens_bad=1 ;; esac
  if [ "$lens_bad" -eq 1 ]; then
    rm -f "$paths" "$diff_file"
    printf 'verify.lens_lines and verify.lens_files must be whole numbers (got: %s, %s) — cannot certify the run\n' "$lens_lines" "$lens_files" >&2
    exit 2
  fi
  lens_list="$(python3 "$RL" lenses "$(cfg verify.lenses 2>/dev/null || true)")" || { rm -f "$paths" "$diff_file"; exit 2; }
  why="$(plural "$n_lines" line) in $(plural "$n_files" file); lenses from $lens_lines lines or $lens_files files"
  if [ "$n_lines" -ge "$lens_lines" ] || [ "$n_files" -ge "$lens_files" ]; then
    while IFS= read -r l; do [ -n "$l" ] && lenses+=("$l"); done < <(printf '%s\n' "$lens_list")
    printf 'review-plan: %s lenses (%s) — the change is large (%s)\n' "${#lenses[@]}" "$(printf '%s\n' "${lenses[@]}" | paste -sd, - | sed 's/,/, /g')" "$why" >&2
  else
    printf 'review-plan: one reviewer — the change is small (%s)\n' "$why" >&2
  fi
  section="$(mktemp)"; heads_prev="$(mktemp)"
  ledger_out="$(python3 "$RL" open "$DAEDALUS_HOME" "$lease_nn" "$tbranch" "$section" "$heads_prev")" \
    || { rm -f "$paths" "$diff_file" "$section" "$section.json" "$heads_prev"; exit 2; }
  earlier_n="${ledger_out% *}"; last_run="${ledger_out#* }"
  [ "$earlier_n" -gt 0 ] && earlier_json="$section.json"
  # The part of the change since the last review: each repository from the commit that review saw. A commit no
  # longer under HEAD (a rebase rewrote the branch) leaves nothing to narrow to — the whole diff is the hunt.
  if [ "$last_run" != "-" ] && [ -s "$heads_prev" ]; then
    delta_file="$(mktemp)"; delta_names="$(mktemp)"; ground="$(mktemp)"; rewritten=0
    while IFS="$(printf '\t')" read -r rel sha; do
      [ -n "$rel" ] || continue
      if [ "$rel" = . ]; then repo="$target"; pfx=""; else repo="$target/$rel"; pfx="${rel%/}/"; fi
      [ -d "$repo" ] || continue
      if git -C "$repo" merge-base --is-ancestor "$sha" HEAD 2>/dev/null; then
        printf '### %s (since %s)\n' "$rel" "$(printf '%s' "$sha" | cut -c1-12)" >> "$delta_file"
        if [ "$rel" = . ]; then
          repo_diff "$repo" "" "$delta_names" "$delta_file" "$sha" ${outer_excl[@]+"${outer_excl[@]}"}
          ground_diff "$repo" "" "$sha" "$ground" ${outer_excl[@]+"${outer_excl[@]}"}
        else
          repo_diff "$repo" "$pfx" "$delta_names" "$delta_file" "$sha"
          ground_diff "$repo" "$pfx" "$sha" "$ground"
        fi
      else
        rewritten=1
      fi
    done < "$heads_prev"
    rm -f "$delta_names"
    [ "$rewritten" -eq 0 ] || : > "$delta_file.rewritten"
    # New ground (v0.12.4): the delta's line ranges, so the merge labels a new finding outside them `missed earlier`.
    # A rewritten branch has no delta to narrow to, and a delta that cannot be read leaves the rule off: both fail
    # safe toward reviewing the whole change.
    if [ "$rewritten" -eq 0 ]; then
      hunks_json="$(mktemp)"
      python3 "$RL" hunks "$ground" "$target" "$hunks_json" 2>/dev/null || { rm -f "$hunks_json"; hunks_json="-"; }
    fi
    rm -f "$ground"
  fi
  rm -f "$heads_prev"
  # The heads this review sees, for the next one's narrowing.
  heads_now="$(mktemp)"
  printf '.\t%s\n' "$(git -C "$target" rev-parse HEAD 2>/dev/null)" >> "$heads_now"
  for rel in ${nested_rel[@]+"${nested_rel[@]}"}; do
    h="$(git -C "$target/$rel" rev-parse HEAD 2>/dev/null)" && printf '%s\t%s\n' "$rel" "$h" >> "$heads_now"
  done
fi
[ "${#lenses[@]}" -gt 0 ] || lenses=(all)
prompt="$(mktemp)"
{
  printf 'Adversarial review. Find what is wrong with this change. Do NOT validate. Do NOT summarize.\n'
  printf 'Assume the author is overconfident. End with a line VERDICT: REFUTED or VERDICT: STANDS.\n'
  # The bar (verdict_of, top of this file): the labels decide the verdict, so the prompt asks for them by name.
  printf 'Label every finding heading, as your charter'"'"'s output format shows, with its severity (HIGH, MEDIUM or LOW), its input'"'"'s standing — observed (the input is in the evidence, fixtures, criteria or the target'"'"'s own code paths), plausible (you state a specific reason it could occur) or hypothetical (possible, nothing points to it) — and whether it is in scope or out of scope of the criteria'"'"'s Scope section (no Scope section: judge against the change'"'"'s evident intent, and report the missing section as an observed, in-scope LOW finding).\n'
  printf 'Label its reach too: reach: user (an ordinary action of the person using the feature meets it — name the action on an Action: line), reach: routine (a path the system runs on its own in ordinary operation: a schedule, a hook, startup, an update) or reach: none (only an unusual input, timing or configuration meets it). Add the flag data when it loses or corrupts the person'"'"'s data, trust when it crosses a trust boundary or weakens a guard, and live-only when only a live run can settle it.\n'
  printf 'The verdict is computed from those labels: an observed HIGH refutes at any reach; an in-scope observed or plausible HIGH or MEDIUM finding refutes when its reach is user or routine or it carries the data or trust flag. Everything else — reach none, hypothetical, out of scope, LOW — is listed for the operator as a backlog candidate, and a live-only finding is recorded as a live check; neither refutes. Report them all.\n\n'
  printf 'The change lives in the git checkout at %s. Paths in the diff and in the pitfalls are relative to that directory; read them there, by absolute path, with Read, Grep and Glob.\n' "$target"
  if [ "$mode" = promote ]; then
    printf 'Review mode: promote — the merge that will be pushed to %s, exactly; nothing uncommitted.\n\n' "$base"
  else
    printf 'Review mode: branch — one window'"'"'s branch: its commits since the base, then its uncommitted and untracked work.\n'
    # A broad first pass (v0.12.4): the first review of a branch is the one that may look everywhere, so it reports
    # everything at once; later reviews narrow to what changed since.
    if [ "$last_run" = "-" ]; then
      printf 'This is the branch'"'"'s first full review: report every defect you find, across all of your charter'"'"'s dimensions, rather than stopping once something refutes. Later reviews narrow to new ground.\n'
    fi
    printf '\n'
  fi
  printf '## Acceptance criteria\n'; [ -f "$criteria" ] && cat "$criteria" || printf '(none supplied)\n'
  printf '\n## Evidence\n'; cat "$evidence_file"
  printf '\n## Pitfalls that apply to the touched paths\n'
  if [ -n "$pitfalls_text" ]; then printf '%s\n' "$pitfalls_text"; else printf '(none)\n'; fi
  if [ -n "$section" ] && [ -s "$section" ]; then printf '\n'; cat "$section"; fi
  if [ -n "$delta_file" ]; then
    printf '\n## Changed since the last review (run %s)\n' "$last_run"
    if [ -f "$delta_file.rewritten" ]; then
      printf 'The branch was rewritten since that review (the commit it saw is no longer under HEAD): hunt the whole diff below.\n'
    elif grep -q '^diff --git ' "$delta_file"; then
      printf 'Hunt for new findings in this part of the change; the whole diff below is there to read around it. A new finding outside this part is labelled missed earlier and does not refute, unless it is an observed HIGH with the data or trust flag; report it all the same, as a backlog candidate.\n'
      cat "$delta_file"
    else
      printf 'Nothing changed since that review: check the earlier findings. A new finding is labelled missed earlier and does not refute, unless it is an observed HIGH with the data or trust flag; report it all the same, as a backlog candidate.\n'
    fi
  fi
  printf '\n## Diff against %s\n' "$base"
  # One section per repository (assembled above). Branch: committed work since
  # the merge base, then uncommitted and untracked work against HEAD. Promote:
  # the merge, trunk_sha_at_prepare..merge_sha.
  cat "$diff_file"
} > "$prompt"
rm -f "$paths" "$diff_file" ${delta_file:+"$delta_file" "$delta_file.rewritten"}
if [ "$render_only" -eq 1 ]; then
  cat "$prompt"; rm -f "$prompt"; exit 0
fi
verdict_file="$ev/$run_id-review.md"
# The launcher's exit code is load-bearing, and so is who spoke. 0 = the
# verdict file was written. 124 with "timed out after" on its stderr = the
# watchdog killed the reviewer. A refusal before launch (exit 2, no receipt
# line) carries its own sentence — a missing or unrenderable charter,
# modified distribution code, a review that already exists — and is passed on
# as it is. So is a refusal after the review ran (exit 2, the sentence on the
# orientation line after "exit: 2 — "): a verdict that appeared meanwhile
# (write-once) or distribution code changed during the review. Anything else
# is claude's own failure ("— failed: …"). All of them are exit 2 here:
# unknown is never STANDS.
# launch_failure <rc> <launcher-stderr-file> — the one sentence for a launch that did not write its verdict.
launch_failure() {
  local rc="$1" err="$2" refusal
  if [ "$rc" -eq 124 ] && grep -q 'timed out after' "$err"; then
    printf 'refuter timed out after %ss (verify.refute_timeout) — killed with its process group; cannot certify the run\n' "$(refute_timeout 2>/dev/null || printf '?')"
  elif ! grep -q ' call [0-9a-f-]*.*; receipt ' "$err"; then
    sed 's/^daedalus: //' "$err"
  elif refusal="$(sed -n 's/^.* orientation: .*; exit: 2 — //p' "$err" | grep -v '^failed: ' | head -1)" \
       && [ -n "$refusal" ]; then
    printf '%s — cannot certify the run; receipt: %s\n' "$refusal" "$(sed -n 's/^.*; receipt //p' "$err" | head -1)"
  else
    printf 'refuter CLI failed (exit %s, %s output) — cannot certify the run; receipt: %s\n' "$rc" \
      "$(grep -q '(with output)' "$err" && printf with || printf no)" "$(sed -n 's/^.*; receipt //p' "$err" | head -1)"
  fi
}
# cleanup_branch — the branch review's temporary files; and, when it ends without a verdict, a line saying the earlier
# findings the reviewers were shown stay as they were (the ledger is written only after a verdict).
recorded=0
cleanup_branch() {
  if [ "$recorded" -eq 0 ] && [ "${earlier_n:-0}" -gt 0 ]; then
    printf 'review-plan: %s shown to the reviewers; the ledger is unchanged, as this review gave no verdict\n' \
      "$(plural "$earlier_n" "earlier finding")" >&2
  fi
  rm -f "$prompt" ${section:+"$section" "$section.json"} ${heads_now:+"$heads_now"}
  [ "$hunks_json" = "-" ] || rm -f "$hunks_json"
}
if [ "${#lenses[@]}" -eq 1 ] && [ "${lenses[0]}" = all ] && [ "$earlier_n" -eq 0 ] && [ "$hunks_json" = "-" ]; then
  # One reviewer, no earlier findings to check and no new ground to mark: the launcher writes the review file
  # itself, as it always has. A later review goes through the merge, which labels findings outside the new ground.
  launch_err="$(mktemp)"
  bash "$DAEDALUS_HOME/core/call-agent.sh" --callee refuter --tree "$target" --request-file "$prompt" \
    --tag "$run_id" --verdict-file "$verdict_file" --mode "$mode" >/dev/null 2>"$launch_err"
  launch_rc=$?
  if [ "$launch_rc" -ne 0 ]; then
    launch_failure "$launch_rc" "$launch_err" >&2
    rm -f "$launch_err"; cleanup_branch
    exit 2
  fi
  rm -f "$launch_err" "$prompt"
else
  # Each lens is a fresh reviewer of its own (tag <run-id>-lens-<name>, review <run-id>-lens-<name>-review.md),
  # verify.lens_concurrency at a time (default 4), each under its own verify.refute_timeout. Every lens must
  # finish with a review that can be certified; one that times out, fails or writes an unlabelled finding fails the
  # whole run closed — a review with a lens missing is a smaller review than the one asked for, never a STANDS.
  # Write-once, as the launcher keeps it for the review it writes itself: the merge must never replace a verdict.
  if [ -e "$verdict_file" ]; then
    printf 'A review for this run already exists; a new verdict needs a new run.\n' >&2
    cleanup_branch
    exit 2
  fi
  conc="$(cfg verify.lens_concurrency 2>/dev/null || printf 4)"
  case "$conc" in
    ''|*[!0-9]*) conc=0 ;;
    *) conc=$((10#$conc)) ;;
  esac
  if [ "$conc" -lt 1 ]; then
    printf 'verify.lens_concurrency must be a whole number of 1 or more (got: %s) — cannot certify the run\n' \
      "$(cfg verify.lens_concurrency 2>/dev/null)" >&2
    cleanup_branch
    exit 2
  fi
  work="$(mktemp -d)"
  i=0
  for l in "${lenses[@]}"; do
    {
      if [ "$l" != all ]; then
        printf 'Your lens: %s. %s Search the whole change through this lens first; report anything else you find too, labelled the same way.\n\n' \
          "$l" "$(python3 "$RL" lens-text "$l")"
      fi
      cat "$prompt"
    } > "$work/$l.prompt"
    ( bash "$DAEDALUS_HOME/core/call-agent.sh" --callee refuter --tree "$target" --request-file "$work/$l.prompt" \
        --tag "$run_id-lens-$l" --verdict-file "$ev/$run_id-lens-$l-review.md" --mode "$mode" >/dev/null 2>"$work/$l.err"
      printf '%s\n' "$?" > "$work/$l.rc" ) &
    i=$((i + 1))
    [ $((i % conc)) -ne 0 ] || wait
  done
  wait
  rm -f "$prompt"
  failed=""; sources=()
  for l in "${lenses[@]}"; do
    lf="$ev/$run_id-lens-$l-review.md"
    rc="$(cat "$work/$l.rc" 2>/dev/null || printf 2)"
    if [ "$rc" -ne 0 ] || [ ! -f "$lf" ]; then
      failed="${failed}the $l lens: $(launch_failure "$rc" "$work/$l.err" | tr '\n' ' ' | sed 's/ *$//'); "
      continue
    fi
    # Written by the launcher under vault/evidence: manifested now, whatever the others did, so a lens review
    # never sits there unaccounted for.
    python3 "$DAEDALUS_HOME/core/manifest-append.py" "$lf" \
      || { failed="${failed}the $l lens: its review could not be added to the evidence manifest; "; continue; }
    lnotes="$(mktemp)"
    verdict_of "$lf" run >/dev/null 2>"$lnotes"
    if [ "$?" -eq 2 ]; then
      failed="${failed}the $l lens: $(tr '\n' ' ' < "$lnotes" | sed 's/ *$//') ($lf); "
    fi
    rm -f "$lnotes"
    sources+=("$l=$lf")
  done
  rm -rf "$work"
  if [ -n "$failed" ]; then
    printf '%s\n' "${failed%; } — cannot certify the run" >&2
    cleanup_branch
    exit 2
  fi
  # The merged review — what the run's verdict is read from — written beside the lenses' own.
  python3 "$RL" merge "$verdict_file" "$run_id" "$earlier_json" "$hunks_json" "${sources[@]}" \
    || { rm -f "$verdict_file"; cleanup_branch; exit 2; }
fi
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
# The verdict: verdict_of, defined at the top of this file. Its notes (what it counted, what it listed and did not
# count) go to stderr with the review file named, for gates.sh to show the operator.
notes="$(mktemp)"
word="$(verdict_of "$verdict_file" run 2>"$notes")"
rc=$?
if [ "$rc" -eq 2 ]; then
  if [ -s "$notes" ]; then
    printf '%s (%s)\n' "$(tr '\n' ' ' < "$notes" | sed 's/ *$//')" "$verdict_file" >&2
  else
    printf 'refuter wrote no VERDICT line — cannot certify the run (%s)\n' "$verdict_file" >&2
  fi
  rm -f "$notes"
  [ "$mode" != branch ] || cleanup_branch
  exit 2
fi
# Each note marked, so gates.sh shows these lines and nothing else this script happened to say on stderr.
[ ! -s "$notes" ] || sed "s|^|verdict-note: |; s|\$| — see $verdict_file|" "$notes" >&2
rm -f "$notes"
# The ledger, after a review that gave a verdict: earlier findings resolved or still open, new counted ones added,
# and the heads this review saw. A ledger that cannot be written costs the next review its narrowing, never this
# verdict.
if [ "$mode" = branch ]; then
  if tally="$(python3 "$RL" record "$DAEDALUS_HOME" "$lease_nn" "$tbranch" "$run_id" "$verdict_file" "$heads_now" 2>/dev/null)"; then
    set -- $tally
    if [ "${1:-0}" -gt 0 ]; then
      printf 'review-plan: %s: %s resolved, %s open%s\n' "$(plural "$1" "earlier finding")" "$2" "$3" \
        "$([ "${4:-0}" -gt 0 ] && printf '; %s new' "$4")" >&2
    elif [ "${4:-0}" -gt 0 ]; then
      printf 'review-plan: %s recorded for the next review to check\n' "$(plural "$4" "counted finding")" >&2
    fi
    if [ "${5:-0}" -gt 0 ] || [ "${6:-0}" -gt 0 ]; then
      printf 'review-plan: kept in the ledger, not counted: %s\n' "$( { [ "${5:-0}" -eq 0 ] || plural "$5" "backlog candidate"
        [ "${5:-0}" -eq 0 ] || [ "${6:-0}" -eq 0 ] || printf ' and '
        [ "${6:-0}" -eq 0 ] || plural "$6" "live check"; } )" >&2
    fi
  else
    printf 'review-plan: the findings ledger could not be written (state/review-ledger/) — the next review starts cold\n' >&2
  fi
  recorded=1
  cleanup_branch
fi
printf '%s\n' "$word"
exit "$rc"
