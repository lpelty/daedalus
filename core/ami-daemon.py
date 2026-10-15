#!/usr/bin/env python3
"""ami-daemon — the supervisor that keeps `strands-decider serve` on a leash (frame-jack spec §4.3), and the
leash itself.

    python3 core/ami-daemon.py --home <home> [--borrowed]          the supervisor (started by frame-jack on)
    python3 core/ami-daemon.py --leash --home <home> --command … --model … --port … --device … [--offline]
                               [--weights-cache …]                 the leash (started by the supervisor)

The supervisor: one per deployment (the first thing it does is read daemon.json and leave if a live,
identified supervisor is named there); every 30 s and on SIGTERM/SIGHUP one pass — the sentinel gone
stops everything and exits; battery (pmset -g batt, when ami.battery_off) stops serve and writes
`battery`; on AC with nothing running it re-probes the port first (an AMI there is adopted as borrowed,
never retried as a bind), else starts the leash, polls /health to readiness, pays the cold first call with
one warm-up question and writes `up`; serve running gets one /health per pass (three failures restart it)
and every tenth pass one bounded inference probe (two past the bound restart it). A terminal exit —
weights missing, or the port held by something that is not the AMI — is `down`, `terminal: true`, no
retry until the next `frame-jack on`. Every pass rewrites daemon.json (tmp + rename) with the heartbeat.

The leash: a child of the supervisor with the supervisor's pipe on its stdin; it starts serve with a
clean environment and waits on its stdin and on serve's exit. EOF (the supervisor is gone, however it
went) → SIGTERM serve, 10 s, SIGKILL, exit 0; serve exit → exit with serve's code; SIGTERM → stop serve,
exit 0. So "5 GB freed" is a property of the process tree, not of the supervisor staying healthy.

The home travels as --home and is re-exported as DAEDALUS_HOME before the one config read (§4.3);
everything else environment-shaped is dropped before serve starts. Python 3.9, standard library.
AMI_TEST_POLL_SECS (shrink-only) scales the poll, the readiness poll and the backoff for tests.
"""
import argparse
import importlib.util
import os
import select
import signal
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

POLL_SECS = 30.0
READY_POLL_SECS = 2.0
READY_MAX_SECS = 120.0
READY_MIN_SECS = 10.0                # the readiness bound never shrinks under this, whatever the knob says
BACKOFF_SECS = (30.0, 60.0, 120.0, 300.0)
BACKOFF_FINAL_SECS = 3600.0
HEALTH_FAILS_TO_RESTART = 3
PROBE_EVERY_PASSES = 10
PROBE_BOUND_SECS = 5.0
PROBE_FAILS_TO_RESTART = 2
WARMUP_BOUND_SECS = 30.0
STOP_GRACE_SECS = 10.0
PID_LINE_WAIT_SECS = 10.0
TERMINAL_WEIGHTS = ("LocalEntryNotFoundError", "OfflineModeIsEnabled", "not found in cache",
                    "Cannot find the requested files in the disk cache")
TERMINAL_BIND = ("address already in use",)
DROP_PREFIXES = ("CLAUDE", "DAEDALUS_")
DROP_VARS = ("DIRECT_CALL_ID",)
OWN_PREFIXES = ("supervisor: ", "leash: ")
LAST_ERROR_CHARS = 300


