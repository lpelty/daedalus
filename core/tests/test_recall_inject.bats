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

# Runs even when a test fails, so a failing assertion cannot orphan the
# stub server and hold the whole run open.
teardown() {
  stop_stub
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
  # An unset STUB_PID makes `wait` block on EVERY child instead of one, so
  # a teardown for a test that never started a stub would hang the run.
  # Guard on the variable, and clear it so a second call is a no-op.
  [ -n "${STUB_PID:-}" ] || return 0
  # Disown before killing so the shell's job-control notice for the
  # expected SIGTERM stays out of the test output — a real failure should
  # be the only unexpected text on the stream.
  disown "$STUB_PID" 2>/dev/null || true
  kill "$STUB_PID" 2>/dev/null || true
  wait "$STUB_PID" 2>/dev/null || true
  STUB_PID=""
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

@test "a 1400-character memory survives injection intact, through the real entry point" {
  # PROP-010. The old behavior cut every memory at 240 characters mid-word
  # and appended an ellipsis, silently discarding whatever came after —
  # including, in the reported case, the operative clause of the memory.
  # This drives the actual CLI entry point end to end (stdin -> stdout),
  # not the private _render() helper, per GC-1.
  long_text=$(python3 -c "print('The scheduler executes rendered goal files rather than the manifest so an unenrolled goal can still run and this clause, which explains why, must survive intact past the two-hundred-forty character mark that used to cut memories off mid-word. ' * 6)" | cut -c1-1450)
  len=${#long_text}
  [ "$len" -gt 1400 ]

  payload=$(python3 -c "import json,sys; print(json.dumps([{'type':'world','text': sys.argv[1]}]))" "$long_text")
  start_stub "$payload"
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub

  [ "$status" -eq 0 ]
  [ -n "$output" ]

  # The full memory text must appear verbatim in the emitted context, and
  # the tail of the source string is what a 240-char cut would have
  # destroyed -- so check specifically for text at the end of the memory.
  # Written to files rather than interpolated into a python -c string:
  # the long_text/output payloads are large and quote-heavy enough that
  # shell interpolation into an embedded script silently mangles them.
  tail_fragment="${long_text: -40}"
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/out.json"
  printf '%s' "$tail_fragment" > "$BATS_TEST_TMPDIR/tail.txt"
  run python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
with open(sys.argv[2]) as f:
    tail_fragment = f.read()
ctx = d['hookSpecificOutput']['additionalContext']
assert tail_fragment in ctx, 'tail of long memory missing from injected context'
assert len(ctx) > 1400, f'injected context too short to hold the full memory: {len(ctx)}'
" "$BATS_TEST_TMPDIR/out.json" "$BATS_TEST_TMPDIR/tail.txt"
  [ "$status" -eq 0 ]
}

@test "no ellipsis truncation marker appears anywhere in the injected context" {
  # PROP-010. Even for a memory well past the old 240-char cutoff, the
  # injector must never append the "…" truncation marker -- full text or
  # nothing. Checked on the JSON-decoded string, not raw stdout: Python's
  # json.dumps renders "…" as a … escape sequence, not the literal
  # glyph, so a raw substring match on $output would silently miss a real
  # truncation.
  long_text=$(python3 -c "print('x' * 900)")
  payload=$(python3 -c "import json,sys; print(json.dumps([{'type':'world','text': sys.argv[1]}]))" "$long_text")
  start_stub "$payload"
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/out.json"
  run python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
ctx = d['hookSpecificOutput']['additionalContext']
assert '…' not in ctx, 'ellipsis truncation marker found in decoded output'
" "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
}

@test "MAX_RESULTS still bounds the count: 15 results in, 10 rendered" {
  # PROP-010 also raises MAX_RESULTS to 10. Bounding the *number* of
  # memories is legitimate (unlike per-memory character truncation), so
  # this pins that the count cap still works post-fix -- asserted by
  # counting rendered lines through the real entry point, never by
  # asserting the constant's value (GC-2).
  results_json=$(python3 -c "
import json
print(json.dumps([{'type': 'world', 'text': f'memory number {i} with enough words to pass as real content'} for i in range(15)]))
")
  start_stub "$results_json"
  run inject '{"prompt":"what did we establish about how the scheduler runs goals"}'
  stop_stub

  [ "$status" -eq 0 ]
  [ -n "$output" ]
  printf '%s' "$output" > "$BATS_TEST_TMPDIR/out.json"
  run python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
ctx = d['hookSpecificOutput']['additionalContext']
rendered = [l for l in ctx.splitlines() if l.startswith('- [')]
assert len(rendered) == 10, f'expected 10 rendered memories, got {len(rendered)}'
" "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
}
