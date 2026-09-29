# core/tests/fixtures/promote/setup.bash — loaded by test_promote.bats (and later suites that promote).
# Builds on caller_fixture (a Daedalus home that is a git checkout with core/ committed, a target
# thing with a nested repo sub, each with a BARE origin under $BATS_TEST_TMPDIR — the only remotes
# anything here ever pushes to — and the recording fake claude first on PATH), adds promote and
# what it runs, the real capture.py (transcriptlib's parser; caller_fixture installs a stub), and
# two live windows: 01 (session sP) holds the pen, 02 (session sC) is where work waits.
load fixtures/caller/setup.bash
load fixtures/transcripts/setup.bash
load fixtures/tty/setup.bash

promote_fixture() {
  caller_fixture
  local src f; src="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  for f in promote.sh promote.py transcriptlib.py distcheck.py capture.py gates.sh manifest-append.py refute.sh \
           refute-pitfalls.py pitfall-inject.py review-inputs.py lease-board.py prepush.py session-start.py; do
    [ -f "$src/$f" ] && cp "$src/$f" "$DAEDALUS_HOME/core/"
  done
  git -C "$DAEDALUS_HOME" add -A
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m promote
  # The merge's identity is the target's git identity (Decision 24); a test sets its own.
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
  # Who runs promote is read from these (spec §7.1 step 1); every test sets exactly the ones it means.
  unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_SESSION_ID DAEDALUS_LEASE DAEDALUS_TARGET_OVERRIDE \
        DAEDALUS_PROMOTE_ID CLAUDE_PROJECT_DIR PROMOTE_TEST_BEFORE_PUSH
  export DAEDALUS_MANAGED_CLAUDE_MD_PATHS="$BATS_TEST_TMPDIR/no-managed-CLAUDE.md"
  export FAKE_ANSWER="F1 — nothing found.
VERDICT: STANDS"
  PROMOTE="$DAEDALUS_HOME/core/promote.sh"; LSH="$DAEDALUS_HOME/core/lease.sh"
  export PROMOTE LSH
  bash "$LSH" create >/dev/null; bash "$LSH" create >/dev/null
  PP="$(live_pid)"; registry_entry "$PP" sP interactive cli daedalus-01; CLAUDE_CODE_SESSION_ID=sP bash "$LSH" claim 01 >/dev/null
  PC="$(live_pid)"; registry_entry "$PC" sC interactive cli daedalus-02; CLAUDE_CODE_SESSION_ID=sC bash "$LSH" claim 02 >/dev/null
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sP","bound_at":"2026-01-01T00:00:00","history":[]}'
  W2="$DAEDALUS_HOME/worktrees/02/thing"
  # The prime's transcript, in the home's own Claude Code project directory — a directory the guard
  # denies; transcriptlib refuses a transcript anywhere else (plan 4 Decision 36).
  TXP="$(tx_path sP)"; : > "$TXP"
  # The prime's SessionStart marker, as session-start.py writes it: its transcript and trunk base.
  python3 - "$DAEDALUS_HOME/state/session-sP.json" "$TXP" "$(git -C "$T" rev-parse origin/main)" <<'PY'
import json, sys, time
json.dump({"session_id": "sP", "started": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(time.time() - 3600)),
           "started_epoch": time.time() - 3600,
           "target_branch": "main", "target_base": sys.argv[3], "target_base_error": "", "transcript_path": sys.argv[2],
           "lease": "01"}, open(sys.argv[1], "w"), indent=2)
PY
  export W2 TXP
}

# work_on_02 — two commits on window 02's branch in the outer repo.
work_on_02() {
  printf 'w1\n' > "$W2/c.txt"; git -C "$W2" add -A; git -C "$W2" commit -q -m "capture: read error before error_message"
  printf 'w2\n' >> "$W2/c.txt"; git -C "$W2" commit -q -am "test: error field fallback"
}
as_prime() { env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sP "$@"; }
# prepared — the newest prepared.json; pj <path> — a field of it (dotted path), printed.
prepared() { ls -t "$DAEDALUS_HOME"/state/promote/*/prepared.json 2>/dev/null | head -1; }
pj() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k] if isinstance(d, dict) else d[int(k)]
print(d)' "$(prepared)" "$1"; }
# refused <text> [code] — the last run exited <code> (default 2), said <text>, and its last line ends
# with the §11.3 suffix: the one contract every refusal carries.
refused() {
  [ "$status" -eq "${2:-2}" ] || { echo "exit $status, wanted ${2:-2}: $output"; return 1; }
  case "$output" in *"$1"*) : ;; *) echo "wanted: $1"; echo "got: $output"; return 1 ;; esac
  case "$(printf '%s\n' "$output" | sed '/^$/d' | tail -1)" in
    *"Nothing was pushed."|*"Nothing changed on origin.") : ;;
    *) echo "last line lacks the suffix: $output"; return 1 ;;
  esac
}
origin_main() { git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse main; }

# shown_then_said <words> [shown text] — the exchange a real confirm follows, after the newest
# prepare: prepare's tool result, the assistant turn that showed the block (by default its first
# line; a skip over a REFUTED review shows the reviewer line), then the operator's words.
# Sets SHOWN and SAID to the two entries' uuids (call it directly, never in "$( )": a
# subshell would lose them).
shown_then_said() {
  local P B="Ready to promote window 02's work onto main."; P="$(pj prepared_ts)"
  # (the default lives in B: an apostrophe inside "${2:-…}" opens a quote bash never closes)
  tx "$TXP" tool-result "prepared" "$(plus "$P" 1)" >/dev/null
  SHOWN="$(tx "$TXP" assistant "${2:-$B}" "$(plus "$P" 2)")"
  SAID="$(tx "$TXP" operator "$1" "$(plus "$P" 3)")"
}
