#!/usr/bin/env bash
# Verify this deployment is wired correctly. Exits 0 only when it is.
#
# Names every missing piece rather than aborting on the first — an operator
# standing up a deployment should learn everything that is wrong in one run.
# Like gates.sh, this survives individual check failures instead of using
# -e, because it must keep going after a failed check to report the rest.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# AFTER the source, not before: lib.sh runs `set -euo pipefail`, so setting
# this first had errexit switched straight back on underneath us. Every check
# that returned non-zero then aborted the run instead of being counted, which
# is the opposite of the contract stated above.
set +e
set -uo pipefail

problems=0
note_problem() { log "MISSING  $*"; problems=$((problems + 1)); }

[ -f "$DAEDALUS_CONFIG" ] || { log "MISSING  config.yaml (copy config.example.yaml)"; exit 1; }

target_repo_ok=0
for key in target.repo target.branch vault.repo proposals.budget; do
  if cfg "$key" >/dev/null 2>&1; then
    log "OK       config: $key"
    [ "$key" = "target.repo" ] && target_repo_ok=1
  else
    note_problem "config: $key"
  fi
done

if [ -n "$(cfg_list gates)" ]; then
  log "OK       config: gates ($(cfg_list gates | wc -l | tr -d ' ') defined)"
else
  note_problem "config: gates (at least one required)"
fi

# target_path() dies (hard exit) if target.repo is unset. Only call it once
# we've confirmed the key is actually present above — otherwise it would
# abort this script before the vault checks below ever run, silently
# skipping checks instead of naming them as MISSING like everything else.
if [ "$target_repo_ok" -eq 1 ]; then
  # target_path also `die`s when it REJECTS the config — a target.dir carrying
  # a path separator, for instance. Discarding that message with `|| true`
  # turned a config error into the generic "run core/sync-target.sh", pointing
  # the operator at a remedy that cannot possibly help: sync-target calls this
  # same function and hits the same rejection. Keep stderr so the real cause
  # can be reported, and keep going — doctor names every problem in one run.
  #
  # The exit code decides, not whether stderr is empty: with lease files
  # present, target_path resolves through leaselib.py, which prints an exit-0
  # courtesy note for an operator shell ("no session — using the prime's
  # checkout"). Reading that note as a rejection turned every doctor run from
  # a shell red the moment a window was open. A note with exit 0 is a NOTE.
  target_err="$(target_path 2>&1 >/dev/null)"; target_rc=$?
  target="$(target_path 2>/dev/null || true)"
  if [ "$target_rc" -ne 0 ]; then
    target_err="${target_err#daedalus: }"
    note_problem "${target_err:-target checkout — cannot resolve the target path (target_path exited $target_rc)}"
  elif [ -z "$target" ] || [ ! -d "$target" ]; then
    note_problem "target checkout — run core/sync-target.sh"
  elif ! is_work_tree_root "$target"; then
    # The same predicate fingerprint.sh and sync-target.sh use (lib.sh), so
    # doctor and the fingerprint never disagree: a linked worktree's .git is
    # a file (`-d .git` called it broken), and a target that lost its .git
    # inside an outer repository is broken even though git answers there.
    note_problem "target checkout is not a git repo: $target — run core/sync-target.sh"
  else
    [ -n "$target_err" ] && log "NOTE     ${target_err#daedalus: }"
    log "OK       target checkout: $target"
    # The trunk name. Every branch-aware guard (guard-bash's push/commit
    # deny, the promotion gate) reads config target.branch; a config that
    # names a branch the target does not use leaves all of them inert while
    # reporting themselves fine — one deployment ran with `main`
    # configured against a GitLab trunk called `mainline`. The hard test
    # is existence: a configured branch that origin does not have is a
    # MISSING (sync-target.sh cannot even fetch it). A branch that exists
    # but is not the remote's default (refs/remotes/origin/HEAD, recorded
    # by `git clone`) is a NOTE naming both, never a problem: a deployment
    # may deliberately guard a trunk that is not the remote's default, and
    # setup.sh dies on a red doctor — prescribing "change to the default"
    # there would re-inert every branch guard. No network: `git remote show
    # origin` would answer when origin/HEAD is unset, but it contacts the
    # remote, so an unset origin/HEAD is reported as undeterminable rather
    # than guessed. (An unset target.branch is already MISSING above.)
    configured_branch="$(cfg target.branch 2>/dev/null || true)"
    if [ -n "$configured_branch" ]; then
      remote_default="$(git -C "$target" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      remote_default="${remote_default#origin/}"
      if [ -z "$(git -C "$target" for-each-ref --count=1 refs/remotes/origin/ 2>/dev/null)" ]; then
        # No remote-tracking refs at all (a checkout with no origin, or one
        # that is not a git repo git can read): absence proves nothing.
        log "NOTE     target.branch: cannot tell whether $configured_branch exists at origin (no origin refs are recorded in $target), so config.yaml's target.branch is unchecked"
      elif ! git -C "$target" rev-parse --verify -q "refs/remotes/origin/$configured_branch" >/dev/null 2>&1; then
        if [ -n "$remote_default" ]; then
          note_problem "config.yaml says target.branch: $configured_branch but origin has no branch by that name (its default branch is $remote_default); fix target.branch in config.yaml"
        else
          note_problem "config.yaml says target.branch: $configured_branch but origin has no branch by that name; fix target.branch in config.yaml"
        fi
      elif [ -z "$remote_default" ]; then
        log "NOTE     target.branch: $configured_branch exists at origin; cannot tell whether it is the target's default branch (origin/HEAD is not recorded in $target)"
      elif [ "$remote_default" = "$configured_branch" ]; then
        log "OK       target.branch: $configured_branch is the target's default branch"
      else
        log "NOTE     target.branch: $configured_branch exists at origin but is not its default branch ($remote_default) — confirm this is the trunk you mean to guard; the branch guard denies pushes and commits to $remote_default as well"
      fi
    fi
  fi
else
  note_problem "target checkout — cannot determine path without config: target.repo"
fi

# Leases (spec §15). Every line is plain language: "03 (electron; no live
# session since 09:40)", never a bare token. The counting and the staleness
# call live in leaselib.py (doctor-lines) so doctor and the board can never
# disagree; it decides each line's kind and this block counts the MISSING
# ones. Guarded on leaselib.py existing so a fixture without it skips the
# block, visibly. Skipped when state/leases/ is absent: leaselib takes its
# lock inside that directory and would create it as a side effect of a
# diagnostic. The here-string loop keeps note_problem in this shell — a pipe
# would put it in a subshell and lose the count (see the unverified-claims
# block below).
if [ -f "$DAEDALUS_HOME/core/leaselib.py" ]; then
  for d in state/leases worktrees; do
    if [ ! -d "$DAEDALUS_HOME/$d" ]; then
      note_problem "$d/ — start a session (the upgrade runs at SessionStart) or run core/setup.sh"
    fi
  done
  if [ -d "$DAEDALUS_HOME/state/leases" ]; then
    lease_out="$(python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines 2>/dev/null)"
    lease_rc=$?
    if [ "$lease_rc" -ne 0 ]; then
      note_problem "leases: check failed (core/leaselib.py doctor-lines exited $lease_rc)"
    else
      while IFS= read -r line; do
        case "$line" in
          "") ;;
          "MISSING  "*) note_problem "${line#MISSING  }" ;;
          *) log "$line" ;;
        esac
      done <<EOF
