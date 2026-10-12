// The Daedalus lease board, drawn in the band above the prompt (lease-board spec, 2026-10-11, §4).
//
// A reader. Every 2 s it runs `python3 core/leaselib.py board-json --session <id>` in the Daedalus
// home and draws one line per window: this window first and in bold, the window that holds the pen
// marked, each window's state in its color. It never writes a file, never runs git or lease.sh,
// never takes a lock, and never throws: a failure costs one dim line, and the last good board stays.
//
// Each mods API call below carries the sentence from the docs it leans on, fetched 2026-10-11 from
// code.claude.com/docs/en/plugins/mods/{api,interface,reference,create}; "the types" is the
// claude-code.d.ts the engine writes for this build (2.1.295). The static-analysis rules (create
// page, "Check what Claude Code reads from your mod"): each call is written in full as
// `$.<namespace>.<method>`; `$` is passed only to functions declared at the top level of this file
// (refresh, findHome); event names are string literals; nothing is imported.

const REFRESH_MS = 2000 // the cadence asked for (spec §9 Q2): a constant, not userConfig, until someone asks
const TIMEOUT_MS = 5000 // twenty times board-json's budget for 40 windows (spec §3.3)
const LEASELIB = 'core/leaselib.py'

let board = null // the last good board-json object
let boardAt = 0 // when it was read, milliseconds since the epoch
let failure = null // why the last read failed, or null
let home = null // the Daedalus home, absolute, or null when none was found
let sid = '' // this session's id: the one a lease's session_id names
let searched = '' // where findHome started looking, for the failure line

function parentOf(path) {
  const s = path.length > 1 ? path.replace(/\/+$/, '') : path
  const i = s.lastIndexOf('/')
  if (i < 0) return ''
  return i === 0 ? '/' : s.slice(0, i)
}

function pad2(n) {
  return (n < 10 ? '0' : '') + n
}

// The clock time today, the date and time when older — as leaselib's _since() prints it.
function clockText(ms) {
  const d = new Date(ms)
  const now = new Date()
  const hhmm = pad2(d.getHours()) + ':' + pad2(d.getMinutes())
  const today = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  return today ? hhmm : d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' + hhmm
}

function firstLine(text) {
  const line = String(text || '')
    .split('\n')
    .find((l) => l.trim())
  return (line || '').trim().replace(/^daedalus: /, '')
}

// The state in plain words (spec §4.2).
function stateWords(w) {
  const seen = typeof w.last_seen_epoch === 'number' ? clockText(w.last_seen_epoch * 1000) : null
  switch (w.state) {
    case 'live':
      return 'live'
    case 'quiet':
      return seen ? 'quiet since ' + seen : 'quiet'
    case 'stale':
      return seen ? 'stale — no live session since ' + seen : 'stale — never seen'
    case 'finished':
      return 'finished — promote ' + w.nn + ' or release ' + w.nn
    case 'released':
      return 'released'
    default:
      return String(w.state)
  }
}

// Colors by state, as theme keys so the operator's theme applies ("A color is a theme key or a
// color such as 'red'", interface page; `Color = ThemeKey | string`, the types).
function styleFor(state) {
  switch (state) {
    case 'live':
      return { color: 'text' }
    case 'quiet':
      return { color: 'warning' }
    case 'stale':
      return { color: 'error' }
    case 'finished':
      return { color: 'suggestion' }
    case 'released':
      return { dimColor: true }
    default:
      return {}
  }
}

function lineText(w) {
  const parts = ['window ' + w.nn]
  if (w.is_this) parts.push('this window')
  if (w.is_prime) parts.push('holds the pen')
  parts.push(stateWords(w))
  parts.push((typeof w.changed_count === 'number' ? w.changed_count : 0) + ' changed')
  if (w.alias) parts.push(String(w.alias))
  // a derived name looks like a number and is not one (spec §4.1): named only when it differs
  if (w.peer_name && w.peer_name !== 'daedalus-' + w.nn) parts.push('peer name ' + w.peer_name)
  if (w.note) parts.push(String(w.note))
  return parts.join(' · ')
}

// Pure over board, failure and boardAt: the Text elements for the band, top to bottom.
// "Text ... Takes color, bold, dimColor, italic, and wrap. ... A wrap is 'wrap', 'truncate',
// 'truncate-start', 'truncate-middle', or 'truncate-end'." (interface page)
function linesFor(Text, props) {
  const dim = (s) => Text({ dimColor: true, wrap: 'truncate-end', children: [s] })
  const maxRows = typeof props.maxRows === 'number' && props.maxRows > 0 ? props.maxRows : 20
  if (!board) return [dim(failure ? 'board unavailable: ' + failure : 'the lease board is not read yet')]
  const windows = Array.isArray(board.windows) ? board.windows : []
  const tail = []
  if (failure) tail.push(dim('board unavailable: ' + failure + ' (showing the board as of ' + clockText(boardAt) + ')'))
  else if (board.error) tail.push(dim('one window is not shown: ' + String(board.error)))
  if (windows.length === 0) return [dim('no windows open in this Daedalus home')].concat(tail)
  const head = []
  if (!board.this_window) head.push(dim('this window holds no number'))
  const room = Math.max(1, maxRows - head.length - tail.length)
  let shown = windows
  let more = null
  if (windows.length > room) {
    shown = windows.slice(0, Math.max(0, room - 1))
    more = dim('+' + (windows.length - shown.length) + ' more windows')
  }
  const rows = shown.map((w) => {
    const p = Object.assign({ wrap: 'truncate-end' }, styleFor(w.state))
    if (w.is_this) p.bold = true
    p.children = [lineText(w)]
    return Text(p)
  })
  return head.concat(rows, more ? [more] : [], tail)
}

