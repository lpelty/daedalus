#!/usr/bin/env bats
#
# Pins core/close.sh — the explicit end-of-session flush.
#
# Capture runs today only if the SessionEnd hook fires. A session that ends
# uncleanly never fires it, and the conversation is gone from working memory
# either way. close.sh removes the dependency on a hook firing.

# Wall-clock assertions live in this file: under the parallel full-suite gate
# (`bats --jobs 12`) its tests run one at a time, while other files run beside it.
BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/close.sh" "$SRC/capture.py" "$DAEDALUS_HOME/core/" 2>/dev/null || true
  export DAEDALUS_HOME
  CLOSE="$DAEDALUS_HOME/core/close.sh"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/t.git
  branch: main
vault:
  repo: https://example.com/kb.git
gates:
  - true
proposals:
  budget: 5
EOF
  exec </dev/null
  unset CAPTURE_DEFER_TO_CALLER DIRECT_CALL_ID
}

teardown() {
  stop_stub
}

seed_transcript() {
  export TRANSCRIPT_DIR_FIXTURE="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$TRANSCRIPT_DIR_FIXTURE"
  cat > "$TRANSCRIPT_DIR_FIXTURE/session-a.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"what did we decide about the scheduler"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"It executes rendered goal files."}]}}
EOF
}

configure_capture() {
  export TENANT_HOME="$DAEDALUS_HOME"
  export TENANT_BANK="testbank"
  export TRANSCRIPT_DIR="$BATS_TEST_TMPDIR/transcripts"
  export HINDSIGHT_API_URL="http://127.0.0.1:1"
  export HINDSIGHT_API_TENANT_API_KEY="not-a-real-key"
  seed_transcript
  export CLAUDE_CODE_SESSION_ID="session-a"
}

@test "close.sh exists and is executable" {
  [ -x "$CLOSE" ]
}

@test "close fails loudly when the capture environment is absent" {
  run env -u TENANT_HOME -u TENANT_BANK -u TRANSCRIPT_DIR bash "$CLOSE"
  [ "$status" -ne 0 ]
  case "$output" in
    *TENANT_*|*capture*) : ;;
    *) echo "expected the failure to name what is missing; got: $output"; return 1 ;;
  esac
}

