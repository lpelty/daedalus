#!/usr/bin/env python3
"""The operator's recorded yes, checked against the session's own transcript
(spec §7.2 step 2, §7.4, §4.8 'Handover', §10 A12).

`promote.confirm: transcribed` — the default, by the operator's decision of
2026-09-25 — records the prime's transcription of what the operator said; this
module checks it. The words must be an entry the operator TYPED — the whole
turn, not a fragment of one (plan 4 Decision 30) — after a cut-off (the
promotion's primaries, Decision 35; for --skip-review the earlier REFUTED
prepare; for `prime take --reason` the moment the holder took the pen, its
bound_epoch — always an absolute instant, never a local stamp the reading
process's TZ would move) and — for
promote — as the operator's first reply to an assistant entry with text that
follows the cut-off and carries the block's opening words (the turn in which
the prime showed it) or ENDS with the block's one-line invitation (the prime's
answer to a question of theirs, asking again — the operator may ask first,
2026-10-14; a turn between them answered that turn instead). A
transcript this build cannot read fails CLOSED, never a pass.

One parser (A12): capture.scan_entries reads the lines; this module decides who
typed an entry. The rule, measured on Claude Code 2.1.251–2.1.282 (plan 4
Decisions 2 and 43): type user, not a sidechain, no tool_result block /
toolUseResult / sourceToolUseID, not isMeta, origin.kind == "human" and
promptSource not "queued" (a queued prompt was typed while the prime was still
working — before the block was on screen). A user text entry with no origin
that starts with a harness tag is a harness record; one with no origin and no
tag is of unknown provenance, and words found only there fail closed.

An operator-typed entry counts only when Claude Code wrote it into the
conversation it went on with (plan 4 completeness critic, finding 2): the
file's uuids are unique and each parentUuid names an entry written before it
(else Unreadable), and the entry lies on the chain from the file's last entry
back through parentUuid with an assistant entry — the harness's reply — after
it there (else NotWritten). A line appended by another writer fails that. A
whole-file rewrite does not (critic-fix review, finding 3), so the entry must
also be a prompt Claude Code reported to the UserPromptSubmit hook as it was
submitted, with the transcript before it byte-identical to what it was then
(record_prompt / submitted; else NotSubmitted).

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
import hashlib
import json
import os
import pwd
import re
import shutil
import string
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

CONFIRM_MODES = ("transcribed", "tty")
HARNESS_TAG = re.compile(r"^\s*<(system-reminder|command-name|command-message|command-args|local-command-[a-z-]+|"
                         r"task-notification|bash-[a-z-]+|user-prompt-submit-hook)\b")
EDGES = string.punctuation + "\u201c\u201d\u2018\u2019\u00ab\u00bb\u2026\u2014\u2013 "
TTY_PARENTS = ("login", "sshd")
MULTIPLEXERS = {"screen": "screen", "SCREEN": "screen", "tmux": "tmux"}   # a pane's ancestor is the server
AGENT_NAMES = ("claude",)
TOOL_PATH = "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"


class Unreadable(Exception):
    """The transcript holds a shape this build cannot read (A12): fail closed."""


class Missing(Exception):
    """No transcript where the marker or the configuration says it is."""


class Unprotected(Exception):
    """The transcript resolves outside every directory nothing may write (Decision 36)."""


class NotFound(Exception):
    """The words are no operator-typed entry after the cut-off."""


class NotWritten(NotFound):
    """The words are in an entry Claude Code did not write there: nothing it wrote afterwards follows from it
    (plan 4 completeness critic, finding 2 — a line appended to the file by another writer)."""


class NotSubmitted(NotFound):
    """The words are in an operator-typed entry, but not as a prompt Claude Code reported to Daedalus when it was
    submitted, with the transcript before it unchanged since (critic-fix review, finding 3 — a whole-file rewrite)."""


class NotShown(Exception):
    """The words were typed after the cut-off, but not as the operator's first reply to a turn showing the block
    or ending with its invitation line."""


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
    (outside <dir>/memory/), or when it has a second hard link (its bytes are also
    a path the guard does not deny) — a transcript the guard does not protect is
    not evidence (Decision 36; plan 4 Task 2 review)."""
    marker = v.read_marker(root, session_id) or {}
    recorded = str(marker.get("transcript_path") or "")
    dirs = transcript_dirs(root)
    path = Path(recorded) if recorded and Path(recorded).is_file() else dirs[0] / ("%s.jsonl" % session_id)
    rp = path.resolve()
    if not any(under(rp, d) and not under(rp, d / "memory") for d in dirs):
        raise Unprotected(str(rp))
    try:
        if rp.stat().st_nlink > 1:
            # a second hard link shares these bytes with a path the guard does not deny
            raise Unprotected("%s (it has another hard link)" % rp)
    except FileNotFoundError:
        pass
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


