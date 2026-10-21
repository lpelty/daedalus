#!/usr/bin/env python3
"""The one way vault/hot.md changes (v0.12.6, spec 2026-10-20 "hot.md: a reader at start, a shape per entry, and a
14-day question"). Python 3.9, stdlib only.

  python3 core/hot.py add "<topic>" --next "…" --done-when "…" [--where "…"] [--owner NN|operator|<agent>] [--blocked]
  python3 core/hot.py update "<topic>" [--next …] [--where …] [--done-when …] [--owner …] [--blocked|--in-flight]
  python3 core/hot.py remove "<topic>"            python3 core/hot.py keep "<topic>" [--owner NN]
  python3 core/hot.py carry [NN]                  (the close: this window's remaining entries become carried)
  python3 core/hot.py drop <id>                   (the pen's holder: text not in entry form, once it is reshaped)
  python3 core/hot.py show | due | --doctor       (read-only)
  update, remove and keep take --operator-said "<a few of their words>" for an entry the operator named.

An entry is one `### <topic>` block under `## In flight` or `## Blocked`, holding only the fields in FIELDS. Each
write edits one block under an exclusive lock on state/hot.lock and lands by temp file + rename; every other byte of
the body stays as it was, and the frontmatter's leases:, updated-by: and updated: are refreshed (leases: from the
live board). There is no size limit, warning or refusal on length anywhere (ruling A).

Who may change an entry (ruling C): any window adds. update / remove / keep: its own entry, a carried one, one whose
owner is not a window (the operator, another agent: its done-when is anyone's to see), one whose window is not open, the
entry this session was asked about at start (D), or one the operator named (--operator-said, checked against the
turns they typed in this session). Another open window's entry is that window's: refused, naming it. An operator
shell (no session) may change anything; a visitor (a direct-call session) changes nothing.

Lock order: the lease lock is never held while this waits for state/hot.lock from a command — the leases are read
first, under the shared lease lock, and let go. leaselib's sweeps call carry_windows while they hold the lease lock,
so the order is always lease lock, then hot lock, never the reverse.
"""
from __future__ import annotations

import contextlib
import datetime
import fcntl
import hashlib
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

FIELDS = ("owner", "since", "kept", "where", "next", "done when")
REQUIRED = ("owner", "next", "done when")
SECTIONS = ("In flight", "Blocked")
DUE_DAYS = 14
HOT = Path("vault") / "hot.md"
LOCK = Path("state") / "hot.lock"
DUE = Path("state") / "hot-due.json"           # {topic: {"asked": date, "session": sid}}: one ask a day (D)
LISTED = Path("state") / "hot-unshaped.json"  # ids of text not in entry form already listed to the pen's holder
LOCK_WAIT = 10.0                               # a command's wait for state/hot.lock; a hook passes its own deadline

_HEADER = re.compile(r"^(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
_FIELD = re.compile(r"^- ([a-z][a-z ]*?):[ \t]*(.*?)[ \t]*$", re.IGNORECASE)
_DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
_WINDOW = re.compile(r"^window ([0-9]{2})$", re.IGNORECASE)
_CARRIED = re.compile(r"^carried from window ([0-9]{2}), ([0-9]{4}-[0-9]{2}-[0-9]{2})$", re.IGNORECASE)

USE_HOT_PY = ("hot.md changes only through core/hot.py, so every window's entries land without overwriting another's: "
              "`python3 core/hot.py add \"<topic>\" --next \"…\" --done-when \"…\"`, or `update`, `remove`, `keep` "
              "with the entry's topic (`python3 core/hot.py --help` lists them).")
VISITOR = "This is a direct-call session (a visitor); it changes nothing in hot.md."
BUSY = "hot.md is being written by another window (state/hot.lock stayed busy); run this again in a moment."


class Refused(Exception):
    pass


def today() -> str:
    return datetime.date.today().isoformat()


def norm(topic: str) -> str:
    return " ".join(str(topic).split()).casefold()


def one_line(text: object) -> str:
    return " ".join(str(text).split())


# --- The file ---------------------------------------------------------------------------------------------------

class Entry:
    """One `### ` block in a managed section: lines [start, end) of the document."""

    def __init__(self, section: str, topic: str, start: int, end: int, fields: Dict[str, str], shaped: bool):
        self.section, self.topic, self.start, self.end, self.fields, self.shaped = \
            section, topic, start, end, fields, shaped

    def age_from(self) -> Optional[str]:
        return self.fields.get("kept") or self.fields.get("since")


class Loose:
    """Text in a managed section outside every `### ` block (a paragraph), or a `### ` block not in entry form."""

    def __init__(self, section: str, start: int, end: int, text: str):
        self.section, self.start, self.end, self.text = section, start, end, text
        self.id = hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]

    def first_line(self) -> str:
        return next((ln.strip() for ln in self.text.splitlines() if ln.strip()), "")


