#!/usr/bin/env python3
"""The self-upgrade (spec §14): what a pull of a new release needs done to this home, done by itself.

Daedalus updates by pulling its own home. At the next SessionStart, session-start.py compares VERSION with
state/upgraded-to and, when they differ, runs this before anything else (step 0 of the binding order). Each
step is idempotent — the second run changes nothing — and says one line the first time it acts:

  1. the window directories: state/leases, worktrees, state/promote, state/direct-calls
  2. the pre-push hook in Daedalus's own checkout of each target repo (target/<repo>), never anywhere else
  3. the old shared reminder files (state/pitfall-seen.json, state/code-context-seen.json) removed
  4. vault/hot.md's `session:` line renamed `leases:` once, left uncommitted for the prime
  5. capture's settings moved from the hook line in .claude/settings.local.json into config.yaml's memory:
     block, the key into state/hindsight/api-key (mode 600); the old line is left and still works
  6. target/ back on its trunk. Unfinished work in any target repo (outer or nested) stops the upgrade first —
     before step 2, the first step that changes anything under target/, and after the safety copy — in one
     sentence naming what it found (the operator's decision of 2026-10-07, spec Appendix E): a local branch with
     commits origin/<trunk> has no equivalent of (git cherry, a merge carrying content, a squash merge; not one a
     window holds, nor one whose branch on origin was deleted, which usually means it was merged), the trunk ahead
     of origin, a detached HEAD with commits no branch has, uncommitted changes (hidden ones included), untracked
     files that are not ignored, stash entries, a rebase, merge, cherry-pick, revert or bisect in progress, and a
     linked worktree that is not a window's. Nothing is moved: the operator says "pick it up", which runs
     core/lease.sh adopt --all-unfinished (pick_up), or finishes and ships it the usual way, and the next session
     start finishes the upgrade. With none, after one bounded fetch of every target repo (plan 5 Decision 3), a
     checkout on a branch whose work is already on origin/<trunk>, on a window's branch, or detached at commits a
     branch holds goes back on its trunk, the branch left as it was; the trunk is fast-forwarded. Lock files a
     cut-off git left, a checkout on a branch that is gone, branch names that differ only in case, a local branch
     named origin/<trunk>, and an untracked or ignored file where the checkout back to the trunk would write each
     stop too, naming what to do; a checkout or reset `lease.sh adopt` began and was cut off is finished.
  7. the daedalus command: this home registered in ~/.config/daedalus/homes.json and ~/.local/bin/daedalus, one
     shim for every home (core/update.py --install-shim's rules — never over a file it did not write nor over a
     newer release's shim; an old single-home shim is rewritten, the home it served registered too), and how to
     reach it from the login shell; it never stops the upgrade (update-command design §4.7, daedalus-start §4)
  8. a config.yaml naming its one callee in the legacy direct_call keys is told, once, its callee key (SPEC-011 §4);
     config.yaml is read, never written
  9. the service-status mod, installed at local scope beside the lease board for a deployment that has the board
     there (`claude plugin install service-status@daedalus-mods --scope local`); never stops the upgrade (service-
     status spec §4)
 10. each Daedalus mod already installed at local scope for this home, enabled there, and older in Claude Code's
     installed_plugins.json than mods/<name>/.claude-plugin/plugin.json, updated (`claude plugin update
     <name>@daedalus-mods --scope local`): a window loads the plugin cache's copy, not mods/; never stops the upgrade.
     FULL = len(STEPS) is the whole run
 11. the stamp, state/upgraded-to, written last: a stopped upgrade runs again from the top next time

Before step 2, the first that can touch target/, every run takes a safety copy of everything in target/ into
state/upgrade-snapshot/<stamp>/ and checks it, or stops before changing anything (see "the safety copy" below):
the upgrade is recoverable by construction, whatever shape of work target/ holds. A copy too big for a session
start's share of time is taken, and the upgrade finished, by a detached run logged to state/upgrade.log. The
board names the copy until --forget-snapshot removes it; nothing else ever does.

    python3 core/upgrade.py                    every step now, as a session start would
    python3 core/upgrade.py --dry-run          what each step would do; changes nothing, fetches nothing
    python3 core/upgrade.py --setup            steps 1-3 (setup.sh's leases phase, spec §15); never stamps
    python3 core/upgrade.py --progress         (with a run) a line on stderr about every 10 s while the safety
                                               copy is written: "safety copy: N of M MB"
    python3 core/upgrade.py --doctor           doctor's upgrade lines (§15)
    python3 core/upgrade.py --doctor-mods      doctor's line for each mod installed here older than mods/ ships
    python3 core/upgrade.py --restore-help     what a safety copy holds that target/ no longer has, and the
                                               commands that bring each back
    python3 core/upgrade.py --forget-snapshot  removes the safety copies, only when nothing in them is missing
    python3 core/upgrade.py --rollback [--dry-run] [--force]
                                               back to where v0.6.1 runs as before (refused while a session is
                                               live, without --force); prints the git checkout that puts the code
                                               back, which it never runs itself

Python 3.9, standard library.
"""
from __future__ import annotations

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
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

STAMP = Path("state") / "upgraded-to"
CONFIG_CHANGES = Path("state") / "config-changes.json"
LOCK_AGE = 5             # seconds: a git lock file younger than this may belong to a command running now
CARRY_CHUNK = 1 << 20    # bytes copied between two looks at the deadline
STOPPED = Path("state") / "upgrade-stopped.json"
LOCK = Path("state") / ".upgrade.lock"
DIRS = (("state/leases", 0o755), ("worktrees", 0o755), ("state/promote", 0o700), ("state/direct-calls", 0o700))
OLD_DEDUP = ("state/pitfall-seen.json", "state/code-context-seen.json")
HOT_LEASES = "leases: (see the board; prime's copy at its last write)"
KEY_FILE = "state/hindsight/api-key"
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
PREFIX_RE = re.compile(r"[A-Z_][A-Z0-9_]*=")
KEY_CAT_RE = re.compile(r"\$\(cat\s+([^\s()$`\"']+)\)")
# a window's branch; never lease/00, a number no window has — a branch of that name is the operator's own and is
# adopted or named like any other (release-candidate review 3, finding 4)
LEASE_BRANCH = re.compile(r"lease/(?!00)[0-9]{2}")
FIELDS = (("TENANT_BANK", "bank"), ("HINDSIGHT_API_URL", "api_url"), ("TRANSCRIPT_DIR", "transcript_dir"),
          ("TENANT_USER_LABEL", "user_label"), ("TENANT_ASSISTANT_LABEL", "assistant_label"))
FETCH_SECS = 4          # one cap for every target repo's fetch together, never over half the deadline left
PICKED_NOTE = "picked up at the upgrade to %s"
# The operator's decision of 2026-10-07 (spec Appendix E): unfinished work in target/ stops the upgrade before it
# changes anything there, in one sentence naming it; the operator says "pick it up" (core/lease.sh adopt
# --all-unfinished), and the next session start finishes the upgrade. "Finish and ship it the usual way" is gone
# from it (update-command Decision 10's rule): shipping needs a window, and none opens until the upgrade finishes.
UNFINISHED = ("Daedalus has unfinished work in %s. Nothing was changed. Say 'pick it up' to move it into windows, "
              "then start a new session.")
MOST_ITEMS = 5          # things the sentence names before "and N more"
UNTRACKED = ("upgrade to %s incomplete: target/%s has untracked files that %s would overwrite (%s) — move them out "
             "of that checkout, or commit them on its branch, then start a session again")
# A gitlink whose directory holds a repository of its own, or files with no .git (a submodule vendored by removing its
# .git), where the trunk has a file: git looks into neither, and the checkout back to the trunk deleted the directory
# with everything in it (release-candidate red team 3, findings 1 and 3).
GITLINK = ("upgrade to %s incomplete: target/%s holds %s (%s), which %s would delete with everything in it — move %s out "
           "of that checkout, then start a session again")
# A local branch named origin/<trunk> shadows the remote-tracking ref in every bare "origin/<trunk>" git is given
# (release-candidate review 2, finding 5): stopped on before anything moves.
SHADOW = ("upgrade to %s incomplete: target/%s has a local branch named origin/%s, which git takes for origin's %s — "
          "rename it (git -C target/%s branch -m origin/%s <new name>), then start a session again")
STOPPED_WHILE = ("upgrade to %s incomplete: stopped while %s — %s; it tries again at the next session start — if it "
                 "stops the same way again, ask this home's agent to look into the reason given")
STOPPED_TIME = ("upgrade to %s incomplete: stopped while %s — the session start ran out of time; it runs again at the next "
                "session start — if it stops this way at every start, run python3 core/upgrade.py once from a terminal "
                "in this home, which has no time limit")
# A git command cut off part-way leaves lock files git then refuses on, or a checkout on a branch that no longer exists
# (a rename stopped between its two ref writes): stopped on, naming them, before anything moves — never "commit them",
# which would commit the whole tree as a new root (release-candidate review 3, finding 9).
LOCKS_LEFT = ("upgrade to %s incomplete: target/%s holds lock files a git command left when it was cut off (%s) — if no "
              "git command is running there, remove them (rm %s), then start a session again")
UNBORN = ("upgrade to %s incomplete: target/%s is on branch %s, which does not exist — a git command was cut off "
          "part-way; the branch's last commit is %s (from HEAD's reflog). Put the branch back with git -C target/%s "
          "branch %s %s, then start a session again — do not commit in that checkout before then")
# Two branch names that differ only in case: git reads one for the other where it ignores case, and the adoption
# deleted the commit of one (release-candidate review 4, finding 1). Stopped on before anything moves.
TWINS = ("upgrade to %s incomplete: target/%s has branches whose names differ only in case (%s), which this filesystem "
         "cannot keep apart — git reads one in place of the other. Give one a new name (git -C target/%s pack-refs "
         "--all, then git -C target/%s branch -m %s <new name>), then start a session again")
# A checkout or hard reset this upgrade began, cut off part-way, leaves the tree half switched and reading as
# uncommitted changes; "commit them" there put the same commit in a second window (release-candidate review 4,
# findings 5-6). Recognized and finished; anything else in the tree is named, never committed.
CUT_WAIT = ("upgrade to %s incomplete: a git command Daedalus ran in target/%s (%s) was cut off part-way, or is still "
            "running%s; window %s already holds its commit %s — do not commit anything there; the next session start "
            "finishes it")
CUT_OTHER = ("upgrade to %s incomplete: a git command Daedalus ran in target/%s (%s) was cut off part-way; window %s "
             "already holds its commit %s. Files there match neither that commit nor %s (%s) — if any of them is work, "
             "copy it into worktrees/%s/%s; then run git -C target/%s %s and start a session again. Do not commit "
             "them there")


class Stop(Exception):
    """The upgrade cannot go on; str(e) is the one sentence the board repeats until a later run finishes."""


def version(root: Path) -> Optional[str]:
    try:
        first = (root / "VERSION").read_text().split("\n", 1)[0].strip()
    except OSError:
        return None
    return first if VERSION_RE.fullmatch(first) else None


def stamped(root: Path) -> Optional[str]:
    try:
        return (root / STAMP).read_text().strip() or None
    except OSError:
        return None


def pending(root: Path) -> bool:
    ver = version(root)
    return ver is not None and stamped(root) != ver


def _git(repo: Path, *args: str) -> Tuple[int, str, str]:
    # submodule.recurse off: set, a checkout, merge or reset here rewrote each submodule's working tree over its
    # uncommitted edits (release-candidate red team 2, finding 1); core.fsmonitor off: a monitor hook that reports no
    # change hid an edit from every check here (red team 3, finding 2) — leaselib.NO_RECURSE
    import leaselib as ll
    return v.run(ll.git_argv(repo, *args))


def _last(err: str) -> str:
    import leaselib as ll
    return ll.git_reason(err)


def _write(path: Path, text: str, mode: Optional[int] = None) -> None:
    tmp = path.with_name(path.name + ".upgrade-tmp")
    tmp.write_text(text)
    if mode is not None:
        os.chmod(str(tmp), mode)
    elif path.exists():
        os.chmod(str(tmp), path.stat().st_mode & 0o777)
    os.replace(str(tmp), str(path))


