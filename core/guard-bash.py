#!/usr/bin/env python3
"""PreToolUse(Bash) guard: the speed bump in front of the boundary check.

Denies, with a reason, pushes to the trunk, commits on the trunk and the
trunk-reaching git shapes it parses (spec §7.3) in every repo under the home —
`target/`, `worktrees/`, `state/promote/` — through `bash -c` (options before
`-c` included), `eval`, `watch`, `$( )`, backticks, a shell fed its script on
a pipe, here-string or heredoc, `( )` and `{ }` groups, `!`, `if`/`while`
bodies, function bodies, `env` and `VAR=` prefixes, any command that runs
another (sudo, nice, timeout, xargs, find -exec … — every word of a
non-data command is searched for git, a shell or eval), git by path
(`/usr/bin/git`) or dashed (`git-send-pack`), and git aliases alike (one
recursive check_command, so a command reached any of those ways passes every
rule; nesting deeper than four is denied); distribution code by every git route
(`apply`, `am`, `cherry-pick`, `merge`, `pull`, `rebase`, `stash pop|apply`,
`checkout <rev>`, `switch <branch>`, `restore --source` in Daedalus's own
checkout, `patch < file` writing its cwd); in Daedalus's own checkout every git
command but reading ones (status, log, diff, show, fetch …) and the release
pull — exactly `git pull --ff-only`, with no other global option than -C,
allowed only while the address git will fetch is the one the checkout's own
.git/config records for its branch, nothing outside it bending that (plan 5
Decision 17; Task 9 review — the §6.1 record compares the disk with HEAD, so a
command that moves HEAD, or a pull aimed elsewhere, would pass it); `git config`
writes at the global or system scope or into a named file that decide where a
pull reads from (remote.*, branch.*, url.*, pull.*, http.*, …), from anywhere;
`--no-verify` (abbreviated too —
git takes any unique prefix of a long option); `core.hooksPath` by `-c`,
`--config-env` and `git config`, the GIT_CONFIG_* variables that point git at
other configuration (GIT_CONFIG_GLOBAL, _SYSTEM, _PARAMETERS, _COUNT/_KEY/_VALUE
— as a prefix or exported), `include.path`/`includeIf.*` by `-c` or `git
config`, and writes (redirects, cp, sed -i, chmod, chown, touch …; the
Edit|Write leg too, through boundary-hook.write_check) under `.git/hooks/`, to a
repo's `.git/config`, `~/.gitconfig` and `~/.config/git/config`; `git
send-pack`, `http-push` and `remote-<helper>` in every repo under the home and
toward the target's origin from anywhere — git runs the pre-push hook for
`git push` and for nothing else, so plumbing passes the hook (Task 13 review,
measured); a push whose destination comes from configuration
(remote.<name>.push, remote.<name>.mirror, push.default over the branch's
upstream — read as the command runs, its `-c` pairs included), git's `heads/<x>`
name matching, a pattern refspec (`refs/heads/x/*:refs/heads/*`, `refs/*:refs/*`) whose
destination can land on a trunk, on the command line or in remote.<name>.push (critic finding 3),
`git config` and `branch -u` aiming at a trunk; a trunk moved by
`update-ref` or `branch -f`; a push to the target's origin from any directory,
judged by repository — a local path as the git directory it opens, a network
URL as host and path in any spelling, after insteadOf — with
`GIT_DIR`/`GIT_WORK_TREE`/`--git-dir`/`--work-tree` honoured; HOME or
XDG_CONFIG_HOME set in a command that runs git (another global configuration
can hold core.hooksPath and remote.<name>.push), a push whose configuration —
read with the command's own HOME, XDG_CONFIG_HOME and GIT_CONFIG_* — sets
core.hooksPath, `cd`/`pushd` options read as the shell reads them (-L, -P, -e,
-@, --; any other option, popd and `builtin cd` placed too) and `git push
--repo=<remote>` as the remote of a push with no repository argument
(critic-fix review, findings 1, 2 and 4); a
program-made terminal (`script`, `expect`, `unbuffer`, a `pty`, the suite's
tty helper) in front of `promote.sh` or `lease.sh`, `screen`/`tmux`/`login`
anywhere, and the suite's tty seam variable; destructive git; and writes
whose operand resolves to a protected path of this deployment. One message
rule in every case: trunk is reached only through promote. The guard reads
only literal words (plan 4 completeness critic, finding 1): a git command any of
whose words the shell fills in or expands when it runs — a variable, `$( )`,
backticks, `$'…'`, a glob or brace expansion — in its subcommand, options,
refspecs or the words before it, a command name or a wrapper's word that could
be git, a `bash -c`/`eval`/interpreter string that is not literal, `env -S`, and
a git command after `cd` to a place the guard cannot know are denied ("I can't
read this git command exactly …"); only a commit message and a pathspec after
`--` of anything but a push may hold one. GIT_COMMON_DIR, which moves the hooks
directory, is denied like the GIT_CONFIG_* variables. A write is read the same
way (finding 2): a write target holding a variable other than $HOME /
$CLAUDE_CONFIG_DIR, a `$( )`, backticks, `$'…'` or a brace expansion, or a
relative one after `cd` to a place the guard cannot know, is denied outright; a
glob is denied when the directory before its first wildcard could hold the
transcript or Daedalus's own files, and otherwise each path it matches now is
checked; the writers beyond redirects — curl -o/-O, wget, tar -x -C and -c -f,
unzip -d, cpio -i, ditto, install, ln (its source too), cp/mv -t, patch -o,
sqlite3 (its database and .output/.once/.save/ATTACH), sort -o, uniq, git
--output, awk print redirects, and inline Python (parsed: open() in a write
mode, pathlib, shutil, os) — are writes; inline perl, ruby or node code that
writes files is denied, its targets unread. So are (critic-fix review,
finding 3) a writer named by its path (`/bin/cp`), sed's w/W commands and
s///w (its e command and s///e denied), base64 -o, openssl -out, xxd's output
file, split/csplit prefixes, plutil -o (or in place), scp to a local path,
say -o, gawk -i inplace, a scripted vim's files and the files its commands
write (commands other than substitute, delete, global, sort, write, quit and
their kin denied, as are -S/-s scripts), and the shell commands awk
(system(), pipes, getline) and osascript (do shell script) run — checked
like any command, denied when not a literal string. The guard is a
speed bump and git's pre-push hook (core/prepush.py) a second one, which does
not fail open when this does but runs only for `git push`; a push by a route
this guard does not parse (a script file, an interpreter's own git library,
a hook disabled by a route not listed here), from a clone outside the home
with no hook, is covered only by server-side branch protection (plan 4
Decision 38).

The trunk is config.yaml target.branch, read through
verifylib.target_branch — never a hardcoded "main": a GitLab deployment whose
trunk is `mainline` had a guard that denied `main` and let `mainline` through
(the same defect class PROP-019 fixed in the promotion gate). "main" and
"master" stay denied alongside the configured trunk as defense in depth for a
config that names the wrong one; neither is ever a feature branch — and so
does the remote's default branch (refs/remotes/origin/HEAD), because the
config that names the wrong trunk is exactly the one doctor cannot tell from
a deliberately non-default trunk. A push
whose refspec names the current commit (`HEAD`, `@`) is resolved to the
current branch before that comparison. Relative paths resolve against the hook's `cwd`, then any
`cd <dir> &&` earlier in the same command. Commands are split at `&&`,
`||`, `|`, `&`, `;` and newlines — tokenized with shlex's punctuation
mode, because plain shlex.split keeps a glued `;` on the word (`vault;`)
and `cd vault; git commit -m x` was one cd segment whose git command was
never examined (Task 11 review). `>` is punctuation too, so a redirect is
its own token in every form (`x>path`, `2>`, `>|`, `&>>`) and `2>&1` does
not split a segment at its `&` (plan 4 Task 2 review). Heredoc bodies are removed before
tokenizing: a body is prose, and an apostrophe in it ("it's") is what
made shlex raise. Fails CLOSED on its own errors (Task 13 review: an empty
alias crashed it, and failing open waved through the trunk push after it):
a segment, or a whole command, the guard raises on is denied with a sentence
saying it could not be checked. A command that is still unparseable is checked
for redirect and `-i` operands with the full write check, and an unreadable config
fails CLOSED for push and commit in every tree of the home: with no trunk to
compare against, a push or commit there is denied rather than waved through
(the same rule boundary-hook.py applies since PROP-019).

Since v0.7.0 the guard also carries the lease-era checks for Bash operands
(spec §4.6, §4.7, §3.1) — boundary-hook.write_check, the same function the
Edit/Write leg runs, so both legs say the same sentences: a write operand
in another live window's changed set is denied ONCE per session with the
warning, then let through with the warning as context; the prime's
checkout (target/ and everything under it) is denied for every window;
another window's worktree (worktrees/<NN> and everything under it, the
directory itself included) is denied every time, and so is `git worktree
remove` of it — resolved against the `-C` directory git runs in, and also
matched the way git itself matches a relative operand, as a path suffix of
every registered worktree (`git worktree remove 01/thing` from window 02's
worktree removes window 01's); a released window's own
worktree is closed; vault/hot.md is the prime's alone; raw `git add`,
`commit` and `stash` under vault/ are denied from EVERY session, prime
included, naming core/vault-commit.sh; a non-prime's `commit` or `push`
under vault/ is denied naming the prime's window number, read from
prime.json at denial time. A session that cannot be bound while lease
files exist fails CLOSED under target/, worktrees/ and hot.md (§4.4).
"""
from __future__ import annotations

import ast
import functools
import glob as globmod
import importlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402
bh = importlib.import_module("boundary-hook")  # noqa: E402  (the file name has a dash)

# The shell's command separators, tokenized as their own words (shlex punctuation mode, plus
# newline): a token made only of these characters (`&&`, `||`, `|`, `|&`, `&`, `;`, `;;`, a
# newline, or a run such as `;\n`) ends a segment. `(` and `)` too (Task 13 review): a subshell
# `(git push …)` and a function body `f() { … }` start a command of their own.
PUNCT = ";&|\n()"
# A heredoc opener: `<<WORD`, `<<-WORD`, `<<'WORD'`, `<<"WORD"`, `<<\WORD` — never `<<<`.
HEREDOC = re.compile(r"<<-?\s*(?:'([^']*)'|\"([^\"]*)\"|(\\?[A-Za-z0-9_][A-Za-z0-9_.-]*))(?!<)")
# Scripts learn which session runs them from these variables (spec §4.4 step 1);
# a prefix that strips or blanks one makes a session look like an operator shell.
STRIP_VARS = re.compile(r"^(CLAUDE[A-Z_]*|DAEDALUS_SESSION_ID)$")
STRIP_REASON = "scripts learn which session runs them from these variables; do not strip them"
# §4.7: the prime's number is read from prime.json at denial time, never hard-coded; never a peer name (§4.1).
NOT_PRIME = bh.NOT_PRIME
VAULT_RULE = "The vault is committed by `core/vault-commit.sh`, which checks every claim first."
DESTRUCTIVE = [("reset", "--hard"), ("checkout", "--"), ("restore", "."), ("clean", "-f"), ("stash", "drop")]
WRITE_IN_STRING = re.compile(r"(?:>>?|\btee\b|open\(\s*['\"][^'\"]+['\"]\s*,\s*['\"][wa]|\.write_text\(|\bwrite\()")
PATHISH = re.compile(r"[A-Za-z0-9_./~-]*[A-Za-z0-9_-]+(?:\.[A-Za-z0-9]+)?")

# §7.3 — the messages, one rule in every case.
PROMOTE_RULE = ("Trunk is reached only through promote. Commit on your window's branch (lease/%s); when it is ready, "
                "ask the prime to run promote %s.")
PUSH_TRUNK = "This push would move %s. " + PROMOTE_RULE
FORCE = PROMOTE_RULE[:-1] + " — and never with --force: a forced push rewrites history."
EVERYTHING = ("`git push %s` is refused: promote pushes one merge commit; nothing else pushes branches (every "
              "window's branches and the trunk share one .git).")
MATCHING = "The refspec `:` pushes every matching branch, %s too. " + PROMOTE_RULE
UNPARSEABLE = "The refspec %s cannot be checked (it holds $, a backtick or {); name the branch literally."
SCRATCH_PUSH = "Pushes from the promote scratch are promote's job; run `core/promote.sh <NN> --confirm`."
COMMIT_TARGET = "You are on %s in the prime's checkout. Build in your window's worktree (%s), not here."
COMMIT_TRUNK = "You are on %s. " + PROMOTE_RULE
NO_VERIFY = ("--no-verify is refused: it skips git's hooks, and the pre-push hook is how git itself refuses a trunk "
             "push no promotion confirmed.")
HOOKSPATH = "core.hooksPath is not changed from here: other hooks would skip the pre-push hook that guards trunk."
HOOKS_WRITE = "%s is under .git/hooks/; those hooks guard trunk, and only Daedalus's installer (core/prepush.py) writes them."
DIST = "`%s` in Daedalus's own checkout changes distribution code; write a proposal instead of editing it."
PUSH_IN_SCRIPT = "A git push inside a script string cannot be checked; run `git push` as its own command."
# Task 13 review: git runs the pre-push hook for `git push` and for nothing else.
PLUMBING = ("`git %s` pushes without running git's pre-push hook, so it is refused here. " + PROMOTE_RULE)
FROM_STDIN = ("`%s git %s` takes arguments from its input, which cannot be checked; run `git %s` with every "
              "argument written out.")
GIT_CONFIG_ENV = ("%s is not set from here: it points git at other configuration, which can switch off the pre-push "
                  "hook that guards trunk or aim a push somewhere else.")
INCLUDE = ("git's configuration does not include other files from here (%s): an included file can switch off the "
           "pre-push hook that guards trunk.")
PUSH_REWRITE = "%s is not set from here: it rewrites where a push goes, and could aim one at the target's origin."
CONFIG_TRUNK = "`git config %s %s` would send pushes to %s. " + PROMOTE_RULE
UPSTREAM_TRUNK = "`git branch %s` would make %s this branch's push destination. " + PROMOTE_RULE
CONFIG_PUSH_TRUNK = "This push would move %s (remote.%s.push sends it there). " + PROMOTE_RULE
PATTERN_TRUNK = "The refspec %s is a pattern that can push onto %s without naming it. " + PROMOTE_RULE
CANNOT_CHECK = ("The guard could not check this command (it failed on `%s`); nothing ran. Run its commands one at a "
                "time, written out plainly.")
# Plan 4 completeness critic, finding 1: a word the shell fills in when the command runs ($VAR, ${…}, $( ),
# backticks, $'…') or a glob it expands (*, ?, […], {a,b}) is not a word the guard can read. Where it reaches git
# — or could be git — the command is denied, never judged by its spelling.
GIT_UNREADABLE = "I can't read this git command exactly, so I can't check it is not a push to trunk. Write it out literally."
CMD_UNREADABLE = ("I can't read this command exactly (%s is filled in by the shell when it runs), so I can't check it "
                  "is not a git push to trunk. Write it out literally.")
ENV_SPLIT = ("`env -S` splits a string into a command the guard cannot read exactly, so I can't check it is not a git "
             "push to trunk or a write to the session transcript. Write the command out literally.")
WRITE_UNREADABLE = ("I can't tell exactly where this write lands (%s is filled in or expanded by the shell when it runs), "
                    "so I can't check it stays out of the session transcript and Daedalus's own files. Write the path "
                    "out literally.")
CODE_WRITE = ("I can't tell exactly where this %s code writes, so I can't check it stays out of the session transcript "
              "and Daedalus's own files. Write the file with a redirect to a literal path, or with Python's open() of "
              "a literal path.")
HOOKDIR_ENV = ("%s is not set from here: it moves where git reads its hooks from, so the pre-push hook that guards "
               "trunk would not run.")
# the GIT_CONFIG_* variables that point git at other configuration; GIT_CONFIG_NOSYSTEM is not among them: it
# can only remove configuration (the system file), never add a hooks path or a push destination.
CONFIG_ENV = re.compile(r"^(GIT_CONFIG|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_PARAMETERS|GIT_CONFIG_COUNT|"
                        r"GIT_CONFIG_KEY_[0-9]+|GIT_CONFIG_VALUE_[0-9]+)=")
TRUNK_REF = "`git %s` would move %s by hand. " + PROMOTE_RULE
# git reads its hooks from the common git directory; GIT_COMMON_DIR moves it (measured: a push with it pointed at a
# copy of the repository ran no pre-push hook) — critic finding 1.
HOOKDIR_VAR = re.compile(r"^(GIT_COMMON_DIR)=")
# git reads its global configuration from $HOME/.gitconfig and $XDG_CONFIG_HOME/git/config: either one, set in a
# command that runs git, points git at another global configuration — whose core.hooksPath skips the pre-push hook
# and whose remote.<name>.push aims the push at trunk (critic-fix review, finding 1: measured, `HOME=<dir> git push
# origin` moved a bare origin's main past a refusing hook). Set as a prefix, through env, exported or assigned.
GLOBAL_CONFIG_VAR = re.compile(r"^(HOME|XDG_CONFIG_HOME)=")
GIT_WORD = re.compile(r"(?:^|[^A-Za-z0-9_.])git(?:$|[^A-Za-z0-9_.])")
GLOBAL_CONFIG_ENV = ("%s is not set in front of a git command: git reads its global configuration from there, and "
                     "another configuration can switch off the pre-push hook that guards trunk or send a push to "
                     "trunk. Run git with the environment it has.")
HOOKSPATH_SET = ("core.hooksPath is set (%s) in the configuration this push runs with, so git would not run the "
                 "pre-push hook that guards trunk. Unset it (git config --unset core.hooksPath, or in your global "
                 "git configuration) and run core/setup.sh.")
TTY_SEAM = "DAEDALUS_TEST_TTY_ANCESTRY is the test suite's switch; nothing outside the suite sets it."
TTY_WRAP = ("A terminal made by a program is not the operator typing: the yes, and a reason to take the pen or skip "
            "the review, are typed by a person in their own shell.")
# Decision 32: in front of promote.sh or lease.sh only (script and expect have ordinary uses) ...
TTY_TOOLS = {"script", "expect", "unbuffer"}
# ... and in ANY command: a multiplexer's typing step (`screen -X stuff yes`, `tmux send-keys`) names no
# entry script, and `login -pf` is the measured route that still passes tty_answer's ancestry check.
TTY_ALWAYS = {"screen", "tmux", "login"}
ENTRY = re.compile(r"\b(promote|lease)\.sh\b")
# Decision 33: git takes any unique prefix of a long option (`--no-veri` is --no-verify).
DENIED_LONG = ("--no-verify", "--mirror", "--all", "--branches", "--prune", "--delete", "--force", "--force-with-lease",
               "--force-if-includes")
