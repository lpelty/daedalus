// The Daedalus lease board, drawn in the band above the prompt (lease-board spec, 2026-10-11, §4).
//
// A reader. Every 2 s it runs `python3 core/leaselib.py board-json --session <id>` in the Daedalus
// home and draws one line per window: this window first and in bold, the window that holds the pen
// marked, each window's state in its color. It never writes a file, never runs git or lease.sh,
// never takes a lock, and never throws: a failure costs one dim line, and the last good board stays.
//
// Each mods API call below carries the sentence from the docs it leans on, fetched 2026-10-11 from
// code.claude.com/docs/en/plugins/mods/{api,interface,reference,create} and read again 2026-10-15
// (unchanged); "the types" is the claude-code.d.ts the engine writes for this build (2.1.300). The static-analysis rules (create
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
let sid = '' // this session's id: the one a lease's session_id names; read again on every tick (/resume changes it)
let searched = '' // where findHome started looking, for the failure line
let inflight = false // one read at a time: a tick while board-json still runs starts no second one
let loggedTheirs = false // the first render logs what next(e) resolved to, for the human step (spec §9 Q3)

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
    case 'swept-waiting': {
      // a swept number still holding unpromoted work (board-json since 2026-10-19): new windows skip it
      const n = typeof w.waiting_count === 'number' ? w.waiting_count : 0
      return 'swept — ' + n + ' unpromoted commit' + (n === 1 ? '' : 's') + ' waiting — say "this is window ' + w.nn + '" to continue it'
    }
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
    case 'swept-waiting':
      return { color: 'warning' }
    default:
      return {}
  }
}

function lineText(w) {
  const parts = ['window ' + w.nn]
  if (w.is_this) parts.push('this window')
  if (w.is_prime) parts.push('holds the pen')
  parts.push(stateWords(w))
  if (w.state === 'swept-waiting') return parts.join(' · ') // no lease: nothing changed, no alias, no peer
  // board-json's task (v0.12.3) is never drawn here: it is for the windows, on the board they read, and a long one
  // pushed the counts and the alias off the band's right edge (operator's call, 2026-10-19)
  parts.push((typeof w.changed_count === 'number' ? w.changed_count : 0) + ' changed')
  if (w.alias) parts.push(String(w.alias))
  // a derived name looks like a number and is not one (spec §4.1): named only when it differs
  if (w.peer_name && w.peer_name !== 'daedalus-' + w.nn) parts.push('peer name ' + w.peer_name)
  if (w.note) parts.push(String(w.note))
  return parts.join(' · ')
}

// The AMI line (frame-jack spec §9.2), from board-json's `ami` key: the switch's word and this
// session's counts. Plain words; a slash command only as the remedy. `now` is the clock of the read
// (boardAt), so the line stays pure over the board.
function count(n) {
  return typeof n === 'number' ? n : 0
}

function amiText(a, nowMs) {
  switch (a.state) {
    case 'on': {
      // a question switched off (board-json's `questions`) reads as off, never as a zero count that looks
      // measured; an older board-json without the key keeps the counts
      const q = a.questions && typeof a.questions === 'object' ? a.questions : {}
      const parts = [
        'AMI on',
        'shadow (logs, never acts)',
        count(a.asked) + ' asked',
        q.destructive === false && count(a.would_ask) === 0
          ? 'destructive question off'
          : 'would have asked you ' + count(a.would_ask) + (count(a.would_ask) === 1 ? ' time' : ' times'),
        q.suite === false && count(a.would_shorten) === 0
          ? 'suite question off'
          : 'would have shortened ' + count(a.would_shorten),
      ]
      if (typeof a.median_ms === 'number') parts.push(a.median_ms + ' ms')
      if (count(a.overrides) > 0) parts.push(a.overrides + ' overruled')
      return parts.join(' · ')
    }
    case 'off':
      return 'AMI off'
    case 'down':
      return 'AMI on but the daemon is down — /frame-jack on'
    case 'supervisor gone':
      return 'AMI on but its supervisor is gone — /frame-jack off, then on'
    case 'battery':
      return 'AMI paused on battery'
    case 'starting': {
      const secs = typeof a.since_epoch === 'number' ? Math.max(0, Math.round(nowMs / 1000 - a.since_epoch)) : null
      return secs === null ? 'AMI starting' : 'AMI starting (' + secs + ' s)'
    }
    case 'tripped':
      return typeof a.retry_epoch === 'number'
        ? 'AMI tripped (slow or wedged) — retrying at ' + clockText(a.retry_epoch * 1000)
        : 'AMI tripped (slow or wedged)'
    case 'unconfigured':
      return 'AMI on but not configured — /frame-jack status'
    default:
      return 'AMI ' + String(a.state)
  }
}

// Dim when off, plain when on, the warning colour for everything that needs the operator.
function amiStyle(a) {
  if (a.state === 'off') return { dimColor: true }
  if (a.state === 'on') return { color: 'text' }
  return { color: 'warning' }
}

