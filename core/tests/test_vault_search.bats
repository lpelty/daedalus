#!/usr/bin/env bats
#
# Pins vault-search's product contract: the query travels as "$1" exactly once,
# results are validated/filtered/capped, and every failure path is silent.
# Assertions use [ ] only — a non-final [[ ]] is decorative under bash 3.2.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault"
  cp "$SRC/lib.sh" "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
  # The runner resolves the home; on macOS /var -> /private/var, so every
  # comparison against a runner-resolved path uses RHOME, never DAEDALUS_HOME.
  RHOME="$(cd "$DAEDALUS_HOME" && pwd -P)"
  SCRIPT="$DAEDALUS_HOME/core/vault-search.py"
  FIXQ="$BATS_TEST_DIRNAME/fixtures/recall/fixture-query.sh"
  RESULTS="$BATS_TEST_TMPDIR/results.json"
  REPORT="$BATS_TEST_TMPDIR/report.txt"
  export FIXTURE_RESULTS="$RESULTS" FIXTURE_REPORT="$REPORT"
  rm -f "$REPORT"
}

# write_config <recall-line-1> [recall-line-2]
write_config() {
  {
    printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\n'
    printf 'vault:\n  repo: https://example.com/thing-kb.git\n'
    printf 'gates:\n  - true\nproposals:\n  budget: 5\n'
    printf 'recall:\n'
    printf '%s\n' "$1"
    if [ -n "${2:-}" ]; then printf '%s\n' "$2"; fi
  } > "$DAEDALUS_HOME/config.yaml"
}

count() { printf '%s\n' "$output" | grep -cF -- "$1"; }
report_count() { grep -cF -- "$1" "$REPORT" 2>/dev/null || true; }

@test "query passes the text as \$1 exactly once, with the RESOLVED store exported" {
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  store: state/chroma"
  mkdir -p "$DAEDALUS_HOME/state/chroma"
  printf '[]' > "$RESULTS"
  run python3 "$SCRIPT" query '"; rm -rf ~"'
  [ "$status" -eq 0 ]
  [ "$(report_count 'argc=1')" -eq 1 ]
  [ "$(report_count 'arg1="; rm -rf ~"')" -eq 1 ]
  [ "$(report_count "store=$RHOME/state/chroma")" -eq 1 ]
}

@test "valid results: filtered, capped at 8 after filtering, order kept, JSON out" {
  write_config "  vault-query: '$FIXQ \"\$1\"'"
  python3 - "$RESULTS" <<'PY'
import json, sys
rows = []
for i in range(12):
    p = "specs/doc%02d.md" % i
    if i == 2: p = "evidence/x.md"
    if i == 4: p = "evidence/y.md"
    rows.append({"path": p, "snippet": "s%d" % i})
open(sys.argv[1], "w").write(json.dumps(rows))
PY
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]
  echo "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 8, len(rows)                       # no-cap prints 10; cap-then-filter prints 6
paths = [r["path"] for r in rows]
assert not any(p.startswith("evidence/") for p in paths), paths
expect = ["specs/doc%02d.md" % i for i in (0,1,3,5,6,7,8,9)]
assert paths == expect, paths                          # first 8 NON-evidence, in order
'
}

@test "bypass path shapes are dropped: absolute, dotdot, dot-slash" {
  write_config "  vault-query: '$FIXQ \"\$1\"'"
  python3 - "$RESULTS" <<'PY'
import json, sys
rows = [
    {"path": "/abs/vault/evidence/x.md", "snippet": "a"},
    {"path": "./evidence/x.md", "snippet": "b"},
    {"path": "specs/../evidence/x.md", "snippet": "c"},
    {"path": "specs/ok.md", "snippet": "d"},
]
open(sys.argv[1], "w").write(json.dumps(rows))
PY
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]
  [ "$(count '"specs/ok.md"')" -eq 1 ]
  [ "$(count 'evidence')" -eq 0 ]
}

