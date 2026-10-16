#!/usr/bin/env bats
# core/upgrade.py's safety copy: before the upgrade's first change to anything under target/, a copy of everything
# there — every repository's refs, the commits only a stash or a reflog holds, every file git does not track or
# that differs from its last commit, git's in-progress files — is written to state/upgrade-snapshot/<stamp>/ and
# checked; the upgrade stops before changing anything when it cannot be. --restore-help names what the copy holds
# that target/ no longer has, with the commands that bring it back; --forget-snapshot removes it only when nothing is.
bats_require_minimum_version 1.5.0
load fixtures/upgrade/setup.bash
setup() {
  upgrade_fixture
  B="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  REAL_GIT="$(command -v git)"
  export B REAL_GIT
}
teardown() {
  if [ -f "$DAEDALUS_HOME/state/upgrade-background.json" ]; then   # never leave a background run behind
    p="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid") or "")' "$DAEDALUS_HOME/state/upgrade-background.json" 2>/dev/null)"
    [ -n "$p" ] && kill "$p" 2>/dev/null
  fi
  teardown_live
}

snaps() { ls -1 "$DAEDALUS_HOME/state/upgrade-snapshot" 2>/dev/null | grep -v '^\.' || true; }
# up_done — the upgrade as it runs now: a run that stops on unfinished work is followed by "pick it up"
# (core/lease.sh adopt --all-unfinished) and a second run; $output holds all three, $status the last run's. Any
# other stop is left for the caller to judge.
up_done() {
  run python3 "$UP"
  case "$status:$output" in 1:*"Daedalus has unfinished work"*) : ;; *) return 0 ;; esac
  local first="$output" picked
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished </dev/null
  picked="$output"
  run python3 "$UP"
  output="$first
$picked
$output"
}
old_locks() { find "$T/.git" "$T/sub/.git" -name '*.lock' -exec touch -t 202001010000 {} + 2>/dev/null || true; }
newest() { printf '%s/state/upgrade-snapshot/%s' "$DAEDALUS_HOME" "$(snaps | tail -1)"; }
cmds() { printf '%s\n' "$1" | sed -n 's/^    //p'; }        # the command lines --restore-help prints, four spaces in
gone() {           # gone <repo> — commits only a deleted branch, stash or reflog held are really gone from <repo>
  git -C "$1" reflog expire --expire=now --expire-unreachable=now --all
  git -C "$1" gc -q --prune=now
}
NOTHING="every branch, tag, stash entry, recent commit and file it holds is still in target/ or in a window"

# shim_git — puts a git first on PATH that logs every call to $B/git.log as "<n>\t<M|R>\t<dir>\t<args>": M when it
# changes a repository under target/ or worktrees/. With KILL_AT=<n> the n-th such call kills the python process
# running it (as a hook's timeout or a kill -9 would) before git runs, once ($B/killed).
shim_git() {
  mkdir -p "$B/shim"
  cat > "$B/shim/git" <<'SH'
#!/bin/bash
dir="$PWD"; args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    -C) i=$((i+1)); case "${args[$i]}" in /*) dir="${args[$i]}" ;; *) dir="$dir/${args[$i]}" ;; esac ;;
    -c|--git-dir|--work-tree|--namespace) i=$((i+1)) ;;
    --git-dir=*|--work-tree=*|--no-optional-locks|--no-pager|--literal-pathspecs|-P) ;;
    *) break ;;
  esac
  i=$((i+1))
done
sub="${args[$i]}"; rest=("${args[@]:$((i+1))}"); m=R
case "$sub" in
  fetch|checkout|switch|reset|update-ref|merge|rebase|commit|cherry-pick|revert|am|pull|push|pack-refs|gc|prune|clean|rm|mv|add|read-tree|checkout-index|update-index|restore) m=M ;;
  worktree) case "${rest[0]}" in add|remove|prune|move|repair|lock|unlock) m=M ;; esac ;;
  stash) case "${rest[0]:-push}" in list|show) ;; *) m=M ;; esac ;;
  reflog) case "${rest[0]}" in expire|delete) m=M ;; esac ;;
  symbolic-ref) n=0; for a in "${rest[@]}"; do case "$a" in -*) ;; *) n=$((n+1)) ;; esac; done; [ $n -ge 2 ] && m=M ;;
  tag) for a in "${rest[@]}"; do case "$a" in -l|--list|--contains|--points-at|--format*) m=R; break ;; -*) ;; *) m=M ;; esac; done ;;
  branch) list=; pos=
    for a in "${rest[@]}"; do case "$a" in
      -d|-D|-m|-M|-c|-C|-f|--force|--delete|--move|--copy|-u|--set-upstream-to*|--unset-upstream) m=M ;;
      --list|-l|--contains*|--merged*|--no-merged*|--points-at*|-a|-r|--all|--remotes|--format*|--show-current|-v|-vv) list=1 ;;
      -*) ;; *) pos=1 ;; esac; done
    [ -n "$pos" ] && [ -z "$list" ] && m=M ;;
  config) for a in "${rest[@]}"; do case "$a" in --unset*|--add|--replace-all|--rename-section|--remove-section) m=M ;; esac; done ;;
esac
real="$(cd "$dir" 2>/dev/null && pwd -P)"
case "$real/" in "$DAEDALUS_HOME"/target/*|"$DAEDALUS_HOME"/worktrees/*) : ;; *) m=R ;; esac
n=$(( $(wc -l < "$B/git.log" 2>/dev/null || echo 0) + 1 ))
printf '%s\t%s\t%s\t%s\n' "$n" "$m" "$real" "$*" >> "$B/git.log"
if [ "$m" = M ] && [ -n "${KILL_AT:-}" ] && [ ! -e "$B/killed" ]; then
  k=$(( $(cat "$B/mcount" 2>/dev/null || echo 0) + 1 )); echo "$k" > "$B/mcount"
  if [ "$k" -ge "$KILL_AT" ]; then
    : > "$B/killed"; pid=$PPID
    while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
      case "$(ps -o command= -p "$pid")" in *python*) kill -9 "$pid"; break ;; esac
      pid="$(ps -o ppid= -p "$pid" | tr -d ' ')"
    done
    exit 137
  fi
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$B/shim/git"; : > "$B/git.log"; rm -f "$B/killed" "$B/mcount"
}

# busy_target — work of every kind the upgrade moves: main ahead of origin, feat/x checked out with a commit, an
# untracked and an ignored file, a parked branch, two stash entries, the nested repo detached with a commit
busy_target() {
  printf '*.local\n' >> "$T/.git/info/exclude"
  printf 'trunk\n' > "$T/trunk.txt"; git -C "$T" add -A; cmt "$T" -m "trunk work, unpushed"
  printf 's1\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  printf 's2\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash -q
  git -C "$T" checkout -q -b park/y refs/remotes/origin/main; printf 'y\n' > "$T/y.txt"; git -C "$T" add -A; cmt "$T" -m "parked work"
  git -C "$T" checkout -q -b feat/x refs/remotes/origin/main; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'MY NOTES\n' > "$T/notes.md"; printf 'MY SETTINGS\n' > "$T/my.local"
  git -C "$T/sub" checkout -q --detach; printf 'd\n' > "$T/sub/d.txt"; git -C "$T/sub" add -A; cmt "$T/sub" -m "detached work"
  BT_MAIN="$(git -C "$T" rev-parse main)"; BT_PARK="$(git -C "$T" rev-parse park/y)"; BT_FEAT="$(git -C "$T" rev-parse feat/x)"
  BT_S0="$(git -C "$T" rev-parse 'stash@{0}')"; BT_S1="$(git -C "$T" rev-parse 'stash@{1}')"; BT_SUB="$(git -C "$T/sub" rev-parse HEAD)"
  export BT_MAIN BT_PARK BT_FEAT BT_S0 BT_S1 BT_SUB
}

# held <when> — the kept copies, together, hold everything busy_target made: notes.md and my.local by content, main's
# unpushed commit, park/y, feat/x, both stash entries and sub's detached commit — each in the manifest and in the
# bundle's own list of heads (a copy that was never taken, or holds less, fails here).
held() {
  python3 - "$DAEDALUS_HOME" "$1" <<'PY' || return 1
import glob, hashlib, json, os, subprocess, sys
home, when = sys.argv[1], sys.argv[2]
e = os.environ
refs, files, heads = set(), set(), set()
for mf in sorted(glob.glob(home + "/state/upgrade-snapshot/*/manifest.json")):
    m, d = json.load(open(mf)), os.path.dirname(mf)
    for r in m["repos"]:
        refs |= {(r["label"], x["kind"], x["name"], x["sha"]) for x in r["refs"]}
        files |= {(r["label"], f["path"], f["sha256"]) for f in r["files"]}
        if r["bundle"]:
            out = subprocess.check_output(["git", "bundle", "list-heads", os.path.join(d, r["bundle"])], text=True)
            heads |= {(r["label"], ln.split(" ")[0]) for ln in out.splitlines()}
t, s = "target/thing", "target/thing/sub"
sha = lambda b: hashlib.sha256(b).hexdigest()
want_files = {(t, "notes.md", sha(b"MY NOTES\n")), (t, "my.local", sha(b"MY SETTINGS\n"))}
want_refs = {(t, "branch", "refs/heads/main", e["BT_MAIN"]), (t, "branch", "refs/heads/park/y", e["BT_PARK"]),
             (t, "branch", "refs/heads/feat/x", e["BT_FEAT"]), (t, "stash-entry", "stash@{0}", e["BT_S0"]),
             (t, "stash-entry", "stash@{1}", e["BT_S1"]), (s, "head", "HEAD", e["BT_SUB"])}
bad = sorted(want_files - files) + sorted(want_refs - refs) + sorted({(x[0], x[3]) for x in want_refs} - heads)
assert not bad, "%s: the kept copies lack %s" % (when, bad)
PY
}

@test "the safety copy is written and checked before the upgrade's first change in target/ — every repository's bundle verified, every file in the manifest with its sha256 — and the run says where it is" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "shipped"
  git -C "$T" push -q origin feat/x:main         # its work is on origin: the upgrade puts the checkout back on main
  printf 'notes.md\n' >> "$T/.git/info/exclude"
  printf 'MY NOTES\n' > "$T/notes.md"; tip="$(git -C "$T" rev-parse HEAD)"; nsum="$(shasum -a 256 "$T/notes.md" | cut -d' ' -f1)"
  shim_git
  PATH="$B/shim:$PATH" run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: a safety copy of everything in target/ is in state/upgrade-snapshot/$(snaps | tail -1) ("*"), taken before anything there changed."*"it is back on main"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 - "$B/git.log" <<'PY'
