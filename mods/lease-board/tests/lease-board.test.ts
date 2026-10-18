// Tests for the lease board above the prompt (lease-board spec §6.3). Run with
// `claude plugin test mods/lease-board` from the Daedalus home. No session, no
// python, no lease files: every call the mod makes is answered by a stub here.
// The test page: "A drawing test checks the tree your hook returns and whether
// it's valid for that app. It doesn't check how the app paints it."
import { expect, mock, test } from 'claude-code/testing'

// What board-json prints for five windows (spec §3.4), this window first.
const FIXTURE = {
  this_window: '03',
  prime_window: '01',
  windows: [
    { nn: '03', alias: null, state: 'quiet', changed_count: 0, peer_name: 'daedalus-03', is_prime: false, is_this: true, last_seen_epoch: 1577880000, note: null },
    { nn: '01', alias: null, state: 'live', changed_count: 0, peer_name: 'daedalus-01', is_prime: true, is_this: false, last_seen_epoch: 1791770388, note: null },
    { nn: '02', alias: 'electron', state: 'stale', changed_count: 14, peer_name: 'daedalus-07', is_prime: false, is_this: false, last_seen_epoch: 1791770000, note: 'EX-024 capture error-field fix' },
    { nn: '04', alias: null, state: 'finished', changed_count: 2, peer_name: null, is_prime: false, is_this: false, last_seen_epoch: null, note: null },
    { nn: '05', alias: null, state: 'released', changed_count: 0, peer_name: null, is_prime: false, is_this: false, last_seen_epoch: null, note: null },
  ],
  generated_epoch: 1791770400.1,
  // frame-jack spec §9.1: the AMI's word and this session's counts, every key always present
  ami: { state: 'on', mode: 'shadow', port_alive: true, device: 'mlx', asked: 212, would_ask: 7, would_shorten: 2, unanswered: 0, median_ms: 171, asks: 0, overrides: 0, since_epoch: 1792000000.0, retry_epoch: null } as Record<string, unknown>,
}

// What Claude Code passes to a ui.render hook for the band, apart from the app.
const BAND = {
  plugin: 'lease-board',
  component: 'AbovePrompt',
  requestId: 'above-prompt',
  viewport: { columns: 100, rows: 30 },
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 9 }, view: {} },
} as const

const THEIRS = { type: 'Text', props: {}, children: ['drawn by Claude Code'] }

function ok(board: unknown) {
  return { value: { exitCode: 0, stdout: JSON.stringify(board), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
}

type Run = { argv: readonly string[]; init: { cwd?: string; timeoutMs?: number } | undefined }

// Every stub the mod needs, registered before the test's first call on $ (the kit's rule:
// "Register every stub before the test's first call on $"). `answer` is read on each run,
// so a test can change what board-json says between ticks.
function stubs(on: any, answer: () => unknown, theirs: unknown = THEIRS) {
  const runs: Run[] = []
  const exists: string[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'sC' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('fs.exists', (_$: unknown, e: any) => {
    exists.push(String(e.path))
    return { value: true }
  })
  on('ui.log', () => ({ value: undefined }))
  on('process.run', (_$: unknown, e: any) => {
    runs.push({ argv: e.argv, init: e.init })
    return answer()
  })
  // "Stands for what Claude Code would draw at the site" (test page): what next(e) resolves to
  on('ui.render', () => theirs)
  const clock = mock.clock(on)
  return { runs, exists, clock }
}

async function start($: any) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
}

async function windowLines(ui: any): Promise<string[]> {
  const texts = await ui.findAll({ type: 'Text' })
  return texts.map((t: any) => String(t.text)).filter((t: string) => t.startsWith('window '))
}

test('draws this window first, in bold, and marks the window that holds the pen', async ($, on) => {
  stubs(on, () => ok(FIXTURE))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const lines = await windowLines(ui)
  expect(lines.length).toBe(5)
  expect(lines[0]).toMatch(/^window 03 · this window · quiet since \S+( \d\d:\d\d)? · 0 changed$/)
  expect(lines[1]).toBe('window 01 · holds the pen · live · 0 changed')
  expect(lines[2]).toMatch(/^window 02 · stale — no live session since \S+( \d\d:\d\d)? · 14 changed · electron · peer name daedalus-07 · EX-024 capture error-field fix$/)
  expect(lines[3]).toBe('window 04 · finished — promote 04 or release 04 · 2 changed')
  expect(lines[4]).toBe('window 05 · released · 0 changed')
  const mine = await ui.find({ type: 'Text', text: /^window 03 /i })
  expect(mine?.props.bold).toBe(true)
  expect(mine?.props.color).toBe('warning')
  expect((await ui.find({ type: 'Text', text: /^window 01 / }))?.props.color).toBe('text')
  expect((await ui.find({ type: 'Text', text: /^window 02 / }))?.props.color).toBe('error')
  expect((await ui.find({ type: 'Text', text: /^window 04 / }))?.props.color).toBe('suggestion')
  expect((await ui.find({ type: 'Text', text: /^window 05 / }))?.props.dimColor).toBe(true)
  // what the mods after this one drew is kept, as a child of the Box (interface page)
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /^board unavailable/ })).toBeUndefined()
})

