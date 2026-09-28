#!/usr/bin/env python3
"""Distribution integrity (spec §6.1): is every file under core/, CLAUDE.md and
.claude/settings.json on disk exactly HEAD's? Standalone on purpose — standard
library only, nothing imported from core/ — because it must run BEFORE any
other distribution code: core/call-agent.sh (and, from plan 4 Task 7,
core/promote.sh) runs it first, as
`python3 -I -B core/distcheck.py <home> --for launch|promote` (isolated: no
PYTHON* variables, no script directory or user site on sys.path, no bytecode
written), after git alone has checked this file against HEAD. core/call_agent.py
imports it for its later checks.

Exit 0 when clean; 2 with one sentence on stderr (`daedalus: …`) when a file
differs or when it cannot tell. Python 3.9.
"""
from __future__ import annotations

import hashlib
import os
import stat
import subprocess
import sys
from pathlib import Path
from typing import Dict, Optional, Sequence, Tuple

DIST_PATHS = ("core", "CLAUDE.md", ".claude/settings.json")
SUFFIX = {"launch": "Nothing was launched.", "promote": "Nothing was pushed."}


def integrity_git(root: Path, *args: str) -> subprocess.CompletedProcess:
    """git for the integrity check: no GIT_* variable from the caller (GIT_DIR,
    GIT_WORK_TREE, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY, GIT_CONFIG_*) can point
    it at another repository or inject config, and replacement objects are off,
    so HEAD's tree is this checkout's committed tree."""
    env = {k: val for k, val in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_NO_REPLACE_OBJECTS"] = "1"
    return subprocess.run(["git", "-C", str(root)] + list(args), capture_output=True, env=env, timeout=20)


def blob_id(data: bytes, algo: str) -> str:
    h = hashlib.new(algo)
    h.update(b"blob %d\0" % len(data))
    h.update(data)
    return h.hexdigest()


def disk_entry(path: Path, algo: str) -> Tuple[str, str]:
    """(git mode, blob id) of one path on disk, never following a symlink."""
    st = os.lstat(str(path))
    if stat.S_ISLNK(st.st_mode):
        return "120000", blob_id(os.fsencode(os.readlink(str(path))), algo)
    if not stat.S_ISREG(st.st_mode):
        return "special", ""
    with open(str(path), "rb") as fh:
        return ("100755" if st.st_mode & 0o100 else "100644"), blob_id(fh.read(), algo)


def distribution_state(root: Path, paths: Sequence[str] = DIST_PATHS) -> Tuple[str, str]:
    """('clean' | 'modified' | 'unknown', detail). The reviewer that ran must be
    the reviewer that is tracked: a modified core/, CLAUDE.md or
    .claude/settings.json — whoever changed it — means nothing this launcher
    runs can be trusted to be the distribution's.

    Every file on disk under those paths is compared by content with HEAD's
    tree, never through git status: status trusts the index (skip-worktree,
    assume-unchanged, the stat cache, fsmonitor) and the exclude rules
    (.gitignore at any level, .git/info/exclude, core.excludesFile,
    status.showUntrackedFiles), and each of those can hide a change. So an
    ignored file is modified like any other. Skipped: __pycache__/ directories,
    which nothing the launcher runs reads (call_agent.py's NO_PYCACHE), and Finder's
    .DS_Store files."""
    top = integrity_git(root, "rev-parse", "--is-inside-work-tree", "--show-prefix")
    if top.returncode != 0 or top.stdout.decode("utf-8", "replace").strip() != "true":
        return "unknown", "%s is not the root of a git checkout" % root
    algo = object_format(root)
    if algo not in ("sha1", "sha256"):
        return "unknown", "unsupported git object format %s in %s" % (algo, root)
    ls = integrity_git(root, "ls-tree", "-r", "-z", "--full-tree", "HEAD", "--", *paths)
    if ls.returncode != 0:
        return "unknown", "cannot read the committed tree in %s (%s)" % (
            root, ls.stderr.decode("utf-8", "replace").strip())
    committed: Dict[str, Tuple[str, str]] = {}
    for rec in ls.stdout.split(b"\0"):
        if not rec:
            continue
        meta, _, name = rec.partition(b"\t")
        mode, kind, oid = meta.decode().split(" ")
        if kind != "blob":
            return "unknown", "%s is a %s in HEAD, not a file" % (os.fsdecode(name), kind)
        committed[os.fsdecode(name)] = (mode, oid)
    if not any(n.startswith("core/") for n in committed):
        return "unknown", "core/ is not tracked in %s" % root
    on_disk: Dict[str, Tuple[str, str]] = {}
    try:
        for rel in paths:
            full = root / rel
            if not os.path.lexists(str(full)):
                continue
            if full.is_symlink() or not full.is_dir():
                on_disk[rel] = disk_entry(full, algo)
                continue
            for d, dirs, files in os.walk(str(full)):
                base = Path(d).relative_to(root).as_posix()
                for name in list(dirs):
                    if os.path.islink(os.path.join(d, name)):
                        dirs.remove(name)
                        files.append(name)   # a directory symlink is a file to git
                    elif name == "__pycache__":
                        dirs.remove(name)
                for name in files:
                    if name != ".DS_Store":   # Finder's folder metadata: nothing loads it
                        on_disk["%s/%s" % (base, name)] = disk_entry(Path(d) / name, algo)
    except OSError as e:
        return "unknown", "cannot read %s (%s)" % (e.filename or root, e.strerror or e)
    changed = sorted(n for n in set(committed) | set(on_disk) if committed.get(n) != on_disk.get(n))
    if not changed:
        return "clean", ""
    shown = ", ".join(changed[:10])
    return "modified", shown + (" and %d more" % (len(changed) - 10) if len(changed) > 10 else "")


def object_format(root: Path) -> str:
    fmt = integrity_git(root, "rev-parse", "--show-object-format")
    return fmt.stdout.decode().strip() if fmt.returncode == 0 and fmt.stdout.strip() else "sha1"


def committed_id(root: Path, spec: str) -> Optional[str]:
    p = integrity_git(root, "rev-parse", spec)
    return p.stdout.decode().strip() if p.returncode == 0 else None


def committed_dist(root: Path) -> Dict[str, Optional[str]]:
    return {"core_tree": committed_id(root, "HEAD:core"),
            "charter_sha": committed_id(root, "HEAD:core/agents/refuter.md")}


def refusal(state: str, detail: str, suffix: str) -> str:
    """The one sentence every caller prints (spec §6.1)."""
    if state == "modified":
        return "Distribution code is modified (%s); restore it before a review or a promote runs. %s" % (detail, suffix)
    return "Cannot tell whether distribution code is modified: %s. %s" % (detail, suffix)


def main(argv: Sequence[str]) -> int:
    if len(argv) != 4 or argv[2] != "--for" or argv[3] not in SUFFIX:
        sys.stderr.write("usage: python3 -I -B core/distcheck.py <home> --for launch|promote\n")
        return 2
    state, detail = distribution_state(Path(argv[1]).resolve())
    if state != "clean":
        sys.stderr.write("daedalus: %s\n" % refusal(state, detail, SUFFIX[argv[3]]))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
