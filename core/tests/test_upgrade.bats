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
  s="upgrade to 0.7.0 incomplete: target/thing has uncommitted changes — commit them on their branch inside that checkout, then start a session again"
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

@test "no remedy says 'stash them'; a stash in a target checkout is named in one upgrade line and by doctor, and stays where it is (critic finding 4)" {
  R="$BATS_TEST_DIRNAME/../.."
  for f in core/upgrade.py core/leaselib.py README.md CLAUDE.md CHANGELOG.md docs/handoff-reverse-caller.md; do
    ! tr '\n' ' ' < "$R/$f" | tr -s ' ' | grep -qiE 'or stash(ed)? them|or stashed|commit or stash' || { echo "$f still offers a stash"; return 1; }
  done
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'saved\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: target/thing holds 1 stash entry (stash@{0}: WIP on feat/x: "*"in flight) — saved work no window shows; the upgrade leaves it there, and core/doctor.sh names it until it is applied or dropped."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" stash list | wc -l | tr -d ' ')" = 1 ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing holds 1 stash entry (stash@{0}: WIP on feat/x: "*"in flight) — saved work no window shows; apply it in a window's worktree (git -C worktrees/<NN>/thing stash apply) or drop it once it is not needed"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" stash drop -q
  run python3 "$UP" --doctor
  case "$output" in *stash*) echo "$output"; return 1 ;; esac
}

@test "every local branch with work origin lacks becomes its own window, checked out or not, each named in one line; a merged branch, and one a window already carries, are left as they were; doctor names a parked branch before the upgrade (critic finding 1)" {
  git -C "$T" checkout -q -b feat/parked; printf 'p\n' > "$T/p.txt"; git -C "$T" add -A; cmt "$T" -m "parked work"
  git -C "$T" checkout -q -b feat/parked-base main; printf 'b\n' > "$T/b.txt"; git -C "$T" add -A; cmt "$T" -m "base work"
  git -C "$T" checkout -q -b feat/on-base; printf 'o\n' > "$T/o.txt"; git -C "$T" add -A; cmt "$T" -m "on base"
  git -C "$T" checkout -q -b fix/merged main; printf 'm\n' > "$T/m.txt"; git -C "$T" add -A; cmt "$T" -m "merged fix"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  git -C "$T" push -q origin fix/merged
  git -C "$BATS_TEST_TMPDIR/hand" fetch -q origin
  git -C "$BATS_TEST_TMPDIR/hand" -c user.email=t@x -c user.name=t merge -q --no-ff origin/fix/merged -m "Merge fix/merged"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  git -C "$T/sub" checkout -q -b feat/sub-parked; printf 's\n' > "$T/sub/s.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "sub parked"
  git -C "$T/sub" checkout -q main
  git -C "$T" checkout -q -b feat/active main; printf 'a\n' > "$T/act.txt"; git -C "$T" add -A; cmt "$T" -m "active work"
  run python3 "$UP" --doctor
  for s in "NOTE     target/thing has branch feat/parked, 1 commit past origin/main, in no window — the upgrade adopts it as a numbered window at the next session start (or run core/lease.sh adopt feat/parked)" \
           "NOTE     target/thing/sub has branch feat/sub-parked, 1 commit past origin/main, in no window — the upgrade adopts it as a numbered window at the next session start (or run core/lease.sh adopt feat/sub-parked --repo sub)"; do
    case "$output" in *"$s"*) : ;; *) echo "doctor lacks: $s"; echo "$output"; return 1 ;; esac
  done
  run python3 "$UP" --dry-run
  case "$output" in *"would move target/thing's branch feat/on-base (2 commits not on origin/main) into a numbered window"*"would move target/thing's branch feat/parked (1 commit not on origin/main) into a numbered window"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"feat/parked-base"*) echo "$output"; return 1 ;; esac     # carried by feat/on-base's window
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was on feat/active (1 commit not on origin/main: \"active work\"); that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Upgrade to 0.7.0: target/thing's branch feat/on-base (2 commits not on origin/main: \"base work\", \"on base\") is now window 02 (branch lease/02); target/thing stays on main. Promote it from the board (\"promote window 02\") or release it."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing's branch feat/parked (1 commit not on origin/main: \"parked work\") is now window 03"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/sub's branch feat/sub-parked (1 commit not on origin/main: \"sub parked\") is now window 04"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 05"*|*"feat/parked-base"*|*"fix/merged"*) echo "$output"; return 1 ;; esac
  [ "$(lease_json 03 adopted_from)" = feat/parked ]; [ "$(lease_json 04 adopted_repo)" = thing/sub ]
  [ "$(git -C "$T" rev-parse lease/02)" = "$(git -C "$T" rev-parse feat/parked-base)" ] || git -C "$T" merge-base --is-ancestor feat/parked-base lease/02
  git -C "$T" rev-parse -q --verify refs/heads/fix/merged >/dev/null; git -C "$T" rev-parse -q --verify refs/heads/feat/parked-base >/dev/null
  [ -d "$DAEDALUS_HOME/worktrees/03/thing" ]; [ "$(git -C "$DAEDALUS_HOME/worktrees/04/thing/sub" branch --show-current)" = lease/04 ]
  [ "$(git -C "$T" branch --show-current)" = main ]; [ "$(git -C "$T/sub" branch --show-current)" = main ]
  run python3 "$UP" --doctor
  case "$output" in *"in no window"*) echo "$output"; return 1 ;; esac
}