// The AMI's Text, or null: omitted when board-json has no `ami` key (an older board-json) or the
// deployment never switched frame-jack on (`absent`), so it never takes a row for a switch that is
// not there.
function amiLine(Text, a, nowMs) {
  if (!a || typeof a !== 'object' || !a.state || a.state === 'absent') return null
  return Text(Object.assign({ wrap: 'truncate-end' }, amiStyle(a), { children: [amiText(a, nowMs)] }))
}

const FIRST_SHARE = 0.6 // the least of the band's width the first line may be squeezed to beside the next mod's tree

// Pure: the props of the Box that holds the band's first line, with its floor (see the band hook).
function firstLineBox(line, columns) {
  const props = { flexDirection: 'row', flexGrow: 1, flexShrink: 1, children: [line] }
  const kids = line && line.props && Array.isArray(line.props.children) ? line.props.children : line && line.children
  const text = Array.isArray(kids) ? kids.filter((k) => typeof k === 'string').join('') : ''
  if (typeof columns === 'number' && columns > 0 && text.length > 0) props.minWidth = Math.min(text.length, Math.floor(columns * FIRST_SHARE))
  return props
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
  // the AMI line goes after the window lines and before the dim tail, and counts in the room
  const ami = amiLine(Text, board.ami, boardAt)
  if (windows.length === 0) return [dim('no windows open in this Daedalus home')].concat(ami ? [ami] : [], tail)
  const head = []
  if (!board.this_window) head.push(dim('this window holds no number'))
  const room = Math.max(1, maxRows - head.length - tail.length - (ami ? 1 : 0))
  let shown = windows
  let more = null
  if (windows.length > room) {
    // room for one row: this window's own line, the one that matters most, and no count in its place
    // (review 2026-10-11, findings 15 and 26)
    if (room <= 1) {
      shown = windows.slice(0, 1)
    } else {
      shown = windows.slice(0, room - 1)
      more = dim('+' + (windows.length - shown.length) + ' more windows')
    }
  }
  const rows = shown.map((w) => {
    const p = Object.assign({ wrap: 'truncate-end' }, styleFor(w.state))
    if (w.is_this) p.bold = true
    p.children = [lineText(w)]
    return Text(p)
  })
  return head.concat(rows, more ? [more] : [], ami ? [ami] : [], tail)
}

// Where the Daedalus home is (spec §4.5, order changed at the review of 2026-10-11, findings 12 and 18):
// the home above the session's cwd first, the one above the plugin directory as the fallback. The
// marketplace name `daedalus-mods` is one record per machine (plugin loading reference: "There is one
// known_marketplaces.json per user"), so with two Daedalus checkouts on one machine the plugin loads
// from whichever checkout the record names — the plugin directory can be the OTHER checkout's, while
// the cwd is the home the window was opened in. When both are found and differ, a debug line says so.
async function findHome($) {
  // "Returns the directory the session runs in, absolute." (the types, $.session.cwd). Windows start
  // in the Daedalus home, so this is usually one exists call; the walk upward is the safety net.
  // "$.fs | read(path), write(path, text), exists(path), stat(path), and list(path) work on files and
  // directories" (api page); "Returns whether the path exists" (the types). Reads only.
  let dir = String(await $.session.cwd())
  searched = dir
  let fromCwd = null
  for (let i = 0; i < 64 && dir; i += 1) {
    if ((await $.fs.exists(dir + '/' + LEASELIB)) && (await $.fs.exists(dir + '/VERSION'))) {
      fromCwd = dir
      break
    }
    const up = parentOf(dir)
    if (!up || up === dir) break
    dir = up
  }
  // "$.plugin | name, root: this plugin's name and directory" (reference); "The plugin's directory
  // (the one holding plugin.json), absolute." (the types; a string under `claude plugin test` too,
  // probed 2026-10-11). In place, that is <home>/mods/lease-board.
  const root = typeof $.plugin.root === 'string' ? $.plugin.root : ''
  const above = root ? parentOf(parentOf(root)) : ''
  const fromPlugin = above && (await $.fs.exists(above + '/' + LEASELIB)) ? above : null
  if (fromCwd && fromPlugin && fromCwd !== fromPlugin) {
    $.ui.log('lease-board: the Daedalus home above the session cwd (' + fromCwd + ') is not the one above the plugin directory (' + fromPlugin + ', mods/lease-board): this machine\'s daedalus-mods marketplace names another checkout; the board shows ' + fromCwd, { to: 'debug' })
  }
  return fromCwd || fromPlugin
}

