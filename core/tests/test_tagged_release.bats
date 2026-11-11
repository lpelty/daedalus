#!/usr/bin/env bats
# Promote as a tagged release (v0.13.0, plan v0130 Task 6): a repo named in promote.tags is released with an
# annotated v<VERSION> tag pushed with the merge. Fixture: test_promote.bats's with the sibling portico, whose
# trunk carries VERSION 0.1.0 (fixtures/leases add_sibling), named in promote.tags.
bats_require_minimum_version 1.5.0
load fixtures/promote/setup.bash
setup() {
  PROMOTE_SIBLING=portico promote_fixture
  W2S="$DAEDALUS_HOME/worktrees/02/portico"; S="$DAEDALUS_HOME/target/portico"; SO="$BATS_TEST_TMPDIR/portico-origin.git"
  printf 'promote:\n  tags: portico=VERSION\n  update_commands: portico=bin/update\n' >> "$DAEDALUS_HOME/config.yaml"
  export W2S S SO
}
teardown() { teardown_live; }

bump() {   # bump <version text, printf-escaped> — window 02 bumps the sibling's VERSION and commits
  printf "$1" > "$W2S/VERSION"; printf 'p\n' >> "$W2S/s.txt"; git -C "$W2S" add -A; git -C "$W2S" commit -q -m "portico: release"
}
origin_tag_sha() { git -C "$SO" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true; }
reject_tags() {    # the sibling's origin refuses tag pushes (a pre-receive hook), until allow_tags
  mkdir -p "$SO/hooks"; printf '#!/bin/sh\nwhile read o n r; do case "$r" in refs/tags/*) echo "tags refused here" >&2; exit 1;; esac; done\n' > "$SO/hooks/pre-receive"; chmod +x "$SO/hooks/pre-receive"
}
allow_tags() { rm -f "$SO/hooks/pre-receive"; }

@test "a release: the decision line names the tag and the update command; confirm pushes the merge and an annotated tag at it; the stamp, the ledger and the closing line carry the tag" {
  bump '0.2.0\n'
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Ready to promote window 02's work onto main — this is a release: it tags v0.2.0 and the next \`bin/update\` ships it." ]
  [ "$(pj tag)" = v0.2.0 ]; [ "$(pj version)" = 0.2.0 ]; m="$(pj merge_sha)"; [ "$(pj tag_sha)" = "$m" ]
  shown_then_said "yes" "Ready to promote window 02's work onto main — this is a release: it tags v0.2.0 and the next \`bin/update\` ships it."
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$SO" rev-parse main)" = "$m" ]
  [ "$(origin_tag_sha v0.2.0)" = "$m" ]
  [ "$(git -C "$SO" cat-file -t refs/tags/v0.2.0)" = tag ]
  [ "$(git -C "$SO" tag -l --format='%(contents:subject)' v0.2.0)" = "portico v0.2.0" ]
  pid="$(pj promote_id)"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "$DAEDALUS_HOME/state/promote/$pid/pushed")" = v0.2.0 ]
  grep -q "	tag v0.2.0	" "$DAEDALUS_HOME/vault/evidence/promotions.log"
  case "$output" in *"Pushed merge ${m:0:7} to main and tag v0.2.0."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"This is a release: run \`bin/update\` to receive it."*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/promote/$pid/portico" ]     # the scratch went, as after any confirm
}

@test "VERSION rules at prepare: unbumped, a leading v, missing; a carriage return is tolerated; nothing is pushed" {
  printf 'p\n' >> "$W2S/s.txt"; git -C "$W2S" commit -q -am "portico: no bump"
  run as_prime bash "$PROMOTE" 02; refused "VERSION is still 0.1.0 on main; a release must bump it."
  bump 'v0.2.0\n'
  run as_prime bash "$PROMOTE" 02; refused 'VERSION holds "v0.2.0", not a dotted version.'
  git -C "$W2S" rm -q VERSION; git -C "$W2S" commit -q -m "portico: drop VERSION"
  run as_prime bash "$PROMOTE" 02; refused "VERSION is missing or empty in the merged tree."
  bump '0.2.0\r\n'
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(pj tag)" = v0.2.0 ]
  [ -z "$(origin_tag_sha v0.2.0)" ]
}

