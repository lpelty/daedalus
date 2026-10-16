#!/usr/bin/env python3
"""Code context at implementation time (code-context design, v0.9.0).

    python3 core/context.py callers   <file>::<function> | <function>  [--json]
    python3 core/context.py importers <file>                           [--json]
    python3 core/context.py tests     <file> | <file>::<function>      [--json]
    python3 core/context.py reach     <file> | <file>::<function>      [--json]
    python3 core/context.py grep      "<text>"                         [--json]
    python3 core/context.py rules --check
    python3 core/context.py rebuild [<repo>] [--timeout <s>]
    python3 core/context.py --doctor

Answers "what else does this change touch?" for the target. Every answer merges
Code Review Graph (optional, PyPI code-review-graph pinned 2.3.9, when config
context.graph names it), `git grep` and the rules, file by file, and labels each
file: both, graph only, grep only, or rule:<name> (§6). What it lists are
candidates, not answers.

It runs only when invoked: no hook calls it, nothing builds an index at session
start, nothing refreshes in the background. Inside a window the index is brought
up to date inside the query that needs it (§7), and the query is recorded in
state/code-context/<NN>/queries.jsonl (§8), which promote compares with what the
window changed (misses(), §9). Outside a window (an operator shell, a visitor, a
gate run or promote's scratch) it answers from grep and rules alone and writes
nothing anywhere under state/.

Exit 0 when it answered (even with zero hits, even when the graph failed); 2 for
usage errors and a Refused resolution. Python 3.9, standard library only; Code
Review Graph runs as a subprocess from its own virtual environment.
"""
from __future__ import annotations

import fcntl
import fnmatch
import json
import os
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

PINNED = "2.3.9"                      # the one version this release reads; any other is treated as absent (§7 step 1)
ALLOWED = ("-v", "build", "update", "query", "impact")   # the only code-review-graph subcommands ever run (§5)
NAME_GLOBS = ("test_*.py", "*_test.py", "conftest.py", "*.bats", "*.test.*", "*.spec.*")
TEST_DIRS = ("tests", "test")        # tests/** and test/**
PRINT_CAP = 200
JSON_CAP = 1000
BROAD = 200                          # a grep answer over this many files predicts nothing (§8)
IMPACT_DEPTH = 2                     # fixed, so misses stay comparable from one window to the next (§5)
IMPACT_MAX = 500
DEFAULT_BUDGET = 90
DEFAULT_BUILD = 80
VERSION_TIMEOUT = 10
RULES_TIMEOUT = 15.0
LONG_LINE = 4000
GREP_TIMEOUT = 60
CANDIDATES = "These are candidates, not answers: read each file, and let the tests decide."
VERBS = ("callers", "importers", "tests", "reach", "grep")
LABELS = ("both", "graph only", "grep only")
USAGE = ("usage: python3 core/context.py callers <file>::<function> | <function>, importers <file>, "
         "tests <file>[::<function>], reach <file>[::<function>], grep \"<text>\" (add --json for structure); "
         "rules --check; rebuild [<repo>] [--timeout <s>]")


class Usage(Exception):
    """A usage error or a Refused resolution: one sentence, exit 2."""


def daedalus_root() -> Path:
    env = os.environ.get("DAEDALUS_HOME")
    return Path(env).resolve() if env else Path(__file__).resolve().parent.parent


def cc_dir(root: Path) -> Path:
    return root / "state" / "code-context"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --- config: one lib.sh call, cfg/cfg_pairs the one parser (§10.3) -----------------------------------

class Cfg:
    def __init__(self) -> None:
        self.graph: Optional[str] = None
        self.module_roots: Optional[List[str]] = None
        self.placeholders: Dict[str, str] = {}
        self.budget = float(DEFAULT_BUDGET)
        self.build_timeout = float(DEFAULT_BUILD)
        self.fingerprint_exclude: List[str] = []
        self.ruff_leftover = False
        self.name: Optional[str] = None
        self.nested: List[str] = []


CFG_SNIPPET = r'''
for k in context.graph context.module_roots context.graph_budget context.build_timeout target.fingerprint_exclude recall.ruff; do
  if val="$(cfg "$k" 2>/dev/null)"; then printf 'K\t%s\t%s\n' "$k" "$val"; fi
done
if pairs="$(cfg_pairs context.placeholders 2>/dev/null)"; then printf '%s\n' "$pairs" | sed 's/^/P	/'; fi
if n="$(target_name 2>/dev/null)"; then printf 'N\t%s\n' "$n"; fi
if pairs="$(cfg_pairs target.nested 2>/dev/null)"; then printf '%s\n' "$pairs" | cut -f1 | sed 's/^/R	/'; fi
true
'''


def _number(raw: str, default: float) -> float:
    try:
        n = float(raw)
        return n if n > 0 else default
    except ValueError:
        return default


def read_config(root: Path) -> Cfg:
    c = Cfg()
    code, out, _ = v._lib_full(root, CFG_SNIPPET, timeout=10)
    if code != 0:
        return c
    for ln in out.splitlines():
        parts = ln.split("\t")
        if parts[0] == "K" and len(parts) >= 3:
            k, val = parts[1], "\t".join(parts[2:]).strip()
            if k == "context.graph":
                c.graph = val
            elif k == "context.module_roots":
                c.module_roots = [norm_dir(x) for x in val.split(",") if x.strip()]
            elif k == "context.graph_budget":
                c.budget = _number(val, DEFAULT_BUDGET)
            elif k == "context.build_timeout":
                c.build_timeout = _number(val, DEFAULT_BUILD)
            elif k == "target.fingerprint_exclude":
                c.fingerprint_exclude = [x.strip().strip("/") for x in val.split(",") if x.strip()]
            elif k == "recall.ruff":
                c.ruff_leftover = True
        elif parts[0] == "P" and len(parts) >= 3 and parts[1].strip():
            c.placeholders[parts[1].strip()] = norm_dir(parts[2])
        elif parts[0] == "N" and len(parts) >= 2:
            c.name = parts[1].strip()
        elif parts[0] == "R" and len(parts) >= 2 and parts[1].strip():
            c.nested.append(parts[1].strip().strip("/"))
    c.build_timeout = min(c.build_timeout, c.budget)
    return c


def norm_dir(d: str) -> str:
    d = posixpath.normpath(d.strip().strip("/")) if d.strip().strip("/") else ""
    return "" if d == "." else d


# --- the tree (§5 Paths, The tree) --------------------------------------------------------------------

class Tree:
    """The outer repo's checkout and the repos in it: (repo name, prefix) — prefix '' for the outer one,
    the nested path for each nested repo present. Paths everywhere are relative to `root`."""

    def __init__(self, root: Path, outer: str, nested: List[str]) -> None:
        self.root = root
        self.outer = outer
        self.repos: List[Tuple[str, str]] = [(outer, "")]
        for n in sorted(nested, key=len, reverse=True):
            if (root / n / ".git").exists():
                self.repos.append(("%s/%s" % (outer, n), n))

    def repo_dir(self, prefix: str) -> Path:
        return self.root / prefix if prefix else self.root

    def repo_of(self, rel: str) -> Tuple[str, str]:
        """(repo name, prefix) of the innermost repo holding rel."""
        for name, pre in self.repos[1:]:
            if rel == pre or rel.startswith(pre + "/"):
                return name, pre
        return self.repos[0]

    def nested_prefixes(self) -> List[str]:
        return [pre for _, pre in self.repos[1:]]


class Where:
    """Where an invocation runs: the tree, and the window when it runs in one."""

    def __init__(self, tree: Tree, window: Optional[str], lease: Optional[dict], sid: Optional[str],
                 why: str) -> None:
        self.tree, self.window, self.lease, self.sid, self.why = tree, window, lease, sid, why


def my_lease(root: Path, sid: Optional[str]) -> Tuple[Optional[str], Optional[dict]]:
    """leaselib's my-lease, in process: this session's lease number and file, or (None, None)."""
    if not sid or not (root / "state" / "leases").is_dir():
        return None, None
    import leaselib as ll
    try:
        with ll.lock(root, shared=True):
            return ll.lease_of_session(ll.read_all(root), sid)
    except ll.Refused:
        return None, None


def resolve_where(root: Path, cfg: Cfg) -> Where:
    if not cfg.name:
        raise Usage("The target is not configured (target.repo in config.yaml), so there is no tree to search.")
    visitor = bool(os.environ.get("DIRECT_CALL_ID"))
    override = bool(os.environ.get("DAEDALUS_TARGET_OVERRIDE", "").strip())
    if visitor and not override:
        # A visitor holds no window and writes nothing (§4.8): grep and rules over the prime's checkout.
        return Where(Tree(root / "target" / cfg.name, cfg.name, cfg.nested), None, None, None, "visitor")
    import leaselib as ll
    sid = ll.session_id_from_env()
    r = v.resolve_target(root, sid)
    if isinstance(r, v.Refused):
        raise Usage(r.sentence)
    if not isinstance(r, v.Resolved):
        raise Usage("The target tree is not known (%s), so there is nothing to search." % r.reason)
    tree = Tree(r.path, cfg.name, cfg.nested)
    if override or visitor:
        return Where(tree, None, None, None, "override")
    nn, lease = my_lease(root, sid)
    if nn and lease is not None:
        wt = (root / str(lease.get("worktree") or ("worktrees/%s" % nn)) / cfg.name).resolve()
        if wt == r.path.resolve():
            return Where(tree, nn, lease, sid, "window")
    return Where(tree, None, None, sid, "outside")


def tree_label(root: Path, tree: Tree) -> str:
    try:
        return tree.root.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return str(tree.root)


# --- the subject ---------------------------------------------------------------------------------------

class Subject:
    def __init__(self, files: List[str], symbol: Optional[str], repo: str, prefix: str) -> None:
        self.files, self.symbol, self.repo, self.prefix = files, symbol, repo, prefix

    @property
    def file(self) -> Optional[str]:
        return self.files[0] if self.files else None


