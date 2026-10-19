# service-status — whether Daedalus's services are running

A Claude Code mod that puts a one-word summary of this deployment's services at
the right end of the band above the prompt, beside the lease board's first
line, with the details in a pane.

```
window 01 · this window · live · 3 changed              services ok  [ details ]
window 02 · quiet since 21:40 · 0 changed
```

- **The band:** `services ok` (green) when every checked service is up. When
  something is down it names it in the warning colour, `hindsight down`, or
  counts, `2 services down`, when the names do not fit beside the board. While
  the first check runs: `services: checking…` (dim). If `core/status.py` itself
  fails: `services: couldn't check`, and the pane says why. It never takes more
  than one row; the lease board keeps every other row.
- **The pane:** `details` (or `d` once the band has the keys, after ctrl+x tab),
  or `/services`, opens a pane titled `Services`: one row per service with its
  plain name, its stem, its state and one detail, and the time of the last
  check. A service this deployment never set up shows dim, as `not set up`, and
  never counts as down. Esc closes the pane. In a wide fullscreen terminal it
  docks at the right; otherwise it sits above the prompt (Claude Code's choice).
- **A toast** only when a service changes after the first check:
  `Hindsight went down`, `Hindsight is back`. Nothing at startup, nothing while
  a state holds.
- **The status line** under the prompt, while anything is down:
  `⚠ service-status: hindsight down — /services for details`. It is cleared
  when everything is back.

## What it checks

Once at start (not awaited, so the first prompt is never held) and every 60
seconds it runs `python3 core/status.py --json` in the Daedalus home: one fast
reader, under 2 seconds, that never runs git, a model or any program. Its
output has the shape another harness's status band already reads, so such a
band could read it unchanged:

```json
{"services": [{"stem": "hindsight", "name": "memory server", "state": "up", "detail": "127.0.0.1:8888 answered"}], "checked_at": "2026-10-17T21:40:00+00:00"}
```

| name | stem | up when | not set up when |
|---|---|---|---|
| memory server | `hindsight` | `GET <memory.api_url>/health` answers 2xx within 1 s | no `memory:` block, or the server is on another host (not checked) |
| memory capture | `capture` | the last capture is within 3 × `memory.capture_interval`, or no session was active since that capture missed | no `memory:` block |
| vault search | `vault-index` | `recall.store` is a readable directory | no `recall:` block |
| decider | `ami` | frame-jack is on and the daemon's port answers | no `ami:` block, or frame-jack never switched on, off, or paused on battery |
| code graph | `code-graph` | `context.graph` is executable | no `context:` block |
| memory tools | `memory-tools` | the session's tool list holds an `mcp__hindsight__` tool; or, with no hindsight MCP server configured, the memory server and capture are up | where the memory server is not set up |

Memory reaches Hindsight by either road: the hindsight MCP server's tools, or
the REST API that capture and recall use (PROP-027). `status.py --json` also
prints `"memory_mcp": {"configured": true | false | null, "detail"}` — whether
an MCP server named `hindsight` is configured for this home, read from Claude
Code's `.claude.json` (local and user scope) and the home's `.mcp.json`
(project scope); `null` when a file could not be read.

With one configured, the memory tools are checked in the mod, from the
session's tool list, with a 15-second grace after start while MCP servers
connect. When they are missing and the memory server is up, the pane says what
to do: `Memory tools aren't connected. Type /mcp and reconnect hindsight.`
With none configured, the row follows the memory server and capture, with no
grace and no `/mcp` line: there is no server to reconnect.

It reads only: it never restarts or fixes a service. `python3 core/status.py`
(without `--json`) prints the same rows for a person at a shell.

## Sharing the band with lease-board

The band is one chain shared by every mod: "A tree replaces what the mods after
yours draw there. To keep theirs, put the result of `await next(e)` among the
children of a Box in your tree." Claude Code orders two mods a person installs
only by `dependencies`, and neither mod depends on the other, so either may run
first. Both put the other's tree where it belongs:

- service-status draws one row: the next mod's tree on the flexible left, the
  summary and `[ details ]` on the right.
- lease-board puts the next mod's tree at the right end of its first line.

Either way round, the summary lands at the right end of the board's first row.
`tests/service-status.test.ts` and lease-board's own tests load the other mod's
shape both before and after this one and check the drawn rows. Either mod can
be switched off in `/plugin` without the other.

## Loading it

The mod ships inside the Daedalus repo, listed by the marketplace at
`mods/.claude-plugin/marketplace.json`, and is installed at local scope beside
lease-board. `core/setup.sh` installs it on a new deployment; the upgrade to
0.11.0 installs it for a deployment that already has lease-board. By hand, in
the Daedalus home (the first line is a no-op where lease-board's install
already added the marketplace):

```bash
claude plugin marketplace add ./mods --scope local
claude plugin install service-status@daedalus-mods --scope local
```

Then open a new terminal, or run `/reload-plugins` in a session that is already
open. `core/doctor.sh` reports whether it is installed (`service status on
screen`).

## Versions

Tested with Claude Code 2.1.302 on macOS. Mods need Claude Code 2.1.287 or later
in the terminal. `claude plugin validate mods/service-status` says what this
build reads from the module, and `claude plugin test mods/service-status` runs
the tests under `tests/`.

## Files

- `.claude-plugin/plugin.json` — the manifest
- `hooks/hooks.json` — names the hooks module
- `hooks/register.js` — the hooks module: a `session.start` hook that registers
  `/services` and starts the checks, the `/services` command, a `ui.render`
  hook on the band and one on the pane
- `tests/service-status.test.ts` — the tests `claude plugin test` runs
