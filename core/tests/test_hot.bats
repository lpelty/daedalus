#!/usr/bin/env bats
# hot.md (v0.12.6, spec 2026-10-20 "hot.md: a reader at start, a shape per entry, and a 14-day question"):
# core/hot.py is the one write path — one entry block changed per call, under state/hot.lock, every other block
# byte-for-byte as it was; any window writes its own entries; session start shows In flight and Blocked in every
# window and asks the operator, once a day, about an entry that has sat for 14 days. No size limit anywhere (ruling A).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() {
  lease_fixture
  mkdir -p "$DAEDALUS_HOME/core/templates"; cp "$SRC/templates/hot.md" "$DAEDALUS_HOME/core/templates/"
  HOT="$DAEDALUS_HOME/vault/hot.md"
}
teardown() { teardown_live; }

hot_as() { local s="$1"; shift; env DAEDALUS_SESSION_ID="$s" python3 "$DAEDALUS_HOME/core/hot.py" "$@"; }
start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup","transcript_path":"%s/transcripts/%s.jsonl"}' "$1" "$BATS_TEST_TMPDIR" "$1" | python3 "$DAEDALUS_HOME/core/session-start.py"; }
ctx() { printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
days_ago() { python3 -c 'import datetime,sys; print((datetime.date.today()-datetime.timedelta(days=int(sys.argv[1]))).isoformat())' "$1"; }
today() { date +%Y-%m-%d; }

# window 01 = sA (the prime), window 02 = sB; both leases read stale until live_holder makes one live
two_windows() {
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null; bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  for p in 01:sA 02:sB; do nn="${p%%:*}"; s="${p##*:}"
    python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$nn" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(session_id=sys.argv[2],pid=1,proc_started=1); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$nn.json" "$s")"
    python3 "$DAEDALUS_HOME/core/leaselib.py" heartbeat "$nn"; done
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
}
live_holder() { local pid; pid="$(live_pid)"; python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$1" "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); d.update(pid=int(sys.argv[2]),proc_started=int(sys.argv[3])); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$1.json" "$pid" "$(ps_ms "$pid")")"; }

# blocks <file> — JSON {topic: block text} for every ### block, plus "__outside__": every line outside a block and
# outside the frontmatter. Written apart from hot.py's own parser, so the byte-for-byte checks do not trust it.
blocks() { python3 - "$1" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
lines = text.splitlines(True)
i = 0
if lines and lines[0] == "---\n":
    i = 1
    while i < len(lines) and lines[i] != "---\n":
        i += 1
    i += 1
out, cur, outside = {}, None, []
for ln in lines[i:]:
    if ln.startswith("### "):
        cur = ln[4:].strip(); out[cur] = ln; continue
    if ln.startswith("## ") or ln.startswith("# "):
        cur = None
    if cur is None:
        outside.append(ln)
    else:
        out[cur] += ln
out["__outside__"] = "".join(outside)
print(json.dumps(out, sort_keys=True))
PY
}
same_except() {   # same_except <before-json> <after-json> <topic...> — every block but the named ones is byte-identical
  python3 - "$@" <<'PY'
import json, sys
a, b, skip = json.loads(sys.argv[1]), json.loads(sys.argv[2]), set(sys.argv[3:])
bad = [k for k in set(a) | set(b) if k not in skip and a.get(k) != b.get(k)]
print("changed: %s" % bad if bad else "")
sys.exit(1 if bad else 0)
PY
}

@test "the template carries the entry shape under In flight and Blocked, the kept: field, where history goes, and no Done section" {
  T="$SRC/templates/hot.md"
  for s in '## In flight' '## Blocked' '### <topic, one line>' '- owner: <window NN, or operator, or another agent' '- since: YYYY-MM-DD' \
           '- where: <branch / file / proposal / backlog id>' '- next: <the one next action>' \
           '- done when: <the observable condition that removes this entry>' 'kept: YYYY-MM-DD' 'core/hot.py' \
           'session log' 'backlog'; do
    grep -qF -- "$s" "$T" || { echo "the template lacks: $s"; return 1; }
  done
  ! grep -qi 'Done since' "$T" || { echo "the template still has a Done section"; return 1; }
  ! grep -qiE 'line budget|lines at most|too long' "$T" || { echo "the template carries a size rule (ruling A)"; return 1; }
}