def tree_rel(tree: Tree, p: str) -> Optional[str]:
    """A path as the tree names it: relative to the outer checkout. None when outside it."""
    if os.path.isabs(p):
        for base in (tree.root, tree.root.resolve()):
            try:
                return Path(os.path.normpath(p)).relative_to(base).as_posix()
            except ValueError:
                pass
        try:
            return Path(p).resolve().relative_to(tree.root.resolve()).as_posix()
        except (ValueError, OSError):
            return None
    rel = posixpath.normpath(p)
    if rel.startswith("../") or rel == "..":
        return None
    return "" if rel == "." else rel


def parse_subject(verb: str, arg: str, tree: Tree) -> Subject:
    if verb == "grep":
        if not arg:
            raise Usage("grep needs the text to search for: python3 core/context.py grep \"<text>\"")
        return Subject([], None, tree.outer, "")
    f, sym = (arg.split("::", 1) if "::" in arg else ((None, arg) if verb == "callers" else (arg, None)))
    if verb == "callers" and not sym:
        raise Usage("callers needs a function: python3 core/context.py callers <file>::<function> or <function>")
    if verb == "importers" and sym:
        raise Usage("importers takes a file, not a function: python3 core/context.py importers <file>")
    if sym is not None and not re.fullmatch(r"[A-Za-z_][\w.]*", sym):
        if verb == "callers" and f is None:
            raise Usage("callers needs a function: python3 core/context.py callers <file>::<function> or <function>")
        raise Usage("%s is not a function name." % sym)
    if f is None:
        return Subject([], sym, tree.outer, "")
    rel = tree_rel(tree, f)
    if not rel:
        raise Usage("%s is not inside the tree this session searches (%s)." % (f, tree.root))
    if not (tree.root / rel).is_file():
        raise Usage("There is no file %s in %s." % (rel, tree.root))
    name, pre = tree.repo_of(rel)
    return Subject([rel], sym, name, pre)


# --- tests, module names ---------------------------------------------------------------------------------

def is_test_path(rel: str) -> bool:
    parts = rel.split("/")
    if any(fnmatch.fnmatchcase(parts[-1], g) for g in NAME_GLOBS):
        return True
    return any(p in TEST_DIRS for p in parts[:-1])


def module_roots(tree: Tree, cfg: Cfg, tracked: Optional[Set[str]] = None) -> List[str]:
    """context.module_roots, or the tree root plus every directory holding a tracked pyproject.toml."""
    if cfg.module_roots is not None:
        return cfg.module_roots
    roots = [""]
    files = tracked if tracked is not None else ls_files(tree, untracked=False)
    for f in sorted(files):
        if f == "pyproject.toml" or f.endswith("/pyproject.toml"):
            d = posixpath.dirname(f)
            if d not in roots:
                roots.append(d)
    return roots


def dotted_under(rel: str, root: str) -> Optional[str]:
    """rel's dotted module name relative to the directory root ('' = the tree root), or None."""
    if not rel.endswith(".py"):
        return None
    if root:
        if not rel.startswith(root + "/"):
            return None
        rel = rel[len(root) + 1:]
    parts = rel[:-3].split("/")
    if parts[-1] in ("__init__", "__main__"):
        parts = parts[:-1]
    if not parts or not all(p.isidentifier() for p in parts):
        return None
    return ".".join(parts)


def module_names(rel: str, roots: List[str]) -> List[str]:
    out: List[str] = []
    for r in roots:
        d = dotted_under(rel, r)
        if d and d not in out:
            out.append(d)
    return sorted(out, key=len, reverse=True)


def stem_of(rel: str) -> str:
    base = posixpath.basename(rel)
    stem = base[:-3] if base.endswith(".py") else base.rsplit(".", 1)[0]
    if stem in ("__init__", "__main__"):
        stem = posixpath.basename(posixpath.dirname(rel)) or stem
    return stem


# --- git grep and ls-files over every repo of the tree --------------------------------------------------

def _git(cwd: Path, args: List[str], timeout: float = GREP_TIMEOUT) -> Tuple[int, str]:
    try:
        r = subprocess.run(["git", "-C", str(cwd)] + args, capture_output=True, text=True, timeout=timeout,
                           errors="replace")
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def _owned(tree: Tree, pre: str, rel: str) -> bool:
    """A path the repo at `pre` answers for: the outer repo never answers inside a nested one."""
    if pre:
        return True
    return not any(rel == n or rel.startswith(n + "/") for n in tree.nested_prefixes())


def ls_files(tree: Tree, untracked: bool = True) -> Set[str]:
    out: Set[str] = set()
    for _, pre in tree.repos:
        args = ["ls-files", "-z", "--cached"] + (["--others", "--exclude-standard"] if untracked else [])
        code, text = _git(tree.repo_dir(pre), args)
        if code != 0:
            continue
        for p in text.split("\0"):
            if p:
                rel = "%s/%s" % (pre, p) if pre else p
                if _owned(tree, pre, rel):
                    out.add(rel)
    return out


def git_grep(tree: Tree, literal: str, word: bool = False, regex: Optional["re.Pattern"] = None,
             only: Optional[List[str]] = None) -> Dict[str, List[Tuple[int, str]]]:
    """{tree-relative file: [(line, text)]} for every line holding `literal` (-F, word-bounded with -w),
    kept only when `regex` (Python) also matches it. git grep -n -I --untracked in every repo of the tree:
    untracked files are searched, ignored ones are not. `only` limits it to those paths."""
    hits: Dict[str, List[Tuple[int, str]]] = {}
    for _, pre in tree.repos:
        args = ["grep", "-n", "-z", "-I", "--untracked", "--no-color", "-F"] + (["-w"] if word else []) + ["-e", literal]
        if only is not None:
            mine = [p[len(pre) + 1:] if pre else p for p in only
                    if (p.startswith(pre + "/") if pre else _owned(tree, "", p))]
            if not mine:
                continue
            args += ["--"] + mine
        code, text = _git(tree.repo_dir(pre), args)
        if code not in (0, 1):
            continue
        for ln in text.split("\n"):
            parts = ln.split("\0", 2)
            if len(parts) < 3:
                continue
            path, n, body = parts
            rel = "%s/%s" % (pre, path) if pre else path
            if not _owned(tree, pre, rel):
                continue
            if regex is not None and not regex.search(body):
                continue
            try:
                hits.setdefault(rel, []).append((int(n), body))
            except ValueError:
                continue
    return hits


class Pattern:
    def __init__(self, literal: str, why: str, word: bool = False, regex: Optional[str] = None) -> None:
        self.literal, self.why, self.word = literal, why, word
        self.regex = re.compile(regex) if regex else None


def callers_patterns(sym: str) -> List[Pattern]:
    last = sym.rsplit(".", 1)[-1]
    return [Pattern(last, last, word=True)]


def importers_patterns(rel: str, roots: List[str]) -> List[Pattern]:
    base, stem = posixpath.basename(rel), stem_of(rel)
    pats: List[Pattern] = []
    if base not in ("__init__.py", "__main__.py"):     # bounded on the left: e.py is not a hit in make-e.py or core.py
        pats.append(Pattern(base, base, regex=r"(?<![\w-])%s" % re.escape(base)))
    for d in module_names(rel, roots):
        if "." in d:            # a one-segment name (cli, e) would be a substring search; the import patterns cover it
            pats.append(Pattern(d, d))
    if stem.isidentifier():
        s = re.escape(stem)
        pats.append(Pattern(stem, "import %s" % stem, regex=r"\bimport\s+%s\b" % s))
        pats.append(Pattern(stem, "from … import %s" % stem,
                            regex=r"\bfrom\s+[A-Za-z0-9_.]+\s+import\s.*\b%s\b" % s))
        pats.append(Pattern(stem, "from %s import" % stem, regex=r"\bfrom\s+\.*%s\s+import\b" % s))
    return pats


def verb_patterns(verb: str, subj: Subject, roots: List[str], arg: str) -> List[Pattern]:
    if verb == "grep":
        return [Pattern(arg, arg)]
    if verb == "callers" or (verb == "tests" and subj.symbol):
        return callers_patterns(subj.symbol or "")
    if verb in ("importers", "tests") or (verb == "reach" and not subj.symbol):
        return importers_patterns(subj.file or "", roots)
    # reach F::f: as callers, plus the basename of F
    base = posixpath.basename(subj.file or "")
    return callers_patterns(subj.symbol or "") + ([Pattern(base, base)] if base else [])


def grep_part(tree: Tree, pats: List[Pattern], tests_only: bool) -> Dict[str, dict]:
    out: Dict[str, dict] = {}
    for p in pats:
        for rel, rows in git_grep(tree, p.literal, word=p.word, regex=p.regex).items():
            if tests_only and not is_test_path(rel):
                continue
            h = out.setdefault(rel, {"lines": set(), "why": []})
            h["lines"].update(n for n, _ in rows)
            if "grep: " + p.why not in h["why"]:
                h["why"].append("grep: " + p.why)
    return out


# --- the graph (§7, §11): optional, never fatal ---------------------------------------------------------

class GraphInfo:
    def __init__(self, state: str, note: Optional[str] = None, version: Optional[str] = None,
                 seconds: Optional[float] = None, action: Optional[str] = None) -> None:
        self.state, self.note, self.version, self.seconds, self.action = state, note, version, seconds, action

    def as_json(self) -> dict:
        return {"state": self.state, "version": self.version,
                "seconds": round(self.seconds, 2) if self.seconds is not None else None, "note": self.note}


NOT_INSTALLED = "not installed (context.graph in config.yaml)"


class GraphFail(Exception):
    """A graph call that did not give a usable answer: graph state `failed` for this answer only."""


class Budget(Exception):
    """The invocation's one deadline ran out: graph state `skipped` (time)."""


def remaining(deadline: float) -> float:
    return deadline - time.monotonic()


