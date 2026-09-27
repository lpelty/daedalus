#!/usr/bin/env python3
"""PostToolUse(Bash) + Stop hook: the boundary that command phrasing cannot
route around.

Four checks against the session-start marker: protected files modified
beyond the operator's snapshot; the gate definition's hash; evidence files
in this session's window that no run produced; and (Stop only) target main
having moved past where origin/<config target.branch> stood at session start (PROP-019: fail-closed). On Stop, exit 2
ends nothing until fixed; on PostToolUse, exit 2 is immediate feedback — the
command already ran.

Since v0.7.0 the same file is also wired on PreToolUse(Edit|Write) — the
boundary warning (spec §4.6): one locked read of the leases, then a path in
another live window's changed set is denied ONCE per session (the deny
reason is the warning; recorded under `warned` in
state/session-<sid>-boundary.json, pruned with the marker, §4.10) and let
through with the warning as context on every later attempt; the prime's
checkout target/<repo> is denied for every window; a released lease's
worktree is closed; another window's worktree is denied every time (§3.1);
vault/hot.md is the prime's alone (§4.7). A session that cannot be bound
while lease files exist — or a lease file that cannot be read — fails
CLOSED under target/, worktrees/ and hot.md (§4.4). Its two helpers, cross_lease_holder and warning_text, are
imported by guard-bash.py for Bash write operands.
"""
from __future__ import annotations

import json
import os
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


def _sanctioned_evidence(root: Path, rel: str, manifest: set) -> bool:
    """A vault/evidence path new this session that gates.sh actually
    recorded is the stage's own output, not tampering (PROP-017 finding 1):
    it must be listed in the manifest AND have the state-side run record
    (the vault-side frontmatter fallback would let a hand-written file
    vouch for itself). `.manifest` is rewritten by every run; its entries
    are judged here and by check_evidence, so the file itself is excused."""
    name = rel.rsplit("/", 1)[-1]
    if name == ".manifest":
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
            if path == "vault/evidence/.manifest":
                continue   # rewritten by every run; entries judged above/check_evidence
            bad.append(path)
    if bad:
        reasons.append("Protected files changed this session: %s. Revert these — Daedalus's own code changes by proposal, not by edit.%s"
                       % (", ".join(sorted(bad)), RESTART))


def check_config(root: Path, marker: dict, reasons: List[str]) -> None:
    if marker.get("config_sha") != v.sha256_file(root / "config.yaml"):
        reasons.append("The gate definition (config.yaml) changed this session; restore it.%s" % RESTART)
    if marker.get("local_settings_sha") != v.local_settings_sha(root):
        reasons.append("The deny rules or hooks in .claude/settings.local.json changed this session; restore them.%s" % RESTART)


def check_evidence(root: Path, marker: dict, reasons: List[str]) -> None:
    try:
        since = time.mktime(time.strptime(marker.get("started", "")[:19], "%Y-%m-%dT%H:%M:%S"))
    except (ValueError, TypeError):
        since = 0
    manifest = v.manifest_paths(root)
    stray: List[str] = []
    for d in (root / "state" / "evidence", root / "vault" / "evidence"):
        if not d.is_dir():
            continue
        for p in d.rglob("*"):
            if not p.is_file() or p.name == ".manifest":
                continue
            try:
                if p.stat().st_mtime < since:
                    continue
            except OSError:
                continue
            if str(p.resolve()) not in manifest:
                stray.append(str(p))
    if stray:
        reasons.append("Evidence files exist that no gate run produced: %s. Evidence is written by core/gates.sh only.%s" % (", ".join(sorted(stray)), RESTART))


def check_promotion(root: Path, marker: dict, reasons: List[str], notes: List[str]) -> None:
    """PROP-019: the gate reads config target.branch, and FAILS CLOSED. The one benign
    skip — the target has no origin remote, so there is nothing shared to protect — says
    so in those words. Every other state in which the comparison cannot be made is a
    refusal that names what could not be determined, never a note that reads like
    "nothing to check"."""
    sid = marker.get("session_id")
    r = v.resolve_target(root, sid)
    if isinstance(r, v.Refused):
        reasons.append("Promotion check could not evaluate: %s" % r.sentence)
        return
    if not isinstance(r, v.Resolved):
        return
    t = r.path
    hit = v.repo_relative(root, t)
    if hit is not None and str(hit[0]).startswith(str((root / "worktrees").resolve()) + "/"):
        notes.append("Promotion check does not apply in a lease worktree; trunk is guarded by promote.")
        return
    if "target_branch" not in marker:
        reasons.append("Promotion check could not evaluate: this session's marker predates the branch-aware gate "
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
        reasons.append("Promotion check could not evaluate: %s. The gate refuses rather than skips when it cannot "
                       "compare; fix config target.branch or fetch origin, then restart the session."
                       % (err or "origin/%s was not recorded at session start" % branch))
        return
    code, out, gerr = v.run(["git", "-C", str(t), "rev-list", "--count", base + ".." + branch])
    if code != 0:
        reasons.append("Promotion check could not evaluate: git rev-list %s..%s failed in the target (%s). The gate "
                       "refuses rather than skips when it cannot compare.%s"
                       % (base[:12], branch, (gerr or "").strip().splitlines()[-1:] or ["no output"], RESTART))
        return
    if out.strip() not in ("", "0"):
        reasons.append("Target %s moved this session (%s commit(s) past origin/%s at session start) — the operator "
                       "merges; work on a branch.%s" % (branch, out.strip(), branch, RESTART))


def deny(reason: str) -> dict:
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}}


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


