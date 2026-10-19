#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$DAEDALUS_HOME/core/"
  export DAEDALUS_HOME
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"

  # A repo whose SHAPE we want and whose CONTENTS we do not.
  SHAPEREPO="$BATS_TEST_TMPDIR/upstream-vault"
  mkdir -p "$SHAPEREPO/00_inbox" "$SHAPEREPO/80_sessions" "$SHAPEREPO/_templates"
  cd "$SHAPEREPO"
  git init -q -b main
  echo "private session content" > 80_sessions/private.md
  echo "inbox item" > 00_inbox/item.md
  # Git tracks files, not directories — an empty dir never appears in
  # `ls-tree`. A real vault's _templates always holds at least one file;
  # this fixture must too, or the fixture itself contradicts the
  # documented git limitation scaffold_repo is built around.
  echo "template stub" > _templates/session.md
  echo "top level file" > README.md
  echo "rolling state" > hot.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init
}

@test "scaffold_repo creates every top-level directory" {
  source "$DAEDALUS_HOME/core/lib.sh"
  run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/00_inbox" ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/80_sessions" ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/_templates" ]
}

@test "scaffold_repo downloads no file contents" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ ! -f "$DAEDALUS_HOME/target/h/vaults/a/80_sessions/private.md" ]
  [ ! -f "$DAEDALUS_HOME/target/h/vaults/a/00_inbox/item.md" ]
  [ ! -f "$DAEDALUS_HOME/target/h/vaults/a/README.md" ]
}

@test "scaffold_repo creates hot.md with a placeholder line" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ -f "$DAEDALUS_HOME/target/h/vaults/a/hot.md" ]
  run grep -qi "placeholder" "$DAEDALUS_HOME/target/h/vaults/a/hot.md"
  [ "$status" -eq 0 ]
}

@test "scaffold_repo leaves no git checkout behind" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ ! -d "$DAEDALUS_HOME/target/h/vaults/a/.git" ]
}

@test "scaffold_repo is idempotent" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/00_inbox" ]
}

@test "scaffold_repo fails loudly on an unreachable repo" {
  source "$DAEDALUS_HOME/core/lib.sh"
  run scaffold_repo "$BATS_TEST_TMPDIR/does-not-exist" "$DAEDALUS_HOME/target/h/vaults/b"
  [ "$status" -ne 0 ]
}

@test "scaffold_repo's clone never has blob content on disk (pins --filter=blob:none --no-checkout)" {
  source "$DAEDALUS_HOME/core/lib.sh"
  DAEDALUS_SCAFFOLD_KEEP_TMP=1 run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  kept_tmp="$(printf '%s\n' "$output" | sed -n 's/^KEPT_TMP=//p')"
  [ -n "$kept_tmp" ]
  [ -d "$kept_tmp/shape" ]
  # A full checkout would put private.md, item.md, and README.md's actual
  # bytes on disk inside the clone. blob:none + no-checkout must mean none
  # of that content — not even as a working-tree file, not as a loose
  # object blob that was ever written to a worktree — ever lands here.
  run find "$kept_tmp/shape" -type f -not -path '*/.git/*'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scaffold_repo excludes dotfile directories such as .obsidian (app config, not vault taxonomy)" {
  mkdir -p "$SHAPEREPO/.obsidian"
  echo "app config" > "$SHAPEREPO/.obsidian/workspace.json"
  ( cd "$SHAPEREPO" && git add -A && git -c user.email=t@t -c user.name=t commit -q -m "add dotfile dir" )

  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ ! -d "$DAEDALUS_HOME/target/h/vaults/a/.obsidian" ]
}

@test "scaffold_repo logs (does not delete) a destination directory the source no longer has" {
  source "$DAEDALUS_HOME/core/lib.sh"
  scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  # Source shrinks: 00_inbox is removed from the tracked tree.
  ( cd "$SHAPEREPO" && git rm -rq 00_inbox/item.md && git -c user.email=t@t -c user.name=t commit -q -m "drop inbox" )

  run scaffold_repo "$SHAPEREPO" "$DAEDALUS_HOME/target/h/vaults/a"
  [ "$status" -eq 0 ]
  # Not deleted — a delete pass on a caller-supplied destination is a bigger
  # hazard than a stale empty directory (this product has already shipped
  # one path-traversal escape from a delete-adjacent operation).
  [ -d "$DAEDALUS_HOME/target/h/vaults/a/00_inbox" ]
  # But drift must be visible, not silent.
  printf '%s\n' "$output" | grep -qF "00_inbox"
}

