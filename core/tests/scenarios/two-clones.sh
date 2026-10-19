#!/usr/bin/env bash
# The two-window scenario (spec §11.2): a scratch deployment built from fixtures — its own small target, a local
# bare repository standing in as origin, its own knowledge base; the invoking deployment's config, target and
# vault are never read — and the steps an operator takes to see windows number themselves, the board, the
# stop-once warning and a message, a rebase, the guard's and git's refusals, a promote with a yes, the
# reviewer's refusal and its override, a background clone, a pivot, sweep and release, and the pen handed over.
#
#   bash core/tests/scenarios/two-clones.sh               interactive (~10 minutes): at each step it prints which
#                                                         terminal, what to say and what to expect, waits for
#                                                         Enter, then checks the deployment's state
#   bash core/tests/scenarios/two-clones.sh --rehearse    the suite's run: plays every window itself through the
#                                                         hooks and commands a window runs, with a stand-in claude
#   --keep                 leave the scratch directory for inspection
#   --with-memory <bank>   interactive only: run step 9 (recall) against that memory bank
set -uo pipefail

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FIX="$SRC/core/tests/fixtures"
mode=interactive; keep=0; bank=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rehearse) mode=rehearse ;;
    --keep) keep=1 ;;
    --with-memory) bank="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1"; usage; exit 2 ;;
  esac
  shift
done
if [ "$mode" = interactive ] && [ ! -t 0 ]; then
  printf 'The scenario needs a terminal: run it yourself in one, or use --rehearse to play every window automatically.\n'
  exit 2
fi
if [ "$mode" = rehearse ] && [ -n "$bank" ]; then
  printf -- '--with-memory is for the interactive run only.\n'; exit 2
fi

