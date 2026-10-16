#!/usr/bin/env python3
"""daedalus update | daedalus version — taking a release in one step (update-command design, 2026-10-15).

    daedalus update     close every Daedalus window first, then type this in a terminal
    daedalus version    the release this home runs, its remote and its tag

The `daedalus` command on PATH is a shim that runs this file with `--home <this home>`. Every path comes from
--home: this script reads nothing from its own directory (a later release runs it from a temporary copy, and the
first update runs it from a temporary file the README's one line saves it to), never reads stdin, and closes stdin for every program it runs. Standard library
only; the home's own core/upgrade.py is imported for one thing, its liveness check.

`daedalus update`, in order, non-interactive; it either finishes or leaves the home as it was:
  1. takes the home's update lock (state/.update.lock; session start honours it), then refuses while a Daedalus
     session is live in this home, naming each (the rollback's check, upgrade._live_sessions);
  2. picks the remote by the release's address (RELEASE_ADDRESS, or update.address in config.yaml for a home that
     follows a mirror) — never by name alone, so a fork named origin is never taken for the release — and checks
     that address is the one recorded, unrewritten (remote_problem, the release-pull rule guard-bash uses too);
  3. asks the remote which branch is its trunk (git ls-remote --symref <r> HEAD; main when it does not say);
  4. fetches that trunk and the release tags, then hands off: unless this run is the home's own core/update.py and
     that file equals the release's, the release's copy is written to a fresh temporary directory outside the home
     and runs in this one's place (--handed-off, holding this run's lock through --lock-fd), so the rules that move
     a home are always the release's; a script run from a temporary file or a pipe always hands off;
  5. with the home already at the remote trunk: says it is up to date (and finishes a stopped upgrade first);
  6. classifies every path where the working tree or HEAD differs from the release, judged against every copy
     of that path on the release's history: a local change outside CLAUDE.md and .claude/settings.json, an
     untracked file where the release adds one, or a merge or rebase half done is refused, naming it; an older
     release's copy checked out on purpose is reported and replaced;
  7. a home that tracks paths no release ever had (its vault; is_deployment_path) is in merge mode: after the
     local-layer migration below, one local commit sets every release path to the release's copy and carries
     .gitignore's own lines, then the release merges into the home's branch (migrate_and_merge) — its history, its
     vault and its branch's own remote kept, a failure restoring only what the move wrote. Otherwise:
     a clean home whose HEAD the release contains fast-forwards; any other runs the local-layer migration —
     backup branch local/before-update-<stamp> and copies under state/update-backups/<stamp>/ first; rules and
     hook groups no release ever had go to .claude/settings.local.json (state/settings-before-merge.json's
     additions too), a removed Edit(/CLAUDE.md) deny becomes boundary.edit_brief: true in config.yaml, brief
     lines no release ever had go to CLAUDE.local.md, and what it does not move is reported — then resets to
     the release, SOUL.md's journal written back (it is the deployment's, dirty or committed). A failure from
     the backup on restores the original HEAD, working tree and local-layer files, never the backup commit;
  8. runs core/upgrade.py --caller update --progress now, not at the next session start;
  9. runs core/doctor.sh quietly, and
 10. leads with the result on the first line — "Daedalus updated 0.7.2 -> 0.7.3; doctor OK.", "Daedalus is up to date
     (X).", or "Not updated: <reason>." — and says the rest on later lines, one sentence each: the move, the upgrade's
     stop, each doctor finding, the notes. A refusal is one line, naming at most three paths (the full list in
     state/update-refused.txt), and never advises undoing, resetting or deleting anything.
Exit 0: updated or up to date; 1: refused (nothing changed) or restored; 2: updated, but the upgrade or doctor names
something.

Two more forms are not verbs of the command; setup, the upgrade and doctor run them:
    python3 core/update.py --install-shim --home <home>   writes ~/.local/bin/daedalus for this home (never over a
        file it did not write, nor over one serving another home that is still there) and says how to reach it
        from the login shell; one line per thing to say, exit 0 always
    python3 core/update.py --doctor --home <home>         doctor's lines: local edits in tracked files, a stale
        auto-mode line, the command
DAEDALUS_NO_COMMAND set (the test suite sets it, core/tests/setup_suite.bash) writes and checks no shim.

Tests replace the upgrade and doctor with DAEDALUS_UPDATE_UPGRADE / DAEDALUS_UPDATE_DOCTOR (a command, split as a
shell would, given the same arguments).
"""
from __future__ import annotations

import difflib
import fcntl
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

# The release's address (Decision 20): a remote is the release's when its recorded URL normalises to this. A fork's
# maintainer changes this one constant; a home that deliberately follows a mirror sets update.address instead.
RELEASE_ADDRESS = "github.com/lpelty/daedalus"
RELEASE_URL = "https://github.com/lpelty/daedalus.git"
UPDATE_LOCK = Path("state") / ".update.lock"
STAMP = Path("state") / "upgraded-to"
LOCK_WAIT_SECS = 2      # a session start holds the lock shared for a moment; a second update holds it throughout
NOTHING = "Nothing in this home was changed."
USAGE = "usage: daedalus update | daedalus version   (python3 core/update.py <verb> --home <absolute path>)"
SELF = Path("core") / "update.py"
JOURNAL = "SOUL.md"     # the deployment's journal: modified in the working tree, kept across the move
GITIGNORE = ".gitignore"
# distcheck.DIST_PATHS, carried here because this script never imports the old home's code (a test pins the two):
# a path under these is code that runs as the release in every window, so it is never a deployment's own path
DIST_PATHS = ("core", "CLAUDE.md", ".claude/settings.json", "mods")
REFUSED_LIST = Path("state") / "update-refused.txt"
NOT_UPDATED = "Not updated: "
MOST = 3                # a refusal names at most this many paths; the full list goes to state/update-refused.txt


class Refuse(Exception):
    """One sentence that ends the update with nothing changed (exit 1)."""


# --- git and the home ----------------------------------------------------------------------------------------------

def _env() -> Dict[str, str]:
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"      # a fetch never stops to ask for a password: the update is non-interactive
    return env


def git(home: Path, *args: str, timeout: int = 120, env: Optional[Dict[str, str]] = None) -> Tuple[int, str, str]:
    e = _env()
    e.update(env or {})
    try:
        r = subprocess.run(["git", "-C", str(home)] + list(args), stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=timeout, env=e)
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %d s" % timeout
    except OSError as e:
        return 127, "", str(e)
    return r.returncode, r.stdout, r.stderr


def _last(text: str) -> str:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1] if lines else "no message"


