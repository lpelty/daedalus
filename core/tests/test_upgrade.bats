#!/usr/bin/env bats
# core/upgrade.py (spec §14): the steps a pull of a new release needs, run by themselves at the next session
# start. Every step idempotent; the stamp last; a dirty target checkout the one stop a person resolves.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() { upgrade_fixture; }
teardown() { teardown_live; }

@test "every step acts once, says one line each, and a second run changes nothing: dirs, hooks, dedup, hot.md, memory, the stamp last" {
  v061_state
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for s in "Upgrade to 0.7.0: created state/leases/, worktrees/, state/promote/, state/direct-calls/." \
           "Upgrade to 0.7.0: installed the pre-push hook in target/thing, target/thing/sub." \
           "Upgrade to 0.7.0: removed the old shared state/pitfall-seen.json and state/code-context-seen.json (each session keeps its own now)." \
           "Upgrade to 0.7.0: renamed vault/hot.md's session: line to leases: (left uncommitted for the prime's next vault commit)." \
           "Upgrade to 0.7.0: moved capture's settings from the hook line in .claude/settings.local.json into config.yaml's memory: block (bank bank-one; the key is in state/hindsight/api-key, mode 600)." \
           "Upgrade to 0.7.0: complete."; do
    case "$output" in *"$s"*) : ;; *) echo "missing: $s"; echo "$output"; return 1 ;; esac
  done
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  [ "$(stat -f %Lp "$DAEDALUS_HOME/state/promote")" = 700 ]
  [ "$(stat -f %Lp "$DAEDALUS_HOME/state/direct-calls")" = 700 ]
  [ "$(sed -n 3p "$DAEDALUS_HOME/vault/hot.md")" = "leases: (see the board; prime's copy at its last write)" ]
  [ -n "$(git -C "$DAEDALUS_HOME/vault" status --porcelain hot.md)" ]      # left uncommitted for the prime
  [ ! -e "$DAEDALUS_HOME/state/pitfall-seen.json" ]
  run python3 "$DAEDALUS_HOME/core/prepush.py" status "$T" "$T/sub"
  [ "$(printf '%s\n' "$output" | cut -f2 | sort -u)" = installed ] || { echo "$output"; return 1; }
  before="$(snapshot)"
  run python3 "$UP"
  [ "$status" -eq 0 ]; [ "$output" = "Already upgraded to 0.7.0; nothing to do." ] || { echo "$output"; return 1; }
  # and with the stamp gone every step is a no-op: only the completion line is said
  rm "$DAEDALUS_HOME/state/upgraded-to"
  run python3 "$UP"
  [ "$status" -eq 0 ]; [ "$output" = "Upgrade to 0.7.0: complete. What changed is in CHANGELOG.md under v0.7.0; what the target's agent may ask of you is in docs/handoff-reverse-caller.md." ] || { echo "$output"; return 1; }
  [ "$(snapshot)" = "$before" ] || { echo "a second run changed something"; return 1; }
}

@test "memory: the block is derived from the hook line — bank, api_url, transcript_dir, labels, the key file 0600 — and capture-tick's dry run resolves it with no TENANT_* in the environment" {
  v061_state
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  sed -n '/^memory:/,$p' "$DAEDALUS_HOME/config.yaml" > "$BATS_TEST_TMPDIR/block"
  grep -qx "  bank: 'bank-one'" "$BATS_TEST_TMPDIR/block"
  grep -qx "  transcript_dir: '$BATS_TEST_TMPDIR/tx'" "$BATS_TEST_TMPDIR/block"
  grep -qx "  user_label: 'OPERATOR'" "$BATS_TEST_TMPDIR/block"
  grep -qx "  api_key_file: state/hindsight/api-key" "$BATS_TEST_TMPDIR/block"
  ! grep -q 'k-123' "$DAEDALUS_HOME/config.yaml"
  [ "$(cat "$DAEDALUS_HOME/state/hindsight/api-key")" = k-123 ]
  [ "$(stat -f %Lp "$DAEDALUS_HOME/state/hindsight/api-key")" = 600 ]
  grep -q 'TENANT_BANK=bank-one' "$DAEDALUS_HOME/.claude/settings.local.json"     # the old line is left in place
  run env -u TENANT_BANK -u TENANT_HOME -u TRANSCRIPT_DIR -u HINDSIGHT_API_TENANT_API_KEY bash "$DAEDALUS_HOME/core/capture-tick.sh" --dry-run </dev/null
  case "$output" in *"bank bank-one"*"transcript directory $BATS_TEST_TMPDIR/tx"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "memory: a key read by \$(cat <file>) on the hook line is taken from that file" {
  v061_state
  printf 'k-from-file\n' > "$BATS_TEST_TMPDIR/keyfile"
  sed -i '' "s|HINDSIGHT_API_TENANT_API_KEY=k-123 TENANT_HOME|HINDSIGHT_API_TENANT_API_KEY=\\\\\"\$(cat $BATS_TEST_TMPDIR/keyfile)\\\\\" TENANT_HOME|" "$DAEDALUS_HOME/.claude/settings.local.json"
  grep -q 'cat ' "$DAEDALUS_HOME/.claude/settings.local.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$DAEDALUS_HOME/.claude/settings.local.json"   # still JSON
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/hindsight/api-key")" = k-from-file ]
  [ "$(stat -f %Lp "$DAEDALUS_HOME/state/hindsight/api-key")" = 600 ]
}

