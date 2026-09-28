#!/usr/bin/env bats
#
# Pins capture.py's offset discipline. The byte offset is a read cursor: if
# it advances past bytes that were never stored, those bytes are lost
# permanently and nothing reports it.
#
# The guard is already correct — _capture_path returns before persisting
# when the POST fails. These tests exist because nothing pinned it, so a
# reordering would have shipped silently green.

# Wall-clock assertions live in this file: under the parallel full-suite gate
# (`bats --jobs 12`) its tests run one at a time, while other files run beside it.
BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  CAPTURE="$ROOT/core/capture.py"
  export TENANT_HOME="$BATS_TEST_TMPDIR/home"
  export TENANT_BANK="testbank"
  export TRANSCRIPT_DIR="$BATS_TEST_TMPDIR/transcripts"
  export HINDSIGHT_API_URL="http://127.0.0.1:1"   # nothing listens here
  export HINDSIGHT_API_TENANT_API_KEY="not-a-real-key"
  # capture no longer guesses "the newest transcript" (spec §4.7); a Bash
  # tool names its session with CLAUDE_CODE_SESSION_ID, and so does this
  # fixture. Unset whatever the developer's own session exported.
  export CLAUDE_CODE_SESSION_ID="session-a"
  # stdin from /dev/null: bats inherits the runner's stdin, and inside a
  # Claude Code Bash tool that can be a socket that never closes — capture
  # would wait on it (a second at most after Task 7; forever before it).
  exec </dev/null
  # Session variables this suite sets per test, never inherited from the
  # developer's own session: a direct call's would make capture stand down
  # (Task 8), an interval would change the in-flight ceiling (Task 9).
  unset CAPTURE_DEFER_TO_CALLER DIRECT_CALL_ID CAPTURE_INTERVAL
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
#
# Looks the transcript up under both its resolved and its literal spelling.
# capture tracks a file under one canonical (resolved) key so that capture and
# reprocess cannot open competing cursors for it; on this platform the bats
# temp dir sits behind a symlink (/var -> /private/var), so a helper that only
# checked the literal path would report 0 for a cursor that is in fact set.
stored_offset() {
  python3 - "$OFFSETS" "$TRANSCRIPT" <<'PY'
import json, sys, pathlib, os
p = pathlib.Path(sys.argv[1])
if not p.exists():
    print(0); raise SystemExit
offsets = json.loads(p.read_text() or "{}").get("offsets", {})
t = sys.argv[2]
for k in (os.path.realpath(t), t):
    if k in offsets:
        print(offsets[k]); raise SystemExit
print(0)
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
import json, sys, pathlib, os
p = pathlib.Path(sys.argv[1])
assert p.exists(), "no state file"
pend = json.loads(p.read_text() or "{}").get("pending") or []
assert pend, "no unconfirmed span recorded"
e = pend[0]
assert e.get("operation_id"), f"no operation id to resolve the span with: {e}"
# The ledger records the same canonical identity the offsets map uses, so
# compare resolved paths rather than the literal spelling handed in.
assert os.path.realpath(e.get("transcript", "")) == os.path.realpath(sys.argv[2]), \
    f"wrong transcript: {e}"
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

# --- a stale ledger entry must never overwrite newer content ----------------
#
# A pending entry names a document_id, and a repeated document_id is a
# re-ingest that DELETES that document's prior memories. So an entry that
# outlives the content it describes is not merely stale — re-pushing it
# destroys whatever newer content now occupies those ids. That is the exact
# mechanism of the 2026-07-09 incident, arriving by a different route.
#
# The route: reprocess resets the offset to 0, so the next capture re-pushes
# the SAME document_ids carrying MORE content. If a pending entry from before
# the reprocess then reports failed, reconciliation re-pushes the older,
# shorter items under those same ids and the newer text is gone.

@test "reprocess drops pending entries for the transcript it invalidates" {
  # reprocess invalidates exactly the spans recorded against this transcript:
  # it is about to re-read the file from zero under the same document_ids.
  # Leaving them in the ledger arms a re-push of superseded content.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]

  run python3 "$CAPTURE" reprocess "$TRANSCRIPT"
  [ "$status" -eq 0 ]

  # Exactly one span is pending afterwards: the one reprocess itself pushed,
  # not the stale one it superseded. Asserting "no entry describes a span the
  # current offset no longer matches" rather than a literal count.
  run python3 - "$OFFSETS" "$TRANSCRIPT" <<'PY'
import json, sys, pathlib
d = json.loads(pathlib.Path(sys.argv[1]).read_text() or "{}")
offsets, pending = d.get("offsets", {}), d.get("pending") or []
stale = [e for e in pending
         if e.get("offset_to") != offsets.get(e.get("transcript"))]
assert not stale, f"stale entries survived reprocess: {stale}"
PY
  [ "$status" -eq 0 ]
}

@test "a reprocessed transcript's newer content is not overwritten by a stale span" {
  # The end-to-end defect, asserted on what actually reaches the server.
  # Capture turn one, append turn two, reprocess (which re-pushes both under
  # the original ids), then let the pre-reprocess operation report failed.
  # Reconciliation must NOT re-push the turn-one-only items over them.
  start_op_stub "running"
  run python3 "$CAPTURE" capture

  printf '%s\n' '{"type":"user","message":{"role":"user","content":"BBBB the second turn that must survive"}}' >> "$TRANSCRIPT"
  run python3 "$CAPTURE" reprocess "$TRANSCRIPT"

  # Everything now fails, which is what would trigger the destructive re-push.
  set_op_status "failed"
  run python3 "$CAPTURE" capture

  # No push carrying a document_id may lack the newer turn once that id has
  # been seen carrying it — a later push under the same id would delete it.
  run python3 - "$STUB_POSTS" <<'PY'
import json, sys
seen_with_new = set()
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    for item in json.loads(line).get("items", []):
        did, content = item.get("document_id"), item.get("content", "")
        if "BBBB" in content:
            seen_with_new.add(did)
        elif did in seen_with_new:
            raise SystemExit(
                f"document_id {did} was re-pushed WITHOUT the newer turn; "
                f"that push deletes it")
PY
  [ "$status" -eq 0 ]
}

@test "a pending span whose recorded end no longer matches the stored offset is discarded" {
  # The general guard, independent of reprocess. Any path that rewinds or
  # rewrites the offset leaves entries describing content that no longer
  # occupies those ids. Such an entry must be dropped, not re-pushed.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  [ "$(pending_count)" -gt 0 ]

  # Rewrite the pending entry's recorded end so it no longer describes the
  # span the stored offset says was captured. Reconciliation must discard it
  # rather than re-push its items over whatever now holds those ids.
  #
  # The entry is pointed at a transcript that no longer exists, so the capture
  # below is pure reconciliation — otherwise a fresh capture would re-sync the
  # offset and paper over the mismatch before it could be asserted.
  python3 - "$OFFSETS" "$TRANSCRIPT" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text() or "{}")
for e in d.get("pending", []):
    e["offset_to"] = e.get("offset_to", 0) + 999
p.write_text(json.dumps(d))
PY
  set_op_status "failed"
  before=$(posted_document_ids | wc -l | tr -d ' ')
  run python3 "$CAPTURE" capture

  # The stale entry must be gone AND must not have been re-pushed.
  after=$(posted_document_ids | wc -l | tr -d ' ')
  [ "$after" -eq "$before" ]
  run python3 - "$OFFSETS" <<'PY'
import json, sys, pathlib
d = json.loads(pathlib.Path(sys.argv[1]).read_text() or "{}")
offsets, pending = d.get("offsets", {}), d.get("pending") or []
stale = [e for e in pending
         if e.get("offset_to") != offsets.get(e.get("transcript"))]
assert not stale, f"stale entry kept: {stale}"
PY
  [ "$status" -eq 0 ]
}

