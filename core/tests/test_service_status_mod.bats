#!/usr/bin/env bats
# The service status on screen (service-status spec §5 items 2-3): the mod under mods/service-status/ as `claude
# plugin validate` reads it — the manifest, the hooks module's hooks and the mods API calls it makes — and its own
# tests under `claude plugin test`. These need the claude CLI: skipped, with the reason visible, when `claude` is
# absent or older than 2.1.287 (mods overview: "In the terminal, use Claude Code v2.1.287 or later").
# BATS_NO_PARALLELIZE_WITHIN_FILE: `claude plugin test` starts a child of the binary.
BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  MODS="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/mods"
  MOD="$MODS/service-status"
  command -v claude >/dev/null 2>&1 || skip "claude is not on PATH"
  ver="$(claude --version 2>/dev/null | awk '{print $1}')"
  python3 -c 'import sys; a=[int(x) for x in sys.argv[1].split(".")[:3]]; sys.exit(0 if a >= [2, 1, 287] else 1)' "$ver" 2>/dev/null \
    || skip "claude $ver is older than 2.1.287, which mods need"
}

@test "claude plugin validate: the mod validates (--strict too), hooks the band, the pane and /services, and calls only readers and the screen" {
  run claude plugin validate "$MOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"hooks: session.start, command.run{command=services}, ui.render{component=AbovePrompt}, ui.render{component=Pane, requestId=services}"*) : ;; *) echo "$output"; return 1 ;; esac
  calls="$(printf '%s\n' "$output" | grep -o 'calls: .*' | head -1)"
  [ -n "$calls" ] || { echo "no calls line: $output"; return 1; }
  for c in '$.process.run' '$.tool.list' '$.ui.status' '$.ui.toast' '$.ui.open' '$.command.register' '$.clock.every' '$.clock.after'; do
    case "$calls" in *"$c"*) : ;; *) echo "the calls line lacks $c: $calls"; return 1 ;; esac
  done
  for c in 'fs.write' 'store.' 'state.' 'prompt.' 'session.send' 'model.' 'process.spawn' 'tool.call' 'env.'; do
    case "$calls" in *"\$.$c"*) echo "the calls line has $c: $calls"; return 1 ;; *) : ;; esac
  done
  run claude plugin validate --strict "$MOD"
  [ "$status" -eq 0 ] || { echo "--strict: $output"; return 1; }
  python3 - "$MODS/.claude-plugin/marketplace.json" "$MOD/.claude-plugin/plugin.json" "$MOD/hooks/hooks.json" <<'PY'
import json, sys
m, p, h = (json.load(open(f)) for f in sys.argv[1:4])
entry = [x for x in m["plugins"] if x["source"] == "./service-status"]
assert len(entry) == 1 and entry[0]["name"] == "service-status" == p["name"], (m, p)
assert "dependencies" not in p, p          # either mod can be switched off alone (spec §4)
assert h["modules"] == ["./register.js"], h
PY
}

@test "the hooks module runs only core/status.py, never git, a service's own commands, or a writing method (spec §6: it reads only)" {
  [ -f "$MOD/hooks/register.js" ]
  ! grep -nE "['\"](git|launchctl|brew|kill|[^'\"]*frame-jack[^'\"]*|[^'\"]*lease\.sh)['\"]|\\\$\.fs\.write|\\\$\.store\.|\\\$\.state\.|\\\$\.prompt\.|\\\$\.session\.send|\\\$\.model\." "$MOD/hooks/register.js"
  [ "$(grep -c '\$\.process\.run(' "$MOD/hooks/register.js")" = 1 ]
  grep -q "\['python3', STATUS_PY, '--json'\]" "$MOD/hooks/register.js"
}

@test "claude plugin test: the mod's own tests pass — the summary all up, one down, several down, the narrow count, both mod orders, a toast only on a change, the status line set and cleared" {
  run claude plugin test "$MOD"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *" 0 fail"*) : ;; *) echo "$output"; return 1 ;; esac
}
