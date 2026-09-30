import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { decodeDate, encodeDate } from '../src/core/dates'
import { applyMerge, db, getMeta, resetDatabase, setMeta, write } from '../src/core/db'
import { compareByKindUid, decodeSnapshot } from '../src/core/snapshot'
import { assignOnce, markDone, moveOccurrence, undoMarkDone } from '../src/modules/maintenance/actions'
import { buildHousehold, currentAssignee, isFinished, TASK } from '../src/modules/maintenance/schedule'

const fixture = (name: string) => decodeSnapshot(readFileSync(join(__dirname, 'fixtures', name), 'utf8'))
const NOW = Date.UTC(2026, 8, 22, 12)

beforeEach(async () => {
  await resetDatabase()
  await setMeta('deviceId', 'D-TEST')
})

async function household(now = NOW) {
  return buildHousehold(await db.records.toArray(), now)
}

describe('local writes', () => {
  it('fill in every key of a kind', async () => {
    const uid = await write((w) => w.create(TASK, { title: 'Descale' }), NOW)
    const task = (await db.records.get(uid))!
    expect(Object.keys(task.data).sort()).toEqual(
      ['anchorDate', 'assigneeUid', 'baselineDoneAt', 'createdAt', 'intervalUnit', 'intervalValue', 'isActive', 'itemUid',
       'onceAssigneeAfter', 'onceAssigneeUid', 'preferredDays', 'repeats', 'scheduleKind', 'shiftedFrom', 'shiftedTo',
       'snoozedUntil', 'title'].sort(),
    )
    expect(task.modifiedBy).toBe('D-TEST')
    expect(task.modifiedAt).toBe(encodeDate(NOW))
  })

  it('stamp only when data changes, and keep unknown fields', async () => {
    await applyMerge([fixture('deviceB.json')])
    const before = (await db.records.get('task-filter'))!
    expect(before.data.priority).toBe('high')

    // Same values in a different key order: no stamp.
    const reordered = Object.fromEntries(Object.entries(before.data).reverse())
    expect(await write((w) => w.update('task-filter', () => reordered), NOW)).toBe(false)
    expect(await write((w) => w.update('task-filter', { snoozedUntil: null }), NOW)).toBe(false)
    expect(await db.records.get('task-filter')).toEqual(before)

    await write((w) => w.update('task-filter', { title: 'Clean the filter' }), NOW)
    const after = (await db.records.get('task-filter'))!
    expect(after.data.title).toBe('Clean the filter')
    expect(after.data.priority).toBe('high')
    expect(after.modifiedBy).toBe('D-TEST')
    expect(decodeDate(after.modifiedAt)!).toBeGreaterThan(decodeDate(before.modifiedAt)!)
  })

  it('never stamp below maxSeen, even with a slow clock', async () => {
    await applyMerge([fixture('deviceA.json'), fixture('deviceB.json')])
    const maxSeen = (await getMeta('maxSeen'))!
    expect(encodeDate(maxSeen)).toBe('2026-09-22T11:00:00.001Z')
    const slow = Date.UTC(2026, 0, 1)
    await write((w) => w.update('task-salt', { title: 'Salt' }), slow)
    expect((await db.records.get('task-salt'))!.modifiedAt).toBe('2026-09-22T11:00:00.002Z')
    expect(await getMeta('maxSeen')).toBe(maxSeen + 1)
  })

  it('cascade deletes to tasks and logs with tombstones', async () => {
    await applyMerge([fixture('deviceA.json'), fixture('deviceB.json')])
    await write((w) => w.delete('item-dishwasher'), NOW)
    const left = await db.records.toArray()
    expect(left.map((r) => r.uid).sort()).toEqual(['item-windows', 'person-ana', 'person-bostjan', 'shop-salt'])
    const tombs = new Set((await db.tombstones.toArray()).map((t) => t.uid))
    for (const uid of ['item-dishwasher', 'task-filter', 'task-salt', 'log-a1', 'log-b1']) expect(tombs.has(uid)).toBe(true)
  })
})

describe('merging into the replica', () => {
  it('does not re-stamp merged records', async () => {
    const A = fixture('deviceA.json')
    const B = fixture('deviceB.json')
    await applyMerge([A])
    await applyMerge([B])
    const expected = JSON.parse(readFileSync(join(__dirname, 'fixtures', 'merged.expected.json'), 'utf8'))
    expect((await db.records.toArray()).sort(compareByKindUid)).toEqual(expected.records)
    expect((await db.tombstones.toArray()).sort(compareByKindUid)).toEqual(expected.tombstones)
    expect(await applyMerge([A, B])).toEqual({ added: 0, updated: 0, removed: 0, byKind: {} })
  })
})

