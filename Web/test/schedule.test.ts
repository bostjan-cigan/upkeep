import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { addCalendar, type Millis } from '../src/core/dates'
import {
  currentAssignee,
  deriveTask,
  describe as describeSchedule,
  dueStatus,
  dueStatusText,
  fixedDue,
  isFinished,
  lastCompletedOf,
  needsAttention,
  upNextBucket,
  type TaskFields,
  type TaskLog,
} from '../src/modules/maintenance/schedule'

const day = (y: number, m: number, d: number, h = 0, mi = 0) => new Date(y, m - 1, d, h, mi).getTime()

const fields = (o: Partial<TaskFields> = {}): TaskFields => ({
  itemUid: 'item',
  title: 'Task',
  intervalValue: 1,
  intervalUnit: 'month',
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
  createdAt: null,
  ...o,
})
const logs = (...dates: number[]): TaskLog[] =>
  dates.map((completedAt, i) => ({ uid: `log-${i}`, taskUid: 'task', completedAt, note: '', completedByUid: '' }))

describe('interval tasks', () => {
  const now = day(2026, 9, 22, 15)

  it('are due right away when never done', () => {
    const t = deriveTask('task', fields(), [], now)
    expect(t.lastDoneAt).toBeNull()
    expect(t.nextDueAt).toBe(day(2026, 9, 22))
    expect(needsAttention(t, now)).toBe(true)
  })

  it('are due one interval after the start of the last-done day', () => {
    const t = deriveTask('task', fields({ intervalValue: 3 }), logs(day(2026, 6, 10, 18, 30)), now)
    expect(t.nextDueAt).toBe(day(2026, 9, 10))
  })

  it('use the later of baseline and logs', () => {
    const baseline = day(2026, 9, 1, 9)
    const early = deriveTask('task', fields({ intervalUnit: 'week', baselineDoneAt: baseline }), logs(day(2026, 8, 20)), now)
    expect(early.lastDoneAt).toBe(baseline)
    expect(early.nextDueAt).toBe(day(2026, 9, 8))
    const late = deriveTask('task', fields({ intervalUnit: 'week', baselineDoneAt: baseline }), logs(day(2026, 9, 5, 20)), now)
    expect(late.nextDueAt).toBe(day(2026, 9, 12))
  })

  it('clamp at month ends', () => {
    const t = deriveTask('task', fields(), logs(day(2026, 1, 31, 12)), now)
    expect(t.nextDueAt).toBe(day(2026, 2, 28))
  })

  it('snoozing hides them until the snooze ends', () => {
    const t = deriveTask('task', fields({ snoozedUntil: day(2026, 9, 23, 15) }), [], now)
    expect(needsAttention(t, now)).toBe(false)
    expect(needsAttention(t, day(2026, 9, 23, 16))).toBe(true)
    expect(needsAttention(deriveTask('task', fields({ isActive: false }), [], now), now)).toBe(false)
  })
})

