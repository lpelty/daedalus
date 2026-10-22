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
  # exit 2 alone is what an unconfigured --callee agent returns anyway: pin the reason
  case "$output" in *"unrecognized arguments: --callee-name"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --callee nobody "hello"
  [ "$status" -eq 2 ]
  [ "$(calls)" -eq 0 ]
}

@test "doctor names every invalid direct_call value as MISSING and turns red" {
  # The fixture's doctor is already red for unrelated reasons, so "non-zero"
  # proves nothing: pin the problem count the block adds.
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  base="$(printf '%s\n' "$output" | sed -n 's/.* \([0-9][0-9]*\) problem(s) found.*/\1/p')"
  [ -n "$base" ] || { echo "no problem count before the block: $output"; return 1; }
  direct_call "callers: Peer" "timeout: ten" "tools: Read,Bash" "max_turns: 0" "capture: maybe"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  [ "$status" -eq 0 ]
  for key in tools max_turns timeout capture; do
    case "$output" in *"MISSING  direct call: direct_call.$key"*) : ;; *) echo "no MISSING line for $key: $output"; return 1 ;; esac
  done
  run bash "$DAEDALUS_HOME/core/doctor.sh"
  [ "$status" -ne 0 ]
  after="$(printf '%s\n' "$output" | sed -n 's/.* \([0-9][0-9]*\) problem(s) found.*/\1/p')"
  [ "$after" -eq $((base + 4)) ] || { echo "problems $base -> $after, want +4 (tools, max_turns, timeout, capture): $output"; return 1; }
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

@test "config.example.yaml ships the direct_call block and a callee_<key>: block commented out, with placeholders and no legacy callee keys; uncommented and pointed at a real home they are valid" {
  ex="$BATS_TEST_DIRNAME/../../config.example.yaml"
  grep -q '^# direct_call:' "$ex"
  grep -q '^# callee_agentname:' "$ex"
  run grep -E '^(direct_call|callee_[a-z0-9-]+):' "$ex"; [ "$status" -ne 0 ]
  # comments on their own lines only: cfg does not strip an inline comment
  run grep -E '^#   [a-z_]+: .*[^ ] +#' "$ex"; [ "$status" -ne 0 ] || { echo "inline comment: $output"; return 1; }
  # SPEC-011 §4: the legacy one-callee keys are still read, no longer shown
  run grep -E '^#   (callee_home|callee_name|callee_launcher|callee_launcher_args|orientation_marker):' "$ex"
  [ "$status" -ne 0 ] || { echo "legacy key in the example: $output"; return 1; }
  sed -n '/^# direct_call:/,/^$/p' "$ex" | grep -E '^# [a-z_]+:$|^#   [a-z_]+: ' | sed 's/^# \{0,1\}//' \
    | sed "s|^  home: .*|  home: $CALLEE|; s|^  launcher: .*|  launcher: /usr/bin/true|" >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *MISSING*) echo "$output"; cat "$DAEDALUS_HOME/config.yaml"; return 1 ;; esac
  for want in "OK       direct call: callers of this Daedalus: AgentName" \
    "OK       direct call: callee agentname (AgentName) at $CALLEE through its own launcher (with --callee agentname); consult for: the history of this target and why it is built the way it is"; do
    printf '%s\n' "$output" | grep -qxF -- "$want" || { echo "lacks [$want]: $output"; cat "$DAEDALUS_HOME/config.yaml"; return 1; }
  done
}

# --- the engine through --callee self: receipts, the stdout/stderr contract, exit codes, the watchdog (Task 2) ---

@test "a new call needs --callee; a call with no request is refused" {
  run bash "$CALL" "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"--callee agent|self|refuter is required for a new call"*) : ;; *) echo "$output"; return 1 ;; esac
  direct_call "callers: Peer"
  run bash "$CALL" --callee self --caller Peer </dev/null
  [ "$status" -eq 2 ]
  case "$output" in *"a non-empty request is required"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
}

@test "a completed call: stdout is the answer verbatim, stderr is exactly two receipt lines, and launch.json records the call" {
  direct_call "callers: Peer"
  FAKE_ANSWER="the answer, verbatim" FAKE_MARKER="Daedalus session orientation: visitor, x" \
    run --separate-stderr bash "$CALL" --callee self --caller Peer "what is this hook for?"
  [ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
  [ "$output" = "the answer, verbatim" ]
  [ "${#stderr_lines[@]}" -eq 2 ] || { printf '%s\n' "$stderr"; return 1; }
  case "${stderr_lines[0]}" in "Daedalus call "*"; receipt state/direct-calls/"*) : ;; *) echo "$stderr"; return 1 ;; esac
  [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: skipped; exit: 0" ]
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"
  d="$DAEDALUS_HOME/state/direct-calls/$id"
  [ "$(stat -f '%Lp' "$d")" = "700" ]
  python3 - "$d/launch.json" "$id" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); cid = sys.argv[2]
assert r["call_id"] == cid and r["session_id"] == cid, r
assert r["mode"] == "self" and r["caller"] == "Peer" and r["callee"] == "Daedalus", r
assert r["scope"] == "read-only-review" and r["status"] == "completed" and r["exit_code"] == 0, r
assert r["orientation"] is True and r["capture"]["status"] == "skipped", r
for k in ("pid", "command", "cwd", "uid", "user", "lease"):
    assert k in r["invoker"], k
assert len(r["request_sha256"]) == 64, r
a = r["attempts"][0]
assert a["advisory"] is False and a["resumed_by"] is None and a["num_turns"] == 1, a
assert open(a["answer"]).read() == "the answer, verbatim"
PY
}

@test "an answer without the orientation marker is exit 3 (answer still on stdout); claude's own failure passes through with no answer" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 3 ]; [ "$output" = "fake answer" ]
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  FAKE_EXIT=5 run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 5 ]; [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 2 ] || { printf '%s\n' "$stderr"; return 1; }     # the explanation rides on line 2
  case "${stderr_lines[1]}" in "Daedalus orientation: no; capture: skipped; exit: 5 — failed: claude exited 5 (with output). No answer is certified.") : ;; *) echo "$stderr"; return 1 ;; esac
}

@test "orientation is read only from the called session's own SessionStart hook output: the marker quoted in the request, in a tool result, or in another hook's output is exit 3" {
  # The transcript also holds the request and every tool result. The callee
  # can Read core/session-start.py and core/leaselib.py, which carry the
  # marker literal, so a plain search of the transcript would certify a
  # session whose SessionStart never ran.
  direct_call "callers: Peer"
  m="Daedalus session orientation: window 01, /somewhere"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "$m
what does that first line mean?"
  [ "$status" -eq 3 ] || { echo "$status / $stderr"; return 1; }
  [ "$output" = "fake answer" ]
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  FAKE_TOOL_RESULT="$m" run --separate-stderr bash "$CALL" --callee self --caller Peer "explain session-start.py"
  [ "$status" -eq 3 ] || { echo "$status / $stderr"; return 1; }
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  FAKE_MARKER="$m" FAKE_MARKER_EVENT=UserPromptSubmit run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 3 ] || { echo "$status / $stderr"; return 1; }
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  for d in "$DAEDALUS_HOME"/state/direct-calls/*/; do
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["orientation"] is False, r' "$d/launch.json"
  done
}

@test "either record Claude Code keeps for a SessionStart hook verifies orientation" {
  direct_call "callers: Peer"
  for shape in success context; do
    FAKE_MARKER="Daedalus session orientation: visitor, x" FAKE_MARKER_SHAPE=$shape \
      run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
    [ "$status" -eq 0 ] || { echo "$shape: $status / $stderr"; return 1; }
    [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: skipped; exit: 0" ]
  done
}

@test "a resumed call is verified by its own SessionStart, not by the first attempt's record in the same transcript" {
  # The launcher reads only what this attempt appended (attempt() takes the
  # transcript's size before launch); --resume itself is Task 5.
  grep -q '^def resume(' "$DAEDALUS_HOME/core/call_agent.py" || skip "--resume lands in plan 3 Task 5; this test then runs as written"
  direct_call "callers: Peer"
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 0 ] || { echo "$status / $stderr"; return 1; }
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\).*/\1/p')"
  [ -n "$id" ]
  run --separate-stderr bash "$CALL" --resume "$id" "and then?"
  [ "$status" -eq 3 ] || { echo "$status / $output / $stderr"; return 1; }
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --resume "$id" "and then?"
  [ "$status" -eq 0 ] || { echo "$status / $stderr"; return 1; }
}

@test "a hung call is killed at direct_call.timeout — its whole process group — and is exit 124 with the receipt timed-out" {
  direct_call "callers: Peer" "timeout: 2"
  t0="$(date +%s)"
  FAKE_SLEEP=60 run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 124 ]; [ "$(( $(date +%s) - t0 ))" -lt 20 ]
  [ "${#stderr_lines[@]}" -eq 2 ] || { printf '%s\n' "$stderr"; return 1; }
  case "${stderr_lines[1]}" in *"; exit: 124 — timed out after 2s; killed with its process group"*) : ;; *) echo "$stderr"; return 1 ;; esac
  read -r shim child < "$FAKE_CLAUDE_DIR/pids"
  alive() { kill -0 "$1" 2>/dev/null && case "$(ps -o stat= -p "$1" 2>/dev/null)" in Z*) return 1 ;; *) return 0 ;; esac; }
  for _ in $(seq 1 20); do alive "$child" || break; sleep 0.1; done
  if alive "$child"; then kill -9 "$child"; echo "the TERM-ignoring child survived"; return 1; fi
  grep -q '"status": "timed-out"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
}

