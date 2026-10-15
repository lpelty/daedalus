#!/usr/bin/env python3
"""frame-jack — the switch for the AMI (Artificial Machine Intelligence: Strands Decider 2B behind
`strands-decider serve`; frame-jack spec §8.2).

    python3 core/frame-jack.py on | off | status | --doctor      (no verb = status)

`on` reads the `ami:` block once (one `_lib` call), refuses with the lines to paste when there is none,
then — holding state/ami/.lock from the probe to the supervisor's first daemon.json write — probes the
port (§4.4: borrow the AMI if another deployment's daemon holds it, refuse anything else), writes the
sentinel and starts core/ami-daemon.py detached with a clean environment. `off` removes the sentinel,
records who flipped it, signals by the liveness-and-identity rule (§4.5) and prints what is true only
after the port went dead. `status` and `--doctor` arrive in a later task of the plan.

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
        "request_timeout_ms", "shadow", "enforce")
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
    "  shadow: destructive, suite",
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
    shadow = _list(raw.get("shadow"), "shadow", problems)
    cfg["shadow"] = list(amilib.QUESTIONS) if shadow is None else shadow
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


# ---------------------------------------------------------------- main
def main(argv):
    verb = argv[0] if argv else "status"
    root = v.ROOT
    if verb == "on":
        return cmd_on(root)
    if verb == "off":
        return cmd_off(root)
    if verb in ("status", "--doctor"):
        print("frame-jack %s: not in this build yet" % verb)
        return 2
    print("frame-jack: say on, off or status (got %s)" % verb)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(1)
