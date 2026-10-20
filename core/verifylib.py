#!/usr/bin/env python3
"""Shared logic for the verify stage: where things are, what counts as a
claim, how evidence is read, and how a hook speaks.

Imported by session-start.py, verify-hook.py, boundary-hook.py, and
guard-bash.py the way recall-inject.py imports capture.py: one implementation
of each rule, sited in one file. Python 3.9, standard library only.
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
from typing import Dict, List, Optional, Tuple

OWN_PARTY = "daedalus"
CLAIM_EXCLUDED_TYPES = {"session", "pitfall", "rolling-state", "evidence"}
# CLAUDE.md is here as well as in the tracked deny list, so it stays protected in a home whose
# tracked settings.json lost that rule (update design Decision 3, §4.4).
EXTRA_PROTECTED = ["CLAUDE.md", "config.yaml", "state/**", "vault/evidence/**"]
BRIEF = "CLAUDE.md"               # distribution code: the release's brief, never written by the agent
LOCAL_BRIEF = "CLAUDE.local.md"   # the deployment's brief, gitignored; the agent's only when boundary.edit_brief is true


def root_dir() -> Path:
    env = os.environ.get("DAEDALUS_HOME")
    return Path(env).resolve() if env else Path(__file__).resolve().parent.parent


ROOT = root_dir()


def run(cmd: List[str], cwd: Optional[Path] = None, timeout: int = 20) -> Tuple[int, str, str]:
    try:
        r = subprocess.run(cmd, cwd=str(cwd) if cwd else None, capture_output=True,
                           text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", str(e)


def _lib(root: Path, snippet: str) -> str:
    lib = root / "core" / "lib.sh"
    if not lib.is_file():
        return ""
    code, out, _ = run(["bash", "-c", 'source "$1"; ' + snippet, "_", str(lib)], timeout=5)
    return out.strip() if code == 0 else ""


NO_LIB = "no core/lib.sh"


def _lib_full(root: Path, snippet: str, timeout: int = 5) -> Tuple[int, str, str]:
    lib = root / "core" / "lib.sh"
    if not lib.is_file():
        return 127, "", NO_LIB
    return run(["bash", "-c", 'source "$1"; ' + snippet, "_", str(lib)], timeout=timeout)


# --- Tri-state target resolution (§4.4) --------------------------------------

class Resolved:
    def __init__(self, path: Path) -> None:
        self.path = path


class Unconfigured:
    def __init__(self, reason: str) -> None:
        self.reason = reason


class Refused:
    def __init__(self, sentence: str) -> None:
        self.sentence = sentence


def export_session(payload: dict) -> Optional[str]:
    """Every Python hook: the payload's session_id is the ONLY session identity a
    hook may use (§4.2). Exported before any lib.sh / fingerprint / gates call."""
    sid = payload.get("session_id")
    if sid:
        os.environ["DAEDALUS_SESSION_ID"] = str(sid)
    os.environ["DAEDALUS_HOOK_PID"] = str(os.getpid())
    return str(sid) if sid else None


def resolve_target(root: Path, session_id: Optional[str], timeout: int = 5):
    """Tri-state, never None (§4.4). The bash seam: lib.sh target_path with the
    session id exported; a non-zero exit whose stderr carries a `daedalus:`
    sentence is Refused, any other failure is Unconfigured — except a seam
    that never answered. `leaselib.py resolve` takes LOCK_SH, so while a
    neighbour's SessionStart holds LOCK_EX through its worktree adds this
    call waits; when it runs out of `timeout` (v.run's 127) the tree is
    simply not known, and not-known fails CLOSED: Refused, with a sentence
    that says so. Mapping it to Unconfigured would write a marker with
    neither target_base nor target_base_error — the silent fail-open the
    tri-state exists to remove (Task 6 review). session-start.py passes the
    budget it has left; every other consumer keeps the 5 s default."""
    if session_id:
        os.environ["DAEDALUS_SESSION_ID"] = str(session_id)
    code, out, err = _lib_full(root, "target_path", timeout=timeout)
    if code == 0 and out.strip():
        return Resolved(Path(out.strip()).resolve())
    if code == 127 and err != NO_LIB:
        if "timed out" in (err or ""):
            return Refused("the lease resolution did not answer within %d s (another window was probably being "
                           "set up at the same moment), so the tree this session builds in is not known. Start a "
                           "fresh window; if this line comes back, check for a stuck `git worktree add` and run "
                           "`core/lease.sh sweep`." % timeout)
        return Refused("the lease resolution could not be run (%s), so the tree this session builds in is not known."
                       % ((err or "").strip() or "no reason given"))
    sentence = ""
    for ln in (err or "").splitlines():
        if ln.startswith("daedalus: "):
            sentence = ln[len("daedalus: "):]
    if code == 3 or (sentence and ("window" in sentence or "sessions are live" in sentence or "DAEDALUS_" in sentence)):
        return Refused(sentence or "the lease resolution failed without a reason")
    return Unconfigured(sentence or (err or "").strip() or "target not configured")


def target_branch(root: Path) -> str:
    """config.yaml target.branch; 'main' when unset. PROP-019: the promotion gate must
    read this instead of assuming 'main' — a target on any other branch name had an
    inert gate that reported itself skipped."""
    out = _lib(root, "cfg target.branch 2>/dev/null || true").strip()
    return out or "main"


def nested_relpaths(root: Path) -> List[str]:
    out = _lib(root, "cfg target.nested >/dev/null 2>&1 && cfg_pairs target.nested | cut -f1")
    return [ln for ln in out.splitlines() if ln.strip()]


def sha256_text(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def sha256_file(p: Path) -> str:
    try:
        return hashlib.sha256(p.read_bytes()).hexdigest()
    except OSError:
        return ""


CONFIG_CHANGES = Path("state") / "config-changes.json"


def home_version(root: Path) -> Optional[str]:
    """VERSION's first line when it is X.Y.Z, else None — the same rule as upgrade.version."""
    try:
        first = (root / "VERSION").read_text().split("\n", 1)[0].strip()
    except OSError:
        return None
    return first if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", first) else None


def local_settings_sha(root: Path) -> str:
    """Only the keys that change what the harness enforces. A permission
    prompt's "don't ask again" writes `allow`, which must not count.
    `disableAllHooks` is included because it is a single-key way to turn off
    every hook this stage depends on — the same enforcement-relevant class
    as `deny` and `hooks`, not the operator's own business like `allow`."""
    p = root / ".claude" / "settings.local.json"
    try:
        data = json.loads(p.read_text())
    except (OSError, ValueError):
        data = {}
    subset = {"deny": (data.get("permissions") or {}).get("deny", []), "hooks": data.get("hooks", {}),
              "disableAllHooks": data.get("disableAllHooks", False)}
    return sha256_text(json.dumps(subset, sort_keys=True))


def fingerprint(root: Path) -> str:
    code, out, _ = run(["bash", str(root / "core" / "fingerprint.sh")], timeout=60)
    out = out.strip()
    return out if code == 0 and out else "null"


def home_relative_glob(root: Path, pattern: str) -> Optional[str]:
    """A deny rule's path pattern as a glob relative to the home, or None when
    it cannot name a file under the home. Claude Code's anchors (docs,
    "Configure permissions"): `//path` is absolute; `~/path` is the user's
    home; `/path` is anchored at the settings source, which for
    .claude/settings.json is the primary working directory, i.e. this home;
    `./path` is relative to the session's current directory, which is this
    home only while nothing has changed directory. A bare `path` is read
    here as anchored at the home too (Claude Code matches it at any depth;
    the shipped rules never use that form). A trailing slash names the
    directory and everything in it, as gitignore reads it. The shipped
    rules use `/path`; a deployment that committed them absolute (seen
    2026-10-13 on another laptop) is read the same way instead of silently
    protecting nothing. The home itself is never a rule."""
    g = pattern
    if g.startswith("//"):
        try:
            g = Path(g[1:]).resolve().relative_to(root.resolve()).as_posix()
        except ValueError:
            return None
        if pattern.endswith("/"):
            g += "/"
    elif g.startswith("~"):
        return None
    elif g.startswith("./"):
        g = g[2:]
    elif g.startswith("/"):
        g = g[1:]
    if g.endswith("/"):
        g = g.rstrip("/") + "/**"
    if g in ("", ".", "/**", "./**"):
        return None
    return g


_EDIT_BRIEF: Dict[str, Tuple[Tuple[float, int], bool]] = {}


def edit_brief(root: Path) -> bool:
    """config.yaml boundary.edit_brief, read with lib.sh cfg: True only for the word `true`
    (anything else, an absent key or an unreadable config is False). Cached per process on the
    config file's mtime and size, because is_protected asks once per Bash write operand."""
    conf = Path(os.environ.get("DAEDALUS_CONFIG") or (root / "config.yaml"))
    try:
        st = conf.stat()
        key = (st.st_mtime, st.st_size)
    except OSError:
        return False
    hit = _EDIT_BRIEF.get(str(conf))
    if hit is not None and hit[0] == key:
        return hit[1]
    val = _lib(root, "cfg boundary.edit_brief 2>/dev/null || true").strip() == "true"
    _EDIT_BRIEF[str(conf)] = (key, val)
    return val


def local_brief_sha(root: Path) -> str:
    """CLAUDE.local.md's content hash ("" when absent). It is gitignored, so protected_status
    never sees it; the session-start marker records this and the Stop check compares it while
    boundary.edit_brief is false."""
    return sha256_file(root / LOCAL_BRIEF)


def _deny_globs(root: Path, name: str) -> List[str]:
    out: List[str] = []
    try:
        data = json.loads((root / ".claude" / name).read_text())
        for rule in (data.get("permissions") or {}).get("deny", []):
            m = re.fullmatch(r"Edit\((.+)\)", rule) if isinstance(rule, str) else None
            if m:
                g = home_relative_glob(root, m.group(1))
                if g is not None:
                    out.append(g)
    except (OSError, ValueError, AttributeError):
        pass
    return out


def protected_globs(root: Path) -> List[str]:
    """The Edit(...) deny rules of .claude/settings.json AND .claude/settings.local.json (a local
    deny the update moved out of the tracked file stays enforced on the Bash leg and at Stop,
    Decision 22), EXTRA_PROTECTED, and CLAUDE.local.md unless boundary.edit_brief is true."""
    globs: List[str] = []
    for g in _deny_globs(root, "settings.json") + _deny_globs(root, "settings.local.json") + EXTRA_PROTECTED:
        if g not in globs:
            globs.append(g)
    if LOCAL_BRIEF not in globs and not edit_brief(root):
        globs.append(LOCAL_BRIEF)
    return globs


def protected_pathspecs(root: Path) -> List[str]:
    return [g[:-3] if g.endswith("/**") else g for g in protected_globs(root)]


def is_protected(root: Path, path: Path) -> bool:
    """A resolved path is protected when it is under the Daedalus root, not
    under target/ or vault/ (except vault/evidence), and matches a glob."""
    try:
        rel = path.resolve().relative_to(root).as_posix()
    except ValueError:
        return False
    if rel.startswith("target/") or (rel.startswith("vault/") and not rel.startswith("vault/evidence")):
        return False
    for g in protected_globs(root):
        base = g[:-3] if g.endswith("/**") else None
        if base is not None and (rel == base or rel.startswith(base + "/")):
            return True
        if base is None and rel == g:
            return True
    return False


def protected_status(root: Path) -> List[str]:
    specs = protected_pathspecs(root)
    code, out, _ = run(["git", "-C", str(root), "status", "--porcelain", "--untracked-files=all", "--"] + specs)
    return sorted(ln for ln in out.splitlines() if ln.strip()) if code == 0 else []


def protected_snapshot(root: Path) -> Dict[str, Dict[str, str]]:
    """Per-path detail behind protected_status's lines: the porcelain line
    plus a content hash, keyed by path. A porcelain line alone conflates
    "this path has dirt" with "this path's content is dirt" — a file that
    was already dirty at session start (operator-owned) can be edited
    further while its line stays the same two letters, and the reverse
    (staging with no content change) flips the line without changing
    content. Hashing lets check 1 key on content, not on git's status
    letters. Content hash is of the current working-tree file (empty
    string's hash for a path git reports but that no longer exists, e.g.
    a delete)."""
    out: Dict[str, Dict[str, str]] = {}
    for ln in protected_status(root):
        path = ln[3:].split(" -> ")[-1].strip().strip('"')
        p = root / path
        sha = sha256_file(p) if p.is_file() else ""
        out[path] = {"line": ln, "sha": sha}
    return out


# --- Marker -----------------------------------------------------------------

def _safe(s: object) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", str(s or "")) or "none"


def marker_path(root: Path, session_id: object) -> Path:
    return root / "state" / ("session-%s.json" % _safe(session_id))


def read_marker(root: Path, session_id: object) -> Optional[dict]:
    try:
        d = json.loads(marker_path(root, session_id).read_text())
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


# --- Frontmatter and claims -------------------------------------------------

def parse_frontmatter(text: str) -> Dict[str, str]:
    text = text.lstrip("﻿")
    lines = [ln.rstrip("\r") for ln in text.split("\n")]
    if not lines or lines[0].strip() != "---":
        return {}
    fm: Dict[str, str] = {}
    for ln in lines[1:]:
        if ln.strip() == "---":
            break
        if not ln.strip() or ln[0] in " \t" or ":" not in ln:
            continue
        k, _, v = ln.partition(":")
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        fm[k.strip().lower()] = v
    return fm


def is_own(fm: Dict[str, str]) -> bool:
    v = (fm.get("updated-by") or fm.get("from") or fm.get("author") or "").strip().lower()
    return v in ("", OWN_PARTY) or v.startswith("<")


def is_claim_shaped(fm: Dict[str, str]) -> bool:
    if fm.get("type", "").strip().lower() in CLAIM_EXCLUDED_TYPES:
        return False
    return fm.get("status", "").strip().upper() == "IMPLEMENTED" or fm.get("kind", "").strip().lower() == "completion"


def first_evidence_date(root: Path) -> Optional[str]:
    dates: List[str] = []
    ev = root / "vault" / "evidence"
    if ev.is_dir():
        for f in ev.glob("*.md"):
            try:
                c = parse_frontmatter(f.read_text()).get("created", "")
            except OSError:
                continue
            if c:
                dates.append(c[:19])
    return min(dates) if dates else None


def vault_git(root: Path) -> Tuple[List[str], List[str]]:
    if (root / "vault" / ".git").exists():
        return ["git", "-C", str(root / "vault")], []
    return ["git", "-C", str(root)], ["--", "vault"]


def vault_git_base(root: Path, g: List[str], spec: List[str]) -> Path:
    """The directory git's repo-relative names (status --porcelain, diff
    --name-only) resolve against: the vault for its own repository; otherwise
    the top level of the repository that tracks it, which is the home or —
    a home inside a larger repository — some ancestor of it. The home itself
    is the fallback when git cannot say."""
    if not spec:
        return root / "vault"
    code, out, _ = run(g + ["rev-parse", "--show-toplevel"], timeout=5)
    return Path(out.strip()) if code == 0 and out.strip() else root


def vault_head(root: Path) -> Optional[str]:
    g, _ = vault_git(root)
    code, out, _ = run(g + ["rev-parse", "HEAD"])
    return out.strip() if code == 0 and out.strip() else None


class VaultLocked(Exception):
    """vault/.git/index.lock held for three retries a second apart (§3.3);
    str(e) is the operator sentence."""


VAULT_LOCKED = "the vault index is locked (another session is committing); try again"
VAULT_STATUS_RETRIES = 3


def _vault_index_lock(g: List[str]) -> Optional[Path]:
    """The index.lock path of the repository `g` addresses (git's own answer, so a
    linked worktree's private git dir is honoured); None when git cannot say."""
    code, out, _ = run(g + ["rev-parse", "--absolute-git-dir"], timeout=5)
    return Path(out.strip()) / "index.lock" if code == 0 and out.strip() else None


def _vault_status(g: List[str], spec: List[str]) -> str:
    """`git status --porcelain` of the vault, retried three times a second apart
    while another session is committing (§3.3), then VaultLocked — fail closed,
    never a silent "no claims found". Two signals count as meeting the lock:
    git refusing with "index.lock" on stderr, and the lock file itself being
    present — `git status` (2.50) exits 0 under a held index.lock (it merely
    skips its opportunistic index refresh), so the exit code alone would never
    see the commit in flight."""
    lock = _vault_index_lock(g)
    for attempt in range(VAULT_STATUS_RETRIES):
        code, out, err = run(g + ["status", "--porcelain", "--untracked-files=all"] + spec)
        if code == 0 and not (lock is not None and lock.exists()):
            return out
        if code != 0 and "index.lock" not in (err or ""):
            return ""
        if attempt < VAULT_STATUS_RETRIES - 1:
            time.sleep(1)
    raise VaultLocked(VAULT_LOCKED)


def changed_vault_docs(root: Path, since_sha: Optional[str], since_time: Optional[float]) -> List[Path]:
    """Three modes, selected by which of since_sha/since_time is given:
    whole-vault (both None) — every *.md under vault/, recursive, committed
    or not, for a crash-recovery/doctor sweep with no prior marker to anchor
    to; since-sha — files changed between since_sha and the working tree;
    since-time — files changed in commits since since_time. The two windowed
    modes also union in live `git status` dirt, since an uncommitted claim
    is still a claim; the whole-vault mode already covers dirt because it
    lists everything on disk, so the status union is skipped there."""
    g, spec = vault_git(root)
    if since_sha is None and since_time is None:
        vdir = root / "vault"
        return sorted(p for p in vdir.rglob("*.md") if p.is_file())
    base = vault_git_base(root, g, spec)
    names: set = set()
    if since_sha:
        code, out, _ = run(g + ["diff", "--name-only", since_sha] + spec)
        if code == 0:
            names.update(out.splitlines())
    elif since_time:
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(since_time))
        code, out, _ = run(g + ["log", "--since=" + stamp, "--name-only", "--pretty=format:"] + spec)
        if code == 0:
            names.update(out.splitlines())
    for ln in _vault_status(g, spec).splitlines():
        if len(ln) > 3:
            names.add(ln[3:].split(" -> ")[-1])
    docs: List[Path] = []
    for n in sorted(n for n in names if n.strip().endswith(".md")):
        p = base / n
        if p.is_file():
            docs.append(p)
    return docs


