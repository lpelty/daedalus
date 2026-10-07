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
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'MY NOTES\n' > "$T/notes.md"; tip="$(git -C "$T" rev-parse HEAD)"; nsum="$(shasum -a 256 "$T/notes.md" | cut -d' ' -f1)"
  shim_git
  PATH="$B/shim:$PATH" run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Upgrade to 0.7.0: a safety copy of everything in target/ is in state/upgrade-snapshot/$(snaps | tail -1) ("*"), taken before anything there changed."*"that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
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
assert f["sha256"] == sys.argv[3] and f["kind"] == "untracked", f
PY
  git bundle list-heads "$S/1-thing.bundle" | grep -q "^$tip "
  ! git -C "$T" for-each-ref | grep -q upgrade-snapshot          # the copy's own refs live in the bundle only
  run python3 "$UP" --restore-help
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

# kill_each <first> — the upgrade killed at its <first>-th change in target/, then every 4th after it, a fresh
# busy_target each time, until a run makes fewer changes than that and finishes; after each kill --restore-help
# finds nothing missing, the next runs finish the upgrade, and nothing is missing after them either. Four tests
# split the cuts so they run side by side.
kill_each() {
  n=$1
  while :; do
    [ "$n" -le 80 ] || { echo "more than 80 changes: the loop never reached a run that finished"; return 1; }
    rm -rf "$B/dae" "$B/origin.git" "$B/sub-origin.git"; upgrade_fixture; busy_target
    shim_git
    KILL_AT=$n PATH="$B/shim:$PATH" run python3 "$UP"
    [ -e "$B/killed" ] || { [ "$status" -eq 0 ] || { echo "run $n: $output"; return 1; }; break; }
    [ "$status" -eq 137 ] || { echo "kill $n: exit $status: $output"; return 1; }
    grep -q " bundle verify " "$B/git.log" || { echo "kill $n came before the copy was checked"; return 1; }
    [ "$(snaps | grep -c .)" -ge 1 ] || { echo "after kill $n: no safety copy was kept"; return 1; }
    held "after kill $n" || return 1
    run python3 "$UP" --restore-help
    case "$output" in *"no longer has"*|*"Bring it back"*|*"bring it back"*) echo "after kill $n: $output"; return 1 ;; esac
    [ "$(printf '%s\n' "$output" | grep -c "$NOTHING")" = "$(snaps | grep -c .)" ] || { echo "after kill $n: $output"; return 1; }
    for again in 1 2 3; do
      run python3 "$UP"
      case "$output" in *"Upgrade to 0.7.0: complete."*) break ;; esac
    done
    case "$output" in *"Upgrade to 0.7.0: complete."*) : ;; *) echo "after kill $n the upgrade did not finish: $output"; return 1 ;; esac
    run python3 "$UP" --restore-help
    [ "$(printf '%s\n' "$output" | grep -c "$NOTHING")" = "$(snaps | grep -c .)" ] || { echo "after kill $n and a full run: $output"; return 1; }
    [ "$(cat "$DAEDALUS_HOME"/worktrees/*/thing/notes.md 2>/dev/null)" = "MY NOTES" ] || { echo "after kill $n: notes.md is not in one window"; return 1; }
    held "after kill $n and a full run" || return 1
    n=$((n+4))
  done
  CUTS=$((n-4))
}