import sys
rows = [l.rstrip("\n").split("\t", 3) for l in open(sys.argv[1])]
ver = [int(r[0]) for r in rows if " bundle verify " in " %s " % r[3]]
mut = [int(r[0]) for r in rows if r[1] == "M"]
assert len(ver) == 2, ("one bundle verified per repository (thing, thing/sub)", ver)
assert mut, "the upgrade changed nothing in target/"
assert max(ver) < min(mut), ("a change before the copy was checked", [r for r in rows if int(r[0]) == min(mut)])
PY
  S="$(newest)"
  python3 - "$S/manifest.json" "$tip" "$nsum" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert m["verified"] is True and m["version"] == "0.7.0", m
labels = [r["label"] for r in m["repos"]]
assert labels == ["target/thing", "target/thing/sub"], labels
thing = m["repos"][0]
assert {"name": "refs/heads/feat/x", "sha": sys.argv[2]}.items() <= next(r for r in thing["refs"] if r["name"] == "refs/heads/feat/x").items()
f = next(f for f in thing["files"] if f["path"] == "notes.md")
assert f["sha256"] == sys.argv[3] and f["kind"] == "ignored", f
PY
  git bundle list-heads "$S/1-thing.bundle" | grep -q "^$tip "
  ! git -C "$T" for-each-ref | grep -q upgrade-snapshot          # the copy's own refs live in the bundle only
  run python3 "$UP" --restore-help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

# kill_each <first> — busy_target, the upgrade stopped on its unfinished work (the copy taken), then "pick it up"
# killed at its <first>-th change in target/, then every 4th after it, a fresh busy_target each time, until a run
# makes fewer changes than that and finishes; after each kill --restore-help finds nothing missing, "pick it up" and
# the next runs finish the upgrade, and nothing is missing after them either. Four tests split the cuts so they run
# side by side.
kill_each() {
  n=$1
  while :; do
    [ "$n" -le 120 ] || { echo "more than 120 changes: the loop never reached a run that finished"; return 1; }
    rm -rf "$B/dae" "$B/origin.git" "$B/sub-origin.git"; upgrade_fixture; busy_target
    run python3 "$UP"
    case "$status:$output" in 1:*"Daedalus has unfinished work"*) : ;; *) echo "the first run did not stop: $output"; return 1 ;; esac
    shim_git
    KILL_AT=$n PATH="$B/shim:$PATH" run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished </dev/null
    if [ ! -e "$B/killed" ]; then
      [ "$status" -eq 0 ] || { echo "pick it up, uncut at $n: $output"; return 1; }
      run python3 "$UP"
      case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "after an uncut pick-up: $output"; return 1 ;; esac
      break
    fi
    [ "$status" -eq 137 ] || { echo "kill $n: exit $status: $output"; return 1; }
    [ "$(snaps | grep -c .)" -ge 1 ] || { echo "after kill $n: no safety copy was kept"; return 1; }
    held "after kill $n" || return 1
    run python3 "$UP" --restore-help
    case "$output" in *"no longer has"*|*"Bring it back"*|*"bring it back"*) echo "after kill $n: $output"; return 1 ;; esac
    [ "$(printf '%s\n' "$output" | grep -c "$NOTHING")" = "$(snaps | grep -c .)" ] || { echo "after kill $n: $output"; return 1; }
    old_locks
    for again in 1 2 3; do
      run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished </dev/null
      run python3 "$UP"
      case "$output" in *"Upgrade to 0.7.0: complete."*) break ;; esac
      old_locks
    done
    case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "after kill $n the upgrade did not finish: $output"; return 1 ;; esac
    run python3 "$UP" --restore-help
    [ "$(printf '%s\n' "$output" | grep -c "$NOTHING")" = "$(snaps | grep -c .)" ] || { echo "after kill $n and a full run: $output"; return 1; }
    [ "$(cat "$DAEDALUS_HOME"/worktrees/*/thing/notes.md 2>/dev/null)" = "MY NOTES" ] || { echo "after kill $n: notes.md is not in one window"; return 1; }
    [ -z "$(git -C "$T" stash list)" ] || { echo "after kill $n: the stash still holds entries"; return 1; }
    [ "$(ls "$DAEDALUS_HOME/state/leases" | grep -c '^[0-9][0-9]\.json$')" = 5 ] || { echo "after kill $n: $(ls "$DAEDALUS_HOME/state/leases")"; return 1; }
    held "after kill $n and a full run" || return 1
    n=$((n+4))
  done
  CUTS=$((n-4))
}

@test "'pick it up' killed at each change it makes in target/ (the 1st, 5th, 9th, ...): after every kill --restore-help finds nothing missing, picking it up again and the next run finish, and nothing is missing after it either" {
  kill_each 1
  [ "$CUTS" -ge 20 ] || { echo "only $CUTS changes were cut: the shim saw too few"; return 1; }
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "'pick it up' killed at each change it makes in target/ (the 2nd, 6th, 10th, ...): nothing missing after each kill, nor after the run that finishes" {
  kill_each 2
}

@test "'pick it up' killed at each change it makes in target/ (the 3rd, 7th, 11th, ...): nothing missing after each kill, nor after the run that finishes" {
  kill_each 3
}

@test "'pick it up' killed at each change it makes in target/ (the 4th, 8th, 12th, ...): nothing missing after each kill, nor after the run that finishes" {
  kill_each 4
}

@test "recoverable from the copy: two branches whose names differ only in case — the upgrade stops on them, and once both are gone --restore-help brings each back under its own name" {
  [ "$(git -C "$T" config --bool core.ignorecase)" = true ] || skip "git here tells branch names apart by case"
  git -C "$T" worktree add -q -b Wip "$B/tmpwt" main
  printf 'U\n' > "$B/tmpwt/upper.txt"; git -C "$B/tmpwt" add -A; cmt "$B/tmpwt" -m "UPPER WORK"
  c1="$(git -C "$B/tmpwt" rev-parse HEAD)"; git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" pack-refs --all
  git -C "$T" worktree add -q --detach "$B/tmpwt" main
  printf 'L\n' > "$B/tmpwt/lower.txt"; git -C "$B/tmpwt" add -A; cmt "$B/tmpwt" -m "LOWER WORK"
  c2="$(git -C "$B/tmpwt" rev-parse HEAD)"; git -C "$T" worktree remove "$B/tmpwt"
  git -C "$T" branch wip "$c2"
  run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"branches whose names differ only in case (Wip, wip)"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); r={x["name"]: x["sha"] for x in m["repos"][0]["refs"]}; assert r["refs/heads/Wip"] == sys.argv[2] and r["refs/heads/wip"] == sys.argv[3], r' "$(newest)/manifest.json" "$c1" "$c2"
  git -C "$T" pack-refs --all; git -C "$T" update-ref -d refs/heads/Wip "$c1"; git -C "$T" update-ref -d refs/heads/wip "$c2"; gone "$T"
  ! git -C "$T" cat-file -e "$c1" 2>/dev/null; ! git -C "$T" cat-file -e "$c2" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"commit ${c1:0:7} (\"UPPER WORK\") — branch Wip."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"commit ${c2:0:7} (\"LOWER WORK\") — branch wip."*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(git -C "$T" rev-parse "refs/heads/restored/Wip-${c1:0:7}")" = "$c1" ]
  [ "$(git -C "$T" rev-parse "refs/heads/restored/wip-${c2:0:7}")" = "$c2" ]
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "recoverable from the copy: work inside a submodule — its branch's commit and its untracked file, both lost after the upgrade, come back" {
  sd="$B/seed-lib"; git init -q -b main "$sd"; printf 'lib\n' > "$sd/lib.txt"; git -C "$sd" add -A; cmt "$sd" -m lib
  git init -q --bare -b main "$B/lib.git"; git -C "$sd" push -q "$B/lib.git" main
  git -C "$T" -c protocol.file.allow=always submodule add -q "$B/lib.git" lib >/dev/null 2>&1
  cmt "$T" -m "add lib"; git -C "$T" push -q origin main
  L="$T/lib"; rec="$(git -C "$L" rev-parse HEAD)"
  git -C "$L" checkout -q -b wip/lib; printf 'w\n' > "$L/w.txt"; git -C "$L" add w.txt; cmt "$L" -m "lib wip commit"
  w="$(git -C "$L" rev-parse HEAD)"; git -C "$L" checkout -q --detach "$rec"; printf 'MY LIB NOTES\n' > "$L/notes.md"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); r=[r for r in m["repos"] if r["label"] == "target/thing/lib"]; assert r and "notes.md" in [f["path"] for f in r[0]["files"]], m["repos"]' "$(newest)/manifest.json"
  git -C "$L" branch -q -D wip/lib; rm "$L/notes.md"; gone "$L"
  ! git -C "$L" cat-file -e "$w" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing/lib: commit ${w:0:7} (\"lib wip commit\")"*"branch wip/lib"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing/lib: untracked file notes.md"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(git -C "$L" rev-parse "refs/heads/restored/wip/lib-${w:0:7}")" = "$w" ]
  [ "$(cat "$DAEDALUS_HOME"/state/upgrade-restore/*/*-lib/w0/notes.md)" = "MY LIB NOTES" ]
}

@test "recoverable from the copy: a worktree made by hand — its branch's commit and its untracked file come back after the worktree and the branch are gone" {
  git -C "$T" worktree add -q -b exp/a "$B/hand" main
  printf 'h\n' > "$B/hand/h.txt"; git -C "$B/hand" add -A; cmt "$B/hand" -m "hand work"; h="$(git -C "$B/hand" rev-parse HEAD)"
  printf 'MY HAND NOTES\n' > "$B/hand/new.md"
  run python3 "$UP"                      # stops on the worktree made by hand; the copy is taken first
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  git -C "$T" worktree remove --force "$B/hand"; git -C "$T" branch -q -D exp/a; gone "$T"
  ! git -C "$T" cat-file -e "$h" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: commit ${h:0:7} (\"hand work\")"*"branch exp/a"*"checked out in $B/hand"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing: untracked file new.md in the worktree at $B/hand"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(git -C "$T" rev-parse "refs/heads/restored/exp/a-${h:0:7}")" = "$h" ]
  [ "$(cat "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/w1/new.md)" = "MY HAND NOTES" ]
}

