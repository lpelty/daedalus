#!/usr/bin/env bash
# Verify this deployment is wired correctly. Exits 0 only when it is.
#
# Names every missing piece rather than aborting on the first — an operator
# standing up a deployment should learn everything that is wrong in one run.
# Like gates.sh, this survives individual check failures instead of using
# -e, because it must keep going after a failed check to report the rest.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
  target="$(target_path 2>/dev/null || true)"
  if [ -z "$target" ] || [ ! -d "$target" ]; then
    note_problem "target checkout — run core/sync-target.sh"
  elif [ ! -d "$target/.git" ]; then
    note_problem "target checkout is not a git repo: $target — run core/sync-target.sh"
  else
    log "OK       target checkout: $target"
  fi
else
  note_problem "target checkout — cannot determine path without config: target.repo"
fi

if [ ! -d "$DAEDALUS_HOME/vault/.git" ]; then
  note_problem "vault is not a git repo: $DAEDALUS_HOME/vault — run core/sync-vault.sh"
else
  for d in infrastructure specs plans proposals pitfalls; do
    if [ -d "$DAEDALUS_HOME/vault/$d" ]; then
      log "OK       vault/$d"
    else
      note_problem "vault/$d — run core/sync-vault.sh"
    fi
  done
fi

if [ "$problems" -ne 0 ]; then
  die "$problems problem(s) found"
fi
log "deployment is wired correctly"
