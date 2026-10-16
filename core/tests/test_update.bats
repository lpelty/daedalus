#!/usr/bin/env bats
# core/update.py — `daedalus update` and `daedalus version` (update-command design, 2026-10-15, §4.2, §5.6).
# Each test builds, in its own temp dir: a bare "release" remote holding release N (the tree under test, as a
# release would ship it) and release N+1 (VERSION bumped, CLAUDE.md and .claude/settings.json changed in a known
# way); a deployment cloned from it at N; update.address set to the bare remote's path, so the release-address
# rule (Decision 20) matches it; a scratch HOME, git global config and session registry. The upgrade and doctor
# are stubbed (DAEDALUS_UPDATE_UPGRADE, DAEDALUS_UPDATE_DOCTOR) in every test here: none is about them.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
load fixtures/update/replay.bash
load fixtures/update/vault.bash

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
  if [ -n "${SEED_OLD_SETTINGS:-}" ]; then   # an older release before N: v0.7.0's ./-anchored settings, one more
    # brief line and one more README line than N has (the history the migration judges "local" against)
    cp "$w/.claude/settings.json" "$B/settings.aside"; cp "$w/CLAUDE.md" "$B/claude.aside"; cp "$w/README.md" "$B/readme.aside"
    cp "$REPO/core/tests/fixtures/update/settings-v0.7.0.json" "$w/.claude/settings.json"
    printf '\nAn older release'"'"'s brief line.\n' >> "$w/CLAUDE.md"
    printf '\nAn older release'"'"'s README line.\n' >> "$w/README.md"
    git -C "$w" add -A; git -C "$w" commit -q -m "older"; git -C "$w" tag older
    cp "$B/settings.aside" "$w/.claude/settings.json"; cp "$B/claude.aside" "$w/CLAUDE.md"; cp "$B/readme.aside" "$w/README.md"
  fi
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
  printf 'A file release %s adds.\n' "$N1" > "$w/NEXT-RELEASE.md"; git -C "$w" add NEXT-RELEASE.md
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
  # the result leads; each finding is a later line, never appended to the first
  [ "$output" = "Daedalus updated $N -> $N1.
Doctor: config: target.repo." ] || { echo "$output"; return 1; }
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
  case "$output" in "Not updated: no remote of this home has the release's address $B/elsewhere (remotes: origin → $R); add it with git remote add daedalus $B/elsewhere.git, then run daedalus update again. Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "update: the release's address is matched in its https, ssh and scp forms, with or without .git and a trailing slash, host case and a GitHub path's case aside" {
  run python3 - "$REPO/core" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import update as u
want = u.normalise_address(u.RELEASE_ADDRESS)
for a in ("https://github.com/lpelty/daedalus.git", "https://GitHub.com/lpelty/daedalus/", "ssh://git@github.com/lpelty/daedalus.git",
          "git@github.com:lpelty/daedalus.git", "github.com/lpelty/daedalus", "http://github.com/lpelty/daedalus",
          "https://github.com/LPelty/Daedalus.git", "git@GitHub.com:LPELTY/daedalus"):
    assert u.normalise_address(a) == want, a
# the same account's fork, derived from the constant (a sibling repository whose name only starts the same)
for a in ("https://github.com/someone/daedalus.git", "git@github.com:" + u.RELEASE_ADDRESS.split("/", 1)[1] + "-fork.git",
          "/srv/daedalus.git"):
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
  case "$output" in "Not updated: an address rewrite (insteadOf) turns $R into $B/evil.git. Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "update: refused while a Daedalus session is live, naming its window, and nothing is changed" {
  p="$(live_pid)"; ms="$(ps_ms "$p")"
  mkdir -p "$H/state/leases"
  printf '{"lease":"01","session_id":"sL","pid":%s,"proc_started":%s}' "$p" "$ms" > "$H/state/leases/01.json"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: 1 Daedalus session is live in this home — window 01 (session sL). Close it, then run daedalus update again. Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
  [ ! -e "$B/log/upgrade.args" ]
}

@test "update: a remote that cannot be reached is one sentence, and nothing is changed" {
  mv "$R" "$B/gone.git"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: could not reach $R ("*"). Nothing in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  # git's own cause, not the tail of its multi-line advice, and no doubled period
  case "$output" in *".."*|*": and the repository exists"*) echo "$output"; return 1 ;; esac
  case "$output" in *"does not appear to be a git repository"*) : ;; *) echo "$output"; return 1 ;; esac
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
  case "$output" in "Daedalus updated $N -> $N1."$'\n'"The upgrade stopped: upgrade to $N1 incomplete: "*"then run daedalus update again.") : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"start a session"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ "$(cat "$H/state/upgraded-to")" = "$N" ]
  rm "$B/stop"
  STUB_STOP="$B/stop" run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus is up to date ($N1); doctor OK.
The upgrade that had stopped has finished." ] || { echo "$output"; return 1; }
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
  [ "$output" = "Not updated: another daedalus update is running in this home. Nothing in this home was changed." ] || { echo "$output"; return 1; }
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
  # the README and the v0.7.3 CHANGELOG section carry exactly this line, on a line of its own
  for f in README.md CHANGELOG.md; do
    grep -qxF "$LINE" "$REPO/$f" || { echo "$f's first-update line is not the one tested"; return 1; }
  done
  R3="$B/old.git"; SEED_OLD=1 seed_release "$R3" main
  local url='https://github.com/lpelty/daedalus.git'
  local here="${LINE//"$url"/$R3}" sh i=0
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

