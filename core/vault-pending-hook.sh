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
# Every window but the pen's holder stops here, on two greps: no python in a window that is not the holder.
sid="$(printf '%s' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
[ -n "$sid" ] || exit 0
grep -qF "\"$sid\"" "$d/state/leases/prime.json" 2>/dev/null || exit 0
DAEDALUS_SESSION_ID="$sid" bash "$d/core/vault-commit.sh" --pending </dev/null >/dev/null 2>&1
exit 0
