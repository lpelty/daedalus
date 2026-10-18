// Daedalus service status (service-status spec, 2026-10-17): a one-word summary at the right end of the band's
// first row, the details in a pane (`details`, or /services), a toast when a service goes down or comes back, and
// a status line under the prompt while anything is down.
//
// A reader. Once at start (not awaited) and every 60 s it runs `python3 core/status.py --json` in the Daedalus
// home, and reads the session's tool list for the memory tools (the hindsight MCP server). It never writes a file,
// never restarts or fixes a service, and never throws: a failure is one word in the band and a line in the pane.
//
// It shares the band. Its band hook draws one row, the next mod's tree on the flexible left and the summary on the
// right, and lease-board puts the next mod's tree at the right end of its own first row, so whichever of the two
// Claude Code runs first, the summary lands at the right end of the board's first row (spec §4; README).
//
// Each mods API call below carries the sentence from the docs it leans on, fetched 2026-10-17 from
// code.claude.com/docs/en/plugins/mods/{interface,api,events,test} and the types Claude Code 2.1.302 writes for a
// mod (`.claude-plugin/types/claude-code/index.d.ts`, "the types"). The static-analysis rules lease-board keeps:
// each call is written in full as `$.<namespace>.<method>`; `$` is passed only to functions declared at the top
// level of this file; event names are string literals; nothing is imported.

const REFRESH_MS = 60000 // spec §4: every 60 s, plus once at start
const GRACE_MS = 15000 // spec §3: MCP servers connect after the session starts; a missing tool counts after this
const TIMEOUT_MS = 5000 // status.py's budget is 2 s (spec §3); this is the most a check may hold a read
const STATUS_PY = 'core/status.py'
const PANE = 'services' // the pane's id: "1-64 of letters, digits, `_` and `-`" (the types, PaneOpenArgs.id)
const TOOLS_PREFIX = 'mcp__hindsight__' // "A tool's server is only in its name: `mcp__<server>__<tool>`" (Atlas's band)
const BUTTON = '[ details ]' // the terminal draws a Button as `[ label ]` (reference: "A Button is `[ label ]` on the terminal")
const SHARE = 0.4 // the most of the band's width the summary and its button may take beside the board's first line
const TOOLS_HELP = "Memory tools aren't connected. Type /mcp and reconnect hindsight."
// A toast names a service by its plain name, capitalised; the memory server by its own name.
const TITLES = { hindsight: 'Hindsight' }

let home = null // the Daedalus home, absolute, or null when none was found
let searched = '' // where findHome started looking, for the pane's failure line
let snapshot = null // null before the first check; { kind: 'ok', services } or { kind: 'failed', reason }
let checkedAt = 0 // when the last check finished, milliseconds since the epoch
let tools = 'unknown' // 'connected', 'not-connected', or 'unknown' (inside the grace, or the list unread)
let pastGrace = false
let inflight = false // one check at a time: a tick while status.py still runs starts no second one
let prev = null // stem -> 'up' | 'down' as of the last check; null until the first check (no toast for it)
let statusText = null // what the status line was last set to; null before the first check

function parentOf(path) {
  const s = path.length > 1 ? path.replace(/\/+$/, '') : path
  const i = s.lastIndexOf('/')
  if (i < 0) return ''
  return i === 0 ? '/' : s.slice(0, i)
}

function pad2(n) {
  return (n < 10 ? '0' : '') + n
}

function clockText(ms) {
  const d = new Date(ms)
  return pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds())
}

function firstLine(text) {
  const line = String(text || '')
    .split('\n')
    .find((l) => l.trim())
  return (line || '').trim().replace(/^daedalus: /, '')
}

// status.py's object (spec §3), checked field by field: anything else is a failed check, never a guess.
function parseStatus(stdout) {
  let data
  try {
    data = JSON.parse(stdout)
  } catch (err) {
    return { kind: 'failed', reason: 'core/status.py printed no JSON' }
  }
  const list = data && Array.isArray(data.services) ? data.services : null
  if (!list || list.length === 0) return { kind: 'failed', reason: 'core/status.py printed no services' }
  const services = []
  for (const s of list) {
    if (!s || typeof s.stem !== 'string' || typeof s.name !== 'string') return { kind: 'failed', reason: 'core/status.py printed a row without a name' }
    if (s.state !== 'up' && s.state !== 'down' && s.state !== 'not-set-up') return { kind: 'failed', reason: 'core/status.py printed a state it does not have' }
    services.push({ stem: s.stem, name: s.name, state: s.state, detail: typeof s.detail === 'string' ? s.detail : '' })
  }
  return { kind: 'ok', services }
}