@test "untracked files of a checkout that becomes a window go with it — copied into its worktree, checked, then removed from target/; ignored files and nested repos stay, the ignored ones named in the window's line; untracked files in a checkout no window is made from are named in one line and by doctor (critic finding 2; review 2, finding 9)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'new\n' > "$T/newfile.py"; mkdir -p "$T/notes/deep"; printf 'n\n' > "$T/notes/deep/a.md"; ln -s newfile.py "$T/link.py"
  printf '*.log\nextra/\n' >> "$T/.git/info/exclude"; printf 'ignored\n' > "$T/build.log"; : > "$T/empty.log"
  git init -q "$T/extra"; printf 'e\n' > "$T/extra/e.txt"; git -C "$T/extra" add -A; cmt "$T/extra" -m "a repo of its own"
  printf 'stray\n' > "$T/sub/stray.txt"
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has untracked files no window holds (link.py, newfile.py, notes/deep/a.md) — the upgrade takes them into the window it makes from feat/x at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01 (branch lease/01), and target/thing is back on main."*"Its untracked files went with it into worktrees/01/thing: link.py, newfile.py, notes/deep/a.md."*" Ignored files stay in target/thing and are not in the window (build.log, extra/) — if any of them is work, move it into worktrees/01/thing."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Upgrade to 0.7.0: target/thing/sub holds untracked files no window has (stray.txt) — they stay there, and core/doctor.sh names them until they are moved into a window's worktree or removed."*) : ;; *) echo "$output"; return 1 ;; esac
  W="$DAEDALUS_HOME/worktrees/01/thing"
  [ "$(cat "$W/newfile.py")" = new ]; [ "$(cat "$W/notes/deep/a.md")" = n ]; [ "$(readlink "$W/link.py")" = newfile.py ]
  [ ! -e "$T/newfile.py" ]; [ ! -e "$T/notes" ]; [ ! -L "$T/link.py" ]
  [ "$(cat "$T/build.log")" = ignored ]; [ ! -e "$W/build.log" ]
  [ "$(cat "$T/sub/stray.txt")" = stray ]; [ "$(git -C "$T/extra" log --format=%s)" = "a repo of its own" ]
  case "$output" in *empty.log*|*"sub/"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$W" status --porcelain | sort | tr '\n' '|')" = "?? link.py|?? newfile.py|?? notes/|" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing/sub has untracked files no window holds (stray.txt) — target/thing/sub is the trunk mirror, which no session works in; move them into a window's worktree (worktrees/<NN>/thing/sub) or remove them"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing has untracked"*) echo "$output"; return 1 ;; esac
}

@test "an untracked file whose copy fails stays in target/ untouched, named in the window's line and by doctor — never removed before a checked copy exists (critic finding 2)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'keep\n' > "$T/newfile.py"
  killed_run 'def bad(*a, **kw):
    raise OSError("disk full")
