#!/usr/bin/env bats
# Review lenses and the findings ledger (v0.12.3). A large change is reviewed by several fresh reviewers at once,
# each through one lens, their findings merged; every window's branch carries a ledger of the findings earlier
# reviews counted, so a re-review checks those first and hunts fresh only in what changed since.

bats_require_minimum_version 1.5.0

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  mkdir -p "$DAEDALUS_HOME/core/agents" "$DAEDALUS_HOME/target/thing"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cp "$SRC/lib.sh" "$SRC/gates.sh" "$SRC/manifest-append.py" "$SRC/refute.sh" "$SRC/fingerprint.sh" "$SRC/agentdef.py" \
     "$SRC/refute-pitfalls.py" "$SRC/pitfall-inject.py" "$SRC/verifylib.py" "$SRC/leaselib.py" "$SRC/call-agent.sh" \
     "$SRC/call_agent.py" "$SRC/distcheck.py" "$SRC/review-lenses.py" "$DAEDALUS_HOME/core/"
  cp "$SRC/agents/refuter.md" "$DAEDALUS_HOME/core/agents/"
  export DAEDALUS_HOME
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$BATS_TEST_TMPDIR/sessions"
  printf 'target/\nvault/\nstate/\nworktrees/\nconfig.yaml\n__pycache__/\n*.pyc\n' > "$DAEDALUS_HOME/.gitignore"
  git init -q -b main "$DAEDALUS_HOME"
  git -C "$DAEDALUS_HOME" add -A
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m fixture
  T="$DAEDALUS_HOME/target/thing"
  echo "marker" > "$T/marker.txt"
  git init -q -b main "$T"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git -C "$T" checkout -q -b lease/03
  STUB="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB"
  stub_claude
}

# write_config [verify-lines] — lenses at 50 lines or 10 files, so a fixture can be large without being slow.
write_config() {
  cat > "$DAEDALUS_HOME/config.yaml" <<EOF
target:
  repo: https://example.com/thing.git
  branch: main
gates:
  - true
verify:
  refute: true
  lens_lines: 50
  lens_files: 10
${1:-}
EOF
}

# stub_claude — the reviewer. Each call reads its prompt, finds its lens ("Your lens: <name>", else "all"), saves
# the prompt as prompt-<lens>-<n>, and prints out-<lens> (or out-all, or a bare STANDS). sleep-<lens> makes that
# lens hang past the timeout.
stub_claude() {
  cat > "$STUB/claude" <<STUB
#!/usr/bin/env bash
p="\$(mktemp)"; cat > "\$p"
lens="\$(sed -n 's/^Your lens: \([a-z0-9_]*\)\..*/\1/p' "\$p" | head -1)"; lens="\${lens:-all}"
n=1; while [ -e "$STUB/prompt-\$lens-\$n" ]; do n=\$((n + 1)); done
cp "\$p" "$STUB/prompt-\$lens-\$n"
[ -f "$STUB/sleep-\$lens" ] && sleep "\$(cat "$STUB/sleep-\$lens")"
if [ -f "$STUB/out-\$lens" ]; then cat "$STUB/out-\$lens"
elif [ -f "$STUB/out-all" ]; then cat "$STUB/out-all"
else printf 'Searched everything.\n\nVERDICT: STANDS\n'; fi
STUB
  chmod +x "$STUB/claude"
}

gates() { PATH="$STUB:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"; }
run_id() { printf '%s\n' "$output" | sed -n 's/^.*run-id: //p' | tail -1; }
small_change() { printf 'one\n' >> "$T/marker.txt"; }
large_change() { seq 1 120 > "$T/big.txt"; }
count_prompts() { ls "$STUB" | grep -c "^prompt-${1}-" || true; }

