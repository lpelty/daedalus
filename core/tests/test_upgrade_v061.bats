#!/usr/bin/env bats
# A v0.6.1 deployment built by v0.6.1's own setup and started once by its own session start, then pulled to the
# tree under test (spec §14): the session open through the pull keeps working under the new hooks, the first new
# session upgrades the home with nobody's hands on it, and the second changes nothing.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() {
  case "$BATS_TEST_DESCRIPTION" in *"target.dir .upgrade-carry"*) V061_TARGET_DIR=.upgrade-carry ;; *) V061_TARGET_DIR= ;; esac
  v061_fixture
}
teardown() { teardown_live; }

start_session() {   # start_session <session-id> — an interactive terminal window's SessionStart, as Claude Code runs it
  local p; p="$(live_pid)"; registry_entry "$p" "$1" interactive cli daedalus-xx
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' \
    "$1" "$B" "$1" | python3 "$H/core/session-start.py"
}
prompt_s0() {       # the session that pulled (started by v0.6.1) takes its next prompt under the new hooks
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"s0","prompt":"what changed?","transcript_path":"%s/transcripts/s0.jsonl"}' \
    "$B" | python3 "$H/core/lease-board.py"
}
stop_s0() {         # ... and its Stop
  printf '{"hook_event_name":"Stop","session_id":"s0","stop_hook_active":false,"transcript_path":"%s/transcripts/s0.jsonl"}' \
    "$B" | python3 "$H/core/boundary-hook.py"
}
ctx_of() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
pick_it_up() { run bash "$H/core/lease.sh" adopt --all-unfinished </dev/null; }   # the operator said "pick it up"
win_of() {          # win_of <branch> — the number of the window adopted from <branch>
  python3 -c 'import json,sys,glob
for f in sorted(glob.glob(sys.argv[1] + "/state/leases/[0-9]*.json")):
    d = json.load(open(f))
    if d.get("adopted_from") == sys.argv[2]: print(d["lease"])' "$H" "$1"
}
ship_in_flight() {  # fix/in-flight reached origin's main: target/ holds no work origin lacks (this laptop's real shape)
  git -C "$T" push -q origin fix/in-flight:main; git -C "$T" fetch -q origin
}
TAIL="Nothing was changed. Say 'pick it up' to move it into windows, then start a new session."

@test "v0.6.1, built and started by its own code, then pulled: the open session's next prompt says the upgrade has not run and its Stop passes, with no traceback; the first new session stops the upgrade on the in-flight branch, changing nothing in target/; 'pick it up' makes it a window; the next session upgrades the home with nobody else's hands on it — every §14 predicate holds; the old session's Stop then gives only the release's config.yaml reason (do not restore it; start a new session) and the promotion backstop; the session after changes nothing" {
  pull_current
  # the session that pulled keeps running: its board leads with the pending line; nothing is created by reading
  run --separate-stderr prompt_s0
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ "$(ctx_of "$output" | head -1)" = "upgrade to $CUR has not run yet — it runs at the next session start in this home" ] || { echo "$output"; return 1; }
  [ ! -d "$H/state/leases" ]
  run --separate-stderr stop_s0
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ -z "$output" ] || { echo "the pulling session's Stop was blocked before any upgrade: $output"; return 1; }
  # the first new session: the in-flight branch is unfinished work; the upgrade stops, target/thing untouched
  tip="$(git -C "$T" rev-parse fix/in-flight)"
  run start_session s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output")"
  s="Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin). $TAIL"
  case "$c" in *"$s"*"No window opens until the upgrade finishes."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"Upgrade to $CUR: complete."*|*"installed the pre-push hook"*|*"You are window"*) echo "$c"; return 1 ;; esac
  [ ! -e "$H/state/upgraded-to" ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  [ "$(git -C "$T" rev-parse fix/in-flight)" = "$tip" ]
  run --separate-stderr prompt_s0
  [ "$(ctx_of "$output" | head -1)" = "$s" ] || { echo "$output"; return 1; }
  # the operator says "pick it up"
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds fix/in-flight from target/thing (1 commit: \"the waiting fix\")"*"Everything unfinished in target/ is in windows now. Start a new session and the upgrade finishes."*) : ;; *) echo "$output"; return 1 ;; esac
  # the next session finishes the upgrade
  run start_session s2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*"You are window 02 and you hold the pen"*) : ;; *) echo "$c"; return 1 ;; esac
  # VERSION and the stamp
  [ "$(cat "$H/VERSION")" = "$CUR" ]; [ "$(cat "$H/state/upgraded-to")" = "$CUR" ]
  # the in-flight branch is window 01; target/thing is the trunk mirror with no ahead
  [ "$(lease_json 01 adopted_from)" = fix/in-flight ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  case "$(git -C "$T" status -sb | head -1)" in *ahead*) echo "still ahead"; return 1 ;; esac
  run bash "$H/core/lease.sh" list
  case "$output" in *"- 01 "*"adopted from fix/in-flight"*) : ;; *) echo "$output"; return 1 ;; esac
  # the hook in Daedalus's own checkout, outer and nested
  run python3 "$H/core/prepush.py" status "$T" "$T/sub"
  [ "$(printf '%s\n' "$output" | cut -f2 | sort -u)" = installed ] || { echo "$output"; return 1; }
  # memory moved; the predicate resolves it with no TENANT_* in the environment
  grep -q '^memory:' "$H/config.yaml"; [ "$(stat -f %Lp "$H/state/hindsight/api-key")" = 600 ]
  run env -u TENANT_BANK -u TENANT_HOME -u TRANSCRIPT_DIR -u HINDSIGHT_API_TENANT_API_KEY bash "$H/core/capture-tick.sh" --dry-run </dev/null
  case "$output" in *"bank bank-one"*"transcript directory $BATS_TEST_TMPDIR/tx"*) : ;; *) echo "$output"; return 1 ;; esac
  # dedup gone, hot.md renamed
  [ ! -e "$H/state/pitfall-seen.json" ]; [ ! -e "$H/state/code-context-seen.json" ]
  [ "$(sed -n 3p "$H/vault/hot.md")" = "leases: (see the board; prime's copy at its last write)" ]
  # doctor: the version line and the upgrade stamp, and nothing MISSING about VERSION, leases or hooks
  run bash "$H/core/doctor.sh"
  case "$output" in *"OK       version: $CUR"*"OK       upgrade: state/upgraded-to $CUR"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"MISSING  VERSION"*|*"MISSING  state/"*|*"MISSING  worktrees/"*|*"MISSING  pre-push hook"*) echo "$output"; return 1 ;; esac
  # the old session's Stop after the upgrade blocks (exit 2, reasons on stderr) with only the reasons the spec gives
  # a session left open through an upgrade: config.yaml changed under it (the memory: block; Decision 11 — the
  # sentence tells the operator to restart it), and the promotion backstop, which cannot tell an unnumbered
  # session's tree now that several sessions are live. Never a traceback.
  run --separate-stderr stop_s0
  case "$status" in 0|2) : ;; *) echo "status $status: $output $stderr"; return 1 ;; esac
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"config.yaml changed under this session, by the upgrade to $CUR — not by this session. Do not restore it"*"tell the operator to close it and start a new session."*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"changed this session; restore it"*) echo "$stderr"; return 1 ;; esac
  [ -z "$(printf '%s\n' "$stderr" | grep -v -e '^$' -e '^config.yaml changed under this session, by the upgrade' -e '^Promotion check')" ] \
    || { echo "an unexpected Stop reason for the old session: $stderr"; return 1; }
  run --separate-stderr stop_s0
  case "$stderr" in *"changed this session; restore it"*) echo "$stderr"; return 1 ;; esac
  # the session after: nothing upgrades again
  before="$(cd "$H" && find config.yaml vault/hot.md state/hindsight state/upgraded-to -type f | sort | xargs shasum)"
  run start_session s3
  case "$output" in *"Upgrade to"*) echo "$output"; return 1 ;; esac
  [ "$(cd "$H" && find config.yaml vault/hot.md state/hindsight state/upgraded-to -type f | sort | xargs shasum)" = "$before" ]
}

target_bytes() {    # every file under target/, git's own included, by content (and every symlink by its target);
  # FETCH_HEAD left out — the one file the upgrade's own fetch writes
  (cd "$H/target" && find . \( -type f -o -type l \) ! -name FETCH_HEAD -print | LC_ALL=C sort | while IFS= read -r f; do
     if [ -L "$f" ]; then printf 'L %s -> %s\n' "$f" "$(readlink "$f")"; else printf '%s  %s\n' "$(shasum < "$f" | cut -c1-40)" "$f"; fi
   done)
}

