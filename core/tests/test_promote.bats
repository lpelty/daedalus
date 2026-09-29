#!/usr/bin/env bats
# Pins core/promote.sh (spec §7, §11.1 test_promote, §11.3). Never a real claude (the fake on
# PATH answers FAKE_ANSWER); every push goes to the bare origin fixtures.
bats_require_minimum_version 1.5.0
load fixtures/promote/setup.bash
setup() { promote_fixture; }
teardown() { teardown_live; }

@test "prepare: the trial merge of window 02 onto freshly fetched main, gates and the reviewer on exactly that merge, prepared.json, and the decision block — two paragraphs, the first in words only; nothing pushed" {
  work_on_02; CLAUDE_CODE_SESSION_ID=sC bash "$LSH" alias 02 poc-ui >/dev/null
  before="$(origin_main)"
  run --separate-stderr as_prime bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
  [ "${lines[0]}" = "Ready to promote window 02's work (poc-ui) onto main." ]
  [ "${lines[1]}" = 'Window 02: 2 commits — "capture: read error before error_message", "test: error field fallback".' ]
  case "${lines[2]}" in "Tests on the merged result: PASS (1 gate, "*" second"*").") : ;; *) echo "${lines[2]}"; return 1 ;; esac
  [ "${lines[3]}" = "Reviewer on the merged change: STANDS — no high findings." ]
  [ "${lines[4]}" = "Nothing has been pushed. Say yes to push." ]
  pid="$(pj promote_id)"; rid="$(pj run_id)"; m="$(pj merge_sha)"; t="$(pj trunk_sha_at_prepare)"; fp="$(pj fp_merged)"
  case "$pid" in 02-[0-9]*-[0-9]*-[0-9a-f][0-9a-f][0-9a-f]) : ;; *) echo "promote id $pid"; return 1 ;; esac
  case "${lines[5]}" in "For the record: merge commit ${m:0:7} onto trunk ${t:0:7} (origin/main, fetched "[0-9][0-9]:[0-9][0-9]");") : ;; *) echo "${lines[5]}"; return 1 ;; esac
  [ "${lines[6]}" = "evidence run $rid; review vault/evidence/$rid-review.md;" ]
  [ "${lines[7]}" = "fingerprint of what will be pushed ${fp:0:4}…${fp:60:4}; promotion id $pid." ]
  S="$DAEDALUS_HOME/state/promote/$pid/thing"
  [ "$(git -C "$S" rev-parse HEAD)" = "$m" ]; [ "$(git -C "$S" rev-parse HEAD^1)" = "$t" ]
  [ "$t" = "$before" ]; [ "$(git -C "$S" rev-parse HEAD^2)" = "$(pj lease_tip)" ]
  [ "$(pj lease_tip)" = "$(git -C "$W2" rev-parse HEAD)" ]
  [ "$(git -C "$S" log -1 --format=%s)" = "promote: merge lease/02 (window 02, poc-ui) into main ($pid)" ]
  [ "$(origin_main)" = "$before" ]
  python3 - "$DAEDALUS_HOME" "$pid" "$rid" <<'PY'
import json, sys
home, pid, rid = sys.argv[1:4]
p = json.load(open("%s/state/promote/%s/prepared.json" % (home, pid)))
r = json.load(open("%s/state/evidence/%s/run.json" % (home, rid)))
assert p["lease"] == "02" and p["repo"] == "thing" and p["trunk"] == "main" and p["alias"] == "poc-ui", p
assert p["review"]["verdict"] == "STANDS" and p["review"]["fingerprint"] == p["fp_merged"] == r["fingerprint"], (p, r)
assert p["review"]["file"] == "vault/evidence/%s-review.md" % rid and p["review"]["call_id"], p
assert p["prepared_by"]["session_id"] == "sP" and p["prepared_by"]["lease"] == "01", p
assert p["core_tree"] and p["charter_sha"] and p["prepared_at"].endswith("Z") and p["prepared_ts"] > 0, p
assert r["promote_id"] == pid and r["merge_sha"] == p["merge_sha"] and r["lease"] == "02", r
assert r["invoked_by"]["kind"] == "prime-session" and r["invoked_by"]["session_id"] == "sP", r
assert r["promotion"] == {"promote_id": pid, "prepared_at": p["prepared_at"], "review_skipped_reason": None,
                          "skip_transcript_ref": None, "skip_transcript_session_id": None,
                          "overrode_review": None}, r["promotion"]
PY
  grep -q '^mode: promote$' "$DAEDALUS_HOME/vault/evidence/$rid-review.md"
}

@test "the decision paragraph is plain language: no 7-hex token and no 36-character id in it" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | python3 -c 'import re, sys
decision = sys.stdin.read().split("\n\n")[0]
assert not re.search(r"\b[0-9a-f]{7,}\b", decision), decision
assert not re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", decision), decision'
}

@test "who: a Claude Code session bound to window 02 is refused even with DAEDALUS_LEASE=01 set; CLAUDECODE with no session id is refused; neither variable is an operator shell, recorded as such" {
  work_on_02
  run env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sC DAEDALUS_LEASE=01 bash "$PROMOTE" 02
  refused "Only the prime window runs promote. You are window 02; ask the prime (marked prime on the board), or take the pen first."
  run env CLAUDECODE=1 bash "$PROMOTE" 02
  refused "I cannot tell whether it holds the pen"
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
  run bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["invoked_by"]["kind"]=="operator-shell" and r["invoked_by"]["session_id"] is None, r' \
    "$DAEDALUS_HOME/state/evidence/$(pj run_id)/run.json"
}

@test "what: an unknown window, an alias where the number belongs, uncommitted work, commits in two repos and nothing past trunk are each refused before any scratch exists" {
  run as_prime bash "$PROMOTE" 05; refused "No window 05. \`core/lease.sh list\` shows the live ones."
  CLAUDE_CODE_SESSION_ID=sC bash "$LSH" alias 02 poc-ui >/dev/null
  run as_prime bash "$PROMOTE" poc-ui; refused "poc-ui is an alias; window 02 carries it — say \`promote 02\`"
  run as_prime bash "$PROMOTE" 02; refused "Window 02 has no commits that are not already on main. Nothing to promote."
  work_on_02; printf 'dirty\n' >> "$W2/a.txt"
  run as_prime bash "$PROMOTE" 02; refused "Window 02 has uncommitted changes in worktrees/02/thing. Commit them on \`lease/02\` first; promote only merges commits."
  git -C "$W2" checkout -q -- a.txt
  printf 'n\n' >> "$W2/sub/n.txt"; git -C "$W2/sub" commit -q -am "nested work"
  run as_prime bash "$PROMOTE" 02; refused "Window 02 has commits in both thing and thing/sub. v1 promotes one repo per run."
  case "$output" in *"core/lease.sh split 02 --repo sub"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
}