// The memory tools' row, read in the mod (spec §3): only beside a memory server status.py reports, not-set-up
// where it is, and 'checking' (counted neither way) until the grace has passed.
function toolsRow(services) {
  const server = services.find((s) => s.stem === 'hindsight')
  if (!server) return null
  const row = { stem: 'memory-tools', name: 'memory tools' }
  if (server.state === 'not-set-up') return Object.assign(row, { state: 'not-set-up', detail: server.detail })
  if (tools === 'connected') return Object.assign(row, { state: 'up', detail: 'connected to this session' })
  if (tools === 'not-connected') return Object.assign(row, { state: 'down', detail: 'not connected to this session' })
  return Object.assign(row, { state: 'checking', detail: 'checking…' })
}

// Every row the band, the pane, the toasts and the status line read: status.py's, then the memory tools'.
function rowsOf(snap) {
  if (!snap || snap.kind !== 'ok') return []
  const t = toolsRow(snap.services)
  return t ? snap.services.concat([t]) : snap.services.slice()
}

function downOf(snap) {
  return rowsOf(snap).filter((r) => r.state === 'down')
}

function countWords(n) {
  return n + (n === 1 ? ' service' : ' services') + ' down'
}

// The band's words (spec §2): `services ok`, what is down by name, or the count when the names do not fit in
// the band's share beside the board's first line; `services: checking…` before the first check.
function summary(snap, columns) {
  if (!snap) return { text: 'services: checking…', tone: 'quiet' }
  if (snap.kind === 'failed') return { text: "services: couldn't check", tone: 'warn' }
  const down = downOf(snap)
  if (down.length === 0) return { text: 'services ok', tone: 'ok' }
  const named = down.map((r) => r.stem).join(', ') + ' down'
  const room = typeof columns === 'number' && columns > 0 ? Math.floor(columns * SHARE) : Infinity
  if (named.length + 1 + BUTTON.length <= room) return { text: named, tone: 'warn' }
  return { text: countWords(down.length), tone: 'warn' }
}

// The status line's text while anything is down, or undefined (spec §2): the names, or the count past three.
function statusLineOf(snap) {
  const down = downOf(snap)
  if (down.length === 0) return undefined
  const what = down.length <= 3 ? down.map((r) => r.stem).join(', ') + ' down' : countWords(down.length)
  return '⚠ service-status: ' + what + ' — /services for details'
}

function titleOf(r) {
  if (TITLES[r.stem]) return TITLES[r.stem]
  return r.name.charAt(0).toUpperCase() + r.name.slice(1)
}

// After a check: a toast for each service that went from up to down or back (never at the first check, never
// while a state holds), and the status line set or cleared when its text changed. A failed check changes neither.
function settle($) {
  if (!snapshot || snapshot.kind !== 'ok') return
  const now = {}
  for (const r of rowsOf(snapshot)) if (r.state === 'up' || r.state === 'down') now[r.stem] = r
  if (prev) {
    for (const stem of Object.keys(now)) {
      const was = prev[stem]
      const is = now[stem].state
      // "$.ui.toast(text) ... Shows `text` for a few seconds under the plugin's name" (the types)
      if (was === 'up' && is === 'down') $.ui.toast(titleOf(now[stem]) + ' went down')
      if (was === 'down' && is === 'up') $.ui.toast(titleOf(now[stem]) + ' is back')
    }
  }
  prev = {}
  for (const stem of Object.keys(now)) prev[stem] = now[stem].state
  const text = statusLineOf(snapshot)
  const key = text === undefined ? '' : text
  if (statusText === null || statusText !== key) {
    // "Pins `text` as this plugin's status line under the prompt ... One per plugin; `undefined` removes it."
    // (the types, $.ui.status). The first check always says it, so a line a reload left standing is cleared.
    $.ui.status(text)
    statusText = key
  }
}

// Where the Daedalus home is: the home above the session's cwd first, the one above the plugin directory as the
// fallback — lease-board's rule (lease-board spec §4.5), so the two mods read the same home.
async function findHome($) {
  // "Returns the directory the session runs in, absolute." (the types, $.session.cwd); "Returns whether the path
  // exists" (the types, $.fs.exists). Reads only.
  let dir = String(await $.session.cwd())
  searched = dir
  for (let i = 0; i < 64 && dir; i += 1) {
    if ((await $.fs.exists(dir + '/' + STATUS_PY)) && (await $.fs.exists(dir + '/VERSION'))) return dir
    const up = parentOf(dir)
    if (!up || up === dir) break
    dir = up
  }
  // "$.plugin | name, root: this plugin's name and directory" (reference): in place, <home>/mods/service-status
  const root = typeof $.plugin.root === 'string' ? $.plugin.root : ''
  const above = root ? parentOf(parentOf(root)) : ''
  return above && (await $.fs.exists(above + '/' + STATUS_PY)) ? above : null
}

