#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export DAEDALUS_HOME
}

@test "CLAUDE.md exists and states the no-self-modification rule" {
  [ -f "$DAEDALUS_HOME/CLAUDE.md" ]
  run grep -qi "belongs to the distribution" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -qi "stays exactly as the distribution shipped it" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md names the five states" {
  for s in IMPLEMENTED REFUSED BLOCKED SCOPE-CREEP PROPOSED; do
    run grep -q "$s" "$DAEDALUS_HOME/CLAUDE.md"
    [ "$status" -eq 0 ]
  done
}

@test "CLAUDE.md names the write boundary" {
  run grep -q "target/" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "vault/" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "SOUL.md exists" {
  [ -f "$DAEDALUS_HOME/SOUL.md" ]
}

# Read from HEAD, never the working files (2026-10-15): SOUL.md is the instance's own journal, so on a
# deployment the working copy carries that deployment's words — and CLAUDE.md may carry its local
# changes; what publishes is what is committed.
@test "identity files contain no harness-specific facts" {
  run bash -c 'cd "$1" && { git show HEAD:CLAUDE.md; git show HEAD:SOUL.md; } | grep -iE "fleet|atlas|smartsheet|larrypelty"' _ "$DAEDALUS_HOME"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

# The test above only ever looked at CLAUDE.md and SOUL.md. That narrow scope
# is exactly how a personal-identity fixture leak (agents/bill, vaults/bill
# in core/tests/test_config.bats) survived seven prior reviews — the guard
# never looked at core/, README.md, or config.example.yaml. This test scans
# the distribution by prefix rather than by a hardcoded file list, so it keeps
# covering whatever the repo ships as files are added or renamed.
#
# The two tests are kept separate rather than folded together: this one
# pins the two identity files specifically (the highest-stakes leak surface,
# since their content is injected as instructions) and fails with a precise
# "CLAUDE.md/SOUL.md" signal; the wide scan below fails with "somewhere in
# the distribution," which is the right granularity for a broad sweep but the
# wrong granularity for the two files most likely to matter.
#
# PREMISE — read this before widening or narrowing the scan.
#
# This guard protects one thing: content reaching a *public* remote. The scan
# covers every tracked path that ships as part of the distribution:
#
#   core/                 the scripts and their tests
#   CLAUDE.md, SOUL.md    the loaded identity files
#   README.md             operator documentation
#   config.example.yaml   the shipped config template
#   .claude/              settings.json and the shipped skills
#   VERSION               the release number (spec §14)
#   docs/                 documents the distribution ships for a deployment to read
#
# .claude/ IS scanned, and that inclusion is load-bearing: its tracked
# contents — the settings file and the skills under .claude/skills/ — are
# committed and travel to the remote exactly like core/ does. Anything there
# publishes. (.claude/settings.local.json does NOT publish: it is gitignored,
# so `git ls-files` never reports it and the scan never reads it. That is why
# the scan is driven by git rather than by a filesystem walk.)
#
# vault/ is the ONE exclusion, and only vault/. A deployment may track its
# vault inside this repo, and a knowledge-base document about a deployment
# cannot avoid naming that deployment. Scanning it would make this guard
# permanently red, and a guard that is always red protects nothing — it trains
# its operator to ignore it. CLAUDE.md already defines vault/ as per-deployment
# work product rather than distribution.
#
# The scan is deliberately NOT a whole-tree scan, for that one reason alone.
# Every other tracked path is in scope, and paths come from `git ls-files` over
# the prefixes above, so the scan follows the repo as files are added or
# renamed rather than tracking a hand-maintained list. A NEW top-level path
# that publishes would still need adding here.
#
# CONSEQUENCE: on a deployment whose vault is tracked in the repo, the thing
# keeping vault content off the public remote is a *config setting* (a disabled
# push URL), not this test. No test verifies that setting stays disabled. If
# you re-enable a public push URL on such a deployment, or move per-deployment
# content out of vault/ into a distribution path, this guard will not catch the
# first case — that is what you are invalidating.
@test "no distribution file leaks personal-identity or environment facts" {
  cd "$DAEDALUS_HOME"
  self="core/tests/test_identity.bats"
  offenders=""

  # Token list: the general set from the narrow test above (fleet, atlas,
  # smartsheet, larrypelty), plus larry/lpelty/an absolute-home-path prefix
  # since those are equally personal and not covered by "larrypelty" alone.
  # The agent names are included separately below with a word-boundary
  # match: as bare regex alternatives they would also match "billing",
  # "billion", "William" and the like, none of which are identity leaks, so
  # they can't share the unbounded pattern the other tokens use safely.
  #
  # Paths come from `git ls-files` over the distribution prefixes (see PREMISE
  # above), so the scan follows the repo as files are added or renamed rather
  # than tracking a hand-maintained list.
  # The two identity files are read from HEAD, never the working tree (2026-10-15): SOUL.md is the
  # instance's own journal, CLAUDE.md may carry a deployment's local changes, and what publishes is
  # what is committed. Every other file is read as it stands, so a leak is caught before its commit.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$self" ] && continue
    case "$f" in
      CLAUDE.md|SOUL.md) text="$(git show "HEAD:$f")" ;;
      *) text="$(cat "$f")" ;;
    esac
    # The release's own public address (v0.7.3, `daedalus update`: core/update.py's RELEASE_ADDRESS, the
    # README's first-update line) is where the distribution publishes, so it is no leak: it alone is
    # taken out before the scan, in its https, ssh and scp forms, and any other use of the account still fails.
    text="$(printf '%s\n' "$text" | tr 'A-Z' 'a-z' | sed -E 's#github\.com[/:]lpelty/daedalus([^-a-z0-9_]|$)#release-address\1#g')"
    if printf '%s\n' "$text" | grep -qiE "larry|lpelty|/Users/|fleet|atlas|smartsheet"; then
      offenders="$offenders $f(token)"
    fi
    # Agent names, word-bounded (spec §8.4): the caller is generalized — the
    # callee is named only by a deployment's gitignored config.yaml — so no
    # agent's name may be hardcoded anywhere in the distribution.
    if printf '%s\n' "$text" | grep -qwiE "bill|wren|clara|moot"; then
      offenders="$offenders $f(agent name)"
    fi
  done <<EOF
$(git ls-files -- core mods .claude CLAUDE.md SOUL.md README.md CHANGELOG.md config.example.yaml VERSION docs)
EOF

  [ -z "$offenders" ] || { echo "personal-identity leak in:$offenders"; return 1; }
}

# The two tests below exercise the scan above against a throwaway repo whose
# topology we control. They run the real guard — this same file, copied into a
# fixture at the same relative path so its DAEDALUS_HOME resolves to the
# fixture root — rather than reimplementing its grep. A reimplementation would
# pass while the real scan was broken, which is the failure mode the scoping
# change is most exposed to.
#
# The scan is selected by name and its result read from bats' exit status, so
# neither test asserts a file count, a token count, or any other constant.
_make_fixture_repo() {
  fixture="$BATS_TEST_TMPDIR/fixture"
  rm -rf "$fixture"
  mkdir -p "$fixture/core/tests"
  cp "$BATS_TEST_DIRNAME/test_identity.bats" "$fixture/core/tests/test_identity.bats"
  # Minimal distribution surface: the scan only reads files git reports.
  printf 'placeholder\n' > "$fixture/CLAUDE.md"
  printf 'placeholder\n' > "$fixture/SOUL.md"
  printf 'placeholder\n' > "$fixture/README.md"
  printf 'placeholder\n' > "$fixture/config.example.yaml"
  printf 'clean core file\n' > "$fixture/core/somefile.sh"
  git -C "$fixture" init -q
  git -C "$fixture" add -A
  # committed: the scan reads the two identity files from HEAD
  git -C "$fixture" -c user.email=t@x -c user.name=t commit -q -m seed
}

# Runs only the wide scan against the fixture, and reports its pass/fail.
_run_scan_in_fixture() {
  bats --filter "no distribution file leaks" "$fixture/core/tests/test_identity.bats"
}

