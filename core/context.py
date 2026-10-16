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
    if base not in ("__init__.py", "__main__.py"):
        pats.append(Pattern(base, base))
    for d in module_names(rel, roots):
        pats.append(Pattern(d, d))
    if stem.isidentifier():
        s = re.escape(stem)
        pats.append(Pattern(stem, "import %s" % stem, regex=r"\bimport\s+%s\b" % s))
        pats.append(Pattern(stem, "from … import %s" % stem,
                            regex=r"\bfrom\s+[A-Za-z0-9_.]+\s+import\s.*\b%s\b" % s))
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


def graph_part(root: Path, cfg: Cfg, where: Where, verb: str, subj: Subject,
               deadline: float) -> Tuple[GraphInfo, Dict[str, dict]]:
    if where.window is None:
        return GraphInfo("skipped", "outside a window"), {}
    if verb == "grep":
        return GraphInfo("skipped", "grep asks git grep only"), {}
    return GraphInfo("absent", NOT_INSTALLED), {}


# --- the rules (§10) -----------------------------------------------------------------------------------

def rules_part(root: Path, cfg: Cfg, tree: Tree, subj: Subject) -> Tuple[Dict[str, dict], List[str], object]:
    """(hits, skipped lines, the names applied or 'timed-out')."""
    return {}, [], []


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
    if g.note and g.note.startswith("the first index build failed"):
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


# --- the query verbs -------------------------------------------------------------------------------------

def query(root: Path, verb: str, arg: str, want_json: bool) -> int:
    started = time.monotonic()
    cfg = read_config(root)
    where = resolve_where(root, cfg)
    tree = where.tree
    subj = parse_subject(verb, arg, tree)
    deadline = started + cfg.budget
    roots = module_roots(tree, cfg)
    tests_only = verb == "tests"
    gi, ghits = graph_part(root, cfg, where, verb, subj, deadline)
    grep = grep_part(tree, verb_patterns(verb, subj, roots, arg), tests_only)
    rhits, skipped, _applied = rules_part(root, cfg, tree, subj)
    if tests_only:
        rhits = {f: h for f, h in rhits.items() if is_test_path(f)}
    hits = merge(ghits, grep, rhits, subj.files)
    tail: List[str] = []
    if want_json:
        print(as_json(where, verb, arg, subj, gi, hits, skipped))
    else:
        print(plain(root, where, verb, arg, subj, gi, hits, skipped, tail))
    return 0


def main(argv: List[str]) -> int:
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
        raise Usage(USAGE)
    except Usage as e:
        print(str(e))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