# lease_for <nn> [promoted-count] — a lease this session holds, so my-lease names it; a leased session's gates run in
# its window's checkout, so T moves there (once).
lease_for() {
  export DAEDALUS_SESSION_ID=s-lens
  mkdir -p "$DAEDALUS_HOME/state/leases" "$DAEDALUS_HOME/worktrees/$1"
  [ -d "$DAEDALUS_HOME/worktrees/$1/thing" ] || cp -R "$DAEDALUS_HOME/target/thing" "$DAEDALUS_HOME/worktrees/$1/thing"
  T="$DAEDALUS_HOME/worktrees/$1/thing"
  python3 - "$DAEDALUS_HOME/state/leases/$1.json" "${2:-0}" <<'PY'
import json, sys
out, n = sys.argv[1], int(sys.argv[2])
json.dump({"lease": out.rsplit("/", 1)[1][:2], "session_id": "s-lens", "created": "2026-10-19T09:00:00",
           "promoted": ["p%d" % i for i in range(n)], "branch": "lease/03"}, open(out, "w"))
PY
}

@test "a small change gets one reviewer, and the run says so and why" {
  write_config; small_change
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(count_prompts all)" -eq 1 ]
  ! grep -q '^Your lens:' "$STUB/prompt-all-1"
  printf '%s\n' "$output" | grep -q 'review: one reviewer — the change is small (1 line in 1 file' || { echo "$output"; return 1; }
}

