# core/tests/fixtures/update/vault.bash — sourced by test_update.bats. A home that keeps its vault in its own
# repository, as the second laptop does:
#   - its .gitignore un-ignores vault/ (the release ignores it) and vault/ is committed: 40 files in several commits;
#   - its history: local commits, then a hand merge of release N over them, then more local commits;
#   - a local edit, committed, in CLAUDE.md and in .claude/settings.json;
#   - its origin is a private bare repository it pushes main to; the release is the remote named daedalus.
# Needs: $H deployed, $R with the tag "older" before release N (older_release).
tracked_vault_home() {
  git -C "$H" reset -q --hard older
  git -C "$H" remote rename origin daedalus
  printf '\n# this home keeps its vault in this repository\n!vault/\n' >> "$H/.gitignore"
  git -C "$H" add .gitignore; git -C "$H" commit -q -m "track the vault here"
  local i
  for i in $(seq 1 15); do mkdir -p "$H/vault/sessions"; printf 'session %s\n' "$i" > "$H/vault/sessions/s$i.md"; done
  git -C "$H" add vault; git -C "$H" commit -q -m "vault: sessions"
  for i in $(seq 1 10); do mkdir -p "$H/vault/proposals"; printf 'proposal %s\n' "$i" > "$H/vault/proposals/p$i.md"; done
  git -C "$H" add vault; git -C "$H" commit -q -m "vault: proposals"
  git -C "$H" merge -q --no-ff -m "Merge release v$N by hand" "v$N"
  for i in $(seq 1 15); do mkdir -p "$H/vault/notes"; printf 'note %s\n' "$i" > "$H/vault/notes/n$i.md"; done
  git -C "$H" add vault; git -C "$H" commit -q -m "vault: notes"
  printf '\nA line this home keeps in its brief.\n' >> "$H/CLAUDE.md"
  python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"].setdefault("allow", []).append("Bash(echo this-home)")
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  git -C "$H" commit -q -am "this home's brief line and allow rule"
  git init -q --bare -b main "$B/private.git"
  git -C "$H" remote add origin "$B/private.git"; git -C "$H" push -q -u origin main
  printf '%s\n' "$N" > "$H/state/upgraded-to"
}
# vault_sums — every vault file by content, tracked or not, and its git status
vault_sums() {
  (cd "$H" && find vault -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(shasum < "$f" | cut -c1-40)" "$f"; done
   git status --porcelain --ignored -- vault)
}
