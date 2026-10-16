#!/usr/bin/env bats
# core/update.py — `daedalus update` and `daedalus version` (update-command design, 2026-10-15, §4.2, §5.6).
# Each test builds, in its own temp dir: a bare "release" remote holding release N (the tree under test, as a
# release would ship it) and release N+1 (VERSION bumped, CLAUDE.md and .claude/settings.json changed in a known
# way); a deployment cloned from it at N; update.address set to the bare remote's path, so the release-address
# rule (Decision 20) matches it; a scratch HOME, git global config and session registry. The upgrade and doctor
# are stubbed (DAEDALUS_UPDATE_UPGRADE, DAEDALUS_UPDATE_DOCTOR) in every test here: none is about them.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  B="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export HOME="$B/home" GIT_CONFIG_GLOBAL="$B/gitconfig" GIT_CONFIG_NOSYSTEM=1 CLAUDE_CONFIG_DIR="$B"
  mkdir -p "$HOME" "$B/sessions" "$B/log"; : > "$GIT_CONFIG_GLOBAL"
  git config --global user.email t@x; git config --global user.name t; git config --global advice.detachedHead false
  unset DAEDALUS_HOME DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_LEASE DIRECT_CALL_ID
  N="$(sed -n 1p "$REPO/VERSION")"
  N1="$(python3 -c 'import sys; a = sys.argv[1].split("."); a[2] = str(int(a[2]) + 1); print(".".join(a))' "$N")"
  R="$B/release.git"
  seed_release "$R" main
  stubs
  H="$B/dae"
  deploy origin "$R"
  export N N1 R H B
}
teardown() { teardown_live; }

# seed_release <bare> <branch> — the bare remote with release N (every file of the tree under test git would
# track, committed or not yet: an executor runs this before committing) and release N+1 on <branch>, each tagged.
seed_release() {
  local bare="$1" br="$2" w="$B/rel-$(basename "$1" .git)"
  mkdir -p "$w"
  (cd "$REPO" && git ls-files --cached --others --exclude-standard -z) | python3 -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for rel in sys.stdin.read().split("\0"):
    if not rel or not os.path.isfile(os.path.join(src, rel)):
        continue
    os.makedirs(os.path.dirname(os.path.join(dst, rel)) or dst, exist_ok=True)
    shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))' "$REPO" "$w"
  git init -q -b "$br" "$w"
  if [ -n "${SEED_OLD:-}" ]; then   # a commit before release N with no core/update.py (a home the bootstrap reaches)
    mv "$w/core/update.py" "$B/update.py.aside"; git -C "$w" add -A; git -C "$w" commit -q -m "before update.py"
    git -C "$w" tag before-update; mv "$B/update.py.aside" "$w/core/update.py"
  fi
  git -C "$w" add -A; git -C "$w" commit -q -m "v$N"; git -C "$w" tag -a "v$N" -m "v$N"
  printf '%s\n' "$N1" > "$w/VERSION"
  printf '\nA line release %s added.\n' "$N1" >> "$w/CLAUDE.md"
  python3 - "$w/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("permissions", {}).setdefault("allow", []).append("Bash(echo next-release)")
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  git -C "$w" commit -q -am "v$N1"; git -C "$w" tag -a "v$N1" -m "v$N1"
  git init -q --bare -b "$br" "$bare"
  git -C "$w" push -q "$bare" "$br" --tags
}

# deploy <remote-name> <bare> [home] — a deployment cloned from <bare> under that remote name and put back at
# release N, upgraded to N (the stamp), with update.address naming the release remote.
deploy() {
  local name="$1" bare="$2" h="${3:-$H}"
  git clone -q -o "$name" "$bare" "$h"
  git -C "$h" reset -q --hard "v$N"
  mkdir -p "$h/state"; printf '%s\n' "$N" > "$h/state/upgraded-to"
  printf 'update:\n  address: %s\n' "${ADDRESS:-$R}" > "$h/config.yaml"
}

