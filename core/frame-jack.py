#!/usr/bin/env python3
"""frame-jack — the switch for the AMI (Artificial Machine Intelligence: Strands Decider 2B behind
`strands-decider serve`; frame-jack spec §8.2).

    python3 core/frame-jack.py on | off | status | --doctor      (no verb = status)

`on` reads the `ami:` block once (one `_lib` call), refuses with the lines to paste when there is none,
then — holding state/ami/.lock from the probe to the supervisor's first daemon.json write — probes the
port (§4.4: borrow the AMI if another deployment's daemon holds it, refuse anything else), writes the
sentinel and starts core/ami-daemon.py detached with a clean environment. `off` removes the sentinel,
records who flipped it, signals by the liveness-and-identity rule (§4.5) and prints what is true only
after the port went dead. `status` prints the long form with the calibration meter (§8.2); `--doctor` prints
doctor.sh's frame-jack lines, OK / NOTE / MISSING (§10).

Python 3.9, standard library. Exit codes: 0; 2 a refusal with its sentence; 1 an unexpected error.
"""
import http.client
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verifylib as v          # noqa: E402
import leaselib as ll          # noqa: E402
import amilib                  # noqa: E402

DEFAULT_PORT = 8761
DEFAULT_TIMEOUT_MS = 1500
DEVICES = ("mlx", "mps", "cpu")
KEYS = ("command", "model", "device", "port", "offline", "weights_cache", "battery_off",
        "request_timeout_ms", "ask_destructive", "ask_suite", "enforce", "shadow")
ASK_KEYS = (("destructive", "ask_destructive"), ("suite", "ask_suite"))     # question, its ami.* switch
HEALTH_TIMEOUT_SECS = 1.0          # the probe's GET /health
FIRST_WRITE_SECS = 2.0             # `on` waits this long for the supervisor's first daemon.json (§4.3)
OFF_PORT_WAIT_SECS = 12.0          # `off` waits this long for the port to go dead before it says freed (§8.2)
OFF_RECORD_WAIT_SECS = 5.0         # then for the supervisor's final record
STOP_GRACE_SECS = 10.0             # SIGTERM, this long, SIGKILL
PASTE = (
    "ami:",
    "  command: /abs/path/to/ami-venv/bin/strands-decider",
    "  model: StrandsAgents/strands-decider-2B-qwen3.5-v1-2610",
    "  device: mlx",
    "  port: 8761",
    "  offline: false",
    "  battery_off: true",
    "  request_timeout_ms: 1500",
    "  ask_destructive: false",
    "  ask_suite: true",
)
DROP_PREFIXES = ("CLAUDE", "DAEDALUS_")
DROP_VARS = ("DIRECT_CALL_ID",)


# ---------------------------------------------------------------- §3 the one config read
def _bool(raw, key, problems, default):
    if raw is None:
        return default
    val = str(raw).strip().lower()
    if val in ("true", "yes", "on", "1"):
        return True
    if val in ("false", "no", "off", "0"):
        return False
    problems.append("ami.%s must be true or false (got %s)" % (key, raw))
    return default


def _list(raw, key, problems):
    if raw is None:
        return None
    out = []
    for part in str(raw).split(","):
        name = part.strip()
        if not name:
            continue
        if name not in amilib.QUESTIONS:
            problems.append("ami.%s names %s, which is not a question (%s)" % (
                key, name, ", ".join(amilib.QUESTIONS)))
            continue
        out.append(name)
    return out


def read_config(root):
    """The `ami:` block as a dict, from one `_lib` call that prints every `ami.*` key as key<TAB>value; None
    when the block is absent (no key found). `problems` holds every plain-language reason `on` must refuse."""
    root = Path(root)
    os.environ["DAEDALUS_HOME"] = str(root)
    snippet = ("for k in %s; do val=\"$(cfg ami.$k 2>/dev/null)\" && printf '%%s\\t%%s\\n' \"$k\" \"$val\" || true; done; true"
               % " ".join(KEYS))
    raw = {}
    for line in v._lib(root, snippet).splitlines():
        if "\t" in line:
            k, val = line.split("\t", 1)
            raw[k.strip()] = val.strip()
    if not raw:
        return None
    problems = []
    cfg = {"command": raw.get("command"), "model": raw.get("model"), "device": raw.get("device"),
           "weights_cache": raw.get("weights_cache") or None}
    if not cfg["command"]:
        problems.append("ami.command is not set — the strands-decider executable inside its virtual environment")
    elif not (os.path.isabs(cfg["command"]) and amilib._executable(cfg["command"])):
        problems.append("ami.command %s is not an executable file — install strands-decider into a virtual "
                        "environment and name its strands-decider here" % cfg["command"])
    if not cfg["model"]:
        problems.append("ami.model is not set")
    if cfg["device"] not in DEVICES:
        problems.append("ami.device must be mlx, mps or cpu (got %s)" % (cfg["device"] or "nothing"))
    try:
        cfg["port"] = int(raw.get("port") or DEFAULT_PORT)
        if not 1024 <= cfg["port"] <= 65535:
            raise ValueError
    except ValueError:
        problems.append("ami.port must be a number from 1024 to 65535 (got %s)" % raw.get("port"))
        cfg["port"] = DEFAULT_PORT
    cfg["offline"] = _bool(raw.get("offline"), "offline", problems, False)
    cfg["battery_off"] = _bool(raw.get("battery_off"), "battery_off", problems, True)
    try:
        cfg["request_timeout_ms"] = int(raw.get("request_timeout_ms") or DEFAULT_TIMEOUT_MS)
        if cfg["request_timeout_ms"] <= 0:
            raise ValueError
    except ValueError:
        problems.append("ami.request_timeout_ms must be a whole number of milliseconds (got %s)"
                        % raw.get("request_timeout_ms"))
        cfg["request_timeout_ms"] = DEFAULT_TIMEOUT_MS
    cfg["questions"] = {q: _bool(raw.get(k), k, problems, amilib.ASKED_DEFAULT[q]) for q, k in ASK_KEYS}
    cfg["shadow_leftover"] = raw.get("shadow") is not None      # the key this release replaced; doctor says so
    cfg["enforce"] = _list(raw.get("enforce"), "enforce", problems) or []
    cfg["problems"] = problems
    return cfg


