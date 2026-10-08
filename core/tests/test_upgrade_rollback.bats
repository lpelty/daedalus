#!/usr/bin/env bats
# python3 core/upgrade.py --rollback: an upgraded home taken back to where the v0.6.1 code runs exactly as before.
# A v0.6.1 deployment built and started by its own code, pulled to the tree under test and upgraded by its own
# session starts (two windows), then rolled back; then the operator's own step, git checkout v0.6.1, and v0.6.1's
# session start, doctor and a push from target/<repo> all work as they did on v0.6.1.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() { V061_TARGET_DIR=; v061_fixture; }
teardown() { teardown_live; }

start_session() {   # start_session <session-id> — an interactive terminal window's SessionStart, as Claude Code runs it
  local p; p="$(live_pid)"; registry_entry "$p" "$1" interactive cli daedalus-xx
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' \
    "$1" "$B" "$1" | python3 "$H/core/session-start.py"
}
end_sessions() {    # every session this test started ends: its process is gone
  local p
  [ -f "$BATS_TEST_TMPDIR/live-pids" ] || return 0
  while read -r p; do kill "$p" 2>/dev/null; while kill -0 "$p" 2>/dev/null; do sleep 0.05; done; done < "$BATS_TEST_TMPDIR/live-pids"
}
# home_listing — every file the rollback may touch, by content, the worktrees git records, every branch and the
# hooks: two equal listings mean a run changed nothing
home_listing() {
  (cd "$H" && find target worktrees state vault/hot.md config.yaml \( -type f -o -type l \) ! -name FETCH_HEAD \
     ! -name .upgrade.lock ! -name .lock -print | LC_ALL=C sort | while IFS= read -r f; do
     if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s  %s\n' "$(shasum < "$f" | cut -c1-40)" "$f"; fi
   done)
  (cd "$H" && find worktrees -type d | LC_ALL=C sort)
  local r; for r in "$T" "$T/sub"; do git -C "$r" worktree list --porcelain; git -C "$r" for-each-ref --format='%(refname) %(objectname)'; done
}
# upgraded — the home upgraded by its own session starts, as on the laptop: the in-flight branch picked up as window
# 01, the completing session window 02; window 02 then holds an edit, untracked files (outer and nested) and an
# ignored file. target/thing/sub carries a pre-push hook of the operator's own.
upgraded() {
  git -C "$H" tag v0.6.1     # every clone of the product carries the release tags
  printf '#!/bin/sh\necho "the operator'"'"'s own pre-push check" >&2\nexit 0\n' > "$T/sub/.git/hooks/pre-push"
  chmod +x "$T/sub/.git/hooks/pre-push"
  shasum "$T/sub/.git/hooks/pre-push" > "$B/own-hook.sha"
  pull_current
  start_session s1 >/dev/null
  run bash "$H/core/lease.sh" adopt --all-unfinished </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  case "$output" in *"Upgrade to 0.7.0: complete."*"You are window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$H/state/upgraded-to")" = 0.7.0 ]
  [ -x "$T/.git/hooks/pre-push" ]
  [ "$(sed -n 3p "$H/vault/hot.md")" = "leases: (see the board; prime's copy at its last write)" ]
  W="$H/worktrees/02/thing"
  printf 'edited in window 02\n' >> "$W/thing.txt"; printf 'new\n' > "$W/new.txt"; mkdir -p "$W/notes"; printf 'n\n' > "$W/notes/n.md"
  printf 'nested work\n' > "$W/sub/s.txt"
  printf '*.local\n' >> "$T/.git/info/exclude"; printf 'SECRET=1\n' > "$W/env.local"
  export W
}

