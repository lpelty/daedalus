#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/sync-vault.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME

  VAULT_REPO="$BATS_TEST_TMPDIR/upstream-vault"
  mkdir -p "$VAULT_REPO"
  cd "$VAULT_REPO"
  git init -q -b main
  echo "kb" > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
vault:
  repo: $VAULT_REPO
EOF
}

@test "sync-vault scaffolds the exchange directory alongside the rest" {
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/vault/exchange" ]
  [ -d "$DAEDALUS_HOME/vault/infrastructure" ]
  [ -d "$DAEDALUS_HOME/vault/specs" ]
  [ -d "$DAEDALUS_HOME/vault/plans" ]
  [ -d "$DAEDALUS_HOME/vault/proposals" ]
  [ -d "$DAEDALUS_HOME/vault/pitfalls" ]
}

@test "sync-vault is idempotent for the exchange directory" {
  bash "$DAEDALUS_HOME/core/sync-vault.sh"
  run bash "$DAEDALUS_HOME/core/sync-vault.sh"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/vault/exchange" ]
}
