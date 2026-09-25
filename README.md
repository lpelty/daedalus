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

### Pitfall triggers

A pitfall in `vault/pitfalls/` can declare what it applies to, and the hook in
the tracked `.claude/settings.json` surfaces it on the matching tool call:

    applies-to:
      bash:
        - '<python regex over the command>'
      path:
        - '<glob over the path, relative to the target checkout>'
    enforce: inject | warn | block

`inject` attaches the pitfall to the tool result. `warn` denies the call once
per session with the pitfall as the reason, then lets the retry through.
`block` denies it every time. Block-lists only, one pattern per line, quoted
or bare (bare items lose a trailing ` #comment`).
`core/doctor.sh` reports pitfalls that cannot fire and files it cannot parse;
`python3 core/pitfall-inject.py --parse <file>` shows how one file is read.

On a new machine the tracked hooks are held until the workspace-trust dialog
is accepted the first time Claude Code opens this directory.

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

#### The refuter (rung 2)

After every PASS, `core/refute.sh` hands the run to a fresh-context reviewer
and a `VERDICT: REFUTED` flips it to FAIL with the review
(`vault/evidence/<run-id>-review.md`) as the log. The reviewer is the charter
at `core/agents/refuter.md` — a Claude Code subagent definition restricted to
`Read`, `Grep` and `Glob` (no `Bash`, no `Edit`, no `Write`), a pinned model,
bounded turns, and deliberately no memory: it never sees the author's
reasoning and starts from nothing every run. It receives the acceptance
criteria (`GATES_CRITERIA=<file>` when calling `core/gates.sh`), the evidence
record, the pitfalls whose `applies-to: path:` matches a touched path (plus
every pitfall with no `applies-to:`), and the diff — in that order — and is
told the checkout's absolute path so it can read the touched files. A
pitfall selector that crashes or is missing makes the run uncertifiable
(FAIL), never a silent "(none)".

The diff is assembled per repository: the target checkout against
`origin/<target.branch>`, then each `target.nested` checkout against its
origin's default branch, every path prefixed with the nested relpath so the
reviewer and the pitfall globs see target-relative paths; committed work
since the merge base, then uncommitted and untracked work against `HEAD`
(through a temporary index — the real index is never touched). A nested
repo the outer `.gitignore` hides, or one tracked as a gitlink, contributes
its content, not a `Subproject commit` stamp. An **empty** assembled diff is
uncertifiable (exit 2, "nothing to review"): the run FAILs rather than
handing nothing to the reviewer — so the first, arming run of `gates.sh` on
a clean tree records a FAIL, which still arms the stage.

`core/gates.sh` runs the review inline, and the review can take minutes.
Invoke it with a timeout of at least the gates' own time plus
`verify.refute_timeout` (600 s by default) — from the Claude Code Bash tool
that means its `timeout` parameter, or run it in the background — because
a tool timeout kills the gate's process group mid-review. The watchdog
takes the reviewer down with it (nothing outlives it) and the vault summary
and `run.json` are written only after the verdict, so a killed run leaves
no PASS-labelled evidence behind; but the run is lost and must be re-done.

The charter lives under `core/` because `claude -p --agent <name>` resolves
only from `.claude/agents/` of the working directory, which is one of
Daedalus's write surfaces; `core/` is not. `refute.sh` renders it with
`core/agentdef.py` and passes the result to `claude --agents`, and runs
`claude` from an empty temporary directory with the target granted through
`--add-dir`. That is what keeps project instructions out of the review: the
charter requests `omitClaudeMd`, but measured on Claude Code 2.1.282 that
key in an `--agents` definition does not stop `claude -p --agent` from
loading the working directory's `CLAUDE.md`, whereas a `CLAUDE.md` under an
`--add-dir` directory is not loaded. So neither Daedalus's nor the target's
`CLAUDE.md` reaches the reviewer. The user-level `~/.claude/CLAUDE.md` of the
account running Daedalus still does (also measured); if that matters on
your deployment, keep it free of anything that would steer a reviewer.

It is **on by default**: an unset `verify.refute` means `true`. To turn it
off, set `verify.refute: false` *and* a non-empty `verify.refute_off_reason`
saying why — without the reason `core/gates.sh` refuses to run any gate.
`verify.refute_model` overrides the charter's model; `verify.refute_timeout`
(default 600 s) bounds the review, and a review that crashes, times out or
ends without a verdict is uncertifiable and FAILs the run — never STANDS.
`core/doctor.sh` also checks that `config.yaml`'s `target.branch` exists at
the target's origin, since every branch-aware guard reads it: a branch origin
does not have is MISSING; one that exists but is not the remote's default
branch is a NOTE naming both, because a deployment may guard a trunk that is
not the default and `setup.sh` must not be blocked by that. That shape is
also what a *wrong* `target.branch` looks like (the originating incident:
config `main`, origin default `mainline`, `main` present too), so the branch
guard denies pushes and commits to the remote's default branch
(`refs/remotes/origin/HEAD`) as well as to the configured trunk, `main` and
`master` — the guard holds even when the config is wrong.

**For the maintainer:** this checkout is also the development site, so a
plain development session in here fires these same hooks — they don't know
the difference between an assignment and you editing `core/` by hand. For a
one-off session, start it with hooks off: `claude --settings
'{"disableAllHooks": true}'`. To leave hooks off for a whole working
session, set `disableAllHooks` in the untracked `.claude/settings.local.json`
instead — but do that *before* you start, not mid-session: the boundary
hook's check 2 hashes that file's `hooks` and `disableAllHooks` keys against
the session-start snapshot, so setting it after the session has already
begun reads as tampering and blocks.