def exe_problem(cfg: Cfg) -> Optional[str]:
    if not cfg.graph:
        return NOT_INSTALLED
    p = cfg.graph
    if not os.path.isabs(p) or not os.path.isfile(p) or not os.access(p, os.X_OK):
        return "context.graph is %s, which is not an executable file" % p
    return None


def crg_env(root: Path, exe: str, data_dir: Optional[Path]) -> dict:
    """The allowlist (§7): never the caller's environment, so no API key reaches the tool, cloud embeddings
    cannot turn on, and ~/.code-review-graph is never written."""
    home = cc_dir(root) / "home"
    try:
        home.mkdir(parents=True, exist_ok=True)
    except OSError:
        pass                        # the call itself then fails, and says so; never this process
    path = ["/usr/bin", "/bin", os.path.dirname(exe)]
    git = shutil.which("git")
    if git:
        path.append(os.path.dirname(git))
    seen: List[str] = []
    for d in path:
        if d not in seen:
            seen.append(d)
    env = {"PATH": ":".join(seen), "HOME": str(home), "CRG_HOME": str(home)}
    if data_dir is not None:
        env["CRG_DATA_DIR"] = str(data_dir)
    for k in ("LANG", "LC_ALL", "TMPDIR"):
        if k in os.environ:
            env[k] = os.environ[k]
    return env


LIVE: List[subprocess.Popen] = []      # children running now: a SIGTERM/SIGINT/SIGHUP to this process stops them


def descendants(pid: int) -> List[int]:
    """Every process below pid (ps once; a child may run its own children, as a build or a fake's sleep does)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="], stdin=subprocess.DEVNULL,
                             capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    kids: Dict[int, List[int]] = {}
    for ln in out.splitlines():
        f = ln.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            kids.setdefault(int(f[1]), []).append(int(f[0]))
    found: List[int] = []
    todo = [pid]
    while todo:
        for k in kids.get(todo.pop(), []):
            if k not in found:
                found.append(k)
                todo.append(k)
    return found


def kill_tree(proc: subprocess.Popen) -> None:
    """SIGKILL proc and everything below it. The children stay in this process's group (no new session), so a
    kill of the caller's group reaches them too; this is for the timeout and the signal handler."""
    for pid in [proc.pid] + descendants(proc.pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def _stop_children(signum: int, _frame: object) -> None:
    for p in list(LIVE):
        kill_tree(p)
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)


def crg_run(exe: str, args: List[str], env: dict, cwd: Path, timeout: float) -> Tuple[int, str, str, bool]:
    """(exit, stdout, stderr, timed out). Only the allowlisted subcommands; the child and everything below it
    are killed at the timeout, so nothing is left running."""
    if not args or args[0] not in ALLOWED:
        raise GraphFail("code-review-graph %s is not a call core/context.py makes" % (args[:1] or ["?"])[0])
    if timeout <= 0:
        return 1, "", "", True
    try:
        proc = subprocess.Popen([exe] + args, cwd=str(cwd), env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors="replace")
    except OSError as e:
        raise GraphFail("it could not be started (%s)" % (e.strerror or e))
    LIVE.append(proc)
    try:
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out, err, False
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        out, err = proc.communicate()
        return proc.returncode if proc.returncode is not None else -9, out or "", err or "", True
    finally:
        LIVE.remove(proc)


def read_json_file(p: Path) -> Optional[dict]:
    try:
        d = json.loads(p.read_text())
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def write_json_file(p: Path, data: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name(".%s.%d.tmp" % (p.name, os.getpid()))
    tmp.write_text(json.dumps(data, indent=2))
    os.replace(str(tmp), str(p))


def dist_info(exe: str) -> List[List[object]]:
    """[name, mtime] of each code_review_graph-*.dist-info in the venv that holds exe (<venv>/bin/<exe>)."""
    out: List[List[object]] = []
    for d in sorted(Path(exe).parent.parent.glob("lib/python*/site-packages/code_review_graph-*.dist-info")):
        try:
            out.append([d.name, d.stat().st_mtime])
        except OSError:
            continue
    return out


def graph_version(root: Path, exe: str) -> Tuple[Optional[str], Optional[str]]:
    """(version, problem). `-v` once per executable: cached in state/code-context/home/version.json,
    keyed on the executable's path, size and mtime, and on the venv's code_review_graph dist-info directories
    (an upgrade in place can leave the console-script wrapper byte-identical)."""
    cache = cc_dir(root) / "home" / "version.json"
    try:
        st = os.stat(exe)
        key = {"path": exe, "size": st.st_size, "mtime": st.st_mtime, "dist": dist_info(exe)}
    except OSError as e:
        return None, "context.graph is %s, which cannot be read (%s)" % (exe, e.strerror)
    c = read_json_file(cache) or {}
    if all(c.get(k) == key[k] for k in key) and c.get("version"):
        ver = str(c["version"])
    else:
        rc, out, err, to = crg_run(exe, ["-v"], crg_env(root, exe, None), root, VERSION_TIMEOUT)
        m = re.search(r"code-review-graph\s+(\S+)", out + "\n" + err)
        if to or rc != 0 or not m:
            return None, "%s -v did not answer with a version%s" % (
                exe, " (timed out after %d s)" % VERSION_TIMEOUT if to else "")
        ver = m.group(1)
        try:
            write_json_file(cache, dict(key, version=ver))
        except OSError:
            pass
    if ver != PINNED:
        return ver, "%s is code-review-graph %s, not the pinned %s" % (exe, ver, PINNED)
    return ver, None


def repo_key(repo: str) -> str:
    return repo.replace("/", "__")


class Lock:
    """flock LOCK_EX on <repo-key>.lock, BESIDE the index directory (a rebuild deletes the directory; a lock
    inside it would let a waiter lock a fresh inode and run alongside the build). Polls until the deadline."""

    def __init__(self, path: Path) -> None:
        self.path, self.fd = path, None

    def take(self, deadline: float) -> bool:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o644)
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    return False
                time.sleep(0.05)

    def release(self) -> None:
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None


BUILD_FAILED = {"build": "the first index build failed", "rebuild": "the index rebuild after a failed update failed"}
BUDGET_SLACK = 1.0      # a build given less than build_timeout minus this was cut short by the time budget


def build_failed_sentence(meta: dict) -> str:
    return ("%s at %s (%s); python3 core/context.py rebuild --timeout 600 tries again "
            "(give that Bash call a 600 s timeout)" % (BUILD_FAILED.get(str(meta.get("kind")), BUILD_FAILED["build"]),
                                                       meta.get("failed_at") or "?",
                                                       meta.get("failed_reason") or "no reason recorded"))


class Index:
    """One window's index of one repo: state/code-context/<NN>/<repo-key>/ (CRG_DATA_DIR), its meta.json, and
    its lock file beside it (§7). Caller holds the lock for every method but take()."""

    def __init__(self, root: Path, where: Where, repo: str, repo_dir: Path, exe: str, version: str) -> None:
        wdir = cc_dir(root) / str(where.window)
        self.dir = wdir / repo_key(repo)
        self.lock = Lock(wdir / (repo_key(repo) + ".lock"))
        self.meta_path = self.dir / "meta.json"
        self.repo, self.repo_dir, self.exe, self.root = repo, repo_dir, exe, root
        self.want = {"lease": where.window, "lease_created": (where.lease or {}).get("created"),
                     "worktree": str(repo_dir), "version": version}
        self.env = crg_env(root, exe, self.dir)

    def meta(self) -> Optional[dict]:
        return read_json_file(self.meta_path)

    def current(self, m: Optional[dict]) -> bool:
        return m is not None and all(m.get(k) == self.want[k] for k in self.want)

    def build(self, timeout: float, kind: str = "build", cut: bool = False) -> Tuple[bool, str, float]:
        """Delete the index and build it. (ok, output, seconds); a failure is recorded in meta.json, except a
        timeout when `cut` (the time budget, not build_timeout, set the timeout): then meta.json is removed, so
        the next query builds again instead of skipping the graph until a manual rebuild."""
        shutil.rmtree(str(self.dir), ignore_errors=True)
        self.dir.mkdir(parents=True, exist_ok=True)
        meta = dict(self.want, built_at=None, build_seconds=None, state="building", pid=os.getpid(),
                    failed_reason=None, kind=kind)
        write_json_file(self.meta_path, meta)
        t0 = time.monotonic()
        rc, out, err, to = crg_run(self.exe, ["build", "--repo", str(self.repo_dir)], self.env, self.repo_dir, timeout)
        secs = time.monotonic() - t0
        if to and cut:
            try:
                self.meta_path.unlink()
            except OSError:
                pass
            return False, out + err, secs
        if to or rc != 0:
            meta.update(state="build-failed", failed_at=time.strftime("%H:%M"),
                        failed_reason=("timed out after %d s" % round(timeout) if to else
                                       "exited %s: %s" % (rc, last_line(err or out) or "no output")))
            write_json_file(self.meta_path, meta)
            return False, out + err, secs
        meta.update(state="ok", built_at=now_iso(), build_seconds=round(secs, 2), pid=None)
        write_json_file(self.meta_path, meta)
        return True, out + err, secs

    def update(self, timeout: float) -> bool:
        rc, _out, _err, to = crg_run(self.exe, ["update", "--repo", str(self.repo_dir)], self.env, self.repo_dir,
                                     timeout)
        return not to and rc == 0

    def mark_stopped(self, m: dict) -> dict:
        # The lock is ours, so the process that wrote `building` is gone (a kill releases its flock).
        m.update(state="build-failed", failed_at=m.get("failed_at") or time.strftime("%H:%M"),
                 failed_reason="did not finish (the process was stopped)", pid=None)
        write_json_file(self.meta_path, m)
        return m

    def build_within(self, cfg: Cfg, deadline: float, kind: str) -> None:
        """build() inside what is left of the budget; raises Budget when the budget cut it short (§7)."""
        left = remaining(deadline)
        if left <= 0:
            raise Budget()
        cut = left < cfg.build_timeout - BUDGET_SLACK
        ok, _, _ = self.build(min(cfg.build_timeout, left), kind, cut)
        if not ok:
            m = self.meta()
            if m is None:
                raise Budget()
            raise GraphFail(build_failed_sentence(m))

    def ready(self, cfg: Cfg, deadline: float) -> str:
        """Bring the index up to date (§7 steps 3-4): 'built' | 'updated'; raises GraphFail / Budget."""
        m = self.meta()
        if m is not None and m.get("state") == "building":
            m = self.mark_stopped(m)
        if self.current(m) and m.get("state") == "build-failed":
            raise GraphFail(build_failed_sentence(m))
        if not self.current(m) or m.get("state") != "ok":
            self.build_within(cfg, deadline, "build")
            return "built"
        if self.update(remaining(deadline)):
            return "updated"
        self.build_within(cfg, deadline, "rebuild")     # an update that fails: rebuild once
        return "rebuilt"

    def ask(self, args: List[str], deadline: float) -> dict:
        rc, out, err, to = crg_run(self.exe, args + ["--repo", str(self.repo_dir)], self.env, self.repo_dir,
                                   remaining(deadline))
        if to:
            raise Budget()
        m = re.search(r"(?m)^\{", out)        # the first line that opens the object; an INFO line may hold a brace
        i = m.start() if m else -1
        if rc != 0 or i < 0:
            raise GraphFail("the graph answer could not be read (%s)" % (
                "exit %s" % rc if rc != 0 else "not JSON"))
        try:
            d = json.loads(out[i:])
        except ValueError:
            raise GraphFail("the graph answer could not be read (not JSON)")
        if not isinstance(d, dict):
            raise GraphFail("the graph answer could not be read (not a JSON object)")
        return d


