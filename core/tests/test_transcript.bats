#!/usr/bin/env bats
# Pins the recorded yes (spec §7.2 step 2, §7.4, A12): capture.py's one parser and
# transcriptlib's rule for which entry the operator typed, on transcripts built from
# the redacted transcript of the live build (fixtures/transcripts/live.jsonl).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
load fixtures/transcripts/setup.bash
load fixtures/tty/setup.bash
setup() { SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"; F="$BATS_TEST_TMPDIR/t.jsonl"; T0="$(now)"; }
teardown() { [ -z "${SCREEN_NAME:-}" ] || screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true; teardown_live; }

# probe_script — $PROBE: reads one line with tty_answer against $DAEDALUS_HOME and prints
# GOT <line> | NOTAPERSON <why> | NOTERMINAL <why>.
probe_script() {
  PROBE="$BATS_TEST_TMPDIR/probe.py"
  cat > "$PROBE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import transcriptlib as tl
try:
    print("GOT", tl.tty_answer("Type it: ", Path(sys.argv[2]))[0])
except tl.NotAPerson as e:
    print("NOTAPERSON", e)
except tl.NoTerminal as e:
    print("NOTERMINAL", e)
PY
}

# yes_check <file> <quote> <after-epoch> [shown 1|0] [shown text] — ACCEPTED <operator uuid> <shown uuid> | NOTFOUND | NOTSHOWN | UNREADABLE <why> | MISSING
yes_check() {
  python3 - "$SRC" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import transcriptlib as tl
f, quote, after = sys.argv[2], sys.argv[3], float(sys.argv[4])
shown = (sys.argv[5] if len(sys.argv) > 5 else "1") == "1"
mark = sys.argv[6] if len(sys.argv) > 6 else None
try:
    r = tl.find_operator_words(f, quote, after, shown, mark)
    print("ACCEPTED", r["transcript_ref"]["uuid"], (r["shown_ref"] or {}).get("uuid") or "")
except tl.Missing:
    print("MISSING")
except tl.Unreadable as e:
    print("UNREADABLE", e)
except tl.NotShown:
    print("NOTSHOWN")
except tl.NotFound:
    print("NOTFOUND")
PY
}

@test "scan_entries reads every entry of the live-shape fixture and _scan_transcript's turns are built on it" {
  run python3 - "$SRC" "$BATS_TEST_DIRNAME/fixtures/transcripts/live.jsonl" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import capture
lines = open(sys.argv[2]).read().splitlines()
entries, unknown, total = capture.scan_entries(lines)
assert unknown == 0 and total == len([l for l in lines if l.strip()]) == len(entries), (unknown, total)
assert all(e["readable"] for e in entries)
assert any(e["tool_result"] for e in entries) and any(e["type"] == "assistant" and e["text"] for e in entries)
convo, u2, t2 = capture._scan_transcript(lines)
assert (u2, t2) == (unknown, total) and convo.count("User: ") >= 1
print("ok")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "accepted: the operator typed the words after the cut-off, after an assistant turn with text; the refs name those two entries; normalization folds case, spacing and surrounding punctuation" {
  tx "$F" operator "promote window 2" "$(plus "$T0" -60)" >/dev/null
  tx "$F" tool-result "prepared" "$(plus "$T0" 1)" >/dev/null
  shown="$(tx "$F" assistant "Ready to promote window 02's work onto main." "$(plus "$T0" 2)")"
  said="$(tx "$F" operator "  YES,   push it! " "$(plus "$T0" 3)")"
  run yes_check "$F" "yes, push it" "$T0"
  [ "$output" = "ACCEPTED $said $shown" ] || { echo "$output"; return 1; }
}

@test "not the operator: the words only in a tool result, an isMeta entry, a peer message, a task notification, a queued prompt or a slash-command record are not found" {
  tx "$F" assistant "the block" "$(plus "$T0" 1)" >/dev/null
  for kind in tool-result meta peer task-notification queued command; do
    rm -f "$F"; tx "$F" assistant "the block" "$(plus "$T0" 1)" >/dev/null
    tx "$F" "$kind" "yes push it" "$(plus "$T0" 2)" >/dev/null
    run yes_check "$F" "yes push it" "$T0"
    [ "$output" = "NOTFOUND" ] || { echo "$kind: $output"; return 1; }
  done
}

@test "before the cut-off is not a yes; after it with no assistant text between is NOTSHOWN — unless the check does not require a shown turn (prime take)" {
  tx "$F" operator "yes push it" "$(plus "$T0" -5)" >/dev/null
  run yes_check "$F" "yes push it" "$T0"; [ "$output" = "NOTFOUND" ] || { echo "$output"; return 1; }
  tx "$F" tool-result "prepared" "$(plus "$T0" 1)" >/dev/null
  said="$(tx "$F" operator "yes push it" "$(plus "$T0" 2)")"
  run yes_check "$F" "yes push it" "$T0"; [ "$output" = "NOTSHOWN" ] || { echo "$output"; return 1; }
  run yes_check "$F" "yes push it" "$T0" 0; [ "$output" = "ACCEPTED $said " ] || { echo "$output"; return 1; }
}

@test "fail closed (A12): an unreadable entry after the cut-off, or the words only in a user entry with no origin field, is UNREADABLE — never accepted; an unreadable entry before the cut-off does not matter; no file is MISSING" {
  tx "$F" malformed "x" "$(plus "$T0" -5)" >/dev/null
  tx "$F" assistant "the block" "$(plus "$T0" 1)" >/dev/null
  said="$(tx "$F" operator "yes push it" "$(plus "$T0" 2)")"
  run yes_check "$F" "yes push it" "$T0"; [ "$output" = "ACCEPTED $said $(sed -n 2p "$F" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["uuid"])')" ] || { echo "$output"; return 1; }
  tx "$F" malformed "x" "$(plus "$T0" 3)" >/dev/null
  run yes_check "$F" "yes push it" "$T0"; case "$output" in "UNREADABLE "*"shape this build does not read"*) : ;; *) echo "$output"; return 1 ;; esac
  rm -f "$F"; tx "$F" assistant "the block" "$(plus "$T0" 1)" >/dev/null; tx "$F" no-origin "yes push it" "$(plus "$T0" 2)" >/dev/null
  run yes_check "$F" "yes push it" "$T0"; case "$output" in "UNREADABLE "*"no origin field"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'not json\n' >> "$F"
  run yes_check "$F" "yes push it" "$T0"; case "$output" in "UNREADABLE "*) : ;; *) echo "$output"; return 1 ;; esac
  run yes_check "$BATS_TEST_TMPDIR/none.jsonl" "yes" "$T0"; [ "$output" = "MISSING" ]
}

