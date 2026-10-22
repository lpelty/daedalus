# Changelog

Releases are annotated git tags (`git tag -a vX.Y.Z -F <notes>`); the notes
for each release live here first, and the tag message repeats the headline.
Earlier releases (v0.1.0 – v0.6.0) are described by their tag messages only.

## v0.12.7 — three checks stop misjudging what a window did, and sweep cleans up after itself

**In short.** The suite question is asked for a large test run that names
files. Another window's review files no longer show up as this window's
dirt. Merging another window's branch no longer blocks every Stop. And a
swept window's merged, clean worktree and branch are removed, kept for 7
days in a trash first.

**What went wrong.**
- A pytest or bats run that named any file counted as "targeted". Seven
  globbed groups, 322 tests and four minutes got no question; only a bare
  `pytest` did.
- The review lenses wrote their files under `vault/evidence/` and listed
  them in the manifest only after every lens finished. For the whole review,
  every other window was told "Protected files changed this session …
  Revert these" about files it never wrote. A lens that failed but left its
  file was never listed, so that message never stopped.
- After a window merged another window's branch, as asked, the Stop check
  listed every merged file as "the warning never fired (the pre-write hook
  timed out?)", at every Stop, even after the owner was messaged. A merge
  never passes through the pre-write hook.
- Sweep removed a window's lease but kept its worktree and branch. The
  window then no longer existed, so nothing in Daedalus could remove them.

**What changed.**
- A test run is judged by how many test files its arguments name, after
  globs (`*`, `**`), braces and `~` are expanded and a `cd` earlier in the
  command is followed. More than 3 files, a directory, or no files at all
  is a full run and gets the suite question. A word that names nothing
  counts as one file only right after an option that takes a value, as in
  `--timeout 30`; otherwise it counts as large.
- Every review path, the lenses' and the verdict's, is listed in the
  manifest before any reviewer starts. A review that ends without a verdict
  records each path's state in `state/evidence/<run>/unwritten.json`: the
  file's checksum if it was there, or "absent". Only that exact file is
  excused afterwards; a file written there later is flagged.
- The Stop check treats files that arrived by merging another window's
  branch as handed over. A file this window changed again after the merge is
  said once, naming the merge. Every such block is said once per file and
  per other window, and recorded only after it was said.
- Sweep removes a window's worktree and deletes `lease/NN` only when all of
  these hold, and otherwise keeps both and names the check that failed:
  - the window's session has ended, or its process is gone; a window with
    no process on file keeps both;
  - each worktree is its own checkout, with nothing uncommitted, nothing
    git is told to look away from, and no commit in its history that the
    trunk lacks;
  - `lease/NN` is on the trunk.
- A removed worktree is moved, with its git-ignored files, to
  `state/swept-trees/<NN>-<time>`, with a `.swept.json` naming each branch
  and its last commit. A later sweep deletes it once it is 7 days old, in
  the background, outside any hook's time.

**What you will see.**
- Sometimes a suite question where there was none: "Given the files edited
  since the last run, is a targeted test run sufficient?" An unneeded question
  is the cheap way to be wrong.
- No more "Revert these" about another window's review files, and no
  repeated "the warning never fired" after an agreed merge.
- After a sweep: "… its worktree moved to state/swept-trees/04-…, deleted
  after 7 days", or "worktree and branch kept: <reason>".
- `core/doctor.sh` lists each entry in `state/swept-trees/` with its age.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal.

**How to tell you have it.** `cat VERSION` prints `0.12.7`. `core/doctor.sh`
has a "swept trees" line once a sweep has moved a worktree.

**Not in this release.** Worktrees and branches left behind by sweeps before
this release are not cleaned up; sweep acts only when it removes a lease.

## v0.12.6 — hot.md is shown at every start, every window writes its own entries, and an old entry gets a question

**In short.** Every session start now shows hot.md's In flight and Blocked
entries, in every window. Each entry is a short block: who owns it, the next
action, and the condition that removes it. Any window writes its own entries
through one command. An entry that has sat for 14 days is put to you once:
move it to the backlog, or keep working on it.

**What went wrong.**
- hot.md only grew. On one deployment it reached 798 lines.
- Nothing read it at the start, so nobody saw it grow.
- Removing an entry took judgment nothing supplied. No entry said who owned
  it, when it began, or what would make it done.
- Only the window holding the pen could write it. A window that closed with
  unfinished work could leave it only in its session log.
- Most of the growth sat in the "Done since the last entry" section.

**What changed.**
- Each entry under In flight or Blocked is one block, with `owner:`,
  `since:`, `where:`, `next:` and `done when:`.
- `core/hot.py` is the only way the file changes: `add`, `update`, `remove`,
  `keep`. It changes one entry under a lock, so two windows writing at once
  both land.
- An Edit or Write of `vault/hot.md` is refused, and the refusal names the
  command.
- Any window adds entries. A window changes its own, carried ones, and ones
  owned by you or another agent. Another open window's entry is refused,
  naming that window.
- When an entry's `done when:` is met, the window that sees it removes it in
  that same turn.
- At a close, `core/close.sh` marks the window's remaining entries carried. A
  sweep does the same for a window closed without a close.
- An entry 14 days old is asked about at the first start of the day. Your
  answer, in any words, is applied by that window. `keep` stamps `kept:` and
  restarts the 14 days.
- The template's Done section is gone. What was done goes in the session log.
- There is no limit on the file's length, and no warning about it.

**What you will see.**
- At every start, a list under In flight and Blocked. Each entry shows its
  owner, next action, done-when and age in days.
- At most once a day for each old entry: "hot.md entry '<topic>' has sat for
  14 days (owner: window 02). Move it to the backlog, or keep working on it in
  a window?"
- At the first start after the update, an entry with no date gets today's
  date, so no wave of questions follows.
- Any other section, such as "Done since the last entry" or a "Waiting on"
  section, is named at every start with its line count. Nothing in the file
  is hidden.
- Text not in entry form, and those sections, are listed once to the window
  holding the pen. They are kept until that window moves them: waiting items
  to Blocked entries, done items to the session log, standing rules to
  `pitfalls/`.
- `core/doctor.sh` lists old entries and text not in entry form.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal.

**How to tell you have it.** `cat VERSION` prints `0.12.6`. A session start
shows "hot.md — what is underway and what it waits on".

## v0.12.5 — your instruction is your yes

**In short.** Say "promote window 2" in any words, and a clean result is
pushed in the same turn. Promote and delete no longer read your words for a
yes. They check one thing: that you typed something since the last promote,
or since the report for a delete.

**What went wrong.**
- Promote still stopped you after you told it to promote. It wanted a second
  answer in a later turn, after the result was shown.
- Skipping a refuted review needed a reason of at least three words.
- A later "wait", a message typed while the window was busy, or words that
  named only some windows could each refuse a plain instruction.

**What changed.**
- A clean result (gates pass, the review stands, nothing new) is pushed right
  after your instruction, in the same turn.
- A result with something new in it is shown once. Your answer, in any words,
  is the yes.
- `--skip-review` takes any words, one word included. `--reason` is optional.
- The tools check only that the words came from you: typed in this session,
  written by Claude Code, and reported as you sent them.
- Whether your words mean yes, and to which windows, is the agent's to read.
- Deleting a window with work still reports what would be lost and asks once.

**What you will see.** Fewer questions. A refusal now says only "The operator
has typed nothing in this session since …".

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal.

**How to tell you have it.** `cat VERSION` prints `0.12.5`. CLAUDE.md's
Promote section says the confirm checks one thing.

## v0.12.4 — review settles instead of growing, and a session never locks up on a blocked stop

**In short.** A review now judges a finding by who meets it, not only by how
it fails. A later review refutes only on what changed since the last one. The
first review reports everything it finds at once. A change to a file the
session read at its start is made after a restart, never with a `!` command.
No stop check blocks the same turn twice, so you always get the turn back.

**What went wrong.**
- A large change was refuted round after round. Each fix drew new findings,
  most of them edge cases nobody meets, on code that had not changed.
- A finding only a live run could settle had nowhere to go but the verdict.
- Changing `config.yaml` with a `!` command looked like the session's own
  change. Every stop after it was blocked until the session locked up.
- A stop check that needed your answer blocked again and again in one turn,
  and you had no turn to answer it.

**What changed.**
- Each finding names its reach: `user` (an ordinary action meets it),
  `routine` (something the system runs on its own meets it) or `none`. It may
  carry the flags `data`, `trust` and `live-only`.
- An observed HIGH still refutes. Other HIGH and MEDIUM findings refute only
  with reach user or routine, or with the data or trust flag.
- Everything else is a backlog candidate. It is listed, kept in the window's
  ledger, and never refutes.
- On a later review, a new finding outside the change since the last review
  is marked `missed earlier` and does not refute. An observed HIGH with the
  data or trust flag still does.
- The first review of a branch is told to report every defect it finds.
- A `live-only` finding is kept as a live check. Promote lists the open ones
  in its decision block, and your yes covers them.
- The brief has a new section, "Changes that need a restart". A change to
  `config.yaml`, `.claude/settings.local.json` or `CLAUDE.local.md` is given
  to you as one command to run after exiting, in a plain terminal.
