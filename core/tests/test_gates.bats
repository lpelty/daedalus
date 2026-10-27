#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/target/thing"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/gates.sh" "$SRC/manifest-append.py" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
  # Registry isolation: gates.sh asks leaselib.py my-lease for this session's
  # window, and a present, empty session registry keeps every run from reading
  # the developer's real ~/.claude/sessions/.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$BATS_TEST_TMPDIR/sessions"
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
# the fingerprint, the charter, its renderer, the pitfall selector with the
# hook module it imports, and the direct-call launcher that runs the review
# (spec §6.1). The launcher refuses while distribution code is modified, so
# the fixture home is a git checkout with core/ committed and everything a
# deployment ignores ignored. A test that replaces a core/ file after this
# commits the replacement (commit_core).
install_refuter() {
  mkdir -p "$DAEDALUS_HOME/core/agents"
  cp "$SRC/refute.sh" "$SRC/review-lenses.py" "$SRC/fingerprint.sh" "$SRC/agentdef.py" "$SRC/refute-pitfalls.py" "$SRC/pitfall-inject.py" \
     "$SRC/verifylib.py" "$SRC/leaselib.py" "$SRC/call-agent.sh" "$SRC/call_agent.py" "$SRC/distcheck.py" "$DAEDALUS_HOME/core/"
  cp "$SRC/agents/refuter.md" "$DAEDALUS_HOME/core/agents/"
  printf 'target/\nvault/\nstate/\nworktrees/\nconfig.yaml\n__pycache__/\n*.pyc\n' > "$DAEDALUS_HOME/.gitignore"
  git init -q -b main "$DAEDALUS_HOME"
  commit_core
}
commit_core() {
  git -C "$DAEDALUS_HOME" add -A
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m fixture
}

# git_target — make the fixture target a committed git repo, so the
# fingerprint is real and a PASS is a PASS. `-b main` because the config
# names `main` as the base: on a host whose init.defaultBranch is master
# the base ref would not exist, every diff against it would fail the same
# way with or without a fix, and a positive control on the diff would pass
# vacuously (it did — Xcode's gitconfig sets main and hid it).
#
# It leaves ONE uncommitted edit behind: the refuter refuses an empty diff
# (exit 2, "nothing to review — cannot certify"), so a fixture whose tree
# matches its base would FAIL every review-shaped test for the wrong reason
# — and, before that refusal existed, let a stub verdict "review" nothing.
git_target() {
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
  printf 'edited after the commit\n' >> "$DAEDALUS_HOME/target/thing/marker.txt"
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
  git_target
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
  git_target
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
  git_target
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
  git_target
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
  git_target
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
  git_target
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
  git_target
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
  git_target
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

@test "a SIGTERM to gates.sh's process group mid-review (a tool timeout) takes claude down with it and strands no PASS-labelled or unmanifested evidence" {
  # Two defects behind one kill. The watchdog's finally did not run on
  # SIGTERM (Python's default action is an immediate exit), so claude — in
  # its own session — outlived it, still working, still writing. And
  # gates.sh wrote vault/evidence/<run>.md with result: PASS before the
  # review and its manifest line only after, so the kill left a
  # PASS-labelled evidence file with no manifest entry and no run.json
  # under a protected path Daedalus cannot remove. Daedalus runs gates.sh
  # from the Bash tool, whose default timeout is 120 s against a 600 s
  # review: this is the realistic shape, not a corner.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin14"
  cat > "$BATS_TEST_TMPDIR/bin14/claude" <<STUB
#!/usr/bin/env bash
cat > /dev/null
echo \$\$ > "$BATS_TEST_TMPDIR/claude.pid"
exec sleep 60
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin14/claude"
  git_target
  write_config "  - true" "  refute: true"
  # gates.sh in its OWN process group, so the kill reaches gates.sh,
  # refute.sh and the watchdog together — the way a tool timeout kills —
  # and nothing else. The stub claude is in its own session (refute.sh puts
  # it there) and is reached only if the watchdog does its job.
  PATH="$BATS_TEST_TMPDIR/bin14:$PATH" python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$DAEDALUS_HOME/core/gates.sh" > "$BATS_TEST_TMPDIR/gates.out" 2>&1 &
  G=$!
  for _ in $(seq 1 100); do [ -s "$BATS_TEST_TMPDIR/claude.pid" ] && break; sleep 0.1; done
  [ -s "$BATS_TEST_TMPDIR/claude.pid" ] || { echo "the stub claude never started: $(cat "$BATS_TEST_TMPDIR/gates.out")"; return 1; }
  stub="$(cat "$BATS_TEST_TMPDIR/claude.pid")"
  kill -TERM -- "-$G"
  wait "$G" || true
  alive() { kill -0 "$1" 2>/dev/null && case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; *) return 0 ;; esac; }
  for _ in $(seq 1 30); do alive "$stub" || break; sleep 0.1; done
  if alive "$stub"; then
    kill -9 "$stub" 2>/dev/null
    echo "claude ($stub) outlived the watchdog after SIGTERM — the finally never ran"; return 1
  fi
  # No evidence file may claim a result the review never reached: the vault
  # summary is written only after the verdict, so the vault holds nothing
  # for this run (at most the manifest).
  [ -z "$(ls "$DAEDALUS_HOME/vault/evidence"/*.md 2>/dev/null)" ] || { echo "stranded vault evidence:"; head -5 "$DAEDALUS_HOME/vault/evidence"/*.md; return 1; }
  # ...and whatever the run did leave under state/ is in the manifest, so
  # the boundary check has a remedy for it instead of a stray file.
  [ -f "$DAEDALUS_HOME/vault/evidence/.manifest" ] || { echo "no manifest at all"; return 1; }
  for f in "$DAEDALUS_HOME"/state/evidence/*/*; do
    [ -f "$f" ] || continue
    grep -qxF "$f" "$DAEDALUS_HOME/vault/evidence/.manifest" || { echo "unmanifested: $f"; return 1; }
  done
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
  git_target
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

@test "the refuter's diff covers a nested repository (target.nested) and untracked files, paths prefixed with the nested relpath, and never a Subproject stamp" {
  # On the one live deployment the target's write surface is a nested repo
  # that the outer .gitignore hides: the outer \`git diff\` showed nothing,
  # so every PASS was reviewed against an EMPTY diff — and default-on made
  # that opus review of nothing mandatory. Tracked as a gitlink instead,
  # the outer diff is a one-line \`Subproject commit …-dirty\` stamp, no
  # content. And \`git diff HEAD\` never showed an untracked new file.
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin15"
  # A pitfall whose glob is written in the target frame, matching the nested path.
  mkdir -p "$DAEDALUS_HOME/vault/pitfalls"
  printf -- "---\ntype: pitfall\ndate: 2026-01-01\napplies-to:\n  path:\n    - 'agents/**'\n---\n# Identity files carry no environment facts\n\nA lesson about agents/.\n" > "$DAEDALUS_HOME/vault/pitfalls/id-facts.md"
  # The nested repo, cloned from a bare origin the way sync-target.sh clones
  # (so origin/HEAD is recorded): committed work on a branch, plus an edit.
  O="$BATS_TEST_TMPDIR/nested-origin.git"; W="$BATS_TEST_TMPDIR/nested-work"
  git init -q --bare -b main "$O"; git init -q -b main "$W"
  printf 'identity\n' > "$W/CLAUDE.md"; git -C "$W" add -A; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m i
  git -C "$W" push -q "$O" main
  printf 'agents/\n' > "$DAEDALUS_HOME/target/thing/.gitignore"      # the live shape: the outer repo cannot see it
  git_target
  git clone -q "$O" "$DAEDALUS_HOME/target/thing/agents/one"
  N="$DAEDALUS_HOME/target/thing/agents/one"
  git -C "$N" switch -q -c fix/n
  printf 'nested committed\n' > "$N/SOUL.md"; git -C "$N" add -A; git -C "$N" -c user.email=t@x -c user.name=t commit -q -m n
  printf 'nested edit\n' >> "$N/CLAUDE.md"
  printf 'brand new\n' > "$DAEDALUS_HOME/target/thing/new.txt"       # untracked in the outer repo
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: https://example.com/thing.git
  branch: main
  nested: agents/one=$O
gates:
  - true
verify:
  refute: true
EOF
  PATH="$BATS_TEST_TMPDIR/bin15:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "gates failed: $output"; return 1; }
  stdin="$BATS_TEST_TMPDIR/bin15/stdin"
  # The nested repo's hunks, once each, under target-relative paths.
  [ "$(grep -cF '+nested committed' "$stdin")" -eq 1 ]
  [ "$(grep -cF '+nested edit' "$stdin")" -eq 1 ]
  [ "$(grep -cF 'diff --git a/agents/one/CLAUDE.md b/agents/one/CLAUDE.md' "$stdin")" -eq 1 ]
  [ "$(grep -cF 'diff --git a/agents/one/SOUL.md b/agents/one/SOUL.md' "$stdin")" -eq 1 ]
  [ "$(grep -cF '### agents/one (against origin/main)' "$stdin")" -eq 1 ]
  # The outer repo's untracked file is a hunk, and its edit too.
  [ "$(grep -cF 'diff --git a/new.txt b/new.txt' "$stdin")" -eq 1 ]
  [ "$(grep -cF '+brand new' "$stdin")" -eq 1 ]
  [ "$(grep -cF '+edited after the commit' "$stdin")" -eq 1 ]
  [ "$(grep -c 'Subproject commit' "$stdin")" -eq 0 ]
  # The pitfall selector saw the prefixed path.
  [ "$(grep -cF '### Pitfall: Identity files carry no environment facts' "$stdin")" -eq 1 ]
  # The real index of both repos is untouched by the temp-index technique.
  [ -z "$(git -C "$DAEDALUS_HOME/target/thing" diff --cached --name-only)" ]
  [ -z "$(git -C "$N" diff --cached --name-only)" ]
  # The same with the nested repo TRACKED as a gitlink in the outer repo.
  rm "$DAEDALUS_HOME/target/thing/.gitignore"
  git -C "$DAEDALUS_HOME/target/thing" -c advice.addEmbeddedRepo=false add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m gitlink
  printf 'outer edit\n' >> "$DAEDALUS_HOME/target/thing/marker.txt"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin15:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "gates failed (gitlink shape): $output"; return 1; }
  [ "$(grep -cF '+nested edit' "$stdin")" -eq 1 ]
  [ "$(grep -cF '+nested committed' "$stdin")" -eq 1 ]
  [ "$(grep -cF '+outer edit' "$stdin")" -eq 1 ]
  [ "$(grep -c 'Subproject commit' "$stdin")" -eq 0 ]
}

@test "an empty diff — nothing in the target or its nested repos differs from the base — cannot certify: exit 2, run FAIL, claude never started" {
  # A review of nothing that says STANDS is this repo's founding pitfall
  # class, and default-on used to make it mandatory on every PASS of a
  # deployment whose write surface the outer diff could not see.
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin16"
  git_target
  git -C "$DAEDALUS_HOME/target/thing" checkout -q -- marker.txt     # undo git_target's edit: a clean tree
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin16:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"nothing to review"*"cannot certify"*) : ;; *) echo "expected the empty-diff refusal; got: $output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  [ ! -f "$BATS_TEST_TMPDIR/bin16/argv" ]
  # Positive control: one untracked file is a diff, and the review runs.
  printf 'x\n' > "$DAEDALUS_HOME/target/thing/new.txt"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin16:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/bin16/argv" ]
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
  commit_core   # committed: the integrity check runs first, so an uncommitted removal would be "modified"
  PATH="$BATS_TEST_TMPDIR/bin12:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"charter missing"*) : ;; *) echo "expected the missing-charter reason; got: $output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  [ ! -f "$BATS_TEST_TMPDIR/bin12/argv" ]
  # A charter that does not render is the same case.
  printf 'not an agent\n' > "$DAEDALUS_HOME/core/agents/refuter.md"
  commit_core
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence"
  PATH="$BATS_TEST_TMPDIR/bin12:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"does not render"*) : ;; *) echo "expected the unrenderable reason; got: $output"; return 1 ;; esac
  [ ! -f "$BATS_TEST_TMPDIR/bin12/argv" ]
}

