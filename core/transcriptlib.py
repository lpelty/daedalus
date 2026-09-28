#!/usr/bin/env python3
"""The operator's recorded yes, checked against the session's own transcript
(spec §7.2 step 2, §7.4, §4.8 'Handover', §10 A12).

`promote.confirm: transcribed` — the default, by Larry's decision of
2026-09-25 — records the prime's transcription of what the operator said; this
module checks it. The words must be an entry the operator TYPED — the whole
turn, not a fragment of one (plan 4 Decision 30) — after a cut-off (the
promotion's primaries, Decision 35; for --skip-review the earlier REFUTED
prepare; for `prime take --reason` the pen holder's bound_at) and — for
promote — after an assistant entry with text that follows the cut-off and
carries the block's opening words (the turn in which the prime showed it). A
transcript this build cannot read fails CLOSED, never a pass.

One parser (A12): capture.scan_entries reads the lines; this module decides who
typed an entry. The rule, measured on Claude Code 2.1.251–2.1.282 (plan 4
Decisions 2 and 43): type user, not a sidechain, no tool_result block /
toolUseResult / sourceToolUseID, not isMeta, origin.kind == "human" and
promptSource not "queued" (a queued prompt was typed while the prime was still
working — before the block was on screen). A user text entry with no origin
that starts with a harness tag is a harness record; one with no origin and no
tag is of unknown provenance, and words found only there fail closed.

Also: where a session's transcript is (transcript_for — only inside a
directory nothing may write, Decision 36), the directories the guard and the
boundary check deny as write targets (transcript_dirs), promote.confirm
(confirm_mode), and the /dev/tty reader of tty mode with its ancestry check
(Decision 32: a second, stronger speed bump — not proof of a person).
Python 3.9, standard library; capture.py (imported only when a transcript is
read) and verifylib.py from core/.
"""
from __future__ import annotations

import calendar
import functools
import json
import os
import re
import string
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

CONFIRM_MODES = ("transcribed", "tty")
HARNESS_TAG = re.compile(r"^\s*<(system-reminder|command-name|command-message|command-args|local-command-[a-z-]+|"
                         r"task-notification|bash-[a-z-]+|user-prompt-submit-hook)\b")
EDGES = string.punctuation + "\u201c\u201d\u2018\u2019\u00ab\u00bb\u2026\u2014\u2013 "
TTY_PARENTS = ("login", "sshd", "tmux", "screen")
AGENT_NAMES = ("claude",)


class Unreadable(Exception):
    """The transcript holds a shape this build cannot read (A12): fail closed."""


class Missing(Exception):
    """No transcript where the marker or the configuration says it is."""


class Unprotected(Exception):
    """The transcript resolves outside every directory nothing may write (Decision 36)."""


class NotFound(Exception):
    """The words are no operator-typed entry after the cut-off."""


class NotShown(Exception):
    """The words were typed after the cut-off, but no assistant turn showing the block came between."""


class NoTerminal(Exception):
    """/dev/tty cannot be opened: no person at a terminal in this process."""


class NotAPerson(Exception):
    """A terminal answers, but this process descends from an agent, or from no terminal login (Decision 32)."""


def confirm_mode(root: Path) -> str:
    """config promote.confirm: transcribed (default) or tty (spec §8.1)."""
    raw = v._lib(root, "cfg promote.confirm 2>/dev/null || true").strip()
    mode = raw or "transcribed"
    if mode not in CONFIRM_MODES:
        raise ValueError("promote.confirm must be transcribed or tty (got: %s)" % raw)
    return mode