@test "memory: a value the shell computes any other way moves nothing — config.yaml untouched, no key file — and the line says which value" {
  v061_state
  sed -i '' 's|TENANT_BANK=bank-one TENANT_USER|TENANT_BANK=$(whoami) TENANT_USER|' "$DAEDALUS_HOME/.claude/settings.local.json"
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/config.before"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"capture's settings were not moved into config.yaml — TENANT_BANK on the old hook line is computed by the shell, not written out; capture keeps running from that line."*) : ;; *) echo "$output"; return 1 ;; esac
  cmp -s "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/config.before"
  [ ! -e "$DAEDALUS_HOME/state/hindsight/api-key" ]
}

@test "the upgrade fetches before it judges: a branch merged on origin since the last fetch is not adopted — target/thing goes back on main and the branch is left as it was" {
  git -C "$T" checkout -q -b fix/y; printf 'y\n' > "$T/y.txt"; git -C "$T" add -A; cmt "$T" -m "the fix"
  git -C "$T" push -q origin fix/y
  # merged on origin by hand, elsewhere; target/thing's origin/main is now stale (the stale-origin case)
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  git -C "$BATS_TEST_TMPDIR/hand" -c user.email=t@x -c user.name=t merge -q --no-ff origin/fix/y -m "Merge fix/y"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was on fix/y, whose work is already on origin/main; it is back on main and fix/y is left as it was."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T" rev-parse HEAD)" = "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse main)" ]
  git -C "$T" rev-parse -q --verify refs/heads/fix/y >/dev/null
}

@test "a dirty target checkout stops the upgrade before anything in target/ moves: the one plain sentence, no stamp, the stop recorded; the earlier steps have acted; clean, the next run finishes" {
  v061_state
  printf 'dirt\n' >> "$T/a.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  s="Daedalus has unfinished work in target/thing: 1 unsaved file. Nothing was changed. Say 'pick it up' to move it into windows, then start a new session."
  [ "$(printf '%s\n' "$output" | tail -1)" = "$s" ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["sentence"] == sys.argv[2] and d["version"] == "0.7.0" and d["step"] == 6, d' "$DAEDALUS_HOME/state/upgrade-stopped.json" "$s"
  [ -d "$DAEDALUS_HOME/state/leases" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     $s"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" checkout -q -- a.txt
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  grep -q '^memory:' "$DAEDALUS_HOME/config.yaml"
}

@test "--dry-run says what each step would do and changes nothing — no fetch, no lock file, no stamp; a would-be stop is said, not recorded" {
  v061_state
  git -C "$T" checkout -q -b fix/shipped; git -C "$T" push -q origin fix/shipped      # on a branch with nothing origin lacks
  before="$(snapshot)"; refs="$(git -C "$T" for-each-ref)"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for s in "would create state/leases/" "would install the pre-push hook in target/thing" "would remove the old shared state/pitfall-seen.json" \
           "would rename vault/hot.md's session: line" "would move capture's settings" "would put target/thing back on main (fix/shipped holds nothing that origin/main lacks)" \
           "(judged against origin/main as last fetched; the real run fetches first)" "would write state/upgraded-to last"; do
    case "$output" in *"$s"*) : ;; *) echo "missing: $s"; echo "$output"; return 1 ;; esac
  done
  [ "$(snapshot)" = "$before" ]; [ "$(git -C "$T" for-each-ref)" = "$refs" ]
  [ ! -e "$DAEDALUS_HOME/state/.upgrade.lock" ]; [ ! -d "$DAEDALUS_HOME/state/leases" ]
  printf 'dirt\n' >> "$T/a.txt"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ]
  case "$output" in *"would stop: Daedalus has unfinished work in target/thing: 1 unsaved file."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
}

