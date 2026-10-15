# lease-board — the Daedalus lease board on screen

A Claude Code mod that draws the lease board in the band above the prompt in
every Daedalus window: this window's number, whether it holds the pen, and every
other window's state (live, quiet, stale, finished, released), its changed-file
count, its alias and its note. It refreshes every 2 seconds.

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
