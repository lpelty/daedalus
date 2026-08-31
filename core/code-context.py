#!/usr/bin/env python3
"""Code context: which files import the module being edited (spec §3).

Hook mode (PreToolUse, Edit|Write): when the edited path is target *.py,
attach the dependents list to the tool result. CLI mode: print it. Engine:
config-pinned ruff (`recall.ruff`), else a pruned stdlib ast walk; the
ruff map is post-filtered through the SAME prune rules (ruff 0.16.5 does
not skip hidden dirs or pyvenv.cfg-venvs by default — verified). Every
failure is silence, except an unreadable state/ which degrades dedup to
repetition (spec B-4). The hook runs under a hard 4s deadline. Python
3.9, stdlib only.
"""
from __future__ import annotations

import ast
import json
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

DEADLINE_SECS = 4.0
RESERVE_SECS = 1.0
RUFF_CAP_SECS = 2.0
CFG_CAP_SECS = 1.0
FILE_CAP = 2000
LIST_CAP = 20
MAX_CHARS = 4000
PRUNE_DAYS = 7
PRUNE_DIRS = {"__pycache__", "node_modules", "site-packages"}

_deadline = 0.0


def _remaining() -> float:
    return _deadline - time.monotonic()


def _sub_timeout(cap: float) -> float:
    return max(0.5, min(cap, _remaining() - RESERVE_SECS))


def daedalus_root() -> Path:
    env = os.environ.get("DAEDALUS_HOME")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parent.parent


