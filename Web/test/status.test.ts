// What the phone tells you about its link to the Mac (src/core/status.ts): one reading, used by
// the indicator in the navigation bar and by Settings.
import { describe, expect, it } from 'vitest'
import { syncStatus, type SyncInputs } from '../src/core/status'
import type { LanState } from '../src/core/sync'

const NOW = Date.UTC(2026, 8, 22, 12)

const lan = (status: LanState['status'], extra: Partial<LanState> = {}): LanState => ({ status, at: NOW, ...extra })

function status(overrides: Partial<SyncInputs> = {}) {
  return syncStatus({ lan: lan('ok'), paired: true, online: true, macName: 'Ana’s Mac', lastLanSync: NOW - 120_000, now: NOW, ...overrides })
}

describe('syncStatus', () => {
  it('says the device is at home once the Mac has answered', () => {
    const s = status()
    expect(s.kind).toBe('connected')
    expect(s.tone).toBe('ok')
    expect(s.detail).toBe('Connected to Ana’s Mac · last synced 2 min ago')
  })

  it('shows the round trip an edit sets off, then that it landed', () => {
    expect(status({ lan: lan('pending') })).toMatchObject({ kind: 'pending', label: 'Saving…', tone: 'busy' })
    expect(status({ lan: lan('syncing') })).toMatchObject({ kind: 'syncing', label: 'Syncing…', tone: 'busy' })
    const landed = status({ justSynced: true, lan: lan('ok', { lastSummary: { added: 1, updated: 2, removed: 0, byKind: {} } }) })
    expect(landed).toMatchObject({ kind: 'synced', label: 'Synced', tone: 'ok' })
    expect(landed.hint).toContain('3 changes')
  })

  it('tells a phone with no network apart from one that is simply elsewhere', () => {
    const offline = status({ online: false, lan: lan('unreachable') })
    expect(offline).toMatchObject({ kind: 'offline', label: 'Offline' })
    expect(offline.detail).toBe('Offline · last synced 2 min ago')

    const away = status({ lan: lan('unreachable') })
    expect(away).toMatchObject({ kind: 'away', label: 'Away' })
    expect(away.hint).toContain('Ana’s Mac')
  })

  it('marks changes the household hasn’t seen, and never while they are on their way', () => {
    expect(status({ lan: lan('unreachable'), pendingChanges: true }).waiting).toBe(true)
    expect(status({ lan: lan('syncing'), pendingChanges: true }).waiting).toBe(false)
  })

  it('asks for pairing before anything else, and keeps the Mac’s own words on a problem', () => {
    expect(status({ paired: false, lan: lan('ok') }).kind).toBe('notPaired')
    const problem = status({ lan: lan('macNeedsUpdate', { message: 'Update Upkeep on your Mac.' }) })
    expect(problem).toMatchObject({ kind: 'problem', tone: 'warn', detail: 'Update Upkeep on your Mac.' })
  })

  it('stands aside for the sample household', () => {
    const s = status({ demo: true, paired: false, lan: lan('unreachable') })
    expect(s).toMatchObject({ kind: 'demo', label: 'Demo', waiting: false })
    expect(s.hint).toContain('sample household')
  })

  it('has nothing to say about a sync that never happened', () => {
    expect(status({ lastLanSync: undefined, lan: lan('idle') }).detail).toBe('Away from home')
    expect(status({ lastLanSync: undefined, lan: lan('idle') }).since).toBe('Not synced yet')
    expect(status({ lastLanSync: undefined }).detail).toBe('Connected to Ana’s Mac')
  })
})
