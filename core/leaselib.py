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

import contextlib
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterator, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

LEASE_RE = re.compile(r"[0-9]{2}")
ALIAS_RE = re.compile(r"[a-z][a-z0-9-]{1,31}")
ALIAS_DENY = {"prime", "main", "master", "target", "vault", "state"}
NEVER_ISSUED = "00"


class Refused(Exception):
    """A resolution that must fail closed; str(e) is the operator sentence."""


BOARD_UNRENDERED = "The lease board could not be rendered: %s"

# SessionStart's two lease-lock waits are bounded by the hook's budget (§4.2;
# plan 2 Decision 18). What each says when the lock stays busy past it:
LOCK_BUSY_AT_START = ("This window was not bound at start: the lease lock stayed busy past the start budget (a "
                      "`core/lease.sh` command or another window's start was holding it). Run `core/lease.sh claim "
                      "<NN>` with your window's number, or `core/lease.sh create` and claim the number it prints.")
BOARD_LOCK_BUSY = "the lease lock stayed busy past the start budget; the board renders at your next prompt"


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
    try:
        d = json.loads(text)
    except ValueError as e:
        raise _unreadable(nn, "not valid JSON: %s" % e)
    if not isinstance(d, dict):
        raise _unreadable(nn, "not a JSON object")
    return d


def read_all(root: Path) -> Dict[str, dict]:
    """Every lease file, keyed by number ('prime' for prime.json). Caller holds
    the lock. Raises Refused on the first file that exists but cannot be read."""
    out: Dict[str, dict] = {}
    d = leases_dir(root)
    if not d.is_dir():
        return out
    for p in sorted(d.glob("*.json")):
        key = p.stem
        if key != "prime" and not valid_id(key):
            continue
        data = read_lease(root, key)
        if data is not None:
            out[key] = data
    return out


def write_lease(root: Path, nn: str, data: dict, exclusive: bool = False) -> None:
    """tmp + os.replace. exclusive=True: O_CREAT|O_EXCL on the final path so a
    second allocator that computed the same number gets FileExistsError."""
    d = leases_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    final = lease_path(root, nn)
    if exclusive:
        fd = os.open(str(final), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)  # raises FileExistsError
        os.close(fd)
    fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".lease-", suffix=".json")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2)
    os.replace(tmp, str(final))


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


