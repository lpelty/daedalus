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

## Rules

- **Daedalus's own code belongs to the distribution.** Updates arrive by
  `git pull`. A deployment carries no local modifications; anything you need
  to customize belongs in `config.yaml` or your vault.
- **Daedalus's write surfaces are `target/`, `vault/`, and `.claude/` (aside
  from the tracked `settings.json`).** Skills it authors and scratch space
  its tooling needs are its own work product, not distribution.
- Development happens at one site only. Defects found in Daedalus travel back
  as a proposal, not a local patch.