def doc_lease(fm: Dict[str, str]) -> str:
    """The `lease:` a claim document carries, two digits or empty; a trailing
    `# comment` (the template's own hint) is not a value."""
    return fm.get("lease", "").split("#", 1)[0].strip()


def claims(root: Path, since_sha: Optional[str], since_time: Optional[float],
           lease: Optional[str] = None) -> List[Tuple[Path, Dict[str, str]]]:
    """Claim-shaped documents of Daedalus's in the window, attributed by their
    `lease:` field (§4.9): lease="*" answers for every claim (the prime's
    commit, --doctor, the offline sweep); a window's number answers only for
    claims carrying that number; None — an unleased or visiting caller —
    answers only for claims that carry no lease. May raise VaultLocked (§3.3)."""
    first = first_evidence_date(root)
    if first is None:
        return []
    out: List[Tuple[Path, Dict[str, str]]] = []
    for p in changed_vault_docs(root, since_sha, since_time):
        try:
            fm = parse_frontmatter(p.read_text())
        except OSError:
            continue
        if not is_claim_shaped(fm) or not is_own(fm):
            continue
        if lease != "*" and doc_lease(fm) != (lease or ""):
            continue
        created = fm.get("created", "")[:19]
        if created and created < first:
            continue
        out.append((p, fm))
    return out


