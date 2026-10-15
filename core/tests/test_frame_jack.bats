#!/usr/bin/env bats
# core/frame-jack.py on|off and core/ami-daemon.py — the switch, the supervisor, the leash, borrowing, battery,
# terminal exits, the environment, the skill (frame-jack spec §4, §8.1, §8.2, §13.1 tests 1–10 and 12).
# Fixtures only: the fake decider stands in for `strands-decider serve`, fake-pmset for pmset; no model, no
# network. Every daemon test runs under AMI_TEST_POLL_SECS=1 (ami_fixture sets it).
bats_require_minimum_version 1.5.0
load fixtures/leases/setup.bash
load fixtures/ami/setup.bash

setup() {
  ami_fixture
  AMI="$DAEDALUS_HOME/state/ami"
  MODEL=StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
  FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"; export FAKE_LOG
  FAKE_POWER_FILE="$BATS_TEST_TMPDIR/power"; export FAKE_POWER_FILE
  printf 'AC Power\n' > "$FAKE_POWER_FILE"
}
teardown() { teardown_ami; teardown_live; }

FJ() { python3 "$DAEDALUS_HOME/core/frame-jack.py" "$@"; }
# dj <key> — one key of daemon.json: strings bare, everything else as JSON (true/false/null/numbers/lists)
dj() {
  python3 -c 'import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v))' "$AMI/daemon.json" "$1"
}
set_dj() {   # set_dj <key> <json value> — rewrite one key of daemon.json
  python3 -c 'import json,sys
p = sys.argv[1]; d = json.load(open(p)); d[sys.argv[2]] = json.loads(sys.argv[3]); open(p, "w").write(json.dumps(d))' \
    "$AMI/daemon.json" "$1" "$2"
}
port_open() { python3 -c 'import socket,sys
s = socket.socket(); s.settimeout(0.2)
try: s.connect(("127.0.0.1", int(sys.argv[1]))); sys.exit(0)
except OSError: sys.exit(1)' "$1"; }
port_closed() { ! port_open "$1"; }
supervisors() { pgrep -f "ami-daemon.py --home $DAEDALUS_HOME" 2>/dev/null | wc -l | tr -d ' '; }
fakes() { pgrep -f "$AMI_FIX/fake-decider serve" 2>/dev/null | wc -l | tr -d ' '; }
has() { case "$1" in *"$2"*) return 0 ;; *) echo "expected <$2> in: $1"; return 1 ;; esac; }
lacks() { case "$1" in *"$2"*) echo "did not expect <$2> in: $1"; return 1 ;; *) return 0 ;; esac; }
borrowed_true() { [ "$(dj borrowed)" = true ]; }
# health_gets — GET /health requests in the fake's log
health_gets() { grep -c '"path": "/health"' "$FAKE_LOG" 2>/dev/null || echo 0; }

@test "on without an ami: block: exit 2, the PASTE lines name every key, no sentinel, no state/ami/" {
  run FJ on
  [ "$status" -eq 2 ]
  has "$output" "no ami: block in config.yaml"
  has "$output" "paste these into config.yaml, fill them in, then say frame-jack on again"
  for k in command model device port offline battery_off request_timeout_ms shadow; do
    case "$output" in *"PASTE    "*"$k:"*) ;; *) echo "no PASTE line for $k in: $output"; return 1 ;; esac
  done
  [ ! -e "$AMI/on" ]
  [ ! -d "$AMI" ]
}

@test "on with a non-executable command: exit 2 naming the path; nothing started" {
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/not-exec"
  chmod -x "$BATS_TEST_TMPDIR/not-exec"
  cat >> "$DAEDALUS_HOME/config.yaml" <<EOF
ami:
  command: $BATS_TEST_TMPDIR/not-exec
  model: $MODEL
  device: mps
  port: 8761
EOF
  run FJ on
  [ "$status" -eq 2 ]
  has "$output" "$BATS_TEST_TMPDIR/not-exec"
  has "$output" "not an executable file"
  [ ! -e "$AMI/on" ]
  [ "$(supervisors)" = 0 ]
}