@test "recoverable from the copy: an ignored file where origin now tracks that path — the upgrade stops on it, and once it is gone --restore-help brings back its exact bytes" {
  git clone -q "$B/origin.git" "$B/mk"; mkdir -p "$B/mk/out"; printf 'generated\n' > "$B/mk/out/gen.txt"
  git -C "$B/mk" add -A; cmt "$B/mk" -m "track out/gen.txt"; git -C "$B/mk" push -q origin main
  git -C "$T" fetch -q origin
  git -C "$T" checkout -q -b feat/x            # nothing origin lacks: the upgrade would put it back on main
  printf 'out/\n' >> "$T/.git/info/exclude"; mkdir -p "$T/out"; printf 'MINE, NOT GENERATED\n' > "$T/out/gen.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"(out/gen.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  rm -rf "$T/out"
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: ignored file out/gen.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(cat "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/w0/out/gen.txt)" = "MINE, NOT GENERATED" ]
}

@test "recoverable from the copy: two stash entries, cleared and pruned after the upgrade, come back into the stash in their order" {
  printf 'first\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash push -q -m "first stash"
  printf 'second\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash push -q -m "second stash"
  before="$(git -C "$T" stash list --format='%H %gs')"
  run python3 "$UP"                      # stops on the stash entries; the copy is taken first
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  git -C "$T" stash clear; gone "$T"
  [ -z "$(git -C "$T" stash list)" ]
  run python3 "$UP" --restore-help
  case "$output" in *"stash entry stash@{1}"*"first stash"*"stash entry stash@{0}"*"second stash"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(git -C "$T" stash list --format='%H %gs')" = "$before" ] || { git -C "$T" stash list --format='%H %gs'; echo "want: $before"; return 1; }
  git -C "$T" stash show -p 'stash@{1}' | grep -q '^+first'
}

@test "the copy over upgrade.snapshot_max_mb stops the upgrade before anything changes, in a sentence naming the size; with the limit raised it runs" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  head -c 3000000 /dev/urandom > "$T/big.bin"
  printf 'upgrade:\n  snapshot_max_mb: 1\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: before it changes anything in target/ it keeps a safety copy of it, and that copy would be about 3 MB, over the 1 MB limit (upgrade.snapshot_max_mb in config.yaml); the largest is target/thing/big.bin (3 MB) — raise the limit, or remove files target/ does not need (ignored build output counts), then start a session again" ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ -z "$(snaps)" ]; [ -z "$(ls -A "$DAEDALUS_HOME/state/upgrade-snapshot" 2>/dev/null)" ]
  sed -i '' 's/snapshot_max_mb: 1$/snapshot_max_mb: 10/' "$DAEDALUS_HOME/config.yaml"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a copy that cannot be written, or that fails its check, stops the upgrade before anything changes, in one sentence; no unchecked copy is left" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  : > "$DAEDALUS_HOME/state/upgrade-snapshot"           # a file where the copy's directory goes
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$(printf '%s\n' "$output" | tail -1)" in "upgrade to 0.7.0 incomplete: the safety copy of target/ it keeps before changing anything could not be written ("*") — nothing in target/ was changed; if it stops the same way again, ask this home's agent to look into the reason given") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  rm "$DAEDALUS_HOME/state/upgrade-snapshot"
  mkdir -p "$B/badgit"
  printf '#!/bin/bash\ncase " $* " in *" bundle verify "*) echo "error: the bundle is damaged" >&2; exit 1 ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" > "$B/badgit/git"
  chmod +x "$B/badgit/git"
  PATH="$B/badgit:$PATH" run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$(printf '%s\n' "$output" | tail -1)" in "upgrade to 0.7.0 incomplete: the safety copy of target/ it keeps before changing anything could not be checked ("*"the bundle is damaged"*") — nothing in target/ was changed;"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ -z "$(ls -A "$DAEDALUS_HOME/state/upgrade-snapshot" 2>/dev/null)" ]
}

@test "the board and doctor name the copy until --forget-snapshot, which refuses while anything in it is missing — naming it — and removes it once nothing is" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "shipped"
  git -C "$T" push -q origin feat/x:main
  printf 'notes.md\n' >> "$T/.git/info/exclude"; printf 'MY NOTES\n' > "$T/notes.md"
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"The upgrade has not finished"*) : ;; *) echo "$output"; return 1 ;; esac
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  s="$(snaps)"; [ -n "$s" ]
  line="A safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/$s; nothing was lost, but if anything looks missing, core/upgrade.py --restore-help lists it"
  run bash -c 'printf "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sB\",\"prompt\":\"hi\",\"transcript_path\":\"%s/sB.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/lease-board.py"'
  case "$output" in *"$line"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     a safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/$s ("*") — core/upgrade.py --restore-help lists anything in it that target/ no longer has; core/upgrade.py --forget-snapshot removes it once nothing is"*) : ;; *) echo "$output"; return 1 ;; esac
  mv "$T/notes.md" "$B/notes.aside"
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]
  case "$output" in *"ignored file notes.md"*"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/state/upgrade-snapshot/$s" ]
  mv "$B/notes.aside" "$T/notes.md"
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Removed the safety copy in state/upgrade-snapshot/$s"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(snaps)" ]
  run bash -c 'printf "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sB\",\"prompt\":\"hi\",\"transcript_path\":\"%s/sB.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/lease-board.py"'
  case "$output" in *"safety copy"*) echo "$output"; return 1 ;; esac
  run python3 "$UP" --doctor
  case "$output" in *"safety copy"*) echo "$output"; return 1 ;; esac
}

@test "a copy too slow for the session start's budget: the start says the upgrade runs in the background; the detached run only takes the copy and changes nothing in target/; the next start finishes the upgrade in the hook with no second copy" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "shipped"
  git -C "$T" push -q origin feat/x:main
  tip="$(git -C "$T" rev-parse HEAD)"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  run env UPGRADE_TEST_SNAPSHOT_SLOW=1 bash -c 'printf "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/session-start.py"'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"The upgrade to 0.7.0 needs a few minutes the first time; it runs in the background and the board will say when it is done"*) : ;; *) echo "$output"; return 1 ;; esac
  for i in $(seq 1 150); do grep -q '"running": false' "$DAEDALUS_HOME/state/upgrade-background.json" 2>/dev/null && break; sleep 0.2; done
  grep -q '"copied": true' "$DAEDALUS_HOME/state/upgrade-background.json" || { cat "$DAEDALUS_HOME/state/upgrade-background.json" "$DAEDALUS_HOME/state/upgrade.log"; return 1; }
  grep -q "a safety copy of everything in target/ is in state/upgrade-snapshot/" "$DAEDALUS_HOME/state/upgrade.log"
  [ "$(snaps | grep -c .)" = 1 ]
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]                 # the detached run changed nothing in target/
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ "$(git -C "$T" rev-parse feat/x)" = "$tip" ]
  run bash -c 'printf "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"hi\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/lease-board.py"'
  case "$output" in *"The upgrade to 0.7.0 took its safety copy of target/ in the background; it finishes at the next session start in this home"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"needs a few minutes"*) echo "$output"; return 1 ;; esac
  run bash -c 'printf "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/session-start.py"'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing was on feat/x, whose work is already on origin/main"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"is in state/upgrade-snapshot/"*) echo "a second copy: $output"; return 1 ;; esac
  [ "$(snaps | grep -c .)" = 1 ]; [ "$(cat "$DAEDALUS_HOME/state/upgraded-to")" = 0.7.0 ]
  [ "$(git -C "$T" branch --show-current)" = main ]
  run bash -c 'printf "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"hi\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/lease-board.py"'
  case "$output" in *"A safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"in the background"*) echo "$output"; return 1 ;; esac
}

@test "a run that finds target/ as the last copy found it takes no second copy; a new file since then is copied by a second copy that holds only it" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'mine\n' > "$T/x2.txt"; git -C "$T" checkout -q main; git -C "$T" checkout -q feat/x
  printf 'dirty\n' >> "$T/a.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"Daedalus has unfinished work"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(snaps | grep -c .)" = 1 ]
  run python3 "$UP"
  [ "$status" -eq 1 ]; [ "$(snaps | grep -c .)" = 1 ]
  case "$output" in *"safety copy"*) echo "$output"; return 1 ;; esac
  printf 'NEW SINCE\n' > "$T/new.md"
  run python3 "$UP"           # a file no copy holds: a second copy holds it, and only it
  [ "$status" -eq 1 ]; [ "$(snaps | grep -c .)" = 2 ] || { echo "$output"; snaps; return 1; }
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); got=[(r["label"], sorted(f["path"] for f in r["files"]), len(r["refs"])) for r in m["repos"]]; assert got == [("target/thing", ["new.md"], 0)], got' "$(newest)/manifest.json"
  git -C "$T" checkout -q -- a.txt
  run python3 "$UP"           # nothing new: the discarded change, a copy holds; what is there, a copy holds too
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }       # feat/x and x2.txt are still unfinished work
  [ "$(snaps | grep -c .)" = 2 ] || { echo "$output"; snaps; return 1; }
  run python3 "$UP" --restore-help
  case "$output" in *"holds 1 thing target/ no longer has"*"target/thing: uncommitted change to file a.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | grep -c "$NOTHING")" = 1 ] || { echo "$output"; return 1; }
}

@test "a change made in target/ while a run was going, after its copy was checked, is copied by the next run before that run changes anything" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'dirty\n' >> "$T/a.txt"
  mkdir -p "$B/cgit"
  cat > "$B/cgit/git" <<SH
#!/bin/bash
"$REAL_GIT" "\$@"; rc=\$?
case " \$* " in
  *" bundle verify "*) : > "$B/verified" ;;
  *) [ -e "$B/verified" ] && [ ! -e "$T/concurrent.md" ] && printf 'WRITTEN DURING THE RUN\n' > "$T/concurrent.md" ;;
esac
exit \$rc
SH
  chmod +x "$B/cgit/git"
  PATH="$B/cgit:$PATH" run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"Daedalus has unfinished work"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -e "$T/concurrent.md" ]; [ "$(snaps | grep -c .)" = 1 ]
  ! grep -q concurrent.md "$(newest)/manifest.json"
  run python3 "$UP"
  [ "$status" -eq 1 ]; [ "$(snaps | grep -c .)" = 2 ] || { echo "$output"; snaps; return 1; }
  grep -q '"path": "concurrent.md"' "$(newest)/manifest.json"
  run python3 "$UP"
  [ "$(snaps | grep -c .)" = 2 ] || { echo "$output"; snaps; return 1; }
  rm "$T/concurrent.md"
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: untracked file concurrent.md"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a tag deleted after the upgrade, its commit left only in HEAD's reflog, is missing: --restore-help lists it, --forget-snapshot refuses, and the printed command brings it back" {
  git -C "$T" checkout -q --detach; printf 'm\n' > "$T/m.txt"; git -C "$T" add -A; cmt "$T" -m "tagged work"
  c="$(git -C "$T" rev-parse HEAD)"; git -C "$T" tag mine; git -C "$T" checkout -q main
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '"name": "refs/tags/mine"' "$(newest)/manifest.json"
  git -C "$T" tag -d mine >/dev/null
  git -C "$T" cat-file -e "$c"           # still in the object store, but only HEAD's reflog reaches it
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: commit ${c:0:7} (\"tagged work\") — tag mine."*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"tag mine"*"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -n "$(snaps)" ]
  gone "$T"; ! git -C "$T" cat-file -e "$c" 2>/dev/null
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(git -C "$T" rev-parse "refs/heads/restored/tag-mine-${c:0:7}")" = "$c" ]
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "staged content that matches neither HEAD nor the working copy is in the copy, and comes back after a reset and gc" {
  printf 'STAGED ONLY\n' > "$T/a.txt"; git -C "$T" add a.txt; git -C "$T" show HEAD:a.txt > "$T/a.txt"
  blob="$(git -C "$T" rev-parse :a.txt)"
  run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"Daedalus has unfinished work"*) : ;; *) echo "$output"; return 1 ;; esac
  git init -q --bare "$B/empty"; git -C "$B/empty" fetch -q "$(newest)/1-thing.bundle" 'refs/*:refs/*'
  git -C "$B/empty" cat-file -e "$blob" || { echo "the staged blob is not in the bundle"; return 1; }
  git -C "$T" reset -q --hard; gone "$T"; ! git -C "$T" cat-file -e "$blob" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: commit "*"the staged, uncommitted content of a.txt in $T"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(git -C "$T" show "$(git -C "$T" for-each-ref --format='%(refname)' refs/heads/restored/ | head -1):a.txt")" = "STAGED ONLY" ]
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a reftable repository: every stash entry and every recent commit only a reflog holds are in the copy, and come back once cleared" {
  git -C "$T" refs migrate --ref-format=reftable >/dev/null 2>&1 || skip "this git cannot make a reftable repository"
  [ "$(git -C "$T" rev-parse --show-ref-format)" = reftable ]
  printf 'first\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash push -q -m "first stash"
  printf 'second\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t stash push -q -m "second stash"
  git -C "$T" checkout -q -b tmp; printf 'r\n' > "$T/r.txt"; git -C "$T" add -A; cmt "$T" -m "reflog only"
  r="$(git -C "$T" rev-parse HEAD)"; git -C "$T" checkout -q main; git -C "$T" branch -q -D tmp
  s0="$(git -C "$T" rev-parse 'stash@{0}')"; s1="$(git -C "$T" rev-parse 'stash@{1}')"
  run python3 "$UP"
  [ -n "$(snaps)" ] || { echo "$output"; return 1; }
  python3 - "$(newest)/manifest.json" "$s0" "$s1" "$r" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
