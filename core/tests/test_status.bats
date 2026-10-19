#!/usr/bin/env bats
# core/status.py — whether this deployment's services are running (service-status spec §3, §5 item 1). Fixture homes
# only: a config.yaml written per test, a throwaway HTTP server on a free port standing for the memory server, a
# closed port for its down case (the real Hindsight server is never stopped), state files written by hand. No model,
# no network beyond 127.0.0.1.
bats_require_minimum_version 1.5.0

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ST="$REPO/core/status.py"
  H="$BATS_TEST_TMPDIR/home"
  mkdir -p "$H/state"
  : > "$H/config.yaml"
  TD="$BATS_TEST_TMPDIR/transcripts"; mkdir -p "$TD"
  PIDS=()
}

teardown() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
}

S() { python3 "$ST" --json --home "$H" </dev/null; }

# field <stem> <key> — one field of one row of the last `run S`
field() {
  printf '%s' "$output" | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(next(s for s in d["services"] if s["stem"] == sys.argv[1])[sys.argv[2]])' "$1" "$2"
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

# serve <code> — an HTTP server on a free port answering every GET with <code>; prints the port
serve() {
  local port; port="$(free_port)"
  python3 -c 'import http.server, sys
code = int(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(code); self.end_headers(); self.wfile.write(b"{}")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()' "$port" "$1" >/dev/null 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 50); do python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.1)' "$port" 2>/dev/null && break; sleep 0.05; done
  SERVED="$port"
}

# listen — a bare TCP listener on a free port (the decider's port); sets LISTENED
listen() {
  local port; port="$(free_port)"
  python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
time.sleep(60)' "$port" >/dev/null 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 50); do python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 0.1)' "$port" 2>/dev/null && break; sleep 0.05; done
  LISTENED="$port"
}

memory_block() { printf 'memory:\n  bank: test\n  api_url: %s\n  capture_interval: 120\n  transcript_dir: %s\n' "$1" "$TD" >> "$H/config.yaml"; }

@test "the JSON has the shared status shape: five rows of exactly stem, name, state and detail, in order, and checked_at; exit 0 in under 2 s" {
  start="$(python3 -c 'import time; print(time.time())')"
  run S
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  python3 - "$output" "$start" <<'PY'
import json, sys, time
from datetime import datetime
d = json.loads(sys.argv[1])
assert set(d) == {"services", "checked_at"}, d
assert [s["stem"] for s in d["services"]] == ["hindsight", "capture", "vault-index", "ami", "code-graph"], d
for s in d["services"]:
    assert set(s) == {"stem", "name", "state", "detail"}, s
    assert s["state"] in ("up", "down", "not-set-up"), s
    assert s["name"] and s["name"] != s["stem"] and s["detail"], s
datetime.fromisoformat(d["checked_at"])
assert time.time() - float(sys.argv[2]) < 2.0
PY
}

@test "a config with none of the blocks: every row not-set-up, each detail naming the missing block" {
  run S
  [ "$status" -eq 0 ]
  for s in hindsight capture vault-index ami code-graph; do [ "$(field $s state)" = not-set-up ] || { echo "$s: $output"; return 1; }; done
  [ "$(field hindsight detail)" = "no memory: block in config.yaml" ]
  [ "$(field vault-index detail)" = "no recall: block in config.yaml" ]
  [ "$(field ami detail)" = "no ami: block in config.yaml" ]
  [ "$(field code-graph detail)" = "no context: block in config.yaml" ]
}

@test "a commented-out block is no block, as lib.sh cfg reads it" {
  printf '# memory:\n#   api_url: http://127.0.0.1:1\n# ami:\n#   port: 8761\n' > "$H/config.yaml"
  run S
  [ "$(field hindsight state)" = not-set-up ]
  [ "$(field ami state)" = not-set-up ]
}

@test "the memory server: up when /health answers 2xx; down on a closed port, and on a 5xx; another host is not checked" {
  serve 200
  memory_block "http://127.0.0.1:$SERVED"
  run S
  [ "$(field hindsight state)" = up ] || { echo "$output"; return 1; }
  [ "$(field hindsight detail)" = "127.0.0.1:$SERVED answered" ]
  closed="$(free_port)"
  : > "$H/config.yaml"; memory_block "http://127.0.0.1:$closed"
  run S
  [ "$(field hindsight state)" = down ]
  [ "$(field hindsight detail)" = "127.0.0.1:$closed did not answer within 1 s" ]
  serve 503
  : > "$H/config.yaml"; memory_block "http://127.0.0.1:$SERVED"
  run S
  [ "$(field hindsight state)" = down ]
  [ "$(field hindsight detail)" = "127.0.0.1:$SERVED answered HTTP 503" ]
  : > "$H/config.yaml"; memory_block "http://memory.example.invalid:8888"
  run S
  [ "$(field hindsight state)" = not-set-up ]
  [ "$(field hindsight detail)" = "memory.example.invalid:8888 is not on this machine, so it is not checked" ]
}

@test "the memory server: no api_url is lib.sh memory_env's default, 127.0.0.1:8888 (only the detail is asserted: one read-only GET to whatever answers there; nothing is ever stopped)" {
  printf 'memory:\n  bank: test\n' > "$H/config.yaml"
  run env -u HINDSIGHT_API_URL python3 "$ST" --json --home "$H"
  case "$(field hindsight detail)" in "127.0.0.1:8888 "*) : ;; *) echo "$output"; return 1 ;; esac
}

