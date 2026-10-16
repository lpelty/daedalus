#!/usr/bin/env bats
#
# Pins vault-search's product contract: the query travels as "$1" exactly once,
# results are validated/filtered/capped, and every failure path is silent.
# Assertions use [ ] only — a non-final [[ ]] is decorative under bash 3.2.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/leaselib.py" "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
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

@test "--check: unconfigured is the summary itself; healthy is the summary and the last-run line only" {
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
  # since the reindex design of 2026-10-15 the last automatic run is always reported (§3.3)
  [ "$output" = "document recall: configured, probe ok
document recall: no automatic index run recorded yet" ]
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

@test "the REAL config.example.yaml recall block parses to exact placeholder values" {
  # Live file, not a frozen copy: this is the test that fails if an inline
  # comment or a bare trailing quote creeps into the example (spec A-1).
  REAL="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/config.example.yaml"
  cp "$REAL" "$DAEDALUS_HOME/config.yaml"
  v="$(cd "$DAEDALUS_HOME" && bash -c 'source core/lib.sh; cfg recall.vault-query')"
  [ "$v" = '<command printing JSON results for query "$1">' ]
  v="$(cd "$DAEDALUS_HOME" && bash -c 'source core/lib.sh; cfg recall.vault-index')"
  [ "$v" = '<command that (re)indexes the vault into the store>' ]
  v="$(cd "$DAEDALUS_HOME" && bash -c 'source core/lib.sh; cfg recall.store')"
  [ "$v" = 'state/chroma' ]
}

@test "index refuses from a non-prime session, runs for the prime under a non-blocking lock, and says 'already running' when held; --check for a clone names the prime" {
  cp "$SRC/leaselib.py" "$DAEDALUS_HOME/core/"
  # the query engine (the fixture script) and an index engine that creates the store and prints the count line
  cat > "$BATS_TEST_TMPDIR/eng.sh" <<'EOF'
#!/bin/bash
mkdir -p "$DAEDALUS_RECALL_STORE"
echo "indexed=1 purged=0"
EOF
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  write_config "  vault-query: '$FIXQ \"\$1\"'" "$(printf "  vault-index: '%s'\n  store: state/chroma" "$BATS_TEST_TMPDIR/eng.sh")"
  mkdir -p "$DAEDALUS_HOME/state/leases"
  printf '{"session_id":"sP","history":[]}' > "$DAEDALUS_HOME/state/leases/prime.json"
  printf '{"lease":"02","session_id":"s2","worktree":"worktrees/02"}' > "$DAEDALUS_HOME/state/leases/02.json"
  run env DAEDALUS_SESSION_ID=s2 python3 "$SCRIPT" index
  case "$output" in *"The document index is rebuilt by the prime; ask it to reindex"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
  run env DAEDALUS_SESSION_ID=sP python3 "$SCRIPT" index; [ "$status" -eq 0 ]
  [ "$(count 'indexed=1 purged=0')" -eq 1 ]; [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
  python3 -c "import fcntl,os,time; fd=os.open('$DAEDALUS_HOME/state/recall-index.lock',os.O_RDWR|os.O_CREAT); fcntl.flock(fd,fcntl.LOCK_EX); time.sleep(3)" 3>&- </dev/null >/dev/null 2>&1 &
  sleep 0.5; run env DAEDALUS_SESSION_ID=sP python3 "$SCRIPT" index; [ "$status" -eq 0 ]; case "$output" in *"index already running"*) : ;; *) echo "$output"; return 1 ;; esac
  wait
  mkdir -p "$DAEDALUS_HOME/vault/specs"; sleep 1; printf 'new\n' > "$DAEDALUS_HOME/vault/specs/new.md"
  printf '[]' > "$RESULTS"
  run env DAEDALUS_SESSION_ID=s2 python3 "$SCRIPT" --check; case "$output" in *"document recall: index older than the vault — ask the prime to reindex"*) : ;; *) echo "$output"; return 1 ;; esac
  # an operator shell: none of the session variables (the Bash tool that runs this suite injects CLAUDE_CODE_SESSION_ID)
  run env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID python3 "$SCRIPT" --check; case "$output" in *"document recall: index run older than newest vault change"*) : ;; *) echo "operator shell keeps the plain line: $output"; return 1 ;; esac
}