S="$(mktemp -d "${TMPDIR:-/tmp}/daedalus-scenario.XXXXXX")" || exit 2
S="$(cd "$S" && pwd -P)"
H="$S/home"
# The deployment this is run from is never read or written: the script reads only the product's tracked files
# (SRC, with git ls-files) and exports DAEDALUS_HOME to the scratch home. The one way the scratch could land in
# that deployment is a TMPDIR pointing into it — refused here, and the empty directory mktemp made is removed.
INVOKED=""; [ -z "${DAEDALUS_HOME:-}" ] || INVOKED="$(cd "$DAEDALUS_HOME" 2>/dev/null && pwd -P)"
if [ -n "$INVOKED" ]; then
  case "$S/" in
    "$INVOKED"/*) rm -rf "$S"
      printf 'The scratch directory %s is inside the deployment this was run from (%s); set TMPDIR elsewhere and run it again.\n' "$S" "$INVOKED"
      exit 2 ;;
  esac
fi
checks=0
cleanup() {
  [ -f "$S/pids" ] && while read -r p; do kill "$p" 2>/dev/null; done < "$S/pids"
  if [ "$keep" -eq 1 ]; then printf 'Scratch kept at %s\n' "$S"; else rm -rf "$S"; fi
}
trap cleanup EXIT

say()   { printf '\n%s\n' "$*"; }
ok()    { checks=$((checks + 1)); printf '  check: %s — ok\n' "$1"; }
fail()  { printf '  CHECK FAILED: %s\n' "$*"; exit 1; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }
step()  {   # step <n> <terminal> <what the operator says> <what to expect>
  say "Step $1. ${2}: say «$3»"
  printf '  expect: %s\n' "$4"
  if [ "$mode" = interactive ]; then printf '  (press Enter when you have seen it) '; read -r _ </dev/tty; fi
}
note()  { say "$*"; if [ "$mode" = interactive ]; then printf '  (press Enter to go on) '; read -r _ </dev/tty; fi; }
has()   { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# Text a window writes in its own words (a note) is checked loosely: it contains the expected words, in any case,
# with whatever punctuation or wording the window kept around them. Exact matches are for values the commands fix.
loosely() { has "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; }
lj()    { python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for k in sys.argv[2].split("."): d = d.get(k) if isinstance(d, dict) else None
print("" if d is None else d)' "$H/state/leases/$1.json" "$2"; }
T() { printf '%s/target/thing' "$H"; }
W() { printf '%s/worktrees/%s/thing' "$H" "$1"; }

# --- the scratch deployment --------------------------------------------------------------------------------
export GIT_AUTHOR_NAME=scenario GIT_AUTHOR_EMAIL=scenario@example.invalid GIT_COMMITTER_NAME=scenario GIT_COMMITTER_EMAIL=scenario@example.invalid
unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_SESSION_ID DAEDALUS_LEASE DIRECT_CALL_ID DAEDALUS_CONFIG \
      DAEDALUS_TARGET_OVERRIDE DAEDALUS_PROMOTE_ID TENANT_HOME TENANT_BANK TRANSCRIPT_DIR HINDSIGHT_API_URL \
      HINDSIGHT_API_TENANT_API_KEY
mkdir -p "$H"
(cd "$SRC" && git ls-files --cached --others --exclude-standard -z) | python3 -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for rel in sys.stdin.read().split("\0"):
    if rel and os.path.isfile(os.path.join(src, rel)):
        os.makedirs(os.path.dirname(os.path.join(dst, rel)) or dst, exist_ok=True)
        shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))' "$SRC" "$H"
git init -q -b main "$H" && git -C "$H" add -A && git -C "$H" commit -q -m "the product, for the scenario" || exit 2
seed="$S/seed"; mkdir -p "$seed/hooks" "$seed/tests"
cat > "$seed/hooks/capture.py" <<'EOF'
"""A stand-in for the target's capture hook: the scenario's windows change it."""


def save_state(offsets):
    return dict(offsets)
EOF
cat > "$seed/tests/test_capture.py" <<'EOF'
import sys
sys.path.insert(0, "hooks")
from capture import save_state
assert save_state({"a": 1}) == {"a": 1}
print("ok")
EOF
printf '# Scenario target\n' > "$seed/README.md"
printf '__pycache__/\n' > "$seed/.gitignore"   # as any Python target has: the gate's bytecode must not dirty the tree
git init -q -b main "$seed" && git -C "$seed" add -A && git -C "$seed" commit -q -m "scenario target" || exit 2
git clone -q --bare "$seed" "$S/thing.git"
kb="$S/kb"; mkdir -p "$kb"
for d in infrastructure specs plans proposals pitfalls exchange evidence sessions; do mkdir -p "$kb/$d"; : > "$kb/$d/.keep"; done
cp "$SRC/core/templates/hot.md" "$kb/hot.md"
git init -q -b main "$kb" && git -C "$kb" add -A && git -C "$kb" commit -q -m "scenario knowledge base" || exit 2
git clone -q --bare "$kb" "$S/kb.git"
cat > "$H/config.yaml" <<EOF
target:
  repo: $S/thing.git
  branch: main
vault:
  repo: $S/kb.git
gates:
  - python3 tests/test_capture.py
proposals:
  budget: 5
promote:
  confirm: transcribed
EOF
export DAEDALUS_HOME="$H"
if [ "$mode" = rehearse ]; then
  export CLAUDE_CONFIG_DIR="$S/claude-config" FAKE_CLAUDE_DIR="$S/fake-claude"
  export DAEDALUS_MANAGED_CLAUDE_MD_PATHS="$S/no-managed-CLAUDE.md"
  export PATH="$FIX/caller/bin:$PATH"
  export FAKE_ANSWER="F1 — nothing found.
VERDICT: STANDS"
  mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$FAKE_CLAUDE_DIR"
fi
bash "$H/core/setup.sh" >"$S/setup.log" 2>&1 || { cat "$S/setup.log"; printf 'Setup of the scratch deployment failed (above).\n'; exit 1; }
say "Scratch deployment at $H. Open your first terminal there and run \`claude\`."

# --- rehearsal: playing a window ---------------------------------------------------------------------------
TXD="$S/claude-config/projects/$(printf '%s' "$H" | sed 's/[^A-Za-z0-9]/-/g')"
txp()  { mkdir -p "$TXD"; printf '%s/%s.jsonl' "$TXD" "$1"; }
tx()   { python3 "$FIX/transcripts/build.py" "$@"; }
now()  { python3 -c 'import time; print("%.3f" % time.time())'; }
as()   { local sid="$1"; shift; (cd "$H" && env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID="$sid" "$@"); }
ctx()  { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"])
except Exception: pass' "$1"; }
open_window() {   # open_window <session> [kind] [entrypoint] [DAEDALUS_LEASE] — a terminal (or a background clone) starts
  local sid="$1" kind="${2:-interactive}" ep="${3:-cli}" lease="${4:-}" pid started
  sleep 3000 </dev/null >/dev/null 2>&1 3>&- & pid=$!
  printf '%s\n' "$pid" >> "$S/pids"; printf '%s\n' "$pid" > "$S/pid-$sid"
  started="$(python3 -c 'import subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True).stdout.strip()
print(int(time.mktime(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000) if out else 0)' "$pid")"
  printf '{"pid":%s,"sessionId":"%s","startedAt":%s,"kind":"%s","entrypoint":"%s","name":"daedalus-xx","nameSource":"derived"}\n' \
    "$pid" "$sid" "$started" "$kind" "$ep" > "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
  : > "$(txp "$sid")"
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s"}' "$sid" "$(txp "$sid")" \
    | (cd "$H" && if [ -n "$lease" ]; then DAEDALUS_LEASE="$lease" python3 core/session-start.py; else python3 core/session-start.py; fi) > "$S/start-$sid.json"
  ctx "$S/start-$sid.json"
}
close_window() {  # close_window <session> — the terminal's close button: the process is gone, no SessionEnd
  local pid; pid="$(cat "$S/pid-$1")"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -f "$CLAUDE_CONFIG_DIR/sessions/$pid.json"
}
said() {          # said <session> <words> — the operator types into that window. build.py writes the turn and
                  # records the prompt as the UserPromptSubmit hook does, before the turn (Claude Code's order); the
                  # board hook then runs without transcript_path, so the prompt is not recorded twice
  tx "$(txp "$1")" operator "$2" >/dev/null
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt":"%s"}' "$1" "$2" \
    | (cd "$H" && python3 core/lease-board.py) > "$S/board-$1.json"
}
replied() { tx "$(txp "$1")" assistant "$2" >/dev/null; }     # the window's reply, repeating what it shows
ran()     { tx "$(txp "$1")" tool-result "$2" >/dev/null; }    # the window's Bash call returned
board()   { as "$1" bash core/lease.sh status; }
edit_attempt() {  # edit_attempt <session> <absolute path> — the Edit tool's PreToolUse, as the boundary hook sees it
  printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"a","new_string":"b"}}' "$1" "$2" \
    | (cd "$H" && python3 core/boundary-hook.py)
}
bash_attempt() {  # bash_attempt <session> <cwd> <command> — the Bash tool's PreToolUse, as the guard sees it
  printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2" "$3" \
    | (cd "$H" && python3 core/guard-bash.py)
}
newest_prepared() { ls -t "$H"/state/promote/*/prepared.json 2>/dev/null | head -1; }
pj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(d)' "$(newest_prepared)" "$1"; }
promote_with_yes() {   # promote_with_yes <window> <first line the prime repeats> — prepare, show, the yes, confirm
  local out
  out="$(as sP bash core/promote.sh "$1" 2>&1)" || { printf '%s\n' "$out"; return 1; }
  ran sP "$out"; replied sP "$2"; said sP "yes, ship it"
  as sP bash core/promote.sh "$1" --confirm --operator-said "yes, ship it"
}
origin_main() { git -C "$S/thing.git" rev-parse main; }