describe('fixed-date tasks', () => {
  const anchor = day(2026, 9, 15)
  const yearly = fields({ scheduleKind: 'fixedDate', anchorDate: anchor, intervalUnit: 'year' })
  const now = day(2026, 9, 22)

  it('are due on the anchor until done', () => {
    expect(deriveTask('task', yearly, [], now).nextDueAt).toBe(anchor)
  })

  it('count an early completion for the nearest date', () => {
    expect(deriveTask('task', yearly, logs(day(2026, 9, 1, 10)), now).nextDueAt).toBe(day(2027, 9, 15))
  })

  it('count a late completion for the date it was late for', () => {
    expect(deriveTask('task', yearly, logs(day(2026, 11, 20, 10)), now).nextDueAt).toBe(day(2027, 9, 15))
  })

  it('do not skip a date when done early twice or double one when done late', () => {
    // Done late for 2026, then early for 2027: next is 2028.
    expect(deriveTask('task', yearly, logs(day(2026, 10, 1), day(2027, 9, 1)), now).nextDueAt).toBe(day(2028, 9, 15))
    // Done twice within days of each other: the second one counts for the same (already covered) date.
    expect(deriveTask('task', yearly, logs(day(2026, 9, 14), day(2026, 9, 16)), now).nextDueAt).toBe(day(2027, 9, 15))
  })

  it('ignore completions long before the first date', () => {
    expect(fixedDue(day(2025, 9, 20), anchor, 1, 'year')).toBe(anchor)
    // Nearer the earlier date: it counts for that one.
    const monthly = day(2026, 1, 1)
    expect(fixedDue(day(2026, 1, 16, 23), monthly, 1, 'month')).toBe(day(2026, 2, 1))
  })

  it('catch up when done after several missed dates', () => {
    const monthly = day(2026, 1, 31)
    // Done on 20 May: nearest date is 31 May (step 4 from 31 Jan), so next is 30 Jun.
    expect(fixedDue(day(2026, 5, 20), monthly, 1, 'month')).toBe(day(2026, 6, 30))
    expect(fixedDue(day(2026, 5, 10), monthly, 1, 'month')).toBe(day(2026, 5, 31))
    expect(addCalendar(monthly, 'month', 4)).toBe(day(2026, 5, 31))
  })

  it('one-offs finish when done and are not rescheduled', () => {
    const once = fields({ scheduleKind: 'fixedDate', anchorDate: anchor, repeats: false, isActive: false })
    const t = deriveTask('task', once, logs(day(2026, 9, 15, 12)), now)
    expect(t.nextDueAt).toBe(anchor)
    expect(isFinished(t)).toBe(true)
    expect(needsAttention(t, now)).toBe(false)
    expect(isFinished(deriveTask('task', { ...once, isActive: true }, [], now))).toBe(false)
  })

  it('without an anchor fall back to the interval rules', () => {
    const t = deriveTask('task', fields({ scheduleKind: 'fixedDate', anchorDate: null }), logs(day(2026, 9, 1)), now)
    expect(t.nextDueAt).toBe(day(2026, 10, 1))
  })
})

describe('DueStatus.text', () => {
  const now = day(2026, 9, 22, 13)
  const text = (y: number, m: number, d: number) => dueStatusText(dueStatus(day(y, m, d), now))

  it('matches the Mac at every boundary', () => {
    expect(text(2026, 9, 21)).toBe('1 day overdue')
    expect(text(2026, 9, 20)).toBe('2 days overdue')
    expect(text(2026, 9, 9)).toBe('13 days overdue')
    expect(text(2026, 9, 8)).toBe('2 weeks overdue')
    expect(text(2026, 8, 1)).toBe('7 weeks overdue')
    expect(text(2026, 9, 22)).toBe('Due today')
    expect(dueStatusText(dueStatus(day(2026, 9, 22, 23, 59), now))).toBe('Due today')
    expect(text(2026, 9, 23)).toBe('Due tomorrow')
    expect(text(2026, 9, 29)).toBe('Due in 7 days')
    expect(text(2026, 9, 30)).toBe('In 8 days')
    expect(text(2026, 10, 5)).toBe('In 13 days')
    expect(text(2026, 10, 6)).toBe('In 2 weeks')
    expect(text(2026, 11, 20)).toBe('In 8 weeks')
    expect(text(2026, 11, 21)).toBe('In 2 months')
    expect(text(2028, 8, 21)).toBe('In 23 months')
    expect(text(2028, 8, 22)).toBe('In 1 years')
    expect(text(2030, 9, 22)).toBe('In 4 years')
  })

  it('counts calendar days across DST', () => {
    expect(dueStatusText(dueStatus(day(2026, 10, 26), day(2026, 10, 25, 1)))).toBe('Due tomorrow')
    expect(dueStatusText(dueStatus(day(2026, 3, 30), day(2026, 3, 28, 23)))).toBe('Due in 2 days')
  })
})