test('runs board-json with this session id, in the Daedalus home, with a 5 s timeout, and no shell', async ($, on) => {
  const { runs, exists } = stubs(on, () => ok(FIXTURE))
  await start($)
  expect(runs.length).toBe(1)
  expect(runs[0].argv).toEqual(['python3', 'core/leaselib.py', 'board-json', '--session', 'sC'])
  expect(runs[0].init?.timeoutMs).toBe(5000)
  const home = runs[0].init?.cwd
  expect(typeof home).toBe('string')
  // the home is where core/leaselib.py was found (spec §4.5)
  expect(exists[0]).toBe(home + '/core/leaselib.py')
})

test('refreshes every 2000 ms and not sooner', async ($, on) => {
  const { runs, clock } = stubs(on, () => ok(FIXTURE))
  await start($)
  await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(runs.length).toBe(1)
  await clock.advance(2000)
  expect(runs.length).toBe(2)
  await clock.advance(1999)
  expect(runs.length).toBe(2)
  await clock.advance(1)
  expect(runs.length).toBe(3)
})

test('a failed read keeps the last good board and adds one dim line saying so', async ($, on) => {
  let mode: 'ok' | 'deny' = 'ok'
  const { clock } = stubs(on, () => (mode === 'ok' ? ok(FIXTURE) : { deny: 'boom' }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  mode = 'deny'
  await clock.advance(2000)
  expect((await windowLines(ui)).length).toBe(5)
  const line = await ui.find({ type: 'Text', text: /^board unavailable: .*boom.* \(showing the board as of .+\)$/ })
  expect(line).toBeDefined()
  expect(line?.props.dimColor).toBe(true)
})

test('a non-zero exit shows the first stderr sentence without its daedalus: prefix, and nothing else before a first good board', async ($, on) => {
  // any exit 1: the lease lock busy, state/leases/ unreadable (an unreadable lease FILE is exit 0 with an error key, tested below)
  stubs(on, () => ({ value: { exitCode: 1, stdout: '', stderr: 'daedalus: the lease lock is busy — a window is being made or swept; the board refreshes when it frees\n', isStdoutTruncated: false, isStderrTruncated: false } }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await windowLines(ui)).length).toBe(0)
  const line = await ui.find({ type: 'Text', text: 'board unavailable: the lease lock is busy — a window is being made or swept; the board refreshes when it frees' })
  expect(line).toBeDefined()
  expect(line?.props.dimColor).toBe(true)
})

test('output that is not JSON is a failure too', async ($, on) => {
  stubs(on, () => ({ value: { exitCode: 0, stdout: 'not json', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /^board unavailable: / })).toBeDefined()
})

test('no windows is one dim line', async ($, on) => {
  stubs(on, () => ok({ ...FIXTURE, this_window: null, prime_window: null, windows: [] }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const line = await ui.find({ type: 'Text', text: 'no windows open in this Daedalus home' })
  expect(line).toBeDefined()
  expect(line?.props.dimColor).toBe(true)
})

test('a session with no number is told so on the first line, then sees the windows', async ($, on) => {
  const windows = FIXTURE.windows.map((w) => ({ ...w, is_this: false }))
  stubs(on, () => ok({ ...FIXTURE, this_window: null, windows }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const texts = (await ui.findAll({ type: 'Text' })).map((t: any) => String(t.text))
  expect(texts[0]).toBe('this window holds no number')
  expect((await windowLines(ui)).length).toBe(5)
})

test('one unreadable lease file is one dim line while every readable window is still listed', async ($, on) => {
  stubs(on, () => ok({ ...FIXTURE, error: 'The lease file for window 06 cannot be read (not valid JSON)' }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await windowLines(ui)).length).toBe(5)
  expect(await ui.find({ type: 'Text', text: 'one window is not shown: The lease file for window 06 cannot be read (not valid JSON)' })).toBeDefined()
})

test('a survey holding the band is left alone: the hook returns next(e)', async ($, on) => {
  stubs(on, () => ok(FIXTURE))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, hasSurvey: true } })
  expect((await windowLines(ui)).length).toBe(0)
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeDefined()
})

test('every line truncates at the end of the band, sized to bodyColumns', async ($, on) => {
  const long = 'a note long enough to run off the end of a narrow band, ' + 'x'.repeat(200)
  const windows = FIXTURE.windows.map((w) => ({ ...w, note: long }))
  // a Box with no Text stands for the mods beneath, so every Text found is this mod's
  stubs(on, () => ok({ ...FIXTURE, windows }), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, bodyColumns: 24 } })
  const texts = await ui.findAll({ type: 'Text' })
  expect(texts.length).toBe(6) // five windows and the AMI line
  for (const t of texts) expect(t.props.wrap).toBe('truncate-end')
  // the width sits on this mod's own Box, one level down: the root Box holds the mods beneath beside it and
  // carries no width of its own (the engine's node may not sit under a Box with a width; the last test below)
  const root = await ui.drawn()
  expect(root.props.width).toBeUndefined()
  const sized = (root.children || []).filter((c: any) => c && c.type === 'Box' && c.props && c.props.width !== undefined)
  expect(sized.length).toBe(1)
  expect(sized[0].props.width).toBe(24)
  expect((await windowLines(ui)).length).toBe(5)
})

test('more windows than rows: maxRows - 1 lines, then "+N more windows"', async ($, on) => {
  stubs(on, () => ok(withAmi(undefined))) // no AMI line: the room is the window lines' alone
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, maxRows: 4, scroll: { offset: 0, bodyRows: 3 } } })
  const lines = await windowLines(ui)
  expect(lines.length).toBe(3)
  expect(lines[0]).toMatch(/^window 03 · this window/)
  expect(await ui.find({ type: 'Text', text: '+2 more windows' })).toBeDefined()
})

