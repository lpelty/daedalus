#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/lib.sh" "$DAEDALUS_HOME/core/"
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/sync-target.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME

  # A real local git repo to act as the upstream target.
  UPSTREAM="$BATS_TEST_TMPDIR/upstream-harness"
  mkdir -p "$UPSTREAM"
  cd "$UPSTREAM"
  git init -q -b main
  echo "harness code" > file.txt
  git add file.txt
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $UPSTREAM
  branch: main
EOF
}

@test "sync-target clones into target/<repo-name>/ preserving the natural name" {
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/file.txt" ]
}

@test "sync-target is idempotent — a second run fast-forwards without error" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/file.txt" ]
}

@test "sync-target picks up new upstream commits" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  cd "$BATS_TEST_TMPDIR/upstream-harness"
  echo "more" > second.txt
  git add second.txt
  git -c user.email=t@t -c user.name=t commit -q -m second
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/second.txt" ]
}

@test "target_path prints the absolute path to the checkout" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  source "$DAEDALUS_HOME/core/lib.sh"
  run target_path
  [ "$output" = "$DAEDALUS_HOME/target/upstream-harness" ]
}

@test "sync-target clones a nested repo into its declared path" {
  NESTED="$BATS_TEST_TMPDIR/upstream-identity"
  mkdir -p "$NESTED"
  cd "$NESTED"
  git init -q -b main
  echo "identity content" > IDENTITY.md
  git add IDENTITY.md
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: agents/one=$NESTED
EOF
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/agents/one/IDENTITY.md" ]
}

@test "a nested clone leaves the ship checkout clean" {
  cd "$BATS_TEST_TMPDIR/upstream-harness"
  echo "agents/" > .gitignore
  git add .gitignore
  git -c user.email=t@t -c user.name=t commit -q -m "gitignore nested paths"

  NESTED="$BATS_TEST_TMPDIR/upstream-identity2"
  mkdir -p "$NESTED"
  cd "$NESTED"
  git init -q -b main
  echo x > f.txt
  git add f.txt
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: agents/two=$NESTED
EOF
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  run git -C "$DAEDALUS_HOME/target/upstream-harness" status --porcelain
  [ -z "$output" ]
}

@test "sync-target succeeds when no nested key is configured" {
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
EOF
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
}

@test "sync-target rejects a nested path that escapes the checkout via .." {
  NESTED="$BATS_TEST_TMPDIR/upstream-escape"
  mkdir -p "$NESTED"
  cd "$NESTED"
  git init -q -b main
  echo x > marker.txt
  git add marker.txt
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: ../escaped=$NESTED
EOF
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  [ ! -e "$DAEDALUS_HOME/escaped" ]
  [ ! -e "$DAEDALUS_HOME/target/escaped" ]
}

@test "sync-target rejects an absolute nested path" {
  NESTED="$BATS_TEST_TMPDIR/upstream-abs"
  mkdir -p "$NESTED"
  cd "$NESTED"
  git init -q -b main
  echo x > marker.txt
  git add marker.txt
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: /tmp/daedalus-abs-escape=$NESTED
EOF
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  [ ! -e "/tmp/daedalus-abs-escape" ]
}

@test "sync-target rejects a nested path whose ancestor is a symlink escaping the checkout" {
  # The early string-form check (case */*..*) cannot see through a symlink:
  # "pwn/escaped" contains neither ".." nor a leading "/", so only the
  # resolved-path (pwd -P) check can catch this. This test exists to pin
  # that check in place — deleting it must turn this test red.
  OUTSIDE="$BATS_TEST_TMPDIR/outside-the-checkout"
  mkdir -p "$OUTSIDE"

  # Pre-clone the ship fixture ourselves. If sync-target.sh created
  # target/upstream-harness itself first, "pwn" wouldn't exist yet either
  # way — but planting the symlink AFTER a real clone, and BEFORE the run
  # that processes "nested", is what proves the guard checks the live
  # filesystem rather than something baked in at clone time.
  git clone -q "$BATS_TEST_TMPDIR/upstream-harness" "$DAEDALUS_HOME/target/upstream-harness"
  ln -s "$OUTSIDE" "$DAEDALUS_HOME/target/upstream-harness/pwn"

  # Ship fixture gitignores "pwn" so the symlink itself doesn't dirty the
  # checkout independent of the escape attempt this test is checking.
  cd "$DAEDALUS_HOME/target/upstream-harness"
  echo "pwn" > .gitignore
  git add .gitignore
  git -c user.email=t@t -c user.name=t commit -q -m "gitignore the symlink foothold"

  NESTED="$BATS_TEST_TMPDIR/upstream-pwn-payload"
  mkdir -p "$NESTED"
  cd "$NESTED"
  git init -q -b main
  echo "payload" > PAYLOAD.md
  git add PAYLOAD.md
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: pwn/escaped=$NESTED
EOF
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  # The assertion that matters: nothing landed outside the checkout. An
  # exit-code-only check would still pass a guard that rejects AFTER
  # cloning into the symlink target.
  [ -z "$(ls -A "$OUTSIDE")" ]
}