refs = {(x["kind"], x["name"], x["sha"]) for x in m["repos"][0]["refs"]}
want = {("stash-entry", "stash@{0}", sys.argv[2]), ("stash-entry", "stash@{1}", sys.argv[3])}
assert want <= refs, sorted(refs)
assert any(x[0] == "reflog" and x[2] == sys.argv[4] for x in refs), sorted(refs)
PY
  git -C "$T" stash clear; gone "$T"
  run python3 "$UP" --restore-help
  case "$output" in *"stash entry stash@{1}"*"first stash"*"stash entry stash@{0}"*"second stash"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"commit ${r:0:7} (\"reflog only\") — a commit from the last 30 days of HEAD's history."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "names are kept exactly: a file whose name holds a newline, and two whose names differ only in case (in two worktrees), come back byte for byte from the commands --restore-help prints" {
  git -C "$T" worktree add -q -b exp/b "$B/hand" main
  printf 'LINE\n' > "$T/two
lines.txt"; printf 'lower\n' > "$T/notes.md"; printf 'UPPER\n' > "$B/hand/Notes.md"
  run python3 "$UP"                      # stops on the untracked files and the worktree made by hand; copy taken
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  rm "$T/two
lines.txt" "$T/notes.md" "$B/hand/Notes.md"
  run python3 "$UP" --restore-help
  [ "$(cmds "$output" | grep -c '^python3 -c ')" = 3 ] || { echo "$output"; return 1; }
  case "$output" in *"\$'w0/two\\nlines.txt'"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  R="$(echo "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing)"
  [ "$(cat "$R/w0/two
lines.txt")" = LINE ]; [ "$(cat "$R/w0/notes.md")" = lower ]; [ "$(cat "$R/w1/Notes.md")" = UPPER ]
}

# copied <sha> — some kept copy's manifest names <sha>, and that copy's bundle lists it among its heads
copied() {
  python3 - "$DAEDALUS_HOME" "$1" <<'PY'
import glob, json, os, subprocess, sys
home, sha = sys.argv[1], sys.argv[2]
for mf in glob.glob(home + "/state/upgrade-snapshot/*/manifest.json"):
    m, d = json.load(open(mf)), os.path.dirname(mf)
    for r in m["repos"]:
        if r["bundle"] and any(x["sha"] == sha for x in r["refs"]):
            out = subprocess.check_output(["git", "bundle", "list-heads", os.path.join(d, r["bundle"])], text=True)
            if any(ln.split(" ")[0] == sha for ln in out.splitlines()):
                sys.exit(0)
sys.exit(1)
PY
}
# restored <sha> — the commit is back in target/thing or in a repository the restore commands made
restored() {
  git -C "$T" cat-file -e "$1" 2>/dev/null && return 0
  local d; for d in "$DAEDALUS_HOME"/state/upgrade-restore/*/*-repo; do git -C "$d" cat-file -e "$1" 2>/dev/null && return 0; done
  return 1
}

@test "target/<repo> reached through a symlink: the copy is taken all the same and holds a commit only a branch's reflog had; after the upgrade adopts (and so deletes) that branch, --restore-help brings it back" {
  mv "$T" "$B/real-thing"; ln -s "$B/real-thing" "$T"
  git -C "$T" checkout -q -b side main; printf 's\n' > "$T/s.txt"; git -C "$T" add -A; cmt "$T" -m "side work"
  b="$(git -C "$T" rev-parse HEAD)"; git -C "$T" checkout -q main
  a="$(printf 'ONLY-IN-SIDE-REFLOG\n' | git -C "$T" -c user.email=t@x -c user.name=t commit-tree "$b^{tree}" -p "$b")"
  git -C "$T" update-ref refs/heads/side "$a"; git -C "$T" update-ref refs/heads/side "$b"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -n "$(snaps)" ] || { echo "no safety copy was taken: $output"; return 1; }
  copied "$a" || { cat "$(newest)/manifest.json"; return 1; }
  ! git -C "$T" rev-parse -q --verify refs/heads/side >/dev/null     # adopted: its name and reflog are gone
  gone "$T"; ! git -C "$T" cat-file -e "$a" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: commit ${a:0:7} (\"ONLY-IN-SIDE-REFLOG\")"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  git -C "$T" cat-file -e "$a"
}

@test "a git repository cloned inside a hand-made worktree (one under worktrees/<NN> the upgrade would clear, one outside target/) is in the copy; the upgrade stops instead of deleting it, and once the operator deletes it --restore-help brings back its commit and its files" {
  W="$DAEDALUS_HOME/worktrees/01/thing"
  git -C "$T" worktree add -q -b hotfix "$W" main
  git clone -q "$B/sub-origin.git" "$W/sub"       # ignored there: thing's .gitignore has sub/
  printf 'P\n' > "$W/sub/precious.txt"; git -C "$W/sub" add -A; cmt "$W/sub" -m "PRECIOUS unpushed"
  p="$(git -C "$W/sub" rev-parse HEAD)"; printf 'MY NESTED NOTES\n' > "$W/sub/untracked-notes.md"
  git -C "$T" worktree add -q -b exp/out "$B/out" main
  git clone -q "$B/sub-origin.git" "$B/out/sub"
  printf 'Q\n' > "$B/out/sub/q.txt"; git -C "$B/out/sub" add -A; cmt "$B/out/sub" -m "OUTSIDE unpushed"
  q="$(git -C "$B/out/sub" rev-parse HEAD)"
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"a worktree made by hand at $W, and a worktree made by hand at $B/out."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W/sub" cat-file -e "$p"; [ "$(cat "$W/sub/untracked-notes.md")" = "MY NESTED NOTES" ]
  copied "$p" || { cat "$(newest)/manifest.json"; return 1; }
  copied "$q" || { cat "$(newest)/manifest.json"; return 1; }
  grep -q '"path": "untracked-notes.md"' "$(newest)/manifest.json"
  rm -rf "$DAEDALUS_HOME/worktrees/01"; git -C "$T" worktree prune
  run python3 "$UP" --restore-help
  case "$output" in *"worktrees/01/thing/sub: commit ${p:0:7} (\"PRECIOUS unpushed\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"worktrees/01/thing/sub: untracked file untracked-notes.md"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  restored "$p" || { cat "$B/restore.sh"; return 1; }
  [ "$(cat "$DAEDALUS_HOME"/state/upgrade-restore/*/*-worktrees-01-thing-sub/w0/untracked-notes.md)" = "MY NESTED NOTES" ]
}