def slug(path: Path) -> str:
    """Claude Code's project-directory name for a directory: its physical path
    with every character other than a letter or digit as - (lib.sh memory_env)."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(Path(path).resolve()))


def config_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"))


def under(p: Path, d: Path) -> bool:
    try:
        p.relative_to(d)
        return True
    except ValueError:
        return False


@functools.lru_cache(maxsize=8)
def _configured(root_s: str) -> str:
    return v._lib(Path(root_s), "cfg memory.transcript_dir 2>/dev/null || true").strip()


def transcript_dirs(root: Path) -> List[Path]:
    """Where this home's session transcripts live, resolved: memory.transcript_dir
    when set; always Claude Code's project directory for the home
    ($CLAUDE_CONFIG_DIR/projects/<slug>) — spec §7.4; and the directory of each
    SessionStart marker's transcript_path when it lies under
    $CLAUDE_CONFIG_DIR/projects/ or memory.transcript_dir (a session started from
    another directory writes under another slug) — Decision 36, so the directory
    a check reads is always one the guard denies. Not cached: a marker can appear
    mid-process; one glob of state/session-*.json per call."""
    out: List[Path] = []
    conf = _configured(str(root))
    if conf:
        out.append(Path(conf).expanduser().resolve())
    projects = (config_dir() / "projects").resolve()
    out.append(projects / slug(root))
    allowed = [projects] + out[:1 if conf else 0]
    for f in sorted((Path(root) / "state").glob("session-*.json")):
        try:
            tp = json.loads(f.read_text()).get("transcript_path")
        except (OSError, ValueError, AttributeError):
            continue
        if not isinstance(tp, str) or not tp:
            continue
        d = Path(tp).expanduser().resolve().parent
        if d.name != "memory" and d not in out and any(under(d, a) for a in allowed):
            out.append(d)
    return out


def transcript_for(root: Path, session_id: str) -> Path:
    """A session's transcript, resolved: its SessionStart marker's transcript_path
    when that file exists (§7.2 step 2), else <the first transcript dir>/<id>.jsonl.
    Raises Unprotected when it is not inside a directory transcript_dirs names
    (outside <dir>/memory/) — a transcript the guard does not protect is not
    evidence (Decision 36)."""
    marker = v.read_marker(root, session_id) or {}
    recorded = str(marker.get("transcript_path") or "")
    dirs = transcript_dirs(root)
    path = Path(recorded) if recorded and Path(recorded).is_file() else dirs[0] / ("%s.jsonl" % session_id)
    rp = path.resolve()
    if not any(under(rp, d) and not under(rp, d / "memory") for d in dirs):
        raise Unprotected(str(rp))
    return rp


def parse_ts(raw: object) -> Optional[float]:
    """A transcript timestamp ('2026-09-28T11:31:45.123Z') as epoch seconds; None
    for anything that is not UTC ISO 8601."""
    if not isinstance(raw, str):
        return None
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|\+00:00)", raw)
    if not m:
        return None
    return calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float(m.group(2) or 0)


def local_stamp_epoch(stamp: str) -> float:
    """A local 'YYYY-mm-ddTHH:MM:SS' (leaselib.now_stamp; the marker's `started`)."""
    return time.mktime(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))


def iso_utc(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(epoch)) + ".%03dZ" % int((epoch % 1) * 1000)


def normalize(text: str) -> str:
    """Whitespace collapsed, case-folded, surrounding punctuation stripped (§7.2)."""
    return " ".join(text.split()).casefold().strip(EDGES)


def is_yes(text: str) -> bool:
    """The reply begins with the word yes — tty's rule, applied to the transcribed
    yes too (Decision 30): 'Yes, push it.' is; 'yesterday…', 'ok', 'no, wait' are not."""
    return re.match(r"yes\b", normalize(text or "")) is not None


def classify(e: dict) -> str:
    """operator | queued | assistant_text | harness | unknown_provenance | other."""
    d = e["data"] or {}
    if d.get("isSidechain"):
        return "other"
    if e["type"] == "assistant":
        return "assistant_text" if e["text"] else "other"
    if e["type"] != "user":
        return "other"
    if e["tool_result"] or "toolUseResult" in d or "sourceToolUseID" in d or d.get("isMeta"):
        return "other"
    origin = d.get("origin")
    if isinstance(origin, dict):
        if origin.get("kind") != "human":
            return "other"
        return "queued" if d.get("promptSource") == "queued" else "operator"
    if HARNESS_TAG.match(e["text"]):
        return "harness"
    return "unknown_provenance" if e["text"] else "other"


def _ref(e: dict) -> dict:
    return {"uuid": e["data"].get("uuid"), "timestamp": e["data"].get("timestamp")}


def _entries(path: Path) -> list:
    import capture   # the one parser; imported here, not at load (a test stub of capture.py exits on import)
    try:
        lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        raise Missing(str(path))
    except OSError as e:
        raise Unreadable("%s: %s" % (path, e.strerror or e))
    return capture.scan_entries(lines)[0]


def find_operator_words(path: Path, quote: str, after: float, require_shown: bool,
                        shown_text: Optional[str] = None) -> dict:
    """{"transcript_ref": {uuid, timestamp}, "shown_ref": {uuid, timestamp} | None,
    "text": the entry's own text} for the first operator-typed entry after `after`
    (epoch seconds) whose WHOLE normalized text equals the normalized quote
    (Decision 30: a fragment of a longer turn is not what the operator said) —
    with require_shown, one that an assistant entry with text precedes, after the
    cut-off, and when shown_text is given, an assistant entry whose normalized
    text contains normalize(shown_text) (the block, not any reply); the latest
    such entry is shown_ref. Raises Missing, Unreadable (A12, fail closed),
    NotShown or NotFound."""
    entries = _entries(path)
    start = None
    for i, e in enumerate(entries):
        ts = parse_ts((e["data"] or {}).get("timestamp")) if e["type"] in ("user", "assistant") else None
        if ts is not None and ts > after:
            start = i
            break
    tail = entries[start:] if start is not None else []
    bad = [e for e in tail if not e["readable"] or (e["type"] in ("user", "assistant") and (
        not isinstance(e["data"].get("uuid"), str) or parse_ts(e["data"].get("timestamp")) is None))]
    if bad:
        raise Unreadable("%d of the %d entries after the cut-off have a shape this build does not read"
                         % (len(bad), len(tail)))
    want = normalize(quote)
    if not want:
        raise NotFound("nothing to look for")
    mark = normalize(shown_text) if shown_text else None
    shown: Optional[dict] = None
    not_shown = unknown_hit = False
    for e in tail:
        kind = classify(e)
        if kind == "assistant_text":
            if mark is None or mark in normalize(e["text"]):
                shown = e
            continue
        if normalize(e["text"]) != want:
            continue
        if kind == "operator":
            if require_shown and shown is None:
                not_shown = True
                continue
            return {"transcript_ref": _ref(e), "shown_ref": _ref(shown) if shown else None, "text": e["text"]}
        if kind == "unknown_provenance":
            unknown_hit = True
    if unknown_hit:
        raise Unreadable("the words are only in a user entry that carries no origin field, so who typed it "
                         "cannot be told")
    if not_shown:
        raise NotShown("no assistant turn showing the block between the cut-off and the words")
    raise NotFound("not an operator-typed entry after the cut-off")


