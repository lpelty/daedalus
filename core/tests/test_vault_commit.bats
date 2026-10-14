#!/usr/bin/env bats
# Pins core/vault-commit.sh: prime-only, index.lock retry, per-file claim staging (spec §4.7).
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

@test "non-prime is refused naming the prime's window number, never a peer name; an operator shell may commit" {
  doc proposals/PROP-1.md PROPOSED 02
  run env DAEDALUS_SESSION_ID=sB bash "$VC"; [ "$status" -ne 0 ]
  case "$output" in *"Only the prime window commits the vault"*"window 01"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *daedalus-0*) echo "$output"; return 1 ;; *) : ;; esac
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID bash '$VC'"; [ "$status" -eq 0 ]
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
  case "$output" in *"vault/ is ignored by $DAEDALUS_HOME/.gitignore"*"remove that line"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"git add failed"*) echo "the generic sentence, not the cause: $output"; return 1 ;; *) : ;; esac
  sed -i '' '/^vault\/$/d' "$DAEDALUS_HOME/.gitignore"; git -C "$DAEDALUS_HOME" add .gitignore
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "ignored"; [ "$status" -ne 0 ]
  case "$output" in *"staged changes outside vault/ (.gitignore)"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "un-ignore the vault" -- .gitignore
  printf '# é\n' > "$DAEDALUS_HOME/vault/proposals/café.md"; git -C "$DAEDALUS_HOME" add -- "vault/proposals/café.md"
  run env DAEDALUS_SESSION_ID=sA bash "$VC" -m "accents"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$DAEDALUS_HOME" -c core.quotepath=false show --name-only --format= HEAD | sort | tr '\n' ' ')" = "vault/proposals/café.md vault/proposals/note.md " ]
}
