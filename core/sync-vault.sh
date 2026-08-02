#!/usr/bin/env bash
# Clone or fast-forward the knowledge-base checkout, and ensure the vault
# layout exists (PRD §9.2).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

url="$(cfg vault.repo)" || die "config: vault.repo is required"
dest="$DAEDALUS_HOME/vault"
tpl_dir="$(dirname "${BASH_SOURCE[0]}")/templates"

if [ -d "$dest/.git" ]; then
  log "updating vault"
  git -C "$dest" pull --ff-only --quiet
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

if [ -f "$dest/hot.md" ]; then
  :
else
  cp "$tpl_dir/hot.md" "$dest/hot.md"
  log "wrote hot.md"
fi

log "vault ready: $dest"
