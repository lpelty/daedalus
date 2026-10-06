# Changelog

Releases are annotated git tags (`git tag -a vX.Y.Z -F <notes>`); the notes
for each release live here first, and the tag message repeats the headline.
Earlier releases (v0.1.0 – v0.6.0) are described by their tag messages only.

## v0.7.0 — numbered windows, promote, the direct-call launcher, incremental capture, and an upgrade that runs itself

**What changes for an operator.** Several Daedalus sessions can now work one
target at once. Each terminal you open in the Daedalus home numbers itself —
"You are window 02" — and builds in its own copy of the target; you talk to
windows by number ("promote window 2", "release window 3"), or by a name you
give one. The first window up holds the pen: only it writes `hot.md`, commits
the vault and promotes. Nothing reaches the target's trunk except
`core/promote.sh`, which merges a window's work onto current trunk, runs the
gates and a fresh reviewer on exactly that merge, shows you one plain-language
block, and pushes only after your yes. Capture records each session every
couple of minutes instead of only at its end. Daedalus can ask the target's
own agent a read-only question, and an agent you allow can ask Daedalus one.

**On each kind of deployment.**
- *Where a promote is a release* — the target's users receive its trunk
  through an update command — set `promote.release_note: true` and
  `promote.update_command` in `config.yaml`: the block and the pushed line then
  say "this is a release", because the next update ships it to everyone. Let
  that deployment's `gates:` exercise what the update exercises.
- *Where the target's harness runs from its live tree* — no update step between
  the push and the harness that loads it — a promote is live at the harness's
  next start. This release does not change that; a pinned checkout for such a
  deployment is separate work.
- *Every deployment* takes this release, and the next, the same way:
  `git pull --ff-only` in the Daedalus home, then a new session.

