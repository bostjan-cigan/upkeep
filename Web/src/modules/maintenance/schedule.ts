// Scheduling and derived task fields (Docs/Sync.md › task, ported from Models.swift).
import {
  addCalendar,
  addDays,
  calendarDaysBetween,
  decodeDate,
  formatDate,
  formatDayMonth,
  startOfDay,
  startOfWeek,
  weekday,
  type Millis,
} from '../../core/dates'
import { peopleFrom, tileColor, type Person, type TileColor } from '../../core/people'
import { registerCollection, registerDerived } from '../../core/registry'
import type { JsonValue, SyncRecord } from '../../core/snapshot'
import { iconKey, type IconKey, type IntervalUnit } from './catalog'

export const HOME_ITEM = 'homeItem'
export const TASK = 'task'
export const TASK_LOG = 'taskLog'

registerCollection({
  kind: HOME_ITEM,
  defaults: () => ({ name: '', iconKey: 'generic', colorKey: 'blue', notes: '', room: '', createdAt: null }),
  children: [{ kind: TASK, foreignKey: 'itemUid' }],
})
registerCollection({
  kind: TASK,
  defaults: () => ({
    itemUid: '',
    title: '',
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
  }),
  children: [{ kind: TASK_LOG, foreignKey: 'taskUid' }],
})
registerCollection({
  kind: TASK_LOG,
  defaults: () => ({ taskUid: '', completedAt: null, note: '', completedByUid: '' }),
})

export type ScheduleKind = 'interval' | 'fixedDate'

export interface HomeItem {
  uid: string
  name: string
  icon: IconKey
  color: TileColor
  notes: string
  room: string
  createdAt: Millis | null
}

export interface TaskLog {
  uid: string
  taskUid: string
  completedAt: Millis
  note: string
  completedByUid: string
}

export interface TaskFields {
  itemUid: string
  title: string
  intervalValue: number
  intervalUnit: IntervalUnit
  scheduleKind: ScheduleKind
  anchorDate: Millis | null
  repeats: boolean
  isActive: boolean
  baselineDoneAt: Millis | null
  snoozedUntil: Millis | null
  /** Days of the week this task prefers, as `Weekdays` digits. Empty means any day. */
  preferredDays: string
  /** A one-off move of a single occurrence: the due date it was made against, and where it went. */
  shiftedFrom: Millis | null
  shiftedTo: Millis | null
  assigneeUid: string
  /** A one-off hand-over of the next occurrence ("" = everyone; null = none), and the last completion
   * it was made after. It only counts until the task is done again. */
  onceAssigneeUid: string | null
  onceAssigneeAfter: Millis | null
  createdAt: Millis | null
}

export interface Task extends TaskFields {
  uid: string
  // Derived, never synced.
  logs: TaskLog[]
  lastDoneAt: Millis | null
  nextDueAt: Millis
}

// MARK: Reading records (tolerant, never normalising stored data)

const str = (v: JsonValue | undefined, d = '') => (typeof v === 'string' ? v : d)
const bool = (v: JsonValue | undefined, d: boolean) => (typeof v === 'boolean' ? v : d)
const int = (v: JsonValue | undefined, d: number) => (typeof v === 'number' && Number.isFinite(v) ? Math.trunc(v) : d)

export function intervalUnit(value: unknown): IntervalUnit {
  return value === 'day' || value === 'week' || value === 'month' || value === 'year' ? value : 'month'
}

export function itemFrom(r: SyncRecord): HomeItem {
  return {
    uid: r.uid,
    name: str(r.data.name),
    icon: iconKey(r.data.iconKey),
    color: tileColor(r.data.colorKey),
    notes: str(r.data.notes),
    room: str(r.data.room),
    createdAt: decodeDate(r.data.createdAt),
  }
}

export function taskFieldsFrom(r: SyncRecord): TaskFields {
  const d = r.data
  return {
    itemUid: str(d.itemUid),
    title: str(d.title),
    intervalValue: int(d.intervalValue, 1),
    intervalUnit: intervalUnit(d.intervalUnit),
    scheduleKind: d.scheduleKind === 'fixedDate' ? 'fixedDate' : 'interval',
    anchorDate: decodeDate(d.anchorDate),
    repeats: bool(d.repeats, true),
    isActive: bool(d.isActive, true),
    baselineDoneAt: decodeDate(d.baselineDoneAt),
    snoozedUntil: decodeDate(d.snoozedUntil),
    preferredDays: str(d.preferredDays),
    shiftedFrom: decodeDate(d.shiftedFrom),
    shiftedTo: decodeDate(d.shiftedTo),
    assigneeUid: str(d.assigneeUid),
    onceAssigneeUid: typeof d.onceAssigneeUid === 'string' ? d.onceAssigneeUid : null,
    onceAssigneeAfter: decodeDate(d.onceAssigneeAfter),
    createdAt: decodeDate(d.createdAt),
  }
}

