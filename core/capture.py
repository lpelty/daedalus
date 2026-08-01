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
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

REQUIRED_ENV = ("TENANT_HOME", "TENANT_BANK", "TRANSCRIPT_DIR")


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
    p = _offsets_path(tenant_home)
    if p.exists():
        return json.loads(p.read_text())
    return {"offsets": {}}


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
    offset = state["offsets"].get(transcript, 0)
    size = Path(transcript).stat().st_size
    if size <= offset:
        print(f"capture: nothing new ({transcript}, offset={offset}, size={size})")
        return

    with open(transcript, "r", encoding="utf-8", errors="replace") as f:
        f.seek(offset)
        new_lines = f.readlines()

    convo = _transcript_to_convo(new_lines, cfg["user_label"], cfg["assistant_label"])
    if not convo.strip():
        state["offsets"][transcript] = size
        _save_state(tenant_home, state)
        print("capture: new bytes but no conversational text; offset advanced.")
        return

    sid = Path(transcript).stem
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    chunks = _split_convo(convo, MAX_ITEM_CHARS)
    items = [{"content": chunk,
              "context": f"session {sid} ({stamp}) part {i + 1}/{len(chunks)}",
              "document_id": f"{sid}-o{offset}-p{i:02d}"}
             for i, chunk in enumerate(chunks)]
    # async=true -> server queues extraction; the SessionEnd hook returns fast.
    res = _req("POST", _bank(bank, "/memories"),
               {"items": items, "async": True, "document_tags": [stamp]},
               api=cfg["api"])
    if res.get("_error"):
        print(f"capture: retain FAILED — {res['_error']} {res.get('_body','')}")
        return  # do not advance offset; retry next time
    state["offsets"][transcript] = size
    _save_state(tenant_home, state)
    print(f"capture: queued {len(convo)} chars from {sid} in {len(items)} "
          f"item(s) (offset {offset}->{size}). {res}")


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
        print(f"capture: no transcript ({transcript})")
        return
    _capture_path(transcript, cfg)


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
        print(f"  [{r.get('type')}] {r.get('text','')[:200]}")


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
    COMMANDS[argv[0]](argv[1:], cfg)


if __name__ == "__main__":
    main(sys.argv[1:])