@test "--setup runs the directories, the hook and the dedup only, and never stamps; with no VERSION the upgrade refuses in one sentence" {
  v061_state
  run python3 "$UP" --setup
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Setup: created state/leases/"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  [ "$(sed -n 3p "$DAEDALUS_HOME/vault/hot.md")" = "session: 011" ]
  ! grep -q '^memory:' "$DAEDALUS_HOME/config.yaml"
  rm "$DAEDALUS_HOME/VERSION"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$output" in *"this checkout has no VERSION file, so there is nothing to upgrade to"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "one upgrade at a time: while another process holds the upgrade lock, a run with a deadline waits no longer than it and records no stop" {
  mkdir -p "$DAEDALUS_HOME/state"
  python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(6)' "$DAEDALUS_HOME/state/.upgrade.lock" 3>&- &
  holder=$!; sleep 0.5
  start=$(date +%s)
  run python3 -c 'import sys,time; sys.path.insert(0, sys.argv[1]); import upgrade as u, pathlib
lines, stop = u.run(pathlib.Path(sys.argv[2]), deadline=time.time()+1); print(lines, stop)' "$DAEDALUS_HOME/core" "$DAEDALUS_HOME"
  [ "$(( $(date +%s) - start ))" -le 3 ]
  [ "$output" = "[] None" ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
}

@test "one upgrade at a time: a run that waited for the lock and finds the stamp the holder wrote does nothing — no step runs twice" {
  mkdir -p "$DAEDALUS_HOME/state"
  python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(1)
open(sys.argv[2], "w").write("0.7.0\n")' "$DAEDALUS_HOME/state/.upgrade.lock" "$DAEDALUS_HOME/state/upgraded-to" 3>&- &
  holder=$!; sleep 0.3
  run python3 -c 'import sys,time; sys.path.insert(0, sys.argv[1]); import upgrade as u, pathlib
lines, stop = u.run(pathlib.Path(sys.argv[2]), deadline=time.time()+5); print(lines, stop)' "$DAEDALUS_HOME/core" "$DAEDALUS_HOME"
  wait "$holder" 2>/dev/null || true
  [ "$output" = "[] None" ] || { echo "$output"; return 1; }
  [ ! -d "$DAEDALUS_HOME/state/leases" ]; [ ! -d "$DAEDALUS_HOME/worktrees" ]
}

# killed_run <python patch> — one upgrade run with <patch> applied to the loaded modules first (u = upgrade,
# ll = leaselib, os imported); the patch models a process killed part-way through (os._exit).
killed_run() {
  run python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import upgrade as u, leaselib as ll
exec(sys.argv[2]); sys.exit(u.main(["upgrade.py"]))' "$DAEDALUS_HOME/core" "$1"
}

@test "a stop that does not clear by itself says what to do when it comes back, and gives git's reason rather than its last line" {
  git -C "$T" checkout -q -b fix/shipped; git -C "$T" push -q origin fix/shipped
  killed_run 'll.git_finish = lambda *a, **kw: (1, "", "error: Your local changes would be overwritten by checkout:\n\ta.txt\nAborting\n")'
  [ "$status" -eq 1 ]
  case "$output" in *"upgrade to 0.7.0 incomplete: stopped while putting target/ back on its trunk — could not put target/thing back on main ("*"); it tries again at the next session start — if it stops the same way again, ask this home's agent to look into the reason given"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Aborting"*) echo "$output"; return 1 ;; esac
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import leaselib as ll
print(ll.git_reason("error: The following untracked working tree files would be overwritten by checkout:\n\ta.txt\n\tb/c.txt\nPlease move or remove them before you switch branches.\nAborting\n"))
print(ll.git_reason("fatal: not a git repository\n"))
print(ll.git_reason(""))' "$DAEDALUS_HOME/core"
  [ "${lines[0]}" = "untracked files would be overwritten: a.txt, b/c.txt" ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "not a git repository" ]; [ "${lines[2]}" = "no output" ]
}

@test "no remedy says 'stash them'; a stash in a target checkout stops the upgrade, is named by doctor, and stays where it is (critic finding 4)" {
  R="$BATS_TEST_DIRNAME/../.."
  for f in core/upgrade.py core/leaselib.py README.md CLAUDE.md CHANGELOG.md docs/handoff-reverse-caller.md; do
    ! tr '\n' ' ' < "$R/$f" | tr -s ' ' | grep -qiE 'or stash(ed)? them|or stashed|commit or stash' || { echo "$f still offers a stash"; return 1; }
  done
  printf 'saved\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$output" in *"Daedalus has unfinished work in target/thing: 1 stash entry."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" stash list | wc -l | tr -d ' ')" = 1 ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing holds 1 stash entry (stash@{0}: WIP on main: "*") — saved work no window shows; apply it in a window's worktree (git -C worktrees/<NN>/thing stash apply) or drop it once it is not needed"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" stash drop -q
  run python3 "$UP" --doctor
  case "$output" in *"target/thing holds 1 stash entry"*) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a branch squash-merged on origin is not made a window — its change is already on origin/main, even once origin/main has changed the same lines since and its branch on origin was deleted; a branch deleted on origin unmerged is unfinished work (release-candidate review, finding 3; review of option 1, finding 2)" {
  git -C "$T" checkout -q -b feat/sq; printf '1\n' > "$T/sq.txt"; git -C "$T" add -A; cmt "$T" -m sq1
  printf '2\n' >> "$T/sq.txt"; git -C "$T" add -A; cmt "$T" -m sq2
  git -C "$T" push -q origin feat/sq
  git -C "$T" checkout -q -b feat/late main; printf 'one\n' > "$T/late.txt"; git -C "$T" add -A; cmt "$T" -m late1
  printf 'two\n' > "$T/late2.txt"; git -C "$T" add -A; cmt "$T" -m late2
  git -C "$T" push -q -u origin feat/late
  git -C "$T" checkout -q -b feat/gone main; printf 'g\n' > "$T/g.txt"; git -C "$T" add -A; cmt "$T" -m gone1
  git -C "$T" push -q -u origin feat/gone
  git -C "$T" checkout -q main
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  H="$BATS_TEST_TMPDIR/hand"
  git -C "$H" merge -q --squash origin/feat/sq; cmt "$H" -m "feat/sq (squashed)"
  git -C "$H" merge -q --squash origin/feat/late; cmt "$H" -m "feat/late (squashed)"
  printf 'changed later\n' > "$H/late.txt"; git -C "$H" add -A; cmt "$H" -m "a later change to late.txt"
  git -C "$H" push -q origin main
  git -C "$H" push -q origin --delete feat/late feat/gone
  git -C "$T" fetch -q --prune origin
  # merging feat/late into origin/main now conflicts: only the commit it was squashed into shows its change landed
  ! git -C "$T" merge-tree --write-tree refs/remotes/origin/main feat/late >/dev/null 2>&1
  run python3 "$UP" --doctor
  case "$output" in *"feat/sq"*|*"feat/late"*) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing has branch feat/gone, 1 commit past origin/main, in no window — the upgrade stops on it until it is picked up"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"Daedalus has unfinished work in target/thing: the branch feat/gone (1 commit not on origin). Nothing was changed."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"feat/sq"*|*"feat/late"*) echo "$output"; return 1 ;; esac
  git -C "$T" branch -D -q feat/gone
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 01"*|*"could not be fast-forwarded"*|*"feat/sq"*|*"feat/late"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  git -C "$T" rev-parse -q --verify refs/heads/feat/sq >/dev/null; git -C "$T" rev-parse -q --verify refs/heads/feat/late >/dev/null
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

