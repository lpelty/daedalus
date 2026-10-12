# Changelog

Releases are annotated git tags (`git tag -a vX.Y.Z -F <notes>`); the notes
for each release live here first, and the tag message repeats the headline.
Earlier releases (v0.1.0 – v0.6.0) are described by their tag messages only.

## v0.7.0 — numbered windows, promote, the direct-call launcher, incremental capture, and an upgrade that runs itself

**In short.** Several Daedalus sessions can now work on one target at the
same time. Each one is a numbered window. A change reaches the target's trunk
only after you say yes to it. Daedalus can ask the target's own agent a
question, and an agent you allow can ask Daedalus one. Each session's memory
is now saved every couple of minutes, not only when it ends.

Every deployment takes this release, and the next, the same way: `git pull
--ff-only` in the Daedalus home, then a new session.

To go back, `python3 core/upgrade.py --rollback` puts the home where v0.6.1
runs as before and keeps each window's work on its branch. A branch the
upgrade picked up gets its own name back, and each target checkout goes back
on the branch it was on. Then it prints the command that puts the code back.

**What you will see at the first session after the pull.**
- The session upgrades the home before anything else. It says one line for
  each thing it did.
- Before it changes anything in `target/`, it keeps a safety copy of all of
  it; `python3 core/upgrade.py --restore-help` lists anything missing, and
  `--forget-snapshot` removes the copy.
- If `target/` holds unfinished work, the upgrade stops and changes nothing
  there. That is a branch with commits its origin does not have yet, or the
  trunk ahead of origin. It is also unsaved files, a stash, a git operation
  left part-way, or a worktree made by hand.
- It says what it found in one sentence, and the board repeats it until the
  upgrade is done. For example: "Daedalus has unfinished work in target/app:
  the branch fix-login (2 commits not on GitHub), and 3 unsaved files. Nothing
  was changed. Say 'pick it up' to move it into windows, or finish and ship it
  the usual way, then start a new session".
- Until the upgrade finishes, no session gets a window, and `core/lease.sh`
  makes none: the board says "No window opens until the upgrade finishes."
  So nothing in `target/` changes, `.git` included, until you say so.
- Say "pick it up", and each piece becomes a numbered window. Then start a
  new session; it finishes the upgrade. Or ship the work the usual way first.
- With nothing unfinished, the upgrade finishes by itself. A checkout on a
  branch that is already merged goes back on the trunk.
  Files git ignores stay where they were, and a line names them.
- Then the session says "You are window 01", or the next free number, and
  that it holds the pen.
- Close and reopen any session that was open through the pull; it is still running the old hooks.
- That old session may say "config.yaml changed under this session, by the
  upgrade to 0.7.0 — not by this session. Do not restore it". It means what
  it says: do not restore the file. Start a new session instead.

**What the windows are.** Each terminal you open in the Daedalus home is a
window with a number, like "window 02". Each window works in its own copy of
the target, so two windows never write over each other. You talk to a window
by its number ("promote window 2", "release window 3"), or by a name you give
it. The first window to start holds the pen. Only the window with the pen
writes the shared notes and ships changes.

**How a change reaches trunk now.**
1. You tell the window with the pen: "promote window 02".
2. It prepares the change. It puts that window's work on top of the current
   trunk, runs the checks, and has a fresh reviewer read exactly that.
3. It shows you one short block in plain words.
4. You say yes, or you do not.
5. Only after your yes does it ship the change to trunk.

Nothing else can push to trunk. Where the target's users receive its trunk
through an update command, a promote is a release. The block then says so,
because the next update ships it to everyone. Where the target runs straight
from its trunk, a promote is live the next time it starts.

**One paste into config.yaml, by the operator.** Daedalus may not edit
`config.yaml`, so a few lines there are yours to add, once. `core/doctor.sh`
shows them as one paste. They say whether a promote here is a release
(`promote.release_note`), what the update command is, which agents may call
Daedalus (`direct_call.callers`), and, on a cloud provider, the reviewer's
model. Answer each `<...>`, paste the lines at the end of `config.yaml`, then
start a new session. Doctor never chooses who may call Daedalus; that is your
decision. Nothing else is done by hand.