class Doc:
    def __init__(self, text: str):
        self.lines = text.splitlines(True)
        self.fm_end = 0
        if self.lines and self.lines[0].rstrip("\r\n") == "---":
            for j in range(1, len(self.lines)):
                if self.lines[j].rstrip("\r\n") == "---":
                    self.fm_end = j + 1
                    break
        self.parse()

    def text(self) -> str:
        return "".join(self.lines)

    def parse(self) -> None:
        self.sections: Dict[str, Tuple[int, int]] = {}
        self.entries: List[Entry] = []
        self.loose: List[Loose] = []
        heads = []                      # (index, level, title) of every heading outside a code fence
        fence = False
        for i in range(self.fm_end, len(self.lines)):
            ln = self.lines[i].rstrip("\r\n")
            if ln.lstrip().startswith("```") or ln.lstrip().startswith("~~~"):
                fence = not fence
                continue
            m = None if fence else _HEADER.match(ln)
            if m:
                heads.append((i, len(m.group(1)), m.group(2)))
        for k, (i, level, title) in enumerate(heads):
            if level != 2:
                continue
            name = next((s for s in SECTIONS if norm(s) == norm(title)), None)
            if name is None or name in self.sections:
                continue
            end = next((j for (j, lv, _t) in heads[k + 1:] if lv <= 2), len(self.lines))
            self.sections[name] = (i, end)
            subs = [j for (j, lv, _t) in heads[k + 1:] if j < end and lv == 3]
            self._preamble(name, i + 1, subs[0] if subs else end)
            for n, j in enumerate(subs):
                self._block(name, j, subs[n + 1] if n + 1 < len(subs) else end)

    def _preamble(self, section: str, start: int, end: int) -> None:
        """HTML comments and blank lines are the section's own; any other paragraph is text not in entry form."""
        comment, para = False, None
        for i in range(start, end):
            s = self.lines[i].strip()
            if comment or s.startswith("<!--"):
                comment = "-->" not in s
                if para is not None:
                    self._loose(section, para, i)
                    para = None
                continue
            if not s:
                if para is not None:
                    self._loose(section, para, i)
                    para = None
                continue
            if para is None:
                para = i
        if para is not None:
            self._loose(section, para, end)

    def _loose(self, section: str, start: int, end: int) -> None:
        while end > start and not self.lines[end - 1].strip():
            end -= 1
        self.loose.append(Loose(section, start, end, "".join(self.lines[start:end])))

    def _block(self, section: str, start: int, end: int) -> None:
        topic = _HEADER.match(self.lines[start].rstrip("\r\n")).group(2)
        fields: Dict[str, str] = {}
        shaped = True
        for i in range(start + 1, end):
            s = self.lines[i].rstrip("\r\n")
            if not s.strip():
                continue
            m = _FIELD.match(s)
            key = m.group(1).lower() if m else None
            if key not in FIELDS or key in fields:
                shaped = False
                continue
            fields[key] = m.group(2)
        if any(not fields.get(k) for k in REQUIRED):
            shaped = False
        for k in ("since", "kept"):
            if k in fields and not _valid_date(fields[k]):
                shaped = False
        e = Entry(section, topic, start, end, fields, shaped)
        self.entries.append(e)
        if not shaped:
            last = end
            while last > start and not self.lines[last - 1].strip():
                last -= 1
            self.loose.append(Loose(section, start, last, "".join(self.lines[start:last])))

    def find(self, topic: str) -> Entry:
        hits = [e for e in self.entries if norm(e.topic) == norm(topic)]
        if not hits:
            raise Refused("hot.md has no entry '%s' under In flight or Blocked (`python3 core/hot.py show` lists them)."
                          % one_line(topic))
        if len(hits) > 1:
            raise Refused("hot.md has %d entries named '%s'; the pen's holder makes their topics differ." % (len(hits), one_line(topic)))
        return hits[0]

    def replace(self, start: int, end: int, new: List[str]) -> None:
        self.lines[start:end] = new
        self.parse()

    def insert_entry(self, section: str, block: List[str]) -> None:
        """At the end of the section: after its last line that is not blank, a blank line between."""
        if section not in self.sections:
            if self.lines and not self.lines[-1].endswith("\n"):
                self.lines[-1] += "\n"
            if self.lines and self.lines[-1].strip():
                self.lines.append("\n")
            self.lines.append("## %s\n" % section)
            self.lines.append("\n")
            self.parse()
        head, end = self.sections[section]
        at = end
        while at > head + 1 and not self.lines[at - 1].strip():
            at -= 1
        new = [ln for ln in block if ln.strip()]           # the blank lines around it are placed here
        if not self.lines[at - 1].endswith("\n"):
            self.lines[at - 1] += "\n"
        if self.lines[at - 1].strip():
            new.insert(0, "\n")
        if at >= len(self.lines) or self.lines[at].strip():
            new.append("\n")
        self.replace(at, at, new)

    def set_frontmatter(self, values: Dict[str, str]) -> None:
        """Replace each key's line (and any indented continuation under it) in the frontmatter; add a key it lacks
        before the closing ---. A file with no frontmatter is left without one."""
        if not self.fm_end:
            return
        for key, val in values.items():
            line = "%s: %s\n" % (key, val)
            idx = next((i for i in range(1, self.fm_end - 1) if re.match(r"^%s:(\s|$)" % re.escape(key), self.lines[i])), None)
            if idx is None:
                self.lines.insert(self.fm_end - 1, line)
                self.fm_end += 1
                continue
            stop = idx + 1
            while stop < self.fm_end - 1 and self.lines[stop][:1] in (" ", "\t"):
                stop += 1
            self.lines[idx:stop] = [line]
            self.fm_end -= stop - idx - 1
        self.parse()


