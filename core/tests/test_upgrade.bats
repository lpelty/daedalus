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

@test "adopt at the upgrade: target/thing on a branch with work past trunk becomes window 01 (no session), target/thing back on main at origin/main, the line says so" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: target/thing was on feat/x (1 commit not on origin/main: \"in flight\"); that work is now window 01 (branch lease/01), and target/thing is back on main. Promote it from the board (\"promote window 01\") or release it."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ "$(git -C "$T" rev-parse HEAD)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(lease_json 01 adopted_from)" = feat/x ]
  [ "$(lease_json 01 note)" = "adopted at the upgrade to 0.7.0" ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "adopt at the upgrade: a trunk ahead of origin — its commit moves to window 01 and main is reset to origin/main; a detached checkout with a commit not on trunk the same" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk"
  tip="$(git -C "$T" rev-parse HEAD)"
  git -C "$T/sub" checkout -q --detach; printf 'd\n' > "$T/sub/d.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "detached work"
  dtip="$(git -C "$T/sub" rev-parse HEAD)"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's main was 1 commit ahead of origin/main (\"committed on trunk\"); that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/sub was not on a branch (1 commit not on origin/main: \"detached work\"); that work is now window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
  [ "$(git -C "$T/sub" branch --show-current)" = main ]
  [ "$(git -C "$T/sub" rev-parse lease/02)" = "$dtip" ]
}

@test "adopt at the upgrade: on a branch AND the trunk ahead of origin — the branch is window 01, the trunk's own commit is window 02, main is back at origin/main with no ahead, and the stamp is written" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk"
  mtip="$(git -C "$T" rev-parse main)"
  git -C "$T" checkout -q -b feat/x origin/main; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was on feat/x (1 commit not on origin/main: \"in flight\"); that work is now window 01"*"target/thing's main was 1 commit ahead of origin/main (\"committed on trunk\"); that work is now window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T" rev-parse lease/02)" = "$mtip" ]
  case "$(git -C "$T" status -sb | head -1)" in *ahead*) echo "still ahead"; return 1 ;; esac
  case "$(lease_json 02 adopted_from)" in daedalus/upgrade-*) : ;; *) echo "adopted_from: $(lease_json 02 adopted_from)"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "adopt at the upgrade: a branch cut from a trunk that was ahead already carries the trunk's commits — one window, and main is only reset to origin/main" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01"*"target/thing's main was also 1 commit ahead of origin/main; window 01 carries those commits, so main is reset to origin/main."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T" log --format=%s lease/01 | head -2 | tr '\n' '|')" = "in flight|committed on trunk|" ]
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
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'dirt\n' >> "$T/a.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  s="upgrade to 0.7.0 incomplete: target/thing has uncommitted changes — commit them on their branch inside that checkout, or stash them, then start a session again"
  [ "$(printf '%s\n' "$output" | tail -1)" = "$s" ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["sentence"] == sys.argv[2] and d["version"] == "0.7.0" and d["step"] == 6, d' "$DAEDALUS_HOME/state/upgrade-stopped.json" "$s"
  [ -d "$DAEDALUS_HOME/state/leases" ]; grep -q '^memory:' "$DAEDALUS_HOME/config.yaml"
  [ "$(git -C "$T" branch --show-current)" = feat/x ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     $s"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" checkout -q -- a.txt
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "--dry-run says what each step would do and changes nothing — no fetch, no lock file, no stamp; a would-be stop is said, not recorded" {
  v061_state
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  before="$(snapshot)"; refs="$(git -C "$T" for-each-ref)"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for s in "would create state/leases/" "would install the pre-push hook in target/thing" "would remove the old shared state/pitfall-seen.json" \
           "would rename vault/hot.md's session: line" "would move capture's settings" "would move target/thing's feat/x (1 commit not on origin/main" \
           "(judged against origin/main as last fetched; the real run fetches first)" "would write state/upgraded-to last"; do
    case "$output" in *"$s"*) : ;; *) echo "missing: $s"; echo "$output"; return 1 ;; esac
  done
  [ "$(snapshot)" = "$before" ]; [ "$(git -C "$T" for-each-ref)" = "$refs" ]
  [ ! -e "$DAEDALUS_HOME/state/.upgrade.lock" ]; [ ! -d "$DAEDALUS_HOME/state/leases" ]
  printf 'dirt\n' >> "$T/a.txt"
  run python3 "$UP" --dry-run
  [ "$status" -eq 0 ]
  case "$output" in *"would stop: upgrade to 0.7.0 incomplete: target/thing has uncommitted changes"*) : ;; *) echo "$output"; return 1 ;; esac
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

@test "a run killed after the checked-out branch became a window, before the trunk was reset: the next run finds the window carrying the trunk's commits — one window, main reset, the stamp" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  killed_run 'o = u._into_window
def k(*a, **kw):
    o(*a, **kw); os._exit(9)
