"""Vendored copy: originally written for another harness's SessionEnd hook,
copied here as-is. Stdlib-only (no third-party or cross-harness imports);
configured entirely via environment variables. This is a fork with no
automatic sync path back to its origin — changes here and there diverge
independently unless someone ports them by hand.

Hindsight capture hook (SessionEnd).

Ingests new transcript bytes -> retain, for a single tenant bank. Tracks a
byte offset per transcript file so re-running over unchanged transcripts posts
nothing; a re-run after new bytes are appended posts only the delta.

Consumes env (all required unless noted): TENANT_HOME, TENANT_BANK,
TRANSCRIPT_DIR, HINDSIGHT_API_URL (default http://127.0.0.1:8888).

Cursors persist at $TENANT_HOME/state/hindsight/offsets.json.

Commands (run via `uv run --project <engine>/services/hindsight python capture.py ...`):
    capture             Ingest new transcript bytes -> retain (SessionEnd hook uses this)
        [--hook-json F] read Claude Code hook payload from file F (else stdin,
                        else newest transcript under TRANSCRIPT_DIR)
    recall "<query>"    Query memory; --types world,experience,observation
    retain "<text>"     Manually store a fact
    status              Server health + bank stats + token usage + offsets
    reprocess <path>    Force full re-ingest of a transcript (ignores offset)
"""
import sys
import os
import json
import glob
import time
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

REQUIRED_ENV = ("TENANT_HOME", "TENANT_BANK", "TRANSCRIPT_DIR")

# PROP-002 extraction verification. Observed extractions took 8-22s; the
# default ceiling leaves headroom for a slow one without letting an explicit
# close hang indefinitely. Both are overridable via env for slow deployments.
VERIFY_TIMEOUT_SEC = 120
VERIFY_POLL_SEC = 2

# PROP-007 deferred verification. Each unconfirmed span carries the items it
# pushed (up to MAX_ITEM_CHARS each) so a retry can reuse their document_ids,
# so the ledger is bounded: a backend that stays unreachable would otherwise
# grow it without limit and make every later run slower. Overflow is reported
# loudly rather than dropped quietly -- an abandoned span is exactly the thing
# this whole mechanism exists to make visible.
MAX_PENDING_SPANS = 50


def _require_env() -> dict:
    missing = [k for k in REQUIRED_ENV if not os.environ.get(k)]
    if missing:
        print(f"capture: missing required env: {', '.join(missing)}", file=sys.stderr)
        sys.exit(2)
    return {
        "api": os.environ.get("HINDSIGHT_API_URL", "http://127.0.0.1:8888"),
        "bank": os.environ["TENANT_BANK"],
        "tenant_home": Path(os.environ["TENANT_HOME"]),
        "transcript_dir": Path(os.environ["TRANSCRIPT_DIR"]),
        "user_label": os.environ.get("TENANT_USER_LABEL", "User"),
        "assistant_label": os.environ.get("TENANT_ASSISTANT_LABEL", "Assistant"),
        # PROP-002: wait for the server to confirm extraction before advancing
        # the offset. OFF by default so the SessionEnd hook still returns fast
        # -- core/close.sh turns it on, because an explicit close is the path
        # that promises "the session was recorded" and must not lie about it.
        "verify_extraction": os.environ.get("CAPTURE_VERIFY_EXTRACTION") == "1",
        "verify_timeout": int(os.environ.get("CAPTURE_VERIFY_TIMEOUT_SEC",
                                             VERIFY_TIMEOUT_SEC)),
    }


TENANT = "default"
# hindsight-api splits one document into ~30k-char sub-batches and its
# crash-recovery skips sub-batches after the first (2026-07-09 incident) —
# keep every item under one batch so each is extracted whole.
MAX_ITEM_CHARS = 28000


def _api_token() -> str | None:
    """REST bearer for the gated API surface (EL-10, ApiKeyTenantExtension).

    Env wins; else read the server's own gitignored .env, which is the single
    home of the secret (this file lives in the engine, so the service dir is
    derivable without any tenant fact). Returns None when auth is off.
    """
    tok = os.environ.get("HINDSIGHT_API_TENANT_API_KEY")
    if tok:
        return tok
    env_file = Path(__file__).resolve().parent.parent / "services" / "hindsight" / ".env"
    try:
        for line in env_file.read_text().splitlines():
            if line.startswith("HINDSIGHT_API_TENANT_API_KEY="):
                return line.split("=", 1)[1].strip().strip('"').strip("'") or None
    except OSError:
        pass
    return None


