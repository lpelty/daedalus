#!/usr/bin/env python3
"""The git pre-push hook that refuses a trunk push no promotion confirmed
(spec §7.3 "The real gate is in git"), its installer, and its state.

    python3 core/prepush.py hook <remote> <url>     run by git; the ref updates on stdin
    python3 core/prepush.py install <repo>...       idempotent; one line per repo; exit 1 if one could not be
    python3 core/prepush.py status <repo>...        for doctor: installed | missing | differs | foreign | hookspath

The installed file is a shim — fixed lines that exec this file's `hook` — in
the repo's COMMON git dir: linked worktrees run hooks from there, so one install
covers target/<repo>, every worktrees/<NN>/<repo> and every
state/promote/<id>/<repo>. core.hooksPath is never touched; a repo that sets it
never runs the shim, and `status` says so. A pre-push hook Daedalus did not
install is never overwritten.

The hook refuses any update to refs/heads/<trunk>, main or master (the trunk:
config target.branch, and the repo's origin/HEAD) unless DAEDALUS_PROMOTE_ID
names state/promote/<id>/prepared.json whose confirmed_at is set, whose
merge_sha is the sha being pushed, whose trunk_sha_at_prepare is the remote's
current sha (a fast-forward from the tested base), with no push_failed_at and
no pushed/announced stamp (plan 4 Decision 34). On one POSIX user it is a claim
check, a second speed bump beside the guard: the record of what was pushed is
confirm's re-derivation, never this hook; a clone outside the home has no hook
at all (Decision 38). git runs a pre-push hook for `git push` only — never for
`git send-pack`, `http-push` or a remote helper driven by hand (measured: a
refusing hook blocked `git push` and not `git send-pack`), so those are the
guard's to deny (Task 13 review). Python 3.9, standard library.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Tuple

HOME = Path(__file__).resolve().parent.parent
MARK = "# daedalus pre-push hook (core/prepush.py)"
REFUSE = "This push would move %s. Trunk is reached only through promote (`core/promote.sh <NN>`)."
ZERO = re.compile(r"^0+$")
PROMOTE_ID = re.compile(r"^[0-9]{2}-[0-9]{8}-[0-9]{6}-[0-9a-f]{3}$")


def shim(home: Path) -> str:
    return ("#!/bin/sh\n%s — installed by Daedalus; do not edit.\n"
            "# Trunk is reached only through promote; this hook refuses any other push to it.\n"
            "exec python3 '%s/core/prepush.py' hook \"$@\"\n" % (MARK, home))


def _git(repo: Path, *args: str) -> Tuple[int, str]:
    p = subprocess.run(["git", "-C", str(repo)] + list(args), capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


def display(repo: Path) -> str:
    try:
        return Path(repo).resolve().relative_to(HOME).as_posix()
    except ValueError:
        return str(repo)


def hook_path(repo: Path) -> Path:
    code, common = _git(repo, "rev-parse", "--git-common-dir")
    if code != 0 or not common:
        raise ValueError("%s is not a git repository" % display(repo))
    c = Path(common)
    return (c if c.is_absolute() else Path(repo) / c).resolve() / "hooks" / "pre-push"


def state(repo: Path) -> Tuple[str, str]:
    try:
        p = hook_path(repo)
    except ValueError as e:
        return "missing", str(e)
    code, hp = _git(repo, "config", "--get", "core.hooksPath")
    if code == 0 and hp:
        return "hookspath", hp
    if not p.exists():
        return "missing", str(p)
    text = p.read_text(errors="replace")
    if MARK not in text:
        return "foreign", str(p)
    if text != shim(HOME) or not os.access(str(p), os.X_OK):
        return "differs", str(p)
    return "installed", str(p)


def install(repo: Path) -> Tuple[str, str]:
    name = display(repo)
    s, where = state(repo)
    if s == "installed":
        return "unchanged", "pre-push hook: unchanged in %s" % name
    if s == "foreign":
        return "foreign", ("%s already has a pre-push hook that Daedalus did not install (%s); it was left alone — merge "
                           "the two by hand, or move it aside and run core/setup.sh" % (name, where))
    if s == "hookspath":
        return "hookspath", ("%s sets core.hooksPath (%s), so a hook in its .git/hooks never runs; unset it (git -C %s "
                             "config --unset core.hooksPath) and run core/setup.sh" % (name, where, name))
    p = hook_path(repo)
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name("pre-push.daedalus-tmp")
    tmp.write_text(shim(HOME))
    os.chmod(str(tmp), 0o755)
    os.replace(str(tmp), str(p))
    return "installed", "pre-push hook: installed in %s" % name


def trunk_names(repo: Path) -> set:
    names = {"main", "master"}
    code, head = _git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if code == 0 and head.startswith("origin/"):
        names.add(head[len("origin/"):])
    try:
        p = subprocess.run(["bash", "-c", 'source "$1"; cfg target.branch 2>/dev/null || true', "_",
                            str(HOME / "core" / "lib.sh")], capture_output=True, text=True,
                           env=dict(os.environ, DAEDALUS_HOME=str(HOME)), timeout=10)
        if p.stdout.strip():
            names.add(p.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return names


def hook(_argv: List[str]) -> int:
    """git runs this in the pushing worktree with `<local ref> <local sha> <remote
    ref> <remote sha>` lines on stdin; any non-zero exit refuses the whole push."""
    names = trunk_names(Path.cwd())
    pid = os.environ.get("DAEDALUS_PROMOTE_ID", "")
    prepared = None
    if PROMOTE_ID.match(pid):
        try:
            prepared = json.loads((HOME / "state" / "promote" / pid / "prepared.json").read_text())
        except (OSError, ValueError):
            prepared = None
    for line in sys.stdin:
        parts = line.split()
        if len(parts) != 4 or not parts[2].startswith("refs/heads/"):
            continue
        branch, local_sha = parts[2][len("refs/heads/"):], parts[1]
        if branch not in names:
            continue
        if not (isinstance(prepared, dict) and prepared.get("confirmed_at") and not ZERO.match(local_sha)
                and prepared.get("merge_sha") == local_sha
                # Decision 34: only a fast-forward from the tested base, and only once
                and parts[3] == prepared.get("trunk_sha_at_prepare")
                and not prepared.get("push_failed_at")
                and not (HOME / "state" / "promote" / pid / "pushed").exists()
                and not (HOME / "state" / "promote" / pid / "announced").exists()):
            sys.stderr.write("daedalus: %s\n" % (REFUSE % branch))
            return 1
    return 0


def main(argv: List[str]) -> int:
    cmd, rest = (argv[1], argv[2:]) if len(argv) > 1 else ("", [])
    if cmd == "hook":
        return hook(rest)
    if cmd == "install":
        rc = 0
        for r in rest:
            try:
                s, msg = install(Path(r))
            except (OSError, ValueError) as e:
                s, msg = "failed", "pre-push hook: could not be installed in %s (%s)" % (display(Path(r)), e)
            print(msg)
            if s not in ("installed", "unchanged"):
                rc = 1
        return rc
    if cmd == "status":
        for r in rest:
            s, where = state(Path(r))
            print("%s\t%s\t%s" % (display(Path(r)), s, where))
        return 0
    sys.stderr.write("usage: python3 core/prepush.py hook | install <repo>... | status <repo>...\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
