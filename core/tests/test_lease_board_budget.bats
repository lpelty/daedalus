#!/usr/bin/env bats
# Pins v0.7.5 (PROP-025): the lease board stays drawn when git is slow — the unpromoted-work cache, a reclaimed window
# that costs nothing, and a partial board on a deadline (spec 2026-10-16-lease-board-budget-design).
# Wall-clock assertions throughout: the tests of this file run one at a time under the parallel full suite.
BATS_NO_PARALLELIZE_WITHIN_FILE=true
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }; export GIT_LOG="$BATS_TEST_TMPDIR/git.log"; }
teardown() { teardown_live; }
board() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"hello there"}' "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py"; }
ctx() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
bind_live() {  # bind_live <NN> <sid> — claim with a live registry pid
  local pid; pid="$(live_pid)"; registry_entry "$pid" "$2" interactive cli "daedalus-$1"
  env CLAUDE_CODE_SESSION_ID="$2" bash "$DAEDALUS_HOME/core/lease.sh" claim "$1" >/dev/null
}
now() { python3 -c 'import time; print(time.time())'; }
under() {  # under <t0> <t1> <secs> <what>
  python3 -c 'import sys; d=float(sys.argv[2])-float(sys.argv[1]); print("%s took %.2fs" % (sys.argv[4], d), file=sys.stderr); assert d < float(sys.argv[3]), "%s slow: %.2fs" % (sys.argv[4], d)' "$@"
}
# timed_board <sid> — one prompt through PATH (as set by the caller); $output, $status, and the wall time checked < 4.5 s
timed_board() {
  local t0 t1; t0="$(now)"; run board "$1"; t1="$(now)"
  [ "$status" -eq 0 ] || { echo "exit $status: $output"; return 1; }
  under "$t0" "$t1" 4.5 "prompt" || { ctx; return 1; }
}
# git_summary — the subcommands in $GIT_LOG, counted ("for-each-ref×4 log×2 …")
git_summary() { cut -f2 "$GIT_LOG" | awk '{k=$1; if ($1=="for-each-ref" && $2 ~ /^--merged/) k="for-each-ref--merged"; if ($1=="log" && $2=="-1") k="log-1"; c[k]++} END {for (k in c) printf "%s×%d ", k, c[k]}'; }
# four_repos <NN>... — outer + sub, sub2, sub3; window 01 live (sA); the given windows created, then swept with work
four_repos() {
  add_nested sub2; add_nested sub3
  local n=$(( $# + 1 )) i
  for i in $(seq 1 "$n"); do LS create >/dev/null; done
  bind_live 01 sA
  swept_with_work "$@"
}

@test "PROP-025: 3 swept windows x 4 repos, every slow-listed git call sleeping 0.15 s — every prompt draws a board (never 'could not be rendered'), exit 0, within 4.5 s; the steady state is one tip listing per repo" {
  four_repos 02 03 04
  export PATH="$(count_git):$PATH" FAKE_GIT_SLEEP_ON="merge-base log for-each-ref" FAKE_GIT_SLEEP=0.15
  for p in 1 2 3 4 5 6 7 8; do        # five drawn prompts are the report's case; the rest reach the steady state
    : > "$GIT_LOG"
    timed_board sA
    c="$(ctx)"
    case "$c" in *"could not be rendered"*) echo "prompt $p: $c"; return 1 ;; esac
    case "$c" in "Lease board ("*) : ;; *) echo "prompt $p: $c"; return 1 ;; esac
    printf '# prompt %s git calls: %s\n' "$p" "$(git_summary)" >&3
  done
  # steady state: one tip listing per repo, no merge-base and no log on the check path, every window drawn
  [ "$(grep -c $'\tfor-each-ref' "$GIT_LOG")" -eq 4 ] || { cat "$GIT_LOG"; return 1; }
  ! grep -q $'\tmerge-base --is-ancestor' "$GIT_LOG"
  ! grep -q $'\tlog --format=%H' "$GIT_LOG"
  for nn in 02 03 04; do
    case "$c" in *"- $nn — swept, 4 unpromoted commits waiting ("*) : ;; *) echo "$c"; return 1 ;; esac
  done
}