# --- the index rebuilds itself (reindex design 2026-10-15) ------------------
# A query engine the --check probe accepts, and an index engine that creates
# the store and prints the count line; both configured, so the fixture is
# never "unconfigured" by accident.
write_recall_config() {   # write_recall_config <index-engine-path>
  write_config "  vault-query: '$FIXQ \"\$1\"'" "$(printf "  vault-index: '%s'\n  store: state/chroma" "$1")"
}
index_engine() {   # index_engine <body...> — a vault-index engine that creates the store, then runs the body
  { printf '#!/bin/bash\nmkdir -p "$DAEDALUS_RECALL_STORE"\n'; printf '%s\n' "$@"; } > "$BATS_TEST_TMPDIR/eng.sh"
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
}

@test "--stale answers in one word without running an engine: unconfigured, no-store, stale (no stamp; a document newer than the stamp), fresh; evidence/ never makes it stale" {
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  store: state/chroma"
  run python3 "$SCRIPT" --stale; [ "$status" -eq 0 ]; [ "$output" = "unconfigured" ]
  write_config "  vault-query: '$FIXQ \"\$1\"'" "$(printf "  vault-index: \"%s\" \n  store: state/chroma" "$BATS_TEST_TMPDIR/eng.sh")"   # trailing space: the cfg mangle
  run python3 "$SCRIPT" --stale; [ "$output" = "unconfigured" ]
  index_engine 'echo "indexed=1 purged=0"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  run python3 "$SCRIPT" --stale; [ "$status" -eq 0 ]; [ "$output" = "no-store" ]
  mkdir -p "$DAEDALUS_HOME/state/chroma"
  run python3 "$SCRIPT" --stale; [ "$output" = "stale" ]            # a store but no stamp
  mkdir -p "$DAEDALUS_HOME/vault/specs" "$DAEDALUS_HOME/vault/evidence"
  printf '# x' > "$DAEDALUS_HOME/vault/specs/x.md"
  sleep 1; printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  run python3 "$SCRIPT" --stale; [ "$output" = "fresh" ]
  sleep 1; printf '# e' > "$DAEDALUS_HOME/vault/evidence/e.md"       # gates.sh churn is not a vault change
  run python3 "$SCRIPT" --stale; [ "$output" = "fresh" ]
  printf '# y' > "$DAEDALUS_HOME/vault/specs/y.md"
  run python3 "$SCRIPT" --stale; [ "$output" = "stale" ]
  [ ! -f "$REPORT" ]                                                  # no engine ran for any answer
}

@test "the stamp carries the engine's START time: a document written while the engine runs is stale after it" {
  index_engine 'sleep 1' "printf '# during' > \"$DAEDALUS_HOME/vault/specs/during.md\"" 'echo "indexed=2 purged=0"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  mkdir -p "$DAEDALUS_HOME/vault/specs"
  t0="$(python3 -c 'import time; print(time.time())')"
  run python3 "$SCRIPT" index; [ "$status" -eq 0 ]; [ "$(count 'indexed=2 purged=0')" -eq 1 ]
  python3 - "$DAEDALUS_HOME/state/recall-last-index" "$t0" "$DAEDALUS_HOME/vault/specs/during.md" <<'PY'
import os, sys
stamp, t0, during = os.path.getmtime(sys.argv[1]), float(sys.argv[2]), os.path.getmtime(sys.argv[3])
assert t0 - 0.5 <= stamp <= t0 + 0.9, (stamp, t0)       # the start, not the finish a second later
assert during > stamp, (during, stamp)
PY
  run python3 "$SCRIPT" --stale; [ "$output" = "stale" ]
}

