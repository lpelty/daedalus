#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault/evidence" "$DAEDALUS_HOME/vault/proposals" "$DAEDALUS_HOME/.claude"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/session-start.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(./core/**)","Edit(./CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  printf 'x\n' > "$DAEDALUS_HOME/CLAUDE.md"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
EOF
  git init -q "$DAEDALUS_HOME"; git -C "$DAEDALUS_HOME" add -A
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m init
  git init -q "$DAEDALUS_HOME/vault"; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  export DAEDALUS_HOME
}

start() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"%s"}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/session-start.py"; }

@test "startup writes the marker with vault head, config sha, and protected snapshot; compact preserves it" {
  printf 'dirty\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run start s1 startup
  [ "$status" -eq 0 ]
  m="$DAEDALUS_HOME/state/session-s1.json"
  [ -f "$m" ]
  [ "$(grep -c '"vault_head"' "$m")" -eq 1 ]
  # CLAUDE.md appears three times by design: once in the protected_status
  # porcelain line, once as the protected_snapshot dict key, and once inside
  # that entry's own "line" field (the porcelain line kept alongside the hash).
  [ "$(grep -c 'CLAUDE.md' "$m")" -eq 3 ]
  [ "$(python3 -c "import json,sys; print('CLAUDE.md' in json.load(open('$m'))['protected_snapshot'])")" = "True" ]
  case "$output" in *"uncommitted changes"*) : ;; *) echo "no operator-dirt notice: $output"; return 1 ;; esac
  before="$(cat "$m")"
  git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m later
  git -C "$DAEDALUS_HOME" checkout -- CLAUDE.md
  run start s1 compact
  [ "$(cat "$m")" = "$before" ]
  case "$output" in *"CLAUDE.md"*) : ;; *) echo "compact notice lost the marker's protected snapshot: $output"; return 1 ;; esac
}

@test "a claim committed by a crashed session is still found; a cited-and-passing claim is not" {
  printf -- '---\ntype: evidence\nrun-id: 20260101-000000-abcdef\nresult: PASS\ncreated: 2026-01-01T00:00:00\n---\n' > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md"
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-02-01\n---\n# Committed\n' > "$DAEDALUS_HOME/vault/proposals/PROP-COMMITTED.md"
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-02-01\nevidence-run: 20260101-000000-abcdef\n---\n# Cited\n' > "$DAEDALUS_HOME/vault/proposals/PROP-CITED.md"
  git -C "$DAEDALUS_HOME/vault" add -A
  git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q -m "crashed session's claims"
  run start s3 startup
  [ "$status" -eq 0 ]
  case "$output" in *"PROP-COMMITTED.md"*"no evidence-run"*) : ;; *) echo "committed claim not announced: $output"; return 1 ;; esac
  case "$output" in *"PROP-CITED.md"*) echo "cited-and-passing claim wrongly flagged: $output"; return 1 ;; *) : ;; esac
}

@test "an unverified claim from a crashed session is announced at start" {
  printf -- '---\ntype: evidence\nrun-id: 20260101-000000-abcdef\nresult: PASS\ncreated: 2026-01-01T00:00:00\n---\n' > "$DAEDALUS_HOME/vault/evidence/20260101-000000-abcdef.md"
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-02-01\n---\n# P\n' > "$DAEDALUS_HOME/vault/proposals/PROP-9.md"
  run start s2 startup
  [ "$status" -eq 0 ]
  case "$output" in *"PROP-9.md"*"no evidence-run"*) : ;; *) echo "claim not announced: $output"; return 1 ;; esac
}