@test "a submodule initialized in a hand-made worktree under worktrees/<NN> (its git directory under .git/worktrees/<id>/modules): its commit is in the copy, the upgrade stops instead of deleting it, and once the worktree is gone --restore-help brings the commit back" {
  W="$DAEDALUS_HOME/worktrees/05/thing"
  git -C "$T" worktree add -q -b hotfix "$W" main
  git -C "$W" -c protocol.file.allow=always submodule add -q "$B/sub-origin.git" mod >/dev/null 2>&1
  cmt "$W" -m "add mod"
  rec="$(git -C "$W" rev-parse HEAD:mod)"
  [ -d "$(git -C "$T" rev-parse --path-format=absolute --git-common-dir)/worktrees/thing/modules/mod" ] || skip "this git keeps a worktree's submodules elsewhere"
  git -C "$W/mod" checkout -q -b subwork; printf 'S\n' > "$W/mod/s.txt"; git -C "$W/mod" add -A; cmt "$W/mod" -m "SUBMODULE-ONLY-WORK"
  s="$(git -C "$W/mod" rev-parse HEAD)"; git -C "$W/mod" checkout -q --detach "$rec"
  [ -z "$(git -C "$W" status --porcelain)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"a worktree made by hand at $W."*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W/mod" cat-file -e "$s"
  copied "$s" || { cat "$(newest)/manifest.json"; return 1; }
  rm -rf "$DAEDALUS_HOME/worktrees/05"; git -C "$T" worktree prune
  run python3 "$UP" --restore-help
  case "$output" in *"commit ${s:0:7} (\"SUBMODULE-ONLY-WORK\")"*"branch subwork"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  restored "$s" || { cat "$B/restore.sh"; return 1; }
}

@test "a shallow target: the copy records the shallow boundary and is checked against it, and once target/thing is gone --restore-help's commands bring its commits back into a new repository shallow at the same commits" {
  git clone -q "$B/origin.git" "$B/mk"
  for i in 2 3; do printf '%s\n' "$i" > "$B/mk/n$i.txt"; git -C "$B/mk" add -A; cmt "$B/mk" -m "origin $i"; done
  git -C "$B/mk" push -q origin main
  mv "$T/sub" "$B/sub-aside"; rm -rf "$T"; git clone -q --depth 1 "file://$B/origin.git" "$T"; mv "$B/sub-aside" "$T/sub"
  git -C "$T" checkout -q -b fix/in-flight; printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m "the waiting fix"
  f="$(git -C "$T" rev-parse HEAD)"; boundary="$(cat "$T/.git/shallow")"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 - "$(newest)/manifest.json" "$boundary" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
r = next(r for r in m["repos"] if r["label"] == "target/thing")
assert r.get("shallow") == sys.argv[2].split(), r.get("shallow")
PY
  rm -rf "$T"
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: commit ${f:0:7} (\"the waiting fix\")"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"shallow"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  restored "$f" || { cat "$B/restore.sh"; return 1; }
}

# moved_off_today — branch experiment: two commits B, A made 45 days ago (so are their reflog entries), then today
# moved back to B without a checkout: A is held only as the old value of today's entry. Sets $a.
moved_off_today() {
  local wt="$B/exp" old="@$(( $(date +%s) - 45 * 86400 )) +0000"
  git -C "$T" worktree add -q -b experiment "$wt" refs/remotes/origin/main
  printf 'b\n' > "$wt/b.txt"; git -C "$wt" add -A; GIT_COMMITTER_DATE="$old" GIT_AUTHOR_DATE="$old" cmt "$wt" -m "B kept"
  printf 'a\n' > "$wt/a2.txt"; git -C "$wt" add -A; GIT_COMMITTER_DATE="$old" GIT_AUTHOR_DATE="$old" cmt "$wt" -m "A dropped today"
  a="$(git -C "$wt" rev-parse HEAD)"; git -C "$T" worktree remove "$wt"
  git -C "$T" branch -f experiment experiment~1
}

@test "a commit a reflog entry from the last 30 days holds only as the value before it (the branch moved off it today, its own entry older): in the copy; after adopt deletes the branch and gc runs, --restore-help lists it, --forget-snapshot refuses, and the printed command brings it back" {
  moved_off_today
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  copied "$a" || { cat "$(newest)/manifest.json"; return 1; }
  gone "$T"; ! git -C "$T" cat-file -e "$a" 2>/dev/null
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"commit ${a:0:7} (\"A dropped today\")"*"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  git -C "$T" cat-file -e "$a"
  run python3 "$UP" --restore-help
  case "$output" in *"${a:0:7}"*) echo "$output"; return 1 ;; esac
}

@test "a file with the same name, size and time as one a kept copy holds, but other content in another worktree, is copied again — never skipped as already held" {
  printf '*.local\n' >> "$T/.git/info/exclude"; printf 'AAAA\n' > "$T/key.local"; printf 'edit\n' >> "$T/a.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"Daedalus has unfinished work"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(snaps | wc -l | tr -d ' ')" = 1 ]
  git -C "$T" checkout -q a.txt
  W="$DAEDALUS_HOME/worktrees/01/thing"; git -C "$T" worktree add -q -b hotfix "$W" main
  printf 'BBBB\n' > "$W/key.local"; touch -r "$T/key.local" "$W/key.local"
  run python3 "$UP"
  found=0
  for t in "$DAEDALUS_HOME"/state/upgrade-snapshot/*/*.tar; do tar -xOf "$t" 2>/dev/null | grep -q BBBB && found=1; done
  [ "$found" = 1 ] || { echo "$output"; return 1; }
  [ "$(cat "$W/key.local" 2>/dev/null)" = BBBB ] || { echo "the worktree's ignored file was deleted: $output"; return 1; }
}

@test "two hard-linked ignored files are each copied whole: the copy checks, the upgrade completes, and both come back with their content" {
  printf '*.local\n' >> "$T/.git/info/exclude"; printf 'same\n' > "$T/a.local"; ln "$T/a.local" "$T/b.local"
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for f in a.local b.local; do [ "$(tar -xOf "$(newest)/1-thing.tar" "w0/$f")" = same ]; done
}

@test "a reftable repository: a commit held only as the value before a reflog entry from the last 30 days is in the copy (git is asked for it; there is no logs/ to read)" {
  git -C "$T" refs migrate --ref-format=reftable >/dev/null 2>&1 || skip "this git cannot make a reftable repository"
  moved_off_today
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  copied "$a" || { cat "$(newest)/manifest.json"; return 1; }
}

@test "a commit only a parked branch's reflog holds, made after a copy was taken with every ref moved back: the next run copies it before adopt deletes that branch; --restore-help lists it, --forget-snapshot refuses, the printed command brings it back" {
  git -C "$T" checkout -q -b park/y; printf 'y\n' > "$T/y.txt"; git -C "$T" add -A; cmt "$T" -m "parked work"
  git -C "$T" checkout -q main
  shim_git
  KILL_AT=1 PATH="$B/shim:$PATH" run python3 "$UP"
  [ "$status" -eq 137 ] || { echo "$output"; return 1; }
  [ "$(snaps | grep -c .)" = 1 ]
  git -C "$T" worktree add -q "$B/exp" park/y           # an experiment, undone: no ref moves, park/y's reflog holds D
  printf 'D\n' > "$B/exp/d.txt"; git -C "$B/exp" add -A; cmt "$B/exp" -m "EXPERIMENT D"
  d="$(git -C "$B/exp" rev-parse HEAD)"; git -C "$B/exp" reset -q --hard HEAD~1; git -C "$T" worktree remove "$B/exp"
  git -C "$T" log -g --format=%H park/y | grep -q "^$d$"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(snaps | grep -c .)" = 2 ] || { echo "no second copy: $output"; return 1; }
  copied "$d" || { cat "$(newest)/manifest.json"; return 1; }
  ! git -C "$T" rev-parse -q --verify refs/heads/park/y >/dev/null      # adopted: its name and reflog are gone
  gone "$T"; ! git -C "$T" cat-file -e "$d" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: commit ${d:0:7} (\"EXPERIMENT D\")"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"${d:0:7}"*"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  git -C "$T" cat-file -e "$d"
}

@test "git's record of a merge in progress in a hand-made worktree is checked by --restore-help: once it is gone it is listed with the command that brings it back, and --forget-snapshot refuses" {
  git -C "$T" branch other; git -C "$T" worktree add -q -b mine "$B/hand" main
  printf 'o\n' > "$B/o.txt"; git -C "$T" checkout -q other; cp "$B/o.txt" "$T/o.txt"; git -C "$T" add -A; cmt "$T" -m other
  o="$(git -C "$T" rev-parse other)"; git -C "$T" checkout -q main
  git -C "$B/hand" -c user.email=t@x -c user.name=t merge -q --no-commit --no-ff -s ours other
  git -C "$B/hand" rev-parse -q --verify MERGE_HEAD >/dev/null
  run python3 "$UP"                      # stops on the worktree made by hand; the copy is taken first
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -q '"path": "MERGE_HEAD"' "$(newest)/manifest.json"
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$B/hand" merge --abort
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"     # as if the upgrade had finished: forget judges the copy alone
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: git's record of a merge in progress (MERGE_HEAD, in the worktree at $B/hand)"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"MERGE_HEAD"*"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --restore-help
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  [ "$(cat "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/git/w1/MERGE_HEAD)" = "$o" ]
}

@test "a worktree left under worktrees/<NN> by a cut-off start, clean but in the middle of a bisect: the upgrade stops naming it as a worktree made by hand, never removes it, and the bisect stays" {
  git -C "$T" checkout -q -b stray; printf 's\n' > "$T/s.txt"; git -C "$T" add -A; cmt "$T" -m "stray work"
  git -C "$T" checkout -q main
  mkdir -p "$DAEDALUS_HOME/worktrees/05"; git -C "$T" worktree add -q "$DAEDALUS_HOME/worktrees/05/thing" stray
  git -C "$DAEDALUS_HOME/worktrees/05/thing" bisect start -q 2>/dev/null || git -C "$DAEDALUS_HOME/worktrees/05/thing" bisect start >/dev/null
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"a worktree made by hand at $DAEDALUS_HOME/worktrees/05/thing."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/worktrees/05/thing" ]; [ -n "$(git -C "$DAEDALUS_HOME/worktrees/05/thing" bisect log 2>/dev/null)" ]
}

@test "a tracked file whose bytes a clean filter hides from git (status clean): in the copy, the upgrade stops before the checkout would replace it, and once replaced --restore-help brings its exact bytes back" {
  git -C "$T" checkout -q -b fix/in-flight
  printf 'notes.txt filter=strip\n' > "$T/.gitattributes"; printf 'v1\n' > "$T/notes.txt"
  git -C "$T" config filter.strip.clean "sed '/^LOCAL/d'"; git -C "$T" config filter.strip.smudge cat
  git -C "$T" add -A; cmt "$T" -m notes
  printf 'v1\nLOCAL hours of output\n' > "$T/notes.txt"; git -C "$T" add notes.txt
  [ -z "$(git -C "$T" status --porcelain)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"1 changed file git status does not show (notes.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; grep -q '^LOCAL hours' "$T/notes.txt"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); f=[f for f in m["repos"][0]["files"] if f["path"] == "notes.txt"]; assert f and f[0]["kind"] == "changed", m["repos"][0]["files"]' "$(newest)/manifest.json"
  cp "$T/notes.txt" "$B/notes.aside"; rm "$T/notes.txt"; git -C "$T" checkout -q -- notes.txt
  ! grep -q LOCAL "$T/notes.txt"
  run python3 "$UP" --restore-help
  case "$output" in *"target/thing: uncommitted change to file notes.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  cmp "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/w0/notes.txt "$B/notes.aside"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "file names holding [ ] * ? or a backslash: the commands --restore-help prints bring back exactly that file, and only it" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  for n in 'a[1].txt' 'b*.txt' 'q?.txt' 'back\slash.txt' 'bX.txt'; do printf 'BYTES OF %s\n' "$n" > "$T/$n"; done
  run python3 "$UP"                      # stops on the unsaved files; the copy is taken first
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  for n in 'a[1].txt' 'b*.txt' 'q?.txt' 'back\slash.txt'; do rm "$T/$n"; done
  run python3 "$UP" --restore-help
  case "$output" in *"holds 4 things"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  d="$(echo "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/w0)"
  for n in 'a[1].txt' 'b*.txt' 'q?.txt' 'back\slash.txt'; do [ "$(cat "$d/$n")" = "BYTES OF $n" ] || { ls -la "$d"; return 1; }; done
  [ ! -e "$d/bX.txt" ] || { echo "a glob pulled out bX.txt too"; return 1; }
  [ "$(ls -1 "$d" | wc -l | tr -d ' ')" = 4 ]
}

@test "two copies (the second building on the first) and a repository that is gone: every printed command runs, in order, into one new repository that holds the commits of both" {
  printf 'dirty\n' >> "$T/a.txt"
  run python3 "$UP"
  [ "$status" -eq 1 ]; case "$output" in *"Daedalus has unfinished work"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(snaps | grep -c .)" = 1 ]
  s1="$(git -C "$T/sub" rev-parse HEAD)"
  git -C "$T" add -A; cmt "$T" -m "the edit"; git -C "$T/sub" -c user.email=t@x -c user.name=t commit -q --allow-empty -m "sub later"
  s2="$(git -C "$T/sub" rev-parse HEAD)"
  sleep 1
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(snaps | grep -c .)" = 2 ] || { echo "$output"; snaps; return 1; }
  rm -rf "$T/sub"
  run python3 "$UP" --restore-help
  case "$output" in *"${s1:0:7}"*"${s2:0:7}"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"
  set -e; while IFS= read -r line; do bash -c "$line" || { echo "failed: $line"; cat "$B/restore.sh"; return 1; }; done < "$B/restore.sh"
  restored "$s1"; restored "$s2"
  [ "$(ls -d "$DAEDALUS_HOME"/state/upgrade-restore/*/*sub*-repo | wc -l | tr -d ' ')" = 1 ]
}