- A change to one of those files blocks one stop, then is only noted.
- Every stop check blocks at most once a turn for the same reason. The block
  says what to do, and to ask you once and end the turn when it needs you.

**What you will see.**
- The gates list backlog candidates and live checks by name, for example
  `review: kept in the ledger, not counted: 2 backlog candidates`.
- Promote's decision block may say
  `Live checks still open (only a live run can settle these; a yes covers them)`.
- When a restart is needed, the window says so, closes the session, and gives
  you one command for after you exit.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal.

**How to tell you have it.** `cat VERSION` prints `0.12.4`. CLAUDE.md has the
section "Changes that need a restart".

## v0.12.3 — a large change is reviewed through several lenses at once, and each window says what it is working on

**In short.** A large change is no longer reviewed one slice at a time.
Several fresh reviewers look at it at once, each through one lens, and their
findings are merged. Every window's branch keeps a ledger of what its reviews
found, so the next review checks those first. Every window now keeps one line
on the board saying what it is working on, and reads the others' before it
starts.

**What went wrong.**
- One reviewer read a large change and could follow only a few threads before
  it stopped. Each run found a different slice, so a large branch was refuted
  round after round.
- Each review started cold. It did not see what earlier reviews had found or
  which of those were fixed.
- A window given a task started at once. It met another window's work only
  when it tried to change a file that window had already changed.

**What changed.**
- From 800 changed lines or 25 files, a window's branch is reviewed by several
  fresh reviewers at once. Each looks through one lens: the criteria, trust
  boundaries, existing installs and upgrade, and failure handling.
- Their findings are merged into one review, one finding per place, judged at
  the strongest labels any lens gave it.
- If one lens fails or times out, the whole run fails. It never stands on part
  of a review.
- A smaller change keeps one reviewer.
- The thresholds, the lenses and how many run at once are set in config.yaml
  under verify.
- Every window's branch keeps a ledger of the findings its reviews counted.
  The next review checks those first, then looks for new problems in what
  changed since the last review.
- A finding no review has checked is carried forward. A fix that broke what it
  fixed refutes.
- Promote's review is still one fresh reviewer with no earlier findings.
- Asking the reviewer about a finding after a lens review names each lens's
  call. The merged review says which lens found it, so you ask that one.
- Every window keeps one line on the board for what it is working on. When
  you give a window a task, it writes that line first, then reads what the
  other windows are doing.
- If another window is working on the same thing, it sends that window one
  message before it starts.
- You never set this line yourself, and your own note for a window stays as
  you wrote it. A window clears its line when it is done. A background clone
  starts with its task already set.
- The task is on the board the windows read. The band above the prompt does
  not show it, so its rows stay short.

**What you will see.**
- The gates say how a change was reviewed and why, for example
  `review: 4 lenses (criteria, trust, upgrade, failure) — the change is large`.
- A re-review says how the earlier findings fared, for example
  `review: 3 earlier findings: 2 resolved, 1 open`.
- A window asked to start work tells you if another window's task overlaps.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal.

**How to tell you have it.** `cat VERSION` prints `0.12.3`. The board each
window reads shows `task:` on a window that has one.

## v0.12.2 — your yes in your own words, a small fix stops looping in review, and the window holding the pen commits every window's log

**In short.** Deleting a window's work and promoting take your consent in
whatever words you give it. Nothing has to be typed word for word or answer a
set line. A window with nothing to lose is deleted without asking, and one yes
deletes several windows. A small fix no longer goes round the review loop
forever. A window's session log no longer depends on the order you close
windows in.

**What went wrong.**
- The delete and the promote looked for one exact line, and your yes counted
  only as your first reply after it.
- A yes to a reply that covered two windows was refused. So was "delete", and
  so was a reason given after a question or a notification.
- A yes typed at the prompt was sometimes refused as added to the file
  afterwards: the check read the transcript before the reply was written.
- A window with no commits and no changes still needed a report and a yes, and
  deleting several looped, one window per yes.
- The reviewer refuted a change on any finding. A finding that needs an input
  nobody has seen blocked a promote as hard as a real one. A small fix grew
  each round and never passed.
- A window that closed while another held the pen left its log uncommitted
  until that window happened to commit again. Sometimes that was the next day,
  unless you closed the windows in the right order.

**What changed.**
- After the report or the prepare, your latest message that agrees or asks for
  the action is the yes. Questions, answers and notifications between do not
  matter.
- Yes, ok, go ahead, delete them, push the work and ship it all count. So does
  a sentence that agrees beside a question.
- Anything else you say after it takes its place: a no in any words, wait,
  keep it, not yet, push it tomorrow, yes if tests pass.
- A message that is only a question changes nothing. A bare ok beside a
  question is not a yes.
- Your words must still be typed by you in that session. A yes the agent wrote,
  or a line added to the file, is refused.
- The check reads the transcript again for about two seconds before it refuses
  a yes whose reply is not written yet.
- A window with no unpromoted commit, no uncommitted file and its worktree on
  its own branch is deleted at once, saying no yes was needed.
- `core/lease.sh unpromoted 02 03 04` reports several windows, and
  `core/lease.sh release 02 03 04 --remove` deletes them under one yes.
- One yes answers one report. Windows reported apart are refused until one
  report names them all.
- A yes that names some of the windows deletes none ("yes, but only 02"). A
  change in any window since the report refuses the whole delete by name.
- To skip a refuted review, your yes needs a reason of three words or more,
  in the same message or the one just before it.
- The report and the promote block end with a plain question that nothing
  checks.
- Each finding the reviewer writes now says how likely its input is:
  observed, plausible or hypothetical. It also says whether it falls inside
  the change's scope.
- Only in-scope observed or plausible findings of high or medium severity
  refute a change. Any observed high one does too. The rest are listed for you
  and set aside.
- The verdict is worked out from those labels, not taken from the reviewer's
  last line. A review that cannot be read still fails.
- Criteria now carry a Scope section: what is covered, what it rests on, and
  what is out.
- After a window's branch is refuted twice, the gates print your three
  choices instead of starting another round.
- If you close a window while another window holds the pen, that window
  commits the log when its current turn ends or when it closes.
- The window holding the pen leaves out the log of any window that is still
  open, because that log is still being written. It names the windows whose
  logs it committed.

**What you will see.**
- After a report, "delete them" or "ok" deletes the windows it named.
- After a prepare, "Same reason: just push the work." skips the review.
- A window with nothing on it is deleted with the line
  `Window 03 had no unpromoted commits and no uncommitted changes, so no yes was needed.`
- Promote's summary says how many findings were set aside.
- Closing a window while another holds the pen says
  `Your log is saved; window 01 holds the pen and commits it.`
- You never move the pen to get a log committed.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. A promotion prepared before the update is prepared again,
because the review's instructions changed.

**How to tell you have it.** `cat VERSION` prints `0.12.2`. The promote block
ends with `Push window 02's work to main?`.

## v0.12.1 — released windows clear themselves, a skipped number says why, and memory reads up by either path

**In short.** A released window no longer sits on the board until you
sweep it. When a new window takes a higher number than you expect, Daedalus
says why. The memory row on the service band reads up when memory works,
whether it goes through the REST API or through MCP tools.

**What went wrong.**
- A released window kept its number until someone ran
  `core/lease.sh sweep`. Nothing ran it on its own.
- A number held by unpromoted commits on `lease/NN`, or by a worktree
  checked out on another branch, was skipped with no word. The board showed
  nothing there, so a new window took 05 beside an empty-looking 02.
- The memory row looked only for MCP tools. A home that reaches memory
  through the REST API alone, with no MCP server, read down while memory
  worked.

**What changed.**
- A released window is removed at the next window start once its process
  is gone. Its worktree and branch are kept, as `sweep` keeps them.
- At exit, a session removes its own lease when it released it. A `/clear`
  keeps it, and so does a session still open in another terminal. This is a
  new SessionEnd hook in `.claude/settings.json`.
- A released lease with no recorded process waits for that exit or for
  `sweep`. A heartbeat's age is not proof the terminal closed.
- Start and `create` say in one line why lower numbers were passed over.
- The band shows a number held by unpromoted work as its own row. Doctor
  names a worktree checked out on another branch.
- `core/status.py --json` reports whether a memory MCP server is
  configured, read from Claude Code's own config files.
- The memory row is up when the MCP tools are connected. With no MCP server
  configured, it is up when the memory server and capture are up.
- It reads down only when a configured MCP server's tools never appear.
  Only then does it show the `/mcp` line.
- When the memory server itself is down, the row reads blocked. It is dim
  and not counted twice.
- Mods: lease-board 0.1.4, service-status 0.1.1.

**What you will see.**
- At start, a line such as
  `Numbered 03, not a lower number: 02 is released and its session is still open.`
- On the band, a row such as
  `swept — 3 unpromoted commits waiting — say "this is window 02" to continue it`.