# --- HTTP helpers ------------------------------------------------------------
def _req(method: str, path: str, body: dict | None = None, timeout: int = 120, *, api: str):
    url = f"{api}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    tok = _api_token()
    if tok:
        headers["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(url, data=data, method=method,
                                 headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        return {"_error": f"HTTP {e.code}", "_body": e.read().decode()[:400]}
    except Exception as e:
        return {"_error": str(e)}


def _bank(bank: str, path: str) -> str:
    return f"/v1/{TENANT}/banks/{bank}{path}"


# --- state -------------------------------------------------------------------
def _offsets_path(tenant_home: Path) -> Path:
    return tenant_home / "state" / "hindsight" / "offsets.json"


def _load_state(tenant_home: Path) -> dict:
    """Read the cursor state, tolerating a file written by an older build.

    A deployment that pulls this code has an existing offsets.json with only
    an "offsets" key. Missing keys are filled in rather than assumed, so the
    first run after an upgrade reconciles an empty ledger instead of crashing
    on its own state.
    """
    p = _offsets_path(tenant_home)
    state = {"offsets": {}, "pending": []}
    if p.exists():
        try:
            stored = json.loads(p.read_text() or "{}")
        except json.JSONDecodeError:
            # A truncated write is recoverable; a crash here is not. Start
            # clean rather than wedging every future capture.
            print("capture: offsets.json is unreadable; starting from empty state",
                  file=sys.stderr)
            stored = {}
        if isinstance(stored.get("offsets"), dict):
            state["offsets"] = stored["offsets"]
        if isinstance(stored.get("pending"), list):
            state["pending"] = stored["pending"]
    return state


def _save_state(tenant_home: Path, state: dict):
    p = _offsets_path(tenant_home)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(state, indent=2))


# --- transcript parsing ------------------------------------------------------
def _extract_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def _transcript_to_convo(raw_lines: list[str], user_label: str = "User", assistant_label: str = "Assistant") -> str:
    """Turn transcript .jsonl lines into '<user_label>:' / '<assistant_label>:' turns.
    Tool calls and tool results are skipped — episodic memory wants the
    reasoning and decisions, not raw tool dumps."""
    turns = []
    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = d.get("type")
        if t not in ("user", "assistant"):
            continue
        text = _extract_text(d.get("message", {})).strip()
        if not text:
            continue
        who = user_label if t == "user" else assistant_label
        turns.append(f"{who}: {text}")
    return "\n\n".join(turns)


def _newest_transcript(transcript_dir: Path) -> Path | None:
    files = glob.glob(str(transcript_dir / "*.jsonl"))
    return Path(max(files, key=os.path.getmtime)) if files else None


def _split_convo(convo: str, max_chars: int = MAX_ITEM_CHARS) -> list[str]:
    """Split a convo into chunks <= max_chars, breaking at turn boundaries
    ('\\n\\n'); a single turn longer than max_chars is hard-split."""
    if len(convo) <= max_chars:
        return [convo]
    chunks, cur = [], ""
    for turn in convo.split("\n\n"):
        while len(turn) > max_chars:
            if cur:
                chunks.append(cur)
                cur = ""
            chunks.append(turn[:max_chars])
            turn = turn[max_chars:]
        cand = f"{cur}\n\n{turn}" if cur else turn
        if len(cand) > max_chars:
            chunks.append(cur)
            cur = turn
        else:
            cur = cand
    if cur:
        chunks.append(cur)
    return chunks