LL() { python3 "$DAEDALUS_HOME/core/leaselib.py" "$@"; }
CACHE() { printf '%s' "$DAEDALUS_HOME/state/leases/unpromoted.cache"; }
# cache_check <python-expression> — true over the parsed cache file as `d`
cache_check() { python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
if not eval(sys.argv[2]): print("FAILED: %s\n%s" % (sys.argv[2], json.dumps(d, indent=1))); sys.exit(1)' "$(CACHE)" "$1"; }
checks() { grep -cE $'\t(log --format=%H|for-each-ref --merged|merge-base --is-ancestor)' "$GIT_LOG" || true; }   # check-path git calls in $GIT_LOG
listings() { grep -c $'\tfor-each-ref --format' "$GIT_LOG" || true; }
set_lease() {  # set_lease <NN> <python dict literal>
  LL _test-write "$1" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(eval(sys.argv[2])); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$1.json" "$2")"
}
swept_lines() { ctx | grep -E '^- [0-9]{2} — swept|^- target/' || true; }
UNCHECKED_LINE() { printf -- "- %s — swept; not checked for unpromoted work this time — the next prompt finishes the check, or run \`core/lease.sh list\` to check now" "$1"; }

# --- Task 2: the alarm is no longer a git failure; the lock wait is bounded and says so -----------------------------

@test "a listing slow enough to cross the deadline never makes a swept window's work vanish: its line is its waiting line, an 'at least' line or the 'not checked' line, and the repo not listed is named" {
  LS create >/dev/null; LS create >/dev/null; bind_live 01 sA; swept_with_work 02
  export PATH="$(count_git):$PATH" FAKE_GIT_SLEEP_ON="rev-parse for-each-ref" FAKE_GIT_SLEEP=1.3
  timed_board sA; c="$(ctx)"
  case "$c" in *"- 02 — swept, "*"waiting ("*|*"$(UNCHECKED_LINE 02)"*) : ;; *) echo "02's work vanished: $c"; return 1 ;; esac
  case "$c" in *"- target/thing/sub's lease branches were not listed this time (cut off); run \`core/lease.sh list\` to check them"*) : ;; *) echo "$c"; return 1 ;; esac
  case "$c" in *"could not be rendered"*) echo "$c"; return 1 ;; esac
}

@test "the exclusive lease lock held past the deadline: the prompt draws the busy sentence within 3.3 s (it was silent), exit 0" {
  LS create >/dev/null; bind_live 01 sA
  python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o644); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(8)' "$DAEDALUS_HOME/state/leases/.lock" 3>&- </dev/null >/dev/null 2>&1 &
  holder=$!; printf '%s\n' "$holder" >> "$BATS_TEST_TMPDIR/live-pids"
  sleep 0.5
  t0="$(now)"; run board sA; t1="$(now)"; kill "$holder" 2>/dev/null || true
  [ "$status" -eq 0 ]; under "$t0" "$t1" 3.3 "busy prompt"
  [ "$(ctx)" = "the lease lock stayed busy (a window is being made or swept); the board draws at your next prompt" ] || { ctx; return 1; }
}

# --- Task 3: tips at SHAs, waiting_work_at ---------------------------------------------------------------------------

@test "waiting_work_at at SHAs: contained, equal, one ahead, ahead and behind give [], [], [s], [s]; waiting_work keeps its sentences" {
  T="$DAEDALUS_HOME/target/thing"; tr="$(git -C "$T" rev-parse refs/remotes/origin/main)"
  git -C "$T" branch side "$tr"; printf 's\n' > "$T/s.txt"; git -C "$T" checkout -q side; git -C "$T" add s.txt
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m "side one"; ahead="$(git -C "$T" rev-parse HEAD)"; git -C "$T" checkout -q main
  trunk_moves
  tr2="$(git -C "$T" rev-parse refs/remotes/origin/main)"
  run LL _test-waiting at thing "$tr2" "$tr"; [ "$output" = "[]" ] || { echo "contained: $output"; return 1; }
  run LL _test-waiting at thing "$tr2" "$tr2"; [ "$output" = "[]" ] || { echo "equal: $output"; return 1; }
  run LL _test-waiting at thing "$tr" "$ahead"; [ "$output" = '["side one"]' ] || { echo "ahead: $output"; return 1; }
  run LL _test-waiting at thing "$tr2" "$ahead"; [ "$output" = '["side one"]' ] || { echo "ahead and behind: $output"; return 1; }
}

