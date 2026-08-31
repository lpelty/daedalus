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
  target_err="$(target_path 2>&1 >/dev/null || true)"
  target="$(target_path 2>/dev/null || true)"
  if [ -n "$target_err" ]; then
    note_problem "${target_err#daedalus: }"
  elif [ -z "$target" ] || [ ! -d "$target" ]; then
    note_problem "target checkout — run core/sync-target.sh"
  elif [ ! -d "$target/.git" ]; then
    note_problem "target checkout is not a git repo: $target — run core/sync-target.sh"
  else
    log "OK       target checkout: $target"
  fi
else
  note_problem "target checkout — cannot determine path without config: target.repo"
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

# Unverified claims: a completion recorded without a PASS gate run for this
# deployment. Same rule as the Stop hook, over the whole vault.
#
# Captured into a variable first, then iterated with a here-string rather
# than piping straight into the while loop — a pipeline's right-hand side
# runs in a subshell, so note_problem's increment to $problems would not
# survive past the loop and every unverified claim would go uncounted even
# though it printed. The here-string keeps the loop (and note_problem) in
# the current shell.
if [ -f "$DAEDALUS_HOME/core/verify-hook.py" ]; then
  unverified="$(python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor 2>/dev/null)"
  while IFS= read -r line; do
    [ -n "$line" ] && note_problem "unverified claim: $line"
  done <<EOF
$unverified
EOF
fi

if [ "$problems" -ne 0 ]; then
  die "$problems problem(s) found"
fi
log "deployment is wired correctly"