# stubs — the upgrade and doctor, stubbed. The upgrade records its arguments, waits while $STUB_WAIT is set and
# that file does not exist yet, stops while $STUB_STOP exists, and otherwise stamps VERSION. Doctor says OK.
stubs() {
  cat > "$B/stub-upgrade" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG/upgrade.args"
if [ -n "${STUB_WAIT:-}" ]; then
  : > "$STUB_WAIT.started"; i=0
  while [ ! -e "$STUB_WAIT" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
fi
if [ -n "${STUB_STOP:-}" ] && [ -e "$STUB_STOP" ]; then
  echo "Upgrade to $(sed -n 1p VERSION): step 1 done."
  echo "upgrade to $(sed -n 1p VERSION) incomplete: the safety copy would be too big; remove what target/ does not need, then run daedalus update again"
  exit 1
fi
mkdir -p state; sed -n 1p VERSION > state/upgraded-to
echo "Upgrade to $(sed -n 1p VERSION): complete."
EOF
  cat > "$B/stub-doctor" <<'EOF'
#!/bin/bash
echo "daedalus: OK       version: $(sed -n 1p VERSION)"
if [ -n "${STUB_DOCTOR_MISSING:-}" ]; then echo "daedalus: MISSING  $STUB_DOCTOR_MISSING"; echo "daedalus: 1 problem(s) found" >&2; exit 1; fi
echo "daedalus: deployment is wired correctly"
EOF
  chmod +x "$B/stub-upgrade" "$B/stub-doctor"
  export DAEDALUS_UPDATE_UPGRADE="$B/stub-upgrade" DAEDALUS_UPDATE_DOCTOR="$B/stub-doctor" STUB_LOG="$B/log"
}

upd() { python3 "$H/core/update.py" "$@" --home "$H" </dev/null; }

# listing — what a refusal must leave as it was: HEAD, the index, every file of the home by content (the lock
# file aside), the status, and the checkout's own git settings
listing() {
  (cd "$H" && git rev-parse HEAD && git ls-files -s && git status --porcelain --ignored \
     && git config --local --list | LC_ALL=C sort \
     && find . -path ./.git -prune -o -type f ! -name .update.lock -print | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s  %s\n' "$(shasum < "$f" | cut -c1-40)" "$f"; done)
}
trunk_sha() { git -C "$1" rev-parse "refs/heads/${2:-main}"; }

@test "update: a clean home fast-forwards to the release, runs the upgrade (--caller update --progress) and doctor, and says one line; a second run says it is up to date" {
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ -z "$(git -C "$H" status --porcelain)" ]
  [ "$(cat "$B/log/upgrade.args")" = "--caller update --progress" ]
  [ "$(git -C "$H" config --get branch.main.remote)" = origin ]
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus is up to date ($N1)." ] || { echo "$output"; return 1; }
  [ "$(wc -l < "$B/log/upgrade.args" | tr -d ' ')" = 1 ]
}

@test "update: doctor naming something ends the line with it, one sentence each, exit 2" {
  STUB_DOCTOR_MISSING="config: target.repo" run upd update
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Daedalus updated $N -> $N1; doctor names what needs attention: config: target.repo.") : ;; *) echo "$output"; return 1 ;; esac
}

@test "update: a remote named upstream with the release's address is used; with a fork named origin that the branch tracks and the release as upstream, upstream is used and the branch's tracking moves to it" {
  rm -rf "$H"; deploy upstream "$R"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  # the fork: the release plus a commit of its own, cloned as origin; the release added as upstream
  F="$B/fork.git"; git clone -q --bare "$R" "$F"
  git clone -q "$F" "$B/fork-work"; printf 'fork\n' > "$B/fork-work/FORK"; git -C "$B/fork-work" add FORK
  git -C "$B/fork-work" commit -q -m fork; git -C "$B/fork-work" push -q origin main
  rm -rf "$H"; deploy origin "$F"; git -C "$H" remote add upstream "$R"
  [ "$(git -C "$H" config --get branch.main.remote)" = origin ]
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ ! -e "$H/FORK" ]
  [ "$(git -C "$H" config --get branch.main.remote)" = upstream ]
  [ "$(git -C "$H" config --get branch.main.merge)" = refs/heads/main ]
}