# --- Evidence ---------------------------------------------------------------

def manifest_paths(root: Path) -> set:
    """Resolved paths listed in vault/evidence/.manifest — the files gates.sh
    says it wrote. One reader for boundary-hook's two checks."""
    out: set = set()
    mp = root / "vault" / "evidence" / ".manifest"
    try:
        for ln in mp.read_text().splitlines():
            ln = ln.strip()
            if ln:
                out.add(str(Path(ln).resolve()))
    except OSError:
        pass
    return out


def run_record(root: Path, run_id: str) -> Optional[dict]:
    if not re.fullmatch(r"[0-9]{8}-[0-9]{6}-[0-9a-f]{6}", run_id or ""):
        return None
    rj = root / "state" / "evidence" / run_id / "run.json"
    try:
        d = json.loads(rj.read_text())
        if isinstance(d, dict):
            d.setdefault("source", "state")
            return d
    except (OSError, ValueError):
        pass
    md = root / "vault" / "evidence" / (run_id + ".md")
    try:
        fm = parse_frontmatter(md.read_text())
    except OSError:
        return None
    if not fm:
        return None
    return {"result": fm.get("result", ""), "fingerprint": fm.get("fingerprint", ""),
            "config_sha": fm.get("config-sha", ""), "gates": [], "source": "vault"}


