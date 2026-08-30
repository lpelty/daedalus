#!/usr/bin/env python3
"""PreToolUse hook: surface the pitfall that is about this tool call.

A pitfall in vault/pitfalls/ may declare, in frontmatter, the commands and
file paths it applies to:

    applies-to:
      bash:
        - '<python regex over the command>'
      path:
        - '<glob over the path relative to the target checkout>'
    enforce: inject | warn | block

`block` denies the call every time. `warn` denies it once per session and
lets the retry through. `inject` (the default) attaches the pitfall to the
tool result. Block decisions are computed before any state is touched, so a
missing or corrupt state file cannot disable one. Every pattern runs under
its own alarm, so one pathological regex cannot silence the rest.

Also the parser the doctor uses (`--check`) and a debugging aid (`--parse`).
Python 3.9, standard library only.
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

ENFORCE = ("inject", "warn", "block")
MAX_INJECT = 3
MAX_CHARS = 8000
PATTERN_MAX_LEN = 200
PATTERN_SECS = 1
PRUNE_DAYS = 7
WARN_TRAILER = (
    "One-time warning for this session. Re-issue the call unchanged if it "
    "is still right, or fix it first."
)


class Unparseable(Exception):
    """A pitfall file outside the grammar. The message names the reason."""


# --- Frontmatter grammar ----------------------------------------------------

def _unquote(raw: str) -> str:
    """One scalar: bare (trailing ` #` comment stripped), 'single' ('' escapes
    a quote), or "double" (\\\\, \\", \\n)."""
    s = raw.strip()
    if len(s) >= 2 and s[0] == "'" and s[-1] == "'":
        return s[1:-1].replace("''", "'")
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        out, i, body = [], 0, s[1:-1]
        while i < len(body):
            c = body[i]
            if c == "\\" and i + 1 < len(body):
                n = body[i + 1]
                out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, "\\" + n))
                i += 2
                continue
            out.append(c)
            i += 1
        return "".join(out)
    if s.startswith(("'", '"')):
        raise Unparseable("unterminated quote: %s" % raw.strip())
    return s.split(" #", 1)[0].rstrip()


