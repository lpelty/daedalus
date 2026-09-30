#!/usr/bin/env bats
# The two-window scenario (spec §11.2). The operator runs it by hand; the suite runs its rehearsal, which plays every
# window through the same hooks and commands a window runs, on a scratch deployment built from fixtures.
bats_require_minimum_version 1.5.0
SCEN="$BATS_TEST_DIRNAME/scenarios/two-clones.sh"
setup() {
  unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_SESSION_ID DAEDALUS_LEASE DIRECT_CALL_ID DAEDALUS_HOME \
        DAEDALUS_CONFIG DAEDALUS_TARGET_OVERRIDE DAEDALUS_PROMOTE_ID TENANT_BANK HINDSIGHT_API_URL
  export TMPDIR="$BATS_TEST_TMPDIR"
}

@test "the two-window scenario, rehearsed: every step's check passes on a scratch deployment built from fixtures, and the scratch is removed afterwards" {
  run bash "$SCEN" --rehearse </dev/null
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" | tail -80; return 1; }
  case "$output" in *"CHECK FAILED"*) printf '%s\n' "$output"; return 1 ;; esac
  case "$output" in *"Rehearsal complete: all "*" checks passed."*) : ;; *) printf '%s\n' "$output" | tail -20; return 1 ;; esac
  for s in "Step 1." "Step 5b." "Step 7b." "Step 7c." "Step 7d." "Step 8b." "Step 11."; do
    case "$output" in *"$s"*) : ;; *) echo "no $s"; return 1 ;; esac
  done
  [ -z "$(ls -d "$BATS_TEST_TMPDIR"/daedalus-scenario.* 2>/dev/null)" ]
}

@test "the scenario refuses to run interactively without a terminal, naming --rehearse, and refuses a scratch directory inside the deployment it was run from; --help says how it is run" {
  run bash "$SCEN" </dev/null
  [ "$status" -eq 2 ]
  case "$output" in *"needs a terminal"*"--rehearse"*) : ;; *) echo "$output"; return 1 ;; esac
  mkdir -p "$BATS_TEST_TMPDIR/dep/tmp"
  run env DAEDALUS_HOME="$BATS_TEST_TMPDIR/dep" TMPDIR="$BATS_TEST_TMPDIR/dep/tmp" bash "$SCEN" --rehearse </dev/null
  [ "$status" -eq 2 ]
  case "$output" in *"is inside the deployment this was run from"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/dep/tmp")" ]
  run bash "$SCEN" --help
  [ "$status" -eq 0 ]
  case "$output" in *"--rehearse"*"--keep"*"--with-memory"*) : ;; *) echo "$output"; return 1 ;; esac
}
