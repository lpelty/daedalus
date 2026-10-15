#!/usr/bin/env python3
"""Document recall runner: the product's single execution path to the
deployment's Chroma engine (spec §2.3).

    vault-search.py query "<text>"   -> JSON array (<=8 results) or nothing
    vault-search.py index            -> runs the reindex engine, stamps on proof
    vault-search.py --check          -> doctor NOTE lines (never empty)
    vault-search.py --stale          -> one word: unconfigured | no-store | stale | fresh

The engine commands live in config.yaml (recall.vault-query /
recall.vault-index), run as `bash -c "<cmd>" _ <args...>` with
DAEDALUS_RECALL_STORE exported. Silence is the contract for query mode:
every failure exits 0 and prints nothing. Python 3.9, stdlib only.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import verifylib as v  # noqa: E402

QUERY_TIMEOUT = 10
# DAEDALUS_TEST_INDEX_TIMEOUT is a test knob and can only shrink the timeout.
INDEX_TIMEOUT = min(120, int(os.environ.get("DAEDALUS_TEST_INDEX_TIMEOUT") or 120))
CFG_TIMEOUT = 3
MAX_RESULTS = 8
STAMP_REL = "state/recall-last-index"
LOCK_REL = "state/recall-index.lock"
PRIME_ONLY = "The document index is rebuilt by the prime; ask it to reindex"
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
    references "$1" itself; nothing is ever spliced or appended (spec §2.2).

    The engine runs in its own session (process group), and a timeout kills
    the whole group: subprocess.run's timeout killed `bash -c` and not the
    indexer it started, so a lock released over a still-writing indexer was
    the "database is locked" case the lock exists for (reindex design
    2026-10-15, decision 22; the shape of leaselib._run_bounded, kept local
    because this script does not import leaselib). None on a timeout or an
    OS failure; otherwise the completed process with its stdout and stderr."""
    try:
        p = subprocess.Popen(
            ["bash", "-c", cmd, "_"] + args,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=dict(os.environ, DAEDALUS_RECALL_STORE=str(store)),
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(p)
        return None
    except BaseException:
        _kill_group(p)
        raise
    return subprocess.CompletedProcess(p.args, p.returncode, out, err)


def _kill_group(p: "subprocess.Popen") -> None:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        p.communicate(timeout=5)
    except (subprocess.SubprocessError, OSError, ValueError):
        pass


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


def _session() -> Optional[str]:
    return os.environ.get("DAEDALUS_SESSION_ID") or os.environ.get("CLAUDE_CODE_SESSION_ID") or None


def is_clone(root: Path) -> bool:
    """A session that holds a lease but not the pen (§4.10). An operator shell
    (no session) is never a clone."""
    sid = _session()
    if not sid:
        return False
    ctx = v.lease_context(root, sid)
    return bool(ctx["leases"]) and not ctx["prime"]


def cmd_index(root: Path) -> int:
    # §4.10: the index is a vault-derived artifact and follows the hot.md rule —
    # prime-only, and one writer at a time (two sqlite writers is "database is locked").
    if is_clone(root):
        print(PRIME_ONLY)
        return 0
    lock_path = root / LOCK_REL
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_path), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("index already running")
            return 0
        ok, line, _ = _index_locked(root)
        if ok:
            sys.stdout.write(line + "\n")
        else:
            sys.stderr.write("vault-search: %s\n" % line)
        return 0
    finally:
        os.close(fd)                                  # releases the flock


def _index_locked(root: Path) -> Tuple[bool, str, str]:
    """Caller holds the lock. Runs the engine once; returns (ok, line, engine_stderr):
    on success the engine's count line, on failure the one sentence that says
    why (the stamp is untouched in every failure). The engine's stderr comes
    back so a log can carry it (decision 4); the foreground form discards it."""
    cmd = read_cfg("recall.vault-index", root)
    if not cmd or looks_corrupted(cmd):
        return False, "recall.vault-index unset or corrupted", ""
    store = store_path(root)
    if store is None:
        return False, "recall.store rejected", ""
    start = time.time()
    r = run_engine(cmd, [], store, INDEX_TIMEOUT)
    if r is None:
        return False, "engine failed; stamp untouched", ""
    if r.returncode != 0:
        return False, "engine failed; stamp untouched", r.stderr or ""
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    m = COUNT_RE.match(lines[-1].strip()) if lines else None
    if not m:
        return False, "no 'indexed=N purged=M' line; stamp untouched", r.stderr or ""
    if not store.is_dir():
        return False, "store dir absent after engine run; stamp untouched", r.stderr or ""
    write_stamp(root, start)
    return True, lines[-1].strip(), r.stderr or ""


def write_stamp(root: Path, start: float) -> None:
    """The stamp's mtime is the engine's START time (reindex design 2026-10-15,
    decision 21): a document changed while the engine ran is newer than the
    stamp and so stale after the run, instead of being marked fresh and left
    unindexed until some later kick. The text is the same instant."""
    stamp = root / STAMP_REL
    stamp.parent.mkdir(parents=True, exist_ok=True)   # state/, not the store
    stamp.write_text(time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(start)))
    os.utime(str(stamp), (start, start))


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


def stale_word(root: Path) -> str:
    """The cheap staleness answer (reindex design 2026-10-15, decision 6): a
    stat of the stamp against the newest vault document, never an engine run,
    so session-start can ask inside its budget. `no-store` is told apart from
    `stale` for the tests; both mean "rebuild"."""
    cmd = read_cfg("recall.vault-index", root)
    if not cmd or looks_corrupted(cmd):
        return "unconfigured"
    store = store_path(root)
    if store is None:
        return "unconfigured"
    if not store.is_dir():
        return "no-store"
    stamp = root / STAMP_REL
    if not stamp.is_file():
        return "stale"
    if _newest_vault_md(root) > stamp.stat().st_mtime:
        return "stale"
    return "fresh"


def cmd_stale(root: Path) -> int:
    print(stale_word(root))
    return 0


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
            if is_clone(root):
                print("document recall: index older than the vault — ask the prime to reindex")
            else:
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
    if len(argv) >= 2 and argv[1] == "--stale":
        try:
            return cmd_stale(root)
        except Exception:
            print("stale")                             # a caller rebuilds on doubt
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