def resolve_lease(leases: Dict[str, dict], sid: str) -> Tuple[Optional[str], Optional[dict]]:
    """§4.4 steps 2–3 over an already-read lease dict. Pure: no I/O, no lock.
    (nn, lease) when the session is bound; (None, None) when no lease file
    exists or the session holds only the pen; Refused for every case that
    must fail closed. The PreToolUse hooks call this on lease_context's read."""
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
    if leases.get("prime", {}).get("session_id") == sid:
        return None, None
    raise Refused("Several sessions are live and I cannot tell which tree is mine. This session holds no lease; "
                  "run `core/lease.sh create` and then `claim <NN>`.")


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
    nn, lease = resolve_lease(leases, sid)
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
    return [e for e in registry_by_session(sid) if pid_is_recorded_process(e.get("pid"), e.get("startedAt"))]


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
    """Epoch milliseconds from `ps -o lstart=` (local time; the registry's
    procStart string is UTC, so never compare strings — §4.5)."""
    code, out, _ = v.run(["ps", "-o", "lstart=", "-p", str(pid)], timeout=5)
    out = out.strip()
    if code != 0 or not out:
        return None
    try:
        return int(time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y")) * 1000)
    except ValueError:
        return None


def pid_is_recorded_process(pid: object, proc_started: object) -> bool:
    """The pid is alive AND is the process the record was made for: its start
    time is within 2 s of the recorded start (a recycled pid fails here), or —
    when ps cannot be parsed — its command is claude. The record is a lease's
    (pid, proc_started) or a registry entry's (pid, startedAt): the registry
    writes startedAt under a second after the process starts (936 ms measured
    on 2.1.282), so one predicate serves both, and a left-behind
    sessions/<pid>.json whose pid another process now holds is not "live"."""
    if not pid_alive(pid):
        return False
    started = proc_started_of(pid)
    if started is None:
        code, out, _ = v.run(["ps", "-o", "comm=", "-p", str(pid)], timeout=5)
        return code == 0 and out.strip().endswith("claude")
    try:
        return abs(int(started) - int(proc_started)) <= 2000
    except (TypeError, ValueError):
        return False


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
    if pid_is_recorded_process(pid, lease.get("proc_started")):
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
    out: Dict[str, str] = {}
    for repo in repos_of(root):
        if "/" not in repo:
            out[repo] = trunk
        else:
            code, head, _ = v.run(["git", "-C", str(target_base / repo), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
            head = head.strip()
            if code != 0 or not head.startswith("origin/"):
                raise Refused("nested repo %s has no origin/HEAD — run git -C target/%s remote set-head origin -a"
                              % (repo.split("/", 1)[1], repo))
            out[repo] = head[len("origin/"):]
        require_trunk_ref(target_base / repo, repo, out[repo])
    return out


def require_trunk_ref(target_repo: Path, repo: str, trunk: str) -> None:
    """origin/<trunk> must resolve before any number is judged or cut. Without
    it, `merge-base --is-ancestor` exits 128 and `git log origin/x..lease/NN`
    prints nothing — which read as "nothing waiting", and a swept window's
    unpromoted commits were silently adopted by the next session (§4.2)."""
    code, _, _ = v.run(["git", "-C", str(target_repo), "rev-parse", "--verify", "-q", "origin/" + trunk])
    if code != 0:
        raise Refused("target/%s has no origin/%s — check config target.branch, or run git -C target/%s fetch origin"
                      % (repo, trunk, repo))


def waiting_work(target_repo: Path, trunk: str, nn: str) -> list:
    """Subjects of commits on lease/<NN> that origin/<trunk> does not contain;
    [] when there are none or the branch is absent (§4.2 'Numbering')."""
    branch = "lease/%s" % nn
    code, _, _ = v.run(["git", "-C", str(target_repo), "rev-parse", "--verify", "-q", branch])
    if code != 0:
        return []
    code, _, err = v.run(["git", "-C", str(target_repo), "merge-base", "--is-ancestor", branch, "origin/" + trunk])
    if code == 0:
        return []
    if code != 1:
        # 128 (a missing ref) and everything else is an ANSWER WE DO NOT HAVE,
        # never "not an ancestor" and never "nothing waiting".
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot tell whether %s has unpromoted work in %s (git merge-base against origin/%s failed: %s)"
                      % (branch, target_repo.name, trunk, last[0]))
    code, out, err = v.run(["git", "-C", str(target_repo), "log", "--format=%s", "origin/%s..%s" % (trunk, branch)])
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot list %s's unpromoted work in %s (git log origin/%s..%s failed: %s)"
                      % (branch, target_repo.name, trunk, branch, last[0]))
    return [ln for ln in out.splitlines() if ln.strip()]


def free_number(root: Path, leases: Dict[str, dict], target_base: Path, trunks: Dict[str, str]) -> str:
    """The lowest number 01–99 that no lease file holds and no swept lease's
    unpromoted work is waiting under. Caller holds the lock."""
    for i in range(1, 100):
        nn = "%02d" % i
        if nn in leases:
            continue
        if any(waiting_work(target_base / repo, trunks[repo], nn) for repo in trunks):
            continue
        return nn
    raise Refused("no free window number: 01–99 are all held; run `core/lease.sh sweep`")


def _git(repo: Path, *args: str, timeout: int = 20) -> Tuple[int, str, str]:
    return v.run(["git", "-C", str(repo)] + list(args), timeout=timeout)


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
    return _run_bounded(["git", "-C", str(repo)] + list(args), left)


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

        r = git("worktree", "prune")
        if r is None or r[0] == 127:
            return False
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
                    if _registered(r2[1], dest):
                        last = r[2].strip().splitlines()[-1:] or ["no output"]
                        raise Refused("worktrees/%s/%s is a half-finished checkout (its add was interrupted) and git "
                                      "would not remove it: %s" % (nn, repo, last[0]))
                    # git deregistered it, then failed on the directory: finish the job.
                    shutil.rmtree(str(dest), ignore_errors=True)
                    if dest.exists():
                        raise Refused("worktrees/%s/%s is left over from an interrupted checkout and could not be "
                                      "deleted; move it aside." % (nn, repo))
                    r = git("worktree", "prune")
                    if r is None or r[0] == 127:
                        return False
                registered = False
        r = git("rev-parse", "--verify", "-q", branch)
        if r is None or r[0] == 127:
            return False
        has_branch = r[0] == 0
        if not registered:
            if has_branch:
                r = git("worktree", "add", str(dest), branch)
            else:
                r = git("worktree", "add", str(dest), "-b", branch, "origin/" + trunk)
            if r is None or r[0] == 127:
                return False   # no time left, or cut off: claim finishes it
            if r[0] != 0:
                last = r[2].strip().splitlines()[-1:] or ["no output"]
                raise Refused("git worktree add for window %s (%s) failed: %s" % (nn, repo, last[0]))
        if has_branch or registered:
            r = git("merge", "--ff-only", "--quiet", "origin/" + trunk, cwd=dest)
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


def allocate_locked(root: Path, sid: Optional[str], note: Optional[str] = None, criteria: Optional[str] = None,
                    spawned: bool = False, timeout: Optional[int] = None,
                    deadline: Optional[float] = None) -> Tuple[str, dict]:
    """§4.2 'Allocation': lowest free number; prune; re-use or refuse; worktree
    add; lease O_EXCL; empty .changed. CALLER HOLDS THE LOCK (session_start_bind
    and claim call this from inside theirs; the lock is not re-entrant).
    `deadline` bounds the worktree adds (SessionStart's budget, §4.2)."""
    timeout = int(os.environ.get("LEASE_WORKTREE_TIMEOUT") or (timeout or 20))
    target_base = root / "target"
    trunks = trunks_of(root, target_base)
    while True:
        leases = read_all(root)
        nn = free_number(root, leases, target_base, trunks)
        data = {"lease": nn, "session_id": sid, "peer_name": None, "pid": None, "proc_started": None,
                "worktree": "worktrees/%s" % nn, "branch": "lease/%s" % nn,
                "repos": list(trunks), "trunks": trunks, "created": now_stamp(),
                "bound_at": now_stamp() if sid else None, "promoted": []}
        if note:
            data["note"] = note
        if criteria:
            data["criteria"] = criteria
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
                  "peer_name": entry.get("name") if entry else None})
    fresh.pop("released", None)
    if expect and expect != sid:
        # A takeover from a dead holder: the old holder's report (`done`) and
        # its spawned mark describe THAT session, not this one — an interactive
        # takeover is not a spawned clone and has not reported. Left in place
        # they render a live window FINISHED and keep sweep from ever clearing
        # it (Task 4 review). A null holder is the clone's own first binding of
        # a spawned lease, which keeps spawned: true.
        for key in ("finished", "summary", "spawned"):
            fresh.pop(key, None)
    if finish_worktree and fresh.get("worktree_ready") is False:
        if add_worktrees(root, nn, fresh.get("trunks") or trunks_of(root, root / "target"), deadline=deadline):
            fresh.pop("worktree_ready", None)
    write_lease(root, nn, fresh)
    heartbeat(root, nn)
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
                  or lease.get("peer_name") != entry.get("name")):
        lease.update({"pid": entry.get("pid"), "proc_started": entry.get("startedAt"), "peer_name": entry.get("name")})
        write_lease(root, nn, lease)
    return nn