@test "capture and reprocess agree on one identity for the same transcript" {
  # reprocess resolved the path while capture stored it as given, so a
  # symlinked temp dir produced two offset keys and two ledger entries for one
  # file — and therefore duplicate pushes of the same bytes. Drive both real
  # commands and assert the state has a single identity for the file.
  start_op_stub "running"
  run python3 "$CAPTURE" capture
  run python3 "$CAPTURE" reprocess "$TRANSCRIPT"

  run python3 - "$OFFSETS" <<'PY'
import json, sys, pathlib, os
d = json.loads(pathlib.Path(sys.argv[1]).read_text() or "{}")
keys = list(d.get("offsets", {}))
# One file, one key — regardless of which spelling was used to reach it.
reals = {os.path.realpath(k) for k in keys}
assert len(keys) == len(reals), f"same file tracked under several keys: {keys}"
tk = {e.get("transcript") for e in (d.get("pending") or [])}
assert len({os.path.realpath(t) for t in tk}) == len(tk), \
    f"same file pending under several keys: {tk}"
PY
  [ "$status" -eq 0 ]
}

@test "a ledger entry written by an older build under an unresolved path still settles" {
  # Normalizing must not orphan entries the previous code wrote under the
  # un-normalized spelling. Hand-write state in the old shape and confirm a
  # normal capture still reconciles it rather than leaving it stranded.
  start_op_stub "completed"
  unresolved="$TRANSCRIPT"
  mkdir -p "$(dirname "$OFFSETS")"
  python3 - "$OFFSETS" "$unresolved" <<'PY'
import json, sys, os
size = os.path.getsize(sys.argv[2])
json.dump({"offsets": {sys.argv[2]: size},
           "pending": [{"operation_id": "op-legacy",
                        "transcript": sys.argv[2],
                        "offset_from": 0, "offset_to": size,
                        "stamp": "2026-01-01",
                        "items": [{"content": "legacy",
                                   "document_id": "session-a-o0-p00"}]}]},
          open(sys.argv[1], "w"))
PY
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  # The operation reports completed, so the entry must drain rather than sit
  # unresolvable under a key nothing looks up any more.
  [ "$(pending_count)" -eq 0 ]
}

@test "the ledger never exceeds the cap it states" {
  # Eviction ran before the append, so the ledger settled one entry above the
  # cap. Asserted as an invariant against the module's own constant rather
  # than a literal (GC-2/GC-5): whatever the cap is, the file must honour it.
  start_op_stub "running"
  for i in $(seq 1 60); do
    printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"turn $i\"}}" >> "$TRANSCRIPT"
    python3 "$CAPTURE" capture >/dev/null 2>&1
  done
  run python3 - "$OFFSETS" "$CAPTURE" <<'PY'
import json, sys, pathlib, importlib.util
spec = importlib.util.spec_from_file_location("capture", sys.argv[2])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
n = len(json.loads(pathlib.Path(sys.argv[1]).read_text() or "{}").get("pending") or [])
assert n <= mod.MAX_PENDING_SPANS, f"ledger holds {n}, cap is {mod.MAX_PENDING_SPANS}"
PY
  [ "$status" -eq 0 ]
}

# --- malformed state must degrade, not wedge capture ------------------------

@test "a malformed pending entry is dropped instead of killing capture" {
  # A non-dict in the pending list raised AttributeError, exit 1, and capture
  # stayed dead until someone hand-edited the state file. The docstring
  # promises tolerance of old or partial state; this makes it true one level
  # deeper.
  start_op_stub "running"
  mkdir -p "$(dirname "$OFFSETS")"
  python3 - "$OFFSETS" <<'PY'
import json, sys
json.dump({"offsets": {}, "pending": ["notadict"]}, open(sys.argv[1], "w"))
PY
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
}

@test "a dropped malformed entry is named rather than silently discarded" {
  start_op_stub "running"
  mkdir -p "$(dirname "$OFFSETS")"
  python3 - "$OFFSETS" <<'PY'
import json, sys
json.dump({"offsets": {}, "pending": ["notadict"]}, open(sys.argv[1], "w"))
PY
  run python3 "$CAPTURE" capture 2>&1
  run grep -qiE "discard|drop|malformed" <<< "$output"
  [ "$status" -eq 0 ]
}