- On a home with no memory MCP server, the memory row reads up, and
  `services ok` when the rest are up.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.12.0 -> 0.12.1; doctor OK.`
The new exit hook and both mod updates come with it.

**How to tell you have it.** `cat VERSION` prints `0.12.1`. A released
window is gone from the board once its terminal is closed.

## v0.12.0 — daedalus start, and one command for every home

**In short.** `daedalus start` starts Daedalus in the right home. It shows
the banner and whether the services are up, then Claude Code takes the
terminal. The `daedalus` command now serves every home on the machine, not
just one: a command means the home you name, else the one you are in, else
the default.

**What went wrong.** `~/.local/bin/daedalus` was written for one home. On a
machine with two homes, `daedalus update` typed anywhere updated that one
home, never the other.

**What changed.**
- `daedalus start [home] [--window NN] [-- <claude args>]` goes to the home,
  prints the banner, a version line and one line per service, waits
  `start.pause` seconds, then runs Claude Code in its place.
- The service lines come from `core/status.py --json`. A service that was
  never set up is left out. A failed or slow check is one line. Nothing is
  started, stopped or fixed.
- `--window NN` starts the session in window NN. Arguments after `--` go to
  Claude Code.
- The banner is the home's own `banner.txt` when it has one, git-ignored
  like `config.yaml`. Otherwise it is the release's `core/banner.txt`.
- `start`, `update` and `version` pick their home the same way: a name on
  the command, else the home the current directory is in, else the default.
- An unknown name is refused with the valid names, exit 2. So is a bare
  command outside every home with several homes and no default. Nothing
  falls back to another home.
- The homes are listed in `~/.config/daedalus/homes.json`. Setup and the
  upgrade register their home, named after its folder without a leading
  `daedalus-`; a folder named `daedalus` is `main`.
- `daedalus homes` lists them. `daedalus homes rename <old> <new>` and
  `daedalus homes default <name>` edit the list.
- One shim serves every home. The upgrade rewrites the old one-home shim it
  wrote and registers the home that shim served. It still never touches a
  file it did not write.
- Doctor prints one more line: how many homes the command serves and which
  is the default.

**What you will see.**
- `daedalus start` prints the banner, then
  `Daedalus 0.12.0 · lares · ~/daedalus-lares`, then lines such as
  `✓ memory server` or `✗ memory capture — last capture 40 min ago`.
- The upgrade says, once, `Registered ~/daedalus-lares as lares in ~/.config/daedalus/homes.json.`
- Where an old shim served another home, it says the shim now serves every
  home (`daedalus homes lists them`).
- Doctor: `OK       daedalus command: 2 homes, default work`. With several
  homes and no default it is a NOTE naming `daedalus homes default <name>`.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.11.0 -> 0.12.0; doctor OK.`
With a second home, then type `daedalus update` and its name, such as
`daedalus update main`; `daedalus homes` lists the names. Set the default
once, for example `daedalus homes rename main work`, then
`daedalus homes default work`.

**How to tell you have it.** `cat VERSION` prints `0.12.0`. `daedalus homes`
lists your homes. `daedalus start` shows the banner, then Claude Code.

## v0.11.0 — the services at a glance, beside the lease board

**In short.** Every window now shows whether this deployment's services are
running. A one-word summary sits at the right end of the lease board's first
line: `services ok`, or what is down. The details are in a pane. This is a
trial, kept easy to change or switch off.

**What changed.**
- A second mod, `mods/service-status/`, ships beside the lease board. It reads
  only, and never restarts or fixes a service.
- `core/status.py` is the one reader behind it. It checks the memory server,
  memory capture, vault search, the decider and the code graph in under 2
  seconds. It runs no git, no model and no other program.
- `python3 core/status.py --json` prints one row per service, each with its
  stem, name, state and one detail. A state is `up`, `down` or `not-set-up`.
- A service whose block is not in `config.yaml` is `not-set-up`. It never
  counts as down. Frame-jack switched off is not down either.
- The mod also checks the memory tools in the session, after a 15-second grace
  while MCP servers connect.
- The lease board now keeps what the next mod draws at the right end of its
  first line. The two mods share the band in either order.
- `core/setup.sh` installs the mod beside the lease board. The upgrade to
  0.11.0 installs it for a deployment that already has the board at local
  scope. A failed install is one line and never stops the upgrade.
- The upgrade now updates a Daedalus mod that is already installed. A window
  loads a mod from Claude Code's plugin cache, not from `mods/`, so a newer
  mod in a pulled release stayed unseen and doctor said nothing. For each mod
  enabled for this home whose installed version is older than the one in
  `mods/`, the upgrade runs `claude plugin update <name>@daedalus-mods --scope
  local` in the home, after any new install. A failed update is one line
  naming the command and never stops the upgrade.
- Doctor prints a NOTE for a mod installed here that is older than `mods/`,
  naming the same command.
- The lease board 0.1.3: the board's first line keeps its full length, up to
  60% of the band, beside the services' summary. On Claude Code 2.1.302 it
  was cut at about half the band.

**What you will see.**
- At the right of the board's first line: `services ok` in green, or
  `hindsight down` in the warning colour, or `2 services down` when the names
  do not fit. While the first check runs: `services: checking…`.
- `details`, or `/services`, opens a `Services` pane with one row per service
  and the time of the last check. Esc closes it.
- A toast when a service goes down or comes back: `Hindsight went down`,
  `Hindsight is back`. Nothing at startup.
- While anything is down, one status line under the prompt:
  `⚠ service-status: hindsight down — /services for details`. It goes when
  everything is back.
- When the memory tools are missing and the server is up, the pane says:
  `Memory tools aren't connected. Type /mcp and reconnect hindsight.`
- Doctor prints one more line, `service status on screen`.
- The upgrade says, once:
  `Installed the service-status mod at local scope: the services' summary now sits at the right of the lease board.`
- For a mod that was behind, the upgrade says, once:
  `lease-board mod updated 0.1.1 → 0.1.3; run /reload-plugins in an open window`.
- Doctor, while a mod is behind: `NOTE     lease-board mod out of date: 0.1.1 is installed for this home, mods/ ships 0.1.3`,
  with the command that updates it.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.10.0 -> 0.11.0; doctor OK.` Open
a new terminal to see the summary.

**How to tell you have it.** `cat VERSION` prints `0.11.0`.
`python3 core/status.py` prints one line per service. `core/doctor.sh` prints
`OK       service status on screen`.

## v0.10.0 — named callees: one Daedalus may ask several agents

**In short.** A deployment can now name more than one agent that Daedalus
may ask a question. Each gets its own `callee_<key>:` block in
`config.yaml`, with a `consult_for` line saying what to ask it. A call names
the key: `core/call-agent.sh --callee agent --to <key>`. Daedalus chooses
whom to ask, and says in one line whom and why. A deployment with one callee
changes nothing. A confirmation is now any acknowledgement in the operator's
own words, not only one that begins with yes.

**What changed.**
- A callee is a top-level block, `callee_<key>:`, with `name`, `home` and
  `consult_for`. The optional fields are `launcher`, `launcher_args` and
  `marker`.
- A block's own `timeout`, `tools`, `max_turns`, `capture` and
  `capture_wait` beat the shared ones in `direct_call:`.
- `--to <key>` picks the callee. With one callee it may be left out. With
  several and no `--to`, the call is refused, and the refusal lists each key
  with its `consult_for`.
- The receipt records the key. `--resume <call-id>` takes the key from the
  receipt, never from the command line. A changed callee still refuses the
  resume.
- A callee's own launcher may report on stderr in its own words. Two
  optional regular expressions in its block, `launcher_call_id` and
  `launcher_oriented`, say where its call id is and which line means its
  orientation was verified. Unset, the launcher must speak Daedalus's own
  receipt, as before.
- The one-callee keys of 0.9.0 (`direct_call.callee_home`, `callee_name` and
  the rest) are still read. That callee's key is its name in lower case.
- A legacy callee and a block with the same key is a problem doctor names.
  Calls are refused until one is removed.
- Session start lists the callees in one line, each with its `consult_for`.
  With none configured it says nothing.
- `direct_call:` still holds who may call this Daedalus. That list is
  unchanged.
- A confirmation no longer has to begin with the word yes. Any
  acknowledgement in the operator's own words passes: "Okay, yes, proceed.",
  "ok", "go ahead", "sounds good, push it".
- A reply with no, not, wait, hold, stop or later in it is refused, and so is
  a question. This holds for promote, typed or recorded, and for deleting a
  window's work. The reply must still be the operator's whole message after
  the block.
- `core/code-context.py` stays a no-op in this release. 0.9.0 said it would
  go now. Removing a leftover hook entry for it needs the upgrade to edit a
  local settings file, which no upgrade has done before.

**What you will see.**
- Doctor prints one line per callee, and whether its callers list admits
  Daedalus where Daedalus can read it. Doctor never makes a call.
- A callee with no `consult_for` is a NOTE. It is still callable.
- A deployment with a legacy callee sees one line at the upgrade:
  `direct_call's callee AgentName is now callee "agentname"; nothing to change.`
  The upgrade does not touch `config.yaml`.