# --- the steps ---------------------------------------------------------------------------------------------
# Session names in the rehearsal: sP = terminal 1 (the prime), sC = terminal 2, sE = terminal 3, sK = the
# background clone, sE2 = terminal 3 reopened, sN = terminal 2 reopened at the end.

step 1 "Terminal 1 (run \`claude\` in the scratch home)" "who is working on what?" \
  "at start: \"You are window 01 and you hold the pen (prime)\" (and, once, that the window may be renamed — ignore it); then the board verbatim: one line, 01 (you) — prime — 0 changed"
if [ "$mode" = rehearse ]; then
  c="$(open_window sP)"; has "$c" "You are window 01 and you hold the pen" || fail "window 01 was not told it holds the pen: $c"
  said sP "who is working on what?"; b="$(board sP)"; has "$b" "- 01 (you) — prime" || fail "board: $b"
fi
check "window 01 exists and holds the pen" test "$(lj 01 session_id)" = "$(lj prime session_id)" -a -n "$(lj 01 session_id)"

step 2 "Terminal 2 (run \`claude\`); then terminal 1" "note for this window: probe of hooks/capture.py. — then, in terminal 1: who is working on what?" \
  "terminal 2 is told \"You are window 02\"; terminal 1's board shows window 02 with that note"
if [ "$mode" = rehearse ]; then
  c="$(open_window sC)"; has "$c" "You are window 02" || fail "terminal 2: $c"
  said sC "note for this window: probe of hooks/capture.py."; as sC bash core/lease.sh note 02 "probe of hooks/capture.py." >/dev/null   # the operator's words as said, period and all (CLAUDE.md: "<their words>")
  said sP "who is working on what?"; has "$(board sP)" "note: probe of hooks/capture.py" || fail "no note on the board"