def _cause(text: str) -> str:
    """git's own reason from a failed fetch: its first fatal:/error: line, not the advice it prints after, with no
    closing period (the sentence adds its own)."""
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    for ln in lines:
        for tag in ("fatal:", "error:"):
            if ln.startswith(tag):
                return ln[len(tag):].strip().rstrip(".") or "no message"
    return _last(text).rstrip(".") or "no message"


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
    """An address in one form for comparing: host (lower case) and path (lower case too on GitHub), without the scheme, the user, a port, a
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
    host = host.lower()
    if host in ("github.com", "www.github.com"):     # GitHub names owner and repository without regard to case
        host, path = "github.com", path.lower()
    return host + "/" + path.lstrip("/")


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
        raise Refuse("Not updated: no remote of this home has the release's address %s (remotes: %s); add it with git "
                     "remote add daedalus %s, then run daedalus update again. %s" % (want, listed, add, NOTHING))
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

def take_lock(home: Path, inherited: Optional[int] = None) -> Optional[int]:
    """The home's update lock, held to the last line. A session start takes it shared for a moment, so a held lock
    is waited for briefly before it counts as another update's. A handed-off run is given its parent's descriptor
    (--lock-fd): the same open lock, so taking it again succeeds at once and nothing else can take it between."""
    if inherited is not None:
        try:
            fcntl.flock(inherited, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return inherited
        except OSError:
            return None
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
            raise Refuse("Not updated: this home predates v0.7.0 (its core/upgrade.py has no liveness check); "
                         "update it with git. " + NOTHING)
    return list(_LIVE["fn"](home))


def _join(words: List[str]) -> str:
    if len(words) < 3:
        return " and ".join(words)
    return ", ".join(words[:-1]) + " and " + words[-1]


def summarise(home: Path, paths: List[str]) -> str:
    """A list of paths in a refusal's one line: the path itself when there is one; else the count, the first
    directory when at least two thirds share it, and at most three examples. With more than three, the full list is
    written (overwritten) to state/update-refused.txt, which the words name inside the parentheses. A refusal never prints a wall of paths."""
    paths = list(paths)
    if len(paths) == 1:
        return paths[0]
    tops: Dict[str, int] = {}
    for q in paths:
        if "/" in q:
            tops[q.split("/", 1)[0]] = tops.get(q.split("/", 1)[0], 0) + 1
    top = max(tops, key=lambda k: tops[k]) if tops else None
    under = " under %s/" % top if top and tops[top] * 3 >= len(paths) * 2 else ""
    shown = ", ".join(paths[:MOST])
    if len(paths) > MOST:
        shown += ", …"
        try:
            (home / "state").mkdir(parents=True, exist_ok=True)
            (home / REFUSED_LIST).write_text("\n".join(paths) + "\n")
            shown += "; the full list is in %s" % REFUSED_LIST.as_posix()
        except OSError:
            pass
    return "%d files%s (%s)" % (len(paths), under, shown)


def _names_in_words(names: List[str]) -> str:
    """Live sessions, by name: at most three, then "and N more"."""
    if len(names) <= MOST:
        return _join(names)
    return "%s and %d more" % (", ".join(names[:MOST]), len(names) - MOST)


def refuse_if_live(home: Path, tail: str = NOTHING) -> None:
    live = live_sessions(home)
    if live:
        one = len(live) == 1
        raise Refuse("Not updated: %d Daedalus session%s live in this home — %s. Close %s, then run daedalus update "
                     "again. %s" % (len(live), " is" if one else "s are", _names_in_words(live), "it" if one else "them",
                                    tail))


# --- the move ------------------------------------------------------------------------------------------------------

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


# --- the local layer: classify, migrate, back up, reset, restore (Decisions 4, 15, 16, 21; §4.3) --------------------

BRIEF = "CLAUDE.md"
SETTINGS = ".claude/settings.json"
LOCAL_BRIEF = "CLAUDE.local.md"
LOCAL_SETTINGS = ".claude/settings.local.json"
CONFIG = "config.yaml"
MIGRATABLE = (BRIEF, SETTINGS)      # the tracked files whose local lines the migration knows how to move
BEFORE_MERGE = Path("state") / "settings-before-merge.json"
BACKUPS = Path("state") / "update-backups"
# what the backup copies, and under which name: a file that is not there is recorded as <name>.absent
COPIES = ((BRIEF, "CLAUDE.md"), (LOCAL_BRIEF, "CLAUDE.local.md"), (SETTINGS, "settings.json"),
          (LOCAL_SETTINGS, "settings.local.json"), (CONFIG, "config.yaml"), (JOURNAL, "SOUL.md"))
LOCAL_LAYER = (LOCAL_BRIEF, LOCAL_SETTINGS, CONFIG)     # the untracked files a migration writes, and a restore puts back
PATH_TOOLS = ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit")
RULE_KINDS = ("allow", "deny", "ask")
BRIEF_DENY = "Edit(CLAUDE.md)"      # Edit(/CLAUDE.md) in any anchor, normalised
ZERO = "0" * 40                     # git's name for "no blob": the path is absent
AUTO_MODE_LINE = "Editing CLAUDE.md in the Daedalus home"   # the v0.7.2 README's auto-mode line
# an operation git has half done; the refusal says to finish it — never to abort it, which throws away any conflict
# resolution not yet committed
IN_PROGRESS = (("MERGE_HEAD", "a merge"), ("rebase-merge", "a rebase"), ("rebase-apply", "a rebase"),
               ("CHERRY_PICK_HEAD", "a cherry-pick"), ("REVERT_HEAD", "a revert"), ("BISECT_LOG", "a bisect"))
_MISSING = object()


class Unmovable(Exception):
    """A clause: why the migration cannot read what it must move. Raised before anything is written."""


class MoveFailed(Exception):
    """A step of the move failed after the backup began: the home is restored."""


def home_relative_glob(root: Path, pattern: str) -> Optional[str]:
    """verifylib.home_relative_glob, carried here because this script never imports the old home's code
    (Decision 12); a test pins the two together. `//path` is absolute, `~/path` names no file of the home, `/path`
    and `./path` and a bare `path` are read at the home, and a trailing slash names the directory and all in it."""
    g = pattern
    if g.startswith("//"):
        try:
            g = Path(g[1:]).resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return None
        if pattern.endswith("/"):
            g += "/"
    elif g.startswith("~"):
        return None
    elif g.startswith("./"):
        g = g[2:]
    elif g.startswith("/"):
        g = g[1:]
    if g.endswith("/"):
        g = g.rstrip("/") + "/**"
    if g in ("", ".", "/**", "./**"):
        return None
    return g


def normalise_rule(home: Path, rule: str) -> str:
    """A permission rule in one form for comparing: a file tool's anchored path read relative to the home, so
    Edit(./SOUL.md), Edit(/SOUL.md) and Edit(//<home>/SOUL.md) are one rule. Any other rule is itself."""
    r = rule.strip()
    m = re.match(r"^([A-Za-z]+)\((.*)\)$", r)
    if not m or m.group(1) not in PATH_TOOLS:
        return r
    g = home_relative_glob(home, m.group(2))
    return r if g is None else "%s(%s)" % (m.group(1), g)


def _out(res: Tuple[int, str, str], what: str) -> str:
    code, out, err = res
    if code != 0:
        raise MoveFailed("%s failed (%s)" % (what, _last(err or out)))
    return out


def tree(home: Path, rev: str) -> Dict[str, str]:
    """path → blob of every file of `rev` ({} for no rev)."""
    if not rev:
        return {}
    code, out, err = git(home, "ls-tree", "-r", "-z", "--full-tree", rev, timeout=120)
    if code != 0:
        raise Unmovable("git could not list %s (%s)" % (rev[:12], _last(err)))
    d = {}
    for ent in out.split("\0"):
        meta, _, path = ent.partition("\t")
        parts = meta.split()
        if path and len(parts) == 3:
            d[path] = parts[2]
    return d


def history(home: Path, ref: str, paths: Tuple[str, ...] = ()) -> Dict[str, Set[str]]:
    """path → every blob that path has held on `ref`'s history (ZERO among them when it was ever absent): what came
    from a release at some time, so is never a local edit. `paths` limits it to those."""
    code, out, err = git(home, "log", "-m", "--root", "--raw", "-z", "--no-abbrev", "--no-renames", "--format=", ref,
                         *(("--",) + paths if paths else ()), timeout=600)
    if code != 0:
        raise Unmovable("git could not read the release's history (%s)" % _last(err))
    hist: Dict[str, Set[str]] = {}
    toks = out.split("\0")
    i = 0
    while i < len(toks):
        t = toks[i].lstrip("\n")
        if t.startswith(":") and i + 1 < len(toks):
            parts = t.split()
            if len(parts) >= 4:
                hist.setdefault(toks[i + 1], set()).update((parts[2], parts[3]))
            i += 2
            continue
        i += 1
    return hist


def blob_text(home: Path, blob: str) -> Optional[str]:
    if not blob or blob == ZERO:
        return None
    code, out, _ = git(home, "cat-file", "blob", blob)
    return out if code == 0 else None


def worktree_blobs(home: Path, paths: List[str]) -> Dict[str, str]:
    """path → the blob the working-tree file would be (ZERO when it is not there)."""
    blobs = {p: ZERO for p in paths}
    present = [p for p in paths if (home / p).is_file()]
    if present:
        try:
            r = subprocess.run(["git", "-C", str(home), "hash-object", "--stdin-paths"], input="\n".join(present) + "\n",
                               capture_output=True, text=True, timeout=300, env=_env())
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Unmovable("git could not read the working tree (%s)" % e)
        if r.returncode != 0:
            raise Unmovable("git could not read the working tree (%s)" % _last(r.stderr))
        for p, b in zip(present, r.stdout.split()):
            blobs[p] = b
    return blobs


def _names(res: Tuple[int, str, str]) -> List[str]:
    code, out, err = res
    if code != 0:
        raise Unmovable("git diff failed (%s)" % _last(err))
    return [p for p in out.split("\0") if p]


def in_progress(home: Path) -> Optional[str]:
    """The clause naming an operation git has half done in this home."""
    for name, what in IN_PROGRESS:
        gp = git(home, "rev-parse", "--git-path", name)[1].strip()
        if gp and (Path(gp) if os.path.isabs(gp) else home / gp).exists():
            return "%s is in progress in this home; finish it" % what
    gp = git(home, "rev-parse", "--git-path", "index.lock")[1].strip()
    if gp and (Path(gp) if os.path.isabs(gp) else home / gp).exists():
        return ("git's index lock (%s) is held; once no git command is running in this home, remove that file" % gp)
    return None


def _test_raise(where: str) -> None:
    """Test knob: DAEDALUS_UPDATE_TEST_RAISE=<where> raises an error that is not a refusal there (classify, inside
    the reset or the release's merge, at the start of finish)."""
    if os.environ.get("DAEDALUS_UPDATE_TEST_RAISE") == where:
        raise RuntimeError("injected by DAEDALUS_UPDATE_TEST_RAISE")


def _unexpected(e: BaseException) -> str:
    return "an unexpected error (%s: %s)" % (type(e).__name__, _one_line(str(e)) or "no message")


def _guarded(fn: Callable[[], List[str]]) -> List[str]:
    """A restore's problems; a restore that itself raises is one problem, never a second error past the move."""
    try:
        return fn()
    except Exception as e:      # the restore must always reach the refusal line
        return ["the rest of the restore (%s)" % _unexpected(e)]


def classify(home: Path, head: str, target: str, base: str, hist: Dict[str, Set[str]]) -> Dict[str, Any]:
    """Every path where the working tree or HEAD differs from the release (Decision 16). A path is local when its
    working-tree blob or its HEAD blob matches no version of it on the release's history; pinned when both are release copies but one is neither the merge base's
    nor the release's (an older release's copy, checked out on purpose). SOUL.md is the deployment's, never
    classified (Decision 15). An absent file is a release's state when the merge base or the release lacks it too
    (a path a later release added, or one the release deleted); a deletion of a file both have is local. Also:
    untracked files at paths the release has. A deployment path — tracked here, never on the release's history,
    not under DIST_PATHS (a vault the home tracks is the case doctor knows) — is the deployment's own: never local,
    carried by merging (deployment)."""
    _test_raise("classify")
    th, tt, tb = tree(home, head), tree(home, target), tree(home, base)
    changed = sorted(set(_names(git(home, "diff", "--name-only", "-z", "--no-renames", target)))
                     | set(_names(git(home, "diff", "--name-only", "-z", "--no-renames", head, target))))
    code, out, err = git(home, "ls-files", "-z")
    if code != 0:
        raise Unmovable("git could not list tracked files (%s)" % _last(err))
    indexed = set(p for p in out.split("\0") if p)
    deployment = sorted(p for p in changed if is_deployment_path(p, th, indexed, hist, tt))
    dep = set(deployment)
    wt = worktree_blobs(home, [p for p in changed if p not in dep] + ([JOURNAL] if JOURNAL not in changed else []))
    local, pinned = [], []
    for p in changed:
        if p == JOURNAL or p in dep:
            continue
        seen = hist.get(p, set())

        def known(b: str) -> bool:
            return (p not in tt or p not in tb) if b == ZERO else b in seen
        hb, wb = th.get(p, ZERO), wt[p]
        if not (known(hb) and known(wb)):
            local.append(p)
        elif {hb, wb} - {tb.get(p, ZERO), tt.get(p, ZERO)}:
            pinned.append(p)
    code, out, err = git(home, "ls-files", "--others", "--exclude-standard", "-z")
    if code != 0:
        raise Unmovable("git could not list untracked files (%s)" % _last(err))
    untracked = {p for p in out.split("\0") if p and p in tt}
    # an ignored file at a path the release adds is as untracked as any other: the reset or the fast-forward
    # would write over it, and no backup holds it
    untracked |= {p for p in tt if p not in th and p not in indexed and os.path.lexists(str(home / p))}
    untracked = sorted(untracked)
    dirty = [p for p in changed if p not in dep and wt.get(p, ZERO) != th.get(p, ZERO)]
    return {"head": th, "target": tt, "base": tb, "changed": changed, "wt": wt, "local": local, "pinned": pinned,
            "untracked": untracked, "dirty": dirty, "deployment": deployment}


def _under_dist(p: str) -> bool:
    return any(p == d or p.startswith(d + "/") for d in DIST_PATHS)


def is_deployment_path(p: str, th: Dict[str, str], indexed: Set[str], hist: Dict[str, Set[str]],
                       tt: Dict[str, str]) -> bool:
    """Tracked at HEAD or in the index, never present on the release's history, and not distribution code."""
    return (p in th or p in indexed) and p not in hist and p not in tt and not _under_dist(p)


def deployment_paths(home: Path, ref: Optional[str] = None) -> List[str]:
    """The paths at this home's HEAD that belong to the deployment (is_deployment_path), judged against `ref`, else
    the release's trunk as last fetched (no network). With no release ref in this home at all, the vault the home
    repository tracks (the layout doctor knows). For upgrade.py's rollback, which must not check out a release that
    would take them out of the working tree."""
    ref = ref or _offline_trunk(home)
    if not ref:
        code, out, _ = git(home, "ls-files", "-z", "--", "vault")
        return sorted(p for p in out.split("\0") if p) if code == 0 else []
    th, tt = tree(home, "HEAD"), tree(home, ref)
    hist = history(home, ref)
    return sorted(p for p in th if is_deployment_path(p, th, set(), hist, tt))


GITIGNORE_MARK = "# This home's own lines, kept here by daedalus update (a release's .gitignore never had them):"


def ignores(text: str, names: List[str]) -> Dict[str, bool]:
    """name -> whether a top-level .gitignore of `text` ignores it (a name ending in / is a directory), judged by git
    itself in a scratch repository: no other ignore source, no file of the home."""
    out: Dict[str, bool] = {}
    tmp = tempfile.mkdtemp(prefix="daedalus-ignore-")
    try:
        if subprocess.run(["git", "init", "-q", tmp], stdin=subprocess.DEVNULL, capture_output=True,
                          env=_env()).returncode != 0:
            raise Unmovable("git could not make a scratch repository to read .gitignore")
        Path(tmp, GITIGNORE).write_text(text)
        for n in names:
            if n.endswith("/"):
                Path(tmp, n).mkdir(parents=True, exist_ok=True)
            r = subprocess.run(["git", "-C", tmp, "-c", "core.excludesFile=/dev/null", "check-ignore", "--no-index",
                                "-q", "--", n.rstrip("/")], stdin=subprocess.DEVNULL, capture_output=True, env=_env())
            out[n] = r.returncode == 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return out


def carried_gitignore(home: Path, c: Dict[str, Any], hist: Dict[str, Set[str]]) -> Optional[str]:
    """Merge mode's .gitignore: the release's copy, then a marked block of this home's lines no release's .gitignore
    ever had, plus an un-ignore for each top-level name of a deployment path the home does not ignore and the release
    would — later rules win, so the block keeps its precedence over the release's lines. Never three-way merged: two
    sides appending at the end would conflict at every release. None when this home's copy is the release's. Raises
    Unmovable when the result would ignore a deployment path differently from this home's copy (nothing is written)."""
    rel = blob_text(home, c["target"].get(GITIGNORE, ZERO)) or ""
    wt_path = home / GITIGNORE
    mine = _read(wt_path) if wt_path.is_file() else (blob_text(home, c["head"].get(GITIGNORE, ZERO)) or "")
    mine = mine or ""
    if mine == rel:
        return None
    known = set()
    for b in sorted(hist.get(GITIGNORE, set())):
        for ln in (blob_text(home, b) or "").splitlines():
            known.add(ln.rstrip())
    rel_lines = {ln.rstrip() for ln in rel.splitlines()}
    own: List[str] = []
    for ln in mine.splitlines():
        r = ln.rstrip()
        if r.strip() and r != GITIGNORE_MARK and r not in known and r not in rel_lines and r not in own:
            own.append(r)
    names = sorted({(p.split("/", 1)[0] + "/") if "/" in p else p for p in c["deployment"]})
    def build(lines: List[str]) -> str:
        body = rel if (not rel or rel.endswith("\n")) else rel + "\n"
        return body + (("\n" if body else "") + GITIGNORE_MARK + "\n" + "\n".join(lines) + "\n" if lines else "")
    was = ignores(mine, names) if names else {}
    trial = ignores(build(own), names) if names else {}
    for n in names:
        if trial[n] and not was[n]:
            un = "!/%s" % n
            if un not in own:
                own.append(un)
    new = build(own)
    if names and ignores(new, names) != was:
        wrong = [n for n, v in ignores(new, names).items() if v != was[n]]
        raise Unmovable("this home's .gitignore cannot be carried over the release's without changing what it ignores "
                        "(%s)" % _join(wrong[:MOST]))
    return new


# --- settings (§4.3 "Settings") --------------------------------------------------------------------------------------

def _json(text: Optional[str], what: str) -> Dict[str, Any]:
    if text is None or not text.strip():
        return {}
    try:
        d = json.loads(text)
    except ValueError as e:
        raise Unmovable("%s is not valid JSON (%s); fix it or move it aside" % (what, e))
    return d if isinstance(d, dict) else {}


def _rules(home: Path, d: Dict[str, Any]) -> List[Tuple[str, str, str]]:
    perms = d.get("permissions") if isinstance(d.get("permissions"), dict) else {}
    out = []
    for k in RULE_KINDS:
        for r in perms.get(k) or []:
            if isinstance(r, str):
                out.append((k, r, normalise_rule(home, r)))
    return out


def _groups(d: Dict[str, Any]) -> List[Tuple[str, str, Any]]:
    hooks = d.get("hooks") if isinstance(d.get("hooks"), dict) else {}
    out = []
    for ev, gs in hooks.items():
        if isinstance(gs, list):
            for g in gs:
                out.append((ev, json.dumps(g, sort_keys=True), g))
    return out


def _matcher(g: Any) -> Optional[str]:
    return g.get("matcher") if isinstance(g, dict) else None


def _hook_name(ev: str, g: Any) -> str:
    m = _matcher(g)
    return "the %s hook%s" % (ev, " for %s" % m if m else "")


def analyse_settings(home: Path, wt: Dict[str, Any], base: Dict[str, Any], target: Dict[str, Any],
                     versions: List[Dict[str, Any]], before: Optional[Dict[str, Any]], bdir: str) -> Dict[str, Any]:
    """What of the working tree's settings is the deployment's own, judged three ways: against the merge base (what
    changed here), the release (what the release has now) and every version on the release's history (what came
    from a release at some time, so is never moved). Also the additions of state/settings-before-merge.json, read
    by the history test alone (its own base is not known)."""
    h_rules = {(k, n) for v in versions for k, _, n in _rules(home, v)}
    h_hooks = {(ev, key) for v in versions for ev, key, _ in _groups(v)}
    base_r = {(k, n) for k, _, n in _rules(home, base)}
    wt_r = {(k, n) for k, _, n in _rules(home, wt)}
    target_r = {(k, n) for k, _, n in _rules(home, target)}
    rules: List[Tuple[str, str, str]] = []
    hooks: List[Tuple[str, str, Any]] = []
    reports: List[str] = []
    edit_brief = False

    def add_rule(k: str, raw: str, n: str) -> None:
        if (k, n) not in {(a, c) for a, _, c in rules}:
            rules.append((k, raw, n))

    def add_hook(ev: str, key: str, g: Any) -> None:
        if (ev, key) not in {(a, b) for a, b, _ in hooks}:
            hooks.append((ev, key, g))

    for k, raw, n in _rules(home, wt):
        if (k, n) not in base_r and (k, n) not in h_rules:
            add_rule(k, raw, n)
    for k, raw, n in _rules(home, base):
        if (k, n) in wt_r:
            continue
        if k == "deny" and n == BRIEF_DENY:
            edit_brief = True
        elif (k, n) in target_r:
            reports.append("the deployment had removed the %s rule %s; the release's settings have it again" % (k, raw))
    base_g, wt_g = _groups(base), _groups(wt)
    base_keys, wt_keys = {(e, k) for e, k, _ in base_g}, {(e, k) for e, k, _ in wt_g}
    target_keys = {(e, k) for e, k, _ in _groups(target)}
    gone = [x for x in base_g if (x[0], x[1]) not in wt_keys]
    for ev, key, g in wt_g:
        if (ev, key) in base_keys or (ev, key) in h_hooks:
            continue
        twin = next((x for x in gone if x[0] == ev and _matcher(x[2]) == _matcher(g)), None)
        if twin is not None:
            # a release group the deployment changed: moving it would run beside the release's, so it is not moved
            gone.remove(twin)
            reports.append("the deployment had changed %s; the release's runs; the old one is in %s/settings.json"
                           % (_hook_name(ev, g), bdir))
        else:
            add_hook(ev, key, g)
    for ev, key, g in gone:
        if (ev, key) in target_keys:
            reports.append("the deployment had removed %s; the release's settings have it again" % _hook_name(ev, g))
    extra: List[Tuple[Tuple[str, ...], Any]] = []
    for k, v in wt.items():
        if k in ("permissions", "hooks"):
            continue
        bv = base.get(k, _MISSING)
        if bv == v:
            continue
        if isinstance(v, dict) and isinstance(bv, dict):
            extra += [((k, sk), sv) for sk, sv in v.items() if bv.get(sk, _MISSING) != sv]
        else:
            extra.append(((k,), v))
    wp = wt.get("permissions") if isinstance(wt.get("permissions"), dict) else {}
    bp = base.get("permissions") if isinstance(base.get("permissions"), dict) else {}
    extra += [(("permissions", sk), sv) for sk, sv in wp.items()
              if sk not in RULE_KINDS and bp.get(sk, _MISSING) != sv]
    if before:
        for k, raw, n in _rules(home, before):
            if (k, n) not in h_rules:
                add_rule(k, raw, n)
        for ev, key, g in _groups(before):
            if (ev, key) not in h_hooks:
                add_hook(ev, key, g)
    return {"rules": rules, "hooks": hooks, "extra": extra, "edit_brief": edit_brief, "reports": reports}


def merged_local_settings(home: Path, local: Dict[str, Any], plan: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]],
                                                                                              List[str]]:
    """settings.local.json with the plan's rules, hooks and keys added (de-duplicated by normalised form), or None
    when nothing new; and the sentences for keys it already sets otherwise (never overwritten)."""
    d = json.loads(json.dumps(local))
    changed = False
    reports = []
    for k, raw, n in plan["rules"]:
        perms = d.setdefault("permissions", {})
        if not isinstance(perms, dict) or not isinstance(perms.setdefault(k, []), list):
            reports.append("the rule %s could not join .claude/settings.local.json, whose permissions are not a list; "
                           "it is in the backup" % raw)
            continue
        if n not in {normalise_rule(home, x) for x in perms[k] if isinstance(x, str)}:
            perms[k].append(raw)
            changed = True
    for ev, key, g in plan["hooks"]:
        hk = d.setdefault("hooks", {})
        if not isinstance(hk, dict) or not isinstance(hk.setdefault(ev, []), list):
            reports.append("%s could not join .claude/settings.local.json; it is in the backup" % _hook_name(ev, g))
            continue
        if key not in {json.dumps(x, sort_keys=True) for x in hk[ev]}:
            hk[ev].append(g)
            changed = True
    for path, v in plan["extra"]:
        node: Any = d
        for part in path[:-1]:
            node = node.setdefault(part, {}) if isinstance(node, dict) else None
        name = ".".join(path)
        if not isinstance(node, dict):
            reports.append("the deployment had set %s, which could not join .claude/settings.local.json; it is in the "
                           "backup" % name)
        elif path[-1] not in node:
            node[path[-1]] = v
            changed = True
        elif node[path[-1]] != v:
            reports.append("the deployment had set %s in .claude/settings.json, and .claude/settings.local.json already "
                           "sets it otherwise; that value stays, and the other is in the backup" % name)
    return (d if changed else None), reports


