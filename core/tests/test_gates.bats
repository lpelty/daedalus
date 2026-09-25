#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/target/thing"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/gates.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
  echo "marker" > "$DAEDALUS_HOME/target/thing/marker.txt"
}

# write_config <gate-lines> [verify-lines] — the refuter is ON by default
# (v0.6.1), and a real `claude` must never run inside this suite, so the
# fixture config switches it off — with the reason gates.sh demands — unless
# a test supplies its own verify block.
write_config() {
  local verify="${2-  refute: false
  refute_off_reason: bats fixture — a real claude must never be invoked in tests}"
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: https://example.com/thing.git
  branch: main
gates:
$1
verify:
$verify
EOF
}

# install_refuter — everything refute.sh needs beside gates.sh: the script,
# the fingerprint, the charter, its renderer, and the pitfall selector with
# the hook module it imports.
install_refuter() {
  mkdir -p "$DAEDALUS_HOME/core/agents"
  cp "$SRC/refute.sh" "$SRC/fingerprint.sh" "$SRC/agentdef.py" "$SRC/refute-pitfalls.py" "$SRC/pitfall-inject.py" "$DAEDALUS_HOME/core/"
  cp "$SRC/agents/refuter.md" "$DAEDALUS_HOME/core/agents/"
}

# git_target — make the fixture target a committed git repo, so the
# fingerprint is real and a PASS is a PASS. `-b main` because the config
# names `main` as the base: on a host whose init.defaultBranch is master
# the base ref would not exist, every diff against it would fail the same
# way with or without a fix, and a positive control on the diff would pass
# vacuously (it did — Xcode's gitconfig sets main and hid it).
git_target() {
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
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

@test "an empty gates list dies before creating a run directory — validation before side effects" {
  # The zero-gates die used to happen after the run-id, mkdir, and
  # fingerprint work, which stranded a fingerprint.err and an empty run
  # directory that no manifest line ever pointed at. Both validations now
  # run first: nothing under state/evidence/ should exist at all.
  write_config ""
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  [ ! -d "$DAEDALUS_HOME/state/evidence" ]
}

@test "a gate command containing a tab dies before creating a run directory — validation before side effects" {
  printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\ngates:\n  - echo one\ttwo\n' \
    > "$DAEDALUS_HOME/config.yaml"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"contains a tab"*) : ;; *) echo "expected a tab refusal; got: $output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/evidence" ]
}

@test "a run whose fingerprint is null writes run.json, the vault summary, and the manifest as INVALID, and does not print a citable run-id" {
  # The fixture target is not a git repo, so the fingerprint is null on both
  # sides and the run is INVALID — a run.json and vault summary still get
  # written (this test locates them by directory listing, not by parsing a
  # run-id off stdout), but nothing in the output should read as a citable
  # run-id: an INVALID run is not something a claim should point at.
  write_config "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"run INVALID — do not cite"*) : ;; *) echo "expected the INVALID notice; got: $output"; return 1 ;; esac
  case "$output" in *"all gates passed"*) echo "must not print the PASS message for an INVALID run: $output"; return 1 ;; *) : ;; esac
  id="$(ls "$DAEDALUS_HOME/state/evidence" | head -1)"
  [ -n "$id" ]
  [ -f "$DAEDALUS_HOME/state/evidence/$id/run.json" ]
  [ -f "$DAEDALUS_HOME/state/evidence/$id/gate-1.log" ]
  [ -f "$DAEDALUS_HOME/vault/evidence/$id.md" ]
  [ "$(grep -c '"result": "INVALID"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]   # fixture target is not a git repo
  [ "$(grep -c "^result: INVALID" "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 1 ]
  [ "$(grep -c "$id" "$DAEDALUS_HOME/vault/evidence/.manifest")" -ge 3 ]
  [ "$(grep -c 'echo\|true' "$DAEDALUS_HOME/vault/evidence/$id.md")" -ge 1 ]
}

@test "a PASS run prints the run-id last" {
  write_config "  - true"
  cp "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  git init -q -b main "$DAEDALUS_HOME/target/thing"
  git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  id="$(printf '%s\n' "$output" | tail -1)"
  case "$id" in [0-9]*-[0-9]*-[0-9a-f]*) : ;; *) echo "no run-id: $output"; return 1 ;; esac
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  case "$output" in *"all gates passed"*) : ;; *) echo "expected the PASS message; got: $output"; return 1 ;; esac
}