def iso_utc(epoch: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(epoch)) + ".%03dZ" % int((epoch % 1) * 1000)


_CURLY = {0x2018: "'", 0x2019: "'", 0x201c: '"', 0x201d: '"'}


def normalize(text: str) -> str:
    """Whitespace collapsed, case-folded, curly quotes straightened, surrounding punctuation stripped (§7.2)."""
    return " ".join(text.translate(_CURLY).split()).casefold().strip(EDGES)


# Decision 30, as revised 2026-10-17 (v0.10.0): the operator's own words are an acknowledgement when
# they carry an affirmative word or phrase and no negation or hold word, each at word boundaries, and
# do not end in a question mark. One rule for the transcribed reply, the tty line and release --remove.
_WORD = r"(?<![\w'])(?:%s)(?![\w'])"
ASSENT_RE = re.compile(_WORD % "|".join((
    "yes", "yeah", "yep", "yup", "ok", "okay", "sure", "go ahead", "go", "proceed", "approved?", "confirm(?:ed)?",
    "do it", "ship it", "push it", "sounds good", "lgtm")) + "|\U0001f44d")
DISSENT_RE = re.compile(_WORD % "|".join((
    "no", "nope", "nah", "not", "cannot", "can't", "don't", "dont", "never", "wait", "stop", "hold", "cancel",
    "abort", "later")))


def is_assent(text: str) -> bool:
    """The operator's reply is an acknowledgement (Decision 30, revised in v0.10.0): an affirmative word
    or phrase (yes, ok, okay, go ahead, proceed, sounds good, ship it, ...) and none of the negation or
    hold words (no, not, don't, wait, stop, hold, later, ...), at word boundaries, and not a question.
    'Okay, yes, proceed.' is; 'yesterday was fine', 'okay but why?', 'no, wait', '' are not."""
    raw = " ".join((text or "").translate(_CURLY).split()).casefold()
    if raw.rstrip(" \"')]}»\u2019\u201d").endswith("?"):
        return False
    t = normalize(text or "")
    return bool(t) and DISSENT_RE.search(t) is None and ASSENT_RE.search(t) is not None


is_yes = is_assent      # the name every caller used before v0.10.0


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


def _chain(entries: list) -> dict:
    """uuid -> entry for every entry that carries a uuid (a shape this build cannot read included: it still
    links), checking the two invariants Claude Code keeps
    (measured on 400 transcripts of 2.1.251-2.1.283, and on the live-shape fixture: no exception): no uuid is
    written twice, and an entry's parentUuid, when set, names an entry written before it in the file. Raises
    Unreadable when either fails — a file that does not link the way the harness writes it is not read as
    evidence (critic finding 2). Timestamps are no invariant: parallel tool results are written out of order."""
    seen: dict = {}
    for e in entries:
        d = e["data"]
        if not isinstance(d, dict) or not isinstance(d.get("uuid"), str):
            continue
        u, parent = d["uuid"], d.get("parentUuid")
        if u in seen or (parent is not None and parent not in seen):
            raise Unreadable("the transcript's entries do not link the way Claude Code writes them (%s)"
                             % ("the uuid %s is written twice" % u if u in seen else
                                "the entry %s names a parent written nowhere before it" % u))
        seen[u] = e
    return seen


