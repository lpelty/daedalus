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
    | sed "s|callee_home: .*|callee_home: $CALLEE|; s|callee_launcher: .*|callee_launcher: /usr/bin/true|" >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$DAEDALUS_HOME/core/call_agent.py" --doctor
  case "$output" in *"OK       direct call: callee AgentName at $CALLEE through its own launcher (with --callee agentname); callers of this Daedalus: AgentName"*) : ;; *) echo "$output"; cat "$DAEDALUS_HOME/config.yaml"; return 1 ;; esac
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