@test "a git target yields a real fingerprint and PASS; a gate that mutates the tree yields INVALID" {
  cp "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  git init -q -b main "$DAEDALUS_HOME/target/thing"
  git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ "$(grep -c '"fingerprint": "null"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 0 ]
  [ "$(grep -c "fingerprint.err" "$DAEDALUS_HOME/vault/evidence/.manifest")" -ge 1 ]
  prev_id="$id"
  write_config "  - echo mutated > new.txt"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"run INVALID — do not cite"*) : ;; *) echo "expected the INVALID notice; got: $output"; return 1 ;; esac
  id="$(ls "$DAEDALUS_HOME/state/evidence" | grep -v "^$prev_id\$")"
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

@test "refute is off with a reason, on when enabled, and a REFUTED verdict flips the run to FAIL" {
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf 'VERDICT: REFUTED\nThe change does not do what the criteria say.\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]   # off with a reason: untouched
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  [ "$(grep -c "$id-review.md" "$DAEDALUS_HOME/vault/evidence/.manifest")" -eq 1 ]
  # FINDING 1: the vault .md frontmatter must agree with run.json after the flip.
  [ "$(grep -c "^result: FAIL" "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 1 ]
}

@test "refute with claude missing from PATH fails loud instead of silently staying PASS" {
  install_refuter
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  # A PATH built from a fixed set of directories with no `claude` on it — the
  # host running this suite may have a real claude CLI installed, and the
  # brief is explicit that a real `claude` must never be invoked in tests.
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *"claude not found"*) : ;;
    *) echo "expected 'claude not found' in output; got: $output"; return 1 ;;
  esac
}

@test "a markdown-wrapped VERDICT: REFUTED still flips the run to FAIL" {
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin2"
  cat > "$BATS_TEST_TMPDIR/bin2/claude" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '**VERDICT:** REFUTED\nThe change does not do what the criteria say.\n'
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin2/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin2:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a bold-word VERDICT (asterisks before the colon) still flips the run to FAIL" {
  # **VERDICT**: REFUTED — the asterisks close BEFORE the colon. The old
  # regex only allowed them after (VERDICT:**), so this shape passed as
  # STANDS. Ledgered as a refute-enablement gap in 055; pinned here.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin3"
  cat > "$BATS_TEST_TMPDIR/bin3/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf 'The criteria are not met.\n\n> **VERDICT**: REFUTED\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin3/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin3:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a present-but-failing claude CLI fails the run loud instead of yielding STANDS" {
  # The second ledgered gap: claude on PATH but exiting nonzero used to
  # leave an empty verdict body, the REFUTED grep missed, and the run
  # stayed PASS — crash reported as green, this repo's founding pitfall.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin4"
  cat > "$BATS_TEST_TMPDIR/bin4/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
exit 1
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin4/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin4:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  case "$output" in *"refuter CLI failed"*) : ;; *) echo "expected a loud refuter failure; got: $output"; return 1 ;; esac
}

