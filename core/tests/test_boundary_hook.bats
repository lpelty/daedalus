#!/usr/bin/env bats
# The lease fixture helper is loaded for live_pid / ps_ms / teardown_live only —
# this suite keeps its own setup() (its own target, vault and marker shape).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
teardown() { teardown_live; chmod -R u+w "$DAEDALUS_HOME/state" 2>/dev/null || true; }

setup() {
  # pwd -P: the bats temp dir sits behind /var -> /private/var, and every path a
  # Python hook prints or keys on is resolved (verifylib.ROOT), so the home must be too.
  DAEDALUS_HOME="$(cd "$BATS_TEST_TMPDIR" && pwd -P)/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault/evidence"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/leaselib.py" "$SRC/lease.sh" "$SRC/fingerprint.sh" "$SRC/gates.sh" "$SRC/manifest-append.py" "$SRC/session-start.py" "$SRC/boundary-hook.py" "$SRC/transcriptlib.py" "$SRC/distcheck.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(/core/**)","Edit(/CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  printf '{"permissions":{"deny":["Edit(//elsewhere/**)"],"allow":[]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  printf 'x\n' > "$DAEDALUS_HOME/CLAUDE.md"
  # The refuter is on by default (v0.6.1); this suite is about the boundary
  # hook, and a real claude must never run in tests, so it is off with the
  # reason gates.sh demands. Every rewrite of this file below must keep the
  # same bytes, or the config-sha check reads the rewrite as a change.
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
  git init -q -b main "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"; git -C "$T" remote add origin "$BATS_TEST_TMPDIR/origin.git"; git -C "$T" push -q origin main
  git init -q "$DAEDALUS_HOME/vault"; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  printf 'target/\nvault/\nconfig.yaml\nstate/\n.claude/settings.local.json\n' > "$DAEDALUS_HOME/.gitignore"
  git init -q "$DAEDALUS_HOME"; git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m i
  export DAEDALUS_HOME
  # Registry isolation: a present, empty session registry, so no hook run from
  # this fixture reads the developer's real ~/.claude/sessions/.
  export CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR"; mkdir -p "$BATS_TEST_TMPDIR/sessions"
  printf '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
}

hook() { printf '{"hook_event_name":"%s","session_id":"s1"}' "$1" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }

@test "new protected dirt blocks on PostToolUse and Stop; snapshot dirt further edited blocks; revert passes" {
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  printf '{"hook_event_name":"SessionStart","session_id":"s2","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  printf 'more\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  # Content-hash keying (Finding 1): a snapshot-dirty file edited FURTHER
  # this session is content-changed relative to the snapshot's hash, even
  # though its porcelain line (" M CLAUDE.md") is unchanged — this must block.
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s2\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"CLAUDE.md"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  printf 'x\nop\n' > "$DAEDALUS_HOME/CLAUDE.md"   # back to exactly the snapshot's content
  printf 'x\n' >> "$DAEDALUS_HOME/core/lib.sh"
  run bash -c "printf '{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s2\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"core/lib.sh"*"restart"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q -- core/lib.sh
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s2\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ]
}

@test "content hashing: untouched snapshot dirt passes; no-op stage of snapshot dirt passes; old-format marker degrades without crashing" {
  # (a) covered above (edited further blocks). (b) untouched snapshot dirt.
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  printf '{"hook_event_name":"SessionStart","session_id":"s3","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s3\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ]
  # (c) staged with no content change (" M" -> "M ") must not block — same sha.
  git -C "$DAEDALUS_HOME" add CLAUDE.md
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s3\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ]
  git -C "$DAEDALUS_HOME" reset -q CLAUDE.md
  # CLAUDE.md is still dirty (op\n appended) at this point — the (d) marker
  # below has an empty protected_status, so this dirt is "new" under the
  # degraded line comparison and must still be caught.
  # (d) old-format marker (no protected_snapshot key) degrades to the line
  # comparison instead of crashing.
  m="$DAEDALUS_HOME/state/session-s4.json"
  python3 -c "
import json, sys
sys.path.insert(0, '$DAEDALUS_HOME/core')
import verifylib as v
from pathlib import Path
root = Path('$DAEDALUS_HOME')
d = {'session_id': 's4', 'started': '2020-01-01T00:00:00', 'vault_head': None,
     'config_sha': v.sha256_file(root / 'config.yaml'),
     'local_settings_sha': v.local_settings_sha(root), 'target_origin_main': '', 'protected_status': []}
open('$m', 'w').write(json.dumps(d))
"
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s4\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"CLAUDE.md"*) : ;; *) echo "old-format marker should still catch new dirt via line comparison: $output"; return 1 ;; esac
}

@test "config change blocks; a 'don't ask again' allow entry does not; a deny change does" {
  printf '  - echo x\n' >> "$DAEDALUS_HOME/config.yaml"
  run hook Stop; [ "$status" -eq 2 ]
  case "$output" in *"config.yaml"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q -- . 2>/dev/null || true
  printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\ngates:\n  - true\nverify:\n  refute: false\n  refute_off_reason: bats fixture — a real claude must never be invoked in tests\n' > "$DAEDALUS_HOME/config.yaml"
  run hook Stop; [ "$status" -eq 0 ]
  printf '{"permissions":{"deny":["Edit(//elsewhere/**)"],"allow":["Bash(ls:*)"]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run hook Stop; [ "$status" -eq 0 ]
  printf '{"permissions":{"deny":[],"allow":["Bash(ls:*)"]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run hook Stop; [ "$status" -eq 2 ]
}

@test "disableAllHooks written mid-session blocks check 2 instead of silently evading it" {
  printf '{"disableAllHooks":true}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  run hook Stop; [ "$status" -eq 2 ]
  case "$output" in *"settings.local.json"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
}

@test "evidence: a gates.sh run passes; a hand-written file in the window blocks; a pre-marker unmanifested file does not" {
  printf -- '---\ntype: evidence\n---\n' > "$DAEDALUS_HOME/vault/evidence/20200101-000000-aaaaaa.md"
  touch -t 202001010000 "$DAEDALUS_HOME/vault/evidence/20200101-000000-aaaaaa.md"
  run hook Stop; [ "$status" -eq 0 ]
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null
  run hook Stop; [ "$status" -eq 0 ]
  printf -- '---\ntype: evidence\nresult: PASS\n---\n' > "$DAEDALUS_HOME/vault/evidence/20261231-000000-ffffff.md"
  run hook Stop; [ "$status" -eq 2 ]
  case "$output" in *"20261231-000000-ffffff.md"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  case "$output" in *"restart the session"*) : ;; *) echo "check 3's reason should name the restart remedy: $output"; return 1 ;; esac
}

@test "promotion: a commit on target main past recorded origin/main blocks even after push; no origin is an explicit does-not-apply note" {
  printf 'b\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -q -am b
  run hook Stop; [ "$status" -eq 2 ]
  case "$output" in *"main moved"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  git -C "$T" push -q origin main
  run hook Stop; [ "$status" -eq 2 ]
  run hook PostToolUse; [ "$status" -eq 0 ]          # promotion is Stop-only
  git -C "$T" reset -q --hard HEAD~1; git -C "$T" remote remove origin
  printf '{"hook_event_name":"SessionStart","session_id":"s5","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s5\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ]
  # PROP-019: the only benign skip is "nothing shared to protect", and it must say so — never "nothing to check".
  case "$output" in *"does not apply"*"no origin remote"*) : ;; *) echo "expected an explicit does-not-apply note: $output"; return 1 ;; esac
}

sess() { printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$1" | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null; }
hook_as() { printf '{"hook_event_name":"%s","session_id":"%s"}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }

@test "promotion (PROP-019): the gate reads config target.branch — a target whose branch is not 'main' is gated" {
  # The reported defect: both call sites hardcoded 'main'; a deployment on any other branch name had an inert gate.
  rm -rf "$T"; git init -q -b mainline "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q --bare "$BATS_TEST_TMPDIR/origin2.git"; git -C "$T" remote add origin "$BATS_TEST_TMPDIR/origin2.git"; git -C "$T" push -q origin mainline
  sed -i.bak 's/^  branch: main$/  branch: mainline/' "$DAEDALUS_HOME/config.yaml"; rm -f "$DAEDALUS_HOME/config.yaml.bak"
  sess s6
  run hook_as Stop s6; [ "$status" -eq 0 ]                       # nothing moved yet: the gate evaluated and passed
  printf 'b\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -q -am b
  run hook_as Stop s6; [ "$status" -eq 2 ]
  case "$output" in *"mainline moved"*"origin/mainline"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
}

@test "promotion (PROP-019): a configured branch that origin does not have REFUSES and names what it could not determine" {
  # Fail closed: a gate that cannot evaluate must not pass by default. The message names the branch and the remedy.
  sed -i.bak 's/^  branch: main$/  branch: mainline/' "$DAEDALUS_HOME/config.yaml"; rm -f "$DAEDALUS_HOME/config.yaml.bak"
  sess s7
  run hook_as Stop s7; [ "$status" -eq 2 ]
  case "$output" in *"could not evaluate"*"mainline"*"target.branch"*) : ;; *) echo "expected a named refusal: $output"; return 1 ;; esac
  run hook_as PostToolUse s7; [ "$status" -eq 0 ]              # still Stop-only
}

@test "promotion (PROP-019): a marker written before the branch-aware gate refuses with the restart remedy" {
  python3 - "$DAEDALUS_HOME/state" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1]) / "session-s1.json"
m = json.loads(p.read_text()); m.pop("target_branch", None); m.pop("target_base", None); m.pop("target_base_error", None)
m["target_origin_main"] = "deadbeef"
p.write_text(json.dumps(m))
PY
  run hook Stop; [ "$status" -eq 2 ]
  case "$output" in *"could not evaluate"*"restart the session"*) : ;; *) echo "expected a refusal naming the remedy: $output"; return 1 ;; esac
}

@test "no-marker degrade notice names the restart remedy" {
  # Finding 2: the marker-less degrade notice must carry the remedy, not just
  # announce the gap. Whether this particular tree is otherwise clean enough
  # to pass (exit 0, note printed to stdout) or has protected dirt of its own
  # (exit 2, note folded into the blocked reasons) is incidental — either way
  # the "session-start hook did not run" notice must name the restart fix.
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"no-such-session\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  case "$status" in 0|2) : ;; *) echo "unexpected exit: $status"; return 1 ;; esac
  case "$output" in *"session-start hook did not run"*"restart the session"*) : ;; *) echo "no-marker notice missing the restart remedy: $output"; return 1 ;; esac
}

@test "visible-vault layout: gates.sh evidence is excused; rewritten past evidence still blocks" {
  # PROP-017 finding 1: with a vault the parent git can SEE (not gitignored,
  # not its own repo — one real deployment's layout), every gates.sh run
  # tripped check_protected on its own sanctioned output. The manifest-aware
  # excusal must clear exactly that, while a rewrite of PRE-EXISTING evidence
  # (real tampering) still blocks.
  rm -rf "$DAEDALUS_HOME/vault/.git"
  printf 'target/\nconfig.yaml\nstate/\n.claude/settings.local.json\n' > "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add .gitignore
  printf -- '---\ntype: evidence\nresult: PASS\n---\nold run\n' > "$DAEDALUS_HOME/vault/evidence/20200101-000000-aaaaaa.md"
  touch -t 202001010000 "$DAEDALUS_HOME/vault/evidence/20200101-000000-aaaaaa.md"
  printf '{"hook_event_name":"SessionStart","session_id":"s9","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null
  run bash -c "printf '{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s9\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ]
  # positive control A: rewriting evidence that PRE-DATES the session blocks
  printf 'tampered\n' >> "$DAEDALUS_HOME/vault/evidence/20200101-000000-aaaaaa.md"
  run bash -c "printf '{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s9\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"20200101-000000-aaaaaa.md"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q -- . 2>/dev/null || true
  printf -- '---\ntype: evidence\nresult: PASS\n---\nold run\n' > "$DAEDALUS_HOME/vault/evidence/20200101-000000-aaaaaa.md"
  # positive control B: a NEW hand-written, unmanifested evidence file blocks
  printf -- '---\ntype: evidence\nresult: PASS\n---\n' > "$DAEDALUS_HOME/vault/evidence/20261231-000000-ffffff.md"
  run bash -c "printf '{\"hook_event_name\":\"PostToolUse\",\"session_id\":\"s9\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"20261231-000000-ffffff.md"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
}

@test "visible-vault layout: the refuter's <run>-review.md is excused like the run's other evidence; a hand-written review for no run still blocks" {
  # refute.sh writes vault/evidence/<run-id>-review.md and manifests it,
  # but _sanctioned_evidence read the run-id off the file name, and
  # "<run-id>-review" is no run: with the refuter on by default, every
  # STANDS verdict in a vault the parent git can see blocked the Stop hook
  # as protected dirt Daedalus cannot revert.
  rm -rf "$DAEDALUS_HOME/vault/.git"
  # __pycache__/ as the real .gitignore has it: refute-pitfalls.py imports pitfall-inject.py.
  printf 'target/\nconfig.yaml\nstate/\n.claude/settings.local.json\n__pycache__/\n' > "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add .gitignore
  mkdir -p "$DAEDALUS_HOME/core/agents" "$BATS_TEST_TMPDIR/bin"
  cp "$SRC/refute.sh" "$SRC/review-lenses.py" "$SRC/agentdef.py" "$SRC/refute-pitfalls.py" "$SRC/pitfall-inject.py" \
     "$SRC/call-agent.sh" "$SRC/call_agent.py" "$SRC/distcheck.py" "$SRC/leaselib.py" "$SRC/fingerprint.sh" "$DAEDALUS_HOME/core/"
  cp "$SRC/agents/refuter.md" "$DAEDALUS_HOME/core/agents/"
  # The launcher that runs the review refuses while core/ differs from the
  # committed version (spec §6.1): commit the files this test just added.
  git -C "$DAEDALUS_HOME" add core
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "refuter and launcher"
  printf '#!/usr/bin/env bash\ncat > /dev/null\nprintf "VERDICT: STANDS\\n"\n' > "$BATS_TEST_TMPDIR/bin/claude"
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
gates:
  - true
verify:
  refute: true
EOF
  printf 'b\n' >> "$T/a.txt"      # something for the refuter to review
  printf '{"hook_event_name":"SessionStart","session_id":"sB","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$DAEDALUS_HOME/core/gates.sh"
  [ "$status" -eq 0 ]
  id="$(printf '%s\n' "$output" | tail -1)"
  [ -f "$DAEDALUS_HOME/vault/evidence/$id-review.md" ]
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"sB\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ] || { echo "the run's own review blocked: $output"; return 1; }
  # Positive control: a review file for a run that has no record is not the
  # stage's output, manifest line or not.
  printf -- '---\ntype: evidence-review\n---\nVERDICT: STANDS\n' > "$DAEDALUS_HOME/vault/evidence/20261231-000000-ffffff-review.md"
  printf '%s\n' "$DAEDALUS_HOME/vault/evidence/20261231-000000-ffffff-review.md" >> "$DAEDALUS_HOME/vault/evidence/.manifest"
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"sB\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"20261231-000000-ffffff-review.md"*) : ;; *) echo "wrong reason: $output"; return 1 ;; esac
}

@test "a second gates.sh run in the same session is also excused (manifest grows)" {
  rm -rf "$DAEDALUS_HOME/vault/.git"
  printf 'target/\nconfig.yaml\nstate/\n.claude/settings.local.json\n' > "$DAEDALUS_HOME/.gitignore"
  git -C "$DAEDALUS_HOME" add .gitignore
  printf '{"hook_event_name":"SessionStart","session_id":"sA","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null
  bash "$DAEDALUS_HOME/core/gates.sh" >/dev/null
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"sA\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ]
}

@test "promotion backstop in a lease worktree reports 'does not apply' and moves on" {
  cp "$SRC/leaselib.py" "$SRC/lease.sh" "$DAEDALUS_HOME/core/"
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  printf '{"lease":"01","session_id":"sL","worktree":"worktrees/01","branch":"lease/01","trunks":{"thing":"main"}}' > "$DAEDALUS_HOME/state/leases/01.json"
  printf '{"hook_event_name":"SessionStart","session_id":"sL","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  printf 'b\n' >> "$DAEDALUS_HOME/worktrees/01/thing/a.txt"; git -C "$DAEDALUS_HOME/worktrees/01/thing" -c user.email=t@x -c user.name=t commit -q -am b
  run hook_as Stop sL; [ "$status" -eq 0 ]
  case "$output" in *"does not apply in a lease worktree; trunk is guarded by promote"*) : ;; *) echo "$output"; return 1 ;; esac
}

# --- PreToolUse(Edit|Write): the boundary warning (spec §4.6, §4.7 hot.md, §4.10) ---

edit_as() { printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
two_leases() {   # window 01 = sA (prime), window 02 = sB; 02 has changed hooks/capture.py
  cp "$SRC/leaselib.py" "$SRC/lease.sh" "$DAEDALUS_HOME/core/"
  bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null; bash "$DAEDALUS_HOME/core/lease.sh" create >/dev/null
  for p in 01:sA 02:sB; do nn="${p%%:*}"; s="${p##*:}"
    python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$nn" "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(session_id=sys.argv[2],pid=int(sys.argv[3]),proc_started=1); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$nn.json" "$s" "$$")"
    python3 "$DAEDALUS_HOME/core/leaselib.py" heartbeat "$nn"; done
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write prime '{"session_id":"sA","history":[]}'
  bash "$DAEDALUS_HOME/core/lease.sh" alias 02 poc-ui >/dev/null
  printf '{"thing":{"hooks/capture.py":"2026-09-25T10:31:04","tests/test_capture.py":"2026-09-25T10:31:04"}}' > "$DAEDALUS_HOME/state/leases/02.changed"
  printf '{"hook_event_name":"SessionStart","session_id":"sA","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
}
# $$ is the bats process: alive for the whole test, but the fixture leases carry proc_started=1, so
# pid_is_recorded_process sees a re-used pid and liveness reads "stale" — the tests that need LIVE
# holders rewrite the lease with live_holder (a live pid AND its real start time).
live_holder() { local pid; pid="$(live_pid)"; python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$1" "$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1])); d.update(pid=int(sys.argv[2]),proc_started=int(sys.argv[3])); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/$1.json" "$pid" "$(ps_ms "$pid")")"; }

@test "cross-lease: first Edit of a path in another live lease's changed set is denied with the holder's number and alias and recorded under warned; the second attempt goes through with context; a different path in that set is denied again; a stale lease's sidecar is ignored; own path and empty set are silent" {
  two_leases; live_holder 02
  W="$DAEDALUS_HOME/worktrees/01/thing"
  run edit_as sA "$W/hooks/capture.py"
  case "$output" in *'"permissionDecision": "deny"'*"The file hooks/capture.py has been changed in window 02 (poc-ui;"*"This first attempt was stopped so you would read this before changing it."*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *'"additionalContext"'*) : ;; *) echo "context must ride along: $output"; return 1 ;; esac
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(k.endswith("hooks/capture.py") for k in d["warned"]), d' "$DAEDALUS_HOME/state/session-sA-boundary.json"
  run edit_as sA "$W/hooks/capture.py"
  case "$output" in *'"permissionDecision"'*) echo "second attempt must not decide: $output"; return 1 ;; *"window 02 (poc-ui"*) : ;; *) echo "$output"; return 1 ;; esac
  run edit_as sA "$W/tests/test_capture.py"; case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "$output"; return 1 ;; esac
  run edit_as sA "$W/a.txt"; [ -z "$output" ]
  printf '{}' > "$DAEDALUS_HOME/state/leases/02.changed"; run edit_as sA "$W/hooks/other.py"; [ -z "$output" ]
  printf '{"thing":{"hooks/x.py":"2026-09-25T10:31:04"}}' > "$DAEDALUS_HOME/state/leases/02.changed"
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(pid=1,proc_started=1); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run edit_as sA "$W/hooks/x.py"; [ -z "$output" ]
}

@test "cross-lease: a background (kind bg) or spawned holder changes the last two sentences of the warning" {
  two_leases; live_holder 02
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["spawned"]=True; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run edit_as sA "$DAEDALUS_HOME/worktrees/01/thing/hooks/capture.py"
  case "$output" in *"That window is a background worker and may not answer a message. Tell the operator what you need from this file; if you then still need to change it here, try again and it will go through."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "an Edit or Write into the prime's checkout target/<repo> is denied for every window, the prime included; an unbindable session is denied (fail closed); a released lease's worktree is denied" {
  two_leases; live_holder 01; live_holder 02
  for s in sA sB; do run edit_as "$s" "$T/a.txt"; case "$output" in *'"permissionDecision": "deny"'*"This is the prime's checkout (target/thing). Your work goes in worktrees/"*"If you meant to change trunk, that is what \`promote\` is for."*) : ;; *) echo "$s: $output"; return 1 ;; esac; done
  run edit_as sZ "$T/a.txt"; case "$output" in *'"permissionDecision": "deny"'*"holds no window"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["released"]="2026-09-25T12:00:00"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run edit_as sB "$DAEDALUS_HOME/worktrees/02/thing/a.txt"; case "$output" in *'"permissionDecision": "deny"'*"this window is released; its worktree is closed"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "vault/hot.md: an Edit or Write is denied for every session, the prime included, naming the core/hot.py command to use; other vault files allowed" {
  # v0.12.6 (spec 2026-10-20, C): core/hot.py is the only way hot.md changes, for every window
  two_leases; live_holder 01; live_holder 02
  for s in sA sB sZ; do
    for f in edit_as write_as; do
      run $f "$s" "$DAEDALUS_HOME/vault/hot.md"
      case "$output" in *'"permissionDecision": "deny"'*"hot.md changes only through core/hot.py"*'python3 core/hot.py add'*'update'*'remove'*'keep'*) : ;; *) echo "$s $f: $output"; return 1 ;; esac
      case "$output" in *"daedalus-0"*|*"Only the prime"*) echo "$s $f: $output"; return 1 ;; *) : ;; esac
    done
  done
  run edit_as sB "$DAEDALUS_HOME/vault/proposals/PROP-9.md"; [ -z "$output" ]
}

@test "the Edit check answers in under 1 s with 40 LIVE fixture leases (the live path: a ps per lease and a registry scan, no git), and the tracked settings.json wires boundary-hook.py on PreToolUse Edit|Write|NotebookEdit with a 5 s timeout" {
  two_leases; live_holder 01; live_holder 02
  for i in $(seq 3 42); do nn="$(printf '%02d' "$i")"; python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$nn" "{\"lease\":\"$nn\",\"session_id\":\"s$nn\",\"pid\":$$,\"proc_started\":$(ps_ms $$),\"worktree\":\"worktrees/$nn\",\"branch\":\"lease/$nn\",\"trunks\":{\"thing\":\"main\"}}"; python3 "$DAEDALUS_HOME/core/leaselib.py" heartbeat "$nn"; printf '{"thing":{"f%s.py":"2026-01-01T00:00:00"}}' "$i" > "$DAEDALUS_HOME/state/leases/$nn.changed"; done
  run python3 "$DAEDALUS_HOME/core/leaselib.py" liveness 30; [ "$output" = "live" ]
  t0="$(python3 -c 'import time; print(time.time())')"; run edit_as sA "$DAEDALUS_HOME/worktrees/01/thing/f10.py"; t1="$(python3 -c 'import time; print(time.time())')"
  case "$output" in *'"permissionDecision": "deny"'*"window 10"*) : ;; *) echo "a live holder's path must warn: $output"; return 1 ;; esac
  python3 -c 'import sys; assert float(sys.argv[2])-float(sys.argv[1]) < 1.0' "$t0" "$t1"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(g.get("matcher")=="Edit|Write|NotebookEdit" and any("boundary-hook.py" in h["command"] and h["timeout"]==5 for h in g["hooks"]) for g in d["hooks"]["PreToolUse"]), d' "$SRC/../.claude/settings.json"
}

@test "a lease file that cannot be read fails CLOSED for Edit/Write under target/ and worktrees/ — the lease.sh sentence, not silence; a path outside every tree is untouched" {
  # Review of Task 10: lease_context returns refused with an EMPTY leases dict when a
  # lease file is unreadable, and the hook returned None at `if not ctx["leases"]`
  # before it looked at the refusal — every write under the guarded trees went through.
  two_leases; live_holder 01; live_holder 02
  printf 'not json' > "$DAEDALUS_HOME/state/leases/02.json"
  for c in "sA $T/a.txt" "sB $DAEDALUS_HOME/worktrees/01/thing/a.txt" "sZ $T/a.txt"; do set -- $c
    run edit_as "$1" "$2"
    case "$output" in *'"permissionDecision": "deny"'*"The lease file for window 02 cannot be read"*"core/lease.sh sweep"*) : ;; *) echo "$1 $2 must fail closed: $output"; return 1 ;; esac
  done
  run edit_as sA "$DAEDALUS_HOME/vault/proposals/PROP-9.md"; [ -z "$output" ]
}

@test "an Edit or Write into ANOTHER window's worktree is denied for a clone and for the prime, naming both worktrees — never the stop-once warning, never recorded under warned" {
  # Spec §3.1: a clone never writes any other lease's worktree; the prime never writes
  # another lease's worktree. Task 11 covers the Bash leg; this is the Edit/Write leg.
  two_leases; live_holder 01; live_holder 02
  run edit_as sB "$DAEDALUS_HOME/worktrees/01/thing/a.txt"
  case "$output" in *'"permissionDecision": "deny"'*"This is window 01's worktree (worktrees/01/thing). Your work goes in worktrees/02/thing."*"send it a message"*) : ;; *) echo "clone: $output"; return 1 ;; esac
  for i in 1 2; do   # the prime, twice: a cross-window write is a deny every time, not a stop-once
    run edit_as sA "$DAEDALUS_HOME/worktrees/02/thing/hooks/capture.py"
    case "$output" in *'"permissionDecision": "deny"'*"This is window 02's worktree (worktrees/02/thing). Your work goes in worktrees/01/thing."*) : ;; *) echo "prime attempt $i: $output"; return 1 ;; esac
    case "$output" in *"This first attempt was stopped"*) echo "must not be the stop-once warning: $output"; return 1 ;; *) : ;; esac
  done
  [ ! -f "$DAEDALUS_HOME/state/session-sA-boundary.json" ] || python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert not d.get("warned"), d' "$DAEDALUS_HOME/state/session-sA-boundary.json"
  run edit_as sB "$DAEDALUS_HOME/worktrees/02/thing/a.txt"; [ -z "$output" ]   # its own worktree is still its own
  # Ownership is judged from the path alone (Task 11 review): a directory path — the worktree's own directory,
  # worktrees/ itself, target/ itself — is denied whether or not a repository is found under it.
  run edit_as sB "$DAEDALUS_HOME/worktrees/01"; case "$output" in *'"permissionDecision": "deny"'*"This is window 01's worktree (worktrees/01). Your work goes in worktrees/02."*) : ;; *) echo "$output"; return 1 ;; esac
  run edit_as sB "$DAEDALUS_HOME/worktrees"; case "$output" in *'"permissionDecision": "deny"'*"worktrees/ holds every window's worktree"*) : ;; *) echo "$output"; return 1 ;; esac
  run edit_as sA "$DAEDALUS_HOME/target"; case "$output" in *'"permissionDecision": "deny"'*"This is the prime's checkout (target)."*) : ;; *) echo "$output"; return 1 ;; esac
  run edit_as sB "$DAEDALUS_HOME/target/notes.md"; case "$output" in *'"permissionDecision": "deny"'*"This is the prime's checkout (target/notes.md)."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "when state/ cannot be written the first cross-lease Edit is still denied with the warning and stderr names the cause; the stop repeats until it can be recorded" {
  two_leases; live_holder 02
  W="$DAEDALUS_HOME/worktrees/01/thing"
  chmod 500 "$DAEDALUS_HOME/state"
  for i in 1 2; do
    run edit_as sA "$W/hooks/capture.py"
    case "$output" in *'"permissionDecision": "deny"'*"changed in window 02"*"This first attempt was stopped"*) : ;; *) echo "attempt $i: $output"; return 1 ;; esac
    case "$output" in *"daedalus: could not record the boundary warning in state/"*"the stop will repeat"*) : ;; *) echo "attempt $i, stderr must name the cause: $output"; return 1 ;; esac
  done
  chmod 755 "$DAEDALUS_HOME/state"
  run edit_as sA "$W/hooks/capture.py"; case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "$output"; return 1 ;; esac
  run edit_as sA "$W/hooks/capture.py"; case "$output" in *'"permissionDecision"'*) echo "recorded: the next attempt must pass: $output"; return 1 ;; *"window 02"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "Stop backstop: a Stop records other live leases' changed sets as seen; at the next Stop a path of this session's that was in that snapshot with no warned entry blocks with 'the warning never fired'; with a warned entry it passes; absent from the snapshot it passes" {
  two_leases; live_holder 01; live_holder 02
  W="$DAEDALUS_HOME/worktrees/01/thing"
  run hook_as Stop sA; [ "$status" -eq 0 ]
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "hooks/capture.py" in d["seen"]["02"]["thing"], d' "$DAEDALUS_HOME/state/session-sA-boundary.json"
  mkdir -p "$W/hooks"; printf 'mine\n' > "$W/hooks/capture.py"     # this session changes it without the pre-write hook firing
  run hook_as Stop sA; [ "$status" -eq 2 ]
  case "$output" in *"you changed hooks/capture.py, which window 02 (poc-ui) had already changed, and the warning never fired (the pre-write hook timed out?). Message that window before you go on."*) : ;; *) echo "$output"; return 1 ;; esac
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.setdefault("warned",{})[sys.argv[2]]="x"; open(p,"w").write(json.dumps(d))' "$DAEDALUS_HOME/state/session-sA-boundary.json" "$W/hooks/capture.py"
  run hook_as Stop sA; [ "$status" -eq 0 ]
  printf 'new\n' > "$W/brand-new.py"; run hook_as Stop sA; [ "$status" -eq 0 ]
}

@test "Stop backstop: when state/ cannot be written the never-fired reason still blocks (exit 2) and stderr names the cause; the snapshot write failing is not a silent pass" {
  two_leases; live_holder 01; live_holder 02
  W="$DAEDALUS_HOME/worktrees/01/thing"
  run hook_as Stop sA; [ "$status" -eq 0 ]                                   # records 02's set as seen
  mkdir -p "$W/hooks"; printf 'mine\n' > "$W/hooks/capture.py"
  chmod 500 "$DAEDALUS_HOME/state"
  run hook_as Stop sA; [ "$status" -eq 2 ]
  case "$output" in *"you changed hooks/capture.py, which window 02 (poc-ui) had already changed, and the warning never fired"*) : ;; *) echo "must still block: $output"; return 1 ;; esac
  case "$output" in *"daedalus: could not record the Stop snapshot in state/"*"previous snapshot"*) : ;; *) echo "stderr must name the cause: $output"; return 1 ;; esac
  chmod 755 "$DAEDALUS_HOME/state"
  run hook_as Stop sA; [ "$status" -eq 2 ]                                   # the previous snapshot still stands once state/ is writable again
  case "$output" in *"daedalus: could not record"*) echo "no stderr line once state/ is writable: $output"; return 1 ;; *"the warning never fired"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a visitor (DIRECT_CALL_ID set) is never blocked at Stop: stray evidence, an unbindable session and a backstop hit all become notes, exit 0; its PreToolUse denials still apply" {
  two_leases; live_holder 01; live_holder 02
  mkdir -p "$DAEDALUS_HOME/state/evidence/x"; printf 'x\n' > "$DAEDALUS_HOME/state/evidence/x/gate.log"   # unmanifested: stray
  run hook_as Stop sA; [ "$status" -eq 2 ]                                   # a window IS blocked by the stray file
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f hook_as); hook_as Stop sA"; [ "$status" -eq 0 ]
  case "$output" in *"(visitor, not blocking)"*"gate.log"*) : ;; *) echo "the reason must survive as a note: $output"; return 1 ;; esac
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f hook_as); hook_as Stop sZ"; [ "$status" -eq 0 ]   # unbindable: a note, not a block
  case "$output" in *"(visitor, not blocking)"*) : ;; *) echo "the unbindable reason must survive as a note: $output"; return 1 ;; esac
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f edit_as); edit_as sZ '$T/a.txt'"
  case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "PreToolUse still denies a visitor: $output"; return 1 ;; esac
  # The downgrade is Stop-only (the plan nests it under the Stop branch): on PostToolUse(Bash)
  # exit 2 only feeds text back after a command that already ran, so a visitor's reason is
  # neither swallowed nor turned into a note nothing prints.
  run env DIRECT_CALL_ID=abc bash -c "$(declare -f hook_as); hook_as PostToolUse sA"; [ "$status" -eq 2 ]
  case "$output" in *"(visitor, not blocking)"*) echo "PostToolUse must not downgrade: $output"; return 1 ;; *"gate.log"*) : ;; *) echo "the PostToolUse reason must surface for a visitor: $output"; return 1 ;; esac
}

@test "another live lease's RUNNING run — run dir, and a written vault summary with no review file yet — is not stray; a stale lease's is stray with the 'never finished' line" {
  two_leases; live_holder 01; live_holder 02
  cp "$SRC/manifest-append.py" "$DAEDALUS_HOME/core/"
  rid="20991231-000000-abcdef"; mkdir -p "$DAEDALUS_HOME/state/evidence/$rid"
  printf '{"run_id":"%s","started":"2099-12-31T00:00:00","lease":"02","session_id":"sB","result":"RUNNING"}' "$rid" > "$DAEDALUS_HOME/state/evidence/$rid/run.json"
  printf -- '---\ntype: evidence\nresult: PASS\n---\n' > "$DAEDALUS_HOME/vault/evidence/$rid.md"
  printf 'x\n' > "$DAEDALUS_HOME/state/evidence/$rid/gate-1.log"
  python3 "$DAEDALUS_HOME/core/manifest-append.py" "$DAEDALUS_HOME/state/evidence/$rid/run.json" "$DAEDALUS_HOME/vault/evidence/$rid.md"
  run hook_as Stop sA; [ "$status" -eq 0 ]
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.update(pid=1,proc_started=1); print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run hook_as Stop sA; [ "$status" -eq 2 ]
  case "$output" in *"a gate run under window 02 (poc-ui) never finished; its session is gone"*"gate-1.log"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a lease file that cannot be read never turns a live window's RUNNING run into 'never finished; its session is gone': the block names the unreadable file, at Stop and at PostToolUse" {
  # Task 14 review: when the lease read refuses, the context carries no liveness at all, so
  # every manifested RUNNING run read as never_finished — a false sentence about a live
  # window (alias dropped too), and on PostToolUse(Bash) the only text shown, since the
  # unreadable-lease sentence surfaced only through the promotion check at Stop.
  two_leases; live_holder 01; live_holder 02
  cp "$SRC/manifest-append.py" "$DAEDALUS_HOME/core/"
  rid="20991231-000000-abcdef"; mkdir -p "$DAEDALUS_HOME/state/evidence/$rid"
  printf '{"run_id":"%s","started":"2099-12-31T00:00:00","lease":"02","session_id":"sB","result":"RUNNING"}' "$rid" > "$DAEDALUS_HOME/state/evidence/$rid/run.json"
  printf -- '---\ntype: evidence\nresult: PASS\n---\n' > "$DAEDALUS_HOME/vault/evidence/$rid.md"
  printf 'x\n' > "$DAEDALUS_HOME/state/evidence/$rid/gate-1.log"
  python3 "$DAEDALUS_HOME/core/manifest-append.py" "$DAEDALUS_HOME/state/evidence/$rid/run.json" "$DAEDALUS_HOME/vault/evidence/$rid.md"
  run hook_as Stop sA; [ "$status" -eq 0 ]
  printf 'garbage' > "$DAEDALUS_HOME/state/leases/03.json"
  for ev in Stop PostToolUse; do
    run hook_as "$ev" sA; [ "$status" -eq 2 ]
    case "$output" in *"never finished"*) echo "$ev: false sentence about a live window: $output"; return 1 ;; esac
    case "$output" in *"The lease file for window 03 cannot be read"*"core/lease.sh sweep"*"gate-1.log"*) : ;; *) echo "$ev must name the unreadable file as the cause: $output"; return 1 ;; esac
  done
}

@test "the session transcript is written by nothing: an Edit of <project dir>/<sid>.jsonl, and of a configured memory.transcript_dir, is denied with the transcript sentence; a sibling path outside, and the project's auto memory, are not" {
  P="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$DAEDALUS_HOME" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$P/memory"
  ed() { printf '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
  run ed Edit "$P/s1.jsonl"
  case "$output" in *'"permissionDecision": "deny"'*"the session transcript is the record of the operator's yes; nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
  run ed Write "$P/other-session.jsonl"; case "$output" in *'"deny"'*) : ;; *) echo "$output"; return 1 ;; esac
  run ed Write "$P/memory/MEMORY.md"; [ -z "$output" ] || { echo "auto memory must stay writable: $output"; return 1; }
  run ed Write "$CLAUDE_CONFIG_DIR/projects/-some-other-home/s1.jsonl"; [ -z "$output" ] || { echo "$output"; return 1; }
  TD="$BATS_TEST_TMPDIR/tdir"; mkdir -p "$TD" "$BATS_TEST_TMPDIR/tdir-sibling"
  python3 - "$DAEDALUS_HOME/config.yaml" "$TD" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s + "memory:\n  transcript_dir: %s\n" % sys.argv[2])
PY
  run ed Edit "$TD/s1.jsonl"; case "$output" in *"nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
  run ed Edit "$BATS_TEST_TMPDIR/tdir-sibling/s1.jsonl"; [ -z "$output" ] || { echo "$output"; return 1; }
  # Decision 36: a session started from another directory writes under another project slug;
  # its marker names that transcript, and the directory is denied like the home's own.
  O="$CLAUDE_CONFIG_DIR/projects/-another-cwd"; mkdir -p "$O"
  printf '{"session_id":"s7","transcript_path":"%s/s7.jsonl"}' "$O" > "$DAEDALUS_HOME/state/session-s7.json"
  run ed Write "$O/s7.jsonl"; case "$output" in *"nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the transcript denial on the Edit|Write leg needs no lease state: with the lease lock unreadable (a lease read that breaks), an Edit of the transcript is still denied with the transcript sentence" {
  P="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$DAEDALUS_HOME" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$P" "$DAEDALUS_HOME/state/leases"
  : > "$P/s1.jsonl"; : > "$DAEDALUS_HOME/state/leases/.lock"; chmod 000 "$DAEDALUS_HOME/state/leases/.lock"
  ed() { printf '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
  run ed Edit "$P/s1.jsonl"
  case "$output" in *'"permissionDecision": "deny"'*"the session transcript is the record of the operator's yes; nothing writes it."*) : ;; *) echo "fails open when the lease read breaks: $output"; return 1 ;; esac
  run ed Write "$P/s1.jsonl"
  case "$output" in *'"deny"'*"nothing writes it."*) : ;; *) echo "$output"; return 1 ;; esac
  chmod 600 "$DAEDALUS_HOME/state/leases/.lock"
}

@test "vault/evidence/promotions.log, promote's ledger, is excused like the manifest: appended this session it does not block a Stop; a stray file beside it still does" {
  printf 'x\twindow 02\n' >> "$DAEDALUS_HOME/vault/evidence/promotions.log"
  run hook Stop; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'stray\n' > "$DAEDALUS_HOME/vault/evidence/stray.md"
  run hook Stop; [ "$status" -eq 2 ]; case "$output" in *"stray.md"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a Stop after a promotion recorded in the marker is not blocked; a trunk move the marker does not record still is, and says trunk is reached only through promote" {
  printf 'b\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -q -am promoted
  run hook Stop; [ "$status" -eq 2 ]
  python3 - "$DAEDALUS_HOME/state/session-s1.json" "$(git -C "$T" rev-parse HEAD)" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["target_base"] = sys.argv[2]
m["promotions"] = [{"id": "02-20260928-120000-abc", "sha": sys.argv[2], "at": "2026-09-28T12:00:00.000Z"}]
json.dump(m, open(sys.argv[1], "w"))
PY
  run hook Stop; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'c\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -q -am unrecorded
  run hook Stop; [ "$status" -eq 2 ]
  case "$output" in *"main moved"*"trunk is reached only through promote"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a Stop with a modified core/ file is blocked with 'Distribution code is modified', whoever changed it — even when the change was already there at session start; a visitor's is a note; restored, the Stop passes" {
  printf '# local\n' >> "$DAEDALUS_HOME/core/fingerprint.sh"
  printf '{"hook_event_name":"SessionStart","session_id":"s9","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  run hook_as Stop s9; [ "$status" -eq 2 ]
  case "$output" in *"Distribution code is modified (core/fingerprint.sh); restore it — reviews and promotes refuse until it is clean."*) : ;; *) echo "$output"; return 1 ;; esac
  DIRECT_CALL_ID=x run hook_as Stop s9; [ "$status" -eq 0 ]
  case "$output" in *"(visitor, not blocking) Distribution code is modified"*) : ;; *) echo "$output"; return 1 ;; esac
  git -C "$DAEDALUS_HOME" checkout -q -- core/fingerprint.sh
  run hook_as Stop s9; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# Critic finding 7: the session open through a release pull is told config.yaml changed under it. When the release
# made the change — the upgrade's own write, recorded in state/, or the pull's own commits to a tracked config.yaml
# — the reason says so, says not to restore it and to have the operator start a new session, and blocks once.
# release_under_session <sid> — session <sid> starts in a home at 0.6.1 (stamped, so no upgrade runs), then a pull
# brings VERSION 0.7.0 in under it: the case the upgrade's recorded config.yaml write is for.
release_under_session() {
  printf '0.6.1\n' > "$DAEDALUS_HOME/VERSION"; printf '0.6.1\n' > "$DAEDALUS_HOME/state/upgraded-to"
  git -C "$DAEDALUS_HOME" add VERSION; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "0.6.1"
  printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$1" | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  printf '0.7.0\n' > "$DAEDALUS_HOME/VERSION"
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -am "the release"     # what the pull brings
}

@test "config.yaml changed by the release (the upgrade's recorded write, or the pull's commits) is not 'restore it': one block saying do not restore it and start a new session, then no block; a change by hand on top still says restore it (critic finding 7)" {
  release_under_session s1
  python3 - "$DAEDALUS_HOME" "$SRC" <<'PY'
import sys; from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, sys.argv[2])     # the upgrade module as it ships; core/ stays clean
import verifylib as v, upgrade
p = root / "config.yaml"; before = v.sha256_file(p)
p.write_text(p.read_text() + "\nmemory:\n  bank: 'b'\n")
upgrade.record_config_change(root, before, v.sha256_file(p), "the upgrade to 0.7.0")
PY
  run hook Stop
  [ "$status" -eq 2 ] || { echo "$output"; return 1; }
  s="config.yaml changed under this session, by the upgrade to 0.7.0 — not by this session. Do not restore it: this session started before the release and still runs its old hooks; tell the operator to close it and start a new session."
  case "$output" in *"$s"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"changed this session; restore it"*) echo "$output"; return 1 ;; esac
  run hook Stop
  [ "$status" -eq 0 ] || { echo "a second block: $output"; return 1; }
  run hook PostToolUse
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '  - echo x\n' >> "$DAEDALUS_HOME/config.yaml"
  run hook Stop
  [ "$status" -eq 2 ]
  case "$output" in *"The gate definition (config.yaml) changed this session; restore it if this session changed it."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "a tracked config.yaml changed by the release pull's own commits is the release's change, not the session's (critic finding 7)" {
  printf 'target/\nvault/\nstate/\n.claude/settings.local.json\n__pycache__/\n' > "$DAEDALUS_HOME/.gitignore"
  then="$(( $(date +%s) - 100 ))"
  git -C "$DAEDALUS_HOME" add -A
  GIT_COMMITTER_DATE="@$then" git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m "config tracked"
  printf '{"hook_event_name":"SessionStart","session_id":"s5","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["started_epoch"]-=50; json.dump(d, open(p,"w"))' "$DAEDALUS_HOME/state/session-s5.json"
  printf '\npromote:\n  release_note: true\n' >> "$DAEDALUS_HOME/config.yaml"
  git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -am "the release"     # what the pull brings
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s5\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"config.yaml changed under this session, by the release pulled into this home — not by this session. Do not restore it"*) : ;; *) echo "$output"; return 1 ;; esac
}

# Release-candidate review, finding 4: state/ is outside the protected snapshot, so the session itself could write a
# record there. A record is the release's only when a release came in under the session, names that release, and is
# the upgrade's one write for it; anything else is the session's change and says restore it.
@test "a config.yaml change recorded in state/config-changes.json by the session itself still says restore it: with no release pulled under the session, and a second record on top of the upgrade's own (release-candidate review, finding 4)" {
  python3 - "$DAEDALUS_HOME" <<'PY'
import hashlib, json, sys, time; from pathlib import Path
root = Path(sys.argv[1]); p = root / "config.yaml"
sha = lambda: hashlib.sha256(p.read_bytes()).hexdigest()
before = sha(); p.write_text(p.read_text() + "  - echo forged\n")
(root / "state" / "config-changes.json").write_text(json.dumps({"changes": [
    {"from": before, "to": sha(), "by": "the upgrade to 0.7.0", "version": "0.7.0", "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
     "at_epoch": time.time()}]}))
PY
  run hook Stop
  [ "$status" -eq 2 ]
  case "$output" in *"The gate definition (config.yaml) changed this session; restore it if this session changed it."*"state/config-changes.json was written during this session"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"Do not restore it"*) echo "$output"; return 1 ;; esac
  # a release did come in under s7, and the upgrade recorded its one write; a second record on top is the session's
  release_under_session s7
  python3 - "$DAEDALUS_HOME" "$SRC" <<'PY'
import json, sys, time; from pathlib import Path
root = Path(sys.argv[1]); sys.path.insert(0, sys.argv[2])
import verifylib as v, upgrade
p = root / "config.yaml"; before = v.sha256_file(p)
p.write_text(p.read_text() + "\nmemory:\n  bank: 'b'\n")
upgrade.record_config_change(root, before, v.sha256_file(p), "the upgrade to 0.7.0")
mid = v.sha256_file(p); p.write_text(p.read_text() + "  - echo forged\n")
d = json.loads((root / "state" / "config-changes.json").read_text())
d["changes"].append({"from": mid, "to": v.sha256_file(p), "by": "the upgrade to 0.7.0", "version": "0.7.0",
                     "at": time.strftime("%Y-%m-%dT%H:%M:%S"), "at_epoch": time.time()})
(root / "state" / "config-changes.json").write_text(json.dumps(d))
PY
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s7\"}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ]
  case "$output" in *"The gate definition (config.yaml) changed this session; restore it if this session changed it."*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "the deny list's path anchors: Edit(/core/**) (the project-anchored form the docs give), Edit(./core/**) and an absolute Edit(//<home>/core/**) all protect core/; an absolute rule outside the home protects nothing here" {
  python3 - "$SRC" "$DAEDALUS_HOME" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import verifylib as v
root = Path(sys.argv[2]).resolve()
s = root / ".claude" / "settings.json"
for rule in ("Edit(/core/**)", "Edit(./core/**)", "Edit(//%s/core/**)" % root, "Edit(/CLAUDE.md)", "Edit(//%s/CLAUDE.md)" % root):
    s.write_text(json.dumps({"permissions": {"deny": [rule]}}))
    target = root / ("core/x.py" if "core" in rule else "CLAUDE.md")
    assert v.is_protected(root, target), (rule, v.protected_globs(root))
    assert not v.is_protected(root, root / "vault" / "notes.md"), rule
    specs = v.protected_pathspecs(root)
    assert all(not p.startswith("/") for p in specs), (rule, specs)
s.write_text(json.dumps({"permissions": {"deny": ["Edit(//elsewhere/core/**)", "Edit(~/core/**)"]}}))
assert not v.is_protected(root, root / "core" / "x.py"), v.protected_globs(root)
# a rule naming the home itself names no file: nothing is protected and git status gets no "." pathspec
for rule in ("Edit(//%s)" % root, "Edit(//%s/)" % root, "Edit(/)", "Edit(.)", "Edit(./)"):
    s.write_text(json.dumps({"permissions": {"deny": [rule]}}))
    assert v.protected_globs(root) == v.EXTRA_PROTECTED + [v.LOCAL_BRIEF], (rule, v.protected_globs(root))   # edit_brief false
    assert "." not in v.protected_pathspecs(root), rule
# a trailing slash is the directory and everything in it, in every form
for rule in ("Edit(/core/)", "Edit(./core/)", "Edit(//%s/core/)" % root):
    s.write_text(json.dumps({"permissions": {"deny": [rule]}}))
    assert v.protected_globs(root)[0] == "core/**", (rule, v.protected_globs(root))
    assert v.is_protected(root, root / "core" / "x.py"), rule
PY
}

@test "a Stop re-fired by Claude Code (stop_hook_active true) is not blocked again by a promotion check that could not evaluate — the agent cannot repair that; a protected-file change still blocks the re-fired Stop" {
  # Claude Code sets stop_hook_active on the Stop it fires after a blocked one. A reason only a restart can
  # repair re-prompted the agent without end (another deployment, 2026-10-13: 15+ times in one session).
  python3 - "$DAEDALUS_HOME/state/session-s1.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m.pop("target_branch", None); json.dump(m, open(p, "w"))
PY
  run --separate-stderr bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"stop_hook_active\":false}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"Promotion check could not evaluate: this session's marker predates the branch-aware gate"*) : ;; *) echo "$stderr"; return 1 ;; esac
  run --separate-stderr bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"stop_hook_active\":true}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 0 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$output" in *"Promotion check could not evaluate: this session's marker predates the branch-aware gate"*) : ;; *) echo "the reason must survive as a note: $output"; return 1 ;; esac
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run --separate-stderr bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"s1\",\"stop_hook_active\":true}' | python3 '$DAEDALUS_HOME/core/boundary-hook.py'"
  [ "$status" -eq 2 ] || { echo "status $status: $output $stderr"; return 1; }
  case "$stderr" in *"CLAUDE.md"*) : ;; *) echo "$stderr"; return 1 ;; esac
}

# --- The local layer (update design §4.4; Decisions 3, 22): boundary.edit_brief, CLAUDE.local.md ---

notebook_as() { printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s","new_source":"x"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
write_as() { printf '{"hook_event_name":"PreToolUse","session_id":"%s","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"; }
LOCAL_DENY="CLAUDE.local.md is the operator's brief; boundary.edit_brief is false in config.yaml."
BRIEF_DENY="CLAUDE.md is distribution code; local brief text goes in CLAUDE.local.md (boundary.edit_brief: true lets Daedalus write it)."
brief_denied() {   # brief_denied <sentence> — a deny whose reason is that sentence
  case "$output" in *'"permissionDecision": "deny"'*"$1"*) : ;; *) echo "expected deny [$1]: $output"; return 1 ;; esac; }
edit_brief_true() { printf 'boundary:\n  edit_brief: true\n' >> "$DAEDALUS_HOME/config.yaml"; }

@test "edit_brief false (the default), no leases held and with one: Edit, Write and NotebookEdit of CLAUDE.local.md are denied naming the key; CLAUDE.md is denied as distribution code; a file beside them is not" {
  run edit_as s1 "$DAEDALUS_HOME/CLAUDE.local.md"; brief_denied "$LOCAL_DENY"
  run write_as s1 "$DAEDALUS_HOME/CLAUDE.local.md"; brief_denied "$LOCAL_DENY"
  run notebook_as s1 "$DAEDALUS_HOME/CLAUDE.local.md"; brief_denied "$LOCAL_DENY"
  run edit_as s1 "$DAEDALUS_HOME/CLAUDE.md"; brief_denied "$BRIEF_DENY"
  run notebook_as s1 "$DAEDALUS_HOME/CLAUDE.md"; brief_denied "$BRIEF_DENY"
  run edit_as s1 "$DAEDALUS_HOME/NOTES.md"; [ -z "$output" ]
  run edit_as s1 "$T/CLAUDE.md"; [ -z "$output" ]     # the target's own brief is the target's, not Daedalus's
  two_leases; live_holder 01; live_holder 02
  for s in sA sB; do
    run edit_as "$s" "$DAEDALUS_HOME/CLAUDE.local.md"; brief_denied "$LOCAL_DENY"
    run notebook_as "$s" "$DAEDALUS_HOME/CLAUDE.local.md"; brief_denied "$LOCAL_DENY"
    run write_as "$s" "$DAEDALUS_HOME/CLAUDE.md"; brief_denied "$BRIEF_DENY"
  done
}

@test "edit_brief true, no leases held and with one: CLAUDE.local.md goes through for Edit, Write and NotebookEdit; CLAUDE.md is still denied; a value other than true is false" {
  edit_brief_true
  run edit_as s1 "$DAEDALUS_HOME/CLAUDE.local.md"; [ -z "$output" ] || { echo "$output"; return 1; }
  run notebook_as s1 "$DAEDALUS_HOME/CLAUDE.local.md"; [ -z "$output" ] || { echo "$output"; return 1; }
  run edit_as s1 "$DAEDALUS_HOME/CLAUDE.md"; brief_denied "$BRIEF_DENY"
  two_leases; live_holder 01; live_holder 02
  for s in sA sB; do
    run write_as "$s" "$DAEDALUS_HOME/CLAUDE.local.md"; [ -z "$output" ] || { echo "$s: $output"; return 1; }
    run edit_as "$s" "$DAEDALUS_HOME/CLAUDE.md"; brief_denied "$BRIEF_DENY"
  done
  sed -i '' 's/edit_brief: true/edit_brief: yes/' "$DAEDALUS_HOME/config.yaml"
  run edit_as sA "$DAEDALUS_HOME/CLAUDE.local.md"; brief_denied "$LOCAL_DENY"
}

@test "Stop, edit_brief false, no leases: CLAUDE.local.md written this session blocks even though it is gitignored (the marker's local_brief_sha); put back, the Stop passes; with edit_brief true a fresh session may write it" {
  printf 'CLAUDE.local.md\n' >> "$DAEDALUS_HOME/.gitignore"
  printf 'operator line\n' > "$DAEDALUS_HOME/CLAUDE.local.md"
  printf '{"hook_event_name":"SessionStart","session_id":"s5","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("local_brief_sha"), d' "$DAEDALUS_HOME/state/session-s5.json"
  run hook_as Stop s5; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'agent line\n' >> "$DAEDALUS_HOME/CLAUDE.local.md"   # as a Bash write past the guard would leave it
  run hook_as Stop s5; [ "$status" -eq 2 ]
  case "$output" in *"CLAUDE.local.md changed this session"*"boundary.edit_brief is false"*) : ;; *) echo "$output"; return 1 ;; esac
  printf 'operator line\n' > "$DAEDALUS_HOME/CLAUDE.local.md"
  run hook_as Stop s5; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  rm "$DAEDALUS_HOME/CLAUDE.local.md"
  run hook_as Stop s5; [ "$status" -eq 2 ]          # removing it is a change too
  edit_brief_true
  printf '{"hook_event_name":"SessionStart","session_id":"s6","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  printf 'agent line\n' > "$DAEDALUS_HOME/CLAUDE.local.md"
  run hook_as Stop s6; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "settings.local.json: an Edit(...) deny there (no leases) protects the path on the Bash leg and shows at Stop like a tracked deny; settings.json's denies still count" {
  export PYTHONDONTWRITEBYTECODE=1      # the guard's imports must not leave core/__pycache__ dirt for the Stop to see
  cp "$SRC/guard-bash.py" "$SRC/amilib.py" "$DAEDALUS_HOME/core/"
  git -C "$DAEDALUS_HOME" add core/guard-bash.py core/amilib.py; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m guard
  printf '{"permissions":{"deny":["Edit(//elsewhere/**)","Edit(/notes/**)"],"allow":[]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  printf '{"hook_event_name":"SessionStart","session_id":"s7","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  bash_as() { printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","session_id":"s7","cwd":"%s","tool_input":{"command":%s}}' "$DAEDALUS_HOME" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" | python3 "$DAEDALUS_HOME/core/guard-bash.py"; }
  run bash_as 'echo x > notes/a.md'
  case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "local deny must hold on the Bash leg: $output"; return 1 ;; esac
  run bash_as 'echo x > core/x.sh'
  case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "$output"; return 1 ;; esac
  run bash_as 'echo x > other/a.md'; [ -z "$output" ] || { echo "$output"; return 1; }
  mkdir -p "$DAEDALUS_HOME/notes"; printf 'x\n' > "$DAEDALUS_HOME/notes/a.md"
  run hook_as Stop s7; [ "$status" -eq 2 ]
  case "$output" in *"Protected files changed this session: "*"notes/a.md. Revert these"*) : ;; *) echo "$output"; return 1 ;; esac
  rm -r "$DAEDALUS_HOME/notes"
  run hook_as Stop s7; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

# --- v0.12.4: changes that need a restart --------------------------------------------------------------------------
# A `!` command runs inside the session, so the operator's own change to a file the session read at its start looked
# like the session's, and every Stop after it blocked until Claude Code locked up. The brief says to restart instead;
# the hook blocks once per change and notes it after that.

@test "CLAUDE.md has the section 'Changes that need a restart'; the gates_setup passages point to it; no line pairs ! with a file read at session start" {
  R="$SRC/.."
  grep -q '^## Changes that need a restart$' "$R/CLAUDE.md"
  sec="$(awk '/^## Changes that need a restart$/{f=1; next} /^## /{f=0} f' "$R/CLAUDE.md")"
  for s in 'config.yaml' '.claude/settings.local.json' 'CLAUDE.local.md' 'read' 'once, when a session starts' \
           '1. Say so plainly: this change needs a restart.' 'core/close.sh' 'one short command, or one sentence' \
           'after exiting, in a plain terminal' 'The next session starts from the changed file.' 'Never offer a `!` command'; do
    printf '%s\n' "$sec" | tr '\n' ' ' | grep -qF -- "$s" || { echo "section lacks: $s"; return 1; }
  done
  # Both gates_setup remedies (gates, promote) send the operator through the restart, not "ask them for it".
  [ "$(grep -c 'gates_setup' "$R/CLAUDE.md")" -ge 2 ]
  [ "$(tr '\n' ' ' < "$R/CLAUDE.md" | grep -o 'change that needs a restart' | wc -l | tr -d ' ')" -ge 2 ]
  ! grep -q 'the operator.s file, so ask them for it' "$R/CLAUDE.md"
  # No line of the distribution's own words offers a ! command next to one of the three files.
  for f in "$R/CLAUDE.md" "$R/README.md"; do
    ! grep -nE '!' "$f" | grep -E 'config\.yaml|settings\.local\.json|CLAUDE\.local\.md' || { echo "$f pairs ! with a session-start file"; return 1; }
  done
}

# changed_three_times <file-change command> — Stop blocks, then notes, then notes; the agent is told each time.
told_once_holds() {
  run --separate-stderr hook Stop
  [ "$status" -eq 2 ] || { echo "first Stop: $status $output $stderr"; return 1; }
  case "$stderr" in *"$1"*"If the operator made this change, do not restore it: this session started before it"*"core/close.sh"*"Changes that need a restart"*) : ;; *) echo "$stderr"; return 1 ;; esac
  run --separate-stderr hook Stop
  [ "$status" -eq 0 ] || { echo "second Stop blocked: $output $stderr"; return 1; }
  case "$output" in *"$1"*) : ;; *) echo "the reason must ride along as a note: $output"; return 1 ;; esac
  run --separate-stderr hook Stop
  [ "$status" -eq 0 ] || { echo "third Stop blocked: $output $stderr"; return 1; }
}

@test "told once: config.yaml changed under a live session blocks the first Stop, then only notes; a further change blocks once more; put back and changed again, it blocks again" {
  cp "$DAEDALUS_HOME/config.yaml" "$BATS_TEST_TMPDIR/cfg"
  printf '  - echo x\n' >> "$DAEDALUS_HOME/config.yaml"
  told_once_holds "The gate definition (config.yaml) changed this session"
  printf '  - echo y\n' >> "$DAEDALUS_HOME/config.yaml"
  told_once_holds "The gate definition (config.yaml) changed this session"
  cp "$BATS_TEST_TMPDIR/cfg" "$DAEDALUS_HOME/config.yaml"
  run hook Stop; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf '  - echo x\n' >> "$DAEDALUS_HOME/config.yaml"
  run hook Stop; [ "$status" -eq 2 ] || { echo "the same change again after a put-back must block: $output"; return 1; }
}

@test "told once: a PostToolUse after the change feeds the reason back and records nothing — the first Stop still blocks; after it, PostToolUse is quiet" {
  printf '  - echo x\n' >> "$DAEDALUS_HOME/config.yaml"
  run hook PostToolUse; [ "$status" -eq 2 ]
  run hook PostToolUse; [ "$status" -eq 2 ]
  run hook Stop; [ "$status" -eq 2 ]
  run hook PostToolUse; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run hook Stop; [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "told once: .claude/settings.local.json's deny rules changed under a live session — block, note, note; a new change blocks once more" {
  printf '{"permissions":{"deny":[],"allow":[]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  told_once_holds "The deny rules or hooks in .claude/settings.local.json changed this session"
  printf '{"permissions":{"deny":["Edit(//other/**)"],"allow":[]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  told_once_holds "The deny rules or hooks in .claude/settings.local.json changed this session"
}

@test "told once: CLAUDE.local.md changed under a live session — block, note, note; a new change blocks once more" {
  printf 'CLAUDE.local.md\n' >> "$DAEDALUS_HOME/.gitignore"
  printf 'operator line\n' > "$DAEDALUS_HOME/CLAUDE.local.md"
  printf '{"hook_event_name":"SessionStart","session_id":"s1","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  printf 'their new line\n' >> "$DAEDALUS_HOME/CLAUDE.local.md"
  told_once_holds "CLAUDE.local.md changed this session"
  printf 'and another\n' >> "$DAEDALUS_HOME/CLAUDE.local.md"
  told_once_holds "CLAUDE.local.md changed this session"
}

# --- v0.12.4: no Stop hook may lock a session (verifylib.stop_once) --------------------------------------------------
# A reason the agent cannot resolve alone blocked every re-fired Stop (9 in a row, 2026-10-19) and the operator had no
# turn. Now a reason blocks once a turn: re-fired (stop_hook_active true) it is a note; a new reason may block once.

stop_as() {   # stop_as <sid> <active true|false>
  printf '{"hook_event_name":"Stop","session_id":"%s","stop_hook_active":%s}' "$1" "$2" | python3 "$DAEDALUS_HOME/core/boundary-hook.py"
}

# once_a_turn <sid> <needle> — blocks with the way back; re-fired, a note; a new turn, blocks again once.
once_a_turn() {
  run --separate-stderr stop_as "$1" false
  [ "$status" -eq 2 ] || { echo "first Stop: $status $output $stderr"; return 1; }
  case "$stderr" in *"$2"*"ask the operator once, in one message, and end your turn"*) : ;; *) echo "$stderr"; return 1 ;; esac
  run --separate-stderr stop_as "$1" true
  [ "$status" -eq 0 ] || { echo "re-fired Stop blocked again: $stderr"; return 1; }
  case "$output" in *"$2"*) : ;; *) echo "the reason must ride along as a note: $output"; return 1 ;; esac
  run --separate-stderr stop_as "$1" false
  [ "$status" -eq 2 ] || { echo "a new turn's Stop must say it once more: $output"; return 1; }
}

@test "once a turn, each blocking reason class: protected files, stray evidence, modified distribution code, a trunk that moved" {
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  once_a_turn s1 "Protected files changed this session"
  git -C "$DAEDALUS_HOME" checkout -q -- CLAUDE.md
  printf -- '---\ntype: evidence\nresult: PASS\n---\n' > "$DAEDALUS_HOME/vault/evidence/20261231-000000-ffffff.md"
  once_a_turn s1 "Evidence files exist that no gate run produced"
  rm "$DAEDALUS_HOME/vault/evidence/20261231-000000-ffffff.md"
  printf '# local\n' >> "$DAEDALUS_HOME/core/fingerprint.sh"
  printf '{"hook_event_name":"SessionStart","session_id":"s2","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  once_a_turn s2 "Distribution code is modified"
  git -C "$DAEDALUS_HOME" checkout -q -- core/fingerprint.sh
  printf 'b\n' >> "$T/a.txt"; git -C "$T" -c user.email=t@x -c user.name=t commit -q -am b
  once_a_turn s2 "main moved"
}

@test "once a turn: a new reason on a re-fired Stop blocks once, never twice; a fresh session blocks again" {
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run stop_as s1 false; [ "$status" -eq 2 ]
  printf 'x\n' > "$DAEDALUS_HOME/vault/evidence/stray.md"
  run --separate-stderr stop_as s1 true
  [ "$status" -eq 2 ] || { echo "a new reason must block once: $output"; return 1; }
  case "$stderr" in *"stray.md"*) : ;; *) echo "$stderr"; return 1 ;; esac
  printf 'y\n' > "$DAEDALUS_HOME/vault/evidence/stray2.md"
  run stop_as s1 true
  [ "$status" -eq 0 ] || { echo "a second re-fire block: $output"; return 1; }
  printf '{"hook_event_name":"SessionStart","session_id":"s3","source":"startup"}' | python3 "$DAEDALUS_HOME/core/session-start.py" >/dev/null
  printf 'more\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run stop_as s3 false; [ "$status" -eq 2 ] || { echo "a fresh session must block: $output"; return 1; }
}

@test "ten consecutive Stops on a reason the agent cannot resolve block at most once (2026-10-19: nine blocks in a row)" {
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  blocks=0
  run stop_as s1 false; [ "$status" -eq 2 ] && blocks=$((blocks + 1))
  for i in 1 2 3 4 5 6 7 8 9; do
    run stop_as s1 true; [ "$status" -eq 2 ] && blocks=$((blocks + 1))
  done
  [ "$blocks" -eq 1 ] || { echo "$blocks blocks"; return 1; }
}

@test "review 2026-10-20 F3: a clean Stop ends the turn — last turn's re-fire block never turns a new reason into a note" {
  printf 'op\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run stop_as s1 false; [ "$status" -eq 2 ]
  printf 'x\n' > "$DAEDALUS_HOME/vault/evidence/stray.md"
  run stop_as s1 true; [ "$status" -eq 2 ]                 # a new reason on the re-fire: the turn's one re-fire block
  git -C "$DAEDALUS_HOME" checkout -q -- CLAUDE.md; rm "$DAEDALUS_HOME/vault/evidence/stray.md"
  run stop_as s1 false; [ "$status" -eq 0 ] || { echo "$output"; return 1; }    # a clean Stop: a new turn
  printf 'more\n' >> "$DAEDALUS_HOME/CLAUDE.md"
  run stop_as s1 true; [ "$status" -eq 2 ] || { echo "a new reason after a clean Stop must block: $output"; return 1; }
}