// One read of the board. Never throws: the last good board stays and `failure` says why. One at a
// time: a tick that finds a read still running (python3 waiting, up to the 5 s timeout) does nothing,
// so reads never pile up and an older, slower result never lands over a newer one (findings 11, 25).
async function refresh($) {
  if (inflight) return
  inflight = true
  try {
    // "Returns the session's id (the transcript file's name)." (the types, $.session.id): read on
    // every tick, not once at session.start — /resume moves the session to another transcript and
    // fires no session.start ("Not after /clear, /resume, or /branch", reference), so a cached id
    // would be the dead one from then on (finding 9). The lease's session_id follows the same id.
    try {
      sid = String(await $.session.id())
    } catch (err) {
      // keep the last id
    }
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
  } finally {
    inflight = false
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
    // "isInteractive: Whether a person is at the prompt: true under the REPL, false for a -p run or
    // the SDK." (the types, SessionStartInput). A headless run — a direct call, a clone — draws no
    // band, so it gets no timer and no python3 every 2 s for its whole life (finding 10).
    if (!e.isInteractive) return next(e)
    try {
      // "Returns the session's id (the transcript file's name)." (the types, $.session.id): the
      // same id the hooks' payload carries, which the lease's session_id stores. Read again at
      // every refresh (see there).
      sid = String(await $.session.id())
    } catch (err) {
      sid = ''
    }
    home = await findHome($)
    // "$.ui.log(text) ... or with { to: "debug" } to the debug log alone." (the types): the human
    // step reads which home this build found, in `claude --debug`.
    $.ui.log('lease-board: home ' + (home || 'not found') + '; session ' + (sid || '(none)'), { to: 'debug' })
    // Not awaited: "Claude Code waits for that hook before the first prompt" (api page), and a
    // board-json waiting on the lease lock would hold the operator's first prompt for up to the
    // 5 s timeout (finding 13). The band fills when the read lands, within one tick either way.
    if (home) refresh($)
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
    if (!loggedTheirs) {
      // what next(e) resolves to on an empty band is undocumented (spec §9 Q3): said once, for `claude --debug`
      loggedTheirs = true
      $.ui.log('lease-board: next(e) resolved to ' + (theirs === null ? 'null' : typeof theirs) + ' on the band', { to: 'debug' })
    }
    const lines = linesFor(Text, e.props)
    // What next(e) resolves to on the band is the engine's own node: "At these sites, next(e) returns a
    // reference to Claude Code's drawing, { type: 'engine', ref }, unless a mod that runs after yours
    // returned a tree of its own" (interface page); "The component core draws itself, with the props held
    // under `ref`. type: 'engine'; ref: number" (the types). It is kept, when it is an object, at the RIGHT
    // END OF THE FIRST ROW (service-status spec §4), beside this mod's first line in a row Box that carries
    // no width — never as a child of a Box with a width. On 2.1.300 that shape was refused on every render
    // and the band stayed empty: "ui.render (AbovePrompt): a hook returned a tree that does not validate
    // (engine node under a Box with prop "width"); drawing the engine's own" (claude --debug, 2026-10-15).
    // The types write no such rule — their one composition rule is "a Box holds elements and strings (core
    // wraps each string in a Text); a Text holds strings and inline elements, never an engine node"
    // (StyledElement.children) — so the engine's refusal reason is the rule, and the page's own example is an
    // unsized Box: "You can return the reference as it is, or place it in a Box beside elements of your own".
    // Why the first row: the band is one chain ("The first mod is outermost: it sees the event before the
    // others and the result after them", events page, "The order mods run in"), and Claude Code orders two
    // mods a person installs only by `dependencies` ("Among the mods you install, a mod runs before the mods
    // it lists under `dependencies`"). service-status draws `[ next(e) | summary ]` in one row; with the next
    // mod's tree here, its summary lands at the right end of this first line whichever of the two runs first.
    // The first line grows and shrinks beside it (flexGrow/flexShrink, no width) and truncates at its end.
    // A floor under the first line: on 2.1.302 a growing, shrinking line beside the next mod's tree was cut at about
    // half the band with the rest left empty (the operator's look, 2026-10-18). minWidth (the types, Box) holds it at its
    // full length, up to FIRST_SHARE of the band; the summary beside it takes at most the other 40%
    // (service-status's SHARE), so the two fit and the line is cut only on a band too narrow for both.
    const first = Box(firstLineBox(lines[0], e.props.bodyColumns))
    const top = Box({ flexDirection: 'row', children: theirs && typeof theirs === 'object' ? [first, theirs] : [first] })
    const children = [top]
    if (lines.length > 1) {
      // The other lines, in a Box of their own sized to the band: "bodyColumns: Cells the band's tree is
      // laid out in ... size a table to it rather than to viewport.columns." (the types)
      const rest = { flexDirection: 'column', children: lines.slice(1) }
      if (typeof e.props.bodyColumns === 'number' && e.props.bodyColumns > 0) rest.width = e.props.bodyColumns
      children.push(Box(rest))
    }
    return Box({ flexDirection: 'column', children })
  })
}