describe('moving an occurrence', () => {
  /** Midnight of a local day, the way due dates are stored. */
  const local = (y: number, m: number, d: number) => new Date(y, m - 1, d).getTime()

  /** Monthly, last done 1 Sep, so it falls due on 1 Oct with no preferred day. */
  async function monthly(extra: Record<string, unknown> = {}) {
    const uid = await write(
      (w) => w.create(TASK, { title: 'Descale', intervalUnit: 'month', baselineDoneAt: encodeDate(local(2026, 9, 1)), ...extra }),
      NOW,
    )
    return (await household()).tasksByUid.get(uid)!
  }

  it('this time only shifts the one occurrence and leaves the schedule alone', async () => {
    const task = await monthly()
    expect(task.nextDueAt).toBe(local(2026, 10, 1))
    await moveOccurrence(task, local(2026, 10, 4), 'thisOnce', NOW)
    const stored = (await db.records.get(task.uid))!
    expect(stored.data.shiftedFrom).toBe(encodeDate(local(2026, 10, 1)))
    expect(stored.data.shiftedTo).toBe(encodeDate(local(2026, 10, 4)))
    expect(stored.data.preferredDays).toBe('')
    expect((await household()).tasksByUid.get(task.uid)!.nextDueAt).toBe(local(2026, 10, 4))
  })

  it('all future puts an after-last-done task on the new weekday', async () => {
    const task = await monthly()
    // 3 Oct 2026 is a Saturday, and snapping from 1 Oct reaches it, so no shift is needed.
    await moveOccurrence(task, local(2026, 10, 3), 'allFuture', NOW)
    const stored = (await db.records.get(task.uid))!
    expect(stored.data.preferredDays).toBe('7')
    expect(stored.data.shiftedFrom).toBeNull()
    expect((await household()).tasksByUid.get(task.uid)!.nextDueAt).toBe(local(2026, 10, 3))
  })

  it('all future still carries an occurrence that snapping cannot reach', async () => {
    const task = await monthly()
    await moveOccurrence(task, local(2026, 10, 17), 'allFuture', NOW)
    const stored = (await db.records.get(task.uid))!
    expect(stored.data.preferredDays).toBe('7')
    // Snapping only reaches 3 Oct, so this occurrence is shifted the rest of the way.
    expect(stored.data.shiftedFrom).toBe(encodeDate(local(2026, 10, 3)))
    expect((await household()).tasksByUid.get(task.uid)!.nextDueAt).toBe(local(2026, 10, 17))
  })

  it('all future moves a whole fixed-date series by the same distance', async () => {
    const uid = await write(
      (w) => w.create(TASK, { title: 'Service', scheduleKind: 'fixedDate', anchorDate: encodeDate(local(2026, 10, 7)), intervalUnit: 'year' }),
      NOW,
    )
    const task = (await household()).tasksByUid.get(uid)!
    await moveOccurrence(task, local(2026, 10, 10), 'allFuture', NOW)
    const stored = (await db.records.get(uid))!
    expect(decodeDate(stored.data.anchorDate)).toBe(local(2026, 10, 10))
    expect(stored.data.preferredDays).toBe('')
  })

  it('marking done takes the shift with it', async () => {
    const task = await monthly()
    await moveOccurrence(task, local(2026, 10, 4), 'thisOnce', NOW)
    const shifted = (await household()).tasksByUid.get(task.uid)!
    await markDone(shifted, 'person-ana', NOW)
    const stored = (await db.records.get(task.uid))!
    expect(stored.data.shiftedFrom).toBeNull()
    expect(stored.data.shiftedTo).toBeNull()
  })

  it('all future falls back to this one when the series has nothing lasting to move', async () => {
    // Yearly and already done: the next one is a year after the last, so there is no weekday or
    // start date to keep. Only this occurrence can move.
    const uid = await write(
      (w) => w.create(TASK, { title: 'Bleed the radiators', intervalUnit: 'year', baselineDoneAt: encodeDate(local(2026, 3, 1)) }),
      NOW,
    )
    const task = (await household()).tasksByUid.get(uid)!
    expect(task.nextDueAt).toBe(local(2027, 3, 1))
    await moveOccurrence(task, local(2027, 3, 6), 'allFuture', NOW)
    const stored = (await db.records.get(uid))!
    expect(stored.data.preferredDays).toBe('')
    expect(stored.data.shiftedFrom).toBe(encodeDate(local(2027, 3, 1)))
    expect(stored.data.shiftedTo).toBe(encodeDate(local(2027, 3, 6)))
    expect((await household()).tasksByUid.get(uid)!.nextDueAt).toBe(local(2027, 3, 6))
  })

  it('a move to the day it is already due does nothing', async () => {
    const task = await monthly()
    const before = (await db.records.get(task.uid))!
    await moveOccurrence(task, local(2026, 10, 1), 'allFuture', NOW)
    expect(await db.records.get(task.uid)).toEqual(before)
  })
})

