#!/usr/bin/env bats

setup() {
  DAEDALUS_HOME="$BATS_TEST_TMPDIR/dae"
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$DAEDALUS_HOME/core" "$DAEDALUS_HOME/state" "$DAEDALUS_HOME/.claude" "$DAEDALUS_HOME/target" "$DAEDALUS_HOME/vault/evidence"
  cp "$SRC/lib.sh" "$SRC/verifylib.py" "$SRC/fingerprint.sh" "$SRC/gates.sh" "$SRC/session-start.py" "$SRC/boundary-hook.py" "$DAEDALUS_HOME/core/"
  printf '{"permissions":{"deny":["Edit(./core/**)","Edit(./CLAUDE.md)"]}}' > "$DAEDALUS_HOME/.claude/settings.json"
  printf '{"permissions":{"deny":["Edit(/elsewhere/**)"],"allow":[]}}' > "$DAEDALUS_HOME/.claude/settings.local.json"
  printf 'x\n' > "$DAEDALUS_HOME/CLAUDE.md"
  cat > "$DAEDALUS_HOME/config.yaml" <<'EOF'
target:
  repo: https://example.com/thing.git
  branch: main
gates:
  - true
EOF
  T="$DAEDALUS_HOME/target/thing"
  git init -q -b main "$T"; printf 'a\n' > "$T/a.txt"; git -C "$T" add -A; git -C "$T" -c user.email=t@x -c user.name=t commit -q -m i
  git init -q --bare "$BATS_TEST_TMPDIR/origin.git"; git -C "$T" remote add origin "$BATS_TEST_TMPDIR/origin.git"; git -C "$T" push -q origin main
  git init -q "$DAEDALUS_HOME/vault"; git -C "$DAEDALUS_HOME/vault" -c user.email=t@x -c user.name=t commit -q --allow-empty -m init
  printf 'target/\nvault/\nconfig.yaml\nstate/\n.claude/settings.local.json\n' > "$DAEDALUS_HOME/.gitignore"
  git init -q "$DAEDALUS_HOME"; git -C "$DAEDALUS_HOME" add -A; git -C "$DAEDALUS_HOME" -c user.email=t@x -c user.name=t commit -q -m i
  export DAEDALUS_HOME
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
  printf 'target:\n  repo: https://example.com/thing.git\n  branch: main\ngates:\n  - true\n' > "$DAEDALUS_HOME/config.yaml"
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
