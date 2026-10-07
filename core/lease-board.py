#!/usr/bin/env python3
"""UserPromptSubmit hook: the lease board on every prompt.

Four duties (spec §4.3): render the board for this session, touch this
session's heartbeat, recompute this session's observed changed set, and
announce a finished/released state. And first, a fifth: record the prompt
Claude Code reports as submitted, beside the session transcript
(transcriptlib.record_prompt — promote's transcribed yes is accepted only as
a prompt reported here; critic-fix review, finding 3). It never creates, numbers or binds a
lease — session-start.py does that, before the marker is written (§4.2),
and session-start.py also renders the board at start (an event's hooks run
in parallel, so a second SessionStart hook could not be ordered after it).
Emits nothing when no lease files exist. A lease file that cannot be read
is reported as the board (one line naming the file and the fix — the same
sentence lease.sh refuses with), never swallowed: a board that vanishes reads
as "no leases", and the session starts guessing (§4.3). Silent only on its
own unexpected failure. 2 s internal budget under the 5 s hook timeout.
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
    if payload.get("hook_event_name", "UserPromptSubmit") == "UserPromptSubmit" \
            and isinstance(payload.get("transcript_path"), str) and isinstance(payload.get("prompt"), str):
        try:
            import transcriptlib as tl
            tl.record_prompt(payload["transcript_path"], payload["prompt"], str(payload.get("session_id") or ""))
        except Exception as e:     # a prompt not recorded is a yes confirm refuses, never one it accepts
            print("daedalus: the prompt was not recorded: %r" % e, file=sys.stderr)
    sid = v.export_session(payload)
    visitor = bool(os.environ.get("DIRECT_CALL_ID"))
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(BUDGET_SECS)
    try:
        text = ll.board_for(v.ROOT, sid, visitor)
    except ll.Refused as e:
        text = ll.BOARD_UNRENDERED % e       # the operator sentence names the file and the fix
    except Exception:
        return 0
    finally:
        signal.alarm(0)
    # §14: while the stamp differs from VERSION, the upgrade's line leads the board on every prompt, even when
    # no window is open (board_for returns '' then); so does the line naming the upgrade's safety copy of target/
    # until the operator forgets it. Absent upgrade.py (a fixture) or any failure: no line.
    lead = []
    try:
        import upgrade as up
        pend = up.pending_line(v.ROOT)
        lead.append(pend)
        if pend:            # no window is made until the stamp is written (session-start.py)
            lead.append(up.WINDOWS_WAIT_BOARD)
        lead.append(up.snapshot_line(v.ROOT))
    except Exception:
        pass
    lead = [x for x in lead if x]
    if lead:
        text = "\n".join(lead) + ("\n" + text if text else "")
    if text:
        v.emit({"hookSpecificOutput": {"hookEventName": payload.get("hook_event_name", "UserPromptSubmit"),
                                       "additionalContext": text}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