def harness_wrote(seen: dict, e: dict) -> bool:
    """Whether Claude Code wrote entry e into the conversation it went on with (critic finding 2): e lies on
    the chain from the file's last entry back through each parentUuid (logicalParentUuid across a compaction),
    and an assistant entry — the harness's reply — lies on that chain after it. A line appended to the file by
    another writer fails one or the other: appended last, nothing the harness wrote follows it; passed by the
    harness, the harness's later entries descend from its own last entry, not from the appended line. Measured:
    every operator-typed turn in 400 transcripts lay on its file's final chain, and all but the last turn of a
    session had an assistant entry after it there. It stops an appended line; it does not stop a whole-file rewrite,
    which can insert a yes and a reply after the block and re-parent the entry after them in any earlier turn — every
    invariant then holds through later harness writes (critic-fix review, finding 3). `submitted` is what stops
    that; neither is proof of who wrote the file."""
    if not seen:
        return False
    cur: Optional[dict] = list(seen.values())[-1]
    replied = False
    for _ in range(len(seen) + 1):
        if cur is None:
            return False
        if cur is e:
            return replied
        replied = replied or cur["type"] == "assistant"
        d = cur["data"]
        cur = seen.get(d.get("parentUuid") or d.get("logicalParentUuid") or "")
    return False


# --- the prompts Claude Code reported (critic-fix review, finding 3) ---------------------------------------------
# A whole-file rewrite can insert a yes after the block and re-parent the entry after it, and every chain invariant
# holds through any number of later harness writes. So a yes is bound to something the transcript does not carry:
# the UserPromptSubmit hook (core/lease-board.py) is handed each prompt by Claude Code as it is submitted, and records
# a hash of its words with the transcript's size and a hash of its bytes at that moment. confirm accepts an operator
# entry only when such a record exists for its words, the transcript's first <size> bytes are still those, and the
# entry is the prompt the record reported: the last typed turn inside that prefix (Claude Code wrote it before the
# hook ran) or the first typed turn after it (after), with the block it answers inside it. The record lives beside the
# transcript, where the guard and the Edit check deny every write.

def prompts_path(transcript: Path) -> Path:
    return Path(transcript).with_name(Path(transcript).name + ".daedalus-prompts")


def _digest(text: str) -> str:
    return hashlib.sha256(normalize(text).encode("utf-8")).hexdigest()


def record_prompt(transcript_path: str, prompt: str, session_id: str = "") -> dict:
    """UserPromptSubmit: record that Claude Code reported `prompt` as submitted into this transcript, with the
    transcript's size (to its last whole line) and a hash of those bytes, now. Returns the row it wrote (its
    `size` is the transcript offset the AMI's operator record keeps — frame-jack spec §5.5; one read per prompt)."""
    t = Path(transcript_path).expanduser().resolve()
    try:
        data = t.read_bytes()
    except FileNotFoundError:
        data = b""
    data = data[:data.rfind(b"\n") + 1]
    row = {"at": time.time(), "session_id": session_id, "prompt": _digest(prompt), "size": len(data),
           "prefix": hashlib.sha256(data).hexdigest()}
    with prompts_path(t).open("a") as fh:
        fh.write(json.dumps(row) + "\n")
    return row


def _records(path: Path) -> list:
    try:
        lines = prompts_path(Path(path).resolve()).read_text().splitlines()
    except OSError:
        return []
    out = []
    for ln in lines:
        try:
            r = json.loads(ln)
        except ValueError:
            continue
        if isinstance(r, dict) and isinstance(r.get("size"), int) and isinstance(r.get("prefix"), str):
            out.append(r)
    return out