@test "while the copy is taken in the background, the session start that handed it over numbers no window: nothing in target/ changes before the copy is checked, lease.sh create and claim refuse until then, and the next start numbers the window" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "shipped"
  git -C "$T" push -q origin feat/x:main
  mkdir -p "$DAEDALUS_HOME/state/leases"                  # an earlier start got as far as step 1
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  shim_git
  mkdir -p "$B/hold"
  cat > "$B/hold/git" <<SH
#!/bin/bash
case " \$* " in *" bundle create "*) while [ ! -e "$B/go" ]; do sleep 0.1; done ;; esac
exec "$B/shim/git" "\$@"
SH
  chmod +x "$B/hold/git"
  run env PATH="$B/hold:$PATH" UPGRADE_TEST_SNAPSHOT_SLOW=1 bash -c 'printf "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/session-start.py"'
  [ "$status" -eq 0 ] || { echo "$output"; : > "$B/go"; return 1; }
  case "$output" in *"runs in the background"*) : ;; *) echo "$output"; : > "$B/go"; return 1 ;; esac
  case "$output" in *"You are window"*) echo "$output"; : > "$B/go"; return 1 ;; esac
  case "$output" in *"no window is made in target/ until the upgrade has its safety copy of it"*) : ;; *) echo "$output"; : > "$B/go"; return 1 ;; esac
  ! cut -f2 "$B/git.log" | grep -q M || { cat "$B/git.log"; : > "$B/go"; return 1; }
  run env DAEDALUS_SESSION_ID=s1 "$DAEDALUS_HOME/core/lease.sh" create
  [ "$status" -ne 0 ]; case "$output" in *"safety copy"*) : ;; *) echo "$output"; : > "$B/go"; return 1 ;; esac
  run env DAEDALUS_SESSION_ID=s1 "$DAEDALUS_HOME/core/lease.sh" claim 01
  [ "$status" -ne 0 ]; case "$output" in *"lease.sh claim\` works once"*) : ;; *) echo "$output"; : > "$B/go"; return 1 ;; esac
  : > "$B/go"
  for i in $(seq 1 150); do grep -q '"running": false' "$DAEDALUS_HOME/state/upgrade-background.json" 2>/dev/null && break; sleep 0.2; done
  grep -q '"copied": true' "$DAEDALUS_HOME/state/upgrade-background.json" || { cat "$DAEDALUS_HOME/state/upgrade.log"; return 1; }
  ! cut -f2 "$B/git.log" | grep -q M || { cat "$B/git.log"; return 1; }
  run bash -c 'printf "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/session-start.py"'
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: complete."*"You are window"*) : ;; *) echo "$output"; return 1 ;; esac
}

# manifest_has <py expr over r (the repo entry for target/thing)> — a check on the newest copy's manifest
manifest_has() {
  python3 - "$(newest)/manifest.json" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
r = [x for x in m["repos"] if x["label"] == "target/thing"][0]
assert eval(sys.argv[2]), json.dumps(r, indent=1)
PY
}

@test "a worktree made by hand under worktrees/ and moved with mv in the middle of a rebase, with staged-only content and a ref of its own: the copy holds all three; the upgrade keeps git's record of it (the moved checkout still works, its branch is not adopted); once the record is gone --restore-help lists them and its commands bring them back" {
  W="$DAEDALUS_HOME/worktrees/hotfix"
  git -C "$T" worktree add -q -b hot "$W" main
  for i in 1 2 3; do printf 'h%s\n' $i > "$W/h$i.txt"; git -C "$W" add -A; cmt "$W" -m "hot $i"; done
  GIT_SEQUENCE_EDITOR="sed -i '' -e '2s/^pick/edit/'" git -C "$W" -c user.email=t@x -c user.name=t rebase -q -i HEAD~3 >/dev/null 2>&1
  [ -d "$(git -C "$W" rev-parse --absolute-git-dir)/rebase-merge" ]
  printf 'STAGED ONLY\n' > "$W/staged.txt"; git -C "$W" add staged.txt; printf 'later\n' > "$W/staged.txt"
  stb="$(git -C "$W" rev-parse :staged.txt)"
  keep="$(echo kept | git -C "$W" -c user.email=t@x -c user.name=t commit-tree 'HEAD^{tree}')"; git -C "$W" update-ref refs/worktree/keep "$keep"
  mv "$W" "$B/hotfix-moved"
  run python3 "$UP"                      # stops on the worktree made by hand; the copy is taken first
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  manifest_has "any(x['kind'] == 'index' and any(b == '$stb' for _, b in x['blobs']) for x in r['refs'])"
  manifest_has "any(x['name'] == 'refs/worktree/keep' and x['sha'] == '$keep' for x in r['refs'])"
  manifest_has "any(g['path'].startswith('rebase-merge/') for g in r['git_state'] if g['w'] > 0)"
  # git's record of it is kept: the moved checkout still works, mid-rebase, with its staged content
  [ "$(git -C "$B/hotfix-moved" rev-parse :staged.txt)" = "$stb" ]
  [ -d "$(git -C "$B/hotfix-moved" rev-parse --absolute-git-dir)/rebase-merge" ]
  git -C "$T" rev-parse -q --verify refs/heads/hot >/dev/null        # not adopted while its rebase is in progress
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$T" worktree prune; gone "$T"
  printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"     # as if the upgrade had finished: forget judges the copy alone
  ! git -C "$T" cat-file -e "$keep" 2>/dev/null; ! git -C "$T" cat-file -e "$stb" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"the staged, uncommitted content of staged.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"git's record of a rebase in progress (rebase-merge/"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"${keep:0:7}"*"ref refs/worktree/keep"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --restore-help
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  git -C "$T" cat-file -e "$keep"; git -C "$T" cat-file -e "$stb"
  ls "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/git/w*/rebase-merge/ >/dev/null
}

@test "a worktree made by hand under worktrees/<NN> whose directory a cut-off git worktree move took elsewhere, with staged content and a merge in progress: the copy holds both; the upgrade stops instead of removing its record, naming git worktree repair; once the record is gone --restore-help lists both" {
  git -C "$T" branch side; git -C "$T" checkout -q side; printf 's\n' > "$T/s.txt"; git -C "$T" add -A; cmt "$T" -m side
  git -C "$T" checkout -q main
  mkdir -p "$DAEDALUS_HOME/worktrees/03"; W="$DAEDALUS_HOME/worktrees/03/thing"
  git -C "$T" worktree add -q -b hotfix "$W" main
  printf 'hot\n' > "$W/h.txt"; git -C "$W" add -A; cmt "$W" -m hot
  git -C "$W" -c user.email=t@x -c user.name=t merge -q --no-commit --no-ff side
  printf 'STAGED-ONLY\n' > "$W/a.txt"; git -C "$W" add a.txt; printf 'WORKING\n' > "$W/a.txt"
  stb="$(git -C "$W" rev-parse :a.txt)"; adm="$(git -C "$W" rev-parse --absolute-git-dir)"; mh="$(cat "$adm/MERGE_HEAD")"
  mkdir -p "$B/elsewhere"; mv "$W" "$B/elsewhere/thing"
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"a worktree made by hand at $W (its directory is gone)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -f "$adm/MERGE_HEAD" ]; [ "$(git -C "$B/elsewhere/thing" rev-parse :a.txt)" = "$stb" ]
  manifest_has "any(x['kind'] == 'index' and any(b == '$stb' for _, b in x['blobs']) for x in r['refs'])"
  manifest_has "any(g['path'] == 'MERGE_HEAD' and g['w'] > 0 for g in r['git_state'])"
  git -C "$T" worktree prune; gone "$T"
  [ ! -d "$adm" ]; ! git -C "$T" cat-file -e "$stb" 2>/dev/null
  run python3 "$UP" --restore-help
  case "$output" in *"the staged, uncommitted content of a.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"git's record of a merge in progress (MERGE_HEAD"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  git -C "$T" cat-file -e "$stb"
  [ "$(cat "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing/git/w*/MERGE_HEAD)" = "$mh" ]
}

@test "an edit git's stat check cannot see (core.trustctime false; same size, inode and mtime): in the copy as a change, and the upgrade stops before the checkout back to the trunk would replace it" {
  git -C "$T" checkout -q -b fix/in-flight; printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m f
  git -C "$T" config core.trustctime false
  touch -t 202601010000 "$T/f.txt"; git -C "$T" update-index --refresh >/dev/null; sleep 1
  cp -p "$T/f.txt" "$B/ref"; printf 'g\n' > "$T/f.txt"; touch -r "$B/ref" "$T/f.txt"
  [ -z "$(git -C "$T" status --porcelain)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"1 changed file git status does not show (f.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$T/f.txt")" = g ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  manifest_has "any(f['path'] == 'f.txt' and f['kind'] == 'changed' for f in r['files'])"
}

@test "an untracked directory holding only a .git git cannot read, where origin now tracks a file: in the copy, and the upgrade stops instead of letting the checkout delete it" {
  trunk_moves scratch "the trunk's own scratch file"
  git -C "$T" checkout -q -b fix/in-flight; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  git init -q "$T/scratch"; printf 'mine\n' > "$T/scratch/m"; git -C "$T/scratch" add m; cmt "$T/scratch" -m "nested-only commit"
  rm "$T/scratch/m"; printf 'garbage\n' > "$T/scratch/.git/HEAD"
  [ -z "$(git -C "$T" status --porcelain --ignored | grep scratch)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"scratch"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$T/scratch/.git/objects" ]; [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]
  manifest_has "any(f['path'] == 'scratch/.git/HEAD' for f in r['files'])"
  manifest_has "sum(1 for f in r['files'] if f['path'].startswith('scratch/.git/objects/')) >= 3"
}

@test "a pre-push hook carrying Daedalus's mark that the operator extended with checks of their own is kept beside the new one, named in the step's line; one that is only another home's copy of the shim is replaced" {
  hp="$T/.git/hooks/pre-push"; mkdir -p "$T/.git/hooks"
  printf '#!/bin/sh\n# daedalus pre-push hook (core/prepush.py)\n# MY OWN CHECKS\n./run-my-lint.sh || exit 1\n' > "$hp"; chmod +x "$hp"
  python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import prepush; from pathlib import Path; open(sys.argv[2], "w").write(prepush.shim(Path("/elsewhere/home")))' "$DAEDALUS_HOME/core" "$T/sub/.git/hooks/pre-push"
  chmod +x "$T/sub/.git/hooks/pre-push"
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"pre-push.before-daedalus"*) : ;; *) echo "$output"; return 1 ;; esac
  grep -q "$DAEDALUS_HOME/core/prepush.py" "$hp"; ! grep -q "MY OWN CHECKS" "$hp"
  grep -l "MY OWN CHECKS" "$T"/.git/hooks/pre-push.before-daedalus-* >/dev/null
  grep -q "$DAEDALUS_HOME/core/prepush.py" "$T/sub/.git/hooks/pre-push"
  [ -z "$(ls "$T/sub/.git/hooks/" | grep before-daedalus)" ]
}