@test "run.json exists and is manifested — with the vault summary path — before the first gate runs, as RUNNING with the lease and session id; two concurrent runs leave a manifest whose every line is a complete path" {
  cp "$SRC/manifest-append.py" "$SRC/verifylib.py" "$SRC/leaselib.py" "$DAEDALUS_HOME/core/"
  mkdir -p "$DAEDALUS_HOME/state/leases"; printf '{"lease":"02","session_id":"sB","worktree":"worktrees/02"}' > "$DAEDALUS_HOME/state/leases/02.json"
  git_target
  # session sB is bound to window 02, so target_path resolves to its worktree (§4.4): give it one
  git -C "$DAEDALUS_HOME/target/thing" worktree add -q "$DAEDALUS_HOME/worktrees/02/thing" -b lease/02
  write_config "  - test -f \"\$DAEDALUS_HOME/state/evidence\"/*/run.json && grep -q RUNNING \"\$DAEDALUS_HOME/state/evidence\"/*/run.json && grep -q '\"lease\": \"02\"' \"\$DAEDALUS_HOME/state/evidence\"/*/run.json && grep -c vault/evidence \"\$DAEDALUS_HOME/vault/evidence/.manifest\" >/dev/null"   # cfg_list strips a trailing quote; end elsewhere
  DAEDALUS_SESSION_ID=sB run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ]
  write_config "  - sleep 1"
  ( bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null ) & ( bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null ) & wait
  while IFS= read -r line; do [ -z "$line" ] && continue; [ -e "$line" ] || { echo "incomplete manifest line: $line"; return 1; }; done < "$DAEDALUS_HOME/vault/evidence/.manifest"
}