def last_line(text: str) -> str:
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()]
    return lines[-1][:160] if lines else ""


def _add(out: Dict[str, dict], tree: Tree, path: object, line: object, why: str) -> None:
    if not isinstance(path, str) or not path:
        return
    rel = tree_rel(tree, path) if os.path.isabs(path) else posixpath.normpath(path)
    if not rel or rel.startswith(".."):
        return
    h = out.setdefault(rel, {"lines": set(), "why": []})
    if isinstance(line, int):
        h["lines"].add(line)
    if why not in h["why"]:
        h["why"].append(why)


def _line(node: dict) -> object:
    cs = node.get("call_site")
    if isinstance(cs, dict) and isinstance(cs.get("line"), int):
        return cs["line"]
    return node.get("line_start")


def graph_hits(idx: Index, tree: Tree, verb: str, subj: Subject, deadline: float) -> Dict[str, dict]:
    """The 2.3.9 calls of §5's table, and only the fields it names."""
    out: Dict[str, dict] = {}
    rel_in_repo = None
    absf = None
    if subj.file:
        rel_in_repo = subj.file[len(subj.prefix) + 1:] if subj.prefix else subj.file
        absf = str(idx.repo_dir / rel_in_repo)
    target = ("%s::%s" % (absf, subj.symbol) if absf else subj.symbol) if subj.symbol else absf

    def results(d: dict) -> List[dict]:
        r = d.get("results")
        return [x for x in r if isinstance(x, dict)] if isinstance(r, list) else []

    def callers() -> None:
        for r in results(idx.ask(["query", "callers_of", str(target)], deadline)):
            _add(out, tree, r.get("file_path"), _line(r), "graph: callers of %s" % subj_text(subj))

    def tests_for() -> None:
        for r in results(idx.ask(["query", "tests_for", str(target)], deadline)):
            if r.get("is_test"):
                _add(out, tree, r.get("file_path"), r.get("line_start"), "graph: tests for %s" % subj_text(subj))

    def importers() -> None:
        d = idx.ask(["query", "importers_of", str(absf)], deadline)
        lines: Dict[str, int] = {}
        for e in d.get("edges") or []:
            if isinstance(e, dict) and isinstance(e.get("source"), str) and isinstance(e.get("line"), int):
                lines.setdefault(e["source"], e["line"])
        for r in results(d):
            f = r.get("importer") or r.get("file")
            _add(out, tree, f, lines.get(f) if isinstance(f, str) else None, "graph: importers of %s" % subj.file)

    def impact(tests_only: bool) -> None:
        d = idx.ask(["impact", "--files", str(rel_in_repo), "--depth", str(IMPACT_DEPTH),
                     "--max-results", str(IMPACT_MAX)], deadline)
        why = "graph: impact of %s" % subj.file
        if not tests_only:
            for f in d.get("impacted_files") or []:
                _add(out, tree, f, None, why)
        for n in d.get("impacted_nodes") or []:
            if isinstance(n, dict) and (n.get("is_test") or not tests_only):
                _add(out, tree, n.get("file_path"), _line(n), why)

    if verb == "callers":
        callers()
    elif verb == "importers":
        importers()
    elif verb == "tests":
        tests_for() if subj.symbol else impact(True)
    elif verb == "reach" and subj.symbol:
        callers()
        tests_for()
    elif verb == "reach":
        impact(False)
        importers()
    return out


def subj_text(subj: Subject) -> str:
    return "%s::%s" % (subj.file, subj.symbol) if subj.file and subj.symbol else (subj.symbol or subj.file or "")


def graph_part(root: Path, cfg: Cfg, where: Where, verb: str, subj: Subject,
               deadline: float) -> Tuple[GraphInfo, Dict[str, dict]]:
    if where.window is None:
        return GraphInfo("skipped", "outside a window"), {}
    if verb == "grep":
        return GraphInfo("skipped", "grep asks git grep only"), {}
    problem = exe_problem(cfg)
    if problem:
        return GraphInfo("absent", problem), {}
    t0 = time.monotonic()
    exe = str(cfg.graph)
    version = None
    idx = None
    try:
        version, problem = graph_version(root, exe)
        if problem:
            return GraphInfo("absent", problem, version), {}
        idx = Index(root, where, subj.repo, where.tree.repo_dir(subj.prefix), exe, str(version))
        if not idx.lock.take(deadline):
            return GraphInfo("skipped", "skipped (another query in this window held the index past the %d s "
                                        "time budget)" % round(cfg.budget), version), {}
        action = idx.ready(cfg, deadline)
        hits = graph_hits(idx, where.tree, verb, subj, deadline)
        return GraphInfo("present", None, version, time.monotonic() - t0, action), hits
    except Budget:
        return GraphInfo("skipped", "skipped (the %d s time budget ran out)" % round(cfg.budget), version,
                         time.monotonic() - t0), {}
    except GraphFail as e:
        return GraphInfo("failed", str(e), version, time.monotonic() - t0), {}
    except Exception as e:      # never fatal (§7): the answer still comes from grep and rules
        return GraphInfo("failed", "the graph call failed (%s)" % type(e).__name__, version,
                         time.monotonic() - t0), {}
    finally:
        if idx is not None:
            idx.lock.release()


def rebuild(root: Path, args: List[str]) -> int:
    timeout = None
    rest: List[str] = []
    i = 0
    while i < len(args):
        if args[i] == "--timeout" and i + 1 < len(args):
            timeout = _number(args[i + 1], 0) or None
            if timeout is None:
                raise Usage("--timeout takes a number of seconds: python3 core/context.py rebuild --timeout 600")
            i += 2
        else:
            rest.append(args[i])
            i += 1
    if len(rest) > 1:
        raise Usage(USAGE)
    cfg = read_config(root)
    if not cfg.graph:
        print("No code graph is configured (context.graph in config.yaml), so there is no index to rebuild.")
        return 0
    where = resolve_where(root, cfg)
    if where.window is None:
        print("This session holds no window, so there is no index to rebuild; run it from the window whose index "
              "you want rebuilt.")
        return 0
    problem = exe_problem(cfg)
    version = None
    if not problem:
        version, problem = graph_version(root, str(cfg.graph))
    if problem:
        print("The code graph cannot be used (%s), so there is no index to rebuild." % problem)
        return 0
    tree = where.tree
    repo = rest[0] if rest else tree.outer
    names = {name: pre for name, pre in tree.repos}
    if repo not in names:
        raise Usage("%s is not a repo of this tree; its repos are %s." % (repo, ", ".join(sorted(names))))
    t = timeout or cfg.build_timeout
    idx = Index(root, where, repo, tree.repo_dir(names[repo]), str(cfg.graph), str(version))
    if not idx.lock.take(time.monotonic() + t):
        print("Another query in window %s held the index of %s for %d s, so it was not rebuilt; try again."
              % (where.window, repo, round(t)))
        return 0
    try:
        ok, out, secs = idx.build(t)
    finally:
        idx.lock.release()
    if not ok:
        m = idx.meta() or {}
        print("The code-context index for %s in window %s was not rebuilt (%s). python3 core/context.py rebuild "
              "--timeout 600 tries again (give that Bash call a 600 s timeout)."
              % (repo, where.window, m.get("failed_reason") or "the build failed"))
        return 0
    n = re.findall(r"(\d+)/(\d+) files parsed", out)
    files = "%s files, " % n[-1][1] if n else ""
    print("Rebuilt the code-context index for %s in window %s (%s%.1f s)." % (repo, where.window, files, secs))
    return 0


# --- the rules (§10) -----------------------------------------------------------------------------------

RULE_NAME = re.compile(r"[a-z0-9-]+")
RESOLVES = ("tree", "beside", "roots", "suffix")
SLOT = re.compile(r"\{(\d+)(?::(module|map|join))?\}")
CONFIG_MAP = "config:context.placeholders"
RELEASE_RULES = "core/context-rules.json"
DEPLOY_RULES = "vault/context-rules.json"
CHECK_HINT = "python3 core/context.py rules --check"


