#!/usr/bin/env python3
"""promote (spec §7): the one way a window's work reaches trunk.

    core/promote.sh <NN>                     prepare (§7.1)
    core/promote.sh <NN> --skip-review --reason "..."   prepare without the review, the operator's written reason
                                             recorded (§7.1 step 8; in tty mode the reason is typed at the terminal)
    core/promote.sh <NN> --clean             remove window NN's promote scratch trees (records kept): the
                                             prime, any promotion; a session holding no window, or a shell,
                                             pushed promotions only; never one a confirm holds
    core/promote.sh <NN> --confirm [--operator-said "..."] [--id <promote-id>]   confirm and push (§7.2)
    python3 core/promote.py --doctor         doctor's promote lines (§15), one per state

core/promote.sh has already run the distribution-integrity check
(core/distcheck.py) before this file was read. Run by the prime — the session
prime.json names — or an operator shell; a window NUMBER, never an alias.
Prepare fetches trunk, trial-merges lease/<NN> onto it in a scratch worktree
under state/promote/<promote-id>/, fingerprints the merged tree, runs the gates
(gates.sh --no-refute --promote) and the fresh-context reviewer (refute.sh
--mode promote, through the direct-call launcher) on exactly that merge,
checks that nothing moved while they ran, writes prepared.json and prints the
decision block: two paragraphs, the decision in plain words and the record.
Prepare pushes nothing.
Confirm re-derives everything from the primary artifacts, records the
operator's yes, and pushes the merge commit the evidence names — nothing else.

Exit: 0 ready (or done); 1 the work is not ready (gates FAIL or INVALID,
REFUTED, the review could not be completed); 2 refused. Every refusal ends
"Nothing was pushed." or "Nothing changed on origin." (§11.3).
Python 3.9, standard library; distcheck, leaselib, transcriptlib and verifylib
from core/.
"""
from __future__ import annotations

import calendar
import contextlib
import fcntl
import json
import os
import pwd
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

# Nothing this runs reads a bytecode cache — the integrity check skips
# __pycache__/ — the launcher's rule (spec §6.1).
NO_PYCACHE = "/dev/null/daedalus-no-pycache"
sys.dont_write_bytecode = True
sys.pycache_prefix = NO_PYCACHE
os.environ.update(PYTHONDONTWRITEBYTECODE="1", PYTHONPYCACHEPREFIX=NO_PYCACHE)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import distcheck as dc  # noqa: E402
import leaselib as ll  # noqa: E402
import transcriptlib as tl  # noqa: E402
import verifylib as v  # noqa: E402

PUSHED, ON_ORIGIN = "Nothing was pushed.", "Nothing changed on origin."
LOCK_ERR = re.compile(r"cannot lock ref|Unable to create '[^']*\.lock'")
RECORDS = ("prepared.json", "context.json", "pushed", "announced", ".confirm.lock")
FINDING = re.compile(r"^#{1,4}\s*F\d+\b.*[—-]\s*(HIGH|MEDIUM|LOW)\s*$", re.M)


class Stop(Exception):
    """A refusal or a not-ready outcome: one sentence, ending with the §11.3
    suffix (added when the sentence does not already end with one), and the
    exit code (2 refused, 1 not ready)."""

    def __init__(self, sentence: str, code: int = 2, suffix: str = PUSHED) -> None:
        sentence = sentence.rstrip()
        if not sentence.endswith((PUSHED, ON_ORIGIN)):
            sentence = sentence + " " + suffix
        super().__init__(sentence)
        self.code = code


# --- small helpers -----------------------------------------------------------------------------------

def run(cmd: List[str], env: Optional[dict] = None, timeout: Optional[float] = 300) -> Tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", str(e)


def last_line(text: str) -> str:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1] if lines else "no output"


def git(repo: Path, *args: str, env: Optional[dict] = None, timeout: Optional[float] = 300,
        stop: bool = True) -> Tuple[int, str, str]:
    """git in one repo, with the shared-.git lock retry (§7.1 step 3): a "cannot
    lock ref" / "Unable to create '….lock'" is retried three times, one second
    apart, and then stops the promotion — never a null fingerprint or an
    INVALID run. With stop=False (the push and every step after it, which must
    never say "Nothing was pushed."), the fourth failure is returned instead."""
    err = ""
    for attempt in range(4):
        code, out, err = run(["git", "-C", str(repo)] + list(args), env=env, timeout=timeout)
        if code == 0 or not LOCK_ERR.search(err or ""):
            return code, out, err
        if attempt < 3:
            time.sleep(1)
    if not stop:
        return code, out, err
    raise Stop("promote did nothing — git could not take a lock in the target (%s); another session is "
               "mid-operation, run promote again." % last_line(err))


def rev(repo: Path, spec: str) -> str:
    code, out, _ = git(repo, "rev-parse", "--verify", "-q", spec + "^{commit}")
    return out.strip() if code == 0 else ""


def read_json(p: Path) -> Optional[dict]:
    try:
        d = json.loads(Path(p).read_text())
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def write_json(p: Path, data: dict) -> None:
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(str(tmp), str(p))


def rel(root: Path, p: object) -> str:
    try:
        return Path(str(p)).resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(p)


def user_name() -> str:
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return str(os.getuid())


def config(root: Path, key: str) -> str:
    return v._lib(root, "cfg %s 2>/dev/null || true" % key).strip()


def home_check(root: Path) -> None:
    """The home and the config are this promote's own (the launcher's rule,
    plan 3 Decision 15): an inherited DAEDALUS_HOME or DAEDALUS_CONFIG must not
    point promote at another deployment's gates or trunk."""
    mine = Path(__file__).resolve().parent.parent
    if root.resolve() != mine:
        raise Stop("DAEDALUS_HOME is %s, but this promote belongs to %s — refusing." % (root, mine))
    conf = Path(os.environ.get("DAEDALUS_CONFIG") or (mine / "config.yaml")).resolve()
    if conf != mine / "config.yaml":
        raise Stop("config %s is not %s/config.yaml — refusing: the gates and the trunk come from this "
                   "deployment's config only." % (conf, mine))


def update_run(root: Path, run_id: str, change: Callable[[dict], None]) -> dict:
    p = root / "state" / "evidence" / run_id / "run.json"
    rec = read_json(p) or {}
    change(rec)
    write_json(p, rec)
    return rec


# --- who and what (§7.1 steps 1–2) -----------------------------------------------------------------

def read_leases(root: Path) -> Dict[str, dict]:
    if not (root / "state" / "leases").is_dir():
        return {}
    with ll.lock(root, shared=True):
        return ll.read_all(root)


PROMOTE_WAITS = ("This session holds the pen but no window, and the upgrade to %s has not finished: promote changes "
                 "target/, which the upgrade's safety copy protects, so it waits until the upgrade finishes. hot.md "
                 "and `core/vault-commit.sh` work now.")
PROMOTE_WAITS_TAKEN = ("This session took the pen at a vault commit while the upgrade to %s was pending: promote "
                       "changes target/, which the upgrade's safety copy protects, so it waits until the upgrade "
                       "finishes.")


