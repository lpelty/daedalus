#!/usr/bin/env python3
"""PostToolUse(Bash) + Stop hook: the boundary that command phrasing cannot
route around.

Four checks against the session-start marker: protected files modified
beyond the operator's snapshot; the gate definition's hash; evidence files
in this session's window that no run produced; and (Stop only) target main
having moved past where origin/<config target.branch> stood at session start (PROP-019: fail-closed). On Stop, exit 2
ends nothing until fixed; on PostToolUse, exit 2 is immediate feedback — the
command already ran.

Since v0.7.0 the same file is also wired on PreToolUse(Edit|Write; NotebookEdit since 0.7.3) — the
boundary warning (spec §4.6): one locked read of the leases, then a path in
another live window's changed set is denied ONCE per session (the deny
reason is the warning; recorded under `warned` in
state/session-<sid>-boundary.json, pruned with the marker, §4.10) and let
through with the warning as context on every later attempt; the prime's
checkout target/<repo> is denied for every window; a released lease's
worktree is closed; another window's worktree is denied every time (§3.1);
vault/hot.md is written only by core/hot.py, for every session (v0.12.6). A
session that cannot be bound while lease files exist — or a lease file that
cannot be read — fails CLOSED under target/ and worktrees/ (§4.4). The whole check is
write_check, which guard-bash.py runs on every Bash write operand too, so
the Edit and Bash legs are one function and say the same sentences.
Ownership of a tree is judged from the PATH alone (tree_deny), before any
repository is looked for under the operand: `rm -rf worktrees/02` names
no file inside a repository and was allowed while a file inside it was
denied (Task 11 review). A warning that cannot be recorded (state/ not
writable) is still a deny — the stop repeats, and one line on stderr says
why — never a silent allow.

A timed-out PreToolUse hook is fail-OPEN (Claude Code treats it as no
decision), so the Stop hook carries the backstop (§4.6 "Budget, and what a
timeout costs"): at every Stop it records under `seen` every other live
lease's changed set as it stands; at the next Stop a path of this
session's own changed set that was in the PREVIOUS snapshot and has no
`warned` entry blocks with "the warning never fired", once (v0.12.7: a
said block is recorded under `warned`) — and not at all for a path this
window took over by merging that window's branch, unless it changed the
path again after the merge (check_backstop). A visitor — a
session with DIRECT_CALL_ID in its environment (§4.8, §8.5) — is
read-only and cannot have caused any Stop-time dirt: the backstop does
not run for it and every Stop reason becomes a "(visitor, not blocking)"
note, exit 0. Its PreToolUse denials are unchanged (a denial costs a
read-only session nothing).
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

RESTART = (" If the operator made this change, restart the session — a FRESH "
           "session re-snapshots. A resume (--continue) keeps the old session "
           "id and its snapshot; to re-baseline under resume, the operator "
           "deletes state/session-<id>.json from outside the session first.")


MANIFEST_FILES = (".manifest", ".manifest.lock", "promotions.log")   # gates.sh's ledger, the lock its appends take, promote's ledger (spec §7.2 step 4)


def evidence_run_id(rel: str) -> str:
    """The run a vault/evidence file belongs to, from its name: <run-id>.md is the run's summary; the refuter's
    verdict, <run-id>-review.md, is refute.sh's output for that run; one lens's review of a large change,
    <run-id>-lens-<name>-review.md (core/review-lenses.py), is the same run's output. "" for any other name."""
    name = rel.rsplit("/", 1)[-1]
    rid = name[:-3] if name.endswith(".md") else ""
    if rid.endswith("-review"):
        rid = rid[:-len("-review")]
        rid = re.sub(r"-lens-[a-z0-9_]{1,24}$", "", rid)
    return rid


def _sanctioned_evidence(root: Path, rel: str, manifest: set) -> bool:
    """A vault/evidence path new this session that gates.sh actually
    recorded is the stage's own output, not tampering (PROP-017 finding 1):
    it must be listed in the manifest AND have the state-side run record
    (the vault-side frontmatter fallback would let a hand-written file
    vouch for itself). `.manifest` is rewritten by every run and
    `.manifest.lock` is the lock every append takes (§4.9); their entries
    are judged here and by check_evidence, so the files themselves are excused.
    The refuter's verdict and a lens's review are judged by their run's record
    (evidence_run_id): with the refuter on by default every STANDS verdict in a
    vault the parent git can see once blocked the Stop hook as protected dirt."""
    name = rel.rsplit("/", 1)[-1]
    if name in MANIFEST_FILES:
        return True
    if str((root / rel).resolve()) not in manifest:
        return False
    rec = v.run_record(root, evidence_run_id(rel))
    return bool(rec) and rec.get("source") == "state"


RUN_ID = re.compile(r"[0-9]{8}-[0-9]{6}-[0-9a-f]{6}")


def run_json(root: Path, rid: str, manifest: set) -> Optional[dict]:
    """Run <rid>'s state-side run.json as gates.sh wrote it, or None. Only a MANIFESTED record counts: gates.sh
    writes run.json first and manifests it in the same breath (§4.9), so every real run's record is there from its
    first moment, while a record a session wrote under state/ by hand (state/ is not protected) vouches for
    nothing."""
    if not RUN_ID.fullmatch(rid or ""):
        return None
    rj = root / "state" / "evidence" / rid / "run.json"
    if str(rj.resolve()) not in manifest:
        return None
    try:
        d = json.loads(rj.read_text())
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def another_sessions_run(rec: dict, sid: object, mine: Optional[str]) -> bool:
    """check_protected's question (v0.12.7, PROP-035 §2): is this run some other session's? The session id the
    run recorded decides when there is one — a different one is another session's run, whatever window it ran
    in, and this session's own run is always its own (its unmanifested evidence is still flagged: the PROP-017
    guard). A record with no session id is judged by its window: a lease other than this session's."""
    rs = rec.get("session_id")
    if rs:
        return str(rs) != str(sid or "")
    rl = rec.get("lease")
    return bool(rl and mine and str(rl) != str(mine))


def names_this_window(rec: dict, sid: object, mine: Optional[str]) -> bool:
    """check_evidence's audience for a run (v0.12.7, PROP-035 §2): the session its run.json names, or the window
    (lease) it names — a later holder of that number inherits its branch and hears about the run. A record that
    names neither is everyone's, as before: nothing vouches for it."""
    rs, rl = rec.get("session_id"), rec.get("lease")
    if not rs and not rl:
        return True
    return bool((rs and str(rs) == str(sid or "")) or (rl and mine and str(rl) == str(mine)))