@test "a pending entry whose items are not a list is dropped without crashing" {
  # The stub reports "failed", which forces the re-push branch — the one that
  # actually iterates items. Against an unreachable server this entry would
  # resolve as "unknown" and never touch the malformed field, so the test
  # would pass without exercising anything.
  start_op_stub "failed"
  mkdir -p "$(dirname "$OFFSETS")"
  python3 - "$OFFSETS" <<'PY'
import json, sys
json.dump({"offsets": {},
           "pending": [{"operation_id": "op-1", "transcript": "/x.jsonl",
                        "offset_from": 0, "offset_to": 1, "items": "nope"}]},
          open(sys.argv[1], "w"))
PY
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  run grep -qiE "discard|drop|malformed" <<< "$output"
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
# operation's verdict arrives LATER via GET /operations/<id>.
#
# $1: the status served for GET /operations/<id> ("completed", "failed", ...).
# $2 (optional): extraction_errors_count to report alongside it.
#
# Every POST body is appended as one JSON line to $STUB_POSTS, and every
# request as "<METHOD> <path> <epoch>" to $BATS_TEST_TMPDIR/requests.log.
# Per-request knobs, read from $BATS_TEST_TMPDIR when present:
#   op_body     the verbatim JSON served for GET /operations/<id> — the live
#               server's shape (PROP-006), overriding $1/$2
#   get_sleep   seconds to stall every GET before answering
#   post_sleep  seconds to stall every POST before answering (logged first)
# Threaded: a stalled request must not hold up the others, or a test of "one
# slow capture does not delay another" would measure the stub, not capture.
start_op_stub() {
  STUB_POSTS="$BATS_TEST_TMPDIR/posts.jsonl"
  STUB_STATUS_FILE="$BATS_TEST_TMPDIR/op_status"
  : > "$STUB_POSTS"
  : > "$BATS_TEST_TMPDIR/requests.log"
  printf '%s' "$1" > "$STUB_STATUS_FILE"
  STUB_PORT=$(python3 -c "import socket;s=socket.socket();s.bind(('127.0.0.1',0));print(s.getsockname()[1]);s.close()")
  python3 - "$STUB_PORT" "$STUB_POSTS" "$STUB_STATUS_FILE" "${2:-0}" "$BATS_TEST_TMPDIR" \
      > "$BATS_TEST_TMPDIR/stub.log" 2>&1 <<'PY' &
import sys, json, itertools, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

posts_path, status_path, errs, tmp = sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
counter = itertools.count(1)

def knob(name):
    p = os.path.join(tmp, name)
    return open(p).read().strip() if os.path.exists(p) else None

class H(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _log(self):
        with open(os.path.join(tmp, "requests.log"), "a") as f:
            f.write("%s %s %.3f\n" % (self.command, self.path, time.time()))

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode()
        self._log()
        with open(posts_path, "a") as f:
            f.write(raw.replace("\n", " ") + "\n")
        s = knob("post_sleep")
        if s:
            time.sleep(float(s))
        # Each accepted batch gets its own operation id, exactly as the real
        # async surface does — a retry must be pollable independently of the
        # push it replaces.
        self._send({"success": True, "operation_id": f"op-{next(counter)}"}, 202)

    def do_GET(self):
        self._log()
        s = knob("get_sleep")
        if s:
            time.sleep(float(s))
        if "/operations/" in self.path:
            body = knob("op_body")
            if body:
                self._send(json.loads(body))
                return
            # Read the verdict per request, so a test can flip it between
            # runs and model "failed once, then succeeded".
            with open(status_path) as f:
                status = f.read().strip()
            self._send({"status": status, "extraction_errors_count": errs})
        else:
            self._send({"ok": True})

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
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

# POSTs the stub has received (0 when it never started or saw none).
post_count() {
  awk '/^POST /{n++} END{print n+0}' "$BATS_TEST_TMPDIR/requests.log" 2>/dev/null || echo 0
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

# Epoch milliseconds a live pid started — the parse capture.py's _proc_started
# and leaselib.proc_started_of use (spec §4.5).
ps_ms() { python3 -c 'import subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True).stdout.strip()
print(int(time.mktime(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000) if out else 0)' "$1"; }

# seed_in_flight <pid> <proc_started_ms> <started_epoch> [transcript] [ceiling]
# — write an in-flight claim for a transcript into offsets.json, as a running
# capture would; with a ceiling, the claim records it as its run's own.
seed_in_flight() {
  mkdir -p "$(dirname "$OFFSETS")"
  python3 - "$OFFSETS" "${4:-$TRANSCRIPT}" "$1" "$2" "$3" "${5:-}" <<'PY'
import json, os, sys, pathlib
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text()) if p.exists() else {}
d.setdefault("offsets", {}); d.setdefault("pending", [])
claim = {"offset": 0, "pid": int(sys.argv[3]), "proc_started": int(sys.argv[4]), "started": float(sys.argv[5])}
if sys.argv[6]:
    claim["ceiling"] = float(sys.argv[6])
d.setdefault("transcripts", {})[os.path.realpath(sys.argv[2])] = {"in_flight": claim}
p.write_text(json.dumps(d))
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

# --- PROP-006: the failure reason is the server's error_message --------------
#
# The live server (GET /v1/default/banks/<bank>/operations, 2026-09-21) returns
# objects whose keys are created_at, document_id, error_message, filename, id,
# items_count, next_retry_at, progress, retry_count, status, task_type,
# updated_at — there is no "error" key. Both sites read op.get('error') and
# printed error=None for every real failure.
LIVE_FAILED_OP='{"id":"op-1","status":"failed","error_message":"chunk 0: JSONDecodeError: Expecting value: line 1 column 1 (char 0)","retry_count":0,"items_count":1,"document_id":"session-a-o0-p00","filename":null,"next_retry_at":null,"progress":null,"task_type":"retain","created_at":"2026-09-21T10:00:00Z","updated_at":"2026-09-21T10:00:05Z"}'

@test "PROP-006: the verified path (_await_extraction) reports the server's error_message on the live payload shape, never error=None" {
  start_op_stub "failed"
  printf '%s' "$LIVE_FAILED_OP" > "$BATS_TEST_TMPDIR/op_body"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=5 run python3 "$CAPTURE" capture
  [ "$status" -ne 0 ]
  case "$output" in *"extraction FAILED"*"JSONDecodeError"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"error=None"*) echo "the reason was dropped: $output"; return 1 ;; *) : ;; esac
}

@test "PROP-006: reconciliation (_check_operation) reports the server's error_message for a failed pending span" {
  start_op_stub "running"
  run python3 "$CAPTURE" capture            # fast path: the span is pending under op-1
  printf '%s' "$LIVE_FAILED_OP" > "$BATS_TEST_TMPDIR/op_body"
  run python3 "$CAPTURE" capture            # nothing new; settles op-1 -> failed
  case "$output" in *"pending span FAILED extraction"*"JSONDecodeError"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"error=None"*) echo "the reason was dropped: $output"; return 1 ;; *) : ;; esac
}

@test "PROP-006: when a server sends both fields, error_message wins over error" {
  # Discriminates the fix's precedence: before it, the reported reason is 'old'.
  start_op_stub "failed"
  printf '%s' '{"status":"failed","error_message":"real","error":"old","retry_count":0}' > "$BATS_TEST_TMPDIR/op_body"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=5 run python3 "$CAPTURE" capture
  case "$output" in *"error='real'"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "PROP-006 non-regression guard: a server that names the field only error still has its reason reported" {
  # Passes before and after the fix, by design, and proves nothing about the
  # fix itself: PROP-006's Test section calls this shape "a test that agreed
  # with the bug". It guards the fallback half — against a later change that
  # reads error_message ONLY and goes mute on an older server.
  start_op_stub "failed"
  printf '%s' '{"status":"failed","error":"boom","retry_count":0}' > "$BATS_TEST_TMPDIR/op_body"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=5 run python3 "$CAPTURE" capture
  case "$output" in *"error='boom'"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- the transcript is named, never guessed (spec §4.7 (2)) -----------------
@test "capture with CLAUDE_CODE_SESSION_ID and two transcripts present captures the named one only — never the newest" {
  start_op_stub "running"
  Z="$TRANSCRIPT_DIR/session-z.jsonl"
  printf '{"type":"user","message":{"role":"user","content":"a different session entirely"}}\n' > "$Z"
  touch -t 203001010000 "$Z"                       # newest by far
  run python3 "$CAPTURE" capture                   # CLAUDE_CODE_SESSION_ID=session-a from setup
  [ "$status" -eq 0 ]
  grep -q 'session session-a' "$STUB_POSTS"
  run grep -q 'session-z' "$STUB_POSTS"; [ "$status" -ne 0 ]
}

@test "no payload, no --transcript and no session id: capture refuses to guess, exits non-zero, and leaves offsets untouched" {
  unset CLAUDE_CODE_SESSION_ID
  start_op_stub "running"
  run python3 "$CAPTURE" capture </dev/null
  [ "$status" -ne 0 ]
  case "$output" in *"capture: I cannot tell which transcript is this session's (no hook payload, no --transcript, no CLAUDE_CODE_SESSION_ID); refusing to guess"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$OFFSETS" ]; [ "$(post_count)" -eq 0 ]
}

@test "--transcript names the file; --session-id goes through this session's SessionStart marker before the TRANSCRIPT_DIR derivation" {
  unset CLAUDE_CODE_SESSION_ID
  start_op_stub "running"
  O="$BATS_TEST_TMPDIR/elsewhere/s-m.jsonl"; mkdir -p "$(dirname "$O")"; cp "$TRANSCRIPT" "$O"
  mkdir -p "$TENANT_HOME/state"; printf '{"transcript_path":"%s"}' "$O" > "$TENANT_HOME/state/session-s-m.json"
  run python3 "$CAPTURE" capture --session-id s-m; [ "$status" -eq 0 ]
  run python3 "$CAPTURE" capture --transcript "$TRANSCRIPT"; [ "$status" -eq 0 ]
  run python3 - "$OFFSETS" "$O" "$TRANSCRIPT" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))["offsets"]
for t in sys.argv[2:]:
    assert d.get(os.path.realpath(t)) == os.path.getsize(t), (t, d)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a hook payload on stdin names the transcript; a payload with only a session_id goes through the derivation, not the newest file" {
  unset CLAUDE_CODE_SESSION_ID
  start_op_stub "running"
  run python3 "$CAPTURE" capture <<< "{\"session_id\":\"x\",\"transcript_path\":\"$TRANSCRIPT\"}"
  [ "$status" -eq 0 ]; [ "$(stored_offset)" -gt 0 ]
  cp "$TRANSCRIPT" "$TRANSCRIPT_DIR/s-p.jsonl"
  touch -t 200001010000 "$TRANSCRIPT_DIR/s-p.jsonl"               # the oldest file here
  printf '{"type":"user","message":{"role":"user","content":"a decoy"}}\n' > "$TRANSCRIPT_DIR/session-z.jsonl"
  touch -t 203001010000 "$TRANSCRIPT_DIR/session-z.jsonl"         # the newest by far
  run python3 "$CAPTURE" capture <<< '{"session_id":"s-p"}'
  [ "$status" -eq 0 ]; grep -q 'session s-p' "$STUB_POSTS"
  run grep -q 'session-z' "$STUB_POSTS"; [ "$status" -ne 0 ]
}

@test "capture never waits on a stdin that stays open: a pipe with a writer that never writes is given one second, then the session id is used" {
  start_op_stub "running"
  mkfifo "$BATS_TEST_TMPDIR/held"
  sleep 30 > "$BATS_TEST_TMPDIR/held" & holder=$!
  t0="$(date +%s)"
  run python3 "$CAPTURE" capture < "$BATS_TEST_TMPDIR/held"
  t1="$(date +%s)"
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ $((t1 - t0)) -lt 5 ] || { echo "capture waited $((t1 - t0)) s on stdin"; return 1; }
  [ "$(post_count)" -eq 1 ]
}

@test "--transcript naming a file that is not there is refused with one plain sentence naming the path; a hook payload's missing transcript still settles the ledger and exits 0" {
  unset CLAUDE_CODE_SESSION_ID
  start_op_stub "running"
  run python3 "$CAPTURE" capture --transcript "$BATS_TEST_TMPDIR/no-such.jsonl" </dev/null
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  case "$output" in *"capture: the transcript you named is not there: $BATS_TEST_TMPDIR/no-such.jsonl"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 0 ]
  # A hook payload whose transcript is gone (a session that never wrote one):
  # nothing to capture, but a pending span of a past transcript still settles.
  run python3 "$CAPTURE" capture <<< "{\"session_id\":\"x\",\"transcript_path\":\"$BATS_TEST_TMPDIR/gone.jsonl\"}"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"capture: no transcript"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a session id whose derived transcript does not exist is refused, naming the path and memory.transcript_dir" {
  start_op_stub "running"
  CLAUDE_CODE_SESSION_ID=no-such-session run python3 "$CAPTURE" capture
  [ "$status" -ne 0 ]
  case "$output" in *"this session's transcript is not at $TRANSCRIPT_DIR/no-such-session.jsonl"*"memory.transcript_dir"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 0 ]
}

