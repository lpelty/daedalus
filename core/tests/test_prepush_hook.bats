#!/usr/bin/env bats
# Pins core/prepush.py (spec §7.3 "The real gate is in git"): the pre-push hook in each target
# repo's common git dir refuses a trunk push that no promotion confirmed.
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() {
  lease_fixture; H="$DAEDALUS_HOME/core/prepush.py"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  unset DAEDALUS_PROMOTE_ID
}
teardown() { teardown_live; }
LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }
hookfile() { printf '%s/hooks/pre-push\n' "$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"; }
stamp() { python3 -c 'import os,sys; print(" ".join("%d:%d" % (os.stat(p).st_ino, os.stat(p).st_mtime_ns) for p in sys.argv[1:]))' "$@"; }

@test "allocating a window installs the hook in the outer and the nested repo's common git dir, executable, calling this home's prepush.py; installing again changes no file; core.hooksPath is never set" {
  LS create >/dev/null
  for r in "$T" "$T/sub"; do
    f="$(hookfile "$r")"; [ -x "$f" ]
    grep -qF '# daedalus pre-push hook (core/prepush.py)' "$f"
    grep -qF "'$DAEDALUS_HOME/core/prepush.py' hook" "$f"
  done
  before="$(stamp "$(hookfile "$T")" "$(hookfile "$T/sub")")"
  run python3 "$H" install "$T" "$T/sub"; [ "$status" -eq 0 ]
  [ "${lines[0]}" = "pre-push hook: unchanged in target/thing" ]; [ "${lines[1]}" = "pre-push hook: unchanged in target/thing/sub" ]
  [ "$(stamp "$(hookfile "$T")" "$(hookfile "$T/sub")")" = "$before" ]
  [ -z "$(git -C "$T" config --get core.hooksPath)" ]; [ -z "$(git -C "$T/sub" config --get core.hooksPath)" ]
}

@test "the hook refuses a trunk push with no promotion id, with an id whose prepared.json has no confirmed_at, with a sha that is not the prepared merge, onto a remote trunk that is not the tested base, after a failed push, and once pushed; accepts the confirmed one; never refuses a branch push; a path in the id is refused" {
  LS create >/dev/null; W="$DAEDALUS_HOME/worktrees/01/thing"
  printf 'x\n' > "$W/x.txt"; git -C "$W" add -A; git -C "$W" commit -q -m x; sha="$(git -C "$W" rev-parse HEAD)"
  base="$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse main)"
  moves() { case "$output" in *"This push would move main. Trunk is reached only through promote (\`core/promote.sh <NN>\`)."*) : ;; *) echo "$output"; return 1 ;; esac; }
  run git -C "$W" push origin HEAD:main; [ "$status" -ne 0 ]; moves
  id=01-20260928-120000-abc; d="$DAEDALUS_HOME/state/promote/$id"; mkdir -p "$d"
  pjw() { printf '{"merge_sha":"%s","trunk_sha_at_prepare":"%s"%s}' "$1" "$2" "$3" > "$d/prepared.json"; }
  push_id() { run env DAEDALUS_PROMOTE_ID=$id git -C "$W" push origin HEAD:main; }
  C=',"confirmed_at":"2026-09-28T12:00:00.000Z"'
  pjw "$sha" "$base" "";                                        push_id; [ "$status" -ne 0 ]; moves
  pjw 0000000000000000000000000000000000000001 "$base" "$C";    push_id; [ "$status" -ne 0 ]; moves
  pjw "$sha" 0000000000000000000000000000000000000002 "$C";     push_id; [ "$status" -ne 0 ]; moves   # Decision 34
  pjw "$sha" "$base" "$C,\"push_failed_at\":\"2026-09-28T12:01:00.000Z\""; push_id; [ "$status" -ne 0 ]; moves
  pjw "$sha" "$base" "$C"; : > "$d/pushed";                     push_id; [ "$status" -ne 0 ]; moves
  rm -f "$d/pushed"
  push_id; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse main)" = "$sha" ]
  run git -C "$W" push origin HEAD:refs/heads/fix/x; [ "$status" -eq 0 ]
  run git -C "$W" push origin HEAD:master; [ "$status" -ne 0 ]
  # a new commit, so the push below carries a trunk update for the hook to judge (an
  # up-to-date push never runs the hook — measured by the review)
  printf 'y\n' > "$W/y.txt"; git -C "$W" add -A; git -C "$W" commit -q -m y
  run env DAEDALUS_PROMOTE_ID=../../x git -C "$W" push origin HEAD:main; [ "$status" -ne 0 ]; moves
}

@test "sync-target.sh — setup's first phase — installs the hook on an existing checkout, outer and nested; a pre-push hook Daedalus did not install is left alone and named; status reports core.hooksPath" {
  cp "$SRC/sync-target.sh" "$DAEDALUS_HOME/core/"
  run bash "$DAEDALUS_HOME/core/sync-target.sh"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"pre-push hook: installed in target/thing"*"pre-push hook: installed in target/thing/sub"*) : ;; *) echo "$output"; return 1 ;; esac
  grep -q 'core/sync-target.sh' "$SRC/setup.sh"
  f="$(hookfile "$T")"; printf '#!/bin/sh\nexit 0\n' > "$f"; chmod +x "$f"
  run python3 "$H" install "$T"; [ "$status" -ne 0 ]
  case "$output" in *"target/thing already has a pre-push hook that Daedalus did not install"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$f")" = "$(printf '#!/bin/sh\nexit 0')" ]
  git -C "$T/sub" config core.hooksPath /tmp/elsewhere
  run python3 "$H" status "$T/sub"; case "$output" in *"hookspath"*) : ;; *) echo "$output"; return 1 ;; esac
}