# --- the local-layer migration (Decisions 4, 15, 16, 21; §4.3, §5.6 tests 20-22, 33-36, 39, 40) ---------------------

# older_release — $R reseeded with an older release before N (tag "older"), and the home deployed again at N
older_release() {
  rm -rf "$R" "$H" "$B/rel-release"; SEED_OLD_SETTINGS=1 seed_release "$R" main; deploy origin "$R"
}
# six — the sha256 of the six files a migration reads or writes, and the home's status, ignored files included
six() {
  (cd "$H" && git status --porcelain --ignored -- . ':!state' && for f in CLAUDE.md CLAUDE.local.md .claude/settings.json \
     .claude/settings.local.json config.yaml SOUL.md; do printf '%s  %s\n' "$( [ -e "$f" ] && shasum -a 256 < "$f" | cut -c1-64 || echo absent)" "$f"; done)
}
jq_py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(eval(sys.argv[2]), sort_keys=True))" "$@"; }

@test "migration replay of the second machine: a home that merged release N over local commits moves its rules, hook and brief lines into the local layer, keeps the committed journal, backs up, and a second run is byte-identical" {
  older_release
  replay_home
  orig="$(git -C "$H" rev-parse HEAD)"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 3 ] || { echo "$output"; return 1; }
  stamp="$(git -C "$H" for-each-ref --format='%(refname:short)' refs/heads/local/ | sed -n 's#^local/before-update-##p')"
  [ -n "$stamp" ] || { git -C "$H" branch -a; return 1; }
  [ "${lines[0]}" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "Local edits moved to .claude/settings.local.json and CLAUDE.local.md; backup at local/before-update-$stamp and state/update-backups/$stamp/." ] || { echo "$output"; return 1; }
  case "${lines[2]}" in *"boundary.edit_brief is now true in config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ "$(git -C "$H" status --porcelain)" = " M SOUL.md" ] || { git -C "$H" status --porcelain; return 1; }
  grep -q '^## Journal: a committed entry$' "$H/SOUL.md"
  [ "$(jq_py "$H/.claude/settings.local.json" 'd["permissions"]')" = '{"allow": ["Bash(echo replay-allow)"], "ask": ["Bash(echo replay-ask)"]}' ] || { cat "$H/.claude/settings.local.json"; return 1; }
  [ "$(jq_py "$H/.claude/settings.local.json" 'sorted(d["hooks"])')" = '["PreToolUse"]' ]
  [ "$(jq_py "$H/.claude/settings.local.json" '[h["command"] for g in d["hooks"]["PreToolUse"] for h in g["hooks"]]')" = '["echo replay-hook"]' ]
  ! grep -q 'deny\|\./' "$H/.claude/settings.local.json"
  grep -q '^  edit_brief: true$' "$H/config.yaml"
  grep -q "^## Local brief — moved from CLAUDE.md by daedalus update, .* (backup: local/before-update-$stamp)$" "$H/CLAUDE.local.md"
  [ "$(grep -c '^Replay local line ' "$H/CLAUDE.local.md")" = 4 ]
  ! grep -q "An older release" "$H/CLAUDE.local.md"
  # the backup: the old tree on the branch (on top of the original HEAD), and the six copies
  [ "$(git -C "$H" rev-parse "local/before-update-$stamp^")" = "$orig" ]
  git -C "$H" show "local/before-update-$stamp:CLAUDE.md" | grep -q '^Replay local line four.$'
  for f in CLAUDE.md CLAUDE.local.md.absent settings.json settings.local.json.absent config.yaml SOUL.md settings-before-merge.json; do
    [ -e "$H/state/update-backups/$stamp/$f" ] || { ls -A "$H/state/update-backups/$stamp"; return 1; }
  done
  [ ! -e "$H/state/settings-before-merge.json" ]
  before="$(six)"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus is up to date ($N1)." ] || { echo "$output"; return 1; }
  [ "$(six)" = "$before" ] || { diff <(printf '%s\n' "$before") <(six); return 1; }
}

@test "migration refused: an uncommitted or a committed local edit to core/lease.sh is refused, naming it, and nothing is changed; an older release's copy checked out on purpose is reported as pinned and replaced" {
  printf '# local\n' >> "$H/core/lease.sh"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: core/lease.sh carries local changes the update cannot carry"*"fetched origin/main, and nothing else in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
  git -C "$H" commit -q -am "a local core edit"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: core/lease.sh carries local changes"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
  # pinned: README.md as an older release had it
  older_release
  git -C "$H" show older:README.md > "$H/README.md"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"README.md held an older release's copy; the release's copy replaces it."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ -z "$(git -C "$H" status --porcelain)" ]
}

@test "migration refused: an untracked file at a path the release adds is refused, naming it, and nothing is changed; so is a merge in progress" {
  printf 'mine\n' > "$H/NEXT-RELEASE.md"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: NEXT-RELEASE.md is untracked here where the release adds files; move it out of the release's way"*"nothing else in this home was changed.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
  rm "$H/NEXT-RELEASE.md"
  git -C "$H" rev-parse HEAD > "$H/.git/MERGE_HEAD"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: a merge is in progress in this home; finish it, then run daedalus update again;"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "migration settings, future release: a release that drops an allow rule and changes a hook's timeout moves only the deployment's own rule, and reports no deployment removal" {
  git clone -q "$R" "$B/next"
  python3 - "$B/next/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["allow"].remove("Bash(core/lease.sh release:*)")
d["hooks"]["SessionStart"][0]["hooks"][0]["timeout"] = 45
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  git -C "$B/next" commit -q -am "drop a rule, change a timeout"; git -C "$B/next" push -q origin main
  python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["allow"].append("Bash(echo mine)")
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"removed"*|*"changed the"*) echo "$output"; return 1 ;; esac
  [ "$(jq_py "$H/.claude/settings.local.json" 'd')" = '{"permissions": {"allow": ["Bash(echo mine)"]}}' ] || { cat "$H/.claude/settings.local.json"; return 1; }
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ -z "$(git -C "$H" status --porcelain)" ]
}

