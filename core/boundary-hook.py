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
vault/hot.md is the prime's alone (§4.7). A session that cannot be bound
while lease files exist — or a lease file that cannot be read — fails
CLOSED under target/, worktrees/ and hot.md (§4.4). The whole check is
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
`warned` entry blocks with "the warning never fired". A visitor — a
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


def _sanctioned_evidence(root: Path, rel: str, manifest: set) -> bool:
    """A vault/evidence path new this session that gates.sh actually
    recorded is the stage's own output, not tampering (PROP-017 finding 1):
    it must be listed in the manifest AND have the state-side run record
    (the vault-side frontmatter fallback would let a hand-written file
    vouch for itself). `.manifest` is rewritten by every run and
    `.manifest.lock` is the lock every append takes (§4.9); their entries
    are judged here and by check_evidence, so the files themselves are excused."""
    name = rel.rsplit("/", 1)[-1]
    if name in MANIFEST_FILES:
        return True
    if str((root / rel).resolve()) not in manifest:
        return False
    rid = name[:-3] if name.endswith(".md") else ""
    # The refuter's verdict, <run-id>-review.md, is refute.sh's output for
    # that run and stands on the run's own record: strip the suffix so it
    # is judged by the same run.json. It was not, and with the refuter on
    # by default every STANDS verdict in a vault the parent git can see
    # blocked the Stop hook as protected dirt.
    if rid.endswith("-review"):
        rid = rid[:-len("-review")]
    rec = v.run_record(root, rid)
    return bool(rec) and rec.get("source") == "state"


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
            if path in ["vault/evidence/" + n for n in MANIFEST_FILES]:
                continue   # rewritten/locked by every run; entries judged above/check_evidence
            bad.append(path)
    if bad:
        reasons.append("Protected files changed this session: %s. Revert these — Daedalus's own code changes by proposal, not by edit.%s"
                       % (", ".join(sorted(bad)), RESTART))


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


def check_config(root: Path, marker: dict, reasons: List[str], notes: Optional[List[str]] = None) -> None:
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
            reasons.append("The gate definition (config.yaml) changed this session; restore it.%s%s" % (told, RESTART))
    if marker.get("local_settings_sha") != v.local_settings_sha(root):
        reasons.append("The deny rules or hooks in .claude/settings.local.json changed this session; restore them.%s" % RESTART)


def check_local_brief(root: Path, marker: dict, reasons: List[str]) -> None:
    """CLAUDE.local.md is gitignored, so check_protected cannot see it: while boundary.edit_brief
    is false, its hash must still be the one the session started with. A marker from before
    this check has no hash and is not judged."""
    if "local_brief_sha" not in marker or v.edit_brief(root):
        return
    if marker.get("local_brief_sha") != v.local_brief_sha(root):
        reasons.append("CLAUDE.local.md changed this session; it is the operator's brief and boundary.edit_brief is "
                       "false in config.yaml, so restore it.%s" % RESTART)


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
    exactly the event where a timeout is meant to block (Task 12 review)."""
    import leaselib as ll
    ctx = v.lease_context(root, str(sid) if sid else None)
    if not ctx["leases"] or not ctx["mine"]:
        return
    mine_nn = ctx["mine"]
    lease = ctx["leases"][mine_nn]
    b = load_boundary(root, sid)
    previous = b.get("seen") or {}
    warned = b.get("warned") or {}
    try:
        mine = ll.recompute_changed(root, mine_nn, lease)
    except ll.Refused as e:
        notes.append(str(e))
        mine = ctx["changed"].get(mine_nn) or {}
    wt = root / str(lease.get("worktree") or ("worktrees/%s" % mine_nn))
    for repo, paths in mine.items():
        for rel in paths:
            key = str((wt / repo / rel).resolve())
            if key in warned:
                continue
            for nn, snap in sorted(previous.items()):
                if isinstance(snap, dict) and rel in (snap.get(repo) or {}):
                    other = ctx["leases"].get(nn) or {}
                    alias = (" (%s)" % other["alias"]) if other.get("alias") else ""
                    reasons.append(NEVER_FIRED % (rel, nn, alias))
    b["seen"] = {nn: ctx["changed"].get(nn, {}) for nn in ctx["leases"]
                 if nn not in ("prime", mine_nn) and ctx["liveness"].get(nn) != "stale"
                 and not ctx["leases"][nn].get("released")}
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


NOT_PRIME = ("Only the prime window commits the vault and writes hot.md. You are window %s; the pen is held by window %s — "
             "ask it to commit, or take the pen with `core/lease.sh prime take` if the operator says so.")
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
    or none — a session with no leases is exactly the pending-upgrade state); fail closed under target/, worktrees/ and
    hot.md for a session that cannot be bound or a lease file that cannot be read (§4.4 —
    judged BEFORE the empty-leases return, which is what a read failure leaves; `refused` is
    the caller's, since the guard's may also come from the bash seam); vault/hot.md for a
    non-prime (§4.7); the trees (tree_deny); the stop-once cross-lease warning (§4.6).
    Returns (deny reason, context): a deny; or context alone for a cross-lease path already
    warned this session; or (None, None)."""
    reason = transcript_deny(root, p) or git_gate_deny(p) or brief_deny(root, p)
    if reason:
        return reason, None
    rroot = root.resolve()
    is_hot = p == rroot / "vault" / "hot.md"
    if refused and (under(p, rroot / "target") or under(p, rroot / "worktrees") or is_hot):
        return refused, None
    if not ctx["leases"]:
        return None, None
    if is_hot and not ctx["prime"]:
        return NOT_PRIME % (ctx["mine"] or "none", ctx["prime_nn"] or "none"), None
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
        check_config(root, marker, reasons, notes)
        check_local_brief(root, marker, reasons)
        check_evidence(root, marker, reasons)
        if event == "Stop":
            if not visitor:
                check_backstop(root, sid, reasons, notes)
            check_distribution(root, reasons)
            check_promotion(root, marker, reasons, notes, restart_only)
    except Exception:
        return 0
    if event == "Stop" and payload.get("stop_hook_active") and restart_only:
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
