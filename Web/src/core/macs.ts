// The household's Macs and which of them send this phone its reminders (Docs/Sync.md › Phone
// notifications). Read from the `mac` and `pushSubscription` records the Macs share; the phone
// never writes them.
import type { SyncRecord } from './snapshot'

export const MAC = 'mac'
export const PUSH_SUBSCRIPTION = 'pushSubscription'

export interface ReminderSenders {
  /** The Mac this phone paired with, which sends on time; null when it's gone. */
  usual: string | null
  /** Macs that send when the usual one hasn't. */
  backups: string[]
}

const text = (v: unknown) => (typeof v === 'string' ? v : '')

/** Who sends this phone its reminders, or null before any Mac has shared its subscription. */
export function reminderSenders(records: readonly SyncRecord[], phoneId: string): ReminderSenders | null {
  const sub = records.find((r) => r.kind === PUSH_SUBSCRIPTION && r.uid === phoneId)
  if (!sub) return null
  const paired = text(sub.data.pairedMacId)
  const macs = records.filter((r) => r.kind === MAC)
  const name = (r: SyncRecord) => text(r.data.name) || 'a Mac'
  const usual = macs.find((m) => m.uid === paired)
  const backups = macs
    .filter((m) => m.uid !== paired && m.data.sendsReminders === true)
    .map(name)
    .sort((a, b) => a.localeCompare(b))
  return { usual: usual ? name(usual) : null, backups }
}

function list(names: string[]): string {
  if (names.length <= 1) return names[0] ?? ''
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`
}

/** The Notifications footer once reminders are on: who sends them, and who steps in. */
export function remindersFooter(senders: ReminderSenders | null, macName: string): string {
  const usual = senders?.usual ?? macName
  if (senders && senders.backups.length) {
    const backups = senders.backups
    return `Reminders come from ${usual}. When it’s asleep or away, ${list(backups)} ${backups.length === 1 ? 'sends' : 'send'} them.`
  }
  return `Reminders come from ${usual} while it’s on and awake. To keep them coming when it isn’t, turn on Settings › Phones › Also send reminders… on another Mac.`
}