@test "migration settings, modified hook: a deployment's changed timeout on a release hook is not moved, it is reported, and the release's hook runs alone" {
  python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["hooks"]["SessionStart"][0]["hooks"][0]["timeout"] = 99
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"The deployment had changed the SessionStart hook; the release's runs; the old one is in state/update-backups/"*"/settings.json."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$H/.claude/settings.local.json" ]
  [ "$(jq_py "$H/.claude/settings.json" 'len(d["hooks"]["SessionStart"])')" = 1 ]
  [ -z "$(git -C "$H" status --porcelain)" ]
}

@test "migration brief: an appended line moves to CLAUDE.local.md, a reworded release line is reported and not moved, and a line merged in from an older release is not moved" {
  older_release
  python3 - "$H/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
i = next(k for k, l in enumerate(lines) if l.startswith("## Windows and the pen"))
j = next(k for k in range(i + 1, len(lines)) if lines[k].strip() and not lines[k].startswith("#"))
lines[j] = "Reworded by this home: " + lines[j]
lines.insert(j + 2, "An older release's brief line.")
open(p, "w").write("\n".join(lines).rstrip("\n") + "\n\nA line this home appended.\n")
PY
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"CLAUDE.md: the deployment had reworded 1 passage of the release's brief, under 'Windows and the pen'; the release's wording is back"*) : ;; *) echo "$output"; return 1 ;; esac
  grep -qx 'A line this home appended.' "$H/CLAUDE.local.md"
  ! grep -q 'Reworded by this home' "$H/CLAUDE.local.md"
  ! grep -q "An older release's brief line" "$H/CLAUDE.local.md"
  [ "$(git -C "$H" rev-parse HEAD)" = "$(trunk_sha "$R")" ]
  [ -z "$(git -C "$H" status --porcelain)" ]
  cmp -s "$H/CLAUDE.md" <(git -C "$R" show main:CLAUDE.md)
}

@test "migration restore: a reset that fails puts back the original HEAD (not the backup commit), the original working-tree changes unstaged, and every local-layer file as it was" {
  printf '\nA line this home appended.\n' >> "$H/CLAUDE.md"
  python3 - "$H/.claude/settings.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["permissions"]["deny"].remove("Edit(/CLAUDE.md)")
d["permissions"]["allow"].append("Bash(echo mine)")
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
  printf '{"permissions": {"deny": ["Edit(//elsewhere/x)"]}}\n' > "$H/.claude/settings.local.json"
  git -C "$H" commit -q -m "a local commit" -- .claude/settings.json
  orig="$(git -C "$H" rev-parse HEAD)"
  diff_before="$(git -C "$H" diff HEAD)"; cached_before="$(git -C "$H" diff --cached)"
  sl="$(shasum < "$H/.claude/settings.local.json")"; cy="$(shasum < "$H/config.yaml")"
  real="$(command -v git)"; target="$(trunk_sha "$R")"; mkdir -p "$B/bin"
  printf '#!/bin/bash\ncase " $* " in *" reset "*"--hard"*"%s"*) echo "fatal: injected failure" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
    "$target" "$real" > "$B/bin/git"
  chmod +x "$B/bin/git"
  PATH="$B/bin:$PATH" run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  case "$output" in "Not updated: "*"injected failure"*"this home is back as it was"*"local/before-update-"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" rev-parse HEAD)" = "$orig" ]
  [ "$(git -C "$H" rev-parse HEAD)" != "$(git -C "$H" for-each-ref --format='%(objectname)' refs/heads/local/)" ]
  ! git -C "$H" log --format=%s | grep -q "daedalus update"
  [ "$(git -C "$H" diff HEAD)" = "$diff_before" ]
  [ "$(git -C "$H" diff --cached)" = "$cached_before" ]
  [ ! -e "$H/CLAUDE.local.md" ]
  [ "$(shasum < "$H/.claude/settings.local.json")" = "$sl" ]
  [ "$(shasum < "$H/config.yaml")" = "$cy" ]
}

@test "migration auto mode: a ~/.claude/settings.json whose auto-mode line lets this home's CLAUDE.md be edited is reported once, and the file is never written" {
  mkdir -p "$HOME/.claude"
  python3 - "$HOME/.claude/settings.json" "$H" <<'PY'
import json, sys
json.dump({"autoMode": {"allow": ["$defaults", "Editing CLAUDE.md in the Daedalus home at %s when the operator asked for that change in this session: the deployment chose to let Daedalus maintain its own brief." % sys.argv[2]]}}, open(sys.argv[1], "w"), indent=2)
PY
  sum="$(shasum < "$HOME/.claude/settings.json")"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"~/.claude/settings.json allows auto mode to edit CLAUDE.md here; reword that line to name CLAUDE.local.md (README, 'Letting Daedalus edit its own brief')."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | grep -o 'allows auto mode' | wc -l | tr -d ' ')" = 1 ]
  [ "$(shasum < "$HOME/.claude/settings.json")" = "$sum" ]
}