def who(root: Path, leases: Dict[str, dict]) -> dict:
    """§7.1 step 1. On one POSIX user every one of these is a claim; the check
    stops the honest mistake (a clone that forgot it is not prime). The gate an
    agent cannot pass alone is the recorded yes (§7.4); git's pre-push hook
    refuses a trunk push no promotion confirmed (§7.3)."""
    sid = ll.session_id_from_env()
    claude = os.environ.get("CLAUDECODE") == "1" or bool(os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if sid is None and not claude:
        return {"kind": "operator-shell", "session_id": None, "pid": os.getpid(), "lease": None, "user": user_name()}
    if sid is None:
        raise Stop("This is a Claude Code session, but its session id is not in the environment, so I cannot tell "
                   "whether it holds the pen. Run promote from the prime window, or from your own shell.")
    mine, mlease = ll.lease_of_session(leases, sid)
    if (leases.get("prime") or {}).get("session_id") != sid:
        me = ll.window_label(mine, mlease) if mine else "a session that holds no window"
        raise Stop("Only the prime window runs promote. You are %s; ask the prime (marked prime on the board), "
                   "or take the pen first." % me)
    if mine is None and ll.pending_version(root):
        raise Stop(PROMOTE_WAITS % ll.pending_version(root))
    pending = ll.pending_version(root)
    if pending and (leases.get("prime") or {}).get("taken_while_pending") == pending:
        # a window from before the pull that picked up the pen at a vault commit (leaselib pen_for_commit)
        raise Stop(PROMOTE_WAITS_TAKEN % pending)
    hint = os.environ.get("DAEDALUS_LEASE", "").strip()
    if hint and hint != (mine or ""):
        raise Stop("`DAEDALUS_LEASE=%s`, but this session is %s (the lease files are the truth). Unset the "
                   "variable." % (hint, ll.window_label(mine, mlease) if mine else "the prime with no window"))
    return {"kind": "prime-session", "session_id": sid, "pid": os.getpid(), "lease": mine, "user": user_name()}


def window(leases: Dict[str, dict], token: str) -> Tuple[str, dict]:
    try:
        nn = ll.number_of(leases, token, "promote")
    except ll.Refused as e:
        raise Stop(str(e) + ".")
    lease = leases.get(nn)
    if lease is None or nn == "prime":
        raise Stop("No window %s. `core/lease.sh list` shows the live ones." % nn)
    return nn, lease


def trunks(root: Path, nn: str, lease: dict) -> Dict[str, str]:
    """repo -> trunk, outer first: the trunks the window's lease file recorded at
    create/adopt (§7 preamble) — the same ones `lease.sh rebase` brings the
    window up to date with. The current config target.branch and each nested
    repo's origin/HEAD must still name them: a trunk moved since the window was
    cut is refused, naming both, rather than promoted onto a branch the window
    was never built or rebased against. A lease with no trunks recorded (cut
    before they were) takes the current ones, as rebase does."""
    now = current_trunks(root)
    rec = lease.get("trunks") or {}
    if not rec:
        return now
    if set(rec) != set(now):
        raise Stop("Window %s was cut for the repos %s, but config now names %s. Promote merges only onto the trunks "
                   "a window was cut from. Put config target.nested back, or move window %s's work to a new window; "
                   "then run promote again." % (nn, ", ".join(sorted(rec)), ", ".join(sorted(now)), nn))
    outer = next(iter(now))
    for repo, trunk in now.items():
        if rec[repo] == trunk:
            continue
        if repo == outer:
            fix = "Set config target.branch back to %s" % rec[repo]
            moved = "config target.branch now says %s" % trunk
        else:
            fix = "Point it back (`git -C target/%s remote set-head origin %s`)" % (repo, rec[repo])
            moved = "that repo's origin/HEAD now points at %s" % trunk
        raise Stop("Window %s was cut from %s in %s, but %s. Promote merges only onto the trunk a window was cut "
                   "from, the one `core/lease.sh rebase` brings it up to date with (%s). %s, or move window %s's "
                   "work to a window cut from %s; then run promote again."
                   % (nn, rec[repo], repo, moved, rec[repo], fix, nn, trunk))
    return {repo: rec[repo] for repo in now}


def current_trunks(root: Path) -> Dict[str, str]:
    """repo -> trunk, outer first: config target.branch for the outer repo, each
    nested repo's origin/HEAD (§7 preamble), read now — fail closed."""
    try:
        name = ll.target_name(root)
    except ll.Refused as e:
        raise Stop(str(e) + ".")
    out = {name: v.target_branch(root)}
    for n in v.nested_relpaths(root):
        repo = "%s/%s" % (name, n)
        code, head, _ = run(["git", "-C", str(root / "target" / repo), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
        head = head.strip()
        if code != 0 or not head.startswith("origin/"):
            raise Stop("nested repo %s has no origin/HEAD; run `git -C target/%s remote set-head origin -a` and "
                       "try again." % (n, repo))
        out[repo] = head[len("origin/"):]
    return out


def outer_of(tr: Dict[str, str]) -> str:
    return next(iter(tr))


def fetch_trunks(root: Path, tr: Dict[str, str]) -> Dict[str, str]:
    """§7.1 step 3: fetch origin in every repo and resolve origin/<trunk> to a sha."""
    shas: Dict[str, str] = {}
    for repo, trunk in tr.items():
        code, _, err = git(root / "target" / repo, "fetch", "--quiet", "origin")
        sha = rev(root / "target" / repo, "origin/" + trunk) if code == 0 else ""
        if not sha:
            raise Stop("Cannot resolve origin/%s: %s. Fix config target.branch or the remote; promote did nothing."
                       % (trunk, last_line(err) if code != 0 else "origin has no branch by that name"))
        shas[repo] = sha
    return shas


def dirty(root: Path, nn: str, tr: Dict[str, str]) -> None:
    for repo in tr:
        try:
            files = ll.dirty_files(root / "worktrees" / nn / repo)
        except ll.Refused as e:
            raise Stop(str(e) + ".")
        if files:
            raise Stop("Window %s has uncommitted changes in worktrees/%s/%s. Commit them on `lease/%s` first; "
                       "promote only merges commits." % (nn, nn, repo, nn))


def commits_by_repo(root: Path, nn: str, tr: Dict[str, str], shas: Dict[str, str]) -> Dict[str, List[str]]:
    """repo -> subjects (oldest first) of lease/<NN>'s commits not on the fetched trunk."""
    out: Dict[str, List[str]] = {}
    for repo in tr:
        src = root / "target" / repo
        if not rev(src, "lease/%s" % nn):
            continue
        _, log, _ = git(src, "log", "--reverse", "--format=%s", "%s..lease/%s" % (shas[repo], nn))
        subjects = [s for s in log.splitlines() if s.strip()]
        if subjects:
            out[repo] = subjects
    return out


# --- the scratch and the trial merge (§7.1 steps 4–5) --------------------------------------------

def promote_root(root: Path) -> Path:
    d = root / "state" / "promote"
    d.mkdir(mode=0o700, parents=True, exist_ok=True)
    return d


def remove_scratch(root: Path, pdir: Path, tr: Dict[str, str], strict: bool = False) -> None:
    """One promotion's scratch worktrees — nested first, they sit inside the
    outer — never its records (prepared.json, context.json, the stamps).
    strict (the confirm's last step, update-command Decision 7): a scratch
    still there afterwards raises, naming git's reason, so the caller can
    say so; every other caller removes what it can and goes on."""
    failed: List[str] = []
    for repo in sorted(tr, key=len, reverse=True):
        dest = pdir / repo
        if dest.exists():
            code, _, err = run(["git", "-C", str(root / "target" / repo), "worktree", "remove", "--force", str(dest)])
            if code != 0:
                failed.append("%s: %s" % (repo, last_line(err)))
        # only promote's own scratch records: never a worktree the operator made elsewhere (review 3, finding 2)
        ll.prune_under(root / "target" / repo, promote_root(root))
    if pdir.is_dir():
        for child in pdir.iterdir():
            if child.name in RECORDS:
                continue
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(str(child), ignore_errors=True)
            else:
                child.unlink()
    left = [repo for repo in tr if (pdir / repo).exists()]
    if strict and left:
        raise RuntimeError("; ".join(failed) or "%s is still there" % ", ".join(rel(root, pdir / r) for r in left))


def was_pushed(pdir: Path) -> bool:
    return (pdir / "pushed").exists() or (pdir / "announced").exists()


def clean_window(root: Path, nn: str, tr: Dict[str, str], pushed_only: bool = False) -> Tuple[List[str], List[str]]:
    """Every scratch of window NN's promotions (plan 4 Decision 22): (removed
    ids, kept sentences). pushed_only (any caller but the prime, update-command
    Decision 10b): a promotion with no pushed or announced record is kept and
    named — its content is not on trunk. Every caller takes each promotion's
    .confirm.lock (the lock confirm_lock takes) without waiting, and keeps a
    promotion whose lock is held: a clean never removes a scratch mid-confirm."""
    removed: List[str] = []
    kept: List[str] = []
    base = root / "state" / "promote"
    for pdir in sorted(base.glob("%s-*" % nn)) if base.is_dir() else []:
        if not pdir.is_dir() or not any((pdir / repo).exists() for repo in tr):
            continue
        if pushed_only and not was_pushed(pdir):
            kept.append("Kept %s: prepared but not pushed; only the prime removes it." % pdir.name)
            continue
        with open(str(pdir / ".confirm.lock"), "a") as fh:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                kept.append("Kept %s: being confirmed now." % pdir.name)
                continue
            remove_scratch(root, pdir, tr)
        removed.append(pdir.name)
    return removed, kept


def cut_scratch(root: Path, pdir: Path, tr: Dict[str, str], shas: Dict[str, str]) -> None:
    for repo in tr:        # outer first: the nested worktrees go inside it
        code, _, err = git(root / "target" / repo, "worktree", "add", "--detach", str(pdir / repo), shas[repo])
        if code != 0:
            remove_scratch(root, pdir, tr)
            raise Stop("Could not create the promote scratch for %s (%s)." % (repo, last_line(err)))
    outer = pdir / outer_of(tr)
    for ln in v._lib(root, "cfg target.scaffold >/dev/null 2>&1 && cfg_pairs target.scaffold | cut -f1").splitlines():
        if ln.strip():
            (outer / ln.strip()).mkdir(parents=True, exist_ok=True)


def trial_merge(root: Path, nn: str, lease: dict, pdir: Path, repo: str, trunk: str, tr: Dict[str, str],
                pid: str) -> Tuple[str, str, str]:
    """git merge --no-ff lease/<NN> in the scratch of <repo>; (merge, trunk_sha,
    lease_tip) read from the merge commit itself (§7.1 step 4)."""
    alias = lease.get("alias")
    msg = "promote: merge lease/%s (window %s%s) into %s (%s)" % (nn, nn, (", " + alias) if alias else "", trunk, pid)
    wt = pdir / repo
    code, _, err = git(wt, "merge", "--no-ff", "--no-edit", "-m", msg, "lease/%s" % nn)
    if code != 0:
        _, unmerged, _ = git(wt, "diff", "--name-only", "--diff-filter=U")
        conflicts = [f for f in unmerged.splitlines() if f.strip()]
        remove_scratch(root, pdir, tr)
        if conflicts:
            raise Stop("Window %s's work does not merge cleanly onto current %s (conflicts in: %s). Tell window %s to "
                       "bring its work up to date with %s; then run promote again."
                       % (nn, trunk, ", ".join(conflicts), nn, trunk))
        raise Stop("The trial merge of window %s's work failed (%s)." % (nn, last_line(err)))
    return rev(wt, "HEAD"), rev(wt, "HEAD^1"), rev(wt, "HEAD^2")


# --- fingerprint, gates, review (§7.1 steps 6–9) ---------------------------------------------------

def fingerprint(root: Path, tree: Path) -> Tuple[str, str]:
    """fingerprint.sh of the merged tree (every repo in it); ("null", reason) on failure."""
    env = dict(os.environ, DAEDALUS_TARGET_OVERRIDE=str(tree))
    code, out, err = run(["bash", str(root / "core" / "fingerprint.sh")], env=env, timeout=600)
    fp = (out.strip().splitlines() or ["null"])[-1]
    why = "; ".join(ln for ln in err.splitlines() if ln.strip() and not ln.startswith("fingerprint_secs="))
    return (fp if re.fullmatch(r"[0-9a-f]{64}", fp) else "null"), why


def run_gates(root: Path, pid: str, tree: Path, trunk: str) -> dict:
    env = dict(os.environ, DAEDALUS_TARGET_OVERRIDE=str(tree))
    _code, out, err = run(["bash", str(root / "core" / "gates.sh"), "--no-refute", "--promote", pid], env=env, timeout=None)
    ev = root / "state" / "evidence"
    runs = [p for p in (ev.glob("*/run.json") if ev.is_dir() else []) if (read_json(p) or {}).get("promote_id") == pid]
    if not runs:
        raise Stop("Gates were INVALID on the merged tree (gates.sh did not start a run: %s). An invalid run is "
                   "not a pass." % last_line(err or out), code=1)
    rec = read_json(max(runs, key=lambda p: p.stat().st_mtime)) or {}
    result = rec.get("result")
    if result == "PASS":
        return rec
    if result == "FAIL":
        g = next((g for g in rec.get("gates") or [] if g.get("exit") != 0), None)
        if g and g.get("exit") in (126, 127):
            # The gate never ran (2026-10-14): a merge is not what failed, and saying so sent an
            # operator looking for a merge problem that did not exist.
            raise Stop("Gates could not run on the merged tree (gate %s: `%s` exit %s — %s; log at %s). The scratch "
                       "holds only tracked files; build output such as a virtual environment is not there. Add a "
                       "`gates_setup:` step to config.yaml that builds it, or change the gate."
                       % (g["n"], g["command"], g["exit"],
                          "command not found" if g["exit"] == 127 else "not executable", rel(root, g["log"])), code=1)
        where = ("gate %s: `%s` exit %s; log at %s" % (g["n"], g["command"], g["exit"], rel(root, g["log"]))
                 if g else "see state/evidence/%s" % rec.get("run_id"))
        raise Stop("Gates FAIL on the merged tree (%s). The lease was green on its own branch; the merge with current "
                   "%s is what fails." % (where, trunk), code=1)
    reason = rec.get("invalid_reason") or (      # a setup step failed or changed the tree: gates.sh names it
        "the fingerprint was null" if rec.get("fingerprint") in (None, "null") else
        "the tree changed while the gates ran" if result == "INVALID" else "the run never finished (%s)" % result)
    raise Stop("Gates were INVALID on the merged tree (%s). An invalid run is not a pass." % reason, code=1)


def review(root: Path, run_id: str, tree: Path) -> dict:
    """§7.1 step 8: refute.sh --mode promote on the merged diff (the launcher runs
    the reviewer; the verdict file is written once)."""
    env = dict(os.environ, DAEDALUS_TARGET_OVERRIDE=str(tree))
    code, _out, err = run(["bash", str(root / "core" / "refute.sh"), run_id, "--mode", "promote"], env=env, timeout=None)
    vf = root / "vault" / "evidence" / ("%s-review.md" % run_id)
    if code not in (0, 1) or not vf.is_file():
        raise Stop("The review could not be completed (%s). A missing review is not a pass." % last_line(err), code=1)
    text = vf.read_text()
    fm = v.parse_frontmatter(text)
    sev = FINDING.findall(text)
    return {"call_id": fm.get("call-id"), "verdict": "STANDS" if code == 0 else "REFUTED", "file": rel(root, vf),
            "fingerprint": fm.get("fingerprint"), "request_sha": fm.get("request-sha"),
            "findings": {s.lower(): sev.count(s) for s in ("HIGH", "MEDIUM", "LOW")}}


# --- the decision block (§7.1 step 10) --------------------------------------------------------------

def n_words(n: int, noun: str) -> str:
    return "no %ss" % noun if n == 0 else "one %s" % noun if n == 1 else "%d %ss" % (n, noun)


def reviewer_line(rv: Optional[dict], skipped: Optional[str]) -> str:
    if rv is None:
        return "Reviewer: skipped by the operator because: %s" % skipped
    f = rv.get("findings") or {}
    rest = [("one" if f.get(s) == 1 else str(f.get(s))) + " " + s for s in ("medium", "low") if f.get(s)]
    counted = n_words(f.get("high", 0), "high finding") + (", " + " and ".join(rest) if rest else "")
    return "Reviewer on the merged change: %s — %s." % (rv["verdict"], counted)


def release_words(root: Path) -> Optional[str]:
    """None unless config promote.release_note is true (a deployment where a
    promote is a release, spec §7.1 step 10); then the deployment's own update
    command in backticks (promote.update_command), or "" for the generic words.
    Core never names a product (Decision 1; the §8.4 generalization rule)."""
    if config(root, "promote.release_note") != "true":
        return None
    cmd = config(root, "promote.update_command")
    return "`%s`" % cmd if cmd else ""


def first_line(p: dict, ready: bool, root: Path) -> str:
    alias = " (%s)" % p["alias"] if p.get("alias") else ""
    if not ready:
        return "Window %s's work%s is not ready to promote onto %s." % (p["lease"], alias, p["trunk"])
    line = "Ready to promote window %s's work%s onto %s" % (p["lease"], alias, p["trunk"])
    rel_ = release_words(root)
    if rel_ is None:
        return line + "."
    return line + " — this is a release: the next %s ships it." % (rel_ or "update")


def block_opening(p: dict) -> str:
    """The block's ready first line without its ending, so the release clause (Task 8) may follow."""
    alias = " (%s)" % p["alias"] if p.get("alias") else ""
    return "Ready to promote window %s's work%s onto %s" % (p["lease"], alias, p["trunk"])


def invitation(p: dict) -> str:
    """The block's closing question. v0.12.2: a plain question — nothing checks its wording or where the
    operator's answer stands; any words of his after the prepare that agree are the yes (transcribed_yes)."""
    return "Push window %s's work to %s?" % (p["lease"], p["trunk"])


def earlier_line(p: dict) -> List[str]:
    """Decision 39: a STANDS review of a change an earlier review REFUTED says so."""
    er, rv = p.get("earlier_refuted") or [], p.get("review")
    if not er or not rv or rv["verdict"] != "STANDS":
        return []
    if len(er) == 1:
        h = int(er[0].get("high") or 0)
        return ["An earlier review of this same change REFUTED it (%d high finding%s); this review STANDS."
                % (h, "" if h == 1 else "s")]
    return ["%d earlier reviews of this same change REFUTED it; this review STANDS." % len(er)]


def decision_block(root: Path, p: dict) -> Tuple[str, str]:
    rv = p.get("review")
    ready = (rv is None and bool(p.get("review_skipped_reason"))) or (rv is not None and rv["verdict"] == "STANDS")
    n = len(p["commits"])
    g = p["gates"]
    decision = "\n".join([
        first_line(p, ready, root),
        "Window %s: %s — %s." % (p["lease"], "1 commit" if n == 1 else "%d commits" % n,
                                  ", ".join('"%s"' % s for s in p["commits"])),
        "Tests on the merged result: PASS (%s, %s)." % ("1 gate" if g["count"] == 1 else "%d gates" % g["count"],
                                                       "1 second" if g["seconds"] == 1 else "%d seconds" % g["seconds"]),
        reviewer_line(rv, p.get("review_skipped_reason")),
    ] + earlier_line(p) + [
        "Nothing has been pushed. %s" % invitation(p) if ready else
        "Nothing has been pushed. Ask me to ask the reviewer why, or give a written reason to promote without the review.",
    ])
    if rv is not None:
        review_part = "review %s;" % rv["file"]
    else:
        o = p.get("overrode_review")
        review_part = "review skipped by the operator%s;" % (
            " (it sets aside review %s of run %s)" % (o["call_id"], o["run_id"]) if o else "")
    fp = p["fp_merged"]
    record = "\n".join([
        "For the record: merge commit %s onto trunk %s (origin/%s, fetched %s);"
        % (p["merge_sha"][:7], p["trunk_sha_at_prepare"][:7], p["trunk"], p["fetched_at"]),
        "evidence run %s; %s" % (p["run_id"], review_part),
        "fingerprint of what will be pushed %s…%s; promotion id %s." % (fp[:4], fp[-4:], p["promote_id"]),
    ] + ([p["context_line"]] if p.get("context_line") else []))     # rendered as stored, never recomputed (§9)
    return decision, record


def code_context(root: Path, p: dict, pdir: Path) -> Tuple[str, dict]:
    """Code-context design §9: the files the window changed and the tests that failed in its gate runs, set
    against what its queries named. core/context.py, imported by path like leaselib; never a Stop."""
    try:
        import context as cc
        return cc.misses(root, p, pdir)
    except Exception as e:
        return ("Code context: misses not computed (%s); promote is unaffected." % (one_line(e) or type(e).__name__),
                {"count": None, "kinds": {}})


def refuted_sentence(p: dict) -> str:
    rv = p["review"]
    high = (rv.get("findings") or {}).get("high", 0)
    return ("The reviewer REFUTED the merged change (%d HIGH finding%s; the review is at %s). If the operator wants to "
            "ask the reviewer about a finding, run `core/call-agent.sh --resume-review %s \"<the operator's question>\"` "
            "and repeat the answer. To promote anyway, the operator must give a written reason: `promote %s "
            "--skip-review --reason \"...\"`." % (high, "" if high == 1 else "s", rv["file"], p["lease"], p["lease"]))


# --- prepare (§7.1) ---------------------------------------------------------------------------------

def scratch_heads(tr: Dict[str, str], repo: str, merge: str, shas: Dict[str, str]) -> Dict[str, str]:
    """What each scratch repo's HEAD must be: the merge in the pushed repo, its trunk in the others."""
    return {r: (merge if r == repo else shas[r]) for r in tr}


def scratch_is(pdir: Path, heads: Dict[str, str]) -> bool:
    """Decision 37: every scratch repo's HEAD is its recorded commit and nothing in
    it differs from that commit — so the working tree fingerprint.sh describes is
    the tree of the commit that is pushed."""
    for r, sha in heads.items():
        if not sha or rev(pdir / r, "HEAD") != sha:
            return False
        try:
            if ll.dirty_files(pdir / r):
                return False
        except ll.Refused:
            return False
    return True


def earlier_refuted(root: Path, nn: str, pid: str, fp: str, tip: str, trunk_sha: str) -> List[dict]:
    """Decision 39: earlier prepares of this same change (same fp_merged, or same
    lease tip on the same trunk) whose review REFUTED it."""
    out = []
    base = root / "state" / "promote"
    for f in sorted(base.glob("%s-*/prepared.json" % nn)) if base.is_dir() else []:
        q = read_json(f) or {}
        rv = q.get("review") or {}
        if q.get("promote_id") == pid or q.get("lease") != nn or rv.get("verdict") != "REFUTED":
            continue
        if q.get("fp_merged") == fp or (q.get("lease_tip") == tip and q.get("trunk_sha_at_prepare") == trunk_sha):
            out.append({"call_id": rv.get("call_id"), "run_id": q.get("run_id"),
                        "high": int((rv.get("findings") or {}).get("high", 0))})
    return out


def occupant_prepares(root: Path, nn: str, lease: dict) -> List[dict]:
    """Decision 51: the prepared.json files of window NN's current occupant, oldest
    first — those carrying the lease file's own `created` stamp (compared as a
    string, never parsed), after the newest one a confirm pushed (its `pushed` or
    `announced` stamp): a promotion settles every review before it."""
    base = root / "state" / "promote"
    found = []
    for f in (base.glob("%s-*/prepared.json" % nn) if base.is_dir() else []):
        p = read_json(f)
        if p and p.get("lease") == nn and p.get("lease_created") == lease.get("created"):
            found.append((float(p.get("prepared_ts") or 0), f.parent, p))
    found.sort(key=lambda x: x[0])
    done = [i for i, (_, d, _) in enumerate(found) if (d / "pushed").exists() or (d / "announced").exists()]
    return [p for _, _, p in found[(done[-1] + 1 if done else 0):]]


SKIP_QUESTION = "Promote window %s's work without the review?"
TOO_SHORT = ("--skip-review needs the operator's reason in their own words — at least three words; a reason is the "
             "price of skipping the review.")


def marker_started(root: Path, sid: Optional[str], nn: str) -> float:
    """When this session started, as an absolute instant (Decisions 45, 51): the
    SessionStart marker's `started_epoch`; for a marker from an older build
    without it, the marker file's modification time (the marker is written once
    per session, so a later write only moves the cut-off later). No readable
    marker is a refusal, never a cut-off of 0 — the prime always has one."""
    m = v.read_marker(root, sid) if sid else None
    if m is not None:
        try:
            return float(m["started_epoch"])
        except (KeyError, TypeError, ValueError):
            try:
                return v.marker_path(root, sid).stat().st_mtime
            except OSError:
                pass
    raise Stop("This session has no start record (state/session-%s.json), so I cannot tell which of the operator's "
               "words came after it started. Restart the prime window, or set `promote.confirm: tty` and run "
               "`core/promote.sh %s --skip-review` in your own shell." % (sid, nn))


def skip_reason(root: Path, me: dict, nn: str, lease: dict, reason: Optional[str], mode: str) -> dict:
    """§7.1 step 8, before any git work: the operator's written reason for
    skipping the review — in transcribed mode a turn of the operator's, at least
    three words, typed after the latest prepare of this window (or since this
    session started when there is none), in his own words, recorded as he typed
    it (transcribed_yes, v0.12.2: no closing line, nothing about where the turn
    stands); in tty mode typed at a terminal — and the REFUTED review it
    sets aside (Decision 31): the latest REFUTED review of this window's current
    occupant that no promotion has settled, however many prepares came after it
    (Decision 51)."""
    mine = occupant_prepares(root, nn, lease)
    earlier = mine[-1] if mine else None
    refuted = next((q for q in reversed(mine) if (q.get("review") or {}).get("verdict") == "REFUTED"), None)
    overrode = {"call_id": refuted["review"]["call_id"], "run_id": refuted["run_id"]} if refuted else None
    paste = "Paste this line in your own shell: `cd %s && core/promote.sh %s --skip-review`" % (root, nn)
    if mode == "tty":
        if reason is not None:
            raise Stop("In tty mode the reason for skipping the review is typed in a terminal, not passed as --reason. "
                       + paste)
        try:
            text, name = tl.tty_answer("Why promote window %s's work without the review? (the operator's words): " % nn,
                                       root)
        except tl.NotAPerson as e:
            raise Stop("The reason to skip the review must be typed by a person in their own terminal: %s. %s"
                       % (e, paste))
        except tl.NoTerminal:
            raise Stop("The reason to skip the review must be typed by a person in a terminal. This session has none. "
                       + paste)
        if len(tl.normalize(text).split()) < 3:
            raise Stop(TOO_SHORT)
        return {"reason": text.strip(), "transcript_ref": None, "session_id": None,
                "typed": {"text": text.strip(), "tty": name, "pid": os.getpid()}, "overrode": overrode}
    if not (reason or "").strip():
        raise Stop("--skip-review needs --reason with the operator's words; a reason is the price of skipping the review.")
    if earlier:
        er = read_json(root / "state" / "evidence" / str(earlier.get("run_id")) / "run.json") or {}
        after = max(float(earlier.get("prepared_ts") or 0),
                    tl.parse_ts((er.get("promotion") or {}).get("prepared_at")) or 0.0)
    else:
        after = marker_started(root, me.get("session_id"), nn)
    yes = transcribed_yes(root, me, str(reason), after, "the review", reason=True)
    return {"reason": yes["text"].strip(), "transcript_ref": yes["transcript_ref"], "session_id": me["session_id"],
            "typed": None, "overrode": overrode}


def prepare(root: Path, a: dict) -> int:
    leases = read_leases(root)
    me = who(root, leases)
    nn, lease = window(leases, a["token"])
    if a.get("reason") is not None and not a.get("skip"):
        raise Stop("--reason goes with --skip-review.")
    skip = skip_reason(root, me, nn, lease, a.get("reason"), confirm_mode(root)) if a.get("skip") else None
    tr = trunks(root, nn, lease)
    dirty(root, nn, tr)
    shas = fetch_trunks(root, tr)
    fetched_at = time.strftime("%H:%M")
    by_repo = commits_by_repo(root, nn, tr, shas)
    outer = outer_of(tr)
    if not by_repo:
        raise Stop("Window %s has no commits that are not already on %s. Nothing to promote." % (nn, tr[outer]))
    if len(by_repo) > 1:
        names = sorted(by_repo, key=len)
        nested = [r for r in names if r != outer]
        raise Stop("Window %s has commits in both %s. v1 promotes one repo per run. Tell window %s to split its work "
                   "so the %s commits get their own window (`core/lease.sh split %s --repo %s`), then promote them "
                   "one at a time." % (nn, " and ".join(names), nn, nested[0], nn, nested[0].split("/", 1)[1]))
    repo = next(iter(by_repo))
    trunk = tr[repo]
    clean_window(root, nn, tr)                 # the prime: every earlier scratch of the window but one mid-confirm
    pid = "%s-%s-%s" % (nn, time.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(2)[:3])
    pdir = promote_root(root) / pid
    pdir.mkdir(mode=0o700)
    cut_scratch(root, pdir, tr, shas)
    merge, trunk_sha, tip = trial_merge(root, nn, lease, pdir, repo, trunk, tr, pid)
    # Decision 40: the commits the block names are the merge's own, read from the merge commit.
    _, log, _ = git(pdir / repo, "log", "--reverse", "--format=%s", "HEAD^1..HEAD^2")
    commits = [s for s in log.splitlines() if s.strip()]
    tree = pdir / outer
    fp, why = fingerprint(root, tree)
    if fp == "null":
        raise Stop("Could not fingerprint the merged tree (%s); promote did nothing." % (why or "fingerprint.sh printed null"))
    if not scratch_is(pdir, scratch_heads(tr, repo, merge, shas)):
        raise Stop("The promote scratch is not the merge commit it was cut for (its HEAD moved or a file in it changed "
                   "right after the trial merge). Run promote again.")
    er = earlier_refuted(root, nn, pid, fp, tip, trunk_sha)
    nested = {}
    for r in tr:
        if r != outer:
            m = merge if r == repo else shas[r]
            nested[r.split("/", 1)[1]] = {"trunk_sha_at_prepare": trunk_sha if r == repo else shas[r], "merge_sha": m}
    write_json(pdir / "context.json", {
        "promote_id": pid, "lease": nn, "repo": repo, "nested": nested,
        "trunk_sha_at_prepare": trunk_sha if repo == outer else shas[outer],
        "merge_sha": merge if repo == outer else shas[outer]})
    run_rec = run_gates(root, pid, tree, trunk)
    run_id = run_rec["run_id"]
    rv = review(root, run_id, tree) if skip is None else None
    fp_after, _ = fingerprint(root, tree)
    seen = [fp, fp_after, run_rec.get("fingerprint")] + ([rv["fingerprint"]] if rv else [])
    if len(set(seen)) != 1:
        raise Stop("The tree changed while promote was running (fingerprint before %s, after %s). Run promote again."
                   % (fp[:12], (fp_after if fp_after != fp else next(s for s in seen if s != fp) or "null")[:12]))
    ctx_line, ctx_misses = code_context(root, {"promote_id": pid, "lease": nn, "lease_created": lease.get("created"),
                                               "repo": repo, "trunk_sha_at_prepare": trunk_sha, "merge_sha": merge},
                                        pdir)
    at, ts = tl.iso_utc(time.time()), time.time()
    dist = dc.committed_dist(root)
    secs = sum(int(g.get("duration_s") or 0) for g in run_rec.get("gates") or [])
    p = {"promote_id": pid, "lease": nn, "lease_created": lease.get("created"), "alias": lease.get("alias"),
         "repo": repo, "trunk": trunk,
         "merge_sha": merge, "trunk_sha_at_prepare": trunk_sha, "lease_tip": tip, "fp_merged": fp, "run_id": run_id,
         "review": ({k: rv[k] for k in ("call_id", "verdict", "file", "fingerprint", "request_sha", "findings")}
                    if rv else None),
         "review_skipped_reason": skip["reason"] if skip else None,
         "skip_transcript_ref": skip["transcript_ref"] if skip else None,
         "skip_transcript_session_id": skip["session_id"] if skip else None,
         "skip_typed": skip["typed"] if skip else None,
         "overrode_review": skip["overrode"] if skip else None, "earlier_refuted": er,
         "core_tree": dist.get("core_tree"), "charter_sha": dist.get("charter_sha"), "commits": commits,
         "gates": {"count": len(run_rec.get("gates") or []), "seconds": secs}, "fetched_at": fetched_at,
         "prepared_at": at, "prepared_ts": ts,
         "prepared_by": {"session_id": me["session_id"], "lease": me["lease"], "pid": me["pid"], "user": me["user"]},
         "context_line": ctx_line, "context_misses": ctx_misses}
    write_json(pdir / "prepared.json", p)

    def record(rec: dict) -> None:
        rec["invoked_by"] = {"kind": me["kind"], "session_id": me["session_id"], "pid": me["pid"], "lease": me["lease"]}
        rec["promotion"] = {"promote_id": pid, "prepared_at": at, "review_skipped_reason": p["review_skipped_reason"],
                            "skip_transcript_ref": p["skip_transcript_ref"],
                            "skip_transcript_session_id": p["skip_transcript_session_id"],
                            "overrode_review": p["overrode_review"]}
        if p["skip_typed"]:
            rec["promotion"]["skip_typed"] = p["skip_typed"]
    update_run(root, run_id, record)
    if skip:
        with open(str(root / "vault" / "evidence" / ("%s.md" % run_id)), "a") as fh:
            fh.write("\nReview skipped by the operator because: %s\n" % one_line(skip["reason"]))
    decision, rec_text = decision_block(root, p)
    print(decision + "\n\n" + rec_text)
    sys.stdout.flush()
    if rv and rv["verdict"] == "REFUTED":
        raise Stop(refuted_sentence(p), code=1)
    return 0


VISITOR_SENTENCE = ("This is a direct-call session (a visitor): it never runs promote, --clean included. The prime, "
                    "a session holding no window, or your own shell can.")


def who_may_clean(root: Path, leases: Dict[str, dict]) -> str:
    """Who may run --clean (update-command Decision 10b): 'prime', 'operator' (a
    shell, as who() decides it) or 'no-window' (a Claude Code session holding
    no lease and not the pen). A visitor, and a session holding a window that
    is not the prime, are refused. Removing pushed scratch moves nothing, so it
    needs no pen — and an upgrade stop, which leaves no window and no pen, can
    name it."""
    if os.environ.get("DIRECT_CALL_ID"):
        raise Stop(VISITOR_SENTENCE)
    sid = ll.session_id_from_env()
    claude = os.environ.get("CLAUDECODE") == "1" or bool(os.environ.get("CLAUDE_CODE_SESSION_ID"))
    if sid is None and not claude:
        return "operator"
    if sid is None:
        who(root, leases)                      # its refusal: a session whose id is not in the environment
    mine, mlease = ll.lease_of_session(leases, sid)
    if (leases.get("prime") or {}).get("session_id") == sid:
        # a pen with no window while the upgrade is pending removes only what a session holding no window may
        return "no-window" if mine is None and ll.pending_version(root) else "prime"
    if mine:
        raise Stop("Only the prime window runs promote. You are %s; ask the prime (marked prime on the board), or "
                   "take the pen first." % ll.window_label(mine, mlease))
    return "no-window"


def clean_target(root: Path, leases: Dict[str, dict], token: str) -> Tuple[str, Dict[str, str]]:
    """Window NN and its repos for --clean: the trunks its lease file recorded
    (else the current config's) — never a trunk check: removing scratch moves
    nothing. A number whose lease file is gone is accepted while
    state/promote/NN-* exists, with the current config's repos."""
    try:
        nn = ll.number_of(leases, token, "promote")
    except ll.Refused as e:
        raise Stop(str(e) + ".")
    lease = leases.get(nn)
    if nn != "prime" and lease is not None:
        return nn, lease.get("trunks") or current_trunks(root)
    base = root / "state" / "promote"
    if nn == "prime" or not (base.is_dir() and any(base.glob("%s-*" % nn))):
        raise Stop("No window %s. `core/lease.sh list` shows the live ones." % nn)
    return nn, current_trunks(root)


def clean(root: Path, a: dict) -> int:
    """`promote <NN> --clean` (§7.1 step 7): the scratch worktrees of window NN's
    promotions go; prepared.json, context.json and the stamps stay (Decision 22).
    The prime removes any promotion's; a session holding no window, or a shell,
    only a pushed promotion's (update-command Decision 10b); a promotion a
    confirm holds is kept, for every caller."""
    leases = read_leases(root)
    kind = who_may_clean(root, leases)
    nn, tr = clean_target(root, leases, a["token"])
    removed, kept = clean_window(root, nn, tr, pushed_only=kind != "prime")
    lines = (["Removed the promote scratch of window %s (%s); the promotion records are kept." % (nn, ", ".join(removed))]
             if removed else [] if kept else ["Window %s has no promote scratch to remove." % nn])
    print("\n".join(lines + kept))
    return 0


# --- confirm (§7.2) ---------------------------------------------------------------------------------

def latest_prepared(root: Path, nn: str, pid: Optional[str] = None) -> Tuple[Path, dict]:
    base = root / "state" / "promote"
    if pid:
        p = read_json(base / pid / "prepared.json") if re.fullmatch(r"[0-9A-Za-z-]+", pid) else None
        if p is None:
            raise Stop("No prepared promotion %s; run `promote %s` first." % (pid, nn))
        if p.get("lease") != nn:
            raise Stop("Promotion %s was prepared for window %s, not window %s." % (pid, p.get("lease"), nn))
        return base / pid, p
    found = []
    for f in (base.glob("%s-*/prepared.json" % nn) if base.is_dir() else []):
        p = read_json(f)
        if p and p.get("lease") == nn:
            found.append((float(p.get("prepared_ts") or 0), f.parent, p))
    if not found:
        raise Stop("No prepared promotion for window %s; run `promote %s` first." % (nn, nn))
    _, pdir, p = max(found, key=lambda x: x[0])
    return pdir, p


def confirm_mode(root: Path) -> str:
    try:
        return tl.confirm_mode(root)
    except ValueError as e:
        raise Stop(str(e) + ".")


def transcribed_yes(root: Path, me: dict, said: str, after: float, what: str, reason: bool = False) -> dict:
    """The operator's words, found in the confirming session's own transcript (§7.2 step 2; v0.12.2): a turn the
    operator typed after `after` (the prepare that asked; a new prepare moves it), in any words — for the confirm,
    any that agree or ask for the push and are not taken back by a later no or wait; for a skipped review
    (reason=True), a reason of at least three words. Nothing about where the turn stands matters: replies,
    questions and notifications between the block and the words do not reset it, and no closing line is looked
    for. `said` is the agent's citation: it picks among his words when it matches loosely and is never itself the
    refusal (transcriptlib.find_consent). A turn the model wrote, or a line added to the file, never counts; an
    unreadable transcript, or one outside the denied directories (Decision 36), is never a pass (A12)."""
    if me["kind"] != "prime-session":
        raise Stop("In transcribed mode the prime window records the operator's yes; from a shell, set "
                   "`promote.confirm: tty` and run the confirm there.")
    try:
        path = tl.transcript_for(root, me["session_id"])
        found = tl.find_consent(path, after, quote=said or None, reason=reason)
    except tl.Unprotected as e:
        raise Stop("This session's transcript (%s) is outside every directory nothing may write, so it is not evidence "
                   "of the operator's words. Set memory.transcript_dir in config.yaml, or set `promote.confirm: tty` "
                   "and paste the confirm line in your own shell." % e)
    except tl.Missing as e:
        raise Stop("I cannot find this session's transcript (%s), so the operator's yes cannot be checked. If it lives "
                   "elsewhere, set memory.transcript_dir in config.yaml; or set `promote.confirm: tty` and paste the "
                   "confirm line in your own shell." % e)
    except tl.Unreadable as e:
        # critic finding 4 (A12): the doctor's sentence, so the refusal and the doctor line read alike
        d = tl.DRIFT[:1].upper() + tl.DRIFT[1:]
        cut = d.index(";")
        raise Stop("%s (%s)%s. Until then, set `promote.confirm: tty` and paste the confirm line in your own shell."
                   % (d[:cut], e, d[cut:]))
    except tl.Declined as e:
        raise Stop("The operator has not agreed: %s. Nothing was recorded; ask him again." % e)
    except tl.NotSubmitted as e:
        raise Stop("Those words are in this session's transcript, but %s. Nothing was recorded; show %s to the "
                   "operator and ask again." % (str(e).replace("the words are", "they are", 1), what))
    except tl.NotWritten:
        raise Stop("Those words are in this session's transcript, but not as a turn Claude Code wrote there: nothing "
                   "in the conversation follows from them, so they were added to the file afterwards. Nothing was "
                   "recorded; show %s to the operator and ask again." % what)
    except tl.NotFound as e:
        if reason:
            raise Stop("I could not find the operator's reason since %s was shown (%s): a reason in his own words, "
                       "at least three of them, is the price of skipping the review." % (what, e))
        raise Stop("The operator has not agreed to %s yet (%s since it was shown); any words that agree are enough."
                   % (what, e))
    return {"transcript_session_id": me["session_id"], "transcript_ref": found["transcript_ref"],
            "shown_ref": found["shown_ref"], "text": found["text"]}


def cutoff(root: Path, p: dict, pdir: Path) -> float:
    """Decision 35: the transcript cut-off is the latest of the promotion's
    primaries — prepared_ts, run.json's promotion.prepared_at, the merge commit's
    committer time, the end of the review's first attempt — never prepared.json's
    word alone; a prepared_ts earlier than the merge commit is a disagreement."""
    ts = float(p.get("prepared_ts") or 0)
    run_rec = read_json(root / "state" / "evidence" / str(p["run_id"]) / "run.json") or {}
    times = [ts, tl.parse_ts((run_rec.get("promotion") or {}).get("prepared_at")) or 0.0]
    code, ct, _ = git(pdir / p["repo"], "show", "-s", "--format=%ct", p["merge_sha"])
    if code == 0 and ct.strip().isdigit():
        if ts + 1 < float(ct.strip()):
            raise Stop("Evidence disagrees with the prepared promotion (the prepared time is earlier than the merge "
                       "commit).")
        times.append(float(ct.strip()))
    rv = p.get("review") or {}
    if rv.get("call_id"):
        launch = read_json(root / "state" / "direct-calls" / str(rv["call_id"]) / "launch.json") or {}
        first = (launch.get("attempts") or [{}])[0]
        try:
            started = calendar.timegm(time.strptime(str(first.get("started"))[:15], "%Y%m%dT%H%M%S"))
            times.append(started + float(first.get("duration_ms") or 0) / 1000.0)
        except ValueError:
            pass
    return max(times)


def tty_yes(root: Path, p: dict) -> dict:
    """§7.2 step 2, tty: the decision paragraph again, then one line read from
    /dev/tty that must be an acknowledgement (§7.4; is_assent) — from a process that descends from
    a terminal login and from no agent (Decision 32)."""
    decision, _ = decision_block(root, p)
    paste = "Paste this line in your own shell: `cd %s && core/promote.sh %s --confirm`" % (root, p["lease"])
    try:
        text, name = tl.tty_answer("%s\n\nType yes to push window %s's work to %s: " % (decision, p["lease"], p["trunk"]),
                                   root)
    except tl.NotAPerson as e:
        raise Stop("The confirm must be typed by a person in their own terminal: %s. %s" % (e, paste))
    except tl.NoTerminal:
        raise Stop("The confirm must be typed by a person in a terminal. This session has none. " + paste)
    if not tl.is_assent(text):
        raise Stop("The operator's words are not an acknowledgement (typed: \"%s\")." % text.strip())
    return {"typed": {"text": text.strip(), "tty": name, "pid": os.getpid()}}


def pair_of(run_rec: dict, p: dict) -> Tuple[str, str]:
    """(trunk_sha_at_prepare, merge_sha) that run.json records for the pushed repo."""
    if "/" not in p["repo"]:
        return str(run_rec.get("trunk_sha_at_prepare") or ""), str(run_rec.get("merge_sha") or "")
    n = (run_rec.get("nested") or {}).get(p["repo"].split("/", 1)[1]) or {}
    return str(n.get("trunk_sha_at_prepare") or ""), str(n.get("merge_sha") or "")


def sha256_bytes(b: bytes) -> str:
    import hashlib
    return hashlib.sha256(b).hexdigest()


def check_review(root: Path, p: dict, run_rec: dict, tree: Path) -> str:
    """§7.2 step 3: the review, the receipt and the re-rendered prompt, each
    against the others; nothing taken from prepared.json that a primary can
    contradict. Returns the review's call id, read from its own frontmatter
    (Decision 48)."""
    vf = root / "vault" / "evidence" / ("%s-review.md" % p["run_id"])
    _, verdict, _ = run(["bash", str(root / "core" / "refute.sh"), "--verdict-of", str(vf)])
    if verdict.strip() != "STANDS" or (p.get("review") or {}).get("verdict") != "STANDS":
        raise Stop("Evidence disagrees with the prepared promotion (review verdict).")
    text = vf.read_text()
    fm = v.parse_frontmatter(text)
    if not fm.get("call-id") or fm.get("call-id") != (p.get("review") or {}).get("call_id"):
        raise Stop("Evidence disagrees with the prepared promotion (the review's call id).")
    if fm.get("fingerprint") != run_rec.get("fingerprint"):
        raise Stop("Evidence disagrees with the prepared promotion (the review's fingerprint and the gate run's).")
    env = dict(os.environ, DAEDALUS_TARGET_OVERRIDE=str(tree))
    r = subprocess.run(["bash", str(root / "core" / "refute.sh"), p["run_id"], "--mode", "promote", "--render-only"],
                       env=env, capture_output=True, timeout=600)
    launch = read_json(root / "state" / "direct-calls" / str(fm.get("call-id")) / "launch.json") or {}
    rendered = sha256_bytes(r.stdout) if r.returncode == 0 else None
    if not (rendered and fm.get("request-sha") == launch.get("request_sha256") == rendered):
        raise Stop("The review did not see the change that will be pushed.")
    head = dc.committed_dist(root)
    if fm.get("core-tree") != head.get("core_tree") or fm.get("charter-sha") != head.get("charter_sha"):
        raise Stop("Distribution code changed since the review.")
    first = (launch.get("attempts") or [{}])[0]
    body = text.split("---\n", 2)[2] if text.startswith("---\n") and text.count("---\n") >= 2 else ""
    try:
        answer = Path(first.get("answer") or "").read_bytes()
    except OSError:
        answer = b""
    if (first.get("exit_code") != 0 or first.get("advisory") or launch.get("core_tree") != fm.get("core-tree")
            or sha256_bytes(answer) != sha256_bytes(body.encode())):
        raise Stop("Evidence disagrees with the prepared promotion (the review's receipt and the review).")
    return str(fm["call-id"])


def check_skip(root: Path, p: dict, promo: dict) -> None:
    """Decision 31: a skipped review's reason, re-read from its primary — the
    terminal record in tty mode, else the transcript entry by uuid, which must be
    operator-typed with the recorded text — never trusted from a ref's presence."""
    reason = promo.get("review_skipped_reason")
    if not reason or reason != p.get("review_skipped_reason"):
        raise Stop("Evidence disagrees with the prepared promotion (the reason for skipping the review).")
    typed, ref, sid = promo.get("skip_typed"), promo.get("skip_transcript_ref") or {}, promo.get("skip_transcript_session_id")
    if typed and typed.get("text") == reason:
        return
    text = None
    if ref.get("uuid") and sid:
        try:
            text = tl.operator_entry(tl.transcript_for(root, sid), ref["uuid"])
        except (tl.Missing, tl.Unreadable, tl.Unprotected):
            text = None
    if text is None or tl.normalize(text) != tl.normalize(reason):
        raise Stop("Evidence disagrees with the prepared promotion (the reason for skipping the review).")


def rederive(root: Path, p: dict, pdir: Path, tr: Dict[str, str]) -> dict:
    """§7.2 step 3, in order. Returns what the ledger records, each from its
    primary (Decision 48): the review's call id from its frontmatter, the
    override from run.json, the earlier refutations recomputed as prepare
    computes them."""
    ctx = read_json(pdir / "context.json") or {}
    # Where the push goes: the repo and trunk the window's lease file recorded, and the repo prepare merged in.
    if (p.get("repo") not in tr or p.get("trunk") != tr[p["repo"]] or ctx.get("repo") != p["repo"]
            or ctx.get("promote_id") != p.get("promote_id") or ctx.get("lease") != p.get("lease")
            or p.get("promote_id") != pdir.name):
        raise Stop("Evidence disagrees with the prepared promotion (the repo or the trunk).")
    run_rec = read_json(root / "state" / "evidence" / str(p["run_id"]) / "run.json") or {}
    base, merge = pair_of(run_rec, p)
    if (run_rec.get("result") != "PASS" or run_rec.get("promote_id") != p["promote_id"] or merge != p["merge_sha"]
            or base != p["trunk_sha_at_prepare"] or run_rec.get("refuter") != "deferred-to-promote"
            or run_rec.get("fingerprint") in (None, "", "null")):
        raise Stop("Evidence disagrees with the prepared promotion (the gate run's record).")
    promo = run_rec.get("promotion") or {}
    if (promo.get("overrode_review") or None) != (p.get("overrode_review") or None):
        raise Stop("Evidence disagrees with the prepared promotion (the review it sets aside).")
    tree = pdir / outer_of(tr)
    call_id = None
    if p.get("review") is None:
        check_skip(root, p, promo)
    else:
        call_id = check_review(root, p, run_rec, tree)
    state, detail = dc.distribution_state(root)
    if state != "clean":
        raise Stop(dc.refusal(state, detail, PUSHED))
    repo, trunk, nn = p["repo"], p["trunk"], p["lease"]
    src = root / "target" / repo
    code, _, err = git(src, "fetch", "--quiet", "origin")
    now_sha = rev(src, "origin/" + trunk) if code == 0 else ""
    if now_sha != p["trunk_sha_at_prepare"]:
        raise Stop("Trunk moved since the trial merge (was %s, now %s). The tested merge is stale. Run `promote %s` "
                   "again." % (p["trunk_sha_at_prepare"][:7], now_sha[:7] or last_line(err), nn))
    tip = rev(src, "lease/%s" % nn)
    if tip != p["lease_tip"]:
        _, log, _ = git(src, "log", "--reverse", "--format=%s", "%s..lease/%s" % (p["lease_tip"], nn))
        new = [s for s in log.splitlines() if s.strip()]
        raise Stop("Window %s's branch changed after the trial merge — %s: %s. Run `promote %s` again."
                   % (nn, "1 new commit" if len(new) == 1 else "%d new commits" % len(new),
                      ", ".join('"%s"' % s for s in new) or "its tip moved", nn))
    wt = pdir / repo
    if rev(wt, p["merge_sha"] + "^2") != p["lease_tip"] or rev(wt, p["merge_sha"] + "^1") != p["trunk_sha_at_prepare"]:
        raise Stop("Evidence disagrees with the prepared promotion (the merge commit's parents).")
    outer = outer_of(tr)
    heads = {outer: ctx.get("merge_sha")}
    heads.update({"%s/%s" % (outer, rel): (n or {}).get("merge_sha") for rel, n in (ctx.get("nested") or {}).items()})
    if heads.get(repo) != p["merge_sha"] or not scratch_is(pdir, heads):
        raise Stop("Evidence disagrees with the prepared promotion (the scratch is not the merge commit).")
    fp, _ = fingerprint(root, tree)
    if not (fp == p["fp_merged"] == run_rec.get("fingerprint")
            and (p.get("review") is None or p["review"].get("fingerprint") == fp)):
        raise Stop("Evidence disagrees with the prepared promotion (the fingerprint of the scratch).")
    return {"call_id": call_id, "overrode": promo.get("overrode_review"),
            "earlier_refuted": earlier_refuted(root, p["lease"], p["promote_id"], fp, p["lease_tip"],
                                               p["trunk_sha_at_prepare"])}


def one_line(text: object) -> str:
    """A field of a one-line record (the ledger, the summary line): every run of
    whitespace — newlines and tabs included — one space (Decision 49)."""
    return " ".join(str(text).split())


def record_yes(root: Path, p: dict, pdir: Path, me: dict, mode: str, yes: dict, said: Optional[str],
               ev: dict) -> None:
    """§7.2 step 4, before the push. The quote is the operator's own words — the
    transcript entry's text, or what was typed at the terminal — never the
    agent's transcription of them (Decision 49); `ev` is what rederive verified."""
    at = tl.iso_utc(time.time())
    words = yes["text"] if mode == "transcribed" else yes["typed"]["text"]
    extra = {"confirmed_at": at, "confirm_mode": mode,
             "confirmed_by": {"session_id": me["session_id"], "lease": me["lease"], "pid": me["pid"], "user": me["user"]},
             "transcript_session_id": yes.get("transcript_session_id"), "transcript_ref": yes.get("transcript_ref"),
             "shown_ref": yes.get("shown_ref")}
    if mode == "transcribed":
        extra["operator_said"] = yes["text"]
        extra["operator_said_as_transcribed"] = said
    else:
        extra["typed"] = yes["typed"]
    update_run(root, p["run_id"], lambda rec: rec.setdefault("promotion", {}).update(extra))
    ev_dir = root / "vault" / "evidence"
    with open(str(ev_dir / ("%s.md" % p["run_id"])), "a") as fh:
        fh.write('\nPromoted to %s at %s after the operator said: "%s"\n'
                 % (p["trunk"], time.strftime("%H:%M"), one_line(words)))
    o = ev.get("overrode")
    fields = [at, "window %s" % p["lease"], "merge %s" % p["merge_sha"], "run %s" % p["run_id"],
              ("STANDS (review %s)" % ev["call_id"]) if ev.get("call_id") else
              "skipped: %s" % p.get("review_skipped_reason"),
              'operator: "%s"' % words, "confirm: %s" % mode] + \
             (["overrode: %s" % (o.get("call_id") if isinstance(o, dict) else o)] if o else []) + \
             (["earlier refuted: %s" % ",".join(str(e.get("call_id")) for e in ev["earlier_refuted"])]
              if ev.get("earlier_refuted") else [])
    log = ev_dir / "promotions.log"
    new = not log.exists()
    with open(str(log), "a") as fh:
        fh.write("\t".join(one_line(f) for f in fields) + "\n")
    if new:
        run(["python3", str(root / "core" / "manifest-append.py"), str(log)])
    p["confirmed_at"] = at
    write_json(pdir / "prepared.json", p)


def push(root: Path, p: dict, pdir: Path) -> None:
    """§7.2 step 5: the merge commit the evidence names, from the scratch, to
    <repo>'s origin — nothing else. DAEDALUS_PROMOTE_ID is what the pre-push
    hook checks against prepared.json's confirmed_at and merge_sha (§7.3)."""
    seam = os.environ.get("PROMOTE_TEST_BEFORE_PUSH")
    if seam:                                   # test seam: move trunk in the race the next sentence names
        subprocess.run(["bash", "-c", seam], capture_output=True)
    env = dict(os.environ, DAEDALUS_PROMOTE_ID=p["promote_id"])
    code, _, err = git(pdir / p["repo"], "push", "origin", "%s:refs/heads/%s" % (p["merge_sha"], p["trunk"]),
                       env=env, timeout=600, stop=False)
    if code != 0 and origin_trunk(pdir / p["repo"], p["trunk"]) == p["merge_sha"]:
        return                                 # git failed after origin took it (a local ref's lock): it is pushed
    if code != 0:
        # Decision 34: a promotion whose push failed is never pushable again — the hook refuses it.
        p["push_failed_at"] = tl.iso_utc(time.time())
        write_json(pdir / "prepared.json", p)
        # With the hook installed (Task 12) a push onto a trunk that moved is refused by the hook
        # (the remote is no longer at the tested base) before git reports "[rejected]" — measured
        # by the review — so the race is judged from origin itself, not from git's wording.
        moved = origin_trunk(pdir / p["repo"], p["trunk"]) not in ("", p["trunk_sha_at_prepare"])
        if moved or re.search(r"non-fast-forward|fetch first|\[rejected\]", err or ""):
            raise Stop("Push rejected: trunk moved during confirm. Run promote again.", suffix=ON_ORIGIN)
        raise Stop("The push to origin failed (%s). Run promote again." % last_line(err), suffix=ON_ORIGIN)


def guarded(root: Path, repo: str) -> None:
    """§14: promote refuses while git's own gate is gone from the window's repo. A deployment set up
    before the hook existed gets it now (§7.3); a foreign pre-push hook or a core.hooksPath (husky sets
    one when a target's gates run npm install) is named, never overwritten, and nothing is recorded."""
    try:
        import prepush
        s, sentence = prepush.install(root / "target" / repo)
    except (ImportError, OSError, ValueError) as e:
        s, sentence = "failed", "the pre-push hook could not be installed in target/%s (%s); run core/setup.sh" % (repo, e)
    if s not in ("installed", "unchanged"):
        raise Stop("The trunk is unguarded in git: %s. The yes was not recorded; run promote --confirm again "
                   "once the hook is in place." % sentence.rstrip("."))


def origin_trunk(repo: Path, trunk: str) -> str:
    """The sha origin's trunk has now, asked of origin itself ("" when it cannot be read)."""
    code, out, _ = run(["git", "-C", str(repo), "ls-remote", "origin", "refs/heads/" + trunk], timeout=120)
    return out.split()[0] if code == 0 and out.split() else ""


def reason(e: BaseException) -> str:
    """A refusal's sentence as a reason inside a note: no "Nothing was pushed." after a push."""
    text = str(e).strip()
    for suffix in (PUSHED, ON_ORIGIN):
        if text.endswith(suffix):
            text = text[:-len(suffix)].rstrip()
    return text.rstrip(".") or type(e).__name__


def bring_forward(root: Path, p: dict) -> List[str]:
    """§7.2 step 6 (a), by whichever process ran the confirm: fetch the trunk
    into target/<repo>; fast-forward the checkout only when it is on trunk and
    clean. Never raises; what it could not do is a note."""
    repo, trunk = p["repo"], p["trunk"]
    src = root / "target" / repo
    code, _, err = git(src, "fetch", "--quiet", "origin", trunk, stop=False)
    if code != 0:
        return ["target/%s could not fetch the new %s (%s); its checkout is untouched. `git -C target/%s fetch "
                "origin` brings the trunk ref up to date." % (repo, trunk, last_line(err), repo)]
    code, head, _ = run(["git", "-C", str(src), "symbolic-ref", "--short", "-q", "HEAD"])
    branch = head.strip() if code == 0 and head.strip() else "a detached HEAD"
    if branch != trunk:
        return ["target/%s is on %s; the trunk ref is updated, the checkout is untouched." % (repo, branch)]
    try:
        clean_tree = not ll.dirty_files(src)
    except ll.Refused:
        clean_tree = False
    if not clean_tree:
        return ["target/%s has uncommitted changes; the trunk ref is updated, the checkout is untouched." % repo]
    code, _, err = git(src, "merge", "--ff-only", "--quiet", "origin/" + trunk, stop=False)
    if code != 0:
        return ["target/%s could not be fast-forwarded (%s); the trunk ref is updated, the checkout is untouched."
                % (repo, last_line(err))]
    return []


def tell_marker(root: Path, p: dict, tr: Dict[str, str]) -> List[str]:
    """§7.2 step 6 (b): the prime session's marker told (target_base, promotions) — once per promotion.
    What it could not tell is a note (the announcement repeats it, never "brought forward")."""
    repo = p["repo"]
    sid = (p.get("prepared_by") or {}).get("session_id") or (read_leases(root).get("prime") or {}).get("session_id")
    if not sid:
        return ["No prime session is known, so no session's marker records the promotion."]
    mp = v.marker_path(root, sid)
    m = read_json(mp)
    if m is None:
        return ["The prime session's marker was not found, so it does not record the promotion; its next Stop may "
                "report the trunk as moved."]
    if any(x.get("id") == p["promote_id"] for x in m.get("promotions") or [] if isinstance(x, dict)):
        return []
    if repo == outer_of(tr):
        m["target_base"] = p["merge_sha"]
    m["promotions"] = (m.get("promotions") or []) + [{"id": p["promote_id"], "sha": p["merge_sha"],
                                                      "at": tl.iso_utc(time.time()), "repo": repo}]
    write_json(mp, m)
    return []


def after_push(root: Path, p: dict, pdir: Path, tr: Dict[str, str], mode: str, yes: dict) -> List[str]:
    """Everything after a push that landed (Decision 47): the pushed stamp and the
    lease's promoted entry first — they are what a second confirm and the board
    read — then the checkout and the marker. Each step is best-effort: a failure
    is a note that says what was not done, never a refusal saying nothing was
    pushed."""
    nn = p["lease"]
    notes: List[str] = []

    def step(fn: Callable[[], object], note: str) -> object:
        try:
            return fn()
        except Exception as e:                 # noqa: BLE001 — the push landed; say what did not follow it
            notes.append(note % reason(e))
            return None

    stamp = {"at": tl.iso_utc(time.time()), "hhmm": time.strftime("%H:%M"), "lease": nn, "merge_sha": p["merge_sha"],
             "confirm_mode": mode, "tty": (yes.get("typed") or {}).get("tty")}
    stamped = step(lambda: write_json(pdir / "pushed", stamp) or True,
                   "The pushed stamp could not be written (%s); a second confirm of this promotion is still refused, "
                   "because the yes is recorded.")
    step(lambda: ll.record_promotion(root, nn, p["promote_id"]),
         "Window " + nn + "'s lease file could not record the promotion (%s).")
    notes.extend(step(lambda: bring_forward(root, p),
                      "target/" + p["repo"] + " could not be brought forward (%s); the checkout is untouched.") or [])
    notes.extend(step(lambda: tell_marker(root, p, tr),
                      "The prime session's marker could not record the promotion (%s); its next Stop may report the "
                      "trunk as moved.") or [])
    # Decision 7 (update-command design): the scratch is detached at the merge commit just pushed, so it holds
    # nothing trunk lacks; left behind, it is copied into every later safety copy. This confirm holds the
    # promotion's .confirm.lock, so no clean is removing it too. The records stay: a second confirm is refused.
    step(lambda: remove_scratch(root, pdir, tr, strict=True) or True,
         "The promote scratch of promotion " + p["promote_id"] + " could not be removed (%s); `core/promote.sh "
         + nn + " --clean` removes it.")
    if stamped:
        # The stamp is rewritten with how the follow-ups went: the prime's announcement (§4.3) waits for
        # finished_at and repeats these notes, so it never says "brought forward" before or instead of it.
        step(lambda: write_json(pdir / "pushed", dict(stamp, followups=list(notes),
                                                      finished_at=tl.iso_utc(time.time()))),
             "The pushed stamp could not record how the confirm finished (%s); the prime is not told of this push.")
    return notes


@contextlib.contextmanager
def confirm_lock(pdir: Path, nn: str):
    """One confirm of a promotion at a time (Decision 47): an exclusive lock on
    state/promote/<id>/.confirm.lock, held from reading prepared.json to the
    pushed stamp; a second confirm is refused, never queued behind the first."""
    fh = open(str(pdir / ".confirm.lock"), "a")
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise Stop("Promotion %s of window %s is being confirmed by another process." % (pdir.name, nn))
        yield
    finally:
        fh.close()


def confirm(root: Path, a: dict) -> int:
    leases = read_leases(root)
    me = who(root, leases)
    nn, lease = window(leases, a["token"])
    mode = confirm_mode(root)
    pdir, _ = latest_prepared(root, nn, a.get("id"))
    with confirm_lock(pdir, nn):
        p = read_json(pdir / "prepared.json") or {}   # re-read under the lock
        if (pdir / "pushed").exists() or (pdir / "announced").exists():
            raise Stop("Promotion %s of window %s was already pushed. Run `promote %s` for anything newer."
                       % (pdir.name, nn, nn))
        if p.get("push_failed_at"):
            raise Stop("Promotion %s of window %s already failed to push (%s). Run `promote %s` again."
                       % (pdir.name, nn, p["push_failed_at"], nn))
        if p.get("confirmed_at"):
            raise Stop("Promotion %s of window %s was already confirmed (%s) by a confirm that did not finish. Run "
                       "`promote %s` again." % (pdir.name, nn, p["confirmed_at"], nn))
        tr = trunks(root, nn, lease)
        if p.get("repo") in tr:                # before the yes: no confirmed_at for a push that will not happen
            guarded(root, p["repo"])           # (a repo the window does not have is refused by rederive)
        if mode == "transcribed":
            yes = transcribed_yes(root, me, a.get("said") or "", cutoff(root, p, pdir), "the promote block")
        else:
            if a.get("said") is not None:
                raise Stop("In tty mode the operator types the yes in a terminal; --operator-said is not accepted. "
                           "Paste this line in your own shell: `cd %s && core/promote.sh %s --confirm`" % (root, nn))
            yes = tty_yes(root, p)
        ev = rederive(root, p, pdir, tr)
        record_yes(root, p, pdir, me, mode, yes, a.get("said"), ev)
        push(root, p, pdir)
        notes = after_push(root, p, pdir, tr, mode, yes)
    alias = " (%s)" % p["alias"] if p.get("alias") else ""
    lines = notes + ["Promoted window %s's work%s to %s (merge commit %s; evidence %s). The window's worktree is still "
                     "there; say \"release window %d\" when you are done with it, or keep working — the next promote "
                     "takes only what is new." % (nn, alias, p["trunk"], p["merge_sha"][:7], p["run_id"], int(nn))]
    try:
        rel_ = release_words(root)
    except Exception:                          # noqa: BLE001 — the push landed; the release sentence is a courtesy
        rel_ = None
    if rel_ is not None:
        lines.append("This is a release: run %s to receive it." % (rel_ or "the update"))
    print("\n".join(lines))
    return 0

# --- doctor (§15) -----------------------------------------------------------------------------------

def leftover_scratch(root: Path) -> List[str]:
    """The ids of pushed (or announced) promotions whose directory still holds
    anything but its records: scratch a confirm or the upgrade should have
    removed (update-command Decisions 7, 10a). Read-only."""
    base = root / "state" / "promote"
    held: List[str] = []
    try:
        for pdir in sorted(base.iterdir()) if base.is_dir() else []:
            if pdir.is_dir() and not pdir.is_symlink() and was_pushed(pdir) \
                    and any(c.name not in RECORDS for c in pdir.iterdir()):
                held.append(pdir.name)
    except OSError:
        return held
    return held


def doctor(root: Path) -> int:
    """The §15 lines for promote, one per state; doctor.sh counts the MISSING
    ones. Never fails on its own: a line it cannot compute is not printed."""
    held = leftover_scratch(root)
    if held:
        print("NOTE     promote scratch: %d pushed promotion%s still hold%s scratch (%s) — core/promote.sh NN --clean "
              "removes it (NN its window: %s)" % (len(held), "" if len(held) == 1 else "s", "s" if len(held) == 1 else "",
                                                  ", ".join(held), ", ".join(sorted({h[:2] for h in held}))))
    try:
        mode = tl.confirm_mode(root)
        print("OK       promote: the operator's yes is transcribed and checked against the session transcript"
              if mode == "transcribed" else "OK       promote: the operator types yes in a terminal (tty)")
        if mode == "transcribed":
            # critic finding 4 (A12): the installed build's shape, read from its newest interactive transcript
            try:
                state, detail = tl.shape_report(root)
            except Exception:           # a line doctor cannot compute is not printed
                state, detail = "", ""
            if state == "ok":
                print("OK       promote: this Claude Code build's transcript shape (%s) reads as the one Daedalus was "
                      "tested against" % detail)
            elif state == "drift":
                print("MISSING  promote: %s (%s)" % (tl.DRIFT, detail))
            elif state == "none":
                print("NOTE     promote: no interactive session transcript of this deployment yet, so this Claude Code "
                      "build's transcript shape is not measured")
    except ValueError as e:
        print("MISSING  %s" % e)
    try:
        name = ll.target_name(root)
    except ll.Refused:
        return 0
    if (root / "target" / name).is_dir():
        nested = v.nested_relpaths(root)
        repos = [name] + ["%s/%s" % (name, n) for n in nested]
        heads, missing_head = ["%s=%s" % (name, v.target_branch(root))], False
        for n in nested:
            code, head, _ = run(["git", "-C", str(root / "target" / name / n), "symbolic-ref", "--short",
                                 "refs/remotes/origin/HEAD"])
            if code == 0 and head.strip().startswith("origin/"):
                heads.append("%s/%s=%s" % (name, n, head.strip()[len("origin/"):]))
            else:
                missing_head = True
                print("MISSING  nested repo %s has no origin/HEAD — run git -C target/%s/%s remote set-head origin -a"
                      % (n, name, n))
        if not missing_head:
            print("OK       trunk: %s" % ", ".join(heads))
        import prepush
        ok = []
        for repo in repos:
            s, where = prepush.state(root / "target" / repo)
            if s == "installed":
                ok.append("target/" + repo)
            elif s == "noexec":
                print("MISSING  pre-push hook in target/%s is not executable, so git never runs it — run core/setup.sh "
                      "(the trunk is unguarded in git until it is)" % repo)
            elif s == "differs":
                print("NOTE     pre-push hook in target/%s differs from this release's — run core/setup.sh to refresh it"
                      % repo)
            elif s == "foreign":
                print("MISSING  target/%s has a pre-push hook Daedalus did not install (%s) — the trunk is unguarded in "
                      "git until Daedalus's hook runs there; merge the two by hand" % (repo, where))
            elif s == "hookspath":
                print("MISSING  target/%s sets core.hooksPath (%s), so its pre-push hook never runs — unset it (git -C "
                      "target/%s config --unset core.hooksPath); the trunk is unguarded in git until then"
                      % (repo, where, repo))
            else:
                print("MISSING  pre-push hook in target/%s — run core/setup.sh (the trunk is unguarded in git until it "
                      "is installed)" % repo)
        if ok:
            print("OK       pre-push hook: %s" % ", ".join(ok))
    # Only the live windows' current occupants (Decision 51's occupant_prepares):
    # a released window, or an earlier occupant of a reused number, has nothing
    # left for the operator to confirm; its records are kept, not reported.
    try:
        leases = read_leases(root)
    except (ll.Refused, OSError):
        leases = {}   # an unreadable lease file is the leases block's line, not this one's
    for nn, lease in sorted(leases.items()):
        if nn == "prime":
            continue
        pending = [p for p in occupant_prepares(root, nn, lease) if not p.get("confirmed_at")]
        if not pending:
            continue
        p = pending[-1]
        at = time.strftime("%H:%M", time.localtime(float(p.get("prepared_ts") or 0)))
        if (p.get("review") or {}).get("verdict") == "REFUTED":
            print("NOTE     promote: window %s's last prepare (%s) was refuted by the review, so it cannot be confirmed "
                  "— fix the work and run promote %s again, or promote it without the review with a written reason "
                  "(promote %s --skip-review --reason \"...\")" % (nn, at, nn, nn))
        else:
            print("NOTE     promote: window %s prepared at %s, not confirmed — say yes to the prime or run promote again"
                  % (nn, at))
    return 0


# --- the command line -----------------------------------------------------------------------------

USAGE = ("Usage: core/promote.sh <NN> [--skip-review [--reason \"...\"]] | <NN> --confirm [--operator-said \"...\"] "
         "[--id <promote-id>] | <NN> --clean (the prime: any promotion; a session holding no window, or a shell: "
         "pushed promotions only)")
VALUE_FLAGS: Dict[str, str] = {"--operator-said": "said", "--id": "id", "--reason": "reason"}   # flags with a value
SWITCHES: Dict[str, str] = {"--clean": "clean", "--confirm": "confirm", "--skip-review": "skip",
                            "--doctor": "doctor"}   # flags without one


def parse(argv: List[str]) -> dict:
    a: dict = {"token": None}
    i = 0
    while i < len(argv):
        x = argv[i]
        if x in VALUE_FLAGS:
            if i + 1 >= len(argv):
                raise Stop("%s needs a value. %s" % (x, USAGE))
            a[VALUE_FLAGS[x]] = argv[i + 1]
            i += 2
            continue
        if x in SWITCHES:
            a[SWITCHES[x]] = True
        elif x.startswith("-"):
            raise Stop("Unknown option %s. %s" % (x, USAGE))
        elif a["token"] is None:
            a["token"] = x
        else:
            raise Stop("One window number only (got %s and %s). %s" % (a["token"], x, USAGE))
        i += 1
    return a


def dispatch(root: Path, a: dict) -> int:
    if a.get("doctor"):
        return doctor(root)
    if not a["token"]:
        raise Stop(USAGE)
    if a.get("confirm"):
        return confirm(root, a)
    if a.get("clean"):
        return clean(root, a)
    return prepare(root, a)


def main(argv: List[str]) -> int:
    root = v.ROOT
    try:
        home_check(root)
        return dispatch(root, parse(argv))
    except ll.Refused as e:
        err: Stop = Stop(str(e) + ".")
    except Stop as e:
        err = e
    sys.stderr.write("daedalus: %s\n" % err)
    return err.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