@test "session start shows In flight and Blocked with each entry's owner, next, done when and age, in the prime and in a non-prime window" {
  two_windows
  cp "$SRC/templates/hot.md" "$HOT"
  hot_as sB add "the probe for the capture lock" --where lease/02 --next "run the probe twice" --done-when "the probe passes twice in a row"
  hot_as sA add "the reviewer's answer on reach" --blocked --owner operator --next "the operator reads the review" --done-when "the operator says yes or no"
  python3 - "$HOT" "$(days_ago 3)" <<'PY'
import sys
p, d = sys.argv[1], sys.argv[2]
t = open(p).read().replace("- since: " + __import__("datetime").date.today().isoformat() + "\n- where: lease/02", "- since: %s\n- where: lease/02" % d, 1)
open(p, "w").write(t)
PY
  for s in sA sB; do
    run start "$s"; [ "$status" -eq 0 ]
    c="$(ctx)"
    case "$c" in *"In flight:"*"- the probe for the capture lock — owner: window 02 — 3 days — next: run the probe twice — done when: the probe passes twice in a row"*"Blocked:"*"- the reviewer's answer on reach — owner: operator — 0 days — next: the operator reads the review — done when: the operator says yes or no"*) : ;;
      *) echo "$s: $c"; return 1 ;; esac
    case "$c" in *"vault/hot.md"*"core/hot.py"*) : ;; *) echo "$s: the listing does not name the file and the script: $c"; return 1 ;; esac
  done
}

@test "the first start stamps since: on an undated entry and does not alert; a block not in entry form and free text are listed once to the prime and kept byte-for-byte; doctor lists them read-only" {
  two_windows
  cat > "$HOT" <<'EOF'
---
type: rolling-state
leases: (old)
updated: 2026-10-01
---

# Hot

## In flight

**EX-028 (2026-10-10) — the update command.** Promoted; the long history
of every round sits here.

### the undated entry
- owner: window 01
- where: lease/01
- next: finish it
- done when: it is merged

### a block with prose
It has no fields, only words.

## Blocked

## Standing gotchas

- never touch this
EOF
  free_before="$(sed -n '/^\*\*EX-028/,/^of every round/p' "$HOT")"
  prose_before="$(blocks "$HOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["a block with prose"])')"
  run start sA; [ "$status" -eq 0 ]; c="$(ctx)"
  grep -qx -- "- since: $(today)" "$HOT" || { cat "$HOT"; return 1; }
  case "$c" in *"has sat for"*) echo "the migration alerted: $c"; return 1 ;; esac
  case "$c" in *"hot.md has text not in entry form"*"(In flight): **EX-028 (2026-10-10) — the update command.**"*"(In flight): ### a block with prose"*) : ;; *) echo "$c"; return 1 ;; esac
  [ "$(sed -n '/^\*\*EX-028/,/^of every round/p' "$HOT")" = "$free_before" ] || { echo "free text changed"; cat "$HOT"; return 1; }
  [ "$(blocks "$HOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["a block with prose"])')" = "$prose_before" ]
  grep -qx -- "- never touch this" "$HOT"
  run start sA; c="$(ctx)"
  case "$c" in *"hot.md has text not in entry form"*) echo "listed twice: $c"; return 1 ;; esac
  case "$c" in *"- a block with prose — not in entry form"*"- and 1 paragraph of text not in entry form"*) : ;; *) echo "the listing hides them: $c"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/hot.py" --doctor; [ "$status" -eq 0 ]
  case "$output" in *"NOTE     hot.md: text not in entry form (In flight): **EX-028"*"NOTE     hot.md: text not in entry form (In flight): ### a block with prose"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(blocks "$HOT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["a block with prose"])')" = "$prose_before" ]
  # once reshaped, the pen's holder drops the old text by its id; no other window may
  id="$(printf '%s\n' "$output" | sed -n 's/.*(In flight): \*\*EX-028.* — id \([0-9a-f]*\), .*/\1/p')"
  [ -n "$id" ] || { echo "no id: $output"; return 1; }
  run hot_as sB drop "$id"; [ "$status" -ne 0 ]; case "$output" in *"Only the pen's holder"*) : ;; *) echo "$output"; return 1 ;; esac
  run hot_as sA drop "$id"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q 'EX-028' "$HOT"
  grep -q '^### the undated entry' "$HOT"; grep -q '^### a block with prose' "$HOT"
}