WORKTREE_PROMOTE = ("Removing or pruning worktrees under state/promote/ is the prime's (it is promote's scratch); "
                    "window %s is not the prime.")
WORKTREE_PROMOTE_WAITS = ("Removing or pruning worktrees under state/promote/ waits until the upgrade to %s finishes: "
                          "this session took the pen at a vault commit while it was pending, and the upgrade's safety "
                          "copy protects target/.")
TOO_DEEP = "This command nests shells too deeply for the guard to check; run the inner command directly."
HOME_TREES = ("target", "worktrees", "state/promote")
# frame-jack spec §6.6: the observed agent cannot switch off its observer. state/ is already protected as a
# whole (verifylib EXTRA_PROTECTED); these name the AMI's record with its own sentence, reach the heredoc bodies an
# interpreter or a shell reads, and hold the switch's two verbs to the operator's recorded words.
AMI_STATE = "state/ami"
AMI_STATE_DENY = "state/ami/ is the AMI's record; /frame-jack off is the switch"
SWITCH_DENY = "the operator has not said /frame-jack %s in this session; the AMI stays %s until they type /frame-jack %s"
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
INTERPRETERS = {"python3", "python", "perl", "ruby", "node"}
PREFIX_CMDS = {"command", "exec", "nohup", "time"}
# Task 13 review: shell words that start a command without being one (`{ git push …; }`, `! git push`,
# `if …; then git push …; fi`) — stripped before the command is classified.
KEYWORDS = {"{", "}", "!", "if", "then", "else", "elif", "fi", "do", "done", "while", "until", "time", "coproc"}
# Commands whose words are data, never a command they run: `echo git push origin main` pushes nothing.
# Every other command is searched for a git, shell or eval word it runs (sudo, nice, timeout, xargs,
# find -exec, watch, stdbuf, flock, caffeinate … — a list of wrappers would always miss one).
DATA_HEADS = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "ag", "man", "which", "type", "whereis", "whatis",
              "apropos", "cat", "less", "more", "head", "tail", "wc", "ls", "file", "stat", "mkdir", "rmdir", "cd",
              "test", "[", "[[", "true", "false", "sort", "uniq", "diff", "cmp", "basename", "dirname", "realpath"}
# The wrappers that feed the command they run arguments from their input.
STDIN_ARGS = {"xargs", "parallel"}
# Deleting a window's work (agent-runnable design 2026-10-15, §4.3): `core/lease.sh release NN --remove …` is
# judged here, wherever lease.sh stands in the segment, and the refusal is leaselib's reason — said before the
# tracked allow rule (Bash(core/lease.sh release:*)) is consulted, since a PreToolUse deny holds after an allow
# rule. ALLOW_RULE_WRAPPERS is the wrapper list the permissions doc ("Wrappers", read 2026-10-15 on 2.1.300) says
# Claude Code strips before matching a Bash allow rule, so `timeout 30 core/lease.sh release …` is pre-approved by
# the rule: exec_index must see past each of them (a test pins this tuple against the guard). The guard's own
# reach is wider — any non-data head: sudo, flock, caffeinate, bash … — and leaselib.release backstops the rest.
ALLOW_RULE_WRAPPERS = ("timeout", "time", "nice", "nohup", "stdbuf", "command", "builtin", "noglob", "xargs")
LEASE_HEADS = {"lease.sh"}
DELETE_FROM_STDIN = ("A delete takes its arguments on the command line, never from xargs or parallel; run "
                     "core/lease.sh release NN --remove … directly.")
DELETE_NO_SESSION = "The delete runs from a window: this command carries no session."
DELETE_NUMBER = "Name the window by its number (core/lease.sh release 02 --remove …), not an alias or a variable."
DELETE_ONE_WORD = ("Ask the operator for a one-word yes and record that; a reply with several lines or shell "
                   "characters cannot be carried on the command.")
# git options that take their value as the next word (git.c handle_options).
GIT_VALUE_OPTS = {"-C", "-c", "--config-env", "--git-dir", "--work-tree", "--namespace", "--super-prefix"}
# bash/sh options that take their value as the next word: `bash -o errexit -c '…'`.
SHELL_VALUE_OPTS = {"-o", "+o", "-O", "+O", "--rcfile", "--init-file"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PUSH_IN_STRING = re.compile(r"\bgit\b[^;&|\n]*\bpush\b")
GIT_BUILTINS = {
    "add", "am", "apply", "archive", "bisect", "blame", "branch", "bundle", "cat-file", "check-ignore", "checkout",
    "cherry", "cherry-pick", "clean", "clone", "commit", "commit-tree", "config", "describe", "diff", "diff-tree",
    "fetch", "for-each-ref", "format-patch", "fsck", "gc", "grep", "hash-object", "help", "init", "log", "ls-files",
    "ls-remote", "ls-tree", "maintenance", "merge", "merge-base", "mv", "notes", "prune", "pull", "push", "range-diff",
    "read-tree", "rebase", "reflog", "remote", "reset", "restore", "rev-list", "rev-parse", "revert", "rm", "show",
    "shortlog", "sparse-checkout", "stash", "status", "submodule", "switch", "symbolic-ref", "tag", "update-index",
    "update-ref", "version", "worktree", "write-tree", "send-pack", "http-push"}


def deny(reason: str) -> None:
    v.emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                   "permissionDecisionReason": reason}})


def is_separator(t: str) -> bool:
    return bool(t) and all(c in PUNCT for c in t)


def segments(tokens: List[str]) -> List[List[str]]:
    out: List[List[str]] = [[]]
    for t in tokens:
        if is_separator(t):
            out.append([])
        else:
            out[-1].append(t)
    return [s for s in out if s]


def segments_sep(tokens: List[str]) -> List[Tuple[List[str], str]]:
    """segments() with the separator run before each one (`|` says it reads the one before)."""
    out: List[Tuple[List[str], str]] = [([], "")]
    for t in tokens:
        if is_separator(t):
            out.append(([], t))
        else:
            out[-1][0].append(t)
    return [(sg, sep) for sg, sep in out if sg]


def strip_heredocs(cmd: str, bodies: Optional[List[str]] = None) -> str:
    """Every heredoc's body lines removed; the `<<WORD` word stays on its line. Bodies run from
    the line after their opener to the terminator line, in the order the openers appear;
    `<<-` lets the terminator carry leading tabs. An unterminated body swallows the rest, as
    it does in bash."""
    out: List[str] = []
    pending: List[Tuple[str, bool]] = []
    for line in cmd.split("\n"):
        if pending:
            term, tabs = pending[0]
            if (line.lstrip("\t") if tabs else line) == term:
                pending.pop(0)
            elif bodies is not None:
                bodies.append(line)
            continue
        out.append(line)
        for m in HEREDOC.finditer(line):
            word = m.group(1) if m.group(1) is not None else m.group(2) if m.group(2) is not None else m.group(3).lstrip("\\")
            pending.append((word, m.group(0).startswith("<<-")))
    return "\n".join(out)


# An unquoted redirect operator as its own token: `>`, `>>`, `>|`, `>&`, `&>`, `&>>` (the fd
# number before it, `2>`, is the preceding word). Plan 4 Task 2 review: `>` is punctuation to
# the lexer, so `echo x>path` and `2>&1` split the way the shell splits them — quoted text
# (`'a->b'`) stays one word.
REDIRECT_RUN = re.compile(r"&>>?|>>?[|&]?")


def split_punct_run(t: str) -> List[str]:
    """A merged punctuation run that carries a `>` split into separators and redirect
    operators: `&&>` -> `&&`, `>`; `;>` -> `;`, `>`; `&>>` stays whole."""
    out: List[str] = []
    sep = ""
    i = 0
    while i < len(t):
        if t.startswith(("&&", "||"), i):
            sep += t[i:i + 2]
            i += 2
            continue
        m = REDIRECT_RUN.match(t, i)
        if m:
            if sep:
                out.append(sep)
                sep = ""
            out.append(m.group(0))
            i = m.end()
            continue
        sep += t[i]
        i += 1
    if sep:
        out.append(sep)
    return out


def is_redirect(t: str) -> bool:
    return ">" in t and all(c in "&>|" for c in t)


# The shell's expansions, marked before tokenizing (critic finding 1): each character that starts one is replaced by
# a private-use character of its own, one for one, so a token keeps the marks through shlex and every slice of it.
DYN, BQ, STAR, QMARK, BRACKET, BRACE, TILDE = "\ue000", "\ue001", "\ue002", "\ue003", "\ue004", "\ue005", "\ue006"
UNMARK = str.maketrans({DYN: "$", BQ: "`", STAR: "*", QMARK: "?", BRACKET: "[", BRACE: "{", TILDE: "~"})
DYN_MARKS = DYN + BQ + TILDE
GLOB_MARKS = STAR + QMARK + BRACKET + BRACE
WORD_END = " \t\n;&|()<>"


def _word_rest(cmd: str, i: int) -> str:
    """The rest of the word that starts at i (approximate: up to unquoted-looking whitespace or an operator)."""
    j = i
    while j < len(cmd) and cmd[j] not in WORD_END:
        j += 1
    return cmd[i:j]


def mark(cmd: str) -> str:
    """cmd with each unquoted expansion's first character replaced by its mark: `$` that starts a parameter,
    command or arithmetic expansion or a $'…' / $"…" string (outside single quotes), a backtick (outside single
    quotes), and — unquoted — `*`, `?`, a `[` closed later in its word, a `{` that opens a brace expansion
    ({a,b} or {1..3}), and a `~+` / `~-` word start. Backslash-escaped characters stay literal."""
    out: List[str] = []
    i, n, state = 0, len(cmd), "n"
    while i < n:
        c = cmd[i]
        if state == "s":
            out.append(c)
            state = "n" if c == "'" else "s"
            i += 1
            continue
        if c == "\\":
            if state == "n" or (i + 1 < n and cmd[i + 1] in '$`"\\\n'):
                out.append(cmd[i:i + 2])
                i += 2
                continue
            out.append(c)
            i += 1
            continue
        if state == "d" and c == '"':
            state = "n"
        elif state == "n" and c == "'":
            state = "s"
        elif state == "n" and c == '"':
            state = "d"
        elif c == "$" and i + 1 < n and (cmd[i + 1].isalnum() or cmd[i + 1] in "{(`@*#?!$_-" or
                                          (state == "n" and cmd[i + 1] in "'\"")):
            out.append(DYN)
            i += 1
            continue
        elif c == "`":
            out.append(BQ)
            i += 1
            continue
        elif state == "n":
            if c == "*":
                c = STAR
            elif c == "?":
                c = QMARK
            elif c == "[" and "]" in _word_rest(cmd, i + 1):
                c = BRACKET
            elif c == "{":
                rest = _word_rest(cmd, i + 1)
                body = rest.split("}", 1)[0] if "}" in rest else ""
                if "," in body or ".." in body:
                    c = BRACE
            elif c == "~" and (i == 0 or cmd[i - 1] in WORD_END + "=:") and cmd[i + 1:i + 2] in ("+", "-"):
                c = TILDE
        out.append(c)
        i += 1
    return "".join(out)


class Word(str):
    """A token as the guard reads it (its marks restored), with `raw` — the marked spelling — so the guard can
    tell a literal word from one the shell fills in or expands."""
    raw: str

    def __new__(cls, raw: str) -> "Word":
        w = str.__new__(cls, raw.translate(UNMARK))
        w.raw = raw
        return w


def wslice(t: str, start: int) -> str:
    """t[start:], keeping a Word's marks (each mark stands for one character, so the offsets agree)."""
    return Word(t.raw[start:]) if isinstance(t, Word) else t[start:]


def dynamic(t: str) -> bool:
    """t holds a parameter, command or arithmetic expansion, a backtick, $'…' or ~+ / ~-."""
    return any(ch in DYN_MARKS for ch in getattr(t, "raw", ""))


def globbed(t: str) -> bool:
    """t holds an unquoted glob or brace expansion."""
    return any(ch in GLOB_MARKS for ch in getattr(t, "raw", ""))


def unresolved(t: str) -> bool:
    return dynamic(t) or globbed(t)


def tokenize(cmd: str) -> List[str]:
    """shlex in punctuation mode over the command with its heredoc bodies removed: `;`, `&`,
    `|`, `>` and newlines come out as their own tokens (runs merged: `&&`, `||`, `>>`, `&>`),
    quotes and escapes as in posix mode, `#` never a comment. A run that mixes a separator
    and a redirect is split (split_punct_run). Raises ValueError only for a quote the shell
    itself leaves open."""
    lex = shlex.shlex(mark(strip_heredocs(cmd)), posix=True, punctuation_chars=PUNCT + ">")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    out: List[str] = []
    for t in lex:
        if ">" in t and t and all(c in PUNCT + ">" for c in t):
            out.extend(split_punct_run(t))
        else:
            out.append(Word(t))
    return out


# The two variables a transcript path is spelled with; expanded from the hook's environment
# (the session's own), everything else left literal (plan 4 Task 2 review).
PATH_VARS = re.compile(r"\$(?:\{(HOME|CLAUDE_CONFIG_DIR)\}|(HOME|CLAUDE_CONFIG_DIR)\b)")


def resolve(cwd: Path, p: str) -> Path:
    p = PATH_VARS.sub(lambda m: os.environ.get(m.group(1) or m.group(2)) or m.group(0), p)
    p = os.path.expanduser(p)
    return (cwd / p).resolve() if not os.path.isabs(p) else Path(p).resolve()


under = bh.under


def long_as(a: str) -> Optional[str]:
    """The denied long option a --name abbreviates (at least two letters after --), or None (Decision 33)."""
    name = a.split("=", 1)[0]
    if not name.startswith("--") or len(name) < 4:
        return None
    return next((full for full in DENIED_LONG if full.startswith(name)), None)


def prefix_env(seg: List[str]) -> Dict[str, str]:
    """VAR=value words before the command, `env`'s included (Decision 38): GIT_DIR,
    GIT_WORK_TREE and GIT_CONFIG_* change which repo git acts on and how."""
    out: Dict[str, str] = {}
    i = 0
    while i < len(seg):
        t = seg[i]
        if ASSIGN.match(t):
            k, _, val = t.partition("=")
            out[k] = val
            i += 1
        elif t == "env" or t in PREFIX_CMDS:
            i += 1
        elif t.startswith("-") and "env" in seg[:i]:
            i += 2 if t in ("-u", "--unset", "-C", "--chdir") else 1
        else:
            break
    return out


NET_URL = re.compile(r"^([A-Za-z][A-Za-z0-9+.-]*)://(?:[^@/]*@)?(\[[^\]]+\]|[^/:]+)(?::[0-9]*)?(/.*)?$")
SCP_URL = re.compile(r"^(?:[^@/:]+@)?([^/:]+):(.*)$")


def _net(host: str, path: str) -> str:
    path = path.strip("/")
    path = path[:-4] if path.endswith(".git") else path
    return "net:%s/%s" % (host.lower(), path.strip("/").lower())


def norm_url(u: str, base: Path) -> str:
    """A remote URL as the repository it names (Task 13 review — the Decision 38 check compared
    spellings, so `<origin>` without `.git` and `file://<origin.git>` were strangers to it). A
    local path or file:// URL is the git directory git's enter_repo would open — `<p>/.git`, `<p>`,
    `<p>.git/.git`, `<p>.git`, the first that exists — resolved; a network URL, ssh, scp-like
    (`user@host:path`, a colon before any slash) or http(s), is its host (lower-cased, no user or
    port) and path (no trailing / or .git, lower-cased), so one host/path is one origin in every
    spelling."""
    u = u.strip()
    m = NET_URL.match(u)
    if m and m.group(1).lower() != "file":
        return _net(m.group(2), m.group(3) or "")
    if u.lower().startswith("file://"):
        u = u[len("file://"):]
        if u.lower().startswith("localhost/"):
            u = u[len("localhost"):]
    else:
        m = SCP_URL.match(u)
        if m and "/" not in u.split(":", 1)[0]:
            return _net(m.group(1), m.group(2))
    p = resolve(base, u) if u else base
    for c in (p / ".git", p, Path(str(p) + ".git") / ".git", Path(str(p) + ".git")):
        if c.is_dir():
            return "local:" + str(c.resolve())
    return "local:" + str(p)


@functools.lru_cache(maxsize=2)
def target_origins(root_s: str) -> frozenset:
    """The push URLs of target/<name>'s origin and each nested repo's (Decision 38), once per guard call."""
    root, out = Path(root_s), set()
    tdir = root / "target"
    for top in (sorted(tdir.iterdir()) if tdir.is_dir() else []):
        if not (top / ".git").exists():
            continue
        for r in [top] + [top / rel for rel in v.nested_relpaths(root)]:
            code, u, _ = v.run(["git", "-C", str(r), "remote", "get-url", "--push", "--all", "origin"])
            for line in (u.splitlines() if code == 0 else []):
                if line.strip():
                    out.add(norm_url(line, r))
    return frozenset(out)


# the environment variables that change which configuration git reads (critic-fix review, finding 1)
CONFIG_ENV_KEYS = re.compile(r"^(HOME|XDG_CONFIG_HOME|GIT_CONFIG[A-Z0-9_]*)$")


def run_git(cmd: List[str], penv: Optional[Dict[str, str]] = None) -> Tuple[int, str, str]:
    """v.run, with the command's own HOME / XDG_CONFIG_HOME / GIT_CONFIG_* over the hook's environment, so a
    query reads the configuration the command would run with (critic-fix review, finding 1)."""
    env = dict(os.environ)
    env.update({k: val for k, val in (penv or {}).items() if CONFIG_ENV_KEYS.match(k)})
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=20, env=env)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.SubprocessError) as e:
        return 127, "", str(e)


def with_cfg(repo: Path, cfg: "Cfg") -> List[str]:
    """`git -C <repo>` with the command's own -c pairs, so a query sees the configuration the command runs with."""
    cmd = ["git", "-C", str(repo)]
    for k, val in getattr(cfg, "pairs", []):
        cmd += ["-c", "%s=%s" % (k, val)]
    return cmd


def destination_urls(repo: Path, word: str, cfg: "Cfg", penv: Optional[Dict[str, str]] = None) -> List[str]:
    """The URLs a push to <word> goes to: a configured remote's push URLs, else <word> as a URL
    after git's url.<base>.insteadOf rewriting (`ls-remote --get-url`), else <word> itself."""
    if "/" not in word and ":" not in word:
        code, u, _ = run_git(with_cfg(repo, cfg) + ["remote", "get-url", "--push", "--all", word], penv)
        if code == 0 and u.strip():
            return [x for x in u.splitlines() if x.strip()]
    code, u, _ = run_git(with_cfg(repo, cfg) + ["ls-remote", "--get-url", word], penv)
    return [u.strip()] if code == 0 and u.strip() else [word]


