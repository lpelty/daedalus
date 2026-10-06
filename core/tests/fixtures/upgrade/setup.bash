# core/tests/fixtures/upgrade/setup.bash — loaded by test_upgrade.bats.
load fixtures/leases/setup.bash

# upgrade_fixture — lease_fixture's home (target/thing with nested sub, bare origins, a vault repo) as a
# deployment that pulled 0.7.0 and has not started a session: VERSION present, no stamp, no state/leases.
upgrade_fixture() {
  lease_fixture
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  UP="$DAEDALUS_HOME/core/upgrade.py"
  export UP
}
cmt() { git -C "$1" -c user.email=t@x -c user.name=t commit -q "${@:2}"; }
# v061_state — what a v0.6.1 deployment accumulates beside its checkout: the shared dedup files, a hot.md whose
# third line is a session number, and a capture hook line in settings.local.json with the key written out.
v061_state() {
  mkdir -p "$DAEDALUS_HOME/state"
  printf '{}\n' > "$DAEDALUS_HOME/state/pitfall-seen.json"
  printf '{}\n' > "$DAEDALUS_HOME/state/code-context-seen.json"
  printf -- '---\ntype: rolling-state\nsession: 011\nauthor: daedalus\n---\n\n# Hot\n' > "$DAEDALUS_HOME/vault/hot.md"
  git -C "$DAEDALUS_HOME/vault" add -A; cmt "$DAEDALUS_HOME/vault" -m hot
  cat > "$DAEDALUS_HOME/.claude/settings.local.json" <<EOF
{"hooks": {
  "SessionEnd": [{"hooks": [{"type": "command", "command": "HINDSIGHT_API_TENANT_API_KEY=k-123 TENANT_HOME=$DAEDALUS_HOME TENANT_BANK=bank-one TENANT_USER_LABEL=OPERATOR TENANT_ASSISTANT_LABEL=Daedalus TRANSCRIPT_DIR=$BATS_TEST_TMPDIR/tx python3 $DAEDALUS_HOME/core/capture.py capture >> $DAEDALUS_HOME/.capture.log 2>&1"}]}],
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "HINDSIGHT_API_TENANT_API_KEY=k-123 TENANT_HOME=$DAEDALUS_HOME TENANT_BANK=bank-one TRANSCRIPT_DIR=$BATS_TEST_TMPDIR/tx python3 $DAEDALUS_HOME/core/recall-inject.py"}]}]
}}
EOF
}
# snapshot — every file the upgrade may touch, hashed, plus each target repo's branch and HEAD: two equal
# snapshots mean a run changed nothing.
snapshot() {
  (cd "$DAEDALUS_HOME" && find state worktrees config.yaml vault/hot.md .claude/settings.local.json -type f \
     ! -name '*.lock' ! -name '*.seen' 2>/dev/null | sort | xargs shasum 2>/dev/null)
  for r in "$T" "$T/sub"; do git -C "$r" branch --show-current; git -C "$r" rev-parse HEAD; git -C "$r" branch --list | sort; done
}

# v061_fixture — a deployment built and started by v0.6.1's own code: the product tree from `git archive v0.6.1`
# of the repository this suite runs in (every clone of the product carries the tag), made a checkout of its own
# at that commit; its own origins under $B/v061/ (never lease_fixture's); v0.6.1's core/setup.sh clones the
# target (thing, nested sub) and the knowledge base from them and runs v0.6.1's doctor; v061_state beside it;
# target/thing on a branch with one commit origin lacks; and session s0 started by v0.6.1's session-start.py —
# the session that will pull. Skips, saying why, in a clone with no v0.6.1 tag.
v061_fixture() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  git -C "$REPO" rev-parse -q --verify 'refs/tags/v0.6.1^{commit}' >/dev/null || skip "this clone has no v0.6.1 tag"
  B="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"; H="$B/dep"; O="$B/v061"
  mkdir -p "$H" "$O" "$B/sessions" "$B/transcripts"
  git -C "$REPO" archive v0.6.1 | tar -x -C "$H"
  [ ! -e "$H/VERSION" ] && [ ! -e "$H/core/leaselib.py" ]      # it really is v0.6.1
  git init -q -b main "$H"; git -C "$H" add -A; cmt "$H" -m "v0.6.1"
  local name sd
  for name in thing sub thing-kb; do     # one-commit origins; thing ignores its nested repo
    sd="$B/seed-$name"; git init -q -b main "$sd"; printf '%s\n' "$name" > "$sd/$name.txt"
    [ "$name" = thing ] && printf 'sub/\n' > "$sd/.gitignore"
    git -C "$sd" add -A; cmt "$sd" -m "$name"
    git init -q --bare -b main "$O/$name.git"; git -C "$sd" push -q "$O/$name.git" main
  done
  # paths unquoted: cfg_pairs reads `nested` as rel=url, and $B has no spaces (it is a resolved bats tmpdir)
  cat > "$H/config.yaml" <<EOF
