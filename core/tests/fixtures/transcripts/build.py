#!/usr/bin/env python3
"""Test transcripts in the live shape (spec A12): every entry written is a copy
of an entry of live.jsonl (the redacted transcript of the live build, see
PROVENANCE.md) with its text, uuid and timestamp replaced, so the checks under
test read exactly the shape the live build writes.

    build.py <out.jsonl> <kind> [text] [epoch]      # appends one entry

kinds: operator (typed by the operator), queued (typed while the session was
busy), assistant (assistant text), tool-use, tool-result, meta (isMeta), peer
(a message from another session), task-notification, command (a slash-command
record: no origin, <command-name> text), no-origin (a user text entry with no
origin and no tag: unknown provenance), malformed (a user entry whose content
is neither text nor a list). epoch defaults to now + 1 s. Each entry's parentUuid is
the file's last uuid, and an operator entry is followed by the harness's reply (an
assistant tool_use entry chained to it) — the shape transcriptlib.harness_wrote reads."""
import copy
import json
import sys
import time
import uuid
from pathlib import Path

LIVE = Path(__file__).resolve().parent / "live.jsonl"
ROWS = [json.loads(ln) for ln in LIVE.read_text().splitlines() if ln.strip()]


def content(r):
    return (r.get("message") or {}).get("content")


def first(pred, what):
    for r in ROWS:
        if pred(r):
            return copy.deepcopy(r)
    sys.exit("live.jsonl has no %s entry to copy — regenerate it (see PROVENANCE.md)" % what)


def typed(r):
    return r.get("type") == "user" and isinstance(content(r), str) and (r.get("origin") or {}).get("kind") == "human"


def blocks(r, kind):
    c = content(r)
    return isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == kind for b in c)


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(epoch)) + ".%03dZ" % int((epoch % 1) * 1000)


def last_uuid(out):
    last = None
    if out.exists():
        for ln in out.read_text().splitlines():
            try:
                d = json.loads(ln)
            except ValueError:
                continue
            if isinstance(d, dict) and isinstance(d.get("uuid"), str):
                last = d["uuid"]
    return last


def main(argv):
    out, kind = Path(argv[1]), argv[2]
    text = argv[3] if len(argv) > 3 else "placeholder text"
    at = float(argv[4]) if len(argv) > 4 and argv[4] else time.time() + 1
    if kind in ("operator", "queued", "peer", "task-notification", "command", "no-origin", "malformed"):
        e = first(typed, "operator-typed")
        e["message"]["content"] = text
        e["promptSource"] = "typed"
        if kind == "queued":
            e["promptSource"] = "queued"
        elif kind == "peer":
            e.update(origin={"kind": "peer", "from": "placeholder"}, isMeta=True, promptSource="system")
        elif kind == "task-notification":
            e.update(origin={"kind": "task-notification"}, promptSource="system")
        elif kind in ("command", "no-origin"):
            for k in ("origin", "promptSource", "turnOrigin"):
                e.pop(k, None)
            if kind == "command":
                e["message"]["content"] = "<command-name>/%s</command-name>" % text
        elif kind == "malformed":
            e["message"]["content"] = 42
    elif kind == "assistant":
        e = first(lambda r: r.get("type") == "assistant" and blocks(r, "text"), "assistant text")
        e["message"]["content"] = [{"type": "text", "text": text}]
    elif kind == "tool-use":
        e = first(lambda r: r.get("type") == "assistant" and blocks(r, "tool_use"), "assistant tool_use")
    elif kind == "tool-result":
        e = first(lambda r: r.get("type") == "user" and blocks(r, "tool_result"), "tool_result")
        for b in e["message"]["content"]:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                b["content"] = text
    elif kind == "meta":
        e = first(lambda r: r.get("type") == "user" and r.get("isMeta"), "isMeta user")
        e["message"]["content"] = [{"type": "text", "text": text}]
    else:
        sys.exit("unknown kind %s" % kind)
    e["uuid"] = str(uuid.uuid4())
    e["timestamp"] = iso(at)
    # linked as Claude Code links them (transcriptlib._chain, harness_wrote): each entry's parent is the last one
    e["parentUuid"] = last_uuid(out)
    rows = [e]
    if kind == "operator":
        # the harness's reply to a typed turn — before any tool can run, the assistant entry that answers it is
        # written, chained to it (critic finding 2: a turn nothing follows was appended, not typed)
        r = first(lambda x: x.get("type") == "assistant" and blocks(x, "tool_use"), "assistant tool_use")
        r.update(uuid=str(uuid.uuid4()), parentUuid=e["uuid"], timestamp=iso(at + 0.001))
        rows.append(r)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("a") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    print(e["uuid"])


if __name__ == "__main__":
    main(sys.argv)
