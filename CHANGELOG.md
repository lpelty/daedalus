# Changelog

Releases are annotated git tags (`git tag -a vX.Y.Z -F <notes>`); the notes
for each release live here first, and the tag message repeats the headline.
Earlier releases (v0.1.0 – v0.6.0) are described by their tag messages only.

## v0.6.1 — branch guard reads the configured trunk; refuter on by default

Prompted by a live defect on a deployment whose GitLab trunk is named
`mainline` (the deployment is not named here: distribution files carry no
environment facts — see `core/tests/test_identity.bats`): `core/guard-bash.py`
hardcoded `main`/`master`, so a push to `mainline` was not denied — the guard
was inert exactly where it mattered.

- **Branch guard reads `target.branch`.** The push deny and the
  commit-on-trunk deny in `core/guard-bash.py` read the configured trunk
  through `verifylib.target_branch` (the reader PROP-019 gave the promotion
  gate). Refspecs are parsed: `push origin mainline`, `push origin
  HEAD:mainline`, `push origin feature:mainline`, `push -u origin mainline`
  and `+src:refs/heads/mainline` are denied; a feature branch in any shape is
  allowed; `--force`/`-f` stay denied; a bare `git push`, `push origin HEAD`,
  `push -u origin HEAD` and `push origin @` are denied while on the trunk
  (they push the checked-out branch); `--all`/`--branches`/`--mirror` are
  denied from any branch inside the target. `main` and `master` stay denied
  alongside the configured trunk. Deny messages name the configured branch.
  A `switch -c` followed by a plain `switch` back to the trunk in the same
  command no longer earns the commit its branch credit. An unreadable
  `config.yaml` fails closed for push and commit inside `target/` (the guard
  used to skip every git rule when it could not find the target).
- **Doctor checks the trunk name.** `core/doctor.sh` checks that
  `target.branch` exists at origin (`refs/remotes/origin/<branch>`, no
  network) and on a miss prints one plain-language line: "config.yaml says
  target.branch: main but origin has no branch by that name (its default
  branch is mainline); fix target.branch in config.yaml". A branch that
  exists but is not the remote's default (`refs/remotes/origin/HEAD`) is a
  NOTE naming both, not a problem — a deliberately non-default trunk must
  not turn doctor red and block `setup.sh`. Missing origin refs or an unset
  origin/HEAD are reported as undeterminable, never guessed.
- **The refuter is a charter, and it is on by default.** The rung-2 reviewer
  is now a Claude Code subagent definition at `core/agents/refuter.md`
  (distribution code): `Read`/`Grep`/`Glob` only, no `Bash`/`Edit`/`Write`,
  `model: opus`, bounded turns, no memory. `core/refute.sh` renders it
  (`core/agentdef.py`) and runs `claude -p --agent refuter --agents
  <rendered> --add-dir <target>` from an empty temporary directory, passes
  `--model` from `verify.refute_model` when set, tells the reviewer the
  checkout's absolute path, and feeds the pitfalls that apply to the touched
  paths (`core/refute-pitfalls.py`) between the evidence and the diff; a
  selector that crashes or is missing is uncertifiable (FAIL), not "(none)".
  The empty working directory is what keeps the project `CLAUDE.md` files
  out of the review — measured on Claude Code 2.1.282, `omitClaudeMd` in an
  `--agents` definition does not do that on its own; the user-level
  `~/.claude/CLAUDE.md` still loads (see README).
  `core/gates.sh` treats an unset `verify.refute` as `true`; `verify.refute:
  false` is honored only with a non-empty `verify.refute_off_reason`,
  otherwise gates.sh dies before running any gate. A missing
  `verify.refute_timeout` defaults to 600 s.

Also: the refuter's local-branch diff fallback is three-dot, so uncommitted
hunks no longer appear twice in its input; `CHANGELOG.md` joins the
Edit-deny list.
