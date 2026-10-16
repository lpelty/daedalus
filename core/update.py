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
  4. fetches that trunk and the release tags, then hands off: unless this run is the home's own core/update.py and
     that file equals the release's, the release's copy is written to a fresh temporary directory outside the home
     and runs in this one's place (--handed-off, holding this run's lock through --lock-fd), so the rules that move
     a home are always the release's; a script read from a pipe cannot be compared, so it always hands off;
  5. with the home already at the remote trunk: says it is up to date (and finishes a stopped upgrade first);
  6. classifies every path where the working tree or HEAD differs from the release, judged against every copy
     of that path on the release's history: a local change outside CLAUDE.md and .claude/settings.json, an
     untracked file where the release adds one, or a merge or rebase half done is refused, naming it; an older
     release's copy checked out on purpose is reported and replaced;
  7. a clean home whose HEAD the release contains fast-forwards; any other runs the local-layer migration —
     backup branch local/before-update-<stamp> and copies under state/update-backups/<stamp>/ first; rules and
     hook groups no release ever had go to .claude/settings.local.json (state/settings-before-merge.json's
     additions too), a removed Edit(/CLAUDE.md) deny becomes boundary.edit_brief: true in config.yaml, brief
     lines no release ever had go to CLAUDE.local.md, and what it does not move is reported — then resets to
     the release, SOUL.md's journal written back (it is the deployment's, dirty or committed). A failure from
     the backup on restores the original HEAD, working tree and local-layer files, never the backup commit;
  8. runs core/upgrade.py --caller update --progress now, not at the next session start;
  9. runs core/doctor.sh quietly, and
 10. says one line: "Daedalus updated 0.7.2 -> 0.7.3; doctor OK." (or what needs attention, one sentence each).
Exit 0: updated or up to date; 1: refused (nothing changed) or restored; 2: updated, but the upgrade or doctor names
something.

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
from typing import Any, Dict, List, Optional, Set, Tuple

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
IN_PROGRESS = (("MERGE_HEAD", "a merge", "git merge --abort"), ("rebase-merge", "a rebase", "git rebase --abort"),
               ("rebase-apply", "a rebase", "git rebase --abort"),
               ("CHERRY_PICK_HEAD", "a cherry-pick", "git cherry-pick --abort"),
               ("REVERT_HEAD", "a revert", "git revert --abort"), ("BISECT_LOG", "a bisect", "git bisect reset"))
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


def history(home: Path, ref: str) -> Dict[str, Set[str]]:
    """path → every blob that path has held on `ref`'s history (ZERO among them when it was ever absent): what came
    from a release at some time, so is never a local edit."""
    code, out, err = git(home, "log", "-m", "--root", "--raw", "-z", "--no-abbrev", "--no-renames", "--format=", ref,
                         timeout=600)
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
    """The clause naming an operation git has half done in this home, and the command that clears it."""
    for name, what, cmd in IN_PROGRESS:
        gp = git(home, "rev-parse", "--git-path", name)[1].strip()
        if gp and (Path(gp) if os.path.isabs(gp) else home / gp).exists():
            return "%s is in progress in this home; finish it or run %s" % (what, cmd)
    gp = git(home, "rev-parse", "--git-path", "index.lock")[1].strip()
    if gp and (Path(gp) if os.path.isabs(gp) else home / gp).exists():
        return ("git's index lock (%s) is held; once no git command is running in this home, remove that file" % gp)
    return None


def classify(home: Path, head: str, target: str, base: str, hist: Dict[str, Set[str]]) -> Dict[str, Any]:
    """Every path where the working tree or HEAD differs from the release (Decision 16). A path is local when its
    working-tree blob or its HEAD blob matches no version of it on the release's history; pinned when both are release copies but one is neither the merge base's
    nor the release's (an older release's copy, checked out on purpose). SOUL.md is the deployment's, never
    classified (Decision 15). An absent file is a release's state when the merge base or the release lacks it too
    (a path a later release added, or one the release deleted); a deletion of a file both have is local. Also:
    untracked files at paths the release has."""
    th, tt, tb = tree(home, head), tree(home, target), tree(home, base)
    changed = sorted(set(_names(git(home, "diff", "--name-only", "-z", "--no-renames", target)))
                     | set(_names(git(home, "diff", "--name-only", "-z", "--no-renames", head, target))))
    wt = worktree_blobs(home, changed + ([JOURNAL] if JOURNAL not in changed else []))
    local, pinned = [], []
    for p in changed:
        if p == JOURNAL:
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
    untracked = sorted(p for p in out.split("\0") if p and p in tt)
    dirty = [p for p in changed if wt.get(p, ZERO) != th.get(p, ZERO)]
    return {"head": th, "target": tt, "base": tb, "changed": changed, "wt": wt, "local": local, "pinned": pinned,
            "untracked": untracked, "dirty": dirty}


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