@test "_resolve_tips: every lease tip and the trunk tip, outer and nested, in one listing; a nested repo with no origin/HEAD is skipped; the outer one with no origin/<trunk> names require_trunk_ref's fix" {
  LS create >/dev/null; LS create >/dev/null
  T="$DAEDALUS_HOME/target/thing"
  run --separate-stderr LL _test-waiting tips thing main; [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin); t=sys.argv[1]
import subprocess
rp=lambda r: subprocess.run(["git","-C",t,"rev-parse",r],capture_output=True,text=True).stdout.strip()
assert d["trunk"]=="main" and d["trunk_sha"]==rp("refs/remotes/origin/main"), d
assert d["tips"]=={"01":rp("refs/heads/lease/01"),"02":rp("refs/heads/lease/02")}, d
assert isinstance(d["view"], str) and d["view"], d' "$T"
  run --separate-stderr LL _test-waiting tips thing/sub; [ "$status" -eq 0 ]
  printf '%s' "$output" | python3 -c 'import json,sys
d=json.load(sys.stdin); assert d["trunk"]=="main" and len(d["trunk_sha"])==40 and sorted(d["tips"])==["01","02"], d'
  git -C "$T/sub" symbolic-ref -d refs/remotes/origin/HEAD
  run --separate-stderr LL _test-waiting tips thing/sub; [ "$status" -eq 0 ]; [ "$output" = "null" ]
  run --separate-stderr LL _test-waiting tips thing nosuch; [ "$status" -eq 1 ]
  [ "$stderr" = "daedalus: target/thing has no origin/nosuch — check config target.branch, or run git -C target/thing fetch origin" ] || { echo "$stderr"; return 1; }
}

# --- Task 4: the cache ----------------------------------------------------------------------------------------------

@test "cache (a): the second prompt on an unchanged fixture runs no check at all — one tip listing per repo, no log, no merge-base, no --merged" {
  four_repos 02 03 04; export PATH="$(count_git):$PATH"
  run board sA; [ "$status" -eq 0 ]
  : > "$GIT_LOG"; run board sA; [ "$status" -eq 0 ]
  [ "$(checks)" -eq 0 ] || { cat "$GIT_LOG"; return 1; }
  [ "$(listings)" -eq 4 ] || { cat "$GIT_LOG"; return 1; }
  for r in thing thing/sub thing/sub2 thing/sub3; do [ "$(grep -c "/target/$r"$'\tfor-each-ref --format' "$GIT_LOG")" -eq 1 ]; done
  case "$(ctx)" in *"- 04 — swept, 4 unpromoted commits waiting ("*) : ;; *) ctx; return 1 ;; esac
}