fi
check "window 02 carries the note" loosely "$(lj 02 note)" "probe of hooks/capture.py"
term2_session="$(lj 02 session_id)"   # step 9 flushes this session's transcript

step 3 "Terminal 3 (run \`claude\`)" "call this window electron." \
  "\"You are window 03\" at start; then \"Window 03 is now shown as electron on the board.\""
if [ "$mode" = rehearse ]; then
  c="$(open_window sE)"; has "$c" "You are window 03" || fail "terminal 3: $c"
  said sE "call this window electron."; o="$(as sE bash core/lease.sh alias 03 electron)"
  has "$o" "Window 03 is now shown as electron on the board." || fail "alias: $o"
fi
check "window 03 carries alias electron" test "$(lj 03 alias)" = electron
check "the board lists 03 (electron)" has "$(bash "$H/core/lease.sh" list)" "03 (electron)"

step 4 "Terminal 2, then terminal 3" "change one line in hooks/capture.py, and stop there. — then, in terminal 3: change one line in hooks/capture.py." \
  "window 02's edit lands in its own worktree; window 03's first attempt is stopped — it says window 02 has changed that file and that it has messaged window 02; terminal 2 shows a message from window 03"
if [ "$mode" = rehearse ]; then
  said sC "change one line in hooks/capture.py, and stop there."
  sed -i.bak 's/    return dict(offsets)/    return dict(offsets)  # window 02/' "$(W 02)/hooks/capture.py" && rm -f "$(W 02)/hooks/capture.py.bak"
  said sC "thanks"      # the next prompt recomputes window 02's changed set
  said sE "change one line in hooks/capture.py."
  d="$(edit_attempt sE "$(W 03)/hooks/capture.py")"
  has "$d" '"permissionDecision": "deny"' || fail "window 03's first edit was not stopped: $d"
  has "$d" "window 02" || fail "the stop does not name window 02: $d"
fi
check "window 02's worktree has hooks/capture.py changed" test -n "$(git -C "$(W 02)" status --porcelain hooks/capture.py)"
check "window 03's worktree does not" test -z "$(git -C "$(W 03)" status --porcelain hooks/capture.py)"
check "window 03's boundary file names hooks/capture.py under warned" has "$(python3 -c 'import glob,json,sys
for f in glob.glob(sys.argv[1] + "/state/session-*-boundary.json"):
    try:
        print("\n".join((json.load(open(f)).get("warned") or {}).keys()))
    except Exception:
        pass' "$H")" "/worktrees/03/thing/hooks/capture.py"
check "window 02's changed set names hooks/capture.py" has "$(python3 "$H/core/leaselib.py" changed 02)" "hooks/capture.py"

step 5 "Terminal 2" "commit that change on your branch and run the gates." \
  "a commit on window 02's branch and a gate result, PASS (the reviewer may say STANDS or REFUTED — either is fine here)"