target:
  repo: $O/thing.git
  branch: main
  nested: sub=$O/sub.git
vault:
  repo: $O/thing-kb.git
gates:
  - true
proposals:
  budget: 5
verify:
  refute: false
  refute_off_reason: bats fixture — a real claude must never be invoked in tests
EOF
  # V061_TARGET_DIR: config target.dir, the checkout's directory under target/ (review 3, finding 1)
  [ -z "${V061_TARGET_DIR:-}" ] || sed -i '' "s|^  branch: main\$|  branch: main\\
  dir: $V061_TARGET_DIR|" "$H/config.yaml"
  mkdir -p "$H/.claude"
  export DAEDALUS_HOME="$H" CLAUDE_CONFIG_DIR="$B" FAKE_CLAUDE_DIR="$B/fake-claude" PATH="$REPO/core/tests/fixtures/caller/bin:$PATH"
  unset CLAUDECODE DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_LEASE DIRECT_CALL_ID \
        DAEDALUS_TARGET_OVERRIDE DAEDALUS_PROMOTE_ID TENANT_BANK TENANT_HOME TRANSCRIPT_DIR HINDSIGHT_API_TENANT_API_KEY
  bash "$H/core/setup.sh" </dev/null >"$B/setup-v061.log" 2>&1 || { cat "$B/setup-v061.log"; return 1; }
  T="$H/target/${V061_TARGET_DIR:-thing}"
  [ -d "$T/.git" ] && [ -d "$T/sub/.git" ] && [ -d "$H/vault/.git" ] || { cat "$B/setup-v061.log"; return 1; }
  v061_state
  git -C "$T" checkout -q -b fix/in-flight; printf 'f\n' > "$T/f.txt"; git -C "$T" add -A; cmt "$T" -m "the waiting fix"
  printf '{"hook_event_name":"SessionStart","session_id":"s0","source":"startup","transcript_path":"%s/transcripts/s0.jsonl"}' "$B" \
    | python3 "$H/core/session-start.py" >"$B/s0-start.out" 2>"$B/s0-start.err" || { cat "$B/s0-start.err"; return 1; }
  [ -f "$H/state/session-s0.json" ] || { echo "v0.6.1 wrote no marker for s0"; cat "$B/s0-start.err"; return 1; }
  export H T REPO B
}
# pull_current — the pull of this release: every file v0.6.1 tracked is removed and every file of the tree under
# test that git would track (committed or not yet — an executor runs this before committing) is copied in, then
# committed, so the home is a clean checkout of the code being tested. target/, vault/, state/ and config.yaml are
# gitignored there, as a pull leaves them.
pull_current() {
  git -C "$H" ls-files -z | (cd "$H" && xargs -0 rm -f)
  (cd "$REPO" && git ls-files --cached --others --exclude-standard -z) | python3 -c '
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for rel in sys.stdin.read().split("\0"):
    if not rel or not os.path.isfile(os.path.join(src, rel)):
        continue
    os.makedirs(os.path.dirname(os.path.join(dst, rel)) or dst, exist_ok=True)
    shutil.copy2(os.path.join(src, rel), os.path.join(dst, rel))' "$REPO" "$H"
  git -C "$H" add -A; cmt "$H" -m "v0.7.0"
  [ "$(cat "$H/VERSION")" = 0.7.0 ]
}