@test "v0.6.1, pulled, with unfinished work — an unshipped branch and an untracked file, the checkout on a branch already on origin: the first new session stops the upgrade and numbers no window — every byte under target/, .git included, is as it was (FETCH_HEAD aside): no lease/01, no worktree record, no branch section, no pre-push hook; the board says the stop and that windows open once the upgrade finishes; lease.sh refuses to make a window with the same pointer, changing nothing; 'pick it up' still works and the next start completes and numbers itself (final verification, mode c)" {
  ship_in_flight
  git -C "$T" branch feat/unshipped; git -C "$T" checkout -q feat/unshipped
  printf 'u\n' > "$T/u.txt"; git -C "$T" add -A; cmt "$T" -m "unshipped work"; git -C "$T" checkout -q fix/in-flight
  printf 'my notes\n' > "$T/notes.txt"
  pull_current
  before="$(target_bytes)"
  [ -n "$before" ] && printf '%s\n' "$before" | grep -q '/\.git/HEAD$'
  run --separate-stderr start_session s1
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  c="$(ctx_of "$output")"
  s="Daedalus has unfinished work in target/thing: the branch feat/unshipped (1 commit not on origin), and 1 unsaved file. $TAIL"
  case "$c" in *"$s"*"No window opens until the upgrade finishes."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"a session started after that is numbered"*) echo "$c"; return 1 ;; esac
  case "$c" in *"You are window"*|*"you hold the pen"*|*"installed the pre-push hook"*|*"complete."*) echo "$c"; return 1 ;; esac
  [ "$(target_bytes)" = "$before" ] || { diff <(printf '%s\n' "$before") <(target_bytes); return 1; }
  [ ! -e "$H/state/upgraded-to" ]; [ -z "$(ls "$H/state/leases" 2>/dev/null)" ]
  [ ! -e "$T/.git/refs/heads/lease/01" ] && [ ! -e "$T/.git/hooks/pre-push" ] && [ ! -d "$T/.git/worktrees" ]
  ! grep -q 'branch "lease/' "$T/.git/config" "$T/sub/.git/config"
  # the open session's next prompt: the stop, then that windows open once the upgrade finishes
  run --separate-stderr prompt_s0
  b="$(ctx_of "$output")"
  [ "$(printf '%s\n' "$b" | sed -n 1p)" = "$s" ] || { echo "$b"; return 1; }
  [ "$(printf '%s\n' "$b" | sed -n 2p)" = "No window opens until the upgrade finishes." ] || { echo "$b"; return 1; }
  # a window made by hand is refused with the same pointer, and changes nothing either
  for cmd in "create" "adopt feat/unshipped" "spawn task" "claim 01"; do
    run --separate-stderr env DAEDALUS_SESSION_ID=s1 bash "$H/core/lease.sh" $cmd </dev/null
    [ "$status" -eq 1 ] || { echo "$cmd: status $status: $output $stderr"; return 1; }
    [ "$stderr" = "daedalus: no window opens until the upgrade to $CUR finishes, so \`core/lease.sh ${cmd%% *}\` is refused. $s" ] \
      || { echo "$cmd: $stderr"; return 1; }
  done
  [ "$(target_bytes)" = "$before" ] || { diff <(printf '%s\n' "$before") <(target_bytes); return 1; }
  [ -z "$(ls "$H/state/leases" 2>/dev/null)" ]
  # "pick it up" is the one way in, and the next start finishes the upgrade and numbers itself
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"now holds feat/unshipped from target/thing"*"Everything unfinished in target/ is in windows now. Start a new session and the upgrade finishes."*) : ;; *) echo "$output"; return 1 ;; esac
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*"You are window 0"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"windows open once the upgrade finishes"*) echo "$c"; return 1 ;; esac
  [ "$(cat "$H/state/upgraded-to")" = "$CUR" ]
}