@test "setup fails loudly when config.yaml is absent" {
  cp "$(cd "$BATS_TEST_DIRNAME/.." && pwd)/setup.sh" "$DAEDALUS_HOME/core/"
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *config*) : ;;
    *) echo "expected the failure to name config; got: $output"; return 1 ;;
  esac
}

@test "setup reports each phase it runs" {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/setup.sh" "$SRC/sync-target.sh" "$SRC/sync-vault.sh" "$SRC/doctor.sh" "$DAEDALUS_HOME/core/"
  cp -R "$SRC/templates" "$DAEDALUS_HOME/core/templates"

  SHIP="$BATS_TEST_TMPDIR/ship"
  mkdir -p "$SHIP"
  cd "$SHIP"
  git init -q -b main
  printf 'vaults/\n' > .gitignore
  echo code > file.txt
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  KB="$BATS_TEST_TMPDIR/kb"
  mkdir -p "$KB"
  cd "$KB"
  git init -q -b main
  echo kb > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $SHIP
  branch: main
  scaffold: vaults/a=$SHAPEREPO
vault:
  repo: $KB
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ]
  case "$output" in
    *scaffold*) : ;;
    *) echo "expected setup to report the scaffold phase; got: $output"; return 1 ;;
  esac
  [ -d "$DAEDALUS_HOME/target/ship/vaults/a/00_inbox" ]
}