# --- release-candidate review 2 -------------------------------------------------------------------------------

@test "a gitignored file where putting a checkout on an already-merged branch back on the trunk would write stops the upgrade before anything moves; lease.sh adopt refuses the same (review 2, finding 1)" {
  git -C "$T" checkout -q -b fix/in-flight
  git -C "$T" rm -q --cached a.txt; printf 'a.txt\n' >> "$T/.gitignore"; git -C "$T" add -A; cmt "$T" -m "stop tracking a.txt"
  git -C "$T" push -q origin fix/in-flight
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  git -C "$BATS_TEST_TMPDIR/hand" -c user.email=t@x -c user.name=t merge -q --no-ff origin/fix/in-flight -m "Merge fix/in-flight"
  printf 'a again\n' > "$BATS_TEST_TMPDIR/hand/a.txt"; git -C "$BATS_TEST_TMPDIR/hand" add -f a.txt; cmt "$BATS_TEST_TMPDIR/hand" -m "track a.txt again"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  printf 'OPERATOR LOCAL SETTINGS\n' > "$T/a.txt"
  [ -z "$(git -C "$T" status --porcelain)" ]          # git status shows nothing: it is ignored
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that putting it back on main would overwrite (a.txt) — move them out of that checkout, or commit them on its branch, then start a session again" ] || { echo "$output"; return 1; }
  [ "$(cat "$T/a.txt")" = "OPERATOR LOCAL SETTINGS" ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m "more work"
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt fix/in-flight      # no window opens while the upgrade is not stamped
  [ "$status" -ne 0 ]
  case "$output" in *"no window opens until the upgrade to 0.7.0 finishes, so \`core/lease.sh adopt\` is refused. upgrade to 0.7.0 incomplete: target/thing has untracked files"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"            # adopt's own refusal, in a home upgraded earlier
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt fix/in-flight
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has ignored files that putting it back on main at origin/main would overwrite (a.txt)"*"nothing was adopted"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/a.txt")" = "OPERATOR LOCAL SETTINGS" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
}