u._copy_bytes = bad'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01"*"Untracked files that could not go with it stay in target/thing (newfile.py); core/doctor.sh names them until they are moved into worktrees/01/thing or removed."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/newfile.py")" = keep ]; [ ! -e "$DAEDALUS_HOME/worktrees/01/thing/newfile.py" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has untracked files no window holds (newfile.py)"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a branch checked out in a worktree someone made by hand is not adopted: one line names it, where it is and what to do; the upgrade completes and stamps; the worktree and its uncommitted edit are untouched; doctor says the same (release-candidate review, finding 1)" {
  git -C "$T" checkout -q -b feat/parked; printf 'p\n' > "$T/p.txt"; git -C "$T" add -A; cmt "$T" -m "parked work"
  git -C "$T" checkout -q main
  UW="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/userwt"
  git -C "$T" worktree add -q "$UW" feat/parked
  printf 'edit\n' >> "$UW/p.txt"
  rest="is checked out in another worktree, at $UW, so it was not made a window — once its work there is committed, remove that worktree (git -C target/thing worktree remove $UW) and run core/lease.sh adopt feat/parked"
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has branch feat/parked, 1 commit past origin/main, in no window — it $rest"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: target/thing's branch feat/parked (1 commit not on origin/main: \"parked work\") $rest."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"lease/01"*|*incomplete*) echo "$output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$UW" branch --show-current)" = feat/parked ]; [ "$(cat "$UW/p.txt")" = "$(printf 'p\nedit')" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has branch feat/parked, 1 commit past origin/main, in no window — it $rest"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a run killed in the middle of copying an untracked file leaves no partial file under its name in the window; the next run finishes the carry into that window, checks it, and removes the original (release-candidate review, finding 2)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  head -c 100001 /dev/zero | tr '\0' 'b' > "$T/big.dat"; printf 'small\n' > "$T/a-small.txt"
  killed_run 'u.CARRY_CHUNK = 10
n = [0]
o = u._out_of_time
def k(d):
    n[0] += 1
    if n[0] > 6:
        os._exit(9)
    return o(d)
u._out_of_time = k'
  [ "$status" -eq 9 ] || { echo "$output"; return 1; }
  W="$DAEDALUS_HOME/worktrees/01/thing"
  [ -d "$W" ]; [ ! -e "$W/big.dat" ]; [ "$(wc -c < "$T/big.dat" | tr -d ' ')" = 100001 ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's work became window 01 at an earlier start; its untracked files went with it into worktrees/01/thing: "*"big.dat"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"no window has"*|*"window 02"*) echo "$output"; return 1 ;; esac
  [ "$(wc -c < "$W/big.dat" | tr -d ' ')" = 100001 ]; [ "$(cat "$W/a-small.txt")" = small ]
  [ ! -e "$T/big.dat" ]; [ ! -e "$T/a-small.txt" ]
  [ -z "$(cd "$W" && ls -A | grep -v -e '^\.git$' -e '^a\.txt$' -e '^x\.txt$' -e '^big\.dat$' -e '^a-small\.txt$' -e '^sub$' -e '^\.gitignore$')" ] || { ls -A "$W"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  run python3 "$UP" --doctor
  case "$output" in *"untracked files no window holds"*) echo "$output"; return 1 ;; esac
}

@test "a run killed after the window was made and before its untracked files moved: the next run carries them into that window, not into the trunk mirror's 'no window has' line (release-candidate review, finding 2)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'new\n' > "$T/new.py"
  killed_run 'u._carry = lambda *a, **kw: os._exit(9)'
  [ "$status" -eq 9 ]; [ -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ "$(cat "$T/new.py")" = new ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's work became window 01 at an earlier start; its untracked files went with it into worktrees/01/thing: new.py."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"no window has"*) echo "$output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/new.py")" = new ]; [ ! -e "$T/new.py" ]
}

@test "the carry watches the session start's deadline: out of time between files it stops with 'it runs again', and the next run finishes the carry (release-candidate review, finding 2)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf '1\n' > "$T/one.txt"; printf '2\n' > "$T/two.txt"
  killed_run 'u._out_of_time = lambda d: True
lines, stop = u.run(u.v.ROOT, deadline=__import__("time").time() + 60)
print(stop); sys.exit(1)'
  case "$output" in *"upgrade to 0.7.0 incomplete: stopped while moving in-flight work in target/ into windows — the session start ran out of time; it runs again at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ "$(cat "$T/one.txt")" = 1 ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"its untracked files went with it into worktrees/01/thing: one.txt, two.txt."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$T/one.txt" ]; [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/two.txt")" = 2 ]
}