@test "a large change gets one reviewer per lens, run in parallel, each told its lens; their findings are merged with duplicates made one, strongest labels kept" {
  write_config; large_change
  # Two lenses find the same defect at the same place with different labels; one finds something else.
  printf '### F1 — big.txt:7 — hypothetical — in scope — LOW — reach: user\nWhat is wrong: the trust view.\nInput: x.\nHow to confirm: y.\n\nVERDICT: STANDS\n' > "$STUB/out-trust"
  printf '### F1 — big.txt:7 — observed — in scope — HIGH — reach: user\nWhat is wrong: the failure view.\nInput: x.\nHow to confirm: y.\n\n### F2 — big.txt:9 — hypothetical — out of scope — LOW — reach: user\nWhat is wrong: other.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-failure"
  gates
  [ "$status" -ne 0 ]
  for l in criteria trust upgrade failure; do
    [ "$(count_prompts "$l")" -eq 1 ] || { echo "lens $l: $(ls "$STUB")"; return 1; }
  done
  [ "$(count_prompts all)" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'review: 4 lenses (criteria, trust, upgrade, failure) — the change is large (120 lines in 1 file; lenses from 50 lines or 10 files)' || { echo "$output"; return 1; }
  id="$(run_id)"; m="$DAEDALUS_HOME/vault/evidence/$id-review.md"
  [ -f "$m" ]
  # One finding at big.txt:7, with the strongest labels, naming both lenses; the other kept.
  [ "$(grep -c '^### F[0-9]* — big.txt:7 ' "$m")" -eq 1 ] || { cat "$m"; return 1; }
  grep -q '^### F[0-9]* — big.txt:7 — observed — in scope — HIGH — reach: user — found by: trust, failure' "$m" || { cat "$m"; return 1; }
  grep -q 'the trust view' "$m"; grep -q 'the failure view' "$m"
  grep -q '^### F[0-9]* — big.txt:9 — hypothetical — out of scope — LOW' "$m"
  # Each lens's own review is kept and manifested beside the merged one.
  for l in criteria trust upgrade failure; do
    [ -f "$DAEDALUS_HOME/vault/evidence/$id-lens-$l-review.md" ] || { ls "$DAEDALUS_HOME/vault/evidence"; return 1; }
    grep -qF "$DAEDALUS_HOME/vault/evidence/$id-lens-$l-review.md" "$DAEDALUS_HOME/vault/evidence/.manifest"
  done
  grep -qF "$m" "$DAEDALUS_HOME/vault/evidence/.manifest"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  # The verdict re-read from the merged file is the run's.
  run bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$m"
  [ "$status" -eq 1 ]
}

@test "large: all lenses STAND with nothing counted, the run stands; the lenses run at the same time" {
  write_config; large_change
  for l in criteria trust upgrade failure; do echo 2 > "$STUB/sleep-$l"; done
  start=$(date +%s)
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(count_prompts criteria)" -eq 1 ]
  # Four 2-second reviewers in series take 8 seconds; at once, about 2 plus the launcher's own time.
  [ $(( $(date +%s) - start )) -lt 7 ] || { echo "took $(( $(date +%s) - start ))s"; return 1; }
}

@test "a lens that times out fails the run closed, naming the lens; a partial review never stands" {
  write_config "  refute_timeout: 2"; large_change
  echo 30 > "$STUB/sleep-upgrade"
  gates
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'the upgrade lens: refuter timed out after 2s' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -qi 'cannot certify' || { echo "$output"; return 1; }
  # The lenses that finished are kept and manifested, not left unaccounted for under vault/evidence.
  grep -qF "$DAEDALUS_HOME/vault/evidence/$(run_id)-lens-criteria-review.md" "$DAEDALUS_HOME/vault/evidence/.manifest"
  id="$(run_id)"
  [ "$(grep -c '"result": "FAIL"' "$DAEDALUS_HOME/state/evidence/$id/run.json")" -eq 1 ]
  [ ! -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
}

@test "a lens whose review cannot be certified (an unlabelled finding) fails the run closed" {
  write_config; large_change
  printf '### F1 — big.txt:1 — HIGH\nWhat is wrong: x.\n\nVERDICT: STANDS\n' > "$STUB/out-criteria"
  gates
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'the criteria lens: review findings without their labels' || { echo "$output"; return 1; }
}

@test "the lens set and thresholds come from config; a bad lens name is refused before any reviewer runs" {
  write_config "  lenses: correctness, speed"; large_change
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(count_prompts correctness)" -eq 1 ]; [ "$(count_prompts speed)" -eq 1 ]
  [ "$(count_prompts trust)" -eq 0 ]
  grep -q '^Your lens: speed\. ' "$STUB/prompt-speed-1"
  rm -f "$STUB"/prompt-*
  write_config "  lenses: ok, Bad Name"
  gates
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'verify.lenses' || { echo "$output"; return 1; }
  [ "$(ls "$STUB" | grep -c '^prompt-')" -eq 0 ]
}

@test "ledger: a second run is told the findings the first counted, checks them first, and hunts fresh only in what changed since" {
  lease_for 03; write_config; small_change
  git -C "$T" -c user.email=t@x -c user.name=t commit -qam first
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user\nWhat is wrong: the second line is wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-all"
  gates
  [ "$status" -ne 0 ]
  first="$(run_id)"
  led="$DAEDALUS_HOME/state/review-ledger/03.json"
  [ -f "$led" ]
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); f=d['findings']; assert len(f)==1 and f[0]['id']=='L1' and f[0]['status']=='open', d" "$led"
  # The fix, and a new file; the reviewer says L1 is resolved and finds nothing new.
  printf 'fresh\n' > "$T/new.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -qm second
  printf 'Checked L1.\nResolved: L1\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  p="$STUB/prompt-all-2"
  grep -q '^## Earlier findings on this branch' "$p"
  grep -q 'L1 — marker.txt:2 — observed — in scope — HIGH — reach: user — the second line is wrong' "$p"
  grep -q "^## Changed since the last review (run $first)" "$p"
  # The fresh-hunt section holds the new file and not the first run's change.
  sec="$(awk '/^## Changed since the last review/{f=1; next} /^## /{f=0} f' "$p")"
  printf '%s\n' "$sec" | grep -q 'new.txt' || { echo "$sec"; return 1; }
  ! printf '%s\n' "$sec" | grep -q 'marker.txt'
  printf '%s\n' "$output" | grep -q 'review: 1 earlier finding: 1 resolved, 0 open' || { echo "$output"; return 1; }
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['findings'][0]['status']=='resolved', d" "$led"
}

@test "ledger: an earlier finding the review neither resolves nor reports again is carried into the verdict" {
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user\nWhat is wrong: wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-all"
  gates; [ "$status" -ne 0 ]
  printf 'Nothing.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  printf 'two\n' >> "$T/marker.txt"
  gates
  [ "$status" -ne 0 ]
  id="$(run_id)"
  grep -q '^### F[0-9]* — marker.txt:2 — observed — in scope — HIGH — reach: user — carried L1' "$DAEDALUS_HOME/vault/evidence/$id-review.md" \
    || { cat "$DAEDALUS_HOME/vault/evidence/$id-review.md"; return 1; }
  printf '%s\n' "$output" | grep -q 'review: 1 earlier finding: 0 resolved, 1 open' || { echo "$output"; return 1; }
}

@test "ledger: a finding its fix broke (regressed) refutes whatever its labels; one reported again keeps its id" {
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user\nWhat is wrong: wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-all"
  gates; [ "$status" -ne 0 ]
  printf 'two\n' >> "$T/marker.txt"
  printf '### F1 — marker.txt:3 — hypothetical — in scope — LOW — reach: user — regressed L1\nWhat is wrong: the fix broke the third line.\nInput: x.\nHow to confirm: y.\n\nResolved: L1\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  led="$DAEDALUS_HOME/state/review-ledger/03.json"
  python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); f={x['id']: x for x in d['findings']}
assert f['L1']['status']=='open', d" "$led"
}

