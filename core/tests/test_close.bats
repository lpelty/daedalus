#!/usr/bin/env bats
#
# Pins core/close.sh — the explicit end-of-session flush.
#
# Capture runs today only if the SessionEnd hook fires. A session that ends
# uncleanly never fires it, and the conversation is gone from working memory
# either way. close.sh removes the dependency on a hook firing.

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
}

teardown() {
  stop_stub
}

configure_capture() {
  export TENANT_HOME="$DAEDALUS_HOME"
  export TENANT_BANK="testbank"
  export TRANSCRIPT_DIR="$BATS_TEST_TMPDIR/transcripts"
  export HINDSIGHT_API_URL="http://127.0.0.1:1"
  export HINDSIGHT_API_TENANT_API_KEY="not-a-real-key"
  mkdir -p "$TRANSCRIPT_DIR"
  cat > "$TRANSCRIPT_DIR/session-a.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"what did we decide about the scheduler"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"It executes rendered goal files."}]}}
EOF
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

# A local stub standing in for the memory backend.
start_stub() {
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    # Speaks the PROP-002 verify-extraction protocol close.sh depends on:
    # the retain POST returns an operation_id, and capture then polls
    # GET .../operations/<id> until the status is terminal. The original
    # stub predated that protocol (no operation_id, no GET handler), which
    # left these two tests red from PROP-002's reapply until 2026-09-01.
    def _json(self, obj):
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        self._json({"success": True, "items_count": 1, "async": True,
                    "operation_id": "stub-op-1"})
    def do_GET(self):
        self._json({"status": "completed", "extraction_errors_count": 0})
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