test('the Desktop app draws the same lines', async ($, on) => {
  stubs(on, () => ok(FIXTURE))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'desktop' })
  const lines = await windowLines(ui)
  expect(lines.length).toBe(5)
  expect(lines[0]).toMatch(/^window 03 · this window · quiet since /)
  expect(lines[1]).toBe('window 01 · holds the pen · live · 0 changed')
})

// --- the review of 2026-10-11 ---------------------------------------------------------------------------------

// The stamp the band prints for a read at that clock time: the mod's clockText, which prints the date too
// when the day is not today (the mock clock starts at the epoch).
function asOf(ms: number): string {
  const d = new Date(ms)
  const now = new Date()
  const p = (n: number) => (n < 10 ? '0' : '') + n
  const hhmm = p(d.getHours()) + ':' + p(d.getMinutes())
  const today = d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate()
  return today ? hhmm : d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + hhmm
}

test('the last good board stays through a failure and the failure line goes away once a read works again; the time shown is the last good read', async ($, on) => {
  let mode: 'ok' | 'deny' = 'ok'
  const { clock } = stubs(on, () => (mode === 'ok' ? ok(FIXTURE) : { deny: 'boom' }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  mode = 'deny'
  await clock.advance(2000)
  expect(await ui.find({ type: 'Text', text: new RegExp('^board unavailable: .*boom.* \\(showing the board as of ' + asOf(0) + '\\)$') })).toBeDefined()
  mode = 'ok'
  await clock.advance(120000) // good reads every 2 s; the last one at 122000 ms, two minutes after the first
  expect((await windowLines(ui)).length).toBe(5)
  expect(await ui.find({ type: 'Text', text: /^board unavailable/ })).toBeUndefined()
  mode = 'deny'
  await clock.advance(2000)
  expect(asOf(122000)).not.toBe(asOf(0))
  expect(await ui.find({ type: 'Text', text: new RegExp('^board unavailable: .*boom.* \\(showing the board as of ' + asOf(122000) + '\\)$') })).toBeDefined()
})

test('an object with no windows array is a failure, not an empty board', async ($, on) => {
  stubs(on, () => ({ value: { exitCode: 0, stdout: '{}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: 'board unavailable: board-json printed no board' })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: 'no windows open in this Daedalus home' })).toBeUndefined()
})

test('the session id is read again on every tick, so after /resume the band follows the new transcript (finding 9)', async ($, on) => {
  let sid = 'sC'
  const runs: Run[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: sid }))
  on('session.cwd', () => ({ value: '/work' }))
  on('fs.exists', () => ({ value: true }))
  on('ui.log', () => ({ value: undefined }))
  on('process.run', (_$: unknown, e: any) => {
    runs.push({ argv: e.argv, init: e.init })
    return ok(FIXTURE)
  })
  on('ui.render', () => THEIRS)
  const clock = mock.clock(on)
  await start($)
  expect(runs[0].argv[4]).toBe('sC')
  sid = 'sNew'
  await clock.advance(2000)
  expect(runs.length).toBe(2)
  expect(runs[1].argv[4]).toBe('sNew')
})

test('a session nobody sits at (claude -p: isInteractive false) starts no timer and runs board-json never (finding 10)', async ($, on) => {
  const { runs, clock } = stubs(on, () => ok(FIXTURE))
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  expect(runs.length).toBe(0)
  await clock.advance(4000)
  expect(runs.length).toBe(0)
})

test('one read at a time: while board-json is still running, a tick starts no second one (finding 11)', async ($, on) => {
  let calls = 0
  const { runs, clock } = stubs(on, () => {
    calls += 1
    if (calls === 1) return ok(FIXTURE)
    return new Promise(() => {}) // the second read never finishes
  })
  await start($)
  expect(runs.length).toBe(1)
  await clock.advance(2000)
  await clock.advance(2000)
  await clock.advance(2000)
  expect(runs.length).toBe(2)
})

test('the first prompt is not held behind the first read: session.start returns while board-json is still running (finding 13)', async ($, on) => {
  let release: (v: unknown) => void = () => {}
  const held = new Promise((r) => { release = r })
  const { clock } = stubs(on, () => held.then(() => ok(FIXTURE)))
  let started = false
  const p = start($).then(() => { started = true })
  await clock.settle()
  await clock.settle()
  expect(started).toBe(true)
  release(null)
  await p
})

test('with room for one row this window\'s own line is the one shown, and no "+N more" line takes its place (findings 15, 26)', async ($, on) => {
  stubs(on, () => ok(withAmi(undefined))) // no AMI line: the room is the window lines' alone
  await start($)
  const one = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, maxRows: 1, scroll: { offset: 0, bodyRows: 1 } } })
  const lines = await windowLines(one)
  expect(lines.length).toBe(1)
  expect(lines[0]).toMatch(/^window 03 · this window/)
  expect(await one.find({ type: 'Text', text: /more windows$/ })).toBeUndefined()
  await one.unmount()
  // two rows: this window and the count of the rest
  const two = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, maxRows: 2, scroll: { offset: 0, bodyRows: 2 } } })
  expect((await windowLines(two)).length).toBe(1)
  expect(await two.find({ type: 'Text', text: '+4 more windows' })).toBeDefined()
})

