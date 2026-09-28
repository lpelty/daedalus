#!/usr/bin/env python3
"""Run a command on a new pseudo-terminal — its controlling terminal, so it can
open /dev/tty — and type one line once its output contains a prompt:

    type-into.py [--detach] '<line>' '<prompt substring>' -- <cmd> [args...]

Prints everything the command wrote (the typed line is echoed by the pty) and
exits with the command's exit code. A 30 s ceiling kills it. --detach first
double-forks, so the pty and the command run in a process reparented to
launchd, with nothing of the caller's process tree above them (the tty
ancestry test, plan 4 Decision 32)."""
import os
import pty
import select
import signal
import sys
import tempfile
import time


def drive(line, prompt, cmd):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(cmd[0], cmd)
    buf, typed, deadline = b"", False, time.time() + 30
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                chunk = b""
            if not chunk:
                break
            buf += chunk
        if not typed and prompt in buf:
            os.write(fd, (line + "\n").encode())
            typed = True
    else:
        os.kill(pid, signal.SIGKILL)
    _, status = os.waitpid(pid, 0)
    return buf, os.waitstatus_to_exitcode(status)


args = sys.argv[1:]
detach = args[:1] == ["--detach"]
if detach:
    args = args[1:]
line, prompt = args[0], args[1].encode()
cmd = args[args.index("--") + 1:]
if not detach:
    buf, code = drive(line, prompt, cmd)
    sys.stdout.write(buf.decode("utf-8", "replace"))
    sys.exit(code)
out = tempfile.mkdtemp()
child = os.fork()
if child == 0:
    os.setsid()
    if os.fork():
        os._exit(0)                       # the grandchild is reparented to launchd
    buf, code = drive(line, prompt, cmd)
    with open(os.path.join(out, "out"), "wb") as fh:
        fh.write(buf)
    with open(os.path.join(out, "exit.tmp"), "w") as fh:
        fh.write(str(code))
    os.rename(os.path.join(out, "exit.tmp"), os.path.join(out, "exit"))
    os._exit(0)
os.waitpid(child, 0)
deadline = time.time() + 35
while time.time() < deadline and not os.path.exists(os.path.join(out, "exit")):
    time.sleep(0.1)
try:
    sys.stdout.write(open(os.path.join(out, "out"), "rb").read().decode("utf-8", "replace"))
    sys.exit(int(open(os.path.join(out, "exit")).read()))
except OSError:
    sys.exit("type-into: the detached command did not finish in 35 s")