export function logFrom(r: SyncRecord): TaskLog | null {
  const completedAt = decodeDate(r.data.completedAt)
  if (completedAt === null) return null
  return {
    uid: r.uid,
    taskUid: str(r.data.taskUid),
    completedAt,
    note: str(r.data.note),
    completedByUid: str(r.data.completedByUid),
  }
}

// MARK: Preferred days

// Weekday sets, stored as digit strings of `Calendar` weekdays (1 = Sunday … 7 = Saturday).
// Empty means "any day". Used for a person's chore days and for a task's preferred days.

export const WEEKDAYS_ANY = ''
export const WEEKDAYS_WEEKEND = '17'

export function weekdaySet(digits: string): Set<number> {
  const days = new Set<number>()
  for (const ch of digits) {
    const n = Number(ch)
    if (Number.isInteger(n) && n >= 1 && n <= 7) days.add(n)
  }
  return days
}

export function weekdayString(days: Iterable<number>): string {
  return [...new Set(days)].sort((a, b) => a - b).join('')
}

/** 2024-01-07 was a Sunday, so day 1 lands on it. */
function weekdayName(day: number, style: 'long' | 'short'): string {
  const date = new Date(Date.UTC(2024, 0, 6 + day))
  return new Intl.DateTimeFormat(undefined, { weekday: style, timeZone: 'UTC' }).format(date)
}

/** "Saturdays", "weekends", "weekdays", "Sun & Wed" — null when any day will do. */
export function weekdaysLabel(digits: string): string | null {
  const days = [...weekdaySet(digits)].sort((a, b) => a - b)
  if (days.length === 0 || days.length === 7) return null
  const key = days.join('')
  if (key === '17') return 'weekends'
  if (key === '23456') return 'weekdays'
  const only = days.length === 1 ? days[0] : undefined
  if (only !== undefined) return `${weekdayName(only, 'long')}s`
  return days.map((d) => weekdayName(d, 'short')).join(' & ')
}

/**
 * Offsets tried when moving a due date onto a preferred day: nearest first, ties preferring the
 * later day, and reaching far enough forward to find one even when the nearer days are past.
 */
const SNAP_OFFSETS = [0, 1, -1, 2, -2, 3, -3, 4, 5, 6]

/**
 * A preferred day only makes sense for work that comes round at least weekly. A fixed date is
 * about the date itself, and a daily chore can't wait for Saturday.
 */
export function snaps(kind: ScheduleKind, value: number, unit: IntervalUnit): boolean {
  if (kind === 'fixedDate') return false
  if (unit === 'day' && value < 7) return false
  return true
}

/**
 * Moves `due` onto the nearest preferred weekday, so a chore lands on the day the household
 * actually does chores rather than wherever the interval happened to put it. A due date already
 * in the past stays put: overdue is overdue, and nothing is ever pushed further away from today.
 */
export function snap(due: Millis, preferredDays: string, kind: ScheduleKind, value: number, unit: IntervalUnit, now: Millis): Millis {
  if (!snaps(kind, value, unit)) return due
  const days = weekdaySet(preferredDays)
  if (days.size === 0) return due
  const today = startOfDay(now)
  if (due < today) return due
  for (const offset of SNAP_OFFSETS) {
    const day = addDays(due, offset)
    if (day < today) continue
    if (days.has(weekday(day))) return day
  }
  return due
}

/**
 * The preferred days a new task starts with: the person's chore days for ordinary chores, none
 * for anything rare enough that the date matters more than the day, such as a yearly AC service.
 */
export function suggestedDays(value: number, unit: IntervalUnit, kind: ScheduleKind, choreDays: string): string {
  if (!snaps(kind, value, unit)) return WEEKDAYS_ANY
  if (unit === 'year') return WEEKDAYS_ANY
  if (unit === 'month' && value >= 3) return WEEKDAYS_ANY
  return choreDays
}

