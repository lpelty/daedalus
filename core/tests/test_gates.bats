#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/target/thing"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/gates.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
  echo "marker" > "$DAEDALUS_HOME/target/thing/marker.txt"
}

write_config() {
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: https://example.com/thing.git
  branch: main
gates:
$1
EOF
}

@test "all gates passing exits 0" {
  write_config "  - true
  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
}

@test "any gate failing exits non-zero" {
  write_config "  - true
  - false"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "gates run from the target checkout root" {
  write_config "  - test -f marker.txt"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
}

@test "a later gate still runs after an earlier one fails" {
  write_config "  - false
  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"FAIL"* ]]
}