def check_protected(root: Path, marker: dict, reasons: List[str]) -> None:
    snapshot = marker.get("protected_snapshot")
    if snapshot is None:
        # Old-format marker (pre-content-hash session-start): degrade to the
        # line-comparison this replaced. A snapshot-dirty file edited further
        # without changing its porcelain line (e.g. still " M") is missed
        # here — that gap is exactly what the hash keying above closes, but
        # never crash on an old marker.
        now = set(v.protected_status(root))
        before = set(marker.get("protected_status", []))
        new = sorted(now - before)
        if new:
            reasons.append("Protected files changed this session: %s. Revert these — Daedalus's own code changes by proposal, not by edit.%s"
                           % (", ".join(ln[3:] for ln in new), RESTART))
        return
    now = v.protected_snapshot(root)
    bad: List[str] = []
    manifest = None
    mine: Optional[List[Optional[str]]] = None
    sid = marker.get("session_id")
    for path, cur in now.items():
        before = snapshot.get(path)
        if before is None or cur.get("sha") != before.get("sha"):
            # New-this-session evidence that gates.sh recorded is the verify
            # stage's own sanctioned output — running the gate must not trip
            # the boundary (PROP-017). Evidence that PRE-DATES the session
            # and changed is still tampering and still lands in `bad`.
            if before is None and path.startswith("vault/evidence/"):
                if manifest is None:
                    manifest = v.manifest_paths(root)
                if _sanctioned_evidence(root, path, manifest):
                    continue
                # v0.12.7 (PROP-035 §2, 2026-10-21): new is judged against THIS session's snapshot, so another
                # window's gate run writing its evidence while this session lives looked new here too — refute.sh's
                # lens reviews sit unmanifested while the lenses run, and a failed lens's once stayed so — and the
                # advice "revert these" would have deleted that window's review record. Evidence is attributed by
                # its run: a run whose manifested run.json names another session is never this session's dirt,
                # manifested or not. check_evidence still judges it, for the run's own window.
                rec = run_json(root, evidence_run_id(path), manifest)
                if rec is not None:
                    if mine is None and not rec.get("session_id"):
                        mine = [v.lease_context(root, sid).get("mine")]      # one lease read, only when needed
                    if another_sessions_run(rec, sid, (mine or [None])[0]):
                        continue
            if path in ["vault/evidence/" + n for n in MANIFEST_FILES]:
                continue   # rewritten/locked by every run; entries judged above/check_evidence
            bad.append(path)
    if bad:
        reasons.append("Protected files changed this session: %s. Revert these — Daedalus's own code changes by proposal, not by edit.%s"
                       % (", ".join(sorted(bad)), RESTART))


# The three files a session reads once, at its start (CLAUDE.md, "Changes that need a restart"). A change to one under
# a live session blocked EVERY Stop after it until the file was put back — and a `!` command, the operator's own,
# runs inside the session, so their change looked like the session's: every turn blocked until Claude Code locked up
# (2026-10-19). So the first Stop after a change says its reason as a block, and every later one only notes it for
# as long as the file keeps that hash; a further change (a new hash) blocks once more, and a file put back starts
# again. Keyed per session and per file hash (verifylib.stop_once's once-a-session keys, the mechanism every
# blocking Stop reason goes through). PostToolUse(Bash) feeds the reason back after a command until a Stop has said
# it, and records nothing: the Stop is the one that counts.
STARTED_BEFORE = (" If the operator made this change, do not restore it: this session started before it and read the "
                  "file then. Close this session now (core/close.sh: the session log, the vault commit, the capture) "
                  "and have the operator start a fresh one — not a resume, which keeps this session's snapshot. "
                  "CLAUDE.md, \"Changes that need a restart\", says how to give the operator such a change: one "
                  "command or sentence to run after exiting, never a `!` command in this session. This reason blocks "
                  "once; later Stops note it until the file changes again.")


# reason -> its once-a-session key ("<file>:<hash>"), for verifylib.stop_once; filled by the checks below.
SESSION_KEYS: dict = {}


def told_once(root: Path, marker: dict, key: str, now: str, reason: str, reasons: List[str],
              notes: Optional[List[str]], stop: bool) -> None:
    """A changed-file reason keyed to the session and the file's hash: verifylib.stop_once blocks it at one Stop
    and notes it after that. PostToolUse(Bash) feeds it back until a Stop has said it, and records nothing."""
    k = "%s:%s" % (key, now)
    if not stop and v.stop_told(root, marker.get("session_id"), "boundary", k):
        return
    SESSION_KEYS[reason] = k
    reasons.append(reason)


def untold(root: Path, marker: dict, key: str) -> None:
    """The file is back to the session's snapshot: a later change to any hash blocks once again."""
    v.stop_untell(root, marker.get("session_id"), "boundary", key + ":")


RELEASE_CONFIG = ("config.yaml changed under this session, by %s — not by this session. Do not restore it: this "
                  "session started before the release and still runs its old hooks; tell the operator to close it and "
                  "start a new session.")


