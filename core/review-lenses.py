#!/usr/bin/env python3
"""Review lenses and the findings ledger (v0.12.3) — refute.sh's helper for a window's branch review.

Why. On a large change one fresh reviewer, within its timeout, can follow only a few threads, so each run was a
different sample: a 56-commit branch was refuted ten times, each review correct, almost each finding something the
last had not mentioned on code that had not changed. And every re-review started cold, re-deriving context instead
of checking the fixes. So a large change is reviewed by several fresh reviewers at once, each through one lens
(criteria, trust boundaries, upgrade and existing installs, failure handling — config verify.lenses), their findings
merged; and each window's branch keeps a ledger of the findings earlier reviews counted, which a re-review checks
first, hunting fresh only in what changed since the last review. A small change keeps one reviewer: the parallel
reviewers cost one review each, for about the same wall-clock time, and a small change does not need them.

Promote's review uses neither. It is the last gate: one fresh reviewer that has not been told what earlier reviews
found, so it cannot inherit their blind spots, and its prompt is re-rendered byte for byte at confirm.

Verbs (all print to stdout; a failure is a sentence on stderr and exit 2 — refute.sh treats it as uncertifiable):
  size <diff-file> <paths-file>                     "<lines> <files>": changed lines (+/-, not headers), paths
  lenses <spec>                                     one valid lens name per line, or refuse
  lens-text <name>                                  the paragraph a reviewer is given for its lens
  key <home> <nn> <branch>                          the ledger key, JSON (same rule as the refutation count)
  open <home> <nn> <branch> <section-out> <heads-out>
        the "Earlier findings" prompt section (empty when none) and the last review's heads
        ("<rel>\\t<sha>" per repository); prints "<earlier-count> <last-run-id>"
  hunks <delta-file> <target> <out>
        the part of the change since the last review, as JSON: per target-relative file, its new-side line ranges
        (null: the whole file — a deletion, a binary or a mode change)
  merge <out> <run-id> <ledger-open-json|-> <hunks-json|-> <lens>=<file>...
        the merged review: findings of every lens, one per file:line with the strongest labels and the lenses
        that found it, earlier findings re-reported kept by id, unchecked open ones carried, and — given the hunks
        — a new finding outside them labelled `missed earlier`; prints the plan note
  record <home> <nn> <branch> <run-id> <review-file> <heads-file>
        the ledger after a run with a verdict; prints "<earlier> <resolved> <open> <new> <backlog> <live>"
  live <home> <nn> <branch>
        the window's open live checks, JSON: [{"id", "file", "line", "what"}] — promote's decision block lists them

Reach and new ground (v0.12.4). Each finding names its reach (user, routine or none) and may carry the flags data,
trust and live-only; refute.sh's verdict_of says what counts, and counted() here is the same rule. A later review of
a branch refutes only on new ground: a new finding outside the part changed since the last review is labelled
`missed earlier` by the merge — the reviewer's own labels never carry it — and goes to the ledger as a backlog
candidate, unless it is an observed HIGH with the data or trust flag. A finding whose place cannot be read is judged
as before: the rule fails safe toward reviewing. Findings that do not count go to the ledger too — `backlog`, and
`live check` for a live-only one — so the operator can file them and promote can list the live checks.
"""
import json
import os
import re
import shutil
import sys
import tempfile
import time

DEFAULT_LENSES = ("criteria", "trust", "upgrade", "failure")
LENS_TEXT = {
    "criteria": "Correctness against the acceptance criteria: does the change do what each criterion says, on every "
                "path the criteria cover, and can its tests fail when it does not?",
    "trust": "Trust boundaries: what reaches this code from outside it — files, the network, other processes, the "
             "operator, config — what it is trusted to be, and what each guard lets through.",
    "upgrade": "Existing installs and upgrade: a deployment that already has state, config, files or data from an "
               "earlier version; formats read and written; what an update leaves behind or cannot read.",
    "failure": "Failure handling: what happens when a command, a read, a write, a lock or a timeout fails or is "
               "interrupted part-way; partial writes; error paths that report success.",
}
NAME = re.compile(r"^[a-z0-9_]{1,24}$")

