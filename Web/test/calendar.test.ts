import { describe, expect, it } from 'vitest'
import { firstWeekday, gridDays, occurrences } from '../src/modules/maintenance/calendar'
import { deriveTask, type TaskFields } from '../src/modules/maintenance/schedule'

const day = (y: number, m: number, d: number, h = 0) => new Date(y, m - 1, d, h).getTime()
const fields = (o: Partial<TaskFields> = {}): TaskFields => ({
  itemUid: 'item', title: 'Task', intervalValue: 1, intervalUnit: 'month', scheduleKind: 'interval', anchorDate: null,
  repeats: true, isActive: true, baselineDoneAt: null, snoozedUntil: null, preferredDays: '', shiftedFrom: null,
  shiftedTo: null, assigneeUid: '', onceAssigneeUid: null, onceAssigneeAfter: null, createdAt: null, ...o,
})
const NOW = day(2026, 9, 22, 15)
const task = (uid: string, o: Partial<TaskFields>) => deriveTask(uid, fields({ title: uid, ...o }), [], NOW)
const days = (map: Map<number, { isProjected: boolean }[]>) =>
  [...map.entries()].sort((a, b) => a[0] - b[0]).map(([d, list]) => [new Date(d).getDate() + '/' + (new Date(d).getMonth() + 1), list.map((o) => o.isProjected)])

describe('calendar occurrences', () => {
  it('projects a fixed-date series from its own dates', () => {
    const t = task('fixed', { scheduleKind: 'fixedDate', anchorDate: day(2026, 9, 25), intervalUnit: 'week', intervalValue: 1 })
    const map = occurrences([t], day(2026, 9, 21), day(2026, 10, 12), NOW)
    expect(days(map)).toEqual([['25/9', [false]], ['2/10', [true]], ['9/10', [true]]])
  })

  it('keeps a preferred-day task on that day, first occurrence and projections alike', () => {
    // Weekly on Saturdays, last done Sat 19 Sep: every date the calendar shows is a Saturday.
    const t = task('chore', { intervalUnit: 'week', baselineDoneAt: day(2026, 9, 19), preferredDays: '7' })
    const map = occurrences([t], day(2026, 9, 21), day(2026, 10, 12), NOW)
    expect(days(map)).toEqual([['26/9', [false]], ['3/10', [true]], ['10/10', [true]]])
  })

  it('restarts an overdue interval task from today', () => {
    const t = task('late', { intervalUnit: 'week', baselineDoneAt: day(2026, 9, 1) }) // due 8 Sep
    const map = occurrences([t], day(2026, 9, 1), day(2026, 10, 12), NOW)
    expect(days(map)).toEqual([['22/9', [false]], ['29/9', [true]], ['6/10', [true]]])
    expect(map.get(day(2026, 9, 22))![0]!.isOverdue).toBe(true)
  })

  it('keeps an overdue fixed-date series on its own dates', () => {
    const t = task('fixedLate', { scheduleKind: 'fixedDate', anchorDate: day(2026, 9, 10), intervalUnit: 'week' })
    const map = occurrences([t], day(2026, 9, 1), day(2026, 10, 1), NOW)
    expect(days(map)).toEqual([['22/9', [false]], ['24/9', [true]]])
  })

  it('gives one-offs no projections and skips inactive tasks', () => {
    const once = task('once', { scheduleKind: 'fixedDate', anchorDate: day(2026, 9, 25), repeats: false, intervalUnit: 'day' })
    const paused = task('paused', { isActive: false })
    expect(days(occurrences([once, paused], day(2026, 9, 1), day(2026, 11, 1), NOW))).toEqual([['25/9', [false]]])
  })

  it('clamps month ends like Foundation, stepping from the base', () => {
    const t = task('eom', { scheduleKind: 'fixedDate', anchorDate: day(2026, 10, 31) })
    const map = occurrences([t], day(2026, 10, 1), day(2027, 4, 1), NOW)
    expect(days(map).map(([d]) => d)).toEqual(['31/10', '30/11', '31/12', '31/1', '28/2', '31/3'])
  })

  it('respects the range bounds (start inclusive, end exclusive)', () => {
    const t = task('daily', { intervalUnit: 'day', baselineDoneAt: day(2026, 9, 22, 9) }) // due 23 Sep
    const map = occurrences([t], day(2026, 9, 24), day(2026, 9, 27), NOW)
    expect(days(map)).toEqual([['24/9', [true]], ['25/9', [true]], ['26/9', [true]]])
    expect(occurrences([t], day(2026, 9, 23), day(2026, 9, 23), NOW).size).toBe(0)
  })

  it('sorts real before projected, then by title', () => {
    const a = task('B weekly', { intervalUnit: 'day', baselineDoneAt: day(2026, 9, 21) }) // due 22, then 23…
    const b = task('A due 23', { intervalUnit: 'day', baselineDoneAt: day(2026, 9, 22) })
    const c = task('Item 10', { intervalUnit: 'day', baselineDoneAt: day(2026, 9, 22) })
    const d = task('Item 2', { intervalUnit: 'day', baselineDoneAt: day(2026, 9, 22) })
    const list = occurrences([a, c, b, d], day(2026, 9, 23), day(2026, 9, 24), NOW).get(day(2026, 9, 23))!
    expect(list.map((o) => [o.task.title, o.isProjected])).toEqual([
      ['A due 23', false], ['Item 2', false], ['Item 10', false], ['B weekly', true],
    ])
  })
})

describe('grid', () => {
  it('has six weeks starting on the first weekday', () => {
    const grid = gridDays(day(2026, 9, 15), 1)
    expect(grid).toHaveLength(42)
    expect(grid[0]).toBe(day(2026, 8, 31))
    expect(new Date(grid[41]!).getDate()).toBe(11)
    expect(gridDays(day(2026, 3, 1), 0)[0]).toBe(day(2026, 3, 1))
  })

  it('starts weeks on Monday for en-GB and sl', () => {
    expect(firstWeekday('en-GB')).toBe(1)
    expect(firstWeekday('sl-SI')).toBe(1)
  })
})

describe('calendar hand-overs', () => {
  // Weekly, last done Sat 19 Sep, usually Bo's.
  const weekly = (o: Partial<TaskFields>) => task('mop', { intervalUnit: 'week', baselineDoneAt: day(2026, 9, 19), assigneeUid: 'bo', ...o })
  const who = (t: ReturnType<typeof task>) =>
    [...occurrences([t], day(2026, 9, 21), day(2026, 10, 12), NOW).entries()].sort((a, b) => a[0] - b[0]).map(([, l]) => l[0]!.assigneeUid)

  it('give only the real occurrence to the one-off person', () => {
    expect(who(weekly({ onceAssigneeUid: 'ana', onceAssigneeAfter: day(2026, 9, 19) }))).toEqual(['ana', 'bo', 'bo'])
  })

  it('ignore a hand-over made before the last completion', () => {
    expect(who(weekly({ onceAssigneeUid: 'ana', onceAssigneeAfter: day(2026, 9, 12) }))).toEqual(['bo', 'bo', 'bo'])
  })
})