def claim(root: Path, token: str, sid: str) -> str:
    """Bind this session to window NN. A swept number (no lease file) whose
    lease/<NN> still carries unpromoted commits is adopted as-is and its
    subjects are named — the one path that continues such work (§4.2)."""
    with lock(root):
        leases = read_all(root)
        nn = number_of(leases, token, "claim")
        held, held_lease = lease_of_session(leases, sid)
        if held and held != nn:
            # One lease per session id: resolve, the board, self_rebind and
            # done's prime lookup all read the ONE lease that names a session.
            if held_lease.get("released"):
                raise Refused("This session was window %s and released it; this window is done — close it and open a "
                              "new terminal for a fresh number." % held)
            raise Refused("This session is already window %s; say 'release %s' first." % (held, held))
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


def dirty_files(worktree: Path) -> list:
    """Paths `git status` reports in a lease worktree — modified, staged and
    untracked alike; [] for a clean tree or a path that is not there. A
    failing status is an answer we do not have, never 'clean'."""
    if not worktree.is_dir():
        return []
    code, out, err = _git(worktree, "status", "--porcelain", "--untracked-files=all")
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot tell whether %s has uncommitted changes (git status failed: %s)" % (worktree, last[0]))
    return [ln[3:].split(" -> ")[-1] for ln in out.splitlines() if len(ln) > 3]


def _remove_lease_files(root: Path, nn: str) -> None:
    for p in (lease_path(root, nn), leases_dir(root) / (nn + ".seen"), leases_dir(root) / (nn + ".changed")):
        try:
            p.unlink()
        except FileNotFoundError:
            pass


def release(root: Path, token: str, sid: Optional[str], remove: bool = False, force: bool = False) -> str:
    """The holder ends its lease: released: <time> (removed at the next
    sweep, so the holder's own hooks can still read the state). Any other
    session is refused while the holder is live; a stale lease may be released
    from anywhere, and an operator shell (sid None) may release anything.
    --remove deletes worktree and branch, refusing unpromoted commits and
    uncommitted changes without --force and naming them (subjects, file
    paths) before deleting them (§4.2, §4.5)."""
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
        trunks = lease.get("trunks") or {}
        subjects = [s for repo in trunks for s in waiting_work(root / "target" / repo, trunks[repo], nn)]
        # Uncommitted work is work too (§4.5): `git worktree remove` refuses a
        # dirty tree on its own, and the --force below would bypass that
        # refusal silently, so it is gated and named here first (Task 4 review).
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
        if problems and not force:
            raise Refused("Window %s %s. Add --force to delete them." % (nn, ", and ".join(problems)))
        out = []
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
                _git(src, "worktree", "prune")
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
        out.append("Window %s released; its worktree and branch are deleted." % nn)
        return "\n".join(out)


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
        code, _, err = _git(root / "target" / repo, "fetch", "--quiet", "origin", timeout=120)
        if code != 0:
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("could not fetch origin in target/%s (%s); window %s was not rebased" % (repo, last[0], nn))
    # Every repo is counted before any is rebased: a count that fails refuses
    # while no worktree has moved, so "was not rebased" stays true.
    counts = {repo: (_count(root, nn, repo, trunk, "origin/%s..HEAD" % trunk),
                     _count(root, nn, repo, trunk, "HEAD..origin/%s" % trunk)) for repo, trunk in trunks.items()}
    report = []
    for repo, trunk in trunks.items():
        wt = root / "worktrees" / nn / repo
        ahead, behind = counts[repo]
        if behind == 0:
            report.append("%s already up to date" % repo)
            continue
        code, _, err = _git(wt, "rebase", "--quiet", "origin/" + trunk, timeout=300)
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
        _git(src, "worktree", "prune")
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
    code, _, err = _git(src, "fetch", "--quiet", "origin", timeout=120)
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
        code, _, err = _git(dest, "cherry-pick", "origin/%s..lease/%s" % (ntrunk, nn), timeout=300)
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
        code, _, err = _git(root / "worktrees" / nn / key, "reset", "--hard", "--quiet", "origin/" + ntrunk)
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


LEASE_BRANCH = re.compile(r"lease/[0-9]{2}")
ADOPT_DIRTY = ("target/%s has uncommitted changes — commit them on their branch inside that checkout, or stash them, "
               "then run adopt again.")


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
    code, out, err = _git(src, "cherry", "origin/" + trunk, rev)
    if code != 0:
        last = err.strip().splitlines()[-1:] or ["no output"]
        raise Refused("cannot compare %s with origin/%s in %s (%s)" % (rev, trunk, src.name, last[0]))
    subjects = []
    for ln in out.splitlines():
        if ln.startswith("+ "):
            _, s, _ = _git(src, "log", "-1", "--format=%s", ln[2:].strip())
            subjects.append(s.strip())
    return subjects


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


