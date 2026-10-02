// The sample household — a household as a Mac would send it, merged in like a LAN sync — and the
// big red button next to it. Both are reachable from Settings once the developer options are
// unlocked, so Upkeep can be shown to someone without a Mac in the room, and handed back empty.
import { addCalendar, encodeDate, startOfDay } from '../core/dates'
import { applyMerge, resetDatabase, setMeta } from '../core/db'
import { DEFAULT_CHORE_DAYS, DEFAULT_REMINDERS } from '../core/people'
import { disablePush } from '../core/push'
import type { JsonObject, SyncRecord } from '../core/snapshot'
import { setBadge } from './badge'

const MAC = 'DEMO0000-0000-4000-8000-00000000MAC0'

export async function loadDemoData(): Promise<void> {
  const now = Date.now()
  const stamp = encodeDate(now - 60_000)
  const today = startOfDay(now)
  const daysAgo = (d: number, hour = 10) => addCalendar(today, 'day', -d) + hour * 3_600_000
  const records: SyncRecord[] = []
  const add = (kind: string, uid: string, data: JsonObject) => records.push({ kind, uid, modifiedAt: stamp, modifiedBy: MAC, data })

  const reminders = { ...DEFAULT_REMINDERS, silencedUntil: null }
  add('person', 'demo-ana', { name: 'Ana', colorKey: 'teal', choreDays: DEFAULT_CHORE_DAYS, reminders })
  add('person', 'demo-bostjan', {
    name: 'Boštjan',
    colorKey: 'indigo',
    choreDays: '7',
    reminders: { ...reminders, workEnabled: true },
  })

  const item = (uid: string, name: string, iconKey: string, colorKey: string, room: string, notes = '') =>
    add('homeItem', uid, { name, iconKey, colorKey, room, notes, createdAt: encodeDate(daysAgo(120)) })
  item('demo-dishwasher', 'Dishwasher', 'dishwasher', 'blue', 'Kitchen', 'Bosch SMV4. Salt and rinse aid under the sink.')
  item('demo-coffee', 'Coffee Machine', 'coffee', 'brown', 'Kitchen')
  item('demo-fridge', 'Fridge', 'fridge', 'indigo', 'Kitchen')
  item('demo-shower', 'Shower & Bath', 'shower', 'teal', 'Bathroom')
  item('demo-vacuum', 'Robot Vacuum', 'vacuum', 'purple', '')
  item('demo-smoke', 'Smoke Detector', 'smoke', 'red', 'Hallway')
  item('demo-plants', 'Plants', 'plant', 'green', 'Living Room')
  item('demo-boiler', 'Heating', 'radiator', 'red', '')

  const task = (uid: string, itemUid: string, title: string, value: number, unit: string, o: JsonObject = {}) =>
    add('task', uid, {
      itemUid,
      title,
      intervalValue: value,
      intervalUnit: unit,
      scheduleKind: 'interval',
      anchorDate: null,
      repeats: true,
      isActive: true,
      baselineDoneAt: null,
      snoozedUntil: null,
      preferredDays: '',
      shiftedFrom: null,
      shiftedTo: null,
      assigneeUid: '',
      onceAssigneeUid: null,
      onceAssigneeAfter: null,
      createdAt: encodeDate(daysAgo(120)),
      ...o,
    })
  const log = (uid: string, taskUid: string, completedAt: number, by = '', note = '') =>
    add('taskLog', uid, { taskUid, completedAt: encodeDate(completedAt), note, completedByUid: by })

  task('demo-t-filter', 'demo-dishwasher', 'Clean the filter', 1, 'month', { assigneeUid: 'demo-ana' })
  log('demo-l-1', 'demo-t-filter', daysAgo(34), 'demo-ana')
  log('demo-l-2', 'demo-t-filter', daysAgo(65), 'demo-bostjan', 'Was really dirty')
  task('demo-t-salt', 'demo-dishwasher', 'Refill salt & rinse aid', 1, 'month', { baselineDoneAt: encodeDate(daysAgo(30)) })
  task('demo-t-arms', 'demo-dishwasher', 'Clean the spray arms', 3, 'month', { baselineDoneAt: encodeDate(daysAgo(40)) })
  task('demo-t-descale', 'demo-coffee', 'Descale', 2, 'month', { assigneeUid: 'demo-bostjan' })
  log('demo-l-3', 'demo-t-descale', daysAgo(58), 'demo-bostjan')
  task('demo-t-brew', 'demo-coffee', 'Rinse the brew group', 1, 'week', { baselineDoneAt: encodeDate(daysAgo(3)) })
  task('demo-t-expired', 'demo-fridge', 'Toss expired food', 1, 'week', { snoozedUntil: encodeDate(now + 2 * 86_400_000) })
  log('demo-l-4', 'demo-t-expired', daysAgo(9), 'demo-ana')
  task('demo-t-coils', 'demo-fridge', 'Vacuum the condenser coils', 6, 'month', { isActive: false })
  task('demo-t-scrub', 'demo-shower', 'Scrub shower & tub', 1, 'week', { assigneeUid: 'demo-bostjan', preferredDays: '7' })
  log('demo-l-5', 'demo-t-scrub', daysAgo(6), 'demo-bostjan')
  task('demo-t-head', 'demo-shower', 'Descale the shower head', 3, 'month', { baselineDoneAt: encodeDate(daysAgo(100)) })
  task('demo-t-bin', 'demo-vacuum', 'Empty the dust bin', 3, 'day')
  log('demo-l-6', 'demo-t-bin', daysAgo(2), 'demo-ana')
  task('demo-t-brushes', 'demo-vacuum', 'Untangle the main & side brushes', 2, 'week', {
    baselineDoneAt: encodeDate(daysAgo(20)),
    preferredDays: '17',
  })
  task('demo-t-test', 'demo-smoke', 'Test the alarm', 1, 'month', { baselineDoneAt: encodeDate(daysAgo(12)) })
  task('demo-t-battery', 'demo-smoke', 'Replace the battery', 1, 'year', {
    scheduleKind: 'fixedDate',
    anchorDate: encodeDate(addCalendar(today, 'day', 23)),
  })
  task('demo-t-water', 'demo-plants', 'Water', 1, 'week', { assigneeUid: 'demo-ana' })
  log('demo-l-7', 'demo-t-water', daysAgo(7, 18), 'demo-ana')
  task('demo-t-service', 'demo-boiler', 'Boiler service', 1, 'year', {
    scheduleKind: 'fixedDate',
    repeats: false,
    anchorDate: encodeDate(addCalendar(today, 'day', -40)),
    isActive: false,
  })
  log('demo-l-8', 'demo-t-service', daysAgo(38), 'demo-bostjan', 'Technician came')
  task('demo-t-bleed', 'demo-boiler', 'Bleed the radiators', 1, 'year', { baselineDoneAt: encodeDate(daysAgo(380)) })

  // An unknown kind from a newer build, to show it survives.
  add('shoppingEntry', 'demo-shop-salt', { listUid: 'demo-list', title: 'Dishwasher salt', quantity: 2, checked: false })

  await applyMerge([{ records, tombstones: [] }])
  await setMeta('macName', 'Demo MacBook Air')
}

