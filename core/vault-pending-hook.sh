#!/usr/bin/env bash
# The pen's holder's Stop and SessionEnd hooks (tracked .claude/settings.json): when a window that closed left its
# session log for the pen (state/vault-pending/, close.sh), commit those logs — and only those — through
# `core/vault-commit.sh --pending`. A window closing while the pen's holder is live never waits for the holder's own
# close, and the operator never closes windows in an order (2026-10-19). Every other turn costs one directory read:
# no python, no git. Silent; exit 0 on every path.
d="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
payload="$(cat 2>/dev/null)"
set -- "$d"/state/vault-pending/*.json
[ -e "$1" ] || exit 0
sid="$(printf '%s' "$payload" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin); print(d.get("session_id") or "")
except Exception:
    pass' 2>/dev/null)"
[ -n "$sid" ] || exit 0
DAEDALUS_SESSION_ID="$sid" bash "$d/core/vault-commit.sh" --pending </dev/null >/dev/null 2>&1
exit 0