def _await_extraction(op_id: str, bank: str, cfg: dict) -> tuple[bool, str]:
    """Poll an async retain operation until it reaches a terminal state.

    Returns (ok, detail). `ok` is True only when the operation completed AND
    reported no extraction errors -- "the server accepted the batch" is not the
    same claim as "the memory was stored", and conflating them is what PROP-002
    documented (an accepted batch whose extraction died with four distinct
    JSONDecodeErrors, offset already advanced past it).

    A timeout returns False. That is deliberate: an unknown outcome is treated
    as failure so the offset stays put and the span is re-pushed next time.
    Re-pushing a span the server *did* eventually store is cheap (a duplicate
    document); losing one is permanent.
    """
    deadline = time.time() + cfg.get("verify_timeout", VERIFY_TIMEOUT_SEC)
    last = "no response"
    while time.time() < deadline:
        op = _req("GET", _bank(bank, f"/operations/{op_id}"), timeout=15, api=cfg["api"])
        if op.get("_error"):
            last = f"operation query failed: {op['_error']}"
            time.sleep(VERIFY_POLL_SEC)
            continue
        status = (op.get("status") or "").lower()
        # `extraction_errors_count` is absent on some operation types, so treat
        # a missing value as zero rather than as a failure.
        errs = op.get("extraction_errors_count") or 0
        if status in ("completed", "succeeded", "success"):
            if errs:
                return False, f"status={status} but extraction_errors_count={errs}"
            return True, f"status={status}, operation {op_id}"
        if status in ("failed", "error", "cancelled", "canceled"):
            return False, (f"status={status}, retry_count={op.get('retry_count')}, "
                           f"error={op.get('error')!r}, operation {op_id}")
        last = f"status={status or 'unknown'}"
        time.sleep(VERIFY_POLL_SEC)
    return False, f"timed out after {cfg.get('verify_timeout', VERIFY_TIMEOUT_SEC)}s ({last})"


def _check_operation(op_id: str, bank: str, cfg: dict) -> tuple[str, str]:
    """Ask once for an operation's state. Returns (verdict, detail) where
    verdict is 'ok', 'failed', or 'unknown'.

    This is _await_extraction's single-poll sibling: no sleeping, no deadline.
    It exists because the SessionEnd hook cannot wait -- but a LATER run can
    ask what happened, and one HTTP round trip is affordable on any path.
    'unknown' covers both "still running" and "could not reach the server",
    which are the same thing to a caller that must not throw the span away.
    """
    op = _req("GET", _bank(bank, f"/operations/{op_id}"), timeout=15, api=cfg["api"])
    if op.get("_error"):
        return "unknown", f"operation query failed: {op['_error']}"
    status = (op.get("status") or "").lower()
    errs = op.get("extraction_errors_count") or 0
    if status in ("completed", "succeeded", "success"):
        if errs:
            return "failed", f"status={status} but extraction_errors_count={errs}"
        return "ok", f"status={status}"
    if status in ("failed", "error", "cancelled", "canceled"):
        return "failed", (f"status={status}, retry_count={op.get('retry_count')}, "
                          f"error={op.get('error')!r}")
    return "unknown", f"status={status or 'unknown'}"


def _push_items(items: list[dict], stamp: str, bank: str, cfg: dict) -> dict:
    """POST a batch of items for async extraction. Returns the raw response."""
    return _req("POST", _bank(bank, "/memories"),
                {"items": items, "async": True, "document_tags": [stamp]},
                api=cfg["api"])


