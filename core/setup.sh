#!/usr/bin/env bash
# Take a deployment from a fresh clone to verified. Rerunnable: every phase
# below is idempotent, and rerunning is how a drifted scaffold is refreshed.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -f "$DAEDALUS_CONFIG" ] || die "no config at $DAEDALUS_CONFIG — copy config.example.yaml to config.yaml and fill it in"

log "phase 1/5: target"
bash "$DAEDALUS_HOME/core/sync-target.sh" || die "target sync failed"

log "phase 2/5: vault"
bash "$DAEDALUS_HOME/core/sync-vault.sh" || die "vault sync failed"
mkdir -p "$DAEDALUS_HOME/state" || die "could not create state/"

# Spec §15: the window directories, the pre-push hook and the old dedup files — the
# functions the upgrade runs at a session start (§14), steps 1-3. Never the stamp: the
# first session start runs the rest, each a no-op on a fresh install (plan 5 Decision 12).
log "phase 3/5: leases"
if [ -f "$DAEDALUS_HOME/core/upgrade.py" ]; then
  python3 "$DAEDALUS_HOME/core/upgrade.py" --setup || die "the window directories could not be made ready (see above)"
else
  log "leases: skipped (core/upgrade.py absent)"
fi

log "phase 4/5: scaffold"
if cfg target.scaffold >/dev/null 2>&1; then
  # target_path() dies internally if target.repo is unset. A die inside a
  # command substitution only exits that subshell, not the caller — under
  # this script's OWN `set -uo pipefail` (no -e, by design), the parent would
  # continue past `target="$(target_path)"` with target set to empty and
  # setup would exit 0. That it doesn't today is incidental: sourcing lib.sh
  # (line 5) re-runs lib.sh's own `set -euo pipefail`, which silently
  # promotes -e for the rest of this script too, and it's that leaked -e —
  # not any check here — that currently makes a failed substitution abort.
  # Checking the precondition as a plain statement, before ever entering the
  # substitution, is correct regardless of which -e state is actually in
  # effect, so it doesn't depend on that leak (which is unrelated to this
  # task and unfixed) or on phase 1 already having validated this for us —
  # the same pattern sync-target.sh uses for target.nested.
  cfg target.repo >/dev/null 2>&1 || die "config: target.repo is required for the scaffold phase"
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

# The lease board on screen (lease-board spec §4.6): the mod under mods/lease-board/ is listed by the
# marketplace at mods/.claude-plugin/marketplace.json and registered once per deployment at LOCAL scope,
# so the absolute path the CLI writes lands in the gitignored .claude/settings.local.json, never in the
# tracked settings. Skipped, with a line saying so, when mods/ is absent (a fixture) or claude is not on
# PATH; a second run is a no-op because the file already names the plugin. doctor says the same (§5.3).
log "lease board: the band above the prompt"
if [ ! -f "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json" ]; then
  log "lease board: skipped (mods/ absent)"
elif ! command -v claude >/dev/null 2>&1; then
  log "lease board: skipped (claude is not on PATH; run the two install commands in README.md \"Windows (leases)\" yourself)"
elif python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) and "lease-board@daedalus-mods" in (d.get("enabledPlugins") or {}) else 1)' "$DAEDALUS_HOME/.claude/settings.local.json" 2>/dev/null; then
  log "lease board: already installed for this deployment (.claude/settings.local.json names lease-board@daedalus-mods)"
else
  ( cd "$DAEDALUS_HOME" && claude plugin marketplace add ./mods --scope local && claude plugin install lease-board@daedalus-mods --scope local ) \
    || log "lease board: the install did not finish — run the two commands in README.md \"Windows (leases)\" yourself"
fi

log "phase 5/5: doctor"
bash "$DAEDALUS_HOME/core/doctor.sh" || die "the deployment is not correctly wired — see the report above"

log "setup complete"