PROMO_REFUSED = "%s cites a promotion's gate run (%s); a window's claim needs its own core/gates.sh run"
PROMO_LATER = "; once the promotion is confirmed and pushed, its run stands behind this window's claim while the window has no new work."
PROMO_NEW_WORK = "; run core/gates.sh in window %s and cite that run."


def is_promotion_run(rec: dict) -> bool:
    """A promotion's gate run (gates.sh --promote): PASS with its reviewer deferred to core/promote.sh."""
    return bool(rec.get("tree") == "promote-scratch" or rec.get("refuter") == "deferred-to-promote" or rec.get("promote_id"))


def _read_record(p: Path) -> Optional[dict]:
    try:
        d = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    return d if isinstance(d, dict) else None


def promotion_vouches(root: Path, rec: dict, fm: Dict[str, str], doc: object = "") -> Optional[str]:
    """None when a promotion's PASS run may stand behind this claim (update-command
    Decision 11), else the refusal naming the first condition that fails. It may
    when the promotion was confirmed and pushed for the claim's own window, that
    push is the merge the run tested, lease/NN is still at the tip it promoted and
    worktrees/NN holds no uncommitted change: after a promote the window's own run
    has an empty diff the refuter cannot certify, but new work needs its own run."""
    rid, pid = str(rec.get("run_id") or fm.get("evidence-run", "")), str(rec.get("promote_id") or "")
    head = PROMO_REFUSED % (doc, rid)
    if not re.fullmatch(r"[0-9A-Za-z-]+", pid):
        return head + PROMO_LATER
    pdir = root / "state" / "promote" / pid
    p = _read_record(pdir / "prepared.json")
    if p is None:
        return head + ", and promotion %s has no readable prepared record (state/promote/%s/prepared.json)%s" % (pid, pid, PROMO_LATER)
    if str(p.get("run_id") or "") != rid:
        return head + ", and promotion %s's prepared record names run %s, not this one." % (pid, p.get("run_id"))
    if not p.get("confirmed_at"):
        return head + ", and promotion %s was not confirmed%s" % (pid, PROMO_LATER)
    pushed = _read_record(pdir / "pushed")
    if pushed is None:
        return head + ", and promotion %s was not pushed%s" % (pid, PROMO_LATER)
    repo, merge = str(p.get("repo") or ""), str(p.get("merge_sha") or "")
    outer = str(rec.get("repo") or repo).split("/", 1)[0]
    # The run records the outer repo's merge; a nested repo's is under nested/<rel> (as promote reads it).
    tested = str(rec.get("merge_sha") or "") if repo == outer or "/" not in repo else \
        str(((rec.get("nested") or {}).get(repo.split("/", 1)[1]) or {}).get("merge_sha") or "")
    if str(pushed.get("merge_sha") or "") != merge or tested != merge:
        return head + ", and promotion %s pushed merge %s, not the merge this run tested (%s)." % (
            pid, str(pushed.get("merge_sha") or "none")[:7], (tested or "none")[:7])
    nn, mine = str(p.get("lease") or ""), doc_lease(fm)
    if str(rec.get("lease") or "") != nn or mine != nn:
        return head + ", and promotion %s is window %s's, not this claim's window (%s)." % (
            pid, nn, ("lease: %s" % mine) if mine else "it carries no lease:")
    code, tip, err = run(["git", "-C", str(root / "target" / repo), "rev-parse", "--verify", "-q", "refs/heads/lease/%s" % nn])
    tip = tip.strip()
    if code != 0 or not tip:
        return head + ", and lease/%s cannot be read in target/%s, so the window's new work cannot be ruled out%s" % (
            nn, repo, PROMO_NEW_WORK % nn)
    if tip != str(p.get("lease_tip") or ""):
        return head + ", and lease/%s has new work committed since promotion %s (now at %s, promoted at %s)%s" % (
            nn, pid, tip[:7], str(p.get("lease_tip") or "")[:7], PROMO_NEW_WORK % nn)
    import leaselib as ll
    for r in ll.repos_of(root):
        try:
            dirty = ll.dirty_files(root / "worktrees" / nn / r)
        except ll.Refused as e:
            return head + ", and %s%s" % (e, PROMO_NEW_WORK % nn)
        if dirty:
            return head + ", and worktrees/%s/%s has uncommitted changes since promotion %s (%s)%s" % (
                nn, r, pid, ", ".join(dirty[:5]) + (" and %d more" % (len(dirty) - 5) if len(dirty) > 5 else ""),
                PROMO_NEW_WORK % nn)
    return None