# --- a direct call's capture belongs to the caller (spec §4.7 (3), §8.5) ----
@test "CAPTURE_DEFER_TO_CALLER=1: capture stands down — 'deferred to caller', no request reaches the server, offsets untouched" {
  start_op_stub "running"
  CAPTURE_DEFER_TO_CALLER=1 run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  case "$output" in *"capture: deferred to caller (direct call) — no post, offset unchanged"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -s "$BATS_TEST_TMPDIR/requests.log" ]
  [ ! -f "$OFFSETS" ]
}

@test "DIRECT_CALL_ID alone (a visitor, spec §8.5) also stands capture down: no request, offsets untouched" {
  start_op_stub "running"
  DIRECT_CALL_ID=call-1 run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  case "$output" in *"capture: deferred to caller (direct call) — no post, offset unchanged"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -s "$BATS_TEST_TMPDIR/requests.log" ]
  [ ! -f "$OFFSETS" ]
}

@test "CAPTURE_DEFER_TO_CALLER=1 stands down before naming a transcript: a visitor's hook with nothing to name exits 0, not the refusal" {
  unset CLAUDE_CODE_SESSION_ID
  CAPTURE_DEFER_TO_CALLER=1 run python3 "$CAPTURE" capture </dev/null
  [ "$status" -eq 0 ]
  case "$output" in *"deferred to caller"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- one capture per transcript; no network call under the lock (§4.7 (1)) ---
@test "two captures of two transcripts at once both advance their offsets — no lost update" {
  start_op_stub "running"; printf '1' > "$BATS_TEST_TMPDIR/post_sleep"
  B="$TRANSCRIPT_DIR/session-b.jsonl"; cp "$TRANSCRIPT" "$B"
  python3 "$CAPTURE" capture --transcript "$TRANSCRIPT" > "$BATS_TEST_TMPDIR/a.out" 2>&1 & pa=$!
  python3 "$CAPTURE" capture --transcript "$B" > "$BATS_TEST_TMPDIR/b.out" 2>&1 & pb=$!
  wait "$pa" "$pb"
  run python3 - "$OFFSETS" "$TRANSCRIPT" "$B" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))["offsets"]
for t in sys.argv[2:]:
    assert d.get(os.path.realpath(t)) == os.path.getsize(t), (t, d)
PY
  [ "$status" -eq 0 ] || { echo "$output"; cat "$BATS_TEST_TMPDIR/a.out" "$BATS_TEST_TMPDIR/b.out"; return 1; }
}

@test "a second capture of a transcript while one is in flight posts nothing and says so; exactly one POST reaches the server" {
  start_op_stub "running"; printf '5' > "$BATS_TEST_TMPDIR/post_sleep"
  python3 "$CAPTURE" capture > "$BATS_TEST_TMPDIR/a.out" 2>&1 & pa=$!
  sleep 1
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  case "$output" in *"capture: a capture of this transcript is in flight (pid "*", started "*") — skipping"*) : ;; *) echo "$output"; return 1 ;; esac
  wait "$pa"
  [ "$(post_count)" -eq 1 ]
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  [ "$(stored_offset)" = "$size" ]
}

