#!/usr/bin/env python3
"""daedalus update | daedalus version — taking a release in one step (update-command design, 2026-10-15).

    daedalus update     close every Daedalus window first, then type this in a terminal
    daedalus version    the release this home runs, its remote and its tag

The `daedalus` command on PATH is a shim that runs this file with `--home <this home>`. Every path comes from
--home: this script reads nothing from its own directory (a later release runs it from a temporary copy, and the
first update runs it from a pipe), never reads stdin, and closes stdin for every program it runs. Standard library
only; the home's own core/upgrade.py is imported for one thing, its liveness check.

`daedalus update`, in order, non-interactive; it either finishes or leaves the home as it was:
  1. takes the home's update lock (state/.update.lock; session start honours it), then refuses while a Daedalus
     session is live in this home, naming each (the rollback's check, upgrade._live_sessions);
  2. picks the remote by the release's address (RELEASE_ADDRESS, or update.address in config.yaml for a home that
     follows a mirror) — never by name alone, so a fork named origin is never taken for the release — and checks
     that address is the one recorded, unrewritten (remote_problem, the release-pull rule guard-bash uses too);
  3. asks the remote which branch is its trunk (git ls-remote --symref <r> HEAD; main when it does not say);
  4. fetches that trunk and the release tags;
  5. with the home already at the remote trunk: says it is up to date (and finishes a stopped upgrade first);
  6. otherwise fast-forwards to the remote trunk (a journal in SOUL.md, modified in the working tree, is kept);
     a local edit in another tracked file, or history the release does not have, is refused in this build;
  7. runs core/upgrade.py --caller update --progress now, not at the next session start;
  8. runs core/doctor.sh quietly, and
  9. says one line: "Daedalus updated 0.7.2 -> 0.7.3; doctor OK." (or what needs attention, one sentence each).
Exit 0: updated or up to date; 1: refused, nothing changed; 2: updated, but the upgrade or doctor names something.

Tests replace the upgrade and doctor with DAEDALUS_UPDATE_UPGRADE / DAEDALUS_UPDATE_DOCTOR (a command, split as a
shell would, given the same arguments).
"""
from __future__ import annotations

import fcntl
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# The release's address (Decision 20): a remote is the release's when its recorded URL normalises to this. A fork's
# maintainer changes this one constant; a home that deliberately follows a mirror sets update.address instead.
RELEASE_ADDRESS = "github.com/lpelty/daedalus"
RELEASE_URL = "https://github.com/lpelty/daedalus.git"
UPDATE_LOCK = Path("state") / ".update.lock"
STAMP = Path("state") / "upgraded-to"
LOCK_WAIT_SECS = 2      # a session start holds the lock shared for a moment; a second update holds it throughout
NOTHING = "Nothing in this home was changed."
USAGE = "usage: daedalus update | daedalus version   (python3 core/update.py <verb> --home <absolute path>)"
JOURNAL = "SOUL.md"     # the deployment's journal: modified in the working tree, kept across the move


class Refuse(Exception):
    """One sentence that ends the update with nothing changed (exit 1)."""


# --- git and the home ----------------------------------------------------------------------------------------------

def _env() -> Dict[str, str]:
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"      # a fetch never stops to ask for a password: the update is non-interactive
    return env


def git(home: Path, *args: str, timeout: int = 120) -> Tuple[int, str, str]:
    try:
        r = subprocess.run(["git", "-C", str(home)] + list(args), stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=timeout, env=_env())
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %d s" % timeout
    except OSError as e:
        return 127, "", str(e)
    return r.returncode, r.stdout, r.stderr


def _last(text: str) -> str:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1] if lines else "no message"


def _cfg_lines(repo: Path, *args: str) -> List[str]:
    code, out, _ = git(repo, "config", *args)
    return out.splitlines() if code == 0 else []


def home_version(home: Path) -> Optional[str]:
    try:
        ver = (home / "VERSION").read_text().split("\n", 1)[0].strip()
    except OSError:
        return None
    return ver or None