@test "killed at each change the upgrade makes in target/ (the 1st, 5th, 9th, ...): after every kill --restore-help finds nothing missing, the next run finishes, and nothing is missing after it either" {
  kill_each 1
  [ "$CUTS" -ge 20 ] || { echo "only $CUTS changes were cut: the shim saw too few"; return 1; }
  run python3 "$UP" --restore-help
  case "$output" in *"$NOTHING"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "killed at each change the upgrade makes in target/ (the 2nd, 6th, 10th, ...): nothing missing after each kill, nor after the run that finishes" {
  kill_each 2
}

@test "killed at each change the upgrade makes in target/ (the 3rd, 7th, 11th, ...): nothing missing after each kill, nor after the run that finishes" {
  kill_each 3
}

@test "killed at each change the upgrade makes in target/ (the 4th, 8th, 12th, ...): nothing missing after each kill, nor after the run that finishes" {
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
  run python3 "$UP"
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
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
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
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
  [ "$(printf '%s\n' "$output" | tail -1)" = "upgrade to 0.7.0 incomplete: before it changes anything in target/ it keeps a safety copy of it, and that copy would be about 3 MB, over the 1 MB limit (upgrade.snapshot_max_mb in config.yaml) — raise the limit, or remove files target/ does not need (ignored build output counts), then start a session again" ] || { echo "$output"; return 1; }
  [ "$(git -C "$T" branch --show-current)" = feat/x ]; [ ! -e "$DAEDALUS_HOME/state/leases/01.json" ]
  [ -z "$(snaps)" ]; [ -z "$(ls -A "$DAEDALUS_HOME/state/upgrade-snapshot" 2>/dev/null)" ]
  sed -i '' 's/snapshot_max_mb: 1$/snapshot_max_mb: 10/' "$DAEDALUS_HOME/config.yaml"
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"that work is now window 01"*) : ;; *) echo "$output"; return 1 ;; esac
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
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
  printf 'MY NOTES\n' > "$T/notes.md"
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]; case "$output" in *"The upgrade has not finished"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  s="$(snaps)"; [ -n "$s" ]
  line="A safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/$s; nothing was lost, but if anything looks missing, core/upgrade.py --restore-help lists it"
  run bash -c 'printf "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sB\",\"prompt\":\"hi\",\"transcript_path\":\"%s/sB.jsonl\"}" "$B" | python3 "$DAEDALUS_HOME/core/lease-board.py"'
  case "$output" in *"$line"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 "$UP" --doctor
  case "$output" in *"NOTE     a safety copy of everything in target/ from before the upgrade is in state/upgrade-snapshot/$s ("*") — core/upgrade.py --restore-help lists anything in it that target/ no longer has; core/upgrade.py --forget-snapshot removes it once nothing is"*) : ;; *) echo "$output"; return 1 ;; esac
  mv "$DAEDALUS_HOME/worktrees/01/thing/notes.md" "$B/notes.aside"
  run python3 "$UP" --forget-snapshot
  [ "$status" -eq 1 ]
  case "$output" in *"untracked file notes.md"*"Nothing was removed"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -d "$DAEDALUS_HOME/state/upgrade-snapshot/$s" ]
  mv "$B/notes.aside" "$DAEDALUS_HOME/worktrees/01/thing/notes.md"
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
  git -C "$T" checkout -q -b feat/x; printf 'x\n' > "$T/x.txt"; git -C "$T" add -A; cmt "$T" -m "in flight"
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
  case "$output" in *"target/thing was on feat/x"*"that work is now window"*"Upgrade to 0.7.0: complete."*) : ;; *) echo "$output"; return 1 ;; esac
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
  [ "$status" -eq 1 ]; case "$output" in *"has uncommitted changes"*) : ;; *) echo "$output"; return 1 ;; esac
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
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
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
  [ "$status" -eq 1 ]; case "$output" in *"has uncommitted changes"*) : ;; *) echo "$output"; return 1 ;; esac
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
  run python3 "$UP"
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
  [ "$status" -eq 1 ]; case "$output" in *"has uncommitted changes"*) : ;; *) echo "$output"; return 1 ;; esac
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
  run python3 "$UP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rm "$T/two
lines.txt" "$T/notes.md" "$B/hand/Notes.md"
  run python3 "$UP" --restore-help
  [ "$(cmds "$output" | grep -c '^mkdir -p ')" = 3 ] || { echo "$output"; return 1; }
  case "$output" in *"\$'w0/two\\nlines.txt'"*) : ;; *) echo "$output"; return 1 ;; esac
  cmds "$output" > "$B/restore.sh"; bash "$B/restore.sh" || { cat "$B/restore.sh"; return 1; }
  R="$(echo "$DAEDALUS_HOME"/state/upgrade-restore/*/1-thing)"
  [ "$(cat "$R/w0/two
lines.txt")" = LINE ]; [ "$(cat "$R/w0/notes.md")" = lower ]; [ "$(cat "$R/w1/Notes.md")" = UPPER ]
}