@test "on: the sentinel holds a time and the session; daemon.json reaches up within the fixture's readiness and records the config it started with; the warm-up question is in the fake's log; leash_pid and serve_pid are alive and identified; a second on says already on and the supervisor pid is unchanged; two on at once (background &) leave one supervisor" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  export DAEDALUS_SESSION_ID=sA
  run FJ on
  [ "$status" -eq 0 ]
  has "$output" "starting the AMI"
  has "$output" "port $PORT"
  [ -f "$AMI/on" ]
  run cat "$AMI/on"
  case "$output" in 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*" session sA") ;; *) echo "sentinel: $output"; return 1 ;; esac
  wait_state up 15
  [ "$(dj command)" = "$AMI_FIX/fake-decider" ]
  [ "$(dj port)" = "$PORT" ]
  [ "$(dj model)" = "$MODEL" ]
  [ "$(dj device)" = mps ]
  [ "$(dj borrowed)" = false ]
  [ "$(dj offline)" = false ]
  [ "$(dj battery_off)" = true ]
  [ "$(dj request_timeout_ms)" = 1500 ]
  [ "$(dj shadow)" = '["destructive", "suite"]' ]
  [ "$(dj enforce)" = '[]' ]
  [ "$(dj terminal)" = false ]
  [ "$(dj restarts)" = 0 ]
  case "$(dj ready_ms)" in ''|null) echo "no ready_ms"; return 1 ;; esac
  grep -q '"question": "Would running this command destroy or permanently lose data' "$FAKE_LOG"
  leash="$(dj leash_pid)"; serve="$(dj serve_pid)"; sup="$(dj supervisor_pid)"
  kill -0 "$leash"; kill -0 "$serve"; kill -0 "$sup"
  has "$(ps -o command= -p "$leash")" "ami-daemon.py --leash"
  has "$(ps -o command= -p "$serve")" "fake-decider serve"
  has "$(ps -o command= -p "$sup")" "ami-daemon.py --home $DAEDALUS_HOME"
  run FJ on
  [ "$status" -eq 0 ]
  has "$output" "already on"
  [ "$(dj supervisor_pid)" = "$sup" ]
  [ "$(supervisors)" = 1 ]
  # two at once, from a clean off
  run FJ off
  [ "$status" -eq 0 ]
  wait_gone "$sup" 5
  FJ on > "$BATS_TEST_TMPDIR/on1" 2>&1 3>&- & p1=$!
  FJ on > "$BATS_TEST_TMPDIR/on2" 2>&1 3>&- & p2=$!
  wait "$p1"; wait "$p2"
  wait_state up 15
  [ "$(supervisors)" = 1 ]
  both="$(cat "$BATS_TEST_TMPDIR/on1" "$BATS_TEST_TMPDIR/on2")"
  has "$both" "starting the AMI"
  has "$both" "already on"
}

@test "off: the sentinel is gone and daemon.json records off_by; the fake serve's pid is gone within 2 s; state is off; the sentence says freed only after the port went dead; a second off is a no-op" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  export DAEDALUS_SESSION_ID=sA
  FJ on; wait_state up 15
  serve="$(dj serve_pid)"; sup="$(dj supervisor_pid)"
  run FJ off
  [ "$status" -eq 0 ]
  [ ! -e "$AMI/on" ]
  has "$output" "the AMI is stopped and its 5 GB freed (port $PORT is closed)"
  port_closed "$PORT"
  wait_gone "$serve" 2
  wait_gone "$sup" 5
  [ "$(dj state)" = off ]
  has "$(dj off_by)" "session sA"
  run FJ off
  [ "$status" -eq 0 ]
  has "$output" "already off"
  [ ! -e "$AMI/on" ]
}

