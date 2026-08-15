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

@test "recall prints a memory's full text, through the real CLI entry point" {
  # PROP-010. cmd_recall used to slice each result to [:200] before
  # printing, silently discarding whatever came after. Drives the actual
  # `capture.py recall` invocation end to end, not a private helper.
  long_text=$(python3 -c "print('The scheduler executes rendered goal files rather than the manifest, and the reason it matters is stated right here past the two-hundred character mark that used to cut recall output off mid-sentence. ' * 3)")
  len=${#long_text}
  [ "$len" -gt 200 ]

  results_json=$(python3 -c "import json,sys; print(json.dumps([{'type':'world','text': sys.argv[1]}]))" "$long_text")
  start_stub "$results_json"
  run python3 "$CAPTURE" recall "what did we establish about the scheduler"
  stop_stub

  [ "$status" -eq 0 ]
  tail_fragment="${long_text: -40}"
  run grep -qF "$tail_fragment" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "recall's printed line is at least as long as the full source memory" {
  # PROP-010. The old [:200] slice printed a line whose length was capped
  # at 200 regardless of the source. Asserting the printed line is at
  # least as long as a 500-char source (not asserting "500" or "200"
  # directly, per GC-2) catches that regression without pinning a magic
  # number.
  long_text=$(python3 -c "print('x' * 500)")
  results_json=$(python3 -c "import json,sys; print(json.dumps([{'type':'world','text': sys.argv[1]}]))" "$long_text")
  start_stub "$results_json"
  run python3 "$CAPTURE" recall "what did we establish about the scheduler"
  stop_stub

  [ "$status" -eq 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/recall_out.txt"
  run python3 -c "
import sys
with open(sys.argv[1]) as f:
    lines = f.read().splitlines()
memory_lines = [l for l in lines if l.strip().startswith('[world]')]
assert memory_lines, f'no rendered memory line found in output: {lines}'
assert len(memory_lines[0]) >= 500, f'printed line shorter than the full source memory: {len(memory_lines[0])}'
" "$BATS_TEST_TMPDIR/recall_out.txt"
  [ "$status" -eq 0 ]
}

# --- deferred verification on the unattended path (PROP-007) -----------------
#
# The SessionEnd hook cannot wait for extraction: hooks share a ~1.5s budget
# and extraction takes 8-22s, so verifying synchronously there is not slow,
# it is impossible. The offset therefore advances on ACCEPTANCE — and before
# this work, that was the end of the story: an extraction that later failed
# took the span with it, silently and permanently.
#
# These tests drive `capture.py capture` — the real entry point the hook
# invokes — against a backend that accepts a push and then reports the
# extraction failed, which is exactly the PROP-002 scenario.

@test "a span accepted on the fast path is recorded as unconfirmed, not assumed stored" {
  # Acceptance is not storage. After a fast-path capture the offset has
  # advanced (the hook cannot hold it), so the ONLY thing standing between a
  # failed extraction and permanent loss is a durable record that the span's
  # fate is unknown.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  [ "$(pending_count)" -gt 0 ]
}

@test "an unconfirmed span records the operation needed to resolve it later" {
  # A log line scrolls away; resolving the span later needs the operation id
  # and the byte range, in durable state. Read them back with a separate
  # process — grepping the file for the transcript name would pass on the old
  # code, because the offsets map already contains that path.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  run python3 - "$OFFSETS" "$TRANSCRIPT" "$size" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
assert p.exists(), "no state file"
pend = json.loads(p.read_text() or "{}").get("pending") or []
assert pend, "no unconfirmed span recorded"
e = pend[0]
assert e.get("operation_id"), f"no operation id to resolve the span with: {e}"
assert e.get("transcript") == sys.argv[2], f"wrong transcript: {e}"
assert e.get("offset_from") == 0, f"wrong span start: {e}"
assert e.get("offset_to") == int(sys.argv[3]), f"wrong span end: {e}"
PY
  [ "$status" -eq 0 ]
}

@test "a later run re-pushes a span whose extraction failed" {
  # The heart of PROP-007. Push on the fast path, let extraction fail, then
  # run capture again with nothing new in the transcript. The failed span
  # must go back to the server rather than being written off.
  start_op_stub "failed"
  run python3 "$CAPTURE" capture
  before=$(posted_document_ids | wc -l | tr -d ' ')

  run python3 "$CAPTURE" capture          # nothing new; reconciliation only
  after=$(posted_document_ids | wc -l | tr -d ' ')
  [ "$after" -gt "$before" ]
}

@test "a re-pushed span carries the same document_ids as its first attempt" {
  # GC-6, and the reason this fix is safe. hindsight-api treats a repeated
  # document_id as a re-ingest that DELETES that document's prior memories —
  # so re-pushing under the ORIGINAL ids replaces the failed attempt, while
  # re-deriving ids from a new offset would duplicate the content instead
  # (the 2026-07-09 incident, in the other direction).
  start_op_stub "failed"
  run python3 "$CAPTURE" capture
  first=$(posted_document_ids | sort -u)
  first_n=$(posted_document_ids | wc -l | tr -d ' ')

  run python3 "$CAPTURE" capture
  total_n=$(posted_document_ids | wc -l | tr -d ' ')
  distinct=$(posted_document_ids | sort -u)

  # A retry must have happened at all — otherwise "reused the ids" is
  # vacuously true, which is how this test passed against the unfixed code.
  [ "$total_n" -gt "$first_n" ]
  [ -n "$first" ]
  # ...and it must have introduced no id the first attempt did not use.
  [ "$distinct" = "$first" ]
}

@test "a span confirmed stored is dropped from the unconfirmed set" {
  # The ledger must drain, or it grows without bound and stops meaning
  # anything. Push, then let the operation report success on the next run.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]

  set_op_status "completed"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -eq 0 ]
}

@test "a span whose outcome is still unknown is kept, not dropped" {
  # An operation that has not finished is not a failure and not a success.
  # Dropping it would lose the span; re-pushing it every run would hammer the
  # server. It stays, and the next run asks again.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]
}

@test "an unreachable backend does not discard an unconfirmed span" {
  # The verdict is unknown because nothing answered — which is the state
  # where throwing the span away is least excusable.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]
  stop_stub

  export HINDSIGHT_API_URL="http://127.0.0.1:1"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]
}

@test "a re-push that fails leaves the span unconfirmed for a further retry" {
  # One retry is not a guarantee. If the re-push itself cannot be delivered,
  # the span must stay in the ledger rather than being counted as handled.
  start_op_stub "failed"
  run python3 "$CAPTURE" capture
  stop_stub

  export HINDSIGHT_API_URL="http://127.0.0.1:1"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]
}

