// Tests for the service status in the band, the pane and the status line (service-status spec §5 item 2). Run
// with `claude plugin test mods/service-status` from the Daedalus home. No session, no python, no service: every
// call the mod makes is answered by a stub here. The test page: "A drawing test checks the tree your hook returns
// and whether it's valid for that app. It doesn't check how the app paints it."
import { expect, mock, test } from 'claude-code/testing'

type Row = { stem: string; name: string; state: string; detail: string }

const ALL_UP: Row[] = [
  { stem: 'hindsight', name: 'memory server', state: 'up', detail: '127.0.0.1:8888 answered' },
  { stem: 'capture', name: 'memory capture', state: 'up', detail: 'last capture 2 min ago' },
  { stem: 'vault-index', name: 'vault search', state: 'up', detail: 'store state/chroma' },
  { stem: 'ami', name: 'decider', state: 'not-set-up', detail: 'frame-jack is off' },
  { stem: 'code-graph', name: 'code graph', state: 'up', detail: 'code-review-graph found' },
]

function withState(states: Record<string, string>): Row[] {
  return ALL_UP.map((r) => (states[r.stem] ? { ...r, state: states[r.stem] } : r))
}

// `mcp` is status.py's memory_mcp (PROP-027): whether an MCP server named hindsight is configured here. Left out, the
// object has no memory_mcp, as status.py printed it before PROP-027: the row reads the tool list alone, as 0.1.0 did.
function ok(services: Row[], mcp?: { configured: boolean | null; detail: string }) {
  const data: any = { services, checked_at: '2026-10-17T21:40:00+00:00' }
  if (mcp) data.memory_mcp = mcp
  return { value: { exitCode: 0, stdout: JSON.stringify(data), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
}

const NO_MCP = { configured: false, detail: 'no MCP server named hindsight in any scope' }
const LOCAL_MCP = { configured: true, detail: 'local scope (/home/x/.claude.json)' }

const tool = (name: string, mcp = false) => ({ name, description: '', mcp })
const WITH_TOOLS = [tool('Bash'), tool('Read'), tool('mcp__hindsight__recall', true), tool('mcp__hindsight__retain', true)]
const NO_TOOLS = [tool('Bash'), tool('Read'), tool('mcp__chroma__chroma_query_documents', true)]

const BAND = {
  plugin: 'service-status',
  component: 'AbovePrompt',
  requestId: 'above-prompt',
  viewport: { columns: 100, rows: 30 },
  props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100, scroll: { offset: 0, bodyRows: 9 }, view: {} },
} as const

const PANE = {
  plugin: 'service-status',
  component: 'Pane',
  requestId: 'services',
  viewport: { columns: 100, rows: 30 },
  props: { title: 'Services', isFocused: true, bodyColumns: 96, placement: 'inline', scroll: { offset: 0, bodyRows: 10 }, view: {} },
} as const

const ENGINE = { type: 'engine', ref: 0 }
const HELP = "Memory tools aren't connected. Type /mcp and reconnect hindsight."

type Run = { argv: readonly string[]; init: { cwd?: string; timeoutMs?: number } | undefined }

// Every stub the mod needs, registered before the test's first call on $ ("Register every stub before the test's
// first call on $"). `answer` and `toolList` are read on each call, so a test can change them between checks.
function stubs(on: any, answer: () => unknown, toolList: () => unknown = () => WITH_TOOLS, theirs: unknown = ENGINE) {
  const runs: Run[] = []
  const toasts: string[] = []
  const statuses: (string | undefined)[] = []
  const opened: any[] = []
  const commands: any[] = []
  const toolReads: number[] = []
  on('session.start', () => ({ cwd: '/work' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('fs.exists', () => ({ value: true }))
  on('ui.log', () => ({ value: undefined }))
  on('command.register', (_$: unknown, e: any) => { commands.push(e); return { value: { command: e.name } } })
  on('process.run', (_$: unknown, e: any) => { runs.push({ argv: e.argv, init: e.init }); return answer() })
  on('ui.toast', (_$: unknown, e: any) => { toasts.push(String(e.text)); return { value: undefined } })
  on('ui.status', (_$: unknown, e: any) => { statuses.push(e.text); return { value: undefined } })
  on('ui.open', (_$: unknown, e: any) => { opened.push(e); return { value: { isPlaced: true } } })
  const clock = mock.clock(on)
  on('tool.list', () => { toolReads.push(clock.now()); const t = toolList(); return Array.isArray(t) ? { value: t } : t })
  // "Stands for what Claude Code would draw at the site" (test page): what next(e) resolves to
  on('ui.render', () => theirs)
  return { runs, toasts, statuses, opened, commands, toolReads, clock }
}

async function start($: any, clock: any) {
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' })
  await clock.advance(0)
}

async function summaryOf(ui: any): Promise<any> {
  const box = await ui.find({ key: 'summary' })
  return (box?.children || []).find((c: any) => c && c.type === 'Text')
}

for (const surface of ['terminal', 'desktop'] as const) {
  test(`all up reads services ok, in green, with a details button (${surface})`, async ($, on) => {
    const { clock } = stubs(on, () => ok(ALL_UP))
    await start($, clock)
    const ui = await $.ui.mount({ ...BAND, surface })
    const words = await summaryOf(ui)
    expect(words?.children).toEqual(['services ok'])
    expect(words?.props.color).toBe('success')
    expect((await ui.find({ key: 'details' }))?.props.label).toBe('details')
    await ui.unmount()
  })

  test(`one service down is named, in the warning colour (${surface})`, async ($, on) => {
    const { clock } = stubs(on, () => ok(withState({ hindsight: 'down' })))
    await start($, clock)
    const ui = await $.ui.mount({ ...BAND, surface })
    const words = await summaryOf(ui)
    expect(words?.children).toEqual(['hindsight down'])
    expect(words?.props.color).toBe('warning')
    await ui.unmount()
  })
}

test('several down are named where they fit, and counted on a narrow band', async ($, on) => {
  const { clock } = stubs(on, () => ok(withState({ hindsight: 'down', capture: 'down' })))
  await start($, clock)
  const wide = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(wide))?.children).toEqual(['hindsight, capture down'])
  await wide.unmount()
  // 60 columns: "hindsight, capture down" and "[ details ]" would take 35 of the 24 cells the summary may have
  const narrow = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, bodyColumns: 60 } })
  expect((await summaryOf(narrow))?.children).toEqual(['2 services down'])
  await narrow.unmount()
})