def operator_entry(path: Path, uuid: str) -> Optional[str]:
    """The text of the entry `uuid` when the operator typed it, else None
    (confirm's re-check of a skip reason, Decision 31). Missing / Unreadable propagate."""
    for e in _entries(path):
        if e["readable"] and (e["data"] or {}).get("uuid") == uuid:
            return e["text"] if classify(e) == "operator" else None
    return None


def seam_allowed(root: Path) -> bool:
    """The suite's DAEDALUS_TEST_TTY_ANCESTRY=skip counts only for a home under the
    system temp directory — every bats fixture home, and no deployment (Decision 32)."""
    rr = Path(root).resolve()
    temps = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
    return any(under(rr, t) for t in temps)


def _ps(pid: int) -> Optional[Tuple[int, Set[str]]]:
    """(parent pid, {executable name, argv[0] name}) of a live process, from /bin/ps."""
    try:
        a = subprocess.run(["/bin/ps", "-o", "ppid=", "-o", "comm=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=5).stdout.strip().split(None, 1)
        c = subprocess.run(["/bin/ps", "-o", "command=", "-p", str(pid)],
                           capture_output=True, text=True, timeout=5).stdout.strip().split()
    except (OSError, subprocess.SubprocessError):
        return None
    if len(a) != 2 or not a[0].isdigit():
        return None
    names = {os.path.basename(a[1].strip()).lstrip("-")}
    if c:
        names.add(os.path.basename(c[0]).lstrip("-"))
    return int(a[0]), names


def agent_ancestry(root: Path) -> Optional[str]:
    """Why this process is not a person's terminal session, or None (Decision 32):
    an ancestor is a Claude Code process (named claude, or a pid recorded in
    $CLAUDE_CONFIG_DIR/sessions/), or the chain reaches launchd without a terminal
    login (login, sshd, tmux, screen, or a name in promote.tty_parents) — a process
    double-forked away from the agent. On one POSIX user this is a speed bump,
    not a proof; §7.4 and Appendix E say so."""
    if os.environ.get("DAEDALUS_TEST_TTY_ANCESTRY") == "skip" and seam_allowed(root):
        return None
    sessions = {int(p.stem) for p in (config_dir() / "sessions").glob("*.json") if p.stem.isdigit()}
    raw = v._lib(root, "cfg promote.tty_parents 2>/dev/null || true")
    extra = [x.strip().strip("'\"") for x in raw.split(",") if x.strip()]   # comma-separated; names may hold spaces
    parents = set(TTY_PARENTS) | set(extra)
    pid, terminal = os.getpid(), False
    for _ in range(64):
        info = _ps(pid)
        if info is None:
            break
        ppid, names = info
        if names & set(AGENT_NAMES) or (pid != os.getpid() and pid in sessions):
            return "a Claude Code session (process %d) started this process" % pid
        if names & parents:
            terminal = True
        if ppid <= 1:
            break
        pid = ppid
    if not terminal:
        return ("this process does not descend from a terminal login (login, sshd, tmux or screen); if yours runs "
                "under another program, name it in promote.tty_parents in config.yaml")
    return None


def tty_answer(prompt: str, root: Path) -> Tuple[str, str]:
    """(the line typed, the terminal's name), from /dev/tty — never stdin. A
    process with no controlling terminal (a Bash tool, a hook) raises NoTerminal;
    one that descends from an agent, or from no terminal login, raises NotAPerson
    (Decision 32). Raw reads on the descriptor: a buffered text stream opened r+
    on /dev/tty raises 'not seekable' (measured). Any other terminal error is
    NoTerminal, so an odd terminal still fails closed."""
    try:
        fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError as e:
        raise NoTerminal(e.strerror or str(e))
    try:
        why = agent_ancestry(root)
        if why:
            raise NotAPerson(why)
        name = os.ttyname(fd)
        os.write(fd, prompt.encode("utf-8", "replace"))
        buf = b""
        while not buf.endswith(b"\n"):
            ch = os.read(fd, 1)
            if not ch:
                break
            buf += ch
    except OSError as e:
        raise NoTerminal(e.strerror or str(e))
    finally:
        os.close(fd)
    return buf.decode("utf-8", "replace").rstrip("\n").rstrip("\r"), name