@test "a branch squash-merged on origin is not made a window — its change is already on origin/main; a branch whose branch on origin was deleted is left as it was and named in one line (release-candidate review, finding 3)" {
  git -C "$T" checkout -q -b feat/sq; printf '1\n' > "$T/sq.txt"; git -C "$T" add -A; cmt "$T" -m sq1
  printf '2\n' >> "$T/sq.txt"; git -C "$T" add -A; cmt "$T" -m sq2
  git -C "$T" push -q origin feat/sq
  git -C "$T" checkout -q -b feat/gone main; printf 'g\n' > "$T/g.txt"; git -C "$T" add -A; cmt "$T" -m gone1
  git -C "$T" push -q -u origin feat/gone
  git -C "$T" checkout -q main
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  git -C "$BATS_TEST_TMPDIR/hand" merge -q --squash origin/feat/sq
  git -C "$BATS_TEST_TMPDIR/hand" -c user.email=t@x -c user.name=t commit -q -m "feat/sq (squashed)"
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  git -C "$BATS_TEST_TMPDIR/hand" push -q origin --delete feat/gone
  git -C "$T" fetch -q --prune origin
  gone_note="NOTE     target/thing has branch feat/gone, 1 commit past origin/main, whose branch on origin was deleted — if it was not merged, run core/lease.sh adopt feat/gone"
  run python3 "$UP" --doctor
  case "$output" in *"feat/sq"*) echo "$output"; return 1 ;; esac
  case "$output" in *"$gone_note"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 01"*|*"could not be fast-forwarded"*|*"feat/sq"*) echo "$output"; return 1 ;; esac
  case "$output" in *"Upgrade to 0.7.0: target/thing's branch feat/gone holds commits origin/main has no copy of, but its branch on origin was deleted, which usually means it was merged — it was left as it was; if it was not merged, run core/lease.sh adopt feat/gone."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  git -C "$T" rev-parse -q --verify refs/heads/feat/sq >/dev/null; git -C "$T" rev-parse -q --verify refs/heads/feat/gone >/dev/null
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  # after the upgrade, when its one line has scrolled away, doctor still names it (review 2, finding 8)
  run python3 "$UP" --doctor
  case "$output" in *"$gone_note"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- release-candidate review 2 -------------------------------------------------------------------------------

@test "a gitignored file where putting the checkout back on the trunk would write stops the upgrade before anything moves — the file is kept, no stamp; lease.sh adopt refuses the same (review 2, finding 1)" {
  git -C "$T" checkout -q -b fix/in-flight
  git -C "$T" rm -q --cached a.txt; printf 'a.txt\n' >> "$T/.gitignore"; git -C "$T" add -A; cmt "$T" -m "stop tracking a.txt"
  printf 'OPERATOR LOCAL SETTINGS\n' > "$T/a.txt"
  [ -z "$(git -C "$T" status --porcelain)" ]          # git status shows nothing: it is ignored
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that putting it back on main would overwrite (a.txt) — move them out of that checkout, or commit them on its branch, then start a session again" ] || { echo "$output"; return 1; }
  [ "$(cat "$T/a.txt")" = "OPERATOR LOCAL SETTINGS" ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt fix/in-flight
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has ignored files that putting it back on main at origin/main would overwrite (a.txt)"*"nothing was adopted"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/a.txt")" = "OPERATOR LOCAL SETTINGS" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
}

@test "a gitignored file that resetting a trunk ahead of origin would write over stops the upgrade before anything moves — the file is kept, main still ahead (review 2, finding 2)" {
  git -C "$T" rm -q --cached a.txt; printf 'a.txt\n' >> "$T/.gitignore"; git -C "$T" add -A; cmt "$T" -m "stop tracking a.txt"
  printf 'OPERATOR LOCAL SETTINGS on trunk\n' > "$T/a.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that resetting main to origin/main would overwrite (a.txt) — move them out of that checkout, or commit them on its branch, then start a session again" ] || { echo "$output"; return 1; }
  [ "$(cat "$T/a.txt")" = "OPERATOR LOCAL SETTINGS on trunk" ]; [ "$(git -C "$T" rev-list --count origin/main..main)" = 1 ]
  [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt main
  [ "$status" -ne 0 ]
  case "$output" in *"resetting main to origin/main would overwrite (a.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/a.txt")" = "OPERATOR LOCAL SETTINGS on trunk" ]
  # a wholly ignored directory is in the way only where origin/main tracks a path that is on disk inside it
  mv "$T/a.txt" "$BATS_TEST_TMPDIR/a.txt"
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
  case "$(printf '%s\n' "$output" | tail -1)" in *"resetting main to origin/main would overwrite (build/keep.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/build/keep.txt")" = "MY BUILD KEEP" ]
}