def _spans(data: bytes) -> dict:
    """uuid -> (start, end) byte offsets of the line that carries it."""
    out, pos = {}, 0
    for line in data.split(b"\n"):
        end = pos + len(line) + 1
        try:
            d = json.loads(line)
        except ValueError:
            d = None
        if isinstance(d, dict) and isinstance(d.get("uuid"), str):
            out.setdefault(d["uuid"], (pos, end))
        pos = end
    return out


NEVER_REPORTED = ("the words are in an entry Claude Code never reported to Daedalus as a prompt the operator "
                  "submitted, so they were written into the file some other way")
CHANGED_AFTER = ("the transcript before those words was changed after the operator typed them, so the conversation "
                 "they answer is not the one on screen")


def submitted(path: Path, entries: list, e: dict, answers: Optional[dict], after: float) -> Optional[str]:
    """None when entry e is a prompt Claude Code reported (see above) after `after`, with `answers` — the block it
    replies to — inside the unchanged prefix; else why not."""
    uid = (e["data"] or {}).get("uuid")
    want = _digest(e["text"])
    recs = [r for r in _records(path) if r.get("prompt") == want and float(r.get("at") or 0) > after]
    if not recs:
        return NEVER_REPORTED
    try:
        data = Path(path).read_bytes()
    except OSError as err:
        raise Unreadable("%s: %s" % (path, err.strerror or err))
    spans = _spans(data)
    me = spans.get(uid)
    if me is None:
        return NEVER_REPORTED
    typed = sorted(spans[t["data"]["uuid"]] for t in typed_turns(entries) if t["data"].get("uuid") in spans)
    ans = spans.get((answers["data"] or {}).get("uuid")) if answers else None
    why = NEVER_REPORTED
    for r in recs:
        size = r["size"]
        inside = me[1] <= size and all(t[1] <= me[0] or t[1] > size for t in typed if t != me)
        beyond = me[0] >= size and not any(size <= t[0] < me[0] for t in typed) and (answers is None or (
            ans is not None and ans[1] <= size))
        if not (inside or beyond):
            continue
        if hashlib.sha256(data[:size]).hexdigest() != r["prefix"]:
            why = CHANGED_AFTER
            continue
        return None
    return why


# Critic finding 4 (A12): the sentence doctor and confirm say when this build's transcript shape is not the one
# Daedalus was tested against.
DRIFT = ("this Claude Code build's transcript shape is not the one Daedalus was tested against; promote confirm "
         "will refuse until the fixture is refreshed — see core/tests/fixtures/transcripts/PROVENANCE.md")


def typed_turns(entries: list) -> list:
    """The user text entries a person could have typed in an interactive session: not a sidechain, a tool
    result, an isMeta record or a compaction summary, and not a headless (sdk) prompt — those carry no origin by
    design."""
    out = []
    for e in entries:
        d = e["data"] if isinstance(e["data"], dict) else {}
        if e["type"] != "user" or not e["readable"] or not e["text"] or d.get("isSidechain") or d.get("isMeta"):
            continue
        if e["tool_result"] or "toolUseResult" in d or "sourceToolUseID" in d or d.get("isCompactSummary"):
            continue
        if str(d.get("entrypoint") or "").startswith("sdk") or d.get("promptSource") == "sdk":
            continue
        out.append(e)
    return out


def shape_problem(entries: list, strict: bool) -> Optional[str]:
    """Why this build's transcript does not read as the tested shape (critic finding 4, A12), or None.
    Always: typed turns exist, none carries origin.kind human and some carry no origin at all (the 2.1.283
    measurement: 0 of its user entries with an origin). strict (doctor, the newest interactive transcript whole):
    any entry this build does not read, entries that do not link the way the harness writes them, or any typed
    turn with no origin field."""
    turns = typed_turns(entries)
    kinds = [classify(e) for e in turns]
    unknown = kinds.count("unknown_provenance")
    typed = kinds.count("operator") + kinds.count("queued")
    if strict:
        bad = sum(1 for e in entries if not e["readable"])
        if bad:
            return "%d of its %d entries have a shape this build does not read" % (bad, len(entries))
        try:
            _chain(entries)
        except Unreadable as e:
            return str(e)
    if unknown and (strict or not typed):
        return ("%d of its %d typed turns carry no origin field, so who typed them cannot be told"
                % (unknown, len(turns)))
    return None


