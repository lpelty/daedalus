#!/usr/bin/env python3
"""The only reader and writer of state/leases/ (spec §4.1).

One file per live window, state/leases/<NN>.json, plus two sidecars: <NN>.seen
(an empty file whose mtime is the heartbeat) and <NN>.changed (the observed
changed set). prime.json names the session holding the pen. Every mutation
runs under fcntl.flock(state/leases/.lock, LOCK_EX) around the whole
check-and-write and lands by tmp + os.replace; allocation opens the new file
O_CREAT|O_EXCL; rebinding is a compare-and-swap on the session_id the caller
read. Readers take LOCK_SH for one directory read. Python 3.9, stdlib only.

Also the one implementation of "which tree is mine" (§4.4): lib.sh
target_path shells to `leaselib.py resolve` when lease files exist, so a
bash caller and a Python caller can never disagree.
"""
from __future__ import annotations

import calendar
import contextlib
import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

LEASE_RE = re.compile(r"[0-9]{2}")
ALIAS_RE = re.compile(r"[a-z][a-z0-9-]{1,31}")
ALIAS_DENY = {"prime", "main", "master", "target", "vault", "state"}
NEVER_ISSUED = "00"


class Refused(Exception):
    """A resolution that must fail closed; str(e) is the operator sentence."""


BOARD_UNRENDERED = "The lease board could not be rendered: %s"

# A session that started before the upgrade finished holds no window and none opens for it (spec §14: create and
# claim are refused until the stamp is written), so the ordinary no-window remedy is impossible there; the Stop
# hook repeated it every turn on another deployment (2026-10-13). What that session is told instead:
NO_WINDOW_PENDING = ("This session started before the upgrade to %s finished, so it holds no window and none opens "
                     "for it. Tell the operator to close this session and start a new one; that start finishes the "
                     "upgrade.")
# That restart advice is true only while a start would finish the upgrade: it has not run yet, or a run in the
# background took the copy (update-command Decision 9). When the upgrade stopped, the session is told that stop's
# own sentence, whose remedy is what the operator needs; while the background copy runs, that it is running. The
# three share NO_WINDOW_PENDING's opening (boundary-hook.py PENDING_PREFIX).
NO_WINDOW_STOPPED = ("This session started before the upgrade to %s finished, so it holds no window and none opens "
                     "for it. The upgrade stopped: %s")
NO_WINDOW_RUNNING = ("This session started before the upgrade to %s finished, so it holds no window and none opens "
                     "for it. The upgrade is taking its safety copy in the background; the board says when it is done.")
# upgrade.pending_line's three sentences of its own, read here without importing upgrade.py (pending_stop; a test pins
# them equal to upgrade.py's)
UPGRADE_NOT_RUN = "upgrade to %s has not run yet — it runs at the next session start in this home"
SNAP_BG_COPIED = ("The upgrade to %s took its safety copy of target/ in the background; it finishes at the next "
                  "session start in this home")
SNAP_BG_GONE = ("upgrade to %s incomplete: the run in the background ended before it finished (state/upgrade.log "
                "says how far it got); it runs again at the next session start")

# SessionStart's two lease-lock waits are bounded by the hook's budget (§4.2;
# plan 2 Decision 18). What each says when the lock stays busy past it:
LOCK_BUSY_AT_START = ("This window was not bound at start: the lease lock stayed busy past the start budget (a "
                      "`core/lease.sh` command or another window's start was holding it). Run `core/lease.sh claim "
                      "<NN>` with your window's number, or `core/lease.sh create` and claim the number it prints.")
BOARD_LOCK_BUSY = "the lease lock stayed busy past the start budget; the board renders at your next prompt"
BOARD_LOCK_BUSY_PROMPT = ("the lease lock stayed busy (a window is being made or swept); the board draws at your next "
                          "prompt, or run `core/lease.sh list` to wait for it")


def leases_dir(root: Path) -> Path:
    return root / "state" / "leases"