@test "--rollback: refused while a session is live, naming it; --dry-run prints the plan and changes nothing; the rollback saves each window's unsaved work on its lease/<NN>, removes the worktrees, keeps every lease branch, removes only Daedalus's pre-push hook, puts hot.md's session: line back, removes the stamp and prints the checkout; run twice it is safe; then git checkout v0.6.1 and v0.6.1's own session start, doctor and a push from target/ work as on v0.6.1" {
  upgraded
  before="$(home_listing)"
  # live sessions: refused, named, nothing changed
  run python3 "$H/core/upgrade.py" --rollback
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"Not going back to v0.6.1: 2 Daedalus sessions are live in this home — window 02 (session s2) and session s1. Close them, then run this again from a terminal, or add --force to go ahead while they run. Nothing was changed."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(home_listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(home_listing); return 1; }
  # the plan, with nothing changed
  run python3 "$H/core/upgrade.py" --rollback --dry-run --force
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"Going back to v0.6.1 (dry run: nothing is changed)"*"would save window 02's unsaved work in worktrees/02/thing (1 changed file, 2 untracked files) as one commit on lease/02"*"would remove worktrees/01/thing/sub, worktrees/02/thing/sub, worktrees/01/thing, worktrees/02/thing — their branches stay"*"would remove the pre-push hook Daedalus installed in target/thing"*"git -C $H checkout v0.6.1"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(home_listing)" = "$before" ] || { diff <(printf '%s\n' "$before") <(home_listing); return 1; }
  # the sessions end; the rollback
  end_sessions
  run python3 "$H/core/upgrade.py" --rollback
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  printf '%s\n' "$output" > "$B/rollback.out"
  case "$output" in *"Going back to v0.6.1"*"1. No Daedalus session is live in this home."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"saved window 02's unsaved work in worktrees/02/thing (1 changed file, 2 untracked files) as one commit on lease/02"*"saved window 02's unsaved work in worktrees/02/thing/sub (1 untracked file) as one commit on lease/02"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"moved window 02's ignored files in worktrees/02/thing (env.local) to state/rollback-kept/"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"removed worktrees/01/thing/sub, worktrees/02/thing/sub, worktrees/01/thing, worktrees/02/thing"*"marked window 01 and window 02 in state/leases/ as having no worktree"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"lease/01 in target/thing: 1 commit origin/main does not have (\"the waiting fix\")"*"lease/02 in target/thing: 1 commit origin/main does not have (\"Unsaved work in window 02, saved before going back to v0.6.1\")"*"lease/01 in target/thing/sub: nothing origin/main does not have"*"lease/02 in target/thing/sub: 1 commit origin/main does not have"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"removed the pre-push hook Daedalus installed in target/thing"*"target/thing/sub's pre-push hook is not Daedalus's; it is left as it is"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Put vault/hot.md's session: line back (session: 011)."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Left as they are, because v0.6.1 does not read them: config.yaml's memory: block, state/hindsight/api-key, state/leases/ and the other directories the upgrade made. v0.6.1's capture keeps reading its settings from the hook line in .claude/settings.local.json, which the upgrade left in place."*"The safety copy in state/upgrade-snapshot/ is kept"*"Removed state/upgraded-to."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | tail -1)" = "  git -C $H checkout v0.6.1" ] || { echo "$output"; return 1; }
  # what the rollback left: no window worktree, the work on lease/02, the ignored file kept, the hooks, hot.md, the stamp
  [ "$(git -C "$T" worktree list | wc -l | tr -d ' ')" = 1 ]; [ "$(git -C "$T/sub" worktree list | wc -l | tr -d ' ')" = 1 ]
  [ ! -e "$H/worktrees/02/thing" ]
  [ "$(git -C "$T" show lease/02:new.txt)" = new ]; [ "$(git -C "$T" show lease/02:notes/n.md)" = n ]
  [ "$(git -C "$T" show lease/02:thing.txt | tail -1)" = "edited in window 02" ]
  [ "$(git -C "$T/sub" show lease/02:s.txt)" = "nested work" ]
  git -C "$T" cat-file -e lease/01:f.txt
  [ "$(cat "$H"/state/rollback-kept/*/02/thing/env.local)" = SECRET=1 ]
  [ ! -e "$T/.git/hooks/pre-push" ]
  shasum -c "$B/own-hook.sha" >/dev/null
  [ "$(sed -n 3p "$H/vault/hot.md")" = "session: 011" ]; [ -z "$(git -C "$H/vault" status --porcelain)" ]
  grep -q '^memory:' "$H/config.yaml"; [ -f "$H/state/hindsight/api-key" ]
  [ -n "$(ls "$H/state/upgrade-snapshot")" ]; [ ! -e "$H/state/upgraded-to" ]
  # twice: safe, nothing changes, the same last step
  after="$(home_listing)"
  run python3 "$H/core/upgrade.py" --rollback
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"No window has unsaved work"*"No window worktree is left"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | tail -1)" = "  git -C $H checkout v0.6.1" ] || { echo "$output"; return 1; }
  [ "$(home_listing)" = "$after" ] || { diff <(printf '%s\n' "$after") <(home_listing); return 1; }
  # the operator's step: the code back to v0.6.1
  git -C "$H" checkout -q v0.6.1
  [ ! -e "$H/VERSION" ] && [ ! -e "$H/core/leaselib.py" ] && [ ! -e "$H/core/upgrade.py" ]
  # v0.6.1's own session start
  run --separate-stderr bash -c 'printf "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s9\",\"source\":\"startup\",\"transcript_path\":\"%s/transcripts/s9.jsonl\"}" "$1" | python3 "$2/core/session-start.py"' _ "$B" "$H"
  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ -f "$H/state/session-s9.json" ]
  # v0.6.1's own doctor: wired correctly, as before the upgrade
  run bash "$H/core/doctor.sh" </dev/null
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"deployment is wired correctly"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *MISSING*|*FAIL*|*Traceback*) echo "$output"; return 1 ;; esac
  # a push of a feature branch from target/thing to origin: no hook stands in the way
  git -C "$T" checkout -q -b feat/after-rollback; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m x
  run git -C "$T" push origin feat/after-rollback
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git --git-dir "$B/v061/thing.git" rev-parse feat/after-rollback)" = "$(git -C "$T" rev-parse HEAD)" ]
  # ... and from the nested repo, whose own hook still runs
  git -C "$T/sub" checkout -q -b feat/sub-after; printf 'y\n' > "$T/sub/y.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m y
  run git -C "$T/sub" push origin feat/sub-after
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"the operator's own pre-push check"*) : ;; *) echo "$output"; return 1 ;; esac
  # the old code can check out each window's branch
  git -C "$T" checkout -q lease/02; [ "$(cat "$T/new.txt")" = new ]; git -C "$T" checkout -q lease/01; [ -f "$T/f.txt" ]
}

