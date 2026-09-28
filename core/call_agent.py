#!/usr/bin/env python3
"""Direct-call launcher: one core, three callees (spec §8).

    core/call-agent.sh --callee agent|self|refuter [--request-file F | "<request>" | stdin]
                       [--tree <abs path>] [--tag <label>] [--artifact-dir <abs path>]
                       [--caller <name>] [--verdict-file <path>] [--mode branch|promote]
    core/call-agent.sh --resume <call-id> [--callee <mode>] [--request-file F | "<request>"]
    core/call-agent.sh --resume-review <NN> "<question>"
    python3 core/call_agent.py --doctor

Contract: the answer on stdout, a two-line receipt on stderr, resume by call
id. Callers check the exit code AND a non-empty stdout, never the receipt line
alone. Exit 0: answer produced and orientation verified. 2: refused before
launch. 3: answer produced, orientation not verified. 124: timed out (process
group killed). Any other non-zero is claude's own exit (or the callee
launcher's), passed through.

The callee is configuration, never an argument (spec §8.4): --callee agent
reads direct_call.callee_home / callee_name (and optional callee_launcher)
from this deployment's config.yaml and is refused while they are unset. Core
names no agent and has no default callee, so the same code calls one agent on
one deployment and a different agent on the next.

Receipts: state/direct-calls/<call-id>/launch.json plus per-attempt sidecars.
Session id == call id. Python 3.9, standard library only; verifylib and
leaselib come from core/ beside this file.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import fcntl
import hashlib
import json
import os
import pwd
import re
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

SELF_NAME = "Daedalus"
SELF_MARKER = "Daedalus session orientation:"
SCOPE = "read-only-review"
MODES = ("agent", "self", "refuter")
READ_ONLY_TOOLS = ("Read", "Grep", "Glob")
TREE_ROOTS = ("worktrees", "target", "state/promote")
DIST_PATHS = ("core", "CLAUDE.md", ".claude/settings.json")
CLAUDE_MD_EXCLUDES = ["**/CLAUDE.md", "**/CLAUDE.local.md", "**/.claude/rules/**", "**/AGENTS.md"]
REFUTER_SETTINGS = json.dumps({"disableAllHooks": True, "autoMemoryEnabled": False,
                               "claudeMdExcludes": CLAUDE_MD_EXCLUDES})
# A called session is a visitor (spec §4.8): it never inherits its caller's
# window, pen or tree override.
BINDING_VARS = ("DAEDALUS_LEASE", "DAEDALUS_SESSION_ID", "DAEDALUS_HOOK_PID", "DAEDALUS_TARGET_OVERRIDE")
# Only the launcher's own re-capture may run capture for a call, and it runs
# in the caller's environment without these (spec §8.5).
CALL_VARS = ("CAPTURE_DEFER_TO_CALLER", "DIRECT_CALL_ID", "DIRECT_CALL_RECEIPT_DIR", "DIRECT_CALL_CALLER")
CONFIG_KEYS = ("direct_call.callee_home", "direct_call.callee_name", "direct_call.callee_human",
               "direct_call.callers", "direct_call.orientation_marker", "direct_call.callee_launcher",
               "direct_call.tools", "direct_call.max_turns", "direct_call.timeout", "direct_call.capture",
               "direct_call.capture_wait", "verify.refute_model", "verify.refute_timeout",
               "memory.transcript_dir")
REQUEST_FILE = "\0request-file"
WRITE_ONCE = "A review for this run already exists; a new verdict needs a new run."
EXIT_REFUSED, EXIT_UNVERIFIED, EXIT_TIMEOUT = 2, 3, 124
CALL_ID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
# One parser for config.yaml: lib.sh cfg (lib.sh:19-69). Every key in one bash call.
CFG_SNIPPET = r'''source "$DAEDALUS_HOME/core/lib.sh"; set +e
for k in "$@"; do val="$(cfg "$k" 2>/dev/null)" && printf '%s\t%s\n' "$k" "$val"; done
exit 0'''
TARGET_SNIPPET = r'''source "$DAEDALUS_HOME/core/lib.sh"; set +e
target_path'''
# The launcher's re-capture (spec §8.5): the memory: block through lib.sh
# memory_env when this build has it (plan 2), else whatever TENANT_* the
# caller's environment already carries; then capture.py on the call's transcript.
CAPTURE_SNIPPET = r'''source "$DAEDALUS_HOME/core/lib.sh"; set +e
if declare -F memory_env >/dev/null 2>&1; then
  mem="$(memory_env)" || exit 97
  eval "$mem"
fi
export TENANT_HOME="${TENANT_HOME:-$DAEDALUS_HOME}"
exec python3 "$DAEDALUS_HOME/core/capture.py" capture --hook-json "$1"'''


class Refusal(Exception):
    """Refused before launch (exit 2); str(e) is the operator's sentence."""