@test "the unconfirmed-span ledger stays bounded when the backend never confirms" {
  # Each entry carries the pushed content, so a backend that never reaches a
  # verdict would otherwise grow this file without limit and tax every later
  # run. Drives many real captures against a server that always says
  # "running", then asserts the ledger stopped growing — without naming the
  # cap (GC-2): the assertion is "fewer entries than runs", not "== 50".
  start_op_stub "running"
  runs=70
  for i in $(seq 1 $runs); do
    printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn $i\"}}" >> "$TRANSCRIPT"
    python3 "$CAPTURE" capture >/dev/null 2>&1
  done
  [ "$(pending_count)" -gt 0 ]
  [ "$(pending_count)" -lt "$runs" ]
}

@test "a span abandoned by the bounded ledger is announced, never dropped silently" {
  # Losing a span quietly is the defect this whole mechanism exists to fix.
  # If capacity forces one out, it must be named on the way out.
  start_op_stub "running"
  for i in $(seq 1 70); do
    printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn $i\"}}" >> "$TRANSCRIPT"
    python3 "$CAPTURE" capture > "$BATS_TEST_TMPDIR/last.txt" 2>&1
  done
  run grep -qiE "abandon|LOST" "$BATS_TEST_TMPDIR/last.txt"
  [ "$status" -eq 0 ]
}

@test "unconfirmed spans are reported by the status command" {
  # Durable is not enough — it has to be findable without reading JSON by
  # hand. status is the command an operator already runs.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  run python3 "$CAPTURE" status
  run grep -qiE "unverified|pending" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "the fast path still returns without waiting out an unfinished extraction" {
  # The reason verification cannot simply be turned on. The operation never
  # reaches a terminal state here, so a blocking implementation would sit on
  # the poll loop until its timeout. The hook budget is ~1.5s; this asserts
  # the fast path does not spend anything like the verify timeout.
  start_op_stub "running"
  started=$(python3 -c "import time; print(time.time())")
  run python3 "$CAPTURE" capture
  elapsed=$(python3 -c "import sys,time; print(time.time() - float(sys.argv[1]))" "$started")
  [ "$status" -eq 0 ]
  run python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 15 else 1)" "$elapsed"
  [ "$status" -eq 0 ]
}