def _valid_date(s: str) -> bool:
    if not _DATE.match(s or ""):
        return False
    try:
        datetime.date.fromisoformat(s)
        return True
    except ValueError:
        return False


def render(topic: str, fields: Dict[str, str], tail: Optional[List[str]] = None) -> List[str]:
    out = ["### %s\n" % one_line(topic)]
    for k in FIELDS:
        if fields.get(k):
            out.append("- %s: %s\n" % (k, one_line(fields[k])))
    return out + (tail if tail is not None else ["\n"])


def _tail(doc: Doc, e: Entry) -> List[str]:
    """The block's own trailing blank lines, kept as they were when the block is rewritten."""
    j = e.end
    while j > e.start + 1 and not doc.lines[j - 1].strip():
        j -= 1
    return doc.lines[j:e.end]


def days(since: Optional[str], now: Optional[datetime.date] = None) -> Optional[int]:
    if not since or not _valid_date(since):
        return None
    return ((now or datetime.date.today()) - datetime.date.fromisoformat(since)).days


# --- Locks and state --------------------------------------------------------------------------------------------

@contextlib.contextmanager
def hot_lock(root: Path, deadline: Optional[float] = None) -> Iterator[None]:
    """Exclusive flock on state/hot.lock, polled every 50 ms until `deadline` (epoch seconds), then Refused(BUSY)
    with nothing done. NOT re-entrant, like leaselib.lock."""
    p = root / LOCK
    p.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(p), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if deadline is not None and time.time() >= deadline:
                    raise Refused(BUSY)
                time.sleep(0.05)
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def _atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".%s-" % path.name, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        try:
            os.chmod(tmp, path.stat().st_mode & 0o777)
        except OSError:
            os.chmod(tmp, 0o644)
        os.replace(tmp, str(path))
        tmp = ""
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _read_json(path: Path) -> dict:
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return d if isinstance(d, dict) else {}


def _read_doc(root: Path) -> Optional[Doc]:
    try:
        return Doc((root / HOT).read_text())
    except FileNotFoundError:
        return None


def _new_doc(root: Path) -> Doc:
    try:
        return Doc((root / "core" / "templates" / "hot.md").read_text())
    except OSError:
        return Doc("---\ntype: rolling-state\nleases:\n---\n\n# Hot — where the work stands\n\n## In flight\n\n## Blocked\n")