@test "the caller's environment reaches claude untouched (a Bedrock switch passes through), except the variables that bind a session to a window" {
  direct_call "callers: Peer"
  CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-2 DAEDALUS_LEASE=02 DAEDALUS_SESSION_ID=sX \
    run bash "$CALL" --callee self --caller Peer "hello"
  python3 - "$FAKE_CLAUDE_DIR/1.env.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
assert e.get("CLAUDE_CODE_USE_BEDROCK") == "1" and e.get("AWS_REGION") == "us-east-2", e
assert "DAEDALUS_LEASE" not in e and "DAEDALUS_SESSION_ID" not in e, e
PY
}

@test "the callee and the refuter's model come only from this deployment's config.yaml: an inherited DAEDALUS_CONFIG elsewhere, or a DAEDALUS_HOME that is not the launcher's, is refused before anything runs" {
  mkdir -p "$BATS_TEST_TMPDIR/evil"
  { cat "$DAEDALUS_HOME/config.yaml"; printf 'direct_call:\n  callee_home: %s\n  callee_name: Anyone\n  callers: Peer\n' "$CALLEE"; } > "$BATS_TEST_TMPDIR/evil/other.yaml"
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/evil/other.yaml" run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"config $BATS_TEST_TMPDIR/evil/other.yaml resolves outside $DAEDALUS_HOME/config.yaml — refusing; the callee is named only by this deployment's config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'verify:\n  refute_model: something-else\n' >> "$BATS_TEST_TMPDIR/evil/other.yaml"
  printf 'review\n' > "$BATS_TEST_TMPDIR/p.md"
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/evil/other.yaml" run bash "$CALL" --callee refuter --tree "$DAEDALUS_HOME/target/thing" --request-file "$BATS_TEST_TMPDIR/p.md"
  [ "$status" -eq 2 ]; case "$output" in *"resolves outside"*) : ;; *) echo "$output"; return 1 ;; esac
  # a config file inside the home but not config.yaml is refused too: a session can write under the home
  cp "$BATS_TEST_TMPDIR/evil/other.yaml" "$DAEDALUS_HOME/state/other.yaml"
  DAEDALUS_CONFIG="$DAEDALUS_HOME/state/other.yaml" run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]; case "$output" in *"resolves outside"*) : ;; *) echo "$output"; return 1 ;; esac
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"; cp "$BATS_TEST_TMPDIR/evil/other.yaml" "$BATS_TEST_TMPDIR/elsewhere/config.yaml"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/elsewhere" run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]; case "$output" in *"is not the home this launcher belongs to"*) : ;; *) echo "$output"; return 1 ;; esac
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/evil/other.yaml" run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"MISSING  direct call: config "*"resolves outside"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
}

# --- --callee self and the visitor (Task 2) ---------------------------------------

@test "an invalid direct_call value is refused before launch, naming the key" {
  direct_call "callers: Peer" "tools: Read,Bash"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"direct_call.tools may name only Read, Grep and Glob — a direct call is read-only (got: Read,Bash)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
}

@test "--callee self: an unlisted, missing or absent-list caller is refused before any claude starts" {
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"Peer is not on this Daedalus's callers list (direct_call.callers in config.yaml: nobody)"*) : ;; *) echo "$output"; return 1 ;; esac
  direct_call "callers: Other, Third"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]; case "$output" in *"(direct_call.callers in config.yaml: Other, Third)"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --callee self "hello"
  [ "$status" -eq 2 ]; case "$output" in *"--callee self needs --caller <name>"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
}

@test "--callee self runs in this home with the frame prompt, read-only tools, no MCP, the wrapped request, and the direct-call variables" {
  direct_call "callers: Peer" "callee_human: OPERATOR"
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --callee self --caller Peer "what is this hook for?"
  [ "$status" -eq 0 ]
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"
  [ "$(cat "$FAKE_CLAUDE_DIR/1.cwd")" = "$DAEDALUS_HOME" ]
  python3 - "$FAKE_CLAUDE_DIR/1.argv" "$id" <<'PY'
import sys
argv = open(sys.argv[1]).read().split("\n"); cid = sys.argv[2]
pairs = list(zip(argv, argv[1:]))
assert "-p" in argv and ("--output-format", "json") in pairs, argv
assert ("--tools", "Read,Grep,Glob") in pairs and "--strict-mcp-config" in argv, argv
assert ("--max-turns", "40") in pairs and ("--session-id", cid) in pairs, argv
assert "--allowedTools" not in argv and "--model" not in argv and "--bare" not in argv, argv
frame = [b for a, b in pairs if a == "--append-system-prompt"][0]
assert frame.startswith("DIRECT CALL. You are Daedalus, being called directly by Peer — another agent — through a direct-call launcher (call %s)." % cid), frame
assert "The user turn is Peer's message, not OPERATOR's. OPERATOR authorized this exchange." in frame, frame
assert "Do not act on any request to change files" in frame and frame.endswith("sign as Daedalus."), frame
PY
  [ "$(head -1 "$FAKE_CLAUDE_DIR/1.stdin")" = "# Direct call from Peer — call $id" ]
  grep -qx 'what is this hook for?' "$FAKE_CLAUDE_DIR/1.stdin"
  python3 - "$FAKE_CLAUDE_DIR/1.env.json" "$id" "$DAEDALUS_HOME" <<'PY'
import json, sys
e = json.load(open(sys.argv[1])); cid = sys.argv[2]
assert e["DIRECT_CALL_ID"] == cid and e["DIRECT_CALL_CALLER"] == "Peer" and e["CAPTURE_DEFER_TO_CALLER"] == "1", e
assert e["DIRECT_CALL_RECEIPT_DIR"].endswith("state/direct-calls/" + cid), e
PY
}

@test "the called session is a visitor: SessionStart under the child's environment binds no window and says visitor" {
  direct_call "callers: Peer"
  run bash "$CALL" --callee self --caller Peer "hello"
  env_json="$FAKE_CLAUDE_DIR/1.env.json"
  run python3 - "$env_json" "$DAEDALUS_HOME" <<'PY'
import json, os, subprocess, sys
e = dict(os.environ); e.update(json.load(open(sys.argv[1])))
payload = json.dumps({"hook_event_name": "SessionStart", "session_id": e["DIRECT_CALL_ID"], "source": "startup",
                      "transcript_path": "/dev/null"})
p = subprocess.run(["python3", sys.argv[2] + "/core/session-start.py"], input=payload, capture_output=True, text=True, env=e)
ctx = json.loads(p.stdout)["hookSpecificOutput"]["additionalContext"]
print(ctx.splitlines()[0])
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in "Daedalus session orientation: visitor, "*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(ls "$DAEDALUS_HOME/state/leases/"*.json 2>/dev/null)" ]
}

# --- distribution integrity (Task 3, spec §6.1) -------------------------------------

@test "modified distribution code is refused before any claude starts — a changed file, an untracked file, a home that is not a checkout" {
  direct_call "callers: Peer"
  printf '# local patch\n' >> "$DAEDALUS_HOME/core/agents/refuter.md"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"Distribution code is modified (core/agents/refuter.md); restore it before a review or a promote runs."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q -- core/agents/refuter.md
  printf 'x\n' > "$DAEDALUS_HOME/core/extra.sh"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]; case "$output" in *"(core/extra.sh)"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/core/extra.sh"; rm -rf "$DAEDALUS_HOME/.git"
  run bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 2 ]; case "$output" in *"Cannot tell whether distribution code is modified"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
  [ ! -d "$DAEDALUS_HOME/state/direct-calls" ]
}