ADOPT_DETACHED = ("target/%s is on a detached HEAD (%s) holding commits no branch has; adopting %s would put the "
                  "checkout on %s and leave them behind — give them a branch inside that checkout "
                  "(git -C target/%s branch <name>), then run adopt again.")


def adopt(root: Path, branch: str, repo: Optional[str] = None, note: Optional[str] = None,
          fetch: bool = True, deadline: Optional[float] = None) -> dict:
    """`lease.sh adopt <branch> [--repo <nested>] [--note "..."]` (spec §4.2, §14 step 6): a branch of target/<repo>
    that carries work trunk does not have becomes a numbered window with no session bound — the same allocation
    `create` and `split` use. target/<repo> goes back to its trunk at origin/<trunk>; the branch is renamed
    lease/<NN> and checked out at worktrees/<NN>/<repo>; the other repos' worktrees are cut at their trunks.
    `adopt <trunk>` moves a trunk that is ahead of origin: lease/<NN> is made at the trunk's tip, the window is
    made, and only then is the trunk reset; adopted_from names it daedalus/upgrade-<stamp>-<short sha> (plan 5
    Decision 14 — a label, no such branch is left). Idempotent: a branch already adopted returns {"already":
    True}; a trunk whose tip is a window's adopted_tip (a run cut off before the reset) is reset and returns
    "already". Refused: a dirty target/<repo> (tracked changes), a branch that does not exist or is a window's,
    nothing past trunk, a detached checkout holding commits no branch has. The fetch (a shell path, §4.2) runs
    before the lock; the upgrade passes fetch=False — it fetched already — and its start deadline.

    Order (plan 5 Task 2 review, finding 1): the first change is always making lease/<NN> (a rename, or for a
    trunk a new branch at its tip, the trunk untouched), so a process killed at any later point leaves the work
    on lease/<NN> — with a lease file the board lists the window, without one the board lists the number as
    waiting work and `claim <NN>` adopts it. A refusal after that point undoes every change: the lease file,
    lease/<NN> (renamed back, or deleted when it was made here), and target/<repo>'s checkout."""
    key = repo_key(root, repo)
    src = root / "target" / key
    if fetch:
        code, _, err = _git(src, "fetch", "--quiet", "origin", timeout=120)
        if code != 0:
            last = err.strip().splitlines()[-1:] or ["no output"]
            raise Refused("could not fetch origin in target/%s (%s); nothing was adopted" % (key, last[0]))

    def _last(err: str) -> str:
        return (err.strip().splitlines()[-1:] or ["no output"])[0]

    with lock(root, deadline=deadline, busy="the lease lock stayed busy; nothing was adopted"):
        leases = read_all(root)
        for nn, d in sorted(leases.items()):
            if nn != "prime" and d.get("adopted_from") == branch and d.get("adopted_repo") == key:
                return {"nn": nn, "repo": key, "branch": branch, "trunk": (d.get("trunks") or {}).get(key, ""),
                        "subjects": [], "already": True, "notes": []}
        if LEASE_BRANCH.fullmatch(branch):
            raise Refused("%s is already a window's branch; nothing to adopt." % branch)
        trunks = trunks_of(root, root / "target")
        trunk = trunks[key]
        code, _, _ = _git(src, "rev-parse", "--verify", "-q", "refs/heads/" + branch)
        if code != 0:
            raise Refused("target/%s has no branch %s." % (key, branch))
        code, dirt, _ = _git(src, "status", "--porcelain", "--untracked-files=no")
        if code != 0 or dirt.strip():
            raise Refused(ADOPT_DIRTY % key)
        _, cur, _ = _git(src, "branch", "--show-current")
        cur = cur.strip()
        _, head, _ = _git(src, "rev-parse", "HEAD")
        head = head.strip()
        _, tip, _ = _git(src, "rev-parse", branch)
        tip = tip.strip()
        notes = []
        is_trunk = branch == trunk
        if is_trunk:
            code, out, _ = _git(src, "log", "--reverse", "--format=%s", "origin/%s..%s" % (trunk, trunk))
            subjects = [s for s in out.splitlines() if s.strip()] if code == 0 else []
            if not subjects:
                raise Refused("target/%s's %s has no commits that are not already on origin/%s — nothing to adopt."
                              % (key, trunk, trunk))
            for nn, d in sorted(leases.items()):
                # a run cut off after the window was made, before the trunk was reset: finish it
                if (nn != "prime" and d.get("adopted_repo") == key and d.get("adopted_tip") == tip
                        and str(d.get("adopted_from", "")).startswith("daedalus/upgrade-")):
                    code, _, err = _git(src, *_trunk_reset(cur, trunk))
                    if code != 0:
                        raise Refused("could not reset target/%s's %s to origin/%s (%s); window %s holds its commits"
                                      % (key, trunk, trunk, _last(err), nn))
                    return {"nn": nn, "repo": key, "branch": trunk, "trunk": trunk, "subjects": [], "already": True,
                            "notes": ["target/%s's %s was reset to origin/%s" % (key, trunk, trunk)]}
            # the window's name for the work: never the trunk's (plan 5 Decision 14) — so the "same-named branch
            # on origin" note cannot fire for a trunk, and a later trunk-ahead case is adopted again
            original = "daedalus/upgrade-%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), tip[:7])
        else:
            subjects = unpromoted_commits(src, trunk, branch)
            if not subjects:
                raise Refused("%s in target/%s has no commits that are not already on origin/%s — nothing to adopt."
                              % (branch, key, trunk))
            if not cur and not _held_elsewhere(src, head):
                raise Refused(ADOPT_DETACHED % (key, head[:7], branch, trunk, key))
            original = branch
        nn = _adopt_number(root, leases, trunks)
        new = "lease/" + nn
        # the first change: lease/<NN> holds the work from here on
        code, _, err = _git(src, *(("branch", new, tip) if is_trunk else ("branch", "-m", branch, new)))
        if code != 0:
            raise Refused("could not %s lease/%s in target/%s (%s); nothing was adopted"
                          % ("make" if is_trunk else "rename %s to" % branch, nn, key, _last(err)))
        data = {"lease": nn, "session_id": None, "peer_name": None, "pid": None, "proc_started": None,
                "worktree": "worktrees/%s" % nn, "branch": new, "repos": list(trunks), "trunks": trunks,
                "created": now_stamp(), "bound_at": None, "promoted": [], "adopted_from": original,
                "adopted_repo": key, "adopted_tip": tip, "worktree_ready": False}
        if note:
            data["note"] = note
        wrote = False
        try:
            write_lease(root, nn, data, exclusive=True)
            wrote = True
            if not is_trunk and cur != trunk:
                # off the renamed branch (or wherever it was) before lease/<NN> is checked out in its worktree
                code, _, err = _git(src, "checkout", "--quiet", trunk)
                if code != 0:
                    raise Refused("could not put target/%s back on %s (%s); nothing was adopted" % (key, trunk, _last(err)))
            ready = add_worktrees(root, nn, trunks, deadline=deadline)
        except BaseException:
            if wrote:
                try:
                    os.unlink(str(lease_path(root, nn)))
                except OSError:
                    pass
            _adopt_undo(root, trunks, src, key, nn, branch, is_trunk, cur, head)
            raise
        if ready:
            data.pop("worktree_ready", None)
            write_lease(root, nn, data)
        write_changed(root, nn, {})
        heartbeat(root, nn)
        # last: target/<repo> to origin/<trunk>. For a trunk this is the reset — lease/<NN> and the lease file
        # already hold the commits; a re-run finishes a reset that did not happen (above).
        if is_trunk:
            code, _, err = _git(src, *_trunk_reset(cur, trunk))
            if code != 0:
                notes.append("target/%s's %s could not be reset to origin/%s (%s) and still holds these commits too; "
                             "run adopt %s again to finish" % (key, trunk, trunk, _last(err), trunk))
        else:
            code, _, err = _git(src, "merge", "--ff-only", "--quiet", "origin/" + trunk)
            if code != 0:
                notes.append("target/%s's %s could not be fast-forwarded to origin/%s (%s)"
                             % (key, trunk, trunk, _last(err)))
            code, _, _ = _git(src, "rev-parse", "--verify", "-q", "refs/remotes/origin/" + original)
            if code == 0:
                notes.append("a branch named %s on origin was left alone" % original)
    return {"nn": nn, "repo": key, "branch": original, "trunk": trunk, "subjects": subjects, "already": False,
            "notes": notes}