def _reconcile_pending(cfg: dict, state: dict) -> None:
    """Settle the fate of spans pushed by an earlier run that could not wait.

    The fast SessionEnd path advances the offset on acceptance because the
    hook must not block session exit -- but acceptance is not storage, and
    the process that would learn the verdict is already gone. So each push
    records what it pushed, and the NEXT run (any run: the next capture, or
    close.sh) asks the server how it turned out.

    A span whose extraction failed is re-pushed with the SAME document_ids it
    was pushed with the first time. That is not incidental: hindsight-api
    treats a repeated document_id as a re-ingest that DELETES that document's
    prior memories, so re-pushing under the original ids REPLACES the failed
    attempt. Re-deriving ids from a fresh offset would duplicate the content
    instead (2026-07-09 incident, and GC-6).

    Mutates `state["pending"]` in place; the caller persists it. An entry is
    only ever dropped on a confirmed verdict -- never on an unreachable
    server, and never merely because it is old.
    """
    pending = state.get("pending") or []
    if not pending:
        return
    bank = cfg["bank"]
    still_pending = []
    for entry in pending:
        op_id = entry.get("operation_id")
        items = entry.get("items") or []
        span = (f"{entry.get('transcript','?')} "
                f"[{entry.get('offset_from')}->{entry.get('offset_to')}]")
        if not op_id or not items:
            # Nothing actionable: no id to poll and/or no content to re-push.
            # Keep it visible rather than dropping it silently.
            print(f"capture: pending entry for {span} is unusable "
                  f"(operation_id={op_id!r}, {len(items)} item(s)); keeping it "
                  f"in the ledger for an operator to see")
            still_pending.append(entry)
            continue
        verdict, detail = _check_operation(op_id, bank, cfg)
        if verdict == "ok":
            print(f"capture: pending span confirmed stored — {span} ({detail})")
            continue
        if verdict == "unknown":
            print(f"capture: pending span still unresolved — {span} ({detail}); "
                  f"will re-check next run")
            still_pending.append(entry)
            continue
        # Terminal failure. Re-push the identical items under their original
        # document_ids, which replaces the failed document rather than
        # duplicating it.
        print(f"capture: pending span FAILED extraction — {span} ({detail}); "
              f"re-pushing {len(items)} item(s) under their original document_ids")
        res = _push_items(items, entry.get("stamp") or
                          datetime.now(timezone.utc).strftime("%Y-%m-%d"), bank, cfg)
        if res.get("_error"):
            print(f"capture: re-push FAILED — {res['_error']} "
                  f"{res.get('_body','')}; span stays in the ledger")
            still_pending.append(entry)
            continue
        new_op = res.get("operation_id") or res.get("id")
        if not new_op:
            print("capture: re-push accepted but returned no operation id; "
                  "span stays in the ledger (cannot verify)")
            still_pending.append(entry)
            continue
        # The retry is itself unverified until someone checks it. Carry the
        # entry forward under the new operation id so the next run settles it.
        retried = dict(entry)
        retried["operation_id"] = new_op
        retried["retried_at"] = datetime.now(timezone.utc).isoformat()
        retried["retries"] = int(entry.get("retries") or 0) + 1
        still_pending.append(retried)

    # Bound the ledger. Each entry carries the pushed content, so an
    # indefinitely unreachable backend would grow this file without limit and
    # tax every later run. Drop the OLDEST first -- and say so at full volume,
    # naming each span, because a span leaving this ledger unconfirmed is the
    # exact loss the ledger exists to prevent.
    if len(still_pending) > MAX_PENDING_SPANS:
        overflow = still_pending[:len(still_pending) - MAX_PENDING_SPANS]
        still_pending = still_pending[len(still_pending) - MAX_PENDING_SPANS:]
        print(f"capture: WARNING — {len(overflow)} unconfirmed span(s) exceeded "
              f"the retry ledger's capacity and are being ABANDONED. These were "
              f"pushed but never confirmed stored; if the backend did not "
              f"extract them, they are lost:", file=sys.stderr)
        for e in overflow:
            print(f"capture:   LOST? {e.get('transcript','?')} "
                  f"[{e.get('offset_from')}->{e.get('offset_to')}] "
                  f"operation={e.get('operation_id')} pushed={e.get('pushed_at')}",
                  file=sys.stderr)

    state["pending"] = still_pending