def config_value(home: Path, dotted: str) -> Optional[str]:
    """A two-level key of config.yaml, read as lib.sh cfg reads it: the block `top:` at column 0, then the first
    line in it whose first word is `sub:`; quotes and spaces trimmed; empty, ~ and null are absent."""
    top, _, sub = dotted.partition(".")
    try:
        lines = (home / "config.yaml").read_text().splitlines()
    except OSError:
        return None
    inblock = False
    for ln in lines:
        if re.match(r"^%s:" % re.escape(top), ln):
            inblock = True
            continue
        if re.match(r"^[^\s#]", ln):
            inblock = False
        words = ln.split()
        if inblock and words and words[0] == sub + ":":
            val = re.sub(r"^\s*[^:]+:\s*", "", ln, count=1)
            val = re.sub(r"^[\"']|[\"']$", "", val).strip()
            return None if val in ("", "~") or val.lower() == "null" else val
    return None


# --- the release's address (Decisions 14, 20) ------------------------------------------------------------------------

def normalise_address(url: str) -> str:
    """An address in one form for comparing: host (lower case) and path, without the scheme, the user, a port, a
    trailing .git or slash — so https://, ssh://git@, git@host: and a bare host/path name one repository alike.
    A local path stays a path (file:// dropped), normalised the same way at its end."""
    s = (url or "").strip()
    m = re.match(r"^file://(/.*)$", s)
    if m:
        s = m.group(1)
    host, path = "", s
    m = re.match(r"^[A-Za-z][A-Za-z0-9+.-]*://(?:[^@/]+@)?([^/:]+)(?::\d+)?/?(.*)$", s)
    if m:
        host, path = m.group(1), m.group(2)
    elif not s.startswith(("/", ".", "~")):
        m = re.match(r"^(?:[^@/]+@)?([^/:]+):(.*)$", s) or re.match(r"^([^/:]+\.[^/:]+)/(.*)$", s)
        if m:
            host, path = m.group(1), m.group(2)
    path = path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4].rstrip("/")
    if not host:
        return os.path.normpath(path) if path else ""
    return host.lower() + "/" + path.lstrip("/")


def remote_problem(repo: Path, remote: str) -> Optional[str]:
    """Why fetching `remote` in this checkout would not read from the address the checkout itself records for it,
    or None: git settings outside the checkout add an address or replace it, an address rewrite (insteadOf) turns
    it into another, or an upload-pack or remote helper fetches through another program. Read with git's effective
    configuration, every scope and include applied. One rule, two callers: guard-bash's release-pull check and
    `daedalus update` (Decision 14). The clause returned is the caller's to frame."""
    urls = _cfg_lines(repo, "--local", "--get-all", "remote.%s.url" % remote)
    every = _cfg_lines(repo, "--get-all", "remote.%s.url" % remote)
    if len(urls) != 1 or every != urls:
        return ("git settings outside this checkout give the remote %s another address (%s)"
                % (remote, ", ".join(u for u in every if u not in urls) or "none recorded here"))
    code, out, _ = git(repo, "ls-remote", "--get-url", remote, timeout=20)
    got = out.strip()
    if code != 0 or got != urls[0]:
        return "an address rewrite (insteadOf) turns %s into %s" % (urls[0], got or "nothing")
    for k in ("uploadpack", "vcs"):
        if _cfg_lines(repo, "--get-all", "remote.%s.%s" % (remote, k)):
            return "remote.%s.%s is set, which fetches through another program" % (remote, k)
    return None


def current_branch(home: Path) -> Optional[str]:
    code, out, _ = git(home, "symbolic-ref", "--quiet", "--short", "HEAD")
    return out.strip() if code == 0 and out.strip() else None


def pick_remote(home: Path, branch: Optional[str]) -> Tuple[str, str]:
    """(name, recorded url) of the remote whose address is the release's. Several: the branch's tracking remote
    among them, else origin among them, else the first by name. None: Refuse with how to add it."""
    configured = config_value(home, "update.address")
    want = normalise_address(configured or RELEASE_ADDRESS)
    code, out, _ = git(home, "remote")
    names = sorted(n for n in out.split() if n) if code == 0 else []
    urls = {n: (_cfg_lines(home, "--local", "--get", "remote.%s.url" % n) or [""])[0] for n in names}
    match = [n for n in names if urls[n] and normalise_address(urls[n]) == want]
    if not match:
        add = configured or RELEASE_URL
        listed = ", ".join("%s → %s" % (n, urls[n] or "no address") for n in names) or "none"
        raise Refuse("No remote of this home has the release's address %s (remotes: %s); add it with git remote add "
                     "daedalus %s, then run daedalus update again. %s" % (want, listed, add, NOTHING))
    if len(match) == 1:
        return match[0], urls[match[0]]
    tracking = (_cfg_lines(home, "--local", "--get", "branch.%s.remote" % branch) or [""])[0] if branch else ""
    for n in ([tracking] if tracking else []) + ["origin"]:
        if n in match:
            return n, urls[n]
    return match[0], urls[match[0]]