**If the upgrade stops.** It stops only to keep work safe. The board then
says why on every prompt, in one sentence, with what to do. Do that, then
start a new session, and it finishes the upgrade.
- Unfinished work in `target/`: say "pick it up". Or ship it the usual way:
  commit them on their branch, push, and merge. Uncommitted changes count as
  unfinished work.
- A file marked skip-worktree or assume-unchanged holds a change `git status`
  hides: clear the mark with the command "pick it up" names.
- A target checkout has ignored files where putting it back on its trunk
  would write: move them out of that checkout, or commit them on its branch.
- A target checkout has a local branch named `origin/main` (its trunk's name):
  rename it.
- A rebase, merge or similar was left half done in a target checkout: the
  sentence names the `git` command that finishes or undoes it.
- A `git` command was cut off part-way in a target checkout. It left lock
  files, or the checkout on a branch that is gone. The sentence names the
  files to remove, or the command that brings the branch back.
- Two branches have names that differ only in capital letters, which this
  disk cannot keep apart. Rename one with the commands the sentence names.
- If a `git` command "pick it up" ran was cut off, the next session start
  finishes it. Do not commit anything there in between.

Never stash the changes to get past a stop. A stash is saved work that no
window shows. If the upgrade finds one, it stops on it, and `core/doctor.sh`
names it. One thing does not stop the upgrade: a target checkout with
another tool's `pre-push` hook, or a `core.hooksPath` setting. The upgrade
says so with the remedy, and promote waits until that is fixed. `python3
core/upgrade.py --dry-run` shows what the upgrade would do. `core/doctor.sh`
shows what is left.

**How to tell you have it.** `cat VERSION` prints `0.7.0`. `git describe
--tags --abbrev=0` prints `v0.7.0`. `core/doctor.sh` prints `OK       version:
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
  acts; the stamp written last; `--dry-run`; `--setup` for setup's leases phase.
  Its steps: the window directories; the pre-push hook in Daedalus's own
  checkout of each target repo; the old shared reminder files removed;
  `hot.md`'s `session:` line renamed `leases:` (left for the prime's first
  vault commit); capture's settings moved from the hook line in
  `.claude/settings.local.json` into a `memory:` block in `config.yaml`, the
  key into `state/hindsight/api-key` (only when every value on that line is
  written out plainly, or the key is read from a file; the old line keeps
  working); then, after the safety copy and before anything in `target/`
  changes, unfinished work in any target repo (outer and nested) stops the
  upgrade in one sentence naming it — a branch with commits `git cherry`
  finds missing from `origin/<trunk>` (or a merge commit whose result adds
  something, which `git cherry` passes over; a squash merge, found even after
  origin changed the same lines, and a branch a window holds do not count; one
  whose branch on origin was deleted counts when it holds such a commit), the trunk
  ahead of origin, a detached HEAD with commits no branch has, uncommitted
  changes (hidden ones too), untracked files that are not ignored, a stash
  entry, a rebase, merge, cherry-pick, revert or bisect in progress, a
  worktree that is not a window's. Nothing is moved by the upgrade itself:
  "pick it up" (`core/lease.sh adopt --all-unfinished`) makes each piece a
  window — unsaved files saved first as one commit, each stash entry as a
  commit of what it saved — and names what it cannot move with what to do;
  the next start finishes. Until the stamp is written (the upgrade stopped,
  runs in the background, or has not run) a session start numbers, binds and
  makes no window, so it adds no `lease/<NN>`, worktree record, branch section
  or pre-push hook to target/'s repositories after a stop that said "Nothing
  was changed"; it says "This session has no window yet: windows open once
  the upgrade finishes", the board says "No window opens until the upgrade
  finishes." under the stop, and `lease.sh` create, claim, spawn, adopt and
  split refuse with that pointer and the stop — all but `adopt
  --all-unfinished`. With nothing unfinished, one bounded fetch, and a
  checkout on a branch already on origin goes back on its trunk, the branch
  left as it was. Ignored files and work inside a submodule are named in a
  line and by doctor and stay where they are.
  Branches are read by their exact names (`refs/heads/<b>`): a tag with a
  branch's name, or a tag named after the trunk, no longer makes a branch
  unreadable. Where git ignores case, two branches whose names differ only in
  case stop the upgrade, and `lease.sh adopt`, naming both and the rename
  (`pack-refs --all`, then `branch -m`): git read one for the other, and the
  adoption deleted the commit of one; a name an adoption drops is deleted only
  by its exact ref, at the adopted commit. The move back to the trunk and the
  trunk's reset are never killed part-way (no 20 s cap; a stopped session
  start leaves them to finish), and one cut off anyway — the checkout still on
  what a window already holds, the tree half switched, git's lock files left —
  is finished by the next start (git's own locks cleared, then the reset or a
  forced checkout of the trunk), never "commit them", which put the same
  commit in a second window; a file whose content is neither side's is named
  instead, and doctor says the window already holds a trunk's commits. Only a
  reset Daedalus began is finished this way: it is marked in
  `state/upgrade-trunk-reset.json` while it runs, so an ordinary edit on a
  trunk a window holds is unsaved work that "pick it up" saves.
  A window is made without renaming anything: `lease/<NN>` is made at the
  work's tip, and the branch's own name is removed only once the lease file and
  the worktrees exist, so a `git` killed at any point leaves the commits on a
  branch. A start cut off while making a window — after `lease/<NN>` was made,
  before its lease file, or before its worktrees — is finished by the next start
  into that same window, never adopted twice. A lease file is written to a temporary file and linked into
  place, so a cut-off start never leaves an empty one (an empty one an earlier
  build left is cleared); a `git worktree add` cut off so early that git will
  not remove what it left (a record locked "initializing", a window branch's
  `.lock`) is cleared by the next allocation of that number. Allocation and
  release prune worktree records under `worktrees/` (and promote's scratch)
  only, never the operator's own worktrees: a plain `git worktree prune` dropped
  one on a volume not mounted at that moment, its index and its detached
  commits with it. Besides unfinished work, it stops before anything in
  `target/` moves, repeated by the board on every prompt, on an ignored file
  where the move back to the trunk or its fast-forward would write (paths compared without case where git ignores
  case), a local branch named `origin/<trunk>`, lock files a cut-off `git`
  left in its git directory, or a checkout on a branch that is gone (the
  sentence gives the branch's last commit from HEAD's reflog and the command
  that brings it back — never "commit them"). Doctor names such a hidden
  edit, a branch named `origin/<trunk>`, a branch whose branch on origin was
  deleted, and the uncommitted or untracked files of a swept window's
  worktree; the board and doctor name a swept window's waiting commits in a
  nested repo as they do the outer one's. Its write to `config.yaml` is recorded in
  `state/config-changes.json`, so a session open through the pull is told
  "Do not restore it" (once) instead of "restore it"; a tracked `config.yaml`
  changed by the pull's own commits reads the same way. A record counts only
  for a session the release came in under, and only the release's first one;
  any other change still says "restore it".
- Doctor shows the `config.yaml` lines only the operator may write
  (`promote.release_note`, `promote.update_command`, `direct_call.callers`,
  `verify.refute_model` on a cloud provider) as one paste, printed bare:
  exact where the answer is known, a `<...>` with its question otherwise,
  never a caller filled in.
- Where a promote is a release, let that deployment's `gates:` exercise what
  the update exercises, as far as a command that exits 0 can. Where the
  target's harness runs from its live tree, a promote is live at its next
  start; a pinned checkout for such a deployment is separate work.
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


#### Fixed on trunk after the v0.7.0 tag — 2026-10-11: the morning terminal is window 01 again

**What went wrong.** A session was judged dead while it ran. The registry
Claude Code keeps per session records when the entry was written, not when
the process started. On the first starts after an OS restart that was 2 to
3 seconds later, and Daedalus allowed 2. So the new session was not seen as
a terminal window: it took no number, and it did not take the pen from the
session that had ended. The refusal it printed blamed "several sessions".
The window it then claimed by hand recorded no pid, so its own board would
have called it stale after four idle hours.

**What changed.**

- Liveness compares process start to process start. The registry's
  `procStart` (copied into the lease as `proc_start` at bind) decides when
  present. Without it, the entry must have been written after the process
  started and within a minute of it. A recycled pid still fails both. The
  process start is read from `ps` in UTC, so the hour the clocks fall back
  no longer reads every session dead.
- A window with nothing to lose and nobody to lose it is reclaimed before a
  number is chosen: its recorded process gone, its worktree clean, nothing
  unpromoted. Yesterday's window 01 becomes today's, and the pen comes with
  it. A window holding work, a quiet one, a finished clone, a background
  clone that never reported, a released one, or one that never recorded a
  pid is left for `sweep`, as before. Every
  terminal start does this, a resume included, and so do `lease.sh create`,
  `spawn` and `adopt` before they choose a number.
- An unleased session is told "This session holds no window: no lease names
  it and it does not hold the pen", never "several sessions are live".

**How you get it.** `git pull --ff-only` in the Daedalus home. VERSION stays
0.7.0: nothing here needs a migration step, so no upgrade runs at the next
start; the code is live at the next hook run.


#### Added on trunk after the v0.7.0 tag — 2026-10-11: the lease board on screen

**What you see.** Every window now shows the lease board above its prompt. It
refreshes itself every 2 seconds. One line per window, yours first: the
number, "this window" on your own line, "holds the pen" on the pen holder's.
Then the state: live, quiet since 09:40, stale, finished, or released. Then
how many files the window has changed, its name if you gave it one, and its
note. Live is plain, quiet is yellow, stale is red, released is dim. Nothing
to run and nothing to ask: before, the board was only in the model's context.
When the board cannot be read, one dim line says why. The last good board
stays until the next read works.

**One-time install, per deployment.** The board is a Claude Code mod that
ships in the repo under `mods/`. In the Daedalus home, run
`claude plugin marketplace add ./mods --scope local`, then
`claude plugin install lease-board@daedalus-mods --scope local`. Then open a
new terminal, or run `/reload-plugins` in a window that is already open.
`core/setup.sh` runs the two commands when they have not been run. Inside
the repo the install writes only `.claude/settings.local.json`, which git
ignores. Claude Code also records the marketplace and the install in its own
per-user files under `~/.claude/plugins/`, so one machine holds one
`daedalus-mods` record: a second Daedalus checkout on the same machine would
load the first one's board, and `core/doctor.sh` says so. Mods need Claude
Code 2.1.287 or later. This was built and tested against 2.1.296.

**What changed underneath.**
- `python3 core/leaselib.py board-json` prints the board as one line of JSON.
  It reads the lease files and their sidecars under the shared lock, then the
  session registry once. It runs no git and writes nothing, so forty windows
  read in under a second. It waits at most 1.5 seconds for the lock.
- `core/doctor.sh` gains two lines. `registry shape` says whether the session
  registry Claude Code keeps still has the fields liveness reads, and names a
  live window whose entry fails the liveness test. `lease board on screen`
  says whether this deployment has installed the board, at local or user
  scope, and whether its Claude Code is new enough. It also notes a
  `daedalus-mods` record that points at another checkout on this machine.
- `mods/` is distribution code. The launcher and promote refuse while it is
  modified, as they do for `core/`.

**How you get it.** `git pull --ff-only` in the Daedalus home, then the two
install commands above, once. VERSION stays 0.7.0: nothing moves and no
state changes shape, so no upgrade runs at the next start.


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
