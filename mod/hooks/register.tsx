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
// The app's appearance (Settings → Appearance), from ~/.claude/gauge/theme.json.
const theme = atom({ plugin: 'usage-gauge', key: 'theme' } as const, { accent: '#63D1FF', secondary: '#FFD63F' })
// Ticks once a second while Claude works, so the spinner and timer move.
const tick = atom({ plugin: 'usage-gauge', key: 'tick' } as const, 0)
const chat = atom({ plugin: 'usage-gauge', key: 'chat' } as const, { state: 'idle', at: 0, label: '', question: '' })

const GREEN = '#40DB80'
const YELLOW = '#FFD63F'
const RED = '#FF5454'
const CYAN = '#63D1FF'
const SOFT = '#C9CED6'
const DIM = '#7D8590'

/** The theme color until a window runs hot: yellow from 75%, red from 90%. */
const warn = (p: number, base: string) => (p >= 90 ? RED : p >= 75 ? YELLOW : base)
const SPIN = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']
/** Context fill as a filling circle. */
const pie = (p: number) => (p >= 88 ? '●' : p >= 63 ? '◕' : p >= 38 ? '◑' : p >= 13 ? '◔' : '○')
/** How much of the window has passed (0...1), from its reset time. */
const passed = (l: Limit, now: number) => {
  if (!l.resetsAt) return -1
  const win = l.kind === 'five_hour' ? 5 * 3600_000 : 7 * 86_400_000
  return Math.min(1, Math.max(0, 1 - (Date.parse(l.resetsAt) - now) / win))
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
  const th = await readJSON($, `${base}/theme.json`)
  if (th?.accent) await update($, theme, () => ({ accent: String(th.accent), secondary: String(th.secondary ?? th.accent) }))
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

// Opens the Claude Gauge app in the background when a chat starts and it isn't running (any surface:
// desktop app, terminal, IDE). Silent when the app isn't installed.
async function launchApp($: any) {
  try {
    const running = await $.process.run(['pgrep', '-x', 'Gauge'], { timeoutMs: 3000 })
    if (running.exitCode !== 0) await $.process.run(['open', '-g', '-b', 'app.claudegauge.mac'], { timeoutMs: 5000 })
  } catch {
    // no process access on this surface, or the app isn't installed
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
async function runningAgents($: any) {
  const list = await $.agent.list().catch(() => [])
  return list.filter((a: any) => a.status === 'running' || a.status === 'pending').length
}

async function setState($: any, state: string, question = '') {
  const at = await $.clock.now()
  await update($, chat, c => ({ ...c, state, at, question }))
  await writeSession($)
}

let poll: { cancel: () => void } | null = null
let inbox: { cancel: () => void } | null = null
let turnActive = false
let pulse: { cancel: () => void } | null = null
let watch: { cancel: () => void } | null = null
let lastSync = 0

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await update($, cwd, () => e.cwd)
    const alias = await $.session.model()
    await update($, model, m => ({ ...m, alias, name: '' }))
    void refresh($)
    void readGit($)
    void launchApp($)
    // Prompts sent from the app's Prompt Pad: `send` submits it as you, `draft` puts it in the prompt box.
    inbox?.cancel()
    inbox = $.clock.every(2000, () => {
      void (async () => {
        const path = `${await root($)}/inbox/${await $.session.id()}.json`
        const msg = await readJSON($, path)
        if (!msg?.text || msg.handled) return
        await $.fs.write(path, JSON.stringify({ ...msg, handled: true }))
        if (msg.mode === 'draft') await $.prompt.fill({ text: String(msg.text), mode: 'replace' })
        else await $.prompt.submit({ text: String(msg.text), asUser: true })
      })()
    })
    // Every 10 s: pick up the newest limits and totals, answer the app's Sync button, re-read git.
    watch?.cancel()
    watch = $.clock.every(10_000, () => {
      void (async () => {
        await readGit($)
        // Background sub-agents finished after the turn ended: now it's done.
        if (!turnActive && (await read($, chat)).state === 'working' && (await runningAgents($)) === 0) await setState($, 'done')
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
    turnActive = true
    const start = await $.clock.now()
    await update($, work, () => ({ start, steps: 0 }))
    await setState($, 'working')
    poll?.cancel()
    poll = $.clock.every(2000, () => void refresh($))
    pulse?.cancel()
    pulse = $.clock.every(1000, () => void update($, tick, n => n + 1))
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    poll?.cancel()
    poll = null
    pulse?.cancel()
    pulse = null
    const out = await next(e)
    turnActive = false
    // Background sub-agents still running: the chat is still working until they finish.
    await setState($, (await runningAgents($)) > 0 ? 'working' : 'done')
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

  // The usage bar above the chat input, one line. Left: model, what Claude is doing, limits, context.
  // Right: what this chat and today cost, and the branch. Colors follow the app's appearance.
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
    const { accent, secondary } = await read($, theme)
    const n = await read($, tick)
    const spentToday = await read($, today)
    const c = await read($, chat)
    const w = await read($, work)
    const g = await read($, git)
    const usage = await $.session.usage()
    const ctx = usage.context?.percent
    const ctxTokens = usage.context?.tokens
    const ctxWindow = usage.context?.window
    const chatUsd = await read($, usd)
    const hours = (now - (usage.startedAt ?? now)) / 3_600_000
    const rate = hours > 0.25 ? chatUsd / hours : 0
    const agents = c.state === 'working' ? await $.agent.list().catch(() => []) : []
    const running = agents.filter((a: any) => a.status === 'running' || a.status === 'pending').length
    const { Box, Text } = $.ui.resolve(e)
    const gap = <Text color={DIM}>{'  '}</Text>

    // A thin track filled to the usage, with a tick where the window's time is: fill past the tick = burning fast.
    const meter = (label: string, l: Limit, base: string) => {
      // The meters take the room the line has: wider windows get longer, finer tracks.
      const cells = cols < 100 ? 0 : Math.max(8, Math.min(22, Math.floor((cols - 110) / 5)))
      const fill = Math.round((Math.min(100, l.percentUsed) / 100) * cells)
      const t = passed(l, now)
      const at = t < 0 ? -1 : Math.min(cells - 1, Math.round(t * cells))
      const color = warn(l.percentUsed, base)
      const track = Array.from({ length: cells }, (_, i) =>
        i === at ? (
          <Text key={`t${i}`} color={SOFT}>
            ┃
          </Text>
        ) : (
          <Text key={`t${i}`} color={i < fill ? color : '#3A3F47'}>
            ━
          </Text>
        ),
      )
      return (
        <Text wrap="truncate-end">
          <Text color={DIM}>{label} </Text>
          {track}
          <Text color={color} bold>
            {' '}
            {Math.round(l.percentUsed)}%
          </Text>
          {l.resetsAt && <Text color={DIM}> {until(l.resetsAt, now)}</Text>}
        </Text>
      )
    }

    const left = (
      <Box flexDirection="row" flexWrap="nowrap" flexShrink={1}>
        {shown && (
          <Text wrap="truncate-end">
            <Text color={modelColor(shown)}>◆ </Text>
            <Text color={accent} bold>
              {modelName(shown)}
            </Text>
            {effort && <Text color={SOFT}> {EFFORT[effort] ?? effort}</Text>}
          </Text>
        )}
        {c.state === 'working' && w.start > 0 && (
          <Text wrap="truncate-end">
            {gap}
            <Text color={accent}>{SPIN[n % SPIN.length]} </Text>
            <Text color={SOFT}>{elapsed(now - w.start)}</Text>
            <Text color={DIM}> · {w.steps} steps</Text>
            {agents.length > 0 && (
              <Text color={DIM}>
                {' '}· <Text color={secondary}>{agents.length - running}</Text>/{agents.length} agents
              </Text>
            )}
          </Text>
        )}
        {c.state === 'waiting' && (
          <Text wrap="truncate-end">
            {gap}
            <Text color={YELLOW} bold>
              ● Needs your answer
            </Text>
          </Text>
        )}
        {five && gap}
        {five && meter('5h', five, accent)}
        {week && gap}
        {week && meter('Week', week, secondary)}
        {ctx != null && cols >= 100 && gap}
        {ctx != null && cols >= 100 && (
          <Text wrap="truncate-end" color={ctx >= 85 ? RED : ctx >= 65 ? YELLOW : SOFT}>
            {pie(ctx)} <Text color={DIM}>ctx </Text>
            <Text bold>{Math.round(ctx)}%</Text>
            {ctxTokens != null && ctxWindow != null && cols >= 140 && (
              <Text color={DIM}>
                {' '}
                {Math.round(ctxTokens / 1000)}k/{Math.round(ctxWindow / 1000)}k
              </Text>
            )}
          </Text>
        )}
      </Box>
    )

    const right = (
      <Box flexDirection="row" flexWrap="nowrap" flexShrink={0}>
        <Text wrap="truncate-end">
          <Text color={accent} bold>
            {money(chatUsd)}
          </Text>
          <Text color={DIM}> chat</Text>
          {rate > 0 && cols >= 150 && <Text color={DIM}> · {money(rate)}/h</Text>}
          {spentToday >= 0 && <Text color={DIM}>{'  '}</Text>}
          {spentToday >= 0 && (
            <Text color={secondary} bold>
              {money(spentToday)}
            </Text>
          )}
          {spentToday >= 0 && <Text color={DIM}> today</Text>}
        </Text>
        {g.branch && cols >= 130 && (
          <Text wrap="truncate-end" color={DIM}>
            {'  '}⎇ {g.branch}
            {g.changed > 0 && <Text color={secondary}> +{g.changed}</Text>}
          </Text>
        )}
      </Box>
    )

    return (
      <Box flexDirection="row" flexWrap="nowrap" justifyContent="space-between" paddingX={1} overflow="hidden">
        {left}
        {right}
      </Box>
    )
  })
}