@test "trunk: a target.branch origin does not have, and a nested repo with no origin/HEAD, fail closed" {
  work_on_02
  sed -i '' 's/^  branch: main$/  branch: trunk-x/' "$DAEDALUS_HOME/config.yaml"
  # the window was cut from trunk-x (recorded in its lease file) and origin has no such branch now
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["trunks"]["thing"]="trunk-x"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run as_prime bash "$PROMOTE" 02; refused "Cannot resolve origin/trunk-x:"
  case "$output" in *"Fix config target.branch or the remote; promote did nothing."*) : ;; *) echo "$output"; return 1 ;; esac
  sed -i '' 's/^  branch: trunk-x$/  branch: main/' "$DAEDALUS_HOME/config.yaml"
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["trunks"]["thing"]="main"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  git -C "$T/sub" symbolic-ref --delete refs/remotes/origin/HEAD
  run as_prime bash "$PROMOTE" 02; refused "nested repo sub has no origin/HEAD; run \`git -C target/thing/sub remote set-head origin -a\` and try again."
}

@test "trunk: the window's recorded trunks are what promote merges onto; config target.branch or a nested origin/HEAD moved since the window was cut is refused naming both, before any scratch" {
  work_on_02
  git -C "$BATS_TEST_TMPDIR/origin.git" branch dev main
  sed -i '' 's/^  branch: main$/  branch: dev/' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02
  refused "Window 02 was cut from main in thing, but config target.branch now says dev."
  case "$output" in *"lease.sh rebase"*"main"*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(ls -d "$DAEDALUS_HOME"/state/promote/*/ 2>/dev/null)" ]
  [ "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse dev)" = "$(origin_main)" ]
  sed -i '' 's/^  branch: dev$/  branch: main/' "$DAEDALUS_HOME/config.yaml"
  git -C "$BATS_TEST_TMPDIR/sub-origin.git" branch other main
  git -C "$T/sub" fetch -q origin
  git -C "$T/sub" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/other
  run as_prime bash "$PROMOTE" 02
  refused "Window 02 was cut from main in thing/sub, but that repo's origin/HEAD now points at other."
  [ -z "$(ls -d "$DAEDALUS_HOME"/state/promote/*/ 2>/dev/null)" ]
  git -C "$T/sub" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj trunk)" = "main" ]
}

@test "a merge conflict stops the prepare naming the paths and the rebase route, and removes the scratch" {
  printf 'window\n' >> "$W2/a.txt"; git -C "$W2" commit -q -am "window edits a.txt"
  trunk_moves a.txt "trunk edits a.txt"
  run as_prime bash "$PROMOTE" 02
  refused "Window 02's work does not merge cleanly onto current main (conflicts in: a.txt). Tell window 02 to bring its work up to date with main; then run promote again."
  [ -z "$(ls -d "$DAEDALUS_HOME"/state/promote/*/thing 2>/dev/null)" ]
  [ -z "$(git -C "$T" worktree list --porcelain | grep state/promote)" ]
}

@test "a null fingerprint of the merged tree, gates that FAIL, and gates that are INVALID stop the prepare with their sentences; the scratch is kept for inspection" {
  work_on_02
  python3 - "$DAEDALUS_HOME/config.yaml" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("  nested: sub=", "  fingerprint_exclude: ../x\n  nested: sub=", 1))
PY
  run as_prime bash "$PROMOTE" 02; refused "Could not fingerprint the merged tree (fingerprint: config target.fingerprint_exclude: path ../x must stay inside the target checkout); promote did nothing."
  sed -i '' '/fingerprint_exclude/d' "$DAEDALUS_HOME/config.yaml"
  sed -i '' 's/^  - true$/  - false/' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; refused "Gates FAIL on the merged tree (gate 1: \`false\` exit 1; log at state/evidence/" 1
  case "$output" in *"/gate-1.log). The lease was green on its own branch; the merge with current main is what fails."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -n "$(ls -d "$DAEDALUS_HOME"/state/promote/*/thing 2>/dev/null)" ]
  sed -i '' 's/^  - false$/  - touch made-by-the-gate/' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; refused "Gates were INVALID on the merged tree (the tree changed while the gates ran). An invalid run is not a pass." 1
}

@test "the reviewer: REFUTED writes prepared.json with the verdict, shows the block that says so, names the resume and the written-reason routes, exit 1; a review that cannot complete is not a pass" {
  work_on_02
  export FAKE_ANSWER="### F1 — c.txt:1 — HIGH
What is wrong: a.
How to confirm: b.
### F2 — c.txt:2 — HIGH
What is wrong: c.
How to confirm: d.
VERDICT: REFUTED"
  run as_prime bash "$PROMOTE" 02
  refused "The reviewer REFUTED the merged change (2 HIGH findings; the review is at vault/evidence/$(pj run_id)-review.md)." 1
  case "$output" in *"Reviewer on the merged change: REFUTED — 2 high findings."*"Nothing has been pushed. Ask me to ask the reviewer why, or give a written reason to promote without the review."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"core/call-agent.sh --resume-review 02"*"promote 02 --skip-review --reason"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(pj review.verdict)" = "REFUTED" ]
  export FAKE_ANSWER="F1 — nothing found.
VERDICT: STANDS" FAKE_EXIT=1
  run as_prime bash "$PROMOTE" 02; refused "The review could not be completed (" 1
  case "$output" in *"A missing review is not a pass."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a second prepare of the same change after a REFUTED review says so: the block names the earlier verdict, prepared.json records it (Decision 39)" {
  work_on_02
  FAKE_ANSWER="### F1 — c.txt:1 — HIGH
What is wrong: a.
How to confirm: b.
VERDICT: REFUTED" run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]
  first="$(pj review.call_id)"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Reviewer on the merged change: STANDS"*"An earlier review of this same change REFUTED it (1 high finding); this review STANDS."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(pj earlier_refuted.0.call_id)" = "$first" ]
}

@test "the tree changed while promote was running (a change made during the review) stops the prepare with both fingerprints" {
  work_on_02
  # A loop, not a redirect: sh (POSIX mode) never expands a glob in a redirection target.
  export FAKE_HOOK="for f in $DAEDALUS_HOME/state/promote/*/thing/c.txt; do printf late >> \"\$f\"; done"
  run as_prime bash "$PROMOTE" 02
  refused "The tree changed while promote was running (fingerprint before "
  case "$output" in *"Run promote again. Nothing was pushed."*) : ;; *) echo "$output"; return 1 ;; esac
  [ -z "$(prepared)" ]
}

@test "modified distribution code: promote refuses before anything runs — the checker itself included" {
  work_on_02; printf '# local\n' >> "$DAEDALUS_HOME/core/lib.sh"
  run as_prime bash "$PROMOTE" 02
  refused "Distribution code is modified (core/lib.sh); restore it before a review or a promote runs."
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
  git -C "$DAEDALUS_HOME" checkout -q -- core/lib.sh
  printf 'import sys\nsys.exit(0)\n' > "$DAEDALUS_HOME/core/distcheck.py"
  run as_prime bash "$PROMOTE" 02
  refused "Distribution code is modified (core/distcheck.py); restore it before a review or a promote runs."
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
}