def transcript_first_ts(path: object) -> Optional[float]:
    try:
        with open(str(path), "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    ts = json.loads(line).get("timestamp")
                except ValueError:
                    continue
                if isinstance(ts, str) and len(ts) >= 19:
                    return time.mktime(time.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S"))
    except OSError:
        pass
    return None


# --- Hook output ------------------------------------------------------------

def emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj))
    sys.stdout.flush()


def block(reason: str) -> None:
    sys.stderr.write(reason.rstrip() + "\n")
    sys.stderr.flush()
    sys.exit(2)


# --- No Stop hook may lock a session (v0.12.4) ---------------------------------------------------------------------
# A Stop hook's block re-prompts the agent, and Claude Code fires Stop again (stop_hook_active true). A reason the agent
# cannot resolve alone — it needs the operator's answer, or a restart — blocked every re-fire: 9 in a row until Claude
# Code overrode the hook (2026-10-19), and on another deployment every turn after a `!` command until the session
# locked up. The operator has no turn while that happens. So every blocking Stop hook passes its reasons through
# stop_once: a reason blocks at most once a turn — re-fired, a reason already said is a note, and the turn ends — and
# a new reason may block once on a re-fire, never twice. A reason keyed to the session (session_keys: a file read at
# session start, at one hash) blocks once a session. Nothing else changes: the next turn's Stop says a turn-scoped
# reason again, once, so what blocked still blocks.
WAY_BACK = ("If you cannot resolve this yourself — it needs the operator's answer, or a restart — ask the operator "
            "once, in one message, and end your turn: this Stop does not block twice for the same reason.")