def _trunk_reset(cur: str, trunk: str) -> tuple:
    """The git arguments that put <trunk> at origin/<trunk>: a hard reset when it is checked out (the checkout
    is clean — adopt refused otherwise), else a forced branch move."""
    return (("reset", "--hard", "--quiet", "origin/" + trunk) if cur == trunk
            else ("branch", "-f", trunk, "origin/" + trunk))


def _adopt_undo(root: Path, trunks: Dict[str, str], src: Path, key: str, nn: str, branch: str, is_trunk: bool,
                cur: str, head: str) -> None:
    """Best effort, after a refusal. In every repo, a worktree at worktrees/<NN>/<repo> on lease/<NN> is removed
    (only this call can have made one: lease/<NN> existed nowhere before it — _adopt_number; git refuses a dirty
    one). In the other repos lease/<NN>, cut here from origin/<trunk>, is deleted. In target/<repo>, lease/<NN> is
    deleted when it was made at a trunk's tip (the trunk still holds the commits), else renamed back to <branch>,
    and the checkout goes back where it was. Anything git refuses is left as it is — the work stays on
    lease/<NN>, which the board lists as waiting work."""
    new = "lease/" + nn
    for repo in trunks:
        rsrc = root / "target" / repo
        dest = root / "worktrees" / nn / repo
        code, listed, _ = _git(rsrc, "worktree", "list", "--porcelain")
        if code == 0 and dest.exists() and _registered(listed, dest):
            _, on, _ = _git(dest, "branch", "--show-current")
            if on.strip() == new:
                _git(rsrc, "worktree", "remove", str(dest))
        if repo != key:
            _git(rsrc, "branch", "-D", new)
    if is_trunk:
        _git(src, "branch", "-D", new)
        return
    _git(src, "branch", "-m", new, branch)
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

def sweep(root: Path, force_nn: Optional[str] = None) -> list:
    """Remove stale and released lease files. A quiet one only as --force <NN>
    (the operator's word); a finished one waits for promote or release (or
    --force); a resumed one (dead recorded pid, session id live in the
    registry) is rebound, never removed; a plainly live one is refused even
    forced. Worktrees and branches are always kept (§4.5). Returns the lines."""
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
            _remove_lease_files(root, nn)
            lines.append("removed the lease of window %s (%s); its worktree and branch are kept" % (nn, why))
    return lines


