#!/usr/bin/env python3
"""PreToolUse(Bash) guard: the speed bump in front of the boundary check.

Denies, with a reason, pushes to the trunk, commits on the trunk and every
other trunk-reaching git shape (spec §7.3) in every repo under the home —
`target/`, `worktrees/`, `state/promote/` — through `bash -c`, `eval`, `$( )`,
backticks, `env` and `VAR=` prefixes and git aliases alike (one recursive
check_command, so a command reached any of those ways passes every rule;
nesting deeper than four is denied); distribution code by every git route
(`apply`, `am`, `cherry-pick`, `merge`, `pull`, `rebase`, `stash pop|apply`,
`checkout <rev>`, `switch <branch>`, `restore --source` in Daedalus's own
checkout, `patch < file` writing its cwd); `--no-verify` (abbreviated too —
git takes any unique prefix of a long option), `core.hooksPath` by every
route (`-c`, `--config-env`, `GIT_CONFIG_*`, `git config`) and writes under
`.git/hooks/`; a trunk moved by `update-ref` or `branch -f`; a push to the
target's origin from any directory, `GIT_DIR`/`GIT_WORK_TREE` honoured; a
program-made terminal (`script`, `expect`, `unbuffer`, a `pty`, the suite's
tty helper) in front of `promote.sh` or `lease.sh`, `screen`/`tmux`/`login`
anywhere, and the suite's tty seam variable; destructive git; and writes
whose operand resolves to a protected path of this deployment. One message
rule in every case: trunk is reached only through promote. The guard is a
speed bump and git's pre-push hook (core/prepush.py) a second one, which does
not fail open when this does; a push by a route this guard does not parse,
from a clone outside the home with no hook, is covered only by server-side
branch protection (plan 4 Decision 38).

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
made shlex raise. Fails open on its own errors, except that a command
that is still unparseable is checked for redirect and `-i` operands
with the full write check, and that an unreadable config
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

import functools
import importlib
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402
bh = importlib.import_module("boundary-hook")  # noqa: E402  (the file name has a dash)

# The shell's command separators, tokenized as their own words (shlex punctuation mode, plus
# newline): a token made only of these characters (`&&`, `||`, `|`, `|&`, `&`, `;`, `;;`, a
# newline, or a run such as `;\n`) ends a segment.
PUNCT = ";&|\n"
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
TRUNK_REF = "`git %s` would move %s by hand. " + PROMOTE_RULE
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
TOO_DEEP = "This command nests shells too deeply for the guard to check; run the inner command directly."
HOME_TREES = ("target", "worktrees", "state/promote")
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
INTERPRETERS = {"python3", "python", "perl", "ruby", "node"}
PREFIX_CMDS = {"command", "exec", "nohup", "time"}
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PUSH_IN_STRING = re.compile(r"\bgit\b[^;&|\n]*\bpush\b")
GIT_BUILTINS = {
    "add", "am", "apply", "archive", "bisect", "blame", "branch", "bundle", "cat-file", "check-ignore", "checkout",
    "cherry", "cherry-pick", "clean", "clone", "commit", "commit-tree", "config", "describe", "diff", "diff-tree",
    "fetch", "for-each-ref", "format-patch", "fsck", "gc", "grep", "hash-object", "help", "init", "log", "ls-files",
    "ls-remote", "ls-tree", "maintenance", "merge", "merge-base", "mv", "notes", "prune", "pull", "push", "range-diff",
    "read-tree", "rebase", "reflog", "remote", "reset", "restore", "rev-list", "rev-parse", "revert", "rm", "show",
    "shortlog", "sparse-checkout", "stash", "status", "submodule", "switch", "symbolic-ref", "tag", "update-index",
    "update-ref", "version", "worktree", "write-tree"}


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


def strip_heredocs(cmd: str) -> str:
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


def tokenize(cmd: str) -> List[str]:
    """shlex in punctuation mode over the command with its heredoc bodies removed: `;`, `&`,
    `|`, `>` and newlines come out as their own tokens (runs merged: `&&`, `||`, `>>`, `&>`),
    quotes and escapes as in posix mode, `#` never a comment. A run that mixes a separator
    and a redirect is split (split_punct_run). Raises ValueError only for a quote the shell
    itself leaves open."""
    lex = shlex.shlex(strip_heredocs(cmd), posix=True, punctuation_chars=PUNCT + ">")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    lex.commenters = ""
    out: List[str] = []
    for t in lex:
        if ">" in t and t and all(c in PUNCT + ">" for c in t):
            out.extend(split_punct_run(t))
        else:
            out.append(t)
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


def norm_url(u: str, base: Path) -> str:
    """A remote URL compared by value: a local path resolved; a network URL without a trailing / or .git."""
    u = u.strip().rstrip("/")
    if "://" in u or re.match(r"^[^/]+@[^:/]+:", u):
        return u[:-4] if u.endswith(".git") else u
    return str(resolve(base, u))


@functools.lru_cache(maxsize=2)
def target_origins(root_s: str) -> frozenset:
    """The push URLs of target/<name>'s origin and each nested repo's (Decision 38), once per guard call."""
    root, out = Path(root_s), set()
    tdir = root / "target"
    for top in (sorted(tdir.iterdir()) if tdir.is_dir() else []):
        if not (top / ".git").exists():
            continue
        for r in [top] + [top / rel for rel in v.nested_relpaths(root)]:
            code, u, _ = v.run(["git", "-C", str(r), "remote", "get-url", "--push", "origin"])
            if code == 0 and u.strip():
                out.add(norm_url(u, r))
    return frozenset(out)


def pushes_to_target(repo: Path, rest: List[str], root: Path) -> bool:
    """Decision 38: a push, from any directory, whose destination is the target's origin (by remote or literal URL)."""
    pos = push_positionals(rest)
    remote = pos[0] if pos else "origin"
    if "/" in remote or ":" in remote:
        url = norm_url(remote, repo)
    else:
        code, u, _ = v.run(["git", "-C", str(repo), "remote", "get-url", "--push", remote])
        if code != 0 or not u.strip():
            return False
        url = norm_url(u, repo)
    return url in target_origins(str(root.resolve()))