def stop_state_path(root: Path, session_id: object, hook: str) -> Path:
    """state/session-<sid>-stop-<hook>.json, under session-start.py's prune of session-<sid>-* (§4.10)."""
    return root / "state" / ("session-%s-stop-%s.json" % (_safe(session_id), _safe(hook)))


def stop_once(root: Path, session_id: object, hook: str, reasons: List[str], active: bool,
              session_keys: Optional[dict] = None) -> "tuple":
    """(the reasons that block this Stop, the ones that become notes). `active` is the payload's stop_hook_active:
    true on a Stop Claude Code fired again after a blocked one. session_keys maps a reason to its once-a-session key."""
    keys = session_keys or {}
    p = stop_state_path(root, session_id, hook)
    try:
        st = json.loads(p.read_text())
        st = st if isinstance(st, dict) else {}
    except (OSError, ValueError):
        st = {}
    if not reasons:
        # A clean Stop still ends a turn: a new turn's state starts empty, so last turn's re-fire block can never
        # turn a reason this turn into a note (review 2026-10-20, F3). Nothing to write when there is nothing to clear.
        if not active and (st.get("turn") or st.get("refire_blocks")):
            st.update(turn=[], refire_blocks=0)
            try:
                tmp = p.with_name(p.name + ".tmp")
                tmp.write_text(json.dumps(st))
                tmp.replace(p)
            except OSError:
                pass
        return [], []
    told_turn = [k for k in st.get("turn") or [] if isinstance(k, str)]
    told_session = [k for k in st.get("session") or [] if isinstance(k, str)]
    refires = st.get("refire_blocks") if isinstance(st.get("refire_blocks"), int) else 0
    if not active:
        told_turn, refires = [], 0              # a new turn: the operator has had control since
    blocks: List[str] = []
    notes: List[str] = []
    for r in reasons:
        k = keys.get(r) or hashlib.sha256(r.encode("utf-8", "replace")).hexdigest()
        if k in told_session or k in told_turn or (active and refires >= 1):
            notes.append(r)
            continue
        blocks.append(r)
        (told_session if r in keys else told_turn).append(k)
    if blocks and active:
        refires += 1
    st.update(turn=told_turn, session=told_session, refire_blocks=refires)
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(json.dumps(st))
        tmp.replace(p)
    except OSError:
        if active:                              # unrecorded, a re-fire could block again: hand the turn back instead
            notes, blocks = blocks + notes, []
    return blocks, notes