test('the home is the one above the session cwd; the plugin directory is the fallback, and a disagreement is logged (findings 12, 18, 21)', async ($, on) => {
  const logs: string[] = []
  const runs: Run[] = []
  const exists: string[] = []
  // the plugin's grandparent (in the kit: the Daedalus checkout holding this mod) has core/leaselib.py too
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'sC' }))
  on('session.cwd', () => ({ value: '/work/deep' }))
  on('fs.exists', (_$: unknown, e: any) => {
    exists.push(String(e.path))
    return { value: !String(e.path).startsWith('/work/deep/') }
  })
  on('ui.log', (_$: unknown, e: any) => { logs.push(String(e.text)); return { value: undefined } })
  on('process.run', (_$: unknown, e: any) => { runs.push({ argv: e.argv, init: e.init }); return ok(FIXTURE) })
  on('ui.render', () => THEIRS)
  mock.clock(on)
  await start($)
  expect(runs[0].init?.cwd).toBe('/work')
  expect(exists[0]).toBe('/work/deep/core/leaselib.py')
  expect(logs.some((l) => l.includes('/work') && l.includes('plugin directory') && l.includes('mods/lease-board'))).toBe(true)
})

test('with no Daedalus home above the cwd, the home above the plugin directory is used', async ($, on) => {
  const runs: Run[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'sC' }))
  on('session.cwd', () => ({ value: '/elsewhere' }))
  on('fs.exists', (_$: unknown, e: any) => ({ value: !String(e.path).startsWith('/elsewhere') && !String(e.path).startsWith('/core') && !String(e.path).startsWith('/VERSION') }))
  on('ui.log', () => ({ value: undefined }))
  on('process.run', (_$: unknown, e: any) => { runs.push({ argv: e.argv, init: e.init }); return ok(FIXTURE) })
  on('ui.render', () => THEIRS)
  mock.clock(on)
  await start($)
  const home = String(runs[0].init?.cwd)
  expect(home.endsWith('/mods/lease-board')).toBe(false)
  expect(home.startsWith('/')).toBe(true)
  // the plugin directory is <home>/mods/lease-board: its grandparent is the home
  expect(new URL('../../..', import.meta.url).pathname.replace(/\/$/, '')).toBe(home)
})