# --- The leases -------------------------------------------------------------------------------------------------

def _ll():
    import leaselib as ll
    return ll


def leases_snapshot(root: Path, deadline: Optional[float] = None) -> Dict[str, dict]:
    """The leases, read under the shared lease lock and let go before the hot lock is taken (the lock order)."""
    ll = _ll()
    if not ll.leases_dir(root).is_dir():
        return {}
    with ll.lock(root, shared=True, deadline=deadline):
        return ll.read_all(root, prune_empty=False)


def open_windows(root: Path, leases: Dict[str, dict]) -> Dict[str, str]:
    """{NN: liveness} for every window, liveness computed once per call."""
    ll = _ll()
    now, quiet = time.time(), None
    out = {}
    for nn in sorted(k for k in leases if k != "prime"):
        if quiet is None:
            quiet = ll.stale_after_secs(root)
        try:
            out[nn] = ll.liveness(root, nn, leases[nn], now=now, quiet_after=quiet)
        except Exception:
            out[nn] = "stale"
    return out


def board_line(root: Path, leases: Dict[str, dict], states: Optional[Dict[str, str]] = None) -> str:
    """The frontmatter's leases: — which windows are open and why, as the board has them now (intent, not status)."""
    states = open_windows(root, leases) if states is None else states
    prime = (leases.get("prime") or {}).get("session_id")
    parts = []
    for nn in sorted(k for k in leases if k != "prime"):
        d = leases[nn]
        label = "%s (%s)" % (nn, d["alias"]) if d.get("alias") else nn
        bits = []
        if prime and d.get("session_id") == prime:
            bits.append("prime")
        bits.append("released" if d.get("released") else ("finished" if d.get("finished") else states.get(nn, "stale")))
        what = one_line(d.get("task") or d.get("summary") or d.get("note") or "")
        parts.append("%s — %s%s" % (label, ", ".join(bits), (": " + what) if what else ""))
    if prime and not any(leases[k].get("session_id") == prime for k in leases if k != "prime"):
        parts.append("the pen is held by a session with no window")
    text = "; ".join(parts) or "no windows open"
    return json.dumps(text, ensure_ascii=False)


# --- Who is calling, and who may change what --------------------------------------------------------------------

class Caller:
    def __init__(self, root: Path, leases: Dict[str, dict]):
        ll = _ll()
        self.visitor = bool(os.environ.get("DIRECT_CALL_ID"))
        self.sid = ll.session_id_from_env()
        self.nn = None
        if self.sid:
            self.nn, _ = ll.lease_of_session(leases, self.sid)
        self.prime = bool(self.sid) and (leases.get("prime") or {}).get("session_id") == self.sid

    def who(self) -> str:
        if self.nn:
            return "window %s" % self.nn
        if self.sid:
            return "a session with no window"
        return "the operator"


def owner_value(raw: str) -> str:
    raw = one_line(raw)
    if re.fullmatch(r"[0-9]{1,2}", raw):
        return "window %02d" % int(raw)
    m = _WINDOW.match(raw)
    return ("window %s" % m.group(1)) if m else raw


def _operator_named(root: Path, sid: str, said: str) -> Optional[str]:
    """None when `said` is in a turn the operator typed in this session (transcriptlib.find_consent, v0.12.5: a
    citation, never a password); else the sentence why not."""
    import transcriptlib as tl
    marker = v.read_marker(root, sid) or {}
    try:
        after = float(marker.get("started_epoch") or 0)
    except (TypeError, ValueError):
        after = 0.0
    try:
        tl.find_consent(tl.transcript_for(root, sid), after, quote=said)
        return None
    except tl.NotCited:
        return "The words cited are in nothing the operator typed in this session; cite a few of their words exactly."
    except tl.NotFound:
        return "The operator has typed nothing in this session that holds those words."
    except (tl.Missing, tl.Unprotected, tl.Unreadable) as e:
        return "This session's transcript cannot be read as the operator's words (%s)." % e