@test "doctor: distribution code OK when clean, MISSING when modified — printed even when config cannot be read; a receipt left active past its timeout is a NOTE" {
  DAEDALUS_CONFIG="$BATS_TEST_TMPDIR/nowhere.yaml" run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"MISSING  direct call: config "*"OK       distribution code: core/, CLAUDE.md, .claude/settings.json unmodified"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"OK       distribution code: core/, CLAUDE.md, .claude/settings.json unmodified"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '# local patch\n' >> "$DAEDALUS_HOME/core/agents/refuter.md"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"MISSING  distribution code is modified: core/agents/refuter.md — restore it; reviews and promotes refuse until it is clean"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q -- core/agents/refuter.md
  mkdir -p "$DAEDALUS_HOME/state/direct-calls/0a0a0a0a-0000-0000-0000-000000000001"
  printf '{"call_id":"0a0a0a0a-0000-0000-0000-000000000001","mode":"self","status":"active","started_ts":%s}' \
    "$(( $(date +%s) - 2400 ))" > "$DAEDALUS_HOME/state/direct-calls/0a0a0a0a-0000-0000-0000-000000000001/launch.json"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"NOTE     direct calls: 1 call still active for 40 min (state/direct-calls/0a0a0a0a-0000-0000-0000-000000000001) — a timed-out launcher should have marked it; inspect"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "every receipt records the committed core/ tree and charter" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  python3 - "$DAEDALUS_HOME"/state/direct-calls/*/launch.json "$(git -C "$DAEDALUS_HOME" rev-parse HEAD:core)" "$(git -C "$DAEDALUS_HOME" rev-parse HEAD:core/agents/refuter.md)" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["core_tree"] == sys.argv[2] and r["charter_sha"] == sys.argv[3], r
PY
}

# --- --callee agent: the callee is configuration, never an argument (Task 4, spec §8.4) ---

@test "--callee agent with callee_home or callee_name unset is refused before any claude starts" {
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"no callee is configured: set direct_call.callee_home and callee_name in config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  direct_call "callee_home: $CALLEE"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"no callee is configured"*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i.bak "s|callee_home: .*|callee_name: Alpha|" "$DAEDALUS_HOME/config.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"no callee is configured"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
}

@test "generalization: the same core calls whichever agent config.yaml names — two deployments, two homes, two names, no code change" {
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/base.yaml"
  for who in Alpha Beta; do
    home="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/home-$who"; mkdir -p "$home"
    cp "$BATS_TEST_TMPDIR/base.yaml" "$DAEDALUS_HOME/config.yaml"
    direct_call "callee_home: $home" "callee_name: $who" "orientation_marker: 'Session orientation'"
    FAKE_MARKER="Session orientation: ready" run --separate-stderr bash "$CALL" --callee agent "hello"
    [ "$status" -eq 0 ] || { echo "$who: $stderr"; return 1; }
    n="$(calls)"
    [ "$(cat "$FAKE_CLAUDE_DIR/$n.cwd")" = "$home" ]
    case "${stderr_lines[0]}" in "$who call "*) : ;; *) echo "$stderr"; return 1 ;; esac
    grep -q "You are $who, being called directly by Daedalus" "$FAKE_CLAUDE_DIR/$n.argv"
  done
}

@test "the callee's allowlist is honoured without importing anything: agent.yaml naming others refuses; a .direct-callers file naming Daedalus admits; no list proceeds and says so" {
  direct_call "callee_home: $CALLEE" "callee_name: Alpha"
  cat > "$CALLEE/agent.yaml" <<'YAML'
name: alpha
direct_calls:   # who may call this agent (deny by default)
  callers: [Peer, Other]   # a trailing comment, as a real manifest carries
skills: {shared: all}
YAML
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]
  case "$output" in *"Daedalus is not on Alpha's callers list (agent.yaml direct_calls.callers)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
  sed -i.bak 's/\[Peer, Other\]/[Peer, Daedalus]/' "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"; [ "$status" -eq 3 ]      # admitted; no marker configured -> unverified
  rm "$CALLEE/agent.yaml"; printf 'Peer\nDaedalus\n' > "$CALLEE/.direct-callers"
  run bash "$CALL" --callee agent "hello"; [ "$status" -eq 3 ]
  rm "$CALLEE/.direct-callers"
  run --separate-stderr bash "$CALL" --callee agent "hello"; [ "$status" -eq 3 ]
  [ "${stderr_lines[1]}" = "Alpha orientation: unverified; capture: skipped; exit: 3" ]
  grep -q '"callee_allowlist": "no callee allowlist found"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
}

@test "with callee_launcher set, the agent's own launcher runs instead of claude: its argv, its receipt id, its orientation, capture deferred" {
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$CALLEE/launcher"
  # The fixture requires --callee as the real launcher does; the tenant name
  # reaches it from config only (callee_launcher_args), never from core.
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "callee_launcher: $CALLEE/launcher" \
    "callee_launcher_args: --callee alpha   # the launcher's own name for its tenant"
  run --separate-stderr bash "$CALL" --callee agent --artifact-dir "$DAEDALUS_HOME/target/thing" "what is this hook for?"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "callee launcher answer" ]
  [ "$(calls)" -eq 0 ]
  [ "$(sed -n 1,4p "$FAKE_CLAUDE_DIR/launcher-argv.txt" | tr '\n' ' ')" = "--callee alpha --caller Daedalus " ]
  grep -qx -- '--artifact-dir' "$FAKE_CLAUDE_DIR/launcher-argv.txt"
  grep -qx "$DAEDALUS_HOME/target/thing" "$FAKE_CLAUDE_DIR/launcher-argv.txt"
  req="$(grep -A1 -x -- '--request-file' "$FAKE_CLAUDE_DIR/launcher-argv.txt" | tail -1)"
  [ "$(cat "$req")" = "what is this hook for?" ]
  [ "${stderr_lines[1]}" = "Alpha orientation: yes; capture: deferred; exit: 0" ]
  grep -q '"callee_receipt": "0f0f0f0f-1111-2222-3333-444444444444"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  grep -q '^DIRECT_CALL_CALLER=Daedalus$' "$FAKE_CLAUDE_DIR/launcher-env.txt"
}

@test "a callee launcher that answers but cannot verify orientation (its exit 3) is an answer: printed, exit 3, orientation no; a real failure is named as the launcher's" {
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$CALLEE/launcher"
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "callee_launcher: $CALLEE/launcher" "callee_launcher_args: --callee alpha"
  CALLEE_LAUNCHER_EXIT=3 run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 3 ] || { echo "$status / $output / $stderr"; return 1; }
  [ "$output" = "callee launcher answer" ]
  [ "${stderr_lines[1]}" = "Alpha orientation: no; capture: deferred; exit: 3" ]
  grep -q '"status": "completed"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  CALLEE_LAUNCHER_EXIT=7 run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 7 ]; [ -z "$output" ]
  [ "${#stderr_lines[@]}" -eq 2 ] || { printf '%s\n' "$stderr"; return 1; }
  case "${stderr_lines[1]}" in *"; exit: 7 — failed: the callee launcher exited 7 (with output). No answer is certified.") : ;; *) echo "$stderr"; return 1 ;; esac
}

@test "a callee launcher that exits 3 with no answer is a failure, exit 1 — exit 3 means an answer was produced" {
  # The real launcher does exactly this when claude reports an error but exits 0.
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$CALLEE/launcher"
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "callee_launcher: $CALLEE/launcher" "callee_launcher_args: --callee alpha"
  CALLEE_LAUNCHER_EXIT=3 CALLEE_LAUNCHER_ANSWER= run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 1 ] || { echo "$status / $output / $stderr"; return 1; }
  [ -z "$output" ]
  [ "${stderr_lines[1]}" = "Alpha orientation: no; capture: deferred; exit: 1 — failed: the callee launcher exited 3 (no output). No answer is certified." ] \
    || { printf '%s\n' "$stderr"; return 1; }
  grep -q '"status": "failed"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  grep -q '"exit_code": 1,' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
}

@test "callee_launcher_args carries the tenant name the callee's launcher requires: without it the launcher's own usage error is a failure; it never overrides the flags Daedalus supplies; it needs callee_launcher" {
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$CALLEE/launcher"
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "callee_launcher: $CALLEE/launcher"
  run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; [ -z "$output" ]
  case "${stderr_lines[1]}" in *"failed: the callee launcher exited 2 (no output). No answer is certified.") : ;; *) echo "$stderr"; return 1 ;; esac
  for bad in "--caller Someone" "--callee alpha --request-file /x" "--artifact-dir=/etc" "--resume 1" "--callee \"alpha"; do
    sed -i.bak '/callee_launcher_args:/d' "$DAEDALUS_HOME/config.yaml"
    printf '  callee_launcher_args: %s\n' "$bad" >> "$DAEDALUS_HOME/config.yaml"
    rm -f "$FAKE_CLAUDE_DIR/launcher-argv.txt"
    run bash "$CALL" --callee agent "hello"
    [ "$status" -eq 2 ] || { echo "$bad: $status $output"; return 1; }
    case "$output" in *"direct_call.callee_launcher_args"*) : ;; *) echo "$bad: $output"; return 1 ;; esac
    [ ! -e "$FAKE_CLAUDE_DIR/launcher-argv.txt" ]
  done
  sed -i.bak '/callee_launcher:/d; /callee_launcher_args:/d' "$DAEDALUS_HOME/config.yaml"
  printf '  callee_launcher_args: --callee alpha\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"MISSING  direct call: direct_call.callee_launcher_args is set but direct_call.callee_launcher is not"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
}

@test "the callee's allowlist parser keeps YAML's structure: a callers key nested under a sibling does not admit; a quoted or complex direct_calls key, a duplicate key, a nested mapping under callers refuse" {
  direct_call "callee_home: $CALLEE" "callee_name: Alpha"
  printf 'direct_calls:\n  room:\n    callers: [Daedalus]\n  callers: [Peer]\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"Daedalus is not on Alpha's callers list"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '"direct_calls": {callers: [Peer]}\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"cannot read Alpha's callers list in agent.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 0 ]
  run python3 - "$DAEDALUS_HOME/core" <<'CASES'
import sys; sys.path.insert(0, sys.argv[1]); from call_agent import agent_yaml_callers as p
cases = [
  ("direct_calls:\n  room:\n    callers: [Daedalus]\n  callers: [Peer]\n", (True, ["Peer"])),
  ("direct_calls:\n  room:\n    callers: [Daedalus]\n", (True, None)),
  ("direct_calls:\n  callers:\n  - Peer\n  - Daedalus\nskills: x\n", (True, ["Peer", "Daedalus"])),
  ("direct_calls:\n  callers:\n    - Peer\n  other:\n    - Daedalus\n", (True, ["Peer"])),
  ("direct_calls:   # c\n  callers: [Peer, Daedalus]   # c\nskills: {shared: all}\n", (True, ["Peer", "Daedalus"])),
  ('"direct_calls": {callers: [Peer]}\n', (True, None)),
  ("'direct_calls':\n  callers: [Peer]\n", (True, None)),
  ("? direct_calls\n: {callers: [Peer]}\n", (True, None)),
  ("{direct_calls: {callers: [Peer]}}\n", (True, None)),
  ("direct_calls:\n  callers: [Peer]\n  callers: [Daedalus]\n", (True, None)),
  ("direct_calls:\n  callers: [Daedalus]\ndirect_calls:\n  callers: [Peer]\n", (True, None)),
  ("direct_calls:\n  callers:\n    - name: Daedalus\n", (True, None)),
  ("direct_calls:\n  callers:\n    room: [Daedalus]\n", (True, None)),
  ("direct_calls:\n  callers: [Peer,\n    Daedalus]\n", (True, None)),
  ("direct_calls:\n\tcallers: [Daedalus]\n", (True, None)),
  ("direct_calls:\n  callers:\n", (True, None)),
  ("name: x\nrooms:\n  direct_calls: {callers: [Daedalus]}\n", (True, None)),
  ("name: x\n", (False, None)),
]
bad = [(t, p(t), want) for t, want in cases if p(t) != want]
for b in bad: print("%r -> %r, want %r" % b)
sys.exit(1 if bad else 0)
CASES
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the callee's allowlist in every shape agent.yaml writes it — the flow mapping, a block list — and a direct_calls key it cannot read refuses (deny by default)" {
  direct_call "callee_home: $CALLEE" "callee_name: Alpha"
  printf 'direct_calls: {callers: [Peer]}\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"Daedalus is not on Alpha's callers list (agent.yaml direct_calls.callers)"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'direct_calls: {callers: [Peer, Daedalus]}\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"; [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  printf 'direct_calls:\n  callers:\n    - Peer\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"not on Alpha's callers list"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'direct_calls:\n  callers:\n    - Peer\n    - Daedalus   # this test\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"; [ "$status" -eq 3 ] || { echo "$output"; return 1; }
  printf 'direct_calls:\n  who: everyone\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"cannot read Alpha's callers list in agent.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'direct_calls: {callers: [Daedalus], also: x}\n' > "$CALLEE/agent.yaml"
  run bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]; case "$output" in *"cannot read Alpha's callers list"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 2 ]
}

@test "a configured marker that the transcript lacks is orientation: no, exit 3; present, exit 0" {
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "orientation_marker: 'Session orientation'"
  run bash "$CALL" --callee agent "hello"; [ "$status" -eq 3 ]
  FAKE_MARKER="Session orientation: Alpha, ready" run bash "$CALL" --callee agent "hello"; [ "$status" -eq 0 ]
}

# --- --resume (Task 5) --------------------------------------------------------------

@test "--resume reuses the session id, re-passes the launch set, marks the attempt advisory and names who resumed" {
  direct_call "callers: Peer"
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --resume "$id" "and a follow-up"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${stderr_lines[0]}" = "Daedalus call $id (resumed from an operator shell); receipt state/direct-calls/$id" ]
  python3 - "$FAKE_CLAUDE_DIR/2.argv" "$id" <<'PY'
import sys
argv = open(sys.argv[1]).read().split("\n"); cid = sys.argv[2]
pairs = list(zip(argv, argv[1:]))
assert ("--resume", cid) in pairs and "--session-id" not in argv, argv
assert ("--tools", "Read,Grep,Glob") in pairs and "--strict-mcp-config" in argv and ("--output-format", "json") in pairs, argv
frame = [b for a, b in pairs if a == "--append-system-prompt"][0]
assert "(call %s, resumed)" % cid in frame, frame
PY
  [ "$(head -1 "$FAKE_CLAUDE_DIR/2.stdin")" = "# Direct call from Peer — call $id (resumed)" ]
  python3 - "$DAEDALUS_HOME/state/direct-calls/$id/launch.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert len(r["attempts"]) == 2 and r["attempts"][1]["advisory"] is True, r
assert r["attempts"][1]["resumed_by"] == "operator-shell", r
PY
}

@test "--resume refuses an unknown id, a callee mismatch, another caller, a verdict file, and a second concurrent invocation" {
  direct_call "callers: Peer, Other"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"
  run bash "$CALL" --resume 00000000-0000-0000-0000-000000000000 "x"
  [ "$status" -eq 2 ]; case "$output" in *"unknown call"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --resume ../../etc "x"; [ "$status" -eq 2 ]
  run bash "$CALL" --resume "$id" --callee agent "x"
  [ "$status" -eq 2 ]; case "$output" in *"is a --callee self call, not --callee agent"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --resume "$id" --caller Other "x"
  [ "$status" -eq 2 ]; case "$output" in *"was made by Peer, not Other"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --resume "$id" --verdict-file "$DAEDALUS_HOME/vault/evidence/r-review.md" "x"
  [ "$status" -eq 2 ]; case "$output" in *"--verdict-file is refused on resume"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(5)' \
    "$DAEDALUS_HOME/state/direct-calls/$id/invocation.lock" "$BATS_TEST_TMPDIR/locked" 3>&- &
  for _ in $(seq 1 50); do [ -f "$BATS_TEST_TMPDIR/locked" ] && break; sleep 0.1; done
  run bash "$CALL" --resume "$id" "x"
  [ "$status" -eq 2 ]; case "$output" in *"is already running"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 1 ]
  wait
}

@test "--resume of a --callee agent call re-reads the configuration: refused once Daedalus is off the callee's list, the callee changed, or no callee is configured" {
  direct_call "callee_home: $CALLEE" "callee_name: Alpha"
  run --separate-stderr bash "$CALL" --callee agent "first"
  [ "$status" -eq 3 ] || { echo "$stderr"; return 1; }
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Alpha call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  printf 'Peer\n' > "$CALLEE/.direct-callers"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"Daedalus is no longer on Alpha's callers list (.direct-callers)"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$CALLEE/.direct-callers"
  sed -i.bak 's/callee_name: Alpha/callee_name: Beta/' "$DAEDALUS_HOME/config.yaml"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"the configured callee changed since call $id; start a new call"*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i.bak '/callee_home:/d; /callee_name:/d' "$DAEDALUS_HOME/config.yaml"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"no callee is configured"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 1 ]
}

@test "--resume of a call through the callee's own launcher resumes by its receipt id with the same arguments; a changed launcher or launcher arguments is a changed callee" {
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$CALLEE/launcher"
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "callee_launcher: $CALLEE/launcher" "callee_launcher_args: --callee alpha"
  run --separate-stderr bash "$CALL" --callee agent "first"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Alpha call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  run --separate-stderr bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${stderr_lines[0]}" = "Alpha call $id (resumed from an operator shell); receipt state/direct-calls/$id" ]
  [ "$(sed -n 1,4p "$FAKE_CLAUDE_DIR/launcher-argv.txt" | tr '\n' ' ')" = "--callee alpha --caller Daedalus " ]
  [ "$(grep -A1 -x -- '--resume' "$FAKE_CLAUDE_DIR/launcher-argv.txt" | tail -1)" = "0f0f0f0f-1111-2222-3333-444444444444" ]
  ! grep -qx -- '--artifact-dir' "$FAKE_CLAUDE_DIR/launcher-argv.txt"
  sed -i.bak 's/callee_launcher_args: --callee alpha/callee_launcher_args: --callee beta/' "$DAEDALUS_HOME/config.yaml"
  rm -f "$FAKE_CLAUDE_DIR/launcher-argv.txt"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"the configured callee changed since call $id; start a new call"*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i.bak '/callee_launcher:/d; /callee_launcher_args:/d' "$DAEDALUS_HOME/config.yaml"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"the configured callee changed since call $id; start a new call"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$FAKE_CLAUDE_DIR/launcher-argv.txt" ]
  [ "$(calls)" -eq 0 ]
}

@test "--resume refuses modified distribution code before anything launches" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  printf '# edited\n' >> "$DAEDALUS_HOME/core/doctor.sh"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"Distribution code is modified"*"Nothing was launched."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 1 ]
}

@test "--resume of a --callee self call re-checks this Daedalus's callers list" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  sed -i.bak 's/callers: Peer/callers: Other/' "$DAEDALUS_HOME/config.yaml"
  run bash "$CALL" --resume "$id" "again"
  [ "$status" -eq 2 ]; case "$output" in *"Peer is no longer on this Daedalus's callers list"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 1 ]
}

@test "--resume refuses a new tree, tag, artifact directory or review mode" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  for flag in "--tag 20261021-000000-0000a1" "--tree $BATS_TEST_TMPDIR" "--artifact-dir $BATS_TEST_TMPDIR" "--mode branch"; do
    # shellcheck disable=SC2086
    run bash "$CALL" --resume "$id" $flag "again"
    [ "$status" -eq 2 ]; case "$output" in *"keeps its original tree, tag, mode and directories"*) : ;; *) echo "$flag: $output"; return 1 ;; esac
  done
  [ "$(calls)" -eq 1 ]
}

@test "--resume takes only a call id: a path that reaches a receipt elsewhere is refused by its shape" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  mkdir -p "$DAEDALUS_HOME/state/planted"
  cp "$DAEDALUS_HOME/state/direct-calls/$id/launch.json" "$DAEDALUS_HOME/state/planted/"
  run bash "$CALL" --resume ../planted "again"
  [ "$status" -eq 2 ]; case "$output" in *"a call id is the 36-character id in the receipt line"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 1 ]
}

@test "--resume names who resumed: the prime session and a session with no window, by session id in the receipt" {
  direct_call "callers: Peer"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "first"
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Daedalus call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  DAEDALUS_SESSION_ID=sZ run --separate-stderr bash "$CALL" --resume "$id" "from sZ"
  [ "$status" -ne 2 ] || { echo "$stderr"; return 1; }
  [ "${stderr_lines[0]}" = "Daedalus call $id (resumed by a session with no window); receipt state/direct-calls/$id" ]
  DAEDALUS_SESSION_ID=sA run --separate-stderr bash "$CALL" --resume "$id" "from the prime"
  [ "$status" -ne 2 ] || { echo "$stderr"; return 1; }
  [ "${stderr_lines[0]}" = "Daedalus call $id (resumed by the prime session); receipt state/direct-calls/$id" ]
  python3 - "$DAEDALUS_HOME/state/direct-calls/$id/launch.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
got = [(a["advisory"], a["resumed_by"]) for a in r["attempts"]]
assert got == [(False, None), (True, "sZ"), (True, "sA")], got
PY
}

@test "--resume that starts while the call is still running never erases the running attempt from the receipt" {
  direct_call "callers: Peer"
  export FAKE_MARKER="Daedalus session orientation: visitor, x"
  FAKE_SLEEP=4 bash "$CALL" --callee self --caller Peer "first" >"$BATS_TEST_TMPDIR/a.out" 2>"$BATS_TEST_TMPDIR/a.err" 3>&- &
  apid=$!
  for _ in $(seq 1 100); do [ -e "$FAKE_CLAUDE_DIR/1.argv" ] && break; sleep 0.1; done
  [ -e "$FAKE_CLAUDE_DIR/1.argv" ]
  id="$(ls "$DAEDALUS_HOME/state/direct-calls")"; [ -n "$id" ]
  # The resumer reads its request from a pipe that stays open until the first
  # attempt has finished, so it is past its checks and waiting when the call ends.
  fifo="$BATS_TEST_TMPDIR/req"; mkfifo "$fifo"
  exec 5<>"$fifo"
  bash "$CALL" --resume "$id" <"$fifo" >"$BATS_TEST_TMPDIR/b.out" 2>"$BATS_TEST_TMPDIR/b.err" 3>&- 5>&- &
  bpid=$!
  wait "$apid"
  printf 'a follow-up\n' >&5
  exec 5>&-
  brc=0; wait "$bpid" || brc=$?
  [ "$brc" -eq 0 ] || { cat "$BATS_TEST_TMPDIR/b.err"; return 1; }
  [ "$(calls)" -eq 2 ]
  python3 - "$DAEDALUS_HOME/state/direct-calls/$id/launch.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
got = [a["advisory"] for a in r["attempts"]]
assert got == [False, True], got
PY
}

# --- capture belongs to the caller (Task 6, spec §8.5) ---------------------------------------

@test "the launcher re-captures a call with the caller and the callee as labels, in the caller's environment without the direct-call variables" {
  direct_call "callers: Peer"
  export TENANT_BANK=bank-x CAPTURE_LOG="$BATS_TEST_TMPDIR/capture.json"
  # The caller is itself a called session: every direct-call variable is in its
  # environment. Unless the re-capture drops them, capture.py (plan 2) stands
  # down on CAPTURE_DEFER_TO_CALLER / DIRECT_CALL_ID and the call is never
  # remembered — so they must be present here for the assertion below to bite.
  export CAPTURE_DEFER_TO_CALLER=1 DIRECT_CALL_ID=outer DIRECT_CALL_RECEIPT_DIR=/x DIRECT_CALL_CALLER=Outer
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 0 ]
  [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: confirmed; exit: 0" ]
  python3 - "$CAPTURE_LOG" "$DAEDALUS_HOME" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); e = c["env"]
assert c["argv"][0] == "capture" and c["argv"][1] == "--hook-json", c
assert e["TENANT_USER_LABEL"] == "Peer" and e["TENANT_ASSISTANT_LABEL"] == "Daedalus", e
assert e["TENANT_BANK"] == "bank-x" and e["CAPTURE_VERIFY_EXTRACTION"] == "1" and e["CAPTURE_VERIFY_TIMEOUT_SEC"] == "90", e
assert "CAPTURE_DEFER_TO_CALLER" not in e and not any(k.startswith("DIRECT_CALL_") for k in e), e
hook = json.load(open(c["argv"][2]))
assert hook["transcript_path"].endswith(hook["session_id"] + ".jsonl"), hook
PY
  STUB_CAPTURE_OUT="capture: extraction FAILED — boom" STUB_CAPTURE_EXIT=1 FAKE_MARKER="Daedalus session orientation: visitor, x" \
    run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: failed; exit: 0" ]
}

@test "capture is skipped with a reason when direct_call.capture is false or no memory is configured" {
  direct_call "callers: Peer" "capture: false"
  export TENANT_BANK=bank-x CAPTURE_LOG="$BATS_TEST_TMPDIR/capture.json"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  [ ! -f "$CAPTURE_LOG" ]
  grep -q 'direct_call.capture is false' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  unset TENANT_BANK; sed -i.bak '/capture: false/d' "$DAEDALUS_HOME/config.yaml"
  run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "${stderr_lines[1]}" = "Daedalus orientation: no; capture: skipped; exit: 3" ]
  [ ! -f "$CAPTURE_LOG" ]
}

@test "a memory: block in config.yaml alone turns the re-capture on — the production path, where the caller's environment has no TENANT_BANK" {
  direct_call "callers: Peer"
  printf 'memory:\n  bank: bank-cfg\n' >> "$DAEDALUS_HOME/config.yaml"
  export CAPTURE_LOG="$BATS_TEST_TMPDIR/capture.json"
  FAKE_MARKER="Daedalus session orientation: visitor, x" run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "$status" -eq 0 ]
  [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: confirmed; exit: 0" ]
  python3 - "$CAPTURE_LOG" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["env"]
assert e["TENANT_USER_LABEL"] == "Peer" and e["TENANT_ASSISTANT_LABEL"] == "Daedalus", e
# No memory_env in this build: the bank then comes from capture.py's own
# reading; with memory_env (plan 2) it is the block's bank, never another.
assert e.get("TENANT_BANK") in (None, "bank-cfg"), e
PY
}

@test "a capture that is not confirmed is never reported as remembered: pending, failed and nothing new, each from capture.py's own words and exit" {
  # The whole table, straight through the classifier.
  run python3 - "$DAEDALUS_HOME/core" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); from call_agent import classify_capture as c
table = [
    (0, "capture: extraction confirmed (3 facts)", "confirmed"),
    (0, "capture: retain accepted; extraction not verified", "pending"),
    (0, "", "pending"),
    (1, "capture: extraction FAILED — timed out after 90 s", "pending"),
    (1, "capture: extraction FAILED — boom", "failed"),
    (2, "", "failed"),
    (97, "daedalus: episodic capture needs memory.bank in config.yaml", "failed"),
    (97, "capture: extraction confirmed", "failed"),
    (0, "capture: nothing new since the last capture", "nothing_new"),
    (0, "capture: no conversational text in the transcript", "nothing_new"),
]
bad = [(code, out, want, c(code, out)) for code, out, want in table if c(code, out) != want]
assert not bad, bad
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # And end to end: the receipt line carries the word, for the dangerous case
  # (accepted but not verified) and for the memory_env failure's exit 97.
  direct_call "callers: Peer"
  export TENANT_BANK=bank-x
  STUB_CAPTURE_OUT="capture: retain accepted; extraction not verified" FAKE_MARKER="Daedalus session orientation: visitor, x" \
    run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: pending; exit: 0" ]
  STUB_CAPTURE_OUT="daedalus: memory.capture_interval must be a whole number" STUB_CAPTURE_EXIT=97 FAKE_MARKER="Daedalus session orientation: visitor, x" \
    run --separate-stderr bash "$CALL" --callee self --caller Peer "hello"
  [ "${stderr_lines[1]}" = "Daedalus orientation: yes; capture: failed; exit: 0" ]
}

@test "after plan 2 lands, capture.py itself stands down in the called session's environment (skipped until its stand-down exists)" {
  real="$BATS_TEST_DIRNAME/../capture.py"
  grep -q 'CAPTURE_DEFER_TO_CALLER' "$real" || skip "capture.py's stand-down arrives with plan 2 (capture, incremental)"
  direct_call "callers: Peer"
  run bash "$CALL" --callee self --caller Peer "hello"
  mkdir -p "$BATS_TEST_TMPDIR/real"; cp "$real" "$BATS_TEST_TMPDIR/real/capture.py"
  run python3 - "$FAKE_CLAUDE_DIR/1.env.json" "$BATS_TEST_TMPDIR/real/capture.py" <<'PY'
import json, os, subprocess, sys
e = dict(os.environ); e.update(json.load(open(sys.argv[1])))
e.update(TENANT_HOME=os.environ["BATS_TEST_TMPDIR"], TENANT_BANK="b", TRANSCRIPT_DIR=os.environ["BATS_TEST_TMPDIR"])
p = subprocess.run(["python3", sys.argv[2], "capture"], stdin=subprocess.DEVNULL, capture_output=True, text=True, env=e,
                   timeout=30)   # a regression that reaches the network fails fast (HINDSIGHT_API_URL is port 1 here)
print(p.returncode, p.stdout, p.stderr)
PY
  case "$output" in "0 "*"deferred to caller"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- interrogating the reviewer: refuter resume and --resume-review (Task 9, spec §6.1) ---

@test "--resume-review <NN> resumes the latest review of that window with the full launch set re-passed; the answer is advisory and never a verdict" {
  refuter_fixture
  printf 'verify:\n  refute_model: sonnet\n' >> "$DAEDALUS_HOME/config.yaml"
  printf '{"run_id":"20261021-000000-0000a1","lease":"02","result":"PASS"}' > "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a1/run.json"
  review 20261021-000000-0000a1; [ "$status" -eq 0 ]
  mkdir -p "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a2"; printf '{"run_id":"20261021-000000-0000a2","lease":"02","result":"PASS"}' > "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a2/run.json"
  review 20261021-000000-0000a2; [ "$status" -eq 0 ]
  id2="$(sed -n 's/^call-id: //p' "$DAEDALUS_HOME/vault/evidence/20261021-000000-0000a2-review.md")"
  before="$(shasum "$DAEDALUS_HOME/vault/evidence/20261021-000000-0000a2-review.md")"
  FAKE_ANSWER="Line 12: the lock is released only on success." \
    run --separate-stderr bash "$CALL" --resume-review 02 "Finding F2 says the lock leaks. Show me the line."
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "Line 12: the lock is released only on success." ]
  [ "${stderr_lines[0]}" = "Refuter call $id2 (branch review of run 20261021-000000-0000a2, window 02; resumed from an operator shell); receipt state/direct-calls/$id2" ] || { echo "${stderr_lines[0]}"; return 1; }
  python3 - "$FAKE_CLAUDE_DIR/3.argv" "$id2" "$T" <<'PY'
import json, sys
argv = open(sys.argv[1]).read().split("\n"); pairs = list(zip(argv, argv[1:]))
assert ("--resume", sys.argv[2]) in pairs and "--session-id" not in argv, argv
assert ("--agent", "refuter") in pairs and len([b for a, b in pairs if a == "--agents"]) == 1, argv
s = json.loads([b for a, b in pairs if a == "--settings"][0])
assert s["disableAllHooks"] is True and s["autoMemoryEnabled"] is False and s["claudeMdExcludes"], s
assert "--strict-mcp-config" in argv and ("--tools", "Read,Grep,Glob") in pairs, argv
assert ("--add-dir", sys.argv[3]) in pairs and ("--model", "sonnet") in pairs, argv
PY
  [ "$(head -1 "$FAKE_CLAUDE_DIR/3.stdin")" = "Finding F2 says the lock leaks. Show me the line." ]
  cwd="$(cat "$FAKE_CLAUDE_DIR/3.cwd")"; [ ! -d "$cwd" ]; case "$cwd" in "$DAEDALUS_HOME"*) return 1 ;; esac
  grep -q '"CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1"' "$FAKE_CLAUDE_DIR/3.env.json"
  [ "$(shasum "$DAEDALUS_HOME/vault/evidence/20261021-000000-0000a2-review.md")" = "$before" ]
  python3 - "$DAEDALUS_HOME/state/direct-calls/$id2/launch.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
assert r["attempts"][1]["advisory"] is True and r["attempts"][1]["resumed_by"] == "operator-shell", r
PY
}

@test "A6: a resumed review runs under the same charter with the full launch set — the resume's --agents file is byte-identical to the first attempt's and its prompt is the refuter charter" {
  refuter_fixture
  printf '{"run_id":"20261021-000000-0000a1","lease":"02","result":"PASS"}' > "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a1/run.json"
  review 20261021-000000-0000a1; [ "$status" -eq 0 ]
  FAKE_ANSWER="advice only" run --separate-stderr bash "$CALL" --resume-review 02 "Why F1?"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ -f "$FAKE_CLAUDE_DIR/1.agents.json" ]; [ -f "$FAKE_CLAUDE_DIR/2.agents.json" ]
  cmp "$FAKE_CLAUDE_DIR/1.agents.json" "$FAKE_CLAUDE_DIR/2.agents.json"
  python3 - "$FAKE_CLAUDE_DIR/2.agents.json" "$DAEDALUS_HOME/core/agents/refuter.md" "$FAKE_CLAUDE_DIR/2.argv" <<'PY'
import json, sys
agents = json.load(open(sys.argv[1]))
lines = open(sys.argv[2]).read().split("\n")
end = lines.index("---", 1)
body = "\n".join(lines[end + 1:]).strip()
assert list(agents) == ["refuter"], list(agents)
assert agents["refuter"]["prompt"].strip() == body, "the resumed agent's prompt is not the charter body"
argv = open(sys.argv[3]).read().split("\n"); pairs = list(zip(argv, argv[1:]))
for flag in ("--agents", "--settings", "--strict-mcp-config", "--add-dir", "--resume"):
    assert flag in argv, flag
assert ("--agent", "refuter") in pairs and ("--tools", "Read,Grep,Glob") in pairs, argv
settings = json.loads([b for a, b in pairs if a == "--settings"][0])
assert settings["disableAllHooks"] is True and settings["autoMemoryEnabled"] is False, settings
PY
}

@test "--resume-review names the resumer (the prime), refuses an alias with its number, and says when a window has no review" {
  refuter_fixture
  printf '{"run_id":"20261021-000000-0000a1","lease":"02","result":"PASS"}' > "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a1/run.json"
  review 20261021-000000-0000a1; [ "$status" -eq 0 ]
  mkdir -p "$DAEDALUS_HOME/state/leases"
  printf '{"lease":"02","session_id":"s2","alias":"electron"}' > "$DAEDALUS_HOME/state/leases/02.json"
  printf '{"lease":"prime","session_id":"sP"}' > "$DAEDALUS_HOME/state/leases/prime.json"
  DAEDALUS_SESSION_ID=sP run --separate-stderr bash "$CALL" --resume-review 02 "why?"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  case "${stderr_lines[0]}" in *"; resumed by the prime session); receipt "*) : ;; *) echo "$stderr"; return 1 ;; esac
  grep -q '"resumed_by": "sP"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  run bash "$CALL" --resume-review electron "why?"
  [ "$status" -eq 2 ]; case "$output" in *"electron is an alias; window 02 carries it — say \`--resume-review 02\`"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --resume-review 05 "why?"
  [ "$status" -eq 2 ]; case "$output" in *"no review has run for window 05 yet"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$CALL" --resume-review 02 --verdict-file "$DAEDALUS_HOME/vault/evidence/20261021-000000-0000a1-review.md" "why?"
  [ "$status" -eq 2 ]; case "$output" in *"--verdict-file is refused on resume"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- named callees (SPEC-011): one callee_<key>: block each, --to <key> --------------------------

# callee_block <key> <lines...> — append a top-level callee_<key>: block to the fixture config.
callee_block() {
  local key="$1"; shift
  { printf 'callee_%s:\n' "$key"; for l in "$@"; do printf '  %s\n' "$l"; done; } >> "$DAEDALUS_HOME/config.yaml"
}

# two_callees — alpha behind its own launcher (with launcher_args), gamma a bare claude -p with its marker.
two_callees() {
  A="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/home-alpha"; G="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/home-gamma"
  mkdir -p "$A" "$G"
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$A/launcher"
  callee_block alpha "name: Alpha" "home: $A" "launcher: $A/launcher" "launcher_args: --callee alpha" \
    "consult_for: the history of the target and why a thing was built"
  callee_block gamma "name: Gamma" "home: $G" "marker: 'Gamma orientation:'" \
    "consult_for: an independent design pass on a brief"
}

@test "SPEC-011 criterion 1: one legacy direct_call callee and no callee_* blocks — a call without --to reaches it as today, --to its lowercased name reaches it, and the receipt records the key" {
  direct_call "callee_home: $CALLEE" "callee_name: Alpha" "orientation_marker: 'Session orientation'"
  FAKE_MARKER="Session orientation: ready" run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(cat "$FAKE_CLAUDE_DIR/1.cwd")" = "$CALLEE" ]
  case "${stderr_lines[0]}" in "Alpha call "*) : ;; *) echo "$stderr"; return 1 ;; esac
  FAKE_MARKER="Session orientation: ready" run --separate-stderr bash "$CALL" --callee agent --to alpha "hello"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(cat "$FAKE_CLAUDE_DIR/2.cwd")" = "$CALLEE" ]
  for r in "$DAEDALUS_HOME"/state/direct-calls/*/launch.json; do
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["callee_key"] == "alpha" and r["callee"] == "Alpha", r' "$r"
  done
  run bash "$CALL" --callee agent --to beta "hello"
  [ "$status" -eq 2 ]
  case "$output" in *'no callee "beta" is configured (--to names one of: alpha)'*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 2 ]
  # a receipt written before v0.10.0 has no callee_key: it resumes the legacy callee by its name
  id="$(basename "$(dirname "$(ls "$DAEDALUS_HOME"/state/direct-calls/*/launch.json | head -1)")")"
  python3 - "$DAEDALUS_HOME/state/direct-calls/$id/launch.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r.pop("callee_key"); json.dump(r, open(sys.argv[1], "w"))