@test "setup rejects a scaffold path that escapes the target checkout via .." {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/setup.sh" "$SRC/sync-target.sh" "$SRC/sync-vault.sh" "$SRC/doctor.sh" "$DAEDALUS_HOME/core/"
  cp -R "$SRC/templates" "$DAEDALUS_HOME/core/templates"

  SHIP="$BATS_TEST_TMPDIR/ship"
  mkdir -p "$SHIP"
  cd "$SHIP"
  git init -q -b main
  printf 'vaults/\n' > .gitignore
  echo code > file.txt
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  KB="$BATS_TEST_TMPDIR/kb"
  mkdir -p "$KB"
  cd "$KB"
  git init -q -b main
  echo kb > README.md
  git add -A
  git -c user.email=t@t -c user.name=t commit -q -m init

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $SHIP
  branch: main
  scaffold: ../../escaped=$SHAPEREPO
vault:
  repo: $KB
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *"must stay inside"*) : ;;
    *) echo "expected the failure to name the traversal; got: $output"; return 1 ;;
  esac
  # The guard must fire before scaffold_repo ever runs mkdir -p on the
  # unvalidated path — an exit-code check alone would still pass if the
  # directory were created first and the failure came from something else
  # afterward. Nothing named "escaped" may exist anywhere under BATS_TEST_TMPDIR,
  # inside DAEDALUS_HOME or out (e.g. at DAEDALUS_HOME/../../escaped).
  run find "$BATS_TEST_TMPDIR" -depth -name escaped
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# The scaffold phase's target.repo precondition guard is unreachable through
# setup.sh as it exists today, and not for the reason first assumed. Phase 1
# (sync-target.sh) does die loudly on a missing target.repo before phase 3
# runs — but that's not even the operative protection. `setup.sh` sources
# lib.sh, and lib.sh's own `set -euo pipefail` silently promotes -e for the
# rest of setup.sh's execution too, overriding setup.sh's stated `-uo
# pipefail` (no -e). Under that leaked -e, a die() inside ANY command
# substitution aborts the whole script immediately — the exact trap this
# guard exists to prevent literally cannot fire anywhere in this codebase
# right now, because every caller of target_path() also sources lib.sh.
#
# Proven directly: with the guard line removed, `bash core/setup.sh` (and an
# isolated extraction of just the scaffold-phase block) both still exit
# non-zero with the right message — not because a check catches it, but
# because the leaked -e catches the underlying die(). A test built against
# real conditions cannot distinguish "guard present" from "guard absent" —
# it would pass vacuously either way, which is exactly the failure mode this
# project has shipped before.
#
# So this test constructs the hypothetical the guard actually defends
# against: `set +e` right after sourcing lib.sh, undoing the accidental
# promotion, to reproduce the -uo-pipefail-without-e conditions setup.sh's
# header claims for itself. Only under that reproduced condition does the
# call-site guard (not the leak) do the work. This is deliberately a
# precaution against a future fix to the -e leak (or any -e-free caller) as
# much as it's a test against today's behavior — that's the honest framing,
# not a claim that today's setup.sh is reachable in this exact broken shape.
@test "setup's scaffold phase reports a clear error (not an empty target, not exit 0) when target.repo is absent, even without the leaked -e from lib.sh" {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  scaffold: vaults/a=$SHAPEREPO
vault:
  repo: $BATS_TEST_TMPDIR/kb
gates:
  - true
proposals:
  budget: 5
EOF

  cat > "$BATS_TEST_TMPDIR/scaffold-phase.sh" <<SCRIPT
#!/usr/bin/env bash
set -uo pipefail
source "$DAEDALUS_HOME/core/lib.sh"
set +e   # undo lib.sh's leaked -e: reproduce setup.sh's OWN stated -uo-pipefail-without-e
$(sed -n '/^log "phase 4\/5: scaffold"/,/^fi$/p' "$SRC/setup.sh" | tail -n +2)
SCRIPT

  run bash "$BATS_TEST_TMPDIR/scaffold-phase.sh"
  [ "$status" -ne 0 ]
  case "$output" in
    *"target.repo is required"*) : ;;
    *) echo "expected the failure to name target.repo; got: $output"; return 1 ;;
  esac
  # The false-green this guards against: target_path()'s internal die fires
  # inside a command substitution, which (without -e) only exits that
  # subshell — the parent would otherwise continue with target='' and
  # reach scaffold_repo with a garbage destination. Assert directly against
  # that: nothing gets scaffolded under an empty-string target path.
  run find "$DAEDALUS_HOME" -depth -name a -path "*vaults*"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "setup runs five phases in order — leases between vault and scaffold makes the window directories (promote's and the direct calls' mode 700) — and never stamps the upgrade" {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  for f in setup.sh sync-target.sh sync-vault.sh doctor.sh upgrade.py verifylib.py leaselib.py prepush.py; do cp "$SRC/$f" "$DAEDALUS_HOME/core/"; done
  cp -R "$SRC/templates" "$DAEDALUS_HOME/core/templates"
  SHIP="$BATS_TEST_TMPDIR/ship"; git init -q -b main "$SHIP"; echo code > "$SHIP/file.txt"
  git -C "$SHIP" add -A; git -C "$SHIP" -c user.email=t@t -c user.name=t commit -q -m init
  KB="$BATS_TEST_TMPDIR/kb"; git init -q -b main "$KB"; echo kb > "$KB/README.md"
  git -C "$KB" add -A; git -C "$KB" -c user.email=t@t -c user.name=t commit -q -m init
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: $SHIP
  branch: main
vault:
  repo: $KB
gates:
  - true
proposals:
  budget: 5
EOF
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | sed -n 's/^daedalus: \(phase [0-9]\/5: [a-z]*\)$/\1/p' | tr '\n' ',')" = "phase 1/5: target,phase 2/5: vault,phase 3/5: leases,phase 4/5: scaffold,phase 5/5: doctor," ] || { echo "$output"; return 1; }
  case "$output" in *"Setup: created state/leases/, worktrees/, state/promote/, state/direct-calls/."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(stat -f %Lp "$DAEDALUS_HOME/state/promote")" = 700 ]; [ "$(stat -f %Lp "$DAEDALUS_HOME/state/direct-calls")" = 700 ]
  [ ! -e "$DAEDALUS_HOME/state/upgraded-to" ]
  run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ]; case "$output" in *"Setup: created"*) echo "a rerun created something: $output"; return 1 ;; esac
}

# --- the lease board install (lease-board spec §4.6; review 2026-10-11, finding 19) -----------------------------
# A fake `claude` on PATH records every argv line; `--version` answers as 2.1.296 so doctor's version line stays quiet.
setup_board_fixture() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  for f in setup.sh sync-target.sh sync-vault.sh doctor.sh upgrade.py verifylib.py leaselib.py prepush.py; do cp "$SRC/$f" "$DAEDALUS_HOME/core/"; done
  cp -R "$SRC/templates" "$DAEDALUS_HOME/core/templates"
  SHIP="$BATS_TEST_TMPDIR/ship"; git init -q -b main "$SHIP"; echo code > "$SHIP/file.txt"
  git -C "$SHIP" add -A; git -C "$SHIP" -c user.email=t@t -c user.name=t commit -q -m init
  KB="$BATS_TEST_TMPDIR/kb"; git init -q -b main "$KB"; echo kb > "$KB/README.md"
  git -C "$KB" add -A; git -C "$KB" -c user.email=t@t -c user.name=t commit -q -m init
  printf 'target:\n  repo: %s\n  branch: main\nvault:\n  repo: %s\ngates:\n  - true\nproposals:\n  budget: 5\n' "$SHIP" "$KB" > "$DAEDALUS_HOME/config.yaml"
  FAKE="$BATS_TEST_TMPDIR/fakeclaude"; mkdir -p "$FAKE"; CALLS="$BATS_TEST_TMPDIR/claude-calls"
  printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "2.1.296 (Claude Code)"; exit 0; }\nprintf "%%s\\n" "$*" >> "%s"\nexit "${FAKE_CLAUDE_RC:-0}"\n' "$CALLS" > "$FAKE/claude"; chmod +x "$FAKE/claude"
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
  export CLAUDE_CODE_PLUGIN_CACHE_DIR="$BATS_TEST_TMPDIR/plugins"
  unset DAEDALUS_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_PID
}