@test "v0.6.1, pulled, with an uncommitted edit hidden from git status by skip-worktree on the in-flight checkout: the first new session stops the upgrade naming the file — no stamp, no window, the edit where it was; doctor names it with how to clear the mark (release-candidate review 2, finding 6)" {
  printf 'MY UNCOMMITTED EDIT\n' > "$T/thing.txt"; git -C "$T" update-index --skip-worktree thing.txt
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ]
  pull_current
  run start_session s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output")"
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin), and 1 changed file git status does not show (thing.txt). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"Upgrade to $CUR: complete."*) echo "$c"; return 1 ;; esac
  [ ! -e "$H/state/upgraded-to" ]; ! grep -qs adopted_from "$H"/state/leases/*.json
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; [ "$(cat "$T/thing.txt")" = "MY UNCOMMITTED EDIT" ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"target/thing has uncommitted changes git status does not show, in files marked skip-worktree (thing.txt) — no window has them; clear the mark (git -C target/thing update-index --no-skip-worktree thing.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
}

s1_ctx() {          # the first new session after the pull; its context in $c
  run --separate-stderr start_session s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output" 2>/dev/null)" || { echo "not the hook's JSON: $output"; return 1; }
}
origin_moves() {    # someone else pushes one commit to origin's main; target/thing fetches it
  git clone -q "$B/v061/thing.git" "$B/mk"
  printf 'x\n' > "$B/mk/x.txt"; git -C "$B/mk" add x.txt; cmt "$B/mk" -m "small fix, pushed"; git -C "$B/mk" push -q origin main
  git -C "$T" fetch -q origin
}

@test "v0.6.1 with target.dir .upgrade-carry, pulled, the checkout on a branch with untracked files: 'pick it up' saves them with the branch into its window's worktree whole — a target named like a temporary directory is just a name (release-candidate review 3, finding 1)" {
  [ "$(basename "$T")" = .upgrade-carry ]
  printf 'MY NOTES\n' > "$T/notes.md"; mkdir -p "$T/draft"; printf 'A DRAFT\n' > "$T/draft/a.md"
  pull_current
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/.upgrade-carry: the branch fix/in-flight (1 commit not on origin), and 2 unsaved files. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  case "$(ctx_of "$output")" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  W="$H/worktrees/$(win_of fix/in-flight)/.upgrade-carry"
  [ "$(git -C "$W" branch --show-current)" = "lease/$(win_of fix/in-flight)" ]; [ "$(cat "$W/f.txt")" = f ]
  [ "$(cat "$W/notes.md")" = "MY NOTES" ]; [ "$(cat "$W/draft/a.md")" = "A DRAFT" ]; [ -z "$(git -C "$W" status --porcelain)" ]
  [ ! -e "$T/notes.md" ]; [ ! -e "$T/draft" ]
}

@test "v0.6.1, pulled, with worktrees made by hand on a volume not mounted at the first new session — one detached with a commit no branch has, one holding a staged change: the upgrade stops naming both, and both come back whole (release-candidate review 3, finding 2)" {
  git -C "$T" worktree add -q --detach "$B/vol/exp" main
  printf 'e\n' > "$B/vol/exp/e.txt"; git -C "$B/vol/exp" add -A; cmt "$B/vol/exp" -m "exp-only"
  sha="$(git -C "$B/vol/exp" rev-parse HEAD)"
  git -C "$T" worktree add -q -b exp/staged "$B/vol/st" main
  printf 'staged\n' > "$B/vol/st/s.txt"; git -C "$B/vol/st" add s.txt; printf 'on disk\n' > "$B/vol/st/s.txt"
  pull_current
  mv "$B/vol" "$B/vol-unmounted"
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin), a worktree made by hand at $B/vol/exp (its directory is gone), and a worktree made by hand at $B/vol/st (its directory is gone). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  mv "$B/vol-unmounted" "$B/vol"
  [ "$(git -C "$B/vol/exp" rev-parse HEAD)" = "$sha" ] || { git -C "$B/vol/exp" status; return 1; }
  [ "$(git -C "$B/vol/st" show :s.txt)" = staged ]; [ "$(cat "$B/vol/st/s.txt")" = "on disk" ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $B/vol/exp, a detached HEAD with 1 commit no branch has (\"exp-only\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $B/vol/st, on branch exp/staged, uncommitted or untracked files (s.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, with a parked branch whose only unpushed content is in a merge commit: git cherry passes it over, the upgrade does not — it stops naming the branch, and 'pick it up' makes it a window holding that content (release-candidate review 3, finding 3)" {
  origin_moves
  git -C "$T" branch spike/notes origin/main~1
  git -C "$T" worktree add -q "$B/tmpwt" spike/notes
  git -C "$B/tmpwt" merge -q --no-ff --no-commit origin/main >/dev/null 2>&1
  printf 'MY UNPUSHED DESIGN NOTES\n' > "$B/tmpwt/notes.md"; git -C "$B/tmpwt" add notes.md
  cmt "$B/tmpwt" -m "Merge origin/main into spike/notes (with my notes)"
  git -C "$T" worktree remove "$B/tmpwt"
  [ -z "$(git -C "$T" cherry origin/main spike/notes)" ]
  pull_current
  run python3 "$H/core/upgrade.py" --doctor
  case "$output" in *"NOTE     target/thing has branch spike/notes, 1 commit past origin/main, in no window"*) : ;; *) echo "$output"; return 1 ;; esac
  s1_ctx
  case "$c" in *"the branch spike/notes (1 commit not on origin)"*"$TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"now holds spike/notes from target/thing (1 commit: \"Merge origin/main into spike/notes (with my notes)\")"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$H/worktrees/$(win_of spike/notes)/thing/notes.md")" = "MY UNPUSHED DESIGN NOTES" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/spike/notes >/dev/null
}

@test "v0.6.1, pulled, on a branch whose only unpushed commit is a merge carrying content: the upgrade stops naming it, not 'already on origin/main'; a merge that adds nothing is still no work (release-candidate review 3, finding 3)" {
  origin_moves
  git -C "$T" checkout -q -b fix/merge-notes origin/main~1
  git -C "$T" merge -q --no-ff --no-commit origin/main >/dev/null 2>&1
  printf 'MY UNPUSHED DESIGN NOTES\n' > "$T/notes.md"; git -C "$T" add notes.md
  cmt "$T" -m "Merge origin/main into fix/merge-notes (resolved; notes added)"
  git -C "$T" branch plain/merge origin/main~1
  git -C "$T" worktree add -q "$B/tmpwt" plain/merge
  git -C "$B/tmpwt" -c user.email=t@x -c user.name=t merge -q --no-ff origin/main -m "Merge origin/main into plain/merge"
  git -C "$T" worktree remove "$B/tmpwt"
  pull_current
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/merge-notes (1 commit not on origin), and the branch fix/in-flight (1 commit not on origin). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"whose work is already on origin/main"*|*"plain/merge"*) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$H/worktrees/$(win_of fix/merge-notes)/thing/notes.md")" = "MY UNPUSHED DESIGN NOTES" ]
  git -C "$T" rev-parse -q --verify refs/heads/plain/merge >/dev/null
}

@test "v0.6.1, pulled, with a branch named lease/00 holding a user branch's unpushed commit: neither hides — the upgrade names it, 'pick it up' makes the work a window, lease/00 is gone, and doctor names nothing left behind (release-candidate review 3, finding 4)" {
  git -C "$T" branch wip/report main
  git -C "$T" worktree add -q "$B/tmpwt" wip/report
  printf 'REPORT DRAFT\n' > "$B/tmpwt/report.md"; git -C "$B/tmpwt" add report.md; cmt "$B/tmpwt" -m "report draft"
  git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" branch lease/00 wip/report
  pull_current
  run python3 "$H/core/upgrade.py" --doctor
  case "$output" in *"branch lease/00, 1 commit past origin/main, in no window"*) : ;; *) echo "$output"; return 1 ;; esac
  s1_ctx
  case "$c" in *"the branch lease/00 (1 commit not on origin)"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  nn="$(win_of lease/00)"
  [ "$(cat "$H/worktrees/$nn/thing/report.md")" = "REPORT DRAFT" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/lease/00 >/dev/null
  git -C "$T" merge-base --is-ancestor wip/report "lease/$nn"
  run python3 "$H/core/upgrade.py" --doctor
  case "$output" in *"in no window"*) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, with worktrees made by hand — one on a new branch with an uncommitted edit and an untracked file, one detached with a commit no branch has: the upgrade stops naming each and leaves them as they are; doctor names their work (release-candidate review 3, finding 5)" {
  git -C "$T" worktree add -q -b exp/a "$B/hand-a" main
  printf 'edit\n' >> "$B/hand-a/thing.txt"; printf 'n\n' > "$B/hand-a/new.md"
  git -C "$T" worktree add -q --detach "$B/hand-b" main
  printf 'd\n' > "$B/hand-b/d.txt"; git -C "$B/hand-b" add -A; cmt "$B/hand-b" -m "detached work"
  pull_current
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin), a worktree made by hand at $B/hand-a, and a worktree made by hand at $B/hand-b. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(git -C "$B/hand-a" status --porcelain | sort | tr '\n' '|')" = " M thing.txt|?? new.md|" ]
  [ "$(git -C "$B/hand-b" log -1 --format=%s)" = "detached work" ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $B/hand-a, on branch exp/a, uncommitted or untracked files (new.md, thing.txt)"*"NOTE     target/thing has a worktree made by hand at $B/hand-b, a detached HEAD with 1 commit no branch has (\"detached work\")"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, with ignored work in checkouts no window is made from — the outer repo on a branch already on origin, and the nested repo: the upgrade names each once; the files stay (release-candidate review 3, finding 6)" {
  git -C "$T" checkout -q main; git -C "$T" branch -D -q fix/in-flight; git -C "$T" checkout -q -b fix/done
  printf '*.local.md\n' >> "$T/.git/info/exclude"; printf 'MY WIP PLAN\n' > "$T/plan.local.md"
  printf '*.local.md\n' >> "$T/sub/.git/info/exclude"; printf 'MY SUB WIP\n' > "$T/sub/todo.local.md"
  pull_current
  s1_ctx
  case "$c" in *"target/thing was on fix/done, whose work is already on origin/main"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing holds ignored files no window has (plan.local.md) — they stay there, in the trunk mirror, which no session works in; if any of them is work, move it into a window's worktree (worktrees/<NN>/thing)."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing/sub holds ignored files no window has (todo.local.md)"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$T/plan.local.md")" = "MY WIP PLAN" ]; [ "$(cat "$T/sub/todo.local.md")" = "MY SUB WIP" ]
}

@test "v0.6.1, pulled, with an empty lease file and an empty prime.json a cut-off reservation left: the first new session clears them, upgrades, numbers itself and renders the board; sweep works (release-candidate review 3, finding 7)" {
  ship_in_flight
  pull_current
  mkdir -p "$H/state/leases"; : > "$H/state/leases/01.json"; : > "$H/state/leases/prime.json"
  s1_ctx
  case "$c" in *"Upgrade to $CUR: complete."*"You are window 0"*"and you hold the pen"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"could not be rendered"*|*"cannot be bound"*) echo "$c"; return 1 ;; esac
  run bash "$H/core/lease.sh" sweep
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v0.6.1, pulled, where an earlier adoption's worktree add for the in-flight branch was cut off — lease/01 at its tip, a record locked 'initializing' over a directory whose .git file was never written: 'pick it up' clears it and finishes window 01 (release-candidate review 3, finding 8)" {
  pull_current
  git -C "$T" branch lease/01 fix/in-flight
  mkdir -p "$H/worktrees/01"
  git -C "$T" worktree add -q --lock --reason initializing "$H/worktrees/01/thing" lease/01; : > "$H/worktrees/01/thing/.git"
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds fix/in-flight from target/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H/worktrees/01/thing" branch --show-current)" = lease/01 ]; [ "$(cat "$H/worktrees/01/thing/f.txt")" = f ]
  ! git -C "$T" rev-parse -q --verify refs/heads/fix/in-flight >/dev/null
  run start_session s2
  case "$(ctx_of "$output")" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, where a git command was cut off part-way — the checkout on a branch that no longer exists, or lock files left: the upgrade stops naming the branch's commit or the files, never 'commit them'; put right and picked up, the next start finishes (release-candidate review 3, finding 9)" {
  sha="$(git -C "$T" rev-parse fix/in-flight)"
  git -C "$T" update-ref -d refs/heads/fix/in-flight
  pull_current
  s1_ctx
  case "$c" in *"upgrade to $CUR incomplete: target/thing is on branch fix/in-flight, which does not exist — a git command was cut off part-way; the branch's last commit is ${sha:0:7} (from HEAD's reflog). Put the branch back with git -C target/thing branch fix/in-flight ${sha:0:7}"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"commit them"*|*"Upgrade to $CUR: complete."*) echo "$c"; return 1 ;; esac
  git -C "$T" branch fix/in-flight "${sha:0:7}"
  : > "$T/.git/packed-refs.lock"; : > "$T/.git/refs/heads/fix/in-flight.lock"
  touch -t 202001010000 "$T/.git/packed-refs.lock" "$T/.git/refs/heads/fix/in-flight.lock"
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"upgrade to $CUR incomplete: target/thing holds lock files a git command left when it was cut off (target/thing/.git/packed-refs.lock, target/thing/.git/refs/heads/fix/in-flight.lock) — if no git command is running there, remove them"*) : ;; *) echo "$c"; return 1 ;; esac
  rm "$T/.git/packed-refs.lock" "$T/.git/refs/heads/fix/in-flight.lock"
  # s1 and s2 have no window (none opens until the upgrade finishes); a window branch's own lock file, left by a
  # cut-off add, is cleared, not a stop
  [ ! -d "$T/.git/refs/heads/lease" ]; mkdir -p "$T/.git/refs/heads/lease"
  : > "$T/.git/refs/heads/lease/01.lock"; touch -t 202001010000 "$T/.git/refs/heads/lease/01.lock"
  run start_session s3
  c="$(ctx_of "$output")"
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin)."*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s4
  case "$(ctx_of "$output")" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse "lease/$(win_of fix/in-flight)")" = "$sha" ]
}

@test "v0.6.1, pulled, with a worktree left under worktrees/01 on the in-flight branch and no lease file: the upgrade stops naming it as a worktree made by hand, never gives its number to a window over it; 'pick it up' names it with what to do and moves the work; removed, the upgrade completes (release-candidate review 3, finding 10)" {
  git -C "$T" checkout -q -b feature/b main; printf 'b\n' > "$T/b.txt"; git -C "$T" add -A; cmt "$T" -m "b work"
  git -C "$T" checkout -q main
  pull_current
  mkdir -p "$H/worktrees/01"; git -C "$T" worktree add -q "$H/worktrees/01/thing" fix/in-flight
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch feature/b (1 commit not on origin), the branch fix/in-flight (1 commit not on origin), and a worktree made by hand at $H/worktrees/01/thing. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"You are window 01"*) echo "$c"; return 1 ;; esac
  [ "$(git -C "$H/worktrees/01/thing" branch --show-current)" = fix/in-flight ]
  pick_it_up
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"now holds feature/b from target/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  # its branch's commits become a window all the same; the branch's name stays while that worktree has it out
  case "$output" in *"now holds fix/in-flight from target/thing"*"fix/in-flight, checked out in another worktree, was left as it was in target/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing has a worktree made by hand at $H/worktrees/01/thing — commit its work on a branch there, then remove it (git -C target/thing worktree remove $H/worktrees/01/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$H/worktrees/01/thing" branch --show-current)" = fix/in-flight ]
  git -C "$T" worktree remove "$H/worktrees/01/thing"
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Nothing unfinished in target/ to pick up."*) : ;; *) echo "$output"; return 1 ;; esac
  run start_session s2
  case "$(ctx_of "$output")" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$H/worktrees/$(win_of fix/in-flight)/thing/f.txt")" = f ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"in no window"*) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, where git does not tell case apart, with branch Wip (packed) and branch wip (a loose file) each holding a commit: the upgrade stops naming both and how to rename one — nothing moves, both commits stay on their branches; renamed and picked up, each is a window and the next start completes (release-candidate review 4, finding 1)" {
  [ "$(git -C "$T" config --bool core.ignorecase)" = true ] || skip "git here tells branch names apart by case"
  git -C "$T" worktree add -q -b Wip "$B/tmpwt" main
  printf 'U\n' > "$B/tmpwt/upper.txt"; git -C "$B/tmpwt" add -A; cmt "$B/tmpwt" -m "UPPER WORK"
  c1="$(git -C "$B/tmpwt" rev-parse HEAD)"; git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" pack-refs --all
  git -C "$T" worktree add -q --detach "$B/tmpwt" main
  printf 'L\n' > "$B/tmpwt/lower.txt"; git -C "$B/tmpwt" add -A; cmt "$B/tmpwt" -m "LOWER WORK"
  c2="$(git -C "$B/tmpwt" rev-parse HEAD)"; git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" branch wip "$c2"
  refs="$(git -C "$T" for-each-ref --format='%(refname) %(objectname)' refs/heads/)"
  case "$refs" in *"refs/heads/Wip $c1"*"refs/heads/wip $c2"*) : ;; *) echo "$refs"; return 1 ;; esac
  pull_current
  s1_ctx
  case "$c" in *"upgrade to $CUR incomplete: target/thing has branches whose names differ only in case (Wip, wip)"*"git -C target/thing pack-refs --all, then git -C target/thing branch -m Wip <new name>"*) : ;; *) echo "$c"; return 1 ;; esac
  [ ! -e "$H/state/upgraded-to" ]; ! grep -qs adopted_from "$H"/state/leases/*.json
  [ "$(git -C "$T" for-each-ref --format='%(refname) %(objectname)' refs/heads/ | grep -i '/wip ')" = "$(printf '%s\n' "$refs" | grep -i '/wip ')" ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"target/thing has branches whose names differ only in case (Wip, wip)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" pack-refs --all; git -C "$T" branch -m Wip upper-work
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ -n "$(git -C "$T" for-each-ref --contains "$c1" refs/heads/lease/)" ] || { git -C "$T" for-each-ref; return 1; }
  [ -n "$(git -C "$T" for-each-ref --contains "$c2" refs/heads/lease/)" ] || { git -C "$T" for-each-ref; return 1; }
}

@test "v0.6.1, pulled, with branch names a tag makes ambiguous — a branch feat/x holding work beside a tag feat/x at origin/main, and a tag main: the upgrade names the branch, never 'heads/'; picked up, feat/x's own commit becomes a window, the tags stay, and the next start completes (release-candidate review 4, finding 2)" {
  git -C "$T" branch feat/x main
  git -C "$T" worktree add -q "$B/tmpwt" feat/x
  printf 'X\n' > "$B/tmpwt/x-work.txt"; git -C "$B/tmpwt" add -A; cmt "$B/tmpwt" -m "X WORK"
  git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" tag feat/x refs/remotes/origin/main; git -C "$T" tag main refs/remotes/origin/main
  pull_current
  s1_ctx
  case "$c" in *"heads/"*) echo "$c"; return 1 ;; esac
  case "$c" in *"the branch feat/x (1 commit not on origin)"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  case "$(ctx_of "$output")" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$H/worktrees/$(win_of feat/x)/thing/x-work.txt")" = X ]
  git -C "$T" rev-parse -q --verify refs/tags/feat/x >/dev/null; git -C "$T" rev-parse -q --verify refs/tags/main >/dev/null
  ! git -C "$T" rev-parse -q --verify refs/heads/feat/x >/dev/null
}

@test "v0.6.1, pulled, with worktrees made by hand under worktrees/ — worktrees/hotfix detached with a commit no branch has, an uncommitted edit and an untracked file; worktrees/scratch on a new branch with only an uncommitted edit and an untracked file: the upgrade stops naming both and leaves them as they are; doctor names their work (release-candidate review 4, finding 3)" {
  mkdir -p "$H/worktrees"
  W="$H/worktrees/hotfix"; git -C "$T" worktree add -q --detach "$W" main
  printf 'h\n' > "$W/h.txt"; git -C "$W" add h.txt; cmt "$W" -m "secret hotfix"
  printf 'edit\n' >> "$W/thing.txt"; printf 'n\n' > "$W/notes.md"
  S="$H/worktrees/scratch"; git -C "$T" worktree add -q -b exp/scratch "$S" main
  printf 'edit\n' >> "$S/thing.txt"; printf 'd\n' > "$S/draft.md"
  pull_current
  s1_ctx
  case "$c" in *"a worktree made by hand at $W, and a worktree made by hand at $S. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(git -C "$W" log -1 --format=%s)" = "secret hotfix" ]; [ "$(cat "$W/notes.md")" = n ]; [ "$(cat "$S/draft.md")" = d ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $W, a detached HEAD with 1 commit no branch has (\"secret hotfix\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $S, on branch exp/scratch"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"made by hand at $H/worktrees/0"*) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, with work inside a git submodule of the target — an untracked file, an uncommitted edit, a branch with a commit, a stash: it is not unfinished work — once the branch is picked up the upgrade completes and names it once, the work stays where it was, doctor names it (release-candidate review 4, finding 4)" {
  sd="$B/seed-lib"; git init -q -b main "$sd"; printf 'lib\n' > "$sd/lib.txt"; git -C "$sd" add -A; cmt "$sd" -m lib
  git init -q --bare -b main "$B/v061/lib.git"; git -C "$sd" push -q "$B/v061/lib.git" main
  git clone -q "$B/v061/thing.git" "$B/mk"
  git -C "$B/mk" -c protocol.file.allow=always submodule add -q "$B/v061/lib.git" lib >/dev/null 2>&1
  cmt "$B/mk" -m "add lib"; git -C "$B/mk" push -q origin main
  git -C "$T" fetch -q origin
  git -C "$T" -c user.email=t@x -c user.name=t rebase -q refs/remotes/origin/main
  git -C "$T" -c protocol.file.allow=always submodule update -q --init >/dev/null 2>&1
  L="$T/lib"; rec="$(git -C "$L" rev-parse HEAD)"
  git -C "$L" checkout -q -b wip/lib; printf 'w\n' > "$L/w.txt"; git -C "$L" add w.txt; cmt "$L" -m "lib wip commit"
  git -C "$L" checkout -q --detach "$rec"
  printf 'stashed\n' >> "$L/lib.txt"; git -C "$L" -c user.email=t@x -c user.name=t stash -q
  printf 'edit\n' >> "$L/lib.txt"; printf 'MY LIB NOTES\n' > "$L/notes.md"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no --ignore-submodules=dirty)" ]
  pull_current
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing's submodule lib holds work no window has: uncommitted or untracked files (lib.txt, notes.md); branch wip/lib, 1 commit its origin lacks (\"lib wip commit\"); 1 stash entry (stash@{0}:"*"the upgrade leaves it there"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$L/notes.md")" = "MY LIB NOTES" ]; [ "$(git -C "$L" log -1 --format=%s wip/lib)" = "lib wip commit" ]
  [ -n "$(git -C "$L" stash list)" ]; grep -q edit "$L/lib.txt"
  run bash "$H/core/doctor.sh"
  case "$output" in *"NOTE     target/thing's submodule lib holds work no window has: uncommitted or untracked files (lib.txt, notes.md)"*) : ;; *) echo "$output"; return 1 ;; esac
}

kill_at() {         # kill_at "<ref> <new value>" — at target/thing's next ref update to that value ("prepared"), the
                    # python process running git is killed, then that git (a hook's timeout, a kill -9): once
  cat > "$T/.git/hooks/reference-transaction" <<HOOK
#!/bin/sh
[ "\$1" = prepared ] || exit 0
[ -e "$B/killed" ] && exit 0
while read o n r; do
  if [ "\$r \$n" = "$1" ]; then
    : > "$B/killed"
    pid=\$PPID; py=
    while [ -n "\$pid" ] && [ "\$pid" -gt 1 ]; do
      case "\$(ps -o command= -p "\$pid")" in *python*) py=\$pid; break ;; esac
      pid="\$(ps -o ppid= -p "\$pid" | tr -d ' ')"
    done
    [ -n "\$py" ] && kill -9 "\$py"
    kill -9 \$PPID
    exit 0
  fi
done
HOOK
  chmod +x "$T/.git/hooks/reference-transaction"
}
old_locks() { find "$T/.git" -name '*.lock' -exec touch -t 202001010000 {} +; }

@test "v0.6.1, pulled, with main ahead of origin and untracked files: 'pick it up' saves them on a branch of their own and makes it a window; its reset of main, cut off part-way (git and pick-up killed), is finished by the next start — never 'commit them', never saved as work; one window holds the commit and the files (release-candidate review 4, finding 5)" {
  origin_moves
  git -C "$T" checkout -q main; git -C "$T" branch -D -q fix/in-flight
  printf 'T\n' > "$T/trunk.txt"; git -C "$T" add trunk.txt; cmt "$T" -m "trunk work, unpushed"
  sha="$(git -C "$T" rev-parse main)"
  printf 'MY NOTES\n' > "$T/notes.md"
  pull_current
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch main (1 commit not on origin), and 1 unsaved file. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  kill_at "refs/heads/main $(git -C "$T" rev-parse refs/remotes/origin/main)"
  pick_it_up
  [ -e "$B/killed" ] || { echo "the reset was never cut off: $output"; return 1; }
  rm "$T/.git/hooks/reference-transaction"
  [ "$(git -C "$T" rev-parse refs/heads/main)" = "$sha" ]; [ -n "$(git -C "$T" status --porcelain --untracked-files=no)" ]
  # the reset it began is marked, so the next run finishes it (review of option 1, finding 1)
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1])) == {"thing": sys.argv[2]}' "$H/state/upgrade-trunk-reset.json" "$sha"
  run bash "$H/core/doctor.sh"
  case "$output" in *"target/thing main is 1 commit ahead of origin/main, but window"*"already holds it"*) : ;; *) echo "$output"; return 1 ;; esac
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"commit them"*|*"Upgrade to $CUR: complete."*|*"unsaved file"*) echo "$c"; return 1 ;; esac
  case "$c" in *"a git command Daedalus ran in target/thing (resetting main to origin/main) was cut off part-way, or is still running"*"do not commit anything there"*) : ;; *) echo "$c"; return 1 ;; esac
  # "pick it up" again: it finishes the cut-off reset — the half-reset tree is never saved as work
  old_locks
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"a git command Daedalus ran in target/thing (resetting main to origin/main) was cut off part-way; it is finished now"*"Nothing unfinished in target/ to pick up."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Window"*"now holds"*|*"Unsaved"*) echo "$output"; return 1 ;; esac
  run start_session s3
  c="$(ctx_of "$output")"
  case "$c" in *"commit them"*|*"unsaved file"*) echo "$c"; return 1 ;; esac
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  n="$(git -C "$T" for-each-ref --contains "$sha" --format='%(refname)' refs/heads/lease/)"
  [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] || { echo "$n"; return 1; }
  nn="${n#refs/heads/lease/}"
  [ "$(git -C "$T" rev-parse refs/heads/main)" = "$(git -C "$T" rev-parse refs/remotes/origin/main)" ]
  [ -z "$(git -C "$T" status --porcelain)" ] || { git -C "$T" status --porcelain; return 1; }
  [ "$(cat "$H/worktrees/$nn/thing/notes.md")" = "MY NOTES" ]; [ "$(cat "$H/worktrees/$nn/thing/trunk.txt")" = T ]
  [ ! -e "$H/state/upgrade-trunk-reset.json" ]
}

@test "v0.6.1, pulled, on the in-flight branch with untracked files: 'pick it up' saves them on the branch; its checkout back to main, cut off part-way (git and pick-up killed), is finished by the next start — never 'commit them'; the window holds the branch's commit and the files (release-candidate review 4, finding 6)" {
  sha="$(git -C "$T" rev-parse fix/in-flight)"
  printf 'MY NOTES\n' > "$T/notes.md"
  pull_current
  s1_ctx
  kill_at "HEAD ref:refs/heads/main"
  pick_it_up
  [ -e "$B/killed" ] || { echo "the checkout was never cut off: $output"; return 1; }
  rm "$T/.git/hooks/reference-transaction"
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"commit them"*|*"Upgrade to $CUR: complete."*) echo "$c"; return 1 ;; esac
  case "$c" in *"a git command Daedalus ran in target/thing (putting it back on main) was cut off part-way, or is still running"*) : ;; *) echo "$c"; return 1 ;; esac
  old_locks
  run start_session s3
  c="$(ctx_of "$output")"
  case "$c" in *"commit them"*|*"whose work is already on origin/main"*) echo "$c"; return 1 ;; esac
  case "$c" in *"a git command Daedalus ran in target/thing (putting it back on main) was cut off part-way; it is finished now"*"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  nn="$(win_of fix/in-flight)"
  git -C "$T" merge-base --is-ancestor "$sha" "lease/$nn"; [ "$(git -C "$T" branch --show-current)" = main ]
  [ -z "$(git -C "$T" status --porcelain)" ] || { git -C "$T" status --porcelain; return 1; }
  [ "$(cat "$H/worktrees/$nn/thing/notes.md")" = "MY NOTES" ]; [ "$(cat "$H/worktrees/$nn/thing/f.txt")" = f ]
  ! git -C "$T" rev-parse -q --verify refs/heads/fix/in-flight >/dev/null
}

# --- release-candidate red team 2 -----------------------------------------------------------------------------

lib_origin() {      # origin's main gains a submodule lib; target/thing's checkout of it is initialized
  sd="$B/seed-lib"; git init -q -b main "$sd"; printf 'lib\n' > "$sd/lib.txt"; git -C "$sd" add -A; cmt "$sd" -m lib
  git init -q --bare -b main "$B/v061/lib.git"; git -C "$sd" push -q "$B/v061/lib.git" main
  git clone -q "$B/v061/thing.git" "$B/mk"
  git -C "$B/mk" -c protocol.file.allow=always submodule add -q "$B/v061/lib.git" lib >/dev/null 2>&1
  cmt "$B/mk" -m "add lib"; git -C "$B/mk" push -q origin main
  git -C "$T" fetch -q origin
}
lib_init() { git -C "$T" -c protocol.file.allow=always submodule update -q --init >/dev/null 2>&1; L="$T/lib"; }
mk_moves() {        # one more commit on origin's main, made from the scratch clone
  git -C "$B/mk" pull -q --ff-only origin main
  printf 'moved\n' > "$B/mk/moved.txt"; git -C "$B/mk" add moved.txt; cmt "$B/mk" -m "moved on"; git -C "$B/mk" push -q origin main
}

@test "v0.6.1, pulled, with submodule.recurse set and an uncommitted edit in a submodule, main ahead of origin: picking it up resets the trunk and leaves the submodule's working tree alone — the edit is still there after 'complete' (release-candidate red team 2, finding 1)" {
  lib_origin
  git -C "$T" checkout -q main; git -C "$T" merge -q --ff-only refs/remotes/origin/main; lib_init
  printf 'A\n' > "$T/ahead.txt"; git -C "$T" add ahead.txt; cmt "$T" -m "ahead on main"
  mk_moves
  git -C "$T" config submodule.recurse true
  printf 'LIB UNCOMMITTED EDIT\n' > "$L/lib.txt"; printf 'u\n' > "$L/libu.txt"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no --ignore-submodules=dirty)" ]
  pull_current
  s1_ctx
  case "$c" in *"the branch main (1 commit not on origin)"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$L/lib.txt")" = "LIB UNCOMMITTED EDIT" ] || { echo "the edit in lib is gone: $(cat "$L/lib.txt")"; return 1; }
  [ "$(cat "$L/libu.txt")" = u ]
  [ "$(git -C "$T" rev-parse refs/heads/main)" = "$(git -C "$T" rev-parse refs/remotes/origin/main)" ]
}

@test "v0.6.1, pulled, with submodule.recurse set, on a branch whose commit moves the submodule, with an uncommitted edit in it: picking it up checks out main and leaves the submodule's working tree alone — the edit is still there after 'complete' (release-candidate red team 2, finding 1)" {
  lib_origin
  git -C "$T" checkout -q main; git -C "$T" merge -q --ff-only refs/remotes/origin/main; git -C "$T" branch -D -q fix/in-flight
  lib_init; git -C "$T" checkout -q -b fix/in-flight
  printf 'lib2\n' > "$L/lib2.txt"; git -C "$L" add lib2.txt; cmt "$L" -m "lib 2"; git -C "$L" push -q origin HEAD:main
  git -C "$T" add lib; cmt "$T" -m "bump lib"
  mk_moves
  git -C "$T" config submodule.recurse true
  printf 'LIB UNCOMMITTED EDIT\n' > "$L/lib.txt"; sum="$(shasum "$L/lib.txt")"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no --ignore-submodules=dirty)" ]
  pull_current
  s1_ctx
  case "$c" in *"the branch fix/in-flight (1 commit not on origin)"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(shasum "$L/lib.txt")" = "$sum" ] || { echo "the edit in lib is gone: $(cat "$L/lib.txt")"; return 1; }
  [ "$(git -C "$T" branch --show-current)" = main ]
}

@test "v0.6.1, pulled, with fetch.prune and fetch.pruneTags set and a tags refspec configured, and tags that are the only refs to a commit: the upgrade's fetch deletes no tag — on a run that stops on an untracked file, on the run that completes, and in lease.sh adopt (release-candidate red team 2, finding 2)" {
  git -C "$T" checkout -q --detach main
  printf 'exp\n' > "$T/exp.txt"; git -C "$T" add exp.txt; cmt "$T" -m "tagged experiment"; exp="$(git -C "$T" rev-parse HEAD)"
  git -C "$T" -c user.email=t@x -c user.name=t tag -a -m keep exp/keep; git -C "$T" tag exp/light
  git -C "$T" checkout -q fix/in-flight; ship_in_flight
  git -C "$T" config fetch.prune true; git -C "$T" config fetch.pruneTags true
  git -C "$T" config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'
  git clone -q "$B/v061/thing.git" "$B/mk"; mk_moves
  printf 'MINE\n' > "$T/moved.txt"
  tags() { git -C "$T" tag -l | tr '\n' ' '; }
  pull_current
  s1_ctx
  case "$c" in *"Daedalus has unfinished work in target/thing: 1 unsaved file. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(tags)" = "exp/keep exp/light " ] || { echo "tags after the stopped run: [$(tags)]"; return 1; }
  rm "$T/moved.txt"
  run --separate-stderr start_session s2
  c="$(ctx_of "$output")" || { echo "$output $stderr"; return 1; }
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(tags)" = "exp/keep exp/light " ] || { echo "tags after the run that completed: [$(tags)]"; return 1; }
  [ "$(git -C "$T" rev-parse exp/light)" = "$exp" ]
  git -C "$T" branch side main; git -C "$T" checkout -q side
  printf 's\n' > "$T/side.txt"; git -C "$T" add side.txt; cmt "$T" -m "side work"; git -C "$T" checkout -q main
  run bash "$H/core/lease.sh" adopt side
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(tags)" = "exp/keep exp/light " ] || { echo "tags after lease.sh adopt: [$(tags)]"; return 1; }
}

@test "v0.6.1, pulled, on the in-flight branch: 'pick it up' cut off after it made the window, before the checkout back to main, then a commit more on the branch — the next start names the branch again, never 'complete'; 'pick it up' names the commit the window lacks and how to rename the branch; renamed as printed, it becomes a window and the next start completes (release-candidate red team 2, finding 3)" {
  pull_current
  s1_ctx
  real="$(command -v git)"; mkdir -p "$B/shim"
  cat > "$B/shim/git" <<SH
#!/bin/bash
case " \$* " in *" -C $T checkout --quiet main "*)
  if [ ! -e "$B/killed" ]; then
    : > "$B/killed"; pid=\$PPID
    while [ -n "\$pid" ] && [ "\$pid" -gt 1 ]; do
      case "\$(ps -o command= -p "\$pid")" in *python*) kill -9 "\$pid"; break ;; esac
      pid="\$(ps -o ppid= -p "\$pid" | tr -d ' ')"
    done
    exit 137
  fi ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$B/shim/git"
  PATH="$B/shim:$PATH" pick_it_up
  [ -e "$B/killed" ] || { echo "pick it up was never cut off: $output"; return 1; }
  nn="$(win_of fix/in-flight)"; [ -n "$nn" ]
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  first="$(git -C "$T" rev-parse "refs/heads/lease/$nn")"
  printf 'more\n' > "$T/more.txt"; git -C "$T" add more.txt; cmt "$T" -m "more work after the cut-off start"
  more="$(git -C "$T" rev-parse HEAD)"
  run --separate-stderr start_session s2
  c="$(ctx_of "$output")" || { echo "$output $stderr"; return 1; }
  case "$c" in *"Upgrade to $CUR: complete."*) echo "$c"; return 1 ;; esac
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (2 commits not on origin)."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; [ "$(git -C "$T" rev-parse "refs/heads/lease/$nn")" = "$first" ]
  pick_it_up
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  case "$output" in *"fix/in-flight in target/thing has 1 commit that window $nn"*"(git -C target/thing branch -m fix/in-flight fix/in-flight-2)"*"nothing was adopted"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"already window $nn"*) echo "$output"; return 1 ;; esac
  (cd "$H" && git -C target/thing branch -m fix/in-flight fix/in-flight-2)
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run --separate-stderr start_session s3
  c="$(ctx_of "$output")" || { echo "$output $stderr"; return 1; }
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ -n "$(git -C "$T" for-each-ref --contains "$more" refs/heads/lease/)" ]
}

@test "v0.6.1, pulled, on a branch with a hidden CRLF edit (status clean) in c.txt, sorted after files an eol=crlf rule, added after they were checked out, would change the size of: the upgrade stops naming c.txt — never 'complete' over it — and c.txt's bytes stay (release-candidate red team 2, finding 4)" {
  printf 'x\n' > "$T/a.txt"; printf 'hello\nworld\n' > "$T/b.txt"; printf 'hello\nworld' > "$T/c.txt"
  printf 'c.txt text eol=lf\n' > "$T/.gitattributes"; git -C "$T" add -A; cmt "$T" -m "notes"
  printf 'a.txt text eol=crlf\nb.txt text eol=crlf\nc.txt text eol=lf\n' > "$T/.gitattributes"
  git -C "$T" add .gitattributes; cmt "$T" -m "windows files"
  printf 'hello\r\nworld' > "$T/c.txt"; cp "$T/c.txt" "$B/c-crlf"; git -C "$T" add c.txt 2>/dev/null
  [ -z "$(git -C "$T" status --porcelain)" ]
  pull_current
  s1_ctx
  case "$c" in *"Upgrade to $CUR: complete."*) echo "$c"; return 1 ;; esac
  case "$c" in *"1 changed file git status does not show (c.txt). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  cmp "$T/c.txt" "$B/c-crlf"; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
}

@test "v0.6.1, pulled, on a branch with a hidden CRLF edit in c.txt beside an untouched a.dat whose smudge filter changes its size: the stop names c.txt alone (release-candidate red team 2, finding 4)" {
  git -C "$T" config filter.grow.clean "sed 's/ grown\$//'"; git -C "$T" config filter.grow.smudge "sed 's/\$/ grown/'"
  printf 'a.dat filter=grow\nc.txt text eol=lf\n' > "$T/.gitattributes"
  printf 'one\ntwo\n' > "$T/a.dat"; printf 'hello\nworld\n' > "$T/c.txt"; git -C "$T" add -A; cmt "$T" -m "data"
  rm "$T/a.dat"; git -C "$T" checkout -- a.dat; [ "$(head -1 "$T/a.dat")" = "one grown" ]
  printf 'hello\r\nworld\r\n' > "$T/c.txt"; git -C "$T" add c.txt 2>/dev/null
  [ -z "$(git -C "$T" status --porcelain)" ]
  pull_current
  s1_ctx
  case "$c" in *"1 changed file git status does not show (c.txt). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "v0.6.1, pulled, with an untouched checkout of a file under '*.bat text eol=crlf' (status clean, the bytes a checkout writes): the upgrade completes (release-candidate red team 2, finding 5)" {
  ship_in_flight
  git clone -q "$B/v061/thing.git" "$B/mk"
  printf '*.bat text eol=crlf\n' > "$B/mk/.gitattributes"; printf '@echo off\necho hi\n' > "$B/mk/run.bat"
  git -C "$B/mk" add -A; cmt "$B/mk" -m "windows script"; git -C "$B/mk" push -q origin main
  git -C "$T" fetch -q origin; git -C "$T" merge -q --no-edit refs/remotes/origin/main 2>/dev/null
  [ -z "$(git -C "$T" status --porcelain)" ]; grep -q $'\r' "$T/run.bat"
  pull_current
  s1_ctx
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"git status does not show"*) echo "$c"; return 1 ;; esac
}

@test "v0.6.1, pulled, with core.trustctime false and an untouched file committed with CRLF before '* text=auto' (status clean): the upgrade completes, and lease.sh adopt does not refuse it (release-candidate red team 2, finding 6)" {
  ship_in_flight
  git clone -q "$B/v061/thing.git" "$B/mk"
  printf '@echo off\r\necho hi\r\n' > "$B/mk/run.bat"; git -C "$B/mk" add run.bat; cmt "$B/mk" -m "windows script"
  printf '* text=auto\n' > "$B/mk/.gitattributes"; git -C "$B/mk" add .gitattributes; cmt "$B/mk" -m "normalize from now on"
  git -C "$B/mk" push -q origin main
  git -C "$T" fetch -q origin; git -C "$T" merge -q --no-edit refs/remotes/origin/main 2>/dev/null
  git -C "$T" config core.trustctime false
  [ -z "$(git -C "$T" status --porcelain)" ]
  pull_current
  s1_ctx
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"git status does not show"*) echo "$c"; return 1 ;; esac
  git -C "$T" branch side2 refs/heads/main; git -C "$T" checkout -q side2
  printf 's2\n' > "$T/side2.txt"; git -C "$T" add side2.txt; cmt "$T" -m "side 2"; git -C "$T" checkout -q main
  run bash "$H/core/lease.sh" adopt side2
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v0.6.1, pulled, with a filter driver shaped like Git LFS — required, run as a long-running process (one asset never pulled, one pulled) — and its server unreachable: the check runs no smudge program and the upgrade completes (release-candidate red team 2, finding 7)" {
  mkdir -p "$B/lfs-server"
  cat > "$B/smudge.sh" <<'SH'
#!/bin/sh
in=$(cat); id=$(printf '%s' "$in" | sed -n 's/^pointer //p')
c="$(git rev-parse --git-common-dir)/lfs-cache"; mkdir -p "$c"
echo "smudge $id by: ${PARENT_CMD:-$(ps -o command= -p $PPID)}" >> "$LFSLOG"
[ "${FAKE_SKIP:-}" = 1 ] && { printf '%s\n' "$in"; exit 0; }
[ -f "$c/$id" ] && { cat "$c/$id"; exit 0; }
[ -f "$LFSSERVER/$id" ] && { cp "$LFSSERVER/$id" "$c/$id"; echo "download $id" >> "$LFSLOG"; cat "$c/$id"; exit 0; }
exit 1
SH
  cat > "$B/clean.sh" <<'SH'
#!/bin/sh
t=$(mktemp); cat > "$t"
if head -c 8 "$t" | grep -q '^pointer '; then cat "$t"; exit 0; fi
id=$(shasum "$t" | cut -c1-12); c="$(git rev-parse --git-common-dir)/lfs-cache"; mkdir -p "$c"
cp "$t" "$c/$id"; cp "$t" "$LFSSERVER/$id"; printf 'pointer %s\n' "$id"
SH
  # git-lfs install sets filter.lfs.process (git-lfs filter-process): git's long-running filter protocol, which this
  # speaks, running the two programs above for each file (their parent named as the git command that started it)
  cat > "$B/proc.py" <<'PY'
import os, subprocess, sys
i, o = sys.stdin.buffer, sys.stdout.buffer
def pkts():
    out = []
    while True:
        n = i.read(4)
        if not n:
            sys.exit(0)
        if int(n, 16) == 0:
            return out
        out.append(i.read(int(n, 16) - 4))
def put(*xs):
    for x in xs:
        for k in range(0, max(len(x), 1), 65516):
            o.write(b"%04x" % (len(x[k:k + 65516]) + 4) + x[k:k + 65516])
    o.write(b"0000"); o.flush()
pkts(); put(b"git-filter-server\n", b"version=2\n")
pkts(); put(b"capability=clean\n", b"capability=smudge\n")
parent = subprocess.run(["ps", "-o", "command=", "-p", str(os.getppid())], capture_output=True, text=True).stdout.strip()
while True:
    head = dict(x.decode().strip().split("=", 1) for x in pkts())
    data = b"".join(pkts())
    prog = os.environ["SMUDGE_SH"] if head["command"] == "smudge" else os.environ["CLEAN_SH"]
    r = subprocess.run([prog], input=data, capture_output=True, env=dict(os.environ, PARENT_CMD=parent))
    if r.returncode != 0:
        put(b"status=error\n")
        continue
    put(b"status=success\n"); put(*([r.stdout] if r.stdout else [])); put()
PY
  chmod +x "$B/smudge.sh" "$B/clean.sh"
  export LFSLOG="$B/lfs.log" LFSSERVER="$B/lfs-server" SMUDGE_SH="$B/smudge.sh" CLEAN_SH="$B/clean.sh"
  git clone -q "$B/v061/thing.git" "$B/mk"
  for r in "$B/mk" "$T"; do
    git -C "$r" config filter.asset.clean "$B/clean.sh"; git -C "$r" config filter.asset.smudge "$B/smudge.sh"
    git -C "$r" config filter.asset.required true; git -C "$r" config filter.asset.process "python3 $B/proc.py"
  done
  printf '*.bin filter=asset\n' > "$B/mk/.gitattributes"; printf 'ASSET A\n' > "$B/mk/a.bin"; printf 'ASSET B\n' > "$B/mk/b.bin"
  git -C "$B/mk" add -A; cmt "$B/mk" -m "assets"; git -C "$B/mk" push -q origin main
  rm -rf "$B/mk/.git/lfs-cache"
  git -C "$T" checkout -q main; git -C "$T" branch -D -q fix/in-flight
  git -C "$T" fetch -q origin; FAKE_SKIP=1 git -C "$T" merge -q --ff-only refs/remotes/origin/main
  rm "$T/b.bin"; git -C "$T" checkout -- b.bin
  [ "$(cat "$T/b.bin")" = "ASSET B" ]; [ "$(cut -c1-8 "$T/a.bin")" = "pointer " ]
  [ -z "$(git -C "$T" status --porcelain)" ]
  cache="$(ls "$T/.git/lfs-cache")"
  pull_current
  mv "$B/lfs-server" "$B/lfs-server.offline"; : > "$LFSLOG"
  s1_ctx
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  # the session's own window is a checkout, which smudges as any checkout does; the check never runs one
  ! grep -e cat-file -e checkout-index "$LFSLOG" || { echo "the check ran a smudge:"; cat "$LFSLOG"; return 1; }
  [ "$(ls "$T/.git/lfs-cache")" = "$cache" ]
}

# --- release-candidate red team 3 --------------------------------------------------------------------------------
tars_have() {       # tars_have <text> — some file in a tar of the safety copy holds <text>
  python3 - "$H/state/upgrade-snapshot" "$1" <<'PY'
import os, sys, tarfile
top, want = sys.argv[1], sys.argv[2].encode()
for dp, _, fs in os.walk(top):
    for f in fs:
        if f.endswith(".tar"):
            with tarfile.open(os.path.join(dp, f)) as t:
                for m in t.getmembers():
                    if m.isfile() and want in t.extractfile(m).read():
                        sys.exit(0)
sys.exit(1)
PY
}
bundles_have() {    # bundles_have <commit> — the safety copy's bundles hold <commit>
  local r="$B/bundles-$RANDOM" b; git init -q --bare "$r"
  for b in $(ls "$H"/state/upgrade-snapshot/*/*.bundle | sort); do
    git -C "$r" fetch -q "$b" "refs/*:refs/from/$(basename "$b")/*" 2>/dev/null || true
  done
  git -C "$r" cat-file -e "$1^{commit}"
}
not_complete() { case "$c" in *"Upgrade to $CUR: complete."*) echo "$c"; return 1 ;; esac; [ ! -e "$H/state/upgraded-to" ]; }