def unwrap(seg: List[str]) -> List[str]:
    """The real command behind `env …`, `VAR=value …` and command/exec/nohup/time
    prefixes (§7.3 (4)). strips_session_variable has already judged the prefix."""
    seg = list(seg)
    while seg:
        h = seg[0]
        if h == "env":
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


def git_parts(seg: List[str], cwd: Path, penv: Optional[Dict[str, str]] = None) -> Tuple[Path, List[str], dict]:
    """(repo, args, -c pairs) of one git segment: GIT_WORK_TREE / GIT_DIR in the
    prefix name the repo (Decision 38), -C moves it, -c k=v and --config-env k=v
    are collected (lower-cased key), --git-dir=X names it; other options are skipped."""
    repo, cfg, i = cwd, {}, 1
    penv = penv or {}
    if penv.get("GIT_WORK_TREE"):
        repo = resolve(cwd, penv["GIT_WORK_TREE"])
    elif penv.get("GIT_DIR"):
        gd = resolve(cwd, penv["GIT_DIR"])
        repo = gd.parent if gd.name == ".git" else gd
    while i < len(seg) and seg[i].startswith("-"):
        a = seg[i]
        if a == "-C" and i + 1 < len(seg):
            repo = resolve(repo, seg[i + 1])
            i += 2
            continue
        if a in ("-c", "--config-env") and i + 1 < len(seg):
            k, _, val = seg[i + 1].partition("=")
            cfg[k.lower()] = val
            i += 2
            continue
        if a.startswith("--config-env="):
            k, _, val = a.split("=", 1)[1].partition("=")
            cfg[k.lower()] = val
            i += 1
            continue
        if a.startswith("--git-dir="):
            gd = resolve(repo, a.split("=", 1)[1])
            repo = gd.parent if gd.name == ".git" else gd
        i += 1
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


