#!/usr/bin/env bats
# Pins core/vault-commit.sh: the pen's holder (or an operator shell) commits, a dead holder's pen moves on, index.lock retry, per-file claim staging (spec §4.7).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() {
  lease_fixture; VC="$DAEDALUS_HOME/core/vault-commit.sh"
  mkdir -p "$DAEDALUS_HOME/vault/exchange/messages"
  printf -- '---\ntype: evidence\nrun-id: 20260101-000000-abcdef\nresult: PASS\ncreated: 2026-01-01T00:00:00\n---\n' > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md"
  git -C "$DAEDALUS_HOME/vault" add -A; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q -m evidence
  mkdir -p "$DAEDALUS_HOME/state/leases"
  for p in 01:sA 02:sB; do nn="${p%%:*}"; s="${p##*:}"; pid="$(live_pid)"; registry_entry "$pid" "$s"
    printf '{"lease":"%s","session_id":"%s","worktree":"worktrees/%s","pid":1,"proc_started":1}' "$nn" "$s" "$nn" > "$DAEDALUS_HOME/state/leases/$nn.json"; touch "$DAEDALUS_HOME/state/leases/$nn.seen"; done
  printf '{"session_id":"sA","history":[]}' > "$DAEDALUS_HOME/state/leases/prime.json"
}
teardown() { teardown_live; }
doc() { # doc <relpath> <status> <lease> [evidence-run]
  { printf -- '---\ntype: proposal\nstatus: %s\nupdated-by: daedalus\ncreated: 2026-02-01\nlease: %s\n' "$2" "$3"; [ -n "${4:-}" ] && printf 'evidence-run: %s\n' "$4"; printf -- '---\n# x\n'; } > "$DAEDALUS_HOME/vault/$1"
}

@test "a session behind a live pen holder is told in one line that the holder's commit carries its files (exit 3), never a peer name, nothing staged; an operator shell may commit; a visitor is told its caller commits" {
  doc proposals/PROP-1.md PROPOSED 02
  run --separate-stderr env DAEDALUS_SESSION_ID=sB bash "$VC"; [ "$status" -eq 3 ] || { echo "$status $output $stderr"; return 1; }
  [ -z "$output" ] || { echo "stdout: $output"; return 1; }
  [ "$stderr" = "daedalus: Window 01 holds the pen and commits the vault, this session's files included." ] || { echo "$stderr"; return 1; }
  case "$stderr" in *daedalus-0*) echo "$stderr"; return 1 ;; *) : ;; esac
  [ -z "$(git -C "$DAEDALUS_HOME/vault" diff --cached --name-only)" ]
  [ "$(git -C "$DAEDALUS_HOME/vault" log --format=%s | wc -l | tr -d ' ')" = 2 ]
  run --separate-stderr env DIRECT_CALL_ID=x DAEDALUS_SESSION_ID=sV bash "$VC"; [ "$status" -eq 3 ]
  [ "$stderr" = "daedalus: This is a direct-call session; it does not commit the vault — its caller's session does." ] || { echo "$stderr"; return 1; }
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash '$VC'"; [ "$status" -eq 0 ]
  git -C "$DAEDALUS_HOME/vault" log -1 --format=%s | grep -q 'vault: prime commit'
}