u._into_window = k'
  [ "$status" -eq 9 ]; [ -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  [ "$(git -C "$T" rev-list --count origin/main..main)" = 1 ]          # the cut: main still ahead
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's main was 1 commit ahead of origin/main; window 01 already carries those commits, so main is reset to origin/main."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 02"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T" log --format=%s lease/01 | head -2 | tr '\n' '|')" = "in flight|committed on trunk|" ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "a run killed inside the trunk's adoption, after its window was made and before the reset: the next run finishes it and names the window — no stop, no second window" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk"
  tip="$(git -C "$T" rev-parse main)"
  killed_run 'll._trunk_reset = lambda *a: os._exit(9)'
  [ "$status" -eq 9 ]; [ -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T" rev-parse main)" = "$tip" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's main was 1 commit ahead of origin/main; window 01 already carries those commits, so main is reset to origin/main."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"still ahead"*|*"incomplete"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]; [ ! -e "$DAEDALUS_HOME/state/upgrade-stopped.json" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$T" rev-parse lease/01)" = "$tip" ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  # the same cut, with the window lookup blind, goes through adopt's own finish ("already"): still no stop
  rm -rf "$DAEDALUS_HOME/state/upgraded-to"
  git -C "$T" reset -q --hard "$tip"
  killed_run 'u._carried_by = lambda *a: None'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's main was 1 commit ahead of origin/main; window 01 already carries those commits, and main is now reset to origin/main."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
}

@test "an untracked file the move back to the trunk would overwrite stops before anything moves, in a sentence that names it and says what to do — not 'it runs again'; moved aside, the next run finishes" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  git -C "$T" checkout -q main; printf 'gen\n' > "$T/gen.txt"; git -C "$T" add -A; cmt "$T" -m "generated file"
  git -C "$T" push -q origin main; git -C "$T" checkout -q feat/x
  printf 'mine\n' > "$T/gen.txt"
  s="upgrade to 0.7.0 incomplete: target/thing has untracked files that putting it back on main would overwrite (gen.txt) — move them out of that checkout, or commit them on its branch, then start a session again"
  for i in 1 2; do
    run python3 "$UP"
    [ "$status" -eq 1 ]
    [ "$(printf '%s\n' "$output" | tail -1)" = "$s" ] || { echo "$output"; return 1; }
  done
  case "$output" in *"runs again"*|*Aborting*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(cat "$T/gen.txt")" = mine ]
  run python3 "$UP" --dry-run
  case "$output" in *"would stop: $s"*) : ;; *) echo "$output"; return 1 ;; esac
  mv "$T/gen.txt" "$BATS_TEST_TMPDIR/gen.txt"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "an untracked file that resetting a trunk ahead of origin would overwrite stops before anything moves — the file is kept, nothing is adopted" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "committed on trunk"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  printf 'gen\n' > "$BATS_TEST_TMPDIR/hand/gen.txt"; git -C "$BATS_TEST_TMPDIR/hand" add -A; cmt "$BATS_TEST_TMPDIR/hand" -m "generated file"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  printf 'mine\n' > "$T/gen.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that resetting main to origin/main would overwrite (gen.txt) — move them out of that checkout, or commit them on its branch, then start a session again" ] || { echo "$output"; return 1; }
  [ "$(cat "$T/gen.txt")" = mine ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T" rev-list --count origin/main..main)" = 1 ]
}

@test "a stop that does not clear by itself says what to do when it comes back, and gives git's reason rather than its last line" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  killed_run 'import leaselib
def refuse(*a, **kw):
    raise ll.Refused("could not add worktrees/01/thing (fatal: worktrees/01/thing already exists)")
ll.adopt = refuse'
  [ "$status" -eq 1 ]
  case "$output" in *"could not move target/thing's work into a window (could not add worktrees/01/thing (fatal: worktrees/01/thing already exists)); it tries again at the next session start — if it stops the same way again, ask this home's agent to look into the reason given"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import leaselib as ll
print(ll.git_reason("error: The following untracked working tree files would be overwritten by checkout:\n\ta.txt\n\tb/c.txt\nPlease move or remove them before you switch branches.\nAborting\n"))
print(ll.git_reason("fatal: not a git repository\n"))
print(ll.git_reason(""))' "$DAEDALUS_HOME/core"
  [ "${lines[0]}" = "untracked files would be overwritten: a.txt, b/c.txt" ] || { echo "$output"; return 1; }
  [ "${lines[1]}" = "not a git repository" ]; [ "${lines[2]}" = "no output" ]
}

@test "a rebase, merge or bisect left part-way in a target checkout stops the upgrade before anything moves, in one sentence naming the operation and its remedy — even when the checkout reads clean (critic finding 3)" {
  git -C "$T" checkout -q -b feat/x; printf '1\n' > "$T/one.txt"; git -C "$T" add -A; cmt "$T" -m one
  printf '2\n' > "$T/two.txt"; git -C "$T" add -A; cmt "$T" -m two
  GIT_SEQUENCE_EDITOR="sed -i.bak -e 1s/^pick/edit/" git -C "$T" -c user.email=t@x -c user.name=t rebase -q -i main >/dev/null 2>&1
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ]          # a rebase stopped at "edit" reads clean
  s="upgrade to 0.7.0 incomplete: target/thing is in the middle of a rebase — finish it with git -C target/thing rebase --continue, or undo it with git -C target/thing rebase --abort, then start a session again"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "$s" ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  git -C "$T" rev-parse -q --verify refs/heads/feat/x >/dev/null
  run python3 "$UP" --dry-run
  case "$output" in *"would stop: $s"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" rebase --abort
  # a merge stopped on a conflict: the in-progress sentence, not the uncommitted-changes one
  git -C "$T" checkout -q main; printf 'm\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "main side"
  git -C "$T" checkout -q feat/x; printf 'f\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "branch side"
  git -C "$T" -c user.email=t@x -c user.name=t merge -q main >/dev/null 2>&1 || true
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing is in the middle of a merge — finish it with git -C target/thing merge --continue, or undo it with git -C target/thing merge --abort, then start a session again" ] || { echo "$output"; return 1; }
  git -C "$T" merge --abort
  # a bisect in a nested repo: its own remedy
  git -C "$T/sub" bisect start >/dev/null 2>&1
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing/sub is in the middle of a bisect — end it with git -C target/thing/sub bisect reset, then start a session again" ] || { echo "$output"; return 1; }
  git -C "$T/sub" bisect reset >/dev/null 2>&1
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
}
