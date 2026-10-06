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
  6. in-flight work in target/ moved into numbered windows (leaselib.adopt) — the checked-out branch, then a
     trunk still ahead of origin — each checkout put back on its trunk at origin, after one bounded fetch of
     all of them at once (plan 5 Decision 3). It will not move a checkout with uncommitted changes, nor one
     with an untracked file where the move back to the trunk would write, nor one where a rebase, merge,
     cherry-pick, revert or bisect stopped part-way (critic finding 3): it stops there, saying what to do,
     and the board repeats the sentence until a later start finishes. A window an earlier, cut-off run made
     is found again, never made twice.
  7. the stamp, state/upgraded-to, written last: a stopped upgrade runs again from the top next time

    python3 core/upgrade.py              every step now, as a session start would
    python3 core/upgrade.py --dry-run    what each step would do; changes nothing, fetches nothing
    python3 core/upgrade.py --setup      steps 1-3 (setup.sh's leases phase, spec §15); never stamps
    python3 core/upgrade.py --doctor     doctor's upgrade lines (§15)

Python 3.9, standard library.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

STAMP = Path("state") / "upgraded-to"
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
    _write(cfgp, text + ("" if text.endswith("\n") or not text else "\n") + "\n" + "\n".join(block) + "\n")
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


def _ahead(p: Path, trunk: str) -> List[str]:
    """Subjects, oldest first, of the commits on the local trunk that origin/<trunk> lacks."""
    _, out, _ = _git(p, "log", "--reverse", "--format=%s", "origin/%s..%s" % (trunk, trunk))
    return [s for s in out.splitlines() if s.strip()]


def _back_on_trunk(p: Path, key: str, trunk: str) -> None:
    code, _, err = _git(p, "checkout", "--quiet", trunk)
    if code != 0:
        raise Stop("could not put target/%s back on %s (%s)" % (key, trunk, _last(err)))
    _git(p, "merge", "--ff-only", "--quiet", "origin/" + trunk)


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
    deletes it silently. Checked after the fetch, against origin/<trunk> as the run will see it."""
    import leaselib as ll
    if cur != trunk:
        refs, doing = [trunk, "origin/" + trunk], "putting it back on %s" % trunk
    elif _ahead(p, trunk):
        refs, doing = ["origin/" + trunk], "resetting %s to origin/%s" % (trunk, trunk)
    else:
        return
    hit = ll.untracked_in_way(p, refs)
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


def _now_window(head: str, what: str, r: dict, key: str, trunk: str, stale: str) -> str:
    tail = " Note: %s." % "; ".join(r["notes"]) if r["notes"] else ""
    return ("%s: %s; that work is now window %s (branch lease/%s), and target/%s is back on %s. Promote it from the "
            "board (\"promote window %s\") or release it.%s%s"
            % (head, what, r["nn"], r["nn"], key, trunk, r["nn"], tail, stale))


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
        code, dirt, _ = _git(p, "status", "--porcelain", "--untracked-files=no")
        if code != 0 or dirt.strip():
            raise Stop(DIRTY % (ver, key))
    fetched = set() if dry else _fetch_all(repos, deadline)
    for key, p in repos:
        _, cur, _ = _git(p, "branch", "--show-current")
        _in_the_way(p, key, trunks[key], cur.strip(), ver)
    lines = []
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
        _, cur, _ = _git(p, "branch", "--show-current")
        cur = cur.strip()
        carrier, carrier_nn = None, None      # the ref a window was (or would be) made from here, and its number
        if cur != trunk:
            headsha = ""
            if cur == "" or LEASE_BRANCH.fullmatch(cur):
                if cur:
                    work = []   # a window's branch checked out here: it is already a window
                else:
                    _, headsha, _ = _git(p, "rev-parse", "HEAD")
                    headsha = headsha.strip()
                    work = ll.unpromoted_commits(p, trunk, headsha)
                what = ("target/%s was not on a branch" % key if not cur
                        else "target/%s was on %s, a window's branch" % (key, cur))
                adopt_ref = None
            else:
                work = ll.unpromoted_commits(p, trunk, cur)
                what = "target/%s was on %s" % (key, cur)
                adopt_ref = cur
            if work:
                what += " (%s not on origin/%s: %s)" % (_plural(len(work), "commit"), trunk, _quoted(work))
            if not work and dry:
                lines.append("%s: would put target/%s back on %s (%s holds nothing that origin/%s lacks)%s."
                             % (head, key, trunk, cur or "its detached HEAD", trunk, stale))
            elif not work:
                _back_on_trunk(p, key, trunk)
                if cur and not LEASE_BRANCH.fullmatch(cur):
                    lines.append("%s: target/%s was on %s, whose work is already on origin/%s; it is back on %s and "
                                 "%s is left as it was.%s" % (head, key, cur, trunk, trunk, cur, stale))
                elif cur:
                    lines.append("%s: %s; it is back on %s (the window keeps its branch).%s" % (head, what, trunk, stale))
                else:
                    lines.append("%s: %s; its work is already on origin/%s, and it is back on %s.%s"
                                 % (head, what, trunk, trunk, stale))
            elif dry:
                lines.append("%s: would move target/%s's %s (%s not on origin/%s) into a numbered window and put "
                             "target/%s back on %s%s." % (head, key, cur or "detached HEAD", _plural(len(work), "commit"),
                                                          trunk, key, trunk, stale))
                carrier = cur or headsha
            else:
                if adopt_ref is None:        # detached with work: name it first, so no commit is lost
                    adopt_ref = "daedalus/upgrade-%s-%s" % (time.strftime("%Y%m%d-%H%M%S"), headsha[:7])
                    code, _, err = _git(p, "branch", adopt_ref, "HEAD")
                    if code != 0:
                        raise Stop("could not name target/%s's detached work (%s)" % (key, _last(err)))
                r = _into_window(root, key, rel, adopt_ref, ver, deadline)
                carrier, carrier_nn = "lease/" + r["nn"], r["nn"]
                lines.append(_now_window(head, what, r, key, trunk, stale))
        ahead = _ahead(p, trunk)
        if not ahead:
            if not dry and cur == trunk:
                _git(p, "merge", "--ff-only", "--quiet", "origin/" + trunk)
            continue
        n = _plural(len(ahead), "commit")
        if carrier and _git(p, "merge-base", "--is-ancestor", trunk, carrier)[0] == 0:
            if dry:
                lines.append("%s: would reset target/%s's %s (also %s ahead of origin/%s) to origin/%s — the window "
                             "made from %s carries those commits%s." % (head, key, trunk, n, trunk, trunk,
                                                                       cur or "the detached HEAD", stale))
                continue
            code, _, err = _git(p, "reset", "--hard", "--quiet", "origin/" + trunk)
            if code != 0:
                raise Stop("could not reset target/%s's %s to origin/%s (%s)" % (key, trunk, trunk, _last(err)))
            lines.append("%s: target/%s's %s was also %s ahead of origin/%s; window %s carries those commits, so %s is "
                         "reset to origin/%s.%s" % (head, key, trunk, n, trunk, carrier_nn, trunk, trunk, stale))
            continue
        prior = _carried_by(root, p, key, trunk)
        if prior:
            # an earlier run made that window and was cut off before the reset: finish it, never a second window
            if dry:
                lines.append("%s: would reset target/%s's %s (%s ahead of origin/%s) to origin/%s — window %s already "
                             "carries those commits%s." % (head, key, trunk, n, trunk, trunk, prior, stale))
                continue
            code, _, err = _git(p, "reset", "--hard", "--quiet", "origin/" + trunk)
            if code != 0:
                raise Stop("could not reset target/%s's %s to origin/%s (%s); window %s holds its commits"
                           % (key, trunk, trunk, _last(err), prior))
            lines.append("%s: target/%s's %s was %s ahead of origin/%s; window %s already carries those commits, so %s "
                         "is reset to origin/%s.%s" % (head, key, trunk, n, trunk, prior, trunk, trunk, stale))
            continue
        if dry:
            lines.append("%s: would move target/%s's %s (%s ahead of origin/%s) into a numbered window and reset it "
                         "to origin/%s%s." % (head, key, trunk, n, trunk, trunk, stale))
            continue
        r = _into_window(root, key, rel, trunk, ver, deadline)
        if r["already"]:
            # adopt finished a reset an earlier, cut-off run left (review finding 2): say so, and go on
            if _ahead(p, trunk):
                raise Stop("target/%s's %s is still ahead of origin/%s after adopting it named window %s, which was "
                           "adopted before" % (key, trunk, trunk, r["nn"]))
            lines.append("%s: target/%s's %s was %s ahead of origin/%s; window %s already carries those commits, and "
                         "%s is now reset to origin/%s.%s" % (head, key, trunk, n, trunk, r["nn"], trunk, trunk, stale))
            continue
        lines.append(_now_window(head, "target/%s's %s was %s ahead of origin/%s (%s)"
                                 % (key, trunk, n, trunk, _quoted(ahead)), r, key, trunk, stale))
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


def doctor(root: Path) -> int:
    """Doctor's upgrade lines (spec §15): the stamp; a target/ checkout off its trunk or ahead of origin; hot.md
    still carrying session:. Local refs only — it never fetches, so it says what the refs this home last fetched
    show. While the upgrade is pending the remedy is the next session start; after it, core/lease.sh adopt."""
    ver = version(root)
    if ver is None:
        return 0                                    # doctor.sh's VERSION line says why
    pend = stamped(root) != ver
    print("NOTE     %s" % pending_line(root) if pend else "OK       upgrade: state/upgraded-to %s" % ver)
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
        stash = _stash_entries(p)
        if stash:
            print("NOTE     target/%s holds %s (%s) — saved work no window shows; apply it in a window's worktree "
                  "(git -C worktrees/<NN>/%s stash apply) or drop it once it is not needed"
                  % ((key,) + _stash_words(stash) + (key,)))
        _, cur, _ = _git(p, "branch", "--show-current")
        cur = cur.strip()
        if cur == trunk:
            _, out, _ = _git(p, "rev-list", "--count", "origin/%s..%s" % (trunk, trunk))
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
            work = ll.unpromoted_commits(p, trunk, cur or "HEAD")
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