# --- small helpers -------------------------------------------------------------

def home_raw() -> str:
    return os.environ.get("DAEDALUS_HOME") or str(v.ROOT)


def now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


def atomic_write(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1))
    os.replace(tmp, path)


def git_out(root: Path, *args: str) -> Optional[str]:
    p = subprocess.run(["git", "-C", str(root)] + list(args), capture_output=True, text=True, timeout=20)
    return p.stdout.strip() if p.returncode == 0 else None


def lib_env(root: Path) -> Dict[str, str]:
    # DAEDALUS_CONFIG is dropped: lib.sh then reads $DAEDALUS_HOME/config.yaml,
    # the one file config_file() accepts.
    env = dict(os.environ, DAEDALUS_HOME=home_raw())
    env.pop("DAEDALUS_CONFIG", None)
    return env


def project_slug(path: Path) -> str:
    """Claude Code's per-project transcript folder name: every character that is
    not a letter or digit becomes '-' (the rule the launcher this one was
    ported from verified against a live home)."""
    return re.sub(r"[^A-Za-z0-9]", "-", str(path))


def transcript_dir_for(cwd: Path, override: Optional[str] = None) -> Path:
    if override:
        return Path(override)
    base = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude"))
    return base / "projects" / project_slug(cwd)


def label_of(mode: str, rec: dict) -> str:
    return {"refuter": "Refuter", "self": SELF_NAME}.get(mode) or str(rec.get("callee") or "Agent")


# --- configuration -------------------------------------------------------------

def config_file(root: Path) -> Path:
    """This deployment's config.yaml, and only it (Decision 15). DAEDALUS_HOME
    and DAEDALUS_CONFIG are inherited from the environment (lib.sh), so a
    session could otherwise hand the launcher any file and, through it, any
    callee home or refuter model — the route the callee-from-config rule
    forbids. The home must be the one this file lives in, and the config
    exactly <home>/config.yaml (stricter than gates.sh's "under the home": a
    session can write under the home)."""
    here = Path(__file__).resolve().parent.parent
    if root.resolve() != here:
        raise Refusal("DAEDALUS_HOME (%s) is not the home this launcher belongs to (%s) — refusing; the callee "
                      "is named only by this deployment's config.yaml" % (root, here))
    raw = os.environ.get("DAEDALUS_CONFIG") or str(here / "config.yaml")
    if Path(raw).resolve() != here / "config.yaml":
        raise Refusal("config %s resolves outside %s/config.yaml — refusing; the callee is named only by this "
                      "deployment's config.yaml" % (raw, here))
    return here / "config.yaml"


def read_config(root: Path) -> Dict[str, str]:
    cfg_file = config_file(root)
    if not cfg_file.is_file():
        raise Refusal("no config at %s (copy config.example.yaml)" % cfg_file)
    p = subprocess.run(["bash", "-c", CFG_SNIPPET, "cfg"] + list(CONFIG_KEYS),
                       capture_output=True, text=True, timeout=20, env=lib_env(root))
    if p.returncode != 0:
        raise Refusal("cannot read config.yaml through lib.sh cfg (%s)" % (p.stderr.strip() or p.returncode))
    out: Dict[str, str] = {}
    for line in p.stdout.splitlines():
        key, _, val = line.partition("\t")
        if key:
            out[key] = val
    return out


def _whole(raw: str, lo: int, hi: int) -> Optional[int]:
    return int(raw) if raw.isdigit() and len(raw) <= 7 and lo <= int(raw) <= hi else None