def may_change(root: Path, caller: Caller, e: Entry, leases: Dict[str, dict], states: Dict[str, str],
               said: Optional[str]) -> None:
    """Refused when the entry is another open window's (ruling C)."""
    if caller.sid is None:
        return                                          # an operator shell
    owner = e.fields.get("owner", "")
    m = _WINDOW.match(owner.strip())
    if not m or m.group(1) == caller.nn:
        return                                          # not a window's (carried, the operator, an agent), or this window's
    nn = m.group(1)
    lease = leases.get(nn)
    held = lease is not None and not lease.get("released") and states.get(nn) in _ll().HELD_BY_LIVE \
        and lease.get("session_id") != caller.sid
    if not held:
        return                                          # its window is not open: nobody else will change it
    asked = _read_json(root / DUE).get(norm(e.topic)) or {}
    if asked.get("session") == caller.sid:
        return                                          # this session asked the operator about it at start (D)
    if said:
        why = _operator_named(root, caller.sid, said)
        if why is None:
            return
        raise Refused(why + " Nothing in hot.md was changed.")
    raise Refused("The hot.md entry '%s' belongs to %s, which is open: it is that window's to change. Send it a "
                  "message; or, if the operator named this entry in this session, run this again with "
                  "--operator-said \"<a few of their words>\". Nothing in hot.md was changed."
                  % (one_line(e.topic), _ll().window_label(nn, lease)))


# --- Writes -----------------------------------------------------------------------------------------------------

def _write(root: Path, doc: Doc, leases: Dict[str, dict], states: Dict[str, str], who: str) -> None:
    doc.set_frontmatter({"leases": board_line(root, leases, states), "updated-by": who, "updated": today()})
    _atomic(root / HOT, doc.text())


def _forget_ask(root: Path, topic: str) -> None:
    p = root / DUE
    d = _read_json(p)
    if d.pop(norm(topic), None) is not None:
        _atomic(p, json.dumps(d, indent=2, sort_keys=True))


def change(root: Path, op: str, topic: str, opts: dict, deadline: Optional[float] = None) -> str:
    """add / update / remove / keep / drop: one block, under the hot lock. Returns the line to print."""
    if os.environ.get("DIRECT_CALL_ID"):
        raise Refused(VISITOR)
    deadline = time.time() + LOCK_WAIT if deadline is None else deadline
    try:
        leases = leases_snapshot(root, deadline=deadline)
    except _ll().Refused as e:
        raise Refused(str(e))
    states = open_windows(root, leases)
    caller = Caller(root, leases)
    with hot_lock(root, deadline=deadline):
        doc = _read_doc(root)
        if doc is None:
            if op != "add":
                raise Refused("vault/hot.md does not exist yet; `python3 core/hot.py add` makes it.")
            doc = _new_doc(root)
        if op == "add":
            if any(norm(e.topic) == norm(topic) for e in doc.entries):
                raise Refused("hot.md already has an entry '%s'; change it with `python3 core/hot.py update`."
                              % one_line(topic))
            if not one_line(topic):
                raise Refused("An entry needs a topic, one line.")
            owner = owner_value(opts["owner"]) if opts.get("owner") else ("window %s" % caller.nn if caller.nn else "")
            if not owner:
                raise Refused("No window is calling, so name the entry's owner with --owner (a window number, operator, or "
                              "another agent's name).")
            for k, flag in (("next", "--next"), ("done when", "--done-when")):
                if not one_line(opts.get(k) or ""):
                    raise Refused("An entry needs %s: %s." % (flag, {"next": "the one next action",
                                                                     "done when": "the observable condition that removes it"}[k]))
            fields = {"owner": owner, "since": today(), "where": opts.get("where") or "", "next": opts["next"],
                      "done when": opts["done when"]}
            section = "Blocked" if opts.get("blocked") else "In flight"
            doc.insert_entry(section, render(topic, fields))
            _write(root, doc, leases, states, caller.who())
            return "Added '%s' under %s, owner %s." % (one_line(topic), section, owner)
        if op == "drop":
            if caller.sid is not None and not caller.prime:
                raise Refused("Only the pen's holder drops text not in entry form; it reshapes it into entries first.")
            hit = [x for x in doc.loose if x.id == topic]
            if not hit:
                raise Refused("hot.md has no text not in entry form with the id %s (`python3 core/hot.py --doctor` "
                              "lists the ids)." % topic)
            x = hit[0]
            end = x.end
            while end < len(doc.lines) and not doc.lines[end].strip() and end < _section_end(doc, x.section):
                end += 1
            doc.replace(x.start, end, [])
            _write(root, doc, leases, states, caller.who())
            return "Dropped the text %s from %s (it began: %s)." % (x.id, x.section, x.first_line()[:80])
        e = doc.find(topic)
        may_change(root, caller, e, leases, states, opts.get("said"))
        if op == "remove":
            end = e.end
            doc.replace(e.start, end, [])
            _forget_ask(root, e.topic)
            _write(root, doc, leases, states, caller.who())
            return "Removed '%s' from %s." % (one_line(e.topic), e.section)
        if not e.shaped:
            raise Refused("The entry '%s' is not in entry form. Move its history to your session log, remove it "
                          "(`python3 core/hot.py remove`), and add it again in entry form." % one_line(e.topic))
        fields = dict(e.fields)
        if op == "keep":
            fields["kept"] = today()
        for k in ("next", "where", "done when"):
            if opts.get(k) is not None:
                if not one_line(opts[k]) and k != "where":
                    raise Refused("--%s cannot be empty." % k.replace(" ", "-"))
                fields[k] = opts[k]
        if opts.get("owner"):
            fields["owner"] = owner_value(opts["owner"])
        section = e.section
        if opts.get("blocked"):
            section = "Blocked"
        elif opts.get("in flight"):
            section = "In flight"
        if section == e.section:
            doc.replace(e.start, e.end, render(e.topic, fields, _tail(doc, e)))
        else:
            doc.replace(e.start, e.end, [])
            doc.insert_entry(section, render(e.topic, fields))
        if op == "keep":
            _forget_ask(root, e.topic)
        _write(root, doc, leases, states, caller.who())
        if op == "keep":
            return "Kept '%s': kept: %s restarts its 14 days, owner %s." % (one_line(e.topic), today(), fields["owner"])
        return "Updated '%s'%s." % (one_line(e.topic), (" (now under %s)" % section) if section != e.section else "")