# --- release-candidate red team -------------------------------------------------------------------------------

@test "a file converted through git's older crlf attribute, its CRLF bytes in no commit (status clean after git add): the upgrade stops before the checkout back to the trunk would replace it, and those bytes are in the copy (release-candidate red team, finding 2)" {
  git -C "$T" checkout -q -b fix/in-flight
  printf '*.txt crlf\n' > "$T/.gitattributes"; printf 'alpha\nbeta\ngamma from the branch\n' > "$T/notes.txt"
  git -C "$T" add -A; cmt "$T" -m notes
  printf 'alpha\r\nbeta\r\ngamma from the branch\r\n' > "$T/notes.txt"; cp "$T/notes.txt" "$B/crlf"
  git -C "$T" add notes.txt 2>/dev/null
  [ -z "$(git -C "$T" status --porcelain)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"1 changed file git status does not show (notes.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = fix/in-flight ]; cmp "$T/notes.txt" "$B/crlf"
  sum="$(shasum -a 256 "$B/crlf" | cut -d' ' -f1)"
  manifest_has "any(f['path'] == 'notes.txt' and f['kind'] == 'changed' and f['sha256'] == '$sum' for f in r['files'])"
}

@test "files whose bytes on disk are exactly their committed blob — checked out before origin added an eol=crlf rule for them, or before a filter was set up — are no hidden change: the upgrade does not stop on them and completes (release-candidate red team, finding 3)" {
  printf '@echo off\nrun\n' > "$T/run.bat"
  for i in 1 2 3 4 5 6 7; do printf 'data %s\n' "$i" > "$T/f$i.dat"; done
  git -C "$T" add -A; cmt "$T" -m files
  printf '*.bat text eol=crlf\n*.dat filter=big\n' > "$T/.gitattributes"; git -C "$T" add .gitattributes; cmt "$T" -m rules
  git -C "$T" push -q origin main
  git -C "$T" config filter.big.clean cat; git -C "$T" config filter.big.smudge 'tr a-z A-Z'
  [ -z "$(git -C "$T" status --porcelain)" ]; [ "$(cat "$T/run.bat")" = "$(printf '@echo off\nrun')" ]
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"git status does not show"*) echo "$output"; return 1 ;; esac
}

@test "the stop on bytes a line-ending conversion hides prints a command that clears it: more than five files, every one named in it (no placeholder); run as printed, the next run goes through (release-candidate red team, finding 4)" {
  git -C "$T" checkout -q -b fix/in-flight
  printf '*.txt text\n' > "$T/.gitattributes"; mkdir -p "$T/d d"
  for f in n1 n2 n3 n4 n5 "d d/n 6"; do printf 'a\nb\n' > "$T/$f.txt"; done
  git -C "$T" add -A; cmt "$T" -m notes
  for f in n1 n2 n3 n4 n5 "d d/n 6"; do printf 'a\r\nb\r\n' > "$T/$f.txt"; done
  git -C "$T" add -A 2>/dev/null
  [ -z "$(git -C "$T" status --porcelain)" ]
  run python3 "$UP"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"6 changed files git status does not show (d d/n 6.txt, n1.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  run bash "$DAEDALUS_HOME/core/lease.sh" adopt --all-unfinished </dev/null
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  case "$output" in *"in files whose line endings or contents git changes when it saves them (d d/n 6.txt, n1.txt"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"<file>"*) echo "$output"; return 1 ;; esac
  cmd="$(printf '%s\n' "$output" | sed -n "s/.*put the committed version back (\(.*\)), then say 'pick it up' again.*/\1/p")"
  [ -n "$cmd" ] || { echo "$output"; return 1; }
  sh_="$(command -v zsh || command -v sh)"
  (cd "$DAEDALUS_HOME" && "$sh_" -c "$cmd") || { echo "$cmd"; return 1; }
  ! grep -q $'\r' "$T/n1.txt" "$T/d d/n 6.txt"
  up_done
  [ "$status" -eq 0 ] || { echo "$cmd"; echo "$output"; return 1; }
}

# --- release-candidate red team 2 -----------------------------------------------------------------------------

@test "a checkout under core.autocrlf true, nothing touched (every text file CRLF on disk, as a checkout writes it): the upgrade completes, and the copy holds none of them as a change (release-candidate red team 2, finding 5)" {
  git -C "$T" checkout -q -b fix/in-flight
  printf 'a\nb\n' > "$T/notes.txt"; printf 'r\n' > "$T/readme.md"; printf '*.md text\n' > "$T/.gitattributes"
  git -C "$T" add -A; cmt "$T" -m notes
  git -C "$T" config core.autocrlf true; git -C "$T" rm -q -r --cached .; git -C "$T" reset -q --hard
  grep -q $'\r' "$T/notes.txt"; grep -q $'\r' "$T/readme.md"; [ -z "$(git -C "$T" status --porcelain)" ]
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
  manifest_has "not any(f['path'] in ('notes.txt', 'readme.md') for f in r['files'])"
}

@test "the check of a checkout cut off part-way counts a file committed with CRLF under text=auto, as the checkout wrote it, as the commit's — and an edited one as neither (release-candidate red team 2, finding 6)" {
  R="$B/crlf-repo"; git init -q -b main "$R"
  printf '@echo off\r\necho hi\r\n' > "$R/run.bat"; printf 'x\n' > "$R/x.txt"; git -C "$R" add -A; cmt "$R" -m one
  printf '* text=auto\n' > "$R/.gitattributes"; git -C "$R" add .gitattributes; cmt "$R" -m two
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import upgrade; from pathlib import Path; print(upgrade._neither(Path(sys.argv[2]), "HEAD~1", "HEAD", ["run.bat", "x.txt"]))' "$DAEDALUS_HOME/core" "$R"
  [ "$output" = "[]" ] || { echo "$output"; return 1; }
  printf '@echo off\r\necho bye\r\n' > "$R/run.bat"
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import upgrade; from pathlib import Path; print(upgrade._neither(Path(sys.argv[2]), "HEAD~1", "HEAD", ["run.bat", "x.txt"]))' "$DAEDALUS_HOME/core" "$R"
  [ "$output" = "['run.bat']" ] || { echo "$output"; return 1; }
}

@test "with core.trustctime false, an edit of the same size with its mtime put back to a file committed with CRLF under text=auto is still found, and the untouched one beside it is not (release-candidate red team 2, finding 6)" {
  git -C "$T" checkout -q -b fix/in-flight
  printf '@echo off\r\necho hi\r\n' > "$T/run.bat"; printf '@echo off\r\necho hi\r\n' > "$T/two.bat"; git -C "$T" add -A; cmt "$T" -m bats
  printf '* text=auto\n' > "$T/.gitattributes"; git -C "$T" add .gitattributes; cmt "$T" -m normalize
  git -C "$T" config core.trustctime false
  touch -t 202601010000 "$T/two.bat"; git -C "$T" update-index --refresh >/dev/null; sleep 1
  cp -p "$T/two.bat" "$B/ref"; printf '@echo off\r\necho yo\r\n' > "$T/two.bat"; touch -r "$B/ref" "$T/two.bat"
  [ -z "$(git -C "$T" status --porcelain)" ]
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import leaselib as ll; from pathlib import Path; print(ll.stat_blind_edits(Path(sys.argv[2])))' "$DAEDALUS_HOME/core" "$T"
  [ "$output" = "['two.bat']" ] || { echo "$output"; return 1; }
}

@test "a session start whose check of target/ against the kept copy never fits its budget: once a run in the background has taken the copy, the next start does not hand off again or say 'the first time' — it stops naming python3 core/upgrade.py, which finishes the upgrade (release-candidate red team 3, findings 4 and 7)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$(live_pid)"; registry_entry "$P" s1 interactive cli daedalus-xx
  start='printf "{\"hook_event_name\":\"SessionStart\",\"session_id\":\"s1\",\"source\":\"startup\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/session-start.py"'
  run env UPGRADE_TEST_SNAPSHOT_SLOW=1 bash -c "$start"
  case "$output" in *"needs a few minutes the first time"*) : ;; *) echo "$output"; return 1 ;; esac
  for i in $(seq 1 150); do grep -q '"running": false' "$DAEDALUS_HOME/state/upgrade-background.json" 2>/dev/null && break; sleep 0.2; done
  grep -q '"copied": true' "$DAEDALUS_HOME/state/upgrade-background.json"
  bg="$(cat "$DAEDALUS_HOME/state/upgrade-background.json")"
  for n in 2 3; do
    run env UPGRADE_TEST_SNAPSHOT_SLOW=1 bash -c "$start"
    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    case "$output" in *"needs a few minutes"*|*"Upgrade to 0.7.0: complete."*) echo "start $n: $output"; return 1 ;; esac
    case "$output" in *"upgrade to 0.7.0 incomplete:"*"run python3 core/upgrade.py once from a terminal in this home"*) : ;; *) echo "start $n: $output"; return 1 ;; esac
    [ "$(cat "$DAEDALUS_HOME/state/upgrade-background.json")" = "$bg" ] || { echo "start $n handed off again"; return 1; }
  done
  run bash -c 'printf "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"s1\",\"prompt\":\"hi\",\"transcript_path\":\"%s/s1.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/lease-board.py"'
  case "$output" in *"run python3 core/upgrade.py once from a terminal in this home"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  up_done
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
}

# pscratch <id> <records...> — a promotion under state/promote/<id>/ with its scratch worktree of target/thing
# (detached at HEAD, as cut_scratch makes it) and the named record files
pscratch() {
  cp "$SRC/promote.py" "$DAEDALUS_HOME/core/"
  local d="$DAEDALUS_HOME/state/promote/$1"; shift
  mkdir -p "$d"; git -C "$T" worktree add -q --detach "$d/thing" HEAD
  printf '{}\n' > "$d/prepared.json"
  for r in "$@"; do : > "$d/$r"; done
}

