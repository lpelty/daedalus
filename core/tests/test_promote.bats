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

@test "config.example.yaml carries a promote: block — confirm transcribed by default, the release lines commented out" {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  [ "$(DAEDALUS_CONFIG="$R/config.example.yaml" bash -c 'source "$1/core/lib.sh"; cfg promote.confirm' _ "$R")" = "transcribed" ]
  grep -q '^  # release_note: true$' "$R/config.example.yaml"
  grep -q "^  # update_command: " "$R/config.example.yaml"
  grep -q "^  # tty_parents: " "$R/config.example.yaml"
}