def _local_runs(lines: List[str], known: Set[str]) -> List[List[str]]:
    """The contiguous runs of lines no release ever had (blank lines join a run; a release's line ends it)."""
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
    for ln in lines:
        if ln.strip() and ln.rstrip() in known:
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
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, b, w, autojunk=False).get_opcodes():
        if tag == "equal":
            continue
        runs = _local_runs(w[j1:j2], known)
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
    step(git(home, "reset", "--quiet", "--hard", orig_head, timeout=600), "git reset to the original HEAD")
    if git(home, "rev-parse", "-q", "--verify", "refs/heads/" + branch)[0] == 0:
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


def migrate_and_reset(home: Path, c: Dict[str, Any], hist: Dict[str, Set[str]], head: str, target: str,
                      branch_name: str, remote: str, trunk: str) -> Tuple[str, List[str]]:
    """The local-layer migration, then the reset to the release, SOUL.md's journal written back; a failure from
    the backup to the end restores the home. Returns the clause for the one line, and the report sentences."""
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    n = 1
    while (home / BACKUPS / stamp).exists() or \
            git(home, "rev-parse", "-q", "--verify", "refs/heads/local/before-update-" + stamp)[0] == 0:
        n += 1
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-%d" % n
    branch = "local/before-update-" + stamp
    bdir_rel = (BACKUPS / stamp).as_posix()
    bdir = home / BACKUPS / stamp
    th, tt, tb = c["head"], c["target"], c["base"]

    def at(path: str, which: Dict[str, str]) -> Optional[str]:
        return blob_text(home, which.get(path, ZERO))

    def versions(path: str) -> List[str]:
        return [t for t in (blob_text(home, b) for b in sorted(hist.get(path, set()))) if t is not None]

    # what moves: read and judged before anything is written (Unmovable ends it with nothing changed)
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
    keep_soul = soul is not None and git_blob_of(home, soul) != tt.get(JOURNAL, ZERO)
    soul_release = keep_soul and tt.get(JOURNAL, ZERO) != tb.get(JOURNAL, ZERO) and JOURNAL in tt
    if c["pinned"]:
        if len(c["pinned"]) == 1:
            reports.append("%s held an older release's copy; the release's copy replaces it" % c["pinned"][0])
        else:
            reports.append("%s held older releases' copies; the release's copies replace them" % _join(c["pinned"]))
    staged = git(home, "diff", "--cached", "--quiet")[0] != 0

    moved_before_merge = False
    old = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGINT, signal.SIGTERM)}
    try:
        try:
            make_backup(home, head, branch, bdir, stamp)
            if soul_release:
                _write(bdir / "SOUL.release.md", at(JOURNAL, tt) or "")
            if local_settings is not None:
                _write(home / LOCAL_SETTINGS, json.dumps(local_settings, indent=2) + "\n")
            if brief_text is not None:
                _write(home / LOCAL_BRIEF, brief_text)
            if config_text is not None:
                _write(home / CONFIG, config_text)
            if before_path.is_file():
                shutil.move(str(before_path), str(bdir / BEFORE_MERGE.name))
                moved_before_merge = True
            _out(git(home, "reset", "--quiet", "--hard", target, timeout=600),
                 "git reset to %s/%s" % (remote, trunk))
            if keep_soul:
                (home / JOURNAL).write_bytes(soul)
            set_tracking(home, branch_name, remote, trunk)
        except (MoveFailed, OSError, Unmovable) as e:
            problems = restore(home, head, branch, bdir, moved_before_merge)
            back = ("this home is back as it was (HEAD %s, its files and its local-layer files restored%s)"
                    % (head[:7], "; changes that were staged come back unstaged" if staged else ""))
            if problems:
                back = "restoring this home also failed for %s — put those back from the backup" % "; ".join(problems)
            raise Refuse("Not updating: %s; %s; the backup is at %s and %s/." % (e, back, branch, bdir_rel))
    finally:
        for s, h in old.items():
            signal.signal(s, h)
    moved = [p for p, w in ((LOCAL_SETTINGS, local_settings), (LOCAL_BRIEF, brief_text)) if w is not None]
    where = "backup at %s and %s/" % (branch, bdir_rel)
    clause = ("local edits moved to %s, %s" % (" and ".join(moved), where)) if moved else where
    notes = []
    if config_text is not None:
        notes.append("This home had removed the CLAUDE.md deny, so boundary.edit_brief is now true in config.yaml: "
                     "Daedalus edits CLAUDE.local.md, and since config.yaml changed, each window re-runs core/gates.sh "
                     "before its next claim")
    if soul_release:
        notes.append("the release changed SOUL.md; this home's journal is kept, and the release's copy is in "
                     "%s/SOUL.release.md" % bdir_rel)
    return clause, notes + reports


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
    A script read from a pipe (python3 /dev/stdin, python3 <(...)) cannot re-read its own text, so it is never
    taken for the release's."""
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


