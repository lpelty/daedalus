---
name: recall
description: Query episodic memory for what past sessions established — decisions, findings, how a system was observed to behave. Use when a question depends on prior work, when the operator refers to something decided earlier, when resuming an assignment, or when asked to recall, remember, or check what was found before.
user-invocable: true
---

# recall

Episodic memory holds what past sessions established: decisions and their
reasoning, findings from audits, and observations about how the target
harness actually behaved. It accumulates automatically — the `SessionEnd`
hook captures each session's transcript, and a background extractor turns it
into typed memories.

Reading it back is this skill.

## When to use it

Ask memory first whenever the answer plausibly already exists:

- A question about a past decision — "what did we decide about X", "why is it
  built this way"
- A named system, document, or assignment worked on before
- "Continue", "last time", "as before", "pick this back up"
- Resuming an assignment whose earlier rounds are not in this session's context
- A claim that feels familiar but unverified — memory may hold the evidence

For a self-contained request with no plausible dependency on prior work,
answer directly. Querying reflexively costs latency on every turn; querying
when the answer is stored is what keeps work continuous across sessions.

## Run it

```bash
TENANT_HOME=<deployment root> \
TENANT_BANK=<bank name> \
TRANSCRIPT_DIR=<transcript directory> \
python3 <deployment root>/core/capture.py recall "<query>"
```

All three variables are required — `capture.py` validates them before
dispatching any command, so recall exits early without them even though it
reads no transcript. The same values appear in the `SessionEnd` capture hook
in `.claude/settings.local.json`; read them from there rather than guessing.

`HINDSIGHT_API_URL` defaults to `http://127.0.0.1:8888`. The API key is read
from `HINDSIGHT_API_TENANT_API_KEY`, or from a `.env` file beside
`capture.py`. Note that this key is the REST API key, which is a different
credential from the MCP bearer token.

### Narrow by type

```bash
… capture.py recall "<query>" --types world,experience,observation
```

- **world** — durable facts about how things are
- **experience** — what happened in a session, with its date
- **observation** — something noticed, often about the target harness

Omit `--types` to search all three.

## Reading the output

```
3 result(s):
  [world] The target harness stores its rendered goals under state/goals/.
  [observation] The scheduler executes rendered goal files rather than the
                manifest, so an unenrolled goal still runs.
  [experience] Audited the identity layer and found four defects in the
               rebuild procedure. | When: on August 01, 2026
```

Each line is one memory, printed in full. Results are ranked by relevance,
so the first few carry the most signal.

Treat what comes back as **true as of when it was recorded**, not as current
state. An `experience` memory carries its date for exactly this reason. When
a recalled fact would change what you do, verify it against the live system
before acting on it — memory says what was observed, and the system says what
is.

## When nothing comes back

`0 result(s)` means the query found nothing, which has several ordinary
causes: the work predates capture, extraction has not yet processed the most
recent session, or the phrasing missed. Rephrase once with different nouns
before concluding the memory is absent.

A `recall failed:` line means the backend is unreachable or the credential is
wrong. That is a tooling problem, not an empty memory — say so plainly rather
than reporting that nothing was found.

## Document recall

Episodic recall answers "what happened"; document recall answers "what is
written". When the question is about vault content — a spec, a plan, an
exchange entry, "where is X written" — query the vault index:

```bash
python3 <deployment root>/core/vault-search.py query "<text>"
```

Output is a JSON array of `{"path", "snippet", ...}` results, best-first.
Empty output means no index, no engine configured, or no hits — fall back
to grep over `vault/`. Never compose the engine command yourself; the
runner is the only execution path.