@test "v0.6.1, pulled, on a branch where thing.txt became a gitlink with no .gitmodules whose directory holds plain files and no .git (a submodule vendored by removing its .git): the upgrade stops on the branch before anything there moves, so the checkout back to main never deletes the directory — no stamp, the file stays; the safety copy holds it; lease.sh adopt refuses too (release-candidate red team 3, finding 1)" {
  git -C "$T" rm -q thing.txt
  git -C "$T" update-index --add --cacheinfo "160000,$(git -C "$T" rev-parse HEAD),thing.txt"; cmt "$T" -m "vendored"
  mkdir "$T/thing.txt"; printf 'MY WORK INSIDE THE GITLINK DIR\n' > "$T/thing.txt/notes.md"
  [ -z "$(git -C "$T" status --porcelain)" ]; [ ! -e "$T/.gitmodules" ]
  pull_current
  s1_ctx
  not_complete
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (2 commits not on origin). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$T/thing.txt/notes.md")" = "MY WORK INSIDE THE GITLINK DIR" ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  tars_have "MY WORK INSIDE THE GITLINK DIR"
  run bash "$H/core/lease.sh" adopt fix/in-flight          # no window opens while the upgrade is not stamped
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  case "$output" in *"no window opens until the upgrade to $CUR finishes, so \`core/lease.sh adopt\` is refused. Daedalus has unfinished work in target/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  # adopt's own refusal, in a home whose upgrade is stamped
  printf '%s\n' "$CUR" > "$H/state/upgraded-to"
  run bash "$H/core/lease.sh" adopt fix/in-flight
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  case "$output" in *"(thing.txt)"*"nothing was adopted"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/thing.txt/notes.md")" = "MY WORK INSIDE THE GITLINK DIR" ]
}