/**
 * Whether a day of the week is the natural way to describe this schedule. True for ordinary
 * chores, false for anything rare enough that the date matters more than the day.
 */
export function prefersWeekday(kind: ScheduleKind, value: number, unit: IntervalUnit): boolean {
  return suggestedDays(value, unit, kind, '1234567') !== WEEKDAYS_ANY
}

/** Whether a day of the week is the lasting way to move this task: one it has, or one it would take. */
export function movesByWeekday(t: Pick<TaskFields, 'scheduleKind' | 'intervalValue' | 'intervalUnit' | 'preferredDays'>): boolean {
  if (!snaps(t.scheduleKind, t.intervalValue, t.intervalUnit)) return false
  return t.preferredDays !== WEEKDAYS_ANY || prefersWeekday(t.scheduleKind, t.intervalValue, t.intervalUnit)
}

/**
 * Whether "this and all future" can really change the series. A fixed date moves its dates and a
 * task never done yet moves its start date; an after-last-done task only keeps a day of the week,
 * so for a rare one — bleed the radiators once a year — there's nothing lasting to change.
 */
export function canMoveSeries(t: Task): boolean {
  if (t.scheduleKind === 'fixedDate' && t.anchorDate !== null) return true
  if (t.lastDoneAt === null) return true
  return movesByWeekday(t)
}

// MARK: Derived fields

/**
 * Next fixed date after a completion on `done`, given the date that was due. A completion counts
 * for the calendar date nearest to it, so doing the job a bit early or late doesn't skip or repeat one.
 */
export function fixedDue(done: Millis, due: Millis, value: number, unit: IntervalUnit): Millis {
  const day = startOfDay(done)
  const n = Math.max(1, value)
  const step = (k: number) => addCalendar(due, unit, k * n)
  let k = 0
  while (step(k + 1) <= day && k < 10_000) k += 1
  while (step(k) > day && k > -10_000) k -= 1
  // step(k) <= day < step(k + 1); pick the closer one.
  const covered = day - step(k) <= step(k + 1) - day ? k : k + 1
  return covered < 0 ? due : step(covered + 1)
}

export function lastDoneOf(fields: Pick<TaskFields, 'baselineDoneAt'>, logs: readonly TaskLog[]): Millis | null {
  let last = fields.baselineDoneAt
  for (const log of logs) if (last === null || log.completedAt > last) last = log.completedAt
  return last
}

/**
 * Three steps: work out the date the schedule puts it on, move that onto a preferred day, then
 * apply a pending one-off shift. Every device runs this, so all of them agree on when a task is due.
 */
export function nextDueOf(fields: TaskFields, logs: readonly TaskLog[], lastDoneAt: Millis | null, now: Millis): Millis {
  let due: Millis
  if (fields.scheduleKind === 'fixedDate' && fields.anchorDate !== null) {
    due = startOfDay(fields.anchorDate)
    if (fields.repeats) {
      const dates = logs.map((l) => l.completedAt).sort((a, b) => a - b)
      for (const date of dates) due = fixedDue(date, due, fields.intervalValue, fields.intervalUnit)
    }
  } else if (lastDoneAt !== null) {
    due = addCalendar(startOfDay(lastDoneAt), fields.intervalUnit, fields.intervalValue)
  } else {
    // Never done: the day the user chose to start, or today.
    due = startOfDay(fields.anchorDate ?? now)
  }
  due = snap(due, fields.preferredDays, fields.scheduleKind, fields.intervalValue, fields.intervalUnit, now)
  if (fields.shiftedFrom !== null && fields.shiftedTo !== null && startOfDay(fields.shiftedFrom) === due) {
    due = startOfDay(fields.shiftedTo)
  }
  return due
}

export function deriveTask(uid: string, fields: TaskFields, logs: TaskLog[], now: Millis): Task {
  const lastDoneAt = lastDoneOf(fields, logs)
  return { ...fields, uid, logs, lastDoneAt, nextDueAt: nextDueOf(fields, logs, lastDoneAt, now) }
}

export const isFixedDate = (t: Pick<TaskFields, 'scheduleKind'>) => t.scheduleKind === 'fixedDate'
export const isOneOff = (t: Pick<TaskFields, 'scheduleKind' | 'repeats'>) => t.scheduleKind === 'fixedDate' && !t.repeats
export const isDue = (t: Pick<Task, 'nextDueAt'>, now: Millis) => t.nextDueAt <= now
export const isSnoozed = (t: Pick<TaskFields, 'snoozedUntil'>, now: Millis) => t.snoozedUntil !== null && t.snoozedUntil > now
export const needsAttention = (t: Task, now: Millis) => t.isActive && isDue(t, now) && !isSnoozed(t, now)
/** A one-off fixed-date task that has been done (and so switched itself off). */
export const isFinished = (t: Task) => isOneOff(t) && !t.isActive && t.lastDoneAt !== null