def log(prefix, msg):
    try:
        sys.stderr.write("%s%s %s\n" % (prefix, time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
        sys.stderr.flush()
    except (OSError, ValueError):
        pass


def clean_env(offline=False, weights_cache=None):
    env = {k: val for k, val in os.environ.items()
           if not k.startswith(DROP_PREFIXES) and k not in DROP_VARS}
    env.pop("HF_HUB_OFFLINE", None)
    if offline:
        env["HF_HUB_OFFLINE"] = "1"
    if weights_cache:
        env["HF_HOME"] = str(weights_cache)
    return env


def test_scale():
    """AMI_TEST_POLL_SECS shrinks the 30 s poll; the readiness poll and the backoff scale with it."""
    raw = os.environ.get("AMI_TEST_POLL_SECS")
    if not raw:
        return 1.0
    try:
        secs = float(raw)
    except ValueError:
        return 1.0
    if secs <= 0 or secs >= POLL_SECS:
        return 1.0
    return secs / POLL_SECS


def load_frame_jack():
    spec = importlib.util.spec_from_file_location("frame_jack", str(HERE / "frame-jack.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- the leash
def stop_process(proc, grace=STOP_GRACE_SECS):
    if proc.poll() is not None:
        return
    try:
        proc.terminate()
    except OSError:
        return
    try:
        proc.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        proc.kill()
        proc.wait(timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        pass


def leash(args):
    cmd = [args.command, "serve", args.model, "--port", str(args.port), "--device", args.device]
    env = clean_env(offline=args.offline, weights_cache=args.weights_cache)
    try:
        serve = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=2, stderr=2, env=env, close_fds=True)
    except OSError as e:
        log("leash: ", "could not start %s: %s" % (args.command, e))
        sys.stdout.write("pid 0\n")
        sys.stdout.flush()
        return 1
    sys.stdout.write("pid %d\n" % serve.pid)
    sys.stdout.flush()
    log("leash: ", "serve started, pid %d" % serve.pid)
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append("signal"))
    signal.signal(signal.SIGHUP, lambda *_: stopping.append("signal"))
    while True:
        rc = serve.poll()
        if rc is not None:
            log("leash: ", "serve exited with code %s" % rc)
            return rc if 0 <= rc < 256 else 1
        if stopping:
            log("leash: ", "stopping serve (%s)" % stopping[0])
            stop_process(serve)
            return 0
        try:
            ready, _, _ = select.select([0], [], [], 0.2)
        except (OSError, ValueError):
            ready = [0]
        if ready:
            try:
                data = os.read(0, 4096)
            except OSError:
                data = b""
            if not data:
                stopping.append("the supervisor is gone")


# ---------------------------------------------------------------- the supervisor
class Supervisor:
    def __init__(self, root, borrowed, cfg, fj, amilib):
        self.root = root
        self.cfg = cfg
        self.fj = fj
        self.amilib = amilib
        self.scale = test_scale()
        self.poll = POLL_SECS * self.scale
        self.ready_poll = max(0.2, READY_POLL_SECS * self.scale)
        self.ready_max = max(READY_MIN_SECS, READY_MAX_SECS * self.scale)
        self.wake = False
        self.leash_proc = None
        self.launched_once = False
        self.backoff_index = 0
        self.next_start = 0.0
        self.health_fails = 0
        self.probe_fails = 0
        self.pass_no = 0
        self.rec = {
            "supervisor_pid": os.getpid(), "leash_pid": None, "serve_pid": None, "borrowed": bool(borrowed),
            "port": cfg["port"], "device": cfg["device"], "state": "starting", "terminal": False,
            "since": time.time(), "heartbeat": time.time(), "ready_ms": None, "restarts": 0, "last_error": None,
            "off_by": None, "command": cfg["command"], "model": cfg["model"], "offline": cfg["offline"],
            "battery_off": cfg["battery_off"], "request_timeout_ms": cfg["request_timeout_ms"],
            "shadow": list(cfg["shadow"]), "enforce": list(cfg["enforce"]),
        }
        self.warm_state = amilib.state_destructive({
            "git_branch": "main", "cwd": str(root), "worktree_line": amilib.worktree_line(root),
            "last_operator_message": "warm up the AMI", "previous_tool_calls": [],
            "description": "list the files in the home", "command": "ls -la"})

    # -- the record
    def write(self, first=False):
        self.rec["heartbeat"] = time.time()
        p = self.amilib.daemon_path(self.root)
        if first:
            self.amilib._write_json(p, self.rec)          # under the lock `frame-jack on` holds (plan Decision 4)
            return
        with self.amilib._Locked(self.amilib.lock_path(self.root)):
            self.amilib._write_json(p, self.rec)

    # -- probes
    def on_battery(self):
        if not self.cfg["battery_off"]:
            return False
        try:
            r = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5)
            first = (r.stdout.splitlines() or [""])[0]
            return "'Battery Power'" in first
        except (OSError, subprocess.SubprocessError):
            return False                                  # a pmset failure never stops the daemon

    def health(self):
        return self.fj.health(self.cfg["port"])

    def log_tail(self, n=20):
        try:
            with open(str(self.amilib.ami_dir(self.root) / "daemon.log"), "rb") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(0, size - 8192))
                lines = fh.read().decode("utf-8", "replace").splitlines()
        except OSError:
            return []
        return [ln for ln in lines if ln.strip() and not ln.startswith(OWN_PREFIXES)][-n:]

    def serve_running(self):
        return self.leash_proc is not None and self.leash_proc.poll() is None

    # -- stopping
    def stop_tree(self):
        """SIGTERM the leash (it stops serve), 10 s, then SIGKILL both — every signal after the identity rule."""
        proc = self.leash_proc
        serve_pid = self.rec.get("serve_pid")
        if proc is not None:
            if proc.poll() is None:
                stop_process(proc)
            self.leash_proc = None
        if serve_pid and self.fj.identified(serve_pid, "serve", self.cfg["command"]):
            self.fj._stop(serve_pid, grace=2.0)
        self.rec["leash_pid"] = None
        self.rec["serve_pid"] = None

    # -- starting
    def launch(self):
        self.rec["state"] = "starting"
        self.rec["terminal"] = False
        if self.launched_once:
            self.rec["restarts"] = int(self.rec.get("restarts") or 0) + 1
        self.launched_once = True
        self.write()
        args = [sys.executable, str(HERE / "ami-daemon.py"), "--leash", "--home", str(self.root),
                "--command", self.cfg["command"], "--model", self.cfg["model"], "--port", str(self.cfg["port"]),
                "--device", self.cfg["device"]]
        if self.cfg["offline"]:
            args.append("--offline")
        if self.cfg.get("weights_cache"):
            args += ["--weights-cache", self.cfg["weights_cache"]]
        t0 = time.monotonic()
        try:
            proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=2,
                                    close_fds=True, env=clean_env())
        except OSError as e:
            return self.launch_failed("could not start the leash: %s" % e)
        self.leash_proc = proc
        self.rec["leash_pid"] = proc.pid
        log("supervisor: ", "leash started, pid %d" % proc.pid)
        # the leash's one stdout line: the serve pid
        serve_pid = None
        end = time.monotonic() + PID_LINE_WAIT_SECS
        while time.monotonic() < end and proc.poll() is None:
            ready, _, _ = select.select([proc.stdout], [], [], 0.2)
            if ready:
                line = proc.stdout.readline().decode("utf-8", "replace").strip()
                if line.startswith("pid "):
                    try:
                        serve_pid = int(line[4:]) or None
                    except ValueError:
                        serve_pid = None
                break
        self.rec["serve_pid"] = serve_pid
        # readiness
        end = time.monotonic() + self.ready_max
        h = None
        while time.monotonic() < end:
            if proc.poll() is not None:
                return self.launch_failed("serve exited with code %s before it answered" % proc.returncode)
            h = self.health()
            if h:
                break
            time.sleep(self.ready_poll)
        if not h:
            self.stop_tree()
            return self.launch_failed("serve did not answer /health within %d s" % int(self.ready_max))
        # the warm-up question pays the cold first call here
        ans = self.amilib.ask(self.cfg["port"], self.warm_state, "destructive",
                              time.monotonic() + WARMUP_BOUND_SECS, int(WARMUP_BOUND_SECS * 1000),
                              self.amilib.ask_lock_path(self.root))
        self.rec["ready_ms"] = int((time.monotonic() - t0) * 1000)
        self.rec["device"] = h.get("device") or self.cfg["device"]
        self.rec["state"] = "up"
        self.rec["last_error"] = None
        self.health_fails = 0
        self.probe_fails = 0
        self.backoff_index = 0
        log("supervisor: ", "serve is up on port %s (pid %s, device %s, ready in %d ms, warm-up %r)" % (
            self.cfg["port"], serve_pid, self.rec["device"], self.rec["ready_ms"], ans))
        return True

    def launch_failed(self, why):
        tail = self.log_tail()
        last = tail[-1] if tail else why
        joined = "\n".join(tail)
        self.stop_tree()
        self.rec["state"] = "down"
        if any(pat in joined for pat in TERMINAL_WEIGHTS):
            snapshot = "models--" + str(self.cfg["model"]).replace("/", "--")
            self.rec["terminal"] = True
            self.rec["last_error"] = ("the weights are missing (%s) — copy them (README \"Weights by hand\"), then "
                                      "/frame-jack on: %s" % (snapshot, last[:LAST_ERROR_CHARS]))
        elif any(pat in joined.lower() for pat in TERMINAL_BIND) and not self.fj.is_ami(self.cfg["port"], self.cfg["model"]):
            self.rec["terminal"] = True
            self.rec["last_error"] = ("port %s is held by something that is not the AMI — change ami.port in "
                                      "config.yaml, then /frame-jack on" % self.cfg["port"])
        else:
            self.rec["terminal"] = False
            self.rec["last_error"] = (why + ": " + last)[:LAST_ERROR_CHARS] if tail else why[:LAST_ERROR_CHARS]
            wait = (BACKOFF_SECS[self.backoff_index] if self.backoff_index < len(BACKOFF_SECS)
                    else BACKOFF_FINAL_SECS) * self.scale
            self.backoff_index += 1
            self.next_start = time.monotonic() + wait
        log("supervisor: ", "launch failed — %s%s" % (self.rec["last_error"],
                                                       " (no retry until the next frame-jack on)" if self.rec["terminal"] else ""))
        return False

    # -- one pass
    def tick(self):
        self.pass_no += 1
        amilib = self.amilib
        # 1. the sentinel gone
        if not amilib.sentinel_path(self.root).exists():
            cur = amilib._read_json(amilib.daemon_path(self.root)) or {}
            self.stop_tree()
            self.rec["state"] = "off"
            self.rec["off_by"] = cur.get("off_by") or "sentinel removed by hand"
            self.write()
            log("supervisor: ", "off (%s)" % self.rec["off_by"])
            return True
        # 2. battery
        if self.on_battery():
            if self.serve_running():
                log("supervisor: ", "on battery — stopping serve")
                self.stop_tree()
            self.rec["state"] = "battery"
            self.write()
            return False
        # borrowed: the power watcher and the heartbeat; one /health so the state word is true
        if self.rec["borrowed"]:
            if self.health():
                self.rec["state"] = "up"
                self.rec["last_error"] = None
            else:
                self.rec["state"] = "down"
                self.rec["last_error"] = ("the borrowed AMI on port %s stopped answering (started by another "
                                          "deployment) — /frame-jack off, then on" % self.cfg["port"])
            self.write()
            return False
        # 4. serve running
        if self.serve_running():
            h = self.health()
            if h:
                self.health_fails = 0
                self.rec["state"] = "up"
                self.rec["device"] = h.get("device") or self.rec["device"]
            else:
                self.health_fails += 1
                log("supervisor: ", "/health failed (%d of %d)" % (self.health_fails, HEALTH_FAILS_TO_RESTART))
                if self.health_fails >= HEALTH_FAILS_TO_RESTART:
                    self.rec["last_error"] = "serve stopped answering /health; restarted"
                    self.stop_tree()
                    self.launch()
                    self.write()
                    return False
            if h and self.pass_no % PROBE_EVERY_PASSES == 0:
                ans = amilib.ask(self.cfg["port"], self.warm_state, "destructive",
                                 time.monotonic() + PROBE_BOUND_SECS, int(PROBE_BOUND_SECS * 1000),
                                 amilib.ask_lock_path(self.root))
                if isinstance(ans, amilib.Answer):
                    self.probe_fails = 0
                elif ans.reason == "timeout":
                    self.probe_fails += 1
                    log("supervisor: ", "inference probe past %d s (%d of %d)" % (
                        int(PROBE_BOUND_SECS), self.probe_fails, PROBE_FAILS_TO_RESTART))
                    if self.probe_fails >= PROBE_FAILS_TO_RESTART:
                        self.rec["last_error"] = "serve answered /health but not a question; restarted"
                        self.stop_tree()
                        self.launch()
            self.write()
            return False
        # serve not running: a leash that exited since the last pass
        if self.leash_proc is not None:
            rc = self.leash_proc.returncode
            self.launch_failed("serve exited with code %s" % rc)
            self.write()
            return False
        if self.rec.get("terminal"):
            self.write()
            return False
        # 3. re-probe first, then start
        h = self.health()
        if h:
            if self.fj.is_ami(self.cfg["port"], self.cfg["model"], h):
                self.rec.update({"borrowed": True, "serve_pid": None, "leash_pid": None, "state": "up",
                                 "device": h.get("device") or self.rec["device"], "last_error": None})
                log("supervisor: ", "adopted the AMI already on port %s (borrowed; no bind will be tried)" % self.cfg["port"])
            else:
                self.rec.update({"state": "down", "terminal": True,
                                 "last_error": "port %s is held by something that is not the AMI — change ami.port "
                                               "in config.yaml, then /frame-jack on" % self.cfg["port"]})
                log("supervisor: ", self.rec["last_error"])
            self.write()
            return False
        if time.monotonic() < self.next_start:
            self.write()
            return False
        self.launch()
        self.write()
        return False

    def sleep_until_next(self):
        end = time.monotonic() + self.poll
        while time.monotonic() < end and not self.wake:
            time.sleep(min(0.25, max(0.0, end - time.monotonic())))
        self.wake = False

    def run(self):
        amilib, fj = self.amilib, self.fj
        cur = amilib._read_json(amilib.daemon_path(self.root)) or {}
        other = cur.get("supervisor_pid")
        if other and other != os.getpid() and fj.identified(other, "supervisor"):
            log("supervisor: ", "another supervisor (pid %s) is alive for this deployment; leaving" % other)
            return 0
        if self.on_battery():
            self.rec["state"] = "battery"
        self.write(first=True)
        log("supervisor: ", "started (pid %d, port %s, %s)" % (
            os.getpid(), self.cfg["port"], "borrowed" if self.rec["borrowed"] else "own serve"))

        def wake(*_):
            self.wake = True
        signal.signal(signal.SIGTERM, wake)
        signal.signal(signal.SIGHUP, wake)
        try:
            while True:
                if self.tick():
                    return 0
                self.sleep_until_next()
        finally:
            if self.leash_proc is not None and self.leash_proc.poll() is None:
                self.stop_tree()