@test "wide scan still catches a deployment-specific leak in a distribution file" {
  _make_fixture_repo
  # The exact case this guard caught for real during the P0 plan: a
  # deployment-specific name appearing in a code comment under core/. The
  # token here is drawn from the scan's own pattern; it names no real
  # deployment, so this file stays clean under its own guard.
  printf '# note about running the fleet on this host\n' >> "$fixture/core/somefile.sh"
  git -C "$fixture" add -A

  run _run_scan_in_fixture
  [ "$status" -ne 0 ]
}

@test "wide scan ignores deployment-specific words in the tracked vault" {
  _make_fixture_repo
  # A deployment whose vault is tracked in the repo: a knowledge-base document
  # about that deployment necessarily names it. vault/ does not travel to a
  # public remote, and is the scan's single exclusion.
  mkdir -p "$fixture/vault/infrastructure"
  printf 'This document describes the fleet running on this host.\n' \
    > "$fixture/vault/infrastructure/deployment.md"
  git -C "$fixture" add -Af

  run _run_scan_in_fixture
  [ "$status" -eq 0 ]
}

@test "wide scan catches a leak in a .claude file, which publishes" {
  # .claude/ is tracked and travels to the remote exactly like core/ does:
  # settings.json and everything under .claude/skills/ publish. A scan that
  # skipped it would leave the shipped skills unguarded — which is precisely
  # the gap a narrower scope opened.
  _make_fixture_repo
  mkdir -p "$fixture/.claude/skills/example"
  printf '# note about running the fleet on this host\n' \
    > "$fixture/.claude/skills/example/SKILL.md"
  git -C "$fixture" add -A

  run _run_scan_in_fixture
  [ "$status" -ne 0 ]
}

@test "wide scan lets the release's own address through, and nothing else of the account (v0.7.3)" {
  _make_fixture_repo
  printf 'RELEASE_ADDRESS = "github.com/lpelty/daedalus"\nurl: https://GitHub.com/lpelty/daedalus.git\nssh: git@github.com:lpelty/daedalus.git\n' >> "$fixture/core/somefile.sh"
  git -C "$fixture" add -A
  run _run_scan_in_fixture
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for leak in 'github.com/lpelty/other-project' 'github.com/lpelty/daedalus-fork' 'mail lpelty about it' 'github.com/lpelty/daedalus by larry'; do
    _make_fixture_repo
    printf '%s\n' "$leak" >> "$fixture/core/somefile.sh"
    git -C "$fixture" add -A
    run _run_scan_in_fixture
    [ "$status" -ne 0 ] || { echo "the scan let through: $leak"; return 1; }
  done
}

@test "wide scan does not read a gitignored local settings file" {
  # .claude/settings.local.json holds per-deployment values (and on a real
  # deployment, a live credential). It is gitignored, so `git ls-files` never
  # reports it and the scan never opens it. Driving the scan from git rather
  # than a filesystem walk is what makes that true — this pins it.
  _make_fixture_repo
  mkdir -p "$fixture/.claude"
  printf '.claude/settings.local.json\n' > "$fixture/.gitignore"
  printf '{"note": "/Users/someone/harness for larry"}\n' \
    > "$fixture/.claude/settings.local.json"
  git -C "$fixture" add -A

  run _run_scan_in_fixture
  [ "$status" -eq 0 ]
}

@test "both scans read SOUL.md and CLAUDE.md from HEAD: a deployment whose instance wrote 'smartsheet' into its working SOUL.md, or whose working CLAUDE.md carries a local change naming it, still passes (2026-10-15: SOUL.md is the instance's own journal)" {
  clone="$BATS_TEST_TMPDIR/clone"; rm -rf "$clone"
  git clone -q "$DAEDALUS_HOME" "$clone"
  cp "$BATS_TEST_DIRNAME/test_identity.bats" "$clone/core/tests/test_identity.bats"   # the scan as written now, not the clone's HEAD copy
  printf '\n## 2026-10-15\nOn the smartsheet laptop today; larrypelty asked for the fleet view.\n' >> "$clone/SOUL.md"
  printf '\n<!-- local change on the smartsheet deployment -->\n' >> "$clone/CLAUDE.md"
  [ -n "$(git -C "$clone" status --porcelain -- SOUL.md CLAUDE.md)" ]
  run bats --filter "identity files contain no harness-specific facts" "$clone/core/tests/test_identity.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bats --filter "no distribution file leaks" "$clone/core/tests/test_identity.bats"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # and the same clone with the words COMMITTED into SOUL.md fails both: HEAD is what is read
  git -C "$clone" -c user.email=t@x -c user.name=t commit -q -am "journal"
  run bats --filter "identity files contain no harness-specific facts" "$clone/core/tests/test_identity.bats"
  [ "$status" -ne 0 ]
  run bats --filter "no distribution file leaks" "$clone/core/tests/test_identity.bats"
  [ "$status" -ne 0 ]
}

@test "wide scan catches a hardcoded agent name in core (the callee is named only by config)" {
  _make_fixture_repo
  printf '# callee: wren\n' >> "$fixture/core/somefile.sh"
  git -C "$fixture" add -A
  run _run_scan_in_fixture
  [ "$status" -ne 0 ]
}

@test "wide scan's agent names are word-bounded: moots, billing and Clarabelle are not agent names" {
  _make_fixture_repo
  printf '# moots, billing and Clarabelle\n' >> "$fixture/core/somefile.sh"
  git -C "$fixture" add -A
  run _run_scan_in_fixture
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "loaded identity files state rules positively" {
  run grep -qi "does not modify" "$DAEDALUS_HOME/CLAUDE.md" "$DAEDALUS_HOME/README.md"
  [ "$status" -ne 0 ]
  run grep -qi "never promote" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -ne 0 ]
}

@test "CLAUDE.md frames target/ contents as evidence, not directives" {
  run grep -q "material under audit" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "observations about how that harness instructs its agent" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md carries the evidence framing into dispatch prompts" {
  run grep -q "reads this file only if you put it there" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "take your instructions from this prompt" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md states the provenance field names" {
  for f in "author:" "created:" "updated-by:" "updated:"; do
    run grep -qF "$f" "$DAEDALUS_HOME/CLAUDE.md"
    [ "$status" -eq 0 ]
  done
}