@test "silence: invalid JSON, non-array, element missing path, engine exit 1" {
  write_config "  vault-query: '$FIXQ \"\$1\"'"
  for bad in 'not json' '{"a":1}' '[{"snippet":"no path"}]'; do
    printf '%s' "$bad" > "$RESULTS"
    run python3 "$SCRIPT" query "some query text"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  write_config "  vault-query: 'false'"
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # positive control: the silent cases above are not a broken runner
  write_config "  vault-query: '$FIXQ \"\$1\"'"
  printf '[{"path":"a.md","snippet":"s"}]' > "$RESULTS"
  run python3 "$SCRIPT" query "some query text"
  [ "$(count '"a.md"')" -eq 1 ]
}

@test "unset vault-query: query is silent" {
  write_config "  store: state/chroma"
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cfg mangles produce silence; balanced value actually RUNS the engine" {
  # NOTE: the two mangle clauses below cannot distinguish detector-off from
  # engine-crash (the mangled command is also unrunnable bash) — they pin
  # silence, not the detector. The DETECTOR is pinned by Task 3's --check
  # corruption test, which names the condition and fails when it's removed.
  # mangle 1: trailing space after a quoted value
  write_config "  vault-query: \"$FIXQ\" "
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -f "$REPORT" ]                       # engine never ran
  # mangle 2: inline comment after a quoted value
  write_config "  vault-query: \"$FIXQ\" # tail comment"
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -f "$REPORT" ]
  # balanced single-quoted value with inner "$1": the engine RUNS (report exists)
  write_config "  vault-query: '$FIXQ \"\$1\"'"
  printf '[]' > "$RESULTS"
  run python3 "$SCRIPT" query "some query text"
  [ "$status" -eq 0 ]
  [ "$(report_count 'argc=1')" -eq 1 ]     # a wrongly-tripped detector fails here
}

@test "store guard: absolute, dotdot, bare dot rejected; symlink escape rejected post-resolution" {
  for bad in "  store: /tmp/evil" "  store: state/../../escape" "  store: ." ; do
    rm -f "$REPORT"
    write_config "  vault-query: '$FIXQ \"\$1\"'" "$bad"
    printf '[]' > "$RESULTS"
    run python3 "$SCRIPT" query "some query text"
    [ "$status" -eq 0 ]
    [ ! -f "$REPORT" ]                     # engine never ran
  done
  # dot-free relative path whose component symlinks OUT of the home:
  ln -s /tmp "$DAEDALUS_HOME/slink"
  rm -f "$REPORT"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  store: slink/chroma"
  run python3 "$SCRIPT" query "some query text"
  [ ! -f "$REPORT" ]
  # positive control: an accepted store runs the engine
  rm -f "$REPORT"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  store: state/chroma"
  printf '[]' > "$RESULTS"
  run python3 "$SCRIPT" query "some query text"
  [ "$(report_count 'store=')" -eq 1 ]
}

