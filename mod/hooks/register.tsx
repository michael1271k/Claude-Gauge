// Claude Gauge mod: a usage bar above the chat input (model, effort, limits, spend), and per-chat
// status written to ~/.claude/gauge for the Claude Gauge app.
import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import type { Limit } from '../types'

const limits = atom({ plugin: 'usage-gauge', key: 'limits' } as const, [] as Limit[])
const usd = atom({ plugin: 'usage-gauge', key: 'usd' } as const, 0)
const today = atom({ plugin: 'usage-gauge', key: 'today' } as const, -1)
const cwd = atom({ plugin: 'usage-gauge', key: 'cwd' } as const, '')
// name: the model id the last request used; alias: what $.session.model() said then (a switch shows instantly);
// effort: the last request's effort, else the chat's or settings' default.
const model = atom({ plugin: 'usage-gauge', key: 'model' } as const, { name: '', effort: '', alias: '', fallback: '' })
// The current turn: when it started and how many tool calls it made (the bar's progress).
const work = atom({ plugin: 'usage-gauge', key: 'work' } as const, { start: 0, steps: 0 })
const git = atom({ plugin: 'usage-gauge', key: 'git' } as const, { branch: '', changed: 0 })
const chat = atom({ plugin: 'usage-gauge', key: 'chat' } as const, { state: 'idle', at: 0, label: '', question: '' })

const GREEN = '#40DB80'
const YELLOW = '#FFD63F'
const RED = '#FF5454'
const CYAN = '#63D1FF'
const SOFT = '#C9CED6'
const DIM = '#7D8590'

const level = (p: number) => (p >= 80 ? RED : p >= 50 ? YELLOW : GREEN)
const bar = (p: number, w: number) => {
  const n = Math.max(0, Math.min(w, Math.round((p / 100) * w)))
  return '▰'.repeat(n) + '▱'.repeat(w - n)
}
const money = (v: number) =>
  v >= 1000 ? `$${Math.round(v).toLocaleString('en-US')}` : v >= 100 ? `$${v.toFixed(0)}` : v >= 10 ? `$${v.toFixed(1)}` : `$${v.toFixed(2)}`