@test "on a filesystem that ignores case, an untracked Thing-style file where a trunk reset writes its lower-case twin stops the upgrade; and a carry never removes a file that is no longer untracked under its name (review 2, finding 3)" {
  [ "$(git -C "$T" config --bool core.ignorecase)" = true ] || skip "this filesystem tells case apart"
  mkdir -p "$T/docs"; git -C "$T" mv a.txt docs/a.txt; cmt "$T" -m "move a.txt"
  printf 'SCRATCH NOTES, untracked, capital A\n' > "$T/A.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has untracked files that resetting main to origin/main would overwrite (A.txt) — move them out of that checkout, or commit them on its branch, then start a session again" ] || { echo "$output"; return 1; }
  [ "$(cat "$T/A.txt")" = "SCRATCH NOTES, untracked, capital A" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  # the carry's own check, with the stop blinded: the reset writes a.txt where A.txt was; the trunk's tracked file
  # stays in target/thing and nothing is copied into the window under the untracked name
  killed_run 'll.untracked_in_way = lambda *a, **kw: []'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(git -C "$T" status --porcelain)" ] || { git -C "$T" status --porcelain; return 1; }
  [ "$(cat "$T/a.txt")" = a ]
  [ ! -e "$DAEDALUS_HOME/worktrees/01/thing/A.txt" ]
  case "$output" in *"went with it"*) echo "$output"; return 1 ;; esac
}

@test "a detached HEAD whose change is already on origin as a squash keeps its commits on a named branch, said in the line, before the checkout goes back on the trunk (review 2, finding 4)" {
  git -C "$T" checkout -q --detach main
  printf '1\n' > "$T/d.txt"; git -C "$T" add -A; cmt "$T" -m "detached d1"
  printf '2\n' >> "$T/d.txt"; git -C "$T" add -A; cmt "$T" -m "detached d2 - unique message"
  h="$(git -C "$T" rev-parse HEAD)"
  git clone -q "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/hand"
  cp "$T/d.txt" "$BATS_TEST_TMPDIR/hand/d.txt"; printf '3\n' > "$BATS_TEST_TMPDIR/hand/e.txt"
  git -C "$BATS_TEST_TMPDIR/hand" add -A; cmt "$BATS_TEST_TMPDIR/hand" -m "d1+d2+d3 squashed"; git -C "$BATS_TEST_TMPDIR/hand" push -q origin main
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: target/thing was not on a branch; its change is already on origin/main, and it is back on main — its commits are kept on branch daedalus/upgrade-"*"-${h:0:7}, left as it was."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ -n "$(git -C "$T" for-each-ref --points-at "$h" refs/heads/daedalus/)" ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "a local branch named origin/main stops the upgrade before anything moves, and doctor names it; renamed, the upgrade finishes; a window is still cut from origin's main when such a branch comes back (review 2, finding 5)" {
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
  git -C "$T" branch -m origin/main feat/o
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's branch feat/o (1 commit not on origin/main: \"on a branch named origin/main\") is now window 01"*"complete."*) : ;; *) echo "$output"; return 1 ;; esac
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

@test "an uncommitted edit hidden from git status by skip-worktree or assume-unchanged stops the upgrade before anything moves, naming the file and how to clear the mark; doctor and lease.sh adopt name it too; a marked file with no edit is no stop (review 2, finding 6)" {
  git -C "$T" checkout -q -b fix/in-flight; printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m "the waiting fix"
  printf 'MY UNCOMMITTED EDIT\n' > "$T/a.txt"; git -C "$T" update-index --skip-worktree a.txt
  git -C "$T/sub" update-index --assume-unchanged n.txt            # marked, unchanged: not work
  [ -z "$(git -C "$T" status --porcelain --untracked-files=no)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: target/thing has uncommitted changes git status does not show, in files marked skip-worktree (a.txt) — clear the mark (git -C target/thing update-index --no-skip-worktree a.txt), commit them on their branch inside that checkout, then start a session again" ] || { echo "$output"; return 1; }
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; [ "$(cat "$T/a.txt")" = "MY UNCOMMITTED EDIT" ]
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     target/thing has uncommitted changes git status does not show, in files marked skip-worktree (a.txt) — no window has them; clear the mark (git -C target/thing update-index --no-skip-worktree a.txt) and commit them on a branch"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/sub has uncommitted"*) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt fix/in-flight
  [ "$status" -ne 0 ]
  case "$output" in *"target/thing has uncommitted changes git status does not show, in files marked skip-worktree (a.txt)"*"nothing was adopted"*) : ;; *) echo "$output"; return 1 ;; esac
  # assume-unchanged: the same stop, its own remedy
  git -C "$T" update-index --no-skip-worktree a.txt; git -C "$T" update-index --assume-unchanged a.txt
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$(printf '%s\n' "$output" | tail -1)" in *"in files marked assume-unchanged (a.txt) — clear the mark (git -C target/thing update-index --no-assume-unchanged a.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" update-index --no-assume-unchanged a.txt; git -C "$T" add -A; cmt "$T" -m "the edit, committed"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/a.txt")" = "MY UNCOMMITTED EDIT" ]
}

