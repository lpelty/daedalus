#!/usr/bin/env bats
# The lease fixture helper is loaded for live_pid / ps_ms / teardown_live only —
# this suite keeps its own setup() (its own target, vault and marker shape).
load fixtures/leases/setup.bash
teardown() { teardown_live; chmod -R u+w "$DAEDALUS_HOME/state" 2>/dev/null || true; }

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault/evidence"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/leaselib.py" "$SRC/lease.sh" "$SRC/fingerprint.sh" "$SRC/gates.sh" "$SRC/session-start.py" "$SRC/boundary-hook.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(./core/**)","Edit(./CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  printf '{"permissions":{"deny":["Edit(/elsewhere/**)"],"allow":[]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
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
  printf '{"permissions":{"deny":["Edit(/elsewhere/**)"],"allow":["Bash(ls:*)"]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
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
  cp "$SRC/refute.sh" "$SRC/agentdef.py" "$SRC/refute-pitfalls.py" "$SRC/pitfall-inject.py" "$DAEDALUS_HOME/core/"
  cp "$SRC/agents/refuter.md" "$DAEDALUS_HOME/core/agents/"
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
  run edit_as sZ "$T/a.txt"; case "$output" in *'"permissionDecision": "deny"'*"cannot tell which tree is mine"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write 02 "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["released"]="2026-09-25T12:00:00"; print(json.dumps(d))' "$DAEDALUS_HOME/state/leases/02.json")"
  run edit_as sB "$DAEDALUS_HOME/worktrees/02/thing/a.txt"; case "$output" in *'"permissionDecision": "deny"'*"this window is released; its worktree is closed"*) : ;; *) echo "$output"; return 1 ;; esac
}

@test "vault/hot.md: denied for a non-prime window naming the prime's window number; allowed for the prime; other vault files allowed" {
  two_leases; live_holder 01; live_holder 02
  run edit_as sB "$DAEDALUS_HOME/vault/hot.md"
  case "$output" in *'"permissionDecision": "deny"'*"Only the prime window commits the vault and writes hot.md. You are window 02; the pen is held by window 01"*"core/lease.sh prime take"*) : ;; *) echo "$output"; return 1 ;; esac
  case "$output" in *"daedalus-0"*) echo "never a peer name: $output"; return 1 ;; *) : ;; esac
  run edit_as sA "$DAEDALUS_HOME/vault/hot.md"; [ -z "$output" ]
  run edit_as sB "$DAEDALUS_HOME/vault/proposals/PROP-9.md"; [ -z "$output" ]
}

@test "the Edit check answers in under 1 s with 40 LIVE fixture leases (the live path: a ps per lease and a registry scan, no git), and the tracked settings.json wires boundary-hook.py on PreToolUse Edit|Write with a 5 s timeout" {
  two_leases; live_holder 01; live_holder 02
  for i in $(seq 3 42); do nn="$(printf '%02d' "$i")"; python3 "$DAEDALUS_HOME/core/leaselib.py" _test-write "$nn" "{\"lease\":\"$nn\",\"session_id\":\"s$nn\",\"pid\":$$,\"proc_started\":$(ps_ms $$),\"worktree\":\"worktrees/$nn\",\"branch\":\"lease/$nn\",\"trunks\":{\"thing\":\"main\"}}"; python3 "$DAEDALUS_HOME/core/leaselib.py" heartbeat "$nn"; printf '{"thing":{"f%s.py":"2026-01-01T00:00:00"}}' "$i" > "$DAEDALUS_HOME/state/leases/$nn.changed"; done
  run python3 "$DAEDALUS_HOME/core/leaselib.py" liveness 30; [ "$output" = "live" ]
  t0="$(python3 -c 'import time; print(time.time())')"; run edit_as sA "$DAEDALUS_HOME/worktrees/01/thing/f10.py"; t1="$(python3 -c 'import time; print(time.time())')"
  case "$output" in *'"permissionDecision": "deny"'*"window 10"*) : ;; *) echo "a live holder's path must warn: $output"; return 1 ;; esac
  python3 -c 'import sys; assert float(sys.argv[2])-float(sys.argv[1]) < 1.0' "$t0" "$t1"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert any(g.get("matcher")=="Edit|Write" and any("boundary-hook.py" in h["command"] and h["timeout"]==5 for h in g["hooks"]) for g in d["hooks"]["PreToolUse"]), d' "$SRC/../.claude/settings.json"
}

@test "a lease file that cannot be read fails CLOSED for Edit/Write under target/, worktrees/ and vault/hot.md — the lease.sh sentence, not silence; a path outside every tree is untouched" {
  # Review of Task 10: lease_context returns refused with an EMPTY leases dict when a
  # lease file is unreadable, and the hook returned None at `if not ctx["leases"]`
  # before it looked at the refusal — every write under the guarded trees went through.
  two_leases; live_holder 01; live_holder 02
  printf 'not json' > "$DAEDALUS_HOME/state/leases/02.json"
  for c in "sA $T/a.txt" "sB $DAEDALUS_HOME/worktrees/01/thing/a.txt" "sB $DAEDALUS_HOME/vault/hot.md" "sZ $T/a.txt"; do set -- $c
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