@test "an in-flight claim whose pid is now another process (pid 1: alive, start time does not match) is cleared and the capture proceeds" {
  start_op_stub "running"
  seed_in_flight 1 1 "$(date +%s)"
  run python3 "$CAPTURE" capture
  [ "$status" -eq 0 ]
  case "$output" in *"capture: cleared a dead in-flight claim for this transcript (pid 1)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 1 ]
}

@test "a live in-flight claim is honoured; once older than the ceiling (interval + verify timeout + 60 s) it is cleared although its pid lives" {
  start_op_stub "running"
  sleep 300 & sp=$!
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(date +%s)"
  run python3 "$CAPTURE" capture
  case "$output" in *"in flight (pid $sp"*"skipping"*) : ;; *) kill "$sp"; echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 0 ]
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(( $(date +%s) - 100 ))"
  CAPTURE_INTERVAL=1 CAPTURE_VERIFY_TIMEOUT_SEC=1 run python3 "$CAPTURE" capture   # ceiling 62 s
  kill "$sp"
  case "$output" in *"cleared a dead in-flight claim"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 1 ]
}

@test "a stalled operations GET for one transcript's pending span does not delay another transcript's capture: no network call runs under the lock, and a span another live run is settling is left to it" {
  start_op_stub "running"
  run python3 "$CAPTURE" capture                          # session-a: one pending span
  printf '5' > "$BATS_TEST_TMPDIR/get_sleep"
  printf '{"type":"user","message":{"role":"user","content":"one more"}}\n' >> "$TRANSCRIPT"
  python3 "$CAPTURE" capture > "$BATS_TEST_TMPDIR/a.out" 2>&1 & pa=$!    # settles it: its GET stalls 5 s
  sleep 0.5
  B="$TRANSCRIPT_DIR/session-b.jsonl"; cp "$TRANSCRIPT" "$B"
  t0="$(python3 -c 'import time; print(time.time())')"
  run python3 "$CAPTURE" capture --transcript "$B"
  t1="$(python3 -c 'import time; print(time.time())')"
  [ "$status" -eq 0 ]
  python3 -c 'import sys; d = float(sys.argv[2]) - float(sys.argv[1]); assert d < 3, "the other transcript waited %.1f s" % d' "$t0" "$t1"
  wait "$pa"
  run python3 - "$OFFSETS" "$TRANSCRIPT" "$B" <<'PY'
import json, os, sys
state = json.load(open(sys.argv[1]))
for t in sys.argv[2:]:
    assert state["offsets"].get(os.path.realpath(t)) == os.path.getsize(t), (t, state["offsets"])
assert not [e for e in state["pending"] if "claim" in e], "a claim outlived its run: %r" % state["pending"]
assert not [k for k, v in state.get("transcripts", {}).items() if v.get("in_flight")], state["transcripts"]
PY
  [ "$status" -eq 0 ] || { echo "$output"; cat "$BATS_TEST_TMPDIR/a.out"; return 1; }
}

@test "reprocess refuses while a capture of that transcript is in flight, and changes nothing" {
  start_op_stub "running"
  sleep 300 & sp=$!
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(date +%s)"
  before="$(shasum "$OFFSETS")"
  run python3 "$CAPTURE" reprocess "$TRANSCRIPT"
  kill "$sp"
  [ "$status" -ne 0 ]
  case "$output" in *"reprocess: a capture of this transcript is in flight (pid $sp)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(shasum "$OFFSETS")" = "$before" ]; [ "$(post_count)" -eq 0 ]
}

# --- a transcript read while it is being written (Decisions 16 and 17) --------
@test "a torn last line is left for the next run and captured whole there; no turn is pushed twice" {
  # Review reproduction on plan 1: the torn line was skipped as undecodable,
  # the offset advanced past it, and "THE DECISION: ship Friday" never reached memory.
  start_op_stub "running"
  printf '{"type":"user","message":{"role":"user","content":"THE DECISION: ship Fri' >> "$TRANSCRIPT"
  run python3 "$CAPTURE" capture; [ "$status" -eq 0 ]
  printf 'day"}}\n{"type":"user","message":{"role":"user","content":"turn three"}}\n' >> "$TRANSCRIPT"
  run python3 "$CAPTURE" capture; [ "$status" -eq 0 ]
  grep -q 'THE DECISION: ship Friday' "$STUB_POSTS"
  [ "$(grep -c 'turn three' "$STUB_POSTS")" -eq 1 ]
  [ "$(grep -c 'what did we decide about the scheduler' "$STUB_POSTS")" -eq 1 ]
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  [ "$(stored_offset)" = "$size" ]
}

@test "bytes appended after a run measured the transcript are not read by that run: it advances only to what it measured" {
  start_op_stub "running"
  run python3 - "$ROOT/core" "$TRANSCRIPT" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import capture
cfg = capture._require_env()
t = sys.argv[2]
orig = pathlib.Path.stat
measured = []
def stat(self, *a, **k):
    r = orig(self, *a, **k)
    if not measured and str(self) == t:
        measured.append(r.st_size)       # _push_span has just measured; now the session writes on
        with open(t, "a") as f:
            f.write('{"type":"user","message":{"role":"user","content":"a late turn"}}\n')
    return r
pathlib.Path.stat = stat
ok, entry, advance_to = capture._push_span(t, 0, cfg)
assert measured and ok and advance_to == measured[0], (measured, ok, advance_to)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run grep -q 'a late turn' "$STUB_POSTS"; [ "$status" -ne 0 ]
}

@test "a transcript in a shape this build cannot read is reported once as a parse failure, and the offset is held, not advanced past it" {
  start_op_stub "running"
  printf '{"kind":"user","body":"moved"}\n{"type":"user","message":{"role":"user","parts":["moved too"]}}\n' > "$TRANSCRIPT"
  run python3 "$CAPTURE" capture; [ "$status" -eq 0 ]
  case "$output" in *"capture: transcript parse failure — 2 of 2 entries have a shape this build does not read"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"offset held at 0"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(stored_offset)" = "0" ]; [ "$(post_count)" -eq 0 ]
  run python3 "$CAPTURE" capture
  case "$output" in *"parse failure"*) echo "said twice: $output"; return 1 ;; *) : ;; esac
  [ "$(stored_offset)" = "0" ]
}

