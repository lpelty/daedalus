#!/usr/bin/env python3
"""SessionStart hook: record where the session began, and say what is
already wrong.

The marker is the root of trust for every later check — vault HEAD for the
claim window, config hashes, the operator's own uncommitted changes to
protected files, the target's origin/<config target.branch> (PROP-019). Written only when no marker
exists yet for this session id, regardless of `source` — never overwritten,
so a claim made before a compaction (or a second `startup`/`fork` payload
for the same session) stays inside the window. Then the offline evidence
check runs, so a claim that slipped past a crashed session is the first
thing the new session sees. Silent on any failure of its own.

Since v0.7.0 the binding comes FIRST (spec §4.2 steps 1–7): export the
payload's session id; a visitor (DIRECT_CALL_ID) binds nothing; a
DAEDALUS_LEASE hint binds a null or dead lease; a resumed session
self-rebinds; a terminal window (registry pair interactive/cli) auto-numbers
and first-ups the pen; only then is the target resolved and the marker
written — otherwise the marker would carry a refusal for a session the
binding fixes a second later. The first line of the context is always the
orientation line (§8.2), so a caller can grep for it.
"""
from __future__ import annotations

import json
import os
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
    sid = v.export_session(payload)
    visitor = bool(os.environ.get("DIRECT_CALL_ID"))
    bind_notes = []
    lease_nn = None
    try:
        import leaselib as ll
    except Exception:  # pragma: no cover
        ll = None
    if ll is not None and not visitor and sid:
        try:
            b = ll.session_start_bind(root, sid)
            lease_nn = b["lease"]
            bind_notes.extend(b["notes"])
            if b["numbered"]:
                line = "You are window %s." % lease_nn
                if b["took_pen"]:
                    line = ("You are window %s and you hold the pen (prime): hot.md, vault commits, promote. "
                            "No other window may do those until you hand over." % lease_nn)
                entry = ll.registry_entry_for(sid)
                if entry and entry.get("name") != "daedalus-%s" % lease_nn:
                    line += " (you may `/rename daedalus-%s` so the board reads cleanly — optional)" % lease_nn
                bind_notes.append(line)
            elif b["took_pen"]:
                bind_notes.append("You hold the pen (prime) now: hot.md, vault commits, promote.")
            if lease_nn is None:
                # §3.1: an unleased session that is not a visitor is told at start what to run.
                bind_notes.append("This session holds no lease. If the operator told you your window number, run "
                                  "`core/lease.sh claim <NN>`; otherwise run `core/lease.sh create` and then `claim` "
                                  "the number it prints.")
        except ll.Refused as e:
            bind_notes.append(str(e))
        except Exception:
            pass
    elif visitor:
        bind_notes.append("This is a direct-call session; it holds no lease and cannot take the pen.")
    mp = v.marker_path(root, sid)
    notes = []
    try:
        pre_existing = mp.exists()
        if not mp.exists():
            # PROP-019: resolve origin/<config target.branch>, and when that fails record WHY,
            # so the boundary hook can refuse by name instead of skipping by silence.
            branch, base, base_err = v.target_branch(root), "", ""
            r = v.resolve_target(root, sid)
            if isinstance(r, v.Refused):
                base_err = r.sentence
                notes.append("This session cannot be bound to a lease: %s" % r.sentence)
            elif isinstance(r, v.Resolved):
                t = r.path
                rcode, _, _ = v.run(["git", "-C", str(t), "remote", "get-url", "origin"])
                if rcode != 0:
                    base_err = "no origin remote"
                else:
                    code, out, err = v.run(["git", "-C", str(t), "rev-parse", "--verify", "-q", "origin/" + branch])
                    if code == 0:
                        base = out.strip()
                    else:
                        base_err = ("origin has no branch '%s' (config target.branch); fetch origin or fix the config"
                                    % branch)
                if base_err and base_err != "no origin remote":
                    notes.append("Promotion gate: cannot resolve origin/%s — %s. Every Stop will REFUSE until this is "
                                 "fixed and the session restarted." % (branch, base_err))
            marker = {
                "session_id": str(sid), "started": time.strftime("%Y-%m-%dT%H:%M:%S"),
                "vault_head": v.vault_head(root),
                "config_sha": v.sha256_file(root / "config.yaml"),
                "local_settings_sha": v.local_settings_sha(root),
                "target_branch": branch,
                "target_base": base,
                "target_base_error": base_err,
                "protected_status": v.protected_status(root),
                "protected_snapshot": v.protected_snapshot(root),
                "transcript_path": str(payload.get("transcript_path") or ""),
                "lease": lease_nn,
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
        pass
    # Emit ALWAYS, even with nothing to say: the orientation line is the
    # contract §8.2 greps for.
    try:
        head = ll.orientation(root, sid, visitor=visitor) if (ll is not None and sid) \
            else "Daedalus session orientation: %s, %s" % ("visitor" if visitor else "unleased", root)
    except Exception:
        head = "Daedalus session orientation: unleased, %s" % root
    v.emit({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                   "additionalContext": "\n\n".join([head] + bind_notes + notes)}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