test('the first render logs what next(e) resolved to, once, for the human step (spec §9 Q3)', async ($, on) => {
  const logs: string[] = []
  const runs: Run[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'sC' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('fs.exists', () => ({ value: true }))
  on('ui.log', (_$: unknown, e: any) => { logs.push(String(e.text)); return { value: undefined } })
  on('process.run', (_$: unknown, e: any) => { runs.push({ argv: e.argv, init: e.init }); return ok(FIXTURE) })
  on('ui.render', () => THEIRS)
  mock.clock(on)
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await ui.unmount()
  await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(logs.filter((l) => l.includes('next(e) resolved to object')).length).toBe(1)
})

// --- the band that never appeared (Claude Code 2.1.300, 2026-10-15) ------------------------------------------------

// What next(e) resolves to on the real band: "At these sites, next(e) returns a reference to Claude Code's drawing,
// { type: 'engine', ref }, unless a mod that runs after yours returned a tree of its own" (interface page); the
// types: "The component core draws itself, with the props held under `ref`. type: 'engine'; ref: number ... 0 draws
// the original props". The stubs above answer with a Text, which is not the shape the engine hands back, so nothing
// here had exercised it: on 2.1.300 every ui.render on the band was refused with "a hook returned a tree that does
// not validate (engine node under a Box with prop "width"); drawing the engine's own", and the band stayed empty.
const ENGINE = { type: 'engine', ref: 0 }

// Every node of a tree with the chain of Boxes above it, outermost first.
function walk(node: any, above: any[] = [], out: { node: any; above: any[] }[] = []) {
  if (!node || typeof node !== 'object') return out
  out.push({ node, above })
  for (const c of node.children || []) walk(c, above.concat([node]), out)
  return out
}

test('the engine\'s own node from next(e) is kept, outside any Box that has a width, and the tree validates (2.1.300)', async ($, on) => {
  stubs(on, () => ok(FIXTURE), ENGINE)
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  // "rejects with the refusal when the surface could not draw what the chain returned" (the types, Mounted.drawn)
  let refusal = ''
  let tree: any
  try {
    tree = await ui.drawn()
  } catch (err: any) {
    refusal = String(err && err.message ? err.message : err)
  }
  expect(refusal).toBe('')
  // this mod's lines are still there, sized to the band
  expect((await windowLines(ui)).length).toBe(5)
  // the engine's node is in the tree exactly once ...
  const found = walk(tree).filter((x) => x.node.type === 'engine')
  expect(found.length).toBe(1)
  // ... and no Box above it carries a width: the engine refuses that shape on this build
  const sized = found[0].above.filter((b) => b.type === 'Box' && b.props && b.props.width !== undefined)
  expect(sized.length).toBe(0)
  // ... and this mod's lines still sit under the one Box that carries the band's width
  const widths = walk(tree).filter((x) => x.node.type === 'Box' && x.node.props && x.node.props.width !== undefined)
  expect(widths.length).toBe(1)
  expect(widths[0].node.props.width).toBe(80)
  await ui.unmount()
  // the Desktop app gets the same tree
  const desktop = await $.ui.mount({ ...BAND, surface: 'desktop' })
  expect(walk(await desktop.drawn()).filter((x) => x.node.type === 'engine').length).toBe(1)
  expect((await windowLines(desktop)).length).toBe(5)
})

// --- frame-jack: the AMI line (frame-jack spec §9.2) ------------------------------------------------------------

const AMI_ON = 'AMI on · shadow (logs, never acts) · 212 asked · would have asked you 7 times · would have shortened 2 · 171 ms'

function withAmi(ami: Record<string, unknown> | undefined, extra: Record<string, unknown> = {}) {
  const b: Record<string, unknown> = { ...FIXTURE, ...extra }
  if (ami === undefined) delete b.ami
  else b.ami = { ...FIXTURE.ami, ...ami }
  return b
}

async function texts(ui: any): Promise<string[]> {
  return (await ui.findAll({ type: 'Text' })).map((t: any) => String(t.text))
}

test('the AMI line when on: the counts in words, plain colour, after the window lines; "· N overruled" only when overrides is not zero', async ($, on) => {
  let ami: Record<string, unknown> = {}
  const { clock } = stubs(on, () => ok(withAmi(ami)), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const t = await texts(ui)
  expect(t[t.length - 1]).toBe(AMI_ON)
  expect(t.slice(0, 5).every((x) => x.startsWith('window '))).toBe(true)
  const line = await ui.find({ type: 'Text', text: AMI_ON })
  expect(line?.props.color).toBe('text')
  expect(line?.props.wrap).toBe('truncate-end')
  ami = { overrides: 3 }
  await clock.advance(2000)
  expect(await ui.find({ type: 'Text', text: AMI_ON + ' · 3 overruled' })).toBeDefined()
})

test('a question switched off reads as off on the AMI line, never as a zero count: destructive off with no would-ask says "destructive question off"; suite off with nothing shortened says "suite question off"; an older board-json without questions keeps the counts', async ($, on) => {
  let ami: Record<string, unknown> = { questions: { destructive: false, suite: true }, would_ask: 0 }
  const { clock } = stubs(on, () => ok(withAmi(ami)), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: 'AMI on · shadow (logs, never acts) · 212 asked · destructive question off · would have shortened 2 · 171 ms' })).toBeDefined()
  ami = { questions: { destructive: true, suite: false }, would_ask: 0, would_shorten: 0 }
  await clock.advance(2000)
  expect(await ui.find({ type: 'Text', text: 'AMI on · shadow (logs, never acts) · 212 asked · would have asked you 0 times · suite question off · 171 ms' })).toBeDefined()
  ami = { would_ask: 0 }
  await clock.advance(2000)
  expect(await ui.find({ type: 'Text', text: 'AMI on · shadow (logs, never acts) · 212 asked · would have asked you 0 times · would have shortened 2 · 171 ms' })).toBeDefined()
})

