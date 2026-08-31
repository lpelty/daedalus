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
EXTRA_PROTECTED = ["config.yaml", "state/**", "vault/evidence/**"]


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


def target_root(root: Path) -> Optional[Path]:
    out = _lib(root, "target_path")
    return Path(out).resolve() if out else None


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


def local_settings_sha(root: Path) -> str:
    """Only the keys that change what the harness enforces. A permission
    prompt's "don't ask again" writes `allow`, which must not count."""
    p = root / ".claude" / "settings.local.json"
    try:
        data = json.loads(p.read_text())
    except (OSError, ValueError):
        data = {}
    subset = {"deny": (data.get("permissions") or {}).get("deny", []), "hooks": data.get("hooks", {})}
    return sha256_text(json.dumps(subset, sort_keys=True))


def fingerprint(root: Path) -> str:
    code, out, _ = run(["bash", str(root / "core" / "fingerprint.sh")], timeout=60)
    out = out.strip()
    return out if code == 0 and out else "null"


def protected_globs(root: Path) -> List[str]:
    globs: List[str] = []
    try:
        data = json.loads((root / ".claude" / "settings.json").read_text())
        for rule in (data.get("permissions") or {}).get("deny", []):
            m = re.fullmatch(r"Edit\((.+)\)", rule)
            if m:
                g = m.group(1)
                globs.append(g[2:] if g.startswith("./") else g)
    except (OSError, ValueError):
        pass
    for g in EXTRA_PROTECTED:
        if g not in globs:
            globs.append(g)
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


def vault_head(root: Path) -> Optional[str]:
    g, _ = vault_git(root)
    code, out, _ = run(g + ["rev-parse", "HEAD"])
    return out.strip() if code == 0 and out.strip() else None


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
    base = root / "vault" if not spec else root
    if since_sha is None and since_time is None:
        vdir = root / "vault"
        return sorted(p for p in vdir.rglob("*.md") if p.is_file())
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
    code, out, _ = run(g + ["status", "--porcelain", "--untracked-files=all"] + spec)
    if code == 0:
        for ln in out.splitlines():
            if len(ln) > 3:
                names.add(ln[3:].split(" -> ")[-1])
    docs: List[Path] = []
    for n in sorted(n for n in names if n.strip().endswith(".md")):
        p = base / n
        if p.is_file():
            docs.append(p)
    return docs


def claims(root: Path, since_sha: Optional[str], since_time: Optional[float]) -> List[Tuple[Path, Dict[str, str]]]:
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
        created = fm.get("created", "")[:19]
        if created and created < first:
            continue
        out.append((p, fm))
    return out


# --- Evidence ---------------------------------------------------------------

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