def rule_problem(r: object) -> Optional[str]:
    """What is wrong with a rule's shape, or None (§10.2)."""
    if not isinstance(r, dict):
        return "it is not a JSON object"
    if not isinstance(r.get("name"), str) or not RULE_NAME.fullmatch(r["name"]):
        return "its name must be lower-case letters, digits and dashes"
    for k in ("about", "hint", "search", "to"):
        if not isinstance(r.get(k), str) or not r[k].strip():
            return "%s is required" % k
    try:
        rx = re.compile(r["search"])
    except re.error as e:
        return "its search does not compile (%s)" % e
    if r.get("resolve") not in RESOLVES:
        return "resolve must be one of %s" % ", ".join(RESOLVES)
    if "in" in r and not (isinstance(r["in"], list) and all(isinstance(g, str) and g for g in r["in"])):
        return "in must be a list of file globs"
    m = r.get("map")
    if m is not None and m != CONFIG_MAP and not (isinstance(m, dict) and all(isinstance(x, str) for x in m.values())):
        return "map must be an object or \"%s\"" % CONFIG_MAP
    for slot in SLOT.finditer(r["to"]):
        if int(slot.group(1)) > rx.groups:
            return "to names group %s, which its search does not have" % slot.group(1)
        if slot.group(2) == "map" and m is None:
            return "to uses {N:map} but the rule has no map"
    o = r.get("origin")
    if not isinstance(o, dict) or not all(isinstance(o.get(k), str) and o[k].strip() for k in ("date", "window", "why")):
        return "origin needs date, window and why"
    t = r.get("test")
    if not isinstance(t, dict) or not isinstance(t.get("file"), str) or not isinstance(t.get("text"), str) \
            or not isinstance(t.get("expect"), list):
        return "test needs file, text and expect"
    return None


def in_globs(r: dict, rel: str) -> bool:
    globs = r.get("in")
    if not globs:
        return True
    base = posixpath.basename(rel)
    return any(fnmatch.fnmatchcase(rel if "/" in g else base, g) for g in globs)


def rule_map(r: dict, placeholders: Dict[str, str]) -> Dict[str, str]:
    m = r.get("map")
    if m == CONFIG_MAP:
        return placeholders
    return m if isinstance(m, dict) else {}


def expand(r: dict, m: "re.Match", mapping: Dict[str, str]) -> List[str]:
    """The candidate templates of `to`, filled from the match; a slot that cannot be filled drops its template."""
    out: List[str] = []
    for tmpl in r["to"].split(" | "):
        ok = True

        def fill(slot: "re.Match") -> str:
            nonlocal ok
            g = m.group(int(slot.group(1)))
            if g is None:
                ok = False
                return ""
            kind = slot.group(2)
            if kind == "module":
                return g.replace(".", "/")
            if kind == "map":
                if g not in mapping:
                    ok = False
                    return ""
                return mapping[g]
            if kind == "join":
                return "/".join(re.findall(r"[\"']([^\"']+)[\"']", g))
            return g
        cand = SLOT.sub(fill, tmpl.strip())
        if ok and cand:
            out.append(cand)
    return out


def norm_candidate(c: str) -> Optional[str]:
    c = posixpath.normpath(c.lstrip("/"))
    if c in (".", "") or c.startswith("../") or c == "..":
        return None
    return c


def resolve_candidates(r: dict, cands: List[str], rel: str, roots: List[str],
                       files: Optional[Set[str]]) -> List[str]:
    """Paths, tree-relative. `files` None (a rule's own test): nothing is checked for existence."""
    out: List[str] = []
    how = r["resolve"]
    for c in cands:
        if how == "beside":
            ps = [posixpath.join(posixpath.dirname(rel), c)]
        elif how == "roots":
            ps = [posixpath.join(rt, c) if rt else c for rt in roots]
        else:
            ps = [c]
        for p in ps:
            p2 = norm_candidate(p)
            if p2 is None:
                continue
            if how == "suffix" and files is not None:
                out += [f for f in files if f == p2 or f.endswith("/" + p2)]
            elif files is None or p2 in files:
                out.append(p2)
    return sorted(set(out))


def rule_test(r: dict, placeholders: Dict[str, str], roots: List[str]) -> Tuple[bool, List[str]]:
    """A rule's own test, in memory: the regex on `text` as if it sat in `file`, candidates unchecked."""
    t = r["test"]
    got: List[str] = []
    if in_globs(r, t["file"]):
        mapping = t["map"] if isinstance(t.get("map"), dict) else rule_map(r, placeholders)
        rts = [norm_dir(x) for x in t["roots"]] if isinstance(t.get("roots"), list) else roots
        rx = re.compile(r["search"])
        for m in rx.finditer(t["text"]):
            got += resolve_candidates(r, expand(r, m, mapping), t["file"], rts, None)
    got = sorted(set(got))
    return got == sorted(set(str(x) for x in t["expect"])), got


def load_rules(root: Path) -> Tuple[List[Tuple[str, object]], List[dict]]:
    """(every rule as (source, raw), release first; the files that cannot be read, with why)."""
    rules: List[Tuple[str, object]] = []
    problems: List[dict] = []
    for src, rel in (("release", RELEASE_RULES), ("deployment", DEPLOY_RULES)):
        p = root / rel
        if not p.exists():
            continue
        try:
            d = json.loads(p.read_text())
        except OSError as e:
            problems.append({"file": rel, "why": e.strerror or str(e)})
            continue
        except ValueError:
            problems.append({"file": rel, "why": "not valid JSON"})
            continue
        if not isinstance(d, dict) or not isinstance(d.get("rules"), list):
            problems.append({"file": rel, "why": "it has no rules list"})
            continue
        rules += [(src, r) for r in d["rules"]]
    return rules, problems


def judged_rules(root: Path, placeholders: Dict[str, str], roots: List[str]) -> Tuple[List[dict], List[dict]]:
    """Every rule with its verdict: [{"name", "source", "rule", "ok", "why", "got"}], plus file-level problems."""
    rules, files = load_rules(root)
    verdicts: List[dict] = []
    release_names: Set[str] = set()
    seen: Set[str] = set()

    def key(x: Tuple[str, object]) -> Tuple[int, str]:
        n = x[1].get("name") if isinstance(x[1], dict) else None
        return (0 if x[0] == "release" else 1, n if isinstance(n, str) else "")
    for src, r in sorted(rules, key=key):
        name = r.get("name") if isinstance(r, dict) and isinstance(r.get("name"), str) else "(unnamed)"
        v_ = {"name": name, "source": src, "rule": r, "ok": False, "why": None, "got": None}
        problem = rule_problem(r)
        if problem:
            v_["why"] = problem
        elif src == "deployment" and name in release_names:
            v_["why"] = "a release rule has that name; rename it"
        elif name in seen:
            v_["why"] = "another rule in the same file has that name; rename it"
        else:
            ok, got = rule_test(r, placeholders, roots)
            v_["got"] = got
            if not ok:
                v_["why"] = "its own test fails"
            else:
                v_["ok"] = True
        if src == "release" and not problem:
            release_names.add(name)
        seen.add(name)
        verdicts.append(v_)
    return verdicts, files


def skip_line(v_: dict) -> str:
    if v_["why"] == "a release rule has that name; rename it":
        return "rule %s skipped: %s" % (v_["name"], v_["why"])
    return "rule %s skipped: %s (%s)" % (v_["name"], v_["why"], CHECK_HINT)


def rules_check(root: Path) -> int:
    cfg = read_config(root)
    verdicts, files = judged_rules(root, cfg.placeholders, cfg.module_roots or [""])
    fails = 0
    for f in files:
        print("FAIL %s: it cannot be read (%s), so its rules are skipped" % (f["file"], f["why"]))
        fails += 1
    for v_ in verdicts:
        if v_["ok"]:
            print("ok %s" % v_["name"])
            continue
        fails += 1
        if v_["why"] == "its own test fails":
            print("FAIL %s: expected %s, got %s" % (v_["name"], json.dumps(sorted(v_["rule"]["test"]["expect"])),
                                                   json.dumps(v_["got"])))
        else:
            print("FAIL %s: %s" % (v_["name"], v_["why"]))
    n_fail = sum(1 for v_ in verdicts if not v_["ok"])
    print("%d rules, %d fail" % (len(verdicts), n_fail))
    return 1 if fails else 0


def apply_rules(job: dict) -> dict:
    """The rules worker's body (§10.2 At query time): load, judge, and run every good rule over the tree."""
    root = Path(job["root"])
    tree = Tree(Path(job["tree"]), job["outer"], job["nested"])
    placeholders, roots, subjects = job["placeholders"], job["roots"], set(job["subjects"])
    verdicts, files = judged_rules(root, placeholders, roots)
    skipped = ["rules in %s skipped: the file cannot be read (%s); %s" % (f["file"], f["why"], CHECK_HINT)
               for f in files]
    skipped += [skip_line(v_) for v_ in verdicts if not v_["ok"]]
    good = [v_["rule"] for v_ in verdicts if v_["ok"]]
    hits: List[dict] = []
    if subjects and good:
        all_files = ls_files(tree)
        for r in good:
            rx = re.compile(r["search"])
            mapping = rule_map(r, placeholders)
            for rel in sorted(git_grep(tree, r["hint"])):
                if not in_globs(r, rel):
                    continue
                try:
                    text = (tree.root / rel).read_text(errors="replace")
                except OSError:
                    continue
                for n, line in enumerate(text.splitlines(), 1):
                    if len(line) > LONG_LINE:
                        continue
                    for m in rx.finditer(line):
                        named = resolve_candidates(r, expand(r, m, mapping), rel, roots, all_files)
                        if subjects.intersection(named):
                            hits.append({"file": rel, "rule": r["name"], "line": n, "text": m.group(0)[:80]})
    return {"hits": hits, "skipped": skipped, "applied": sorted(r["name"] for r in good)}


def rules_timeout() -> float:
    try:
        return float(os.environ.get("DAEDALUS_CONTEXT_TEST_RULES_TIMEOUT") or RULES_TIMEOUT)
    except ValueError:
        return RULES_TIMEOUT


