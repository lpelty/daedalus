#!/usr/bin/env bash
# Content fingerprint of the target checkout: independent of HEAD and of the
# index, covering untracked (unignored) content, with nested repositories
# excluded from the parent tree and fingerprinted separately.
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

lines=""
tree="$(fp_repo "$target" ${nested[@]+"${nested[@]}"})" || emit_null
lines=".:$tree"
for rel in ${nested[@]+"${nested[@]}"}; do
  tree="$(fp_repo "$target/$rel")" || emit_null
  lines="$lines
$rel:$tree"
done

printf '%s\n' "$lines" | shasum -a 256 | awk '{print $1}'
printf 'fingerprint_secs=%s\n' "$(( $(date +%s) - start ))" >&2
exit 0