$lease_out
EOF
    fi
  fi
  registry="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  if [ -d "$registry" ]; then
    n="$(ls "$registry"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    log "OK       session registry: $registry/ present ($n entries)"
  else
    # Deviates from §15's exact line ("first-up by terminal check"): hooks
    # cannot open /dev/tty (Task 6), so the line says what a registry-absent
    # build actually does instead of promising a check that never runs.
    log "NOTE     session registry absent — liveness by heartbeat only on this build; peer names unknown; no window numbers itself and nobody takes the pen at start (launch each window with DAEDALUS_LEASE=<NN>; core/lease.sh prime take gives one the pen)"
  fi
  for old in pitfall-seen.json code-context-seen.json; do
    [ -f "$DAEDALUS_HOME/state/$old" ] && log "NOTE     state/$old is the pre-v0.7.0 shared file — the upgrade removes it at the next session start"
  done
fi

# A healthy vault is either its own git repo (vault/.git exists — the
# original assumption), or a directory absorbed into the parent daedalus
# repo via `git subtree add` — a deliberate choice on some deployments when
# the vault holds session history on a single disk with no remote of its own.
# `git ls-files --error-unmatch` alone is not sufficient: it checks the
# INDEX, not the working tree, so it reports success even for a vault
# deleted from disk after being committed (verified empirically). The
# on-disk directory check guards against exactly that false green.
vault_tracked_by_parent=0
if [ -d "$DAEDALUS_HOME/vault" ] && git -C "$DAEDALUS_HOME" ls-files --error-unmatch vault >/dev/null 2>&1; then
  vault_tracked_by_parent=1
fi

if [ ! -d "$DAEDALUS_HOME/vault/.git" ] && [ "$vault_tracked_by_parent" -eq 0 ]; then
  note_problem "vault is not a git repo and is not tracked by the parent repo: $DAEDALUS_HOME/vault — run core/sync-vault.sh"