@test "migration normalising: update.normalise_rule agrees with verifylib.home_relative_glob on every anchor form" {
  run python3 - "$REPO/core" "$H" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
import update as u, verifylib as v
home = Path(sys.argv[2])
forms = ["/CLAUDE.md", "./CLAUDE.md", "//%s/CLAUDE.md" % home, "CLAUDE.md", "core/", "/core/**", "//elsewhere/x", "~/x"]
for p in forms:
    g = v.home_relative_glob(home, p)
    want = "Edit(%s)" % g if g is not None else "Edit(%s)" % p
    got = u.normalise_rule(home, "Edit(%s)" % p)
    assert got == want, (p, got, want)
assert u.normalise_rule(home, "Edit(./SOUL.md)") == u.normalise_rule(home, "Edit(/SOUL.md)") == u.normalise_rule(home, "Edit(//%s/SOUL.md)" % home)
assert u.normalise_rule(home, "Bash(core/lease.sh release:*)") == "Bash(core/lease.sh release:*)"
print("ok")
PY
  [ "$status" -eq 0 ] && [ "$output" = ok ] || { echo "$output"; return 1; }
}

# --- the shim (§4.1, §5.6 test 27) and doctor's lines from update.py --doctor (§4.5) ---------------------------------
# A fake login shell: `<shell> -l -c <command>` runs the command under /bin/sh with $FAKE_LOGIN_PATH as its PATH, the
# PATH a login shell's startup files would give; named zsh and bash so the PATH line is worded for each. A broken
# shell exits 1 having run nothing.
login_shells() {
  mkdir -p "$B/shells"
  printf '#!/bin/sh\n[ "$1" = -l ] && [ "$2" = -c ] || exit 9\nPATH="$FAKE_LOGIN_PATH" exec /bin/sh -c "$3"\n' > "$B/shells/zsh"
  cp "$B/shells/zsh" "$B/shells/bash"; printf '#!/bin/sh\nexit 1\n' > "$B/shells/broken"
  chmod +x "$B/shells/zsh" "$B/shells/bash" "$B/shells/broken"
  unset DAEDALUS_NO_COMMAND
  export SHELL="$B/shells/zsh" FAKE_LOGIN_PATH="$HOME/.local/bin:/usr/bin:/bin"
  SHIM="$HOME/.local/bin/daedalus"
}
shim() { python3 "${2:-$H}/core/update.py" --install-shim --home "${2:-$H}" </dev/null; }
sha() { shasum < "$1" | cut -c1-40; }

@test "shim: absent, it is written mode 755 with the marker naming this home and runs daedalus version; a second install says nothing and leaves it; one for this home with another body is rewritten" {
  login_shells
  run shim
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Installed the daedalus command at ~/.local/bin/daedalus; type daedalus update in a terminal (or ~/.local/bin/daedalus update)." ] || { echo "$output"; return 1; }
  [ "$(stat -f %Lp "$SHIM")" = 755 ]
  [ "$(sed -n 2p "$SHIM")" = "# daedalus shim — installed by core/setup.sh for the home below; safe to delete" ]
  [ "$(sed -n 3p "$SHIM")" = "exec python3 \"$H/core/update.py\" \"\$@\" --home \"$H\"" ] || { cat "$SHIM"; return 1; }
  run "$SHIM" version
  case "$output" in "Daedalus $N (home $H, remote origin"*) : ;; *) echo "$output"; return 1 ;; esac
  before="$(sha "$SHIM")"; touch -t 202001010000 "$SHIM"
  run shim
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "status $status: $output"; return 1; }
  [ "$(sha "$SHIM")" = "$before" ]; [ "$(stat -f %Sm -t %Y "$SHIM")" = 2020 ]
  printf '# an older body\n' >> "$SHIM"
  run shim
  [ "$output" = "Rewrote ~/.local/bin/daedalus for this home (its text was an older shim's)." ] || { echo "$output"; return 1; }
  [ "$(sha "$SHIM")" = "$before" ]
}

@test "shim: one serving another live home is left with a line; one whose home has moved (no core/update.py there) is rewritten with a line; a file the install did not write is left with a line" {
  login_shells
  O="$B/other"; mkdir -p "$O/core"; cp "$H/core/update.py" "$O/core/update.py"
  run shim "" "$O"; [ -f "$SHIM" ] || { echo "$output"; return 1; }
  before="$(sha "$SHIM")"
  run shim
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "~/.local/bin/daedalus serves $O; this home is not on the command, so type python3 $H/core/update.py update --home $H here." ] || { echo "$output"; return 1; }
  [ "$(sha "$SHIM")" = "$before" ]
  rm -rf "$O"
  run shim
  [ "$output" = "~/.local/bin/daedalus served $O, which has no core/update.py any more; it now serves this home." ] || { echo "$output"; return 1; }
  grep -q -- "--home \"$H\"" "$SHIM"
  printf '#!/bin/sh\necho mine\n' > "$SHIM"; before="$(sha "$SHIM")"
  run shim
  [ "$output" = "~/.local/bin/daedalus is not a shim daedalus wrote, so it was left as it is; type python3 $H/core/update.py update --home $H instead." ] || { echo "$output"; return 1; }
  [ "$(sha "$SHIM")" = "$before" ]
}

