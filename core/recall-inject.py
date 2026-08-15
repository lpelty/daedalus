#!/usr/bin/env python3
"""UserPromptSubmit hook: surface relevant episodic memory automatically.

Reads the prompt on stdin, queries the deployment's memory bank, and emits
matches as `additionalContext` so continuity survives a session boundary
without anyone having to ask for it.

Deliberately minimal. A reference implementation in this family runs to
~1,300 lines of thresholds tuned against observed misses in conversational
prompts. That tuning answers questions this deployment has not asked, so
none of it is ported. What ships is one gate (prompt length), one query,
and a cap on what is emitted. Observed misses argue for loosening; the
starting position is conservative, because an injector that fires on every
prompt and returns weak hits spends context and trains its reader to skip
past it.

Silence is the contract. Every failure path — unreachable backend, bad
stdin, absent configuration, empty result — exits 0 and emits nothing. A
hook that errors is a hook a deployment turns off, and recall is an
enhancement: a session runs without it.

Consumes the same env as core/capture.py (TENANT_HOME, TENANT_BANK,
TRANSCRIPT_DIR required; HINDSIGHT_API_URL, HINDSIGHT_API_TENANT_API_KEY
optional) and reuses its HTTP path rather than opening a second one.

Wire it in a deployment's .claude/settings.local.json; see README.md.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

# The query path lives in capture.py. Importing it keeps one HTTP
# implementation and one credential resolution for the whole product.
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from capture import _bank, _req  # noqa: E402
except Exception:  # pragma: no cover - import failure degrades to silence
    sys.exit(0)

# --- Gates -------------------------------------------------------------------
# A prompt shorter than this carries too little signal to retrieve against.
# Set here rather than tuned: the number is a starting position, and the
# evidence that would move it is a recorded miss.
MIN_PROMPT_WORDS = 4

# How many memories to surface. Enough to be useful, few enough that the
# reader still reads them. This bounds the *count* of memories, not the
# length of any one of them — see _render(), which emits each memory's
# full text. A truncated memory is a wrong memory, not a shorter one.
MAX_RESULTS = 10

# Seconds to wait on the backend. A slow query that delays every prompt is
# worse than a query that silently gives up.
TIMEOUT_SECS = 5


def _config() -> dict | None:
    """Resolve the bank and API base, or None when unconfigured."""
    import os

    bank = os.environ.get("TENANT_BANK")
    if not bank:
        return None
    return {
        "bank": bank,
        "api": os.environ.get("HINDSIGHT_API_URL", "http://127.0.0.1:8888"),
    }


def _render(results: list) -> str:
    """Format memories for injection, or an empty string when there is nothing."""
    lines = []
    for r in results[:MAX_RESULTS]:
        text = (r.get("text") or "").strip()
        if not text:
            continue
        kind = r.get("type") or "memory"
        lines.append(f"- [{kind}] {text}")
    if not lines:
        return ""
    return (
        "Relevant memories from prior sessions. These record what was "
        "observed at the time, so verify against the live system before "
        "acting on anything that would change what you do:\n"
        + "\n".join(lines)
    )


def main() -> None:
    raw = sys.stdin.read()
    if not raw.strip():
        return

    payload = json.loads(raw)
    prompt = (payload.get("prompt") or "").strip()
    if len(prompt.split()) < MIN_PROMPT_WORDS:
        return

    cfg = _config()
    if cfg is None:
        return

    res = _req("POST", _bank(cfg["bank"], "/memories/recall"),
               {"query": prompt}, timeout=TIMEOUT_SECS, api=cfg["api"])
    if res.get("_error"):
        return

    context = _render(res.get("results") or [])
    if not context:
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Fail open, unconditionally. No traceback, no partial stdout, no
        # non-zero exit — the session proceeds as though recall were absent.
        pass
    sys.exit(0)