@test "fail closed (A12): a timestamp this build does not read — an offset instead of Z, epoch milliseconds — on the entries after the cut-off is UNREADABLE (the sentence that names tty), never NOTFOUND" {
  tx "$F" operator "promote window 2" "$(plus "$T0" -60)" >/dev/null
  tx "$F" assistant "Ready to promote window 02's work onto main." "$(plus "$T0" 1)" >/dev/null
  said="$(tx "$F" operator "yes push it" "$(plus "$T0" 2)")"
  run yes_check "$F" "yes push it" "$T0"; case "$output" in "ACCEPTED $said "*) : ;; *) echo "$output"; return 1 ;; esac
  for form in offset epoch-ms; do
    python3 - "$F" "$F.$form" "$form" <<'PY'
import json, sys
rows = [json.loads(ln) for ln in open(sys.argv[1]) if ln.strip()]
for r in rows[1:]:
    r["timestamp"] = r["timestamp"].replace("Z", "-00:00") if sys.argv[3] == "offset" else 1790000000000
open(sys.argv[2], "w").write("".join(json.dumps(r) + "\n" for r in rows))
PY
    run yes_check "$F.$form" "yes push it" "$T0"
    case "$output" in "UNREADABLE "*"shape this build does not read"*) : ;; *) echo "$form: $output"; return 1 ;; esac
  done
}

