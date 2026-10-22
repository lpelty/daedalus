#!/usr/bin/env bash
# Run the target harness's gate commands and produce the evidence record.
# Green is an exit code; the record is what a claim cites.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e
set -uo pipefail

# A promotion's gate run (spec §7.1 step 7): `DAEDALUS_TARGET_OVERRIDE=<merged tree>
# core/gates.sh --no-refute --promote <promote-id>`, run by core/promote.sh only. The
# reviewer is skipped here because promote runs it itself on the merged diff; run.json
# then says refuter: deferred-to-promote and carries NO reason field (two fields, never
# one: an operator's --skip-review reason lives only in promote's own promotion object).
# --no-refute alone is refused: switching the branch reviewer off takes a written
# reason in config (verify.refute_off_reason). Validated before any side effect.
promote_id=""; no_refute=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --promote) promote_id="${2:-}"; [ -n "$promote_id" ] || die "--promote needs a promotion id"; shift 2 ;;
    --no-refute) no_refute=1; shift ;;
    *) die "usage: core/gates.sh [--no-refute --promote <promote-id>]" ;;
  esac
done
promo_ctx=""
if [ "$no_refute" -eq 1 ] && [ -z "$promote_id" ]; then
  die "--no-refute is only for a promotion (--promote <id>): promote reviews the merged diff itself; a plain run's reviewer is switched off only in config.yaml, with verify.refute_off_reason"
fi
if [ -n "$promote_id" ]; then
  case "$promote_id" in *[!A-Za-z0-9-]*) die "--promote: not a promotion id: $promote_id" ;; esac
  promo_ctx="$DAEDALUS_HOME/state/promote/$promote_id/context.json"
  [ -f "$promo_ctx" ] || die "--promote $promote_id: no state/promote/$promote_id/context.json — only core/promote.sh runs a promotion's gates"
  home_p="$(cd "$DAEDALUS_HOME" && pwd -P)"
  case "${DAEDALUS_TARGET_OVERRIDE:-}" in
    "$DAEDALUS_HOME/state/promote/$promote_id/"*|"$home_p/state/promote/$promote_id/"*) : ;;
    *) die "--promote $promote_id runs on the merged tree: DAEDALUS_TARGET_OVERRIDE must point under state/promote/$promote_id/" ;;
  esac
  # The promotion record is read here, before any run exists: a context.json the
  # run.json writers below cannot use would otherwise leave a PASS-labelled vault
  # summary and a printed run-id with no run.json behind them.
  ctx_msg="$(python3 - "$promo_ctx" "$promote_id" <<'PY'
import json, re, sys
path, pid = sys.argv[1:3]
where = "state/promote/%s/context.json" % pid
try:
    c = json.load(open(path))
except (OSError, ValueError) as e:
    print("%s cannot be read as JSON (%s)" % (where, e)); sys.exit(1)
if not isinstance(c, dict):
    print("%s is not a JSON object" % where); sys.exit(1)
if c.get("promote_id") != pid:
    print("%s names promotion %s, not %s" % (where, c.get("promote_id"), pid)); sys.exit(1)
if not (isinstance(c.get("lease"), str) and re.fullmatch(r"[0-9]{2}", c["lease"])):
    print("%s names no two-digit window number as its lease (got %r)" % (where, c.get("lease"))); sys.exit(1)
for k in ("merge_sha", "trunk_sha_at_prepare"):
    if not (isinstance(c.get(k), str) and c[k].strip()):
        print("%s has no %s" % (where, k)); sys.exit(1)
PY
)" || die "--promote $promote_id: ${ctx_msg:-the promotion record cannot be checked} — only core/promote.sh writes it; run promote again"
fi

