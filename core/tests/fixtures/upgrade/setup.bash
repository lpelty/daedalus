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