@test "transcript_for prefers the SessionStart marker's transcript_path, else memory.transcript_dir, else the home's Claude Code project directory; transcript_dirs names both directories, resolved" {
  lease_fixture
  run python3 - "$SRC" "$DAEDALUS_HOME" "$BATS_TEST_TMPDIR" <<'PY'
import json, os, re, sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
import transcriptlib as tl
home, tmp = Path(sys.argv[2]), Path(sys.argv[3])
proj = (tmp / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(home.resolve()))).resolve()
assert tl.transcript_dirs(home) == [proj], tl.transcript_dirs(home)
assert tl.transcript_for(home, "sX") == proj / "sX.jsonl"
other = (tmp / "projects" / "-another-cwd").resolve(); other.mkdir(parents=True)   # a session started elsewhere
rec = other / "sX.jsonl"; rec.write_text("")
(home / "state" / "session-sX.json").write_text(json.dumps({"session_id": "sX", "transcript_path": str(rec)}))
assert tl.transcript_for(home, "sX") == rec
assert other in tl.transcript_dirs(home), tl.transcript_dirs(home)          # Decision 36: denied as well as read
out = (tmp / "elsewhere").resolve(); out.mkdir(); (out / "sZ.jsonl").write_text("")
(home / "state" / "session-sZ.json").write_text(json.dumps({"session_id": "sZ", "transcript_path": str(out / "sZ.jsonl")}))
try:
    tl.transcript_for(home, "sZ")
    raise SystemExit("a transcript outside every denied directory was accepted")
except tl.Unprotected:
    pass
assert out not in tl.transcript_dirs(home)
# a transcript with a second hard link shares its bytes with a file outside the denied
# directory, which anything may write: not evidence (plan 4 Task 2 review)
forged = out / "forged.jsonl"; os.link(rec, forged)
try:
    tl.transcript_for(home, "sX")
    raise SystemExit("a hard-linked transcript was accepted")
except tl.Unprotected:
    pass
forged.unlink()
assert tl.transcript_for(home, "sX") == rec
print("ok")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mkdir -p "$BATS_TEST_TMPDIR/tdir"
  printf 'memory:\n  transcript_dir: %s\n' "$BATS_TEST_TMPDIR/tdir" >> "$DAEDALUS_HOME/config.yaml"
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import transcriptlib as tl; d = tl.transcript_dirs(Path(sys.argv[2])); print(d[0]); print(tl.transcript_for(Path(sys.argv[2]), "sY"))' "$SRC" "$DAEDALUS_HOME"
  [ "${lines[0]}" = "$(cd "$BATS_TEST_TMPDIR/tdir" && pwd -P)" ]; [ "${lines[1]}" = "$(cd "$BATS_TEST_TMPDIR/tdir" && pwd -P)/sY.jsonl" ]
}

@test "the yes is the operator's whole turn (Decision 30): a fragment of a longer turn is not found, whatever it is; the shown turn must carry the block's opening words when they are named; is_yes wants the word yes first" {
  tx "$F" assistant "Ready to promote window 02's work onto main." "$(plus "$T0" 1)" >/dev/null
  tx "$F" operator "No, wait — what did the reviewer say about F2?" "$(plus "$T0" 2)" >/dev/null
  for q in "wait" "e" "no" "No, wait"; do
    run yes_check "$F" "$q" "$T0"; [ "$output" = "NOTFOUND" ] || { echo "$q: $output"; return 1; }
  done
  tx "$F" assistant "F2 was a naming nit. Ready to promote window 02's work onto main. Say yes to push." "$(plus "$T0" 2.5)" >/dev/null
  tx "$F" operator "Yes — push it." "$(plus "$T0" 3)" >/dev/null
  run yes_check "$F" "yes" "$T0"; [ "$output" = "NOTFOUND" ] || { echo "$output"; return 1; }
  run yes_check "$F" "yes — push it" "$T0" 1 "Ready to promote window 02's work onto main"
  case "$output" in "ACCEPTED "*) : ;; *) echo "$output"; return 1 ;; esac
  rm -f "$F"
  tx "$F" assistant "Something else entirely." "$(plus "$T0" 1)" >/dev/null; tx "$F" operator "yes" "$(plus "$T0" 2)" >/dev/null
  run yes_check "$F" "yes" "$T0" 1 "Ready to promote window 02's work onto main"; [ "$output" = "NOTSHOWN" ] || { echo "$output"; return 1; }
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import transcriptlib as tl
assert tl.is_yes("Yes, push it.") and tl.is_yes("  YES") and tl.is_yes("yes")
assert not tl.is_yes("no, wait") and not tl.is_yes("yesterday was fine") and not tl.is_yes("ok") and not tl.is_yes("")
print("ok")' "$SRC"
  [ "$output" = "ok" ] || { echo "$output"; return 1; }
}