@test "the nested case: commits only in window 02's nested repo merge in the nested scratch; the outer scratch sits at its trunk; the fingerprint spans both; run.json carries the nested pair" {
  printf 'n\n' >> "$W2/sub/n.txt"; git -C "$W2/sub" commit -q -am "nested work"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pid="$(pj promote_id)"; S="$DAEDALUS_HOME/state/promote/$pid/thing"
  [ "$(pj repo)" = "thing/sub" ]
  [ "$(git -C "$S" rev-parse HEAD)" = "$(git -C "$T" rev-parse origin/main)" ]
  [ "$(git -C "$S/sub" rev-parse HEAD)" = "$(pj merge_sha)" ]
  [ "$(git -C "$S/sub" rev-parse HEAD^2)" = "$(git -C "$W2/sub" rev-parse HEAD)" ]
  [ "$(pj fp_merged)" != "null" ]
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); n=r["nested"]["sub"]; assert r["merge_sha"]==r["trunk_sha_at_prepare"] and n["merge_sha"]==sys.argv[2], r' \
    "$DAEDALUS_HOME/state/evidence/$(pj run_id)/run.json" "$(pj merge_sha)"
}

@test "git lock contention: a lock error is retried and the prepare goes on; four in a row is 'promote did nothing'" {
  work_on_02; export REAL_GIT="$(command -v git)"
  run env PATH="$BATS_TEST_DIRNAME/fixtures/promote/bin:$PATH" FAKE_GIT_LOCK_FAILS=1 CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sP bash "$PROMOTE" 02
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rm -f "$BATS_TEST_TMPDIR/git-lock-fails"
  run env PATH="$BATS_TEST_DIRNAME/fixtures/promote/bin:$PATH" FAKE_GIT_LOCK_FAILS=4 CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sP bash "$PROMOTE" 02
  refused "promote did nothing — git could not take a lock in the target (error: cannot lock ref"
  case "$output" in *"another session is mid-operation, run promote again."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "on a deployment where a promote is a release, the first line says so — naming the deployment's own update command when config gives one" {
  work_on_02
  printf 'promote:\n  release_note: true\n' >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Ready to promote window 02's work onto main — this is a release: the next update ships it." ]
  printf "  update_command: 'tool update'\n" >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Ready to promote window 02's work onto main — this is a release: the next \`tool update\` ships it." ]
}

@test "--clean removes window 02's promote scratch worktrees and keeps the records; a new prepare replaces the old scratch" {
  work_on_02; sed -i '' 's/^  - true$/  - false/' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]
  first="$(ls "$DAEDALUS_HOME/state/promote")"; [ -d "$DAEDALUS_HOME/state/promote/$first/thing" ]
  sed -i '' 's/^  - false$/  - true/' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -d "$DAEDALUS_HOME/state/promote/$first/thing" ]; [ -f "$DAEDALUS_HOME/state/promote/$first/context.json" ]
  second="$(pj promote_id)"
  run as_prime bash "$PROMOTE" 02 --clean; [ "$status" -eq 0 ]
  [ "$output" = "Removed the promote scratch of window 02 ($second); the promotion records are kept." ]
  [ ! -d "$DAEDALUS_HOME/state/promote/$second/thing" ]; [ -f "$DAEDALUS_HOME/state/promote/$second/prepared.json" ]
  [ -z "$(git -C "$T" worktree list --porcelain | grep state/promote)" ]
  run as_prime bash "$PROMOTE" 02 --clean; [ "$output" = "Window 02 has no promote scratch to remove." ]
}

@test "--clean uses the trunks window 02's lease recorded: a trunk moved since the window was cut does not stop the scratch going; a clone session is refused --clean" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pid="$(pj promote_id)"; [ -d "$DAEDALUS_HOME/state/promote/$pid/thing" ]
  git -C "$BATS_TEST_TMPDIR/origin.git" branch dev main
  sed -i '' 's/^  branch: main$/  branch: dev/' "$DAEDALUS_HOME/config.yaml"
  run env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sC bash "$PROMOTE" 02 --clean
  refused "Only the prime window runs promote."
  [ -d "$DAEDALUS_HOME/state/promote/$pid/thing" ]
  run as_prime bash "$PROMOTE" 02 --clean; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "Removed the promote scratch of window 02 ($pid); the promotion records are kept." ]
  [ ! -d "$DAEDALUS_HOME/state/promote/$pid/thing" ]; [ -f "$DAEDALUS_HOME/state/promote/$pid/prepared.json" ]
  [ -z "$(git -C "$T" worktree list --porcelain | grep state/promote)" ]
}

@test "config.example.yaml carries a promote: block — confirm transcribed by default, the release lines commented out" {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  [ "$(DAEDALUS_CONFIG="$R/config.example.yaml" bash -c 'source "$1/core/lib.sh"; cfg promote.confirm' _ "$R")" = "transcribed" ]
  grep -q '^  # release_note: true$' "$R/config.example.yaml"
  grep -q "^  # update_command: " "$R/config.example.yaml"
  grep -q "^  # tty_parents: " "$R/config.example.yaml"
}

@test "confirm (transcribed): the operator's words, typed after the block was shown, are recorded; exactly the tested merge is pushed; the target is brought forward; the marker, the lease, the evidence and the ledger say so" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(pj merge_sha)"; rid="$(pj run_id)"; pid="$(pj promote_id)"
  shown_then_said "Yes, push it."; said="$SAID"
  run --separate-stderr as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes, push it"
  [ "$status" -eq 0 ] || { echo "$output / $stderr"; return 1; }
  case "$output" in *"Promoted window 02's work to main (merge commit ${m:0:7}; evidence $rid). The window's worktree is still there; say \"release window 2\" when you are done with it, or keep working — the next promote takes only what is new."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(origin_main)" = "$m" ]
  [ "$(git -C "$T" rev-parse HEAD)" = "$m" ]
  python3 - "$DAEDALUS_HOME" "$pid" "$rid" "$m" "$said" "$SHOWN" <<'PY'
import json, sys
home, pid, rid, m, said, shown = sys.argv[1:7]
r = json.load(open("%s/state/evidence/%s/run.json" % (home, rid)))["promotion"]
# The quote is the operator's own turn from the transcript; the agent's transcription is kept beside it.
assert r["confirm_mode"] == "transcribed" and r["operator_said"] == "Yes, push it." and r["confirmed_at"], r
assert r["operator_said_as_transcribed"] == "yes, push it", r
assert r["confirmed_by"]["session_id"] == "sP" and r["transcript_session_id"] == "sP", r
assert r["transcript_ref"]["uuid"] == said and r["shown_ref"]["uuid"] == shown, r
p = json.load(open("%s/state/promote/%s/prepared.json" % (home, pid)))
assert p["confirmed_at"] == r["confirmed_at"], p
s = json.load(open("%s/state/promote/%s/pushed" % (home, pid)))
assert s["merge_sha"] == m and s["confirm_mode"] == "transcribed" and s["tty"] is None, s
mk = json.load(open("%s/state/session-sP.json" % home))
assert mk["target_base"] == m and mk["promotions"][-1]["id"] == pid and mk["promotions"][-1]["sha"] == m, mk
assert pid in json.load(open("%s/state/leases/02.json" % home))["promoted"]
PY
  grep -qE "^Promoted to main at [0-9][0-9]:[0-9][0-9] after the operator said: \"Yes, push it.\"$" "$DAEDALUS_HOME/vault/evidence/$rid.md"
  L="$DAEDALUS_HOME/vault/evidence/promotions.log"; [ "$(wc -l < "$L" | tr -d ' ')" = 1 ]
  for f in "window 02" "merge $m" "run $rid" "STANDS (review " 'operator: "Yes, push it."' "confirm: transcribed"; do grep -qF -- "$f" "$L" || { echo "ledger lacks $f: $(cat "$L")"; return 1; }; done
  grep -qxF "$L" "$DAEDALUS_HOME/vault/evidence/.manifest"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes, push it"; refused "was already pushed"
}