# ---------------------------------------------------------------- §4.4 the port
def health(port, timeout=HEALTH_TIMEOUT_SECS):
    """GET /health as a dict; None when the port is dead, answers something else, or not JSON."""
    conn = None
    try:
        conn = http.client.HTTPConnection("127.0.0.1", int(port), timeout=timeout)
        conn.request("GET", "/health")
        resp = conn.getresponse()
        raw = resp.read()
        if resp.status != 200:
            return None
        d = json.loads(raw.decode("utf-8"))
        return d if isinstance(d, dict) else None
    except Exception:
        return None
    finally:
        if conn is not None:
            try:
                conn.close()
            except Exception:
                pass


def is_ami(port, model, h=None):
    """§4.4: /health is JSON whose `checkpoint` equals ami.model verbatim, or whose `model` equals its basename
    (server.py answers the basename as `model`)."""
    h = health(port) if h is None else h
    if not h:
        return False
    if h.get("checkpoint") == model:
        return True
    return bool(model) and h.get("model") == os.path.basename(str(model).rstrip("/"))


# ---------------------------------------------------------------- §4.5 liveness and identity
def proc_command(pid):
    try:
        r = subprocess.run(["ps", "-o", "command=", "-p", str(int(pid))], capture_output=True, text=True, timeout=5)
        return r.stdout.strip()
    except (OSError, ValueError, TypeError, subprocess.SubprocessError):
        return ""


def identified(pid, kind, command=None):
    """True when the pid is alive AND its command line names what the record says (plan Decision 5):
    `ami-daemon.py` without `--leash` for the supervisor, with it for the leash, `<basename(command)> serve`
    for serve. Alive-but-something-else is a recycled pid: False."""
    if not ll.pid_alive(pid):
        return False
    line = proc_command(pid)
    if kind == "supervisor":
        return "ami-daemon.py" in line and "--leash" not in line
    if kind == "leash":
        return "ami-daemon.py" in line and "--leash" in line
    if kind == "serve":
        return bool(command) and ("%s serve" % os.path.basename(str(command))) in line
    return False


def pid_status(pid, kind, command=None):
    """`live` | `dead` | `recycled`."""
    if pid is None or not ll.pid_alive(pid):
        return "dead"
    return "live" if identified(pid, kind, command) else "recycled"


def _stop(pid, grace=STOP_GRACE_SECS):
    """SIGTERM, wait up to `grace`, SIGKILL. The caller has applied the identity rule."""
    try:
        os.kill(int(pid), signal.SIGTERM)
    except OSError:
        return
    end = time.monotonic() + grace
    while time.monotonic() < end:
        if not ll.pid_alive(pid):
            return
        time.sleep(0.1)
    try:
        os.kill(int(pid), signal.SIGKILL)
    except OSError:
        pass


# ---------------------------------------------------------------- helpers
def session_word():
    return ll.session_id_from_env() or "shell"


def off_by_word():
    sid = ll.session_id_from_env()
    return "operator via session %s" % sid if sid else "shell"


def clean_env():
    """Every CLAUDE*, DAEDALUS_* and DIRECT_CALL_ID variable dropped (§4.3): the daemon must not look like a
    session's child to anything that reads the registry."""
    return {k: val for k, val in os.environ.items()
            if not k.startswith(DROP_PREFIXES) and k not in DROP_VARS}


def daemon_line(d):
    d = d or {}
    return "daemon %s on port %s (supervisor pid %s, serve pid %s, device %s)" % (
        d.get("state"), d.get("port"), d.get("supervisor_pid"),
        d.get("serve_pid") if d.get("serve_pid") is not None else ("borrowed" if d.get("borrowed") else "none"),
        d.get("device"))


def _wait_port_closed(port, secs):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        if not amilib._port_open(port):
            return True
        time.sleep(0.1)
    return not amilib._port_open(port)


def _write_sentinel(root):
    p = amilib.sentinel_path(root)
    if not p.exists():
        p.write_text("%s session %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), session_word()))


def launch_supervisor(root, borrowed):
    """§4.3: detached, its own session, stdin from /dev/null, both outputs to daemon.log, a clean environment,
    the home as --home."""
    log = open(str(amilib.ami_dir(root) / "daemon.log"), "ab")
    try:
        args = [sys.executable, str(Path(root) / "core" / "ami-daemon.py"), "--home", str(root)]
        if borrowed:
            args.append("--borrowed")
        return subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                close_fds=True, start_new_session=True, env=clean_env())
    finally:
        log.close()


def _wait_first_write(root, child, secs=FIRST_WRITE_SECS):
    """The supervisor's first daemon.json names its pid, or the child exited, or the bound passed."""
    end = time.monotonic() + secs
    while time.monotonic() < end:
        d = amilib._read_json(amilib.daemon_path(root))
        if d and d.get("supervisor_pid") == child.pid:
            return d
        if child.poll() is not None:
            return None
        time.sleep(0.05)
    return amilib._read_json(amilib.daemon_path(root))