test('the AMI line when off is dim; down, supervisor gone, battery, tripped and not configured are in the warning colour with their remedies', async ($, on) => {
  let ami: Record<string, unknown> = { state: 'off' }
  const { clock } = stubs(on, () => ok(withAmi(ami)))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: 'AMI off' }))?.props.dimColor).toBe(true)
  const retry = new Date(2026, 9, 15, 9, 48).getTime() / 1000
  const cases: Array<[Record<string, unknown>, string | RegExp]> = [
    [{ state: 'down' }, 'AMI on but the daemon is down — /frame-jack on'],
    [{ state: 'supervisor gone' }, 'AMI on but its supervisor is gone — /frame-jack off, then on'],
    [{ state: 'battery' }, 'AMI paused on battery'],
    [{ state: 'tripped', retry_epoch: retry }, /^AMI tripped \(slow or wedged\) — retrying at (\d{4}-\d\d-\d\d )?09:48$/],
    [{ state: 'unconfigured' }, 'AMI on but not configured — /frame-jack status'],
  ]
  for (const [a, want] of cases) {
    ami = a
    await clock.advance(2000)
    const line = await ui.find({ type: 'Text', text: want })
    expect(line).toBeDefined()
    expect(line?.props.color).toBe('warning')
  }
})

test('AMI starting shows the seconds since since_epoch, against the clock of the read', async ($, on) => {
  const { clock } = stubs(on, () => ok(withAmi({ state: 'starting', since_epoch: 88 })))
  await start($)
  await clock.advance(100000) // the last read at 100 s on the mock clock: twelve seconds after since_epoch
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const line = await ui.find({ type: 'Text', text: 'AMI starting (12 s)' })
  expect(line).toBeDefined()
  expect(line?.props.color).toBe('warning')
})

