#!/usr/bin/env bash
# Clone or fast-forward the target harness checkout.
# The clone keeps its natural name and shape: target/<repo-name>/ — anything
# in the harness using paths relative to its repo root depends on this.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

url="$(cfg target.repo)" || die "config: target.repo is required"
branch="$(cfg target.branch)" || branch="main"
dest="$(target_path)"

if [ -d "$dest/.git" ]; then
  log "updating $(basename "$dest") ($branch)"
  git -C "$dest" fetch --quiet origin "$branch"
  git -C "$dest" checkout --quiet "$branch"
  git -C "$dest" merge --ff-only --quiet "origin/$branch"
else
  log "cloning $url -> $dest"
  mkdir -p "$(dirname "$dest")"
  git clone --quiet --branch "$branch" "$url" "$dest"
fi
log "target ready: $dest"