test('not set up never counts as down', async ($, on) => {
  const { clock } = stubs(on, () => ok(withState({ capture: 'not-set-up', 'vault-index': 'not-set-up' })))
  await start($, clock)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(ui))?.children).toEqual(['services ok'])
})

test('while the first check runs the band says services: checking…, dim, and the first prompt is not held', async ($, on) => {
  const { clock } = stubs(on, () => new Promise(() => {}))
  let started = false
  const p = $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work' }).then(() => { started = true })
  await clock.settle()
  await clock.settle()
  expect(started).toBe(true)
  await p
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  const words = await summaryOf(ui)
  expect(words?.children).toEqual(['services: checking…'])
  expect(words?.props.dimColor).toBe(true)
})

test("a status.py that fails is couldn't check in the band, and the pane says why; no toast, no status line", async ($, on) => {
  const { clock, toasts, statuses } = stubs(on, () => ({ value: { exitCode: 2, stdout: '', stderr: 'daedalus: no config.yaml in /work, so no service can be checked\n', isStdoutTruncated: false, isStderrTruncated: false } }))
  await start($, clock)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(["services: couldn't check"])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await pane.find({ type: 'Text', text: "Couldn't check: no config.yaml in /work, so no service can be checked" })).toBeDefined()
  expect(toasts).toEqual([])
  expect(statuses).toEqual([])
})