@test "the yes answers the block itself: after the operator's reply to the block (a no, a question, a queued prompt), a yes to a later question is NOTSHOWN; shown again, it is accepted; more text in the block's own turn does not matter" {
  mark="Ready to promote window 02's work (poc-ui) onto main"
  tx "$F" assistant "Ready to promote window 02's work (poc-ui) onto main. Say yes to push." "$(plus "$T0" 1)" >/dev/null
  tx "$F" operator "No. What did the reviewer say about the low finding?" "$(plus "$T0" 2)" >/dev/null
  tx "$F" assistant "It was a naming nit. Separately: shall I update the CHANGELOG entry now?" "$(plus "$T0" 3)" >/dev/null
  tx "$F" operator "yes" "$(plus "$T0" 4)" >/dev/null
  run yes_check "$F" "yes" "$T0" 1 "$mark"; [ "$output" = "NOTSHOWN" ] || { echo "no then yes: $output"; return 1; }
  again="$(tx "$F" assistant "Ready to promote window 02's work (poc-ui) onto main. Say yes to push." "$(plus "$T0" 5)")"
  said="$(tx "$F" operator "yes push it" "$(plus "$T0" 6)")"
  run yes_check "$F" "yes push it" "$T0" 1 "$mark"; [ "$output" = "ACCEPTED $said $again" ] || { echo "shown again: $output"; return 1; }
  rm -f "$F"
  tx "$F" assistant "Ready to promote window 02's work (poc-ui) onto main." "$(plus "$T0" 1)" >/dev/null
  tx "$F" queued "check the CHANGELOG too" "$(plus "$T0" 2)" >/dev/null
  tx "$F" operator "yes" "$(plus "$T0" 3)" >/dev/null
  run yes_check "$F" "yes" "$T0" 1 "$mark"; [ "$output" = "NOTSHOWN" ] || { echo "queued between: $output"; return 1; }
  rm -f "$F"
  block="$(tx "$F" assistant "Ready to promote window 02's work (poc-ui) onto main." "$(plus "$T0" 1)")"
  tx "$F" tool-result "board read" "$(plus "$T0" 2)" >/dev/null
  tx "$F" assistant "Say yes to push." "$(plus "$T0" 3)" >/dev/null
  said="$(tx "$F" operator "yes" "$(plus "$T0" 4)")"
  run yes_check "$F" "yes" "$T0" 1 "$mark"; [ "$output" = "ACCEPTED $said $block" ] || { echo "same turn: $output"; return 1; }
}

@test "tty_answer reads one line from the terminal it is typed at (raw reads — a text-mode r+ stream on /dev/tty cannot be opened); with no terminal it is NoTerminal" {
  lease_fixture; probe_script
  run type_into "yes" "Type it: " python3 "$PROBE" "$SRC" "$DAEDALUS_HOME"
  case "$output" in *"GOT yes"*) : ;; *) echo "$output"; return 1 ;; esac
  run no_tty python3 "$PROBE" "$SRC" "$DAEDALUS_HOME"
  case "$output" in *"NOTERMINAL"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "tty_answer is not a person's terminal (Decision 32): under a process named claude, or double-forked away to launchd with no terminal login between, it refuses on a pseudo-terminal that would answer; the seam works only for a home under the temp directory" {
  lease_fixture; probe_script
  TI="$BATS_TEST_DIRNAME/fixtures/tty/type-into.py"
  run under_fake_agent python3 "$TI" "yes" "Type it: " -- python3 "$PROBE" "$SRC" "$DAEDALUS_HOME"
  case "$output" in *"NOTAPERSON"*"Claude Code"*) : ;; *) echo "$output"; return 1 ;; esac
  run env -u DAEDALUS_TEST_TTY_ANCESTRY python3 "$TI" --detach "yes" "Type it: " -- python3 "$PROBE" "$SRC" "$DAEDALUS_HOME"
  case "$output" in *"NOTAPERSON"*"terminal login"*) : ;; *) echo "$output"; return 1 ;; esac
  run python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import transcriptlib as tl