@test "the pen's holder has ended: the next terminal session's vault-commit.sh takes the pen, says so in one line, and commits (one commit)" {
  cat "$DAEDALUS_HOME/state/leases/01.json" > /dev/null
  rm -f "$BATS_TEST_TMPDIR"/sessions/*.json                  # nobody is in the registry: both windows have ended ...
  pb="$(live_pid)"; registry_entry "$pb" sB                  # ... but window 02's session is back, in a terminal
  printf '{"lease":"02","session_id":"sB","worktree":"worktrees/02","pid":%s,"proc_started":%s}' "$pb" "$(ps_ms "$pb")" > "$DAEDALUS_HOME/state/leases/02.json"
  printf 'log\n' > "$DAEDALUS_HOME/vault/sessions/2026-10-16-001.md"
  n0="$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)"
  run env DAEDALUS_SESSION_ID=sB bash "$VC"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in "daedalus: The pen's holder, window 01, has ended; this session holds the pen now and commits the vault."*"daedalus: committed: "*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)" = $((n0 + 1)) ]
  git -C "$DAEDALUS_HOME/vault" show --name-only --format= HEAD | grep -q 'sessions/2026-10-16-001.md'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["session_id"]=="sB" and d["history"][-1]["auto"]=="commit", d' "$DAEDALUS_HOME/state/leases/prime.json"
}

@test "a live other lease's IMPLEMENTED claim is left unstaged and named; the rest commits; a dead lease's unverified claim stops the commit naming the dead window; two files with one number stop it" {
  doc proposals/PROP-2.md IMPLEMENTED 02
  doc proposals/PROP-3.md PROPOSED 01
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "prime commit"; [ "$status" -eq 0 ]
  case "$output" in *"left uncommitted: PROP-2.md (window 02, still live) — its own session verifies it"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME/vault" log -1 --format=%s | grep -q "prime commit"
  git -C "$DAEDALUS_HOME/vault" status --porcelain | grep -q 'PROP-2.md'
  ! git -C "$DAEDALUS_HOME/vault" status --porcelain | grep -q 'PROP-3.md'
  rm -f "$DAEDALUS_HOME/state/leases/02.json"   # window 02 is gone: its claim is now the prime's to answer for
  run env DAEDALUS_SESSION_ID=sA bash "$VC"; [ "$status" -ne 0 ]
  case "$output" in *"PROP-2.md claims IMPLEMENTED with no evidence-run"*"window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  doc proposals/PROP-2.md IMPLEMENTED 02 20260101-000000-abcdef
  printf -- '---\nid: EX-025\nlease: 01\n---\n' > "$DAEDALUS_HOME/vault/exchange/messages/EX-025-capture-lock.md"
  printf -- '---\nid: EX-025\nlease: 01\n---\n' > "$DAEDALUS_HOME/vault/exchange/messages/EX-025-menu.md"
  run env DAEDALUS_SESSION_ID=sA bash "$VC"; [ "$status" -ne 0 ]
  case "$output" in *"EX-025 exists twice"*"the later one renumbers its own file"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a fake git that fails once with index.lock is retried; --push pushes; the default message names the date and the leases" {
  git init -q --bare "$BATS_TEST_TMPDIR/vault-origin.git"; git -C "$DAEDALUS_HOME/vault" remote add origin "$BATS_TEST_TMPDIR/vault-origin.git"; git -C "$DAEDALUS_HOME/vault" push -q -u origin main
  mkdir -p "$BATS_TEST_TMPDIR/bin"; cat > "$BATS_TEST_TMPDIR/bin/git" <<'EOF'
#!/usr/bin/env bash
# Flakes ONCE on the commit subcommand wherever it sits: vault-commit.sh runs
# `git -C <vault> [-c user.email=… -c user.name=…] commit …`, so the
# subcommand is never at a fixed position. The real git is the first one on
# PATH past this file's own directory: `command -v -p git` returns THIS fake
# under bash 3.2 when its directory leads PATH (measured), and exec'ing it
# re-executes the fake forever.
me="$(cd "$(dirname "$0")" && pwd)"; real=""
IFS=:; for d in $PATH; do [ "$d" = "$me" ] && continue; [ -x "$d/git" ] && { real="$d/git"; break; }; done; unset IFS
[ -n "$real" ] || { echo "fake git: no real git on PATH" >&2; exit 127; }
case " $* " in
  *" commit "*) if [ ! -f "$FLAKE_ONCE" ]; then touch "$FLAKE_ONCE"; echo "fatal: Unable to create '$2/.git/index.lock': File exists." >&2; exit 128; fi ;;
esac
exec "$real" "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/git"; export FLAKE_ONCE="$BATS_TEST_TMPDIR/flaked"
  doc proposals/PROP-4.md PROPOSED 01
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run env DAEDALUS_SESSION_ID=sA bash "$VC" --push; [ "$status" -eq 0 ]
  [ -f "$FLAKE_ONCE" ]
  git -C "$DAEDALUS_HOME/vault" log -1 --format=%s | grep -q "vault: prime commit $(date +%Y-%m-%d) (leases: 01, 02)"
  [ "$(git -C "$BATS_TEST_TMPDIR/vault-origin.git" rev-parse main)" = "$(git -C "$DAEDALUS_HOME/vault" rev-parse HEAD)" ]
}

@test "an unreadable lease file refuses the commit before anything is staged — prime and operator shell alike, naming window 02's lease file (never a silent crash, never a fail-open commit)" {
  doc proposals/PROP-2.md IMPLEMENTED 02 20260101-000000-abcdef   # a verified claim from window 02, whose session is live
  printf 'not json' > "$DAEDALUS_HOME/state/leases/02.json"
  # The claim report itself fails closed: no row (a `live: false` row would hand window 02's claim to the committer).
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID python3 '$DAEDALUS_HOME/core/verifylib.py' --vault-claims"; [ "$status" -eq 1 ]
  case "$output" in *"daedalus: The lease file for window 02 cannot be read"*) : ;; *) echo "report: $output"; return 1 ;; esac
  case "$output" in *'"live"'*) echo "report: $output"; return 1 ;; *) : ;; esac
  run env DAEDALUS_SESSION_ID=sA bash "$VC"; [ "$status" -ne 0 ]
  case "$output" in *"The lease file for window 02 cannot be read"*) : ;; *) echo "prime: $output"; return 1 ;; esac
  [ -z "$(git -C "$DAEDALUS_HOME/vault" diff --cached --name-only)" ]
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash '$VC'"; [ "$status" -ne 0 ]
  case "$output" in *"daedalus: "*"The lease file for window 02 cannot be read"*) : ;; *) echo "operator: $output"; return 1 ;; esac
  [ -z "$(git -C "$DAEDALUS_HOME/vault" diff --cached --name-only)" ]
  git -C "$DAEDALUS_HOME/vault" log -1 --format=%s | grep -q '^evidence$'   # nothing was committed
}

# A vault that lives inside the Daedalus home repo (no vault/.git, the directory
# tracked by the parent — the layout doctor accepts) commits through the parent
# repo, with a pathspec that leaves the parent's other staged work alone.
@test "a vault tracked by the parent repo (no vault/.git) commits through the parent, vault paths only, refusing by name while the parent has other staged work; a vault tracked by neither is refused by name" {
  rm -rf "$DAEDALUS_HOME/vault/.git"
  sed -i '' '/^vault\/$/d' "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "vault absorbed"
  mkdir -p "$DAEDALUS_HOME/vault/sessions/2026/10"; printf '# log\n' > "$DAEDALUS_HOME/vault/sessions/2026/10/2026-10-14-047.md"
  printf 'other\n' > "$DAEDALUS_HOME/other.txt"; git -C "$DAEDALUS_HOME" add other.txt
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "session log 047"; [ "$status" -ne 0 ]
  case "$output" in *"the repository holding the vault has staged changes outside vault/ (other.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" reset -q -- other.txt
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "session log 047"; [ "$status" -eq 0 ]
  case "$output" in *"committed: session log 047"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME" log -1 --format=%s)" = "session log 047" ]
  [ "$(git -C "$DAEDALUS_HOME" show --name-only --format= HEAD)" = "vault/sessions/2026/10/2026-10-14-047.md" ]
  [ "$(git -C "$DAEDALUS_HOME" status --porcelain -- vault)" = "" ]
  [ "$(git -C "$DAEDALUS_HOME" status --porcelain -- other.txt)" = "?? other.txt" ]   # the parent's own work is untouched
  git -C "$DAEDALUS_HOME" rm -rq --cached vault; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "untracked"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m x; [ "$status" -ne 0 ]
  case "$output" in *"is neither its own git repository nor tracked by the Daedalus home"*) : ;; *) echo "$output"; return 1 ;; esac
}

# The Daedalus home may itself sit inside a larger repository (the ship repo)
# that tracks the vault. The staged-elsewhere check must see the whole index,
# not only the home directory, or the operator's other staged work is swept
# into the vault commit (fresh-context review, 2026-10-14).
@test "a home inside a larger repository that tracks the vault: staged work anywhere else in that repository is refused by name; then the commit carries vault paths only" {
  rm -rf "$DAEDALUS_HOME/vault/.git" "$DAEDALUS_HOME/.git"
  sed -i '' '/^vault\/$/d' "$DAEDALUS_HOME/.gitignore"
  SHIP="$(dirname "$DAEDALUS_HOME")"
  printf '/origin.git/\n/sub-origin.git/\n/sessions/\n/elsewhere*/\n/transcripts/\n/dae/target/\n/dae/state/\n/dae/worktrees/\n' > "$SHIP/.gitignore"   # anchored: the vault has a sessions/ too
  git init -q -b main "$SHIP"; git -C "$SHIP" add -A; git -C "$SHIP" -c user.email=t@x -c user.name=t commit -q -m ship
  mkdir -p "$DAEDALUS_HOME/vault/sessions/2026/10"; printf '# log\n' > "$DAEDALUS_HOME/vault/sessions/2026/10/2026-10-14-048.md"
  doc proposals/PROP-2.md IMPLEMENTED 02     # window 02 is live: its claim is left out, by name
  doc proposals/PROP-3.md PROPOSED 01
  printf 'ship\n' > "$SHIP/ship-file.txt"; git -C "$SHIP" add ship-file.txt
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "log 048"; [ "$status" -ne 0 ]
  case "$output" in *"staged changes outside vault/ (ship-file.txt)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$SHIP" reset -q -- ship-file.txt
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "log 048"; [ "$status" -eq 0 ]
  case "$output" in *"left uncommitted: PROP-2.md (window 02, still live)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$SHIP" show --name-only --format= HEAD | sort | tr '\n' ' ')" = "dae/vault/proposals/PROP-3.md dae/vault/sessions/2026/10/2026-10-14-048.md " ] || { git -C "$SHIP" show --name-only --format= HEAD; git -C "$SHIP" status --porcelain; return 1; }
  [ "$(git -C "$SHIP" status --porcelain -- ship-file.txt)" = "?? ship-file.txt" ]
  [ "$(git -C "$SHIP" status --porcelain -- dae/vault/proposals/PROP-2.md)" = "?? dae/vault/proposals/PROP-2.md" ]
  run env DAEDALUS_SESSION_ID=sA bash "$VC" --push; [ "$status" -ne 0 ]
  case "$output" in *"the repository holding the vault has no origin to push to"*) : ;; *) echo "$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/state/leases/02.json"     # window 02 gone: its unverified claim stops the commit, naming the window
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "must refuse"; [ "$status" -ne 0 ]
  case "$output" in *"PROP-2.md"*"window 02 has no live session, so the prime answers for it"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$SHIP" log -1 --format=%s)" = "log 048" ]
}

