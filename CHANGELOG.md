# Changelog

Releases are annotated git tags (`git tag -a vX.Y.Z -F <notes>`); the notes
for each release live here first, and the tag message repeats the headline.
Earlier releases (v0.1.0 – v0.6.0) are described by their tag messages only.

## Unreleased — numbered windows, lease worktrees, the board, the pen; incremental capture (v0.7.0 plans 1–2 of 5)

- **Every interactive window numbers itself** at SessionStart and builds in
  its own git worktree of the target (`worktrees/<NN>/<repo>`, branch
  `lease/<NN>`); `target/<repo>` is the prime's mirror of trunk and no
  session writes there. `core/lease.sh` (`create claim alias note update spawn
  list status release done sweep prime take`) and `core/leaselib.py` are the
  only writers of `state/leases/`.
- **The lease board** is injected at start (by `session-start.py`, right
  after it numbers and binds the window) and on every prompt
  (`core/lease-board.py`); it is also the heartbeat and recomputes the
  reader's observed changed set.
- **Stop-once cross-lease warning** on PreToolUse(Edit|Write) and Bash write
  operands; a Stop-time backstop catches a warning that never fired.
- **The pen**: `state/leases/prime.json`; first interactive window up takes
  it; `hot.md` and the vault are prime-only, and the vault is committed only
  by `core/vault-commit.sh`.
- `verifylib.target_root` (which returned `None` and let every guard fail
  open) is replaced by the tri-state `resolve_target`; every consumer names
  what it does under `Refused`. `fingerprint.sh` and `sync-target.sh` treat a
  linked worktree as a repository.
- Evidence: `run.json` is written first (`RUNNING`, with the window) and the
  manifest is appended under a lock (`core/manifest-append.py`).
- Session logs are named by window number and date; claim documents carry
  `lease:`; per-session dedup files; the document index is prime-only.
- Doctor reports the lease directories, stale/released/finished windows,
  swept numbers with waiting work, and the session registry.
- **Incremental capture.** With a `memory:` block in `config.yaml` — now the
  one place capture's configuration lives (`lib.sh memory_env`; an environment
  variable still overrides a field; the API key comes from a 0600 file) —
  `core/capture-tick.sh` captures each window's session at Stop, at most every
  `capture_interval` seconds, and flushes it at SessionEnd. Both are wired in
  the tracked `settings.json` and run capture in the background.
- **The transcript is named, never guessed**: `capture.py capture
  --transcript` / `--session-id`, the hook payload, this session's start
  marker, then `<transcript_dir>/<session id>.jsonl`. The "newest transcript"
  fallback is gone (it could flush another session); with nothing to go on,
  capture refuses.
- **One capture per session at a time**: `offsets.json` is read and written
  under a lock that is never held across a network call; a run marks the
  transcript in flight (process id, start time) and the retry-ledger entries it
  is settling. A second run skips; `close.sh` waits up to 90 s and otherwise
  exits non-zero; a run that outlived its mark never writes over the run that
  replaced it.
- **`close.sh` confirms the whole session** — the spans the Stop captures sent
  earlier as well as its own — and takes `--transcript <path>` from a shell.
- **Whole lines only**: a turn still being written waits for the next capture;
  an unreadable transcript format is logged once and never skipped silently.
- `CAPTURE_DEFER_TO_CALLER=1`, or `DIRECT_CALL_ID` (a direct-call visitor),
  makes capture stand down (the direct-call launcher re-captures, plan 3).
- PROP-006: a failed extraction reports the server's `error_message` instead
  of `error=None`.
- `core/lease.sh` refuses every command that changes a window from a
  direct-call session; SessionStart's worktree adds share the hook's 30 s
  budget (a slow nested repo leaves the window for `claim` to finish); an add
  interrupted mid-checkout is removed and redone instead of adopted.
- Doctor reports the `memory:` block (OK, absent, or unusable) and a leftover
  capture line in `.claude/settings.local.json`.
- Not yet in this release: the caller and refuter launcher (plan 3);
  `promote`, the pre-push hook and `prime take`'s transcript check (plan 4);
  `lease.sh rebase/split/adopt` (plans 4 and 5); the self-upgrade that moves an
  old capture line into `memory:`, `recall-inject.py` on `memory_env`, and
  `VERSION` (plan 5).

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

From the adversarial review of this release, before tagging:

- **The refuter's diff covers nested checkouts and untracked files.** On a
  deployment whose write surface is a `target.nested` repository the outer
  `git diff` showed nothing (gitignored) or a `Subproject commit …-dirty`
  stamp (tracked), so every PASS was reviewed against an empty diff — and
  default-on made that mandatory. `core/refute.sh` now assembles the diff
  per repository (target, then each nested path, against its own base),
  prefixes nested paths so `applies-to: path:` globs match, includes
  untracked files through a temporary index, and refuses an empty diff as
  uncertifiable (exit 2) instead of handing it to the model.
- **A killed review strands nothing.** The watchdog handles SIGTERM/SIGHUP
  so its process-group kill runs when a tool timeout kills `gates.sh`
  (claude used to outlive it); `gates.sh` manifests the run's logs before
  the review and writes the vault summary and `run.json` only after the
  verdict, so no PASS-labelled, unmanifested evidence is left under a
  protected path. README and CLAUDE.md say what timeout to run it with.
- **Guard: the matching refspec and `switch -`.** `git push origin :` (and
  `+:`) pushes every matching branch, the trunk included, and was allowed
  from a feature branch; denied. `switch -c fix/x && switch -` (or
  `checkout -`, `--detach`) kept the branch credit for a commit that lands
  on the trunk; cancelled.
- **Guard: the remote's default branch is a trunk name.** The originating
  shape — config `main`, origin default `mainline`, `main` present at
  origin too — is a doctor NOTE (indistinguishable from a deliberate
  non-default trunk) and `push origin HEAD:mainline` was allowed. The guard
  now reads `refs/remotes/origin/HEAD` and denies pushes and commits to the
  default branch as well; the NOTE says so.
- **Boundary hook: the verdict file is the run's own evidence.** In a vault
  the parent git can see, `<run-id>-review.md` was flagged as protected
  dirt at Stop (its run-id was read off the file name), which with the
  refuter on by default blocked every session after a STANDS.