**At the first session after the pull.** Nobody runs a step by hand. The
session's start runs the upgrade (`core/upgrade.py`) before the window numbers
itself, and says one line for each thing it did: made the window directories;
installed the pre-push hook in Daedalus's own checkout of each target repo;
removed the old shared reminder files; renamed `hot.md`'s `session:` line to
`leases:` (left for the prime's first vault commit); moved capture's settings
from the hook line in `.claude/settings.local.json` into a `memory:` block in
`config.yaml`, with the key in `state/hindsight/api-key` (only when every value
on that line is written out plainly, or the key is read from a file; the old
line keeps working and can be removed later); and turned any work waiting in
`target/` — a branch, a trunk ahead of origin, a detached checkout — into a
numbered window you can promote or release, putting the checkout back on its
trunk. Then the window numbers itself — window 01 if nothing was waiting, the
next number otherwise — and takes the pen. If a target checkout has
uncommitted changes, or an untracked file where putting it back on its trunk
would write, the upgrade stops before moving anything there and the board says
so in one sentence on every prompt: commit or stash them (or move the file),
and the next session finishes it. If a target checkout already has another
tool's `pre-push` hook, or sets `core.hooksPath`, the upgrade finishes but says
so with the remedy, and promote refuses until the hooks are merged or
`core.hooksPath` is unset and `core/setup.sh` has run. Close and reopen any
session that was open through the pull; it is still running the old hooks.
If the upgrade moved capture's settings, that session's next Stop says "The
gate definition (config.yaml) changed this session; restore it." That change
was the upgrade's, so do not restore the file: restart the session instead.
`python3 core/upgrade.py --dry-run` shows what it would do; `core/doctor.sh`
shows what is left. Session logs are named by window and date from now on; earlier logs
keep their names.

**How to tell you have it.** `cat VERSION` prints `0.7.0`; `git describe
--tags --abbrev=0` prints `v0.7.0`; `core/doctor.sh` prints `OK       version:
0.7.0` and `OK       upgrade: state/upgraded-to 0.7.0`.

### In detail

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
- **The direct-call launcher** (`core/call-agent.sh`, `core/call_agent.py`;
  plan 3 of 5): `--callee agent` asks the target's own agent, named only in
  `config.yaml` (`direct_call.callee_home` / `callee_name`, refused while
  unset — the same code calls a different agent on each deployment);
  `--callee self --caller <name>` lets an allowlisted agent ask this Daedalus
  (`direct_call.callers`), as a visitor — whose Stop no verify check blocks;
  `--callee refuter` runs the reviewer. The callee's own callers list is
  honoured and an unreadable one refuses; a resume re-reads both. Answer on
  stdout, a two-line receipt on stderr, receipts under `state/direct-calls/`,
  `--resume <call-id>`, exit 0/2/3/124.
- **The refuter is a Thing the launcher runs**: `core/refute.sh` only
  assembles the review. The launcher refuses while distribution code is
  modified, excludes every `CLAUDE.md` and auto memory, writes the review once
  per run with the call id, fingerprint, mode, prompt sha and committed
  `core/` tree in its frontmatter, and `--resume-review <NN>` lets the operator
  ask the reviewer about a finding (advice, never a verdict). A canary with a
  positive control proves the reviewer shares no context with the author
  (stubbed in the suite; live per deployment with `DAEDALUS_LIVE_CANARY=1`).
  `refute.sh --mode promote` and `--render-only` are ready for `promote`.
- Doctor reports the `direct_call:` block, whether distribution code is
  modified, and calls a launcher left marked active.
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
- **Promote** (`core/promote.sh`; plan 4 of 5): the one way a window's work
  reaches trunk. Prepare trial-merges the window's branch onto freshly fetched
  trunk in a scratch worktree, runs the gates and the fresh-context reviewer
  on exactly that merge, and prints a plain-language decision block; confirm
  re-derives the evidence, records the operator's yes and pushes that exact
  merge. The yes is checked against the prime's own session transcript by
  default (`promote.confirm: transcribed` — words the operator typed after the
  block was shown, in a later turn, and a prompt Claude Code reported to the
  UserPromptSubmit hook as it was submitted, with the transcript before it
  unchanged since; an unreadable transcript is refused, never passed) or typed
  at a terminal (`tty`). `--skip-review --reason` records the
  operator's written reason beside the verdict it sets aside; gates are never
  skipped. `vault/evidence/promotions.log` keeps one line per promotion.
- **The pre-push hook** (`core/prepush.py`): git itself refuses a trunk push no
  promotion confirmed; installed idempotently in every target repo.
- **The guard** covers every trunk-reaching git shape in every repo under the
  home — through `bash -c`, `$( )`, backticks, `env` prefixes and aliases —
  plus `--no-verify`, `core.hooksPath` (set by `-c`, `git config`, or already
  in the configuration a push runs with), HOME or XDG_CONFIG_HOME set in a
  command that runs git, writes under `.git/hooks/`, and
  distribution code by every git route; its messages say trunk is reached only
  through promote. A modified `core/` blocks at Stop. The session transcript
  cannot be written from either tool.
- `core/lease.sh rebase <NN>` and `split <NN> --repo <nested>`; `prime take
  --reason` from a live holder is checked like a yes.
- The integrity check runs before any other distribution code in the launcher
  and in promote (`core/distcheck.py`); `capture-tick.sh --dry-run`.
- Doctor reports the confirm mode, each repo's trunk and pre-push hook, and a
  promotion prepared but never confirmed.
- **The upgrade** (`core/upgrade.py`): run at SessionStart when `VERSION` and
  `state/upgraded-to` differ (never in a direct-call session), inside the start's
  time budget, one run at a time; every step idempotent and said once when it
  acts; the stamp written last; a dirty target checkout the one stop, repeated
  by the board on every prompt; `--dry-run`; `--setup` for setup's leases phase.
- `core/lease.sh adopt <branch> [--repo <nested>] [--note "…"]`: an in-flight
  branch in `target/` becomes a numbered window and the checkout goes back to
  its trunk; `adopt <trunk>` moves a trunk that is ahead of origin into one; a
  branch with nothing past trunk is refused.
- `VERSION` and `lib.sh daedalus_version`; doctor reports the version, the
  upgrade stamp, `state/promote/` and `state/direct-calls/`, a target checkout
  off its trunk or ahead of origin, `hot.md`'s old field, and — from a session —
  that session's registry entry. `setup.sh` has a leases phase;
  `sync-target.sh` refuses a target checkout that is not on its trunk.
- `recall-inject.py` reads the `memory:` block (a hook-line prefix still wins).
- The guard allows exactly `git pull --ff-only` in Daedalus's own checkout —
  the release pull, while it reads from the address the checkout itself
  records; every other git command there but reading ones is refused.
- `CLAUDE.md`: what the operator says to a window and what it runs, what is
  repeated word for word, and how windows message each other.
- `core/tests/scenarios/two-clones.sh`: the two-window scenario on a scratch
  deployment — interactive for an operator, `--rehearse` in the suite.
- `docs/handoff-reverse-caller.md`: for a Daedalus that the target's agent
  calls — what it exposes, what this release changed, and how to check each.

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