@test "sync-target still clones a legitimate nested subdirectory path" {
  NESTED="$BATS_TEST_TMPDIR/upstream-deep"
  mkdir -p "$NESTED"
  cd "$NESTED"
  git init -q -b main
  echo "deep content" > DEEP.md
  git add DEEP.md
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: a/b/c=$NESTED
EOF
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/a/b/c/DEEP.md" ]
}

@test "sync-target refuses to sync a lease worktree — the prime's checkout is what it updates; lease.sh rebase brings a lease forward" {
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  D="$DAEDALUS_HOME/target/upstream-harness"
  git -C "$D" worktree add -q "$DAEDALUS_HOME/worktrees/01/upstream-harness" -b lease/01 origin/main
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/leaselib.py" "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/verifylib.py" "$DAEDALUS_HOME/core/"
  mkdir -p "$DAEDALUS_HOME/state/leases"
  printf '{"lease":"01","session_id":"s1","worktree":"worktrees/01","branch":"lease/01"}' > "$DAEDALUS_HOME/state/leases/01.json"
  run env DAEDALUS_SESSION_ID=s1 bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"sync-target updates the prime's checkout; a lease worktree is brought forward by \`core/lease.sh rebase 01\`"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -d "$DAEDALUS_HOME/worktrees/01/upstream-harness/.git" ]   # never `git clone`d over
}

@test "sync-target updates a nested checkout whose .git is a file (a linked worktree) instead of trying to clone over it" {
  NESTED="$BATS_TEST_TMPDIR/upstream-sub"
  git init -q -b main "$NESTED"
  echo "sub content" > "$NESTED/SUB.md"
  git -C "$NESTED" add SUB.md
  git -C "$NESTED" -c user.email=t@t -c user.name=t commit -q -m init
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: sub=$NESTED
EOF
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  D="$DAEDALUS_HOME/target/upstream-harness"
  [ -d "$D/sub/.git" ]
  # Replace the nested clone with a linked worktree of another clone of the
  # same upstream: same content, but .git is now a FILE (gitdir: …).
  git clone -q "$NESTED" "$BATS_TEST_TMPDIR/subclone"
  rm -rf "$D/sub"
  # on the nested trunk (sync-target refuses any other branch, spec §14): free main in the clone first
  git -C "$BATS_TEST_TMPDIR/subclone" checkout -q --detach
  git -C "$BATS_TEST_TMPDIR/subclone" worktree add -q "$D/sub" main
  [ -f "$D/sub/.git" ]
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"updating nested sub"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"cloning nested sub"*) echo "$output"; return 1 ;; esac   # `-d .git` cloned here and died: "already exists and is not an empty directory"
  [ -f "$D/sub/.git" ]                                                          # still the worktree, untouched
}

@test "sync-target clones into an existing empty target directory inside an outer repository instead of fetching the outer repo" {
  git init -q "$BATS_TEST_TMPDIR"          # the deployment root is itself a repository
  mkdir -p "$DAEDALUS_HOME/target/upstream-harness"
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -eq 0 ]
  [ -f "$DAEDALUS_HOME/target/upstream-harness/file.txt" ]
}

