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

Its configuration is the deployment's memory: block in config.yaml, read through
lib.sh memory_env — the one place capture reads it too (spec §4.7). A TENANT_BANK
(and the other TENANT_* / HINDSIGHT_* variables) in the hook's environment still
wins, so a hook line written for an older release keeps working. It reuses
capture.py's HTTP path rather than opening a second one.

Wire it in a deployment's .claude/settings.local.json; see README.md.
"""
from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

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


def _memory_env() -> dict:
    """The memory: block through lib.sh memory_env (spec §4.7 "one place"; plan 5 Decision 23), as
    NAME -> value; {} when the block is absent or unusable, or lib.sh does not answer in two seconds."""
    try:
        p = subprocess.run(["bash", "-c", 'source "$1" >/dev/null 2>&1 && memory_configured && memory_env', "_",
                            str(ROOT / "core" / "lib.sh")], capture_output=True, text=True, timeout=2,
                           stdin=subprocess.DEVNULL, env=dict(os.environ, DAEDALUS_HOME=str(ROOT)))
    except (OSError, subprocess.SubprocessError):
        return {}
    if p.returncode != 0:
        return {}
    out = {}
    for line in p.stdout.splitlines():
        if not line.startswith("export "):
            continue
        try:
            words = shlex.split(line[len("export "):])
        except ValueError:
            continue
        if len(words) == 1 and "=" in words[0]:
            k, val = words[0].split("=", 1)
            out[k] = val
    return out


def _config() -> dict | None:
    """Resolve the bank and API base, or None when unconfigured. The environment wins; else the memory: block,
    whose values (the key among them) are placed in the environment for capture._req to read."""
    bank = os.environ.get("TENANT_BANK")
    if not bank:
        env = _memory_env()
        bank = env.get("TENANT_BANK")
        if not bank:
            return None
        for k, val in env.items():
            os.environ.setdefault(k, val)
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
