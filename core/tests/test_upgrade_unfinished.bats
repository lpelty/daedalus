#!/usr/bin/env bats
# core/upgrade.py and unfinished work (spec §14 step 6; the operator's decision of 2026-10-07, Appendix E): the
# upgrade moves nothing by itself. Unfinished work in any target repo stops it before it changes anything under
# target/ (after its safety copy), in one plain sentence naming what it found; "pick it up" is
# core/lease.sh adopt --all-unfinished, and the next session start finishes the upgrade. With none, the upgrade
# goes through by itself, putting a checkout on an already-merged branch back on its trunk.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() { upgrade_fixture; }
teardown() { teardown_live; }

TAIL="Nothing was changed. Say 'pick it up' to move it into windows, or finish and ship it the usual way, then start a new session."

# --- one test per kind: the stop, and nothing under target/ changed -----------------------------------------------

@test "unfinished work: the checked-out branch with commits not on origin — named with its count, GitHub when origin's address is GitHub's" {
  git -C "$T" config remote.origin.url https://github.com/acme/thing.git
  git -C "$T" config "url.$BATS_TEST_TMPDIR/origin.git.insteadOf" https://github.com/acme/thing.git
  git -C "$T" checkout -q -b fix-login; printf 'l\n' > "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m one
  printf 'l2\n' >> "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m two
  up_stops "Daedalus has unfinished work in target/thing: the branch fix-login (2 commits not on GitHub). $TAIL"
  [ "$(git -C "$T" branch --show-current)" = fix-login ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
}

@test "unfinished work: a branch not checked out, with a commit not on origin" {
  git -C "$T" checkout -q -b feat/parked; printf 'p\n' > "$T/p.txt"; git -C "$T" add -A; cmt "$T" -m parked
  git -C "$T" checkout -q main
  up_stops "Daedalus has unfinished work in target/thing: the branch feat/parked (1 commit not on origin). $TAIL"
}

@test "unfinished work: the trunk ahead of origin" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m ahead
  up_stops "Daedalus has unfinished work in target/thing: the branch main (1 commit not on origin). $TAIL"
}

@test "unfinished work: a branch whose branch on origin was deleted after it merged, with a follow-up commit made since — the follow-up counts; one deleted on origin unmerged counts too (review of option 1, finding 2)" {
  git -C "$T" checkout -q -b fix-login; printf 'l\n' > "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m one
  git -C "$T" push -q -u origin fix-login
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  git -C "$BATS_TEST_TMPDIR/hand" -c user.email=t@x -c user.name=t merge -q --no-ff origin/fix-login -m "Merge fix-login"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main; git -C "$BATS_TEST_TMPDIR/hand" push -q origin --delete fix-login
  git -C "$T" fetch -q --prune origin
  printf 'MORE\n' > "$T/more.txt"; git -C "$T" add -A; cmt "$T" -m "the follow-up fix nobody pushed"
  up_stops "Daedalus has unfinished work in target/thing: the branch fix-login (1 commit not on origin). $TAIL"
  run python3 "$UP" --doctor
  case "$output" in *"target/thing is on fix-login, 1 commit past origin/main — the upgrade stops on it until it is picked up"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" checkout -q -b wip main; printf 'w\n' > "$T/w.txt"; git -C "$T" add -A; cmt "$T" -m wip1
  git -C "$T" push -q -u origin wip; git -C "$T" push -q origin --delete wip; git -C "$T" fetch -q --prune origin
  git -C "$T" branch -D -q fix-login
  up_stops "Daedalus has unfinished work in target/thing: the branch wip (1 commit not on origin). $TAIL"
}

@test "unfinished work: a detached HEAD holding commits no branch has — even when its change is already on origin as a squash" {
  git -C "$T/sub" checkout -q --detach; printf 'd\n' > "$T/sub/d.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m d1
  printf 'd2\n' >> "$T/sub/d.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m d2
  up_stops "Daedalus has unfinished work in target/thing/sub: a detached checkout with 2 commits no branch has. $TAIL"
  git clone -q "$BATS_TEST_TMPDIR/sub-origin.git" "$BATS_TEST_TMPDIR/hand"
  cp "$T/sub/d.txt" "$BATS_TEST_TMPDIR/hand/d.txt"; git -C "$BATS_TEST_TMPDIR/hand" add -A; cmt "$BATS_TEST_TMPDIR/hand" -m squashed
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  git -C "$T/sub" fetch -q origin           # the upgrade's own fetch moves only origin's refs; the listing is taken after it
  up_stops "Daedalus has unfinished work in target/thing/sub: a detached checkout with 2 commits no branch has. $TAIL"
}

