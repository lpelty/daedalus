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

@test "a nested repo already ignored by the parent does not null the fingerprint" {
  # The live failure this pins: the parent repo gitignores the nested dir, and
  # an explicit :(exclude) pathspec for an ignored path makes git add error
  # ("Use -f"), nulling every fingerprint. Ignored-by-parent nested paths need
  # no exclude at all — git add skips them by itself.
  printf 'sub/\n' >> "$T/.gitignore"
  git -C "$T" add .gitignore
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m ign
  a="$(fp)"
  [ "$a" != "null" ]
  # nested content must still move the combined fingerprint (fingerprinted separately)
  printf 'm\n' >> "$T/sub/n.txt"
  [ "$(fp)" != "$a" ]
}

# --- target.fingerprint_exclude (PROP-018 second addendum, 2026-09-17) ---

with_exclude() {                     # $1 = the config value for fingerprint_exclude
  cat > "$DAEDALUS_HOME/config.yaml" <<CFG
target:
  repo: https://example.com/thing.git
  branch: main
  nested: sub=https://example.com/sub.git
  fingerprint_exclude: $1
CFG
}

@test "fingerprint_exclude: editing an excluded file does not move the fingerprint; editing any other file still does" {
  printf '0.27.0\n' > "$T/VERSION"; printf '# log\n' > "$T/CHANGELOG.md"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m meta
  with_exclude "VERSION, CHANGELOG.md"
  a="$(fp)"; [ "$a" != "null" ]
  printf '0.28.0\n' > "$T/VERSION";        [ "$(fp)" = "$a" ]
  printf '## 0.28.0\n' >> "$T/CHANGELOG.md"; [ "$(fp)" = "$a" ]
  printf 'two\n' >> "$T/a.txt";           [ "$(fp)" != "$a" ]
  git -C "$T" checkout -q -- a.txt;       [ "$(fp)" = "$a" ]
  # the exclusion itself is part of the hash: removing it makes the edited metadata count again
  with_exclude ""; sed -i '' '/fingerprint_exclude/d' "$DAEDALUS_HOME/config.yaml"
  [ "$(fp)" != "$a" ]
}

@test "fingerprint_exclude: a path that does not exist in the target is a no-op, not null" {
  a="$(fp)"
  with_exclude "CHANGELOG.md, VERSION"
  [ "$(fp)" = "$a" ]
}

@test "fingerprint_exclude: a gitignored path is skipped rather than nulling every fingerprint (the 'Use -f' trap)" {
  a="$(fp)"
  with_exclude "ignored"
  b="$(fp)"
  [ "$b" != "null" ]
  [ "$b" = "$a" ]
}

@test "fingerprint_exclude: a path that could leave the checkout nulls the fingerprint and names itself on stderr" {
  for bad in "../outside" "/etc/passwd" ":(top)VERSION" "VERSION, ../x"; do
    with_exclude "$bad"
    out="$(bash "$DAEDALUS_HOME/core/fingerprint.sh" 2>"$BATS_TEST_TMPDIR/err")"; st=$?
    [ "$st" -eq 0 ]
    [ "$out" = "null" ] || { echo "expected null for '$bad', got: $out"; return 1; }
    grep -q "must stay inside the target checkout" "$BATS_TEST_TMPDIR/err" || { echo "no reason on stderr for '$bad'"; return 1; }
  done
}
