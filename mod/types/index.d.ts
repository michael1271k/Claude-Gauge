export type Limit = { kind: string; percentUsed: number; resetsAt?: string }
export type Chat = { state: string; at: number; label: string; question: string }

declare module 'claude-code' {
  interface PluginState {
    'usage-gauge': {
      limits: Limit[]
      usd: number
      today: number
      cwd: string
      model: { name: string; effort: string; alias: string; fallback: string }
      chat: Chat
      work: { start: number; steps: number }
      git: { branch: string; changed: number }
    }
  }
}