@test "CLAUDE.md states author and created stay fixed across edits" {
  run grep -q "keeps .author. and .created. exactly as found" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

@test "CLAUDE.md distinguishes updated from verified-against-live" {
  run grep -q "asserting something stricter" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "moves on any edit, including a typo fix" "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
  run grep -q "verification pass moves .verified-against-live." "$DAEDALUS_HOME/CLAUDE.md"
  [ "$status" -eq 0 ]
}

# Regression guard for the capture.py credential incident: a deployment ran
# for hours on a 401 because the wrong bearer token was used. Since v0.7.0 the
# key lives in a 0600 file named by memory.api_key_file (spec §4.7) — the old
# advice, "Set HINDSIGHT_API_TENANT_API_KEY explicitly on the hook command",
# put the key on a command line any process listing shows, and must not come back.
@test "README documents the capture credential: the variable, the key file, that it is not the MCP token, and never the hook-command advice" {
  run grep -qF "HINDSIGHT_API_TENANT_API_KEY" "$DAEDALUS_HOME/README.md"; [ "$status" -eq 0 ]
  run grep -qF "memory.api_key_file" "$DAEDALUS_HOME/README.md"; [ "$status" -eq 0 ]
  run grep -q "different credential" "$DAEDALUS_HOME/README.md"; [ "$status" -eq 0 ]
  run grep -q "explicitly on the hook command" "$DAEDALUS_HOME/README.md"; [ "$status" -ne 0 ]
}

# The recall-inject example is the one hook line that still takes the key as a
# prefix in this release. It must read the key from the file at run time, never
# carry a literal key, and must not claim to share the memory: block it cannot read.
@test "README never shows the key typed on a hook command line; its recall-inject example carries no prefixes, because the injector reads the memory: block" {
  run grep -nE 'HINDSIGHT_API_TENANT_API_KEY=[^"$ \\]' "$DAEDALUS_HOME/README.md"
  [ "$status" -ne 0 ] || { echo "key typed on a command line: $output"; return 1; }
  run grep -qF '"command": "python3 /path/to/daedalus/core/recall-inject.py"' "$DAEDALUS_HOME/README.md"; [ "$status" -eq 0 ]
  run grep -q 'TENANT_BANK=daedalus TRANSCRIPT_DIR=/path/to/daedalus/transcripts python3 /path/to/daedalus/core/recall-inject.py' "$DAEDALUS_HOME/README.md"; [ "$status" -ne 0 ]
  run grep -q "cannot read the \`memory:\` block yet" "$DAEDALUS_HOME/README.md"; [ "$status" -ne 0 ]
}

@test "runtime-evaluated PEP 604 unions carry the future import (3.9 deployments)" {
  # `X | None` in a def signature COMPILES under 3.9 but raises TypeError at
  # import time unless the file has `from __future__ import annotations`.
  # A compile sweep is blind to it (found live on the 3.9 deployment,
  # 2026-08-31: capture.py killed capture, close, and recall-inject at once).
  cd "$DAEDALUS_HOME"
  bad=""
  for f in core/*.py; do
    if grep -qE '\| None|None \|' "$f"; then
      grep -q 'from __future__ import annotations' "$f" || bad="$bad $f"
    fi
  done
  [ -z "$bad" ] || { echo "PEP 604 unions without the future import:$bad"; return 1; }
}

# Spec §4.7 "Logs", D7 as amended 2026-10-14 (the operator's ruling): a session log is
# named by date and one global counter per vault (YYYY-MM-DD-NNN.md), reserved
# in the lease file at session start and read with `core/lease.sh log` — never
# counted from a directory listing, and never the window number, which lives in
# the frontmatter. The templates carry the lease fields the log's frontmatter
# needs, and hot.md holds a copy of the lease board (leases:) rather than
# mirroring a session number.
@test "CLAUDE.md names session logs by date and the global counter, hands the path out with lease.sh log, and the templates carry lease fields" {
  run grep -q 'YYYY-MM-DD-NNN.md' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -q 'YYYY-MM-DD-<NN>.md' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -ne 0 ]
  run grep -q 'core/lease.sh log' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -q 'YYYY-MM-DD-NN.md\|YYYY-MM-DD-prime.md' "$DAEDALUS_HOME/CLAUDE.md" "$DAEDALUS_HOME/core/templates/session.md"; [ "$status" -ne 0 ]
  run grep -q '## Continued HH:MM' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -q '^lease: ' "$DAEDALUS_HOME/core/templates/session.md"; [ "$status" -eq 0 ]
  run grep -q '^lease-created: ' "$DAEDALUS_HOME/core/templates/session.md"; [ "$status" -eq 0 ]
  run grep -q '^leases: ' "$DAEDALUS_HOME/core/templates/hot.md"; [ "$status" -eq 0 ]
  run grep -q '^session: ' "$DAEDALUS_HOME/core/templates/hot.md"; [ "$status" -ne 0 ]
}

# Spec §4.2, §4.3, §4.6, §4.7: the operator-facing summary of windows, the
# board, the stop-once warning and the pen lives in the distribution docs —
# in plain language, with a window example an operator can read as a number
# ("window 02"), the command that drives it, and the one sanctioned vault
# commit. Task 19 (plan 1 of 5).
@test "CLAUDE.md, README and CHANGELOG describe windows, the board, the stop-once warning and the prime — in plain language" {
  for f in CLAUDE.md README.md; do
    run grep -q 'window 0' "$DAEDALUS_HOME/$f"; [ "$status" -eq 0 ] || { echo "$f lacks a window example"; return 1; }
    run grep -q 'core/lease.sh' "$DAEDALUS_HOME/$f"; [ "$status" -eq 0 ] || { echo "$f does not name core/lease.sh"; return 1; }
  done
  run grep -q 'prime' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -q 'core/vault-commit.sh' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -q '^## v0.7.0 — ' "$DAEDALUS_HOME/CHANGELOG.md"; [ "$status" -eq 0 ]
}

# Spec §4.7: the operator-facing summary of incremental capture (plan 2 of 5).
@test "README, CLAUDE.md and CHANGELOG describe Stop-cadence capture, the memory: block and close.sh's in-flight wait" {
  for s in 'memory:' 'core/capture-tick.sh' 'capture_interval' 'still in flight' '--transcript'; do
    run grep -qF -- "$s" "$DAEDALUS_HOME/README.md"; [ "$status" -eq 0 ] || { echo "README lacks $s"; return 1; }
  done
  run grep -qF 'core/close.sh' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -qF 'still in flight' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -qF 'Incremental capture' "$DAEDALUS_HOME/CHANGELOG.md"; [ "$status" -eq 0 ]
  run grep -qF 'incremental capture (plan 2)' "$DAEDALUS_HOME/CHANGELOG.md"; [ "$status" -ne 0 ]
}

@test "VERSION is one line, 0.9.0; the wide scan reads VERSION and docs/, which publish (spec §14)" {
  [ "$(cat "$DAEDALUS_HOME/VERSION")" = "0.9.0" ]
  [ "$(wc -l < "$DAEDALUS_HOME/VERSION" | tr -d ' ')" = 1 ]
  _make_fixture_repo
  mkdir -p "$fixture/docs"
  printf 'A note about running the fleet on this host.\n' > "$fixture/docs/handoff.md"
  git -C "$fixture" add -A
  run _run_scan_in_fixture
  [ "$status" -ne 0 ] || { echo "a leak in docs/ passed the scan"; return 1; }
  _make_fixture_repo
  printf 'atlas\n' > "$fixture/VERSION"
  git -C "$fixture" add -A
  run _run_scan_in_fixture
  [ "$status" -ne 0 ] || { echo "a leak in VERSION passed the scan"; return 1; }
}

# Spec §4.11, §5, §14: the operator speaks in intents and never sees tool output, so the window repeats, translates,
# and messages its peers by these rules; a deployment takes a release by pulling, and upgrades at its next start.
@test "CLAUDE.md carries the operator's vocabulary, the verbatim rule and the rules for messaging other windows; README says how a deployment upgrades" {
  flat() { tr '\n' ' ' < "$1" | tr -s ' '; }
  CM="$(flat "$DAEDALUS_HOME/CLAUDE.md")"; RM="$(flat "$DAEDALUS_HOME/README.md")"
  for s in '## What the operator says, and what you run' 'word for word' 'window 02 (poc-ui)' 'core/lease.sh alias 03' \
           'core/lease.sh note 03' 'core/lease.sh claim 02' 'core/lease.sh spawn "' 'core/lease.sh done <NN> --summary' \
           'Pivot: this window now works on' 'the pen is taken, never given' 'Say that to window 02, or close it first.' \
           'core/lease.sh adopt <branch>' 'signed "— the reviewer"' '## Messages between windows' 'SendMessage' \
           'Never message to ask permission' 'do not edit it' 'not an instruction' 'core/upgrade.py --dry-run' \
           'This is window 02. My work is ready to promote' 'The operator asked you to take the pen' 'will hit it when you run the gates' \
           'core.hooksPath' 'Close every Daedalus window, then type `daedalus update` in a terminal.' \
           'CLAUDE.local.md' 'boundary.edit_brief: true' 'never edit CLAUDE.md' 'core/promote.sh 02 --clean' \
           'a session holding no window, or a shell: pushed promotions only' \
           'run `core/lease.sh unpromoted 02` first' 'the unpromoted commits and any uncommitted files' \
           'it ends with the line `Say yes to delete window 02'"'"'s work.`' 'Never run `release` with `--remove`' \
           'run `core/lease.sh release 02 --remove --force --operator-said "<their whole reply>"` exactly so' \
           'ask for a one-word yes and carry that' 'never write a yes the operator did not give'; do
    case "$CM" in *"$s"*) : ;; *) echo "CLAUDE.md lacks: $s"; return 1 ;; esac
  done
  # 2026-10-15: the agent runs the delete after the yes; the "give the operator the line to run" fallback is gone
  for s in 'give the operator the line to run' '! core/lease.sh release 02 --remove --force' 'If the permission system refuses'; do
    case "$CM" in *"$s"*) echo "CLAUDE.md still hands the operator a shell line: $s"; return 1 ;; *) : ;; esac
  done
  # v0.7.3: a release arrives by daedalus update, typed by the operator with every window closed, not by a pull a session runs
  for s in 'A new release reaches you as a pull'; do
    case "$CM" in *"$s"*) echo "CLAUDE.md still says: $s"; return 1 ;; *) : ;; esac
  done
  for s in '## Upgrading' 'state/upgraded-to' 'core/upgrade.py --dry-run' 'uncommitted changes' 'core/lease.sh adopt <branch>' \
           'cat VERSION' 'makes the window directories' '`adopt <branch>`' 'core.hooksPath' 'the address this checkout records for its branch' \
           'Deleting a window'"'"'s work is report, yes, delete.' 'Bash(core/lease.sh release:*)' 'autoMode.classifyAllShell' \
           'state/evidence/deletions/' '### Letting Daedalus edit its own brief' '"$defaults"' 'the classifier never reads `autoMode` from a project' \
           'daedalus update' 'Daedalus updated 0.7.3 -> 0.7.4; doctor OK.' 'Daedalus is up to date (0.7.4).' '~/.local/bin/daedalus update' \
           'Close every Daedalus window, then run the first-update line from the Daedalus README' '### The local layer' \
           'CLAUDE.local.md' '.claude/settings.local.json' 'boundary.edit_brief' 'local/before-update-<stamp>' 'state/update-backups/<stamp>/' \
           'update.address' 'uv sync --frozen' 'installs the daedalus command' 'Editing CLAUDE.local.md in the Daedalus home' \
           'core/promote.sh NN --clean'; do
    case "$RM" in *"$s"*) : ;; *) echo "README lacks: $s"; return 1 ;; esac
  done
  # v0.7.3: the stash recipe and the note about editing CLAUDE.md in place are gone; the local layer replaces them
  for s in 'git stash push -m local-changes' '### Letting Daedalus edit its own CLAUDE.md' 'A deployment that modified a tracked file' \
           'Editing CLAUDE.md in the Daedalus home'; do
    case "$RM" in *"$s"*) echo "README still says: $s"; return 1 ;; *) : ;; esac
  done
}

# Companion handoff §2-§5, plan 5 Task 12 (Decision 19): the reverse-caller handoff ships for the callee, generic —
# the wide scan above reads docs/, so no deployment, agent or person is named in it.
@test "docs/handoff-reverse-caller.md ships for the callee: the version predicate, what it exposes with a check each, what the pull changes and how the upgrade runs, the two states that need a person, what the calling agent builds, the callers list, the checks before the pull, the predicates V0-V11, and the rule" {
  D="$DAEDALUS_HOME/docs/handoff-reverse-caller.md"
  [ -f "$D" ]
  flat="$(tr '\n' ' ' < "$D" | tr -s ' ')"
  for s in 'cat <daedalus-home>/VERSION' 'git -C <daedalus-home> describe --tags --abbrev=0' '--callee self --caller' \
           'direct_call.callers' 'DIRECT_CALL_ID' 'CAPTURE_DEFER_TO_CALLER=1' 'The launcher is the only sanctioned entry' \
           'core/upgrade.py' 'uncommitted changes' 'untracked files' 'core.hooksPath' 'never changes another tool' \
           'promote.release_note' 'Check the exit code and a non-empty answer' \
           'is not under the' 'V0' 'V6b' 'V11' 'Nothing from this handoff lands in the target'; do
    case "$flat" in *"$s"*) : ;; *) echo "the handoff lacks: $s"; return 1 ;; esac
  done
}

# v0.7.3 (daedalus update; the upgrade that can finish): the release a deployment on a second machine reported,
# written for the same operator — the house parts in order, the one line it prints, the first update's one
# line and one sentence, and short sentences; no employer and no agent is named (the wide scan checks the file).
# v0.7.5 (the lease board stays drawn when git is slow): the report from the deployment on a second machine, written
# for the operator — the house parts in order, the board's new lines and the command they name; no employer, agent or
# proposal number.
@test "CHANGELOG: v0.7.5, below v0.8.0 — its heading verbatim; in short, what went wrong, what changed, what you will see, how to take it, how to tell; the board's new lines and core/lease.sh list; short sentences; v0.7.4 right below it" {
  [ "$(grep '^## v[0-9.]* — ' "$DAEDALUS_HOME/CHANGELOG.md" | sed -n 3p)" = "## v0.7.5 — the lease board stays drawn when git is slow" ]
  sec="$(awk '/^## v0.7.5 /{f=1; next} /^### In detail/{if (f) exit} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md")"
  rel="$(printf '%s\n' "$sec" | tr '\n' ' ' | tr -s ' ')"
  order=""
  for h in '**In short.**' '**What went wrong.**' '**What changed.**' '**What you will see.**' '**How to take it.**' '**How to tell you have it.**'; do
    case "$rel" in *"$h"*) : ;; *) echo "the v0.7.5 section lacks: $h"; return 1 ;; esac
    order="$order$(printf '%s' "$rel" | awk -v h="$h" '{print index($0, h)}') "
  done
  [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ] || { echo "the v0.7.5 parts are out of order: $order"; return 1; }
  for s in 'a Daedalus deployment on a second machine' 'state/leases/unpromoted.cache' 'not checked for unpromoted work this' \
           'at least N unpromoted commits waiting' '`core/lease.sh list`' 'A commit with an empty message now counts as unpromoted work' \
           'daedalus update' 'Daedalus updated 0.7.4 -> 0.7.5; doctor OK.' '`cat VERSION` prints `0.7.5`'; do
    case "$rel" in *"$s"*) : ;; *) echo "the v0.7.5 section lacks: $s"; return 1 ;; esac
  done
  ! printf '%s\n' "$sec" | grep -qiE 'smartsheet|employer' || { echo "the v0.7.5 section names an employer"; return 1; }
  ! printf '%s\n' "$sec" | grep -qwiE 'wren|bill|clara' || { echo "the v0.7.5 section names an agent"; return 1; }
  ! printf '%s\n' "$sec" | grep -qE 'PROP-[0-9]|EX-[0-9]' || { echo "the v0.7.5 section names a proposal number"; return 1; }
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$rel"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.7.5 section:"; echo "$output"; return 1; }
  [ "$(grep '^## v[0-9.]* — ' "$DAEDALUS_HOME/CHANGELOG.md" | sed -n 4p)" = "## v0.7.4 — every session can close and commit, and the update keeps a deployment's own vault" ]
}

# v0.7.4 (a session holding no window can still close): written for the operator, the house parts in order, what a
# windowless session now does at its close and the commands it names; no employer, agent or proposal number.
@test "CHANGELOG: v0.7.4, below v0.7.5 — its heading verbatim; in short, what went wrong, what changed, what you will see, how to take it, how to tell; the close commands it names; short sentences; v0.7.3 right below it" {
  grep -qxF "## v0.7.4 — every session can close and commit, and the update keeps a deployment's own vault" "$DAEDALUS_HOME/CHANGELOG.md"
  sec="$(awk '/^## v0.7.4 /{f=1; next} /^### In detail/{if (f) exit} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md")"
  rel="$(printf '%s\n' "$sec" | tr '\n' ' ' | tr -s ' ')"
  order=""
  for h in '**In short.**' '**What went wrong.**' '**What changed.**' '**What you will see.**' '**How to take it.**' '**How to tell you have it.**'; do
    case "$rel" in *"$h"*) : ;; *) echo "the v0.7.4 section lacks: $h"; return 1 ;; esac
    order="$order$(printf '%s' "$rel" | awk -v h="$h" '{print index($0, h)}') "
  done
  [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ] || { echo "the v0.7.4 parts are out of order: $order"; return 1; }
  for s in 'core/lease.sh log' 'core/lease.sh prime take' 'hot.md' 'core/vault-commit.sh' 'state/leases/unwindowed.json' \
           'never takes the pen from a live' 'daedalus update' 'Daedalus updated 0.7.3 -> 0.7.4; doctor OK.' '`cat VERSION` prints `0.7.4`'; do
    case "$rel" in *"$s"*) : ;; *) echo "the v0.7.4 section lacks: $s"; return 1 ;; esac
  done
  ! printf '%s\n' "$sec" | grep -qiE 'smartsheet|employer' || { echo "the v0.7.4 section names an employer"; return 1; }
  ! printf '%s\n' "$sec" | grep -qwiE 'wren|bill|clara' || { echo "the v0.7.4 section names an agent"; return 1; }
  ! printf '%s\n' "$sec" | grep -qE 'PROP-[0-9]|EX-[0-9]' || { echo "the v0.7.4 section names a proposal number"; return 1; }
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$rel"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.7.4 section:"; echo "$output"; return 1; }
  [ "$(grep '^## v[0-9.]* — ' "$DAEDALUS_HOME/CHANGELOG.md" | sed -n 5p)" = "## v0.7.3 — one command updates Daedalus, and the upgrade no longer outgrows its safety copy" ]
}

@test "CLAUDE.md says how a session holding no window closes: its log number at start and from lease.sh log, the pen when no live session holds it, lease: none in the frontmatter, and the close order" {
  CM="$(tr '\n' ' ' < "$DAEDALUS_HOME/CLAUDE.md" | tr -s ' ')"
  for s in 'A session holding no window may take the pen when no live session holds it' \
           'A session holding no window is told its number at start' 'lease: none' \
           '`core/lease.sh log` → `core/lease.sh prime take` (when no live session holds the pen) → `hot.md` (only if this session holds the pen) → `core/close.sh`.'; do
    case "$CM" in *"$s"*) : ;; *) echo "CLAUDE.md lacks: $s"; return 1 ;; esac
  done
}

@test "the close commits: CLAUDE.md's Memory paragraph and close order, README's close.sh entry and the v0.7.4 part say core/close.sh commits the vault, --no-commit skips it, a dead session's pen moves on, exit 3 and exit 4; no employer, agent or proposal number; short sentences" {
  CM="$(tr '\n' ' ' < "$DAEDALUS_HOME/CLAUDE.md" | tr -s ' ')"
  for s in 'At the end of a working session run `core/close.sh`: it waits until the server confirms the session was stored, then commits the vault.' \
           'If another live session holds the pen, it says so in one line and leaves the commit to that session' \
           "if the pen's holder has ended, this session takes the pen and commits." '`--no-commit` skips the commit.' \
           'If it exits 4, the session is recorded but the vault commit did not run' 'then run `core/vault-commit.sh`' \
           'A pen whose session has ended moves to the next session that commits the vault; one held by a live session never moves without `prime take` and the operator' \
           '→ `hot.md` (only if this session holds the pen) → `core/close.sh`.'; do
    case "$CM" in *"$s"*) : ;; *) echo "CLAUDE.md lacks: $s"; return 1 ;; esac
  done
  case "$CM" in *'core/close.sh --commit'*) echo "CLAUDE.md still teaches --commit"; return 1 ;; esac
  RM="$(tr '\n' ' ' < "$DAEDALUS_HOME/README.md" | tr -s ' ')"
  for s in 'then commits the vault' '`--no-commit`' 'exits 3' 'exits 4' 'takes the pen and commits'; do
    case "$RM" in *"$s"*) : ;; *) echo "README lacks: $s"; return 1 ;; esac
  done
  sec="$(awk '/^## v0.7.4 /{f=1; next} /^### In detail/{if (f) exit} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md")"
  rel="$(printf '%s\n' "$sec" | tr '\n' ' ' | tr -s ' ')"
  for s in '**The close commits.**' '`core/close.sh` commits the vault now; `--commit` is no longer needed.' '`--no-commit`'; do
    case "$rel" in *"$s"*) : ;; *) echo "the v0.7.4 section lacks: $s"; return 1 ;; esac
  done
  ! printf '%s\n' "$sec" | grep -qwiE 'wren|bill|clara|smartsheet' || { echo "names an agent or employer"; return 1; }
  ! printf '%s\n' "$sec" | grep -qE 'PROP-[0-9]|EX-[0-9]' || { echo "names a proposal number"; return 1; }
}

@test "CHANGELOG: v0.7.3, below v0.7.4 — in short, what went wrong, what changed, what you will see, the first update, how to tell; it thanks a deployment on a second machine, gives the one first-update line and the sentence for a local agent, and keeps every sentence to 30 words" {
  grep -qxF "## v0.7.3 — one command updates Daedalus, and the upgrade no longer outgrows its safety copy" "$DAEDALUS_HOME/CHANGELOG.md"
  sec="$(awk '/^## v0.7.3 /{f=1; next} /^### In detail/{if (f) exit} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md")"
  rel="$(printf '%s\n' "$sec" | tr '\n' ' ' | tr -s ' ')"
  order=""
  for h in '**In short.**' '**What went wrong.**' '**What changed.**' '**What you will see.**' '**The first update.**' '**How to tell you have it.**'; do
    case "$rel" in *"$h"*) : ;; *) echo "the v0.7.3 section lacks: $h"; return 1 ;; esac
    order="$order$(printf '%s' "$rel" | awk -v h="$h" '{print index($0, h)}') "
  done
  [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ] || { echo "the v0.7.3 parts are out of order: $order"; return 1; }
  for s in 'a Daedalus deployment on a second machine' 'daedalus update' 'Daedalus updated 0.7.2 -> 0.7.3; doctor OK.' \
           'Daedalus is up to date (0.7.3).' 'CLAUDE.local.md' '.claude/settings.local.json' 'boundary.edit_brief' \
           'local/before-update-' 'state/update-backups/' 'uv sync --frozen' 'core/promote.sh NN --clean' 'core/gates.sh' \
           '~/.local/bin/daedalus' 'Close every Daedalus window, then run the first-update line from the Daedalus README' \
           'Upgrade to 0.7.3: complete.' '`cat VERSION` prints `0.7.3`' 'mods/lease-board/tsconfig.json'; do
    case "$rel" in *"$s"*) : ;; *) echo "the v0.7.3 section lacks: $s"; return 1 ;; esac
  done
  printf '%s\n' "$sec" | grep -qxF '(f="$(mktemp)" && { git -C ~/daedalus fetch -q https://github.com/lpelty/daedalus.git main && git -C ~/daedalus show FETCH_HEAD:core/update.py >"$f"; } 2>/dev/null || { echo "Not updated: could not fetch the update from github.com/lpelty/daedalus. Nothing in this home was changed." >&2; rm -f "$f"; exit 1; }; python3 "$f" update --home ~/daedalus; s=$?; rm -f "$f"; exit $s)' \
    || { echo "the v0.7.3 section lacks the first-update line on a line of its own"; return 1; }
  ! printf '%s\n' "$sec" | grep -qiE 'smartsheet|employer' || { echo "the v0.7.3 section names an employer"; return 1; }
  ! printf '%s\n' "$sec" | grep -qwiE 'wren|bill|clara' || { echo "the v0.7.3 section names an agent"; return 1; }
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$rel"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.7.3 section:"; echo "$output"; return 1; }
  # v0.7.2 sits right below it
  [ "$(grep '^## v[0-9.]* — ' "$DAEDALUS_HOME/CHANGELOG.md" | sed -n 6p)" = "## v0.7.2 — the vault index rebuilds itself; deleting a window's work and keeping the journal are the agent's again" ]
}

@test "CHANGELOG: v0.7.2, below v0.7.3, keeps its trunk parts under In detail; v0.7.1 below it — a one-line headline for the tag, then, in short plain sentences, what went wrong, what changed, what you will see, how to take it, and how to tell; the v0.7.0 section below it keeps its shape: what changes, what the first session after the pull shows, what the windows are, how a change reaches trunk, the one paste, what to do if the upgrade stops, and how to tell; In detail below; nothing left unreleased" {
  grep -qxF "## v0.7.2 — the vault index rebuilds itself; deleting a window's work and keeping the journal are the agent's again" "$DAEDALUS_HOME/CHANGELOG.md"
  # v0.7.2 (the routine steps are the agent's again): the same six parts in order, the autoMode line, short sentences
  rel="$(awk '/^## v0.7.2 /{f=1; next} /^### In detail/{if (f) exit} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')"
  order=""
  for h in '**In short.**' '**What went wrong.**' '**What changed.**' '**What you will see.**' '**How to take it.**' '**How to tell you have it.**'; do
    case "$rel" in *"$h"*) : ;; *) echo "the v0.7.2 section lacks: $h"; return 1 ;; esac
    order="$order$(printf '%s' "$rel" | awk -v h="$h" '{print index($0, h)}') "
  done
  [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ] || { echo "the v0.7.2 parts are out of order: $order"; return 1; }
  for s in '[Interfere With Workloads]' '[Self-Modification]' 'Bash(core/lease.sh release:*)' "Say yes to delete window 02's work." \
           '"autoMode"' '"$defaults"' '~/.claude/settings.json' 'git pull --ff-only' 'git stash push -m local-changes CLAUDE.md' \
           'e1b349e' 'Upgrade to 0.7.2: complete.' 'upgrade: state/upgraded-to 0.7.2' '`cat VERSION` prints `0.7.2`'; do
    case "$rel" in *"$s"*) : ;; *) echo "the v0.7.2 section lacks: $s"; return 1 ;; esac
  done
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$rel"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.7.2 section:"; echo "$output"; return 1; }
  det="$(awk '/^## v0.7.2 /{f=1; next} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md")"
  for s in '#### The document index rebuilds itself' '#### The routine steps run by the agent, not the operator'; do
    case "$det" in *"$s"*) : ;; *) echo "v0.7.2's In detail lacks: $s"; return 1 ;; esac
  done
  ! grep -q '^#### .*after the v0.7.1 tag' "$DAEDALUS_HOME/CHANGELOG.md"
  ! grep -q '^#### .*2026-10-15' "$DAEDALUS_HOME/CHANGELOG.md"
  # v0.7.1 (the lease board on 2.1.300): the same operator reads it, in the same parts and the same short sentences
  fix="$(awk '/^## v0.7.1 /{f=1; next} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')"
  order=""
  for h in '**In short.**' '**What went wrong.**' '**What changed.**' '**What you will see.**' '**How to take it.**' '**How to tell you have it.**'; do
    case "$fix" in *"$h"*) : ;; *) echo "the v0.7.1 section lacks: $h"; return 1 ;; esac
    order="$order$(printf '%s' "$fix" | awk -v h="$h" '{print index($0, h)}') "
  done
  [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ] || { echo "the v0.7.1 parts are out of order: $order"; return 1; }
  for s in 'engine node under a Box with prop "width"' 'git pull --ff-only' 'no `claude plugin install` to run again' '/reload-plugins' \
           'Upgrade to 0.7.1: complete.' 'upgrade: state/upgraded-to 0.7.1' '`cat VERSION` prints `0.7.1`'; do
    case "$fix" in *"$s"*) : ;; *) echo "the v0.7.1 section lacks: $s"; return 1 ;; esac
  done
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$fix"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.7.1 section:"; echo "$output"; return 1; }
  # v0.7.0, the release below it, as it was
  grep -q '^## v0.7.0 — numbered windows, promote, the direct-call launcher, incremental capture, and an upgrade that runs itself$' "$DAEDALUS_HOME/CHANGELOG.md"
  flat="$(tr '\n' ' ' < "$DAEDALUS_HOME/CHANGELOG.md" | tr -s ' ')"
  for s in 'git pull --ff-only' 'core/upgrade.py --dry-run' 'uncommitted changes' 'promote.release_note' 'cat VERSION' \
           'upgrade: state/upgraded-to 0.7.0' 'core/lease.sh adopt' 'docs/handoff-reverse-caller.md' 'core/tests/scenarios/two-clones.sh'; do
    case "$flat" in *"$s"*) : ;; *) echo "CHANGELOG lacks: $s"; return 1 ;; esac
  done
  # The top section is for an operator with no engineering background (critic finding 6): its parts in this order,
  # short plain sentences, the one paste and the stops each in a part of their own, 'In detail' kept below.
  top="$(awk '/^## v0.7.0 /{f=1; next} /^### In detail/{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')"
  order=""
  for h in '**In short.**' '**What you will see at the first session after the pull.**' '**What the windows are.**' \
           '**How a change reaches trunk now.**' '**One paste into config.yaml, by the operator.**' '**If the upgrade stops.**' \
           '**How to tell you have it.**'; do
    case "$top" in *"$h"*) : ;; *) echo "the top section lacks: $h"; return 1 ;; esac
    order="$order$(printf '%s' "$top" | awk -v h="$h" '{print index($0, h)}') "
  done
  [ "$(printf '%s\n' $order | sort -n | tr '\n' ' ')" = "$order" ] || { echo "the parts are out of order: $order"; return 1; }
  for s in 'you say yes' '`core/doctor.sh` shows them as one paste' 'Nothing else is done by hand.' 'start a new session' 'commit them on their branch'; do
    case "$top" in *"$s"*) : ;; *) echo "the top section lacks: $s"; return 1 ;; esac
  done
  grep -q '^### In detail' "$DAEDALUS_HOME/CHANGELOG.md"
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$top"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the top section:"; echo "$output"; return 1; }
  # the same guard over each dated part added under v0.7.0 after the tag ("#### Added on trunk after the v0.7.0 tag — ..."):
  # it is written for the same operator (review 2026-10-11, finding 24)
  part="$(awk '/^#### Added on trunk after the v0.7.0 tag/{f=1} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')"
  [ -n "$part" ] || { echo "no dated part under v0.7.0"; return 1; }
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$part"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the dated part:"; echo "$output"; return 1; }
  ! grep -q '^## Unreleased' "$DAEDALUS_HOME/CHANGELOG.md"
  ! grep -qi 'not yet in this release' "$DAEDALUS_HOME/CHANGELOG.md"
}

@test "CHANGELOG: a session left open through the pull is told to restart unconditionally, and told that a config.yaml Stop reason after the upgrade is the upgrade's own change, not something to restore — the hook's sentence quoted as the hook says it (plan 5 Task 13 review)" {
  flat="$(tr '\n' ' ' < "$DAEDALUS_HOME/CHANGELOG.md" | tr -s ' ')"
  # the old promise: a Stop asks for the restart only when the upgrade wrote config.yaml, and then it says restore first
  case "$flat" in *"Stop asks for exactly that"*) echo "CHANGELOG still promises the old session's Stop asks for a restart"; return 1 ;; esac
  for s in 'Close and reopen any session that was open through the pull; it is still running the old hooks.' \
           'do not restore the file'; do
    case "$flat" in *"$s"*) : ;; *) echo "CHANGELOG lacks: $s"; return 1 ;; esac
  done
  # the quoted Stop sentence is the one the boundary hook really emits for the release's own change (critic finding 7)
  q='config.yaml changed under this session, by'
  case "$flat" in *"$q"*) : ;; *) echo "CHANGELOG does not quote the hook's sentence"; return 1 ;; esac
  grep -qF "$q" "$DAEDALUS_HOME/core/boundary-hook.py"
  # and CLAUDE.md's "Taking a release" tells the agent the same: do not restore it; the operator starts a new session
  sec="$(awk '/^\*\*Taking a release\.\*\*/{f=1} f&&/^## /{exit} f' "$DAEDALUS_HOME/CLAUDE.md" | tr '\n' ' ' | tr -s ' ')"
  for s in "$q" 'do not restore it' 'start a new session'; do
    case "$sec" in *"$s"*) : ;; *) echo "'Taking a release' lacks: $s"; return 1 ;; esac
  done
}