@test "a run whose claim was cleared as overdue pushes nothing and records no pending entry: its successor's push under the same document_ids is the only one" {
  # Review finding: the overdue run appended its shorter pending entry
  # (0 -> size1) beside the successor's (0 -> size2) under the same ids; a later
  # failure verdict would re-push the shorter one over the longer document.
  # Here the run's time limit stops it before its POST (a successor can clear
  # a live claim only past the ceiling, which is past that limit); the claim
  # re-check under the lock and section (c)'s check are the further guards.
  start_op_stub "running"
  run python3 - "$ROOT/core" "$TRANSCRIPT" "$CAPTURE" <<'PY'
import json, subprocess, sys
sys.path.insert(0, sys.argv[1])
import capture
cfg = capture._require_env()
t = sys.argv[2]
status, ctx = capture._claim_run(t, cfg, None)            # run A claims offset 0
assert status == "claimed", status
with capture._state_lock(cfg["tenant_home"]):             # ... and becomes overdue
    s = capture._load_state(cfg["tenant_home"])
    s["transcripts"][ctx["key"]]["in_flight"]["started"] -= 10000
    capture._save_state(cfg["tenant_home"], s)
ctx["me"]["started"] -= 10000
with open(t, "a") as f:                                   # the session writes on
    f.write('{"type":"user","message":{"role":"user","content":"grown since"}}\n')
b = subprocess.run([sys.executable, sys.argv[3], "capture", "--transcript", t],
                   capture_output=True, text=True, stdin=subprocess.DEVNULL)   # run B
assert "cleared a dead in-flight claim" in b.stdout, b.stdout
ok, entry, advance_to = capture._push_span(t, ctx["offset"], cfg, ctx)      # A finishes late
capture._finish_run(ctx, cfg, [], entry, advance_to, t)
state = json.load(open(capture._offsets_path(cfg["tenant_home"])))
at0 = [e for e in state["pending"] if e.get("offset_from") == 0]
assert len(at0) == 1, at0
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(post_count)" -eq 1 ]
}

# Review of Task 9: the two guards past the time limit (the claim re-check just
# before the POST, and section (c)'s refusal) are reached only when a successor
# takes the claim while this run's own clock still says it has time -- the
# laptop slept mid-run, or a response outlasted its socket timeout.
@test "a run whose claim a successor took, while its own time limit still allows the POST, pushes nothing and records nothing: the claim is re-checked just before the POST" {
  start_op_stub "running"
  run python3 - "$ROOT/core" "$TRANSCRIPT" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import capture
cfg = capture._require_env()
t = sys.argv[2]
status, ctx = capture._claim_run(t, cfg, None)
assert status == "claimed", status
with capture._state_lock(cfg["tenant_home"]):               # a successor's claim, taken after a sleep
    s = capture._load_state(cfg["tenant_home"])
    s["transcripts"][ctx["key"]]["in_flight"] = {"offset": 0, "pid": 1, "proc_started": 1,
                                                 "started": ctx["me"]["started"] + 1}
    capture._save_state(cfg["tenant_home"], s)
assert capture._run_timeout(ctx, cfg, 120) >= 1              # this run's own clock allows the POST
ok, entry, advance_to = capture._push_span(t, ctx["offset"], cfg, ctx)
assert (ok, entry, advance_to) == (True, None, None), (ok, entry, advance_to)
capture._finish_run(ctx, cfg, [], entry, advance_to, t)
state = json.load(open(capture._offsets_path(cfg["tenant_home"])))
assert state["pending"] == [], state["pending"]
assert state["offsets"] == {}, state["offsets"]
assert state["transcripts"][ctx["key"]]["in_flight"]["pid"] == 1, "the successor's claim was touched"
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(post_count)" -eq 0 ]
}

@test "a run whose claim a successor took after its POST records no pending entry and does not advance the offset (section (c))" {
  start_op_stub "running"
  run python3 - "$ROOT/core" "$TRANSCRIPT" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import capture
cfg = capture._require_env()
t = sys.argv[2]
status, ctx = capture._claim_run(t, cfg, None)
assert status == "claimed", status
ok, entry, advance_to = capture._push_span(t, ctx["offset"], cfg, ctx)
assert ok and entry is not None and advance_to, (ok, entry, advance_to)
with capture._state_lock(cfg["tenant_home"]):               # taken over between the POST and section (c)
    s = capture._load_state(cfg["tenant_home"])
    s["transcripts"][ctx["key"]]["in_flight"] = {"offset": 0, "pid": 1, "proc_started": 1,
                                                 "started": ctx["me"]["started"] + 1}
    capture._save_state(cfg["tenant_home"], s)
capture._finish_run(ctx, cfg, [], entry, advance_to, t)
state = json.load(open(capture._offsets_path(cfg["tenant_home"])))
assert state["pending"] == [], state["pending"]
assert state["offsets"] == {}, state["offsets"]
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(post_count)" -eq 1 ]
}

@test "with verification on (a close), a run that pushes nothing because it lost its claim or ran out of time fails, so close.sh never says close complete over it" {
  start_op_stub "completed"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=5 run python3 - "$ROOT/core" "$TRANSCRIPT" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import capture
cfg = capture._require_env()
t = sys.argv[2]

def take_over(*a, **k):                                     # a successor takes the claim mid-run
    with capture._state_lock(cfg["tenant_home"]):
        s = capture._load_state(cfg["tenant_home"])
        key = capture._transcript_key(t)
        mine = s["transcripts"][key]["in_flight"]
        s["transcripts"][key]["in_flight"] = {"offset": 0, "pid": 1, "proc_started": 1,
                                              "started": mine["started"] + 1}
        capture._save_state(cfg["tenant_home"], s)
    return []
real = capture._reconcile_snapshot
capture._reconcile_snapshot = take_over
try:
    capture.main(["capture", "--transcript", t])
    raise AssertionError("a close that pushed nothing exited 0")
except SystemExit as e:
    assert e.code == 1, e.code
capture._reconcile_snapshot = real

with capture._state_lock(cfg["tenant_home"]):               # clear the successor, then: out of time
    s = capture._load_state(cfg["tenant_home"])
    s["transcripts"] = {}
    capture._save_state(cfg["tenant_home"], s)
status, ctx = capture._claim_run(t, cfg, None)
assert status == "claimed", status
ctx["me"]["started"] -= 100000
ok, entry, advance_to = capture._push_span(t, ctx["offset"], cfg, ctx)
assert ok is False and advance_to is None, (ok, entry, advance_to)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"close again"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 0 ]; [ "$(stored_offset)" = "0" ]
}

@test "with verification on (a close), a capture of this transcript already in flight fails with a line to close again; the fast path still skips with exit 0" {
  start_op_stub "running"
  sleep 300 & sp=$!
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(date +%s)"
  run python3 "$CAPTURE" capture
  st_fast=$status; out_fast="$output"
  CAPTURE_VERIFY_EXTRACTION=1 CAPTURE_VERIFY_TIMEOUT_SEC=5 run python3 "$CAPTURE" capture
  kill "$sp"
  [ "$st_fast" -eq 0 ] || { echo "$out_fast"; return 1; }
  [ "$status" -ne 0 ]
  case "$output" in *"in flight (pid $sp"*"close again"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 0 ]
}

@test "a claim is judged by the ceiling its own run recorded: a close's longer verify timeout keeps its claim live for a tick using the default" {
  start_op_stub "running"
  sleep 300 & sp=$!
  mkdir -p "$(dirname "$OFFSETS")"
  python3 - "$OFFSETS" "$TRANSCRIPT" "$sp" "$(ps_ms "$sp")" <<'PY'
import json, os, sys, time, pathlib
p = pathlib.Path(sys.argv[1])
d = {"offsets": {}, "pending": [], "transcripts": {os.path.realpath(sys.argv[2]): {"in_flight": {
    "offset": 0, "pid": int(sys.argv[3]), "proc_started": int(sys.argv[4]),
    "started": time.time() - 600, "ceiling": 2000}}}}      # 600 s old: past the default 300 s, inside its own 2000 s
p.write_text(json.dumps(d))
PY
  run python3 "$CAPTURE" capture
  kill "$sp"
  case "$output" in *"in flight (pid $sp"*"skipping"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 0 ]
  run python3 - "$ROOT/core" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import capture
