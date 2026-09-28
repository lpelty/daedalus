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
        [--transcript P | --session-id S | --hook-json F]
                        the transcript: P; else a hook payload (file F, else
                        stdin); else session S / CLAUDE_CODE_SESSION_ID via its
                        SessionStart marker or TRANSCRIPT_DIR/<S>.jsonl. Never
                        "the newest transcript": with nothing named it refuses.
    recall "<query>"    Query memory; --types world,experience,observation
    retain "<text>"     Manually store a fact
    status              Server health + bank stats + token usage + offsets
    reprocess <path>    Force full re-ingest of a transcript (ignores offset)
"""
from __future__ import annotations

import sys
import os
import json
import re
import select
import copy
import fcntl
import subprocess
from contextlib import contextmanager
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

# Spec §4.7 "Capture, incremental". A run claims its transcript (in_flight)
# for as long as an honest run takes; a claim older than capture_interval +
# the verify timeout + this margin is dead whatever its pid says.
IN_FLIGHT_MARGIN_SEC = 60
DEFAULT_CAPTURE_INTERVAL = 120
# Settling earlier spans is time-boxed per run: against an unreachable server
# every GET waits out its 15 s timeout, and the ledger holds up to 50 spans.
# Entries not reached are kept for the next run.
RECONCILE_BUDGET_SEC = 30


def _env_secs(name: str, default: int) -> int:
    raw = os.environ.get(name, "")
    return int(raw) if raw.isdigit() and int(raw) > 0 else default


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
        # Seconds between Stop-tick captures of one transcript (memory.capture_interval
        # through lib.sh memory_env); also sizes the in-flight ceiling.
        "capture_interval": _env_secs("CAPTURE_INTERVAL", DEFAULT_CAPTURE_INTERVAL),
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


def _transcript_key(transcript: str) -> str:
    """The single identity a transcript is tracked under.

    capture stored the path exactly as it was handed in while reprocess stored
    the resolved one, so on any host where the transcript directory sits behind
    a symlink (/tmp -> /private/tmp) one file acquired TWO offset keys and two
    ledger entries -- and therefore pushed the same bytes twice. Every read and
    write of the offsets map and the ledger goes through this.
    """
    try:
        return str(Path(transcript).resolve())
    except OSError:
        # A path that cannot be resolved (a vanished mount) is still worth
        # tracking under its literal spelling rather than crashing capture.
        return str(transcript)


def _lookup_offset(offsets: dict, transcript: str) -> int:
    """Read a transcript's offset, honouring a key written by an older build.

    Entries predating normalization sit under the un-normalized spelling. They
    must still be found, or the upgrade re-ingests transcripts already captured.
    """
    key = _transcript_key(transcript)
    if key in offsets:
        return offsets[key]
    if transcript in offsets:
        return offsets[transcript]
    return 0


def _clean_pending(entries: list) -> list:
    """Keep only ledger entries this code can actually act on.

    _load_state's docstring promises tolerance of old or partial state, but it
    type-checked only the two top-level keys: a pending list holding a bare
    string raised AttributeError, exited 1, and left capture dead until someone
    hand-edited the state file. An entry that cannot be used is dropped with a
    line naming what went -- never silently, since a vanishing span is the
    exact loss this ledger exists to make visible.
    """
    kept = []
    for entry in entries:
        if not isinstance(entry, dict):
            print(f"capture: discarding malformed ledger entry (expected an "
                  f"object, got {type(entry).__name__}): {entry!r:.120}",
                  file=sys.stderr)
            continue
        items = entry.get("items")
        if items is not None and not isinstance(items, list):
            print(f"capture: discarding malformed ledger entry for "
                  f"{entry.get('transcript','?')} (its items are "
                  f"{type(items).__name__}, not a list); it cannot be re-pushed",
                  file=sys.stderr)
            continue
        kept.append(entry)
    return kept


def _load_state(tenant_home: Path) -> dict:
    """Read the cursor state, tolerating a file written by an older build.

    A deployment that pulls this code has an existing offsets.json with only
    an "offsets" key (or "offsets" and "pending"). Missing keys are filled in
    rather than assumed, so the first run after an upgrade reconciles an empty
    ledger instead of crashing on its own state. Individual ledger entries are
    validated too, not just the top-level keys -- see _clean_pending.

    "transcripts" (spec §4.7) holds, per transcript key, the last_capture
    stamp the Stop tick throttles on and the in_flight claim of a run that is
    capturing it. It sits BESIDE "offsets", whose values stay plain integers,
    so an older build reading this file still finds what it expects.
    """
    p = _offsets_path(tenant_home)
    state = {"offsets": {}, "pending": [], "transcripts": {}}
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
            state["pending"] = _clean_pending(stored["pending"])
        if isinstance(stored.get("transcripts"), dict):
            state["transcripts"] = {k: v for k, v in stored["transcripts"].items() if isinstance(v, dict)}
    return state


def _save_state(tenant_home: Path, state: dict):
    """tmp + os.replace, so a concurrent reader never sees a half-written file
    (write_text truncates first: a load in that instant read '' and started
    from empty state)."""
    p = _offsets_path(tenant_home)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name("%s.tmp.%d" % (p.name, os.getpid()))
    tmp.write_text(json.dumps(state, indent=2))
    os.replace(str(tmp), str(p))


@contextmanager
def _state_lock(tenant_home: Path):
    """The one lock over offsets.json (spec §4.7). Held for a load-modify-save of
    local state only -- NEVER across a network call: a lock held through one
    slow Hindsight round trip would queue every window's capture behind it.
    Not re-entrant (flock belongs to the open file description): nothing
    called under it takes it again."""
    p = _offsets_path(tenant_home).with_name("offsets.json.lock")
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(p), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _pid_alive(pid) -> bool:
    """kill(pid, 0). EPERM means the process EXISTS (another user's, pid 1);
    only ESRCH is dead -- leaselib.pid_alive's rule (spec §4.5), copied."""
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, TypeError, ValueError):
        return False


