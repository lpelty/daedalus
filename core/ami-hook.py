#!/usr/bin/env python3
"""PostToolUse / PostToolUseFailure (Bash): the AMI's outcome row (frame-jack spec §5.4, §6.3).

`ami-hook.py outcome` reads the hook payload and, only while frame-jack is on (the sentinel
state/ami/on present), appends one row to the day's decision log keyed on the call's
tool_use_id: `ran`, `interrupted` (tool_response.interrupted true) or `failed`
(PostToolUseFailure, with the first line of its error — `Exit code N` — as error_head).
Joined on tool_use_id it is the real outcome beside the AMI's answer; it also bumps the
session's would-ask-then-failed / shortened-then-failed counts and the inferred overrides.

A separate small script, not a leg of boundary-hook.py: that leg is the boundary check with
its own budget; this is bookkeeping, and the two should not fail together. When the switch
is off it costs the interpreter start and one stat, and writes nothing. It never emits a
decision and never blocks: any failure is one stderr line and exit 0.
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOCK_SECS = 2.0         # the counters lock is waited on at most this long (the hook's timeout is 5 s); the row is written regardless


def root_dir() -> Path:
    """The deployment's home — verifylib.root_dir's rule, without importing it on the idle path."""
    env = os.environ.get("DAEDALUS_HOME")
    return Path(env).resolve() if env else HERE.parent


def main(argv) -> int:
    if argv[1:2] != ["outcome"]:
        print("usage: ami-hook.py outcome  (reads a PostToolUse / PostToolUseFailure payload on stdin)",
              file=sys.stderr)
        return 0
    root = root_dir()
    if not (root / "state" / "ami" / "on").exists():
        return 0                                     # off: one stat, nothing written
    if os.environ.get("DIRECT_CALL_ID"):
        return 0                                     # a visitor is read-only and writes nothing (as in the guard)
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    try:
        sys.path.insert(0, str(HERE))
        import amilib
        amilib.outcome_row(root, str(payload.get("session_id") or "") or None, payload,
                           deadline=time.monotonic() + LOCK_SECS)
    except Exception as e:
        print("daedalus: the AMI outcome row was not written (%r)." % e, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