@test "a vault the home repository tracks but still ignores is refused naming the .gitignore line; a staged vault file with a non-ASCII name is not mistaken for work outside vault/" {
  rm -rf "$DAEDALUS_HOME/vault/.git"
  git -C "$DAEDALUS_HOME" add -f vault; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "vault force-added, still ignored"
  printf '# x\n' > "$DAEDALUS_HOME/vault/proposals/note.md"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "ignored"; [ "$status" -ne 0 ]
  case "$output" in *"vault/ is ignored by $DAEDALUS_HOME/.gitignore (the rule \`vault/\`)"*"remove that line"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"git add failed"*) echo "the generic sentence, not the cause: $output"; return 1 ;; *) : ;; esac
  sed -i '' '/^vault\/$/d' "$DAEDALUS_HOME/.gitignore"; git -C "$DAEDALUS_HOME" add .gitignore
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "ignored"; [ "$status" -ne 0 ]
  case "$output" in *"staged changes outside vault/ (.gitignore)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "un-ignore the vault" -- .gitignore
  printf '# é\n' > "$DAEDALUS_HOME/vault/proposals/café.md"; git -C "$DAEDALUS_HOME" add -- "vault/proposals/café.md"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "accents"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$DAEDALUS_HOME" -c core.quotepath=false show --name-only --format= HEAD | sort | tr '\n' ' ')" = "vault/proposals/café.md vault/proposals/note.md " ]
}