def push_positionals(rest: List[str]) -> List[str]:
    positionals: List[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            positionals.extend(rest[i + 1:])
            break
        if a.startswith("-"):
            i += 2 if (a in PUSH_VALUE_OPTS and "=" not in a) else 1
            continue
        positionals.append(a)
        i += 1
    return positionals


def check_worktree_promote(rest: List[str], repo: Path, root: Path, ctx: dict) -> Optional[str]:
    """§7.3: `git worktree remove <state/promote/…>` and `git worktree prune` in a repo
    under the home are the prime's; a non-prime window is denied."""
    if not ctx["leases"] or ctx["prime"] or not rest or home_tree(root, repo) is None:
        return None
    who = ctx["mine"] or "none"
    if rest[0] == "prune":
        return WORKTREE_PROMOTE % who
    if rest[0] == "remove":
        scratch = (root / "state" / "promote").resolve()
        if any(not a.startswith("-") and under(resolve(repo, a), scratch) for a in rest[1:]):
            return WORKTREE_PROMOTE % who
    return None


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
    args, shell_alias = resolve_alias(repo, args, cfg)
    if shell_alias is not None:
        return None, shell_alias
    sub, rest = args[0], args[1:]
    if sub == "config" and any(r.lower() == "core.hookspath" for r in rest):
        return HOOKSPATH, None
    tree = home_tree(root, repo)
    if refused and sub in ("push", "commit") and under(repo, root):
        # §4.4: a session no lease names, while leases exist, fails closed —
        # the tree it would push or commit from is not known.
        return refused, None
    for a, b in DESTRUCTIVE:
        if sub == a and (b in rest or (b == "-f" and any(r.startswith("-f") for r in rest))):
            if not (sub == "checkout" and rest and rest[-1] != "."):
                return "`git %s %s` destroys work; ask the operator." % (a, b), None
    if is_product_repo(root, repo) or any(v.is_protected(root, resolve(repo, r)) for r in rest if not r.startswith("-")):
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
                or (sub == "push" and pushes_to_target(repo, rest, root)))       # Decision 38
    if not in_scope:
        return None, None
    if target is None:
        # config.yaml could not be read: the trunk is unknown — fail closed in every tree of the home.
        return "config.yaml cannot be read, so the trunk is unknown; refusing `git %s` inside the target until it is fixed." % sub, None
    mine = ctx["mine"] or "<NN>"
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
        # `push origin HEAD` / `push -u origin HEAD` / `push origin @` push the
        # current branch to its same-named remote branch: resolve before comparing.
        dests = [cur if d in ("HEAD", "@") else d for d in push_destinations(rest)]
        if PUSH_MATCHING in dests:
            return MATCHING % (trunk, mine, mine), None
        if not dests and cur in names:
            return PUSH_TRUNK % (cur, mine, mine), None
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
        if spec.startswith("refs/heads/"):
            spec = spec[len("refs/heads/"):]
        if spec:
            dests.append(spec)
    return dests


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
    head, pos = words[0], positionals(words[1:])
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
    head = seg[0]
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
        ops.extend(t[3:] for t in seg[1:] if t.startswith("of=") and len(t) > 3)
    if head in ("perl", "ruby") and any(PERL_INPLACE.match(t) for t in seg[1:]):
        # in-place edit: every file operand; the program after -e is not one
        ops.extend(t for i, t in enumerate(seg[1:], 1) if not t.startswith("-") and seg[i - 1] not in ("-e", "-E"))
    if head == "patch":
        ops.extend(pos)
    if head == "git" and len(seg) >= 3 and seg[1] in ("apply", "checkout") and "--" in seg:
        ops.extend(seg[seg.index("--") + 1:])
    if head in ("python3", "python", "perl", "ruby", "node", "bash", "sh") and any(t in ("-c", "-e") for t in seg):
        for t in seg[1:]:
            if len(t) > 8 and WRITE_IN_STRING.search(t):
                ops.extend(m.group(0) for m in PATHISH.finditer(t) if "/" in m.group(0) or m.group(0).endswith((".sh", ".py", ".md", ".json", ".yaml")))
    return ops


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
    """The command string of `bash -c '…'` (or `-ec`, `-lc`), or None."""
    for i, t in enumerate(seg[1:-1], 1):
        if not t.startswith("-"):
            return None
        if SHELL_C.fullmatch(t):
            return seg[i + 1]
    return None


