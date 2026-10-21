---
type: rolling-state
leases:             # the lease board when core/hot.py last wrote this: which windows are open and why (intent, not status)
author: <who wrote this>
created: YYYY-MM-DD
updated-by: <who last modified this>
updated: YYYY-MM-DD
---

# Hot — where the work stands

**This file records intent: what is underway, what is next, what is waiting
and on whom.**

Service health, repo state, and test counts belong to whatever probes them
live. A status line written here is re-read as current fact indefinitely,
because nothing re-verifies prose and it is indistinguishable from a live
probe at read time.

**The test: can this change without anyone editing a file? Then it is state —
probe it.**

Every session start shows In flight and Blocked. Change them only with
`python3 core/hot.py` (`add`, `update`, `remove`, `keep`); nobody edits this
file by hand. Each entry is one block in this shape:

```markdown
### <topic, one line>
- owner: <window NN, or operator, or another agent's name>
- since: YYYY-MM-DD
- where: <branch / file / proposal / backlog id>
- next: <the one next action>
- done when: <the observable condition that removes this entry>
```

`kept: YYYY-MM-DD` is added when the operator keeps an entry after its 14-day
question; it restarts the clock. Entries keep to these fields. History,
rounds and evidence go in the session log; a design question goes in a
proposal; work for later goes in a backlog row. What was done belongs in the
session log, not here; a standing rule or gotcha goes in `pitfalls/` or
CLAUDE.md. Every start names any other `##` section, so nothing here is
hidden. When an entry's `done when:` is met, the session that sees it removes
it in that same turn.

## In flight

<!-- The assignment underway, one entry each. -->

## Blocked

<!-- Questions asked and unanswered; the owner is who answers. -->
