#!/usr/bin/env bats
# A claim is a vault doc of Daedalus's, changed this session, shaped like
# completion, created after the deployment's first evidence. Every negative
# has a positive control.

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/leaselib.py" "$SRC/fingerprint.sh" "$SRC/gates.sh" "$SRC/manifest-append.py" "$SRC/session-start.py" "$SRC/verify-hook.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(/core/**)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  # Refuter off with a reason (v0.6.1 default-on): this suite is about the
  # Stop gate, and a real claude must never run in tests.
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
gates:
  - true
verify:
  refute: false
  refute_off_reason: bats fixture — a real claude must never be invoked in tests
EOF
  T="$DAEDALUS_HOME/target/thing"
  git init -q "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A
  git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  V="$DAEDALUS_HOME/vault"; mkdir -p "$V/proposals" "$V/evidence"
  git init -q "$V"; git -C "$V" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  git init -q "$DAEDALUS_HOME"; git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m i
  export DAEDALUS_HOME
  # Registry isolation: a present, empty session registry, so no hook run from
  # this fixture reads the developer's real ~/.claude/sessions/.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$BATS_TEST_TMPDIR/sessions"
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

@test "a claim citing a promotion's gate run (tree promote-scratch, reviewer deferred to promote) is refused at Stop and listed by --doctor, even when the merged tree's fingerprint equals the target's; the window's own run passes" {
  # A promotion whose trunk has not moved: the merged scratch holds exactly the target's content,
  # so its fingerprint (independent of HEAD) matches, and gates.sh --promote wrote PASS with no review.
  PID=01-20260928-120000-abc; PT="$DAEDALUS_HOME/state/promote/$PID/thing"
  mkdir -p "$(dirname "$PT")"; git clone -q "$T" "$PT"
  printf '{"promote_id":"%s","lease":"01","repo":"thing","trunk_sha_at_prepare":"%s","merge_sha":"%s","nested":{}}' \
    "$PID" "$(git -C "$T" rev-parse HEAD)" "$(git -C "$PT" rev-parse HEAD)" > "$DAEDALUS_HOME/state/promote/$PID/context.json"
  pid_run="$(DAEDALUS_TARGET_OVERRIDE="$PT" bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID" | tail -1)"
  own="$(gate)"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$DAEDALUS_HOME/state/evidence/$pid_run/run.json")" = \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$DAEDALUS_HOME/state/evidence/$own/run.json")" ]
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$pid_run"
  run stop; [ "$status" -eq 2 ]
  case "$output" in *"PROP-1.md cites a promotion's gate run ($pid_run); a window's claim needs its own core/gates.sh run"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  run python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor
  case "$output" in *"PROP-1.md cites a promotion's gate run"*) : ;; *) echo "not listed: $output"; return 1 ;; esac
  claim PROP-1.md IMPLEMENTED daedalus 2026-12-01 "$own"
  run stop; [ "$status" -eq 0 ] || { echo "positive control: $output"; return 1; }
}

# --- Claim attribution (spec §4.9) and the vault index.lock (spec §3.3) ------

# ps_ms <pid> — the epoch-millisecond start time of a live pid, as leaselib.proc_started_of computes it.
# $$ is the bats process, alive for the whole test; a lease recording ITS real start time reads "live"
# (one recording proc_started 1 reads "stale": pid reuse), which is what the §4.9 refusal keys on.
ps_ms() { python3 -c 'import subprocess,sys,time
out=subprocess.run(["ps","-o","lstart=","-p",sys.argv[1]],capture_output=True,text=True).stdout.strip()
print(int(time.mktime(time.strptime(out,"%a %b %d %H:%M:%S %Y"))*1000) if out else 0)' "$1"; }
lease_pair() {   # 01=sA, 02=sB, both live under $$; s1's marker already written by setup
  mkdir -p "$DAEDALUS_HOME/state/leases"; local st; st="$(ps_ms $$)"
  for p in 01:sA 02:sB; do nn="${p%%:*}"; s="${p##*:}"; printf '{"lease":"%s","session_id":"%s","worktree":"worktrees/%s","branch":"lease/%s","pid":%s,"proc_started":%s}' "$nn" "$s" "$nn" "$nn" "$$" "$st" > "$DAEDALUS_HOME/state/leases/$nn.json"; touch "$DAEDALUS_HOME/state/leases/$nn.seen"; done
  for s in sA sB; do printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$s" | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null; done
}
claim_l() {  # claim_l <file> <lease-or-empty>
  { printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-12-01\n'; [ -n "$2" ] && printf 'lease: %s\n' "$2"; printf -- '---\n# P\n'; } > "$DAEDALUS_HOME/vault/proposals/$1"
}

@test "a claim with another lease's lease: does not block this session; its own does; an unleased session with live leases is refused on any claim with the plain-language reason" {
  id="$(gate)"     # claims() is armed only once the deployment has evidence (first_evidence_date)
  lease_pair
  claim_l PROP-A.md 02
  run stop sA; [ "$status" -eq 0 ]
  claim_l PROP-B.md 01
  run stop sA; [ "$status" -eq 2 ]; case "$output" in *"PROP-B.md"*"no evidence-run"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"PROP-A.md"*) echo "window 02's claim is not this session's: $output"; return 1 ;; *) : ;; esac
  run stop sZ; [ "$status" -eq 2 ]; case "$output" in *"This session holds no lease, so its claims cannot be attributed. Claim a lease and restart."*) : ;; *) echo "$output"; return 1 ;; esac
  # Only stale leases (their sessions are gone, not yet swept) are not "live leases" (§4.9): an
  # unleased session is not refused — it answers for lease-less claims as it would with no leases.
  # "pid": *  — session start re-serialises a lease it reserves a log number in (json.dump, a space after the colon)
  for nn in 01 02; do sed -i.bak "s/\"pid\": *$$,/\"pid\":999999,/" "$DAEDALUS_HOME/state/leases/$nn.json"; rm -f "$DAEDALUS_HOME/state/leases/$nn.json.bak"; touch -t 202001010000 "$DAEDALUS_HOME/state/leases/$nn.seen"; done
  run stop sZ; [ "$status" -eq 0 ]
  claim_l PROP-Z.md ""
  run stop sZ; [ "$status" -eq 2 ]; case "$output" in *"PROP-Z.md"*"no evidence-run"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"holds no lease"*) echo "a dead lease refused the session with a remedy that cannot clear it: $output"; return 1 ;; *) : ;; esac
  # One live lease alongside the dead ones brings the refusal back.
  printf '{"lease":"03","session_id":"sC","worktree":"worktrees/03","branch":"lease/03","pid":%s,"proc_started":%s}' "$$" "$(ps_ms $$)" > "$DAEDALUS_HOME/state/leases/03.json"; touch "$DAEDALUS_HOME/state/leases/03.seen"
  run stop sZ; [ "$status" -eq 2 ]; case "$output" in *"holds no lease"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a lease file that cannot be read fails closed on any claim: a leased session's own unverified claim is blocked with the file named, an unleased session is blocked the same way, and a claim-free Stop still passes" {
  id="$(gate)"
  lease_pair
  claim_l PROP-B.md 01
  run stop sA; [ "$status" -eq 2 ]
  printf 'not json' > "$DAEDALUS_HOME/state/leases/02.json"
  run stop sA; [ "$status" -eq 2 ]; case "$output" in *"cannot be attributed"*"The lease file for window 02 cannot be read"*"lease.sh sweep"*) : ;; *) echo "silent pass or wrong reason: status=$status output=$output"; return 1 ;; esac
  run stop sZ; [ "$status" -eq 2 ]; case "$output" in *"cannot be attributed"*"window 02"*) : ;; *) echo "silent pass or wrong reason: status=$status output=$output"; return 1 ;; esac
  rm "$DAEDALUS_HOME/vault/proposals/PROP-B.md"
  run stop sA; [ "$status" -eq 0 ]
}

@test "a vault git status that meets index.lock is retried (a lock held 1 s, then released) and proceeds; one held for the whole run blocks with 'the vault index is locked', never a silent pass" {
  id="$(gate)"
  claim_l PROP-C.md ""
  ( touch "$DAEDALUS_HOME/vault/.git/index.lock"; sleep 1; rm -f "$DAEDALUS_HOME/vault/.git/index.lock" ) &
  run stop; [ "$status" -eq 2 ]; case "$output" in *"PROP-C.md"*) : ;; *) echo "$output"; return 1 ;; esac
  wait
  touch "$DAEDALUS_HOME/vault/.git/index.lock"
  run stop; [ "$status" -eq 2 ]; case "$output" in *"the vault index is locked (another session is committing); try again"*) : ;; *) echo "$output"; return 1 ;; esac
  rm -f "$DAEDALUS_HOME/vault/.git/index.lock"
}

@test "the proposal template carries a lease: field" { grep -q '^lease:' "$SRC/templates/proposal.md"; }

@test "--doctor is a whole-vault sweep: a claim carrying another window's lease: is still listed" {
  id="$(gate)"
  claim_l PROP-L.md 02
  run python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor; [ "$status" -eq 0 ]
  case "$output" in *"PROP-L.md"*) : ;; *) echo "leased claim dropped from the sweep: $output"; return 1 ;; esac
}

@test "a visitor (DIRECT_CALL_ID set) is never blocked by verify-hook at Stop: it writes no claims, so it answers for none — an unverified claim and an unreadable lease file included; the same Stop without it blocks" {
  id="$(gate)"
  claim PROP-V.md IMPLEMENTED daedalus 2026-12-01
  run stop; [ "$status" -eq 2 ]                                   # control: a claim with no evidence-run blocks
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f stop); stop"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "status=$status output=$output"; return 1; }
  mkdir -p "$DAEDALUS_HOME/state/leases"; printf 'not json' > "$DAEDALUS_HOME/state/leases/02.json"
  run stop; [ "$status" -eq 2 ]                                   # control: an unreadable lease file blocks a claim
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f stop); stop"
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "status=$status output=$output"; return 1; }
}

# --- A confirmed, pushed promotion's run behind its own window's claim (update-command Decision 11) ---

# promo04 — window 04 (session sD, live under $$) with one commit on lease/04 in worktrees/04/thing;
# promotion 04's scratch merges it, gates.sh --promote runs there, and the records say confirmed and
# pushed. Sets PID, PDIR, PRUN, TIP.
promo04() {
  git -C "$T" branch -q lease/04
  mkdir -p "$DAEDALUS_HOME/worktrees/04"; git -C "$T" worktree add -q "$DAEDALUS_HOME/worktrees/04/thing" lease/04
  W="$DAEDALUS_HOME/worktrees/04/thing"; printf 'w\n' > "$W/w.txt"; git -C "$W" add -A
  git -C "$W" -c user.email=t@x -c user.name=t commit -q -m work
  TIP="$(git -C "$T" rev-parse lease/04)"
  PID=04-20261015-120000-abc; PDIR="$DAEDALUS_HOME/state/promote/$PID"; PT="$PDIR/thing"
  mkdir -p "$PDIR"; git clone -q "$T" "$PT"
  git -C "$PT" -c user.email=t@x -c user.name=t merge -q --no-ff --no-edit -m "promote: merge lease/04" origin/lease/04
  M="$(git -C "$PT" rev-parse HEAD)"; B="$(git -C "$T" rev-parse HEAD)"
  printf '{"promote_id":"%s","lease":"04","repo":"thing","trunk_sha_at_prepare":"%s","merge_sha":"%s","nested":{}}' "$PID" "$B" "$M" > "$PDIR/context.json"
  PRUN="$(DAEDALUS_TARGET_OVERRIDE="$PT" bash "$DAEDALUS_HOME/core/gates.sh" --no-refute --promote "$PID" | tail -1)"
  printf '{"promote_id":"%s","lease":"04","repo":"thing","trunk":"main","merge_sha":"%s","trunk_sha_at_prepare":"%s","lease_tip":"%s","run_id":"%s","confirmed_at":"2026-10-15T12:05:00Z"}' \
    "$PID" "$M" "$B" "$TIP" "$PRUN" > "$PDIR/prepared.json"
  printf '{"at":"2026-10-15T12:05:01Z","lease":"04","merge_sha":"%s"}' "$M" > "$PDIR/pushed"
  mkdir -p "$DAEDALUS_HOME/state/leases"
  printf '{"lease":"04","session_id":"sD","worktree":"worktrees/04","branch":"lease/04","pid":%s,"proc_started":%s}' "$$" "$(ps_ms $$)" > "$DAEDALUS_HOME/state/leases/04.json"
  touch "$DAEDALUS_HOME/state/leases/04.seen"
  printf '{"hook_event_name":"SessionStart","session_id":"sD","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
}
claim_p() {  # claim_p <lease> <run>
  printf -- '---\ntype: proposal\nstatus: IMPLEMENTED\nupdated-by: daedalus\ncreated: 2026-12-01\nlease: %s\nevidence-run: %s\n---\n# P\n' "$1" "$2" > "$DAEDALUS_HOME/vault/proposals/PROP-P.md"
}

@test "promotion: a claim of window 04 citing promotion 04's run, confirmed and pushed, with lease/04 at the promoted tip and worktrees/04 clean, passes at Stop and --doctor says nothing of it" {
  own="$(gate)"; promo04
  claim_p 04 "$PRUN"
  run stop sD; [ "$status" -eq 0 ] || { echo "refused: $output"; return 1; }
  run python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor; [ "$status" -eq 0 ]
  case "$output" in *"PROP-P.md"*) echo "listed: $output"; return 1 ;; *) : ;; esac
  # The config check still holds for a promotion's run.
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/cfg.bak"; printf '  - echo extra\n' >> "$DAEDALUS_HOME/config.yaml"
  run stop sD; [ "$status" -eq 2 ]; case "$output" in *"config.yaml"*) : ;; *) echo "$output"; return 1 ;; esac
  cp "$BATS_TEST_TMPDIR/cfg.bak" "$DAEDALUS_HOME/config.yaml"
}

@test "promotion: the same run is refused with no pushed record, with no confirmed_at, with a different pushed merge, or cited by window 01's claim, each naming what is missing" {
  own="$(gate)"; promo04
  claim_p 04 "$PRUN"
  mv "$PDIR/pushed" "$BATS_TEST_TMPDIR/pushed"
  run stop sD; [ "$status" -eq 2 ]
  case "$output" in *"PROP-P.md cites a promotion's gate run ($PRUN)"*"was not pushed"*"once the promotion is confirmed and pushed, its run stands behind this window's claim while the window has no new work"*) : ;; *) echo "$output"; return 1 ;; esac
  mv "$BATS_TEST_TMPDIR/pushed" "$PDIR/pushed"
  run stop sD; [ "$status" -eq 0 ] || { echo "control: $output"; return 1; }
  cp "$PDIR/prepared.json" "$BATS_TEST_TMPDIR/prep.bak"
  python3 -c 'import json,sys; p=json.load(open(sys.argv[1])); p.pop("confirmed_at"); json.dump(p,open(sys.argv[1],"w"))' "$PDIR/prepared.json"
  run stop sD; [ "$status" -eq 2 ]
  case "$output" in *"was not confirmed"*"once the promotion is confirmed and pushed"*) : ;; *) echo "$output"; return 1 ;; esac
  cp "$BATS_TEST_TMPDIR/prep.bak" "$PDIR/prepared.json"
  cp "$PDIR/pushed" "$BATS_TEST_TMPDIR/pushed.bak"
  printf '{"lease":"04","merge_sha":"%s"}' "$TIP" > "$PDIR/pushed"
  run stop sD; [ "$status" -eq 2 ]
  case "$output" in *"pushed merge ${TIP:0:7}"*"not the merge"*) : ;; *) echo "$output"; return 1 ;; esac
  cp "$BATS_TEST_TMPDIR/pushed.bak" "$PDIR/pushed"
  run stop sD; [ "$status" -eq 0 ] || { echo "control: $output"; return 1; }
  claim_p 01 "$PRUN"
  run python3 "$DAEDALUS_HOME/core/verify-hook.py" --doctor
  case "$output" in *"PROP-P.md"*"window 04's"*"lease: 01"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "promotion: after the promote, new work committed on lease/04 or an uncommitted change in worktrees/04 makes the promotion's run refuse the window's new claim, naming which, and asking for a core/gates.sh run" {
  own="$(gate)"; promo04
  claim_p 04 "$PRUN"
  W="$DAEDALUS_HOME/worktrees/04/thing"
  printf 'more\n' > "$W/more.txt"; git -C "$W" add -A; git -C "$W" -c user.email=t@x -c user.name=t commit -q -m more
  run stop sD; [ "$status" -eq 2 ]
  case "$output" in *"PROP-P.md"*"lease/04"*"new work"*"core/gates.sh"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W" reset -q --hard "$TIP"
  run stop sD; [ "$status" -eq 0 ] || { echo "control: $output"; return 1; }
  printf 'x\n' > "$W/w.txt"
  run stop sD; [ "$status" -eq 2 ]
  case "$output" in *"PROP-P.md"*"worktrees/04"*"uncommitted"*"w.txt"*"core/gates.sh"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$W" checkout -q -- w.txt
  run stop sD; [ "$status" -eq 0 ] || { echo "control: $output"; return 1; }
}
