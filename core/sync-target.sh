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
#
# Write-boundary enforcement lives here, not just in .claude/settings.json's
# deny rules. Those rules gate tool calls; a `git clone` inside this shell
# script never goes through a tool call, so a `../` (or an absolute path) in
# a config value would walk straight past them and write outside target/ —
# exactly the class of bug this product exists to prevent. Two checks:
# reject the obvious forms (`..`, leading `/`) before touching git at all, so
# the error names the real problem; then, after mkdir -p creates the parent,
# resolve it with `cd ... && pwd -P` (no realpath on base macOS, bash-3.2-safe)
# and confirm it still sits under $dest — catching anything the glob misses
# (symlinks, odd encodings).
if cfg target.nested >/dev/null 2>&1; then
  resolved_dest="$(cd "$dest" && pwd -P)"
  nested_list="$dest/.daedalus-nested"
  # Cover every exit from this block — an explicit `die`, or `set -e`
  # aborting on a failed git command mid-loop — not just the happy path.
  # A stale temp file left behind by a failed run must never be readable
  # by the next run.
  trap 'rm -f "$nested_list"' EXIT
  cfg_pairs target.nested > "$nested_list" || die "config: target.nested is malformed"
  while IFS="$(printf '\t')" read -r rel url; do
    [ -n "$rel" ] || continue
    case "$rel" in
      /*|*..*)
        die "config target.nested: path $rel must stay inside the target checkout"
        ;;
    esac
    ndest="$dest/$rel"
    nparent="$(dirname "$ndest")"
    mkdir -p "$nparent"
    resolved_parent="$(cd "$nparent" && pwd -P)"
    case "$resolved_parent" in
      "$resolved_dest"|"$resolved_dest"/*) : ;;
      *)
        die "config target.nested: path $rel resolves outside the target checkout"
        ;;
    esac
    if [ -d "$ndest/.git" ]; then
      log "updating nested $rel"
      git -C "$ndest" fetch --quiet origin
      git -C "$ndest" merge --ff-only --quiet "@{u}"
    else
      log "cloning nested $rel"
      git clone --quiet "$url" "$ndest"
    fi
  done < "$nested_list"
  rm -f "$nested_list"
  trap - EXIT
fi

log "target ready: $dest"