cfg = capture._require_env()
assert capture._my_claim(cfg)["ceiling"] == capture._in_flight_ceiling(cfg)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a turn holding a Unicode line separator (U+2028) is captured whole: only newline bytes end a transcript line" {
  start_op_stub "running"
  python3 - "$TRANSCRIPT" <<'PY'
import json, sys
line = json.dumps({"type": "user", "message": {"role": "user",
                   "content": "pasted para one para two: THE DECISION"}}, ensure_ascii=False)
open(sys.argv[1], "w", encoding="utf-8").write(line + "\n")
PY
  run python3 "$CAPTURE" capture; [ "$status" -eq 0 ]
  case "$output" in *"parse failure"*) echo "$output"; return 1 ;; *) : ;; esac
  grep -q 'THE DECISION' "$STUB_POSTS"
  size=$(python3 -c "import os,sys; print(os.path.getsize(sys.argv[1]))" "$TRANSCRIPT")
  [ "$(stored_offset)" = "$size" ]
}

# --- cadence and waiting (spec §4.7) ----------------------------------------
@test "--throttle: a second capture inside the interval posts nothing even with new bytes; once the interval has passed it captures" {
  start_op_stub "running"
  run python3 "$CAPTURE" capture --throttle 120; [ "$status" -eq 0 ]; [ "$(post_count)" -eq 1 ]
  printf '{"type":"user","message":{"role":"user","content":"later"}}\n' >> "$TRANSCRIPT"
  run python3 "$CAPTURE" capture --throttle 120; [ "$status" -eq 0 ]
  case "$output" in *"capture: throttled — this transcript was captured "*" s ago (interval 120 s)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 1 ]
  python3 - "$OFFSETS" "$TRANSCRIPT" <<'PY'
import json, os, sys, time
p = sys.argv[1]; d = json.load(open(p))
d["transcripts"][os.path.realpath(sys.argv[2])]["last_capture"] = time.time() - 200
open(p, "w").write(json.dumps(d))
PY
  run python3 "$CAPTURE" capture --throttle 120; [ "$status" -eq 0 ]; [ "$(post_count)" -eq 2 ]
}

@test "--wait-in-flight polls until a live claim clears, then captures" {
  start_op_stub "running"
  sleep 2 & sp=$!
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(date +%s)"
  run python3 "$CAPTURE" capture --wait-in-flight 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(post_count)" -eq 1 ]
}

@test "--wait-in-flight gives up at its limit with the close sentence, exits non-zero and leaves the offset where it was" {
  start_op_stub "running"
  sleep 300 & sp=$!
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(date +%s)"
  run python3 "$CAPTURE" capture --wait-in-flight 2
  kill "$sp"
  [ "$status" -ne 0 ]
  case "$output" in *"capture: a capture is still in flight after 2 s; wait and close again"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(stored_offset)" = "0" ]; [ "$(post_count)" -eq 0 ]
}

