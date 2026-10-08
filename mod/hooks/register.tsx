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
const money = (v: number) => (v >= 100 ? `$${v.toFixed(0)}` : v >= 10 ? `$${v.toFixed(1)}` : `$${v.toFixed(2)}`)
const until = (iso: string | undefined, now: number) => {
  if (!iso) return ''
  const m = Math.max(0, Math.round((Date.parse(iso) - now) / 60000))
  return m >= 1440 ? `${Math.floor(m / 1440)}d ${Math.floor((m % 1440) / 60)}h` : m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`
}

/** "claude-opus-5-5" → "Opus 5.5"; same rule as the app's modelLabel. */
const modelName = (id: string) => {
  const parts = id.replace('claude-', '').replace(/\[.*\]$/, '').split('-').filter(p => p && p.length < 8)
  if (!parts.length) return id
  return parts[0][0].toUpperCase() + parts[0].slice(1) + (parts.length > 1 ? ' ' + parts.slice(1).join('.') : '')
}
const EFFORT: Record<string, string> = { low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max' }
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

let poll: (() => void) | null = null
let watch: (() => void) | null = null
let lastSync = 0

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await update($, cwd, () => e.cwd)
    const alias = await $.session.model()
    await update($, model, m => ({ ...m, alias, name: '' }))
    void refresh($)
    // Every 10 s: pick up the newest limits and totals, and answer the app's Sync button.
    watch?.()
    watch = $.clock.every(10_000, () => {
      void (async () => {
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
    await setState($, 'working')
    poll?.()
    poll = $.clock.every(2000, () => void refresh($))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    poll?.()
    poll = null
    const out = await next(e)
    await setState($, 'done')
    await refresh($)
    return out
  })

  on('tool.call', async ($, e, next) => {
    if (e.tool !== 'AskUserQuestion' && e.tool !== 'ExitPlanMode') return next(e)
    const qs = (e as any).questions
    await setState($, 'waiting', Array.isArray(qs) ? String(qs[0]?.question ?? '') : 'Plan ready for review')
    const out = await next(e)
    await setState($, 'working')
    return out
  })

  // The usage bar above the chat input.
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
    const spentToday = await read($, today)
    const wide = (e.props.bodyColumns ?? 100) >= 90
    const { Box, Text } = $.ui.resolve(e)
    const sep = <Text color={DIM}>│</Text>
    return (
      <Box flexDirection="row" flexWrap="wrap" columnGap={2} paddingX={1}>
        {shown && (
          <Text>
            <Text color={modelColor(shown)} bold>
              ◆ {modelName(shown)}
            </Text>
            {effort && <Text color={SOFT}> · {EFFORT[effort] ?? effort} effort</Text>}
          </Text>
        )}
        {shown && sep}
        {five && (
          <Text>
            <Text color={SOFT}>5h </Text>
            <Text color={level(five.percentUsed)} bold>
              {wide ? `${bar(five.percentUsed, 8)} ` : ''}
              {Math.round(five.percentUsed)}%
            </Text>
            {five.resetsAt && <Text color={SOFT}> · {until(five.resetsAt, now)} left</Text>}
          </Text>
        )}
        {week && (
          <Text>
            <Text color={SOFT}>Week </Text>
            <Text color={level(week.percentUsed)} bold>
              {wide ? `${bar(week.percentUsed, 6)} ` : ''}
              {Math.round(week.percentUsed)}%
            </Text>
            {week.resetsAt && <Text color={SOFT}> · {until(week.resetsAt, now)} left</Text>}
          </Text>
        )}
        {sep}
        <Text>
          <Text color={SOFT}>This chat </Text>
          <Text color={CYAN} bold>
            {money(await read($, usd))}
          </Text>
          {spentToday >= 0 && <Text color={SOFT}> · Today </Text>}
          {spentToday >= 0 && (
            <Text color={YELLOW} bold>
              {money(spentToday)}
            </Text>
          )}
        </Text>
      </Box>
    )
  })
}