@test "sync-target refuses a target checkout that is not on the trunk — a branch, or no branch — naming it and what turns it into a window; nothing moves" {
  echo 0.7.0 > "$DAEDALUS_HOME/VERSION"     # a release pulled, not yet upgraded: the next session start adopts it
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  D="$DAEDALUS_HOME/target/upstream-harness"
  git -C "$D" checkout -q -b feat/x
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness is on feat/x; the upgrade stops on it while it holds work origin/main lacks, until it is picked up (core/lease.sh adopt --all-unfinished, or core/lease.sh adopt feat/x), and otherwise puts it back on main at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$D" branch --show-current)" = feat/x ]
  git -C "$D" checkout -q --detach
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness is not on a branch; the upgrade puts it back on main at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "sync-target refuses a nested checkout that is not on its trunk (origin/HEAD)" {
  NESTED="$BATS_TEST_TMPDIR/upstream-n"; git init -q -b main "$NESTED"; echo n > "$NESTED/n.txt"
  git -C "$NESTED" add -A; git -C "$NESTED" -c user.email=t@t -c user.name=t commit -q -m n
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: sub=$NESTED
EOF
  echo 0.7.0 > "$DAEDALUS_HOME/VERSION"
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  git -C "$DAEDALUS_HOME/target/upstream-harness/sub" checkout -q -b feat/n
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness/sub is on feat/n; the upgrade stops on it while it holds work origin/main lacks, until it is picked up (core/lease.sh adopt --all-unfinished, or core/lease.sh adopt feat/n --repo sub), and otherwise puts it back on main at the next session start"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "sync-target on an upgraded home (the stamp matches VERSION) never promises a next-session adoption — the upgrade does not run again; it names lease.sh adopt, or for no branch how to name the commits first" {
  echo 0.7.0 > "$DAEDALUS_HOME/VERSION"
  mkdir -p "$DAEDALUS_HOME/state"; echo 0.7.0 > "$DAEDALUS_HOME/state/upgraded-to"
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  D="$DAEDALUS_HOME/target/upstream-harness"
  git -C "$D" checkout -q -b feat/x
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness is on feat/x; run core/lease.sh adopt feat/x to make it a numbered window"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"next session start"*) echo "$output"; return 1 ;; esac
  [ "$(git -C "$D" branch --show-current)" = feat/x ]
  git -C "$D" checkout -q --detach
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness is not on a branch; give its commits a branch (git -C target/upstream-harness switch -c <name>) and run core/lease.sh adopt <name>, or check out main if they are already on origin/main"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"next session start"*) echo "$output"; return 1 ;; esac
  # A window's own branch is never adopted (lease.sh adopt refuses it): the refusal says to go back to the trunk.
  git -C "$D" checkout -q -b lease/03
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness is on lease/03, window 03's branch; check out main there (the window keeps its branch)"*) : ;; *) echo "$output"; return 1 ;; esac
  # A home with no VERSION is never upgraded either (session-start's own rule): the same wording.
  rm -f "$DAEDALUS_HOME/VERSION" "$DAEDALUS_HOME/state/upgraded-to"
  git -C "$D" checkout -q feat/x
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness is on feat/x; run core/lease.sh adopt feat/x to make it a numbered window"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "sync-target on an upgraded home names lease.sh adopt with --repo for a nested checkout off its trunk" {
  NESTED="$BATS_TEST_TMPDIR/upstream-n"; git init -q -b main "$NESTED"; echo n > "$NESTED/n.txt"
  git -C "$NESTED" add -A; git -C "$NESTED" -c user.email=t@t -c user.name=t commit -q -m n
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $BATS_TEST_TMPDIR/upstream-harness
  branch: main
  nested: sub=$NESTED
EOF
  echo 0.7.0 > "$DAEDALUS_HOME/VERSION"
  mkdir -p "$DAEDALUS_HOME/state"; printf '0.7.0\n' > "$DAEDALUS_HOME/state/upgraded-to"
  bash "$DAEDALUS_HOME/core/sync-target.sh"
  N="$DAEDALUS_HOME/target/upstream-harness/sub"
  git -C "$N" checkout -q -b feat/n
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness/sub is on feat/n; run core/lease.sh adopt feat/n --repo sub to make it a numbered window"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"next session start"*) echo "$output"; return 1 ;; esac
  git -C "$N" checkout -q --detach
  run bash "$DAEDALUS_HOME/core/sync-target.sh"
  [ "$status" -ne 0 ]
  case "$output" in *"target/upstream-harness/sub is not on a branch; give its commits a branch (git -C target/upstream-harness/sub switch -c <name>) and run core/lease.sh adopt <name> --repo sub, or check out main if they are already on origin/main"*) : ;; *) echo "$output"; return 1 ;; esac
}