def rules_part(root: Path, cfg: Cfg, tree: Tree, subj: Subject,
               roots: List[str]) -> Tuple[Dict[str, dict], List[str], object]:
    """(hits, skipped lines, the names applied or 'timed-out'). The rules run in a child process with a
    timeout: Python's re has no timeout of its own, so a catastrophic regex would otherwise hang the query."""
    job = {"root": str(root), "tree": str(tree.root), "outer": tree.outer, "nested": tree.nested_prefixes(),
           "placeholders": cfg.placeholders, "roots": roots, "subjects": subj.files}
    limit = rules_timeout()
    try:
        proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--rules-worker"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, env=dict(os.environ, DAEDALUS_HOME=str(root)))
    except OSError as e:
        return {}, ["rules could not run (%s), so this answer has no rule hits" % (e.strerror or e)], "failed"
    LIVE.append(proc)
    try:
        out, _ = proc.communicate(json.dumps(job), timeout=limit)
    except subprocess.TimeoutExpired:
        kill_tree(proc)
        proc.communicate()
        LIVE.remove(proc)
        return {}, ["rules timed out after %s s, so this answer has no rule hits; %s lists them"
                    % (("%g" % limit), CHECK_HINT)], "timed-out"
    LIVE.remove(proc)
    try:
        res = json.loads(out)
    except ValueError:
        return {}, ["rules could not run (the worker exited %s), so this answer has no rule hits"
                    % proc.returncode], "failed"
    hits: Dict[str, dict] = {}
    for h in res.get("hits") or []:
        e = hits.setdefault(h["file"], {"lines": set(), "why": [], "rules": [], "text": ""})
        e["lines"].add(h["line"])
        if h["rule"] not in e["rules"]:
            e["rules"].append(h["rule"])
            e["why"].append("rule:%s: %s" % (h["rule"], h["text"]))
        if not e["text"] or sorted(e["rules"])[0] == h["rule"]:
            e["text"] = e["text"] or h["text"]
    return hits, list(res.get("skipped") or []), list(res.get("applied") or [])


# --- merge and labels (§6) -----------------------------------------------------------------------------

def merge(graph: Dict[str, dict], grep: Dict[str, dict], rules: Dict[str, dict], subject: List[str]) -> List[dict]:
    files = (set(graph) | set(grep) | set(rules)) - set(subject)
    out: List[dict] = []
    for f in files:
        sources: List[str] = []
        lines: Set[int] = set()
        why: List[str] = []
        text = ""
        for src, part in (("graph", graph), ("grep", grep)):
            if f in part:
                sources.append(src)
                lines.update(part[f]["lines"])
                why += part[f]["why"]
        rnames = sorted(rules.get(f, {}).get("rules", []))
        if f in rules:
            lines.update(rules[f]["lines"])
            why += rules[f]["why"]
            text = rules[f].get("text", "")
        sources += ["rule:%s" % n for n in rnames]
        if "graph" in sources and "grep" in sources:
            label = "both"
        elif "graph" in sources:
            label = "graph only"
        elif "grep" in sources:
            label = "grep only"
        else:
            label = "rule:%s" % rnames[0]
        out.append({"file": f, "label": label, "sources": sources, "lines": sorted(lines), "why": why,
                    "text": text})
    rank = {"both": 0, "graph only": 1, "grep only": 2}
    out.sort(key=lambda h: (rank.get(h["label"], 3), h["file"]))
    return out


def counts_of(hits: List[dict]) -> Dict[str, int]:
    c = {"both": 0, "graph only": 0, "grep only": 0, "rule": 0}
    for h in hits:
        c[h["label"] if h["label"] in LABELS else "rule"] += 1
    return c


# --- output (§5) -----------------------------------------------------------------------------------------

def graph_phrase(g: GraphInfo) -> str:
    if g.state == "present":
        return "graph %s (%.1f s)" % (g.action or "updated", g.seconds or 0.0)
    if g.state == "absent":
        return "graph: %s, so these answers come from git grep and rules" % g.note
    if g.note and g.note.startswith(tuple(BUILD_FAILED.values())):
        return "graph: %s" % g.note
    return "graph: %s, so these answers come from git grep and rules" % (g.note or g.state)


def header(root: Path, where: Where, verb: str, arg: str, subj: Subject, g: GraphInfo) -> str:
    if where.window is None:
        return "%s %s — outside a window: grep and rules over %s; nothing recorded" % (
            verb, arg, tree_label(root, where.tree))
    return "%s %s — window %s, repo %s; %s" % (verb, arg, where.window, subj.repo, graph_phrase(g))


def closing(hits: List[dict]) -> str:
    c = counts_of(hits)
    per: Dict[str, int] = {}
    for h in hits:
        for s in h["sources"]:
            if s.startswith("rule:"):
                per[s[5:]] = per.get(s[5:], 0) + 1
    rule = "%d rule" % c["rule"]
    if per:
        rule += " (%s)" % ", ".join("%s %d" % (n, per[n]) for n in sorted(per))
    return "%d file%s: %d both, %d graph only, %d grep only, %s. %s" % (
        len(hits), "" if len(hits) == 1 else "s", c["both"], c["graph only"], c["grep only"], rule, CANDIDATES)


def file_line(h: dict) -> str:
    loc = "%s:%d" % (h["file"], h["lines"][0]) if h["lines"] else h["file"]
    if h["label"].startswith("rule:"):
        return "%s  %s  %s" % (h["label"], loc, h["text"][:80])
    extra = [s for s in h["sources"] if s.startswith("rule:")]
    return "%-13s %s%s" % (h["label"], loc, "".join("  +" + s for s in extra))


def plain(root: Path, where: Where, verb: str, arg: str, subj: Subject, g: GraphInfo, hits: List[dict],
          skipped: List[str], tail: List[str]) -> str:
    out = [header(root, where, verb, arg, subj, g)]
    out += [file_line(h) for h in hits[:PRINT_CAP]]
    if len(hits) > PRINT_CAP:
        out.append("+%d more — run it again with --json for all of them" % (len(hits) - PRINT_CAP))
    out += skipped
    out.append(closing(hits))
    out += tail
    return "\n".join(out)


def as_json(where: Where, verb: str, arg: str, subj: Subject, g: GraphInfo, hits: List[dict],
            skipped: List[str]) -> str:
    shown = hits[:JSON_CAP]
    return json.dumps({
        "verb": verb, "arg": arg,
        "subject": {"files": subj.files, "symbol": subj.symbol, "repo": subj.repo},
        "window": where.window, "tree": str(where.tree.root), "graph": g.as_json(),
        "hits": [{k: h[k] for k in ("file", "label", "sources", "lines", "why")} for h in shown],
        "rules_skipped": skipped, "counts": counts_of(hits), "truncated": len(hits) - len(shown)})


# --- the query log (§8) and pruning (§7) ---------------------------------------------------------------

def append_row(path: Path, row: dict) -> Optional[str]:
    """One JSON row, one write, under flock on the file. The reason it failed, or None."""
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(str(path), "a") as fh:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
            try:
                fh.write(json.dumps(row) + "\n")
                fh.flush()
            finally:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        return None
    except OSError as e:
        return e.strerror or str(e)


def read_rows(path: Path) -> List[dict]:
    rows: List[dict] = []
    try:
        with open(str(path)) as fh:
            for ln in fh:
                try:
                    r = json.loads(ln)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    return rows


def record(root: Path, where: Where, verb: str, arg: str, subj: Subject, g: GraphInfo, hits: List[dict],
           applied: object) -> Optional[str]:
    row = {"at": now_iso(), "lease": where.window, "lease_created": (where.lease or {}).get("created"),
           "session_id": where.sid, "verb": verb, "arg": arg, "repo": subj.repo, "subject_files": subj.files,
           "hits": [[h["file"], h["label"]] for h in hits], "graph": g.state, "rules": applied,
           "broad": verb == "grep" and len(hits) > BROAD}
    return append_row(cc_dir(root) / str(where.window) / "queries.jsonl", row)


def recorded_created(d: Path) -> Optional[str]:
    """The lease_created a window directory was written for: its rows, else any index's meta.json."""
    for r in read_rows(d / "queries.jsonl"):
        if r.get("lease_created"):
            return str(r["lease_created"])
    for m in sorted(d.glob("*/meta.json")):
        c = (read_json_file(m) or {}).get("lease_created")
        if c:
            return str(c)
    return None


def prune(root: Path) -> None:
    """Only a window prunes (§7): a directory whose lease file is gone (swept), or whose rows were written for an
    earlier holder of the number (reissued). A released window that is not swept keeps its directory, since its
    promote may still need the queries; a live window's rows carry its own lease_created, so it is never touched."""
    base = cc_dir(root)
    if not base.is_dir():
        return
    import leaselib as ll
    try:
        with ll.lock(root, shared=True):
            leases = ll.read_all(root)
    except ll.Refused:
        return
    for d in sorted(base.iterdir()):
        if not d.is_dir() or not re.fullmatch(r"[0-9]{2}", d.name):
            continue
        lease = leases.get(d.name)
        created = recorded_created(d)
        if lease is None or (created and lease.get("created") and created != str(lease.get("created"))):
            shutil.rmtree(str(d), ignore_errors=True)


# --- misses at promote (§9) ------------------------------------------------------------------------------

LOG_NAME = "state/code-context/misses.jsonl"
FAILURE_LINE = re.compile(r"FAILED|ERROR|not ok|in test file")
LOCATION_LINE = re.compile(r"^([\w./-]+):\d+: ")
PATH_TOKEN = re.compile(r"[\w./-]+")
CONFIG_EXTS = (".yaml", ".yml", ".toml", ".json", ".ini", ".cfg")
NOT_COUNTED = ("summary", "no-queries", "unasked")
CLASSIFY_MAX = 50
CLASSIFY_SECS = 20.0
TOO_MANY_FAILING = 10


