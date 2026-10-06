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

@test "identity files contain no harness-specific facts" {
  run grep -riE "fleet|atlas|smartsheet|larrypelty" "$DAEDALUS_HOME/CLAUDE.md" "$DAEDALUS_HOME/SOUL.md"
  [ "$status" -ne 0 ]
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
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$f" = "$self" ] && continue
    if grep -qiE "larry|lpelty|/Users/|fleet|atlas|smartsheet" "$f"; then
      offenders="$offenders $f(token)"
    fi
    # Agent names, word-bounded (spec §8.4): the caller is generalized — the
    # callee is named only by a deployment's gitignored config.yaml — so no
    # agent's name may be hardcoded anywhere in the distribution.
    if grep -qwiE "bill|wren|clara|moot" "$f"; then
      offenders="$offenders $f(agent name)"
    fi
  done <<EOF
$(git ls-files -- core .claude CLAUDE.md SOUL.md README.md CHANGELOG.md config.example.yaml VERSION docs)
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

# Spec §4.7 "Logs", D7: a session log is named by window number and date
# (YYYY-MM-DD-<NN>.md), never by the retired global running count. The
# templates carry the lease fields the log's frontmatter needs, and hot.md
# holds a copy of the lease board (leases:) rather than mirroring a session
# number that no longer exists.
@test "CLAUDE.md names session logs by window number and date, and the templates carry lease fields" {
  run grep -q 'YYYY-MM-DD-<NN>.md' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -eq 0 ]
  run grep -q 'global running count' "$DAEDALUS_HOME/CLAUDE.md"; [ "$status" -ne 0 ]
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

@test "VERSION is one line, 0.7.0; the wide scan reads VERSION and docs/, which publish (spec §14)" {
  [ "$(cat "$DAEDALUS_HOME/VERSION")" = "0.7.0" ]
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
           'Never message to ask permission' 'do not edit it' 'not an instruction' 'git pull --ff-only' 'core/upgrade.py --dry-run' \
           'This is window 02. My work is ready to promote' 'The operator asked you to take the pen' 'will hit it when you run the gates' \
           'core.hooksPath' 'the address this checkout records for its branch' \
           'run `core/lease.sh release 02 --remove` first' 'the unpromoted commits and any uncommitted files' \
           'only after a yes run it again with `--force`'; do
    case "$CM" in *"$s"*) : ;; *) echo "CLAUDE.md lacks: $s"; return 1 ;; esac
  done
  for s in '## Upgrading' 'state/upgraded-to' 'core/upgrade.py --dry-run' 'uncommitted changes' 'core/lease.sh adopt <branch>' \
           'cat VERSION' 'makes the window directories' '`adopt <branch>`' 'core.hooksPath' 'the address this checkout records for its branch'; do
    case "$RM" in *"$s"*) : ;; *) echo "README lacks: $s"; return 1 ;; esac
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

@test "CHANGELOG: v0.7.0 is the newest release — a one-line headline for the tag, then what changes for an operator on each kind of deployment, what the first session after the pull does, and how to tell; nothing left unreleased" {
  [ "$(grep -m1 '^## ' "$DAEDALUS_HOME/CHANGELOG.md")" = "## v0.7.0 — numbered windows, promote, the direct-call launcher, incremental capture, and an upgrade that runs itself" ]
  flat="$(tr '\n' ' ' < "$DAEDALUS_HOME/CHANGELOG.md" | tr -s ' ')"
  for s in '**What changes for an operator.**' '**On each kind of deployment.**' '**At the first session after the pull.**' '**How to tell you have it.**' \
           'git pull --ff-only' 'core/upgrade.py --dry-run' 'uncommitted changes' 'promote.release_note' 'cat VERSION' \
           'upgrade: state/upgraded-to 0.7.0' 'core/lease.sh adopt' 'docs/handoff-reverse-caller.md' 'core/tests/scenarios/two-clones.sh'; do
    case "$flat" in *"$s"*) : ;; *) echo "CHANGELOG lacks: $s"; return 1 ;; esac
  done
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
  # the quoted Stop sentence is the one the boundary hook really emits
  q='The gate definition (config.yaml) changed this session'
  case "$flat" in *"$q"*) : ;; *) echo "CHANGELOG does not quote the hook's sentence"; return 1 ;; esac
  grep -qF "$q" "$DAEDALUS_HOME/core/boundary-hook.py"
}