@test "unfinished work: uncommitted changes to tracked files and untracked files that are not ignored — counted together as unsaved files; ignored files are not work" {
  printf 'edit\n' >> "$T/a.txt"; printf 'new\n' > "$T/new.txt"; mkdir -p "$T/notes"; printf 'n\n' > "$T/notes/n.md"
  printf '*.log\n' >> "$T/.git/info/exclude"; printf 'ignored\n' > "$T/build.log"
  up_stops "Daedalus has unfinished work in target/thing: 3 unsaved files. $TAIL"
  rm "$T/new.txt" "$T/notes/n.md"; git -C "$T" checkout -q -- a.txt
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing holds ignored files no window has (build.log)"*"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/build.log")" = ignored ]
}

@test "ignored files: a configured nested repo is never named among them, nor anything under it, even where the outer repo ignores the directory holding it (agents/); what else that directory holds is named — in the upgrade's line and in doctor" {
  mkdir -p "$T/agents"; mv "$T/sub" "$T/agents/one"
  printf 'agents/\n' > "$T/.gitignore"; git -C "$T" add -A; cmt "$T" -m "ignore agents/"; git -C "$T" push -q origin main
  sed -i '' 's|nested: sub=|nested: agents/one=|' "$DAEDALUS_HOME/config.yaml"
  printf 'scratch\n' > "$T/agents/one/scratch.local"; printf 'scratch.local\n' >> "$T/agents/one/.git/info/exclude"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing holds ignored files"*) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/agents/one holds ignored files no window has (scratch.local)"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'notes\n' > "$T/agents/notes.md"; mkdir -p "$T/agents/two/x"; printf 'y\n' > "$T/agents/two/x/y.txt"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ln="$(printf '%s\n' "$output" | grep 'target/thing holds ignored files')"
  case "$ln" in *"target/thing holds ignored files no window has (agents/notes.md, agents/two/) — they stay there"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"(agents/)"*|*"(agents/,"*|*"agents/one/"*) echo "$output"; return 1 ;; esac
  printf 'loose\n' > "$T/agents/one/loose.txt"
  run python3 "$UP" --doctor
  case "$output" in *"agents/one/"*|*"(agents/)"*) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/agents/one has untracked files no window holds (loose.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "unfinished work: an edit git status does not show — skip-worktree — is named with the file; a marked file with no edit is not work" {
  printf 'MY EDIT\n' > "$T/a.txt"; git -C "$T" update-index --skip-worktree a.txt
  git -C "$T/sub" update-index --assume-unchanged n.txt
  [ -z "$(git -C "$T" status --porcelain)" ]
  up_stops "Daedalus has unfinished work in target/thing: 1 changed file git status does not show (a.txt). $TAIL"
  [ "$(cat "$T/a.txt")" = "MY EDIT" ]
}

@test "unfinished work: stash entries" {
  printf 's1\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  printf 's2\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  up_stops "Daedalus has unfinished work in target/thing: 2 stash entries. $TAIL"
}

@test "unfinished work: a rebase, merge, cherry-pick, revert or bisect in progress — each named, even when the checkout reads clean" {
  git -C "$T" checkout -q -b feat/x; printf '1\n' > "$T/one.txt"; git -C "$T" add -A; cmt "$T" -m one
  git -C "$T" push -q origin feat/x:main            # the branch's work is on origin: only the operation is left
  git -C "$T" fetch -q origin
  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    git -C "$T" rev-parse HEAD > "$T/.git/$f"
    case $f in MERGE_HEAD) w=merge ;; CHERRY_PICK_HEAD) w=cherry-pick ;; REVERT_HEAD) w=revert ;; esac
    up_stops "Daedalus has unfinished work in target/thing: a $w in progress. $TAIL"
    rm "$T/.git/$f"
  done
  mkdir "$T/.git/rebase-merge"
  up_stops "Daedalus has unfinished work in target/thing: a rebase in progress. $TAIL"
  rmdir "$T/.git/rebase-merge"
  git -C "$T/sub" bisect start >/dev/null 2>&1
  up_stops "Daedalus has unfinished work in target/thing/sub: a bisect in progress. $TAIL"
}

@test "unfinished work: a linked worktree that is not a window's — clean or not, under worktrees/ too" {
  UW="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/userwt"
  git -C "$T" worktree add -q --detach "$UW" main
  up_stops "Daedalus has unfinished work in target/thing: a worktree made by hand at $UW. $TAIL"
  git -C "$T" worktree remove "$UW"
  mkdir -p "$DAEDALUS_HOME/worktrees"
  git -C "$T" worktree add -q -b hotfix "$DAEDALUS_HOME/worktrees/hotfix" main
  up_stops "Daedalus has unfinished work in target/thing: a worktree made by hand at $DAEDALUS_HOME/worktrees/hotfix. $TAIL"
}