def parse_local(stamp: object) -> Optional[float]:
    if not isinstance(stamp, str):
        return None
    try:
        return time.mktime(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


def window_rows(root: Path, nn: str, created: object) -> List[dict]:
    return [r for r in read_rows(cc_dir(root) / nn / "queries.jsonl")
            if r.get("lease") == nn and r.get("lease_created") == created]


def predicted_of(rows: List[dict]) -> Tuple[Set[str], Set[str], int]:
    """(predicted files, those only rules named, broad queries): every subject file and every hit, except the hits
    of a broad grep (§8)."""
    pred: Set[str] = set()
    labels: Dict[str, Set[str]] = {}
    broad = 0
    for r in rows:
        for f in r.get("subject_files") or []:
            if isinstance(f, str):
                pred.add(f)
                labels.setdefault(f, set()).add("subject")
        if r.get("broad"):
            broad += 1
            continue
        for h in r.get("hits") or []:
            if isinstance(h, list) and h and isinstance(h[0], str):
                pred.add(h[0])
                labels.setdefault(h[0], set()).add(str(h[1]) if len(h) > 1 else "")
    rule_only = {f for f, ls in labels.items() if ls and all(x.startswith("rule:") for x in ls)}
    return pred, rule_only, broad


def excluded(rel: str, patterns: List[str]) -> bool:
    """As git reads fingerprint.sh's :(exclude) pathspecs: the path, a directory above it, or a wildcard (whose *
    crosses /, as git's default pathspec does)."""
    return any(rel == x or rel.startswith(x + "/") or (any(c in x for c in "*?[") and fnmatch.fnmatchcase(rel, x))
               for x in patterns if x)


def changed_files(tree: Tree, repo_pre: str, base: str, head: str,
                  fx: List[str]) -> Tuple[Dict[str, str], Set[str]]:
    """({tree-relative path: status} the merge changed, the paths it added). Added files are dropped from the
    first (a file that did not exist could not have been predicted), as is target.fingerprint_exclude."""
    code, out = _git(tree.repo_dir(repo_pre), ["diff", "--name-status", "--no-renames", "-z", base, head])
    if code != 0:
        raise RuntimeError("git diff %s..%s failed" % (base[:7], head[:7]))
    parts = [x for x in out.split("\0")]
    changed: Dict[str, str] = {}
    added: Set[str] = set()
    i = 0
    while i + 1 < len(parts):
        st, path = parts[i], parts[i + 1]
        i += 2
        if not st:
            continue
        rel = "%s/%s" % (repo_pre, path) if repo_pre else path
        if st.startswith("A"):
            added.add(rel)
            continue
        if excluded(rel, fx):
            continue
        changed[rel] = st[0]
    return changed, added


def failed_tests(root: Path, nn: str, created: object, tracked: Set[str],
                 added: Set[str]) -> Tuple[Set[str], int]:
    """(test files named on a failure line of the window's FAIL gate runs, runs dropped as too broad)."""
    since = parse_local(created)
    out: Set[str] = set()
    too_broad = 0
    ev = root / "state" / "evidence"
    for rj in sorted(ev.glob("*/run.json")) if ev.is_dir() else []:
        rec = read_json_file(rj) or {}
        started = parse_local(rec.get("started"))
        if rec.get("lease") != nn or rec.get("result") != "FAIL" or rec.get("promote_id"):
            continue
        if since is not None and (started is None or started < since):
            continue
        named: Set[str] = set()
        for g in rec.get("gates") or []:
            if not isinstance(g, dict) or g.get("exit") in (0, 126, 127) or not g.get("log"):
                continue
            try:
                text = Path(str(g["log"])).read_text(errors="replace")
            except OSError:
                continue
            for ln in text.splitlines():
                if not (FAILURE_LINE.search(ln) or LOCATION_LINE.match(ln)):
                    continue
                for tok in PATH_TOKEN.findall(ln):
                    tok = tok.lstrip("./") if tok.startswith("./") else tok
                    if "." not in posixpath.basename(tok) or not is_test_path(tok):
                        continue
                    named.update(f for f in tracked if f == tok or f.endswith("/" + tok))
        named -= added                        # a new test that failed is the red step, not a missed link
        if len(named) > TOO_MANY_FAILING:
            too_broad += 1
            continue
        out |= named
    return out, too_broad


def names_for(rel: str, roots: List[str]) -> List[Tuple[str, Optional["re.Pattern"]]]:
    """What another file would say to name rel: its basename (a substring), and each dotted module name with at
    least one dot (word-bounded)."""
    out: List[Tuple[str, Optional[re.Pattern]]] = [(posixpath.basename(rel), None)]
    for d in module_names(rel, roots):
        if "." in d:
            out.append((d, re.compile(r"(?<![\w.])%s(?![\w])" % re.escape(d))))
    return out


def mentions(text: str, names: List[Tuple[str, Optional["re.Pattern"]]]) -> bool:
    for lit, rx in names:
        if lit in text and (rx is None or rx.search(text)):
            return True
    return False


def dotted_above(rel: str) -> List[str]:
    """M's module name relative to every directory above it, longest first (x/a/b/c.py: x.a.b.c, a.b.c, b.c, c)."""
    if not rel.endswith(".py"):
        return []
    parts = rel[:-3].split("/")
    if parts[-1] in ("__init__", "__main__"):
        parts = parts[:-1]
    out = []
    for i in range(len(parts)):
        sub = parts[i:]
        if sub and all(p.isidentifier() for p in sub):
            out.append(".".join(sub))
    return out


def _pick(hits: Dict[str, List[Tuple[int, str]]], m: str, predicted: Set[str],
          accept=None) -> Optional[str]:
    """The evidence file:line, preferring a line in M or in a predicted file."""
    cands: List[Tuple[int, str, int]] = []
    for f, rows in sorted(hits.items()):
        if accept is not None and not accept(f):
            continue
        for n, _ in rows:
            cands.append((0 if f == m or f in predicted else 1, f, n))
    if not cands:
        return None
    cands.sort()
    return "%s:%d" % (cands[0][1], cands[0][2])


def shell_file(tree: Tree, rel: str) -> bool:
    if rel.endswith((".sh", ".bash")):
        return True
    if "." in posixpath.basename(rel):
        return False
    try:
        with open(str(tree.root / rel), errors="replace") as fh:
            first = fh.readline()
    except OSError:
        return False
    return bool(re.match(r"#!.*\b(bash|sh)\b", first))


def kind_of(tree: Tree, m: str, predicted: Set[str], roots: List[str]) -> Tuple[str, str]:
    """(kind, evidence) of one linked miss: the §9 table, first match wins."""
    base = posixpath.basename(m)
    if m.endswith(".tmpl"):
        return "template path", m
    rx = re.compile(r"\{\{[A-Z][A-Z0-9_]*\}\}[^\s\"'`]*" + re.escape(base) + r"(?![\w.])")
    ev = _pick(git_grep(tree, base, regex=rx), m, predicted, accept=lambda f: f.endswith(".tmpl"))
    if ev:
        return "template path", ev
    for d in dotted_above(m):
        rx = re.compile(r"-m\s+%s(?![\w.])" % re.escape(d))
        ev = _pick(git_grep(tree, d, regex=rx), m, predicted)
        if ev:
            return "uv run -m", ev
    if m.endswith(CONFIG_EXTS):
        return "manifest/config key", m
    ev = _pick(git_grep(tree, base), m, predicted, accept=lambda f: f.endswith(CONFIG_EXTS))
    if ev:
        return "manifest/config key", ev
    parent = posixpath.basename(posixpath.dirname(m))
    if parent:
        rx = re.compile(r"[\"']%s[\"']\s*/\s*[\"']%s[\"']" % (re.escape(parent), re.escape(base)))
        ev = _pick(git_grep(tree, base, regex=rx), m, predicted, accept=lambda f: f.endswith(".py"))
        if ev:
            return "python path join", ev
    ev = _pick(git_grep(tree, base, regex=re.compile(r"python")), m, predicted, accept=lambda f: shell_file(tree, f))
    if ev:
        return "shell python invocation", ev
    return "other", ""


def earlier_windows(rows: List[dict], kind: str, nn: str, created: object) -> int:
    return len({(r.get("lease"), r.get("lease_created")) for r in rows
                if r.get("kind") == kind and kind not in NOT_COUNTED
                and (r.get("lease"), r.get("lease_created")) != (nn, created)})


def count_phrase(n_changed: int, n_failed: int) -> str:
    parts = []
    if n_changed:
        parts.append("%d changed file%s" % (n_changed, "" if n_changed == 1 else "s"))
    if n_failed:
        parts.append("%d failed test%s" % (n_failed, "" if n_failed == 1 else "s"))
    return " and ".join(parts)


def misses(root: Path, p: dict, pdir: Path) -> Tuple[str, dict]:
    """§9: (the record paragraph's line, {"count", "kinds"}), the rows appended to misses.jsonl. Needs neither
    the graph nor grep over the window: promote never depends on the optional tool."""
    if os.environ.get("DAEDALUS_CONTEXT_TEST_DIE") == "misses":
        raise RuntimeError("test knob")
    cfg = read_config(root)
    nn, created, repo, pid = str(p["lease"]), p.get("lease_created"), str(p["repo"]), p.get("promote_id")
    outer = cfg.name or repo.split("/")[0]
    pre = repo[len(outer) + 1:] if repo != outer and repo.startswith(outer + "/") else ""
    tree = Tree(pdir / outer, outer, cfg.nested)
    log = cc_dir(root) / "misses.jsonl"
    earlier = read_rows(log)
    rows = window_rows(root, nn, created)
    predicted, rule_only, broad = predicted_of(rows)
    changed, added = changed_files(tree, pre, str(p["trunk_sha_at_prepare"]), str(p["merge_sha"]),
                                   cfg.fingerprint_exclude)
    tracked = ls_files(tree, untracked=False)
    failed, too_broad = failed_tests(root, nn, created, tracked, added)
    base = {"lease": nn, "lease_created": created, "promote_id": pid}
    summary = dict(base, at=now_iso(), kind="summary", queries=len(rows), predicted=len(predicted),
                   predicted_rule_only=len(rule_only & predicted), broad_queries=broad, changed=len(changed),
                   failed_tests=len(failed), misses=0, runs_too_broad=too_broad)
    if not rows:
        append_row(log, dict(base, at=now_iso(), repo=repo, kind="no-queries", queries=0))
        append_row(log, summary)
        return ("Code context: window %s ran no code-context queries, so there is nothing to compare." % nn,
                {"count": None, "kinds": {}})
    found = [(f, "changed") for f in sorted(changed) if f not in predicted]
    found += [(f, "failed-test") for f in sorted(failed) if f not in predicted and f not in changed]
    roots = module_roots(tree, cfg, tracked)
    pred_names = {f: names_for(f, roots) for f in predicted}
    pred_text: Dict[str, str] = {}
    for f in predicted:
        try:
            pred_text[f] = (tree.root / f).read_text(errors="replace")
        except OSError:
            pred_text[f] = ""

    def text_of(m: str) -> str:
        try:
            return (tree.root / m).read_text(errors="replace")
        except OSError:
            r_name, r_pre = tree.repo_of(m)
            code, out = _git(tree.repo_dir(r_pre), ["show", "%s:%s" % (p["trunk_sha_at_prepare"],
                                                                         m[len(r_pre) + 1:] if r_pre else m)])
            return out if code == 0 else ""

    started = time.monotonic()
    limit = int(os.environ.get("DAEDALUS_CONTEXT_TEST_CLASSIFY_MAX") or CLASSIFY_MAX)
    classified = 0
    result: List[dict] = []
    for m, source in found:
        mt = text_of(m)
        linked = any(mentions(t, names_for(m, roots)) for t in pred_text.values()) or \
            any(mentions(mt, pred_names[f]) for f in predicted)
        if not linked:
            kind, ev = "unasked", ""
        elif classified >= limit or time.monotonic() - started > CLASSIFY_SECS:
            kind, ev = "other", "not classified (budget)"
        else:
            kind, ev = kind_of(tree, m, predicted, roots)
            classified += 1
        result.append({"file": m, "source": source, "kind": kind, "evidence": ev})
    for r in result:
        append_row(log, dict(base, at=now_iso(), repo=repo, file=r["file"], source=r["source"], kind=r["kind"],
                             evidence=r["evidence"], queries=len(rows)))
    summary["misses"] = len(result)
    append_row(log, summary)
    kinds: Dict[str, int] = {}
    for r in result:
        kinds[r["kind"]] = kinds.get(r["kind"], 0) + 1
    note = ""
    if predicted and len(rule_only & predicted) * 2 > len(predicted):
        note = " (%d of %d predicted files came from rules alone)" % (len(rule_only & predicted), len(predicted))
    if not result:
        line = "Code context: every changed file and failed test was named by window %s's %d quer%s%s." % (
            nn, len(rows), "y" if len(rows) == 1 else "ies", note)
        return line, {"count": 0, "kinds": {}}
    ordered = [r for r in result if r["kind"] != "unasked"] + [r for r in result if r["kind"] == "unasked"]
    n_changed = sum(1 for r in result if r["source"] == "changed")
    n_failed = len(result) - n_changed
    if all(r["kind"] == "unasked" for r in result):
        named = ", ".join(r["file"] for r in ordered[:3])
        head = "%s no query was near (unasked)" % count_phrase(n_changed, n_failed)
    else:
        items = []
        for r in ordered[:3]:
            k = r["kind"]
            e = earlier_windows(earlier, k, nn, created) if k not in NOT_COUNTED else 0
            items.append("%s (%s%s)" % (r["file"], k, ", also missed in %d earlier window%s" % (e, "" if e == 1 else "s")
                                        if e else ""))
        named = ", ".join(items)
        head = "%s no query named" % count_phrase(n_changed, n_failed)
    more = " and %d more" % (len(ordered) - 3) if len(ordered) > 3 else ""
    line = "Code context: %s — %s%s%s; the log is %s." % (head, named, more, note, LOG_NAME)
    return line, {"count": len(result), "kinds": kinds}


# --- doctor (§12) ---------------------------------------------------------------------------------------

def leftover_hook(root: Path) -> bool:
    try:
        d = json.loads((root / ".claude" / "settings.local.json").read_text())
    except (OSError, ValueError):
        return False
    return "code-context.py" in json.dumps((d or {}).get("hooks") if isinstance(d, dict) else None)


def doctor_lines(root: Path) -> List[str]:
    """OK and NOTE lines, never MISSING: the deployment works without any of this. Runs `<graph> -v` (cached)
    and the rules' own tests in memory; never builds, updates or queries an index, never greps the target."""
    cfg = read_config(root)
    lines: List[str] = []
    problem = exe_problem(cfg)
    ver = None
    if not problem:
        ver, problem = graph_version(root, str(cfg.graph))
    verdicts, files = judged_rules(root, cfg.placeholders, cfg.module_roots or [""])
    n_rel = sum(1 for x in verdicts if x["source"] == "release")
    n_dep = len(verdicts) - n_rel
    bad = [x for x in verdicts if not x["ok"]]
    if problem is None:
        lines.append("OK       code context: code-review-graph %s at %s; %d release rule%s, %d deployment rule%s; %s" % (
            ver, cfg.graph, n_rel, "" if n_rel == 1 else "s", n_dep, "" if n_dep == 1 else "s",
            "every rule test passes" if not bad and not files else "%d rule%s skipped" % (
                len(bad), "" if len(bad) == 1 else "s")))
    elif problem == NOT_INSTALLED:
        lines.append("NOTE     code context: no code graph configured (context.graph in config.yaml), so answers come "
                     "from git grep and the rules (optional; see \"Code context\" in README.md)")
    elif "not the pinned" in problem:
        lines.append("NOTE     code context: %s, so answers come from git grep and the rules; install %s (README "
                     "\"Code context\")" % (problem, PINNED))
    else:
        lines.append("NOTE     code context: %s, so answers come from git grep and the rules" % problem)
    for f in files:
        what = ("queries use the release rules only" if f["file"] == DEPLOY_RULES else
                "queries use the deployment rules only")
        lines.append("NOTE     code context: %s cannot be read (%s), so %s; fix it, then run %s"
                     % (f["file"], f["why"], what, CHECK_HINT))
    for x in bad:
        where = DEPLOY_RULES if x["source"] == "deployment" else RELEASE_RULES
        if x["why"] == "its own test fails":
            lines.append("NOTE     code context: rule %s in %s fails its own test, so queries skip it; fix it, then "
                         "run %s" % (x["name"], where, CHECK_HINT))
        else:
            lines.append("NOTE     code context: rule %s in %s is skipped (%s); fix it, then run %s"
                         % (x["name"], where, x["why"], CHECK_HINT))
    if any(x["ok"] and x["name"] == "template-placeholder" for x in verdicts) and not cfg.placeholders:
        lines.append("NOTE     code context: rule template-placeholder has no placeholders to map "
                     "(context.placeholders in config.yaml), so it adds nothing")
    if cfg.ruff_leftover:
        lines.append("NOTE     code context: recall.ruff in config.yaml is no longer read (0.9.0 removed the edit-time "
                     "code-context hook); the line can be removed")
    if leftover_hook(root):
        lines.append("NOTE     code context: .claude/settings.local.json still runs core/code-context.py, which 0.9.0 "
                     "removed; remove that hook entry")
    return lines


# --- the query verbs -------------------------------------------------------------------------------------

def query(root: Path, verb: str, arg: str, want_json: bool) -> int:
    started = time.monotonic()
    cfg = read_config(root)
    where = resolve_where(root, cfg)
    tree = where.tree
    if where.window is not None:
        try:
            prune(root)
        except Exception:
            pass
    subj = parse_subject(verb, arg, tree)
    deadline = started + cfg.budget
    roots = module_roots(tree, cfg)
    tests_only = verb == "tests"
    gi, ghits = graph_part(root, cfg, where, verb, subj, deadline)
    grep = grep_part(tree, verb_patterns(verb, subj, roots, arg), tests_only)
    rhits, skipped, applied = rules_part(root, cfg, tree, subj, roots)
    if tests_only:
        rhits = {f: h for f, h in rhits.items() if is_test_path(f)}
    hits = merge(ghits, grep, rhits, subj.files)
    tail: List[str] = []
    if where.window is not None:
        why = record(root, where, verb, arg, subj, gi, hits, applied)
        if why:
            tail.append("This query was not recorded (%s); promote will count its files as unpredicted." % why)
    if want_json:
        print(as_json(where, verb, arg, subj, gi, hits, skipped))
        for ln in tail:                 # stdout stays one JSON object
            sys.stderr.write(ln + "\n")
    else:
        print(plain(root, where, verb, arg, subj, gi, hits, skipped, tail))
    return 0


def main(argv: List[str]) -> int:
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, _stop_children)
    root = daedalus_root()
    args = argv[1:]
    want_json = "--json" in args
    args = [a for a in args if a != "--json"]
    try:
        if not args:
            raise Usage(USAGE)
        verb = args[0]
        if verb in VERBS:
            if len(args) != 2:
                raise Usage(USAGE)
            return query(root, verb, args[1], want_json)
        if verb == "rebuild":
            return rebuild(root, args[1:])
        if args == ["rules", "--check"]:
            return rules_check(root)
        if args == ["--doctor"]:
            for ln in doctor_lines(root):
                print(ln)
            return 0
        if args == ["--rules-worker"]:
            print(json.dumps(apply_rules(json.load(sys.stdin))))
            return 0
        raise Usage(USAGE)
    except Usage as e:
        print(str(e))
        return 2
    except Exception as e:      # exit codes are 0 and 2 only (§5); never a traceback for the agent to parse
        print("core/context.py could not answer (%s: %s)." % (type(e).__name__, " ".join(str(e).split())[:200]))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