@test "hot.py add, update, remove and keep each change one block and leave every other block byte-identical" {
  two_windows
  cp "$SRC/templates/hot.md" "$HOT"
  printf '\n<!-- a hand note in the gotchas -->\n' >> "$HOT"
  hot_as sA add "first" --where a --next n1 --done-when d1
  hot_as sA add "second" --where b --next n2 --done-when d2
  hot_as sA add "third" --blocked --where c --next n3 --done-when d3
  b0="$(blocks "$HOT")"
  hot_as sA add "fourth" --where e --next n4 --done-when d4; b1="$(blocks "$HOT")"
  same_except "$b0" "$b1" fourth
  hot_as sA update "second" --next "n2 moved" --where "b2"; b2="$(blocks "$HOT")"
  same_except "$b1" "$b2" second
  printf '%s' "$b2" | python3 -c 'import json,sys; b=json.load(sys.stdin)["second"]; assert "- next: n2 moved\n" in b and "- where: b2\n" in b, b'
  hot_as sA keep "third"; b3="$(blocks "$HOT")"
  same_except "$b2" "$b3" third
  printf '%s' "$b3" | python3 -c 'import json,sys,datetime; b=json.load(sys.stdin)["third"]; assert "- kept: %s\n" % datetime.date.today() in b, b'
  hot_as sA remove "first"; b4="$(blocks "$HOT")"
  same_except "$b3" "$b4" first
  printf '%s' "$b4" | python3 -c 'import json,sys; assert "first" not in json.load(sys.stdin)'
  grep -qF '<!-- a hand note in the gotchas -->' "$HOT"
  # the frontmatter's leases: is the live board, refreshed on each write; updated: is today
  grep -q '^leases: ".*01' "$HOT" || { head -8 "$HOT"; return 1; }
  grep -qx "updated: $(today)" "$HOT"
  run hot_as sA add "second" --next x --done-when y; [ "$status" -ne 0 ]
  case "$output" in *"already has an entry 'second'"*) : ;; *) echo "$output"; return 1 ;; esac
  run hot_as sA remove "nothing like it"; [ "$status" -ne 0 ]
  case "$output" in *"no entry 'nothing like it'"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "two hot.py writers racing (two processes, overlapping) both land: no write is lost" {
  two_windows
  cp "$SRC/templates/hot.md" "$HOT"
  for w in sA sB; do
    ( for i in 1 2 3 4 5 6 7 8; do hot_as "$w" add "$w entry $i" --next "n" --done-when "d" >/dev/null 2>&1 || echo "FAIL $w $i"; done ) > "$BATS_TEST_TMPDIR/race-$w" 3>&- &
  done
  wait
  [ ! -s "$BATS_TEST_TMPDIR/race-sA" ] && [ ! -s "$BATS_TEST_TMPDIR/race-sB" ] || { cat "$BATS_TEST_TMPDIR"/race-*; return 1; }
  [ "$(grep -c '^### s[AB] entry ' "$HOT")" -eq 16 ] || { cat "$HOT"; return 1; }
  [ -f "$DAEDALUS_HOME/state/hot.lock" ]
}

