#!/usr/bin/env python3
"""PreToolUse(Bash) guard: the speed bump in front of the boundary check.

Denies, with a reason, pushes to the trunk and commits on the trunk inside
the target, destructive git, and writes whose operand resolves to a protected
path of this deployment. The trunk is config.yaml target.branch, read through
verifylib.target_branch — never a hardcoded "main": a GitLab deployment whose
trunk is `mainline` had a guard that denied `main` and let `mainline` through
(the same defect class PROP-019 fixed in the promotion gate). "main" and
"master" stay denied alongside the configured trunk as defense in depth for a
config that names the wrong one; neither is ever a feature branch — and so
does the remote's default branch (refs/remotes/origin/HEAD), because the
config that names the wrong trunk is exactly the one doctor cannot tell from
a deliberately non-default trunk. A push
whose refspec names the current commit (`HEAD`, `@`) is resolved to the
current branch before that comparison, and `--all`/`--mirror` are denied
outright inside the target: both push the trunk whatever branch is checked
out. Relative paths resolve against the hook's `cwd`, then any
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
fails CLOSED for git inside `target/`: with no trunk to compare against,
a push or commit there is denied rather than waved through (the same rule
boundary-hook.py applies since PROP-019). Everything this guard can be
routed around is caught by boundary-hook.py from git state.

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

import importlib
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import List, Optional, Tuple

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


def git_repo_and_args(seg: List[str], cwd: Path) -> Tuple[Path, List[str]]:
    repo = cwd
    i = 1
    while i < len(seg) and seg[i].startswith("-"):
        if seg[i] == "-C" and i + 1 < len(seg):
            repo = resolve(repo, seg[i + 1])
            i += 2
            continue
        if seg[i] == "-c" and i + 1 < len(seg):
            i += 2
            continue
        i += 1
    return repo, seg[i:]


under = bh.under


def branch_of(repo: Path) -> str:
    code, out, _ = v.run(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"])
    return out.strip() if code == 0 else ""


def check_git(seg: List[str], cwd: Path, target: Optional[Path], branch_created: bool,
              refused: str = "") -> Optional[str]:
    repo, args = git_repo_and_args(seg, cwd)
    if not args:
        return None
    sub = args[0]
    rest = args[1:]
    if refused and sub in ("push", "commit") and under(repo, v.ROOT):
        # §4.4: a session no lease names, while leases exist, fails closed —
        # the tree it would push or commit from is not known.
        return refused
    for a, b in DESTRUCTIVE:
        if sub == a and (b in rest or (b == "-f" and any(r.startswith("-f") for r in rest))):
            if not (sub == "checkout" and rest and rest[-1] != "."):
                return "`git %s %s` destroys work; ask the operator." % (a, b)
    if sub not in ("push", "commit"):
        return None
    if target is None:
        # config.yaml could not be read, so the trunk is unknown. A repo under
        # this deployment's target/ is still the target: fail closed there.
        if under(repo, (v.ROOT / "target").resolve()):
            return "config.yaml cannot be read, so the trunk is unknown; refusing `git %s` inside the target until it is fixed." % sub
        return None
    if not under(repo, target):
        return None
    if sub == "push":
        if any(r in ("--force", "-f") or r.startswith("--force") or r.startswith("-f") for r in rest):
            return "The operator merges; a forced push rewrites history — push your branch, without --force."
        trunk = v.target_branch(v.ROOT)
        if any(r in PUSH_EVERYTHING for r in rest):
            return "The operator merges; `git push %s` pushes %s too — push your branch by name." % (
                next(r for r in rest if r in PUSH_EVERYTHING), trunk)
        cur = branch_of(repo)
        # `push origin HEAD` / `push -u origin HEAD` / `push origin @` push the
        # current branch to its same-named remote branch: resolve before comparing.
        dests = [cur if d in ("HEAD", "@") else d for d in push_destinations(rest)]
        if PUSH_MATCHING in dests:
            return "The operator merges; the refspec `:` pushes every matching branch, %s too — push your branch by name." % trunk
        if not dests and cur in trunk_names(trunk, repo):
            return "The operator merges; you are on %s — switch to a branch and push that, not %s." % (cur, trunk)
        hit = [d for d in dests if d in trunk_names(trunk, repo)]
        if hit:
            return "The operator merges; push your branch, not %s." % hit[0]
    if sub == "commit" and not branch_created:
        trunk = v.target_branch(v.ROOT)
        if branch_of(repo) in trunk_names(trunk, repo):
            return "Branch first (`git switch -c fix/<slug>`), then commit — you are on %s." % branch_of(repo)
    return None


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
    positionals: List[str] = []
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            positionals.extend(rest[i + 1:])
            break
        if a.startswith("-"):
            if a in PUSH_VALUE_OPTS and "=" not in a:
                i += 2
                continue
            i += 1
            continue
        positionals.append(a)
        i += 1
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
        tokens = tokenize(cmd)
    except ValueError:
        # Still unparseable with the heredoc bodies gone (a quote the shell leaves open): the
        # redirect / -i operands the regex finds get the FULL write check, not is_protected
        # alone — the lease-era denials have no Stop backstop for hot.md or the prime's checkout.
        try:
            for m in re.finditer(r"(?:>>?|\s-i(?:\s+\S+)?\s)\s*([A-Za-z0-9_./~-]+)", cmd):
                p = resolve(cwd, m.group(1))
                reason, _ = bh.write_check(root, ctx, p, sid, refused)
                if reason:
                    deny(reason)
                    return 0
                if v.is_protected(root, p):
                    deny("%s is distribution code; write a proposal instead of editing it." % p)
                    return 0
        except Exception:
            return 0
        return 0
    try:
        branch_created = False
        here = cwd
        vault = (root / "vault").resolve()
        contexts: List[str] = []          # cross-lease warnings already given this session (§4.6 second attempt)
        for seg in segments(tokens):
            if not seg:
                continue
            if strips_session_variable(seg):
                deny(STRIP_REASON)
                return 0
            if seg[0] == "cd" and len(seg) >= 2:
                here = resolve(here, seg[1])
                continue
            if seg[0] == "git":
                seg = split_redirects(seg)[1] or seg    # `2>&1` is not a refspec or an argument
                repo_dir, args = git_repo_and_args(seg, here)
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
                reason = check_git(seg, here, target, branch_created, refused)
                if reason:
                    deny(reason)
                    return 0
                reason = check_vault_git(args, repo_dir, vault, ctx) or check_worktree_remove(args, repo_dir, root, ctx)
                if reason:
                    deny(reason)
                    return 0
            removed, filled = tree_operands(seg)
            for op in removed + filled:
                reason = transcript_ancestor(root, resolve(here, op), op in filled and op not in removed)
                if reason:
                    deny(reason)
                    return 0
            for op in write_operands(seg):
                p = resolve(here, op)
                reason, context = bh.write_check(root, ctx, p, sid, refused)
                if reason:
                    deny(reason)
                    return 0
                if context:
                    contexts.append(context)
                if v.is_protected(root, p):
                    deny("%s is distribution code (or evidence); write a proposal instead of editing it." % p)
                    return 0
        if contexts:
            # Every operand was checked; the warning(s) go through as context with the write (§4.6).
            v.emit({"hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": "\n".join(contexts)}})
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