@test "a vault un-ignored by a negation line (the .gitignore daedalus update writes in a home that keeps its own vault) is committed, not refused" {
  rm -rf "$DAEDALUS_HOME/vault/.git"
  printf '!/vault/\n' >> "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add .gitignore vault; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "the home keeps its vault"
  git -C "$DAEDALUS_HOME" check-ignore -v --no-index -- vault >/dev/null   # the trap: with -v git reports the negation as a match, exit 0
  printf '# n\n' > "$DAEDALUS_HOME/vault/proposals/negated.md"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "negated"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$DAEDALUS_HOME" show --name-only --format= HEAD)" = "vault/proposals/negated.md" ]
}

# --- the document index follows the vault (reindex design 2026-10-15, §3.4) ---
# recall_engine <body...> — a recall: block naming a fake index engine that creates the store, then runs the body
recall_engine() {
  cp "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
  { printf '#!/bin/bash\nmkdir -p "$DAEDALUS_RECALL_STORE"\n'; printf '%s\n' "$@"; } > "$BATS_TEST_TMPDIR/eng.sh"
  chmod +x "$BATS_TEST_TMPDIR/eng.sh"
  printf "recall:\n  vault-query: 'echo []'\n  vault-index: '%s'\n  store: state/chroma\n" "$BATS_TEST_TMPDIR/eng.sh" >> "$DAEDALUS_HOME/config.yaml"
}
wait_log() {   # wait_log <text> — up to 6 s for the log's last line to carry <text>
  local i=0
  while [ "$i" -lt 60 ]; do
    if [ -f "$DAEDALUS_HOME/state/recall-index.log" ] && tail -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -qF -- "$1"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  echo "log never reached '$1':"; cat "$DAEDALUS_HOME/state/recall-index.log" 2>/dev/null; return 1
}