@test "a non-prime window adds, updates and removes its own entries; it is refused on another live window's entry with the owner named, and allowed on a carried one" {
  two_windows; live_holder 01; live_holder 02
  bash "$DAEDALUS_HOME/core/lease.sh" alias 01 main-ui >/dev/null
  cp "$SRC/templates/hot.md" "$HOT"
  run hot_as sB add "mine" --next n --done-when d; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx -- "- owner: window 02" "$HOT"
  run hot_as sB update "mine" --next "n again"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run hot_as sB remove "mine"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^### mine' "$HOT"
  hot_as sA add "the prime's" --next n --done-when d
  before="$(cat "$HOT")"
  for op in "update --next x" "remove" "keep"; do
    # shellcheck disable=SC2086
    run hot_as sB $op "the prime's"; [ "$status" -ne 0 ] || { echo "$op went through"; return 1; }
    case "$output" in *"The hot.md entry 'the prime's' belongs to window 01 (main-ui), which is open"*"--operator-said"*) : ;; *) echo "$op: $output"; return 1 ;; esac
  done
  [ "$(cat "$HOT")" = "$before" ]
  hot_as sA carry
  grep -qx -- "- owner: carried from window 01, $(today)" "$HOT" || { cat "$HOT"; return 1; }
  run hot_as sB update "the prime's" --owner 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx -- "- owner: window 02" "$HOT"
  run hot_as sB remove "the prime's"; [ "$status" -eq 0 ]
  # an entry whose owner is not a window (the operator, another agent) is any window's to remove when its done when is met
  hot_as sA add "waiting on the operator" --blocked --owner operator --next n --done-when d
  run hot_as sB remove "waiting on the operator"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # a visitor writes nothing
  run env DIRECT_CALL_ID=x DAEDALUS_SESSION_ID=sV python3 "$DAEDALUS_HOME/core/hot.py" add "v" --next n --done-when d
  [ "$status" -ne 0 ]; case "$output" in *"direct-call session"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "close marks the window's remaining entries carried; a sweep does the same for a swept window, and only for it" {
  two_windows
  cp "$SRC/templates/hot.md" "$HOT"
  hot_as sA add "a" --next n --done-when d
  hot_as sB add "b1" --next n --done-when d
  hot_as sB add "b2" --blocked --next n --done-when d
  run hot_as sA carry; [ "$status" -eq 0 ]
  case "$output" in *"1 hot.md entry of window 01 is marked carried"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(grep -c -- "^- owner: carried from window 01, $(today)$" "$HOT")" -eq 1 ]
  [ "$(grep -c -- '^- owner: window 02$' "$HOT")" -eq 2 ]
  # window 02 reads stale (its recorded process is gone): the sweep removes its lease and carries its entries
  run bash "$DAEDALUS_HOME/core/lease.sh" sweep; [ "$status" -eq 0 ]
  case "$output" in *"removed the lease of window 02"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(grep -c -- "^- owner: carried from window 02, $(today)$" "$HOT")" -eq 2 ] || { cat "$HOT"; return 1; }
  # close.sh runs the carry before the vault commit
  grep -n 'hot.py" carry' "$SRC/close.sh" >/dev/null
  [ "$(grep -n 'hot.py" carry' "$SRC/close.sh" | cut -d: -f1)" -lt "$(grep -n 'phase 2/2: vault commit' "$SRC/close.sh" | cut -d: -f1)" ]
}

@test "an entry 14 days old alerts at the top of the first window's start only; a second window the same day does not; an unanswered alert asks again the next day; kept: restarts the clock" {
  two_windows
  cp "$SRC/templates/hot.md" "$HOT"
  hot_as sA add "old one" --owner 02 --next n --done-when d
  hot_as sA add "young one" --next n --done-when d
  sed -i '' "s/^- since: $(today)\$/- since: $(days_ago 14)/" "$HOT"
  sed -i '' "/^### young one/,/^- since/ s/^- since: .*/- since: $(days_ago 13)/" "$HOT"
  run start sA; c="$(ctx)"
  second="$(printf '%s\n' "$c" | awk 'NR>1 && NF {print; exit}')"
  [ "$second" = "hot.md entry 'old one' has sat for 14 days (owner: window 02). Move it to the backlog, or keep working on it in a window?" ] || { echo "$c"; return 1; }
  case "$c" in *"young one' has sat"*) echo "a 13-day entry alerted: $c"; return 1 ;; esac
  case "$c" in *"Ask the operator this in your first reply"*'python3 core/hot.py remove "old one"'*'python3 core/hot.py keep "old one"'*) : ;; *) echo "$c"; return 1 ;; esac
  python3 -c 'import json,sys,datetime; d=json.load(open(sys.argv[1])); e=d["old one"]; assert e["asked"]==datetime.date.today().isoformat() and e["session"]=="sA", d' "$DAEDALUS_HOME/state/hot-due.json"
  run start sB; c="$(ctx)"
  case "$c" in *"has sat for"*) echo "asked twice the same day: $c"; return 1 ;; esac
  # the next day's first start asks again while it stays unanswered
  python3 -c 'import json,sys,datetime; p=sys.argv[1]; d=json.load(open(p)); d["old one"]["asked"]=(datetime.date.today()-datetime.timedelta(days=1)).isoformat(); json.dump(d,open(p,"w"))' "$DAEDALUS_HOME/state/hot-due.json"
  run start sB; c="$(ctx)"
  case "$c" in *"hot.md entry 'old one' has sat for 14 days"*) : ;; *) echo "not asked again: $c"; return 1 ;; esac
  # the window that asked applies the answer itself: keep stamps kept: today
  run hot_as sB keep "old one" --owner 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx -- "- kept: $(today)" "$HOT"
  rm -f "$DAEDALUS_HOME/state/hot-due.json"
  run start sA; c="$(ctx)"
  case "$c" in *"has sat for"*) echo "kept: did not restart the clock: $c"; return 1 ;; esac
  # kept 14 days ago restarts nothing more: due again
  sed -i '' "s/^- kept: .*/- kept: $(days_ago 14)/" "$HOT"
  run start sA; c="$(ctx)"
  case "$c" in *"hot.md entry 'old one' has sat for 14 days"*) : ;; *) echo "$c"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/hot.py" due; [ "$status" -eq 0 ]
  case "$output" in *"old one"*"14 days"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "CLAUDE.md: hot.md is read at every start and written only through core/hot.py; the prime no longer writes it alone; the close order names hot.py; the 14-day question and its two answers; no size rule" {
  CM="$(tr '\n' ' ' < "$SRC/../CLAUDE.md" | tr -s ' ')"
  for s in '## hot.md' 'Every session start shows its `## In flight` and `## Blocked` entries, in every window' \
           'It changes only through `core/hot.py`.' 'python3 core/hot.py add "<topic>"' 'python3 core/hot.py remove "<topic>"` in that same turn' \
           'Another open window'"'"'s entry is that window'"'"'s' '`core/close.sh` then marks the rest `owner: carried from window NN, YYYY-MM-DD`' \
           'python3 core/hot.py update "<topic>" --owner <your NN>' 'Move it to the backlog, or keep working on it in a window?' \
           'python3 core/hot.py keep "<topic>"' 'There is no limit on length.' 'only it commits the vault'; do
    case "$CM" in *"$s"*) : ;; *) echo "CLAUDE.md lacks: $s"; return 1 ;; esac
  done
  for s in 'only it writes `hot.md`' 'Only the prime writes `hot.md`' '(only if this session holds the pen)'; do
    case "$CM" in *"$s"*) echo "CLAUDE.md still says: $s"; return 1 ;; esac
  done
}