@test "shim: a ~/.local that cannot be written is one line naming it, and nothing is written" {
  login_shells
  mkdir -p "$HOME/.local"; chmod 555 "$HOME/.local"
  run shim
  chmod 755 "$HOME/.local"
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "~/.local/bin could not be made ("*"); the daedalus command was not installed, so type python3 $H/core/update.py update --home $H instead.") : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$HOME/.local/bin" ]
}

@test "shim: off the login shell's PATH it says the shell's line and the full-path form (zsh, bash); another daedalus earlier on PATH is the shadow line; a login shell that fails falls back to this process's PATH" {
  login_shells
  shim >/dev/null
  FAKE_LOGIN_PATH="/usr/bin:/bin" run shim
  [ "$output" = "Add ~/.local/bin to PATH: echo 'path+=~/.local/bin' >> ~/.zshrc (new terminals); until then type ~/.local/bin/daedalus update." ] || { echo "$output"; return 1; }
  SHELL="$B/shells/bash" FAKE_LOGIN_PATH="/usr/bin:/bin" run shim
  [ "$output" = "Add ~/.local/bin to PATH: echo 'PATH=~/.local/bin:\$PATH' >> ~/.bash_profile (new terminals); until then type ~/.local/bin/daedalus update." ] || { echo "$output"; return 1; }
  mkdir -p "$B/early"; printf '#!/bin/sh\n' > "$B/early/daedalus"; chmod +x "$B/early/daedalus"
  FAKE_LOGIN_PATH="$B/early:$HOME/.local/bin:/usr/bin:/bin" run shim
  [ "$output" = "Another daedalus ($B/early/daedalus) comes first on PATH; use ~/.local/bin/daedalus update." ] || { echo "$output"; return 1; }
  SHELL="$B/shells/broken" PATH="$HOME/.local/bin:$PATH" run shim
  [ -z "$output" ] || { echo "on this process's PATH: $output"; return 1; }
  SHELL="$B/shells/broken" run shim
  case "$output" in "Add ~/.local/bin to PATH"*"until then type ~/.local/bin/daedalus update.") : ;; *) echo "$output"; return 1 ;; esac
}

@test "shim and doctor: update.py --doctor names the command (absent, then OK once installed and on PATH), and DAEDALUS_NO_COMMAND keeps both the install and the check silent" {
  login_shells
  run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"NOTE     command: ~/.local/bin/daedalus is absent; core/setup.sh installs it (until then type python3 $H/core/update.py update --home $H)"*) : ;; *) echo "$output"; return 1 ;; esac
  shim >/dev/null
  run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"OK       command: daedalus on PATH (~/.local/bin/daedalus)"*) : ;; *) echo "$output"; return 1 ;; esac
  FAKE_LOGIN_PATH="/usr/bin:/bin" run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"NOTE     command: Add ~/.local/bin to PATH: echo 'path+=~/.local/bin' >> ~/.zshrc"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$SHIM"
  DAEDALUS_NO_COMMAND=1 run shim
  [ -z "$output" ] && [ ! -e "$SHIM" ] || { echo "$output"; return 1; }
  DAEDALUS_NO_COMMAND=1 run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"command:"*) echo "$output"; return 1 ;; esac
}

@test "shim and doctor: on the replay of the second machine, local edits in tracked files are MISSING before daedalus update and OK after; a stale auto-mode line is a NOTE" {
  older_release
  replay_home
  export DAEDALUS_NO_COMMAND=1
  run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"MISSING  local edits in tracked files: CLAUDE.md, .claude/settings.json — run daedalus update, which moves them into the local layer"*) : ;; *) echo "$output"; return 1 ;; esac
  run upd update; [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"MISSING"*) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       tracked files: CLAUDE.md and .claude/settings.json carry no local edits"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '\nan uncommitted line\n' >> "$H/CLAUDE.md"
  run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"MISSING  local edits in tracked files: CLAUDE.md — run daedalus update"*) : ;; *) echo "$output"; return 1 ;; esac
  mkdir -p "$HOME/.claude"
  python3 - "$HOME/.claude/settings.json" "$H" <<'PY'
import json, sys
json.dump({"autoMode": {"allow": ["Editing CLAUDE.md in the Daedalus home at %s when the operator asked." % sys.argv[2]]}}, open(sys.argv[1], "w"))
PY
  run python3 "$H/core/update.py" --doctor --home "$H" </dev/null
  case "$output" in *"NOTE     brief: ~/.claude/settings.json's autoMode.allow names CLAUDE.md in this home; reword it to CLAUDE.local.md (README, \"Letting Daedalus edit its own brief\")"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "migration restore: a backup that fails (at the branch commit, then at the copies) changes nothing — the dirty CLAUDE.md and SOUL.md stay as they were, and no backup is named or left" {
  printf '\nA line this home appended.\n' >> "$H/CLAUDE.md"
  printf '\n## A journal entry\n' >> "$H/SOUL.md"
  claude="$(shasum < "$H/CLAUDE.md")"; soul="$(shasum < "$H/SOUL.md")"; orig="$(git -C "$H" rev-parse HEAD)"
  real="$(command -v git)"; mkdir -p "$B/bin"
  printf '#!/bin/bash\ncase " $* " in *" commit-tree "*) echo "fatal: injected commit-tree failure" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
    "$real" > "$B/bin/git"
  chmod +x "$B/bin/git"
  PATH="$B/bin:$PATH" run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 1 ]
  case "$output" in "Not updated: "*"injected commit-tree failure"*"the backup could not be made, so nothing in this home was changed"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"local/before-update-"*|*"update-backups"*) echo "$output"; return 1 ;; esac
  [ -z "$(git -C "$H" for-each-ref refs/heads/local/)" ]
  [ ! -e "$H/state/update-backups" ] || [ -z "$(ls -A "$H/state/update-backups")" ]
  [ "$(git -C "$H" rev-parse HEAD)" = "$orig" ]
  [ "$(shasum < "$H/CLAUDE.md")" = "$claude" ] && [ "$(shasum < "$H/SOUL.md")" = "$soul" ]
  [ ! -e "$H/CLAUDE.local.md" ]
  # the copies: state/update-backups cannot be a directory
  rm -rf "$H/state/update-backups"; : > "$H/state/update-backups"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: "*"the backup could not be made, so nothing in this home was changed"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"local/before-update-"*) echo "$output"; return 1 ;; esac
  [ -z "$(git -C "$H" for-each-ref refs/heads/local/)" ]
  [ "$(git -C "$H" rev-parse HEAD)" = "$orig" ]
  [ "$(shasum < "$H/CLAUDE.md")" = "$claude" ] && [ "$(shasum < "$H/SOUL.md")" = "$soul" ]
}