@test "README's upgrade section and CLAUDE.md's 'Taking a release' name the untracked-files stop with its remedy, worded as core/upgrade.py's UNTRACKED says it, and README no longer calls the uncommitted-changes stop the only one (plan 5 Decision 25; Task 14 review)" {
  remedy='move them out of that checkout, or commit them on its branch'
  # the remedy the docs quote is the one the upgrade really says
  said="$(cd "$DAEDALUS_HOME/core" && python3 -c 'import upgrade; print(upgrade.UNTRACKED)')"
  case "$said" in *"has untracked files that"*"$remedy"*) : ;; *) echo "upgrade.py's UNTRACKED no longer says: $remedy"; return 1 ;; esac
  RM="$(tr '\n' ' ' < "$DAEDALUS_HOME/README.md" | tr -s ' ')"
  CM="$(tr '\n' ' ' < "$DAEDALUS_HOME/CLAUDE.md" | tr -s ' ')"
  case "$RM" in *"The one thing it will not do is move a target checkout with uncommitted"*) echo "README still says uncommitted changes are the only stop"; return 1 ;; esac
  for f in README CLAUDE; do
    [ "$f" = README ] && flat="$RM" || flat="$CM"
    for s in 'untracked files' "$remedy"; do
      case "$flat" in *"$s"*) : ;; *) echo "$f.md lacks: $s"; return 1 ;; esac
    done
  done
  # CLAUDE.md's sentence sits in "Taking a release", not elsewhere
  sec="$(awk '/^\*\*Taking a release\.\*\*/{f=1} f&&/^## /{exit} f' "$DAEDALUS_HOME/CLAUDE.md" | tr '\n' ' ' | tr -s ' ')"
  case "$sec" in *'untracked files'*"$remedy"*) : ;; *) echo "'Taking a release' lacks the untracked-files stop"; return 1 ;; esac
}