@test "a refuter reply with no VERDICT line fails the run instead of defaulting to STANDS" {
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin5"
  cat > "$BATS_TEST_TMPDIR/bin5/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf 'I reviewed the change and found several concerns.\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin5/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin5:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  case "$output" in *"no VERDICT line"*) : ;; *) echo "expected the no-verdict reason; got: $output"; return 1 ;; esac
  # The review file WAS written in this exit-2 sub-case — pin that it exists
  # and is manifested, not just incidentally named in stderr text.
  [ -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  [ "$(grep -c "$id-review.md" "$DAEDALUS_HOME/vault/evidence/.manifest")" -eq 1 ]
}

@test "an echoed instruction line does not false-REFUTE a run whose real verdict is STANDS" {
  # The prompt tells the model to end with "VERDICT: REFUTED or VERDICT:
  # STANDS"; a reply quoting that line verbatim matched the old prefix-only
  # regex and flipped a passing run. The verdict match is line-anchored now.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin6"
  cat > "$BATS_TEST_TMPDIR/bin6/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf 'VERDICT: REFUTED or VERDICT: STANDS was requested; my verdict follows.\n\nVERDICT: STANDS\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin6/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin6:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a hung refuter is killed at verify.refute_timeout — its whole process group — and fails the run loud instead of hanging gates" {
  # The residual after f7528ea: crash and mute both fail loud, but a claude
  # that never returns hung gates.sh forever — no verdict, no FAIL, no
  # evidence, just a stuck gate. A hung reviewer is not a verdict either:
  # bound the invocation, kill it, and land in the same uncertifiable exit 2.
  #
  # The stub has the real shape of a hang: the CLI itself answers TERM, but
  # the thing it is waiting on (a tool child, an MCP server, a node process
  # whose event loop is blocked) ignores TERM. A watchdog that stops once
  # the direct child dies leaves that descendant running.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin6"
  cat > "$BATS_TEST_TMPDIR/bin6/claude" <<STUB
#!/usr/bin/env bash
cat > /dev/null
sh -c 'trap "" TERM; echo \$\$ > "\$0"; exec sleep 60' "$BATS_TEST_TMPDIR/hung-child.pid" &
wait
printf 'VERDICT: STANDS\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin6/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true
  refute_timeout: 2"
  t0="$(date +%s)"
  PATH="$BATS_TEST_TMPDIR/bin6:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  elapsed="$(( $(date +%s) - t0 ))"
  [ "$status" -ne 0 ]
  [ "$elapsed" -lt 15 ] || { echo "gates.sh waited ${elapsed}s — the refuter was not bounded"; return 1; }
  case "$output" in *"refuter timed out"*) : ;; *) echo "expected a loud timeout; got: $output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ "$(grep -c "^result: FAIL" "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 1 ]
  # A killed reviewer wrote no verdict: no review file may claim one.
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  # And nothing it spawned survives it. Reaping after reparenting is not
  # instantaneous, so allow two seconds; a zombie counts as dead.
  child="$(cat "$BATS_TEST_TMPDIR/hung-child.pid")"
  [ -n "$child" ]
  alive() { kill -0 "$1" 2>/dev/null && case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; *) return 0 ;; esac; }
  for _ in $(seq 1 20); do alive "$child" || break; sleep 0.1; done
  if alive "$child"; then
    kill -9 "$child" 2>/dev/null
    echo "the TERM-ignoring child ($child) survived the watchdog — only the shim was killed"; return 1
  fi
}

@test "an invalid verify.refute_timeout is refused before any gate runs — validation before side effects, never an unbounded run" {
  # A typo in operator config must not manufacture evidence: a FAIL run.json
  # written after every gate has executed reads, in the record, exactly like
  # a real refutation. gates.sh refuses up front, the way it refuses a tab in
  # a gate command or an empty gates list.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin7"
  cat > "$BATS_TEST_TMPDIR/bin7/claude" <<STUB
#!/usr/bin/env bash
cat > /dev/null
touch "$BATS_TEST_TMPDIR/claude-ran"
printf 'VERDICT: STANDS\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin7/claude"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  for bad in 'ten minutes' '0' '00' '-5' '600.5' '99999999999999999999'; do
    rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
    write_config "  - true" "  refute: true
  refute_timeout: $bad"
    PATH="$BATS_TEST_TMPDIR/bin7:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
    [ "$status" -ne 0 ] || { echo "refute_timeout=$bad was accepted"; return 1; }
    case "$output" in *"whole number of seconds"*) : ;; *) echo "expected a refute_timeout refusal for '$bad'; got: $output"; return 1 ;; esac
    [ ! -d "$DAEDALUS_HOME/state/evidence" ] || { echo "refute_timeout=$bad created evidence before being refused"; return 1; }
    [ ! -f "$BATS_TEST_TMPDIR/claude-ran" ] || { echo "refute_timeout=$bad reached the refuter"; return 1; }
  done
}

