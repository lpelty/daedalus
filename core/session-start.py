#!/usr/bin/env python3
"""SessionStart hook: record where the session began, and say what is
already wrong.

The marker is the root of trust for every later check — vault HEAD for the
claim window, config hashes, the operator's own uncommitted changes to
protected files, the target's origin/main. Written only when no marker
exists yet for this session id, regardless of `source` — never overwritten,
so a claim made before a compaction (or a second `startup`/`fork` payload
for the same session) stays inside the window. Then the offline evidence
check runs, so a claim that slipped past a crashed session is the first
thing the new session sees. Silent on any failure of its own.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import verifylib as v
except Exception:  # pragma: no cover
    sys.exit(0)


def unverified(root: Path, marker: dict) -> list:
    out = []
    for p, fm in v.claims(root, None, None):          # whole vault: this is the offline check
        rid = fm.get("evidence-run", "")
        rec = v.run_record(root, rid) if rid else None
        if not rid:
            out.append("%s: no evidence-run" % p)
        elif rec is None:
            out.append("%s: evidence-run %s not found" % (p, rid))
        elif rec.get("result") != "PASS":
            out.append("%s: evidence-run %s is %s" % (p, rid, rec.get("result")))
    return out


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    root = v.ROOT
    sid = payload.get("session_id")
    mp = v.marker_path(root, sid)
    notes = []
    try:
        pre_existing = mp.exists()
        if not mp.exists():
            origin = ""
            t = v.target_root(root)
            if t is not None:
                code, out, _ = v.run(["git", "-C", str(t), "rev-parse", "origin/main"])
                origin = out.strip() if code == 0 else ""
            marker = {
                "session_id": str(sid), "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "vault_head": v.vault_head(root),
                "config_sha": v.sha256_file(root / "config.yaml"),
                "local_settings_sha": v.local_settings_sha(root),
                "target_origin_main": origin,
                "protected_status": v.protected_status(root),
                "protected_snapshot": v.protected_snapshot(root),
            }
            mp.parent.mkdir(parents=True, exist_ok=True)
            mp.write_text(json.dumps(marker, indent=2))
            cutoff = time.time() - 7 * 86400
            for old in mp.parent.glob("session-*.json"):
                try:
                    if old.stat().st_mtime < cutoff:
                        old.unlink()
                except OSError:
                    pass
        marker = v.read_marker(root, sid) or {}
        src = str(payload.get("source", "")).lower()
        if pre_existing and src in ("resume", "startup") and marker.get("started"):
            # The marker is deliberately write-once per session id (a claim's
            # window must survive compaction and duplicate startup payloads),
            # so a resume reuses the snapshot taken at the ORIGINAL start.
            # Say so, so an operator who restarted-to-re-baseline learns why
            # nothing changed and what actually re-baselines (PROP-017 f.3).
            notes.append("This session id resumed with its original snapshot "
                         "(taken %s). A boundary block naming operator changes "
                         "clears only in a FRESH session, or after the operator "
                         "deletes %s from outside the session."
                         % (marker.get("started"), mp))
        if marker.get("protected_status"):
            notes.append("The operator has uncommitted changes in protected files (%s); not yours, not blocked."
                         % ", ".join(ln[3:] for ln in marker["protected_status"]))
        bad = unverified(root, marker)
        if bad:
            notes.append("Unverified claims in the vault — run core/gates.sh and cite the run-id, or change the status:\n"
                         + "\n".join("  - " + b for b in bad))
        ev_dir = root / "vault" / "evidence"
        if not ev_dir.is_dir() or not any(ev_dir.glob("*.md")):
            notes.append("verify: stage unarmed — no evidence yet; run core/gates.sh once to arm it")
        ev = root / "state" / "evidence"
        if ev.is_dir():
            runs = sorted(ev.glob("*/run.json"))
            if runs:
                try:
                    secs = int(json.loads(runs[-1].read_text()).get("fingerprint_secs", 0))
                    if secs > 20:
                        notes.append("The last fingerprint took %ds; tighten the target's .gitignore before the verify hook goes silent." % secs)
                except (OSError, ValueError):
                    pass
    except Exception:
        return 0
    if notes:
        v.emit({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "\n\n".join(notes)}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