@test "unfinished work: a repository of its own inside the checkout that is not ignored" {
  git init -q "$T/extra"; printf 'e\n' > "$T/extra/e.txt"; git -C "$T/extra" add -A; cmt "$T/extra" -m own
  up_stops "Daedalus has unfinished work in target/thing: a repository of its own at extra/. $TAIL"
}

@test "the sentence names at most five things across every repo, then 'and N more'; a dry run says it as 'would stop' and records nothing" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m ahead
  for b in b1 b2 b3; do git -C "$T" branch "$b" main; done
  git -C "$T" checkout -q b1; printf '1\n' > "$T/1.txt"; git -C "$T" add -A; cmt "$T" -m 1
  printf 'new\n' > "$T/new.txt"
  git -C "$T/sub" checkout -q -b s1; printf 's\n' > "$T/sub/s.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m s
  printf 'x\n' > "$T/sub/x.txt"
  s="Daedalus has unfinished work in target/thing: the branch b1 (2 commits not on origin), the branch b2 (1 commit not on origin), the branch b3 (1 commit not on origin), the branch main (1 commit not on origin), and 1 unsaved file, and 2 more. $TAIL"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ]
  case "$output" in *"would stop: $s"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
  up_stops "$s"
  git -C "$T" checkout -q main; git -C "$T" branch -D b1 b2 b3 >/dev/null; git -C "$T" reset -q --hard origin/main; rm "$T/new.txt"
  up_stops "Daedalus has unfinished work in target/thing/sub: the branch s1 (1 commit not on origin), and 1 unsaved file. $TAIL"
}

@test "the board shows the stop on every prompt and doctor names it, until the upgrade completes" {
  git -C "$T" checkout -q -b fix-login; printf 'l\n' > "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m one
  s="Daedalus has unfinished work in target/thing: the branch fix-login (1 commit not on origin). $TAIL"
  up_stops "$s"
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import upgrade as u; print(u.pending_line(u.v.ROOT))' "$DAEDALUS_HOME/core"
  [ "$output" = "$s" ] || { echo "$output"; return 1; }
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     $s"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing is on fix-login, 1 commit past origin/main — the upgrade stops on it until it is picked up (core/lease.sh adopt --all-unfinished, or core/lease.sh adopt fix-login)"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- nothing unfinished: the upgrade goes through by itself ---------------------------------------------------------

@test "no unfinished work, the checkout on a branch already merged on origin (this home's real shape): the upgrade goes through by itself — back on main at origin/main, the branch left as it was, no window, the stamp" {
  v061_state
  git -C "$T" checkout -q -b fix/shipped; printf 's\n' > "$T/s.txt"; git -C "$T" add -A; cmt "$T" -m "the shipped fix"
  git -C "$T" push -q -u origin fix/shipped
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  git -C "$BATS_TEST_TMPDIR/hand" -c user.email=t@x -c user.name=t merge -q --no-ff origin/fix/shipped -m "Merge fix/shipped"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: target/thing was on fix/shipped, whose work is already on origin/main; it is back on main and fix/shipped is left as it was."*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"unfinished"*|*"window 01"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ "$(git -C "$T" rev-parse HEAD)" = "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse main)" ]
  git -C "$T" rev-parse -q --verify refs/heads/fix/shipped >/dev/null
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  # squash-merged and its branch on origin deleted, as GitHub leaves it: the same
  rm "$DAEDALUS_HOME/state/upgraded-to"
  git -C "$T" checkout -q -b fix/squashed; printf 'q\n' > "$T/q.txt"; git -C "$T" add -A; cmt "$T" -m "squash me"
  git -C "$T" push -q -u origin fix/squashed
  git -C "$BATS_TEST_TMPDIR/hand" pull -q origin main
  git -C "$BATS_TEST_TMPDIR/hand" fetch -q origin; git -C "$BATS_TEST_TMPDIR/hand" merge -q --squash origin/fix/squashed
  cmt "$BATS_TEST_TMPDIR/hand" -m "fix/squashed (squashed)"; git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin --delete fix/squashed
  git -C "$T" fetch -q --prune origin
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was on fix/squashed, whose work is already on origin/main; it is back on main and fix/squashed is left as it was."*"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
}

# --- "pick it up", then the next session start finishes the upgrade -------------------------------------------------