# --- commands ----------------------------------------------------------------
def _capture_path(transcript: str, cfg: dict):
    """Push transcript bytes past the stored offset. Each push gets
    document_ids unique to (session, offset, part) — hindsight-api treats a
    repeated document_id as a re-ingest that DELETES the document's prior
    memories, so reusing the bare session id destroyed every earlier delta
    (2026-07-09 incident)."""
    tenant_home = cfg["tenant_home"]
    bank = cfg["bank"]
    state = _load_state(tenant_home)

    # Settle earlier pushes BEFORE doing anything else. A run that has nothing
    # new to send is still the run that can learn what happened to the last
    # one, so this must not sit behind the size check below.
    _reconcile_pending(cfg, state)
    _save_state(tenant_home, state)

    offset = state["offsets"].get(transcript, 0)
    size = Path(transcript).stat().st_size
    if size <= offset:
        print(f"capture: nothing new ({transcript}, offset={offset}, size={size})")
        return True

    with open(transcript, "r", encoding="utf-8", errors="replace") as f:
        f.seek(offset)
        new_lines = f.readlines()

    convo = _transcript_to_convo(new_lines, cfg["user_label"], cfg["assistant_label"])
    if not convo.strip():
        state["offsets"][transcript] = size
        _save_state(tenant_home, state)
        print("capture: new bytes but no conversational text; offset advanced.")
        return True

    sid = Path(transcript).stem
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    chunks = _split_convo(convo, MAX_ITEM_CHARS)
    items = [{"content": chunk,
              "context": f"session {sid} ({stamp}) part {i + 1}/{len(chunks)}",
              "document_id": f"{sid}-o{offset}-p{i:02d}"}
             for i, chunk in enumerate(chunks)]
    # async=true -> server queues extraction and returns 202 on ACCEPTANCE.
    # Acceptance is not storage: extraction happens later and can fail on its
    # own (PROP-002 observed a terminal failure with four distinct
    # JSONDecodeErrors on identical input). Whether we wait for that verdict
    # is the caller's choice -- see the offset discipline below.
    res = _push_items(items, stamp, bank, cfg)
    if res.get("_error"):
        print(f"capture: retain FAILED — {res['_error']} {res.get('_body','')}")
        # Do not advance the offset; retry next time. Report failure to the
        # caller so an explicit close (core/close.sh) can refuse to claim the
        # session was recorded when it was not.
        return False

    op_id = res.get("operation_id") or res.get("id")

    # PROP-002: the offset is the only record of what has been captured, so it
    # must not advance past a span the server never stored. Advancing on
    # acceptance made every extraction failure silent AND permanent -- the next
    # capture starts after the lost span, and close.sh exited 0 reporting a
    # session that went unrecorded.
    #
    # When verification is on (core/close.sh), the offset advances only after
    # the operation reaches a terminal success -- an explicit close can afford
    # to wait, and it promises the session was recorded.
    if cfg.get("verify_extraction"):
        if not op_id:
            # Nothing to poll. Do not advance -- an unverifiable push is
            # indistinguishable from a failed one, and the offset is the thing
            # we cannot get back.
            print("capture: retain accepted but returned no operation id; "
                  "offset NOT advanced (cannot verify extraction)")
            return False
        ok, detail = _await_extraction(op_id, bank, cfg)
        if not ok:
            print(f"capture: extraction FAILED — {detail}. Offset NOT advanced "
                  f"(offset stays {offset}); the span will be retried.")
            return False
        print(f"capture: extraction confirmed ({detail})")
    else:
        # The fast SessionEnd path. It cannot wait for the verdict: hooks share
        # a ~1.5s budget and extraction takes 8-22s, so blocking here is not
        # slow, it is structurally impossible.
        #
        # So the offset advances -- but the span is NOT abandoned. It is
        # recorded as pending, with the exact items and document_ids it was
        # pushed under, and the next run settles it (_reconcile_pending above).
        #
        # Advancing rather than holding is deliberate. Holding the offset would
        # make the next run re-read from the same start against a transcript
        # that has since GROWN, deriving document_ids from a different offset
        # for content already ingested -- duplication, not replacement. Keeping
        # the pushed items verbatim is what makes the retry a same-id re-ingest,
        # which is the one form of retry hindsight-api treats as a replacement
        # (GC-6, 2026-07-09 incident).
        entry = {
            "operation_id": op_id,
            "transcript": transcript,
            "offset_from": offset,
            "offset_to": size,
            "stamp": stamp,
            "pushed_at": datetime.now(timezone.utc).isoformat(),
            "items": items,
        }
        state.setdefault("pending", []).append(entry)
        if op_id:
            print(f"capture: extraction unverified (fast path); span "
                  f"[{offset}->{size}] recorded as pending under operation "
                  f"{op_id} — the next run confirms or re-pushes it")
        else:
            # No id means no way to ask. Record it anyway: an unresolvable
            # span must be visible in durable state, not only in a log line.
            print("capture: retain accepted but returned no operation id; span "
                  f"[{offset}->{size}] recorded as pending and UNVERIFIABLE — "
                  "it needs an operator, not a retry")

    state["offsets"][transcript] = size
    _save_state(tenant_home, state)
    verb = "captured" if cfg.get("verify_extraction") else "queued"
    print(f"capture: {verb} {len(convo)} chars from {sid} in {len(items)} "
          f"item(s) (offset {offset}->{size}). {res}")
    return True