@test "a refute.sh that dies with an unexpected exit code fails the run — no nonzero refuter exit is a PASS" {
  # gates.sh allow-listed refuter exits 1 and 2. A refuter killed by a
  # signal exits 143 and left result=PASS: a reviewer that never finished,
  # certifying. Any nonzero exit is not a verdict.
  cp "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  printf '#!/usr/bin/env bash\nkill -TERM $$\n' > "$DAEDALUS_HOME/core/refute.sh"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  write_config "  - true" "  refute: true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ -n "$id" ] || { echo "no run-id in output: $output"; return 1; }
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ "$(grep -c "^result: FAIL" "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 1 ]
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
}

# --- Default-on refuter, the reasoned off-switch, the charter (v0.6.1) -------

# recording_stub <dir> — a fake claude that saves its argv and stdin beside
# itself and answers STANDS, so a test can see exactly how it was invoked.
recording_stub() {
  mkdir -p "$1"
  cat > "$1/claude" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$1/argv"
cat > "$1/stdin"
pwd > "$1/cwd"
# --agents names a file that must exist AT CALL TIME (refute.sh deletes it after).
prev=""; for a in "\$@"; do [ "\$prev" = "--agents" ] && cp "\$a" "$1/agents.json"; prev="\$a"; done
printf 'VERDICT: STANDS\\n'
STUB
  chmod +x "$1/claude"
}

@test "the refuter is ON by default: no verify block at all, and a PASS run is still reviewed (no refute_timeout needed)" {
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin8"
  cat > "$BATS_TEST_TMPDIR/bin8/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf 'VERDICT: REFUTED\nDefault-on caught this.\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin8/claude"
  git_target
  write_config "  - true" ""       # verify: block present but empty — nothing set
  PATH="$BATS_TEST_TMPDIR/bin8:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ -n "$id" ] || { echo "no run-id: $output"; return 1; }
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  # No verify: key anywhere in the file either.
  cat > "$DAEDALUS_HOME/config.yaml" <<'CFG'
target:
  repo: https://example.com/thing.git
  branch: main
gates:
  - true
CFG
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin8:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  # And an explicit true is the same as unset.
  write_config "  - true" "  refute: true"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin8:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
}

@test "verify.refute: false without a refute_off_reason dies BEFORE any gate runs; with a reason it is honored; a typo is refused" {
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin9"
  cat > "$BATS_TEST_TMPDIR/bin9/claude" <<STUB
#!/usr/bin/env bash
cat > /dev/null
touch "$BATS_TEST_TMPDIR/claude-ran"
printf 'VERDICT: STANDS\n'
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin9/claude"
  git_target
  for verify in "  refute: false" "  refute: false
  refute_off_reason:" "  refute: false
  refute_off_reason: ~" "  refute: false
  refute_off_reason: \"\""; do
    rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
    write_config "  - echo GATE_RAN > $BATS_TEST_TMPDIR/gate-ran" "$verify"
    PATH="$BATS_TEST_TMPDIR/bin9:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
    [ "$status" -ne 0 ] || { echo "refute: false with no reason was accepted (verify block: $verify)"; return 1; }
    case "$output" in *"refute_off_reason"*) : ;; *) echo "expected the off-reason refusal; got: $output"; return 1 ;; esac
    [ ! -d "$DAEDALUS_HOME/state/evidence" ] || { echo "evidence was created before the refusal"; return 1; }
    [ ! -f "$BATS_TEST_TMPDIR/gate-ran" ] || { echo "a gate ran before the refusal"; return 1; }
    [ ! -f "$BATS_TEST_TMPDIR/claude-ran" ] || { echo "the refuter ran despite refute: false"; return 1; }
  done
  # A reason makes the off-switch real: the gate runs, PASS stands, claude never starts.
  write_config "  - echo GATE_RAN > $BATS_TEST_TMPDIR/gate-ran" "  refute: false
  refute_off_reason: rung 1 has not run on a real assignment yet"
  PATH="$BATS_TEST_TMPDIR/bin9:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/gate-ran" ]
  [ ! -f "$BATS_TEST_TMPDIR/claude-ran" ]
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  # Neither true nor false is a typo, refused up front.
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  write_config "  - true" "  refute: yes"
  PATH="$BATS_TEST_TMPDIR/bin9:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"must be true or false"*) : ;; *) echo "expected a typo refusal; got: $output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/evidence" ]
}