/**
 * Who's responsible for the occurrence that's due next: a one-off hand-over made since the last
 * completion, otherwise the usual person. Mirrors `Schedule.currentAssignee` on the Mac; dates are
 * whole milliseconds here, just as they're stored.
 */
export function currentAssignee(t: Pick<Task, 'assigneeUid' | 'onceAssigneeUid' | 'onceAssigneeAfter' | 'lastDoneAt'>): string {
  return t.onceAssigneeUid !== null && t.onceAssigneeAfter === t.lastDoneAt ? t.onceAssigneeUid : t.assigneeUid
}

// MARK: Due status

export type DueStatus =
  | { kind: 'overdue'; days: number }
  | { kind: 'today' }
  | { kind: 'soon'; days: number }
  | { kind: 'later'; days: number }

export function dueStatus(due: Millis, now: Millis): DueStatus {
  const days = calendarDaysBetween(now, due)
  if (days < 0) return { kind: 'overdue', days: -days }
  if (days === 0) return { kind: 'today' }
  if (days <= 7) return { kind: 'soon', days }
  return { kind: 'later', days }
}

export function dueStatusText(status: DueStatus): string {
  switch (status.kind) {
    case 'overdue':
      if (status.days === 1) return '1 day overdue'
      if (status.days >= 14) return `${Math.floor(status.days / 7)} weeks overdue`
      return `${status.days} days overdue`
    case 'today':
      return 'Due today'
    case 'soon':
      return status.days === 1 ? 'Due tomorrow' : `Due in ${status.days} days`
    case 'later': {
      const d = status.days
      if (d < 14) return `In ${d} days`
      if (d < 60) return `In ${Math.floor(d / 7)} weeks`
      if (d < 700) return `In ${Math.floor(d / 30)} months`
      return `In ${Math.floor(d / 365)} years`
    }
  }
}

export const statusIsDue = (s: DueStatus) => s.kind === 'overdue' || s.kind === 'today'

/**
 * Where a task belongs in Up Next's By Date list — the same rule as `UpNextBucket` on the Mac.
 * The list is this week's work and nothing else; a task ticked off drops to 'done', since it
 * isn't due again this week but shouldn't just vanish either.
 */
export type UpNextBucket = 'overdue' | 'today' | 'thisWeek' | 'done' | 'hidden'

/** The newest ticked-off completion (a log); unlike `lastDoneAt`, never a "last done" typed in. */
export function lastCompletedOf(task: Pick<Task, 'logs'>): Millis | null {
  let last: Millis | null = null
  for (const log of task.logs) if (last === null || log.completedAt > last) last = log.completedAt
  return last
}

/**
 * `lastCompletedAt` is the newest ticked-off completion, not `lastDoneAt`: a date entered as
 * "I just did these" moves the schedule but isn't something anyone ticked off.
 */
export function upNextBucket(
  task: Pick<Task, 'nextDueAt' | 'isActive'> & { lastCompletedAt: Millis | null },
  now: Millis,
  weekStart: number,
): UpNextBucket {
  const start = startOfWeek(now, weekStart)
  const end = addDays(start, 7)
  const doneThisWeek = task.lastCompletedAt !== null && task.lastCompletedAt >= start
  // A paused task, or a one-off that switched itself off, is only here as this week's receipt.
  if (!task.isActive) return doneThisWeek ? 'done' : 'hidden'
  const today = startOfDay(now)
  const day = startOfDay(task.nextDueAt)
  // Still actionable today, whatever was ticked off earlier.
  if (day < today) return 'overdue'
  if (day === today) return 'today'
  // Done this week and nothing more to do about it now — even a daily chore that comes round
  // again on Friday is finished as far as today is concerned.
  if (doneThisWeek) return 'done'
  return day < end ? 'thisWeek' : 'hidden'
}

// MARK: Descriptions

export function unitLabel(unit: IntervalUnit, value: number): string {
  return value === 1 ? unit : `${unit}s`
}

/**
 * "Every 3 months", "Every 2 weeks on Saturdays", "Every year on 15 Sep", "Once on 15 Sep 2026".
 * A null `fixedDate` means after last done.
 */