def spawn(root: Path, task: str, note: Optional[str]) -> str:
    """create + launch a --bg clone on the next free number, spawned: true;
    the number reaches the clone as DAEDALUS_LEASE and its task always ends
    with the `done` instruction, so it is never hand-typed (§4.2)."""
    import subprocess
    target = root / "target" / target_name(root)
    v.run(["git", "-C", str(target), "fetch", "--quiet", "origin"], timeout=60)
    nn, _ = allocate(root, None, note=note, spawned=True)
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
    pen (§4.4) and sweep removes a released lease before it looks at
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
    fresh.update(dict({"session_id": sid}, **pen_bound()))
    write_lease(root, "prime", fresh)
    return True


def session_start_bind(root: Path, sid: str, deadline: Optional[float] = None) -> dict:
    """Returns {"lease": NN|None, "prime": bool, "took_pen": bool, "numbered": bool, "notes": [..]}.
    Order per §4.2: hint bind -> self-rebind -> auto-number (terminal windows only) -> first-up.
    ONE lock around the whole sequence; everything called inside is a *_locked /
    "caller holds the lock" function (allocate_locked, bind, self_rebind, first_up).
    `deadline` (epoch seconds) is the moment every worktree git call must stop —
    SessionStart's budget less the marker's share (§4.2) — on the
    `DAEDALUS_LEASE` bind and the auto-number alike. The wait for the lease lock
    is bounded by the same deadline: still busy then, it raises
    Refused(LOCK_BUSY_AT_START) having written nothing (plan 2 Decision 18)."""
    out = {"lease": None, "prime": False, "took_pen": False, "numbered": False, "notes": []}
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
        if out["lease"] is None and terminal:
            nn, data = allocate_locked(root, sid, deadline=deadline)      # NOT allocate(): the lock is held here
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
    return out


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

def _listing(repo_path: Path, repo: str, nn: str, *args: str) -> list:
    """One NUL-separated git listing as a list of literal repo-relative paths.
    -z keeps a path with accents, quotes, backslashes or control characters
    literal (core.quotePath would C-quote it, and the boundary check could
    never match it against another window's set). A listing that fails is
    an answer we do not have, never an empty set: refuse, naming the window
    and the command, so the caller keeps the last computed set."""
    code, out, err = _git(repo_path, *args)
    if code != 0:
        last = (err.strip().splitlines() or ["no output"])[-1]
        raise Refused("window %s's changed set could not be recomputed (git %s failed in %s: %s); "
                      "the last computed set is kept." % (nn, " ".join(args), repo, last))
    return [p for p in out.split("\0") if p]


def compute_changed(root: Path, nn: str, lease: dict, previous: dict) -> dict:
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
        mb = _listing(repo_path, repo, nn, "merge-base", "origin/" + trunk, "HEAD")
        paths.update(_listing(repo_path, repo, nn, "diff", "--name-only", "-z", mb[0].strip()))
        paths.update(_listing(repo_path, repo, nn, "diff", "--name-only", "-z"))
        paths.update(_listing(repo_path, repo, nn, "ls-files", "--others", "--exclude-standard", "-z"))
        # a nested repo's paths never belong to the outer set
        nested_prefixes = [r[len(repo) + 1:] + "/" for r in lease.get("trunks", {}) if r.startswith(repo + "/")]
        prev = previous.get(repo, {}) if isinstance(previous.get(repo), dict) else {}
        out[repo] = {p: prev.get(p, stamp) for p in sorted(paths)
                     if p.strip() and not any(p.startswith(pre) for pre in nested_prefixes)}
    return out


def recompute_changed(root: Path, nn: str, lease: Optional[dict] = None) -> dict:
    """Read the sidecar, compute, write (tmp + os.replace). Takes no lock. A
    Refused from the listings propagates before the write, so the sidecar
    on disk is untouched."""
    if lease is None:
        lease = read_lease(root, nn) or {}
    changed = compute_changed(root, nn, lease, read_changed(root, nn))
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
        raise Refused("This session holds no window, so it cannot take the pen; claim a number first.")
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
                found = tl.find_operator_words(tl.transcript_for(root, sid), str(reason),
                                               pen_cutoff(root, prime), require_shown=False)
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
            except (tl.NotFound, tl.NotShown):
                raise Refused("I could not find those words as something the operator typed in this window since "
                              "the pen was last taken. The pen did not move.")
            record["transcript_ref"] = found["transcript_ref"]
    with lock(root):
        fresh = read_lease(root, "prime") or {}
        if fresh.get("session_id") != expect:
            raise Refused("`prime` changed under you — re-read the board and try again")
        entry: Dict[str, object] = {"from": holder, "to": sid, "at": now_stamp(),
                                    "reason": reason or "previous holder gone"}
        entry.update(record)
        fresh["history"] = (fresh.get("history") or []) + [entry]
        fresh.update(dict({"session_id": sid}, **pen_bound()))
        write_lease(root, "prime", fresh)
    return "Window %s holds the pen now (prime): hot.md, vault commits, promote." % mine


# --- The board (§4.3) ---------------------------------------------------------

UNLEASED_NAG = ("This session holds no lease. If the operator told you your window number, run `core/lease.sh claim <NN>`; "
                "otherwise run `core/lease.sh create` and then `claim` the number it prints.")