@test "after a commit it made, vault-commit.sh kicks the document index in the background and says so; the stamp and the log follow; nothing to commit kicks nothing" {
  recall_engine 'sleep 1' 'echo "indexed=3 purged=1"'
  doc proposals/PROP-5.md PROPOSED 01
  t0="$(date +%s)"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "with index"; t1="$(date +%s)"; [ "$status" -eq 0 ]
  case "$output" in *"committed: with index"*"document index: rebuilding in the background (state/recall-index.log)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ $((t1 - t0)) -lt 2 ] || { echo "the commit waited for the engine: $((t1 - t0)) s"; return 1; }   # the engine sleeps 1 s; the script returned before it finished
  wait_log "finished"
  head -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -q ' by vault-commit$'
  tail -1 "$DAEDALUS_HOME/state/recall-index.log" | grep -q 'indexed=3 purged=1$'
  [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
  rm -f "$DAEDALUS_HOME/state/recall-index.log" "$DAEDALUS_HOME/state/recall-last-index"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "again"; [ "$status" -eq 0 ]
  case "$output" in *"nothing to commit"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"document index"*) echo "a kick with nothing committed: $output"; return 1 ;; *) : ;; esac
  sleep 1; [ ! -f "$DAEDALUS_HOME/state/recall-index.log" ]; [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
}

@test "an index engine that fails leaves the commit made and the exit 0, the log saying failed; a vault-search.py that cannot run is one line, never a failed commit" {
  recall_engine 'echo "store is read-only" >&2' 'exit 1'
  doc proposals/PROP-6.md PROPOSED 01
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "engine fails"; [ "$status" -eq 0 ]
  case "$output" in *"committed: engine fails"*"document index: rebuilding in the background"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/vault" log -1 --format=%s)" = "engine fails" ]
  wait_log "failed"
  grep -q '^engine: store is read-only$' "$DAEDALUS_HOME/state/recall-index.log"
  [ ! -f "$DAEDALUS_HOME/state/recall-last-index" ]
  printf '#!/usr/bin/env python3\nimport sys; sys.exit(3)\n' > "$DAEDALUS_HOME/core/vault-search.py"   # the runner itself broken
  doc proposals/PROP-7.md PROPOSED 01
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "runner broken"; [ "$status" -eq 0 ]
  case "$output" in *"committed: runner broken"*"document index: not started (core/vault-search.py exited 3); run it with python3 core/vault-search.py index"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/vault" log -1 --format=%s)" = "runner broken" ]
}

