#!/usr/bin/env bats
# lib.sh target_path and leaselib.py resolve are one implementation (spec §4.4).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
setup() { lease_fixture; LS() { bash "$DAEDALUS_HOME/core/lease.sh" "$@"; }; LL="$DAEDALUS_HOME/core/leaselib.py"; }
teardown() { teardown_live; }
tp() { bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"; }

@test "with no lease files target_path is the plain bash path and spawns no python" {
  run bash -c "PATH=/nonexistent:\$PATH; source '$DAEDALUS_HOME/core/lib.sh'; python3() { echo PYTHON-SPAWNED >&2; }; target_path"
  [ "$output" = "$DAEDALUS_HOME/target/thing" ]
}

@test "resolves by DAEDALUS_SESSION_ID first, then CLAUDE_CODE_SESSION_ID, then CLAUDE_PID -> registry; bash and python agree on every case" {
  LS create >/dev/null; LS create >/dev/null
  CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null; CLAUDE_CODE_SESSION_ID=sB LS claim 02 >/dev/null
  pid="$(live_pid)"; registry_entry "$pid" sB
  for envs in "DAEDALUS_SESSION_ID=sA CLAUDE_CODE_SESSION_ID=sB" "CLAUDE_CODE_SESSION_ID=sB CLAUDE_PID=$pid" "CLAUDE_PID=$pid"; do
    b="$(env $envs bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path")"
    p="$(env $envs python3 "$LL" resolve thing)"
    [ "$b" = "$p" ] || { echo "disagree for $envs: $b vs $p"; return 1; }
  done
  [ "$(DAEDALUS_SESSION_ID=sA CLAUDE_CODE_SESSION_ID=sB tp)" = "$DAEDALUS_HOME/worktrees/01/thing" ]
  [ "$(CLAUDE_PID=$pid tp)" = "$DAEDALUS_HOME/worktrees/02/thing" ]
}

@test "dies: a disagreeing DAEDALUS_LEASE, a hint naming a missing file, a session with no lease while leases exist; resolves: empty leases, prime-only; operator shell gets target and the note" {
  LS create >/dev/null; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  run env DAEDALUS_SESSION_ID=sA DAEDALUS_LEASE=03 bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"; [ "$status" -ne 0 ]
  run env DAEDALUS_SESSION_ID=sZ DAEDALUS_LEASE=07 bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"; [ "$status" -ne 0 ]
  run env DAEDALUS_SESSION_ID=sZ bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"; [ "$status" -ne 0 ]
  case "$output" in *"Several sessions are live and I cannot tell which tree is mine"*) : ;; *) echo "$output"; return 1 ;; esac
  python3 "$LL" _test-write prime '{"session_id":"sP","history":[]}'
  [ "$(DAEDALUS_SESSION_ID=sP tp)" = "$DAEDALUS_HOME/target/thing" ]
  run bash -c "env -u DAEDALUS_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u DAEDALUS_LEASE bash -c \"source '$DAEDALUS_HOME/core/lib.sh'; target_path\" 2>'$BATS_TEST_TMPDIR/err'"
  [ "$status" -eq 0 ]; [ "$output" = "$DAEDALUS_HOME/target/thing" ]; grep -q "no session — using the prime's checkout" "$BATS_TEST_TMPDIR/err"
}

@test "the scratch override is accepted only under state/promote/" {
  mkdir -p "$DAEDALUS_HOME/state/promote/p1/thing"
  [ "$(DAEDALUS_TARGET_OVERRIDE="$DAEDALUS_HOME/state/promote/p1/thing" tp)" = "$DAEDALUS_HOME/state/promote/p1/thing" ]
  run env DAEDALUS_TARGET_OVERRIDE=/tmp bash -c "source '$DAEDALUS_HOME/core/lib.sh'; target_path"; [ "$status" -ne 0 ]
}

@test "verifylib.resolve_target returns Refused (never None) for the die cases, Resolved otherwise, Unconfigured with no target.repo" {
  LS create >/dev/null; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  run python3 -c "
import sys; sys.path.insert(0,'$DAEDALUS_HOME/core'); import verifylib as v
from pathlib import Path; root=Path('$DAEDALUS_HOME')
r=v.resolve_target(root,'sZ'); assert isinstance(r,v.Refused) and 'cannot tell which tree' in r.sentence, r
r=v.resolve_target(root,'sA'); assert isinstance(r,v.Resolved) and r.path.name=='thing', r
print('ok')"
  [ "$output" = "ok" ]
  printf 'gates:\n  - true\n' > "$DAEDALUS_HOME/config.yaml"
  run python3 -c "
import sys; sys.path.insert(0,'$DAEDALUS_HOME/core'); import verifylib as v
from pathlib import Path; r=v.resolve_target(Path('$DAEDALUS_HOME'),'sA'); assert isinstance(r,v.Unconfigured), r; print('ok')"
  [ "$output" = "ok" ]
}

@test "repo_relative strips target/<repo>, worktrees/<NN>/<repo> and state/promote/<id>/<repo>; a nested repo path is keyed to the nested tree" {
  LS create >/dev/null; mkdir -p "$DAEDALUS_HOME/state/promote/p1/thing/sub"
  run python3 -c "
import sys; sys.path.insert(0,'$DAEDALUS_HOME/core'); import verifylib as v
from pathlib import Path; root=Path('$DAEDALUS_HOME').resolve()
for p,tree,rel in [('target/thing/a.txt','target/thing','a.txt'),('worktrees/01/thing/sub/n.txt','worktrees/01/thing/sub','n.txt'),('state/promote/p1/thing/x.py','state/promote/p1/thing','x.py')]:
    t,r=v.repo_relative(root, root/p); assert (t,r)==(root/tree,rel),(p,t,r)
assert v.repo_relative(root, root/'vault/hot.md') is None
print('ok')"
  [ "$output" = "ok" ]
}

@test "a hook payload bound to no lease, with lease files present and every CLAUDE_* variable stripped, yields deny for git push origin HEAD:main from target/<repo>, deny for an Edit of target/<repo>/README.md, and a Stop block naming the sentence" {
  LS create >/dev/null; CLAUDE_CODE_SESSION_ID=sA LS claim 01 >/dev/null
  guard='{"hook_event_name":"PreToolUse","session_id":"sZ","tool_name":"Bash","cwd":"'"$T"'","tool_input":{"command":"git push origin HEAD:main"}}'
  run bash -c "env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u DAEDALUS_SESSION_ID bash -c 'printf %s \"\$1\" | python3 $DAEDALUS_HOME/core/guard-bash.py' _ '$guard'"
  case "$output" in *'"permissionDecision": "deny"'*"cannot tell which tree is mine"*) : ;; *) echo "$output"; return 1 ;; esac
  edit='{"hook_event_name":"PreToolUse","session_id":"sZ","tool_name":"Edit","tool_input":{"file_path":"'"$T"'/README.md"}}'
  run bash -c "printf %s '$edit' | python3 $DAEDALUS_HOME/core/boundary-hook.py"
  case "$output" in *'"permissionDecision": "deny"'*) : ;; *) echo "$output"; return 1 ;; esac
  run bash -c "printf '{\"hook_event_name\":\"Stop\",\"session_id\":\"sZ\"}' | python3 $DAEDALUS_HOME/core/boundary-hook.py"
  [ "$status" -eq 2 ]; case "$output" in *"cannot tell which tree is mine"*) : ;; *) echo "$output"; return 1 ;; esac
}