# A release never ships a file under a path a deployment keeps as its own (vault/, state/, target/, worktrees/):
# a home that tracks its vault takes releases by merging, and a release file there would conflict with it.
@test "the distribution tracks no file its own .gitignore ignores, and nothing under vault/, state/, target/ or worktrees/" {
  run git -C "$DAEDALUS_HOME" ls-files -ci --exclude-standard
  [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "tracked yet ignored: $output"; return 1; }
  run git -C "$DAEDALUS_HOME" ls-files -- vault state target worktrees
  [ "$status" -eq 0 ]; [ -z "$output" ] || { echo "tracked under a deployment's paths: $output"; return 1; }
}

@test "a home that keeps its vault in its own repository: README's Upgrading section says the update merges, carries .gitignore's own lines and keeps the branch's own remote, and how a release arrives there; the v0.7.4 part says it in plain words; the first line is the result" {
  UP="$(awk '/^## Upgrading/{f=1; next} /^## /{if (f) exit} f' "$DAEDALUS_HOME/README.md" | tr '\n' ' ' | tr -s ' ')"
  for s in 'A home that keeps its vault in its own repository' 'merges the release into its branch' "keeps the home's history" \
           "this home's own lines" '.gitignore' 'keeps following its own remote' \
           "In a home that tracks its vault in its own repository, \`daedalus update\` is the way a release arrives; \`git pull\` pulls that home's own remote." \
           'The first line is the result' 'state/update-refused.txt' 'local/before-update-' 'mirror'; do
    case "$UP" in *"$s"*) : ;; *) echo "README Upgrading lacks: $s"; return 1 ;; esac
  done
  grep -qF "git describe --tags --abbrev=0 --match 'v[0-9]*'" "$DAEDALUS_HOME/README.md"
  sec="$(awk '/^## v0.7.4 /{f=1; next} /^### In detail/{if (f) exit} /^## /{if (f) exit} f' "$DAEDALUS_HOME/CHANGELOG.md")"
  rel="$(printf '%s\n' "$sec" | tr '\n' ' ' | tr -s ' ')"
  for s in '**A home that keeps its vault in its own repository.**' 'merges' 'Not updated:' 'state/update-refused.txt' '.gitignore'; do
    case "$rel" in *"$s"*) : ;; *) echo "the v0.7.4 section lacks: $s"; return 1 ;; esac
  done
  ! printf '%s\n' "$sec" | grep -qwiE 'wren|bill|clara|smartsheet' || { echo "names an agent or employer"; return 1; }
  ! printf '%s\n' "$sec" | grep -qE 'PROP-[0-9]|EX-[0-9]|\bB[0-9]\b|\bA[0-9]\b' || { echo "names a proposal number or step code"; return 1; }
}