- At session start, a line beginning `Agents you may consult`.
- A confirmation that is not an acknowledgement is refused with
  `The operator's words are not an acknowledgement`.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.9.0 -> 0.10.0; doctor OK.` To
add a callee, paste a `callee_<key>:` block into `config.yaml`.
`config.example.yaml` shows one with every field.

**How to tell you have it.** `cat VERSION` prints `0.10.0`.
`core/doctor.sh` prints a `direct call: callee <key>` line for each callee.

## v0.9.0 — code context at build time: a code graph and grep together, and a log of what they missed

**In short.** A new command, `core/context.py`, answers "what else does this
change touch?" before the agent changes code. It merges an optional code
graph, `git grep` and a few rules. It runs only when the agent calls it:
before it changes code, or while you brainstorm or plan and the answer turns
on what already exists. No hook runs it.

**What changed.**
- `core/context.py` has five questions: `callers`, `importers`, `tests`,
  `reach` and `grep`. Each answer labels every file: both, graph only, grep
  only, or the rule that named it.
- The code graph is Code Review Graph, PyPI `code-review-graph`, pinned at
  2.3.9. It is optional, like frame-jack: without it the answers come from
  `git grep` and the rules.
- It runs only when invoked. No hook calls it, nothing builds an index at
  session start, and nothing refreshes in the background.
- In a window, the first query builds that window's index. Every later query
  updates it first, inside one 90 second budget. A build that fails is not
  retried until `rebuild`.
- Four rules ship for the links neither source sees: `python -m X`, template
  placeholders, Python path joins, and a shell script running the Python file
  beside it. Each came from a real miss in a trial.
- A deployment's own rules live in `vault/context-rules.json`. Rules only add
  candidates, and each one has its own test.
- Promote now compares what the window changed, and the tests that failed in
  its gate runs, with what its queries named. Anything left is a miss, logged
  in `state/code-context/misses.jsonl`.
- The edit-time hook `core/code-context.py` is gone from
  `.claude/settings.json`. The file stays one release as a no-op, so a copy of
  the hook left in a local settings file cannot block edits.
- `recall.ruff` is no longer read. The Bash guard refuses `code-review-graph`
  run directly: `core/context.py` is its only caller.
- Measured on a 283-file target: the first index build took 1.6 s, an
  update and query after a 4-file edit 0.9 s, and a median `reach` 0.8 s. An
  index is about 40 MB.
- On the trial's own questions, the merged answer's recall was at least the
  graph's on every one the graph answers. Shell, template and `-m` edges went
  from 0 of 15 to 15 of 15. The two text questions run on grep alone: one
  found all 11 files, the other 2 of 10, because most of its answer lies
  outside the target.
- Precision fell where grep adds noise, which is why every file carries its
  label.

**What you will see.**
- Doctor has a new line: `NOTE code context: no code graph configured`. The
  graph is optional, and the line says so.
- The promote block's record paragraph ends with one more line, starting
  `Code context:`. It names files no query named, or says every one was.
- When a kind of miss repeats, the agent may add a rule and tells you in one
  line: `Added code-context rule <name>: <why>; its test passes.`

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.8.0 -> 0.9.0; doctor OK.` The
update installs nothing for the graph. Only if you want it, install Code
Review Graph 2.3.9 once per machine, in its own virtual environment. Then paste the `context:` block into `config.yaml`. README "Code
context" has every step, and the commands of the tool never to run.

**How to tell you have it.** `cat VERSION` prints `0.9.0`.
`python3 core/context.py rules --check` ends
`4 rules, 0 fail`. `core/doctor.sh` prints a `code context` line.

## v0.8.0 — frame-jack, a switch for the AMI

**In short.** A new switch, `/frame-jack on`, `off` and `status`, runs a small
local decision model on this machine: the AMI (Artificial Machine
Intelligence). In this release it runs in shadow mode only: it asks, logs, and never
acts. Until you switch it on, nothing runs.

**What changed.**
- The AMI is Strands Decider 2B. It answers yes/no questions with a
  confidence, and it cannot write text.
- Before a full test-suite run during a build, it asks whether a targeted run
  would do (`ami.ask_suite`, on by default).
- It can also ask, before each Bash call the guard allowed, whether the
  command is destructive (`ami.ask_destructive`). That question is off by
  default: its precision measured 0.36, and the guard's own rules already deny
  the destructive cases. Off means no inference and no row.
- The evidence run, `core/gates.sh`, is never asked. The AMI never grants a
  call and never replaces a deny.
- Acting was promised only past a bar set in advance. For the destructive
  question, the bar is recall 0.95, precision 0.60 and Brier 0.15. It
  measured 1.00, 0.36 and 0.054, on four positives.
- For the suite question, the bar is accuracy 0.85 with at most 0.05 unsafe
  "targeted" answers. It measured 0.78 and 0.068. Latency met its bar of a
  400 ms median: 245 ms on MPS, 60 ms on MLX.
- So both questions stay in shadow mode, and naming one under `ami.enforce` is
  a doctor MISSING. With the switch off, the daemon down or the laptop on
  battery, nothing is skipped.
- MLX is the default device on Apple silicon (`ami.device` may be left out).
  Two questions at once crashed the MPS daemon in the lab, twice. MLX queued
  four callers at a 149 ms p99 in the same 5.2 GB.
- `mps` stays selectable, and doctor prints a NOTE naming the crash when it is
  configured. A lock in the client keeps one deployment's windows from
  overlapping, and that lock is what keeps the daemon alive.
- `core/frame-jack.py` is the switch, and `core/ami-daemon.py` supervises
  serve. A pipe ties serve to its supervisor, so killing the supervisor stops
  serve too. The supervisor checks the power source every 30 seconds.
- The AMI tier sits inside `core/guard-bash.py`, after the deterministic
  checks, under a hard deadline. Three failures in a row pause it for five
  minutes in that session.
- `core/ami-hook.py outcome` runs after each Bash call, on success and on
  failure. It writes the real outcome beside the AMI's answer. Both hook
  lines carry a 5 second timeout.
- No AMI write waits on its lock past the hook's budget. A row or a count that
  would have is skipped, and the board is drawn all the same.
- Two guard rules are new. Writes and removals under `state/ami/` from the
  Bash tool are denied. The agent may switch the AMI on or off only after your
  own message says `frame-jack on` or `frame-jack off`.
- `leaselib.py board-json` gains an `ami` key. It reads two small files and
  makes one 100 ms port probe, with no config, no bash and no git.
- `core/doctor.sh` gains a `frame-jack` block: the config, the executable, the
  weights, the daemon, and a second daemon on the machine.

**What you will see.**
- Before the first `/frame-jack on`, doctor has one new line: `NOTE
  frame-jack: no ami: block in config.yaml`. The AMI is optional, and the line
  says so.
- Every Bash call starts one more small hook, `core/ami-hook.py outcome`. With
  the switch off it is a python3 start and one stat: 17.6 ms measured.
- Once switched on, the lease board gains one line: `AMI on · shadow (logs,
  never acts)`, with counts. Other lines say `AMI off`, `AMI paused on
  battery`, or that the daemon is down.
- `/frame-jack status` prints the long form: the daemon, its memory, and the
  commands it would have asked you about.
- When you ask for the AMI in other words, the agent asks you to type
  `/frame-jack on`. The guard refuses the switch until your own message says
  it.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.7.5 -> 0.8.0; doctor OK.` The
update downloads nothing for the AMI
and starts nothing; `state/ami/` appears at the first `/frame-jack on`. Then,
only if you want the AMI, install it once per machine:
- Make a Python 3.12 virtual environment with `uv venv --python 3.12`.
  Install the git clone with its `[mlx]` extra and `mlx-lm<0.33`.
- Paste the `ami:` block into `config.yaml`, with the executable's absolute
  path. The first start downloads about 4.8 GB of weights.
- On a laptop behind a corporate proxy, copy them by hand instead and set
  `offline: true`. README "Frame-jack (the AMI)" has every step, and the
  tarball that carries the shared blobs. That copy is not yet run there.

**How to tell you have it.** `cat VERSION` prints `0.8.0`.
`python3 core/frame-jack.py status` prints
`frame-jack: off — never switched on in this deployment`. `core/doctor.sh`
prints a `frame-jack` line. After `/frame-jack on`, the band shows `AMI on`
within about half a minute.

## v0.7.5 — the lease board stays drawn when git is slow

**In short.** On a deployment with several nested repos, the board failed to
draw on about one prompt in three. It named a different window each time,
because the cause was the clock, not the repository. The board now checks
swept windows from a cache, draws what it checked in time, and says what it did
not check. Thanks to a Daedalus deployment on a second machine, which reported
it with the cause.

**What went wrong.**
- The prompt hook gave the board 2 seconds, enforced with an alarm. The alarm's
  error was caught as a failed git call, so the board said it "cannot tell"
  whether whichever window was being checked had unpromoted work, and drew
  nothing else.
- Where the alarm landed decided the damage. Sometimes the board vanished; and
  sometimes a swept window's waiting work was left off with no sentence at all.
- Every swept window was checked again in every repo on every prompt, with
  three git processes each. A reclaimed window was checked forever.

**What changed.**
- Each swept window's answer is kept in `state/leases/unpromoted.cache`, keyed
  on its branch tip and the trunk tip. It is recomputed only when one of them
  moves. In steady state the board runs one git process per repo.
- Commands that act on the answer (`create`, `claim`, deleting a window's
  work) never read the cache. They check git as before.
- A reclaimed window stops costing anything: reclaim records what it proved,
  and a later commit in its worktree still shows.
- A commit with an empty message now counts as unpromoted work. Before, a new
  window could be handed a number over it.

**What you will see.**
- A window not checked in time reads "not checked for unpromoted work this
  time". The next prompt finishes the check, or `core/lease.sh list` checks
  now.
- A window with work already found reads "at least N unpromoted commits
  waiting" until every repo is checked.
- A repo whose lease branches could not be listed has its own line, naming
  `core/lease.sh list`.
- A git error on one window is on that window's line, with the command that
  shows the error. The other windows still draw.
- While a window is being made or swept, the board says the lock is busy and
  draws at the next prompt; `core/lease.sh list` waits for it. Before, it was
  silent.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.7.4 -> 0.7.5; doctor OK.` There
