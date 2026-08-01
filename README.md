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

## Rules

- **Daedalus's own code belongs to the distribution.** Updates arrive by
  `git pull`. A deployment carries no local modifications; anything you need
  to customize belongs in `config.yaml` or your vault.
- **Daedalus writes only to `target/` and `vault/`.**
- Development happens at one site only. Defects found in Daedalus travel back
  as a proposal, not a local patch.