def cmd_capture(args: list[str], cfg: dict):
    transcript = None
    if "--hook-json" in args:
        payload = json.loads(Path(args[args.index("--hook-json") + 1]).read_text())
        transcript = payload.get("transcript_path")
    elif not sys.stdin.isatty():
        stdin = sys.stdin.read().strip()
        if stdin:
            try:
                transcript = json.loads(stdin).get("transcript_path")
            except json.JSONDecodeError:
                pass
    if not transcript:
        t = _newest_transcript(cfg["transcript_dir"])
        transcript = str(t) if t else None
    if not transcript or not Path(transcript).exists():
        # Still settle the ledger. A pending span belongs to a PAST transcript,
        # so its fate does not depend on there being a current one -- and this
        # is otherwise the branch where a ledger could sit unresolved forever.
        state = _load_state(cfg["tenant_home"])
        _reconcile_pending(cfg, state)
        _save_state(cfg["tenant_home"], state)
        print(f"capture: no transcript ({transcript})")
        return True
    return _capture_path(transcript, cfg)


def cmd_recall(args: list[str], cfg: dict):
    if not args:
        print('usage: recall "<query>" [--types world,experience,observation]')
        return
    query = args[0]
    body = {"query": query}
    if "--types" in args:
        body["types"] = args[args.index("--types") + 1].split(",")
    res = _req("POST", _bank(cfg["bank"], "/memories/recall"), body, api=cfg["api"])
    if res.get("_error"):
        print(f"recall failed: {res['_error']} {res.get('_body','')}")
        return
    results = res.get("results", [])
    print(f"{len(results)} result(s):")
    for r in results:
        print(f"  [{r.get('type')}] {r.get('text','')}")


def cmd_retain(args: list[str], cfg: dict):
    if not args:
        print('usage: retain "<text>"')
        return
    res = _req("POST", _bank(cfg["bank"], "/memories"), {"items": [{"content": args[0]}]}, api=cfg["api"])
    print(json.dumps(res, indent=2)[:600] if not res.get("_error")
          else f"retain failed: {res['_error']} {res.get('_body','')}")


def cmd_status(args: list[str], cfg: dict):
    health = _req("GET", "/health", timeout=10, api=cfg["api"])
    print("server:", health)
    stats = _req("GET", _bank(cfg["bank"], "/memories/list?limit=1"), timeout=10, api=cfg["api"])
    print(f"bank {cfg['bank']!r} reachable:", "_error" not in stats)
    usage = _req("GET", _bank(cfg["bank"], "/llm-requests/stats?period=7d"), timeout=10, api=cfg["api"])
    if "_error" not in usage:
        for b in usage.get("buckets", []):
            tok = b.get("tokens", {})
            print(f"  {b.get('time','')[:10]}: {b.get('total')} calls, "
                  f"{tok.get('input',0)} in / {tok.get('output',0)} out tokens")
    state = _load_state(cfg["tenant_home"])
    print("tracked transcripts:", len(state.get("offsets", {})))
    # Spans pushed but not yet confirmed stored. A non-empty list here is the
    # durable, greppable record that something may have been lost -- the whole
    # point of the ledger is that this outlives the log line.
    pending = state.get("pending") or []
    print("unverified spans:", len(pending))
    for e in pending:
        print(f"  {e.get('transcript','?')} [{e.get('offset_from')}->"
              f"{e.get('offset_to')}] operation={e.get('operation_id')} "
              f"pushed={e.get('pushed_at')} retries={e.get('retries') or 0}")


def cmd_reprocess(args: list[str], cfg: dict):
    if not args:
        print("usage: reprocess <transcript_path>")
        return
    transcript = str(Path(args[0]).resolve())
    if not Path(transcript).exists():
        print(f"reprocess: no such transcript ({transcript})")
        return
    tenant_home = cfg["tenant_home"]
    state = _load_state(tenant_home)
    state["offsets"].pop(transcript, None)
    state["offsets"].pop(args[0], None)
    _save_state(tenant_home, state)
    _capture_path(transcript, cfg)


COMMANDS = {
    "capture": cmd_capture, "recall": cmd_recall, "retain": cmd_retain,
    "status": cmd_status, "reprocess": cmd_reprocess,
}


def main(argv: list[str]):
    if not argv or argv[0] not in COMMANDS:
        print(__doc__)
        return
    cfg = _require_env()
    ok = COMMANDS[argv[0]](argv[1:], cfg)
    # A command that returns False failed. Commands that report through
    # stdout alone return None, which stays exit 0 — only an explicit
    # False is an error.
    if ok is False:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
