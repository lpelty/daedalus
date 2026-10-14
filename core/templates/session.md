---
type: session
lease: NN
alias:
lease-created: YYYY-MM-DDTHH:MM:SS
author: <who wrote this>
created: YYYY-MM-DD
updated-by: <who last modified this>
updated: YYYY-MM-DD
assignment: EX-NNN
touched: []
findings: 0
status: open
---

<!-- File: vault/sessions/YYYY/MM/YYYY-MM-DD-NNN.md — NNN is the vault's one
     running counter. The session start says your path for today and
     `core/lease.sh log` prints it again; never count the directory. The
     window is `lease:` below, not the filename. A restart under the same
     lease instance (same lease-created) on the same day appends a
     "## Continued HH:MM" section here. See the session-logs section of
     CLAUDE.md. -->

# Session YYYY-MM-DD-NNN, window NN — <what this session was about>

<!-- The reader of this log is you, retrieving. Retrieval surfaces one
     fragment without its neighbours, so every entry must stand alone: name
     the subject in the line itself rather than relying on the heading above
     it or the bullet before it. Bullets everywhere except Context. -->

## Context

<!-- Prose, deliberately. A paragraph or a sentence.
     The question to answer: why did this session need to happen?
     A list of what happened never explains why the work existed, and this is
     the one part a human reads naturally. -->

## Decisions

<!-- One per line: <decision> — because <reasoning>.
     Git shows the code and never the rejected alternative. -->

## What I got wrong

<!-- What was believed, what overturned it, what replaced it.
     This exists nowhere else — failed attempts are never committed. -->

## Confidence

<!-- Per claim: verified / assumed / unverifiable, with the reason for the
     third. Commits assert; they do not qualify. -->

## Left open

<!-- With the reason. Otherwise deliberate omission and forgetting look
     identical a month later. -->