@test "migration brief: a release line between two local lines (a table separator) stays in the moved passage; a longer release run inside a local passage is reported as a split" {
  python3 - "$H/CLAUDE.md" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read()
heads = [l for l in text.split("\n") if l.startswith("## ")]
add = ("\n| Local column | Local value |\n|---|---|\n| local row | 1 |\n"
       "\nLocal passage start.\n|---|---|---|\n|---|---|\n" + heads[0] + "\nLocal passage end.\n")
open(p, "w").write(text.rstrip("\n") + "\n" + add)
PY
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  python3 - "$H/CLAUDE.local.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
assert "| Local column | Local value |\n|---|---|\n| local row | 1 |" in t, t
PY
  grep -qx 'Local passage start.' "$H/CLAUDE.local.md"
  grep -qx 'Local passage end.' "$H/CLAUDE.local.md"
  case "$output" in *"CLAUDE.md: 1 local passage held lines a release's brief also has"*"split there"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "migration refused: an ignored file at a path the release adds is refused, naming it, and nothing is changed" {
  printf 'NEXT-RELEASE.md\n' >> "$H/.git/info/exclude"
  printf 'mine\n' > "$H/NEXT-RELEASE.md"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: NEXT-RELEASE.md is untracked here where the release adds files"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

# --- a home that keeps its vault in its own repository: merge mode (close-commits-and-vault-update design, B1) -------

# py_update '<python>' — update.py's functions on $H (u is the module, home the path)
py_update() { python3 -c 'import sys; sys.path.insert(0, sys.argv[2]); import update as u
from pathlib import Path
home = Path(sys.argv[1]); exec(sys.argv[3])' "$H" "$REPO/core" "$1"; }

@test "classify: tracked vault files no release ever had are the deployment's, not local; .gitignore is local; a path the release once had and later deleted, and a local file under core/, are not the deployment's" {
  older_release; tracked_vault_home
  git -C "$H" fetch -q daedalus
  printf 'kept\n' > "$H/LICENSE-OLD"; git -C "$H" add LICENSE-OLD; git -C "$H" commit -q -m "a root file of this home"
  run py_update '
t = u.git(home, "rev-parse", "daedalus/main")[1].strip(); h = u.git(home, "rev-parse", "HEAD")[1].strip()
hist = u.history(home, t); base = u.git(home, "merge-base", h, t)[1].strip()
c = u.classify(home, h, t, base, hist)
print(len([p for p in c["deployment"] if p.startswith("vault/")]), "LICENSE-OLD" in c["deployment"])
print(sorted(p for p in c["local"]))
print([p for p in c["deployment"] if not p.startswith("vault/") and p != "LICENSE-OLD"])
print(len(u.deployment_paths(home)))'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "40 True" ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "['.claude/settings.json', '.gitignore', 'CLAUDE.md']" ] || { echo "$output"; return 1; }
  [ "${lines[2]}" = "[]" ] || { echo "$output"; return 1; }
  [ "${lines[3]}" = 41 ] || { echo "$output"; return 1; }
  run py_update 'print(u.is_deployment_path("core/mine.sh", {"core/mine.sh": "x"}, set(), {}, {}), u.is_deployment_path("vault/a.md", {"vault/a.md": "x"}, set(), {}, {}), u.is_deployment_path("gone.md", {"gone.md": "x"}, set(), {"gone.md": {"y"}}, {}))'
  [ "$output" = "False True False" ] || { echo "$output"; return 1; }
}

@test "merge mode: a home that tracks its vault takes the release by merging — its history kept, every vault file as it was (dirty and untracked too), the local layer migrated, the branch still following its own origin; a second run is up to date, and a later release merges again" {
  older_release; tracked_vault_home
  printf 'dirty edit\n' >> "$H/vault/notes/n3.md"; printf 'untracked\n' > "$H/vault/notes/new.md"
  old="$(git -C "$H" rev-parse HEAD)"; before="$(vault_sums)"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  stamp="$(git -C "$H" for-each-ref --format='%(refname:short)' refs/heads/local/ | sed -n 's#^local/before-update-##p')"
  [ "${lines[0]}" = "Daedalus updated $N -> $N1; doctor OK." ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "Local edits moved to .claude/settings.local.json and CLAUDE.local.md; merged the release into main; this home's history is kept; backup at local/before-update-$stamp and state/update-backups/$stamp/." ] || { echo "$output"; return 1; }
  git -C "$H" merge-base --is-ancestor "$old" HEAD
  git -C "$H" merge-base --is-ancestor "$(trunk_sha "$R")" HEAD
  git -C "$H" diff --quiet "$(trunk_sha "$R")" HEAD -- . ':!vault' ':!.gitignore' ':!SOUL.md' || { git -C "$H" diff --stat "$(trunk_sha "$R")" HEAD; return 1; }
  [ "$(vault_sums)" = "$before" ] || { diff <(printf '%s\n' "$before") <(vault_sums); return 1; }
  grep -qx 'A line this home keeps in its brief.' "$H/CLAUDE.local.md"
  grep -q 'echo this-home' "$H/.claude/settings.local.json"
  [ "$(git -C "$H" config --get branch.main.remote)" = origin ]
  [ "$(git -C "$H" log --first-parent --format=%s -2 | sed -n 2p)" = "daedalus update $stamp: local edits moved to the local layer; release files set to $N1" ] || { git -C "$H" log --first-parent --format=%s -3; return 1; }
  case "$(git -C "$H" log -1 --format=%s)" in "daedalus update $stamp: merge release $N1 ("*") into main") : ;; *) git -C "$H" log -1 --format=%s; return 1 ;; esac
  [ "$(git -C "$H" log --format=%s "$old..HEAD" --first-parent | wc -l | tr -d ' ')" = 2 ]
  # .gitignore: the release's lines first, then this home's own; the vault is not ignored
  [ -z "$(git -C "$H" check-ignore vault/notes/n1.md)" ]
  grep -qx '!vault/' "$H/.gitignore"
  cmp -s <(head -n "$(git -C "$R" show main:.gitignore | wc -l)" "$H/.gitignore") <(git -C "$R" show main:.gitignore)
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Daedalus is up to date ($N1)." ] || { echo "$output"; return 1; }
  # a later release merges again, both merges kept
  git clone -q "$R" "$B/next"
  python3 -c 'import sys; a = open(sys.argv[1]).read().strip().split("."); a[2] = str(int(a[2]) + 1); open(sys.argv[1], "w").write(".".join(a) + "\n")' "$B/next/VERSION"
  N2="$(sed -n 1p "$B/next/VERSION")"; printf 'A file release %s adds.\n' "$N2" > "$B/next/LATER.md"
  git -C "$B/next" add -A; git -C "$B/next" commit -q -m "v$N2"; git -C "$B/next" tag -a "v$N2" -m "v$N2"; git -C "$B/next" push -q origin main --tags
  first="$(git -C "$H" rev-parse HEAD)"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "${lines[0]}" = "Daedalus updated $N1 -> $N2; doctor OK." ] || { echo "$output"; return 1; }
  git -C "$H" merge-base --is-ancestor "$first" HEAD
  [ "$(git -C "$H" log --merges --format=%s | grep -c '^daedalus update .*: merge release')" = 2 ]
  [ "$(vault_sums)" = "$before" ] || { diff <(printf '%s\n' "$before") <(vault_sums); return 1; }
  [ -f "$H/LATER.md" ]
}