test('no AMI line when board-json has no ami key (an older board-json) or the state is absent; the window lines are unchanged', async ($, on) => {
  let ami: Record<string, unknown> | undefined = undefined
  const { clock } = stubs(on, () => ok(withAmi(ami)), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  let t = await texts(ui)
  expect(t.length).toBe(5)
  expect(t.some((x) => x.startsWith('AMI'))).toBe(false)
  expect((await windowLines(ui)).length).toBe(5)
  ami = { state: 'absent' }
  await clock.advance(2000)
  t = await texts(ui)
  expect(t.length).toBe(5)
  expect(t.some((x) => x.startsWith('AMI'))).toBe(false)
})

test('zero windows: the AMI line sits between the "no windows" line and the tail; no board yet: no AMI line', async ($, on) => {
  let mode: 'ok' | 'deny' = 'ok'
  const { clock } = stubs(on, () => (mode === 'ok' ? ok(withAmi({}, { this_window: null, prime_window: null, windows: [] })) : { deny: 'boom' }), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await texts(ui)).toEqual(['no windows open in this Daedalus home', AMI_ON])
  mode = 'deny'
  await clock.advance(2000)
  const t = await texts(ui)
  expect(t.length).toBe(3)
  expect(t[0]).toBe('no windows open in this Daedalus home')
  expect(t[1]).toBe(AMI_ON)
  expect(t[2]).toMatch(/^board unavailable: /)
})

test('no board yet: one dim line and no AMI line', async ($, on) => {
  stubs(on, () => ({ deny: 'boom' }), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const t = await texts(ui)
  expect(t.length).toBe(1)
  expect(t[0]).toMatch(/^board unavailable: /)
})

test('maxRows reached: the AMI line is drawn and it takes one window row — it counts in the room', async ($, on) => {
  stubs(on, () => ok(FIXTURE), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, maxRows: 4, scroll: { offset: 0, bodyRows: 3 } } })
  const t = await texts(ui)
  expect(t.length).toBe(4)
  expect((await windowLines(ui)).length).toBe(2)
  expect(t[2]).toBe('+3 more windows')
  expect(t[3]).toBe(AMI_ON)
})

test('the AMI line says "1 time", not "1 times"', async ($, on) => {
  stubs(on, () => ok(withAmi({ would_ask: 1 })), { type: 'Box', props: {}, children: [] })
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: AMI_ON.replace('7 times', '1 time') })).toBeDefined()
})

// --- sharing the band with service-status (service-status spec §4) -----------------------------------------------