// The memory tools: "Returns the tools the model can call now, built-in and MCP alike" (the types, $.tool.list);
// `mcp` is "True for an MCP server's tool" (the types, ToolInfo). Inside the grace a missing tool is no news;
// a list that cannot be read is no news either, and is logged.
async function checkTools($) {
  try {
    const list = await $.tool.list()
    if (list.some((t) => t && t.mcp && String(t.name).startsWith(TOOLS_PREFIX))) tools = 'connected'
    else if (pastGrace) tools = 'not-connected'
  } catch (err) {
    $.ui.log('service-status: the tool list did not read: ' + firstLine(err && err.message ? err.message : String(err)), { to: 'debug' })
  }
}

// One check: status.py, then the tool list, then the toasts and the status line, then a redraw. Never throws.
async function refresh($) {
  if (inflight) return
  inflight = true
  try {
    if (!home) {
      snapshot = { kind: 'failed', reason: STATUS_PY + ' not found above ' + searched }
    } else {
      try {
        // "$.process.run: takes an argument list and uses no shell. It resolves to { exitCode, stdout, stderr }
        // whatever the exit code. It rejects if the program can't start or is still running at the timeout"
        // (api page); init "{ cwd, env, stdin, timeoutMs }" (the types).
        const r = await $.process.run(['python3', STATUS_PY, '--json'], { cwd: home, timeoutMs: TIMEOUT_MS })
        snapshot = r.exitCode === 0 ? parseStatus(r.stdout) : { kind: 'failed', reason: firstLine(r.stderr) || 'core/status.py exited ' + r.exitCode }
      } catch (err) {
        snapshot = { kind: 'failed', reason: firstLine(err && err.message ? err.message : String(err)) || 'core/status.py did not run' }
      }
    }
    await checkTools($)
    // "Resolves milliseconds since the epoch, now." (the types, $.clock.now)
    checkedAt = await $.clock.now()
    settle($)
  } finally {
    inflight = false
  }
  // "To have your sites drawn again after your own data changes, call $.ui.invalidate('ui.render')" (interface page)
  $.ui.invalidate('ui.render')
}

// The grace check reads the tool list alone; status.py keeps its cadence.
async function graceCheck($) {
  pastGrace = true
  await checkTools($)
  settle($)
  $.ui.invalidate('ui.render')
}

async function openPane($) {
  // "Opens a pane, a framed region the surface places and this plugin draws by hooking `ui.render` for
  // `{ component: "Pane" }`" ... "Asked, the person's command, prompt or press behind it (not `focus`), it is
  // placed at any width" (the types, $.ui.open). `closeOnEscape`: "the key that hands it back (Escape) also
  // closes it as the person's close does" (the types, PaneOpenArgs).
  const opened = await $.ui.open({ id: PANE, title: 'Services', focus: true, closeOnEscape: true })
  if (opened && opened.isPlaced === false) $.ui.log('service-status: the pane is open but not drawn: ' + opened.reason, { to: 'debug' })
}

// The pane's rows (spec §2): plain name, what it is (the stem), state, one detail; then the help line for the
// memory tools when their server is up, and the time of the last check. Not-set-up rows are dim.
function paneLines(Text, Box) {
  const out = []
  const line = (key, props, text) => Box({ key, children: [Text(Object.assign({ wrap: 'truncate-end' }, props, { children: [text] }))] })
  if (!snapshot) return [line('row-checking', { dimColor: true }, 'The first check is running.')]
  if (snapshot.kind === 'failed') {
    out.push(line('row-failed', { color: 'warning' }, "Couldn't check: " + snapshot.reason))
  } else {
    for (const r of rowsOf(snapshot)) {
      const state = r.state === 'not-set-up' ? 'not set up' : r.state
      const text = r.name.padEnd(16) + r.stem.padEnd(14) + state.padEnd(12) + r.detail
      const props = r.state === 'down' ? { color: 'warning' } : r.state === 'up' ? {} : { dimColor: true }
      out.push(line('row-' + r.stem, props, text))
    }
    const server = snapshot.services.find((s) => s.stem === 'hindsight')
    if (tools === 'not-connected' && server && server.state === 'up') {
      // indented by layout, so a wrapped line keeps the indent (Atlas's band)
      out.push(Box({ key: 'tools-help', paddingLeft: 2, children: [Text({ children: [TOOLS_HELP] })] }))
    }
  }
  out.push(line('checked', { dimColor: true }, 'checked at ' + clockText(checkedAt)))
  return out
}