@test "a gitignored file where fast-forwarding the trunk would write stops the upgrade before anything moves — the file is kept, no stamp (review 2, findings 1-2)" {
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  mkdir -p "$BATS_TEST_TMPDIR/hand/build"; printf 'k\n' > "$BATS_TEST_TMPDIR/hand/build/keep.txt"
  git -C "$BATS_TEST_TMPDIR/hand" add -A; cmt "$BATS_TEST_TMPDIR/hand" -m "build/keep.txt"; git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  printf 'build/\n' >> "$T/.git/info/exclude"; mkdir -p "$T/build"; printf 'mine\n' > "$T/build/other.txt"
  run python3 "$UP" --dry-run
  case "$output" in *"would stop"*) echo "$output"; return 1 ;; esac
  git -C "$T" fetch -q origin
  printf 'MY BUILD KEEP\n' > "$T/build/keep.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that fast-forwarding main to origin/main would overwrite (build/keep.txt) — move them out of that checkout, or commit them on its branch, then start a session again" ] || { echo "$output"; return 1; }
  [ "$(cat "$T/build/keep.txt")" = "MY BUILD KEEP" ]; [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  [ "$(git -C "$T" rev-parse main)" != "$(git -C "$T" rev-parse origin/main)" ]
  mv "$T/build/keep.txt" "$BATS_TEST_TMPDIR/keep.txt"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
}

@test "a local branch named origin/main stops the upgrade before anything moves, and doctor names it; renamed and picked up, the upgrade finishes; a window is still cut from origin's main when such a branch comes back (review 2, finding 5)" {
  git -C "$T" checkout -q -b origin/main; printf 'o\n' > "$T/o.txt"; git -C "$T" add -A; cmt "$T" -m "on a branch named origin/main"
  git -C "$T" checkout -q main
  s="upgrade to 0.7.0 incomplete: target/thing has a local branch named origin/main, which git takes for origin's main — rename it (git -C target/thing branch -m origin/main <new name>), then start a session again"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "$s" ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse refs/remotes/origin/main)" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has a local branch named origin/main, which git takes for origin's main — rename it (git -C target/thing branch -m origin/main <new name>)"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished
  [ "$status" -eq 1 ]
  case "$output" in *"target/thing has a local branch named origin/main, which git takes for origin's main — rename it (git -C target/thing branch -m origin/main <new name>), then say 'pick it up' again."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" branch -m origin/main feat/o
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$output" in *"Daedalus has unfinished work in target/thing: the branch feat/o (1 commit not on origin)."*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds feat/o from target/thing (1 commit: \"on a branch named origin/main\")"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  # the branch comes back; a branch adopted by hand still becomes a window cut from origin's main in every repo
  git -C "$T" branch origin/main lease/01
  git -C "$T" checkout -q -b feat/y main; printf 'y\n' > "$T/y.txt"; git -C "$T" add -A; cmt "$T" -m "y work"; git -C "$T" checkout -q main
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt feat/y
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 02 now holds feat/y"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/worktrees/02/thing" branch --show-current)" = lease/02 ]
  [ "$(git -C "$DAEDALUS_HOME/worktrees/02/thing/sub" rev-parse HEAD)" = "$(git -C "$T/sub" rev-parse refs/remotes/origin/main)" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse refs/remotes/origin/main)" ]
}

