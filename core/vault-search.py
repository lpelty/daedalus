#!/usr/bin/env python3
"""Document recall runner: the product's single execution path to the
deployment's Chroma engine (spec §2.3).

    vault-search.py query "<text>"   -> JSON array (<=8 results) or nothing
    vault-search.py index            -> runs the reindex engine, stamps on proof
    vault-search.py --check          -> doctor NOTE lines (never empty)

The engine commands live in config.yaml (recall.vault-query /
recall.vault-index), run as `bash -c "<cmd>" _ <args...>` with
DAEDALUS_RECALL_STORE exported. Silence is the contract for query mode:
every failure exits 0 and prints nothing. Python 3.9, stdlib only.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

QUERY_TIMEOUT = 10
INDEX_TIMEOUT = 120
CFG_TIMEOUT = 3
MAX_RESULTS = 8
STAMP_REL = "state/recall-last-index"
COUNT_RE = re.compile(r"^indexed=(\d+) purged=(\d+)$")


def daedalus_root() -> Path:
    env = os.environ.get("DAEDALUS_HOME")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parent.parent


def read_cfg(key: str, root: Path) -> Optional[str]:
    """One config value via lib.sh's cfg — the product's only config parser.
    Positional form (spec §2.3): a $ROOT form fails with 127."""
    lib = root / "core" / "lib.sh"
    if not lib.is_file():
        return None
    try:
        r = subprocess.run(
            ["bash", "-c", 'source "$1"; cfg "$2"', "_", str(lib), key],
            capture_output=True, text=True, timeout=CFG_TIMEOUT,
            env=dict(os.environ, DAEDALUS_HOME=str(root)),
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    val = r.stdout.strip()
    return val or None


def looks_corrupted(value: str) -> bool:
    """Odd double-quote parity = a verified cfg mangle (spec §2.3): trailing
    whitespace or an inline comment after a quoted value."""
    return value.count('"') % 2 == 1


def store_path(root: Path) -> Optional[Path]:
    """recall.store resolved under the home, guarded (spec §2.2): reject
    absolute, any '..' component, bare '.', and post-resolution escape."""
    raw = read_cfg("recall.store", root) or "state/chroma"
    if os.path.isabs(raw) or raw == ".":
        return None
    parts = Path(raw).parts
    if ".." in parts or not parts:
        return None
    resolved = (root / raw).resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    return resolved


def run_engine(cmd: str, args: List[str], store: Path,
               timeout: int) -> Optional[subprocess.CompletedProcess]:
    """bash -c "<cmd>" _ <args...> with the store exported. The command string
    references "$1" itself; nothing is ever spliced or appended (spec §2.2)."""
    try:
        return subprocess.run(
            ["bash", "-c", cmd, "_"] + args,
            capture_output=True, text=True, timeout=timeout,
            env=dict(os.environ, DAEDALUS_RECALL_STORE=str(store)),
        )
    except (OSError, subprocess.SubprocessError):
        return None


def _valid_rel(path: str) -> bool:
    if not path or os.path.isabs(path) or path.startswith("./"):
        return False
    if ".." in Path(path).parts:
        return False
    return True


def filter_results(rows: object) -> Optional[List[dict]]:
    """Validate the engine's JSON contract; normalize-and-filter paths; drop
    evidence/; cap AFTER filtering (spec §2.3)."""
    if not isinstance(rows, list):
        return None
    out: List[dict] = []
    for r in rows:
        if not isinstance(r, dict):
            return None
        path = r.get("path")
        snippet = r.get("snippet")
        if not isinstance(path, str) or not isinstance(snippet, str):
            return None
        if not _valid_rel(path):
            continue
        if Path(path).parts[0] == "evidence":
            continue
        out.append(r)
        if len(out) == MAX_RESULTS:
            break
    return out


def cmd_query(text: str, root: Path) -> int:
    cmd = read_cfg("recall.vault-query", root)
    if not cmd or looks_corrupted(cmd):
        return 0
    store = store_path(root)
    if store is None:
        return 0
    r = run_engine(cmd, [text], store, QUERY_TIMEOUT)
    if r is None or r.returncode != 0:
        return 0
    try:
        rows = json.loads(r.stdout)
    except ValueError:
        return 0
    out = filter_results(rows)
    if out is None or not out:
        return 0
    sys.stdout.write(json.dumps(out))
    return 0


def cmd_index(root: Path) -> int:
    cmd = read_cfg("recall.vault-index", root)
    if not cmd or looks_corrupted(cmd):
        sys.stderr.write("vault-search: recall.vault-index unset or corrupted\n")
        return 0
    store = store_path(root)
    if store is None:
        sys.stderr.write("vault-search: recall.store rejected\n")
        return 0
    r = run_engine(cmd, [], store, INDEX_TIMEOUT)
    if r is None or r.returncode != 0:
        sys.stderr.write("vault-search: engine failed; stamp untouched\n")
        return 0
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    m = COUNT_RE.match(lines[-1].strip()) if lines else None
    if not m:
        sys.stderr.write("vault-search: no 'indexed=N purged=M' line; stamp untouched\n")
        return 0
    if not store.is_dir():
        sys.stderr.write("vault-search: store dir absent after engine run; stamp untouched\n")
        return 0
    stamp = root / STAMP_REL
    stamp.parent.mkdir(parents=True, exist_ok=True)   # state/, not the store
    stamp.write_text(time.strftime("%Y-%m-%dT%H:%M:%S"))
    sys.stdout.write(lines[-1].strip() + "\n")
    return 0


def _newest_vault_md(root: Path) -> float:
    """Newest *.md mtime under vault/, excluding evidence/ and dot-dirs
    (spec §2.6 — gates.sh writes evidence on every run)."""
    newest = 0.0
    vault = root / "vault"
    if not vault.is_dir():
        return newest
    for dirpath, dirnames, filenames in os.walk(str(vault)):
        dirnames[:] = [d for d in dirnames
                       if not d.startswith(".") and d != "evidence"]
        for f in filenames:
            if f.endswith(".md"):
                try:
                    newest = max(newest, os.path.getmtime(os.path.join(dirpath, f)))
                except OSError:
                    pass
    return newest


def cmd_check(root: Path) -> int:
    lines: List[str] = []
    cmd = read_cfg("recall.vault-query", root)
    if not cmd:
        print("document recall: unconfigured")
        return 0
    if looks_corrupted(cmd):
        lines.append("document recall: recall.vault-query looks corrupted "
                     "(odd quote count — trailing whitespace or an inline "
                     "comment after a quoted value?)")
    store = store_path(root)
    if store is None:
        lines.append("document recall: recall.store rejected "
                     "(absolute, '..', '.', or resolves outside the home)")
    probe_ok = False
    if store is not None and not lines:
        r = run_engine(cmd, ["daedalus doctor probe"], store, QUERY_TIMEOUT)
        if r is not None and r.returncode == 0:
            try:
                probe_ok = filter_results(json.loads(r.stdout)) is not None
            except ValueError:
                probe_ok = False
        if not probe_ok:
            lines.append("document recall: query command failing")
    summary = "document recall: configured, probe ok" if probe_ok and not lines \
        else "document recall: configured, problems below"
    print(summary)
    for ln in lines:
        print(ln)
    if store is not None:
        stamp = root / STAMP_REL
        if not store.is_dir():
            print("document recall: no index at %s" % store)
            if stamp.is_file():
                print("document recall: stamp without a store — store deleted "
                      "since the last index, or the engine is ignoring "
                      "DAEDALUS_RECALL_STORE")
        elif not stamp.is_file():
            print("document recall: no index stamp — run indexing through "
                  "vault-search.py index")
        elif _newest_vault_md(root) > stamp.stat().st_mtime:
            print("document recall: index run older than newest vault change")
    if not read_cfg("recall.vault-index", root):
        print("document recall: reindex command unconfigured")
    return 0


def main(argv: List[str]) -> int:
    root = daedalus_root()
    if len(argv) >= 2 and argv[1] == "--check":
        try:
            return cmd_check(root)
        except Exception:
            print("document recall: check crashed")   # red, never silently green
            return 0
    try:
        if len(argv) >= 3 and argv[1] == "query":
            return cmd_query(argv[2], root)
        if len(argv) >= 2 and argv[1] == "index":
            return cmd_index(root)
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