is no migration: the cache is made by the first board that needs it.

**How to tell you have it.** `cat VERSION` prints `0.7.5`. `daedalus version`
prints `Daedalus 0.7.5`. With a swept window open, `state/leases/` holds
`unpromoted.cache` after the next prompt.

## v0.7.4 — every session can close and commit, and the update keeps a deployment's own vault

**In short.** A session that started while an upgrade was pending holds no
window, by design. It can now close like any other session. It gets its
session-log number, takes the pen when no live session holds it, writes
`hot.md` and commits the vault. Thanks to a Daedalus deployment on a second
machine, which reported the stall this came from. Every close now commits the
vault, and a pen left by a session that has ended moves on by itself. And a
home that keeps its vault in its own repository now takes releases by
merging.

**What went wrong.**
- No window opens while the upgrade is pending, so that its safety copy reads
  `target/` before anything there changes. That rule is right, and it stays.
- But a session started in that state could not close. `core/lease.sh log`
  refused it, so it counted the files to pick a number, the race the
  reservation exists to prevent.
- It could not write `hot.md` or take the pen, because only a window could. So
  the next session read stale state first.
- `core/vault-commit.sh` refused it too. The session log and the proposals it
  wrote were left uncommitted.
- The stall on that deployment ran across three sessions. A session that
  cannot close loses its reasoning exactly when it matters most.

**What changed.**
- `core/lease.sh log` reserves a number for a session holding no window. It
  uses the same lock and the same counter as windows, kept in
  `state/leases/unwindowed.json`.
- When that session later holds a window, the number moves with it. It is
  never told two numbers.
- `core/lease.sh prime take` works from a session holding no window when no
  live session holds the pen. It never takes the pen from a live or quiet
  holder, whatever reason is given.
- Taking the pen that way writes only `state/leases/prime.json` and runs no
  git. It makes no window, branch or worktree.
- The pen gives such a session the vault, not a tree. Until the upgrade
  finishes, and until it claims a window, `target/` and `worktrees/` stay
  closed to it.
- So promote waits until the upgrade finishes. `core/promote.sh NN --clean`
  still removes pushed scratch, as before.
- Every message such a session is shown names a command that works for it. A
  test runs each one from that state.

**What you will see.**
- A session started in a terminal while the upgrade is pending is told its
  session log at start; a headless one, as at any other time, is given no
  number at start. It is also told that `core/lease.sh prime take` gives it the pen at
  the close.
- The no-window sentence ends with the close: `core/lease.sh log`, then
  `core/lease.sh prime take` when no live session holds the pen.
- When a live session holds the pen, the refusal names it. It also says the
  operator can commit the vault from their own shell.
- `core/vault-commit.sh` takes a pen whose holder has ended and commits. When
  a live session holds the pen, it says so in one line.
- The board says when the pen is held by a session holding no window.

**The close commits.**
- Before, `core/close.sh` committed the vault only with `--commit`, and the
  brief never taught that flag. So a normal close left the session log and
  proposals uncommitted.
- And a pen left by a session that had ended stayed with it. Every later
  commit was refused until someone ran `core/lease.sh prime take`.
- Now `core/close.sh` commits the vault after the session is stored.
  `--no-commit` skips the commit.
- When another live session holds the pen, the close says so in one line and
  succeeds. That session's next commit carries this one's files.
- When the pen's holder has ended, the next terminal session's close takes the
  pen and commits. It never takes the pen from a live or quiet session.
- A headless session, or a session started by the direct-call launcher, never
  takes the pen.
- If the session is stored but the commit fails, the close exits 4. Fix what
  its line names, then run `core/vault-commit.sh`; do not close again.
- If your deployment keeps its own close skill: `core/close.sh` commits the
  vault now; `--commit` is no longer needed.

**A home that keeps its vault in its own repository.**
- Some homes commit `vault/` in the home repository and push it to a remote
  of their own. `daedalus update` refused such a home.
- The refusal listed every vault file, hundreds of paths in one sentence. It
  also advised undoing them with git, which would have destroyed the vault.
- Now such a home takes the release by merging. Its history, its vault and
  its own remote are kept; nothing is reset.
- One local commit first sets the release's files, after the usual move of
  local edits into the local layer. Then the release merges into the branch.
- `.gitignore` becomes the release's copy plus a marked block of the home's
  own lines. Later releases never conflict there.
- `core/vault-commit.sh` no longer refuses a vault that `.gitignore` ignores
  and then un-ignores with a `!vault/` line. It read git's report of that
  negation as "ignored", so every commit in such a home stopped there.
- If anything fails, the update puts back only what it wrote. A vault edit
  made meanwhile is kept.
- `core/upgrade.py --rollback` refuses such a home in one line: its last step
  would take the vault out of the working tree.
- Every result now leads the output on its own first line. A refusal is one
  line starting `Not updated:`, naming at most three paths.
- Past three paths, the full list is in `state/update-refused.txt`. No
  refusal tells you to undo, reset, abort or delete anything.

**How to take it.** Close every Daedalus window, then type `daedalus update`
in a terminal. It prints `Daedalus updated 0.7.3 -> 0.7.4; doctor OK.` There
is no migration: the upgrade only writes the new stamp. A home older than
v0.7.3 has no `daedalus` command yet; type this one line instead, with your
home's path in place of `~/daedalus`:

```
(f="$(mktemp)" && { git -C ~/daedalus fetch -q https://github.com/lpelty/daedalus.git main && git -C ~/daedalus show FETCH_HEAD:core/update.py >"$f"; } 2>/dev/null || { echo "Not updated: could not fetch the update from github.com/lpelty/daedalus. Nothing in this home was changed." >&2; rm -f "$f"; exit 1; }; python3 "$f" update --home ~/daedalus; s=$?; rm -f "$f"; exit $s)
```

It replaces the earlier first-update line, which auto mode refused. It saves
the fetched update to a temporary file, runs it, and removes the file.

**How to tell you have it.** `cat VERSION` prints `0.7.4`. `daedalus version`
prints `Daedalus 0.7.4`, with the home, the remote and the tag. `core/doctor.sh`
prints `OK       version: 0.7.4`.

## v0.7.3 — one command updates Daedalus, and the upgrade no longer outgrows its safety copy

**In short.** Taking a release is one command now. Close every Daedalus
window, then type `daedalus update` in a terminal. It prints one line. Local
edits no longer live in tracked files, so a release never conflicts with
them. And the upgrade that stopped at every session start can finish. Thanks
to a Daedalus deployment on a second machine, which reported each of these
problems with its evidence.

**What went wrong.**
- Taking v0.7.1 and v0.7.2 on that deployment took an eight-step recipe and a
  merge conflict in `.claude/settings.json`. A second agent on the machine had
  to resolve it.
- The deployment kept local edits inside tracked files: in `CLAUDE.md`, and
  in `.claude/settings.json`, whose `Edit(/CLAUDE.md)` deny it had removed.
  Every release that touched either file conflicted.
- The 0.7.2 upgrade stopped at every session start. Its safety copy came to
  about 15 GB, over a limit already raised to 10000 MB.
- Most of that was one rebuildable Python environment, `engine/.venv`, copied
  five times. Two of the copies sat in promote scratch worktrees whose push
  had already happened.
- A session open during the background copy was told only to restart. The
  real reason, the size limit, showed only on the board.
- The stop asked for cleanup. The supported cleanup, `core/promote.sh NN
  --clean`, needed the prime window. No window opens until the upgrade
  finishes. The operator removed the worktrees by hand.
- After a promote, a window's IMPLEMENTED claim had no evidence the Stop hook
  accepted. It refused the promotion's run, and a fresh `core/gates.sh` run had
  nothing left to review.

**What changed.**
- `daedalus update` (`core/update.py`) takes a release in one step. It
  refuses while a session is live. It picks the remote with the release's
  address, fetches, and moves to the release.
- It then runs the upgrade at once and doctor quietly, and prints one line.
  `daedalus version` is the only other verb.
- `core/setup.sh` and the upgrade install the command as
  `~/.local/bin/daedalus`. They never overwrite a file they did not write.
- The local layer. Local permission rules and hooks go in
  `.claude/settings.local.json`, and local brief text in `CLAUDE.local.md`.
  Both are gitignored, and Claude Code loads both.
- `boundary.edit_brief` in `config.yaml` decides whether Daedalus may write
  `CLAUDE.local.md`. It is false by default. `CLAUDE.md` stays denied always.
- The update moves a home's local edits into the local layer. It first keeps
  a backup branch, `local/before-update-<stamp>`, and copies under
  `state/update-backups/<stamp>/`. Then it resets the tracked files to the
  release.
