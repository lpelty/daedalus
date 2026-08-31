#!/usr/bin/env bats
# A claim is a vault doc of Daedalus's, changed this session, shaped like
# completion, created after the deployment's first evidence. Every negative
# has a positive control.

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/fingerprint.sh" "$SRC/gates.sh" "$SRC/session-start.py" "$SRC/verify-hook.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(./core/**)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
gates:
  - true
EOF
  T="$DAEDALUS_HOME/target/thing"
  git init -q "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  V="$DAEDALUS_HOME/vault"; mkdir -p "$V/proposals" "$V/evidence"
  git init -q "$V"; git -C "$V" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  git init -q "$DAEDALUS_HOME"; git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m i
  export DAEDALUS_HOME
  printf '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
}

gate() { bash "$DAEDALUS_HOME/core/gates.sh" | tail -1; }
stop() { printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s}' "${1:-s1}" "${2:-false}" | python3 "$DAEDALUS_HOME/core/verify-hook.py"; }
claim() {  # claim <file> <status> <updated-by> <created> [evidence-run]
  { printf -- '---\ntype: proposal\nstatus: %s\nupdated-by: %s\ncreated: %s\n' "$2" "$3" "$4"
    [ -n "${5:-}" ] && printf 'evidence-run: %s\n' "$5"
    printf -- '---\n# P\n'; } > "$DAEDALUS_HOME/vault/proposals/$1"
}

@test "no evidence blocks; valid citation passes; operator's doc not scanned; placeholder author is scanned" {
  id="$(gate)"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01
  run stop; [ "$status" -eq 2 ]
  case "$output" in *"PROP-1.md"*"no evidence-run"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$id"
  run stop; [ "$status" -eq 0 ]
  claim PROP-2.md IMPLEMENTED operator 2026-12-01
  run stop; [ "$status" -eq 0 ]
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nauthor: <who wrote this>\ncreated: 2026-12-01\n---\n# P\n' > "$DAEDALUS_HOME/vault/proposals/PROP-3.md"
  run stop; [ "$status" -eq 2 ]
}

@test "tree change by content blocks; touch and commit do not; untracked file blocks" {
  id="$(gate)"; claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$id"
  run stop; [ "$status" -eq 0 ]
  touch "$T/a.txt"; run stop; [ "$status" -eq 0 ]
  printf 'b\n' >> "$T/a.txt"; run stop; [ "$status" -eq 2 ]
  case "$output" in *"different tree"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  git -C "$T" checkout -q -- a.txt; run stop; [ "$status" -eq 0 ]
  printf 'u\n' > "$T/new.txt"; run stop; [ "$status" -eq 2 ]
  rm "$T/new.txt"; run stop; [ "$status" -eq 0 ]
  git -C "$T" -c user.email=t@x -c user.name=t commit -q --allow-empty -m e; run stop; [ "$status" -eq 0 ]
}

@test "gate definition changed after the run blocks with the restart remedy; restored passes" {
  id="$(gate)"; claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$id"
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/cfg.bak"
  printf '  - echo extra\n' >> "$DAEDALUS_HOME/config.yaml"
  run stop; [ "$status" -eq 2 ]
  case "$output" in *"config.yaml"*"restart"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  cp "$BATS_TEST_TMPDIR/cfg.bak" "$DAEDALUS_HOME/config.yaml"
  run stop; [ "$status" -eq 0 ]
}

@test "gate definition changed before the run (pre-run tamper) blocks even though the run matches live; restored and re-run passes" {
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/marker-cfg.bak"
  printf '  - echo extra\n' >> "$DAEDALUS_HOME/config.yaml"
  id="$(gate)"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$id"
  run stop; [ "$status" -eq 2 ]
  case "$output" in *"config.yaml"*"restart"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  cp "$BATS_TEST_TMPDIR/marker-cfg.bak" "$DAEDALUS_HOME/config.yaml"
  id2="$(gate)"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$id2"
  run stop; [ "$status" -eq 0 ]
}

@test "FAIL run cited blocks with the log path; INVALID cited blocks" {
  printf 'gates:\n  - false\n' > /dev/null
  sed -i.bak 's/  - true/  - false/' "$DAEDALUS_HOME/config.yaml"; rm -f "$DAEDALUS_HOME/config.yaml.bak"
  printf '{"hook_event_name":"SessionStart","session_id":"s3","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  out="$(bash "$DAEDALUS_HOME/core/gates.sh" 2>&1 || true)"
  id="$(printf '%s\n' "$out" | sed -n 's/^.*run-id: //p' | tail -1)"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$id"
  run stop s3; [ "$status" -eq 2 ]
  case "$output" in *"gate-1.log"*) : ;; *) echo "no log path: $output"; return 1 ;; esac
}

@test "no claim with a dirty tree passes; pre-first-evidence doc edited passes; stop_hook_active still blocks" {
  printf 'b\n' >> "$T/a.txt"
  run stop; [ "$status" -eq 0 ]
  id="$(gate)"
  claim OLD.md IMPLEMENTED daedalus 2020-01-01
  run stop; [ "$status" -eq 0 ]
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01
  run stop s1 true; [ "$status" -eq 2 ]
}

@test "one-turn assignment: claim committed before any Stop is still inside the window" {
  id="$(gate)"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01
  git -C "$DAEDALUS_HOME/vault" add -A; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q -m c
  run stop; [ "$status" -eq 2 ]
}

@test "no marker: a claim committed after the transcript's first timestamp is still found" {
  rm -f "$DAEDALUS_HOME"/state/session-*.json
  id="$(gate)"
  tp="$BATS_TEST_TMPDIR/t.jsonl"
  printf '{"timestamp":"%s"}\n' "$(date -v-1H +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '1 hour ago' +%Y-%m-%dT%H:%M:%S)" > "$tp"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01
  git -C "$DAEDALUS_HOME/vault" add -A; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q -m c
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s9\",\"transcript_path\":\"$tp\"}' | python3 '$DAEDALUS_HOME/core/verify-hook.py'"
  [ "$status" -eq 2 ]
}

@test "--doctor lists unverified claims across the whole vault and nothing when there is no evidence yet" {
  run python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor; [ "$status" -eq 0 ]; [ -z "$output" ]
  id="$(gate)"
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01
  run python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor
  case "$output" in *"PROP-1.md"*) : ;; *) echo "not listed: $output"; return 1 ;; esac
}
