#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DAEDALUS_HOME
}

@test "target/ is gitignored" {
  cd "$DAEDALUS_HOME"
  run git check-ignore -q target/anything
  [ "$status" -eq 0 ]
}

@test "vault/ is gitignored" {
  cd "$DAEDALUS_HOME"
  run git check-ignore -q vault/anything
  [ "$status" -eq 0 ]
}

@test "config.yaml is gitignored but config.example.yaml is not" {
  cd "$DAEDALUS_HOME"
  run git check-ignore -q config.yaml
  [ "$status" -eq 0 ]
  run git check-ignore -q config.example.yaml
  [ "$status" -ne 0 ]
}

# PROTECTED PATHS — the single source of truth for the tests below.
#
# One representative concrete file per protected area, NOT the glob text of the
# deny rules. The tests ask "is this file covered by some Edit rule?", which is
# a question about the protection actually in force; asserting the glob text
# would only restate the config back to itself, and would break on a rule that
# was legitimately broadened or narrowed while still covering the file.
#
# Deliberately not a count of anything. Adding a protected area means adding a
# line here; no test needs its total edited to stay green.
_protected_paths() {
  cat <<'EOF'
./core/capture.py
./CLAUDE.md
./SOUL.md
./.claude/settings.json
./.claude/settings.local.json
./config.example.yaml
./README.md
./config.yaml
./state/evidence/keep
./vault/evidence/keep
EOF
}

# Reports which of the given paths are NOT covered by any Edit(...) deny rule
# in the settings file named as the first argument. Coverage is glob matching
# against the rule's path, not string equality — a broader rule that still
# covers the file counts, which is what "protected" actually means.
_uncovered_by_edit_rules() {
  settings="$1"
  shift
  python3 - "$settings" "$@" <<'PY'
import fnmatch, json, os, sys

settings, paths = sys.argv[1], sys.argv[2:]
if not os.path.exists(settings):
    print(" ".join(paths))
    sys.exit(0)

with open(settings) as fh:
    deny = json.load(fh).get("permissions", {}).get("deny", [])

globs = [r[len("Edit("):-1] for r in deny
         if r.startswith("Edit(") and r.endswith(")")]

uncovered = [p for p in paths
             if not any(fnmatch.fnmatch(p, g) or fnmatch.fnmatch(p.lstrip("./"), g.lstrip("./"))
                        for g in globs)]
print(" ".join(uncovered))
PY
}

# Reports every deny rule that names the Write tool, across both settings files.
#
# WHY THIS IS AN ASSERTION AND NOT AN OVERSIGHT — read before "fixing" the deny
# list by pairing each Edit rule with a Write one:
#
#   Edit(path) deny rules cover ALL built-in file-editing tools — Edit, Write,
#   NotebookEdit, the legacy multi-edit tool — plus file-touching commands the
#   agent recognizes in a shell call. One Edit rule is the whole protection.
#
#   Write(path) rules in a deny list are ACCEPTED BUT NEVER CONSULTED. They are
#   inert for file protection and are the sole cause of the startup warning
#   "... is not matched by file permission checks — only Edit(path) rules are."
#
# So adding a Write rule back reintroduces the warning without adding one byte
# of protection. The suite previously demanded those rules and passed happily
# while half the rules it required were doing nothing — it was pinning the bug
# in place. This function is what stops that from recurring.
_write_rules_in() {
  python3 - "$@" <<'PY'
import json, os, sys

found = []
for settings in sys.argv[1:]:
    if not os.path.exists(settings):
        continue
    with open(settings) as fh:
        deny = json.load(fh).get("permissions", {}).get("deny", [])
    found += ["%s: %s" % (settings, r) for r in deny if r.startswith("Write(")]
print("; ".join(found))
PY
}

# Glob matching does not require a file to exist, so a protected path that was
# renamed or deleted would keep "passing" coverage forever while guarding
# nothing. This pins the representative paths to real files, which is what makes
# the coverage test above meaningful rather than self-satisfying.
@test "every protected path names a file that exists" {
  cd "$DAEDALUS_HOME"
  missing=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # settings.local.json is per-deployment and absent on a fresh clone;
    # state/evidence and vault/evidence are gitignored evidence directories
    # with no committed contents. Their coverage still matters, so they are
    # exempt from existence but not from the Edit-rule check.
    case "$p" in
      ./.claude/settings.local.json|./config.yaml|./state/evidence/keep|./vault/evidence/keep) continue ;;
    esac
    [ -e "$p" ] || missing="$missing $p"
  done <<EOF