def shape_report(root: Path) -> Tuple[str, str]:
    """For doctor (critic finding 4, read-only): ("ok", build version), ("drift", why — naming the file) or
    ("none", "") for the newest transcript of this deployment's sessions that has turns a person typed."""
    files: List[Path] = []
    for d in transcript_dirs(root):
        try:
            files += [f for f in d.glob("*.jsonl") if f.is_file()]
        except OSError:
            continue
    for f in sorted(set(files), key=lambda x: x.stat().st_mtime, reverse=True)[:20]:
        try:
            entries = _entries(f)
        except (Missing, Unreadable):
            continue
        turns = typed_turns(entries)
        if not turns:
            continue
        why = shape_problem(entries, strict=True)
        if why:
            return "drift", "%s, in %s" % (why, f.name)
        if not any(classify(e) in ("operator", "queued") for e in turns):
            continue      # nothing a person typed is marked either way here: not a measure
        versions = [str((e["data"] or {}).get("version") or "") for e in turns]
        return "ok", max(set(versions), key=versions.count) or "unknown build"
    return "none", ""


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


def ends_with_line(n: str, end: str) -> bool:
    """Whether normalized text `n` ends with the invitation `end` as a whole phrase: nothing alphanumeric
    touches its start (so window 102's line is not window 02's), and only punctuation, quotes, markdown
    marks or symbols — an emoji, a closing backtick or asterisks — may follow it."""
    return re.search(r"(?:^|[^0-9a-z])%s[^0-9a-z]*$" % re.escape(end), n) is not None


