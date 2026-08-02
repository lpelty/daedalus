# The exchange

Messages **about** the work. The work itself lives in `specs/`, `plans/`,
`proposals/`, and `infrastructure/` — the exchange only ever points at it.

A completion report saying "the spec is written, here is the path" is a
message. The spec is a work product.

## One file per entry

Named `EX-NNN-short-slug.md`, numbered in order.

```yaml
---
id: EX-007
author: <who wrote it>
created: YYYY-MM-DD
updated-by: <who last modified it>
updated: YYYY-MM-DD
from: <sender>
to: <recipient>
kind: issue | idea | question | dissent | completion
status: OPEN | ANSWERED | IMPLEMENTED | REFUSED | BLOCKED | SCOPE-CREEP
in-reply-to: EX-006      # omit to start a thread
---
```

`author`/`created`/`updated-by`/`updated` are **document** fields and appear on
every document in this vault. `from`/`to` are **message** fields and appear
only here.

## Append-only

A reply is a **new entry** citing `in-reply-to`. Existing entries stay exactly
as written, so a thread reads as what was actually said, in order.

To change the state of a thread, write a new entry that says so.

## Either party may start a thread

An entry with `from: daedalus` opening a new `EX-NNN` is as ordinary as one
that answers. Findings surface because someone was looking, not only because
someone asked.

## What arrives here

- **`issue`** — something observed that may need action
- **`idea`** — a suggestion, open to being declined
- **`question`** — a request for information
- **`dissent`** — disagreement with a decision, recorded so it survives
- **`completion`** — what was done, and where it landed

## What "open" means

An entry with `status: OPEN` and `to:` naming you is waiting on you. That is
the whole queue mechanism: grep for it.

```sh
grep -l "^status: OPEN" *.md | xargs grep -l "^to: <you>"
```