def _bash(root: Path, snippet: str, timeout: float) -> Optional[str]:
    lib = root / "core" / "lib.sh"
    if not lib.is_file():
        return None
    try:
        r = subprocess.run(
            ["bash", "-c", 'source "$1"; ' + snippet, "_", str(lib)],
            capture_output=True, text=True, timeout=timeout,
            env=dict(os.environ, DAEDALUS_HOME=str(root)),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return r.stdout.strip()


def target_root(root: Path) -> Optional[Path]:
    out = _bash(root, "target_path", _sub_timeout(CFG_CAP_SECS))
    return Path(out).resolve() if out else None


def ruff_cmd(root: Path) -> Optional[str]:
    return _bash(root, "cfg recall.ruff", _sub_timeout(CFG_CAP_SECS))


def module_name(rel: str) -> str:
    """Root-relative path -> dotted module name (spec §3.2); pkg/__init__.py
    -> pkg; a path that yields no dotted identity stays a path."""
    p = Path(rel)
    if p.suffix != ".py":
        return rel
    parts = list(p.parts)
    parts[-1] = p.stem
    if parts[-1] == "__init__":
        parts = parts[:-1]
    if not parts:
        return rel
    if any(not part.isidentifier() for part in parts):
        return rel
    return ".".join(parts)


def _pruned_rel(rel: str, root: Path) -> bool:
    """True when a root-relative path falls under the prune rules — the ONE
    exclusion policy applied to the ast walk AND the ruff map."""
    parts = Path(rel).parts
    acc = root
    for part in parts[:-1]:
        if part.startswith(".") or part in PRUNE_DIRS:
            return True
        acc = acc / part
        if (acc / "pyvenv.cfg").exists():
            return True
    last = parts[-1] if parts else ""
    return last.startswith(".") and last != "."


def _prune(dirpath: str, dirnames: List[str]) -> None:
    keep = []
    for d in dirnames:
        if d.startswith(".") or d in PRUNE_DIRS:
            continue
        if os.path.exists(os.path.join(dirpath, d, "pyvenv.cfg")):
            continue
        keep.append(d)
    dirnames[:] = keep


def _walk_py(root: Path) -> Optional[List[Path]]:
    files: List[Path] = []
    sleep = os.environ.get("DAEDALUS_CODE_CONTEXT_TEST_SLEEP")
    for dirpath, dirnames, filenames in os.walk(str(root)):
        _prune(dirpath, dirnames)
        if sleep:
            time.sleep(float(sleep))
        for f in filenames:
            if f.endswith(".py"):
                files.append(Path(dirpath) / f)
                if len(files) > FILE_CAP:
                    return None
    return files


def _imports_of(path: Path, rel: Path) -> List[str]:
    """Module names this file imports, package-relative ones resolved."""
    try:
        tree = ast.parse(path.read_text(encoding="utf-8", errors="replace"))
    except (SyntaxError, ValueError, OSError):
        return []
    pkg_parts = list(rel.parts[:-1])   # the file's package path
    out: List[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                out.append(a.name)
        elif isinstance(node, ast.ImportFrom):
            if node.level == 0:
                base = node.module or ""
            else:
                anchor = pkg_parts[: len(pkg_parts) - (node.level - 1)]
                base = ".".join(anchor + ([node.module] if node.module else []))
            if base:
                out.append(base)
                for a in node.names:
                    out.append(base + "." + a.name)
    return out


def build_graph_ast(root: Path) -> Optional[Dict[str, List[str]]]:
    """rel-posix -> sorted list of rel-posix dependents. None when over cap
    or the walk failed."""
    files = _walk_py(root)
    if files is None:
        return None
    mod_to_rel: Dict[str, str] = {}
    rels: Dict[Path, Path] = {}
    for f in files:
        try:
            rel = f.relative_to(root)
        except ValueError:
            continue
        rels[f] = rel
        name = module_name(rel.as_posix())
        if name != rel.as_posix():
            mod_to_rel[name] = rel.as_posix()
    dependents: Dict[str, List[str]] = {}
    for f, rel in rels.items():
        for imp in _imports_of(f, rel):
            hit = mod_to_rel.get(imp)
            if hit and hit != rel.as_posix():
                dependents.setdefault(hit, [])
                if rel.as_posix() not in dependents[hit]:
                    dependents[hit].append(rel.as_posix())
    return {k: sorted(v) for k, v in dependents.items()}


def _ruff_graph(cmd: str, root: Path) -> Optional[Dict[str, List[str]]]:
    try:
        argv = shlex.split(cmd) + ["analyze", "graph", "--direction", "dependents"]
    except ValueError:
        return None
    try:
        r = subprocess.run(argv, capture_output=True, text=True,
                           cwd=str(root), timeout=_sub_timeout(RUFF_CAP_SECS))
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    # ONE exclusion policy: post-filter ruff's map (keys AND values) through
    # the same prune rules the ast walk uses (spec §3.2, amended).
    out: Dict[str, List[str]] = {}
    for k, v in data.items():
        if not isinstance(v, list) or _pruned_rel(k, root):
            continue
        out[k] = [d for d in v
                  if isinstance(d, str) and not _pruned_rel(d, root)]
    return out


def dependents_for(rel: str, root: Path, ruff: Optional[str]) -> Optional[List[str]]:
    graph: Optional[Dict[str, List[str]]] = None
    if ruff:
        graph = _ruff_graph(ruff, root)
    if graph is None:
        graph = build_graph_ast(root)
    if graph is None:
        return None
    return sorted(graph.get(rel, []))


# --- Seen-state (pattern of pitfall-inject) ---------------------------------

def _seen_path(root: Path) -> Path:
    return root / "state" / "code-context-seen.json"


def _sanitize(s: object) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", str(s or "")) or "none"


def load_seen(root: Path) -> dict:
    try:
        data = json.loads(_seen_path(root).read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_seen(root: Path, data: dict) -> None:
    cutoff = time.time() - PRUNE_DAYS * 86400
    for key in list(data):
        entries = data[key]
        if not isinstance(entries, dict):
            del data[key]
            continue
        for f in list(entries):
            try:
                t = time.mktime(time.strptime(entries[f].get("touched", ""),
                                              "%Y-%m-%dT%H:%M:%S"))
            except (ValueError, AttributeError, OverflowError):
                t = 0
            if t < cutoff:
                del entries[f]
        if not entries:
            del data[key]
    try:
        d = _seen_path(root).parent
        d.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(d), prefix=".ccseen-", suffix=".json")
        with os.fdopen(fd, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp, str(_seen_path(root)))
    except OSError:
        pass          # unwritable state: dedup degrades to repetition (B-4)


# --- Rendering and hook ------------------------------------------------------

def render(rel: str, deps: List[str]) -> str:
    shown = deps[:LIST_CAP]
    more = " (+%d more)" % (len(deps) - LIST_CAP) if len(deps) > LIST_CAP else ""
    text = ("## Code context: %d files import %s\n%s%s "
            "(full list: python3 core/code-context.py <path>)"
            % (len(deps), module_name(rel), ", ".join(shown), more))
    return text[:MAX_CHARS]


class _Stall(Exception):
    pass


def _on_alarm(signum, frame):
    raise _Stall()


def run_hook(payload: dict, root: Path) -> Optional[dict]:
    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if tool not in ("Edit", "Write") or not isinstance(tool_input, dict):
        return None
    fp = str(tool_input.get("file_path") or "")
    if not fp.endswith(".py") or not os.path.isabs(fp):
        return None
    troot = target_root(root)
    if troot is None:
        return None
    try:
        rel = Path(fp).resolve().relative_to(troot).as_posix()
    except ValueError:
        return None
    key = "%s:%s" % (_sanitize(payload.get("session_id")),
                     _sanitize(payload.get("agent_id") or "main"))
    seen = load_seen(root)
    mine = seen.setdefault(key, {})
    if not isinstance(mine, dict):
        mine = seen[key] = {}
    if rel in mine:
        return None
    deps = dependents_for(rel, troot, ruff_cmd(root))
    if not deps:
        return None
    if os.environ.get("DAEDALUS_CODE_CONTEXT_TEST_DIE") == "render":
        raise RuntimeError("test knob: die before emit")
    text = render(rel, deps)
    # The context now exists and nothing below can stall on computation:
    # disarm the alarm BEFORE marking seen, so a deadline landing mid-save
    # cannot consume the file's one shot with nothing emitted (spec §3.2
    # ordering; cycle-3 finding — save_seen used to run inside the armed
    # window). Residual, pitfall-inject's recorded trade-off applies here
    # too: a harness kill between this save and main()'s stdout write loses
    # one banner for the session; the common case (compaction) is covered
    # by PreCompact.
    signal.alarm(0)
    mine[rel] = {"touched": time.strftime("%Y-%m-%dT%H:%M:%S")}
    save_seen(root, seen)
    return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                   "additionalContext": text}}