def check_command(cmd: str, cwd: Path, g: G, depth: int = 0) -> Tuple[Optional[str], List[str]]:
    """(deny reason | None, cross-lease warnings to pass on as context) for one
    command string — and, recursively, for every command inside it: $( ),
    backticks, `bash -c`, `eval`, and a `!` git alias (§7.3 (2)–(3))."""
    if depth > 4:
        return TOO_DEEP, []
    if "DAEDALUS_TEST_TTY_ANCESTRY" in cmd:                   # Decision 32: the suite's seam
        return TTY_SEAM, []
    names_entry = ENTRY.search(cmd) is not None
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
    branch_created = False
    here = cwd
    vault = (g.root / "vault").resolve()
    for raw in segments(tokens):
        if strips_session_variable(raw):
            return STRIP_REASON, []
        penv = prefix_env(raw)
        seg = unwrap(raw)
        if not seg:
            continue
        head = os.path.basename(seg[0])
        if head in TTY_ALWAYS or (names_entry and (
                head in TTY_TOOLS or any("fixtures/tty/" in t for t in seg)
                or (head in INTERPRETERS and any(re.search(r"\bpty\b", t) for t in seg[1:])))):
            return TTY_WRAP, []                                # Decision 32: a program-made terminal
        if seg[0] == "cd" and len(seg) >= 2:
            here = resolve(here, seg[1])
            continue
        inner = None
        if head in SHELLS:
            inner = shell_inner(seg)
        elif seg[0] == "eval" and len(seg) > 1:
            inner = " ".join(seg[1:])
        if inner is not None:
            reason, more = check_command(inner, here, g, depth + 1)
            if reason:
                return reason, []
            contexts += more
        if head in INTERPRETERS and any(t in ("-c", "-e") for t in seg) and any(PUSH_IN_STRING.search(t) for t in seg[1:]):
            return PUSH_IN_SCRIPT, []
        if seg[0] == "git":
            gseg = split_redirects(seg)[1] or seg    # `2>&1` is not a refspec or an argument
            repo_dir, args, _cfg = git_parts(gseg, here, penv)
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
                return reason, []
            if alias_cmd is not None:
                reason, more = check_command(alias_cmd, repo_dir, g, depth + 1)
                if reason:
                    return reason, []
                contexts += more
            reason = check_vault_git(args, repo_dir, vault, g.ctx) or check_worktree_remove(args, repo_dir, g.root, g.ctx)
            if reason:
                return reason, []
        removed, filled = tree_operands(seg)
        for op in removed + filled:
            reason = transcript_ancestor(g.root, resolve(here, op), op in filled and op not in removed)
            if reason:
                return reason, []
        ops = write_operands(seg)
        if seg[0] == "patch" and any(t.startswith("<") for t in seg[1:]):
            ops.append(".")        # patch < file writes its cwd (§7.3)
        for op in ops:
            p = resolve(here, op)
            if hooks_path(p):
                return HOOKS_WRITE % op, []
            reason, context = bh.write_check(g.root, g.ctx, p, g.sid, g.refused)
            if reason:
                return reason, []
            if context:
                contexts.append(context)
            if v.is_protected(g.root, p):
                return "%s is distribution code (or evidence); write a proposal instead of editing it." % p, []
    return None, contexts


def main() -> int:
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
    try:
        reason, contexts = check_command(cmd, cwd, G(root, ctx, target, refused, sid))
    except Exception:
        return 0
    if reason:
        deny(reason)
    elif contexts:
        # Every operand was checked; the warning(s) go through as context with the write (§4.6).
        v.emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "\n".join(contexts)}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
