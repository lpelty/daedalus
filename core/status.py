#!/usr/bin/env python3
"""Whether this deployment's services are running, read in under 2 s (service-status spec §3).

    python3 core/status.py [--json] [--home <Daedalus home>]

One fast reader for the service-status mod's band and pane, and for a person at a shell. It reads
config.yaml (the way lib.sh cfg reads it), a few files under state/, one HTTP GET to the memory server's
/health (1 s), and the AMI switch through amilib (one 100 ms TCP connect). It never runs git, a model or
any program, never writes a file, and never reaches the network beyond this machine: a memory server
configured on another host is not checked.

--json prints one object in the shape another harness's status band already reads, so such a band reads it
unchanged:

    {"services": [{"stem", "name", "state", "detail"}], "checked_at": "<ISO 8601, UTC>"}

`state` is up, down or not-set-up. A service the deployment never configured is not-set-up, never down, so a
deployment shows only what it set up. Exit 0 whenever the object was printed (whatever the states); exit 2
with one sentence on stderr when there is no config.yaml in the home.

Python 3.9, standard library only.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional

sys.dont_write_bytecode = True      # importing amilib must leave no __pycache__ in the home (identity guard)
sys.path.insert(0, str(Path(__file__).resolve().parent))
import amilib  # noqa: E402

HEALTH_TIMEOUT_SECS = 1.0           # §3: the memory server answers 2xx within 1 s, or it is down
DEFAULT_API_URL = "http://127.0.0.1:8888"     # lib.sh memory_env's default, and capture.py's
DEFAULT_CAPTURE_INTERVAL = 120      # capture.py DEFAULT_CAPTURE_INTERVAL
CAPTURE_WINDOW = 3                  # §3: up while the last capture is within 3 x capture_interval of now
WRITE_SLACK_SECS = 60               # a transcript line written just after the Stop tick that captured it
RECENT_SECS = 24 * 3600             # transcripts older than a day are history, not session activity
TAIL_CAP = 2 * 1024 * 1024          # the most of a transcript's uncaptured end read for its newest message
LOCAL_HOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}

# stem, plain name, what it is — in the order the pane lists them
SERVICES = (
    ("hindsight", "memory server", "the Hindsight server episodic capture writes to"),
    ("capture", "memory capture", "the Stop and SessionEnd capture of this home's transcripts"),
    ("vault-index", "vault search", "the store vault search reads"),
    ("ami", "decider", "the AMI daemon behind /frame-jack"),
    ("code-graph", "code graph", "the code-review-graph executable core/context.py asks"),
)


# ---------------------------------------------------------------- config.yaml, as lib.sh cfg reads it
class Config:
    """config.yaml read once. `block(top)` is lib.sh's `grep -q '^top:'`; `get("top.sub")` is lib.sh cfg's awk:
    the block opens at a line `top:`, closes at the next line that starts with neither space nor #, and the
    value is the first line in it whose first field is `sub:`, edge quotes and spaces stripped; empty, ~ or null
    is unset. A value still reading <...> (the example's placeholder) is unset too, as upgrade.py's _cfg has it."""

    def __init__(self, text: str):
        self.lines = text.splitlines()

    def block(self, top: str) -> bool:
        return any(ln.startswith(top + ":") for ln in self.lines)

    def get(self, dotted: str) -> Optional[str]:
        top, _, sub = dotted.partition(".")
        inblock = False
        for ln in self.lines:
            if re.match(re.escape(top) + ":", ln):
                inblock = True
                continue
            if re.match(r"[^\s#]", ln):
                inblock = False
            fields = ln.split()
            if inblock and fields and fields[0] == sub + ":":
                val = re.sub(r"^\s*[^:]+:\s*", "", ln, count=1)
                val = re.sub(r"^[\"']|[\"']$", "", val).strip()
                if val in ("", "~") or val.lower() == "null" or val.startswith("<"):
                    return None
                return val
        return None


def row(stem: str, state: str, detail: str) -> Dict[str, str]:
    name = next(n for s, n, _ in SERVICES if s == stem)
    return {"stem": stem, "name": name, "state": state, "detail": detail}


def ago(secs: float) -> str:
    secs = max(0, int(secs))
    if secs < 60:
        return "%d s ago" % secs
    if secs < 3600:
        return "%d min ago" % (secs // 60)
    if secs < 86400:
        return "%d h ago" % (secs // 3600)
    return "%d days ago" % (secs // 86400)


# ---------------------------------------------------------------- the checks
def check_hindsight(cfg: Config) -> Dict[str, str]:
    if not cfg.block("memory"):
        return row("hindsight", "not-set-up", "no memory: block in config.yaml")
    # capture honours HINDSIGHT_API_URL over the block (lib.sh memory_env): the server it writes to is the one checked
    api = (os.environ.get("HINDSIGHT_API_URL") or cfg.get("memory.api_url") or DEFAULT_API_URL).rstrip("/")
    parts = urllib.parse.urlsplit(api)
    host = parts.hostname or ""
    where = parts.netloc or api
    if parts.scheme not in ("http", "https") or host not in LOCAL_HOSTS:
        return row("hindsight", "not-set-up", "%s is not on this machine, so it is not checked" % where)
    url = api + "/health"
    try:
        # no proxy: a localhost GET must never leave the machine through an HTTP(S)_PROXY in the environment
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(urllib.request.Request(url, method="GET"), timeout=HEALTH_TIMEOUT_SECS) as r:
            code = r.status
    except urllib.error.HTTPError as e:
        code = e.code
    except Exception:
        return row("hindsight", "down", "%s did not answer within 1 s" % where)
    if 200 <= code < 300:
        return row("hindsight", "up", "%s answered" % where)
    return row("hindsight", "down", "%s answered HTTP %d" % (where, code))


def _transcript_dir(home: Path, cfg: Config) -> Path:
    # lib.sh memory_env: TRANSCRIPT_DIR, memory.transcript_dir, else Claude Code's project directory for this home
    tdir = os.environ.get("TRANSCRIPT_DIR") or cfg.get("memory.transcript_dir")
    if tdir:
        return Path(os.path.expanduser(tdir))
    conf = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return Path(conf) / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(home.resolve()))


def _interval(cfg: Config) -> int:
    raw = os.environ.get("CAPTURE_INTERVAL") or cfg.get("memory.capture_interval") or ""
    return int(raw) if raw.isdigit() and 0 < int(raw) < 10 ** 6 else DEFAULT_CAPTURE_INTERVAL


def _newest_message(path: str, offset: int, size: int) -> Optional[float]:
    """The time of the newest user or assistant row past `offset` (what capture has not taken), read from at most
    the file's last TAIL_CAP bytes; None when there is none. The engine's own rows after a turn (the Stop hook's
    summary, the turn's duration, an away summary written minutes later) are not session activity."""
    start = max(offset, size - TAIL_CAP)
    if start >= size:
        return None
    try:
        with open(path, "rb") as f:
            f.seek(start)
            tail = f.read(size - start)
    except OSError:
        return None
    newest = None
    for ln in tail.splitlines():
        if b'"user"' not in ln and b'"assistant"' not in ln:
            continue                                # most rows: no JSON parse
        try:
            r = json.loads(ln)
            if r.get("type") not in ("user", "assistant"):
                continue
            t = datetime.fromisoformat(str(r["timestamp"]).replace("Z", "+00:00")).timestamp()
        except (ValueError, KeyError, TypeError, AttributeError):
            continue                                # a line cut by the read's start, or a row with no time
        newest = t if newest is None else max(newest, t)
    return newest


def check_capture(home: Path, cfg: Config, now: float) -> Dict[str, str]:
    """Up while the last capture is within 3 x capture_interval of now, or there was no session activity since
    (§3). "Activity since" is read per transcript from state/hindsight/offsets.json (the byte offset capture has
    taken, and its `last_capture` time) and the transcript's rows past that offset: a user or assistant row
    written more than one capture_interval after that transcript's last capture (so the Stop that ended its turn
    was not throttled and should have captured it), and quiet for 3 intervals since (so the turn has ended), is
    activity capture missed. A turn still running, and a short turn the Stop tick throttled (SessionEnd takes
    it), are not misses."""
    if not cfg.block("memory"):
        return row("capture", "not-set-up", "no memory: block in config.yaml")
    interval = _interval(cfg)
    window = CAPTURE_WINDOW * interval
    try:
        rec = json.loads((home / "state" / "hindsight" / "offsets.json").read_text())
        rec = rec if isinstance(rec, dict) else {}
    except (OSError, ValueError):
        rec = {}
    captured: Dict[str, float] = {}
    for path, entry in (rec.get("transcripts") or {}).items():
        t = entry.get("last_capture") if isinstance(entry, dict) else None
        if isinstance(t, (int, float)):
            captured[os.path.realpath(path)] = float(t)
    offsets: Dict[str, int] = {}
    for path, off in (rec.get("offsets") or {}).items():
        if isinstance(off, int):
            offsets[os.path.realpath(path)] = off
    last = max(captured.values()) if captured else None
    if last is not None and now - last <= window:
        return row("capture", "up", "last capture %s" % ago(now - last))
    missed = None
    try:
        entries = list(os.scandir(_transcript_dir(home, cfg)))
    except OSError:
        entries = []
    for ent in entries:
        if not ent.name.endswith(".jsonl"):
            continue
        try:
            st = ent.stat()
        except OSError:
            continue
        if now - st.st_mtime > RECENT_SECS:
            continue                                # history, not session activity
        real = os.path.realpath(ent.path)
        newest = _newest_message(ent.path, offsets.get(real, 0), st.st_size)
        if newest is None or now - newest <= window:
            continue                                # nothing uncaptured, or a turn that may still be running
        since = captured.get(real, getattr(st, "st_birthtime", st.st_ctime))
        if newest - since > interval + WRITE_SLACK_SECS:
            missed = newest if missed is None else max(missed, newest)
    if missed is None:
        if last is None:
            return row("capture", "up", "no capture yet, and no session to capture")
        return row("capture", "up", "last capture %s; no session activity since" % ago(now - last))
    if last is None:
        return row("capture", "down", "no capture yet; a session was active %s" % ago(now - missed))
    return row("capture", "down", "last capture %s; a session was active %s" % (ago(now - last), ago(now - missed)))


def check_vault_index(home: Path, cfg: Config) -> Dict[str, str]:
    if not cfg.block("recall"):
        return row("vault-index", "not-set-up", "no recall: block in config.yaml")
    store = cfg.get("recall.store")
    if not store:
        return row("vault-index", "down", "recall.store is not set in config.yaml")
    p = home / store
    if p.is_dir() and os.access(str(p), os.R_OK | os.X_OK):
        return row("vault-index", "up", "store %s" % store)
    if p.exists():
        return row("vault-index", "down", "store %s cannot be read" % store)
    return row("vault-index", "down", "store %s is missing" % store)


def check_ami(home: Path, cfg: Config) -> Dict[str, str]:
    if not cfg.block("ami"):
        return row("ami", "not-set-up", "no ami: block in config.yaml")
    d = amilib.switch_detail(home, None)
    state = d.get("state")
    port = d.get("port") or cfg.get("ami.port")
    on_port = "port %s" % port if port else "no port recorded"
    if state == "on":
        return row("ami", "up", on_port)
    if state == "absent":
        return row("ami", "not-set-up", "frame-jack was never switched on here")
    if state == "off":
        return row("ami", "not-set-up", "frame-jack is off")
    if state == "battery":
        return row("ami", "not-set-up", "paused on battery")
    if state == "starting":
        return row("ami", "up", "starting, %s" % on_port)
    if state == "unconfigured":
        return row("ami", "down", "on but not configured — /frame-jack status")
    if d.get("reason") == "supervisor gone":
        return row("ami", "down", "its supervisor is gone — /frame-jack off, then on")
    return row("ami", "down", "%s does not answer — /frame-jack on" % on_port)


def check_code_graph(cfg: Config) -> Dict[str, str]:
    if not cfg.block("context"):
        return row("code-graph", "not-set-up", "no context: block in config.yaml")
    graph = cfg.get("context.graph")
    if not graph:
        return row("code-graph", "not-set-up", "context.graph is not set in config.yaml")
    if os.path.isfile(graph) and os.access(graph, os.X_OK):
        return row("code-graph", "up", "%s found" % os.path.basename(graph))
    if os.path.exists(graph):
        return row("code-graph", "down", "context.graph is not executable")
    return row("code-graph", "down", "context.graph is missing")


def status(home: Path, now: Optional[float] = None) -> dict:
    cfg = Config((home / "config.yaml").read_text())
    now = time.time() if now is None else now
    services: List[Dict[str, str]] = []
    for check in (lambda: check_hindsight(cfg), lambda: check_capture(home, cfg, now),
                  lambda: check_vault_index(home, cfg), lambda: check_ami(home, cfg),
                  lambda: check_code_graph(cfg)):
        services.append(check())
    stamp = datetime.fromtimestamp(now, timezone.utc).isoformat(timespec="seconds")
    return {"services": services, "checked_at": stamp}


def _human(data: dict) -> str:
    out = []
    for s in data["services"]:
        out.append("%-15s %-11s %s" % (s["name"], s["state"], s["detail"]))
    out.append("checked at %s" % data["checked_at"])
    return "\n".join(out)


def main(argv: List[str]) -> int:
    as_json = "--json" in argv
    home = Path(__file__).resolve().parent.parent
    if "--home" in argv:
        i = argv.index("--home")
        if i + 1 >= len(argv):
            print("daedalus: --home needs a directory", file=sys.stderr)
            return 2
        home = Path(argv[i + 1]).expanduser().resolve()
    unknown = [a for a in argv if a.startswith("-") and a not in ("--json", "--home")]
    if unknown:
        print("daedalus: status.py takes --json and --home <dir>, not %s" % unknown[0], file=sys.stderr)
        return 2
    if not (home / "config.yaml").is_file():
        print("daedalus: no config.yaml in %s, so no service can be checked" % home, file=sys.stderr)
        return 2
    data = status(home)
    print(json.dumps(data) if as_json else _human(data))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