test('output that is not the shape is a failed check, never a guess', async ($, on) => {
  const { clock } = stubs(on, () => ({ value: { exitCode: 0, stdout: '{"services":[{"stem":"x","name":"y","state":"sideways"}]}', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  await start($, clock)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(ui))?.children).toEqual(["services: couldn't check"])
})

test('runs core/status.py --json in the Daedalus home with a 5 s timeout, at start and every 60 s', async ($, on) => {
  const { runs, clock } = stubs(on, () => ok(ALL_UP))
  await start($, clock)
  expect(runs.length).toBe(1)
  expect(runs[0].argv).toEqual(['python3', 'core/status.py', '--json'])
  expect(runs[0].init?.cwd).toBe('/work')
  expect(runs[0].init?.timeoutMs).toBe(5000)
  await clock.advance(59000)
  expect(runs.length).toBe(1)
  await clock.advance(1000)
  expect(runs.length).toBe(2)
  await clock.advance(60000)
  expect(runs.length).toBe(3)
})

test('a session nobody sits at (isInteractive false) registers no command, starts no timer and runs status.py never', async ($, on) => {
  const { runs, commands, clock } = stubs(on, () => ok(ALL_UP))
  await $.session.start({ surface: 'terminal', isInteractive: false, cwd: '/work' })
  await clock.advance(120000)
  expect(runs.length).toBe(0)
  expect(commands.length).toBe(0)
})

test('a toast only on a change after the first check: nothing at start, nothing while the state holds, then went down and is back', async ($, on) => {
  let services = withState({ hindsight: 'down' })
  const { clock, toasts } = stubs(on, () => ok(services))
  await start($, clock)
  expect(toasts).toEqual([]) // down at the first check: no toast for it
  await clock.advance(60000)
  expect(toasts).toEqual([]) // still down
  services = ALL_UP
  await clock.advance(60000)
  expect(toasts).toEqual(['Hindsight is back'])
  await clock.advance(60000)
  expect(toasts).toEqual(['Hindsight is back'])
  services = withState({ hindsight: 'down', capture: 'down' })
  await clock.advance(60000)
  expect(toasts).toEqual(['Hindsight is back', 'Hindsight went down', 'Memory capture went down'])
})

test('a failed check changes no state: no toast across it', async ($, on) => {
  let mode: 'up' | 'fail' | 'down' = 'up'
  const { clock, toasts } = stubs(on, () => (mode === 'fail' ? { deny: 'timed out after 5000 ms' } : ok(mode === 'up' ? ALL_UP : withState({ hindsight: 'down' }))))
  await start($, clock)
  mode = 'fail'
  await clock.advance(60000)
  expect(toasts).toEqual([])
  mode = 'down'
  await clock.advance(60000)
  expect(toasts).toEqual(['Hindsight went down'])
})

test('the status line: cleared at the first check when all is up, set while anything is down, said once, cleared when it is back', async ($, on) => {
  let services = ALL_UP
  const { clock, statuses } = stubs(on, () => ok(services))
  await start($, clock)
  expect(statuses).toEqual([undefined])
  services = withState({ hindsight: 'down' })
  await clock.advance(60000)
  expect(statuses).toEqual([undefined, '⚠ service-status: hindsight down — /services for details'])
  await clock.advance(60000)
  expect(statuses.length).toBe(2) // still down: not said again
  services = ALL_UP
  await clock.advance(60000)
  expect(statuses).toEqual([undefined, '⚠ service-status: hindsight down — /services for details', undefined])
})

test('the memory tools: missing inside the 15 s grace is no news; past it, memory-tools down, and the pane says what to do', async ($, on) => {
  const { clock, toolReads } = stubs(on, () => ok(ALL_UP), () => NO_TOOLS)
  await start($, clock)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await clock.advance(14000)
  expect((await summaryOf(band))?.children).toEqual(['services ok'])
  await clock.advance(1000)
  expect((await summaryOf(band))?.children).toEqual(['memory-tools down'])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ key: 'row-memory-tools' }))?.children?.[0]?.children?.[0]).toMatch(/^memory tools {4}memory-tools {2}down {8}not connected to this session$/)
  expect((await pane.find({ key: 'tools-help' }))?.props.paddingLeft).toBe(2)
  expect(await pane.find({ type: 'Text', text: HELP })).toBeDefined()
  await clock.advance(45000)
  expect(toolReads).toEqual([0, 15000, 60000])
})

test('with the memory server down the /mcp help is left out: reconnecting cannot help', async ($, on) => {
  const { clock } = stubs(on, () => ok(withState({ hindsight: 'down' })), () => NO_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await pane.find({ key: 'row-memory-tools' })).toBeDefined()
  expect(await pane.find({ key: 'tools-help' })).toBeUndefined()
})

