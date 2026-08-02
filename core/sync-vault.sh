#!/usr/bin/env bash
# Clone or fast-forward the knowledge-base checkout, and ensure the vault
# layout exists (PRD §9.2).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

url="$(cfg vault.repo)" || die "config: vault.repo is required"
dest="$DAEDALUS_HOME/vault"

if [ -d "$dest/.git" ]; then
  log "updating vault"
  git -C "$dest" pull --ff-only --quiet
else
  log "cloning $url -> $dest"
  git clone --quiet "$url" "$dest"
fi

for d in infrastructure specs plans proposals pitfalls exchange; do
  mkdir -p "$dest/$d"
done

log "vault ready: $dest"