# A finding heading, as verdict_of in refute.sh reads it: F<n> after #s or in bold, then a separator.
HEAD = re.compile(r"^[ \t>]*(?:#{1,6}[ \t]*(?:\*\*|__)?|\*\*|__)[ \t]*F(\d+)\b(?:\*\*|__)?[ \t]*([—–:|-].*)$")
SPLIT = re.compile(r"\s*[—–|]+\s*|\s+-+\s+|^-+\s*|^:\s*")
SEV, STAND = ("HIGH", "MEDIUM", "LOW"), ("observed", "plausible", "hypothetical")
REACH, FLAGS = ("user", "routine", "none"), ("data", "trust", "live-only")
REF = re.compile(r"\b(earlier|regressed|carried)\s+(L\d+)\b", re.I)
RESOLVED = re.compile(r"^[\s*>-]*\**Resolved\**\s*:\s*\**\s*((?:L\d+[\s,;and]*)+)", re.I | re.M)
LOC = re.compile(r"^(.+?):(\d+)(?:[-–](\d+))?$")
# refute.sh's verdict grammar (V and E there): a lens that says REFUTED and names no labelled finding still refutes.
SAID_REFUTED = re.compile(r"^[*#>0-9.\s-]*VERDICT[*\s]*:?[*\s]*REFUTED[*\s.!]*$", re.M)


def die(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)


def parts_of(rest):
    return [p.strip(" *`_:") for p in SPLIT.split(rest) if p.strip(" *`_:")]


def labels(parts):
    low = [p.lower() for p in parts]
    sev = [p.upper() for p in parts if p.upper() in SEV]
    st = [p for p in low if p in STAND]
    sc = ["in scope" if p in ("in scope", "in-scope") else "out of scope" for p in low
          if p in ("in scope", "in-scope", "out of scope", "out-of-scope")]
    return sev, st, sc


def reach_of(parts):
    return [m.group(1) for m in (re.match(r"^reach\s*[:=]?\s*(user|routine|none)$", p.lower()) for p in parts) if m]


def flags_of(parts):
    out = set()
    for p in parts:
        toks = [("live-only" if t == "live only" else t) for t in re.split(r"\s*[,+]\s*|\s+and\s+", p.lower()) if t]
        if toks and all(t in FLAGS for t in toks):
            out.update(toks)
    return out


def new_ground(text):
    """True for a review the merge wrote with the new-ground rule on (its `new-ground:` frontmatter line): the only
    file whose `missed earlier` labels are the tool's own."""
    fm = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    return bool(fm and re.search(r"^new-ground:", fm.group(1), re.M))


def findings(text):
    """[(heading parts, body lines)] in order; the body runs to the next finding, a level-1/2 heading, the rubric
    or the verdict line."""
    out, cur = [], None
    for ln in text.splitlines():
        m = HEAD.match(ln)
        if m:
            cur = (parts_of(m.group(2)), [])
            out.append(cur)
            continue
        if cur is None:
            continue
        if re.match(r"^\s*#{1,2}\s", ln) or re.match(r"^[*#>0-9.\s-]*VERDICT\b", ln) \
                or re.match(r"^[\s*#>-]*\**(Correctness|Regression risk|Test honesty|Pitfall|Claim)", ln) \
                or RESOLVED.match(ln):
            cur = None
            continue
        cur[1].append(ln)
    return out