fsm_hook() { printf '#!/bin/sh\nprintf "tok\\0"\n' > "$B/fsm.sh"; chmod +x "$B/fsm.sh"; }
fsm_edit() {        # the hook trusted, then an edit of f.txt (the branch's committed file) it never reports
  git -C "$T" update-index --refresh >/dev/null 2>&1 || true; git -C "$T" status >/dev/null; sleep 1
  printf 'MY UNCOMMITTED EDIT\n' > "$T/f.txt"
  [ -z "$(git -C "$T" status --porcelain)" ]; [ -n "$(GIT_OPTIONAL_LOCKS=0 git -C "$T" -c core.fsmonitor=false status --porcelain)" ]
  [ -z "$(git -C "$T" status --porcelain)" ]
}
fsm_kept() {
  not_complete
  case "$c" in *"the branch fix/in-flight (1 commit not on origin), and 1 unsaved file. $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$T/f.txt")" = "MY UNCOMMITTED EDIT" ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  tars_have "MY UNCOMMITTED EDIT"
}

@test "v0.6.1, pulled, with core.fsmonitor in the repository's config naming a hook that reports no changes, and an uncommitted edit it hides from git status: the upgrade stops on the edit — never 'complete' over it — the edit stays and the safety copy holds it (release-candidate red team 3, finding 2)" {
  fsm_hook; git -C "$T" config core.fsmonitor "$B/fsm.sh"
  fsm_edit
  pull_current
  s1_ctx
  fsm_kept
}

