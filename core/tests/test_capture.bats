#!/usr/bin/env bats
#
# Pins capture.py's offset discipline. The byte offset is a read cursor: if
# it advances past bytes that were never stored, those bytes are lost
# permanently and nothing reports it.
#
# The guard is already correct — _capture_path returns before persisting
# when the POST fails. These tests exist because nothing pinned it, so a
# reordering would have shipped silently green.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CAPTURE="$ROOT/core/capture.py"
  export TENANT_HOME="$BATS_TEST_TMPDIR/home"
  export TENANT_BANK="testbank"
  export TRANSCRIPT_DIR="$BATS_TEST_TMPDIR/transcripts"
  export HINDSIGHT_API_URL="http://127.0.0.1:1"   # nothing listens here
  export HINDSIGHT_API_TENANT_API_KEY="not-a-real-key"
  mkdir -p "$TENANT_HOME" "$TRANSCRIPT_DIR"

  TRANSCRIPT="$TRANSCRIPT_DIR/session-a.jsonl"
  cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"what did we decide about the scheduler"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"It executes rendered goal files rather than the manifest."}]}}
EOF
  OFFSETS="$TENANT_HOME/state/hindsight/offsets.json"
}

# Runs even when a test fails. Without this, a failing test skips its
# stop_stub call and the orphaned server holds the run open — which is how
# a mutation run stalled past a two-minute wall instead of reporting red.
teardown() {
  stop_stub
}

# Reads the stored offset for the fixture transcript. Prints 0 when the
# state file or the entry is absent — the same thing capture.py assumes.
stored_offset() {
  python3 - "$OFFSETS" "$TRANSCRIPT" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print(0); raise SystemExit
d = json.loads(p.read_text() or "{}")
print(d.get("offsets", {}).get(sys.argv[2], 0))
PY
}

@test "a failed write leaves the offset at zero" {
  run python3 "$CAPTURE" capture
  [ "$(stored_offset)" = "0" ]
}

@test "a failed write exits non-zero" {
  # The exit code is the only signal a caller can act on. capture.py used
  # to print "retain FAILED" and exit 0, so core/close.sh reported success
  # for a session that was never recorded.
  run python3 "$CAPTURE" capture
  [ "$status" -ne 0 ]
}

@test "a successful write exits zero" {
  start_stub
  run python3 "$CAPTURE" capture
  stop_stub
  [ "$status" -eq 0 ]
}

@test "a run with nothing new exits zero" {
  # Idempotence is success, not failure — the SessionEnd hook and an
  # explicit close both run capture, and the second must not report an error.
  start_stub
  run python3 "$CAPTURE" capture
  run python3 "$CAPTURE" capture
  stop_stub
  [ "$status" -eq 0 ]
}

@test "a failed write says so on stdout" {
  run python3 "$CAPTURE" capture
  run grep -qF "retain FAILED" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "a repeated failure still leaves the offset at zero" {
  # The failure mode this guards is cumulative: each failed run that
  # advanced the cursor would strand another block of bytes.
  run python3 "$CAPTURE" capture
  run python3 "$CAPTURE" capture
  [ "$(stored_offset)" = "0" ]
}

@test "a successful write advances the offset to the file size" {
  start_stub
  run python3 "$CAPTURE" capture
  stop_stub
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  [ "$(stored_offset)" = "$size" ]
}

@test "a second successful run captures nothing new" {
  # Idempotence: the offset exists so re-running over an unchanged
  # transcript is a no-op rather than a duplicate ingest.
  start_stub
  run python3 "$CAPTURE" capture
  run python3 "$CAPTURE" capture
  stop_stub
  run grep -qF "nothing new" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "bytes stranded by a failed write are re-read by the next success" {
  # The whole point of holding the cursor. Fail once, then succeed, and
  # the offset must jump from 0 to the full size — not from a partially
  # advanced position that skipped the failed run's bytes.
  run python3 "$CAPTURE" capture      # fails: backend unreachable
  [ "$(stored_offset)" = "0" ]

  start_stub
  run python3 "$CAPTURE" capture
  stop_stub
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  [ "$(stored_offset)" = "$size" ]
  run grep -qF "offset 0->$size" <<< "$output"
  [ "$status" -eq 0 ]
}

# A local stub standing in for the memory backend, so the success path can
# be exercised without a live server.
start_stub() {
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        body = json.dumps({"success": True, "items_count": 1}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
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
  # An unset STUB_PID makes `wait` block on EVERY child instead of one, so
  # a teardown for a test that never started a stub would hang the run.
  # Guard on the variable, and clear it so a second call is a no-op.
  [ -n "${STUB_PID:-}" ] || return 0
  disown "$STUB_PID" 2>/dev/null || true
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
}
