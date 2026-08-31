# Daedalus

A standalone agentic harness for building and maintaining Claude Code–based
harnesses. Agnostic until a codebase and a vault are supplied.

## Deploying

1. Clone this repo.
2. `cp config.example.yaml config.yaml` and fill in your target repo, its
   nested and scaffold repos, your knowledge-base repo, and your gate commands.
3. `./core/setup.sh`

Setup clones the target and its nested repos at the paths they occupy in your
real tree, recreates the directory shape of any scaffold repo, and finishes by
running the doctor. Rerun it any time — every phase is idempotent, and
rerunning is how a scaffold picks up new directories.

### Protecting your live harness

Daedalus reads your live harness as ground truth when auditing (the target
checkout is a mirror). The tracked `.claude/settings.json` only protects
Daedalus's own files, so your deployment SHOULD add a
`.claude/settings.local.json` (gitignored — see `.gitignore`) with deny rules
covering any path outside this repo Daedalus must never write, especially
your live harness:

```json
{
  "permissions": {
    "deny": [
      "Write(/path/to/your/harness/**)",
      "Edit(/path/to/your/harness/**)"
    ]
  }
}
```

## Episodic memory capture (optional)

`core/capture.py` reads Claude Code session transcripts and posts new turns to
a Hindsight episodic-memory server. It is additive: `setup.sh` and the gates
work fully with episodic capture unconfigured.

Capture runs as a `SessionEnd` hook, wired in `.claude/settings.local.json`
(gitignored, per-deployment — see `.gitignore`). That file, not a tracked
settings file, is the right home for this hook: the command line carries a
machine-specific transcript path and a secret, both of which belong to one
deployment rather than the distribution.

The script reads its configuration entirely from environment variables set
on the hook command:

- `TENANT_HOME`, `TENANT_BANK`, `TRANSCRIPT_DIR` — required.
- `HINDSIGHT_API_URL` — optional, defaults to `http://127.0.0.1:8888`.
- `TENANT_USER_LABEL`, `TENANT_ASSISTANT_LABEL` — optional, default `User` /
  `Assistant`.
- `HINDSIGHT_API_TENANT_API_KEY` — the bearer credential for the REST API
  `capture.py` posts to. This is a **different credential** from the bearer
  token a Hindsight MCP client uses against `/mcp/BANK/` — using the MCP
  token here authenticates as the wrong principal and the server returns
  `401 Invalid API key`.

Set `HINDSIGHT_API_TENANT_API_KEY` explicitly on the hook command — this is
the required setup step, not an optional one. The script falls back to a
`.env` file at a path relative to its own location on disk, a path that
resolves in the harness capture.py was vendored from. In Daedalus's directory
layout, the explicit environment variable is the path that resolves.

Worked example, `.claude/settings.local.json`:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "HINDSIGHT_API_TENANT_API_KEY=YOUR_KEY TENANT_HOME=/path/to/daedalus TENANT_BANK=daedalus TRANSCRIPT_DIR=/path/to/daedalus/transcripts python3 /path/to/daedalus/core/capture.py capture >> /path/to/daedalus/.capture.log 2>&1"
          }
        ]
      }
    ]
  }
}
```

### What happens when extraction fails

The server returns `202` when it *accepts* a batch; extraction runs afterwards
and can fail on its own. The `SessionEnd` hook cannot wait for that verdict —
Claude Code gives its hooks a shared budget of roughly a second and a half,
while extraction takes tens of seconds — so the hook records each pushed span
in a retry ledger inside `state/hindsight/offsets.json` and returns.

Every later run of `capture.py capture` (including `core/close.sh`) settles
that ledger first: it asks the server how each pending operation ended, drops
the spans that were stored, keeps the ones still running or unreachable, and
re-pushes the ones that failed. A re-push reuses the original `document_id`s,
which the API treats as replacing that document rather than adding a second
copy of it.

`core/capture.py status` prints the spans that are still unconfirmed. A
non-empty list there means those turns may not be in memory yet; it should
return to zero on its own once the backend is healthy.

### Reading memory back (optional)

Capture writes; two mechanisms read.

**The `recall` skill** ships at `.claude/skills/recall/SKILL.md` and needs no
wiring. It documents the query command, which is `core/capture.py recall`.

**Automatic injection** is a `UserPromptSubmit` hook. `core/recall-inject.py`
queries the bank with the prompt and returns matches as `additionalContext`,
so continuity survives a session boundary without anyone asking for it. It
shares the credentials above, and it is optional — a deployment without it
works, and the skill still does.

Add alongside the `SessionEnd` block in `.claude/settings.local.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "HINDSIGHT_API_TENANT_API_KEY=YOUR_KEY TENANT_HOME=/path/to/daedalus TENANT_BANK=daedalus TRANSCRIPT_DIR=/path/to/daedalus/transcripts python3 /path/to/daedalus/core/recall-inject.py"
          }
        ]
      }
    ]
  }
}
```

The injector fails silent on every path — unreachable backend, absent
configuration, malformed input, empty result. It emits nothing and exits 0,
so a session runs normally whether or not memory is reachable. Its gates are
deliberately conservative: prompts shorter than four words are skipped, and
at most five memories are surfaced. Those numbers are a starting position,
and a recorded miss is what argues for loosening them.

## Rules

- **Daedalus's own code belongs to the distribution.** Updates arrive by
  `git pull`. A deployment carries no local modifications; anything you need
  to customize belongs in `config.yaml` or your vault.
- **Daedalus's write surfaces are `target/`, `vault/`, and `.claude/` (aside
  from the tracked `settings.json`).** Skills it authors and scratch space
  its tooling needs are its own work product, not distribution.
- Development happens at one site only. Defects found in Daedalus travel back
  as a proposal, not a local patch.

### The verify stage

Hooks in the tracked `.claude/settings.json` make a completion claim
unrecordable without evidence. `core/gates.sh` writes the evidence; the
`Stop` hook checks any `IMPLEMENTED`/`completion` document changed this
session against it; the boundary hook blocks edits to Daedalus's own code,
the gate definition, and the evidence. Everything is snapshotted at session
start, so if you change `config.yaml` or a file under `core/` mid-session,
Daedalus is blocked with a reason naming the remedy: restart the session.
On a new machine the hooks are held until the workspace-trust dialog is
accepted. `core/doctor.sh` reports unverified claims offline.