# --- the brief (§4.3 "Brief") ----------------------------------------------------------------------------------------

def _heading(lines: List[str], i: int) -> str:
    for k in range(min(i, len(lines)) - 1, -1, -1):
        if lines[k].startswith("#"):
            return lines[k].lstrip("#").strip()
    return "the top of CLAUDE.md"


BRIDGE = 2     # at most this many release lines between two local lines stay in the passage (a rule, a separator)


def _local_runs(lines: List[str], known: Set[str], splits: Optional[List[int]] = None) -> List[List[str]]:
    """The contiguous runs of lines no release ever had (blank lines join a run; a release's line ends it). Up to
    BRIDGE release lines with local lines on both sides (a '---' rule, a table separator, a common heading) stay in
    the run; a longer such stretch splits it, and each split is counted in `splits`."""
    rel = [bool(ln.strip()) and ln.rstrip() in known for ln in lines]
    keep = [False] * len(lines)
    i = 0
    while i < len(lines):
        if not rel[i]:
            i += 1
            continue
        j = i
        while j < len(lines) and (rel[j] or not lines[j].strip()):
            j += 1
        before = any(lines[k].strip() and not rel[k] for k in range(i))
        after = j < len(lines)
        if before and after:
            if sum(rel[i:j]) <= BRIDGE:
                for k in range(i, j):
                    keep[k] = True
            elif splits is not None:
                splits.append(1)
        i = j
    runs: List[List[str]] = []
    cur: List[str] = []

    def flush() -> None:
        while cur and not cur[-1].strip():
            cur.pop()
        while cur and not cur[0].strip():
            cur.pop(0)
        if cur:
            runs.append(list(cur))
        cur.clear()
    for ln, r, k in zip(lines, rel, keep):
        if r and not k:
            flush()
        else:
            cur.append(ln)
    flush()
    return runs


