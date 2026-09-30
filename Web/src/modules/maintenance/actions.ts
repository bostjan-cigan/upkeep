// Everyday actions on a task: done, moving an occurrence when the day doesn't suit ("not today,
// Saturday") or handing it to someone else ("can you do it this time?"). Adding and editing
// items, tasks and history is in editing.ts.
import { addDays, calendarDaysBetween, encodeDate, startOfDay, weekday, type Millis } from '../../core/dates'
import { write } from '../../core/db'
import type { JsonObject, JsonValue } from '../../core/snapshot'
import {
  canMoveSeries,
  isFinished,
  lastDoneOf,
  movesByWeekday,
  nextDueOf,
  TASK_LOG,
  weekdayString,
  type Task,
  type TaskFields,
  type TaskLog,
} from './schedule'

export interface DoneReceipt {
  taskUid: string
  logUid: string
  /** The task fields that marking done changed, with their previous values (empty if none changed). */
  previous: JsonObject
}

/**
 * Creates a `taskLog` (`completedAt = now`, `completedByUid = me`), clears the snooze and switches
 * off a one-off fixed-date task. The task record is stamped only if its data actually changed.
 */
export async function markDone(task: Task, myPersonUid: string, now: Millis = Date.now(), note = ''): Promise<DoneReceipt> {
  return write(async (w) => {
    const logUid = await w.create(TASK_LOG, { taskUid: task.uid, completedAt: encodeDate(now), note, completedByUid: myPersonUid })
    const previous: JsonObject = {}
    const stored = await w.get(task.uid)
    if (stored) {
      // A one-off move or hand-over belongs to the occurrence it was made for and goes with it.
      const changes: JsonObject = { snoozedUntil: null, shiftedFrom: null, shiftedTo: null, onceAssigneeUid: null, onceAssigneeAfter: null }
      if (task.scheduleKind === 'fixedDate' && task.anchorDate !== null && !task.repeats) changes.isActive = false
      const patch: JsonObject = {}
      for (const [key, value] of Object.entries(changes)) {
        const old: JsonValue | undefined = stored.data[key]
        // A key that a record from an older build doesn't have yet is null already.
        if (old === value || (old === undefined && value === null)) continue
        previous[key] = old === undefined ? null : old
        patch[key] = value
      }
      await w.update(task.uid, patch)
    }
    return { taskUid: task.uid, logUid, previous }
  }, now)
}

/**
 * Hands just the next occurrence to `uid` ("" = everyone); picking the usual person takes it back.
 * Mirrors `MaintenanceTask.assignOnce` on the Mac.
 */
export async function assignOnce(task: Task, uid: string, now: Millis = Date.now()): Promise<void> {
  const patch: JsonObject =
    uid === task.assigneeUid
      ? { onceAssigneeUid: null, onceAssigneeAfter: null }
      : { onceAssigneeUid: uid, onceAssigneeAfter: task.lastDoneAt === null ? null : encodeDate(task.lastDoneAt) }
  await write((w) => w.update(task.uid, patch), now)
}

/** What a move applies to, the way a calendar asks it. */
export type MoveScope = 'thisOnce' | 'allFuture'

/**
 * Moves a task's next occurrence to `date`, either on its own or taking the rest of the series
 * with it. Mirrors `MaintenanceTask.move(to:scope:)` on the Mac.
 */
export async function moveOccurrence(task: Task, date: Millis, scope: MoveScope, now: Millis = Date.now()): Promise<void> {
  const target = startOfDay(date)
  const current = startOfDay(task.nextDueAt)
  if (target === current) return
  if (!canMoveSeries(task)) scope = 'thisOnce'
  await write(async (w) => {
    if (scope === 'thisOnce') {
      await w.update(task.uid, { shiftedFrom: encodeDate(current), shiftedTo: encodeDate(target) })
      return
    }
    const patch: JsonObject = { shiftedFrom: null, shiftedTo: null }
    if (task.scheduleKind === 'fixedDate' && task.anchorDate !== null) {
      // The series is the dates themselves, so move every one of them by the same distance.
      patch.anchorDate = encodeDate(addDays(task.anchorDate, calendarDaysBetween(current, target)))
      await w.update(task.uid, patch)
      return
    }
    // An after-last-done task rebuilds itself from each completion, so what lasts is the day of
    // the week. A task never done yet also gets its start date moved.
    const moved: TaskFields = { ...task, shiftedFrom: null, shiftedTo: null }
    if (movesByWeekday(task)) {
      moved.preferredDays = weekdayString([weekday(target)])
      patch.preferredDays = moved.preferredDays
    }
    if (task.lastDoneAt === null) {
      moved.anchorDate = target
      patch.anchorDate = encodeDate(target)
    }
    // A move of more than a few days lands further out than snapping can reach; the occurrence on
    // the calendar right now still needs carrying across.
    const landed = nextDueOf(moved, task.logs, task.lastDoneAt, now)
    if (landed !== target) {
      patch.shiftedFrom = encodeDate(landed)
      patch.shiftedTo = encodeDate(target)
    }
    await w.update(task.uid, patch)
  }, now)
}

/**
 * Undo for the Done group: removes the newest completion and puts the task back where it was.
 * Mirrors `TaskRow.undo()` on the Mac, and Docs/Sync.md › "Remove a log" — a finished one-off
 * comes back to life once nothing says it was done.
 */
export async function undoLastDone(task: Task, now: Millis = Date.now()): Promise<void> {
  const newest = task.logs.reduce<TaskLog | undefined>((best, log) => (!best || log.completedAt > best.completedAt ? log : best), undefined)
  if (!newest) return
  await write(async (w) => {
    await w.delete(newest.uid)
    const remaining = task.logs.filter((l) => l.uid !== newest.uid)
    if (isFinished(task) && lastDoneOf(task, remaining) === null) await w.update(task.uid, { isActive: true })
  }, now)
}

/** Undo for the toast: tombstones the log and puts back the task fields marking done changed. */
export async function undoMarkDone(receipt: DoneReceipt): Promise<void> {
  await write(async (w) => {
    await w.delete(receipt.logUid)
    if (Object.keys(receipt.previous).length) await w.update(receipt.taskUid, receipt.previous)
  })
}
