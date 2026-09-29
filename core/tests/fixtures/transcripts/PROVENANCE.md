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

## Drift is seen before a promotion (plan 4 completeness critic, finding 4)

The suite reads only this file, so it cannot notice a newer build. Doctor
does, read-only: in `promote.confirm: transcribed` it runs transcriptlib's
parser over the newest transcript of this deployment's sessions that has
turns a person typed (headless sdk prompts carry no origin by design and are
skipped) and prints OK naming the build, or MISSING with "this Claude Code
build's transcript shape is not the one Daedalus was tested against; promote
confirm will refuse until the fixture is refreshed". Confirm refuses with the
same sentence when a transcript's typed turns carry no origin field and none
is marked as typed by a person. When either says so: regenerate `live.jsonl`
from a transcript of the installed build as described above, run
`bats core/tests/test_capture.bats core/tests/test_transcript.bats`, update
`core/transcriptlib.py` until they pass, and use `promote.confirm: tty`
meanwhile.

## The chain the harness-written check reads (finding 2)

`transcriptlib.harness_wrote` accepts a typed yes only on the chain back from
the file's last entry, with an assistant entry after it, in a file whose uuids
are unique and whose parentUuids name earlier entries. This fixture keeps at
most three entries of each kind, so its chain is broken by design; what it can
show (unique uuids, no parent written after its child, timestamps out of file
order) `test_transcript.bats` pins. `build.py` links every entry it writes to
the file's last one and writes the harness's reply after a typed turn.