def _log_tail(root, n=5):
    try:
        lines = (amilib.ami_dir(root) / "daemon.log").read_text(errors="replace").splitlines()
        return [ln for ln in lines if ln.strip()][-n:]
    except OSError:
        return []


# ---------------------------------------------------------------- §8.2 on
def cmd_on(root):
    cfg = read_config(root)
    if cfg is None:
        print("frame-jack on: no ami: block in config.yaml — paste these into config.yaml, fill them in, "
              "then say frame-jack on again")
        for ln in PASTE:
            print("PASTE    " + ln)
        return 2
    if cfg["problems"]:
        print("frame-jack on: %s" % cfg["problems"][0])
        for p in cfg["problems"][1:]:
            print("            and: %s" % p)
        return 2
    base = amilib.ami_dir(root)
    base.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(str(base), 0o755)
    except OSError:
        pass
    port = cfg["port"]
    with amilib._Locked(amilib.lock_path(root)):
        d = amilib._read_json(amilib.daemon_path(root)) or {}
        if identified(d.get("supervisor_pid"), "supervisor"):
            _write_sentinel(root)
            print("frame-jack on: already on — %s" % daemon_line(d))
            return 0
        borrowed = False
        if amilib._port_open(port):
            if is_ami(port, cfg["model"]):
                borrowed = True
            else:
                print("frame-jack on: port %d is held by something that is not the AMI — change ami.port in "
                      "config.yaml (and name the same port in every deployment on this machine)" % port)
                return 2
        _write_sentinel(root)
        child = launch_supervisor(root, borrowed)
        rec = _wait_first_write(root, child)
    if child.poll() is not None and (not rec or rec.get("supervisor_pid") != child.pid):
        print("frame-jack on: the supervisor exited at once (code %s) — see state/ami/daemon.log:" % child.returncode)
        for ln in _log_tail(root):
            print("    " + ln)
        return 1
    if rec and rec.get("supervisor_pid") == child.pid and rec.get("state") == "battery":
        print("frame-jack on, waiting for AC power (the AMI does not run on battery)")
        return 0
    if borrowed:
        print("frame-jack on: using the AMI already running on port %d (started by another deployment); this "
              "deployment's supervisor watches power only" % port)
        return 0
    print("frame-jack on: starting the AMI (model %s, device %s, port %d); it answers in about 30 s — the band "
          "shows `AMI on` when it does" % (cfg["model"], cfg["device"], port))
    if not rec or rec.get("supervisor_pid") != child.pid:
        print("            (the supervisor, pid %d, has not written its record yet; state/ami/daemon.log says "
              "what it is doing)" % child.pid)
    return 0


# ---------------------------------------------------------------- §8.2 off
def cmd_off(root):
    base = amilib.ami_dir(root)
    if not base.is_dir():
        print("frame-jack off: already off (frame-jack was never switched on in this deployment)")
        return 0
    with amilib._Locked(amilib.lock_path(root)):
        d = amilib._read_json(amilib.daemon_path(root)) or {}
        had_sentinel = amilib.sentinel_path(root).exists()
        if had_sentinel:
            try:
                amilib.sentinel_path(root).unlink()
            except OSError:
                pass
        off_by = off_by_word()
        if d:
            d["off_by"] = off_by
            amilib._write_json(amilib.daemon_path(root), d)
    port = d.get("port")
    command = d.get("command")
    borrowed = bool(d.get("borrowed"))
    sup = pid_status(d.get("supervisor_pid"), "supervisor")
    leash = pid_status(d.get("leash_pid"), "leash")
    serve = pid_status(d.get("serve_pid"), "serve", command)
    notes = []
    for kind, status, pid in (("supervisor", sup, d.get("supervisor_pid")), ("leash", leash, d.get("leash_pid")),
                              ("the AMI (%s serve)" % os.path.basename(str(command or "serve")), serve, d.get("serve_pid"))):
        if status == "recycled":
            notes.append("pid %s was recorded as the %s but is another process now (recycled) — nothing was "
                         "sent to it" % (pid, kind))
    if not had_sentinel and sup != "live" and leash != "live" and serve != "live":
        if d and d.get("state") != "off":
            d.update({"state": "off", "off_by": d.get("off_by") or off_by, "heartbeat": time.time()})
            with amilib._Locked(amilib.lock_path(root)):
                amilib._write_json(amilib.daemon_path(root), d)
        for n in notes:
            print("frame-jack off: " + n)
        print("frame-jack off: already off")
        return 0
    if sup == "live":
        os.kill(int(d["supervisor_pid"]), signal.SIGHUP)        # the supervisor stops the leash, which stops serve
    elif not borrowed:
        if leash == "live":
            _stop(d["leash_pid"])
        elif serve == "live":
            _stop(d["serve_pid"])
    for n in notes:
        print("frame-jack off: " + n)
    if borrowed:
        _wait_supervisor_record(root, d, off_by)
        print("frame-jack off: the sentinel is removed; the daemon on port %s was not started by this deployment "
              "and keeps running" % port)
        return 0
    if port is not None and not _wait_port_closed(port, OFF_PORT_WAIT_SECS):
        _wait_supervisor_record(root, d, off_by)
        if serve == "live" and ll.pid_alive(d.get("serve_pid")):
            print("frame-jack off: the sentinel is removed but port %s still answers — pid %s (%s serve) did not "
                  "stop; run /frame-jack off again or kill it by hand"
                  % (port, d.get("serve_pid"), os.path.basename(str(command or "strands-decider"))))
        else:
            print("frame-jack off: the sentinel is removed but port %s still answers and nothing on record is that "
                  "process — find it (lsof -i :%s) and stop it by hand" % (port, port))
        return 1
    _wait_supervisor_record(root, d, off_by)
    if port is None:
        print("frame-jack off: the sentinel is removed (no daemon was on record)")
        return 0
    print("frame-jack off: the AMI is stopped and its 5 GB freed (port %s is closed)" % port)
    return 0


