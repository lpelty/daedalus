#!/usr/bin/env python3
"""The inputs of a promote review, pinned (spec §6.1): the verdict of a
promotion is bound to what the reviewer was shown, so the prompt is rebuilt
byte for byte from primary artifacts at confirm (`refute.sh --mode promote
--render-only <run-id>`) and its sha compared with the one the launcher sent.

    python3 core/review-inputs.py shas   <run.json>            # shell assignments for refute.sh
    python3 core/review-inputs.py nested <run.json>            # rel<TAB>base<TAB>merge per nested repo
    python3 core/review-inputs.py record <run.json> <evidence> <criteria-or-empty> <pitfall-list> <verdict-file>
    python3 core/review-inputs.py verify <run.json> <evidence> <criteria-or-empty> <pitfall-list-out>

run.json is the promote gate run's (state/evidence/<run-id>/run.json), which
promote's prepare writes with promote_id, trunk_sha_at_prepare, merge_sha,
lease and — for nested repositories — nested: {<relpath>: {trunk_sha_at_prepare,
merge_sha}}. `record` adds what the render read: pitfalls [{path, sha256}]
(paths relative to the home, in the order they were shown), criteria_path
and criteria_sha (the lease file's criteria:, never argv), evidence_sha. It
may pin again while no verdict and no prepared.json exist — a review the
launcher refused before it ran does not burn the promotion's one review —
and refuses once either exists. `verify` refuses (exit 2, one sentence) when any of them has
changed since, and writes the recorded pitfall paths for refute-pitfalls.py
--only. Python 3.9, standard library only.
"""
from __future__ import annotations

import hashlib
import json
import os
import shlex
import sys
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

REQUIRED = ("promote_id", "trunk_sha_at_prepare", "merge_sha", "lease")


class Refused(Exception):
    pass


def sha_of(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def load(run_json: str) -> dict:
    try:
        rec = json.loads(Path(run_json).read_text())
    except (OSError, ValueError):
        raise Refused("no promote run record at %s — a promote review reads the promotion's gate run" % run_json)
    missing = [k for k in REQUIRED if not rec.get(k)]
    if missing:
        raise Refused("the run record %s is not a promotion's (missing %s)" % (run_json, ", ".join(missing)))
    return rec


def home_path(raw: str) -> Path:
    p = Path(raw)
    return p if p.is_absolute() else v.ROOT / p


def criteria_of(rec: dict) -> str:
    """The recorded criteria file once recorded; before that, the one the
    window's lease file names (set by `core/lease.sh update <NN> --criteria`)."""
    if "criteria_path" in rec:
        return rec["criteria_path"] or ""
    import leaselib as ll
    try:
        lease = ll.read_lease(v.ROOT, str(rec["lease"])) or {}
    except ll.Refused as e:   # an unreadable lease file: its sentence, never a traceback
        raise Refused(str(e))
    return str(lease.get("criteria") or "")


def cmd_shas(run_json: str) -> None:
    rec = load(run_json)
    crit = criteria_of(rec)
    out = {"base_sha": rec["trunk_sha_at_prepare"], "merge_sha": rec["merge_sha"], "lease_nn": rec["lease"],
           "criteria": str(home_path(crit)) if crit else ""}
    for k, val in out.items():
        print("%s=%s" % (k, shlex.quote(str(val))))


def cmd_nested(run_json: str) -> None:
    for rel, shas in sorted((load(run_json).get("nested") or {}).items()):
        print("%s\t%s\t%s" % (rel, shas["trunk_sha_at_prepare"], shas["merge_sha"]))


def rel_to_home(p: Path) -> str:
    try:
        return str(p.resolve().relative_to(v.ROOT))
    except ValueError:
        return str(p)


def cmd_record(run_json: str, evidence: str, criteria: str, pitfall_list: str, verdict_file: str) -> None:
    rec = load(run_json)
    prepared = v.ROOT / "state" / "promote" / str(rec["promote_id"]) / "prepared.json"
    if "pitfalls" in rec and (Path(verdict_file).exists() or prepared.exists()):
        raise Refused("this promotion's review inputs are already recorded and its review exists; "
                      "a new review needs a new run")
    # Pinned before by an attempt that produced no verdict (the launcher
    # refused it, or claude failed): pin again, so the inputs on record are
    # always those of the attempt that wrote the verdict (Decision 20).
    files = [Path(l) for l in Path(pitfall_list).read_text().splitlines() if l.strip()]
    rec["pitfalls"] = [{"path": rel_to_home(f), "sha256": sha_of(f)} for f in files]
    rec["criteria_path"] = rel_to_home(Path(criteria)) if criteria else None
    rec["criteria_sha"] = sha_of(Path(criteria)) if criteria else None
    rec["evidence_sha"] = sha_of(Path(evidence))
    tmp = Path(run_json + ".tmp")
    tmp.write_text(json.dumps(rec, indent=2))
    os.replace(tmp, run_json)


def cmd_verify(run_json: str, evidence: str, criteria: str, list_out: str) -> None:
    rec = load(run_json)
    if "pitfalls" not in rec:
        raise Refused("this promotion's review inputs were never recorded; there is no review to re-render")
    for p in rec["pitfalls"]:
        f = home_path(p["path"])
        if not f.is_file() or sha_of(f) != p["sha256"]:
            raise Refused("a pitfall the reviewer read has changed since the review (%s)" % p["path"])
    if rec.get("criteria_sha") and (not criteria or sha_of(Path(criteria)) != rec["criteria_sha"]):
        raise Refused("the acceptance criteria the reviewer read have changed since the review (%s)"
                      % rec.get("criteria_path"))
    if not Path(evidence).is_file() or sha_of(Path(evidence)) != rec.get("evidence_sha"):
        raise Refused("the evidence summary the reviewer read has changed since the review (%s)" % evidence)
    Path(list_out).write_text("".join(str(home_path(p["path"])) + "\n" for p in rec["pitfalls"]))


def main(argv: List[str]) -> int:
    cmds = {"shas": (cmd_shas, 1), "nested": (cmd_nested, 1), "record": (cmd_record, 5), "verify": (cmd_verify, 4)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        sys.stderr.write("usage: review-inputs.py shas|nested <run.json> | record <run.json> <evidence> "
                         "<criteria-or-empty> <pitfall-list> <verdict-file> | verify <run.json> <evidence> "
                         "<criteria-or-empty> <pitfall-list-out>\n")
        return 2
    try:
        cmds[argv[1]][0](*argv[2:])
    except Refused as e:
        sys.stderr.write("%s\n" % e)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