@test "a DAEDALUS_HOME containing a space leaves no gate log unmanifested: every manifest line is one complete, existing path" {
  # Task 14 review: the pre-refuter append passed the gate-log paths through UNQUOTED
  # $(...) substitutions, so bash split each path at the space — two fragments per log,
  # neither a file — and the session's own Stop then blocked on evidence "no gate run
  # produced". The parent commit's `printf | awk >> manifest` never split; the regression
  # came in with the locked append. Paths never travel through word-splitting.
  mkdir -p "$BATS_TEST_TMPDIR/sp ace"; mv "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR/sp ace/dae"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/sp ace/dae"; export DAEDALUS_HOME
  write_config "  - true
  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ]
  id="$(basename "$(ls -d "$DAEDALUS_HOME"/state/evidence/*/)")"   # no git target: INVALID, so no run-id line
  n=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue; n=$((n+1))
    [ -e "$line" ] || { echo "incomplete manifest line: $line"; cat "$DAEDALUS_HOME/vault/evidence/.manifest"; return 1; }
  done < "$DAEDALUS_HOME/vault/evidence/.manifest"
  [ "$n" -eq 4 ] || { echo "expected 4 manifest lines (run.json, summary, two gate logs); got $n:"; cat "$DAEDALUS_HOME/vault/evidence/.manifest"; return 1; }
  grep -qxF "$DAEDALUS_HOME/state/evidence/$id/gate-1.log" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -qxF "$DAEDALUS_HOME/state/evidence/$id/gate-2.log" "$DAEDALUS_HOME/vault/evidence/.manifest"
}

@test "a manifest append that fails after a STANDS verdict is 'could not certify' (refuter exit 2): result FAIL, the reason and the append's own error reach the operator, and the review file is neither recorded as a refutation nor left unmanifested" {
  # Task 14 review: refute.sh's append used lib.sh's die (exit 1), and gates.sh reads
  # refuter exit 1 as REFUTED with the review file as the fail_log — a STANDS review whose
  # manifest line failed was recorded as a refutation, and the append's stderr was swallowed
  # (gates.sh prints the refuter's message only for codes other than 1). Every other
  # cannot-certify path in refute.sh is an explicit exit 2 so that only a real REFUTED is 1.
  install_refuter
  mkdir -p "$BATS_TEST_TMPDIR/bin7"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "VERDICT: STANDS\\n"\n' > "$BATS_TEST_TMPDIR/bin7/claude"; chmod +x "$BATS_TEST_TMPDIR/bin7/claude"
  mv "$DAEDALUS_HOME/core/manifest-append.py" "$DAEDALUS_HOME/core/manifest-append.real.py"
  cat > "$DAEDALUS_HOME/core/manifest-append.py" <<'PY'
#!/usr/bin/env python3
import os, subprocess, sys
if any(a.endswith("-review.md") for a in sys.argv[1:]):
    sys.stderr.write("simulated append failure\n"); sys.exit(1)
sys.exit(subprocess.call([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "manifest-append.real.py")] + sys.argv[1:]))
PY
  commit_core       # the stand-in is this fixture's distribution code; the launcher refuses a modified core/
  git_target
  write_config "  - true" "  refute: true"
  PATH="$BATS_TEST_TMPDIR/bin7:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ -n "$id" ] || { echo "no run-id in output: $output"; return 1; }
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  case "$output" in *"daedalus: log: /"*) echo "a failed append was recorded as a refutation (the review path is the fail_log): $output"; return 1 ;; esac
  case "$output" in *"cannot append the review file to the evidence manifest"*) : ;; *) echo "the reason must be the fail_log: $output"; return 1 ;; esac
  case "$output" in *"simulated append failure"*) : ;; *) echo "the append's own error must reach the operator: $output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ] || { echo "an unmanifested review file was left under vault/evidence"; return 1; }
  ! grep -q -- "-review.md" "$DAEDALUS_HOME/vault/evidence/.manifest"
}

# promote_run_fixture — what core/promote.sh hands gates.sh: a merged tree under
# state/promote/<id>/thing (a git checkout, so the fingerprint is real), the promotion's
# context.json, the resolution machinery DAEDALUS_TARGET_OVERRIDE goes through, and a
# claude on PATH that leaves a mark if anything runs it.
promote_run_fixture() {
  cp "$SRC/leaselib.py" "$SRC/verifylib.py" "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  PID=02-20260928-120000-abc; PT="$DAEDALUS_HOME/state/promote/$PID/thing"
  git init -q -b main "$PT"; printf 'm\n' > "$PT/m.txt"; git -C "$PT" add -A; git -C "$PT" -c user.email=t@x -c user.name=t commit -q -m merged
  printf '{"promote_id":"%s","lease":"02","repo":"thing","trunk_sha_at_prepare":"aaaaaaa","merge_sha":"%s","nested":{}}' \
    "$PID" "$(git -C "$PT" rev-parse HEAD)" > "$DAEDALUS_HOME/state/promote/$PID/context.json"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ntouch "%s/claude-ran"\necho "VERDICT: STANDS"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/claude"; chmod +x "$BATS_TEST_TMPDIR/bin/claude"
}

@test "--promote: run.json, started and final, carries the promotion — id, shas, repo, nested, the promoted window as lease, tree promote-scratch, refuter deferred-to-promote and no reason field; the summary says the reviewer runs on the merged diff; nothing runs a reviewer, even with verify.refute on" {
  write_config "  - true" "  refute: true"
  promote_run_fixture
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rid="$(printf '%s\n' "$output" | tail -1)"
  python3 - "$DAEDALUS_HOME/state/evidence/$rid/run.json" "$(git -C "$PT" rev-parse HEAD)" "$PID" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["result"] == "PASS" and r["promote_id"] == sys.argv[3] and r["lease"] == "02", r
assert r["merge_sha"] == sys.argv[2] and r["trunk_sha_at_prepare"] == "aaaaaaa" and r["nested"] == {} and r["repo"] == "thing", r
assert r["tree"] == "promote-scratch" and r["refuter"] == "deferred-to-promote", r
assert not [k for k in r if "reason" in k], sorted(r)
PY
  grep -qxF 'Reviewer: runs on the merged diff in this promotion' "$DAEDALUS_HOME/vault/evidence/$rid.md"
  ! grep -qi 'reviewer.*off' "$DAEDALUS_HOME/vault/evidence/$rid.md"
  [ ! -e "$BATS_TEST_TMPDIR/claude-ran" ]
}

@test "--no-refute without --promote, a --promote with no context.json, and a --promote whose tree is not under state/promote/<id>/ all die before any run exists" {
  write_config "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute; [ "$status" -ne 0 ]
  case "$output" in *"--no-refute is only for a promotion (--promote <id>)"*) : ;; *) echo "$output"; return 1 ;; esac
  promote_run_fixture
  run env DAEDALUS_TARGET_OVERRIDE="$PT" bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote 02-nope
  [ "$status" -ne 0 ]; case "$output" in *"no state/promote/02-nope/context.json"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -ne 0 ]; case "$output" in *"DAEDALUS_TARGET_OVERRIDE must point under state/promote/$PID/"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/evidence" ] || [ -z "$(ls -A "$DAEDALUS_HOME/state/evidence")" ]
}

@test "--promote with a context.json that will not parse, is not an object, names another promotion, names no two-digit window, or lacks a merge or trunk commit dies in plain language before any run exists — never a PASS with no run.json" {
  write_config "  - true"
  promote_run_fixture
  ctx="$DAEDALUS_HOME/state/promote/$PID/context.json"; good="$(cat "$ctx")"
  bad() {  # bad <context.json text> <expected words>
    printf '%s' "$1" > "$ctx"
    run env DAEDALUS_TARGET_OVERRIDE="$PT" bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
    [ "$status" -ne 0 ] || { echo "accepted: $1 -> $output"; return 1; }
    case "$output" in *"$2"*) : ;; *) echo "wrong reason for $1: $output"; return 1 ;; esac
    case "$output" in *"all gates passed"*|*Traceback*) echo "leaked: $output"; return 1 ;; esac
    [ ! -d "$DAEDALUS_HOME/state/evidence" ] || [ -z "$(ls -A "$DAEDALUS_HOME/state/evidence")" ] || { echo "a run exists after $1"; return 1; }
    [ ! -d "$DAEDALUS_HOME/vault/evidence" ] || [ -z "$(ls -A "$DAEDALUS_HOME/vault/evidence")" ] || { echo "a vault summary exists after $1"; return 1; }
  }
  bad '{not json' "cannot be read as JSON"
  bad '[]' "is not a JSON object"
  bad "$(printf '%s' "$good" | sed 's/"promote_id":"[^"]*"/"promote_id":"02-other"/')" "names promotion 02-other, not $PID"
  bad "$(printf '%s' "$good" | sed 's/"lease":"02"/"lease":"alias"/')" "no two-digit window number"
  bad "$(printf '%s' "$good" | sed 's/"lease":"02"/"lease":2/')" "no two-digit window number"
  bad "$(printf '%s' "$good" | sed 's/"merge_sha":"[^"]*"/"merge_sha":""/')" "no merge_sha"
  bad "$(printf '%s' "$good" | sed 's/"trunk_sha_at_prepare":"[^"]*",//')" "no trunk_sha_at_prepare"
  printf '%s' "$good" > "$ctx"
  run env DAEDALUS_TARGET_OVERRIDE="$PT" bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -eq 0 ] || { echo "positive control failed: $output"; return 1; }
  [ -f "$DAEDALUS_HOME/state/evidence/$(printf '%s\n' "$output" | tail -1)/run.json" ]
}

@test "refute.sh --verdict-of reads a review with the grammar the run uses: STANDS 0, REFUTED 1, no verdict line 2 — dressing allowed, an echoed instruction line matches neither" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$1"; }
  printf 'F1 — nothing.\n**VERDICT**: STANDS\n' > "$f"; vo "$f"; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  printf '> VERDICT: **REFUTED**\n' > "$f"; vo "$f"; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  printf 'End with a line VERDICT: REFUTED or VERDICT: STANDS.\n' > "$f"; vo "$f"; [ "$status" -eq 2 ]; [ "$output" = NONE ]
  vo "$BATS_TEST_TMPDIR/none.md"; [ "$status" -eq 2 ]
}

# --- the refuter's bar: labelled findings, the verdict computed from the labels (2026-10-19) -----------------

# labelled <file> <reviewer-verdict> <heading-tail>... — a review with one "### F<n> — f.py:<n> — <tail>" heading per
# tail, each with its body lines, then the reviewer's own verdict line.
labelled() {
  local f="$1" v="$2" n=0 t; shift 2
  : > "$f"
  for t in "$@"; do
    n=$((n + 1))
    printf '### F%s — core/x.py:%s — %s\nWhat is wrong: something.\nInput: why.\nHow to confirm: read it.\n\n' "$n" "$n" "$t" >> "$f"
  done
  printf 'Correctness: WEAK (F1)\n\nVERDICT: %s\n' "$v" >> "$f"
}

@test "the verdict is computed from the finding labels: only in-scope observed or plausible HIGH/MEDIUM findings, or an observed HIGH, refute; the rest are listed, not counted" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$f"; }
  # Only hypothetical findings, even HIGH and in scope, and the reviewer said REFUTED: STANDS, each one listed.
  labelled "$f" REFUTED "hypothetical — in scope — HIGH" "hypothetical — in scope — MEDIUM"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  printf '%s\n' "$stderr" | grep -q 'F1.*hypothetical' || { echo "stderr: $stderr"; return 1; }
  printf '%s\n' "$stderr" | grep -q 'F2.*hypothetical'
  printf '%s\n' "$stderr" | grep -qi 'not counted'
  # One in-scope plausible MEDIUM refutes.
  labelled "$f" STANDS "hypothetical — in scope — HIGH" "plausible — in scope — MEDIUM"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  printf '%s\n' "$stderr" | grep -q 'F2'
  # An out-of-scope plausible HIGH is listed and does not refute.
  labelled "$f" REFUTED "plausible — out of scope — HIGH"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  printf '%s\n' "$stderr" | grep -q 'F1.*out of scope'
  # An observed HIGH refutes on its own, whatever its scope label.
  labelled "$f" STANDS "observed — out of scope — HIGH"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  labelled "$f" STANDS "observed — in scope — HIGH"
  vo; [ "$status" -eq 1 ]
  # A LOW finding never refutes, even observed and in scope (a missing scope section is reported as one).
  labelled "$f" REFUTED "observed — in scope — LOW"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  # Dressing: bold, en dash or hyphen separators, 'in-scope', any order of the three labels.
  printf '## **F1** - core/x.py:3 - MEDIUM - in-scope - Plausible\nWhat is wrong: x.\n\n**VERDICT**: STANDS\n' > "$f"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
}

@test "a labelled review fails closed: a finding with a missing or unknown label, or no verdict line, cannot be certified" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$f"; }
  # One finding labelled, one with no standing: malformed, never STANDS.
  labelled "$f" STANDS "hypothetical — in scope — LOW" "in scope — HIGH"
  vo; [ "$status" -eq 2 ]; [ "$output" = NONE ]
  printf '%s\n' "$stderr" | grep -q 'F2'
  # No scope label.
  labelled "$f" STANDS "observed — HIGH"
  vo; [ "$status" -eq 2 ]
  # No severity.
  labelled "$f" STANDS "plausible — in scope"
  vo; [ "$status" -eq 2 ]
  # Two standings on one finding.
  labelled "$f" STANDS "plausible — hypothetical — in scope — HIGH"
  vo; [ "$status" -eq 2 ]
  # Labelled findings and no verdict line: a truncated review.
  labelled "$f" STANDS "hypothetical — in scope — LOW"; sed -i.bak '/VERDICT/d' "$f"
  vo; [ "$status" -eq 2 ]; [ "$output" = NONE ]
  # Unlabelled findings (an older review, promote's re-read of it): the reviewer's own verdict, as before.
  printf '### F1 — core/x.py:1 — LOW\nWhat is wrong: x.\n\nVERDICT: REFUTED\n' > "$f"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  printf '### F1 — core/x.py:1 — HIGH\nWhat is wrong: x.\n\nVERDICT: STANDS\n' > "$f"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
}

@test "the review prompt asks for the labels: standing (observed, plausible, hypothetical) and scope on every finding" {
  install_refuter
  bin="$BATS_TEST_TMPDIR/binp"; mkdir -p "$bin"; recording_stub "$bin"
  git_target
  write_config "  - true" "  refute: true"
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for needle in observed plausible hypothetical 'in scope' 'out of scope' 'VERDICT: REFUTED or VERDICT: STANDS' \
                'reach: user' 'reach: routine' 'reach: none' 'Action: line' live-only 'backlog candidate' \
                "This is the branch's first full review: report every defect you find, across all of your charter's dimensions, rather than stopping once something refutes."; do
    grep -qF -- "$needle" "$bin/stdin" || { echo "prompt lacks: $needle"; return 1; }
  done
}

@test "review 2026-10-19: a finding under a level-5 heading or in bold is read; a new run never falls back to the reviewer's word over an unlabelled finding; a rubric FAIL with nothing counted behind it is named as set aside" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$f"; }
  printf '##### F1 — x:1 — observed — in scope — HIGH\nW.\n\nVERDICT: STANDS\n' > "$f"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  printf '**F1 — x:1 — observed — in scope — HIGH**\nW.\n\nVERDICT: STANDS\n' > "$f"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  # A rubric FAIL resting on a LOW finding: STANDS, and the set-aside FAIL is said.
  printf '### F1 — x:1 — observed — in scope — LOW\nW.\n\nTest honesty: FAIL (F1)\n\nVERDICT: REFUTED\n' > "$f"
  vo; [ "$status" -eq 0 ]; printf '%s\n' "$stderr" | grep -q 'rubric FAIL on Test honesty set aside'
  # --counts-of: the real findings by severity and how many were set aside.
  printf '### F1 — x:1 — hypothetical — in scope — HIGH\n\n### F2 — x:2 — plausible — in scope — MEDIUM\n\n### F3 — x:3 — observed — out of scope — HIGH\n\nVERDICT: REFUTED\n' > "$f"
  run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --counts-of "$f"
  [ "$status" -eq 0 ]
  [ "$output" = '{"high": 1, "medium": 1, "low": 0, "set_aside": 1}' ] || { echo "$output"; return 1; }
}

# --- reach (v0.12.4): who meets a finding decides whether it refutes ----------------------------------------------

@test "reach: an in-scope observed or plausible HIGH or MEDIUM refutes only with reach user or routine, or a data or trust flag; an observed HIGH refutes at any reach; the rest are backlog candidates" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$f"; }
  # An edge case nothing ordinary meets: STANDS, listed as a backlog candidate with its labels.
  labelled "$f" REFUTED "plausible — in scope — MEDIUM — reach: none"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  printf '%s\n' "$stderr" | grep -q '1 backlog candidate, not counted' || { echo "stderr: $stderr"; return 1; }
  printf '%s\n' "$stderr" | grep -q 'F1 MEDIUM, plausible, in scope, reach: none'
  # The same finding with an ordinary action or a routine path behind it refutes.
  labelled "$f" STANDS "plausible — in scope — MEDIUM — reach: user"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  labelled "$f" STANDS "observed — in scope — HIGH — reach: routine"
  vo; [ "$status" -eq 1 ]
  labelled "$f" STANDS "plausible — in scope — MEDIUM — reach: routine"
  vo; [ "$status" -eq 1 ]
  # A data or trust flag stands in for reach.
  labelled "$f" STANDS "plausible — in scope — MEDIUM — reach: none — data"
  vo; [ "$status" -eq 1 ]
  labelled "$f" STANDS "plausible — in scope — HIGH — reach: none — trust"
  vo; [ "$status" -eq 1 ]
  # An observed HIGH refutes at any reach, in scope or not.
  labelled "$f" STANDS "observed — out of scope — HIGH — reach: none"
  vo; [ "$status" -eq 1 ]
  # Reach never lifts what the 2026-10-19 bar set aside: hypothetical, out of scope or LOW.
  labelled "$f" REFUTED "hypothetical — in scope — HIGH — reach: user" "plausible — out of scope — MEDIUM — reach: user" "observed — in scope — LOW — reach: user"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  printf '%s\n' "$stderr" | grep -q '3 backlog candidates, not counted'
  # A regression refutes at reach none.
  labelled "$f" STANDS "hypothetical — in scope — LOW — reach: none — regressed L1"
  vo; [ "$status" -eq 1 ]
  # Dressing: reach without the colon, bold, any position; flags joined by a comma.
  printf '### **F1** — x:1 — Reach user — MEDIUM — plausible — in scope\nW.\n\nVERDICT: STANDS\n' > "$f"
  vo; [ "$status" -eq 1 ] || { echo "$output $stderr"; return 1; }
  printf '### F1 — x:1 — plausible — in scope — MEDIUM — reach: none — data, trust\nW.\n\nVERDICT: STANDS\n' > "$f"
  vo; [ "$status" -eq 1 ]
}

@test "reach: live-only never counts and never passes — it is named as a live check; --counts-of gives counted findings, backlog candidates and live checks" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$f"; }
  labelled "$f" REFUTED "plausible — in scope — HIGH — reach: routine — live-only"
  vo; [ "$status" -eq 0 ]; [ "$output" = STANDS ]
  printf '%s\n' "$stderr" | grep -q '1 live check, not counted — only a live run can settle it: F1 HIGH, plausible, in scope, reach: routine, live-only' \
    || { echo "stderr: $stderr"; return 1; }
  printf '### F1 — job.sh:4 — plausible — in scope — HIGH — reach: routine — live-only\nWhat is wrong: the scheduled job may not reach the service.\n\n### F2 — x:2 — plausible — in scope — MEDIUM — reach: user\n\n### F3 — x:3 — plausible — in scope — MEDIUM — reach: none\n\nVERDICT: REFUTED\n' > "$f"
  run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --counts-of "$f"
  [ "$status" -eq 0 ]
  python3 -c 'import json, sys; c = json.loads(sys.argv[1]); assert c == {"high": 0, "medium": 1, "low": 0, "backlog": 1, "live": 1,
    "live_checks": ["job.sh:4 \u2014 the scheduled job may not reach the service."]}, c' "$output"
}

@test "reach: a labelled heading without its reach is a labelling failure (NONE); a re-read review with no reach on any heading keeps the 2026-10-19 bar" {
  cp "$SRC/refute.sh" "$DAEDALUS_HOME/core/"; f="$BATS_TEST_TMPDIR/r.md"
  vo() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$f"; }
  # One heading with reach, one without: the review cannot be certified.
  labelled "$f" STANDS "plausible — in scope — MEDIUM — reach: none" "hypothetical — in scope — LOW"
  vo; [ "$status" -eq 2 ]; [ "$output" = NONE ]
  printf '%s\n' "$stderr" | grep -q 'F2 (needs one reach: user, routine or none)' || { echo "stderr: $stderr"; return 1; }
  # Two reaches on one heading.
  labelled "$f" STANDS "plausible — in scope — MEDIUM — reach: none — reach: user"
  vo; [ "$status" -eq 2 ]
  # No reach anywhere, re-read: the bar it was written under — an in-scope plausible MEDIUM refutes.
  labelled "$f" STANDS "plausible — in scope — MEDIUM"
  vo; [ "$status" -eq 1 ]; [ "$output" = REFUTED ]
  run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" --counts-of "$f"
  [ "$output" = '{"high": 0, "medium": 1, "low": 0, "set_aside": 0}' ] || { echo "$output"; return 1; }
}

@test "reach: a new run's review whose headings carry no reach is uncertifiable, even with every other label" {
  install_refuter
  bin="$BATS_TEST_TMPDIR/binreach"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '### F1 — core/x.py:1 — plausible — in scope — MEDIUM\nWhat is wrong: x.\n\nVERDICT: STANDS\n'
STUB
  chmod +x "$bin/claude"
  git_target
  write_config "  - true" "  refute: true"
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'needs one reach: user, routine or none' || { echo "$output"; return 1; }
}

@test "a new run's review with an unlabelled finding heading is uncertifiable even when the reviewer says STANDS" {
  install_refuter
  bin="$BATS_TEST_TMPDIR/binu"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '##### F1 — core/x.py:1 — HIGH\nWhat is wrong: x.\n\nVERDICT: STANDS\n'
STUB
  chmod +x "$bin/claude"
  git_target
  write_config "  - true" "  refute: true"
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'without their labels' || { echo "$output"; return 1; }
}

# lease_for <nn> <session> [promoted-count] — a lease file this session holds, so gates.sh's my-lease names it.
lease_for() {
  mkdir -p "$DAEDALUS_HOME/state/leases"
  python3 - "$DAEDALUS_HOME/state/leases/$1.json" "$2" "${3:-0}" <<'PY'
import json, sys
out, sid, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
json.dump({"lease": out.rsplit("/", 1)[1][:2], "session_id": sid, "created": "2026-10-19T09:00:00",
           "promoted": ["p%d" % i for i in range(n)], "branch": "lease/03"}, open(out, "w"))
PY
}

@test "the second refutation of a window's branch prints the operator's three choices; the first does not; a promote resets the count" {
  install_refuter
  bin="$BATS_TEST_TMPDIR/binr"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '### F1 — core/x.py:1 — observed — in scope — HIGH — reach: user\nWhat is wrong: x.\n\nVERDICT: REFUTED\n'
STUB
  chmod +x "$bin/claude"
  git_target
  write_config "  - true" "  refute: true"
  export DAEDALUS_SESSION_ID=sess-r
  lease_for 03 sess-r
  # A leased session's gates run in its window's checkout.
  mkdir -p "$DAEDALUS_HOME/worktrees/03"; cp -R "$DAEDALUS_HOME/target/thing" "$DAEDALUS_HOME/worktrees/03/thing"
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'another round' && { echo "choices after the first refutation: $output"; return 1; }
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'refuted 2 times' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qi 'another round'
  printf '%s\n' "$output" | grep -qi 'backlog'
  printf '%s\n' "$output" | grep -q -- '--skip-review'
  # The window promoted: its lease records one more promotion, and the count starts again.
  lease_for 03 sess-r 1
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qi 'another round' && { echo "choices right after a promote: $output"; return 1; }
  # Released and the number taken again: a new lease (a new created time) starts again too.
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  printf '%s\n' "$output" | grep -q 'refuted 2 times'
  python3 - "$DAEDALUS_HOME/state/leases/03.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["created"] = "2026-10-19T15:00:00"; json.dump(d, open(sys.argv[1], "w"))
PY
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  printf '%s\n' "$output" | grep -qi 'another round' && { echo "choices on a new lease: $output"; return 1; }
  true
}

@test "a STANDS with findings it did not count says so in one line, naming the review file" {
  install_refuter
  bin="$BATS_TEST_TMPDIR/bins"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '### F1 — core/x.py:1 — hypothetical — in scope — HIGH — reach: user\nWhat is wrong: x.\n\nVERDICT: REFUTED\n'
STUB
  chmod +x "$bin/claude"
  git_target
  write_config "  - true" "  refute: true"
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(grep -c '"result": "PASS"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  printf '%s\n' "$output" | grep -q "1 backlog candidate, not counted.*$id-review.md" || { echo "$output"; return 1; }
}

# --- gates_setup: commands that prepare the tree under test before the gates (2026-10-14) ---------

# write_config_setup <setup-lines> <gate-lines> — like write_config, with a gates_setup: list.
write_config_setup() {
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: https://example.com/thing.git
  branch: main
gates_setup:
$1
gates:
$2
verify:
  refute: false
  refute_off_reason: bats fixture — a real claude must never be invoked in tests
EOF
}
# git_thing [ignore-line] — the fixture target as a committed git repo (a real fingerprint).
git_thing() {
  cp "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$DAEDALUS_HOME/target/thing/.gitignore"
  git init -q -b main "$DAEDALUS_HOME/target/thing"; git -C "$DAEDALUS_HOME/target/thing" add -A
  git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m i
}

@test "gates_setup: the steps run in the target, in order, before the gates; each is logged, recorded in run.json and the summary, and manifested; a gate that needs their output passes; git-ignored output leaves the run PASS with a real fingerprint" {
  git_thing "build/"
  write_config_setup "  - mkdir -p build && printf one > build/x
  - printf two >> build/x" "  - test \"\$(cat build/x)\" = onetwo"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(printf '%s\n' "$output" | tail -1)"
  R="$DAEDALUS_HOME/state/evidence/$id/run.json"
  [ "$(grep -c '"result": "PASS"' "$R")" -eq 1 ]
  [ "$(grep -c '"fingerprint": "null"' "$R")" -eq 0 ]
  python3 - "$R" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
s = r["setup"]
assert [x["n"] for x in s] == [1, 2] and all(x["exit"] == 0 for x in s), s
assert s[0]["command"].startswith("mkdir -p build") and s[1]["command"].startswith("printf two"), s
assert s[0]["log"].endswith("/setup-1.log") and s[1]["log"].endswith("/setup-2.log"), s
assert "setup_failed" not in r and "invalid_reason" not in r, r
print("ok")
PY
  [ -f "$DAEDALUS_HOME/state/evidence/$id/setup-1.log" ] && [ -f "$DAEDALUS_HOME/state/evidence/$id/setup-2.log" ]
  grep -qF "$DAEDALUS_HOME/state/evidence/$id/setup-1.log" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -qF "$DAEDALUS_HOME/state/evidence/$id/setup-2.log" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -q "setup-1.log" "$DAEDALUS_HOME/vault/evidence/$id.md"
  case "$output" in *"SETUP "*"mkdir -p build"*) : ;; *) echo "no setup line: $output"; return 1 ;; esac
}

@test "gates_setup: a failing step runs no gate; the run is INVALID naming the step; exit non-zero with run-id and log; no citable run-id is printed" {
  git_thing
  # The token is assembled at runtime so it appears only in the step's OUTPUT, never in its
  # command text (the summary shows the operator-authored command, as it does for gates).
  write_config_setup "  - printf SETUP_TOKEN\"_abc\"; exit 3" "  - touch gate-ran"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/target/thing/gate-ran" ]
  case "$output" in *"setup step 1 "*"exit 3"*"no gate ran"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"run-id: "*"log: "*) : ;; *) echo "$output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(printf '%s\n' "$output" | tail -1)" != "$id" ]
  R="$DAEDALUS_HOME/state/evidence/$id/run.json"
  [ "$(grep -c '"result": "INVALID"' "$R")" -eq 1 ]
  [ "$(grep -c '"setup_failed": 1' "$R")" -eq 1 ]
  [ "$(grep -c '"exit": 3' "$R")" -eq 1 ]
  [ "$(grep -c '"gates": \[\]' "$R")" -eq 1 ]
  [ ! -e "$DAEDALUS_HOME/state/evidence/$id/gate-1.log" ]
  grep -q "^result: INVALID" "$DAEDALUS_HOME/vault/evidence/$id.md"
  [ "$(grep -c SETUP_TOKEN_abc "$DAEDALUS_HOME/state/evidence/$id/setup-1.log")" -eq 1 ]
  [ "$(grep -c SETUP_TOKEN_abc "$DAEDALUS_HOME/vault/evidence/$id.md")" -eq 0 ]
}

@test "gates_setup: a step whose output git can see makes the run INVALID before any gate, saying the output must be ignored" {
  git_thing
  write_config_setup "  - printf x > build.txt" "  - touch gate-ran"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/target/thing/gate-ran" ]
  case "$output" in *"changed the tree under test"*"ignored by git"*) : ;; *) echo "$output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "INVALID"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ "$(grep -c '"invalid_reason"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a gate that exits 127 is said to be unable to start, naming gates_setup as the remedy — still a FAIL" {
  git_thing
  write_config "  - ./no-such-tool"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"gate 1 could not start (exit 127"*"gates_setup"*) : ;; *) echo "$output"; return 1 ;; esac
  id="$(printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
}

@test "a gates_setup step containing a tab dies before creating a run directory — validation before side effects" {
  write_config_setup "  - printf 'a	b'" "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"gates_setup"*"tab"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/evidence" ] || [ -z "$(ls "$DAEDALUS_HOME/state/evidence")" ]
}

# PROP-037 (a field deployment, 2026-10-24): `core/lease.sh update <NN> --criteria <file>` was read only by
# promote's review (refute.sh --mode promote, through review-inputs.py). A branch run handed refute.sh
# only $GATES_CRITERIA, so a window that used the lease form had its review judged against "evident
# intent" with a LOW finding for the missing Scope — every time, not intermittently.
@test "a window's criteria file reaches the branch review: without GATES_CRITERIA the lease's file is rendered and named; GATES_CRITERIA still wins; a missing file is named once and the review runs without; an unleased session is unchanged" {
  install_refuter
  recording_stub "$BATS_TEST_TMPDIR/bin13"
  git_target
  # session sB is bound to window 02, so target_path resolves to its worktree: give it one, with an edit to review
  git -C "$DAEDALUS_HOME/target/thing" worktree add -q "$DAEDALUS_HOME/worktrees/02/thing" -b lease/02
  printf 'edited in the window\n' >> "$DAEDALUS_HOME/worktrees/02/thing/marker.txt"
  mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/.claude/scratch"
  printf 'AC-7: the window criteria must reach the review.\n' > "$DAEDALUS_HOME/.claude/scratch/crit.md"
  # the path as lease.sh update stores it — relative, resolved against the home like promote's review does
  printf '{"lease":"02","session_id":"sB","worktree":"worktrees/02","criteria":".claude/scratch/crit.md"}' > "$DAEDALUS_HOME/state/leases/02.json"
  write_config "  - true" "  refute: true"
  stdin="$BATS_TEST_TMPDIR/bin13/stdin"
  H="$(cd "$DAEDALUS_HOME" && pwd -P)"   # leaselib resolves the home; the fixture lives under a symlinked /var
  DAEDALUS_SESSION_ID=sB PATH="$BATS_TEST_TMPDIR/bin13:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -cF 'AC-7: the window criteria must reach the review.' "$stdin")" -eq 1 ]
  [ "$(grep -cF '(none supplied)' "$stdin")" -eq 0 ]
  case "$output" in *"review: criteria from window 02's file $H/.claude/scratch/crit.md"*) : ;; *) echo "no criteria line: $output"; return 1 ;; esac
  # An explicit GATES_CRITERIA still wins over the lease's file, and the lease's file is not mentioned.
  rm -rf "$DAEDALUS_HOME/state/evidence" "$DAEDALUS_HOME/vault/evidence"
  printf 'AC-8: the explicit file.\n' > "$BATS_TEST_TMPDIR/explicit.md"
  DAEDALUS_SESSION_ID=sB GATES_CRITERIA="$BATS_TEST_TMPDIR/explicit.md" PATH="$BATS_TEST_TMPDIR/bin13:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -cF 'AC-8: the explicit file.' "$stdin")" -eq 1 ]
  [ "$(grep -cF 'AC-7' "$stdin")" -eq 0 ]
  case "$output" in *"criteria from window"*) echo "the lease's file was named although GATES_CRITERIA was set: $output"; return 1 ;; *) : ;; esac
  # The lease names a file that is not there: said in one line, and the review runs against evident intent.
  rm -rf "$DAEDALUS_HOME/state/evidence" "$DAEDALUS_HOME/vault/evidence" "$DAEDALUS_HOME/.claude/scratch/crit.md"
  DAEDALUS_SESSION_ID=sB PATH="$BATS_TEST_TMPDIR/bin13:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -cF '(none supplied)' "$stdin")" -eq 1 ]
  case "$output" in *"window 02's criteria file $H/.claude/scratch/crit.md is missing"*) : ;; *) echo "no missing-file line: $output"; return 1 ;; esac
  # Positive control: a deployment with no windows at all (no state/leases/) renders (none supplied) and
  # says nothing about criteria. (With leases present, a session holding no window is refused outright.)
  rm -rf "$DAEDALUS_HOME/state/evidence" "$DAEDALUS_HOME/vault/evidence" "$DAEDALUS_HOME/state/leases"
  PATH="$BATS_TEST_TMPDIR/bin13:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep -cF '(none supplied)' "$stdin")" -eq 1 ]
  case "$output" in *"criteria"*) echo "an unleased run spoke of criteria: $output"; return 1 ;; *) : ;; esac
}

# --- v0.12.8 (2026-10-21): a gate PASS is reused for an identical tree; a flaky failure re-runs its failures ------

# reuse_fixture — what reuse needs: a real fingerprint (a git target, fingerprint.sh) and a recorded core/ tree (a
# home that is a git checkout with core/ committed and distcheck.py beside gates.sh). install_refuter provides both;
# the fixture config keeps the reviewer off. Every gate below appends to $RAN, outside the target, so counting its
# lines counts the gate commands that really ran without touching the fingerprinted tree.
reuse_fixture() {
  install_refuter
  git_target
  RAN="$BATS_TEST_TMPDIR/gate-ran"
}
ran() { if [ -f "$RAN" ]; then wc -l < "$RAN" | tr -d ' '; else printf '0\n'; fi; }
last_id() { printf '%s\n' "$output" | tail -1; }
failed_id() { printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1; }
rj() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else d[int(k)]
print(d)' "$DAEDALUS_HOME/state/evidence/$1/run.json" "$2"; }

@test "2026-10-21 (the seventh full run): an identical tree and gate definition is PASS by reuse — no setup or gate command runs (a gate that would now fail proves it), the record and summary are written and manifested, reused_from names the earlier run" {
  reuse_fixture
  write_config "  - echo ran >> $RAN; test ! -e $BATS_TEST_TMPDIR/now-failing"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  first="$(last_id)"; [ "$(ran)" = 1 ]
  [ "$(rj "$first" core_tree)" != None ] || { echo "the run records no core tree"; return 1; }
  touch "$BATS_TEST_TMPDIR/now-failing"         # the gate would FAIL if it ran again
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  second="$(last_id)"
  [ "$second" != "$first" ]; [ "$(ran)" = 1 ] || { echo "a gate ran on a tree that already passed"; return 1; }
  case "$output" in *"PASS — reused from run $first (same tree, same gates); nothing re-ran."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(rj "$second" result)" = PASS ]; [ "$(rj "$second" reused_from)" = "$first" ]
  [ "$(rj "$second" fingerprint)" = "$(rj "$first" fingerprint)" ]
  [ "$(rj "$second" gates.0.command)" = "$(rj "$first" gates.0.command)" ]
  [ ! -e "$DAEDALUS_HOME/state/evidence/$second/gate-1.log" ]
  grep -qxF "$DAEDALUS_HOME/state/evidence/$second/run.json" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -qxF "$DAEDALUS_HOME/vault/evidence/$second.md" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -qF "PASS — reused from run $first (same tree, same gates); nothing re-ran." "$DAEDALUS_HOME/vault/evidence/$second.md"
  grep -q '^result: PASS$' "$DAEDALUS_HOME/vault/evidence/$second.md"
}

@test "2026-10-21: a changed file, a changed config, a changed or modified core/, and a null fingerprint each run the gates in full" {
  reuse_fixture
  write_config "  - echo ran >> $RAN"
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; [ "$(ran)" = 1 ]
  printf 'one more line\n' >> "$DAEDALUS_HOME/target/thing/marker.txt"
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; [ "$(ran)" = 2 ] || { echo "a changed file reused"; return 1; }
  printf '# a comment\n' >> "$DAEDALUS_HOME/config.yaml"
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; [ "$(ran)" = 3 ] || { echo "a changed config reused"; return 1; }
  printf 'x\n' > "$DAEDALUS_HOME/core/extra.txt"; commit_core
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; [ "$(ran)" = 4 ] || { echo "a changed core/ tree reused"; return 1; }
  printf 'y\n' >> "$DAEDALUS_HOME/core/extra.txt"           # modified on disk, not committed: no core tree to match
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; [ "$(ran)" = 5 ] || { echo "a modified core/ reused"; return 1; }
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; [ "$(ran)" = 6 ] || { echo "a modified core/ matched itself"; return 1; }
  git -C "$DAEDALUS_HOME" checkout -q -- core/extra.txt
  python3 - "$DAEDALUS_HOME/config.yaml" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("  branch: main\n", "  branch: main\n  fingerprint_exclude: ../x\n", 1))
PY
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1; bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null 2>&1
  [ "$(ran)" = 8 ] || { echo "a null fingerprint matched: $(ran)"; return 1; }
}

@test "2026-10-21: an earlier FAIL, INVALID or RUNNING run is never reused, nor a hand-written run.json the manifest does not list" {
  reuse_fixture
  write_config "  - echo ran >> $RAN; test -e $BATS_TEST_TMPDIR/ok"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  [ "$(ran)" = 2 ] || { echo "a FAIL was reused"; return 1; }
  touch "$BATS_TEST_TMPDIR/ok"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ]; pass="$(last_id)"; [ "$(ran)" = 3 ]
  for state in INVALID RUNNING; do
    python3 - "$DAEDALUS_HOME/state/evidence/$pass/run.json" "$state" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["result"] = sys.argv[2]; d["gates_result"] = sys.argv[2]
json.dump(d, open(sys.argv[1], "w"))
PY
    run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ]; pass="$(last_id)"
  done
  [ "$(ran)" = 5 ] || { echo "an INVALID or RUNNING run was reused: $(ran)"; return 1; }
  # A copy of the last PASS under a run id the manifest never named: not evidence gates.sh wrote.
  forged=20990101-000000-abcdef
  mkdir -p "$DAEDALUS_HOME/state/evidence/$forged"
  python3 - "$DAEDALUS_HOME/state/evidence/$pass/run.json" "$DAEDALUS_HOME/state/evidence/$forged/run.json" "$forged" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["run_id"] = sys.argv[3]; json.dump(d, open(sys.argv[2], "w"))
e = json.load(open(sys.argv[1])); e["result"] = e["gates_result"] = "INVALID"; json.dump(e, open(sys.argv[1], "w"))
PY
  cp "$DAEDALUS_HOME/vault/evidence/$pass.md" "$DAEDALUS_HOME/vault/evidence/$forged.md"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ]
  [ "$(ran)" = 6 ] || { echo "an unmanifested run.json was reused"; return 1; }
  [ "$(rj "$(last_id)" reused_from)" = None ]
}

@test "2026-10-21: a run whose review REFUTED it still passed its gates — the same tree reuses them and the reviewer runs again" {
  reuse_fixture
  bin="$BATS_TEST_TMPDIR/binx"; mkdir -p "$bin"
  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
echo x >> "$REVIEWS"
printf '### F1 — marker.txt:1 — observed — in scope — HIGH — reach: user\nWhat is wrong: x.\n\nVERDICT: REFUTED\n'
STUB
  chmod +x "$bin/claude"
  export REVIEWS="$BATS_TEST_TMPDIR/reviews"
  write_config "  - echo ran >> $RAN" "  refute: true"
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  first="$(failed_id)"
  [ "$(rj "$first" result)" = FAIL ]; [ "$(rj "$first" gates_result)" = PASS ]
  PATH="$bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  second="$(failed_id)"
  [ "$(ran)" = 1 ] || { echo "the gates ran again on the refuted tree"; return 1; }
  [ "$(rj "$second" reused_from)" = "$first" ]
  [ "$(wc -l < "$REVIEWS" | tr -d ' ')" = 2 ] || { echo "the reviewer did not run on the reused run"; return 1; }
}

# write_config_rerun <gate-lines> <rerun-lines> — gates and their gates_rerun_failed commands; the reviewer off.
write_config_rerun() {
  { printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\ngates:\n%s\ngates_rerun_failed:\n%s\n' "$1" "$2"
    printf 'verify:\n  refute: false\n  refute_off_reason: bats fixture — a real claude must never be invoked in tests\n'
  } > "$DAEDALUS_HOME/config.yaml"
}

@test "2026-10-21 (two flaky restarts): a gate that fails and passes its rerun is PASS after a rerun — both logs kept and manifested, the summary names it" {
  reuse_fixture
  write_config_rerun "  - ls first-run-no-such-file
  - true" "  - echo rerun >> $RAN; echo rerun-log
  - \"\""
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(last_id)"; [ "$(ran)" = 1 ]
  [ "$(rj "$id" result)" = PASS ]; [ "$(rj "$id" gates.0.exit)" = 0 ]
  [ "$(rj "$id" gates.0.rerun.first_exit)" = 1 ]
  first_log="$(rj "$id" gates.0.rerun.first_log)"; rerun_log="$(rj "$id" gates.0.log)"
  [ "$first_log" != "$rerun_log" ]
  grep -q first-run-no-such-file "$first_log"; grep -q rerun-log "$rerun_log"
  grep -qxF "$first_log" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -qxF "$rerun_log" "$DAEDALUS_HOME/vault/evidence/.manifest"
  grep -qF "gate 1 passed after re-running its failures (first run log: \`$first_log\`)" "$DAEDALUS_HOME/vault/evidence/$id.md"
  case "$output" in *"gate 1 passed after re-running its failures"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "2026-10-21: a rerun that fails leaves the gate FAIL; a tree changed between the gate and its rerun is FAIL with the reason, the rerun never started; no gates_rerun_failed key changes nothing" {
  reuse_fixture
  write_config_rerun "  - exit 1" "  - echo rerun >> $RAN; exit 1"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]; [ "$(ran)" = 1 ]
  id="$(failed_id)"
  [ "$(rj "$id" result)" = FAIL ]; [ "$(rj "$id" gates.0.rerun.first_exit)" = 1 ]
  grep -qF "gate 1 failed again when its failures were re-run" "$DAEDALUS_HOME/vault/evidence/$id.md"
  # The failing gate leaves a file git can see; the next gate removes it, so the run ends on the tree it started on.
  write_config_rerun "  - touch left-behind /no-such-dir/x
  - rm -f left-behind" "  - echo rerun >> $RAN"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]; [ "$(ran)" = 1 ] || { echo "the rerun ran on a changed tree"; return 1; }
  id="$(failed_id)"
  [ "$(rj "$id" result)" = FAIL ] || { echo "$output"; return 1; }
  grep -qF "gate 1's failures were not re-run: the tree changed after it failed" "$DAEDALUS_HOME/vault/evidence/$id.md"
  write_config "  - exit 1"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  id="$(failed_id)"
  [ "$(rj "$id" gates.0.exit)" = 1 ]; ! grep -q '"rerun"' "$DAEDALUS_HOME/state/evidence/$id/run.json"
  [ -z "$(ls "$DAEDALUS_HOME/state/evidence/$id" | grep rerun)" ]
}

@test "2026-10-21: gates_rerun_failed with more commands than gates, or a tab in one, dies before creating a run directory" {
  write_config_rerun "  - true" "  - true
  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  case "$output" in *"gates_rerun_failed"*"2"*"1"*) : ;; *) echo "$output"; return 1 ;; esac
  write_config_rerun "  - true" "  - printf 'a	b'"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  case "$output" in *"gates_rerun_failed"*"tab"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/evidence" ] || [ -z "$(ls "$DAEDALUS_HOME/state/evidence")" ]
}

# --- v0.12.8 review revisions (2026-10-22): clean-copy runs, rerun only a whole gate --------------------------------

@test "2026-10-22 (C2): a clean tree runs setup and gates in a fresh scratch checkout of HEAD — a git-ignored file in the worktree is not there; the record says clean-copy and names the commit; the scratch is removed, the logs kept" {
  install_refuter
  git_thing "secret.env"
  printf 'only here\n' > "$DAEDALUS_HOME/target/thing/secret.env"
  write_config_setup "  - pwd > $BATS_TEST_TMPDIR/setup-cwd" "  - pwd > $BATS_TEST_TMPDIR/gate-cwd; test ! -e secret.env"
  run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(printf '%s\n' "$output" | tail -1)"
  where="$(cat "$BATS_TEST_TMPDIR/gate-cwd")"
  [ "$where" = "$(cat "$BATS_TEST_TMPDIR/setup-cwd")" ]
  [ "$where" != "$(cd "$DAEDALUS_HOME/target/thing" && pwd -P)" ] || { echo "the gate ran in the worktree"; return 1; }
  [ ! -e "$where" ] || { echo "the scratch was left behind: $where"; return 1; }
  [ "$(git -C "$DAEDALUS_HOME/target/thing" worktree list | wc -l | tr -d ' ')" = 1 ]
  [ -f "$DAEDALUS_HOME/state/evidence/$id/gate-1.log" ]
  python3 - "$DAEDALUS_HOME/state/evidence/$id/run.json" "$(git -C "$DAEDALUS_HOME/target/thing" rev-parse HEAD)" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["tree"] == "clean-copy" and r["commit"] == sys.argv[2] and r["result"] == "PASS", r
PY
}

@test "2026-10-22 (C2): a dirty tree runs in place as before (tree: worktree), and a later clean-copy run of the same content does not reuse it" {
  install_refuter
  git_thing
  RAN="$BATS_TEST_TMPDIR/gate-ran"
  write_config "  - echo ran >> $RAN; test -e marker.txt"
  printf 'new\n' > "$DAEDALUS_HOME/target/thing/new.txt"          # untracked: the tree is dirty
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tree"])' "$DAEDALUS_HOME/state/evidence/$id/run.json")" = worktree ]
  git -C "$DAEDALUS_HOME/target/thing" add -A; git -C "$DAEDALUS_HOME/target/thing" -c user.email=t@x -c user.name=t commit -q -m new
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(printf '%s\n' "$output" | tail -1)"
  [ "$(wc -l < "$RAN" | tr -d ' ')" = 2 ] || { echo "a clean-copy run reused a worktree run"; return 1; }
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tree"])' "$DAEDALUS_HOME/state/evidence/$id/run.json")" = clean-copy ]
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ]
  [ "$(wc -l < "$RAN" | tr -d ' ')" = 2 ] || { echo "a clean-copy PASS was not reused by the next run"; return 1; }
}

@test "2026-10-22 (M1): a compound gate (&&, ||, ;, |) gets no rerun — a rerun could cover only part of it; a single leading cd is not compound" {
  reuse_fixture
  write_config_rerun "  - true && exit 1" "  - echo rerun >> $RAN"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -ne 0 ]
  [ "$(ran)" = 0 ] || { echo "a compound gate was re-run"; return 1; }
  case "$output" in *"compound"*) : ;; *) echo "$output"; return 1 ;; esac
  write_config_rerun "  - cd . && exit 1" "  - echo rerun >> $RAN"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(ran)" = 1 ]
}

@test "2026-10-22 (L3): a run that reuses one whose gate passed after a rerun says so" {
  reuse_fixture
  write_config_rerun "  - exit 1" "  - true"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  first="$(last_id)"
  run bash "$DAEDALUS_HOME/core/gates.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  second="$(last_id)"; [ "$(rj "$second" reused_from)" = "$first" ]
  grep -qF "gate 1 passed after re-running its failures in run $first" "$DAEDALUS_HOME/vault/evidence/$second.md"
}

# --- v0.12.9 (spec 2026-10-21 §E): quick mode under --promote -------------------------------------------------------
@test "quick mode (v0.12.9): under --promote, GATES_QUICK=1 runs the one targeted command instead of the gates (gates_setup still runs), the record says quick with the command, the summary says the full suite has not run; a later promote run of the same tree does not reuse it; with no command nothing runs and the reason is recorded; without --promote GATES_QUICK is ignored; a tab in the command dies before any run" {
  write_config "  - echo gate-ran >> $BATS_TEST_TMPDIR/ran"
  printf 'gates_setup:\n  - echo setup-ran >> %s\n' "$BATS_TEST_TMPDIR/ran" >> "$DAEDALUS_HOME/config.yaml"
  install_refuter; git_target          # a home that is a git checkout with core/ committed (reuse needs a recorded core tree); a fingerprintable target for the plain run below
  promote_run_fixture                  # copies files install_refuter already committed; state/ is ignored
  GATES_QUICK=1 GATES_QUICK_COMMAND="echo quick-ran >> $BATS_TEST_TMPDIR/ran" DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  q="$(printf '%s\n' "$output" | tail -1)"
  case "$output" in *"quick promote: the targeted command above stood in for the gates; the full suite has not run on this commit yet"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$BATS_TEST_TMPDIR/ran")" = "setup-ran
quick-ran" ] || { cat "$BATS_TEST_TMPDIR/ran"; return 1; }
  python3 - "$DAEDALUS_HOME/state/evidence/$q/run.json" "$BATS_TEST_TMPDIR/ran" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["quick"] == {"command": "echo quick-ran >> %s" % sys.argv[2], "why": None}, r["quick"]
assert r["result"] == "PASS" and r["gates_result"] == "PASS" and r["tree"] == "promote-scratch", r
assert [g["command"] for g in r["gates"]] == ["echo quick-ran >> %s" % sys.argv[2]], r["gates"]
assert "reused_from" not in r and "rerun" not in r["gates"][0], r
PY
  grep -qF "Quick promote: the targeted command stood in for the gates; the full suite has not run on this commit yet." "$DAEDALUS_HOME/vault/evidence/$q.md"
  # the same tree, an ordinary promote run: the quick record stands for nothing, the gate runs
  DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  f="$(printf '%s\n' "$output" | tail -1)"; [ "$f" != "$q" ]
  grep -qxF gate-ran "$BATS_TEST_TMPDIR/ran"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reused_from"))' "$DAEDALUS_HOME/state/evidence/$f/run.json")" = None ]
  # a quick run with no command: nothing runs, the reason is on record; a full PASS on record is reused instead (quick dropped)
  rm -rf "$DAEDALUS_HOME/state/evidence" "$DAEDALUS_HOME/vault/evidence"; : > "$BATS_TEST_TMPDIR/ran"
  GATES_QUICK=1 GATES_QUICK_COMMAND="" GATES_QUICK_WHY="no test file changed" DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  q2="$(printf '%s\n' "$output" | tail -1)"
  case "$output" in *"quick promote: nothing ran (no test file changed); the full suite has not run on this commit yet"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$BATS_TEST_TMPDIR/ran")" = "setup-ran" ]
  [ "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["quick"]["why"], len(r["gates"]), r["result"])' "$DAEDALUS_HOME/state/evidence/$q2/run.json")" = "no test file changed 0 PASS" ]
  grep -qF "Quick promote: nothing ran (no test file changed); the full suite has not run on this commit yet." "$DAEDALUS_HOME/vault/evidence/$q2.md"
  # a full run, then quick again on the same tree: PASS by reuse, no quick key
  DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"; [ "$status" -eq 0 ]
  full="$(printf '%s\n' "$output" | tail -1)"
  GATES_QUICK=1 GATES_QUICK_COMMAND="echo quick-ran >> $BATS_TEST_TMPDIR/ran" DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  q3="$(printf '%s\n' "$output" | tail -1)"
  [ "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("reused_from"), r.get("quick"))' "$DAEDALUS_HOME/state/evidence/$q3/run.json")" = "$full None" ]
  ! grep -q quick-ran "$BATS_TEST_TMPDIR/ran"
  # without --promote the variable means nothing
  rm -rf "$DAEDALUS_HOME/state/evidence" "$DAEDALUS_HOME/vault/evidence"
  GATES_QUICK=1 GATES_QUICK_COMMAND="echo quick-ran >> $BATS_TEST_TMPDIR/ran" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  p="$(printf '%s\n' "$output" | tail -1)"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("quick"))' "$DAEDALUS_HOME/state/evidence/$p/run.json")" = None ]
  ! grep -q quick-ran "$BATS_TEST_TMPDIR/ran"; grep -qxF gate-ran "$BATS_TEST_TMPDIR/ran"
  # a tab in the command: refused before any run exists
  rm -rf "$DAEDALUS_HOME/state/evidence" "$DAEDALUS_HOME/vault/evidence"
  GATES_QUICK=1 GATES_QUICK_COMMAND="$(printf 'echo a\tb')" DAEDALUS_TARGET_OVERRIDE="$PT" run bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID"
  [ "$status" -ne 0 ]; case "$output" in *"GATES_QUICK_COMMAND contains a tab character"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/state/evidence" ] || [ -z "$(ls -A "$DAEDALUS_HOME/state/evidence")" ]
}