def find_operator_words(path: Path, quote: str, after: float, require_shown: bool,
                        shown_text: Optional[str] = None, shown_end: Optional[str] = None) -> dict:
    """{"transcript_ref": {uuid, timestamp}, "shown_ref": {uuid, timestamp} | None,
    "text": the entry's own text} for the first operator-typed entry after `after` that Claude Code wrote
    into the conversation it went on with (harness_wrote — critic finding 2),
    (epoch seconds) whose WHOLE normalized text equals the normalized quote
    (Decision 30: a fragment of a longer turn is not what the operator said) —
    with require_shown, one that is the operator's FIRST turn after an assistant
    entry with text that follows the cut-off (when shown_text is given, one whose
    normalized text contains normalize(shown_text): the block, not any reply;
    when shown_end is given, also — once the block was in a reply after the cut-off — one whose
    normalized text ends with normalize(shown_end) as a whole phrase (`ends_with_line`): a reply that
    asks again; with shown_end, the prime's LAST text entry before the words must be one of those two,
    so a further question after a tool call clears the line);
    that entry is shown_ref. The yes answers the block itself: any user turn
    between the block and the words (operator-typed, queued, or of unknown
    provenance) was the reply to it, and words after it answer something else
    unless the block is shown again. Raises Missing, Unreadable (A12, fail closed; also a
    file whose entries do not link the way the harness writes them), NotWritten (the words
    only in entries the harness did not write), NotShown or NotFound."""
    entries = _entries(path)
    # The tail starts after the last user/assistant entry PROVABLY before the cut-off,
    # so an entry whose timestamp this build writes in a form parse_ts does not read
    # (an offset, epoch milliseconds) lands in it and fails closed as Unreadable —
    # never silently outside it, which would read as "the words are not there" (A12).
    last_before = -1
    for i, e in enumerate(entries):
        ts = parse_ts((e["data"] or {}).get("timestamp")) if e["type"] in ("user", "assistant") else None
        if ts is not None and ts <= after:
            last_before = i
    tail = entries[last_before + 1:]
    bad = [e for e in tail if not e["readable"] or (e["type"] in ("user", "assistant") and (
        not isinstance(e["data"].get("uuid"), str) or parse_ts(e["data"].get("timestamp")) is None))]
    if bad:
        raise Unreadable("%d of the %d entries after the cut-off have a shape this build does not read"
                         % (len(bad), len(tail)))
    want = normalize(quote)
    if not want:
        raise NotFound("nothing to look for")
    seen = _chain(entries)
    drift = shape_problem(entries, strict=False)
    if drift:
        raise Unreadable(drift)     # critic finding 4: this build's typed turns are not the tested shape
    not_written = False
    not_submitted: Optional[str] = None
    mark = normalize(shown_text) if shown_text else None
    end = normalize(shown_end) if shown_end else None
    shown: Optional[dict] = None
    block_seen = mark is None     # with shown_end, the line arms only once the block itself was in a reply
    not_shown = unknown_hit = False
    for e in tail:
        kind = classify(e)
        if kind == "assistant_text":
            n = normalize(e["text"])
            if mark is not None and mark in n:
                block_seen, shown = True, e
            elif end is not None:
                # The yes answers the last thing the prime said: an entry that neither shows the block nor
                # ends with its line (a further question after a tool call, say) clears an earlier one.
                shown = e if block_seen and ends_with_line(n, end) else None
            elif mark is None:
                shown = e
            continue
        if kind not in ("operator", "queued", "unknown_provenance"):
            continue
        answers, shown = shown, None   # this turn is the reply to the block; a later one answers something else
        if normalize(e["text"]) != want:
            continue
        if kind == "operator":
            if require_shown and answers is None:
                not_shown = True
                continue
            if not harness_wrote(seen, e):
                not_written = True      # critic finding 2: appended to the file, not written by Claude Code
                continue
            why = submitted(path, entries, e, answers, after)
            if why:
                not_submitted = why     # critic-fix review, finding 3: not a prompt Claude Code reported
                continue
            return {"transcript_ref": _ref(e), "shown_ref": _ref(answers) if answers else None, "text": e["text"]}
        if kind == "unknown_provenance":
            unknown_hit = True
    if unknown_hit:
        raise Unreadable("the words are only in a user entry that carries no origin field, so who typed it "
                         "cannot be told")
    if not_written:
        raise NotWritten("the words are in an entry nothing Claude Code wrote follows it on the conversation's "
                         "chain, so it was added to the file afterwards")
    if not_submitted:
        raise NotSubmitted(not_submitted)
    if not_shown:
        raise NotShown("the words are not the operator's first reply to an assistant turn showing the block, "
                       "or ending with its invitation line, after the cut-off")
    raise NotFound("not an operator-typed entry after the cut-off")


def operator_entry(path: Path, uuid: str) -> Optional[str]:
    """The text of the entry `uuid` when the operator typed it, else None
    (confirm's re-check of a skip reason, Decision 31). Missing / Unreadable propagate."""
    entries = _entries(path)
    seen = _chain(entries)
    for e in entries:
        if e["readable"] and (e["data"] or {}).get("uuid") == uuid:
            ok = classify(e) == "operator" and harness_wrote(seen, e) and submitted(path, entries, e, None, 0.0) is None
            return e["text"] if ok else None
    return None


_CS_DARWIN_USER_TEMP_DIR = 65537   # <unistd.h>; Python's os.confstr has no name for it