@test "ledger and refutation count start again when the window promotes or its lease is new" {
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user\nWhat is wrong: wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-all"
  gates; [ "$status" -ne 0 ]
  lease_for 03 1          # promoted since
  printf 'Nothing.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^## Earlier findings' "$STUB/prompt-all-2"
  ! grep -q '^## Changed since the last review' "$STUB/prompt-all-2"
}

@test "lenses and ledger together: each lens gets the earlier findings; a re-report by any lens keeps it open over another's Resolved" {
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user\nWhat is wrong: wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-all"
  gates; [ "$status" -ne 0 ]
  rm -f "$STUB/out-all"
  large_change
  printf 'Resolved: L1\n\nVERDICT: STANDS\n' > "$STUB/out-criteria"
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user — earlier L1\nWhat is wrong: still wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-trust"
  printf 'Resolved: L1\n\nVERDICT: STANDS\n' > "$STUB/out-upgrade"
  printf 'Resolved: L1\n\nVERDICT: STANDS\n' > "$STUB/out-failure"
  gates
  [ "$status" -ne 0 ]
  for l in criteria trust upgrade failure; do grep -q 'L1 — marker.txt:2' "$STUB/prompt-$l-1"; done
  printf '%s\n' "$output" | grep -q 'review: 1 earlier finding: 0 resolved, 1 open' || { echo "$output"; return 1; }
}