def stop_untell(root: Path, session_id: object, hook: str, prefix: str) -> None:
    """Forget the once-a-session keys starting with <prefix> (a file put back to the session's snapshot)."""
    p = stop_state_path(root, session_id, hook)
    try:
        st = json.loads(p.read_text())
    except (OSError, ValueError):
        return
    if not isinstance(st, dict) or not any(isinstance(k, str) and k.startswith(prefix) for k in st.get("session") or []):
        return
    st["session"] = [k for k in st.get("session") or [] if not (isinstance(k, str) and k.startswith(prefix))]
    try:
        tmp = p.with_name(p.name + ".tmp")
        tmp.write_text(json.dumps(st))
        tmp.replace(p)
    except OSError:
        pass


def stop_told(root: Path, session_id: object, hook: str, key: str) -> bool:
    try:
        st = json.loads(stop_state_path(root, session_id, hook).read_text())
    except (OSError, ValueError):
        return False
    return isinstance(st, dict) and key in (st.get("session") or [])


# --- Trees and the per-hook lease read (§4.4, §4.6) --------------------------

def repo_relative(root: Path, path: Path):
    """(tree_root, rel) for an absolute operand under target/<repo>/,
    worktrees/<NN>/<repo>/ or state/promote/<id>/<repo>/ — the deepest
    repository the operand lies in (a nested repo wins over its outer). None
    when the operand is outside every tree. Lexical: needs no lease (§4.4)."""
    try:
        rel = Path(path).resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None
    parts = rel.split("/")
    if parts[:1] == ["target"] and len(parts) >= 2:
        base, rest = parts[:2], parts[2:]
    elif parts[:1] == ["worktrees"] and len(parts) >= 3 and re.fullmatch(r"[0-9]{2}", parts[1]):
        base, rest = parts[:3], parts[3:]
    elif parts[:2] == ["state", "promote"] and len(parts) >= 4:
        base, rest = parts[:4], parts[4:]
    else:
        return None
    for n in nested_relpaths(root):
        npart = n.split("/")
        if rest[:len(npart)] == npart:
            base, rest = base + npart, rest[len(npart):]
            break
    return root.resolve().joinpath(*base), "/".join(rest)


def _empty_lease_context() -> dict:
    return {"leases": {}, "changed": {}, "mine": None, "prime": False, "prime_nn": None,
            "liveness": {}, "refused": None, "unreadable": None}