@test "review 2026-10-20: release --remove carries the window's entries; a spawned clone is shown hot.md but not asked; a topic ending in # is found; a ~~~ line inside a \`\`\` fence hides no entry" {
  two_windows
  cp "$SRC/templates/hot.md" "$HOT"
  hot_as sB add "b" --next n --done-when d
  run env -u DAEDALUS_SESSION_ID bash "$DAEDALUS_HOME/core/lease.sh" release 02 --remove --force; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -qx -- "- owner: carried from window 02, $(today)" "$HOT" || { cat "$HOT"; return 1; }
  # a spawned clone: no ask recorded, the listing still shown
  hot_as sA add "old" --next n --done-when d
  sed -i '' "/^### old/,/^- since/ s/^- since: .*/- since: $(days_ago 20)/" "$HOT"
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 01 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["spawned"]=True; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/01.json")"
  run start sA; c="$(ctx)"
  case "$c" in *"has sat for"*) echo "a clone was asked: $c"; return 1 ;; esac
  case "$c" in *"- old — owner: window 01 — 20 days"*) : ;; *) echo "$c"; return 1 ;; esac
  [ ! -f "$DAEDALUS_HOME/state/hot-due.json" ] || ! grep -q '"old"' "$DAEDALUS_HOME/state/hot-due.json"
  # a topic ending in #
  hot_as sA add "Port to C#" --next n --done-when d
  run hot_as sA update "Port to C#" --next m; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run hot_as sA add "Port to C#" --next n --done-when d; [ "$status" -ne 0 ]
  # fences close only on their own kind
  printf -- '---\ntype: rolling-state\n---\n\n## In flight\n\n```\n~~~\n```\n\n### after the fence\n- owner: window 01\n- since: %s\n- next: n\n- done when: d\n' "$(today)" > "$HOT"
  run python3 "$DAEDALUS_HOME/core/hot.py" show
  case "$output" in *"- after the fence — owner: window 01"*) : ;; *) echo "$output"; return 1 ;; esac
}