@test "update: no remote with the release's address is refused with the add-remote sentence, and nothing is changed" {
  rm -rf "$H"; ADDRESS="$B/elsewhere.git" deploy origin "$R"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "No remote of this home has the release's address $B/elsewhere (remotes: origin → $R); add it with git remote add daedalus $B/elsewhere.git, then run daedalus update again. Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "update: the release's address is matched in its https, ssh and scp forms, with or without .git and a trailing slash, host case aside" {
  run python3 - "$REPO/core" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import update as u
want = u.normalise_address(u.RELEASE_ADDRESS)
for a in ("https://github.com/lpelty/daedalus.git", "https://GitHub.com/lpelty/daedalus/", "ssh://git@github.com/lpelty/daedalus.git",
          "git@github.com:lpelty/daedalus.git", "github.com/lpelty/daedalus", "http://github.com/lpelty/daedalus"):
    assert u.normalise_address(a) == want, a
for a in ("https://github.com/someone/daedalus.git", "git@github.com:lpelty/daedalus-fork.git", "/srv/daedalus.git"):
    assert u.normalise_address(a) != want, a
assert u.normalise_address("/srv/x/release.git/") == u.normalise_address("/srv/x/release")
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

@test "update: an address rewritten by insteadOf in settings outside the checkout is refused with the release-pull rule's sentence, and nothing is changed" {
  git config --global "url.$B/evil.git.insteadOf" "$R"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updating: an address rewrite (insteadOf) turns $R into $B/evil.git. Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "update: refused while a Daedalus session is live, naming its window, and nothing is changed" {
  p="$(live_pid)"; ms="$(ps_ms "$p")"
  mkdir -p "$H/state/leases"
  printf '{"lease":"01","session_id":"sL","pid":%s,"proc_started":%s}' "$p" "$ms" > "$H/state/leases/01.json"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updating: 1 Daedalus session is live in this home — window 01 (session sL). Close it, then run daedalus update again. Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
  [ ! -e "$B/log/upgrade.args" ]
}

@test "update: a remote that cannot be reached is one sentence, and nothing is changed" {
  mv "$R" "$B/gone.git"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Could not reach $R: "*". Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "update: a local edit to a tracked file is refused for now (the migration is not in this build), and nothing is changed" {
  printf 'local\n' >> "$H/README.md"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updating: this home has local edits in tracked files (README.md)"*"in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "update: a journal in SOUL.md (modified in the working tree) is kept across the fast-forward" {
  printf '\n## A journal entry\n' >> "$H/SOUL.md"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  grep -q '^## A journal entry$' "$H/SOUL.md"
  [ "$(git -C "$H" status --porcelain)" = " M SOUL.md" ]
}

@test "update: an upgrade that stops is passed through in its daedalus-update wording, exit 2, and the new code stays; a second run finishes it once the cause is gone" {
  : > "$B/stop"
  STUB_STOP="$B/stop" run upd update
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Daedalus updated $N -> $N1; the upgrade stopped: upgrade to $N1 incomplete: "*"then run daedalus update again") : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"start a session"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ "$(cat "$H/state/upgraded-to")" = "$N" ]
  rm "$B/stop"
  STUB_STOP="$B/stop" run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus is up to date ($N1); the upgrade finished; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(cat "$H/state/upgraded-to")" = "$N1" ]
}

@test "version: the release, the home, the remote and the tag; without a tag, no tag part" {
  run upd version
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus $N (home $H, remote origin, tag v$N)" ] || { echo "$output"; return 1; }
  git -C "$H" tag -l | xargs git -C "$H" tag -d >/dev/null
  run upd version
  [ "$output" = "Daedalus $N (home $H, remote origin)" ] || { echo "$output"; return 1; }
}

@test "update: no verb, an unknown verb, or no --home is the usage line, exit 2" {
  run python3 "$H/core/update.py" --home "$H" </dev/null
  [ "$status" -eq 2 ]; case "$output" in *"usage: daedalus update | daedalus version"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$H/core/update.py" rollback --home "$H" </dev/null
  [ "$status" -eq 2 ]
  run python3 "$H/core/update.py" update </dev/null
  [ "$status" -eq 2 ]
}

@test "update: while one update holds the home's update lock, a second is refused and a session start says only that the update is running — it starts no upgrade and writes no marker" {
  STUB_WAIT="$B/go" python3 "$H/core/update.py" update --home "$H" </dev/null >"$B/first.out" 2>&1 3>&- &
  first=$!; printf '%s\n' "$first" >> "$BATS_TEST_TMPDIR/live-pids"
  i=0; while [ ! -e "$B/go.started" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$B/go.started" ] || { cat "$B/first.out"; return 1; }
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Not updating: another daedalus update is running in this home. Nothing in this home was changed." ] || { echo "$output"; return 1; }
  run bash -c "printf '%s' '{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s9\",\"source\":\"startup\"}' | python3 '$H/core/session-start.py'"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"daedalus update is running in this home; close this session and start again once it prints its result"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$H/state/session-s9.json" ]
  [ "$(wc -l < "$B/log/upgrade.args" | tr -d ' ')" = 1 ]
  : > "$B/go"; wait "$first"
  [ "$(cat "$B/first.out")" = "Daedalus updated $N -> $N1; doctor OK." ] || { cat "$B/first.out"; return 1; }
}

@test "update: the trunk is the one the remote's HEAD names (here trunk, not main), found with no refs/remotes/<r>/HEAD in the home" {
  R2="$B/trunk.git"; seed_release "$R2" trunk
  rm -rf "$H"; ADDRESS="$R2" deploy origin "$R2"
  git -C "$H" remote set-head origin -d 2>/dev/null || true
  ! git -C "$H" rev-parse -q --verify refs/remotes/origin/HEAD
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R2" trunk)" ]
}

# marked_release — one more commit on $R's main whose core/update.py first prints "HANDED-OFF-MARKER <its args>"
marked_release() {
  git clone -q "$R" "$B/mark"
  python3 - "$B/mark/core/update.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "def main(argv: List[str]) -> int:\n"
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + '    print("HANDED-OFF-MARKER " + " ".join(argv[1:]), flush=True)\n')
open(p, "w").write(s)
PY
  git -C "$B/mark" commit -q -am "update.py with a marker"; git -C "$B/mark" push -q origin main
}

@test "hand-off: a home whose update.py differs from the release's runs the release's copy once, from a temporary directory outside the home, holding the parent's lock; --handed-off never hands off again" {
  marked_release
  mkdir -p "$B/tmp"
  TMPDIR="$B/tmp" run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c HANDED-OFF-MARKER)" = 1 ] || { echo "$output"; return 1; }
  case "$output" in *"HANDED-OFF-MARKER update --home $H --handed-off --lock-fd "[0-9]*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ -z "$(find "$H/state" -name update.py)" ]
  [ -z "$(ls -A "$B/tmp")" ] || { ls -A "$B/tmp"; return 1; }
  # the home now runs the release's copy itself: equal to the release, so no hand-off (the marker's args say so)
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "HANDED-OFF-MARKER update --home $H
Daedalus is up to date ($N1)." ] || { echo "$output"; return 1; }
  # started with --handed-off, the home's older copy does the update itself
  H="$B/dae2"; deploy origin "$R" "$H"
  run upd update --handed-off
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
}

@test "hand-off: a script read from a pipe always hands off, even when it is the release's own text" {
  marked_release
  run bash -c "git -C '$R' show main:core/update.py | python3 /dev/stdin update --home '$H'"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c HANDED-OFF-MARKER)" = 2 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c 'HANDED-OFF-MARKER update --home .* --handed-off --lock-fd [0-9]*$')" = 1 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
}