def describe(parts, body, honour_missed=False):
    """(file, line, end, sev, standing, scope, reach, flags, missed, refs, what) — None when the labels are not one
    of each. `missed` is read only from a file the merge wrote with the new-ground rule on (honour_missed)."""
    sev, st, sc = labels(parts)
    if len(sev) != 1 or len(st) != 1 or len(sc) != 1:
        return None
    loc = next((LOC.match(p) for p in parts if LOC.match(p)), None)
    f, line = (loc.group(1), int(loc.group(2))) if loc else (next((p for p in parts if "/" in p or "." in p), "?"), 0)
    end = int(loc.group(3)) if loc and loc.group(3) and int(loc.group(3)) >= line else line
    rc = reach_of(parts)
    refs = [(k.lower(), i.upper()) for p in parts for k, i in REF.findall(p)]
    what = ""
    for ln in body:
        m = re.match(r"^\s*What is wrong:\s*(.*)$", ln)
        if m:
            what = m.group(1).strip()
            break
    return {"file": f, "line": line, "end": end, "severity": sev[0], "standing": st[0], "scope": sc[0],
            "reach": rc[0] if len(rc) == 1 else None, "flags": sorted(flags_of(parts)),
            "missed": honour_missed and any(p.lower().startswith("missed earlier") for p in parts), "refs": refs,
            "what": what}


def counted(d):
    """refute.sh's verdict_of, for one finding (a review with reach; the merge refuses one without)."""
    if any(k in ("regressed", "carried") for k, _ in d["refs"]):
        return True
    if "live-only" in d.get("flags", ()):
        return False
    observed_high = d["standing"] == "observed" and d["severity"] == "HIGH"
    flagged = bool(set(d.get("flags", ())) & {"data", "trust"})
    if d.get("missed"):
        return observed_high and flagged
    if d.get("reach") is None:      # a ledger entry from before reach (v0.12.3): it was counted by that bar
        return observed_high or (d["scope"] == "in scope" and d["standing"] in ("observed", "plausible")
                                 and d["severity"] in ("HIGH", "MEDIUM"))
    return observed_high or (d["scope"] == "in scope" and d["standing"] in ("observed", "plausible")
                             and d["severity"] in ("HIGH", "MEDIUM") and (d["reach"] in ("user", "routine") or flagged))


def resolved_ids(text):
    ids = set()
    for m in RESOLVED.finditer(text):
        ids.update(i.upper() for i in re.findall(r"L\d+", m.group(1), re.I))
    return ids


def key(home, nn, branch):
    k = {"lease": nn or None, "branch": branch or None}
    if nn:
        try:
            lease = json.load(open(os.path.join(home, "state", "leases", nn + ".json")))
        except (OSError, ValueError):
            lease = {}
        k.update(created=lease.get("created"), promoted=len(lease.get("promoted") or []))
    return k


def ledger_path(home, nn):
    return os.path.join(home, "state", "review-ledger", (nn or "unleased") + ".json")


def load(home, nn, branch):
    """The ledger for this key, or a fresh one: a new lease, a promote, or another branch starts again."""
    k = key(home, nn, branch)
    try:
        d = json.load(open(ledger_path(home, nn)))
    except (OSError, ValueError):
        d = {}
    if d.get("key") != k or not isinstance(d.get("findings"), list) or not isinstance(d.get("runs"), list):
        d = {"key": k, "runs": [], "findings": []}
    return d