describe('describe()', () => {
  it('reads like the Mac', () => {
    expect(describeSchedule(1, 'month', null, true)).toBe('Every month')
    expect(describeSchedule(3, 'month', null, true)).toBe('Every 3 months')
    expect(describeSchedule(2, 'week', null, true)).toBe('Every 2 weeks')
    expect(describeSchedule(1, 'year', day(2026, 9, 15), true)).toBe('Every year on 15 Sep')
    expect(describeSchedule(2, 'year', day(2026, 9, 15), true)).toBe('Every 2 years on 15 Sep')
    expect(describeSchedule(1, 'month', day(2026, 9, 15), true)).toBe('Every month from 15 Sep')
    expect(describeSchedule(1, 'year', day(2026, 9, 15), false)).toBe('Once on 15 Sep 2026')
  })
})

// MARK: Cases shared with the Mac

/** One row of `fixtures/schedule.cases.json`, run here and by `Tests/Core/main.swift`. */
interface SharedCase {
  name: string
  scheduleKind: 'interval' | 'fixedDate'
  intervalValue: number
  intervalUnit: TaskFields['intervalUnit']
  repeats: boolean
  anchorDate: string | null
  baselineDoneAt: string | null
  completions: string[]
  preferredDays: string
  shiftedFrom: string | null
  shiftedTo: string | null
  now: string
  expectedDue: string
}

const shared = JSON.parse(readFileSync(new URL('./fixtures/schedule.cases.json', import.meta.url), 'utf8')) as {
  timeZone: string
  cases: SharedCase[]
}

/** "2026-09-22" or "2026-09-22 15:00", in the local zone the suite pins. */
const localFrom = (s: string): Millis => {
  const [datePart = '', timePart = ''] = s.split(' ')
  const [y = 0, m = 1, d = 1] = datePart.split('-').map(Number)
  const [h = 0, mi = 0] = timePart === '' ? [] : timePart.split(':').map(Number)
  return new Date(y, m - 1, d, h, mi).getTime()
}
const localOrNull = (s: string | null): Millis | null => (s === null ? null : localFrom(s))

describe('scheduling cases shared with the Mac', () => {
  it('runs in the time zone the cases are written for', () => {
    expect(process.env.TZ).toBe(shared.timeZone)
  })

  for (const c of shared.cases) {
    it(c.name, () => {
      const t = deriveTask(
        'task',
        fields({
          scheduleKind: c.scheduleKind,
          intervalValue: c.intervalValue,
          intervalUnit: c.intervalUnit,
          repeats: c.repeats,
          anchorDate: localOrNull(c.anchorDate),
          baselineDoneAt: localOrNull(c.baselineDoneAt),
          preferredDays: c.preferredDays,
          shiftedFrom: localOrNull(c.shiftedFrom),
          shiftedTo: localOrNull(c.shiftedTo),
        }),
        logs(...c.completions.map(localFrom)),
        localFrom(c.now),
      )
      expect(t.nextDueAt).toBe(localFrom(c.expectedDue))
    })
  }
})

