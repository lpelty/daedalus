#!/usr/bin/env bats
# The lease board on screen (lease-board spec §6.3): the mod under mods/lease-board/ as
# `claude plugin validate` reads it — the manifest, the hooks module's hooks and the mods
# API calls it makes — and its own tests under `claude plugin test`. These need the
# claude CLI: skipped, with the reason visible, when `claude` is absent or older than
# 2.1.287 (mods overview: "In the terminal, use Claude Code v2.1.287 or later").
# BATS_NO_PARALLELIZE_WITHIN_FILE: `claude plugin test` starts a child of the binary.
BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  MODS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/mods"
  MOD="$MODS/lease-board"
  command -v claude >/dev/null 2>&1 || skip "claude is not on PATH"
  ver="$(claude --version 2>/dev/null | awk '{print $1}')"
  python3 -c 'import sys; a=[int(x) for x in sys.argv[1].split(".")[:3]]; sys.exit(0 if a >= [2, 1, 287] else 1)' "$ver" 2>/dev/null \
    || skip "claude $ver is older than 2.1.287, which mods need"
}

@test "claude plugin validate: the mod validates, hooks session.start and the band, and calls exactly the nine reading methods of spec §4.8" {
  run claude plugin validate "$MOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"hooks: session.start, ui.render{component=AbovePrompt}"*) : ;; *) echo "$output"; return 1 ;; esac
  calls="$(printf '%s\n' "$output" | grep -o 'calls: .*' | head -1)"
  [ -n "$calls" ] || { echo "no calls line: $output"; return 1; }
  for c in '$.session.id' '$.session.cwd' '$.fs.exists' '$.process.run' '$.clock.now' '$.clock.every' '$.ui.invalidate' '$.ui.resolve' '$.ui.log'; do
    case "$calls" in *"$c"*) : ;; *) echo "the calls line lacks $c: $calls"; return 1 ;; esac
  done
  # nothing else: nine distinct methods, none of them a writer
  n="$(printf '%s\n' "$calls" | grep -oE '\$\.[a-z]+\.[a-zA-Z]+' | sort -u | wc -l | tr -d ' ')"
  [ "$n" = 9 ] || { echo "$n methods, not 9: $calls"; return 1; }
  for c in 'fs.write' 'store.' 'state.' 'prompt.' 'session.send' 'model.' 'process.spawn' 'command.' 'tool.' 'env.'; do
    case "$calls" in *"\$.$c"*) echo "the calls line has $c: $calls"; return 1 ;; *) : ;; esac
  done
  run claude plugin validate --strict "$MOD"
  [ "$status" -eq 0 ] || { echo "--strict: $output"; return 1; }
}

@test "claude plugin validate: the marketplace under mods/ validates and lists ./lease-board, then ./service-status" {
  run claude plugin validate "$MODS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"Validation passed"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 - "$MODS/.claude-plugin/marketplace.json" "$MOD/.claude-plugin/plugin.json" "$MOD/hooks/hooks.json" <<'PY'
import json, sys
m, p, h = (json.load(open(f)) for f in sys.argv[1:4])
assert m["name"] == "daedalus-mods", m
assert [x["source"] for x in m["plugins"]] == ["./lease-board", "./service-status"], m
assert m["plugins"][0]["name"] == "lease-board" == p["name"], (m, p)
assert h["modules"] == ["./register.js"], h
PY
}

@test "the hooks module never names git, core/lease.sh or a writing method (spec §4.8)" {
  [ -f "$MOD/hooks/register.js" ]
  # string literals only ('git', 'core/lease.sh'): the comments may say what the mod never does
  ! grep -nE "['\"](git|[^'\"]*lease\.sh)['\"]|\\\$\.fs\.write|\\\$\.store\.|\\\$\.state\.|\\\$\.prompt\.|\\\$\.session\.send|\\\$\.model\." "$MOD/hooks/register.js"
}

@test "claude plugin test: the mod's own tests pass — this window first, the pen marked, a 2 s cadence, the last board kept on a failure, the survey left alone" {
  run claude plugin test "$MOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *" 0 fail"*) : ;; *) echo "$output"; return 1 ;; esac
}