def save(home, nn, d):
    p = ledger_path(home, nn)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = "%s.%d.tmp" % (p, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(d, fh, indent=2)
    os.replace(tmp, p)


def heading(n, d, extra):
    loc = "%s:%s" % (d["file"], d["line"]) if d["line"] else d["file"]
    if d.get("line") and d.get("end", 0) > d["line"]:
        loc += "-%d" % d["end"]
    labels_ = (["reach: " + d["reach"]] if d.get("reach") else []) + list(d.get("flags") or [])
    return "### F%d — %s — %s — %s — %s%s" % (n, loc, d["standing"], d["scope"], d["severity"],
                                             "".join(" — " + e for e in labels_ + extra))


def cmd_size(diff, paths):
    lines = 0
    for ln in open(diff, encoding="utf-8", errors="replace"):
        if (ln.startswith("+") and not ln.startswith("+++")) or (ln.startswith("-") and not ln.startswith("---")):
            lines += 1
    files = sum(1 for ln in open(paths, encoding="utf-8", errors="replace") if ln.strip())
    print("%d %d" % (lines, files))


def cmd_lenses(spec):
    names = [n.strip() for n in re.split(r"[,\s]+", spec or "") if n.strip()] or list(DEFAULT_LENSES)
    bad = [n for n in names if not NAME.match(n)]
    if bad:
        die("verify.lenses: %s — a lens is a name of lowercase letters, digits and underscores, up to 24 "
            "(the defaults: %s)" % (", ".join(bad), ", ".join(DEFAULT_LENSES)))
    seen = []
    for n in names:
        if n not in seen:
            seen.append(n)
    print("\n".join(seen))


def cmd_lens_text(name):
    print(LENS_TEXT.get(name, "Focus on %s, as its name says, wherever it touches this change." % name.replace("_", " ")))


def cmd_open(home, nn, branch, section_out, heads_out):
    d = load(home, nn, branch)
    openf = [f for f in d["findings"] if f.get("status") == "open"]
    last = d["runs"][-1] if d["runs"] else None
    with open(section_out, "w") as fh:
        if openf:
            fh.write("## Earlier findings on this branch\n")
            fh.write("Earlier reviews of this branch counted these findings (the last review was run %s). Check each "
                     "one first, before you hunt for new ones:\n" % (last or {}).get("run_id", "?"))
            for f in openf:
                loc = "%s:%s" % (f["file"], f["line"]) if f.get("line") else f["file"]
                more = "".join(" — " + x for x in (["reach: " + f["reach"]] if f.get("reach") else []) + (f.get("flags") or []))
                fh.write("- %s — %s — %s — %s — %s%s — %s\n" % (f["id"], loc, f["standing"], f["scope"], f["severity"],
                                                              more, f.get("what") or "(no description)"))
            fh.write("\nIf one is fixed, name it on a line of its own: `Resolved: L1, L3`. If one is not fixed, report "
                     "it again as a finding with its labels and `earlier L1` as the last part of its heading. If its "
                     "fix broke something, report that as a finding with `regressed L1` as the last part of its "
                     "heading — a regression refutes. An earlier finding you neither resolve nor report again is "
                     "carried into this verdict as it was.\n\n")
    with open(heads_out, "w") as fh:
        for rel, sha in sorted(((last or {}).get("heads") or {}).items()):
            fh.write("%s\t%s\n" % (rel, sha))
    print("%d %s" % (len(openf), (last or {}).get("run_id", "-")))
    with open(section_out + ".json", "w") as fh:
        json.dump(openf, fh)


def cmd_hunks(delta, target, out):
    """The new-side line ranges of the change since the last review (refute.sh's ground_diff: the working tree against
    that review's commit, in one diff), per file."""
    files, cur = {}, None
    for ln in open(delta, encoding="utf-8", errors="replace"):
        ln = ln.rstrip("\n")
        m = re.match(r"^diff --git a/(.*) b/(.*)$", ln)
        if m:
            cur = m.group(2)
            files.setdefault(cur, [])
            continue
        if ln.startswith("+++ b/"):
            cur = ln[6:]
            files.setdefault(cur, [])
            continue
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", ln)
        if m and cur is not None and files.get(cur) is not None:
            start, n = int(m.group(1)), int(m.group(2)) if m.group(2) is not None else 1
            # A pure deletion (+c,0) sits between line c and c+1 of the new side.
            files[cur].append([start, start + 1] if n == 0 else [start, start + n - 1])
    # No hunk at all — a deleted file, a binary, a mode change: the whole file is new ground.
    with open(out, "w") as fh:
        json.dump({"target": target, "files": {f: (r or None) for f, r in files.items()}}, fh)


def missed_earlier(d, hunks):
    """True when the finding's place is readable and lies outside every hunk of the delta. An unreadable place
    (no line, no file) is not missed: it counts as it would have before."""
    if not hunks or not d.get("line") or d.get("file") in (None, "?"):
        return False
    f = d["file"].strip("`")
    tgt = (hunks.get("target") or "").rstrip("/")
    if tgt and f.startswith(tgt + "/"):
        f = f[len(tgt) + 1:]
    if f.startswith("./"):
        f = f[2:]
    files = hunks.get("files") or {}
    keys = [k for k in files if k == f] or [k for k in files if k.endswith("/" + f) or f.endswith("/" + k)]
    if not keys:
        return True
    lo, hi = d["line"], max(d.get("end") or d["line"], d["line"])
    for k in keys:
        if files[k] is None or any(a <= hi and lo <= b for a, b in files[k]):
            return False
    return True


def cmd_merge(out, run_id, open_json, hunks_json, sources):
    """sources: [(lens, file)]. The merged review refute.sh writes as <run-id>-review.md."""
    earlier = json.load(open(open_json)) if open_json != "-" else []
    hunks = json.load(open(hunks_json)) if hunks_json != "-" else None
    merged = {}     # (file, line) -> {d, lenses, bodies}
    order = []
    resolved = set()
    bare = []       # lenses that said REFUTED and named no labelled finding
    for lens, path in sources:
        text = open(path, encoding="utf-8", errors="replace").read()
        resolved |= resolved_ids(text)
        if not findings(text) and SAID_REFUTED.search(text):
            bare.append((lens, path))
        for parts, body in findings(text):
            d = describe(parts, body)
            if d is None:
                die("the %s lens's review has a finding without its labels — cannot certify the run (%s)" % (lens, path))
            ids = sorted({i for _, i in d["refs"]})
            k = ("ref",) + tuple(ids) if ids else ((d["file"], d["line"]) if d["line"] else (d["file"], d["what"]))
            if k not in merged:
                merged[k] = {"d": d, "lenses": [], "bodies": []}
                order.append(k)
            m = merged[k]["d"]
            # The strongest labels: the ones most likely to refute — a defect two lenses saw is judged at its worst.
            m["severity"] = min((m["severity"], d["severity"]), key=SEV.index)
            m["standing"] = min((m["standing"], d["standing"]), key=STAND.index)
            m["scope"] = "in scope" if "in scope" in (m["scope"], d["scope"]) else "out of scope"
            m["reach"] = min((r for r in (m["reach"], d["reach"]) if r), key=REACH.index, default=None)
            # live-only only when every lens that found it said so; data and trust whenever any did.
            live = "live-only" in m["flags"] and "live-only" in d["flags"]
            m["flags"] = sorted((set(m["flags"]) | set(d["flags"])) - ({"live-only"} if not live else set()))
            if m["line"] and d["line"]:
                m["end"] = max(m.get("end") or m["line"], d.get("end") or d["line"])
            for r in d["refs"]:
                if r not in m["refs"]:
                    m["refs"].append(r)
            if not m["what"]:
                m["what"] = d["what"]
            if lens not in merged[k]["lenses"]:
                merged[k]["lenses"].append(lens)
            merged[k]["bodies"].append((lens, body))
    reported = {i for k in order for _, i in merged[k]["d"]["refs"]}
    multi = len(sources) > 1
    lines = ["---", "type: evidence-review", "run-id: %s" % run_id, "created: %s" % time.strftime("%Y-%m-%dT%H:%M:%S"),
             "mode: branch", "lenses: %s" % ", ".join(l for l, _ in sources),
             "sources: %s" % ", ".join(os.path.basename(p) for _, p in sources)]
    if not multi:
        # One reviewer: its own record (call-id, fingerprint, request-sha, the charter and core it ran, a managed
        # CLAUDE.md) stays on the review the run is read from, as when the launcher writes that review itself.
        src = open(sources[0][1], encoding="utf-8", errors="replace").read()
        fm = re.match(r"^---\n(.*?)\n---\n", src, re.S)
        have = {ln.split(":", 1)[0] for ln in lines if ":" in ln}
        for ln in (fm.group(1).splitlines() if fm else []):
            k = ln.split(":", 1)[0]
            if ":" in ln and k not in have and k != "new-ground":
                lines.append(ln)
                have.add(k)
    if hunks is not None:
        lines.append("new-ground: findings outside the change since the last review are labelled missed earlier")
    lines += ["---", "",
              "# Review of run %s — %s" % (run_id, "%d lenses, merged" % len(sources) if multi else "one reviewer, with "
                                           "the branch's earlier findings"), ""]
    n = 0
    any_counted = False
    for k in order:
        e = merged[k]
        n += 1
        extra = []
        if multi:
            extra.append("found by: %s" % ", ".join(e["lenses"]))
        extra += ["%s %s" % (kind, i) for kind, i in e["d"]["refs"]]
        e["d"]["missed"] = not e["d"]["refs"] and missed_earlier(e["d"], hunks)
        if e["d"]["missed"]:
            extra.append("missed earlier (outside the change since the last review)")
        lines.append(heading(n, e["d"], extra))
        for lens, body in e["bodies"]:
            if multi:
                lines.append("From the %s lens:" % lens)
            lines.extend(body if body and body[-1].strip() else body)
        if lines[-1].strip():
            lines.append("")
        any_counted = any_counted or counted(e["d"])
    for f in earlier:
        if f["id"] in reported or f["id"] in resolved:
            continue
        n += 1
        d = {"file": f["file"], "line": f.get("line") or 0, "severity": f["severity"], "standing": f["standing"],
             "scope": f["scope"], "reach": f.get("reach"), "flags": [x for x in f.get("flags") or [] if x != "live-only"]}
        extra = ["carried %s (no review checked it)" % f["id"]]
        if f.get("regressed"):
            extra.append("regressed %s" % f["id"])      # still a regression until a review says it is fixed (review F1)
        lines.append(heading(n, d, extra))
        lines.append("What is wrong: %s" % (f.get("what") or "(as the earlier review said)"))
        lines.append("Input: as the earlier review said.")
        lines.append("How to confirm: the earlier review of this branch.")
        lines.append("")
        any_counted = True
    for lens, path in bare:
        # verdict_of refutes a review that says REFUTED and names no finding; the merge must too, or a lens that wrote
        # its findings as prose would vanish into a STANDS (review F2). Marked `unlabelled`, so the ledger skips it.
        n += 1
        lines.append("### F%d — %s — observed — in scope — HIGH — unlabelled refutation by the %s lens"
                     % (n, os.path.basename(path), lens))
        lines.append("What is wrong: the %s lens said REFUTED and named no labelled finding; read its review." % lens)
        lines.append("Input: %s." % os.path.basename(path))
        lines.append("How to confirm: read that review.")
        lines.append("")
        any_counted = True
    done = sorted((resolved & {f["id"] for f in earlier}) - reported, key=lambda i: int(i[1:]))
    if done:
        lines += ["## Earlier findings resolved", "Resolved: %s" % ", ".join(done), ""]
    lines.append("VERDICT: %s" % ("REFUTED" if any_counted else "STANDS"))
    fd, tmp = tempfile.mkstemp(prefix="review-merge-")
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    shutil.move(tmp, out)


def cmd_record(home, nn, branch, run_id, review, heads_file):
    d = load(home, nn, branch)
    text = open(review, encoding="utf-8", errors="replace").read()
    byid = {f["id"]: f for f in d["findings"]}
    earlier = [f for f in d["findings"] if f.get("status") == "open"]
    resolved = resolved_ids(text)
    again = {}      # earlier id -> the re-reports of it in this review
    new = backlog = live_n = 0
    nxt = 1 + max([int(f["id"][1:]) for f in d["findings"]] or [0])
    honour = new_ground(text)
    for parts, body in findings(text):
        desc = describe(parts, body, honour)
        if desc is None or any(p.lower().startswith("unlabelled refutation") for p in parts):
            continue
        old = [i for _, i in desc["refs"] if i in byid]
        if old:
            for i in old:
                again.setdefault(i, []).append(desc)
            continue
        # A finding that does not count is kept too: a live-only one as a required live check (promote lists the open
        # ones), the rest as backlog candidates for the operator. One already kept, at the same place with the same
        # words, is not kept twice.
        status = "open" if counted(desc) else "live check" if "live-only" in desc["flags"] else "backlog"
        # A live check is one per place, however a later review words it (review 2026-10-20, F5).
        if status != "open" and any(f.get("status") == status and f.get("file") == desc["file"]
                                    and f.get("line") == desc["line"]
                                    and (status == "live check" or f.get("what") == desc["what"])
                                    for f in d["findings"]):
            continue
        f = {"id": "L%d" % nxt, "file": desc["file"], "line": desc["line"], "severity": desc["severity"],
             "standing": desc["standing"], "scope": desc["scope"], "reach": desc["reach"], "flags": desc["flags"],
             "what": desc["what"], "status": status, "first_run": run_id, "last_run": run_id}
        if desc["missed"]:
            f["missed_earlier"] = True
        nxt += 1
        if status == "open":
            new += 1
        elif status == "backlog":
            backlog += 1
        else:
            live_n += 1
        d["findings"].append(f)
        byid[f["id"]] = f
    for i, reports in again.items():
        # Open while any re-report of it counts (review F3); its labels are those of the strongest counting one, and a
        # regression stays marked so that, carried unchecked later, it still refutes (review F1).
        f = byid[i]
        live = [r for r in reports if counted(r)]
        pick = min(live or reports, key=lambda r: (SEV.index(r["severity"]), STAND.index(r["standing"])))
        f.update(file=pick["file"], line=pick["line"], severity=pick["severity"], standing=pick["standing"],
                 scope=pick["scope"], reach=pick["reach"], flags=pick["flags"], last_run=run_id)
        f["regressed"] = any(k == "regressed" for r in reports for k, _ in r["refs"])
        f["status"] = "open" if live else "set aside"
    for f in earlier:
        if f["id"] not in again and f["id"] in resolved:
            f["status"] = "resolved"
            f["last_run"] = run_id
    heads = {}
    for ln in open(heads_file, encoding="utf-8", errors="replace"):
        rel, _, sha = ln.rstrip("\n").partition("\t")
        if rel and sha:
            heads[rel] = sha
    d["runs"].append({"run_id": run_id, "heads": heads, "at": time.strftime("%Y-%m-%dT%H:%M:%S")})
    d["runs"] = d["runs"][-20:]
    save(home, nn, d)
    ids = {f["id"] for f in earlier}
    still = sum(1 for f in d["findings"] if f["id"] in ids and f.get("status") == "open")
    gone = sum(1 for f in d["findings"] if f["id"] in ids and f.get("status") in ("resolved", "set aside"))
    print("%d %d %d %d %d %d" % (len(earlier), gone, still, new, backlog, live_n))


def cmd_live(home, nn, branch):
    """The open live checks of this window's ledger (the same key as every other read: a new lease or a promote
    starts again), for promote's decision block."""
    d = load(home, nn, branch)
    print(json.dumps([{"id": f["id"], "file": f.get("file"), "line": f.get("line") or 0, "what": f.get("what") or ""}
                      for f in d["findings"] if f.get("status") == "live check"]))


def main(argv):
    if not argv:
        die(__doc__)
    verb, a = argv[0], argv[1:]
    try:
        if verb == "size" and len(a) == 2:
            cmd_size(*a)
        elif verb == "lenses" and len(a) <= 1:
            cmd_lenses(a[0] if a else "")
        elif verb == "lens-text" and len(a) == 1:
            cmd_lens_text(a[0])
        elif verb == "key" and len(a) == 3:
            print(json.dumps(key(*a)))
        elif verb == "open" and len(a) == 5:
            cmd_open(*a)
        elif verb == "hunks" and len(a) == 3:
            cmd_hunks(*a)
        elif verb == "merge" and len(a) >= 5:
            cmd_merge(a[0], a[1], a[2], a[3], [tuple(s.split("=", 1)) for s in a[4:]])
        elif verb == "record" and len(a) == 6:
            cmd_record(*a)
        elif verb == "live" and len(a) == 3:
            cmd_live(*a)
        else:
            die("review-lenses.py: unknown verb or arguments: %s" % " ".join(argv))
    except (OSError, ValueError, KeyError) as e:
        die("review-lenses.py %s: %s" % (verb, e))


if __name__ == "__main__":
    main(sys.argv[1:])