def finish(home: Path, head: str, done: str = "", notes: Optional[List[str]] = None) -> Tuple[str, int]:
    """The upgrade, then doctor, as the tail of the one line, and the exit code. `done` is said after head when
    the upgrade finished; `notes` (what the move reports) follow, one sentence each."""
    stop = run_upgrade(home)
    if stop:
        line, code = "%s; the upgrade stopped: %s" % (head, stop), 2
    else:
        head += done
        missing = run_doctor(home)
        if missing:
            line, code = "%s; doctor names what needs attention: %s" % (head, " ".join(_sentence(m) for m in missing)), 2
        else:
            line, code = head + "; doctor OK.", 0
    if notes:
        line = _sentence(line) + " " + " ".join(_sentence(n[:1].upper() + n[1:]) for n in notes)
    return line, code


# --- the verbs -----------------------------------------------------------------------------------------------------

def update(home: Path, handed_off: bool = False, lock_fd: Optional[int] = None) -> int:
    fd = take_lock(home, lock_fd)
    if fd is None:
        print("Not updating: another daedalus update is running in this home. " + NOTHING)
        return 1
    try:
        line, code = _update(home, fd, handed_off)
    except Refuse as e:
        line, code = str(e), 1
    finally:
        os.close(fd)
    if line is not None:
        print(line)
    return code


def _update(home: Path, fd: int, handed_off: bool) -> Tuple[Optional[str], int]:
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
    if not handed_off and not running_release_copy(home, ref):
        child = hand_off(home, ref, "update", fd)
        if child is not None:
            return None, child      # the release's copy said its own one line
    target = git(home, "rev-parse", "--verify", ref + "^{commit}")[1].strip()
    head = git(home, "rev-parse", "--verify", "HEAD")[1].strip()
    if not target or not head:
        raise Refuse("Not updating: %s/%s or HEAD does not name a commit; %s" % (remote, trunk, fetched))
    stuck = in_progress(home)
    if stuck:
        raise Refuse("Not updating: %s, then run daedalus update again; %s" % (stuck, fetched))
    try:
        hist = history(home, target)
        base = git(home, "merge-base", head, target)[1].strip()
        c = classify(home, head, target, base, hist)
    except Unmovable as e:
        raise Refuse("Not updating: %s; %s" % (e, fetched))
    if c["untracked"]:
        one = len(c["untracked"]) == 1
        raise Refuse("Not updating: %s %s untracked here and the release adds %s; move %s aside, then run daedalus "
                     "update again; %s" % (_join(c["untracked"]), "is" if one else "are", "it" if one else "them",
                                           "it" if one else "them", fetched))
    outside = [p for p in c["local"] if p not in MIGRATABLE]
    if outside:
        raise Refuse("Not updating: %s carr%s local changes daedalus update cannot move (it moves only CLAUDE.md and "
                     ".claude/settings.json, and keeps SOUL.md); keep a copy elsewhere and undo them with git, then "
                     "run daedalus update again; %s" % (_join(outside), "ies" if len(outside) == 1 else "y", fetched))
    others = [p for p in c["changed"] if p != JOURNAL]
    ver = home_version(home) or "unknown"
    if head == target and not others:
        if _stamp(home) == ver:
            return "Daedalus is up to date (%s)." % ver, 0
        # up to date, but an earlier upgrade stopped: run it now, so a second run finishes it
        return finish(home, "Daedalus is up to date (%s)" % ver, done="; the upgrade finished")
    ancestor = git(home, "merge-base", "--is-ancestor", head, target)[0] == 0
    soul_dirty = c["wt"].get(JOURNAL, ZERO) != c["head"].get(JOURNAL, ZERO)
    soul_moves = c["head"].get(JOURNAL, ZERO) != c["target"].get(JOURNAL, ZERO)
    refuse_if_live(home, tail=fetched[0].upper() + fetched[1:])
    old = ver if ver != "unknown" else head[:7]
    notes: List[str] = []
    if ancestor and not [p for p in c["dirty"] if p != JOURNAL] and not (soul_dirty and soul_moves):
        code, msg = fast_forward(home, target)
        if code != 0:
            raise Refuse("Not updating: git could not fast-forward to %s/%s (%s); %s"
                         % (remote, trunk, _last(msg), fetched))
        set_tracking(home, branch, remote, trunk)
        clause = ""
    else:
        try:
            clause, notes = migrate_and_reset(home, c, hist, head, target, branch, remote, trunk)
        except Unmovable as e:
            raise Refuse("Not updating: %s; %s" % (e, fetched))
        clause = "; " + clause
    auto = auto_mode_note(home)
    if auto:
        notes.append(auto)
    new = home_version(home) or target[:7]
    if head == target:
        line = "Daedalus is up to date (%s)" % new
    else:
        line = "Daedalus updated %s -> %s" % (old, new if new != old else "%s (%s)" % (new, target[:7]))
    return finish(home, line + clause, notes=notes)


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
    if home_arg is None or len(args) != 1 or args[0] not in ("update", "version") or not os.path.isabs(home_arg):
        sys.stderr.write(USAGE + "\n")
        return 2
    home = Path(home_arg).resolve()
    if not (home / ".git").exists() or not (home / "core").is_dir():
        print("%s is not a Daedalus home (no .git or core/ there). %s" % (home, NOTHING))
        return 1
    if args[0] == "version":
        return version(home)
    return update(home, handed_off, lock_fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