def remote_trunk(home: Path, remote: str) -> str:
    """The branch the remote's HEAD names (git ls-remote --symref), else main. A plain fetch never writes
    refs/remotes/<r>/HEAD, so that ref is never read."""
    code, out, _ = git(home, "ls-remote", "--symref", remote, "HEAD", timeout=60)
    if code == 0:
        for ln in out.splitlines():
            m = re.match(r"^ref:\s+refs/heads/(\S+)\s+HEAD$", ln.strip())
            if m:
                return m.group(1)
    return "main"


# --- liveness and the lock (Decisions 2a, 17, 19) ------------------------------------------------------------------

def take_lock(home: Path) -> Optional[int]:
    """The home's update lock, held to the last line. A session start takes it shared for a moment, so a held lock
    is waited for briefly before it counts as another update's."""
    (home / "state").mkdir(parents=True, exist_ok=True)
    fd = os.open(str(home / UPDATE_LOCK), os.O_RDWR | os.O_CREAT, 0o644)
    deadline = time.time() + LOCK_WAIT_SECS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.time() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.05)


_LIVE = {}


def live_sessions(home: Path) -> List[str]:
    """The Daedalus sessions live in this home, in words, by the home's own check (upgrade._live_sessions). A
    session running `daedalus update` is itself live, and named."""
    if "fn" not in _LIVE:
        core = str(home / "core")
        os.environ["DAEDALUS_HOME"] = str(home)
        sys.dont_write_bytecode = True   # a refusal leaves the home as it was: no __pycache__ either
        if core not in sys.path:
            sys.path.insert(0, core)
        try:
            import upgrade as up
            _LIVE["fn"] = up._live_sessions
        except Exception:
            raise Refuse("Not updating: this home predates v0.7.0 (its core/upgrade.py has no liveness check); "
                         "update it with git. " + NOTHING)
    return list(_LIVE["fn"](home))


def _join(words: List[str]) -> str:
    if len(words) < 3:
        return " and ".join(words)
    return ", ".join(words[:-1]) + " and " + words[-1]


def refuse_if_live(home: Path, tail: str = NOTHING) -> None:
    live = live_sessions(home)
    if live:
        one = len(live) == 1
        raise Refuse("Not updating: %d Daedalus session%s live in this home — %s. Close %s, then run daedalus update "
                     "again. %s" % (len(live), " is" if one else "s are", _join(live), "it" if one else "them", tail))


# --- the move ------------------------------------------------------------------------------------------------------

def local_edits(home: Path, trunk_ref: str) -> List[str]:
    """Tracked paths the working tree changes, but a journal in SOUL.md the release does not touch."""
    code, out, err = git(home, "status", "--porcelain=v1", "-z", "--untracked-files=no")
    if code != 0:
        raise Refuse("Not updating: git status failed in this home (%s). %s" % (_last(err), NOTHING))
    paths: List[str] = []
    parts = out.split("\0")
    i = 0
    while i < len(parts):
        ent = parts[i]
        i += 1
        if len(ent) < 4:
            continue
        if ent[0] in "RC":
            i += 1      # the rename's source follows
        paths.append(ent[3:])
    out_paths = []
    for p in paths:
        if p == JOURNAL:
            a = git(home, "rev-parse", "-q", "--verify", "HEAD:" + p)[1].strip()
            b = git(home, "rev-parse", "-q", "--verify", trunk_ref + ":" + p)[1].strip()
            if a and a == b:
                continue
        out_paths.append(p)
    return out_paths