@test "setup: the lease board — with mods/ present and nothing enabling the plugin, the two commands run in order at local scope; a second run finds .claude/settings.local.json naming it and runs nothing" {
  setup_board_fixture
  mkdir -p "$DAEDALUS_HOME/mods/.claude-plugin"; printf '{"name":"daedalus-mods","owner":{"name":"x"},"plugins":[]}\n' > "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"lease board: the band above the prompt"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$CALLS")" = "plugin marketplace add ./mods --scope local
plugin install lease-board@daedalus-mods --scope local" ] || { echo "calls: $(cat "$CALLS")"; return 1; }
  # the real CLI writes this; the fake does not, so write what it would have
  mkdir -p "$DAEDALUS_HOME/.claude"; printf '{"enabledPlugins":{"lease-board@daedalus-mods":true}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  rm -f "$CALLS"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"lease board: already installed for this deployment (.claude/settings.local.json names lease-board@daedalus-mods)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CALLS" ] || { echo "claude was run: $(cat "$CALLS")"; return 1; }
}

@test "setup: the lease board — a claude that fails prints the did-not-finish line and setup still finishes; mods/ absent is the skipped line and no call" {
  setup_board_fixture
  mkdir -p "$DAEDALUS_HOME/mods/.claude-plugin"; printf '{"name":"daedalus-mods","owner":{"name":"x"},"plugins":[]}\n' > "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json"
  FAKE_CLAUDE_RC=1 PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *'lease board: the install did not finish — run the two commands in README.md "Windows (leases)" yourself'*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$CALLS")" = "plugin marketplace add ./mods --scope local" ] || { echo "calls: $(cat "$CALLS")"; return 1; }
  rm -rf "$DAEDALUS_HOME/mods" "$CALLS"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"lease board: skipped (mods/ absent)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CALLS" ]
}

@test "setup: the lease board — a plugin enabled at user scope (~/.claude/settings.json) counts as installed: no second declaration at local scope (review 2026-10-11, finding 14)" {
  setup_board_fixture
  mkdir -p "$DAEDALUS_HOME/mods/.claude-plugin"; printf '{"name":"daedalus-mods","owner":{"name":"x"},"plugins":[]}\n' > "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json"
  printf '{"enabledPlugins":{"lease-board@daedalus-mods":true}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"lease board: already installed for this deployment ($CLAUDE_CONFIG_DIR/settings.json names lease-board@daedalus-mods)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CALLS" ] || { echo "claude was run: $(cat "$CALLS")"; return 1; }
}

# --- the service status install (service-status spec §4) ----------------------------------------------------------
@test "setup: the service status — a marketplace listing it installs it at local scope after the lease board; a second run finds both named and runs nothing; one enabled at user scope is not declared again" {
  setup_board_fixture
  mkdir -p "$DAEDALUS_HOME/mods/.claude-plugin"
  printf '{"name":"daedalus-mods","owner":{"name":"x"},"plugins":[{"name":"lease-board","source":"./lease-board"},{"name":"service-status","source":"./service-status"}]}\n' > "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"service status: the summary beside the board"*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(cat "$CALLS")" = "plugin marketplace add ./mods --scope local
plugin install lease-board@daedalus-mods --scope local
plugin marketplace add ./mods --scope local
plugin install service-status@daedalus-mods --scope local" ] || { echo "calls: $(cat "$CALLS")"; return 1; }
  mkdir -p "$DAEDALUS_HOME/.claude"
  printf '{"enabledPlugins":{"lease-board@daedalus-mods":true,"service-status@daedalus-mods":true}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  rm -f "$CALLS"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"service status: already installed for this deployment (.claude/settings.local.json names service-status@daedalus-mods)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CALLS" ] || { echo "claude was run: $(cat "$CALLS")"; return 1; }
  printf '{"enabledPlugins":{"lease-board@daedalus-mods":true}}\n' > "$DAEDALUS_HOME/.claude/settings.local.json"
  printf '{"enabledPlugins":{"service-status@daedalus-mods":true}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  case "$output" in *"service status: already installed for this deployment ($CLAUDE_CONFIG_DIR/settings.json names service-status@daedalus-mods)"*) : ;; *) echo "$output"; return 1 ;; esac
  [ ! -e "$CALLS" ] || { echo "claude was run: $(cat "$CALLS")"; return 1; }
}