@test "confirm leaves a target checkout that is not on trunk alone: the trunk ref moves, the branch does not" {
  work_on_02; git -C "$T" switch -q -c other
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]
  m="$(pj merge_sha)"; shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing is on other; the trunk ref is updated, the checkout is untouched."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse origin/main)" = "$m" ]; [ "$(git -C "$T" rev-parse HEAD)" != "$m" ]
}

@test "the transcribed yes, refused: empty; not a yes; not in the transcript; a fragment of a longer turn; only in a tool result; only before the block; with no assistant turn between, or only one that is not the block; an unreadable transcript (naming tty); no transcript at all; from an operator shell — and nothing is pushed" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; before="$(origin_main)"; P="$(pj prepared_ts)"
  B="Ready to promote window 02's work onto main."
  c() { run as_prime bash "$PROMOTE" 02 --confirm --operator-said "$1"; }
  c ""; refused "Record what the operator said. The yes is evidence; an empty one is not a yes."
  tx "$TXP" assistant "$B" "$(plus "$P" 1)" >/dev/null
  tx "$TXP" operator "No, wait — what did the reviewer say about F2?" "$(plus "$P" 2)" >/dev/null
  c "No, wait"; refused "The operator's words do not begin with yes (got: \"No, wait\")."
  c "yes ship it"; refused "I could not find those words as something the operator typed after the promote block was shown."
  tx "$TXP" operator "yes, but first tell me about F2" "$(plus "$P" 3)" >/dev/null
  c "yes"; refused "I could not find those words as something the operator typed after the promote block was shown."
  : > "$TXP"; tx "$TXP" tool-result "yes ship it" "$(plus "$P" 1)" >/dev/null; tx "$TXP" assistant "$B" "$(plus "$P" 2)" >/dev/null
  c "yes ship it"; refused "I could not find those words as something the operator typed after the promote block was shown."
  : > "$TXP"; tx "$TXP" operator "yes ship it" "$(plus "$P" -30)" >/dev/null; tx "$TXP" assistant "$B" "$(plus "$P" 2)" >/dev/null
  c "yes ship it"; refused "I could not find those words as something the operator typed after the promote block was shown."
  : > "$TXP"; tx "$TXP" tool-result "prepared" "$(plus "$P" 1)" >/dev/null; tx "$TXP" operator "yes ship it" "$(plus "$P" 2)" >/dev/null
  c "yes ship it"; refused "The promote block was not shown to the operator before that yes (prepare and confirm ran in one turn, no reply since the prepare repeated the block, or the operator's reply to it came before that yes). Show the block, then ask."
  : > "$TXP"; tx "$TXP" assistant "Shall I go ahead?" "$(plus "$P" 1)" >/dev/null; tx "$TXP" operator "yes ship it" "$(plus "$P" 2)" >/dev/null
  c "yes ship it"; refused "The promote block was not shown to the operator before that yes"
  tx "$TXP" assistant "$B" "$(plus "$P" 3)" >/dev/null; tx "$TXP" malformed "x" "$(plus "$P" 4)" >/dev/null; tx "$TXP" operator "yes ship it" "$(plus "$P" 5)" >/dev/null
  c "yes ship it"; refused "I cannot read this build's transcript format ("
  case "$output" in *"set \`promote.confirm: tty\` and paste the confirm line in your own shell. Nothing was pushed."*) : ;; *) echo "$output"; return 1 ;; esac
  rm -f "$TXP"
  c "yes ship it"; refused "I cannot find this session's transcript ("
  run bash "$PROMOTE" 02 --confirm --operator-said "yes ship it"
  refused "In transcribed mode the prime window records the operator's yes; from a shell, set \`promote.confirm: tty\` and run the confirm there."
  [ "$(origin_main)" = "$before" ]; [ ! -f "$(dirname "$(prepared)")/pushed" ]
}

@test "which promotion: none prepared; an --id prepared for another window" {
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "No prepared promotion for window 02; run \`promote 02\` first."
  work_on_02; run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]
  run as_prime bash "$PROMOTE" 01 --confirm --operator-said "yes" --id "$(pj promote_id)"; refused "was prepared for window 02, not window 01."
}

@test "evidence, re-derived: a REFUTED prepare is refused even with prepared.json edited to STANDS; a review whose request-sha is not the re-render's; a review of other distribution code; modified distribution code" {
  work_on_02
  FAKE_ANSWER="### F1 — c.txt:1 — HIGH
What is wrong: a.
How to confirm: b.
VERDICT: REFUTED" run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (review verdict)."
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["review"]["verdict"]="STANDS"; json.dump(p, open(sys.argv[1],"w"))' "$(prepared)"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (review verdict)."
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; rid="$(pj run_id)"; shown_then_said "yes"
  sed -i '' 's/^request-sha: .*/request-sha: 0000000000000000000000000000000000000000000000000000000000000000/' "$DAEDALUS_HOME/vault/evidence/$rid-review.md"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "The review did not see the change that will be pushed."
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; shown_then_said "yes"
  printf '# a later commit\n' >> "$DAEDALUS_HOME/core/refute-pitfalls.py"; git -C "$DAEDALUS_HOME" commit -qam "later"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Distribution code changed since the review."
  printf '# dirty\n' >> "$DAEDALUS_HOME/core/lib.sh"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Distribution code is modified (core/lib.sh)"
}

@test "evidence, re-derived: trunk moved since the trial merge; the window's branch gained a commit after it (named by subject)" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; t="$(pj trunk_sha_at_prepare)"; shown_then_said "yes"
  trunk_moves b.txt "elsewhere"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Trunk moved since the trial merge (was ${t:0:7}, now "
  case "$output" in *"The tested merge is stale. Run \`promote 02\` again. Nothing was pushed."*) : ;; *) echo "$output"; return 1 ;; esac
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; shown_then_said "yes"
  printf 't\n' >> "$W2/c.txt"; git -C "$W2" commit -q -am "fix typo"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "branch changed after the trial merge — 1 new commit: \"fix typo\"."
}

@test "a push rejected because trunk moved during confirm changes nothing on origin, and marks the promotion so the hook refuses it from then on" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; shown_then_said "yes"
  O="$BATS_TEST_TMPDIR/origin.git"; R="$BATS_TEST_TMPDIR/racer"
  export PROMOTE_TEST_BEFORE_PUSH="git clone -q '$O' '$R' && cd '$R' && echo r >> b.txt && git add -A && git -c user.email=t@x -c user.name=t commit -qm race && git push -q origin HEAD:main"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Push rejected: trunk moved during confirm. Run promote again."
  case "$output" in *"Nothing changed on origin."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$O" log -1 --format=%s main)" = "race" ]; [ "$(origin_main)" != "$m" ]
  [ -n "$(pj push_failed_at)" ]
  unset PROMOTE_TEST_BEFORE_PUSH
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "already failed to push"
  [ "$(git -C "$O" log -1 --format=%s main)" = "race" ]
}

