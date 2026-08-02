#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/sync-vault.sh" "$DAEDALUS_HOME/core/"
  cp -R "$SRC/templates" "$DAEDALUS_HOME/core/templates"
  export DAEDALUS_HOME

  VAULT_REPO="$BATS_TEST_TMPDIR/upstream-vault"
  mkdir -p "$VAULT_REPO"
  cd "$VAULT_REPO"
  git init -q -b main
  echo "kb" > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<CFG
vault:
  repo: $VAULT_REPO
CFG
}

@test "sync-vault scaffolds the exchange directory alongside the rest" {
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/vault/exchange" ]
}

@test "sync-vault is idempotent for the exchange directory" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/vault/exchange" ]
}

@test "sync-vault ships the exchange contract README" {
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/vault/exchange/README.md" ]
}

@test "the shipped exchange README carries the load-bearing contract" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run grep -qi "append-only" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
  run grep -q "SCOPE-CREEP" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
  run grep -q "in-reply-to" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
}

@test "sync-vault preserves an operator's edits to the exchange README on rerun" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  printf '%s\n' "operator-added-note" >> "$DAEDALUS_HOME/vault/exchange/README.md"

  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  run grep -q "operator-added-note" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
}

@test "sync-vault scaffolds the exchange/messages subfolder" {
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/vault/exchange/messages" ]
}

@test "sync-vault ships the Exchange.base view file" {
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/vault/exchange/Exchange.base" ]
}

@test "sync-vault preserves an operator's edits to Exchange.base on rerun" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  printf '%s\n' "    - operator-added-view" >> "$DAEDALUS_HOME/vault/exchange/Exchange.base"

  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  run grep -q "operator-added-view" "$DAEDALUS_HOME/vault/exchange/Exchange.base"
  [ "$status" -eq 0 ]
}

@test "the shipped exchange README documents the nested layout" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run grep -q "exchange/messages" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
  run grep -q "Exchange.base" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
  run grep -q "messages/\*.md" "$DAEDALUS_HOME/vault/exchange/README.md"
  [ "$status" -eq 0 ]
}

@test "the scaffolded vault contains sessions/" {
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/vault/sessions" ]
}

@test "the scaffolded vault contains hot.md carrying the intent-only rule" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ -f "$DAEDALUS_HOME/vault/hot.md" ]
  run grep -qF "records intent" "$DAEDALUS_HOME/vault/hot.md"
  [ "$status" -eq 0 ]
  run grep -qF "can this change without anyone editing a file" "$DAEDALUS_HOME/vault/hot.md"
  [ "$status" -eq 0 ]
}

@test "the session template ships and carries the Context section" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ -f "$DAEDALUS_HOME/vault/sessions/_template.md" ]
  run grep -qF "why did this session need to happen" "$DAEDALUS_HOME/vault/sessions/_template.md"
  [ "$status" -eq 0 ]
}

@test "the session template tells its reader that entries stand alone" {
  # The shape rule is the point of the template. Without it the file is a
  # set of empty headings and a writer fills them with report prose.
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run grep -qF "stand alone" "$DAEDALUS_HOME/vault/sessions/_template.md"
  [ "$status" -eq 0 ]
}

@test "a rerun leaves an edited hot.md alone" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  printf 'operator edit\n' >> "$DAEDALUS_HOME/vault/hot.md"
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run grep -qF "operator edit" "$DAEDALUS_HOME/vault/hot.md"
  [ "$status" -eq 0 ]
}

@test "a rerun leaves an edited session template alone" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  printf 'operator edit\n' >> "$DAEDALUS_HOME/vault/sessions/_template.md"
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run grep -qF "operator edit" "$DAEDALUS_HOME/vault/sessions/_template.md"
  [ "$status" -eq 0 ]
}
