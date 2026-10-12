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

test('a non-zero exit shows the operator sentence without its daedalus: prefix, and nothing else before a first good board', async ($, on) => {
  stubs(on, () => ({ value: { exitCode: 1, stdout: '', stderr: 'daedalus: The lease file for window 02 cannot be read (not valid JSON)\n', isStdoutTruncated: false, isStderrTruncated: false } }))
  await start($)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await windowLines(ui)).length).toBe(0)
  const line = await ui.find({ type: 'Text', text: 'board unavailable: The lease file for window 02 cannot be read (not valid JSON)' })
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
  expect(texts.length).toBe(5)
  for (const t of texts) expect(t.props.wrap).toBe('truncate-end')
  expect((await ui.drawn()).props.width).toBe(24)
})

test('more windows than rows: maxRows - 1 lines, then "+N more windows"', async ($, on) => {
  stubs(on, () => ok(FIXTURE))
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
