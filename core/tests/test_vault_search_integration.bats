#!/usr/bin/env bats
#
# Spec A-9's through-the-runner clause: the real engine driven by
# vault-search.py. Skips where the engine checkout this machine provides
# isn't present.

setup() {
  ENGINE_DIR="${DAEDALUS_RECALL_TEST_ENGINE:-}"
  UV="$HOME/.local/bin/uv"
  { [ -n "$ENGINE_DIR" ] && [ -d "$ENGINE_DIR" ] && [ -x "$UV" ]; } || skip "recall engine not configured (set DAEDALUS_RECALL_TEST_ENGINE)"
  [ -f "$ENGINE_DIR/pipeline/daedalus_recall.py" ] || skip "daedalus_recall not built yet"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/specs"
  cp "$SRC/lib.sh" "$SRC/vault-search.py" "$DAEDALUS_HOME/core/"
  printf '# Alpha\n\nzebra quokka axolotl\n' > "$DAEDALUS_HOME/vault/specs/a.md"
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: https://example.com/thing.git
  branch: main
vault:
  repo: https://example.com/thing-kb.git
gates:
  - true
proposals:
  budget: 5
recall:
  vault-query: 'cd $ENGINE_DIR && DAEDALUS_VAULT_ROOT=$DAEDALUS_HOME/vault "$UV" run -m pipeline.daedalus_recall query "\$1"'
  vault-index: 'cd $ENGINE_DIR && DAEDALUS_VAULT_ROOT=$DAEDALUS_HOME/vault "$UV" run -m pipeline.daedalus_recall index'
  store: state/chroma
EOF
  export DAEDALUS_HOME
  SCRIPT="$DAEDALUS_HOME/core/vault-search.py"
}

@test "index through the runner: count line echoed, stamp written; churn re-run echoes indexed=0" {
  run python3 "$SCRIPT" index
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cE '^indexed=[0-9]+ purged=[0-9]+$')" -eq 1 ]
  [ -f "$DAEDALUS_HOME/state/recall-last-index" ]
  touch "$DAEDALUS_HOME/vault/specs/a.md"
  run python3 "$SCRIPT" index
  [ "$(printf '%s\n' "$output" | grep -cF 'indexed=0 purged=0')" -eq 1 ]
}

@test "query through the runner returns the indexed path" {
  python3 "$SCRIPT" index >/dev/null
  run python3 "$SCRIPT" query "zebra quokka axolotl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cF 'specs/a.md')" -eq 1 ]
}
