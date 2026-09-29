#!/usr/bin/env python3
"""promote (spec §7): the one way a window's work reaches trunk.

    core/promote.sh <NN>                     prepare (§7.1)

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

Exit: 0 ready (or done); 1 the work is not ready (gates FAIL or INVALID,
REFUTED, the review could not be completed); 2 refused. Every refusal ends
"Nothing was pushed." or "Nothing changed on origin." (§11.3).
Python 3.9, standard library; distcheck, leaselib, transcriptlib and verifylib
from core/.
"""
from __future__ import annotations

import calendar
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
RECORDS = ("prepared.json", "context.json", "pushed", "announced")
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


def git(repo: Path, *args: str, env: Optional[dict] = None, timeout: Optional[float] = 300) -> Tuple[int, str, str]:
    """git in one repo, with the shared-.git lock retry (§7.1 step 3): a "cannot
    lock ref" / "Unable to create '….lock'" is retried three times, one second
    apart, and then stops the promotion — never a null fingerprint or an
    INVALID run."""
    err = ""
    for attempt in range(4):
        code, out, err = run(["git", "-C", str(repo)] + list(args), env=env, timeout=timeout)
        if code == 0 or not LOCK_ERR.search(err or ""):
            return code, out, err
        if attempt < 3:
            time.sleep(1)
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


def remove_scratch(root: Path, pdir: Path, tr: Dict[str, str]) -> None:
    """One promotion's scratch worktrees — nested first, they sit inside the
    outer — never its records (prepared.json, context.json, the stamps)."""
    for repo in sorted(tr, key=len, reverse=True):
        dest = pdir / repo
        if dest.exists():
            run(["git", "-C", str(root / "target" / repo), "worktree", "remove", "--force", str(dest)])
        run(["git", "-C", str(root / "target" / repo), "worktree", "prune"])
    if pdir.is_dir():
        for child in pdir.iterdir():
            if child.name in RECORDS:
                continue
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(str(child), ignore_errors=True)
            else:
                child.unlink()


def clean_window(root: Path, nn: str, tr: Dict[str, str]) -> List[str]:
    """Every scratch of window NN's promotions (plan 4 Decision 22)."""
    removed = []
    base = root / "state" / "promote"
    for pdir in sorted(base.glob("%s-*" % nn)) if base.is_dir() else []:
        if any((pdir / repo).exists() for repo in tr):
            remove_scratch(root, pdir, tr)
            removed.append(pdir.name)
    return removed


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
        where = ("gate %s: `%s` exit %s; log at %s" % (g["n"], g["command"], g["exit"], rel(root, g["log"]))
                 if g else "see state/evidence/%s" % rec.get("run_id"))
        raise Stop("Gates FAIL on the merged tree (%s). The lease was green on its own branch; the merge with current "
                   "%s is what fails." % (where, trunk), code=1)
    reason = ("the fingerprint was null" if rec.get("fingerprint") in (None, "null") else
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


def first_line(p: dict, ready: bool, root: Path) -> str:
    alias = " (%s)" % p["alias"] if p.get("alias") else ""
    if not ready:
        return "Window %s's work%s is not ready to promote onto %s." % (p["lease"], alias, p["trunk"])
    return "Ready to promote window %s's work%s onto %s." % (p["lease"], alias, p["trunk"])


def block_opening(p: dict) -> str:
    """The words the assistant turn that showed the block must carry (Decision 30):
    the ready first line without its ending, so the release clause (Task 8) may follow."""
    alias = " (%s)" % p["alias"] if p.get("alias") else ""
    return "Ready to promote window %s's work%s onto %s" % (p["lease"], alias, p["trunk"])


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
        "Nothing has been pushed. Say yes to push." if ready else
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
    ])
    return decision, record


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


def prepare(root: Path, a: dict) -> int:
    leases = read_leases(root)
    me = who(root, leases)
    nn, lease = window(leases, a["token"])
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
    clean_window(root, nn, tr)
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
    rv = review(root, run_id, tree) if not a.get("skip") else None
    fp_after, _ = fingerprint(root, tree)
    seen = [fp, fp_after, run_rec.get("fingerprint")] + ([rv["fingerprint"]] if rv else [])
    if len(set(seen)) != 1:
        raise Stop("The tree changed while promote was running (fingerprint before %s, after %s). Run promote again."
                   % (fp[:12], (fp_after if fp_after != fp else next(s for s in seen if s != fp) or "null")[:12]))
    at, ts = tl.iso_utc(time.time()), time.time()
    dist = dc.committed_dist(root)
    secs = sum(int(g.get("duration_s") or 0) for g in run_rec.get("gates") or [])
    p = {"promote_id": pid, "lease": nn, "alias": lease.get("alias"), "repo": repo, "trunk": trunk,
         "merge_sha": merge, "trunk_sha_at_prepare": trunk_sha, "lease_tip": tip, "fp_merged": fp, "run_id": run_id,
         "review": ({k: rv[k] for k in ("call_id", "verdict", "file", "fingerprint", "request_sha", "findings")}
                    if rv else None),
         "review_skipped_reason": None, "skip_transcript_ref": None, "skip_transcript_session_id": None,
         "overrode_review": None, "earlier_refuted": er,
         "core_tree": dist.get("core_tree"), "charter_sha": dist.get("charter_sha"), "commits": commits,
         "gates": {"count": len(run_rec.get("gates") or []), "seconds": secs}, "fetched_at": fetched_at,
         "prepared_at": at, "prepared_ts": ts,
         "prepared_by": {"session_id": me["session_id"], "lease": me["lease"], "pid": me["pid"], "user": me["user"]}}
    write_json(pdir / "prepared.json", p)

    def record(rec: dict) -> None:
        rec["invoked_by"] = {"kind": me["kind"], "session_id": me["session_id"], "pid": me["pid"], "lease": me["lease"]}
        rec["promotion"] = {"promote_id": pid, "prepared_at": at, "review_skipped_reason": None,
                            "skip_transcript_ref": None, "skip_transcript_session_id": None, "overrode_review": None}
    update_run(root, run_id, record)
    decision, rec_text = decision_block(root, p)
    print(decision + "\n\n" + rec_text)
    sys.stdout.flush()
    if rv and rv["verdict"] == "REFUTED":
        raise Stop(refuted_sentence(p), code=1)
    return 0


# --- the command line -----------------------------------------------------------------------------

USAGE = "Usage: core/promote.sh <NN>"
VALUE_FLAGS: Dict[str, str] = {}           # flag -> key, for flags that take a value (later tasks add theirs)
SWITCHES: Dict[str, str] = {}              # flag -> key, for flags without one


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
    if not a["token"]:
        raise Stop(USAGE)
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