@test "the boundary hook excuses a manifested lens review by its run's record, like the run's merged review" {
  mkdir -p "$DAEDALUS_HOME/state/evidence/20261019-120000-abcdef" "$DAEDALUS_HOME/vault/evidence"
  printf '{"run_id": "20261019-120000-abcdef", "result": "PASS"}\n' > "$DAEDALUS_HOME/state/evidence/20261019-120000-abcdef/run.json"
  cp "$SRC/boundary-hook.py" "$DAEDALUS_HOME/core/"
  run python3 - "$DAEDALUS_HOME" <<'PY'
import importlib.util, sys
from pathlib import Path
root = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("bh", str(root / "core" / "boundary-hook.py"))
bh = importlib.util.module_from_spec(spec); spec.loader.exec_module(bh)
ok = lambda name: bh._sanctioned_evidence(root, "vault/evidence/" + name, {str((root / "vault/evidence" / name).resolve())})
assert ok("20261019-120000-abcdef-lens-trust-review.md"), "lens review not excused"
assert ok("20261019-120000-abcdef-review.md")
assert not ok("20261019-999999-ffffff-lens-trust-review.md"), "a lens review for no run excused"
print("ok")
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- review 2026-10-19 (fresh-context, under the labelled bar) ------------------------------------------------------

refute_l1() {
  printf '### F1 — marker.txt:2 — observed — in scope — HIGH — reach: user\nWhat is wrong: wrong.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-all"
}

@test "review F1: a regression carried unchecked into a later review still refutes" {
  lease_for 03; write_config; small_change; refute_l1
  gates; [ "$status" -ne 0 ]
  printf 'two\n' >> "$T/marker.txt"
  printf '### F1 — marker.txt:3 — hypothetical — in scope — LOW — reach: user — regressed L1\nWhat is wrong: broke.\nInput: x.\nHow to confirm: y.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates; [ "$status" -ne 0 ]
  printf 'three\n' >> "$T/marker.txt"
  printf 'Nothing.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  id="$(run_id)"
  grep -q 'carried L1.*regressed L1' "$DAEDALUS_HOME/vault/evidence/$id-review.md" || { cat "$DAEDALUS_HOME/vault/evidence/$id-review.md"; return 1; }
}

@test "review F2: a lens that says REFUTED and names no labelled finding refutes the merged run" {
  write_config; large_change
  printf '1. The parser drops the last line.\n\nVERDICT: REFUTED\n' > "$STUB/out-criteria"
  gates
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  id="$(run_id)"
  grep -q 'unlabelled refutation by the criteria lens' "$DAEDALUS_HOME/vault/evidence/$id-review.md"
}

@test "review F3/F4: lenses re-reporting one earlier finding at different lines keep it open on the strongest; a new defect on a re-reported line gets its own id" {
  lease_for 03; write_config; small_change; refute_l1
  gates; [ "$status" -ne 0 ]
  rm -f "$STUB/out-all"; large_change
  printf '### F1 — big.txt:7 — observed — in scope — HIGH — reach: user — earlier L1\nWhat is wrong: still.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-trust"
  printf '### F1 — big.txt:8 — hypothetical — in scope — LOW — reach: user — earlier L1\nWhat is wrong: maybe.\nInput: x.\nHow to confirm: y.\n\nVERDICT: STANDS\n' > "$STUB/out-upgrade"
  printf '### F1 — big.txt:7 — observed — in scope — HIGH — reach: user\nWhat is wrong: a new defect.\nInput: x.\nHow to confirm: y.\n\nVERDICT: REFUTED\n' > "$STUB/out-failure"
  gates; [ "$status" -ne 0 ]
  python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); f={x['id']: x for x in d['findings']}
assert f['L1']['status']=='open' and f['L1']['severity']=='HIGH', d
assert 'L2' in f and f['L2']['what']=='a new defect.', d" "$DAEDALUS_HOME/state/review-ledger/03.json"
  printf '%s\n' "$output" | grep -q 'review: 1 earlier finding: 0 resolved, 1 open; 1 new' || { echo "$output"; return 1; }
}

@test "review F5: the first run says what it recorded; a run that gives no verdict says the earlier findings stay as they were" {
  lease_for 03; write_config "  refute_timeout: 2"; small_change; refute_l1
  gates; [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'review: 1 counted finding recorded for the next review to check' || { echo "$output"; return 1; }
  echo 30 > "$STUB/sleep-all"
  printf 'two\n' >> "$T/marker.txt"
  gates; [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'review: 1 earlier finding shown to the reviewers; the ledger is unchanged' || { echo "$output"; return 1; }
}

@test "review F7: verify.lens_concurrency is checked, and bounds how many lenses run at once" {
  write_config "  lens_concurrency: 00"; large_change
  gates; [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q 'verify.lens_concurrency must be' || { echo "$output"; return 1; }
  write_config "  lens_concurrency: 1"
  for l in criteria trust upgrade failure; do echo 1 > "$STUB/sleep-$l"; done
  start=$(date +%s)
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ $(( $(date +%s) - start )) -ge 4 ] || { echo "one at a time took $(( $(date +%s) - start ))s"; return 1; }
}

@test "--resume-review after a lens run names each lens's call instead of resuming one lens as if it were the review" {
  write_config; lease_for 03; large_change
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  PATH="$STUB:$PATH" run bash "$DAEDALUS_HOME/core/call-agent.sh" --resume-review 03 "why F1?"
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  case "$output" in *"Window 03's latest review (run "*") was 4 reviewers at once, one per lens: criteria "*", failure "*", trust "*", upgrade "*"core/call-agent.sh --resume <call-id>"*) : ;; *) echo "$output"; return 1 ;; esac
  # nothing was resumed: no reviewer ran past the four lenses
  [ "$(ls "$STUB" | grep -c '^prompt-')" -eq 4 ]
}