@contextlib.contextmanager
def lock(root: Path, shared: bool = False, deadline: Optional[float] = None,
         busy: str = "the lease lock stayed busy") -> Iterator[None]:
    """NOT re-entrant. flock belongs to the open file description and this
    opens the file afresh, so a nested lock() — in this process or a child
    process — blocks until the outer one is released, i.e. forever. Every
    function that runs under the lock is named *_locked or says "Caller holds
    the lock", and never calls lock(), resolve(), recompute_all_changed(),
    board_for() or lib.sh target_path (which shells back into leaselib).

    Without `deadline` it blocks, as every shell command does (a shell has no
    budget). With one (epoch seconds; SessionStart's budget, §4.2) it polls
    without blocking every 50 ms and, still busy at the deadline, raises
    Refused(busy) with nothing done under the lock. A lock that is free is
    taken even past the deadline."""
    d = leases_dir(root)
    if shared and not d.is_dir():
        # A reader has nothing to read (read_all returns {} for a missing directory) and never makes the
        # directory: its absence means the upgrade's first step has not run (plan 5 Decision 13). Every write
        # under state/leases/ takes the exclusive lock, which does make it.
        yield
        return
    d.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(d / ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
    mode = fcntl.LOCK_SH if shared else fcntl.LOCK_EX
    try:
        if deadline is None:
            fcntl.flock(fd, mode)
        else:
            while True:
                try:
                    fcntl.flock(fd, mode | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.time() >= deadline:
                        raise Refused(busy)
                    time.sleep(0.05)
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def valid_id(nn: object) -> bool:
    return isinstance(nn, str) and LEASE_RE.fullmatch(nn) is not None and nn != NEVER_ISSUED


def valid_alias(alias: object, root: Optional[Path] = None) -> bool:
    if not isinstance(alias, str) or ALIAS_RE.fullmatch(alias) is None:
        return False
    deny = set(ALIAS_DENY)
    if root is not None:
        deny.add(v.target_branch(root))
    return alias not in deny


def lease_path(root: Path, nn: str) -> Path:
    return leases_dir(root) / ("%s.json" % nn)


def _unreadable(nn: str, reason: str) -> Refused:
    what = "The prime file (state/leases/prime.json)" if nn == "prime" else "The lease file for window %s" % nn
    return Refused("%s cannot be read (%s). Fix it or run `core/lease.sh sweep` before building." % (what, reason))


def read_lease(root: Path, nn: str) -> Optional[dict]:
    """None only when the file does not exist. A file that exists but cannot
    be opened or parsed, or is not a JSON object, raises Refused: treating it
    as absent would resolve its holder (and every unbound session) to the
    prime's checkout with exit 0 — the fail-open §4.4 exists to prevent."""
    try:
        text = lease_path(root, nn).read_text()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise _unreadable(nn, e.strerror or str(e))
    if text == "":
        # an empty file is a number reserved by a build that created the file before writing it, cut off in
        # between: it never held a session (release-candidate review 3, finding 7). read_all removes it.
        return None
    try:
        d = json.loads(text)
    except ValueError as e:
        raise _unreadable(nn, "not valid JSON: %s" % e)
    if not isinstance(d, dict):
        raise _unreadable(nn, "not a JSON object")
    return d


def read_all(root: Path, prune_empty: bool = True, errors: Optional[list] = None) -> Dict[str, dict]:
    """Every lease file, keyed by number ('prime' for prime.json). Caller holds
    the lock. Raises Refused on the first file that exists but cannot be read.

    prune_empty=False leaves an empty <NN>.json where it is and treats it as
    absent: the unlink is a write, and `board-json` reads under the shared lock
    every 2 s in every window (lease-board spec §3.2). Every other caller keeps
    the default. errors: when a list, a file that cannot be read is appended to
    it as its Refused and the pass goes on, instead of raising on the first —
    the band must list the windows whose files are fine beside the one that is
    not; a hook or command that fails closed on one bad file keeps the default."""
    out: Dict[str, dict] = {}
    d = leases_dir(root)
    if not d.is_dir():
        return out
    for p in sorted(d.glob("*.json")):
        key = p.stem
        if key != "prime" and not valid_id(key):
            continue
        if prune_empty:
            try:
                if p.stat().st_size == 0:
                    # an interrupted reservation (read_lease): every later start, sweep and board refused on it
                    # before, and the sentence's own remedy refused the same (release-candidate review 3, finding 7)
                    p.unlink()
                    continue
            except OSError:
                pass
        try:
            data = read_lease(root, key)
        except Refused as e:
            if errors is None:
                raise
            errors.append(e)
            continue
        if data is not None:
            out[key] = data
    return out


def write_lease(root: Path, nn: str, data: dict, exclusive: bool = False) -> None:
    """The content is written to a temporary file first, then lands in one
    step: os.replace, or with exclusive=True os.link onto the final path, which
    raises FileExistsError when another allocator took the number. The
    reservation and its content are one step: an exclusive create followed by
    the replace left an empty <NN>.json when a start was cut off between them,
    and every later start, the board and sweep refused on it
    (release-candidate review 3, finding 7)."""
    d = leases_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    final = lease_path(root, nn)
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".lease-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh, indent=2)
        if exclusive:
            os.link(tmp, str(final))       # raises FileExistsError
        else:
            os.replace(tmp, str(final))
            tmp = ""
    finally:
        if tmp:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def heartbeat(root: Path, nn: str) -> None:
    p = leases_dir(root) / ("%s.seen" % nn)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(str(p), "a"):
        pass
    os.utime(str(p), None)


def seen_mtime(root: Path, nn: str) -> Optional[float]:
    try:
        return (leases_dir(root) / ("%s.seen" % nn)).stat().st_mtime
    except OSError:
        return None


def read_changed(root: Path, nn: str) -> dict:
    try:
        d = json.loads((leases_dir(root) / ("%s.changed" % nn)).read_text())
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def write_changed(root: Path, nn: str, changed: dict) -> None:
    d = leases_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".changed-", suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(changed, fh)
    os.replace(tmp, str(d / ("%s.changed" % nn)))


# --- Session identity (§4.2, §4.4 step 1) -----------------------------------

def registry_dir() -> Path:
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")) / "sessions"


def registry_by_pid(pid: object) -> Optional[dict]:
    try:
        d = json.loads((registry_dir() / ("%s.json" % pid)).read_text())
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def session_id_from_env() -> Optional[str]:
    """Scripts: DAEDALUS_SESSION_ID (a hook exported it), else the Bash tool's
    CLAUDE_CODE_SESSION_ID, else CLAUDE_PID -> registry sessionId. None means
    an operator shell. Hooks never reach the CLAUDE_PID leg: they export the
    payload's session_id first (§4.2)."""
    for var in ("DAEDALUS_SESSION_ID", "CLAUDE_CODE_SESSION_ID"):
        val = os.environ.get(var, "").strip()
        if val:
            return val
    pid = os.environ.get("CLAUDE_PID", "").strip()
    if pid:
        entry = registry_by_pid(pid)
        if entry and entry.get("sessionId"):
            return str(entry["sessionId"])
    return None


def lease_of_session(leases: Dict[str, dict], sid: str) -> Tuple[Optional[str], Optional[dict]]:
    for nn in sorted(k for k in leases if k != "prime"):
        if leases[nn].get("session_id") == sid:
            return nn, leases[nn]
    return None, None


# --- Resolution (§4.4 steps 2–4) --------------------------------------------

def _override(root: Path) -> Optional[Path]:
    ov = os.environ.get("DAEDALUS_TARGET_OVERRIDE", "").strip()
    if not ov:
        return None
    p = Path(ov).resolve()
    try:
        p.relative_to((root / "state" / "promote").resolve())
    except ValueError:
        raise Refused("`DAEDALUS_TARGET_OVERRIDE` must point under state/promote/; got %s" % ov)
    return p


def bad_hint_sentence(hint: str) -> str:
    return "`DAEDALUS_LEASE=%s` is not a window number (two digits, 01–99)" % hint


_VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def pending_version(root: Path) -> Optional[str]:
    """The release waiting for the next session start — VERSION reads X.Y.Z and state/upgraded-to (trimmed) is
    not it (lib.sh upgrade_pending, session-start.py upgrade_pending: the same rule) — or None. Read where
    resolve_lease is called with a root in hand; resolve_lease itself stays pure. Reads the two files directly
    and never imports upgrade.py: resolve runs on every target_path, and a home at its VERSION must not load the
    module (test_session_start "a stub that records its import stays silent")."""
    try:
        ver = (root / "VERSION").read_text().split("\n", 1)[0].strip()
    except OSError:
        return None
    if not _VERSION_RE.fullmatch(ver):
        return None
    try:
        done = (root / "state" / "upgraded-to").read_text().strip()
    except OSError:
        done = ""
    return ver if done != ver else None


def _read_record(path: Path) -> Optional[dict]:
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def _bg_running(root: Path) -> bool:
    """upgrade._bg_running: state/upgrade-background.json names a live `upgrade.py --background`."""
    rec = _read_record(root / "state" / "upgrade-background.json")
    if not rec or not rec.get("running"):
        return False
    try:
        pid = int(rec.get("pid"))
        os.kill(pid, 0)
    except (TypeError, ValueError, OSError):
        return False
    code, out, _ = v.run(["ps", "-o", "command=", "-p", str(pid)], timeout=5)
    return code == 0 and "upgrade.py" in out and "--background" in out


def pending_stop(root: Path) -> Optional[Tuple[str, str, str]]:
    """While the upgrade is pending (pending_version): (version, kind, sentence), else None. The sentence is
    upgrade.pending_line's, read by the same rules from state/upgrade-stopped.json and state/upgrade-background.json
    without importing upgrade.py; kind says which no-window sentence a session gets (no_window_pending):
    'stopped' (a recorded stop, or a run in the background that ended without its copy), 'running' (that run is
    going), or 'restart' (not run yet, or the copy taken in the background: the next start finishes it)."""
    ver = pending_version(root)
    if ver is None:
        return None
    rec = _read_record(root / "state" / "upgrade-stopped.json")
    if not (rec and rec.get("version") == ver and isinstance(rec.get("sentence"), str)):
        return ver, "restart", UPGRADE_NOT_RUN % ver
    if not rec.get("background"):
        return ver, "stopped", rec["sentence"]
    if _bg_running(root):
        return ver, "running", rec["sentence"]
    bg = _read_record(root / "state" / "upgrade-background.json") or {}
    if bg.get("copied") and bg.get("version") == ver:
        return ver, "restart", SNAP_BG_COPIED % ver
    return ver, "stopped", SNAP_BG_GONE % ver


# What every no-window sentence of a pending upgrade ends with: the close that works for a session holding no window.
# True whether or not it holds the pen yet, so the Stop's once-only comparison does not re-block when the pen moves.
WINDOWLESS_CLOSE = ("At its close, `core/lease.sh log` prints this session's log path; when no live session holds "
                    "the pen, `core/lease.sh prime take` gives it the pen, for `core/vault-commit.sh`.")


def no_window_pending(pending) -> str:
    """The no-window sentence while the upgrade is pending: `pending` is pending_stop's triple, or (older callers)
    the version alone, which reads as not run yet. Each kind ends with WINDOWLESS_CLOSE."""
    if isinstance(pending, str):
        return NO_WINDOW_PENDING % pending + " " + WINDOWLESS_CLOSE
    ver, kind, sentence = pending
    if kind == "running":
        return NO_WINDOW_RUNNING % ver + " " + WINDOWLESS_CLOSE
    if kind != "stopped":
        return NO_WINDOW_PENDING % ver + " " + WINDOWLESS_CLOSE
    body = re.sub(r"^upgrade to \S+ incomplete: ", "", sentence).strip().rstrip(".")
    return NO_WINDOW_STOPPED % (ver, body + ".") + " " + WINDOWLESS_CLOSE


def pen_without_tree(leases: Dict[str, dict], sid: Optional[str], pending=None) -> bool:
    """The pen gives this session the vault, not a tree: it holds the pen and no
    numbered lease, and either the upgrade is pending (`pending`, as
    resolve_lease takes it — the safety copy protects target/) or it took the
    pen without a window (prime.json's taken_without_window) and has not
    claimed one since. Pure over the lease read. A session that kept the pen
    after releasing its window, once nothing is pending, is not one: it builds
    in target/<name> as before."""
    prime = leases.get("prime") or {}
    if not sid or prime.get("session_id") != sid or lease_of_session(leases, sid)[0] is not None:
        return False
    return bool(pending) or prime.get("taken_without_window") == sid


PEN_NO_TREE = ("This session holds no window: no lease names it. It holds the pen: `core/vault-commit.sh` is "
               "its; to build, run `core/lease.sh create` and then `claim <NN>`.")


def resolve_lease(leases: Dict[str, dict], sid: str,
                  pending=None) -> Tuple[Optional[str], Optional[dict]]:
    """§4.4 steps 2–3 over an already-read lease dict. Pure: no I/O, no lock.
    (nn, lease) when the session is bound; (None, None) when no lease file
    exists or the session holds only the pen; Refused for every case that
    must fail closed. The PreToolUse hooks call this on lease_context's read.
    `pending` (pending_stop, or pending_version's string): the no-window
    refusal names the upgrade — its recorded stop when it stopped — instead of
    create/claim, which are refused until it finishes."""
    if not leases:
        return None, None
    numbered = {k: d for k, d in leases.items() if k != "prime"}
    nn, lease = lease_of_session(leases, sid)
    hint = os.environ.get("DAEDALUS_LEASE", "").strip()
    if hint:
        if not valid_id(hint):
            # Refused by name: 'prime', an alias, or a path in this position
            # must never reach read_lease (state/leases/<hint>.json) — Task 6 review.
            raise Refused(bad_hint_sentence(hint) + ". Unset the variable, or set it to the number `core/lease.sh "
                          "create` printed.")
        # A bound session's own lease file outranks the hint, whether the
        # hinted file exists or not: telling window 02 to "claim 03" because
        # 03 is missing would be the wrong remedy. Only an unbound session
        # gets the missing-file sentence.
        if nn is not None and hint != nn:
            raise Refused("`DAEDALUS_LEASE=%s` but this session is window %s (the lease files are the truth). "
                          "Unset the variable or run `core/lease.sh claim`." % (hint, nn))
        if hint not in numbered:
            raise Refused("The lease file for window %s is gone (swept?). Run `core/lease.sh claim %s` to re-create "
                          "the binding, or `create` for a new number." % (hint, hint))
    if lease is not None:
        if lease.get("worktree_ready") is False:
            raise Refused("window %s's worktree was not finished at start; run `core/lease.sh claim %s` to finish it" % (nn, nn))
        return nn, lease
    holds_pen = leases.get("prime", {}).get("session_id") == sid
    if holds_pen and not pen_without_tree(leases, sid, pending):
        return None, None
    # Said whenever a session holds no window while lease files exist — whatever
    # the number of live sessions. The old sentence blamed "several sessions";
    # the window of 2026-10-10 repeated that to the operator as its cause (§4.4).
    if pending:
        raise Refused(no_window_pending(pending))
    if holds_pen:
        raise Refused(PEN_NO_TREE)
    raise Refused("This session holds no window: no lease names it and it does not hold the pen. "
                  "Run `core/lease.sh create` and then `claim <NN>`.")


def resolve(root: Path, sid: Optional[str], name: str) -> Path:
    """The tree a session builds in. Raises Refused for every case that must
    fail closed; an operator shell (sid None) always gets target/<name>.
    Takes LOCK_SH for one read — never call it while the lock is held."""
    ov = _override(root)
    if ov is not None:
        return ov
    default = root / "target" / name
    with lock(root, shared=True):
        try:
            leases = read_all(root)
        except Refused as e:
            if sid is not None:
                raise
            # An operator shell is not a session and always gets the prime's
            # checkout; the live-window count is a courtesy, so say why it is missing.
            sys.stderr.write("daedalus: no session — using the prime's checkout target/%s (%s)\n" % (name, e))
            return default
    if sid is None:
        live = sum(1 for k, d in leases.items() if k != "prime" and not d.get("released"))
        sys.stderr.write("daedalus: no session — using the prime's checkout target/%s (%d window%s live)\n"
                         % (name, live, "" if live == 1 else "s"))
        return default
    nn, lease = resolve_lease(leases, sid, pending_stop(root))
    if lease is None:
        return default
    return root / str(lease.get("worktree") or ("worktrees/%s" % nn)) / name


# --- Liveness (§4.5) ---------------------------------------------------------

def registry_present() -> bool:
    return registry_dir().is_dir()


def registry_by_session(sid: str) -> list:
    """Every sessions/*.json whose sessionId is sid — a resumed session has a
    new pid and a new file, so the lookup is by session id, never by pid."""
    out = []
    d = registry_dir()
    if not d.is_dir():
        return out
    for p in d.glob("*.json"):
        try:
            e = json.loads(p.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(e, dict) and e.get("sessionId") == sid:
            out.append(e)
    return out


def registry_live_entries(sid: str) -> list:
    """The registry entries for sid whose pid is still the process that wrote
    them (startedAt against ps, the same check a lease's pid gets). This is
    what 'a live registry entry' means everywhere — liveness, sweep, the
    two-terminals refusal, the board — never pid_alive alone: a crashed
    session leaves its sessions/<pid>.json behind, and a pid-only check would
    call that entry live as soon as any long-lived process reused the pid,
    making a dead lease read "resumed" and therefore never sweepable."""
    return [e for e in registry_by_session(sid)
            if pid_is_recorded_process(e.get("pid"), e.get("startedAt"), e.get("procStart"))]


def is_interactive_window(entry: Optional[dict]) -> bool:
    """§4.8: a terminal a person sits at is kind=interactive AND entrypoint=cli
    (claude -p registers interactive/sdk-cli; --bg registers bg/cli)."""
    return bool(entry) and entry.get("kind") == "interactive" and entry.get("entrypoint") == "cli"


def pid_alive(pid: object) -> bool:
    """A process that exists. kill(pid, 0) raises PermissionError for another
    user's process (pid 1, root) — that process EXISTS; only ESRCH is dead.
    Reporting EPERM as dead would make a live lease sweepable."""
    try:
        os.kill(int(pid), 0)
        return True
    except PermissionError:
        return True
    except (OSError, TypeError, ValueError):
        return False


def proc_started_of(pid: object) -> Optional[int]:
    """Epoch milliseconds of the process start, from `ps -o lstart=` run with
    TZ=UTC and read with calendar.timegm. ps prints a zone-less local stamp;
    read in the local zone through time.mktime, the stamp of a process started
    in the hour the clocks fall back (01:00–02:00 CST on 2026-11-01) is
    ambiguous and mktime guesses an hour off, so for that hour every live
    session read dead (review of 2026-10-11, finding 2). In UTC there is no
    ambiguous hour. The registry's procStart string is UTC too; strings are
    never compared (§4.5)."""
    try:
        # TZ in the child's environment, not an `env` in front: one process per
        # lease (the board does one of these per lease on every prompt).
        pr = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=5,
                            env=dict(os.environ, TZ="UTC"))
    except (OSError, subprocess.SubprocessError):
        return None
    out = pr.stdout.strip()
    if pr.returncode != 0 or not out:
        return None
    try:
        return int(calendar.timegm(time.strptime(out, "%a %b %d %H:%M:%S %Y")) * 1000)
    except ValueError:
        return None


# How long after its process started a registry entry may have been written and
# still be that process's record. startedAt is NOT the process start: it is the
# moment Claude Code finished starting and wrote sessions/<pid>.json — 936 ms
# after the process on 2.1.282, 2.07 s and 3.0 s on 2.1.295/296 on the first
# starts after an OS restart (2026-10-10). A 2 s window called both of those
# sessions dead: not terminal windows, so no number, no first-up, and the pen
# stayed with a session that had ended. The lag has no upper bound in
# principle (a cold start), so the ceiling is generous. It costs nothing in
# recycling safety: the original process held the pid when the record was
# written, so a recycler starts after it and fails the lower bound; the only
# exposure is ps's one-second resolution (−2 s), the same as before. procStart,
# when the entry has it, decides exactly (proc_start_text_ms).
REGISTRY_LAG_MS = 60000


def proc_start_text_ms(text: object) -> Optional[int]:
    """The registry's procStart (and a lease's proc_start, copied from it at
    bind): the process start as Claude Code records it, a UTC string in ps's
    lstart layout ("Sat Oct 10 14:48:45 2026" for a process ps shows as
    09:48:45 CDT — spec §4.5: never compare the strings). Epoch ms, None when
    absent or not in that layout."""
    if not isinstance(text, str) or not text.strip():
        return None
    try:
        return int(calendar.timegm(time.strptime(text.strip(), "%a %b %d %H:%M:%S %Y")) * 1000)
    except ValueError:
        return None


def pid_is_recorded_process(pid: object, proc_started: object, proc_start: object = None) -> bool:
    """The pid is alive AND is the process the record was made for, or — when
    ps cannot be parsed — its command is claude. The record is a lease's (pid,
    proc_started, proc_start) or a registry entry's (pid, startedAt, procStart).
    With proc_start (the process start, UTC text): its second must be the one
    ps reports, ±2 s for ps's one-second resolution. Without it: the record
    (startedAt) must have been written AFTER the process started — never
    before, that pid was recycled after the write — and within REGISTRY_LAG_MS
    of it. A left-behind sessions/<pid>.json whose pid another process now
    holds fails either test."""
    if not pid_alive(pid):
        return False
    started = proc_started_of(pid)
    if started is None:
        code, out, _ = v.run(["ps", "-o", "comm=", "-p", str(pid)], timeout=5)
        return code == 0 and out.strip().endswith("claude")
    exact = proc_start_text_ms(proc_start)
    if exact is not None:
        return abs(int(started) - exact) <= 2000
    try:
        lag = int(proc_started) - int(started)
    except (TypeError, ValueError):
        return False
    return -2000 <= lag <= REGISTRY_LAG_MS


_STALE_AFTER: Dict[str, int] = {}


def stale_after_secs(root: Path) -> int:
    """config leases.stale_after: an integer with an m, h or d suffix; default
    4h; anything else is the default plus a stderr note. Memoized per process
    keyed on root: one bash spawn per hook or board render, not one per lease."""
    key = str(root)
    if key in _STALE_AFTER:
        return _STALE_AFTER[key]
    raw = v._lib(root, "cfg leases.stale_after 2>/dev/null || true").strip()
    secs = 4 * 3600
    if raw:
        m = re.fullmatch(r"([0-9]+)([mhd])", raw)
        if m:
            secs = int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]
        else:
            sys.stderr.write("daedalus: config leases.stale_after must be an integer with an m, h or d suffix "
                             "(got: %s); using 4h\n" % raw)
    _STALE_AFTER[key] = secs
    return secs


def liveness(root: Path, nn: str, lease: dict, now: Optional[float] = None, quiet_after: Optional[int] = None) -> str:
    """live | quiet | stale | resumed (dead recorded pid, same session id live
    in the registry under another pid — §4.2 'A resumed session'). Callers
    that walk every lease compute now and quiet_after once and pass them in."""
    now = time.time() if now is None else now
    hb = seen_mtime(root, nn)
    quiet_after = stale_after_secs(root) if quiet_after is None else quiet_after
    pid = lease.get("pid")
    if pid is None:
        # registry-absent build, or never bound: heartbeat alone (§4.5)
        if hb is None or now - hb > quiet_after:
            return "stale"
        return "live"
    if pid_is_recorded_process(pid, lease.get("proc_started"), lease.get("proc_start")):
        return "quiet" if (hb is not None and now - hb > quiet_after) else "live"
    sid = lease.get("session_id")
    if sid and registry_live_entries(str(sid)):
        return "resumed"
    return "stale"


# --- Allocation (§4.2) --------------------------------------------------------

_TARGET_NAME: Dict[str, str] = {}


def target_name(root: Path) -> str:
    """The checkout's directory name from config alone (lib.sh target_name),
    cached per process. NEVER target_path: that consults the leases and fails
    closed for the session being numbered (and would take LOCK_SH from a child
    process while the allocator holds LOCK_EX).

    Fails CLOSED (§4.4): an empty name would make target/ + "" the product's
    own tree, and git would cut worktrees/NN from it and report success. So
    lib.sh's exit code and stderr are kept, not swallowed through v._lib: a
    die there (an invalid target.dir) is re-raised with its own sentence, and
    no answer at all (timeout, no lib.sh) is a refusal too."""
    key = str(root)
    if key not in _TARGET_NAME:
        lib = root / "core" / "lib.sh"
        silent = Refused("could not read the target's name from config (lib.sh target_name did not answer)")
        if not lib.is_file():
            raise silent
        code, out, err = v.run(["bash", "-c", 'source "$1"; target_name', "_", str(lib)], timeout=5)
        name = out.strip()
        if code == 127 and not err.strip().startswith("daedalus:"):
            raise silent           # v.run's code for a timeout or an OS failure
        if code != 0:
            last = [ln for ln in err.strip().splitlines() if ln.strip()][-1:]
            if last:
                msg = last[0]
                raise Refused(msg[len("daedalus: "):] if msg.startswith("daedalus: ") else msg)
            raise silent
        if not name or "/" in name or name in (".", ".."):
            raise silent
        _TARGET_NAME[key] = name
    return _TARGET_NAME[key]


def repos_of(root: Path) -> list:
    """['<name>', '<name>/<nested rel>', ...] — the main repo and each nested
    repo at its mirrored relative path (config target.nested)."""
    name = target_name(root)
    return [name] + ["%s/%s" % (name, rel) for rel in v.nested_relpaths(root)]


def trunks_of(root: Path, target_base: Path) -> Dict[str, str]:
    """repo -> trunk branch. The main repo's trunk is config target.branch; a
    nested repo's is its origin/HEAD, and a nested repo without one fails
    closed (cutting its lease branch from a guessed trunk is worse than a
    refusal that names the remedy)."""
    trunk = v.target_branch(root)
    return {repo: trunk_of(target_base, repo, trunk) for repo in repos_of(root)}


def trunk_of(target_base: Path, repo: str, outer_trunk: str) -> str:
    """One repo's trunk, as trunks_of tells it: outer_trunk (config target.branch)
    for the main repo, origin/HEAD for a nested one; Refused when it cannot be told
    or origin/<trunk> does not resolve. Per repo, so a reader that must name every
    problem (doctor) can skip only the repo that fails."""
    if "/" not in repo:
        out = outer_trunk
    else:
        code, head, _ = v.run(["git", "-C", str(target_base / repo), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        head = head.strip()
        if code != 0 or not head.startswith("origin/"):
            raise Refused("nested repo %s has no origin/HEAD — run git -C target/%s remote set-head origin -a"
                          % (repo.split("/", 1)[1], repo))
        out = head[len("origin/"):]
    require_trunk_ref(target_base / repo, repo, out)
    return out


def remote_ref(trunk: str) -> str:
    """origin/<trunk> as a revision git cannot mistake: a local branch named origin/<trunk> (refs/heads/origin/main)
    shadows the bare name — git resolves refs/heads/ before refs/remotes/ and `worktree add` calls it ambiguous
    (release-candidate review 2, finding 5)."""
    return "refs/remotes/origin/" + trunk


def require_trunk_ref(target_repo: Path, repo: str, trunk: str) -> None:
    """origin/<trunk> must resolve before any number is judged or cut. Without
    it, `merge-base --is-ancestor` exits 128 and `git log origin/x..lease/NN`
    prints nothing — which read as "nothing waiting", and a swept window's
    unpromoted commits were silently adopted by the next session (§4.2)."""
    code, _, _ = v.run(["git", "-C", str(target_repo), "rev-parse", "--verify", "-q", remote_ref(trunk)])
    if code != 0:
        raise Refused(TRUNK_REF_MISSING % (repo, trunk, repo))


TRUNK_REF_MISSING = "target/%s has no origin/%s — check config target.branch, or run git -C target/%s fetch origin"


def waiting_work(target_repo: Path, trunk: str, nn: str, timeout: int = 20) -> list:
    """Subjects of commits on lease/<NN> that origin/<trunk> does not contain;
    [] when there are none or the branch is absent (§4.2 'Numbering').
    `timeout` bounds each git call (reclaim passes what the start has left)."""
    branch = "lease/%s" % nn
    code, _, _ = v.run(["git", "-C", str(target_repo), "rev-parse", "--verify", "-q", "refs/heads/" + branch],
                       timeout=timeout)
    if code != 0:
        return []
    code, _, err = v.run(["git", "-C", str(target_repo), "merge-base", "--is-ancestor", "refs/heads/" + branch,
                          remote_ref(trunk)], timeout=timeout)
    if code == 0:
        return []
    if code != 1:
        # 128 (a missing ref) and everything else is an ANSWER WE DO NOT HAVE,
        # never "not an ancestor" and never "nothing waiting".
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot tell whether %s has unpromoted work in %s (git merge-base against origin/%s failed: %s)"
                      % (branch, target_repo.name, trunk, last[0]))
    code, out, err = v.run(["git", "-C", str(target_repo), "log", LOG_RECORD,
                            "%s..refs/heads/%s" % (remote_ref(trunk), branch)], timeout=timeout)
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot list %s's unpromoted work in %s (git log origin/%s..%s failed: %s)"
                      % (branch, target_repo.name, trunk, branch, last[0]))
    return log_subjects(out)


# One record per commit: the SHA, a tab, the subject. Records are counted, never subject lines: `--format=%s` prints
# an empty line for a commit made with --allow-empty-message, and a filter on blank lines read that commit as
# "nothing waiting" — free_number handed its number out over it and reclaim removed its lease (v0.7.5 review, R1).
LOG_RECORD = "--format=%H%x09%s"
NO_SUBJECT = "(no subject)"


def log_subjects(out: str) -> list:
    """The subjects of `git log LOG_RECORD` output, one per record; an empty subject is NO_SUBJECT."""
    subs = []
    for ln in out.splitlines():
        sha, tab, subj = ln.partition("\t")
        if tab and sha.strip():
            subs.append(subj if subj.strip() else NO_SUBJECT)
    return subs


# --- The board's check path (v0.7.5) -----------------------------------------
# Every git call here is told apart as an answer, an error or a cut-off (by the exception, never by stderr text), and
# runs at SHAs once the tips are listed, so a ref moving in between can never mix two tips into one answer.

MIN_CALL_SECS = 0.2      # fewer seconds left than this before a deadline: no git call is started
RECOMPUTE_SHARE = 0.5    # at a prompt: the most of what is left of the check deadline the reader's changed set may use


def _left_f(deadline: Optional[float], cap: float) -> float:
    """Seconds (a float) the next git call may take: `cap`, or what is left before `deadline` when that comes
    sooner; 0.0 = no time left. _left gives whole seconds to the callers that want them."""
    if deadline is None:
        return cap
    return max(0.0, min(cap, deadline - time.time()))


def _git_t(repo: Path, *args: str, timeout: float) -> Tuple[int, str, str, bool]:
    """(code, stdout, stderr, timed_out). v.run folds a timeout and a missing git into one 127, so a cut-off could not
    be told from an error (v0.7.5 review, R8); here it is the exception that says so."""
    try:
        r = subprocess.run(git_argv(repo, *args), capture_output=True, text=True, errors="replace",
                           timeout=max(timeout, 0.01))
        return r.returncode, r.stdout, r.stderr, False
    except subprocess.TimeoutExpired:
        return 127, "", "cut off", True
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", str(e), False


def _last_line(err: str) -> str:
    return (err.strip().splitlines() or ["no output"])[-1]


class CheckCut(Refused):
    """A git call on the check path cut off by its deadline."""


class ListFailed(Refused):
    """A repo's tip listing failed (not a cut-off); the message is the reason."""


_LEASE_REF = re.compile(r"refs/heads/lease/([0-9]{2})")
ORIGIN_HEAD = "refs/remotes/origin/HEAD"


def _common_git_dir(target: Path) -> Optional[Path]:
    """A repo's common git dir, read without git (gitrepository-layout): target/.git when it is a directory; when it
    is a gitfile, the gitdir: it names, then that directory's commondir file if present. None when it cannot be read."""
    g = target / ".git"
    try:
        if g.is_dir():
            gd = g
        elif g.is_file():
            txt = g.read_text().strip()
            if not txt.startswith("gitdir:"):
                return None
            gd = Path(txt[len("gitdir:"):].strip())
            gd = gd if gd.is_absolute() else target / gd
        else:
            return None
        cd = gd / "commondir"
        if cd.is_file():
            c = Path(cd.read_text().strip())
            gd = c if c.is_absolute() else gd / c
        return gd if gd.is_dir() else None
    except (OSError, ValueError):
        return None


def history_view(target: Path, replace: list) -> Optional[str]:
    """The repo's view of history beyond the SHAs (spec §3.1): its refs/replace/ refs, and the size and mtime of
    info/grafts and shallow in the common git dir. Any change misses every cached answer of the repo. None when the
    layout cannot be read: nothing is cached for that repo, it is always checked live."""
    gd = _common_git_dir(target)
    if gd is None:
        return None
    h = hashlib.sha256()
    for line in sorted(replace):
        h.update((line + "\n").encode())
    for name in ("info/grafts", "shallow"):
        try:
            st = os.stat(str(gd / name))
            h.update(("%s %d %d\n" % (name, st.st_size, st.st_mtime_ns)).encode())
        except FileNotFoundError:
            h.update(("%s 0 0\n" % name).encode())
        except OSError:
            return None
    return h.hexdigest()[:20]


def _resolve_tips(target: Path, repo: str, trunk: Optional[str], timeout: float = 20) -> Optional[dict]:
    """One `git for-each-ref` for a repo: every lease/<NN> tip, the trunk's tip, and the replace refs (for
    history_view). `trunk` None: a nested repo's trunk is origin/HEAD's target, as trunk_of tells it, and a missing
    or dangling origin/HEAD (git does not list a broken symref) returns None — the repo is skipped. Lines are
    matched by exact refname. {"trunk", "trunk_sha" (None when origin/<trunk> is absent), "tips": {NN: sha},
    "view"}. Raises CheckCut when cut off, ListFailed when the listing fails: an answer we do not have is never
    "no swept windows" (v0.7.5 review, R4)."""
    pats = ["refs/heads/lease/", "refs/replace/"] + ([remote_ref(trunk)] if trunk else [ORIGIN_HEAD])
    code, out, err, cut = _git_t(target, "for-each-ref", "--format=%(objectname) %(refname) %(symref)", *pats,
                                 timeout=timeout)
    if cut:
        raise CheckCut("cut off")
    if code != 0:
        raise ListFailed("git for-each-ref failed: %s" % _last_line(err))
    tips: Dict[str, str] = {}
    replace, trunk_sha, head = [], None, None
    for ln in out.splitlines():
        parts = ln.split(" ")
        if len(parts) < 2:
            continue
        sha, ref, sym = parts[0], parts[1], (parts[2] if len(parts) > 2 else "")
        m = _LEASE_REF.fullmatch(ref)
        if m:
            if valid_id(m.group(1)):
                tips[m.group(1)] = sha
        elif ref.startswith("refs/replace/"):
            replace.append("%s %s" % (ref, sha))
        elif trunk and ref == remote_ref(trunk):
            trunk_sha = sha
        elif not trunk and ref == ORIGIN_HEAD:
            head = (sym, sha)
    if not trunk:
        if not head or not head[0].startswith("refs/remotes/origin/"):
            return None
        trunk, trunk_sha = head[0][len("refs/remotes/origin/"):], head[1]
    return {"trunk": trunk, "trunk_sha": trunk_sha, "tips": tips, "view": history_view(target, replace)}


def _log_at(target: Path, trunk_sha: str, tip_sha: str, timeout: float) -> Tuple[int, list, str, bool]:
    """The commits on tip_sha that trunk_sha does not contain, at SHAs: (code, subjects, stderr, timed_out).
    No record = contained (the same predicate as merge-base --is-ancestor, spec §2.2)."""
    code, out, err, cut = _git_t(target, "log", LOG_RECORD, "%s..%s" % (trunk_sha, tip_sha), timeout=timeout)
    return code, (log_subjects(out) if code == 0 and not cut else []), err, cut


def waiting_work_at(target: Path, trunk_sha: str, tip_sha: str, timeout: float = 20) -> list:
    """waiting_work at SHAs resolved beforehand (_resolve_tips): a commit landing in between cannot be judged under
    the old tip's name. Refused on any failure: cannot tell is never "nothing"."""
    code, subs, err, cut = _log_at(target, trunk_sha, tip_sha, timeout)
    if cut or code != 0:
        raise Refused("cannot list unpromoted work in %s (git log %s..%s failed: %s)"
                      % (target.name, trunk_sha[:12], tip_sha[:12], "cut off" if cut else _last_line(err)))
    return subs


def free_number(root: Path, leases: Dict[str, dict], target_base: Path, trunks: Dict[str, str],
                skipped: Optional[list] = None) -> str:
    """The lowest number 01–99 that no lease file holds and no swept lease's
    unpromoted work is waiting under, and whose worktrees/<NN> is not another
    branch's checkout (_foreign_numbers). Caller holds the lock. `skipped`,
    when given, receives (nn, why) for each lower number passed over whose
    reason the band would not show as an open window — a lease that is
    released, finished or stale, unpromoted work, a foreign checkout — so the
    start can say why the number is not lower (reported 2026-10-19: a new
    terminal was 05 with no 02 or 03 on the band). An open window (live,
    quiet, resumed) is left out: the band already shows it."""
    foreign = _foreign_numbers(root, trunks)
    for i in range(1, 100):
        nn = "%02d" % i
        if nn in leases:
            if skipped is not None:
                why = _held_why(root, nn, leases[nn])
                if why:
                    skipped.append((nn, why))
            continue
        if nn in foreign:
            if skipped is not None:
                skipped.append((nn, FOREIGN_WHY % (nn, foreign[nn])))
            continue
        hit = next((repo for repo in trunks if waiting_work(target_base / repo, trunks[repo], nn)), None)
        if hit is not None:
            if skipped is not None:
                skipped.append((nn, "has unpromoted commits on lease/%s%s"
                                % (nn, "" if hit == target_name(root) else " in %s" % hit)))
            continue
        return nn
    raise Refused("no free window number: 01–99 are all held; run `core/lease.sh sweep`")


FOREIGN_WHY = "has worktrees/%s checked out on another branch (%s), which new windows never take over"


def _held_why(root: Path, nn: str, lease: dict) -> Optional[str]:
    """Why a lease file keeps its number from a new window, in the words of free_number's `skipped` — None for an
    open window (live, quiet, resumed), which the band shows as one."""
    if lease.get("released"):
        return "is released and its session is still open"
    if lease.get("finished"):
        return "is finished — promote %s or release %s" % (nn, nn)
    if liveness(root, nn, lease) == "stale":
        return "is stale (no live session) — say 'this is window %s' to a new window to continue it" % nn
    return None


def skipped_sentence(nn: str, skipped: list) -> Optional[str]:
    """The start's one line on why window <nn> is not a lower number (free_number's `skipped`), None when nothing
    needs saying."""
    if not skipped:
        return None
    return "Numbered %s, not a lower number: %s." % (nn, "; ".join("%s %s" % (k, why) for k, why in skipped))


# Every git command run here and by the upgrade in a target repository runs with submodule.recurse off. Set — in the
# repository or globally, as git's documentation suggests — it makes a checkout, merge, reset or worktree add rewrite
# each submodule's working tree too, over the uncommitted edits there that the dirty check leaves to the submodule on
# purpose (release-candidate red team 2, finding 1). And with core.fsmonitor off: a file-system monitor hook (set in the
# repository or globally) that reports no change made git status, git diff and the safety copy's listing pass an
# uncommitted edit, and the checkout back to the trunk trusted the index's "unchanged" marks and wrote the committed
# version over it. Off, git checks every file itself, and the checkout refuses over the edit (release-candidate red
# team 3, finding 2).
NO_RECURSE = ("-c", "submodule.recurse=false", "-c", "core.fsmonitor=false")


def git_argv(repo: Path, *args: str) -> list:
    return ["git"] + list(NO_RECURSE) + ["-C", str(repo)] + list(args)


def fetch_args(repo: Path) -> list:
    """`git fetch` of origin that changes nothing but origin's remote-tracking branches: never a tag. With the
    operator's fetch.pruneTags (or remote.origin.pruneTags, or a configured refs/tags/* refspec beside fetch.prune)
    a plain fetch deleted every local tag origin lacks — some the only ref to their commit — and a forced tag refspec
    moved them (release-candidate red team 2, finding 2). The configured refspecs that write under refs/remotes/
    are kept (a single-branch clone fetches its one branch), else git's default one."""
    _, out, _ = _git(repo, "config", "--get-all", "remote.origin.fetch")
    specs = [s.strip() for s in out.splitlines()
             if s.strip().startswith("^") or s.strip().partition(":")[2].startswith("refs/remotes/")]
    if not [s for s in specs if not s.startswith("^")]:
        specs = ["+refs/heads/*:refs/remotes/origin/*"] + specs
    return ["fetch", "--quiet", "--no-tags", "--no-prune-tags", "origin"] + specs


def fetch_origin(repo: Path, timeout: int = 120) -> Tuple[int, str, str]:
    return _git(repo, *fetch_args(repo), timeout=timeout)


def _git(repo: Path, *args: str, timeout: int = 20) -> Tuple[int, str, str]:
    return v.run(git_argv(repo, *args), timeout=timeout)


def git_finish(repo: Path, *args: str, timeout: int = 600) -> Tuple[int, str, str]:
    """A git command that rewrites a checkout — the move back to the trunk, a trunk's hard reset — run so that it is
    never killed part-way: v.run SIGKILLs git at its 20 s timeout, and an exception in the caller (SIGTERM at a hook's
    timeout is SystemExit) killed it too, mid-write, leaving the tree half switched (release-candidate review 4,
    findings 5-6). It runs in its own session with no pipe to break: past `timeout`, or when the caller is stopped, it
    is left to finish on its own. (code, "", stderr); 127 with "still running" past the timeout."""
    try:
        err_f = tempfile.TemporaryFile(mode="w+")
    except OSError as e:
        return 127, "", str(e)
    with err_f:
        try:
            pr = subprocess.Popen(git_argv(repo, *args), stdin=subprocess.DEVNULL,
                                  stdout=subprocess.DEVNULL, stderr=err_f, start_new_session=True)
        except OSError as e:
            return 127, "", str(e)
        try:
            code = pr.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return 127, "", "still running after %d s" % timeout
        err_f.seek(0)
        return code, "", err_f.read()


def ref_oid(src: Path, ref: str) -> Optional[str]:
    """The commit the ref named exactly <ref> (refs/heads/<b>) points at, from for-each-ref's listing — or None. Where
    git ignores case, `rev-parse refs/heads/Wip` opens a loose refs/heads/wip and answers for that other branch
    (release-candidate review 4, finding 1); the listing keeps the two apart."""
    # the whole of refs/heads/ (never refs/heads/Feat/): a loose directory read under a case-folded prefix comes
    # back with that prefix's spelling
    code, out, _ = _git(src, "for-each-ref", "--format=%(refname) %(objectname)", "/".join(ref.split("/")[:2]) + "/")
    for ln in (out.splitlines() if code == 0 else []):
        name, _, sha = ln.partition(" ")
        if name == ref:
            return sha.strip()
    return None


def case_twins(src: Path) -> list:
    """Groups of <src>'s local branch names that differ only in case or Unicode normalization, where git ignores
    case (core.ignorecase) or precomposes Unicode (core.precomposeunicode): this filesystem keeps one file for both,
    so git reads one branch in place of the other and deleting one deletes both (release-candidate review 4,
    finding 1). Each group sorted; [] when there are none or git tells such names apart here."""
    fold = ignores_case(src)
    code, pre, _ = _git(src, "config", "--bool", "core.precomposeunicode")
    if not fold and not (code == 0 and pre.strip() == "true"):
        return []
    code, out, _ = _git(src, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/")
    seen: Dict[str, list] = {}
    for b in (out.splitlines() if code == 0 else []):
        if b.strip():
            k = unicodedata.normalize("NFC", b)
            seen.setdefault(k.casefold() if fold else k, []).append(b)
    return sorted(sorted(g) for g in seen.values() if len(g) > 1)


def twins_words(groups: list) -> str:
    return "; ".join(", ".join(g) for g in groups)


# Only when `ps` cannot answer: an interrupted add's checkout then counts as
# possibly still writing while the worktree's index.lock is younger than this.
CHECKOUT_FRESH_SECS = 60


def _left(deadline: Optional[float], cap: int) -> int:
    """Whole seconds the next git call may take: `cap`, or what is left before
    `deadline` (epoch seconds) when that comes sooner. 0 = no time left. The
    SessionStart hook has 30 s in all (§4.2); a fixed per-add timeout let one
    outer and one nested add take 40."""
    if deadline is None:
        return cap
    return max(0, min(cap, int(deadline - time.time())))


def _kill_group(p: "subprocess.Popen") -> None:
    """SIGKILL the whole process group `p` leads (it was started in its own
    session), then reap it for at most 5 s."""
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        p.communicate(timeout=5)
    except Exception:
        pass


def _run_bounded(cmd: list, timeout: int) -> Tuple[int, str, str]:
    """v.run's contract — (code, stdout, stderr), 127 on a timeout or an OS
    failure — but the command runs in its own session and, on timeout, its
    WHOLE process group is killed. `git worktree add` checks out through a
    child (`git reset --hard --no-recurse-submodules`); v.run killed only the
    parent, and the orphan kept writing the tree after the budget was spent
    (reproduced on git 2.50.1, review of 2026-09-27). Its own session also
    takes the checkout out of the caller's process group, so a signal to the
    caller no longer reaches it: on ANY exception while waiting — Ctrl-C in a
    lease.sh shell (KeyboardInterrupt), SIGTERM (session-start.py turns it
    into SystemExit) — the group is killed too, then the exception goes on
    (plan 2 Decision 20). A SIGKILL of the caller cannot be caught; the
    interrupted-add recovery in add_worktrees cleans up after it."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             start_new_session=True)
    except OSError as e:
        return 127, "", str(e)
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out, err
    except subprocess.TimeoutExpired:
        _kill_group(p)
        return 127, "", "timed out after %d s" % timeout
    except BaseException:
        _kill_group(p)
        raise


def _git_budget(repo: Path, *args: str, timeout: int, deadline: Optional[float]):
    """One git call under the SessionStart budget: its timeout is recomputed
    from `deadline` immediately before it runs (the first draft computed it
    once per repo and reused it for four calls). None when no whole second is
    left — the caller stops, and the window is written worktree_ready: false."""
    left = _left(deadline, timeout)
    if left < 1:
        return None
    return _run_bounded(git_argv(repo, *args), left)


def _registered(listed: str, dest: Path) -> bool:
    want = "worktree " + str(dest.resolve())
    return any(ln.strip() == want for ln in listed.splitlines() if ln.startswith("worktree "))


def _interrupted_add(listed: str, dest: Path) -> bool:
    """True when `git worktree list --porcelain` shows `dest` registered and
    still locked with reason 'initializing' — an add killed mid-checkout (a
    SessionStart cut off at its budget, a killed shell). Measured 2026-09-27 on
    git 2.50.1: such a worktree has its branch and a half-written tree whose
    status lists every file deleted; adopting it hands the window a broken
    checkout."""
    want = "worktree " + str(dest.resolve())
    block: list = []
    for ln in listed.splitlines() + [""]:
        if ln.strip():
            block.append(ln.strip())
            continue
        if block and block[0] == want:
            return "locked initializing" in block
        block = []
    return False


def _add_running(dest: Path) -> Optional[bool]:
    """Whether a `git ... worktree add <dest> ...` process is alive — the
    writer of an interrupted add, since `worktree add` waits for its checkout
    child. Daedalus runs every add with `dest` as its own argument (and in its
    own session, so the add outlives a SIGKILLed caller). None when `ps`
    cannot answer."""
    code, out, _ = v.run(["ps", "-A", "-ww", "-o", "command="], timeout=5)
    if code != 0:
        return None
    wants = {" %s " % dest, " %s " % dest.resolve()}
    return any(" worktree add " in c and any(w in c + " " for w in wants) for c in out.splitlines())


def _checkout_live(dest: Path) -> bool:
    """True while an interrupted add's checkout may still be writing `dest`:
    its `git worktree add` process is alive. Removing a tree under a live
    writer failed with 'Directory not empty' after git had already
    deregistered it (review, 2026-09-27).

    Not the index.lock's age (the first draft): a checkout Daedalus cut off
    itself is SIGKILLed with its group (_run_bounded) and leaves its lock
    behind, which read as "still writing" for a minute although nothing was;
    and the lock's mtime is set when the checkout opens it and does not move
    until the index is written at the end (measured 2026-09-28, git 2.50.1),
    so an orphaned add running past 60 s read as dead under its writer. The
    lock age is only the fallback when `ps` cannot answer."""
    running = _add_running(dest)
    if running is not None:
        return running
    try:
        line = (dest / ".git").read_text().strip()
    except OSError:
        return False
    if not line.startswith("gitdir:"):
        return False
    gitdir = Path(line[len("gitdir:"):].strip())
    if not gitdir.is_absolute():
        gitdir = dest / gitdir
    try:
        return time.time() - (gitdir / "index.lock").stat().st_mtime < CHECKOUT_FRESH_SECS
    except OSError:
        return False


def _common_dir(src: Path) -> Optional[Path]:
    code, out, _ = _git(src, "rev-parse", "--git-common-dir", timeout=10)
    if code != 0 or not out.strip():
        return None
    d = Path(out.strip())
    return d if d.is_absolute() else src / d


def _under(path: str, base: Path) -> bool:
    b = os.path.realpath(str(base))
    return os.path.realpath(path).startswith(b + os.sep)


# git's files in a linked worktree's own git directory that say an operation stopped part-way there
RECORD_BUSY = ("rebase-merge", "rebase-apply", "sequencer", "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE",
               "CHERRY_PICK_HEAD", "REVERT_HEAD")


def _git_at(gd: Path, *args: str, timeout: int = 20) -> Tuple[int, str, str]:
    """git with --git-dir on <gd> — a linked worktree's own git directory (<common>/worktrees/<id>) answers for that
    worktree whether or not its directory is there."""
    return v.run(["git", "--git-dir", str(gd)] + list(args), timeout=timeout)


def worktree_records(src: Path) -> Dict[str, Path]:
    """{real path git records for the worktree: its git directory} for each linked worktree of <src>'s repository,
    read from each <common>/worktrees/<id>/gitdir — so a worktree whose directory is gone (moved with mv, an
    unmounted volume) is found too."""
    common = _common_dir(src)
    found: Dict[str, Path] = {}
    try:
        entries = sorted((common / "worktrees").iterdir()) if common is not None else []
    except OSError:
        return found
    for a in entries:
        try:
            gd = (a / "gitdir").read_text().strip()
        except OSError:
            continue
        if not os.path.isabs(gd):
            gd = os.path.normpath(os.path.join(str(a), gd))
        found[os.path.realpath(os.path.dirname(gd))] = a
    return found


def record_holds(admin: Path) -> list:
    """What git's record of a linked worktree (<common>/worktrees/<id>) holds that no branch does, in words: a
    rebase, merge, cherry-pick, revert or bisect in progress, refs of its own (refs/worktree, refs/bisect,
    refs/rewritten), staged content its HEAD lacks. Read through that record, so it answers when the worktree's
    directory is gone; deleting the record deletes all of it. [] when it holds none."""
    out = []
    try:
        names = sorted(os.listdir(str(admin)))
    except OSError:
        return out
    busy = [n for n in names if n in RECORD_BUSY or n.startswith("BISECT_")]
    if busy:
        out.append("git's record of an operation in progress (%s)" % ", ".join(busy))
    code, refs, _ = _git_at(admin, "for-each-ref", "--format=%(refname)", "refs/worktree/", "refs/bisect/",
                            "refs/rewritten/")
    if code != 0 or refs.strip():
        out.append("refs of its own (%s)" % (name_paths(refs.split()) if code == 0 else "git could not list them"))
    if (admin / "index").is_file():
        code, _, _ = _git_at(admin, "diff-index", "--cached", "--quiet", "HEAD", "--")
        if code != 0:
            out.append("staged changes its last commit does not have")
    return out


def branch_in_use(admin: Path) -> Optional[str]:
    """The branch a linked worktree is rebasing or bisecting (its HEAD detached meanwhile), read from its record:
    git counts it as checked out there, and moving or deleting it under the rebase loses the rebase's place."""
    for f in ("rebase-merge/head-name", "rebase-apply/head-name", "BISECT_START"):
        try:
            name = (admin / f).read_text().strip()
        except OSError:
            continue
        name = name[len("refs/heads/"):] if name.startswith("refs/heads/") else name
        if name and name != "detached HEAD":
            return name
    return None


def _window_record(base: Path, wt: str, admin: Path) -> bool:
    """Is the worktree recorded at <wt> under worktrees/ (<base>) a window's: worktrees/<NN>/... with a lease file
    for <NN>, or its HEAD on lease/<NN>?"""
    rel = os.path.relpath(os.path.realpath(wt), os.path.realpath(str(base)))
    nn = rel.split(os.sep, 1)[0]
    if not valid_id(nn):
        return False
    if lease_path(base.parent, nn).exists():
        return True
    try:
        return (admin / "HEAD").read_text().strip() == "ref: refs/heads/lease/" + nn
    except OSError:
        return False


def prune_under(src: Path, base: Path, force: Optional[Path] = None) -> list:
    """`git worktree prune` for the worktrees under <base> only (worktrees/, or
    promote's scratch): the record of one whose directory is gone is removed,
    as git's prune would. A worktree of target/<repo> made anywhere else is the
    operator's and is never touched: a plain prune removed the record of one on
    a volume not mounted at that moment — its index and the commits only its
    detached HEAD held went with it — where git's own gc waits three months
    (release-candidate review 3, finding 2). A locked record is left, unless it
    is locked "initializing" by a `git worktree add` no longer running — an add
    cut off (findings 8, 11). A record that holds what no branch does (staged
    content, an operation in progress, refs of its own: record_holds) is left,
    and so is every record under worktrees/ that is not a window's (one made
    there by hand, then moved with mv): deleting it deleted that work, and cut
    the moved checkout off from git (safety-copy review 4, findings 1 and 5).
    <force>: that worktree's record is removed whatever its lock says; the
    caller has judged it (its directory is gone).
    Returns the real paths of the cut-off adds' worktrees whose records it
    removed: what is left of such a directory is a half-written tree.
    Caller holds the lock."""
    dropped: list = []
    common = _common_dir(src)
    if common is None:
        return dropped
    admin = common / "worktrees"
    try:
        entries = sorted(admin.iterdir())
    except OSError:
        return dropped
    want = os.path.realpath(str(force)) if force is not None else None
    for a in entries:
        try:
            gd = (a / "gitdir").read_text().strip()
        except OSError:
            continue
        if not os.path.isabs(gd):
            gd = os.path.normpath(os.path.join(str(a), gd))
        wt = os.path.dirname(gd)
        if not _under(wt, base) or os.path.exists(gd):
            continue
        if want is None or os.path.realpath(wt) != want:
            try:
                reason = (a / "locked").read_text().strip()
            except FileNotFoundError:
                reason = None
            except OSError:
                continue
            if reason is not None and (reason != "initializing" or _add_running(Path(wt)) is not False):
                continue
            if reason == "initializing":
                dropped.append(os.path.realpath(wt))
            elif (base.name == "worktrees" and not _window_record(base, wt, a)) or record_holds(a):
                continue
        shutil.rmtree(str(a), ignore_errors=True)
    return dropped


def _clear_ref_lock(src: Path, branch: str) -> None:
    """refs/heads/<branch>.lock for a window's own branch, left by a git command
    cut off while it wrote that ref (a `worktree add -b`, a branch made): git
    refuses that ref until it is removed ("remove the file manually"). Only
    Daedalus writes lease/<NN> refs, under the lease lock this caller holds
    (release-candidate review 3, finding 8)."""
    common = _common_dir(src)
    if common is not None:
        try:
            (common / "refs" / "heads" / (branch + ".lock")).unlink()
        except OSError:
            pass


LOCK_NAMED_RE = re.compile(r"Unable to create '([^']+\.lock)'")


def _lock_words(err: str) -> Optional[str]:
    """git's "Unable to create '<file>.lock': File exists" as the file to remove, or None."""
    m = LOCK_NAMED_RE.search(err)
    return m.group(1) if m else None


def _foreign_numbers(root: Path, trunks: Dict[str, str]) -> Dict[str, str]:
    """Numbers whose worktrees/<NN>/<repo> is registered to a branch other than lease/<NN> — the debris of an adoption
    cut off by an earlier build: handing out that number gave the window someone else's checkout
    (release-candidate review 3, finding 10). NN -> the branch it is on (the first one found), for the start's
    sentence on skipped numbers."""
    nums: Dict[str, str] = {}
    base = os.path.realpath(str(root / "worktrees"))
    for repo in trunks:
        code, out, _ = _git(root / "target" / repo, "worktree", "list", "--porcelain")
        path = None
        for ln in (out.splitlines() if code == 0 else []) + [""]:
            if ln.startswith("worktree "):
                path = os.path.realpath(ln[len("worktree "):])
            elif ln.startswith("branch refs/heads/") and path and path.startswith(base + os.sep):
                nn = path[len(base) + 1:].split(os.sep, 1)[0]
                if valid_id(nn) and ln[len("branch refs/heads/"):] != "lease/" + nn:
                    nums.setdefault(nn, ln[len("branch refs/heads/"):])
            elif not ln.strip():
                path = None
    return nums


def add_worktrees(root: Path, nn: str, trunks: Dict[str, str], timeout: int = 20,
                  deadline: Optional[float] = None) -> bool:
    """§4.2 'Re-use or refuse': prune; adopt a registered worktree in place;
    check out an existing merged lease/<NN>; else cut it from origin/<trunk>;
    fast-forward an adopted one; recreate target.scaffold dirs empty. Returns
    False when a git call timed out or `deadline` (SessionStart's budget) left
    no whole second for the next one — the lease is then written
    worktree_ready: false and `claim` finishes it, fast-forward included.

    Every git call's timeout is the smaller of `timeout` and what is left
    before `deadline`, recomputed immediately before the call, and a call cut
    off takes its whole process group with it (_run_bounded) — so no repo,
    nested or not, pushes SessionStart past its 30 s, and no checkout keeps
    writing after it. A worktree list cut off is "out of time", never "not
    registered". A registered worktree still locked 'initializing' (an add
    killed mid-checkout) is refused while its `worktree add` is still alive
    (_checkout_live), else removed with `remove -f -f` — plain -f refuses a
    locked tree — and added again from its branch; when git deregisters it
    but cannot delete the directory, the leftover is deleted here. Caller
    holds the lock."""
    base = root / "worktrees" / nn
    branch = "lease/%s" % nn
    for repo, trunk in trunks.items():
        src = root / "target" / repo
        dest = base / repo

        def git(*args: str, cwd: Path = src):
            return _git_budget(cwd, *args, timeout=timeout, deadline=deadline)

        if _left(deadline, timeout) < 1:
            return False
        cut = prune_under(src, root / "worktrees")    # never the operator's own worktrees (review 3, finding 2)
        if dest.exists() and os.path.realpath(str(dest)) in cut:
            # an add cut off before it wrote the worktree's .git file: its record is gone now, and what it wrote
            # of the tree is no one's work (review 3, finding 8)
            shutil.rmtree(str(dest), ignore_errors=True)
        registered = False
        if dest.exists():
            r = git("worktree", "list", "--porcelain")
            if r is None or r[0] == 127:
                return False
            listed = r[1]
            registered = _registered(listed, dest)
            if not registered:
                raise Refused("worktrees/%s/%s exists but is not a worktree of target/%s; move it aside." % (nn, repo, repo))
            if _interrupted_add(listed, dest):
                if _checkout_live(dest):
                    raise Refused("window %s is still being checked out (%s); run `core/lease.sh claim %s` again in "
                                  "a minute." % (nn, repo, nn))
                r = git("worktree", "remove", "-f", "-f", str(dest))
                if r is None or r[0] == 127:
                    return False
                if r[0] != 0:
                    r2 = git("worktree", "list", "--porcelain")
                    if r2 is None or r2[0] == 127:
                        return False
                    # git deregistered it and failed on the directory, or would not remove it at all — an add cut
                    # off before it wrote the worktree's .git file (HEAD 0000, "not a .git file"): nothing in it is
                    # anyone's work, and no add is running. The directory goes, then its record (review 3, finding 8).
                    still = _registered(r2[1], dest)
                    shutil.rmtree(str(dest), ignore_errors=True)
                    if dest.exists():
                        raise Refused("worktrees/%s/%s is left over from an interrupted checkout and could not be "
                                      "deleted; move it aside." % (nn, repo))
                    prune_under(src, root / "worktrees", force=dest if still else None)
                    r2 = git("worktree", "list", "--porcelain")
                    if r2 is None or r2[0] == 127:
                        return False
                    if _registered(r2[1], dest):
                        last = r[2].strip().splitlines()[-1:] or ["no output"]
                        raise Refused("worktrees/%s/%s is a half-finished checkout (its add was interrupted) and git "
                                      "would not remove it: %s" % (nn, repo, last[0]))
                registered = False
        r = git("rev-parse", "--verify", "-q", branch)
        if r is None or r[0] == 127:
            return False
        has_branch = r[0] == 0
        if not registered:
            _clear_ref_lock(src, branch)
            if has_branch:
                r = git("worktree", "add", str(dest), branch)
            else:
                r = git("worktree", "add", str(dest), "-b", branch, remote_ref(trunk))
            if r is None or r[0] == 127:
                return False   # no time left, or cut off: claim finishes it
            if r[0] != 0:
                named = _lock_words(r[2])
                if named:
                    raise Refused("git worktree add for window %s (%s) failed: %s is left over from a git command that "
                                  "was cut off — if no git command is running in target/%s, remove that file, then "
                                  "start a session again." % (nn, repo, named, repo))
                last = r[2].strip().splitlines()[-1:] or ["no output"]
                raise Refused("git worktree add for window %s (%s) failed: %s" % (nn, repo, last[0]))
        if has_branch or registered:
            r = git("merge", "--ff-only", "--quiet", remote_ref(trunk), cwd=dest)
            if r is None or r[0] == 127:
                return False   # not started, or cut off: claim fast-forwards it (Decision 19)
            if r[0] != 0:
                last = r[2].strip().splitlines()[-1:] or ["no output"]
                sys.stderr.write("daedalus: window %s: %s could not be fast-forwarded to origin/%s (%s); "
                                 "the tree is usable but behind trunk — rebase it before promoting.\n"
                                 % (nn, repo, trunk, last[0]))
    # scaffold dirs, empty, inside the outer worktree (config target.scaffold)
    for ln in v._lib(root, "cfg target.scaffold >/dev/null 2>&1 && cfg_pairs target.scaffold | cut -f1").splitlines():
        if ln.strip():
            (base / list(trunks)[0] / ln.strip()).mkdir(parents=True, exist_ok=True)
    # The pre-push hook (spec §7.3), in each repo's COMMON git dir: one install
    # covers target/<repo>, every lease worktree and every promote scratch.
    # Idempotent; a hook Daedalus did not install is left alone (doctor names it).
    try:
        import prepush
    except ImportError:
        prepush = None
    if prepush is not None:
        for repo in trunks:
            try:
                s, msg = prepush.install(root / "target" / repo)
            except (OSError, ValueError) as e:
                s, msg = "failed", "the pre-push hook could not be installed in target/%s (%s)" % (repo, e)
            if s not in ("installed", "unchanged"):
                sys.stderr.write("daedalus: %s; run core/doctor.sh\n" % msg)
    return True


def now_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def pen_bound() -> dict:
    """The fields every prime.json write sets when the pen changes hands:
    bound_at, the local stamp people read, and bound_epoch, the absolute instant
    `prime take --reason` measures the operator's words against. The cut-off is
    never the local stamp: a zone-less stamp means whatever the reading
    process's TZ says, and TZ is the taker's to set (plan 4 Task 3 review)."""
    return {"bound_at": now_stamp(), "bound_epoch": time.time()}


def pen_cutoff(root: Path, prime: dict) -> float:
    """When the holder took the pen, as epoch seconds: bound_epoch; for a
    prime.json written by a build before it, the file's own modification time —
    every write that moves the pen rewrites the file, and a later write can only
    move the cut-off later, never earlier."""
    epoch = prime.get("bound_epoch")
    if isinstance(epoch, (int, float)) and not isinstance(epoch, bool):
        return float(epoch)
    try:
        return lease_path(root, "prime").stat().st_mtime
    except OSError:
        return time.time()


RECLAIM_MIN_SECS = 5


def reclaim_idle_locked(root: Path, leases: Dict[str, dict], trunks: Dict[str, str],
                        deadline: Optional[float] = None) -> list:
    """§4.2 'Numbering': before a number is chosen, every lease with nothing to
    lose and nobody to lose it is removed, so the number it held is free again
    and re-use-or-refuse adopts its worktree. Nothing to lose: no commit on
    lease/<NN> that origin/<trunk> lacks (waiting_work) and no uncommitted
    or untracked file in any of its worktrees (dirty_files); the worktree and
    branch of an idle window are kept, for the number's re-use (§4.5); a
    released window's go too when nothing would be lost (v0.12.7, PROP-029,
    as sweep clears them). Nobody to lose it: its
    RECORDED process is gone — liveness "stale" with a pid on file — never a
    lease that recorded no pid (its staleness is a heartbeat's age, not proof
    the terminal closed), never a finished clone (kept until promote or
    release), and never a spawned clone that has not
    reported `done` (its STALE line on the board says to read its log before
    it is swept — spec §4.2 "How a spawned clone finishes"). A listing that
    cannot answer (Refused) keeps the lease: cannot tell is not "nothing".
    `deadline` (SessionStart's budget): the pass stops, keeping the rest, when
    fewer than RECLAIM_MIN_SECS remain, and each git call gets what is left.
    Added 2026-10-11: the operator's morning terminal reclaims yesterday's
    window 01 and its pen (first_up: previous holder gone) instead of numbering
    02 beside a STALE 01 every day. A RELEASED lease is removed on the
    second leg alone — its session has ended (liveness "stale") — since
    release already said there is nothing to keep it for; while its session
    is open it is held, its holder's hooks may still be reading (2026-10-19).
    CALLER HOLDS THE LOCK; mutates `leases`; returns the numbers removed,
    with why, as (nn, sentence)."""
    out = []
    for nn in sorted(k for k in leases if k != "prime"):
        lease = leases[nn]
        if lease.get("released"):
            # 2026-10-19 (the operator: no sweep typed by hand): a released lease goes once its session has ended — the hold
            # was only for its holder's hooks, and they are gone. A pid on file that is dead and not resumed (liveness
            # "stale" with a pid), as for an idle one below: a lease with no pid is left to `sweep` and SessionEnd,
            # since a heartbeat's age is not proof its terminal closed (review 2026-10-19, finding 3). What `sweep`
            # does for a released lease, no more: the branch and worktree stay unless nothing would be lost (below);
            # unpromoted work on lease/<NN> still holds the number (free_number), and the board names it.
            if lease.get("pid") is None or liveness(root, nn, lease) != "stale":
                continue
            # v0.12.7 (PROP-029): its worktree and branch go too when nothing would be lost — clean, and lease/<NN>
            # on trunk — and only while the start has the time for the git that tells (kept otherwise, as before).
            budget = _left(deadline, 20)
            removed, kept = clear_swept_trees_locked(root, nn, lease, timeout=budget) \
                if budget >= RECLAIM_MIN_SECS else (False, [])
            _remove_lease_files(root, nn)
            del leases[nn]
            carry_hot_locked(root, nn, leases)
            out.append((nn, "Swept window %s: it was released and its session has ended%s." % (nn, swept_words(removed, kept))))
            continue
        if lease.get("finished") or lease.get("spawned"):
            continue
        if lease.get("pid") is None or liveness(root, nn, lease) != "stale":
            continue
        budget = _left(deadline, 20)
        if budget < RECLAIM_MIN_SECS:
            break                               # out of time: the rest are kept, as they were
        why = "its session (pid %s) has ended" % lease.get("pid")
        seeds = {}
        try:
            if not nothing_to_lose(root, nn, lease.get("trunks") or trunks, budget, seeds):
                continue
        except Refused:
            continue
        _remove_lease_files(root, nn)
        del leases[nn]
        carry_hot_locked(root, nn, leases)
        # v0.7.5 (spec §3.2): what reclaim proved goes into the board's cache, at the SHAs and history view it was
        # proved at and for exactly the repos it checked, so the reclaimed number costs the board nothing until a
        # tip moves. Under this lock, but taking none of its own; a failed write never fails the reclaim.
        if seeds:
            write_unpromoted_cache(root, seeds)
        out.append((nn, "Reclaimed window %s: %s, its worktree is clean and nothing is unpromoted; the number is free again."
                    % (nn, why)))
    return out


def nothing_to_lose(root: Path, nn: str, lease_trunks: Dict[str, str], budget: int, seeds: dict) -> bool:
    """The one test of "a window with nothing to lose" (reclaim_idle_locked, and claim dropping the claimer's own
    window): no commit on lease/<NN> that origin/<trunk> lacks in any repo, and no uncommitted or untracked file in
    any of its worktrees. Refused when either cannot be told — cannot tell is not "nothing"."""
    if any(_reclaim_waiting(root, repo, trunk, nn, budget, seeds) for repo, trunk in lease_trunks.items()):
        return False
    return not any(dirty_files(root / "worktrees" / nn / repo, timeout=budget) for repo in lease_trunks)


def _reclaim_waiting(root: Path, repo: str, trunk: str, nn: str, budget: int, seeds: dict) -> list:
    """reclaim's waiting_work for one repo, at SHAs resolved first (a commit landing in between is never judged under
    the old tip). [] when lease/<NN> is absent; Refused when anything cannot be told. A [] at a known history view
    adds its cache entry to `seeds`."""
    target = root / "target" / repo
    if not target.is_dir():
        return []           # as on 2d3bc0c (rev-parse could not run there): a repo that is not there holds no work
    try:
        info = _resolve_tips(target, repo, trunk, timeout=budget)
    except Refused as e:
        raise Refused("cannot tell whether lease/%s has unpromoted work in %s (%s)" % (nn, repo, e))
    tip = (info or {}).get("tips", {}).get(nn)
    if tip is None:
        return []
    if not info["trunk_sha"]:
        raise Refused(TRUNK_REF_MISSING % (repo, trunk, repo))
    subs = waiting_work_at(target, info["trunk_sha"], tip, timeout=budget)
    if not subs and info["view"]:
        seeds[_cache_key(nn, repo)] = _cache_entry(tip, info["trunk_sha"], info["view"], [])
    return subs


def allocate_locked(root: Path, sid: Optional[str], note: Optional[str] = None, criteria: Optional[str] = None,
                    task: Optional[str] = None,
                    spawned: bool = False, timeout: Optional[int] = None,
                    deadline: Optional[float] = None, notes: Optional[list] = None,
                    reclaimed: bool = False) -> Tuple[str, dict]:
    """§4.2 'Allocation': reclaim idle numbers; lowest free number; prune;
    re-use or refuse; worktree add; lease O_EXCL; empty .changed. CALLER HOLDS
    THE LOCK (session_start_bind and claim call this from inside theirs; the
    lock is not re-entrant). `deadline` bounds the worktree adds
    (SessionStart's budget, §4.2). `notes`, when given, receives one sentence
    per number reclaimed (reclaim_idle_locked), then one on why the number is
    not lower when that needs saying (skipped_sentence); `reclaimed` True when the
    caller ran that pass itself under the same lock (session_start_bind)."""
    timeout = int(os.environ.get("LEASE_WORKTREE_TIMEOUT") or (timeout or 20))
    target_base = root / "target"
    trunks = trunks_of(root, target_base)
    if not reclaimed:
        for _nn, sentence in reclaim_idle_locked(root, read_all(root), trunks, deadline=deadline):
            if notes is not None:
                notes.append(sentence)
    while True:
        leases = read_all(root)
        skipped: list = []
        nn = free_number(root, leases, target_base, trunks, skipped=skipped)
        data = {"lease": nn, "session_id": sid, "peer_name": None, "pid": None, "proc_started": None,
                "worktree": "worktrees/%s" % nn, "branch": "lease/%s" % nn,
                "repos": list(trunks), "trunks": trunks, "created": now_stamp(),
                "bound_at": now_stamp() if sid else None, "promoted": []}
        if note:
            data["note"] = note
        if criteria:
            data["criteria"] = criteria
        if task:
            data["task"] = task
        if spawned:
            data["spawned"] = True
        # Written unfinished and marked ready only once the add returns True:
        # a caller SIGKILLed mid-add (its add lives on in its own session,
        # _run_bounded) leaves a window that claim finishes, never one that
        # reads ready over a half-written tree.
        data["worktree_ready"] = False
        try:
            write_lease(root, nn, data, exclusive=True)
        except FileExistsError:
            continue               # another allocator took this number: recompute under the same lock
        break
    said = skipped_sentence(nn, skipped)
    if said and notes is not None:
        notes.append(said)
    try:
        ready = add_worktrees(root, nn, trunks, timeout=timeout, deadline=deadline)
    except BaseException:
        # A refused or failed add must not leave the number held by a lease
        # that has no tree: the next allocation would skip it forever.
        try:
            os.unlink(str(lease_path(root, nn)))
        except OSError:
            pass
        raise
    if ready:
        data.pop("worktree_ready", None)
        write_lease(root, nn, data)
    write_changed(root, nn, {})
    heartbeat(root, nn)
    return nn, data


def allocate(root: Path, sid: Optional[str], **kw) -> Tuple[str, dict]:
    """create / spawn: take the lock, then allocate_locked."""
    with lock(root):
        return allocate_locked(root, sid, **kw)


def launch_line(root: Path, nn: str) -> str:
    home = str(root)
    lines = ["Window %s is ready (not bound to any session yet)." % nn,
             "For a headless clone, run:",
             "  cd %s && DAEDALUS_LEASE=%s claude --bg --name daedalus-%s \"<task>\"" % (home, nn, nn),
             "For a terminal on a build without the session registry:",
             "  cd %s && DAEDALUS_LEASE=%s claude --name daedalus-%s" % (home, nn, nn)]
    if registry_present():
        lines.append("On this build a plain `claude` window numbers itself; you only need this line for the two cases above.")
    else:
        lines.append("This build has no session registry: every terminal window needs the line above.")
    return "\n".join(lines)


# --- Binding and the lifecycle commands (§4.2) ---------------------------------

HELD_BY_LIVE = ("live", "quiet", "resumed")   # a window in any of these states is held (§4.2, §4.5)


def peer_of(lease: dict) -> str:
    return str(lease.get("peer_name") or "unknown — the registry is not available on this build")


def window_label(nn: str, lease: Optional[dict]) -> str:
    """'window 02 (poc-ui)' — number first, alias in parentheses when there is one (§4.2)."""
    alias = (lease or {}).get("alias")
    return "window %s (%s)" % (nn, alias) if alias else "window %s" % nn


def number_of(leases: Dict[str, dict], token: str, cmd: str) -> str:
    """Every command that takes a lease takes its NUMBER; an alias in that
    position is refused with the number it maps to (§4.1)."""
    if valid_id(token):
        return token
    for nn, d in leases.items():
        if nn != "prime" and d.get("alias") == token:
            raise Refused("%s is an alias; window %s carries it — say `%s %s`" % (token, nn, cmd, nn))
    raise Refused("%s is not a window number (two digits, 01–99)" % token)


def require_session(sid: Optional[str], what: str) -> str:
    if sid is None:
        raise Refused("%s needs a session: run it from a Daedalus window (or set DAEDALUS_SESSION_ID)" % what)
    return sid


def _quoted(subjects: list) -> str:
    return ", ".join('"%s"' % s for s in subjects)


def registry_entry_for(sid: str) -> Optional[dict]:
    """The one live registry entry for sid, None when the registry has none;
    Refused when it shows the session open in two terminals (§4.2)."""
    live = registry_live_entries(sid)     # pid + startedAt, never pid alone (Task 2 review, deviation 19c)
    if len(live) > 1:
        raise Refused("This session is open in two terminals at once (pids %s); close one before it can hold a lease."
                      % " and ".join(str(e.get("pid")) for e in live))
    return live[0] if live else None


def _held_by_live(nn: str, lease: dict, remedy: str) -> Refused:
    return Refused("Window %s is held by a live session (peer name %s). %s" % (nn, peer_of(lease), remedy))


def bind(root: Path, nn: str, sid: str, finish_worktree: bool = True, deadline: Optional[float] = None) -> dict:
    """claim / DAEDALUS_LEASE binding. Caller holds the lock. The same rule the
    hook applies: null or dead holder -> bind; a live (or quiet, or resumed)
    other holder -> refuse with its peer name. A compare-and-swap on the
    session_id read first; pid / proc_started / peer_name come from the
    registry entry for sid (None on a build without one); an unfinished
    worktree (worktree_ready: false) is completed here (§4.2) — except when
    finish_worktree is False: a SessionStart that just spent its add budget
    in allocate_locked must not spend it twice (§4.6); `claim` finishes it.
    `deadline` bounds that completion when SessionStart binds through
    `DAEDALUS_LEASE` (§4.2's 30 s); `claim` passes none."""
    lease = read_lease(root, nn)
    if lease is None:
        raise Refused("There is no lease file for window %s; run `core/lease.sh create` for a number first." % nn)
    expect = lease.get("session_id")
    if expect and expect != sid and liveness(root, nn, lease) in HELD_BY_LIVE:
        raise _held_by_live(nn, lease, "Say 'release %s' to that window, or close it first." % nn)
    entry = registry_entry_for(sid)
    fresh = read_lease(root, nn) or {}
    if fresh.get("session_id") != expect:
        raise Refused("window %s changed under you — re-read the board and try again" % nn)
    fresh.update({"session_id": sid, "bound_at": now_stamp(),
                  "pid": entry.get("pid") if entry else None,
                  "proc_started": entry.get("startedAt") if entry else None,
                  "proc_start": entry.get("procStart") if entry else None,
                  "peer_name": entry.get("name") if entry else None})
    fresh.pop("released", None)
    if expect and expect != sid:
        # A takeover from a dead holder: the old holder's report (`done`) and
        # its spawned mark describe THAT session, not this one — an interactive
        # takeover is not a spawned clone and has not reported. Left in place
        # they render a live window FINISHED and keep sweep from ever clearing
        # it (Task 4 review). A null holder is the clone's own first binding of
        # a spawned lease, which keeps spawned: true.
        # ... and its session-log reservation: the number was that session's, for the day it
        # opened; this one is told today's at `lease.sh log` (fresh-context review, 2026-10-14).
        for key in ("finished", "summary", "spawned", "logs"):
            fresh.pop(key, None)
    if finish_worktree and fresh.get("worktree_ready") is False:
        if add_worktrees(root, nn, fresh.get("trunks") or trunks_of(root, root / "target"), deadline=deadline):
            fresh.pop("worktree_ready", None)
    write_lease(root, nn, fresh)
    heartbeat(root, nn)
    # A session that took the pen holding no window is treeless only until it claims one (pen_without_tree):
    # it keeps the pen, and from here on it is a window holding the pen, as after any claim.
    prime = read_lease(root, "prime")
    if prime and prime.get("taken_without_window") == sid:
        prime.pop("taken_without_window", None)
        write_lease(root, "prime", prime)
    return fresh


def self_rebind(root: Path, sid: str, leases: Optional[Dict[str, dict]] = None,
                live: Optional[list] = None) -> Optional[str]:
    """A resumed session keeps its id and gets a new pid (§4.2): refresh pid /
    proc_started / peer_name on the lease that already names sid. The
    compare-and-swap is on session_id, which is unchanged, so no other session
    is displaced. Does nothing while the session is open in two terminals.
    Caller holds the lock. Returns the window number, None when sid holds none.
    The board passes the leases it read and sid's live registry entries from
    its one registry pass (registry_live_map), so a render is one read per
    lease and no ps; every other caller lets this read both."""
    leases = read_all(root) if leases is None else leases
    nn, lease = lease_of_session(leases, sid)
    if nn is None:
        return None
    if live is None:
        try:
            entry = registry_entry_for(sid)
        except Refused:
            return nn                   # two terminals: do nothing (§4.2)
    elif len(live) > 1:
        return nn
    else:
        entry = live[0] if live else None
    if entry and (lease.get("pid") != entry.get("pid") or lease.get("proc_started") != entry.get("startedAt")
                  or lease.get("proc_start") != entry.get("procStart") or lease.get("peer_name") != entry.get("name")):
        lease.update({"pid": entry.get("pid"), "proc_started": entry.get("startedAt"),
                      "proc_start": entry.get("procStart"), "peer_name": entry.get("name")})
        write_lease(root, nn, lease)
    return nn


def claim(root: Path, token: str, sid: str) -> str:
    """Bind this session to window NN. A swept number (no lease file) whose
    lease/<NN> still carries unpromoted commits is adopted as-is and its
    subjects are named — the one path that continues such work (§4.2).
    A session already holding another window with nothing to lose
    (nothing_to_lose — the number every terminal takes at start, released or
    not) gives it up: once NN is bound, that window's lease files are
    removed as reclaim removes them — its worktree and branch are kept for the
    next allocation to re-use (they may hold git-ignored files) — and its
    session-log reservation moves to NN, so the session keeps the log number
    it was told.
    Added 2026-10-19: 'this is window 01' from a new terminal (numbered 03 at
    start) refused, and a released 03 told the operator to open yet another
    terminal, which was numbered again — a loop with no way back to 01."""
    with lock(root):
        leases = read_all(root)
        nn = number_of(leases, token, "claim")
        held, held_lease = lease_of_session(leases, sid)
        drop = None
        if held and held != nn:
            # One lease per session id: resolve, the board, self_rebind and
            # done's prime lookup all read the ONE lease that names a session.
            held_trunks = held_lease.get("trunks") or trunks_of(root, root / "target")
            try:
                empty, why = nothing_to_lose(root, held, held_trunks, 20, {}), None
            except Refused as e:
                empty, why = False, str(e)
            if not empty:
                raise Refused(_claim_held_refusal(root, nn, held, held_lease, why, leases))
            drop = held
        line = _claim_locked(root, nn, sid, leases)
        if drop is None:
            return line
        logs = _reservations(held_lease)
        _remove_lease_files(root, drop)     # as reclaim: worktree and branch kept for the next allocation to re-use
        carry_hot_locked(root, drop, read_all(root))
        if logs:
            claimed = read_lease(root, nn) or {}
            if not _reservations(claimed):
                claimed["logs"] = logs
                write_lease(root, nn, claimed)
        return ("This session was window %s, which had nothing to lose (clean, nothing unpromoted); its lease is given "
                "up.\n%s" % (drop, line))


def _claim_held_refusal(root: Path, nn: str, held: str, held_lease: dict, why: Optional[str],
                        leases: Dict[str, dict]) -> str:
    """claim's sentence when this session's own window has work: what it holds, and the path that works — a new
    terminal, numbered at start with nothing in it, where 'this is window NN' gives that number up and binds NN."""
    if why is None:
        try:
            problems = unpromoted_work(root, held, held_lease)[2]
        except Refused as e:
            problems = [str(e)]
        why = ", and ".join(problems) or "has work"
    else:
        why = "cannot be checked (%s)" % why
    hint = (" (or start it with `DAEDALUS_LEASE=%s claude`)" % nn) if nn in leases else ""
    if held_lease.get("released"):
        return ("This session was window %s and released it, and it still %s; this window is done — close it. To "
                "continue window %s, say 'this is window %s' in a new terminal%s." % (held, why, nn, nn, hint))
    return ("This session is already window %s, which %s, so it cannot also be window %s. To continue window %s, say "
            "'this is window %s' in a new terminal%s; this one stays window %s." % (held, why, nn, nn, nn, hint, held))


def _claim_locked(root: Path, nn: str, sid: str, leases: Dict[str, dict]) -> str:
    """claim's bind of NN, the caller holding the lock: an existing lease through bind(), a swept number re-created
    and adopted. Returns the sentence."""
    if nn in leases:
        before = leases[nn]
        lease = bind(root, nn, sid)
        line = "This is %s." % window_label(nn, lease)
        if before.get("finished") and before.get("session_id") != sid:
            line += (" An earlier session finished it (%s); that report is cleared — this window continues the work."
                     % (before.get("summary") or "no summary"))
        return line
    trunks = trunks_of(root, root / "target")
    subjects = [s for repo in trunks for s in waiting_work(root / "target" / repo, trunks[repo], nn)]
    data = {"lease": nn, "session_id": None, "peer_name": None, "pid": None, "proc_started": None,
            "worktree": "worktrees/%s" % nn, "branch": "lease/%s" % nn,
            "repos": list(trunks), "trunks": trunks, "created": now_stamp(), "bound_at": None, "promoted": [],
            "worktree_ready": False}   # as allocate_locked: ready only once the add returns True
    write_lease(root, nn, data, exclusive=True)
    try:
        if add_worktrees(root, nn, trunks):
            data.pop("worktree_ready", None)
            write_lease(root, nn, data)
        # else cut off (a git call timed out): left unfinished, so the bind
        # just below — and any later claim — finishes it (§4.2). Plan 1
        # discarded this False and wrote the window ready.
        write_changed(root, nn, {})
        lease = bind(root, nn, sid)
    except BaseException:
        # as allocate_locked: a number held by a lease with no tree or no
        # holder would be skipped by every later allocation
        try:
            os.unlink(str(lease_path(root, nn)))
        except OSError:
            pass
        raise
    if subjects:
        return "Window %s continues %d unpromoted commit%s from an earlier session (%s)." % (
            nn, len(subjects), "" if len(subjects) == 1 else "s", _quoted(subjects))
    return "This is %s." % window_label(nn, lease)


TASK_MAX = 120            # stored: the board cuts it to TASK_SHOWN, the band to its own width
TASK_SHOWN = 90


def task_line(text: object, limit: int = TASK_MAX) -> str:
    """One line of a window's task: every run of whitespace or control characters is one space, at most `limit`
    characters (the last an ellipsis when cut); "" when nothing is left."""
    flat = " ".join(_CONTROL_RUN.sub(" ", str(text or "")).split())
    return flat if len(flat) <= limit else flat[:limit - 1] + "…"


def set_task(root: Path, token: str, sid: Optional[str], value: Optional[str]) -> str:
    """`task`: like set_field, but a window's task is its own session's while that session is live — another
    window setting it would put words on the board that window never chose (review 2026-10-19, F1). A stale
    window's may be set from anywhere, and an operator shell (sid None) may set any. Returns the number."""
    with lock(root):
        leases = read_all(root)
        nn = number_of(leases, token, "task")
        lease = leases.get(nn)
        if lease is None:
            raise Refused("There is no window %s." % nn)
        holder = lease.get("session_id")
        if sid is not None and holder and holder != sid and liveness(root, nn, lease) in HELD_BY_LIVE:
            mine, _ = lease_of_session(leases, sid)
            raise Refused("Window %s's task is its own session's to set; set yours with `core/lease.sh task %s \"<one "
                          "line>\"`." % (nn, mine or "<NN>"))
        if value is None:
            lease.pop("task", None)
        else:
            lease["task"] = value
        write_lease(root, nn, lease)
        return nn


def set_field(root: Path, token: str, cmd: str, key: str, value: object) -> str:
    """alias / note / update --criteria: one field, under the lock. An alias
    must pass valid_alias and be unique among the leases on disk (§4.1);
    value None removes the field (`alias --clear`). Returns the number."""
    with lock(root):
        leases = read_all(root)
        nn = number_of(leases, token, cmd)
        lease = leases.get(nn)
        if lease is None:
            raise Refused("There is no window %s." % nn)
        if key == "alias" and value is not None:
            if not valid_alias(value, root):
                raise Refused("%s cannot be an alias: lowercase letters, digits and dashes, 2–32 characters, and not a "
                              "role or branch name (prime, main, master, the trunk, target, vault, state)." % value)
            for other, d in leases.items():
                if other != nn and other != "prime" and d.get("alias") == value:
                    raise Refused("%s is already the alias of window %s; pick another." % (value, other))
        if value is None:
            lease.pop(key, None)
        else:
            lease[key] = value
        write_lease(root, nn, lease)
        return nn


def dirty_files(worktree: Path, timeout: int = 20) -> list:
    """Paths `git status` reports in a lease worktree — modified, staged and
    untracked alike; [] for a clean tree or a path that is not there. A
    failing status is an answer we do not have, never 'clean'."""
    if not worktree.is_dir():
        return []
    code, out, err = _git(worktree, "status", "--porcelain", "--untracked-files=all", timeout=timeout)
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot tell whether %s has uncommitted changes (git status failed: %s)" % (worktree, last[0]))
    return [ln[3:].split(" -> ")[-1] for ln in out.splitlines() if len(ln) > 3]


def _remove_lease_files(root: Path, nn: str) -> None:
    # The delete ask (release_asked_path) goes with the lease files, so a reused number never inherits an old ask.
    for p in (lease_path(root, nn), leases_dir(root) / (nn + ".seen"), leases_dir(root) / (nn + ".changed"),
              release_asked_path(root, nn)):
        try:
            p.unlink()
        except FileNotFoundError:
            pass


HOT_CARRY_WAIT = 2.0     # seconds a sweep waits for state/hot.lock; a window's hot.py write holds it for milliseconds


def carry_hot_locked(root: Path, nn: str, leases: Dict[str, dict]) -> None:
    """A window that goes without its close (swept, reclaimed, its released lease removed) leaves its hot.md entries
    `carried from window NN, <date>`, as its close would have (v0.12.6, spec 2026-10-20 C), so the number's next
    holder never inherits them. CALLER HOLDS THE LOCK; `leases` is what it holds now, the removed window gone. The
    lock order is this one: lease lock, then state/hot.lock (core/hot.py never waits for the lease lock while it
    holds its own). A hot lock busy past HOT_CARRY_WAIT, or any failure, changes nothing and never fails the sweep."""
    try:
        import hot
        hot.carry_windows(root, [nn], {k: d for k, d in leases.items() if k != nn}, who="the sweep",
                          deadline=time.time() + HOT_CARRY_WAIT)
    except Exception:
        pass


def release(root: Path, token: str, sid: Optional[str], remove: bool = False, force: bool = False,
            said: Optional[str] = None) -> str:
    """The holder ends its lease: released: <time> (removed when its session
    ends — the SessionEnd hook, or the next terminal start's reclaim — or at
    a sweep, so the holder's own hooks can still read the state). Any other
    session is refused while the holder is live; a stale lease may be released
    from anywhere, and an operator shell (sid None) may release anything.
    --remove deletes worktree and branch, refusing unpromoted commits and
    uncommitted changes without --force and naming them (subjects, file
    paths) before deleting them (§4.2, §4.5). From a session (sid), a window
    with nothing to lose is deleted at once (delete_risks, v0.12.2); one with
    work only after its unpromoted report ran in this session and the operator
    agreed after it, in any words (deletion_confirmed_locked; `said`, the
    --operator-said citation, is optional), and what authorised it is recorded
    first (record_deletion). An operator shell
    (sid None) is unchanged — whatever form ran it, this is the backstop
    behind the guard's early refusal (design 2026-10-15, decision 13)."""
    with lock(root):
        leases = read_all(root)
        nn = number_of(leases, token, "release")
        lease = leases.get(nn)
        if lease is None:
            raise Refused("There is no window %s." % nn)
        holder = lease.get("session_id")
        if sid is not None and holder != sid and liveness(root, nn, lease) in HELD_BY_LIVE:
            raise _held_by_live(nn, lease, "Say 'release %s' to that window, or close it first." % nn)
        if not remove:
            lease["released"] = now_stamp()
            write_lease(root, nn, lease)
            return "Window %s released; this window is done — close it." % nn
        # v0.12.2: from a session, the yes is asked only when there is something to lose (delete_risks)
        authorised = None
        if sid is not None and delete_risks(root, nn, lease):
            authorised = deletion_confirmed_locked(root, sid, nn, lease, said)
        subjects, dirty, problems = unpromoted_work(root, nn, lease)
        if problems and not force:
            raise Refused("Window %s %s. Add --force to delete them." % (nn, ", and ".join(problems)))
        return "\n".join(_delete_window_locked(root, nn, lease, sid, said, authorised, subjects, dirty))


def _delete_window_locked(root: Path, nn: str, lease: dict, sid: Optional[str], said: Optional[str],
                          authorised: Optional[dict], subjects: list, dirty: list) -> list:
    """release --remove's deletion of one window, once its gate has passed: the evidence first (when a yes
    authorised it), then worktrees, branches, split tips, lease files and its unpromoted-cache entries. Caller holds
    the lock. Returns the lines."""
    trunks = lease.get("trunks") or {}
    if authorised is not None:
        record_deletion(root, nn, str(sid), str(said), authorised)
    out = []
    if sid is not None and authorised is None:
        out.append("Window %s had no unpromoted commits and no uncommitted changes, so no yes was needed." % nn)
    if subjects:
        out.append("Deleting window %s's unpromoted commits: %s" % (nn, _quoted(subjects)))
    for repo, files in dirty:
        out.append("Deleting window %s's uncommitted changes in worktrees/%s/%s: %s" % (nn, nn, repo, ", ".join(files)))
    for repo in reversed(list(trunks)):          # nested repos first: they sit inside the outer worktree
        src = root / "target" / repo
        dest = root / "worktrees" / nn / repo
        if dest.exists():
            code, _, err = _git(src, "worktree", "remove", "--force", str(dest))
            if code != 0:
                last = err.strip().splitlines()[-1:] or ["no output"]
                raise Refused("could not remove worktrees/%s/%s (git worktree remove: %s); nothing was deleted from the lease"
                              % (nn, repo, last[0]))
        else:
            prune_under(src, root / "worktrees")
        if _git(src, "rev-parse", "--verify", "-q", "lease/%s" % nn)[0] == 0:
            code, _, err = _git(src, "branch", "-D", "lease/%s" % nn)
            if code != 0:
                last = err.strip().splitlines()[-1:] or ["no output"]
                raise Refused("could not delete branch lease/%s in target/%s (%s)" % (nn, repo, last[0]))
        # split's kept tips (spec §7.1 step 2): kept until release --remove, then gone.
        _, split_refs, _ = _git(src, "for-each-ref", "--format=%(refname)", "refs/daedalus/split/%s-*" % nn)
        for ref in split_refs.split():
            _git(src, "update-ref", "-d", ref)
    _remove_lease_files(root, nn)
    carry_hot_locked(root, nn, read_all(root))
    # the branch is gone, so is its work: drop its unpromoted-work answers, or the band (which reads the cache and
    # never git) shows a swept number with work until some prompt's board rewrites it (review 2026-10-19, finding 4)
    write_unpromoted_cache(root, {}, keep=lambda k: k.partition(" ")[0] != nn)
    if authorised is not None:
        out.append("Window %s released; its worktree and branch are deleted (after the operator said: \"%s\")."
                   % (nn, authorised["text"]))
    else:
        out.append("Window %s released; its worktree and branch are deleted." % nn)
    return out


def release_many(root: Path, tokens: list, sid: Optional[str], force: bool = False, said: Optional[str] = None) -> str:
    """`release 02 03 04 --remove [--force] [--operator-said "…"]` (v0.12.2): several windows' work deleted under
    ONE gate. Every window is checked as `release NN --remove` checks one — it exists, no other live session holds
    it — and, from a session, the windows with something to lose (delete_risks) need the operator's one consent
    after their reports (group_confirmed_locked); a window with nothing to lose needs none. Any refusal — a held window,
    a missing ask, a changed window, unpromoted work without --force — refuses the whole delete before anything is
    deleted; a git failure part-way (a worktree git cannot remove) stops there and names what was already deleted.
    Several numbers go only with --remove: a window releases itself (`release NN`)."""
    with lock(root):
        leases = read_all(root)
        nns = sorted(set(number_of(leases, t, "release") for t in tokens))
        for nn in nns:
            lease = leases.get(nn)
            if lease is None:
                raise Refused("There is no window %s." % nn)
            holder = lease.get("session_id")
            if sid is not None and holder != sid and liveness(root, nn, lease) in HELD_BY_LIVE:
                raise _held_by_live(nn, lease, "Say 'release %s' to that window, or close it first." % nn)
        ok = None
        if sid is not None:
            need = [nn for nn in nns if delete_risks(root, nn, leases[nn])]
            if need:
                ok = group_confirmed_locked(root, sid, need, leases, said)
        work = {}
        for nn in nns:
            subjects, dirty, problems = unpromoted_work(root, nn, leases[nn])
            if problems and not force:
                raise Refused("Window %s %s. Add --force to delete them; nothing was deleted." % (nn, ", and ".join(problems)))
            work[nn] = (subjects, dirty)
        out = []
        for nn in nns:
            m = (ok or {}).get("markers", {}).get(nn)
            authorised = dict(ok, fingerprint=m.get("fingerprint"), problems=m.get("problems")) if m else None
            try:
                out += _delete_window_locked(root, nn, leases[nn], sid, said, authorised, *work[nn])
            except Refused as e:
                raise Refused("\n".join(out + [str(e)]))
        return "\n".join(out)


def unpromoted_work(root: Path, nn: str, lease: dict) -> Tuple[list, list, list]:
    """What `release --remove` would delete: the window's commits not on its trunk (subjects), its uncommitted
    files per repo, and the same as the sentences the refusal and the `unpromoted` report are built from.
    Uncommitted work is work too (§4.5): `git worktree remove` refuses a dirty tree on its own, and --force
    would bypass that refusal silently, so it is named here first (Task 4 review)."""
    trunks = lease.get("trunks") or {}
    subjects = [s for repo in trunks for s in waiting_work(root / "target" / repo, trunks[repo], nn)]
    dirty = []
    for repo in trunks:
        files = dirty_files(root / "worktrees" / nn / repo)
        if files:
            dirty.append((repo, files))
    problems = []
    if subjects:
        problems.append("has %d unpromoted commit%s: %s"
                        % (len(subjects), "" if len(subjects) == 1 else "s", _quoted(subjects)))
    for repo, files in dirty:
        problems.append("has uncommitted changes in worktrees/%s/%s (%d file%s: %s)"
                        % (nn, repo, len(files), "" if len(files) == 1 else "s", ", ".join(files)))
    return subjects, dirty, problems


# --- Deleting a window's work: report, yes, delete (agent-runnable design 2026-10-15, §4.2) -------------------
# The question the report ends with. v0.12.2: a plain question — nothing checks its wording or where the operator's
# answer stands; one report names every window, and one consent covers them all.
DELETE_INVITATION = "Delete window %s's work"
DELETE_INVITATION_MANY = "Delete the work of windows %s"


def and_list(nns: list) -> str:
    """'02' · '02 and 03' · '02, 03 and 04'."""
    return nns[0] if len(nns) == 1 else "%s and %s" % (", ".join(nns[:-1]), nns[-1])


def delete_invitation(nns: list) -> str:
    """The report's closing question, for one window or several."""
    return DELETE_INVITATION % nns[0] if len(nns) == 1 else DELETE_INVITATION_MANY % and_list(nns)


def release_asked_path(root: Path, nn: str) -> Path:
    """The witness that `unpromoted <NN>` ran for a session: state/release-asked/<NN>.json. A witness, not a trust
    root — a script the session runs could write it, so the consent must be a turn the operator typed (find_consent)
    and the cut-off is never this file's time alone (lease_epochs)."""
    return root / "state" / "release-asked" / (nn + ".json")


def _hash_update(h: "hashlib._Hash", *parts: object) -> None:
    for part in parts:
        b = part if isinstance(part, bytes) else str(part).encode("utf-8", "surrogateescape")
        h.update(b)
        h.update(b"\0")


def work_fingerprint(root: Path, nn: str, lease: dict) -> str:
    """What the operator's yes answers: a sha256 over, per repo of the window, the worktree's HEAD, its tracked
    diff, its status and each untracked file's content. A commit, an amended commit with the same subject, a
    further edit to a file the report already named, or a new file all change it; the report's sentences cannot
    tell those apart. Git only, no lease lock: it may run under either lock."""
    h = hashlib.sha256()
    for repo in (lease.get("trunks") or {}):
        wt = root / "worktrees" / nn / repo
        _hash_update(h, "repo", repo)
        if not wt.is_dir():
            _hash_update(h, "absent")
            continue
        for args in (("rev-parse", "HEAD"), ("diff", "HEAD", "--binary"),
                     ("status", "--porcelain", "-z", "--untracked-files=all")):
            code, out, _ = _git(wt, *args)
            _hash_update(h, " ".join(args), code, out)
        code, out, _ = _git(wt, "ls-files", "--others", "--exclude-standard", "-z")
        _hash_update(h, "untracked", code)
        for rel in sorted(x for x in out.split("\0") if x):
            try:
                content = hashlib.sha256((wt / rel).read_bytes()).hexdigest()
            except OSError as e:
                content = "unreadable: %s" % e
            _hash_update(h, rel, content)
    return h.hexdigest()


def lease_epochs(lease: dict) -> float:
    """The latest instant the lease file itself records — created, bound_at, every history[].at and split_from.at
    (now_stamp's local %Y-%m-%dT%H:%M:%S, parsed with mktime) — 0.0 when none parses. The delete's cut-off is at
    least this: a yes from before this window existed never counts, whatever the witness marker says."""
    stamps = [lease.get("created"), lease.get("bound_at")]
    for entry in (lease.get("history") or []):
        if isinstance(entry, dict):
            stamps.append(entry.get("at"))
    sf = lease.get("split_from")
    if isinstance(sf, dict):
        stamps.append(sf.get("at"))
    best = 0.0
    for raw in stamps:
        if not isinstance(raw, str):
            continue
        try:
            best = max(best, time.mktime(time.strptime(raw, "%Y-%m-%dT%H:%M:%S")))
        except (ValueError, OverflowError):
            continue
    return best


def _read_json(p: Path) -> Optional[dict]:
    try:
        d = json.loads(p.read_text())
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


ASK_FIRST = ("Run core/lease.sh unpromoted %s first, tell the operator what would be lost, and ask; the delete runs "
             "once they agree, in any words.")
NOTHING_TO_LOSE = ("Window %s has no unpromoted commits and no uncommitted changes; deleting its work removes only its "
                   "worktree and branch and needs no yes.")


def delete_risks(root: Path, nn: str, lease: dict) -> list:
    """What deleting window nn's work could lose, as the report's sentences — [] only when it is PROVED there is
    nothing (v0.12.2: then the delete needs no yes): no commit on lease/<NN> that its trunk lacks, no uncommitted or
    untracked file in any of its worktrees (unpromoted_work), and every worktree there checked out on lease/<NN> —
    a detached HEAD or another branch may carry commits unpromoted_work never looks at. Refused when any of it
    cannot be told: cannot tell is not "nothing"."""
    _, _, risks = unpromoted_work(root, nn, lease)
    risks = list(risks)
    for repo in (lease.get("trunks") or {}):
        wt = root / "worktrees" / nn / repo
        if not wt.is_dir():
            continue
        code, out, err = _git(wt, "symbolic-ref", "-q", "HEAD")
        if code == 0 and out.strip() == "refs/heads/lease/%s" % nn:
            continue
        if code == 0:
            ref = out.strip()
            risks.append("has worktrees/%s/%s on branch %s, not lease/%s"
                         % (nn, repo, ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref, nn))
        elif code == 1:
            risks.append("has worktrees/%s/%s on a detached HEAD, not lease/%s" % (nn, repo, nn))
        else:
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("cannot tell which branch worktrees/%s/%s is on (git symbolic-ref: %s)" % (nn, repo, last[0]))
    return risks


def deletion_confirmed_locked(root: Path, sid: Optional[str], nn: str, lease: dict, said: Optional[str]) -> dict:
    """One window's gate: group_confirmed_locked for [nn], answering as before — what authorised it (transcript_ref,
    shown_ref, cutoff, fingerprint, text, problems) or Refused with one sentence."""
    ok = group_confirmed_locked(root, sid, [nn], {nn: lease}, said)
    m = ok["markers"][nn]
    return dict(ok, fingerprint=m.get("fingerprint"), problems=m.get("problems"))


def group_confirmed_locked(root: Path, sid: Optional[str], nns: list, leases: Dict[str, dict],
                           said: Optional[str]) -> dict:
    """Whether a session may delete the work of windows nns now (agent-runnable design 2026-10-15, §4.2; v0.12.2:
    v0.12.5: anything the operator typed since the report, one answer for every window it named). Caller holds the lock,
    shared or exclusive; this never calls lock(). Returns what authorised it — transcript_ref, shown_ref (None),
    cutoff, text, and each window's witness under "markers" — or raises Refused with one sentence:
      1. the witness: ONE `unpromoted` report in THIS session named every one of these windows
         (state/release-asked/<NN>.json names sid, its number, the report's numbers and its time — one time for
         all), and not before any of them existed (lease_epochs) — a witness, not a trust root;
      2. tty mode: the deployment confirms at a terminal, so the delete is pasted there;
      3. the work is what the report named, in every window (work_fingerprint unchanged since its ask): a changed
         window refuses the whole delete by name — nothing is deleted, and the report is made again;
      4. the operator's words: a turn they typed in this session after the latest of those asks and the windows' own
         times, in any words (v0.12.5, transcriptlib.find_consent: a model-written turn, or a line added to the file,
         never counts). Whether the words agree is the agent's judgment; `said` (the agent's --operator-said) is a
         citation, refused only when the words it cites are in no turn the operator typed."""
    import transcriptlib as tl
    nns = sorted(set(nns))
    nums = " ".join(nns)
    markers, asks, epochs = {}, set(), 0.0
    for nn in nns:
        m = _read_json(release_asked_path(root, nn))
        if m is None or m.get("session_id") != sid or m.get("lease") != nn or nn not in (m.get("group") or [nn]):
            raise Refused(ASK_FIRST % nums)
        try:
            at = float(m.get("at"))      # type: ignore[arg-type]
        except (TypeError, ValueError):
            raise Refused(ASK_FIRST % nums)
        e = lease_epochs(leases[nn])
        if at < e:
            raise Refused(ASK_FIRST % nums)                  # the report predates this window: stale, or not its own
        asks.add(at)
        epochs = max(epochs, e)
        markers[nn] = m
    if len(asks) > 1:
        # one consent answers one report: windows reported apart were asked apart, and a no to the earlier one would
        # fall before the later one's cut-off (review 2026-10-19, finding 2) — so they are reported together, once
        raise Refused(ASK_FIRST % nums)
    asked_at = asks.pop()
    try:
        mode = tl.confirm_mode(root)
    except ValueError as e:
        raise Refused(str(e))
    if mode == "tty":
        raise Refused("This deployment confirms at the terminal (promote.confirm: tty). Paste this line in your "
                      "own shell: cd %s && core/lease.sh release %s --remove --force" % (root, nums))
    changed = [nn for nn in nns if work_fingerprint(root, nn, leases[nn]) != markers[nn].get("fingerprint")]
    if changed:
        raise Refused("Window%s %s's work changed since the report (a commit, an amended commit, or a changed or added "
                      "file); nothing was deleted. Run core/lease.sh unpromoted %s again, tell the operator what "
                      "changed, and ask again." % ("s" if len(changed) > 1 else "", and_list(changed), nums))
    cutoff = max(asked_at, epochs)
    shell = "set `promote.confirm: tty` and run the delete in your own shell"
    try:
        found = tl.find_consent(tl.transcript_for(root, str(sid)), cutoff, quote=said)
    except tl.Unprotected as e:
        raise Refused("This session's transcript (%s) is outside every directory nothing may write, so it is not "
                      "evidence of the operator's words. Nothing was deleted. Set memory.transcript_dir in "
                      "config.yaml, or %s." % (e, shell))
    except tl.Missing as e:
        raise Refused("I cannot find this session's transcript (%s), so the operator's consent cannot be checked. "
                      "Nothing was deleted. If it lives elsewhere, set memory.transcript_dir in config.yaml; or %s."
                      % (e, shell))
    except tl.Unreadable as e:
        d = tl.DRIFT[:1].upper() + tl.DRIFT[1:]
        cut = d.index(";")
        raise Refused("%s (%s)%s. Nothing was deleted. Until then, %s." % (d[:cut], e, d[cut:], shell))
    except tl.NotCited:
        raise Refused("The words cited are in nothing the operator typed since the report on window%s %s. Nothing "
                      "was deleted; cite a few of their words exactly, or leave --operator-said out."
                      % ("s" if len(nns) > 1 else "", and_list(nns)))
    except tl.NotSubmitted as e:
        raise Refused("Those words are in this session's transcript, but %s. Nothing was deleted; ask the operator."
                      % str(e).replace("the words are", "they are", 1))
    except tl.NotWritten:
        raise Refused("Those words are in this session's transcript, but not as a turn Claude Code wrote there: "
                      "nothing in the conversation follows from them, so they were added to the file afterwards. "
                      "Nothing was deleted; ask the operator.")
    except tl.NotFound:
        raise Refused("The operator has typed nothing in this session since the report on window%s %s. Nothing was "
                      "deleted; tell them what would be lost and ask — any words are enough."
                      % ("s" if len(nns) > 1 else "", and_list(nns)))
    return {"transcript_ref": found["transcript_ref"], "shown_ref": found["shown_ref"], "cutoff": cutoff,
            "text": found["text"], "markers": markers}


def deletion_confirmed(root: Path, sid: str, nns: "list | str", said: Optional[str]) -> Optional[str]:
    """The guard's entry (core/guard-bash.py): the refusal sentence for `core/lease.sh release NN [NN …] --remove …`
    from session sid, or None when the delete may run. A shared lock, one read of the leases; transcriptlib is
    imported only inside the check. A window with nothing to lose (delete_risks) needs no yes (v0.12.2); the rest
    need the operator's consent, in any words, after their reports."""
    nns = [nns] if isinstance(nns, str) else list(nns)
    try:
        with lock(root, shared=True):
            leases = read_all(root)
            for nn in nns:
                if leases.get(nn) is None:
                    return "There is no window %s." % nn
            need = [nn for nn in nns if delete_risks(root, nn, leases[nn])]
            if need:
                group_confirmed_locked(root, sid, need, leases, said)
    except Refused as e:
        return str(e)
    return None


def record_deletion(root: Path, nn: str, sid: str, said: str, ok: dict) -> Path:
    """What authorised a deletion, written before anything is deleted (design decision 23): the witness marker goes
    with the lease files, so this is the one record naming the transcript entry the deletion rested on."""
    d = root / "state" / "evidence" / "deletions"
    d.mkdir(parents=True, exist_ok=True)
    p = d / ("%s-%s.json" % (nn, time.strftime("%Y%m%d-%H%M%S")))
    p.write_text(json.dumps({"lease": nn, "session_id": sid, "said": said, "transcript_ref": ok["transcript_ref"],
                             "shown_ref": ok["shown_ref"], "cutoff": ok["cutoff"], "fingerprint": ok["fingerprint"],
                             "problems": ok.get("problems"), "at": now_stamp()}, indent=2))
    return p


def unpromoted_report(root: Path, tokens: "list | str", sid: Optional[str] = None) -> str:
    """`core/lease.sh unpromoted <NN> [<NN> …]`: the report-only first step of "release NN and delete its work" —
    what `release NN --remove` would delete, deleting nothing. A verb of its own because `release --remove` was denied
    by Claude Code's auto-mode classifier before it ran (another deployment, 2026-10-13). Read-only on the leases: a
    shared lock, any session, a visitor too. One sentence per window, then — when any window has something to lose —
    one plain question naming them (delete_invitation; nothing checks its wording, v0.12.2). A window with nothing
    to lose (delete_risks is []) is said to need no yes, and gets no witness. From a session (sid), each window with
    something to lose is witnessed under state/release-asked/<NN>.json — the session id, its report, problems and
    fingerprint, the time, and the numbers this report named; the latest ask for a number overwrites an earlier one,
    and moves the cut-off the operator's consent must follow. A visitor's ask is witnessed too (a visitor cannot
    release). An operator shell leaves no marker: it needs none."""
    tokens = [tokens] if isinstance(tokens, str) else list(tokens)
    with lock(root, shared=True):
        leases = read_all(root)
        nns = []
        for t in tokens:
            nn = number_of(leases, t, "unpromoted")
            if leases.get(nn) is None:
                raise Refused("There is no window %s." % nn)
            if nn not in nns:
                nns.append(nn)
        nns.sort()
        risks = {nn: delete_risks(root, nn, leases[nn]) for nn in nns}
        need = [nn for nn in nns if risks[nn]]
        fps = {nn: work_fingerprint(root, nn, leases[nn]) for nn in need}
    reports = {nn: ("Window %s %s." % (nn, ", and ".join(risks[nn])) if risks[nn] else NOTHING_TO_LOSE % nn)
               for nn in nns}
    if sid is not None and need:
        at = time.time()
        for nn in need:
            marker = release_asked_path(root, nn)
            marker.parent.mkdir(parents=True, exist_ok=True)
            tmp = marker.with_name(marker.name + ".tmp")
            tmp.write_text(json.dumps({"lease": nn, "session_id": sid, "at": at, "report": reports[nn],
                                       "problems": risks[nn], "fingerprint": fps[nn], "group": need}, indent=2))
            os.replace(str(tmp), str(marker))
    lines = [reports[nn] for nn in nns]
    if need:
        lines.append(delete_invitation(need) + "?")
    return "\n".join(lines)


def _holder_or_shell(root: Path, nn: str, lease: dict, sid: Optional[str], cmd: str) -> None:
    """rebase / split are the window's own (spec §4.11: "run by the clone"): its
    holder, or an operator shell, or anyone once the holder is stale — never
    another live session (plan 4 Decision 26)."""
    holder = lease.get("session_id")
    if sid is not None and holder and holder != sid and liveness(root, nn, lease) in HELD_BY_LIVE:
        raise _held_by_live(nn, lease, "Say '%s %s' to that window; it runs it in its own worktree." % (cmd, nn))


def _count(root: Path, nn: str, repo: str, trunk: str, spec: str) -> int:
    """Commits in `spec` in worktrees/<nn>/<repo>. A rev-list that fails is an
    answer we do not have, never 0 — 0 would tell the window it is up to date."""
    code, out, err = _git(root / "worktrees" / nn / repo, "rev-list", "--count", spec)
    if code != 0 or not out.strip().isdigit():
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot tell whether worktrees/%s/%s is behind origin/%s (git rev-list: %s); window %s was not rebased"
                      % (nn, repo, trunk, last[0], nn))
    return int(out.strip())


def rebase(root: Path, token: str, sid: Optional[str]) -> str:
    """`lease.sh rebase <NN>` (spec §7.1 step 4, §4.2): fetch origin in every repo of
    the window, then `git rebase origin/<trunk>` in each of its worktrees,
    outer first. A conflict stops there, names the paths and leaves the
    worktree mid-rebase for the window to resolve (`git rebase --continue`),
    exit non-zero. Uncommitted work is refused first, before any fetch
    (rebase moves commits only). The lock is held only to read the lease:
    git runs outside it."""
    with lock(root, shared=True):
        leases = read_all(root)
    nn = number_of(leases, token, "rebase")
    lease = leases.get(nn)
    if lease is None:
        raise Refused("There is no window %s." % nn)
    _holder_or_shell(root, nn, lease, sid, "rebase")
    if lease.get("worktree_ready") is False:
        raise Refused("window %s's worktree was not finished at start; run `core/lease.sh claim %s` to finish it" % (nn, nn))
    trunks = lease.get("trunks") or trunks_of(root, root / "target")
    # A worktree that is not there cannot be counted or rebased, and
    # dirty_files calls it clean: refuse it rather than report it up to date.
    for repo in trunks:
        if not (root / "worktrees" / nn / repo).is_dir():
            raise Refused("worktrees/%s/%s is missing; run `core/lease.sh claim %s` to finish window %s's worktree, "
                          "then rebase" % (nn, repo, nn, nn))
    for repo in trunks:
        files = dirty_files(root / "worktrees" / nn / repo)
        if files:
            raise Refused("Window %s has uncommitted changes in worktrees/%s/%s (%s). Commit them on lease/%s first; "
                          "rebase moves commits only." % (nn, nn, repo, ", ".join(files), nn))
    for repo in trunks:
        code, _, err = fetch_origin(root / "target" / repo)
        if code != 0:
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("could not fetch origin in target/%s (%s); window %s was not rebased" % (repo, last[0], nn))
    # Every repo is counted before any is rebased: a count that fails refuses
    # while no worktree has moved, so "was not rebased" stays true.
    counts = {repo: (_count(root, nn, repo, trunk, "%s..HEAD" % remote_ref(trunk)),
                     _count(root, nn, repo, trunk, "HEAD..%s" % remote_ref(trunk))) for repo, trunk in trunks.items()}
    report = []
    for repo, trunk in trunks.items():
        wt = root / "worktrees" / nn / repo
        ahead, behind = counts[repo]
        if behind == 0:
            report.append("%s already up to date" % repo)
            continue
        code, _, err = _git(wt, "rebase", "--quiet", remote_ref(trunk), timeout=300)
        if code != 0:
            _, unmerged, _ = _git(wt, "diff", "--name-only", "--diff-filter=U")
            conflicts = [f for f in unmerged.splitlines() if f.strip()]
            if conflicts:
                raise Refused("Window %s's rebase stopped on a conflict in %s: %s. Resolve it in worktrees/%s/%s, "
                              "`git add` the file, then `git rebase --continue`; run core/gates.sh when it finishes."
                              % (nn, repo, ", ".join(conflicts), nn, repo))
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("git rebase in worktrees/%s/%s failed (%s)" % (nn, repo, last[0]))
        report.append("%s fast-forwarded to origin/%s" % (repo, trunk) if ahead == 0 else
                      "%s: %d commit%s replayed onto origin/%s" % (repo, ahead, "" if ahead == 1 else "s", trunk))
    try:
        recompute_changed(root, nn)
    except Refused:
        pass
    return "Window %s is up to date with trunk (%s). Run core/gates.sh before asking for promote." % (nn, "; ".join(report))


def _discard_locked(root: Path, nn: str, trunks: Dict[str, str]) -> None:
    """Undo an allocation made inside this lock (split's rollback): worktrees
    (nested first), lease/<NN> branches, lease files. Caller holds the lock."""
    for repo in reversed(list(trunks)):
        src = root / "target" / repo
        _git(src, "worktree", "remove", "--force", str(root / "worktrees" / nn / repo))
        prune_under(src, root / "worktrees")
        _git(src, "branch", "-D", "lease/%s" % nn)
    _remove_lease_files(root, nn)


# Git operations that leave a worktree mid-way, each with the words that finish
# or undo it (checked by the marker git keeps in the worktree's own git dir).
_IN_PROGRESS = (("rebase-merge", "rebase", "rebase"), ("rebase-apply", "rebase", "rebase"),
                ("MERGE_HEAD", "merge", "merge"), ("CHERRY_PICK_HEAD", "cherry-pick", "cherry-pick"),
                ("REVERT_HEAD", "revert", "revert"))


def _on_lease_branch(root: Path, nn: str, repo: str) -> None:
    """Refuse unless worktrees/<nn>/<repo> is on branch lease/<nn> with no git
    operation stopped half-way. split resets whatever HEAD points to: on a
    detached HEAD (a rebase stopped on a conflict and resolved with nothing
    left to commit shows a clean `git status`) lease/<nn> would keep every
    commit it just copied to the new window."""
    wt, where = root / "worktrees" / nn / repo, "worktrees/%s/%s" % (nn, repo)
    for marker, what, cmd in _IN_PROGRESS:
        code, out, _ = _git(wt, "rev-parse", "--git-path", marker)
        path = Path(out.strip()) if code == 0 and out.strip() else None
        if path is not None and not path.is_absolute():
            path = wt / path
        if path is not None and path.exists():
            raise Refused("%s is in the middle of a %s. Finish it there with `git %s --continue`, or undo it with "
                          "`git %s --abort`, then split; split moves finished commits only." % (where, what, cmd, cmd))
    code, out, _ = _git(wt, "symbolic-ref", "-q", "HEAD")
    head = out.strip() if code == 0 else ""
    if head != "refs/heads/lease/%s" % nn:
        state = ("its HEAD is on branch %s" % head[len("refs/heads/"):] if head.startswith("refs/heads/")
                 else "its HEAD is detached")
        raise Refused("%s is not on branch lease/%s (%s). Run `git checkout lease/%s` there, then split; split moves "
                      "lease/%s's commits and resets that branch." % (where, nn, state, nn, nn))


def _split_checks(root: Path, nn: str, lease: dict, sid: Optional[str], nested: str) -> Tuple[Dict[str, str], str]:
    """What split refuses from the lease alone and the window's worktrees:
    run once before the fetch (no network for a refusal) and again under the
    exclusive lock after it, because the window may have moved meanwhile.
    Returns (trunks, key)."""
    _holder_or_shell(root, nn, lease, sid, "split")
    if lease.get("worktree_ready") is False:
        raise Refused("window %s's worktree was not finished at start; run `core/lease.sh claim %s` to finish it"
                      % (nn, nn))
    trunks = lease.get("trunks") or trunks_of(root, root / "target")
    outer = next(iter(trunks))
    key = "%s/%s" % (outer, nested.strip("/"))
    if key not in trunks:
        names = [k.split("/", 1)[1] for k in trunks if "/" in k]
        raise Refused("Window %s has no nested repo %s (its nested repos: %s)."
                      % (nn, nested, ", ".join(names) or "none"))
    # A worktree that is not there reads clean to dirty_files and cannot be
    # reset: refuse it before anything is allocated (as rebase does).
    for repo in trunks:
        if not (root / "worktrees" / nn / repo).is_dir():
            raise Refused("worktrees/%s/%s is missing; run `core/lease.sh claim %s` to finish window %s's "
                          "worktree, then split" % (nn, repo, nn, nn))
    _on_lease_branch(root, nn, key)
    for repo in trunks:
        files = dirty_files(root / "worktrees" / nn / repo)
        if files:
            raise Refused("Window %s has uncommitted changes in worktrees/%s/%s (%s). Commit them first; split "
                          "moves commits only." % (nn, nn, repo, ", ".join(files)))
    return trunks, key


def split(root: Path, token: str, sid: Optional[str], nested: str) -> str:
    """`lease.sh split <NN> --repo <nested>` (spec §7.1 step 2, §4.2): the nested
    repo's commits origin/<trunk>..lease/<NN> become a new numbered window (as
    `create` allocates it: no session bound, promoted from the board and
    released afterwards); the original window's branch in that repo is reset
    to origin/<trunk>, its old tip kept as refs/daedalus/split/<NN>-<stamp>
    until `release --remove`. The outer repo is not touched. Refuses when
    either worktree is dirty or the nested one is not on lease/<NN>; a
    cherry-pick that does not apply rolls the new window back.

    The fetch runs with no lock held, as rebase's does: guard-bash and the
    Edit|Write boundary hook take the lock shared under 5 s hook timeouts, and
    a network fetch under the exclusive lock would stall every window's
    checks. Every check is then repeated under the exclusive lock, which
    holds only local work: allocation, cherry-pick, reset, the lease writes."""
    with lock(root, shared=True):
        leases = read_all(root)
    nn = number_of(leases, token, "split")
    lease = leases.get(nn)
    if lease is None:
        raise Refused("There is no window %s." % nn)
    trunks, key = _split_checks(root, nn, lease, sid, nested)
    ntrunk, src = trunks[key], root / "target" / key
    code, _, err = fetch_origin(src)
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("could not fetch origin in target/%s (%s); nothing was split" % (key, last[0]))
    with lock(root):
        lease = read_all(root).get(nn)
        if lease is None:
            raise Refused("Window %s was released while its trunk was being fetched; nothing was split." % nn)
        trunks, key = _split_checks(root, nn, lease, sid, nested)
        ntrunk, src = trunks[key], root / "target" / key
        subjects = list(reversed(waiting_work(src, ntrunk, nn)))
        if not subjects:
            raise Refused("Window %s has no commits in %s that are not already on %s; nothing to split."
                          % (nn, key, ntrunk))
        new_nn, data = allocate_locked(root, None, note="split from window %s (%s)" % (nn, key))
        new_trunks = data.get("trunks") or trunks
        dest = root / "worktrees" / new_nn / key
        if data.get("worktree_ready") is False or key not in new_trunks or not dest.is_dir():
            _discard_locked(root, new_nn, new_trunks)
            raise Refused("window %s's worktree for %s could not be made; nothing was split" % (new_nn, key))
        code, _, err = _git(dest, "cherry-pick", "--allow-empty-message", "%s..refs/heads/lease/%s" % (remote_ref(ntrunk), nn), timeout=300)
        if code != 0:
            _git(dest, "cherry-pick", "--abort")
            _discard_locked(root, new_nn, new_trunks)
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("Window %s's commits in %s do not apply cleanly onto current %s (%s); nothing was split. "
                          "Run `core/lease.sh rebase %s` first, then split again." % (nn, key, ntrunk, last[0], nn))
        stamp = time.strftime("%Y%m%d-%H%M%S")
        kept = "refs/daedalus/split/%s-%s" % (nn, stamp)
        code, _, err = _git(src, "update-ref", kept, "lease/%s" % nn)
        if code != 0:
            raise Refused("could not keep lease/%s's old tip in %s (%s); window %s now holds copies and window %s is "
                          "unchanged" % (nn, key, err.strip(), new_nn, nn))
        code, _, err = _git(root / "worktrees" / nn / key, "reset", "--hard", "--quiet", remote_ref(ntrunk))
        if code != 0:
            raise Refused("could not reset window %s's branch in %s (%s); its old tip is kept as %s"
                          % (nn, key, err.strip(), kept))
        lease["split_to"] = (lease.get("split_to") or []) + [{"lease": new_nn, "repo": key, "at": now_stamp(),
                                                              "commits": len(subjects), "kept": kept}]
        write_lease(root, nn, lease)
        fresh = read_lease(root, new_nn) or {}
        fresh["split_from"] = {"lease": nn, "repo": key, "at": now_stamp(), "kept": kept}
        write_lease(root, new_nn, fresh)
    for n in (nn, new_nn):
        try:
            recompute_changed(root, n)
        except Refused:
            pass
    return ("Window %s now holds window %s's commits in %s (%d: %s); window %s keeps its other commits. The old tip of "
            "lease/%s in %s is kept as %s until `core/lease.sh release %s --remove`. Promote window %s from the board, "
            "then release it.\n%s" % (new_nn, nn, key, len(subjects), _quoted(subjects), nn, nn, key, kept, nn, new_nn,
                                      new_nn))


# A window's branch: lease/<NN> for a number ever issued — never lease/00, which an operator's own branch can be named
# and which no window has (release-candidate review 3, finding 4).
LEASE_BRANCH = re.compile(r"lease/(?!00)[0-9]{2}")
ADOPT_DIRTY = ("target/%s has uncommitted changes — commit them on their branch inside that checkout, then "
               "run adopt again.")
# Two branch names that differ only in case share one file where git ignores case: git reads one for the other, and
# deleting one deletes both (release-candidate review 4, finding 1). The rename goes through packed-refs, which keeps
# the two apart.
ADOPT_TWINS = ("target/%s has branches whose names differ only in case (%s), which this filesystem cannot keep apart "
               "— git reads one in place of the other. Give one a new name (git -C target/%s pack-refs --all, then "
               "git -C target/%s branch -m %s <new name>), then run adopt again.")


def repo_key(root: Path, repo: Optional[str]) -> str:
    """'<name>' for the outer repo (repo None or the name itself); '<name>/<rel>' for a nested one, given as
    '<rel>' or '<name>/<rel>'. Refused for anything that is not one of this target's repos."""
    name = target_name(root)
    if not repo or repo == name:
        return name
    key = repo if repo.startswith(name + "/") else "%s/%s" % (name, repo)
    repos = repos_of(root)
    if key not in repos:
        raise Refused("%s is not one of this target's repos (%s)." % (repo, ", ".join(repos)))
    return key


def unpromoted_commits(src: Path, trunk: str, rev: str) -> list:
    """Subjects, oldest first, of the commits on <rev> that origin/<trunk> has no equivalent of. `git cherry`
    compares changes, not shas: a commit that reached trunk as part of a merge, or cherry-picked under another
    sha, is on trunk (spec §14 step 6 adopts only work that is not; plan 5 Decision 4)."""
    code, out, err = _git(src, "cherry", remote_ref(trunk), rev)
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot compare %s with origin/%s in %s (%s)" % (rev, trunk, src.name, last[0]))
    subjects = []
    for ln in out.splitlines():
        if ln.startswith("+ "):
            _, s, _ = _git(src, "log", "-1", "--format=%s", ln[2:].strip())
            subjects.append(s.strip())
    return subjects or merge_work(src, trunk, rev)


def merge_work(src: Path, trunk: str, rev: str) -> list:
    """Subjects, oldest first, of <rev>'s merge commits origin/<trunk> lacks, when merging <rev> into origin/<trunk>
    would change something: git cherry passes over merge commits, so a branch whose only unpushed content is in a
    merge — a resolved conflict, an amended merge, notes added while merging — read as already on origin and was named
    nowhere (release-candidate review 3, finding 3). [] when it has none, or its merge changes nothing there (a merge
    of origin/<trunk> into a branch already merged). A merge git cannot judge here (`merge-tree --write-tree` needs
    git 2.38) counts as work: named, never passed over."""
    code, out, _ = _git(src, "log", "--merges", "--reverse", "--format=%s", "%s..%s" % (remote_ref(trunk), rev))
    merges = [s for s in out.splitlines() if s.strip()] if code == 0 else []
    if not merges:
        return []
    code, tree, _ = _git(src, "merge-tree", "--write-tree", remote_ref(trunk), rev)
    _, base, _ = _git(src, "rev-parse", "%s^{tree}" % remote_ref(trunk))
    if code == 0 and tree.split()[:1] == [base.strip()]:
        return []
    return merges


def _adopt_number(root: Path, leases: Dict[str, dict], trunks: Dict[str, str]) -> str:
    """free_number, skipping a number whose lease/<NN> branch still exists in any repo (a swept window's merged
    branch — §4.5 keeps branches): adopt makes that branch itself, so it needs the name free. Caller holds the lock."""
    taken = dict(leases)
    while True:
        nn = free_number(root, taken, root / "target", trunks)
        if not any(_git(root / "target" / r, "rev-parse", "--verify", "-q", "refs/heads/lease/" + nn)[0] == 0
                   for r in trunks):
            return nn
        taken[nn] = {}


def _held_elsewhere(src: Path, sha: str) -> bool:
    """Is commit <sha> on some local or remote-tracking branch of <src>?"""
    code, out, _ = _git(src, "for-each-ref", "--contains", sha, "--count=1", "--format=%(refname)",
                        "refs/heads", "refs/remotes")
    return code == 0 and bool(out.strip())


def git_reason(err: str) -> str:
    """git's reason for a refusal, in one line: the files named after a "would be overwritten" line (untracked
    files in the way, or local changes), else the first error:/fatal: line without its prefix, else the last line.
    git ends such refusals with "Aborting", which says nothing (plan 5 Task 3 review, finding 3)."""
    lines = err.strip().splitlines()
    for i, ln in enumerate(lines):
        if "would be overwritten" in ln:
            files = []
            for f in lines[i + 1:]:
                if not f.startswith(("\t", " ")):
                    break
                files.append(f.strip())
            kind = "untracked files" if "untracked" in ln else "local changes"
            if files:
                return "%s would be overwritten: %s" % (kind, ", ".join(files))
    for ln in lines:
        for pre in ("error: ", "fatal: "):
            if ln.startswith(pre):
                return ln[len(pre):].strip()
    return (lines[-1:] or ["no output"])[0].strip() or "no output"


def ignores_case(src: Path) -> bool:
    """Does git in <src> treat paths that differ only in case as one (core.ignorecase — set by git on a
    case-insensitive filesystem, macOS's default)?"""
    code, out, _ = _git(src, "config", "--bool", "core.ignorecase")
    return code == 0 and out.strip() == "true"


def unreadable_gits(src: Path) -> list:
    """Directories below the checkout at <src> (relative to it) holding an entry named .git, in any case, that git
    cannot read as a repository there — its HEAD broken, or a .git file pointing nowhere. git lists neither the
    entry nor, when nothing else is in it, the directory: no status shows it, yet a checkout or reset that writes a
    file where that directory is deletes it, the commits in that .git with it (safety-copy review 4, finding 3).
    A readable repository inside is git's to list and is not looked into."""
    found = []
    top = str(src)
    for dp, dns, fns in os.walk(top):
        names = [n for n in dns + fns if n.casefold() == ".git" and not (dp == top and n == ".git")]
        dns[:] = [d for d in dns if d.casefold() != ".git"]
        if not names or dp == top:
            if dp == top and names:
                found.append(".")
            continue
        code, out, _ = _git(Path(dp), "rev-parse", "--show-toplevel")
        if code == 0 and os.path.realpath(out.strip()) == os.path.realpath(dp):
            dns[:] = []             # a repository git can read: its own files are its own
            continue
        found.append(os.path.relpath(dp, top))
    return sorted(f for f in found if f != ".")


def untracked_in_way(src: Path, refs: list, ignored_only: bool = False) -> list:
    """Untracked paths of <src>'s working tree — ignored ones too — that checking out, fast-forwarding or
    hard-resetting to any of <refs> would overwrite: a file the ref tracks, a directory where it has a file, or a
    file where it has a directory. A checkout or merge refuses over an untracked file, but writes over an ignored
    one without a word, as `reset --hard` does over both (plan 5 Task 3 review, finding 3; release-candidate review
    2, findings 1-2: a file someone stopped tracking and listed in .gitignore). Paths are compared casefolded and
    NFC-normalized when git ignores case (finding 3: an untracked Thing.txt is where a reset writes thing.txt).
    ignored_only: only the ignored ones (a fast-forward refuses over the others by itself). Sorted; [] when there
    are none or git cannot answer."""
    untracked: list = []
    if not ignored_only:
        code, out, _ = _git(src, "ls-files", "--others", "--exclude-standard", "-z")
        untracked = [u.rstrip("/") for u in out.split("\0") if u] if code == 0 else []
    # --directory: a wholly ignored directory (node_modules/) is one entry, looked into below only where a ref tracks
    code, out, _ = _git(src, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z")
    ignored = [u for u in out.split("\0") if u] if code == 0 else []
    # a directory holding a .git git cannot read is untracked work no listing names; a checkout writes over it
    # whether git would refuse over an untracked file or not
    hidden = unreadable_gits(src)
    untracked += [h for h in hidden if h not in untracked]
    if not untracked and not ignored:
        return []
    fold = ignores_case(src)

    def norm(path: str) -> str:
        return unicodedata.normalize("NFC", path).casefold() if fold else path

    ign_dirs = {norm(u.rstrip("/")): u.rstrip("/") for u in ignored if u.endswith("/")}
    files: set = set()
    dirs: set = set()
    under: Dict[str, set] = {}          # an ignored directory -> the paths a ref tracks below it
    for ref in refs:
        code, out, _ = _git(src, "ls-tree", "-r", "--name-only", "-z", ref)
        if code != 0:
            continue
        for t in out.split("\0"):
            if not t:
                continue
            n = norm(t)
            files.add(n)
            parts = n.split("/")
            for i in range(1, len(parts)):
                pre = "/".join(parts[:i])
                dirs.add(pre)
                if pre in ign_dirs:
                    under.setdefault(pre, set()).add(t)

    def in_way(u: str) -> bool:
        n = norm(u)
        parts = n.split("/")
        return n in files or n in dirs or any("/".join(parts[:i]) in files for i in range(1, len(parts)))

    hit = {u for u in untracked if in_way(u)}
    for u in ignored:
        if not u.endswith("/"):
            if in_way(u):
                hit.add(u)
            continue
        d = u.rstrip("/")
        if norm(d) in files:
            hit.add(d)                  # a directory where a ref has a file
            continue
        # every path below an ignored directory is untracked here: one a ref tracks is in the way where anything
        # is on disk at it, or a file is where it needs a directory
        for t in sorted(under.get(norm(d), ())):
            rest = t.split("/")[len(d.split("/")):]
            for i in range(1, len(rest) + 1):
                q = "/".join([d] + rest[:i])
                if not os.path.lexists(str(src / q)):
                    break
                if i == len(rest) or not os.path.isdir(str(src / q)):
                    hit.add(q)
                    break
    return sorted(hit)


def gitlink_dirs(src: Path) -> Dict[str, str]:
    """{path: "repository" | "files"} for each gitlink (a submodule's entry, .gitmodules or not) in the index of the
    checkout at <src> whose directory on disk holds anything: a repository of its own ("repository": an entry named
    .git, in any case, at its top — its commits, its untracked files), or plain files ("files": a submodule vendored
    by removing its .git, the gitlink left in the index). git never looks into either from <src>: no status, diff or
    listing of untracked files names what is in it. An empty directory (a submodule not checked out) is not listed."""
    code, out, _ = _git(src, "ls-files", "-s", "-z")
    found: Dict[str, str] = {}
    for ent in (out.split("\0") if code == 0 else []):
        meta, _, path = ent.partition("\t")
        bits = meta.split()
        if len(bits) != 3 or bits[0] != "160000" or not path:
            continue
        d = os.path.join(str(src), path)
        if os.path.islink(d) or not os.path.isdir(d):
            continue
        try:
            names = os.listdir(d)
        except OSError:
            continue
        if names:
            found[path] = "repository" if any(n.casefold() == ".git" for n in names) else "files"
    return found


def gitlinks_in_way(src: Path, refs: list) -> Dict[str, str]:
    """gitlink_dirs of <src> where any of <refs> has something other than a gitlink — a file, a symlink or a
    directory: checking out, fast-forwarding or hard-resetting to it deletes that directory with everything in it, a
    repository's .git and its commits too, or writes files into it over what is there; git, which does not look
    into it, neither refuses nor says so (release-candidate red team 3, findings 1 and 3). Where a ref has the
    gitlink too (any commit), or nothing, git leaves the directory as it is. {} when there are none."""
    dirs = gitlink_dirs(src)
    if not dirs:
        return {}
    hit: Dict[str, str] = {}
    for ref in refs:
        code, out, _ = _git(src, "--literal-pathspecs", "ls-tree", "-z", ref, "--", *sorted(dirs))
        for ent in (out.split("\0") if code == 0 else []):
            meta, _, path = ent.partition("\t")
            bits = meta.split()
            if path in dirs and bits and bits[0] != "160000":
                hit[path] = dirs[path]
    return hit


def gitlink_words(hit: Dict[str, str]) -> Tuple[str, str, str]:
    """(what is there, the paths named, "it" or "them") for a sentence about gitlinks_in_way."""
    one = len(hit) == 1
    if all(k == "repository" for k in hit.values()):
        what = ("a repository of its own, recorded there as a submodule" if one
                else "repositories of their own, recorded there as submodules")
    else:
        what = ("a directory git records as a submodule, with files in it git never lists" if one
                else "directories git records as submodules, with files in them git never lists")
    return what, name_paths(sorted(hit)), "it" if one else "them"


def hidden_edits(src: Path) -> Dict[str, str]:
    """{path: "skip-worktree" | "assume-unchanged"} for each tracked file of <src> carrying that mark whose file on
    disk differs from the index: an uncommitted change `git status` does not show (release-candidate review 2,
    finding 6). A marked file absent from disk (a sparse checkout) is no change. {} when there are none."""
    code, out, _ = _git(src, "ls-files", "-v", "-s", "-z")
    if code != 0:
        return {}
    marked = []
    for ent in out.split("\0"):
        if len(ent) < 3 or "\t" not in ent:
            continue
        tag, rest = ent[0], ent[2:]
        meta, path = rest.split("\t", 1)
        bits = meta.split()
        if len(bits) < 2 or bits[0] == "160000":
            continue                    # a submodule
        if tag == "S" or tag == "s":
            marked.append((path, bits[1], "skip-worktree"))
        elif tag.islower():
            marked.append((path, bits[1], "assume-unchanged"))
    found: Dict[str, str] = {}
    for path, blob, mark in marked:
        f = src / path
        if not os.path.lexists(str(f)):
            continue
        if os.path.islink(str(f)):
            data = os.readlink(str(f)).encode()
            import hashlib
            sha = hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()
        else:
            code, sha, _ = _git(src, "hash-object", "--", path)
            if code != 0:
                found[path] = mark      # cannot tell: say so rather than miss it
                continue
            sha = sha.strip()
        if sha != blob:
            found[path] = mark
    return found


# attributes under which git changes a file's bytes on the way into the repository or out of it — crlf too, git's older
# name for text, which git still honours (set: text; input: text with eol=lf) and check-attr reports only under its
# own name (release-candidate red team, finding 2). Unset, each means no change (-crlf is -text).
TRANSFORM_ATTRS = ("filter", "ident", "text", "eol", "working-tree-encoding", "crlf")


def _checker(src: Path, deadline: Optional[float]):
    """(left, run) for the content checks below: left() is the seconds to <deadline> (None without one) and raises
    subprocess.TimeoutExpired once there are none; run(args, inp, env_extra) runs git in <src> in its own process
    group — a filter program git starts is killed with it at the deadline — and returns (code, stdout bytes)."""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")

    def left() -> Optional[float]:
        if deadline is None:
            return None
        t = deadline - time.time()
        if t <= 0:
            raise subprocess.TimeoutExpired("git", 0)
        return t

    def run(args: list, inp: Optional[bytes] = None, env_extra: Optional[dict] = None) -> Tuple[int, bytes]:
        p = subprocess.Popen(git_argv(src, *args), stdin=subprocess.PIPE if inp is not None
                             else subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             env=dict(env, **(env_extra or {})), start_new_session=True)
        try:
            out, _ = p.communicate(input=inp, timeout=left())
        except BaseException:
            _kill_group(p)
            raise
        return p.returncode, out

    return left, run


def filtered_edits(src: Path, deadline: Optional[float] = None, skip: Optional[set] = None) -> list:
    """Tracked files of the worktree at <src> whose bytes on disk are in no object: neither what a checkout of their
    staged content writes nor that staged blob itself, among those git transforms on the way in or out (a clean or
    smudge filter, ident, line-ending conversion, a working-tree encoding — or every file under core.autocrlf): an
    edit git status never shows, because git compares such a file only after its clean filter ran (a filter that
    strips local lines or a notebook's outputs, CRLF line ends under text=auto). A checkout or reset replaces the
    file with the committed version and those bytes are gone. A file whose bytes are the staged blob's own — checked
    out before a rule or a filter for it was added — holds nothing no commit has (release-candidate red team,
    finding 3).
    What a checkout writes is written whole, by git checkout-index into a scratch directory, and compared whole:
    cat-file --batch --filters gives each file's size before its conversion, so a file whose conversion changes its
    size threw the reading of every later file off — an untouched clone stopped for good, and a real hidden change
    could read as none (release-candidate red team 2, findings 4-5). A filter driver git runs as a long-running
    process (how Git LFS sets itself up) is never run here: its smudge can download, write into the repository and
    fail offline (finding 7); its files are left to git status, which compares their clean side — for Git LFS a hash
    of the whole content, so every edit shows — and to stat_blind_edits. A driver git merely marks required
    (nbstripout, git-crypt) is run (red team 3, finding 6). A file whose bytes differ from a checkout's only inside
    $Keyword: ...$ expansions (git's ident, a keyword-expanding filter), and whose clean side is its staged blob, is
    no hidden change: a checkout writes the same with fresh expansions (red team 3, finding 8). Paths in <skip> are
    not read. Under <deadline>, raises subprocess.TimeoutExpired when it is
    out of time."""
    skip = skip or set()
    left, run = _checker(src, deadline)
    code, out = run(["ls-files", "-s", "-z"])
    if code != 0:
        return []
    blobs: Dict[str, str] = {}
    for rec in out.split(b"\0"):
        meta, _, path = rec.partition(b"\t")
        bits = meta.split(b" ")
        if len(bits) == 3 and bits[2] == b"0" and bits[0] not in (b"160000", b"120000"):
            p = os.fsdecode(path)
            if p not in skip:
                blobs[p] = bits[1].decode()
    if not blobs:
        return []
    code, out = run(["config", "--get", "core.autocrlf"])
    every = os.fsdecode(out).strip().lower() in ("true", "input", "yes", "on", "1")
    code, out = run(["check-attr", "-z", "--stdin"] + list(TRANSFORM_ATTRS),
                    b"".join(os.fsencode(p) + b"\0" for p in blobs))
    toks = out.split(b"\0") if code == 0 else []
    hit, driver = set(), {}
    for i in range(0, len(toks) - 2, 3):
        name, attr, val = os.fsdecode(toks[i]), toks[i + 1], toks[i + 2]
        if val not in (b"unspecified", b"unset"):
            hit.add(name)
            if attr == b"filter" and val != b"set":
                driver[name] = os.fsdecode(val)
    cands = []
    for p, b in sorted(blobs.items()):
        if not every and p not in hit:
            continue
        try:
            st = os.lstat(os.path.join(str(src), p))
        except OSError:
            continue        # deleted: git status names it
        if stat.S_ISREG(st.st_mode):
            cands.append((p, b, st.st_size))
    if not cands:
        return []
    # bytes on disk exactly the staged blob's: nothing no commit has (read with its true size: no conversion)
    differ = set(_unlike(src, cands, run, left))
    cands = [c for c in cands if c[0] in differ]
    # a long-running filter driver (filter.<d>.process: how Git LFS sets itself up) is not run (finding 7). One git
    # merely marks required is: nbstripout's own install marks its driver required, and skipping it let the
    # notebook outputs its clean side strips — bytes in no commit — be deleted unseen (red team 3, finding 6)
    unrun = set()
    for d in sorted({driver[p] for p, _, _ in cands if p in driver}):
        _, proc = run(["config", "--get", "filter.%s.process" % d])
        if proc.strip():
            unrun.add(d)
    cands = [c for c in cands if driver.get(c[0]) not in unrun]
    if not cands:
        return []
    return sorted(_unlike_checkout(src, cands, run, left))


def _unlike_checkout(src: Path, cands: list, run, left) -> list:
    """The paths of <cands> ((path, blob, size on disk)) whose bytes on disk are not what a checkout of the staged
    blob writes (smudge, ident, line-ending conversion, working-tree encoding applied): every one written whole by
    one git checkout-index into a scratch directory, never into the worktree or its index; a path it did not write
    (skip-worktree, a name it refuses) is written by cat-file --filters alone. One that cannot be written or read
    counts as unlike: say so rather than miss it. One that differs only inside keyword expansions, its clean side its
    staged blob, is not unlike (_keywords_only)."""
    found = []
    written: Dict[str, object] = {}     # path -> what a checkout writes: the scratch file's name, or its bytes
    scratch = tempfile.mkdtemp(prefix="daedalus-checkout-")
    try:
        run(["checkout-index", "-z", "--stdin", "--prefix=%s/" % scratch],
            b"".join(os.fsencode(p) + b"\0" for p, _, _ in cands))
        for p, b, size in cands:
            mine = os.path.join(str(src), p)
            out = os.path.join(scratch, p)
            if os.path.isfile(out) and not os.path.islink(out):
                if not _same_files(mine, out):
                    found.append(p)
                    written[p] = out
                continue
            code, data = run(["cat-file", "--filters", "--path=" + p, b])
            if code != 0 or not _same_bytes(mine, data):
                found.append(p)
                if code == 0:
                    written[p] = data
        if found:
            found = _keywords_only(src, [c for c in cands if c[0] in set(found)], written, run)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return found


# a keyword git's ident attribute, or a keyword-expanding filter, writes expanded: $Id: <blob id> $, $Date: ... $
KEYWORD = re.compile(rb"\$([A-Za-z]+):[^$\n]*\$")
KEYWORD_MAX = 64 << 20      # larger files are not compared keyword by keyword: they stay "unlike"


def _keywords_only(src: Path, cands: list, written: Dict[str, object], run) -> list:
    """The paths of <cands> ((path, blob, size on disk)), each unlike what a checkout writes (<written>), that hold
    something a commit does not: all but those whose bytes on disk, cleaned as git add cleans them, are their staged
    blob, and differ from what a checkout writes only inside $Keyword: ...$ expansions — a $Id: <old blob id> $ an
    earlier checkout expanded, which git never rewrites after a commit (release-candidate red team 3, finding 8).
    Bytes a filter's clean side drops (a notebook's outputs) differ outside any keyword and stay."""
    maybe = [c for c in cands if c[0] in written and "\n" not in c[0] and c[2] <= KEYWORD_MAX]
    keep = [c[0] for c in cands if c not in maybe]
    if not maybe:
        return sorted(keep)
    code, out = run(["hash-object", "--stdin-paths"], b"".join(os.fsencode(p) + b"\n" for p, _, _ in maybe))
    ids = out.split() if code == 0 else []
    if len(ids) != len(maybe):
        return sorted(keep + [p for p, _, _ in maybe])
    for (p, b, _), h in zip(maybe, ids):
        same = h.decode() == b
        if same:
            try:
                with open(os.path.join(str(src), p), "rb") as fh:
                    mine = fh.read()
                w = written[p]
                if isinstance(w, str):
                    with open(w, "rb") as fh:
                        w = fh.read()
                same = KEYWORD.sub(rb"$\1$", mine) == KEYWORD.sub(rb"$\1$", w)
            except OSError:
                same = False
        if not same:
            keep.append(p)
    return sorted(keep)


def _same_files(a: str, b: str) -> bool:
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        with open(a, "rb") as fa, open(b, "rb") as fb:
            while True:
                x, y = fa.read(1 << 20), fb.read(1 << 20)
                if x != y:
                    return False
                if not x:
                    return True
    except OSError:
        return False


def _unlike(src: Path, cands: list, run, left) -> list:
    """The paths of <cands> ((path, blob, size on disk)) whose bytes on disk are not the blob's as stored. One
    cat-file --batch for every name without a newline (cat-file's batch reads one name per line; with no --filters
    each header's size is the size of the bytes that follow); one call each for the others. A path whose bytes
    cannot be read or compared counts as unlike: say so rather than miss it."""
    found = []
    lined = [c for c in cands if "\n" not in c[0]]
    for p, b, _ in cands:
        if "\n" in p:
            code, out = run(["cat-file", "blob", b])
            if code != 0 or not _same_bytes(os.path.join(str(src), p), out):
                found.append(p)
    if not lined:
        return found
    proc = subprocess.Popen(git_argv(src, "cat-file", "--batch"), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0"))
    data = b"".join(b.encode() + b"\n" for _, b, _ in lined)

    def feed() -> None:
        try:
            proc.stdin.write(data)
            proc.stdin.close()
        except OSError:
            pass
    import threading
    threading.Thread(target=feed, daemon=True).start()
    try:
        for p, b, size in lined:
            left()
            head = proc.stdout.readline().split()
            if len(head) < 3 or not head[2].isdigit():
                found.append(p)
                continue
            n = int(head[2])
            same = n == size
            try:
                fh = open(os.path.join(str(src), p), "rb") if same else None
            except OSError:
                fh, same = None, False
            while n > 0:
                chunk = proc.stdout.read(min(n, 1 << 20))
                if not chunk:
                    raise OSError("git cat-file ended early")
                n -= len(chunk)
                if same and fh.read(len(chunk)) != chunk:
                    same = False
            if fh is not None:
                fh.close()
            proc.stdout.read(1)
            if not same:
                found.append(p)
    except OSError:
        found += [p for p, _, _ in lined if p not in found]
    finally:
        proc.kill()
        proc.wait()
    return found


def _same_bytes(path: str, data: bytes) -> bool:
    try:
        with open(path, "rb") as fh:
            return fh.read() == data
    except OSError:
        return False


def stat_blind(src: Path) -> bool:
    """Does git in <src> pass a file as unchanged on size, inode and mtime alone — core.trustctime false, or
    core.checkStat minimal? Then an edit that keeps the size and puts the mtime back is never looked at: ctime,
    which no one can set back, is the stat field that otherwise gives it away."""
    _, trust, _ = _git(src, "config", "--bool", "core.trustctime")
    _, check, _ = _git(src, "config", "core.checkStat")
    return trust.strip() == "false" or check.strip().lower() == "minimal"


def stat_blind_edits(src: Path, deadline: Optional[float] = None, skip: Optional[set] = None) -> list:
    """Tracked files of the worktree at <src> whose content is not their staged content although git's stat check
    passes them (stat_blind: an in-place edit of the same size with its mtime put back). git status and git add
    never read such a file again, and a checkout or reset writes the committed version over it, in no object.
    Only where git is stat_blind; there every tracked file's content is compared by git itself, as git status
    compares a file whose stat data changed: the staged entries are copied into a scratch index with no stat data,
    which git refresh then has to read by content — through the index, so a blob that already holds CRLF is not
    converted, as git add would not (hash-object, which reads no index, called such an untouched file changed for
    good: release-candidate red team 2, finding 6). Paths in <skip> are not read. Under <deadline>, raises
    subprocess.TimeoutExpired when it is out of time."""
    if not stat_blind(src):
        return []
    skip = skip or set()
    left, run = _checker(src, deadline)
    code, out = run(["ls-files", "-s", "-z"])
    if code != 0:
        return []
    keep, recs = set(), []
    for rec in out.split(b"\0"):
        meta, _, path = rec.partition(b"\t")
        bits = meta.split(b" ")
        if len(bits) != 3 or bits[2] != b"0" or bits[0] == b"160000":
            continue
        p = os.fsdecode(path)
        if p in skip:
            continue
        try:
            st = os.lstat(os.path.join(str(src), p))
        except OSError:
            continue            # deleted: git status names it
        if (stat.S_ISLNK(st.st_mode) if bits[0] == b"120000" else stat.S_ISREG(st.st_mode)):
            keep.add(p)
            recs.append(rec)
    if not recs:
        return []
    scratch = tempfile.mkdtemp(prefix="daedalus-index-")
    try:
        ix = {"GIT_INDEX_FILE": os.path.join(scratch, "index")}
        code, _ = run(["update-index", "-z", "--index-info"], b"".join(r + b"\0" for r in recs), ix)
        if code != 0:
            return sorted(keep)         # cannot tell: say so rather than miss it
        run(["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false", "-c", "core.untrackedCache=false",
             "update-index", "-q", "--refresh"], None, ix)
        code, out = run(["diff-files", "--name-only", "-z", "--ignore-submodules"], None, ix)
        if code != 0:
            return sorted(keep)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return sorted({os.fsdecode(x) for x in out.split(b"\0") if x} & keep)


def hidden_words(key: str, hidden: Dict[str, str]) -> Tuple[str, str, str]:
    """(the marks, the paths named, the commands that clear the marks) for a sentence about hidden_edits."""
    marks = sorted(set(hidden.values()))
    paths = sorted(hidden)
    cmds = []
    for mark in marks:
        mine = [p for p in paths if hidden[p] == mark]
        cmds.append("git -C target/%s update-index --no-%s %s" % (key, mark, shell_paths(mine)))
    return " or ".join(marks), name_paths(paths), ", and ".join(cmds)


def name_paths(paths: list, most: int = 5) -> str:
    return ", ".join(paths[:most]) + (" and %d more" % (len(paths) - most) if len(paths) > most else "")


def shell_paths(paths: list) -> str:
    """Every one of <paths>, quoted for a shell, for a command a sentence prints to be run as it is: never a
    placeholder, which a shell reads as a redirect (release-candidate red team, finding 4)."""
    return " ".join(shlex.quote(p) for p in paths)


ADOPT_UNTRACKED = ("target/%s has untracked files that resetting %s to origin/%s would overwrite (%s) — move them out "
                   "of that checkout, or commit them, then run adopt again; nothing was adopted.")


ADOPT_IGNORED = ("target/%s has ignored files that putting it back on %s at origin/%s would overwrite (%s) — move them out "
                 "of that checkout, then run adopt again; nothing was adopted.")


ADOPT_GITLINK = ("target/%s holds %s (%s), which %s would delete with everything in it — move %s out of that "
                 "checkout, then run adopt again; nothing was adopted.")


ADOPT_HIDDEN = ("target/%s has uncommitted changes git status does not show, in files marked %s (%s) — clear the mark "
                "(%s), commit them on their branch inside that checkout, then run adopt again; nothing was adopted.")


ADOPT_FILTERED = ("target/%s has changes git status does not show, in files whose line endings or contents git changes "
                  "when it saves them (%s) — their bytes on disk are in no commit, and adopting would replace them with "
                  "the committed version: copy those files out of that checkout, put the committed version back "
                  "(%s), then run adopt again; nothing was adopted.")


def put_back(key: str, paths: list) -> str:
    """The command that writes the committed version over <paths> in target/<key>. A checkout alone leaves a file
    git's stat check passes as it is — the very file a filtered edit is — so each is removed first (release-candidate
    red team, finding 4)."""
    q = shell_paths(paths)
    return "(cd target/%s && rm -f -- %s && git checkout -- %s)" % (key, q, q)


ADOPT_STAT_BLIND = ("target/%s has uncommitted changes git status does not show, in files whose content changed while "
                    "their size and times stayed as git last saw them (%s) — have git look at them again ((cd target/%s "
                    "&& touch %s)), commit them on their branch inside that checkout, then run adopt again; nothing "
                    "was adopted.")


class AdoptedPast(Refused):
    """adopt <branch> where a window was adopted from a branch of that name and <branch> has commits since that the
    window's lease/<NN> lacks: a start cut off after the window was made, then more commits on the branch
    (release-candidate red team 2, finding 3). Answering "already window <NN>" hid them: .nn, .subjects (oldest
    first), .rename (a free name for the branch)."""

    def __init__(self, msg: str, nn: str, subjects: list, rename: str):
        super().__init__(msg)
        self.nn, self.subjects, self.rename = nn, subjects, rename


ADOPT_PAST = ("%s in target/%s has %s that window %s, adopted from a branch of that name, does not have (%s) — adopting "
              "it would only name window %s again: give the branch another name (git -C target/%s branch -m %s %s), "
              "then run adopt again with that name%s; nothing was adopted.")


def free_branch_name(src: Path, branch: str) -> str:
    """<branch>-2, -3, ...: the first that is no branch in <src>."""
    n = 2
    while _git(src, "rev-parse", "--verify", "-q", "refs/heads/%s-%d" % (branch, n))[0] == 0:
        n += 1
    return "%s-%d" % (branch, n)


def adopted_past(src: Path, branch: str, nn: str) -> Optional[Tuple[list, str]]:
    """(subjects of <branch>'s commits lease/<NN> lacks, a free name for <branch>) when <branch> has any, else None —
    also None when <branch> is gone (its adoption finished)."""
    tip = ref_oid(src, "refs/heads/" + branch)
    if not tip or _git(src, "merge-base", "--is-ancestor", tip, "refs/heads/lease/" + nn)[0] == 0:
        return None
    code, out, _ = _git(src, "log", "--reverse", "--format=%s", "refs/heads/lease/%s..%s" % (nn, tip))
    return ([x for x in out.splitlines() if x.strip()] if code == 0 else []), free_branch_name(src, branch)


ADOPT_DETACHED = ("target/%s is on a detached HEAD (%s) holding commits no branch has; adopting %s would put the "
                  "checkout on %s and leave them behind — give them a branch inside that checkout "
                  "(git -C target/%s branch <name>), then run adopt again.")


def adopt(root: Path, branch: str, repo: Optional[str] = None, note: Optional[str] = None,
          fetch: bool = True, deadline: Optional[float] = None, checked: bool = False) -> dict:
    """`lease.sh adopt <branch> [--repo <nested>] [--note "..."]` (spec §4.2, §14 step 6): a branch of target/<repo>
    that carries work trunk does not have becomes a numbered window with no session bound — the same allocation
    `create` and `split` use. target/<repo> goes back to its trunk at origin/<trunk>; lease/<NN> is made at the
    branch's tip and checked out at worktrees/<NN>/<repo>, and the branch's own name is removed once the window is
    whole; the other repos' worktrees are cut at their trunks.
    `adopt <trunk>` moves a trunk that is ahead of origin: lease/<NN> is made at the trunk's tip, the window is
    made, and only then is the trunk reset; adopted_from names it daedalus/upgrade-<stamp>-<short sha> (plan 5
    Decision 14 — a label, no such branch is left). Idempotent: a branch already adopted returns {"already":
    True} while its window's lease/<NN> holds its tip, and is refused (AdoptedPast) once it has commits since;
    a trunk whose tip is a window's adopted_tip (a run cut off before the reset) is reset and returns "already". A lease/<NN> already at the adopted commit — an earlier adoption cut off before its lease file or
    its worktrees (release-candidate review 2, findings 11-12) — is finished as window <NN>, never adopted a
    second time. Refused: a dirty target/<repo> (tracked changes, or a change hidden by skip-worktree or
    assume-unchanged), an ignored file where the trunk's checkout or fast-forward would write, a branch that does
    not exist or is a live window's, nothing past trunk, a detached checkout holding commits no branch has. The fetch (a shell path, §4.2) runs
    before the lock; "pick it up" (upgrade.pick_up, `adopt --all-unfinished`) passes fetch=False — it fetched every
    target repo already. checked=True skips the read of target/<repo> for changes git status does not show
    (filtered_edits, stat_blind_edits), for a caller that read it before anything moved (release-candidate red
    team 3, finding 4).

    Order (plan 5 Task 2 review, finding 1): the first change is always making lease/<NN> at the work's tip — one
    new ref, the operator's branch (or the trunk) untouched — so a process killed at any later point leaves the
    work on its own branch and on lease/<NN>, and a re-run finishes that window. Never a rename: `git branch -m`
    is two ref writes and a HEAD write, and a git killed between them left the commit on no ref and the checkout on
    an unborn branch (release-candidate review 3, finding 9). The branch's own name goes last, after the lease file
    and the worktrees, and only while it still points at the adopted commit. A refusal before then undoes every
    change: the lease file, lease/<NN> (unless an earlier run made it), and target/<repo>'s checkout."""
    key = repo_key(root, repo)
    src = root / "target" / key
    if fetch:
        code, _, err = fetch_origin(src)
        if code != 0:
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("could not fetch origin in target/%s (%s); nothing was adopted" % (key, last[0]))

    def _last(err: str) -> str:
        return (err.strip().splitlines()[-1:] or ["no output"])[0]

    with lock(root, deadline=deadline, busy="the lease lock stayed busy; nothing was adopted"):
        leases = read_all(root)
        for nn, d in sorted(leases.items()):
            if nn != "prime" and d.get("adopted_from") == branch and d.get("adopted_repo") == key:
                # "already" only while lease/<NN> holds the branch's tip: commits made on it since (after a start cut
                # off between the window and the checkout back to the trunk) are no window's
                past = adopted_past(src, branch, nn)
                if past:
                    subjects, rename = past
                    raise AdoptedPast(ADOPT_PAST % (branch, key, "%d commit%s" % (len(subjects), "" if len(subjects) == 1
                                                                                   else "s"),
                                                    nn, ", ".join('"%s"' % x for x in subjects), nn, key, branch,
                                                    rename, " --repo %s" % repo if repo else ""),
                                      nn, subjects, rename)
                return {"nn": nn, "repo": key, "branch": branch, "trunk": (d.get("trunks") or {}).get(key, ""),
                        "subjects": [], "already": True, "notes": []}
        if LEASE_BRANCH.fullmatch(branch) and branch[len("lease/"):] in leases:
            raise Refused("%s is already a window's branch; nothing to adopt." % branch)
        # a lease/<NN> with no lease file — an earlier adoption cut off before it wrote one, or a swept window — is
        # adopted as window <NN> again, below (release-candidate review 2, finding 11)
        trunks = trunks_of(root, root / "target")
        trunk = trunks[key]
        twins = case_twins(src)
        if any(branch in g for g in twins):
            raise Refused(ADOPT_TWINS % (key, twins_words(twins), key, key, branch))
        code, _, _ = _git(src, "rev-parse", "--verify", "-q", "refs/heads/" + branch)
        if code != 0:
            raise Refused("target/%s has no branch %s." % (key, branch))
        # a submodule's own edits and untracked files are its work, named by the upgrade and doctor; they never
        # leave the checkout, and committing here cannot clear them (release-candidate review 4, finding 4)
        code, dirt, _ = _git(src, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=dirty")
        if code != 0 or dirt.strip():
            raise Refused(ADOPT_DIRTY % key)
        hidden = hidden_edits(src)
        if hidden:
            raise Refused(ADOPT_HIDDEN % ((key,) + hidden_words(key, hidden)))
        try:
            filtered = [] if checked else filtered_edits(src, deadline)
            blind = [] if filtered or checked else stat_blind_edits(src, deadline)
        except subprocess.TimeoutExpired:
            raise Refused("the time ran out while checking target/%s for changes git status does not show; nothing "
                          "was adopted" % key)
        if filtered:
            raise Refused(ADOPT_FILTERED % (key, name_paths(filtered), put_back(key, filtered)))
        if blind:
            raise Refused(ADOPT_STAT_BLIND % (key, name_paths(blind), key, shell_paths(blind)))
        _, cur, _ = _git(src, "branch", "--show-current")
        cur = cur.strip()
        _, head, _ = _git(src, "rev-parse", "HEAD")
        head = head.strip()
        # the branch's own commit, by its exact name: a bare name is a tag's when a tag has it too (review 4,
        # finding 2), and rev-parse answers for a case twin's loose file (finding 1) — the two must agree
        tip = ref_oid(src, "refs/heads/" + branch) or ""
        if not tip or _git(src, "rev-parse", "--verify", "-q", "refs/heads/" + branch)[1].strip() != tip:
            raise Refused("target/%s's branch %s cannot be read by its exact name; nothing was adopted." % (key, branch))
        notes = []
        is_trunk = branch == trunk
        # a directory recorded as a submodule, holding a repository or files git never looks into, where the trunk
        # has a file: the checkout or reset deletes it whole (release-candidate red team 3, findings 1 and 3)
        doing = ("resetting %s to origin/%s" % (trunk, trunk) if is_trunk and cur == trunk
                 else "putting it back on %s at origin/%s" % (trunk, trunk))
        moves = ([remote_ref(trunk)] if cur == trunk else [] if is_trunk
                 else ["refs/heads/" + trunk, remote_ref(trunk)])
        links = gitlinks_in_way(src, moves) if moves else {}
        if links:
            what, names, it = gitlink_words(links)
            raise Refused(ADOPT_GITLINK % (key, what, names, doing, it))
        if is_trunk and cur == trunk:
            # the trunk's reset is a `reset --hard`, which deletes an untracked file in its way without a word
            in_way = untracked_in_way(src, [remote_ref(trunk)])
            if in_way:
                raise Refused(ADOPT_UNTRACKED % (key, trunk, trunk, name_paths(in_way)))
        elif not is_trunk:
            # the checkout of the trunk and its fast-forward refuse over an untracked file, but write over an
            # ignored one (release-candidate review 2, finding 1)
            in_way = untracked_in_way(src, ([] if cur == trunk else ["refs/heads/" + trunk]) + [remote_ref(trunk)],
                                      ignored_only=True)
            if in_way:
                raise Refused(ADOPT_IGNORED % (key, trunk, trunk, name_paths(in_way)))
        if is_trunk:
            code, out, _ = _git(src, "log", "--reverse", "--format=%s", "%s..refs/heads/%s" % (remote_ref(trunk), trunk))
            subjects = [s for s in out.splitlines() if s.strip()] if code == 0 else []
            if not subjects:
                raise Refused("target/%s's %s has no commits that are not already on origin/%s — nothing to adopt."
                              % (key, trunk, trunk))
            for nn, d in sorted(leases.items()):
                # a run cut off after the window was made, before the trunk was reset: finish it
                if (nn != "prime" and d.get("adopted_repo") == key and d.get("adopted_tip") == tip
                        and str(d.get("adopted_from", "")).startswith("daedalus/upgrade-")):
                    code, _, err = git_finish(src, *_trunk_reset(cur, trunk))
                    if code != 0:
                        raise Refused("could not reset target/%s's %s to origin/%s (%s); window %s holds its commits"
                                      % (key, trunk, trunk, _last(err), nn))
                    return {"nn": nn, "repo": key, "branch": trunk, "trunk": trunk, "subjects": [], "already": True,
                            "notes": ["target/%s's %s was reset to origin/%s" % (key, trunk, trunk)]}
            # the window's name for the work: never the trunk's (plan 5 Decision 14) — so the "same-named branch
            # on origin" note cannot fire for a trunk, and a later trunk-ahead case is adopted again
            original = "daedalus/upgrade-%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), tip[:7])
        else:
            subjects = unpromoted_commits(src, trunk, "refs/heads/" + branch)
            if not subjects:
                raise Refused("%s in target/%s has no commits that are not already on origin/%s — nothing to adopt."
                              % (branch, key, trunk))
            if not cur and not _held_elsewhere(src, head):
                raise Refused(ADOPT_DETACHED % (key, head[:7], branch, trunk, key))
            original = branch
        # an earlier adoption of this same commit, cut off part-way, left lease/<NN> at it: with a lease file whose
        # worktree was never made, or with none yet. That window is finished here — never a second one made beside
        # it (release-candidate review 2, findings 11-12).
        nn, prior = _prior_adoption(src, key, tip, leases)
        resumed = nn is not None
        if nn is not None:
            new = "lease/" + nn
        else:
            nn = _adopt_number(root, leases, trunks)
            new = "lease/" + nn
            # the first change: lease/<NN> made at the work's tip, one new ref; the branch stays as it is until the
            # window is whole (review 3, finding 9)
            _clear_ref_lock(src, new)
            code, _, err = _git(src, "branch", new, tip)
            if code != 0:
                raise Refused("could not make lease/%s in target/%s (%s); nothing was adopted" % (nn, key, _last(err)))
        data = dict(prior) if prior else {
            "lease": nn, "session_id": None, "peer_name": None, "pid": None, "proc_started": None,
            "worktree": "worktrees/%s" % nn, "branch": new, "repos": list(trunks), "trunks": trunks,
            "created": now_stamp(), "bound_at": None, "promoted": [], "adopted_from": original,
            "adopted_repo": key, "adopted_tip": tip, "worktree_ready": False}
        if note and not prior:
            data["note"] = note
        # whether this call may remove the lease file on a refusal: decided before the write, so a signal between the
        # write and the next line still removes it (review 3, finding 7)
        wrote = prior is None and not lease_path(root, nn).exists()
        try:
            if prior is None:
                write_lease(root, nn, data, exclusive=True)
            if not is_trunk and cur != trunk:
                # off the branch (or wherever it was) before lease/<NN> is checked out in its worktree; never killed
                # part-way (review 4, finding 6)
                code, _, err = git_finish(src, "checkout", "--quiet", trunk)
                if code != 0:
                    raise Refused("could not put target/%s back on %s (%s); nothing was adopted"
                                  % (key, trunk, git_reason(err)))
            ready = add_worktrees(root, nn, trunks, deadline=deadline)
        except BaseException:
            if wrote:
                try:
                    os.unlink(str(lease_path(root, nn)))
                except OSError:
                    pass
            if not resumed:     # a resumed lease/<NN> was there before this call: it stays, holding the work
                _adopt_undo(root, trunks, src, key, nn, cur, head)
            raise
        if ready:
            data.pop("worktree_ready", None)
            write_lease(root, nn, data)
        write_changed(root, nn, {})
        heartbeat(root, nn)
        # last: target/<repo> to origin/<trunk>. For a trunk this is the reset — lease/<NN> and the lease file
        # already hold the commits; a re-run finishes a reset that did not happen (above).
        if is_trunk:
            code, _, err = git_finish(src, *_trunk_reset(cur, trunk))
            if code != 0:
                notes.append("target/%s's %s could not be reset to origin/%s (%s) and still holds these commits too; "
                             "run adopt %s again to finish" % (key, trunk, trunk, _last(err), trunk))
        else:
            # the branch's own name, and any label Daedalus gave the same commit, go now that lease/<NN> and the
            # window hold it (review 3, finding 9)
            left = _drop_names(src, key, tip, new, [branch])
            if left:
                notes.append(left)
            code, _, err = _git(src, "merge", "--ff-only", "--quiet", remote_ref(trunk))
            if code != 0:
                notes.append("target/%s's %s could not be fast-forwarded to origin/%s (%s)"
                             % (key, trunk, trunk, _last(err)))
            code, _, _ = _git(src, "rev-parse", "--verify", "-q", "refs/remotes/origin/" + original)
            if code == 0:
                notes.append("a branch named %s on origin was left alone" % original)
    return {"nn": nn, "repo": key, "branch": original, "trunk": trunk, "subjects": subjects, "already": False,
            "notes": notes}


def _drop_names(src: Path, key: str, tip: str, new: str, names: list) -> str:
    """Delete each of <names> (and every daedalus/upgrade-* label) that still points at <tip>, once lease/<NN> (<new>)
    holds <tip>: the names an adoption replaces. Each is read and deleted by its exact name, and only while its
    listing and rev-parse agree on <tip> (`update-ref -d <ref> <tip>`): where git ignores case, `branch -D Wip` also
    unlinked a loose refs/heads/wip holding other work (release-candidate review 4, finding 1). A branch checked out
    in a worktree is left and named in the returned note ("" when none is)."""
    if _git(src, "merge-base", "--is-ancestor", tip, "refs/heads/" + new)[0] != 0:
        return ""
    _, labels, _ = _git(src, "for-each-ref", "--format=%(refname:lstrip=2) %(objectname)", "refs/heads/daedalus/")
    cands = [b for b in names if b and b != new]
    cands += [b for b, _, sha in (ln.partition(" ") for ln in labels.splitlines())
              if b.startswith("daedalus/upgrade-") and sha.strip() == tip and b not in cands]
    _, wl, _ = _git(src, "worktree", "list", "--porcelain")
    out_there = {ln[len("branch refs/heads/"):] for ln in wl.splitlines() if ln.startswith("branch refs/heads/")}
    kept = []
    for b in cands:
        ref = "refs/heads/" + b
        if ref_oid(src, ref) != tip or _git(src, "rev-parse", "--verify", "-q", ref)[1].strip() != tip:
            continue
        if b in out_there or _git(src, "update-ref", "-d", ref, tip)[0] != 0:
            kept.append(b)
    if not kept:
        return ""
    return ("%s, checked out in another worktree, was left as it was in target/%s; window %s holds its commits"
            % (" and ".join(kept), key, new[len("lease/"):]))


def _prior_adoption(src: Path, key: str, tip: str, leases: Dict[str, dict]) -> Tuple[Optional[str], Optional[dict]]:
    """(NN, its lease) of an adoption of commit <tip> from target/<key> that an earlier run began and was cut off
    in: a lease file adopted at <tip> whose worktree was never made, its lease/<NN> still at <tip>; else (NN, None)
    for a lease/<NN> at <tip> with no lease file — made, or renamed, before the lease file was written (or a swept
    window's, which adopting again revives). (None, None) when there is neither."""
    def at(nn: str) -> bool:
        code, out, _ = _git(src, "rev-parse", "--verify", "-q", "refs/heads/lease/" + nn)
        return code == 0 and out.strip() == tip
    for nn, d in sorted(leases.items()):
        if (nn != "prime" and d.get("adopted_repo") == key and d.get("adopted_tip") == tip
                and d.get("worktree_ready") is False and not d.get("session_id") and at(nn)):
            return nn, d
    code, out, _ = _git(src, "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/lease/")
    for ln in (out.splitlines() if code == 0 else []):
        ref, _, sha = ln.partition(" ")
        nn = ref[len("refs/heads/lease/"):]
        if (LEASE_BRANCH.fullmatch(ref[len("refs/heads/"):]) and valid_id(nn) and nn not in leases
                and sha.strip() == tip):
            return nn, None
    return None, None


def finish_adopted(root: Path, key: str, deadline: Optional[float] = None) -> list:
    """Each window adopted from target/<key> with no session whose worktree was never made — a start cut off
    between its lease file and the end of its worktrees (release-candidate review 2, findings 12-13): target/<key>
    is put back on its trunk if it is still on lease/<NN> or detached at the adopted commit, the worktrees are
    added, and the lease is marked ready. Returns [(NN, finished)] — finished False when the worktrees ran out of
    the deadline's time. Refused when the checkout cannot be moved or a worktree add fails."""
    src = root / "target" / key
    done = []
    with lock(root, deadline=deadline, busy="the lease lock stayed busy; the window was not finished"):
        leases = read_all(root)
        for nn, d in sorted(leases.items()):
            if (nn == "prime" or d.get("adopted_repo") != key or d.get("worktree_ready") is not False
                    or d.get("session_id")):
                continue
            new = "lease/" + nn
            if _git(src, "rev-parse", "--verify", "-q", "refs/heads/" + new)[0] != 0:
                continue
            trunks = trunks_of(root, root / "target")
            trunk = trunks.get(key) or (d.get("trunks") or {}).get(key)
            _, cur, _ = _git(src, "branch", "--show-current")
            _, head, _ = _git(src, "rev-parse", "HEAD")
            tip, orig = d.get("adopted_tip"), str(d.get("adopted_from") or "")
            on_orig = cur.strip() == orig and orig != trunk and ref_oid(src, "refs/heads/" + orig) == tip
            if cur.strip() == new or on_orig or (not cur.strip() and head.strip() == tip):
                code, _, err = git_finish(src, "checkout", "--quiet", trunk)
                if code != 0:
                    raise Refused("could not put target/%s back on %s (%s)" % (key, trunk, git_reason(err)))
            if not add_worktrees(root, nn, trunks, deadline=deadline):
                done.append((nn, False))
                continue
            d.pop("worktree_ready", None)
            write_lease(root, nn, d)
            heartbeat(root, nn)
            done.append((nn, True))
        # the branch's own name (and its labels) an adoption cut off after its window was made left behind: removed
        # as that adoption would have (review 3, finding 9)
        for nn, d in sorted(read_all(root).items()):
            if nn == "prime" or d.get("adopted_repo") != key or not d.get("adopted_tip"):
                continue
            _drop_names(src, key, str(d["adopted_tip"]), "lease/" + nn, [str(d.get("adopted_from") or "")])
    return done


def _trunk_reset(cur: str, trunk: str) -> tuple:
    """The git arguments that put <trunk> at origin/<trunk>: a hard reset when it is checked out (the checkout
    is clean — adopt refused otherwise), else a forced branch move."""
    return (("reset", "--hard", "--quiet", remote_ref(trunk)) if cur == trunk
            else ("branch", "-f", trunk, remote_ref(trunk)))


def _adopt_undo(root: Path, trunks: Dict[str, str], src: Path, key: str, nn: str, cur: str, head: str) -> None:
    """Best effort, after a refusal. In every repo, a worktree at worktrees/<NN>/<repo> on lease/<NN> is removed
    (only this call can have made one: lease/<NN> existed nowhere before it — _adopt_number; git refuses a dirty
    one), and lease/<NN> is deleted: cut here from origin/<trunk>, or in target/<repo> made at the work's tip, which
    the branch (or the trunk) still holds — nothing was renamed (review 3, finding 9). The checkout goes back where
    it was. Anything git refuses is left as it is: lease/<NN> then still holds the work too, and the next adoption
    of it finishes that window."""
    new = "lease/" + nn
    for repo in reversed(list(trunks)):      # nested first: they sit inside the outer worktree
        rsrc = root / "target" / repo
        dest = root / "worktrees" / nn / repo
        code, listed, _ = _git(rsrc, "worktree", "list", "--porcelain")
        if code == 0 and dest.exists() and _registered(listed, dest):
            _, on, _ = _git(dest, "branch", "--show-current")
            if on.strip() == new:
                _git(rsrc, "worktree", "remove", str(dest))
        _git(rsrc, "branch", "-D", new)
    _, now, _ = _git(src, "branch", "--show-current")
    if cur and now.strip() != cur:
        _git(src, "checkout", "--quiet", cur)
    elif not cur:
        _, nowsha, _ = _git(src, "rev-parse", "HEAD")
        if now.strip() or nowsha.strip() != head:
            _git(src, "checkout", "--quiet", "--detach", head)


def adopt_sentence(r: dict) -> str:
    if r["already"] and r["notes"]:
        return "%s in target/%s is already window %s; %s." % (r["branch"], r["repo"], r["nn"], "; ".join(r["notes"]))
    if r["already"]:
        return "%s in target/%s is already window %s; nothing to do." % (r["branch"], r["repo"], r["nn"])
    n = len(r["subjects"])
    s = ("Window %s now holds %s from target/%s (%d commit%s: %s) on branch lease/%s; target/%s is on %s at origin/%s."
         % (r["nn"], r["branch"], r["repo"], n, "" if n == 1 else "s", _quoted(r["subjects"]), r["nn"], r["repo"],
            r["trunk"], r["trunk"]))
    if r["notes"]:
        s += " Note: %s." % "; ".join(r["notes"])
    return s


def mark_done(root: Path, token: str, sid: str, summary: str) -> str:
    """A spawned clone reports completion: finished: <time> and summary: in
    the lease, holder only, under the lock. The board renders FINISHED from
    those fields and sweep spares the lease until promote or release (§4.2).
    Recorded deviation: SendMessage is a tool the model calls, not a script,
    so this prints the line to send and the prime's peer name."""
    with lock(root):
        leases = read_all(root)
        nn = number_of(leases, token, "done")
        lease = leases.get(nn)
        if lease is None or lease.get("session_id") != sid:
            raise Refused("Only window %s's own session may mark it done." % nn)
        lease["finished"] = now_stamp()
        lease["summary"] = summary
        lease.pop("task", None)     # the summary says what it did; a task left up would draw overlap messages to a session that ended
        write_lease(root, nn, lease)
        prime = leases.get("prime") or {}
    _, prime_lease = lease_of_session(leases, str(prime.get("session_id")))
    prime_peer = peer_of(prime_lease) if prime_lease else "unknown"
    what = "%s (a spawned clone)" % window_label(nn, lease) if lease.get("spawned") else window_label(nn, lease)
    return ("This is %s, finished: %s. Promote or release it.\n"
            "(Send that line to the prime — peer name %s — with SendMessage if the board shows it live.)"
            % (what, summary, prime_peer))


def record_promotion(root: Path, nn: str, promote_id: str) -> None:
    """§7.2 step 7: the lease file's `promoted` list gains the promote id, under
    the leases lock, by whichever process ran the confirm."""
    with lock(root):
        lease = read_lease(root, nn)
        if lease is None:
            return
        if promote_id in (lease.get("promoted") or []):
            return                             # once per promotion (plan 4 Decision 47)
        lease["promoted"] = (lease.get("promoted") or []) + [promote_id]
        write_lease(root, nn, lease)

# v0.12.7 (PROP-029, 2026-10-19): a swept window's worktree and branch go with its lease when nothing would be lost.
# `sweep` removed window 04's lease and kept worktrees/04/atlas and lease/04; the unpromoted window then read "There is
# no window 04", so `release --remove` could not run, and nothing in Daedalus removed them. Claim and reclaim of an
# idle window still keep them, for re-use; only a sweep of a released or stale window (by hand, at a start, at the
# session's end) clears them.
SWEPT_TREES = "state/swept-trees"      # where a window's worktrees are moved, in one rename, before they are deleted


def _plural(n: int, word: str) -> str:
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def swept_tree_checks(root: Path, nn: str, lease: dict, timeout: int = 20) -> list:
    """Why a swept window's worktrees and lease/<NN> must stay, one sentence per failed check; [] when they may go.
    Per repository of the window: the worktree has no uncommitted and no untracked file that git does not ignore
    (dirty_files — an ignored file is a merged branch's build output, not work); git's record of it holds nothing
    no branch does and is not locked (record_holds, the rule prune_under keeps); lease/<NN>'s tip is reachable from
    origin/<trunk>, the ref promote and `unpromoted` judge by (waiting_work); and a checkout whose HEAD is not
    lease/<NN> holds no commit trunk lacks. Anything that cannot be told is a reason to keep, named — cannot tell is
    not "nothing". And worktrees/<NN> holds nothing but the window's repositories."""
    trunks = lease.get("trunks") or {}
    base = root / "worktrees" / nn
    out = []
    if base.is_dir():
        tops = {r.split("/", 1)[0] for r in trunks}
        try:
            other = sorted(p.name for p in base.iterdir() if p.name not in tops)
        except OSError as e:
            other = ["(it cannot be listed: %s)" % e]
        if other:
            out.append("kept worktrees/%s: it holds %s, which is none of the window's repositories" % (nn, name_paths(other)))
    for repo, trunk in trunks.items():
        src, dest = root / "target" / repo, base / repo
        where = "" if repo == next(iter(trunks)) else " in %s" % repo
        try:
            files = dirty_files(dest, timeout=timeout)
            if files:
                out.append("kept worktrees/%s/%s: %s" % (nn, repo, _plural(len(files), "uncommitted file")))
        except Refused as e:
            out.append("kept worktrees/%s/%s: %s" % (nn, repo, e))
        if dest.is_dir():
            admin = worktree_records(src).get(os.path.realpath(str(dest)))
            if admin is not None:
                holds = record_holds(admin) + (["a lock"] if (admin / "locked").exists() else [])
                if holds:
                    out.append("kept worktrees/%s/%s: git's record of it holds %s" % (nn, repo, " and ".join(holds)))
        try:
            subjects = waiting_work(src, trunk, nn, timeout=timeout)
            if subjects:
                out.append("kept lease/%s%s: %s not on %s" % (nn, where, _plural(len(subjects), "commit"), trunk))
        except Refused as e:
            out.append("kept lease/%s%s: %s" % (nn, where, e))
        if dest.is_dir():
            code, head, _ = _git(dest, "rev-parse", "--verify", "-q", "HEAD", timeout=timeout)
            head = head.strip()
            if code == 0 and head and head != ref_oid(src, "refs/heads/lease/%s" % nn):
                code, n, err = _git(dest, "rev-list", "--count", "%s..%s" % (remote_ref(trunk), head), timeout=timeout)
                if code != 0:
                    out.append("kept worktrees/%s/%s: cannot tell whether its checkout holds commits %s lacks (%s)"
                               % (nn, repo, trunk, _last_line(err)))
                elif n.strip() not in ("", "0"):
                    out.append("kept worktrees/%s/%s: its checkout holds %s not on %s"
                               % (nn, repo, _plural(int(n.strip()), "commit"), trunk))
    return out


def remove_swept_trees_locked(root: Path, nn: str, lease: dict, timeout: int = 20) -> Optional[str]:
    """Delete a swept window's worktrees and lease/<NN> in every repository, once swept_tree_checks found nothing
    to keep. None when done, else the sentence saying what is left. worktrees/<NN> is first moved aside whole, in
    one rename, to state/swept-trees/ — so a hook cut off by its timeout (the session's end has three seconds)
    leaves either the worktrees as they were or a directory nothing reads, never a half-deleted checkout git still
    records; then each repository's records of the gone directory are pruned (prune_under, under worktrees/ only),
    lease/<NN> deleted (its tip is on trunk: checked), the number's unpromoted-work answers dropped, and last the
    moved directory deleted — what a cut-off delete left there is deleted at the next sweep. CALLER HOLDS THE
    LOCK, and calls this before the lease files go (prune_under knows a window's record by them)."""
    trunks = lease.get("trunks") or {}
    trash_root = root / SWEPT_TREES
    if trash_root.is_dir():
        for old in trash_root.iterdir():
            shutil.rmtree(str(old), ignore_errors=True)
    base = root / "worktrees" / nn
    trash = None
    if base.exists():
        trash = trash_root / ("%s-%d" % (nn, time.time_ns()))
        try:
            trash_root.mkdir(parents=True, exist_ok=True)
            os.rename(str(base), str(trash))
        except OSError as e:
            return "kept worktrees/%s: it could not be moved aside to be deleted (%s)" % (nn, e)
    for repo in reversed(list(trunks)):          # nested repos first, as release --remove goes
        src = root / "target" / repo
        prune_under(src, root / "worktrees")
        if ref_oid(src, "refs/heads/lease/%s" % nn) is not None:
            code, _, err = _git(src, "branch", "-D", "lease/%s" % nn, timeout=timeout)
            if code != 0:
                return "kept lease/%s in %s: git branch -D failed (%s)" % (nn, repo, _last_line(err))
    write_unpromoted_cache(root, {}, keep=lambda k: k.partition(" ")[0] != nn)
    if trash is not None:
        shutil.rmtree(str(trash), ignore_errors=True)
    return None


def clear_swept_trees_locked(root: Path, nn: str, lease: dict, timeout: int = 20) -> Tuple[bool, list]:
    """swept_tree_checks, then remove_swept_trees_locked when they found nothing to keep: (removed, the sentences
    naming what was kept and why). CALLER HOLDS THE LOCK; before the lease files go."""
    if not (lease.get("trunks") or {}):
        return False, []
    kept = swept_tree_checks(root, nn, lease, timeout=timeout)
    if kept:
        return False, kept
    failed = remove_swept_trees_locked(root, nn, lease, timeout=timeout)
    return (False, [failed]) if failed else (True, [])


def swept_words(removed: bool, kept: list) -> str:
    """The tail of a sweep's line for the window's worktrees and branch."""
    if removed:
        return ", and its worktree and branch: nothing uncommitted, nothing trunk lacks"
    if kept:
        return "; kept its worktree and branch — " + "; ".join(kept)
    return "; its worktree and branch are kept"


def sweep(root: Path, force_nn: Optional[str] = None) -> list:
    """Remove stale and released lease files. A quiet one only as --force <NN>
    (the operator's word); a finished one waits for promote or release (or
    --force); a resumed one (dead recorded pid, session id live in the
    registry) is rebound, never removed; a plainly live one is refused even
    forced. A removed window's worktrees and lease/<NN> go too when nothing
    would be lost — clean, and its tip on trunk (v0.12.7, PROP-029:
    clear_swept_trees_locked); otherwise they are kept, and the line names
    the check that kept them. Returns the lines."""
    lines = []
    with lock(root):
        leases = read_all(root)
        if force_nn is not None:
            # --force takes a number like every other lease position (§4.1):
            # an alias is refused naming the number; a number with no lease is
            # refused, never ignored with a clean exit (Task 4 review).
            force_nn = number_of(leases, force_nn, "sweep --force")
            if force_nn not in leases:
                raise Refused("There is no window %s." % force_nn)
        now = time.time()
        quiet_after = stale_after_secs(root)
        for nn in sorted(k for k in leases if k != "prime"):
            lease = leases[nn]
            state = liveness(root, nn, lease, now=now, quiet_after=quiet_after)
            forced = force_nn == nn
            if state == "resumed":
                self_rebind(root, str(lease.get("session_id")))
                pids = [e.get("pid") for e in registry_live_entries(str(lease.get("session_id")))]
                lines.append("window %s: resumed in pid %s; rebinding instead" % (nn, pids[0] if pids else "?"))
                continue
            if lease.get("released"):
                why = "released"
            elif forced and state == "live":
                lines.append("window %s is live in pid %s — not removed; say 'release %s' to that window, or close it first"
                             % (nn, lease.get("pid"), nn))
                continue
            elif forced:
                why = "%s, removed on --force" % state
            elif lease.get("finished"):
                lines.append("window %s finished (%s) — kept until you promote %s or release %s"
                             % (nn, lease.get("summary") or "no summary", nn, nn))
                continue
            elif state == "stale":
                why = "stale"
            elif state == "quiet":
                lines.append("window %s is quiet (its window is still open) — not swept; use `sweep --force %s` "
                             "if the operator says so" % (nn, nn))
                continue
            else:
                continue
            removed, kept = clear_swept_trees_locked(root, nn, lease)
            _remove_lease_files(root, nn)
            carry_hot_locked(root, nn, leases)
            lines.append("removed the lease of window %s (%s)%s" % (nn, why, swept_words(removed, kept)))
    return lines


SESSION_END_LOCK_WAIT = 1.0     # seconds; SessionEnd's hooks share a short budget (the settings.json timeout raises it)
SESSION_END_GIT_SECS = 1        # seconds for each git call of the session end's worktree check (PROP-029)


def session_end_sweep(root: Path, sid: Optional[str]) -> Optional[str]:
    """SessionEnd (2026-10-19, the operator: no sweep by hand): the ending session's own lease is removed when it is
    released — the hold `release` leaves is for this session's hooks, and this is the last of them. What `sweep`
    does for a released lease and no more: the worktree and branch go too only when nothing would be lost (v0.12.7,
    clear_swept_trees_locked), and unpromoted work on lease/<NN> keeps them and the number (free_number). Never another session's lease, never an unreleased one (a window closed without release
    is reclaim's or the board's), never makes state/leases/, and gives up when the lock stays busy past
    SESSION_END_LOCK_WAIT (Refused; the next terminal start sweeps it — reclaim_idle_locked). Returns the number."""
    if not sid or not leases_dir(root).is_dir():
        return None
    with lock(root, deadline=time.time() + SESSION_END_LOCK_WAIT, busy="the lease lock stayed busy at session end"):
        nn, lease = lease_of_session(read_all(root), sid)
        if nn is None or not (lease or {}).get("released"):
            return None
        if len(registry_live_entries(sid)) > 1:
            # the session is open in another terminal too (claude --resume): that one's hooks still read the lease;
            # it goes when the last of them ends, or at a start once none is live (review 2026-10-19, finding 2)
            return None
        try:
            # v0.12.7 (PROP-029): the worktree and branch go too when nothing would be lost; a git call gets a second,
            # and the delete itself is a rename then a prune, so the hook's three seconds never cut a checkout in half
            clear_swept_trees_locked(root, nn, lease or {}, timeout=SESSION_END_GIT_SECS)
        except Exception:
            pass
        _remove_lease_files(root, nn)
        carry_hot_locked(root, nn, {k: d for k, d in read_all(root).items()})
        return nn


def spawn(root: Path, task: str, note: Optional[str]) -> str:
    """create + launch a --bg clone on the next free number, spawned: true;
    the number reaches the clone as DAEDALUS_LEASE and its task always ends
    with the `done` instruction, so it is never hand-typed (§4.2)."""
    import subprocess
    target = root / "target" / target_name(root)
    fetch_origin(target, timeout=60)
    # the first line that says something: not blank and not a markdown heading ("# Context")
    first = next((ln for ln in task.splitlines() if ln.strip() and not ln.lstrip().startswith("#")), "")
    nn, _ = allocate(root, None, note=note, spawned=True, task=task_line(first) or None)
    full = ('%s\n\nWhen the work is done or you are stuck, run `core/lease.sh done %s --summary "<one paragraph: what changed, '
            'what is untested, what you need>"` as your final action.' % (task, nn))
    env = dict(os.environ, DAEDALUS_LEASE=nn)
    try:
        subprocess.Popen(["claude", "--bg", "--name", "daedalus-%s" % nn, full], cwd=str(root), env=env,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as e:
        with lock(root):
            _remove_lease_files(root, nn)   # the worktree stays; the next allocation adopts it
        raise Refused("could not start claude for window %s (%s); the number is free again" % (nn, e.strerror or e))
    return "Window %s is a background clone working on %s; it will report on the board when done." % (nn, task)


# --- SessionStart binding (§4.2 steps 1–6, §4.8 first-up) ---------------------

def is_terminal_window(sid: str) -> bool:
    """The §4.8 test: the registry pair (kind=interactive, entrypoint=cli) for
    THIS session id. No registry -> False: a hook process has no controlling
    terminal (Claude Code docs: hooks "can't open /dev/tty"), so there is no
    weaker test to fall back to; a registry-absent build binds windows with
    DAEDALUS_LEASE and takes the pen with `core/lease.sh prime take`."""
    if not registry_present():
        return False
    return is_interactive_window(registry_entry_for(sid))


def prime_holder_live(root: Path, leases: Dict[str, dict], holder: str) -> Tuple[bool, Optional[str], Optional[dict]]:
    """Is the pen's holder still a live session? (live, hnn, hlease). Two legs,
    both required (§4.8 'refuses when the current holder is live'): the
    holder's numbered lease, when it has one, judged by liveness(); and,
    when it holds ONLY the pen — reachable because `release <NN>` keeps the
    pen (§4.4) and sweep (or session end, or a start's reclaim once its
    session has ended) removes a released lease before it looks at
    liveness — the registry, through the same live-entry check liveness()
    uses for "resumed". Judging by the lease alone called a live prime-only
    holder "gone", and both prime take and first-up rebound the pen under
    it with no reason recorded (Task 7 review)."""
    hnn, hlease = lease_of_session(leases, holder)
    if hlease is not None:
        return liveness(root, hnn, hlease) in HELD_BY_LIVE, hnn, hlease
    return bool(registry_live_entries(holder)), None, None


def first_up(root: Path, sid: str) -> bool:
    """Caller holds the lock. O_EXCL prime.json; a stale prime is rebound by CAS."""
    prime = read_lease(root, "prime")
    if prime is None:
        try:
            write_lease(root, "prime", dict({"session_id": sid, "history": []}, **pen_bound()), exclusive=True)
            return True
        except FileExistsError:
            return False
    holder = prime.get("session_id")
    if holder == sid:
        return True
    if prime_holder_live(root, read_all(root), str(holder))[0]:
        return False
    fresh = read_lease(root, "prime") or {}
    if fresh.get("session_id") != holder:
        return False
    fresh["history"] = (fresh.get("history") or []) + [{"from": holder, "to": sid, "at": now_stamp(),
                                                        "reason": "first-up (previous holder gone)"}]
    fresh.pop("logs", None)      # a pen-only reservation was the gone holder's, like a window's on takeover
    fresh.pop("taken_without_window", None)
    fresh.pop("taken_while_pending", None)
    fresh.update(dict({"session_id": sid}, **pen_bound()))
    write_lease(root, "prime", fresh)
    return True


def session_start_bind(root: Path, sid: str, deadline: Optional[float] = None, new_day: bool = True) -> dict:
    """Returns {"lease": NN|None, "prime": bool, "took_pen": bool, "numbered": bool, "notes": [..],
    "log": <the session-log path, reserved>|None}. `new_day` False (a compaction, a clear) returns the
    log the session opened with instead of reserving today's (log_path_locked).
    Order per §4.2: hint bind -> self-rebind -> auto-number (terminal windows only) -> first-up.
    ONE lock around the whole sequence; everything called inside is a *_locked /
    "caller holds the lock" function (allocate_locked, bind, self_rebind, first_up).
    `deadline` (epoch seconds) is the moment every worktree git call must stop —
    SessionStart's budget less the marker's share (§4.2) — on the
    `DAEDALUS_LEASE` bind and the auto-number alike. The wait for the lease lock
    is bounded by the same deadline: still busy then, it raises
    Refused(LOCK_BUSY_AT_START) having written nothing (plan 2 Decision 18)."""
    out = {"lease": None, "prime": False, "took_pen": False, "numbered": False, "notes": [], "log": None}
    terminal = is_terminal_window(sid)
    hint = os.environ.get("DAEDALUS_LEASE", "").strip()
    if hint and not valid_id(hint):
        # Every command that takes a lease takes its NUMBER (§4.2). Unvalidated,
        # `DAEDALUS_LEASE=prime` bound prime.json as a lease — the pen moved
        # without `prime take` (§4.8) — and a path rewrote whatever JSON it
        # named under the home (Task 6 review).
        out["notes"].append(bad_hint_sentence(hint) + "; it was ignored.")
        hint = ""
    with lock(root, deadline=deadline, busy=LOCK_BUSY_AT_START):
        held, _ = lease_of_session(read_all(root), sid)
        if hint and held is not None and held != hint:
            # One lease per session, the rule claim() enforces, holds on the
            # hook path too: a `claude --resume` from a shell that still
            # exports an older window's number must not make this session the
            # holder of two numbers (Task 6 review). self_rebind below keeps it
            # on the window it already is.
            out["notes"].append("`DAEDALUS_LEASE=%s` ignored: this session is already window %s (the lease files are "
                                "the truth)." % (hint, held))
            hint = ""
        if hint:
            lease = read_lease(root, hint)
            if lease is None:
                out["notes"].append("`DAEDALUS_LEASE=%s` names no lease file; run `core/lease.sh create` for a number "
                                    "and `claim` it." % hint)
            else:
                try:
                    bind(root, hint, sid, deadline=deadline)
                    out["lease"] = hint
                except Refused as e:
                    # §4.2's exact line: "`DAEDALUS_LEASE=02` ignored: window 02 is held by a live session (peer name …)"
                    # — bind's sentence starts "Window …"; one source for the sentence, lowercased in the clause.
                    why = str(e).replace("Say 'release %s' to that window, or close it first." % hint, "").strip()
                    msg = "`DAEDALUS_LEASE=%s` ignored: %s" % (hint, why[:1].lower() + why[1:])
                    if not terminal:
                        msg += " Run `core/lease.sh create` for a new number and `claim` it, or stop the other session."
                    out["notes"].append(msg)
        if out["lease"] is None:
            out["lease"] = self_rebind(root, sid)
        if terminal:
            # Every terminal start reclaims the idle windows, not only one that
            # numbers itself: a resumed window (self_rebind above) never
            # allocates, and without this pass yesterday's STALE window would
            # sit on its board at every prompt until a sweep. A trunk that
            # cannot be told is allocate_locked's refusal to make, not this
            # pass's — it skips, and the bind goes on.
            try:
                for _nn, sentence in reclaim_idle_locked(root, read_all(root), trunks_of(root, root / "target"),
                                                         deadline=deadline):
                    out["notes"].append(sentence)
            except Refused:
                pass
        if out["lease"] is None and terminal:
            nn, data = allocate_locked(root, sid, deadline=deadline, notes=out["notes"],
                                       reclaimed=True)              # NOT allocate(): the lock is held here
            try:
                bind(root, nn, sid, finish_worktree=False)
            except Refused:
                pass
            out["lease"], out["numbered"] = nn, True
        if terminal and out["lease"] is not None:
            was = (read_lease(root, "prime") or {}).get("session_id") == sid
            out["prime"] = first_up(root, sid)
            out["took_pen"] = out["prime"] and not was
        else:
            out["prime"] = (read_lease(root, "prime") or {}).get("session_id") == sid
        # The session-log number, reserved here under the same lock (§4.7 D7 as
        # amended): the start says the path, so no session ever counts the directory.
        # A number reserved while the session held no window moves into the window it holds now (carry), so the
        # start says the number the session was already told.
        key = out["lease"] or ("prime" if out["prime"] else None)
        if key is not None:
            try:
                leases = read_all(root)
                today = time.strftime("%Y-%m-%d")
                if key == "prime":
                    out["log"] = session_log_locked(root, sid, leases, today, new_day=new_day)
                elif key in leases:
                    carry_unwindowed_locked(root, sid, key, leases, today)
                    out["log"] = log_path_locked(root, key, leases, today, new_day=new_day)
            except Refused as e:
                out["notes"].append(str(e))
    return out


# --- Session logs (§4.7 D7, amended 2026-10-14) ------------------------------
# One global counter per vault: vault/sessions/YYYY/MM/YYYY-MM-DD-NNN.md. The
# number is reserved in the session's lease file (logs: {"<date>": N}) under
# the exclusive lease lock — at session start, and by `core/lease.sh log` —
# never computed from a directory listing at close, where two windows open on
# one day count the same next number (D7's collision). The operator's ruling of
# 2026-10-14 keeps the counter they navigate by; the window number lives in the
# frontmatter only. A window-numbered log of v0.7.0 (a two-digit tail) and a
# prime log are not part of the sequence and are not counted.

LOG_FILE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}-([0-9]{3,})\.md$")
LOG_NEEDS_SESSION = ("`core/lease.sh log` names the calling session's log for today; run it from a session, "
                     "not from an operator shell.")


def _max_log_number(root: Path, leases: Dict[str, dict], unwindowed: Optional[dict] = None) -> int:
    """The highest number in the sequence: in the vault's files, or reserved in
    any lease file (prime.json included), or for a session holding no window
    (unwindowed.json), for a log not written yet, whatever day it was reserved
    for. An unwindowed.json that cannot be read refuses (no counting around it)."""
    n = 0
    sdir = root / "vault" / "sessions"
    if sdir.is_dir():
        for path in sdir.glob("*/*/*.md"):
            m = LOG_FILE_RE.match(path.name)
            if m:
                n = max(n, int(m.group(1)))
    for lease in leases.values():
        for val in _reservations(lease).values():
            n = max(n, val)
    for entry in (read_unwindowed(root) if unwindowed is None else unwindowed).values():
        if isinstance(entry, dict):
            for val in _reservations(entry).values():
                n = max(n, val)
    return n


# The log reservations of sessions holding no window: {"<session id>": {"logs": {"<date>": N}}}. Its own file, so
# read_all (which reads only prime.json and numbered files) and every reader of the lease files never see it.
UNWINDOWED = "unwindowed"
UNWINDOWED_UNREADABLE = ("state/leases/unwindowed.json cannot be read (%s). Fix or remove it; it holds only "
                         "session-log reservations.")
UNWINDOWED_KEEP_DAYS = 7      # a build with no session registry cannot tell a live session: an entry this old goes


def read_unwindowed(root: Path) -> dict:
    """unwindowed.json, {} when it does not exist. Caller holds the lock. A file
    that cannot be read, or is not a JSON object, raises Refused by name."""
    try:
        text = lease_path(root, UNWINDOWED).read_text()
    except FileNotFoundError:
        return {}
    except OSError as e:
        raise Refused(UNWINDOWED_UNREADABLE % (e.strerror or str(e)))
    if text == "":
        return {}
    try:
        d = json.loads(text)
    except ValueError as e:
        raise Refused(UNWINDOWED_UNREADABLE % ("not valid JSON: %s" % e))
    if not isinstance(d, dict):
        raise Refused(UNWINDOWED_UNREADABLE % "not a JSON object")
    return d


def _prune_unwindowed(d: dict, today: str, keep: Optional[str] = None) -> dict:
    """Drop the entries whose newest reserved day is before today and whose
    session has no live registry entry (no registry: older than
    UNWINDOWED_KEEP_DAYS). A number pruned before its file was written is free
    again, as a swept window's is. `keep` is never dropped."""
    out = {}
    registry = registry_present()
    floor = time.strftime("%Y-%m-%d", time.localtime(time.time() - UNWINDOWED_KEEP_DAYS * 86400))
    for sid, entry in d.items():
        logs = _reservations(entry) if isinstance(entry, dict) else {}
        if sid != keep:
            if not logs:
                continue
            newest = max(logs)
            if newest < today and (not registry_live_entries(sid) if registry else newest < floor):
                continue
        out[sid] = entry
    return out


def write_unwindowed(root: Path, d: dict, today: str, keep: Optional[str] = None) -> None:
    """Prune, then write (tmp + os.replace through write_lease); the file is
    removed when nothing is left. CALLER HOLDS THE LOCK."""
    d = _prune_unwindowed(d, today, keep)
    if d:
        write_lease(root, UNWINDOWED, d)
        return
    try:
        lease_path(root, UNWINDOWED).unlink()
    except FileNotFoundError:
        pass


def log_key_locked(root: Path, sid: str, leases: Dict[str, dict]) -> Tuple[str, str]:
    """Which store holds the session's log reservation: ("lease", NN) for its
    numbered lease; ("lease", "prime") when it holds the pen and prime.json
    already holds a reservation, or it has none for this session elsewhere (a
    session that kept the pen after releasing its window, as before);
    ("unwindowed", sid) otherwise — a session holding no window, its entry in
    unwindowed.json (made on its first reservation). CALLER HOLDS THE LOCK."""
    nn, _ = lease_of_session(leases, sid)
    if nn is not None:
        return "lease", nn
    prime = leases.get("prime") or {}
    if prime.get("session_id") == sid and (_reservations(prime) or sid not in read_unwindowed(root)):
        return "lease", "prime"
    return UNWINDOWED, sid


def unwindowed_log_locked(root: Path, sid: str, leases: Dict[str, dict], today: str, new_day: bool = False) -> str:
    """log_path_locked for a session holding no window: the same rules, kept in
    its unwindowed.json entry. CALLER HOLDS THE LOCK."""
    unw = read_unwindowed(root)
    entry = unw.get(sid) if isinstance(unw.get(sid), dict) else {}
    logs = _reservations(entry)
    if today in logs:
        return _log_file(today, logs[today])
    if logs and not new_day:
        day = max(logs)
        return _log_file(day, logs[day])
    n = _max_log_number(root, leases, unw) + 1
    logs[today] = n
    unw[sid] = dict(entry, logs=logs)
    write_unwindowed(root, unw, today, keep=sid)
    return _log_file(today, n)


def carry_unwindowed_locked(root: Path, sid: str, nn: str, leases: Dict[str, dict], today: str) -> None:
    """A session that reserved its log while it held no window and now holds
    window NN with no reservation of its own: the reservation moves into the
    lease, so the session keeps the number it was told — never two numbers.
    It comes from the session's unwindowed.json entry (the entry is removed),
    or else from prime.json when this session holds the pen there (it took the
    pen, or kept it, before it reserved; prime.json's logs are removed).
    CALLER HOLDS THE LOCK."""
    lease = leases.get(nn)
    if lease is None or _reservations(lease):
        return
    if lease_path(root, UNWINDOWED).exists():
        unw = read_unwindowed(root)
        entry = unw.get(sid)
        logs = _reservations(entry) if isinstance(entry, dict) else {}
        if logs:
            lease["logs"] = logs
            write_lease(root, nn, lease)
            unw.pop(sid, None)
            write_unwindowed(root, unw, today)
            return
    prime = leases.get("prime")
    logs = _reservations(prime) if isinstance(prime, dict) and prime.get("session_id") == sid else {}
    if not logs:
        return
    lease["logs"] = logs
    write_lease(root, nn, lease)
    prime.pop("logs", None)
    write_lease(root, "prime", prime)


def session_log_locked(root: Path, sid: str, leases: Dict[str, dict], today: str, new_day: bool = False) -> str:
    """The session's log path from whichever store holds it (log_key_locked),
    after carrying a reservation made with no window into the window it now
    holds. CALLER HOLDS THE LOCK."""
    kind, key = log_key_locked(root, sid, leases)
    if kind == UNWINDOWED:
        return unwindowed_log_locked(root, sid, leases, today, new_day=new_day)
    if key != "prime":
        carry_unwindowed_locked(root, sid, key, leases, today)
    return log_path_locked(root, key, leases, today, new_day=new_day)


# --- The pen commits every window's session log (2026-10-19) ------------------
# The pen's holder stays the one vault committer. A window that closes while the pen's holder is live leaves its log
# with a marker under state/vault-pending/ (close.sh, `mark-log-pending`); the holder commits the marked logs at its
# next Stop, at its SessionEnd, and in every full vault commit it makes, and says whose logs it carried. A live other
# window's log with no marker is its own session's work in progress: a full commit leaves it out ("hold").

def pending_dir(root: Path) -> Path:
    return root / "state" / "vault-pending"


def pending_logs(root: Path) -> List[str]:
    """The home-relative log paths closed windows left for the pen's holder (one marker file each). Lock-free: the
    markers are written whole (tmp + os.replace) and only ever added or removed. A marker counts only while its log
    is as it was at the close (same mtime_ns): a session that goes on after close.sh — another question, a restart the
    same day — writes to the same log, and from then on that log is its work in progress again, never committed by
    the pen's holder until it closes again (review 2026-10-19, M1)."""
    d = pending_dir(root)
    out = []
    try:
        names = sorted(os.listdir(str(d)))
    except OSError:
        return []
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            m = json.loads((d / name).read_text())
            rel, at = m.get("path"), m.get("mtime_ns")
        except (OSError, ValueError, AttributeError):
            continue
        if not (isinstance(rel, str) and _LOG_PATH_RE.match(rel)):
            continue
        try:
            if os.stat(str(root / rel)).st_mtime_ns != at:
                continue
        except OSError:
            continue
        out.append(rel)
    return out


_LOG_PATH_RE = re.compile(r"^vault/sessions/[0-9]{4}/[0-9]{2}/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3,}\.md$")


def clear_pending(root: Path, paths: List[str]) -> None:
    for rel in paths:
        try:
            (pending_dir(root) / (Path(rel).stem + ".json")).unlink()
        except OSError:
            pass


def _session_reservations(root: Path, leases: Dict[str, dict], sid: str) -> List[str]:
    """Every log path session sid has reserved, in any store: its numbered lease, prime.json when it holds the pen,
    its unwindowed.json entry. CALLER HOLDS THE LOCK."""
    stores = []
    nn, lease = lease_of_session(leases, sid)
    if lease is not None:
        stores.append(lease)
    prime = leases.get("prime") or {}
    if prime.get("session_id") == sid:
        stores.append(prime)
    if lease_path(root, UNWINDOWED).exists():
        entry = read_unwindowed(root).get(sid)
        if isinstance(entry, dict):
            stores.append(entry)
    paths = {_log_file(day, n) for store in stores for day, n in _reservations(store).items()}
    return sorted(paths)


def mark_log_pending(root: Path, sid: Optional[str]) -> str:
    """close.sh, when vault-commit.sh did not commit here (exit 3): mark this session's own logs that exist on disk
    as closed, so whichever session commits the vault next carries them (a marker keeps a log from being held as
    work in progress). The plain sentence — "Your log is saved; window NN holds the pen and commits it." — only when
    the pen's holder is another session that is live; every other exit 3 already said its own line (review
    2026-10-19, M2). Nothing for an operator shell or a direct-call visitor, which holds no log."""
    if not sid or os.environ.get("DIRECT_CALL_ID") or not leases_dir(root).is_dir():
        return ""
    with lock(root, shared=True):
        leases = read_all(root)
        mine = [p for p in _session_reservations(root, leases, sid) if (root / p).is_file()]
        holder = (leases.get("prime") or {}).get("session_id")
        who = None
        if holder and holder != sid and holder_ended(root, leases, holder) is False:
            who = _holder_words(leases, str(holder))[0]
    if not mine:
        return ""
    d = pending_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    for rel in mine:
        tmp = d / (".%s.%d.tmp" % (Path(rel).stem, os.getpid()))
        tmp.write_text(json.dumps({"path": rel, "session_id": sid, "at": now_stamp(),
                                   "mtime_ns": os.stat(str(root / rel)).st_mtime_ns}))
        os.replace(str(tmp), str(d / (Path(rel).stem + ".json")))
    return ("Your log is saved; %s holds the pen and commits it." % who) if who else ""


def vault_log_rows(root: Path, sid: Optional[str]) -> List[dict]:
    """`leaselib.py vault-logs` (vault-commit.sh's full commit): one row per reserved session log, any session —
    {path, owner, mine, hold}. hold: another session's log while that session is still open (live, quiet or
    resumed) and has not closed (no pending marker) — its work in progress, never committed by someone else.
    One shared lock."""
    if not leases_dir(root).is_dir():
        return []
    pending = set(pending_logs(root))
    rows: Dict[str, dict] = {}
    with lock(root, shared=True):
        leases = read_all(root)
        for nn in sorted(k for k in leases if k != "prime"):
            lease = leases[nn]
            mine = bool(sid) and lease.get("session_id") == sid
            live = liveness(root, nn, lease) in HELD_BY_LIVE
            for day, n in _reservations(lease).items():
                rel = _log_file(day, n)
                rows[rel] = {"path": rel, "owner": "window %s" % nn, "mine": mine,
                             "hold": live and not mine and rel not in pending}
        prime = leases.get("prime") or {}
        holder = prime.get("session_id")
        if holder:
            ended = holder_ended(root, leases, holder)
            for day, n in _reservations(prime).items():
                rel = _log_file(day, n)
                mine = holder == sid
                rows.setdefault(rel, {"path": rel, "owner": _holder_words(leases, str(holder))[0], "mine": mine,
                                      "hold": ended is not True and not mine and rel not in pending})
        if lease_path(root, UNWINDOWED).exists():
            for other, entry in read_unwindowed(root).items():
                if not isinstance(entry, dict):
                    continue
                mine = other == sid
                live = bool(registry_live_entries(str(other))) if registry_present() else True
                for day, n in _reservations(entry).items():
                    rel = _log_file(day, n)
                    rows.setdefault(rel, {"path": rel, "owner": "a session with no window", "mine": mine,
                                          "hold": live and not mine and rel not in pending})
    return [rows[k] for k in sorted(rows)]


def _reservations(lease: dict) -> Dict[str, int]:
    """The lease's logs: {"<date>": N} with every entry that is not a date
    and a positive int left out — only leaselib writes it, so a corrupt value
    is treated as no reservation rather than a traceback."""
    logs = lease.get("logs")
    out: Dict[str, int] = {}
    if not isinstance(logs, dict):
        return out
    for day, val in logs.items():
        if isinstance(day, str) and _DATE_RE.match(day) and isinstance(val, int) and not isinstance(val, bool) and val > 0:
            out[day] = val
    return out


_DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")


def _log_file(day: str, n: int) -> str:
    return "vault/sessions/%s/%s/%s-%03d.md" % (day[:4], day[5:7], day, n)


def log_path_locked(root: Path, key: str, leases: Dict[str, dict], today: str, new_day: bool = False) -> str:
    """The home-relative path of the log for the lease `key` (NN, or 'prime'
    for a session that holds only the pen). A day already reserved gives the
    same path again. With no reservation for `today`: new_day=True (a session
    starting or resuming today) reserves the next number for today;
    new_day=False (`lease.sh log`, a compaction) returns the latest reservation
    — the file the session opened with, so a session that runs past midnight
    keeps its log — and reserves today only when the lease has none at all.
    CALLER HOLDS THE LOCK."""
    lease = leases[key]
    logs = _reservations(lease)
    if today in logs:
        return _log_file(today, logs[today])
    if logs and not new_day:
        day = max(logs)
        return _log_file(day, logs[day])
    n = _max_log_number(root, leases) + 1
    logs[today] = n
    lease["logs"] = logs
    write_lease(root, key, lease)
    return _log_file(today, n)


# What a session that starts while the upgrade is pending (it holds no window) is told about its close.
WINDOWLESS_PEN_AT_CLOSE = ("At the close, when no live session holds the pen, `core/lease.sh prime take` gives this "
                           "session the pen for `core/vault-commit.sh` — no window is made.")
LOG_BUSY_AT_START = ("Your session log was not reserved at start: the lease lock stayed busy past the start budget. "
                     "`core/lease.sh log` reserves it and prints the path.")
# The upgrade has not made state/leases/ yet: no number can be reserved, and there is nothing to hold — hot.md and the
# vault commit pass with no lease files. lease.sh says it for `log` and `prime`; a start in that state says it too.
NO_LEASES_YET = ("the upgrade has not run, so no session-log number can be reserved yet; hot.md and "
                 "`core/vault-commit.sh` work now. Ask the operator to start a session in this home, then run "
                 "`core/lease.sh log` again.")


def reserve_at_start(root: Path, sid: str, deadline: Optional[float] = None, new_day: bool = True) -> Tuple[str, bool]:
    """A start that binds nothing (the upgrade is pending): the session's log
    path, reserved in whichever store is its own (session_log_locked), and
    whether it holds no window. The lock wait is bounded by `deadline`: still
    busy then, Refused(LOG_BUSY_AT_START) with nothing written. Never called
    when state/leases/ does not exist (lock() would make it)."""
    with lock(root, deadline=deadline, busy=LOG_BUSY_AT_START):
        leases = read_all(root)
        path = session_log_locked(root, sid, leases, time.strftime("%Y-%m-%d"), new_day=new_day)
        return path, lease_of_session(leases, sid)[0] is None


def log_path(root: Path, sid: str, today: Optional[str] = None) -> str:
    """`core/lease.sh log`: the calling session's log path for today, reserved
    under the lock — for a window, for a session holding only the pen, and for
    a session holding no window at all (unwindowed.json), so no session ever
    counts the directory to name its log."""
    today = today or time.strftime("%Y-%m-%d")
    with lock(root):
        leases = read_all(root)
        return session_log_locked(root, sid, leases, today)


def orientation(root: Path, sid: Optional[str], visitor: bool = False, deadline: Optional[float] = None) -> str:
    """The first line of SessionStart's additionalContext (§8.2).

    `deadline` bounds the wait for the lease lock, SessionStart's third
    acquire beside the bind's and the board's (§4.2; plan 2 Decision 18,
    found at Task 3: unbounded, a lock held elsewhere kept the hook until its
    holder let go). Still busy then, the lease files are read without the
    lock: each lands whole by tmp + os.replace, so "which window names this
    session" is answered from what is on disk rather than guessed as unleased."""
    if visitor:
        return "Daedalus session orientation: visitor, %s" % root
    try:
        with lock(root, shared=True, deadline=deadline):
            leases = read_all(root)
    except Refused:
        if deadline is None:
            raise
        leases = read_all(root)
    nn, lease = lease_of_session(leases, sid or "")
    if nn is None:
        return "Daedalus session orientation: unleased, %s" % root
    label = window_label(nn, lease)
    if leases.get("prime", {}).get("session_id") == sid:
        label += ", prime"
    return "Daedalus session orientation: %s, %s" % (label, root)


# --- The observed changed set (§4.1) ------------------------------------------

def _listing(repo_path: Path, repo: str, nn: str, *args: str, deadline: Optional[float] = None) -> list:
    """One NUL-separated git listing as a list of literal repo-relative paths.
    -z keeps a path with accents, quotes, backslashes or control characters
    literal (core.quotePath would C-quote it, and the boundary check could
    never match it against another window's set). A listing that fails is
    an answer we do not have, never an empty set: refuse, naming the window
    and the command, so the caller keeps the last computed set."""
    t = _left_f(deadline, 20)
    if t < MIN_CALL_SECS:
        raise Refused("window %s's changed set could not be recomputed in time; the last computed set is kept." % nn)
    code, out, err = _git(repo_path, *args, timeout=t)
    if code != 0:
        last = (err.strip().splitlines() or ["no output"])[-1]
        raise Refused("window %s's changed set could not be recomputed (git %s failed in %s: %s); "
                      "the last computed set is kept." % (nn, " ".join(args), repo, last))
    return [p for p in out.split("\0") if p]


def compute_changed(root: Path, nn: str, lease: dict, previous: dict, deadline: Optional[float] = None) -> dict:
    """{"<repo>": {"<repo-relative path>": "<first-seen stamp>"}} — per repo of
    the lease's worktree, the union of committed/staged work on the lease
    branch (diff against merge-base origin/<trunk>..HEAD), unstaged
    modifications (diff) and untracked files (ls-files --others). A nested
    repo's paths never belong to the outer set. A path keeps the stamp it
    carried in `previous` while it stays changed; a path that left the set
    is dropped. Any listing that fails — merge-base included: a missing
    origin/<trunk> is not "no committed work" — raises Refused, and the
    caller leaves the sidecar as it was (§4.1: an empty set claims nothing,
    so a wiped set would silence every warning for the window). Takes no
    lock (four git commands per repo, nothing under state/leases/)."""
    out: dict = {}
    stamp = now_stamp()
    base = root / str(lease.get("worktree") or ("worktrees/%s" % nn))
    for repo, trunk in (lease.get("trunks") or {}).items():
        repo_path = base / repo
        if not repo_path.is_dir():
            continue
        paths: set = set()
        mb = _listing(repo_path, repo, nn, "merge-base", "origin/" + trunk, "HEAD", deadline=deadline)
        paths.update(_listing(repo_path, repo, nn, "diff", "--name-only", "-z", mb[0].strip(), deadline=deadline))
        paths.update(_listing(repo_path, repo, nn, "diff", "--name-only", "-z", deadline=deadline))
        paths.update(_listing(repo_path, repo, nn, "ls-files", "--others", "--exclude-standard", "-z", deadline=deadline))
        # a nested repo's paths never belong to the outer set
        nested_prefixes = [r[len(repo) + 1:] + "/" for r in lease.get("trunks", {}) if r.startswith(repo + "/")]
        prev = previous.get(repo, {}) if isinstance(previous.get(repo), dict) else {}
        out[repo] = {p: prev.get(p, stamp) for p in sorted(paths)
                     if p.strip() and not any(p.startswith(pre) for pre in nested_prefixes)}
    return out


def recompute_changed(root: Path, nn: str, lease: Optional[dict] = None, deadline: Optional[float] = None) -> dict:
    """Read the sidecar, compute, write (tmp + os.replace). Takes no lock. A
    Refused from the listings propagates before the write, so the sidecar
    on disk is untouched. `deadline` (the prompt hook's check deadline): each
    listing gets what is left, and a cut-off is that Refused."""
    if lease is None:
        lease = read_lease(root, nn) or {}
    changed = compute_changed(root, nn, lease, read_changed(root, nn), deadline=deadline)
    write_changed(root, nn, changed)
    return changed


def recompute_all_changed(root: Path) -> None:
    """Every unswept lease's sidecar (§4.1: a shell has no budget). Takes and
    releases LOCK_SH for the one directory read, then works outside it — so
    it is never called from under another lock (the lock is not re-entrant).
    A lease file that cannot be read refuses the whole command (read_all).
    One window whose git cannot answer must not block another window's
    command: its sidecar is left as it was and the reason goes to stderr."""
    with lock(root, shared=True):
        leases = read_all(root)
    for nn, lease in leases.items():
        if nn == "prime":
            continue
        try:
            recompute_changed(root, nn, lease)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)


# --- The pen (§4.8) -----------------------------------------------------------

def prime_take(root: Path, sid: str, reason: Optional[str], mode: str = "transcribed") -> str:
    """`lease.sh prime take [--reason "..."]` from the TAKING session. Every
    prime is a window (§4.8), so a session with no numbered lease is refused.
    A live holder (live, quiet or resumed — HELD_BY_LIVE) needs the operator's
    reason; a stale holder, or no prime.json at all (a registry-absent build
    that never first-upped), needs none. The reason is recorded in prime.json's
    append-only history.

    The reason is checked (spec §4.8, §7.4). transcribed: --reason must be,
    whole, a turn the operator typed in the TAKER's own transcript after the
    holder took the pen — bound_epoch, an absolute instant (pen_cutoff) — (transcriptlib; plan 4 Decision 30; no shown turn is
    required — there is no block to show), in a transcript nothing may write
    (Decision 36); the history entry records the transcript entry. tty:
    --reason is refused and the reason is read from /dev/tty — the take is the
    operator's keystroke; a process that descends from an agent, or from no
    terminal login, is refused (Decision 32). Both happen with NO lock held
    (plan 4 Decision 15: they may wait on a person, and the lock is not
    re-entrant); the write is a compare-and-swap on the holder read at the
    start (§4.1). LEASE_TEST_CAS_EXPECT lets a test simulate a stale read."""
    import transcriptlib as tl
    with lock(root, shared=True):
        leases = read_all(root)
    mine, _ = lease_of_session(leases, sid)
    if mine is None:
        return prime_take_windowless(root, sid, reason)
    registry_entry_for(sid)   # §4.5: a session open in two terminals cannot take the pen either (Refused)
    if mode == "tty" and reason is not None:
        raise Refused("In tty mode (promote.confirm: tty) the reason for taking the pen is typed in a terminal, "
                      "not passed as --reason. Run `core/lease.sh prime take` and type it when asked.")
    prime = leases.get("prime") or {}
    holder = prime.get("session_id")
    expect = os.environ.get("LEASE_TEST_CAS_EXPECT", holder)   # test knob: simulate a stale read
    record: Dict[str, object] = {}
    if holder and holder != sid:
        live, hnn, hlease = prime_holder_live(root, leases, str(holder))
        if live and mode == "tty":
            paste = "Paste this line in your own shell: `cd %s && DAEDALUS_SESSION_ID=%s core/lease.sh prime take`" % (root, sid)
            try:
                reason, _tty = tl.tty_answer("Why does window %s take the pen from %s? (the operator's words): "
                                             % (mine, window_label(hnn, hlease) if hlease is not None
                                                else "the live holder"), root)
            except tl.NotAPerson as e:
                raise Refused("Taking the pen from a live window must be typed by a person in their own terminal: %s. "
                              "The pen did not move. %s" % (e, paste))
            except tl.NoTerminal:
                raise Refused("Taking the pen from a live window must be typed by a person in a terminal. This "
                              "session has none. The pen did not move. %s" % paste)
            if not reason.strip():
                raise Refused("An empty reason is not a reason. The pen did not move.")
            record["reason_typed_at_terminal"] = True
        elif live and not reason:
            if hlease is not None:
                raise Refused("The pen is held by a live session, %s. Taking it needs --reason \"<the operator's words>\"."
                              % window_label(hnn, hlease))
            names = [e.get("name") for e in registry_live_entries(str(holder)) if e.get("name")]
            raise Refused("The pen is held by a live session that holds no window now (peer name %s). "
                          "Taking it needs --reason \"<the operator's words>\"." % (names[0] if names else "unknown"))
        elif live:
            try:
                found = tl.find_consent(tl.transcript_for(root, sid), pen_cutoff(root, prime), quote=str(reason))
            except tl.Missing as e:
                raise Refused("I cannot find this window's transcript (%s), so the operator's words cannot be checked. "
                              "The pen did not move. If the transcript lives elsewhere, set memory.transcript_dir in "
                              "config.yaml; or set promote.confirm: tty and take the pen by typing the reason." % e)
            except tl.Unprotected as e:
                raise Refused("This window's transcript (%s) is outside every directory nothing may write, so it is not "
                              "evidence of the operator's words. The pen did not move. Set memory.transcript_dir in "
                              "config.yaml, or set promote.confirm: tty and take the pen by typing the reason." % e)
            except tl.Unreadable as e:
                raise Refused("I cannot read this build's transcript format (%s), so the operator's words cannot be "
                              "checked. The pen did not move. Until the parser is updated, set `promote.confirm: tty` "
                              "and take the pen by typing the reason." % e)
            except tl.NotCited:
                raise Refused("The words cited are in nothing the operator typed in this window since the pen was "
                              "last taken. The pen did not move; cite a few of their words exactly.")
            except (tl.NotWritten, tl.NotSubmitted):
                raise Refused("The words cited are in this window's transcript, but not as a turn the operator typed "
                              "and Claude Code reported. The pen did not move.")
            except tl.NotFound:
                raise Refused("I could not find anything the operator typed in this window since the pen was last "
                              "taken. The pen did not move.")
            record["transcript_ref"] = found["transcript_ref"]
            record["operator_said"] = found["text"]
    with lock(root):
        fresh = read_lease(root, "prime") or {}
        if fresh.get("session_id") != expect:
            raise Refused("`prime` changed under you — re-read the board and try again")
        entry: Dict[str, object] = {"from": holder, "to": sid, "at": now_stamp(),
                                    "reason": reason or "previous holder gone"}
        entry.update(record)
        fresh["history"] = (fresh.get("history") or []) + [entry]
        fresh.pop("logs", None)      # the pen's reservation, if any, was the previous holder's
        fresh.pop("taken_without_window", None)
        fresh.pop("taken_while_pending", None)
        fresh.update(dict({"session_id": sid}, **pen_bound()))
        write_lease(root, "prime", fresh)
    return "Window %s holds the pen now (prime): vault commits, promote." % mine


WINDOWLESS_NOT_IN_REGISTRY = ("This session is not in the session registry, so no later session could tell it is "
                              "live; it cannot take the pen.")
WINDOWLESS_PEN_HELD = ("The pen is held by a live session, %s; a session holding no window never takes it from a live "
                       "holder. Your session log is still yours (`core/lease.sh log`); for the vault "
                       "commit, message that session (SendMessage to %s); or the operator commits the vault from "
                       "their own shell: `cd %s && core/vault-commit.sh`.")
WINDOWLESS_PEN_UNTOLD = ("The pen is held by a session holding no window, and on this build (no session registry) it "
                         "cannot be told whether it is live, so it is treated as live; a session holding no window "
                         "never takes it from a live holder. Your session log is still yours (`core/lease.sh log`); "
                         "for the vault commit, message that session; or the operator commits the vault "
                         "from their own shell: `cd %s && core/vault-commit.sh`.")
WINDOWLESS_PEN_TAKEN = "This session holds the pen now, with no window: `core/vault-commit.sh` is yours%s."
PROMOTE_WAITS_CLAUSE = "; promote waits until the upgrade finishes"


def _holder_words(leases: Dict[str, dict], holder: str) -> Tuple[str, str]:
    """(how the refusal names the live holder, its peer name)."""
    names = [e.get("name") for e in registry_live_entries(holder) if e.get("name")]
    hnn, hlease = lease_of_session(leases, holder)
    if hlease is not None:
        peer = names[0] if names else peer_of(hlease)
        return window_label(hnn, hlease), peer
    peer = names[0] if names else "unknown"
    return "a session holding no window (peer name %s)" % peer, peer


def prime_take_windowless(root: Path, sid: str, reason: Optional[str]) -> str:
    """`prime take` from a session holding no numbered lease — one that started
    while the upgrade was pending, or any other: it takes the pen only when no
    live session holds it, never from a live holder whatever --reason says (the
    reason path stays a window's). Liveness is judged and the write made in one
    exclusive section (first_up's pattern): no lock-free read, no transcript,
    no terminal, no git. It makes no window, branch or worktree and touches
    nothing under target/: it writes state/leases/prime.json only, marked
    taken_without_window so the pen gives it no tree until it claims a window
    (pen_without_tree)."""
    if registry_entry_for(sid) is None and registry_present():
        # a session id with no live registry entry would hold a pen every later judge calls gone at once
        raise Refused(WINDOWLESS_NOT_IN_REGISTRY)
    with lock(root):
        leases = read_all(root)
        if lease_of_session(leases, sid)[0] is not None:
            raise Refused("`prime` changed under you — re-read the board and try again")
        fresh = read_lease(root, "prime")
        holder = (fresh or {}).get("session_id")
        if holder == sid:
            return "This session already holds the pen."
        if holder:
            hnn, _ = lease_of_session(leases, str(holder))
            if hnn is None and not registry_present():
                raise Refused(WINDOWLESS_PEN_UNTOLD % root)
            if prime_holder_live(root, leases, str(holder))[0]:
                label, peer = _holder_words(leases, str(holder))
                raise Refused(WINDOWLESS_PEN_HELD % (label, peer, root))
        entry = {"from": holder, "to": sid, "at": now_stamp(),
                 "reason": reason or "taken by a session holding no window; previous holder gone", "no_window": True}
        data = dict(fresh or {})
        data["history"] = (data.get("history") or []) + [entry]
        data.pop("logs", None)       # the previous holder's pen-only reservation, as on every take
        data.pop("taken_while_pending", None)
        data.update(dict({"session_id": sid, "taken_without_window": sid}, **pen_bound()))
        try:
            write_lease(root, "prime", data, exclusive=fresh is None)
        except FileExistsError:
            raise Refused("`prime` changed under you — re-read the board and try again")
    return WINDOWLESS_PEN_TAKEN % (PROMOTE_WAITS_CLAUSE if pending_version(root) else "")


# --- The pen at a vault commit (close-commits design 2026-10-16) ------------------------------------------

PEN_TAKEN_AT_COMMIT = "The pen's holder, %s, has ended; this session holds the pen now and commits the vault%s."
PEN_HELD_AT_COMMIT = "%s holds the pen and commits the vault, this session's files included."
PEN_UNTOLD_AT_COMMIT = ("The vault is left for the pen's holder, %s; this build cannot tell whether it is live, so it is "
                        "not taken — `core/lease.sh prime take` moves it, or the operator commits from their own shell: "
                        "`cd %s && core/vault-commit.sh`.")
PEN_ENDED_NOT_TERMINAL = ("The pen's holder, %s, has ended, but this is not a terminal session, so it does not take the "
                          "pen: the next close in a terminal session takes it and commits these files, or the operator "
                          "commits from their own shell: `cd %s && core/vault-commit.sh`.")
NOBODY_NOT_TERMINAL = ("Nobody holds the pen, and this is not a terminal session, so it does not take it: the next "
                       "close in a terminal session takes it and commits these files, or the operator commits from "
                       "their own shell: `cd %s && core/vault-commit.sh`.")
TERMINAL_UNTOLD_AT_COMMIT = ("%s, but this build has no session registry, so it cannot tell whether this is a terminal "
                             "session and does not take the pen: `core/lease.sh prime take` takes it, or the operator "
                             "commits from their own shell: `cd %s && core/vault-commit.sh`.")
VISITOR_AT_COMMIT = "This is a direct-call session; it does not commit the vault — its caller's session does."
NOT_IN_REGISTRY_AT_COMMIT = WINDOWLESS_NOT_IN_REGISTRY + " The next session's close commits these files."


def holder_ended(root: Path, leases: Dict[str, dict], holder: Optional[str]) -> Optional[bool]:
    """Has the pen's holder ended? True, False, or None (cannot tell — treated as live by every caller).
    No holder: True. A holder with a numbered lease: reclaim_idle_locked's test word for word — a pid on
    file and liveness "stale"; live, quiet and resumed are False, a lease that recorded no pid is None.
    A holder with no window: the registry's live entries, None when this build has no registry. Pure over
    the read; stricter than prime_holder_live, which reads a pid-less heartbeat-stale window as gone —
    the automatic take has no operator in the loop."""
    if not holder:
        return True
    hnn, hlease = lease_of_session(leases, str(holder))
    if hlease is not None:
        if hlease.get("pid") is None:
            return None
        return liveness(root, hnn, hlease) == "stale"
    if not registry_present():
        return None
    return not registry_live_entries(str(holder))


def pen_for_commit(root: Path, sid: Optional[str]) -> Tuple[int, str]:
    """vault-commit.sh step 1: may this session commit the vault, taking a pen whose holder has ended?
    (exit, line): 0 commit (the line says the pen moved, or is empty), 3 not here (the pen's holder
    commits; the line says why), 1 a lease file cannot be read (Refused propagates). The judge and the
    write sit in ONE exclusive lock (first_up's pattern): no lock-free read, no CAS window. The take is
    a terminal session's only (is_terminal_window, first_up's rule): a headless, background or spawned
    session, or a visitor, never holds the pen. It writes prime.json alone — no window, branch or
    worktree, nothing under target/ — marked taken_without_window for a taker holding no window
    (pen_without_tree) and taken_while_pending while the upgrade is pending (promote.who waits)."""
    if sid is None:
        return 0, ""
    if os.environ.get("DIRECT_CALL_ID"):
        return 3, VISITOR_AT_COMMIT
    if not leases_dir(root).is_dir():
        return 0, ""                       # never made here: lock() would mkdir it
    with lock(root):
        leases = read_all(root)            # an unreadable lease file fails closed (Refused)
        numbered = [k for k in leases if k != "prime"]
        prime = leases.get("prime")
        holder = (prime or {}).get("session_id")
        if not numbered and not holder:
            return 0, ""
        if holder == sid:
            return 0, ""
        label = _holder_words(leases, str(holder))[0] if holder else "nobody"
        mine, _ = lease_of_session(leases, sid)
        if mine is None and registry_present() and not registry_live_entries(sid):
            return 3, NOT_IN_REGISTRY_AT_COMMIT
        ended = holder_ended(root, leases, holder)
        if ended is None:
            return 3, PEN_UNTOLD_AT_COMMIT % (label, root)
        if not ended:
            return 3, PEN_HELD_AT_COMMIT % (label[:1].upper() + label[1:])
        registry_entry_for(sid)            # a session open in two terminals is refused, as at every take
        if not is_terminal_window(sid):
            if not registry_present():     # no registry: no session can be told a terminal one, so never "not one"
                said = ("The pen's holder, %s, has ended" % label) if holder else "Nobody holds the pen"
                return 3, TERMINAL_UNTOLD_AT_COMMIT % (said, root)
            if not holder:
                return 3, NOBODY_NOT_TERMINAL % root
            return 3, PEN_ENDED_NOT_TERMINAL % (label, root)
        pending = pending_version(root)
        entry: Dict[str, object] = {"from": holder, "to": sid, "at": now_stamp(),
                                    "reason": "taken at commit: previous holder ended", "auto": "commit"}
        data = dict(prime or {})
        if mine is None:
            entry["no_window"] = True
            data["taken_without_window"] = sid
        else:
            data.pop("taken_without_window", None)
        if pending:
            data["taken_while_pending"] = pending
        else:
            data.pop("taken_while_pending", None)
        data["history"] = (data.get("history") or []) + [entry]
        data.pop("logs", None)             # the ended holder's pen-only reservation, as on every take
        data.update(dict({"session_id": sid}, **pen_bound()))
        write_lease(root, "prime", data)
    if holder:
        return 0, PEN_TAKEN_AT_COMMIT % (label, PROMOTE_WAITS_CLAUSE if pending else "")
    return 0, ("Nobody held the pen; this session holds it now and commits the vault%s."
               % (PROMOTE_WAITS_CLAUSE if pending else ""))


# --- The board (§4.3) ---------------------------------------------------------

UNLEASED_NAG = ("This session holds no lease. If the operator told you your window number, run `core/lease.sh claim <NN>`; "
                "otherwise run `core/lease.sh create` and then `claim` the number it prints.")
VISITOR_LINE = "This is a direct-call session; it holds no lease and cannot take the pen."
# §4.8: a visitor never creates, claims or binds any lease, and cannot take the
# pen. Every lease.sh command that changes state/leases/ is refused for it —
# not only create/claim/spawn: sweep and release delete lease files, and
# `prime take` would move the pen to a read-only headless session that exits
# in minutes. list/status stay allowed (they read).
VISITOR_REFUSED = ("create", "claim", "alias", "note", "task", "update", "spawn", "release", "done", "sweep", "prime",
                   "rebase", "split", "adopt", "log")
# what makes, moves or removes a window's worktree in target/'s repositories: refused while the upgrade's safety copy
# of target/ is not taken (safety-copy review 3, finding 4)
# what makes or binds a window: refused while the upgrade is not stamped (upgrade.windows_wait_lease), all but
# `adopt --all-unfinished`
WINDOW_MAKERS = ("create", "claim", "spawn", "adopt", "split")
COPY_GATED = ("create", "claim", "spawn", "release", "done", "sweep", "rebase", "split", "adopt")
VISITOR_REFUSAL = ("This is a direct-call session (a visitor): it never creates, claims or changes a window and "
                   "cannot take the pen. `core/lease.sh %s` is refused here; ask the operator to run it from a window.")
TASK_LINE = ("When the operator gives you a task: set yours with `core/lease.sh task <NN> \"<one line>\"`, read the other "
             "windows' tasks above, and message a window whose task overlaps yours once, before you start.")
MESSAGE_LINE = ("If you need a file another window has changed, message that window (SendMessage to its peer name, "
                "from this board) before changing it.")


def _ago(ts: Optional[float], now: float) -> str:
    if ts is None:
        return "never"
    s = int(now - ts)
    if s < 60:
        return "just now"
    if s < 3600:
        return "%d minute%s ago" % (s // 60, "" if s // 60 == 1 else "s")
    return time.strftime("%H:%M", time.localtime(ts))


def last_commit_subject(root: Path, lease: dict, nn: str, deadline: Optional[float] = None) -> Optional[str]:
    """The subject of the newest commit on the lease branch that origin/<trunk>
    does not contain — the outer repo first, then each nested one. A repo whose
    worktree is not made yet is read at lease/<NN> in target/<repo>: an adopted
    window holds its commits there before it has a worktree (release-candidate
    red team, finding 1). `deadline` (the prompt hook's render deadline, v0.7.5):
    None when it is reached or a call is cut off — "not read this time", never
    "no commits yet", which is a claim about the branch."""
    base = root / str(lease.get("worktree") or ("worktrees/%s" % nn))
    for repo, trunk in (lease.get("trunks") or {}).items():
        if (base / repo).is_dir():
            where, tip = base / repo, "HEAD"
        elif (root / "target" / repo).is_dir():
            where, tip = root / "target" / repo, "refs/heads/lease/%s" % nn
        else:
            continue
        if deadline is None:
            code, out, _ = _git(where, "log", "-1", "--format=%s", "%s..%s" % (remote_ref(trunk), tip))
        else:
            t = _left_f(deadline, 20)
            if t < MIN_CALL_SECS:
                return None
            code, out, _, cut = _git_t(where, "log", "-1", "--format=%s", "%s..%s" % (remote_ref(trunk), tip), timeout=t)
            if cut:
                return None
        if code == 0 and out.strip():
            return out.strip().splitlines()[0]
    return ""


def fetched_at(root: Path, lease: dict) -> str:
    repo = list((lease.get("trunks") or {}).keys())[:1]
    if not repo:
        return ""
    try:
        return time.strftime("%H:%M", time.localtime((root / "target" / repo[0] / ".git" / "FETCH_HEAD").stat().st_mtime))
    except OSError:
        return ""


def registry_live_map() -> Dict[str, list]:
    """session id -> its live registry entries, from ONE pass over sessions/
    (one ps per registry file). A render reads this once instead of one glob
    and one ps per lease per entry; the same live-entry rule as
    registry_live_entries (pid + startedAt, never pid alone)."""
    out: Dict[str, list] = {}
    d = registry_dir()
    if not d.is_dir():
        return out
    for p in d.glob("*.json"):
        try:
            e = json.loads(p.read_text())
        except (OSError, ValueError):
            continue
        if isinstance(e, dict) and e.get("sessionId") and pid_is_recorded_process(e.get("pid"), e.get("startedAt"),
                                                                                    e.get("procStart")):
            out.setdefault(str(e["sessionId"]), []).append(e)
    return out


def render_board(root: Path, sid: Optional[str], leases: Dict[str, dict], changed: Dict[str, dict],
                 waiting: "Waiting", states: Dict[str, str], now: float, visitor: bool = False,
                 live_map: Optional[Dict[str, list]] = None, render_deadline: Optional[float] = None) -> str:
    """The board text (§4.3). Pure over its inputs except one `git log` per
    repo of each non-stale lease and one `cfg` for the reader's trunk. states:
    liveness per number, computed ONCE by the caller (board_for); live_map:
    the registry read once (registry_live_map) — the peer name on every line
    comes from it at render time (§4.1 're-read at every board render'), the
    lease file's stored peer_name only when the registry has no live entry."""
    numbered = {k: d for k, d in leases.items() if k != "prime"}
    prime = leases.get("prime") or {}
    # None when prime.json is absent or unclaimed; the mark below requires BOTH sides bound,
    # else a null (created-but-unclaimed) lease reads as the holder of a pen nobody took (§4.8).
    prime_sid = prime.get("session_id") or None
    live_map = registry_live_map() if live_map is None else live_map
    mine, _ = lease_of_session(leases, sid or "")
    head = "Lease board (%d window%s; %s):" % (len(numbered), "" if len(numbered) == 1 else "s",
                                                "you are window %s" % mine if mine else "you hold no lease")
    order = ([mine] if mine else []) + [k for k in sorted(numbered) if k != mine]
    lines = [head]
    # §4.8 handover: the displaced holder learns from the board, never from memory.
    hist = prime.get("history") or []
    if sid and hist and hist[-1].get("from") == sid and hist[-1].get("to") != sid:
        tnn, tlease = lease_of_session(leases, str(hist[-1].get("to")))
        lines.append("You no longer hold the pen; %s took it at %s (reason: '%s')."
                     % (window_label(tnn, tlease) if tnn else "another session",
                        str(hist[-1].get("at", ""))[11:16], hist[-1].get("reason", "")))
    # a pen held by a session holding no window shows on no numbered line: say so, so a window knows why it is not its
    if prime_sid and lease_of_session(leases, str(prime_sid))[0] is None:
        if prime_sid == sid:
            lines.append("You hold the pen, with no window: `core/vault-commit.sh` is yours.")
        else:
            names = [e.get("name") for e in live_map.get(str(prime_sid), []) if e.get("name")]
            lines.append("The pen is held by a session holding no window (peer name %s)."
                         % (names[0] if names else "unknown"))
    for nn in order:
        d = numbered[nn]
        marks = []
        if nn == mine:
            marks.append("(you)")
        if d.get("alias"):
            marks.append("(%s)" % d["alias"])
        if d.get("spawned"):
            marks.append("(spawned)")
        label = "- %s%s" % (nn, (" " + " ".join(marks)) if marks else "")
        parts = []
        # v0.12.3: the window's task first, so a window given a task sees what the others are doing before it starts
        if d.get("task") and not d.get("released"):
            parts.append("task: %s" % task_line(d["task"], TASK_SHOWN))
        state = states.get(nn, "stale")
        entries = live_map.get(str(d.get("session_id")), []) if d.get("session_id") else []
        if d.get("released"):
            parts.append("released — this window is done")
        elif d.get("finished"):
            parts.append("FINISHED at %s: %s — promote %s or release %s" % (str(d["finished"])[11:16], d.get("summary", ""), nn, nn))
        elif len(entries) > 1:
            parts.append("open in two terminals (pids %s) — close one" % ", ".join(str(e.get("pid")) for e in entries))
        elif state == "stale":
            since = _ago(seen_mtime(root, nn), now)
            parts.append("STALE: no live session since %s; run `core/lease.sh sweep`, or say 'this is window %s' to a new window to continue it." % (since, nn))
            if d.get("spawned"):
                # a spawned clone is launched `--name daedalus-<NN>` (spawn), so that is its log's name
                parts.append("a background clone that never reported — read its log with `claude logs %s` before sweeping"
                             % (d.get("peer_name") or "daedalus-%s" % nn))
        else:
            if prime_sid and d.get("session_id") == prime_sid:
                parts.append("prime (holds the pen: vault commits, promote)")
            if entries and entries[0].get("kind") == "bg" and not d.get("spawned"):
                parts.append("background clone")
            # distinct paths across repos, as board_json counts them (lease-board spec §3.4; finding 23)
            paths = sorted({p for repo in (changed.get(nn) or {}) for p in changed[nn][repo]})
            if paths:
                shown = ", ".join(paths[:3]) + (", … (+%d)" % (len(paths) - 3) if len(paths) > 3 else "")
                parts.append("%d changed: %s" % (len(paths), shown))
            else:
                parts.append("0 changed")
            subj = last_commit_subject(root, d, nn, deadline=render_deadline)
            parts.append(LAST_COMMIT_NOT_READ if subj is None else 'last commit "%s"' % subj if subj else "no commits yet")
            if d.get("worktree_ready") is False:
                parts.append(NO_WORKTREE_YET % (nn, nn))
            if d.get("note"):
                parts.append("note: %s" % d["note"])
            if d.get("adopted_from"):
                parts.append("adopted from %s" % d["adopted_from"])
            if nn == mine:
                fetched = fetched_at(root, d)
                parts.append("based on origin/%s %s" % (v.target_branch(root),
                                                        ("as fetched %s" % fetched) if fetched else "(never fetched)"))
            elif state == "quiet":
                parts.append("quiet since %s — its window is still open" % _ago(seen_mtime(root, nn), now))
            else:
                parts.append("last seen %s" % _ago(seen_mtime(root, nn), now))
        # §4.1: the peer name is RE-READ from the registry at every render (renames,
        # two-word variants); the stored field is only the fallback — and the one used when
        # the session is open in two terminals, which has no single name (the same rule as
        # board_json, so the two boards show one peer name; review 2026-10-11, finding 5).
        peer = (entries[0].get("name") if len(entries) == 1 else None) or d.get("peer_name")
        if peer and peer != "daedalus-%s" % nn:
            parts.append("peer name %s (not a window number)" % peer)
        lines.append("%s — %s" % (label, " — ".join(parts)))
    lines.extend(waiting_lines(waiting))
    if not registry_present():
        lines.append("(no session registry on this build: liveness is by heartbeat only, peer names are unknown, no window numbers itself "
                     "and nobody takes the pen at start — launch each window with DAEDALUS_LEASE=<NN> and run `core/lease.sh prime take` from the one that should hold it)")
    if visitor:
        lines.append(VISITOR_LINE)
    elif mine and numbered[mine].get("released"):
        lines.append("Window %s is released; this window is done — close it." % mine)
    elif sid is not None and not mine and numbered:
        # a session with no lease is nagged; an operator shell (sid None) is not a session. While the upgrade
        # is pending the nag's remedy is refused (create/claim), so the sentence names the upgrade instead.
        ps = pending_stop(root)
        lines.append(no_window_pending(ps) if ps else UNLEASED_NAG)
    # only to a reader that can act on it: a live window of its own, and another window to compare with (F3)
    if len(numbered) > 1 and not visitor and mine and not numbered[mine].get("released"):
        lines.append(TASK_LINE)
    lines.append(MESSAGE_LINE)
    return "\n".join(lines)


# --- The unpromoted-work cache (v0.7.5, spec §3.1) ------------------------------
# state/leases/unpromoted.cache: per (window, repo), the answer of `git log <trunk sha>..<tip sha>`, keyed on both SHAs
# and the repo's history_view. Commits are content-addressed: for a fixed pair the answer can never change, so a ref
# moving changes the key, never the value. Only the board reads it; every command that ACTS on the answer (free_number,
# claim, delete, waiting-work) keeps its live check. No .json suffix: read_all and every lease-file reader never see it.

UNPROMOTED_CACHE = "unpromoted.cache"
CACHE_TMP_PREFIX = ".unpromoted-"
CACHE_TMP_MAX_AGE = 60      # seconds; a temp this old was left by a writer killed before its os.replace


def unpromoted_cache_path(root: Path) -> Path:
    return leases_dir(root) / UNPROMOTED_CACHE


def _cache_entry_ok(e: object) -> bool:
    return (isinstance(e, dict) and all(isinstance(e.get(k), str) and e.get(k) for k in ("tip", "trunk", "view"))
            and isinstance(e.get("subjects"), list) and all(isinstance(x, str) for x in e["subjects"])
            and isinstance(e.get("at"), (int, float)) and not isinstance(e.get("at"), bool))


def read_unpromoted_cache(root: Path) -> Tuple[dict, dict]:
    """(entries, cut) from the cache file. Unreadable, not JSON, a wrong version or a wrong shape is empty for what
    is bad (an entry with a missing or ill-typed field is dropped, the rest kept): every such lookup misses, and the
    next write replaces the file. Never a Refused, never on stderr."""
    try:
        d = json.loads(unpromoted_cache_path(root).read_bytes())
    except (OSError, ValueError, RecursionError):
        return {}, {}
    if not isinstance(d, dict) or d.get("v") != 1:
        return {}, {}
    ents = d.get("entries") if isinstance(d.get("entries"), dict) else {}
    cut = d.get("cut") if isinstance(d.get("cut"), dict) else {}
    return ({k: e for k, e in ents.items() if _cache_entry_ok(e)},
            {k: c for k, c in cut.items() if isinstance(c, str) and c})


def write_unpromoted_cache(root: Path, fresh: dict, keep=None, cut_set: Optional[dict] = None,
                           cut_drop: tuple = ()) -> None:
    """Merge `fresh` entries over the file as it is now (newer `at` wins per pair), drop entries `keep` rejects, set
    and drop `cut` markers, and replace the file (temp + os.replace). No lock: the lease lock stays free for creates
    and sweeps; two racing writers lose at most one's fresh entries, never correctness (every entry is a pure
    function of its key). Never makes state/leases/ (readers never make it, plan 5 Decision 13). A failed write is
    ignored: the board still draws what it computed."""
    d = leases_dir(root)
    if not d.is_dir():
        return
    now = time.time()
    try:
        for t in d.glob(CACHE_TMP_PREFIX + "*.tmp"):
            try:
                if now - t.stat().st_mtime > CACHE_TMP_MAX_AGE:
                    t.unlink()
            except OSError:
                pass
    except OSError:
        pass
    entries, cut = read_unpromoted_cache(root)
    for k, e in fresh.items():
        old = entries.get(k)
        if old is None or old.get("at", 0) <= e["at"]:
            entries[k] = e
    if keep is not None:
        entries = {k: e for k, e in entries.items() if keep(k)}
    for r in cut_drop:
        cut.pop(r, None)
    cut.update(cut_set or {})
    body = json.dumps({"v": 1, "entries": entries, "cut": cut}, sort_keys=True)
    try:
        fd, tmp = tempfile.mkstemp(dir=str(d), prefix=CACHE_TMP_PREFIX, suffix=".tmp")
    except OSError:
        return
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        os.replace(tmp, str(unpromoted_cache_path(root)))
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _cache_key(nn: str, repo: str) -> str:
    return "%s %s" % (nn, repo)


def _cache_entry(tip: str, trunk_sha: str, view: str, subjects: list) -> dict:
    return {"tip": tip, "trunk": trunk_sha, "view": view, "subjects": list(subjects), "at": time.time()}


class Waiting:
    """What the board knows about swept windows (spec §3.3). waiting: NN -> subjects, outer repo first;
    incomplete: the NNs of `waiting` not every repo answered for (drawn "at least N"); unchecked: NNs with no answer
    this time; unlisted: repo -> why its lease branches were not listed; errors: NN -> (repo, trunk, last stderr
    line) of a git error that is not a cut-off."""

    def __init__(self) -> None:
        self.waiting: Dict[str, list] = {}
        self.incomplete: set = set()
        self.unchecked: list = []
        self.unlisted: Dict[str, str] = {}
        self.errors: Dict[str, tuple] = {}

    def empty(self) -> bool:
        return not (self.waiting or self.unchecked or self.unlisted or self.errors)


LAST_COMMIT_NOT_READ = "last commit not read this time"
SWEPT_UNCHECKED = ("- %s — swept; not checked for unpromoted work this time — the next prompt finishes the check, "
                   "or run `core/lease.sh list` to check now")
SWEPT_AT_LEAST = ("- %s — swept, at least %d unpromoted commit%s waiting (%s); not every repo was checked this time: say "
                  "'this is window %s' to a new window to continue it, or 'delete %s's work', or run `core/lease.sh list` "
                  "for the full count")
CANNOT_TELL = "cannot tell whether lease/%s has unpromoted work in %s (git log origin/%s..lease/%s failed: %s)"
SWEPT_CANNOT_TELL = "- %s — swept; %s; run `git -C target/%s log -1 refs/heads/lease/%s` to see the error"
REPO_UNLISTED = "- target/%s's lease branches were not listed this time (%s); run `core/lease.sh list` to check them"


def waiting_lines(w: "Waiting") -> list:
    """The board's lines for swept windows (spec §3.3): waiting work (exact, or "at least" when not every repo
    answered — known work is never demoted to "not checked"), a git error on the window's own line, the windows not
    checked this time, then each repo that could not be listed. Every line that is not an answer names a command
    that works in every state the board draws in."""
    lines = []
    for nn in sorted(w.waiting):
        subs = w.waiting[nn]
        if nn in w.incomplete:
            lines.append(SWEPT_AT_LEAST % (nn, len(subs), "" if len(subs) == 1 else "s", _quoted(subs), nn, nn))
        else:
            lines.append("- %s — swept, %d unpromoted commit%s waiting (%s): say 'this is window %s' to a new window to continue it, or 'delete %s's work'"
                         % (nn, len(subs), "" if len(subs) == 1 else "s", _quoted(subs), nn, nn))
    for nn in sorted(w.errors):
        repo, trunk, last = w.errors[nn]
        lines.append(SWEPT_CANNOT_TELL % (nn, CANNOT_TELL % (nn, repo, trunk, nn, last), repo, nn))
    for nn in sorted(w.unchecked):
        lines.append(SWEPT_UNCHECKED % nn)
    for repo in sorted(w.unlisted):
        lines.append(REPO_UNLISTED % (repo, w.unlisted[repo]))
    return lines


def waiting_numbers(root: Path, leases: Dict[str, dict], deadline: Optional[float] = None,
                    write: bool = True) -> Waiting:
    """Swept numbers whose lease/<NN> still carries unpromoted commits (§4.2), in any target repo — the outer one
    and each nested one, as free_number judges them (release-candidate review 2, finding 7: a nested window's work
    was held back from new windows and named nowhere). Subjects of every repo, outer first. A nested repo whose
    trunk cannot be told is skipped (promote's doctor row names it); the outer one's missing origin/<trunk> is
    raised when it has a swept window to judge.

    v0.7.5 (spec §3.1, §3.3): one `for-each-ref` per repo lists every tip; answers come from the unpromoted-work
    cache when both SHAs and the history view match; misses are judged by one `for-each-ref --merged=<trunk sha>`
    per repo with two or more of them (phase A), then by one `log <trunk sha>..<tip sha>` per pair still open,
    window by window (phase B). `deadline`: no git call starts with fewer than MIN_CALL_SECS left, each gets what
    is left, and what was not reached is `unchecked` — answers already computed are written first, so the next
    prompt starts where this one stopped. A phase A cut off, or one that left windows to phase B, leaves a `cut`
    marker for (repo, trunk SHA), so the repo goes straight to phase B until its trunk moves or every miss of it is
    answered: progress is monotone. `write`
    False (doctor) reads the cache and never writes it."""
    res = Waiting()
    outer, trunk0 = target_name(root), v.target_branch(root)
    repos = repos_of(root)
    entries, cut = read_unpromoted_cache(root)
    listed: Dict[str, dict] = {}
    for repo in repos:
        target = root / "target" / repo
        if not target.is_dir():
            continue
        t = _left_f(deadline, 20)
        if t < MIN_CALL_SECS:
            res.unlisted[repo] = "cut off"
            continue
        try:
            info = _resolve_tips(target, repo, trunk0 if repo == outer else None, timeout=t)
        except CheckCut:
            res.unlisted[repo] = "cut off"
            continue
        except ListFailed as e:
            res.unlisted[repo] = str(e)
            continue
        if info is None:
            continue
        info["swept"] = {nn: sha for nn, sha in info["tips"].items() if nn not in leases}
        if info["trunk_sha"] is None:
            if info["swept"]:
                raise Refused(TRUNK_REF_MISSING % (repo, info["trunk"], repo))
            continue
        listed[repo] = info
    order = {repo: i for i, repo in enumerate(repos)}
    answers: Dict[tuple, list] = {}
    fresh: Dict[str, dict] = {}
    misses: Dict[str, list] = {}
    numbers = set()
    for repo, info in listed.items():
        for nn, tip in sorted(info["swept"].items()):
            numbers.add(nn)
            e = entries.get(_cache_key(nn, repo))
            if info["view"] and e and (e["tip"], e["trunk"], e["view"]) == (tip, info["trunk_sha"], info["view"]):
                answers[(nn, repo)] = list(e["subjects"])
            else:
                misses.setdefault(repo, []).append(nn)
    for k in entries:
        nn, _, repo = k.partition(" ")
        if repo in res.unlisted and valid_id(nn) and nn not in leases:
            numbers.add(nn)

    def answer(nn: str, repo: str, subs: list) -> None:
        answers[(nn, repo)] = subs
        info = listed[repo]
        if info["view"]:
            fresh[_cache_key(nn, repo)] = _cache_entry(info["swept"][nn], info["trunk_sha"], info["view"], subs)

    cut_set: Dict[str, str] = {}
    cut_drop = {r for r, c in cut.items() if r not in order or (r in listed and listed[r]["trunk_sha"] != c)}
    stopped = False
    # Phase A, per repo: which missed refs the trunk already contains, in one walk.
    for repo in sorted(misses, key=order.get):
        info, nns = listed[repo], misses[repo]
        if len(nns) < 2 or cut.get(repo) == info["trunk_sha"]:
            continue
        t = _left_f(deadline, 20)
        if t < MIN_CALL_SECS:
            stopped = True
            break
        code, out, _, was_cut = _git_t(root / "target" / repo, "for-each-ref", "--merged=" + info["trunk_sha"],
                                       "--format=%(objectname) %(refname)",
                                       *["refs/heads/lease/" + nn for nn in nns], timeout=t)
        if was_cut:
            cut_set[repo] = info["trunk_sha"]
            continue
        if code != 0:
            continue                    # a shortcut only: phase B judges these by the same predicate
        contained = {ref: sha for sha, ref in (ln.split(" ", 1) for ln in out.splitlines() if " " in ln)}
        for nn in nns:
            if contained.get("refs/heads/lease/" + nn) == info["swept"][nn]:     # at the SHA listed, never a newer tip
                answer(nn, repo, [])
        # The marker also stands when the walk finished but left windows to phase B: their answers land one window at
        # a time, and a prompt that spent its time repeating the same walk would never reach them (built, not spec).
        if any((nn, repo) not in answers for nn in nns):
            cut_set[repo] = info["trunk_sha"]
        else:
            cut_drop.add(repo)
    # Phase B, window by window, each across its repos.
    for nn, repo in sorted(((nn, repo) for repo, nns in misses.items() for nn in nns),
                           key=lambda p: (p[0], order[p[1]])):
        if stopped:
            break
        if (nn, repo) in answers or nn in res.errors:
            continue
        t = _left_f(deadline, 20)
        if t < MIN_CALL_SECS:
            break
        info = listed[repo]
        code, subs, err, was_cut = _log_at(root / "target" / repo, info["trunk_sha"], info["swept"][nn], t)
        if was_cut:
            break
        if code != 0:
            res.errors[nn] = (repo, info["trunk"], _last_line(err))
            continue
        answer(nn, repo, subs)
    # A repo whose misses are all answered needs its marker no more: it goes, so a later miss at the same trunk SHA
    # gets its walk again (a marker kept until the trunk moved cost a log per new miss; v0.7.5 review 2).
    for repo in set(cut) | set(cut_set):
        if repo in listed and all((nn, repo) in answers for nn in misses.get(repo, [])):
            cut_set.pop(repo, None)
            cut_drop.add(repo)
    for nn in sorted(numbers):
        if nn in res.errors:
            continue
        subs, complete = [], not res.unlisted
        for repo in sorted(listed, key=order.get):
            if nn in listed[repo]["swept"]:
                got = answers.get((nn, repo))
                if got is None:
                    complete = False
                else:
                    subs.extend(got)
        if subs:
            res.waiting[nn] = subs
            if not complete:
                res.incomplete.add(nn)
        elif not complete:
            res.unchecked.append(nn)
    if write:
        def keep(k: str) -> bool:
            nn, _, repo = k.partition(" ")
            if nn in leases or repo not in order:
                return False                  # live again, or no longer a target repo
            return not (repo in listed and nn not in listed[repo]["tips"])     # its branch is gone (listed repos only)
        if fresh or cut_set or (cut_drop & set(cut)) or any(not keep(k) for k in entries):
            write_unpromoted_cache(root, fresh, keep, cut_set, tuple(cut_drop))
    return res


def swept_loose(root: Path, leases: Dict[str, dict]) -> Dict[str, list]:
    """{"<NN>/<repo>": paths} — untracked files, and files with uncommitted changes, in the worktree of a window
    whose lease file is gone (swept: §4.5 keeps worktrees): work no board line names (release-candidate review 2,
    finding 7). Nested target repos inside a worktree are left out; they are judged as their own."""
    out: Dict[str, list] = {}
    base = root / "worktrees"
    try:
        nums = sorted(n for n in os.listdir(str(base)) if valid_id(n) and n not in leases)
    except OSError:
        return out
    repos = repos_of(root)
    for nn in nums:
        for repo in repos:
            wt = base / nn / repo
            if not (wt / ".git").exists():
                continue
            code, st, _ = _git(wt, "status", "--porcelain", "-z", "--untracked-files=all")
            if code != 0:
                continue
            nested = [r[len(repo) + 1:] for r in repos if r.startswith(repo + "/")]
            paths = []
            for ent in st.split("\0"):
                if len(ent) < 4:
                    continue
                path = ent[3:]
                if not any(path.rstrip("/") == n or path.startswith(n + "/") for n in nested):
                    paths.append(path)
            if paths:
                out["%s/%s" % (nn, repo)] = sorted(paths)
    return out


def announce_pushed(root: Path, sid: Optional[str]) -> list:
    """§4.3 'announce': a promotion confirmed in tty mode — from the operator's
    own shell (§7.4) — for which THIS session prepared is reported once, and its
    stamp renamed `announced`, once the confirming process has finished the
    work after the push (the stamp's finished_at) and saying what it could
    not do (its followups) in place of "brought forward"; this only tells the prime. A transcribed
    confirm ran in the prime itself and is never announced (plan 4 Decision 20)."""
    out = []
    base = root / "state" / "promote"
    if not sid or not base.is_dir():
        return out
    for stamp in sorted(base.glob("*/pushed")):
        try:
            s = json.loads(stamp.read_text())
            p = json.loads((stamp.parent / "prepared.json").read_text())
        except (OSError, ValueError):
            continue
        if s.get("confirm_mode") != "tty" or (p.get("prepared_by") or {}).get("session_id") != sid:
            continue
        if not s.get("finished_at"):
            continue          # the confirming shell is still bringing the checkout and marker forward
        try:
            os.rename(str(stamp), str(stamp.with_name("announced")))
        except OSError:
            continue          # another prompt of this session announced it first
        head = "Promotion of window %s's work was confirmed and pushed from your shell at %s (merge %s)" % (
            p.get("lease"), s.get("hhmm") or "?", str(s.get("merge_sha") or "")[:7])
        notes = [str(n) for n in s.get("followups") or [] if str(n).strip()]
        out.append(head + ("; not everything after the push was done: " + " ".join(notes) if notes else
                           "; your checkout and marker are already brought forward."))
    return out


def board_for(root: Path, sid: Optional[str], visitor: bool, recompute_all: bool = False,
              deadline: Optional[float] = None, with_mine: bool = False, check_deadline: Optional[float] = None,
              render_deadline: Optional[float] = None, busy: str = BOARD_LOCK_BUSY, recompute_share: float = 1.0):
    """The duties of §4.3 in one call: recompute the reader's changed set
    (every lease's for `list`/`status` — a shell has no budget), touch the
    reader's heartbeat, refresh stored pid/proc_started/peer_name from the
    registry for every lease whose session it shows live (so the file and the
    board agree, §4.1), render, and announce a tty-mode promotion confirmed
    from the operator's shell (announce_pushed). Never binds, numbers or takes the pen
    (§4.2). '' when no numbered lease exists. Never called while the lock is
    held (it takes the lock itself, twice); the git and ps work runs outside it.
    `deadline` bounds both lock acquires (SessionStart and the prompt hook):
    still busy then, it raises Refused(busy). v0.7.5: `check_deadline` bounds
    the swept-window checks and the reader's changed-set recompute (which gets
    at most `recompute_share` of what is left of it; the prompt hook passes
    RECOMPUTE_SHARE; what is not reached is drawn "not checked this time");
    `render_deadline` bounds the
    render's `git log -1` calls. A shell passes neither: it has no budget."""
    with lock(root, shared=True, deadline=deadline, busy=busy):
        leases = read_all(root)
    mine, _ = lease_of_session(leases, sid or "")
    wr = None
    if not any(k != "prime" for k in leases):
        # with no window open, swept work still waiting is still listed (review 2, finding 7) — and so is work
        # that could not be checked in time: "not checked" is never "no board" (v0.7.5 review, R10)
        wr = waiting_numbers(root, leases, deadline=check_deadline)
        if wr.empty():
            return ("", mine) if with_mine else ""
    # at a prompt the reader's changed set gets at most half of what is left of the check deadline: on its own it
    # could spend all of it on every prompt, and then no tip listing would ever start (v0.7.5 review 2)
    rc_deadline = None if check_deadline is None else time.time() + recompute_share * max(0.0, check_deadline - time.time())
    for nn, d in leases.items():
        if nn == "prime" or not (recompute_all or nn == mine):
            continue
        try:
            recompute_changed(root, nn, d, deadline=rc_deadline)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)     # the last computed set is kept (§4.1)
    if mine:
        heartbeat(root, mine)
    now, quiet_after = time.time(), stale_after_secs(root)
    states = {nn: liveness(root, nn, d, now, quiet_after) for nn, d in leases.items() if nn != "prime"}   # computed ONCE
    live_map = registry_live_map()                                                                          # read ONCE
    with lock(root, deadline=deadline, busy=busy):
        leases = read_all(root)
        for nn, d in leases.items():
            if nn != "prime" and d.get("session_id"):
                # a write only on a rename or a resume; nothing while a session is open in two terminals
                self_rebind(root, str(d["session_id"]), leases=leases, live=live_map.get(str(d["session_id"]), []))
        leases = read_all(root)
        changed = {nn: read_changed(root, nn) for nn in leases if nn != "prime"}
    if wr is None:
        wr = waiting_numbers(root, leases, deadline=check_deadline)
    text = render_board(root, sid, leases, changed, wr, states, now, visitor=visitor, live_map=live_map,
                        render_deadline=render_deadline)
    announced = announce_pushed(root, sid) if not visitor else []
    text = "\n".join(announced + [text]) if announced else text
    return (text, mine) if with_mine else text


def _since(ts: Optional[float], now: float) -> str:
    """When a window was last seen, for an operator: the clock time today,
    the date and time when older — a heartbeat from last month must not read
    as "since 09:40" this morning."""
    if ts is None:
        return "never seen"
    fmt = "%H:%M" if time.localtime(ts)[:3] == time.localtime(now)[:3] else "%Y-%m-%d %H:%M"
    return "no live session since " + time.strftime(fmt, time.localtime(ts))


# a window whose worktree was never made: its work is on lease/<NN> in target/, where no session builds
# (release-candidate red team, finding 1)
NO_WORKTREE_YET = "its worktree is not made yet: say 'this is window %s' to a new window (core/lease.sh claim %s) to make it"


def doctor_lines(root: Path) -> list:
    """The doctor's lease lines (spec §15), from ONE LOCK_SH read, with the
    same liveness call the board makes so doctor and the board never
    disagree. Each line carries its kind ("OK       ", "NOTE     ",
    "MISSING  ") and doctor.sh counts the MISSING ones. Plain language
    throughout: "03 (electron; no live session since 09:40)", never a bare
    token. Released and finished windows are neither live nor stale — they
    have their own line — so the counts describe windows someone might be
    sitting at."""
    try:
        with lock(root, shared=True):
            leases = read_all(root)
    except Refused as e:
        return ["MISSING  leases: %s" % e]
    numbered = {k: d for k, d in sorted(leases.items()) if k != "prime"}
    now, quiet_after = time.time(), stale_after_secs(root)
    live, stale, finished, released = [], [], [], []
    for nn, d in numbered.items():
        if d.get("released"):
            released.append(nn)
        elif d.get("finished"):
            finished.append(nn)
        elif liveness(root, nn, d, now, quiet_after) == "stale":
            stale.append(nn)
        else:
            live.append(nn)
    lines = ["OK       leases: state/leases/ (%d window%s live, %d stale)"
             % (len(live), "" if len(live) == 1 else "s", len(stale))]
    if stale:
        parts = []
        for nn in stale:
            alias = numbered[nn].get("alias")
            when = _since(seen_mtime(root, nn), now)
            parts.append("%s (%s; %s)" % (nn, alias, when) if alias else "%s (%s)" % (nn, when))
        lines.append("NOTE     leases: %d stale — %s; run core/lease.sh sweep" % (len(stale), ", ".join(parts)))
    if finished or released:
        parts = ["%s%s FINISHED (promote %s or release %s)" % (nn, " (spawned)" if numbered[nn].get("spawned") else "", nn, nn)
                 for nn in finished]
        parts += ["%s released (swept at next sweep)" % nn for nn in released]
        lines.append("NOTE     leases: %s" % "; ".join(parts))
    for nn, d in numbered.items():
        if d.get("worktree_ready") is False and not d.get("released"):
            lines.append("NOTE     leases: window %s%s has no worktree yet — say \"this is window %s\" to a new window "
                         "(core/lease.sh claim %s) to make it"
                         % (nn, " (adopted from %s)" % d["adopted_from"] if d.get("adopted_from") else "", nn, nn))
    try:
        wr = waiting_numbers(root, leases, write=False)     # doctor is a diagnostic: it reads the cache, never writes it
    except Refused as e:
        wr = Waiting()
        lines.append("NOTE     leases: cannot tell whether a swept number still has unpromoted work (%s)" % e)
    for nn in sorted(wr.waiting):
        k = len(wr.waiting[nn])
        lines.append("NOTE     leases: %s swept with %d unpromoted commit%s waiting — say \"this is window %s\" to a new window "
                     "to continue it, or \"delete %s's work\"" % (nn, k, "" if k == 1 else "s", nn, nn))
    for nn in sorted(wr.errors):
        repo, trunk, last = wr.errors[nn]
        lines.append("NOTE     leases: cannot tell whether a swept number still has unpromoted work (%s); run "
                     "git -C target/%s log -1 refs/heads/lease/%s to see the error" % (CANNOT_TELL % (nn, repo, trunk, nn, last), repo, nn))
    for nn in sorted(wr.unchecked):
        lines.append("NOTE     leases: %s swept, not checked for unpromoted work (a git call was cut off); run "
                     "core/lease.sh list to check it" % nn)
    # numbers free_number passes over for a checkout no lease explains (2026-10-19): named nowhere else — the boards
    # stay off this git call; doctor runs it once
    try:
        foreign = _foreign_numbers(root, {repo: "" for repo in repos_of(root)})     # it reads the repo names only
    except (Refused, OSError):
        foreign = {}
    for nn in sorted(k for k in foreign if k not in numbered):
        lines.append("NOTE     leases: %s %s; check what it holds and remove it (git worktree remove) to free the number"
                     % (nn, FOREIGN_WHY % (nn, foreign[nn])))
    for repo in sorted(wr.unlisted):
        lines.append("NOTE     leases: target/%s's lease branches could not be listed (%s); run core/lease.sh list "
                     "to check them" % (repo, wr.unlisted[repo]))
    for where, paths in sorted(swept_loose(root, leases).items()):
        nn = where.split("/", 1)[0]
        lines.append("NOTE     leases: worktrees/%s holds uncommitted or untracked files of swept window %s (%s) — say "
                     "\"this is window %s\" to a new window to continue it, or remove them"
                     % (where, nn, name_paths(paths), nn))
    return lines


# --- The on-screen band's data (lease-board spec §3) ----------------------------

# windows[].state. "swept-waiting" (since 2026-10-19): a swept number with unpromoted work, as last found by the
# model-facing board's waiting_numbers and read here from its cache — this reader still never runs git (spec §9 Q1).
BOARD_STATES = ("live", "quiet", "stale", "finished", "released", "swept-waiting")


BOARD_JSON_LOCK_WAIT = 1.5   # seconds; the band's tick is 2 s and its process timeout 5 s
BOARD_JSON_LOCK_BUSY = "the lease lock is busy — a window is being made or swept; the board refreshes when it frees"
_CONTROL_RUN = re.compile(r"\s*[\x00-\x1f\x7f]+\s*")   # a run of control characters and the blanks around it


def _band_text(value: object) -> Optional[str]:
    """A lease's free text as one row of the band can hold it: every run of
    control characters is one space; empty is None."""
    if not value:
        return None
    text = _CONTROL_RUN.sub(" ", str(value)).strip()
    return text or None


# The `ami` key of board-json (frame-jack spec §9.1): every sub-key, always — the mod relies on every key being present.
BOARD_AMI_KEYS = ("state", "mode", "port_alive", "device", "asked", "would_ask", "would_shorten", "unanswered",
                  "median_ms", "asks", "overrides", "since_epoch", "retry_epoch", "questions")


def board_ami(root: Path, sid: Optional[str]) -> dict:
    """The switch's word and this session's counts, from state/ami/ alone (amilib.board_ami: stats, one read of
    daemon.json, one of the counters file, one 100 ms-bounded connect — no config, no bash, no git). Outside the
    lease lock: it reads nothing under state/leases/. Any failure, amilib missing or broken included, is `absent`
    with every other key None — the band never goes blank over the AMI."""
    try:
        import amilib  # noqa: E402 — imported here so a deployment without it, or a broken copy, costs only this key
        got = amilib.board_ami(root, sid)
        return {k: got.get(k) for k in BOARD_AMI_KEYS}
    except Exception:
        out = dict.fromkeys(BOARD_AMI_KEYS)
        out["state"] = "absent"
        out["port_alive"] = False
        return out


def board_json(root: Path, sid: Optional[str]) -> dict:
    """The lease board as one object for the band above the prompt, which asks
    for it every 2 s in every open window. A READER: one pass over the lease
    files, .seen and .changed sidecars and prime.json under the shared lock,
    then liveness() per lease and registry_live_map() once — the same calls the
    model-facing board makes, so the two never disagree about a state. Never:
    git, heartbeat, self_rebind, recompute_changed, write_lease, waiting_numbers,
    an exclusive lock, or read_all's pruning of an empty file.

    Keys (spec §3.4): this_window, prime_window, windows (this window first,
    then by number), generated_epoch, ami (frame-jack spec §9.1: board_ami,
    every sub-key always present); each window has exactly nn, alias, state,
    changed_count, peer_name, is_prime, is_this, last_seen_epoch, note,
    waiting_count (null on a lease's row; on a swept-waiting row, the
    unpromoted commits the unpromoted-work cache holds for it). One
    more, `error`, only when a lease file could not be read: its operator
    sentence(s), while every readable window is still listed — one bad file
    must never blank the band (build brief, 2026-10-11; the spec's §3.5 exit 1
    was dropped for that reason).

    The shared lock is taken with a 1.5 s deadline, never a blocking wait: the
    writers hold the exclusive lock across git worktree adds and fetches
    (claim, create, adopt, sweep; up to the worktree budget), and a band that
    blocks there spawns another python3 every 2 s in every open window until
    the lock frees (review 2026-10-11, finding 2). Past the deadline this
    raises Refused with the busy sentence — exit 1, the band keeps its last
    good board and tries again at the next tick.

    alias, note and peer_name are plain text on one row of the band: every
    run of control characters (newline, ESC, ...) becomes one space (finding
    3), so a note typed with a newline cannot break the one-row-per-window
    layout and an escape sequence cannot reach the terminal."""
    errors: list = []
    with lock(root, shared=True, deadline=time.time() + BOARD_JSON_LOCK_WAIT, busy=BOARD_JSON_LOCK_BUSY):
        leases = read_all(root, prune_empty=False, errors=errors)
        numbered = {k: d for k, d in leases.items() if k != "prime"}
        seen = {nn: seen_mtime(root, nn) for nn in numbered}
        changed = {nn: read_changed(root, nn) for nn in numbered}
    prime_sid = (leases.get("prime") or {}).get("session_id") or None
    # both sides bound, else an unclaimed lease would read as the holder of a pen nobody took (§4.8); compared
    # unconverted, as render_board compares, so the two boards agree about the pen whatever the value's type
    # (finding 4)
    prime_nn = lease_of_session(leases, prime_sid)[0] if prime_sid else None
    mine = lease_of_session(leases, sid)[0] if sid else None
    now, quiet_after = time.time(), stale_after_secs(root)
    live_map = registry_live_map()                                      # read ONCE
    windows = []
    for nn in ([mine] if mine else []) + [k for k in sorted(numbered) if k != mine]:
        d = numbered[nn]
        if d.get("released"):
            state = "released"
        elif d.get("finished"):
            state = "finished"
        else:
            state = liveness(root, nn, d, now, quiet_after)
            if state == "resumed":
                state = "live"      # the window is live; the next model-facing render rebinds it
        entries = live_map.get(str(d.get("session_id")), []) if d.get("session_id") else []
        # §4.1: the peer name is re-read from the registry when exactly one live entry names the session
        peer = (entries[0].get("name") if len(entries) == 1 else None) or d.get("peer_name") or None
        # the sidecar is {"<repo>": {"<path>": "<first-seen stamp>"}} (compute_changed); distinct paths across repos
        paths: set = set()
        for per_repo in changed[nn].values():
            if isinstance(per_repo, (dict, list)):
                paths.update(str(x) for x in per_repo)
        windows.append({
            "nn": nn,
            "alias": _band_text(d.get("alias")),
            "state": state,
            "changed_count": len(paths),
            "peer_name": _band_text(peer),
            "is_prime": nn == prime_nn,
            "is_this": nn == mine,
            "last_seen_epoch": float(seen[nn]) if seen[nn] is not None else None,
            "note": _band_text(d.get("note")),
            "task": None if d.get("released") else (task_line(d.get("task")) or None),
            "waiting_count": None,
        })
    # Swept numbers still holding unpromoted work (2026-10-19: a terminal became 05 and the band showed no 02 or 03).
    # From the unpromoted-work cache the model-facing board keeps (waiting_numbers, every prompt) — a file read, no
    # git: as fresh as the last prompt's board, and a number no prompt has checked yet is no row. After the lease rows.
    entries, _ = read_unpromoted_cache(root)
    swept: Dict[str, int] = {}
    for k, e in entries.items():
        nn, _, _repo = k.partition(" ")
        if valid_id(nn) and nn not in numbered:
            swept[nn] = swept.get(nn, 0) + len(e["subjects"])
    for nn in sorted(k for k, n in swept.items() if n):
        windows.append({"nn": nn, "alias": None, "state": "swept-waiting", "changed_count": 0, "peer_name": None,
                        "is_prime": False, "is_this": False, "last_seen_epoch": None, "note": None,
                        "task": None, "waiting_count": swept[nn]})
    obj: dict = {"this_window": mine, "prime_window": prime_nn, "windows": windows, "generated_epoch": time.time(),
                 "ami": board_ami(root, sid)}
    if errors:
        obj["error"] = " ".join(str(e) for e in errors)
    return obj


# --- The registry's shape (lease-board spec §5) --------------------------------

# what liveness(), registry_live_map(), is_interactive_window() and the peer name read from sessions/<pid>.json
REGISTRY_FIELDS = ("pid", "sessionId", "startedAt", "procStart", "kind", "entrypoint", "name")
PROC_START_LAYOUT = "%a %b %d %H:%M:%S %Y"
# what each missing field costs, in the words of the thing that stops working
_REGISTRY_COST = (
    (("procStart",), "liveness falls back to startedAt for it"),
    (("kind", "entrypoint"), "this session cannot be told from a headless one; it will not number itself or take the pen"),
    (("name",), "its peer name is unknown; the board shows the one its lease stored"),
    (("sessionId",), "no lease can name this session"),
    (("startedAt",), "liveness has no fallback for it when procStart does not parse"),
    (("pid",), "liveness cannot check its process"),
)


def _same_dir(a: object, b: str) -> bool:
    try:
        return isinstance(a, str) and bool(a) and os.path.realpath(a) == b
    except (OSError, ValueError):
        return False


def doctor_registry_lines(root: Path) -> list:
    """One `registry shape` line for doctor.sh, OK or NOTE — never MISSING: the
    registry (~/.claude/sessions/<pid>.json) is undocumented and changed
    meaning on 2026-10-10 with nothing here saying so, and liveness has a
    fallback for every field it reads. Judged: this home's entries — a lease
    names the session, or cwd is this home — whose pid is alive (or absent:
    a renamed key is exactly the kind of change to report); an entry whose
    pid is dead is an ended session's left-behind file and nobody's business,
    and other projects' entries are not Daedalus's. NOT judged by
    pid_is_recorded_process: that test reads the very fields under check, so
    a registry whose shape or meaning changed would be filtered out and read
    OK (review 2026-10-11, finding 1). An entry that fails it is a NOTE saying
    its window reads dead. One NOTE per entry with a problem naming every
    missing field; a file that is not JSON is skipped as registry_live_map
    skips it, and counted; a directory that cannot be listed is a NOTE, not an
    OK with nothing to check (finding 7). Runs whether or not state/leases/
    exists."""
    d = registry_dir()
    if not d.is_dir():
        return ["NOTE     registry shape: %s is absent — nothing to check" % d]
    try:
        names = sorted(os.listdir(str(d)))
    except OSError as e:
        return ["NOTE     registry shape: %s cannot be read (%s) — liveness has no registry on this build"
                % (d, e.strerror or e)]
    by_sid: Dict[str, str] = {}
    if leases_dir(root).is_dir():
        try:
            with lock(root, shared=True):
                leases = read_all(root, prune_empty=False, errors=[])
        except OSError:
            leases = {}
        for nn, lease in leases.items():
            if nn != "prime" and lease.get("session_id"):
                by_sid[str(lease["session_id"])] = nn
    home = str(root.resolve())
    judged, notes, not_json = 0, [], []
    for name in names:
        if not name.endswith(".json"):
            continue
        p = d / name
        try:
            e = json.loads(p.read_text())
        except (OSError, ValueError):
            not_json.append("sessions/%s" % p.name)
            continue
        if not isinstance(e, dict):
            continue
        nn = by_sid.get(str(e.get("sessionId"))) if e.get("sessionId") else None
        if nn is None and not _same_dir(e.get("cwd"), home):
            continue
        pid = e.get("pid")
        if pid is not None and not pid_alive(pid):
            continue
        judged += 1
        where = "sessions/%s%s" % (p.name, " (window %s)" % nn if nn else "")
        # the test liveness applies; failing it with a live pid is the 2026-10-10 class, whatever else is wrong
        dead = pid is not None and not pid_is_recorded_process(pid, e.get("startedAt"), e.get("procStart"))
        reads_dead = ("is a live pid that fails the recorded-process test (startedAt=%s, procStart=%s) — the registry may "
                      "have changed meaning, or its process ended and the pid was reused; its window reads dead"
                      % (json.dumps(e.get("startedAt")), json.dumps(e.get("procStart"))))
        missing = [f for f in REGISTRY_FIELDS if e.get(f) is None]
        if missing:
            costs = [cost for fields, cost in _REGISTRY_COST if any(f in missing for f in fields)]
            notes.append("NOTE     registry shape: %s lacks %s — %s%s" % (where, ", ".join(missing), "; ".join(costs),
                                                                         ("; and " + reads_dead) if dead else ""))
        elif proc_start_text_ms(e.get("procStart")) is None:
            notes.append('NOTE     registry shape: %s has procStart "%s" that does not parse as "%s" UTC — liveness falls '
                         "back to startedAt for it%s" % (where, e.get("procStart"), PROC_START_LAYOUT,
                                                        ("; and " + reads_dead) if dead else ""))
        elif dead:
            notes.append("NOTE     registry shape: %s %s" % (where, reads_dead))
    if notes:
        lines = notes
    elif judged:
        lines = ["OK       registry shape: %d live window entr%s carr%s %s; procStart parses"
                 % (judged, "y" if judged == 1 else "ies", "ies" if judged == 1 else "y", ", ".join(REGISTRY_FIELDS))]
    else:
        lines = ["OK       registry shape: no live window entries to check"]
    if not_json:
        n = len(not_json)
        lines.append("NOTE     registry shape: %d registry file%s %s not JSON (%s)"
                     % (n, "" if n == 1 else "s", "is" if n == 1 else "are", ", ".join(not_json)))
    return lines


# --- CLI ----------------------------------------------------------------------

def main(argv: list) -> int:
    root = v.ROOT
    if len(argv) < 2:
        sys.stderr.write("usage: leaselib.py <command> ...\n")
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd in VISITOR_REFUSED and os.environ.get("DIRECT_CALL_ID"):
        # Before recompute_all_changed and every lock: a visitor writes nothing.
        sys.stderr.write("daedalus: %s\n" % (VISITOR_REFUSAL % cmd))
        return 1
    if cmd in COPY_GATED:
        try:
            import upgrade as up
            gated = up.copy_missing(root)
        except Exception:
            gated = False
        if gated:
            sys.stderr.write("daedalus: %s\n" % (up.COPY_FIRST_LEASE % cmd))
            return 1
    wait = None
    if cmd in WINDOW_MAKERS:        # upgrade.py is loaded only for these: `resolve` runs on every target_path
        try:
            import upgrade as up
            wait = up.windows_wait_lease(root, cmd, args)
        except Exception:
            wait = None
    if wait:
        # while the upgrade is not stamped no window is made or bound: target/ stays as the stop left it
        sys.stderr.write("daedalus: %s\n" % wait)
        return 1
    if cmd == "validate-id":
        return 0 if args and valid_id(args[0]) else 1
    if cmd == "validate-alias":
        return 0 if args and valid_alias(args[0], root) else 1
    if cmd == "heartbeat":
        heartbeat(root, args[0]); return 0
    if cmd == "resolve":
        try:
            print(resolve(root, session_id_from_env(), args[0]))
            return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)
            return 3
    if cmd == "liveness":
        lease = read_lease(root, args[0]) or {}
        print(liveness(root, args[0], lease)); return 0
    if cmd == "stale-after":
        print(stale_after_secs(root)); return 0
    if cmd == "my-lease":
        # gates.sh: the number of this session's lease for the run.json started
        # record (§4.9), or nothing — an operator shell, an unleased session, or
        # a deployment with no state/leases/ yet (never created here: lock()
        # would mkdir it as a side effect of a plain gate run).
        sid = session_id_from_env()
        nn = None
        if sid and leases_dir(root).is_dir():
            try:
                with lock(root, shared=True):
                    nn, _ = lease_of_session(read_all(root), sid)
            except Refused as e:
                sys.stderr.write("daedalus: %s\n" % e); return 1
        if nn:
            print(nn)
        return 0
    if cmd == "my-session":
        # vault-commit.sh: the caller's session id, or exit 1 for an operator shell.
        sid = session_id_from_env()
        if not sid:
            return 1
        print(sid); return 0
    if cmd == "vault-logs":
        # vault-commit.sh's full commit: one JSON row per reserved session log (vault_log_rows).
        try:
            for row in vault_log_rows(root, session_id_from_env()):
                print(json.dumps(row))
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
        return 0
    if cmd == "mark-log-pending":
        # close.sh after vault-commit.sh exit 3: one plain sentence, or nothing.
        try:
            line = mark_log_pending(root, session_id_from_env())
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
        if line:
            print(line)
        return 0
    if cmd == "pending-logs":
        for rel in pending_logs(root):
            print(rel)
        return 0
    if cmd == "clear-pending":
        clear_pending(root, list(args))
        return 0
    if cmd == "pen-for-commit":
        # vault-commit.sh step 1: exit 0 commit (a line when the pen moved), 3 the pen's holder commits (its line),
        # 1 a lease file cannot be read. Lines go to stdout; vault-commit.sh decides where they are shown.
        try:
            rc, line = pen_for_commit(root, session_id_from_env())
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
        if line:
            print(line)
        return rc
    if cmd in ("is-prime", "numbers"):
        # is-prime exits 0 when prime.json names the caller's session, or when the deployment has no lease
        # files at all (nothing to hold); vault-commit.sh judges the pen with pen-for-commit instead. numbers
        # prints one unswept window number per line for the default commit message. One LOCK_SH read; an
        # unreadable lease file fails closed.
        sid = session_id_from_env()
        leases: Dict[str, dict] = {}
        if leases_dir(root).is_dir():
            try:
                with lock(root, shared=True):
                    leases = read_all(root)
            except Refused as e:
                sys.stderr.write("daedalus: %s\n" % e); return 1
        numbered = sorted(k for k in leases if k != "prime")
        if cmd == "numbers":
            for nn in numbered:
                print(nn)
            return 0
        holder = (leases.get("prime") or {}).get("session_id")
        if sid is None or (not numbered and not holder):
            return 0
        return 0 if holder and holder == sid else 1
    if cmd == "changed":
        if not args:
            sys.stderr.write("usage: leaselib.py changed <NN>\n"); return 2
        try:
            print(json.dumps(recompute_changed(root, args[0]))); return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
    if cmd == "doctor-lines":
        # doctor.sh: one line per §15 lease row; MISSING lines are counted there.
        for line in doctor_lines(root):
            print(line)
        return 0
    if cmd == "doctor-registry":
        # doctor.sh: the registry shape line(s), OK or NOTE only (lease-board spec §5)
        for line in doctor_registry_lines(root):
            print(line)
        return 0
    if cmd == "session-end":
        # The tracked settings.json's SessionEnd hook: the payload on stdin; silent and exit 0 on every path — a hook
        # that cannot end a session has nothing to say to it.
        try:
            d = json.loads(sys.stdin.read() or "{}")
            sid = d.get("session_id") if isinstance(d, dict) else None
            # reason "clear": the terminal goes on (session-start reads a clear as continuing the session), so its
            # released lease is left for the real end, or for the next start's reclaim once the process is gone
            if isinstance(d, dict) and d.get("reason") != "clear":
                session_end_sweep(root, sid if isinstance(sid, str) else None)
        except Exception:
            pass
        return 0
    if cmd == "board-json":
        # The band above the prompt (the lease-board mod) runs this every 2 s in every window. A reader, so it sits
        # with doctor-lines and my-lease, outside the visitor, copy and upgrade gates: the operator wants to see the
        # board while the upgrade is pending (spec §14), and a visitor may read. --session because a mod's child is
        # not a Bash-tool child and carries no CLAUDE_CODE_SESSION_ID (lease-board spec §3.1).
        if not args:
            sid = session_id_from_env()
        elif len(args) == 2 and args[0] == "--session":
            sid = args[1] or None
        else:
            sys.stderr.write("usage: leaselib.py board-json [--session <id>]\n")
            return 2
        try:
            print(json.dumps(board_json(root, sid), sort_keys=True))
            return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)
            return 1
        except OSError as e:
            sys.stderr.write("daedalus: state/leases/ cannot be read (%s)\n" % (e.strerror or e))
            return 1
    if cmd in ("list", "status"):
        # sid is None from an operator shell: the head says "you hold no lease"
        # and there is no nag (a person at a shell holds no lease by design).
        try:
            print(board_for(root, session_id_from_env(), bool(os.environ.get("DIRECT_CALL_ID")), recompute_all=True)
                  or "No windows are open.")
            return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
    # §4.1: every lifecycle command recomputes every unswept lease's sidecar (a
    # shell has no budget). Before the dispatch and outside any lock — it takes
    # and releases LOCK_SH itself. list/status do it through the board (Task 8);
    # create and resolve do not (a spawner's create may run hook-adjacent, and
    # resolve is on every target_path).
    recompute = cmd in ("claim", "alias", "note", "task", "update", "release", "done", "sweep", "spawn", "prime", "rebase",
                        "split")
    if cmd == "prime":
        # a session holding no window takes the pen running no git at all (the pre-pass runs git in every window's
        # worktree): one shared read decides whether the caller holds a window
        psid = session_id_from_env()
        try:
            with lock(root, shared=True):
                recompute = bool(psid) and lease_of_session(read_all(root), psid)[0] is not None
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)
            return 1
    if recompute:
        try:
            recompute_all_changed(root)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)
            return 1
    if cmd == "registry-pids":
        print(" ".join(str(e.get("pid")) for e in registry_by_session(args[0]))); return 0
    if cmd == "registry-live-pids":
        print(" ".join(str(e.get("pid")) for e in registry_live_entries(args[0]))); return 0
    if cmd == "registry-kind":
        # doctor.sh (spec §15): this session's registry pair, when exactly one live entry names it
        live = registry_live_entries(args[0]) if args else []
        if len(live) == 1:
            print("kind=%s entrypoint=%s" % (live[0].get("kind"), live[0].get("entrypoint")))
        return 0
    if cmd == "pid-alive":
        return 0 if pid_alive(args[0]) else 1
    if cmd == "create":
        note = args[args.index("--note") + 1] if "--note" in args else None
        crit = args[args.index("--criteria") + 1] if "--criteria" in args else None
        try:
            # a spawner/operator path: fetch first (no network only inside a hook — §4.2)
            fetch_origin(root / "target" / target_name(root), timeout=60)
            reclaimed: list = []
            nn, data = allocate(root, None, note=note, criteria=crit, spawned="--spawned" in args, notes=reclaimed)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
        for sentence in reclaimed:
            print(sentence)
        print(launch_line(root, nn))
        if data.get("worktree_ready") is False:
            print("Window %s's worktree was not finished inside the budget; run `core/lease.sh claim %s` to finish it." % (nn, nn))
        return 0
    if cmd == "adopt":
        if args == ["--all-unfinished"]:
            # "pick it up": every piece of unfinished work in target/ the upgrade stopped on, a window each
            import upgrade as up
            return up.pick_up(root)
        if not args or args[0].startswith("--"):
            sys.stderr.write('usage: core/lease.sh adopt <branch> [--repo <nested>] [--note "..."] | adopt '
                             '--all-unfinished\n')
            return 2

        def _opt(flag: str) -> Optional[str]:
            return args[args.index(flag) + 1] if flag in args and args.index(flag) + 1 < len(args) else None

        try:
            r = adopt(root, args[0], repo=_opt("--repo"), note=_opt("--note"))
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)
            return 1
        print(adopt_sentence(r))
        if not r["already"]:
            print(launch_line(root, r["nn"]))
        return 0
    if cmd == "log":
        sid = session_id_from_env()
        if not sid:
            sys.stderr.write("daedalus: %s\n" % LOG_NEEDS_SESSION); return 1
        try:
            print(log_path(root, sid)); return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
    if cmd == "unpromoted":
        if not args or args[0].startswith("--"):
            sys.stderr.write("usage: core/lease.sh unpromoted <NN> [<NN> …]\n"); return 2
        try:
            print(unpromoted_report(root, [a for a in args if not a.startswith("--")], session_id_from_env())); return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
    if cmd == "waiting-work":
        try:
            trunk = v.target_branch(root)
            repo = root / "target" / target_name(root)
            require_trunk_ref(repo, repo.name, trunk)
            for s in waiting_work(repo, trunk, args[0]):
                print(s)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
        return 0
    if cmd in ("claim", "alias", "note", "task", "update", "release", "done", "sweep", "spawn", "prime", "rebase", "split"):
        def _refused(fn):
            try:
                out = fn()
                if out:
                    print(out)
                return 0
            except Refused as e:
                sys.stderr.write("daedalus: %s\n" % e)
                return 1

        def _after(flag: str) -> str:
            if flag not in args or args.index(flag) + 1 >= len(args):
                raise Refused("%s needs %s <value>" % (cmd, flag))
            return args[args.index(flag) + 1]

        if not args and cmd != "sweep":
            sys.stderr.write("usage: core/lease.sh %s <NN> ...\n" % cmd)
            return 2
        sid = session_id_from_env()
        if cmd == "claim":
            return _refused(lambda: claim(root, args[0], require_session(sid, "claim")))
        if cmd == "alias":
            if "--clear" in args:
                return _refused(lambda: "Window %s has no alias now." % set_field(root, args[0], "alias", "alias", None))
            if len(args) < 2:
                sys.stderr.write("usage: core/lease.sh alias <NN> <word> | alias <NN> --clear\n"); return 2
            return _refused(lambda: "Window %s is now shown as %s on the board."
                            % (set_field(root, args[0], "alias", "alias", args[1]), args[1]))
        if cmd == "note":
            if len(args) < 2:
                sys.stderr.write('usage: core/lease.sh note <NN> "..."\n'); return 2
            return _refused(lambda: "Noted for window %s." % set_field(root, args[0], "note", "note", args[1]))
        if cmd == "task":
            # v0.12.3: the window's own one line for its current task, apart from the operator's `note`; the board
            # shows it first on the window's line, so a window given a task can see what the others are doing.
            # Exactly <NN> and one quoted line, or <NN> --clear: an unquoted task would otherwise keep its first word.
            clear = args[1:] == ["--clear"]
            text = task_line(args[1]) if len(args) == 2 and not clear else ""
            if not clear and (not text or args[1].startswith("--")):
                sys.stderr.write('usage: core/lease.sh task <NN> "<one line: what this window is working on>" | task <NN> --clear\n'); return 2
            if clear:
                return _refused(lambda: "Window %s has no task on the board now." % set_task(root, args[0], sid, None))
            return _refused(lambda: "Window %s's task is on the board: %s" % (set_task(root, args[0], sid, text), text))
        if cmd == "update":
            return _refused(lambda: "Window %s's criteria file is %s."
                            % (set_field(root, args[0], "update", "criteria", _after("--criteria")), _after("--criteria")))
        if cmd == "release":
            # --operator-said carries the operator's whole reply to the delete line (the recorded yes, §4.2); read
            # here so its value is never mistaken for a token or a flag.
            # several numbers (v0.12.2): the leading words before the first flag; they go only with --remove
            nums = []
            for a in args:
                if a.startswith("--"):
                    break
                nums.append(a)
            said = _after("--operator-said") if "--operator-said" in args else None
            if len(nums) > 1:
                if "--remove" not in args:
                    sys.stderr.write("daedalus: Release one window at a time (each window releases itself); several "
                                     "numbers go with --remove, which deletes their work.\n")
                    return 1
                return _refused(lambda: release_many(root, nums, sid, force="--force" in args, said=said))
            return _refused(lambda: release(root, args[0], sid, remove="--remove" in args, force="--force" in args,
                                            said=said))
        if cmd == "done":
            return _refused(lambda: mark_done(root, args[0], require_session(sid, "done"), _after("--summary")))
        if cmd == "sweep":
            return _refused(lambda: "\n".join(sweep(root, _after("--force") if "--force" in args else None)) or "nothing to sweep")
        if cmd == "spawn":
            return _refused(lambda: spawn(root, args[0], _after("--note") if "--note" in args else None))
        if cmd == "prime":
            if args[:1] != ["take"]:
                sys.stderr.write('usage: core/lease.sh prime take [--reason "..."]\n'); return 2
            import transcriptlib as tl
            try:
                mode = tl.confirm_mode(root)
            except ValueError as e:
                sys.stderr.write("daedalus: %s\n" % e); return 1
            return _refused(lambda: prime_take(root, require_session(sid, "prime take"),
                                               _after("--reason") if "--reason" in args else None, mode=mode))
        if cmd == "rebase":
            return _refused(lambda: rebase(root, args[0], sid))
        if cmd == "split":
            return _refused(lambda: split(root, args[0], sid, _after("--repo")))
    if cmd == "_test-waiting":   # fixture helper for the suites; never used by a hook (v0.7.5 check path)
        # _test-waiting tips <repo> [trunk] | _test-waiting at <repo> <trunk sha> <tip sha>
        try:
            target = root / "target" / args[1]
            if args[0] == "tips":
                info = _resolve_tips(target, args[1], args[2] if len(args) > 2 else None)
                if info is not None and not info["trunk_sha"]:
                    raise Refused(TRUNK_REF_MISSING % (args[1], info["trunk"], args[1]))
                print(json.dumps(info, sort_keys=True))
            else:
                print(json.dumps(waiting_work_at(target, args[2], args[3])))
            return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
    if cmd == "_test-write":     # fixture helper for the suites; never used by a hook
        try:
            write_lease(root, args[0], json.loads(args[1]), exclusive="--exclusive" in args)
            return 0
        except FileExistsError:
            sys.stderr.write("daedalus: lease file %s already exists\n" % args[0]); return 1
    sys.stderr.write("leaselib.py: unknown command %s\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
