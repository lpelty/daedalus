# lease-board — the Daedalus lease board on screen

A Claude Code mod that draws the lease board in the band above the prompt in
every Daedalus window: this window's number, whether it holds the pen, and every
other window's state (live, quiet, stale, finished, released), its changed-file
count, its alias and its note. It refreshes every 2 seconds. After the windows,
each swept number that still holds unpromoted work — new windows skip it — is
one line with its commit count (0.1.4), as the last prompt's board found it.

```
window 02 · this window · live · 4 changed · poc-ui
window 01 · holds the pen · live · 0 changed
window 03 · quiet since 09:40 · 14 changed · electron · peer name daedalus-07
```

It reads only. Every 2 seconds it runs `python3 core/leaselib.py board-json
--session <id>` in the Daedalus home — the lease files and their sidecars under
the shared lock (waiting at most 1.5 seconds for it), then the session registry
once, with no git — and asks Claude Code to draw the band again. One read at a
time; a session nobody sits at (`claude -p`) starts no timer. It never writes a
file, never runs `git` or `core/lease.sh`, and never throws: when the read
fails, the last good board stays and one dim line says why
(`board unavailable: …`); when one lease file cannot be read, every other
window is still listed and one dim line names it (`one window is not shown: …`).

## Sharing the band

The band is one chain shared by every mod. The board keeps what the mods after
it draw, at the right end of its first line, so the service-status mod's
summary (`services ok  [ details ]`) sits there whichever of the two Claude
Code runs first; every other row is the board's. See
`mods/service-status/README.md`.

## The AMI line (frame-jack)

When frame-jack has been switched on in this deployment, one more line follows
the window lines: what the AMI (the small local decision model behind
`/frame-jack`) is doing in this session. It comes from the `ami` key of the same
`board-json` read — the switch file under `state/ami/`, the daemon's record, this
session's counts and one port check bounded at 100 ms; no config, no bash, no
git, no question asked of the model.

```
AMI on · shadow (logs, never acts) · 6 asked · destructive question off · would have shortened 2 · 171 ms
AMI on · shadow (logs, never acts) · 212 asked · would have asked you 7 times · would have shortened 2 · 171 ms
AMI on · shadow (logs, never acts) · 212 asked · would have asked you 7 times · would have shortened 2 · 171 ms · 3 overruled
AMI off
AMI on but the daemon is down — /frame-jack on
AMI on but its supervisor is gone — /frame-jack off, then on
AMI paused on battery
AMI starting (12 s)
AMI tripped (slow or wedged) — retrying at 09:48
AMI on but not configured — /frame-jack status
```

Plain when on, dim when off, the warning colour for every line that needs you.
`· N overruled` appears only when the AMI's call was overruled at least once.
A question switched off in config.yaml (`ami.ask_destructive`, off by default;
`ami.ask_suite`) reads `destructive question off` or `suite question off` in
place of its count, so a zero never looks like a measurement.
The line counts in the band's rows, so it never pushes a window line off; with
no windows it sits between the "no windows" line and the tail. It is left out
entirely when `board-json` has no `ami` key (an older Daedalus) or frame-jack was
never switched on here (`state/ami/` does not exist). `/frame-jack status`
prints the long form.

### The status line fallback (not built)

If the band cannot carry the line — a Claude Code build where this mod does not
load (doctor's `lease board on screen` says so), or mods disabled — the same line
can come from a `statusLine` script instead. It is not built: a status line is
one script per machine in user settings and would replace one you may already
run. This is what it would run, from the Daedalus home, so the fallback is a
paste rather than a design:

```bash
python3 core/leaselib.py board-json --session "$CLAUDE_CODE_SESSION_ID" | python3 -c '
import json, sys
a = json.load(sys.stdin).get("ami") or {}
s = a.get("state")
n = lambda k: a.get(k) or 0
if s == "on":
    q = a.get("questions") or {}
    wa = "destructive question off" if q.get("destructive") is False and not n("would_ask") else "would have asked you %d times" % n("would_ask")
    ws = "suite question off" if q.get("suite") is False and not n("would_shorten") else "would have shortened %d" % n("would_shorten")
    line = "AMI on · shadow (logs, never acts) · %d asked · %s · %s" % (n("asked"), wa, ws)
    line += " · %d ms" % a["median_ms"] if a.get("median_ms") is not None else ""
    line += " · %d overruled" % n("overrides") if n("overrides") else ""
    print(line)
elif s and s != "absent":
    print("AMI " + s)
'
```

Where neither the band nor a status line shows, the once-per-session message
the guard prints when the daemon is down is what tells you.

## Loading it

The mod ships inside the Daedalus repo, listed by the marketplace at
`mods/.claude-plugin/marketplace.json`. Each deployment registers it once, at
local scope, so the absolute path lands in the gitignored
`.claude/settings.local.json`. In the Daedalus home:

```bash
claude plugin marketplace add ./mods --scope local
claude plugin install lease-board@daedalus-mods --scope local
```

`core/setup.sh` runs both when they have not been run. Then open a new terminal,
or run `/reload-plugins` in a session that is already open. Edits under
`mods/lease-board/` reach the next session start without a version bump: the
plugin loads in place from this directory. `core/doctor.sh` reports whether the
install has been done (`lease board on screen`).

## Versions

Tested with Claude Code 2.1.300 on macOS. Mods need Claude Code 2.1.287 or
later in the terminal. The mods API is early access and moves between
releases; `claude plugin validate mods/lease-board` says what this build reads
from the module, and `claude plugin test mods/lease-board` runs the tests under
`tests/`.

## Files

- `.claude-plugin/plugin.json` — the manifest
- `hooks/hooks.json` — names the hooks module
- `hooks/register.js` — the hooks module: a `session.start` hook that starts the
  2-second timer, and a `ui.render` hook on the band above the prompt
- `tests/lease-board.test.ts` — the tests `claude plugin test` runs