@test "a timed-out engine is killed as a whole process group — no indexer of its keeps writing after the lock is released — and index says what it said before" {
  marker="vault-search-timeout-marker-$(basename "$BATS_TEST_TMPDIR")"
  # the engine's grandchild: the sleeping python outlives bash -c unless the GROUP is killed
  index_engine "python3 -c 'import time; time.sleep(30)' $marker & wait"
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  printf 'old' > "$DAEDALUS_HOME/state/recall-last-index"
  t0="$(date +%s)"
  run bash -c "DAEDALUS_TEST_INDEX_TIMEOUT=1 python3 '$SCRIPT' index 2>&1"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]; [ "$output" = "vault-search: engine failed; stamp untouched" ]
  [ $((t1 - t0)) -lt 5 ] || { echo "index took $((t1 - t0)) s"; return 1; }
  [ "$(cat "$DAEDALUS_HOME/state/recall-last-index")" = "old" ]
  i=0; while pgrep -f "$marker" >/dev/null 2>&1 && [ "$i" -lt 20 ]; do sleep 0.1; i=$((i + 1)); done
  if pgrep -fl "$marker"; then pkill -f "$marker"; echo "the engine's sleeper survived the timeout"; return 1; fi
  # the foreground form's words are unchanged: the count line on stdout, a failure sentence on stderr
  index_engine 'echo "indexed=4 purged=2"'
  run bash -c "python3 '$SCRIPT' index 2>/dev/null"; [ "$output" = "indexed=4 purged=2" ]
  index_engine 'echo "engine: cannot open store" >&2' 'exit 1'
  run bash -c "python3 '$SCRIPT' index 2>&1 >/dev/null"; [ "$output" = "vault-search: engine failed; stamp untouched" ]
  index_engine 'echo done'
  run bash -c "python3 '$SCRIPT' index 2>&1 >/dev/null"; [ "$output" = "vault-search: no 'indexed=N purged=M' line; stamp untouched" ]
}

# wait_log <text> — poll up to 6 s for the log's last non-empty line to carry <text>
wait_log() {
  local i=0
  while [ "$i" -lt 60 ]; do
    if [ -f "$DAEDALUS_HOME/state/recall-index.log" ] && grep -v '^$' "$DAEDALUS_HOME/state/recall-index.log" | tail -1 | grep -qF -- "$1"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  echo "log never reached '$1':"; cat "$DAEDALUS_HOME/state/recall-index.log" 2>/dev/null; return 1
}
# timed_kick <args...> — runs the script with a pipe held open, prints "<exit> <elapsed>": a child that
# inherited the pipe would hold communicate() until the engine finished
timed_kick() {
  python3 -c 'import subprocess,sys,time
t=time.time(); p=subprocess.run([sys.executable]+sys.argv[1:],capture_output=True,text=True,timeout=20)
print(p.returncode, round(time.time()-t,2)); sys.stdout.write(p.stdout)' "$SCRIPT" "$@"
}

@test "index --background returns at once with the rebuilding line while the engine runs detached; the log is framed started … by <who> / finished … indexed=N purged=M and the stamp follows; --by names the kicker" {
  index_engine 'sleep 1' 'echo "indexed=3 purged=1"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  run timed_kick index --background; [ "$status" -eq 0 ]
  case "$output" in "0 0."*|"0 1.0"*) : ;; *) echo "exit/elapsed: $output"; return 1 ;; esac
  case "$output" in *"document index: rebuilding in the background (state/recall-index.log)"*) : ;; *) echo "$output"; return 1 ;; esac
  wait_log "finished"
  [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
  head -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -Eq '^started [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} by operator$'
  tail -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -Eq '^finished [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} indexed=3 purged=1$'
  [ "$(grep -c . "$DAEDALUS_HOME/state/recall-index.log")" -eq 2 ]
  printf 'earlier holder\n' >> "$DAEDALUS_HOME/state/recall-index.log"   # the new holder truncates it
  run python3 "$SCRIPT" index --background --by vault-commit; [ "$status" -eq 0 ]
  wait_log "finished"
  head -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -q ' by vault-commit$'
  [ "$(grep -c '^started' "$DAEDALUS_HOME/state/recall-index.log")" -eq 1 ]   # one holder per file: truncated by the new holder
  [ "$(grep -c 'earlier holder' "$DAEDALUS_HOME/state/recall-index.log")" -eq 0 ]
  rm -f "$DAEDALUS_HOME/state/recall-index.log"
  run python3 "$SCRIPT" index --background --by session-start; wait_log "finished"
  head -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -q ' by session-start$'
}

@test "index --background --if-stale with a fresh index says so and spawns nothing; stale, it rebuilds" {
  index_engine 'touch "$DAEDALUS_RECALL_STORE/ran"' 'echo "indexed=1 purged=0"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  mkdir -p "$DAEDALUS_HOME/state/chroma" "$DAEDALUS_HOME/vault/specs"; printf '# x' > "$DAEDALUS_HOME/vault/specs/x.md"
  sleep 1; printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  run python3 "$SCRIPT" index --background --if-stale --by session-start; [ "$status" -eq 0 ]
  [ "$output" = "document index: fresh" ]
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/chroma/ran" ]; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  printf '# y' > "$DAEDALUS_HOME/vault/specs/y.md"
  run python3 "$SCRIPT" index --background --if-stale --by session-start
  [ "$output" = "document index: rebuilding in the background (state/recall-index.log)" ]
  wait_log "finished"; [ -f "$DAEDALUS_HOME/state/chroma/ran" ]
  rm -rf "$DAEDALUS_HOME/state/chroma"                                     # no store: a rebuild too
  run python3 "$SCRIPT" index --background --if-stale
  [ "$output" = "document index: rebuilding in the background (state/recall-index.log)" ]
  wait_log "finished"
}

