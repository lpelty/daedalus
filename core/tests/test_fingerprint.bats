#!/usr/bin/env bats
# Pins the fingerprint's semantics: content, not mtime; commit-invariant;
# nested repos excluded; null on every failure (never the empty-tree hash).

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/target"
  cp "$SRC/lib.sh" "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
  T="$DAEDALUS_HOME/target/thing"
  git init -q "$T"
  git -C "$T" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  printf 'one\n' > "$T/a.txt"; printf 'ignored\n' > "$T/.gitignore"; printf 'x\n' > "$T/ignored"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m a
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
  nested: sub=https://example.com/sub.git
EOF
  git init -q "$T/sub"
  printf 'n\n' > "$T/sub/n.txt"
  git -C "$T/sub" add -A; git -C "$T/sub" -c user.email=t@x -c user.name=t commit -q -m n
}

teardown() {
  # An unreadable fixture path left behind by a failing assertion would
  # block bats' own tmpdir cleanup — restore permissions unconditionally,
  # whether or not this test's own restore line was reached.
  [ -n "${T:-}" ] && [ -e "$T/subdir" ] && chmod -R u+rwx "$T/subdir" 2>/dev/null || true
}

fp() { bash "$DAEDALUS_HOME/core/fingerprint.sh" 2>/dev/null; }

@test "content changes it, touch does not, revert restores it" {
  a="$(fp)"; [ "$a" != "null" ]
  touch "$T/a.txt"; [ "$(fp)" = "$a" ]
  printf 'two\n' >> "$T/a.txt"; b="$(fp)"; [ "$b" != "$a" ]
  git -C "$T" checkout -q -- a.txt; [ "$(fp)" = "$a" ]
}

@test "untracked content counts; ignored content does not" {
  a="$(fp)"
  printf 'u\n' > "$T/new.txt"; [ "$(fp)" != "$a" ]
  rm "$T/new.txt"; [ "$(fp)" = "$a" ]
  printf 'y\n' >> "$T/ignored"; [ "$(fp)" = "$a" ]
}

@test "a commit in the parent or the nested repo does not change it; nested content does" {
  a="$(fp)"
  git -C "$T" -c user.email=t@x -c user.name=t commit -q --allow-empty -m e; [ "$(fp)" = "$a" ]
  git -C "$T/sub" -c user.email=t@x -c user.name=t commit -q --allow-empty -m e; [ "$(fp)" = "$a" ]
  printf 'm\n' >> "$T/sub/n.txt"; [ "$(fp)" != "$a" ]
}

@test "null when the target is not a repo, when index.lock exists, and when fingerprint.sh's add fails" {
  rm -rf "$T/.git"; [ "$(fp)" = "null" ]
  git init -q "$T"; touch "$T/.git/index.lock"; [ "$(fp)" = "null" ]
}

@test "an unreadable file inside a subdirectory makes git add fail, and fingerprint prints null (drill-6)" {
  # Pins the `|| { rm -f "$idx"; return 1; }` on `git add` in fp_repo. On
  # this platform an unreadable DIRECTORY only produces a warning from `git
  # add -A` (still exit 0) — an unreadable FILE inside a subdirectory is
  # what actually makes `add` fail (exit 128), verified empirically before
  # writing this test. That failure must propagate as `null`, never the
  # empty-tree hash a half-built index would otherwise produce.
  rm -rf "$T/.git"; git init -q "$T"
  git -C "$T" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$T/subdir"
  printf 'secret\n' > "$T/subdir/locked.txt"
  chmod 000 "$T/subdir/locked.txt"
  [ "$(fp)" = "null" ]
  chmod 644 "$T/subdir/locked.txt"
  [ "$(fp)" != "null" ]
}

@test "prints fingerprint_secs on stderr and exits 0" {
  run bash "$DAEDALUS_HOME/core/fingerprint.sh"
  [ "$status" -eq 0 ]
  case "$output" in *fingerprint_secs=*) : ;; *) echo "no timing: $output"; return 1 ;; esac
}