if [ "$mode" = rehearse ]; then
  said sC "commit that change on your branch and run the gates."
  git -C "$(W 02)" commit -q -am "capture: note window 02" || fail "commit"
  as sC bash core/gates.sh > "$S/gates-5.log" 2>&1 || { cat "$S/gates-5.log"; fail "gates"; }
fi
check "lease/02 has a commit origin/main lacks" test -n "$(git -C "$(T)" log --oneline origin/main..lease/02 2>/dev/null)"

note "Step 5b. The script now commits a conflicting change to the same line on origin's main (a stand-in for someone else's work)."
git clone -q "$S/thing.git" "$S/elsewhere"
sed -i.bak 's/    return dict(offsets)/    return dict(offsets)  # trunk/' "$S/elsewhere/hooks/capture.py" && rm -f "$S/elsewhere/hooks/capture.py.bak"
git -C "$S/elsewhere" commit -q -am "capture: a trunk change on the same line" && git -C "$S/elsewhere" push -q origin main
trunk_commit="$(origin_main)"
step 5b "Terminal 1, then terminal 2" "promote window 2. — then, in terminal 2: bring your work up to date with main." \
  "terminal 1: \"… does not merge cleanly onto current main … Tell window 02 to bring its work up to date …\" and \"Nothing was pushed.\"; terminal 2 rebases, resolves the conflict itself, runs the gates and says so in words"
if [ "$mode" = rehearse ]; then
  said sP "promote window 2."
  o="$(as sP bash core/promote.sh 02 2>&1)"; has "$o" "does not merge cleanly onto current" || fail "promote: $o"
  said sC "bring your work up to date with main."
  as sC bash core/lease.sh rebase 02 >/dev/null 2>&1   # stops on the conflict, by design
  sed -i.bak -e '/^<<<<<<< /d' -e '/^=======/d' -e '/^>>>>>>> /d' -e 's/  # trunk$/  # trunk, then window 02/' "$(W 02)/hooks/capture.py"
  rm -f "$(W 02)/hooks/capture.py.bak"
  python3 - "$(W 02)/hooks/capture.py" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().split("\n"); out = []
for ln in lines:
    if "return dict(offsets)" in ln:
        if any("return dict(offsets)" in o for o in out):
            continue
        ln = "    return dict(offsets)  # trunk, then window 02"
    out.append(ln)
open(p, "w").write("\n".join(out))
PY
  git -C "$(W 02)" add hooks/capture.py && GIT_EDITOR=true git -C "$(W 02)" rebase --continue >/dev/null 2>&1 || fail "rebase --continue"
  as sC bash core/gates.sh > "$S/gates-5b.log" 2>&1 || { cat "$S/gates-5b.log"; fail "gates after the rebase"; }
fi
check "lease/02 now contains the trunk commit" git -C "$(T)" merge-base --is-ancestor "$trunk_commit" lease/02

step 6 "Terminal 2" "push your branch onto main. — then: update hot.md to say the probe is done." \
  "the guard's sentence (\"Trunk is reached only through promote …\"); then a refusal naming the prime, window 01, for hot.md"
if [ "$mode" = rehearse ]; then
  said sC "push your branch onto main."
  d="$(bash_attempt sC "$(W 02)" "git push origin HEAD:main")"; has "$d" "Trunk is reached only through promote" || fail "guard: $d"
  said sC "update hot.md to say the probe is done."
  d="$(edit_attempt sC "$H/vault/hot.md")"; has "$d" '"permissionDecision": "deny"' || fail "hot.md: $d"; has "$d" "window 01" || fail "hot.md refusal does not name window 01: $d"
fi
note "Step 6, the script's half: the same push, run from a shell inside window 02's worktree, past the guard — git's own pre-push hook refuses it:"
p="$(git -C "$(W 02)" push origin HEAD:main 2>&1)"; printf '%s\n' "$p" | sed 's/^/  /'
check "git's pre-push hook refused a trunk push no promotion confirmed" has "$p" "This push would move main"
check "origin's main did not move" test "$(origin_main)" = "$trunk_commit"

step 7 "Terminal 1" "promote window 2. — then, after the block: yes, ship it." \
  "two paragraphs, the first with no hashes: \"Ready to promote window 02's work onto main …\"; after the yes, in a later reply, \"Promoted …\""
