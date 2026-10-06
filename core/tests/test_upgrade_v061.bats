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

@test "v0.6.1, built and started by its own code, then pulled: the open session's next prompt says the upgrade has not run and its Stop passes, with no traceback; the first new session upgrades the home with nobody's hands on it — every §14 predicate holds; the old session's Stop then gives only the release's config.yaml reason (do not restore it; start a new session) and the promotion backstop; the second session changes nothing" {
  pull_current
  # the session that pulled keeps running: its board leads with the pending line; nothing is created by reading
  run --separate-stderr prompt_s0
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ "$(ctx_of "$output" | head -1)" = "upgrade to 0.7.0 has not run yet — it runs at the next session start in this home" ] || { echo "$output"; return 1; }
  [ ! -d "$H/state/leases" ]
  run --separate-stderr stop_s0
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  [ -z "$output" ] || { echo "the pulling session's Stop was blocked before any upgrade: $output"; return 1; }
  # the first new session
  run start_session s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output")"
  case "$c" in *"Upgrade to 0.7.0: complete."*"You are window 02 and you hold the pen"*) : ;; *) echo "$c"; return 1 ;; esac
  # VERSION and the stamp
  [ "$(cat "$H/VERSION")" = 0.7.0 ]; [ "$(cat "$H/state/upgraded-to")" = 0.7.0 ]
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
  case "$output" in *"OK       version: 0.7.0"*"OK       upgrade: state/upgraded-to 0.7.0"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"MISSING  VERSION"*|*"MISSING  state/"*|*"MISSING  worktrees/"*|*"MISSING  pre-push hook"*) echo "$output"; return 1 ;; esac
  # the old session's Stop after the upgrade blocks (exit 2, reasons on stderr) with only the reasons the spec gives
  # a session left open through an upgrade: config.yaml changed under it (the memory: block; Decision 11 — the
  # sentence tells the operator to restart it), and the promotion backstop, which cannot tell an unnumbered
  # session's tree now that two sessions are live. Never a traceback. (Measured on a scratch build of Tasks 2-5,
  # 2026-09-29: exactly these two lines.)
  run --separate-stderr stop_s0
  case "$status" in 0|2) : ;; *) echo "status $status: $output $stderr"; return 1 ;; esac
  case "$stderr" in *Traceback*) echo "$stderr"; return 1 ;; esac
  # Since the critic's finding 7 the config.yaml reason names the upgrade as the one that changed it and says not to
  # restore it; it blocks once (test_boundary_hook.bats), and here the promotion backstop still blocks on its own.
  case "$stderr" in *"config.yaml changed under this session, by the upgrade to 0.7.0 — not by this session. Do not restore it"*"tell the operator to close it and start a new session."*) : ;; *) echo "$stderr"; return 1 ;; esac
  case "$stderr" in *"changed this session; restore it"*) echo "$stderr"; return 1 ;; esac
  [ -z "$(printf '%s\n' "$stderr" | grep -v -e '^$' -e '^config.yaml changed under this session, by the upgrade' -e '^Promotion check')" ] \
    || { echo "an unexpected Stop reason for the old session: $stderr"; return 1; }
  run --separate-stderr stop_s0
  case "$stderr" in *"changed this session; restore it"*) echo "$stderr"; return 1 ;; esac
  # the second session: nothing upgrades again
  before="$(cd "$H" && find config.yaml vault/hot.md state/hindsight state/upgraded-to -type f | sort | xargs shasum)"
  run start_session s2
  case "$output" in *"Upgrade to"*) echo "$output"; return 1 ;; esac
  [ "$(cd "$H" && find config.yaml vault/hot.md state/hindsight state/upgraded-to -type f | sort | xargs shasum)" = "$before" ]
}