- A confirm that pushed removes its promotion's scratch worktrees and keeps
  the records. The upgrade removes every pushed promotion's scratch before it
  estimates its copy.
- The safety copy skips a `.venv` or `node_modules` directory that a lockfile
  beside it rebuilds. The manifest names each one with its rebuild command,
  such as `uv sync --frozen`.
- `core/promote.sh NN --clean` also runs from a session holding no window, or
  from a shell, for pushed promotions. Every command an upgrade stop names is
  tested to work in the state that stop leaves.
- When the upgrade has stopped, the session start, the board and the Stop hook
  all say that stop's own sentence.
- A window's claim may cite its promotion's gate run once that promotion was
  confirmed and pushed. The window must have no new work since.
- `mods/lease-board/tsconfig.json` is gitignored. Claude Code writes it when
  the mod loads.

**What you will see.**
- `daedalus update` prints `Daedalus updated 0.7.2 -> 0.7.3; doctor OK.` Run
  again, it prints `Daedalus is up to date (0.7.3).`
- When it moved local edits, the same line names the backup branch and the
  copies.
- When it wrote `config.yaml`, it says so. Each window then re-runs
  `core/gates.sh` before its next claim, because the gates' record pins
  `config.yaml`.
- A home that had removed the CLAUDE.md deny now has `boundary.edit_brief:
  true`. Its own brief lines are in `CLAUDE.local.md`, under a header naming
  the date and the backup.
- A release rule or brief line the deployment removed or reworded is reported
  in one sentence. Nothing is dropped silently.
- An upgrade stop in a terminal ends "then run daedalus update again". Over
  the size limit, it names the three largest parts.
- `core/doctor.sh` adds lines for the brief, the command, local edits in
  tracked files, and leftover promote scratch.
- The upgrade says one line for the command it installed, then `Upgrade to
  0.7.3: complete.`

**The first update.** A home older than v0.7.3 has no `daedalus` command yet.
This one time takes a longer line. Close every Daedalus window, then type it
in a terminal, with your home's path in place of `~/daedalus`:

```
(f="$(mktemp)" && { git -C ~/daedalus fetch -q https://github.com/lpelty/daedalus.git main && git -C ~/daedalus show FETCH_HEAD:core/update.py >"$f"; } 2>/dev/null || { echo "Not updated: could not fetch the update from github.com/lpelty/daedalus. Nothing in this home was changed." >&2; rm -f "$f"; exit 1; }; python3 "$f" update --home ~/daedalus; s=$?; rm -f "$f"; exit $s)
```

It names no remote, so it works whatever your remotes are called. Or say to
an agent on that machine: "Close every Daedalus window, then run the
first-update line from the Daedalus README's Upgrading section on GitHub,
github.com/lpelty/daedalus." Every later release is just `daedalus update`.
README, "Upgrading", says the same.

**How to tell you have it.** `cat VERSION` prints `0.7.3`. `daedalus version`
prints `Daedalus 0.7.3 (home <your home>, remote <its name>, tag v0.7.3)`.
`core/doctor.sh` prints `OK       version: 0.7.3` and `OK       command:
daedalus on PATH (~/.local/bin/daedalus)`.

## v0.7.2 — the vault index rebuilds itself; deleting a window's work and keeping the journal are the agent's again

**In short.** Since v0.7.0 you had to remember or run some routine steps
yourself. They are Daedalus's job again. The document index now follows the
vault without anyone running it. When you say yes to deleting a window's
work, the window runs the delete itself. SOUL.md, Daedalus's own journal, is
no longer locked against it. CLAUDE.md stays locked. A deployment that
unlocked it is told how to let auto mode allow the edit.

**What went wrong.**
- Document recall reads an index of the vault. Nothing in Daedalus rebuilt
  that index; only `python3 core/vault-search.py index`, run by hand, did. So
  recall drifted behind the vault until the prime remembered. Only doctor
  said so (a deployment on another machine, 2026-10-14).
- Deleting a window's work ended with a shell line for you to run. Auto
  mode's classifier refused `core/lease.sh release 02 --remove --force` as
  "[Interfere With Workloads]". CLAUDE.md then told the window to hand you
  the line. A builder that hands you shell lines to run is not how Daedalus
  works.
- The tracked settings denied every edit to SOUL.md. It is this instance's
  journal, not distribution code.
- On a deployment that had chosen to unlock CLAUDE.md, auto mode still
  refused the edit as "[Self-Modification]".
- The vault commit at every close was the other such step. It was fixed on
  2026-10-14 (e1b349e) and is not changed here.

**What changed.**
- `core/vault-commit.sh` starts a rebuild of the index in the background
  after every commit the prime makes. The commit never waits for it. A
  rebuild that fails never fails the commit. The prime's session start does
  the same when the index is older than the vault.
- The tracked `.claude/settings.json` allows `Bash(core/lease.sh release:*)`.
  Claude Code resolves that rule before the classifier, so the classifier no
  longer stands in the way. Daedalus's own check decides instead.
  `core/guard-bash.py` refuses the delete unless three things hold. The
  report was shown in this session. Your yes followed it in the session's
  transcript. And the window's work has not changed since the report.
- `Edit(/SOUL.md)` leaves the tracked deny list. `Edit(/CLAUDE.md)` stays:
  CLAUDE.md is distribution code, and promote and the launcher refuse a tree
  where it differs from HEAD.

**What you will see.**
- After each vault commit the prime makes: "document index: rebuilding in
  the background (state/recall-index.log)".
- At the prime's start, when the index is older than the vault: "The
  document index is older than the vault; rebuilding it in the background
  (state/recall-index.log)." Other windows say nothing.
- `core/doctor.sh` adds a line under document recall: "last automatic index
  <time> by <who>: indexed=N purged=M", or that it failed and where the
  engine's output is.
- "Release window 2 and delete its work": the window runs `core/lease.sh
  unpromoted 02` and repeats its report. The report ends with "Say yes to
  delete window 02's work." You may ask about it first. After your yes, the
  window runs the delete itself.
- `core/doctor.sh` prints `OK       CLAUDE.md: edits denied (<file>)`. When no
  deny rule covers CLAUDE.md, it prints a NOTE pointing at the README
  instead.
- The first session after the pull says one line, "Upgrade to 0.7.2:
  complete.", and that is all the upgrade does. No state changes shape and
  no file moves.

**If you let Daedalus edit its own CLAUDE.md.** The distribution cannot
ship auto mode's exception for you. The classifier reads `autoMode` only from
`~/.claude/settings.json` or managed settings, never from a project's
`.claude/settings*.json`. So add this once to `~/.claude/settings.json`,
keeping `"$defaults"`, with your home's path in place of `/path/to/daedalus`:

```json
{
  "autoMode": {
    "allow": [
      "$defaults",
      "Editing CLAUDE.md in the Daedalus home at /path/to/daedalus when the operator asked for that change in this session: the deployment chose to let Daedalus maintain its own brief."
    ]
  }
}
```

Without it, a message from you in the session asking for the edit clears
the refusal on its own. README, "Letting Daedalus edit its own CLAUDE.md",
says the same.

**How to take it.** `git pull --ff-only` in the Daedalus home, then a new
session. Close and reopen any session that was open through the pull; it is
still running the old hooks. This release changes `CLAUDE.md` and
`.claude/settings.json`. If your deployment carries local changes to either,
the pull refuses. Then run `git stash push -m local-changes CLAUDE.md
.claude/settings.json && git pull --ff-only && git stash pop`. Resolve what
conflicts (expect the "Release window 2" row), and commit the result on your
local branch. README, "Upgrading", says the same.

**How to tell you have it.** `cat VERSION` prints `0.7.2`. `git describe
--tags --abbrev=0` prints `v0.7.2`. `core/doctor.sh` prints `OK       version:
0.7.2` and `OK       upgrade: state/upgraded-to 0.7.2`. It also prints the
CLAUDE.md line and, once a rebuild has run, the last automatic index.

### In detail

#### The document index rebuilds itself

**In short.** The document index — what `recall.vault-index` builds for
document recall — waited for someone to run `python3 core/vault-search.py
index`. Nothing in Daedalus ran it, so recall drifted behind the vault until
the prime remembered. The prime was told only when someone ran doctor (a
deployment on another machine, 2026-10-14). Now the index follows the vault
by itself, and doctor says when it last ran.

**What you will see.**
- After every vault commit the prime makes — each close with `--commit`, and
  `core/vault-commit.sh` by hand — one line: "document index: rebuilding in
  the background (state/recall-index.log)". The commit never waits for the
  rebuild, and a rebuild that fails never fails the commit: the line says
  so, and `python3 core/vault-search.py index` runs one by hand.
- At the start of the window that holds the pen, when the index is older
  than the vault: "The document index is older than the vault; rebuilding it
  in the background (state/recall-index.log)." A fresh index, another
  window, a visitor and a compaction say nothing. A start that spent its
  time on worktree checkouts skips the rebuild rather than running late; the
  next commit kicks it.
- A rebuild kicked while one is running: "a rebuild is already running; it
  will run again when done". It does, once, so a document changed during a
  run is indexed by the run that follows.
- `state/recall-index.log` holds the last run: `started <time> by
  vault-commit`, then `finished <time> indexed=N purged=M`, or the engine's
  last lines and `failed <time>: <reason>`.