if [ "$mode" = rehearse ]; then
  said sP "promote window 2."
  o="$(promote_with_yes 02 "Ready to promote window 02's work onto main." 2>&1)" || fail "promote 02: $o"
  has "$o" "Promoted" || fail "confirm: $o"
  said sP "thanks"
fi
check "origin's main is the promoted merge" test "$(origin_main)" = "$(pj merge_sha 2>/dev/null)"
check "promotions.log has one line" test "$(grep -c . "$H/vault/evidence/promotions.log" 2>/dev/null)" = 1
check "the operator's yes is recorded from the transcript (run.json promotion.transcript_ref)" test -n "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["promotion"].get("transcript_ref") or "")' "$H/state/evidence/$(pj run_id)/run.json" 2>/dev/null)"
if [ "$mode" = rehearse ]; then
  st="$(printf '{"hook_event_name":"Stop","session_id":"sP","transcript_path":"%s"}' "$(txp sP)" | (cd "$H" && python3 core/boundary-hook.py) 2>&1; echo "exit=$?")"
  check "terminal 1's next Stop is not blocked" has "$st" "exit=0"
fi

step 7b "Terminal 2, then terminal 1" "delete the assertion from tests/test_capture.py and commit that on your branch. — then, in terminal 1: promote window 2. — what did the reviewer find? — ask the reviewer what its first finding meant. — promote it anyway, because this is a scenario and the assertion goes back in step 7c. — yes" \
  "the block's reviewer line says REFUTED; the review repeated word for word, signed as the reviewer; the reviewer's answer about its first finding, word for word; then a fresh block whose reviewer line reads \"skipped by the operator because: promote it anyway, because this is a scenario and the assertion goes back in step 7c\", and after the yes, Promoted"
if [ "$mode" = rehearse ]; then
  said sC "delete the assertion from tests/test_capture.py and commit that on your branch."
  as sC bash core/lease.sh rebase 02 >/dev/null 2>&1 || fail "rebase 02 onto the promoted trunk"
  sed -i.bak '/^assert /d' "$(W 02)/tests/test_capture.py" && rm -f "$(W 02)/tests/test_capture.py.bak"
  git -C "$(W 02)" commit -q -am "test: drop the assertion" || fail "commit"
  said sP "promote window 2."
  export FAKE_ANSWER="F1 [high] — Test honesty: the only assertion in tests/test_capture.py was deleted, so the gate passes whatever capture does.
VERDICT: REFUTED"
  o="$(as sP bash core/promote.sh 02 2>&1)"; has "$o" "Reviewer on the merged change: REFUTED" || fail "no REFUTED block: $o"
  ran sP "$o"; replied sP "Reviewer on the merged change: REFUTED. Nothing was pushed."
  said sP "what did the reviewer find?"
  rv="$(ls -t "$H"/vault/evidence/*-review.md 2>/dev/null | head -1)"
  check "the review file holds the reviewer's words" has "$(cat "$rv" 2>/dev/null)" "Test honesty"
  replied sP "$(sed '1,/^---$/d' "$rv" | sed '1,/^---$/d') — the reviewer"
  said sP "ask the reviewer what its first finding meant."
  export FAKE_ANSWER="Finding 1 means the test no longer checks anything: with the assertion gone it cannot fail."
  a="$(as sP bash core/call-agent.sh --resume-review 02 "what did your first finding mean?" 2>/dev/null)"
  check "the reviewer answered the follow-up" has "$a" "Finding 1 means"
  replied sP "$a — the reviewer. Reviewer on the merged change: REFUTED. To promote without the review I need your reason in your own words."
  r="promote it anyway, because this is a scenario and the assertion goes back in step 7c."
  said sP "$r"
  export FAKE_ANSWER="F1 — nothing found.
VERDICT: STANDS"
  o="$(as sP bash core/promote.sh 02 --skip-review --reason "$r" 2>&1)" || fail "skip-review prepare: $o"
  has "$o" "skipped by the operator because" || fail "no skipped line: $o"
  ran sP "$o"; replied sP "Ready to promote window 02's work onto main."; said sP "yes"
  o="$(as sP bash core/promote.sh 02 --confirm --operator-said "yes" 2>&1)" || fail "confirm after skip: $o"
