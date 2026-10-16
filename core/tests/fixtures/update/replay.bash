# core/tests/fixtures/update/replay.bash — sourced by test_update.bats. Builds the second machine's shape
# (update-command design §5.6 test 20): a home that took release N by `git merge` over local commits.
#   - its journal: SOUL.md entries COMMITTED in the local history (working tree equal to HEAD);
#   - its merge commit's .claude/settings.json: release N's, minus Edit(/CLAUDE.md), plus an allow rule
#     and a PreToolUse hook group of its own;
#   - its merge commit's CLAUDE.md: release N's plus four lines of its own, appended;
#   - state/settings-before-merge.json: the v0.7.0 settings (./-anchored, the SOUL.md deny included)
#     minus Edit(./CLAUDE.md), plus an ask rule — the copy an agent kept while resolving the merge.
# Needs: $H (a deployment at release N), $R's history holding the v0.7.0 settings (SEED_OLD_SETTINGS=1),
# and the tag "older" (the commit before release N).
REPLAY_FIXTURES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

replay_home() {
  git -C "$H" reset -q --hard older
  printf '\n## Journal: a committed entry\n\nI kept this one in the local history.\n' >> "$H/SOUL.md"
  git -C "$H" commit -q -am "journal"
  git -C "$H" merge -q --no-ff --no-commit "v$N" >/dev/null 2>&1 || true
  git -C "$H" checkout -q "v$N" -- .claude/settings.json CLAUDE.md
  python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["deny"].remove("Edit(/CLAUDE.md)")
d["permissions"].setdefault("allow", []).append("Bash(echo replay-allow)")
d["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [{"type": "command", "command": "echo replay-hook", "timeout": 5}]})
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  printf '\nReplay local line one.\nReplay local line two.\nReplay local line three.\nReplay local line four.\n' >> "$H/CLAUDE.md"
  git -C "$H" add -A
  git -C "$H" commit -q -m "Merge release N, with this home's own edits"
  python3 - "$REPLAY_FIXTURES/settings-v0.7.0.json" "$H/state/settings-before-merge.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["permissions"]["deny"].remove("Edit(./CLAUDE.md)")
d["permissions"]["ask"] = ["Bash(echo replay-ask)"]
open(sys.argv[2], "w").write(json.dumps(d, indent=2) + "\n")
PY
}