@test "pick it up: every kind of work the stop named becomes a window — the checked-out branch with its unsaved files, a parked branch, a branch it carries left as it was, the trunk ahead, a stash entry, a detached nested repo; then the next session start completes the upgrade" {
  printf 's\n' > "$T/stashed.txt"; git -C "$T" add stashed.txt; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "trunk work"
  git -C "$T" checkout -q -b feat/base refs/remotes/origin/main; printf 'b\n' > "$T/b.txt"; git -C "$T" add -A; cmt "$T" -m "base work"
  git -C "$T" checkout -q -b feat/top; printf 't\n' > "$T/t.txt"; git -C "$T" add -A; cmt "$T" -m "top work"
  git -C "$T" checkout -q -b fix-login refs/remotes/origin/main; printf 'l\n' > "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m "login fix"
  printf 'edit\n' >> "$T/a.txt"; printf 'NOTES\n' > "$T/notes.md"; printf '*.local\n' >> "$T/.git/info/exclude"; printf 'MINE\n' > "$T/my.local"
  git -C "$T/sub" checkout -q --detach; printf 'd\n' > "$T/sub/d.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "detached work"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$output" in *"Daedalus has unfinished work in target/thing: the branch fix-login (1 commit not on origin), the branch feat/top (2 commits not on origin), the branch feat/base (1 commit not on origin), the branch main (1 commit not on origin), and 2 unsaved files, and 2 more. $TAIL"*) : ;; *) echo "$output"; return 1 ;; esac
  pick_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds fix-login from target/thing (2 commits: \"login fix\", \"Unsaved work in target/thing, picked up before the upgrade\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Window 02 now holds feat/top from target/thing (2 commits: \"base work\", \"top work\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Window 03 now holds daedalus/stash-"*" from target/thing (1 commit: \"WIP on main: "*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Window 04 now holds daedalus/upgrade-"*"from target/thing (1 commit: \"trunk work\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Window 05 now holds daedalus/detached-"*"from target/thing/sub (1 commit: \"detached work\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Everything unfinished in target/ is in windows now. Start a new session and the upgrade finishes."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Window 06"*|*feat/base*) echo "$output"; return 1 ;; esac
  W="$DAEDALUS_HOME/worktrees"
  [ "$(cat "$W/01/thing/notes.md")" = NOTES ]; [ "$(tail -1 "$W/01/thing/a.txt")" = edit ]; [ -z "$(git -C "$W/01/thing" status --porcelain)" ]
  [ "$(cat "$W/03/thing/stashed.txt")" = s ]; [ "$(cat "$W/05/thing/sub/d.txt")" = d ]
  [ -z "$(git -C "$T" stash list)" ]; git -C "$T" rev-parse -q --verify refs/heads/feat/base >/dev/null
  [ "$(cat "$T/my.local")" = MINE ]
  [ "$(git -C "$T" branch --show-current)" = main ]; [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T/sub" branch --show-current)" = main ]
  [ "$(lease_json 01 note)" = "picked up at the upgrade to 0.7.0" ]
  # the next session start: nothing unfinished, the upgrade completes
  printf '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup","transcript_path":"%s/s1.jsonl"}' "$BATS_TEST_TMPDIR" | python3 "$DAEDALUS_HOME/core/session-start.py" > "$BATS_TEST_TMPDIR/s1.out" 2>&1 || { cat "$BATS_TEST_TMPDIR/s1.out"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ] || { cat "$BATS_TEST_TMPDIR/s1.out"; return 1; }
  grep -q "Upgrade to 0.7.0: complete." "$BATS_TEST_TMPDIR/s1.out" || { cat "$BATS_TEST_TMPDIR/s1.out"; return 1; }
  ! grep -q "unfinished work" "$BATS_TEST_TMPDIR/s1.out"
  run python3 "$UP" --restore-help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"is still in target/ or in a window"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"no longer has"*) echo "$output"; return 1 ;; esac
}