def record_config_change(root: Path, before: str, after: str, by: str) -> None:
    """Record that <by> (the upgrade, never a session) rewrote config.yaml from sha256 <before> to <after>, so the
    boundary hook of a session open through the release reads that change as the release's own and does not tell
    its agent to restore the file (critic finding 7). The last 20 kept."""
    p = root / CONFIG_CHANGES
    try:
        d = json.loads(p.read_text())
        changes = d.get("changes") if isinstance(d, dict) and isinstance(d.get("changes"), list) else []
    except (OSError, ValueError):
        changes = []
    changes.append({"from": before, "to": after, "by": by, "version": version(root),
                    "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "at_epoch": time.time()})
    p.parent.mkdir(parents=True, exist_ok=True)
    _write(p, json.dumps({"changes": changes[-20:]}, indent=2) + "\n")


def _plural(n: int, word: str) -> str:
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def _quoted(subjects: List[str]) -> str:
    return ", ".join('"%s"' % s for s in subjects)


# --- the steps (each: root, head, dry, deadline -> lines; raise Stop to stop) -----------------------------

def step_dirs(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    made = []
    for rel, mode in DIRS:
        p = root / rel
        if p.is_dir():
            continue
        made.append(rel + "/")
        if not dry:
            p.mkdir(parents=True, exist_ok=True)
            os.chmod(str(p), mode)
    return ["%s: %s %s." % (head, "would create" if dry else "created", ", ".join(made))] if made else []


def target_repos(root: Path) -> List[Tuple[str, Path]]:
    """(key, path) of target/<name> and each nested repo that is a checkout's root; [] before the target was
    synced (nothing to guard or adopt yet) or when config names no target."""
    import leaselib as ll
    try:
        keys = ll.repos_of(root)
    except ll.Refused:
        return []
    out = []
    for key in keys:
        p = root / "target" / key
        code, top, _ = _git(p, "rev-parse", "--show-toplevel")
        if p.is_dir() and code == 0 and Path(top.strip()).resolve() == p.resolve():
            out.append((key, p))
    return out


def step_hooks(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    import prepush
    done, other, kept = [], [], []
    for key, p in target_repos(root):
        s, _ = prepush.state(p)
        if s == "installed":
            continue
        if dry:
            if s in ("missing", "differs", "noexec"):
                done.append("target/" + key)
            else:
                other.append("target/%s has a hook setting Daedalus will not change (%s)" % (key, s))
            continue
        try:
            s2, sentence = prepush.install(p)
        except (OSError, ValueError) as e:
            s2, sentence = "failed", "the pre-push hook could not be installed in target/%s (%s)" % (key, e)
        if s2 == "installed":
            done.append("target/" + key)
            if "is kept as" in sentence:        # a hook with lines of the operator's own, kept beside the new one
                kept.append("target/%s's pre-push hook had lines of its own, which no longer run before a push; "
                            "it is kept, unchanged, as %s" % (key, sentence.rsplit("is kept as ", 1)[1].rstrip(".")))
        elif s2 != "unchanged":
            other.append(sentence.rstrip("."))
    lines = ["%s: %s the pre-push hook in %s." % (head, "would install" if dry else "installed", ", ".join(done))] \
        if done else []
    lines += ["%s: %s." % (head, k) for k in kept]
    return lines + ["%s: %s — promote refuses until it is fixed; core/doctor.sh names the remedy." % (head, o)
                    for o in other]


def step_dedup(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    gone = [rel for rel in OLD_DEDUP if (root / rel).is_file()]
    if not gone:
        return []
    if not dry:
        for rel in gone:
            (root / rel).unlink()
    return ["%s: %s the old shared %s (each session keeps its own now)."
            % (head, "would remove" if dry else "removed", " and ".join(gone))]


def _hot_session_line(lines: List[str]) -> Optional[int]:
    """The index of the frontmatter's `session:` line when the frontmatter has no `leases:`; else None."""
    if not lines or lines[0].strip() != "---":
        return None
    end = next((i for i in range(1, len(lines)) if lines[i].strip() == "---"), None)
    if end is None or any(ln.startswith("leases:") for ln in lines[1:end]):
        return None
    return next((i for i in range(1, end) if lines[i].startswith("session:")), None)


def step_hot(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    p = root / "vault" / "hot.md"
    try:
        lines = p.read_text().split("\n")
    except OSError:
        return []
    i = _hot_session_line(lines)
    if i is None:
        return []
    if not dry:
        lines[i] = HOT_LEASES
        _write(p, "\n".join(lines))
    return ["%s: %s vault/hot.md's session: line to leases: (left uncommitted for the prime's next vault commit)."
            % (head, "would rename" if dry else "renamed")]


def _hook_prefixes(root: Path) -> Optional[Dict[str, str]]:
    """The VAR=value words leading the settings.local.json hook command that runs capture.py with TENANT_BANK
    (else the first command with TENANT_BANK), walked as JSON the way doctor.sh does; None when there is none."""
    try:
        d = json.loads((root / ".claude" / "settings.local.json").read_text())
    except (OSError, ValueError):
        return None
    hooks = d.get("hooks") if isinstance(d, dict) else None
    cmds = []
    for groups in (hooks.values() if isinstance(hooks, dict) else []):
        for g in (groups if isinstance(groups, list) else []):
            for h in ((g.get("hooks") or []) if isinstance(g, dict) else []):
                c = h.get("command") if isinstance(h, dict) else None
                if isinstance(c, str) and "TENANT_BANK=" in c:
                    cmds.append(c)
    cmds.sort(key=lambda c: "capture.py" not in c)
    for c in cmds:
        try:
            words = shlex.split(c)
        except ValueError:
            continue
        out: Dict[str, str] = {}
        for w in words:
            if not PREFIX_RE.match(w):
                break
            k, val = w.split("=", 1)
            out[k] = val
        if out.get("TENANT_BANK"):
            return out
    return None


def _yaml(val: str) -> Optional[str]:
    """A value cfg reads back exactly (it strips one quote at each end); None when it cannot be written so."""
    if "\n" in val or "\r" in val:
        return None
    if "'" not in val:
        return "'%s'" % val
    if '"' not in val:
        return '"%s"' % val
    return None


def step_memory(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    cfgp = root / "config.yaml"
    try:
        text = cfgp.read_text()
    except OSError:
        return []
    if any(ln.startswith("memory:") for ln in text.splitlines()):
        return []
    pre = _hook_prefixes(root)
    if not pre:
        return []
    nomove = "%s: capture's settings were not moved into config.yaml — %s; capture keeps running from that line."
    fields = []
    for var, key in FIELDS:
        val = pre.get(var)
        if not val:
            continue
        if "$" in val or "`" in val:
            return [nomove % (head, "%s on the old hook line is computed by the shell, not written out" % var)]
        q = _yaml(val)
        if q is None:
            return [nomove % (head, "%s on the old hook line holds both kinds of quote or a line break" % var)]
        fields.append((key, q))
    raw, key_val = pre.get("HINDSIGHT_API_TENANT_API_KEY"), None
    if raw:
        m = KEY_CAT_RE.fullmatch(raw)
        if m:
            src = Path(os.path.expanduser(m.group(1)))
            try:
                key_val = src.read_text().split("\n", 1)[0].strip()
            except OSError:
                return [nomove % (head, "the key on the old hook line is read from %s, which cannot be read" % src)]
            if not key_val:
                return [nomove % (head, "the key on the old hook line is read from %s, which is empty" % src)]
        elif any(ch in raw for ch in "$`\\\"' "):
            return [nomove % (head, "HINDSIGHT_API_TENANT_API_KEY on the old hook line is computed by the shell, "
                                    "not written out")]
        else:
            key_val = raw
    bank = pre["TENANT_BANK"]
    if dry:
        return ["%s: would move capture's settings from the hook line in .claude/settings.local.json into "
                "config.yaml's memory: block (bank %s%s)." % (head, bank, "; the key into " + KEY_FILE if key_val else "")]
    if key_val:
        kp = root / KEY_FILE
        kp.parent.mkdir(parents=True, exist_ok=True)
        _write(kp, key_val + "\n", mode=0o600)
    block = ["memory:", "  # moved here from .claude/settings.local.json by the upgrade to %s" % version(root)]
    block += ["  %s: %s" % (k, q) for k, q in fields]
    if key_val:
        block.append("  api_key_file: %s" % KEY_FILE)
    before = v.sha256_file(cfgp)
    _write(cfgp, text + ("" if text.endswith("\n") or not text else "\n") + "\n" + "\n".join(block) + "\n")
    record_config_change(root, before, v.sha256_file(cfgp), "the upgrade to %s" % version(root))
    return ["%s: moved capture's settings from the hook line in .claude/settings.local.json into config.yaml's "
            "memory: block (bank %s%s). The old line still works and can be removed; sessions opened before this "
            "upgrade should be closed and reopened." % (head, bank, "; the key is in %s, mode 600" % KEY_FILE
                                                        if key_val else "")]


def _fetch_all(repos: List[Tuple[str, Path]], deadline: Optional[float]) -> Set[str]:
    """`git fetch --quiet origin` in every target repo at once (leaselib.fetch_args: no tag is fetched or pruned),
    all under one cap (plan 5 Decision 3): FETCH_SECS, and never more than half of what is left of `deadline`, so adoption's worktree adds keep the
    rest. Each fetch runs in its own process group, which is killed if it is still running at the cap or if
    this process is interrupted. GIT_TERMINAL_PROMPT=0: a remote that wants a password fails at once instead of
    waiting on a prompt nobody sees. Returns the keys of the repos whose fetch finished with exit 0."""
    cap = float(FETCH_SECS)
    if deadline is not None:
        cap = min(cap, (deadline - time.time()) / 2)
    if cap < 0.5:
        return set()
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    procs: Dict[str, subprocess.Popen] = {}
    done: Set[str] = set()
    try:
        import leaselib as ll
        for key, p in repos:
            try:
                # only origin's remote-tracking branches change: never a tag, whatever fetch.pruneTags says
                # (release-candidate red team 2, finding 2)
                procs[key] = subprocess.Popen(ll.git_argv(p, *ll.fetch_args(p)),
                                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                              stderr=subprocess.DEVNULL, env=env, start_new_session=True)
            except OSError:
                pass
        end = time.time() + cap
        for key, pr in procs.items():
            try:
                if pr.wait(timeout=max(0.0, end - time.time())) == 0:
                    done.add(key)
            except subprocess.TimeoutExpired:
                pass
    finally:
        for pr in procs.values():
            if pr.poll() is None:
                try:
                    os.killpg(pr.pid, signal.SIGKILL)
                except OSError:
                    pass
                pr.wait()
    return done


def _q(rev: str) -> str:
    """A branch name as its exact ref, refs/heads/<b>: a bare name is a tag's when a tag has it too (release-candidate
    review 4, finding 2). HEAD, a full ref and a commit id pass as they are."""
    return rev if rev == "HEAD" or rev.startswith("refs/") or re.fullmatch(r"[0-9a-f]{40}([0-9a-f]{24})?", rev) else \
        "refs/heads/" + rev


def _origin(trunk: str) -> str:
    """origin/<trunk> as a revision a local branch of that name cannot shadow (release-candidate review 2, 5)."""
    return "refs/remotes/origin/" + trunk


def _ahead(p: Path, trunk: str) -> List[str]:
    """Subjects, oldest first, of the commits on the local trunk that origin/<trunk> lacks."""
    _, out, _ = _git(p, "log", "--reverse", "--format=%s", "%s..refs/heads/%s" % (_origin(trunk), trunk))
    return [s for s in out.splitlines() if s.strip()]


def _back_on_trunk(p: Path, key: str, trunk: str) -> None:
    import leaselib as ll
    code, _, err = ll.git_finish(p, "checkout", "--quiet", trunk)
    if code != 0:
        raise Stop("could not put target/%s back on %s (%s)" % (key, trunk, _last(err)))
    _git(p, "merge", "--ff-only", "--quiet", _origin(trunk))


# A window adopted from target/ whose worktree is not made: the stamp waits for it, since only the upgrade finishes it
# (release-candidate red team, finding 1).
_NO_WORKTREE = STOPPED_WHILE % ("%s", "finishing the windows picked up from target/",
                                "window %s (adopted from %s) has no worktree yet")


def _unfinished_windows(root: Path) -> List[Tuple[str, str]]:
    """(NN, what it was adopted from) for each window adopted from target/ with no session whose worktree was never
    made, its lease/<NN> still there — what finish_adopted finishes at the next run."""
    import leaselib as ll
    out, keys = [], {key for key, _ in target_repos(root)}     # the repos step 6 runs finish_adopted on
    for nn, d in sorted(ll.read_all(root).items()):
        if (nn == "prime" or d.get("adopted_repo") not in keys or d.get("worktree_ready") is not False
                or d.get("session_id")):
            continue
        src = root / "target" / str(d["adopted_repo"])
        if _git(src, "rev-parse", "--verify", "-q", "refs/heads/lease/" + nn)[0] == 0:
            out.append((nn, str(d.get("adopted_from") or "")))
    return out


def _carried_by(root: Path, p: Path, key: str, trunk: str) -> Optional[str]:
    """The number of a window adopted from target/<key> whose lease/<NN> already holds the trunk's tip — made by
    an earlier run cut off before the trunk was reset (review finding 1). None when no window does."""
    import leaselib as ll
    for nn, d in sorted(ll.read_all(root).items()):
        if nn == "prime" or d.get("adopted_repo") != key:
            continue
        ref = "refs/heads/lease/" + nn
        if (_git(p, "rev-parse", "--verify", "-q", ref)[0] == 0
                and _git(p, "merge-base", "--is-ancestor", _q(trunk), ref)[0] == 0):
            return nn
    return None


# The trunk's reset "pick it up" or step 6 runs when a window holds the trunk's commits: marked here, {repo: the commit
# the trunk was on}, before git starts and cleared once it finishes, so that only a reset Daedalus really began is ever
# finished as cut off — never an ordinary edit on a trunk a window holds (review of option 1, finding 1).
TRUNK_RESET = Path("state") / "upgrade-trunk-reset.json"


def _reset_marks(root: Path) -> Dict[str, str]:
    try:
        d = json.loads((root / TRUNK_RESET).read_text())
    except (OSError, ValueError):
        return {}
    return {str(k): str(v) for k, v in d.items()} if isinstance(d, dict) else {}


def _reset_mark(root: Path, key: str, sha: Optional[str]) -> None:
    """Record (sha) or clear (None) the trunk reset Daedalus began in target/<key>."""
    marks = _reset_marks(root)
    if sha:
        marks[key] = sha
    elif key in marks:
        del marks[key]
    else:
        return
    path = root / TRUNK_RESET
    if marks:
        path.parent.mkdir(parents=True, exist_ok=True)
        _write(path, json.dumps(marks, indent=1, sort_keys=True) + "\n")
    else:
        try:
            path.unlink()
        except OSError:
            pass


def _reset_trunk(root: Path, p: Path, key: str, trunk: str) -> Tuple[int, str]:
    """Put <trunk> at origin/<trunk> (a window holds its commits), marked while it runs: (git's exit code, its stderr).
    The mark stays when git fails or is still running, so the next start or "pick it up" finishes it."""
    import leaselib as ll
    _, now, _ = _git(p, "branch", "--show-current")
    now = now.strip()
    if now == trunk:
        _reset_mark(root, key, ll.ref_oid(p, "refs/heads/" + trunk))
    code, _, err = ll.git_finish(p, *ll._trunk_reset(now, trunk))
    if code == 0:
        _reset_mark(root, key, None)
    return code, err


def _in_the_way(p: Path, key: str, trunk: str, cur: str, ver: str) -> None:
    """Stop, before anything in target/ moves, when an untracked file is where the move back to the trunk or the
    trunk's reset would write (review finding 3): git refuses the checkout over it on every run, and a reset
    deletes it silently — and an ignored one, which a checkout, a reset and a fast-forward all write over
    without a word (release-candidate review 2, findings 1-2). Checked after the fetch, against origin/<trunk>
    as the run will see it."""
    import leaselib as ll
    ignored_only = False
    if cur != trunk:
        refs, doing = ["refs/heads/" + trunk, _origin(trunk)], "putting it back on %s" % trunk
    elif _ahead(p, trunk):
        refs, doing = [_origin(trunk)], "resetting %s to origin/%s" % (trunk, trunk)
    else:
        # the trunk's fast-forward refuses over an untracked file, which is then left as it was; it writes over
        # an ignored one (release-candidate review 2, finding 1)
        refs, doing, ignored_only = [_origin(trunk)], "fast-forwarding %s to origin/%s" % (trunk, trunk), True
    # a directory recorded as a submodule, holding a repository or files git never looks into, where the trunk has a
    # file: the checkout deletes it whole without a word (release-candidate red team 3, findings 1 and 3)
    links = ll.gitlinks_in_way(p, refs)
    if links:
        what, names, it = ll.gitlink_words(links)
        raise Stop(GITLINK % (ver, key, what, names, doing, it))
    hit = ll.untracked_in_way(p, refs, ignored_only=ignored_only)
    if hit:
        raise Stop(UNTRACKED % (ver, key, doing, ll.name_paths(hit)))


def _stash_entries(p: Path) -> List[str]:
    """`stash@{N}: <subject>` for each entry of <p>'s stash list, newest first; [] when it has none."""
    code, out, _ = _git(p, "stash", "list", "--format=%gd: %gs")
    return [ln for ln in out.splitlines() if ln.strip()] if code == 0 else []


def _stash_words(entries: List[str]) -> Tuple[str, str]:
    n = len(entries)
    return "%d stash %s" % (n, "entry" if n == 1 else "entries"), \
        "; ".join(entries[:3]) + (" and %d more" % (len(entries) - 3) if len(entries) > 3 else "")


def _carried(p: Path, ref: str, extra: List[str]) -> bool:
    """Is every commit of <ref> already on a window's branch in <p> (any lease/<NN>) or on one of <extra>?"""
    _, out, _ = _git(p, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/lease/")
    for c in [b for b in out.split() if LEASE_BRANCH.fullmatch(b)] + extra:
        if c and c != ref and _git(p, "merge-base", "--is-ancestor", _q(ref), _q(c))[0] == 0:
            return True
    return False


def _checked_out_elsewhere(p: Path) -> Dict[str, str]:
    """{branch: path} for each branch checked out in a worktree of <p> other than <p> itself — one someone made by
    hand with `git worktree add`, or a window's. Such a branch cannot be checked out in a window's worktree: git
    refuses ("already used by worktree"), so adopting it fails on every run (release-candidate review, finding 1).
    A branch another worktree is rebasing or bisecting (its HEAD detached meanwhile) counts too, as git counts it:
    adopting it moved the branch out from under the rebase (safety-copy review 4, finding 1)."""
    import leaselib as ll
    code, out, _ = _git(p, "worktree", "list", "--porcelain")
    if code != 0:
        return {}
    here = os.path.realpath(str(p))
    records = ll.worktree_records(p)
    found, path = {}, None
    for ln in out.splitlines() + [""]:
        if ln.startswith("worktree "):
            path = ln[len("worktree "):]
        elif ln.startswith("branch refs/heads/") and path is not None:
            if os.path.realpath(path) != here:
                found[ln[len("branch refs/heads/"):]] = path
        elif ln == "detached" and path is not None and os.path.realpath(path) != here:
            b = ll.branch_in_use(records[os.path.realpath(path)]) if os.path.realpath(path) in records else None
            if b:
                found.setdefault(b, path)
        elif not ln:
            path = None
    return found


SQUASH_LOOK = 50    # commits of origin/<trunk>, newest first, _squashed tries as the one a branch was squashed into


def _merges_to_nothing(p: Path, at: str, b: str) -> bool:
    """Would merging <b> into <at> change nothing — `git merge-tree --write-tree` (git 2.38+) giving <at>'s own tree?
    No when the merge conflicts, or the git here cannot say."""
    code, out, _ = _git(p, "merge-tree", "--write-tree", at, _q(b))
    if code != 0 or not out.strip():
        return False
    _, tree, _ = _git(p, "rev-parse", "%s^{tree}" % at)
    return out.split()[0] == tree.strip()


def _squashed(p: Path, trunk: str, b: str) -> bool:
    """Is <b>'s change already on origin/<trunk> although git cherry finds no equal commit — a squash merge, the
    usual way a branch reaches a GitHub trunk (release-candidate review, finding 3)? Yes when merging <b> into
    origin/<trunk> would change nothing; or, once origin/<trunk> has changed the same lines since, when merging it
    into the commit it was squashed into would: one of origin/<trunk>'s own commits since <b> left it (first parent,
    the newest SQUASH_LOOK touching <b>'s files). A commit made on <b> after the squash is in none of them, so <b>
    then holds work — whether or not its branch on origin was deleted (review of option 1, finding 2)."""
    if _merges_to_nothing(p, _origin(trunk), b):
        return True
    code, base, _ = _git(p, "merge-base", _origin(trunk), _q(b))
    if code != 0 or not base.strip():
        return False
    code, out, _ = _git(p, "diff", "--name-only", "-z", "--no-renames", base.strip(), _q(b))
    paths = [x for x in out.split("\0") if x]
    if code != 0 or not paths:
        return False
    code, out, _ = _git(p, "rev-list", "--first-parent", "--max-count=%d" % SQUASH_LOOK, _origin(trunk),
                        "^" + base.strip(), "--", *[":(literal)" + x for x in paths])
    return code == 0 and any(_merges_to_nothing(p, c, b) for c in out.split())


def _work(p: Path, trunk: str, rev: str) -> List[str]:
    """The subjects of <rev>'s commits that origin/<trunk> has no equivalent of (git cherry, as adopt judges) —
    none when <rev>'s change as a whole is already there (a squash merge)."""
    import leaselib as ll
    work = ll.unpromoted_commits(p, trunk, _q(rev))
    return [] if work and _squashed(p, trunk, rev) else work


def _branches(p: Path, trunk: str, skip: str) -> Tuple[List[Tuple[str, List[str]]], List[Tuple[str, str, List[str]]]]:
    """The local branches of <p> other than <trunk>, <skip> (the checked-out one) and a window's lease/<NN> that
    hold commits origin/<trunk> has no equivalent of (critic finding 1), in two kinds:
      parked: (branch, subjects) — work to pick up, whether or not its branch on origin was deleted (review of
              option 1, finding 2). Most commits first, so a branch built on another is adopted before it and the
              other is then found carried, never a second copy.
      elsewhere: (branch, path, subjects) — checked out in another worktree; named, never adopted (finding 1 of
              the release-candidate review: adopting it fails every time).
    A branch whose change is already on origin/<trunk> (git cherry, or a squash merge) is neither."""
    import leaselib as ll
    # lstrip=2, never refname:short: a branch a tag shares its name with is short "heads/<b>" (review 4, finding 2)
    _, out, _ = _git(p, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/")
    held = _checked_out_elsewhere(p)
    parked, elsewhere = [], []
    for b in out.splitlines():
        if not b.strip() or b in (trunk, skip) or LEASE_BRANCH.fullmatch(b):
            continue
        try:
            work = _work(p, trunk, b)
        except ll.Refused as e:
            raise Stop("could not tell whether target branch %s holds work origin/%s lacks (%s)" % (b, trunk, e))
        if not work:
            continue
        if b in held:
            elsewhere.append((b, held[b], work))
        else:
            parked.append((b, work))
    return sorted(parked, key=lambda bw: (-len(bw[1]), bw[0])), elsewhere


def _elsewhere_words(key: str, b: str, path: str, flag: str) -> str:
    return ("is checked out in another worktree, at %s, so it was not made a window — once its work there is "
            "committed, remove that worktree (git -C target/%s worktree remove %s) and run core/lease.sh adopt %s%s"
            % (path, key, path, b, flag))


def _nested_rels(key: str, keys: List[str]) -> List[str]:
    """The configured nested repos under target/<key>, as paths from its root."""
    return [k[len(key) + 1:] for k in keys if k.startswith(key + "/")]


def _beside_nested(p: Path, paths: List[str], nested: List[str]) -> List[str]:
    """<paths> (from target/<key>'s root; a directory ends in "/") without every configured nested repo and anything
    under it. A directory entry that holds one — git names a wholly ignored agents/ as one entry when the nested repo
    is agents/<name> — is opened up to what else it holds, so the nested repo is never named as a file of the outer
    one, and nothing beside it goes unnamed."""
    out: List[str] = []
    for u in paths:
        d = u.rstrip("/")
        if any(d == n or d.startswith(n + "/") for n in nested):
            continue
        if u.endswith("/") and any(n.startswith(d + "/") for n in nested):
            try:
                names = sorted(os.listdir(str(p / d)))
            except OSError:
                continue
            kids = [d + "/" + x + ("/" if (p / d / x).is_dir() and not (p / d / x).is_symlink() else "")
                    for x in names]
            out += _beside_nested(p, kids, nested)
            continue
        out.append(u)
    return out


def _loose(p: Path, key: str, keys: List[str]) -> List[str]:
    """Untracked, not-ignored paths of target/<key>'s working tree (files and symlinks; a repository of its own
    shows as "<dir>/"), leaving out the configured nested repos under it, which are repos of their own. Sorted."""
    code, out, _ = _git(p, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted(_beside_nested(p, [u for u in (out.split("\0") if code == 0 else []) if u],
                                 _nested_rels(key, keys)))


def _ignored(p: Path, key: str, keys: List[str]) -> List[str]:
    """Ignored, non-empty entries of target/<key>'s working tree — .gitignore, .git/info/exclude or the global
    excludes file: notes, .env, a repository cloned inside (a wholly ignored directory is one "<dir>/" entry) —
    leaving out the configured nested repos and anything under them, and opening up a directory that holds one
    (agents/ holding agents/<name>). A window is made from the commits and the untracked files; these stay in the
    trunk mirror, so its line names them (release-candidate review 2, finding 9). Sorted."""
    code, out, _ = _git(p, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory",
                        "--no-empty-directory", "-z")
    found = []
    for u in _beside_nested(p, [u for u in (out.split("\0") if code == 0 else []) if u], _nested_rels(key, keys)):
        try:
            if u.endswith("/"):
                if not os.listdir(str(p / u)):
                    continue
            elif not os.path.islink(str(p / u)) and os.path.getsize(str(p / u)) == 0:
                continue
        except OSError:
            continue
        found.append(u)
    return sorted(found)


class _OutOfTime(Exception):
    pass


def _git_path(p: Path, *args: str) -> Optional[Path]:
    code, out, _ = _git(p, "rev-parse", *args)
    if code != 0 or not out.strip():
        return None
    d = Path(out.strip())
    return d if d.is_absolute() else p / d


def _leftover_locks(root: Path, p: Path, min_age: float = LOCK_AGE) -> List[str]:
    """Lock files in target/<repo>'s git directory — HEAD.lock, index.lock, packed-refs.lock, a ref's .lock — as paths
    from the home. A window's own lease/<NN>.lock is left out: adopt and the worktree add clear it under the lease
    lock (release-candidate review 3, findings 8-9). One younger than LOCK_AGE seconds may be a git command running
    now (an editor's `git status`) and is not counted."""
    import leaselib as ll
    gd, common = _git_path(p, "--absolute-git-dir"), _git_path(p, "--git-common-dir")
    found = []
    for f in ([gd / "HEAD.lock", gd / "index.lock"] if gd else []) + ([common / "packed-refs.lock"] if common else []):
        if f.exists():
            found.append(str(f))
    if common is not None:
        for dirpath, _dirs, files in os.walk(str(common / "refs")):
            for f in files:
                if not f.endswith(".lock"):
                    continue
                full = os.path.join(dirpath, f)
                rel = os.path.relpath(full, str(common / "refs" / "heads"))
                if LEASE_BRANCH.fullmatch(rel[:-len(".lock")]) and ll.valid_id(rel[len("lease/"):-len(".lock")]):
                    continue
                found.append(full)
    now = time.time()
    old = []
    for f in found:
        try:
            if now - os.path.getmtime(f) >= min_age:
                old.append(os.path.relpath(f, str(root)))
        except OSError:
            pass
    return sorted(old)


def _unborn(p: Path) -> Optional[Tuple[str, str]]:
    """(branch, commit) when target/<repo>'s HEAD names a branch that does not exist while HEAD's reflog ends at a
    commit — a rename cut off between its ref writes (release-candidate review 3, finding 9). None otherwise."""
    code, ref, _ = _git(p, "symbolic-ref", "-q", "HEAD")
    ref = ref.strip()
    if code != 0 or not ref.startswith("refs/heads/") or _git(p, "rev-parse", "--verify", "-q", ref)[0] == 0:
        return None
    gd = _git_path(p, "--absolute-git-dir")
    try:
        log = (gd / "logs" / "HEAD").read_text().splitlines() if gd else []
    except OSError:
        return None
    # the newest entry that moved HEAD to a commit — a deleted branch's entry moves it to 0000…
    sha = next((f[1] for f in (ln.split() for ln in reversed(log)) if len(f) > 1 and f[1].strip("0")), "")
    if not sha or _git(p, "cat-file", "-e", sha + "^{commit}")[0] != 0:
        return None
    return ref[len("refs/heads/"):], sha


def _worktrees(p: Path) -> List[Dict[str, str]]:
    """`git worktree list --porcelain` of <p> as one dict per worktree: path, and head, branch, detached, prunable,
    locked when given."""
    code, out, _ = _git(p, "worktree", "list", "--porcelain")
    found, cur = [], {}
    for ln in (out.splitlines() if code == 0 else []) + [""]:
        if not ln.strip():
            if cur:
                found.append(cur)
            cur = {}
            continue
        k, _, val = ln.partition(" ")
        cur[{"worktree": "path", "HEAD": "head"}.get(k, k)] = val
    return found


def _window_tree(root: Path, real: str, branch: str) -> bool:
    """Is the worktree at <real> (a resolved path) a window's: under worktrees/<NN>/ with <NN> a lease file's number,
    or on lease/<NN> itself?"""
    import leaselib as ll
    base = os.path.realpath(str(root / "worktrees"))
    if not real.startswith(base + os.sep):
        return False
    nn = real[len(base) + 1:].split(os.sep, 1)[0]
    return ll.valid_id(nn) and (branch == "refs/heads/lease/" + nn or ll.read_lease(root, nn) is not None)


def _hand_worktrees(root: Path, p: Path) -> List[Tuple[str, str]]:
    """(path, what) for each worktree of target/<repo> someone made by hand — not target/<repo> itself, not a window's
    (worktrees/<NN>/ with a lease file, or on lease/<NN>), not promote's scratch — that holds work no window or branch
    has: a detached HEAD with commits no branch holds, uncommitted or untracked files (release-candidate review 3,
    finding 5); its directory missing is said (an unmounted volume: its record is kept, finding 2). One made by hand
    under worktrees/ — worktrees/hotfix, or a number no window has — is named like any other (review 4, finding 3).
    A branch with commits is named by _branches."""
    import leaselib as ll
    here = os.path.realpath(str(p))
    scratch = os.path.realpath(str(root / "state" / "promote"))
    found = []
    for w in _worktrees(p):
        path = w.get("path", "")
        real = os.path.realpath(path)
        if (not path or real == here or real.startswith(scratch + os.sep)
                or _window_tree(root, real, w.get("branch", ""))):
            continue
        parts = []
        sha = w.get("head", "")
        if "detached" in w and sha.strip("0") and not ll._held_elsewhere(p, sha):
            _, subs, _ = _git(p, "log", "--reverse", "--format=%s", sha, "--not", "--branches", "--remotes")
            subs = [x for x in subs.splitlines() if x.strip()]
            if subs:
                parts.append("a detached HEAD with %s no branch has (%s)" % (_plural(len(subs), "commit"), _quoted(subs)))
        missing = "prunable" in w or not os.path.isdir(path)
        if missing:
            # moved with mv, it still works through git's record of it, which the upgrade keeps (safety-copy
            # review 4, findings 1 and 5): what that record holds is named
            admin = ll.worktree_records(p).get(real)
            holds = ll.record_holds(admin) if admin is not None else []
            if holds:
                parts.append("git's record of it holds %s" % "; ".join(holds))
        else:
            code, st, _ = _git(Path(path), "status", "--porcelain", "--untracked-files=all")
            files = sorted(ln[3:] for ln in st.splitlines() if ln.strip()) if code == 0 else []
            if files:
                parts.append("uncommitted or untracked files (%s)" % ll.name_paths(files))
        if parts:
            what = " and ".join(parts)
            if "branch" in w:
                what = "on branch %s, %s" % (w["branch"][len("refs/heads/"):], what)
            if missing:
                what += (" — its directory is not there now (a volume not mounted, or moved: then run git -C %s "
                         "worktree repair <its new path>); its record is kept" % _rel(root, str(p)))
            found.append((path, what))
    return found


def _submodules(p: Path, rel: str = "") -> List[Tuple[str, Path, str]]:
    """(path from target/<repo>, checkout, the commit its parent's index records) for each initialized submodule of
    <p>, and theirs in turn."""
    code, out, _ = _git(p, "ls-files", "--stage", "-z")
    found: List[Tuple[str, Path, str]] = []
    for ent in (out.split("\0") if code == 0 else []):
        meta, _, path = ent.partition("\t")
        f = meta.split()
        if len(f) != 3 or f[0] != "160000" or not path:
            continue
        sp = p / path
        if (sp / ".git").exists():
            found.append((rel + path, sp, f[1]))
            found += _submodules(sp, rel + path + "/")
    return found


def _submodule_work(p: Path) -> List[Tuple[str, str]]:
    """(path, what) for each initialized submodule of target/<repo> holding work: uncommitted or untracked files, a
    local branch with commits none of its remote-tracking branches has, a detached HEAD past what the checkout records,
    a stash. A window's worktree starts with its submodules empty, so this work stays in the trunk mirror, where
    nothing named it (release-candidate review 4, finding 4)."""
    import leaselib as ll
    found = []
    for rel, sp, rec in _submodules(p):
        parts = []
        code, st, _ = _git(sp, "status", "--porcelain", "-z", "--untracked-files=all", "--ignore-submodules=all")
        files = sorted(e[3:] for e in st.split("\0") if len(e) > 3) if code == 0 else []
        if files:
            parts.append("uncommitted or untracked files (%s)" % ll.name_paths(files))
        _, out, _ = _git(sp, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/")
        for b in [x for x in out.splitlines() if x.strip()]:
            _, subs, _ = _git(sp, "log", "--reverse", "--format=%s", "refs/heads/" + b, "--not", "--remotes")
            subs = [x for x in subs.splitlines() if x.strip()]
            if subs:
                parts.append("branch %s, %s its origin lacks (%s)" % (b, _plural(len(subs), "commit"), _quoted(subs)))
        _, cur, _ = _git(sp, "branch", "--show-current")
        if not cur.strip():
            have = _git(sp, "cat-file", "-e", rec + "^{commit}")[0] == 0
            _, subs, _ = _git(sp, "log", "--reverse", "--format=%s", "HEAD", "--not", "--branches", "--remotes",
                              *([rec] if have else []))
            subs = [x for x in subs.splitlines() if x.strip()]
            if subs:
                parts.append("a detached HEAD with %s no branch has (%s)" % (_plural(len(subs), "commit"), _quoted(subs)))
        stash = _stash_entries(sp)
        if stash:
            n, named = _stash_words(stash)
            parts.append("%s (%s)" % (n, named))
        if parts:
            found.append((rel, "; ".join(parts)))
    return found


def _blobs(p: Path, rev: str) -> Dict[str, str]:
    """{path: blob id} of every file <rev> tracks (submodules left out)."""
    code, out, _ = _git(p, "ls-tree", "-r", "-z", "--full-tree", rev)
    found = {}
    for ent in (out.split("\0") if code == 0 else []):
        meta, _, path = ent.partition("\t")
        f = meta.split()
        if len(f) == 3 and f[1] == "blob":
            found[path] = f[2]
    return found


def _neither(p: Path, rev: str, to: str, paths: List[str]) -> List[str]:
    """Of <paths> in <p>'s working tree, those on disk whose content is neither <rev>'s nor <to>'s: not something a
    checkout or reset from <rev> to <to> wrote. A path not on disk is one it had yet to write. A file is either's
    when its bytes cleaned as git add would (a line-ending conversion undone) are that blob, or when its bytes as
    they are are: a checkout writes a blob that already holds CRLF unconverted, which hash-object alone, reading no
    index, would convert and call neither (release-candidate red team 2, finding 6)."""
    import leaselib as ll
    have, want = _blobs(p, rev), _blobs(p, to)
    files = [x for x in paths if os.path.isfile(str(p / x)) and not os.path.islink(str(p / x))]
    ids: Dict[str, Set[str]] = {}
    for how in ([], ["--no-filters"]):
        if not files:
            break
        try:
            r = subprocess.run(ll.git_argv(p, "hash-object", *how, "--stdin-paths"),
                               input="\n".join(files) + "\n", capture_output=True, text=True, timeout=120)
            got = r.stdout.split() if r.returncode == 0 else []
        except (OSError, subprocess.SubprocessError):
            got = []
        if len(got) == len(files):
            for x, h in zip(files, got):
                ids.setdefault(x, set()).add(h)
    odd = []
    for x in paths:
        if not os.path.lexists(str(p / x)):
            continue
        if not ids.get(x, set()) & {have.get(x), want.get(x)} - {None}:
            odd.append(x)
    return sorted(odd)


def _cut_off(root: Path, p: Path, key: str, trunk: str, ver: str, head: str, dry: bool) -> Optional[str]:
    """A checkout or hard reset this upgrade began in target/<key> and was cut off in part-way — git killed at the hook's
    timeout, or by a SIGKILL (release-candidate review 4, findings 5-6): the checkout is still on what was adopted
    (the trunk's tip, the adopted branch's tip, or the detached HEAD), a window's lease/<NN> holds that commit, and
    the tree is half switched — tracked changes, or git's own lock files left. Finished here, before the stops on lock
    files and uncommitted changes ("commit them" put the same commit in a second window): git's locks cleared, then
    the reset to origin/<trunk> (the trunk) or a forced checkout of <trunk> (an adopted branch). Locks younger than
    LOCK_AGE stop the step (git may be running); a file whose content is neither the commit's nor the destination's
    is named, never thrown away. Returns the line said, or None when there is nothing to finish."""
    import leaselib as ll
    _, cur, _ = _git(p, "branch", "--show-current")
    cur = cur.strip()
    sha = ll.ref_oid(p, "refs/heads/" + cur) if cur else _git(p, "rev-parse", "--verify", "-q", "HEAD")[1].strip()
    if not sha or (cur and LEASE_BRANCH.fullmatch(cur)):
        return None
    hit = None
    for nn, d in sorted(ll.read_all(root).items()):
        if nn == "prime" or d.get("adopted_repo") != key or d.get("adopted_tip") != sha:
            continue
        if _git(p, "merge-base", "--is-ancestor", sha, "refs/heads/lease/" + nn)[0] != 0:
            continue
        label = str(d.get("adopted_from") or "").startswith("daedalus/upgrade-")
        if cur == trunk and label:
            hit = (nn, _origin(trunk), ("reset", "--hard", "--quiet", _origin(trunk)),
                   "resetting %s to origin/%s" % (trunk, trunk), "reset --hard origin/%s" % trunk)
        elif (cur and cur != trunk and d.get("adopted_from") == cur) or (not cur and label):
            hit = (nn, "refs/heads/" + trunk, ("checkout", "-f", "--quiet", trunk), "putting it back on %s" % trunk,
                   "checkout -f %s" % trunk)
        if hit:
            break
    marked = _reset_marks(root).get(key)
    if hit is None and cur == trunk and marked:
        # the reset of a trunk whose commits a window holds, which "pick it up" or step 6 began (its mark says so, and
        # the trunk is still on the commit it was reset from): finished the same way, the files that are neither the
        # commit's nor origin's named, never thrown away. With no mark, a trunk a window holds and an edit there is
        # plain unsaved work (review of option 1, finding 1).
        nn = _carrier(root, p, "refs/heads/" + trunk) if marked == sha and _ahead(p, trunk) else None
        if nn is not None:
            hit = (nn, _origin(trunk), ("reset", "--hard", "--quiet", _origin(trunk)),
                   "resetting %s to origin/%s" % (trunk, trunk), "reset --hard origin/%s" % trunk)
        elif not dry:
            _reset_mark(root, key, None)        # it finished, or the trunk moved since: nothing of it is left
    if hit is None:
        return None
    nn, to, args, doing, cmd = hit
    gd, common = _git_path(p, "--absolute-git-dir"), _git_path(p, "--git-common-dir")
    mine = ([gd / "HEAD.lock", gd / "index.lock", gd / "ORIG_HEAD.lock"] if gd else []) + \
        ([common / "refs" / "heads" / (trunk + ".lock")] + ([common / "refs" / "heads" / (cur + ".lock")] if cur else [])
         if common else [])
    locks = [f for f in mine if f.exists()]
    code, st, _ = _git(p, "status", "--porcelain", "-z", "--untracked-files=no", "--ignore-submodules=all",
                       "--no-renames")
    changed = sorted({e[3:] for e in st.split("\0") if len(e) > 3}) if code == 0 else []
    if not locks and not changed:
        return None         # not switched at all yet: the run below finishes it as before
    now = time.time()
    young = []
    for f in locks:
        try:
            if now - f.stat().st_mtime < LOCK_AGE:
                young.append(f)
        except OSError:
            pass
    if young or dry:
        shown = young or locks
        named = " (%s)" % ", ".join(os.path.relpath(str(f), str(root)) for f in shown) if shown else ""
        raise Stop(CUT_WAIT % (ver, key, doing, named, nn, sha[:7]))
    # an untracked file the switch wrote (the index never got it) is the destination's; one of the operator's is not
    odd = _neither(p, sha, to, changed + ll.untracked_in_way(p, [to]))
    if odd:
        raise Stop(CUT_OTHER % (ver, key, doing, nn, sha[:7], to.replace("refs/remotes/", "").replace("refs/heads/", ""),
                                ll.name_paths(odd), nn, key, key, cmd))
    for f in locks:
        try:
            f.unlink()
        except OSError:
            pass
    code, _, err = ll.git_finish(p, *args)
    if code != 0:
        raise Stop("could not finish %s in target/%s, cut off at an earlier start (%s); window %s holds its commit %s"
                   % (doing, key, _last(err), nn, sha[:7]))
    if args[0] == "reset":
        _reset_mark(root, key, None)
    return ("%s: a git command Daedalus ran in target/%s (%s) was cut off part-way; it is finished now — window %s holds "
            "the commit %s." % (head, key, doing, nn, sha[:7]))


def _gate_checks(root: Path, p: Path, key: str, trunk: str, ver: str) -> None:
    """Stop when target/<key> cannot be read safely: lock files a cut-off git left, a checkout on a branch that is
    gone, branch names that differ only in case, a local branch named origin/<trunk>."""
    import leaselib as ll
    locks = _leftover_locks(root, p)
    if locks:
        raise Stop(LOCKS_LEFT % (ver, key, ", ".join(locks), " ".join(shlex.quote(f) for f in locks)))
    unborn = _unborn(p)
    if unborn:
        raise Stop(UNBORN % (ver, key, unborn[0], unborn[1][:7], key, unborn[0], unborn[1][:7]))
    twins = ll.case_twins(p)
    if twins:
        raise Stop(TWINS % (ver, key, ll.twins_words(twins), key, key, twins[0][0]))
    if _git(p, "rev-parse", "--verify", "-q", "refs/heads/origin/" + trunk)[0] == 0:
        raise Stop(SHADOW % (ver, key, trunk, trunk, key, trunk))


def _host(p: Path) -> str:
    """What the operator calls origin: GitHub when its recorded address is GitHub's, else origin."""
    _, url, _ = _git(p, "config", "--get", "remote.origin.url")
    return "GitHub" if "github.com" in url.lower() else "origin"


def _busy(p: Path) -> List[Tuple[str, str]]:
    """(what, its git command) for each rebase, merge, cherry-pick, revert or bisect stopped part-way in <p> (critic
    finding 3: a rebase stopped at "edit" reads clean)."""
    import leaselib as ll
    found: List[Tuple[str, str]] = []
    for marker, what, cmd in tuple(ll._IN_PROGRESS) + (("BISECT_LOG", "bisect", "bisect"),):
        path = _git_path(p, "--git-path", marker)
        if path is not None and path.exists() and what not in [w for w, _ in found]:
            found.append((what, cmd))
    return found


def _other_worktrees(root: Path, p: Path) -> List[str]:
    """Every linked worktree of <p> that is not a window's (worktrees/<NN>/ with a lease file, or on lease/<NN>) nor
    promote's scratch — made by hand anywhere, under worktrees/ too, its directory there or not."""
    here = os.path.realpath(str(p))
    scratch = os.path.realpath(str(root / "state" / "promote"))
    found = []
    for w in _worktrees(p):
        path = w.get("path", "")
        real = os.path.realpath(path)
        if (not path or real == here or real.startswith(scratch + os.sep)
                or _window_tree(root, real, w.get("branch", ""))):
            continue
        found.append(path)
    return found


def _carrier(root: Path, p: Path, ref: str) -> Optional[str]:
    """The number of a window — a lease file and its lease/<NN> — whose branch holds every commit of <ref>, or None.
    A lease/<NN> with no lease file (an adoption cut off before it wrote one) is no window: what it holds is still
    work to pick up, and adopting it again finishes that window."""
    import leaselib as ll
    _, out, _ = _git(p, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/lease/")
    for c in [b for b in out.split() if LEASE_BRANCH.fullmatch(b)]:
        if (c != ref and ll.read_lease(root, c[len("lease/"):]) is not None
                and _git(p, "merge-base", "--is-ancestor", _q(ref), _q(c))[0] == 0):
            return c[len("lease/"):]
    return None


def unfinished(root: Path, key: str, p: Path, trunk: str, keys: List[str], deadline: Optional[float],
               ver: str) -> List[dict]:
    """The unfinished work in target/<key>, each {"kind", "words", ...}, in the order the stop names them (spec §14
    step 6, the operator's decision of 2026-10-07 — Appendix E): a git operation stopped part-way ("busy"); a local
    branch with commits origin/<trunk> has no equivalent of — git cherry, a merge carrying content, a squash merge
    found by merge-tree — that no window already holds, its branch on origin deleted or not ("branch"; the checked-out
    one first); the trunk ahead of origin, unless a window holds those commits ("trunk"); a detached
    HEAD with commits no branch has ("detached"); uncommitted changes to tracked files and untracked files that
    are not ignored ("unsaved"), and changes git status does not show — skip-worktree or assume-unchanged, a
    clean filter or line-ending conversion, an edit git's stat check passes ("hidden"); a repository of its own
    inside the checkout that is not ignored ("clone"); stash entries ("stash"); and every linked worktree that is
    not a window's ("worktree"). Nested target repos are judged as repos of their own. Ignored files and work in
    a submodule are not unfinished work: the upgrade names them and leaves them where they are."""
    import leaselib as ll
    host = _host(p)
    items: List[dict] = []
    for what, cmd in _busy(p):
        items.append({"kind": "busy", "what": what, "cmd": cmd, "words": "a %s in progress" % what})
    _, cur, _ = _git(p, "branch", "--show-current")
    cur = cur.strip()
    _, out, _ = _git(p, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/")
    names = [b for b in out.splitlines() if b.strip() and b != trunk]
    found = []
    for b in names:
        # a window's own branch is a window; one with no lease file checked out here is the operator's work
        if LEASE_BRANCH.fullmatch(b) and not (b == cur and ll.read_lease(root, b[len("lease/"):]) is None):
            continue
        try:
            work = _work(p, trunk, b)
        except ll.Refused as e:
            raise Stop("could not tell whether target branch %s holds work origin/%s lacks (%s)" % (b, trunk, e))
        if work and _carrier(root, p, b) is None:
            found.append((b, work))
    for b, work in sorted(found, key=lambda bw: (bw[0] != cur, -len(bw[1]), bw[0])):
        items.append({"kind": "branch", "branch": b, "n": len(work),
                      "words": "the branch %s (%s not on %s)" % (b, _plural(len(work), "commit"), host)})
    ahead = _ahead(p, trunk)
    if ahead and _carrier(root, p, trunk) is None:
        items.append({"kind": "trunk", "n": len(ahead),
                      "words": "the branch %s (%s not on %s)" % (trunk, _plural(len(ahead), "commit"), host)})
    if not cur:
        _, out, _ = _git(p, "rev-list", "HEAD", "--not", "--branches", "--remotes")
        n = len([x for x in out.split() if x.strip()])
        if n:
            items.append({"kind": "detached", "n": n,
                          "words": "a detached checkout with %s no branch has" % _plural(n, "commit")})
    # a submodule's own edits, untracked files and commits are its work, named in a line, never "unsaved" here: no
    # commit in this checkout can take them (release-candidate review 4, finding 4) — nor a submodule checked out at
    # another commit than the one recorded (picking up a branch that moved it leaves it there): the checkout back to
    # the trunk leaves a submodule's working tree as it is (submodule.recurse off), so nothing of it is lost
    code, st, err = _git(p, "status", "--porcelain", "-z", "--untracked-files=no", "--ignore-submodules=all",
                         "--no-renames")
    if code != 0:
        raise Stop("could not read target/%s's status (%s)" % (key, _last(err)))
    changed = sorted({e[3:] for e in st.split("\0") if len(e) > 3})
    loose = _loose(p, key, keys)
    hidden = ll.hidden_edits(p)
    filtered, blind = [], []
    if not changed and not hidden:
        # under the start's deadline: running out of time is a stop, never a pass (release-candidate red team 2,
        # finding 7)
        try:
            filtered = ll.filtered_edits(p, deadline)
            blind = [] if filtered else ll.stat_blind_edits(p, deadline)
        except subprocess.TimeoutExpired:
            raise Stop(STOPPED_TIME % (ver, "checking target/%s for changes git status does not show" % key))
    odd = sorted(set(hidden) | set(filtered) | set(blind))
    plain = sorted((set(changed) | {u for u in loose if not u.endswith("/")}) - set(odd))
    if plain:
        items.append({"kind": "unsaved", "paths": plain, "words": _plural(len(plain), "unsaved file")})
    if odd:
        items.append({"kind": "hidden", "hidden": hidden, "filtered": filtered, "blind": blind,
                      "words": "%s git status does not show (%s)" % (_plural(len(odd), "changed file"),
                                                                     ll.name_paths(odd))})
    for u in [u for u in loose if u.endswith("/")]:
        items.append({"kind": "clone", "path": u, "words": "a repository of its own at %s" % u})
    # a directory holding a .git git cannot read: no status lists it, and a checkout deletes it whole (safety-copy
    # review 4, finding 3)
    for d in ll.unreadable_gits(p):
        items.append({"kind": "clone", "path": d + "/", "words": "a .git git cannot read at %s/" % d})
    stash = _stash_entries(p)
    if stash:
        items.append({"kind": "stash", "n": len(stash), "words": _stash_words(stash)[0]})
    for path in _other_worktrees(root, p):
        items.append({"kind": "worktree", "path": path,
                      "words": "a worktree made by hand at %s%s" % (path, "" if os.path.isdir(path)
                                                                    else " (its directory is gone)")})
    return items


def _and(words: List[str]) -> str:
    return words[0] if len(words) == 1 else ", ".join(words[:-1]) + ", and " + words[-1]


def unfinished_sentence(found: List[Tuple[str, List[dict]]]) -> str:
    """The one sentence the stop says, the board repeats on every prompt and doctor shows: what was found, by repo,
    at most MOST_ITEMS things, then "and N more"."""
    total = sum(len(items) for _, items in found)
    parts, shown = [], 0
    for key, items in found:
        take = items[:MOST_ITEMS - shown]
        if not take:
            break
        parts.append("target/%s: %s" % (key, _and([i["words"] for i in take])))
        shown += len(take)
    said = "; and in ".join(parts)
    if total > shown:
        said += ", and %d more" % (total - shown)
    return UNFINISHED % said


_FETCHED: Dict[str, Set[str]] = {}     # root -> the repos whose fetch at the gate finished (step 6 reads it)


def gate(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """_gate; a stop carries the lines said before it (e.lines)."""
    lines: List[str] = []
    try:
        return _gate(root, head, dry, deadline, lines)
    except Stop as e:
        e.lines = list(lines)
        raise


def _gate(root: Path, head: str, dry: bool, deadline: Optional[float], lines: List[str]) -> List[str]:
    """Before step 2, the first step that can change anything under target/, and after the safety copy: a checkout
    or reset the upgrade or `lease.sh adopt` began and was cut off is finished (the window holds its commit);
    target/ that cannot be read safely stops; then one bounded fetch of every target repo (plan 5 Decision 3), and
    any unfinished work in any of them (unfinished()) stops the upgrade with one sentence naming it — nothing under
    target/ is changed, and the operator says "pick it up" (core/lease.sh adopt --all-unfinished) or ships it the
    usual way. Last, an untracked or ignored file where putting a checkout back on its trunk would write stops too."""
    import leaselib as ll
    repos = target_repos(root)
    if not repos:
        return []
    try:
        trunks = ll.trunks_of(root, root / "target")
    except ll.Refused as e:
        raise Stop("could not tell each target repo's trunk (%s)" % e)
    ver = version(root) or "this release"
    for key, p in repos:
        cut = _cut_off(root, p, key, trunks[key], ver, head, dry)
        if cut:
            lines.append(cut)
        _gate_checks(root, p, key, trunks[key], ver)
    fetched = set() if dry else _fetch_all(repos, deadline)
    _FETCHED[str(root)] = fetched
    found = []
    for key, p in repos:
        items = unfinished(root, key, p, trunks[key], list(trunks), deadline, ver)
        if items:
            found.append((key, items))
    if found:
        raise Stop(unfinished_sentence(found))
    for key, p in repos:
        _, cur, _ = _git(p, "branch", "--show-current")
        _in_the_way(p, key, trunks[key], cur.strip(), ver)
    return lines


def step_trunk(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """_step_trunk; a stop carries the lines of what the step did before it (e.lines)."""
    lines: List[str] = []
    try:
        return _step_trunk(root, head, dry, deadline, lines)
    except Stop as e:
        e.lines = list(lines)
        raise


def _step_trunk(root: Path, head: str, dry: bool, deadline: Optional[float], lines: List[str]) -> List[str]:
    """Spec §14 step 6, after the gate found no unfinished work: per repo (outer first, then nested), a window
    `lease.sh adopt` made and was cut off before its worktree is finished (finish_adopted); a checkout on a branch
    whose work is already on origin/<trunk> (merged or squash-merged), on a window's branch, or detached at commits a
    branch holds, goes back on its trunk, the branch left as it was; a trunk ahead of origin whose commits a window
    holds is reset to origin/<trunk>; the trunk is fast-forwarded to origin. Then ignored files and work in a
    submodule are each named in a line and left where they are. Afterwards no target/<repo> is off its trunk or
    ahead of origin — §14's predicate."""
    import leaselib as ll
    repos = target_repos(root)
    if not repos:
        return []
    try:
        trunks = ll.trunks_of(root, root / "target")
    except ll.Refused as e:
        raise Stop("could not tell each target repo's trunk (%s)" % e)
    ver = version(root) or "this release"
    fetched = _FETCHED.get(str(root), set())
    for key, p in repos:
        trunk = trunks[key]
        if dry:
            stale = " (judged against origin/%s as last fetched; the real run fetches first)" % trunk
        elif key not in fetched:
            stale = " (judged against origin/%s as last fetched — the fetch did not finish)" % trunk
        else:
            stale = ""
        if not dry:
            # a window `lease.sh adopt` made from here at "pick it up", cut off before its worktree: made now
            try:
                finished = ll.finish_adopted(root, key, deadline)
            except ll.Refused as e:
                raise Stop("could not finish a window adopted from target/%s (%s)" % (key, e))
            for nn, ok in finished:
                if not ok:
                    raise Stop(STOPPED_TIME % (ver, STEPS[5][1]))
                lines.append("%s: window %s, adopted from target/%s, now has its worktree (worktrees/%s/%s)."
                             % (head, nn, key, nn, key))
        _, cur, _ = _git(p, "branch", "--show-current")
        cur = cur.strip()
        if cur != trunk:
            if not cur:
                what = ("target/%s was not on a branch; its commits are already on a branch or on origin/%s, and it is "
                        "back on %s" % (key, trunk, trunk))
            elif LEASE_BRANCH.fullmatch(cur):
                what = "target/%s was on %s, a window's branch; it is back on %s (the window keeps its branch)" % (
                    key, cur, trunk)
            elif _carrier(root, p, cur) is not None and _work(p, trunk, cur):
                what = ("target/%s was on %s, whose commits window %s holds; it is back on %s"
                        % (key, cur, _carrier(root, p, cur), trunk))
            else:
                what = ("target/%s was on %s, whose work is already on origin/%s; it is back on %s and %s is left as it "
                        "was" % (key, cur, trunk, trunk, cur))
            if dry:
                lines.append("%s: would put target/%s back on %s (%s holds nothing that origin/%s lacks)%s."
                             % (head, key, trunk, cur or "its detached HEAD", trunk, stale))
            else:
                _back_on_trunk(p, key, trunk)
                lines.append("%s: %s.%s" % (head, what, stale))
        ahead = _ahead(p, trunk)
        if ahead:
            nn = _carrier(root, p, trunk)
            if nn is None:      # the gate stops on this; never reset over commits no window holds
                raise Stop("target/%s's %s is ahead of origin/%s and no window holds those commits" % (key, trunk,
                                                                                                       trunk))
            n = _plural(len(ahead), "commit")
            if dry:
                lines.append("%s: would reset target/%s's %s (%s ahead of origin/%s) to origin/%s — window %s holds "
                             "those commits%s." % (head, key, trunk, n, trunk, trunk, nn, stale))
            else:
                code, err = _reset_trunk(root, p, key, trunk)
                if code != 0:
                    raise Stop("could not reset target/%s's %s to origin/%s (%s); window %s holds its commits"
                               % (key, trunk, trunk, _last(err), nn))
                lines.append("%s: target/%s's %s was %s ahead of origin/%s; window %s already holds those commits, so "
                             "%s is reset to origin/%s.%s" % (head, key, trunk, n, trunk, nn, trunk, trunk, stale))
        elif not dry and cur == trunk:
            _git(p, "merge", "--ff-only", "--quiet", _origin(trunk))
    # ignored files stay in the trunk mirror, which no session works in (review 3, finding 6); work in a submodule
    # too (a window's worktree starts with the submodule empty: review 4, finding 4) — each named once
    for key, p in repos:
        ign = _ignored(p, key, list(trunks))
        if ign:
            lines.append("%s: target/%s holds ignored files no window has (%s) — they stay there, in the trunk mirror, "
                         "which no session works in; if any of them is work, move it into a window's worktree "
                         "(worktrees/<NN>/%s)." % (head, key, ll.name_paths(ign), key))
        for rel, what in _submodule_work(p):
            lines.append("%s: target/%s's submodule %s holds work no window has: %s — the upgrade leaves it there, in "
                         "the trunk mirror (a window's worktree starts with the submodule empty), and core/doctor.sh "
                         "names it until it is moved or removed." % (head, key, rel, what))
    return lines


# --- "pick it up": core/lease.sh adopt --all-unfinished -------------------------------------------------------
# What the operator's "pick it up" runs after the upgrade stopped on unfinished work: every piece of it the stop
# names that can become a window does, one window each, through leaselib.adopt — the checked-out branch, every other
# branch, the trunk ahead of origin, a detached HEAD (given a branch first), unsaved files (saved first as one
# commit: on the checked-out branch, or on a branch of their own when the checkout is on the trunk or detached), and
# each stash entry (as a commit of what it saved, on the commit it was made on; the entry is dropped only once a
# window holds it, and its own commit kept under refs/daedalus/stash/). Every name and commit it makes is the same
# on a second run, so a run cut off part-way is finished by the next, never doubled. What it cannot move — a git
# operation stopped part-way, changes git status does not show, a repository of its own inside the checkout, a
# worktree made by hand — is named with what to do. Then the next session start finishes the upgrade.

def _pick_env(p: Path, extra: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """The environment for the commits "pick it up" makes: the repository's own identity, or a fixed one when it
    has none."""
    env = dict(os.environ, **(extra or {}))
    if _git(p, "var", "GIT_COMMITTER_IDENT")[0] != 0 or _git(p, "var", "GIT_AUTHOR_IDENT")[0] != 0:
        env.update({"GIT_AUTHOR_NAME": "Daedalus", "GIT_AUTHOR_EMAIL": "daedalus@localhost",
                    "GIT_COMMITTER_NAME": "Daedalus", "GIT_COMMITTER_EMAIL": "daedalus@localhost"})
    return env


def _git_env(p: Path, env: Dict[str, str], *args: str, inp: Optional[str] = None) -> Tuple[int, str, str]:
    import leaselib as ll
    try:
        r = subprocess.run(ll.git_argv(p, *args), input=inp, capture_output=True, text=True, env=env, timeout=600)
    except (OSError, subprocess.SubprocessError) as e:
        return 1, "", str(e)
    return r.returncode, r.stdout, r.stderr


def _commit_at(p: Path, tree: str, parent: str, msg: str, when: str) -> str:
    """A commit of <tree> on <parent> dated <when> (a commit's own date: the same on every run, so a run cut off
    part-way and run again makes the very same commit)."""
    env = _pick_env(p, {"GIT_AUTHOR_DATE": when, "GIT_COMMITTER_DATE": when})
    code, out, err = _git_env(p, env, "commit-tree", tree, "-p", parent, "-m", msg)
    if code != 0 or not out.strip():
        raise Stop("could not save the work in target as a commit (%s)" % _last(err))
    return out.strip()


def _set_branch(p: Path, branch: str, sha: str) -> None:
    """Make <branch> at <sha>, or find it already there (a run cut off after it made it)."""
    ref = "refs/heads/" + branch
    _, at, _ = _git(p, "rev-parse", "--verify", "-q", ref)
    if at.strip() == sha:
        return
    if at.strip():
        raise Stop("target has a branch %s already, at another commit; rename it, then say 'pick it up' again" % branch)
    code, _, err = _git(p, "update-ref", ref, sha, "0" * 40)
    if code != 0:
        raise Stop("could not make branch %s (%s)" % (branch, _last(err)))


def _save_unsaved(root: Path, p: Path, key: str, trunk: str, cur: str, paths: List[str]) -> str:
    """Unsaved files of target/<key> — tracked changes and untracked files that are not ignored — saved as one
    commit on what is checked out, built in a scratch index (the checkout's own index untouched until the commit
    is on a branch): on the checked-out branch when it is the operator's own, else on a branch of their own,
    daedalus/unsaved-<short sha>, which the checkout then follows. Then the index is read from that commit, so the
    checkout reads clean and the branch can be adopted. Returns the branch."""
    import leaselib as ll
    _, head, _ = _git(p, "rev-parse", "HEAD")
    head = head.strip()
    # dated as the newest of the files it saves: the same on a second run, so a cut-off run makes the same commit
    stamps = []
    for x in paths:
        try:
            stamps.append(int(os.lstat(str(p / x)).st_mtime))
        except OSError:
            pass
    if stamps:
        when = "@%d +0000" % max(stamps)
    else:
        when = _git(p, "log", "-1", "--format=%cI", "HEAD")[1].strip()
    idx = _git_path(p, "--git-path", "index")
    tmp = tempfile.mkdtemp(prefix="daedalus-pick-up-")
    try:
        tmpidx = os.path.join(tmp, "index")
        if idx is not None and idx.exists():
            shutil.copy2(str(idx), tmpidx)
        env = dict(os.environ, GIT_INDEX_FILE=tmpidx, GIT_LITERAL_PATHSPECS="1")
        code, _, err = _git_env(p, env, "add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul",
                                inp="\0".join(paths) + "\0")
        if code != 0:
            raise Stop("could not save target/%s's unsaved files (%s)" % (key, _last(err)))
        code, tree, err = _git_env(p, env, "write-tree")
        if code != 0:
            raise Stop("could not save target/%s's unsaved files (%s)" % (key, _last(err)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    tree = tree.strip()
    own = bool(cur) and cur != trunk and not (LEASE_BRANCH.fullmatch(cur)
                                              and ll.read_lease(root, cur[len("lease/"):]) is not None)
    if tree == _git(p, "rev-parse", "HEAD^{tree}")[1].strip():
        sha = head           # a run cut off after the commit: it is HEAD already, only the index is left
    else:
        sha = _commit_at(p, tree, head, "Unsaved work in target/%s, picked up before the upgrade" % key, when)
    if own:
        branch = cur
        if sha != head:
            code, _, err = _git(p, "update-ref", "-m", "pick it up: unsaved work", "refs/heads/" + cur, sha, head)
            if code != 0:
                raise Stop("could not save target/%s's unsaved files on %s (%s)" % (key, cur, _last(err)))
    else:
        branch = "daedalus/unsaved-%s" % sha[:12]
        _set_branch(p, branch, sha)
        code, _, err = _git(p, "symbolic-ref", "-m", "pick it up: unsaved work", "HEAD", "refs/heads/" + branch)
        if code != 0:
            raise Stop("could not put target/%s on %s (%s)" % (key, branch, _last(err)))
    code, _, err = _git(p, "reset", "-q")
    if code != 0:
        raise Stop("could not read target/%s's index from its new commit (%s)" % (key, _last(err)))
    return branch


def _stash_commits(p: Path) -> List[Tuple[int, str, str]]:
    """(index, the entry's commit, a commit holding what it saved — its working tree, and its untracked files when
    it has them — on the commit it was made on, dated as the entry) for each stash entry, newest first."""
    code, out, _ = _git(p, "stash", "list", "--format=%H%x09%cI%x09%gs")
    found = []
    for i, ln in enumerate(out.splitlines() if code == 0 else []):
        w, when, subject = (ln.split("\t", 2) + ["", ""])[:3]
        if not w:
            continue
        _, tree, _ = _git(p, "rev-parse", "%s^{tree}" % w)
        tree = tree.strip()
        if _git(p, "rev-parse", "--verify", "-q", "%s^3" % w)[0] == 0:
            tmp = tempfile.mkdtemp(prefix="daedalus-pick-up-")
            try:
                env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "index"))
                _git_env(p, env, "read-tree", w)
                _, ls, _ = _git(p, "ls-tree", "-r", "-z", "%s^3" % w)
                _git_env(p, env, "update-index", "-z", "--index-info", inp=ls)
                code, t2, _ = _git_env(p, env, "write-tree")
                if code == 0 and t2.strip():
                    tree = t2.strip()
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
        _, base, _ = _git(p, "rev-parse", "%s^1" % w)
        found.append((i, w, _commit_at(p, tree, base.strip(), subject or "a stash entry", when)))
    return found


PICK_BUSY = ("target/%s is in the middle of a %s — finish it with git -C target/%s %s --continue, or undo it with git "
             "-C target/%s %s --abort; nothing there was moved")
PICK_BISECT = "target/%s is in the middle of a bisect — end it with git -C target/%s bisect reset; nothing there was moved"
PICK_HIDDEN = ("target/%s has changes git status does not show (%s) — %s; nothing there was moved")
PICK_CLONE = ("target/%s holds %s, a repository of its own that no window can take — move it out of target/%s")
PICK_WORKTREE = ("target/%s has a worktree made by hand at %s — commit its work on a branch there, then remove it (git -C "
                 "target/%s worktree remove %s, or git -C target/%s worktree prune if its directory is gone)")


def _pick_repo(root: Path, key: str, p: Path, trunk: str, items: List[dict], ver: str,
               left: List[str]) -> List[str]:
    import leaselib as ll
    kinds = {i["kind"] for i in items}
    if not kinds & {"branch", "trunk", "detached", "unsaved", "stash"}:
        return []
    rel = None if key == ll.target_name(root) else key.split("/", 1)[1]
    said: List[str] = []
    _, cur, _ = _git(p, "branch", "--show-current")
    cur = cur.strip()
    refs: List[str] = []
    unsaved = next((i for i in items if i["kind"] == "unsaved"), None)
    if unsaved:
        cur = _save_unsaved(root, p, key, trunk, cur, unsaved["paths"])
        refs.append(cur)
    elif not cur and "detached" in kinds:
        _, head, _ = _git(p, "rev-parse", "HEAD")
        name = "daedalus/detached-%s" % head.strip()[:12]
        _set_branch(p, name, head.strip())
        refs.append(name)
    refs += [i["branch"] for i in items if i["kind"] == "branch" and i["branch"] not in refs]
    stashes = _stash_commits(p) if "stash" in kinds else []
    for _i, w, c in stashes:
        name = "daedalus/stash-%s" % w[:12]
        if _carrier(root, p, c) is None:
            _set_branch(p, name, c)
            refs.append(name)
    held: Set[str] = set()
    for ref in refs:
        if _git(p, "rev-parse", "--verify", "-q", "refs/heads/" + ref)[0] != 0:
            continue
        if ref != cur and _carrier(root, p, ref) is not None:
            continue            # a window just made holds every commit of it
        try:
            r = ll.adopt(root, ref, repo=rel, note=PICKED_NOTE % ver, fetch=False)
        except ll.Refused as e:
            left.append(str(e))
            continue
        held.add(ref)
        said.append(ll.adopt_sentence(r))
        if r["already"]:        # a run cut off after the window was made: the name made again goes
            tip = ll.ref_oid(p, "refs/heads/" + ref)
            if tip and ref.startswith("daedalus/") and _carrier(root, p, ref) is not None:
                _git(p, "update-ref", "-d", "refs/heads/" + ref, tip)
    # a stash entry a window holds is dropped, newest index first, only while the entry is still that commit; its own
    # commit stays reachable under refs/daedalus/stash/, so the safety copy finds nothing missing
    for i, w, c in sorted(stashes, reverse=True):
        if _carrier(root, p, c) is None:
            continue
        _git(p, "update-ref", "refs/daedalus/stash/" + w, w)
        if _git(p, "rev-parse", "stash@{%d}" % i)[1].strip() == w:
            _git(p, "stash", "drop", "-q", "stash@{%d}" % i)
    ahead = _ahead(p, trunk)
    if ahead:
        nn = _carrier(root, p, trunk)
        if nn is None:
            try:
                r = ll.adopt(root, trunk, repo=rel, note=PICKED_NOTE % ver, fetch=False)
                said.append(ll.adopt_sentence(r))
            except ll.Refused as e:
                left.append(str(e))
        else:
            code, err = _reset_trunk(root, p, key, trunk)
            if code != 0:
                left.append("could not reset target/%s's %s to origin/%s (%s); window %s holds its commits"
                            % (key, trunk, trunk, _last(err), nn))
            else:
                said.append("target/%s's %s was also %s ahead of origin/%s; window %s holds those commits, so %s is "
                            "reset to origin/%s." % (key, trunk, _plural(len(ahead), "commit"), trunk, nn, trunk,
                                                     trunk))
    return said


def _for_pick(sentence: str) -> str:
    """A stop sentence of the upgrade's, said by "pick it up": no "upgrade incomplete", no "start a session"."""
    s = re.sub(r"^upgrade to \S+ incomplete: ", "", sentence)
    return s.replace("then start a session again", "then say 'pick it up' again")


# `upgrade.py --caller update` (daedalus update runs it): the stop is said in a terminal, where "start a session" is
# the wrong next step (update-command Decision 23). (session wording, terminal wording); the recorded "sentence"
# keeps the session wording.
_UPDATE_WORDS = (("then start a session again", "then run daedalus update again"),
                 ("and start a session again", "and run daedalus update again"),
                 ("then start a new session", "then run daedalus update again"),
                 ("it tries again at the next session start", "it tries again at the next daedalus update"),
                 ("it runs again at the next session start", "it runs again at the next daedalus update"),
                 ("the next session start finishes it", "the next daedalus update finishes it"),
                 ("Say 'pick it up'", "Say 'pick it up' to this home's agent"))
_CALLER = {"update": False}


def _for_update(sentence: str) -> str:
    """A stop sentence of the upgrade's, said to the terminal that ran `daedalus update`."""
    for a, b in _UPDATE_WORDS:
        sentence = sentence.replace(a, b)
    return sentence


def pick_up(root: Path) -> int:
    """`core/lease.sh adopt --all-unfinished`: see "pick it up" above. Prints one line per window made (adopt's own
    sentence), one per thing left with what to do, and a last line; exit 1 when anything was left."""
    import leaselib as ll
    repos = target_repos(root)
    try:
        trunks = ll.trunks_of(root, root / "target") if repos else {}
    except ll.Refused as e:
        sys.stderr.write("daedalus: %s\n" % e)
        return 1
    ver = version(root) or "this release"
    for _key, p in repos:
        ll.fetch_origin(p, timeout=60)     # judged against origin as last fetched when this cannot finish
    said: List[str] = []
    left: List[str] = []
    found = False
    for key, p in repos:
        trunk = trunks[key]
        busy_locks = [f for f in _leftover_locks(root, p, 0) if f not in _leftover_locks(root, p)]
        if busy_locks:      # a git command may be running there now: never read a tree it is half-way through
            left.append("a git command may still be running in target/%s (%s) — wait a moment, then say 'pick it up' "
                        "again" % (key, ", ".join(busy_locks)))
            continue
        try:
            cut = _cut_off(root, p, key, trunk, ver, "Pick it up", False)
            if cut:
                said.append(cut[len("Pick it up: "):])
            _gate_checks(root, p, key, trunk, ver)
            items = unfinished(root, key, p, trunk, list(trunks), None, ver)
        except Stop as e:
            left.append(_for_pick(str(e)))
            continue
        found = found or bool(items)
        busy = [i for i in items if i["kind"] == "busy"]
        hidden = next((i for i in items if i["kind"] == "hidden"), None)
        if busy:
            b = busy[0]
            left.append(PICK_BISECT % (key, key) if b["what"] == "bisect"
                        else PICK_BUSY % (key, b["what"], key, b["cmd"], key, b["cmd"]))
            continue
        if hidden:
            if hidden["hidden"]:
                marks, named, cmds = ll.hidden_words(key, hidden["hidden"])
                how = "in files marked %s (%s): clear the mark (%s), then say 'pick it up' again" % (marks, named, cmds)
            elif hidden["filtered"]:
                how = ("in files whose line endings or contents git changes when it saves them (%s): their bytes on "
                       "disk are in no commit — copy those files out of that checkout, put the committed version back "
                       "(%s), then say 'pick it up' again and copy your files into its window"
                       % (ll.name_paths(hidden["filtered"]), ll.put_back(key, hidden["filtered"])))
            else:
                how = ("in files whose content changed while their size and times stayed as git last saw them (%s): "
                       "have git look at them again ((cd target/%s && touch %s)), then say 'pick it up' again"
                       % (ll.name_paths(hidden["blind"]), key, ll.shell_paths(hidden["blind"])))
            left.append(PICK_HIDDEN % (key, hidden["words"].split(" git status")[0], how))
            continue
        try:
            said += _pick_repo(root, key, p, trunk, items, ver, left)
        except (ll.Refused, Stop) as e:
            left.append(_for_pick(str(e)))
        for i in items:
            if i["kind"] == "clone":
                left.append(PICK_CLONE % (key, i["path"], key))
            elif i["kind"] == "worktree":
                left.append(PICK_WORKTREE % (key, i["path"], key, shlex.quote(i["path"]), key))
    for s in said:
        print(s)
    for s in left:
        print(s if s.endswith(".") else s + ".")
    pend = pending(root)
    if not left and pend:
        # the stop it answered is dealt with: the board and every no-window line go back to "the next start finishes
        # it" (update-command Decision 9), never the stale "Say 'pick it up'"
        rec = _read_json(root / STOPPED) or {}
        if str(rec.get("sentence", "")).startswith(UNFINISHED.split("%s", 1)[0]):
            try:
                (root / STOPPED).unlink()
            except OSError:
                pass
    if left:
        print("That stays where it is until it is done; then say 'pick it up' again%s."
              % (" — the upgrade finishes at the first session start that finds nothing unfinished" if pend else ""))
        return 1
    if not found:
        print("Nothing unfinished in target/ to pick up.%s" % (" Start a new session and the upgrade finishes."
                                                                if pend else ""))
        return 0
    print("Everything unfinished in target/ is in windows now.%s"
          % (" Start a new session and the upgrade finishes." if pend else ""))
    return 0


# --- the safety copy: the upgrade is recoverable by construction -----------------------------------------------
# Three rounds of review each found another shape of work in target/ the upgrade could lose or hide; patching each
# shape did not converge. So before its first change to anything under target/, the upgrade copies everything there
# to state/upgrade-snapshot/<stamp>/ and checks the copy: for every repository (outer, nested, submodule — found by
# walking target/ and asking git, never from config alone) (a) a git bundle of every ref, every worktree's HEAD,
# every stash entry, every commit a reflog reached in the last REFLOG_DAYS days or a branch's reflog holds at all (all
# read through git, so a reftable repository's are seen) and each worktree's staged content as a commit, under
# refs/upgrade-snapshot/* in the bundle only, never in the repository; (b) a tar of every file a working tree holds
# that git does not track (untracked and ignored) or that differs from its last commit, for the checkout and every
# linked worktree;
# (c) git's in-progress files (index, rebase, merge, cherry-pick, revert, bisect); (d) manifest.json with every
# ref's sha and every file's sha256. Each bundle is checked with git bundle verify and its list of heads; the
# tar is read back and every file hashed again. A copy that cannot be written or checked, or would be over
# upgrade.snapshot_max_mb, stops the upgrade before anything changes. A later run copies only what no kept copy
# holds (its bundle builds on their commits); it skips the copy only when the kept copies really hold everything —
# never on a record of how a run left target/, which another session may have changed after the copy was checked.
# Nothing deletes a copy but --forget-snapshot, and only when everything in it is still reachable from a ref, not
# merely from a reflog that will expire. The per-shape fixes stay: they make the copy
# needed less often.
SNAPS = Path("state") / "upgrade-snapshot"
SNAP_RECORD = Path("state") / "upgrade-snapshot.json"     # the newest copy, and target/'s state the copies hold
BACKGROUND = Path("state") / "upgrade-background.json"    # a detached run: its pid while running, then how it ended
UPGRADE_LOG = Path("state") / "upgrade.log"
RESTORE = Path("state") / "upgrade-restore"
SNAP_MAX_MB = 2048
REFLOG_DAYS = 30
BG_BYTES = 256 << 20     # at a session start, a copy estimated bigger than this is taken by a detached run at once
SNAP_REF = "refs/upgrade-snapshot/"
GIT_STATE = ("rebase-merge", "rebase-apply", "sequencer", "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE",
             "CHERRY_PICK_HEAD", "REVERT_HEAD", "ORIG_HEAD", "index")
SNAP_BIG = ("upgrade to %s incomplete: before it changes anything in target/ it keeps a safety copy of it, and that "
            "copy would be about %s, over the %d MB limit (upgrade.snapshot_max_mb in config.yaml)%s — raise the limit, "
            "or remove files target/ does not need (ignored build output counts), then start a session again")
SNAP_DISK = ("upgrade to %s incomplete: before it changes anything in target/ it keeps a safety copy of it, about %s, "
             "and the disk has %s free — free some space, then start a session again")
SNAP_FAIL = ("upgrade to %s incomplete: the safety copy of target/ it keeps before changing anything could not be %s "
             "(%s) — nothing in target/ was changed; if it stops the same way again, ask this home's agent to look "
             "into the reason given")
SNAP_BG = ("The upgrade to %s needs a few minutes the first time; it runs in the background and the board will say "
           "when it is done")
SNAP_BG_FAIL = ("upgrade to %s incomplete: the safety copy of target/ it keeps before changing anything takes longer "
                "than a session start allows, and it could not be started in the background (%s) — run python3 "
                "core/upgrade.py once from a terminal in this home")
SNAP_SLOW = ("upgrade to %s incomplete: its safety copy of target/ is taken, but reading target/ to check it against "
             "that copy takes longer than a session start allows, so a session start cannot finish the upgrade — run "
             "python3 core/upgrade.py once from a terminal in this home, which has no time limit; nothing in target/ "
             "was changed")
SNAP_BG_GONE = ("upgrade to %s incomplete: the run in the background ended before it finished (state/upgrade.log "
                "says how far it got); it runs again at the next session start")
SNAP_LINE = ("A safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/%s; nothing "
             "was lost, but if anything looks missing, core/upgrade.py --restore-help lists it")
SNAP_BG_COPIED = ("The upgrade to %s took its safety copy of target/ in the background; it finishes at the next "
                  "session start in this home")
# The stop-command rule (update-command Decisions 10 and 23): every command a stop sentence names must work in the
# state that stop leaves — the upgrade not stamped, so no window opens and nobody holds the pen — run by whoever the
# sentence asks: "operator" from a terminal in this home, "agent" from a session holding no window, "both".
# START is "start a session again" (the operator starts one; its start runs the upgrade); the --caller update wording
# (_for_update) turns it into UPDATE. A sentence naming no command maps to (). Placeholders are filled from the
# stop's own words: {repo} a target repository (thing), {trunk}, {branch}, {new} a new branch name, {sha}, {path},
# {elsewhere}, {locks}, {cmd} the git command the sentence names, {nn} a window number.
# test_upgrade_stop_commands.bats runs each in that state, and fails on a stop constant missing here.
START = "start a session again"
_UPGRADE_CLI = ("operator", "python3 core/upgrade.py")
STOP_COMMANDS: Dict[str, Tuple[Tuple[str, str], ...]] = {
    "SNAP_BIG": (("operator", START), ("both", "core/promote.sh {nn} --clean")),
    "SNAP_DISK": (("operator", START),),
    "SNAP_FAIL": (),
    "SNAP_BG_FAIL": (_UPGRADE_CLI,),
    "SNAP_SLOW": (_UPGRADE_CLI,),
    "SNAP_BG_GONE": (("operator", START),),
    "STOPPED_WHILE": (("operator", START),),
    "STOPPED_TIME": (("operator", START), _UPGRADE_CLI),
    "UNFINISHED": (("agent", "core/lease.sh adopt --all-unfinished"), ("operator", START)),
    "UNTRACKED": (("operator", "mv target/{repo}/{path} {elsewhere}"), ("operator", START)),
    "GITLINK": (("operator", "mv target/{repo}/{path} {elsewhere}"), ("operator", START)),
    "SHADOW": (("operator", "git -C target/{repo} branch -m origin/{trunk} {new}"), ("operator", START)),
    "LOCKS_LEFT": (("operator", "rm {locks}"), ("operator", START)),
    "UNBORN": (("operator", "git -C target/{repo} branch {branch} {sha}"), ("operator", START)),
    "TWINS": (("operator", "git -C target/{repo} pack-refs --all"),
              ("operator", "git -C target/{repo} branch -m {branch} {new}"), ("operator", START)),
    "CUT_WAIT": (("operator", START),),
    "CUT_OTHER": (("operator", "git -C target/{repo} {cmd}"), ("operator", START)),
    "_NO_WORKTREE": (("operator", START),),
}
# stops only a session start reaches (its deadline, or the run in the background it hands the copy to): never said to
# the terminal of `daedalus update`, so their wording keeps "session start"
SESSION_ONLY = ("SNAP_BG_FAIL", "SNAP_SLOW", "SNAP_BG_GONE", "STOPPED_TIME")
# a package directory a lockfile beside it rebuilds is no work: the copy skips its untracked and ignored files and
# records it with the command that rebuilds it (update-command Decision 8). (directory name, ((lockfile, command), ...))
REBUILD = ((".venv", (("uv.lock", "uv sync --frozen"), ("pyproject.toml", "uv sync"))),
           ("node_modules", (("pnpm-lock.yaml", "pnpm install --frozen-lockfile"), ("package-lock.json", "npm ci"),
                             ("yarn.lock", "yarn install --frozen-lockfile"))))
SNAP_SKIPPED = "Not copied, rebuilt from a lockfile: %s."
# --progress: one line on stderr about this often while the copy is written (UPGRADE_TEST_PROGRESS_SECONDS, a test
# knob, can only shorten it)
PROGRESS_SECONDS = 10.0
_PROGRESS: Dict[str, float] = {"on": 0, "done": 0, "total": 0, "last": 0.0}
FILE_WORDS = {"untracked": "untracked file", "ignored": "ignored file", "changed": "uncommitted change to file",
              "unlisted": "file"}
SNAP_NOTHING = ("every branch, tag, stash entry, recent commit and file it holds is still in target/ or in a window")


class _SnapFail(Exception):
    """The copy could not be made: (verb, reason) — "written" or "checked" or "read"."""


class _Background(Exception):
    """The copy will not fit in this session start's budget: a detached run takes it. slow: the start ran out of time
    reading target/ to compare it with the kept copies, before it knew of anything new to copy."""

    def __init__(self, slow: bool = False) -> None:
        super().__init__()
        self.slow = slow


def _gb(args: List[str], inp: Optional[bytes] = None, deadline: Optional[float] = None,
        env_extra: Optional[Dict[str, str]] = None) -> Tuple[int, bytes, str]:
    """git <args>, bytes out. Never takes an optional lock (no index refresh): the copy changes nothing it copies.
    Under a deadline, a call that outlives it is out of time. With core.fsmonitor off (leaselib.NO_RECURSE): a monitor
    hook that reports no change kept an uncommitted edit out of the copy (release-candidate red team 3, finding 2)."""
    import leaselib as ll
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0", **(env_extra or {}))
    timeout = 3600.0
    if deadline is not None:
        timeout = deadline - time.time()
        if timeout <= 0:
            raise _OutOfTime()
    try:
        r = subprocess.run(["git"] + list(ll.NO_RECURSE) + args, input=inp, capture_output=True, env=env,
                           timeout=timeout, stdin=None if inp is not None else subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise _OutOfTime()
    except (OSError, subprocess.SubprocessError) as e:
        return 127, b"", str(e)
    return r.returncode, r.stdout, r.stderr.decode("utf-8", "replace")


def _snap_late(deadline: Optional[float]) -> bool:
    """Out of this session start's time — or, as a test knob that can only make a start give up sooner,
    UPGRADE_TEST_SNAPSHOT_SLOW set (never in a detached run, which has no deadline)."""
    if deadline is None:
        return False
    return bool(os.environ.get("UPGRADE_TEST_SNAPSHOT_SLOW")) or time.time() >= deadline


def _z(out: bytes) -> List[str]:
    return [os.fsdecode(x) for x in out.split(b"\0") if x]


def _common_dir(args: List[str]) -> Optional[str]:
    code, out, _ = _gb(args + ["rev-parse", "--path-format=absolute", "--git-common-dir"])
    if code != 0 or not out.strip():
        return None
    return os.path.realpath(os.fsdecode(out.rstrip(b"\n")))


def _rel(root: Path, path: str) -> str:
    try:
        return str(Path(path).relative_to(root))
    except ValueError:
        return path


def _repo_at(d: str) -> Optional[Tuple[str, str]]:
    """(common git directory, git directory) of the repository whose checkout is exactly <d> — never the repository
    above it, which git finds when <d>'s own .git is not usable. None when <d> is no checkout's root."""
    code, out, _ = _gb(["-C", d, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir",
                        "--absolute-git-dir"])
    parts = os.fsdecode(out).split("\n") if code == 0 else []
    if len(parts) < 3 or os.path.realpath(parts[0]) != os.path.realpath(d):
        return None
    return os.path.realpath(parts[1]), os.path.realpath(parts[2])


def _snap_repos(root: Path) -> List[dict]:
    """Every git repository the upgrade could reach, once each (one entry per common git directory), found from
    what is there, never from config alone: every directory with a .git found by walking target/ (and through
    each symlink directly in it — target/<repo> may be one; each real directory once), every repository the
    upgrade's steps act on
    (target_repos), and, until nothing new turns up, for each repository found: every one of its worktrees walked
    the same way (a window's, or one made by hand anywhere, with a repository cloned inside it), the submodules
    git submodule status --recursive names in each worktree, and the submodule git directories under .git/modules
    and .git/worktrees/<id>/modules that have no checkout now. {"label", "common", "work"}; work is the main
    checkout, or None for a git directory with none."""
    tgt = root / "target"
    if not tgt.is_dir():
        return []
    walked: Set[str] = set()

    def walk(top: str) -> List[str]:
        found = []
        for dirpath, dirnames, filenames in os.walk(top):
            real = os.path.realpath(dirpath)
            if real in walked:
                dirnames[:] = []
                continue
            walked.add(real)
            # .GIT is .git where git ignores case (macOS's default)
            if any(n.casefold() == ".git" for n in dirnames + filenames):
                found.append(dirpath)
            dirnames[:] = [d for d in dirnames if d.casefold() != ".git"]
        return found

    repos: Dict[str, dict] = {}
    found = walk(str(tgt))
    for name in sorted(os.listdir(str(tgt))):
        if os.path.islink(str(tgt / name)) and os.path.isdir(str(tgt / name)):
            found += walk(str(tgt / name))
    if (root / "worktrees").is_dir():
        # a worktree someone made there by hand and then moved or renamed with mv: git's record still names the old
        # path, and the checkout still works through its .git file (safety-copy review 4, findings 1 and 5)
        found += walk(str(root / "worktrees"))
    cands: List[str] = sorted(found, key=lambda q: (len(Path(q).parts), q))
    cands += [str(p) for _, p in target_repos(root)]
    moved: Dict[str, Dict[str, str]] = {}      # common git directory: {a worktree's git directory: where it is now}
    done = 0
    while True:
        while done < len(cands):
            c = cands[done]
            done += 1
            at = _repo_at(c)
            if at is None:
                continue
            common, gd = at
            if gd != common:
                try:
                    rec = (Path(gd) / "gitdir").read_text().strip()
                except OSError:
                    rec = ""
                if rec and os.path.realpath(os.path.dirname(rec)) != os.path.realpath(c):
                    moved.setdefault(common, {})[gd] = c
            if common in repos:
                continue
            work: Optional[str] = c
            if gd != common:         # a linked worktree: the repository's main checkout is its first worktree
                first = (_worktree_list(["--git-dir", common]) or [{}])[0]
                main = first.get("worktree", "")
                work = main if main and "bare" not in first and (_repo_at(main) or ("",))[0] == common else None
            repos[common] = {"label": _rel(root, work or c), "common": common, "work": work}
            for w in _worktree_list(["--git-dir", common]):
                wp = w.get("worktree", "")
                if "bare" in w or not wp or not os.path.isdir(wp):
                    continue
                if wp == common:     # a submodule's main worktree is listed as its git directory
                    if not work:
                        continue
                    wp = work
                cands += walk(wp)
                if os.path.isfile(os.path.join(wp, ".gitmodules")):
                    code, out, _ = _gb(["-C", wp, "submodule", "status", "--recursive"])
                    for ln in (os.fsdecode(out).splitlines() if code == 0 else []):
                        parts = ln[1:].split(" ", 1)
                        if len(parts) != 2:
                            continue
                        rel = parts[1]
                        if rel.endswith(")") and " (" in rel:
                            rel = rel.rsplit(" (", 1)[0]
                        if os.path.exists(os.path.join(wp, rel, ".git")):
                            cands.append(os.path.join(wp, rel))
        before = len(repos)
        for common in list(repos):
            tops = [os.path.join(common, "modules")] + sorted(str(x) for x in Path(common).glob("worktrees/*/modules"))
            for top in tops:
                for dirpath, dirnames, filenames in os.walk(top):
                    if "HEAD" in filenames and "objects" in dirnames and "refs" in dirnames:
                        cm = _common_dir(["--git-dir", dirpath])
                        if cm and cm not in repos:
                            repos[cm] = {"label": _rel(root, cm), "common": cm, "work": None}
                            for w in _worktree_list(["--git-dir", cm]):
                                wp = w.get("worktree", "")
                                if "bare" not in w and wp and wp != cm and os.path.isdir(wp):
                                    cands += walk(wp)
                        dirnames[:] = [d for d in dirnames if d == "modules"]
        if len(repos) == before and done == len(cands):
            break
    for common, m in moved.items():
        if common in repos:
            repos[common]["moved"] = m
    return list(repos.values())


def _g(repo: dict) -> List[str]:
    return ["-C", repo["work"]] if repo["work"] else ["--git-dir", repo["common"]]


def _worktree_list(g: List[str]) -> List[Dict[str, str]]:
    code, out, _ = _gb(g + ["worktree", "list", "--porcelain", "-z"])
    wts: List[Dict[str, str]] = []
    cur: Dict[str, str] = {}
    for tok in (out.split(b"\0") if code == 0 else []):
        if not tok:
            if cur:
                wts.append(cur)
            cur = {}
            continue
        k, _, val = os.fsdecode(tok).partition(" ")
        cur[k] = val
    if cur:
        wts.append(cur)
    return wts


def _ref_format(g: List[str]) -> str:
    """files or reftable (git rev-parse --show-ref-format; a git too old to say has only files)."""
    code, out, _ = _gb(g + ["rev-parse", "--show-ref-format"])
    return os.fsdecode(out).strip() if code == 0 and out.strip() else "files"


def _reflogs(g: List[str], deadline: Optional[float] = None,
             since: Optional[float] = None) -> Optional[List[Tuple[str, str, int, str]]]:
    """(ref, sha, unix time, message) for every reflog entry of the repository, every worktree's HEAD included, as
    git reads them — a reftable repository has no logs/ directory to read. Each entry's value before it too, at that
    entry's time: a commit a branch moved off today is kept by today's entry as its old value, however old its own
    entry is. git log -g prints only new values, so the old one is the next older entry's new value, and the oldest
    entry's is <ref>@{<count>}, which git resolves to it (asked only when that entry is <since> or newer, or is a
    branch's, whose every entry the copy keeps: _snap_collect). None
    when git cannot read them."""
    code, out, _ = _gb(g + ["log", "-g", "--all", "--date=unix", "--format=%H%x01%gD%x01%gs"], deadline=deadline)
    if code != 0:
        return None
    code2, out2, _ = _gb(g + ["log", "-g", "--all", "--format=%gD"], deadline=deadline)
    dated = [ln for ln in os.fsdecode(out).split("\n") if ln.count("\x01") >= 2]
    sels = [ln for ln in os.fsdecode(out2).split("\n") if ln] if code2 == 0 else []
    entries = []
    per_ref: Dict[str, List[Tuple[int, str, int, str]]] = {}     # raw ref: [(index, sha, time, label)]
    for k, ln in enumerate(dated):
        sha, sel, msg = ln.split("\x01", 2)
        ref, _, ts = sel.rpartition("@{")
        try:
            t = int(ts.rstrip("}"))
        except ValueError:
            continue
        wt = re.match(r"worktrees/([^/]+)/HEAD$", ref)
        label = "HEAD of worktree %s" % wt.group(1) if wt else ref
        entries.append((label, sha, t, msg))
        idx = None
        if len(sels) == len(dated):
            r2, _, n = sels[k].rpartition("@{")
            if r2 == ref and n.rstrip("}").isdigit():
                idx = int(n.rstrip("}"))
        lst = per_ref.setdefault(ref, [])
        lst.append((len(lst) if idx is None else idx, sha, t, label))
    for ref, lst in per_ref.items():
        lst.sort()
        for i, (n, sha, t, label) in enumerate(lst):
            if i + 1 < len(lst):
                entries.append((label, lst[i + 1][1], t, "the value before: %s" % ref))
            elif since is None or t >= since or ref.startswith("refs/heads/"):
                code, o, _ = _gb(g + ["rev-parse", "-q", "--verify", "%s@{%d}^{object}" % (ref, n + 1)],
                                 deadline=deadline)
                old = os.fsdecode(o).strip()
                if code == 0 and old.strip("0"):
                    entries.append((label, old, t, "the value before: %s" % ref))
    return entries


def _stash_list(g: List[str], deadline: Optional[float] = None) -> Optional[List[Tuple[int, str, str]]]:
    """(n, sha, message) of every stash entry, stash@{n}, as git lists them (so a reftable repository's are seen
    too). None when git cannot read them."""
    if _gb(g + ["rev-parse", "-q", "--verify", "refs/stash"], deadline=deadline)[0] != 0:
        return []
    code, out, _ = _gb(g + ["log", "-g", "--format=%H%x01%gs", "refs/stash", "--"], deadline=deadline)
    if code != 0:
        return None
    lines = [ln.split("\x01", 1) for ln in os.fsdecode(out).split("\n") if "\x01" in ln]
    return [(i, sha, msg) for i, (sha, msg) in enumerate(lines)]


def _reflogs_files(common: str) -> List[Tuple[str, str, int, str]]:
    """_reflogs read from a files repository's logs/ directly — only when git itself could not read them."""
    out = []
    files = []
    base = Path(common) / "logs"
    for dirpath, _, filenames in os.walk(str(base)):
        for f in filenames:
            files.append((str(Path(dirpath, f).relative_to(base)), Path(dirpath, f)))
    for hp in sorted((Path(common) / "worktrees").glob("*/logs/HEAD")):
        files.append(("HEAD of worktree %s" % hp.parent.parent.name, hp))
    for ref, path in files:
        try:
            data = path.read_bytes()
        except OSError:
            continue
        for ln in data.split(b"\n"):
            head, _, msg = ln.partition(b"\t")
            parts = head.split(b" ")
            if len(parts) < 4:
                continue
            try:
                ts = int(parts[-2])
            except ValueError:
                continue
            for sha in (parts[0], parts[1]):
                s = sha.decode("ascii", "replace")
                if s.strip("0"):
                    out.append((ref, s, ts, os.fsdecode(msg)))
    return out


def _stash_list_files(common: str) -> List[Tuple[int, str, str]]:
    """_stash_list read from a files repository's logs/refs/stash — only when git itself could not read it."""
    try:
        lines = [ln for ln in (Path(common) / "logs" / "refs" / "stash").read_bytes().split(b"\n") if ln.strip()]
    except OSError:
        return []
    out = []
    for i, ln in enumerate(reversed(lines)):
        head, _, msg = ln.partition(b"\t")
        parts = head.split(b" ")
        if len(parts) >= 2:
            out.append((i, parts[1].decode("ascii", "replace"), os.fsdecode(msg)))
    return out


def _own_refs_files(g: List[str], admin: str, deadline: Optional[float]) -> bytes:
    """A linked worktree's own refs read from the files under its record's refs/ — only when git cannot read that
    record (its commondir or HEAD broken) — as for-each-ref prints them; one naming no object here is left out."""
    found = []
    for top in ("worktree", "bisect", "rewritten"):
        for dp, _, fns in os.walk(os.path.join(admin, "refs", top)):
            for f in fns:
                try:
                    sha = Path(dp, f).read_text().strip()
                except (OSError, UnicodeDecodeError):
                    continue
                if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", sha):
                    found.append((sha, os.path.relpath(os.path.join(dp, f), admin)))
    if not found:
        return b""
    code, out, _ = _gb(g + ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
                       inp="".join(sha + "\n" for sha, _ in found).encode(), deadline=deadline)
    types = dict(ln.split(" ", 1) for ln in os.fsdecode(out).splitlines() if " " in ln) if code == 0 else {}
    return "".join("%s %s %s\n" % (sha, types[sha], name) for sha, name in found if sha in types).encode()


def _wt_at(w: dict) -> str:
    """Where a copied worktree's files are: where its checkout is now (moved with mv), else its recorded path."""
    return w.get("at") or w["path"]


def _git_entries(top: str, own_copy) -> List[str]:
    """Every entry under the checkout at <top> whose name is .git in any case — never <top>'s own .git — below a
    directory that is not a repository a copy holds (own_copy), relative to <top>. git lists none of them: it never
    names an entry called .git, and where it ignores case not .GIT either."""
    found = []
    for dp, dns, fns in os.walk(top):
        names = [n for n in dns + fns if n.casefold() == ".git" and not (dp == top and n == ".git")]
        if dp != top and names and own_copy(dp):
            dns[:] = []
            continue
        found += [os.path.relpath(os.path.join(dp, n), top) for n in names]
        dns[:] = [d for d in dns if d.casefold() != ".git"]
    return found


def _all_files(top: str) -> List[str]:
    """Every file and symlink under <top> (a .git inside included), relative to it; links are not followed."""
    out = []
    for dp, dns, fns in os.walk(top):
        for d in dns:
            if os.path.islink(os.path.join(dp, d)):
                fns.append(d)
        for f in fns:
            out.append(os.path.relpath(os.path.join(dp, f), top))
    return out


def _snap_collect(root: Path, repo: dict, deadline: Optional[float], known: Optional[Set[str]] = None) -> dict:
    """What the copy of one repository holds, read without changing anything: refs, worktrees, the files to tar
    (with lstat), git's in-progress files. Content is read only when written. <known>: the common git directories
    of every repository being copied — a directory git lists as another repository is left to that one's own copy
    only when it is among them; otherwise every file in it, its .git included, is in this one's tar."""
    known = known or set()

    def own_copy(d: str) -> bool:
        at = _repo_at(d) if os.path.lexists(os.path.join(d, ".git")) else None
        return at is not None and at[0] in known
    g = _g(repo)
    common = repo["common"]
    label = repo["label"]
    code, out, err = _gb(g + ["for-each-ref", "--format=%(objectname) %(objecttype) %(refname)"], deadline=deadline)
    if code != 0:
        raise _SnapFail("read", "git could not list the refs of %s: %s" % (label, _last(err)))
    refs: List[dict] = []
    for ln in os.fsdecode(out).splitlines():
        sha, typ, name = (ln.split(" ", 2) + ["", ""])[:3]
        kind = ("branch" if name.startswith("refs/heads/") else "tag" if name.startswith("refs/tags/") else
                "remote" if name.startswith("refs/remotes/") else "stash" if name == "refs/stash" else "other")
        refs.append({"name": name, "sha": sha, "type": typ, "kind": kind})
    # git's record of each linked worktree (<common>/worktrees/<id>), by the path it records — read whether or not
    # that path is there: a worktree moved with mv (or by a `git worktree move` cut off after its rename) keeps its
    # staged content, its in-progress state and its own refs there, and the upgrade's prune of records under
    # worktrees/ deleted them (safety-copy review 4, findings 1, 4 and 5)
    records: Dict[str, str] = {}
    try:
        ids = sorted(os.listdir(os.path.join(common, "worktrees")))
    except OSError:
        ids = []
    for wid in ids:
        a = os.path.realpath(os.path.join(common, "worktrees", wid))
        try:
            rec = Path(a, "gitdir").read_text().strip()
        except OSError:
            rec = ""
        if os.path.isdir(a):
            records.setdefault(os.path.realpath(os.path.dirname(rec)) if rec else "\0" + a, a)
    moved = repo.get("moved") or {}
    listed = _worktree_list(g)
    seen: Set[str] = set()
    for i, w in enumerate(listed):
        if i > 0 and w.get("worktree"):
            seen.add(records.get(os.path.realpath(w["worktree"]), ""))
    for key, a in records.items():         # a record git does not list (its gitdir file unreadable): copied all the same
        if a not in seen:
            code, o, _ = _gb(["--git-dir", a, "rev-parse", "-q", "--verify", "HEAD"], deadline=deadline)
            listed.append({"worktree": "" if key.startswith("\0") else key, "HEAD": os.fsdecode(o).strip()
                           if code == 0 else "", "admin": a})
    wts = []
    for i, w in enumerate(listed):
        path = w.get("worktree", "")
        if i == 0 and repo["work"] and "bare" not in w:
            path = repo["work"]      # a submodule's main worktree is listed as its git directory
        bare = "bare" in w
        exists = bool(path) and not bare and Path(path).is_dir()
        head = w.get("HEAD", "")
        admin = w.get("admin") or (records.get(os.path.realpath(path), "") if i > 0 and path else "")
        wt = {"i": i, "path": path or admin, "head": head if head.strip("0") else "", "branch": w.get("branch", ""),
              "exists": exists}
        if admin:
            wt["admin"] = admin
            if not exists and admin in moved and Path(moved[admin]).is_dir():
                wt["at"] = moved[admin]      # where the checkout is now; its files are copied from there
        wts.append(wt)
        path = wt["path"]
        if head.strip("0"):
            refs.append({"name": "HEAD", "sha": head, "type": "commit", "kind": "head", "worktree": path,
                         "branch": w.get("branch", "")})
        if i > 0 and (admin or exists):     # a linked worktree's own refs (bisect, worktree-local) only it lists
            c2, o2, _ = _gb((["--git-dir", admin] if admin else ["-C", path]) + [
                "for-each-ref", "--format=%(objectname) %(objecttype) %(refname)", "refs/bisect/", "refs/worktree/",
                "refs/rewritten/"], deadline=deadline)
            if c2 != 0 and admin:
                o2 = _own_refs_files(g, admin, deadline)      # a record git cannot read: its ref files, read directly
            for ln in (os.fsdecode(o2).splitlines() if c2 == 0 or admin else []):
                sha, typ, name = (ln.split(" ", 2) + ["", ""])[:3]
                refs.append({"name": name, "sha": sha, "type": typ, "kind": "other", "worktree": path})
    cutoff = time.time() - REFLOG_DAYS * 86400
    stashes = _stash_list(g, deadline)
    fmt = _ref_format(g)
    # a files repository's logs/ is read directly below; git is asked for the oldest entries' old values otherwise
    logs = _reflogs(g, deadline, cutoff if fmt != "files" else float("inf"))
    if stashes is None or logs is None:
        if fmt != "files":      # nothing else to read: a copy without them would lose them unseen
            raise _SnapFail("read", "git could not read the stash and reflogs of %s (a %s repository)" % (label, fmt))
        stashes = _stash_list_files(common) if stashes is None else stashes
        logs = _reflogs_files(common) if logs is None else logs
    elif fmt == "files":
        logs += _reflogs_files(common)      # every entry's old and new value exactly, as written
    for n, sha, msg in stashes:
        refs.append({"name": "stash@{%d}" % n, "sha": sha, "type": "commit", "kind": "stash-entry", "message": msg})
    have = {r["sha"] for r in refs}
    # a branch's reflog whatever its age: adopting the branch deletes its reflog (update-ref -d), so a commit only an
    # entry older than the window held was in neither the window nor the copy, even where gc.reflogExpireUnreachable
    # is never (release-candidate red team 3, finding 5); HEAD's and the others' last REFLOG_DAYS days
    tips: Dict[str, Tuple[str, bool]] = {}
    for ref, sha, ts, _ in logs:
        if (ts >= cutoff or ref.startswith("refs/heads/")) and sha not in have and (sha not in tips or tips[sha][1]):
            tips[sha] = (ref, ts < cutoff)
    if tips:
        code, out, _ = _gb(g + ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
                           inp="".join(s + "\n" for s in tips).encode(), deadline=deadline)
        types = dict(ln.split(" ", 1) for ln in os.fsdecode(out).splitlines() if " " in ln) if code == 0 else {}
        for sha, (ref, old) in tips.items():
            if types.get(sha) in ("commit", "tag"):
                refs.append(dict({"name": ref, "sha": sha, "type": types[sha], "kind": "reflog"},
                                 **({"older": True} if old else {})))
    commits = sorted({r["sha"] for r in refs if r["type"] == "commit"})
    subjects: Dict[str, str] = {}
    if commits:
        code, out, _ = _gb(g + ["log", "--no-walk=unsorted", "--stdin", "--format=%H%x00%s"],
                           inp="".join(s + "\n" for s in commits).encode(), deadline=deadline)
        for ln in (os.fsdecode(out).splitlines() if code == 0 else []):
            sha, _, subj = ln.partition("\0")
            subjects[sha] = subj
    for r in refs:
        r["subject"] = subjects.get(r["sha"], "")
    files: List[dict] = []
    state: List[dict] = []
    skipped: List[dict] = []
    scratch: Optional[str] = None
    for w in wts:
        if w["i"] == 0:
            gd = common
        elif w.get("admin"):
            gd = w["admin"]
        elif w["exists"]:
            code, out, _ = _gb(["-C", w["path"], "rev-parse", "--absolute-git-dir"], deadline=deadline)
            gd = os.fsdecode(out.rstrip(b"\n")) if code == 0 else ""
        else:
            gd = ""
        if gd and os.path.isdir(gd):
            if w["head"] or os.path.isfile(os.path.join(gd, "index")):
                if scratch is None:
                    scratch = _scratch_repo(common, "collect")
                ix = _index_commit(scratch, common, gd, w["path"], w["i"], deadline)
                if ix:
                    refs.append(dict(ix, name="index of %s" % w["path"], type="commit", kind="index",
                                     worktree=w["path"], subject="the staged changes of %s" % w["path"]))
            names = [n for n in sorted(os.listdir(gd)) if n in GIT_STATE or n.startswith("BISECT_")]
            for n in names:
                full = os.path.join(gd, n)
                walk = [(full, n)] if not os.path.isdir(full) else [
                    (os.path.join(dp, f), os.path.relpath(os.path.join(dp, f), gd))
                    for dp, _, fs in os.walk(full) for f in fs]
                for fp, rel in walk:
                    try:
                        st = os.lstat(fp)
                    except OSError:
                        continue
                    if stat.S_ISREG(st.st_mode):
                        state.append({"w": w["i"], "path": rel, "size": st.st_size, "mtime_ns": st.st_mtime_ns,
                                      "src": fp})
        if not (w["exists"] or w.get("at")):
            continue
        wp = _wt_at(w)
        kinds = _wt_kinds(wp, bool(w["head"]), deadline)
        if kinds is None:
            # a directory git cannot read as a worktree (a cut-off worktree add left it without a usable .git file):
            # git cannot say what it tracks, so every file in it is copied
            kinds = {}
            for dp, dns, fns in os.walk(wp):
                dns[:] = [d for d in dns if not own_copy(os.path.join(dp, d))]
                for d in dns:
                    if os.path.islink(os.path.join(dp, d)):
                        fns.append(d)
                for f in fns:
                    if not (dp == wp and f == ".git"):
                        kinds[os.path.relpath(os.path.join(dp, f), wp)] = "unlisted"
        for p in [q for q in kinds if q.endswith("/")]:
            kind = kinds.pop(p)
            if not own_copy(os.path.join(wp, p.rstrip("/"))):     # a repository no copy holds: all of it, here
                for f in _all_files(os.path.join(wp, p.rstrip("/"))):
                    kinds.setdefault(os.path.join(p.rstrip("/"), f), kind)
        # a .git (any case) git never lists, below a directory that is no repository a copy holds — one git cannot
        # read (its HEAD broken), or a .git file pointing nowhere: every file in it, its commits' objects included
        # (safety-copy review 4, finding 3)
        for e in _git_entries(wp, own_copy):
            full = os.path.join(wp, e)
            for f in (_all_files(full) if os.path.isdir(full) and not os.path.islink(full) else [""]):
                kinds.setdefault(os.path.join(e, f) if f else e, "unlisted")
        rebuild = _rebuildable_dirs(wp, kinds)
        held_back: Dict[str, int] = {}
        for p in sorted(kinds):
            try:
                st = os.lstat(os.path.join(wp, p))
            except OSError:
                continue        # deleted: its content is in the commit
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                continue
            under = _under(p, rebuild) if kinds[p] in ("ignored", "untracked") else None
            if under is not None:
                held_back[under] = held_back.get(under, 0) + st.st_size
                continue
            files.append({"w": w["i"], "path": p, "kind": kinds[p], "size": st.st_size, "mtime_ns": st.st_mtime_ns,
                          "ctime_ns": st.st_ctime_ns, "ino": st.st_ino, "link": stat.S_ISLNK(st.st_mode)})
        skipped += [{"w": w["i"], "path": d, "bytes": n, "rebuild": rebuild[d]} for d, n in sorted(held_back.items())]
    code, out, _ = _gb(["--git-dir", common, "count-objects", "-v"], deadline=deadline)
    kib = 0
    for ln in (os.fsdecode(out).splitlines() if code == 0 else []):
        k, _, val = ln.partition(": ")
        if k in ("size", "size-pack", "size-garbage") and val.strip().isdigit():
            kib += int(val)
    return dict(repo, refs=refs, worktrees=wts, files=files, state=state, pack_bytes=kib * 1024, scratch=scratch,
                skipped=skipped)


def _rebuildable_dirs(wp: str, kinds: Dict[str, str]) -> Dict[str, str]:
    """{directory: the command that rebuilds it} for each .venv or node_modules in the worktree at <wp> whose parent
    holds a lockfile (REBUILD), read from the directory parts of its untracked and ignored paths — never a second walk
    of the tree. The outermost such directory on a path is the one kept."""
    names = dict(REBUILD)
    seen: Dict[str, Optional[str]] = {}
    keep: Dict[str, str] = {}
    for p, kind in kinds.items():
        if kind not in ("ignored", "untracked"):
            continue
        parts = p.split("/")
        for i, part in enumerate(parts[:-1]):
            if part not in names:
                continue
            d = "/".join(parts[:i + 1])
            if d not in seen:
                parent = os.path.join(wp, *parts[:i])
                seen[d] = None if os.path.islink(os.path.join(wp, d)) else next(
                    (cmd for lock, cmd in names[part] if os.path.isfile(os.path.join(parent, lock))), None)
            if seen[d]:
                keep[d] = seen[d] or ""
                break
    return keep


def _under(p: str, dirs: Dict[str, str]) -> Optional[str]:
    """The directory of <dirs> that holds the path <p>, or None."""
    if not dirs:
        return None
    parts = p.split("/")
    for i in range(1, len(parts)):
        d = "/".join(parts[:i])
        if d in dirs:
            return d
    return None


def _snap_largest(root: Path, coll: List[dict]) -> List[Tuple[int, str]]:
    """What a copy of <coll> would hold, in its largest parts first: each repository's history (what a new bundle
    would hold), and the files of each worktree grouped by the directory git names as untracked as a whole (git
    ls-files --others --directory), else one by one. [(bytes, name)]: names relative to the home where they are in it."""
    parts: Dict[str, int] = {}
    seen: Set[str] = set()
    for r in coll:
        if r["common"] not in seen:
            seen.add(r["common"])
            parts["%s history" % r["label"]] = r.get("new_bytes", r["pack_bytes"])
        dirs: Dict[int, Dict[str, str]] = {}
        for f in r["files"]:
            w = r["worktrees"][f["w"]]
            wp = _wt_at(w)
            if f["w"] not in dirs:
                code, out, _ = _gb(["-C", wp, "ls-files", "-z", "--others", "--directory"])
                dirs[f["w"]] = {x.rstrip("/"): "" for x in _z(out) if x.endswith("/")} if code == 0 else {}
            d = _under(f["path"], dirs[f["w"]]) or f["path"]
            name = _rel(root, os.path.join(wp, d))
            parts[name] = parts.get(name, 0) + f["size"]
        for s in r["state"]:
            name = "%s git state" % _rel(root, _wt_at(r["worktrees"][s["w"]]))
            parts[name] = parts.get(name, 0) + s["size"]
    return sorted(((n, k) for k, n in parts.items()), key=lambda x: (-x[0], x[1]))


def _snap_big(root: Path, ver: str, size: int, cap: int, coll: List[dict]) -> str:
    """SNAP_BIG, naming the three largest parts of at least 1 MB, so the operator can tell what to remove."""
    top = [(n, k) for n, k in _snap_largest(root, coll) if n >= (1 << 20)][:3]
    names = ["%s (%s%s)" % (k, _mb(n), _scratch_clean(root, k)) for n, k in top]
    clause = ""
    if len(names) == 1:
        clause = "; the largest is %s" % names[0]
    elif names:
        clause = "; the largest are %s and %s" % (", ".join(names[:-1]), names[-1])
    return SNAP_BIG % (ver, _mb(size), cap, clause)


def _scratch_clean(root: Path, name: str) -> str:
    """For a part of the copy under a pushed promotion's scratch (state/promote/<NN>-.../), the command that removes
    it with no window and no pen (update-command Decision 10b); "" for anything else. The upgrade removes pushed
    scratch before it estimates, so this is a promotion a confirm held then. An unpushed promotion's scratch is not
    named: only the prime removes it, and no window opens until the upgrade finishes; raising the limit is the way."""
    m = re.match(r"state/promote/(([0-9]{2})-[^/]+)/", name)
    if not m:
        return ""
    pdir = root / "state" / "promote" / m.group(1)
    if not ((pdir / "pushed").exists() or (pdir / "announced").exists()):
        return ""
    return ", pushed: core/promote.sh %s --clean removes it" % m.group(2)


def _progress(n: int) -> None:
    """--progress: count <n> more bytes written, and about every PROGRESS_SECONDS say how far the copy is."""
    if not _PROGRESS["on"]:
        return
    _PROGRESS["done"] += n
    every = PROGRESS_SECONDS
    try:
        every = min(every, float(os.environ.get("UPGRADE_TEST_PROGRESS_SECONDS", every)))
    except ValueError:
        pass
    now = time.monotonic()
    if now - _PROGRESS["last"] >= every:
        _PROGRESS["last"] = now
        try:
            sys.stderr.write("safety copy: %d of %d MB\n" % (int(_PROGRESS["done"]) >> 20,
                                                              -(-int(_PROGRESS["total"]) >> 20)))
            sys.stderr.flush()
        except (OSError, ValueError):
            pass


SNAP_IDENT = {"GIT_AUTHOR_NAME": "upgrade safety copy", "GIT_AUTHOR_EMAIL": "upgrade@localhost",
              "GIT_AUTHOR_DATE": "@0 +0000", "GIT_COMMITTER_NAME": "upgrade safety copy",
              "GIT_COMMITTER_EMAIL": "upgrade@localhost", "GIT_COMMITTER_DATE": "@0 +0000"}


def _scratch_repo(common: str, what: str) -> str:
    """A bare repository in the system's temporary directory that borrows <common>'s objects (alternates): where
    the copy writes its own trees and commits, never into the operator's repository. The caller removes it."""
    d = tempfile.mkdtemp(prefix="upgrade-%s-" % what)
    args = ["init", "--bare", "-q"]
    code, out, _ = _gb(["--git-dir", common, "rev-parse", "--show-object-format"])
    if code == 0 and out.strip() and out.strip() != b"sha1":
        args.append("--object-format=%s" % os.fsdecode(out.strip()))
    code, _, err = _gb(args + [d])
    if code != 0:
        shutil.rmtree(d, ignore_errors=True)
        raise _SnapFail("written", "git init: %s" % _last(err))
    (Path(d) / "objects" / "info").mkdir(parents=True, exist_ok=True)
    (Path(d) / "objects" / "info" / "alternates").write_text(os.path.join(common, "objects") + "\n")
    return d


def _index_commit(scratch: str, common: str, gd: str, wp: str, n: int, deadline: Optional[float]) -> Optional[dict]:
    """The content staged in the worktree at <wp> (its index is <gd>/index) that its HEAD does not hold, as a
    commit made in <scratch> — the staged blobs are reachable from no ref, so without it a reset and a gc lose
    them. A copy of the index is read, never the index itself. The commit is made with a fixed author and date,
    so the same staged content always gives the same sha. None when nothing is staged that HEAD lacks.
    {"sha", "tree", "blobs": [[path, blob sha], ...], "conflicted"}."""
    idx = os.path.join(gd, "index")
    if not os.path.isfile(idx):
        return None
    copy = os.path.join(scratch, "index-w%d" % n)
    try:
        shutil.copyfile(idx, copy)
        for sh in Path(gd).glob("sharedindex.*"):        # a split index reads its shared part beside it
            shutil.copyfile(str(sh), os.path.join(scratch, sh.name))
    except OSError as e:
        raise _SnapFail("read", "the index of %s: %s" % (wp, e.strerror or e))
    env = {"GIT_INDEX_FILE": copy}
    code, out, err = _gb(["--git-dir", scratch, "ls-files", "-s", "-z"], env_extra=env, deadline=deadline)
    if code != 0:
        raise _SnapFail("read", "git could not read the index of %s: %s" % (wp, _last(err)))
    entries = []
    for rec in _z(out):
        meta, _, path = rec.partition("\t")
        parts = meta.split(" ")
        if len(parts) == 3:
            entries.append((parts[0], parts[1], parts[2], path))
    head: Dict[str, Tuple[str, str]] = {}
    code, out, _ = _gb(["--git-dir", gd, "ls-tree", "-r", "-z", "--full-tree", "HEAD"], deadline=deadline)
    for rec in (_z(out) if code == 0 else []):
        meta, _, path = rec.partition("\t")
        parts = meta.split(" ")
        if len(parts) == 3:
            head[path] = (parts[0], parts[2])
    staged = [(mode, sha, stage, path) for mode, sha, stage, path in entries
              if mode != "160000" and (stage != "0" or head.get(path) != (mode, sha))]
    if not staged:
        return None
    conflicted = any(stage != "0" for _, _, stage, _ in staged)
    gs = ["--git-dir", scratch]
    tree = ""
    if not conflicted:
        code, out, _ = _gb(gs + ["write-tree"], env_extra=env, deadline=deadline)
        tree = os.fsdecode(out).strip() if code == 0 else ""
    if not tree:        # unmerged (or unreadable as a tree): every staged blob, under its number, in one tree
        lines = "".join("100644 blob %s\t%06d-%s\n" % (sha, k, stage)
                        for k, (_, sha, stage, _) in enumerate(staged))
        code, out, err = _gb(gs + ["mktree"], inp=lines.encode(), deadline=deadline)
        if code != 0:
            raise _SnapFail("written", "the staged changes of %s: %s" % (wp, _last(err)))
        tree = os.fsdecode(out).strip()
    msg = "the staged changes of %s\n\n%s" % (wp, "".join(
        "%06d stage %s: %s\n" % (k, stage, path) for k, (_, _, stage, path) in enumerate(staged)))
    code, out, err = _gb(gs + ["commit-tree", tree, "-F", "-"], inp=msg.encode("utf-8", "surrogateescape"),
                         env_extra=SNAP_IDENT, deadline=deadline)
    if code != 0:
        raise _SnapFail("written", "the staged changes of %s: %s" % (wp, _last(err)))
    return {"sha": os.fsdecode(out).strip(), "tree": tree, "conflicted": conflicted,
            "blobs": sorted({(path, sha) for _, sha, _, path in staged})}


def _drop_scratch(coll: List[dict]) -> None:
    for r in coll:
        if r.get("scratch"):
            shutil.rmtree(r["scratch"], ignore_errors=True)
            r["scratch"] = None


def _wt_kinds(wp: str, head: bool, deadline: Optional[float]) -> Optional[Dict[str, str]]:
    """{path: untracked|ignored|changed} for the files of the worktree at <wp> that its last commit does not hold as
    they are: untracked and ignored ones, and tracked ones that differ from HEAD (a change hidden by skip-worktree
    or assume-unchanged included, and bytes a clean filter or line-ending conversion hides, which no checkout writes
    back). None when git cannot read <wp> as a worktree."""
    lists = {}
    for key, args in (("untracked", ["ls-files", "-z", "--others", "--exclude-standard"]),
                      ("others", ["ls-files", "-z", "--others"]),
                      ("tags", ["ls-files", "-z", "-v"]),
                      ("stage", ["ls-files", "-z", "-s"]),
                      ("changed", ["diff", "--name-only", "-z", "--no-renames", "HEAD", "--"] if head else
                       ["ls-files", "-z"])):
        code, out, _ = _gb(["-C", wp] + args, deadline=deadline)
        if code != 0:
            return None
        lists[key] = _z(out)
    untracked = set(lists["untracked"])
    changed = set(lists["changed"])
    changed |= {t[2:] for t in lists["tags"] if len(t) > 2 and (t[0].islower() or t[0] == "S")}
    kinds: Dict[str, str] = {}
    for p in lists["others"]:
        kinds[p] = "untracked" if p in untracked else "ignored"
    for p in changed:
        kinds.setdefault(p, "changed")
    # a gitlink whose directory holds files and no .git (a submodule vendored by removing its .git): git looks into it
    # neither as this worktree's nor as a repository of its own, so every file in it is copied here (release-candidate
    # red team 3, finding 1); one holding a .git is a repository, copied as one or by _git_entries
    for ent in lists["stage"]:
        meta, _, p = ent.partition("\t")
        d = os.path.join(wp, p)
        if meta.split()[:1] != ["160000"] or os.path.islink(d) or not os.path.isdir(d):
            continue
        try:
            names = os.listdir(d)
        except OSError:
            continue
        if not any(n.casefold() == ".git" for n in names):
            for f in _all_files(d):
                kinds.setdefault(os.path.join(p, f), "unlisted")
    import leaselib as ll
    try:
        # bytes a clean filter or a line-ending conversion hides from git diff: what a checkout would not write back
        for p in ll.filtered_edits(Path(wp), deadline, skip=set(kinds)):
            kinds[p] = "changed"
        # an edit git's stat check passes (core.trustctime false: same size, inode and mtime) — read by content
        for p in ll.stat_blind_edits(Path(wp), deadline, skip=set(kinds)):
            kinds[p] = "changed"
    except subprocess.TimeoutExpired:
        raise _OutOfTime()
    return kinds


# git's files that change while no work does — the index (a read can rewrite it; its staged content is an index ref)
# and ORIG_HEAD (rewritten at every reset; its commit a reflog holds): copied along, never a reason for a new copy
SNAP_ALONG = ("index", "ORIG_HEAD")


def _snap_fp(coll: List[dict]) -> str:
    """target/'s state in one hash: refs (staged content included), every commit a reflog from the last 30 days
    holds (a branch's reflog whatever its age), worktrees, stash, and every copied file's worktree, name, size, times
    and inode — never SNAP_ALONG. Equal hashes: nothing a copy holds has changed (a content change kept at the same size with its mtime set back still
    moves ctime, which no one can set). A commit only a reflog holds counts: one made and undone after a copy (a
    branch moved there and back) moves no ref, and the upgrade's adoption deletes that branch's reflog."""
    parts = []
    for r in coll:
        parts.append([r["common"],
                      sorted((x["name"], x.get("worktree", ""), x["sha"]) for x in r["refs"]),
                      [(w["path"], w["head"], w["branch"], w["exists"], w.get("at", "")) for w in r["worktrees"]],
                      sorted((_wt_at(r["worktrees"][f["w"]]), f["path"], f["kind"], f["size"], f["mtime_ns"],
                              f.get("ctime_ns"), f.get("ino")) for f in r["files"]),
                      sorted((r["worktrees"][s["w"]]["path"], s["path"], s["size"], s["mtime_ns"])
                             for s in r["state"] if s["path"] not in SNAP_ALONG)])
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode("utf-8", "surrogateescape")).hexdigest()


def _snap_estimate(coll: List[dict]) -> int:
    seen: Set[str] = set()
    n = 0
    for r in coll:
        if r["common"] not in seen:
            seen.add(r["common"])
            n += r.get("new_bytes", r["pack_bytes"])
        n += sum(f["size"] for f in r["files"]) + sum(s["size"] for s in r["state"])
    return n


def _kept(root: Path) -> Dict[str, dict]:
    """What the kept copies hold together, by git directory: every ref's sha (and which are commits), every file by
    name and content (and by worktree, name, size, mtime, ctime and inode — the very file a copy read, unchanged,
    which saves hashing it again), every in-progress file by name and content."""
    held: Dict[str, dict] = {}
    for st in _snapshots(root):
        m = _read_json(root / SNAPS / st / "manifest.json") or {}
        for r in m.get("repos", []):
            h = held.setdefault(r.get("git_dir") or "", {"shas": set(), "commits": set(), "stat": set(),
                                                         "files": set(), "state": set()})
            for x in r.get("refs", []):
                h["shas"].add(x["sha"])
                if x.get("type") == "commit" and x.get("kind") != "index":
                    h["commits"].add(x["sha"])
            wtp = {w.get("i"): w.get("at") or w.get("path") for w in r.get("worktrees", [])}
            for f in r.get("files", []):
                h["files"].add((f["path"], f["sha256"]))
                if "ctime_ns" in f and "ino" in f:
                    h["stat"].add((wtp.get(f["w"]), f["path"], f["size"], f["mtime_ns"], f["ctime_ns"], f["ino"]))
            for g in r.get("git_state", []):
                h["state"].add((g["path"], g["sha256"]))
    return held


def _snap_plan(root: Path, coll: List[dict], deadline: Optional[float]) -> Tuple[str, List[dict]]:
    """(target/'s fingerprint, what a new copy must hold). Nothing, when target/ is exactly as a kept copy found it,
    or when the kept copies already hold everything in it: every ref's commit (a kept copy's refs reach it), every
    file under its name with its content, every in-progress file. Otherwise, per repository, only what they do not
    hold — with "basis", the kept commits still in the repository, which a new bundle builds on instead of copying
    the history again. A change made after a copy was checked (another session at work while a run went on) is
    never taken as covered: only what a copy really holds is."""
    fp = _snap_fp(coll)
    rec = _read_json(root / SNAP_RECORD) or {}
    snaps = _snapshots(root)
    if snaps and rec.get("stamp") in snaps and fp == rec.get("covered"):
        return fp, []
    held = _kept(root)
    todo = []
    for r in coll:
        h = held.get(r["common"])
        if h is None:
            todo.append(dict(r, basis=[]))
            continue
        g = _g(r)
        basis: List[str] = []
        if h["commits"]:
            code, out, _ = _gb(g + ["cat-file", "--batch-check=%(objectname) %(objecttype)"],
                               inp="".join(x + "\n" for x in sorted(h["commits"])).encode(), deadline=deadline)
            basis = [ln.split(" ")[0] for ln in os.fsdecode(out).splitlines() if ln.endswith(" commit")] \
                if code == 0 else []
        fresh = sorted({x["sha"] for x in r["refs"]
                        if x["type"] == "commit" and x["kind"] != "index" and x["sha"] not in h["shas"]})
        new = set(fresh)
        if fresh and basis:
            code, out, _ = _gb(g + ["rev-list", "--stdin"], deadline=deadline, inp=(
                "".join(x + "\n" for x in fresh) + "--not\n" + "".join(x + "\n" for x in basis)).encode())
            if code == 0:
                new &= set(os.fsdecode(out).split())
        refs = [x for x in r["refs"] if x["sha"] not in h["shas"]
                and (x["type"] != "commit" or x["kind"] == "index" or x["sha"] in new)]
        files = []
        for f in r["files"]:
            if (_wt_at(r["worktrees"][f["w"]]), f["path"], f["size"], f["mtime_ns"], f["ctime_ns"], f["ino"]) \
                    in h["stat"]:
                continue
            if _snap_late(deadline):
                raise _OutOfTime()
            if (f["path"], _sha256(os.path.join(_wt_at(r["worktrees"][f["w"]]), f["path"]), f["link"])) in h["files"]:
                continue
            files.append(f)
        state = [x for x in r["state"] if x["path"] not in SNAP_ALONG
                 and (x["path"], _sha256(x["src"], False)) not in h["state"]]
        if not (refs or files or state):
            continue
        state += [x for x in r["state"] if x["path"] in SNAP_ALONG]
        nb = 0
        news = sorted({x["sha"] for x in refs if x["kind"] != "index" and x["type"] == "commit"})
        if news and basis:
            code, out, _ = _gb(g + ["rev-list", "--objects", "--stdin"], deadline=deadline, inp=(
                "".join(x + "\n" for x in news) + "--not\n" + "".join(x + "\n" for x in basis)).encode())
            objs = "".join(ln.split(" ")[0] + "\n" for ln in os.fsdecode(out).splitlines() if ln) if code == 0 else ""
            code, out, _ = _gb(g + ["cat-file", "--batch-check=%(objectsize:disk)"], inp=objs.encode(),
                               deadline=deadline)
            nb = sum(int(x) for x in os.fsdecode(out).split() if x.isdigit()) if code == 0 else r["pack_bytes"]
        elif news:
            nb = r["pack_bytes"]
        todo.append(dict(r, refs=refs, files=files, state=state, basis=basis, new_bytes=nb))
    if not todo:
        _snap_record(root, fp)
    return fp, todo


def _snap_record(root: Path, fp: str, stamp: Optional[str] = None) -> None:
    """target/'s fingerprint as the kept copies hold all of it (and the newest copy's stamp)."""
    snaps = _snapshots(root)
    if not snaps:
        return
    try:
        _write(root / SNAP_RECORD, json.dumps({"stamp": stamp or snaps[-1], "covered": fp}, indent=2) + "\n")
    except OSError:
        pass


def _mb(n: int) -> str:
    return "under 1 MB" if n < (1 << 20) else "%d MB" % -(-n // (1 << 20))


def _snap_cap(root: Path) -> int:
    val = _cfg(root, "upgrade.snapshot_max_mb")
    return int(val) if val.isdigit() and int(val) > 0 else SNAP_MAX_MB


def _snapshots(root: Path) -> List[str]:
    """The stamps of every finished, checked copy, oldest first (a copy's directory gets its name only then)."""
    try:
        names = os.listdir(str(root / SNAPS))
    except OSError:
        return []
    return sorted(n for n in names if not n.startswith(".") and (root / SNAPS / n / "manifest.json").is_file())


def _read_json(path: Path) -> Optional[dict]:
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


class _Hashing:
    """A file read through tarfile, hashed on the way, looking at the deadline between chunks."""
    def __init__(self, f, deadline: Optional[float]) -> None:
        self.f, self.h, self.deadline = f, hashlib.sha256(), deadline

    def read(self, size: int = -1) -> bytes:
        b = self.f.read(size)
        self.h.update(b)
        _progress(len(b))
        if _snap_late(self.deadline):
            raise _OutOfTime()
        return b


def _name(n: int, label: str) -> str:
    base = label[len("target/"):] if label.startswith("target/") else label
    return "%d-%s" % (n, re.sub(r"[^A-Za-z0-9._-]+", "-", base).strip("-") or "repo")


def _snap_write(root: Path, coll: List[dict], ver: str, fp: str, cap: int, deadline: Optional[float]) -> Tuple[str, int]:
    """Write the copy to state/upgrade-snapshot/.partial-<stamp>, check it, and only then name it <stamp>. Anything
    short of a checked copy is removed: it is this run's own scratch, never a copy anyone relies on."""
    base = root / SNAPS
    try:
        base.mkdir(parents=True, exist_ok=True)
        for old in base.glob(".partial-*"):
            shutil.rmtree(str(old), ignore_errors=True)
    except OSError as e:
        raise _SnapFail("written", "%s: %s" % (SNAPS, e.strerror or e))
    stamp = time.strftime("%Y%m%d-%H%M%S")
    k = 1
    while (base / stamp).exists():
        k += 1
        stamp = "%s-%d" % (time.strftime("%Y%m%d-%H%M%S"), k)
    part = base / (".partial-" + stamp)
    try:
        part.mkdir()
        manifest = {"format": 1, "stamp": stamp, "version": ver, "taken_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                    "fingerprint": fp, "reflog_days": REFLOG_DAYS, "verified": False, "repos": [],
                    "skipped": [{"repo": r["label"], "worktree": _wt_at(r["worktrees"][x["w"]]), "path": x["path"],
                                 "bytes": x["bytes"], "rebuild": x["rebuild"]}
                                for r in coll for x in r.get("skipped", [])]}
        _PROGRESS.update(done=0, total=_snap_estimate(coll), last=time.monotonic())
        for n, r in enumerate(coll, 1):
            if _snap_late(deadline):
                raise _OutOfTime()
            manifest["repos"].append(_snap_repo(part, n, r, deadline))
        _snap_verify(part, manifest)
        size = sum(f.stat().st_size for f in part.iterdir() if f.is_file())
        if size > cap * (1 << 20):
            raise Stop(_snap_big(root, ver, size, cap, coll))
        manifest["verified"] = True
        manifest["size_bytes"] = size
        (part / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
        os.rename(str(part), str(base / stamp))
    except BaseException as e:
        shutil.rmtree(str(part), ignore_errors=True)
        if isinstance(e, OSError):
            raise _SnapFail("written", "%s%s" % (e.strerror or e, " (%s)" % e.filename if e.filename else ""))
        raise
    return stamp, size


def _snap_repo(part: Path, n: int, r: dict, deadline: Optional[float]) -> dict:
    name = _name(n, r["label"])
    entry = {"n": n, "label": r["label"], "path": r["work"], "git_dir": r["common"], "bundle": None,
             "basis": list(r.get("basis") or []),
             "tar": name + ".tar", "worktrees": [dict({"i": w["i"], "path": w["path"], "head": w["head"],
                                                       "branch": w["branch"]},
                                                      **{k: w[k] for k in ("admin", "at") if w.get(k)})
                                                 for w in r["worktrees"]],
             "refs": [], "files": [], "git_state": []}
    by_sha: Dict[str, str] = {}
    for x in r["refs"]:
        if x["sha"] not in by_sha:
            by_sha[x["sha"]] = "%s%04d" % (SNAP_REF, len(by_sha) + 1)
        entry["refs"].append(dict(x, bundle_ref=by_sha[x["sha"]]))
    if by_sha:
        tmp = part / (".git-" + name)
        bundle = part / (name + ".bundle")
        code, _, err = _gb(["init", "--bare", "-q", str(tmp)])
        if code != 0:
            raise _SnapFail("written", "git init: %s" % _last(err))
        (tmp / "objects" / "info").mkdir(parents=True, exist_ok=True)
        (tmp / "objects" / "info" / "alternates").write_text(
            "".join(d + "\n" for d in [os.path.join(r["common"], "objects")]
                    + ([os.path.join(r["scratch"], "objects")] if r.get("scratch") else [])))
        if os.path.isfile(os.path.join(r["common"], "shallow")):
            shutil.copy2(os.path.join(r["common"], "shallow"), str(tmp / "shallow"))
            # a shallow clone's history stops at these commits: its bundle restores only into a repository that
            # says so too — recorded, checked so below, and written by the commands --restore-help prints
            entry["shallow"] = (tmp / "shallow").read_text().split()
        code, _, err = _gb(["-C", str(tmp), "update-ref", "--stdin"],
                           inp="".join("create %s %s\n" % (b, s) for s, b in by_sha.items()).encode())
        if code != 0:
            raise _SnapFail("written", "the refs of %s: %s" % (r["label"], _last(err)))
        # building on kept copies: only what their commits do not reach (git bundle create --all ^<kept>...)
        code, _, err = _gb(["-C", str(tmp), "bundle", "create", "-q", str(bundle), "--all", "--stdin"],
                           inp="".join("^%s\n" % b for b in entry["basis"]).encode(), deadline=deadline)
        if code != 0:
            raise _SnapFail("written", "the bundle of %s: %s" % (r["label"], _last(err)))
        shutil.rmtree(str(tmp), ignore_errors=True)
        _progress(bundle.stat().st_size)
        entry["bundle"] = bundle.name
    paths = {w["i"]: _wt_at(w) for w in r["worktrees"]}
    with tarfile.open(str(part / entry["tar"]), "w", format=tarfile.PAX_FORMAT, encoding="utf-8",
                      errors="surrogateescape") as tar:
        for f in r["files"]:
            src = os.path.join(paths[f["w"]], f["path"])
            member = "w%d/%s" % (f["w"], f["path"])
            entry["files"].append(dict(f, member=member, sha256=_tar_add(tar, src, member, deadline)))
        for s in r["state"]:
            member = "git/w%d/%s" % (s["w"], s["path"])
            entry["git_state"].append({"w": s["w"], "path": s["path"], "size": s["size"], "member": member,
                                       "sha256": _tar_add(tar, s["src"], member, deadline)})
    return entry


def _tar_add(tar: tarfile.TarFile, src: str, member: str, deadline: Optional[float]) -> str:
    if _snap_late(deadline):
        raise _OutOfTime()
    tar.inodes = {}         # a file hard-linked to one already added is still a whole member, never a link to it
    info = tar.gettarinfo(name=src, arcname=member)
    if info is None:
        raise _SnapFail("written", "%s is neither a file nor a link" % src)
    if info.issym():
        tar.addfile(info)
        return hashlib.sha256(os.fsencode(info.linkname)).hexdigest()
    with open(src, "rb") as fh:
        hf = _Hashing(fh, deadline)
        tar.addfile(info, hf)
    return hf.h.hexdigest()


def _snap_verify(part: Path, manifest: dict) -> None:
    """Every bundle passes git bundle verify in an empty repository (so it needs nothing outside itself) and lists
    exactly the refs the manifest gives it; a shallow repository's bundle, which git bundle verify passes even
    though it cannot stand alone, is fetched whole into an empty repository holding only the recorded shallow
    boundary (and, building on kept copies, their objects); every file read back from the tar hashes to the
    manifest's sha256."""
    vt = part / ".verify"
    code, _, err = _gb(["init", "--bare", "-q", str(vt)])
    if code != 0:
        raise _SnapFail("checked", "git init: %s" % _last(err))
    try:
        for r in manifest["repos"]:
            if r["bundle"]:
                b = str(part / r["bundle"])
                where = vt
                if r.get("basis") or r.get("shallow"):
                    where = part / (".verify-%d" % r["n"])
                    code, _, err = _gb(["init", "--bare", "-q", str(where)])
                    if code != 0:
                        raise _SnapFail("checked", "git init: %s" % _last(err))
                    if r.get("basis"):
                        (where / "objects" / "info").mkdir(parents=True, exist_ok=True)
                        (where / "objects" / "info" / "alternates").write_text(
                            os.path.join(r["git_dir"], "objects") + "\n")
                    if r.get("shallow"):
                        (where / "shallow").write_text("".join(x + "\n" for x in r["shallow"]))
                code, _, err = _gb(["-C", str(where), "bundle", "verify", "-q", b])
                if code != 0:
                    raise _SnapFail("checked", "git bundle verify %s: %s" % (r["bundle"], _last(err) or "failed"))
                if r.get("shallow"):
                    code, _, err = _gb(["-C", str(where), "fetch", "-q", b, SNAP_REF + "*:" + SNAP_REF + "*"])
                    if code != 0:
                        raise _SnapFail("checked", "%s does not restore into a repository shallow at the commits "
                                                   "it records: %s" % (r["bundle"], _last(err) or "failed"))
                code, out, err = _gb(["-C", str(where), "bundle", "list-heads", b])
                if where != vt:
                    shutil.rmtree(str(where), ignore_errors=True)
                heads = {tuple(ln.split(" ", 1)[::-1]) for ln in os.fsdecode(out).splitlines() if " " in ln}
                want = {(x["bundle_ref"], x["sha"]) for x in r["refs"]}
                if code != 0 or heads != want:
                    raise _SnapFail("checked", "%s does not list the refs it was given" % r["bundle"])
            want_files = {f["member"]: f["sha256"] for f in r["files"] + r["git_state"]}
            got: Dict[str, str] = {}
            with tarfile.open(str(part / r["tar"]), "r", encoding="utf-8", errors="surrogateescape") as tar:
                for m in tar:
                    if m.issym():
                        got[m.name] = hashlib.sha256(os.fsencode(m.linkname)).hexdigest()
                    elif m.isfile():
                        h = hashlib.sha256()
                        fh = tar.extractfile(m)
                        for chunk in iter(lambda: fh.read(CARRY_CHUNK), b""):
                            h.update(chunk)
                        got[m.name] = h.hexdigest()
            if got != want_files:
                bad = sorted(k for k in set(got) | set(want_files) if got.get(k) != want_files.get(k))
                raise _SnapFail("checked", "%s reads back different from what was written (%s)"
                                % (r["tar"], ", ".join(bad[:3])))
    finally:
        shutil.rmtree(str(vt), ignore_errors=True)


def _clear_pushed_scratch(root: Path, dry: bool) -> List[str]:
    """Before the safety copy is estimated (update-command Decision 10a): the scratch worktrees of every promotion
    under state/promote/ whose pushed or announced record exists, removed through promote.remove_scratch, which
    keeps the records. Its content is on trunk by construction, so the copy need not hold it; removing it first is
    what keeps it out of the estimate. A promotion whose .confirm.lock is held is being confirmed now and is left
    alone, unnamed. [] or one line, without the run's head: "removed" ("would remove" in a dry run)."""
    base = root / "state" / "promote"
    if not base.is_dir():
        return []
    done: List[str] = []
    pm, tr = None, {}
    for pdir in sorted(base.iterdir()):
        if pdir.is_symlink() or not pdir.is_dir() or not ((pdir / "pushed").exists() or (pdir / "announced").exists()):
            continue
        if pm is None:         # only once one is found: promote (and what it imports) is read when there is work
            import promote as pm
            tr = {key: "" for key, _ in target_repos(root)}
        if not any(c.name not in pm.RECORDS for c in pdir.iterdir()):
            continue
        try:           # the lock confirm_lock takes; a dry run only asks whether it is free, and creates no file
            fh = open(str(pdir / ".confirm.lock"), "r" if dry else "a")
        except OSError:
            if dry and not (pdir / ".confirm.lock").exists():
                done.append(pdir.name)
            continue
        with fh:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                continue
            if dry:
                done.append(pdir.name)
                continue
            pm.remove_scratch(root, pdir, tr)
        if not any(c.name not in pm.RECORDS for c in pdir.iterdir()):
            done.append(pdir.name)
    if not done:
        return []
    return ["%s the promote scratch of %d pushed promotion%s (%s); their records are kept."
            % ("would remove" if dry else "removed", len(done), "" if len(done) == 1 else "s", ", ".join(done))]


def ensure_snapshot(root: Path, ver: str, deadline: Optional[float], prefer_bg: bool = False,
                    said: Optional[List[str]] = None) -> Optional[str]:
    """Before the upgrade's first change in target/: a checked copy of everything there the kept copies do not
    already hold, or a Stop. None when target/ holds no repository, or the kept copies hold all of it. At a session
    start (a deadline), a copy that will not fit raises _Background. First, the scratch of every pushed promotion is
    removed (_clear_pushed_scratch); its line goes into said, which the caller reports whatever follows."""
    cleared = _clear_pushed_scratch(root, False)
    if said is not None:
        said += cleared
    coll: List[dict] = []
    try:
        try:
            repos = _snap_repos(root)
            if not repos:
                return None
            for r in repos:
                if _snap_late(deadline) and not prefer_bg:
                    raise _OutOfTime()
                coll.append(_snap_collect(root, r, deadline, {x["common"] for x in repos}))
            fp, todo = _snap_plan(root, coll, None if prefer_bg else deadline)
        except _OutOfTime:
            raise _Background(slow=True)
        except _SnapFail as e:
            raise Stop(SNAP_FAIL % (ver, e.args[0], e.args[1]))
        if not todo:
            return None
        prev = _snapshots(root)
        est = _snap_estimate(todo)
        cap = _snap_cap(root)
        if est > cap * (1 << 20):
            raise Stop(_snap_big(root, ver, est, cap, todo))
        try:
            (root / "state").mkdir(parents=True, exist_ok=True)
            free = shutil.disk_usage(str(root / "state")).free
        except OSError:
            free = None
        if free is not None and free < est + (64 << 20):
            raise Stop(SNAP_DISK % (ver, _mb(est), _mb(free)))
        if deadline is not None and (prefer_bg or est > BG_BYTES):
            raise _Background()
        try:
            stamp, size = _snap_write(root, todo, ver, fp, cap, deadline)
        except _OutOfTime:
            raise _Background()
        except _SnapFail as e:
            raise Stop(SNAP_FAIL % (ver, e.args[0], e.args[1]))
        _snap_record(root, fp, stamp)
        if prev:
            return ("a safety copy of what is new in target/ since the copy in state/upgrade-snapshot/%s is in "
                    "state/upgrade-snapshot/%s (%s), taken before anything there changed." % (prev[-1], stamp, _mb(size)))
        return "a safety copy of everything in target/ is in state/upgrade-snapshot/%s (%s), taken before anything " \
               "there changed." % (stamp, _mb(size))
    finally:
        _drop_scratch(coll)


# --- the run in the background --------------------------------------------------------------------------------

def _bg_running(root: Path) -> bool:
    rec = _read_json(root / BACKGROUND)
    if not rec or not rec.get("running"):
        return False
    try:
        pid = int(rec.get("pid"))
        os.kill(pid, 0)
    except (TypeError, ValueError, OSError):
        return False
    code, out, _ = v.run(["ps", "-o", "command=", "-p", str(pid)], timeout=5)
    return code == 0 and "upgrade.py" in out and "--background" in out


def _bg_copied(root: Path, ver: Optional[str]) -> bool:
    """Has a run in the background finished taking the copy for the upgrade to <ver>?"""
    rec = _read_json(root / BACKGROUND) or {}
    return bool(rec.get("copied")) and rec.get("version") == ver and not rec.get("running")


def _go_background(root: Path, ver: str) -> str:
    """Start `core/upgrade.py --background` detached (its own session, no pipe to this hook, logged to
    state/upgrade.log) and record it; the sentence the board repeats until it is done. The detached run only takes
    the copy, which changes nothing in target/: sessions bound meanwhile work there while it reads."""
    try:
        log = open(str(root / UPGRADE_LOG), "ab")
    except OSError as e:
        return _stopped(root, ver, 2, SNAP_BG_FAIL % (ver, e.strerror or e))
    try:
        with log:
            log.write(("--- %s: the safety copy for the upgrade to %s, started in the background by a session start\n"
                       % (time.strftime("%Y-%m-%dT%H:%M:%S"), ver)).encode())
            log.flush()
            pr = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--background"],
                                  stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, cwd=str(root),
                                  env=dict(os.environ, DAEDALUS_HOME=str(root)), start_new_session=True,
                                  close_fds=True)
    except OSError as e:
        return _stopped(root, ver, 2, SNAP_BG_FAIL % (ver, e.strerror or e))
    try:
        _write(root / BACKGROUND, json.dumps({"pid": pr.pid, "version": ver, "running": True,
                                              "started_at": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=2) + "\n")
    except OSError:
        pass
    return _stopped(root, ver, 2, SNAP_BG % ver, background=True)


def background_main(root: Path) -> int:
    """The detached run: the copy, checked, and nothing else. The upgrade's changes in target/ are made by the next
    session start, inside its hook, before that session's agent has control — never while sessions work there."""
    ver = version(root)
    _write(root / BACKGROUND, json.dumps({"pid": os.getpid(), "version": ver, "running": True,
                                          "started_at": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=2) + "\n")
    copied = False
    try:
        fd = _lock(root, None)
        try:
            first: List[str] = []
            try:
                said = ensure_snapshot(root, ver or "", None, said=first)
            finally:
                for ln in first:
                    print("Upgrade to %s: %s" % (ver, ln))
            print("Upgrade to %s: %s" % (ver, said or "the kept safety copies already hold everything in target/."))
            copied = True
        except Stop as e:
            print(_stopped(root, ver, 2, str(e)))
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        return 0 if copied else 1
    finally:
        sys.stdout.flush()
        _write(root / BACKGROUND, json.dumps({"pid": None, "version": ver, "running": False, "copied": copied,
                                              "at": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=2) + "\n")


def _uncopied(root: Path) -> List[str]:
    """Each repository the upgrade's steps act on (target_repos) whose git directory no checked copy holds."""
    held = _kept(root)
    out = []
    for key, p in target_repos(root):
        c = _common_dir(["-C", str(p)])
        if c is None or c not in held:
            out.append("target/%s" % key)
    return out


COPY_FIRST = ("This session has no window yet: no window is made in target/ until the upgrade has its safety copy of "
              "it; a session started after that is numbered")
COPY_FIRST_LEASE = ("no window is made or changed in target/ until the upgrade has its safety copy of it, which it has "
                    "not yet; `core/lease.sh %s` works once the board no longer says the copy is being taken")


def copy_missing(root: Path) -> bool:
    """While the upgrade is pending: a repository its steps act on that no checked copy holds — the copy not taken
    yet (handed to a run in the background, or stopped before it). A session start then numbers no window, and
    lease.sh refuses what makes or changes one: a window's worktree add (and its prune of records under worktrees/)
    would change target/'s repositories before the copy read them."""
    return pending(root) and bool(_uncopied(root))


# No window while the upgrade is not stamped — stopped, handed to a run in the background, or not run yet (final
# verification, mode c): a session start that numbered one added lease/<NN>, a worktree record, a branch section and
# the pre-push hook to target/'s repositories right after the stop said "Nothing was changed". The session start
# says WINDOWS_WAIT, the board on every prompt WINDOWS_WAIT_BOARD under the stop, and lease.sh refuses what makes a
# window with WINDOWS_WAIT_LEASE — all but "pick it up" (adopt --all-unfinished), the way in that the stop names.
WINDOWS_WAIT = ("This session has no window yet: windows open once the upgrade finishes; a session started after that "
                "is numbered")
WINDOWS_WAIT_BOARD = "No window opens until the upgrade finishes."
WINDOWS_WAIT_LEASE = "no window opens until the upgrade to %s finishes, so `core/lease.sh %s` is refused. %s"


def windows_wait_lease(root: Path, cmd: str, args: List[str]) -> Optional[str]:
    """lease.sh's refusal of a command that makes or binds a window while the upgrade is not stamped, or None: the
    stop the board shows (or "has not run yet"), after the pointer. `adopt --all-unfinished` is never refused here."""
    import leaselib as ll
    if cmd not in ll.WINDOW_MAKERS or (cmd == "adopt" and args == ["--all-unfinished"]) or not pending(root):
        return None
    pend = pending_line(root) or ""
    if pend and not pend.endswith("."):
        pend += "."
    return WINDOWS_WAIT_LEASE % (version(root), cmd, pend)


def snapshot_line(root: Path) -> Optional[str]:
    """The board's line while a copy is kept."""
    snaps = _snapshots(root)
    return SNAP_LINE % snaps[-1] if snaps else None


# --- --restore-help and --forget-snapshot ---------------------------------------------------------------------

def _sh(s: str) -> str:
    """A word for the shell: shlex.quote, or $'...' when it holds a newline or another control byte, or bytes that
    are not UTF-8 (bash and zsh both read $'...')."""
    if not re.search(CTRL, s):
        return shlex.quote(s)
    return "$'" + _escaped(s, True) + "'"


CTRL = "[\x00-\x1f\x7f\udc80-\udcff]"
ESCAPES = {"\t": "\\t", "\n": "\\n", "\r": "\\r"}


def _escaped(s: str, quoting: bool = False) -> str:
    """<s> with each newline, tab or other control character (and each byte that is not UTF-8) written as \\n, \\t or
    \\xHH, so a name said in a sentence stays on its line; quoting: also ' and \\, for inside $'...'."""
    out = []
    for ch in s:
        o = ord(ch)
        if quoting and ch in "'\\":
            out.append("\\" + ch)
        elif ch in ESCAPES:
            out.append(ESCAPES[ch])
        elif o < 32 or o == 127:
            out.append("\\x%02x" % o)
        elif 0xdc80 <= o <= 0xdcff:
            out.append("\\x%02x" % (o - 0xdc00))
        else:
            out.append(ch)
    return "".join(out)


def _repo_now(r: dict) -> Optional[List[str]]:
    if r.get("path") and (Path(r["path"]) / ".git").exists():
        return ["-C", r["path"]]
    if r.get("git_dir") and Path(r["git_dir"]).is_dir():
        return ["--git-dir", r["git_dir"]]
    return None


def _in_a_window(g: List[str], path: str, want: str) -> bool:
    """Does a window's branch (lease/<NN>) hold <path> with the content whose sha256 is <want>? "Pick it up" saves
    unsaved files as a commit there, and the window's worktree may not be made yet."""
    code, out, _ = _gb(g + ["for-each-ref", "--format=%(objectname)", "refs/heads/lease/"])
    for tip in sorted(_lines_set(out)) if code == 0 else []:
        code, blob, _ = _gb(g + ["cat-file", "blob", "%s:%s" % (tip, path)])
        if code == 0 and hashlib.sha256(blob).hexdigest() == want:
            return True
    return False


def _sha256(path: str, link: bool) -> Optional[str]:
    try:
        if link:
            return hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(CARRY_CHUNK), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def _lines_set(out: bytes) -> Set[str]:
    return {ln.split(" ")[0] for ln in os.fsdecode(out).splitlines() if ln}


def _snap_missing(root: Path, stamp: str) -> Tuple[dict, List[Tuple[dict, str, object]]]:
    """(manifest, [(repo entry, "commit"|"file"|"git-state", what)]) — what the copy holds that target/ no longer has. A commit is
    there only while a ref reaches it — a branch, a tag, any worktree's HEAD, a stash entry (a window's branch
    counts: the upgrade moves work there) — never because only a reflog does, which expires, nor because the
    object is still on disk, which gc removes. What the copy held only through a reflog is there while a reflog or a
    ref still reaches it. Staged content is there while every staged blob is reachable from a ref or held by an
    index. Origin's branches as last fetched are origin's, not counted. A file is there while any worktree of its
    repository — a window's included — holds it at the same path with the same content. Each of git's in-progress
    files (a merge's, rebase's, cherry-pick's, revert's or bisect's — never the index or ORIG_HEAD) is there while
    its worktree's git directory holds it with the same content. Whatever git cannot read counts as missing."""
    m = _read_json(root / SNAPS / stamp / "manifest.json")
    if not m:
        raise Stop("the safety copy in %s/%s has no readable manifest.json" % (SNAPS, stamp))
    out: List[Tuple[dict, str, object]] = []
    for r in m.get("repos", []):
        g = _repo_now(r)
        refs = r.get("refs", [])
        kinds = {x["kind"] for x in refs}
        reach: Optional[Set[str]] = None
        logged: Optional[Set[str]] = None
        objs: Optional[Set[str]] = None
        targets: Set[str] = set()
        staged: Set[str] = set()
        wts: List[str] = []
        if g is not None:
            stashes = _stash_list(g) or []
            # each linked worktree's own refs (refs/worktree, refs/bisect, refs/rewritten), which --all from another
            # worktree does not see, read through git's record of it whether or not its directory is there
            admins = sorted(str(a) for a in Path(r["git_dir"]).glob("worktrees/*") if a.is_dir()) \
                if r.get("git_dir") else []
            own: Set[str] = set()
            for a in admins:
                code, o, _ = _gb(["--git-dir", a, "for-each-ref", "--format=%(objectname)", "refs/worktree/",
                                  "refs/bisect/", "refs/rewritten/"])
                own |= _lines_set(o) if code == 0 else set()
            ins = "".join(sha + "\n" for sha in [x for _, x, _ in stashes] + sorted(own)).encode()
            code, o, _ = _gb(g + ["rev-list", "--all", "--stdin"], inp=ins)
            reach = _lines_set(o) if code == 0 else None
            code, o, _ = _gb(g + ["for-each-ref", "--format=%(objectname)"])
            targets = (_lines_set(o) if code == 0 else set()) | own
            if "reflog" in kinds:
                code, o, _ = _gb(g + ["rev-list", "--all", "--reflog", "--stdin"], inp=ins)
                logged = _lines_set(o) if code == 0 else None
            wts = [w.get("worktree", "") for w in _worktree_list(g) if "bare" not in w]
            if r.get("path") and g[0] == "-C":
                wts = [r["path"]] + wts[1:]     # a submodule's main worktree is listed as its git directory
            for w in r.get("worktrees", []):
                # a checkout moved with mv, where the copy found it — while it is still one of this repository's
                at = w.get("at")
                if at and at not in wts and os.path.isdir(at) and _common_dir(["-C", at]) == r.get("git_dir"):
                    wts.append(at)
            if "index" in kinds:
                code, o, _ = _gb(g + ["rev-list", "--objects", "--all", "--stdin"], inp=ins)
                objs = _lines_set(o) if code == 0 else None
                # every index git keeps for this repository — a worktree's whose directory is gone included
                for gd in ([r["git_dir"]] if r.get("git_dir") else []) + admins:
                    if not os.path.isfile(os.path.join(gd, "index")):
                        continue
                    code, o, _ = _gb(["--git-dir", gd, "ls-files", "-s", "-z"])
                    for rec in (_z(o) if code == 0 else []):
                        parts = rec.partition("\t")[0].split(" ")
                        if len(parts) == 3:
                            staged.add(parts[1])
                for wp in wts:
                    code, o, _ = _gb(["-C", wp, "ls-files", "-s", "-z"])
                    for rec in (_z(o) if code == 0 else []):
                        parts = rec.partition("\t")[0].split(" ")
                        if len(parts) == 3:
                            staged.add(parts[1])
        lost: Dict[str, List[dict]] = {}
        for x in refs:
            k, sha = x["kind"], x["sha"]
            if k == "remote":
                continue
            if k == "index":
                there = objs is not None and all(b in objs or b in staged for _, b in x.get("blobs", []))
            elif x.get("type") != "commit":
                there = sha in targets
            else:
                there = (reach is not None and sha in reach) or (k == "reflog" and logged is not None and sha in logged)
            if not there:
                lost.setdefault(sha, []).append(x)
        for sha, xs in lost.items():
            out.append((r, "commit", xs))
        for f in r.get("files", []):
            there = False
            for wp in wts:
                p = os.path.join(wp, f["path"])
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if st.st_size == f["size"] or f.get("link"):
                    if _sha256(p, bool(f.get("link"))) == f["sha256"]:
                        there = True
                        break
            if not there and g is not None and not f.get("link"):
                there = _in_a_window(g, f["path"], f["sha256"])
            if not there:
                out.append((r, "file", f))
        gds: Dict[int, Optional[str]] = {}
        for x in r.get("git_state", []):
            if x["path"] in SNAP_ALONG:
                continue
            if x["w"] not in gds:
                gds[x["w"]] = _git_dir_now(r, x["w"])
            gd = gds[x["w"]]
            if gd is None or _sha256(os.path.join(gd, x["path"]), False) != x["sha256"]:
                out.append((r, "git-state", x))
    return m, out


def _git_dir_now(r: dict, w: int) -> Optional[str]:
    """The git directory of worktree <w> of the copied repository <r> as it is now (the common one for the main
    worktree), or None when that worktree or repository is gone."""
    if w == 0:
        return r["git_dir"] if r.get("git_dir") and os.path.isdir(r["git_dir"]) else None
    x = next((x for x in r.get("worktrees", []) if x.get("i") == w), {})
    for wt in (x.get("path"), x.get("at")):
        if wt and os.path.isdir(wt):
            code, out, _ = _gb(["-C", wt, "rev-parse", "--absolute-git-dir"])
            gd = os.fsdecode(out.rstrip(b"\n")) if code == 0 else ""
            if gd and os.path.isdir(gd):
                return gd
    # its directory gone (moved with mv, an unmounted volume): git's record of it, while it is still that worktree's
    admin = x.get("admin")
    try:
        rec = Path(admin, "gitdir").read_text().strip() if admin else ""
    except OSError:
        rec = ""
    if rec and os.path.realpath(os.path.dirname(rec)) in {os.path.realpath(q) for q in (x.get("path"), x.get("at")) if q}:
        return admin
    return None


def _ref_words(x: dict, wt0: str) -> str:
    k = x["kind"]
    if k == "branch":
        return "branch %s" % x["name"][len("refs/heads/"):]
    if k == "tag":
        return "tag %s" % x["name"][len("refs/tags/"):]
    if k in ("stash", "stash-entry"):
        return "stash entry %s%s" % ("stash@{0}" if k == "stash" else x["name"],
                                     " (%s)" % x["message"] if x.get("message") else "")
    if k == "head":
        return "the commit checked out in %s" % _escaped(x.get("worktree") or wt0)
    if k == "reflog" and x.get("older"):
        return "a commit from %s's history, more than %d days old" % (x["name"], REFLOG_DAYS)
    if k == "reflog":
        return "a commit from the last %d days of %s's history" % (REFLOG_DAYS, x["name"])
    if k == "index":
        paths = sorted({_escaped(p) for p, _ in x.get("blobs", [])})
        more = " and %d more" % (len(paths) - 5) if len(paths) > 5 else ""
        return "the staged, uncommitted content of %s%s in %s%s" % (
            ", ".join(paths[:5]), more, _escaped(x.get("worktree") or wt0),
            " (a merge with conflicts: each staged version is a numbered file, listed in the commit's message)"
            if x.get("conflicted") else "")
    return "ref %s" % x["name"]


def _restore_name(xs: List[dict], sha: str) -> str:
    for x in xs:
        if x["kind"] == "branch":
            return "restored/%s-%s" % (x["name"][len("refs/heads/"):], sha[:7])
    for x in xs:
        if x["kind"] == "tag":
            return "restored/tag-%s-%s" % (x["name"][len("refs/tags/"):], sha[:7])
    if any(x["kind"] == "index" for x in xs):
        return "restored/staged-%s" % sha[:7]
    return "restored/%s-%s" % ("detached" if any(x["kind"] == "head" for x in xs) else "commit", sha[:7])


def _restore_repo(root: Path, r: dict) -> Path:
    """Where the commands bring back a repository that is gone: one place per repository (by its git directory),
    whichever copy the commit is in."""
    slug = _name(0, r["label"])[2:]
    return root / RESTORE / "repositories" / ("%s-%s-repo" % (slug, hashlib.sha256(
        os.fsencode(r.get("git_dir") or r["label"])).hexdigest()[:8]))


def _extract(tar: str, dest: str, member: str) -> str:
    """A command that takes exactly the member named <member> out of <tar> into <dest> — by its name, never as a
    pattern (tar reads [ ] * ? and \\ in a name as a glob, and which tar is installed decides how)."""
    code = ('import sys, tarfile; t = tarfile.open(sys.argv[1]); t.extract(t.getmember(sys.argv[3]), sys.argv[2], '
            '**({"filter": "tar"} if hasattr(tarfile, "tar_filter") else {}))')
    return "python3 -c %s %s %s %s" % (_sh(code), _sh(tar), _sh(dest), _sh(member))


def _restore_lines(root: Path, stamp: str, m: dict, missing: List[Tuple[dict, str, object]]) -> List[str]:
    snapdir = root / SNAPS / stamp
    lines = []
    commits = [(r, xs) for r, what, xs in missing if what == "commit"]
    # stash entries oldest first, so storing them one by one rebuilds the stash in its order
    def order(item: Tuple[dict, List[dict]]) -> Tuple[int, int]:
        xs = item[1]
        st = [x for x in xs if x["kind"] == "stash-entry"]
        return (1, -int(st[0]["name"][len("stash@{"):-1])) if st else (0, 0)
    for r, xs in sorted(commits, key=order):
        sha = xs[0]["sha"]
        wt0 = (r.get("worktrees") or [{}])[0].get("path") or r["label"]
        names = []
        entry_kinds = {x["kind"] for x in xs}
        for x in xs:
            if x["kind"] == "stash" and "stash-entry" in entry_kinds:
                continue        # refs/stash is stash@{0}, named with its message below
            w = _ref_words(x, wt0)
            if w not in names:
                names.append(w)
        subj = next((x.get("subject") for x in xs if x.get("subject")), "")
        lead = "- %s: commit %s%s — %s." % (r["label"], sha[:7], ' ("%s")' % subj if subj else "", "; ".join(names))
        g = "git -C %s" % _sh(r["path"]) if r.get("path") else "git --git-dir=%s" % _sh(r["git_dir"])
        shallow = r.get("shallow") or []
        pre = ""
        if _repo_now(r) is None:
            # the repository itself is gone: the commands bring it back into a new one under state/upgrade-restore/,
            # shallow at the same commits when it was (its copy holds no history beyond them) — one for every copy,
            # so a later copy's bundle finds there the commits of the earlier one it builds on
            dest = _restore_repo(root, r)
            g = "git -C %s" % _sh(str(dest))
            pre = "git init -q %s && %s" % (_sh(str(dest)), "printf '%%s\\n' %s > %s && " % (
                " ".join(shallow), _sh(str(dest / ".git" / "shallow"))) if shallow else "")
            lead += (" %s is not there now; this brings the commit back into a repository of its own at %s%s."
                     % (_escaped(r.get("path") or r["git_dir"]), _escaped(_rel(root, str(dest))),
                        ", shallow at the same %s as the clone it was copied from" % _plural(len(shallow), "commit")
                        if shallow else ""))
        elif shallow:
            lead += (" (%s is a shallow clone: its copy holds no history past %s, so it comes back only into this "
                     "repository or another shallow at the same commits)" % (r["label"], _plural(len(shallow), "commit")))
        bundle = _sh(str(snapdir / r["bundle"])) if r.get("bundle") else None
        bref = xs[0]["bundle_ref"]
        stash = next((x for x in xs if x["kind"] == "stash-entry"), None)
        if bundle is None:
            lines += [lead + " The copy has no bundle for this repository."]
        elif stash is not None and r.get("path"):
            lines += [lead + " Bring it back into the stash:",
                      "    %s%s fetch -q %s %s && %s stash store -m %s %s" % (pre, g, bundle, bref, g,
                                                                         _sh(stash.get("message") or "restored"), sha)]
        else:
            typ = xs[0].get("type")
            name = _restore_name(xs, sha)
            dest = ("refs/tags/" if typ == "tag" else "refs/heads/") + name
            lines += [lead + " Bring it back as %s %s:" % ("tag" if typ == "tag" else "branch", name),
                      "    %s%s fetch -q %s %s:%s" % (pre, g, bundle, bref, dest)]
    for r, what, f in missing:
        if what != "file":
            continue
        wt = next((w for w in r.get("worktrees", []) if w["i"] == f["w"]), {})
        where = "" if f["w"] == 0 else " in the worktree at %s" % _escaped(wt.get("path", "?"))
        dest = root / RESTORE / stamp / _name(r["n"], r["label"])
        lines += ["- %s: %s %s%s (%s) — bring it back; it lands in %s, from where you move it where you "
                  "want it:" % (r["label"], FILE_WORDS.get(f["kind"], "file"), _escaped(f["path"]), where,
                                _plural(f["size"], "byte"), _escaped(_rel(root, str(dest / f["member"])))),
                  "    " + _extract(str(snapdir / r["tar"]), str(dest), f["member"])]
    for r, what, x in missing:
        if what != "git-state":
            continue
        wt = next((w for w in r.get("worktrees", []) if w["i"] == x["w"]), {})
        where = (_escaped(r.get("path") or r["git_dir"]) if x["w"] == 0
                 else "the worktree at %s" % _escaped(wt.get("path", "?")))
        dest = root / RESTORE / stamp / _name(r["n"], r["label"])
        lines += ["- %s: git's record of a %s in progress (%s, in %s) — if that was finished or given up since, "
                  "nothing is lost; otherwise bring it back; it lands in %s, from where you copy it into that "
                  "worktree's git directory:" % (r["label"], _git_state_words(x["path"]), _escaped(x["path"]), where,
                                                 _escaped(_rel(root, str(dest / x["member"])))),
                  "    " + _extract(str(snapdir / r["tar"]), str(dest), x["member"])]
    return lines


def _git_state_words(path: str) -> str:
    top = path.split("/", 1)[0]
    if top.startswith("rebase-"):
        return "rebase"
    if top.startswith("BISECT_"):
        return "bisect"
    return {"CHERRY_PICK_HEAD": "cherry-pick", "REVERT_HEAD": "revert",
            "sequencer": "cherry-pick or revert"}.get(top, "merge")


def _snap_report(root: Path, stamp: str) -> Tuple[List[str], int]:
    m, missing = _snap_missing(root, stamp)
    head = "The safety copy in state/upgrade-snapshot/%s (taken %s, before the upgrade to %s)" % (
        stamp, str(m.get("taken_at", "")).replace("T", " "), m.get("version", "?"))
    sk = []
    for x in m.get("skipped") or []:
        try:
            full = os.path.join(x["worktree"], x["path"])
            sk.append("%s (%s) — cd %s && %s" % (_rel(root, full), _mb(int(x["bytes"])),
                                                 shlex.quote(_rel(root, os.path.dirname(full))), x["rebuild"]))
        except (KeyError, TypeError, ValueError):
            continue
    tail = [SNAP_SKIPPED % "; ".join(sk)] if sk else []
    if not missing:
        return [head + ": nothing in it is missing — " + SNAP_NOTHING + "."] + tail, 0
    lines = [head + " holds %s target/ no longer has. Each command can be run from anywhere (run them in the "
             "order shown: a later copy's commits build on an earlier one's); none overwrites anything — a branch "
             "comes back under restored/, a file under state/upgrade-restore/:"
             % _plural(len(missing), "thing")]
    return lines + _restore_lines(root, stamp, m, missing) + tail, len(missing)


def _names_out() -> None:
    try:
        sys.stdout.reconfigure(errors="surrogateescape")      # a name that is not UTF-8 is printed, never a crash
    except (AttributeError, ValueError):
        pass


def restore_help(root: Path) -> int:
    _names_out()
    snaps = _snapshots(root)
    if not snaps:
        print("There is no safety copy in state/upgrade-snapshot/ — the upgrade has not needed to take one here.")
        return 0
    for s in snaps:
        try:
            lines, _ = _snap_report(root, s)
        except Stop as e:
            lines = [str(e)]
        for ln in lines:
            print(ln)
    return 0


def forget_snapshot(root: Path) -> int:
    _names_out()
    if pending(root) or _bg_running(root):
        print("The upgrade has not finished, so the safety copy is kept — it is what brings back anything the "
              "upgrade could lose. Run this again once the board no longer names the upgrade.")
        return 1
    snaps = _snapshots(root)
    if not snaps:
        print("There is no safety copy to remove.")
        return 0
    held, report = [], []
    for s in snaps:
        try:
            lines, n = _snap_report(root, s)
        except Stop as e:
            lines, n = [str(e)], 1
        if n:
            held.append(s)
            report += lines
    if held:
        for ln in report:
            print(ln)
        print("Nothing was removed: the copy holds what is listed above, which target/ no longer has. Bring back "
              "what you need with the commands above; if none of it is needed, remove %s by hand."
              % " and ".join("state/upgrade-snapshot/%s" % s for s in held))
        return 1
    for s in snaps:
        size = sum(f.stat().st_size for f in (root / SNAPS / s).iterdir() if f.is_file())
        shutil.rmtree(str(root / SNAPS / s))
        print("Removed the safety copy in state/upgrade-snapshot/%s (%s); %s." % (s, _mb(size), SNAP_NOTHING))
    for p in (SNAP_RECORD, BACKGROUND):
        try:
            (root / p).unlink()
        except OSError:
            pass
    return 0


def _snap_doctor(root: Path) -> None:
    for s in _snapshots(root):
        try:
            size = sum(f.stat().st_size for f in (root / SNAPS / s).iterdir() if f.is_file())
        except OSError:
            size = 0
        print("NOTE     a safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/%s "
              "(%s) — core/upgrade.py --restore-help lists anything in it that target/ no longer has; "
              "core/upgrade.py --forget-snapshot removes it once nothing is" % (s, _mb(size)))


def step_command(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """Step 7 (update-command design §4.7, daedalus-start design §4): this home registered and the daedalus command in
    ~/.local/bin, one shim for every home, by core/update.py's own install (never over a file it did not write), with
    how to reach it from the login shell. It never stops the
    upgrade: what it cannot do is a line. The login-shell check takes at most 5 s, less near a start's deadline."""
    if not (root / "core" / "update.py").is_file():
        return []
    timeout = 5.0 if deadline is None else min(5.0, deadline - time.time() - 0.5)
    try:
        import update as upd
        said = upd.install_shim(root, dry=dry, timeout=max(0.0, timeout))
    except Exception as e:          # never a stop: the command is a convenience, the upgrade is not
        said = ["the daedalus command was not installed (%s: %s); core/setup.sh installs it" % (type(e).__name__, e)]
    return ["%s: %s" % (head, ln) for ln in said]


NAMED_CALLEES = (0, 10, 0)
LEGACY_CALLEE = ("direct_call's callee %s is now callee \"%s\"; nothing to change. A second callee goes in its own "
                 "callee_<key>: block (config.example.yaml shows one).")


def step_callee(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """Step 8 (SPEC-011 §4): a home whose config.yaml names its one callee in the legacy direct_call keys is told,
    once — at the upgrade from a release before named callees — that the callee now has a key and nothing needs
    changing. Reads config.yaml and never writes it (the operator's file); never stops the upgrade."""
    was = stamped(root) or ""
    if VERSION_RE.fullmatch(was) and tuple(int(x) for x in was.split(".")) >= NAMED_CALLEES:
        return []
    name = _cfg(root, "direct_call.callee_name")
    if not (name and _cfg(root, "direct_call.callee_home")):
        return []
    return ["%s: %s" % (head, LEGACY_CALLEE % (name, name.lower()))]


STATUS_MOD = "service-status@daedalus-mods"
BOARD_MOD = "lease-board@daedalus-mods"
STATUS_INSTALL = "claude plugin install %s --scope local" % STATUS_MOD
STATUS_SAID = ("Installed the service-status mod at local scope: the services' summary now sits at the right of the "
               "lease board. Open a new terminal, or run /reload-plugins in one already open, to see it.")


def _enabled_in(path: Path, plugin: str) -> Optional[bool]:
    """enabledPlugins[plugin] in a settings file: True or False when it says, None when it does not (or is no JSON)."""
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    v = (d.get("enabledPlugins") or {}).get(plugin) if isinstance(d, dict) else None
    return v if isinstance(v, bool) else None


def step_status_mod(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """Step 9 (service-status spec §4): the service-status mod for a deployment that already has the lease board at
    local scope — the second mod of the same marketplace, installed beside the first, so `daedalus update` stays one
    command. Acts only when this home's marketplace lists it, the lease board is enabled in .claude/settings.local.json,
    and neither settings file names service-status (a person who switched it off keeps it off). A deployment without
    the lease board is setup's and doctor's to tell. It never stops the upgrade: what it cannot do is a line naming
    the command. The install is bounded by 20 s, less near a start's deadline."""
    market = root / "mods" / ".claude-plugin" / "marketplace.json"
    try:
        if '"./service-status"' not in market.read_text():
            return []
    except OSError:
        return []
    local = root / ".claude" / "settings.local.json"
    user = Path(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")) / "settings.json"
    if _enabled_in(local, BOARD_MOD) is not True:
        return []
    if _enabled_in(local, STATUS_MOD) is not None or _enabled_in(user, STATUS_MOD) is not None:
        return []
    if dry:
        return ["%s: would install the service-status mod at local scope (%s)" % (head, STATUS_INSTALL)]
    claude = shutil.which("claude")
    if not claude:
        return ["%s: the service-status mod was not installed (claude is not on PATH); run `%s` in the Daedalus home"
                % (head, STATUS_INSTALL)]
    timeout = 20.0 if deadline is None else min(20.0, deadline - time.time() - 0.5)
    if timeout < 2.0:
        return ["%s: the service-status mod was not installed (no time left in this session start); run `%s` in the "
                "Daedalus home" % (head, STATUS_INSTALL)]
    try:
        r = subprocess.run([claude, "plugin", "install", STATUS_MOD, "--scope", "local"], cwd=str(root),
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        ok = r.returncode == 0
        why = "exit %d" % r.returncode
    except (OSError, subprocess.TimeoutExpired) as e:
        ok, why = False, type(e).__name__
    if ok:
        return ["%s: %s" % (head, STATUS_SAID)]
    return ["%s: the service-status mod was not installed (%s); run `%s` in the Daedalus home" % (head, why, STATUS_INSTALL)]


MODS_MARKET = "daedalus-mods"


def _plugins_root() -> Path:
    """Where Claude Code keeps its plugin records: ~/.claude/plugins, or CLAUDE_CODE_PLUGIN_CACHE_DIR (plugin loading
    reference, "Find plugins on disk"). Whether CLAUDE_CONFIG_DIR moves it is not documented, so, as doctor's
    marketplace check does, it is not read here."""
    return Path(os.environ.get("CLAUDE_CODE_PLUGIN_CACHE_DIR") or os.path.expanduser("~/.claude/plugins"))


def _vtuple(s: object) -> Optional[Tuple[int, ...]]:
    return tuple(int(x) for x in s.split(".")) if isinstance(s, str) and re.fullmatch(r"\d+(\.\d+)*", s) else None


def stale_mods(root: Path) -> List[Tuple[str, str, str]]:
    """(name, installed, shipped) for each mod of this home's marketplace that is enabled in .claude/settings.local.json
    and whose local-scope record for this home in installed_plugins.json names an older version than
    mods/<name>/.claude-plugin/plugin.json. A window loads the recorded copy from the plugin cache, not mods/, so a
    newer mod in a pulled release stays unseen until `claude plugin update` (found 2026-10-18: lease-board 0.1.1 drawn
    while the home shipped 0.1.3). A version either side that is not plain numbers is not compared."""
    try:
        market = json.loads((root / "mods" / ".claude-plugin" / "marketplace.json").read_text())
        recs = json.loads((_plugins_root() / "installed_plugins.json").read_text()).get("plugins") or {}
    except (OSError, ValueError, AttributeError):
        return []
    if not (isinstance(market, dict) and isinstance(recs, dict)):
        return []
    local = root / ".claude" / "settings.local.json"
    here = os.path.realpath(str(root))
    out: List[Tuple[str, str, str]] = []
    for entry in market.get("plugins") or []:
        name = entry.get("name") if isinstance(entry, dict) else None
        src = entry.get("source") if isinstance(entry, dict) else None
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", name):
            continue
        plugin = "%s@%s" % (name, MODS_MARKET)
        if _enabled_in(local, plugin) is not True:
            continue
        rel = src[2:] if isinstance(src, str) and src.startswith("./") else name
        try:
            shipped = json.loads((root / "mods" / rel / ".claude-plugin" / "plugin.json").read_text()).get("version")
        except (OSError, ValueError, AttributeError):
            continue
        rec = [r for r in (recs.get(plugin) or []) if isinstance(r, dict) and r.get("scope") == "local"
               and isinstance(r.get("projectPath"), str) and os.path.realpath(r["projectPath"]) == here]
        if len(rec) != 1:
            continue
        have, want = _vtuple(rec[0].get("version")), _vtuple(shipped)
        if have is not None and want is not None and have < want:
            out.append((name, rec[0]["version"], shipped))
    return out


def _mod_update(name: str) -> str:
    return "claude plugin update %s@%s --scope local" % (name, MODS_MARKET)


def stale_mods_doctor(root: Path) -> None:
    """Doctor's line for each mod a window here would draw from an older copy than this home ships. NOTE, never
    MISSING: the older mod still works, and the model-facing board is unchanged."""
    for name, have, want in stale_mods(root):
        print("NOTE     %s mod out of date: %s is installed for this home, mods/ ships %s — run `%s` in the Daedalus "
              "home, then /reload-plugins in an open window" % (name, have, want, _mod_update(name)))


def step_mod_updates(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """Step 10: each Daedalus mod already installed at local scope for this home and enabled there, whose recorded
    version is older than the one mods/ ships, updated (`claude plugin update <name>@daedalus-mods --scope local`, in
    the home). After step 9, so a release that adds one mod and changes another does both in one upgrade. It never
    stops the upgrade: what it cannot do is a line naming the command. The updates together are bounded by 20 s, less
    near a start's deadline."""
    stale = stale_mods(root)
    if not stale:
        return []
    if dry:
        return ["%s: would update the %s mod %s → %s (%s)" % (head, n, a, b, _mod_update(n)) for n, a, b in stale]
    claude = shutil.which("claude")
    end = time.time() + 20.0 if deadline is None else min(time.time() + 20.0, deadline - 0.5)
    lines: List[str] = []
    for n, a, b in stale:
        timeout = end - time.time()
        if not claude:
            why = "claude is not on PATH"
        elif timeout < 2.0:
            why = "no time left in this session start"
        else:
            try:
                r = subprocess.run([claude, "plugin", "update", "%s@%s" % (n, MODS_MARKET), "--scope", "local"],
                                   cwd=str(root), stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                   timeout=timeout)
                why = "" if r.returncode == 0 else "exit %d" % r.returncode
            except (OSError, subprocess.TimeoutExpired) as e:
                why = type(e).__name__
        if not why:
            lines.append("%s: %s mod updated %s → %s; run /reload-plugins in an open window" % (head, n, a, b))
        else:
            lines.append("%s: the %s mod was not updated from %s to %s (%s); run `%s` in the Daedalus home"
                         % (head, n, a, b, why, _mod_update(n)))
    return lines


STEPS = ((1, "creating the window directories", step_dirs),
         (2, "installing the pre-push hook", step_hooks),
         (3, "removing the old shared reminder files", step_dedup),
         (4, "renaming hot.md's session line", step_hot),
         (5, "moving capture's settings into config.yaml", step_memory),
         (6, "putting target/ back on its trunk", step_trunk),
         (7, "installing the daedalus command", step_command),
         (8, "naming the direct-call callee", step_callee),
         (9, "installing the service-status mod", step_status_mod),
         (10, "updating the Daedalus mods", step_mod_updates))
FULL = len(STEPS)       # "the whole run": every step, then the stamp (Decision 18); --setup runs steps 1-3


def _lock(root: Path, deadline: Optional[float]) -> Optional[int]:
    """The upgrade lock (Decision 10). Free, it is taken at once. Held by another start's upgrade, this polls for
    it until `deadline` — at a session start the upgrade's own share of the budget, so the bind that follows keeps
    its reserve — and returns None if it is still held then."""
    (root / "state").mkdir(parents=True, exist_ok=True)
    fd = os.open(str(root / LOCK), os.O_RDWR | os.O_CREAT, 0o644)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if deadline is not None and time.time() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.05)


def run(root: Path, dry: bool = False, deadline: Optional[float] = None,
        upto: int = FULL) -> Tuple[List[str], Optional[str]]:
    """Steps 1..upto in order, then (upto FULL, not dry) the stamp. Returns (the lines of the steps that acted, the
    stop sentence or None). A stop is recorded in state/upgrade-stopped.json (not in a dry run) and the stamp is
    not written, so the next run starts again from the top. Before step 2, the first that can touch target/, a
    full run (upto FULL, not dry) takes the safety copy of target/ or stops; at a session start (a deadline) a copy
    that will not fit in it is taken by a detached run, and a start while that run is going leaves it alone; the
    start after it finds the copy taken and makes the upgrade's changes itself."""
    ver = version(root)
    if ver is None and upto == FULL:
        return [], None
    head = "Upgrade to %s" % ver if upto == FULL else "Setup"
    if not dry and upto == FULL and _bg_running(root):
        return [], None              # a detached run holds the upgrade; the board says so
    fd = None
    if not dry:
        fd = _lock(root, deadline)
        if fd is None:
            return [], None
    try:
        if fd is not None and upto == FULL and stamped(root) == ver:
            return [], None          # the run that held the lock finished it while this one waited
        lines: List[str] = []
        for n, what, fn in STEPS:
            if n > upto:
                break
            if not dry and deadline is not None and time.time() >= deadline:
                return lines, _stopped(root, ver, n, STOPPED_TIME % (ver, what))
            if n == 2 and upto == FULL and not dry:
                rec = _read_json(root / STOPPED) or {}
                # the last start handed a whole copy to a detached run that did not finish it: do not spend this
                # start's time trying it here again
                again = bool(rec.get("background")) and rec.get("version") == ver and not _snapshots(root)
                first: List[str] = []
                try:
                    said = ensure_snapshot(root, ver or "", deadline, prefer_bg=again, said=first)
                except _Background as e:
                    lines += ["%s: %s" % (head, ln) for ln in first]
                    if e.slow and _bg_copied(root, ver):
                        # a run in the background has taken the copy, and reading target/ against it still does not
                        # fit a start: another handoff would find the copy whole and change nothing, at every start
                        # (release-candidate red team 3, findings 4 and 7)
                        return lines, _stopped(root, ver, n, SNAP_SLOW % ver)
                    return lines, _go_background(root, ver or "")
                except Stop as e:
                    return lines + ["%s: %s" % (head, ln) for ln in first], _stopped(root, ver, n, str(e))
                lines += ["%s: %s" % (head, ln) for ln in first]
                bare = _uncopied(root)
                if bare:        # however it was found or missed, no repository is changed without a checked copy
                    return lines, _stopped(root, ver, n, SNAP_FAIL % (ver, "checked", "it holds no copy of %s"
                                                                      % ", ".join(bare)))
                if said:
                    lines.append("%s: %s" % (head, said))
            elif n == 2 and upto == FULL and dry:
                try:
                    lines += _dry_snapshot(root, head)
                except Stop as e:
                    return lines + getattr(e, "lines", []), str(e)
            if n == 2 and upto == FULL:
                # unfinished work in target/ stops here, before step 2 — the first that changes anything there —
                # and after the safety copy; recorded as step 6's, whose work it is
                try:
                    lines += gate(root, head, dry, deadline)
                except Stop as e:
                    lines += getattr(e, "lines", [])
                    sentence = (str(e) if str(e).startswith(("upgrade to ", "Daedalus has unfinished work"))
                                else STOPPED_WHILE % (ver, STEPS[5][1], e))
                    return lines, (sentence if dry else _stopped(root, ver, 6, sentence))
                except Exception as e:      # a check that crashed is a stop with its reason, never a silent pass
                    sentence = STOPPED_WHILE % (ver, STEPS[5][1], "%s: %s" % (type(e).__name__, e))
                    return lines, (sentence if dry else _stopped(root, ver, 6, sentence))
            try:
                lines += fn(root, head, dry, deadline)
            except Stop as e:
                lines += getattr(e, "lines", [])
                sentence = str(e) if str(e).startswith("upgrade to ") else STOPPED_WHILE % (ver, what, e)
                return lines, (sentence if dry else _stopped(root, ver, n, sentence))
            except Exception as e:      # a step that crashed is a stop with its reason, never a silent pass
                sentence = STOPPED_WHILE % (ver, what, "%s: %s" % (type(e).__name__, e))
                return lines, (sentence if dry else _stopped(root, ver, n, sentence))
        if upto == FULL:
            if dry:
                lines.append("%s: would write state/upgraded-to last." % head)
            else:
                no_tree = _unfinished_windows(root)
                if no_tree:
                    return lines, _stopped(root, ver, 6, _NO_WORKTREE % ((ver,) + no_tree[0]))
                _write(root / STAMP, ver + "\n")
                try:
                    (root / STOPPED).unlink()
                except OSError:
                    pass
                lines.append("%s: complete. What changed is in CHANGELOG.md under v%s; what the target's agent may "
                             "ask of you is in docs/handoff-reverse-caller.md." % (head, ver))
        return lines, None
    finally:
        if fd is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def _dry_snapshot(root: Path, head: str) -> List[str]:
    first = ["%s: %s" % (head, ln) for ln in _clear_pushed_scratch(root, True)]
    try:
        return first + _dry_estimate(root, head)
    except Stop as e:
        e.lines = first + getattr(e, "lines", [])      # type: ignore[attr-defined]
        raise


def _dry_estimate(root: Path, head: str) -> List[str]:
    coll: List[dict] = []
    try:
        repos = _snap_repos(root)
        coll = [_snap_collect(root, r, None, {x["common"] for x in repos}) for r in repos]
        if not coll:
            return []
        _, todo = _snap_plan(root, coll, None)
    except (_SnapFail, _OutOfTime):
        return []
    finally:
        _drop_scratch(coll)
    if not todo:
        return []
    est = _snap_estimate(todo)
    lines = ["%s: would keep a safety copy of %s target/ (about %s, in state/upgrade-snapshot/) before changing "
             "anything there." % (head, "what is new in" if _snapshots(root) else "everything in", _mb(est))]
    cap = _snap_cap(root)
    if est > cap * (1 << 20):
        e = Stop(_snap_big(root, version(root) or "", est, cap, todo))
        e.lines = lines      # type: ignore[attr-defined]
        raise e
    return lines


def _stopped(root: Path, ver: Optional[str], step: int, sentence: str, background: bool = False) -> str:
    rec = {"version": ver, "step": step, "sentence": sentence, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if background:
        rec["background"] = True
    if _CALLER["update"]:
        rec["sentence_update"] = _for_update(sentence)      # session lines read "sentence" (Decision 23)
    try:
        _write(root / STOPPED, json.dumps(rec, indent=2) + "\n")
    except OSError:
        pass
    return sentence


def pending_line(root: Path) -> Optional[str]:
    """The board's line on every prompt until the stamp is this VERSION's (spec §14 "What the operator sees if
    a step could not run"): the recorded stop, else "has not run yet"."""
    import leaselib as ll
    if version(root) is None:
        return None
    p = ll.pending_stop(root)        # the one reading of the recorded stop, shared with every no-window sentence
    return p[2] if p else None


def _repo_flag(root: Path, key: str) -> str:
    import leaselib as ll
    return "" if key == ll.target_name(root) else " --repo %s" % key.split("/", 1)[1]


OPERATOR_NOTE = ("NOTE     config.yaml lacks lines only the operator may write (the agent may not edit config.yaml) — "
                 "one paste: add the lines below to the end of config.yaml, replace each <...> with your answer, then "
                 "start a new session")
CLOUD_ENV = ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX")


def _cfg(root: Path, key: str) -> str:
    """config.yaml's <key> through lib.sh cfg, as every reader reads it; "" when unset or still a <...>."""
    val = v._lib(root, "cfg %s 2>/dev/null || true" % key).strip()
    return "" if val.startswith("<") else val


def _cloud_provider(root: Path) -> bool:
    """Does Claude Code run on a cloud provider here — the environment, or an env block in the settings it reads?"""
    def on(val: object) -> bool:
        return str(val or "").strip().lower() not in ("", "0", "false", "no")
    if any(on(os.environ.get(k)) for k in CLOUD_ENV):
        return True
    conf = Path(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"))
    for p in (root / ".claude" / "settings.json", root / ".claude" / "settings.local.json", conf / "settings.json"):
        try:
            env = json.loads(p.read_text()).get("env") or {}
        except (OSError, ValueError, AttributeError):
            continue
        if isinstance(env, dict) and any(on(env.get(k)) for k in CLOUD_ENV):
            return True
    return False


def operator_paste(root: Path) -> List[str]:
    """The config.yaml lines this release needs that only a person may write (critic finding 5): Edit of
    config.yaml is denied to the agent and a write to it trips the Stop check. Exact where the answer is known
    (update_command set: a promote is a release), a <...> with its question on a comment line above where only the
    operator knows it, and never a grant invented (callers). Repeated top-level blocks are read as one by lib.sh
    cfg, so the whole paste goes at the end of the file. [] when nothing is missing."""
    blocks: List[Tuple[str, List[str]]] = []
    note, cmd = _cfg(root, "promote.release_note"), _cfg(root, "promote.update_command")
    promote = []
    if note not in ("true", "false"):
        if cmd:
            promote += ["  # a promote here is a release: update_command is set", "  release_note: true"]
        else:
            promote += ["  # true if this target's users receive its trunk through an update command (a promote is "
                        "then a release), false if not", "  release_note: <true or false>"]
    if note != "false" and not cmd:
        promote += ["  # the command this target's users run to receive its trunk; leave this line out if "
                    "release_note is false", "  update_command: '<the update command>'"]
    if promote:
        blocks.append(("promote:", promote))
    if not _cfg(root, "direct_call.callers"):
        blocks.append(("direct_call:", ["  # the agents allowed to ask this Daedalus a question, comma separated; leave "
                                        "these two lines out to allow none", "  callers: <agent names>"]))
    if _cloud_provider(root) and not _cfg(root, "verify.refute_model"):
        blocks.append(("verify:", ["  # the model id the reviewer runs on with this provider; the charter's short "
                                   "name may not resolve here", "  refute_model: <your provider's model id>"]))
    return [ln for hdr, body in blocks for ln in [hdr] + body]


def doctor(root: Path) -> int:
    """Doctor's upgrade lines (spec §15): the stamp; a target/ checkout off its trunk or ahead of origin; hot.md
    still carrying session:. Local refs only — it never fetches, so it says what the refs this home last fetched
    show. While the upgrade is pending the remedy is the next session start; after it, core/lease.sh adopt."""
    ver = version(root)
    if ver is None:
        return 0                                    # doctor.sh's VERSION line says why
    pend = stamped(root) != ver
    print("NOTE     %s" % pending_line(root) if pend else "OK       upgrade: state/upgraded-to %s" % ver)
    _snap_doctor(root)
    paste = operator_paste(root)
    if paste:
        print(OPERATOR_NOTE)
        for ln in paste:
            print("PASTE    " + ln)
    try:
        import leaselib as ll
        repos, outer = target_repos(root), v.target_branch(root)
    except Exception:
        repos = []       # no target yet: nothing in target/ to judge
    for key, p in repos:
        # Per repo (spec §15: doctor names every problem in one run): a repo whose trunk cannot be told — a
        # nested repo with no origin/HEAD, a trunk origin lacks — is skipped alone; promote.py --doctor's trunk
        # row already names its fix, and the other repos are still judged.
        try:
            trunk = ll.trunk_of(root / "target", key, outer)
        except Exception:
            continue
        flag = _repo_flag(root, key)
        if _git(p, "rev-parse", "--verify", "-q", "refs/heads/origin/" + trunk)[0] == 0:
            print("NOTE     target/%s has a local branch named origin/%s, which git takes for origin's %s — rename it "
                  "(git -C target/%s branch -m origin/%s <new name>)" % (key, trunk, trunk, key, trunk))
        twins = ll.case_twins(p)
        if twins:           # git reads one for the other here (review 4, finding 1)
            print("NOTE     target/%s has branches whose names differ only in case (%s), which this filesystem cannot "
                  "keep apart — give one a new name (git -C target/%s pack-refs --all, then git -C target/%s branch -m "
                  "%s <new name>)" % (key, ll.twins_words(twins), key, key, twins[0][0]))
        for rel, what in _submodule_work(p):        # review 4, finding 4
            print("NOTE     target/%s's submodule %s holds work no window has: %s — it is in the trunk mirror, which no "
                  "session works in; move it into a window's worktree, or remove it once it is not needed"
                  % (key, rel, what))
        hidden = ll.hidden_edits(p)
        if hidden:
            marks, named, cmds = ll.hidden_words(key, hidden)
            print("NOTE     target/%s has uncommitted changes git status does not show, in files marked %s (%s) — "
                  "no window has them; clear the mark (%s) and commit them on a branch" % (key, marks, named, cmds))
        stash = _stash_entries(p)
        if stash:
            print("NOTE     target/%s holds %s (%s) — saved work no window shows; apply it in a window's worktree "
                  "(git -C worktrees/<NN>/%s stash apply) or drop it once it is not needed"
                  % ((key,) + _stash_words(stash) + (key,)))
        _, cur, _ = _git(p, "branch", "--show-current")
        cur = cur.strip()
        try:
            parked, elsewhere = _branches(p, trunk, cur)
        except Stop:
            parked, elsewhere = [], []
        loose = _loose(p, key, ll.repos_of(root))     # every configured nested repo, cloned or not
        if loose:                       # untracked files in a target checkout: work no window holds (critic finding 2)
            if pend:
                print("NOTE     target/%s has untracked files no window holds (%s) — the upgrade stops on them until "
                      "they are picked up (core/lease.sh adopt --all-unfinished) or moved out of target/%s"
                      % (key, ll.name_paths(loose), key))
            else:
                print("NOTE     target/%s has untracked files no window holds (%s) — target/%s is the trunk mirror, "
                      "which no session works in; move them into a window's worktree (worktrees/<NN>/%s) or remove "
                      "them" % (key, ll.name_paths(loose), key, key))
        mine = [] if LEASE_BRANCH.fullmatch(cur) or cur == trunk else [cur or "HEAD"]
        for path, what in _hand_worktrees(root, p):     # work in a worktree made by hand (review 3, finding 5)
            print("NOTE     target/%s has a worktree made by hand at %s, %s — no window has that work; commit it on a "
                  "branch and run core/lease.sh adopt <branch>%s, or remove that worktree once it is not needed"
                  % (key, path, what, flag))
        for b, path, work in elsewhere:  # checked out in another worktree: adopt cannot take it there (review 1)
            if not _carried(p, b, mine):
                print("NOTE     target/%s has branch %s, %s past origin/%s, in no window — it %s"
                      % (key, b, _plural(len(work), "commit"), trunk, _elsewhere_words(key, b, path, flag)))
        for b, work in parked:          # a branch beside the checkout, in no window (critic finding 1)
            if _carried(p, b, mine):
                continue
            print("NOTE     target/%s has branch %s, %s past origin/%s, in no window — %s"
                  % (key, b, _plural(len(work), "commit"), trunk,
                     "the upgrade stops on it until it is picked up (core/lease.sh adopt --all-unfinished, or "
                     "core/lease.sh adopt %s%s)" % (b, flag) if pend else "run core/lease.sh adopt %s%s to turn it into a window"
                     % (b, flag)))
        if cur == trunk:
            _, out, _ = _git(p, "rev-list", "--count", "%s..refs/heads/%s" % (_origin(trunk), trunk))
            n = int(out.strip() or 0)
            held = _carried_by(root, p, key, trunk) if n else None
            if held:
                # a window an adoption made already holds them; only the reset is left — cut off part-way, or never
                # reached (release-candidate review 4, finding 5): never "moves the commit" a second time
                print("NOTE     target/%s %s is %s ahead of origin/%s, but window %s already holds %s — %s"
                      % (key, trunk, _plural(n, "commit"), trunk, held, "it" if n == 1 else "them",
                         "the upgrade resets %s to origin/%s at the next session start; do not commit there" % (trunk, trunk)
                         if pend else "reset it (git -C target/%s reset --hard origin/%s)" % (key, trunk)))
            elif n:
                what = "the commit" if n == 1 else "the commits"
                print("MISSING  target/%s %s is %s ahead of origin/%s — trunk is reached only through promote; %s"
                      % (key, trunk, _plural(n, "commit"), trunk,
                         "the upgrade stops on %s until %s picked up (core/lease.sh adopt --all-unfinished)"
                         % (what, "it is" if n == 1 else "they are") if pend
                         else "run core/lease.sh adopt %s%s to move %s to a window" % (trunk, flag, what)))
            continue
        if LEASE_BRANCH.fullmatch(cur):
            print("NOTE     target/%s is on %s, a window's branch — target/%s is the trunk mirror; put it back with "
                  "git -C target/%s checkout %s" % (key, cur, key, key, trunk))
            continue
        try:
            work = _work(p, trunk, cur or "HEAD")
        except ll.Refused:
            continue
        name = cur or "no branch (a detached checkout)"
        if work and cur:
            fix = ("the upgrade stops on it until it is picked up (core/lease.sh adopt --all-unfinished, or "
                   "core/lease.sh adopt %s%s)" % (cur, flag)) if pend else "run core/lease.sh adopt %s%s to turn it into a window" % (cur, flag)
        elif work:
            fix = ("the upgrade stops on it until it is picked up (core/lease.sh adopt --all-unfinished)" if pend else
                   "name it (git -C target/%s branch <name>), then run core/lease.sh adopt <name>%s" % (key, flag))
        else:
            fix = ("the upgrade puts it back on %s at the next session start" % trunk if pend else
                   "put it back with git -C target/%s checkout %s" % (key, trunk))
        if work:
            print("NOTE     target/%s is on %s, %s past origin/%s — %s" % (key, name, _plural(len(work), "commit"), trunk, fix))
        else:
            print("NOTE     target/%s is on %s, whose commits are already on origin/%s — %s" % (key, name, trunk, fix))
    try:
        hot = (root / "vault" / "hot.md").read_text().split("\n")
    except OSError:
        hot = []
    if _hot_session_line(hot) is not None:
        print("NOTE     vault/hot.md still carries session: — %s" % ("the upgrade renames it to leases: at the next "
              "session start" if pend else "rename it to leases: in the prime's next vault commit"))
    return 0


# --- going back to v0.6.1: --rollback ------------------------------------------------------------------------------
# The operator's way back (asked 2026-10-08, "If there's an issue can I revert?"): an upgraded home is put where the
# v0.6.1 code runs as before, and the operator then switches the code with the one command it prints — this script
# is part of that code, so it never switches it itself. Nothing is discarded: unsaved work in a window is a commit on
# its lease/<NN>, ignored files are moved aside, every branch stays, a branch the upgrade picked up gets its own name
# back, target/<repo> goes back on the branch it was on, a pre-push hook that is not only Daedalus's shim stays.
# Every window is checked before anything changes: one that cannot be saved or removed safely stops the rollback
# with nothing changed. Running it again is safe; --dry-run says what it would do and changes nothing.

ROLLBACK_TO = "v0.6.1"
KEPT = Path("state") / "rollback-kept"
# the newest safety copy when a rollback finished: the next rollback reads where target/ was before the upgrade from
# the oldest copy after it (an upgrade after a rollback takes copies of its own)
ROLLED_BACK = Path("state") / "rollback-done"
SAVED_MSG = "Unsaved work in window %s, saved before going back to " + ROLLBACK_TO
LIVE_REFUSED = ("Not going back to %s: %s live in this home — %s. Close them, then run this again from a terminal, or "
                "add --force to go ahead while they run. Nothing was changed.")
ROLLBACK_STOPPED = ("Stopped here: nothing after this step was changed. Once each of the above is dealt with, run "
                    "python3 core/upgrade.py --rollback again; it picks up where it stopped.")


def _both(words: List[str]) -> str:
    return " and ".join(words) if len(words) < 3 else _and(words)


def _live_sessions(root: Path) -> List[str]:
    """The Daedalus sessions live in this home, in words: each window's and the pen's session (its registry entry,
    or the process its lease recorded), then each session whose start record (state/session-<id>.json) has a live
    registry entry; and a run of the upgrade in the background."""
    import leaselib as ll
    out: List[str] = []
    seen: Set[str] = set()
    try:
        leases = ll.read_all(root)
    except ll.Refused:
        leases = {}
    for nn in sorted(leases, key=lambda k: (k == "prime", k)):
        d = leases[nn]
        sid = str(d.get("session_id") or "")
        if not sid or sid in seen:
            continue
        live = bool(ll.registry_live_entries(sid))
        if not live and d.get("pid"):
            live = ll.pid_is_recorded_process(d.get("pid"), d.get("proc_started"), d.get("proc_start"))
        if live:
            seen.add(sid)
            out.append("the session holding the pen (session %s)" % sid if nn == "prime"
                       else "window %s (session %s)" % (nn, sid))
    for f in sorted((root / "state").glob("session-*.json")):
        sid = str((_read_json(f) or {}).get("session_id") or "")
        if sid and sid not in seen and ll.registry_live_entries(sid):
            seen.add(sid)
            out.append("session %s" % sid)
    if _bg_running(root):
        out.append("the upgrade's run in the background")
    return out


def _windows(root: Path) -> List[dict]:
    """Every window's worktree: each linked worktree of a target repo that git records under worktrees/<NN>/, as
    {key, src, path, rel, nn, branch, head, locked, admin}, deepest first (a nested repo's worktree lies inside its
    outer repo's)."""
    import leaselib as ll
    base = os.path.realpath(str(root / "worktrees"))
    found: List[dict] = []
    for key, p in target_repos(root):
        records = ll.worktree_records(p)
        code, out, _ = _git(p, "worktree", "list", "--porcelain")
        if code != 0:
            continue
        for block in out.strip().split("\n\n"):
            f: Dict[str, str] = {}
            for ln in block.splitlines():
                k, _, val = ln.partition(" ")
                f[k] = val
            path = f.get("worktree", "")
            real = os.path.realpath(path) if path else ""
            if not real.startswith(base + os.sep):
                continue
            nn = os.path.relpath(real, base).split(os.sep, 1)[0]
            if not ll.valid_id(nn):
                continue
            br = f.get("branch", "")
            found.append({"key": key, "src": p, "path": path, "rel": _rel(root, real), "nn": nn,
                          "branch": br[len("refs/heads/"):] if br.startswith("refs/heads/") else "",
                          "head": f.get("HEAD", ""), "locked": "locked" in f, "admin": records.get(real)})
    return sorted(found, key=lambda w: (-w["rel"].count("/"), w["rel"]))


def _wt_spec(wp: Path, nested: List[str]) -> List[str]:
    """The pathspec for everything in a window's worktree but its nested repos: an exclude for each one git does not
    ignore already (git add refuses a pathspec naming an ignored path)."""
    return ["."] + [":(exclude)" + n for n in nested
                    if (wp / n).exists() and _git(wp, "check-ignore", "-q", "--no-index", n)[0] != 0]


def _wt_status(w: dict, nested: List[str]) -> Tuple[int, int]:
    """(changed tracked files, untracked files that are not ignored) in a window's worktree, its nested repos left
    out."""
    spec = _wt_spec(Path(w["path"]), nested)
    code, out, err = _git(Path(w["path"]), "status", "--porcelain", "-z", "--untracked-files=all",
                          "--ignore-submodules=all", "--no-renames", "--", *spec)
    if code != 0:
        raise Stop("could not read %s's status (%s)" % (w["rel"], _last(err)))
    entries = [e for e in out.split("\0") if len(e) > 3]
    return len([e for e in entries if not e.startswith("??")]), len([e for e in entries if e.startswith("??")])


def _wt_problems(root: Path, w: dict, keys: List[str]) -> List[str]:
    """Why a window's worktree cannot be saved and removed safely, each with what to do; [] when it can."""
    import leaselib as ll
    wp, rel, want = Path(w["path"]), w["rel"], "lease/" + w["nn"]
    if not wp.is_dir():
        return []
    out = []
    for what, cmd in _busy(wp):
        out.append("%s is in the middle of a %s — finish it, or stop it (git -C %s %s --abort)"
                   % (rel, what, _sh(rel), cmd))
    if w["locked"]:
        out.append("%s is locked against removal — if nothing is still checking it out, unlock it (git -C target/%s "
                   "worktree unlock %s)" % (rel, w["key"], _sh(w["path"])))
    if w["admin"] is not None and (Path(w["admin"]) / "modules").exists():
        out.append("%s has had a submodule checked out in it, and git will not remove such a worktree: the submodule's "
                   "own repository is kept in git's record of it (%s), which the removal deletes — once what that "
                   "submodule holds is pushed or kept elsewhere, and %s's own changes are committed on %s, remove it "
                   "yourself (git -C target/%s worktree remove --force %s), then run this again"
                   % (rel, _rel(root, str(Path(w["admin"]) / "modules")), rel, want, w["key"], _sh(w["path"])))
    if w["branch"] != want:
        on = w["branch"] or "no branch (a detached checkout)"
        out.append("%s is on %s, not on its window's branch %s — commit what is there, then put the window's branch "
                   "on it (git -C %s checkout -B %s) once %s holds nothing else you need"
                   % (rel, on, want, _sh(rel), want, want))
    hidden = ll.hidden_edits(wp)
    if hidden:
        marks = sorted(set(hidden.values()))
        out.append("%s has changes git status does not show, in files marked %s (%s) — clear the mark (%s)"
                   % (rel, " or ".join(marks), ll.name_paths(sorted(hidden)),
                      ", and ".join("git -C %s update-index --no-%s %s" % (_sh(rel), m, ll.shell_paths(
                          sorted(x for x in hidden if hidden[x] == m))) for m in marks)))
    try:
        blind = ll.filtered_edits(wp) or ll.stat_blind_edits(wp)
    except subprocess.TimeoutExpired:      # never a silent pass
        blind = []
        out.append("%s could not be checked for changes git does not see (a git command ran out of time) — run this "
                   "again" % rel)
    if blind:
        out.append("%s has changes git does not see in %s — commit them on %s by hand there (touch them first, then "
                   "git add and git commit)" % (rel, ll.name_paths(sorted(blind)), want))
    nested = _nested_rels(w["key"], keys)
    for u in _loose(wp, w["key"], keys):
        if u.endswith("/"):
            out.append("%s holds a repository of its own at %s — move it out of the worktree" % (rel, u))
    for d in ll.unreadable_gits(wp):
        if not any(d == n or d.startswith(n + "/") for n in nested):
            out.append("%s holds a .git git cannot read at %s/ — move it out of the worktree" % (rel, d))
    return out


def _save_window(root: Path, w: dict, keys: List[str]) -> None:
    """The unsaved work in a window's worktree — changes to tracked files and untracked files that are not ignored,
    its nested repos left out — as one commit on its lease/<NN>, which the worktree has checked out; afterwards it
    reads clean."""
    wp, nested = Path(w["path"]), _nested_rels(w["key"], keys)
    env = _pick_env(wp)
    env.pop("GIT_LITERAL_PATHSPECS", None)
    spec = _wt_spec(wp, nested)
    code, _, err = _git_env(wp, env, "add", "-A", "--", *spec)
    if code == 0:
        code, tree, err = _git_env(wp, env, "write-tree")
    if code == 0:
        code, sha, err = _git_env(wp, env, "commit-tree", "--no-gpg-sign", tree.strip(), "-p", w["head"],
                                  "-m", SAVED_MSG % w["nn"])
    if code == 0:
        code, _, err = _git(wp, "update-ref", "-m", "rollback: unsaved work", "refs/heads/lease/" + w["nn"],
                            sha.strip(), w["head"])
    if code != 0:
        raise Stop("could not save %s's unsaved work on lease/%s (%s)" % (w["rel"], w["nn"], _last(err)))


def _ignored_in(w: dict, keys: List[str]) -> List[str]:
    """Every ignored entry of a window's worktree, empty or not (a wholly ignored directory is one "<dir>/"), its
    nested repos left out: a worktree's removal deletes them."""
    wp = Path(w["path"])
    code, out, _ = _git(wp, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z")
    return sorted(_beside_nested(wp, [u for u in (out.split("\0") if code == 0 else []) if u],
                                 _nested_rels(w["key"], keys)))


def _move_aside(src: Path, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(str(src), str(dest))
    except OSError:
        shutil.move(str(src), str(dest))


def _hot_was(root: Path) -> Optional[str]:
    """vault/hot.md's `session:` line as the vault's history last had it before the upgrade renamed it."""
    vault = root / "vault"
    code, out, _ = _git(vault, "log", "-n", "200", "--format=%H", "--", "hot.md")
    for sha in (out.split() if code == 0 else []):
        code, text, _ = _git(vault, "show", "%s:hot.md" % sha)
        if code != 0:
            continue
        lines = text.split("\n")
        i = _hot_session_line(lines)
        if i is not None:
            return lines[i]
    return None


def _lease_branches(root: Path, notes: Optional[Dict[Tuple[str, str], str]] = None) -> List[str]:
    """Each lease/<NN> branch in each target repo, with what it holds that origin's trunk does not have, and its note
    in <notes> ({(repo, lease/<NN>): words}) when it has one."""
    import leaselib as ll
    out = []
    outer = v.target_branch(root)
    for key, p in target_repos(root):
        _, refs, _ = _git(p, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads/lease/")
        names = [b for b in refs.split() if LEASE_BRANCH.fullmatch(b)]
        if not names:
            continue
        try:
            trunk: Optional[str] = ll.trunk_of(root / "target", key, outer)
        except Exception:
            trunk = None
        for b in names:
            note = (" — " + notes[(key, b)]) if notes and (key, b) in notes else ""
            if trunk is None:
                _, subj, _ = _git(p, "log", "-1", "--format=%s", "refs/heads/" + b)
                out.append("%s in target/%s: its last commit is \"%s\"%s" % (b, key, subj.strip(), note))
                continue
            _, subj, _ = _git(p, "log", "--format=%s", "%s..refs/heads/%s" % (_origin(trunk), b))
            subj = [s for s in subj.splitlines() if s.strip()]
            if subj:
                out.append("%s in target/%s: %s origin/%s does not have (\"%s\"%s)%s"
                           % (b, key, _plural(len(subj), "commit"), trunk, subj[0],
                              "" if len(subj) == 1 else ", the newest", note))
            else:
                out.append("%s in target/%s: nothing origin/%s does not have%s" % (b, key, trunk, note))
    return out


def _rollback_stops(root: Path, wins: List[dict], keys: List[str]) -> List[str]:
    """Everything that stops the rollback, found before it changes anything, so that a window it cannot save or
    remove never leaves the others half done: each window's problems (_wt_problems), a window whose directory is
    gone while git's record of it holds something, and a window's worktree holding a repository that is no window's
    worktree (its removal would delete it)."""
    import leaselib as ll
    out: List[str] = []
    rels = {w["rel"] for w in wins}
    for w in wins:
        rel, wp = w["rel"], Path(w["path"])
        if not wp.is_dir():
            holds = ll.record_holds(w["admin"]) if w["admin"] is not None else []
            if w["admin"] is not None and (Path(w["admin"]) / "modules").exists():
                holds.append("a submodule's own repository")
            if holds:
                out.append("%s is gone, but git's record of it holds %s — put the directory back where it was "
                           "(git -C target/%s worktree repair <its new place>)" % (rel, _and(holds), w["key"]))
            continue
        out += _wt_problems(root, w, keys)
        for n in _nested_rels(w["key"], keys):
            if (wp / n).exists() and "%s/%s" % (rel, n) not in rels:
                out.append("%s holds %s/%s, which is not a window's worktree — move it out of the worktree"
                           % (rel, rel, n))
    return out


def _no_worktree(root: Path, nns: List[str], dry: bool) -> List[str]:
    """Mark each window of <nns> worktree_ready false in state/leases/ — on this release again, the next session start
    (a picked-up window) or core/lease.sh claim <NN> then makes its worktree from its branch. The ones it marked (or,
    dry, would mark): not prime, a released window, or one marked already."""
    import leaselib as ll
    out = []
    with ll.lock(root, shared=dry):
        for nn in nns:
            d = ll.read_lease(root, nn)
            if nn == "prime" or d is None or d.get("released") or d.get("worktree_ready") is False:
                continue
            if not dry:
                d["worktree_ready"] = False
                ll.write_lease(root, nn, d)
            out.append(nn)
    return out


def _worktrees_missing(root: Path) -> List[str]:
    """Each window in state/leases/ whose record does not say it has no worktree while one of its worktrees
    (worktrees/<NN>/<repo>) is not there — removed by an earlier run that stopped, or by hand."""
    import leaselib as ll
    try:
        leases = ll.read_all(root)
    except ll.Refused:
        return []
    out = []
    for nn, d in sorted(leases.items()):
        if nn == "prime" or d.get("released") or d.get("worktree_ready") is False:
            continue
        repos = list(d.get("trunks") or {}) or [str(r) for r in (d.get("repos") or [])]
        if any(not (root / "worktrees" / nn / r).is_dir() for r in repos):
            out.append(nn)
    return out


_LABELS = (("daedalus/upgrade-", "it holds the commits target/%s's %s had that origin/%s did not; %s was reset to "
                                 "origin/%s (to have them on it again: git -C target/%s merge %s, on %s)"),
           ("daedalus/unsaved-", "it holds the changes that were not committed in target/%s, as one commit"),
           ("daedalus/detached-", "it holds target/%s's detached checkout"),
           ("daedalus/stash-", "it holds a stash entry of target/%s, as a commit"))


def _old_names(root: Path, dry: bool) -> Tuple[Dict[Tuple[str, str], str], Dict[Tuple[str, str], str]]:
    """Each window picked up from a branch of target/<repo> (its lease's adopted_from and adopted_repo) gets that name
    back at its lease/<NN>'s tip, made with a plain git branch where no branch has it, so it never moves one —
    its upstream settings, which the upgrade's removal of the name left, come back with it; one that is there
    already is left as it is. A name Daedalus made (daedalus/...) is said in words, never made. Returns
    ({(repo, lease/<NN>): its note}, {(repo, name): the commit it is at, or would be}) — the second for the
    checkout back to the branch target/<repo> was on."""
    import leaselib as ll
    notes: Dict[Tuple[str, str], str] = {}
    at: Dict[Tuple[str, str], str] = {}
    try:
        leases = ll.read_all(root)
    except ll.Refused:
        return notes, at
    for nn, d in sorted(leases.items()):
        key, orig = str(d.get("adopted_repo") or ""), str(d.get("adopted_from") or "")
        if nn == "prime" or not key or not orig:
            continue
        p, lease = root / "target" / key, "lease/" + nn
        tip = ll.ref_oid(p, "refs/heads/" + lease) if p.is_dir() else None
        if not tip:
            continue
        label = next((words for pre, words in _LABELS if orig.startswith(pre)), None)
        if label is not None:
            if orig.startswith("daedalus/upgrade-"):
                trunk = str((d.get("trunks") or {}).get(key) or "its trunk")
                notes[(key, lease)] = label % (key, trunk, trunk, trunk, trunk, key, lease, trunk)
            else:
                notes[(key, lease)] = label % key
            continue
        have = ll.ref_oid(p, "refs/heads/" + orig)
        if have == tip:
            notes[(key, lease)] = "it was %s before the upgrade, which is at the same commit" % orig
            at[(key, orig)] = tip
        elif have:
            notes[(key, lease)] = ("it was %s before the upgrade; a branch of that name is there already, at another "
                                   "commit, and is left as it is" % orig)
            at[(key, orig)] = have
        elif dry:
            notes[(key, lease)] = "it was %s before the upgrade; would give it that name back" % orig
            at[(key, orig)] = tip
        else:
            code, _, err = _git(p, "branch", "--no-track", orig, tip)
            if code == 0:
                notes[(key, lease)] = "it was %s before the upgrade; gave it that name back" % orig
                at[(key, orig)] = tip
            else:
                notes[(key, lease)] = ("it was %s before the upgrade; could not give it that name back (%s) — "
                                       "git -C target/%s branch %s %s" % (orig, _last(err), key, _sh(orig), lease))
    return notes, at


def _before_upgrade(root: Path) -> Dict[str, Tuple[str, str]]:
    """{repo: (the branch target/<repo> was on before the upgrade, "" when detached; its commit)}, read from the oldest
    safety copy taken since the last rollback finished; {} when there is none."""
    try:
        after = (root / ROLLED_BACK).read_text().strip()
    except OSError:
        after = ""
    snaps = [x for x in _snapshots(root) if x > after]
    if not snaps:
        return {}
    man = _read_json(root / SNAPS / snaps[0] / "manifest.json") or {}
    keys = {os.path.realpath(str(p)): key for key, p in target_repos(root)}
    out: Dict[str, Tuple[str, str]] = {}
    for r in man.get("repos") or []:
        key = keys.get(os.path.realpath(str(r.get("path") or ""))) if r.get("path") else None
        main = next((w for w in r.get("worktrees") or [] if w.get("i") == 0), None)
        if key is None or main is None:
            continue
        br = str(main.get("branch") or "")
        out[key] = (br[len("refs/heads/"):] if br.startswith("refs/heads/") else "", str(main.get("head") or ""))
    return out


def _checkouts_back(root: Path, keys: List[str], at: Dict[Tuple[str, str], str], dry: bool) -> List[str]:
    """Each target/<repo> the upgrade moved off the branch it was on is put back on it with git checkout — only while
    it is still on its trunk where the upgrade left it, has no uncommitted change, untracked file or git operation
    in progress, and nothing untracked or ignored is where that branch has a file; otherwise the line says what to
    run. <at>: the names _old_names gives back (in a dry run, not made yet)."""
    import leaselib as ll
    outer = v.target_branch(root)
    out = []
    for key, (was, head) in sorted(_before_upgrade(root).items()):
        p = root / "target" / key
        if not p.is_dir():
            continue
        _, cur, _ = _git(p, "branch", "--show-current")
        cur = cur.strip()
        if not was:
            if head and _git(p, "rev-parse", "HEAD")[1].strip() != head:
                out.append("target/%s was on a detached checkout before the upgrade (%s); it is on %s now — to go back "
                           "to it: git -C target/%s checkout --detach %s" % (key, head[:12], cur or "another commit",
                                                                             key, head[:12]))
            continue
        if cur == was:
            continue
        sha = at.get((key, was)) or ll.ref_oid(p, "refs/heads/" + was)
        if not sha:
            out.append("target/%s was on %s before the upgrade, which is no branch now; it stays on %s"
                       % (key, was, cur or "a detached checkout"))
            continue
        try:
            trunk: Optional[str] = ll.trunk_of(root / "target", key, outer)
        except Exception:
            trunk = None
        why = []
        if cur != trunk:
            why.append("it is on %s now, not on %s where the upgrade left it" % (cur or "a detached checkout",
                                                                                 trunk or "its trunk"))
        else:
            code, st, _ = _git(p, "status", "--porcelain", "--untracked-files=no", "--ignore-submodules=all")
            if code != 0 or st.strip() or ll.hidden_edits(p):
                why.append("it has uncommitted changes")
            if _loose(p, key, keys):
                why.append("it has untracked files")
            if _busy(p):
                why.append("a git operation is in progress there")
            if not why and (ll.gitlinks_in_way(p, [sha]) or ll.untracked_in_way(p, [sha])):
                why.append("files git does not track are where %s has files" % was)
        if why:
            out.append("target/%s was on %s before the upgrade and is left on %s, because %s — to go back: "
                       "git -C target/%s checkout %s" % (key, was, cur or "a detached checkout", _and(why), key,
                                                         _sh(was)))
            continue
        if not dry:
            code, _, err = ll.git_finish(p, "checkout", "--quiet", was)
            if code != 0:
                out.append("could not put target/%s back on %s (%s) — git -C target/%s checkout %s"
                           % (key, was, _last(err), key, _sh(was)))
                continue
        out.append("%s target/%s back on %s, the branch it was on before the upgrade"
                   % ("would put" if dry else "put", key, was))
    return out


ROLLBACK_TRACKED = ("Not rolled back: this home tracks %d files no release has (%s, …); `git checkout %s` would take "
                    "them out of the working tree. Nothing was changed.")


def rollback(root: Path, dry: bool = False, force: bool = False) -> int:
    """python3 core/upgrade.py --rollback [--dry-run] [--force]: the steps, in order, as one numbered list. A home
    that tracks files no release has (its vault, update.deployment_paths) is refused before anything: the last
    step's `git checkout v0.6.1` would take every one of them out of the working tree."""
    try:
        import update as upd
        dep = upd.deployment_paths(root)
    except Exception:
        dep = []
    if dep:
        print(ROLLBACK_TRACKED % (len(dep), dep[0], ROLLBACK_TO))
        return 1
    import leaselib as ll
    import prepush
    os.environ["GIT_OPTIONAL_LOCKS"] = "0"      # git status reads; it never rewrites an index here
    live = _live_sessions(root)
    if live and not force:
        print(LIVE_REFUSED % (ROLLBACK_TO, _plural(len(live), "Daedalus session") + (" is" if len(live) == 1 else
                                                                                     " are"), _both(live)))
        return 1
    fd = None
    if not dry:
        fd = _lock(root, time.time() + 10)
        if fd is None:
            print("Not going back to %s: the upgrade is running in this home right now. Try again in a minute. "
                  "Nothing was changed." % ROLLBACK_TO)
            return 1
    would = (lambda now, then: then) if dry else (lambda now, then: now)
    steps: List[List[str]] = []

    def say(*lines: str) -> None:
        steps.append(list(lines))

    def show(stopped: bool = False) -> None:
        print("Going back to %s%s:" % (ROLLBACK_TO, " (dry run: nothing is changed)" if dry else ""))
        for i, lines in enumerate(steps, 1):
            print("%d. %s" % (i, lines[0]))
            for ln in lines[1:]:
                print("   - " + ln)
        if stopped:
            print(ROLLBACK_STOPPED)

    try:
        say("No Daedalus session is live in this home." if not live else
            "Going ahead with --force while %s %s live: %s." % (_plural(len(live), "session"),
                                                                 "is" if len(live) == 1 else "are", _both(live)))
        try:
            keys = ll.repos_of(root)
        except ll.Refused:
            keys = []
        wins = _windows(root)
        # every window checked before anything changes: one it cannot save or remove stops it with nothing changed
        stops = _rollback_stops(root, wins, keys)
        if stops:
            say("Window worktrees: %s %s the rollback, so nothing was changed:"
                % (_plural(len(stops), "thing"), "stops" if len(stops) == 1 else "stop"), *stops)
            show(stopped=True)
            return 1
        # 2. unsaved work, each window's own commit on its lease/<NN>
        saved = []
        for w in sorted(wins, key=lambda w: w["rel"]):
            if not os.path.isdir(w["path"]):
                continue
            changed, untracked = _wt_status(w, _nested_rels(w["key"], keys))
            if not changed and not untracked:
                continue
            words = ", ".join(x for x in (_plural(changed, "changed file") if changed else "",
                                          _plural(untracked, "untracked file") if untracked else "") if x)
            if not dry:
                _save_window(root, w, keys)
            saved.append("%s window %s's unsaved work in %s (%s) as one commit on lease/%s"
                         % (would("saved", "would save"), w["nn"], w["rel"], words, w["nn"]))
        if saved:
            say("Unsaved work in the windows, kept as commits:", *saved)
        else:
            say("No window has unsaved work to save.")
        # 3. the worktrees, deepest first; ignored files moved aside first, never deleted. Each window is marked as
        # having no worktree just before git removes one of its worktrees, so a run cut off or stopped part-way never
        # leaves a record saying a removed worktree is there (forward again, claim <NN> would make none)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        moved, removed, stuck = [], [], []
        marked: Set[str] = set()
        gone: Set[str] = set()
        for w in wins:
            rel, wp = w["rel"], Path(w["path"])
            if not wp.is_dir():
                marked.update(_no_worktree(root, [w["nn"]], dry))
                if not dry:
                    ll.prune_under(w["src"], root / "worktrees")
                removed.append("%s (its directory was already gone; git's record of it %s)"
                               % (rel, would("is removed", "would be removed")))
                continue
            inside = [x["rel"] for x in wins if x is not w and x["rel"].startswith(rel + "/")
                      and os.path.isdir(x["path"]) and x["rel"] not in gone]
            inside += ["%s/%s" % (rel, n) for n in _nested_rels(w["key"], keys) if (wp / n).exists()
                       and "%s/%s" % (rel, n) not in inside and not dry]
            if inside:
                stuck.append("%s still holds %s, which was not removed" % (rel, _and(inside)))
                continue
            ign = _ignored_in(w, keys)
            if ign:
                dest = root / KEPT / stamp / w["nn"] / w["key"]
                if not dry:
                    for u in ign:
                        _move_aside(wp / u.rstrip("/"), dest / u.rstrip("/"))
                moved.append("%s window %s's ignored files in %s (%s) to %s/ — git ignores them, so no commit "
                             "holds them" % (would("moved", "would move"), w["nn"], rel, ll.name_paths(ign),
                                             _rel(root, str(dest))))
            marked.update(_no_worktree(root, [w["nn"]], dry))
            if not dry:
                code, _, err = _git(w["src"], "worktree", "remove", w["path"])
                if code != 0:
                    stuck.append("git would not remove %s (%s) — deal with what it names, then run this again"
                                 % (rel, _last(err)))
                    continue
            removed.append(rel)
            gone.add(rel)
        lines = moved + (["%s %s — their branches stay" % (would("removed", "would remove"), ", ".join(removed))]
                         if removed else [])
        # forward again: no window's record may say a worktree is there that is not — whatever removed it (an earlier
        # run that stopped, or a hand), on this release the next start or core/lease.sh claim <NN> makes it again
        marked.update(_no_worktree(root, _worktrees_missing(root), dry))
        if marked:
            lines.append("%s %s in state/leases/ as having no worktree, so on this release again the next session "
                         "start or core/lease.sh claim <NN> makes it from its branch"
                         % (would("marked", "would mark"), _both(["window " + nn for nn in sorted(marked)])))
        if stuck:
            say("Window worktrees: %s could not be removed:" % _plural(len(stuck), "thing"), *(lines + stuck))
            show(stopped=True)
            return 1
        say("Window worktrees removed with git worktree remove:" if lines and not dry else
            "Window worktrees, removed with git worktree remove:" if lines else "No window worktree is left.", *lines)
        # 4. every lease branch stays; a branch the upgrade picked up gets its own name back
        notes, at = _old_names(root, dry)
        branches = _lease_branches(root, notes)
        if branches:
            say("Every window's branch is kept; v0.6.1 can check any of them out (git -C target/<repo> checkout "
                "lease/<NN>):", *branches)
        else:
            say("There is no window branch to keep.")
        # 5. each target checkout back on the branch it was on before the upgrade
        back = _checkouts_back(root, keys, at, dry)
        if back:
            say("Target checkouts:", *back)
        # 5. the pre-push hook, only where it is Daedalus's own shim
        hooks = []
        for key, p in target_repos(root):
            try:
                hp = prepush.hook_path(p)
            except ValueError:
                continue
            if hp.is_file() or hp.is_symlink():
                try:
                    text = hp.read_text(errors="replace")
                except OSError:
                    text = ""
                if prepush._only_a_shim(text):
                    if not dry:
                        hp.unlink()
                    hooks.append("%s the pre-push hook Daedalus installed in target/%s" % (would("removed",
                                                                                          "would remove"), key))
                else:
                    hooks.append("target/%s's pre-push hook is not Daedalus's; it is left as it is" % key)
            if not dry and hp.exists():
                continue
            for kept in sorted(hp.parent.glob("pre-push.before-daedalus-*")):
                hooks.append("the hook target/%s had before the upgrade is kept as %s; to have it run again: mv %s %s"
                             % (key, _rel(root, str(kept)), _sh(_rel(root, str(kept))), _sh(_rel(root, str(hp)))))
        say("Pre-push hooks:", *hooks) if hooks else say("No target repo has a pre-push hook of Daedalus's.")
        # 6. hot.md's session: line
        hot = root / "vault" / "hot.md"
        try:
            hl = hot.read_text().split("\n")
        except OSError:
            hl = []
        end = next((i for i in range(1, len(hl)) if hl and hl[0].strip() == "---" and hl[i].strip() == "---"), None)
        at = next((i for i in range(1, end) if hl[i] == HOT_LEASES), None) if end else None
        if at is not None and not any(ln.startswith("session:") for ln in hl[1:end]):
            was = _hot_was(root)
            line = was or "session: NNN"
            if not dry:
                hl[at] = line
                _write(hot, "\n".join(hl))
            say("%s vault/hot.md's session: line back (%s)%s." % (
                would("Put", "Would put"), line, "" if was else " — the vault's history does not hold the number "
                "it had; the next session log sets it"))
        else:
            say("vault/hot.md needs nothing: the upgrade did not rename its session: line, or it is back already.")
        # 7. what stays, which v0.6.1 does not read
        stays = ("Left as they are, because v0.6.1 does not read them: config.yaml's memory: block, %s, state/leases/ "
                 "and the other directories the upgrade made." % KEY_FILE)
        mem = any(ln.startswith("memory:") for ln in (root / "config.yaml").read_text().splitlines()) \
            if (root / "config.yaml").is_file() else False
        if mem and _hook_prefixes(root) is None:
            stays += (" v0.6.1's capture reads its settings only from the hook line in .claude/settings.local.json, "
                      "which is gone: put it back before you start a session on v0.6.1, or capture stops.")
        elif mem:
            stays += (" v0.6.1's capture keeps reading its settings from the hook line in .claude/settings.local.json, "
                      "which the upgrade left in place.")
        say(stays)
        snaps = _snapshots(root)
        say("The safety copy in state/upgrade-snapshot/ is kept (%s); v0.6.1 does not read it." % ", ".join(snaps)
            if snaps else "There is no safety copy to keep.")
        # 8. the stamp; the next rollback reads only the safety copies taken after this one
        if not dry:
            _write(root / ROLLED_BACK, (snaps[-1] if snaps else "") + "\n")
        if (root / STAMP).exists():
            if not dry:
                (root / STAMP).unlink()
            say("%s state/upgraded-to." % would("Removed", "Would remove"))
        else:
            say("state/upgraded-to is gone already.")
        show()
        home = _sh(str(root))
        print("Last step, yours to run: put the code back. This script is part of that code, so it does not switch it "
              "itself. Start no session in this home until you have run it: a session started on this release "
              "upgrades the home again.")
        if _git(root, "rev-parse", "--verify", "-q", "refs/tags/%s^{commit}" % ROLLBACK_TO)[0] != 0:
            print("  git -C %s fetch origin tag %s" % (home, ROLLBACK_TO))
        print("  git -C %s checkout %s" % (home, ROLLBACK_TO))
        return 0
    except Stop as e:
        show()
        print("Stopped: %s. Nothing after that was changed; run python3 core/upgrade.py --rollback again once it is "
              "dealt with." % e)
        return 1
    finally:
        if fd is not None:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)


def main(argv: List[str]) -> int:
    root = v.ROOT
    args = argv[1:]
    if args == ["--doctor"]:
        return doctor(root)
    if args == ["--doctor-mods"]:
        stale_mods_doctor(root)
        return 0
    if args == ["--restore-help"]:
        return restore_help(root)
    if args == ["--forget-snapshot"]:
        return forget_snapshot(root)
    if args == ["--background"]:
        return background_main(root)
    if "--rollback" in args:
        if [a for a in args if a not in ("--rollback", "--dry-run", "--force")]:
            sys.stderr.write("usage: python3 core/upgrade.py --rollback [--dry-run] [--force]\n")
            return 2
        return rollback(root, dry="--dry-run" in args, force="--force" in args)
    if "--caller" in args:
        i = args.index("--caller")
        if args[i + 1:i + 2] != ["update"]:
            sys.stderr.write("usage: python3 core/upgrade.py ... --caller update\n")
            return 2
        args = args[:i] + args[i + 2:]
        _CALLER["update"] = True
    if [a for a in args if a not in ("--dry-run", "--setup", "--progress")]:
        sys.stderr.write("usage: python3 core/upgrade.py [--dry-run] [--setup] [--progress] [--caller update] | --doctor | "
                         "--doctor-mods | --restore-help | --forget-snapshot | --rollback [--dry-run] [--force]\n")
        return 2
    dry, upto = "--dry-run" in args, (3 if "--setup" in args else FULL)
    _PROGRESS["on"] = 1 if "--progress" in args else 0
    ver = version(root)
    if upto == FULL and ver is None:
        sys.stderr.write("daedalus: this checkout has no VERSION file, so there is nothing to upgrade to\n")
        return 1
    if upto == FULL and not dry and stamped(root) == ver:
        print("Already upgraded to %s; nothing to do." % ver)
        return 0
    if upto == FULL and not dry and _bg_running(root):
        print("The upgrade to %s is taking its safety copy of target/ in the background (state/upgrade.log); the "
              "board says when it is done." % ver)
        return 0
    lines, stop = run(root, dry=dry, upto=upto)
    for ln in lines:
        print(ln)
    if stop:
        print(("would stop: " if dry else "") + (_for_update(stop) if _CALLER["update"] else stop))
        return 0 if dry else 1
    if not lines:
        print("Nothing to do.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
