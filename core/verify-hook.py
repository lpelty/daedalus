#!/usr/bin/env python3
"""Stop hook: a completion claim stands only on evidence for this tree.

A claim is a vault document of Daedalus's, changed this session, carrying
`status: IMPLEMENTED` or `kind: completion`, created after the deployment's
first evidence. Each must cite an `evidence-run:` whose record says PASS,
whose config hash matches the session's, and whose fingerprint matches the
target now. A promotion's gate run (tree promote-scratch) is promote's
evidence; it stands behind a window's claim only once that promotion was
confirmed and pushed for the claim's own window, while lease/NN is still at the
promoted tip and worktrees/NN is clean (no fingerprint compare; the config
check stays). Fails closed only when a claim exists and the evidence cannot
be read.

No Stop hook may lock a session (v0.12.4, verifylib.stop_once): a reason
blocks once a turn. When Claude Code fires Stop again after a block
(`stop_hook_active` true), the same reason is a note and the turn ends — a
claim the agent cannot settle alone hands the operator the turn instead of
re-prompting until Claude Code overrides the hook. The next turn's Stop
blocks on it once more, so an unsupported claim is never let through
silently. vault-commit.sh refuses a claim with no evidence-run, one citing a
run that does not exist, or one whose run did not PASS (verifylib
--vault-claims); the config and fingerprint matches are judged here only. `--doctor` runs the same check
over the whole vault and prints one line per problem.

Since v0.7.0 a session answers only for claims carrying its own `lease:`
(§4.9): another window's half-written document never blocks this Stop; an
unleased session with live leases (live, quiet or resumed — a stale lease's
session is gone and holds nothing) is refused on any claim; a lease file that
cannot be read blocks any claim at all, since nothing can be attributed until
it is fixed or swept; `--doctor` still sweeps every claim. A vault
`index.lock` met at Stop is retried three times a second apart, then blocks
(§3.3) — never a silent "no claims found".
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

UNLEASED_CLAIMS = "This session holds no lease, so its claims cannot be attributed. Claim a lease and restart."
UNREADABLE_CLAIMS = "A lease file cannot be read, so this session's claims cannot be attributed. "


def problems(root: Path, since_sha: Optional[str], since_time: Optional[float], marker: Optional[dict], live: bool,
             lease: Optional[str] = "*") -> List[str]:
    out: List[str] = []
    found = v.claims(root, since_sha, since_time, lease=lease)
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
        if rec.get("quick"):
            out.append("%s cites evidence-run %s, a quick promote's run (targeted tests or nothing, not the full suite); "
                       "cite a full run." % (p, rid))
            continue
        # A promotion's gate run (gates.sh --promote) is PASS with its reviewer deferred to
        # core/promote.sh, which never flips it; its merged tree can fingerprint exactly like a
        # window's clean worktree. It is promote's evidence, and stands behind a window's claim
        # only once that promotion was confirmed and pushed for the same window and the window
        # has no new work (update-command Decision 11). Its tree is the pushed merge, not the
        # window's checkout, so the fingerprint is not compared; the config check still is.
        promoted = v.is_promotion_run(rec)
        if promoted:
            why = v.promotion_vouches(root, dict(rec, run_id=rec.get("run_id") or rid), fm, p)
            if why:
                out.append(why)
                continue
        if not live:
            continue
        live_cfg = v.sha256_file(root / "config.yaml")
        marker_cfg = marker.get("config_sha") if marker else None
        if rec.get("config_sha") != live_cfg or (marker_cfg is not None and rec.get("config_sha") != marker_cfg):
            out.append("%s cites evidence-run %s, but the gate definition (config.yaml) changed this session; re-run core/gates.sh — if the operator changed it, restart the session (it re-snapshots)." % (p, rid))
            continue
        if promoted:
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
    # A visitor — a session this Daedalus was called into (DIRECT_CALL_ID, spec
    # §8.5) — writes no claims, so it answers for none: a blocked Stop in a
    # headless call spins until max_turns or the call's timeout.
    if os.environ.get("DIRECT_CALL_ID"):
        return 0
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    sid = v.export_session(payload)
    marker = v.read_marker(root, sid)
    since_sha = marker.get("vault_head") if marker else None
    since_time = None if marker else v.transcript_first_ts(payload.get("transcript_path", ""))
    # §4.9: a session answers only for its own window's claims. An unleased
    # session in a deployment with live leases cannot attribute anything, so
    # any claim at all refuses its Stop (a visitor never gets here: it returned
    # above).
    # "Live" is liveness, not a file's existence: a stale lease (dead pid, its
    # session gone from the registry) holds nothing, and refusing on it would
    # point at the wrong remedy ("claim a lease" cannot clear a dead file;
    # `lease.sh sweep` can) — so only stale leases fall through to lease-less
    # attribution. A lease file that cannot be read leaves `mine` unknown; the
    # empty context vouches for nothing, so any claim blocks, whoever stops
    # (the leaselib sentence names the file and the fix).
    ctx = v.lease_context(root, sid)
    held = [nn for nn in ctx["leases"] if nn != "prime" and ctx["liveness"].get(nn) != "stale"]
    reason = None
    try:
        if ctx["unreadable"]:
            if v.claims(root, since_sha, since_time, lease="*"):
                reason = UNREADABLE_CLAIMS + ctx["unreadable"]
        elif held and ctx["mine"] is None:
            if v.claims(root, since_sha, since_time, lease="*"):
                reason = UNLEASED_CLAIMS
        if reason is None:
            bad = problems(root, since_sha, since_time, marker, live=True, lease=ctx["mine"])
            if bad:
                note = "" if marker else "\n(the session-start hook did not run; the claim window is approximate)"
                reason = "\n".join(bad) + note
    except v.VaultLocked as e:
        reason = str(e)
    except Exception as e:
        # Fail closed only if a claim exists at all; otherwise stay out of the way.
        try:
            if v.claims(root, since_sha, since_time, lease=ctx["mine"]):
                reason = "verify-hook could not read the evidence: %s" % e
        except v.VaultLocked as e2:
            reason = str(e2)
        except Exception:
            pass
    blocks, notes = v.stop_once(root, sid, "verify", [reason] if reason else [], bool(payload.get("stop_hook_active")))
    if blocks:
        v.block("\n".join(blocks + [v.WAY_BACK]))
    if notes:
        print("\n".join(notes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
