import { beforeEach, describe, expect, it } from 'vitest'
import { encodeDate, startOfDay } from '../src/core/dates'
import { db, getMeta, resetDatabase, setMeta, write } from '../src/core/db'
import { addPerson, removePerson, sameName, silence, twinOf, unsilence, updateReminders } from '../src/core/peopleEditing'
import { peopleFrom, PERSON } from '../src/core/people'
import { ITEM_TEMPLATES, missingSuggestions, searchTemplates, TEMPLATE_CATEGORIES } from '../src/modules/maintenance/catalog'
import { markDone } from '../src/modules/maintenance/actions'
import {
  addItem,
  addRoutineTask,
  adjustForm,
  deleteItem,
  draftFor,
  draftFromSuggestion,
  newTaskForm,
  previewDue,
  removeLog,
  renameRoom,
  rescheduleTask,
  saveTask,
  snooze,
  taskForm,
} from '../src/modules/maintenance/editing'
import { buildHousehold, isFinished, TASK } from '../src/modules/maintenance/schedule'

const local = (y: number, m: number, d: number, h = 0) => new Date(y, m - 1, d, h).getTime()
// Tuesday 22 September 2026, mid-afternoon.
const NOW = local(2026, 9, 22, 15)

beforeEach(async () => {
  await resetDatabase()
  await setMeta('deviceId', 'D-TEST')
})

async function household(now = NOW) {
  return buildHousehold(await db.records.toArray(), now)
}

describe('the catalog', () => {
  it('has every template in a known category', () => {
    const keys = new Set(TEMPLATE_CATEGORIES.map(([k]) => k))
    expect(ITEM_TEMPLATES).toHaveLength(45)
    for (const t of ITEM_TEMPLATES) expect(keys.has(t.category)).toBe(true)
  })

  it('searches names and tasks', () => {
    expect(searchTemplates('robot').map((t) => t.id)).toContain('robotvacuum')
    expect(searchTemplates('descale').length).toBeGreaterThan(0)
    expect(searchTemplates('zzz')).toEqual([])
  })

  it('suggests only what the routine lacks', () => {
    const all = missingSuggestions('dishwasher', [])
    const rest = missingSuggestions('dishwasher', ['clean the filter'])
    expect(rest).toHaveLength(all.length - 1)
  })
})

describe('adding an item', () => {
  it('creates the item and its chosen routine, starting the clock today', async () => {
    const dishwasher = ITEM_TEMPLATES.find((t) => t.id === 'dishwasher')!
    const tasks = dishwasher.suggestions.slice(0, 2).map((s) => ({ title: s.title, schedule: draftFromSuggestion(s, '7', NOW), assigneeUid: 'p-ana' }))
    const uid = await addItem({ name: ' Dishwasher ', icon: 'dishwasher', color: 'blue', room: 'Kitchen', notes: '' }, tasks, true, NOW)
    const h = await household()
    expect(h.itemsByUid.get(uid)!.name).toBe('Dishwasher')
    const made = h.tasksByItem.get(uid)!
    expect(made).toHaveLength(2)
    expect(made.every((t) => t.lastDoneAt === NOW && t.assigneeUid === 'p-ana')).toBe(true)
    // Monthly chores on Saturdays: a month after today, snapped to the nearest Saturday.
    expect(made[0]!.preferredDays).toBe('7')
    expect(new Date(made[0]!.nextDueAt).getDay()).toBe(6)
  })

  it('without "I just did these" puts them on the next chore day', async () => {
    const uid = await addItem({ name: 'Plants', icon: 'plant', color: 'green', room: '', notes: '' }, [{ title: 'Water', schedule: draftFor(1, 'week', '7', NOW), assigneeUid: '' }], false, NOW)
    const water = (await household()).tasksByItem.get(uid)![0]!
    expect(water.lastDoneAt).toBeNull()
    expect(water.nextDueAt).toBe(local(2026, 9, 26))
  })

  it('renames a room on every item in it, and deletes an item with its tasks', async () => {
    const a = await addItem({ name: 'A', icon: 'generic', color: 'blue', room: 'Kitchen', notes: '' }, [{ title: 'T', schedule: draftFor(1, 'month', '', NOW), assigneeUid: '' }], true, NOW)
    await addItem({ name: 'B', icon: 'generic', color: 'blue', room: 'Kitchen', notes: '' }, [], true, NOW)
    await renameRoom((await household()).items, 'Kitchen', ' Cuisine ', NOW)
    expect((await household()).items.map((i) => i.room)).toEqual(['Cuisine', 'Cuisine'])
    await deleteItem(a, NOW)
    const h = await household()
    expect(h.items.map((i) => i.name)).toEqual(['B'])
    expect(h.tasks).toHaveLength(0)
  })
})