@test "an uncommitted edit hidden from git status by skip-worktree or assume-unchanged stops the upgrade before anything moves, naming the file; doctor and lease.sh adopt name it with how to clear the mark; a marked file with no edit is no stop (review 2, finding 6)" {
  git -C "$T" checkout -q -b fix/in-flight; printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m "the waiting fix"
  printf 'MY UNCOMMITTED EDIT\n' > "$T/a.txt"; git -C "$T" update-index --skip-worktree a.txt
  git -C "$T/sub" update-index --assume-unchanged n.txt            # marked, unchanged: not work
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "Daedalus has unfinished work in target/thing: the branch fix/in-flight (1 commit not on origin), and 1 changed file git status does not show (a.txt). Nothing was changed. Say 'pick it up' to move it into windows, then start a new session." ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; [ "$(cat "$T/a.txt")" = "MY UNCOMMITTED EDIT" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has uncommitted changes git status does not show, in files marked skip-worktree (a.txt) — no window has them; clear the mark (git -C target/thing update-index --no-skip-worktree a.txt) and commit them on a branch"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/sub has uncommitted"*) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt fix/in-flight      # no window opens while the upgrade is not stamped
  [ "$status" -ne 0 ]
  case "$output" in *"no window opens until the upgrade to 0.7.0 finishes, so \`core/lease.sh adopt\` is refused. Daedalus has unfinished work in target/thing"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"            # adopt's own refusal, in a home upgraded earlier
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt fix/in-flight
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has uncommitted changes git status does not show, in files marked skip-worktree (a.txt)"*"nothing was adopted"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/state/upgraded-to"
  # assume-unchanged: the same stop
  git -C "$T" update-index --no-skip-worktree a.txt; git -C "$T" update-index --assume-unchanged a.txt
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$(printf '%s\n' "$output" | tail -1)" in *"1 changed file git status does not show (a.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished
  case "$output" in *"in files marked assume-unchanged (a.txt): clear the mark (git -C target/thing update-index --no-assume-unchanged a.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" update-index --no-assume-unchanged a.txt
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/a.txt")" = "MY UNCOMMITTED EDIT" ]
}

@test "a nested repo's picked-up window, swept: its unpromoted commits are named by doctor and the board, its untracked files by doctor, and its number is never silently held back (review 2, finding 7)" {
  git -C "$T/sub" checkout -q -b fix/nested; printf 'n2\n' > "$T/sub/n2.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "nested waiting fix"
  run python3 "$UP"; [ "$status" -eq 1 ]
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 01 now holds fix/nested from target/thing/sub"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'notes\n' > "$DAEDALUS_HOME/worktrees/01/thing/sub/notes-untracked.txt"
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/01.seen"
  run bash "$DAEDALUS_HOME/core/lease.sh" sweep
  case "$output" in *"removed the lease of window 01 (stale)"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines
  case "$output" in *"NOTE     leases: 01 swept with 1 unpromoted commit waiting"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     leases: worktrees/01/thing/sub holds uncommitted or untracked files of swept window 01 (notes-untracked.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"- 01 — swept, 1 unpromoted commit waiting (\"nested waiting fix\")"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a pick-up cut off between a window's lease file and the end of its worktrees: the next session start's upgrade makes the worktree, and the board does not call it stale (review 2, finding 13)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "the waiting fix"
  run python3 "$UP"; [ "$status" -eq 1 ]
  run python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import upgrade as u, leaselib as ll
ll.add_worktrees = lambda *a, **kw: os._exit(9)
sys.exit(u.pick_up(u.v.ROOT))' "$DAEDALUS_HOME/core"
  [ "$status" -eq 9 ]; [ "$(lease_json 01 worktree_ready)" = False ]; [ ! -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 01, adopted from target/thing, now has its worktree (worktrees/01/thing)."*"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 02"*) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 worktree_ready)" = None ]; [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" branch --show-current)" = lease/01 ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  ! git -C "$T" rev-parse -q --verify refs/heads/feat/x >/dev/null
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"STALE"*) echo "$output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "a session start that runs out of time finishing a picked-up window's worktree writes no stamp: it stops saying it runs again; the board shows the unfinished window's commits and how to finish it, doctor names it, and the next start finishes it (release-candidate red team, finding 1)" {
  git -C "$T" checkout -q -b park/y; printf 'y\n' > "$T/y.txt"; git -C "$T" add -A; cmt "$T" -m "parked work"
  git -C "$T" checkout -q main
  run python3 "$UP"; [ "$status" -eq 1 ]
  run python3 -c 'import os, sys; sys.path.insert(0, sys.argv[1]); import upgrade as u, leaselib as ll
ll.add_worktrees = lambda *a, **kw: False
sys.exit(u.pick_up(u.v.ROOT))' "$DAEDALUS_HOME/core"
  [ "$(lease_json 01 worktree_ready)" = False ]; [ ! -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *'- 01 — '*'last commit "parked work"'*'core/lease.sh claim 01'*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *'- 01 — '*'no commits yet'*) echo "$output"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines
  case "$output" in *"window 01 (adopted from park/y) has no worktree yet"*"core/lease.sh claim 01"*) : ;; *) echo "$output"; return 1 ;; esac
  # the start's time runs out making it, once
  killed_run 'o = ll.add_worktrees