# --- v0.12.4: a later review refutes only on new ground; a broad first pass; live checks ---------------------------

# second_round <reviewer output> — run 1 refutes L1 at marker.txt:2 on a committed change; then a new file, committed,
# is the only change since; the reviewer of run 2 resolves L1 and prints <reviewer output> after it.
second_round() {
  lease_for 03; write_config; small_change
  git -C "$T" -c user.email=t@x -c user.name=t commit -qam first
  refute_l1; gates; [ "$status" -ne 0 ]
  seq 1 5 > "$T/new.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -qm second
  printf 'Resolved: L1\n\n%b\nVERDICT: STANDS\n' "$1" > "$STUB/out-all"
  gates
}
finding() {   # finding <file:line> <labels> — one finding block for second_round
  printf '### F1 — %s — %s\\nWhat is wrong: %s is wrong.\\nInput: x.\\nHow to confirm: y.\\n' "$1" "$2" "$1"
}

@test "new ground: a later run's new finding outside the change since the last review is labelled missed earlier, does not refute, and is kept as a backlog candidate" {
  second_round "$(finding marker.txt:1 'plausible — in scope — MEDIUM — reach: user')"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  id="$(printf '%s\n' "$output" | tail -1)"; m="$DAEDALUS_HOME/vault/evidence/$id-review.md"     # a PASS ends with its run-id
  grep -q '^new-ground: ' "$m" || { cat "$m"; return 1; }
  grep -q '^### F1 — marker.txt:1 — plausible — in scope — MEDIUM — reach: user — missed earlier' "$m" || { cat "$m"; return 1; }
  printf '%s\n' "$output" | grep -q 'backlog candidate.*missed earlier' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q 'review: kept in the ledger, not counted: 1 backlog candidate' || { echo "$output"; return 1; }
  python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); f=[x for x in d['findings'] if x['status']=='backlog']
assert len(f)==1 and f[0]['file']=='marker.txt' and f[0]['line']==1 and f[0].get('missed_earlier'), d" "$DAEDALUS_HOME/state/review-ledger/03.json"
  # A re-read gives the run's verdict.
  run bash "$DAEDALUS_HOME/core/refute.sh" --verdict-of "$m"; [ "$status" -eq 0 ]
}

@test "new ground: the same finding inside the change since the last review refutes; so does an observed HIGH with the data or trust flag outside it; an observed HIGH without a flag outside it does not" {
  second_round "$(finding new.txt:3 'plausible — in scope — MEDIUM — reach: user')"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ -f "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md" ]; ! grep -q '^### .*missed earlier' "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md" || { echo "$output"; cat "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md"; return 1; }
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/worktrees"; rm -f "$STUB"/prompt-*
  second_round "$(finding marker.txt:1 'observed — in scope — HIGH — reach: none — data')"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  grep -q 'reach: none — data — missed earlier' "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md"
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/worktrees"; rm -f "$STUB"/prompt-*
  second_round "$(finding marker.txt:1 'observed — in scope — HIGH — reach: user')"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "new ground: a finding whose place cannot be read counts as before; a reviewer's own 'missed earlier' label is not honoured" {
  second_round "### F1 — the whole design — plausible — in scope — MEDIUM — reach: user\nWhat is wrong: x.\nInput: x.\nHow to confirm: y.\n"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/worktrees"; rm -f "$STUB"/prompt-*
  second_round "$(finding new.txt:2 'plausible — in scope — MEDIUM — reach: user — missed earlier')"
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  # And on a first review, which the launcher writes itself, the label is the reviewer's and counts for nothing.
  rm -rf "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/vault" "$DAEDALUS_HOME/worktrees"; rm -f "$STUB"/prompt-*
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — plausible — in scope — MEDIUM — reach: user — missed earlier\nWhat is wrong: x.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
}