// "When the mod loads, Claude Code calls the register function the file exports and passes it a function named
// on." (create page)
export function register(on) {
  // "Once for each loaded mod, before the first prompt, and again after a reload of that mod." (reference,
  // session.start). "Work that outlives one event ... runs on a timer you start from session.start." (api page)
  on('session.start', async ($, e, next) => {
    // "isInteractive: Whether a person is at the prompt: true under the REPL, false for a -p run or the SDK."
    // (the types). A headless run draws no band: no command, no timer, no python3 (spec §4).
    if (!e.isInteractive) return next(e)
    // "Register each event once per matcher." (events page) — the one session.start hook does it all.
    // "Serve it with a `command.run` hook on `{ command: "<name>" }`" (the types, $.command.register)
    try {
      await $.command.register({ name: 'services', description: "Show whether Daedalus's services are running, in a pane" })
    } catch (err) {
      $.ui.log('service-status: /services was not registered: ' + firstLine(err && err.message ? err.message : String(err)), { to: 'debug' })
    }
    home = await findHome($)
    $.ui.log('service-status: home ' + (home || 'not found'), { to: 'debug' })
    // Not awaited: "Claude Code waits for that hook before the first prompt" (api page), and the first check
    // must not hold it (spec §4).
    refresh($)
    // "$.clock.every and $.clock.after take the place of setInterval and setTimeout, with the delay in
    // milliseconds first ... Each returns a timer with a cancel() method." "Timers stop when the module reloads."
    // (api page)
    $.clock.after(GRACE_MS, () => graceCheck($))
    // every periodic check is past the grace too, so a lost grace timer only delays the warning to the first one
    $.clock.every(REFRESH_MS, () => {
      pastGrace = true
      refresh($)
    })
    return next(e)
  })

  // "A hook's own answer without `next` runs no command: its `text` is shown as the command's output"; `text` is
  // "undefined when the command showed nothing as text (a panel ...)" (the types, CommandRunResult).
  on('command.run', { command: 'services' }, async ($) => {
    await openPane($)
    if (!inflight) refresh($)
    return {}
  })

  // "The band is a strip directly above the prompt input. It's always there, and every mod shares it. ... A tree
  // replaces what the mods after yours draw there. To keep theirs, put the result of await next(e) among the
  // children of a Box in your tree." (interface page)
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // "hasSurvey: True while a survey holds the band; a hook yields to it." (the types)
    if (e.props.hasSurvey) return next(e)
    const { Box, Text, Button } = $.ui.resolve(e)
    // "At these sites, next(e) returns a reference to Claude Code's drawing, { type: 'engine', ref }, unless a mod
    // that runs after yours returned a tree of its own" (interface page). Either way it takes the flexible left of
    // the row, in a Box with no width: the engine refuses its node under a Box that has one (lease-board, 2.1.300).
    const theirs = await next(e)
    const s = summary(snapshot, e.props.bodyColumns)
    const color = s.tone === 'ok' ? 'success' : s.tone === 'warn' ? 'warning' : undefined
    const words = Text({ wrap: 'truncate-end', dimColor: s.tone === 'quiet', color, children: [s.text] })
    // "Buttons ... keep their handlers in the plugin and raise `ui.press`"; "a Button's `hotkey` (one digit or
    // lowercase letter) presses it while its site holds the keyboard, the band after ctrl+x tab or a click"
    // (reference)
    const details = Button({ key: 'details', label: 'details', hotkey: 'd', onPress: () => openPane($) })
    const left = Box({ key: 'theirs', flexDirection: 'row', flexGrow: 1, flexShrink: 1, children: theirs && typeof theirs === 'object' ? [theirs] : [] })
    const right = Box({ key: 'summary', flexDirection: 'row', flexShrink: 0, children: [words, ' ', details] })
    return Box({ flexDirection: 'row', children: [left, right] })
  })

  // "$.ui.open({ id, title }), drawn by a `ui.render` hook on `{ component: 'Pane', requestId: id }`" (skill)
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    return Box({ flexDirection: 'column', children: paneLines(Text, Box) })
  })
}