@test "a nested repo's adopted window, swept: its unpromoted commits are named by doctor and the board, its untracked files by doctor, and its number is never silently held back (review 2, finding 7)" {
  git -C "$T/sub" checkout -q -b fix/nested; printf 'n2\n' > "$T/sub/n2.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "nested waiting fix"
  printf 'notes\n' > "$T/sub/notes-untracked.txt"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing/sub was on fix/nested"*"now window 01"*"worktrees/01/thing/sub: notes-untracked.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  touch -t 202001010000 "$DAEDALUS_HOME/state/leases/01.seen"
  run bash "$DAEDALUS_HOME/core/lease.sh" sweep
  case "$output" in *"removed the lease of window 01 (stale)"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines
  case "$output" in *"NOTE     leases: 01 swept with 1 unpromoted commit waiting"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"NOTE     leases: worktrees/01/thing/sub holds uncommitted or untracked files of swept window 01 (notes-untracked.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"- 01 — swept, 1 unpromoted commit waiting (\"nested waiting fix\")"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "an untracked file named like the carry's temporary name for another goes with it too, both whole (review 2, finding 10)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'IMPORTANT NOTES\n' > "$T/.notes.upgrade-carry"; printf 'plain notes\n' > "$T/notes"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"went with it into worktrees/01/thing: .notes.upgrade-carry, notes."*) : ;; *) echo "$output"; return 1 ;; esac
  W="$DAEDALUS_HOME/worktrees/01/thing"
  [ "$(cat "$W/.notes.upgrade-carry")" = "IMPORTANT NOTES" ]; [ "$(cat "$W/notes")" = "plain notes" ]
  [ ! -e "$DAEDALUS_HOME/worktrees/01/.upgrade-carry" ]
}

@test "a trunk-ahead adoption killed after lease/NN was made and before its lease file: the next run finishes that window — one window holds the commits, outer and nested; a checked-out branch killed after lease/NN was made the same (review 2, finding 11; review 3, finding 9)" {
  printf 'ahead1\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "main-ahead-1"
  printf 'ahead2\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "main-ahead-2"
  printf 'n\n' > "$T/notes.txt"
  printf 's\n' >> "$T/sub/n.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "sub-ahead"
  kill_at_lease_file='o = ll.write_lease
def k(root, nn, data, exclusive=False):
    if exclusive:
        os._exit(9)
    return o(root, nn, data, exclusive)
ll.write_lease = k'
  killed_run "$kill_at_lease_file"
  [ "$status" -eq 9 ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]; git -C "$T" rev-parse -q --verify refs/heads/lease/01 >/dev/null
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing's main was 2 commits ahead of origin/main"*"that work is now window 01"*"worktrees/01/thing: notes.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/sub's main was 1 commit ahead of origin/main"*"that work is now window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 03"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/03.json" ]; ! git -C "$T" rev-parse -q --verify refs/heads/lease/03 >/dev/null
  [ "$(git -C "$T" log --format=%s lease/01 | head -2 | tr '\n' '|')" = "main-ahead-2|main-ahead-1|" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/notes.txt")" = n ]
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"swept"*) echo "$output"; return 1 ;; esac
  # the nested repo's trunk cut off the same way
  rm -f "$DAEDALUS_HOME/state/upgraded-to"
  printf 's2\n' >> "$T/sub/n.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "sub-ahead-2"
  killed_run "$kill_at_lease_file"
  [ "$status" -eq 9 ]; [ ! -e "$DAEDALUS_HOME/state/leases/03.json" ]; git -C "$T/sub" rev-parse -q --verify refs/heads/lease/03 >/dev/null
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing/sub's main was 1 commit ahead of origin/main"*"that work is now window 03"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -e "$DAEDALUS_HOME/state/leases/03.json" ]; [ ! -e "$DAEDALUS_HOME/state/leases/04.json" ]
  ! git -C "$T/sub" rev-parse -q --verify refs/heads/lease/04 >/dev/null
  # a checked-out branch cut off after lease/NN was made at its tip (never renamed: review 3, finding 9): the branch
  # is still checked out, and the next run adopts it as that window, not a second one beside it
  rm -f "$DAEDALUS_HOME/state/upgraded-to"
  git -C "$T" checkout -q -b feat/x main; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'u\n' > "$T/u.txt"
  killed_run "$kill_at_lease_file"
  [ "$status" -eq 9 ]; [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/leases/04.json" ]
  [ "$(git -C "$T" rev-parse lease/04)" = "$(git -C "$T" rev-parse feat/x)" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was on feat/x (1 commit not on origin/main: \"in flight\"); that work is now window 04"*"worktrees/04/thing: u.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = main ]; [ ! -e "$DAEDALUS_HOME/state/leases/05.json" ]
  ! git -C "$T" rev-parse -q --verify refs/heads/feat/x >/dev/null
  [ "$(cat "$DAEDALUS_HOME/worktrees/04/thing/u.txt")" = u ]
}

@test "a detached checkout's adoption killed part-way — before the trunk checkout, or after the rename before the lease file — is finished by the next run: one window, the untracked files in it, no stray label (review 2, finding 12)" {
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "main-ahead-1"
  git -C "$T" checkout -q --detach main; printf 'd\n' > "$T/d.txt"; git -C "$T" add -A; cmt "$T" -m "detached-work"
  printf 'n\n' > "$T/notes.txt"
  # (a) killed at adopt's checkout of the trunk, after the lease file was written (run through git_finish since
  # release-candidate review 4, finding 6)
  killed_run 'o = ll.git_finish
def k(repo, *args, **kw):
    if args[:2] == ("checkout", "--quiet"):
        os._exit(9)
    return o(repo, *args, **kw)
ll.git_finish = k'
  [ "$status" -eq 9 ]; [ -e "$DAEDALUS_HOME/state/leases/01.json" ]; [ -z "$(git -C "$T" branch --show-current)" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 01, adopted from target/thing at an earlier start, now has its worktree"*"target/thing's work became window 01 at an earlier start; its untracked files went with it into worktrees/01/thing: notes.txt."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 02"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]; [ "$(git -C "$T" branch --show-current)" = main ]
  [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/notes.txt")" = n ]; [ ! -e "$T/notes.txt" ]
  [ -z "$(git -C "$T" for-each-ref refs/heads/daedalus/)" ]
  [ "$(git -C "$T" rev-parse main)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(lease_json 01 worktree_ready)" = None ]
  # (b) killed after the label became lease/NN, before the lease file
  rm -f "$DAEDALUS_HOME/state/upgraded-to"
  printf 'ahead\n' >> "$T/a.txt"; git -C "$T" add -A; cmt "$T" -m "main-ahead-again"
  git -C "$T" checkout -q --detach main; printf 'd2\n' > "$T/d2.txt"; git -C "$T" add -A; cmt "$T" -m "detached-work-2"
  printf 'm\n' > "$T/more.txt"
  killed_run 'o = ll.write_lease
def k(root, nn, data, exclusive=False):
    if exclusive:
        os._exit(9)
    return o(root, nn, data, exclusive)
ll.write_lease = k'
  [ "$status" -eq 9 ]; [ ! -e "$DAEDALUS_HOME/state/leases/02.json" ]; git -C "$T" rev-parse -q --verify refs/heads/lease/02 >/dev/null
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was not on a branch (2 commits not on origin/main"*"that work is now window 02"*"worktrees/02/thing: more.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 03"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/leases/03.json" ]; [ -z "$(git -C "$T" for-each-ref refs/heads/daedalus/)" ]
  [ "$(cat "$DAEDALUS_HOME/worktrees/02/thing/more.txt")" = m ]
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"swept"*|*"STALE"*) echo "$output"; return 1 ;; esac
}

@test "an adoption killed between its lease file and the end of its worktrees: the next run makes the worktree, carries the untracked files into it, and the board does not call it stale (review 2, finding 13)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "the waiting fix"
  printf 'n\n' > "$T/notes.txt"
  killed_run 'll.add_worktrees = lambda *a, **kw: os._exit(9)'
  [ "$status" -eq 9 ]; [ "$(lease_json 01 worktree_ready)" = False ]; [ ! -d "$DAEDALUS_HOME/worktrees/01/thing" ]
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 01, adopted from target/thing at an earlier start, now has its worktree (worktrees/01/thing)."*"its untracked files went with it into worktrees/01/thing: notes.txt."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"could not go"*|*"window 02"*) echo "$output"; return 1 ;; esac
  [ "$(lease_json 01 worktree_ready)" = None ]; [ "$(git -C "$DAEDALUS_HOME/worktrees/01/thing" branch --show-current)" = lease/01 ]
  [ "$(cat "$DAEDALUS_HOME/worktrees/01/thing/notes.txt")" = n ]; [ ! -e "$T/notes.txt" ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *"STALE"*) echo "$output"; return 1 ;; esac
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
}

@test "a session start that runs out of time making an adopted window's worktree writes no stamp: it stops saying it runs again and names the window it did make; the board shows the unfinished window's commits and how to finish it, doctor names it, and the next start finishes it (release-candidate red team, finding 1)" {
  git -C "$T" checkout -q -b park/y; printf 'y\n' > "$T/y.txt"; git -C "$T" add -A; cmt "$T" -m "parked work"
  git -C "$T" checkout -q -b feat/x main; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  # window 02's worktree add runs out of the start's time once (one slow checkout of a large repository)
  killed_run 'o = ll.add_worktrees
def k(root, nn, *a, **kw):
    flag = os.path.join(os.environ["BATS_TEST_TMPDIR"], "slow-once")
    if nn == "02" and not os.path.exists(flag):
        open(flag, "w").close()
        return False
    return o(root, nn, *a, **kw)
ll.add_worktrees = k
lines, stop = u.run(u.v.ROOT, deadline=__import__("time").time() + 60)
print("\n".join(lines)); print(stop); sys.exit(1)'
  case "$output" in *"target/thing was on feat/x"*"is now window 01"*"target/thing's branch park/y (1 commit not on origin/main: \"parked work\"); that work is now window 02 (branch lease/02), whose worktree is not made yet — the next session start makes it."*"upgrade to 0.7.0 incomplete: stopped while moving in-flight work in target/ into windows — the session start ran out of time; it runs again at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"complete."*|*"promote window 02"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ "$(lease_json 02 worktree_ready)" = False ]
  [ ! -d "$DAEDALUS_HOME/worktrees/02/thing" ]
  run bash "$DAEDALUS_HOME/core/lease.sh" list
  case "$output" in *'- 02 — '*'last commit "parked work"'*'core/lease.sh claim 02'*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *'- 02 — '*'no commits yet'*) echo "$output"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines
  case "$output" in *"window 02 (adopted from park/y) has no worktree yet"*"core/lease.sh claim 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"window 02, adopted from target/thing at an earlier start, now has its worktree (worktrees/02/thing)."*"complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"window 03"*) echo "$output"; return 1 ;; esac
  [ "$(lease_json 02 worktree_ready)" = None ]; [ "$(cat "$DAEDALUS_HOME/worktrees/02/thing/y.txt")" = y ]
  [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  run python3 "$DAEDALUS_HOME/core/leaselib.py" doctor-lines
  case "$output" in *"no worktree yet"*) echo "$output"; return 1 ;; esac
}

@test "the stamp is not written while a window adopted from target/ has no worktree: a run that finds one it cannot finish stops instead of saying complete (release-candidate red team, finding 1)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  # every worktree add fails, and the step's own check after each adoption is bypassed: only the stamp's is left
  killed_run 'll.add_worktrees = lambda *a, **kw: False
u._into_window = lambda root, key, rel, ref, ver, deadline: dict(ll.adopt(root, ref, fetch=False), ready=True)
lines, stop = u.run(u.v.ROOT); print("\n".join(lines)); print(stop); sys.exit(1)'
  case "$output" in *"upgrade to 0.7.0 incomplete: stopped while moving in-flight work in target/ into windows — window 01 (adopted from feat/x) has no worktree yet"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"complete."*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]; [ "$(lease_json 01 worktree_ready)" = False ]
}