@test "pick it up, cut off part-way, run again: the same windows, never a second one for the same work; then the upgrade completes" {
  printf 's\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "trunk work"
  git -C "$T" checkout -q -b fix-login refs/remotes/origin/main; printf 'l\n' > "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m "login fix"
  printf 'NOTES\n' > "$T/notes.md"
  run python3 "$UP"; [ "$status" -eq 1 ]
  for kill in write_lease:2 add_worktrees:1 git_finish:1; do
    run python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import upgrade as u, leaselib as ll
n = {"k": 0}
name, at = sys.argv[2].split(":")
o = getattr(ll, name)
def k(*a, **kw):
    n["k"] += 1
    if n["k"] == int(at):
        os._exit(9)
    return o(*a, **kw)
setattr(ll, name, k)
sys.exit(u.pick_up(u.v.ROOT))' "$DAEDALUS_HOME/core" "$kill"
    [ "$status" -eq 9 ] || { echo "$kill: $status $output"; return 1; }
  done
  pick_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  # three pieces of work, three windows: the branch with its notes, the stash entry, the trunk's commit
  [ "$(ls "$DAEDALUS_HOME/state/leases" | grep -c '^[0-9][0-9]\.json$')" = 3 ] || { ls "$DAEDALUS_HOME/state/leases"; return 1; }
  [ "$(git -C "$T" for-each-ref refs/heads/lease/ | wc -l | tr -d ' ')" = 3 ]
  [ -z "$(git -C "$T" for-each-ref refs/heads/daedalus/)" ]; [ -z "$(git -C "$T" stash list)" ]
  [ "$(cat "$DAEDALUS_HOME"/worktrees/*/thing/notes.md)" = NOTES ]
}

@test "pick it up names what it cannot move, with what to do — a rebase in progress, an edit git status does not show, a worktree made by hand, a repository of its own — and moves the rest" {
  git -C "$T/sub" checkout -q -b s1; printf 's\n' > "$T/sub/s.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m s
  mkdir "$T/sub/.git/rebase-merge"
  git -C "$T" checkout -q -b fix-login; printf 'l\n' > "$T/l.txt"; git -C "$T" add -A; cmt "$T" -m "login fix"
  UW="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/userwt"; git -C "$T" worktree add -q --detach "$UW" main
  git init -q "$T/extra"
  run python3 "$UP"; [ "$status" -eq 1 ]
  pick_up
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds fix-login from target/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/sub is in the middle of a rebase — finish it with git -C target/thing/sub rebase --continue, or undo it with git -C target/thing/sub rebase --abort; nothing there was moved."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing has a worktree made by hand at $UW — commit its work on a branch there, then remove it (git -C target/thing worktree remove $UW"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing holds extra/, a repository of its own that no window can take — move it out of target/thing."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"That stays where it is until it is done; then say 'pick it up' again"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T/sub" branch --show-current)" = s1 ]
  rmdir "$T/sub/.git/rebase-merge"; git -C "$T" worktree remove "$UW"; mv "$T/extra" "$BATS_TEST_TMPDIR/extra"
  printf 'MY EDIT\n' > "$T/a.txt"; git -C "$T" update-index --skip-worktree a.txt
  pick_up
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 02 now holds s1 from target/thing/sub"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing has changes git status does not show (1 changed file) — in files marked skip-worktree (a.txt): clear the mark (git -C target/thing update-index --no-skip-worktree a.txt), then say 'pick it up' again; nothing there was moved."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" update-index --no-skip-worktree a.txt
  pick_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 03 now holds daedalus/unsaved-"*"(1 commit: \"Unsaved work in target/thing, picked up before the upgrade\")"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/worktrees/03/thing/a.txt")" = "MY EDIT" ]
}

@test "the trunk ahead of origin, a window holding its commits, and an ordinary edit there: plain unsaved work, never a cut-off reset — 'pick it up' saves the edit into a window and resets the trunk; the upgrade completes (review of option 1, finding 1)" {
  run python3 "$UP"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "trunk work"
  git -C "$T" branch feat main; git -C "$T" checkout -q feat; printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m feat
  git -C "$T" checkout -q main
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" rev-parse main)" != "$(git -C "$T" rev-parse refs/remotes/origin/main)" ]
  printf 'MY EDIT\n' >> "$T/a.txt"
  rm "$DAEDALUS_HOME/state/upgraded-to"
  up_stops "Daedalus has unfinished work in target/thing: 1 unsaved file. $TAIL"
  pick_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"cut off"*) echo "$output"; return 1 ;; esac
  case "$output" in *"Window 02 now holds daedalus/unsaved-"*"Unsaved work in target/thing, picked up before the upgrade"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing's main was also 1 commit ahead of origin/main; window 01 holds those commits, so main is reset to origin/main."*"Everything unfinished in target/ is in windows now."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(tail -1 "$DAEDALUS_HOME/worktrees/02/thing/a.txt")" = "MY EDIT" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse refs/remotes/origin/main)" ]; [ -z "$(git -C "$T" status --porcelain)" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"cut off"*) echo "$output"; return 1 ;; esac
}

@test "pick it up with nothing unfinished says so and changes nothing" {
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  before="$(target_listing)"
  pick_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "Nothing unfinished in target/ to pick up." ] || { echo "$output"; return 1; }
  [ "$(target_listing)" = "$before" ]
}