$(_protected_paths)
EOF
  [ -z "$missing" ] || { echo "protected path does not exist:$missing"; return 1; }
}

@test "every protected path is covered by an Edit deny rule" {
  cd "$DAEDALUS_HOME"
  # shellcheck disable=SC2046
  uncovered=$(_uncovered_by_edit_rules .claude/settings.json $(_protected_paths))
  [ -z "$uncovered" ] || { echo "no Edit deny rule covers:$uncovered"; return 1; }
}

@test "no deny rule names the Write tool, in either settings file" {
  cd "$DAEDALUS_HOME"
  offenders=$(_write_rules_in .claude/settings.json .claude/settings.local.json)
  [ -z "$offenders" ] || {
    echo "inert Write deny rule present (see the comment above _write_rules_in): $offenders"
    return 1
  }
}

@test "the deny list does not block .claude/skills/**" {
  cd "$DAEDALUS_HOME"
  run grep -qF '.claude/skills' .claude/settings.json
  [ "$status" -ne 0 ]
}

@test ".claude/settings.local.json is gitignored by the repo's own rules" {
  cd "$DAEDALUS_HOME"
  # Override core.excludesfile to neutralize any operator's global gitignore
  # (e.g. ~/.gitignore_global) so this only exercises the repo's own
  # .gitignore. Without this override the test could pass for the wrong
  # reason on a machine whose global config happens to cover this path.
  run git -c core.excludesfile=/dev/null check-ignore -q .claude/settings.local.json
  [ "$status" -eq 0 ]
}

@test "state/ and .capture.log are gitignored by the repo's own rules" {
  cd "$DAEDALUS_HOME"
  # Override core.excludesfile to neutralize any operator's global gitignore
  # so this only exercises the repo's own .gitignore.
  run git -c core.excludesfile=/dev/null check-ignore -q state/hindsight/offsets.json
  [ "$status" -eq 0 ]
  run git -c core.excludesfile=/dev/null check-ignore -q .capture.log
  [ "$status" -eq 0 ]
}

@test "both settings files are protected, local included" {
  cd "$DAEDALUS_HOME"
  # settings.local.json holds a deployment's own deny rules. An agent able to
  # rewrite its own permission surface can lift every other restriction, so it
  # is protected alongside the tracked settings file. The broad ./.claude/**
  # rule used to cover it incidentally; narrowing that rule to unblock skills
  # removed the coverage, and this test pins it back.
  #
  # Both files are already in _protected_paths, so the coverage test above would
  # catch a regression here too. This test is kept separate for its failure
  # signal: it names the permission surface specifically, which is the
  # highest-stakes entry in that list and the one whose loss is self-amplifying.
  uncovered=$(_uncovered_by_edit_rules .claude/settings.json \
    ./.claude/settings.json ./.claude/settings.local.json)
  [ -z "$uncovered" ] || { echo "permission surface unprotected:$uncovered"; return 1; }
}

@test "settings.json parses with unique keys and every wired hook event survives" {
  cd "$DAEDALUS_HOME"
  # The verify-stage merge produced two top-level "hooks" keys; JSON parsers
  # keep the last, so SessionStart, guard-bash, boundary, and the verify Stop
  # hook were silently dark while the file looked fully wired (found live,
  # 2026-08-31). Duplicate keys anywhere in the file are a parse-shadowing
  # hazard, and the event list asserts the protection actually in force —
  # the same posture as the deny-rule coverage tests above.
  run python3 - <<'PY'
import json, sys

def reject_dupes(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen:
            sys.exit("duplicate key shadows earlier value: %r" % k)
        seen.add(k)
    return dict(pairs)

with open(".claude/settings.json") as fh:
    cfg = json.load(fh, object_pairs_hook=reject_dupes)

events = set(cfg.get("hooks", {}))
missing = {"SessionStart", "PreToolUse", "PostToolUse", "Stop", "PreCompact"} - events
if missing:
    sys.exit("hook events lost from effective config: %s" % sorted(missing))

cmds = json.dumps(cfg["hooks"])
for script in ("session-start.py", "guard-bash.py", "pitfall-inject.py",
               "boundary-hook.py", "verify-hook.py"):
    if script not in cmds:
        sys.exit("hook script not wired in effective config: %s" % script)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
