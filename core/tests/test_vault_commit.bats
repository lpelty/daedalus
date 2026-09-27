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