@test "merge mode, nothing new from the release: a brief line added after the last merge is moved to the local layer by one local commit, and the first line says up to date" {
  older_release; tracked_vault_home
  run upd update; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '\nA second line of this home.\n' >> "$H/CLAUDE.md"; git -C "$H" commit -q -am "another brief line"
  merges="$(git -C "$H" log --merges --oneline | wc -l)"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "${lines[0]}" = "Daedalus is up to date ($N1); doctor OK." ] || { echo "$output"; return 1; }
  case "${lines[1]}" in "Local edits moved to CLAUDE.local.md; the release was merged already; this home's history is kept; backup at "*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" log --merges --oneline | wc -l)" = "$merges" ]
  grep -qx 'A second line of this home.' "$H/CLAUDE.local.md"
  cmp -s "$H/CLAUDE.md" <(git -C "$R" show main:CLAUDE.md)
}

@test "merge mode, SOUL.md: the release changes the journal and this home has committed and dirty entries — the journal stays this home's, still dirty, and the release's copy is in the backup" {
  older_release
  w="$B/rel-release"; printf '\nA line the release added to the journal.\n' >> "$w/SOUL.md"
  git -C "$w" commit -q -am "release journal"; git -C "$w" push -q "$R" main
  tracked_vault_home
  printf '\n## A committed entry\n' >> "$H/SOUL.md"; git -C "$H" commit -q -am "journal"
  printf '\n## A dirty entry\n' >> "$H/SOUL.md"
  soul="$(shasum < "$H/SOUL.md")"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$(shasum < "$H/SOUL.md")" = "$soul" ]
  git -C "$H" status --porcelain -- SOUL.md | grep -q '^ M SOUL.md$'
  ls "$H"/state/update-backups/*/SOUL.release.md >/dev/null
  case "$output" in *"the release's copy is in state/update-backups/"*"/SOUL.release.md."*) : ;; *) echo "$output"; return 1 ;; esac
  ! git -C "$H" show HEAD:SOUL.md | grep -q 'A line the release added to the journal'
}

@test "merge mode, .gitignore: a home whose edit deleted the release's vault line comes out with the release's line and an un-ignore; a release that changes .gitignore merges with no conflict" {
  older_release
  w="$B/rel-release"; printf '\n# a rule the release added\n*.release-tmp\n' >> "$w/.gitignore"
  git -C "$w" commit -q -am "release ignore rule"; git -C "$w" push -q "$R" main
  git -C "$H" reset -q --hard older; git -C "$H" remote rename origin daedalus
  sed -i '' '/^vault\/$/d' "$H/.gitignore"; git -C "$H" add .gitignore; git -C "$H" commit -q -m "no vault ignore"
  mkdir -p "$H/vault"; printf 'v\n' > "$H/vault/a.md"; git -C "$H" add vault; git -C "$H" commit -q -m vault
  before="$(vault_sums)"
  run upd update
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  grep -qx 'vault/' "$H/.gitignore"; grep -qx '!/vault/' "$H/.gitignore"; grep -qx '\*.release-tmp' "$H/.gitignore"
  [ -z "$(git -C "$H" check-ignore vault/a.md)" ]
  [ "$(vault_sums)" = "$before" ]
  [ -z "$(git -C "$H" status --porcelain -- .gitignore)" ]
}

@test "merge mode, conflicts and failures: a file the release now ships that differs here is refused before any backup; a failed merge commit restores the home exactly, and a vault file written while the update ran keeps its new bytes" {
  older_release
  w="$B/rel-release"; mkdir -p "$w/vault"; printf 'the release README\n' > "$w/vault/README.md"
  git -C "$w" add -f vault/README.md; git -C "$w" commit -q -m "a release file under vault"; git -C "$w" push -q "$R" main
  tracked_vault_home
  printf 'this home README\n' > "$H/vault/README.md"; git -C "$H" add vault/README.md; git -C "$H" commit -q -m readme
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [ "$output" = "Not updated: vault/README.md, a file the release now ships, differs in this home; move it out of the release's way, then run daedalus update again; it fetched daedalus/main, and nothing else in this home was changed." ] || { echo "$output"; return 1; }
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
  [ -z "$(ls "$H/state/update-backups" 2>/dev/null)" ]
  # the release takes its vault file back out; the merge commit fails while a vault file changes
  git -C "$w" rm -q vault/README.md; git -C "$w" commit -q -m "no vault file"; git -C "$w" push -q "$R" main
  git -C "$H" reset -q --hard HEAD~1
  printf 'kept dirty\n' >> "$H/vault/sessions/s2.md"
  orig="$(git -C "$H" rev-parse HEAD)"; st="$(git -C "$H" status --porcelain --ignored -- . ':!state' ':!vault/sessions/s5.md')"; dh="$(git -C "$H" diff HEAD)"
  real="$(command -v git)"; mkdir -p "$B/bin"
  printf '#!/bin/bash\ncase " $* " in *" commit "*"merge release"*) printf "written during the update\\n" > "%s/vault/sessions/s5.md"; echo "fatal: injected failure" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' \
    "$H" "$real" > "$B/bin/git"; chmod +x "$B/bin/git"
  PATH="$B/bin:$PATH" run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  [ "${#lines[@]}" = 1 ] || { echo "$output"; return 1; }
  case "$output" in "Not updated: the merge commit failed (fatal: injected failure); this home is back as it was"*"local/before-update-"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H" rev-parse HEAD)" = "$orig" ]
  [ ! -e "$H/.git/MERGE_HEAD" ]
  [ "$(cat "$H/vault/sessions/s5.md")" = "written during the update" ]
  [ "$(git -C "$H" status --porcelain --ignored -- . ':!state' ':!vault/sessions/s5.md')" = "$st" ] || { git -C "$H" status --porcelain --ignored; return 1; }
  [ "$(git -C "$H" diff HEAD -- . ':!vault/sessions/s5.md')" = "$dh" ]
  [ ! -e "$H/CLAUDE.local.md" ]; [ ! -e "$H/.claude/settings.local.json" ]
}

@test "merge mode, still refused: an edit to core/close.sh in a home that tracks its vault is refused naming it, and nothing is changed" {
  older_release; tracked_vault_home
  printf '# local\n' >> "$H/core/close.sh"
  before="$(listing)"
  run upd update
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in "Not updated: core/close.sh carries local changes the update cannot carry"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(listing); return 1; }
}

@test "merge mode: daedalus version names the merged release's tag past a home's own tag; doctor's update lines name nothing missing; distcheck passes on the merged home" {
  older_release; tracked_vault_home
  git -C "$H" tag home-own-tag
  run upd update; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$H" tag later-own-tag
  run upd version
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in "Daedalus $N1 ("*"remote daedalus, tag v$N1)") : ;; *) echo "$output"; return 1 ;; esac
  DAEDALUS_NO_COMMAND=1 run python3 "$H/core/update.py" --doctor --home "$H"
  [ "$status" -eq 0 ]; case "$output" in *MISSING*) echo "$output"; return 1 ;; esac
  case "$output" in *"OK       tracked files: CLAUDE.md and .claude/settings.json carry no local edits"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$H/core/distcheck.py" "$H" --for launch
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git -C "$H" ls-files --error-unmatch vault >/dev/null 2>&1
}

@test "update.py carries distcheck's DIST_PATHS word for word" {
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import update, distcheck; assert update.DIST_PATHS == distcheck.DIST_PATHS, (update.DIST_PATHS, distcheck.DIST_PATHS)' "$REPO/core"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