describe('mark done', () => {
  it('logs the completion by me and stamps the task only if it changed', async () => {
    await applyMerge([fixture('deviceA.json'), fixture('deviceB.json')])
    const before = (await db.records.get('task-filter'))!
    const task = (await household()).tasksByUid.get('task-filter')!
    const receipt = await markDone(task, 'person-ana', NOW)
    expect(await db.records.get('task-filter')).toEqual(before) // snoozedUntil was already null
    expect(receipt.previous).toEqual({})
    const log = (await db.records.get(receipt.logUid))!
    expect(log.data).toEqual({ taskUid: 'task-filter', completedAt: encodeDate(NOW), note: '', completedByUid: 'person-ana' })
    const after = (await household()).tasksByUid.get('task-filter')!
    expect(after.lastDoneAt).toBe(NOW)
  })

  it('clears a snooze, and undo tombstones the log and restores the task', async () => {
    await applyMerge([fixture('deviceB.json')])
    await write((w) => w.update('task-filter', { snoozedUntil: '2026-09-25T08:00:00.000Z' }), NOW - 5000)
    const snoozed = (await db.records.get('task-filter'))!
    const task = (await household()).tasksByUid.get('task-filter')!
    const receipt = await markDone(task, 'person-bostjan', NOW)
    expect((await db.records.get('task-filter'))!.data.snoozedUntil).toBeNull()
    await undoMarkDone(receipt)
    const restored = (await db.records.get('task-filter'))!
    expect(restored.data).toEqual(snoozed.data)
    expect(await db.records.get(receipt.logUid)).toBeUndefined()
    expect(await db.tombstones.get(receipt.logUid)).toBeDefined()
  })

  it('finishes a one-off fixed-date task, and undo makes it due again', async () => {
    const uid = await write((w) => w.create(TASK, { title: 'Service', scheduleKind: 'fixedDate', anchorDate: encodeDate(NOW), repeats: false }), NOW)
    const task = (await household()).tasksByUid.get(uid)!
    const receipt = await markDone(task, '', NOW + 1000)
    const done = (await household()).tasksByUid.get(uid)!
    expect(done.isActive).toBe(false)
    expect(isFinished(done)).toBe(true)
    await undoMarkDone(receipt)
    const again = (await household()).tasksByUid.get(uid)!
    expect(again.isActive).toBe(true)
    expect(again.logs).toHaveLength(0)
  })
})

describe('handing over one occurrence', () => {
  async function weekly() {
    const uid = await write(
      (w) => w.create(TASK, { title: 'Mop', intervalUnit: 'week', assigneeUid: 'person-bostjan', baselineDoneAt: encodeDate(NOW - 86_400_000) }),
      NOW,
    )
    return (await household()).tasksByUid.get(uid)!
  }

  it('gives just the next one to someone else, and marking done ends it', async () => {
    const task = await weekly()
    await assignOnce(task, 'person-ana', NOW)
    const stored = (await db.records.get(task.uid))!
    expect(stored.data.assigneeUid).toBe('person-bostjan')
    expect(stored.data.onceAssigneeUid).toBe('person-ana')
    expect(stored.data.onceAssigneeAfter).toBe(encodeDate(NOW - 86_400_000))
    const handed = (await household()).tasksByUid.get(task.uid)!
    expect(currentAssignee(handed)).toBe('person-ana')

    const receipt = await markDone(handed, 'person-ana', NOW + 1000)
    const after = (await household()).tasksByUid.get(task.uid)!
    expect(after.onceAssigneeUid).toBeNull()
    expect(currentAssignee(after)).toBe('person-bostjan')

    // Undo brings the hand-over back with the occurrence.
    await undoMarkDone(receipt)
    expect(currentAssignee((await household()).tasksByUid.get(task.uid)!)).toBe('person-ana')
  })

  it('picking the usual person takes it back', async () => {
    const task = await weekly()
    await assignOnce(task, '', NOW)
    expect(currentAssignee((await household()).tasksByUid.get(task.uid)!)).toBe('')
    await assignOnce((await household()).tasksByUid.get(task.uid)!, 'person-bostjan', NOW)
    const stored = (await db.records.get(task.uid))!
    expect(stored.data.onceAssigneeUid).toBeNull()
    expect(stored.data.onceAssigneeAfter).toBeNull()
  })

  it('lapses when someone else finishes the occurrence first', async () => {
    const task = await weekly()
    await assignOnce(task, 'person-ana', NOW)
    // A completion synced from another device, which knew nothing of the hand-over.
    await write((w) => w.create('taskLog', { taskUid: task.uid, completedAt: encodeDate(NOW + 1000), note: '', completedByUid: '' }), NOW + 1000)
    const after = (await household(NOW + 2000)).tasksByUid.get(task.uid)!
    expect(after.onceAssigneeUid).toBe('person-ana')
    expect(currentAssignee(after)).toBe('person-bostjan')
  })
})