assert tl.seam_allowed(Path(sys.argv[2])), "a fixture home is under the temp directory"
assert not tl.seam_allowed(Path("/opt/somewhere/daedalus")), "a deployment home is not"
print("ok")' "$SRC" "$DAEDALUS_HOME"
  [ "$output" = "ok" ] || { echo "$output"; return 1; }
  # the temp directories are not the caller's to name: TMPDIR/TEMP/TMP pointing at a deployment's parent change nothing
  run env TMPDIR=/opt/somewhere TEMP=/opt/somewhere TMP=/opt/somewhere python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import transcriptlib as tl
assert not tl.seam_allowed(Path("/opt/somewhere/daedalus")), "TMPDIR made a deployment home a temp home"
assert Path("/opt/somewhere").resolve() not in tl.temp_roots()
print("ok")' "$SRC"
  [ "$output" = "ok" ] || { echo "$output"; return 1; }
}

@test "tty_answer refuses inside a detached screen session — two stock commands an agent can run (screen -dm, then screen -X stuff yes) — and under a tmux process it cannot find attached; the seam unset" {
  lease_fixture; probe_script
  run under_named tmux python3 "$BATS_TEST_DIRNAME/fixtures/tty/type-into.py" "yes" "Type it: " -- python3 "$PROBE" "$SRC" "$DAEDALUS_HOME"
  case "$output" in *"NOTAPERSON"*"tmux session with no terminal attached"*) : ;; *) echo "tmux: $output"; return 1 ;; esac
  command -v screen >/dev/null || skip "screen is not installed"
  SCREEN_NAME="daedalus-test-$$-$BATS_TEST_NUMBER-$RANDOM"; out="$BATS_TEST_TMPDIR/screen.out"
  printf '#!/bin/bash\nunset DAEDALUS_TEST_TTY_ANCESTRY\npython3 "%s" "%s" "%s" > "%s.tmp" 2>&1; mv "%s.tmp" "%s"\n' \
    "$PROBE" "$SRC" "$DAEDALUS_HOME" "$out" "$out" "$out" > "$BATS_TEST_TMPDIR/in-screen.sh"
  chmod +x "$BATS_TEST_TMPDIR/in-screen.sh"
  screen -dmS "$SCREEN_NAME" "$BATS_TEST_TMPDIR/in-screen.sh"
  for _ in $(seq 1 50); do
    [ -f "$out" ] && break
    screen -S "$SCREEN_NAME" -p 0 -X stuff $'yes\r' >/dev/null 2>&1 || true
    sleep 0.2
  done
  run cat "$out"
  case "$output" in "NOTAPERSON"*"screen session with no terminal attached"*) : ;; *) echo "screen: $output"; return 1 ;; esac
}

@test "confirm_mode: transcribed by default (the operator's decision, 2026-09-25); tty when configured; anything else is refused by name" {
  lease_fixture
  m() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from pathlib import Path; import transcriptlib as tl
try: print(tl.confirm_mode(Path(sys.argv[2])))
except ValueError as e: print("REFUSED", e)' "$SRC" "$DAEDALUS_HOME"; }
  [ "$(m)" = "transcribed" ]
  printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"; [ "$(m)" = "tty" ]
  sed -i '' 's/confirm: tty/confirm: maybe/' "$DAEDALUS_HOME/config.yaml"
  [ "$(m)" = "REFUSED promote.confirm must be transcribed or tty (got: maybe)" ]
}
