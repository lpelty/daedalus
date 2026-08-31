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

@test "a PASS run writes run.json, the vault summary, the manifest, and prints the run-id last" {
  write_config "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  id="$(printf '%s\n' "$output" | tail -1)"
  case "$id" in [0-9]*-[0-9]*-[0-9a-f]*) : ;; *) echo "no run-id: $output"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/evidence/$id/run.json" ]
  [ -f "$DAEDALUS_HOME/state/evidence/$id/gate-1.log" ]
  [ -f "$DAEDALUS_HOME/vault/evidence/$id.md" ]
  [ "$(grep -c '"result": "INVALID"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]   # fixture target is not a git repo
  [ "$(grep -c "^result: INVALID" "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 1 ]
  [ "$(grep -c "$id" "$DAEDALUS_HOME/vault/evidence/.manifest")" -ge 3 ]
  [ "$(grep -c 'echo\|true' "$DAEDALUS_HOME/vault/evidence/$id.md")" -ge 1 ]
}

@test "a git target yields a real fingerprint and PASS; a gate that mutates the tree yields INVALID" {
  cp "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  git init -q "$DAEDALUS_HOME/target/thing"
  git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ "$(grep -c '"fingerprint": "null"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 0 ]
  [ "$(grep -c "fingerprint.err" "$DAEDALUS_HOME/vault/evidence/.manifest")" -ge 1 ]
  write_config "  - echo mutated > new.txt"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "INVALID"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a FAIL run records the exit code, prints run-id and log path, and no excerpt reaches the vault" {
  # The secret must appear only in the gate's runtime OUTPUT, not in the
  # command text itself — the vault legitimately shows the operator-authored
  # command (see the PASS test above), so the token is assembled at runtime
  # via concatenation rather than spelled out in the gate string, keeping
  # this test a check on output-leakage rather than command-echoing.
  write_config "  - echo SECRET_TOKEN\"_abc\"; false"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"run-id: "*) : ;; *) echo "no run-id on FAIL: $output"; return 1 ;; esac
  case "$output" in *"log: "*) : ;; *) echo "no log path on FAIL: $output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c SECRET_TOKEN_abc "$DAEDALUS_HOME/state/evidence/$id/gate-1.log")" -eq 1 ]
  [ "$(grep -c SECRET_TOKEN_abc "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 0 ]
  [ "$(grep -c '"exit": 1' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a gate command containing a literal tab is refused loudly, before any evidence claims PASS" {
  # write_config's heredoc can't carry a literal tab byte reliably, so the
  # config is written directly with printf, embedding a real tab (\t) inside
  # the gate command — not an escaped/quoted tab, the actual byte that would
  # corrupt the tab-delimited row format.
  printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\ngates:\n  - echo one\ttwo\n' \
    > "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"contains a tab"*) : ;; *) echo "expected a tab refusal; got: $output"; return 1 ;; esac
  # No evidence run.json anywhere should ever claim PASS for this run: the
  # refusal must happen before any gate executes, so no run directory with a
  # PASS result exists at all.
  if [ -d "$DAEDALUS_HOME/state/evidence" ]; then
    run grep -rl '"result": "PASS"' "$DAEDALUS_HOME/state/evidence"
    [ "$status" -ne 0 ]
  fi
}

@test "config outside DAEDALUS_HOME is refused" {
  write_config "  - true"
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/outside.yaml"
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/outside.yaml" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"outside"*) : ;; *) echo "expected refusal: $output"; return 1 ;; esac
}
