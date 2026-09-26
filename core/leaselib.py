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


def leases_dir(root: Path) -> Path:
    return root / "state" / "leases"


@contextlib.contextmanager
def lock(root: Path, shared: bool = False) -> Iterator[None]:
    """NOT re-entrant. flock belongs to the open file description and this
    opens the file afresh, so a nested lock() — in this process or a child
    process — blocks until the outer one is released, i.e. forever. Every
    function that runs under the lock is named *_locked or says "Caller holds
    the lock", and never calls lock(), resolve(), recompute_all_changed(),
    board_for() or lib.sh target_path (which shells back into leaselib)."""
    d = leases_dir(root)
    d.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(d / ".lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_SH if shared else fcntl.LOCK_EX)
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
        sys.stderr.write("daedalus: no session — using the prime's checkout target/%s (%d windows live)\n" % (name, live))
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


def add_worktrees(root: Path, nn: str, trunks: Dict[str, str], timeout: int = 20) -> bool:
    """§4.2 'Re-use or refuse': prune; adopt a registered worktree in place;
    check out an existing merged lease/<NN>; else cut it from origin/<trunk>;
    fast-forward an adopted one; recreate target.scaffold dirs empty. Returns
    False only when a worktree add timed out (the lease is then written
    worktree_ready: false and `claim` finishes it). Caller holds the lock."""
    base = root / "worktrees" / nn
    branch = "lease/%s" % nn
    for repo, trunk in trunks.items():
        src = root / "target" / repo
        dest = base / repo
        _git(src, "worktree", "prune")
        registered = False
        if dest.exists():
            listed = _git(src, "worktree", "list", "--porcelain")[1]
            registered = any(ln.strip() == "worktree " + str(dest.resolve())
                             for ln in listed.splitlines() if ln.startswith("worktree "))
            if not registered:
                raise Refused("worktrees/%s/%s exists but is not a worktree of target/%s; move it aside." % (nn, repo, repo))
        has_branch = _git(src, "rev-parse", "--verify", "-q", branch)[0] == 0
        if not registered:
            if has_branch:
                code, _, err = v.run(["git", "-C", str(src), "worktree", "add", str(dest), branch], timeout=timeout)
            else:
                code, _, err = v.run(["git", "-C", str(src), "worktree", "add", str(dest), "-b", branch, "origin/" + trunk],
                                     timeout=timeout)
            if code == 127:
                return False   # v.run's code for a timeout or an OS failure
            if code != 0:
                last = err.strip().splitlines()[-1:] or ["no output"]
                raise Refused("git worktree add for window %s (%s) failed: %s" % (nn, repo, last[0]))
        if has_branch or registered:
            code, _, err = _git(dest, "merge", "--ff-only", "--quiet", "origin/" + trunk)
            if code != 0:
                last = err.strip().splitlines()[-1:] or ["no output"]
                sys.stderr.write("daedalus: window %s: %s could not be fast-forwarded to origin/%s (%s); "
                                 "the tree is usable but behind trunk — rebase it before promoting.\n"
                                 % (nn, repo, trunk, last[0]))
    # scaffold dirs, empty, inside the outer worktree (config target.scaffold)
    for ln in v._lib(root, "cfg target.scaffold >/dev/null 2>&1 && cfg_pairs target.scaffold | cut -f1").splitlines():
        if ln.strip():
            (base / list(trunks)[0] / ln.strip()).mkdir(parents=True, exist_ok=True)
    return True


def now_stamp() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S")


def allocate_locked(root: Path, sid: Optional[str], note: Optional[str] = None, criteria: Optional[str] = None,
                    spawned: bool = False, timeout: Optional[int] = None) -> Tuple[str, dict]:
    """§4.2 'Allocation': lowest free number; prune; re-use or refuse; worktree
    add; lease O_EXCL; empty .changed. CALLER HOLDS THE LOCK (session_start_bind
    and claim call this from inside theirs; the lock is not re-entrant)."""
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
        try:
            write_lease(root, nn, data, exclusive=True)
        except FileExistsError:
            continue               # another allocator took this number: recompute under the same lock
        break
    try:
        ready = add_worktrees(root, nn, trunks, timeout=timeout)
    except BaseException:
        # A refused or failed add must not leave the number held by a lease
        # that has no tree: the next allocation would skip it forever.
        try:
            os.unlink(str(lease_path(root, nn)))
        except OSError:
            pass
        raise
    if not ready:
        data["worktree_ready"] = False
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


def bind(root: Path, nn: str, sid: str, finish_worktree: bool = True) -> dict:
    """claim / DAEDALUS_LEASE binding. Caller holds the lock. The same rule the
    hook applies: null or dead holder -> bind; a live (or quiet, or resumed)
    other holder -> refuse with its peer name. A compare-and-swap on the
    session_id read first; pid / proc_started / peer_name come from the
    registry entry for sid (None on a build without one); an unfinished
    worktree (worktree_ready: false) is completed here (§4.2) — except when
    finish_worktree is False: a SessionStart that just spent its add budget
    in allocate_locked must not spend it twice (§4.6); `claim` finishes it."""
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
        if add_worktrees(root, nn, fresh.get("trunks") or trunks_of(root, root / "target")):
            fresh.pop("worktree_ready", None)
    write_lease(root, nn, fresh)
    heartbeat(root, nn)
    return fresh


def self_rebind(root: Path, sid: str) -> Optional[str]:
    """A resumed session keeps its id and gets a new pid (§4.2): refresh pid /
    proc_started / peer_name on the lease that already names sid. The
    compare-and-swap is on session_id, which is unchanged, so no other session
    is displaced. Does nothing while the session is open in two terminals.
    Caller holds the lock. Returns the window number, None when sid holds none."""
    leases = read_all(root)
    nn, lease = lease_of_session(leases, sid)
    if nn is None:
        return None
    try:
        entry = registry_entry_for(sid)
    except Refused:
        return nn                       # two terminals: do nothing (§4.2)
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
                "repos": list(trunks), "trunks": trunks, "created": now_stamp(), "bound_at": None, "promoted": []}
        write_lease(root, nn, data, exclusive=True)
        try:
            add_worktrees(root, nn, trunks)
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
        _remove_lease_files(root, nn)
        out.append("Window %s released; its worktree and branch are deleted." % nn)
        return "\n".join(out)


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


