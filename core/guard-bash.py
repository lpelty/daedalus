#!/usr/bin/env python3
"""PreToolUse(Bash) guard: the speed bump in front of the boundary check.

Denies, with a reason, pushes to main and commits on main inside the target,
destructive git, and writes whose operand resolves to a protected path of
this deployment. Relative paths resolve against the hook's `cwd`, then any
`cd <dir> &&` earlier in the same command. Fails open on its own errors,
except that an unparseable command is still checked for redirect and `-i`
operands that resolve to protected paths. Everything this guard can be
routed around is caught by boundary-hook.py from git state.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

SEPARATORS = {"&&", "||", ";", "|", "&"}
DESTRUCTIVE = [("reset", "--hard"), ("checkout", "--"), ("restore", "."), ("clean", "-f"), ("stash", "drop")]
WRITE_IN_STRING = re.compile(r"(?:>>?|\btee\b|open\(\s*['\"][^'\"]+['\"]\s*,\s*['\"][wa]|\.write_text\(|\bwrite\()")
PATHISH = re.compile(r"[A-Za-z0-9_./~-]*[A-Za-z0-9_-]+(?:\.[A-Za-z0-9]+)?")


def deny(reason: str) -> None:
    v.emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}})


def segments(tokens: List[str]) -> List[List[str]]:
    out: List[List[str]] = [[]]
    for t in tokens:
        if t in SEPARATORS:
            out.append([])
        else:
            out[-1].append(t)
    return [s for s in out if s]


def resolve(cwd: Path, p: str) -> Path:
    p = os.path.expanduser(p)
    return (cwd / p).resolve() if not os.path.isabs(p) else Path(p).resolve()


def git_repo_and_args(seg: List[str], cwd: Path) -> Tuple[Path, List[str]]:
    repo = cwd
    i = 1
    while i < len(seg) and seg[i].startswith("-"):
        if seg[i] == "-C" and i + 1 < len(seg):
            repo = resolve(repo, seg[i + 1])
            i += 2
            continue
        if seg[i] == "-c" and i + 1 < len(seg):
            i += 2
            continue
        i += 1
    return repo, seg[i:]


def under(p: Path, base: Optional[Path]) -> bool:
    if base is None:
        return False
    try:
        p.resolve().relative_to(base)
        return True
    except ValueError:
        return False


def branch_of(repo: Path) -> str:
    code, out, _ = v.run(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"])
    return out.strip() if code == 0 else ""


def check_git(seg: List[str], cwd: Path, target: Optional[Path], branch_created: bool) -> Optional[str]:
    repo, args = git_repo_and_args(seg, cwd)
    if not args:
        return None
    sub = args[0]
    rest = args[1:]
    for a, b in DESTRUCTIVE:
        if sub == a and (b in rest or (b == "-f" and any(r.startswith("-f") for r in rest))):
            if not (sub == "checkout" and rest and rest[-1] != "."):
                return "`git %s %s` destroys work; ask the operator." % (a, b)
    if sub == "push" and under(repo, target):
        if any(r in ("main", "master", "--force", "-f") or r.startswith("--force") or ":main" in r for r in rest):
            return "The operator merges; push your branch, not main."
    if sub == "commit" and under(repo, target) and not branch_created:
        if branch_of(repo) in ("main", "master"):
            return "Branch first (`git switch -c fix/<slug>`), then commit."
    return None


def write_operands(seg: List[str]) -> List[str]:
    ops: List[str] = []
    for i, t in enumerate(seg):
        if t in (">", ">>") and i + 1 < len(seg):
            ops.append(seg[i + 1])
        elif t.startswith((">", ">>")) and len(t) > 2 and t.lstrip(">"):
            ops.append(t.lstrip(">"))
    if not seg:
        return ops
    head = seg[0]
    if head == "sed" and any(t == "-i" or t.startswith("-i") for t in seg[1:]):
        ops.extend(t for t in seg[1:] if not t.startswith("-") and ("/" in t or t.endswith((".sh", ".py", ".md", ".json", ".yaml"))))
    if head == "tee":
        ops.extend(t for t in seg[1:] if not t.startswith("-"))
    if head in ("cp", "mv", "install") and len(seg) >= 3:
        ops.append(seg[-1])
    if head in ("rm", "unlink"):
        ops.extend(t for t in seg[1:] if not t.startswith("-"))
    if head == "patch":
        ops.extend(t for t in seg[1:] if not t.startswith("-"))
    if head == "git" and len(seg) >= 3 and seg[1] in ("apply", "checkout") and "--" in seg:
        ops.extend(seg[seg.index("--") + 1:])
    if head in ("python3", "python", "perl", "ruby", "node", "bash", "sh") and any(t in ("-c", "-e") for t in seg):
        for t in seg[1:]:
            if len(t) > 8 and WRITE_IN_STRING.search(t):
                ops.extend(m.group(0) for m in PATHISH.finditer(t) if "/" in m.group(0) or m.group(0).endswith((".sh", ".py", ".md", ".json", ".yaml")))
    return ops


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        cmd = str(payload["tool_input"]["command"])
        cwd = Path(payload.get("cwd") or v.ROOT).resolve()
    except Exception:
        return 0
    root = v.ROOT
    target = v.target_root(root)
    try:
        tokens = shlex.split(cmd, posix=True)
    except ValueError:
        # Unparseable (a heredoc with an apostrophe): check only redirect / -i operands.
        for m in re.finditer(r"(?:>>?|\s-i(?:\s+\S+)?\s)\s*([A-Za-z0-9_./~-]+)", cmd):
            p = resolve(cwd, m.group(1))
            if v.is_protected(root, p):
                deny("%s is distribution code; write a proposal instead of editing it." % p)
                return 0
        return 0
    try:
        branch_created = False
        here = cwd
        for seg in segments(tokens):
            if not seg:
                continue
            if seg[0] == "cd" and len(seg) >= 2:
                here = resolve(here, seg[1])
                continue
            if seg[0] == "git":
                _, args = git_repo_and_args(seg, here)
                if args[:2] in (["switch", "-c"], ["checkout", "-b"]):
                    branch_created = True
                reason = check_git(seg, here, target, branch_created)
                if reason:
                    deny(reason)
                    return 0
            for op in write_operands(seg):
                p = resolve(here, op)
                if v.is_protected(root, p):
                    deny("%s is distribution code (or evidence); write a proposal instead of editing it." % p)
                    return 0
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