def _wait_supervisor_record(root, d, off_by):
    """A live supervisor writes `state: off` on its way out (§4.3 step 1); wait for it, and when it is gone
    without having done so, write the record ourselves."""
    sup = d.get("supervisor_pid")
    end = time.monotonic() + OFF_RECORD_WAIT_SECS
    while time.monotonic() < end:
        cur = amilib._read_json(amilib.daemon_path(root)) or {}
        if cur.get("state") == "off":
            return
        if not ll.pid_alive(sup):
            break
        time.sleep(0.1)
    if identified(sup, "supervisor"):
        return                                        # still writing; its record will follow
    cur = amilib._read_json(amilib.daemon_path(root)) or d
    if cur and cur.get("state") != "off":
        cur.update({"state": "off", "off_by": cur.get("off_by") or off_by, "heartbeat": time.time(),
                    "serve_pid": None if not identified(cur.get("serve_pid"), "serve", cur.get("command")) else cur.get("serve_pid"),
                    "leash_pid": None if not identified(cur.get("leash_pid"), "leash") else cur.get("leash_pid")})
        with amilib._Locked(amilib.lock_path(root)):
            amilib._write_json(amilib.daemon_path(root), cur)


# ---------------------------------------------------------------- §8.2 status
MEASURED_DEVICE = "mps"            # the device CALIBRATION's thresholds were measured on
SHOWN_WOULD_ASK = 5                # status lists the last five would-ask commands
QUEUED_MIN_MS = 5.0                # a wait on the ask lock this long means another window held it
ROW_SCAN_BYTES = 64 * 1024 * 1024  # status reads at most this much of the decision log for the queued count


def _n(x):
    """A whole number with thousands separators."""
    try:
        return "{:,}".format(int(round(float(x))))
    except (TypeError, ValueError):
        return "?"


def _plural(n, one, many=None):
    return "%s %s" % (_n(n), one if int(n) == 1 else (many or one + "s"))