# capture fixtures: offsets.json naming one transcript, captured <cap> seconds ago up to its current size, then rows
# appended after that offset with the given ages (seconds before now)
capture_fixture() {   # capture_fixture <seconds since the last capture> [<type>:<age> ...]
  local cap="$1"; shift
  python3 - "$H" "$TD/s1.jsonl" "$cap" "$@" <<'PY'
import json, os, sys, time
from datetime import datetime, timezone
home, path, cap = sys.argv[1], sys.argv[2], float(sys.argv[3])
now = time.time()
def stamp(age): return datetime.fromtimestamp(now - age, timezone.utc).isoformat().replace("+00:00", "Z")
with open(path, "w") as f:
    f.write(json.dumps({"type": "user", "timestamp": stamp(cap + 30), "message": {"role": "user", "content": "x"}}) + "\n")
size = os.path.getsize(path)
os.makedirs(os.path.join(home, "state", "hindsight"), exist_ok=True)
json.dump({"offsets": {path: size}, "pending": [], "transcripts": {path: {"last_capture": now - cap}}},
          open(os.path.join(home, "state", "hindsight", "offsets.json"), "w"))
newest = None
with open(path, "a") as f:
    for spec in sys.argv[4:]:
        kind, age = spec.split(":"); age = float(age)
        rec = {"type": kind, "timestamp": stamp(age)}
        if kind == "system": rec["subtype"] = "away_summary"
        # a slash command's rows (/reload-plugins): user rows the engine writes with no model turn, so no Stop follows
        if kind == "command": rec = {"type": "user", "timestamp": stamp(age), "message": {"role": "user", "content": "<command-name>/reload-plugins</command-name>"}}
        # a compaction's summary: a user row written before the next turn
        if kind == "compact": rec = {"type": "user", "timestamp": stamp(age), "isCompactSummary": True, "message": {"role": "user", "content": "This session is being continued"}}
        f.write(json.dumps(rec) + "\n")
        newest = age if newest is None else min(newest, age)
age = newest if newest is not None else cap
os.utime(path, (now - age, now - age))
PY
}

@test "memory capture: up while the last capture is within 3 x capture_interval; down when a session was active after it and capture missed it" {
  memory_block "http://127.0.0.1:$(free_port)"
  capture_fixture 100
  run S
  [ "$(field capture state)" = up ] || { echo "$output"; return 1; }
  [ "$(field capture detail)" = "last capture 1 min ago" ]
  # captured 40 min ago; an assistant row 30 min ago (10 min after the capture: its Stop was not throttled)
  capture_fixture 2400 assistant:1800
  run S
  [ "$(field capture state)" = down ] || { echo "$output"; return 1; }
  [ "$(field capture detail)" = "last capture 40 min ago; a session was active 30 min ago" ]
}

@test "memory capture: no session activity since is up — the engine's own rows after a turn (an away summary minutes later) are not activity" {
  memory_block "http://127.0.0.1:$(free_port)"
  capture_fixture 2400 system:2200
  run S
  [ "$(field capture state)" = up ] || { echo "$output"; return 1; }
  [ "$(field capture detail)" = "last capture 40 min ago; no session activity since" ]
}

@test "memory capture: a slash command or a compaction with no reply after it is not a miss — no turn ran, so no Stop could capture it (2026-10-18: capture read down after /reload-plugins until the next message)" {
  memory_block "http://127.0.0.1:9"
  capture_fixture 2400 command:1800
  run S
  [ "$(field capture state)" = up ] || { echo "$output"; return 1; }
  capture_fixture 2400 compact:1800
  run S
  [ "$(field capture state)" = up ] || { echo "$output"; return 1; }
  # the same rows followed by a reply that capture missed: still down
  capture_fixture 2400 command:1800 assistant:1790
  run S
  [ "$(field capture state)" = down ] || { echo "$output"; return 1; }
}