def direct_call_settings(conf: Dict[str, str]) -> Tuple[dict, List[str]]:
    """direct_call.* validated, with the spec §8.1 defaults. (settings,
    problems): each problem is one plain sentence naming its key. The launcher
    refuses on the first; doctor prints them all."""
    g = conf.get
    problems: List[str] = []
    s = {"callee_home": None, "callee_name": None, "callee_launcher": None,
         "callee_human": g("direct_call.callee_human") or "the operator",
         "callers": [c.strip() for c in (g("direct_call.callers") or "").split(",") if c.strip()],
         "marker": g("direct_call.orientation_marker"), "tools": list(READ_ONLY_TOOLS),
         "max_turns": 40, "timeout": 600, "capture": True, "capture_wait": 90,
         "transcript_dir": g("memory.transcript_dir")}
    home, name = g("direct_call.callee_home"), g("direct_call.callee_name")
    if bool(home) != bool(name):
        problems.append("direct_call.callee_home and direct_call.callee_name are set together or not at all "
                        "(only %s is set)" % ("callee_home" if home else "callee_name"))
    elif home:
        if not home.startswith("/"):
            problems.append("direct_call.callee_home must be an absolute path (got: %s)" % home)
        elif not Path(home).is_dir():
            problems.append("direct_call.callee_home is not a directory: %s" % home)
        else:
            s["callee_home"], s["callee_name"] = home, name
    launcher = g("direct_call.callee_launcher")
    if launcher:
        if not (launcher.startswith("/") and Path(launcher).is_file() and os.access(launcher, os.X_OK)):
            problems.append("direct_call.callee_launcher must be the absolute path of an executable file (got: %s)"
                            % launcher)
        else:
            s["callee_launcher"] = launcher
    tools = g("direct_call.tools")
    if tools is not None:
        names = [t.strip() for t in tools.split(",") if t.strip()]
        if not names or any(t not in READ_ONLY_TOOLS for t in names):
            problems.append("direct_call.tools may name only Read, Grep and Glob — a direct call is read-only "
                            "(got: %s)" % tools)
        else:
            s["tools"] = names
    for key, lo, hi in (("max_turns", 1, 500), ("capture_wait", 0, 300), ("timeout", 1, 9999999)):
        raw = g("direct_call." + key)
        if raw is None:
            continue
        n = _whole(raw, lo, hi)
        if n is None:
            problems.append("direct_call.%s must be a whole number from %d to %d (got: %s)" % (key, lo, hi, raw))
        else:
            s[key] = n
    cap = g("direct_call.capture")
    if cap is not None:
        if cap not in ("true", "false"):
            problems.append("direct_call.capture must be true or false (got: %s)" % cap)
        else:
            s["capture"] = cap == "true"
    return s, problems


def refuter_settings(conf: Dict[str, str]) -> Tuple[dict, List[str]]:
    """verify.refute_timeout (lib.sh refute_timeout's rule: 1..9999999, absent =
    600) and verify.refute_model (absent = the charter's model)."""
    problems: List[str] = []
    s = {"timeout": 600, "model": conf.get("verify.refute_model")}
    raw = conf.get("verify.refute_timeout")
    if raw is not None:
        n = _whole(raw, 1, 9999999)
        if n is None:
            problems.append("verify.refute_timeout must be a whole number of seconds > 0 (got: %s)" % raw)
        else:
            s["timeout"] = n
    return s, problems


def first(problems: List[str]) -> None:
    if problems:
        raise Refusal(problems[0])


# --- doctor (spec §15) -------------------------------------------------------------------

def doctor(root: Path) -> int:
    """One line per state (spec §15, Decision 5). No direct_call: block prints
    nothing; an unreadable config is one MISSING line, and the rows that do
    not depend on config (Task 3's distribution code) still follow it."""
    try:
        conf = read_config(root)
    except Refusal as e:
        print("MISSING  direct call: %s" % e)
        conf = {}
    s, problems = direct_call_settings(conf)
    callers = ", ".join(s["callers"]) or "nobody"
    for p in problems:
        print("MISSING  direct call: %s" % p)
    if not problems and any(k.startswith("direct_call.") for k in conf):
        if s["callee_home"]:
            print("OK       direct call: callee %s at %s%s; callers of this Daedalus: %s"
                  % (s["callee_name"], s["callee_home"],
                     " through its own launcher" if s["callee_launcher"] else "", callers))
        else:
            print("NOTE     direct call: no callee configured (optional) — core/call-agent.sh --callee agent is "
                  "refused until direct_call.callee_home and callee_name are set in config.yaml; callers of this "
                  "Daedalus: %s" % callers)
    return 0


# --- entry point -------------------------------------------------------------------------

def parse(argv: List[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="core/call-agent.sh", description="Direct-call launcher (spec §8).")
    ap.add_argument("--callee", choices=MODES)
    ap.add_argument("--caller")
    ap.add_argument("--request-file")
    ap.add_argument("--resume", metavar="CALL_ID")
    ap.add_argument("--resume-review", metavar="NN")
    ap.add_argument("--tree")
    ap.add_argument("--tag")
    ap.add_argument("--artifact-dir")
    ap.add_argument("--verdict-file")
    ap.add_argument("--mode", choices=("branch", "promote"))
    ap.add_argument("--doctor", action="store_true")
    ap.add_argument("text", nargs="?")
    args = ap.parse_args(argv)
    if args.resume and args.resume_review:
        ap.error("--resume and --resume-review are two ways to name one call; use one")
    return args


def main(argv: List[str]) -> int:
    args = parse(argv)
    if args.doctor:
        return doctor(v.ROOT)
    # Task 2 replaces this body with the launcher.
    sys.stderr.write("daedalus: this build of core/call_agent.py only checks configuration (--doctor)\n")
    return EXIT_REFUSED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
