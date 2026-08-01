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

@test "setup fails loudly when config.yaml is absent" {
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/setup.sh" "$DAEDALUS_HOME/core/"
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *config*) : ;;
    *) echo "expected the failure to name config; got: $output"; return 1 ;;
  esac
}

@test "setup reports each phase it runs" {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/setup.sh" "$SRC/sync-target.sh" "$SRC/sync-vault.sh" "$SRC/doctor.sh" "$DAEDALUS_HOME/core/"

  SHIP="$BATS_TEST_TMPDIR/ship"
  mkdir -p "$SHIP"
  cd "$SHIP"
  git init -q -b main
  printf 'vaults/\n' > .gitignore
  echo code > file.txt
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  KB="$BATS_TEST_TMPDIR/kb"
  mkdir -p "$KB"
  cd "$KB"
  git init -q -b main
  echo kb > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $SHIP
  branch: main
  scaffold: vaults/a=$SHAPEREPO
vault:
  repo: $KB
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ]
  case "$output" in
    *scaffold*) : ;;
    *) echo "expected setup to report the scaffold phase; got: $output"; return 1 ;;
  esac
  [ -d "$DAEDALUS_HOME/target/ship/vaults/a/00_inbox" ]
}

@test "setup rejects a scaffold path that escapes the target checkout via .." {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/setup.sh" "$SRC/sync-target.sh" "$SRC/sync-vault.sh" "$SRC/doctor.sh" "$DAEDALUS_HOME/core/"

  SHIP="$BATS_TEST_TMPDIR/ship"
  mkdir -p "$SHIP"
  cd "$SHIP"
  git init -q -b main
  printf 'vaults/\n' > .gitignore
  echo code > file.txt
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  KB="$BATS_TEST_TMPDIR/kb"
  mkdir -p "$KB"
  cd "$KB"
  git init -q -b main
  echo kb > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $SHIP
  branch: main
  scaffold: ../../escaped=$SHAPEREPO
vault:
  repo: $KB
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *"must stay inside"*) : ;;
    *) echo "expected the failure to name the traversal; got: $output"; return 1 ;;
  esac
  # The guard must fire before scaffold_repo ever runs mkdir -p on the
  # unvalidated path — an exit-code check alone would still pass if the
  # directory were created first and the failure came from something else
  # afterward. Nothing named "escaped" may exist anywhere under BATS_TEST_TMPDIR,
  # inside DAEDALUS_HOME or out (e.g. at DAEDALUS_HOME/../../escaped).
  run find "$BATS_TEST_TMPDIR" -depth -name escaped
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
