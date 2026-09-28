# core/tests/fixtures/caller/setup.bash — loaded by test_call_agent.bats and test_refuter_charter.bats.
# Builds on lease_fixture (a Daedalus home that is a git checkout with core/
# committed, a target with an origin, a vault) and adds the launcher, the
# refuter's charter and renderer, the fingerprint, doctor, a recording stub
# for capture.py, and the fake claude first on PATH. The home is committed
# again afterwards: the launcher refuses when distribution code is modified.
load fixtures/leases/setup.bash

caller_fixture() {
  lease_fixture
  local src; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core/agents"
  # Whatever of the launcher's files this build has (later tasks add some).
  for f in call-agent.sh call_agent.py agentdef.py fingerprint.sh doctor.sh refute.sh refute-pitfalls.py review-inputs.py; do
    [ -f "$src/$f" ] && cp "$src/$f" "$DAEDALUS_HOME/core/"
  done
  cp "$src/agents/refuter.md" "$DAEDALUS_HOME/core/agents/"
  # capture.py stand-in: records the environment and argv the launcher's
  # re-capture gives it, and prints $STUB_CAPTURE_OUT (default a confirmation).
  cat > "$DAEDALUS_HOME/core/capture.py" <<'PY'
import json, os, sys
out = os.environ.get("CAPTURE_LOG")
if out:
    keep = {k: v for k, v in os.environ.items() if k.startswith(("TENANT_", "TRANSCRIPT_", "CAPTURE_", "DIRECT_CALL_"))}
    with open(out, "w") as fh:
        json.dump({"argv": sys.argv[1:], "env": keep}, fh)
print(os.environ.get("STUB_CAPTURE_OUT", "capture: extraction confirmed (stub)"))
sys.exit(int(os.environ.get("STUB_CAPTURE_EXIT", "0")))
PY
  # The product repo ignores bytecode (.gitignore: __pycache__/); so does the
  # fixture, keeping git status quiet. The integrity check never asks git what
  # is ignored: it skips __pycache__/ itself and nothing it launches reads one.
  printf '__pycache__/\n*.pyc\n' >> "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add -A
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m caller
  FAKE_CLAUDE_DIR="$BATS_TEST_TMPDIR/fake"; mkdir -p "$FAKE_CLAUDE_DIR"
  PATH="$BATS_TEST_DIRNAME/fixtures/caller/bin:$PATH"
  CALLEE="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/callee"; mkdir -p "$CALLEE"
  CALL="$DAEDALUS_HOME/core/call-agent.sh"
  # Never the machine's real memory server: the default capture.py would reach
  # (127.0.0.1:8888) may be live. Port 1 refuses at once.
  HINDSIGHT_API_URL=http://127.0.0.1:1
  export FAKE_CLAUDE_DIR PATH CALLEE CALL HINDSIGHT_API_URL
  unset CAPTURE_DEFER_TO_CALLER DIRECT_CALL_RECEIPT_DIR DIRECT_CALL_CALLER TENANT_BANK TENANT_HOME \
        TRANSCRIPT_DIR FAKE_ANSWER FAKE_EXIT FAKE_MARKER FAKE_MARKER_SHAPE FAKE_MARKER_EVENT FAKE_TOOL_RESULT FAKE_SLEEP FAKE_IS_ERROR CAPTURE_LOG STUB_CAPTURE_OUT
}

# direct_call <lines...> — append a direct_call: block to the fixture config.
direct_call() {
  { printf 'direct_call:\n'; for l in "$@"; do printf '  %s\n' "$l"; done; } >> "$DAEDALUS_HOME/config.yaml"
}

# calls — how many times the fake claude ran.
calls() { ls "$FAKE_CLAUDE_DIR"/*.argv 2>/dev/null | wc -l | tr -d ' '; }
