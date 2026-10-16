#!/usr/bin/env python3
"""Removed in 0.9.0; deleted in 0.10.0.

This was the edit-time code-context hook (PreToolUse Edit|Write and
PreCompact). v0.9.0 replaced it with core/context.py, which runs only when
it is invoked (code-context design §4). Nothing in .claude/settings.json runs
this file. It stays for one release as a no-op that reads nothing, prints
nothing and exits 0, because a hook entry left behind in a home's
.claude/settings.local.json would otherwise run `python3 <missing file>`,
which exits 2, and exit 2 from a PreToolUse hook blocks the tool call:
every edit in that home. Doctor notes such an entry so the operator can
remove it.
"""
import sys

if __name__ == "__main__":
    sys.exit(0)