def analyse_brief(base: str, wt: str, target: str, versions: List[str], bdir: str) -> Dict[str, Any]:
    """Three-way, from the merge base's CLAUDE.md to the working tree's, each line judged against every version of
    CLAUDE.md on the release's history: inserted lines no release had move; reworded release passages are reported
    and not moved (CLAUDE.md goes back to the release's wording, and both would load); release lines the
    deployment removed are reported."""
    known = {ln.rstrip() for t in versions for ln in t.splitlines()}
    tl = {ln.rstrip() for ln in target.splitlines()}
    b, w = base.splitlines(), wt.splitlines()
    blocks: List[Tuple[str, List[str]]] = []
    reworded: List[str] = []
    removed = 0
    splits: List[int] = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, b, w, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        runs = _local_runs(w[j1:j2], known, splits)
        heading = _heading(b, i1)
        if tag == "replace" and runs:
            reworded.append(heading)
            continue
        blocks += [(heading, r) for r in runs]
        if tag in ("delete", "replace"):
            removed += sum(1 for ln in b[i1:i2] if ln.strip() and ln.rstrip() in tl)
    reports = []
    if reworded:
        where = " and ".join("'%s'" % h for h in dict.fromkeys(reworded))
        reports.append("CLAUDE.md: the deployment had reworded %d passage%s of the release's brief, under %s; the "
                       "release's wording is back; the reworded text is in %s/CLAUDE.md — move what still applies "
                       "into CLAUDE.local.md" % (len(reworded), "" if len(reworded) == 1 else "s", where, bdir))
    if splits:
        reports.append("CLAUDE.md: %d local passage%s held lines a release's brief also has, so %s split there in "
                       "CLAUDE.local.md without them; the whole passage is in %s/CLAUDE.md"
                       % (len(splits), "" if len(splits) == 1 else "s", "it is" if len(splits) == 1 else "they are",
                          bdir))
    if removed:
        reports.append("CLAUDE.md: the deployment had removed %d line%s of the release's brief; they are back; the "
                       "old text is in %s/CLAUDE.md" % (removed, "" if removed == 1 else "s", bdir))
    return {"blocks": blocks, "reports": reports}


def local_brief_text(existing: str, blocks: List[Tuple[str, List[str]]], stamp: str, branch: str) -> Optional[str]:
    """CLAUDE.local.md with the moved blocks appended under one header, or None when every block is there already."""
    new = []
    for heading, run in blocks:
        body = "\n".join(run)
        if body not in existing:
            new.append("<!-- was under: %s -->\n%s" % (heading, body))
    if not new:
        return None
    day = "%s-%s-%s" % (stamp[0:4], stamp[4:6], stamp[6:8])
    out = existing
    if out and not out.endswith("\n"):
        out += "\n"
    if out:
        out += "\n"
    return (out + "## Local brief — moved from CLAUDE.md by daedalus update, %s (backup: %s)\n\n" % (day, branch)
            + "\n\n".join(new) + "\n")


def with_edit_brief(text: str) -> str:
    """config.yaml with boundary.edit_brief: true, the rest of the file as it was."""
    lines = text.splitlines()
    for i, ln in enumerate(lines):
        if re.match(r"^boundary:", ln):
            j = i + 1
            while j < len(lines) and not re.match(r"^[^\s#]", lines[j]):
                words = lines[j].split()
                if words and words[0] == "edit_brief:":
                    lines[j] = (re.match(r"^\s*", lines[j]).group(0) or "  ") + "edit_brief: true"
                    return "\n".join(lines) + "\n"
                j += 1
            lines.insert(i + 1, "  edit_brief: true")
            return "\n".join(lines) + "\n"
    body = text if not text or text.endswith("\n") else text + "\n"
    return body + ("\n" if body else "") + "boundary:\n  edit_brief: true\n"


def auto_mode_note(home: Path) -> Optional[str]:
    """The operator's Claude Code settings, read only: an auto-mode line that lets this home's CLAUDE.md be edited
    (the v0.7.2 README's wording) now names the wrong file."""
    user = os.path.expanduser("~")
    files = []
    for d in (os.environ.get("CLAUDE_CONFIG_DIR"), os.path.join(user, ".claude")):
        if d and os.path.join(d, "settings.json") not in files:
            files.append(os.path.join(d, "settings.json"))
    forms = {str(home)}
    if str(home).startswith(user + os.sep):
        forms.add("~" + str(home)[len(user):])
    for f in files:
        try:
            with open(f) as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            continue
        am = d.get("autoMode") if isinstance(d, dict) else None
        allow = am.get("allow") if isinstance(am, dict) else None
        for e in allow if isinstance(allow, list) else []:
            if isinstance(e, str) and AUTO_MODE_LINE in e and any(x in e for x in forms):
                return ("~/.claude/settings.json allows auto mode to edit CLAUDE.md here; reword that line to name "
                        "CLAUDE.local.md (README, 'Letting Daedalus edit its own brief')")
    return None


# --- back up, move, restore ------------------------------------------------------------------------------------------

def _read(path: Path) -> Optional[str]:
    try:
        return path.read_text()
    except (OSError, UnicodeDecodeError):
        return None


def _ident(home: Path) -> Dict[str, str]:
    """An author for the backup commit when git has none configured here (a fresh machine)."""
    if git(home, "var", "GIT_COMMITTER_IDENT")[0] == 0 and git(home, "var", "GIT_AUTHOR_IDENT")[0] == 0:
        return {}
    who = {"NAME": "daedalus update", "EMAIL": "daedalus-update@localhost"}
    return {"GIT_%s_%s" % (r, k): v for r in ("AUTHOR", "COMMITTER") for k, v in who.items()}


def make_backup(home: Path, head: str, branch: str, bdir: Path, stamp: str) -> None:
    """Copies of the six files under state/update-backups/<stamp>/, then the branch: a commit of the working tree's
    tracked files on top of HEAD, made in a temporary index so neither HEAD nor the real index moves."""
    bdir.mkdir(parents=True)
    for rel, name in COPIES:
        src = home / rel
        if src.is_file():
            shutil.copy2(str(src), str(bdir / name))
        else:
            (bdir / (name + ".absent")).write_text("")
    gp = git(home, "rev-parse", "--git-path", "index.daedalus-update")[1].strip()
    idx = gp if os.path.isabs(gp) else str(home / gp)
    env = {"GIT_INDEX_FILE": idx}
    try:
        _out(git(home, "read-tree", head, env=env), "making the backup branch")
        _out(git(home, "add", "-u", "--", ".", env=env, timeout=600), "making the backup branch")
        t = _out(git(home, "write-tree", env=env), "making the backup branch").strip()
        env.update(_ident(home))
        c = _out(git(home, "commit-tree", t, "-p", head, "-m",
                     "daedalus update %s: this home's tracked files as they were before the update" % stamp, env=env),
                 "making the backup branch").strip()
        _out(git(home, "branch", branch, c), "making the backup branch")
    finally:
        try:
            os.unlink(idx)
        except OSError:
            pass


def restore(home: Path, orig_head: str, branch: str, bdir: Path, moved_before_merge: bool) -> List[str]:
    """Back to the original HEAD and working tree — never the backup commit, which would join the branch's history
    — and every local-layer file as the copies hold it (Decision 21). What could not be put back, in words."""
    problems = []

    def step(res: Tuple[int, str, str], what: str) -> bool:
        if res[0] != 0:
            problems.append("%s (%s)" % (what, _last(res[2] or res[1])))
            return False
        return True
    if git(home, "rev-parse", "-q", "--verify", "refs/heads/" + branch)[0] != 0:
        # without the branch nothing could put the working tree's edits back after a reset: leave the files alone
        problems.append("the tracked files, left as they are because the backup branch %s does not exist" % branch)
    elif step(git(home, "reset", "--quiet", "--hard", orig_head, timeout=600), "putting back the original HEAD"):
        if step(git(home, "checkout", branch, "--", ".", timeout=600), "the original files from the backup branch"):
            for p in _names(git(home, "diff", "--name-only", "-z", "--no-renames", "--diff-filter=D", orig_head,
                                branch)):
                try:
                    (home / p).unlink()
                except OSError:
                    pass
        step(git(home, "reset", "--quiet"), "unstaging the original changes")
    for rel, name in COPIES:
        if rel not in LOCAL_LAYER:
            continue
        try:
            if (bdir / name).is_file():
                (home / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(str(bdir / name), str(home / rel))
            elif (bdir / (name + ".absent")).exists() and (home / rel).exists():
                (home / rel).unlink()
        except OSError as e:
            problems.append("%s (%s)" % (rel, e))
    if moved_before_merge:
        try:
            shutil.move(str(bdir / BEFORE_MERGE.name), str(home / BEFORE_MERGE))
        except OSError as e:
            problems.append("%s (%s)" % (BEFORE_MERGE, e))
    return problems


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".daedalus-update")
    tmp.write_text(text)
    os.replace(str(tmp), str(path))


