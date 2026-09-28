# live.jsonl — where it came from

A redacted copy of one interactive Claude Code session transcript, made once
on 2026-09-28 from a transcript of Claude Code 2.1.282 (the `version` field of
its operator-typed entries) — the newest build on this machine with
operator-typed turns. The installed build was 2.1.283; its interactive
transcript shape was not measured (no session of it had an operator-typed turn
yet) — regenerate this file from one. Every
string value was replaced by `placeholder` (or `placeholder text` for message
text) except the structural keys: `type`, `uuid`, `parentUuid`, `timestamp`,
`userType`, `entrypoint`, `version`, `promptSource`, `subtype`, `level`,
`role`, `kind`, `turnOrigin`, `operation`, `stop_reason`; session ids are one
fixed placeholder uuid. Keys that can be paths (holding a `/`, or under
`trackedFileBackups` or `_meta`) were replaced by `placeholder-N`, and
file-history entries were dropped. At most three entries of each kind were
kept, in file order.

Why: the transcript format is internal to Claude Code and changes between
versions (spec A12). The capture parser and the operator's-yes check both
read this shape; `test_capture.bats` and `test_transcript.bats` read this
file, and `fixtures/transcripts/build.py` copies its entries to build every
promote and prime-take transcript. When a Claude Code release changes the
shape those tests fail first — regenerate this file from a new transcript the
same way, and update the parser, before trusting a transcribed yes.