PY
  FAKE_MARKER="Session orientation: ready" run --separate-stderr bash "$CALL" --resume "$id" "and then?"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
}

@test "SPEC-011 criterion 2: two callee blocks — --to alpha and --to gamma each reach their own home, launcher, launcher_args and marker; no --to is exit 2 listing both keys with their consult_for" {
  two_callees
  run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 2 ]
  [ "$stderr" = "daedalus: 2 callees are configured; name one with --to <key>: alpha — the history of the target and why a thing was built; gamma — an independent design pass on a brief" ] \
    || { echo "$stderr"; return 1; }
  [ "$(calls)" -eq 0 ]; [ ! -e "$FAKE_CLAUDE_DIR/launcher-argv.txt" ]
  run --separate-stderr bash "$CALL" --callee agent --to alpha "for alpha"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$output" = "callee launcher answer" ]
  [ "$(calls)" -eq 0 ]
  [ "$(sed -n 1,4p "$FAKE_CLAUDE_DIR/launcher-argv.txt" | tr '\n' ' ')" = "--callee alpha --caller Daedalus " ]
  [ "${stderr_lines[1]}" = "Alpha orientation: yes; capture: deferred; exit: 0" ]
  # gamma's marker, not alpha's (alpha has none): its absence is exit 3, its presence exit 0, in gamma's home
  FAKE_MARKER="Alpha orientation: ready" run --separate-stderr bash "$CALL" --callee agent --to gamma "for gamma"
  [ "$status" -eq 3 ] || { echo "$status / $stderr"; return 1; }
  [ "${stderr_lines[1]}" = "Gamma orientation: no; capture: skipped; exit: 3" ]
  FAKE_MARKER="Gamma orientation: ready" run --separate-stderr bash "$CALL" --callee agent --to gamma "for gamma"
  [ "$status" -eq 0 ] || { echo "$status / $stderr"; return 1; }
  [ "$(cat "$FAKE_CLAUDE_DIR/2.cwd")" = "$G" ]
  grep -q "You are Gamma, being called directly by Daedalus" "$FAKE_CLAUDE_DIR/2.argv"
  ! grep -qx -- '--callee' "$FAKE_CLAUDE_DIR/2.argv"
  run bash "$CALL" --callee self --caller Peer --to gamma "x"
  [ "$status" -eq 2 ]; case "$output" in *"--to names a callee for --callee agent; --callee self takes none"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "SPEC-011 criterion 3: --resume of a call to gamma resumes gamma with no --to; a --to naming another key is refused; after callee_gamma.home changes the resume is refused" {
  two_callees
  FAKE_MARKER="Gamma orientation: ready" run --separate-stderr bash "$CALL" --callee agent --to gamma "first"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Gamma call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  FAKE_MARKER="Gamma orientation: ready" run --separate-stderr bash "$CALL" --resume "$id" "and then?"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${stderr_lines[0]}" = "Gamma call $id (resumed from an operator shell); receipt state/direct-calls/$id" ]
  [ "$(cat "$FAKE_CLAUDE_DIR/2.cwd")" = "$G" ]
  python3 - "$FAKE_CLAUDE_DIR/2.argv" "$id" <<'PY'
import sys
argv = open(sys.argv[1]).read().split("\n")
assert ("--resume", sys.argv[2]) in list(zip(argv, argv[1:])), argv
PY
  FAKE_MARKER="Gamma orientation: ready" run --separate-stderr bash "$CALL" --resume "$id" --to gamma "same key"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  run bash "$CALL" --resume "$id" --to alpha "another key"
  [ "$status" -eq 2 ]
  case "$output" in *"call $id went to callee gamma; a resume keeps its callee (--to alpha refused) — start a new call"*) : ;; *) echo "$output"; return 1 ;; esac
  G2="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/home-gamma-2"; mkdir -p "$G2"
  sed -i.bak "s|home: $G\$|home: $G2|" "$DAEDALUS_HOME/config.yaml"
  grep -q "home: $G2" "$DAEDALUS_HOME/config.yaml"
  run bash "$CALL" --resume "$id" "after the move"
  [ "$status" -eq 2 ]
  case "$output" in *"the configured callee changed since call $id; start a new call"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" -eq 3 ]
}