# A deployment's hot.md as it stands before v0.12.6: the section names of a live one, made-up bodies.
legacy_hot() {
  cat > "$HOT" <<'EOF2'
---
type: rolling-state
leases: "02 — prime"
updated: 2026-10-14
---

# Hot — where the work stands

Intent only.

## Standing decision (the operator, 2026-08-30)

**The diagnosis duty is mine.** A paragraph that settles an old question.

## In flight

**EX-1 — a long-running item.** Its history, round after round.

## Done since the last entry

- **A finished thing (window 01).** Merged and verified.
- **Another finished thing.** Also merged.

## Still waiting on the agent

- The reply on the migration design (asked 2026-10-01).

## Waiting on the operator

- Whether the doctor tenant retires.
- Whether the budget rises.

## Proposals budget: 4/5

PROP-1, PROP-2, PROP-3, PROP-4 open.

## Standing gotchas

- Never commit the target's lockfile.
EOF2
}

@test "a hot.md with sections outside the shape: every window's start names each one with its line count; the pen's holder gets the reshaping list once with where each kind goes; drop removes a moved section by name; add --blocked puts Blocked right after In flight; doctor names them" {
  two_windows; legacy_hot
  before="$(cat "$HOT")"
  run start sB; c="$(ctx)"
  for s in "## Standing decision (the operator, 2026-08-30) (1 line)" "## Done since the last entry (2 lines)" "## Still waiting on the agent (1 line)" \
           "## Waiting on the operator (2 lines)" "## Proposals budget: 4/5 (1 line)" "## Standing gotchas (1 line)"; do
    case "$c" in *"Not in the hot.md shape"*"- $s"*) : ;; *) echo "the start hides: $s"; echo "$c"; return 1 ;; esac
  done
  case "$c" in *"hot.md has text not in entry form"*) echo "a non-prime got the reshaping list: $c"; return 1 ;; esac
  [ "$(cat "$HOT")" = "$before" ] || { echo "the start changed the file"; return 1; }
  run start sA; c="$(ctx)"
  case "$c" in *"hot.md has text not in entry form"*'python3 core/hot.py drop "<section name>"'*"waiting on someone → a Blocked entry each"*"the owner is who it waits on"*"done → your session log"*"pitfalls/ or CLAUDE.md"*"- ## Waiting on the operator (2 lines), a section outside In flight and Blocked"*) : ;; *) echo "$c"; return 1 ;; esac
  run start sA; c="$(ctx)"
  case "$c" in *"hot.md has text not in entry form"*) echo "listed twice: $c"; return 1 ;; esac
  case "$c" in *"- ## Waiting on the operator (2 lines)"*) : ;; *) echo "the start stopped naming it: $c"; return 1 ;; esac
  # the waiting items become Blocked entries: Blocked lands right after In flight, never at the end of the file
  hot_as sA add "whether the doctor tenant retires" --blocked --owner operator --next "ask the operator" --done-when "the operator decides"
  [ "$(grep -c '^## Blocked$' "$HOT")" -eq 1 ]
  [ "$(awk '/^## /{print}' "$HOT" | sed -n '3p')" = "## Blocked" ] || { awk '/^## /' "$HOT"; return 1; }
  [ "$(awk '/^## /{print}' "$HOT" | sed -n '2p')" = "## In flight" ]
  # drop removes a moved section by name; another window may not
  run hot_as sB drop "Waiting on the operator"; [ "$status" -ne 0 ]
  run hot_as sA drop "Waiting on the operator"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q 'Waiting on the operator' "$HOT"; ! grep -q 'Whether the budget rises' "$HOT"
  grep -q '^## Proposals budget: 4/5' "$HOT"; grep -q '^## Still waiting on the agent' "$HOT"
  run hot_as sA drop "no such section"; [ "$status" -ne 0 ]
  run python3 "$DAEDALUS_HOME/core/hot.py" --doctor
  case "$output" in *"NOTE     hot.md: section not in the hot.md shape: ## Done since the last entry (2 lines)"*"NOTE     hot.md: section not in the hot.md shape: ## Standing gotchas (1 line)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Waiting on the operator"*) echo "$output"; return 1 ;; esac
}