@test "memory capture: a turn still running (a row within 3 intervals), and a short turn the Stop tick throttled, are not misses" {
  memory_block "http://127.0.0.1:$(free_port)"
  capture_fixture 2400 assistant:200
  run S
  [ "$(field capture state)" = up ] || { echo "$output"; return 1; }
  # a turn that ended 60 s after the capture: throttled at Stop (capture_interval 120), taken at SessionEnd
  capture_fixture 2400 assistant:2340
  run S
  [ "$(field capture state)" = up ] || { echo "$output"; return 1; }
}

@test "vault search: up when recall.store is a readable directory under the home; down when missing; not-set-up without recall:" {
  printf 'recall:\n  store: state/chroma\n' > "$H/config.yaml"
  run S
  [ "$(field vault-index state)" = down ]
  [ "$(field vault-index detail)" = "store state/chroma is missing" ]
  mkdir -p "$H/state/chroma"
  run S
  [ "$(field vault-index state)" = up ]
  [ "$(field vault-index detail)" = "store state/chroma" ]
}

# ami fixtures: the switch files amilib.switch_detail reads (frame-jack spec §5.1), written by hand
ami_block() { printf 'ami:\n  command: %s\n  port: %s\n' "$BATS_TEST_TMPDIR/decider" "$1" >> "$H/config.yaml"; }
ami_on() {   # ami_on <port>: switched on, the daemon recorded on that port with a fresh heartbeat
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/decider"; chmod +x "$BATS_TEST_TMPDIR/decider"
  mkdir -p "$H/state/ami"; : > "$H/state/ami/on"
  python3 -c 'import json, sys, time
json.dump({"command": sys.argv[2], "port": int(sys.argv[3]), "heartbeat": time.time(), "state": "on", "device": "cpu", "since": time.time()}, open(sys.argv[1], "w"))' \
    "$H/state/ami/daemon.json" "$BATS_TEST_TMPDIR/decider" "$1"
}

@test "decider: up when switched on and its port answers; down when the port is closed; not-set-up when never switched on, or switched off (off is not down)" {
  listen
  ami_block "$LISTENED"
  run S
  [ "$(field ami state)" = not-set-up ]
  [ "$(field ami detail)" = "frame-jack was never switched on here" ]
  ami_on "$LISTENED"
  run S
  [ "$(field ami state)" = up ] || { echo "$output"; return 1; }
  [ "$(field ami detail)" = "port $LISTENED" ]
  rm "$H/state/ami/on"     # what /frame-jack off leaves: state/ami/ without its sentinel
  run S
  [ "$(field ami state)" = not-set-up ]
  [ "$(field ami detail)" = "frame-jack is off" ]
  closed="$(free_port)"
  ami_on "$closed"
  run S
  [ "$(field ami state)" = down ]
  [ "$(field ami detail)" = "port $closed does not answer — /frame-jack on" ]
}

@test "code graph: up when context.graph is executable; down when it is not, or missing; not-set-up with no graph line" {
  printf 'context:\n  graph: %s\n' "$BATS_TEST_TMPDIR/crg" > "$H/config.yaml"
  run S
  [ "$(field code-graph state)" = down ]
  [ "$(field code-graph detail)" = "context.graph is missing" ]
  printf '#!/bin/sh\n' > "$BATS_TEST_TMPDIR/crg"
  run S
  [ "$(field code-graph detail)" = "context.graph is not executable" ]
  chmod +x "$BATS_TEST_TMPDIR/crg"
  run S
  [ "$(field code-graph state)" = up ]
  [ "$(field code-graph detail)" = "crg found" ]
  printf 'context:\n  module_roots: engine\n' > "$H/config.yaml"
  run S
  [ "$(field code-graph state)" = not-set-up ]
}

@test "no config.yaml is exit 2 with one sentence, nothing on stdout; an unknown flag is exit 2" {
  rm "$H/config.yaml"
  run --separate-stderr python3 "$ST" --json --home "$H"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "daedalus: no config.yaml in $(cd "$H" && pwd -P), so no service can be checked" ] || [ "$stderr" = "daedalus: no config.yaml in $H, so no service can be checked" ] || { echo "$stderr"; return 1; }
  run python3 "$ST" --verbose --home "$H"
  [ "$status" -eq 2 ]
}

@test "the plain form is one line per service and the check time, for a person at a shell" {
  run python3 "$ST" --home "$H"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" = 6 ]
  printf '%s\n' "$output" | grep -q '^memory server  *not-set-up  *no memory: block in config.yaml$'
  printf '%s\n' "$output" | tail -1 | grep -q '^checked at '
}

@test "status.py reads only: it names no subprocess, no git and no writer, and leaves no bytecode in core/" {
  ! grep -nE "subprocess|os\.system|os\.popen|['\"]git['\"]|\.write_text|open\([^)]*['\"][wa]" "$ST"
  before="$(ls "$REPO/core" | grep -c __pycache__ || true)"
  run S
  [ "$(ls "$REPO/core" | grep -c __pycache__ || true)" = "$before" ]
}
