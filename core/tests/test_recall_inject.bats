#!/usr/bin/env bats
#
# Pins the injector's silence guarantees. Recall is an enhancement; a
# session must run without it. Every failure path — unreachable backend,
# malformed stdin, empty prompt, missing configuration — exits 0 and emits
# nothing. A hook that errors is a hook a deployment disables.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  INJECT="$ROOT/core/recall-inject.py"
  export TENANT_HOME="$BATS_TEST_TMPDIR/home"
  export TENANT_BANK="testbank"
  export TRANSCRIPT_DIR="$BATS_TEST_TMPDIR/transcripts"
  export HINDSIGHT_API_URL="http://127.0.0.1:1"   # nothing listens here
  export HINDSIGHT_API_TENANT_API_KEY="not-a-real-key"
  mkdir -p "$TENANT_HOME" "$TRANSCRIPT_DIR"
}

inject() {
  printf '%s' "$1" | python3 "$INJECT"
}

# A local stub standing in for the memory backend. Tests that must
# distinguish "the injector chose not to query" from "the query failed"
# point at this, so silence means a decision rather than an outage.
# $1 (optional): JSON results array the stub serves. Defaults to one hit.
start_stub() {
  # Set the default with an if, not ${1:-...}: a literal } inside the
  # expansion terminates it early and silently mangles the JSON.
  if [ "$#" -gt 0 ]; then
    STUB_RESULTS="$1"
  else
    STUB_RESULTS='[{"type": "world", "text": "The scheduler runs rendered goal files."}]'
  fi
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" "$STUB_RESULTS" > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        body = json.dumps({"results": json.loads(sys.argv[2])}).encode()
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
  # Wait for the stub to accept connections (no `timeout` on macOS).
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
  # Disown before killing so the shell's job-control notice for the
  # expected SIGTERM stays out of the test output — a real failure should
  # be the only unexpected text on the stream.
  disown "$STUB_PID" 2>/dev/null || true
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
}

@test "the injector exists and is executable" {
  [ -x "$INJECT" ]
}

@test "an unreachable backend exits 0" {
  run inject '{"prompt":"what did we decide about the keychain"}'
  [ "$status" -eq 0 ]
}

@test "an unreachable backend emits nothing" {
  run inject '{"prompt":"what did we decide about the keychain"}'
  [ -z "$output" ]
}

@test "malformed stdin exits 0 and emits nothing" {
  run inject 'not json at all'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "empty stdin exits 0 and emits nothing" {
  run inject ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an empty prompt exits 0 and emits nothing" {
  run inject '{"prompt":""}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a payload with no prompt field exits 0 and emits nothing" {
  run inject '{"session_id":"abc"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing required configuration exits 0 and emits nothing" {
  # A deployment that never set the capture variables still runs. Pointed
  # at a live stub, so silence proves the configuration check fired rather
  # than the backend being absent.
  start_stub
  run bash -c "printf '%s' '{\"prompt\":\"what did we establish about the scheduler\"}' | env -u TENANT_BANK HINDSIGHT_API_URL='$HINDSIGHT_API_URL' python3 '$INJECT'"
  stop_stub
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a very short prompt is skipped without querying" {
  # Conservative by design: a two-word prompt carries too little signal to
  # retrieve against. Pointed at a live stub that would answer any query,
  # a gated prompt still emits nothing — which is what distinguishes "the
  # gate held" from "the backend happened to be down".
  start_stub
  run inject '{"prompt":"ok thanks"}'
  stop_stub
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a long enough prompt does reach the backend" {
  # The other half of the gate: without this, a gate set to reject
  # everything would pass the test above.
  start_stub
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "a served result is emitted as UserPromptSubmit additionalContext" {
  # The shape of a successful injection, pinned against the stub.
  start_stub
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run bash -c "printf '%s' '$output' | python3 -c 'import json,sys; d=json.load(sys.stdin); h=d[\"hookSpecificOutput\"]; assert h[\"hookEventName\"]==\"UserPromptSubmit\"; assert h[\"additionalContext\"].strip()'"
  [ "$status" -eq 0 ]
}

@test "a backend that returns no results emits nothing" {
  start_stub '[]'
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a backend whose results are all blank emits nothing" {
  # Guards the render path specifically: results arrive, none carry text,
  # so there is nothing worth spending context on.
  start_stub '[{"type": "world", "text": "   "}, {"type": "world"}]'
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