@test "the cut-off is the latest of the primaries: prepared.json's time lowered below an earlier yes does not let that yes count (Decision 35)" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; P="$(pj prepared_ts)"; m="$(pj merge_sha)"
  tx "$TXP" assistant "Ready to promote window 02's work onto main." "$(plus "$P" -120)" >/dev/null
  tx "$TXP" operator "yes" "$(plus "$P" -110)" >/dev/null
  setp() { python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p["prepared_ts"]=float(sys.argv[2]); json.dump(p, open(sys.argv[1],"w"))' "$(prepared)" "$1"; }
  setp "$(plus "$P" -200)"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  refused "Evidence disagrees with the prepared promotion (the prepared time is earlier than the merge commit)."
  setp "$(git -C "$T" show -s --format=%ct "$m")"   # the scratch is a worktree of target/thing: one object store
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  refused "I could not find those words as something the operator typed after the promote block was shown."
}

@test "the scratch must still be the merge commit at confirm: a commit made in it, which leaves the fingerprint unchanged, is refused (Decision 37)" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; shown_then_said "yes"
  S="$DAEDALUS_HOME/state/promote/$(pj promote_id)/thing"
  git -C "$S" -c user.email=t@x -c user.name=t commit -q --allow-empty -m "same tree"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  refused "Evidence disagrees with the prepared promotion (the scratch is not the merge commit)."
}

@test "the nested case, confirmed: the push goes to the nested repo's origin; the outer origin is untouched; the marker's trunk base is the outer repo's and stays" {
  printf 'n\n' >> "$W2/sub/n.txt"; git -C "$W2/sub" commit -q -am "nested work"
  outer_before="$(origin_main)"; base_before="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["target_base"])' "$DAEDALUS_HOME/state/session-sP.json")"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$BATS_TEST_TMPDIR/sub-origin.git" rev-parse main)" = "$m" ]; [ "$(origin_main)" = "$outer_before" ]
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["target_base"]==sys.argv[2] and m["promotions"][-1]["sha"]==sys.argv[3], m' \
    "$DAEDALUS_HOME/state/session-sP.json" "$base_before" "$m"
}

@test "tty mode from a session with no terminal: --operator-said is refused; the confirm hands over the paste line and pushes nothing" {
  work_on_02; printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; before="$(origin_main)"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "In tty mode the operator types the yes in a terminal; --operator-said is not accepted."
  run no_tty env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sP bash "$PROMOTE" 02 --confirm
  refused "The confirm must be typed by a person in a terminal. This session has none. Paste this line in your own shell: \`cd $DAEDALUS_HOME && core/promote.sh 02 --confirm\`"
  [ "$(origin_main)" = "$before" ]
}

# jedit <json file> <python statement on d> — edit one field of a record in place.
jedit() { python3 -c 'import json,sys
d = json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(d, open(sys.argv[1], "w"))' "$1" "$2"; }
# ledger_lines — how many lines promotions.log holds (one per promotion, §7.2 step 4).
ledger_lines() { wc -l < "$DAEDALUS_HOME/vault/evidence/promotions.log" | tr -d ' '; }

@test "a failure after the push is a note, never 'Nothing was pushed.': a stale index.lock in target/thing leaves its checkout behind; the stamp, the lease and the marker are still written; a second confirm says already pushed" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; pid="$(pj promote_id)"; shown_then_said "yes"
  export PROMOTE_TEST_BEFORE_PUSH="touch '$T/.git/index.lock'"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Nothing was pushed."*|*"Nothing changed on origin."*) echo "$output"; return 1 ;; esac
  case "$output" in *"target/thing could not be fast-forwarded ("*"the trunk ref is updated, the checkout is untouched."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Promoted window 02's work to main (merge commit ${m:0:7}; evidence "*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(origin_main)" = "$m" ]; [ "$(git -C "$T" rev-parse HEAD)" != "$m" ]
  python3 - "$DAEDALUS_HOME" "$pid" "$m" <<'PY'
import json, sys
home, pid, m = sys.argv[1:4]
assert json.load(open("%s/state/promote/%s/pushed" % (home, pid)))["merge_sha"] == m
assert json.load(open("%s/state/leases/02.json" % home))["promoted"] == [pid]
mk = json.load(open("%s/state/session-sP.json" % home))
assert mk["target_base"] == m and [x["id"] for x in mk["promotions"]] == [pid], mk
PY
  rm -f "$T/.git/index.lock"; unset PROMOTE_TEST_BEFORE_PUSH
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "was already pushed"
  [ "$(ledger_lines)" = 1 ]
}

@test "two confirms of one promotion at once: the second is refused while the first holds it; one ledger line, one promoted entry, one marker entry" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; pid="$(pj promote_id)"; shown_then_said "yes"
  F="$BATS_TEST_TMPDIR/in-push"
  PROMOTE_TEST_BEFORE_PUSH="touch '$F'; sleep 3" as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes" \
    > "$BATS_TEST_TMPDIR/first.out" 2>&1 3>&- &
  first=$!
  for _ in $(seq 150); do [ -f "$F" ] && break; sleep 0.1; done; [ -f "$F" ]
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  refused "Promotion $pid of window 02 is being confirmed by another process."
  wait "$first" || { cat "$BATS_TEST_TMPDIR/first.out"; return 1; }
  grep -q "Promoted window 02's work to main (merge commit ${m:0:7}" "$BATS_TEST_TMPDIR/first.out"
  [ "$(origin_main)" = "$m" ]; [ "$(ledger_lines)" = 1 ]
  python3 - "$DAEDALUS_HOME" "$pid" <<'PY'
import json, sys
home, pid = sys.argv[1:3]
assert json.load(open("%s/state/leases/02.json" % home))["promoted"] == [pid]
assert [x["id"] for x in json.load(open("%s/state/session-sP.json" % home))["promotions"]] == [pid]
PY
}

@test "confirm takes the trunk, the repo, the review's call id, the override and the earlier refutations from their primaries, not from prepared.json" {
  work_on_02
  git -C "$BATS_TEST_TMPDIR/origin.git" branch release main
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; P="$(prepared)"; cp "$P" "$P.orig"
  shown_then_said "yes" "Ready to promote window 02's work onto release."
  jedit "$P" 'd["trunk"] = "release"'
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the repo or the trunk)."
  [ "$(git -C "$BATS_TEST_TMPDIR/origin.git" rev-parse release)" != "$m" ]
  cp "$P.orig" "$P"; C="$(dirname "$P")/context.json"; cp "$C" "$C.orig"
  jedit "$C" 'd["repo"] = "thing/sub"'
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the repo or the trunk)."
  cp "$C.orig" "$C"
  jedit "$P" 'd["review"]["call_id"] = "FORGED"'
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the review's call id)."
  cp "$P.orig" "$P"; jedit "$P" 'd["overrode_review"] = {"call_id": "FORGED"}'
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the review it sets aside)."
  cp "$P.orig" "$P"
  [ "$(origin_main)" != "$m" ]
}