@test "borrowed: a fake already on the port whose checkpoint is the configured model — on writes the sentinel, borrowed true, serve_pid null, a supervisor in borrowed mode; off removes the sentinel, stops the supervisor and leaves the fake running, saying so; a fake answering model as the basename only still borrows" {
  PORT="$(free_port)"
  START_FAKE_PORT="$PORT" start_fake "$MODEL"
  owner="$FAKE_PID"
  write_ami_config "$PORT"
  run FJ on
  [ "$status" -eq 0 ]
  has "$output" "using the AMI already running on port $PORT"
  has "$output" "watches power only"
  [ -f "$AMI/on" ]
  wait_state up 15
  [ "$(dj borrowed)" = true ]
  [ "$(dj serve_pid)" = null ]
  [ "$(dj leash_pid)" = null ]
  sup="$(dj supervisor_pid)"
  has "$(ps -o command= -p "$sup")" "--borrowed"
  [ "$(fakes)" = 1 ]
  run FJ off
  [ "$status" -eq 0 ]
  has "$output" "was not started by this deployment and keeps running"
  lacks "$output" "freed"
  [ ! -e "$AMI/on" ]
  wait_gone "$sup" 5
  kill -0 "$owner"
  port_open "$PORT"
  # 5b: the basename trap — the fake's checkpoint is the basename only; model = basename(ami.model) still borrows
  kill "$owner"; wait_gone "$owner" 5
  START_FAKE_PORT="$PORT" start_fake strands-decider-2B-qwen3.5-v1-2610
  run FJ on
  [ "$status" -eq 0 ]
  has "$output" "using the AMI already running on port $PORT"
  wait_state up 15
  [ "$(dj borrowed)" = true ]
  [ "$(fakes)" = 1 ]
}

@test "refused: the port held by a plain HTTP server, and by a fake with another checkpoint — on refuses naming ami.port and writes no sentinel" {
  PORT="$(free_port)"
  python3 -m http.server "$PORT" --bind 127.0.0.1 > /dev/null 2>&1 3>&- < /dev/null & srv=$!
  printf '%s\n' "$srv" >> "$BATS_TEST_TMPDIR/live-pids"
  wait_for 5 port_open "$PORT"
  write_ami_config "$PORT"
  run FJ on
  [ "$status" -eq 2 ]
  has "$output" "port $PORT is held by something that is not the AMI"
  has "$output" "change ami.port in config.yaml"
  [ ! -e "$AMI/on" ]
  [ "$(supervisors)" = 0 ]
  kill "$srv"; wait_gone "$srv" 5
  START_FAKE_PORT="$PORT" start_fake other/another-checkpoint
  run FJ on
  [ "$status" -eq 2 ]
  has "$output" "port $PORT is held by something that is not the AMI"
  [ ! -e "$AMI/on" ]
  [ "$(supervisors)" = 0 ]
}

@test "battery: with the power file saying Battery Power the supervisor stops serve within one poll and writes state battery; back on AC serve returns within one poll; in borrowed mode battery is written and the fake keeps running" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  FJ on; wait_state up 15
  serve="$(dj serve_pid)"
  printf 'Battery Power\n' > "$FAKE_POWER_FILE"
  wait_state battery 5
  wait_gone "$serve" 3
  port_closed "$PORT"
  [ "$(dj serve_pid)" = null ]
  printf 'AC Power\n' > "$FAKE_POWER_FILE"
  wait_state up 15
  serve2="$(dj serve_pid)"
  [ "$serve2" != "$serve" ]
  kill -0 "$serve2"
  FJ off; wait_gone "$(dj supervisor_pid)" 5
  # borrowed mode: nothing is signalled, the state word still says battery
  START_FAKE_PORT="$PORT" start_fake "$MODEL"
  owner="$FAKE_PID"
  FJ on; wait_state up 15
  [ "$(dj borrowed)" = true ]
  printf 'Battery Power\n' > "$FAKE_POWER_FILE"
  wait_state battery 5
  kill -0 "$owner"
  port_open "$PORT"
  printf 'AC Power\n' > "$FAKE_POWER_FILE"
  wait_state up 5
  kill -0 "$owner"
}