@test "a kick that finds the lock held says so, leaves the rerun flag, and touches neither the log nor the stamp" {
  index_engine 'echo "indexed=1 purged=0"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  python3 -c "import fcntl,os,time; fd=os.open('$DAEDALUS_HOME/state/recall-index.lock',os.O_RDWR|os.O_CREAT); fcntl.flock(fd,fcntl.LOCK_EX); time.sleep(3)" 3>&- </dev/null >/dev/null 2>&1 &
  sleep 0.5
  run python3 "$SCRIPT" index --background --by vault-commit; [ "$status" -eq 0 ]
  [ "$output" = "document index: a rebuild is already running; it will run again when done (state/recall-index.log)" ]
  [ -f "$DAEDALUS_HOME/state/recall-index.rerun" ]
  [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]; [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
  wait
}

@test "the rerun flag: a kick during a real run makes the holder run the engine again before it exits — two started frames, the second saying rerun, the engine run twice, the flag gone" {
  index_engine 'echo run >> "$DAEDALUS_HOME/runs"' 'sleep 2' 'echo "indexed=1 purged=0"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  python3 "$SCRIPT" index --log operator 3>&- </dev/null >/dev/null 2>&1 &
  i=0; while [ ! -f "$DAEDALUS_HOME/runs" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$DAEDALUS_HOME/runs" ]
  run python3 "$SCRIPT" index --background --by vault-commit
  [ "$output" = "document index: a rebuild is already running; it will run again when done (state/recall-index.log)" ]
  [ -f "$DAEDALUS_HOME/state/recall-index.rerun" ]
  wait
  [ "$(grep -c run "$DAEDALUS_HOME/runs")" -eq 2 ]
  [ "$(grep -c '^started' "$DAEDALUS_HOME/state/recall-index.log")" -eq 2 ]
  [ "$(grep -c '^finished' "$DAEDALUS_HOME/state/recall-index.log")" -eq 2 ]
  sed -n '3p' "$DAEDALUS_HOME/state/recall-index.log" | grep -Eq '^started [0-9T:-]+ by operator \(rerun: the vault changed during the last run\)$'
  [ ! -f "$DAEDALUS_HOME/state/recall-index.rerun" ]
}

@test "a failing engine: the log carries its last stderr lines as engine: … then the failed line with the reason; no stamp" {
  index_engine 'echo "noise on stdout"' 'echo "cannot open store: permission denied" >&2' 'echo "second line" >&2' 'exit 1'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  run python3 "$SCRIPT" index --background --by vault-commit; [ "$status" -eq 0 ]
  wait_log "failed"
  [ "$(sed -n '2p' "$DAEDALUS_HOME/state/recall-index.log")" = "engine: cannot open store: permission denied" ]
  [ "$(sed -n '3p' "$DAEDALUS_HOME/state/recall-index.log")" = "engine: second line" ]
  tail -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -Eq '^failed [0-9T:-]+: engine failed; stamp untouched$'
  [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
  # no count line: the same frame, the sentence names it
  index_engine 'echo done'
  rm -f "$DAEDALUS_HOME/state/recall-index.log"
  run python3 "$SCRIPT" index --background; wait_log "failed"
  tail -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -q ": no 'indexed=N purged=M' line; stamp untouched$"
}

@test "a clone's kick is refused with PRIME_ONLY and spawns nothing; an unconfigured reindex is one line and no log; a kick from another cwd still works" {
  cp "$SRC/leaselib.py" "$DAEDALUS_HOME/core/"
  index_engine 'echo "indexed=1 purged=0"'
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  mkdir -p "$DAEDALUS_HOME/state/leases"
  printf '{"session_id":"sP","history":[]}' > "$DAEDALUS_HOME/state/leases/prime.json"
  printf '{"lease":"02","session_id":"s2","worktree":"worktrees/02"}' > "$DAEDALUS_HOME/state/leases/02.json"
  run env DAEDALUS_SESSION_ID=s2 python3 "$SCRIPT" index --background --by session-start; [ "$status" -eq 0 ]
  [ "$output" = "The document index is rebuilt by the prime; ask it to reindex" ]
  sleep 0.5; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]; [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
  write_config "  vault-query: '$FIXQ \"\$1\"'" "  store: state/chroma"
  run env DAEDALUS_SESSION_ID=sP python3 "$SCRIPT" index --background --if-stale --by session-start; [ "$status" -eq 0 ]
  [ "$output" = "document index: reindex command unconfigured; nothing started" ]
  sleep 0.5; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]
  write_recall_config "$BATS_TEST_TMPDIR/eng.sh"
  run bash -c "cd / && env DAEDALUS_SESSION_ID=sP python3 '$SCRIPT' index --background --by vault-commit"; [ "$status" -eq 0 ]
  [ "$output" = "document index: rebuilding in the background (state/recall-index.log)" ]
  wait_log "finished"; [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
}

@test "--check reports the last automatic index run from the log: none yet; finished; failed with the pointer; started with the lock held (running); started with the lock free (did not finish); a two-frame log reports the last frame" {
  cat > "$BATS_TEST_TMPDIR/q.sh" <<'EOF2'
#!/bin/bash
echo '[]'
EOF2
  chmod +x "$BATS_TEST_TMPDIR/q.sh"
  write_config "  vault-query: '$BATS_TEST_TMPDIR/q.sh \"\$1\"'" "$(printf "  vault-index: 'true'\n  store: state/chroma")"
  mkdir -p "$DAEDALUS_HOME/state/chroma"; printf 'now' > "$DAEDALUS_HOME/state/recall-last-index"
  LOG="$DAEDALUS_HOME/state/recall-index.log"
  run python3 "$SCRIPT" --check; [ "$status" -eq 0 ]
  [ "$(count 'document recall: no automatic index run recorded yet')" -eq 1 ]
  printf 'started 2026-10-15T09:00:00 by vault-commit\nfinished 2026-10-15T09:00:04 indexed=3 purged=1\n' > "$LOG"
  run python3 "$SCRIPT" --check
  [ "$(count 'document recall: last automatic index 2026-10-15T09:00:00 by vault-commit: indexed=3 purged=1')" -eq 1 ]
  printf 'started 2026-10-15T09:00:00 by session-start\nengine: cannot open store\nfailed 2026-10-15T09:00:04: engine failed; stamp untouched\n' > "$LOG"
  run python3 "$SCRIPT" --check
  [ "$(count "document recall: last automatic index 2026-10-15T09:00:00 by session-start FAILED: engine failed; stamp untouched (state/recall-index.log has the engine's output)")" -eq 1 ]
  printf 'started 2026-10-15T09:00:00 by operator\nengine: warming up\n' > "$LOG"
  python3 -c "import fcntl,os,time; fd=os.open('$DAEDALUS_HOME/state/recall-index.lock',os.O_RDWR|os.O_CREAT); fcntl.flock(fd,fcntl.LOCK_EX); time.sleep(3)" 3>&- </dev/null >/dev/null 2>&1 &
  sleep 0.5
  run python3 "$SCRIPT" --check
  [ "$(count 'document recall: an index run by operator is running since 2026-10-15T09:00:00')" -eq 1 ]
  wait
  run python3 "$SCRIPT" --check
  [ "$(count "document recall: the index run by operator started 2026-10-15T09:00:00 and did not finish (killed, or the machine slept); the next vault commit or the prime's next session start runs it again")" -eq 1 ]
  printf 'started 2026-10-15T09:00:00 by vault-commit\nfinished 2026-10-15T09:00:04 indexed=3 purged=1\nstarted 2026-10-15T09:00:04 by vault-commit (rerun: the vault changed during the last run)\nfinished 2026-10-15T09:00:08 indexed=4 purged=0\n' > "$LOG"
  run python3 "$SCRIPT" --check
  [ "$(count 'last automatic index 2026-10-15T09:00:04 by vault-commit: indexed=4 purged=0')" -eq 1 ]
  [ "$(count 'last automatic index')" -eq 1 ]
  # the reindex command unconfigured: that line, never a last-run line
  write_config "  vault-query: '$BATS_TEST_TMPDIR/q.sh \"\$1\"'" "  store: state/chroma"
  run python3 "$SCRIPT" --check
  [ "$(count 'reindex command unconfigured')" -eq 1 ]; [ "$(count 'automatic index')" -eq 0 ]
}