@test "the upgrade's session: → leases: rename of hot.md waits for state/hot.lock, so it never races a window's hot.py write (review 2026-10-20, finding 8)" {
  cp "$SRC/upgrade.py" "$DAEDALUS_HOME/core/" 2>/dev/null || true
  printf -- '---\ntype: rolling-state\nsession: 011\n---\n\n## In flight\n' > "$HOT"
  python3 -c 'import sys,time; sys.path.insert(0,sys.argv[1]); import hot
from pathlib import Path
with hot.hot_lock(Path(sys.argv[2])):
    open(sys.argv[3],"w").close(); time.sleep(2)' "$DAEDALUS_HOME/core" "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR/held" 3>&- &
  until [ -f "$BATS_TEST_TMPDIR/held" ]; do sleep 0.05; done
  run python3 -c 'import sys,time; sys.path.insert(0,sys.argv[1]); import upgrade
from pathlib import Path
t=time.time(); print(upgrade.step_hot(Path(sys.argv[2]), "Upgrade", False, None)); print("waited %.1f" % (time.time()-t))' "$DAEDALUS_HOME/core" "$DAEDALUS_HOME"
  wait
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"renamed vault/hot.md's session: line to leases:"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import sys; w=float(sys.argv[1].rsplit("waited ",1)[1]); assert w >= 1.5, w' "$output"
  grep -q '^leases:' "$HOT"; ! grep -q '^session:' "$HOT"
}
