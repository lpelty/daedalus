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

# Nested repos live at fixed paths INSIDE the ship checkout, mirroring the
# operator's real tree exactly. Absent `nested` key means a single-repo target.
if cfg target.nested >/dev/null 2>&1; then
  cfg_pairs target.nested > "$dest/.daedalus-nested" || die "config: target.nested is malformed"
  while IFS="$(printf '\t')" read -r rel url; do
    [ -n "$rel" ] || continue
    ndest="$dest/$rel"
    if [ -d "$ndest/.git" ]; then
      log "updating nested $rel"
      git -C "$ndest" fetch --quiet origin
      git -C "$ndest" merge --ff-only --quiet "@{u}"
    else
      log "cloning nested $rel"
      mkdir -p "$(dirname "$ndest")"
      git clone --quiet "$url" "$ndest"
    fi
  done < "$dest/.daedalus-nested"
  rm -f "$dest/.daedalus-nested"
fi

log "target ready: $dest"