@test "a broad first pass: the first review of a branch is told to report every defect at once; a later review is not, and is told findings outside the new ground are missed earlier" {
  second_round "$(finding new.txt:1 'hypothetical — in scope — LOW — reach: none')"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  grep -q "^This is the branch's first full review: report every defect you find" "$STUB/prompt-all-1"
  ! grep -q "first full review" "$STUB/prompt-all-2"
  grep -q 'labelled missed earlier and does not refute' "$STUB/prompt-all-2"
}

@test "live checks: a live-only finding does not refute, is recorded in the ledger as a required live check, and the live verb lists it for promote" {
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — plausible — in scope — HIGH — reach: routine — live-only\nWhat is wrong: the scheduled job may not reach the service.\nInput: x.\nHow to confirm: run it.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q 'review: kept in the ledger, not counted: 1 live check' || { echo "$output"; return 1; }
  printf '%s\n' "$output" | grep -q '1 live check, not counted' || { echo "$output"; return 1; }
  run python3 "$DAEDALUS_HOME/core/review-lenses.py" live "$DAEDALUS_HOME" 03 lease/03
  [ "$status" -eq 0 ]
  python3 -c "
import json,sys; r=json.loads(sys.argv[1])
assert r==[{'id': 'L1', 'file': 'marker.txt', 'line': 2, 'what': 'the scheduled job may not reach the service.'}], r" "$output"
  # A second run that reports it again keeps one live check, not two.
  printf 'two\n' >> "$T/marker.txt"
  gates; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # The second reviewer is told the check is already kept (review 2026-10-20, round 2, F3).
  grep -q '^## Live checks already recorded on this branch' "$STUB/prompt-all-2" || { cat "$STUB/prompt-all-2"; return 1; }
  grep -q '^- L1 — marker.txt:2 — the scheduled job may not reach the service.' "$STUB/prompt-all-2"
  run python3 "$DAEDALUS_HOME/core/review-lenses.py" live "$DAEDALUS_HOME" 03 lease/03
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 1 ] || { echo "$output"; return 1; }
}

@test "review 2026-10-20 F4: new ground is numbered as the working tree the reviewer reads — a committed change below uncommitted lines added above it is still new ground" {
  lease_for 03; write_config; small_change; seq 1 30 > "$T/f.txt"
  git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -qm first
  refute_l1; gates; [ "$status" -ne 0 ]
  sed -i '' 's/^20$/twenty/' "$T/f.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -qam second
  { seq 101 110; cat "$T/f.txt"; } > "$T/f.new"; mv "$T/f.new" "$T/f.txt"      # uncommitted, above the commit's line
  printf 'Resolved: L1\n\n### F1 — f.txt:30 — plausible — in scope — MEDIUM — reach: user\nWhat is wrong: twenty.\nInput: x.\nHow to confirm: y.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates
  [ "$status" -ne 0 ] || { echo "$output"; return 1; }
  [ -f "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md" ]; ! grep -q '^### .*missed earlier' "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md" || { echo "$output"; cat "$DAEDALUS_HOME/vault/evidence/$(run_id)-review.md"; return 1; }
}

@test "review 2026-10-20 F5: a live check reported again in other words at the same place stays one live check" {
  lease_for 03; write_config; small_change
  printf '### F1 — marker.txt:2 — plausible — in scope — HIGH — reach: routine — live-only\nWhat is wrong: the job may not reach the service.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'two\n' >> "$T/marker.txt"
  printf '### F1 — marker.txt:2 — plausible — in scope — HIGH — reach: routine — live-only\nWhat is wrong: whether the scheduled job reaches the service is unknown.\n\nVERDICT: STANDS\n' > "$STUB/out-all"
  gates; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run python3 "$DAEDALUS_HOME/core/review-lenses.py" live "$DAEDALUS_HOME" 03 lease/03
  [ "$(printf '%s' "$output" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 1 ] || { echo "$output"; return 1; }
}
