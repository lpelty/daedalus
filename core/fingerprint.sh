#!/usr/bin/env bash
# Content fingerprint of the target checkout: independent of HEAD and of the
# index, covering untracked (unignored) content, with nested repositories
# excluded from the parent tree and fingerprinted separately, and any paths
# named in target.fingerprint_exclude left out of the parent tree entirely.
#
# Prints exactly one line: a sha256, or `null` on ANY failure. Never a hash
# of a half-built index — `write-tree` on a temp index that `add` never
# populated returns the empty-tree hash with exit 0, and every fingerprint
# would then compare equal. Exit status is always 0; `null` is the failure
# signal, and a `null` fingerprint can never be cited.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e
set -uo pipefail

start=$(date +%s)

fp_repo() {                          # $1 = repo; $2… = nested relpaths to exclude
  local repo="$1"; shift
  local idx n
  local ex=()
  idx="$(mktemp -u)" || return 1     # -u: git must create the index itself
  for n in "$@"; do ex+=(":(exclude)$n"); done
  [ -d "$repo/.git" ] || return 1
  [ -e "$repo/.git/index.lock" ] && return 1
  GIT_INDEX_FILE="$idx" git -C "$repo" -c advice.addEmbeddedRepo=false \
      add -A -- . ${ex[@]+"${ex[@]}"} >/dev/null 2>&1 || { rm -f "$idx"; return 1; }
  GIT_INDEX_FILE="$idx" git -C "$repo" write-tree 2>/dev/null || { rm -f "$idx"; return 1; }
  rm -f "$idx"
}

emit_null() { printf 'null\n'; printf 'fingerprint_secs=%s\n' "$(( $(date +%s) - start ))" >&2; exit 0; }

target="$(target_path 2>/dev/null)" || emit_null
[ -d "$target" ] || emit_null

nested=()
if cfg target.nested >/dev/null 2>&1; then
  while IFS="$(printf '\t')" read -r rel url; do
    [ -n "$rel" ] || continue
    nested+=("$rel")
  done <<EOF
$(cfg_pairs target.nested 2>/dev/null)
EOF
fi

# Exclude pathspecs are only for nested repos the parent can SEE. A nested
# path already covered by the parent's .gitignore is skipped by `git add`
# on its own — and naming it in an explicit :(exclude) pathspec makes git
# treat the ignored path as explicitly requested, which errors ("Use -f")
# and nulled every fingerprint on the live deployment. Ignored nested repos
# are still fingerprinted separately below; they just need no exclude.
nested_excl=()
for rel in ${nested[@]+"${nested[@]}"}; do
  git -C "$target" check-ignore -q "$rel" 2>/dev/null && continue
  nested_excl+=("$rel")
done

# Operator-named paths to leave OUT of the parent tree (config
# target.fingerprint_exclude: comma-separated, relative to the target root).
# `write-tree` cannot tell a changelog comma from a rewrite of the code under
# test, so every prose revision to distribution metadata invalidated every
# evidence citation and forced a full gate run — six in one day on one
# deployment, with the tested code unchanged (PROP-018, second
# addendum). This is a per-target decision made in config, never a list
# hardcoded here: excluding a file a gate reads would hide a real change, so
# the operator names the files and owns that check. Two guards, both
# verified against git 2.50 before writing: a path that is gitignored is
# skipped (naming it in :(exclude) errors "Use -f" and nulls everything, the
# same trap as nested repos above), and a path that could leave the checkout
# ("/", "..", or pathspec magic ":") nulls the fingerprint with a named
# reason on stderr rather than silently widening the tree. A path that does
# not exist is a no-op for git and needs no guard.
extra_excl=()
if raw_excl="$(cfg target.fingerprint_exclude 2>/dev/null)"; then
  while IFS= read -r rel; do
    rel="$(printf '%s' "$rel" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$rel" ] || continue
    case "$rel" in
      /*|*..*|:*)
        printf 'fingerprint: config target.fingerprint_exclude: path %s must stay inside the target checkout\n' "$rel" >&2
        emit_null
        ;;
    esac
    git -C "$target" check-ignore -q "$rel" 2>/dev/null && continue
    extra_excl+=("$rel")
  done <<EOF
$(printf '%s\n' "$raw_excl" | tr ',' '\n')
EOF
fi

lines=""
tree="$(fp_repo "$target" ${nested_excl[@]+"${nested_excl[@]}"} ${extra_excl[@]+"${extra_excl[@]}"})" || emit_null
lines=".:$tree"
for rel in ${nested[@]+"${nested[@]}"}; do
  tree="$(fp_repo "$target/$rel")" || emit_null
  lines="$lines
$rel:$tree"
done

printf '%s\n' "$lines" | shasum -a 256 | awk '{print $1}'
printf 'fingerprint_secs=%s\n' "$(( $(date +%s) - start ))" >&2
exit 0
