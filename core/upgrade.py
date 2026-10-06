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
  6. in-flight work in target/ moved into numbered windows (leaselib.adopt) — the checked-out branch, then
     every other local branch with work origin lacks, one window each (critic finding 1) — not one already
     squash-merged, and one checked out in another worktree or whose branch on origin is gone only named
     (release-candidate review, findings 1 and 3) — then a trunk still
     ahead of origin; the checked-out work's untracked files go into its window's worktree, copied and checked
     before the original is removed, and any no window takes are named (critic finding 2) — each checkout put back on its trunk at origin, after one bounded fetch of
     all of them at once (plan 5 Decision 3). It will not move a checkout with uncommitted changes (one
     hidden by skip-worktree or assume-unchanged included), nor one with an untracked or ignored file where
     the move back to the trunk would write, nor one with a local branch named origin/<trunk>, nor one where a
     rebase, merge, cherry-pick, revert or bisect stopped part-way (critic finding 3; release-candidate review
     2, findings 1-6): it stops there, saying what to do, and the board repeats the sentence until a later
     start finishes. A window an earlier, cut-off run made — lease file or not, worktree or not — is found
     again and finished, never made twice (review 2, findings 11-13).
  7. the stamp, state/upgraded-to, written last: a stopped upgrade runs again from the top next time

    python3 core/upgrade.py              every step now, as a session start would
    python3 core/upgrade.py --dry-run    what each step would do; changes nothing, fetches nothing
    python3 core/upgrade.py --setup      steps 1-3 (setup.sh's leases phase, spec §15); never stamps
    python3 core/upgrade.py --doctor     doctor's upgrade lines (§15)

Python 3.9, standard library.
"""
from __future__ import annotations

import fcntl
import filecmp
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

STAMP = Path("state") / "upgraded-to"
CONFIG_CHANGES = Path("state") / "config-changes.json"
CARRY = Path("state") / "upgrade-carry.json"
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
LEASE_BRANCH = re.compile(r"lease/[0-9]{2}")
FIELDS = (("TENANT_BANK", "bank"), ("HINDSIGHT_API_URL", "api_url"), ("TRANSCRIPT_DIR", "transcript_dir"),
          ("TENANT_USER_LABEL", "user_label"), ("TENANT_ASSISTANT_LABEL", "assistant_label"))
FETCH_SECS = 4          # one cap for every target repo's fetch together, never over half the deadline left
NOTE_ADOPTED = "adopted at the upgrade to %s"
# Commit, never stash: a stash stays in the trunk mirror, where no window shows it (critic finding 4).
DIRTY = ("upgrade to %s incomplete: target/%s has uncommitted changes — commit them on their branch inside that "
         "checkout, then start a session again")
STASHED = ("%s: target/%s holds %s (%s) — saved work no window shows; the upgrade leaves it there, and core/doctor.sh "
           "names it until it is applied or dropped.")
UNTRACKED = ("upgrade to %s incomplete: target/%s has untracked files that %s would overwrite (%s) — move them out "
             "of that checkout, or commit them on its branch, then start a session again")
# A local branch named origin/<trunk> shadows the remote-tracking ref in every bare "origin/<trunk>" git is given
# (release-candidate review 2, finding 5): stopped on before anything moves.
SHADOW = ("upgrade to %s incomplete: target/%s has a local branch named origin/%s, which git takes for origin's %s — "
          "rename it (git -C target/%s branch -m origin/%s <new name>), then start a session again")
# An edit to a tracked file marked skip-worktree or assume-unchanged is not in git status (review 2, finding 6).
HIDDEN = ("upgrade to %s incomplete: target/%s has uncommitted changes git status does not show, in files marked %s "
          "(%s) — clear the mark (%s), commit them on their branch inside that checkout, then start a session again")
# A branch whose branch on origin was deleted (on GitHub, what follows a merge) is not made a window: a squash merge
# leaves its commits looking unmerged to git cherry (release-candidate review, finding 3). Named, so one that was not
# merged can still be adopted.
GONE_ONE = ("%s: target/%s's branch %s holds commits origin/%s has no copy of, but its branch on origin was deleted, "
            "which usually means it was merged — it was left as it was; if it was not merged, run core/lease.sh adopt "
            "%s%s.%s")
GONE_MANY = ("%s: target/%s's branches %s hold commits origin/%s has no copy of, but their branches on origin were "
             "deleted, which usually means they were merged — they were left as they were; for any that was not "
             "merged, run core/lease.sh adopt <branch>%s.%s")
# A stop the upgrade cannot say will clear by itself names what to do if it comes back (review finding 3); only
# running out of time at a session start is sure to clear, so only it says "it runs again".
IN_PROGRESS = ("upgrade to %s incomplete: target/%s is in the middle of a %s — finish it with git -C target/%s %s "
               "--continue, or undo it with git -C target/%s %s --abort, then start a session again")
BISECTING = ("upgrade to %s incomplete: target/%s is in the middle of a bisect — end it with git -C target/%s bisect "
             "reset, then start a session again")
STOPPED_WHILE = ("upgrade to %s incomplete: stopped while %s — %s; it tries again at the next session start — if it "
                 "stops the same way again, ask this home's agent to look into the reason given")
STOPPED_TIME = "upgrade to %s incomplete: stopped while %s — the session start ran out of time; it runs again at the next session start"


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
    return v.run(["git", "-C", str(repo)] + list(args))


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
    done, other = [], []
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
        elif s2 != "unchanged":
            other.append(sentence.rstrip("."))
    lines = ["%s: %s the pre-push hook in %s." % (head, "would install" if dry else "installed", ", ".join(done))] \
        if done else []
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
    """`git fetch --quiet origin` in every target repo at once, all under one cap (plan 5 Decision 3):
    FETCH_SECS, and never more than half of what is left of `deadline`, so adoption's worktree adds keep the
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
        for key, p in repos:
            try:
                procs[key] = subprocess.Popen(["git", "-C", str(p), "fetch", "--quiet", "origin"],
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


def _origin(trunk: str) -> str:
    """origin/<trunk> as a revision a local branch of that name cannot shadow (release-candidate review 2, 5)."""
    return "refs/remotes/origin/" + trunk


def _ahead(p: Path, trunk: str) -> List[str]:
    """Subjects, oldest first, of the commits on the local trunk that origin/<trunk> lacks."""
    _, out, _ = _git(p, "log", "--reverse", "--format=%s", "%s..refs/heads/%s" % (_origin(trunk), trunk))
    return [s for s in out.splitlines() if s.strip()]


def _back_on_trunk(p: Path, key: str, trunk: str) -> None:
    code, _, err = _git(p, "checkout", "--quiet", trunk)
    if code != 0:
        raise Stop("could not put target/%s back on %s (%s)" % (key, trunk, _last(err)))
    _git(p, "merge", "--ff-only", "--quiet", _origin(trunk))


def _into_window(root: Path, key: str, rel: str, ref: str, ver: str, deadline: Optional[float]) -> dict:
    import leaselib as ll
    try:
        return ll.adopt(root, ref, repo=None if rel == key else rel, note=NOTE_ADOPTED % ver, fetch=False,
                        deadline=deadline)
    except ll.Refused as e:
        raise Stop("could not move target/%s's work into a window (%s)" % (key, e))


def _carried_by(root: Path, p: Path, key: str, trunk: str) -> Optional[str]:
    """The number of a window adopted from target/<key> whose lease/<NN> already holds the trunk's tip — made by
    an earlier run cut off before the trunk was reset (review finding 1). None when no window does."""
    import leaselib as ll
    for nn, d in sorted(ll.read_all(root).items()):
        if nn == "prime" or d.get("adopted_repo") != key:
            continue
        ref = "refs/heads/lease/" + nn
        if (_git(p, "rev-parse", "--verify", "-q", ref)[0] == 0
                and _git(p, "merge-base", "--is-ancestor", trunk, ref)[0] == 0):
            return nn
    return None


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
    hit = ll.untracked_in_way(p, refs, ignored_only=ignored_only)
    if hit:
        raise Stop(UNTRACKED % (ver, key, doing, ll.name_paths(hit)))


def _half_done(p: Path, key: str, ver: str) -> None:
    """Stop, before anything in target/ moves, when a git operation stopped part-way in target/<key> (critic
    finding 3): a rebase stopped at "edit" reads clean and its detached HEAD would be adopted without the rest of
    the branch, and the rebase left behind in the trunk mirror. Uses leaselib's markers, plus a bisect's."""
    import leaselib as ll
    for marker, what, cmd in tuple(ll._IN_PROGRESS) + (("BISECT_LOG", "bisect", "bisect"),):
        code, out, _ = _git(p, "rev-parse", "--git-path", marker)
        path = Path(out.strip()) if code == 0 and out.strip() else None
        if path is not None and not path.is_absolute():
            path = p / path
        if path is not None and path.exists():
            if what == "bisect":
                raise Stop(BISECTING % (ver, key, key))
            raise Stop(IN_PROGRESS % (ver, key, what, key, cmd, key, cmd))


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
    _, out, _ = _git(p, "for-each-ref", "--format=%(refname:short)", "refs/heads/lease/")
    for c in [b for b in out.split() if LEASE_BRANCH.fullmatch(b)] + extra:
        if c and c != ref and _git(p, "merge-base", "--is-ancestor", ref, c)[0] == 0:
            return True
    return False


def _checked_out_elsewhere(p: Path) -> Dict[str, str]:
    """{branch: path} for each branch checked out in a worktree of <p> other than <p> itself — one someone made by
    hand with `git worktree add`, or a window's. Such a branch cannot be checked out in a window's worktree: git
    refuses ("already used by worktree"), so adopting it fails on every run (release-candidate review, finding 1)."""
    code, out, _ = _git(p, "worktree", "list", "--porcelain")
    if code != 0:
        return {}
    here = os.path.realpath(str(p))
    found, path = {}, None
    for ln in out.splitlines() + [""]:
        if ln.startswith("worktree "):
            path = ln[len("worktree "):]
        elif ln.startswith("branch refs/heads/") and path is not None:
            if os.path.realpath(path) != here:
                found[ln[len("branch refs/heads/"):]] = path
        elif not ln:
            path = None
    return found


def _squashed(p: Path, trunk: str, b: str) -> bool:
    """Is <b>'s change already on origin/<trunk> although git cherry finds no equal commit — a squash merge, the
    usual way a branch reaches a GitHub trunk (release-candidate review, finding 3)? Yes when merging <b> into
    origin/<trunk> would change nothing: `git merge-tree --write-tree` (git 2.38+) gives origin/<trunk>'s own tree.
    No when the merge conflicts, or the git here cannot say."""
    code, out, _ = _git(p, "merge-tree", "--write-tree", _origin(trunk), b)
    if code != 0 or not out.strip():
        return False
    _, tree, _ = _git(p, "rev-parse", "%s^{tree}" % _origin(trunk))
    return out.split()[0] == tree.strip()


def _work(p: Path, trunk: str, rev: str) -> List[str]:
    """The subjects of <rev>'s commits that origin/<trunk> has no equivalent of (git cherry, as adopt judges) —
    none when <rev>'s change as a whole is already there (a squash merge)."""
    import leaselib as ll
    work = ll.unpromoted_commits(p, trunk, rev)
    return [] if work and _squashed(p, trunk, rev) else work


def _upstream_gone(p: Path, b: str) -> bool:
    """Was <b> tracking a branch on origin that is gone now — deleted there, which on GitHub follows a merge?"""
    code, out, _ = _git(p, "for-each-ref", "--format=%(upstream:track)", "refs/heads/" + b)
    return code == 0 and out.strip() == "[gone]"


def _branches(p: Path, trunk: str, skip: str) -> Tuple[List[Tuple[str, List[str]]], List[Tuple[str, str, List[str]]],
                                                        List[str]]:
    """The local branches of <p> other than <trunk>, <skip> (the checked-out one) and a window's lease/<NN> that
    hold commits origin/<trunk> has no equivalent of (critic finding 1), in three kinds:
      parked: (branch, subjects) — each becomes a window. Most commits first, so a branch built on another is
              adopted before it and the other is then found carried, never a second copy.
      elsewhere: (branch, path, subjects) — checked out in another worktree; named, never adopted (finding 1 of
              the release-candidate review: adopting it fails every time).
      gone: (branch, subjects) — its branch on origin was deleted, which usually follows a merge; named, left as
              it was (by doctor too: release-candidate review 2, finding 8).
    A branch whose change is already on origin/<trunk> (git cherry, or a squash merge) is none of them."""
    import leaselib as ll
    _, out, _ = _git(p, "for-each-ref", "--format=%(refname:short)", "refs/heads/")
    held = _checked_out_elsewhere(p)
    parked, elsewhere, gone = [], [], []
    for b in out.split():
        if b in (trunk, skip) or LEASE_BRANCH.fullmatch(b):
            continue
        try:
            work = _work(p, trunk, b)
        except ll.Refused as e:
            raise Stop("could not tell whether target branch %s holds work origin/%s lacks (%s)" % (b, trunk, e))
        if not work:
            continue
        if b in held:
            elsewhere.append((b, held[b], work))
        elif _upstream_gone(p, b):
            gone.append((b, work))
        else:
            parked.append((b, work))
    return sorted(parked, key=lambda bw: (-len(bw[1]), bw[0])), elsewhere, gone


def _elsewhere_words(key: str, b: str, path: str, flag: str) -> str:
    return ("is checked out in another worktree, at %s, so it was not made a window — once its work there is "
            "committed, remove that worktree (git -C target/%s worktree remove %s) and run core/lease.sh adopt %s%s"
            % (path, key, path, b, flag))


def _loose(p: Path, key: str, keys: List[str]) -> List[str]:
    """Untracked, not-ignored paths of target/<key>'s working tree (files and symlinks; a repository of its own
    shows as "<dir>/"), leaving out the nested target repos under it, which are repos of their own. Sorted."""
    code, out, _ = _git(p, "ls-files", "--others", "--exclude-standard", "-z")
    nested = [k[len(key) + 1:] for k in keys if k.startswith(key + "/")]
    return sorted(u for u in (out.split("\0") if code == 0 else [])
                  if u and not any(u.rstrip("/") == n or u.startswith(n + "/") for n in nested))


def _ignored(p: Path, key: str, keys: List[str]) -> List[str]:
    """Ignored, non-empty entries of target/<key>'s working tree — .gitignore, .git/info/exclude or the global
    excludes file: notes, .env, a repository cloned inside (a wholly ignored directory is one "<dir>/" entry) —
    leaving out the nested target repos. A window is made from the commits and the untracked files; these stay
    in the trunk mirror, so its line names them (release-candidate review 2, finding 9). Sorted."""
    code, out, _ = _git(p, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory",
                        "--no-empty-directory", "-z")
    nested = [k[len(key) + 1:] for k in keys if k.startswith(key + "/")]
    found = []
    for u in (out.split("\0") if code == 0 else []):
        if not u or any(u.rstrip("/") == n or u.startswith(n + "/") for n in nested):
            continue
        try:
            if not u.endswith("/") and not os.path.islink(str(p / u)) and os.path.getsize(str(p / u)) == 0:
                continue
        except OSError:
            continue
        found.append(u)
    return sorted(found)


def _ignored_words(key: str, nn: str, ign: List[str]) -> str:
    import leaselib as ll
    return (" Ignored files stay in target/%s and are not in the window (%s) — if any of them is work, move it into "
            "worktrees/%s/%s." % (key, ll.name_paths(ign), nn, key)) if ign else ""


class _OutOfTime(Exception):
    pass


def _out_of_time(deadline: Optional[float]) -> bool:
    return deadline is not None and time.time() >= deadline


def _copy_bytes(src: Path, dst: Path, deadline: Optional[float]) -> None:
    """<src>'s bytes and mode into <dst>, CARRY_CHUNK at a time, the deadline looked at before each: a large file is
    never what keeps a session start past its hook's timeout (release-candidate review, finding 2)."""
    with open(str(src), "rb") as f, open(str(dst), "wb") as g:
        while True:
            if _out_of_time(deadline):
                raise _OutOfTime()
            chunk = f.read(CARRY_CHUNK)
            if not chunk:
                break
            g.write(chunk)
    shutil.copystat(str(src), str(dst))


def _same(src: Path, dst: Path) -> bool:
    """Does <dst> hold what <src> holds: the same symlink target, or the same bytes?"""
    try:
        if os.path.islink(str(src)) or os.path.islink(str(dst)):
            return (os.path.islink(str(src)) and os.path.islink(str(dst))
                    and os.readlink(str(src)) == os.readlink(str(dst)))
        return dst.is_file() and filecmp.cmp(str(src), str(dst), shallow=False)
    except OSError:
        return False


def _carry(root: Path, p: Path, key: str, nn: str, loose: List[str],
           deadline: Optional[float] = None) -> Tuple[List[str], List[str]]:
    """Untracked files of target/<key> into window <nn>'s worktree of it (critic finding 2): each is copied under a
    temporary name in worktrees/<nn>/.upgrade-carry, the copy checked against the original (bytes, or a symlink's
    target), put in place with one rename, checked again, and only then is the original removed — and only while
    it is still an untracked file of target/<key> under that name — so a run cut off at any point leaves the
    original where it was and no part of a file under its real name in the window (release-candidate review,
    finding 2). A copy already in place (a run cut off before the original was removed) is checked and kept.
    Out of time between files or chunks it stops, saying it runs again; the next run finishes (_pending_carry).
    (carried, left): left are those that could not go: a repository of its own, a different file already at
    that path, a worktree not made yet, an error."""
    dest = root / "worktrees" / nn / key
    if not loose:
        return [], []
    if not dest.is_dir():
        return [], list(loose)
    out_of_time = Stop(STOPPED_TIME % (version(root) or "this release", "moving in-flight work in target/ into windows"))
    # Temporary copies live in a directory of their own beside the window's repos, never under a name an untracked
    # file could have (release-candidate review 2, finding 10); one a cut-off run left is removed first.
    tmpdir = root / "worktrees" / nn / ".upgrade-carry"
    shutil.rmtree(str(tmpdir), ignore_errors=True)
    # Still untracked, under the very name: a trunk reset on a filesystem that ignores case can have put a tracked
    # file where Thing.txt was, which must never be moved out of the trunk mirror (review 2, finding 3).
    code, out, _ = _git(p, "ls-files", "--others", "--exclude-standard", "-z")
    still = set(out.split("\0")) if code == 0 else set()
    try:
        return _carry_each(p, dest, tmpdir, loose, still, deadline, out_of_time)
    finally:
        shutil.rmtree(str(tmpdir), ignore_errors=True)


def _carry_each(p: Path, dest: Path, tmpdir: Path, loose: List[str], still: Set[str], deadline: Optional[float],
                out_of_time: Stop) -> Tuple[List[str], List[str]]:
    carried, left = [], []
    for i, u in enumerate(loose):
        if _out_of_time(deadline):
            raise out_of_time
        src, dst = p / u, dest / u
        if u.endswith("/") or u not in still or not os.path.lexists(str(src)):
            left.append(u)
            continue
        if os.path.lexists(str(dst)):
            same = _same(src, dst)          # an earlier run's copy, put in place before it was cut off
        else:
            tmp = tmpdir / str(i)
            try:
                dst.parent.mkdir(parents=True, exist_ok=True)
                tmpdir.mkdir(parents=True, exist_ok=True)
                if src.is_symlink():
                    os.symlink(os.readlink(str(src)), str(tmp))
                else:
                    _copy_bytes(src, tmp, deadline)
                same = _same(src, tmp)
                if same:
                    os.replace(str(tmp), str(dst))
            except _OutOfTime:
                try:
                    os.unlink(str(tmp))
                except OSError:
                    pass
                raise out_of_time
            except OSError:
                same = False
            if not same:
                try:
                    if os.path.lexists(str(tmp)):
                        os.unlink(str(tmp))
                except OSError:
                    pass
        if not same or not _same(src, dst):
            left.append(u)
            continue
        try:
            os.unlink(str(src))
        except OSError:
            left.append(u)          # the copy stays too; doctor names the original until it is removed
            continue
        carried.append(u)
        d = src.parent
        while d != p and p in d.parents:
            try:
                d.rmdir()           # only an emptied directory goes
            except OSError:
                break
            d = d.parent
    return carried, left


def _pending_carry(root: Path) -> Dict[str, str]:
    """{repo key: the tip its window was adopted at} for each checkout whose window was made by a run that did not
    finish moving its untracked files (cut off, or out of time) — written before the window is made, cleared once
    the carry has run (release-candidate review, finding 2)."""
    try:
        d = json.loads((root / CARRY).read_text())
    except (OSError, ValueError):
        return {}
    return {k: t for k, t in d.items() if isinstance(k, str) and isinstance(t, str)} if isinstance(d, dict) else {}


def _set_carry(root: Path, key: str, tip: Optional[str]) -> None:
    d = _pending_carry(root)
    if tip:
        d[key] = tip
    else:
        d.pop(key, None)
    if d:
        (root / CARRY).parent.mkdir(parents=True, exist_ok=True)
        _write(root / CARRY, json.dumps(d, indent=2) + "\n")
    else:
        try:
            (root / CARRY).unlink()
        except OSError:
            pass


def _window_at(root: Path, key: str, tip: str) -> Optional[str]:
    """The window adopted from target/<key> at commit <tip>, or None."""
    import leaselib as ll
    for nn, d in sorted(ll.read_all(root).items()):
        if nn != "prime" and d.get("adopted_repo") == key and d.get("adopted_tip") == tip:
            return nn
    return None


def _loose_words(head: str, key: str, nn: str, carried: List[str], left: List[str]) -> str:
    import leaselib as ll
    s = " Its untracked files went with it into worktrees/%s/%s: %s." % (nn, key, ll.name_paths(carried)) \
        if carried else ""
    if left:
        s += (" Untracked files that could not go with it stay in target/%s (%s); core/doctor.sh names them until "
              "they are moved into worktrees/%s/%s or removed." % (key, ll.name_paths(left), nn, key))
    return s


def _dry_loose(loose: List[str]) -> str:
    import leaselib as ll
    return " with its untracked files (%s)" % ll.name_paths(loose) if loose else ""


def _now_window(head: str, what: str, r: dict, key: str, trunk: str, stale: str, extra: str = "") -> str:
    tail = " Note: %s." % "; ".join(r["notes"]) if r["notes"] else ""
    return ("%s: %s; that work is now window %s (branch lease/%s), and target/%s is back on %s. Promote it from the "
            "board (\"promote window %s\") or release it.%s%s%s"
            % (head, what, r["nn"], r["nn"], key, trunk, r["nn"], extra, tail, stale))


def step_adopt(root: Path, head: str, dry: bool, deadline: Optional[float]) -> List[str]:
    """Spec §14 step 6. Every checkout is checked for a git operation stopped part-way, then for uncommitted
    changes, before anything in target/ moves; either stops the step (Decision 6; critic finding 3). Then one bounded fetch of all of them at once (Decision 3)
    and, per repo (outer first, then nested): the checked-out ref — a branch or a detached HEAD with work that
    origin/<trunk> lacks is adopted as a numbered window, one whose work is already there goes back to the trunk
    and is left as it was (Decisions 4, 5) — and then the trunk itself: a trunk still ahead of origin is adopted
    as its own window, unless the window just adopted from this checkout already carries its commits, in which
    case the trunk is only reset to origin/<trunk> (review of 2026-09-29, finding 1) — and so it is when a window
    an earlier run made, cut off before the reset, carries them (Task 3 review, findings 1-2). An untracked file
    where a checkout or reset would write stops the step, after the fetch and before anything moves (finding 3).
    Afterwards no target/<repo> is off its trunk or ahead of origin — §14's predicate."""
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
        _half_done(p, key, ver)
    for key, p in repos:
        t = trunks[key]
        if _git(p, "rev-parse", "--verify", "-q", "refs/heads/origin/" + t)[0] == 0:
            raise Stop(SHADOW % (ver, key, t, t, key, t))
    for key, p in repos:
        code, dirt, _ = _git(p, "status", "--porcelain", "--untracked-files=no")
        if code != 0 or dirt.strip():
            raise Stop(DIRTY % (ver, key))
        hidden = ll.hidden_edits(p)
        if hidden:
            raise Stop(HIDDEN % ((ver, key) + ll.hidden_words(key, hidden)))
    fetched = set() if dry else _fetch_all(repos, deadline)
    for key, p in repos:
        _, cur, _ = _git(p, "branch", "--show-current")
        _in_the_way(p, key, trunks[key], cur.strip(), ver)
    lines = []
    spoken: Set[str] = set()      # repos whose untracked files a line already names
    for key, p in repos:
        stash = _stash_entries(p)
        if stash:       # never moved, never invisible (critic finding 4)
            lines.append(STASHED % ((head, key) + _stash_words(stash)))
        trunk = trunks[key]
        if dry:
            stale = " (judged against origin/%s as last fetched; the real run fetches first)" % trunk
        elif key not in fetched:
            stale = " (judged against origin/%s as last fetched — the fetch did not finish)" % trunk
        else:
            stale = ""
        rel = key if key == ll.target_name(root) else key.split("/", 1)[1]
        if not dry:
            # a window an earlier, cut-off start adopted from here and never made a worktree for: made now, so its
            # untracked files can go into it and its work is not adopted a second time (review 2, findings 12-13)
            try:
                finished = ll.finish_adopted(root, key, deadline)
            except ll.Refused as e:
                raise Stop("could not finish a window adopted from target/%s at an earlier start (%s)" % (key, e))
            for nn, ok in finished:
                if not ok:
                    raise Stop(STOPPED_TIME % (ver, "moving in-flight work in target/ into windows"))
                lines.append("%s: window %s, adopted from target/%s at an earlier start, now has its worktree "
                             "(worktrees/%s/%s)." % (head, nn, key, nn, key))
        _, cur, _ = _git(p, "branch", "--show-current")
        cur = cur.strip()
        loose = _loose(p, key, list(trunks))      # carried into the window made from this checkout, if one is
        ign = _ignored(p, key, list(trunks))      # named in that window's line: they stay (review 2, finding 9)
        carrier, carrier_nn = None, None      # the ref a window was (or would be) made from here, and its number
        tip = None if dry else _pending_carry(root).get(key)
        if tip:
            # a window made from this checkout by a run cut off before its untracked files had all moved: finish
            # moving them into that window, never into the trunk mirror's "no window has" line (review, finding 2)
            nn = _window_at(root, key, tip)
            if nn and loose and (root / "worktrees" / nn / key).is_dir():
                carried, left = _carry(root, p, key, nn, loose, deadline)
                words = _loose_words(head, key, nn, carried, left)
                lines.append("%s: target/%s's work became window %s at an earlier start%s"
                             % (head, key, nn, "; i" + words[2:] if carried else "." + words))
                spoken.add(key)
                loose = []
            _set_carry(root, key, None)
        if cur != trunk:
            headsha = ""
            orphan = bool(LEASE_BRANCH.fullmatch(cur)) and ll.read_lease(root, cur[len("lease/"):]) is None
            if cur == "" or (LEASE_BRANCH.fullmatch(cur) and not orphan):
                if cur:
                    work = []   # a window's branch checked out here: it is already a window
                else:
                    _, headsha, _ = _git(p, "rev-parse", "HEAD")
                    headsha = headsha.strip()
                    work = _work(p, trunk, headsha)
                what = ("target/%s was not on a branch" % key if not cur
                        else "target/%s was on %s, a window's branch" % (key, cur))
                adopt_ref = None
            else:
                work = _work(p, trunk, cur)
                what = "target/%s was on %s" % (key, cur)
                adopt_ref = cur
            if work:
                what += " (%s not on origin/%s: %s)" % (_plural(len(work), "commit"), trunk, _quoted(work))
            if not work and dry:
                lines.append("%s: would put target/%s back on %s (%s holds nothing that origin/%s lacks)%s."
                             % (head, key, trunk, cur or "its detached HEAD", trunk, stale))
            elif not work:
                label = None
                if not cur and not ll._held_elsewhere(p, headsha):
                    # a detached HEAD whose change is on origin as a squash: its commits are named, never left
                    # reachable from nothing (release-candidate review 2, finding 4)
                    label = "daedalus/upgrade-%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), headsha[:7])
                    code, _, err = _git(p, "branch", label, headsha)
                    if code != 0:
                        raise Stop("could not name target/%s's detached commits (%s)" % (key, _last(err)))
                _back_on_trunk(p, key, trunk)
                if label:
                    lines.append("%s: %s; its change is already on origin/%s, and it is back on %s — its commits are "
                                 "kept on branch %s, left as it was.%s" % (head, what, trunk, trunk, label, stale))
                elif cur and not LEASE_BRANCH.fullmatch(cur):
                    lines.append("%s: target/%s was on %s, whose work is already on origin/%s; it is back on %s and "
                                 "%s is left as it was.%s" % (head, key, cur, trunk, trunk, cur, stale))
                elif cur:
                    lines.append("%s: %s; it is back on %s (the window keeps its branch).%s" % (head, what, trunk, stale))
                else:
                    lines.append("%s: %s; its work is already on origin/%s, and it is back on %s.%s"
                                 % (head, what, trunk, trunk, stale))
            elif dry:
                lines.append("%s: would move target/%s's %s (%s not on origin/%s)%s into a numbered window and put "
                             "target/%s back on %s%s." % (head, key, cur or "detached HEAD", _plural(len(work), "commit"),
                                                          trunk, _dry_loose(loose), key, trunk, stale))
                if loose:
                    spoken.add(key)
                carrier = cur or headsha
            else:
                if adopt_ref is None:        # detached with work: name it first, so no commit is lost
                    adopt_ref = "daedalus/upgrade-%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), headsha[:7])
                    code, _, err = _git(p, "branch", adopt_ref, "HEAD")
                    if code != 0:
                        raise Stop("could not name target/%s's detached work (%s)" % (key, _last(err)))
                if loose:                    # so a run cut off before the carry is done finishes it (review, 2)
                    _set_carry(root, key, _git(p, "rev-parse", "HEAD")[1].strip())
                r = _into_window(root, key, rel, adopt_ref, ver, deadline)
                carrier, carrier_nn = "lease/" + r["nn"], r["nn"]
                carried, left = _carry(root, p, key, r["nn"], loose, deadline)
                _set_carry(root, key, None)
                if loose:
                    spoken.add(key)
                loose = []
                lines.append(_now_window(head, what, r, key, trunk, stale, _loose_words(head, key, r["nn"], carried, left)
                                         + _ignored_words(key, r["nn"], ign)))
        # every other local branch with work origin/<trunk> lacks: a window each, named in one line each; the
        # checkout is not touched (critic finding 1). One a window already carries is left as it was.
        # (ref, what a line calls the window it became): in a dry run the ref it would be made from
        carriers = [(carrier, (cur or "the detached HEAD") if dry else carrier_nn)] if carrier else []
        parked, elsewhere, gone = _branches(p, trunk, cur)
        for b, path, work in elsewhere:      # adopting it would fail on every run (release-candidate review, 1)
            if not _carried(p, b, [c for c, _ in carriers]):
                lines.append("%s: target/%s's branch %s (%s not on origin/%s: %s) %s.%s"
                             % (head, key, b, _plural(len(work), "commit"), trunk, _quoted(work),
                                _elsewhere_words(key, b, path, _repo_flag(root, key)), stale))
        gone = [b for b, _w in gone]
        if gone:
            lines.append((GONE_ONE % (head, key, gone[0], trunk, gone[0], _repo_flag(root, key), stale)) if len(gone) == 1
                         else GONE_MANY % (head, key, ll.name_paths(gone), trunk, _repo_flag(root, key), stale))
        for b, work in parked:
            if _carried(p, b, [c for c, _ in carriers]):
                continue
            n = _plural(len(work), "commit")
            if dry:
                lines.append("%s: would move target/%s's branch %s (%s not on origin/%s) into a numbered window%s."
                             % (head, key, b, n, trunk, stale))
                carriers.append((b, b))
                continue
            r = _into_window(root, key, rel, b, ver, deadline)
            tail = " Note: %s." % "; ".join(r["notes"]) if r["notes"] else ""
            if r["already"]:
                lines.append("%s: target/%s's branch %s (%s not on origin/%s: %s) has the name of the branch window %s "
                             "was adopted from, so it was not adopted; run core/lease.sh adopt after renaming it.%s%s"
                             % (head, key, b, n, trunk, _quoted(work), r["nn"], tail, stale))
                continue
            carriers.append(("lease/" + r["nn"], r["nn"]))
            lines.append("%s: target/%s's branch %s (%s not on origin/%s: %s) is now window %s (branch lease/%s); "
                         "target/%s stays on %s. Promote it from the board (\"promote window %s\") or release it.%s%s"
                         % (head, key, b, n, trunk, _quoted(work), r["nn"], r["nn"], key, trunk, r["nn"], tail, stale))
        ahead = _ahead(p, trunk)
        if not ahead:
            if not dry and cur == trunk:
                _git(p, "merge", "--ff-only", "--quiet", _origin(trunk))
            continue
        n = _plural(len(ahead), "commit")
        hit = next((lbl for c, lbl in carriers if _git(p, "merge-base", "--is-ancestor", trunk, c)[0] == 0), None)
        if hit:
            if dry:
                lines.append("%s: would reset target/%s's %s (also %s ahead of origin/%s) to origin/%s — the window "
                             "made from %s carries those commits%s." % (head, key, trunk, n, trunk, trunk, hit, stale))
                continue
            code, _, err = _git(p, "reset", "--hard", "--quiet", _origin(trunk))
            if code != 0:
                raise Stop("could not reset target/%s's %s to origin/%s (%s)" % (key, trunk, trunk, _last(err)))
            lines.append("%s: target/%s's %s was also %s ahead of origin/%s; window %s carries those commits, so %s is "
                         "reset to origin/%s.%s" % (head, key, trunk, n, trunk, hit, trunk, trunk, stale))
            continue
        prior = _carried_by(root, p, key, trunk)
        if prior:
            # an earlier run made that window and was cut off before the reset: finish it, never a second window
            if dry:
                lines.append("%s: would reset target/%s's %s (%s ahead of origin/%s) to origin/%s — window %s already "
                             "carries those commits%s." % (head, key, trunk, n, trunk, trunk, prior, stale))
                continue
            code, _, err = _git(p, "reset", "--hard", "--quiet", _origin(trunk))
            if code != 0:
                raise Stop("could not reset target/%s's %s to origin/%s (%s); window %s holds its commits"
                           % (key, trunk, trunk, _last(err), prior))
            lines.append("%s: target/%s's %s was %s ahead of origin/%s; window %s already carries those commits, so %s "
                         "is reset to origin/%s.%s" % (head, key, trunk, n, trunk, prior, trunk, trunk, stale))
            continue
        if dry:
            lines.append("%s: would move target/%s's %s (%s ahead of origin/%s)%s into a numbered window and reset it "
                         "to origin/%s%s." % (head, key, trunk, n, trunk, _dry_loose(loose if cur == trunk else []),
                                               trunk, stale))
            if loose and cur == trunk:
                spoken.add(key)
            continue
        if loose and cur == trunk:
            _set_carry(root, key, _git(p, "rev-parse", "HEAD")[1].strip())
        r = _into_window(root, key, rel, trunk, ver, deadline)
        if r["already"]:
            # adopt finished a reset an earlier, cut-off run left (review finding 2): say so, and go on
            if _ahead(p, trunk):
                raise Stop("target/%s's %s is still ahead of origin/%s after adopting it named window %s, which was "
                           "adopted before" % (key, trunk, trunk, r["nn"]))
            lines.append("%s: target/%s's %s was %s ahead of origin/%s; window %s already carries those commits, and "
                         "%s is now reset to origin/%s.%s" % (head, key, trunk, n, trunk, r["nn"], trunk, trunk, stale))
            continue
        extra = ""
        if cur == trunk:            # the window is made from what was checked out: its untracked files go too
            carried, left = _carry(root, p, key, r["nn"], loose, deadline)
            _set_carry(root, key, None)
            extra = _loose_words(head, key, r["nn"], carried, left) + _ignored_words(key, r["nn"], ign)
            if loose:
                spoken.add(key)
            loose = []
        lines.append(_now_window(head, "target/%s's %s was %s ahead of origin/%s (%s)"
                                 % (key, trunk, n, trunk, _quoted(ahead)), r, key, trunk, stale, extra))
    # untracked files in a checkout no window was made from stay where they are, named (critic finding 2)
    for key, p in repos:
        if key in spoken:
            continue
        left = _loose(p, key, list(trunks))
        if left:
            lines.append("%s: target/%s holds untracked files no window has (%s) — they stay there, and core/doctor.sh "
                         "names them until they are moved into a window's worktree or removed."
                         % (head, key, ll.name_paths(left)))
    return lines


STEPS = ((1, "creating the window directories", step_dirs),
         (2, "installing the pre-push hook", step_hooks),
         (3, "removing the old shared reminder files", step_dedup),
         (4, "renaming hot.md's session line", step_hot),
         (5, "moving capture's settings into config.yaml", step_memory),
         (6, "moving in-flight work in target/ into windows", step_adopt))


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
        upto: int = 6) -> Tuple[List[str], Optional[str]]:
    """Steps 1..upto in order, then (upto 6, not dry) the stamp. Returns (the lines of the steps that acted, the
    stop sentence or None). A stop is recorded in state/upgrade-stopped.json (not in a dry run) and the stamp is
    not written, so the next run starts again from the top."""
    ver = version(root)
    if ver is None and upto == 6:
        return [], None
    head = "Upgrade to %s" % ver if upto == 6 else "Setup"
    fd = None
    if not dry:
        fd = _lock(root, deadline)
        if fd is None:
            return [], None
    try:
        if fd is not None and upto == 6 and stamped(root) == ver:
            return [], None          # the run that held the lock finished it while this one waited
        lines: List[str] = []
        for n, what, fn in STEPS:
            if n > upto:
                break
            if not dry and deadline is not None and time.time() >= deadline:
                return lines, _stopped(root, ver, n, STOPPED_TIME % (ver, what))
            try:
                lines += fn(root, head, dry, deadline)
            except Stop as e:
                sentence = str(e) if str(e).startswith("upgrade to ") else STOPPED_WHILE % (ver, what, e)
                return lines, (sentence if dry else _stopped(root, ver, n, sentence))
            except Exception as e:      # a step that crashed is a stop with its reason, never a silent pass
                sentence = STOPPED_WHILE % (ver, what, "%s: %s" % (type(e).__name__, e))
                return lines, (sentence if dry else _stopped(root, ver, n, sentence))
        if upto == 6:
            if dry:
                lines.append("%s: would write state/upgraded-to last." % head)
            else:
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


def _stopped(root: Path, ver: Optional[str], step: int, sentence: str) -> str:
    try:
        _write(root / STOPPED, json.dumps({"version": ver, "step": step, "sentence": sentence,
                                           "at": time.strftime("%Y-%m-%dT%H:%M:%S")}, indent=2) + "\n")
    except OSError:
        pass
    return sentence


def pending_line(root: Path) -> Optional[str]:
    """The board's line on every prompt until the stamp is this VERSION's (spec §14 "What the operator sees if
    a step could not run"): the recorded stop, else "has not run yet"."""
    ver = version(root)
    if ver is None or stamped(root) == ver:
        return None
    try:
        rec = json.loads((root / STOPPED).read_text())
    except (OSError, ValueError):
        rec = None
    if isinstance(rec, dict) and rec.get("version") == ver and isinstance(rec.get("sentence"), str):
        return rec["sentence"]
    return "upgrade to %s has not run yet — it runs at the next session start in this home" % ver


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
            parked, elsewhere, gone = _branches(p, trunk, cur)
        except Stop:
            parked, elsewhere, gone = [], [], []
        loose = _loose(p, key, [k for k, _ in repos])
        if loose:                       # untracked files in a target checkout: work no window holds (critic finding 2)
            if cur == trunk:
                takes = bool(_ahead(p, trunk))
            elif LEASE_BRANCH.fullmatch(cur):
                takes = False
            else:
                try:
                    takes = bool(_work(p, trunk, cur or "HEAD"))
                except ll.Refused:
                    takes = False
            if pend and takes:
                print("NOTE     target/%s has untracked files no window holds (%s) — the upgrade takes them into the "
                      "window it makes from %s at the next session start"
                      % (key, ll.name_paths(loose), cur or "the detached HEAD"))
            else:
                print("NOTE     target/%s has untracked files no window holds (%s) — target/%s is the trunk mirror, "
                      "which no session works in; move them into a window's worktree (worktrees/<NN>/%s) or remove "
                      "them" % (key, ll.name_paths(loose), key, key))
        mine = [] if LEASE_BRANCH.fullmatch(cur) or cur == trunk else [cur or "HEAD"]
        for b, path, work in elsewhere:  # checked out in another worktree: adopt cannot take it there (review 1)
            if not _carried(p, b, mine):
                print("NOTE     target/%s has branch %s, %s past origin/%s, in no window — it %s"
                      % (key, b, _plural(len(work), "commit"), trunk, _elsewhere_words(key, b, path, flag)))
        for b, work in gone:            # named by the upgrade once, here every time (review 2, finding 8)
            if not _carried(p, b, mine):
                print("NOTE     target/%s has branch %s, %s past origin/%s, whose branch on origin was deleted — "
                      "if it was not merged, run core/lease.sh adopt %s%s" % (key, b, _plural(len(work), "commit"),
                                                                             trunk, b, flag))
        for b, work in parked:          # a branch beside the checkout, in no window (critic finding 1)
            if _carried(p, b, mine):
                continue
            print("NOTE     target/%s has branch %s, %s past origin/%s, in no window — %s"
                  % (key, b, _plural(len(work), "commit"), trunk,
                     "the upgrade adopts it as a numbered window at the next session start (or run core/lease.sh "
                     "adopt %s%s)" % (b, flag) if pend else "run core/lease.sh adopt %s%s to turn it into a window"
                     % (b, flag)))
        if cur == trunk:
            _, out, _ = _git(p, "rev-list", "--count", "%s..refs/heads/%s" % (_origin(trunk), trunk))
            n = int(out.strip() or 0)
            if n:
                what = "the commit" if n == 1 else "the commits"
                print("MISSING  target/%s %s is %s ahead of origin/%s — trunk is reached only through promote; %s"
                      % (key, trunk, _plural(n, "commit"), trunk,
                         "the upgrade moves %s to a window at the next session start" % what if pend
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
            fix = ("the upgrade adopts it as a numbered window at the next session start (or run core/lease.sh "
                   "adopt %s%s)" % (cur, flag)) if pend else "run core/lease.sh adopt %s%s to turn it into a window" % (cur, flag)
        elif work:
            fix = ("the upgrade moves it to a numbered window at the next session start" if pend else
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


def main(argv: List[str]) -> int:
    root = v.ROOT
    args = argv[1:]
    if args == ["--doctor"]:
        return doctor(root)
    if [a for a in args if a not in ("--dry-run", "--setup")]:
        sys.stderr.write("usage: python3 core/upgrade.py [--dry-run] [--setup] | --doctor\n")
        return 2
    dry, upto = "--dry-run" in args, (3 if "--setup" in args else 6)
    ver = version(root)
    if upto == 6 and ver is None:
        sys.stderr.write("daedalus: this checkout has no VERSION file, so there is nothing to upgrade to\n")
        return 1
    if upto == 6 and not dry and stamped(root) == ver:
        print("Already upgraded to %s; nothing to do." % ver)
        return 0
    lines, stop = run(root, dry=dry, upto=upto)
    for ln in lines:
        print(ln)
    if stop:
        print(("would stop: " if dry else "") + stop)
        return 0 if dry else 1
    if not lines:
        print("Nothing to do.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
