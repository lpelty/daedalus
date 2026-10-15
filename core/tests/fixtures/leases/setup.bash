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
           fingerprint.sh gates.sh manifest-append.py vault-commit.sh pitfall-inject.py code-context.py \
           transcriptlib.py capture.py prepush.py distcheck.py upgrade.py update.py capture-tick.sh \
           amilib.py frame-jack.py ami-daemon.py ami-hook.py; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DAEDALUS_HOME/core/"
  done
  printf '{"permissions":{"deny":["Edit(/core/**)","Edit(/CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
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
  export DAEDALUS_NO_COMMAND=1      # never a shim in the real ~/.local/bin (setup_suite.bash sets it too)
  unset DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_LEASE DIRECT_CALL_ID
}

# registry_entry <pid> <session-id> [kind] [entrypoint] [name] [startedAt] — a
# Claude Code session registry file as observed on 2.1.282 (spec §4.8, A11).
# startedAt is epoch ms, by default that pid's real start time from ps (a real
# entry lags lstart by under a second: 936 ms measured on 2.1.282); pass a
# sixth argument to fake a left-behind entry whose pid another process now holds.
# A seventh argument is the entry's procStart: the process start as Claude Code
# records it, a UTC "%a %b %d %H:%M:%S %Y" string (2.1.295/296 write it; the
# fixture leaves it out by default, as 2.1.282 did). startedAt is the moment
# the entry was WRITTEN, after the process started: 936 ms later measured on
# 2.1.282, 2.1–3.0 s on 2.1.295/296 after an OS restart (2026-10-10).
registry_entry() {
  local pid="$1" sid="$2" kind="${3:-interactive}" ep="${4:-cli}" name="${5:-daedalus-xx}" started="${6:-}" pstart="${7:-}"
  [ -n "$started" ] || started="$(ps_ms "$pid")"
  local extra=""
  [ -z "$pstart" ] || extra=",\"procStart\":\"$pstart\""
  printf '{"pid":%s,"sessionId":"%s","startedAt":%s,"kind":"%s","entrypoint":"%s","name":"%s","nameSource":"derived"%s}\n' \
    "$pid" "$sid" "$started" "$kind" "$ep" "$name" "$extra" > "$BATS_TEST_TMPDIR/sessions/$pid.json"
}

# utc_lstart <epoch-ms> — the procStart string Claude Code writes for a process
# started at that instant (UTC, the ps lstart layout).
utc_lstart() { python3 -c 'import sys,time; print(time.strftime("%a %b %d %H:%M:%S %Y", time.gmtime(int(sys.argv[1])//1000)))' "$1"; }

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
# leaselib.proc_started_of computes it (ps under TZ=UTC, read with timegm: the
# local-zone read is ambiguous in the hour the clocks fall back); a lease whose
# proc_started carries this value for a live pid reads "live", one that
# carries 1 reads "stale" (pid reuse).
ps_ms() { python3 -c 'import calendar,os,subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True,env=dict(os.environ,TZ="UTC")).stdout.strip()
print(int(calendar.timegm(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000) if out else 0)' "$1"; }

hook_json() {   # hook_json <event> <session-id> [extra-json-fields]
  printf '{"hook_event_name":"%s","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"%s}' \
    "$1" "$2" "$BATS_TEST_TMPDIR" "$2" "${3:+,$3}"
}
lease_json() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]))' "$DAEDALUS_HOME/state/leases/$1.json" "$2"; }

# trunk_moves [file] [line] — someone else moves origin/main, from a separate clone
# (the way trunk moves in real life), and target/thing fetches it. Never a push from
# target/thing: once a window exists its pre-push hook refuses a trunk push that no
# promotion confirmed (spec §7.3). TRUNK_MOVES_NO_FETCH=1 leaves target/thing's
# origin/main where it was, so a test passes only if the command under test fetches.
trunk_moves() { _origin_moves "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/elsewhere" \
                  "$DAEDALUS_HOME/target/thing" "${1:-b.txt}" "${2:-trunk moved}"; }
# sub_moves [file] [line] — the same for the nested repo's origin (sub-origin.git),
# fetched (unless TRUNK_MOVES_NO_FETCH=1) into target/thing/sub.
sub_moves() { _origin_moves "$BATS_TEST_TMPDIR/sub-origin.git" "$BATS_TEST_TMPDIR/elsewhere-sub" \
                "$DAEDALUS_HOME/target/thing/sub" "${1:-m.txt}" "${2:-sub trunk moved}"; }
_origin_moves() {
  local origin="$1" o="$2" target="$3" f="$4" msg="$5"
  [ -d "$o/.git" ] || git clone -q "$origin" "$o"
  git -C "$o" pull -q --ff-only origin main
  printf '%s\n' "$msg" >> "$o/$f"
  git -C "$o" add -A; git -C "$o" -c user.email=t@x -c user.name=t commit -q -m "$msg"
  git -C "$o" push -q origin HEAD:main
  [ "${TRUNK_MOVES_NO_FETCH:-}" = 1 ] || git -C "$target" fetch -q origin
}

# add_nested <rel> — one more nested repo at target/thing/<rel>, with its own bare origin and origin/HEAD, added to
# config target.nested and to the outer repo's .gitignore (committed and pushed, so every window's outer worktree
# ignores it too). Call it before the first window is made.
add_nested() {
  local rel="$1" T="$DAEDALUS_HOME/target/thing" o="$BATS_TEST_TMPDIR/$1-origin.git"
  git init -q -b main "$T/$rel"; printf 'n\n' > "$T/$rel/n.txt"
  git -C "$T/$rel" add -A; git -C "$T/$rel" -c user.email=t@x -c user.name=t commit -q -m n
  git init -q --bare -b main "$o"
  git -C "$T/$rel" remote add origin "$o"; git -C "$T/$rel" push -q -u origin main
  git -C "$T/$rel" remote set-head origin main
  printf '%s/\n' "$rel" >> "$T/.gitignore"
  git -C "$T" add .gitignore; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m "ignore $rel"
  git -C "$T" push -q origin main
  sed -i '' "s|^  nested: \(.*\)\$|  nested: \1,$rel=https://example.com/$rel.git|" "$DAEDALUS_HOME/config.yaml"
}

# swept_with_work <NN>... — one commit in every repo of each window's worktree (the outer one and each nested one
# present), then the window's lease files are removed: swept, with unpromoted work waiting on lease/<NN>.
swept_with_work() {
  local nn d
  for nn in "$@"; do
    for d in "$DAEDALUS_HOME/worktrees/$nn/thing" "$DAEDALUS_HOME/worktrees/$nn/thing"/*; do
      [ -e "$d/.git" ] || continue
      printf 'w%s\n' "$nn" >> "$d/w.txt"
      git -C "$d" add w.txt; git -C "$d" -c user.email=t@x -c user.name=t commit -q -m "work $nn in ${d##*/}"
    done
    rm -f "$DAEDALUS_HOME/state/leases/$nn.json" "$DAEDALUS_HOME/state/leases/$nn.seen" "$DAEDALUS_HOME/state/leases/$nn.changed"
  done
}

# count_git — a directory holding `git` -> fake-git-count, for the front of PATH; every call lands in $GIT_LOG.
count_git() {
  local d="$BATS_TEST_TMPDIR/count-git"
  mkdir -p "$d"; ln -sf "$BATS_TEST_DIRNAME/fixtures/leases/fake-git-count" "$d/git"
  printf '%s\n' "$d"
}