describe('the task editor', () => {
  async function item() {
    return addItem({ name: 'Item', icon: 'generic', color: 'blue', room: '', notes: '' }, [], true, NOW)
  }

  it('adds a task last done on a chosen day, as the preview said', async () => {
    const itemUid = await item()
    const form = { ...newTaskForm(itemUid, '7', NOW), title: 'Descale', value: 2, unit: 'week' as const, lastDone: local(2026, 9, 15) }
    const preview = previewDue(form, NOW)
    const uid = await saveTask(null, form, NOW)
    const t = (await household()).tasksByUid.get(uid)!
    expect(t.baselineDoneAt).toBe(local(2026, 9, 15))
    expect(t.nextDueAt).toBe(preview)
    expect(t.nextDueAt).toBe(local(2026, 9, 26)) // two weeks on is Tue 29th; the nearest Saturday is the 26th
  })

  it('round-trips an existing task through the form unchanged', async () => {
    const itemUid = await item()
    const uid = await saveTask(null, { ...newTaskForm(itemUid, '17', NOW), title: 'Mop', value: 1, unit: 'week', startMode: 'firstDue', startDate: local(2026, 9, 26) }, NOW)
    const before = (await db.records.get(uid))!
    const t = (await household()).tasksByUid.get(uid)!
    await saveTask(t, taskForm(t, () => true, NOW), NOW + 1000)
    expect((await db.records.get(uid))!.data).toEqual(before.data)
  })

  it('switching to a date starts yearly and drops chore days a yearly job ignores', () => {
    const form = newTaskForm('i', '7', NOW)
    expect(form.preferredDays).toBe('7')
    const fixed = adjustForm(form, { ...form, kind: 'fixedDate' }, '7', false)
    expect(fixed.unit).toBe('year')
    expect(fixed.preferredDays).toBe('')
  })

  it('brings a finished one-off back when it gets a new date', async () => {
    const itemUid = await item()
    const uid = await saveTask(null, { ...newTaskForm(itemUid, '', NOW), title: 'Service', kind: 'fixedDate', fixedDate: startOfDay(NOW), repeats: false }, NOW)
    await markDone((await household()).tasksByUid.get(uid)!, '', NOW + 1000)
    const done = (await household()).tasksByUid.get(uid)!
    expect(isFinished(done)).toBe(true)
    await saveTask(done, { ...taskForm(done, () => true, NOW), fixedDate: local(2027, 9, 22) }, NOW + 2000)
    const again = (await household()).tasksByUid.get(uid)!
    expect(again.isActive).toBe(true)
    expect(again.nextDueAt).toBe(local(2027, 9, 22))
  })

  it('rescheduling clears a one-off move and keeps the history', async () => {
    const itemUid = await item()
    const uid = await addRoutineTask(itemUid, 'Filter', draftFor(1, 'month', '', NOW), '', NOW)
    await write((w) => w.update(uid, { shiftedFrom: encodeDate(local(2026, 10, 22)), shiftedTo: encodeDate(local(2026, 10, 25)) }), NOW)
    await rescheduleTask((await household()).tasksByUid.get(uid)!, draftFor(2, 'month', '', NOW), NOW)
    const t = (await household()).tasksByUid.get(uid)!
    expect(t.shiftedFrom).toBeNull()
    expect(t.intervalValue).toBe(2)
    expect(t.lastDoneAt).toBe(NOW)
  })

  it('snoozes for whole days from now', async () => {
    const itemUid = await item()
    const uid = await addRoutineTask(itemUid, 'Filter', draftFor(1, 'month', '', NOW), '', NOW)
    await snooze((await household()).tasksByUid.get(uid)!, 3, NOW)
    expect((await household()).tasksByUid.get(uid)!.snoozedUntil).toBe(local(2026, 9, 25, 15))
  })

  it('removing the only completion of a finished one-off makes it due again', async () => {
    const itemUid = await item()
    const uid = await saveTask(null, { ...newTaskForm(itemUid, '', NOW), title: 'Service', kind: 'fixedDate', fixedDate: startOfDay(NOW), repeats: false }, NOW)
    const receipt = await markDone((await household()).tasksByUid.get(uid)!, '', NOW + 1000)
    await removeLog((await household()).tasksByUid.get(uid)!, receipt.logUid, NOW + 2000)
    const t = (await household()).tasksByUid.get(uid)!
    expect(t.logs).toHaveLength(0)
    expect(t.isActive).toBe(true)
    expect(await db.tombstones.get(receipt.logUid)).toBeDefined()
  })

  it('new tasks carry every key, like the Mac writes them', async () => {
    const itemUid = await item()
    const uid = await addRoutineTask(itemUid, 'Filter', draftFor(1, 'month', '', NOW), '', NOW)
    const stored = (await db.records.get(uid))!
    expect(stored.kind).toBe(TASK)
    expect(stored.data.createdAt).toBe(encodeDate(NOW))
    expect(stored.data.onceAssigneeUid).toBeNull()
  })
})

describe('people', () => {
  it('reads names the way people do', () => {
    expect(sameName('Ana', ' aña ')).toBe(true)
    expect(sameName('Ana', 'Anna')).toBe(false)
    expect(sameName('', '')).toBe(false)
    expect(twinOf('ANA', [{ uid: 'a', name: 'Ana', color: 'blue', choreDays: '', reminders: {} as never }])?.uid).toBe('a')
  })

  it('edits reminders without losing ones a newer build added', async () => {
    const uid = await addPerson('Ana', 'pink', NOW)
    await write((w) => w.update(uid, (d) => ({ ...d, reminders: { ...(d.reminders as object), quietWeekends: true } })), NOW)
    await updateReminders(uid, { nagHours: 6, workEnabled: true }, NOW)
    await silence(uid, 1, NOW)
    const record = (await db.records.get(uid))!
    const reminders = record.data.reminders as Record<string, unknown>
    expect(reminders.quietWeekends).toBe(true)
    expect(reminders.nagHours).toBe(6)
    expect(reminders.silencedUntil).toBe(encodeDate(local(2026, 9, 23, 15)))
    await unsilence(uid, NOW)
    expect(peopleFrom(await db.records.toArray())[0]!.reminders.silencedUntil).toBeNull()
  })

  it('removing me forgets who I am on this device', async () => {
    const uid = await addPerson('Ana', 'pink', NOW)
    await setMeta('myPersonUid', uid)
    await removePerson(uid, uid, NOW)
    expect(await getMeta('myPersonUid')).toBe('')
    expect((await db.records.toArray()).filter((r) => r.kind === PERSON)).toHaveLength(0)
  })
})
