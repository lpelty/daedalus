#!/usr/bin/env python3
"""Render a Claude Code subagent definition (markdown with YAML frontmatter)
into the JSON object `claude --agents <file>` takes.

The refuter charter lives at core/agents/refuter.md — distribution code,
under the same `Edit(./core/**)` deny rule as every other file in core/, so
the running Daedalus cannot rewrite its own reviewer. `claude -p --agent
<name>` resolves agents only from `.claude/agents/` of the cwd project, which
is a write surface; `--agents <file>` takes a definition from any path, so
refute.sh renders this file at run time and passes the result. One reader for
that frontmatter, sited here. Python 3.9, standard library only.

Frontmatter grammar (the subset the charter uses): `key: value` scalars.
`tools` and `disallowedTools` are comma-separated lists. `maxTurns` is an
integer. `omitClaudeMd` and `background` are booleans. Everything after the
closing `---` is the prompt, verbatim.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Dict, List, Tuple

LIST_KEYS = ("tools", "disallowedTools")
INT_KEYS = ("maxTurns",)
BOOL_KEYS = ("omitClaudeMd", "background")


class BadAgent(Exception):
    """The file is not an agent definition; the message names the reason."""


def _split(text: str) -> Tuple[List[str], str]:
    text = text.lstrip("﻿")
    lines = [ln.rstrip("\r") for ln in text.split("\n")]
    if not lines or lines[0].strip() != "---":
        raise BadAgent("no frontmatter")
    try:
        end = lines.index("---", 1)
    except ValueError:
        raise BadAgent("unterminated frontmatter")
    return lines[1:end], "\n".join(lines[end + 1:]).strip("\n") + "\n"


def _scalar(raw: str) -> str:
    s = raw.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        return s[1:-1]
    return s


def parse_agent(text: str) -> Tuple[str, Dict[str, object]]:
    """(name, definition) — the definition is the value `--agents` expects
    under that name. Raises BadAgent."""
    fm_lines, body = _split(text)
    fields: Dict[str, object] = {}
    for ln in fm_lines:
        if not ln.strip() or ln.lstrip().startswith("#"):
            continue
        if ln[0] in " \t" or ":" not in ln:
            raise BadAgent("not key: value: %s" % ln.strip())
        key, _, rest = ln.partition(":")
        key = key.strip()
        val = _scalar(rest)
        if key in fields:
            raise BadAgent("duplicate key: %s" % key)
        if key in LIST_KEYS:
            fields[key] = [t.strip() for t in val.split(",") if t.strip()]
        elif key in INT_KEYS:
            if not val.isdigit():
                raise BadAgent("%s must be an integer, got %r" % (key, val))
            fields[key] = int(val)
        elif key in BOOL_KEYS:
            if val.lower() not in ("true", "false"):
                raise BadAgent("%s must be true or false, got %r" % (key, val))
            fields[key] = val.lower() == "true"
        else:
            fields[key] = val
    name = str(fields.pop("name", "")).strip()
    if not name:
        raise BadAgent("name is required")
    if not str(fields.get("description", "")).strip():
        raise BadAgent("description is required")
    if not body.strip():
        raise BadAgent("prompt body is empty")
    fields["prompt"] = body
    return name, fields


def render(path: Path) -> str:
    name, definition = parse_agent(path.read_text(encoding="utf-8"))
    return json.dumps({name: definition}, indent=2, sort_keys=True)


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: agentdef.py <agent.md>\n")
        return 2
    try:
        sys.stdout.write(render(Path(argv[1])) + "\n")
    except (BadAgent, OSError, UnicodeDecodeError) as e:
        sys.stderr.write("agentdef: %s: %s\n" % (argv[1], e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