@test "frame-jack is documented: README has the Frame-jack section with the install, the config paste, weights by hand and the doctor lines; CLAUDE.md has the two operator rows and the gates paragraph; config.example.yaml has the ami: block with every key; CHANGELOG has v0.8.0 below v0.9.0 and above v0.7.5 saying shadow and naming the bar; none names the company or a section code" {
  H="$DAEDALUS_HOME"
  # README: the section, after "Direct calls", with its parts
  grep -qF '## Frame-jack (the AMI)' "$H/README.md" || { echo "README lacks the Frame-jack section"; return 1; }
  dc="$(grep -n '^## Direct calls' "$H/README.md" | head -1 | cut -d: -f1)"
  fj="$(grep -n '^## Frame-jack (the AMI)' "$H/README.md" | head -1 | cut -d: -f1)"
  [ "$fj" -gt "$dc" ] || { echo "the Frame-jack section is not after Direct calls"; return 1; }
  rsec="$(awk '/^## Frame-jack \(the AMI\)/{f=1; print; next} f&&/^## /{exit} f' "$H/README.md")"
  for s in '### Install' 'uv venv --python 3.12' "[mlx]" 'mlx-lm<0.33' '### The config paste' 'ami:' \
           '### The switch' '/frame-jack on' '/frame-jack off' '/frame-jack status' '### What shadow means' \
           '0.95' '0.85' '400 ms' '### Weights by hand' 'tar -czf' 'blobs/6c/' 'blobs/47/' 'offline: true' \
           'a laptop behind a corporate proxy' 'not yet run there' '### Doctor' 'frame-jack weights:' \
           'ask_destructive: false' 'ask_suite: true' 'frame-jack questions:' 'frame-jack: device mps' 'default device'; do
    case "$rsec" in *"$s"*) : ;; *) echo "README's Frame-jack section lacks: $s"; return 1 ;; esac
  done
  # CLAUDE.md: the two operator rows, after "Pick it up", and the paragraph under "Gates and evidence"
  grep -qF '| "/frame-jack on" / "frame-jack off"' "$H/CLAUDE.md" || { echo "CLAUDE.md lacks the on/off row"; return 1; }
  grep -qF '| "Is frame-jack on?"' "$H/CLAUDE.md" || { echo "CLAUDE.md lacks the is-it-on row"; return 1; }
  pk="$(grep -n '^| "Pick it up"' "$H/CLAUDE.md" | cut -d: -f1)"
  ro="$(grep -n '^| "/frame-jack on" / "frame-jack off"' "$H/CLAUDE.md" | cut -d: -f1)"
  [ "$ro" -gt "$pk" ] || { echo "the AMI rows are not after Pick it up"; return 1; }
  rows="$(grep -E '^\| "(/frame-jack on|Is frame-jack on\?)"' "$H/CLAUDE.md")"
  for s in 'python3 core/frame-jack.py on' 'python3 core/frame-jack.py off' 'word for word' 'status' \
           'ask them to type `/frame-jack on`'; do
    case "$rows" in *"$s"*) : ;; *) echo "the CLAUDE.md rows lack: $s"; return 1 ;; esac
  done
  gsec="$(awk '/^## Gates and evidence/{f=1; next} f&&/^## /{exit} f' "$H/CLAUDE.md" | tr '\n' ' ' | tr -s ' ')"
  for s in 'logged opinion' 'changes nothing you do' 'state/ami/' 'not yours to write'; do
    case "$gsec" in *"$s"*) : ;; *) echo "CLAUDE.md's Gates and evidence lacks: $s"; return 1 ;; esac
  done
  # config.example.yaml: the block with every key, comments on their own lines, enforce commented out
  csec="$(awk '/^# ami:/{f=1} f' "$H/config.example.yaml")"
  [ -n "$csec" ] || { echo "config.example.yaml lacks the ami: block"; return 1; }
  for k in command model device port offline weights_cache battery_off request_timeout_ms ask_destructive ask_suite enforce; do
    printf '%s\n' "$csec" | grep -qE "^#   (# )?$k:" || { echo "the ami: block lacks: $k"; return 1; }
  done
  printf '%s\n' "$csec" | grep -qE '^#   # enforce:' || { echo "enforce is not commented out"; return 1; }
  printf '%s\n' "$csec" | grep -qE '^#   command: /' || { echo "command is not an absolute placeholder"; return 1; }
  # CHANGELOG: v0.8.0, the second release heading, below v0.9.0 and above v0.7.5; its
  # shadow sentence and the bar; how it arrives is daedalus update, and nothing moves until /frame-jack on
  [ "$(grep '^## v[0-9.]* — ' "$H/CHANGELOG.md" | sed -n 2p)" = "## v0.8.0 — frame-jack, a switch for the AMI" ] \
    || { echo "CHANGELOG's second released section is not frame-jack's v0.8.0"; return 1; }
  [ "$(grep '^## v[0-9.]* — ' "$H/CHANGELOG.md" | sed -n 3p)" = "## v0.7.5 — the lease board stays drawn when git is slow" ]
  ! grep -q '^#### .*frame-jack' "$H/CHANGELOG.md" || { echo "a frame-jack part is still dated under an older release"; return 1; }
  ch="$(awk '/^## v0.8.0 — frame-jack/{f=1; print; next} f&&/^## /{exit} f' "$H/CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')"
  for s in 'shadow' 'never acts' '0.95' '0.60' '0.15' '0.85' '0.05' '400 ms' 'Daedalus updated 0.7.5 -> 0.8.0; doctor OK.' 'daedalus update' 'ask_destructive' 'off by default' \
           'downloads nothing for the AMI'; do
    case "$ch" in *"$s"*) : ;; *) echo "the CHANGELOG part lacks: $s"; return 1 ;; esac
  done
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$ch"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.8.0 section:"; echo "$output"; return 1; }
  # none of the four names the company, and none carries a spec section code
  for t in "$rsec" "$rows" "$gsec" "$csec" "$ch"; do
    ! printf '%s' "$t" | grep -qi 'smartsheet' || { echo "the company is named"; return 1; }
    ! printf '%s' "$t" | grep -qE '§[0-9]' || { echo "a section code in operator-facing text: $(printf '%s' "$t" | grep -oE '.{30}§[0-9]+.{0,10}' | head -1)"; return 1; }
  done
}

