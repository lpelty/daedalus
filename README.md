# Daedalus

A standalone agentic harness for building and maintaining Claude Code–based
harnesses. Agnostic until a codebase and a vault are supplied.

## Deploying

1. Clone this repo.
2. `cp config.example.yaml config.yaml` and fill in your target repo, its
   nested and scaffold repos, your knowledge-base repo, and your gate commands.
3. `./core/setup.sh`

Setup clones the target and its nested repos at the paths they occupy in your
real tree, makes the window directories and installs the pre-push hook,
recreates the directory shape of any scaffold repo, and finishes by running
the doctor. Rerun it any time — every phase is idempotent, and rerunning is
how a scaffold picks up new directories.

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
      "Edit(//path/to/your/harness/**)"
    ]
  }
}
```

### The local layer

A deployment never edits a tracked file. A release rewrites those files, and
a local edit inside one turns every update into a merge. Local choices go in
three files no release touches:

- `.claude/settings.local.json` (gitignored) — local permission rules and
  hooks. Claude Code merges its lists with the tracked `.claude/settings.json`.
  Its `Edit(...)` deny rules also protect Bash writes and the Stop check, as
  the tracked ones do.
- `CLAUDE.local.md` (gitignored) — local brief text. Claude Code loads it
  after `CLAUDE.md`.
- `config.yaml` — `boundary.edit_brief` decides whether Daedalus may write
  `CLAUDE.local.md` (see below).

`daedalus update` moves what a deployment already put in the tracked files
into these, once, and keeps a backup (see "Upgrading").

### Letting Daedalus edit its own brief

`CLAUDE.md` is distribution code, and Daedalus never edits it: the
distribution denies it (`Edit(/CLAUDE.md)` in `.claude/settings.json`), the
boundary hook and the guard refuse it, and `core/promote.sh`, the direct-call
launcher and the update all refuse a tree whose CLAUDE.md differs from HEAD.
The deployment's own brief is `CLAUDE.local.md`. By default the operator
writes it and Daedalus may not. To let Daedalus maintain it, set this in
`config.yaml`:

```yaml
boundary:
  edit_brief: true
```

Daedalus then writes `CLAUDE.local.md` when you ask, and still never
`CLAUDE.md`. `core/doctor.sh` names the key's value. In auto mode, Claude
Code's classifier may still refuse the edit under its "Self-Modification"
rule. That rule is a soft deny: a message from you in the session asking for
the edit clears it on its own. For an edit you want allowed without asking
each time, add a prose exception to **`~/.claude/settings.json`** (user scope;
the classifier never reads `autoMode` from a project's
`.claude/settings*.json`), keeping `"$defaults"`:

```json
{
  "autoMode": {
    "allow": [
      "$defaults",
      "Editing CLAUDE.local.md in the Daedalus home at /path/to/daedalus when the operator asked for that change in this session: the deployment chose to let Daedalus maintain its own brief."
    ]
  }
}
```

A v0.7.2 exception that names CLAUDE.md no longer fits; `daedalus update` and
`core/doctor.sh` say so, and you reword it to `CLAUDE.local.md`. Neither ever
writes `~/.claude/settings.json`. SOUL.md is different: it is this instance's
own journal, is not denied by the distribution since 2026-10-15, and no
release changes it (a test pins the tracked file to its seed); `daedalus
update` keeps the deployment's copy.

## Starting Daedalus (`daedalus start`)

Type one command in a terminal:

```
daedalus start
```

It goes to the home, prints the banner and one line under it,
`Daedalus 0.12.0 · lares · ~/daedalus-lares`, then one line per service this
deployment set up, from `core/status.py`:

```
✓ memory server
✗ memory capture — last capture 40 min ago
```

A service that was never set up is left out. When the check fails or takes
more than 2 seconds the line is `services: couldn't check`. It starts, stops
and fixes nothing, and a service that is down never stops the start. The
screen holds for `start.pause` seconds (`config.yaml`, default 1.5; 0 skips
it), then Claude Code takes the terminal.

- `daedalus start --window 03` starts the session in window 03
  (`DAEDALUS_LEASE=03`): the way back into a window you parked.
- Anything after `--` goes to Claude Code: `daedalus start -- --resume`.
- The banner is `banner.txt` in the home when there is one (git-ignored, like
  `config.yaml`), else the release's `core/banner.txt`.

### Which home a command means

Every verb — `start`, `update`, `version` — picks its home the same way:

1. a name on the command: `daedalus start lares`, `daedalus update work`;
2. else the home the current directory is in, from anywhere under it (a
   window's worktree too);
3. else the default home. With exactly one home, that is the default.

An unknown name is refused with the valid names, exit 2. So is a bare command
outside every home when there are several homes and no default. A command
never falls back to some other home.

The homes are listed in `~/.config/daedalus/homes.json`
(`$XDG_CONFIG_HOME/daedalus/` when that is set). `core/setup.sh` and the
upgrade register their home. Its name is the folder's name without a leading
`daedalus-` (`daedalus-lares` is `lares`), and a folder named `daedalus` is
`main`.

```
daedalus homes                        # each home, its path, the default, any gone
daedalus homes rename main work
daedalus homes default work
```

A home whose folder is gone is listed as gone and never used. One
`~/.local/bin/daedalus` serves every home. Setup and the upgrade rewrite a
shim from an earlier release, which served one home, and register that home
too. They never touch a file there they did not write. Doctor says
`OK       daedalus command: 2 homes, default work`.

## Upgrading

Close every Daedalus window, then type one command in a terminal:

```
daedalus update
```

The first line is the result: `Daedalus updated 0.7.3 -> 0.7.4; doctor OK.`,
`Daedalus is up to date (0.7.4).`, or `Not updated:` and the reason. What
else it has to say follows on later lines, one sentence each: what it moved
and where the backup is, what the upgrade or doctor needs. If `daedalus` is not found, type `~/.local/bin/daedalus
update`; `core/setup.sh` and the upgrade install the command there and print
the one line that adds it to your shell's PATH. It never overwrites a file
there it did not write. `daedalus version` prints the release, the home, the
remote and the tag.

What it does, in order. It refuses while any Daedalus session is live in the
home, naming each, and while another update runs. It picks the remote whose
address is the release's, github.com/lpelty/daedalus, whatever it is called;
a home that follows a mirror sets `update.address` in `config.yaml`. It
refuses when git's settings would fetch from anywhere but that address. It
fetches, runs the release's own copy of the update, and refuses in one line
on local changes it cannot carry: an edit to `core/`, `mods/` or the README,
or an untracked file where the release adds one. The line names at most three
paths; past three, the full list is in `state/update-refused.txt`. A refusal
never tells you to undo, reset or delete anything. When `CLAUDE.md` or
`.claude/settings.json` carries a local edit, or the home's history has
diverged from the release (a merge with local commits), it moves those edits
into the local layer (see "The local layer"):

- a permission rule or hook no release ever had goes to
  `.claude/settings.local.json`;
- a removed `Edit(/CLAUDE.md)` deny becomes `boundary.edit_brief: true` in
  `config.yaml` (windows then re-run `core/gates.sh` before their next claim,
  since the gates' record pins `config.yaml`);
- brief lines no release ever had go to `CLAUDE.local.md`, under a header
  naming the date and the backup;
- a release rule or line the deployment removed or reworded is reported in one
  sentence, never moved and never dropped silently;
- `state/settings-before-merge.json`, a backup an earlier hand merge left, is
  read for additions too.

First it keeps a backup: the branch `local/before-update-<stamp>` and copies
under `state/update-backups/<stamp>/`. Then it resets the tracked files to the
release. SOUL.md, the journal, keeps the deployment's copy. Backup branches
stay local and pile up; the update never pushes or prunes them, but a remote
set up with `mirror = true` would push them.

**A home that keeps its vault in its own repository.** Some homes commit
`vault/` in the home repository (doctor accepts that layout) and push it to a
remote of their own. There the update never resets: after the local-layer
move, one local commit sets the release's files, then it merges the release
into its branch and keeps the home's history, every vault file, and the
branch's tracking — the branch keeps following its own remote, so the next
push is an ordinary one. `.gitignore` becomes the release's copy followed by
a marked block of this home's own lines (with `!/vault/` when the release
would ignore it), so later releases never conflict there. SOUL.md stays the
home's. A failure puts back only what the update wrote; a vault edit made
meanwhile is kept. In a home that tracks its vault in its own repository,
`daedalus update` is the way a release arrives; `git pull` pulls that home's
own remote. If the backup
itself fails, it stops before changing anything. A failure after the backup
puts the home back from it. Then it runs the upgrade at once, then
doctor, and prints the result first, naming the backup on a later line when
it made one. Network failure, or anything unsafe, ends with one line that
says nothing in the home was changed.

**The first update.** A home older than v0.7.3 has no `daedalus` command yet.
Close every Daedalus window and type this one line in a terminal, with your
home's path in place of `~/daedalus`:

```
(f="$(mktemp)" && { git -C ~/daedalus fetch -q https://github.com/lpelty/daedalus.git main && git -C ~/daedalus show FETCH_HEAD:core/update.py >"$f"; } 2>/dev/null || { echo "Not updated: could not fetch the update from github.com/lpelty/daedalus. Nothing in this home was changed." >&2; rm -f "$f"; exit 1; }; python3 "$f" update --home ~/daedalus; s=$?; rm -f "$f"; exit $s)
```

It names no remote: it fetches the release's own address, saves that
release's update to a temporary file and runs it; the update then picks the
home's remote by address. If the fetch fails, it says so in one line and
changes nothing. Or say to an
agent on that machine: "Close every Daedalus window, then run the first-update
line from the Daedalus README's Upgrading section on GitHub,
github.com/lpelty/daedalus." From then on, `daedalus update` is the whole
procedure.

**The upgrade.** `git pull --ff-only` in the home still works where nothing
local is in the way (a session may run exactly that; the guard allows no
other git route into Daedalus's own code, and refuses even that when git's
settings would fetch from anywhere but the address this checkout records for
its branch). It moves no local edit, and the upgrade then waits for the next
session start. Whenever `VERSION` and `state/upgraded-to` differ,
`core/session-start.py` runs `core/upgrade.py` before the window numbers
itself; `daedalus update` runs it at once. Each step acts once and says one
line when it does:

1. makes `state/leases/`, `worktrees/`, `state/promote/` and `state/direct-calls/`;
2. installs the pre-push hook in Daedalus's own checkout of each target repo;
3. removes the pre-v0.7.0 shared `state/pitfall-seen.json` and `state/code-context-seen.json`;
4. renames `vault/hot.md`'s `session:` line to `leases:`, left for the prime's next vault commit;
5. moves capture's settings from the hook line in `.claude/settings.local.json`
   into a `memory:` block in `config.yaml`, and the key into
   `state/hindsight/api-key` (mode 600) — only when every value on the line is
   written out plainly (a key read by `$(cat <file>)` counts); the old line
   keeps working and can then be removed;
6. checks every target repo (outer and nested) for unfinished work, after the
   safety copy and before it changes anything in `target/`. Unfinished work
   is: a local branch with commits `origin` lacks; the trunk ahead of
   `origin`; a detached checkout with commits no branch has; uncommitted
   changes, hidden ones too; untracked files that are not ignored; stash
   entries; a rebase, merge, cherry-pick, revert or bisect in progress; a
   worktree that is not a window's. Work already on `origin` does not count,
   squash-merged or merged, nor does a branch a window holds. A branch whose
   branch on `origin` was deleted counts when it holds a commit `origin` has
   no copy of, such as a fix made after its pull request merged. If it finds
   any, it stops and changes nothing there. It
   says one sentence, for example: "Daedalus has unfinished work in
   target/app: the branch fix-login (2 commits not on GitHub), and 3 unsaved
   files. Nothing was changed. Say 'pick it up' to move it into windows,
   then start a new session." The board
   repeats it on every prompt, and `core/doctor.sh` shows it. Until the
   upgrade finishes no session gets a window and `core/lease.sh` makes none
   (the board says so), so nothing in `target/` changes, its `.git` included;
   "pick it up" is the one exception. "Pick it up" is
   `core/lease.sh adopt --all-unfinished`. Each piece becomes a numbered
   window. Unsaved files are saved first, as one commit. Each stash entry
   becomes a commit of what it saved, and leaves the stash. What it cannot
   move, it names with what to do: an operation in progress, a change `git
   status` does not show, a repository inside the checkout, a worktree made by
   hand. The next session start then finishes the upgrade. With nothing
   unfinished, the upgrade goes on by itself: it fetches each target repo
   once and puts `target/<repo>` back on its trunk, leaving a branch whose
   work is already on `origin` as it is. Ignored files and work in a submodule
   are named in a line and stay where they are. No checkout, reset or merge
   the upgrade or `lease.sh` runs touches a submodule's files, even where
   `submodule.recurse` is set. A checkout or reset "pick it up" began and was
   cut off is finished by the next start, or by picking it up again;
7. registers the home and installs the daedalus command at
   `~/.local/bin/daedalus`, one for every home, never over a file it did not
   write, and says how to reach it from your shell;
8. says, once, that a callee named the 0.9.0 way (`direct_call.callee_name`)
   now has a key, its name in lower case, and that nothing needs changing; it
   never writes `config.yaml`;
9. installs the service-status mod at local scope for a deployment that has
   the lease board there, unless either settings file switches it off;
10. updates each Daedalus mod already installed for this home whose installed
   version is older than the one in `mods/` (`claude plugin update
   <name>@daedalus-mods --scope local`): a window loads the copy in Claude
   Code's plugin cache, not `mods/`. An open window needs `/reload-plugins`.
   A failed install or update is one line naming the command; neither stops
   the upgrade;
11. writes `state/upgraded-to`, last — never while a window picked up from `target/` has no
   worktree (the board and doctor name such a window).

Before it changes anything in `target/`, the upgrade keeps a checked safety
copy of everything there in `state/upgrade-snapshot/<stamp>` (every branch,
stash and recent commit as a git bundle — every commit a branch's reflog
holds, whatever its age, since adopting the branch deletes that reflog —
staged changes included; every
untracked, ignored or uncommitted file in a tar, an edit a clean filter or a
line-ending conversion hides from `git status` included (a filter git marks
required, as nbstripout's install does, is run like any other; one git runs
as a long-running process, as Git LFS does, never is, so such files are
compared only the way `git status` compares them, which for Git LFS sees every
edit), and one git's stat
check misses (`core.trustctime` false), an edit a `core.fsmonitor` hook does
not report (every `git` the upgrade runs in `target/` has it off), every file
of a `.git` git cannot read, and every file in a directory git records as a
submodule that holds no `.git`; git's record of a merge, rebase or bisect in progress, of each worktree
whether or not its directory is there now), stops instead if it cannot
make one (no room, or over `upgrade.snapshot_max_mb`, 2048 by default; the
stop names the three largest parts), and
keeps it until `python3 core/upgrade.py --forget-snapshot`, which refuses while
anything in it is missing — `python3 core/upgrade.py --restore-help` lists what
is, with the commands that bring each back (into a new repository under
`state/upgrade-restore/` when the repository itself is gone). The copy covers
every repository the upgrade can reach: those under `target/` (through a
symlink too), every worktree of each wherever it is, and any repository cloned
or checked out as a submodule inside one. A later run copies only what no
kept copy holds yet. A copy that would not fit in a session start is taken in
the background, and changes nothing; no window is numbered, and `lease.sh`
makes or changes none, until it is done; the next session start makes the
upgrade's changes. If reading `target/` to check it against that copy still
does not fit in a session start, the board says so and asks for
`python3 core/upgrade.py` once from a terminal in the home, which has no time
limit. git's record of a worktree made by hand under `worktrees/`
is never removed, even when its directory is gone (moved with `mv`, it still
works through that record; `git worktree repair <new path>` points git at it).

The copy leaves out what a lockfile rebuilds: a `.venv` directory beside a
`uv.lock` or `pyproject.toml`, and a `node_modules` directory beside a
`pnpm-lock.yaml`, `package-lock.json` or `yarn.lock`, in every repository and
worktree. A tracked file changed under one is still copied. The manifest and
`--restore-help` name each one left out, with the command that rebuilds it
(`uv sync --frozen`, `pnpm install --frozen-lockfile`, `npm ci`, …). Before it
estimates the copy, the upgrade removes the scratch worktrees of every
promotion already pushed, keeping the records: their content is on trunk. A
promote that pushes removes its own scratch too. Leftover scratch is removed
with `core/promote.sh NN --clean`, which runs from the prime (any promotion),
or from a session holding no window or a shell (pushed promotions only), so
it works while the upgrade is stopped. When the upgrade stops, every session
line, the board and the Stop hook say the stop's own sentence; in a terminal
running `daedalus update` it ends "then run daedalus update again".

Its `git fetch` of `origin` changes only origin's remote-tracking branches: it
fetches, moves and deletes no tag, whatever `fetch.pruneTags` says.

Unfinished work is the usual stop (step 6). A change `git status` does not
show counts as unsaved: a file marked skip-worktree or assume-unchanged (clear
the mark with the command "pick it up" names), an edit git's stat check passes
where `core.trustctime` is false (`touch` the file), or bytes a filter or a
line-ending conversion hides. A directory holding only a `.git` git cannot read
counts as unfinished work too. It also stops, before anything in that checkout
moves, on untracked files (ignored ones) that putting it back on its trunk
would overwrite (move them out of that checkout, or commit them on its
branch), or one where a directory git
records as a submodule (with or without `.gitmodules`) holds a repository of
its own or files with no `.git`, and its trunk has a file or a directory there,
which the checkout would delete or write into (move that directory out), or one with a
local branch named `origin/<trunk>`, which git takes for origin's trunk
(rename it), or one where a rebase,
merge, cherry-pick, revert or bisect stopped part-way (finish it or undo it
there, with the `git` command the sentence names), or one where a `git`
command was cut off and left lock files, or the checkout on a branch that is
gone (the sentence names the files to remove, or the `git branch` command that
brings the branch back from HEAD's reflog), or one with two branches whose names
differ only in case where git ignores case (rename one: `git pack-refs --all`,
then `git branch -m`). A file whose bytes differ from a checkout only in a
`$Id$`-style keyword git expanded at an earlier checkout is no change. A checkout or reset "pick it up" began and was cut
off part-way is not a stop: the next session start finishes it — never commit
in that checkout in between. The board says which on
every prompt, in one sentence, with what to do; the next session start
finishes the job. One other state needs a person but does not stop it: a
target checkout that already has a `pre-push` hook Daedalus did not install,
or sets `core.hooksPath` (as husky or lefthook do). (A Daedalus hook you added lines to is replaced, and kept
beside it as `pre-push.before-daedalus-<stamp>`, named.) The upgrade says so with the remedy — merge the two hooks or
move the other aside, or `git -C target/<repo> config --unset core.hooksPath`
— then `core/setup.sh`; until then promote refuses and the doctor says
MISSING.
`python3 core/upgrade.py --dry-run` says what it would do and changes nothing.
`cat VERSION` prints the release, and `git describe --tags --abbrev=0 --match 'v[0-9]*'` its tag.
`core/doctor.sh` reports the version, the stamp, and anything in `target/`
still off its trunk. A stash in a target checkout is saved work no window
shows, so it is never the remedy: the upgrade stops on it, and `core/doctor.sh`
names it until it is picked up, applied or dropped. A picked-up window is promoted from the board ("promote
window 01") or released, like any other; `core/lease.sh adopt <branch>
[--repo <nested>]` does the same for any branch later.

**Going back to v0.6.1.** Close every session in the home, then run
`python3 core/upgrade.py --rollback` from a terminal there; `--dry-run` first
prints the plan and changes nothing. It refuses while a Daedalus session is
live, naming it (`--force` goes ahead anyway). It checks every window
first: one it cannot save or remove safely (on another branch, in the middle
of a rebase, locked, a submodule checked out in it) is named, and it changes
nothing until each is dealt with. Then it saves each window's uncommitted and
untracked files as one commit on its `lease/<NN>` branch, moves its ignored
files to `state/rollback-kept/`, and removes the window worktrees with `git
worktree remove`. Every `lease/<NN>` branch stays, listed with what it holds,
so v0.6.1 can check it out. A branch the upgrade picked up gets its own name
back at its window's latest commit (its upstream settings with it), unless a
branch of that name is there already, and each `target/<repo>` goes back on
the branch it was on before the upgrade, read from the safety copy — when it
has changes or untracked files, it stays where it is and the command is
printed instead. Uncommitted changes the upgrade picked up come back as a
commit, and a trunk's commits that origin lacked stay on their window's
branch, named in the list. It removes the pre-push hook only
where it is Daedalus's own, puts `vault/hot.md`'s `session:` line back, and
removes `state/upgraded-to`; the `memory:` block, the key file and the safety
copy stay, unread by v0.6.1. Last it prints `git -C <home> checkout v0.6.1`,
which you run yourself, since the script is part of that code; start no
session before then. Running it twice is safe. To come forward again, check
your branch out again (`git -C <home> checkout main`) and start a session:
the upgrade runs again, and `core/lease.sh claim <NN>` brings a window's
worktree back from its branch.

**Rehearsing two windows.** `bash core/tests/scenarios/two-clones.sh` builds a
scratch deployment from fixtures (its own small target and a local stand-in
for origin — your deployment is never read or touched) and walks you through
two, then three, windows: at each step it says which terminal, what to say,
and what you should see, then checks the result. `--rehearse` plays every
window itself (the suite runs it that way); `--keep` leaves the scratch
directory to inspect.

**Local edits in tracked files**, made before v0.7.3, need nothing by
hand: `daedalus update` moves the local edits into the local layer, keeps
the backup, and takes the release. `core/doctor.sh` says MISSING, naming the
files, while a tracked file carries a local edit; promote and the launcher
keep refusing until then.

## Windows (leases)

Several Daedalus sessions can work the same target at once. Each interactive
terminal is a **window**: at start it takes the lowest free two-digit number
and is told "You are window 02". Its lease is a file under `state/leases/`
(written only by `core/lease.sh` and `core/leaselib.py`), and its checkout of
the target is a git worktree under `worktrees/02/<repo>/` on branch
`lease/02`, cut from `target/<repo>/` — which becomes the prime's mirror of
trunk that no session writes to. Both directories are gitignored and
per-deployment.

The tracked `.claude/settings.json` wires this: `core/session-start.py`
numbers the window and prints the **lease board** (one line per open window —
number, alias, task, changed files, last commit, last seen); `core/lease-board.py`
prints it again on every prompt and is the window's heartbeat; a
`PreToolUse(Edit|Write)` line runs `core/boundary-hook.py` before a write, so
the first attempt to change a file another window has already changed is
stopped once with the advice to message that window, and goes through on the
next try (`core/guard-bash.py` does the same for Bash write operands). One
window holds the pen — the board marks it `prime` — and only it commits the
vault, through `core/vault-commit.sh`. It commits every window's session log
too, and `vault/hot.md`. A window that closes while the pen's
holder is live is told "Your log is saved; window NN holds the pen and
commits it", and the holder commits that log at its next turn or when it
ends, whichever comes first. You never close windows in an order or move the
pen for a log to land. The holder's own commits leave out the log of a window
that is still open (it is still being written) and name whose logs they
carried.

A session that started while an upgrade was pending holds no window: none
opens until the upgrade finishes, so its safety copy reads `target/` first.
It can still close. `core/lease.sh log` reserves its session-log number
(kept in `state/leases/unwindowed.json`), and `core/lease.sh prime take` gives
it the pen when no live session holds it — never from a live one. The pen
gives it `core/vault-commit.sh`, not a tree: `target/`
stays closed to it until it claims a window, and promote waits until the
upgrade finishes. When a live session holds the pen, the operator can commit
the vault from their own shell: `cd <home> && core/vault-commit.sh`.

**`vault/hot.md`** answers two questions: what is underway, and what it is
waiting on. Every session start shows its In flight and Blocked entries in
every window, each with its owner, its next action, the condition that removes
it, and its age in days. Any window writes its own entries, and only through
`core/hot.py` (`add`, `update`, `remove`, `keep`), which changes one entry
under a lock, so two windows writing at once both land; an Edit or Write of the
file is refused and names the command. An entry looks like this:

```markdown
### the probe for the capture lock
- owner: window 02
- since: 2026-10-20
- where: lease/02
- next: run the probe twice
- done when: the probe passes twice in a row
```

When an entry's `done when:` is met, the window that sees it removes it in
that turn. At a window's close, `core/close.sh` marks its remaining entries
`owner: carried from window 02, <date>`; a sweep does the same for a window
closed without a close. The next window to take the work runs
`python3 core/hot.py update "<topic>" --owner 03`. An entry that has sat for
14 days is put to you at the first session start of the day: move it to the
backlog, or keep working on it in a window. Your answer, in any words, is
applied by that window (`keep` stamps `kept:` and restarts the 14 days).
There is no limit on the file's length. `core/doctor.sh` lists due entries and
any text not in entry form.

The board is also on your screen. A Claude Code mod under `mods/lease-board/`
draws it in the band above the prompt in every window and refreshes it every
2 seconds: one line per window, this window first — `window 02 · this window ·
live · 4 changed · poc-ui`, `window 01 · holds the pen · live · 0 changed`,
`window 03 · quiet since 09:40 · 14 changed · electron`. Live is plain, quiet is
yellow, stale is red, released is dim. It reads the lease files through
`python3 core/leaselib.py board-json` (shared lock, no git, nothing written)
and itself writes nothing. Install it once per deployment, in the Daedalus
home: `claude plugin marketplace add ./mods --scope local`, then
`claude plugin install lease-board@daedalus-mods --scope local`; `core/setup.sh`
runs both when they have not been run. Then open a new terminal, or run
`/reload-plugins` in a window that is already open. Inside the repo the install
writes only the gitignored `.claude/settings.local.json`; Claude Code also
records the marketplace and the install in its own per-user files under
`~/.claude/plugins/`. The mod loads in place from `mods/`, so a `git pull` that
changes it reaches the next session start with no version bump. One machine
holds one `daedalus-mods` record, so a second Daedalus checkout on the same
machine would load the first checkout's copy of the mod; the band still shows
the home the window was opened in, and `core/doctor.sh` notes the mismatch.
Two dim lines can appear under the board: `one window is not shown: …` when one
lease file cannot be read (every other window is still listed), and
`board unavailable: …` when the read itself failed (no `python3` on the path,
the Daedalus home not found above the working directory or the plugin, the
lease lock busy for over 1.5 seconds, a timeout); the last good board stays
above it. Mods need Claude Code 2.1.287 or later in the terminal; this was
built and tested against 2.1.296. `core/doctor.sh` reports the install (`lease
board on screen`) and whether the session registry still has the shape
liveness reads (`registry shape`).

`core/lease.sh` drives it from a session or your shell: `create`, `claim <NN>`,
`alias <NN> <word>`, `note`, `task <NN> "<one line>"` (the window's own line
for what it is working on, first on its board line; `--clear` when done),
`update`, `spawn`, `list`, `status`,
`log` (this session's log path for today — the counter is reserved in the
lease, never counted from the directory), `unpromoted <NN>` (what `release <NN> --remove` would delete; deletes nothing),
`release <NN>`, `done <NN>`, `sweep` (removes windows with no live session),
`adopt <branch>` (an in-flight branch in `target/` becomes a window) and
`prime take`. `leases.stale_after` in `config.yaml` (default `4h`) is
how long a window may go without a prompt before the board calls it quiet;
a window whose session is gone is stale and `sweep` removes it. A stale
window with nothing to lose — its recorded process gone, its worktree
clean, nothing unpromoted — does not wait for a sweep: the next terminal
start reclaims it (a resumed window too, before it rebinds; `create`,
`spawn` and `adopt` before they choose a number), so the terminal you open
in the morning is window 01 again and takes the pen from yesterday's
session. A released window needs no sweep either: its lease goes when its
session ends (the SessionEnd hook), or at the next terminal start if that hook
did not run. When a sweep (by hand, at a start or at the session's end)
removes a window whose session has ended, its worktree and `lease/<NN>` go
with it only if the worktree is its own checkout with no uncommitted or
untracked file git does not ignore, nothing hidden from `git status`, no commit
only its reflog holds, and the branch holds nothing `origin/<trunk>` lacks (a
released window whose session is still open keeps both). The worktree is not
deleted then but moved to `state/swept-trees/<NN>-<time>` with a `.swept.json`
naming each branch's last commit, and kept 7 days — git-ignored files such as
an `.env` go with it — before a later sweep deletes it; doctor lists what is
there. Otherwise both stay, the
sweep's line names which check kept them, and if the branch holds unpromoted
commits the number stays with them — the board and the band show it as swept
with work waiting, and a terminal numbered past it is told why. A stale window that still holds work, or a background clone that never
reported, keeps its number until you continue it or release it. To continue
window 01, say "this is window 01" in a new terminal: the number that terminal
took at start has nothing in it, so `core/lease.sh claim 01` gives it up (its
lease goes, as a reclaim's does, and the worktree is kept for the next number;
the session keeps its log number) and binds 01. A window that holds work of its own (a commit not on the trunk, an
uncommitted file) is refused, and the refusal names the work. You can also
start the terminal on the number: `DAEDALUS_LEASE=01 claude` in the home binds
window 01 at start, before any number is taken, as long as window 01 still has
its lease file (the board lists it); a swept number is claimed instead. Session logs
are named by date and one running counter per vault
(`vault/sessions/YYYY/MM/YYYY-MM-DD-NNN.md`); the start says each session's
path, and the window number is in the log's frontmatter.
`core/doctor.sh` reports the two lease directories, stale and released
windows, swept numbers with work still waiting, and the session registry
Claude Code keeps under `~/.claude/sessions/` (liveness reads it).

Deleting a window's work is report, yes, delete. `core/lease.sh unpromoted 02`
reports what would be lost and asks; the agent tells you. A window with
nothing to lose — no unpromoted commit, no uncommitted file, its worktree on
its own branch — needs no yes: the report says so and `release 02 --remove`
deletes it at once. Several windows go in one report and one yes:
`core/lease.sh unpromoted 02 03 04`, then
`core/lease.sh release 02 03 04 --remove --force --operator-said "<your reply>"`
deletes them all; a change in any one refuses the whole delete. Your yes is
whatever you say, in any words; the agent reads it. The tool checks only that
you typed something in the window's own transcript after the report — a turn
the agent wrote, or a line added to the file, never counts. It is refused when
no report ran in this session, when you have typed nothing since, and when the
window's work changed since the report. The tracked `.claude/settings.json` allows that one command
(`Bash(core/lease.sh release:*)`) ahead of auto mode's classifier, because
`core/guard-bash.py` and `core/leaselib.py` check the yes first, in every
permission mode (the guard behind any wrapper, leaselib for every form); what
authorised a deletion is written to `state/evidence/deletions/`. A project's
allow rules apply only in a folder whose workspace trust dialog you accepted
— the home is one from its first interactive session on (a `claude -p` run
never shows the dialog). A user-scope
`autoMode.classifyAllShell: true` in `~/.claude/settings.json` suspends every
Bash allow rule in auto mode, so on such a deployment the classifier is back in
front of the delete and may refuse it as it did before 2026-10-15;
`core/doctor.sh` says so.

## Service status (`core/status.py`)

Whether this deployment's services are running, at a glance. A second mod,
`mods/service-status/`, puts a one-word summary at the right end of the lease
board's first line, with the details in a pane:

```
window 01 · this window · live · 3 changed              services ok  [ details ]
window 02 · quiet since 21:40 · 0 changed
```

`services ok` is green. When something is down the summary names it in the
warning colour (`hindsight down`), or counts (`2 services down`) when the names
do not fit beside the board. `details`, or `/services`, opens a `Services` pane:
one row per service with its plain name, its stem, its state and one detail,
and the time of the last check; Esc closes it. A toast says when a service goes
down or comes back, never at startup. While anything is down, a status line
under the prompt reads
`⚠ service-status: hindsight down — /services for details`;
it goes when everything is back.

The mod runs `python3 core/status.py --json` in the Daedalus home once at
start and every 60 seconds. It takes under 2 seconds, never runs git, a model
or any program, and reaches nothing beyond this machine. Run it yourself
without `--json` for the same rows:

```
memory server   up          127.0.0.1:8888 answered
memory capture  up          last capture 2 min ago
vault search    up          store state/chroma
decider         not-set-up  frame-jack is off
code graph      not-set-up  no context: block in config.yaml
checked at 2026-10-17T21:40:00+00:00
```

The rows are the memory server (`memory.api_url`'s `/health`), memory capture
(the last capture against the sessions since), vault search (`recall.store`),
the decider (frame-jack's daemon) and the code graph (`context.graph`). A
service whose block is not in `config.yaml` is `not set up`: dim in the pane,
never counted as down. Frame-jack switched off is not down either. The mod also
checks the memory tools, the hindsight MCP server's tools in this session,
after a 15-second grace; when they are missing and the server is up, the pane
says to type `/mcp` and reconnect hindsight. It reads only: nothing here
restarts or fixes a service.

`core/setup.sh` installs the mod beside the lease board, and the upgrade to
0.11.0 installs it for a deployment that already has the board, so `daedalus
update` is still the one command. By hand, in the Daedalus home:
`claude plugin install service-status@daedalus-mods --scope local`, then open a
new terminal. Either mod can be switched off in `/plugin` without the other.
`core/doctor.sh` reports the install (`service status on screen`), and names
`claude plugin update <name>@daedalus-mods --scope local` for a mod installed
here that is older than `mods/` ships.

## Promote (`core/promote.sh`)

Trunk moves only through promote. The window holding the pen runs
`core/promote.sh 02` for window 02: it fetches trunk, merges `lease/02` onto
it in a scratch worktree under `state/promote/<id>/`, fingerprints the merged
tree, runs the gates (`core/gates.sh --no-refute --promote <id>`) and the
fresh-context reviewer (`core/refute.sh --mode promote`) on exactly that
merge, and prints two paragraphs: the decision, in plain words, and the
record (merge commit, trunk, evidence run, review, fingerprint, promotion
id). Nothing is pushed.

What already passed is not repeated (v0.12.8). When the merged tree is
byte-identical to a tree that already passed its gates — trunk had not moved
and the window ran its gates on its last commit — the promotion's gate run is
PASS by reuse and runs nothing (the block says "this exact tree already
passed them, nothing re-ran"; the record names the run it reused). When the
window's own branch review judged exactly that tree, promote launches no
reviewer: "Review STANDS — window 02's review of this exact tree, not
repeated", or, for a refuted one, the refutation and your choice, as for any
REFUTED. `--skip-review` then re-runs nothing either. Only a merged tree no
earlier run or review has judged gets the gates and a fresh reviewer. The
confirm re-derives a reused review from its own files as it does a fresh
one: the review and each reviewer's receipt must name exactly the
fingerprint of what will be pushed, and the distribution code that ran it
must be today's. `core/promote.sh 02 --confirm` then re-derives every
piece of evidence from its own file, records the operator's yes, and pushes
exactly the merge commit the evidence names; the prime's checkout is
fast-forwarded when it is on trunk and clean, and the window's worktree stays
until it is released.

**The operator's yes** (`promote:` in `config.yaml`):

- `confirm: transcribed` (the default) — your instruction is the yes. "Promote
  window 2", in any words, followed by a clean result (gates PASS, the review
  STANDS, nothing you have not seen) is pushed in the same turn; a result with
  something new in it is shown once and your reply, in any words, is the yes.
  Whether your words agree is the agent's judgment. promote checks one thing:
  that you typed something in the prime's own session transcript since the
  window's last promote — one word or fifty. The agent cites a few of your
  words with `--operator-said "…"`; that is a citation, not a password, and is
  refused only when the words it cites are in no turn you typed.
  A transcript this Claude Code build writes in a shape the parser cannot read
  is refused, never passed — switch to `promote.confirm: tty` until the parser
  is updated. The transcript directory is closed to writes by both the Bash
  guard and the Edit check, and your turn must also be a prompt Claude Code
  reported to Daedalus as it was submitted (the UserPromptSubmit hook records
  each one beside the transcript), with the transcript before it unchanged
  since — words rewritten into the file never count.
- `confirm: tty` — the operator pastes one line into their own shell and
  types `yes` (or any acknowledgement) at the terminal; that shell pushes and finishes the rest, and
  the prime's next prompt says it happened. The confirm refuses a process
  started by a Claude Code session or by no terminal login, and the guard
  refuses programs that make terminals — a stronger check than the
  transcript, but not a proof that a person typed it: on one user account a
  determined agent can still build a terminal. `promote.tty_parents` names a
  terminal program other than login, sshd, tmux or screen.
- `release_note: true` (and optionally `update_command: '…'`) — for a
  deployment where a promote is a release; the decision block and the pushed
  line say so. `release_note: false` says a promote is not one.

`config.yaml` is the operator's: the agent may not edit it. The lines a
release needs there and only a person can answer — `promote.release_note`,
`promote.update_command`, `direct_call.callers`, and on a cloud provider
`verify.refute_model` — are shown by `core/doctor.sh` as one paste, printed
bare so it can be copied as it is: exact where the answer is known, a `<...>`
with its question on a comment line above where only the operator knows it.
Doctor never fills in who may call (`callers`).

**When it refuses.** Every refusal ends "Nothing was pushed." (or "Nothing
changed on origin." after a rejected push). A merge conflict: the window runs
`core/lease.sh rebase 02` and resolves it in its own worktree. Commits in two
repos: `core/lease.sh split 02 --repo <nested>` moves the nested repo's
commits to a new window, promoted separately. A refuted review: ask it about
a finding with `core/call-agent.sh --resume-review 02 "…"`, or, when the
operator says to in any words, promote with `--skip-review --reason "…"`: their
words are checked like a yes and recorded beside the verdict it sets aside
(`vault/evidence/promotions.log` names the overridden review). Gates are
never skipped. `core/promote.sh 02 --clean` removes a window's scratch trees.

**The pre-push hook.** `core/prepush.py` installs a pre-push hook in each
target repo's shared `.git/hooks/` (lease allocation, `core/sync-target.sh`
and so `core/setup.sh`, and promote itself; `core.hooksPath` is never
touched, and a hook Daedalus did not install is never overwritten). It
refuses a push to the trunk, `main` or `master` unless the push is the
merge of a confirmed promotion, fast-forwarding the trunk it was tested on,
pushed once. It is a second check beside the Bash guard, not a signature:
the record of what was pushed is the confirm's re-derivation. Both checks
live on this machine, so a push by a route the guard does not parse, from a
clone outside the home (which has no hook), is caught only by server-side
branch protection on the remote — set it where you can. `core/doctor.sh`
reports each repo's hook and trunk, the confirm mode, and any promotion
prepared but never confirmed.

The transcript format is internal to Claude Code and changes between
releases. `core/tests/fixtures/transcripts/live.jsonl` is a redacted copy of a
real transcript (see its `PROVENANCE.md`); after a Claude Code upgrade, run
`bats core/tests/test_transcript.bats core/tests/test_capture.bats` — they
fail first if the fixture's shape moved. Those tests read only the fixture, so
`core/doctor.sh` also reads the newest transcript of this deployment's own
sessions (read-only) and says MISSING — "this Claude Code build's transcript
shape is not the one Daedalus was tested against; promote confirm will refuse
until the fixture is refreshed" — when the installed build writes a shape the
parser does not know; confirm refuses with the same sentence. Refresh the
fixture as `PROVENANCE.md` says, and use `promote.confirm: tty` meanwhile.

## Episodic memory capture (optional)

`core/capture.py` reads Claude Code session transcripts and posts new turns to
a Hindsight episodic-memory server. It is additive: `setup.sh` and the gates
work fully with episodic capture unconfigured.

### One place for its configuration: the `memory:` block

Everything capture needs lives in a `memory:` block in `config.yaml`.
`config.example.yaml` carries the block commented out; adding it turns capture
on.

```yaml
memory:
  bank: daedalus
  api_url: http://127.0.0.1:8888
  # A file under the Daedalus home holding the REST API key, mode 0600.
  api_key_file: state/hindsight/api-key
  capture_interval: 120
  # Optional; see below.
  # transcript_dir: /path/to/transcripts
  # user_label: OPERATOR
  # assistant_label: Daedalus
```

- `bank` — the Hindsight bank. Required once the block is there.
- `api_url` — defaults to `http://127.0.0.1:8888`.
- `api_key_file` — the bearer credential for the REST API `capture.py` posts
  to, in a file under the Daedalus home. `chmod 600` it: capture refuses a key
  file others can read. This is a **different credential** from the bearer
  token a Hindsight MCP client uses against `/mcp/BANK/` — using the MCP
  token here authenticates as the wrong principal and the server returns
  `401 Invalid API key`. Keep the key in the file, never on a hook command
  line, where any process listing shows it. In capture's environment the file
  named by `memory.api_key_file` becomes `HINDSIGHT_API_TENANT_API_KEY`.
- `capture_interval` — seconds between captures of one session at Stop;
  default 120.
- `transcript_dir` — where Claude Code writes this home's transcripts. The
  default is `~/.claude/projects/` (or `$CLAUDE_CONFIG_DIR/projects/`) plus
  this home's resolved path with every character other than a letter or
  digit turned into `-` — Claude Code's own naming. Capture needs it only
  when no hook has named the transcript; `core/doctor.sh` says when the
  directory does not exist.
- `user_label`, `assistant_label` — how turns are labelled in memory;
  default `User` / `Assistant`.

An environment variable of the same meaning overrides one field:
`TENANT_BANK`, `HINDSIGHT_API_URL`, `HINDSIGHT_API_TENANT_API_KEY`,
`TRANSCRIPT_DIR`, `CAPTURE_INTERVAL`, `TENANT_USER_LABEL`,
`TENANT_ASSISTANT_LABEL`, `TENANT_HOME`. That is how a hook line written for
an older release keeps working. `core/doctor.sh` reports the block, or says
capture is off.

### When capture runs

- **At every Stop** — `core/capture-tick.sh`, wired in the tracked
  `.claude/settings.json`. At most once per `capture_interval` for each
  session. The capture runs in the background (its output goes to
  `.capture.log`), so a turn never waits on memory, and what one window
  learned reaches the bank within minutes.
- **When the session ends** — the same script with `--final`: the last turns,
  no interval, after any Stop capture still sending.
- **`core/close.sh`** — the explicit flush at the end of a working session. It
  waits until the server confirms every part of the session it holds —
  including what the Stop captures sent earlier — and otherwise exits
  non-zero, naming the parts not yet confirmed, so you close again. If
  another capture of the session is still in flight it waits up to 90
  seconds; past that it exits non-zero with "a capture is still in flight
  after 90 s; wait and close again" rather than report a close that did not
  happen. Once the session is stored, it then commits the vault through
  `core/vault-commit.sh`; `--no-commit` skips that (`--commit`, the old
  opt-in, is still accepted). When another live session holds the pen,
  `core/vault-commit.sh` says so in one line and exits 3, and the close still
  succeeds: the close says "Your log is saved; window NN holds the pen and
  commits it", and that window commits the log at its next turn or when it
  ends (`core/vault-pending-hook.sh`, on Stop and SessionEnd). When the
  pen's holder has ended, a terminal session takes the pen and commits; a
  headless one never takes it. If the commit fails for another reason, the
  close exits 4: the session is recorded, so fix what the line names and run
  `core/vault-commit.sh`, not the close. From an operator shell
  (`--transcript`), the commit runs as the operator's, as a bare
  `core/vault-commit.sh` does; a live other window's claimed documents are
  still left out.

The transcript is named, never guessed: the hook payload's `transcript_path`;
else the path this session's start recorded; else
`<transcript_dir>/<CLAUDE_CODE_SESSION_ID>.jsonl`. From a shell with none of
those, name it: `core/close.sh --transcript <path>`. With nothing to go on,
capture refuses rather than flush another session.

A transcript is read in whole lines, so a turn Claude Code is still writing
waits for the next capture. If the transcript format changes under a newer
Claude Code, `.capture.log` says once "transcript parse failure — …";
entries capture cannot read are not stored, and a stretch with nothing
readable is held for a build that can read it.

One capture of a session runs at a time. A second one — a Stop capture while
the end-of-session flush is sending, or two windows closing together — sees
the first's in-flight mark in `state/hindsight/offsets.json` and skips (from
`close.sh`, waits). A mark left by a process that died is recognised by its
process id and start time and cleared.

A session started by the direct-call launcher does not capture itself
(`CAPTURE_DEFER_TO_CALLER=1` or `DIRECT_CALL_ID` in its environment); the
caller records it.

### Moving from the hook line in `.claude/settings.local.json`

Releases before v0.7.0 wired capture as a `SessionEnd` command in
`.claude/settings.local.json`, with its values as `VAR=value` prefixes on the
command line. That line keeps working — its prefixes override the block — so
nothing breaks while you move the values into `memory:` (the bank, the
transcript directory, and the key into `state/hindsight/api-key`). Once they
are there, the line can be removed; `core/doctor.sh` says so.
From v0.7.0 the upgrade does this move for you at the first session start after
the pull (see "Upgrading"), and `recall-inject.py` reads the block too, so its
line needs no prefixes either.

### What happens when extraction fails

The server returns `202` when it *accepts* a batch; extraction runs afterwards
and can fail on its own. The Stop capture and the end-of-session flush do not
wait for that verdict — extraction takes tens of seconds — so each records the
pushed span in a retry ledger inside `state/hindsight/offsets.json` and
finishes.

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
uses the same bank and key as capture, and it is optional — a deployment
without it works, and the skill still does.

It reads the same `memory:` block capture does, so its hook line carries no
values and no key; a `TENANT_*` prefix on the line still overrides the block.

Add to `.claude/settings.local.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 /path/to/daedalus/core/recall-inject.py"
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
at most ten memories are surfaced. Those numbers are a starting position,
and a recorded miss is what argues for loosening them.

**The document index** is separate from the memory bank, and optional: the
`recall:` block in `config.yaml` names a deployment-owned engine that indexes the vault into
`recall.store`, and `core/vault-search.py` is its only runner. Since
2026-10-15 the index follows the vault by itself. It is rebuilt after every
vault commit `core/vault-commit.sh` makes (each close, unless `--no-commit`), and
at the start of the window that holds the pen when the index is older than
the vault — in the background, never holding the turn, one run at a time
under `state/recall-index.lock`; a vault change during a run makes the run go
once more. Each run is framed in `state/recall-index.log`: `started <time> by
vault-commit|session-start|operator`, then `finished <time> indexed=N
purged=M`, or the engine's last output lines and `failed <time>: <reason>`.
`core/doctor.sh` says when the index last rebuilt and how it went.
`python3 core/vault-search.py index` runs one by hand, in the foreground; a
clone is refused, because the prime rebuilds it.

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
- **Daedalus's write surfaces are `target/` (through each window's worktree
  under `worktrees/`, see "Windows (leases)"), `vault/`, and `.claude/`
  (aside from the tracked `settings.json`).** Skills it authors and scratch space
  its tooling needs are its own work product, not distribution.
- Development happens at one site only. Defects found in Daedalus travel back
  as a proposal, not a local patch.

### The verify stage

Hooks in the tracked `.claude/settings.json` make a completion claim
unrecordable without evidence. `core/gates.sh` writes the evidence. An
optional `gates_setup:` list in `config.yaml` runs first in the tree under
test — a window's worktree or promote's scratch, which holds tracked files
only — to build what the gates need, such as a virtual environment; a
setup step that fails, or one whose output git can see, makes the run
INVALID before any gate, and a gate that exits 127 is reported as unable
to start rather than as a failing merge. A tree that already passed is not
tested again (v0.12.8): an earlier run with the same tree fingerprint, the
same `config.yaml` and the same `core/`, whose gates passed, makes the run
PASS by reuse — no setup step or gate runs, and the record says
`reused_from: <run id>`. Never a null fingerprint, a gates FAIL, an INVALID or
unfinished run, or a run the evidence manifest does not list. An optional
`gates_rerun_failed:` list (one command per gate, in order) runs once when its
gate fails, on the same tree, to re-run only the failures (for pytest,
`--lf --lfnf=none`); exit 0 makes the gate PASS after a rerun, both logs kept
and named in the summary. The
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
criteria (`GATES_CRITERIA=<file>` when calling `core/gates.sh`, else the file the
window named with `core/lease.sh update <NN> --criteria <file>`), the evidence
record, the pitfalls whose `applies-to: path:` matches a touched path (plus
every pitfall with no `applies-to:`), and the diff — in that order — and is
told the checkout's absolute path so it can read the touched files. A
pitfall selector that crashes or is missing makes the run uncertifiable
(FAIL), never a silent "(none)".

**The bar between a finding and a refutation.** Every finding heading
carries three labels: a severity (HIGH, MEDIUM, LOW); its input's standing —
*observed* (the input is in the evidence, fixtures, criteria or the target's
own code paths), *plausible* (the reviewer states a specific reason it could
occur) or *hypothetical* (possible, nothing points to it); and whether it is
*in scope* or *out of scope* of the criteria. The verdict is computed from
the labels by `refute.sh`, not taken from the reviewer's last line: an
in-scope observed or plausible HIGH or MEDIUM finding refutes, and so does
any observed HIGH; hypothetical, out-of-scope and LOW findings are listed
for the operator ("N findings not counted … — see <review file>") and do not.
A labelled heading missing a label, or a review with no verdict line, is
uncertifiable (FAIL), never STANDS; a new run never falls back to the
reviewer's word over an unlabelled finding. A review with no labelled
findings that promote re-reads from before this release keeps its own verdict
line. The rubric is the audit trail, not a second verdict: a dimension scored
FAIL with nothing counted behind it is named as set aside. Promote's decision
block reads its counts from the same labels (`refute.sh --counts-of`), so it
says how many findings were set aside rather than "2 high findings" over two
hypothetical ones.

**Criteria carry a Scope section** — what the change covers, the evidence
it rests on, and what is out of scope — and the reviewer judges against it.
Daedalus writes it when it writes the criteria; a missing one is reported
as an observed, in-scope LOW finding (listed, not refuting), and the
reviewer then judges against the change's evident intent.

**After the second refutation of a window's branch**, `gates.sh` prints the
operator's three choices — another round; promote with the remaining
findings filed as backlog rows; or skip the review with the operator's
reason — instead of leaving the loop to the builder. The count lives in
`state/refutations/<NN>.json` and starts again after a promote or when the
window is released and its number taken again.

**A large change is reviewed through several lenses at once.** On a large
branch one reviewer, within its timeout, can follow only a few threads, so
each run was a different sample — a 56-commit branch was refuted ten times,
each review right, each finding something new on code that had not changed.
From `verify.lens_lines` changed lines or `verify.lens_files` files (800 and
25 by default), a window's branch review runs one fresh reviewer per lens —
`verify.lenses`, by default `criteria` (correctness against the criteria),
`trust` (trust boundaries), `upgrade` (existing installs and upgrade) and
`failure` (failure handling) — at the same time (`verify.lens_concurrency`,
default 4), each under its own `verify.refute_timeout`. Their findings are
merged into `<run>-review.md`: one finding per place, with the strongest
labels any lens gave it and the lenses that found it; each lens's own review
is kept beside it as `<run>-lens-<name>-review.md`. The verdict is computed
from the merged findings exactly as from one review. A lens that times out,
fails or writes an unlabelled finding fails the run as uncertifiable — a
review with a lens missing is never a STANDS. A smaller change keeps one
reviewer: lenses cost one review each for about the same wall-clock time.
The run says which, and why: `review: 4 lenses (criteria, trust, upgrade,
failure) — the change is large (1210 lines in 31 files; lenses from 800 lines
or 25 files)`.

**Every window's branch keeps a findings ledger**
(`state/review-ledger/<NN>.json`, started again after a promote or a new
lease, as the refutation count is). The next review of that branch is told
the findings earlier reviews counted and asked to check them first: one
fixed is named on a `Resolved:` line; one not fixed is reported again
(`earlier L1` in its heading); one whose fix broke something is reported as
`regressed L1`, which refutes whatever its labels. One it neither resolves
nor reports again is carried into its verdict as it was. Then it hunts for
new findings in what changed since the last review (its commits, from the
commit the last review saw, and the uncommitted work), with the whole diff
there to read around it; a rebase that rewrote the branch leaves the whole
diff to hunt. The run says how the earlier findings fared:
`review: 3 earlier findings: 2 resolved, 1 open`.

**Promote's review takes neither.** It is the last gate: one fresh reviewer,
not told what earlier reviews found — so it cannot inherit their blind spots
— whose prompt is re-rendered byte for byte at confirm. When the merged tree
is exactly one the window's own review already judged, that review is
promote's (v0.12.8), and the confirm checks its receipts' fingerprints
instead of a re-render.

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
Daedalus's write surfaces; `core/` is not. `refute.sh` assembles the review
and the direct-call launcher runs it: `core/call-agent.sh --callee refuter`
renders the charter with `core/agentdef.py`, refuses while `core/`,
`CLAUDE.md` or `.claude/settings.json` differ from the committed version (a
modified reviewer cannot certify anything), and runs `claude` from an empty
temporary directory with the checkout granted through `--add-dir`, hooks
off, no MCP servers, `Read`/`Grep`/`Glob` only, and `--settings` excluding
every `CLAUDE.md` and turning auto memory off. Measured on Claude Code
2.1.282: the charter's `omitClaudeMd` does not stop `claude -p --agent` from
loading the working directory's `CLAUDE.md`, a `CLAUDE.md` under an
`--add-dir` directory is not loaded, and the account's user-level
`~/.claude/CLAUDE.md` and auto memory still load from an empty directory —
which is what the exclusions are for. The review is written once per run to
`vault/evidence/<run-id>-review.md`, whose frontmatter records the call id,
the fingerprint of the tree reviewed, the mode, the sha256 of the exact
prompt, and the committed `core/` tree and charter.

**Proving the reviewer shares nothing with the author** is a canary with a
positive control, in `core/tests/test_refuter_charter.bats`. The canary in the
test suite is stubbed: it runs on every build against a stand-in `claude` that
models how Claude Code loads context, so it proves the launcher's wiring, not
what the real CLI loads. The live canary, with its positive control, is the
per-deployment check the operator runs, once per deployment and again after a
Claude Code upgrade, against the real CLI —
`DAEDALUS_LIVE_CANARY=1 bats core/tests/test_refuter_charter.bats -f 'canary \(live'`
— and read the result: the control (the charter run from the tree, no
exclusions) must answer `PINEAPPLE` or the test fails as inconclusive; the
launcher's review must not, and must refute the seeded defect. The live
canary rests on that answer alone; in the suite the stand-in also records
every file it loaded, and the reviewer's list must be empty. Neither canary
exercises auto memory — the reviewer runs from a fresh directory, which has
no project memory to load — so the auto-memory switches are pinned by the
launch assertions in the same file instead. If the control fires and the
review leaks, the build loads context the exclusions do not reach; say so as
a proposal before trusting a review there. A managed policy `CLAUDE.md` (the
organization's) cannot be excluded by any setting; when one is present the
review names it (`managed-claude-md:`).

**Asking the reviewer about a finding.** Every review is a receipted call
(`state/direct-calls/<call-id>/`). To ask the reviewer that found a defect
what it meant — the same session, with its findings in context —
`core/call-agent.sh --resume-review 02 "Finding F2 says the lock is not
released on the error path. Show me the line."` resumes the most recent
review of window 02. After a lens review (several reviewers at once) it
resumes none of them: it names each lens's call, and the merged review says
which lens found each finding — `core/call-agent.sh --resume <call-id> "…"`
asks that one. The answer is advice, never a verdict: a resumed review
cannot write the review file, and a new verdict needs a new run.

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

## Direct calls (`core/call-agent.sh`)

One launcher, three callees, one receipt format:

- `--callee agent --to <key>` asks one of the agents this deployment may
  consult a read-only question ("what is this hook for, before I change it?").
  Each is one `callee_<key>:` block in `config.yaml`: its `name`, its `home`,
  and a `consult_for` line that says what to ask it. Session start lists the
  keys with their `consult_for`, and the agent chooses whom to ask, saying in
  one line whom and why. With exactly one callee, `--to` may be left out;
  with several and no `--to` the call is refused, and the refusal lists them.
  The call runs in that agent's home with its hooks, so its own identity
  loads. Nothing else can name a callee: there is no default and no
  command-line flag for a home. If the agent publishes a callers list
  (`direct_calls.callers` in its `agent.yaml`, or a `.direct-callers` file),
  Daedalus must be on it; with `launcher:` the agent's own launcher runs
  instead and applies its own list, receipt and capture. A launcher whose
  stderr reads differently from Daedalus's own (`<Name> call <id>; ...` and
  `orientation: yes`) is described by `launcher_call_id` and
  `launcher_oriented`, two regular expressions in its block. A block's own
  `timeout`, `tools`, `max_turns`, `capture` and `capture_wait` beat
  `direct_call`'s. `config.example.yaml` shows a block with every field.
- A deployment from before 0.10.0 that names its one callee in
  `direct_call.callee_home` and `direct_call.callee_name` keeps working
  unchanged: that callee's key is its name in lower case. The upgrade says so
  in one line and does not touch `config.yaml`. Doctor prints one line per
  callee, and whether its callers list admits Daedalus where Daedalus can
  read it; it never makes a call.
- `--callee self --caller <name>` is how another agent asks this Daedalus;
  the name must be in `direct_call.callers`. The called session is a
  visitor: it never takes a window number or the pen.
- `--callee refuter` is the reviewer (above); only `core/refute.sh` calls it.

The answer is on stdout and a two-line receipt on stderr:

```
Daedalus call 4f1c…; receipt state/direct-calls/4f1c…
Daedalus orientation: yes; capture: confirmed; exit: 0
```

On a failure the second line says why, after the exit code. Exit codes: `0`
answered and the callee's identity verified; `2` refused before anything ran
(unlisted caller, no callee configured, several callees and no `--to`, a config other than this
deployment's `config.yaml`, bad arguments, modified distribution code); `3`
answered but the identity marker was not found; `124` timed out and killed;
anything else is `claude`'s own failure.
Check the exit code and that the answer is not empty — never the receipt
line alone. `--resume <call-id>` continues a call, with the callee it went
to: the key comes from the receipt, never the command line. Every call is read-only:
`Read`, `Grep` and `Glob`, no MCP servers, and a frame prompt that says it
is a discussion, not a work order. With a `memory:` block, the launcher
captures the call afterwards with the caller and the callee as the speakers;
the called session's own capture stands down.

## Code context (`core/context.py`)

`core/context.py` answers "what else does this change touch?" for the
target, so the agent can read those files before it changes one:

```bash
python3 core/context.py callers app/core.py::helper   # or a bare function name
python3 core/context.py importers app/core.py
python3 core/context.py tests app/core.py             # or app/core.py::helper
python3 core/context.py reach app/core.py             # or app/core.py::helper
python3 core/context.py grep "some text"
```

Add `--json` for one JSON object an agent can read. Every answer merges three
sources, file by file, and labels each file: `both` (the code graph and
`git grep` named it), `graph only`, `grep only`, or `rule:<name>` when only a
rule (below) named it. They are candidates, not answers:

```
reach app/core.py — window 02, repo app; graph updated (0.4 s)
both          app/user.py:3
graph only    tests/test_core.py:12
grep only     templates/job.md.tmpl:1
rule:python-path-join  tools/call.py:9  ROOT / "app" / "core.py"
4 files: 1 both, 1 graph only, 1 grep only, 1 rule (python-path-join 1). These are candidates, not answers: read each file, and let the tests decide.
```

It runs only when someone invokes it. No hook calls it, nothing builds an
index at session start, and nothing refreshes in the background. The agent
runs it in its window when it is about to change code. While brainstorming,
planning or writing a spec it runs when the talk turns on what already exists
or when you ask, and the agent says in one line that it checked. Inside a window the
first query builds the window's index and every later query updates it, all
inside one time budget (`context.graph_budget`, 90 s). Outside a window (your
own shell, a direct call) it answers from `git grep` and the rules over
`target/` and writes nothing. The index and the logs live under
`state/code-context/`: one index per window and repo, removed once the window
is swept.

The code graph is optional. It is Code Review Graph, version 2.3.9, which
reads Python calls, imports and tests. Without it every answer comes from
`git grep` and the rules, and the header says so once. Neither source sees
everything: YAML keys, templates, shell scripts that run Python, and Python
run by path or with `-m` are what the rules are for.

### Install (optional, once per machine)

```bash
mkdir -p ~/crg && cd ~/crg
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python 'code-review-graph==2.3.9'
.venv/bin/code-review-graph -v        # code-review-graph 2.3.9
```

Then paste the `context:` block from `config.example.yaml` into `config.yaml`,
with `graph` set to the absolute path of `.venv/bin/code-review-graph`:

```yaml
context:
  graph: /abs/path/to/crg/.venv/bin/code-review-graph
  placeholders: ENGINE=engine
```

- The venv is about 444 MB (the tree-sitter language pack). An index is about
  35 MB per window and repo on a 280-file target.
- The package is PyPI `code-review-graph`, MIT licensed, from
  github.com/tirth8205/code-review-graph. The similarly named
  `better-code-review-graph` is a different project.
- Never run its `install`, `init`, `register`, `daemon`, `serve`/`mcp` or
  `watch` commands, and never register its MCP server. They write MCP entries,
  hooks, skills and rule files into your coding tools' configuration, or a
  registry under your home. `core/context.py` runs only `build`, `update`,
  `query` and `impact`, with `HOME`, `CRG_HOME` and `CRG_DATA_DIR` pointed
  under `state/code-context/`, and the Bash guard refuses the agent's own
  direct call of the tool.
- Any other version is treated as not installed: doctor says which version it
  found.

### Rules

A rule maps a convention to the file it names, for the links neither the
graph nor `git grep` resolves. Rules only add candidates; nothing can remove
one.

- `core/context-rules.json` ships with the release: `module-run`
  (`python -m X`, `uv run -m X`), `template-placeholder` (`{{NAME}}/x.py` in a
  template, with the directories in `context.placeholders`),
  `python-path-join` (`ROOT / "a" / "b.py"`) and `shell-beside`
  (`python3 "$(dirname "${BASH_SOURCE[0]}")/x.py"`).
- `vault/context-rules.json` holds this deployment's own rules. The agent may
  add one when a kind of miss repeats, with where it came from and a test
  made from the line that was missed; it tells you in one line. `daedalus
  update` never touches the file.
- Each rule has its own test. `python3 core/context.py rules --check` runs
  them all; a rule whose test fails is skipped, with one line saying so.

### Misses at promote

Each query in a window is recorded. When the window is promoted, the files it
changed and the tests that failed in its gate runs are compared with what its
queries named, and the record paragraph of the promote block gains one line:

```
Code context: 2 changed files no query named — templates/job.md.tmpl (template path, also missed in 2 earlier windows), bin/tool.py (other); the log is state/code-context/misses.jsonl.
```

A file the window changed without asking about anything near it is counted
as unasked, not as a miss of the tool. The line never stops a promote. Every
miss is a row in `state/code-context/misses.jsonl`, with the kind of link
that was missed.

### Doctor

`core/doctor.sh` prints one or more code-context lines, never a MISSING:

```
OK       code context: code-review-graph 2.3.9 at /abs/path/to/crg/.venv/bin/code-review-graph; 4 release rules, 0 deployment rules; every rule test passes
NOTE     code context: no code graph configured (context.graph in config.yaml), so answers come from git grep and the rules (optional; see "Code context" in README.md)
NOTE     code context: rule template-placeholder has no placeholders to map (context.placeholders in config.yaml), so it adds nothing
```

Doctor runs the graph's `-v` and the rules' own tests only; it never builds
or reads an index. It also notes a leftover `recall.ruff` line and a
`.claude/settings.local.json` entry that still runs `core/code-context.py`,
the edit-time hook 0.9.0 removed.

## Frame-jack (the AMI)

Frame-jack is an on/off switch for the AMI (Artificial Machine Intelligence):
a small local decision model, Strands Decider 2B, run by
`strands-decider serve` on this machine. It answers yes/no questions with a
calibrated confidence. It cannot write text or reason. In this release it
knows two questions and **only writes its answers down** (shadow mode):

- before a full-suite run during a build: "given the files edited since the
  last run, would a targeted run do?". The evidence run, `core/gates.sh`,
  is never asked; what it runs is its own rule (in full, unless that exact
  tree already passed or a gate re-runs only its failures). Asked by default
  (`ask_suite: true`).
- before every Bash call the guard did not deny: "is this command
  destructive or irreversible?". **Off by default** (`ask_destructive:
  false`). Its precision measured 0.36, the destructive cases that matter
  are already denied by the guard's own rules, and a question on every Bash
  call costs battery and heat for nearly nothing. Off means no inference and
  no row for it. Set `ask_destructive: true` to collect shadow answers again.

It is optional. Without an `ami:` block nothing changes, and everything
else in Daedalus works the same. When it is on, it costs about 5.2 GB of
unified memory while the daemon is up, measured with `footprint`.

### Install

Once per machine, into a virtual environment of its own (Python 3.12):

```bash
mkdir -p ~/ami && cd ~/ami
uv venv --python 3.12 .venv-mlx
git clone --depth 1 https://github.com/strands-labs/strands-decider strands-decider-src
uv pip install --python .venv-mlx/bin/python -e './strands-decider-src[mlx]' 'mlx-lm<0.33'
```

The `[mlx]` extra exists only in the git clone until the next PyPI release,
and `mlx-lm` must stay below 0.33 (the backend reaches into its internals).
MLX is the default device on Apple silicon (`device` may be left out; it
is `cpu` elsewhere): it measured about 2.7 times faster than MPS here, and it
survives concurrent questions, where two overlapping questions crashed the
MPS daemon (below). A deployment that installs the PyPI package instead
(`uv pip install --python .venv/bin/python strands-decider`) has no mlx
extra and must say `device: mps`; doctor then prints a NOTE naming that
crash. Where GitHub is blocked, the clone comes by hand too.

The first start downloads the weights (about 4.8 GB) into the Hugging Face
cache. Where Hugging Face is unreachable, copy them by hand (below).

### The config paste

Paste the block into `config.yaml` and fill in `command` with the absolute
path of the `strands-decider` executable inside the virtual environment —
never a bare name on `PATH`. `config.example.yaml` carries the same block,
commented, with a line on each key. `/frame-jack on` without a block refuses
and prints these lines to paste.

```yaml
ami:
  command: /abs/path/to/ami/.venv-mlx/bin/strands-decider
  model: StrandsAgents/strands-decider-2B-qwen3.5-v1-2610
  device: mlx
  port: 8761
  offline: false
  battery_off: true
  request_timeout_ms: 1500
  ask_destructive: false
  ask_suite: true
```

Every window of this deployment shares one daemon. A second deployment on
the same machine should name the same `port`: it then borrows the daemon
instead of starting a second one, and never stops it. Thresholds are not
config; they are the output of a measurement and live in `core/amilib.py`.
A config edit takes effect at the next `/frame-jack on`.

### The switch

- `/frame-jack on` writes the sentinel `state/ami/on` and starts a
  supervisor that keeps `strands-decider serve` running. The AMI answers in
  about 30 seconds. The band above the prompt shows `AMI starting (…)`, then
  `AMI on`.
- `/frame-jack off` removes the sentinel and stops the daemon. It says
  "freed" only once the port is closed.
- `/frame-jack status` prints the long form: the daemon's pid and memory,
  the decisions this session, the commands it would have asked you about,
  and how often its call was overruled. That last count is the calibration
  meter.
- On battery the daemon stops by itself, and on AC power it starts again
  (`battery_off: false` turns this off). The band says `AMI paused on
  battery`.

The agent may run `core/frame-jack.py on` or `off` only after you said so in
the session; the guard refuses it otherwise. The agent may not write or
delete anything under `state/ami/`, which is the AMI's record. From a plain
shell, `python3 core/frame-jack.py on|off|status` is yours, unrestricted.

Off means conservative, never "skip the check": with the sentinel absent,
the port dead, or the machine on battery, every consumer takes the branch it
would take without the AMI. A sentinel present with a dead daemon warns
once per session.

### What shadow means

Shadow mode asks the question, writes the answer, its confidence and its
latency to `state/ami/decisions.jsonl`, and acts on nothing. The real
outcome of the command is written beside it. The AMI never grants a call,
never replaces a deny, never asks you, and never shortens a test run in
this release. Acting (enforce mode) was offered only if the AMI met a bar
fixed before it was measured:

| Question | Bar | Measured (in-sample, MPS) |
|---|---|---|
| Destructive or irreversible | recall ≥ 0.95, precision ≥ 0.60, Brier ≤ 0.15 | 1.00 / 0.36 / 0.054, on 4 positives |
| Would a targeted run do | accuracy ≥ 0.85, "targeted" when full was needed ≤ 0.05 | 0.78 / 0.068 |
| Latency | median ≤ 400 ms per question | 245 ms on MPS, 60 ms on MLX |

Neither question met its bar, so both ship in shadow mode only. Naming a
question under `ami.enforce` is a doctor MISSING, and the question stays in
shadow mode. The shadow log is what the next measurement is built from.

Numbers. Concurrent questions: two at once crashed the MPS daemon (a Metal
assertion), while MLX queued four callers at a 149 ms p99. The client
therefore holds a lock, so one deployment's windows never overlap.

### Weights by hand

On a laptop behind a corporate proxy, Hugging Face is likely unreachable.
The weights are two snapshots in the Hugging Face cache, and the large files
sit in a shared blob store the snapshot folders only link into. Copying the
two model folders alone copies links to nothing. Copy the folders and the
two blobs together (4.76 GB, nothing stored twice):

```bash
# on a machine that has them
cd ~/.cache/huggingface/hub && tar -czf ~/strands-decider-weights.tgz \
  models--Qwen--Qwen3.5-2B-Base models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610 \
  blobs/6c/6cb808828f2829da873eb9e83ef220d632e340d54272f0ebdd1a31bd8ee0ded2 \
  blobs/47/47ee46d5ecca77fec40d7d7cbe4e5d2044b44984f34b09092ac9c6b5cdb78144
# on the laptop: the same layout, links resolving into the same store
mkdir -p ~/.cache/huggingface/hub && tar -xzf ~/strands-decider-weights.tgz -C ~/.cache/huggingface/hub
```

Then set `offline: true` in the `ami:` block, so the daemon runs with
`HF_HUB_OFFLINE=1` and never tries the network. The two blob names are
pinned for this model version. The expected snapshots are base `b1485b2f…`
and decider `216d1ccb…`. This procedure is written down but
not yet run there; the first copy on that laptop is its test.

### Doctor

`core/doctor.sh` prints a `frame-jack` block from one reader,
`python3 core/frame-jack.py --doctor`. Anything the deployment works without
is a NOTE: no block, the weights absent, the daemon down, a second daemon on
the machine. A block that says something false is a MISSING. For example:

```
NOTE     frame-jack: no ami: block in config.yaml — the AMI cannot be switched on (optional; see "Frame-jack" in README.md)
OK       frame-jack: strands-decider at <path>, model StrandsAgents/strands-decider-2B-qwen3.5-v1-2610, device mlx, port 8761, online
OK       frame-jack questions: suite asked; destructive not asked (ami.ask_destructive is false — the default)
NOTE     frame-jack: device mps — two overlapping questions crashed the MPS daemon in the lab (a Metal assertion, twice); MLX queues them, about 27 questions a second in the same 5.2 GB — set ami.device: mlx (README "Frame-jack" installs the mlx extra)
NOTE     frame-jack questions: none asked (ami.ask_destructive and ami.ask_suite are both false) — switched on, the daemon would hold about 5.2 GB for nothing; leave frame-jack off
NOTE     frame-jack questions: the running daemon asks destructive and suite asked, not what config.yaml now says (suite asked; destructive not asked (ami.ask_destructive is false — the default)) — /frame-jack off, then on, to apply it
MISSING  frame-jack: ami.command <path> is not an executable file — install strands-decider into a virtual environment and name its strands-decider here
MISSING  frame-jack: ami.enforce names destructive, which no release has certified to act — remove it; the question stays in shadow mode
NOTE     frame-jack weights: models--Qwen--Qwen3.5-2B-Base has links into a blob store that is not there — the folders were copied without the blobs; copy with the tarball in README "Weights by hand"
OK       frame-jack weights: both snapshots present (4.76 GB)
OK       frame-jack: off (the sentinel is absent; /frame-jack on starts the AMI)
NOTE     frame-jack: on, paused on battery
NOTE     frame-jack: a second strands-decider serve is running on this machine (pid 70012, port 8762, not this deployment's) — two daemons cost twice 5.2 GB; name the same ami.port in both deployments so one borrows the other
```