export function describe(value: number, unit: IntervalUnit, fixedDate: Millis | null, repeats: boolean, preferredDays = WEEKDAYS_ANY): string {
  let every = value === 1 ? `Every ${unit}` : `Every ${value} ${unitLabel(unit, value)}`
  if (fixedDate === null && snaps('interval', value, unit)) {
    const days = weekdaysLabel(preferredDays)
    if (days) every += ` on ${days}`
  }
  if (fixedDate === null) return every
  if (!repeats) return `Once on ${formatDate(fixedDate)}`
  const day = formatDayMonth(fixedDate)
  return unit === 'year' ? `${every} on ${day}` : `${every} from ${day}`
}

export function intervalDescription(t: TaskFields): string {
  return describe(t.intervalValue, t.intervalUnit, isFixedDate(t) ? t.anchorDate : null, t.repeats, t.preferredDays)
}

// MARK: Household model

export interface Household {
  now: Millis
  people: Person[]
  items: HomeItem[]
  tasks: Task[]
  logs: TaskLog[]
  itemsByUid: Map<string, HomeItem>
  tasksByItem: Map<string, Task[]>
  tasksByUid: Map<string, Task>
}

export function buildHousehold(records: readonly SyncRecord[], now: Millis): Household {
  const items: HomeItem[] = []
  const taskRecords: SyncRecord[] = []
  const logs: TaskLog[] = []
  for (const r of records) {
    if (r.kind === HOME_ITEM) items.push(itemFrom(r))
    else if (r.kind === TASK) taskRecords.push(r)
    else if (r.kind === TASK_LOG) {
      const log = logFrom(r)
      if (log) logs.push(log)
    }
  }
  const logsByTask = new Map<string, TaskLog[]>()
  for (const log of logs) {
    const list = logsByTask.get(log.taskUid)
    if (list) list.push(log)
    else logsByTask.set(log.taskUid, [log])
  }
  const itemsByUid = new Map(items.map((i) => [i.uid, i]))
  const tasks = taskRecords.map((r) => deriveTask(r.uid, taskFieldsFrom(r), logsByTask.get(r.uid) ?? [], now))
  const tasksByItem = new Map<string, Task[]>()
  for (const t of tasks) {
    const list = tasksByItem.get(t.itemUid)
    if (list) list.push(t)
    else tasksByItem.set(t.itemUid, [t])
  }
  items.sort((a, b) => compareTitles(a.name, b.name))
  return {
    now,
    people: peopleFrom(records),
    items,
    tasks,
    logs,
    itemsByUid,
    tasksByItem,
    tasksByUid: new Map(tasks.map((t) => [t.uid, t])),
  }
}

registerDerived('maintenance', buildHousehold)

/** Finder-like ordering ("Item 2" before "Item 10"), like `localizedStandardCompare`. */
export function compareTitles(a: string, b: string): number {
  return a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })
}

// MARK: Item helpers

export function activeTasks(tasks: readonly Task[]): Task[] {
  return tasks.filter((t) => t.isActive).sort((a, b) => a.nextDueAt - b.nextDueAt)
}

export function pausedTasks(tasks: readonly Task[]): Task[] {
  return tasks.filter((t) => !t.isActive).sort((a, b) => compareTitles(a.title, b.title))
}

export function historyOf(tasks: readonly Task[]): { log: TaskLog; task: Task }[] {
  return tasks.flatMap((task) => task.logs.map((log) => ({ log, task }))).sort((a, b) => b.log.completedAt - a.log.completedAt)
}

/** Named rooms alphabetically, ungrouped last. */
export function groupByRoom<T>(values: readonly T[], room: (v: T) => string): { room: string; values: T[] }[] {
  const groups = new Map<string, T[]>()
  for (const v of values) {
    const key = room(v).trim()
    const list = groups.get(key)
    if (list) list.push(v)
    else groups.set(key, [v])
  }
  return [...groups.entries()]
    .map(([room, values]) => ({ room, values }))
    .sort((a, b) => {
      if ((a.room === '') !== (b.room === '')) return a.room === '' ? 1 : -1
      return compareTitles(a.room, b.room)
    })
}

/** Ungrouped things read as "Home" until at least one room exists. */
export function roomTitle(room: string, hasRooms = true): string {
  return room === '' ? (hasRooms ? 'Other' : 'Home') : room
}