@test "refute.sh invokes the charter: -p --agent refuter --agents <rendered file> with hooks off; --model only from verify.refute_model" {
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin10"
  git_target
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin10:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  argv="$BATS_TEST_TMPDIR/bin10/argv"
  # The invariants, not the argv positions: print mode, the charter selected
  # by name from a rendered file that existed at call time, hooks off, the
  # target granted as an extra directory, no --model unless configured.
  python3 - "$argv" "$DAEDALUS_HOME/target/thing" <<'CHECK'
import json, sys
argv = open(sys.argv[1]).read().split("\n")
pairs = list(zip(argv, argv[1:]))
assert "-p" in argv, argv
assert ("--agent", "refuter") in pairs, argv
agents = [b for a, b in pairs if a == "--agents"]
assert len(agents) == 1 and agents[0].startswith("/"), argv
settings = [b for a, b in pairs if a == "--settings"]
assert len(settings) == 1 and json.loads(settings[0]).get("disableAllHooks") is True, argv
assert ("--add-dir", sys.argv[2]) in pairs, argv
assert "--model" not in argv, argv
CHECK
  # The stub ran from an EMPTY directory — not Daedalus's, not the target's —
  # so neither project's CLAUDE.md is in the reviewer's context.
  cwd="$(cat "$BATS_TEST_TMPDIR/bin10/cwd")"
  [ "$cwd" != "$DAEDALUS_HOME" ] && [ "$cwd" != "$DAEDALUS_HOME/target/thing" ]
  case "$cwd" in "$DAEDALUS_HOME"/*) echo "refuter ran inside DAEDALUS_HOME: $cwd"; return 1 ;; esac
  [ ! -d "$cwd" ]   # a temp dir, removed afterwards
  # The --agents file existed at call time and was the rendered charter.
  [ -f "$BATS_TEST_TMPDIR/bin10/agents.json" ]
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["refuter"]
assert sorted(d["tools"]) == ["Glob", "Grep", "Read"], d["tools"]
assert "Bash" in d["disallowedTools"] and d["omitClaudeMd"] is True
assert d["model"] and d["model"] != "inherit", d["model"]
assert "Never validate" in d["prompt"]
' "$BATS_TEST_TMPDIR/bin10/agents.json"
  # ...and is gone afterwards (a temp file, not a tracked artifact).
  [ ! -f "$(grep -A1 -- '^--agents$' "$argv" | tail -1)" ]
  # verify.refute_model overrides the charter's model on the command line.
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  write_config "  - true" "  refute: true
  refute_model: sonnet"
  PATH="$BATS_TEST_TMPDIR/bin10:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -c -- '^--model$' "$argv")" -eq 1 ]
  [ "$(grep -A1 -- '^--model$' "$argv" | tail -1)" = "sonnet" ]
}

@test "the refuter's input carries criteria, evidence, the pitfalls for the touched paths, then the diff — in that order" {
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin11"
  mkdir -p "$DAEDALUS_HOME/vault/pitfalls"
  cp "$BATS_TEST_DIRNAME/fixtures/pitfalls/aa-bad-timeout.md" "$BATS_TEST_DIRNAME/fixtures/pitfalls/bb-bats-brackets.md" "$DAEDALUS_HOME/vault/pitfalls/"
  printf -- '---\ntype: pitfall\n---\n# Waits to be asked\n\nA lesson with no trigger.\n' > "$DAEDALUS_HOME/vault/pitfalls/zz-no-trigger.md"
  printf 'old\n' > "$DAEDALUS_HOME/target/thing/t.bats"
  git_target
  # Committed work on a feature branch (the three-dot diff against main)...
  git -C "$DAEDALUS_HOME/target/thing" switch -q -c fix/x
  printf 'committed\n' > "$DAEDALUS_HOME/target/thing/c.txt"
  git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m c
  # ...and uncommitted work on top (the diff against HEAD).
  printf 'new\n' >> "$DAEDALUS_HOME/target/thing/t.bats"      # the diff touches a .bats file
  printf 'AC-1: the thing must thing.\n' > "$BATS_TEST_TMPDIR/criteria.md"
  write_config "  - true" "  refute: true"
  GATES_CRITERIA="$BATS_TEST_TMPDIR/criteria.md" PATH="$BATS_TEST_TMPDIR/bin11:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  stdin="$BATS_TEST_TMPDIR/bin11/stdin"
  # The reviewer is told where the checkout is: the diff's paths are relative to it.
  [ "$(grep -cF "checkout at $DAEDALUS_HOME/target/thing" "$stdin")" -eq 1 ]
  [ "$(grep -cF 'AC-1: the thing must thing.' "$stdin")" -eq 1 ]
  [ "$(grep -cF '## Pitfalls that apply to the touched paths' "$stdin")" -eq 1 ]
  [ "$(grep -cF '### Pitfall: A non-final double-bracket assertion is silently ignored' "$stdin")" -eq 1 ]
  [ "$(grep -cF '### Pitfall: Waits to be asked' "$stdin")" -eq 1 ]
  [ "$(grep -cF 'timeout command is absent' "$stdin")" -eq 0 ]
  # Each hunk exactly once: the committed one from the three-dot diff, the
  # uncommitted one from the diff against HEAD. A two-dot fallback showed
  # the uncommitted hunk twice; a missing base ref would show the committed
  # hunk zero times.
  [ "$(grep -cF '+committed' "$stdin")" -eq 1 ]
  [ "$(grep -cF '+new' "$stdin")" -eq 1 ]
  # Order: criteria, evidence, pitfalls, diff.
  c="$(grep -nF '## Acceptance criteria' "$stdin" | cut -d: -f1)"
  e="$(grep -nF '## Evidence' "$stdin" | cut -d: -f1)"
  p="$(grep -nF '## Pitfalls that apply' "$stdin" | cut -d: -f1)"
  d="$(grep -nF '## Diff against main' "$stdin" | cut -d: -f1)"
  [ "$c" -lt "$e" ] && [ "$e" -lt "$p" ] && [ "$p" -lt "$d" ]
  # Positive control: with the .bats change reverted, bb drops out and the section says so.
  git -C "$DAEDALUS_HOME/target/thing" checkout -q -- t.bats
  rm "$DAEDALUS_HOME/vault/pitfalls/zz-no-trigger.md"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin11:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  [ "$(grep -cF 'double-bracket' "$stdin")" -eq 0 ]
  [ "$(grep -c -A1 -F '## Pitfalls that apply to the touched paths' "$stdin")" -ge 1 ]
  [ "$(grep -A1 -F '## Pitfalls that apply to the touched paths' "$stdin" | tail -1)" = "(none)" ]
}

@test "a missing or crashing pitfall selector cannot certify: run FAIL, no review file, claude never started, reason in the log" {
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin13"
  git_target
  write_config "  - true" "  refute: true"
  printf 'raise SystemExit("boom")\n' > "$DAEDALUS_HOME/core/refute-pitfalls.py"
  PATH="$BATS_TEST_TMPDIR/bin13:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"pitfall selector failed"*"boom"*) : ;; *) echo "expected the selector failure with its reason; got: $output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  [ ! -f "$BATS_TEST_TMPDIR/bin13/argv" ]
  # A selector that is not there at all is the same case — it used to read as "(none)".
  rm "$DAEDALUS_HOME/core/refute-pitfalls.py"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin13:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"pitfall selector failed"*) : ;; *) echo "expected the selector failure; got: $output"; return 1 ;; esac
  [ ! -f "$BATS_TEST_TMPDIR/bin13/argv" ]
}

@test "a missing or unrenderable charter cannot certify: exit 2, run FAIL, no review file, claude never started" {
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin12"
  git_target
  write_config "  - true" "  refute: true"
  rm "$DAEDALUS_HOME/core/agents/refuter.md"
  PATH="$BATS_TEST_TMPDIR/bin12:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"charter missing"*) : ;; *) echo "expected the missing-charter reason; got: $output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  [ ! -f "$BATS_TEST_TMPDIR/bin12/argv" ]
  # A charter that does not render is the same case.
  printf 'not an agent\n' > "$DAEDALUS_HOME/core/agents/refuter.md"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin12:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"does not render"*) : ;; *) echo "expected the unrenderable reason; got: $output"; return 1 ;; esac
  [ ! -f "$BATS_TEST_TMPDIR/bin12/argv" ]
}
