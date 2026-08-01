#!/usr/bin/env bash
# Take a deployment from a fresh clone to verified. Rerunnable: every phase
# below is idempotent, and rerunning is how a drifted scaffold is refreshed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -f "$DAEDALUS_CONFIG" ] || die "no config at $DAEDALUS_CONFIG — copy config.example.yaml to config.yaml and fill it in"

log "phase 1/4: target"
bash "$DAEDALUS_HOME/core/sync-target.sh" || die "target sync failed"

log "phase 2/4: vault"
bash "$DAEDALUS_HOME/core/sync-vault.sh" || die "vault sync failed"

log "phase 3/4: scaffold"
if cfg target.scaffold >/dev/null 2>&1; then
  target="$(target_path)"
  cfg_pairs target.scaffold > "$DAEDALUS_HOME/.daedalus-scaffold" || die "config: target.scaffold is malformed"
  while IFS="$(printf '\t')" read -r rel url; do
    [ -n "$rel" ] || continue
    # Same path-traversal guard as sync-target.sh's nested loop, and for the
    # same reason: scaffold_repo runs mkdir -p on this path, and a `../` would
    # create directories outside target/. Deny rules gate tool calls, not
    # shell scripts, so the check belongs here.
    case "$rel" in
      /*|*..*)
        die "config target.scaffold: path $rel must stay inside the target checkout"
        ;;
    esac
    scaffold_repo "$url" "$target/$rel"
  done < "$DAEDALUS_HOME/.daedalus-scaffold"
  rm -f "$DAEDALUS_HOME/.daedalus-scaffold"
else
  log "scaffold: nothing configured"
fi

log "phase 4/4: doctor"
bash "$DAEDALUS_HOME/core/doctor.sh" || die "the deployment is not correctly wired — see the report above"

log "setup complete"
