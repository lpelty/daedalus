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
own unexpected failure. Under the 5 s hook timeout (v0.7.5, PROP-025): the
swept-window checks, the lock waits and the reader's changed set get a 2.5 s
deadline (the changed set at most half of what is left of it), the render's
git 3.5 s; what the checks did not reach is drawn "not checked this time",
never a board that vanishes. A 4 s alarm is a backstop for a hang anywhere
else, and says so in one line naming `core/lease.sh list`.
"""
from __future__ import annotations

import json
import os
import signal
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402
import leaselib as ll  # noqa: E402

CHECK_SECS = 2.5        # the swept-window checks, both lock waits and the reader's changed set
RENDER_SECS = 3.5       # the render's `git log -1` per repo of each non-stale window
BACKSTOP_SECS = 4       # whole seconds (signal.alarm); 1 s under Claude Code's 5 s kill
BOARD_OVERRUN = "The lease board was not drawn in time at this prompt; run `core/lease.sh list` to see it now"


class BoardOverrun(BaseException):
    """The backstop. Deliberately not an OSError or an Exception: v.run caught the old alarm's TimeoutError as a git
    failure, and the board named whichever window's git call was in flight (PROP-025)."""


def _on_alarm(signum, frame):
    raise BoardOverrun()


def main() -> int:
    start = time.time()
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    if payload.get("hook_event_name", "UserPromptSubmit") == "UserPromptSubmit" \
            and isinstance(payload.get("transcript_path"), str) and isinstance(payload.get("prompt"), str):
        row = None
        try:
            import transcriptlib as tl
            row = tl.record_prompt(payload["transcript_path"], payload["prompt"], str(payload.get("session_id") or ""))
        except Exception as e:     # a prompt not recorded is a yes confirm refuses, never one it accepts
            print("daedalus: the prompt was not recorded: %r" % e, file=sys.stderr)
        # frame-jack spec §5.5: with the AMI's sentinel present, the operator's words and the transcript offset
        # record_prompt computed go to the AMI's session file — the Bash hook never scans the transcript for them.
        # One stat when off; a failure here is its own, never the board's.
        if row is not None:
            try:
                import amilib
                amilib.record_operator_message(v.ROOT, str(payload.get("session_id") or ""), payload["prompt"],
                                               payload["transcript_path"], row.get("size"))
            except Exception as e:
                print("daedalus: the operator's message was not recorded for the AMI: %r" % e, file=sys.stderr)
    sid = v.export_session(payload)
    visitor = bool(os.environ.get("DIRECT_CALL_ID"))
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(BACKSTOP_SECS)
    mine, drawn = None, False
    try:
        try:
            text, mine = ll.board_for(v.ROOT, sid, visitor, with_mine=True, deadline=start + CHECK_SECS,
                                      check_deadline=start + CHECK_SECS, render_deadline=start + RENDER_SECS,
                                      busy=ll.BOARD_LOCK_BUSY_PROMPT, recompute_share=ll.RECOMPUTE_SHARE)
            drawn = True
        finally:
            signal.alarm(0)
    except BoardOverrun:
        text = BOARD_OVERRUN                 # a board that vanishes reads as "no leases" (v0.7.5 review, R9)
    except ll.Refused as e:
        # the busy lock is its own sentence; any other names the file and the fix
        text = str(e) if str(e) == ll.BOARD_LOCK_BUSY_PROMPT else ll.BOARD_UNRENDERED % e
    except Exception:
        return 0
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
            # how a session holding no window closes; the board itself ends with it whenever a window is open
            if sid and not visitor and mine is None and not drawn:
                try:            # no board, so no `mine`: the lease files say whether this session holds a window
                    mine, _ = ll.lease_of_session(ll.read_all(v.ROOT, prune_empty=False), sid)   # a read only, no lock
                except Exception:
                    pass
            if sid and not visitor and mine is None and ll.WINDOWLESS_CLOSE not in text:
                lead.append(ll.WINDOWLESS_CLOSE)
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