@test "SPEC-011 criterion 4: a reserved or malformed key, a duplicate (legacy + same key), and every per-field rule is one MISSING line in doctor and the same sentence as the launcher's refusal" {
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/base.yaml"
  H="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/home-x"; mkdir -p "$H"
  printf 'not executable\n' > "$H/plain"
  printf '#!/bin/sh\nexit 0\n' > "$H/launcher"; chmod +x "$H/launcher"
  ok="name: X|home: $H"
  # case: the --to a call names | the block's lines, |-separated (the first line is the block's own)
  cases=(
    "x|callee_X:|$ok"
    "x|callee_self:|$ok"
    "x|callee_9x:|$ok"
    "x|callee_x: value|$ok"
    "x|LEGACY|callee_x:|$ok"
    "x|callee_x:|name: X"
    "x|callee_x:|home: $H"
    "x|callee_x:|consult_for: something"
    "x|callee_x:|name: X|home: relative/path"
    "x|callee_x:|name: X|home: $H/nowhere"
    "x|callee_x:|$ok|launcher: $H/plain"
    "x|callee_x:|$ok|launcher_args: --callee x"
    "x|callee_x:|$ok|launcher: $H/launcher|launcher_args: --x 'unclosed"
    "x|callee_x:|$ok|launcher: $H/launcher|launcher_args: --caller Someone"
    "x|callee_x:|$ok|launcher_call_id: 'call (\\S+)'"
    "x|callee_x:|$ok|launcher_oriented: 'recall: available'"
    "x|callee_x:|$ok|launcher: $H/launcher|launcher_call_id: 'call ([a-z'"
    "x|callee_x:|$ok|launcher: $H/launcher|launcher_call_id: 'call \\S+'"
    "x|callee_x:|$ok|launcher: $H/launcher|launcher_oriented: '(unclosed'"
    "x|callee_x:|$ok|tools: Read,Bash"
    "x|callee_x:|$ok|max_turns: 0"
    "x|callee_x:|$ok|capture_wait: 301"
    "x|callee_x:|$ok|timeout: ten"
    "x|callee_x:|$ok|capture: maybe"
  )
  for c in "${cases[@]}"; do
    cp "$BATS_TEST_TMPDIR/base.yaml" "$DAEDALUS_HOME/config.yaml"
    IFS='|' read -r -a parts <<< "$c"
    to="${parts[0]}"; rest=("${parts[@]:1}")
    if [ "${rest[0]}" = "LEGACY" ]; then
      direct_call "callee_home: $H" "callee_name: X"; rest=("${rest[@]:1}")
    fi
    { printf '%s\n' "${rest[0]}"; for l in "${rest[@]:1}"; do printf '  %s\n' "$l"; done; } >> "$DAEDALUS_HOME/config.yaml"
    run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
    [ "$status" -eq 0 ]
    missing="$(printf '%s\n' "$output" | grep '^MISSING  direct call: ' || true)"
    [ "$(printf '%s\n' "$missing" | grep -c .)" -eq 1 ] || { echo "case [$c]: want one MISSING line: $output"; return 1; }
    run --separate-stderr bash "$CALL" --callee agent --to "$to" "hello"
    [ "$status" -eq 2 ] || { echo "case [$c]: exit $status: $stderr"; return 1; }
    [ "$stderr" = "daedalus: ${missing#MISSING  direct call: }" ] || { echo "case [$c]: doctor [$missing] launcher [$stderr]"; return 1; }
  done
  [ "$(calls)" -eq 0 ]
}

