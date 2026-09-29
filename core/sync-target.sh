#!/usr/bin/env bash
# Clone or fast-forward the target harness checkout.
# The clone keeps its natural name and shape: target/<repo-name>/ — anything
# in the harness using paths relative to its repo root depends on this.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

url="$(cfg target.repo)" || die "config: target.repo is required"
branch="$(cfg target.branch)" || branch="main"
dest="$(target_path)"

# A lease worktree is never synced here: its branch is lease/<NN>, and the
# trunk cannot be checked out twice. `leaselib.py resolve` prints the
# physical path (DAEDALUS_HOME resolved), so match both spellings of the
# home — /var vs /private/var on macOS — with `pwd -P` (no realpath on base
# macOS, bash-3.2-safe), as the nested guard below does.
home_p="$(cd "$DAEDALUS_HOME" && pwd -P)"
case "$dest" in
  "$DAEDALUS_HOME"/worktrees/*|"$home_p"/worktrees/*)
    nn="${dest#"$DAEDALUS_HOME"/worktrees/}"; nn="${nn#"$home_p"/worktrees/}"; nn="${nn%%/*}"
    die "sync-target updates the prime's checkout; a lease worktree is brought forward by \`core/lease.sh rebase $nn\`, which rebases lease/$nn onto origin/$branch"
    ;;
esac

# A linked worktree's .git is a FILE, not a directory (spec §4.4): ask git
# whether this is a work tree rather than testing for the directory, or a
# worktree would be `git clone`d over. "Is a work tree" means "is the ROOT
# of one": `--is-inside-work-tree` alone is true for any subdirectory of a
# repository, and a real deployment's DAEDALUS_HOME is itself one — an
# empty target/<name> would then be fetched as the outer repo instead of
# cloned. lib.sh is_work_tree_root is git's own answer to both questions;
# it never compares paths (a case-swapped home spelling once failed that).
if is_work_tree_root "$dest"; then
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
# script never goes through a tool call, so a `../` (or an absolute path, or
# a symlinked ancestor) in a config value would walk straight past them and
# write outside target/ — exactly the class of bug this product exists to
# prevent. Two checks, both BEFORE any directory gets created: reject the
# obvious string forms (`..`, leading `/`) up front, so the error names the
# real problem; then resolve the deepest already-existing ancestor of the
# nested path with `cd ... && pwd -P` (no realpath on base macOS, bash-3.2-
# safe) and confirm it sits under $dest — this is the check that catches a
# symlink, which the string-form check cannot see through. Validating an
# ancestor that already exists, rather than mkdir -p'ing first and checking
# after, means a hostile config value never gets so much as an empty
# directory created outside the checkout before the guard fires.
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
    # Validate BEFORE creating anything. mkdir -p on an unvalidated path
    # would create a real directory outside the checkout before the check
    # ever ran (a symlinked ancestor resolves outside $dest even though the
    # string form of $rel looks fine — the early case-based check above
    # can't see through a symlink, only this resolved-path check can). So
    # walk up from $nparent to the deepest ANCESTOR THAT ALREADY EXISTS,
    # resolve only that (mkdir -p hasn't run yet, so deeper components may
    # not exist to resolve), and confirm it sits under $resolved_dest before
    # creating anything.
    walk="$nparent"
    while [ ! -d "$walk" ]; do
      walk="$(dirname "$walk")"
    done
    resolved_walk="$(cd "$walk" && pwd -P)"
    case "$resolved_walk" in
      "$resolved_dest"|"$resolved_dest"/*) : ;;
      *)
        die "config target.nested: path $rel resolves outside the target checkout"
        ;;
    esac
    mkdir -p "$nparent"
    resolved_parent="$(cd "$nparent" && pwd -P)"
    case "$resolved_parent" in
      "$resolved_dest"|"$resolved_dest"/*) : ;;
      *)
        die "config target.nested: path $rel resolves outside the target checkout"
        ;;
    esac
    if is_work_tree_root "$ndest"; then
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

# The pre-push hook (spec §7.3): installed idempotently in the target and every nested
# repo, core.hooksPath untouched. setup.sh runs this script as its first phase, so a
# fresh install and a re-run of setup both get it.
if [ -f "$DAEDALUS_HOME/core/prepush.py" ]; then
  hook_repos=("$dest")
  if cfg target.nested >/dev/null 2>&1; then
    while IFS="$(printf '\t')" read -r rel _url; do
      [ -n "$rel" ] && hook_repos+=("$dest/$rel")
    done <<EOF
$(cfg_pairs target.nested)
EOF
  fi
  python3 "$DAEDALUS_HOME/core/prepush.py" install "${hook_repos[@]}" \
    || die "the pre-push hook could not be installed (see above) — the trunk is unguarded in git until it is"
fi

log "target ready: $dest"
