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
    process while the allocator holds LOCK_EX)."""
    key = str(root)
    if key not in _TARGET_NAME:
        _TARGET_NAME[key] = v._lib(root, "target_name 2>/dev/null").strip()
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
            continue
        code, head, _ = v.run(["git", "-C", str(target_base / repo), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        head = head.strip()
        if code != 0 or not head.startswith("origin/"):
            raise Refused("nested repo %s has no origin/HEAD — run git -C target/%s remote set-head origin -a"
                          % (repo.split("/", 1)[1], repo))
        out[repo] = head[len("origin/"):]
    return out


def waiting_work(target_repo: Path, trunk: str, nn: str) -> list:
    """Subjects of commits on lease/<NN> that origin/<trunk> does not contain;
    [] when there are none or the branch is absent (§4.2 'Numbering')."""
    branch = "lease/%s" % nn
    code, _, _ = v.run(["git", "-C", str(target_repo), "rev-parse", "--verify", "-q", branch])
    if code != 0:
        return []
    code, _, _ = v.run(["git", "-C", str(target_repo), "merge-base", "--is-ancestor", branch, "origin/" + trunk])
    if code == 0:
        return []
    _, out, _ = v.run(["git", "-C", str(target_repo), "log", "--format=%s", "origin/%s..%s" % (trunk, branch)])
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
            _git(dest, "merge", "--ff-only", "--quiet", "origin/" + trunk)
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
        trunk = v.target_branch(root)
        for s in waiting_work(root / "target" / target_name(root), trunk, args[0]):
            print(s)
        return 0
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