def _new_stamp(home: Path) -> str:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    n = 1
    while (home / BACKUPS / stamp).exists() or \
            git(home, "rev-parse", "-q", "--verify", "refs/heads/local/before-update-" + stamp)[0] == 0:
        n += 1
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-%d" % n
    return stamp


def plan_local_layer(home: Path, c: Dict[str, Any], hist: Dict[str, Set[str]], stamp: str, branch: str,
                     bdir_rel: str) -> Dict[str, Any]:
    """What the local-layer migration moves, read and judged before anything is written (Unmovable ends it with
    nothing changed): the local settings, the local brief, config.yaml's edit_brief line, SOUL.md's journal, and the
    sentences to report. Both moves (reset and merge) take this plan."""
    th, tt, tb = c["head"], c["target"], c["base"]

    def at(path: str, which: Dict[str, str]) -> Optional[str]:
        return blob_text(home, which.get(path, ZERO))

    def versions(path: str) -> List[str]:
        return [t for t in (blob_text(home, b) for b in sorted(hist.get(path, set()))) if t is not None]

    reports: List[str] = []
    local_settings = None
    before_path = home / BEFORE_MERGE
    before = _json(_read(before_path), str(BEFORE_MERGE)) if before_path.is_file() else None
    edit_brief = False
    if SETTINGS in c["local"] or before:
        wt_text = _read(home / SETTINGS) if (home / SETTINGS).is_file() else at(SETTINGS, th)
        plan = analyse_settings(home, _json(wt_text, SETTINGS) if SETTINGS in c["local"] else {},
                                _json(at(SETTINGS, tb), SETTINGS), _json(at(SETTINGS, tt), SETTINGS),
                                [_json(t, SETTINGS) for t in versions(SETTINGS)], before, bdir_rel)
        if SETTINGS not in c["local"]:
            plan["edit_brief"], plan["reports"] = False, []
        edit_brief = plan["edit_brief"]
        reports += plan["reports"]
        existing = _json(_read(home / LOCAL_SETTINGS), LOCAL_SETTINGS) if (home / LOCAL_SETTINGS).is_file() else {}
        local_settings, more = merged_local_settings(home, existing, plan)
        reports += more
    brief_text = None
    if BRIEF in c["local"]:
        wt_brief = _read(home / BRIEF)
        bp = analyse_brief(at(BRIEF, tb) or "", wt_brief if wt_brief is not None else (at(BRIEF, th) or ""),
                           at(BRIEF, tt) or "", versions(BRIEF), bdir_rel)
        reports += bp["reports"]
        brief_text = local_brief_text(_read(home / LOCAL_BRIEF) or "", bp["blocks"], stamp, branch)
    config_text = None
    if edit_brief and config_value(home, "boundary.edit_brief") != "true":
        config_text = with_edit_brief(_read(home / CONFIG) or "")
    soul = None
    try:
        soul = (home / JOURNAL).read_bytes()
    except OSError:
        pass
    if c["pinned"]:
        if len(c["pinned"]) == 1:
            reports.append("%s held an older release's copy; the release's copy replaces it" % c["pinned"][0])
        else:
            reports.append("%s held older releases' copies; the release's copies replace them" % summarise(home, c["pinned"]))
    return {"local_settings": local_settings, "brief_text": brief_text, "config_text": config_text, "soul": soul,
            "soul_release_text": at(JOURNAL, tt), "reports": reports,
            "staged": git(home, "diff", "--cached", "--quiet")[0] != 0}


def _backup_or_refuse(home: Path, head: str, branch: str, bdir: Path, stamp: str) -> None:
    try:
        make_backup(home, head, branch, bdir, stamp)
    except (MoveFailed, OSError) as e:
        # nothing in the home has been touched yet: no reset (it would wipe the uncommitted edits the backup was
        # for), and no half-made backup left to be mistaken for a whole one
        if git(home, "rev-parse", "-q", "--verify", "refs/heads/" + branch)[0] == 0:
            git(home, "branch", "-D", branch)
        shutil.rmtree(str(bdir), ignore_errors=True)
        raise Refuse(NOT_UPDATED + "%s; the backup could not be made, so nothing in this home was changed." % e)


def _write_local_layer(home: Path, plan: Dict[str, Any], bdir: Path, soul_release: bool) -> bool:
    """The local-layer files the plan names, and settings-before-merge.json moved into the backup; True when it
    was moved."""
    if soul_release:
        _write(bdir / "SOUL.release.md", plan["soul_release_text"] or "")
    if plan["local_settings"] is not None:
        _write(home / LOCAL_SETTINGS, json.dumps(plan["local_settings"], indent=2) + "\n")
    if plan["brief_text"] is not None:
        _write(home / LOCAL_BRIEF, plan["brief_text"])
    if plan["config_text"] is not None:
        _write(home / CONFIG, plan["config_text"])
    if (home / BEFORE_MERGE).is_file():
        shutil.move(str(home / BEFORE_MERGE), str(bdir / BEFORE_MERGE.name))
        return True
    return False


def _restored_refusal(home: Path, e: Exception, head: str, branch: str, bdir: Path, bdir_rel: str, staged: bool,
                      problems: List[str], what: str = "") -> Refuse:
    have = [w for w, ok in ((branch, git(home, "rev-parse", "-q", "--verify", "refs/heads/" + branch)[0] == 0),
                            (bdir_rel + "/", bdir.is_dir())) if ok]
    back = ("this home is back as it was (HEAD %s, its files and its local-layer files restored%s)"
            % (head[:7], "; changes that were staged come back unstaged" if staged else ""))
    if problems:
        shown = problems[:MOST] + (["and %d more" % (len(problems) - MOST)] if len(problems) > MOST else [])
        back = "restoring this home also failed for %s — put those back from the backup" % "; ".join(shown)
    where = ("the backup is at %s" % " and ".join(have)) if have else "no backup of this home survives"
    return Refuse(NOT_UPDATED + "%s; %s; %s." % (what or e, back, where))


def _notes(plan: Dict[str, Any], soul_release: bool, bdir_rel: str) -> List[str]:
    notes = []
    if plan["config_text"] is not None:
        notes.append("This home had removed the CLAUDE.md deny, so boundary.edit_brief is now true in config.yaml: "
                     "Daedalus edits CLAUDE.local.md, and since config.yaml changed, each window re-runs core/gates.sh "
                     "before its next claim")
    if soul_release:
        notes.append("the release changed SOUL.md; this home's journal is kept, and the release's copy is in "
                     "%s/SOUL.release.md" % bdir_rel)
    return notes + plan["reports"]


def _moved(plan: Dict[str, Any]) -> List[str]:
    return [p for p, k in ((LOCAL_SETTINGS, "local_settings"), (LOCAL_BRIEF, "brief_text")) if plan[k] is not None]


def migrate_and_reset(home: Path, c: Dict[str, Any], hist: Dict[str, Set[str]], head: str, target: str,
                      branch_name: str, remote: str, trunk: str) -> Tuple[str, List[str]]:
    """The local-layer migration, then the reset to the release, SOUL.md's journal written back; a failure from
    the backup to the end restores the home. Returns the move's sentence and the report sentences."""
    stamp = _new_stamp(home)
    branch = "local/before-update-" + stamp
    bdir_rel = (BACKUPS / stamp).as_posix()
    bdir = home / BACKUPS / stamp
    tt, tb = c["target"], c["base"]
    plan = plan_local_layer(home, c, hist, stamp, branch, bdir_rel)
    soul = plan["soul"]
    keep_soul = soul is not None and git_blob_of(home, soul) != tt.get(JOURNAL, ZERO)
    soul_release = keep_soul and tt.get(JOURNAL, ZERO) != tb.get(JOURNAL, ZERO) and JOURNAL in tt
    moved_before_merge = False
    old = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        _backup_or_refuse(home, head, branch, bdir, stamp)
        try:
            moved_before_merge = _write_local_layer(home, plan, bdir, soul_release)
            _out(git(home, "reset", "--quiet", "--hard", target, timeout=600),
                 "moving this home to %s/%s" % (remote, trunk))
            _test_raise("reset")
            if keep_soul:
                (home / JOURNAL).write_bytes(soul)
            set_tracking(home, branch_name, remote, trunk)
        except (MoveFailed, OSError, Unmovable) as e:
            problems = _guarded(lambda: restore(home, head, branch, bdir, moved_before_merge))
            raise _restored_refusal(home, e, head, branch, bdir, bdir_rel, plan["staged"], problems)
        except Exception as e:      # any other error inside the move restores too: never a half-moved home
            problems = _guarded(lambda: restore(home, head, branch, bdir, moved_before_merge))
            raise _restored_refusal(home, e, head, branch, bdir, bdir_rel, plan["staged"], problems, _unexpected(e))
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    moved = _moved(plan)
    where = "backup at %s and %s/" % (branch, bdir_rel)
    line = ("Local edits moved to %s; %s." % (" and ".join(moved), where)) if moved else "Backup at %s." % where[10:]
    return line, _notes(plan, soul_release, bdir_rel)


class MergeConflict(Exception):
    """The release's merge would conflict in these paths."""

    def __init__(self, paths: List[str]) -> None:
        super().__init__(", ".join(paths))
        self.paths = paths


def _merge_env(home: Path) -> Dict[str, str]:
    env = {"GIT_MERGE_AUTOEDIT": "no"}
    env.update(_ident(home))
    return env


NO_HOOKS = ("-c", "core.hooksPath=/dev/null")


def restore_merge(home: Path, orig_head: str, branch: str, bdir: Path, moved_before_merge: bool,
                  paths: List[str]) -> List[str]:
    """Merge mode's restore: the branch back to the original HEAD without touching a file (reset --soft, then the
    index), then only the paths the move wrote put back from the backup branch — those it lacks, which the move
    added, removed — then the local layer, as restore does. A deployment path is never named: the move never wrote
    one, so a write to the vault made while the update ran (an editor, a sync client, a hook) is kept."""
    problems = []

    def step(res: Tuple[int, str, str], what: str) -> bool:
        if res[0] != 0:
            problems.append("%s (%s)" % (what, _last(res[2] or res[1])))
            return False
        return True
    gp = git(home, "rev-parse", "--git-path", "MERGE_HEAD")[1].strip()
    if gp and (Path(gp) if os.path.isabs(gp) else home / gp).exists():
        step(git(home, "merge", "--abort", timeout=600), "ending the release's merge")
    if step(git(home, "reset", "-q", "--soft", orig_head), "the branch back at the original HEAD"):
        step(git(home, "reset", "-q"), "unstaging the original changes")
    if git(home, "rev-parse", "-q", "--verify", "refs/heads/" + branch)[0] != 0:
        problems.append("the release's files, left as they are because the backup branch %s does not exist" % branch)
    else:
        try:
            kept = tree(home, branch)
        except Unmovable as e:
            kept = None
            problems.append("the release's files (%s)" % e)
        if kept is not None:
            back = [p for p in paths if p in kept]
            for i in range(0, len(back), 200):
                step(git(home, "checkout", branch, "--", *back[i:i + 200], timeout=600),
                     "the original files from the backup branch")
            for p in paths:
                if p not in kept and os.path.lexists(str(home / p)):
                    try:
                        (home / p).unlink()
                    except OSError as e:
                        problems.append("%s (%s)" % (p, e))
            step(git(home, "reset", "-q"), "unstaging the original changes")
    for rel, name in COPIES:
        if rel not in LOCAL_LAYER:
            continue
        try:
            if (bdir / name).is_file():
                (home / rel).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(str(bdir / name), str(home / rel))
            elif (bdir / (name + ".absent")).exists() and (home / rel).exists():
                (home / rel).unlink()
        except OSError as e:
            problems.append("%s (%s)" % (rel, e))
    if moved_before_merge:
        try:
            shutil.move(str(bdir / BEFORE_MERGE.name), str(home / BEFORE_MERGE))
        except OSError as e:
            problems.append("%s (%s)" % (BEFORE_MERGE, e))
    return problems