@test "bootstrap: the README's first-update line, run literally under bash and under zsh on a home with no core/update.py, updates it" {
  LINE='python3 <(git -C ~/daedalus fetch -q https://github.com/lpelty/daedalus.git main && git -C ~/daedalus show FETCH_HEAD:core/update.py) update --home ~/daedalus'
  if grep -q 'FETCH_HEAD:core/update.py' "$REPO/README.md"; then
    grep -qxF "$LINE" "$REPO/README.md" || { echo "README's first-update line is not the one tested"; return 1; }
  fi
  R3="$B/old.git"; SEED_OLD=1 seed_release "$R3" main
  local here="${LINE//https:\/\/github.com\/lpelty\/daedalus.git/$R3}" sh i=0
  for sh in /bin/bash /bin/zsh; do
    i=$((i + 1)); export HOME="$B/home$i"; mkdir -p "$HOME"
    ADDRESS="$R3" deploy origin "$R3" "$HOME/daedalus"
    git -C "$HOME/daedalus" reset -q --hard before-update
    [ ! -e "$HOME/daedalus/core/update.py" ]
    run "$sh" -c "$here" </dev/null
    [ "$status" -eq 0 ] || { echo "$sh status $status: $output"; return 1; }
    [ "$output" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$sh: $output"; return 1; }
    [ "$(git -C "$HOME/daedalus" rev-parse HEAD)" = "$(trunk_sha "$R3")" ]
    [ -f "$HOME/daedalus/core/update.py" ]
  done
}