@test "the ledger names an earlier REFUTED review of the same change even when prepared.json's list was emptied, and the review's call id from its own frontmatter" {
  work_on_02
  FAKE_ANSWER="### F1 — c.txt:1 — HIGH
What is wrong: a.
How to confirm: b.
VERDICT: REFUTED" run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]; refuted_call="$(pj review.call_id)"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; rid="$(pj run_id)"; call="$(pj review.call_id)"
  jedit "$(prepared)" 'd["earlier_refuted"] = []'
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  L="$DAEDALUS_HOME/vault/evidence/promotions.log"
  grep -qF "STANDS (review $call)" "$L"; grep -qF "earlier refuted: $refuted_call" "$L" || { cat "$L"; return 1; }
}

@test "evidence, re-derived: the gate run's record — result, refuter, fingerprint — each checked" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; rid="$(pj run_id)"; shown_then_said "yes"
  R="$DAEDALUS_HOME/state/evidence/$rid/run.json"; cp "$R" "$R.orig"
  for e in 'd["result"] = "FAIL"' 'd["refuter"] = "STANDS"' 'd["fingerprint"] = None' 'd["promote_id"] = "02-x"'; do
    cp "$R.orig" "$R"; jedit "$R" "$e"
    run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the gate run's record)." || { echo "edit: $e"; return 1; }
  done
  [ "$(origin_main)" != "$m" ]
}

@test "evidence, re-derived: the review's receipt — the first attempt's exit code, the advisory flag, the answer file, the receipt's core tree — and the charter the review names" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; rid="$(pj run_id)"; call="$(pj review.call_id)"; shown_then_said "yes"
  J="$DAEDALUS_HOME/state/direct-calls/$call/launch.json"; cp "$J" "$J.orig"
  A="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["attempts"][0]["answer"])' "$J")"; cp "$A" "$A.orig"
  for e in 'd["attempts"][0]["exit_code"] = 1' 'd["attempts"][0]["advisory"] = True' 'd["core_tree"] = "0" * 40'; do
    cp "$J.orig" "$J"; jedit "$J" "$e"
    run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the review's receipt and the review)." || { echo "edit: $e"; return 1; }
  done
  cp "$J.orig" "$J"; printf 'and one more line\n' >> "$A"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the review's receipt and the review)."
  cp "$A.orig" "$A"
  # The charter is under core/, so a committed change to it moves the core tree too; the review's own
  # record of the charter is what this checks.
  V="$DAEDALUS_HOME/vault/evidence/$rid-review.md"
  sed -i '' 's/^charter-sha: .*/charter-sha: 0000000000000000000000000000000000000000/' "$V"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Distribution code changed since the review."
  [ "$(origin_main)" != "$m" ]
}

@test "evidence, re-derived: prepared.json's fingerprint is the scratch's; a merge commit with the same tree whose parents are not trunk then the window's tip is refused" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; t="$(pj trunk_sha_at_prepare)"; tip="$(pj lease_tip)"
  rid="$(pj run_id)"; call="$(pj review.call_id)"; P="$(prepared)"; cp "$P" "$P.orig"; shown_then_said "yes"
  jedit "$P" 'd["fp_merged"] = "0" * 64'
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the fingerprint of the scratch)."
  cp "$P.orig" "$P"
  # The same tree, the parents swapped; every record re-pointed at it, the review's render re-signed.
  S="$DAEDALUS_HOME/state/promote/$(pj promote_id)/thing"; when="$(git -C "$S" show -s --format=%cI "$m")"
  m2="$(GIT_COMMITTER_DATE="$when" GIT_AUTHOR_DATE="$when" git -C "$S" commit-tree "$m^{tree}" -p "$tip" -p "$t" -m swapped)"
  R="$DAEDALUS_HOME/state/evidence/$rid/run.json"
  for f in "$P" "$R" "$(dirname "$P")/context.json"; do jedit "$f" "d['merge_sha'] = '$m2'"; done
  sha="$(as_prime env DAEDALUS_TARGET_OVERRIDE="$S" bash "$DAEDALUS_HOME/core/refute.sh" "$rid" --mode promote --render-only | shasum -a 256 | cut -d' ' -f1)"
  sed -i '' "s/^request-sha: .*/request-sha: $sha/" "$DAEDALUS_HOME/vault/evidence/$rid-review.md"
  jedit "$DAEDALUS_HOME/state/direct-calls/$call/launch.json" "d['request_sha256'] = '$sha'"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; refused "Evidence disagrees with the prepared promotion (the merge commit's parents)."
  [ "$(origin_main)" = "$t" ]
}

@test "confirm fast-forwards the target only when it is clean: target/thing on main with an uncommitted change keeps its checkout" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; m="$(pj merge_sha)"; shown_then_said "yes"
  printf 'local\n' >> "$T/a.txt"; before="$(git -C "$T" rev-parse HEAD)"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing has uncommitted changes; the trunk ref is updated, the checkout is untouched."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse HEAD)" = "$before" ]; [ "$(git -C "$T" rev-parse origin/main)" = "$m" ]
}

@test "the recorded quote is the operator's own turn, and one line: an agent's reshaped --operator-said with a newline and a tab neither replaces it nor splits the ledger or the summary" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; rid="$(pj run_id)"
  shown_then_said $'Yes,\npush\tit.'
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said $'YES,\npush\tit'; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(ledger_lines)" = 1 ]
  L="$DAEDALUS_HOME/vault/evidence/promotions.log"
  grep -qF 'operator: "Yes, push it."' "$L" || { cat "$L"; return 1; }
  [ "$(awk -F'\t' '{print NF}' "$L")" = 7 ]
  grep -qE "^Promoted to main at [0-9][0-9]:[0-9][0-9] after the operator said: \"Yes, push it.\"$" "$DAEDALUS_HOME/vault/evidence/$rid.md"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["promotion"]; assert r["operator_said"]=="Yes,\npush\tit." and r["operator_said_as_transcribed"]=="YES,\npush\tit", r' \
    "$DAEDALUS_HOME/state/evidence/$rid/run.json"
}

