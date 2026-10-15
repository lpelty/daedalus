# core/tests/fixtures/ami/setup.bash — sourced by the frame-jack suites after fixtures/leases/setup.bash.
# Fixtures only, never a model: fake-decider stands in for `strands-decider serve`, fake-pmset for pmset.

# ami_fixture — a lease_fixture home plus the AMI files, the ami fixture directory copied beside the
# home (AMI_FIX), pmset shadowed by the fake, the session variables unset, the supervisor's poll
# shrunk to 1 s.
ami_fixture() {
  lease_fixture
  for f in amilib.py frame-jack.py ami-daemon.py ami-hook.py; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DAEDALUS_HOME/core/"
  done
  AMI_FIX="$BATS_TEST_TMPDIR/fix/ami"
  mkdir -p "$BATS_TEST_TMPDIR/fix"
  cp -R "$BATS_TEST_DIRNAME/fixtures/ami" "$AMI_FIX"
  chmod +x "$AMI_FIX/fake-decider" "$AMI_FIX/fake-pmset"
  cp "$AMI_FIX/fake-pmset" "$AMI_FIX/pmset"      # so `pmset` on PATH is the fake
  PATH="$AMI_FIX:$PATH"
  export PATH AMI_FIX
  export AMI_TEST_POLL_SECS=1
  unset CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_PID DAEDALUS_SESSION_ID DAEDALUS_LEASE \
        DAEDALUS_TARGET_OVERRIDE DAEDALUS_PROMOTE_ID DIRECT_CALL_ID
}

# free_port — a port nothing listens on right now (bind 0, print, close).
free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# start_fake <model> [VAR=value ...] — starts `fake-decider serve <model> --port <a free port> --device mps` with the
# given environment, reads the port from its first stdout line, exports FAKE_PORT and FAKE_PID, and
# records the pid for teardown_live. The port is always explicit on the command line, as a real serve's
# is: the identity rule matches --port. FAKE_LOG defaults to $BATS_TEST_TMPDIR/fake.log. START_FAKE_PORT
# pins the port (a fake standing on the configured port: the borrowed and refused cases).
start_fake() {
  local model="$1"; shift
  local out="$BATS_TEST_TMPDIR/fake-$RANDOM$RANDOM.out"
  : > "$out"
  env FAKE_LOG="${FAKE_LOG:-$BATS_TEST_TMPDIR/fake.log}" "$@" "$AMI_FIX/fake-decider" serve "$model" --port "${START_FAKE_PORT:-$(free_port)}" --device mps \
      > "$out" 2> "$out.err" 3>&- < /dev/null &
  FAKE_PID=$!
  printf '%s\n' "$FAKE_PID" >> "$BATS_TEST_TMPDIR/live-pids"
  local i=0
  while [ ! -s "$out" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  FAKE_PORT="$(head -1 "$out")"
  export FAKE_PID FAKE_PORT
  [ -n "$FAKE_PORT" ] || { echo "the fake did not print a port:"; cat "$out.err"; return 1; }
}

# write_ami_config <port> [device] [offline] — appends the ami: block to the fixture's config.yaml, the
# fake as the command (an absolute path, as the real one must be). Comments on their own lines only.
write_ami_config() {
  local port="$1" device="${2:-mps}" offline="${3:-false}"
  cat >> "$DAEDALUS_HOME/config.yaml" <<EOF
ami:
  command: $AMI_FIX/fake-decider
  model: StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
  device: $device
  port: $port
  offline: $offline
  battery_off: true
  request_timeout_ms: 1500
EOF
}

# wait_state <word> <secs> — polls daemon.json's state until it is <word>; fails after <secs>.
wait_state() {
  local want="$1" secs="${2:-10}" i=0 n
  n=$((secs * 10))
  while [ "$i" -lt "$n" ]; do
    if [ "$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("state"))
except Exception: print("")' "$DAEDALUS_HOME/state/ami/daemon.json" 2>/dev/null)" = "$want" ]; then
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  echo "daemon.json never reached state $want:"; cat "$DAEDALUS_HOME/state/ami/daemon.json" 2>/dev/null
  return 1
}

# ami_py <python code> [arg ...] — runs code with the fixture's core/ on sys.path and amilib imported
# as `a`, ROOT as the resolved home (a Path), SID as $SID (or "sA"); extra arguments are sys.argv[3:].
ami_py() {
  local code="$1"; shift
  python3 -c "import sys, pathlib; sys.path.insert(0, sys.argv[1]); import amilib as a
ROOT = pathlib.Path(sys.argv[1]).parent; SID = sys.argv[2]
$code" "$DAEDALUS_HOME/core" "${SID:-sA}" "$@"
}

# wait_gone <pid> <secs> — polls until the pid is dead; fails after <secs>.
wait_gone() {
  local pid="$1" secs="${2:-5}" i=0 n
  n=$((secs * 10))
  while [ "$i" -lt "$n" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1; i=$((i + 1))
  done
  echo "pid $pid is still alive after $secs s: $(ps -o command= -p "$pid")"
  return 1
}

# wait_for <secs> <command ...> — polls until the command succeeds; fails after <secs>.
wait_for() {
  local secs="$1" i=0 n; shift
  n=$((secs * 10))
  while [ "$i" -lt "$n" ]; do
    "$@" && return 0
    sleep 0.1; i=$((i + 1))
  done
  echo "never true within $secs s: $*"
  return 1
}

# teardown_ami — kills every daemon this fixture's home started (the supervisor and the leash by their
# --home, which is unique per test), then every process run from the fixture's copy of the AMI files
# (the fake serve, a wrapper) — scoped to this test's directories so parallel files are untouched.
teardown_ami() {
  [ -n "${DAEDALUS_HOME:-}" ] || return 0
  pkill -KILL -f "ami-daemon.py .*--home $DAEDALUS_HOME" 2>/dev/null || true
  [ -n "${AMI_FIX:-}" ] && { pkill -KILL -f "$AMI_FIX/" 2>/dev/null || true; }
  sleep 0.2
  true
}