def _pre(decision: Optional[str], text: str) -> dict:
    """A PreToolUse output: a deny whose reason IS the text (the reason is shown
    to Claude) and the same text as context; or context alone (no decision)."""
    out = {"hookEventName": "PreToolUse", "additionalContext": text}
    if decision:
        out["permissionDecision"] = decision
        out["permissionDecisionReason"] = text
    return {"hookSpecificOutput": out}


def check_pretooluse(root: Path, payload: dict) -> Optional[dict]:
    """PreToolUse(Edit|Write): one read of the leases (lease_context, §4.6
    budget rule — no bash seam, no git), then the checks in this order: fail
    closed under target/, worktrees/ and hot.md for a session that cannot be
    bound or a lease file that cannot be read (§4.4, ctx['refused'] — judged
    before the empty-leases return, which is what a read failure leaves);
    vault/hot.md for a non-prime (§4.7); the prime's checkout target/<repo>
    for every window; another window's worktree (§3.1); a released lease's
    worktree; and the stop-once cross-lease warning (§4.6). None means
    nothing to say."""
    if payload.get("tool_name") not in ("Edit", "Write"):
        return None
    sid = v.export_session(payload)
    fp = str((payload.get("tool_input") or {}).get("file_path") or "")
    if not fp or not os.path.isabs(fp):
        return None
    op = Path(fp).resolve()
    ctx = v.lease_context(root, sid)
    rroot = root.resolve()
    under_target = str(op).startswith(str(rroot / "target") + "/")
    under_wt = str(op).startswith(str(rroot / "worktrees") + "/")
    # The refusal is judged BEFORE the empty-leases return: a lease file that cannot be read
    # comes back as refused with an EMPTY leases dict, and testing `leases` first turned that
    # refusal into silence (Task 10 review). hot.md is included — an unreadable lease set means
    # the pen-holder is unknown too.
    if ctx["refused"] and (under_target or under_wt or op == rroot / "vault" / "hot.md"):
        return _pre("deny", ctx["refused"])
    if not ctx["leases"]:
        return None
    if op == rroot / "vault" / "hot.md" and not ctx["prime"]:
        return _pre("deny", "Only the prime window commits the vault and writes hot.md. You are window %s; the pen is held by "
                            "window %s — ask it to commit, or take the pen with `core/lease.sh prime take` if the operator says so."
                    % (ctx["mine"] or "none", ctx["prime_nn"] or "none"))
    hit = v.repo_relative(root, op)
    if hit is None:
        return None
    tree, rel = hit
    repo_key = repo_key_of(root, tree)
    if under_target:
        mine_wt = ("worktrees/%s/%s" % (ctx["mine"], repo_key)) if ctx["mine"] else "a numbered window's worktree"
        return _pre("deny", "This is the prime's checkout (%s). Your work goes in %s. If you meant to change trunk, that is what "
                            "`promote` is for." % (tree.resolve().relative_to(rroot).as_posix(), mine_wt))
    if under_wt:
        wt_nn = tree.resolve().relative_to(rroot / "worktrees").parts[0]
        if ctx["mine"] and wt_nn != ctx["mine"]:
            # §3.1: a clone never writes any other lease's worktree, the prime never writes
            # another lease's worktree — a deny every time, never the stop-once warning.
            return _pre("deny", "This is window %s's worktree (worktrees/%s/%s). Your work goes in worktrees/%s/%s. If you need "
                                "something from that window's tree, send it a message."
                        % (wt_nn, wt_nn, repo_key, ctx["mine"], repo_key))
        if (ctx["leases"].get(wt_nn) or {}).get("released"):
            return _pre("deny", "this window is released; its worktree is closed")
    holder = cross_lease_holder(root, ctx, tree, rel)
    if holder is None:
        return None
    import leaselib as ll          # already imported by lease_context once leases exist
    nn, lease = holder
    entries = ll.registry_by_session(str(lease.get("session_id"))) if lease.get("session_id") else []
    background = bool(lease.get("spawned")) or any(e.get("kind") == "bg" for e in entries)
    text = warning_text(nn, lease, rel, background, ll._ago(ll.seen_mtime(root, nn), time.time()))
    b = load_boundary(root, sid)
    warned = b.setdefault("warned", {})
    key = str(op)
    if key in warned:
        return _pre(None, text.replace(FIRST_STOP, ""))
    warned[key] = time.strftime("%Y-%m-%dT%H:%M:%S")
    save_boundary(root, sid, b)
    return _pre("deny", text)


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
    marker = v.read_marker(root, sid)
    reasons: List[str] = []
    notes: List[str] = []
    try:
        if marker is None:
            marker = {"session_id": sid, "protected_status": [], "config_sha": v.sha256_file(root / "config.yaml"),
                      "local_settings_sha": v.local_settings_sha(root), "started": "",
                      "target_branch": v.target_branch(root), "target_base": "",
                      "target_base_error": "session-start hook did not run, so origin/<branch> was never recorded"}
            notes.append("The session-start hook did not run; boundary checks compare against the current state.%s" % RESTART)
            # With no snapshot, any protected dirt counts.
        check_protected(root, marker, reasons)
        check_config(root, marker, reasons)
        check_evidence(root, marker, reasons)
        if event == "Stop":
            check_promotion(root, marker, reasons, notes)
    except Exception:
        return 0
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