// Where the Daedalus home is (spec §4.5): above the plugin for an in-place load, else above the cwd.
async function findHome($) {
  // "$.plugin | name, root: this plugin's name and directory" (reference); "The plugin's directory
  // (the one holding plugin.json), absolute." (the types). In place, that is <home>/mods/lease-board.
  const root = typeof $.plugin.root === 'string' ? $.plugin.root : ''
  const above = root ? parentOf(parentOf(root)) : ''
  // "$.fs | read(path), write(path, text), exists(path), stat(path), and list(path) work on files and
  // directories" (api page); "Returns whether the path exists" (the types). Reads only.
  if (above && (await $.fs.exists(above + '/' + LEASELIB))) return above
  // "Returns the directory the session runs in, absolute." (the types, $.session.cwd). Windows start
  // in the Daedalus home, so this is usually one exists call; the walk upward is the safety net.
  let dir = String(await $.session.cwd())
  searched = dir
  for (let i = 0; i < 64 && dir; i += 1) {
    if ((await $.fs.exists(dir + '/' + LEASELIB)) && (await $.fs.exists(dir + '/VERSION'))) return dir
    const up = parentOf(dir)
    if (!up || up === dir) break
    dir = up
  }
  return null
}

// One read of the board. Never throws: the last good board stays and `failure` says why.
async function refresh($) {
  try {
    // "$.process.run: takes an argument list and uses no shell. It resolves to { exitCode, stdout,
    // stderr } whatever the exit code. It rejects if the program can't start or is still running at
    // the timeout, which is 30 seconds by default, so wrap it in try and catch." (api page);
    // init "{ cwd, env, stdin, timeoutMs } (cwd the session's by default; timeout 30 s by default,
    // ten minutes at most)" (the types). --session because a mod's child is not a Bash-tool child
    // and carries no CLAUDE_CODE_SESSION_ID (spec §3.1).
    const r = await $.process.run(['python3', LEASELIB, 'board-json', '--session', sid], { cwd: home, timeoutMs: TIMEOUT_MS })
    if (r.exitCode !== 0) throw new Error(firstLine(r.stderr) || 'board-json exited ' + r.exitCode)
    const parsed = JSON.parse(r.stdout)
    if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.windows)) throw new Error('board-json printed no board')
    board = parsed
    // "Resolves milliseconds since the epoch, now." (the types, $.clock.now)
    boardAt = await $.clock.now()
    failure = null
  } catch (err) {
    failure = firstLine(err && err.message ? err.message : String(err)) || 'board-json failed'
  }
  // "To have your sites drawn again after your own data changes, call $.ui.invalidate('ui.render')"
  // (interface page). Throttled by the engine: "10 a second, or 30 in the terminal" (reference, Limits).
  $.ui.invalidate('ui.render')
}

// "When the mod loads, Claude Code calls the register function the file exports and passes it a
// function named on." (create page)
export function register(on) {
  // "Once for each loaded mod, before the first prompt, and again after a reload of that mod. Not
  // after /clear, /resume, or /branch." (reference, session.start). "Work that outlives one event,
  // such as checking on something once a minute, runs on a timer you start from session.start." (api page)
  on('session.start', async ($, e, next) => {
    try {
      // "Returns the session's id (the transcript file's name)." (the types, $.session.id): the
      // same id the hooks' payload carries, which the lease's session_id stores.
      sid = String(await $.session.id())
    } catch (err) {
      sid = ''
    }
    home = await findHome($)
    // "$.ui.log(text) ... or with { to: "debug" } to the debug log alone." (the types): the human
    // step reads which home this build found, in `claude --debug`.
    $.ui.log('lease-board: home ' + (home || 'not found') + '; session ' + (sid || '(none)'), { to: 'debug' })
    if (home) await refresh($)
    else failure = LEASELIB + ' not found above ' + searched
    // "$.clock.every and $.clock.after take the place of setInterval and setTimeout, with the delay in
    // milliseconds first ... Each returns a timer with a cancel() method." (api page). "The timer's
    // callback runs outside any event, so it keeps running between turns and doesn't start one."
    // "Timers stop when the module reloads." (api page)
    $.clock.every(REFRESH_MS, () => {
      if (home) refresh($)
    })
    return next(e)
  })

  // "The band is a strip directly above the prompt input. It's always there, and every mod shares it.
  // Your hook returns a tree to show something in the band, or next(e) to show nothing. A tree
  // replaces what the mods after yours draw there. To keep theirs, put the result of await next(e)
  // among the children of a Box in your tree. To draw in the band, filter on
  // { component: 'AbovePrompt' }." (interface page)
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // "hasSurvey: True while a survey holds the band; a hook yields to it." (the types)
    if (e.props.hasSurvey) return next(e)
    // "To get the elements, call $.ui.resolve(e) in your hook, as in const { Box, Text, Button } =
    // $.ui.resolve(e)." (interface page)
    const { Box, Text } = $.ui.resolve(e)
    const theirs = await next(e)
    const lines = linesFor(Text, e.props)
    // what next resolves to on an empty band is undocumented (spec §9 Q3): kept when it is an object
    const children = theirs && typeof theirs === 'object' ? lines.concat([theirs]) : lines
    const box = { flexDirection: 'column', children }
    // "bodyColumns: Cells the band's tree is laid out in ... size a table to it rather than to
    // viewport.columns." (the types)
    if (typeof e.props.bodyColumns === 'number' && e.props.bodyColumns > 0) box.width = e.props.bodyColumns
    return Box(box)
  })
}