/**
 * Turns this device into a demo: everything on it is erased first, so the sample household never
 * mixes with a real one, and nothing is paired — demo items can't reach anybody's Mac.
 */
export async function enterDemoMode(): Promise<void> {
  await eraseDevice()
  await loadDemoData()
  await setMeta('demoMode', true)
  await setMeta('onboarded', true)
  await setMeta('myPersonUid', 'demo-ana')
  await setMeta('deviceName', 'Demo iPhone')
}

/**
 * Wipes this device back to a fresh install: the replica, the pairing, who you are, the
 * reminders it receives and its own preferences. The household itself is untouched — every other
 * device still has it, and this one can pair again and sync it back.
 */
export async function eraseDevice(): Promise<void> {
  // Best effort, and before the token goes: otherwise the Mac keeps pushing to a dead app. It
  // talks to the Mac, so it's capped — a device being wiped away from home shouldn't wait.
  await Promise.race([disablePush().catch(() => undefined), new Promise((resolve) => setTimeout(resolve, 1500))])
  await resetDatabase()
  try {
    for (const key of Object.keys(localStorage)) if (key.startsWith('upkeep.')) localStorage.removeItem(key)
    sessionStorage.removeItem('upkeep.installSkipped')
  } catch {
    // Private mode: nothing was stored anyway.
  }
  setBadge(0)
}