def _section_end(doc: Doc, section: str) -> int:
    return doc.sections.get(section, (0, len(doc.lines)))[1]


def carry_windows(root: Path, nns: List[str], leases: Dict[str, dict], who: str = "the sweep",
                  deadline: Optional[float] = None) -> int:
    """Every entry owned by `window NN` for NN in nns becomes `carried from window NN, <today>` (ruling C: window
    numbers are reused, so the topic, not the number, names the work). The caller may hold the lease lock and
    passes the leases it read (the lock order: lease lock, then hot lock). Returns how many entries changed."""
    nns = set(nns)
    with hot_lock(root, deadline=deadline):
        doc = _read_doc(root)
        if doc is None:
            return 0
        n = 0
        for e in sorted(doc.entries, key=lambda x: -x.start):
            m = _WINDOW.match(e.fields.get("owner", "").strip())
            if not m or m.group(1) not in nns or not e.shaped:
                continue
            fields = dict(e.fields, owner="carried from window %s, %s" % (m.group(1), today()))
            doc.replace(e.start, e.end, render(e.topic, fields, _tail(doc, e)))
            n += 1
        if n:
            _write(root, doc, leases, open_windows(root, leases), who)
        return n


def carry_mine(root: Path, token: Optional[str]) -> str:
    """`hot.py carry` — the close: this window's remaining entries are marked carried. From a shell, `carry NN`."""
    if os.environ.get("DIRECT_CALL_ID"):
        raise Refused(VISITOR)
    leases = leases_snapshot(root, deadline=time.time() + LOCK_WAIT)
    caller = Caller(root, leases)
    nn = caller.nn
    if token:
        if not re.fullmatch(r"[0-9]{2}", token):
            raise Refused("%s is not a window number (two digits, 01–99)." % token)
        if caller.sid is not None and token != caller.nn:
            raise Refused("A session marks only its own window's entries carried; window %s's are its own, or the "
                          "sweep's when it is swept." % token)
        nn = token
    if not nn:
        return "This session holds no window, so no hot.md entry is its own to carry."
    n = carry_windows(root, [nn], leases, who=caller.who(), deadline=time.time() + LOCK_WAIT)
    if n == 0:
        return "Window %s owns no hot.md entry; nothing to carry." % nn
    return ("%s of window %s %s marked carried; the window that picks one up takes it with "
            "`python3 core/hot.py update \"<topic>\" --owner <NN>`." % (_entries(n), nn, "is" if n == 1 else "are"))


# --- Reading: the start, the doctor -----------------------------------------------------------------------------