fi
check "the ledger line names the overridden review" has "$(tail -1 "$H/vault/evidence/promotions.log")" "overrode:"
check "origin's trunk now has the test without its assertion" test -z "$(git -C "$S/thing.git" show main:tests/test_capture.py | grep '^assert ')"

step 7c "Terminal 1" "start a background clone to put the assertion back in tests/test_capture.py, and tell me when it is done. — who is working on what? — promote window 4. — yes. — release window 4." \
  "\"Window 04 is a background clone …\"; within a minute the board shows 04 (spawned) — FINISHED …; promote 04 with STANDS, then the yes; release 04 is not refused (the clone has finished) and succeeds"
if [ "$mode" = rehearse ]; then
  said sP "start a background clone to put the assertion back in tests/test_capture.py, and tell me when it is done."
  o="$(as sP bash core/lease.sh spawn "put the assertion back in tests/test_capture.py" 2>&1)"
  has "$o" "Window 04 is a background clone" || fail "spawn: $o"
  # The launch is detached (test_lease.bats's spawn test): give the stand-in claude up to 5 s to record it.
  launched() { grep -l -- '--bg' "$FAKE_CLAUDE_DIR"/*.argv 2>/dev/null | xargs cat 2>/dev/null; }
  for _ in $(seq 1 50); do has "$(launched)" "core/lease.sh done 04" && break; sleep 0.1; done
  check "the clone was launched in the background with the done instruction" has "$(launched)" "core/lease.sh done 04"
  c="$(open_window sK bg cli 04)"          # the clone's own SessionStart: bound to 04 by DAEDALUS_LEASE
  git -C "$(W 04)" merge -q --ff-only origin/main 2>/dev/null
  printf 'assert save_state({"a": 1}) == {"a": 1}\n' >> "$(W 04)/tests/test_capture.py"
  git -C "$(W 04)" commit -q -am "test: put the assertion back" || fail "clone commit"
  as sK bash core/lease.sh done 04 --summary "put the assertion back; gates pass" >/dev/null || fail "done"
  close_window sK
  said sP "who is working on what?"; b="$(board sP)"; has "$b" "(spawned) — FINISHED" || fail "board: $b"
  said sP "promote window 4."
  o="$(promote_with_yes 04 "Ready to promote window 04's work onto main." 2>&1)" || fail "promote 04: $o"
  said sP "release window 4."
  o="$(as sP bash core/lease.sh release 04 2>&1)" || fail "release 04 was refused: $o"
fi
check "window 04 was spawned and finished with a summary" test "$(lj 04 spawned)" = True -a -n "$(lj 04 summary)"
check "origin's trunk has the assertion back" test -n "$(git -C "$S/thing.git" show main:tests/test_capture.py | grep '^assert ')"
check "window 04 is released" test -n "$(lj 04 released)"

step 7d "Terminal 2, then terminal 1" "new problem: add a comment to README.md and forget about capture.py for now. — then, in terminal 1: who is working on what?" \
  "no ceremony: window 02 edits README.md in its own worktree; the board shows README.md in window 02's changed files; no new window, alias or note"
before_note="$(lj 02 note)"; before_alias="$(lj 02 alias)"
if [ "$mode" = rehearse ]; then
  said sC "new problem: add a comment to README.md and forget about capture.py for now."
  printf '\n<!-- a comment from window 02 -->\n' >> "$(W 02)/README.md"
  said sP "who is working on what?"; board sP >/dev/null
fi
check "window 02's changed set names README.md" has "$(python3 "$H/core/leaselib.py" changed 02)" "README.md"
check "no note or alias changed" test "$(lj 02 note)|$(lj 02 alias)" = "$before_note|$before_alias"

step 8 "Close terminal 3 with its window's close button; then terminal 1" "who is working on what? — clean up the dead ones. — (open a fresh terminal 3 and run \`claude\`; after this step, close it again)" \
  "03 (electron) — STALE; the sweep removes 03 and says 02 was left alone; worktrees/03 is still there; the fresh terminal 3 is told \"You are window 03\" again and works in the same worktree"
[ -d "$(W 03)" ] && : > "$(W 03)/.scenario-sentinel"
if [ "$mode" = rehearse ]; then
  close_window sE
  said sP "who is working on what?"; has "$(board sP)" "03 (electron) — STALE" || fail "board: $(board sP)"
  said sP "clean up the dead ones."; o="$(as sP bash core/lease.sh sweep 2>&1)"
  has "$o" "removed the lease of window 03" || fail "sweep: $o"
  c="$(open_window sE2)"; has "$c" "You are window 03" || fail "the fresh terminal 3: $c"
fi
check "the swept window's worktree was kept and re-used" test -f "$(W 03)/.scenario-sentinel"
check "window 03 is held again" test -n "$(lj 03 session_id)"
if [ "$mode" = rehearse ]; then close_window sE2; as sP bash core/lease.sh sweep >/dev/null 2>&1; fi

step 8b "Terminal 1, then terminal 2" "release window 2. — then, in terminal 2: release window 2." \
  "terminal 1: say that to window 02, or close it first; terminal 2: \"Window 02 released; this window is done — close it.\""
if [ "$mode" = rehearse ]; then
  said sP "release window 2."; o="$(as sP bash core/lease.sh release 02 2>&1)"
  has "$o" "to that window, or close it first" || fail "release from window 01 was not refused: $o"
  said sC "release window 2."; o="$(as sC bash core/lease.sh release 02 2>&1)"
  has "$o" "Window 02 released; this window is done — close it." || fail "release from window 02: $o"
  close_window sC
fi
check "window 02 is released and its worktree kept" test -n "$(lj 02 released)" -a -d "$(W 02)"

if [ "$mode" = interactive ] && [ -n "$bank" ]; then
  note "Step 9. The script adds a memory: block for bank $bank to the scratch config.yaml, then sends terminal 2's conversation to that memory and waits until the server confirms it has read it."
  printf 'memory:\n  bank: %s\n' "$bank" >> "$H/config.yaml"
  tr2="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$(printf '%s' "$H" | sed 's/[^A-Za-z0-9]/-/g')/$term2_session.jsonl"
  check "terminal 2's conversation was sent to memory and confirmed (the call close.sh makes)" \
    bash -c 'cd "$1" && bash core/close.sh --no-commit --transcript "$2"' _ "$H" "$tr2"
  step 9 "Terminal 1" "what did window 2 change?" "an answer that recalls window 02's change to hooks/capture.py and README.md"
else
  say "Step 9 (recall) is skipped: it needs a memory server; run interactively with --with-memory <bank> to include it."
fi

note "Step 11. Close terminal 2 and terminal 3 if they are still open. The script now clears away the released and closed windows, as \"clean up the dead ones\" would:"
as_shell_sweep="$(bash "$H/core/lease.sh" sweep 2>&1)"; printf '%s\n' "$as_shell_sweep" | sed 's/^/  /'
check "only window 01 and the pen's file remain" test "$(cd "$H/state/leases" && ls *.json | sort | tr '\n' ' ')" = "01.json prime.json "
step 11 "A new terminal 2 (run \`claude\`); then terminal 1" "take the pen; the operator says the scenario is closing. — then, in terminal 1: anything new?" \
  "the new terminal is told \"You are window 02\"; terminal 1's next prompt says it no longer holds the pen and names the reason"
if [ "$mode" = rehearse ]; then
  c="$(open_window sN)"; has "$c" "You are window 02" || fail "the new terminal 2: $c"
  r="take the pen; the operator says the scenario is closing."
  said sN "$r"; o="$(as sN bash core/lease.sh prime take --reason "$r" 2>&1)" || fail "prime take: $o"
  said sP "anything new?"; has "$(ctx "$S/board-sP.json")" "You no longer hold the pen" || fail "window 01 was not told"
fi
check "the pen moved to window 02" test "$(lj prime session_id)" = "$(lj 02 session_id)"

if [ "$mode" = rehearse ]; then say "Rehearsal complete: all $checks checks passed."; else say "Scenario complete: all $checks checks passed."; fi
