#!/usr/bin/env python3
"""Append paths to vault/evidence/.manifest under a lock, as one write.

gates.sh and refute.sh used to append with `>>` from several lines; two
windows running gates at once interleaved them into half paths (spec §4.9).
bash 3.2 on macOS has no flock binary, hence python3. The lock is
vault/evidence/.manifest.lock — its own file, so a reader of .manifest
(verifylib.manifest_paths) never blocks on it and the leases lock is never
involved.

Paths come as arguments, or newline-separated on stdin when an argument is
`-`: a caller that has a LIST of paths (gates.sh's gate logs) pipes them,
one per line, so no path ever crosses a shell word boundary — an unquoted
$(...) once split every path at a space in DAEDALUS_HOME into fragments,
each manifested, none a file (Task 14 review).
"""
from __future__ import annotations

import fcntl
import os
import sys
from pathlib import Path


def main(argv: list) -> int:
    root = Path(os.environ.get("DAEDALUS_HOME") or Path(__file__).resolve().parent.parent)
    ev = root / "vault" / "evidence"
    if not ev.is_dir():
        sys.stderr.write("daedalus: vault/evidence is missing; nothing manifested\n")
        return 1
    paths: list = []
    for a in argv[1:]:
        paths.extend(sys.stdin.read().splitlines() if a == "-" else [a])
    paths = [p for p in paths if p.strip()]
    if not paths:
        return 0
    fd = os.open(str(ev / ".manifest.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with open(str(ev / ".manifest"), "a") as fh:
            fh.write("\n".join(paths) + "\n")
            fh.flush()
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
