import { describe, expect, it } from 'vitest'
import { reminderSenders, remindersFooter } from '../src/core/macs'
import type { SyncRecord } from '../src/core/snapshot'

const rec = (kind: string, uid: string, data: SyncRecord['data']): SyncRecord => ({ kind, uid, modifiedAt: '2026-09-27T10:00:00.000Z', modifiedBy: 'M', data })
const macs = [
  rec('mac', 'mac-b', { name: 'Bostjan’s MacBook', sendsReminders: false }),
  rec('mac', 'mac-t', { name: 'Tjaša’s MacBook Air', sendsReminders: true }),
  rec('mac', 'mac-k', { name: 'Kitchen iMac', sendsReminders: true }),
]
const sub = rec('pushSubscription', 'phone-1', { pairedMacId: 'mac-b', personUid: 'p1', endpoint: 'https://push.example/1' })

describe('who sends a phone its reminders', () => {
  it('names the usual Mac and the ones that step in', () => {
    const senders = reminderSenders([...macs, sub], 'phone-1')
    expect(senders).toEqual({ usual: 'Bostjan’s MacBook', backups: ['Kitchen iMac', 'Tjaša’s MacBook Air'] })
    expect(remindersFooter(senders, 'your Mac')).toBe(
      'Reminders come from Bostjan’s MacBook. When it’s asleep or away, Kitchen iMac and Tjaša’s MacBook Air send them.',
    )
  })

  it('a usual Mac that helps too is not its own backup', () => {
    const paired = rec('pushSubscription', 'phone-2', { pairedMacId: 'mac-t' })
    expect(reminderSenders([...macs, paired], 'phone-2')?.backups).toEqual(['Kitchen iMac'])
  })

  it('says how to get a backup when there is none', () => {
    const senders = reminderSenders([macs[0]!, sub], 'phone-1')
    expect(remindersFooter(senders, 'your Mac')).toContain('turn on Settings › Phones › Also send reminders… on another Mac')
  })

  it('falls back to the paired Mac’s name before any Mac shares the subscription', () => {
    expect(reminderSenders(macs, 'phone-1')).toBeNull()
    expect(remindersFooter(null, 'Bostjan’s MacBook')).toMatch(/^Reminders come from Bostjan’s MacBook while it’s on and awake/)
  })
})