def k(root, nn, *a, **kw):
    flag = os.path.join(os.environ["BATS_TEST_TMPDIR"], "slow-once")
    if not os.path.exists(flag):
        open(flag, "w").close()
        return False
    return o(root, nn, *a, **kw)
ll.add_worktrees = k
lines, stop = u.run(u.v.ROOT, deadline=__import__("time").time() + 60)
print("\n".join(lines)); print(stop); sys.exit(1)'
  case "$output" in *"upgrade to 0.7.0 incomplete: stopped while putting target/ back on its trunk — the session start ran out of time; it runs again at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"complete."*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 01, adopted from target/thing, now has its worktree (worktrees/01/thing)."*"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 02"*) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 worktree_ready)" = None ]; [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/y.txt")" = y ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  run python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines
  case "$output" in *"no worktree yet"*) echo "$output"; return 1 ;; esac
}

@test "the stamp is not written while a window adopted from target/ has no worktree: a run that finds one it cannot finish stops instead of saying complete (release-candidate red team, finding 1)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  run python3 "$UP"; [ "$status" -eq 1 ]
  # every worktree add fails, and the step's own finish is bypassed: only the stamp's check is left
  killed_run 'll.add_worktrees = lambda *a, **kw: False
u.pick_up(u.v.ROOT)
ll.finish_adopted = lambda *a, **kw: []
lines, stop = u.run(u.v.ROOT); print("\n".join(lines)); print(stop); sys.exit(1)'
  case "$output" in *"upgrade to 0.7.0 incomplete: stopped while finishing the windows picked up from target/ — window 01 (adopted from feat/x) has no worktree yet"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"complete."*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ "$(lease_json 01 worktree_ready)" = False ]
}


# A patch release bumps VERSION and adds no step (v0.7.1, v0.7.2): a home already upgraded to the release before it
# runs every step as a no-op at the next start, says only the completion line, and stamps the new VERSION.
@test "a patch release on an upgraded home: only the completion line, nothing touched, the stamp follows VERSION" {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  CUR="$(sed -n 1p "$REPO/VERSION")"
  [ "$CUR" != 0.7.0 ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  printf '%s\n' "$CUR" > "$DAEDALUS_HOME/VERSION"
  before="$(snapshot | grep -v 'state/upgraded-to')"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c .)" = 1 ] || { echo "the dry run would do more than stamp: $output"; return 1; }
  case "$output" in *"state/upgraded-to"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ]
  [ "$output" = "Upgrade to $CUR: complete. What changed is in CHANGELOG.md under v$CUR; what the target's agent may ask of you is in docs/handoff-reverse-caller.md." ] || { echo "$output"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = "$CUR" ]
  [ "$(snapshot | grep -v 'state/upgraded-to')" = "$before" ] || { echo "the patch upgrade changed something"; return 1; }
  run python3 "$UP"
  [ "$status" -eq 0 ]; [ "$output" = "Already upgraded to $CUR; nothing to do." ] || { echo "$output"; return 1; }
}