- `core/doctor.sh` prints one more line under document recall: "last
  automatic index <time> by <who>: indexed=N purged=M"; or that it FAILED
  and where the engine's output is; or that a run is still going; or that
  one started and did not finish (killed, or the machine slept), and that
  the next vault commit or the prime's next session start runs it again.
- A reindex engine that runs past two minutes is stopped as a whole, so
  nothing of it keeps writing the store after the lock is released.

A deployment without a `recall:` block sees none of this; `core/doctor.sh`
still says "document recall: reindex command unconfigured".

**How to take it.** `git pull --ff-only` in the Daedalus home, then a new
session. The upgrade at the first start only stamps `0.7.2`; a session
already open keeps the old hooks until it is restarted. This release also
touches `CLAUDE.md` and `.claude/settings.json`, so a deployment with local
changes to them takes it by the stash–pull–pop recipe in "How to take it"
above.

#### The routine steps run by the agent, not the operator

**In short.** Deleting a window's work no longer ends with a shell line for
you to run: the agent repeats the report, you say yes, the agent runs the
delete. SOUL.md is yours again — the distribution stops denying edits to it
and will never change it. A deployment that chose to let Daedalus edit its
own CLAUDE.md is told exactly where auto mode's exception goes, and doctor
says when that choice is in force. The vault commit at every close was
already fixed on 2026-10-14. A deployment with local changes to the tracked
files gets a recipe for taking this release.

Taken as v0.7.2 says above: `git pull --ff-only` in the Daedalus home, then
a new session.

**What you will see.**
- "Release window 2 and delete its work" is report, yes, delete. The window
  runs `core/lease.sh unpromoted 02`, which now ends with one line: "Say yes
  to delete window 02's work." You may ask about it first; the window answers
  and ends its answer with that line. When you say yes, the window runs
  `core/lease.sh release 02 --remove --force --operator-said "<your reply>"`
  itself. That command is allowed in the tracked `.claude/settings.json`
  (`Bash(core/lease.sh release:*)`). Claude Code resolves such a rule before
  auto mode's classifier (permissions and permission-modes docs, read
  2026-10-15 on 2.1.300). So the classifier's "[Interfere With Workloads]"
  refusal of 2026-10-14 no longer stands in the way. What decides is now
  Daedalus's own check, in every permission mode. `core/guard-bash.py`
  refuses the command before it runs unless three things hold. The report
  was shown in this session. Your yes followed its line in the session's own
  transcript (the same recorded-yes machinery promote uses). And the window's
  work is still what the report named: a fingerprint of its commits and
  files, so a change since the report means asking again. The guard sees the
  command behind any wrapper (`timeout`, `nice`, `sudo`, `bash -c` …) and
  from any path, and refuses it outright through `xargs`. `core/leaselib.py`
  refuses the same for every form the guard cannot read (`python3
  core/leaselib.py release …`, a copied script). A reply of several lines or
  with a `$` in it cannot ride on the command: the window asks for a one-word
  yes. What authorised a deletion is written to `state/evidence/deletions/`
  first. Your own shell is unchanged. In `promote.confirm: tty` mode the
  window hands you the line to paste, as promote does there. The sentence
  "If the permission system refuses that command, say so and give the
  operator the line to run" is gone from CLAUDE.md.
- One caveat: a user-scope `autoMode.classifyAllShell: true` suspends every
  Bash allow rule in auto mode, so on such a deployment the classifier is
  back in front of the delete; `core/doctor.sh` prints a NOTE when it finds
  that set.
- SOUL.md leaves the tracked deny list. It is this instance's own journal:
  `core/distcheck.py` does not cover it, and promote does not read it. The
  distribution will not change it in any later release; a test pins the
  tracked file to its seed. A release that touched it would make `git pull
  --ff-only` refuse on every deployment whose instance has written in it. The identity leak scan reads it from HEAD, never the working file.
  CLAUDE.md stays denied: it is distribution code, and promote and the
  launcher refuse a tree whose CLAUDE.md differs from HEAD.
- A deployment that chooses to let Daedalus edit its own CLAUDE.md met auto
  mode's "[Self-Modification]" refusal on 2026-10-14. The distribution cannot
  give it the exception: the classifier reads `autoMode` only from
  `~/.claude/settings.json`, managed settings or `--settings`. It never reads
  it from a project's `.claude/settings*.json`. README, "Letting Daedalus
  edit its own CLAUDE.md", gives the one-off `autoMode.allow` entry for the
  user file (keeping `"$defaults"`). It also notes that a message asking for
  the edit in the session clears the soft deny on its own. `core/doctor.sh` prints `OK       CLAUDE.md: edits denied (<file>)`
  naming the project, local or user file whose rule covers it, and a NOTE
  pointing at that README section when none does.
- The vault commit at every close was shipped on 2026-10-14 (e1b349e):
  `core/close.sh --commit` runs `core/vault-commit.sh` after a successful
  capture (`core/tests/test_close.bats:211`), and `vault-commit.sh` commits
  a vault the home repository tracks (`core/tests/test_vault_commit.bats:90`,
  `:114`, `:140`). Nothing new here.
- **Taking this release on a deployment with local changes.** This release
  edits `CLAUDE.md` (the "Release window 2" row) and `.claude/settings.json`
  (the permissions block). The deployment this work is for carries local
  changes to both. There `git pull --ff-only` refuses with "Your local
  changes to the following files would be overwritten". Keep the local changes on the deployment's own branch and
  bring the release under them: `git stash push -m local-changes CLAUDE.md
  .claude/settings.json && git pull --ff-only && git stash pop`, resolve what
  conflicts (expect the "Release window 2" row), and commit the result on
  the local branch. README, "Upgrading", says the same.
- One fact the check below turned up, worth knowing on a deployment: a
  project's `permissions.allow` rules apply only in a folder whose workspace
  trust dialog was accepted, and `claude -p` never shows that dialog
  (permissions doc, "Project allow rules and workspace trust"). The Daedalus
  home is such a folder once its first interactive session opened there, so
  the tracked rule applies in every window. A scratch folder a script made
  is not. So the check carries the rule through `--settings` (the same scope
  as `~/.claude/settings.json`). One run keeps the rule in the scratch
  project file instead, to show the difference (run 2a).
- The headless check of the allow rule (`core/tests/automode-allow-rule.sh`,
  run once in validation on 2026-10-15 from the real config home, whose
  user-scope rules name no `lease.sh`; not part of the suite, since it needs
  a logged-in `claude`, the network and a model call), verbatim:

  $ core/tests/automode-allow-rule.sh   (claude 2.1.300, 2026-10-15)
  config home: the real one (~/.claude) — a scratch CLAUDE_CONFIG_DIR is not logged in; the user-scope settings there (permissions.allow, autoMode) were in effect
  effective auto-mode config saved: <scratch>/auto-mode-config.json (81974 bytes); lease.sh named in it: 0 line(s)
  run1-default-no-rule: exit 0 — ran: no — denied: no — stdout: The command to release window 02 needs your approval before it can run. I ran it once as the project instructions specify, and the harness blocked it pending permission.  Nothing was changed. Approve 
  run2a-default-project-rule-untrusted: exit 0 — ran: no — denied: no — stdout: The release command for window 02 was blocked pending approval, so it did not run. Approve `core/lease.sh release 02 --remove --force` and I will run it once as instructed. 
  run2b-default-settings-rule: exit 0 — ran: yes (release 02 --remove --force ) — denied: no — stdout: Window 02 released. Its worktree and branch are deleted. 
  run3-auto-rule-and-soft-deny: exit 0 — ran: yes (release 02 --remove --force ) — denied: no — stdout: Window 02 released. Its worktree and branch are deleted. 
  run4-auto-soft-deny-alone: exit 0 — ran: no — denied: yes ({"command": "core/lease.sh release 02 --remove --force", "reason": "The server-side auto mode classifier judged this action dangerous (it gave no explanation)"} ) — stdout: The release command was blocked by the auto mode permission classifier, so window 02 was not tidied.  The project CLAUDE.md specifies running exactly this once with nothing else, so I did not attempt 
  results: <scratch>
  claude -p processes left: none
  RESULT: the allow rule is resolved before the classifier (runs 2b and 3 ran, run 4 was denied, run 1 did not run)
  exit 0

- Tests: `test_boundary.bats` (the exact allow list, the deny members),
  `test_distribution_integrity.bats` (the SOUL.md seed pin),
  `test_identity.bats` (both scans over HEAD; the CLAUDE.md and README
  pins), `test_lease.bats` (the report, the witness marker, the fingerprint,
  the gate and the record), `test_guard_bash.bats` (the early refusal behind
  every wrapper; the docs' wrapper list pinned), `test_doctor.bats` (the
  CLAUDE.md and classifyAllShell lines).

## v0.7.1 — the lease board appears again on Claude Code 2.1.300

**In short.** On Claude Code 2.1.300 the lease board never appeared above
the prompt. The mod drew it every 2 seconds, and Claude Code refused the
drawing every time. It appears again. Nothing else changes.