@test "cache (b)(c): a new commit on lease/03 in one repo recomputes that pair only; the trunk advanced in one repo is one --merged there, and the promoted work leaves the line" {
  four_repos 02 03 04; export PATH="$(count_git):$PATH"
  run board sA; run board sA
  W="$DAEDALUS_HOME/worktrees/03/thing/sub2"; printf 'more\n' >> "$W/w.txt"
  git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "more 03 in sub2"
  : > "$GIT_LOG"; run board sA
  [ "$(checks)" -eq 1 ] && grep -q $'/target/thing/sub2\tlog --format=%H' "$GIT_LOG" || { cat "$GIT_LOG"; return 1; }
  case "$(ctx)" in *"- 03 — swept, 5 unpromoted commits waiting ("*"more 03 in sub2"*) : ;; *) ctx; return 1 ;; esac
  # 02's work in sub lands on sub's trunk (from another clone, the way it happens), and target/thing/sub fetches it
  E="$BATS_TEST_TMPDIR/promoter"; git clone -q "$BATS_TEST_TMPDIR/sub-origin.git" "$E"
  git -C "$E" fetch -q "$DAEDALUS_HOME/target/thing/sub" lease/02; git -C "$E" push -q origin FETCH_HEAD:main
  git -C "$DAEDALUS_HOME/target/thing/sub" fetch -q origin
  : > "$GIT_LOG"; run board sA
  [ "$(grep -c $'\tfor-each-ref --merged' "$GIT_LOG")" -eq 1 ] && grep -q $'/target/thing/sub\tfor-each-ref --merged' "$GIT_LOG" || { cat "$GIT_LOG"; return 1; }
  ! grep -qE $'/target/thing(/sub2|/sub3)?\tlog --format=%H' "$GIT_LOG" || { cat "$GIT_LOG"; return 1; }
  c="$(ctx)"
  case "$c" in *"- 02 — swept, 3 unpromoted commits waiting (\"work 02 in thing\", \"work 02 in sub2\", \"work 02 in sub3\")"*) : ;; *) echo "$c"; return 1 ;; esac
}

@test "cache (d): a corrupt cache — '{', '[]', '{\"v\":9}', a binary blob, one entry missing a field — draws the same swept lines as no cache, exit 0, one JSON object on stdout; the file is valid JSON afterwards; a directory at the path draws the same, unwritten" {
  four_repos 02 03
  run --separate-stderr board sA; base="$(swept_lines)"; [ -n "$base" ]
  good="$(cat "$(CACHE)")"
  for bad in '{' '[]' '{"v":9}' 'BLOB' 'MISSING'; do
    case "$bad" in
      BLOB) printf '\377\376\000\001junk' > "$(CACHE)" ;;
      MISSING) printf '%s' "$good" | python3 -c 'import json,sys; d=json.load(sys.stdin); k=sorted(d["entries"])[0]; del d["entries"][k]["tip"]; print(json.dumps(d))' > "$(CACHE)" ;;
      *) printf '%s' "$bad" > "$(CACHE)" ;;
    esac
    run --separate-stderr board sA; [ "$status" -eq 0 ] || { echo "$bad: $output $stderr"; return 1; }
    [ "$(swept_lines)" = "$base" ] || { echo "$bad:"; swept_lines; return 1; }
    cache_check 'd["v"] == 1 and len(d["entries"]) == 8' || { echo "after $bad"; return 1; }
  done
  rm -f "$(CACHE)"; mkdir "$(CACHE)"
  run --separate-stderr board sA; [ "$status" -eq 0 ]; [ "$(swept_lines)" = "$base" ]; [ -d "$(CACHE)" ]
  [ -z "$(ls -A "$(CACHE)")" ]
}

@test "cache (e): pruning — a claimed window's entries go, a deleted branch's entries go, a repo whose listing fails keeps its entries" {
  four_repos 02 03 04
  run board sA; cache_check 'len(d["entries"]) == 12'
  bind_live 02 sB
  run board sA; cache_check 'not any(k.startswith("02 ") for k in d["entries"]) and len(d["entries"]) == 8'
  for r in thing thing/sub thing/sub2 thing/sub3; do git -C "$DAEDALUS_HOME/target/$r" update-ref -d refs/heads/lease/03; done
  run board sA; cache_check 'sorted(d["entries"]) == ["04 thing", "04 thing/sub", "04 thing/sub2", "04 thing/sub3"]'
  export PATH="$(count_git):$PATH" FAKE_GIT_FAIL_ON="for-each-ref" FAKE_GIT_FAIL_IN="/thing/sub2"
  rm -f "$DAEDALUS_HOME/worktrees/04/thing/sub2/.git" 2>/dev/null; git -C "$DAEDALUS_HOME/target/thing/sub2" update-ref -d refs/heads/lease/04
  W="$DAEDALUS_HOME/worktrees/04/thing"; printf 'x\n' >> "$W/w.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "04 again"
  run board sA
  case "$(ctx)" in *"- target/thing/sub2's lease branches were not listed this time (git for-each-ref failed: fatal: Unable to create"*"run \`core/lease.sh list\` to check them"*) : ;; *) ctx; return 1 ;; esac
  cache_check '"04 thing/sub2" in d["entries"]'      # unlisted: kept, although its branch is gone
}