VISITOR_LINE = "This is a direct-call session; it holds no lease and cannot take the pen."
# §4.8: a visitor never creates, claims or binds any lease, and cannot take the
# pen. Every lease.sh command that changes state/leases/ is refused for it —
# not only create/claim/spawn: sweep and release delete lease files, and
# `prime take` would move the pen to a read-only headless session that exits
# in minutes. list/status stay allowed (they read).
VISITOR_REFUSED = ("create", "claim", "alias", "note", "update", "spawn", "release", "done", "sweep", "prime",
                   "rebase", "split", "adopt")
VISITOR_REFUSAL = ("This is a direct-call session (a visitor): it never creates, claims or changes a window and "
                   "cannot take the pen. `core/lease.sh %s` is refused here; ask the operator to run it from a window.")
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


def last_commit_subject(root: Path, lease: dict, nn: str) -> str:
    """The subject of the newest commit on the lease branch that origin/<trunk>
    does not contain — the outer repo first, then each nested one."""
    base = root / str(lease.get("worktree") or ("worktrees/%s" % nn))
    for repo, trunk in (lease.get("trunks") or {}).items():
        if not (base / repo).is_dir():
            continue
        code, out, _ = _git(base / repo, "log", "-1", "--format=%s", "origin/%s..HEAD" % trunk)
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
        if isinstance(e, dict) and e.get("sessionId") and pid_is_recorded_process(e.get("pid"), e.get("startedAt")):
            out.setdefault(str(e["sessionId"]), []).append(e)
    return out


def render_board(root: Path, sid: Optional[str], leases: Dict[str, dict], changed: Dict[str, dict],
                 waiting: Dict[str, list], states: Dict[str, str], now: float, visitor: bool = False,
                 live_map: Optional[Dict[str, list]] = None) -> str:
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
                parts.append("prime (holds the pen: hot.md, vault commits, promote)")
            if entries and entries[0].get("kind") == "bg" and not d.get("spawned"):
                parts.append("background clone")
            paths = sorted(p for repo in (changed.get(nn) or {}) for p in changed[nn][repo])
            if paths:
                shown = ", ".join(paths[:3]) + (", … (+%d)" % (len(paths) - 3) if len(paths) > 3 else "")
                parts.append("%d changed: %s" % (len(paths), shown))
            else:
                parts.append("0 changed")
            subj = last_commit_subject(root, d, nn)
            parts.append('last commit "%s"' % subj if subj else "no commits yet")
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
        # two-word variants); the stored field is only the fallback.
        peer = (entries[0].get("name") if entries else None) or d.get("peer_name")
        if peer and peer != "daedalus-%s" % nn:
            parts.append("peer name %s (not a window number)" % peer)
        lines.append("%s — %s" % (label, " — ".join(parts)))
    for nn in sorted(waiting):
        subs = waiting[nn]
        lines.append("- %s — swept, %d unpromoted commit%s waiting (%s): say 'this is window %s' to a window to continue it, or 'delete %s's work'"
                     % (nn, len(subs), "" if len(subs) == 1 else "s", _quoted(subs), nn, nn))
    if not registry_present():
        lines.append("(no session registry on this build: liveness is by heartbeat only, peer names are unknown, no window numbers itself "
                     "and nobody takes the pen at start — launch each window with DAEDALUS_LEASE=<NN> and run `core/lease.sh prime take` from the one that should hold it)")
    if visitor:
        lines.append(VISITOR_LINE)
    elif mine and numbered[mine].get("released"):
        lines.append("Window %s is released; this window is done — close it." % mine)
    elif sid is not None and not mine and numbered:
        # a session with no lease is nagged; an operator shell (sid None) is not a session
        lines.append(UNLEASED_NAG)
    lines.append(MESSAGE_LINE)
    return "\n".join(lines)


def waiting_numbers(root: Path, leases: Dict[str, dict]) -> Dict[str, list]:
    """Swept numbers whose lease/<NN> still carries unpromoted commits (§4.2)."""
    out: Dict[str, list] = {}
    target = root / "target" / target_name(root)
    trunk = v.target_branch(root)
    _, refs, _ = _git(target, "for-each-ref", "--format=%(refname:short)", "refs/heads/lease/")
    for ref in refs.splitlines():
        nn = ref.strip()[len("lease/"):]
        if valid_id(nn) and nn not in leases:
            subs = waiting_work(target, trunk, nn)
            if subs:
                out[nn] = subs
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
              deadline: Optional[float] = None) -> str:
    """The duties of §4.3 in one call: recompute the reader's changed set
    (every lease's for `list`/`status` — a shell has no budget), touch the
    reader's heartbeat, refresh stored pid/proc_started/peer_name from the
    registry for every lease whose session it shows live (so the file and the
    board agree, §4.1), render, and announce a tty-mode promotion confirmed
    from the operator's shell (announce_pushed). Never binds, numbers or takes the pen
    (§4.2). '' when no numbered lease exists. Never called while the lock is
    held (it takes the lock itself, twice); the git and ps work runs outside it.
    `deadline` bounds both lock acquires (SessionStart only, §4.2): still busy
    then, it raises Refused(BOARD_LOCK_BUSY), which the hook renders as
    BOARD_UNRENDERED."""
    with lock(root, shared=True, deadline=deadline, busy=BOARD_LOCK_BUSY):
        leases = read_all(root)
    if not any(k != "prime" for k in leases):
        return ""
    mine, _ = lease_of_session(leases, sid or "")
    for nn, d in leases.items():
        if nn == "prime" or not (recompute_all or nn == mine):
            continue
        try:
            recompute_changed(root, nn, d)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)     # the last computed set is kept (§4.1)
    if mine:
        heartbeat(root, mine)
    now, quiet_after = time.time(), stale_after_secs(root)
    states = {nn: liveness(root, nn, d, now, quiet_after) for nn, d in leases.items() if nn != "prime"}   # computed ONCE
    live_map = registry_live_map()                                                                          # read ONCE
    with lock(root, deadline=deadline, busy=BOARD_LOCK_BUSY):
        leases = read_all(root)
        for nn, d in leases.items():
            if nn != "prime" and d.get("session_id"):
                # a write only on a rename or a resume; nothing while a session is open in two terminals
                self_rebind(root, str(d["session_id"]), leases=leases, live=live_map.get(str(d["session_id"]), []))
        leases = read_all(root)
        changed = {nn: read_changed(root, nn) for nn in leases if nn != "prime"}
    text = render_board(root, sid, leases, changed, waiting_numbers(root, leases), states, now, visitor=visitor,
                        live_map=live_map)
    announced = announce_pushed(root, sid) if not visitor else []
    return "\n".join(announced + [text]) if announced else text


