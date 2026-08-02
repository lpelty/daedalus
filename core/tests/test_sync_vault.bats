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