@test "cache (f): two boards started together, 20 rounds — the file parses after every round, and the prompt after is all hits" {
  four_repos 02 03
  for i in $(seq 1 20); do
    [ $((i % 2)) -eq 0 ] && rm -f "$(CACHE)"
    board sA >/dev/null 2>&1 & a=$!; board sA >/dev/null 2>&1 & b=$!; wait "$a" "$b"
    cache_check 'd["v"] == 1' || { echo "round $i"; return 1; }
  done
  run board sA; export PATH="$(count_git):$PATH"; : > "$GIT_LOG"; run board sA
  [ "$(checks)" -eq 0 ] || { cat "$GIT_LOG"; return 1; }
}

@test "cache (g): the history view — a replace ref, info/grafts, or shallow in one repo misses that repo's pairs only; with the replace ref the board agrees with waiting-work; no --no-replace-objects on the check path" {
  four_repos 02 03; export PATH="$(count_git):$PATH"
  run board sA
  T="$DAEDALUS_HOME/target/thing"
  git -C "$T" replace --graft "$(git -C "$T" rev-parse refs/remotes/origin/main)" "$(git -C "$T" rev-parse refs/heads/lease/03)"   # the trunk now descends from 03
  : > "$GIT_LOG"; run board sA
  ! grep -qE $'/target/thing/sub[23]?\t(log --format=%H|for-each-ref --merged)' "$GIT_LOG" || { cat "$GIT_LOG"; return 1; }
  grep -qE $'/target/thing\t(log --format=%H|for-each-ref --merged)' "$GIT_LOG" || { cat "$GIT_LOG"; return 1; }
  [ -z "$(LL waiting-work 03)" ]       # through the replace ref, the trunk contains 03's outer commit
  case "$(ctx)" in *"- 03 — swept, 3 unpromoted commits waiting (\"work 03 in sub\", "*) : ;; *) ctx; return 1 ;; esac
  ! grep -q -- '--no-replace-objects' "$GIT_LOG"
  for f in info/grafts shallow; do
    run board sA
    mkdir -p "$DAEDALUS_HOME/target/thing/sub2/.git/info"; : > "$DAEDALUS_HOME/target/thing/sub2/.git/$f"
    : > "$GIT_LOG"; run board sA
    grep -qE $'/target/thing/sub2\t(log --format=%H|for-each-ref --merged)' "$GIT_LOG" || { echo "$f"; cat "$GIT_LOG"; return 1; }
    ! grep -qE $'/target/thing(/sub|/sub3)?\t(log --format=%H|for-each-ref --merged)' "$GIT_LOG" || { echo "$f"; cat "$GIT_LOG"; return 1; }
    rm -f "$DAEDALUS_HOME/target/thing/sub2/.git/$f"
  done
}

@test "cache (h): written only on change — an all-hits prompt leaves the mtime; a home with no swept window never gets the file; doctor-lines with misses leaves state/leases/ byte-identical" {
  LS create >/dev/null; bind_live 01 sA
  run board sA; run board sA; [ ! -e "$(CACHE)" ]
  LS create >/dev/null; swept_with_work 02
  L="$DAEDALUS_HOME/state/leases"
  before="$(cd "$L" && shasum -a 256 * | sort)"; mt="$(cd "$L" && stat -f '%N %Fm' * | sort)"
  run LL doctor-lines
  case "$output" in *"NOTE     leases: 02 swept with 2 unpromoted commits waiting"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cd "$L" && shasum -a 256 * | sort)" = "$before" ]; [ "$(cd "$L" && stat -f '%N %Fm' * | sort)" = "$mt" ]
  [ ! -e "$(CACHE)" ]
  run board sA; [ -f "$(CACHE)" ]
  touch -t 202001010000 "$(CACHE)"; m="$(stat -f %Fm "$(CACHE)")"
  run board sA; [ "$(stat -f %Fm "$(CACHE)")" = "$m" ]
}

