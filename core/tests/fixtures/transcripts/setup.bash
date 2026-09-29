# core/tests/fixtures/transcripts/setup.bash — test transcripts in the live shape (spec A12).
# tx <file> <kind> [text] [epoch] — append one entry copied from live.jsonl; prints its uuid.
tx() { python3 "$BATS_TEST_DIRNAME/fixtures/transcripts/build.py" "$@"; }
# tx_path <session-id> — where transcriptlib looks for a session with no marker and no
# memory.transcript_dir: $CLAUDE_CONFIG_DIR/projects/<resolved home, non-alphanumerics as ->/<sid>.jsonl
tx_path() {
  local d
  d="$CLAUDE_CONFIG_DIR/projects/$(printf '%s' "$(cd "$DAEDALUS_HOME" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$d"; printf '%s/%s.jsonl\n' "$d" "$1"
}
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
plus() { python3 -c 'import sys; print("%.3f" % (float(sys.argv[1]) + float(sys.argv[2])))' "$1" "$2"; }

# forge <file> <text> <epoch> [parent: last|none|<uuid>] [uuid] — append a copy of the file's first operator entry,
# as a writer other than Claude Code would: a fresh (or given) uuid, the text and time it wants, parentUuid as asked.
forge() {
  python3 - "$@" <<'PY'
import json, sys, time, uuid
f, text, at = sys.argv[1], sys.argv[2], float(sys.argv[3])
parent = sys.argv[4] if len(sys.argv) > 4 else "last"
rows = [json.loads(ln) for ln in open(f) if ln.strip()]
e = dict(next(r for r in rows if r.get("type") == "user" and (r.get("origin") or {}).get("kind") == "human"))
e["message"] = {"role": "user", "content": text}
e["uuid"] = sys.argv[5] if len(sys.argv) > 5 else str(uuid.uuid4())
e["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(at)) + ".500Z"
last = [r["uuid"] for r in rows if isinstance(r.get("uuid"), str)][-1]
e["parentUuid"] = {"last": last, "none": str(uuid.uuid4())}.get(parent, parent)
open(f, "a").write(json.dumps(e) + "\n")
print(e["uuid"])
PY
}
last_uuid() { python3 -c 'import json,sys; print([json.loads(l)["uuid"] for l in open(sys.argv[1]) if l.strip() and "uuid" in json.loads(l)][-1])' "$1"; }