def _show_sha(root: Path, rev: str) -> Optional[str]:
    try:
        r = subprocess.run(["git", "-C", str(root), "show", "%s:config.yaml" % rev], capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None


def _pull_edge(root: Path, marker: dict) -> Optional[Tuple[str, str]]:
    """(config.yaml's sha256 at the home's HEAD when the session started, at HEAD now) when config.yaml is tracked
    and a pull since then changed it — the release pull's own commit range, read from HEAD's reflog. A marker
    from before v0.7.0 has only the local `started` stamp; it is read as local time."""
    t = marker.get("started_epoch")
    if not isinstance(t, (int, float)):
        try:
            t = time.mktime(time.strptime(str(marker.get("started")), "%Y-%m-%dT%H:%M:%S"))
        except (ValueError, OverflowError):
            return None
    code, out, _ = v.run(["git", "-C", str(root), "reflog", "--date=unix", "--format=%H %gd", "HEAD"])
    if code != 0:
        return None
    start = None
    for ln in out.splitlines():                 # newest first: HEAD's value at the session's start
        sha, _, gd = ln.partition(" ")
        m = re.search(r"\{([0-9]+)\}", gd)
        if m and int(m.group(1)) <= t:
            start = sha
            break
    if not start:
        return None
    a, b = _show_sha(root, start), _show_sha(root, "HEAD")
    return (a, b) if a and b and a != b else None


def release_came_in(root: Path, marker: dict) -> Optional[str]:
    """The release pulled into this home under this session — VERSION now, when it differs from the one the session
    started on — or None. A marker with no "version" was written by a session start older than v0.7.0, the first
    release to record it, so any release now is one pulled under it."""
    now = v.home_version(root)
    if now is None:
        return None
    if "version" not in marker:
        return now
    return now if marker.get("version") != now else None


def _upgrade_edges(root: Path, marker: dict) -> List[Tuple[str, str, str]]:
    """The upgrade's recorded config.yaml writes (state/config-changes.json) this session may read as the release's
    (release-candidate review, finding 4). state/ is outside the protected snapshot, so the session itself could
    write a record; one counts only when a release came in under this session, the record names that release and
    was written after the session started, and it is that release's first record — the upgrade writes config.yaml
    once per release, so any record after it is someone else's."""
    rel = release_came_in(root, marker)
    if rel is None:
        return []
    try:
        d = json.loads((root / v.CONFIG_CHANGES).read_text())
    except (OSError, ValueError):
        return []
    start = marker.get("started_epoch")
    for e in (d.get("changes") or []) if isinstance(d, dict) else []:
        if not (isinstance(e, dict) and all(isinstance(e.get(k), str) for k in ("from", "to", "by"))):
            continue
        if e.get("version") != rel:
            continue
        at = e.get("at_epoch")
        if isinstance(start, (int, float)) and not (isinstance(at, (int, float)) and at >= start):
            return []           # this release's first record predates the session: not a change under it
        return [(e["from"], e["to"], e["by"])]
    return []


def release_change(root: Path, marker: dict, now: str) -> Optional[str]:
    """What changed config.yaml from the marker's sha to <now>, when only the release did: a chain of the
    upgrade's recorded writes (state/config-changes.json, written by core/upgrade.py) and the pull's own commits
    to a tracked config.yaml. The words naming who did it, or None when any step of the change is not theirs."""
    edges: List[Tuple[str, str, str]] = []
    for e in _upgrade_edges(root, marker):
        edges.append(e)
    pe = _pull_edge(root, marker)
    if pe:
        edges.append((pe[0], pe[1], "the release pulled into this home"))
    cur, seen, bys = marker.get("config_sha"), set(), []
    while cur != now:
        step = next(((t, b) for f, t, b in edges if f == cur and t not in seen), None)
        if step is None:
            return None
        cur = step[0]
        seen.add(cur)
        if step[1] not in bys:
            bys.append(step[1])
    return " and ".join(bys) or None


def check_config(root: Path, marker: dict, reasons: List[str], notes: Optional[List[str]] = None,
                 stop: bool = True) -> None:
    now = v.sha256_file(root / "config.yaml")
    if marker.get("config_sha") != now:
        try:
            by = release_change(root, marker, now)
        except Exception:
            by = None
        if by:
            # the release's change (critic finding 7): said once as a block, so the agent hears it and tells the
            # operator; after that only a note — a restart is the remedy, and no Stop can bring it about
            sid = marker.get("session_id")
            b = load_boundary(root, sid)
            if b.get("release_config_told") == now:
                if notes is not None:
                    notes.append(RELEASE_CONFIG % by)
            else:
                reasons.append(RELEASE_CONFIG % by)
                b["release_config_told"] = now
                try:
                    save_boundary(root, sid, b)
                except OSError:
                    pass
        else:
            told = ""
            if ("config_changes_sha" in marker and release_came_in(root, marker) is None
                    and v.sha256_file(root / v.CONFIG_CHANGES) != marker.get("config_changes_sha")):
                # no release came in, yet the upgrade's record changed: only this session can have written it
                told = (" state/config-changes.json was written during this session too, but only the upgrade "
                        "writes it, and no release came in under this session.")
            told_once(root, marker, "config.yaml", now,
                      "The gate definition (config.yaml) changed this session; restore it if this session changed "
                      "it.%s%s" % (told, STARTED_BEFORE), reasons, notes, stop)
    else:
        untold(root, marker, "config.yaml")
    ls = v.local_settings_sha(root)
    if marker.get("local_settings_sha") != ls:
        told_once(root, marker, ".claude/settings.local.json", ls,
                  "The deny rules or hooks in .claude/settings.local.json changed this session; restore them if this "
                  "session changed them.%s" % STARTED_BEFORE, reasons, notes, stop)
    else:
        untold(root, marker, ".claude/settings.local.json")


def check_local_brief(root: Path, marker: dict, reasons: List[str], notes: Optional[List[str]] = None,
                      stop: bool = True) -> None:
    """CLAUDE.local.md is gitignored, so check_protected cannot see it: while boundary.edit_brief
    is false, its hash must still be the one the session started with. A marker from before
    this check has no hash and is not judged. Told once per hash, like config.yaml (told_once)."""
    if "local_brief_sha" not in marker or v.edit_brief(root):
        return
    now = v.local_brief_sha(root)
    if marker.get("local_brief_sha") != now:
        told_once(root, marker, "CLAUDE.local.md", str(now),
                  "CLAUDE.local.md changed this session; it is the operator's brief and boundary.edit_brief is false "
                  "in config.yaml, so restore it if this session changed it.%s" % STARTED_BEFORE, reasons, notes, stop)
    else:
        untold(root, marker, "CLAUDE.local.md")


def check_distribution(root: Path, reasons: List[str]) -> None:
    """§6.1, §7.3: at Stop a modified core/ blocks — whoever changed it and
    whenever, since a modified reviewer cannot certify anything and the
    launcher and promote refuse until it is clean. core/ only (the spec's
    words); a home that is not a git checkout is silent here (plan 4
    Decision 11 — the launcher, promote and doctor all say so)."""
    sys.dont_write_bytecode = True   # a new core/__pycache__/distcheck.*.pyc would itself be protected dirt
    try:
        import distcheck as dc
    except ImportError:
        return
    state, detail = dc.distribution_state(root, paths=("core",))
    if state == "modified":
        reasons.append("Distribution code is modified (%s); restore it — reviews and promotes refuse until it is "
                       "clean." % detail)


def check_evidence(root: Path, marker: dict, reasons: List[str]) -> None:
    try:
        since = time.mktime(time.strptime(marker.get("started", "")[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        since = 0
    manifest = v.manifest_paths(root)
    # §4.9: gates.sh writes run.json FIRST, as a started record that names its window, and
    # manifests it in the same breath. While that record is manifested, says RUNNING and names a
    # window whose session is live, every file of that run — under state/evidence/<run-id>/ and
    # vault/evidence/<run-id>*.md, keyed on the run id across both trees — is another window's
    # gate run still in flight, not tampering. A RUNNING run whose window is stale (its session
    # is gone) never finished: it is named once, in those words, and its unmanifested files are
    # stray as before. An unleased run (lease null) gets no excuse — nothing can vouch for it.
    # A lease set that could not be READ vouches for nothing either way: no run is excused
    # and none is called never-finished (that sentence was false for a live window whose
    # liveness simply could not be read); the block names the unreadable file instead.
    ctx = v.lease_context(root, marker.get("session_id"))
    running_ok: set = set()
    never_finished: List[Tuple[str, str]] = []
    ev_state = root / "state" / "evidence"
    for rj in ([] if ctx.get("unreadable") else (ev_state.glob("*/run.json") if ev_state.is_dir() else [])):
        try:
            rec = json.loads(rj.read_text())
        except (OSError, ValueError):
            continue
        if (not isinstance(rec, dict) or rec.get("result") != "RUNNING"
                or str(rj.resolve()) not in manifest or not rec.get("lease")):
            continue
        rid, nn = str(rec.get("run_id") or rj.parent.name), str(rec["lease"])
        if ctx["liveness"].get(nn) in ("live", "quiet", "resumed"):
            running_ok.add(rid)
        else:
            never_finished.append((rid, nn))
    # v0.12.7 (PROP-035 §2): a run is said to the session or window its manifested run.json names, never to
    # another window — window 01's Stop kept saying "a gate run under window 04 never finished" over window 04's
    # abandoned run (2026-10-20, 20261020-205918-5450b3, superseded 28 s later), and a lens review another window's
    # run left unmanifested read here as evidence no gate run produced. Not while a lease file cannot be read:
    # then nothing vouches either way (above).
    sid = marker.get("session_id")
    elsewhere: dict = {}

    def theirs(rid: str) -> bool:
        if ctx.get("unreadable") or not rid:
            return False
        if rid not in elsewhere:
            rec = run_json(root, rid, manifest)
            elsewhere[rid] = rec is not None and not names_this_window(rec, sid, ctx.get("mine"))
        return elsewhere[rid]

    stray: List[str] = []
    for d in (ev_state, root / "vault" / "evidence"):
        if not d.is_dir():
            continue
        for p in d.rglob("*"):
            if not p.is_file() or p.name in MANIFEST_FILES:
                continue
            try:
                if p.stat().st_mtime < since:
                    continue
            except OSError:
                continue
            if any(rid and rid in str(p) for rid in running_ok):
                continue
            if str(p.resolve()) not in manifest:
                rid = p.relative_to(ev_state).parts[0] if d == ev_state else evidence_run_id(p.name)
                if theirs(rid):
                    continue
                stray.append(str(p))
    if stray:
        import leaselib as ll
        gone = ["a gate run under %s never finished; its session is gone." % ll.window_label(nn, ctx["leases"].get(nn))
                for rid, nn in never_finished if any(rid in s for s in stray)]
        if ctx.get("unreadable"):
            gone = ["No gate run can be excused as still in flight while a lease file cannot be read. " + ctx["unreadable"]]
        reasons.append("".join(g + " " for g in gone)
                       + "Evidence files exist that no gate run produced: %s. Evidence is written by core/gates.sh only.%s"
                       % (", ".join(sorted(stray)), RESTART))


def check_promotion(root: Path, marker: dict, reasons: List[str], notes: List[str],
                    restart_only: Optional[List[str]] = None) -> None:
    """PROP-019: the gate reads config target.branch, and FAILS CLOSED. The one benign
    skip — the target has no origin remote, so there is nothing shared to protect — says
    so in those words. Every other state in which the comparison cannot be made is a
    refusal that names what could not be determined, never a note that reads like
    "nothing to check"."""
    sid = marker.get("session_id")
    unrepairable = restart_only if restart_only is not None else []

    def refuse(sentence: str) -> None:
        # a comparison that cannot be made, which no action of the agent's repairs — a restart does (main: a
        # re-fired Stop carries these as notes). A refusal from the lease resolution that names a command
        # (claim, create, unset a variable) is the agent's to act on and never lands here.
        reasons.append(sentence)
        unrepairable.append(sentence)

    r = v.resolve_target(root, sid)
    if isinstance(r, v.Refused):
        if r.sentence.startswith(PENDING_PREFIX):
            # A session started before the upgrade finished (leaselib.NO_WINDOW_PENDING): no window can be made
            # for it, so nothing it does repairs this. Said once as a block, so the agent tells the operator;
            # after that a note — the same shape as the release's config.yaml change (check_config).
            b = load_boundary(root, sid)
            if b.get("upgrade_pending_told") == r.sentence:
                notes.append(r.sentence)
            else:
                reasons.append(r.sentence)
                b["upgrade_pending_told"] = r.sentence
                try:
                    save_boundary(root, sid, b)
                except OSError:
                    pass
            return
        if r.sentence.startswith(RESOLUTION_FAILED):
            refuse(COULD_NOT_EVALUATE + r.sentence)      # the seam did not answer or could not run
        else:
            reasons.append(COULD_NOT_EVALUATE + r.sentence)
        return
    if not isinstance(r, v.Resolved):
        return
    t = r.path
    hit = v.repo_relative(root, t)
    if hit is not None and str(hit[0]).startswith(str((root / "worktrees").resolve()) + "/"):
        notes.append("Promotion check does not apply in a lease worktree; trunk is guarded by promote.")
        return
    if "target_branch" not in marker:
        refuse("Promotion check could not evaluate: this session's marker predates the branch-aware gate "
               "(no target_branch recorded), so the comparison base is unknown.%s" % RESTART)
        return
    branch = marker.get("target_branch") or "main"
    base = marker.get("target_base") or ""
    err = marker.get("target_base_error") or ""
    if err == "no origin remote":
        notes.append("Promotion check does not apply: the target has no origin remote, so there is no shared "
                     "branch to protect. (Add a remote and restart the session to arm it.)")
        return
    if not base:
        refuse("Promotion check could not evaluate: %s. The gate refuses rather than skips when it cannot "
               "compare; fix config target.branch or fetch origin, then restart the session."
               % (err or "origin/%s was not recorded at session start" % branch))
        return
    code, out, gerr = v.run(["git", "-C", str(t), "rev-list", "--count", base + ".." + branch])
    if code != 0:
        refuse("Promotion check could not evaluate: git rev-list %s..%s failed in the target (%s). The gate "
               "refuses rather than skips when it cannot compare.%s"
               % (base[:12], branch, (gerr or "").strip().splitlines()[-1:] or ["no output"], RESTART))
        return
    if out.strip() not in ("", "0"):
        # confirm rewrites the marker's target_base after a push (§7.2 step 6), so a promoted merge is
        # not a trunk move here and an unrecorded one still is.
        reasons.append("Target %s moved this session (%s commit(s) past origin/%s at session start) — trunk is "
                       "reached only through promote; work on a window's branch.%s" % (branch, out.strip(), branch, RESTART))


PENDING_PREFIX = "This session started before the upgrade to "      # leaselib.NO_WINDOW_PENDING's opening
COULD_NOT_EVALUATE = "Promotion check could not evaluate: "
RESOLUTION_FAILED = "the lease resolution "                          # verifylib.resolve_target's two seam failures

NEVER_FIRED = ("you changed %s, which window %s%s had already changed, and the warning never fired "
               "(the pre-write hook timed out?). Message that window before you go on.")
# v0.12.7 (PROP-035 §3): a path still contested after this window merged the other window's branch says so — the
# merge is why no pre-write warning was ever written, not a hook that timed out.
MERGED_AGAIN = ("you changed %s again after merging window %s%s's branch (lease/%s), which had changed it. "
                "Message that window before you go on.")
GIT_SECS = 5        # each git call the backstop makes for a merge; the Stop hook's whole budget is larger


def _git_out(tree: Path, *args: str) -> Tuple[int, str]:
    code, out, _ = v.run(["git", "-C", str(tree)] + list(args), timeout=GIT_SECS)
    return code, out


def lease_tip(tree: Path, nn: str) -> Optional[str]:
    """lease/<NN>'s commit, read in this window's checkout of the repo (a worktree shares its repository's
    branches), or None when the branch is not there."""
    code, out = _git_out(tree, "rev-parse", "--verify", "-q", "refs/heads/lease/%s^{commit}" % nn)
    return out.strip() if code == 0 and out.strip() else None


def handed_over(tree: Path, trunk: Optional[str], tips: List[Optional[str]]) -> Optional[Tuple[str, set]]:
    """(the merged tip, the paths its commits changed) when one of `tips` — the other window's lease/<NN> as it is
    now, then as the previous Stop recorded it — is an ancestor of this window's HEAD: this window merged that
    branch. The paths are the ones that branch committed since it left trunk (origin/<trunk>, the ref promote
    and `unpromoted` judge by), so an uncommitted change in the other window — no merge can carry it — is never
    handed over. None when nothing was merged or anything cannot be told: then the backstop says what it said
    before."""
    if not trunk:
        return None
    for tip in [t for i, t in enumerate(tips) if t and t not in tips[:i]]:
        if _git_out(tree, "merge-base", "--is-ancestor", tip, "HEAD")[0] != 0:
            continue
        code, out = _git_out(tree, "diff", "--name-only", "--no-renames", "refs/remotes/origin/%s...%s" % (trunk, tip))
        if code != 0:
            return None
        return tip, set(ln for ln in out.splitlines() if ln)
    return None


def changed_after_merge(tree: Path, tip: str, rel: str) -> bool:
    """This window's copy of rel — committed after the merge, staged, or only in the working tree — is not what
    the merged tip had: changed again after the merge, and still contested. One `git diff` of the tip against the
    working tree; an answer git cannot give counts as changed, so the backstop blocks rather than passes."""
    code, _ = _git_out(tree, "diff", "--quiet", tip, "--", rel)
    return code != 0


def check_backstop(root: Path, sid: object, reasons: List[str], notes: List[str]) -> None:
    """§4.6: the Stop-time backstop for a pre-write warning that never fired. This
    session's own changed set is recomputed here (the one place git runs for the
    lease on the Stop side); each of its paths is looked up in the PREVIOUS Stop's
    `seen` snapshot of the other live windows' sets, keyed the way first_warning
    keys `warned` (the resolved absolute path). A path both windows changed in the
    same interval was in nobody's snapshot — not a false positive here; the
    pre-write hook catches it in whichever window touches it next. Then the
    snapshot is replaced with the other live leases' sets as they stand now. A set
    that cannot be recomputed (git failed in the worktree) keeps the last computed
    set, and the Refused sentence rides along as a note — never a silent pass.
    Likewise a snapshot that cannot be written: the reasons already found still
    block, one stderr line says why, and the previous snapshot stands for next
    time — the OSError climbing to main's outer except was a silent pass at
    exactly the event where a timeout is meant to block (Task 12 review).

    After an agreed merge (v0.12.7, PROP-035 §3, 2026-10-21): the operator had three windows ship as one version,
    one window merged the other two's branches, and every Stop after it listed all ~31 merged files as "the warning
    never fired (the pre-write hook timed out?)" — a `git merge` never passes the pre-write hook, so no `warned`
    entry was ever written and the block never cleared. Now, when lease/<NN>'s tip (as it is now, or as the
    previous Stop recorded it under `seen_tips`) is an ancestor of this window's HEAD, the paths that branch
    committed are handed over and skipped — unless this window changed the path again after the merge (a later
    commit, or its working tree), which is contested and blocks with words that name the merge. And a path whose
    block has been said is recorded under `warned`, the once-per-path rule the pre-write warning keeps, so a Stop
    never repeats what it already said: messaging the owner is the remedy, and it must not take another Stop."""
    import leaselib as ll
    ctx = v.lease_context(root, str(sid) if sid else None)
    if not ctx["leases"] or not ctx["mine"]:
        return
    mine_nn = ctx["mine"]
    lease = ctx["leases"][mine_nn]
    b = load_boundary(root, sid)
    previous = b.get("seen") or {}
    previous_tips = b.get("seen_tips") or {}
    warned = b.setdefault("warned", {})
    try:
        mine = ll.recompute_changed(root, mine_nn, lease)
    except ll.Refused as e:
        notes.append(str(e))
        mine = ctx["changed"].get(mine_nn) or {}
    wt = root / str(lease.get("worktree") or ("worktrees/%s" % mine_nn))
    trunks = lease.get("trunks") or {}
    merges: dict = {}

    def merge_of(nn: str, repo: str) -> Optional[Tuple[str, set]]:
        if (nn, repo) not in merges:
            tree = wt / repo
            recorded = (previous_tips.get(nn) or {}).get(repo) if isinstance(previous_tips.get(nn), dict) else None
            merges[(nn, repo)] = handed_over(tree, trunks.get(repo), [lease_tip(tree, nn), recorded])
        return merges[(nn, repo)]

    stamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    for repo, paths in mine.items():
        for rel in paths:
            key = str((wt / repo / rel).resolve())
            if key in warned:
                continue
            for nn, snap in sorted(previous.items()):
                if isinstance(snap, dict) and rel in (snap.get(repo) or {}):
                    other = ctx["leases"].get(nn) or {}
                    alias = (" (%s)" % other["alias"]) if other.get("alias") else ""
                    merged = merge_of(nn, repo)
                    if merged is not None and rel in merged[1]:
                        if not changed_after_merge(wt / repo, merged[0], rel):
                            continue                     # handed over by the merge: nothing contested
                        reasons.append(MERGED_AGAIN % (rel, nn, alias, nn))
                    else:
                        reasons.append(NEVER_FIRED % (rel, nn, alias))
                    warned[key] = stamp                  # said once; saved with the snapshot below
    b["seen"] = {nn: ctx["changed"].get(nn, {}) for nn in ctx["leases"]
                 if nn not in ("prime", mine_nn) and ctx["liveness"].get(nn) != "stale"
                 and not ctx["leases"][nn].get("released")}
    # the tips the snapshot's sets stood at, so a merge of that tip is recognised even once lease/<NN> moved on or
    # was deleted (a sweep removes a merged window's branch)
    b["seen_tips"] = {nn: {repo: t for repo in (sets or {}) for t in [lease_tip(wt / repo, nn)] if t}
                      for nn, sets in b["seen"].items() if isinstance(sets, dict) and sets}
    try:
        save_boundary(root, sid, b)
    except OSError as e:
        print(SNAPSHOT_FAILED % e, file=sys.stderr)


def deny(reason: str) -> dict:
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


def under(p: Path, base: Optional[Path]) -> bool:
    """p is base or lies under it (both resolved). base None is never matched."""
    if base is None:
        return False
    try:
        p.resolve().relative_to(base)
        return True
    except ValueError:
        return False


# --- PreToolUse(Edit|Write): the boundary warning (§4.6, §4.7, §4.10) ---------

def boundary_file(root: Path, sid: object) -> Path:
    """state/session-<sid>-boundary.json: {"warned": {"<abs path>": "<stamp>"}, "seen": {...}}.
    The session-<sid>- prefix puts it under session-start.py's 7-day prune (§4.10)."""
    return root / "state" / ("session-%s-boundary.json" % v._safe(sid))


def load_boundary(root: Path, sid: object) -> dict:
    try:
        d = json.loads(boundary_file(root, sid).read_text())
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def save_boundary(root: Path, sid: object, data: dict) -> None:
    p = boundary_file(root, sid)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(p.name + ".tmp")
    tmp.write_text(json.dumps(data))
    tmp.replace(p)


RECORD_FAILED = "daedalus: could not record the boundary warning in state/ (%s); the stop will repeat until it can be recorded."
SNAPSHOT_FAILED = ("daedalus: could not record the Stop snapshot in state/ (%s); "
                   "the backstop will use the previous snapshot next time.")


def first_warning(root: Path, sid: object, key: str) -> bool:
    """True when this path has not been warned this session — and it is recorded now, so the
    next attempt goes through with context. When the record cannot be written the answer is
    still True: a stop that repeats is the safe failure, and one line on stderr says why. The
    alternative — the OSError climbing to the hook's outer except — was a silent allow on every
    attempt (Task 11 review)."""
    b = load_boundary(root, sid)
    warned = b.setdefault("warned", {})
    if key in warned:
        return False
    warned[key] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        save_boundary(root, sid, b)
    except OSError as e:
        print(RECORD_FAILED % e, file=sys.stderr)
    return True


def repo_key_of(root: Path, tree: Path) -> str:
    """The changed-sidecar key for a tree repo_relative returned: the repo's
    path under target/ (\"thing\", \"thing/sub\") — the same key compute_changed
    writes, for a target checkout, a lease worktree or a promote scratch."""
    parts = tree.resolve().relative_to(root.resolve()).parts
    if parts[:1] == ("target",):
        return "/".join(parts[1:])
    if parts[:1] == ("worktrees",):
        return "/".join(parts[2:])
    if parts[:2] == ("state", "promote"):
        return "/".join(parts[3:])
    return "/".join(parts)


def cross_lease_holder(root: Path, ctx: dict, tree: Path, rel: str) -> Optional[Tuple[str, dict]]:
    """The other unswept, not-stale lease whose changed set holds rel in the
    same repo (§4.6): lowest number first. Reads only ctx — no lock, no git."""
    repo_key = repo_key_of(root, tree)
    for nn, d in sorted(ctx["leases"].items()):
        if nn in ("prime", ctx["mine"]) or d.get("released"):
            continue
        if ctx["liveness"].get(nn) == "stale":
            continue
        per_repo = ctx["changed"].get(nn, {}).get(repo_key)
        if isinstance(per_repo, dict) and rel in per_repo:
            return nn, d
    return None


FIRST_STOP = "This first attempt was stopped so you would read this before changing it. "


def warning_text(nn: str, lease: dict, rel: str, background: bool, ago: str) -> str:
    """The §4.6 warning, verbatim. Never a peer name (§4.1): the alias and the
    window number, and \"peer name from the board\" for the reader to look up."""
    alias = ("%s; " % lease["alias"]) if lease.get("alias") else ""
    first = ("The file %s has been changed in window %s (%speer name from the board; last seen %s) — it is in that "
             "window's changed set." % (rel, nn, alias, ago))
    if background:
        tail = ("That window is a background worker and may not answer a message. Tell the operator what you need "
                "from this file; if you then still need to change it here, try again and it will go through.")
    else:
        tail = ("Send that window a message saying what you need from this file and why, and wait for its answer. "
                "If it does not answer, tell the operator. If you then still need to change it here, try again and it will go through.")
    return first + "\n" + FIRST_STOP + tail


NOT_PRIME = ("Only the prime window commits the vault. You are window %s; the pen is held by window %s — "
             "ask it to commit, or take the pen with `core/lease.sh prime take` if the operator says so.")
# v0.12.6 (spec 2026-10-20 C): any window writes its own hot.md entries, and only through core/hot.py, under its lock.
HOT_DENY = ("hot.md changes only through core/hot.py, which edits one entry under a lock so no window's write is lost: "
            "`python3 core/hot.py add \"<topic>\" --next \"…\" --done-when \"…\"` for a new entry, or `update`, "
            "`remove` or `keep` with its topic (`python3 core/hot.py --help` lists every option).")
WORKTREES_ROOT = "worktrees/ holds every window's worktree; nothing writes or removes it as a whole. Your work goes in %s."
TRANSCRIPT_DENY = "the session transcript is the record of the operator's yes; nothing writes it."


def transcript_deny(root: Path, p: Path) -> Optional[str]:
    """Spec §7.4: an operand under memory.transcript_dir, or Claude Code's
    project directory for this home, is denied — an absolute-path check of its
    own, because verifylib.is_protected is root-relative and would never see a
    path outside the home. <dir>/memory/ (Claude Code's auto memory) is not the
    record (plan 4 Decision 4); the operand is resolved first, so a symlink
    there that points at a transcript is still denied."""
    import transcriptlib as tl
    rp = p.resolve()
    for d in tl.transcript_dirs(root):
        if under(rp, d) and not under(rp, d / "memory"):
            return TRANSCRIPT_DENY
    return None


def tree_deny(root: Path, ctx: dict, p: Path) -> Optional[str]:
    """§3.1, §4.2, §4.6 judged from the PATH alone, before repo_relative — which is None for
    target/ itself, worktrees/ itself and worktrees/<NN> itself, exactly the operands `rm -rf`
    names (Task 11 review). The prime's checkout is target/ and everything under it, for every
    window; another window's worktree is worktrees/<NN> and everything under it, for clone and
    prime alike — a deny every time, never the stop-once warning; a released window's own
    worktree is closed. The repository under the operand, when there is one, only sharpens the
    sentence. None means the path is nobody else's."""
    rroot = root.resolve()
    hit = v.repo_relative(root, p)
    repo_key = repo_key_of(root, hit[0]) if hit is not None else ""
    mine = ctx["mine"]
    if mine and repo_key:
        mine_wt = "worktrees/%s/%s" % (mine, repo_key)
    elif mine:
        mine_wt = "worktrees/%s" % mine
    else:
        mine_wt = "a numbered window's worktree"
    if under(p, rroot / "target"):
        shown = (hit[0] if hit is not None else p).resolve().relative_to(rroot).as_posix()
        return ("This is the prime's checkout (%s). Your work goes in %s. If you meant to change trunk, that is what "
                "`promote` is for." % (shown, mine_wt))
    wts = rroot / "worktrees"
    if under(p, wts):
        parts = p.resolve().relative_to(wts).parts
        if not parts:
            return WORKTREES_ROOT % mine_wt
        wt_nn = parts[0]
        if mine and wt_nn != mine:
            theirs = ("worktrees/%s/%s" % (wt_nn, repo_key)) if repo_key else ("worktrees/%s" % wt_nn)
            return ("This is window %s's worktree (%s). Your work goes in %s. If you need something from that "
                    "window's tree, send it a message." % (wt_nn, theirs, mine_wt))
        if (ctx["leases"].get(wt_nn) or {}).get("released"):
            return "this window is released; its worktree is closed"
    return None


HOOKS_DENY = ("%s is under .git/hooks/; those hooks guard trunk, and only Daedalus's installer (core/prepush.py) "
              "writes them.")
GITCONFIG_DENY = ("%s is git's configuration; it is changed with `git config`, never written directly — a written "
                  "file can switch off the pre-push hook that guards trunk.")


def git_gate_deny(p: Path) -> Optional[str]:
    """Plan 4 Task 13 review: git's own gate, for both legs — a file under any `.git/hooks/`, a
    repo's `.git/config` (or `config.worktree`), and the global and system git configuration
    (~/.gitconfig, $XDG_CONFIG_HOME/git/config or ~/.config/git/config, /etc/gitconfig), each
    of which can set core.hooksPath or include a file that does."""
    rp = p.resolve()
    parts = rp.parts
    for i in range(len(parts) - 1):
        if parts[i] == ".git" and parts[i + 1] == "hooks":
            return HOOKS_DENY % rp
        if parts[i] == ".git" and parts[-1] in ("config", "config.worktree") and (
                i + 2 == len(parts) or (parts[i + 1] == "worktrees" and i + 4 == len(parts))):
            return GITCONFIG_DENY % rp
    home = Path(os.path.expanduser("~")).resolve()
    xdg = Path(os.environ.get("XDG_CONFIG_HOME") or (home / ".config")).expanduser().resolve()
    if rp in (home / ".gitconfig", xdg / "git" / "config", home / ".config" / "git" / "config", Path("/etc/gitconfig")):
        return GITCONFIG_DENY % rp
    return None


BRIEF_DENY = ("CLAUDE.md is distribution code; local brief text goes in CLAUDE.local.md (boundary.edit_brief: true "
              "lets Daedalus write it).")
LOCAL_BRIEF_DENY = "CLAUDE.local.md is the operator's brief; boundary.edit_brief is false in config.yaml."


def brief_deny(root: Path, p: Path) -> Optional[str]:
    """The home's two briefs (update design §4.4): CLAUDE.md is the release's, denied always;
    CLAUDE.local.md is the deployment's, denied unless config.yaml boundary.edit_brief is true.
    Matched without case, as the default macOS file system opens either spelling."""
    try:
        rel = p.resolve().relative_to(root.resolve()).as_posix().lower()
    except ValueError:
        return None
    if rel == v.BRIEF.lower():
        return BRIEF_DENY
    if rel == v.LOCAL_BRIEF.lower() and not v.edit_brief(root):
        return LOCAL_BRIEF_DENY
    return None


def write_check(root: Path, ctx: dict, p: Path, sid: object, refused: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """The lease-era checks for one resolved write path — the Edit/Write leg and every Bash
    write operand run this same function. In order: the session transcript (§7.4, any
    session, leases or none); git's own gate; the two briefs (brief_deny, any session, leases
    or none — a session with no leases is exactly the pending-upgrade state); vault/hot.md for every
    session (core/hot.py is its one write path, v0.12.6); fail closed under target/ and worktrees/
    for a session that cannot be bound or a lease file that cannot be read (§4.4 —
    judged BEFORE the empty-leases return, which is what a read failure leaves; `refused` is
    the caller's, since the guard's may also come from the bash seam); the trees (tree_deny);
    the stop-once cross-lease warning (§4.6).
    Returns (deny reason, context): a deny; or context alone for a cross-lease path already
    warned this session; or (None, None)."""
    reason = transcript_deny(root, p) or git_gate_deny(p) or brief_deny(root, p)
    if reason:
        return reason, None
    rroot = root.resolve()
    try:
        rel_lower = p.resolve().relative_to(rroot).as_posix().lower()
    except ValueError:
        rel_lower = ""
    if rel_lower == "vault/hot.md":     # without case, as brief_deny: the default macOS file system opens either spelling
        # every session, the pen's holder too, leases or none: core/hot.py is the one write path
        return HOT_DENY, None
    if refused and (under(p, rroot / "target") or under(p, rroot / "worktrees")):
        return refused, None
    if not ctx["leases"]:
        return None, None
    reason = tree_deny(root, ctx, p)
    if reason:
        return reason, None
    hit = v.repo_relative(root, p)
    if hit is None:
        return None, None
    tree, rel = hit
    holder = cross_lease_holder(root, ctx, tree, rel)
    if holder is None:
        return None, None
    import leaselib as ll          # already imported by lease_context once leases exist
    nn, lease = holder
    entries = ll.registry_by_session(str(lease.get("session_id"))) if lease.get("session_id") else []
    background = bool(lease.get("spawned")) or any(e.get("kind") == "bg" for e in entries)
    text = warning_text(nn, lease, rel, background, ll._ago(ll.seen_mtime(root, nn), time.time()))
    if first_warning(root, sid, str(p.resolve())):
        return text, None
    return None, text.replace(FIRST_STOP, "")


def _pre(decision: Optional[str], text: str) -> dict:
    """A PreToolUse output: a deny whose reason IS the text (the reason is shown
    to Claude) and the same text as context; or context alone (no decision)."""
    out = {"hookEventName": "PreToolUse", "additionalContext": text}
    if decision:
        out["permissionDecision"] = decision
        out["permissionDecisionReason"] = text
    return {"hookSpecificOutput": out}


def check_pretooluse(root: Path, payload: dict) -> Optional[dict]:
    """PreToolUse(Edit|Write|NotebookEdit): the transcript denial first (§7.4 — no lease state),
    then one read of the leases (lease_context, §4.6 budget rule — no bash seam,
    no git), then write_check on the path. None means nothing to say."""
    if payload.get("tool_name") not in ("Edit", "Write", "NotebookEdit"):
        return None
    sid = v.export_session(payload)
    ti = payload.get("tool_input") or {}
    fp = str(ti.get("file_path") or ti.get("notebook_path") or "")   # NotebookEdit names notebook_path
    if not fp or not os.path.isabs(fp):
        return None
    op = Path(fp).resolve()
    # The transcript denial needs no lease state, so it is judged BEFORE the lease read:
    # a lock that cannot be opened, or stays busy past the hook's timeout, must not make
    # it fail open (plan 4 Task 2 review). write_check repeats it for the Bash leg.
    reason = transcript_deny(root, op)
    if reason:
        return _pre("deny", reason)
    ctx = v.lease_context(root, sid)
    reason, context = write_check(root, ctx, op, sid, ctx["refused"])
    if reason:
        return _pre("deny", reason)
    if context:
        return _pre(None, context)
    return None


def main() -> int:
    root = v.ROOT
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    event = payload.get("hook_event_name", "Stop")
    if event == "PreToolUse":
        try:
            out = check_pretooluse(root, payload)
        except Exception:
            return 0
        if out is not None:
            v.emit(out)
        return 0
    sid = v.export_session(payload)                  # every Python hook: the payload's session_id (§4.4 step 1)
    visitor = bool(os.environ.get("DIRECT_CALL_ID"))  # §4.8: the one signal that makes a visitor
    marker = v.read_marker(root, sid)
    reasons: List[str] = []
    notes: List[str] = []
    restart_only: List[str] = []       # reasons in `reasons` that only a restart repairs (check_promotion)
    try:
        if marker is None:
            marker = {"session_id": sid, "protected_status": [], "config_sha": v.sha256_file(root / "config.yaml"),
                      "local_settings_sha": v.local_settings_sha(root), "local_brief_sha": v.local_brief_sha(root),
                      "started": "",
                      "target_branch": v.target_branch(root), "target_base": "",
                      "target_base_error": "session-start hook did not run, so origin/<branch> was never recorded"}
            notes.append("The session-start hook did not run; boundary checks compare against the current state.%s" % RESTART)
            # With no snapshot, any protected dirt counts.
        check_protected(root, marker, reasons)
        check_config(root, marker, reasons, notes, event == "Stop")
        check_local_brief(root, marker, reasons, notes, event == "Stop")
        check_evidence(root, marker, reasons)
        if event == "Stop":
            if not visitor:
                check_backstop(root, sid, reasons, notes)
            check_distribution(root, reasons)
            check_promotion(root, marker, reasons, notes, restart_only)
    except Exception:
        return 0
    active = bool(payload.get("stop_hook_active"))
    if event == "Stop" and active and restart_only:
        # Claude Code re-fires Stop after a blocked one with stop_hook_active true. A promotion check that could
        # not evaluate for a reason only a restart repairs (a missing base, a tree not known, a marker from
        # before the gate) blocked that Stop again and re-prompted the agent without end (another deployment,
        # 2026-10-13: 15+ times in one session). Once said, such a reason rides along as a note. Everything
        # the agent can repair — protected files, config, evidence, a refusal that names a command — still blocks.
        notes.extend(r for r in reasons if r in restart_only)
        reasons = [r for r in reasons if r not in restart_only]
    if visitor and reasons and event == "Stop":
        # §8.5: a direct-call session is read-only and cannot have caused any of this — say
        # it, never block (a blocked Stop in a -p session spins until max_turns). Stop only:
        # on PostToolUse(Bash) exit 2 just feeds the text back after a command that already
        # ran, and notes are not printed there — a downgrade would drop the reason entirely.
        notes.extend("(visitor, not blocking) " + r for r in reasons)
        reasons = []
    if event == "Stop":
        # No Stop hook may lock a session (verifylib.stop_once): a reason blocks once a turn — once a session for a
        # file read at session start — and is a note after that, so a reason only the operator can resolve hands
        # them the turn instead of re-prompting the agent until Claude Code gives up.
        reasons, later = v.stop_once(root, sid, "boundary", reasons, active, SESSION_KEYS)
        notes = later + notes
        if reasons:
            reasons.append(v.WAY_BACK)
    if reasons:
        v.block("\n".join(reasons + notes))
    if notes and event == "Stop":
        # hooks.md documents Stop's JSON output as a top-level `decision`
        # field only — hookSpecificOutput.additionalContext is not honored
        # for Stop (that field is UserPromptSubmit-specific). Printed as
        # plain stdout text instead; nothing consumes it structurally, but
        # nothing breaks either.
        print("\n".join(notes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