@test "tty mode, end to end: typed yes at a terminal in an operator shell with windows open pushes; the pushed stamp names the terminal; marker, lease and ledger are done before any hook runs; the prime's next prompt announces it once" {
  work_on_02; printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(pj merge_sha)"; pid="$(pj promote_id)"
  run type_into "yes" "Type yes to push" bash "$PROMOTE" 02 --confirm
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Ready to promote window 02's work onto main."*"Type yes to push window 02's work to main: "*"Promoted window 02's work to main (merge commit ${m:0:7};"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(origin_main)" = "$m" ]
  python3 - "$DAEDALUS_HOME" "$pid" "$m" "$(pj run_id)" <<'PY'
import json, sys
home, pid, m, rid = sys.argv[1:5]
s = json.load(open("%s/state/promote/%s/pushed" % (home, pid)))
assert s["confirm_mode"] == "tty" and s["tty"].startswith("/dev/") and s["merge_sha"] == m, s
assert json.load(open("%s/state/session-sP.json" % home))["target_base"] == m
assert pid in json.load(open("%s/state/leases/02.json" % home))["promoted"]
r = json.load(open("%s/state/evidence/%s/run.json" % (home, rid)))["promotion"]
assert r["confirm_mode"] == "tty" and r["typed"]["text"] == "yes" and r["confirmed_by"]["session_id"] is None, r
PY
  grep -qF "confirm: tty" "$DAEDALUS_HOME/vault/evidence/promotions.log"
  board() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s"}' "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py"; }
  out="$(board sC)"; case "$out" in *"was confirmed and pushed from your shell"*) echo "announced to the wrong window: $out"; return 1 ;; esac
  out="$(board sP)"
  case "$out" in *"Promotion of window 02's work was confirmed and pushed from your shell at "[0-9][0-9]:[0-9][0-9]" (merge ${m:0:7}); your checkout and marker are already brought forward"*) : ;; *) echo "$out"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/promote/$pid/announced" ]; [ ! -f "$DAEDALUS_HOME/state/promote/$pid/pushed" ]
  out="$(board sP)"; case "$out" in *"pushed from your shell"*) echo "announced twice: $out"; return 1 ;; esac
}

@test "tty mode: the prime's announcement says what the confirm could not finish (a dirty target/thing keeps its checkout), never that the checkout was brought forward; a stamp whose confirm has not finished is not announced yet" {
  work_on_02; printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(pj merge_sha)"; pid="$(pj promote_id)"; S="$DAEDALUS_HOME/state/promote/$pid/pushed"
  printf 'local\n' >> "$T/a.txt"; before="$(git -C "$T" rev-parse HEAD)"
  run type_into "yes" "Type yes to push" bash "$PROMOTE" 02 --confirm
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"target/thing has uncommitted changes; the trunk ref is updated, the checkout is untouched."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$T" rev-parse HEAD)" = "$before" ]; [ "$(origin_main)" = "$m" ]
  board() { printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s"}' "$1" | python3 "$DAEDALUS_HOME/core/lease-board.py"; }
  # a prompt that lands while the confirm is still finishing: the stamp is written, the follow-ups are not
  cp "$S" "$S.done"; jedit "$S" "d.pop('finished_at', None); d.pop('followups', None)"
  out="$(board sP)"; case "$out" in *"pushed from your shell"*) echo "announced before the confirm finished: $out"; return 1 ;; esac
  [ -f "$S" ]; mv "$S.done" "$S"
  out="$(board sP)"
  case "$out" in *"already brought forward"*) echo "claimed the checkout was brought forward: $out"; return 1 ;; esac
  case "$out" in *"Promotion of window 02's work was confirmed and pushed from your shell at "[0-9][0-9]:[0-9][0-9]" (merge ${m:0:7})"*"target/thing has uncommitted changes; the trunk ref is updated, the checkout is untouched."*) : ;; *) echo "$out"; return 1 ;; esac
  [ -f "$DAEDALUS_HOME/state/promote/$pid/announced" ]; [ ! -f "$S" ]
}

@test "tty mode: anything but yes at the terminal pushes nothing; a transcribed confirm's stamp is never announced as pushed from a shell" {
  work_on_02; printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ]; before="$(origin_main)"
  run type_into "not yet" "Type yes to push" bash "$PROMOTE" 02 --confirm
  [ "$status" -eq 2 ]; case "$output" in *"The operator did not say yes (typed: \"not yet\"). Nothing was pushed."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(origin_main)" = "$before" ]
  sed -i '' 's/^  confirm: tty$/  confirm: transcribed/' "$DAEDALUS_HOME/config.yaml"
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  out="$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"sP"}' | python3 "$DAEDALUS_HOME/core/lease-board.py")"
  case "$out" in *"pushed from your shell"*) echo "$out"; return 1 ;; esac
  [ -f "$(dirname "$(prepared)")/pushed" ]
}

REFUTE_ONE="### F1 — c.txt:1 — HIGH
What is wrong: a.
How to confirm: b.
VERDICT: REFUTED"

@test "--skip-review needs --reason with the operator's words, refused before any git work" {
  work_on_02
  run as_prime bash "$PROMOTE" 02 --skip-review; refused "--skip-review needs --reason with the operator's words; a reason is the price of skipping the review."
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "  "; refused "--skip-review needs --reason"
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
}

@test "--skip-review over a REFUTED review: the reason typed only before that review was shown, not at all, as a fragment, in too few words, or after a reply that did not show the verdict is refused; typed after it, the operator's own words are recorded beside the verdict they set aside, no reviewer runs, gates still run, and the confirm's ledger line names the overridden call" {
  work_on_02
  FAKE_ANSWER="$REFUTE_ONE" run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]
  refuted="$(pj review.call_id)"; rrun="$(pj run_id)"; P="$(pj prepared_ts)"; n0="$(calls)"
  why="promote it anyway, F1 is about a test file"; typed="Promote it anyway, F1 is about a test file."
  RL="Reviewer on the merged change: REFUTED — one high finding."
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "$why"
  refused "I could not find those words as something the operator typed after the review was shown."
  tx "$TXP" operator "$why" "$(plus "$P" -30)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "$why"
  refused "I could not find those words as something the operator typed after the review was shown."
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "the"
  refused "at least three words"
  tx "$TXP" assistant "Shall I promote it?" "$(plus "$P" 1)" >/dev/null; tx "$TXP" operator "$typed" "$(plus "$P" 2)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "$why"
  refused "The review was not shown to the operator before those words"
  tx "$TXP" operator "$typed and more" "$(plus "$P" 3)" >/dev/null
  shown_then_said "$typed" "$RL"
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "F1 is about a test file"
  refused "I could not find those words as something the operator typed after the review was shown."
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "$why"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[3]}" = "Reviewer: skipped by the operator because: $typed" ]
  case "$output" in *"review skipped by the operator (it sets aside review $refuted of run $rrun);"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(calls)" = "$n0" ]
  python3 - "$(prepared)" "$DAEDALUS_HOME/state/evidence/$(pj run_id)/run.json" "$SAID" "$refuted" "$rrun" "$typed" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); r = json.load(open(sys.argv[2]))
said, refuted, rrun, typed = sys.argv[3:7]
assert p["review"] is None and p["review_skipped_reason"] == typed, p     # the operator's words, not the flag's
assert p["skip_transcript_ref"]["uuid"] == said and p["overrode_review"] == {"call_id": refuted, "run_id": rrun}, p
assert p["skip_transcript_session_id"] == "sP", p
pr = r["promotion"]
assert pr["review_skipped_reason"] == typed and pr["skip_transcript_ref"] == p["skip_transcript_ref"] and pr["overrode_review"] == p["overrode_review"], pr
assert pr["skip_transcript_session_id"] == "sP", pr
assert r["refuter"] == "deferred-to-promote" and r["result"] == "PASS" and not [k for k in r if k.endswith("reason")], r
PY
  grep -qxF "Review skipped by the operator because: $typed" "$DAEDALUS_HOME/vault/evidence/$(pj run_id).md"
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  L="$DAEDALUS_HOME/vault/evidence/promotions.log"
  grep -qF "skipped: $typed" "$L"; grep -qF "overrode: $refuted" "$L"
  [ "$(origin_main)" = "$(pj merge_sha)" ]
}