@test "SPEC-011 criterion 5: session start lists the configured callees in one line, with consult_for or its absence; none configured, nothing" {
  start_context() {
    python3 - "$DAEDALUS_HOME" "$1" <<'PY'
import json, os, subprocess, sys
payload = json.dumps({"hook_event_name": "SessionStart", "session_id": sys.argv[2], "source": "startup",
                      "transcript_path": "/dev/null"})
p = subprocess.run(["python3", sys.argv[1] + "/core/session-start.py"], input=payload, capture_output=True, text=True)
print(json.loads(p.stdout)["hookSpecificOutput"]["additionalContext"])
PY
  }
  run start_context s-none
  [ "$status" -eq 0 ]
  case "$output" in *"Agents you may consult"*) echo "a line with no callee: $output"; return 1 ;; esac
  two_callees
  callee_block delta "name: Delta" "home: $CALLEE"
  run start_context s-three
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^Agents you may consult')" -eq 1 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qxF "Agents you may consult (core/call-agent.sh --callee agent --to <key>): alpha — the history of the target and why a thing was built; gamma — an independent design pass on a brief; delta — (no consult_for set)" \
    || { echo "$output"; return 1; }
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"NOTE     direct call: callee delta has no consult_for — it is callable but Daedalus has no reason on file to choose it"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "SPEC-011 criterion 6: a callee's own knob beats direct_call's — callee_gamma.timeout: 1200 over direct_call.timeout, and a callee's short timeout kills its call while the shared one is long" {
  two_callees
  direct_call "timeout: 600"
  sed -i.bak "s|^  marker: 'Gamma orientation:'|  marker: 'Gamma orientation:'\n  timeout: 1200|" "$DAEDALUS_HOME/config.yaml"
  PYTHONDONTWRITEBYTECODE=1 python3 - "$DAEDALUS_HOME" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/core")
import call_agent as ca
from pathlib import Path
t = ca.callee_table(ca.read_config(Path(sys.argv[1])))
by = {e["key"]: e["settings"] for e in t["callees"]}
assert by["gamma"]["timeout"] == 1200 and by["alpha"]["timeout"] == 600, by
assert t["shared"]["timeout"] == 600, t["shared"]
PY
  sed -i.bak 's|^  timeout: 1200|  timeout: 1|' "$DAEDALUS_HOME/config.yaml"
  t0="$(date +%s)"
  FAKE_SLEEP=3 run --separate-stderr bash "$CALL" --callee agent --to gamma "hello"
  [ "$status" -eq 124 ] || { echo "$status / $stderr"; return 1; }
  case "${stderr_lines[1]}" in *"; exit: 124 — timed out after 1s; killed with its process group"*) : ;; *) echo "$stderr"; return 1 ;; esac
  [ "$(( $(date +%s) - t0 ))" -lt 20 ]
}