@test "v0.6.1, pulled, with core.fsmonitor set only in the global config (GIT_CONFIG_GLOBAL) to a hook that reports no changes, and an uncommitted edit it hides: the upgrade stops on the edit, which stays and is in the safety copy (release-candidate red team 3, finding 2)" {
  pull_current
  fsm_hook
  printf '[user]\n\tname = t\n\temail = t@x\n[core]\n\tfsmonitor = %s\n' "$B/fsm.sh" > "$B/global.gitconfig"
  export GIT_CONFIG_GLOBAL="$B/global.gitconfig"
  fsm_edit
  s1_ctx
  fsm_kept
}

@test "v0.6.1, pulled, on a branch where thing.txt is a repository of its own recorded as a gitlink (no .gitmodules), with a commit and an untracked file nowhere else, and main has a file there: the upgrade stops on the branch — no stamp, the repository with its .git, commit and files intact (release-candidate red team 3, finding 3)" {
  git -C "$T" rm -q thing.txt
  git init -q -b main "$T/thing.txt"; printf 'NESTED COMMITTED WORK\n' > "$T/thing.txt/lib.md"
  git -C "$T/thing.txt" add lib.md; cmt "$T/thing.txt" -m "nested-only commit"
  printf 'NESTED UNTRACKED WORK\n' > "$T/thing.txt/scratch.md"
  git -C "$T" add thing.txt 2>/dev/null; cmt "$T" -m "embed"
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no --ignore-submodules=dirty)" ]
  pull_current
  s1_ctx
  not_complete
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (2 commits not on origin). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  [ -d "$T/thing.txt/.git" ]; [ "$(git -C "$T/thing.txt" log --format=%s)" = "nested-only commit" ]
  [ "$(cat "$T/thing.txt/scratch.md")" = "NESTED UNTRACKED WORK" ]
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
}