def set_tracking(home: Path, branch: str, remote: str, trunk: str) -> None:
    """The branch follows <remote>/<trunk> afterwards, so the release pull and the next update read the release."""
    if _cfg_lines(home, "--local", "--get", "branch.%s.remote" % branch) != [remote]:
        git(home, "config", "--local", "branch.%s.remote" % branch, remote)
    if _cfg_lines(home, "--local", "--get", "branch.%s.merge" % branch) != ["refs/heads/" + trunk]:
        git(home, "config", "--local", "branch.%s.merge" % branch, "refs/heads/" + trunk)


def fast_forward(home: Path, ref: str) -> Tuple[int, str]:
    """git merge --ff-only, with Ctrl-C and SIGTERM ignored for its length (the child inherits that), so no signal
    leaves a half-moved tree."""
    old = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        code, out, err = git(home, "merge", "--ff-only", "--quiet", ref, timeout=600)
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    return code, err or out


# --- the upgrade and doctor ----------------------------------------------------------------------------------------

def _cmd(env_key: str, default: List[str]) -> List[str]:
    over = os.environ.get(env_key)
    return shlex.split(over) if over else default


def run_upgrade(home: Path) -> Optional[str]:
    """core/upgrade.py --caller update --progress, from the new tree, now. Its progress (stderr) is relayed as it
    comes. None when it finished (the stamp equals VERSION); else the sentence to pass on — its stop, worded for a
    terminal by --caller update."""
    cmd = _cmd("DAEDALUS_UPDATE_UPGRADE", [sys.executable, str(home / "core" / "upgrade.py")])
    env = _env()
    env["DAEDALUS_HOME"] = str(home)
    try:
        r = subprocess.run(cmd + ["--caller", "update", "--progress"], cwd=str(home), stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=None, text=True, env=env)
    except OSError as e:
        return "the upgrade could not start (%s); run daedalus update again" % e
    last = _last(r.stdout)
    if r.returncode == 1:
        return last
    if r.returncode != 0:
        return "the upgrade ended with exit %d (%s); run daedalus update again" % (r.returncode, last)
    try:
        stamped = (home / STAMP).read_text().strip()
    except OSError:
        stamped = ""
    if stamped != (home_version(home) or ""):
        return last
    return None


def run_doctor(home: Path) -> List[str]:
    """core/doctor.sh, quietly: each MISSING line as one sentence; [] when it passes."""
    cmd = _cmd("DAEDALUS_UPDATE_DOCTOR", ["bash", str(home / "core" / "doctor.sh")])
    env = _env()
    env["DAEDALUS_HOME"] = str(home)
    try:
        r = subprocess.run(cmd, cwd=str(home), stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env,
                           timeout=600)
    except (OSError, subprocess.TimeoutExpired) as e:
        return ["core/doctor.sh could not run (%s)" % e]
    found = []
    for ln in (r.stdout + "\n" + r.stderr).splitlines():
        m = re.match(r"^(?:daedalus:\s*)?MISSING\s+(.*\S)\s*$", ln)
        if m:
            found.append(m.group(1))
    if r.returncode != 0 and not found:
        found.append("core/doctor.sh exited %d (%s)" % (r.returncode, _last(r.stdout + "\n" + r.stderr)))
    return found


def _sentence(s: str) -> str:
    s = s.strip()
    return s if s.endswith((".", "!", "?")) else s + "."


def finish(home: Path, head: str, done: str = "") -> Tuple[str, int]:
    """The upgrade, then doctor, as the tail of the one line, and the exit code. `done` is said after head when
    the upgrade finished."""
    stop = run_upgrade(home)
    if stop:
        return "%s; the upgrade stopped: %s" % (head, stop), 2
    head += done
    missing = run_doctor(home)
    if missing:
        return "%s; doctor names what needs attention: %s" % (head, " ".join(_sentence(m) for m in missing)), 2
    return head + "; doctor OK.", 0


# --- the verbs -----------------------------------------------------------------------------------------------------

def update(home: Path) -> int:
    fd = take_lock(home)
    if fd is None:
        print("Not updating: another daedalus update is running in this home. " + NOTHING)
        return 1
    try:
        line, code = _update(home)
    except Refuse as e:
        line, code = str(e), 1
    finally:
        os.close(fd)
    print(line)
    return code