@test "doctor, one line per callee: OK with its home, launcher and consult_for; the allowlist where core can read it (admits, refuses, none), or enforced by the callee's own launcher" {
  two_callees
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  [ "$status" -eq 0 ]
  for want in \
    "OK       direct call: callee alpha (Alpha) at $A through its own launcher (with --callee alpha); consult for: the history of the target and why a thing was built" \
    "OK       direct call: callee gamma (Gamma) at $G; consult for: an independent design pass on a brief" \
    "OK       direct call: callee alpha allowlist: enforced by its own launcher, not checked without a call" \
    "NOTE     direct call: callee gamma allowlist: none found (no direct_calls in agent.yaml, no .direct-callers); a call proceeds and its receipt says so"; do
    printf '%s\n' "$output" | grep -qxF -- "$want" || { echo "lacks [$want]: $output"; return 1; }
  done
  printf 'name: gamma\ndirect_calls:\n  callers: [Daedalus]\n' > "$G/agent.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  printf '%s\n' "$output" | grep -qxF "OK       direct call: callee gamma allowlist: agent.yaml direct_calls.callers admits Daedalus" || { echo "$output"; return 1; }
  printf 'name: gamma\ndirect_calls:\n  callers: [Peer]\n' > "$G/agent.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  printf '%s\n' "$output" | grep -qxF "MISSING  direct call: callee gamma allowlist: agent.yaml direct_calls.callers does not admit Daedalus — a call to it is refused until it does" || { echo "$output"; return 1; }
  run bash "$CALL" --callee agent --to gamma "hello"
  [ "$status" -eq 2 ]; case "$output" in *"Daedalus is not on Gamma's callers list (agent.yaml direct_calls.callers)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a callee launcher's receipt: unset patterns keep today's contract; launcher_call_id and launcher_oriented read a receipt of another shape — the call id it resumes by, orientation yes on the configured line, unverified (exit 3) without it" {
  H="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/home-gamma"; mkdir -p "$H"
  cp "$BATS_TEST_DIRNAME/fixtures/caller/callee-launcher" "$H/launcher"
  # unset: today's "<Name> call <uuid>" and "orientation: yes"; the other shape has neither
  callee_block gamma "name: Gamma" "home: $H" "launcher: $H/launcher" "launcher_args: --callee gamma" "consult_for: review"
  run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "${stderr_lines[1]}" = "Gamma orientation: yes; capture: deferred; exit: 0" ]
  grep -q '"callee_receipt": "0f0f0f0f-1111-2222-3333-444444444444"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  rm -rf "$DAEDALUS_HOME"/state/direct-calls/*
  CALLEE_LAUNCHER_SHAPE=other run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 3 ] || { echo "$status / $stderr"; return 1; }
  [ "${stderr_lines[1]}" = "Gamma orientation: unverified; capture: deferred; exit: 3" ]
  ! grep -q '"callee_receipt"' "$DAEDALUS_HOME"/state/direct-calls/*/launch.json
  rm -rf "$DAEDALUS_HOME"/state/direct-calls/*
  # configured for the other shape
  printf "  launcher_call_id: '^Gamma call (\\\\S+); status and answer files in '\n  launcher_oriented: 'Gamma recall: available;'\n" >> "$DAEDALUS_HOME/config.yaml"
  CALLEE_LAUNCHER_SHAPE=other run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 0 ] || { echo "$status / $stderr"; cat "$DAEDALUS_HOME/config.yaml"; return 1; }
  [ "$output" = "callee launcher answer" ]
  [ "${stderr_lines[1]}" = "Gamma orientation: yes; capture: deferred; exit: 0" ]
  id="$(printf '%s\n' "${stderr_lines[0]}" | sed -n 's/^Gamma call \([0-9a-f-]*\);.*/\1/p')"; [ -n "$id" ]
  grep -q '"callee_receipt": "g-20261017-0001"' "$DAEDALUS_HOME/state/direct-calls/$id/launch.json"
  CALLEE_LAUNCHER_SHAPE=other run --separate-stderr bash "$CALL" --resume "$id" "and then?"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(grep -A1 -x -- '--resume' "$FAKE_CLAUDE_DIR/launcher-argv.txt" | tail -1)" = "g-20261017-0001" ]
  # its orientation line absent or another value: unverified, the answer still printed, exit 3
  CALLEE_LAUNCHER_SHAPE=other CALLEE_LAUNCHER_RECALL=unavailable run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 3 ] || { echo "$status / $stderr"; return 1; }
  [ "$output" = "callee launcher answer" ]
  [ "${stderr_lines[1]}" = "Gamma orientation: unverified; capture: deferred; exit: 3" ]
  # a launcher's exit 3 with no answer is still a failure, whatever its receipt says
  CALLEE_LAUNCHER_SHAPE=other CALLEE_LAUNCHER_EXIT=3 CALLEE_LAUNCHER_ANSWER= run --separate-stderr bash "$CALL" --callee agent "hello"
  [ "$status" -eq 1 ] || { echo "$status / $stderr"; return 1; }
  [ "$(calls)" -eq 0 ]
}