def migrate_and_merge(home: Path, c: Dict[str, Any], hist: Dict[str, Set[str]], head: str, target: str,
                      branch_name: str, gitignore_text: Optional[str], ver: str) -> Tuple[str, List[str], bool]:
    """Merge mode, for a home that tracks paths no release has (its vault): the backup, the local layer, then one
    local commit that sets every release path to the release's copy (the migrated CLAUDE.md and settings, pinned
    and dirty copies) and writes the carried .gitignore, then the release merged into the home's branch, SOUL.md
    and .gitignore resolved to ours. Never a reset of the working tree, never a deployment path written, never the
    branch's tracking moved: the home keeps its history and pushes to its own remote. A failure restores
    (restore_merge). Returns the move's sentence, the reports, and whether the release was already merged."""
    stamp = _new_stamp(home)
    branch = "local/before-update-" + stamp
    bdir_rel = (BACKUPS / stamp).as_posix()
    bdir = home / BACKUPS / stamp
    th, tt, tb = c["head"], c["target"], c["base"]
    dep = set(c["deployment"])
    plan = plan_local_layer(home, c, hist, stamp, branch, bdir_rel)
    soul = plan["soul"]
    soul_release = soul is not None and JOURNAL in tt and tt.get(JOURNAL, ZERO) != tb.get(JOURNAL, ZERO) \
        and git_blob_of(home, soul) != tt.get(JOURNAL, ZERO)
    soul_dirty = soul is not None and git_blob_of(home, soul) != th.get(JOURNAL, ZERO)
    setting = [p for p in c["changed"] if p not in dep and p not in (JOURNAL, GITIGNORE)]
    written = sorted(set(setting) | {JOURNAL, GITIGNORE})
    moved_before_merge = False
    already = False
    staged_dep: List[str] = []
    old = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        _backup_or_refuse(home, head, branch, bdir, stamp)
        try:
            moved_before_merge = _write_local_layer(home, plan, bdir, soul_release)
            staged_dep = [p for p in _names(git(home, "diff", "--cached", "--name-only", "-z", "--no-renames"))
                          if p in dep]
            _out(git(home, "reset", "-q"), "unstaging this home's changes")
            # the migration commit: every release path the release's copy, the carried .gitignore
            in_t = [p for p in setting if p in tt]
            for i in range(0, len(in_t), 200):
                _out(git(home, "checkout", target, "--", *in_t[i:i + 200], timeout=600), "setting the release's files")
            for p in setting:
                if p not in tt:
                    _out(git(home, "rm", "-q", "--cached", "--ignore-unmatch", "--", p), "leaving out %s" % p)
                    if os.path.lexists(str(home / p)):
                        (home / p).unlink()
            if gitignore_text is not None and _read(home / GITIGNORE) != gitignore_text:
                _write(home / GITIGNORE, gitignore_text)
            if (home / GITIGNORE).is_file() and git_blob_of(home, (home / GITIGNORE).read_bytes()) != th.get(GITIGNORE, ZERO):
                _out(git(home, "add", "--", GITIGNORE), "staging .gitignore")
            if git(home, "diff", "--cached", "--quiet")[0] != 0:
                _out(git(home, *NO_HOOKS, "commit", "--no-verify", "-q", "-m",
                         "daedalus update %s: local edits moved to the local layer; release files set to %s"
                         % (stamp, ver), env=_ident(home), timeout=600), "the migration commit")
            mig = _out(git(home, "rev-parse", "--verify", "HEAD"), "reading HEAD").strip()
            already = git(home, "merge-base", "--is-ancestor", target, mig)[0] == 0
            if not already:
                if soul_dirty and tt.get(JOURNAL, ZERO) != tb.get(JOURNAL, ZERO) and JOURNAL in th:
                    _out(git(home, "checkout", "HEAD", "--", JOURNAL), "setting SOUL.md aside for the merge")
                written = sorted(set(written) | {p for p in _names(git(home, "diff", "--name-only", "-z",
                                                                       "--no-renames", mig, target)) if p not in dep})
                code, out, err = git(home, *NO_HOOKS, "-c", "rerere.enabled=false", "-c", "merge.renames=false",
                                     "merge", "--no-ff", "--no-commit", "--no-edit", target, env=_merge_env(home),
                                     timeout=600)
                conflicts = _names(git(home, "diff", "--name-only", "-z", "--diff-filter=U"))
                if [p for p in conflicts if p not in (JOURNAL, GITIGNORE)]:
                    raise MergeConflict([p for p in conflicts if p not in (JOURNAL, GITIGNORE)])
                if code != 0 and not conflicts:
                    raise MoveFailed("merging the release failed (%s)" % _last(err or out))
                _test_raise("merge")
                mt = tree(home, mig)
                for p in (JOURNAL, GITIGNORE):
                    if p in mt:
                        _out(git(home, "checkout", mig, "--", p), "keeping this home's %s" % p)
                        _out(git(home, "add", "--", p), "keeping this home's %s" % p)
                _out(git(home, *NO_HOOKS, "commit", "--no-verify", "-q", "-m",
                         "daedalus update %s: merge release %s (%s) into %s" % (stamp, ver, target[:7], branch_name),
                         env=_ident(home), timeout=600), "the merge commit")
            if soul is not None:
                (home / JOURNAL).write_bytes(soul)
        except MergeConflict as e:
            problems = _guarded(lambda: restore_merge(home, head, branch, bdir, moved_before_merge, written))
            raise _restored_refusal(home, e, head, branch, bdir, bdir_rel, plan["staged"], problems,
                                    "merging the release would conflict in %s" % summarise(home, e.paths))
        except (MoveFailed, OSError, Unmovable) as e:
            problems = _guarded(lambda: restore_merge(home, head, branch, bdir, moved_before_merge, written))
            raise _restored_refusal(home, e, head, branch, bdir, bdir_rel, plan["staged"], problems)
        except Exception as e:      # any other error inside the move restores too: never a half-merged home
            problems = _guarded(lambda: restore_merge(home, head, branch, bdir, moved_before_merge, written))
            raise _restored_refusal(home, e, head, branch, bdir, bdir_rel, plan["staged"], problems, _unexpected(e))
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    moved = _moved(plan)
    where = "backup at %s and %s/" % (branch, bdir_rel)
    did = ("the release was merged already; this home's history is kept" if already else
           "merged the release into %s; this home's history is kept" % branch_name)
    line = (("Local edits moved to %s; %s; %s." % (" and ".join(moved), did, where)) if moved
            else "%s; %s." % (did[:1].upper() + did[1:], where))
    notes = _notes(plan, soul_release, bdir_rel)
    if staged_dep:      # the migration commit carries release paths only: a staged deployment change comes out unstaged
        n = len(staged_dep)
        shown = ", ".join(staged_dep[:MOST]) + (", …" if n > MOST else "")
        notes.append(("1 change that was staged in this home's own files (%s) is unstaged now, its file as it was; "
                      "core/vault-commit.sh stages and commits it" % shown) if n == 1 else
                     ("%d changes that were staged in this home's own files (%s) are unstaged now, their files as they "
                      "were; core/vault-commit.sh stages and commits them" % (n, shown)))
    return line, notes, already