# The gate definition must live inside this deployment. A config elsewhere
# is a gate the operator did not write.
home_real="$(cd "$DAEDALUS_HOME" && pwd -P)"
cfg_real="$(cd "$(dirname "$DAEDALUS_CONFIG")" 2>/dev/null && pwd -P)/$(basename "$DAEDALUS_CONFIG")"
case "$cfg_real" in
  "$home_real"/*) : ;;
  *) die "config $DAEDALUS_CONFIG resolves outside $DAEDALUS_HOME — refusing" ;;
esac

target="$(target_path)"
[ -d "$target" ] || die "no target checkout at $target — run core/sync-target.sh"

# Validation first, side effects after: everything below this point can die
# without having created a run directory, written fingerprint.err, or
# touched the manifest — an early-die evidence tree with nothing to point a
# BLOCKED claim at, which the boundary check then flags as unmanifested with
# no remedy. So both checks that can `die` run BEFORE any evidence
# directory, fingerprint, or run-id exists.

# The evidence row format below is tab-delimited. A literal tab inside a gate
# command would silently corrupt that format — line.split("\t", 4) absorbs the
# extra field into the wrong column instead of erroring. config.yaml is
# operator-authored, so a tab in a gate command is an error, not a use case:
# refuse loudly, upfront, before any gate runs or any evidence is recorded.
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  case "$gate" in
    *"$(printf '\t')"*) die "config gates: gate command contains a tab character — refusing (the evidence row format is tab-delimited): $gate" ;;
  esac
done <<EOF
$(cfg_list gates)
EOF
while IFS= read -r step; do
  [ -n "$step" ] || continue
  case "$step" in
    *"$(printf '\t')"*) die "config gates_setup: step contains a tab character — refusing (the evidence row format is tab-delimited): $step" ;;
  esac
done <<EOF
$(cfg_list gates_setup)
EOF

# Zero-gates refusal, also moved ahead of any evidence-directory creation —
# counted directly off cfg_list's output rather than the gate-count computed
# during the run loop below, since that loop hasn't executed yet at this point.
gate_list_count="$(cfg_list gates | grep -c .)" || gate_list_count=0
[ "$gate_list_count" -gt 0 ] || die "no gates configured — refusing to report success (check the gates: list in config.yaml)"

# gates_rerun_failed (v0.12.8, spec 2026-10-21 C): optional, one command per gate, in the gates' order — `""` for a
# gate with none. The same trust as gates:, and the same tab rule (a rerun is logged in the same row format). A list
# longer than gates: names a rerun for a gate that does not exist — almost certainly a list that drifted out of line
# with the gates — so it is refused here, before a run id exists, rather than pairing commands with the wrong gates.
while IFS= read -r rr; do
  case "$rr" in
    *"$(printf '\t')"*) die "config gates_rerun_failed: command contains a tab character — refusing (the evidence row format is tab-delimited): $rr" ;;
  esac
done <<EOF
$(cfg_list gates_rerun_failed)
EOF
rerun_list_count="$(cfg_list gates_rerun_failed | wc -l | tr -d ' ')"
if [ "$rerun_list_count" -gt "$gate_list_count" ]; then
  die "config gates_rerun_failed has $rerun_list_count commands but gates: has $gate_list_count — one rerun command per gate, in the same order (\"\" for a gate with none); refusing before any gate runs"
fi
# is_compound <command> — true when a gate is more than one command (&&, ||, ;, |), after one leading `cd <dir> &&`.
is_compound() {
  local c="$1"
  c="$(printf '%s' "$c" | sed -E 's/^[[:space:]]*cd[[:space:]]+[^;&|[:space:]]+[[:space:]]*&&//')"
  case "$c" in *'&&'*|*'||'*|*';'*|*'|'*) return 0 ;; esac
  return 1
}
# rerun_of <n> — gate n's rerun command, or nothing.
rerun_of() { cfg_list gates_rerun_failed | sed -n "${1}p"; }

# The refuter is ON unless the operator says otherwise, in writing. An
# unset verify.refute means true. `verify.refute: false` is honored only
# with a non-empty verify.refute_off_reason beside it — an off-switch with
# no reason is indistinguishable from an off-switch nobody meant to leave
# on, and a green run nobody reviewed is this repo's founding pitfall.
# Anything else is a typo, refused. All of it before a run-id exists.
refute_on=1
refute_cfg="$(cfg verify.refute 2>/dev/null || true)"
case "$refute_cfg" in
  ""|true) refute_on=1 ;;
  false)
    refute_off_reason="$(cfg verify.refute_off_reason 2>/dev/null || true)"
    if [ -z "$refute_off_reason" ]; then
      die "config verify.refute is false but verify.refute_off_reason is empty — the refuter runs after every PASS unless you say, in verify.refute_off_reason, why it should not; refusing before any gate runs"
    fi
    refute_on=0
    ;;
  *) die "config verify.refute must be true or false (got: $refute_cfg) — refusing before any gate runs" ;;
esac
# A promotion's reviewer runs in core/promote.sh (spec §7.1 step 8), whatever verify.refute says.
[ -n "$promote_id" ] && refute_on=0

# The refuter's timeout is operator config too. Discovered late — inside
# refute.sh, after every gate has run — a typo there records a FAIL run.json
# and vault summary that read, in the evidence, exactly like a real
# refutation. Refuse it here, with the other config errors, before a run-id
# exists. refute.sh re-checks (belt to this brace) but should never be the
# one to find it. An ABSENT verify.refute_timeout is fine: lib.sh
# refute_timeout defaults it to 600 seconds, so default-on needs no
# timeout line in config.yaml.
if [ "$refute_on" -eq 1 ]; then
  refute_timeout >/dev/null || die "config verify.refute_timeout is invalid — refusing before any gate runs"
fi

# --- Where the gates run: the tree in place, or a clean copy of its commit (v0.12.8, spec 2026-10-22 revisions, C2) ---
# A window's PASS can depend on what the fingerprint does not see: git-ignored files such as a .venv or a .env. Promote's
# own run, in a scratch of tracked files only, was what caught that — and on 2026-10-22 the operator called running the
# suite again "where the only change was me saying the word promote" pointless. So a window's run becomes the run
# promote can use when its tree is committed: when every repository of the tree under test (the target and each
# target.nested checkout) is clean — nothing modified, staged or untracked that git sees — the setup steps and gates
# run in a fresh scratch checkout of exactly that commit, tracked files only, cut the way promote cuts its scratch
# (git worktree add --detach per repository, nested inside the outer, target.scaffold directories created), under
# state/clean-copy/<run-id>/. The record says tree: "clean-copy" and names the commit(s). A dirty tree runs in place,
# tree: "worktree", exactly as before. A promotion's run is already in promote's scratch (tree: "promote-scratch").
# The fingerprint is taken of the tree under test as always; the commit is read before and again after it, so the
# scratch holds exactly what was fingerprinted. A status git cannot give is never "clean": that tree runs in place.
tree_mode=worktree; clean_commit=""; clean_nested=""
nested_rels="$(cfg_pairs target.nested 2>/dev/null | cut -f1)"
# repo_heads — "<rel>\t<sha>" per repository of the tree under test ("." the target), or nothing when any is dirty,
# is not a repository, or cannot be read.
repo_heads() {
  local rel dir sha st out=""
  for rel in . $nested_rels; do
    dir="$target"; [ "$rel" = . ] || dir="$target/$rel"
    is_work_tree_root "$dir" 2>/dev/null || return 1
    st="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null)" || return 1
    [ -z "$st" ] || return 1
    sha="$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null)" || return 1
    out="$out$rel	$sha
"
  done
  printf '%s' "$out"
}
if [ -z "$promote_id" ]; then
  if heads_before="$(repo_heads)" && [ -n "$heads_before" ]; then
    tree_mode=clean-copy
  fi
else
  tree_mode=promote-scratch
fi

run_id="$(date +%Y%m%d-%H%M%S)-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
ev_state="$DAEDALUS_HOME/state/evidence/$run_id"
ev_vault="$DAEDALUS_HOME/vault/evidence"
mkdir -p "$ev_state" "$ev_vault" || die "cannot create evidence directories"
started="$(date +%Y-%m-%dT%H:%M:%S)"

# The started record, FIRST (spec §4.9): a manifested run.json that says
# RUNNING and names this session's window is what lets every other window's
# Stop excuse this run's files while it runs. Manifested together with the
# vault summary path in ONE locked append (the path is known before the
# file exists), so the common case needs no excuse at all. Every later
# manifest line goes through manifest-append.py too: two windows running
# gates at once used to interleave `>>` appends into half paths.
lease_nn="$(python3 "$DAEDALUS_HOME/core/leaselib.py" my-lease 2>/dev/null || true)"
session_id="${DAEDALUS_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
python3 - "$ev_state/run.json" "$run_id" "$started" "$lease_nn" "$session_id" "$promo_ctx" <<'PY'
import json, sys
out, run_id, started, lease, sid, ctx = sys.argv[1:7]
rec = {"run_id": run_id, "started": started, "lease": lease or None, "session_id": sid or None, "result": "RUNNING"}
if ctx:
    c = json.load(open(ctx))
    rec.update({k: c.get(k) for k in ("promote_id", "merge_sha", "trunk_sha_at_prepare", "repo", "nested")})
    rec.update({"lease": c.get("lease"), "tree": "promote-scratch", "refuter": "deferred-to-promote"})
with open(out, "w") as fh:
    json.dump(rec, fh, indent=2)
PY
[ "$?" -eq 0 ] || die "cannot write run.json for run $run_id"
python3 "$DAEDALUS_HOME/core/manifest-append.py" "$ev_state/run.json" "$ev_vault/$run_id.md" || die "cannot append to the evidence manifest"

fingerprint() {
  if [ -f "$DAEDALUS_HOME/core/fingerprint.sh" ]; then
    bash "$DAEDALUS_HOME/core/fingerprint.sh" 2>"$ev_state/fingerprint.err" || printf 'null\n'
  else
    printf 'null\n'
  fi
}

config_sha="$(shasum -a 256 "$DAEDALUS_CONFIG" | awk '{print $1}')"
fp_before="$(fingerprint)"
fp_secs="$(sed -n 's/^fingerprint_secs=//p' "$ev_state/fingerprint.err" 2>/dev/null | tail -1)"
[ -n "$fp_secs" ] || fp_secs=0

# --- Has this exact tree already passed these gates? (v0.12.8, spec 2026-10-21 A) ------------------------------
# On 2026-10-21 one combined release ran a ~3,100-test suite (9–12 minutes) seven times on nearly the same code; the
# seventh was promote's, on a merged tree byte-identical to the one that had just passed, and an eighth was one
# --skip-review away. Nothing asked "has this exact tree already passed?" although every run.json records what it
# takes to answer: the tree's content fingerprint (fingerprint.sh — independent of HEAD and the index, untracked
# content included), the config_sha of the gate definition and the outcome. So, before any setup step or gate: an
# earlier run with the same fingerprint, the same config_sha and the same distribution core/ tree, whose gates all
# passed, makes this run PASS by reuse — a normal record and summary, manifested the same way, carrying reused_from
# and the earlier run's gate rows, and no setup or gate command executed. Here, so every caller gets it unchanged:
# promote's prepare, --skip-review's prepare, a window re-running gates on a tree it has not changed.
#
# What counts as "passed its gates": gates_result PASS — the gates' outcome before the reviewer spoke. A run whose
# review REFUTED it, or that the reviewer could not certify, is result FAIL, but its gates passed, and the same tree
# passes them again; the reviewer is a separate rung and still runs on this run as on any PASS (verify.refute).
# Never reused: a null fingerprint (fingerprint.sh's own rule — null is never citable, so it matches nothing), a
# gates FAIL, an INVALID or RUNNING run, a run from before this release (it records no core_tree), and a run.json the
# manifest does not list: the boundary hook sanctions evidence only when it is manifested and has its state-side
# record, and a hand-written run.json at a path gates.sh never manifested is not evidence gates.sh wrote. The vault
# summary must be manifested too and name the same fingerprint and config-sha.
#
# The distribution core/ tree is HEAD:core of this home (distcheck.committed_dist), recorded only while core/ on
# disk is exactly HEAD's (distcheck.distribution_state): a modified core/ records null and matches nothing, since
# the gate runner and fingerprint that produced an earlier PASS must be the ones running now. A home that is not a
# git checkout, or one without distcheck.py, records null — no reuse, exactly the behaviour before this release.
#
# Fast with many runs: run ids sort by time, so the newest are read first and the first match ends the search; a
# run.json whose raw text does not contain this fingerprint is skipped before it is parsed; the manifest is read
# once. Never fails the run: anything it cannot read is a run it does not reuse.
# The commit read before the fingerprint must still be the tree's after it, still clean; otherwise the tree moved
# while it was fingerprinted and the run stays in place.
if [ "$tree_mode" = clean-copy ]; then
  heads_after="$(repo_heads)" || heads_after=""
  if [ "$heads_after" = "$heads_before" ]; then
    clean_commit="$(printf '%s' "$heads_before" | awk -F'\t' '$1=="." {print $2}')"
  else
    tree_mode=worktree
  fi
fi

# Which earlier runs may stand for this one (spec 2026-10-22 revisions): a promotion's run and a clean-copy run reuse
# only a promote-grade run — one that ran in a clean copy or in promote's scratch, tracked files only — and a
# promotion's run only one recorded under the deployment's own config.yaml (its config_sha is the current one's, never
# merely equal to some earlier run's: a window can run gates under an in-home copy of the config). A window's
# worktree run, which can depend on git-ignored files, is reused only by the same window's next run in place.
home_config_sha="$(shasum -a 256 "$DAEDALUS_HOME/config.yaml" 2>/dev/null | awk '{print $1}')"
core_tree="null"; reused_from=""; reused_gates="$(mktemp)" || die "cannot create a temp file for the reuse lookup"
IFS= read -r -d '' reuse_script <<'PY'
import json, os, re, sys
home, fp, config_sha, own, out, mode, lease, home_config_sha = sys.argv[1:9]
core_tree = None
try:
    sys.dont_write_bytecode = True          # a new core/__pycache__ would itself be a modified core/
    sys.path.insert(0, os.path.join(home, "core"))
    import distcheck as dc
    from pathlib import Path
    root = Path(home).resolve()
    if dc.distribution_state(root, paths=("core",))[0] == "clean":
        core_tree = dc.committed_dist(root).get("core_tree")
except Exception:
    core_tree = None
print(core_tree or "null")
if not core_tree or not re.fullmatch(r"[0-9a-f]{64}", fp or ""):
    sys.exit(0)
ev_state = os.path.join(home, "state", "evidence")
ev_vault = os.path.join(home, "vault", "evidence")
try:
    with open(os.path.join(ev_vault, ".manifest")) as fh:
        manifest = {os.path.realpath(ln.strip()) for ln in fh if ln.strip()}
    names = sorted((n for n in os.listdir(ev_state) if re.fullmatch(r"[0-9]{8}-[0-9]{6}-[0-9a-f]{6}", n) and n != own),
                   reverse=True)
except OSError:
    sys.exit(0)
def frontmatter(path):
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return {}
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return dict(ln.split(": ", 1) for ln in (m.group(1).splitlines() if m else []) if ": " in ln)
for name in names:
    rj = os.path.join(ev_state, name, "run.json")
    try:
        raw = open(rj).read()
    except OSError:
        continue
    if fp not in raw or os.path.realpath(rj) not in manifest:
        continue
    try:
        rec = json.loads(raw)
    except ValueError:
        continue
    gates = rec.get("gates") if isinstance(rec, dict) else None
    if (rec.get("run_id") != name or rec.get("fingerprint") != fp or rec.get("config_sha") != config_sha
            or rec.get("core_tree") != core_tree or rec.get("gates_result") != "PASS"
            or rec.get("result") not in ("PASS", "FAIL") or rec.get("invalid_reason") or rec.get("setup_failed")
            or not isinstance(gates, list) or not gates
            or not all(isinstance(g, dict) and g.get("exit") == 0 for g in gates)):
        continue
    grade = rec.get("tree") in ("clean-copy", "promote-scratch")
    if mode == "promote-scratch" and not (grade and config_sha == home_config_sha):
        continue
    if mode == "clean-copy" and not grade:
        continue
    if mode == "worktree" and not grade and not (rec.get("tree") == "worktree" and (rec.get("lease") or "") == lease):
        continue
    summary = os.path.join(ev_vault, name + ".md")
    fm = frontmatter(summary)
    if (os.path.realpath(summary) not in manifest or fm.get("fingerprint") != fp
            or fm.get("config-sha") != config_sha):
        continue
    with open(out, "w") as fh:
        json.dump({"gates": gates, "tree": rec.get("tree"), "commit": rec.get("commit"),
                   "nested_commits": rec.get("nested_commits")}, fh)
    print(name)
    break
PY
reuse_out="$(python3 -c "$reuse_script" "$DAEDALUS_HOME" "$fp_before" "$config_sha" "$run_id" "$reused_gates" \
  "$tree_mode" "$lease_nn" "$home_config_sha" 2>/dev/null)"
core_tree="$(printf '%s\n' "$reuse_out" | sed -n 1p)"
reused_from="$(printf '%s\n' "$reuse_out" | sed -n 2p)"
[ -n "$core_tree" ] || core_tree="null"
case "$reused_from" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
  *) reused_from="" ;;
esac

# The clean copy (C2 above), cut only when something will run in it. Outer first, the nested repositories inside it,
# each at the commit read before the fingerprint; then target.scaffold's directories, as promote's cut_scratch makes
# them. Removed when the gates are done (the logs live under state/evidence, not here) and on any exit. A copy that
# cannot be cut is said, and the run goes on in place as a worktree run — never promote-grade by accident.
run_dir="$target"; clean_dir=""
remove_clean_copy() {
  [ -n "$clean_dir" ] || return 0
  local rel
  for rel in $(printf '%s\n' $nested_rels | awk '{print length, $0}' | sort -rn | cut -d' ' -f2-) .; do
    if [ "$rel" = . ]; then
      git -C "$target" worktree remove --force "$run_dir" >/dev/null 2>&1
      git -C "$target" worktree prune >/dev/null 2>&1
    else
      git -C "$target/$rel" worktree remove --force "$run_dir/$rel" >/dev/null 2>&1
      git -C "$target/$rel" worktree prune >/dev/null 2>&1
    fi
  done
  rm -rf "$clean_dir"
  clean_dir=""
}
trap remove_clean_copy EXIT
if [ "$tree_mode" = clean-copy ] && [ -z "$reused_from" ]; then
  clean_dir="$DAEDALUS_HOME/state/clean-copy/$run_id"
  run_dir="$clean_dir/$(basename "$target")"
  cut_ok=1
  mkdir -p "$clean_dir" || cut_ok=0
  while IFS="$(printf '\t')" read -r rel sha; do
    [ -n "$rel" ] && [ "$cut_ok" -eq 1 ] || continue
    if [ "$rel" = . ]; then
      git -C "$target" worktree add -q --detach "$run_dir" "$sha" >/dev/null 2>&1 || cut_ok=0
    else
      clean_nested="$clean_nested$rel=$sha,"
      git -C "$target/$rel" worktree add -q --detach "$run_dir/$rel" "$sha" >/dev/null 2>&1 || cut_ok=0
    fi
  done <<EOF
$heads_before
EOF
  if [ "$cut_ok" -eq 1 ]; then
    while IFS= read -r sc; do
      [ -n "$sc" ] && mkdir -p "$run_dir/$sc"
    done <<EOF
$(cfg_pairs target.scaffold 2>/dev/null | cut -f1)
EOF
    log "clean tree: the gates run in a fresh copy of commit ${clean_commit:0:12} (tracked files only)"
  else
    log "the clean copy of commit ${clean_commit:0:12} could not be cut; the gates run in place (tree: worktree)"
    remove_clean_copy
    run_dir="$target"; tree_mode=worktree; clean_nested=""
  fi
fi
# tree_moved — true when the tree under test is no longer the tree that was fingerprinted: in a clean copy, any
# repository of it with something git sees changed (it holds exactly the fingerprinted commit, so that is the same
# question, asked without fingerprinting a tree outside state/promote); in place, a fingerprint that differs.
tree_moved() {
  if [ -n "$clean_dir" ]; then
    local rel dir st
    for rel in . $nested_rels; do
      dir="$run_dir"; [ "$rel" = . ] || dir="$run_dir/$rel"
      st="$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null)" || return 0
      [ -z "$st" ] || return 0
    done
    return 1
  fi
  local now; now="$(fingerprint)"
  [ "$now" = "null" ] || [ "$now" != "$fp_before" ]
}

# gates_setup (2026-10-14): commands that prepare the tree under test — a window's
# worktree, or promote's scratch, which holds tracked files only — before any gate
# runs (a build environment, say). Same trust as gates:, same cwd, logged beside
# the gate logs. Run AFTER the first fingerprint: what a step leaves behind must be
# invisible to git, because the fingerprinted tree is the tree of the commit promote
# pushes (Decision 37). A step that fails, or one that changes what git sees, ends
# the run INVALID before any gate — never FAIL: nothing was tested.
setup_rows=""; setup_count=0; setup_failed=0; invalid_reason=""; fail_log=""
while IFS= read -r step; do
  [ -n "$step" ] || continue
  setup_count=$((setup_count + 1))
  log_file="$ev_state/setup-$setup_count.log"
  t0=$(date +%s)
  ( cd "$run_dir" && eval "$step" ) </dev/null >"$log_file" 2>&1
  code=$?
  dur=$(( $(date +%s) - t0 ))
  setup_rows="$setup_rows
$setup_count	$code	$dur	$log_file	$step"
  if [ "$code" -eq 0 ]; then
    log "SETUP $step"
  else
    log "SETUP FAIL  $step"
    setup_failed=$setup_count
    invalid_reason="setup step $setup_count \`$step\` exit $code, so no gate ran: the tree under test could not be prepared"
    fail_log="$log_file"
    break
  fi
done <<EOF
$([ -n "$reused_from" ] || cfg_list gates_setup)
EOF
if [ "$setup_failed" -eq 0 ] && [ "$setup_count" -gt 0 ]; then
  if tree_moved; then
    invalid_reason="gates_setup changed the tree under test (git sees what a step left behind), so no gate ran: what a setup step leaves behind must be ignored by git"
  fi
fi

failed=0
gate_count=0
rows=""
rerun_rows=""
while IFS= read -r gate; do
  [ -n "$gate" ] || continue
  gate_count=$((gate_count + 1))
  log_file="$ev_state/gate-$gate_count.log"
  t0=$(date +%s)
  # Operator-authored config, deliberately trusted — eval is intentional.
  # stdin from /dev/null so a gate that reads stdin cannot eat the list.
  ( cd "$run_dir" && eval "$gate" ) </dev/null >"$log_file" 2>&1
  code=$?
  dur=$(( $(date +%s) - t0 ))
  # A failed gate with a gates_rerun_failed command (spec 2026-10-21 C): on 2026-10-21 two runs of an 11-minute
  # suite each failed on one flaky test, so the reviewer never ran and the whole suite repeated just to reach it. The
  # rerun command runs ONCE, in the same tree — the fingerprint is taken again first, and a tree that changed since
  # the run started is not re-run (a pass on another tree says nothing about this one). Exit 0 makes the gate PASS
  # after a rerun: its row then carries the rerun's exit and log, and rerun_rows keeps the first run's exit and log,
  # so both logs stay in the evidence and the summary names it. Anything else and the gate FAILs as before, with the
  # rerun's log as its log (what still fails). No command for the gate: exactly as before this release.
  rerun_cmd=""
  [ "$code" -eq 0 ] || rerun_cmd="$(rerun_of "$gate_count")"
  # M1 (review 2026-10-22): a rerun must cover the whole gate. A compound gate (&&, ||, ;, |) is several commands,
  # and a rerun of the failures of one would PASS a gate whose other parts never ran again, or never ran at all, so it
  # gets no rerun. One leading `cd <dir> &&` is not a second test, only where the gate runs, and is not compound.
  if [ -n "$rerun_cmd" ] && is_compound "$gate"; then
    rerun_rows="$rerun_rows
$gate_count	$code	$dur	$log_file	compound	$rerun_cmd"
    log "gate $gate_count is a compound command; its failures are not re-run (a rerun could cover only part of it)"
    rerun_cmd=""
  fi
  if [ -n "$rerun_cmd" ]; then
    first_code=$code; first_dur=$dur; first_log="$log_file"
    if tree_moved; then
      rerun_rows="$rerun_rows
$gate_count	$first_code	$first_dur	$first_log	tree-changed	$rerun_cmd"
      log "gate $gate_count failed; its failures were not re-run: the tree changed after it failed"
    else
      log "FAIL  $gate — re-running its failures once: $rerun_cmd"
      log_file="$ev_state/gate-$gate_count-rerun.log"
      t0=$(date +%s)
      ( cd "$run_dir" && eval "$rerun_cmd" ) </dev/null >"$log_file" 2>&1
      code=$?
      dur=$(( first_dur + $(date +%s) - t0 ))
      rerun_outcome=failed
      [ "$code" -ne 0 ] || rerun_outcome=passed
      rerun_rows="$rerun_rows
$gate_count	$first_code	$first_dur	$first_log	$rerun_outcome	$rerun_cmd"
      if [ "$code" -eq 0 ]; then
        log "gate $gate_count passed after re-running its failures (first run log: $first_log)"
      else
        log "gate $gate_count failed again when its failures were re-run (rerun log: $log_file)"
      fi
    fi
  fi
  if [ "$code" -eq 0 ]; then
    log "PASS  $gate"
  else
    log "FAIL  $gate"
    failed=1
    fail_log="$log_file"
    if [ "$code" -eq 127 ] || [ "$code" -eq 126 ]; then
      log "gate $gate_count could not start (exit $code: command not found or not executable) — the tree under test may lack build output; a gates_setup: step in config.yaml can build it before the gates (a change that needs a restart: CLAUDE.md, \"Changes that need a restart\")"
    fi
  fi
  rows="$rows
$gate_count	$code	$dur	$log_file	$gate"
done <<EOF
$([ -n "$invalid_reason" ] || [ -n "$reused_from" ] || cfg_list gates)
EOF

# A reused run (A above): the earlier run's gate rows are this run's, as they were recorded — their logs are that
# run's logs, already manifested — and nothing ran, so the tree cannot have moved under a gate.
if [ -n "$reused_from" ]; then
  IFS= read -r -d '' rows_script <<'PY'
import json, sys
for g in json.load(open(sys.argv[1]))["gates"]:
    print("\t".join(str(x) for x in (g["n"], g["exit"], g.get("duration_s") or 0, g["log"], g["command"])))
PY
  rows="$(python3 -c "$rows_script" "$reused_gates")" || die "cannot read the gate rows of run $reused_from"
  # L3 (review 2026-10-22): a reused gate that passed only after a rerun says so, so the reuse never hides it.
  reused_notes="$(python3 -c 'import json, sys
for g in json.load(open(sys.argv[1]))["gates"]:
    if (g.get("rerun") or {}).get("outcome") == "passed":
        print("gate %s passed after re-running its failures in run %s (first run log: `%s`)." % (g["n"], sys.argv[2], g["rerun"].get("first_log")))
' "$reused_gates" "$reused_from" 2>/dev/null)"
  rows="
$rows"
  gate_count="$(printf '%s\n' "$rows" | grep -c .)"
  log "PASS — reused from run $reused_from (same tree, same gates); nothing re-ran."
  fp_after="$fp_before"
elif [ -n "$clean_dir" ]; then
  # In a clean copy the worktree may change while the gates run without touching what was tested; what the gates
  # must not have changed is the copy. Then the copy goes; the logs stay under state/evidence.
  if tree_moved; then fp_after="changed"; else fp_after="$fp_before"; fi
  remove_clean_copy
else
  fp_after="$(fingerprint)"
fi
result=PASS
[ "$failed" -ne 0 ] && result=FAIL
[ -n "$invalid_reason" ] && result=INVALID
if [ "$fp_before" = "null" ] || [ "$fp_after" = "null" ] || [ "$fp_before" != "$fp_after" ]; then
  result=INVALID
fi
# The gates' own outcome, kept apart from `result`, which the reviewer may still turn to FAIL below: reuse (A above)
# asks whether this tree passed its gates, not whether a review stood.
gates_result="$result"

# The evidence summary — no output excerpt; the vault is a pushed
# repository. Written FIRST to a temp file outside the evidence tree, and
# copied into the vault only after the refuter has spoken, with the final
# result. The vault copy used to be written here, before the refute call,
# with `result: PASS`, and its manifest line only at the end: for the whole
# length of an opus review (up to verify.refute_timeout) a PASS-labelled
# evidence file sat under vault/evidence/** with no manifest line and no
# run.json — and a review killed from outside (a Bash tool timeout is
# 120 s by default) left it there for good, under a protected path Daedalus
# cannot remove: exactly the unmanifested evidence with no remedy that the
# validation-first rule above exists to prevent. refute.sh reads the
# summary from the path passed as its third argument.
write_summary() {   # write_summary <path> <result>
  {
    printf -- '---\ntype: evidence\nrun-id: %s\nresult: %s\nfingerprint: %s\nconfig-sha: %s\ncreated: %s\n---\n' \
      "$run_id" "$2" "$fp_before" "$config_sha" "$started"
    printf '# Gate run %s — %s\n\n' "$run_id" "$2"
    if [ -n "$promote_id" ]; then printf 'Reviewer: runs on the merged diff in this promotion\n\n'; fi
    printf '| # | command | exit | seconds | log |\n|---|---|---|---|---|\n'
    printf '%s\n' "$rows" | while IFS="$(printf '\t')" read -r n code dur logf cmd; do
      [ -n "$n" ] || continue
      printf '| %s | `%s` | %s | %s | `%s` |\n' "$n" "$cmd" "$code" "$dur" "$logf"
    done
    if [ -n "$(printf '%s' "$setup_rows" | tr -d '\n')" ]; then
      printf '\nSetup, before the gates:\n\n| # | command | exit | seconds | log |\n|---|---|---|---|---|\n'
      printf '%s\n' "$setup_rows" | while IFS="$(printf '\t')" read -r n code dur logf cmd; do
        [ -n "$n" ] || continue
        printf '| %s | `%s` | %s | %s | `%s` |\n' "$n" "$cmd" "$code" "$dur" "$logf"
      done
    fi
    [ -z "$reused_from" ] || printf '\nPASS — reused from run %s (same tree, same gates); nothing re-ran.\n' "$reused_from"
    [ -z "${reused_notes:-}" ] || printf '%s\n' "$reused_notes"
    if [ -n "$(printf '%s' "$rerun_rows" | tr -d '\n')" ]; then
      printf '\n'
      printf '%s\n' "$rerun_rows" | while IFS="$(printf '\t')" read -r n fcode fdur flog outcome cmd; do
        [ -n "$n" ] || continue
        case "$outcome" in
          passed) printf 'gate %s passed after re-running its failures (first run log: `%s`).\n' "$n" "$flog" ;;
          failed) printf 'gate %s failed again when its failures were re-run (first run log: `%s`).\n' "$n" "$flog" ;;
          compound) printf "gate %s is a compound command, so its failures were not re-run: a rerun could cover only part of it (first run log: \`%s\`).\n" "$n" "$flog" ;;
          *) printf "gate %s's failures were not re-run: the tree changed after it failed (first run log: \`%s\`).\n" "$n" "$flog" ;;
        esac
      done
    fi
    [ -z "$invalid_reason" ] || printf '\nINVALID: %s\n' "$invalid_reason"
  } > "$1"
}
summary_tmp="$(mktemp)" || die "cannot create a temp file for the evidence summary"
write_summary "$summary_tmp" "$result"

# Everything under the run directory that is complete at this point goes
# into the manifest BEFORE the refuter runs: the gate logs and the
# fingerprint error file are what they are, verdict or no verdict. If the
# review is killed from outside, what is left behind is manifested and
# carries no result at all — the final run.json and the vault summary come
# after (their paths were manifested at the start). The paths go one per
# line on stdin (`-`), never through an unquoted $(...): word-splitting once
# cut every path at a space in DAEDALUS_HOME into fragments, each manifested,
# none a file — and the session's own Stop then blocked on its own gate logs.
{
  [ -f "$ev_state/fingerprint.err" ] && printf '%s\n' "$ev_state/fingerprint.err"
  printf '%s\n' "$setup_rows" | awk -F'\t' 'NF {print $4}'
  printf '%s\n' "$rows" | awk -F'\t' 'NF {print $4}'
  printf '%s\n' "$rerun_rows" | awk -F'\t' 'NF {print $4}'
} | python3 "$DAEDALUS_HOME/core/manifest-append.py" - \
  || die "cannot append to the evidence manifest"

# refuted_choices <lease-nn> — count this REFUTED against the window's branch, and from the second on print the
# operator's three choices (2026-10-19). A small fix to code that reads an outside service was refuted five runs
# running and the loop was left to the builder, who kept widening the change; after two refutations the call is the
# operator's. The count lives in state/refutations/<NN>.json and starts again when the window's lease is new (its
# created time changed: released and taken again) or has promoted since (its promoted list grew); an unleased run
# counts against the target's checked-out branch. Never fails the run: a count it cannot keep is a count not shown.
refuted_choices() {
  local n script branch
  branch="$(git -C "$(target_path 2>/dev/null || printf .)" symbolic-ref --short -q HEAD 2>/dev/null || true)"
  # read, not a heredoc inside $(...): bash 3.2 mis-parses quotes in a heredoc body there
  IFS= read -r -d '' script <<'PY'
import json, os, sys
home, nn, branch = sys.argv[1:4]
key = {"lease": nn or None, "branch": branch or None}
if nn:
    try:
        lease = json.load(open(os.path.join(home, "state", "leases", nn + ".json")))
    except (OSError, ValueError):
        lease = {}
    key.update(created=lease.get("created"), promoted=len(lease.get("promoted") or []))
d = os.path.join(home, "state", "refutations")
os.makedirs(d, exist_ok=True)
path = os.path.join(d, (nn or "unleased") + ".json")
try:
    rec = json.load(open(path))
except (OSError, ValueError):
    rec = {}
count = (rec.get("count") or 0) + 1 if rec.get("key") == key else 1
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump({"key": key, "count": count}, fh)
os.replace(tmp, path)
print(count)
PY
  n="$(python3 -c "$script" "$DAEDALUS_HOME" "${1:-}" "$branch" 2>/dev/null)" || return 0
  case "$n" in ''|*[!0-9]*) return 0 ;; esac
  [ "$n" -ge 2 ] || return 0
  local who="this branch"
  [ -z "${1:-}" ] || who="window $1's branch"
  log "${who} has been refuted $n times. The operator chooses, in their own words, one of three:"
  log "  another round — fix the counted findings and run the gates again;"
  log "  promote with the remaining findings filed as backlog rows (the reason names the rows);"
  log "  or skip the review with the operator's reason: core/promote.sh ${1:-<NN>} --skip-review --reason \"<their reason>\"."
}

if [ "$result" = PASS ] && [ "$refute_on" -eq 1 ]; then
  # The review's criteria: GATES_CRITERIA when set; else the file this window named with
  # `core/lease.sh update <NN> --criteria <file>` — the same file promote's review reads. Until
  # v0.12.8 only promote read it, and a branch run told its reviewer "(none supplied)" (PROP-037).
  criteria="${GATES_CRITERIA:-}"
  if [ -z "$criteria" ] && [ -n "$lease_nn" ]; then
    criteria="$(python3 "$DAEDALUS_HOME/core/leaselib.py" my-criteria 2>/dev/null || true)"
    if [ -n "$criteria" ] && [ -f "$criteria" ]; then
      log "review: criteria from window $lease_nn's file $criteria"
    elif [ -n "$criteria" ]; then
      log "review: window $lease_nn's criteria file $criteria is missing — the review judges the change by its evident intent"
      criteria=""
    fi
  fi
  refute_msg="$(bash "$DAEDALUS_HOME/core/refute.sh" "$run_id" "$criteria" "$summary_tmp" 2>&1 >/dev/null)"
  refute_code=$?
  # How the change was reviewed — one reviewer or several lenses, and why; how the earlier findings fared — shown
  # whatever the verdict, and kept out of the message a failure shows (review-lenses.py, refute.sh).
  printf '%s\n' "$refute_msg" | sed -n 's/^review-plan: //p' | while IFS= read -r ln; do log "review: $ln"; done
  # C1 (review 2026-10-22): the verdict and every reviewer call id, as refute.sh read them, go into this run's
  # state-side run.json — what promote later requires before it reuses this run's review.
  review_json="$(printf '%s\n' "$refute_msg" | sed -n 's/^review-record: //p' | tail -1)"
  refute_msg="$(printf '%s\n' "$refute_msg" | grep -v '^review-plan: ' | grep -v '^review-record: ')"
  if [ "$refute_code" -ne 0 ]; then
    result=FAIL; failed=1
    if [ "$refute_code" -eq 1 ]; then
      # Exit 1 = REFUTED; the review file is the fail_log.
      fail_log="$ev_vault/$run_id-review.md"
      notes="$(printf '%s\n' "$refute_msg" | sed -n 's/^verdict-note: //p')"
      [ -z "$notes" ] || log "review REFUTED; $notes"
      refuted_choices "$lease_nn"
    else
      # Exit 2 = the refuter could not certify: CLI missing, python3 missing,
      # CLI failed or timed out and was killed (no review file was written),
      # nothing to review, or a reply with no VERDICT line (review file
      # exists; the refuter's message carries its path). Any other code =
      # refute.sh itself died — a signal, a die — and there is no verdict
      # either. Only 0 is STANDS; an allow-list of failure codes once let
      # 143 stay PASS. Either way the refuter's own message is the honest
      # fail_log.
      log "refute: $refute_msg"
      fail_log="$refute_msg"
    fi
  fi
fi

# A STANDS that listed findings it did not count (hypothetical, out of scope, LOW — refute.sh's verdict_of) says so,
# with the review file, so the operator can see what was set aside and why.
if [ "$result" = PASS ] && [ "$refute_on" -eq 1 ]; then
  notes="$(printf '%s\n' "${refute_msg:-}" | sed -n 's/^verdict-note: //p')"
  [ -z "$notes" ] || log "review STANDS; $notes"
fi

# The vault summary, with the verdict folded into `result`, so this file and
# run.json never disagree — a re-setup deployment's state-loss fallback reads
# this frontmatter verbatim, so a stale PASS here would be a real false claim.
write_summary "$ev_vault/$run_id.md" "$result"
rm -f "$summary_tmp"

# run.json — through python for correct JSON escaping of arbitrary commands.
# The row data is written to a temp file OUTSIDE the evidence tree (so it
# never needs a manifest line) and its path passed via argv, not piped on
# stdin: `python3 -` already consumes stdin as the program source (the
# heredoc), so a second use of stdin for data is silently empty. Written
# after the refute call so a REFUTED verdict's flipped `result` is what gets
# recorded here.
rows_tmp="$(mktemp)" || die "cannot create a temp file for gate rows"
printf '%s' "$rows" > "$rows_tmp"
printf '\n%s' "$setup_rows" >> "$rows_tmp"     # a blank line parts the gate rows from the setup rows
rerun_tmp="$(mktemp)" || die "cannot create a temp file for gate rows"
printf '%s' "$rerun_rows" > "$rerun_tmp"
python3 - "$ev_state/run.json" "$run_id" "$started" "$fp_before" "$fp_secs" "$config_sha" "$result" "$rows_tmp" "$lease_nn" "$session_id" "$promo_ctx" "$setup_failed" "$invalid_reason" \
    "$gates_result" "$core_tree" "$reused_from" "$reused_gates" "$rerun_tmp" \
    "$tree_mode" "$clean_commit" "$clean_nested" "$refute_on" "${review_json:-}" <<'PY'
import json, sys, time
out, run_id, started, fp, fp_secs, config_sha, result, rows_path, lease, sid, ctx, setup_failed, invalid = sys.argv[1:14]
gates_result, core_tree, reused_from, reused_gates, rerun_path = sys.argv[14:19]
tree_mode, commit, nested_commits, refute_on, review_json = sys.argv[19:24]
gates, setup = [], []
with open(rows_path) as fh:
    gate_part, _, setup_part = fh.read().partition("\n\n")
for part, into in ((gate_part, gates), (setup_part, setup)):
    for line in part.splitlines():
        if not line.strip():
            continue
        n, code, dur, log, cmd = line.split("\t", 4)
        into.append({"n": int(n), "command": cmd, "exit": int(code), "duration_s": int(dur), "log": log})
# A gate whose failures were re-run (spec 2026-10-21 C) keeps its first run beside the row: the row is the outcome.
with open(rerun_path) as fh:
    for line in fh.read().splitlines():
        if not line.strip():
            continue
        n, fcode, fdur, flog, outcome, cmd = line.split("\t", 5)
        for g in gates:
            if g["n"] == int(n):
                g["rerun"] = {"command": cmd, "outcome": outcome.split(" ", 1)[0], "first_exit": int(fcode),
                              "first_duration_s": int(fdur), "first_log": flog}
# A reused run (spec 2026-10-21 A) carries the earlier run's gate rows exactly as that run recorded them.
tree = {"tree": tree_mode}
if tree_mode == "clean-copy":
    tree["commit"] = commit
    if nested_commits:
        tree["nested_commits"] = dict(x.split("=", 1) for x in nested_commits.split(",") if "=" in x)
if reused_from:
    src = json.load(open(reused_gates))
    gates = src["gates"]
    # What ran is the reused run's tree (spec 2026-10-22 revisions): a worktree run is never relabelled clean-copy.
    tree = {k: src.get(k) for k in ("tree", "commit", "nested_commits") if src.get(k) is not None}
rec = {"run_id": run_id, "started": started, "fingerprint": fp, "fingerprint_secs": int(fp_secs or 0),
       "config_sha": config_sha, "core_tree": None if core_tree in ("", "null") else core_tree,
       "setup": setup, "gates": gates, "gates_result": gates_result, "result": result,
       "lease": lease or None, "session_id": sid or None, "refuter": "on" if refute_on == "1" else "off"}
rec.update(tree)
try:
    review = json.loads(review_json) if review_json else None
except ValueError:
    review = None
if isinstance(review, dict):
    rec["review"] = review
if reused_from:
    rec["reused_from"] = reused_from
if int(setup_failed or 0):
    rec["setup_failed"] = int(setup_failed)
if invalid:
    rec["invalid_reason"] = invalid
if ctx:
    c = json.load(open(ctx))
    rec.update({k: c.get(k) for k in ("promote_id", "merge_sha", "trunk_sha_at_prepare", "repo", "nested")})
    rec.update({"lease": c.get("lease"), "tree": "promote-scratch", "refuter": "deferred-to-promote"})
rec["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S")
with open(out, "w") as fh:
    json.dump(rec, fh, indent=2)
PY
rj=$?
rm -f "$rows_tmp" "$rerun_tmp" "$reused_gates"
if [ "$rj" -ne 0 ]; then
  # The vault summary was written above with the result; with no run.json behind
  # it, it must not say PASS.
  write_summary "$ev_vault/$run_id.md" INVALID
  die "cannot write run.json for run $run_id — do not cite it"
fi

if [ -n "$invalid_reason" ]; then
  log "run-id: $run_id"
  [ -z "$fail_log" ] || log "log: $fail_log"
  die "run INVALID — $invalid_reason; do not cite it"
fi
if [ "$failed" -ne 0 ]; then
  log "run-id: $run_id"
  log "log: $fail_log"
  die "one or more gates failed"
fi
if [ "$result" = INVALID ]; then
  log "run INVALID — do not cite"
else
  log "all gates passed ($result)"
  printf '%s\n' "$run_id"
fi