def _count_py(root: Path) -> int:
    """Full post-prune count, uncapped — used only by --check (not
    hook-bound), so the over-cap NOTE can report the real number."""
    n = 0
    for dirpath, dirnames, filenames in os.walk(str(root)):
        _prune(dirpath, dirnames)
        n += sum(1 for f in filenames if f.endswith(".py"))
    return n


def check(root: Path) -> List[str]:
    lines: List[str] = []
    troot = target_root(root)
    ruff = ruff_cmd(root)
    engine = "ruff" if ruff else "ast fallback"
    if troot is None:
        # distinct diagnosis — an unresolved target root is not "over cap"
        lines.append("code context: target root unresolved — hook inert")
        if not ruff:
            lines.append("code context: ast fallback (no recall.ruff configured)")
        return lines
    files = _walk_py(troot)
    if files is None:
        total = _count_py(troot)
        lines.append("code context: engine %s, %d files after pruning"
                     % (engine, total))
        lines.append("code context: %d files after pruning — over the %d cap, "
                     "fallback silent" % (total, FILE_CAP))
    else:
        lines.append("code context: engine %s, %d files after pruning"
                     % (engine, len(files)))
    if ruff:
        try:
            argv = shlex.split(ruff) + ["--version"]
            r = subprocess.run(argv, capture_output=True, text=True, timeout=10)
            ok = r.returncode == 0
        except (OSError, subprocess.SubprocessError, ValueError):
            ok = False
        if not ok:
            lines.append("code context: configured ruff not runnable — "
                         "ast fallback in force")
        else:
            # end-to-end probe under the hook's own budget (spec §3.3)
            global _deadline
            _deadline = time.monotonic() + DEADLINE_SECS
            t0 = time.monotonic()
            g = _ruff_graph(ruff, troot)
            secs = time.monotonic() - t0
            if g is None:
                lines.append("code context: ruff configured but the hook path "
                             "fell back to ast (%.1fs)" % secs)
    else:
        lines.append("code context: ast fallback (no recall.ruff configured)")
    return lines


def main(argv: List[str]) -> int:
    global _deadline
    root = daedalus_root()
    if len(argv) >= 2 and argv[1] == "--check":
        # --check is not hook-bound: a generous deadline so the cfg/root
        # subprocess timeouts get their full 1s caps (not the 0.5s floor an
        # unset deadline would compute); the end-to-end probe narrows it.
        _deadline = time.monotonic() + 30.0
        try:
            for line in check(root):
                print(line)
        except Exception:
            print("code context: check crashed")
        return 0
    if len(argv) >= 2 and not argv[1].startswith("-"):
        # CLI: no deadline, no state.
        _deadline = time.monotonic() + 3600
        fp = os.path.abspath(argv[1])
        troot = target_root(root)
        for base in (troot, root):
            if base is None:
                continue
            try:
                rel = Path(fp).resolve().relative_to(base).as_posix()
            except ValueError:
                continue
            deps = dependents_for(rel, base, ruff_cmd(root))
            for d in deps or []:
                print(d)
            return 0
        return 0
    # Hook mode.
    _deadline = time.monotonic() + DEADLINE_SECS
    try:
        payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            return 0
    except (ValueError, OSError):
        return 0
    if payload.get("hook_event_name") == "PreCompact":
        try:
            seen = load_seen(root)
            sid = _sanitize(payload.get("session_id"))
            for key in [k for k in seen if k.startswith(sid + ":")]:
                del seen[key]
            save_seen(root, seen)
        except Exception:
            pass
        return 0
    signal.signal(signal.SIGALRM, _on_alarm)
    signal.alarm(int(DEADLINE_SECS))
    try:
        out = run_hook(payload, root)
    except Exception:      # _Stall included: silence, seen unmarked
        return 0
    finally:
        signal.alarm(0)
    if out is not None:
        sys.stdout.write(json.dumps(out))
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
