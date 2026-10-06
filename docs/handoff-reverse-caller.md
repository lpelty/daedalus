# The reverse caller — for the Daedalus that is called

You are the Daedalus this document is addressed to: the builder of a target
harness whose own agent (below, **the target's agent**) wants to ask you
something mid-build. The upgrade that installed this release pointed you here.
It says what you expose to that agent, what else changed on your deployment
with this release, what the target's agent builds on its side, and how each
piece is checked. You verify, here, and record the results in your vault — a
session log, and an exchange entry for anything that failed.

Plain-language rule for everything below: a message a person reads is a
sentence, never a code. Where this document names an identifier (a call id,
a config key), it is for scripts, and the text around it says what it is.

## 1. What the reverse caller is

The target's agent is building the target. Mid-build it wants a second reader
who knows the harness — its pitfalls, its evidence, its exchange history — to
look at a change before it commits to it. That reader is you. The reverse
caller lets the target's agent, from its own session, run one command that
starts you in a bounded, read-only, receipted session, hands you a question
or a diff, and gets your answer back.

It is a review, not a work order. In a called session you have `Read`,
`Grep` and `Glob`, no MCP, no Bash, and a frame prompt saying so. You cannot
promote, commit, write a pitfall or raise a proposal from inside a call. If
the answer implies work, the target's agent brings it to the operator, or you
pick it up in your own session — the answer is advice.

## 2. What you expose (shipped in core; nothing to build)

The release that carries this is **v0.7.0**, the first with a `VERSION` file.
Predicate that you have it: `cat <daedalus-home>/VERSION` prints `0.7.0` and
`git -C <daedalus-home> describe --tags --abbrev=0` prints `v0.7.0`.

| Piece | Where | Check |
|---|---|---|
| The launcher, in its self mode | `core/call-agent.sh`, `core/call_agent.py` | `bash core/call-agent.sh --help` lists `self` among `--callee`'s choices and names `--caller`. |
| The callers list — on your side | `config.yaml`, `direct_call.callers` | With the key absent, `printf 'ping' \| bash core/call-agent.sh --callee self --caller <name>` exits 2 with "<name> is not on this Daedalus's callers list" and no `claude` starts (`state/direct-calls/` gains nothing). |
| The orientation marker | `core/session-start.py` writes `Daedalus session orientation: …` as the first line of its context; the launcher knows it for a call to itself — no `orientation_marker` line is needed | A successful call's receipt says `orientation: yes`, exit 0, with only `callers` configured. |
| Capture stands down | `core/capture.py` honours `CAPTURE_DEFER_TO_CALLER=1` | `.capture.log` shows "deferred to caller" for the call's session; the receipt says `capture: confirmed` or `capture: skipped` — never a second capture under the operator's label. |
| Receipts you can resume | `state/direct-calls/<call-id>/launch.json` | `bash core/call-agent.sh --resume <call-id>` with a follow-up on stdin answers in the same session (`attempts` grows by one; `session_id` unchanged). |
| Read-only tools, no MCP | `--tools Read,Grep,Glob --strict-mcp-config` | Ask, in a call, to "create a file named probe.txt": the answer refuses and no such file exists. |
| A called session is a visitor | The launcher exports `DIRECT_CALL_ID` into the session, and that alone makes it a visitor: your hooks never create, claim or bind a window, never take the pen, and downgrade their Stop-time checks to notes. The board is shown read-only with "This is a direct-call session; it holds no lease and cannot take the pen." How the session was started never makes it one. | Ask "which windows are live?" in a call: the answer lists them from the board. `ls -l state/leases/` is identical before and after — also when no window of yours is open and `prime.json` does not exist (V6b). |

**The launcher is the only sanctioned entry.** A `claude -p` run directly in
your home — from the target's agent, a cron, a shell — is an ordinary session
with the default tools, not a visitor: it is told to claim a window, it can
claim one, and although it never numbers itself or takes the pen, your hooks
treat it as a builder, with write access and capture under the operator's
label. So the calling side never falls back to a bare `claude -p` when the
launcher refuses or is missing; a refusal is the answer.

## 3. What else this release changed on your deployment

**Nobody runs upgrade steps by hand** — not the operator, not the target's
agent. You took the release by pulling your own home (`git pull --ff-only`;
if the guard refused it, the operator pulled in a shell); at your next session
start the upgrade (`core/upgrade.py`) ran by itself. Nothing here touches the
target's code: every path is under your home or its `config.yaml`.

| Change | What it means | Check |
|---|---|---|
| Every window is numbered | A plain `claude` in your home numbers itself — "You are window 01" — and works in `worktrees/01/<repo>` on `lease/01`; the next terminal is window 02. A lone window is 01 and holds the pen. `target/<repo>` is now the trunk mirror no session writes. An alias is display only. A headless session does not number itself: it is told to claim a number and never takes the pen. | `core/lease.sh list` shows `01 (you) — prime`; an Edit under `target/<repo>` is denied with "This is the prime's checkout". |
| The hand merge is retired | Trunk is reached only by `core/promote.sh <NN>`, run by the prime after the operator's yes; a direct push to trunk is denied by the guard and refused by a pre-push hook in your own target checkout. | `git -C target/<repo> push origin HEAD:<trunk>` from a shell there is refused with "This push would move <trunk>. Trunk is reached only through promote (`core/promote.sh <NN>`)." |
| Session logs by window and date | `vault/sessions/YYYY/MM/YYYY-MM-DD-<NN>.md`; earlier logs keep their names. `hot.md`'s `session:` is now `leases:`. | The first log after the upgrade carries `lease: "01"`; `hot.md`'s third line reads `leases:`. |
| `hot.md` and vault commits are the prime's | `core/vault-commit.sh` is the only way to commit the vault; a raw `git commit` under `vault/` is denied. | That `git commit` from a Bash tool is denied, naming `core/vault-commit.sh`. |
| Capture reads a `memory:` block | The upgrade moved it there from your old hook line, and a Stop hook now captures every couple of minutes. The old line still works and can be removed once `core/capture-tick.sh --dry-run` prints the bank with no `TENANT_*` in the environment; `core/doctor.sh` says when a leftover line can go. | `core/doctor.sh` prints `OK       memory: bank …`. |
| The reviewer runs through the launcher, resumable | The same verdict file, plus `call-id:` in its frontmatter; "ask the reviewer why" is `core/call-agent.sh --resume-review <NN> "<question>"`. | `bats core/tests/test_refuter_charter.bats` passes, its positive control included. |
| A model alias may not resolve on a managed or cloud-provider build | `verify.refute_model` in `config.yaml` names your provider's model id. | A gate run with the reviewer completes with a verdict, not exit 2. |
| The promote block can say a yes is a release | On a deployment whose users receive trunk through an update command, `promote.release_note: true` (and `promote.update_command`) in `config.yaml` makes the block say so. | The block printed by `promote <NN>` carries the release sentence. |

**How the upgrade ran.** At your first session after the pull, before the
window numbered itself, it: made `state/leases/`, `worktrees/`,
`state/promote/`, `state/direct-calls/`; installed the pre-push hook in your
own checkout under `target/` (outer and nested repos; never in any other
checkout on the machine); removed the old shared `state/pitfall-seen.json` /
`state/code-context-seen.json`; renamed `hot.md`'s `session:` to `leases:`
once; moved capture's settings from the hook line into `memory:` (the key into
the file `memory.api_key_file` names, mode 600); fetched each target repo once
and turned any work there that trunk lacks — the branch checked out, every
other local branch, a trunk ahead of origin, a detached checkout — into a
numbered window each (the checked-out work's untracked files went with it into
the window's worktree; any left in `target/` were named, and doctor names them),
putting the checkout
back on its trunk; then wrote `state/upgraded-to`. It said one line for each
thing it did. The session that ran the pull still runs the old hooks: it is
closed and a new one started. If its Stop says "config.yaml changed under this
session, by the upgrade to 0.7.0 — not by this session", that is the release's
own change: it is not restored. Check: `core/doctor.sh` prints
`OK       upgrade: state/upgraded-to 0.7.0` and no MISSING line about
leases, hooks or `VERSION`; `git -C target/<repo> status -sb` shows the trunk
with no `ahead`; the board lists any adopted window with "adopted from".
`python3 core/upgrade.py --dry-run` says what it would still do, and changes
nothing.

**What it would not do: move a target checkout that holds work it could
lose.** If yours had uncommitted changes, the upgrade stopped there and the
board says on every prompt: "upgrade to 0.7.0 incomplete: target/<repo> has
uncommitted changes — commit them on their branch inside that checkout, then
start a session again." A stash in that checkout is not a way out: it stays
in the trunk mirror, where no window shows it — the upgrade names any stash it
finds in one line, and `core/doctor.sh` names it until it is applied or dropped. If it had untracked files where
putting it back on its trunk would write, the sentence names them: "… has
untracked files that putting it back on <trunk> would overwrite (<files>) —
move them out of that checkout, or commit them on its branch, then start a
session again." If a rebase, merge, cherry-pick, revert or bisect had stopped
part-way there, it stopped before anything moved, naming the operation and the
`git -C target/<repo>` command that finishes or undoes it. Either way that work is yours to commit, in your own session;
nobody else touches it, and the next session start finishes the upgrade.

**The one other thing that needs a person** does not stop the upgrade: a
target checkout that already has a `pre-push` hook Daedalus did not install,
or sets `core.hooksPath` (a hook manager such as husky or lefthook does). The
upgrade said so in one line, with the remedy — merge the two hooks by hand or
move the other aside, or `git -C target/<repo> config --unset core.hooksPath`
— and then `core/setup.sh`. Until then promote refuses and `core/doctor.sh`
says MISSING for that repo's pre-push hook. Daedalus never changes another
tool's hook or `core.hooksPath` itself: either may be the target's own checks.

**Adopted work ships by "promote window NN"** to the prime. On a deployment
whose trunk lives behind a forge with branch protection, the first promote is
also the live check of whether that protection accepts the push for the
operator's credentials; if it does not, record it as an exchange entry. A
promote that opens a merge request instead (`promote.mode: merge-request`) is
the designed fallback; it is not in this release, so the exchange entry is
what carries it. On a deployment where a promote is a release, the operator
runs the update command (`promote.update_command`) after the push and sees the
release land.

**One note for your `config.yaml`, not for core:** where a promote is a
release, your `gates:` should exercise what the update command exercises — as
far as the gate contract (a command that exits 0) allows — so a trial merge
fails where the update would. You and the operator own that list.

## 4. What the target's agent builds on its side (not yours)

The calling side is the target agent's own extension, in its own home — never
inside the target, never inside your home. What it must do, stated as
requirements:

1. **Invoke your launcher; never reimplement it.** `bash <daedalus-home>/core/call-agent.sh --callee self --caller <its name> [--request-file F | request on stdin] [--resume <call-id>]`. No fallback: if the launcher refuses, the refusal is reported.
2. **Carry its own model-provider environment.** The launcher passes the environment through untouched and never sets a provider or a model.
3. **The operator's presence or a recorded grant.** The launcher does not check authorization; a call is made with the operator in the agent's conversation, or under a grant it records, and its log line says which.
4. **Check the exit code and a non-empty answer**, never the receipt line alone. 0 = an answer, identity verified; 3 = an answer, identity not verified (fine for a question, not for a review it will act on); 2 = refused before launch; 124 = timed out. Empty output with any exit is no answer.
5. **Keep the call id**, so an answer can be asked about: `--resume <call-id> "why?"`.
6. **Nothing from the calling side lands in the target — with a precondition.** The wrapper, its skill file, its log and its notes live in a directory that is not under the target checkout you manage (V0 settles it before anything is installed). A caller inside the target would be a change you read as part of the harness under audit, would enter the evidence fingerprint, and would make the target depend on the tool that reviews it.

## 5. The callers list

In your `config.yaml`:

```yaml
direct_call:
  callers: <the target agent's name>
```

Deny by default; absent means nobody. The name is a claim (one user account,
no separation between processes); the receipt records the invoking pid,
command, working directory, user and window as evidence. A second caller later
is one more comma-separated name. `config.yaml` is gitignored — this line never
leaves the machine. It is the whole configuration: no `orientation_marker` is
needed for a call to you, so a call with only this line exits 0 on success.

## 6. Checks the target's agent runs before your pull

Before the pull, the target's agent runs these on this machine and posts the
answers where the operator reads them; they say what to expect from your first
upgraded session. Every command reads, except the hook-environment block,
which writes one throwaway settings file and one probe file under `/tmp` and
removes both.

```
# build
claude --version

# from a Bash tool call INSIDE one of its sessions (not a plain shell):
env | grep -E '^CLAUDE(CODE|_CODE_SESSION_ID|_PID)='
cat ~/.claude/sessions/$CLAUDE_PID.json

# the session registry, three session kinds
ls ~/.claude/sessions/                                   # while a terminal session is open
jq '.pid,.sessionId,.name,.nameSource,.kind,.entrypoint' ~/.claude/sessions/<that pid>.json
#   then, while `claude -p 'say ok'` runs from a shell, the same jq on ITS file
#   then, if `claude --bg` exists on this build, `claude --bg --name probe "wait"` and the same jq on ITS file; stop it after

# hook environment ("if cheap"): the read-only half, from a Bash tool call inside a session started as `DAEDALUS_PROBE=1 claude`:
ps eww $CLAUDE_PID | tr ' ' '\n' | grep '^DAEDALUS_PROBE='
#   the hook half — a throwaway SessionStart hook in a --settings file outside any repo, then /exit each session:
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"env | grep ^DAEDALUS_PROBE= >> /tmp/daedalus-probe.txt"}]}]}}' > /tmp/probe-settings.json
DAEDALUS_PROBE=1 claude --settings /tmp/probe-settings.json
DAEDALUS_PROBE=1 claude --settings /tmp/probe-settings.json --bg --name probe "wait"   # only if --bg exists; stop it after
cat /tmp/daedalus-probe.txt
rm /tmp/probe-settings.json /tmp/daedalus-probe.txt

# same-machine messaging, with a second session open: ListAgents (is the second listed?), /status (any managed-settings line about messaging)
# one message: SendMessage to that peer (a delivery notice? the other terminal shows "Message from @…"?)
# only if messaging worked: the documented inbound-messaging setting, tried as --settings on a --bg launch; its exact spelling or "not found"
```

What each answer means for you: no session variables in a Bash tool → your
scripts cannot tell which session runs them, and `lease.sh claim` and
`promote` depend on the launch prefix alone (the caller is unaffected); hooks
that do not inherit the process environment → a background clone opens with
`claim`, and the launch line tells the operator to say "this is window NN"
first; no session registry → windows do not number themselves and the
`DAEDALUS_LEASE=<NN> claude` launch line is the way in; a different registry
pair → the board says who may take the pen; no messaging → windows still
work, and "message the holder" becomes "tell the operator". A build below
2.1.248 is the one answer that changes the plan rather than a fallback.

## 7. Verification predicates

Run in order; stop at the first failure and record it as an exchange entry
(`kind: issue`). V1–V4 repeat §6; copy those answers rather than re-running.

| # | Check | Expect |
|---|---|---|
| V0 | Before anything is installed: print the absolute path of the directory the caller's wrapper will live in, and the target checkout's top (`git -C <target-checkout> rev-parse --show-toplevel`) | The first is not under the second (`case "$wrapper_dir" in "$target_top"/*) echo INSIDE;; esac` prints nothing). If it is, choose a directory outside both repos and record the choice. V11 runs right after the install, before V6, and again after V10. |
| V1 | `claude --version` in the caller's shell | ≥ 2.1.248; record the number. |
| V1b | Inside a caller session's Bash tool: `env \| grep -E '^CLAUDE(CODE\|_CODE_SESSION_ID\|_PID)='` | `CLAUDECODE=1`, `CLAUDE_CODE_SESSION_ID=<uuid>`, `CLAUDE_PID=<pid>`; a missing one is recorded (§6 says what it means). |
| V2 | `ls ~/.claude/sessions/` with a session open; `cat` one file; the same for a `claude -p 'say ok'` run | JSON with `pid`, `sessionId`, `name`, `startedAt`, `kind`, `entrypoint`; a terminal `kind: interactive`, `entrypoint: cli`; the `-p` run `entrypoint: sdk-cli`. Record what this build shows. |
| V3 | From a caller session with a Daedalus session also open: `ListAgents` | Daedalus listed; if not, record "native messaging unavailable here" — the caller still works; skip V4. |
| V4 | One `SendMessage` to the Daedalus peer | A delivery notice; your terminal shows `Message from @<the caller's name>`. |
| V5 | The callers-list refusal, before the caller is added | Exit 2, "not on this Daedalus's callers list", no receipt directory. |
| V6 | First real call, a question ("What pitfalls apply to `<path>`?") | Exit 0; the answer on stdout, signed as Daedalus; the receipt says `orientation: yes`; `launch.json` says `status: completed`. |
| V6b | A call with no Daedalus window open (`state/leases/prime.json` absent or its session dead), and — if you can arrange it — while another session of yours runs gates | Exit 0 in V6's time (not 124); `state/leases/` byte-for-byte unchanged (`ls -l` and `shasum state/leases/*.json`); no `prime.json` created. |
| V7 | Read-only, inside a call | Asked to write a file: a refusal, no file. |
| V8 | Resume | `--resume <id>` with a follow-up: `attempts` has two entries, the same `session_id`, and the answer refers to the earlier turn. |
| V9 | Capture (only with a `memory:` block in your `config.yaml`) | `.capture.log` says "deferred to caller" for the call's session; the receipt says `capture: confirmed` with the caller's label. Without a block: `capture: skipped`, and `core/doctor.sh` says the block is absent. |
| V10 | Timeout | `direct_call.timeout: 5` for a moment: a call exits 124; no `claude -p` survives (`pgrep -f 'claude -p'` is empty). Restore the value. |
| V11 | The target untouched — run twice: right after the wrapper is installed, and after V10 | `git -C <target-checkout> status --porcelain` is empty both times (untracked files count); the target's evidence fingerprint (`core/fingerprint.sh`) is unchanged from before the install to after V10. |

V11 is the one that matters most, and its first run catches a misplaced
wrapper before any call is made: if the install shows up in the target's
working tree, V0 was answered wrong.

## 8. The rule, stated once

**Nothing from this handoff lands in the target.** Your side is Daedalus core
(shipped; you pulled it and it upgraded itself). The calling side lives in the
target agent's own home, outside the target. The callers list is one
gitignored config line. If a later version needs something inside the target,
that is a proposal to the development site, not a local patch — the rule you
live under too.