@test "an existing state file written before this change is read without error" {
  # A deployment that pulls this has an offsets.json with only an "offsets"
  # key. Reading it must not crash, and its recorded offset must still be
  # honoured — otherwise the upgrade re-ingests the whole transcript.
  mkdir -p "$(dirname "$OFFSETS")"
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  python3 - "$OFFSETS" "$TRANSCRIPT" "$size" <<'PY'
import json, sys
json.dump({"offsets": {sys.argv[2]: int(sys.argv[3])}}, open(sys.argv[1], "w"))
PY
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  run grep -qF "nothing new" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "close's verified path still refuses to advance when extraction fails" {
  # No regression on core/close.sh's contract: with verification on, a failed
  # extraction must leave the offset where it was, so the span is re-read
  # rather than trusted to the ledger.
  start_op_stub "failed"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=3 \
    run python3 "$CAPTURE" capture
  [ "$(stored_offset)" = "0" ]
}

@test "close's verified path still advances on a confirmed extraction" {
  start_op_stub "completed"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=10 \
    run python3 "$CAPTURE" capture
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  [ "$(stored_offset)" = "$size" ]
}

# A local stub standing in for the memory backend, so the success path can
# be exercised without a live server. $1 (optional): JSON body to serve for
# a POST to a path containing "/recall" — defaults to the plain capture-op
# response every other test in this file relies on.
start_stub() {
  if [ "$#" -gt 0 ]; then
    STUB_RECALL_RESULTS="$1"
  else
    STUB_RECALL_RESULTS='[]'
  fi
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" "$STUB_RECALL_RESULTS" > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        if "/recall" in self.path:
            body = json.dumps({"results": json.loads(sys.argv[2])}).encode()
        else:
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

# A stub that models the part of the backend the deferred-verification work
# actually depends on: an async retain returns an operation id, and the
# operation's verdict arrives LATER via GET /operations/<id>. The plain
# start_stub above returns no operation id at all, so it cannot express the
# difference between "accepted" and "stored" — which is the entire defect.
#
# $1: the status served for GET /operations/<id> ("completed", "failed", ...).
# $2 (optional): extraction_errors_count to report alongside it.
#
# Every POST body is appended as one JSON line to $STUB_POSTS, so a test can
# assert what was re-pushed — including the document_ids, which is the one
# property GC-6 makes load-bearing.
start_op_stub() {
  STUB_POSTS="$BATS_TEST_TMPDIR/posts.jsonl"
  STUB_STATUS_FILE="$BATS_TEST_TMPDIR/op_status"
  : > "$STUB_POSTS"
  printf '%s' "$1" > "$STUB_STATUS_FILE"
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" "$STUB_POSTS" "$STUB_STATUS_FILE" "${2:-0}" \
      > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json, itertools
from http.server import BaseHTTPRequestHandler, HTTPServer

posts_path, status_path, errs = sys.argv[2], sys.argv[3], int(sys.argv[4])
counter = itertools.count(1)

class H(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode()
        with open(posts_path, "a") as f:
            f.write(raw.replace("\n", " ") + "\n")
        # Each accepted batch gets its own operation id, exactly as the real
        # async surface does — a retry must be pollable independently of the
        # push it replaces.
        self._send({"success": True, "operation_id": f"op-{next(counter)}"}, 202)

    def do_GET(self):
        if "/operations/" in self.path:
            # Read the verdict per request, so a test can flip it between
            # runs and model "failed once, then succeeded".
            with open(status_path) as f:
                status = f.read().strip()
            self._send({"status": status, "extraction_errors_count": errs})
        else:
            self._send({"ok": True})

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

# Flip the verdict the running operation stub serves.
set_op_status() {
  printf '%s' "$1" > "$STUB_STATUS_FILE"
}

# Number of pending (pushed-but-unconfirmed) spans in the durable ledger.
pending_count() {
  python3 - "$OFFSETS" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print(0); raise SystemExit
print(len(json.loads(p.read_text() or "{}").get("pending", []) or []))
PY
}

# All document_ids the stub was asked to ingest, in order, one per line.
posted_document_ids() {
  python3 - "$STUB_POSTS" <<'PY'
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    for item in json.loads(line).get("items", []):
        print(item.get("document_id"))
PY
}
