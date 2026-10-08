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
      "Write(/path/to/your/harness/**)",
      "Edit(/path/to/your/harness/**)"
    ]
  }
}
```

## Upgrading

A deployment takes a release by pulling this repository in its home:
`git pull --ff-only` (a session may run exactly that; the guard allows no
other git route into Daedalus's own code, and refuses even that when git's
settings would fetch from anywhere but the address this checkout records for
its branch — then pull in a shell). Nothing else is done by hand. At the next
session start `core/session-start.py` compares `VERSION` with
`state/upgraded-to` and, when they differ, runs `core/upgrade.py` before the
window numbers itself. Each step acts once and says one line when it does:

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
   files. Nothing was changed. Say 'pick it up' to move it into windows, or
   finish and ship it the usual way, then start a new session." The board
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
7. writes `state/upgraded-to`, last — never while a window picked up from `target/` has no
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
make one (no room, or over `upgrade.snapshot_max_mb`, 2048 by default), and
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
`cat VERSION` prints the release, and `git describe --tags --abbrev=0` its tag.
`core/doctor.sh` reports the version, the stamp, and anything in `target/`
still off its trunk. A stash in a target checkout is saved work no window
shows, so it is never the remedy: the upgrade stops on it, and `core/doctor.sh`
names it until it is picked up, applied or dropped. A picked-up window is promoted from the board ("promote
window 01") or released, like any other; `core/lease.sh adopt <branch>
[--repo <nested>]` does the same for any branch later.

**Going back to v0.6.1.** Close every session in the home, then run
`python3 core/upgrade.py --rollback` from a terminal there; `--dry-run` first
prints the plan and changes nothing. It refuses while a Daedalus session is
live, naming it (`--force` goes ahead anyway). It saves each window's
uncommitted and untracked files as one commit on its `lease/<NN>` branch,
moves its ignored files to `state/rollback-kept/`, and removes the window
worktrees with `git worktree remove`; a window it cannot save safely (on
another branch, in the middle of a rebase, locked) is named, and it stops
there until that is dealt with. Every `lease/<NN>` branch stays, listed with
what it holds, so v0.6.1 can check it out. It removes the pre-push hook only
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
number, alias, changed files, last commit, last seen); `core/lease-board.py`
prints it again on every prompt and is the window's heartbeat; a
`PreToolUse(Edit|Write)` line runs `core/boundary-hook.py` before a write, so
the first attempt to change a file another window has already changed is
stopped once with the advice to message that window, and goes through on the
next try (`core/guard-bash.py` does the same for Bash write operands). One
window holds the pen — the board marks it `prime` — and only it writes
`vault/hot.md` and commits the vault, through `core/vault-commit.sh`.

`core/lease.sh` drives it from a session or your shell: `create`, `claim <NN>`,
`alias <NN> <word>`, `note`, `update`, `spawn`, `list`, `status`,
`release <NN>`, `done <NN>`, `sweep` (removes windows with no live session),
`adopt <branch>` (an in-flight branch in `target/` becomes a window) and
`prime take`. `leases.stale_after` in `config.yaml` (default `4h`) is
how long a window may go without a prompt before the board calls it quiet;
a window whose session is gone is stale and `sweep` removes it. Session logs
are named by window number and date (`vault/sessions/YYYY/MM/YYYY-MM-DD-02.md`).
`core/doctor.sh` reports the two lease directories, stale and released
windows, swept numbers with work still waiting, and the session registry
Claude Code keeps under `~/.claude/sessions/` (liveness reads it).

## Promote (`core/promote.sh`)

Trunk moves only through promote. The window holding the pen runs
`core/promote.sh 02` for window 02: it fetches trunk, merges `lease/02` onto
it in a scratch worktree under `state/promote/<id>/`, fingerprints the merged
tree, runs the gates (`core/gates.sh --no-refute --promote <id>`) and the
fresh-context reviewer (`core/refute.sh --mode promote`) on exactly that
merge, and prints two paragraphs: the decision, in plain words, and the
record (merge commit, trunk, evidence run, review, fingerprint, promotion
id). Nothing is pushed. `core/promote.sh 02 --confirm` then re-derives every
piece of evidence from its own file, records the operator's yes, and pushes
exactly the merge commit the evidence names; the prime's checkout is
fast-forwarded when it is on trunk and clean, and the window's worktree stays
until it is released.

**The operator's yes** (`promote:` in `config.yaml`):

- `confirm: transcribed` (the default) — the prime types the operator's reply
  with `--operator-said "…"`, and promote requires it in the prime's own
  session transcript as a whole message the operator typed, which begins with
  yes, after a reply of the prime's that repeated the block, in a later turn.
  A transcript this Claude Code build writes in a shape the parser cannot read
  is refused, never passed — switch to `promote.confirm: tty` until the parser
  is updated. The transcript directory is closed to writes by both the Bash
  guard and the Edit check, and the yes must also be a prompt Claude Code
  reported to Daedalus as it was submitted (the UserPromptSubmit hook records
  each one beside the transcript), with the transcript before it unchanged
  since — a yes rewritten into the file is refused.
- `confirm: tty` — the operator pastes one line into their own shell and
  types `yes` at the terminal; that shell pushes and finishes the rest, and
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
a finding with `core/call-agent.sh --resume-review 02 "…"`, or promote with
the operator's written reason, `--skip-review --reason "…"`, which is checked
like a yes and recorded beside the verdict it sets aside
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
  happen.

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
review of window 02. The answer is advice, never a verdict: a resumed review
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

- `--callee agent` asks the target's own agent — the one whose home and name
  `config.yaml` sets in `direct_call.callee_home` and `direct_call.callee_name`
  — a read-only question ("what is this hook for, before I change it?"). The
  call runs in that agent's home with its hooks, so its own identity loads.
  Nothing else can name the callee: there is no default and no command-line
  flag for it, and the call is refused while the two keys are unset. If the
  agent publishes a callers list (`direct_calls.callers` in its `agent.yaml`,
  or a `.direct-callers` file), Daedalus must be on it; with
  `direct_call.callee_launcher` the agent's own launcher runs instead and
  applies its own list, receipt and capture.
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
(unlisted caller, no callee configured, a config other than this
deployment's `config.yaml`, bad arguments, modified distribution code); `3`
answered but the identity marker was not found; `124` timed out and killed;
anything else is `claude`'s own failure.
Check the exit code and that the answer is not empty — never the receipt
line alone. `--resume <call-id>` continues a call. Every call is read-only:
`Read`, `Grep` and `Glob`, no MCP servers, and a frame prompt that says it
is a discussion, not a work order. With a `memory:` block, the launcher
captures the call afterwards with the caller and the callee as the speakers;
the called session's own capture stands down.