@test "cache (i): a .unpromoted-*.tmp older than 60 s is removed by the next write; a younger one is left" {
  LS create >/dev/null; bind_live 01 sA; LS create >/dev/null; swept_with_work 02
  L="$DAEDALUS_HOME/state/leases"
  : > "$L/.unpromoted-old111.tmp"; touch -t 202001010000 "$L/.unpromoted-old111.tmp"; : > "$L/.unpromoted-new222.tmp"
  run board sA; [ -f "$(CACHE)" ]
  [ ! -e "$L/.unpromoted-old111.tmp" ]; [ -e "$L/.unpromoted-new222.tmp" ]
  [ "$(ls "$L" | grep -c '\.json$')" -eq 1 ]      # the cache and its temps are never *.json
}

# --- Task 4b: a commit with an empty message is unpromoted work -----------------------------------------------------

@test "an empty-message commit on a swept lease/03 is waiting work: create skips 03, waiting-work prints (no subject), the board counts it, and reclaim keeps a stale lease whose only unpromoted commit has no message" {
  for i in 1 2 3; do LS create >/dev/null; done; bind_live 01 sA
  W="$DAEDALUS_HOME/worktrees/03/thing"; printf 'e\n' >> "$W/a.txt"
  git -C "$W" -c user.email=t@x -c user.name=t commit -q -a --allow-empty-message -m ""
  rm -f "$DAEDALUS_HOME/state/leases/03.json" "$DAEDALUS_HOME/state/leases/03.seen" "$DAEDALUS_HOME/state/leases/03.changed"
  run LL waiting-work 03; [ "$output" = "(no subject)" ] || { echo "$output"; return 1; }
  run board sA; case "$(ctx)" in *"- 03 — swept, 1 unpromoted commit waiting (\"(no subject)\")"*) : ;; *) ctx; return 1 ;; esac
  run LS create; [ -f "$DAEDALUS_HOME/state/leases/04.json" ]; [ ! -f "$DAEDALUS_HOME/state/leases/03.json" ]
  # reclaim: window 02 stale (dead recorded pid), clean, its only unpromoted commit message-less
  W="$DAEDALUS_HOME/worktrees/02/thing"; printf 'e\n' >> "$W/a.txt"
  git -C "$W" -c user.email=t@x -c user.name=t commit -q -a --allow-empty-message -m ""
  set_lease 02 'dict(session_id="sB", pid=1, proc_started=1)'
  run LS create; [ -f "$DAEDALUS_HOME/state/leases/02.json" ] || { echo "reclaimed over a message-less commit: $output"; return 1; }
}

# --- Task 5: reclaim seeds the cache --------------------------------------------------------------------------------

@test "a reclaimed window costs the board nothing: create reclaims 02 (held back by a foreign worktree registration), the next prompt checks nothing for it and draws no line; a later commit in its worktree shows" {
  LS create >/dev/null; bind_live 01 sA; LS create >/dev/null
  set_lease 02 'dict(session_id="sB", pid=1, proc_started=1)'
  git -C "$DAEDALUS_HOME/worktrees/02/thing/sub" checkout -q -b elsewhere     # registered to a branch other than lease/02
  run LS create; case "$output" in *"Reclaimed window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/leases/02.json" ]; [ -f "$DAEDALUS_HOME/state/leases/03.json" ]
  cache_check 'sorted(d["entries"]) == ["02 thing", "02 thing/sub"] and all(e["subjects"] == [] for e in d["entries"].values())'
  export PATH="$(count_git):$PATH"; : > "$GIT_LOG"; run board sA
  [ "$(checks)" -eq 0 ] || { cat "$GIT_LOG"; return 1; }
  case "$(ctx)" in *"- 02 "*) ctx; return 1 ;; esac
  W="$DAEDALUS_HOME/worktrees/02/thing"; printf 'later\n' >> "$W/a.txt"; git -C "$W" -c user.email=t@x -c user.name=t commit -q -am "later work"
  run board sA; case "$(ctx)" in *"- 02 — swept, 1 unpromoted commit waiting (\"later work\")"*) : ;; *) ctx; return 1 ;; esac
}
