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
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

# The tracked .claude/settings.json gives this hook 30 s (pinned in
# test_session_start.bats). The worktree git calls get ADD_BUDGET_SECS of it,
# measured from the hook's start (leaselib.add_worktrees gives every call what
# is left, kills a cut-off call's whole process group, and leaves the window
# worktree_ready: false for `claim`); the target resolution after them gets
# what is left less a tail for the marker's own git calls, and never less than
# the 5 s every other hook uses. MARKER_TAIL_SECS is an allowance, not an
# enforced timeout (v.run's default is 20 s). LEASE_TEST_HOOK_BUDGET is a test
# knob and can only shrink the budget.
HOOK_BUDGET_SECS = min(30, int(os.environ.get("LEASE_TEST_HOOK_BUDGET") or 30))
MARKER_TAIL_SECS = 5
MIN_RESOLVE_SECS = 5
ADD_BUDGET_SECS = HOOK_BUDGET_SECS - MARKER_TAIL_SECS - MIN_RESOLVE_SECS
# The upgrade (spec §14 step 0) gets its own share of the worktree budget — 12 s of 20 at the default — so a
# slow fetch or another start's upgrade can never leave this window's own bind without time (plan 5
# Decisions 3, 10). It shrinks with LEASE_TEST_HOOK_BUDGET like everything above.
UPGRADE_BUDGET_SECS = max(1, ADD_BUDGET_SECS * 3 // 5)

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    import verifylib as v
except Exception:  # pragma: no cover
    sys.exit(0)


def unverified(root: Path, marker: dict) -> list:
    out = []
    for p, fm in v.claims(root, None, None, lease="*"):  # whole vault, every window's: the offline sweep
        rid = fm.get("evidence-run", "")
        rec = v.run_record(root, rid) if rid else None
        if not rid:
            out.append("%s: no evidence-run" % p)
        elif rec is None:
            out.append("%s: evidence-run %s not found" % (p, rid))
        elif rec.get("result") != "PASS":
            out.append("%s: evidence-run %s is %s" % (p, rid, rec.get("result")))
    return out


def resolve_budget(started_at: float) -> int:
    left = HOOK_BUDGET_SECS - MARKER_TAIL_SECS - (time.time() - started_at)
    return max(MIN_RESOLVE_SECS, int(left))


_VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def upgrade_pending(root: Path) -> bool:
    """§14 step 0's test, by reading two files — the upgrade module is loaded only when it has work, so a home
    already at its VERSION pays nothing, and a home with no VERSION (or one that is not X.Y.Z) is not upgraded
    at all (plan 5 Decision 1; the same rule as upgrade.version and lib.sh daedalus_version)."""
    try:
        ver = (root / "VERSION").read_text().split("\n", 1)[0].strip()
    except OSError:
        return False
    if not _VERSION_RE.fullmatch(ver):
        return False
    try:
        done = (root / "state" / "upgraded-to").read_text().strip()
    except OSError:
        done = ""
    return ver != done


MEMORY_ABSENT = ("memory: block absent from config.yaml — Stop-cadence capture is off; "
                 "a SessionEnd capture wired in .claude/settings.local.json still runs")
REINDEX_NOTE = ("The document index is older than the vault; rebuilding it in the background "
                "(state/recall-index.log).")
REINDEX_MIN_LEFT_SECS = 4


def kick_reindex(root: Path, started_at: float) -> Optional[str]:
    """The document index follows the vault (reindex design 2026-10-15, §3.5):
    the window that holds the pen rebuilds a stale index at its start, so a
    vault that changed outside a commit — an operator's edit, a pull, a failed
    earlier rebuild — is not left unindexed until the next commit. One bounded
    subprocess, `vault-search.py index --background --if-stale`, which answers
    "fresh" from a stat and otherwise spawns the detached rebuild; its lock
    dedups a kick that races a commit's. Run only inside what the budget has
    left after the bind and the marker's tail; a start that spent its budget on
    worktree adds skips the kick rather than overrunning. A timeout or a crash
    ends it silently. The note is said when a rebuild started, or when one is
    already running (the script's own line); "fresh", "unconfigured" (recall is
    optional; doctor names it) and PRIME_ONLY say nothing."""
    script = root / "core" / "vault-search.py"
    if not script.is_file():
        return None
    left = HOOK_BUDGET_SECS - MARKER_TAIL_SECS - (time.time() - started_at)
    if left < REINDEX_MIN_LEFT_SECS:
        return None
    try:
        r = subprocess.run(
            [sys.executable, str(script), "index", "--background", "--if-stale", "--by", "session-start"],
            cwd=str(root), stdin=subprocess.DEVNULL, capture_output=True, text=True,
            timeout=min(5, left - 1),
        )
    except Exception:
        return None
    lines = [ln.strip() for ln in (r.stdout or "").splitlines() if ln.strip()]
    line = lines[0] if lines else ""
    if line.startswith("document index: rebuilding in the background"):
        return REINDEX_NOTE
    if line.startswith("document index: a rebuild is already running"):
        return line
    return None


def _hook_commands(path: Path) -> list:
    """Every hook command in a settings file, walked as JSON (hooks -> event
    -> groups -> hooks -> command) — the walk doctor.sh's local_capture_wiring
    makes, so the two never disagree. A text search counted a permission rule
    (an allow entry for `python3 core/capture.py status`) as a wired hook."""
    try:
        d = json.loads(path.read_text())
    except (OSError, ValueError):
        return []
    hooks = d.get("hooks") if isinstance(d, dict) else None
    out = []
    for groups in (hooks.values() if isinstance(hooks, dict) else []):
        for g in (groups if isinstance(groups, list) else []):
            for h in ((g.get("hooks") or []) if isinstance(g, dict) else []):
                c = h.get("command") if isinstance(h, dict) else None
                if isinstance(c, str):
                    out.append(c)
    return out


def memory_note(root: Path) -> Optional[str]:
    """§4.7: a memory-configured deployment that has not moved its capture
    wiring into config.yaml's memory: block is told so at its first session
    after the upgrade, not months later. Said when the session's marker is
    first written (once per session), and only when a hook command in
    settings.local.json still runs capture.py and config.yaml has no
    top-level memory: line."""
    if not any("capture.py" in c for c in _hook_commands(root / ".claude" / "settings.local.json")):
        return None
    try:
        text = (root / "config.yaml").read_text()
    except OSError:
        return None
    if any(line.startswith("memory:") for line in text.splitlines()):
        return None
    return MEMORY_ABSENT


def main() -> int:
    # A SIGTERM (a cancelled hook, a shutdown) becomes SystemExit, so
    # leaselib._run_bounded kills the running git's process group on its way
    # out instead of leaving a checkout writing (plan 2 Decision 20).
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(128 + signum))
    started_at = time.time()
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
    # Step 0 (spec §14): a pulled release upgrades this home before anything binds — every step idempotent,
    # each said once when it acts. Never in a visitor, which writes nothing (plan 5 Decision 2). A failure
    # of the upgrade module is a line, never a broken start. The upgrade has its own deadline, so the bind
    # below keeps the rest of the worktree budget.
    skip_bind = False
    if not visitor and upgrade_pending(root):
        try:
            import upgrade as up
            up_lines, up_stop = up.run(root, deadline=started_at + UPGRADE_BUDGET_SECS)
            bind_notes.extend(up_lines)
            if up_stop:
                bind_notes.append(up_stop)
        except Exception as e:
            bind_notes.append("The upgrade could not run at this start (%s: %s); core/doctor.sh says what is left."
                              % (type(e).__name__, e))
        # §14: no auto-numbering while state/leases/ does not exist — the upgrade did not get to its first step
        # (another start held its lock past this start's share, or it failed). The next start, or `claim`,
        # numbers this window; the pending line says why (plan 5 Decision 13).
        # No window while the upgrade's safety copy of target/ is not taken (it runs in the background, or it
        # stopped before it): numbering one adds a worktree in target/'s repositories, and prunes records under
        # worktrees/, before the copy has read them (safety-copy review 3, finding 4).
        try:
            import upgrade as up
            uncopied = upgrade_pending(root) and up.copy_missing(root)
        except Exception:
            uncopied = False
        if uncopied and not visitor:
            bind_notes.append(up.COPY_FIRST + ".")
        # No window at all while the upgrade is not stamped — it stopped (on unfinished work, out of time, ...), a
        # run in the background holds it, or it did not get to run: numbering one adds lease/<NN>, a worktree
        # record, a branch section and the pre-push hook to target/'s repositories, right after a stop that said
        # "Nothing was changed" (final verification, mode c). The board says the stop and that windows open once
        # the upgrade finishes; "pick it up" (lease.sh adopt --all-unfinished) is the way in.
        if upgrade_pending(root):
            skip_bind = True
            try:
                import upgrade as up
                pend = up.pending_line(root)
            except Exception:
                pend = None
            if pend and pend not in bind_notes:
                bind_notes.append(pend)
            if not uncopied:
                try:
                    bind_notes.append(up.WINDOWS_WAIT + ".")
                except Exception:
                    pass
    lease_nn = None
    holds_pen = False
    try:
        import leaselib as ll
    except Exception:  # pragma: no cover
        ll = None
    if ll is not None and not visitor and sid and not skip_bind:
        try:
            # startup / resume open a session today; compact / clear continue one — its log stays the file it opened with
            b = ll.session_start_bind(root, sid, deadline=started_at + ADD_BUDGET_SECS,
                                      new_day=str(payload.get("source", "")).lower() not in ("compact", "clear"))
            lease_nn = b["lease"]
            # the bind's own answer, never a second locked read (decision 26): the kick below rests on it
            holds_pen = bool(b.get("prime"))
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
            if b.get("log"):
                bind_notes.append("Your session log for today is %s (the window goes in its frontmatter, never the "
                                  "filename); a restart today continues that file under `## Continued HH:MM`, and a "
                                  "session that runs past midnight keeps it. `core/lease.sh log` prints the path again."
                                  % b["log"])
            if lease_nn is None:
                # §3.1: an unleased session that is not a visitor is told at start what to run
                # (the board's own sentence, so the dedup below can recognise it).
                bind_notes.append(ll.UNLEASED_NAG)
        except ll.Refused as e:
            bind_notes.append(str(e))
        except Exception:
            pass
    elif visitor:
        bind_notes.append("This is a direct-call session; it holds no lease and cannot take the pen.")
    # The board at start (§4.3), rendered HERE after the bind: an event's hooks
    # run in parallel, so lease-board.py on SessionStart could not be ordered
    # after the numbering and might show this window unleased. Same render,
    # same four duties as every prompt's; lease-board.py is UserPromptSubmit only.
    board = ""
    if ll is not None and sid:
        try:
            # the same deadline as the bind, or one second from now when that
            # is later: the board's lock wait is bounded too (Decision 18)
            board = ll.board_for(root, sid, visitor, deadline=max(started_at + ADD_BUDGET_SECS, time.time() + 1))
        except ll.Refused as e:
            # a corrupt lease file must not make the board vanish (that reads as "no leases"):
            # say the sentence lease.sh refuses with — it names the file and the fix
            board = ll.BOARD_UNRENDERED % e
        except Exception:
            board = ""
    if board:
        # the board carries the unleased nag and the visitor line itself; say each once
        bind_notes = [n for n in bind_notes if n not in (ll.UNLEASED_NAG, ll.VISITOR_LINE)]
    mp = v.marker_path(root, sid)
    notes = []
    try:
        pre_existing = mp.exists()
        if not mp.exists():
            # PROP-019: resolve origin/<config target.branch>, and when that fails record WHY,
            # so the boundary hook can refuse by name instead of skipping by silence.
            branch, base, base_err = v.target_branch(root), "", ""
            # The seam waits on the lease lock while a neighbour's SessionStart
            # adds its worktrees (§4.2: seconds, not milliseconds), so it gets
            # the budget this hook has left rather than the 5 s default; a seam
            # that still does not answer is Refused, and recorded as such.
            r = v.resolve_target(root, sid, timeout=resolve_budget(started_at))
            if isinstance(r, v.Refused):
                base_err = r.sentence
                notes.append("This session cannot be bound to a lease: %s" % r.sentence)
            elif isinstance(r, v.Unconfigured):
                # No target yet (no config, no lib.sh): notes, never denials —
                # but the marker still says WHY it holds no base, so it is never
                # a silent empty pair that a later Stop reads as "not recorded".
                base_err = r.reason
                notes.append("The target did not resolve (%s); the promotion gate has nothing to compare until it does."
                             % r.reason)
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
                # the absolute instant beside the local stamp: a transcript cut-off is never a
                # local stamp parsed under the reader's TZ (plan 4 Decisions 45, 51)
                "started_epoch": time.time(),
                "vault_head": v.vault_head(root),
                "config_sha": v.sha256_file(root / "config.yaml"),
                # the release this session started on, and the upgrade's record of its config.yaml writes as it
                # stood: a record is the release's only when a release came in under the session (review, 4)
                "version": v.home_version(root),
                "config_changes_sha": v.sha256_file(root / v.CONFIG_CHANGES),
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
            mem = memory_note(root)
            if mem:
                notes.append(mem)
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
    # The document index follows the vault: for the window that holds the pen, at a startup or a
    # resume (a compaction is not a start and the vault did not change with it), one bounded call.
    if holds_pen and not visitor and not skip_bind \
            and str(payload.get("source", "")).lower() in ("startup", "resume"):
        try:
            line = kick_reindex(root, started_at)
        except Exception:
            line = None
        if line:
            notes.append(line)
    # Emit ALWAYS, even with nothing to say: the orientation line is the
    # contract §8.2 greps for.
    try:
        # bounded like the board's wait: the orientation line reads the leases under the lock too
        head = ll.orientation(root, sid, visitor=visitor, deadline=max(started_at + ADD_BUDGET_SECS, time.time() + 1)) \
            if (ll is not None and sid) \
            else "Daedalus session orientation: %s, %s" % ("visitor" if visitor else "unleased", root)
    except Exception:
        head = "Daedalus session orientation: unleased, %s" % root
    v.emit({"hookSpecificOutput": {"hookEventName": "SessionStart",
                                   "additionalContext": "\n\n".join([head] + bind_notes + notes + ([board] if board else []))}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