def temp_roots() -> Set[Path]:
    """The system temp directories, resolved, WITHOUT the environment: /tmp,
    /private/tmp, /var/tmp and, on macOS, the per-user temp directory as libc
    reports it from the user's record (confstr). Never TMPDIR/TEMP/TMP
    (tempfile.gettempdir honours them): the caller sets those."""
    roots = {Path(p).resolve() for p in ("/tmp", "/private/tmp", "/var/tmp")}
    if sys.platform == "darwin":
        try:
            roots.add(Path(os.confstr(_CS_DARWIN_USER_TEMP_DIR)).resolve())
        except (ValueError, OSError, TypeError):
            pass
    return roots


def seam_allowed(root: Path) -> bool:
    """The suite's DAEDALUS_TEST_TTY_ANCESTRY=skip counts only for a home under a
    system temp directory — every bats fixture home, and no deployment (Decision 32)."""
    rr = Path(root).resolve()
    return any(under(rr, t) for t in temp_roots())


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


def _clean_env() -> dict:
    """An environment the caller did not choose (SCREENDIR, TMUX_TMPDIR, PATH are
    theirs to set): the user's own home and name, a fixed PATH."""
    pw = pwd.getpwuid(os.getuid())
    return {"PATH": TOOL_PATH, "HOME": pw.pw_dir, "USER": pw.pw_name, "LOGNAME": pw.pw_name}


def mux_attached(kind: str, pid: int) -> bool:
    """Whether the screen or tmux server `pid` has a terminal attached, asked in
    the default socket directory with a clean environment. Anything unclear —
    no such tool, a server not found there, an error — is False (fail closed). A
    detached session is what an agent can make with two stock commands
    (`screen -dm …`, then `screen -X stuff yes`): measured 2026-09-28."""
    tool = shutil.which(kind, path=TOOL_PATH)
    if not tool:
        return False
    env = _clean_env()

    def run(*args: str) -> str:
        try:
            return subprocess.run([tool, *args], capture_output=True, text=True, timeout=5, env=env,
                                  stdin=subprocess.DEVNULL).stdout
        except (OSError, subprocess.SubprocessError):
            return ""
    if kind == "screen":
        m = re.search(r"^\s*%d\.\S*\s+\(([^)]*)\)" % pid, run("-ls"), re.M)
        return bool(m) and m.group(1).strip().lower() in ("attached", "multi, attached")
    sockets = Path("/tmp/tmux-%d" % os.getuid())
    try:
        candidates = sorted(sockets.iterdir())
    except OSError:
        return False
    for sock in candidates:
        if run("-S", str(sock), "display-message", "-p", "#{pid}").strip() == str(pid):
            return bool(run("-S", str(sock), "list-clients", "-F", "#{client_pid}").strip())
    return False


def agent_ancestry(root: Path) -> Optional[str]:
    """Why this process is not a person's terminal session, or None (Decision 32):
    an ancestor is a Claude Code process (named claude, or a pid recorded in
    $CLAUDE_CONFIG_DIR/sessions/); an ancestor is a screen or tmux server with no
    terminal attached (a detached session an agent made and types into); or the
    chain reaches launchd without a terminal login (login, sshd, an attached
    screen or tmux, or a name in promote.tty_parents) — a process double-forked
    away from the agent. On one POSIX user this is a speed bump, not a proof: a
    program-made terminal running /usr/bin/login -pf <user> (which the user may
    run for themselves) in a double-forked process still passes it, measured
    2026-09-28; §7.4 and Appendix E say so."""
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
        mux = next((MULTIPLEXERS[n] for n in names if n in MULTIPLEXERS), None)
        if mux:
            if not mux_attached(mux, pid):
                return ("this process runs inside a %s session with no terminal attached (process %d), which "
                        "cannot be told from one an agent made; type the answer in a plain terminal window, or "
                        "in an attached session" % (mux, pid))
            terminal = True
        if names & parents:
            terminal = True
        if ppid <= 1:
            break
        pid = ppid
    if not terminal:
        return ("this process does not descend from a terminal login (login, sshd, or an attached screen or tmux); "
                "if yours runs under another program, name it in promote.tty_parents in config.yaml")
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