@test "v0.6.1, pulled, with a parked branch whose reflog's older entry (45 days) holds a commit no ref has: adopting the branch deletes its reflog, so the safety copy holds that commit whatever its age, and --restore-help names it (release-candidate red team 3, finding 5)" {
  d45="@$(( $(date +%s) - 45*86400 )) +0000"; d40="@$(( $(date +%s) - 40*86400 )) +0000"
  GIT_COMMITTER_DATE="$d45" git -C "$T" worktree add -q -b feat/r "$B/wt-r" main
  printf 'A\n' > "$B/wt-r/old.txt"; git -C "$B/wt-r" add old.txt
  GIT_COMMITTER_DATE="$d45" GIT_AUTHOR_DATE="$d45" cmt "$B/wt-r" -m "old experiment"
  A="$(git -C "$B/wt-r" rev-parse HEAD)"; git -C "$T" worktree remove --force "$B/wt-r"
  git -C "$T" worktree add -q --detach "$B/wt-b" main
  printf 'B\n' > "$B/wt-b/b.txt"; git -C "$B/wt-b" add b.txt; cmt "$B/wt-b" -m "the real work"
  Bc="$(git -C "$B/wt-b" rev-parse HEAD)"; git -C "$T" worktree remove --force "$B/wt-b"
  GIT_COMMITTER_DATE="$d40" git -C "$T" branch -f feat/r "$Bc"
  [ "$(git -C "$T" rev-parse 'feat/r@{1}')" = "$A" ]
  pull_current
  s1_ctx
  case "$c" in *"the branch feat/r (1 commit not on origin)"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  case "$(ctx_of "$output")" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  bundles_have "$A" || { echo "the copy lacks the old reflog commit"; return 1; }
  run python3 "$H/core/upgrade.py" --restore-help
  case "$output" in *"${A:0:7}"*"old experiment"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, with a notebook filter git marks required (nbstripout's install: filter.<d>.required true, smudge cat) and outputs staged that its clean side strips (git status clean): the upgrade stops naming the notebook — the outputs stay and the safety copy holds them (release-candidate red team 3, finding 6)" {
  git -C "$T" config filter.nbs.clean "sed '/^OUTPUT/d'"; git -C "$T" config filter.nbs.smudge cat
  git -C "$T" config filter.nbs.required true
  printf '*.ipynb filter=nbs\n' > "$T/.gitattributes"; printf 'cell 1\ncell 2\n' > "$T/nb.ipynb"
  git -C "$T" add -A; cmt "$T" -m "notebook"
  printf 'cell 1\nOUTPUT-SECRET result 42\ncell 2\n' > "$T/nb.ipynb"; git -C "$T" add nb.ipynb
  [ -z "$(git -C "$T" status --porcelain)" ]
  pull_current
  s1_ctx
  not_complete
  case "$c" in *"1 changed file git status does not show (nb.ipynb). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  grep -q OUTPUT-SECRET "$T/nb.ipynb"
  tars_have "OUTPUT-SECRET"
}

@test "v0.6.1, pulled, on a branch with '*.c ident' and a.c edited and committed after an earlier checkout expanded \$Id\$ (the only difference on disk a stale \$Id: <sha> \$): no hidden-change stop — picked up, the upgrade completes; lease.sh adopt of such a branch does not refuse (release-candidate red team 3, finding 8)" {
  printf '*.c ident\n' > "$T/.gitattributes"; printf '/* $Id$ */\nint a;\n' > "$T/a.c"
  git -C "$T" add -A; cmt "$T" -m "a.c"
  rm "$T/a.c"; git -C "$T" checkout -- a.c; grep -q '[$]Id: [0-9a-f]* [$]' "$T/a.c"
  sed -i '' 's/int a;/int b;/' "$T/a.c"; git -C "$T" add a.c; cmt "$T" -m "edit a.c"
  [ -z "$(git -C "$T" status --porcelain)" ]
  git -C "$T" branch side; git -C "$T" checkout -q side; printf 's\n' > "$T/side.txt"; git -C "$T" add side.txt
  cmt "$T" -m "side work"; git -C "$T" checkout -q fix/in-flight
  pull_current
  s1_ctx
  case "$c" in *"git status does not show"*) echo "$c"; return 1 ;; esac
  case "$c" in *"Daedalus has unfinished work in target/thing: the branch fix/in-flight (3 commits not on origin), and the branch side (4 commits not on origin). $TAIL"*) : ;; *) echo "$c"; return 1 ;; esac
  pick_it_up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to $CUR: complete."*) : ;; *) echo "$c"; return 1 ;; esac
}
