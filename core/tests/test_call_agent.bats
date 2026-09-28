#!/usr/bin/env bats
# The direct-call launcher (spec §8): core/call-agent.sh + core/call_agent.py.
# A fake claude (fixtures/caller/bin/claude) is first on PATH in every test —
# the suite never runs the real CLI.
bats_require_minimum_version 1.5.0
load fixtures/caller/setup.bash
setup() { caller_fixture; }
teardown() { teardown_live; }

# --- configuration and arguments (Task 1) -------------------------------------

@test "a callee home or name on the command line is an unknown flag: exit 2, claude never starts" {
  run bash "$CALL" --callee agent --callee-home /x "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"unrecognized arguments: --callee-home"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --callee agent --callee-name Someone "hello"
  [ "$status" -eq 2 ]
  run bash "$CALL" --callee nobody "hello"
  [ "$status" -eq 2 ]
  [ "$(calls)" -eq 0 ]
}

@test "doctor names every invalid direct_call value as MISSING and turns red" {
  direct_call "callers: Peer" "timeout: ten" "tools: Read,Bash" "max_turns: 0" "capture: maybe"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  [ "$status" -eq 0 ]
  for key in tools max_turns timeout capture; do
    case "$output" in *"MISSING  direct call: direct_call.$key"*) : ;; *) echo "no MISSING line for $key: $output"; return 1 ;; esac
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"MISSING  direct call: direct_call.timeout must be a whole number from 1 to 9999999 (got: ten)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "doctor: no direct_call block prints no direct-call line; a block with no callee is a NOTE naming the two keys; a configured callee is OK; half a callee is MISSING" {
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"direct call:"*) echo "a line for an absent block: $output"; return 1 ;; esac
  direct_call "callers: Peer, Other"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"NOTE     direct call: no callee configured (optional) — core/call-agent.sh --callee agent is refused until direct_call.callee_home and callee_name are set in config.yaml; callers of this Daedalus: Peer, Other"*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i.bak '/^direct_call:/,$d' "$DAEDALUS_HOME/config.yaml"
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "callers: Peer, Other"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"OK       direct call: callee Alpha at $CALLEE; callers of this Daedalus: Peer, Other"*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i.bak '/callee_name: Alpha/d' "$DAEDALUS_HOME/config.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"MISSING  direct call: direct_call.callee_home and direct_call.callee_name are set together or not at all (only callee_home is set)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "config.example.yaml ships the direct_call block commented out, with placeholders; uncommented and pointed at a real home it is valid" {
  ex="$BATS_TEST_DIRNAME/../../config.example.yaml"
  grep -q '^# direct_call:' "$ex"
  run grep -E '^direct_call:' "$ex"; [ "$status" -ne 0 ]
  # comments on their own lines only: cfg does not strip an inline comment
  run grep -E '^#   [a-z_]+: .*[^ ] +#' "$ex"; [ "$status" -ne 0 ] || { echo "inline comment: $output"; return 1; }
  sed -n '/^# direct_call:/,/^$/p' "$ex" | sed 's/^# \{0,1\}//' | grep -v '^ *#' | grep -v '^$' \
    | sed "s|callee_home: .*|callee_home: $CALLEE|; /callee_launcher:/d" >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"OK       direct call: callee "*) : ;; *) echo "$output"; cat "$DAEDALUS_HOME/config.yaml"; return 1 ;; esac
}