@test "the leash: SIGKILL the supervisor and the fake serve exits within 2 s (stdin EOF); switch() reads supervisor gone from the stale heartbeat; off with a dead supervisor and a live identified serve pid stops it; off with a recorded pid that is now another process (a sleep) signals nothing and says recycled; off with the port answering and nothing on record says still answers" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  FJ on; wait_state up 15
  sup="$(dj supervisor_pid)"; leash="$(dj leash_pid)"; serve="$(dj serve_pid)"
  kill -9 "$sup"
  wait_gone "$serve" 2
  wait_gone "$leash" 3
  port_closed "$PORT"
  set_dj heartbeat "$(python3 -c 'import time; print(time.time() - 120)')"
  run ami_py 'd = a.switch_detail(ROOT, SID); print(d["state"], d["reason"])'
  [ "$output" = "down supervisor gone" ]
  # off with a dead supervisor and a live, identified serve pid: it is stopped
  START_FAKE_PORT="$PORT" start_fake "$MODEL"
  set_dj serve_pid "$FAKE_PID"; set_dj leash_pid null
  run FJ off
  [ "$status" -eq 0 ]
  has "$output" "freed (port $PORT is closed)"
  wait_gone "$FAKE_PID" 2
  [ ! -e "$AMI/on" ]
  [ "$(dj state)" = off ]
  # a recorded pid that is now another process: nothing is signalled, the sentence says recycled
  sl="$(live_pid)"
  printf '%s session shell\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AMI/on"
  set_dj serve_pid "$sl"; set_dj supervisor_pid "$sup"; set_dj leash_pid null; set_dj state '"up"'
  run FJ off
  [ "$status" -eq 0 ]
  has "$output" "recycled"
  kill -0 "$sl"
  [ ! -e "$AMI/on" ]
  # the port answers and nothing on record is that process: the sentence says so, never freed
  START_FAKE_PORT="$PORT" start_fake "$MODEL"
  printf '%s session shell\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$AMI/on"
  set_dj serve_pid null; set_dj leash_pid null; set_dj supervisor_pid "$sup"
  run FJ off
  [ "$status" -ne 0 ]
  has "$output" "port $PORT still answers"
  lacks "$output" "freed"
  kill -0 "$FAKE_PID"
}

@test "start path: a fake appearing on the port while the supervisor is in backoff is adopted as borrowed and no second serve is started (one /health per poll in the fake's log, no second fake process)" {
  PORT="$(free_port)"
  cat > "$AMI_FIX/wrapper" <<EOF
#!/usr/bin/env bash
# refuses every launch (exit 1, no terminal pattern) so the supervisor stays in backoff; counts launches
n=\$(cat "$AMI_FIX/launches" 2>/dev/null || echo 0)
echo \$((n + 1)) > "$AMI_FIX/launches"
echo "wrapper: launch \$((n + 1)) refused" >&2
exit 1
EOF
  chmod +x "$AMI_FIX/wrapper"
  cat >> "$DAEDALUS_HOME/config.yaml" <<EOF
ami:
  command: $AMI_FIX/wrapper
  model: $MODEL
  device: mps
  port: $PORT
  offline: false
  battery_off: true
EOF
  FJ on
  wait_state down 10
  [ "$(dj terminal)" = false ]
  [ "$(cat "$AMI_FIX/launches")" -ge 1 ]
  START_FAKE_PORT="$PORT" start_fake "$MODEL"
  wait_for 10 borrowed_true
  wait_state up 5
  launches="$(cat "$AMI_FIX/launches")"
  before="$(health_gets)"
  sleep 3
  [ "$(cat "$AMI_FIX/launches")" = "$launches" ]
  after="$(health_gets)"
  [ "$((after - before))" -ge 2 ]
  [ "$((after - before))" -le 4 ]
  [ "$(fakes)" = 1 ]
  [ "$(dj serve_pid)" = null ]
}

@test "terminal exit: a command that prints LocalEntryNotFoundError and exits 1 gives state down, terminal true, last_error naming the snapshot, and no relaunch across three polls" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  export FAKE_EXIT_WEIGHTS=1
  FJ on
  wait_state down 10
  [ "$(dj terminal)" = true ]
  has "$(dj last_error)" "models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610"
  has "$(dj last_error)" "weights are missing"
  sleep 3
  [ "$(grep -c '^huggingface_hub.errors.LocalEntryNotFoundError' "$AMI/daemon.log")" = 1 ]
  [ "$(dj state)" = down ]
  [ "$(dj terminal)" = true ]
  kill -0 "$(dj supervisor_pid)"
}