# --- the distribution docs (Task 10) ------------------------------------------------

@test "README, CLAUDE.md and CHANGELOG describe the launcher, the callee-from-config rule, the receipt and --resume-review — in plain language" {
  R="$BATS_TEST_DIRNAME/../.."
  for s in 'core/call-agent.sh' 'direct_call.callee_home' '--resume-review 02' 'DAEDALUS_LIVE_CANARY=1' 'orientation: yes; capture: confirmed; exit: 0'; do
    grep -qF -- "$s" "$R/README.md" || { echo "README lacks: $s"; return 1; }
  done
  grep -qF -- '--resume-review <NN>' "$R/CLAUDE.md"
  grep -qF '## Direct calls' "$R/CLAUDE.md"
  grep -qF 'The direct-call launcher' "$R/CHANGELOG.md"
  ! grep -qF 'keep it free of anything that would steer a reviewer' "$R/README.md"
}

@test "the refuter's claudeMdExcludes names CLAUDE.local.md beside CLAUDE.md, so a deployment's local brief never reaches a review (update design §4.4)" {
  PYTHONDONTWRITEBYTECODE=1 python3 - "$BATS_TEST_DIRNAME/.." <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import call_agent as ca
assert "**/CLAUDE.local.md" in ca.CLAUDE_MD_EXCLUDES and "**/CLAUDE.md" in ca.CLAUDE_MD_EXCLUDES, ca.CLAUDE_MD_EXCLUDES
assert json.loads(ca.REFUTER_SETTINGS)["claudeMdExcludes"] == ca.CLAUDE_MD_EXCLUDES
PY
}