@test "--rollback: a window worktree it cannot save safely — not on its lease/<NN>, holding a commit no branch has — is named and left whole, and it stops before the hooks, hot.md and the stamp; once it is dealt with, the rollback finishes" {
  upgraded
  end_sessions
  W1="$H/worktrees/01/thing"
  git -C "$W1" checkout -q --detach; printf 'd\n' > "$W1/d.txt"; git -C "$W1" add -A; cmt "$W1" -m "detached work"
  tip="$(git -C "$W1" rev-parse HEAD)"
  run python3 "$H/core/upgrade.py" --rollback
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  case "$output" in *"worktrees/01/thing is on no branch (a detached checkout), not on its window's branch lease/01"*"Stopped here: nothing after this step was changed."*"python3 core/upgrade.py --rollback"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"removed the pre-push hook"*|*"Removed state/upgraded-to"*|*"checkout v0.6.1"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W1" rev-parse HEAD)" = "$tip" ]; [ -f "$W1/d.txt" ]
  [ -x "$T/.git/hooks/pre-push" ]; [ -f "$H/state/upgraded-to" ]
  git -C "$W1" checkout -q -B lease/01
  run python3 "$H/core/upgrade.py" --rollback
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
  [ ! -e "$T/.git/hooks/pre-push" ]; [ ! -e "$H/state/upgraded-to" ]
}

@test "--rollback, then forward again: a session started on this release after the rollback upgrades the home again — the hook back, hot.md renamed, the stamp written — and the saved work is still on lease/02, which a window can take again" {
  upgraded
  end_sessions
  run python3 "$H/core/upgrade.py" --rollback
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  run start_session s3
  case "$output" in *"window 01, adopted from target/thing, now has its worktree (worktrees/01/thing)"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$H/state/upgraded-to")" = 0.7.0 ]; [ -x "$T/.git/hooks/pre-push" ]; [ -f "$H/worktrees/01/thing/f.txt" ]
  [ "$(sed -n 3p "$H/vault/hot.md")" = "leases: (see the board; prime's copy at its last write)" ]
  [ "$(git -C "$T" show lease/02:new.txt)" = new ]
  p="$(live_pid)"; registry_entry "$p" s4 interactive cli daedalus-xx
  run env DAEDALUS_SESSION_ID=s4 bash "$H/core/lease.sh" claim 02 </dev/null
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$H/worktrees/02/thing/new.txt")" = new ]; [ "$(cat "$H/worktrees/02/thing/sub/s.txt")" = "nested work" ]
}