@test "code context is documented: CLAUDE.md's Code context section names core/context.py, runs it only at implementation time in the words of the design, and has Daedalus add rules with a test and report them; the operator row; README's section after Direct calls; CHANGELOG v0.9.0 the newest release above v0.8.0; no company, no section code, short CHANGELOG sentences" {
  H="$DAEDALUS_HOME"
  gs="$(grep -n '^## Gates and evidence' "$H/CLAUDE.md" | cut -d: -f1)"
  cc="$(grep -n '^## Code context' "$H/CLAUDE.md" | cut -d: -f1)"
  pr="$(grep -n '^## Promote' "$H/CLAUDE.md" | cut -d: -f1)"
  [ -n "$cc" ] && [ "$cc" -gt "$gs" ] && [ "$cc" -lt "$pr" ] || { echo "CLAUDE.md's Code context section is not between Gates and evidence and Promote"; return 1; }
  csec="$(awk '/^## Code context/{f=1; next} f&&/^## /{exit} f' "$H/CLAUDE.md" | tr '\n' ' ' | tr -s ' ')"
  for s in 'python3 core/context.py callers <file>::<function>' 'importers <file>' 'grep "<text>"' '--json' \
           'both, graph only, grep only, or rule:<name>' \
           'Run it in your window when you are about to change code' \
           'That is the only time it runs on its own initiative.' \
           'No hook calls it, nothing runs it at session start, and nothing refreshes it in the background' \
           'While brainstorming, planning or writing a spec, run it only when the operator asks you to.' \
           'Never run `code-review-graph` yourself' 'candidates, not answers' 'state/code-context/misses.jsonl' \
           'unasked' 'vault/context-rules.json' 'with an origin (date, window, why) and a test' \
           'python3 core/context.py rules --check' 'A rule can only add candidates.' 'You need no approval' \
           'Added code-context rule <name>: <why>; its test passes.' 'session log'; do
    case "$csec" in *"$s"*) : ;; *) echo "CLAUDE.md's Code context section lacks: $s"; return 1 ;; esac
  done
  row="$(grep -F '| "What does this change touch?"' "$H/CLAUDE.md")"
  for s in 'python3 core/context.py reach <X>' 'word for word' 'during planning, it is the operator asking'; do
    case "$row" in *"$s"*) : ;; *) echo "the operator row lacks: $s"; return 1 ;; esac
  done
  dc="$(grep -n '^## Direct calls' "$H/README.md" | head -1 | cut -d: -f1)"
  rc="$(grep -n '^## Code context (`core/context.py`)' "$H/README.md" | head -1 | cut -d: -f1)"
  fj="$(grep -n '^## Frame-jack (the AMI)' "$H/README.md" | head -1 | cut -d: -f1)"
  [ -n "$rc" ] && [ "$rc" -gt "$dc" ] && [ "$rc" -lt "$fj" ] || { echo "README's Code context section is not right after Direct calls"; return 1; }
  rsec="$(awk '/^## Code context \(`core\/context.py`\)/{f=1; print; next} f&&/^## /{exit} f' "$H/README.md")"
  for s in '### Install' 'uv venv --python 3.12' "code-review-graph==2.3.9" 'code-review-graph 2.3.9' 'context:' \
           'never register its MCP server' 'install' 'init' 'register' 'daemon' 'watch' 'better-code-review-graph' \
           'only when' 'state/code-context/' 'core/context-rules.json' 'vault/context-rules.json' 'only add' \
           'Code context:' 'misses.jsonl' 'rules --check' 'NOTE     code context:' 'OK       code context:'; do
    case "$rsec" in *"$s"*) : ;; *) echo "README's Code context section lacks: $s"; return 1 ;; esac
  done
  [ "$(grep -m1 '^## ' "$H/CHANGELOG.md")" = "## v0.9.0 — code context at build time: a code graph and grep together, and a log of what they missed" ] \
    || { echo "CHANGELOG's first section is not v0.9.0"; return 1; }
  [ "$(grep '^## v[0-9.]* — ' "$H/CHANGELOG.md" | sed -n 2p)" = "## v0.8.0 — frame-jack, a switch for the AMI" ]
  ! grep -q '^## v[0-9.]* (draft) — ' "$H/CHANGELOG.md" || { echo "a draft section is left in the CHANGELOG"; return 1; }
  # the body only: the heading carries no full stop, so it would join the first sentence
  ch="$(awk '/^## v0.9.0 — /{f=1; next} f&&/^## /{exit} f' "$H/CHANGELOG.md" | tr '\n' ' ' | tr -s ' ')"
  for s in '**In short.**' '**What changed.**' '**What you will see.**' '**How to take it.**' '**How to tell you have it.**' \
           'core/context.py' 'brainstorm' 'code-review-graph' '2.3.9' 'optional' 'daedalus update' 'Code context:' \
           'Daedalus updated 0.8.0 -> 0.9.0; doctor OK.' '`cat VERSION` prints `0.9.0`'; do
    case "$ch" in *"$s"*) : ;; *) echo "the CHANGELOG v0.9.0 section lacks: $s"; return 1 ;; esac
  done
  run python3 -c 'import re, sys
text = re.sub(r"`[^`]*`", "X", sys.argv[1])
long = [s.strip() for s in re.split(r"(?<=[.!?:;])\s+", text) if len(s.split()) > 30]
print("\n".join(long)); sys.exit(1 if long else 0)' "$ch"
  [ "$status" -eq 0 ] || { echo "sentences over 30 words in the v0.9.0 section:"; echo "$output"; return 1; }
  for t in "$csec" "$row" "$rsec" "$ch"; do
    ! printf '%s' "$t" | grep -qi 'smartsheet' || { echo "the company is named"; return 1; }
    ! printf '%s' "$t" | grep -qE '§[0-9]' || { echo "a section code in operator-facing text: $(printf '%s' "$t" | grep -oE '.{30}§[0-9]+.{0,10}' | head -1)"; return 1; }
  done
}