@test "environment: the serve process carries no CLAUDE* or DAEDALUS_* variable and no DIRECT_CALL_ID (FAKE_ENV_DUMP), HF_HUB_OFFLINE=1 only when offline is true, HF_HOME when weights_cache is set; the supervisor's own DAEDALUS_HOME came from --home" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  export FAKE_ENV_DUMP="$BATS_TEST_TMPDIR/env.json"
  export CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sX DAEDALUS_SESSION_ID=sX DAEDALUS_LEASE=03 DIRECT_CALL_ID=d1 HF_HUB_OFFLINE=1
  home="$DAEDALUS_HOME"
  # the home reaches the supervisor as --home: frame-jack.py is run with DAEDALUS_HOME unset
  env -u DAEDALUS_HOME python3 "$home/core/frame-jack.py" on
  wait_state up 15
  has "$(ps -o command= -p "$(dj supervisor_pid)")" "--home $home"
  [ "$(dj command)" = "$AMI_FIX/fake-decider" ]
  run python3 -c 'import json,sys
e = json.load(open(sys.argv[1]))
bad = sorted(k for k in e if k.startswith("CLAUDE") or k.startswith("DAEDALUS_") or k == "DIRECT_CALL_ID")
print("bad:", bad); print("offline:", e.get("HF_HUB_OFFLINE")); print("hf_home:", e.get("HF_HOME"))' "$FAKE_ENV_DUMP"
  has "$output" "bad: []"
  has "$output" "offline: None"
  has "$output" "hf_home: None"
  FJ off; wait_gone "$(dj supervisor_pid)" 5
  # offline true and a weights cache
  python3 - "$DAEDALUS_HOME/config.yaml" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s[:s.index("ami:\n")])
EOF
  cat >> "$DAEDALUS_HOME/config.yaml" <<EOF
ami:
  command: $AMI_FIX/fake-decider
  model: $MODEL
  device: mps
  port: $PORT
  offline: true
  weights_cache: $BATS_TEST_TMPDIR/hf
EOF
  rm -f "$FAKE_ENV_DUMP"
  unset HF_HUB_OFFLINE
  FJ on
  wait_state up 15
  [ "$(dj offline)" = true ]
  run python3 -c 'import json,sys
e = json.load(open(sys.argv[1])); print("offline:", e.get("HF_HUB_OFFLINE")); print("hf_home:", e.get("HF_HOME"))' "$FAKE_ENV_DUMP"
  has "$output" "offline: 1"
  has "$output" "hf_home: $BATS_TEST_TMPDIR/hf"
}

@test "on on battery with battery_off true: the sentinel is written, the supervisor waits, the sentence says waiting for AC power, no serve is started" {
  PORT="$(free_port)"; write_ami_config "$PORT"
  printf 'Battery Power\n' > "$FAKE_POWER_FILE"
  run FJ on
  [ "$status" -eq 0 ]
  has "$output" "waiting for AC power"
  [ -f "$AMI/on" ]
  wait_state battery 5
  sleep 2
  [ "$(dj state)" = battery ]
  [ "$(fakes)" = 0 ]
  port_closed "$PORT"
  kill -0 "$(dj supervisor_pid)"
}

@test "the skill: .claude/skills/frame-jack/SKILL.md is user-invocable, runs python3 core/frame-jack.py with the operator's word, and holds no logic (no state/ami, no port, no pmset in its body)" {
  f="$SRC/../.claude/skills/frame-jack/SKILL.md"
  [ -f "$f" ]
  grep -q '^name: frame-jack$' "$f"
  grep -q '^user-invocable: true$' "$f"
  grep -q 'python3 core/frame-jack.py' "$f"
  grep -q 'half a minute' "$f"
  ! grep -q 'state/ami' "$f"
  ! grep -qi 'pmset' "$f"
  ! grep -qw 'port' "$f"
}
