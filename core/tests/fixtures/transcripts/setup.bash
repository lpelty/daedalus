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
