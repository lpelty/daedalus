# core/tests/fixtures/leases/setup.bash — sourced by lease-related suites.
lease_fixture() {
  # pwd -P: the bats temp dir sits behind /var -> /private/var, and every path
  # a Python hook prints is resolved (verifylib.ROOT), so the home must be too.
  DAEDALUS_HOME="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/.claude" \
           "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault/evidence" "$DAEDALUS_HOME/vault/proposals" \
           "$DAEDALUS_HOME/vault/sessions" "$BATS_TEST_TMPDIR/sessions"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/leaselib.py" "$DAEDALUS_HOME/core/"
  for f in lease.sh lease-board.py session-start.py boundary-hook.py guard-bash.py verify-hook.py \
           fingerprint.sh gates.sh manifest-append.py vault-commit.sh pitfall-inject.py code-context.py; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DAEDALUS_HOME/core/"
  done
  printf '{"permissions":{"deny":["Edit(./core/**)","Edit(./CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  printf 'x\n' > "$DAEDALUS_HOME/CLAUDE.md"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
  nested: sub=https://example.com/sub.git
gates:
  - true
verify:
  refute: false
  refute_off_reason: bats fixture — a real claude must never be invoked in tests
EOF
  T="$DAEDALUS_HOME/target/thing"
  git init -q -b main "$T"; printf 'a\n' > "$T/a.txt"; printf 'sub/\n' > "$T/.gitignore"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q --bare -b main "$BATS_TEST_TMPDIR/origin.git"
  git -C "$T" remote add origin "$BATS_TEST_TMPDIR/origin.git"; git -C "$T" push -q -u origin main
  git -C "$T" remote set-head origin main
  git init -q -b main "$T/sub"; printf 'n\n' > "$T/sub/n.txt"
  git -C "$T/sub" add -A; git -C "$T/sub" -c user.email=t@x -c user.name=t commit -q -m n
  git init -q --bare -b main "$BATS_TEST_TMPDIR/sub-origin.git"
  git -C "$T/sub" remote add origin "$BATS_TEST_TMPDIR/sub-origin.git"; git -C "$T/sub" push -q -u origin main
  git -C "$T/sub" remote set-head origin main
  git init -q -b main "$DAEDALUS_HOME/vault"
  git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  printf 'target/\nvault/\nconfig.yaml\nstate/\nworktrees/\n.claude/settings.local.json\n' > "$DAEDALUS_HOME/.gitignore"
  git init -q -b main "$DAEDALUS_HOME"; git -C "$DAEDALUS_HOME" add -A
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m i
  export DAEDALUS_HOME CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"
  unset DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_LEASE DIRECT_CALL_ID
}

# registry_entry <pid> <session-id> [kind] [entrypoint] [name] — a Claude Code
# session registry file as observed on 2.1.282 (spec §4.8, A11). startedAt is
# epoch ms; procStart is the ps -o lstart= string of that pid.
registry_entry() {
  local pid="$1" sid="$2" kind="${3:-interactive}" ep="${4:-cli}" name="${5:-daedalus-xx}" started
  started="$(python3 -c 'import subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True).stdout.strip()
print(int(time.mktime(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000) if out else 0)' "$pid")"
  printf '{"pid":%s,"sessionId":"%s","startedAt":%s,"kind":"%s","entrypoint":"%s","name":"%s","nameSource":"derived"}\n' \
    "$pid" "$sid" "$started" "$kind" "$ep" "$name" > "$BATS_TEST_TMPDIR/sessions/$pid.json"
}

# live_pid — a process that outlives the test step (a sleep in the background);
# every pid is recorded in $BATS_TEST_TMPDIR/live-pids and killed by
# teardown_live. A file, not a variable: callers run it as "$(live_pid)", a
# subshell, where an assignment to LIVE_PIDS would be lost — and bats waits
# at the end of the file for every sleep nobody killed (measured: a leaked
# sleep 300 held the suite for the full five minutes). The sleep's
# stdin/stdout/stderr and bats's fd 3 are detached too: a sleep holding the
# substitution pipe makes the caller wait for EOF, one holding fd 3 makes
# bats wait at test end.
live_pid() {
  sleep 300 3>&- </dev/null >/dev/null 2>&1 & LIVE_PID=$!
  printf '%s\n' "$LIVE_PID" >> "$BATS_TEST_TMPDIR/live-pids"
  printf '%s\n' "$LIVE_PID"
}
teardown_live() {
  [ -f "$BATS_TEST_TMPDIR/live-pids" ] || return 0
  while read -r p; do kill "$p" 2>/dev/null; done < "$BATS_TEST_TMPDIR/live-pids"
  true
}

# ps_ms <pid> — the epoch-millisecond start time of a live pid, exactly as
# leaselib.proc_started_of computes it; a lease whose proc_started carries this
# value for a live pid reads "live", one that carries 1 reads "stale" (pid reuse).
ps_ms() { python3 -c 'import subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True).stdout.strip()
print(int(time.mktime(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000) if out else 0)' "$1"; }

hook_json() {   # hook_json <event> <session-id> [extra-json-fields]
  printf '{"hook_event_name":"%s","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"%s}' \
    "$1" "$2" "$BATS_TEST_TMPDIR" "$2" "${3:+,$3}"
}
lease_json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))' "$DAEDALUS_HOME/state/leases/$1.json" "$2"; }