@test "v0.6.1, pulled, with an uncommitted edit hidden from git status by skip-worktree on the in-flight checkout: the first new session stops the upgrade naming the file and how to clear the mark — no stamp, no window, the edit where it was; doctor names it (release-candidate review 2, finding 6)" {
  printf 'MY UNCOMMITTED EDIT\n' > "$T/thing.txt"; git -C "$T" update-index --skip-worktree thing.txt
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ]
  pull_current
  run start_session s1
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  c="$(ctx_of "$output")"
  case "$c" in *"upgrade to 0.7.0 incomplete: target/thing has uncommitted changes git status does not show, in files marked skip-worktree (thing.txt) — clear the mark (git -C target/thing update-index --no-skip-worktree thing.txt), commit them on their branch inside that checkout, then start a session again"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"Upgrade to 0.7.0: complete."*) echo "$c"; return 1 ;; esac
  [ ! -e "$H/state/upgraded-to" ]; ! grep -qs adopted_from "$H"/state/leases/*.json
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; [ "$(cat "$T/thing.txt")" = "MY UNCOMMITTED EDIT" ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"target/thing has uncommitted changes git status does not show, in files marked skip-worktree (thing.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
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

@test "v0.6.1 with target.dir .upgrade-carry, pulled, the checkout on a branch with untracked files: the first new session carries them whole into window 01's worktree — the carry's temporary directory is never the window's checkout (release-candidate review 3, finding 1)" {
  [ "$(basename "$T")" = .upgrade-carry ]
  printf 'MY NOTES\n' > "$T/notes.md"; mkdir -p "$T/draft"; printf 'A DRAFT\n' > "$T/draft/a.md"
  pull_current
  s1_ctx
  case "$c" in *"Its untracked files went with it into worktrees/01/.upgrade-carry: draft/a.md, notes.md."*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  W="$H/worktrees/01/.upgrade-carry"
  [ "$(git -C "$W" branch --show-current)" = lease/01 ]; [ "$(cat "$W/f.txt")" = f ]
  [ "$(cat "$W/notes.md")" = "MY NOTES" ]; [ "$(cat "$W/draft/a.md")" = "A DRAFT" ]
  [ ! -e "$T/notes.md" ]; [ ! -e "$T/draft" ]; [ ! -e "$H/state/upgrade-carry-tmp" ]
}

@test "v0.6.1, pulled, with worktrees made by hand on a volume not mounted at the first new session — one detached with a commit no branch has, one holding a staged change: both come back whole; the upgrade names the detached commit (release-candidate review 3, finding 2)" {
  git -C "$T" worktree add -q --detach "$B/vol/exp" main
  printf 'e\n' > "$B/vol/exp/e.txt"; git -C "$B/vol/exp" add -A; cmt "$B/vol/exp" -m "exp-only"
  sha="$(git -C "$B/vol/exp" rev-parse HEAD)"
  git -C "$T" worktree add -q -b exp/staged "$B/vol/st" main
  printf 'staged\n' > "$B/vol/st/s.txt"; git -C "$B/vol/st" add s.txt; printf 'on disk\n' > "$B/vol/st/s.txt"
  pull_current
  mv "$B/vol" "$B/vol-unmounted"
  s1_ctx
  case "$c" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing has a worktree made by hand at $B/vol/exp, a detached HEAD with 1 commit no branch has (\"exp-only\") — its directory is not there now"*) : ;; *) echo "$c"; return 1 ;; esac
  mv "$B/vol-unmounted" "$B/vol"
  [ "$(git -C "$B/vol/exp" rev-parse HEAD)" = "$sha" ] || { git -C "$B/vol/exp" status; return 1; }
  [ "$(git -C "$B/vol/st" show :s.txt)" = staged ]; [ "$(cat "$B/vol/st/s.txt")" = "on disk" ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $B/vol/exp, a detached HEAD with 1 commit no branch has (\"exp-only\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     target/thing has a worktree made by hand at $B/vol/st, on branch exp/staged, uncommitted or untracked files (s.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "v0.6.1, pulled, with a parked branch whose only unpushed content is in a merge commit: git cherry passes it over, the upgrade does not — it becomes a window holding that content (release-candidate review 3, finding 3)" {
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
  case "$c" in *"target/thing's branch spike/notes (1 commit not on origin/main: \"Merge origin/main into spike/notes (with my notes)\") is now window 02"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$H/worktrees/02/thing/notes.md")" = "MY UNPUSHED DESIGN NOTES" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/spike/notes >/dev/null
}

@test "v0.6.1, pulled, on a branch whose only unpushed commit is a merge carrying content: it becomes window 01, not 'already on origin/main'; a merge that adds nothing is still no work (release-candidate review 3, finding 3)" {
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
  case "$c" in *"target/thing was on fix/merge-notes (1 commit not on origin/main: \"Merge origin/main into fix/merge-notes (resolved; notes added)\"); that work is now window 01"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"whose work is already on origin/main"*|*"plain/merge"*) echo "$c"; return 1 ;; esac
  [ "$(cat "$H/worktrees/01/thing/notes.md")" = "MY UNPUSHED DESIGN NOTES" ]
  git -C "$T" rev-parse -q --verify refs/heads/plain/merge >/dev/null
}

@test "v0.6.1, pulled, with a branch named lease/00 holding a user branch's unpushed commit: neither hides — the work becomes a window, lease/00 is gone, and doctor names nothing left behind (release-candidate review 3, finding 4)" {
  git -C "$T" branch wip/report main
  git -C "$T" worktree add -q "$B/tmpwt" wip/report
  printf 'REPORT DRAFT\n' > "$B/tmpwt/report.md"; git -C "$B/tmpwt" add report.md; cmt "$B/tmpwt" -m "report draft"
  git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" branch lease/00 wip/report
  pull_current
  run python3 "$H/core/upgrade.py" --doctor
  case "$output" in *"branch lease/00, 1 commit past origin/main, in no window"*) : ;; *) echo "$output"; return 1 ;; esac
  s1_ctx
  case "$c" in *"target/thing's branch lease/00 (1 commit not on origin/main: \"report draft\") is now window 02"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(cat "$H/worktrees/02/thing/report.md")" = "REPORT DRAFT" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/lease/00 >/dev/null
  git -C "$T" merge-base --is-ancestor wip/report lease/02
}

@test "v0.6.1, pulled, with worktrees made by hand — one on a new branch with an uncommitted edit and an untracked file, one detached with a commit no branch has: the upgrade names each once and leaves them as they are; doctor names them (release-candidate review 3, finding 5)" {
  git -C "$T" worktree add -q -b exp/a "$B/hand-a" main
  printf 'edit\n' >> "$B/hand-a/thing.txt"; printf 'n\n' > "$B/hand-a/new.md"
  git -C "$T" worktree add -q --detach "$B/hand-b" main
  printf 'd\n' > "$B/hand-b/d.txt"; git -C "$B/hand-b" add -A; cmt "$B/hand-b" -m "detached work"
  pull_current
  s1_ctx
  case "$c" in *"target/thing has a worktree made by hand at $B/hand-a, on branch exp/a, uncommitted or untracked files (new.md, thing.txt) — no window has that work; the upgrade leaves it as it is"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing has a worktree made by hand at $B/hand-b, a detached HEAD with 1 commit no branch has (\"detached work\")"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
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
  pull_current
  mkdir -p "$H/state/leases"; : > "$H/state/leases/01.json"; : > "$H/state/leases/prime.json"
  s1_ctx
  case "$c" in *"Upgrade to 0.7.0: complete."*"You are window 02 and you hold the pen"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"could not be rendered"*|*"cannot be bound"*) echo "$c"; return 1 ;; esac
  [ "$(lease_json 01 adopted_from)" = fix/in-flight ]
  run bash "$H/core/lease.sh" sweep
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "v0.6.1, pulled, where an earlier start's worktree add for the in-flight branch was cut off — lease/01 at its tip, a record locked 'initializing' over a directory whose .git file was never written: the next start clears it and finishes window 01 (release-candidate review 3, finding 8)" {
  pull_current
  git -C "$T" branch lease/01 fix/in-flight
  mkdir -p "$H/worktrees/01"
  git -C "$T" worktree add -q --lock --reason initializing "$H/worktrees/01/thing" lease/01; : > "$H/worktrees/01/thing/.git"
  printf 'n\n' > "$T/notes.txt"
  s1_ctx
  case "$c" in *"target/thing was on fix/in-flight (1 commit not on origin/main: \"the waiting fix\"); that work is now window 01"*"worktrees/01/thing: notes.txt"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(git -C "$H/worktrees/01/thing" branch --show-current)" = lease/01 ]; [ "$(cat "$H/worktrees/01/thing/f.txt")" = f ]
  ! git -C "$T" rev-parse -q --verify refs/heads/fix/in-flight >/dev/null
}

@test "v0.6.1, pulled, where a git command was cut off part-way — the checkout on a branch that no longer exists, or lock files left: the upgrade stops naming the branch's commit or the files, never 'commit them'; put right, the next start finishes (release-candidate review 3, finding 9)" {
  sha="$(git -C "$T" rev-parse fix/in-flight)"
  git -C "$T" update-ref -d refs/heads/fix/in-flight
  pull_current
  s1_ctx
  case "$c" in *"upgrade to 0.7.0 incomplete: target/thing is on branch fix/in-flight, which does not exist — a git command was cut off part-way; the branch's last commit is ${sha:0:7} (from HEAD's reflog). Put the branch back with git -C target/thing branch fix/in-flight ${sha:0:7}"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"commit them"*|*"Upgrade to 0.7.0: complete."*) echo "$c"; return 1 ;; esac
  git -C "$T" branch fix/in-flight "${sha:0:7}"
  : > "$T/.git/packed-refs.lock"; : > "$T/.git/refs/heads/fix/in-flight.lock"
  touch -t 202001010000 "$T/.git/packed-refs.lock" "$T/.git/refs/heads/fix/in-flight.lock"
  run start_session s2
  c="$(ctx_of "$output")"
  case "$c" in *"upgrade to 0.7.0 incomplete: target/thing holds lock files a git command left when it was cut off (target/thing/.git/packed-refs.lock, target/thing/.git/refs/heads/fix/in-flight.lock) — if no git command is running there, remove them"*) : ;; *) echo "$c"; return 1 ;; esac
  rm "$T/.git/packed-refs.lock" "$T/.git/refs/heads/fix/in-flight.lock"
  # s1 and s2 are windows 01 and 02; a window branch's own lock file, left by a cut-off add, is cleared, not a stop
  : > "$T/.git/refs/heads/lease/03.lock"; touch -t 202001010000 "$T/.git/refs/heads/lease/03.lock"
  run start_session s3
  c="$(ctx_of "$output")"
  case "$c" in *"target/thing was on fix/in-flight (1 commit not on origin/main: \"the waiting fix\"); that work is now window 03"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse lease/03)" = "$sha" ]
}

@test "v0.6.1, pulled, with a worktree an earlier start's cut-off adoption left under worktrees/01 on the in-flight branch, no lease file: it is cleared and the branch is adopted — never named 'checked out in another worktree', never its number given to another window over it (release-candidate review 3, finding 10)" {
  git -C "$T" checkout -q -b feature/b main; printf 'b\n' > "$T/b.txt"; git -C "$T" add -A; cmt "$T" -m "b work"
  git -C "$T" checkout -q main
  pull_current
  mkdir -p "$H/worktrees/01"; git -C "$T" worktree add -q "$H/worktrees/01/thing" fix/in-flight
  s1_ctx
  case "$c" in *"checked out in another worktree"*) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing's branch fix/in-flight (1 commit not on origin/main: \"the waiting fix\") is now window"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"target/thing's branch feature/b (1 commit not on origin/main: \"b work\") is now window"*) : ;; *) echo "$c"; return 1 ;; esac
  for n in 01 02; do
    [ "$(git -C "$H/worktrees/$n/thing" branch --show-current)" = "lease/$n" ] || { git -C "$T" worktree list; return 1; }
  done
  [ "$(cat "$H/worktrees/$(python3 -c 'import json,sys,glob
for f in sorted(glob.glob(sys.argv[1] + "/state/leases/[0-9]*.json")):
    d = json.load(open(f))
    if d.get("adopted_from") == "fix/in-flight": print(d["lease"])' "$H")/thing/f.txt")" = f ]
  run bash "$H/core/doctor.sh"
  case "$output" in *"in no window"*) echo "$output"; return 1 ;; esac
}