@test "setup: the service status — a failing claude is the did-not-finish line and setup still finishes; a marketplace that does not list it is the skipped line" {
  setup_board_fixture
  mkdir -p "$DAEDALUS_HOME/mods/.claude-plugin"
  printf '{"name":"daedalus-mods","owner":{"name":"x"},"plugins":[{"name":"service-status","source":"./service-status"}]}\n' > "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json"
  FAKE_CLAUDE_RC=1 PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"service status: the install did not finish — run the install command in mods/service-status/README.md yourself"*) : ;; *) echo "$output"; return 1 ;; esac
  printf '{"name":"daedalus-mods","owner":{"name":"x"},"plugins":[]}\n' > "$DAEDALUS_HOME/mods/.claude-plugin/marketplace.json"
  rm -f "$CALLS"
  PATH="$FAKE:$PATH" run bash "$DAEDALUS_HOME/core/setup.sh"
  case "$output" in *"service status: skipped (the marketplace in mods/ does not list it)"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$(cat "$CALLS" 2>/dev/null)" in *service-status*) echo "calls: $(cat "$CALLS")"; return 1 ;; esac
}

# --- the daedalus command (update-command design Decision 1, §4.1, §4.7) -----------------------------------------
@test "setup: the daedalus command — installed in ~/.local/bin (a scratch HOME) before doctor, one shim for every home, this home registered; a second run leaves it and says nothing about it; a file there it did not write is left, with a line, and setup still finishes" {
  setup_board_fixture
  cp "$SRC/update.py" "$DAEDALUS_HOME/core/"
  S="$BATS_TEST_TMPDIR/scratch-home"; mkdir -p "$S"; DH="$(cd "$DAEDALUS_HOME" && pwd -P)"
  printf '#!/bin/sh\nPATH="%s/.local/bin:/usr/bin:/bin" exec /bin/sh -c "$3"\n' "$S" > "$BATS_TEST_TMPDIR/zsh"; chmod +x "$BATS_TEST_TMPDIR/zsh"
  run env -u DAEDALUS_NO_COMMAND -u XDG_CONFIG_HOME HOME="$S" SHELL="$BATS_TEST_TMPDIR/zsh" bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q '^exec python3 "$h/core/update.py" "$@"$' "$S/.local/bin/daedalus"     # one shim for every home
  grep -q "\"$DH\"" "$S/.config/daedalus/homes.json"                          # and this home registered
  [ "$(stat -f %Lp "$S/.local/bin/daedalus")" = 755 ]
  cmd="$(printf '%s\n' "$output" | grep -n 'daedalus: command: Installed the daedalus command at ~/.local/bin/daedalus' | cut -d: -f1)"
  doc="$(printf '%s\n' "$output" | grep -n 'phase 5/5: doctor' | cut -d: -f1)"
  [ -n "$cmd" ] && [ "$cmd" -lt "$doc" ] || { echo "$output"; return 1; }
  run env -u DAEDALUS_NO_COMMAND -u XDG_CONFIG_HOME HOME="$S" SHELL="$BATS_TEST_TMPDIR/zsh" bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"command: Installed"*|*"command: Rewrote"*) echo "$output"; return 1 ;; esac
  printf '#!/bin/sh\necho mine\n' > "$S/.local/bin/daedalus"
  run env -u DAEDALUS_NO_COMMAND -u XDG_CONFIG_HOME HOME="$S" SHELL="$BATS_TEST_TMPDIR/zsh" bash "$DAEDALUS_HOME/core/setup.sh"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  case "$output" in *"command: ~/.local/bin/daedalus is not a shim daedalus wrote, so it was left as it is; type python3 $DH/core/update.py update --home $DH instead."*) : ;; *) echo "$output"; return 1 ;; esac
  [ "$(sed -n 2p "$S/.local/bin/daedalus")" = "echo mine" ]
}