// --- PROP-027: memory reached through the REST API, with no hindsight MCP server configured --------------------

test('no hindsight MCP server configured, memory server and capture up: memory-tools up at the first check, services ok, no status line, no /mcp help (PROP-027)', async ($, on) => {
  const { clock, statuses, toasts } = stubs(on, () => ok(ALL_UP, NO_MCP), () => NO_TOOLS)
  await start($, clock)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['services ok'])
  await clock.advance(15000)
  await clock.advance(60000)
  expect((await summaryOf(band))?.children).toEqual(['services ok'])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ key: 'row-memory-tools' }))?.children?.[0]?.children?.[0]).toMatch(/^memory tools {4}memory-tools {2}up {10}no MCP server here; capture and recall use the REST API$/)
  expect(await pane.find({ key: 'tools-help' })).toBeUndefined()
  expect(statuses).toEqual([undefined])
  expect(toasts).toEqual([])
})

test('no hindsight MCP server configured and memory capture down: memory-tools blocked (dim, not a second name), no /mcp help (PROP-027)', async ($, on) => {
  const { clock } = stubs(on, () => ok(withState({ capture: 'down' }), NO_MCP), () => NO_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['capture down'])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const row = (await pane.find({ key: 'row-memory-tools' }))?.children?.[0]
  expect(row?.children?.[0]).toMatch(/blocked {5}memory capture is down; no MCP server here$/)
  expect(row?.props.dimColor).toBe(true)
  expect(await pane.find({ key: 'tools-help' })).toBeUndefined()
})

test('no hindsight MCP server configured and the memory server down: hindsight down alone in the band, memory-tools blocked, no /mcp help (PROP-027)', async ($, on) => {
  const { clock } = stubs(on, () => ok(withState({ hindsight: 'down' }), NO_MCP), () => NO_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['hindsight down'])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ key: 'row-memory-tools' }))?.children?.[0]?.children?.[0]).toMatch(/blocked {5}the memory server is down$/)
  expect(await pane.find({ key: 'tools-help' })).toBeUndefined()
})

test('a hindsight MCP server configured whose tools never appear: past the grace memory-tools down, with the /mcp help (PROP-027)', async ($, on) => {
  const { clock } = stubs(on, () => ok(ALL_UP, LOCAL_MCP), () => NO_TOOLS)
  await start($, clock)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await clock.advance(14000)
  expect((await summaryOf(band))?.children).toEqual(['services ok'])
  await clock.advance(1000)
  expect((await summaryOf(band))?.children).toEqual(['memory-tools down'])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await pane.find({ type: 'Text', text: HELP })).toBeDefined()
})

test('a hindsight MCP server configured and its tools connected: memory-tools up, connected to this session (PROP-027)', async ($, on) => {
  const { clock } = stubs(on, () => ok(ALL_UP, LOCAL_MCP), () => WITH_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ key: 'row-memory-tools' }))?.children?.[0]?.children?.[0]).toMatch(/up {10}connected to this session$/)
})

test('tools connected win even where no server is configured (a plugin or a managed config this reader does not see) (PROP-027)', async ($, on) => {
  const { clock } = stubs(on, () => ok(ALL_UP, NO_MCP), () => WITH_TOOLS)
  await start($, clock)
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ key: 'row-memory-tools' }))?.children?.[0]?.children?.[0]).toMatch(/up {10}connected to this session$/)
})

test('the memory server down with its tools still listed: memory-tools blocked, never up over a dead server; hindsight down alone in the band (review finding 1)', async ($, on) => {
  const { clock, toasts } = stubs(on, () => ok(withState({ hindsight: 'down' }), LOCAL_MCP), () => WITH_TOOLS)
  await start($, clock)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['hindsight down'])
  const pane = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await pane.find({ key: 'row-memory-tools' }))?.children?.[0]?.children?.[0]).toMatch(/blocked {5}the memory server is down$/)
  expect(await pane.find({ key: 'tools-help' })).toBeUndefined()
  await clock.advance(60000)
  expect(toasts).toEqual([])
})