def _plural(n: int, word: str) -> str:
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def _entries(n: int) -> str:
    return "%d hot.md entr%s" % (n, "y" if n == 1 else "ies")


def entry_line(e: Entry) -> str:
    if not e.shaped:
        return "- %s — not in entry form (its text is in vault/hot.md)" % one_line(e.topic)
    age = days(e.fields.get("since"))
    return "- %s — owner: %s — %s — next: %s — done when: %s" % (
        one_line(e.topic), e.fields.get("owner", ""), _plural(age, "day") if age is not None else "no date",
        e.fields.get("next", ""), e.fields.get("done when", ""))


def listing(doc: Doc) -> str:
    out = ["hot.md — what is underway and what it waits on (the full file is vault/hot.md):"]
    for s in SECTIONS:
        out.append("%s:" % s)
        rows = [entry_line(e) for e in doc.entries if e.section == s]
        loose = [x for x in doc.loose if x.section == s and not x.text.startswith("#")]
        if loose:
            rows.append("- and %s of text not in entry form" % _plural(len(loose), "paragraph"))
        out.extend(rows or ["- nothing"])
    out.append("Change hot.md only with `python3 core/hot.py` (add, update, remove, keep). When an entry's done when "
               "is met, remove it in that same turn.")
    return "\n".join(out)


def due_entries(doc: Doc) -> List[Tuple[Entry, int]]:
    out = []
    for e in doc.entries:
        if not e.shaped:
            continue
        n = days(e.age_from())
        if n is not None and n >= DUE_DAYS:
            out.append((e, n))
    return out


def alert_line(e: Entry, n: int) -> str:
    return ("hot.md entry '%s' has sat for %s (owner: %s). Move it to the backlog, or keep working on it in a window?"
            % (one_line(e.topic), _plural(n, "day"), e.fields.get("owner", "")))


ASK = ("Ask the operator this in your first reply. Their answer, in any words, is the decision, and this window "
       "applies it: backlog → add a backlog row (or a backlog candidate in your session log if the backlog cannot be "
       "reached), then `python3 core/hot.py remove \"%s\"`; keep → `python3 core/hot.py keep \"%s\"`, with "
       "`--owner <NN>` if they put it in this window.")


def at_start(root: Path, sid: str, holds_pen: bool, deadline: Optional[float] = None) -> Tuple[List[str], List[str]]:
    """The session start (B, C, D): stamps since: on an entry that has none (the first start after the update, so
    it sets off no alerts), asks about each entry due today that no session has asked about today, lists text not in
    entry form once to the pen's holder, and shows In flight and Blocked. Returns (lines for the top of the context,
    lines for the end). A busy lock or an unreadable file is a line, never a broken start."""
    try:
        leases = leases_snapshot(root, deadline=deadline)
    except Exception:
        leases = {}
    top: List[str] = []
    tail: List[str] = []
    with hot_lock(root, deadline=deadline):
        doc = _read_doc(root)
        if doc is None:
            return [], []
        stamped = 0
        for e in sorted(doc.entries, key=lambda x: -x.start):
            if e.shaped and not e.fields.get("since"):
                doc.replace(e.start, e.end, render(e.topic, dict(e.fields, since=today()), _tail(doc, e)))
                stamped += 1
        if stamped:
            caller = Caller(root, leases)
            _write(root, doc, leases, open_windows(root, leases), caller.who())
        asked = _read_json(root / DUE)
        present = {norm(e.topic) for e in doc.entries}
        changed = False
        for k in [k for k in asked if k not in present]:
            del asked[k]
            changed = True
        for e, n in due_entries(doc):
            key = norm(e.topic)
            if (asked.get(key) or {}).get("asked") == today():
                continue
            top.append(alert_line(e, n))
            top.append(ASK % (one_line(e.topic), one_line(e.topic)))
            asked[key] = {"asked": today(), "session": sid, "topic": one_line(e.topic)}
            changed = True
        if changed:
            _atomic(root / DUE, json.dumps(asked, indent=2, sort_keys=True))
        if holds_pen and doc.loose:
            seen = _read_json(root / LISTED)
            fresh = [x for x in doc.loose if x.id not in seen]
            if fresh:
                rows = ["hot.md has text not in entry form. Reshape each into an entry (`python3 core/hot.py add`), "
                        "with its history in your session log, then drop the old text with `python3 core/hot.py drop "
                        "<id>`. Nothing is deleted until you do. Listed once here; core/doctor.sh lists them again:"]
                for x in fresh:
                    rows.append("- %s (%s): %s (%s)" % (x.id, x.section, x.first_line()[:100],
                                                         _plural(x.text.count("\n") or 1, "line")))
                    seen[x.id] = today()
                tail.append("\n".join(rows))
                _atomic(root / LISTED, json.dumps(seen, indent=2, sort_keys=True))
        tail.append(listing(doc))
    return top, tail


