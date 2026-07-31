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
  case "$output" in
    *PASS*) : ;;
    *) echo "expected a PASS line; got: $output"; return 1 ;;
  esac
}

@test "any gate failing exits non-zero" {
  write_config "  - true
  - false"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *FAIL*) : ;;
    *) echo "expected a FAIL line; got: $output"; return 1 ;;
  esac
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
  # POSIX [ ] with an explicit case match: unlike a non-final [[ ]], this is
  # enforced regardless of errexit state in the test body.
  case "$output" in
    *PASS*) : ;;
    *) echo "expected a PASS line for the second gate; got: $output"; return 1 ;;
  esac
  case "$output" in
    *FAIL*) : ;;
    *) echo "expected a FAIL line for the first gate; got: $output"; return 1 ;;
  esac
}

@test "a gate that reads stdin does not consume the remaining gate list" {
  write_config "  - echo GATE1; cat
  - echo GATE2_SHOULD_RUN
  - echo GATE3_SHOULD_RUN"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  # Gate output itself goes to /dev/null in gates.sh, so assert on the
  # PASS/FAIL log lines (which carry the gate text), not on GATE2/GATE3
  # appearing in captured stdout.
  case "$output" in
    *"PASS  echo GATE2_SHOULD_RUN"*) : ;;
    *) echo "expected gate 2 to run and PASS; got: $output"; return 1 ;;
  esac
  case "$output" in
    *"PASS  echo GATE3_SHOULD_RUN"*) : ;;
    *) echo "expected gate 3 to run and PASS; got: $output"; return 1 ;;
  esac
  [ "$status" -eq 0 ]
}

@test "an empty gates list exits non-zero and says so" {
  write_config ""
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *"no gates configured"*) : ;;
    *) echo "expected a 'no gates configured' message; got: $output"; return 1 ;;
  esac
}
