#!/usr/bin/env bash
# Clone or fast-forward the knowledge-base checkout, and ensure the vault
# layout exists (PRD §9.2).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

url="$(cfg vault.repo)" || die "config: vault.repo is required"
dest="$DAEDALUS_HOME/vault"
tpl_dir="$(dirname "${BASH_SOURCE[0]}")/templates"

# A vault can be healthy in a shape other than its own git checkout: absorbed
# into the parent daedalus repo (e.g. via `git subtree add`) so vault/.git
# does not exist but vault/ is real, populated, and tracked by the parent.
# `git ls-files --error-unmatch` alone is not sufficient: it checks the
# INDEX, not the working tree, so it reports success even for a vault
# deleted from disk after being committed (same false-green doctor.sh guards
# against). The on-disk directory check guards against exactly that.
vault_tracked_by_parent=0
if [ -d "$dest" ] && git -C "$DAEDALUS_HOME" ls-files --error-unmatch vault >/dev/null 2>&1; then
  vault_tracked_by_parent=1
fi

if [ -d "$dest/.git" ]; then
  log "updating vault"
  git -C "$dest" pull --ff-only --quiet
elif [ "$vault_tracked_by_parent" -eq 1 ]; then
  # The vault travels with the parent repo, so there is no separate remote
  # to clone or pull from here — that's the parent's job, not this script's.
  log "vault is tracked by the parent repo, not its own checkout — skipping clone/pull"
else
  log "cloning $url -> $dest"
  git clone --quiet "$url" "$dest"
fi

for d in infrastructure specs plans proposals pitfalls exchange exchange/messages sessions; do
  mkdir -p "$dest/$d"
done

if [ -f "$dest/exchange/README.md" ]; then
  :
else
  cp "$tpl_dir/exchange-README.md" "$dest/exchange/README.md"
  log "wrote exchange/README.md"
fi

if [ -f "$dest/exchange/Exchange.base" ]; then
  :
else
  cp "$tpl_dir/Exchange.base" "$dest/exchange/Exchange.base"
  log "wrote exchange/Exchange.base"
fi

if [ -f "$dest/sessions/_template.md" ]; then
  :
else
  cp "$tpl_dir/session.md" "$dest/sessions/_template.md"
  log "wrote sessions/_template.md"
fi

if [ -f "$dest/proposals/_template.md" ]; then
  :
else
  cp "$tpl_dir/proposal.md" "$dest/proposals/_template.md"
  log "wrote proposals/_template.md"
fi

if [ -f "$dest/hot.md" ]; then
  :
else
  cp "$tpl_dir/hot.md" "$dest/hot.md"
  log "wrote hot.md"
fi

log "vault ready: $dest"