# The pen commits every window's session log (2026-10-19): a window that closes while the pen's holder is live marks
# its log for the holder (close.sh → mark-log-pending); the holder's Stop and SessionEnd hooks commit the marked logs
# and nothing else; its full commits leave out an open window's log (work in progress) and name whose logs they carried.
own_log() { # own_log <NN> <session> <date> <n> — reserve the log in the lease and write it
  python3 - "$DAEDALUS_HOME/state/leases/$1.json" "$3" "$4" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["logs"] = {sys.argv[2]: int(sys.argv[3])}; json.dump(d, open(p, "w"))
PY
  mkdir -p "$DAEDALUS_HOME/vault/sessions/${3:0:4}/${3:5:2}"
  printf -- '---\ntype: session\nlease: %s\n---\n# log of %s\n' "$1" "$2" > "$DAEDALUS_HOME/vault/sessions/${3:0:4}/${3:5:2}/$3-$(printf %03d "$4").md"
}
closes() { # closes <session> — what close.sh does past capture: the vault commit, then on exit 3 the pending mark
  local rc=0 out
  out="$(env DAEDALUS_SESSION_ID="$1" bash "$VC" 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -eq 3 ]; then env DAEDALUS_SESSION_ID="$1" python3 "$DAEDALUS_HOME/core/leaselib.py" mark-log-pending; fi
  return "$rc"
}
stop_hook() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$1" | CLAUDE_PROJECT_DIR="$DAEDALUS_HOME" bash "$DAEDALUS_HOME/core/vault-pending-hook.sh"; }

@test "a window closes while the pen's holder is live: its log is saved and it is told plainly who commits it; the holder's next Stop commits that log alone; the holder's close then commits the rest; no order, no pen move" {
  own_log 02 sB 2026-10-19 7
  own_log 01 sA 2026-10-19 6                                            # the holder's own log, still being written
  printf 'prime notes\n' > "$DAEDALUS_HOME/vault/notes.md"               # the holder's unrelated edit
  n0="$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)"
  run closes sB; [ "$status" -eq 3 ] || { echo "$status $output"; return 1; }
  case "$output" in *"Window 01 holds the pen and commits the vault, this session's files included."*"Your log is saved; window 01 holds the pen and commits it."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)" = "$n0" ]   # nothing committed by window 02
  run stop_hook sA; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(git -C "$DAEDALUS_HOME/vault" show --name-only --format= HEAD)" = "sessions/2026/10/2026-10-19-007.md" ]
  git -C "$DAEDALUS_HOME/vault" status --porcelain | grep -q '^?? notes.md$'
  git -C "$DAEDALUS_HOME/vault" status --porcelain -uall | grep -q '2026-10-19-006.md'
  [ -z "$(ls -A "$DAEDALUS_HOME/state/vault-pending")" ]                 # the marker went with the commit
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "holder closes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(git -C "$DAEDALUS_HOME/vault" status --porcelain)" ]
}

@test "only the pen's holder's hook commits pending logs: another window's Stop, or a hook with no session id, commits nothing" {
  own_log 02 sB 2026-10-19 7
  run closes sB; [ "$status" -eq 3 ]
  n0="$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)"
  run stop_hook sB; [ "$status" -eq 0 ]; [ -z "$output" ]
  run bash -c "printf '{}' | CLAUDE_PROJECT_DIR='$DAEDALUS_HOME' bash '$DAEDALUS_HOME/core/vault-pending-hook.sh'"; [ "$status" -eq 0 ]
  [ "$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)" = "$n0" ]
}

@test "the holder's full commit leaves out a still-open window's log and says so; once that window has closed, the next commit carries it and names whose it was" {
  own_log 02 sB 2026-10-19 7
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "first"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"left out, still being written: the session log of window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME/vault" status --porcelain -uall | grep -q '2026-10-19-007.md'
  run closes sB; [ "$status" -eq 3 ]
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "second"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"carried the session log of window 02 (2026-10-19-007)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(git -C "$DAEDALUS_HOME/vault" status --porcelain)" ]
  [ -z "$(ls -A "$DAEDALUS_HOME/state/vault-pending" 2>/dev/null)" ]
}