def supervise(args):
    root = Path(args.home).resolve()
    os.environ["DAEDALUS_HOME"] = str(root)
    sys.path.insert(0, str(root / "core"))
    import amilib
    fj = load_frame_jack()
    cfg = fj.read_config(root)
    if cfg is None or cfg["problems"]:
        why = "no ami: block in config.yaml" if cfg is None else cfg["problems"][0]
        log("supervisor: ", "cannot start — %s" % why)
        base = amilib.ami_dir(root)
        if base.is_dir():
            amilib._write_json(amilib.daemon_path(root), {
                "supervisor_pid": os.getpid(), "leash_pid": None, "serve_pid": None, "borrowed": bool(args.borrowed),
                "port": None, "device": None, "state": "down", "terminal": True, "since": time.time(),
                "heartbeat": time.time(), "ready_ms": None, "restarts": 0, "last_error": why, "off_by": None,
                "command": None, "model": None, "offline": None, "battery_off": None, "request_timeout_ms": None,
                "shadow": [], "enforce": []})
        return 2
    return Supervisor(root, args.borrowed, cfg, fj, amilib).run()


def main(argv):
    ap = argparse.ArgumentParser(prog="ami-daemon.py", add_help=True)
    ap.add_argument("--home", required=True)
    ap.add_argument("--borrowed", action="store_true")
    ap.add_argument("--leash", action="store_true")
    ap.add_argument("--command")
    ap.add_argument("--model")
    ap.add_argument("--port", type=int)
    ap.add_argument("--device")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--weights-cache", dest="weights_cache")
    args = ap.parse_args(argv)
    if args.leash:
        if not (args.command and args.model and args.port and args.device):
            ap.error("--leash needs --command, --model, --port and --device")
        return leash(args)
    return supervise(args)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(1)