@test "--throttle and --wait-in-flight take whole seconds only" {
  run python3 "$CAPTURE" capture --throttle 2m
  [ "$status" -eq 2 ]
  case "$output" in *"capture: --throttle needs a whole number of seconds"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- the Stop tick and the session-end flush (spec §4.7) ---------------------
tick_home() {
  TH="$BATS_TEST_TMPDIR/tick"
  mkdir -p "$TH/core"
  cp "$ROOT/core/lib.sh" "$ROOT/core/capture.py" "$ROOT/core/capture-tick.sh" "$TH/core/"
  printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\n' > "$TH/config.yaml"
  unset TENANT_HOME TENANT_BANK HINDSIGHT_API_TENANT_API_KEY CLAUDE_CODE_SESSION_ID DAEDALUS_CONFIG
  TICK_TRANSCRIPTS="$TRANSCRIPT_DIR"; unset TRANSCRIPT_DIR
}
with_memory() {   # with_memory [interval] — after start_op_stub: the block points at the stub; the variable goes
  cat >> "$TH/config.yaml" <<EOF
memory:
  bank: tickbank
  api_url: $HINDSIGHT_API_URL
  transcript_dir: $TICK_TRANSCRIPTS
  capture_interval: ${1:-120}
EOF
  unset HINDSIGHT_API_URL
}
tick() {
  printf '{"hook_event_name":"Stop","session_id":"session-a","transcript_path":"%s"}' "$TRANSCRIPT" \
    | DAEDALUS_HOME="$TH" bash "$TH/core/capture-tick.sh" "$@"
}
await_posts() {   # await_posts <n> — up to 10 s
  local i=0
  while [ "$i" -lt 50 ]; do [ "$(post_count)" -ge "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done
  echo "expected $1 POST(s), saw $(post_count); log: $(cat "$TH/.capture.log" 2>/dev/null)"; return 1
}
await_log() {     # await_log <text> — up to 10 s
  local i=0
  while [ "$i" -lt 50 ]; do grep -qF "$1" "$TH/.capture.log" 2>/dev/null && return 0; sleep 0.2; i=$((i + 1)); done
  echo "no '$1' in: $(cat "$TH/.capture.log" 2>/dev/null)"; return 1
}

@test "capture-tick.sh and --final exit 0 silently without a memory: block: no output, no request, no log" {
  tick_home; start_op_stub "running"
  run tick; [ "$status" -eq 0 ]; [ -z "$output" ]
  run tick --final; [ "$status" -eq 0 ]; [ -z "$output" ]
  sleep 1
  [ "$(post_count)" -eq 0 ]; [ ! -e "$TH/.capture.log" ]
}

@test "with a memory: block and no capture variables in the environment, a Stop tick captures the payload's transcript through the block, and logs the payload keys once" {
  tick_home; start_op_stub "running"; with_memory
  run tick; [ "$status" -eq 0 ]; [ -z "$output" ]
  await_posts 1
  grep -q '^POST /v1/default/banks/tickbank/memories' "$BATS_TEST_TMPDIR/requests.log"
  grep -q 'session session-a' "$STUB_POSTS"
  await_log "capture: queued"
  grep -qF 'capture-tick: first hook payload keys: hook_event_name,session_id,transcript_path' "$TH/.capture.log"
  run tick; await_log "throttled"
  [ "$(grep -c 'first hook payload keys' "$TH/.capture.log")" -eq 1 ]
}

@test "an environment value overrides the memory: block's field in the tick" {
  tick_home; start_op_stub "running"; with_memory
  export TENANT_BANK=envbank
  run tick; [ "$status" -eq 0 ]
  await_posts 1
  grep -q '^POST /v1/default/banks/envbank/memories' "$BATS_TEST_TMPDIR/requests.log"
}

@test "the tick returns at once while the push is slow — a Stop hook never waits on memory" {
  tick_home; start_op_stub "running"; with_memory
  printf '5' > "$BATS_TEST_TMPDIR/post_sleep"
  t0="$(python3 -c 'import time; print(time.time())')"
  run tick
  t1="$(python3 -c 'import time; print(time.time())')"
  [ "$status" -eq 0 ]
  python3 -c 'import sys; d = float(sys.argv[2]) - float(sys.argv[1]); assert d < 2, "the hook took %.1f s" % d' "$t0" "$t1"
  await_posts 1
}

@test "the Stop tick is throttled per transcript; --final captures what the throttle held back" {
  tick_home; start_op_stub "running"; with_memory
  run tick; await_posts 1; await_log "capture: queued"
  printf '{"type":"user","message":{"role":"user","content":"the last turn"}}\n' >> "$TRANSCRIPT"
  run tick; await_log "throttled"
  [ "$(post_count)" -eq 1 ]
  run tick --final; [ "$status" -eq 0 ]
  await_posts 2
}

@test "the session-end flush waits out a Stop tick still in flight, then captures the turns appended after it" {
  # A --final that skips a live claim (as a Stop tick does) loses the tail:
  # nothing re-ticks an ended session's transcript.
  tick_home; start_op_stub "running"; with_memory
  printf '4' > "$BATS_TEST_TMPDIR/post_sleep"
  run tick; await_posts 1
  printf '{"type":"user","message":{"role":"user","content":"the last turn"}}\n' >> "$TRANSCRIPT"
  run tick --final; [ "$status" -eq 0 ]
  await_posts 2
  await_log "capture: queued"
  run grep -F "skipping" "$TH/.capture.log"; [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ "$(grep -c 'the last turn' "$STUB_POSTS")" -eq 1 ]
}

@test "--wait-out-claim waits for the claim in flight to its own recorded ceiling, not a fixed limit, then clears it and captures" {
  start_op_stub "running"
  sleep 300 & sp=$!
  # Live for 3 s more by its own ceiling (300 s), although its pid lives on.
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(( $(date +%s) - 297 ))" "" 300
  run python3 "$CAPTURE" capture --wait-out-claim
  kill "$sp"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"cleared a dead in-flight claim"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(post_count)" -eq 1 ]
}

@test "a session-end flush that must give up says so in a sentence fit for a hook: the last turns were not stored, and the close command that stores them" {
  # A claim dated ahead of the clock (the wall clock stepped back) stays live
  # past the flush's wait; the flush gives up rather than hanging.
  tick_home; start_op_stub "running"; with_memory
  OFFSETS="$TH/state/hindsight/offsets.json"
  sleep 300 & sp=$!
  seed_in_flight "$sp" "$(ps_ms "$sp")" "$(( $(date +%s) + 600 ))" "" 2
  run tick --final; [ "$status" -eq 0 ]
  await_log "the session-end flush gave up after" || { kill "$sp"; return 1; }
  kill "$sp"
  grep -qF "the last turns of this session were not stored — run core/close.sh --transcript $TRANSCRIPT" "$TH/.capture.log"
  run grep -F "wait and close again" "$TH/.capture.log"; [ "$status" -ne 0 ]
  [ "$(post_count)" -eq 0 ]
}

@test "the tick honours memory.capture_interval end to end: with 2 s a second tick at once is throttled (the log names 2 s, not the 120 s default), and a tick after 3 s captures" {
  # Every other tick test uses 120, which is also memory_env's default: a tick
  # that ignored $CAPTURE_INTERVAL, or hard-coded --throttle 120, stayed green.
  tick_home; start_op_stub "running"; with_memory 2
  run tick; await_posts 1; await_log "capture: queued"
  printf '{"type":"user","message":{"role":"user","content":"a second turn"}}\n' >> "$TRANSCRIPT"
  run tick; await_log "throttled"
  grep -qF "(interval 2 s)" "$TH/.capture.log"
  run grep -qF "(interval 120 s)" "$TH/.capture.log"; [ "$status" -ne 0 ]
  [ "$(post_count)" -eq 1 ]
  sleep 3
  run tick; await_posts 2
}

@test "the payload's session id is the fallback when it names no transcript_path" {
  tick_home; start_op_stub "running"; with_memory
  printf '{"hook_event_name":"Stop","session_id":"session-a"}' | DAEDALUS_HOME="$TH" bash "$TH/core/capture-tick.sh"
  await_posts 1
  grep -q 'session session-a' "$STUB_POSTS"
}

@test "the tracked settings.json runs capture-tick.sh on Stop (10 s, spec §4.6) and capture-tick.sh --final on SessionEnd" {
  python3 - "$ROOT/.claude/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["hooks"]
stop = [h for g in d["Stop"] for h in g["hooks"] if "capture-tick.sh" in h["command"]]
assert len(stop) == 1 and "--final" not in stop[0]["command"] and stop[0]["timeout"] == 10, stop
end = [h for g in d["SessionEnd"] for h in g["hooks"] if "capture-tick.sh --final" in h["command"]]
assert len(end) == 1 and end[0]["timeout"] == 5, end
PY
}

@test "capture-tick.sh --dry-run prints the bank, server, transcript directory and what a tick would capture — and touches nothing (the upgrade predicate)" {
  tick_home; start_op_stub "running"; with_memory
  run tick --dry-run; [ "$status" -eq 0 ]
  case "$output" in *"capture-tick (dry run): bank tickbank, server http://127.0.0.1:"*", transcript directory $TICK_TRANSCRIPTS, one capture per transcript every 120 s"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"would capture $TRANSCRIPT unless it was captured in the last 120 s"*) : ;; *) echo "$output"; return 1 ;; esac
  run tick --final --dry-run; [ "$status" -eq 0 ]
  case "$output" in *"would flush $TRANSCRIPT, waiting out a capture in flight"*) : ;; *) echo "$output"; return 1 ;; esac
  sleep 1
  [ "$(post_count)" -eq 0 ]; [ ! -e "$TH/.capture.log" ]; [ ! -e "$TH/state/hindsight" ]
}

@test "capture-tick.sh --dry-run without a memory: block, or with one it cannot use, says a tick would do nothing" {
  tick_home
  run tick --dry-run; [ "$status" -eq 0 ]
  [ "$output" = "capture-tick (dry run): no memory: block in config.yaml — a tick would do nothing." ]
  printf 'memory:\n  capture_interval: 120\n' >> "$TH/config.yaml"
  run tick --dry-run; [ "$status" -eq 0 ]
  case "$output" in *"capture-tick (dry run): episodic capture needs memory.bank in config.yaml"*"— a tick would do nothing."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$TH/.capture.log" ]
}

# Spec A12: the shape capture reads, pinned to a transcript of the live build.
@test "the live-shape fixture transcript reads with no unknown entries: capture turns its operator and assistant text into turns" {
  F="$BATS_TEST_DIRNAME/fixtures/transcripts/live.jsonl"
  run python3 - "$ROOT/core" "$F" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import capture
lines = open(sys.argv[2]).read().splitlines()
convo, unknown, total = capture._scan_transcript(lines)
assert total >= 6, total
assert unknown == 0, "entries this build's parser cannot read: %d of %d" % (unknown, total)
assert "User: placeholder text" in convo and "Assistant: placeholder text" in convo, convo[:200]
print("ok")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