def _update(home: Path) -> Tuple[str, int]:
    refuse_if_live(home)
    branch = current_branch(home)
    if not branch:
        raise Refuse("Not updating: this home is not on a branch (its HEAD is detached); check out its branch, then "
                     "run daedalus update again. " + NOTHING)
    remote, url = pick_remote(home, branch)
    problem = remote_problem(home, remote)
    if problem:
        raise Refuse("Not updating: %s. %s" % (problem, NOTHING))
    trunk = remote_trunk(home, remote)
    ref = "refs/remotes/%s/%s" % (remote, trunk)
    code, _, err = git(home, "fetch", "--quiet", "--no-tags", remote, "+refs/heads/%s:%s" % (trunk, ref), timeout=600)
    if code != 0:
        raise Refuse("Could not reach %s: %s. %s" % (url, _last(err), NOTHING))
    git(home, "fetch", "--quiet", "--no-tags", remote, "refs/tags/v*:refs/tags/v*", timeout=300)   # tags: best effort
    fetched = "fetched %s/%s, and nothing else in this home was changed." % (remote, trunk)
    target = git(home, "rev-parse", "--verify", ref + "^{commit}")[1].strip()
    head = git(home, "rev-parse", "--verify", "HEAD")[1].strip()
    if not target or not head:
        raise Refuse("Not updating: %s/%s or HEAD does not name a commit; %s" % (remote, trunk, fetched))
    local = local_edits(home, ref)
    if head == target and not local:
        ver = home_version(home) or "unknown"
        if _stamp(home) == ver:
            return "Daedalus is up to date (%s)." % ver, 0
        # up to date, but an earlier upgrade stopped: run it now, so a second run finishes it
        return finish(home, "Daedalus is up to date (%s)" % ver, done="; the upgrade finished")
    ancestor = git(home, "merge-base", "--is-ancestor", head, target)[0] == 0
    if local or not ancestor:
        why = ("local edits in tracked files (%s)" % ", ".join(local)) if local else \
              "commits of its own that the release does not have"
        raise Refuse("Not updating: this home has %s, which this daedalus update cannot move into the local layer "
                     "yet; %s" % (why, fetched))
    refuse_if_live(home, tail=fetched[0].upper() + fetched[1:])
    old = home_version(home) or head[:7]
    code, msg = fast_forward(home, target)
    if code != 0:
        raise Refuse("Not updating: git could not fast-forward to %s/%s (%s); %s" % (remote, trunk, _last(msg), fetched))
    set_tracking(home, branch, remote, trunk)
    new = home_version(home) or target[:7]
    if new == old:
        new = "%s (%s)" % (new, target[:7])
    return finish(home, "Daedalus updated %s -> %s" % (old, new))


def _stamp(home: Path) -> str:
    try:
        return (home / STAMP).read_text().strip()
    except OSError:
        return ""


def version(home: Path) -> int:
    parts = ["home %s" % home]
    try:
        remote, _ = pick_remote(home, current_branch(home))
        parts.append("remote %s" % remote)
    except Refuse:
        pass
    code, out, _ = git(home, "describe", "--tags", "--abbrev=0")
    if code == 0 and out.strip():
        parts.append("tag %s" % out.strip())
    print("Daedalus %s (%s)" % (home_version(home) or "(no VERSION)", ", ".join(parts)))
    return 0


def main(argv: List[str]) -> int:
    args = argv[1:]
    home_arg = None
    if "--home" in args:
        i = args.index("--home")
        if i + 1 >= len(args):
            sys.stderr.write(USAGE + "\n")
            return 2
        home_arg = args[i + 1]
        args = args[:i] + args[i + 2:]
    if home_arg is None or len(args) != 1 or args[0] not in ("update", "version") or not os.path.isabs(home_arg):
        sys.stderr.write(USAGE + "\n")
        return 2
    home = Path(home_arg).resolve()
    if not (home / ".git").exists() or not (home / "core").is_dir():
        print("%s is not a Daedalus home (no .git or core/ there). %s" % (home, NOTHING))
        return 1
    return update(home) if args[0] == "update" else version(home)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