def _since(ts: Optional[float], now: float) -> str:
    """When a window was last seen, for an operator: the clock time today,
    the date and time when older — a heartbeat from last month must not read
    as "since 09:40" this morning."""
    if ts is None:
        return "never seen"
    fmt = "%H:%M" if time.localtime(ts)[:3] == time.localtime(now)[:3] else "%Y-%m-%d %H:%M"
    return "no live session since " + time.strftime(fmt, time.localtime(ts))


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
    try:
        waiting = waiting_numbers(root, leases)
    except Refused as e:
        waiting = {}
        lines.append("NOTE     leases: cannot tell whether a swept number still has unpromoted work (%s)" % e)
    for nn in sorted(waiting):
        k = len(waiting[nn])
        lines.append("NOTE     leases: %s swept with %d unpromoted commit%s waiting — say \"this is window %s\" to a window "
                     "to continue it, or \"delete %s's work\"" % (nn, k, "" if k == 1 else "s", nn, nn))
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
    if cmd in ("is-prime", "not-prime-sentence", "numbers"):
        # vault-commit.sh (§4.7): is-prime exits 0 when prime.json names the caller's
        # session, or when the deployment has no lease files at all (nothing to hold);
        # not-prime-sentence prints the refusal with window NUMBERS, never peer names
        # (§4.1); numbers prints one unswept window number per line for the default
        # commit message. One LOCK_SH read; an unreadable lease file fails closed.
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
        prime = leases.get("prime") or {}
        holder = prime.get("session_id")
        if cmd == "is-prime":
            if sid is None or (not numbered and not holder):
                return 0
            return 0 if holder and holder == sid else 1
        mine, _ = lease_of_session(leases, sid or "")
        prime_nn, prime_lease = lease_of_session(leases, str(holder)) if holder else (None, None)
        me = "You are %s" % window_label(mine, leases.get(mine)) if mine else "This session holds no window"
        if prime_nn:
            pen = "the pen is held by %s — ask it to commit, or take the pen with `core/lease.sh prime take` if the operator says so." % window_label(prime_nn, prime_lease)
        elif holder:
            pen = "the pen is held by a session that holds no window now — take it with `core/lease.sh prime take` if the operator says so."
        else:
            pen = "nobody holds the pen — take it with `core/lease.sh prime take` if the operator says so."
        print("Only the prime window commits the vault. %s; %s" % (me, pen))
        return 0
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
    if cmd in ("claim", "alias", "note", "update", "release", "done", "sweep", "spawn", "prime", "rebase", "split"):
        try:
            recompute_all_changed(root)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e)
            return 1
    if cmd == "registry-pids":
        print(" ".join(str(e.get("pid")) for e in registry_by_session(args[0]))); return 0
    if cmd == "registry-live-pids":
        print(" ".join(str(e.get("pid")) for e in registry_live_entries(args[0]))); return 0
    if cmd == "pid-alive":
        return 0 if pid_alive(args[0]) else 1
    if cmd == "create":
        note = args[args.index("--note") + 1] if "--note" in args else None
        crit = args[args.index("--criteria") + 1] if "--criteria" in args else None
        try:
            # a spawner/operator path: fetch first (no network only inside a hook — §4.2)
            v.run(["git", "-C", str(root / "target" / target_name(root)), "fetch", "--quiet", "origin"], timeout=60)
            nn, data = allocate(root, None, note=note, criteria=crit, spawned="--spawned" in args)
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
        print(launch_line(root, nn))
        if data.get("worktree_ready") is False:
            print("Window %s's worktree was not finished inside the budget; run `core/lease.sh claim %s` to finish it." % (nn, nn))
        return 0
    if cmd == "adopt":
        if not args or args[0].startswith("--"):
            sys.stderr.write('usage: core/lease.sh adopt <branch> [--repo <nested>] [--note "..."]\n')
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
    if cmd in ("claim", "alias", "note", "update", "release", "done", "sweep", "spawn", "prime", "rebase", "split"):
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
        if cmd == "update":
            return _refused(lambda: "Window %s's criteria file is %s."
                            % (set_field(root, args[0], "update", "criteria", _after("--criteria")), _after("--criteria")))
        if cmd == "release":
            return _refused(lambda: release(root, args[0], sid, remove="--remove" in args, force="--force" in args))
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
