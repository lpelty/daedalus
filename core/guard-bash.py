#!/usr/bin/env python3
"""PreToolUse(Bash) guard: the speed bump in front of the boundary check.

Denies, with a reason, pushes to the trunk and commits on the trunk inside
the target, destructive git, and writes whose operand resolves to a protected
path of this deployment. The trunk is config.yaml target.branch, read through
verifylib.target_branch — never a hardcoded "main": a GitLab deployment whose
trunk is `mainline` had a guard that denied `main` and let `mainline` through
(the same defect class PROP-019 fixed in the promotion gate). "main" and
"master" stay denied alongside the configured trunk as defense in depth for a
config that names the wrong one; neither is ever a feature branch. A push
whose refspec names the current commit (`HEAD`, `@`) is resolved to the
current branch before that comparison, and `--all`/`--mirror` are denied
outright inside the target: both push the trunk whatever branch is checked
out. Relative paths resolve against the hook's `cwd`, then any
`cd <dir> &&` earlier in the same command. Fails open on its own errors,
except that an unparseable command is still checked for redirect and `-i`
operands that resolve to protected paths, and that an unreadable config
fails CLOSED for git inside `target/`: with no trunk to compare against,
a push or commit there is denied rather than waved through (the same rule
boundary-hook.py applies since PROP-019). Everything this guard can be
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
    if sub not in ("push", "commit"):
        return None
    if target is None:
        # config.yaml could not be read, so the trunk is unknown. A repo under
        # this deployment's target/ is still the target: fail closed there.
        if under(repo, (v.ROOT / "target").resolve()):
            return "config.yaml cannot be read, so the trunk is unknown; refusing `git %s` inside the target until it is fixed." % sub
        return None
    if not under(repo, target):
        return None
    if sub == "push":
        if any(r in ("--force", "-f") or r.startswith("--force") or r.startswith("-f") for r in rest):
            return "The operator merges; a forced push rewrites history — push your branch, without --force."
        trunk = v.target_branch(v.ROOT)
        if any(r in PUSH_EVERYTHING for r in rest):
            return "The operator merges; `git push %s` pushes %s too — push your branch by name." % (
                next(r for r in rest if r in PUSH_EVERYTHING), trunk)
        cur = branch_of(repo)
        # `push origin HEAD` / `push -u origin HEAD` / `push origin @` push the
        # current branch to its same-named remote branch: resolve before comparing.
        dests = [cur if d in ("HEAD", "@") else d for d in push_destinations(rest)]
        if not dests and cur in trunk_names(trunk):
            return "The operator merges; you are on %s — switch to a branch and push that, not %s." % (cur, trunk)
        hit = [d for d in dests if d in trunk_names(trunk)]
        if hit:
            return "The operator merges; push your branch, not %s." % hit[0]
    if sub == "commit" and not branch_created:
        trunk = v.target_branch(v.ROOT)
        if branch_of(repo) in trunk_names(trunk):
            return "Branch first (`git switch -c fix/<slug>`), then commit — you are on %s." % branch_of(repo)
    return None


def trunk_names(trunk: str) -> set:
    """The configured trunk plus the two conventional names. A feature
    branch is never called main or master, so denying them costs nothing
    and still protects a deployment whose config names the wrong trunk."""
    return {trunk, "main", "master"}


# push options that take a separate value argument; skipped with their value.
PUSH_VALUE_OPTS = {"--repo", "--receive-pack", "--exec", "-o", "--push-option"}
# push options that push every local branch — the trunk among them — with no
# refspec naming it; denied outright inside the target.
PUSH_EVERYTHING = {"--all", "--branches", "--mirror"}


def push_destinations(rest: List[str]) -> List[str]:
    """The remote-side branch names a `git push` writes to, from its refspecs.
    `push origin mainline` -> [mainline]; `push origin HEAD:mainline` and
    `push origin feature:mainline` -> [mainline]; `push -u origin fix/x` ->
    [fix/x]; `push origin +src:refs/heads/mainline` -> [mainline]. The first
    positional is the remote, every later one a refspec. Options are skipped,
    with a following value for the ones that take one as a separate word.
    A bare `git push` yields [] (the current branch is the destination —
    the caller checks that from git state)."""
    positionals: List[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            positionals.extend(rest[i + 1:])
            break
        if a.startswith("-"):
            if a in PUSH_VALUE_OPTS and "=" not in a:
                i += 2
                continue
            i += 1
            continue
        positionals.append(a)
        i += 1
    dests: List[str] = []
    for spec in positionals[1:]:
        spec = spec.lstrip("+")
        if ":" in spec:
            spec = spec.split(":", 1)[1]
        if spec.startswith("refs/heads/"):
            spec = spec[len("refs/heads/"):]
        if spec:
            dests.append(spec)
    return dests


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
                elif args[:1] in (["switch"], ["checkout"]) and len(args) == 2 and not args[1].startswith("-"):
                    # `switch -c fix/x && switch mainline && commit` lands the
                    # commit on the trunk: a later plain switch cancels the credit.
                    branch_created = False
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