@test "the upgrade removes the scratch of every pushed promotion before it estimates the safety copy, in one line naming them; a prepared-not-pushed one, one whose confirm lock is held, and every record are kept; --dry-run says it would and removes nothing (update-command Decision 10a)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  P="$DAEDALUS_HOME/state/promote"
  pscratch 01-20261015-125249-d0b pushed
  pscratch 04-20261015-160828-526 pushed announced
  pscratch 02-20261015-130000-aaa
  pscratch 03-20261015-140000-bbb pushed
  # the two pushed scratches hold 6 MB the copy would otherwise count, over the 2 MB limit
  head -c 3000000 /dev/urandom > "$P/01-20261015-125249-d0b/thing/gate.out"
  head -c 3000000 /dev/urandom > "$P/04-20261015-160828-526/thing/gate.out"
  printf 'upgrade:\n  snapshot_max_mb: 2\n' >> "$DAEDALUS_HOME/config.yaml"
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f.fileno(), fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(120)' \
    "$P/03-20261015-140000-bbb/.confirm.lock" "$B/held" 3>&- </dev/null >/dev/null 2>&1 &
  HOLDER=$!
  for _ in $(seq 50); do [ -e "$B/held" ] && break; python3 -c 'import time; time.sleep(0.1)'; done
  [ -e "$B/held" ]

  run python3 "$UP" --dry-run
  case "$output" in *"Upgrade to 0.7.0: would remove the promote scratch of 2 pushed promotions (01-20261015-125249-d0b, 04-20261015-160828-526); their records are kept."*) : ;; *) kill "$HOLDER"; echo "$output"; return 1 ;; esac
  for id in 01-20261015-125249-d0b 04-20261015-160828-526 02-20261015-130000-aaa 03-20261015-140000-bbb; do
    [ -d "$P/$id/thing" ] || { kill "$HOLDER"; echo "dry run removed $id"; return 1; }
  done

  up_done
  kill "$HOLDER"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: removed the promote scratch of 2 pushed promotions (01-20261015-125249-d0b, 04-20261015-160828-526); their records are kept."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"over the 2 MB limit"*) echo "$output"; return 1 ;; esac
  [ "$(printf '%s\n' "$output" | grep -c 'promote scratch')" -eq 1 ] || { echo "$output"; return 1; }
  [ ! -e "$P/01-20261015-125249-d0b/thing" ]; [ ! -e "$P/04-20261015-160828-526/thing" ]
  [ -f "$P/01-20261015-125249-d0b/prepared.json" ]; [ -f "$P/01-20261015-125249-d0b/pushed" ]
  [ -f "$P/04-20261015-160828-526/pushed" ]; [ -f "$P/04-20261015-160828-526/announced" ]
  [ -d "$P/02-20261015-130000-aaa/thing" ]; [ -d "$P/03-20261015-140000-bbb/thing" ]
  ! git -C "$T" worktree list --porcelain | grep -q -e 01-20261015 -e 04-20261015
  git -C "$T" worktree list --porcelain | grep -q 02-20261015
}

# est — the MB figure of the dry run's "would keep a safety copy ... (about N MB ...)" line; 0 for "under 1 MB"
est() { printf '%s\n' "$1" | sed -n 's/.*would keep a safety copy of .* (about \([0-9]*\) MB, in state.*/\1/p; s/.*would keep a safety copy of .* (about under 1 MB, in state.*/0/p'; }

@test "the second machine's shape: 9+ GB of venvs and node_modules a lockfile rebuilds are not counted; with the leftover clone the estimate is 3840-3904 MB and the stop names the clone first among the largest; without it, under 64 MB (update-command Decision 8)" {
  second_machine_shape
  printf 'upgrade:\n  snapshot_max_mb: 2048\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP" --dry-run
  n="$(est "$output")"
  [ -n "$n" ] && [ "$n" -ge 3840 ] && [ "$n" -le 3904 ] || { echo "estimate: $n"; echo "$output"; return 1; }
  stop="$(printf '%s\n' "$output" | grep '^would stop: ')" || { echo "$output"; return 1; }
  case "$stop" in "would stop: upgrade to 0.7.0 incomplete: before it changes anything in target/ it keeps a safety copy of it, and that copy would be about $n MB, over the 2048 MB limit (upgrade.snapshot_max_mb in config.yaml); the largest is target/thing/extensions/open-design/open-design-plainclone-unused (3840 MB) — raise the limit"*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i '' 's/snapshot_max_mb: 2048$/snapshot_max_mb: 10000/' "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP" --dry-run
  [ "$(est "$output")" = "$n" ] || { echo "$output"; return 1; }
  case "$output" in *"over the "*" MB limit"*) echo "$output"; return 1 ;; esac
  rm -rf "$T/extensions/open-design/open-design-plainclone-unused"
  sed -i '' 's/snapshot_max_mb: 10000$/snapshot_max_mb: 2048/' "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP" --dry-run
  n="$(est "$output")"
  [ -n "$n" ] && [ "$n" -lt 64 ] || { echo "estimate: $n"; echo "$output"; return 1; }
  case "$output" in *"over the "*" MB limit"*) echo "$output"; return 1 ;; esac
}

@test "a .venv with no lockfile beside it and a node_modules with none are copied; a tracked file changed under a skipped directory is copied too (update-command Decision 8)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"
  mkdir -p "$T/loose/.venv" "$T/loose/node_modules/a" "$T/eng/.venv/bin"
  printf 'v\n' > "$T/loose/.venv/v.txt"; printf 'm\n' > "$T/loose/node_modules/a/m.js"
  printf 'v = 1\n' > "$T/eng/uv.lock"; printf '#!/bin/sh\n' > "$T/eng/.venv/bin/tool"
  git -C "$T" add -A; git -C "$T" add -f eng/.venv/bin/tool; cmt "$T" -m "in flight"
  printf '#!/bin/sh\necho changed\n' > "$T/eng/.venv/bin/tool"; printf 'skip me\n' > "$T/eng/.venv/ignored.txt"
  git -C "$T" rm -q --cached loose/.venv/v.txt loose/node_modules/a/m.js
  cmt "$T" -m "untrack the loose ones"
  run python3 "$UP"
  m="$DAEDALUS_HOME/state/upgrade-snapshot/$(snaps | head -1)/manifest.json"
  [ -f "$m" ] || { echo "$output"; return 1; }
  python3 - "$m" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
files = {f["path"] for r in m["repos"] for f in r["files"]}
assert {"loose/.venv/v.txt", "loose/node_modules/a/m.js", "eng/.venv/bin/tool"} <= files, files
assert "eng/.venv/ignored.txt" not in files, files
sk = [s["path"] for s in m.get("skipped", [])]
assert sk == ["eng/.venv"], sk
PY
}

@test "the manifest names each skipped directory with its bytes and rebuild command, --restore-help prints them, and a change inside a skipped .venv leaves the fingerprint as it was (update-command Decision 8)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"
  mkdir -p "$T/engine" "$T/web" "$T/py"
  printf 'v = 1\n' > "$T/engine/uv.lock"; printf '[project]\n' > "$T/py/pyproject.toml"
  printf '{}\n' > "$T/web/package-lock.json"
  printf 'sub/\n.venv/\nnode_modules/\n' > "$T/.gitignore"
  git -C "$T" add -A; cmt "$T" -m "in flight"
  mkdir -p "$T/engine/.venv" "$T/web/node_modules/x" "$T/py/.venv"; head -c 2000000 /dev/urandom > "$T/engine/.venv/lib.so"; printf 'w\n' > "$T/web/node_modules/x/i.js"; printf 'p\n' > "$T/py/.venv/p"
  fp() { python3 - "$DAEDALUS_HOME" <<'PY'
import os, sys
from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, str(root / "core"))
import upgrade as u
repos = u._snap_repos(root)
coll = [u._snap_collect(root, r, None, {x["common"] for x in repos}) for r in repos]
try:
    print(u._snap_fp(coll))
finally:
    u._drop_scratch(coll)
PY
  }
  a="$(fp)"; printf 'reinstalled\n' > "$T/engine/.venv/lib.so"; printf 'new\n' > "$T/py/.venv/q"
  [ "$(fp)" = "$a" ]
  printf 'x2\n' > "$T/x.txt"; [ "$(fp)" != "$a" ]
  head -c 2000000 /dev/urandom > "$T/engine/.venv/lib.so"
  run python3 "$UP"
  m="$DAEDALUS_HOME/state/upgrade-snapshot/$(snaps | head -1)/manifest.json"
  [ -f "$m" ] || { echo "$output"; return 1; }
  python3 - "$m" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sk = {s["path"]: s for s in m["skipped"]}
assert sorted(sk) == ["engine/.venv", "py/.venv", "web/node_modules"], sk
assert sk["engine/.venv"]["rebuild"] == "uv sync --frozen" and sk["engine/.venv"]["bytes"] == 2000000, sk
assert sk["py/.venv"]["rebuild"] == "uv sync" and sk["web/node_modules"]["rebuild"] == "npm ci", sk
assert all(s["repo"] == "target/thing" and s["worktree"].endswith("/target/thing") for s in sk.values()), sk
files = {f["path"] for r in m["repos"] for f in r["files"]}
assert not [f for f in files if "/.venv/" in f or "node_modules" in f], files
PY
  run python3 "$UP" --restore-help
  case "$output" in *"Not copied, rebuilt from a lockfile: target/thing/engine/.venv (2 MB) — cd target/thing/engine && uv sync --frozen; target/thing/py/.venv (under 1 MB) — cd target/thing/py && uv sync; target/thing/web/node_modules (under 1 MB) — cd target/thing/web && npm ci."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the over-limit stop names the three largest parts of the copy, largest first, and never a fourth (update-command Decision 8)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  sparse "$T/build/out/a.bin" 300; sparse "$T/build/out/b.bin" 200
  sparse "$T/cache/c.bin" 400; sparse "$T/dump.sql" 100; sparse "$T/logs/l.txt" 50
  printf 'upgrade:\n  snapshot_max_mb: 10\n' >> "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP"
  [ "$status" -eq 1 ]
  case "$(printf '%s\n' "$output" | tail -1)" in *"over the 10 MB limit (upgrade.snapshot_max_mb in config.yaml); the largest are target/thing/build (500 MB), target/thing/cache (400 MB) and target/thing/dump.sql (100 MB) — raise the limit, or remove files target/ does not need (ignored build output counts), then start a session again") : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *logs*) echo "$output"; return 1 ;; esac
  [ -z "$(snaps)" ]
}

@test "--progress reports the copy on stderr while it is written, about every 10 s (a test knob shortens it), and nothing on stdout; without --progress, nothing (update-command Decision 8)" {
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  head -c 1000000 /dev/urandom > "$T/small.bin"
  UPGRADE_TEST_PROGRESS_SECONDS=0 run --separate-stderr python3 "$UP"
  case "$output" in *"a safety copy of everything in target/ is in state/upgrade-snapshot/"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
  head -c 3000000 /dev/urandom > "$T/big.bin"
  UPGRADE_TEST_PROGRESS_SECONDS=0 run --separate-stderr python3 "$UP" --progress
  printf '%s\n' "$stderr" | grep -qE '^safety copy: [0-9]+ of 3 MB$' || { echo "stderr: $stderr"; echo "$output"; return 1; }
  case "$output" in *"safety copy: "*" of "*) echo "$output"; return 1 ;; esac
  case "$output" in *"a safety copy of what is new in target/ since the copy in state/upgrade-snapshot/"*) : ;; *) echo "$output"; return 1 ;; esac
}
