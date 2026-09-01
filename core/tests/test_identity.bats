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
  # "bill" — the agent's own name — is included separately below with a
  # word-boundary match: as a bare regex alternative it would also match
  # "billing", "billion", and "William", none of which are identity leaks,
  # so it can't share the unbounded pattern the other tokens use safely.
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
    if grep -qwiE "bill" "$f"; then
      offenders="$offenders $f(bill)"
    fi
  done <<EOF
$(git ls-files -- core .claude CLAUDE.md SOUL.md README.md config.example.yaml)
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
# for hours on a 401 because the wrong bearer token was used and the
# fallback .env path does not resolve in Daedalus's layout. Two distinct
# assertions so a partial deletion (e.g. keeping the env var name but
# dropping the explicit-setup sentence) still fails this test.
@test "README documents the capture.py credential requirement" {
  run grep -qF "HINDSIGHT_API_TENANT_API_KEY" "$DAEDALUS_HOME/README.md"
  [ "$status" -eq 0 ]
  run grep -q "Set .HINDSIGHT_API_TENANT_API_KEY. explicitly on the hook command" "$DAEDALUS_HOME/README.md"
  [ "$status" -eq 0 ]
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