def git_blob_of(home: Path, data: bytes) -> str:
    try:
        r = subprocess.run(["git", "-C", str(home), "hash-object", "--stdin"], input=data, capture_output=True,
                           timeout=60, env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout.decode().strip() if r.returncode == 0 else ""


# --- the hand-off (Decision 13) -------------------------------------------------------------------------------------

def running_release_copy(home: Path, ref: str) -> bool:
    """True when this run is the home's own core/update.py, a real file, whose blob equals <ref>:core/update.py.
    A script run from anywhere else — a temporary file (the README's first-update line), a pipe (python3
    /dev/stdin) — is never taken for the release's: it always hands off to the release's own copy."""
    me = os.path.realpath(globals().get("__file__") or "")
    mine = home / SELF
    if not me or me != os.path.realpath(str(mine)) or not mine.is_file():
        return False
    code, here, _ = git(home, "hash-object", "--no-filters", "--", str(mine))
    want = git(home, "rev-parse", "-q", "--verify", "%s:%s" % (ref, SELF.as_posix()))[1].strip()
    return code == 0 and bool(want) and here.strip() == want


def hand_off(home: Path, ref: str, verb: str, lock_fd: int) -> Optional[int]:
    """Run the release's core/update.py in this one's place, from a fresh temporary directory outside the home,
    with --handed-off and this run's lock passed down; its exit code, or None when this run goes on itself (the
    release has no core/update.py)."""
    try:
        blob = subprocess.run(["git", "-C", str(home), "show", "%s:%s" % (ref, SELF.as_posix())],
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=120, env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    if blob.returncode != 0 or not blob.stdout:
        return None
    tmp = tempfile.mkdtemp(prefix="daedalus-update-")
    try:
        script = os.path.join(tmp, "update.py")
        with open(script, "wb") as f:
            f.write(blob.stdout)
        sys.stdout.flush()
        proc = subprocess.Popen([sys.executable, script, verb, "--home", str(home), "--handed-off",
                                 "--lock-fd", str(lock_fd)], stdin=subprocess.DEVNULL, pass_fds=(lock_fd,),
                                cwd=str(home))
        while True:
            try:
                return proc.wait()
            except KeyboardInterrupt:
                continue    # the child has the same Ctrl-C and decides; this run only waits for it
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


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


def finish(home: Path, first: str, move: str = "", notes: Optional[List[str]] = None,
           after: str = "") -> Tuple[List[str], int]:
    """The upgrade, then doctor; the lines to print and the exit code. The first line is the result alone —
    "<first>; doctor OK." when the upgrade finished and doctor is clean, else "<first>." — and every later line one
    sentence: the move, `after` (said once the upgrade finished), the upgrade's stop, each doctor finding, the notes."""
    _test_raise("finish")
    later = [move] if move else []
    stop = run_upgrade(home)
    if stop:
        lines, code = [first + "."] + later + ["The upgrade stopped: " + _sentence(stop)], 2
    else:
        if after:
            later.append(after)
        missing = run_doctor(home)
        if missing:
            lines, code = [first + "."] + later + ["Doctor: " + _sentence(m) for m in missing], 2
        else:
            lines, code = [first + "; doctor OK."] + later, 0
    lines += [_sentence(n[:1].upper() + n[1:]) for n in (notes or [])]
    return lines, code


# --- the command on PATH: the shim (Decision 1, §4.1) and doctor's lines (§4.5) --------------------------------------

SHIM_MARKER = "# daedalus shim — installed by core/setup.sh for the home below; safe to delete"
NO_COMMAND = "DAEDALUS_NO_COMMAND"      # set (the test suite sets it): no shim is written and none is checked
LOGIN_TIMEOUT = 5.0
_END = "__daedalus_login_end__"


def shim_path() -> Path:
    """~/.local/bin/daedalus, ~ from the environment's HOME (tests point it at scratch)."""
    return Path(os.path.expanduser("~")) / ".local" / "bin" / "daedalus"


def _tilde(p: Any) -> str:
    s, user = str(p), os.path.expanduser("~")
    return "~" + s[len(user):] if user not in ("", "/") and (s == user or s.startswith(user + os.sep)) else s


def shim_text(home: Path) -> str:
    return '#!/usr/bin/env bash\n%s\nexec python3 "%s/core/update.py" "$@" --home "%s"\n' % (SHIM_MARKER, home, home)


def _full_path(home: Path) -> str:
    return "python3 %s/core/update.py update --home %s" % (home, home)


def shim_owner(path: Path) -> Tuple[str, Optional[str]]:
    """What ~/.local/bin/daedalus is: ("absent", None), ("foreign", None) — not a file this install wrote — or
    ("shim", the home its exec line names)."""
    if not os.path.lexists(str(path)):
        return "absent", None
    if path.is_symlink() or not path.is_file():
        return "foreign", None
    try:
        lines = path.read_text().splitlines()
    except (OSError, UnicodeDecodeError):
        return "foreign", None
    if len(lines) < 3 or lines[1] != SHIM_MARKER:
        return "foreign", None
    m = re.match(r'^exec python3 "(.+)/core/update\.py" "\$@" --home "(.+)"$', lines[2])
    return ("shim", m.group(2)) if m else ("foreign", None)


def _same(a: str, b: str) -> bool:
    return a == b or os.path.realpath(a) == os.path.realpath(b)


def login_lookup(timeout: float) -> Tuple[bool, str]:
    """(answered, what `command -v daedalus` says) in the operator's login shell — the PATH a new terminal has, not
    this process's (a SessionStart hook runs with Claude Code's). A shell that fails, times out or is not there falls
    back to this process's PATH, answered False."""
    sh = os.environ.get("SHELL") or ""
    if sh and timeout > 0 and os.access(sh, os.X_OK):
        try:
            r = subprocess.run([sh, "-l", "-c", "command -v daedalus; echo %s" % _END], stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=timeout, env=_env())
            lines = r.stdout.splitlines()
            if _END in lines:
                said = [ln.strip() for ln in lines[:lines.index(_END)] if ln.strip()]
                return True, (said[-1] if said else "")
        except (OSError, subprocess.TimeoutExpired):
            pass
    return False, shutil.which("daedalus") or ""


def path_sentence(path: Path, timeout: float) -> Optional[str]:
    """None when the login shell finds this shim as `daedalus`; else what to do, worded for the operator's shell."""
    _, found = login_lookup(timeout)
    if found and _same(found, str(path)):
        return None
    if found:
        return "Another daedalus (%s) comes first on PATH; use %s update." % (found, _tilde(path))
    shell = os.path.basename(os.environ.get("SHELL") or "")
    if shell == "zsh":
        add = "echo 'path+=~/.local/bin' >> ~/.zshrc (new terminals)"
    elif shell == "bash":
        add = "echo 'PATH=~/.local/bin:$PATH' >> ~/.bash_profile (new terminals)"
    else:
        add = "add it in your shell's startup file (new terminals)"
    return "Add ~/.local/bin to PATH: %s; until then type %s update." % (add, _tilde(path))


def install_shim(home: Path, dry: bool = False, timeout: float = LOGIN_TIMEOUT) -> List[str]:
    """Install ~/.local/bin/daedalus for this home and say how to reach it, never over a file this install did not
    write or one serving another home that is still there. [] when it is in place and the login shell finds it.
    Never raises: every refusal is a line (setup and the upgrade go on)."""
    if os.environ.get(NO_COMMAND):
        return []
    path = shim_path()
    want = shim_text(home)
    kind, other = shim_owner(path)
    lines: List[str] = []
    if kind == "foreign":
        return ["%s is not a shim daedalus wrote, so it was left as it is; type %s instead."
                % (_tilde(path), _full_path(home))]
    if kind == "shim" and other != str(home) and (Path(other) / SELF).is_file():
        return ["%s serves %s; this home is not on the command, so type %s here." % (_tilde(path), other,
                                                                                      _full_path(home))]
    current = _read(path) if kind == "shim" else None
    if current != want:
        if kind == "absent":
            said = ("Installed the daedalus command at %s; type daedalus update in a terminal (or %s update)."
                    % (_tilde(path), _tilde(path)))
            would = "would install the daedalus command at %s." % _tilde(path)
        elif other != str(home):
            said = "%s served %s, which has no core/update.py any more; it now serves this home." % (_tilde(path), other)
            would = "would rewrite %s, which serves %s (gone), for this home." % (_tilde(path), other)
        else:
            said = "Rewrote %s for this home (its text was an older shim's)." % _tilde(path)
            would = "would rewrite %s for this home (its text is an older shim's)." % _tilde(path)
        if dry:
            return [would]
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".daedalus.")
            try:
                with os.fdopen(fd, "w") as fh:
                    fh.write(want)
                os.chmod(tmp, 0o755)
                os.replace(tmp, str(path))
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        except OSError as e:      # a ~/.local left root-owned by an installer run with sudo, say
            return ["%s could not be %s (%s); the daedalus command was not installed, so type %s instead."
                    % (_tilde(path.parent), "written" if path.parent.is_dir() else "made", e.strerror or e,
                       _full_path(home))]
        lines.append(said)
    elif dry:
        return []
    advice = path_sentence(path, timeout)
    if advice:
        lines.append(advice)
    return lines


def command_line(home: Path) -> Optional[str]:
    """Doctor's command line: OK when the login shell finds this home's shim; else a NOTE with the install rule's
    sentence. None while DAEDALUS_NO_COMMAND is set."""
    if os.environ.get(NO_COMMAND):
        return None
    path = shim_path()
    kind, other = shim_owner(path)
    if kind == "absent":
        return ("NOTE     command: %s is absent; core/setup.sh installs it (until then type %s)"
                % (_tilde(path), _full_path(home)))
    if kind == "foreign":
        return ("NOTE     command: %s is not a shim daedalus wrote; type %s instead" % (_tilde(path), _full_path(home)))
    if other != str(home):
        if not (Path(other) / SELF).is_file():
            return ("NOTE     command: %s names %s, which has no core/update.py; core/setup.sh rewrites it for this "
                    "home" % (_tilde(path), other))
        return ("NOTE     command: %s serves %s; this home is not on the command (type %s)"
                % (_tilde(path), other, _full_path(home)))
    advice = path_sentence(path, LOGIN_TIMEOUT)
    if advice:
        return "NOTE     command: " + advice.rstrip(".")
    return "OK       command: daedalus on PATH (%s)" % _tilde(path)


def _offline_trunk(home: Path) -> Optional[str]:
    """The release's trunk as this home last fetched it, without the network: refs/remotes/<r>/HEAD, the branch's
    tracking ref on that remote, or <r>/main. None when no remote has the release's address or none is there."""
    branch = current_branch(home)
    try:
        remote, _ = pick_remote(home, branch)
    except Refuse:
        return None
    cands = []
    code, out, _ = git(home, "symbolic-ref", "--quiet", "refs/remotes/%s/HEAD" % remote)
    if code == 0 and out.strip():
        cands.append(out.strip())
    if branch and _cfg_lines(home, "--local", "--get", "branch.%s.remote" % branch) == [remote]:
        merge = (_cfg_lines(home, "--local", "--get", "branch.%s.merge" % branch) or [""])[0]
        if merge.startswith("refs/heads/"):
            cands.append("refs/remotes/%s/%s" % (remote, merge[len("refs/heads/"):]))
    cands.append("refs/remotes/%s/main" % remote)
    for ref in cands:
        if git(home, "rev-parse", "--verify", "--quiet", ref + "^{commit}")[0] == 0:
            return ref
    return None


def tracked_local_edits(home: Path) -> Optional[List[str]]:
    """The migratable tracked files (CLAUDE.md, .claude/settings.json) carrying a local edit: changed in the working
    tree, or holding at HEAD a copy no release on the last-fetched trunk ever had. None when this is not a git
    checkout."""
    if git(home, "rev-parse", "--verify", "--quiet", "HEAD")[0] != 0:
        return None
    code, out, _ = git(home, "diff", "--name-only", "-z", "HEAD", "--", *MIGRATABLE)
    found = set(p for p in out.split("\0") if p) if code == 0 else set()
    ref = _offline_trunk(home)
    if ref:
        try:
            hist = history(home, ref, MIGRATABLE)
        except Unmovable:
            hist = None
        if hist is not None:
            for p in MIGRATABLE:
                code, blob, _ = git(home, "rev-parse", "--verify", "--quiet", "HEAD:" + p)
                if code == 0 and blob.strip() and blob.strip() not in hist.get(p, set()):
                    found.add(p)
    return [p for p in MIGRATABLE if p in found]


def doctor_lines(home: Path) -> List[str]:
    lines = []
    edits = tracked_local_edits(home)
    if edits:
        lines.append("MISSING  local edits in tracked files: %s — run daedalus update, which moves them into the local "
                     "layer" % ", ".join(edits))
    elif edits is not None:
        lines.append("OK       tracked files: CLAUDE.md and .claude/settings.json carry no local edits")
    if auto_mode_note(home):
        lines.append("NOTE     brief: ~/.claude/settings.json's autoMode.allow names CLAUDE.md in this home; reword it "
                     "to CLAUDE.local.md (README, \"Letting Daedalus edit its own brief\")")
    cmd = command_line(home)
    if cmd:
        lines.append(cmd)
    return lines


# --- the verbs -----------------------------------------------------------------------------------------------------

def update(home: Path, handed_off: bool = False, lock_fd: Optional[int] = None) -> int:
    """Every outcome leads with its result on the first line; a refusal is one line starting "Not updated:", exit 1."""
    fd = take_lock(home, lock_fd)
    if fd is None:
        print(NOT_UPDATED + "another daedalus update is running in this home. " + NOTHING)
        return 1
    start = _head(home)
    try:
        lines, code = _update(home, fd, handed_off)
    except Refuse as e:
        lines, code = [_one_line(str(e))], 1
    except Exception as e:      # a line, never a traceback; it says what it reads, never that nothing changed
        lines, code = [_unexpected_line(home, e, start)], 1
    finally:
        os.close(fd)
    if lines:
        print("\n".join(lines))
    return code


def _head(home: Path) -> str:
    try:
        return git(home, "rev-parse", "-q", "--verify", "HEAD")[1].strip()
    except Exception:           # read for the error line only: an unreadable HEAD is said as unknown
        return ""


def _unexpected_line(home: Path, e: BaseException, start: str) -> str:
    """The line for an error that is not a refusal. A move restores the home in its own try, so this is reached
    before a move, after one, or by a fast-forward: the line says where this home's branch is now, read now."""
    now = _head(home)
    try:
        stuck = in_progress(home)
    except Exception:
        stuck = None
    again = "run daedalus update again, and if it says this again, report it."
    if start and now and now != start:
        return (NOT_UPDATED + "%s stopped the update after this home's branch moved from %s to %s, before it finished; "
                "%srun daedalus update again, which finishes it, and if it says this again, report it."
                % (_unexpected(e), start[:7], now[:7], (stuck + ", then ") if stuck else ""))
    where = ("this home's branch is still at %s" % now[:7]) if now and now == start else "this home's HEAD cannot be read"
    if stuck:
        return NOT_UPDATED + "%s; %s, but %s, then %s" % (_unexpected(e), where, stuck, again)
    return NOT_UPDATED + "%s; %s; %s" % (_unexpected(e), where, again)


def _one_line(text: str) -> str:
    return " ".join(text.split())


def _refuse_paths(home: Path, c: Dict[str, Any], paths: List[str], fetched: str) -> Refuse:
    """The refusal of release paths the update cannot carry: those the release now ships that differ here, and local
    changes; one line, never a list, never advice that would lose what they hold."""
    ships = [p for p in paths if p in c["target"] and p not in c["base"]
             and (c["head"].get(p, ZERO) != ZERO or c["wt"].get(p, ZERO) != ZERO)]
    rest = [p for p in paths if p not in ships]
    if rest:
        one = len(rest) == 1
        return Refuse(NOT_UPDATED + "%s carr%s local changes the update cannot carry (it carries only CLAUDE.md, "
                      ".claude/settings.json, SOUL.md and files no release has); %s"
                      % (summarise(home, rest), "ies" if one else "y", fetched))
    if len(ships) == 1:
        what = "%s, a file the release now ships, differs" % ships[0]
    else:
        what = "%s the release now ships differ" % summarise(home, ships)
    return Refuse(NOT_UPDATED + "%s in this home; move %s out of the release's way, then run daedalus update again; %s"
                  % (what, "it" if len(ships) == 1 else "them", fetched))


def _update(home: Path, fd: int, handed_off: bool) -> Tuple[List[str], int]:
    refuse_if_live(home)
    branch = current_branch(home)
    if not branch:
        raise Refuse(NOT_UPDATED + "this home is not on a branch (its HEAD is detached); check out its branch, then "
                     "run daedalus update again. " + NOTHING)
    remote, url = pick_remote(home, branch)
    problem = remote_problem(home, remote)
    if problem:
        raise Refuse(NOT_UPDATED + "%s. %s" % (problem, NOTHING))
    trunk = remote_trunk(home, remote)
    ref = "refs/remotes/%s/%s" % (remote, trunk)
    code, _, err = git(home, "fetch", "--quiet", "--no-tags", remote, "+refs/heads/%s:%s" % (trunk, ref), timeout=600)
    if code != 0:
        raise Refuse(NOT_UPDATED + "could not reach %s (%s). %s" % (url, _cause(err), NOTHING))
    git(home, "fetch", "--quiet", "--no-tags", remote, "refs/tags/v*:refs/tags/v*", timeout=300)   # tags: best effort
    fetched = "it fetched %s/%s, and nothing else in this home was changed." % (remote, trunk)
    if not handed_off and not running_release_copy(home, ref):
        child = hand_off(home, ref, "update", fd)
        if child is not None:
            return [], child      # the release's copy said its own lines
    target = git(home, "rev-parse", "--verify", ref + "^{commit}")[1].strip()
    head = git(home, "rev-parse", "--verify", "HEAD")[1].strip()
    if not target or not head:
        raise Refuse(NOT_UPDATED + "%s/%s or HEAD does not name a commit; %s" % (remote, trunk, fetched))
    stuck = in_progress(home)
    if stuck:
        raise Refuse(NOT_UPDATED + "%s, then run daedalus update again; %s" % (stuck, fetched))
    try:
        hist = history(home, target)
        base = git(home, "merge-base", head, target)[1].strip()
        c = classify(home, head, target, base, hist)
    except Unmovable as e:
        raise Refuse(NOT_UPDATED + "%s; %s" % (e, fetched))
    if c["untracked"]:
        one = len(c["untracked"]) == 1
        raise Refuse(NOT_UPDATED + "%s %s untracked here where the release adds files; move %s out of the release's "
                     "way, then run daedalus update again; %s"
                     % (summarise(home, c["untracked"]), "is" if one else "are", "it" if one else "them", fetched))
    dep = set(c["deployment"])
    merging = bool(dep)       # a home that tracks paths no release has (its vault) takes releases by merging
    carried = (GITIGNORE,) if merging else ()
    outside = [p for p in c["local"] if p not in MIGRATABLE and p not in carried]
    if outside:
        raise _refuse_paths(home, c, outside, fetched)
    gitignore_text = None
    if merging and GITIGNORE in c["changed"]:
        try:
            gitignore_text = carried_gitignore(home, c, hist)
        except Unmovable as e:
            raise Refuse(NOT_UPDATED + "%s; %s" % (e, fetched))
    head_gi = blob_text(home, c["head"].get(GITIGNORE, ZERO))
    gi_ours = (merging and gitignore_text is not None and head_gi == gitignore_text
               and _read(home / GITIGNORE) == head_gi)
    others = [p for p in c["changed"] if p != JOURNAL and p not in dep and not (p == GITIGNORE and gi_ours)]
    ver = home_version(home) or "unknown"
    contains = git(home, "merge-base", "--is-ancestor", target, head)[0] == 0
    if contains and not others:
        if _stamp(home) == ver:
            return ["Daedalus is up to date (%s)." % ver], 0
        # up to date, but an earlier upgrade stopped: run it now, so a second run finishes it
        return finish(home, "Daedalus is up to date (%s)" % ver, after="The upgrade that had stopped has finished.")
    ancestor = git(home, "merge-base", "--is-ancestor", head, target)[0] == 0
    soul_dirty = c["wt"].get(JOURNAL, ZERO) != c["head"].get(JOURNAL, ZERO)
    soul_moves = c["head"].get(JOURNAL, ZERO) != c["target"].get(JOURNAL, ZERO)
    refuse_if_live(home, tail=fetched[0].upper() + fetched[1:])
    old = ver if ver != "unknown" else head[:7]
    notes: List[str] = []
    move = ""
    already = False
    if not merging and ancestor and not [p for p in c["dirty"] if p != JOURNAL] and not (soul_dirty and soul_moves):
        code, msg = fast_forward(home, target)
        if code != 0:
            raise Refuse(NOT_UPDATED + "git could not fast-forward to %s/%s (%s); %s"
                         % (remote, trunk, _last(msg), fetched))
        set_tracking(home, branch, remote, trunk)
    else:
        new_ver = blob_text(home, c["target"].get("VERSION", ZERO))
        new_ver = new_ver.split("\n", 1)[0].strip() if new_ver else target[:7]
        try:
            if merging:
                move, notes, already = migrate_and_merge(home, c, hist, head, target, branch, gitignore_text, new_ver)
            else:
                move, notes = migrate_and_reset(home, c, hist, head, target, branch, remote, trunk)
        except Unmovable as e:
            raise Refuse(NOT_UPDATED + "%s; %s" % (e, fetched))
    auto = auto_mode_note(home)
    if auto:
        notes.append(auto)
    new = home_version(home) or target[:7]
    if head == target or already:
        first = "Daedalus is up to date (%s)" % new
    else:
        first = "Daedalus updated %s -> %s" % (old, new if new != old else "%s (%s)" % (new, target[:7]))
    return finish(home, first, move=move, notes=notes)


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
    # --match: a merged home may carry tags of its own on local commits, and the nearest tag of any name wins describe
    code, out, _ = git(home, "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*")
    if code == 0 and out.strip():
        parts.append("tag %s" % out.strip())
    print("Daedalus %s (%s)" % (home_version(home) or "(no VERSION)", ", ".join(parts)))
    return 0


def main(argv: List[str]) -> int:
    args = argv[1:]
    handed_off = "--handed-off" in args
    args = [a for a in args if a != "--handed-off"]
    lock_fd = None
    if "--lock-fd" in args:
        i = args.index("--lock-fd")
        if i + 1 >= len(args) or not args[i + 1].isdigit():
            sys.stderr.write(USAGE + "\n")
            return 2
        lock_fd = int(args[i + 1])
        args = args[:i] + args[i + 2:]
    home_arg = None
    if "--home" in args:
        i = args.index("--home")
        if i + 1 >= len(args):
            sys.stderr.write(USAGE + "\n")
            return 2
        home_arg = args[i + 1]
        args = args[:i] + args[i + 2:]
    if home_arg is not None and os.path.isabs(home_arg) and args in (["--install-shim"], ["--doctor"]):
        home = Path(home_arg).resolve()
        if not (home / SELF).is_file():
            print(NOT_UPDATED + "%s is not a Daedalus home with core/update.py. %s" % (home, NOTHING))
            return 1
        try:
            out = install_shim(home) if args == ["--install-shim"] else doctor_lines(home)
        except Exception as e:      # setup and doctor go on: a line, never a traceback
            out = ["the daedalus command could not be checked (%s: %s)" % (type(e).__name__, e)]
        for ln in out:
            print(ln)
        return 0
    if home_arg is None or len(args) != 1 or args[0] not in ("update", "version") or not os.path.isabs(home_arg):
        sys.stderr.write(USAGE + "\n")
        return 2
    home = Path(home_arg).resolve()
    if not (home / ".git").exists() or not (home / "core").is_dir():
        print(NOT_UPDATED + "%s is not a Daedalus home (no .git or core/ there). %s" % (home, NOTHING))
        return 1
    if args[0] == "version":
        return version(home)
    return update(home, handed_off, lock_fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