const elapsed = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000))
  return s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m` : s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`
}
const until = (iso: string | undefined, now: number) => {
  if (!iso) return ''
  const m = Math.max(0, Math.round((Date.parse(iso) - now) / 60000))
  return m >= 1440 ? `${Math.floor(m / 1440)}d ${Math.floor((m % 1440) / 60)}h` : m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`
}

/** "claude-opus-5-5" → "Opus 5.5"; same rule as the app's modelLabel. */
const modelName = (id: string) => {
  const parts = id.replace('claude-', '').replace(/\[.*\]$/, '').split('-').filter(p => p && p.length < 8)
  const first = parts[0]
  if (!first) return id
  return first.charAt(0).toUpperCase() + first.slice(1) + (parts.length > 1 ? ' ' + parts.slice(1).join('.') : '')
}
const EFFORT: Record<string, string> = { low: 'Low', medium: 'Med', high: 'High', xhigh: 'XHigh', max: 'Max' }
const modelColor = (id: string) =>
  id.includes('opus') ? '#B89AFF' : id.includes('haiku') ? GREEN : id.includes('fable') ? '#FF8C73' : CYAN

async function root($: any) {
  return `${(await $.env.get('HOME')) ?? '~'}/.claude/gauge`
}

async function readJSON($: any, path: string) {
  try {
    return (await $.fs.exists(path)) ? JSON.parse(String(await $.fs.read(path))) : null
  } catch {
    return null
  }
}

async function writeSession($: any) {
  const id = await $.session.id()
  const dir = await read($, cwd)
  const c = await read($, chat)
  await $.fs.write(
    `${await root($)}/sessions/${id}.json`,
    JSON.stringify({
      id,
      cwd: dir,
      project: dir.split('/').filter(Boolean).pop() ?? '',
      label: c.label,
      usd: await read($, usd),
      at: await $.clock.now(),
      limits: await read($, limits),
      state: c.state,
      stateAt: c.at,
      question: c.question,
      model: (await read($, model)).name,
      effort: (await read($, model)).effort,
    }),
  )
}

// Limits are shared through limits.json: the newest reading from any chat wins, so the bar in every chat
// and the app always show the same numbers. Today's spend comes from the app (totals.json).
async function syncShared($: any) {
  const base = await root($)
  const now = await $.clock.now()
  const shared = await readJSON($, `${base}/limits.json`)
  if (shared?.limits?.length) await update($, limits, () => shared.limits)
  const t = await readJSON($, `${base}/totals.json`)
  await update($, today, () => (t && now - Number(t.at ?? 0) < 15 * 60_000 ? Number(t.today ?? 0) : -1))
  // Effort when no request has reported one yet: the app's reading of this chat's transcript, else settings.
  const fromApp = (await readJSON($, `${base}/models.json`))?.[await $.session.id()]?.effort
  const fromSettings = (await $.settings.read())?.effortLevel
  await update($, model, m => ({ ...m, fallback: String(fromApp ?? fromSettings ?? '') }))
}

// Branch and changed-file count, every 10 s (git off the render path).
async function readGit($: any) {
  try {
    const b = await $.process.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], { timeoutMs: 3000 })
    if (b.exitCode !== 0) return update($, git, () => ({ branch: '', changed: 0 }))
    const st = await $.process.run(['git', 'status', '--porcelain'], { timeoutMs: 3000 })
    const changed = st.stdout.split('\n').filter(Boolean).length
    await update($, git, () => ({ branch: b.stdout.trim(), changed }))
  } catch {
    await update($, git, () => ({ branch: '', changed: 0 }))
  }
}

async function refresh($: any, given?: { limits: Limit[]; cost?: number }) {
  const u = given ?? (await $.session.usage().then((x: any) => ({ limits: x.rateLimits, cost: x.cost?.usd })))
  await update($, usd, () => u.cost ?? 0)
  if (u.limits?.length) {
    await $.fs.write(`${await root($)}/limits.json`, JSON.stringify({ limits: u.limits, at: await $.clock.now() }))
  }
  await syncShared($)
  await writeSession($)
}

// working | waiting (Claude asked the user something) | done (turn finished) | idle
async function setState($: any, state: string, question = '') {
  const at = await $.clock.now()
  await update($, chat, c => ({ ...c, state, at, question }))
  await writeSession($)
}

let poll: { cancel: () => void } | null = null
let watch: { cancel: () => void } | null = null
let lastSync = 0

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await update($, cwd, () => e.cwd)
    const alias = await $.session.model()
    await update($, model, m => ({ ...m, alias, name: '' }))
    void refresh($)
    void readGit($)
    // Every 10 s: pick up the newest limits and totals, answer the app's Sync button, re-read git.
    watch?.cancel()
    watch = $.clock.every(10_000, () => {
      void (async () => {
        await readGit($)
        const req = await readJSON($, `${await root($)}/sync.json`)
        if (req && Number(req.at) > lastSync) {
          lastSync = Number(req.at)
          await refresh($)
        } else {
          await syncShared($)
        }
      })()
    })
    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    await refresh($, { limits: e.rateLimits, cost: e.cost?.usd })
    return next(e)
  })

  // The model and effort each request is actually sent with (main loop only).
  on('turn.step', async function* ($, e, next) {
    if (!e.agentId) {
      const effort = typeof e.effort === 'string' ? e.effort : ''
      const alias = await $.session.model()
      await update($, model, m => ({ ...m, name: e.model, effort, alias }))
    }
    return yield* next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    if (!(await read($, chat)).label) {
      const label = e.text.replace(/\s+/g, ' ').trim().slice(0, 48)
      await update($, chat, c => ({ ...c, label }))
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    const start = await $.clock.now()
    await update($, work, () => ({ start, steps: 0 }))
    await setState($, 'working')
    poll?.cancel()
    poll = $.clock.every(2000, () => void refresh($))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    poll?.cancel()
    poll = null
    const out = await next(e)
    await setState($, 'done')
    await refresh($)
    return out
  })

  on('tool.call', async ($, e, next) => {
    if (!(e as any).agentId) await update($, work, w => ({ ...w, steps: w.steps + 1 }))
    if (e.tool !== 'AskUserQuestion' && e.tool !== 'ExitPlanMode') return next(e)
    const qs = (e as any).questions
    await setState($, 'waiting', Array.isArray(qs) ? String(qs[0]?.question ?? '') : 'Plan ready for review')
    const out = await next(e)
    await setState($, 'working')
    return out
  })

  // The usage bar above the chat input: one line, most useful first, trimmed on narrow windows.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const ls = await read($, limits)
    const five = ls.find(l => l.kind === 'five_hour')
    const week = ls.find(l => l.kind === 'seven_day')
    const m = await read($, model)
    // A /model switch shows at once; the exact id and effort follow with the next request.
    const current = await $.session.model()
    const shown = m.name && current === m.alias ? m.name : current
    const effort = (shown === m.name && m.effort) || m.fallback
    if (!five && !week && !shown) return next(e)
    const now = await $.clock.now()
    const cols = e.props.bodyColumns ?? 100
    const spentToday = await read($, today)
    const c = await read($, chat)
    const w = await read($, work)
    const g = await read($, git)
    const ctx = (await $.session.usage()).context?.percent
    const agents = c.state === 'working' ? await $.agent.list().catch(() => []) : []
    const running = agents.filter((a: any) => a.status === 'running' || a.status === 'pending').length
    const { Box, Text } = $.ui.resolve(e)
    const sep = <Text color={DIM}> │ </Text>
    const limit = (label: string, l: Limit, cells: number) => (
      <Text wrap="truncate-end">
        <Text color={DIM}>{label} </Text>
        {cols >= 110 && <Text color={level(l.percentUsed)}>{bar(l.percentUsed, cells)} </Text>}
        <Text color={level(l.percentUsed)} bold>
          {Math.round(l.percentUsed)}%
        </Text>
        {l.resetsAt && <Text color={DIM}> {until(l.resetsAt, now)}</Text>}
      </Text>
    )
    return (
      <Box flexDirection="row" flexWrap="nowrap" paddingX={1} overflow="hidden">
        {shown && (
          <Text wrap="truncate-end">
            <Text color={modelColor(shown)} bold>
              ◆ {modelName(shown)}
            </Text>
            {effort && <Text color={SOFT}> {EFFORT[effort] ?? effort}</Text>}
          </Text>
        )}
        {c.state === 'working' && w.start > 0 && (
          <Text wrap="truncate-end">
            {sep}
            <Text color={CYAN}>● </Text>
            <Text color={SOFT}>
              {w.steps} steps · {elapsed(now - w.start)}
            </Text>
            {agents.length > 0 && (
              <Text color={SOFT}>
                {' '}· {agents.length - running}/{agents.length} agents
              </Text>
            )}
          </Text>
        )}
        {c.state === 'waiting' && (
          <Text wrap="truncate-end">
            {sep}
            <Text color={YELLOW} bold>
              ● needs you
            </Text>
          </Text>
        )}
        {five && sep}
        {five && limit('5h', five, 5)}
        {week && sep}
        {week && limit('Wk', week, 5)}
        {ctx != null && cols >= 100 && sep}
        {ctx != null && cols >= 100 && (
          <Text wrap="truncate-end">
            <Text color={DIM}>Ctx </Text>
            <Text color={ctx >= 85 ? RED : ctx >= 65 ? YELLOW : SOFT}>{Math.round(ctx)}%</Text>
          </Text>
        )}
        {sep}
        <Text wrap="truncate-end">
          <Text color={CYAN} bold>
            {money(await read($, usd))}
          </Text>
          <Text color={DIM}> chat</Text>
          {spentToday >= 0 && <Text color={DIM}> · </Text>}
          {spentToday >= 0 && <Text color={YELLOW}>{money(spentToday)}</Text>}
          {spentToday >= 0 && <Text color={DIM}> today</Text>}
        </Text>
        {g.branch && cols >= 130 && sep}
        {g.branch && cols >= 130 && (
          <Text wrap="truncate-end" color={SOFT}>
            ⎇ {g.branch}
            {g.changed > 0 && <Text color={YELLOW}> +{g.changed}</Text>}
          </Text>
        )}
      </Box>
    )
  })
}
