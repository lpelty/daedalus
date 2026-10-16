# core/tests/fixtures/context/setup.bash — loaded by test_context*.bats (code-context design §16).
# Builds on lease_fixture: a home whose target thing (outer repo) has a nested repo sub. Adds a small
# Python package and its non-Python wiring, committed and pushed, so a window cut from main has them:
#   pkg/core.py            the subject most tests ask about (def helper)
#   pkg/user.py            from pkg.core import helper; helper()        a .py caller
#   pkg/other.py           from pkg import core                         an importer by name only
#   tools/run.sh           python3 -m pkg.core                          a .sh caller
#   templates/job.md.tmpl  python3 {{APP}}/pkg/core.py                  a template
#   tests/test_core.py     from pkg.core import helper                  a test
#   README.md              the word helper, in prose
#   sub/agent.py           from pkg.core import helper                  in the nested repo
# and, after the commit, in whatever tree `dirt` is given:
#   pkg/new_user.py        import pkg.core          untracked (git grep --untracked finds it)
#   build/ignored.py       import pkg.core; helper  ignored (nothing finds it)
load fixtures/leases/setup.bash

context_fixture() {
  lease_fixture
  local f
  for f in context.py context-rules.json; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DAEDALUS_HOME/core/"
  done
  CX="$DAEDALUS_HOME/core/context.py"
  T="$DAEDALUS_HOME/target/thing"
  mkdir -p "$T/pkg" "$T/tools" "$T/templates" "$T/tests"
  : > "$T/pkg/__init__.py"
  printf 'def helper():\n    return 1\n' > "$T/pkg/core.py"
  printf 'from pkg.core import helper\n\nhelper()\n' > "$T/pkg/user.py"
  printf 'from pkg import core\n' > "$T/pkg/other.py"
  printf '#!/bin/bash\npython3 -m pkg.core "$@"\n' > "$T/tools/run.sh"
  printf 'Run: python3 {{APP}}/pkg/core.py\n' > "$T/templates/job.md.tmpl"
  printf 'from pkg.core import helper\n\n\ndef test_helper():\n    assert helper() == 1\n' > "$T/tests/test_core.py"
  printf 'The helper lives in pkg.\n' > "$T/README.md"
  printf 'build/\n' >> "$T/.gitignore"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m pkg; git -C "$T" push -q origin main
  printf 'from pkg.core import helper\n' > "$T/sub/agent.py"
  git -C "$T/sub" add -A; git -C "$T/sub" -c user.email=t@x -c user.name=t commit -q -m agent; git -C "$T/sub" push -q origin main
  dirt "$T"
  export CX T
  unset DIRECT_CALL_ID DAEDALUS_TARGET_OVERRIDE
}

# dirt <tree> — the untracked and the ignored file, in that tree.
dirt() {
  mkdir -p "$1/build"
  printf 'import pkg.core\n' > "$1/pkg/new_user.py"
  printf 'import pkg.core\nhelper()\n' > "$1/build/ignored.py"
}

# window_02 — window 02 bound to session sC: worktrees cut from main in both repos, the lease file
# written directly (lease.sh create is not under test here). W is its outer checkout.
window_02() {
  W="$DAEDALUS_HOME/worktrees/02/thing"
  git -C "$T" worktree add -q -b lease/02 "$W" main
  git -C "$T/sub" worktree add -q -b lease/02 "$W/sub" main
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 \
    '{"lease":"02","session_id":"sC","worktree":"worktrees/02","branch":"lease/02","created":"2026-10-16T10:00:00","trunks":{"thing":"main","thing/sub":"main"}}'
  : > "$DAEDALUS_HOME/state/leases/.lock"     # as lease.sh create leaves it (every lease read opens it)
  dirt "$W"
  export W
}
as_window() { env CLAUDE_CODE_SESSION_ID=sC "$@"; }

# files_of — the file column of a plain answer: every line between the header and the closing line,
# label stripped, ":<line>" and anything after it dropped; sorted.
files_of() {
  printf '%s\n' "$output" | sed '1d' | grep -E '^(both|graph only|grep only|rule:[a-z0-9-]+) ' \
    | sed -E 's/^(both|graph only|grep only|rule:[a-z0-9-]+) +//; s/[: ].*$//' | sort
}
# expect_files <file>... — files_of is exactly these.
expect_files() {
  local want; want="$(printf '%s\n' "$@" | sort)"
  [ "$(files_of)" = "$want" ] || { echo "want:"; echo "$want"; echo "got:"; files_of; echo "--- output:"; echo "$output"; return 1; }
}
# state_listing — every path under state/ (to prove a run wrote nothing there).
state_listing() { (cd "$DAEDALUS_HOME/state" && find . | sort); }

# use_fake_graph [graph_budget] [build_timeout] — a copy of the fake code-review-graph (and its canned
# 2.3.9 answers) under $BATS_TEST_TMPDIR/crg/, named in a context: block of config.yaml. CRG_LOG is its
# call log; crg_knob NAME=value sets one of its knobs (fake-crg.env).
use_fake_graph() {
  CRG_DIR="$BATS_TEST_TMPDIR/crg/bin"; mkdir -p "$CRG_DIR"
  cp "$BATS_TEST_DIRNAME/fixtures/context/fake-code-review-graph" "$CRG_DIR/code-review-graph"
  cp -R "$BATS_TEST_DIRNAME/fixtures/context/crg-2.3.9" "$CRG_DIR/crg-2.3.9"
  : > "$CRG_DIR/fake-crg.env"; CRG_LOG="$CRG_DIR/fake-crg.log"; : > "$CRG_LOG"
  {
    printf 'context:\n'
    printf '  graph: %s\n' "$CRG_DIR/code-review-graph"
    [ -z "${1:-}" ] || printf '  graph_budget: %s\n' "$1"
    [ -z "${2:-}" ] || printf '  build_timeout: %s\n' "$2"
  } >> "$DAEDALUS_HOME/config.yaml"
  export CRG_DIR CRG_LOG
}
crg_knob() { printf '%s\n' "$1" >> "$CRG_DIR/fake-crg.env"; }
# crg_verbs — the subcommand of every logged call, in order, one per line.
crg_verbs() { grep '^argv ' "$CRG_LOG" | awk '{print $2}'; }