**What went wrong.** The band the mod draws has to hold Claude Code's own
drawing too: the spinner and the notices. So the mod asks Claude Code for
that drawing and puts it in the tree it returns. It put the drawing inside
the same Box it then sized to the band's width. The width is there so that
each window's line cuts off at the band's edge, not at the terminal's.
Claude Code 2.1.300 refuses that shape. In `claude --debug`, every draw
said: `ui.render (AbovePrompt): a hook returned a tree that does not validate
(engine node under a Box with prop "width"); drawing the engine's own`. So
Claude Code drew its own band, and the board was never on screen. The mod's
tests had not caught it. They answered the mod's request for Claude Code's
drawing with a plain line of text, not the reference
(`{ type: 'engine', ref }`) Claude Code really hands back, so nothing
exercised the real shape. A Daedalus deployment on a second machine found
this on 2026-10-15 with `claude --debug`. On 2.1.296, which the board was
built against, the shape was accepted.

**What changed.** The window lines now sit in an inner Box that carries the
width. Claude Code's own drawing sits beside that Box, inside an outer Box
with no width. That is the shape the mods interface page sanctions: "place
it in a Box beside elements of your own". The lines still cut off at the
band's edge. The mod's tests now answer with the reference Claude Code really
hands back. They check that exactly one Box carries the width, that the
reference is not under it, and that the tree validates on 2.1.300. `claude
plugin validate` and `claude plugin test` pass (24 tests). In a live
`claude --debug` session on 2.1.300, every draw was accepted where every one
was refused before. The mod's own version is 0.1.1, and its README says it is
tested with 2.1.300. Two board reads at startup that exited 1 on the laptop
where this was found did not reproduce here and are not changed.

**What you will see.** The board above the prompt in every window: one line
per window, yours first, refreshed every 2 seconds, as the 2026-10-11 entry
under v0.7.0 describes. On 2.1.300 you saw Claude Code's plain band and no
board; now you see the board. The first session after the pull says one
line, "Upgrade to 0.7.1: complete.", and that is all the upgrade does. No
state changes shape, no file moves, and no target checkout is touched. It
first takes its usual safety copy of anything new in `target/` and runs its
usual check for unfinished work there. If that check stops it, the board
says why and what to do, as for v0.7.0.

**How to take it.** `git pull --ff-only` in the Daedalus home, then a new
session. The mod loads in place from `mods/lease-board/`, so there is no
`claude plugin install` to run again. A window that is already open keeps
the old drawing until it is restarted or runs `/reload-plugins`. A
deployment that never installed the board runs the two install commands
from the 2026-10-11 entry under v0.7.0, once. Mods need Claude Code 2.1.287
or later; this is tested with 2.1.300.

**How to tell you have it.** `cat VERSION` prints `0.7.1`. `git describe
--tags --abbrev=0` prints `v0.7.1`. `core/doctor.sh` prints `OK       version:
0.7.1` and `OK       upgrade: state/upgraded-to 0.7.1`. And the board is on
screen.

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


#### Fixed on trunk after the v0.7.0 tag — 2026-10-13: the deny rules are anchored at the home

- The deny rules in `.claude/settings.json` now read `Edit(/core/**)`, not `Edit(./core/**)`. Claude Code anchors a `/path` rule at the settings file's project, and a `./path` rule at the session's current directory. A shell that changed directory made the old rules match nothing; another deployment saw this and committed them absolute.
- The boundary hook and the bash guard read those rules to know what is distribution code. They now understand all three forms: `/path`, `./path`, and an absolute `//<home>/path`. Before, anything but `./path` silently protected nothing.
- The README's example for a deployment's own deny rules in `.claude/settings.local.json` now shows the absolute `//` form. The single slash it showed is not absolute in Claude Code's rules.
- That example's `Write(...)` line is gone: Claude Code checks file writes against `Edit(path)` rules only and never consults a `Write(path)` rule.

#### Added on trunk after the v0.7.0 tag — 2026-10-13: the Stop hook stops looping; a report-only delete step

Taken the same way as v0.7.0: `git pull --ff-only` in the Daedalus home,
then a new session. VERSION stays 0.7.0, so no upgrade step runs.

**The Stop hook no longer buries a session that was open while the upgrade
waited.** A session started before the upgrade finished holds no window.
None opens for it until the upgrade is done: `create` and `claim` are
refused. Its Stop check used to block every turn with "run `core/lease.sh
create` and then `claim <NN>`", the one thing the release forbids. Claude
Code re-fired the Stop each time: more than 15 times in a row on one
deployment (2026-10-13). Now that session is told once, as a block: "This
session started before the upgrade to 0.7.0 finished, so it holds no window
and none opens for it. Tell the operator to close this session and start a
new one; that start finishes the upgrade." After that it is only a note.
The board above the prompt, `core/lease.sh list`, the per-prompt context
and `lib.sh target_path` say the same sentence in that state. Once the
upgrade is stamped, the ordinary no-window refusal returns, because its
remedy is then possible.

**A re-fired Stop is not blocked again by a check only a restart repairs.**
Claude Code marks the Stop it fires after a blocked one (`stop_hook_active`).
On that Stop, a "Promotion check could not evaluate" reason that no action
of the agent's repairs becomes a note instead of a second block: a missing
comparison base, a tree not known, a marker from before the gate. Everything
the agent can repair still blocks on every Stop: protected files changed,
the gate definition changed, evidence no gate produced, a refusal that names
a command to run.

**`core/lease.sh unpromoted <NN>`** reports what `release <NN> --remove`
would delete, the window's unpromoted commits and uncommitted files, and
deletes nothing. It is now the first step of "release window N and delete
its work" in CLAUDE.md. Before, that step was `release --remove` itself.
Claude Code's auto-mode permission classifier denied it before it ran on
one deployment, and with nothing unpromoted it deletes at once instead of
reporting. The procedure now also says what to do when the permission
system refuses the delete: say so, and give the operator the line to run
with `!`.

**Small.** `core/lease.sh` in a home whose upgrade stamp is absent no longer
prints a shell error about the missing file before its own sentence.

#### Added on trunk after the v0.7.0 tag — 2026-10-14: session logs keep the global counter; the vault commits inside the home repo; the yes may follow a question; a setup step before the gates

**In short.** Session logs go back to one running number per vault,
`YYYY-MM-DD-NNN.md`. The harness hands the number out. A vault that lives
inside the Daedalus home repository can be committed again. You may ask
about a promote before you say yes to it. A `gates_setup:` list in
`config.yaml` builds what the gates need before they run.

- **A setup step before the gates.** Promote tests the merged tree in a
  scratch copy that holds tracked files only. A gate that needs build
  output, such as `engine/.venv`, exits 127 there. Promote then said the
  merge with trunk was what failed, which sent an operator after a merge
  problem that did not exist (2026-10-14). Now `gates_setup:` in
  `config.yaml` lists commands run in the tree under test before the gates,
  in a window's worktree and in the scratch alike. Each is logged and
  recorded in the evidence. A step that fails ends the run INVALID before
  any gate, with the step named. What a step leaves behind must be ignored
  by git, as a virtual environment is. A step that changes what git sees
  also ends the run INVALID, saying so. A gate that exits 127 is now
  reported as unable to start, with `gates_setup:` named as the remedy.
  An example step for a Python harness: `cd engine && uv sync --frozen`.
  `core/doctor.sh` reports the steps it finds.

- **The yes may follow a question.** The confirm used to take a yes only as
  the first reply to the block itself. Any other reply, even a question,
  used the block up. The prime then printed the whole block again, so the
  same long message came back after each reply, several times in one
  afternoon on 2026-10-14. Now the block's first paragraph ends with one
  line: "Say yes to push window 02's work to main." The prime answers your question and ends
  its answer with that line. Your next yes counts. The block is printed
  once, and the line counts only after it. A line followed by anything
  else, even after a tool call, asks that last, and a yes answers that. A
  line for another window does not count.

- **The global counter is back, reserved by the harness.** v0.7.0 named logs
  by window number. The operator ruled on 2026-10-14 that the sequence they navigate
  by stays. The number is now reserved in the lease file under the lease
  lock, at session start and by the new `core/lease.sh log`. No session
  counts the directory, so two windows on one day never share a number. The
  window number lives in the frontmatter only. A v0.7.0 log with a two-digit
  tail is outside the sequence and is not counted. The session start says
  the path: "Your session log for today is vault/sessions/…". The log is
  keyed to the day the session opened. Past midnight it keeps that file, a
  compaction returns the same path, and a start or resume on the new day
  takes the next number. A window swept before its log is written frees
  the number.
- **`core/vault-commit.sh` commits a vault the home repository tracks.** It
  refused every layout but a vault with its own `.git`, while doctor accepted
  a vault absorbed into the home repository. Now it commits in the home
  repository, vault paths only. Other work staged anywhere in that
  repository is refused by name first. So a home that sits inside a larger
  repository never sweeps the operator's staged files into a vault commit.
  The claim report resolves paths against that repository too. A vault
  tracked by neither is refused by name. A tracked vault that an ignore
  rule still matches is refused naming the file and the rule.
- README and `docs/handoff-reverse-caller.md` say the same convention.
- Tests: `core/tests/test_session_log.bats` (new), two nested-vault cases in
  `test_vault_commit.bats`, and the `test_identity` pin on the naming.

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