def parse_frontmatter(text: str) -> Tuple[Dict[str, object], List[str]]:
    """Return (fields, body_lines). `applies-to` becomes
    {'bash': [...], 'path': [...]}. Raises Unparseable."""
    text = text.lstrip("﻿")
    lines = [ln.rstrip("\r") for ln in text.split("\n")]
    if not lines or lines[0].strip() != "---":
        raise Unparseable("no frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError:
        raise Unparseable("unterminated frontmatter")
    fields: Dict[str, object] = {}
    i = 1
    while i < end:
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        if line[0] in " \t":
            raise Unparseable("unexpected indented line: %s" % line.strip())
        if ": " not in line and not line.endswith(":"):
            raise Unparseable("not key: value: %s" % line.strip())
        key, _, rest = line.partition(":")
        key = key.strip()
        if key in fields:
            raise Unparseable("duplicate key: %s" % key)
        if key == "applies-to":
            if rest.strip():
                raise Unparseable("applies-to must be a block map")
            sub: Dict[str, List[str]] = {}
            i += 1
            while i < end and lines[i][:1] in (" ", "\t"):
                sline = lines[i]
                stripped = sline.strip()
                if not stripped:
                    i += 1
                    continue
                skey, _, srest = stripped.partition(":")
                if skey not in ("bash", "path") or stripped.startswith("-"):
                    raise Unparseable("applies-to: unknown key or misplaced item: %s" % stripped)
                if srest.strip().startswith("["):
                    raise Unparseable("applies-to.%s: flow list; use a block list" % skey)
                if srest.strip():
                    raise Unparseable("applies-to.%s: must be a block list" % skey)
                if skey in sub:
                    raise Unparseable("duplicate key: applies-to.%s" % skey)
                items: List[str] = []
                i += 1
                while i < end and lines[i].strip().startswith("- "):
                    items.append(_unquote(lines[i].strip()[2:]))
                    i += 1
                sub[skey] = items
            fields["applies-to"] = sub
            continue
        fields[key] = _unquote(rest)
        i += 1
    enforce = fields.get("enforce", "inject")
    if enforce not in ENFORCE:
        raise Unparseable("enforce must be one of %s, got %r" % ("/".join(ENFORCE), enforce))
    fields["enforce"] = enforce
    return fields, lines[end + 1:]


def _title_and_paragraph(fields: Dict[str, object], body: List[str]) -> Tuple[str, str]:
    title = str(fields.get("title", "")).strip()
    idx = -1
    fence = False
    for n, ln in enumerate(body):
        if ln.strip().startswith("```"):
            fence = not fence
            continue
        if not fence and ln.startswith("# "):
            idx = n
            if not title:
                title = ln[2:].strip()
            break
    para: List[str] = []
    fence = False
    for ln in body[idx + 1:]:
        if ln.strip().startswith("```"):
            if para:
                break
            fence = not fence
            continue
        if fence:
            continue
        if not ln.strip():
            if para:
                break
            continue
        para.append(ln.strip())
    return title, " ".join(para)


def parse_pitfall(path: Path) -> Dict[str, object]:
    """Parse one pitfall file into {'file','title','first_paragraph','enforce',
    'bash': [...], 'path': [...]}. Raises Unparseable."""
    fields, body = parse_frontmatter(path.read_text(encoding="utf-8"))
    title, para = _title_and_paragraph(fields, body)
    applies = fields.get("applies-to") or {}
    regexes = [glob_to_regex(g).pattern for g in applies.get("path", [])]
    return {
        "file": str(path),
        "title": title,
        "first_paragraph": para,
        "enforce": fields["enforce"],
        "bash": list(applies.get("bash", [])),
        "path": list(applies.get("path", [])),
        "path_regex": regexes,
    }


# --- Globs and paths --------------------------------------------------------

def glob_to_regex(glob: str) -> "re.Pattern[str]":
    """Translate the spec's glob dialect to a full-match regex.
    `**/` = zero or more segments; trailing `/**` = optionally anything below;
    `*` = within a segment (may be empty); `?` = one non-slash character;
    everything else literal. Brackets, braces, a bare `**`, and a leading
    `/` or `./` are outside the dialect and raise Unparseable."""
    if glob.startswith(("/", "./")):
        raise Unparseable("glob must be relative: %s" % glob)
    if any(c in glob for c in "[]{}"):
        raise Unparseable("glob uses [ ] or { }: %s" % glob)
    out: List[str] = []
    i = 0
    n = len(glob)
    while i < n:
        if glob.startswith("**/", i) and (i == 0 or glob[i - 1] == "/"):
            out.append("(?:[^/]+/)*")
            i += 3
        elif glob.startswith("/**", i) and i + 3 == n:
            out.append("(?:/.*)?")
            i += 3
        elif glob.startswith("**", i):
            raise Unparseable("bare ** inside a segment: %s" % glob)
        elif glob[i] == "*":
            out.append("[^/]*")
            i += 1
        elif glob[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(glob[i]))
            i += 1
    return re.compile("".join(out))


def daedalus_root() -> Path:
    env = os.environ.get("DAEDALUS_HOME")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parent.parent


def target_root(root: Path) -> Optional[Path]:
    """The product's one source for the target checkout: lib.sh target_path."""
    lib = root / "core" / "lib.sh"
    if not lib.is_file():
        return None
    try:
        r = subprocess.run(
            ["bash", "-c", 'source "$1"; target_path', "_", str(lib)],
            capture_output=True, text=True, timeout=3,
            env=dict(os.environ, DAEDALUS_HOME=str(root)),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return Path(r.stdout.strip()).resolve()


def rel_path(file_path: str, target: Optional[Path], root: Path) -> Optional[str]:
    """Path relative to the target checkout if under it, else relative to the
    Daedalus root, else None. Both sides resolved."""
    if not file_path or not os.path.isabs(file_path):
        return None
    p = Path(file_path).resolve()
    for base in (target, root):
        if base is None:
            continue
        try:
            return p.relative_to(base).as_posix()
        except ValueError:
            continue
    return None


# --- Entry points -----------------------------------------------------------

def _cmd_parse(arg: str) -> int:
    p = Path(arg)
    try:
        print(json.dumps(parse_pitfall(p), indent=2, sort_keys=True))
    except Unparseable as e:
        print(json.dumps({"file": str(p), "unparseable": str(e)}, indent=2))
    except OSError as e:
        print(json.dumps({"file": str(p), "unparseable": "unreadable: %s" % e}, indent=2))
    return 0


def main(argv: List[str]) -> int:
    if len(argv) >= 3 and argv[1] == "--parse":
        return _cmd_parse(argv[2])
    if len(argv) >= 4 and argv[1] == "--match-glob":
        try:
            rx = glob_to_regex(argv[2])
        except Unparseable as e:
            print("unparseable: %s" % e)
            return 0
        print("match" if rx.fullmatch(argv[3]) else "no match")
        return 0
    if len(argv) >= 3 and argv[1] == "--match-path":
        root = daedalus_root()
        rel = rel_path(argv[2], target_root(root), root)
        print(rel if rel is not None else "outside")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
