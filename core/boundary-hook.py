#!/usr/bin/env python3
"""PostToolUse(Bash) + Stop hook: the boundary that command phrasing cannot
route around.

Four checks against the session-start marker: protected files modified
beyond the operator's snapshot; the gate definition's hash; evidence files
in this session's window that no run produced; and (Stop only) target main
having moved past where origin/main stood at session start. On Stop, exit 2
ends nothing until fixed; on PostToolUse, exit 2 is immediate feedback — the
command already ran.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import List

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
    t = v.target_root(root)
    if t is None:
        return
    base = marker.get("target_origin_main") or ""
    if not base:
        notes.append("Promotion check skipped: the target has no origin/main recorded (no origin remote, or never fetched).")
        return
    code, out, _ = v.run(["git", "-C", str(t), "rev-list", "--count", base + "..main"])
    if code != 0:
        notes.append("Promotion check skipped: could not compare main with the recorded origin/main.")
        return
    if out.strip() not in ("", "0"):
        reasons.append("Target main moved this session (%s commit(s) past origin/main at session start) — the operator merges; work on a branch.%s" % (out.strip(), RESTART))


def main() -> int:
    root = v.ROOT
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    event = payload.get("hook_event_name", "Stop")
    marker = v.read_marker(root, payload.get("session_id"))
    reasons: List[str] = []
    notes: List[str] = []
    try:
        if marker is None:
            marker = {"protected_status": [], "config_sha": v.sha256_file(root / "config.yaml"),
                      "local_settings_sha": v.local_settings_sha(root), "started": "", "target_origin_main": ""}
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