def first_up(root: Path, sid: str) -> bool:
    """Caller holds the lock. O_EXCL prime.json; a stale prime is rebound by CAS."""
    prime = read_lease(root, "prime")
    if prime is None:
        try:
            write_lease(root, "prime", {"session_id": sid, "bound_at": now_stamp(), "history": []}, exclusive=True)
            return True
        except FileExistsError:
            return False
    holder = prime.get("session_id")
    if holder == sid:
        return True
    hnn, hlease = lease_of_session(read_all(root), str(holder))
    if hlease is not None and liveness(root, hnn, hlease) in HELD_BY_LIVE:
        return False
    fresh = read_lease(root, "prime") or {}
    if fresh.get("session_id") != holder:
        return False
    fresh["history"] = (fresh.get("history") or []) + [{"from": holder, "to": sid, "at": now_stamp(),
                                                        "reason": "first-up (previous holder gone)"}]
    fresh.update({"session_id": sid, "bound_at": now_stamp()})
    write_lease(root, "prime", fresh)
    return True


def session_start_bind(root: Path, sid: str) -> dict:
    """Returns {"lease": NN|None, "prime": bool, "took_pen": bool, "numbered": bool, "notes": [..]}.
    Order per §4.2: hint bind -> self-rebind -> auto-number (terminal windows only) -> first-up.
    ONE lock around the whole sequence; everything called inside is a *_locked /
    "caller holds the lock" function (allocate_locked, bind, self_rebind, first_up)."""
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
    with lock(root):
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
                    bind(root, hint, sid)
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
            nn, data = allocate_locked(root, sid)      # NOT allocate(): the lock is held here
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


def orientation(root: Path, sid: Optional[str], visitor: bool = False) -> str:
    """The first line of SessionStart's additionalContext (§8.2)."""
    if visitor:
        return "Daedalus session orientation: visitor, %s" % root
    with lock(root, shared=True):
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

def prime_take(root: Path, sid: str, reason: Optional[str]) -> str:
    """`lease.sh prime take [--reason "..."]` from the TAKING session. Every
    prime is a window (§4.8), so a session with no numbered lease is refused.
    A live holder (live, quiet or resumed — HELD_BY_LIVE) needs --reason, the
    operator's words, recorded in prime.json's append-only history; a stale
    holder, or no prime.json at all (a registry-absent build that never
    first-upped), needs none. The take is a compare-and-swap on the
    session_id the taker read (§4.1); LEASE_TEST_CAS_EXPECT lets a test
    simulate a stale read. The transcribed-mode check of --reason against
    the taker's transcript is plan 4 (it needs the promote transcript parser);
    this release records the reason as given."""
    with lock(root):
        leases = read_all(root)
        mine, _ = lease_of_session(leases, sid)
        if mine is None:
            raise Refused("This session holds no window, so it cannot take the pen; claim a number first.")
        prime = leases.get("prime") or {}
        holder = prime.get("session_id")
        expect = os.environ.get("LEASE_TEST_CAS_EXPECT", holder)   # test knob: simulate a stale read
        hnn, hlease = lease_of_session(leases, str(holder)) if holder else (None, None)
        if holder and holder != sid and hlease is not None and liveness(root, hnn, hlease) in HELD_BY_LIVE:
            if not reason:
                raise Refused("The pen is held by a live session, %s. Taking it needs --reason \"<the operator's words>\"."
                              % window_label(hnn, hlease))
        fresh = read_lease(root, "prime") or {}
        if fresh.get("session_id") != expect:
            raise Refused("`prime` changed under you — re-read the board and try again")
        fresh["history"] = (fresh.get("history") or []) + [{"from": holder, "to": sid, "at": now_stamp(),
                                                            "reason": reason or "previous holder gone"}]
        fresh.update({"session_id": sid, "bound_at": now_stamp()})
        write_lease(root, "prime", fresh)
    return "Window %s holds the pen now (prime): hot.md, vault commits, promote." % mine


# --- CLI ----------------------------------------------------------------------

def main(argv: list) -> int:
    root = v.ROOT
    if len(argv) < 2:
        sys.stderr.write("usage: leaselib.py <command> ...\n")
        return 2
    cmd, args = argv[1], argv[2:]
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
    if cmd == "changed":
        if not args:
            sys.stderr.write("usage: leaselib.py changed <NN>\n"); return 2
        try:
            print(json.dumps(recompute_changed(root, args[0]))); return 0
        except Refused as e:
            sys.stderr.write("daedalus: %s\n" % e); return 1
    # §4.1: every lifecycle command recomputes every unswept lease's sidecar (a
    # shell has no budget). Before the dispatch and outside any lock — it takes
    # and releases LOCK_SH itself. list/status do it through the board (Task 8);
    # create and resolve do not (a spawner's create may run hook-adjacent, and
    # resolve is on every target_path).
    if cmd in ("claim", "alias", "note", "update", "release", "done", "sweep", "spawn", "prime"):
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
    if cmd in ("claim", "alias", "note", "update", "release", "done", "sweep", "spawn", "prime"):
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
            return _refused(lambda: prime_take(root, require_session(sid, "prime take"),
                                               _after("--reason") if "--reason" in args else None))
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