def names_target(repo: Path, word: str, cfg: "Cfg", root: Path, penv: Optional[Dict[str, str]] = None) -> bool:
    origins = target_origins(str(root.resolve()))
    return any(norm_url(u, repo) in origins for u in destination_urls(repo, word, cfg, penv))


def push_repo_option(rest: List[str]) -> Optional[str]:
    """The value of `--repo=<r>` / `--repo <r>` (or an abbreviation git accepts, `--rep`): the remote a push with
    no repository argument goes to (critic-fix review, finding 4). The last one wins, as in git."""
    val = None
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            break
        full = push_value_option(a)
        if full is not None:
            name, eq, _ = a.partition("=")
            got = wslice(a, len(name) + 1) if eq else (rest[i + 1] if i + 1 < len(rest) else None)
            if full == "--repo" and got is not None:
                val = got
            i += 1 if eq else 2
            continue
        i += 1
    return val


def push_remote(repo: Path, rest: List[str], conf: Dict[str, List[str]], cur: str) -> str:
    pos = push_positionals(rest)
    if pos:
        return pos[0]
    opt = push_repo_option(rest)
    if opt:
        return opt
    for k in ("branch.%s.pushremote" % cur, "remote.pushdefault", "branch.%s.remote" % cur):
        if conf.get(k):
            return conf[k][-1]
    return "origin"


def pushes_to_target(repo: Path, rest: List[str], root: Path, cfg: Optional["Cfg"] = None,
                     penv: Optional[Dict[str, str]] = None) -> bool:
    """Decision 38: a push, from any directory, whose destination is the target's origin (by remote or literal URL)."""
    cfg = cfg if cfg is not None else Cfg()
    pos = push_positionals(rest)
    return names_target(repo, pos[0] if pos else (push_repo_option(rest) or "origin"), cfg, root, penv)


def unwrap(seg: List[str]) -> List[str]:
    """The real command behind `env …`, `VAR=value …` and command/exec/nohup/time
    prefixes (§7.3 (4)). strips_session_variable has already judged the prefix."""
    seg = list(seg)
    while seg:
        h = seg[0]
        if h in KEYWORDS:
            seg = seg[1:]
        elif h == "env":
            i = 1
            while i < len(seg) and (seg[i].startswith("-") or ASSIGN.match(seg[i])):
                i += 2 if seg[i] in ("-u", "--unset", "-C", "--chdir") else 1
            seg = seg[i:]
        elif ASSIGN.match(h):
            seg = seg[1:]
        elif h in PREFIX_CMDS:
            seg = seg[1:]
            while seg and seg[0].startswith("-"):
                seg = seg[1:]
        else:
            break
    return seg


def substitutions(cmd: str) -> List[str]:
    """The bodies of $( … ) and ` … ` in a command (§7.3 (2)); single-quoted text
    is literal to the shell and skipped; $(( … )) is arithmetic, not a command."""
    out: List[str] = []
    i, n, single = 0, len(cmd), False
    while i < n:
        c = cmd[i]
        if single:
            single = c != "'"
            i += 1
            continue
        if c == "'":
            single = True
        elif c == "\\":
            i += 2
            continue
        elif c == "$" and cmd.startswith("$(", i) and not cmd.startswith("$((", i):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += {"(": 1, ")": -1}.get(cmd[j], 0)
                j += 1
            out.append(cmd[i + 2:j - 1])
            i = j
            continue
        elif c == "`":
            j = cmd.find("`", i + 1)
            if j == -1:
                break
            out.append(cmd[i + 1:j])
            i = j + 1
            continue
        i += 1
    return out


class Cfg(dict):
    """A git command's -c pairs by lower-cased key; `.pairs` keeps them as written (a subsection —
    a branch or remote name — is case-sensitive), `.env_keys` the keys --config-env set from a
    variable whose value the guard cannot see."""

    def __init__(self) -> None:
        super().__init__()
        self.pairs: List[Tuple[str, str]] = []
        self.env_keys: List[str] = []
        self.globals: List[str] = []     # every global option before the subcommand but -C, -c and --config-env
        self.base: Optional[Path] = None  # where git runs, after every -C


def git_parts(seg: List[str], cwd: Path, penv: Optional[Dict[str, str]] = None) -> Tuple[Path, List[str], Cfg]:
    """(repo, args, -c pairs) of one git segment: GIT_DIR / GIT_WORK_TREE in the prefix and
    --git-dir / --work-tree name the repo (Decision 38; the git directory wins, since HEAD lives
    there), -C moves it, -c k=v and --config-env k=v are collected. Options git takes with their
    value as the next word (--git-dir, --work-tree, --namespace, --super-prefix) skip it too —
    `git --git-dir <path> push` classified <path> as the subcommand (Task 13 review)."""
    cfg = Cfg()
    penv = penv or {}
    base, i = cwd, 1
    gd, wt = penv.get("GIT_DIR") or None, penv.get("GIT_WORK_TREE") or None
    while i < len(seg) and seg[i].startswith("-"):
        a = seg[i]
        name, eq, val = a.partition("=")
        if name in GIT_VALUE_OPTS and not eq:
            if i + 1 >= len(seg):
                break
            val = seg[i + 1]
            i += 2
        else:
            i += 1
        if name not in ("-C", "-c", "--config-env"):
            cfg.globals.append(name)
        if name == "-C":
            base = resolve(base, val)
        elif name in ("-c", "--config-env"):
            k, _, kv = val.partition("=")
            cfg[k.lower()] = kv
            if name == "-c":
                cfg.pairs.append((k, kv))
            else:
                cfg.env_keys.append(k.lower())
        elif name == "--git-dir":
            gd = val
        elif name == "--work-tree":
            wt = val
    cfg.base = base
    # a relative --git-dir / GIT_DIR is relative to where git runs, after every -C
    if gd:
        p = resolve(base, gd)
        repo = p.parent if p.name == ".git" else p
    elif wt:
        repo = resolve(base, wt)
    else:
        repo = base
    return repo, seg[i:], cfg


def resolve_alias(repo: Path, args: List[str], cfg: dict) -> Tuple[List[str], Optional[str]]:
    """§7.3 (3): `git <word>` through alias.<word> — the command's own `-c
    alias.<word>=…` first, then the repo's config; up to five levels. A `!` alias
    is a shell command, returned for the caller to check like any other."""
    for _ in range(5):
        if not args or args[0] in GIT_BUILTINS:
            break
        val = cfg.get("alias." + args[0].lower())
        if val is None:
            code, out, _ = v.run(["git", "-C", str(repo), "config", "--get", "alias." + args[0]])
            val = out.strip() if code == 0 else None
        if not val:
            break
        if val.startswith("!"):
            return args, val[1:] + "".join(" " + shlex.quote(a) for a in args[1:])
        try:
            args = shlex.split(val) + args[1:]
        except ValueError:
            break
    return args, None


def home_tree(root: Path, repo: Path) -> Optional[str]:
    for t in HOME_TREES:
        if under(repo, (root / t).resolve()):
            return t
    return None


def is_product_repo(root: Path, repo: Path) -> bool:
    """Daedalus's own checkout: under the home, and in none of its other repos."""
    rr = root.resolve()
    return under(repo, rr) and not any(under(repo, (rr / t).resolve()) for t in ("target", "worktrees", "state", "vault"))


def dist_verb(sub: str, rest: List[str]) -> Optional[str]:
    """The git verbs that rewrite files from somewhere else (§7.3 "Distribution
    code by every git route"; switch — Decision 14)."""
    if sub in ("apply", "am", "cherry-pick", "merge", "pull", "rebase"):
        return "git " + sub
    if sub == "stash" and rest[:1] in (["pop"], ["apply"]):
        return "git stash " + rest[0]
    if sub == "checkout" and "--" not in rest and not any(r in ("-b", "-B", "--orphan") for r in rest):
        pos = [r for r in rest if not r.startswith("-")]
        if pos:
            return "git checkout " + pos[0]
    if sub == "switch" and rest and not any(r in ("-c", "-C", "--create", "--force-create", "--orphan") for r in rest):
        return "git switch"
    if sub == "restore" and any(r in ("--source", "-s") or r.startswith(("--source=", "-s")) for r in rest):
        return "git restore --source"
    return None


RELEASE_PULL_WORDS = {"--ff-only", "-q", "--quiet"}


def release_pull(sub: str, rest: List[str], cfg: "Cfg", penv: Dict[str, str]) -> bool:
    """`git pull --ff-only` and nothing else, in Daedalus's own checkout: the one way a release reaches the home
    (PRD §5.4 "updating is `git pull`, forever"; spec §13 Q9b; plan 5 Decision 17). Any other argument, any global
    option but -C (--git-dir with --work-tree elsewhere moved the home's HEAD and wrote the files outside it — Task 9
    review, finding 2), a -c pair, --config-env or a GIT_* prefix and it is an ordinary pull. The words alone do not
    make it the release: release_origin_problem reads, as the command runs, where the pull would read from."""
    return (sub == "pull" and "--ff-only" in rest and all(r in RELEASE_PULL_WORDS for r in rest)
            and len(cfg) == 0 and not cfg.env_keys and not cfg.globals and not any(k.startswith("GIT_") for k in penv))


RELEASE_REFUSED = ("The release pull is refused: %s. A release is taken from the address this checkout itself records "
                   "for its branch, and nothing else; the operator can pull the release in a shell.")


def release_origin_problem(repo: Path) -> Optional[str]:
    """Why `git pull --ff-only` in Daedalus's own checkout would not read the release from where the checkout
    itself says it comes from, or None (Task 9 review, finding 1). Read with git's effective configuration — every
    scope, includes and insteadOf applied — against the checkout's own .git/config, which the guard's parsed routes
    cannot write (git config and git remote are refused in this checkout, and a write to a .git/config is refused
    everywhere): the branch follows its own name on a named remote, nothing outside the checkout adds a remote
    address or changes the branch's remote, the address git will fetch is the recorded one unrewritten, and no
    upload-pack or remote helper is set for that remote. A fast-forward is invisible to the §6.1 record, which
    compares the disk with HEAD, so this is the check that stands between the pull and a foreign HEAD."""
    def get(*args: str) -> List[str]:
        code, out, _ = v.run(["git", "-C", str(repo), "config"] + list(args))
        return out.splitlines() if code == 0 else []
    code, out, _ = v.run(["git", "-C", str(repo), "symbolic-ref", "--quiet", "--short", "HEAD"])
    b = out.strip()
    if code != 0 or not b:
        return RELEASE_REFUSED % "Daedalus's own checkout is not on a branch"
    remote, merge = get("--local", "--get", "branch.%s.remote" % b), get("--local", "--get", "branch.%s.merge" % b)
    if not remote or remote[0] in ("", ".") or merge != ["refs/heads/" + b]:
        return RELEASE_REFUSED % ("%s does not follow %s on its remote (branch.%s.remote is %s, branch.%s.merge is %s)"
                                  % (b, b, b, remote[0] if remote else "unset", b, merge[0] if merge else "unset"))
    r = remote[0]
    if get("--get-all", "branch.%s.remote" % b) != remote or get("--get-all", "branch.%s.merge" % b) != merge:
        return RELEASE_REFUSED % ("git settings outside this checkout change which remote or branch %s pulls from" % b)
    # the address half is one rule with `daedalus update` (update design Decision 14): core/update.py holds it
    try:
        upd = importlib.import_module("update")
        problem = upd.remote_problem(repo, r)
    except Exception as e:   # fail closed: without the rule nothing says the address is the recorded one
        return RELEASE_REFUSED % ("core/update.py, which checks the remote's address, could not be read (%s: %s)"
                                  % (type(e).__name__, e))
    return RELEASE_REFUSED % problem if problem else None


PRODUCT_WRITE = ("`git %s` changes Daedalus's own checkout, which changes only by the release pull (`git pull "
                 "--ff-only`); write a proposal instead of editing it. Reading it — status, log, diff, show — is fine.")
# Task 9 review, finding 1: the §6.1 record compares the disk with HEAD, so any command that moves the checkout's
# HEAD — or aims the release pull elsewhere — passes it. In Daedalus's own checkout a session reads; it never writes.
PRODUCT_READ = {"status", "log", "show", "diff", "blame", "annotate", "grep", "ls-files", "ls-tree", "ls-remote",
                "rev-parse", "rev-list", "describe", "shortlog", "cat-file", "show-ref", "for-each-ref", "name-rev",
                "merge-base", "whatchanged", "version", "help", "var", "check-ignore", "check-attr", "count-objects",
                "cherry", "range-diff", "diff-tree", "diff-files", "diff-index", "show-branch", "verify-commit",
                "verify-tag", "archive", "format-patch", "clone"}
FETCH_OK = {"-q", "--quiet", "-v", "--verbose", "-t", "--tags", "--no-tags", "-p", "--prune", "--all", "--dry-run"}
BRANCH_LIST = {"-a", "--all", "-r", "--remotes", "-v", "-vv", "--verbose", "--list", "-l", "--show-current", "--contains",
               "--no-contains", "--merged", "--no-merged", "--points-at", "--sort", "--format", "--color", "--no-color",
               "--column", "--no-column", "-q", "--quiet", "--abbrev", "--no-abbrev", "-i", "--ignore-case"}
BRANCH_PATTERN = {"--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at", "--sort",
                  "--format"}
CONFIG_READ = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--get-color", "--get-colorbool", "--list", "-l"}
CONFIG_SCOPED = {"--global", "--system", "-f", "--file"}
RELEASE_KEYS = re.compile(r"^(remote|branch|url|pull|submodule|http|protocol)\.|^core\.(sshcommand|gitproxy)$")


def config_writes(rest: List[str]) -> bool:
    """Whether a `git config` command writes (sets, adds, unsets, renames or edits) rather than reads."""
    names = [r.split("=", 1)[0] for r in rest]
    if any(n in CONFIG_READ for n in names) or (rest[:1] and rest[0] in ("get", "list")):
        return False
    if any(n in ("-e", "--edit") for n in names) or (rest[:1] and rest[0] in CONFIG_VERBS):
        return True
    return len(config_words(rest)) != 1 or any(n.startswith("--unset") or n in ("--add", "--replace-all",
                                                                               "--rename-section", "--remove-section")
                                               for n in names)


def config_release(rest: List[str], words: List[str], product: bool) -> Optional[str]:
    """Task 9 review, finding 1: a `git config` write in Daedalus's own checkout is refused outright; one at the global
    or system scope, or into a named file, is refused from anywhere when it sets what decides where a pull reads
    from — the remote's address, the branch it follows, an address rewrite, the transport — since those scopes
    reach Daedalus's own checkout too. Reads stay allowed everywhere."""
    if not config_writes(rest):
        return None
    if product:
        return PRODUCT_WRITE % ("config " + " ".join(words[:1])).strip()
    names = [r.split("=", 1)[0] for r in rest]
    if any(n in CONFIG_SCOPED for n in names):
        key = (words[0] if words else "").lower()
        if not words or RELEASE_KEYS.match(key):
            return ("`git config %s` is not set at that scope from here: git settings outside a checkout reach "
                    "Daedalus's own checkout too, and %s decides where its release pull reads from."
                    % (" ".join(r for r in rest if r.startswith("-")) + (" " + words[0] if words else ""),
                       words[0] if words else "an edited configuration file"))
    return None


def product_git(sub: str, rest: List[str], cfg: "Cfg", penv: Dict[str, str], repo: Path) -> Optional[str]:
    """The deny reason for one git command in Daedalus's own checkout, or None: reading git passes, the release pull
    passes when release_origin_problem finds nothing, and everything else — any command that could move HEAD, the
    index or the files, or repoint the remote — is refused (Task 9 review, finding 1)."""
    if sub == "pull" and release_pull(sub, rest, cfg, penv):
        return release_origin_problem(repo)
    d = dist_verb(sub, rest)
    if d:
        return DIST % d
    first = rest[0] if rest else ""
    if sub in PRODUCT_READ:
        return None
    if sub == "fetch":
        opts = [r.split("=", 1)[0] for r in rest if r.startswith("-")]
        if all(o in FETCH_OK for o in opts) and not any(":" in r for r in rest if not r.startswith("-")):
            return None
    elif sub == "branch":
        opts = [r.split("=", 1)[0] for r in rest if r.startswith("-")]
        pos = [r for r in rest if not r.startswith("-")]
        if all(o in BRANCH_LIST for o in opts) and (not pos or any(o in BRANCH_PATTERN for o in opts)):
            return None
    elif sub == "remote":
        if not rest or first in ("-v", "--verbose", "show", "get-url"):
            return None
    elif sub in ("stash", "worktree", "submodule", "reflog", "notes"):
        if (first in ("list", "show", "status") or (sub == "reflog" and not rest)) and not (sub == "worktree" and first != "list"):
            return None
    elif sub == "tag":
        opts = [r.split("=", 1)[0] for r in rest if r.startswith("-")]
        pos = [r for r in rest if not r.startswith("-")]
        if all(o in ("-l", "--list", "-n", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at",
                     "--sort", "--format", "--column", "--no-column") or re.fullmatch(r"-n[0-9]+", o) for o in opts) \
                and (not pos or any(o in ("-l", "--list") for o in opts)):
            return None
    label = sub + (" " + first if sub in ("remote", "stash", "worktree", "submodule", "reflog", "notes") and first else "")
    return PRODUCT_WRITE % label

# git push's long options that take a value, each with the shortest abbreviation git accepts for it (parse-options
# takes any unique prefix: `--rep` is --repo; `--re` is ambiguous with --receive-pack and --recurse-submodules).
PUSH_VALUE_LONG = {"--repo": "--rep", "--receive-pack": "--rece", "--exec": "--e", "--push-option": "--pu"}


def push_value_option(a: str) -> Optional[str]:
    """The value-taking push option a word spells (`-o`, or a long option or an abbreviation of one), or None."""
    if a == "-o":
        return "-o"
    name = a.split("=", 1)[0]
    if not name.startswith("--"):
        return None
    return next((full for full, least in PUSH_VALUE_LONG.items()
                 if full.startswith(name) and len(name) >= len(least)), None)


