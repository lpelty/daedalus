#!/usr/bin/env python3
"""daedalus start — Claude Code in the right home, after the banner and a look at the services (daedalus-start
design, 2026-10-19, §3).

    daedalus start [home] [--window NN] [-- <claude args>]

The `daedalus` command resolves the home (core/update.py: the name given, else the current directory's home, else
the default) and runs this file as

    python3 <home>/core/start.py --home <home> [--name <its name>] [--window NN] [-- <claude args>]

In order: cd to the home; print the banner — <home>/banner.txt when the deployment has one (git-ignored, like
config.yaml), else the release's core/banner.txt — and under it `Daedalus <version> · <name> · <path>`; run
core/status.py --json (2 s at most) and print one line per configured service, ✓ or ✗ and the detail, a not-set-up
service left out, or `services: couldn't check` when the check fails or is slow; hold the screen start.pause seconds
(config.yaml, default 1.5, 0 skips); then exec claude with the arguments after `--`, so Claude Code owns the terminal
and this process. --window NN sets DAEDALUS_LEASE=NN for it: the session binds window NN at start.

It starts, stops and fixes nothing: a down service is shown and never blocks the start. Standard library only.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

sys.dont_write_bytecode = True      # importing update.py must leave no __pycache__ in the home (identity guard)
sys.path.insert(0, str(Path(__file__).resolve().parent))
import update  # noqa: E402

STATUS_TIMEOUT_SECS = 2.0           # design §3: the service check is under 2 s, or it is said as not checked
DEFAULT_PAUSE = 1.5
MAX_PAUSE = 10.0
USAGE = "usage: daedalus start [home] [--window NN] [-- <claude args>]"


def say(text: str = "") -> None:
    """One line to the terminal as UTF-8, whatever the locale says (the banner is box-drawing characters)."""
    sys.stdout.buffer.write((text + "\n").encode("utf-8", "replace"))


def banner(home: Path) -> Optional[str]:
    for p in (home / "banner.txt", home / "core" / "banner.txt"):
        try:
            return p.read_bytes().decode("utf-8", "replace").rstrip("\n")
        except OSError:
            continue
    return None


def service_lines(home: Path) -> List[str]:
    """One line per configured service from core/status.py --json; ["services: couldn't check"] on any failure."""
    failed = ["services: couldn't check"]
    try:
        r = subprocess.run([sys.executable, str(home / "core" / "status.py"), "--json", "--home", str(home)],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=STATUS_TIMEOUT_SECS)
        if r.returncode != 0:
            return failed
        rows = json.loads(r.stdout)["services"]
        out = []
        for s in rows:
            state, name, detail = s.get("state"), s.get("name") or s.get("stem"), s.get("detail") or ""
            if state == "not-set-up":
                continue
            if state == "up":
                out.append("✓ %s" % name)
            else:
                out.append("✗ %s — %s" % (name, detail) if detail else "✗ %s" % name)
        return out
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, AttributeError):
        return failed


def pause_secs(home: Path) -> float:
    raw = update.config_value(home, "start.pause")
    try:
        val = float(raw) if raw is not None else DEFAULT_PAUSE
    except ValueError:
        val = DEFAULT_PAUSE
    if val != val:      # nan
        val = DEFAULT_PAUSE
    return min(max(val, 0.0), MAX_PAUSE)


def main(argv: List[str]) -> int:
    args = list(argv)
    claude_args: List[str] = []
    if "--" in args:
        i = args.index("--")
        args, claude_args = args[:i], args[i + 1:]
    home_arg = name = window = None
    while args:
        a = args.pop(0)
        if a in ("--home", "--name", "--window") and args:
            v = args.pop(0)
            if a == "--home":
                home_arg = v
            elif a == "--name":
                name = v
            else:
                window = v
        elif a.startswith("--window="):
            window = a.split("=", 1)[1]
        else:
            sys.stderr.write("daedalus: start does not take %s. %s\n" % (a, USAGE))
            return 2
    home = Path(home_arg).resolve() if home_arg else Path(__file__).resolve().parent.parent
    if not update.is_home(home):
        sys.stderr.write("daedalus: %s is not a Daedalus home (core/update.py, config.yaml and VERSION).\n" % home)
        return 2
    env = dict(os.environ)
    if window is not None:
        if not re.fullmatch(r"\d{1,2}", window) or int(window) == 0:
            sys.stderr.write("daedalus: --window takes a window number, 01 to 99, not %s.\n" % window)
            return 2
        env["DAEDALUS_LEASE"] = "%02d" % int(window)
    os.chdir(str(home))
    art = banner(home)
    if art:
        say(art)
    say("Daedalus %s · %s · %s" % (update.home_version(home) or "(no VERSION)", name or update.home_name(home),
                                   update._tilde(home)))
    for ln in service_lines(home):
        say(ln)
    sys.stdout.flush()
    pause = pause_secs(home)
    if pause > 0:
        time.sleep(pause)
    try:
        os.execvpe("claude", ["claude"] + claude_args, env)
    except OSError as e:
        sys.stderr.write("daedalus: claude (Claude Code) could not be started: %s.\n" % (e.strerror or e))
        return 127
    return 0        # not reached


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