@test "a tag already on origin at another commit, or a local tag at another commit, is refused at prepare naming the commit" {
  bump '0.2.0\n'
  other="$(git -C "$S" rev-parse HEAD)"
  git -C "$SO" tag -a v0.2.0 -m "by hand" "$other"            # made in origin itself, as a push from elsewhere would
  run as_prime bash "$PROMOTE" 02; refused "tag v0.2.0 is already on origin at ${other:0:7}; bump VERSION."
  git -C "$SO" tag -d v0.2.0 >/dev/null
  git -C "$S" tag -f v0.2.0 "$other" >/dev/null
  run as_prime bash "$PROMOTE" 02; refused "a local tag v0.2.0 in target/portico points at ${other:0:7}; delete it (git -C target/portico tag -d v0.2.0) or bump VERSION."
}

@test "promote.tags naming a repo that is not one of this target's repos is refused at prepare" {
  bump '0.2.0\n'
  sed -i '' 's/^  tags: portico=VERSION$/  tags: nope=VERSION/' "$DAEDALUS_HOME/config.yaml"
  run as_prime bash "$PROMOTE" 02; refused "config promote.tags names nope, which is not one of this target's repos (thing, thing/sub, portico)."
}

@test "a tag push that fails: the merge is on main, the words say so, the promotion is stamped tag-unpushed with no local tag left, doctor says MISSING, --clean keeps the scratch; --confirm again pushes only the tag and finishes the record" {
  bump '0.2.0\n'
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  m="$(pj merge_sha)"; pid="$(pj promote_id)"; shown_then_said "yes"
  reject_tags
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"
  [ "$status" -ne 0 ]
  case "$output" in *"Merge ${m:0:7} is on main. Tag v0.2.0 was not pushed: "*"tags refused here"*"Run \`core/promote.sh 02 --confirm\` again to push the tag."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$(printf '%s\n' "$output" | sed '/^$/d' | tail -1)" in *"Nothing else changed on origin.") : ;; *) echo "$output"; return 1 ;; esac
  [ "$(git -C "$SO" rev-parse main)" = "$m" ]; [ -z "$(origin_tag_sha v0.2.0)" ]
  [ -f "$DAEDALUS_HOME/state/promote/$pid/tag-unpushed" ]; [ ! -e "$DAEDALUS_HOME/state/promote/$pid/pushed" ]
  ! git -C "$S" rev-parse -q --verify refs/tags/v0.2.0 >/dev/null
  run bash "$DAEDALUS_HOME/core/promote.sh" --doctor
  case "$output" in *"MISSING  promotion $pid of window 02: merge pushed, tag v0.2.0 not on origin — run core/promote.sh 02 --confirm"*) : ;; *) echo "$output"; return 1 ;; esac
  run as_prime bash "$PROMOTE" 02 --clean; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -d "$DAEDALUS_HOME/state/promote/$pid/portico" ] || { echo "the scratch of a tag-unpushed promotion was removed: $output"; return 1; }
  allow_tags
  run as_prime bash "$PROMOTE" 02 --confirm --operator-said "yes"; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Pushed tag v0.2.0 at merge ${m:0:7} (the merge was already on main)."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(origin_tag_sha v0.2.0)" = "$m" ]
  [ -f "$DAEDALUS_HOME/state/promote/$pid/pushed" ]; [ ! -e "$DAEDALUS_HOME/state/promote/$pid/tag-unpushed" ]
  grep -q "	tag v0.2.0	" "$DAEDALUS_HOME/vault/evidence/promotions.log"
  run bash "$DAEDALUS_HOME/core/promote.sh" --doctor
  case "$output" in *"tag v0.2.0 not on origin"*) echo "$output"; return 1 ;; esac
  [ ! -e "$DAEDALUS_HOME/state/promote/$pid/portico" ]
}

@test "the primary is not a release repo: its promote says nothing about a tag or a release when release_note is unset" {
  work_on_02
  run as_prime bash "$PROMOTE" 02; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = "Ready to promote window 02's work onto main." ]
  [ "$(pj tag)" = None ]
}