@test "close names the specific variable that is missing" {
  # A message saying only "configuration missing" sends the reader to the
  # whole README instead of one line of it.
  configure_capture
  run env -u TENANT_BANK bash "$CLOSE"
  [ "$status" -ne 0 ]
  run grep -qF "TENANT_BANK" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "close checks the environment itself, before invoking capture" {
  # capture.py also validates and exits 2, so a close with no check of its
  # own still fails — but with capture.py's wording and only after the
  # process starts. This pins that close.sh owns the check: its message
  # points at the README section a reader needs.
  configure_capture
  run env -u TENANT_BANK bash "$CLOSE"
  [ "$status" -ne 0 ]
  run grep -qF "README" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "close reports the phase it runs" {
  # Matches the phase counter specifically. A bare "capture" would also
  # match capture.py's own output, so removing close.sh's log line would
  # leave the test green.
  configure_capture
  run bash "$CLOSE"
  run grep -qE "phase [0-9]+/[0-9]+" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "close fails when capture fails" {
  # The backend is unreachable here. A close that reports success while the
  # session went unrecorded is the false green this project has shipped six
  # times.
  configure_capture
  run bash "$CLOSE"
  [ "$status" -ne 0 ]
}

@test "close says the session is unrecorded when capture fails" {
  configure_capture
  run bash "$CLOSE"
  run grep -qiE "unrecorded|failed" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "close succeeds and reports completion when capture succeeds" {
  configure_capture
  start_stub
  run bash "$CLOSE"
  stop_stub
  [ "$status" -eq 0 ]
  run grep -qiF "complete" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "close is safe to run twice" {
  # It shares capture.py's offset, so a second run is a no-op rather than a
  # duplicate ingest. Running it after the SessionEnd hook already fired is
  # the normal case.
  configure_capture
  start_stub
  run bash "$CLOSE"
  [ "$status" -eq 0 ]
  run bash "$CLOSE"
  stop_stub
  [ "$status" -eq 0 ]
}

# A local stub standing in for the memory backend. Logs every request as
# "<METHOD> <path>" to requests.log and every POST body to posts.jsonl, so a
# test can see which bank and which session were written. Each POST gets its
# own operation id (stub-op-1, stub-op-2, ...); GET .../operations/<id> is
# "running" for an id listed in $BATS_TEST_TMPDIR/running_ops, else
# "completed" (Task 10's whole-session close test uses the knob).
start_stub() {
  : > "$BATS_TEST_TMPDIR/requests.log"; : > "$BATS_TEST_TMPDIR/posts.jsonl"
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json, os, itertools
from http.server import BaseHTTPRequestHandler, HTTPServer
tmp = sys.argv[2]
counter = itertools.count(1)

class H(BaseHTTPRequestHandler):
    # Speaks the PROP-002 verify-extraction protocol close.sh depends on:
    # the retain POST returns an operation_id, and capture then polls
    # GET .../operations/<id> until the status is terminal.
    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _log(self):
        with open(os.path.join(tmp, "requests.log"), "a") as f:
            f.write("%s %s\n" % (self.command, self.path))
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode()
        self._log()
        with open(os.path.join(tmp, "posts.jsonl"), "a") as f:
            f.write(raw.replace("\n", " ") + "\n")
        self._json({"success": True, "items_count": 1, "async": True,
                    "operation_id": "stub-op-%d" % next(counter)})
    def do_GET(self):
        self._log()
        knob = os.path.join(tmp, "running_ops")
        running = set(open(knob).read().split()) if os.path.exists(knob) else set()
        op = self.path.rsplit("/", 1)[-1]
        self._json({"status": "running" if op in running else "completed",
                    "extraction_errors_count": 0})
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  STUB_PID=$!
  i=0
  while [ "$i" -lt 50 ]; do
    if python3 -c "import socket,sys;s=socket.socket();s.settimeout(0.2);sys.exit(0 if s.connect_ex(('127.0.0.1',$STUB_PORT))==0 else 1)"; then
      break
    fi
    i=$((i + 1))
  done
  export HINDSIGHT_API_URL="http://127.0.0.1:$STUB_PORT"
}

stop_stub() {
  # An unset STUB_PID makes `wait` block on EVERY child instead of one.
  [ -n "${STUB_PID:-}" ] || return 0
  disown "$STUB_PID" 2>/dev/null || true
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
}

@test "close.sh --commit runs core/vault-commit.sh after a successful capture, and not when capture fails" {
  cp "$SRC/vault-commit.sh" "$DAEDALUS_HOME/core/"
  printf '#!/usr/bin/env bash\necho VAULT-COMMIT-RAN\n' > "$DAEDALUS_HOME/core/vault-commit.sh"
  configure_capture; start_stub
  run bash "$CLOSE" --commit; [ "$status" -eq 0 ]; case "$output" in *VAULT-COMMIT-RAN*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"phase 1/2"*"phase 2/2"*) : ;; *) echo "expected two phases: $output"; return 1 ;; esac
  stop_stub
  # New transcript bytes past the stored offset: with nothing new, capture.py
  # never touches the backend and exits 0, and the failure leg would prove nothing.
  printf '{"type":"user","message":{"role":"user","content":"one more turn"}}\n' >> "$TRANSCRIPT_DIR/session-a.jsonl"
  run bash "$CLOSE" --commit; [ "$status" -ne 0 ]; case "$output" in *VAULT-COMMIT-RAN*) echo "must not commit after a failed capture: $output"; return 1 ;; *) : ;; esac
}

# --- the memory: block is the source (spec §4.7 "one place") ----------------
# A Bash tool carries none of the TENANT_* variables, so close.sh from a
# session used to die at its own environment check unless the operator had
# exported them in the shell that started Claude Code.
memory_block() {   # memory_block <bank> — after start_stub: points at the stub
  cat >> "$DAEDALUS_HOME/config.yaml" <<EOF
memory:
  bank: $1
  api_url: $HINDSIGHT_API_URL
  transcript_dir: $BATS_TEST_TMPDIR/transcripts
EOF
}

@test "close with no capture variables in the environment and a memory: block in config.yaml captures" {
  seed_transcript; start_stub; memory_block blockbank
  run env -u TENANT_HOME -u TENANT_BANK -u TRANSCRIPT_DIR -u HINDSIGHT_API_URL -u HINDSIGHT_API_TENANT_API_KEY \
      CLAUDE_CODE_SESSION_ID=session-a bash "$CLOSE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^POST /v1/default/banks/blockbank/memories' "$BATS_TEST_TMPDIR/requests.log"
  case "$output" in *"close complete"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "close with neither a memory: block nor the variables dies naming memory: and the README section" {
  seed_transcript
  run env -u TENANT_HOME -u TENANT_BANK -u TRANSCRIPT_DIR -u HINDSIGHT_API_URL CLAUDE_CODE_SESSION_ID=session-a bash "$CLOSE"
  [ "$status" -ne 0 ]
  case "$output" in *"memory.bank"*"README"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "an environment variable overrides the memory: block's field for close" {
  seed_transcript; start_stub; memory_block blockbank
  run env -u TENANT_HOME -u TRANSCRIPT_DIR -u HINDSIGHT_API_URL -u HINDSIGHT_API_TENANT_API_KEY \
      TENANT_BANK=envbank CLAUDE_CODE_SESSION_ID=session-a bash "$CLOSE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^POST /v1/default/banks/envbank/memories' "$BATS_TEST_TMPDIR/requests.log"
  run grep -q 'blockbank' "$BATS_TEST_TMPDIR/requests.log"; [ "$status" -ne 0 ]
}

@test "close --transcript names the session from an operator shell (no session id): it captures that file and exits 0" {
  configure_capture; start_stub
  unset CLAUDE_CODE_SESSION_ID
  run bash "$CLOSE" --transcript "$BATS_TEST_TMPDIR/transcripts/session-a.jsonl"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'session session-a' "$BATS_TEST_TMPDIR/posts.jsonl"
  case "$output" in *"close complete"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "close from an operator shell without --transcript refuses to guess, names close.sh --transcript, and never says close complete" {
  configure_capture; start_stub
  unset CLAUDE_CODE_SESSION_ID
  run bash "$CLOSE"
  [ "$status" -ne 0 ]
  case "$output" in *"refusing to guess"*"core/close.sh --transcript"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"close complete"*) echo "$output"; return 1 ;; *) : ;; esac
  [ ! -s "$BATS_TEST_TMPDIR/posts.jsonl" ]
}

@test "close from a Bash-tool environment captures its own session's transcript, not the newest" {
  configure_capture; start_stub
  printf '{"type":"user","message":{"role":"user","content":"another window"}}\n' > "$BATS_TEST_TMPDIR/transcripts/session-z.jsonl"
  touch -t 203001010000 "$BATS_TEST_TMPDIR/transcripts/session-z.jsonl"
  CLAUDE_CODE_SESSION_ID=session-a run bash "$CLOSE"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q 'session session-a' "$BATS_TEST_TMPDIR/posts.jsonl"
  run grep -q 'session-z' "$BATS_TEST_TMPDIR/posts.jsonl"; [ "$status" -ne 0 ]
}