def lease_context(root: Path, session_id: Optional[str]) -> dict:
    """One locked read of state/leases/ and every .changed sidecar (§4.6 budget
    rule); liveness with stale_after read once; the §4.4 refusal computed
    in-process from the same read — no bash, no second python. A deployment
    with no state/leases/ directory yet gets the empty context without
    importing leaselib or creating the lock file. A lease file that cannot be
    read is the same refusal lease.sh gives (fail closed for a session)."""
    if not (root / "state" / "leases").is_dir():
        return _empty_lease_context()
    import leaselib as ll
    ctx = _empty_lease_context()
    try:
        with ll.lock(root, shared=True):
            leases = ll.read_all(root)
            changed = {nn: ll.read_changed(root, nn) for nn in leases if nn != "prime"}
    except ll.Refused as e:
        # `unreadable` regardless of session: the leases could not be READ, so the empty
        # context vouches for nothing — a caller judging other windows' liveness (the RUNNING
        # excuse) must not read {} as "every window is gone". `refused` keeps its session gate.
        ctx["unreadable"] = str(e)
        if session_id:
            ctx["refused"] = str(e)
        return ctx
    mine, _ = ll.lease_of_session(leases, session_id or "")
    prime_sid = (leases.get("prime") or {}).get("session_id")
    prime_nn, _ = ll.lease_of_session(leases, str(prime_sid)) if prime_sid else (None, None)
    now, quiet_after = time.time(), ll.stale_after_secs(root)
    live = {nn: ll.liveness(root, nn, d, now, quiet_after) for nn, d in leases.items() if nn != "prime"}
    refused = None
    if session_id and leases:
        try:
            ll.resolve_lease(leases, session_id, ll.pending_stop(root))
        except ll.Refused as e:
            refused = str(e)
    ctx.update({"leases": leases, "changed": changed, "mine": mine,
                "prime": bool(session_id) and prime_sid == session_id,
                "prime_nn": prime_nn, "liveness": live, "refused": refused})
    return ctx


# --- The prime's vault commit (§4.7) ------------------------------------------

def vault_claim_report(root: Path) -> List[dict]:
    """Every claim-shaped changed/untracked vault *.md, whatever `lease:` it
    carries, with the lease's liveness and the plain-language problem an
    unverified claim has (§4.7 rules 3–4). `live` is judged from one locked
    read of state/leases/ (lease_context): a lease with no file, or a stale
    one, is not live — its claim is the prime's to answer for. `own` marks
    the caller's own lease (its claim is judged, never left out). May raise
    VaultLocked (§3.3), or leaselib.Refused when a lease file cannot be read:
    an unreadable lease vouches for nothing, so no claim is judged — a
    `live: false` row would hand a possibly-live window's claim to the
    prime (or an operator shell, which no `is-prime` step guards) to stage.
    Fails closed like verify-hook and boundary-hook (Task 16 review)."""
    ctx = lease_context(root, session_id_of_caller())
    if ctx["unreadable"]:
        import leaselib as ll
        raise ll.Refused(ctx["unreadable"])
    out: List[dict] = []
    for p, fm in claims(root, vault_head(root), None, lease="*"):
        rid = fm.get("evidence-run", "")
        rec = run_record(root, rid) if rid else None
        problem = None
        if not rid:
            problem = ("%s claims IMPLEMENTED with no evidence-run: run core/gates.sh and cite the run-id, "
                       "or change the status." % p.name)
        elif rec is None:
            problem = "%s cites evidence-run %s, which does not exist." % (p.name, rid)
        elif rec.get("result") != "PASS":
            problem = "%s cites evidence-run %s, whose result is %s." % (p.name, rid, rec.get("result"))
        lease = doc_lease(fm)
        out.append({"path": str(p), "lease": lease,
                    "live": ctx["liveness"].get(lease) in ("live", "quiet", "resumed"),
                    "own": bool(lease) and lease == ctx["mine"], "problem": problem})
    return out


def session_id_of_caller() -> Optional[str]:
    """A script's session identity (§4.2): DAEDALUS_SESSION_ID, else
    CLAUDE_CODE_SESSION_ID, else CLAUDE_PID through the registry; None is an
    operator shell. The one implementation lives in leaselib."""
    import leaselib as ll
    return ll.session_id_from_env()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--vault-claims"]:
        import leaselib as ll
        try:
            for row in vault_claim_report(ROOT):
                print(json.dumps(row))
        except (VaultLocked, ll.Refused) as e:
            sys.stderr.write("daedalus: %s\n" % e)
            sys.exit(1)
        sys.exit(0)
    sys.stderr.write("usage: verifylib.py --vault-claims\n")
    sys.exit(2)
