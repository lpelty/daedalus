#!/usr/bin/env python3
"""Stop hook: a completion claim stands only on evidence for this tree.

A claim is a vault document of Daedalus's, changed this session, carrying
`status: IMPLEMENTED` or `kind: completion`, created after the deployment's
first evidence. Each must cite an `evidence-run:` whose record says PASS,
whose config hash matches the session's, and whose fingerprint matches the
target now. Never exits early on `stop_hook_active`. Fails closed only when a
claim exists and the evidence cannot be read. `--doctor` runs the same check
over the whole vault and prints one line per problem.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402


def problems(root: Path, since_sha: Optional[str], since_time: Optional[float], marker: Optional[dict], live: bool) -> List[str]:
    out: List[str] = []
    found = v.claims(root, since_sha, since_time)
    if not found:
        return out
    fp_now = v.fingerprint(root) if live else None
    for p, fm in found:
        rid = fm.get("evidence-run", "")
        if not rid:
            out.append("%s claims IMPLEMENTED with no evidence-run: run core/gates.sh and cite the run-id, or change the status." % p)
            continue
        rec = v.run_record(root, rid)
        if rec is None:
            out.append("%s cites evidence-run %s, which does not exist." % (p, rid))
            continue
        if rec.get("result") != "PASS":
            logs = [g.get("log") for g in rec.get("gates", []) if g.get("exit") not in (0, None)]
            out.append("%s cites evidence-run %s, whose result is %s%s." % (p, rid, rec.get("result"), (" — see " + logs[0]) if logs else ""))
            continue
        if not live:
            continue
        expected_cfg = v.sha256_file(root / "config.yaml")
        if rec.get("config_sha") != expected_cfg:
            out.append("%s cites evidence-run %s, but the gate definition (config.yaml) changed this session; re-run core/gates.sh — if the operator changed it, restart the session (it re-snapshots)." % (p, rid))
            continue
        if fp_now == "null":
            out.append("%s: the target's fingerprint cannot be computed right now (index.lock, or not a repository); clear it and re-run core/gates.sh." % p)
            continue
        if rec.get("fingerprint") != fp_now:
            out.append("%s cites evidence-run %s, which is for a different tree; re-run core/gates.sh." % (p, rid))
    return out


def main(argv: List[str]) -> int:
    root = v.ROOT
    if len(argv) > 1 and argv[1] == "--doctor":
        for line in problems(root, None, None, None, live=False):
            print(line)
        return 0
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    marker = v.read_marker(root, payload.get("session_id"))
    since_sha = marker.get("vault_head") if marker else None
    since_time = None if marker else v.transcript_first_ts(payload.get("transcript_path", ""))
    try:
        bad = problems(root, since_sha, since_time, marker, live=True)
    except Exception as e:
        # Fail closed only if a claim exists at all; otherwise stay out of the way.
        try:
            if v.claims(root, since_sha, since_time):
                v.block("verify-hook could not read the evidence: %s" % e)
        except Exception:
            pass
        return 0
    if bad:
        note = "" if marker else "\n(the session-start hook did not run; the claim window is approximate)"
        v.block("\n".join(bad) + note)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