def push_positionals(rest: List[str]) -> List[str]:
    positionals: List[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            positionals.extend(rest[i + 1:])
            break
        if a.startswith("-"):
            i += 2 if (push_value_option(a) is not None and "=" not in a) else 1
            continue
        positionals.append(a)
        i += 1
    return positionals


def check_worktree_promote(rest: List[str], repo: Path, root: Path, ctx: dict) -> Optional[str]:
    """§7.3: `git worktree remove <state/promote/…>` and `git worktree prune` in a repo
    under the home are the prime's; a non-prime window is denied, and so is a prime
    that can be given no tree (it holds no window while the upgrade is pending, or took
    the pen without one: `refused` is set for it) — target/'s repositories are not its —
    and a prime that took the pen at a vault commit while the upgrade is pending
    (prime.json's taken_while_pending), until the upgrade finishes, as promote waits."""
    if not ctx["leases"] or not rest or home_tree(root, repo) is None:
        return None
    if rest[0] == "prune":
        hit = True
    elif rest[0] == "remove":
        scratch = (root / "state" / "promote").resolve()
        hit = any(not a.startswith("-") and under(resolve(repo, a), scratch) for a in rest[1:])
    else:
        hit = False
    if not hit:
        return None
    if ctx["prime"] and not ctx.get("refused"):
        mark = (ctx["leases"].get("prime") or {}).get("taken_while_pending")
        if not mark:
            return None
        import leaselib as ll        # only for a prime that took the pen at a commit while the upgrade was pending
        return WORKTREE_PROMOTE_WAITS % mark if ll.pending_version(root) == mark else None
    return WORKTREE_PROMOTE % (ctx["mine"] or "none")


def hooks_path(p: Path) -> bool:
    parts = p.parts
    return any(parts[i] == ".git" and parts[i + 1] == "hooks" for i in range(len(parts) - 1))


def branch_of(repo: Path) -> str:
    code, out, _ = v.run(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"])
    return out.strip() if code == 0 else ""


def check_git(seg: List[str], cwd: Path, target: Optional[Path], branch_created: bool, refused: str,
              ctx: dict, root: Path, penv: Optional[Dict[str, str]] = None) -> Tuple[Optional[str], Optional[str]]:
    """(deny reason, shell alias to check) for one git segment — every §7.3 rule,
    plus Decisions 13, 14, 33 and 38."""
    penv = penv or {}
    repo, args, cfg = git_parts(seg, cwd, penv)
    if not args:
        return None, None
    if "core.hookspath" in cfg or "core.hookspath" in penv.get("GIT_CONFIG_PARAMETERS", "").lower() or any(
            k.startswith("GIT_CONFIG_KEY_") and val.strip().lower() == "core.hookspath" for k, val in penv.items()):
        return HOOKSPATH, None
    reason = config_route(["-c " + k for k in cfg], [k for k in cfg.env_keys])
    if reason:
        return reason, None
    args, shell_alias = resolve_alias(repo, args, cfg)
    if shell_alias is not None:
        return None, shell_alias
    if not args:
        # an alias that expands to nothing (`-c 'alias.x= '`) — git refuses it; nothing to check
        return None, None
    sub, rest = args[0], args[1:]
    mine = ctx["mine"] or "<NN>"
    tree = home_tree(root, repo)
    if sub == "config":
        words = config_words(rest)
        if any(w.lower() == "core.hookspath" for w in words):
            return HOOKSPATH, None
        reason = config_route(["git config " + w.lower() for w in words], [])
        if reason:
            return reason, None
        reason = config_release(rest, words, is_product_repo(root, repo))
        if reason:
            return reason, None
        if tree is not None or (target is not None and under(repo, target)):
            reason = config_aims_at_trunk(words, trunk_names(v.target_branch(root), repo), mine)
            if reason:
                return reason, None
        return None, None
    if sub in PLUMBING_SUBS or sub.startswith("remote-"):
        # git runs no pre-push hook for these: in the home they are refused outright, and from
        # anywhere toward the target's origin (Task 13 review, measured: send-pack moved origin's trunk).
        if under(repo, root.resolve()) or any(names_target(repo, w, cfg, root, penv) for w in positionals(rest)):
            return PLUMBING % (sub, mine, mine), None
        return None, None
    if refused and sub in ("push", "commit") and under(repo, root):
        # §4.4: a session no lease names, while leases exist, fails closed —
        # the tree it would push or commit from is not known.
        return refused, None
    for a, b in DESTRUCTIVE:
        if sub == a and (b in rest or (b == "-f" and any(r.startswith("-f") for r in rest))):
            if not (sub == "checkout" and rest and rest[-1] != "."):
                return "`git %s %s` destroys work; ask the operator." % (a, b), None
    # a work tree named without a git directory: git still finds the repository from where it runs, so
    # `git -C <home> --work-tree=<elsewhere> pull` moves the home's HEAD (Task 9 review, finding 2)
    product = is_product_repo(root, repo) or (
        ("--work-tree" in cfg.globals or penv.get("GIT_WORK_TREE")) and "--git-dir" not in cfg.globals
        and not penv.get("GIT_DIR") and cfg.base is not None and is_product_repo(root, cfg.base))
    if product:
        reason = product_git(sub, rest, cfg, penv, repo)
        if reason:
            return reason, None
    elif any(v.is_protected(root, resolve(repo, r)) for r in rest if not r.startswith("-")):
        d = dist_verb(sub, rest)
        if d:
            return DIST % d, None
    norm = [long_as(r) or r for r in rest]      # Decision 33: --no-veri is --no-verify
    if sub in ("push", "commit") and ("--no-verify" in norm or (sub == "commit" and "-n" in rest)):
        return NO_VERIFY, None
    if sub == "worktree":
        return check_worktree_promote(rest, repo, root, ctx), None
    if sub not in ("push", "commit", "update-ref", "branch"):
        return None, None
    in_scope = (tree is not None or (target is not None and under(repo, target))
                or (sub == "push" and pushes_to_target(repo, rest, root, cfg, penv)))  # Decision 38
    if not in_scope:
        return None, None
    if target is None:
        # config.yaml could not be read: the trunk is unknown — fail closed in every tree of the home.
        return "config.yaml cannot be read, so the trunk is unknown; refusing `git %s` inside the target until it is fixed." % sub, None
    trunk = v.target_branch(root)
    if sub in ("update-ref", "branch"):
        # Decision 33: a trunk ref moved by hand, then pushed, is a trunk push by other means.
        names = trunk_names(trunk, repo)
        hits = [r for r in rest if r in names or (r.startswith("refs/heads/") and r[len("refs/heads/"):] in names)]
        if sub == "update-ref" and (hits or "--stdin" in rest):
            return TRUNK_REF % ("update-ref", hits[0] if hits else "a ref read from stdin", mine, mine), None
        if sub == "branch" and hits and any(r in ("-f", "--force", "-M", "-C", "-m", "-c") or long_as(r) == "--force"
                                            for r in rest):
            return TRUNK_REF % ("branch", hits[0], mine, mine), None
        up = upstream_arg(rest) if sub == "branch" else None
        if up is not None:
            short = up[len("refs/remotes/"):] if up.startswith("refs/remotes/") else up
            short = dest_name(short)
            hit = next((n for n in (short, short.split("/", 1)[-1]) if n in names), None)
            if hit:
                return UPSTREAM_TRUNK % ("--set-upstream-to " + up, hit, mine, mine), None
        return None, None
    if sub == "push":
        if tree == "state/promote":
            return SCRATCH_PUSH, None
        if any(r in ("--force", "-f") or r.startswith("--force") or r.startswith("-f") for r in norm):
            return FORCE % (mine, mine), None
        every = next((r for r in norm if r in PUSH_EVERYTHING or r in ("--prune", "-d", "--delete")), None)
        if every:
            return EVERYTHING % every, None
        bad = next((s for s in push_positionals(rest)[1:] if any(ch in s for ch in "$`{")), None)
        if bad:
            return UNPARSEABLE % bad, None
        cur = branch_of(repo)
        names = trunk_names(trunk, repo)
        for spec in push_positionals(rest)[1:]:
            hit = pattern_hits_trunk(spec, names)
            if hit:
                return PATTERN_TRUNK % (spec, hit, mine, mine), None
        # Task 13 review: the destination can come from configuration — remote.<name>.push (which
        # also maps a refspec written without a destination), remote.<name>.mirror, and for a push
        # with no refspec push.default over the branch's upstream (a window's branch is cut from
        # origin/<trunk>, so it tracks the trunk). Read as the command would run, its -c pairs included.
        conf = config_list(repo, cfg, penv)
        hp = [x for x in conf.get("core.hookspath") or [] if x.strip()]
        if hp:
            return HOOKSPATH_SET % hp[-1], None     # critic-fix review, finding 1: git would skip the pre-push hook
        remote = push_remote(repo, rest, conf, cur)
        if truthy((conf.get("remote.%s.mirror" % remote) or [""])[-1]):
            return EVERYTHING % ("%s (remote.%s.mirror is on)" % (remote, remote)), None
        specs = conf.get("remote.%s.push" % remote) or []
        for spec in specs:
            d = spec_hits_trunk(spec, names, cur, trunk)
            if d:
                return CONFIG_PUSH_TRUNK % (d, remote, mine, mine), None
        # `push origin HEAD` / `push -u origin HEAD` / `push origin @` push the
        # current branch to its same-named remote branch: resolve before comparing.
        dests = [cur if d in ("HEAD", "@") else d for d in push_destinations(rest)]
        if not push_positionals(rest)[1:] and not specs:
            mode = ((conf.get("push.default") or ["simple"])[-1]).lower()
            if mode == "matching":
                dests = [PUSH_MATCHING]
            elif mode in ("upstream", "tracking"):
                merge = conf.get("branch.%s.merge" % cur) or []
                dests = [dest_name(merge[-1])] if merge else []
            elif mode == "nothing":
                dests = []
            else:
                dests = [cur]
        if PUSH_MATCHING in dests:
            return MATCHING % (trunk, mine, mine), None
        hit = [d for d in dests if d in names]
        if hit:
            return PUSH_TRUNK % (hit[0], mine, mine), None
        return None, None
    if not branch_created:
        cur = branch_of(repo)
        if cur in trunk_names(trunk, repo):
            if tree == "target":
                own = "worktrees/%s/%s" % (ctx["mine"], repo_key(root, repo)) if ctx["mine"] else "a window's worktree"
                return COMMIT_TARGET % (cur, own), None
            return COMMIT_TRUNK % (cur, mine, mine), None
    return None, None


def repo_key(root: Path, repo: Path) -> str:
    try:
        return bh.repo_key_of(root, repo)
    except ValueError:
        return repo.name


def remote_default(repo: Path) -> str:
    """The remote's default branch as `git clone` recorded it
    (refs/remotes/origin/HEAD), or "" when it is not recorded. No network."""
    code, out, _ = v.run(["git", "-C", str(repo), "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    out = out.strip()
    return out[len("origin/"):] if code == 0 and out.startswith("origin/") else ""


def trunk_names(trunk: str, repo: Optional[Path] = None) -> set:
    """The configured trunk, the remote's default branch, and the two
    conventional names. A feature branch is never called main or master, so
    denying them costs nothing and still protects a deployment whose config
    names the wrong trunk. The remote default is there for the same reason
    with sharper teeth: the originating incident was config `main` against
    an origin whose default is `mainline` while `main` also existed there —
    doctor can only NOTE that shape (a deliberately non-default trunk looks
    identical), so the guard denies the default branch too."""
    names = {trunk, "main", "master"}
    if repo is not None:
        d = remote_default(repo)
        if d:
            names.add(d)
    return names


# push options that take a separate value argument; skipped with their value.
PUSH_VALUE_OPTS = {"--repo", "--receive-pack", "--exec", "-o", "--push-option"}
# push options that push every local branch — the trunk among them — with no
# refspec naming it; denied outright inside the target.
PUSH_EVERYTHING = {"--all", "--branches", "--mirror"}
# push_destinations' marker for the matching refspec `:` (or `+:`): every
# local branch with a same-named remote branch, which includes the trunk.
PUSH_MATCHING = ":"


def push_destinations(rest: List[str]) -> List[str]:
    """The remote-side branch names a `git push` writes to, from its refspecs.
    `push origin mainline` -> [mainline]; `push origin HEAD:mainline` and
    `push origin feature:mainline` -> [mainline]; `push -u origin fix/x` ->
    [fix/x]; `push origin +src:refs/heads/mainline` -> [mainline]. The first
    positional is the remote, every later one a refspec. Options are skipped,
    with a following value for the ones that take one as a separate word.
    A bare `git push` yields [] (the current branch is the destination —
    the caller checks that from git state)."""
    positionals = push_positionals(rest)
    dests: List[str] = []
    for spec in positionals[1:]:
        spec = spec.lstrip("+")
        if spec == ":":
            # The "matching" refspec: every local branch that already exists
            # at the remote is pushed, the trunk among them, without naming
            # it. `git push origin :` from a feature branch moved a bare
            # origin's trunk in a probe. An everything-push, like --all.
            dests.append(PUSH_MATCHING)
            continue
        if ":" in spec:
            src, spec = spec.split(":", 1)
            if not spec:
                # `fix/y:` — explicit source, same-named destination.
                spec = src
        spec = dest_name(spec)
        if spec:
            dests.append(spec)
    return dests


def dest_name(d: str) -> str:
    """The branch a push destination names: `refs/heads/x` and git's DWIM `heads/x` (it matches
    `refs/%s` first — Task 13 review, measured: `HEAD:heads/main` updated refs/heads/main) are `x`."""
    d = d.strip()
    for p in ("refs/heads/", "heads/"):
        if d.startswith(p):
            return d[len(p):]
    return d


def truthy(val: str) -> bool:
    return val.strip().lower() in ("true", "yes", "on", "1")


def config_list(repo: Path, cfg: "Cfg", penv: Optional[Dict[str, str]] = None) -> Dict[str, List[str]]:
    """Every configuration value the command would run with (`git config --list -z`, its -c pairs and its
    configuration variables included), by key; git lower-cases section and name, never a branch or remote
    subsection."""
    code, out, _ = run_git(with_cfg(repo, cfg) + ["config", "--list", "-z"], penv)
    conf: Dict[str, List[str]] = {}
    for entry in (out.split("\0") if code == 0 else []):
        if entry:
            k, _, val = entry.partition("\n")
            conf.setdefault(k, []).append(val)
    return conf


def pattern_hits_trunk(spec: str, names: set) -> Optional[str]:
    """Critic finding 3: the trunk a pattern refspec (one holding `*`) can write, or None. git maps each ref the
    source pattern matches onto the destination pattern, `*` matching any run of characters, `/` included; the
    destination can land on a trunk when the pattern matches it in any spelling git accepts (`main`,
    `heads/main`, `refs/heads/main`) — `refs/heads/x/*:refs/heads/*` (from x/main), `refs/heads/*`, `refs/*:refs/*`."""
    spec = spec.strip().lstrip("+")
    if "*" not in spec:
        return None
    src, colon, dst = spec.partition(":")
    dst = dst if colon and dst else src
    rx = re.compile("^" + ".*".join(re.escape(part) for part in dst.split("*")) + "$")
    for n in sorted(names):
        if any(rx.match(c) for c in (n, "heads/" + n, "refs/heads/" + n)):
            return n
    return None


def spec_hits_trunk(spec: str, names: set, cur: str, trunk: str) -> Optional[str]:
    """The trunk a configured push refspec can write, or None: `:` (matching) and `HEAD` on a
    trunk, a destination naming one, or a pattern whose destination can land on one (finding 3)."""
    spec = spec.strip().lstrip("+")
    if spec == ":":
        return trunk
    src, colon, dst = spec.partition(":")
    dst = dst if colon and dst else src
    if "*" in dst:
        return pattern_hits_trunk(spec, names)
    d = dest_name(dst)
    d = cur if d in ("HEAD", "@") else d
    return d if d in names else None


# `git config` options that take their value as the next word.
CONFIG_VALUE_OPTS = {"-f", "--file", "--blob", "--type", "--default", "--comment", "--value"}
CONFIG_VERBS = {"set", "unset", "get", "list", "edit", "rename-section", "remove-section"}
PUSH_SHAPING = re.compile(r"^(remote\..+\.(push|mirror|pushurl|url)|branch\..+\.(merge|remote|pushremote)|"
                          r"push\.default|remote\.pushdefault)$")
PLUMBING_SUBS = {"send-pack", "http-push"}


def config_words(rest: List[str]) -> List[str]:
    """A `git config` command's key and value words: options and their values skipped, and the
    subcommand word of the newer syntax (`git config set <key> <value>`)."""
    out: List[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a in CONFIG_VALUE_OPTS:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        out.append(a)
        i += 1
    if out and out[0] in CONFIG_VERBS:
        out = out[1:]
    return out


def config_route(keys: List[str], env_keys: List[str]) -> Optional[str]:
    """Task 13 review: configuration that switches off the pre-push hook or re-aims a push by a
    route other than core.hooksPath itself — an include (`include.path`, `includeIf.<cond>.path`),
    a push URL rewrite (`url.<base>.pushInsteadOf`), or a push-shaping key set by --config-env
    from a variable the guard cannot read. Each entry is "<how> <lower-cased key>"."""
    for k in keys:
        key = k.split(" ")[-1]
        if key.startswith(("include.", "includeif.")):
            return INCLUDE % k
        if key.startswith("url.") and key.endswith(".pushinsteadof"):
            return PUSH_REWRITE % key
    for k in env_keys:
        if PUSH_SHAPING.match(k) or (k.startswith("url.") and k.endswith("insteadof")):
            return PUSH_REWRITE % ("--config-env " + k)
    return None


def config_aims_at_trunk(words: List[str], names: set, mine: str) -> Optional[str]:
    """`git config` in a repo under the home that would send later pushes to a trunk:
    remote.<name>.push naming one (or `:`, or a wildcard mapping a name elsewhere),
    remote.<name>.mirror on, branch.<name>.merge naming one."""
    for i, w in enumerate(words):
        lw = w.lower()
        val = words[i + 1] if i + 1 < len(words) else ""
        hit = None
        if re.fullmatch(r"remote\..+\.push", lw) and val:
            hit = spec_hits_trunk(val, names, "", "every matching branch, the trunk among them")
        elif re.fullmatch(r"remote\..+\.mirror", lw) and truthy(val):
            hit = "every branch, the trunk among them"
        elif re.fullmatch(r"branch\..+\.merge", lw) and dest_name(val) in names:
            hit = dest_name(val)
        if hit:
            return CONFIG_TRUNK % (w, val, hit, mine, mine)
    return None


def upstream_arg(rest: List[str]) -> Optional[str]:
    """The upstream `git branch -u <x>` / `--set-upstream-to[=]<x>` sets, or None."""
    for i, r in enumerate(rest):
        if r in ("-u", "--set-upstream-to") and i + 1 < len(rest):
            return rest[i + 1]
        if r.startswith("--set-upstream-to="):
            return r.split("=", 1)[1]
        if r.startswith("-u") and len(r) > 2 and not r.startswith("--"):
            return r[2:]
    return None


def split_redirects(seg: List[str]) -> Tuple[List[str], List[str], bool]:
    """(redirect targets, the words with every redirect and its target removed, whether the
    last word is a bare number glued to a redirect — `cp a b 2>/dev/null` tokenizes as
    `b`, `2`, `>`, so the number may be an fd rather than an operand). `>&N` / `>&-`
    duplicate a descriptor and write no file."""
    targets: List[str] = []
    words: List[str] = []
    fd_tail = False
    i = 0
    while i < len(seg):
        t = seg[i]
        if is_redirect(t):
            nxt = seg[i + 1] if i + 1 < len(seg) else ""
            if nxt and not (t.endswith("&") and (nxt.isdigit() or nxt == "-")):
                targets.append(nxt)
            if words and words[-1].isdigit() and not t.startswith("&"):
                fd_tail = True
            i += 2
            continue
        words.append(t)
        fd_tail = False
        i += 1
    return targets, words, fd_tail


def positionals(args: List[str]) -> List[str]:
    """The operands of a file command: every word not starting with `-`, and every word after
    `--` (Claude Code project slugs all start with `-`: `rm -rf -- <slug>`)."""
    out: List[str] = []
    for i, a in enumerate(args):
        if a == "--":
            return out + list(args[i + 1:])
        if not a.startswith("-"):
            out.append(a)
    return out


PERL_INPLACE = re.compile(r"-[0aelnpsw]*i")
RECURSIVE_COPY = re.compile(r"-[A-Za-z]*[Rra]")


def tree_operands(seg: List[str]) -> Tuple[List[str], List[str]]:
    """(removed, filled): operands a command removes or renames whole (rm, unlink, mv's
    sources) and directories a recursive copy fills (cp -R/-r/-a, rsync). guard main denies
    either when it is an ancestor of the transcript directory — a write operand below it is
    write_check's; one above it replaces the record wholesale (plan 4 Task 2 review)."""
    _, words, _ = split_redirects(seg)
    if not words:
        return [], []
    head, pos = os.path.basename(words[0]), positionals(words[1:])
    if head in ("rm", "unlink"):
        return pos, []
    if head == "mv" and len(pos) >= 2:
        return pos[:-1], []
    recursive = head == "rsync" or (head == "cp" and any(
        a in ("--recursive", "--archive") or (not a.startswith("--") and RECURSIVE_COPY.match(a)) for a in words[1:]))
    if recursive and len(pos) >= 2:
        return [], [pos[-1]]
    return [], []


def write_operands(seg: List[str]) -> List[str]:
    ops, words, fd_tail = split_redirects(seg)
    seg = words
    if not seg:
        return ops
    head = os.path.basename(seg[0])     # critic-fix review, finding 3: `/bin/cp` is cp
    pos = positionals(seg[1:])
    if head == "sed" and any(t == "-i" or t.startswith("-i") for t in seg[1:]):
        ops.extend(t for t in seg[1:] if not t.startswith("-") and ("/" in t or t.endswith((".sh", ".py", ".md", ".json", ".yaml"))))
    if head == "tee":
        ops.extend(pos)
    if head in ("cp", "install", "ln", "rsync") and len(pos) >= 2:
        # the destination; when a redirect's fd number sits last it may be the fd, so the word before is taken too
        ops.append(pos[-1])
        if fd_tail and len(pos) >= 3:
            ops.append(pos[-2])
    if head == "mv" and len(pos) >= 2:
        # mv writes its destination and removes every source.
        ops.extend(pos)
    if head in ("rm", "unlink", "truncate"):
        ops.extend(pos)
    if head == "dd":
        ops.extend(wslice(t, 3) for t in seg[1:] if t.startswith("of=") and len(t) > 3)
    if head in ("cp", "mv", "install", "ln"):
        ops.extend(option_values(seg[1:], {"-t", "--target-directory"}, set()))
    if head == "ln":
        # a link made toward the transcript (or distribution code) lets a later plain write reach it (critic finding 2)
        ops.extend(pos)
    ops.extend(extra_writer_operands(head, seg))
    if head in ("perl", "ruby") and any(PERL_INPLACE.match(t) for t in seg[1:]):
        # in-place edit: every file operand; the program after -e is not one
        ops.extend(t for i, t in enumerate(seg[1:], 1) if not t.startswith("-") and seg[i - 1] not in ("-e", "-E"))
    if head == "patch":
        ops.extend(pos)
    if head in ("chmod", "chown", "chgrp", "chflags", "touch"):
        # Task 13 review: `chmod -x <T>/.git/hooks/pre-push` switched git's gate off. The mode or
        # owner word is taken too; it resolves to a name in the cwd, which no check objects to.
        ops.extend(pos)
    if head == "git" and len(seg) >= 3 and seg[1] in ("apply", "checkout") and "--" in seg:
        ops.extend(seg[seg.index("--") + 1:])
    if head in ("python3", "python", "perl", "ruby", "node", "bash", "sh") and any(t in ("-c", "-e") for t in seg):
        for t in seg[1:]:
            if len(t) > 8 and WRITE_IN_STRING.search(t):
                ops.extend(m.group(0) for m in PATHISH.finditer(t) if "/" in m.group(0) or m.group(0).endswith((".sh", ".py", ".md", ".json", ".yaml")))
    return ops


def option_values(args: List[str], spaced: set, glued_short: set) -> List[str]:
    """The values of options: `-o X` / `--output X` (spaced), `--output=X`, and `-oX` or a flag run ending in o
    (`-sSo X`) for the one-letter options in glued_short."""
    out: List[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            break
        name, eq, _ = a.partition("=")
        if a in spaced and i + 1 < len(args):
            out.append(args[i + 1])
            i += 2
            continue
        if eq and name in spaced and name.startswith("--"):
            out.append(wslice(a, len(name) + 1))
        elif a.startswith("-") and not a.startswith("--") and len(a) > 1:
            letters = a[1:]
            for k, ch in enumerate(letters):
                if ch in glued_short:
                    if k + 1 < len(letters):
                        out.append(wslice(a, k + 2))
                    elif i + 1 < len(args):
                        out.append(args[i + 1])
                        i += 1
                    break
        i += 1
    return out


def url_basename(u: str) -> str:
    return u.split("?", 1)[0].rstrip("/").rsplit("/", 1)[-1] or "index.html"


SQLITE_WRITE = re.compile(r"(?:^|\s|;)\.(?:output|once|save|backup(?:\s+\S+)?|excel)\s+['\"]?([^\s'\";]+)|"
                          r"\b(?:ATTACH(?:\s+DATABASE)?|VACUUM\s+INTO)\s+['\"]([^'\"]+)['\"]", re.I)
AWK_WRITE = re.compile(r"\bprint[f]?\b[^;}]*?(>>?|\|)\s*(\"[^\"]*\"|[^\s;}]+)")


def extra_writer_operands(head: str, seg: List[str]) -> List[str]:
    """Critic finding 2: the writers beyond redirect/sed/tee/cp/mv/rm/dd/perl -i — each file they write."""
    args = seg[1:]
    pos = positionals(args)
    ops: List[str] = []
    if head == "curl":
        ops += option_values(args, {"-o", "--output", "-D", "--dump-header", "-c", "--cookie-jar", "--trace",
                                    "--trace-ascii", "--stderr", "--libcurl", "--etag-save"}, {"o", "D", "c"})
        if any(a in ("-O", "--remote-name", "--remote-name-all") or (a.startswith("-") and not a.startswith("--")
                                                                    and "O" in a[1:]) for a in args):
            dirs = option_values(args, {"--output-dir"}, set()) or ["."]
            urls = [a for a in pos if "://" in a]
            ops += ["%s/%s" % (dirs[-1], url_basename(u)) for u in urls]
    elif head == "wget":
        ops += option_values(args, {"-O", "--output-document", "-o", "--output-file", "-a", "--append-output"},
                             {"O", "o", "a"})
        if not any(a in ("-O", "--output-document") or a.startswith(("--output-document=", "-O")) for a in args):
            dirs = option_values(args, {"-P", "--directory-prefix"}, {"P"}) or ["."]
            ops += ["%s/%s" % (dirs[-1], url_basename(u)) for u in pos if "://" in u]
    elif head in ("sort", "shuf"):
        ops += option_values(args, {"-o", "--output"}, {"o"})
    elif head == "uniq" and len(pos) >= 2:
        ops.append(pos[1])
    elif head == "sqlite3":
        dbs = [a for a in pos]
        if dbs:
            ops.append(dbs[0])
        for a in args:
            for m in SQLITE_WRITE.finditer(a):
                ops.append(m.group(1) or m.group(2))
    elif head == "patch":
        ops += option_values(args, {"-o", "--output", "-r", "--reject-file"}, {"o", "r"})
    elif head == "ditto" and len(pos) >= 2:
        ops.append(pos[-1])
    elif head == "git":
        ops += option_values(args, {"--output"}, set())
        if "format-patch" in args:
            ops += option_values(args, {"-o", "--output-directory"}, {"o"})
    elif head in ("awk", "gawk", "mawk", "nawk"):
        prog = awk_program(args)
        for m in AWK_WRITE.finditer(prog or ""):
            if m.group(1) == "|":
                continue            # a command pipe: embedded_code checks the command it runs
            t = m.group(2)
            ops.append(t[1:-1] if t.startswith('"') and t.endswith('"') else Word(DYN + t))
        if prog is not None and ("inplace" in option_values(args, {"-i", "--include"}, set())
                                 or any(a.startswith("--include=inplace") for a in args)):
            # gawk's inplace extension rewrites every file operand after the program
            ops += [a for a in args[args.index(prog) + 1:] if not a.startswith("-") and not ASSIGN.match(a)]
    # critic-fix review, finding 3: the whole-file writers the guard passed with a literal transcript path
    elif head in ("sed", "gsed"):
        for script in sed_scripts(args)[0]:
            ops += sed_parse(script)[0]
    elif head == "base64":
        ops += option_values(args, {"-o", "--output"}, {"o"})
    elif head == "openssl":
        ops += option_values(args, {"-out", "-keyout"}, set())
    elif head == "xxd":
        pos = operands_past(args, {"-c", "-cols", "-g", "-groupsize", "-l", "-len", "-s", "-seek", "-o", "-offset",
                                   "-n", "-name"})
        if len(pos) >= 2:
            ops.append(pos[1])
    elif head in ("split", "gsplit"):
        pos = operands_past(args, {"-l", "-b", "-n", "-a", "-p", "-C", "-t", "--lines", "--bytes", "--number",
                                   "--suffix-length", "--line-bytes", "--additional-suffix", "--separator"})
        ops.append(pos[1] if len(pos) >= 2 else "x")        # the prefix each piece is named after
    elif head in ("csplit", "gcsplit"):
        ops += option_values(args, {"-f", "--prefix"}, {"f"}) or ["xx"]
    elif head == "plutil":
        out = option_values(args, {"-o"}, set())
        if out:
            ops += [o for o in out if o != "-"]
        elif any(a in ("-convert", "-insert", "-replace", "-remove", "-create") for a in args) and pos:
            ops.append(pos[-1])                             # converted or edited in place
    elif head == "scp":
        pos = operands_past(args, {"-P", "-i", "-F", "-o", "-c", "-l", "-S", "-J", "-D", "-X"})
        if len(pos) >= 2 and not SCP_REMOTE.match(pos[-1]):
            ops.append(pos[-1])
    elif head == "say":
        ops += option_values(args, {"-o", "--output-file"}, {"o"})
    elif head in VIM_HEADS:
        ops += vim_code(head, args)[0]
    return ops


# ---- critic-fix review, finding 3: the whole-file writers past the finding 2 fix ----

def _sed_addr(s: str, i: int) -> int:
    n = len(s)
    if i < n and s[i].isdigit():
        while i < n and s[i].isdigit():
            i += 1
        if i < n and s[i] == "~":
            i += 1
            while i < n and s[i].isdigit():
                i += 1
    elif i < n and s[i] == "$":
        i += 1
    elif i < n and s[i] in "/\\":
        if s[i] == "\\":
            i += 1
        d = s[i] if i < n else ""
        i += 1
        while i < n and s[i] != d:
            i += 2 if s[i] == "\\" else 1
        i += 1
        while i < n and s[i] in "IM":
            i += 1
    return i


def sed_parse(s: str) -> Tuple[List[str], bool]:
    """(the files a sed script writes — its w and W commands and the s///w flag, each file named to the end of its
    line —, whether it runs a command: GNU's e command or the s///e flag)."""
    targets: List[str] = []
    runs = False
    i, n = 0, len(s)

    def eol(j: int) -> int:
        k = s.find("\n", j)
        return n if k < 0 else k
    while i < n:
        c = s[i]
        if c in " \t\n;{}":
            i += 1
            continue
        if c == "#":
            i = eol(i)
            continue
        i = _sed_addr(s, i)
        while i < n and s[i] in " \t":
            i += 1
        if i < n and s[i] == ",":
            i += 1
            while i < n and s[i] in " \t":
                i += 1
            if i < n and s[i] in "+~":
                i += 1
                while i < n and s[i].isdigit():
                    i += 1
            else:
                i = _sed_addr(s, i)
        while i < n and s[i] in " \t!":
            i += 1
        if i >= n:
            break
        cmd = s[i]
        i += 1
        if cmd in "wW":
            e = eol(i)
            if s[i:e].strip():
                targets.append(s[i:e].strip())
            i = e
        elif cmd == "e":
            runs = True
            i = eol(i)
        elif cmd in "aic":
            e = eol(i)
            while e < n and s[e - 1] == "\\":
                e = eol(e + 1)
            i = e
        elif cmd in "rR:":
            i = eol(i)
        elif cmd in "btTv":
            ends = [k for k in (s.find(";", i), s.find("\n", i)) if k >= 0]
            i = min(ends) if ends else n
        elif cmd in "sy":
            if i >= n:
                break
            d = s[i]
            i += 1
            for _ in range(2):
                while i < n and s[i] != d:
                    i += 2 if s[i] == "\\" else 1
                i += 1
            while cmd == "s" and i < n and s[i].isalnum():
                f = s[i]
                i += 1
                if f == "e":
                    runs = True
                if f == "w":
                    e = eol(i)
                    if s[i:e].strip():
                        targets.append(s[i:e].strip())
                    i = e
                    break
        elif cmd in "qQlL":
            while i < n and s[i] in " \t0123456789":
                i += 1
        elif cmd not in "=dDgGhHnNpPxzF":
            break          # not a sed command: sed refuses the script and writes nothing
    return targets, runs


def sed_scripts(args: List[str]) -> Tuple[List[str], List[str]]:
    """(every script a sed command may run — its -e values, else its first operand read both as GNU sed reads it and
    as BSD sed does, whose bare -i takes the next word as a suffix —, the scripts GNU sed would run: only GNU sed has
    the e command)."""
    exprs: List[str] = []
    firsts: Dict[str, Optional[str]] = {}
    for flavor in ("gnu", "bsd"):
        i, pos = 0, []
        while i < len(args):
            a = args[i]
            if a == "--":
                pos += args[i + 1:]
                break
            if a in ("-e", "--expression", "-f", "--file"):
                if flavor == "gnu" and a in ("-e", "--expression") and i + 1 < len(args):
                    exprs.append(args[i + 1])
                i += 2
                continue
            if a.startswith("--"):
                if flavor == "gnu" and a.startswith("--expression="):
                    exprs.append(wslice(a, len("--expression=")))
                i += 1
                continue
            if a.startswith("-") and len(a) > 1:
                letters = a[1:]
                k = next((j for j, ch in enumerate(letters) if ch in "ef"), None)
                if k is not None:
                    val = letters[k + 1:] or (args[i + 1] if i + 1 < len(args) else "")
                    if flavor == "gnu" and letters[k] == "e":
                        exprs.append(wslice(a, k + 2) if letters[k + 1:] else val)
                    i += 1 if letters[k + 1:] else 2
                    continue
                i += 2 if (flavor == "bsd" and a in ("-i", "-I")) else 1
                continue
            pos.append(a)
            i += 1
        firsts[flavor] = pos[0] if pos else None
    if exprs:
        return exprs, exprs
    return [x for x in (firsts["gnu"], firsts["bsd"]) if x is not None], [x for x in (firsts["gnu"],) if x is not None]


VIM_HEADS = {"vi", "vim", "nvim", "ex", "view", "rvim", "rview", "vimdiff", "gvim", "mvim", "evim"}
# the ex commands a scripted vim may run from here, each with the shortest abbreviation vim accepts; every other
# command (edit, set, source, normal, !, redir, let, call, execute …) can write anywhere or run anything.
EX_EDIT = {"substitute": "s", "&&": "&&", "&": "&", "~": "~", "delete": "d", "global": "g", "vglobal": "v",
           "quit": "q", "qall": "qa", "quitall": "quita", "cquit": "cq", "sort": "sor", "retab": "ret", "join": "j",
           "move": "m", "copy": "co", "t": "t", "print": "p", "number": "nu", "#": "#", "=": "=", ">": ">", "<": "<",
           "left": "le", "right": "ri", "center": "ce", "yank": "y", "put": "pu", "undo": "u", "redo": "red",
           "read": "r", "nohlsearch": "noh"}
EX_WRITE = {"write": "w", "wq": "wq", "xit": "x", "exit": "exi", "update": "up", "wall": "wa", "wqall": "wqa",
            "xall": "xa", "saveas": "sav", "file": "f"}
EX_RANGE = re.compile(r"^(?:\s|:|\d+|[.$%,;]|'[A-Za-z<>\[\]]|/(?:\\.|[^/\\])*/?|\?(?:\\.|[^?\\])*\??|[+-]\d*)*")


def _ex_name(word: str, table: Dict[str, str]) -> Optional[str]:
    return next((full for full, least in table.items() if full.startswith(word) and len(word) >= len(least)), None)


def ex_parse(cmd: str, depth: int = 0) -> Tuple[List[str], bool]:
    """(the files an ex command line writes, whether it holds a command the guard does not read)."""
    targets: List[str] = []
    for part in re.split(r"(?<!\\)\|", cmd):
        part = part[EX_RANGE.match(part).end():]
        m = re.match(r"[A-Za-z]+|&&|[&~#=<>]", part)
        if not m:
            if part.strip():
                return targets, True
            continue
        word, rest = m.group(0), part[m.end():]
        name = _ex_name(word, EX_EDIT)
        if name is not None:
            if name in ("global", "vglobal"):
                body = rest.lstrip("!").lstrip()
                if body:
                    d, j = body[0], 1
                    while j < len(body) and body[j] != d:
                        j += 2 if body[j] == "\\" else 1
                    inner, more = ex_parse(body[j + 1:], depth + 1) if depth < 3 else ([], True)
                    targets += inner
                    if more:
                        return targets, True
                continue
            if (name in ("substitute", "&", "&&", "~") and "\\=" in rest) or (name == "put" and "=" in rest) \
                    or (name == "read" and rest.lstrip("!").lstrip().startswith("!")):
                return targets, True
            continue
        name = _ex_name(word, EX_WRITE)
        if name is None:
            return targets, True
        rest = rest[1:] if rest.startswith("!") else rest
        rest = re.sub(r"\+\+\S+", "", rest).strip()
        if rest.startswith("!"):
            return targets, True          # `w !cmd` pipes the buffer into a shell command
        rest = rest[2:].strip() if rest.startswith(">>") else rest
        if rest:
            if any(ch in rest for ch in "%#<`$") or rest.startswith("="):
                return targets, True
            targets.append(rest)
    return targets, False


def vim_code(head: str, args: List[str]) -> Tuple[List[str], bool]:
    """(the files a scripted vim writes — its file operands, a file its commands write, -i/-w/-W/-V/--startuptime
    files —, whether it runs something the guard does not read: a command outside EX_EDIT/EX_WRITE, -S or a -s
    script, a vimrc other than NONE, --remote-*)."""
    cmds: List[str] = []
    targets: List[str] = []
    ex_mode = head == "ex"
    i = 0
    while i < len(args):
        a = args[i]
        nxt = args[i + 1] if i + 1 < len(args) else ""
        if a == "--":
            targets += args[i + 1:]
            break
        if a.startswith("+"):
            c = a[1:]
            if c and not c.isdigit() and not c.startswith("/"):
                cmds.append(c)
            i += 1
            continue
        if a.startswith("--"):
            name, eq, val = a.partition("=")
            if name in ("--cmd", "--startuptime"):
                (cmds if name == "--cmd" else targets).append(val if eq else nxt)
                i += 1 if eq else 2
                continue
            if name.startswith("--remote"):
                return targets, True          # sends keys or an expression to another vim
            i += 1
            continue
        if a.startswith("-") and len(a) > 1:
            letters, took = a[1:], 1
            for k, ch in enumerate(letters):
                rest = letters[k + 1:]
                if ch in "eE":
                    ex_mode = True
                    continue
                if ch == "s" and ex_mode:
                    continue
                if ch in "cSsuUiwWTtq":
                    val = rest or nxt
                    took = 1 if rest else 2
                    if ch == "c":
                        cmds.append(val)
                    elif ch in "Ss" or (ch in "uU" and val not in ("NONE", "NORC", "DEFAULTS")):
                        return targets, True
                    elif (ch == "i" and val != "NONE") or (ch in "wW" and not val.isdigit()):
                        targets.append(val)
                    break
                if ch == "V":
                    f = rest.lstrip("0123456789")
                    if f:
                        targets.append(f)
                    break
            i += took
            continue
        targets.append(a)
        i += 1
    for c in cmds:
        more, bad = ex_parse(c)
        targets += more
        if bad:
            return targets, True
    return targets, False


AWK_STR = r'"((?:[^"\\\n]|\\.)*)"'


def _unescape(s: str) -> str:
    return re.sub(r"\\(.)", r"\1", s)


def awk_commands(prog: str) -> Tuple[List[str], bool]:
    """(the shell commands an awk program runs — system("…"), print … | "…", "…" | getline, each a literal string
    —, whether it runs one the guard cannot read: a command built from a variable or by concatenation)."""
    lits: List[str] = []
    body = re.sub(AWK_STR, lambda m: "\0%d\0" % (lits.append(m.group(1)) or len(lits) - 1), prog)
    # regular expression literals, which may hold `|`, after an operator or at the start of a pattern
    body = re.sub(r"(^|[(~,{;!&|]\s*)/(?:\\.|[^/\\\n])*/", r"\1R", body)
    cmds: List[str] = []
    bad = False
    for m in re.finditer(r"\bsystem\s*\(\s*", body):
        mm = re.match(r"\0(\d+)\0\s*\)", body[m.end():])
        if mm:
            cmds.append(_unescape(lits[int(mm.group(1))]))
        else:
            bad = True
    for m in re.finditer(r"(?<!\|)\|&?(?!\|)\s*", body):
        after = body[m.end():]
        if after.startswith("getline"):
            mm = re.search(r"\0(\d+)\0\s*$", body[:m.start()])
            if mm:
                cmds.append(_unescape(lits[int(mm.group(1))]))
            else:
                bad = True
            continue
        mm = re.match(r"\0(\d+)\0", after)
        if mm:
            cmds.append(_unescape(lits[int(mm.group(1))]))
        else:
            bad = True
    return cmds, bad


OSA_WRITE = re.compile(r"\bopen\s+for\s+access\b|\bwrite\b|\bsave\b|\bduplicate\b|\bmove\b|\bmake\s+new\s+file\b|"
                       r"\bdelete\b|writeToFile|NSFileManager|createFileAtPath|\$\.system",
                       re.I)


def osascript_commands(args: List[str]) -> Tuple[List[str], bool]:
    """(the shell commands `osascript -e …` runs through do shell script / doShellScript, each a literal string —,
    whether its code runs one the guard cannot read or writes a file itself)."""
    code = "\n".join(args[i + 1] for i, a in enumerate(args[:-1]) if a == "-e")
    cmds: List[str] = []
    bad = bool(OSA_WRITE.search(code))
    for m in re.finditer(r"\bdo\s+shell\s+script\s+", code, re.I):
        mm = re.match(AWK_STR + r"[ \t]*(?=$|\n|\)|with\b|user\b|password\b|administrator\b|altering\b|--)",
                      code[m.end():])
        if mm:
            cmds.append(_unescape(mm.group(1)))
        else:
            bad = True
    for m in re.finditer(r"doShellScript\s*\(\s*", code):
        mm = re.match(r"(['\"])((?:(?!\1)[^\\]|\\.)*)\1\s*\)", code[m.end():])
        if mm:
            cmds.append(_unescape(mm.group(2)))
        else:
            bad = True
    return cmds, bad


def awk_program(args: List[str]) -> Optional[str]:
    """awk's inline program: the first operand, past -F / -v / -f values (none when -f names a program file)."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-f", "--file"):
            return None
        if a in ("-F", "-v", "--assign", "--field-separator", "-i", "--include", "-l", "--load"):
            i += 2
            continue
        if a == "--":
            return args[i + 1] if i + 1 < len(args) else None
        if a.startswith("-") and len(a) > 1:
            i += 1
            continue
        return a
    return None


def embedded_code(seg: List[str]) -> Tuple[List[str], Optional[str]]:
    """(the shell commands a writer runs from its own code — checked like any command —, or the name of a language
    whose code runs or writes what the guard cannot read): awk's system() and pipes, osascript's do shell script,
    sed's e command, a scripted vim's commands and -S/-s scripts (critic-fix review, finding 3)."""
    _, words, _ = split_redirects(seg)
    if not words:
        return [], None
    head, args = os.path.basename(words[0]), words[1:]
    if head in ("awk", "gawk", "mawk", "nawk"):
        cmds, bad = awk_commands(awk_program(args) or "")
        return cmds, ("awk" if bad else None)
    if head == "osascript":
        cmds, bad = osascript_commands(args)
        return cmds, ("AppleScript" if bad else None)
    if head in ("sed", "gsed"):
        _, gnu = sed_scripts(args)
        return [], ("sed" if any(sed_parse(s)[1] for s in gnu) else None)
    if head in VIM_HEADS:
        return [], ("vim" if vim_code(head, args)[1] else None)
    if head == "split":
        f = option_values(args, {"--filter"}, set())
        return f, None
    return [], None


def operands_past(args: List[str], value_opts: set) -> List[str]:
    """The operands of a command whose options in value_opts take the next word as their value."""
    out: List[str] = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return out + list(args[i + 1:])
        if a.startswith("-") and len(a) > 1:
            i += 2 if (a in value_opts and "=" not in a) else 1
            continue
        out.append(a)
        i += 1
    return out


SCP_REMOTE = re.compile(r"^(?:scp://|(?:[^@/:]+@)?[^/:]+:)")


def fill_dirs(seg: List[str], here: Path) -> List[str]:
    """Critic finding 2: the directories an extraction fills with files the archive names — tar -x (its -C or the
    cwd), unzip (-d or the cwd), ditto's destination, cpio -i (the cwd) — and, for tar -c/-r/-u, the archive."""
    _, words, _ = split_redirects(seg)
    if not words:
        return []
    head, args = os.path.basename(words[0]), words[1:]
    if head in ("tar", "gtar", "bsdtar"):
        letters = ""
        for i, a in enumerate(args):
            if a.startswith("--"):
                continue
            if a.startswith("-") or (i == 0 and a.isalpha()):
                letters += a.lstrip("-")
        longs = {a.split("=", 1)[0] for a in args if a.startswith("--")}
        extract = "x" in letters or longs & {"--extract", "--get"}
        create = any(ch in letters for ch in "cru") or longs & {"--create", "--append", "--update"}
        out: List[str] = []
        if extract:
            out += option_values(args, {"-C", "--directory", "--cd"}, {"C"}) or ["."]
        if create:
            files = option_values(args, {"-f", "--file"}, {"f"})
            first = args[0] if args and not args[0].startswith("-") and args[0].isalpha() else ""
            if "f" in first and len(args) > 1:
                files.append(args[1])
            out += files
        return out
    if head == "unzip" and not any(a in ("-l", "-p", "-t", "-v", "-Z", "-z") for a in args):
        return option_values(args, {"-d"}, set()) or ["."]
    if head == "cpio" and any(a.startswith("-") and not a.startswith("--") and "i" in a[1:] for a in args):
        return ["."]
    return []


def code_write(head: str, code: str) -> Tuple[List[str], Optional[str]]:
    """(the literal paths inline code writes, why its targets cannot be read — or None). Python is parsed:
    open()/io.open() in a write mode, pathlib's write_text/write_bytes/open/touch/unlink/rename/replace/symlink_to/
    hardlink_to on Path('<literal>'), shutil copy/move, os rename/replace/link/symlink/remove/unlink/truncate/open.
    A target that is not a string literal cannot be read. perl, ruby and node are not parsed: code there that
    opens a file for writing, renames, links or removes one cannot be read (critic finding 2)."""
    if head in ("python", "python3"):
        try:
            tree = ast.parse(code)
        except SyntaxError:
            return [], ("Python" if WRITE_IN_STRING.search(code) else None)
        lits: List[str] = []
        unread = False

        def target(node: Optional[ast.AST]) -> None:
            nonlocal unread
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                lits.append(node.value)
            else:
                unread = True

        def name(f: ast.AST) -> str:
            if isinstance(f, ast.Name):
                return f.id
            if isinstance(f, ast.Attribute):
                return name(f.value) + "." + f.attr
            if isinstance(f, ast.Call):
                return name(f.func) + "()"
            return "?"
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            fn = name(node.func)
            args = list(node.args)
            kw = {k.arg: k.value for k in node.keywords}
            last = fn.rsplit(".", 1)[-1]
            if fn in ("open", "io.open", "codecs.open") or (last == "open" and fn.endswith("Path().open")):
                mode = args[1] if len(args) > 1 and fn in ("open", "io.open", "codecs.open") else (
                    args[0] if args and fn.endswith("Path().open") else kw.get("mode"))
                writes = not (isinstance(mode, ast.Constant) and isinstance(mode.value, str)
                              and not any(ch in mode.value for ch in "wax+")) and mode is not None
                if writes:
                    if fn.endswith("Path().open"):
                        inner = node.func.value if isinstance(node.func, ast.Attribute) else None
                        target(inner.args[0] if isinstance(inner, ast.Call) and inner.args else None)
                    else:
                        target(args[0] if args else kw.get("file"))
            elif fn.endswith("Path()." + last) and last in ("write_text", "write_bytes", "touch", "unlink", "rename",
                                                              "replace", "symlink_to", "hardlink_to", "mkdir", "chmod",
                                                              "rmdir"):
                inner = node.func.value if isinstance(node.func, ast.Attribute) else None
                target(inner.args[0] if isinstance(inner, ast.Call) and inner.args else None)
                if last in ("rename", "replace"):
                    target(args[0] if args else None)
            elif last in ("write_text", "write_bytes") :
                unread = True           # a Path the code built: its value is not a literal
            elif fn in ("shutil.copy", "shutil.copy2", "shutil.copyfile", "shutil.copytree", "shutil.move",
                        "os.rename", "os.replace", "os.link", "os.symlink"):
                target(args[1] if len(args) > 1 else kw.get("dst"))
                if fn in ("shutil.move", "os.rename", "os.replace"):
                    target(args[0] if args else kw.get("src"))
                if fn == "os.symlink":
                    target(args[0] if args else kw.get("src"))
            elif fn in ("os.remove", "os.unlink", "os.truncate", "os.rmdir", "os.removedirs", "shutil.rmtree",
                        "os.chmod", "os.chown", "os.utime", "os.open", "os.mkfifo"):
                target(args[0] if args else kw.get("path"))
        return lits, ("Python" if unread else None)
    shapes = {"perl": r"\bopen\s*\(?[^;]*?['\"]\s*\+?[>|]|\bsysopen\b|\b(?:rename|unlink|link|symlink|truncate)\b|"
                      r"\b(?:copy|move)\s*\(",
              "ruby": r"\b(?:File|IO)\.(?:write|open|rename|symlink|link|delete|unlink|truncate|binwrite)\b|FileUtils\.",
              "node": r"\bfs(?:\.promises)?\.\w*(?:[Ww]rite|[Aa]ppend|[Cc]opy|[Rr]ename|[Ss]ymlink|[Ll]ink|[Uu]nlink|"
                      r"[Tt]runcate|[Rr]m|[Oo]pen|createWriteStream)"}
    rx = shapes.get(head)
    if rx and re.search(rx, code):
        return [], head
    return [], None


def interpreter_code(seg: List[str]) -> Optional[str]:
    """The inline program of `python3 -c …`, `perl -e …` (and -E, -ne, -pe …), `ruby -e …`, `node -e …`."""
    for i, t in enumerate(seg[1:-1], 1):
        if t in ("-c", "-e", "-E") or (t.startswith("-") and not t.startswith("--") and t[-1] in "eE"
                                        and os.path.basename(seg[0]) in ("perl", "ruby")):
            return seg[i + 1]
    return None


def strips_session_variable(seg: List[str]) -> bool:
    """`env -u VAR`, `env -i`, `unset VAR`, `VAR=` / `VAR=""` prefixes over a
    session variable (spec §4.4 step 4 — the speed bump)."""
    if not seg:
        return False
    if seg[0] == "env":
        for i, a in enumerate(seg):
            if a in ("-i", "--ignore-environment"):
                return True
            if a in ("-u", "--unset") and i + 1 < len(seg) and STRIP_VARS.match(seg[i + 1]):
                return True
            if a.startswith("-u") and len(a) > 2 and STRIP_VARS.match(a[2:]):
                return True
        return False
    # rstrip(";"): tokenize() now splits a glued `;` off the word; kept for a token that still carries one
    if seg[0] == "unset":
        return any(STRIP_VARS.match(a.rstrip(";")) for a in seg[1:])
    if "=" in seg[0]:
        name, val = seg[0].split("=", 1)
        return bool(STRIP_VARS.match(name)) and val.rstrip(";") in ("", '""', "''")
    return False


def check_vault_git(args: List[str], repo: Path, vault: Path, ctx: dict) -> Optional[str]:
    """§4.7, in this order: a non-prime's `commit`/`push` under vault/ names the
    prime's window number (and, for commit, the vault-commit.sh rule); then raw
    `add`/`commit`/`stash` under vault/ from every session, prime included and
    with no lease files at all, names core/vault-commit.sh."""
    if not args or not under(repo, vault):
        return None
    sub = args[0]
    non_prime = bool(ctx["leases"]) and not ctx["prime"]
    if sub in ("commit", "push") and non_prime:
        text = NOT_PRIME % (ctx["mine"] or "none", ctx["prime_nn"] or "none")
        return text + " " + VAULT_RULE if sub == "commit" else text
    if sub in ("add", "commit", "stash"):
        return VAULT_RULE
    return None


def transcript_ancestor(root: Path, p: Path, filled: bool) -> Optional[str]:
    """§7.4 above the transcript directory: removing or renaming an ancestor of it (`rm -rf
    ~/.claude/projects`, `mv ~/.claude/projects x`) takes the record with it; a recursive
    copy onto one (`cp -R fake/ ~/.claude/projects/`) can replace it. The home directory and
    what is above it are not refused as a copy destination — `cp -R x ~/` is ordinary."""
    import transcriptlib as tl
    home = Path(os.path.expanduser("~")).resolve()
    for d in tl.transcript_dirs(root):
        if d != p and under(d, p):
            if filled and (p == home or under(home, p)):
                continue
            return bh.TRANSCRIPT_DENY
    return None


REMOVE_OTHER = "That is window %s's worktree; only that window (or `core/lease.sh release --remove`) may remove it."


def other_worktrees(root: Path, ctx: dict) -> List[Tuple[str, Path]]:
    """Every other window's worktree directory on disk — worktrees/<NN>/<repo> and each nested
    repo under it — as (NN, path). No git: a listing of worktrees/<NN>/ per lease."""
    wts = (root / "worktrees").resolve()
    out: List[Tuple[str, Path]] = []
    for nn in sorted(ctx["leases"]):
        if nn in ("prime", ctx["mine"]):
            continue
        try:
            children = sorted(c for c in (wts / nn).iterdir() if c.is_dir())
        except OSError:
            continue
        for c in children:
            out.append((nn, c))
            out.extend((nn, c / n) for n in v.nested_relpaths(root) if (c / n).is_dir())
    return out


def check_worktree_remove(args: List[str], repo_dir: Path, root: Path, ctx: dict) -> Optional[str]:
    """§3.1: `git worktree remove <path>` of another window's worktree is denied. The operand
    is resolved against repo_dir — the `-C` directory git runs in, not the shell's cwd — and
    a relative operand is ALSO matched the way git matches it first: as a path suffix of every
    registered worktree (worktree.c find_worktree_by_suffix; measured 2026-09-26: `git -C
    worktrees/01/thing worktree remove 02/thing` removed window 02's worktree while the path
    it resolves to does not exist)."""
    if args[:2] != ["worktree", "remove"] or not ctx["mine"]:
        return None
    wts = (root / "worktrees").resolve()
    others: Optional[List[Tuple[str, Path]]] = None
    for a in args[2:]:
        if a.startswith("-"):
            continue
        p = resolve(repo_dir, a)
        if under(p, wts):
            parts = p.relative_to(wts).parts
            if parts and parts[0] != ctx["mine"]:
                return REMOVE_OTHER % parts[0]
        if not os.path.isabs(os.path.expanduser(a)):
            if others is None:
                others = other_worktrees(root, ctx)
            suffix = "/" + a.rstrip("/")
            for nn, wp in others:
                if str(wp).endswith(suffix):
                    return REMOVE_OTHER % nn
    return None


def unparseable(cmd: str, cwd: Path, g: "G") -> Optional[str]:
    """A command shlex cannot tokenize even with heredoc bodies gone (a quote the shell leaves
    open): the redirect and -i operands the regex finds get the FULL write check, not
    is_protected alone — the lease-era denials have no Stop backstop for hot.md or the
    prime's checkout."""
    for m in re.finditer(r">>?\|?\s*([^\s;&|<>]+)", cmd):
        t = m.group(1).strip("'\"")
        if re.search(r"[$`*?\[{]", t) and not re.fullmatch(r"(?:\$\{?(?:HOME|CLAUDE_CONFIG_DIR)\}?)?[A-Za-z0-9_./~-]*", t):
            return WRITE_UNREADABLE % t      # critic finding 2: a target the shell fills in or expands
    for m in re.finditer(r"(?:>>?|\s-i(?:\s+\S+)?\s)\s*([A-Za-z0-9_./~-]+)", cmd):
        p = resolve(cwd, m.group(1))
        reason, _ = bh.write_check(g.root, g.ctx, p, g.sid, g.refused)
        if reason:
            return reason
        if hooks_path(p):
            return HOOKS_WRITE % m.group(1)
        if v.is_protected(g.root, p):
            return "%s is distribution code; write a proposal instead of editing it." % p
    return None


class G:
    """What one guard invocation knows: the home, the one locked lease read, the
    session's tree (or None when config.yaml is unreadable), the refusal
    sentence for an unbindable session, the session id."""

    def __init__(self, root: Path, ctx: dict, target: Optional[Path], refused: str, sid: Optional[str]) -> None:
        self.root, self.ctx, self.target, self.refused, self.sid = root, ctx, target, refused, sid


SHELL_C = re.compile(r"-[A-Za-z]*c[A-Za-z]*")   # `-c`, and a flag run carrying it (`-ec`, `-lc`)


def shell_inner(seg: List[str]) -> Optional[str]:
    """The command string of `bash -c '…'` (or `-ec`, `-lc`), or None. Options before it are
    skipped with their values (`bash -o errexit -c …` — Task 13 review)."""
    i = 1
    while i < len(seg) - 1:
        t = seg[i]
        if t in SHELL_VALUE_OPTS:
            i += 2
            continue
        if not t.startswith(("-", "+")):
            return None
        if SHELL_C.fullmatch(t):
            return seg[i + 1]
        i += 1
    return None


def shell_reads_stdin(seg: List[str]) -> bool:
    """A shell with no -c string and no script file — or with -s — runs what its input says:
    `echo '…' | bash`, `bash <<< '…'`, a heredoc (Task 13 review)."""
    i, s_flag = 1, False
    while i < len(seg):
        t = seg[i]
        if t in SHELL_VALUE_OPTS:
            i += 2
            continue
        if t.startswith("<"):
            i += 2 if t in ("<", "<<", "<<<", "<<-") else 1
            continue
        if t.startswith(("-", "+")):
            if SHELL_C.fullmatch(t):
                return False
            s_flag = s_flag or (not t.startswith("--") and "s" in t[1:])
            i += 1
            continue
        return s_flag
    return True


def herestrings(seg: List[str]) -> List[str]:
    out: List[str] = []
    for i, t in enumerate(seg):
        if t == "<<<" and i + 1 < len(seg):
            out.append(seg[i + 1])
        elif t.startswith("<<<") and len(t) > 3:
            out.append(t[3:])
    return out


def is_git_word(b: str) -> bool:
    return b == "git" or (b.startswith("git-") and len(b) > 4)


def git_argv(run: List[str]) -> List[str]:
    """`git …` from `/usr/bin/git …` or the dashed form `git-send-pack …`."""
    b = os.path.basename(run[0])
    return ["git"] + run[1:] if b == "git" else ["git", b[4:]] + run[1:]


# what write_operands knows how to read, found behind a wrapper (`sudo chmod -x …`)
WRITE_HEADS = {"sed", "tee", "cp", "install", "ln", "rsync", "mv", "rm", "unlink", "truncate", "dd", "perl", "ruby",
               "patch", "chmod", "chown", "chgrp", "chflags", "touch", "curl", "wget", "sort", "shuf", "uniq", "sqlite3",
               "ditto", "awk", "gawk", "mawk", "nawk", "tar", "gtar", "bsdtar", "unzip", "cpio", "gsed", "base64",
               "openssl", "xxd", "split", "gsplit", "csplit", "gcsplit", "plutil", "scp", "say", "osascript"} | VIM_HEADS


def exec_index(seg: List[str], heads: set) -> int:
    """Where the command a segment runs begins: 0, or — behind a command that runs another
    (sudo, nice, timeout, xargs, find -exec, flock …) — the first word naming one of `heads`
    (Task 13 review: `seg[0] == "git"` saw none of them). Data commands (`echo git push …`) and
    git itself are never searched."""
    head = os.path.basename(seg[0])
    if head in DATA_HEADS or is_git_word(head) or head in heads:
        return 0
    for i in range(1, len(seg)):
        b = os.path.basename(seg[i])
        if b in heads or (is_git_word(b) and "git" in heads):
            return i
    return 0


WATCH_VALUE_OPTS = {"-n", "--interval", "-q", "--equexit"}


def watch_inner(seg: List[str]) -> Optional[str]:
    """`watch [options] <command…>` runs its words through `sh -c`."""
    i = 1
    while i < len(seg) and seg[i].startswith("-"):
        i += 2 if seg[i] in WATCH_VALUE_OPTS else 1
    return " ".join(seg[i:]) if i < len(seg) else None


RUN_HEADS = SHELLS | INTERPRETERS | {"git", "eval"}
# Commands that run another command from their words (critic finding 1): a word the shell fills in there could be git.
RUNNERS = {"sudo", "doas", "su", "runuser", "nice", "ionice", "renice", "timeout", "gtimeout", "xargs", "parallel", "watch",
           "stdbuf", "flock", "caffeinate", "nohup", "setsid", "chronic", "taskset", "chrt", "unbuffer", "script", "time",
           "command", "exec", "builtin", "env", "arch", "sandbox-exec", "strace", "ltrace", "dtruss", "valgrind", "entr",
           "retry", "sem", "find"}
FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
# A cwd the guard cannot know (`cd "$D"`): a git command run there cannot be placed in a repository.
UNKNOWN_CWD = Path("/" + DYN + "unknown-cwd")
# git subcommands whose -m / --message value is a message, never an option or a ref.
MESSAGE_SUBS = {"commit", "tag", "notes", "stash", "merge"}
MESSAGE_CLUSTER = re.compile(r"^-[A-Za-z]*m$")


def env_splits(seg: List[str]) -> bool:
    """`env -S …` / `env --split-string …` (or a flag run carrying S) anywhere in the segment's env words."""
    for i, t in enumerate(seg):
        if os.path.basename(t) != "env":
            continue
        j = i + 1
        while j < len(seg) and (seg[j].startswith("-") or ASSIGN.match(seg[j])):
            a = seg[j]
            if a.startswith("--split-string") or (a.startswith("-") and not a.startswith("--") and "S" in a[1:]):
                return True
            j += 2 if a in ("-u", "--unset", "-C", "--chdir") else 1
    return False


def runner_unresolved(seg: List[str]) -> Optional[str]:
    """A word the shell fills in, in a command that runs another from its words — it could be git."""
    head = os.path.basename(seg[0])
    if head not in RUNNERS:
        return None
    words = seg[1:]
    if head == "find":
        idx = next((i for i, t in enumerate(words) if t in FIND_EXEC), None)
        words = words[idx + 1:] if idx is not None else []
    return next((t for t in words if unresolved(t)), None)


def git_unreadable(gseg: List[str], prefix: List[str], here: Path, penv: Dict[str, str]) -> Optional[str]:
    """Critic finding 1: every word that reaches git must be literal — the words before it (VAR= prefixes, a
    wrapper's), git's own options and their values, the subcommand, and each argument — or the command is denied.
    Two places may hold a word the shell fills in, since neither can move a ref or change how git runs: a message
    (-m / --message of commit, tag, notes, stash, merge) and a pathspec after `--` of anything but a push. A git
    command run in a directory the guard cannot know (`cd "$D" && git …`) is denied too."""
    if here == UNKNOWN_CWD or any(unresolved(t) for t in prefix):
        return GIT_UNREADABLE
    i = 1
    while i < len(gseg):
        a = gseg[i]
        if unresolved(a):
            return GIT_UNREADABLE
        if not a.startswith("-"):
            break
        name, eq, _ = a.partition("=")
        if name in GIT_VALUE_OPTS and not eq:
            if i + 1 < len(gseg) and unresolved(gseg[i + 1]):
                return GIT_UNREADABLE
            i += 2
        else:
            i += 1
    if i >= len(gseg):
        return None
    repo, args, cfg = git_parts(gseg, here, penv)
    resolved, shell_alias = resolve_alias(repo, args, cfg)
    sub = resolved[0] if resolved else ""
    pushes = shell_alias is not None or sub == "push" or sub in PLUMBING_SUBS or sub.startswith("remote-")
    rest = gseg[i + 1:]
    j = 0
    while j < len(rest):
        a = rest[j]
        if a == "--" and not pushes:
            return None
        if sub in MESSAGE_SUBS and (a == "--message" or MESSAGE_CLUSTER.match(a)):
            j += 2
            continue
        if sub in MESSAGE_SUBS and (a.startswith("--message=") or (a.startswith("-m") and not a.startswith("--"))):
            j += 1
            continue
        if unresolved(a):
            return GIT_UNREADABLE
        j += 1
    return None


# $HOME / $CLAUDE_CONFIG_DIR, marked: resolve() expands them from the hook's environment — unless the command
# itself assigns one, when the shell's value is not the hook's.
MARKED_PATH_VARS = re.compile(DYN + r"(?:\{(?:HOME|CLAUDE_CONFIG_DIR)\}|(?:HOME|CLAUDE_CONFIG_DIR)\b)")
ASSIGNS_PATH_VAR = re.compile(r"(?:^|[\s;&|(])(?:export\s+|declare\s+-x\s+|typeset\s+-x\s+)?(?:HOME|CLAUDE_CONFIG_DIR)=")


def could_land(d: Path, g: G) -> Optional[str]:
    """Critic finding 2: the sentence a write somewhere under directory d could earn, or None — d is, holds or
    lies in a transcript directory (outside <dir>/memory/); d is the home or above it; or d, under the home, is
    protected, holds a protected path, or is a tree the lease rules deny (no warning state is recorded: this is
    a probe of a directory, not the write itself)."""
    import transcriptlib as tl
    rr = g.root.resolve()
    for t in tl.transcript_dirs(g.root):
        if under(t, d) or (under(d, t) and not under(d, t / "memory")):
            return bh.TRANSCRIPT_DENY
    protected = "%s can hold Daedalus's own files (distribution code or evidence); write a proposal instead." % d
    if under(rr, d):
        return protected
    if not under(d, rr):
        return bh.git_gate_deny(d)
    if v.is_protected(g.root, d) or hooks_path(d):
        return protected
    for pg in v.protected_globs(g.root):
        base = rr / (pg[:-3] if pg.endswith("/**") else pg)
        if under(base, d):
            return protected
    if g.refused and (under(d, rr / "target") or under(d, rr / "worktrees")):
        return g.refused
    if g.ctx["leases"]:
        return bh.tree_deny(g.root, g.ctx, d)
    return None


def expanded(op: str, cmd: str) -> str:
    """op with $HOME / $CLAUDE_CONFIG_DIR and a leading ~ expanded, as resolve() does."""
    t = op if ASSIGNS_PATH_VAR.search(cmd) else PATH_VARS.sub(
        lambda m: os.environ.get(m.group(1) or m.group(2)) or m.group(0), op)
    return os.path.expanduser(t)


def unreadable_target(op: str, here: Path, g: G, cmd: str) -> Optional[str]:
    """Critic finding 2: a write operand the guard cannot resolve to one literal path — a variable other than
    $HOME / $CLAUDE_CONFIG_DIR (those two only when the command does not assign them), $( ), backticks, $'…', a
    brace expansion, a relative path after `cd` to a place the guard cannot know — is denied; a glob is denied when
    the directory before its first wildcard could hold the transcript or Daedalus's own files, and otherwise each
    path it matches now gets the full check (see glob_matches)."""
    raw = getattr(op, "raw", None)
    if raw is None:
        return None
    r = raw if ASSIGNS_PATH_VAR.search(cmd) else MARKED_PATH_VARS.sub("", raw)
    if any(ch in DYN_MARKS for ch in r) or BRACE in r:
        return WRITE_UNREADABLE % op
    if here == UNKNOWN_CWD and not os.path.isabs(expanded(op, cmd)):
        return WRITE_UNREADABLE % op
    if globbed(op):
        i = next(k for k, ch in enumerate(raw) if ch in GLOB_MARKS)
        head = expanded(str(op)[:i], cmd)
        d = head.rsplit("/", 1)[0] if "/" in head else ""
        base = resolve(here, d) if d else (Path("/") if head.startswith("/") else here.resolve())
        if could_land(base, g):
            return WRITE_UNREADABLE % op
    return None


def glob_matches(op: str, here: Path, cmd: str) -> List[Path]:
    """What a glob write operand matches now, as the shell would expand it from `here` (hidden files only when
    the pattern names them)."""
    pat = expanded(str(op), cmd)
    pat = pat if os.path.isabs(pat) else str(here / pat)
    return [Path(m) for m in globmod.glob(pat, recursive=True)]


def literal_write(p: Path, op: str, g: G) -> Tuple[Optional[str], Optional[str]]:
    """(deny reason, context) for one resolved write path: git's hooks, the lease-era write_check (the transcript,
    git's configuration, the trees, the cross-lease warning), distribution code."""
    if ami_state_hit(g.root, p):
        return AMI_STATE_DENY, None
    if hooks_path(p):
        return HOOKS_WRITE % op, None
    reason, context = bh.write_check(g.root, g.ctx, p, g.sid, g.refused)
    if reason:
        return reason, None
    if v.is_protected(g.root, p):
        return "%s is distribution code (or evidence); write a proposal instead of editing it." % p, None
    return None, context


def ami_state_hit(root: Path, p: Path) -> bool:
    """§6.6: p is state/ami, lies under it, or is state/ itself (removing it takes the record with it)."""
    rr = Path(root).resolve()
    rp = Path(p).resolve()
    return under(rp, rr / AMI_STATE) or rp == rr / "state"


def ami_body_write(rhead: str, body: str, here: Path, g: G) -> bool:
    """§6.6: a heredoc or here-string body an interpreter or a shell reads writes or removes under state/ami — the
    literal paths Python's code writes, the write operands of a shell body's commands, or (code whose targets
    cannot be read, perl, ruby, node) a write shape beside a mention of state/ami."""
    mentions = AMI_STATE in body or (("'ami'" in body or '"ami"' in body) and "state" in body)
    if rhead in SHELLS:
        try:
            tokens = tokenize(body)
        except ValueError:
            return mentions
        for raw in segments(tokens):
            while raw and raw[0] in KEYWORDS:
                raw = raw[1:]
            seg = unwrap(raw)
            if not seg:
                continue
            ops = write_operands(seg) + tree_operands(seg)[0]
            if any(ami_state_hit(g.root, resolve(here, op)) for op in ops):
                return True
        return False
    lits, why = code_write(rhead, body)
    if any(ami_state_hit(g.root, resolve(here, op)) for op in lits):
        return True
    return bool(why) and mentions


def switch_verb_denied(seg: List[str], g: G) -> Optional[str]:
    """§6.6: `frame-jack.py on|off` from the Bash tool runs only when the operator's last recorded message in this
    session (amilib's session file, operator.text) says `frame-jack on` / `frame-jack off`, with or without the
    slash, in any case — those words only: "turn the AMI on" is refused with the phrase that works. Other verbs
    (status, --doctor) are free."""
    if not any("frame-jack.py" in t for t in seg):
        return None
    import amilib
    hs = amilib.head(seg)
    if not hs:
        return None
    rest = hs[1:]
    if os.path.basename(hs[0]) in amilib._PY:
        rest = [t for t in hs[1:] if not t.startswith("-")]
        if not rest:
            return None
        script, rest = rest[0], rest[1:]
    else:
        script = hs[0]
    if os.path.basename(script) != "frame-jack.py":
        return None
    verb = next((t for t in rest if not t.startswith("-")), None)
    if verb not in ("on", "off"):
        return None
    text = ""
    if g.sid:
        c = amilib.counters(g.root, g.sid) or {}
        text = str((c.get("operator") or {}).get("text") or "")
    if re.search(r"(?<![\w-])/?frame-jack\s+%s\b" % verb, text, re.IGNORECASE):
        return None
    return SWITCH_DENY % (verb, "on" if verb == "off" else "off", verb)


CD_FLAGS = "LPe@"      # bash's cd options (zsh's -q and -s too): none moves the directory elsewhere


def cd_target(seg: List[str], here: Path, cmd: str) -> Path:
    """Where `cd` / `pushd` / `popd` leave the shell (critic-fix review, finding 2): options are read as the shell
    reads them — -L, -P, -e, -@ (a flag run of them, `-LP`) and `--` before the directory, which is the first operand
    after them. Any other option, a missing operand after options, `-`, a `+N`/`-N` stack rotation, popd, a word
    the shell fills in, and a relative directory while CDPATH could redirect it are places the guard cannot know."""
    if seg[0] == "popd":
        return UNKNOWN_CWD
    i = 1
    while i < len(seg):
        a = seg[i]
        if a == "--":
            i += 1
            break
        if a.startswith("-") and a != "-":
            if seg[0] == "cd" and len(a) > 1 and all(ch in CD_FLAGS + "qs" for ch in a[1:]):
                i += 1
                continue
            return UNKNOWN_CWD
        break
    if i >= len(seg):
        return Path(os.path.expanduser("~")).resolve() if i == 1 else UNKNOWN_CWD
    op = seg[i]
    if unresolved(op) or op == "-" or op.startswith("+"):
        return UNKNOWN_CWD                                              # critic finding 1: nowhere the guard knows
    if ("CDPATH=" in cmd or os.environ.get("CDPATH")) and not op.startswith(("/", "./", "../", "~")) and op != ".":
        return UNKNOWN_CWD
    return resolve(here, op)


def check_command(cmd: str, cwd: Path, g: G, depth: int = 0) -> Tuple[Optional[str], List[str]]:
    """(deny reason | None, cross-lease warnings to pass on as context) for one
    command string — and, recursively, for every command inside it: $( ),
    backticks, `bash -c`, `eval`, and a `!` git alias (§7.3 (2)–(3))."""
    if depth > 4:
        return TOO_DEEP, []
    if "DAEDALUS_TEST_TTY_ANCESTRY" in cmd:                   # Decision 32: the suite's seam
        return TTY_SEAM, []
    contexts: List[str] = []
    for inner in substitutions(cmd):
        reason, more = check_command(inner, cwd, g, depth + 1)
        if reason:
            return reason, []
        contexts += more
    try:
        tokens = tokenize(cmd)
    except ValueError:
        return unparseable(cmd, cwd, g), contexts
    # critic-fix review, finding 1: HOME / XDG_CONFIG_HOME set anywhere in a command that runs git (a prefix, env,
    # export, a plain assignment, or a shell function or string the git runs in) points git at another global
    # configuration. A command that runs no git keeps them.
    home = next((m.group(1) for t in tokens for m in [GLOBAL_CONFIG_VAR.match(t.split()[0] if t.split() else t)] if m),
                None)
    if home and any(GIT_WORD.search(t) for t in tokens):
        return GLOBAL_CONFIG_ENV % home, []
    bodies: List[str] = []
    strip_heredocs(cmd, bodies)
    branch_created = False
    here = cwd
    vault = (g.root / "vault").resolve()
    prev: List[str] = []
    for raw, sep in segments_sep(tokens):
        piped = prev if ("|" in sep and "||" not in sep) else []
        prev = raw
        try:
            reason, more, here, branch_created = check_segment(raw, piped, bodies, cmd, here, branch_created,
                                                                vault, g, depth)
        except Exception as e:     # Task 13 review: a crash denies the command, never waves the rest through
            print("daedalus: guard-bash failed on a segment: %r" % e, file=sys.stderr)
            return CANNOT_CHECK % " ".join(raw)[:120], []
        if reason:
            return reason, []
        contexts += more
    return None, contexts


def check_lease_release(seg: List[str], g: G) -> Optional[str]:
    """The early refusal for `lease.sh release NN --remove …` (design 2026-10-15, §4.3): the first word naming
    lease.sh, by basename, behind any wrapper (exec_index) — the home's, a worktree checkout's, a copy. Behind
    xargs or parallel it is refused outright (bare xargs is a wrapper Claude Code strips for the allow rule; the
    guard reads no stdin). Then: a session must be present (fail closed), the number literal, the operator's
    words readable, and leaselib.deletion_confirmed decides — the report shown, the yes after the line in this
    session's transcript, the work unchanged. Plain `release NN` and every other verb are untouched."""
    j = exec_index(seg, LEASE_HEADS)
    if os.path.basename(seg[j]) != "lease.sh":
        return None
    if any(os.path.basename(t) in STDIN_ARGS for t in seg[:j]):
        return DELETE_FROM_STDIN
    args = seg[j + 1:]
    if args[:1] != ["release"] or "--remove" not in args[1:]:
        return None
    if g.sid is None:
        return DELETE_NO_SESSION
    nn = args[1] if len(args) > 1 else ""
    if unresolved(nn) or not re.fullmatch(r"[0-9]{2}", nn):
        return DELETE_NUMBER
    said = ""
    if "--operator-said" in args:
        i = args.index("--operator-said")
        said = args[i + 1] if i + 1 < len(args) else ""
        if unresolved(said):
            return DELETE_ONE_WORD                 # a $ or a backtick the guard cannot read
    import leaselib as ll
    return ll.deletion_confirmed(g.root, g.sid, nn, said)


def segments_of(cmd: str, cwd: Path, g: G, depth: int = 0) -> List[List[str]]:
    """Every segment check_command walks, after `unwrap`, at every depth it walks — $( ) and backtick bodies,
    `bash -c` strings, `eval` words, `watch` commands, the shell commands a writer runs from its own code —
    heredoc bodies masked (tokenize strips them), as plain token lists for amilib.classify (frame-jack spec
    §6.1: one tokenizer, one unwrap). A git alias's expansion is not re-walked here (check_git resolves it
    against the repository; the segment is classified as the git word it is)."""
    if depth > 4:
        return []
    out: List[List[str]] = []
    for inner in substitutions(cmd):
        out += segments_of(inner, cwd, g, depth + 1)
    try:
        tokens = tokenize(cmd)
    except ValueError:
        return out
    for raw, _sep in segments_sep(tokens):
        while raw and raw[0] in KEYWORDS:
            raw = raw[1:]
        seg = unwrap(raw)
        if not seg:
            continue
        out.append([str(t) for t in seg])
        k = exec_index(seg, RUN_HEADS)
        run = seg[k:]
        rhead = os.path.basename(run[0])
        inner = None
        if rhead in SHELLS:
            inner = shell_inner(run)
        elif rhead == "eval" and len(run) > 1:
            inner = " ".join(run[1:])
        elif os.path.basename(seg[0]) == "watch":
            inner = watch_inner(seg)
        if inner is not None:
            out += segments_of(inner, cwd, g, depth + 1)
        try:
            inner_cmds, _why = embedded_code(seg)
        except Exception:
            inner_cmds = []
        for inner_cmd in inner_cmds:
            out += segments_of(inner_cmd, cwd, g, depth + 1)
    return out


def check_segment(raw: List[str], piped: List[str], bodies: List[str], cmd: str, here: Path, branch_created: bool,
                  vault: Path, g: G, depth: int) -> Tuple[Optional[str], List[str], Path, bool]:
    """One segment of check_command: (deny reason | None, contexts, the cwd after it, whether a
    branch was created so far)."""
    contexts: List[str] = []
    while raw and raw[0] in KEYWORDS:
        raw = raw[1:]
    if not raw:
        return None, [], here, branch_created
    for t in raw:
        # GIT_CONFIG_* as a prefix, through env, or exported for the commands after it (Task 13 review)
        m = CONFIG_ENV.match(t)
        if m:
            return GIT_CONFIG_ENV % m.group(1), [], here, branch_created
        m = HOOKDIR_VAR.match(t)
        if m:
            return HOOKDIR_ENV % m.group(1), [], here, branch_created
    if strips_session_variable(raw):
        return STRIP_REASON, [], here, branch_created
    if env_splits(raw):
        return ENV_SPLIT, [], here, branch_created
    penv = prefix_env(raw)
    seg = unwrap(raw)
    if not seg:
        return None, [], here, branch_created
    prefix = raw[:len(raw) - len(seg)]
    if unresolved(seg[0]):
        return CMD_UNREADABLE % seg[0], [], here, branch_created      # critic finding 1: it could be git
    bad = runner_unresolved(seg)
    if bad is not None:
        return CMD_UNREADABLE % bad, [], here, branch_created
    names_entry = ENTRY.search(cmd) is not None
    head = os.path.basename(seg[0])
    if head in TTY_ALWAYS or (names_entry and (
            head in TTY_TOOLS or any("fixtures/tty/" in t for t in seg)
            or (head in INTERPRETERS and any(re.search(r"\bpty\b", t) for t in seg[1:])))):
        return TTY_WRAP, [], here, branch_created           # Decision 32: a program-made terminal
    reason = check_lease_release(seg, g)                     # design 2026-10-15: the delete's early refusal
    if reason:
        return reason, [], here, branch_created
    if seg[0] == "builtin" and len(seg) > 1 and seg[1] in ("cd", "pushd", "popd"):
        seg = seg[1:]                                                   # `builtin cd …` is cd
    if seg[0] in ("cd", "pushd", "popd"):
        return None, [], cd_target(seg, here, cmd), branch_created
    reason = switch_verb_denied(seg, g)
    if reason:
        return reason, [], here, branch_created
    k = exec_index(seg, RUN_HEADS)
    run = seg[k:]
    rhead = os.path.basename(run[0])
    if k:
        penv = dict(penv)
        penv.update(t.split("=", 1) for t in seg[:k] if ASSIGN.match(t))
    inner = None
    if rhead in SHELLS:
        inner = shell_inner(run)
        if inner is not None and unresolved(inner):
            return CMD_UNREADABLE % inner, [], here, branch_created
        if inner is None and shell_reads_stdin(run):
            fed = [" ".join(piped)] + herestrings(run)
            if any(t.startswith("<<") and not t.startswith("<<<") for t in run):
                fed += bodies
            if any(PUSH_IN_STRING.search(x) for x in fed):
                return PUSH_IN_SCRIPT, [], here, branch_created
    elif rhead == "eval" and len(run) > 1:
        bad = next((t for t in run[1:] if unresolved(t)), None)
        if bad is not None:
            return CMD_UNREADABLE % bad, [], here, branch_created
        inner = " ".join(run[1:])
    elif head == "watch":
        inner = watch_inner(seg)
    if inner is not None:
        reason, more = check_command(inner, here, g, depth + 1)
        if reason:
            return reason, [], here, branch_created
        contexts += more
    if rhead in INTERPRETERS:
        code = next((run[i + 1] for i, t in enumerate(run[:-1]) if t in ("-c", "-e", "-E")), None)
        if code is not None and dynamic(code):
            return CMD_UNREADABLE % code, [], here, branch_created
    if rhead in INTERPRETERS and any(t in ("-c", "-e") for t in run) and any(PUSH_IN_STRING.search(t) for t in run[1:]):
        return PUSH_IN_SCRIPT, [], here, branch_created
    if is_git_word(rhead):
        gseg = git_argv(run)
        gseg = split_redirects(gseg)[1] or gseg    # `2>&1` is not a refspec or an argument
        reason = git_unreadable(gseg, prefix + seg[:k], here, penv)
        if reason:
            return reason, [], here, branch_created
        repo_dir, args, _cfg = git_parts(gseg, here, penv)
        if head in STDIN_ARGS and args[:1] and args[0] in ("push", "send-pack", "config", "update-ref", "branch", "commit"):
            return FROM_STDIN % (head, args[0], args[0]), [], here, branch_created
        if args[:2] in (["switch", "-c"], ["checkout", "-b"]):
            branch_created = True
        elif args[:1] in (["switch"], ["checkout"]) and len(args) == 2 \
                and (args[1] == "-" or args[1] == "--detach" or not args[1].startswith("-")):
            # `switch -c fix/x && switch mainline && commit` lands the
            # commit on the trunk: a later plain switch cancels the
            # credit. `-` is a branch name (the previous branch — the
            # trunk, right after `switch -c`), not an option, and
            # `--detach` leaves the new branch too.
            branch_created = False
        reason, alias_cmd = check_git(gseg, here, g.target, branch_created, g.refused, g.ctx, g.root, penv)
        if reason:
            return reason, [], here, branch_created
        if alias_cmd is not None:
            reason, more = check_command(alias_cmd, repo_dir, g, depth + 1)
            if reason:
                return reason, [], here, branch_created
            contexts += more
        reason = check_vault_git(args, repo_dir, vault, g.ctx) or check_worktree_remove(args, repo_dir, g.root, g.ctx)
        if reason:
            return reason, [], here, branch_created
    removed, filled = tree_operands(seg)
    for op in removed + filled:
        reason = transcript_ancestor(g.root, resolve(here, op), op in filled and op not in removed)
        if reason:
            return reason, [], here, branch_created
    w = exec_index(seg, WRITE_HEADS)
    # critic finding 2: an extraction fills a directory (tar -x, unzip, cpio -i), its -C / -d or the cwd
    for op in fill_dirs(seg, here) + (fill_dirs(seg[w:], here) if w else []):
        reason = unreadable_target(op, here, g, cmd)
        if reason:
            return reason, [], here, branch_created
        reason = transcript_ancestor(g.root, resolve(here, op), True) or could_land(resolve(here, op), g)
        if reason:
            return reason, [], here, branch_created
    ops = write_operands(seg)
    if w:
        ops += write_operands(seg[w:])        # behind a wrapper: `sudo chmod -x …`
    # critic-fix review, finding 3: the commands a writer runs from its own code are commands like any other
    for part in ([seg[w:]] if w else []) + [seg]:
        inner_cmds, why = embedded_code(part)
        if why:
            return CODE_WRITE % why, [], here, branch_created
        for inner_cmd in inner_cmds:
            reason, more = check_command(inner_cmd, here, g, depth + 1)
            if reason:
                return reason, [], here, branch_created
            contexts += more
    if rhead in INTERPRETERS or rhead in SHELLS:
        fed = herestrings(run)
        if any(t.startswith("<<") and not t.startswith("<<<") for t in run):
            fed += bodies
        if any(ami_body_write(rhead, b, here, g) for b in fed):
            return AMI_STATE_DENY, [], here, branch_created
    if os.path.basename(seg[0]) == "patch" and any(t.startswith("<") for t in seg[1:]):
        ops.append(".")        # patch < file writes its cwd (§7.3)
    if rhead in INTERPRETERS:
        code = interpreter_code(run)
        if code is not None:
            lits, why = code_write(rhead, code)
            if why:
                return CODE_WRITE % why, [], here, branch_created
            ops += lits
    for op in ops:
        reason = unreadable_target(op, here, g, cmd)
        if reason:
            return reason, [], here, branch_created
        paths = glob_matches(op, here, cmd) if globbed(op) else [resolve(here, op)]
        for p in paths:
            reason, context = literal_write(p, op, g)
            if reason:
                return reason, [], here, branch_created
            if context:
                contexts.append(context)
    return None, contexts, here, branch_created


AMI_HARD_DEADLINE_SECS = 4.3      # absolute, from the hook's start; the guard's timeout in settings.json is 5
AMI_MIN_REMAINING_SECS = 0.3      # below this the tier is skipped, row `unanswered: budget`


def ami_deadline_secs() -> float:
    """The tier's absolute budget; AMI_TEST_DEADLINE_SECS shrinks it for a test and can never widen it."""
    secs = AMI_HARD_DEADLINE_SECS
    try:
        knob = float(os.environ.get("AMI_TEST_DEADLINE_SECS") or secs)
        if 0 < knob < secs:
            secs = knob
    except ValueError:
        pass
    return secs


def main() -> int:
    started = time.monotonic()       # frame-jack spec §6.0: the AMI tier's deadline is absolute from here
    try:
        payload = json.load(sys.stdin)
        cmd = str(payload["tool_input"]["command"])
        cwd = Path(payload.get("cwd") or v.ROOT).resolve()
    except Exception:
        return 0
    root = v.ROOT
    sid = v.export_session(payload)
    try:
        ctx = v.lease_context(root, sid)             # one locked read; the refusal is in-process (§4.6)
    except Exception as e:
        # The read itself broke (lock file unwritable, a liveness probe raising):
        # say so, and fall through to the bash seam, which answers Refused
        # for the same breakage (lib.sh maps a leaselib failure to exit 3).
        ctx = v._empty_lease_context()
        print("daedalus: the guard could not read the lease files (%s); asking the lease resolution directly." % e,
              file=sys.stderr)
    refused = ctx["refused"] or ""
    target = None
    if not refused:
        r = v.resolve_target(root, sid)             # the tree path for check_git's trunk rules (one bash spawn, as before)
        if isinstance(r, v.Resolved):
            target = r.path
        elif isinstance(r, v.Refused):
            # §4.4: what the in-process read did not refuse, the seam still can
            # (a DAEDALUS_TARGET_OVERRIDE outside state/promote/, a lock wait
            # that ran out, a leaselib crash). Not-known fails CLOSED for push
            # and commit under this deployment, with the seam's own sentence —
            # dropping it to target=None was the fail-open the tri-state removes.
            refused = r.sentence
        # Unconfigured (config.yaml unreadable) keeps target=None: check_git's
        # target/ rule fails closed there with the config sentence.
    g = G(root, ctx, target, refused, sid)
    try:
        reason, contexts = check_command(cmd, cwd, g)
    except Exception as e:
        # Task 13 review: an error the guard hits is a command it could not check — denied, not
        # waved through (an empty alias crashed it and let the trunk push after it pass).
        print("daedalus: guard-bash failed: %r" % e, file=sys.stderr)
        reason, contexts = CANNOT_CHECK % cmd[:120], []
    # The AMI tier (frame-jack spec §6.0): after the deterministic guard, only for a command it did not deny,
    # never for a visitor; under the absolute deadline; shadow only — it logs, and may add the once-per-session
    # sentence of §6.4. An exception inside it is a row and a stderr line; the guard's decision stands.
    ami_out = None
    if not reason and not os.environ.get("DIRECT_CALL_ID"):
        ami_deadline = started + ami_deadline_secs()     # the counters lock is waited on only until it, too
        try:
            import amilib
            ami_out = amilib.before_bash(root, sid, payload, cmd, cwd,
                                         guard="allow" if not contexts else contexts[0][:80],
                                         deadline=ami_deadline,
                                         segments=lambda: segments_of(cmd, cwd, g))
        except ModuleNotFoundError as e:
            if e.name != "amilib":   # a home without core/amilib.py has no AMI to run: nothing to say
                print("daedalus: the AMI tier could not run (%r); the command goes on as the guard decided." % e,
                      file=sys.stderr)
        except Exception as e:
            try:
                amilib.row_unanswered(root, sid, payload, "error %s" % type(e).__name__, "destructive",
                                      deadline=ami_deadline, guard="allow" if not contexts else contexts[0][:80], cwd=str(cwd))
            except Exception:
                pass
            print("daedalus: the AMI tier could not run (%r); the command goes on as the guard decided." % e,
                  file=sys.stderr)
    if reason:
        deny(reason)
        return 0
    # The one emit: the guard's own warning(s) as context with the write (§4.6), the AMI's once sentence beside
    # them and, at the top level, as systemMessage — the operator's copy.
    out: Dict[str, object] = {"hookSpecificOutput": {"hookEventName": "PreToolUse"}}
    lines = list(contexts)
    if ami_out and ami_out.get("context"):
        lines.append(str(ami_out["context"]))
    if lines:
        out["hookSpecificOutput"]["additionalContext"] = "\n".join(lines)      # type: ignore[index]
    if ami_out and ami_out.get("system"):
        out["systemMessage"] = str(ami_out["system"])
    if lines or "systemMessage" in out:
        v.emit(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