@test "confirm re-reads a skip reason from the transcript: a reason edited in run.json, or a ref to an entry the operator did not type, is refused (Decision 31)" {
  work_on_02; now_="$(now)"
  tx "$TXP" assistant "Promote window 02's work without the review? Tell me why in your own words." "$(plus "$now_" -20)" >/dev/null
  tx "$TXP" operator "skip the review, it is a docs change" "$(plus "$now_" -10)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "skip the review, it is a docs change"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  shown_then_said "yes"
  R="$DAEDALUS_HOME/state/evidence/$(pj run_id)/run.json"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["promotion"]["review_skipped_reason"]="something the operator never said"; json.dump(r, open(sys.argv[1],"w"))' "$R"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  refused "Evidence disagrees with the prepared promotion (the reason for skipping the review)."
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["promotion"]["review_skipped_reason"]=sys.argv[3]; r["promotion"]["skip_transcript_ref"]["uuid"]=sys.argv[2]; json.dump(r, open(sys.argv[1],"w"))' "$R" "$SHOWN" "$(pj review_skipped_reason)"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  refused "Evidence disagrees with the prepared promotion (the reason for skipping the review)."
}

@test "--skip-review with no earlier REFUTED review is allowed with a reason typed since the session started after the prime asked the skip question, and overrides nothing" {
  work_on_02; now_="$(now)"
  tx "$TXP" assistant "Promote window 02's work without the review? Tell me why in your own words." "$(plus "$now_" -20)" >/dev/null
  tx "$TXP" operator "skip the review, it is a docs change" "$(plus "$now_" -10)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "skip the review, it is a docs change"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj overrode_review)" = "None" ]; [ "$(calls)" -eq 0 ]
}

@test "a second --skip-review after trunk moved still sets aside the REFUTED review: a reason typed after only the skip question is refused; typed after the verdict is shown again, the block and the confirm's ledger line name it; and a promotion settles it" {
  work_on_02
  FAKE_ANSWER="$REFUTE_ONE" run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]
  refuted="$(pj review.call_id)"; rrun="$(pj run_id)"
  RL="Reviewer on the merged change: REFUTED — one high finding."
  shown_then_said "promote it anyway, F1 is about a test file" "$RL"
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "promote it anyway, F1 is about a test file"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  trunk_moves b.txt "elsewhere"
  P="$(pj prepared_ts)"; why="same reason as before, really"
  tx "$TXP" assistant "Promote window 02's work without the review? Tell me why in your own words." "$(plus "$P" 1)" >/dev/null
  tx "$TXP" operator "$why" "$(plus "$P" 2)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "$why"
  refused "The review was not shown to the operator before those words"
  tx "$TXP" assistant "$RL" "$(plus "$P" 4)" >/dev/null; tx "$TXP" operator "$why" "$(plus "$P" 5)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "$why"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"review skipped by the operator (it sets aside review $refuted of run $rrun);"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(pj overrode_review.call_id)" = "$refuted" ]; [ "$(pj overrode_review.run_id)" = "$rrun" ]
  shown_then_said "yes"
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  L="$DAEDALUS_HOME/vault/evidence/promotions.log"
  [ "$(tail -1 "$L" | grep -cF "overrode: $refuted")" = 1 ] || { cat "$L"; return 1; }
  [ "$(origin_main)" = "$(pj merge_sha)" ]
  # promoted: the REFUTED review is settled; the next skip on this window sets nothing aside
  printf 'w3\n' >> "$W2/c.txt"; git -C "$W2" commit -q -am "docs: note"
  P="$(pj prepared_ts)"
  tx "$TXP" assistant "Promote window 02's work without the review? Tell me why in your own words." "$(plus "$P" 1)" >/dev/null
  tx "$TXP" operator "a docs-only note, skip it" "$(plus "$P" 2)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "a docs-only note, skip it"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj overrode_review)" = "None" ]
}

@test "a REFUTED review from an earlier window under the same number is not set aside by the new window's skip" {
  work_on_02
  FAKE_ANSWER="$REFUTE_ONE" run as_prime bash "$PROMOTE" 02; [ "$status" -eq 1 ]
  # the window is re-created under the same number (its lease file is a new one)
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["created"]="2099-01-01T00:00:00"; json.dump(d, open(sys.argv[1],"w"))' \
    "$DAEDALUS_HOME/state/leases/02.json"
  P="$(pj prepared_ts)"
  tx "$TXP" assistant "Promote window 02's work without the review? Tell me why in your own words." "$(plus "$P" 1)" >/dev/null
  tx "$TXP" operator "a docs-only change, skip it" "$(plus "$P" 2)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "a docs-only change, skip it"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj overrode_review)" = "None" ]
}

@test "--skip-review with no earlier prepare: words typed before this session's marker started do not count, under any TZ, a marker from an older build counts from its file's time, and no readable marker is refused" {
  work_on_02; M="$DAEDALUS_HOME/state/session-sP.json"
  S="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["started_epoch"])' "$M")"
  tx "$TXP" assistant "Promote window 02's work without the review? Tell me why in your own words." "$(plus "$S" -20)" >/dev/null
  tx "$TXP" operator "skip the review, it is a docs change" "$(plus "$S" -10)" >/dev/null
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "skip the review, it is a docs change"
  refused "I could not find those words as something the operator typed after the review was shown."
  TZ=Etc/GMT-14 run as_prime bash "$PROMOTE" 02 --skip-review --reason "skip the review, it is a docs change"
  refused "I could not find those words as something the operator typed after the review was shown."
  # an older build's marker (no started_epoch) counts from the file's modification time
  python3 - "$M" "$S" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1])); m.pop("started_epoch"); json.dump(m, open(sys.argv[1], "w")); os.utime(sys.argv[1], (float(sys.argv[2]),) * 2)
PY
  TZ=Etc/GMT-14 run as_prime bash "$PROMOTE" 02 --skip-review --reason "skip the review, it is a docs change"
  refused "I could not find those words as something the operator typed after the review was shown."
  rm "$M"
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "skip the review, it is a docs change"
  refused "This session has no start record"
  [ -z "$(ls "$DAEDALUS_HOME/state/promote" 2>/dev/null)" ]
}

@test "--skip-review in tty mode: --reason is refused; the reason typed at a terminal is recorded as typed, and a tty confirm pushes it" {
  work_on_02; printf 'promote:\n  confirm: tty\n' >> "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02 --skip-review --reason "x"; refused "the reason for skipping the review is typed in a terminal"
  run type_into "a docs-only change" "without the review?" bash "$PROMOTE" 02 --skip-review
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj review_skipped_reason)" = "a docs-only change" ]; [ "$(pj skip_typed.text)" = "a docs-only change" ]
  run type_into "yes" "Type yes to push" bash "$PROMOTE" 02 --confirm; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(origin_main)" = "$(pj merge_sha)" ]
}
