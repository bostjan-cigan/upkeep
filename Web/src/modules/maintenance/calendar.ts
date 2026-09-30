// Calendar projection, ported from CalendarView.swift (`CalendarOccurrence.all`).
import { addCalendar, addDays, localDay, startOfDay, type Millis } from '../../core/dates'
import { compareTitles, currentAssignee, type Task } from './schedule'

/**
 * A task landing on a calendar day. Only the first occurrence is real; later ones are where the
 * task would fall if each one gets done on time.
 */
export interface CalendarOccurrence {
  task: Task
  /** Start of the local day. */
  day: Millis
  isProjected: boolean
  /** Overdue tasks are shown on today, since that's when they need doing. */
  isOverdue: boolean
  /** Who it's for: a one-off hand-over only covers the real occurrence, and repeats go to the usual person. */
  assigneeUid: string
}

/** Occurrences of `tasks` on days in `[start, end)` (start-of-day dates), keyed by day. */
export function occurrences(tasks: readonly Task[], start: Millis, end: Millis, now: Millis): Map<Millis, CalendarOccurrence[]> {
  const today = startOfDay(now)
  const result = new Map<Millis, CalendarOccurrence[]>()
  const add = (o: CalendarOccurrence) => {
    const list = result.get(o.day)
    if (list) list.push(o)
    else result.set(o.day, [o])
  }
  const inRange = (day: Millis) => day >= start && day < end

  for (const task of tasks) {
    if (!task.isActive) continue
    const due = startOfDay(task.nextDueAt)
    const first = Math.max(due, today)
    if (inRange(first)) add({ task, day: first, isProjected: false, isOverdue: due < today, assigneeUid: currentAssignee(task) })
    const fixed = task.scheduleKind === 'fixedDate'
    if (fixed && !task.repeats) continue

    // Fixed dates keep their own series; interval tasks restart from the day they get done.
    const base = fixed ? due : first
    const step = Math.max(1, task.intervalValue)
    for (let k = 1; k <= 1_000; k++) {
      const day = addCalendar(base, task.intervalUnit, k * step)
      if (day >= end) break
      if (day <= first || !inRange(day)) continue
      add({ task, day, isProjected: true, isOverdue: false, assigneeUid: task.assigneeUid })
    }
  }
  for (const list of result.values()) {
    list.sort((a, b) => (a.isProjected !== b.isProjected ? (a.isProjected ? 1 : -1) : compareTitles(a.task.title, b.task.title)))
  }
  return result
}

/** First day of the week as a JS weekday (0 = Sunday), from `Intl.Locale` week info; Monday otherwise. */
export function firstWeekday(locale: string = typeof navigator !== 'undefined' ? navigator.language : 'en-GB'): number {
  try {
    const loc = new Intl.Locale(locale) as Intl.Locale & { weekInfo?: { firstDay: number }; getWeekInfo?: () => { firstDay: number } }
    const info = loc.getWeekInfo?.() ?? loc.weekInfo
    if (info && info.firstDay >= 1 && info.firstDay <= 7) return info.firstDay % 7
  } catch {
    // Unsupported: fall through.
  }
  return 1
}

/** Six whole weeks covering the month containing `month`, starting on `weekStart`. */
export function gridDays(month: Millis, weekStart: number): Millis[] {
  const d = new Date(month)
  const firstOfMonth = localDay(d.getFullYear(), d.getMonth(), 1)
  const offset = (new Date(firstOfMonth).getDay() - weekStart + 7) % 7
  const start = addDays(firstOfMonth, -offset)
  return Array.from({ length: 42 }, (_, i) => addDays(start, i))
}