def doctor_lines(root: Path) -> List[str]:
    doc = _read_doc(root)
    if doc is None:
        return ["NOTE     hot.md: vault/hot.md does not exist yet (`python3 core/hot.py add` makes it)"]
    out = []
    for e, n in due_entries(doc):
        out.append("NOTE     hot.md: entry '%s' has sat for %s (owner: %s) — the next session start asks the operator "
                   "to move it to the backlog or keep it" % (one_line(e.topic), _plural(n, "day"), e.fields.get("owner", "")))
    for x in doc.loose:
        out.append("NOTE     hot.md: text not in entry form (%s): %s — id %s, for the pen's holder to reshape"
                   % (x.section, x.first_line()[:100], x.id))
    if not out:
        out.append("OK       hot.md: %s, none due, all in entry form" % _entries(len(doc.entries)).replace(" hot.md", ""))
    return out


# --- The command ------------------------------------------------------------------------------------------------

USAGE = __doc__.split("\n\n")[1]


def _opts(args: List[str]) -> Tuple[List[str], dict]:
    names = {"--next": "next", "--where": "where", "--done-when": "done when", "--owner": "owner",
             "--operator-said": "said"}
    flags = {"--blocked": "blocked", "--in-flight": "in flight"}
    pos, opts = [], {}
    i = 0
    while i < len(args):
        a = args[i]
        if a in names:
            if i + 1 >= len(args):
                raise Refused("%s needs a value.\n%s" % (a, USAGE))
            opts[names[a]] = args[i + 1]
            i += 2
            continue
        if a in flags:
            opts[flags[a]] = True
        elif a.startswith("--"):
            raise Refused("unknown option %s.\n%s" % (a, USAGE))
        else:
            pos.append(a)
        i += 1
    if opts.get("blocked") and opts.get("in flight"):
        raise Refused("--blocked and --in-flight name two sections; give one.")
    return pos, opts


def main(argv: List[str]) -> int:
    root = v.ROOT
    args = argv[1:]
    if not args or args[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0 if args else 2
    cmd, rest = args[0], args[1:]
    try:
        if cmd == "--doctor":
            print("\n".join(doctor_lines(root)))
            return 0
        if cmd in ("show", "due"):
            doc = _read_doc(root)
            if doc is None:
                print("vault/hot.md does not exist yet.")
                return 0
            if cmd == "show":
                print(listing(doc))
            else:
                rows = due_entries(doc)
                print("\n".join(alert_line(e, n) for e, n in rows) if rows else "No hot.md entry has sat for %d days." % DUE_DAYS)
            return 0
        if cmd == "carry":
            print(carry_mine(root, rest[0] if rest else None))
            return 0
        if cmd in ("add", "update", "remove", "keep", "drop"):
            pos, opts = _opts(rest)
            if len(pos) != 1:
                raise Refused("%s takes one %s, in quotes.\n%s" % (cmd, "id" if cmd == "drop" else "topic", USAGE))
            allowed = {"add": {"next", "where", "done when", "owner", "blocked"},
                       "update": {"next", "where", "done when", "owner", "blocked", "in flight", "said"},
                       "remove": {"said"}, "keep": {"owner", "said"}, "drop": set()}[cmd]
            extra = sorted(set(opts) - allowed)
            if extra:
                raise Refused("%s does not take %s.\n%s" % (cmd, ", ".join("--" + k.replace(" ", "-") for k in extra), USAGE))
            print(change(root, cmd, pos[0], opts))
            return 0
        raise Refused("unknown command: %s\n%s" % (cmd, USAGE))
    except Refused as e:
        sys.stderr.write("daedalus: %s\n" % e)
        return 1
    except Exception as e:      # a lease lock that stayed busy, an unreadable lease file: one line, never a trace
        sys.stderr.write("daedalus: hot.md was not changed: %s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
