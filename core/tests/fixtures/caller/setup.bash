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
  for f in call-agent.sh call_agent.py distcheck.py agentdef.py fingerprint.sh doctor.sh refute.sh refute-pitfalls.py review-inputs.py review-lenses.py; do
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
  unset CAPTURE_DEFER_TO_CALLER DIRECT_CALL_ID DIRECT_CALL_RECEIPT_DIR DIRECT_CALL_CALLER TENANT_BANK TENANT_HOME \
        TRANSCRIPT_DIR FAKE_ANSWER FAKE_EXIT FAKE_MARKER FAKE_MARKER_SHAPE FAKE_MARKER_EVENT FAKE_TOOL_RESULT FAKE_SLEEP FAKE_IS_ERROR FAKE_HOOK CAPTURE_LOG STUB_CAPTURE_OUT STUB_CAPTURE_EXIT
}

# direct_call <lines...> — append a direct_call: block to the fixture config.
direct_call() {
  { printf 'direct_call:\n'; for l in "$@"; do printf '  %s\n' "$l"; done; } >> "$DAEDALUS_HOME/config.yaml"
}

# calls — how many times the fake claude ran.
calls() { ls "$FAKE_CLAUDE_DIR"/*.argv 2>/dev/null | wc -l | tr -d ' '; }

# refuter_fixture — a fresh caller_fixture with something to review in the
# target (an uncommitted edit), an evidence summary outside the evidence tree
# (as gates.sh hands one over) and run 20261021-000000-0000a1's run.json; the fake claude answers
# STANDS. review [run-id] runs refute.sh on it.
refuter_fixture() {
  rm -rf "$BATS_TEST_TMPDIR/dae" "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/sub-origin.git" "$BATS_TEST_TMPDIR/fake"
  caller_fixture
  T="$DAEDALUS_HOME/target/thing"
  printf 'changed\n' >> "$T/a.txt"                          # something to review
  printf -- '---\ntype: evidence\nrun-id: 20261021-000000-0000a1\nresult: PASS\n---\n# Gate run 20261021-000000-0000a1 — PASS\n' > "$BATS_TEST_TMPDIR/evidence.md"
  mkdir -p "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a1"
  printf '{"run_id":"20261021-000000-0000a1","lease":null,"result":"PASS"}' > "$DAEDALUS_HOME/state/evidence/20261021-000000-0000a1/run.json"
  export FAKE_ANSWER="F1 — nothing found.
VERDICT: STANDS"
  # No managed policy CLAUDE.md, whatever machine runs the suite (Decision 17).
  export DAEDALUS_MANAGED_CLAUDE_MD_PATHS="$BATS_TEST_TMPDIR/no-managed-CLAUDE.md"
}
review() { run --separate-stderr bash "$DAEDALUS_HOME/core/refute.sh" "${1:-20261021-000000-0000a1}" "" "$BATS_TEST_TMPDIR/evidence.md"; }

# isolation_problems <n> — every isolation property of the reviewer's launch
# (spec §6.1) that the fake claude's call n lacks, one per line; empty when
# all hold. One definition for the launch test and for the mutation test
# that proves these assertions catch a launcher with a property removed.
isolation_problems() {
  python3 - "$FAKE_CLAUDE_DIR/$1.argv" "$FAKE_CLAUDE_DIR/$1.env.json" "$T" <<'PY'
import json, sys
argv = open(sys.argv[1]).read().split("\n"); pairs = list(zip(argv, argv[1:]))
env = json.load(open(sys.argv[2])); out = []
raw = [b for a, b in pairs if a == "--settings"]
s = json.loads(raw[0]) if raw else {}
if s.get("disableAllHooks") is not True: out.append("hooks: disableAllHooks is not true")
if s.get("autoMemoryEnabled") is not False: out.append("auto memory: autoMemoryEnabled is not false")
if set(s.get("claudeMdExcludes") or []) != {"**/CLAUDE.md", "**/CLAUDE.local.md", "**/.claude/rules/**", "**/AGENTS.md"}:
    out.append("CLAUDE.md: claudeMdExcludes is not the four globs")
if env.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY") != "1": out.append("auto memory: CLAUDE_CODE_DISABLE_AUTO_MEMORY is not 1")
if "--strict-mcp-config" not in argv: out.append("MCP: no --strict-mcp-config")
if ("--tools", "Read,Grep,Glob") not in pairs: out.append("tools: not Read,Grep,Glob")
if ("--add-dir", sys.argv[3]) not in pairs: out.append("tree: no --add-dir pair for the tree")
print("\n".join(out))
PY
}