@test "the other order: the holder has closed and its session ended; the window that closes next takes the pen and commits its own log with everything else" {
  own_log 02 sB 2026-10-19 7
  rm -f "$BATS_TEST_TMPDIR"/sessions/*.json                               # both sessions gone from the registry ...
  pb="$(live_pid)"; registry_entry "$pb" sB                               # ... window 02 is back, in a terminal
  printf '{"lease":"02","session_id":"sB","worktree":"worktrees/02","pid":%s,"proc_started":%s,"logs":{"2026-10-19":7}}' "$pb" "$(ps_ms "$pb")" > "$DAEDALUS_HOME/state/leases/02.json"
  run closes sB; [ "$status" -eq 0 ] || { echo "$status $output"; return 1; }
  git -C "$DAEDALUS_HOME/vault" show --name-only --format= HEAD | grep -q 'sessions/2026/10/2026-10-19-007.md'
  [ -z "$(git -C "$DAEDALUS_HOME/vault" status --porcelain)" ]
}

@test "a vault tracked by the home repository: the pending commit and the still-open hold work on vault/ paths" {
  rm -rf "$DAEDALUS_HOME/vault/.git"
  sed -i '' '/^vault\/$/d' "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "vault absorbed"
  own_log 02 sB 2026-10-19 7
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "hold"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"left out, still being written: the session log of window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run closes sB; [ "$status" -eq 3 ]
  run stop_hook sA; [ "$status" -eq 0 ]
  [ "$(git -C "$DAEDALUS_HOME" show --name-only --format= HEAD)" = "vault/sessions/2026/10/2026-10-19-007.md" ]
}

@test "the tracked settings.json runs vault-pending-hook.sh on Stop and on SessionEnd, each with a timeout; with nothing pending it returns at once and prints nothing" {
  python3 - "$BATS_TEST_DIRNAME/../../.claude/settings.json" <<'PY'
import json, sys
h = json.load(open(sys.argv[1]))["hooks"]
cmd = 'bash "$CLAUDE_PROJECT_DIR"/core/vault-pending-hook.sh'
for ev in ("Stop", "SessionEnd"):
    hs = [x for g in h[ev] for x in g["hooks"] if x["command"] == cmd]
    assert len(hs) == 1 and isinstance(hs[0].get("timeout"), int) and hs[0]["timeout"] <= 10, (ev, h[ev])
PY
  t0="$(python3 -c 'import time; print(time.time())')"
  run stop_hook sA; [ "$status" -eq 0 ]; [ -z "$output" ]
  python3 -c "import time,sys; sys.exit(0 if time.time() - $t0 < 1.0 else 1)"
}

@test "a window that goes on after its close writes to its log again: the marker no longer counts, so the holder neither commits nor carries it until that window closes again (review M1)" {
  own_log 02 sB 2026-10-19 7
  run closes sB; [ "$status" -eq 3 ]
  sleep 1; printf '## Continued\n' >> "$DAEDALUS_HOME/vault/sessions/2026/10/2026-10-19-007.md"
  n0="$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)"
  run stop_hook sA; [ "$status" -eq 0 ]
  [ "$(git -C "$DAEDALUS_HOME/vault" rev-list --count HEAD)" = "$n0" ]
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "holder"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"left out, still being written: the session log of window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  run closes sB; [ "$status" -eq 3 ]
  run stop_hook sA; [ "$status" -eq 0 ]
  git -C "$DAEDALUS_HOME/vault" show HEAD:sessions/2026/10/2026-10-19-007.md | grep -q 'Continued'
}

@test "the plain sentence is said only when another live session holds the pen; with the holder ended the log is still marked, nothing false is said; a visitor marks nothing (review M2)" {
  own_log 02 sB 2026-10-19 7
  printf '{"session_id":"sGone","history":[]}' > "$DAEDALUS_HOME/state/leases/prime.json"   # a holder in no registry
  run env DAEDALUS_SESSION_ID=sB python3 "$DAEDALUS_HOME/core/leaselib.py" mark-log-pending; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ -f "$DAEDALUS_HOME/state/vault-pending/2026-10-19-007.json" ]
  rm -rf "$DAEDALUS_HOME/state/vault-pending"
  run env DIRECT_CALL_ID=x DAEDALUS_SESSION_ID=sB python3 "$DAEDALUS_HOME/core/leaselib.py" mark-log-pending; [ "$status" -eq 0 ]; [ -z "$output" ]
  [ ! -e "$DAEDALUS_HOME/state/vault-pending" ]
}