def _proc_started(pid) -> int | None:
    """Epoch milliseconds of pid's start from `ps -o lstart=` -- the parse
    leaselib.proc_started_of uses (spec §4.5), copied because this module
    imports nothing from core."""
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True,
                             text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not out:
        return None
    try:
        return int(time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y")) * 1000)
    except ValueError:
        return None


def _my_claim() -> dict:
    pid = os.getpid()
    return {"pid": pid, "proc_started": _proc_started(pid), "started": time.time()}


def _is_mine(claim, me: dict) -> bool:
    return (isinstance(claim, dict) and claim.get("pid") == me["pid"]
            and claim.get("started") == me["started"])


def _in_flight_ceiling(cfg: dict) -> int:
    return (cfg.get("capture_interval", DEFAULT_CAPTURE_INTERVAL)
            + cfg.get("verify_timeout", VERIFY_TIMEOUT_SEC) + IN_FLIGHT_MARGIN_SEC)


def _claim_live(claim, cfg: dict, now: float) -> bool:
    """Is the run that wrote `claim` still running? Never pid-only (spec §4.7,
    the pid-reuse hole §4.5 closes for leases): dead when the pid is gone, when
    the pid's start time is not the recorded one (a recycled pid), or when the
    claim is older than the ceiling -- a tick killed at its hook timeout, or
    by sleep or shutdown, must not block every later capture of its
    transcript. A pid whose start time cannot be read is judged by pid and age."""
    if not isinstance(claim, dict):
        return False
    started = claim.get("started")
    if not isinstance(started, (int, float)) or now - started > _in_flight_ceiling(cfg):
        return False
    pid = claim.get("pid")
    if not _pid_alive(pid):
        return False
    actual = _proc_started(pid)
    if actual is None:
        return True
    try:
        return abs(actual - int(claim.get("proc_started"))) <= 2000
    except (TypeError, ValueError):
        return False


def _entry_id(entry: dict) -> tuple:
    return (entry.get("operation_id"), entry.get("transcript"),
            entry.get("offset_from"), entry.get("offset_to"))


def _claim_pending_locked(state: dict, me: dict, cfg: dict, now: float) -> list:
    """Caller holds the lock. Stamp every ledger entry no LIVE run is settling
    with this run's claim and return deep copies of them: the snapshot section
    (b) settles with no lock held. Without the claim two runs settle one entry
    -- each GETs it, and on a failure each re-pushes it."""
    snapshot = []
    for entry in state["pending"]:
        other = entry.get("claim")
        if other is not None and not _is_mine(other, me) and _claim_live(other, cfg, now):
            continue
        entry["claim"] = me
        snapshot.append(copy.deepcopy(entry))
    return snapshot


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


def _scan_transcript(raw_lines: list[str], user_label: str = "User",
                     assistant_label: str = "Assistant") -> tuple:
    """Turn transcript .jsonl lines into '<user_label>:' / '<assistant_label>:'
    turns, and count the entries this build cannot read. Returns (convo,
    unknown, total). Tool calls and tool results are skipped -- episodic
    memory wants the reasoning and decisions, not raw tool dumps.

    An entry is UNKNOWN (spec §10 A12: the transcript format is internal and
    changes between versions) when it is not a JSON object, has no string
    "type", or is a user/assistant entry whose "message" is not an object or
    whose "content" is neither a string nor a list. Other types (summaries,
    snapshots, system lines) are known, and skipped."""
    turns = []
    unknown = total = 0
    for line in raw_lines:
        line = line.strip()
        if not line:
            continue
        total += 1
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            unknown += 1
            continue
        if not isinstance(d, dict) or not isinstance(d.get("type"), str):
            unknown += 1
            continue
        t = d["type"]
        if t not in ("user", "assistant"):
            continue
        message = d.get("message")
        if not isinstance(message, dict) or not isinstance(message.get("content"), (str, list)):
            unknown += 1
            continue
        text = _extract_text(message).strip()
        if not text:
            continue
        who = user_label if t == "user" else assistant_label
        turns.append(f"{who}: {text}")
    return "\n\n".join(turns), unknown, total


def _transcript_to_convo(raw_lines: list[str], user_label: str = "User", assistant_label: str = "Assistant") -> str:
    """The turns of _scan_transcript, for a caller that needs only the text."""
    return _scan_transcript(raw_lines, user_label, assistant_label)[0]


def _report_parse_failure(cfg: dict, unknown: int, total: int) -> None:
    """Say once per deployment -- into .capture.log when the Stop tick runs
    this -- that the transcript holds entries this build cannot read: a format
    change must be visible, not a silent loss (spec §10 A12). The stamp file
    makes it once; deleting it brings the line back."""
    stamp = cfg["tenant_home"] / "state" / "hindsight" / "parse-failure-reported"
    if stamp.exists():
        return
    print(f"capture: transcript parse failure — {unknown} of {total} entries have a shape this build does "
          f"not read (the transcript format may have changed). Readable turns are still captured; these "
          f"entries are not. Said once; delete {stamp} to hear it again.")
    try:
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(datetime.now(timezone.utc).isoformat() + "\n")
    except OSError:
        pass


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
            # PROP-006: the live payload's field is error_message; "error" is
            # the fallback for an older or differently versioned server.
            reason = op.get("error_message") or op.get("error")
            return False, (f"status={status}, retry_count={op.get('retry_count')}, "
                           f"error={reason!r}, operation {op_id}")
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
        # PROP-006: see _await_extraction.
        reason = op.get("error_message") or op.get("error")
        return "failed", (f"status={status}, retry_count={op.get('retry_count')}, "
                          f"error={reason!r}")
    return "unknown", f"status={status or 'unknown'}"


def _push_items(items: list[dict], stamp: str, bank: str, cfg: dict, timeout: int = 120) -> dict:
    """POST a batch of items for async extraction. Returns the raw response."""
    return _req("POST", _bank(bank, "/memories"),
                {"items": items, "async": True, "document_tags": [stamp]},
                timeout=timeout, api=cfg["api"])


def _enforce_ledger_cap(entries: list) -> list:
    """Trim the ledger to MAX_PENDING_SPANS, announcing anything forced out.

    Each entry carries the pushed content, so an indefinitely unreachable
    backend would grow this file without limit and tax every later run. Drop
    the OLDEST first -- and say so at full volume, naming each span, because a
    span leaving this ledger unconfirmed is the exact loss it exists to prevent.

    Applied at every point that can grow the ledger, not only in reconcile:
    eviction used to run before the fast path appended its new entry, so the
    file settled at one entry ABOVE the stated cap.
    """
    if len(entries) <= MAX_PENDING_SPANS:
        return entries
    cut = len(entries) - MAX_PENDING_SPANS
    overflow, kept = entries[:cut], entries[cut:]
    print(f"capture: WARNING — {len(overflow)} unconfirmed span(s) exceeded "
          f"the retry ledger's capacity and are being ABANDONED. These were "
          f"pushed but never confirmed stored; if the backend did not "
          f"extract them, they are lost:", file=sys.stderr)
    for e in overflow:
        print(f"capture:   LOST? {e.get('transcript','?')} "
              f"[{e.get('offset_from')}->{e.get('offset_to')}] "
              f"operation={e.get('operation_id')} pushed={e.get('pushed_at')}",
              file=sys.stderr)
    return kept


def _reconcile_snapshot(cfg: dict, snapshot: list, offsets: dict, deadline: float) -> list:
    """Section (b) of spec §4.7: settle a SNAPSHOT of the ledger with no lock held.

    The fast path advances the offset on acceptance because a hook must not
    block -- but acceptance is not storage, and the process that would learn
    the verdict is already gone. So each push records what it pushed, and a
    LATER run (the next Stop tick, the session-end flush, or close.sh) asks
    the server how it turned out.

    A span whose extraction failed is re-pushed with the SAME document_ids it
    was pushed with the first time. That is not incidental: hindsight-api
    treats a repeated document_id as a re-ingest that DELETES that document's
    prior memories, so re-pushing under the original ids REPLACES the failed
    attempt. Re-deriving ids from a fresh offset would duplicate the content
    instead (2026-07-09 incident, and GC-6).

    An entry is only ever dropped on a confirmed verdict or on being
    superseded (below) -- never on an unreachable server, and never merely
    because it is old.

    SUPERSEDED ENTRIES. Re-pushing under the original document_ids is a
    REPLACEMENT, which is what makes the retry safe -- but only while those ids
    still hold the content the entry describes. If the transcript was re-read
    from an EARLIER offset (reprocess, or any path that rewinds the cursor),
    the next capture derives the same ids from the same starting offset while
    reading MORE bytes, so those ids now hold newer, longer content. Re-pushing
    the older items would delete it. The test is whether the cursor has
    REWOUND behind this entry -- not whether it has merely moved: a cursor
    that advanced past an entry is the normal case (the transcript grew). An
    entry with no stored cursor at all is treated as superseded.

    Returns verdicts {"id": _entry_id(entry), "action": "drop" | "replace",
    "entry": <the retried entry, for replace>}; an entry with no verdict is
    kept. _finish_run applies them under the lock, and only to entries this run
    still has claimed. Entries not reached before `deadline` are kept for the
    next run, so an unreachable server cannot hold one run open indefinitely.
    """
    bank = cfg["bank"]
    verdicts = []
    for entry in snapshot:
        eid = _entry_id(entry)
        op_id = entry.get("operation_id")
        items = entry.get("items") or []
        span = (f"{entry.get('transcript','?')} "
                f"[{entry.get('offset_from')}->{entry.get('offset_to')}]")
        transcript = entry.get("transcript")
        if transcript is not None:
            has_offset = (_transcript_key(transcript) in offsets
                          or transcript in offsets)
            current = _lookup_offset(offsets, transcript)
            end = entry.get("offset_to")
            rewound = (not isinstance(end, int)) or current < end
            if not has_offset or rewound:
                print(f"capture: pending span SUPERSEDED — {span}; the stored "
                      f"offset for this transcript is now "
                      f"{current if has_offset else 'unset'}, behind this "
                      f"span's end, so its document_ids will be rewritten by a "
                      f"re-read. Discarding it rather than re-pushing older "
                      f"content over newer.", file=sys.stderr)
                verdicts.append({"id": eid, "action": "drop"})
                continue
        if not op_id or not items:
            # Nothing actionable: no id to poll and/or no content to re-push.
            # Keep it visible rather than dropping it silently.
            print(f"capture: pending entry for {span} is unusable "
                  f"(operation_id={op_id!r}, {len(items)} item(s)); keeping it "
                  f"in the ledger for an operator to see")
            continue
        if time.time() >= deadline:
            print(f"capture: pending span left for the next run — {span} "
                  f"(this run's settling time is used up)")
            continue
        verdict, detail = _check_operation(op_id, bank, cfg)
        if verdict == "ok":
            print(f"capture: pending span confirmed stored — {span} ({detail})")
            verdicts.append({"id": eid, "action": "drop"})
            continue
        if verdict == "unknown":
            print(f"capture: pending span still unresolved — {span} ({detail}); "
                  f"will re-check next run")
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
            continue
        new_op = res.get("operation_id") or res.get("id")
        if not new_op:
            print("capture: re-push accepted but returned no operation id; "
                  "span stays in the ledger (cannot verify)")
            continue
        # The retry is itself unverified until someone checks it. Carry the
        # entry forward under the new operation id so the next run settles it.
        retried = dict(entry)
        retried["operation_id"] = new_op
        retried["retried_at"] = datetime.now(timezone.utc).isoformat()
        retried["retries"] = int(entry.get("retries") or 0) + 1
        verdicts.append({"id": eid, "action": "replace", "entry": retried})
    return verdicts


# --- commands ----------------------------------------------------------------
def _run_timeout(ctx: dict | None, cfg: dict, cap: int) -> int:
    """Seconds one network call of this run may take: `cap`, or what is left
    before the run's claim could be cleared as overdue (its start + the
    in-flight ceiling, less 5 s) when that is sooner. 0 = no time left. With
    it, a run's POST never lands after a successor was allowed to start
    (plan 2 Decision 3)."""
    if not ctx:
        return cap
    left = ctx["me"]["started"] + _in_flight_ceiling(cfg) - 5 - time.time()
    return max(0, min(cap, int(left)))


def _still_claimed(ctx: dict, cfg: dict) -> bool:
    """Is this run's in_flight claim still the one on file? Read under the
    lock, with no network: a run whose claim another run cleared as overdue
    must not push -- its successor pushes a superset of the same span under
    the same document_ids."""
    with _state_lock(cfg["tenant_home"]):
        state = _load_state(cfg["tenant_home"])
        held = (state["transcripts"].get(ctx["key"]) or {}).get("in_flight")
    return _is_mine(held, ctx["me"]) and held.get("offset") == ctx["offset"]


def _claim_run(transcript: str, cfg: dict, throttle: int | None) -> tuple:
    """Section (a) of spec §4.7, under the lock and with no network: load;
    honour the throttle ("throttled", seconds since the last capture) -- checked
    first, so a throttled tick never reports another run as in flight; clear a
    dead in_flight claim; refuse a live one ("busy", its claim); otherwise stamp
    in_flight = {offset, pid, proc_started, started} and last_capture, claim
    the ledger entries this run will settle, save, and return ("claimed", ctx)."""
    th = cfg["tenant_home"]
    key = _transcript_key(transcript)
    me = _my_claim()
    now = me["started"]
    with _state_lock(th):
        state = _load_state(th)
        slot = state["transcripts"].setdefault(key, {})
        last = slot.get("last_capture")
        if throttle and isinstance(last, (int, float)) and now - last < throttle:
            return "throttled", int(now - last)
        held = slot.get("in_flight")
        if held is not None:
            if _claim_live(held, cfg, now):
                return "busy", held
            pid = held.get("pid") if isinstance(held, dict) else "?"
            print(f"capture: cleared a dead in-flight claim for this transcript (pid {pid})")
            slot.pop("in_flight", None)
        offset = _lookup_offset(state["offsets"], transcript)
        snapshot = _claim_pending_locked(state, me, cfg, now)
        slot["in_flight"] = dict(me, offset=offset)
        slot["last_capture"] = now
        offsets = dict(state["offsets"])
        _save_state(th, state)
    return "claimed", {"key": key, "offset": offset, "me": me, "snapshot": snapshot, "offsets": offsets}


def _push_span(transcript: str, offset: int, cfg: dict, ctx: dict | None = None) -> tuple:
    """Section (b)'s push, no lock held across the network: the complete lines
    past `offset`. Returns (ok, pending_entry, advance_to); _finish_run applies
    both under the lock. Each push gets document_ids unique to (session,
    offset, part) -- hindsight-api treats a repeated document_id as a re-ingest
    that DELETES the document's prior memories, so reusing the bare session id
    destroyed every earlier delta (2026-07-09 incident).

    WHOLE LINES ONLY (plan 2 Decision 16). A detached Stop tick reads a
    transcript Claude Code is still writing: read exactly the bytes up to the
    size measured here, and stop at the last newline. A torn last line is left
    for the next run (read as undecodable and advanced past, it was lost), and
    bytes appended after the measurement are not read by this run (read to end
    of file, they were read again by the next run under new document_ids).

    With `ctx` (a claimed run), the POST is sent only while this run's claim
    is still the one on file, and is given at most what is left before the
    claim could be cleared as overdue (Decision 3)."""
    bank = cfg["bank"]
    size = Path(transcript).stat().st_size
    if size <= offset:
        print(f"capture: nothing new ({transcript}, offset={offset}, size={size})")
        return True, None, None

    with open(transcript, "rb") as f:
        f.seek(offset)
        data = f.read(size - offset)
    cut = data.rfind(b"\n")
    if cut < 0:
        print("capture: the new bytes end mid-line; the rest of the line is left for the next run")
        return True, None, None
    end = offset + cut + 1
    new_lines = data[:cut + 1].decode("utf-8", errors="replace").splitlines()

    convo, unknown, total = _scan_transcript(new_lines, cfg["user_label"], cfg["assistant_label"])
    if unknown:
        _report_parse_failure(cfg, unknown, total)
    if not convo.strip():
        if unknown:
            # Nothing readable and something unrecognised: hold the offset, so a
            # build that reads this format can still capture it (Decision 17).
            print(f"capture: nothing readable in the new bytes ({unknown} of {total} entries in a shape "
                  f"this build does not read); offset held at {offset}")
            return True, None, None
        print("capture: new bytes but no conversational text; offset advanced.")
        return True, None, end

    sid = Path(transcript).stem
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    chunks = _split_convo(convo, MAX_ITEM_CHARS)
    items = [{"content": chunk,
              "context": f"session {sid} ({stamp}) part {i + 1}/{len(chunks)}",
              "document_id": f"{sid}-o{offset}-p{i:02d}"}
             for i, chunk in enumerate(chunks)]
    if ctx is not None:
        post_timeout = _run_timeout(ctx, cfg, 120)
        if post_timeout < 1:
            print("capture: this run is out of time before its push; the next run pushes the span")
            return True, None, None
        if not _still_claimed(ctx, cfg):
            print("capture: another run took over this transcript while this one worked (this run's claim "
                  "was older than the in-flight ceiling); this run pushes nothing")
            return True, None, None
    else:
        post_timeout = 120
    # async=true -> server queues extraction and returns 202 on ACCEPTANCE.
    # Acceptance is not storage: extraction happens later and can fail on its
    # own (PROP-002). Whether we wait for that verdict is the caller's choice.
    res = _push_items(items, stamp, bank, cfg, timeout=post_timeout)
    if res.get("_error"):
        print(f"capture: retain FAILED — {res['_error']} {res.get('_body','')}")
        # Do not advance the offset; retry next time. Report failure to the
        # caller so an explicit close (core/close.sh) can refuse to claim the
        # session was recorded when it was not.
        return False, None, None

    op_id = res.get("operation_id") or res.get("id")

    # PROP-002: the offset is the only record of what has been captured, so it
    # must not advance past a span the server never stored. With verification
    # on (core/close.sh) the offset advances only after the operation reaches
    # a terminal success -- an explicit close can wait, and it promises the
    # session was recorded.
    entry = None
    if cfg.get("verify_extraction"):
        if not op_id:
            print("capture: retain accepted but returned no operation id; "
                  "offset NOT advanced (cannot verify extraction)")
            return False, None, None
        ok, detail = _await_extraction(op_id, bank, cfg)
        if not ok:
            print(f"capture: extraction FAILED — {detail}. Offset NOT advanced "
                  f"(offset stays {offset}); the span will be retried.")
            return False, None, None
        print(f"capture: extraction confirmed ({detail})")
    else:
        # The fast path (the Stop tick, the session-end flush). It cannot wait
        # for the verdict, so the offset advances -- but the span is NOT
        # abandoned: it is recorded as pending with the exact items and
        # document_ids it was pushed under, and a later run settles it.
        # Advancing rather than holding is deliberate: holding would make the
        # next run re-read from the same start against a transcript that has
        # since GROWN, deriving document_ids for content already ingested --
        # duplication, not replacement (GC-6, 2026-07-09 incident).
        entry = {
            "operation_id": op_id,
            "transcript": _transcript_key(transcript),
            "offset_from": offset,
            "offset_to": end,
            "stamp": stamp,
            "pushed_at": datetime.now(timezone.utc).isoformat(),
            "items": items,
        }
        if op_id:
            print(f"capture: extraction unverified (fast path); span "
                  f"[{offset}->{end}] recorded as pending under operation "
                  f"{op_id} — the next run confirms or re-pushes it")
        else:
            print("capture: retain accepted but returned no operation id; span "
                  f"[{offset}->{end}] recorded as pending and UNVERIFIABLE — "
                  "it needs an operator, not a retry")
    verb = "captured" if cfg.get("verify_extraction") else "queued"
    print(f"capture: {verb} {len(convo)} chars from {sid} in {len(items)} "
          f"item(s) (offset {offset}->{end}). {res}")
    return True, entry, end


def _finish_run(ctx: dict, cfg: dict, verdicts: list, new_entry: dict | None,
                advance_to: int | None, transcript: str | None) -> None:
    """Section (c) of spec §4.7, under the lock: reload; apply each verdict only
    to an entry this run still has claimed (one another run settled or retried
    meanwhile is left alone); release this run's claims; and -- only while this
    run's in_flight claim is still the one on file (the same offset it claimed)
    -- append this run's own pending entry, advance the offset and clear the
    claim. A run whose claim another run cleared as overdue drops its entry and
    leaves the offset: the successor pushed a superset of the same span under
    the same document_ids, and this run's shorter entry, re-pushed on a later
    failure, would replace it (plan 2 Decision 3)."""
    th = cfg["tenant_home"]
    me = ctx["me"]
    by_id = {v["id"]: v for v in verdicts}
    with _state_lock(th):
        state = _load_state(th)
        kept = []
        for entry in state["pending"]:
            if _is_mine(entry.get("claim"), me):
                verdict = by_id.get(_entry_id(entry))
                if verdict is not None and verdict["action"] == "drop":
                    continue
                if verdict is not None and verdict["action"] == "replace":
                    entry = dict(verdict["entry"])
                else:
                    entry = dict(entry)
                entry.pop("claim", None)
            kept.append(entry)
        key = ctx.get("key")
        still_mine = True
        if key is not None:
            slot = state["transcripts"].setdefault(key, {})
            held = slot.get("in_flight")
            still_mine = _is_mine(held, me) and held.get("offset") == ctx["offset"]
        if new_entry is not None:
            if still_mine:
                kept.append(new_entry)
            else:
                print(f"capture: another run took over this transcript; this run's span "
                      f"[{new_entry.get('offset_from')}->{new_entry.get('offset_to')}] is not recorded — "
                      f"the other run pushed it, longer, under the same document ids")
        # Enforce the cap AFTER the append, or the ledger settles one above it.
        state["pending"] = _enforce_ledger_cap(kept)
        if key is not None:
            if advance_to is not None:
                if still_mine:
                    # Retire any entry an older build left under the
                    # un-normalized spelling: one cursor per file, not two.
                    state["offsets"].pop(transcript, None)
                    state["offsets"][key] = advance_to
                else:
                    print("capture: another run cleared this run's in-flight claim while it "
                          "worked; the offset is left for that run")
            if still_mine:
                slot.pop("in_flight", None)
        _save_state(th, state)


def _capture_path(transcript: str, cfg: dict):
    """One capture of one transcript in three sections (spec §4.7): claim it,
    settle and push with no lock, apply what this run still holds. A second
    run while one is in flight skips; a claim is always released, even when
    the push raises."""
    status, info = _claim_run(transcript, cfg, None)
    if status == "busy":
        started = time.strftime("%H:%M", time.localtime(info.get("started") or 0))
        print(f"capture: a capture of this transcript is in flight (pid {info.get('pid')}, "
              f"started {started}) — skipping")
        return True
    ctx = info
    ok, new_entry, advance_to, verdicts = False, None, None, []
    try:
        verdicts = _reconcile_snapshot(cfg, ctx["snapshot"], ctx["offsets"],
                                       time.time() + RECONCILE_BUDGET_SEC)
        ok, new_entry, advance_to = _push_span(transcript, ctx["offset"], cfg, ctx)
    finally:
        _finish_run(ctx, cfg, verdicts, new_entry, advance_to, transcript)
    return ok


def _settle_ledger(cfg: dict) -> None:
    """Settle the ledger when there is no transcript to push (the one named
    does not exist yet): the same three sections, without an in_flight claim."""
    th = cfg["tenant_home"]
    me = _my_claim()
    with _state_lock(th):
        state = _load_state(th)
        snapshot = _claim_pending_locked(state, me, cfg, me["started"])
        offsets = dict(state["offsets"])
        _save_state(th, state)
    verdicts = []
    try:
        verdicts = _reconcile_snapshot(cfg, snapshot, offsets, time.time() + RECONCILE_BUDGET_SEC)
    finally:
        _finish_run({"key": None, "offset": None, "me": me}, cfg, verdicts, None, None, None)


REFUSE_GUESS = ("capture: I cannot tell which transcript is this session's (no hook payload, "
                "no --transcript, no CLAUDE_CODE_SESSION_ID); refusing to guess — from a shell, name it: "
                "core/close.sh --transcript <path>, or capture.py capture --transcript <path>")


def _flag(args: list[str], name: str) -> str | None:
    """The value after `name`, or None when the flag is absent. A flag given
    with no value is a usage error (exit 2), never silently ignored."""
    if name not in args:
        return None
    i = args.index(name)
    if i + 1 >= len(args):
        print(f"capture: {name} needs a value", file=sys.stderr)
        sys.exit(2)
    return args[i + 1]


def _safe_sid(sid: str) -> str:
    """The marker file's spelling of a session id — verifylib._safe, copied
    because this module imports nothing from core (recall-inject.py imports it)."""
    return re.sub(r"[^A-Za-z0-9_-]", "_", str(sid or "")) or "none"


def _resolve_transcript(args: list[str], cfg: dict) -> tuple[str | None, str | None]:
    """Which transcript is this session's (spec §4.7 'the transcript is named,
    never guessed'). Returns (path, source), source being where the path came
    from: 'given' (--transcript), 'payload' (the hook payload's
    transcript_path, --hook-json F else stdin), 'marker' (a session id — the
    payload's, else --session-id, else CLAUDE_CODE_SESSION_ID — through the
    SessionStart marker's transcript_path) or 'derived' (TRANSCRIPT_DIR/
    <sid>.jsonl). Nothing to go on -> (None, None) and the caller refuses.
    The caller needs the source because a missing path means different things:
    only a hook payload may name a transcript that was never written.

    There is no 'newest transcript' fallback any more: on a live machine it
    named a session from days earlier, so close.sh could flush the wrong
    session — and with several windows or a visitor there is no right answer
    to 'newest'."""
    given = _flag(args, "--transcript")
    if given:
        return given, "given"
    payload: object = {}
    hook_json = _flag(args, "--hook-json")
    if hook_json:
        payload = json.loads(Path(hook_json).read_text())
    elif not sys.stdin.isatty():
        # A hook writes its payload and closes stdin at once. A Bash tool can
        # hand over a stdin that is an open socket and never closes (measured
        # 2026-09-27 in a subagent's Bash tool: `capture` blocked in read()
        # for minutes), so wait at most a second for it to become readable.
        ready, _, _ = select.select([sys.stdin], [], [], 1.0)
        raw = sys.stdin.read().strip() if ready else ""
        if raw:
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = {}
    if not isinstance(payload, dict):
        payload = {}
    if payload.get("transcript_path"):
        return str(payload["transcript_path"]), "payload"
    sid = payload.get("session_id") or _flag(args, "--session-id") or os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        return None, None
    marker = cfg["tenant_home"] / "state" / f"session-{_safe_sid(sid)}.json"
    try:
        recorded = json.loads(marker.read_text()).get("transcript_path")
    except (OSError, ValueError, AttributeError):
        recorded = None
    if recorded and Path(recorded).exists():
        return str(recorded), "marker"
    return str(cfg["transcript_dir"] / f"{sid}.jsonl"), "derived"


def cmd_capture(args: list[str], cfg: dict):
    # Direct calls (spec §8.5): the launcher runs `claude -p` in this home, so
    # this session's capture would record the call under the operator's label
    # on the fast path. The launcher owns that capture — it re-captures with
    # the caller's label and verified extraction — so when it sets
    # CAPTURE_DEFER_TO_CALLER=1 in claude's environment (inherited by the Stop
    # tick and the SessionEnd flush) capture stands down: no POST, offsets
    # untouched, exit 0. Never set outside a launcher. Ported from the engine's
    # hooks/capture.py. DIRECT_CALL_ID stands it down too: spec §8.5 makes it
    # the one signal every hook of a called Daedalus keys on (a visitor). The
    # launcher's own re-capture runs in the caller's environment, which
    # carries neither.
    if os.environ.get("CAPTURE_DEFER_TO_CALLER") == "1" or os.environ.get("DIRECT_CALL_ID"):
        print("capture: deferred to caller (direct call) — no post, offset unchanged")
        return True
    transcript, source = _resolve_transcript(args, cfg)
    if not transcript:
        print(REFUSE_GUESS)
        return False
    if not Path(transcript).exists():
        if source == "given":
            # An operator typed this path (close.sh --transcript) — a typo, a
            # wrong id, a relative path from the wrong directory. Reporting
            # success here would let close.sh say "close complete" (and, with
            # --commit, commit the vault) for a session that went unrecorded.
            print(f"capture: the transcript you named is not there: {transcript}")
            return False
        if source == "derived":
            # A derived path that is not there means the directory is wrong,
            # not that the session said nothing: refuse rather than report a
            # close that recorded nothing.
            print(f"capture: this session's transcript is not at {transcript} (derived from the "
                  f"session id and TRANSCRIPT_DIR); set memory.transcript_dir in config.yaml or "
                  f"pass --transcript")
            return False
        # A hook payload named it: the session may simply never have written
        # one. Still settle the ledger. A pending span belongs to a PAST transcript,
        # so its fate does not depend on there being a current one.
        _settle_ledger(cfg)
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
    transcript = _transcript_key(args[0])
    if not Path(transcript).exists():
        print(f"reprocess: no such transcript ({transcript})")
        return
    tenant_home = cfg["tenant_home"]
    with _state_lock(tenant_home):
        state = _load_state(tenant_home)
        held = (state["transcripts"].get(transcript) or {}).get("in_flight")
        if held is not None and _claim_live(held, cfg, time.time()):
            print(f"reprocess: a capture of this transcript is in flight (pid {held.get('pid')}); "
                  f"run reprocess again when it has finished")
            return False
        # Clear the cursor under both spellings: an older build tracked this file
        # under the path exactly as it was typed.
        state["offsets"].pop(transcript, None)
        state["offsets"].pop(args[0], None)

        # Drop this transcript's unsettled spans. reprocess is about to re-read the
        # file from zero and push it under the SAME document_ids, so every pending
        # entry for it describes content those ids will no longer hold. Leaving
        # them armed a re-push of the older, shorter span over the fuller one --
        # destroying whatever was appended since (2026-07-09, by another route).
        keys = {transcript, str(args[0])}
        kept, dropped = [], []
        for entry in state.get("pending") or []:
            t = entry.get("transcript")
            if t is not None and (str(t) in keys or _transcript_key(t) == transcript):
                dropped.append(entry)
            else:
                kept.append(entry)
        if dropped:
            print(f"reprocess: discarding {len(dropped)} unsettled span(s) for this "
                  f"transcript — it is being re-read from the start, so their "
                  f"document_ids are superseded by this run:")
            for e in dropped:
                print(f"reprocess:   superseded [{e.get('offset_from')}->"
                      f"{e.get('offset_to')}] operation={e.get('operation_id')}")
        state["pending"] = kept
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