else
  for d in infrastructure specs plans proposals pitfalls exchange; do
    if [ -d "$DAEDALUS_HOME/vault/$d" ]; then
      log "OK       vault/$d"
    else
      note_problem "vault/$d — run core/sync-vault.sh"
    fi
  done
fi

# Pitfall triggers: a pitfall that cannot fire is a pitfall that will be
# missed again. Informational — never a problem — and skipped, visibly, when
# the script is absent (the doctor fixture copies only lib.sh and doctor.sh).
# stderr goes to /dev/null rather than being merged into the piped stream: a
# crashing --check must not print a raw Python traceback disguised as doctor
# NOTE lines. On a non-zero exit we report exactly one line naming the exit
# code instead.
if [ -f "$DAEDALUS_HOME/core/pitfall-inject.py" ]; then
  pitfall_out="$(python3 "$DAEDALUS_HOME/core/pitfall-inject.py" --check 2>/dev/null)"
  pitfall_status=$?
  if [ "$pitfall_status" -ne 0 ]; then
    log "NOTE     pitfalls: check failed (core/pitfall-inject.py --check exited $pitfall_status)"
  else
    printf '%s\n' "$pitfall_out" | while IFS= read -r line; do
      log "NOTE     $line"
    done
  fi
else
  log "NOTE     pitfalls: check skipped (core/pitfall-inject.py absent)"
fi

# Document recall: enhancement-layer health, NOTE lines only (spec §2.6).
if [ -f "$DAEDALUS_HOME/core/vault-search.py" ]; then
  recall_out="$(python3 "$DAEDALUS_HOME/core/vault-search.py" --check 2>/dev/null)"
  recall_status=$?
  if [ "$recall_status" -ne 0 ]; then
    log "NOTE     document recall: check failed (core/vault-search.py --check exited $recall_status)"
  else
    printf '%s\n' "$recall_out" | while IFS= read -r line; do
      log "NOTE     $line"
    done
  fi
else
  log "NOTE     document recall: check skipped (core/vault-search.py absent)"
fi

# Code context: enhancement-layer health, NOTE lines only (spec §3.3).
if [ -f "$DAEDALUS_HOME/core/code-context.py" ]; then
  cc_out="$(python3 "$DAEDALUS_HOME/core/code-context.py" --check 2>/dev/null)"
  cc_status=$?
  if [ "$cc_status" -ne 0 ]; then
    log "NOTE     code context: check failed (core/code-context.py --check exited $cc_status)"
  else
    printf '%s\n' "$cc_out" | while IFS= read -r line; do
      log "NOTE     $line"
    done
  fi
else
  log "NOTE     code context: check skipped (core/code-context.py absent)"
fi

# Arm-state visibility: claims() returns [] until vault/evidence/ has at
# least one dated *.md file, which is also what forces the first gates run
# to happen at all. That is a real gap, not a bug — but a silent one, since
# a deployment with no evidence yet is inert and gives no signal that it is.
# This is visibility only; nothing here runs gates.sh or writes evidence.
if [ ! -d "$DAEDALUS_HOME/vault/evidence" ] || [ -z "$(find "$DAEDALUS_HOME/vault/evidence" -maxdepth 1 -name '*.md' -print -quit 2>/dev/null)" ]; then
  log "NOTE     verify: stage unarmed — no evidence yet; run core/gates.sh once to arm it"
fi

# Unverified claims: a completion recorded without a PASS gate run for this
# deployment. Same rule as the Stop hook, over the whole vault.
#
# Captured into a variable first, then iterated with a here-string rather
# than piping straight into the while loop — a pipeline's right-hand side
# runs in a subshell, so note_problem's increment to $problems would not
# survive past the loop and every unverified claim would go uncounted even
# though it printed. The here-string keeps the loop (and note_problem) in
# the current shell.
#
# The exit code is checked too, right after the command substitution. A
# crashing verify-hook.py prints nothing to stdout, which previously read as
# "no unverified claims" — the doctor stayed green and silent on top of a
# broken claims-checker. That is this repo's founding pitfall class: a
# diagnostic for silent failure that failed silently. A non-zero exit is
# itself a problem, so it goes through note_problem and turns doctor red.
if [ -f "$DAEDALUS_HOME/core/verify-hook.py" ]; then
  unverified="$(python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    note_problem "unverified-claims check failed (core/verify-hook.py --doctor exited $rc)"
  else
    while IFS= read -r line; do
      [ -n "$line" ] && note_problem "unverified claim: $line"
    done <<EOF
$unverified
EOF
  fi
fi

if [ "$problems" -ne 0 ]; then
  die "$problems problem(s) found"
fi
log "deployment is wired correctly"
