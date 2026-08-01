#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME

  # A repo whose SHAPE we want and whose CONTENTS we do not.
  SHAPEREPO="$BATS_TEST_TMPDIR/upstream-vault"
  mkdir -p "$SHAPEREPO/00_inbox" "$SHAPEREPO/80_sessions" "$SHAPEREPO/_templates"
  cd "$SHAPEREPO"
  git init -q -b main
  echo "private session content" > 80_sessions/private.md
  echo "inbox item" > 00_inbox/item.md
  # Git tracks files, not directories — an empty dir never appears in
  # `ls-tree`. A real vault's _templates always holds at least one file;
  # this fixture must too, or the fixture itself contradicts the
  # documented git limitation scaffold_repo is built around.
  echo "template stub" > _templates/session.md
  echo "top level file" > README.md
  echo "rolling state" > hot.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init
}

@test "scaffold_repo creates every top-level directory" {
  source "$DAEDALUS_HOME/core/lib.sh"
  run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/00_inbox" ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/80_sessions" ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/_templates" ]
}

@test "scaffold_repo downloads no file contents" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ ! -f "$DAEDALUS_HOME/target/h/vaults/a/80_sessions/private.md" ]
  [ ! -f "$DAEDALUS_HOME/target/h/vaults/a/00_inbox/item.md" ]
  [ ! -f "$DAEDALUS_HOME/target/h/vaults/a/README.md" ]
}

@test "scaffold_repo creates hot.md with a placeholder line" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ -f "$DAEDALUS_HOME/target/h/vaults/a/hot.md" ]
  run grep -qi "placeholder" "$DAEDALUS_HOME/target/h/vaults/a/hot.md"
  [ "$status" -eq 0 ]
}

@test "scaffold_repo leaves no git checkout behind" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ ! -d "$DAEDALUS_HOME/target/h/vaults/a/.git" ]
}

@test "scaffold_repo is idempotent" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/00_inbox" ]
}

@test "scaffold_repo fails loudly on an unreachable repo" {
  source "$DAEDALUS_HOME/core/lib.sh"
  run scaffold_repo "$BATS_TEST_TMPDIR/does-not-exist" "$DAEDALUS_HOME/target/h/vaults/b"
  [ "$status" -ne 0 ]
}

@test "scaffold_repo's clone never has blob content on disk (pins --filter=blob:none --no-checkout)" {
  source "$DAEDALUS_HOME/core/lib.sh"
  DAEDALUS_SCAFFOLD_KEEP_TMP=1 run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  kept_tmp="$(printf '%s\n' "$output" | sed -n 's/^KEPT_TMP=//p')"
  [ -n "$kept_tmp" ]
  [ -d "$kept_tmp/shape" ]
  # A full checkout would put private.md, item.md, and README.md's actual
  # bytes on disk inside the clone. blob:none + no-checkout must mean none
  # of that content — not even as a working-tree file, not as a loose
  # object blob that was ever written to a worktree — ever lands here.
  run find "$kept_tmp/shape" -type f -not -path '*/.git/*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scaffold_repo excludes dotfile directories such as .obsidian (app config, not vault taxonomy)" {
  mkdir -p "$SHAPEREPO/.obsidian"
  echo "app config" > "$SHAPEREPO/.obsidian/workspace.json"
  ( cd "$SHAPEREPO" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m "add dotfile dir" )

  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ ! -d "$DAEDALUS_HOME/target/h/vaults/a/.obsidian" ]
}

@test "scaffold_repo logs (does not delete) a destination directory the source no longer has" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  # Source shrinks: 00_inbox is removed from the tracked tree.
  ( cd "$SHAPEREPO" && git rm -rq 00_inbox/item.md && git -c user.email=t@t -c user.name=t commit -q -m "drop inbox" )

  run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  # Not deleted — a delete pass on a caller-supplied destination is a bigger
  # hazard than a stale empty directory (this product has already shipped
  # one path-traversal escape from a delete-adjacent operation).
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/00_inbox" ]
  # But drift must be visible, not silent.
  printf '%s\n' "$output" | grep -qF "00_inbox"
}
