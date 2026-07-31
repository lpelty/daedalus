# Daedalus

A standalone agentic harness for building and maintaining Claude Code–based
harnesses. Agnostic until a codebase and a vault are supplied.

## Deploying

1. Clone this repo.
2. `cp config.example.yaml config.yaml` and fill in your target repo, KB repo,
   and gate commands.
3. `./core/sync-target.sh && ./core/sync-vault.sh`
4. `./core/doctor.sh` — verifies the deployment is correctly wired.

## Rules

- **Daedalus's own code belongs to the distribution.** Updates arrive by
  `git pull`. A deployment carries no local modifications; anything you need
  to customize belongs in `config.yaml` or your vault.
- **Daedalus writes only to `target/` and `vault/`.**
- Development happens at one site only. Defects found in Daedalus travel back
  as a proposal, not a local patch.
