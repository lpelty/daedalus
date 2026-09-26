#!/usr/bin/env python3
"""UserPromptSubmit hook: the lease board on every prompt.

Four duties (spec §4.3): render the board for this session, touch this
session's heartbeat, recompute this session's observed changed set, and
announce a finished/released state. It never creates, numbers or binds a
lease — session-start.py does that, before the marker is written (§4.2),
and session-start.py also renders the board at start (an event's hooks run
in parallel, so a second SessionStart hook could not be ordered after it).
Emits nothing when no lease files exist; silent on its own failure. 2 s
internal budget under the 5 s hook timeout.
"""
from __future__ import annotations

import json
import os
import signal
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402
import leaselib as ll  # noqa: E402

BUDGET_SECS = 2


def _on_alarm(signum, frame):
    raise TimeoutError("lease-board budget")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    sid = v.export_session(payload)
    visitor = bool(os.environ.get("DIRECT_CALL_ID"))
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(BUDGET_SECS)
    try:
        text = ll.board_for(v.ROOT, sid, visitor)
    except Exception:
        return 0
    finally:
        signal.alarm(0)
    if text:
        v.emit({"hookSpecificOutput": {"hookEventName": payload.get("hook_event_name", "UserPromptSubmit"),
                                       "additionalContext": text}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