// The rows a tree lays out as, top to bottom, each the texts drawn left to right on it: a column Box stacks its
// children's rows, a row Box lays its children's rows side by side (row i of each), a Text is one row, the engine's
// node on an empty band draws nothing. A layout of the tree, not of the paint ("A drawing test checks the tree your
// hook returns and whether it's valid for that app. It doesn't check how the app paints it", test page).
function rowsOfTree(node: any): string[][] {
  if (!node || typeof node !== 'object') return typeof node === 'string' && node.trim() ? [[node]] : []
  if (node.type === 'engine') return []
  if (node.type === 'Text') return [[(node.children || []).map((c: any) => (typeof c === 'string' ? c : '')).join('')]]
  const kids = (node.children || []).map(rowsOfTree)
  // a Box with no flexDirection is a row, as in the terminal's flex layout; both mods name theirs anyway
  const dir = node.props && node.props.flexDirection
  if (node.type === 'Box' && (dir === undefined || dir === 'row')) {
    const n = Math.max(0, ...kids.map((k: string[][]) => k.length))
    const out: string[][] = []
    for (let i = 0; i < n; i += 1) out.push(kids.flatMap((k: string[][]) => k[i] || []))
    return out
  }
  return kids.flat()
}

// A stand-in for service-status's band hook, the shape it draws (mods/service-status/hooks/register.js): one row,
// the next mod's tree on the flexible left in a Box with no width, the summary on the right. Inline plugins are
// "self-contained, as a module's is: it closes over nothing of the test file" (the types, Plugin), so the shape is
// written out here; mods/service-status/tests/ holds the mirror of these tests with the real service-status and a
// stand-in for this mod. `tier` places it in the chain: prepend runs before this mod (outermost), append after it.
function statusStandIn(tier: 'prepend' | 'append') {
  return {
    name: 'status-stand-in',
    tier,
    register(on: any) {
      on('ui.render', { component: 'AbovePrompt' }, async ($: any, e: any, next: any) => {
        if (e.props.hasSurvey) return next(e)
        const { Box, Text } = $.ui.resolve(e)
        const theirs = await next(e)
        return Box({
          flexDirection: 'row',
          children: [
            Box({ flexDirection: 'row', flexGrow: 1, flexShrink: 1, children: theirs && typeof theirs === 'object' ? [theirs] : [] }),
            Box({ key: 'summary', flexDirection: 'row', flexShrink: 0, children: [Text({ children: ['services ok'] }), ' ', Text({ children: ['[ details ]'] })] }),
          ],
        })
      })
    },
  }
}

for (const [order, tier] of [['service-status first (outermost)', 'prepend'], ['lease-board first (outermost)', 'append']] as const) {
  test(`both mods in the band, ${order}: one valid tree, every window line, the summary once at the right end of the first row`, { plugins: [statusStandIn(tier)] }, async ($, on) => {
    stubs(on, () => ok(withAmi(undefined)), ENGINE)
    await start($)
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ ...BAND, surface })
      let refusal = ''
      let tree: any
      try {
        tree = await ui.drawn()
      } catch (err: any) {
        refusal = String(err && err.message ? err.message : err)
      }
      expect(refusal).toBe('')
      // the order is the one asked for: the outermost mod's own Box is the root (a row for the stand-in)
      expect(tree.props.flexDirection).toBe(tier === 'prepend' ? 'row' : 'column')
      const rows = rowsOfTree(tree)
      expect(rows.length).toBe(5)
      expect(rows[0][0]).toMatch(/^window 03 · this window/)
      expect(rows[0].slice(1)).toEqual(['services ok', '[ details ]'])
      // the first line has a floor: its full length, up to 60% of the band (the operator's look, 2026-10-18)
      const floors = walk(tree).filter((x) => x.node.type === 'Box' && x.node.props && x.node.props.minWidth !== undefined)
      expect(floors.length).toBe(1)
      expect(floors[0].node.props.minWidth).toBe(Math.min(rows[0][0].length, Math.floor(BAND.props.bodyColumns * 0.6)))
      for (const r of rows.slice(1)) expect(r.length).toBe(1)
      expect(rows.slice(1).map((r) => r[0].slice(0, 9))).toEqual(['window 01', 'window 02', 'window 04', 'window 05'])
      // the engine's node once, under no Box with a width
      const found = walk(tree).filter((x) => x.node.type === 'engine')
      expect(found.length).toBe(1)
      expect(found[0].above.filter((b) => b.type === 'Box' && b.props && b.props.width !== undefined).length).toBe(0)
      await ui.unmount()
    }
  })
}