// The same rule as `UpNextBucket.of` on the Mac (Tests/Core/main.swift), on the same week:
// Monday 21 → Sunday 27 September 2026, with "now" on the Wednesday.
describe('up next buckets', () => {
  const MONDAY_START = 1
  const wednesday = day(2026, 9, 23, 9)
  const bucket = (due: Millis, lastCompletedAt: Millis | null = null, isActive = true) =>
    upNextBucket({ nextDueAt: due, lastCompletedAt, isActive }, wednesday, MONDAY_START)

  it('is this week’s work', () => {
    expect(bucket(day(2026, 9, 21, 9))).toBe('overdue')
    expect(bucket(day(2026, 9, 23, 22))).toBe('today')
    expect(bucket(day(2026, 9, 27, 9))).toBe('thisWeek')
    expect(bucket(day(2026, 9, 28, 9))).toBe('hidden')
    expect(bucket(day(2026, 10, 23, 9))).toBe('hidden')
  })

  it('keeps what was ticked off this week', () => {
    expect(bucket(day(2026, 10, 23, 9), day(2026, 9, 23, 8))).toBe('done')
    expect(bucket(day(2026, 10, 23, 9), day(2026, 9, 21, 8))).toBe('done')
    expect(bucket(day(2026, 10, 23, 9), day(2026, 9, 19, 8))).toBe('hidden')
    // A daily chore done this morning comes round again tomorrow — but it's done for today.
    expect(bucket(day(2026, 9, 24, 9), day(2026, 9, 23, 8))).toBe('done')
    // Done yesterday and due again today: there's something to do, so it's back on the list.
    expect(bucket(day(2026, 9, 23, 9), day(2026, 9, 22, 8))).toBe('today')
    expect(bucket(day(2026, 9, 22, 9), day(2026, 9, 21, 8))).toBe('overdue')
  })

  it('shows a finished one-off as this week’s receipt, once', () => {
    expect(bucket(day(2026, 9, 23, 9), day(2026, 9, 23, 8), false)).toBe('done')
    expect(bucket(day(2026, 9, 23, 9), day(2026, 8, 1, 8), false)).toBe('hidden')
    expect(bucket(day(2026, 9, 23, 9), null, false)).toBe('hidden')
  })

  it('starts the week on the locale’s first day', () => {
    const SUNDAY_START = 0
    // With a Sunday-first week, Sunday the 27th is next week, not this one.
    expect(upNextBucket({ nextDueAt: day(2026, 9, 27, 9), lastCompletedAt: null, isActive: true }, wednesday, SUNDAY_START)).toBe('hidden')
  })

  it('counts only what was ticked off, not a "last done" typed in', () => {
    // "I just did these" on Monday: last done is this week, but nobody ticked it off.
    const added = deriveTask('task', fields({ intervalUnit: 'week', baselineDoneAt: day(2026, 9, 21, 10) }), [], wednesday)
    expect(added.lastDoneAt).toBe(day(2026, 9, 21, 10))
    expect(upNextBucket({ ...added, lastCompletedAt: lastCompletedOf(added) }, wednesday, MONDAY_START)).toBe('hidden')
    const ticked = deriveTask('task', fields({ intervalUnit: 'week' }), logs(day(2026, 9, 21, 10)), wednesday)
    expect(upNextBucket({ ...ticked, lastCompletedAt: lastCompletedOf(ticked) }, wednesday, MONDAY_START)).toBe('done')
  })
})

describe('handing over one occurrence', () => {
  const now = day(2026, 9, 22, 15)
  const done = day(2026, 9, 15, 18, 30)

  it('names the one-off person until the task is done again', () => {
    const t = deriveTask('task', fields({ assigneeUid: 'bo', onceAssigneeUid: 'ana', onceAssigneeAfter: done }), logs(done), now)
    expect(currentAssignee(t)).toBe('ana')
    const later = deriveTask('task', fields({ assigneeUid: 'bo', onceAssigneeUid: 'ana', onceAssigneeAfter: done }), logs(done, now), now)
    expect(currentAssignee(later)).toBe('bo')
  })

  it('can hand a never-done task to everyone', () => {
    const t = deriveTask('task', fields({ assigneeUid: 'bo', onceAssigneeUid: '', onceAssigneeAfter: null }), [], now)
    expect(currentAssignee(t)).toBe('')
    expect(currentAssignee(deriveTask('task', fields({ assigneeUid: 'bo', onceAssigneeUid: '' }), logs(done), now))).toBe('bo')
  })

  it('means nothing without a person', () => {
    expect(currentAssignee(deriveTask('task', fields({ assigneeUid: 'bo' }), [], now))).toBe('bo')
  })
})