@test "index: success + count line + store present -> stamp written, line echoed" {
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<EOF
#!/bin/bash
mkdir -p "\$DAEDALUS_RECALL_STORE"
echo "some engine noise"
echo "indexed=3 purged=1"
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  vault-index: '$BATS_TEST_TMPDIR/eng.sh'"
  run python3 "$SCRIPT" index
  [ "$status" -eq 0 ]
  [ "$(count 'indexed=3 purged=1')" -eq 1 ]
  [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
}

@test "index: exit 0 without count line -> no stamp" {
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<EOF
#!/bin/bash
mkdir -p "\$DAEDALUS_RECALL_STORE"
echo "done"
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  vault-index: '$BATS_TEST_TMPDIR/eng.sh'"
  run python3 "$SCRIPT" index
  [ "$status" -eq 0 ]
  [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
}

@test "index: count line but store never created -> no stamp (misbound engine)" {
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<'EOF'
#!/bin/bash
echo "indexed=5 purged=0"
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  vault-index: '$BATS_TEST_TMPDIR/eng.sh'"
  run python3 "$SCRIPT" index
  [ "$status" -eq 0 ]
  [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
}

@test "index: failing engine leaves an existing stamp untouched" {
  mkdir -p "$DAEDALUS_HOME/state"
  printf 'old' > "$DAEDALUS_HOME/state/recall-last-index"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  vault-index: 'false'"
  run python3 "$SCRIPT" index
  [ "$status" -eq 0 ]
  [ "$(cat "$DAEDALUS_HOME/state/recall-last-index")" = "old" ]
}

@test "--check: unconfigured is the summary itself; healthy is summary only" {
  write_config "  store: state/chroma"
  run python3 "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [ "$output" = "document recall: unconfigured" ]
  # healthy: engine answers, store + stamp fresh
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<'EOF'
#!/bin/bash
echo '[]'
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$BATS_TEST_TMPDIR/eng.sh \"\$1\"'" "  vault-index: 'true'"
  mkdir -p "$DAEDALUS_HOME/state/chroma" "$DAEDALUS_HOME/vault/specs"
  printf '# x' > "$DAEDALUS_HOME/vault/specs/x.md"
  sleep 1
  printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  run python3 "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [ "$output" = "document recall: configured, probe ok" ]
}

@test "--check: each condition line fires on its fixture" {
  # failing engine
  write_config "  vault-query: 'false'" "  vault-index: 'true'"
  mkdir -p "$DAEDALUS_HOME/state/chroma"
  run python3 "$SCRIPT" --check
  [ "$(count 'query command failing')" -eq 1 ]
  # corrupted values: BOTH real cfg mangle classes, named by --check
  # (the Task 1 mangle tests pin only silence; this is the detector's pin)
  write_config "  vault-query: \"$BATS_TEST_TMPDIR/eng.sh\" " "  vault-index: 'true'"
  run python3 "$SCRIPT" --check
  [ "$(count 'looks corrupted')" -eq 1 ]
  write_config "  vault-query: \"$BATS_TEST_TMPDIR/eng.sh\" # tail" "  vault-index: 'true'"
  run python3 "$SCRIPT" --check
  [ "$(count 'looks corrupted')" -eq 1 ]
  # rejected store is NAMED by --check (spec A-5)
  write_config "  vault-query: 'true'" "  store: /tmp/evil"
  run python3 "$SCRIPT" --check
  [ "$(count 'recall.store rejected')" -eq 1 ]
  # store missing
  rm -rf "$DAEDALUS_HOME/state/chroma"
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<'EOF'
#!/bin/bash
echo '[]'
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$BATS_TEST_TMPDIR/eng.sh \"\$1\"'" "  vault-index: 'true'"
  run python3 "$SCRIPT" --check
  [ "$(count 'no index at')" -eq 1 ]
  # stamp without a store
  printf 'x' > "$DAEDALUS_HOME/state/recall-last-index"
  run python3 "$SCRIPT" --check
  [ "$(count 'stamp without a store')" -eq 1 ]
  # store present, stamp absent -> the "no index stamp" NOTE
  rm -f "$DAEDALUS_HOME/state/recall-last-index"
  mkdir -p "$DAEDALUS_HOME/state/chroma"
  run python3 "$SCRIPT" --check
  [ "$(count 'no index stamp')" -eq 1 ]
  # stale: vault newer than stamp
  printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  mkdir -p "$DAEDALUS_HOME/vault/specs"
  sleep 1
  printf '# y' > "$DAEDALUS_HOME/vault/specs/y.md"
  run python3 "$SCRIPT" --check
  [ "$(count 'index run older than newest vault change')" -eq 1 ]
  # reindex key unset
  write_config "  vault-query: '$BATS_TEST_TMPDIR/eng.sh \"\$1\"'"
  run python3 "$SCRIPT" --check
  [ "$(count 'reindex command unconfigured')" -eq 1 ]
}

@test "--check staleness scan ignores evidence/ and dot-dirs" {
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<'EOF'
#!/bin/bash
echo '[]'
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$BATS_TEST_TMPDIR/eng.sh \"\$1\"'" "  vault-index: 'true'"
  mkdir -p "$DAEDALUS_HOME/state/chroma" "$DAEDALUS_HOME/vault/evidence" "$DAEDALUS_HOME/vault/.obsidian"
  printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  sleep 1
  printf '# e' > "$DAEDALUS_HOME/vault/evidence/e.md"     # gates.sh churn
  printf '# o' > "$DAEDALUS_HOME/vault/.obsidian/o.md"
  run python3 "$SCRIPT" --check
  [ "$(count 'index run older')" -eq 0 ]
  sleep 1
  mkdir -p "$DAEDALUS_HOME/vault/specs"
  printf '# real' > "$DAEDALUS_HOME/vault/specs/real.md"  # positive control
  run python3 "$SCRIPT" --check
  [ "$(count 'index run older')" -eq 1 ]
}