def _ago(secs):
    secs = max(0, int(secs))
    if secs < 120:
        return "%d s" % secs
    if secs < 7200:
        return "%d min" % (secs // 60)
    return "%d h %d min" % (secs // 3600, (secs % 3600) // 60)


def _clock(epoch):
    lt = time.localtime(epoch)
    if time.strftime("%Y-%m-%d", lt) == time.strftime("%Y-%m-%d"):
        return time.strftime("%H:%M", lt)
    return time.strftime("%b %d %H:%M", lt)


def _sentinel(root):
    """(epoch or None, the session word or None) from the sentinel's one line: `<ISO time> session <sid>`."""
    try:
        line = amilib.sentinel_path(root).read_text().strip()
    except OSError:
        return None, None
    parts = line.split()
    when = None
    if parts:
        try:
            from datetime import datetime
            when = datetime.strptime(parts[0], "%Y-%m-%dT%H:%M:%S%z").timestamp()
        except ValueError:
            when = None
    sid = parts[2] if len(parts) >= 3 and parts[1] == "session" else None
    return when, sid


def _ordinal(n):
    words = {1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth"}
    return words.get(n, "%dth" % n)


def memory_line(d, command):
    """§8.2: footprint when it answers, labelled; else ps rss, labelled — ps under-counts what MPS keeps in Metal
    buffers (the lab measured 4 GB missing)."""
    if d.get("borrowed"):
        return "memory: the daemon is borrowed from another deployment — its memory is that deployment's (footprint -p <pid> there)"
    pid = d.get("serve_pid")
    if pid is None or not identified(pid, "serve", command):
        return "memory: no serve process of this deployment is running"
    rss_mb = None
    try:
        r = subprocess.run(["ps", "-o", "rss=", "-p", str(int(pid))], capture_output=True, text=True, timeout=5)
        if r.returncode == 0 and r.stdout.strip():
            rss_mb = int(r.stdout.strip().split()[0]) / 1024.0
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    total = metal = None
    try:
        r = subprocess.run(["footprint", "-p", str(int(pid)), "-f", "bytes"], capture_output=True, text=True,
                           timeout=20)
        if r.returncode == 0:
            import re
            m = re.search(r"Footprint:\s*(\d+)\s*B", r.stdout)
            if m:
                total = int(m.group(1)) / 1048576.0
                metal = 0.0
                for ln in r.stdout.splitlines():
                    if "IOAccelerator" in ln:
                        mm = re.match(r"\s*(\d+)\s*B", ln)
                        if mm:
                            metal += int(mm.group(1)) / 1048576.0
    except (OSError, ValueError, subprocess.SubprocessError):
        total = None
    if total is not None:
        line = "memory: %s MB resident (footprint" % _n(total)
        line += "; %s MB of it in Metal buffers)" % _n(metal) if metal else ")"
        if rss_mb is not None:
            line += " — ps shows %s MB" % _n(rss_mb)
        return line
    if rss_mb is not None:
        return ("memory: %s MB resident (ps rss; footprint was not available — ps under-counts what the GPU "
                "backends hold)" % _n(rss_mb))
    return "memory: serve pid %s did not report its memory (neither footprint nor ps answered)" % pid


def _log_files(root):
    try:
        return sorted(p for p in (amilib.ami_dir(root) / amilib.DECISIONS_DIR).glob("*.jsonl") if p.is_file())
    except OSError:
        return []


def _count_lines(p):
    try:
        with open(str(p), "rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def _queued(root, sid):
    """How often this session's questions waited on the ask lock behind another window, and the longest wait —
    from the decision log's question rows (status is not a hot path; the band never reads the log)."""
    n, longest, budget = 0, 0.0, ROW_SCAN_BYTES
    for p in reversed(_log_files(root)):
        try:
            size = p.stat().st_size
        except OSError:
            continue
        if size > budget:
            break
        budget -= size
        try:
            with open(str(p), "r", errors="replace") as fh:
                for ln in fh:
                    if '"queued_ms"' not in ln or sid not in ln:
                        continue
                    try:
                        row = json.loads(ln)
                    except ValueError:
                        continue
                    q = row.get("queued_ms")
                    if row.get("session") == sid and isinstance(q, (int, float)) and q >= QUEUED_MIN_MS:
                        n += 1
                        longest = max(longest, float(q))
        except OSError:
            continue
    return n, longest


def daemon_status_line(sw, d):
    state = sw["state"]
    now = time.time()
    if state == "on":
        head = "up %s" % _ago(now - (d.get("since") or now))
    elif state == "down" and sw.get("reason") == "supervisor gone":
        head = "its supervisor is gone (heartbeat %s ago) — /frame-jack off, then on" % _ago(now - (d.get("heartbeat") or 0))
    elif state == "down":
        if d.get("terminal"):
            head = "stopped for good: %s" % (d.get("last_error") or "see state/ami/daemon.log")
        else:
            head = "down (last error: %s) — /frame-jack on starts it again" % (
                d.get("last_error") or ("the port does not answer" if d.get("state") == "up" else "none recorded"))
    elif state == "battery":
        head = "paused on battery (it starts again on AC power)"
    elif state == "starting":
        head = "starting (%s)" % _ago(now - (d.get("since") or now))
    elif state == "tripped":
        head = "up, breaker tripped (slow or wedged) until %s" % _clock(sw.get("retry_epoch") or now)
    else:
        head = state
    hb = d.get("heartbeat")
    sup = "supervisor pid %s" % d.get("supervisor_pid")
    if pid_status(d.get("supervisor_pid"), "supervisor") != "live":
        sup += " (not running)"
    if isinstance(hb, (int, float)):
        sup += " (heartbeat %s ago)" % _ago(now - hb)
    parts = [sup]
    if d.get("borrowed"):
        parts.append("serve borrowed from another deployment")
    else:
        for kind, key in (("leash", "leash_pid"), ("serve", "serve_pid")):
            pid = d.get(key)
            if pid is None:
                parts.append("no %s" % kind)
                continue
            st = pid_status(pid, kind, d.get("command"))
            parts.append("%s pid %s%s" % (kind, pid, "" if st == "live" else
                                          " (not running)" if st == "dead" else " (recycled — another process now)"))
    parts.append("port %s" % d.get("port"))
    parts.append("device %s" % d.get("device"))
    if isinstance(d.get("ready_ms"), (int, float)):
        parts.append("ready in %d s" % int(round(d["ready_ms"] / 1000.0)))
    parts.append(_plural(int(d.get("restarts") or 0), "restart"))
    return "daemon: %s — %s" % (head, ", ".join(parts))


def questions_phrase(asked):
    """`destructive and suite asked` | `suite asked; destructive not asked (ami.ask_destructive is false — the
    default)` | `none asked (…)` — which questions the guard asks, from {question: bool}."""
    on = [q for q, _ in ASK_KEYS if asked.get(q)]
    off = [(q, k) for q, k in ASK_KEYS if not asked.get(q)]
    if not on:
        return "none asked (%s are both false)" % " and ".join("ami.%s" % k for _, k in off)
    if not off:
        return "%s asked" % " and ".join(on)
    why = "; ".join("%s not asked (ami.%s is false%s)" % (
        q, k, " — the default" if amilib.ASKED_DEFAULT[q] is False else "") for q, k in off)
    return "%s asked; %s" % (" and ".join(on), why)


def questions_line(cfg, d):
    """What the guard asks: the daemon's record when there is one (that is what the guard reads), else the
    config, else the defaults."""
    if d and d.get("command"):
        asked = amilib.asked_questions(d)
    elif cfg is not None:
        asked = cfg["questions"]
    else:
        asked = dict(amilib.ASKED_DEFAULT)
    return "questions: " + questions_phrase(asked)


def config_line(cfg, d):
    if cfg is None:
        return "config: no ami: block in config.yaml — frame-jack on will refuse until one is pasted"
    now_desc = "port %s, device %s, offline %s" % (cfg["port"], cfg["device"], "yes" if cfg["offline"] else "no")
    if not d or not d.get("command"):
        return "config: %s (no daemon on record to compare with)" % now_desc
    changed = []
    then_asked = amilib.asked_questions(d)
    for k in ("command", "model", "device", "port", "offline", "battery_off", "request_timeout_ms",
              "ask_destructive", "ask_suite", "enforce"):
        then, now_v = d.get(k), cfg.get(k)
        if k.startswith("ask_"):
            then, now_v = then_asked[k[4:]], cfg["questions"][k[4:]]
        if k == "enforce":
            same = sorted(then or []) == sorted(now_v or [])
            fmt = lambda x: ", ".join(x) if x else "nothing"          # noqa: E731
        elif k in ("offline", "battery_off") or k.startswith("ask_"):
            same = bool(then) == bool(now_v)
            fmt = lambda x: "true" if x else "false"                  # noqa: E731
        else:
            same = str(then) == str(now_v)
            fmt = str
        if not same:
            changed.append("ami.%s is %s now, %s when it started" % (k, fmt(now_v), fmt(then)))
    if changed:
        return "config: changed since the daemon started — %s; /frame-jack off, then on, applies it" % "; ".join(changed)
    return "config: as the daemon started with (%s)" % now_desc


def cmd_status(root):
    sid = ll.session_id_from_env()
    base = amilib.ami_dir(root)
    out = []
    try:
        cfg = read_config(root)
    except Exception:
        cfg = None
    if not base.is_dir():
        print("frame-jack: off — never switched on in this deployment (/frame-jack on starts the AMI)")
        print(questions_line(cfg, None))
        print(config_line(cfg, None))
        return 0
    d = amilib._read_json(amilib.daemon_path(root)) or {}
    sw = amilib.switch_detail(root, sid)
    if sw["state"] == "off":
        out.append("frame-jack: off (the sentinel is absent; /frame-jack on starts the AMI)")
        if d.get("off_by"):
            out.append("last switched off by: %s" % d["off_by"])
    else:
        when, who = _sentinel(root)
        since = "on since %s" % _clock(when) if when else "on"
        if who and sid and who == sid:
            by = "this session, by the operator"
        elif who and who != "shell":
            by = "session %s" % who
        else:
            by = "from a shell"
        mode = "shadow mode — the AMI logs, never acts"
        asked_for = amilib.enforce_requested(root)
        if asked_for:
            mode += " (ami.enforce names %s, which no release has certified to act)" % ", ".join(asked_for)
        out.append("frame-jack: %s (%s), %s" % (since, by, mode))
        out.append(questions_line(cfg, d))
        if sw["state"] == "unconfigured":
            out.append("daemon: no usable record (state/ami/daemon.json is missing or its command is not executable) "
                       "— /frame-jack off, then on")
        else:
            out.append(daemon_status_line(sw, d))
            out.append(memory_line(d, d.get("command")))
    # this session
    c = amilib.counters(root, sid) if sid else None
    if not sid:
        out.append("this session: run from a shell, so there are no session counts (each session's are in "
                   "state/ami/session-<id>.json)")
    elif not c:
        out.append("this session: no questions asked yet")
    else:
        asked = c.get("asked") or {}
        total = sum(int(v or 0) for v in asked.values())
        out.append("this session: %s asked (%s)" % (_plural(total, "question"), ", ".join(
            "%s %s" % (q, _n(asked.get(q) or 0)) for q in amilib.QUESTIONS)))
        wa = int(c.get("would_ask") or 0)
        recent = [x for x in (c.get("recent_would_ask") or []) if isinstance(x, str)]
        if wa:
            out.append("  would have asked you %s — the commands:" % _plural(wa, "time"))
            shown = recent[-SHOWN_WOULD_ASK:]
            for cmd in shown:
                out.append("    " + (cmd.splitlines()[0] if cmd.strip() else "(empty)"))
            if wa > len(shown):
                out.append("    … (%s more; all %s are in the decision log, state/ami/decisions/)" % (
                    _n(wa - len(shown)), _n(wa)))
            out.append("  of those %s: %s carried a guard warning too (the deterministic guard agreed), %s then failed" % (
                _n(wa), _n(c.get("would_ask_with_guard_warning") or 0), _n(c.get("would_ask_then_failed") or 0)))
        else:
            out.append("  would have asked you 0 times")
        out.append("  would have shortened %s of the %s suite runs — %s of those then failed" % (
            _n(c.get("would_shorten") or 0), _n(asked.get("suite") or 0), _n(c.get("shortened_then_failed") or 0)))
        un = {k: int(v or 0) for k, v in (c.get("unanswered") or {}).items() if int(v or 0)}
        if un:
            out.append("unanswered this session: %s (%s)" % (_n(sum(un.values())), ", ".join(
                "%s %s" % (k, _n(v)) for k, v in sorted(un.items(), key=lambda kv: (-kv[1], kv[0])))))
        else:
            out.append("unanswered this session: 0")
        recent_lat = sorted(x for x in (c.get("latency_recent") or []) if isinstance(x, (int, float)))
        lat = c.get("latency_ms") if isinstance(c.get("latency_ms"), list) else [0, 0, 0]
        if recent_lat:
            n = len(recent_lat)
            med = recent_lat[n // 2] if n % 2 else (recent_lat[n // 2 - 1] + recent_lat[n // 2]) / 2.0
            qn, ql = _queued(root, sid)
            queued = ("queued behind another window: %s, longest %s ms" % (_plural(qn, "time"), _n(ql))
                      if qn else "never queued behind another window")
            out.append("latency this session: median %s ms, max %s ms (%s)" % (
                _n(med), _n(lat[2] if len(lat) > 2 else max(recent_lat)), queued))
        else:
            out.append("latency this session: no answers yet")
        asks, ov = int(c.get("asks") or 0), int(c.get("overrides") or 0)
        if not asks:
            out.append("overrides: none — shadow mode asks nothing; when a question is certified to act, an ask the "
                       "operator then approves counts here (inferred from the outcome rows)")
        else:
            out.append("overrides: %s of %s asks were approved and ran (inferred from the outcome rows: an ask "
                       "followed by the command running)" % (_n(ov), _n(asks)))
        br = c.get("breaker") or {}
        until = br.get("tripped_until")
        if isinstance(until, (int, float)) and until > time.time():
            out.append("breaker: tripped (slow or wedged) — retrying at %s; the %s trip this session" % (
                _clock(until), _ordinal(int(br.get("trips") or 1))))
        elif int(br.get("consecutive") or 0):
            out.append("breaker: not tripped; %s failed in a row (it trips at %d)" % (
                _plural(int(br["consecutive"]), "question"), amilib.BREAKER_STRIKES))
        else:
            out.append("breaker: not tripped this session")
    # the log, the calibration, the config
    files = _log_files(root)
    today = amilib.decisions_path(root)
    rel = "state/ami/%s/%s" % (amilib.DECISIONS_DIR, today.name)
    if files:
        out.append("decision log: %s (%s today, %s kept)" % (
            rel, _plural(_count_lines(today) if today.exists() else 0, "row"), _plural(len(files), "day")))
    else:
        out.append("decision log: none yet (state/ami/decisions/ holds one file per day)")
    running = d.get("device") if d else None
    label = amilib.CALIBRATION.split(",")
    cal = "%s (%s)" % (label[0].strip(), label[1].strip() if len(label) > 1 else MEASURED_DEVICE.upper())
    if running and running == MEASURED_DEVICE:
        dev = "measured and running device %s" % running
    elif running:
        dev = "measured device %s, running device %s" % (MEASURED_DEVICE, running)
    else:
        dev = "measured device %s, running device unknown (no daemon on record)" % MEASURED_DEVICE
    out.append("calibration: thresholds from %s; %s — re-measure before any question acts" % (cal, dev))
    out.append(config_line(cfg, d))
    for ln in out:
        print(ln)
    return 0


# ---------------------------------------------------------------- §10 --doctor
WEIGHT_FOLDERS = ("models--Qwen--Qwen3.5-2B-Base", "models--StrandsAgents--strands-decider-2B-qwen3.5-v1-2610")


def _tilde(path):
    home = os.path.expanduser("~")
    p = str(path)
    return "~" + p[len(home):] if home and home != "/" and (p == home or p.startswith(home + os.sep)) else p


def hub_dir(cfg):
    """The weights cache's hub: ami.weights_cache (the daemon's HF_HOME), else the fixture's AMI_TEST_HF_HOME,
    else HF_HOME, else ~/.cache/huggingface."""
    home = (cfg or {}).get("weights_cache") or os.environ.get("AMI_TEST_HF_HOME") or os.environ.get("HF_HOME") \
        or os.path.join(os.path.expanduser("~"), ".cache", "huggingface")
    return Path(os.path.expanduser(home)) / "hub"


def snapshot_state(folder):
    """(`present` | `missing` | `dangling`, bytes) — present when some snapshot has at least one entry and every
    entry is a regular file or a symlink that resolves (os.path.exists follows links); dangling when the
    entries are links to nothing (the folders were copied without the shared blob store)."""
    snaps = folder / "snapshots"
    best, dangling = None, False
    try:
        revs = sorted(p for p in snaps.iterdir() if p.is_dir())
    except OSError:
        return "missing", 0
    for rev in revs:
        entries, ok, size, seen = 0, True, 0, set()
        for dirpath, _dirs, names in os.walk(str(rev)):
            for name in names:
                path = os.path.join(dirpath, name)
                entries += 1
                if not os.path.exists(path):
                    ok = False
                    continue
                real = os.path.realpath(path)
                if real not in seen:
                    seen.add(real)
                    try:
                        size += os.stat(path).st_size
                    except OSError:
                        ok = False
        if entries and ok:
            best = size if best is None else max(best, size)
        elif entries:
            dangling = True
    if best is not None:
        return "present", best
    return ("dangling" if dangling else "missing"), 0


def _size_word(b):
    return "%.2f GB" % (b / 1e9) if b >= 1e8 else "%.1f MB" % (b / 1e6)


def _ps_listing():
    seam = os.environ.get("AMI_TEST_PS")
    try:
        import shlex
        cmd = shlex.split(seam) if seam else ["ps", "-axo", "pid=,command="]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return r.stdout if r.returncode == 0 else ""
    except (OSError, ValueError, subprocess.SubprocessError):
        return ""


def second_serves(cfg, d):
    """`ps -axo pid=,command=` lines naming `strands-decider serve` (or the configured command's basename) whose
    pid is not this deployment's serve_pid and whose port is not this deployment's (a daemon on our port is ours
    or the one we borrow — one daemon either way). [(pid, port or None)]."""
    import re
    names = {"strands-decider"}
    if cfg and cfg.get("command"):
        names.add(os.path.basename(str(cfg["command"])))
    pat = re.compile(r"(?:^|[\s/])(?:%s)\s+serve(?:\s|$)" % "|".join(re.escape(n) for n in sorted(names)))
    own_pid = (d or {}).get("serve_pid")
    own_port = (cfg or {}).get("port")
    found = []
    for ln in _ps_listing().splitlines():
        parts = ln.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        pid, command = int(parts[0]), parts[1]
        argv0 = command.split(None, 1)[0]
        if os.path.basename(argv0) in ("sh", "bash", "zsh", "grep", "pgrep", "ps"):
            continue
        if not pat.search(command):
            continue
        m = re.search(r"--port[\s=](\d+)", command)
        port = int(m.group(1)) if m else None
        if pid == os.getpid() or (own_pid is not None and pid == own_pid):
            continue
        if port is not None and own_port is not None and port == own_port:
            continue
        found.append((pid, port))
    return found


def doctor_lines(root):
    lines = []
    cfg = read_config(root)
    base = amilib.ami_dir(root)
    if cfg is None:
        lines.append('NOTE     frame-jack: no ami: block in config.yaml — the AMI cannot be switched on (optional; '
                     'see "Frame-jack" in README.md)')
        if not base.is_dir():
            return lines
    else:
        problems = list(cfg["problems"])
        for q in cfg["enforce"]:
            if q not in amilib.CERTIFIED:
                problems.append("ami.enforce names %s, which no release has certified to act — remove it; the "
                                "question stays in shadow mode" % q)
        for p in problems:
            lines.append("MISSING  frame-jack: %s" % p)
        if not problems:
            lines.append("OK       frame-jack: strands-decider at %s, model %s, device %s, port %s, %s" % (
                cfg["command"], cfg["model"], cfg["device"], cfg["port"], "offline" if cfg["offline"] else "online"))
        if any(cfg["questions"].values()):
            lines.append("OK       frame-jack questions: " + questions_phrase(cfg["questions"]))
        else:
            lines.append("NOTE     frame-jack questions: %s — switched on, the daemon would hold about 5.2 GB for "
                         "nothing; leave frame-jack off" % questions_phrase(cfg["questions"]))
        if cfg["shadow_leftover"]:
            lines.append("NOTE     frame-jack: ami.shadow is no longer read — ami.ask_destructive and ami.ask_suite "
                         "say which questions are asked; remove the shadow line")
        # the weights
        hub = hub_dir(cfg)
        total, states = 0, {}
        for name in WEIGHT_FOLDERS:
            st, size = snapshot_state(hub / name)
            states[name] = st
            total += size
        for name in WEIGHT_FOLDERS:
            if states[name] == "missing":
                remedy = ('copy it by hand (README "Weights by hand"); ami.offline is true, so the daemon will not '
                          'download it' if cfg["offline"] else
                          'copy it by hand (README "Weights by hand") or let the first start download it '
                          '(ami.offline is false)')
                lines.append("NOTE     frame-jack weights: the model snapshot is missing under %s (%s) — %s" % (
                    _tilde(hub), name, remedy))
            elif states[name] == "dangling":
                lines.append('NOTE     frame-jack weights: %s has links into a blob store that is not there — the '
                             'folders were copied without the blobs; copy with the tarball in README "Weights by '
                             'hand"' % name)
        if all(s == "present" for s in states.values()):
            lines.append("OK       frame-jack weights: both snapshots present (%s)" % _size_word(total))
    # the daemon
    d = amilib._read_json(amilib.daemon_path(root)) or {}
    sw = amilib.switch_detail(root, None)
    state, now = sw["state"], time.time()
    port = d.get("port") or (cfg or {}).get("port")
    model = d.get("model") or (cfg or {}).get("model")
    if state in ("absent", "off"):
        lines.append("OK       frame-jack: off (the sentinel is absent; /frame-jack on starts the AMI)")
    elif state == "unconfigured":
        lines.append("NOTE     frame-jack: on but the daemon has no usable record (state/ami/daemon.json is missing or "
                     "its command is not executable) — /frame-jack off, then on")
    elif state == "down" and sw.get("reason") == "supervisor gone":
        serve = d.get("serve_pid")
        if serve is not None and identified(serve, "serve", d.get("command")):
            tail = "serve pid %s still running" % serve
        else:
            tail = "no serve running"
        lines.append("NOTE     frame-jack: on but its supervisor is gone (heartbeat %s ago; %s) — /frame-jack off, "
                     "then on" % (_ago(now - (d.get("heartbeat") or 0)), tail))
    elif state == "down" and d.get("terminal"):
        lines.append("NOTE     frame-jack: on but the daemon stopped for good: %s" % (
            d.get("last_error") or "see state/ami/daemon.log"))
    elif state == "down":
        lines.append("NOTE     frame-jack: on but the daemon is down (last error: %s) — /frame-jack on starts it "
                     "again" % (d.get("last_error") or ("port %s does not answer" % port)))
    elif state == "battery":
        lines.append("NOTE     frame-jack: on, paused on battery")
    elif state == "starting":
        lines.append("NOTE     frame-jack: on, the daemon is starting (%s)" % _ago(now - (d.get("since") or now)))
    elif state in ("on", "tripped"):
        if port is not None and not is_ami(port, model):
            pass                                            # the port line below says it
        else:
            today = amilib.decisions_path(root)
            serve = ("serve borrowed from another deployment" if d.get("borrowed")
                     else "serve pid %s" % d.get("serve_pid"))
            lines.append("OK       frame-jack: on — daemon up on port %s (%s, device %s, supervisor heartbeat %s ago), "
                         "shadow mode, %s logged today" % (
                             port, serve, d.get("device"), _ago(now - (d.get("heartbeat") or now)),
                             _plural(_count_lines(today) if today.exists() else 0, "decision")))
    # the port, by §4.4's comparison, whenever it answers
    if port is not None and model and amilib._port_open(port) and not is_ami(port, model):
        lines.append("NOTE     frame-jack: port %s is held by something that is not the AMI — change ami.port in "
                     "config.yaml" % port)
    for pid, other_port in second_serves(cfg, d):
        lines.append("NOTE     frame-jack: a second strands-decider serve is running on this machine (pid %s, port %s, "
                     "not this deployment's) — two daemons cost twice 5.3 GB; name the same ami.port in both "
                     "deployments so one borrows the other" % (pid, other_port if other_port is not None else "unknown"))
    return lines


def cmd_doctor(root):
    for ln in doctor_lines(root):
        print(ln)
    return 0


# ---------------------------------------------------------------- main
def main(argv):
    verb = argv[0] if argv else "status"
    root = v.ROOT
    if verb == "on":
        return cmd_on(root)
    if verb == "off":
        return cmd_off(root)
    if verb == "status":
        return cmd_status(root)
    if verb == "--doctor":
        return cmd_doctor(root)
    print("frame-jack: say on, off or status (got %s)" % verb)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(1)