test('a check where status.py could not tell (null) keeps the last answer it gave: no down, no toast, no /mcp line in a REST-only home (review finding 3)', async ($, on) => {
  let mcp: any = NO_MCP
  const { clock, toasts, statuses } = stubs(on, () => ok(ALL_UP, mcp), () => NO_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  mcp = { configured: null, detail: '/x/.claude.json could not be read (JSONDecodeError)' }
  await clock.advance(60000)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['services ok'])
  mcp = NO_MCP
  await clock.advance(60000)
  expect(toasts).toEqual([])
  expect(statuses).toEqual([undefined])
})

test('a memory_mcp that is not the shape is read as unknown: the 0.1.0 tool-list rule, never a failed check (PROP-027)', async ($, on) => {
  const bad = { value: { exitCode: 0, stdout: JSON.stringify({ services: ALL_UP, checked_at: 'x', memory_mcp: { configured: 'maybe' } }), stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  const { clock } = stubs(on, () => bad, () => NO_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['memory-tools down'])
})

test('the memory tools are not set up where the memory server is not', async ($, on) => {
  const { clock } = stubs(on, () => ok(withState({ hindsight: 'not-set-up' })), () => NO_TOOLS)
  await start($, clock)
  await clock.advance(15000)
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  expect((await summaryOf(band))?.children).toEqual(['services ok'])
})

test('/services opens the Services pane, closed by Esc, and prints nothing; details opens the same pane', async ($, on) => {
  const { clock, opened, commands } = stubs(on, () => ok(ALL_UP))
  await start($, clock)
  expect(commands.map((c) => c.name)).toEqual(['services'])
  const answer = await $.command.run({ command: 'services', args: '' } as any)
  expect(answer.text).toBeUndefined()
  expect(opened.length).toBe(1)
  expect(opened[0]).toMatchObject({ id: 'services', title: 'Services', closeOnEscape: true })
  const band = await $.ui.mount({ ...BAND, surface: 'terminal' })
  await band.press({ key: 'details' })
  expect(opened.length).toBe(2)
  expect(opened[1].id).toBe('services')
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the pane: one row per service with its plain name, stem, state and detail; not set up dim; the time of the last check (${surface})`, async ($, on) => {
    const { clock } = stubs(on, () => ok(withState({ capture: 'down' })))
    await start($, clock)
    await clock.advance(15000)
    const pane = await $.ui.mount({ ...PANE, surface })
    const text = async (key: string) => (await pane.find({ key }))?.children?.[0]
    expect((await text('row-hindsight'))?.children?.[0]).toBe('memory server   hindsight     up          127.0.0.1:8888 answered')
    expect((await text('row-capture'))?.props.color).toBe('warning')
    expect((await text('row-ami'))?.children?.[0]).toBe('decider         ami           not set up  frame-jack is off')
    expect((await text('row-ami'))?.props.dimColor).toBe(true)
    expect((await text('row-memory-tools'))?.children?.[0]).toMatch(/connected to this session$/)
    expect((await text('checked'))?.children?.[0]).toMatch(/^checked at \d\d:\d\d:\d\d$/)
    await pane.unmount()
  })
}

test('a survey holding the band is left alone: the hook returns next(e)', async ($, on) => {
  const { clock } = stubs(on, () => ok(ALL_UP), () => WITH_TOOLS, { type: 'Text', props: {}, children: ['drawn by Claude Code'] })
  await start($, clock)
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal', props: { ...BAND.props, hasSurvey: true } })
  expect(await ui.find({ key: 'summary' })).toBeUndefined()
  expect(await ui.find({ type: 'Text', text: 'drawn by Claude Code' })).toBeDefined()
})

// --- sharing the band with lease-board (spec §4) --------------------------------------------------------------

// Every node of a tree with the chain of Boxes above it, outermost first.
function walk(node: any, above: any[] = [], out: { node: any; above: any[] }[] = []) {
  if (!node || typeof node !== 'object') return out
  out.push({ node, above })
  for (const c of node.children || []) walk(c, above.concat([node]), out)
  return out
}

// The rows a tree lays out as, top to bottom, each the texts drawn left to right on it (the same helper as
// lease-board's tests): a column Box stacks, a row Box (or one with no flexDirection) lays side by side, a Text is
// one row, the engine's node on an empty band draws nothing, a Button draws `[ label ]`.
function rowsOfTree(node: any): string[][] {
  if (!node || typeof node !== 'object') return typeof node === 'string' && node.trim() ? [[node]] : []
  if (node.type === 'engine') return []
  if (node.type === 'Text') return [[(node.children || []).map((c: any) => (typeof c === 'string' ? c : '')).join('')]]
  if (node.type === 'Button') return [['[ ' + node.props.label + ' ]']]
  const kids = (node.children || []).map(rowsOfTree)
  const dir = node.props && node.props.flexDirection
  if (node.type === 'Box' && (dir === undefined || dir === 'row')) {
    const n = Math.max(0, ...kids.map((k: string[][]) => k.length))
    const out: string[][] = []
    for (let i = 0; i < n; i += 1) out.push(kids.flatMap((k: string[][]) => k[i] || []))
    return out
  }
  return kids.flat()
}

// A stand-in for lease-board's band hook, the shape it draws (mods/lease-board/hooks/register.js): a column, its
// first line in a row with the next mod's tree at its right end in no Box with a width, the other lines in a Box
// sized to the band. Inline plugins are "self-contained, as a module's is: it closes over nothing of the test file"
// (the types, Plugin); mods/lease-board/tests/ holds the mirror with the real lease-board and a stand-in for this
// mod. prepend runs it before this mod (outermost), append after it.
function boardStandIn(tier: 'prepend' | 'append') {
  return {
    name: 'board-stand-in',
    tier,
    register(on: any) {
      on('ui.render', { component: 'AbovePrompt' }, async ($: any, e: any, next: any) => {
        if (e.props.hasSurvey) return next(e)
        const { Box, Text } = $.ui.resolve(e)
        const theirs = await next(e)
        const first = Box({ flexDirection: 'row', flexGrow: 1, flexShrink: 1, children: [Text({ wrap: 'truncate-end', children: ['window 01 · this window · live · 3 changed'] })] })
        return Box({
          flexDirection: 'column',
          children: [
            Box({ flexDirection: 'row', children: theirs && typeof theirs === 'object' ? [first, theirs] : [first] }),
            Box({ flexDirection: 'column', width: e.props.bodyColumns, children: [Text({ wrap: 'truncate-end', children: ['window 02 · quiet since 21:40 · 0 changed'] })] }),
          ],
        })
      })
    },
  }
}

test('alone in the band: the engine\'s own node takes the flexible left, under no Box with a width, and the tree validates', async ($, on) => {
  const { clock } = stubs(on, () => ok(ALL_UP))
  await start($, clock)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })
    const tree = await ui.drawn()
    expect(rowsOfTree(tree)).toEqual([['services ok', '[ details ]']])
    const found = walk(tree).filter((x) => x.node.type === 'engine')
    expect(found.length).toBe(1)
    expect(found[0].above.filter((b) => b.type === 'Box' && b.props && b.props.width !== undefined).length).toBe(0)
    await ui.unmount()
  }
})

for (const [order, tier] of [['lease-board first (outermost)', 'prepend'], ['service-status first (outermost)', 'append']] as const) {
  test(`both mods in the band, ${order}: one valid tree, the board's rows kept, the summary once at the right end of the first row`, { plugins: [boardStandIn(tier)] }, async ($, on) => {
    const { clock } = stubs(on, () => ok(withState({ hindsight: 'down' })))
    await start($, clock)
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
      // the order is the one asked for: the outermost mod's own Box is the root (a column for the board)
      expect(tree.props.flexDirection).toBe(tier === 'prepend' ? 'column' : 'row')
      expect(rowsOfTree(tree)).toEqual([
        ['window 01 · this window · live · 3 changed', 'hindsight down', '[ details ]'],
        ['window 02 · quiet since 21:40 · 0 changed'],
      ])
      const found = walk(tree).filter((x) => x.node.type === 'engine')
      expect(found.length).toBe(1)
      expect(found[0].above.filter((b) => b.type === 'Box' && b.props && b.props.width !== undefined).length).toBe(0)
      await ui.unmount()
    }
  })
}
