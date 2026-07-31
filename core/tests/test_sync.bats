#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/lib.sh" "$DAEDALUS_HOME/core/"
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sync-target.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME

  # A real local git repo to act as the upstream target.
  UPSTREAM="$BATS_TEST_TMPDIR/upstream-harness"
  mkdir -p "$UPSTREAM"
  cd "$UPSTREAM"
  git init -q -b main
  echo "harness code" > file.txt
  git add file.txt
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $UPSTREAM
  branch: main
EOF
}

@test "sync-target clones into target/<repo-name>/ preserving the natural name" {
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/file.txt" ]
}

@test "sync-target is idempotent — a second run fast-forwards without error" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/file.txt" ]
}

@test "sync-target picks up new upstream commits" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  cd "$BATS_TEST_TMPDIR/upstream-harness"
  echo "more" > second.txt
  git add second.txt
  git -c user.email=t@t -c user.name=t commit -q -m second
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/second.txt" ]
}

@test "target_path prints the absolute path to the checkout" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  source "$DAEDALUS_HOME/core/lib.sh"
  run target_path
  [ "$output" = "$DAEDALUS_HOME/target/upstream-harness" ]
}
