// Adding and editing items, tasks and history, the same way the Mac's sheets do (Sheets.swift,
// ItemDetailView.swift). Everyday actions — done, move, hand over — are in actions.ts.
import { addDays, encodeDate, isSameDay, startOfDay, type Millis } from '../../core/dates'
import { write } from '../../core/db'
import { DEFAULT_CHORE_DAYS, type TileColor } from '../../core/people'
import type { JsonObject } from '../../core/snapshot'
import type { IconKey, IntervalUnit, TaskSuggestion } from './catalog'
import {
  describe,
  HOME_ITEM,
  isFinished,
  lastDoneOf,
  nextDueOf,
  suggestedDays,
  TASK,
  WEEKDAYS_ANY,
  type HomeItem,
  type ScheduleKind,
  type Task,
} from './schedule'

// MARK: Schedules chosen before a task exists (DraftSchedule on the Mac)

export interface DraftSchedule {
  kind: ScheduleKind
  value: number
  unit: IntervalUnit
  /** Fixed dates: the first due date. */
  date: Millis
  repeats: boolean
  /** Days of the week this should land on, as `Weekdays` digits. Empty means any day. */
  preferredDays: string
}

/** A suggestion's schedule: after last done, on the person's chore days when it's an ordinary chore. */
export function draftFor(value: number, unit: IntervalUnit, choreDays: string, now: Millis): DraftSchedule {
  return { kind: 'interval', value, unit, date: startOfDay(now), repeats: true, preferredDays: suggestedDays(value, unit, 'interval', choreDays) }
}

export function draftFromSuggestion(s: TaskSuggestion, choreDays: string, now: Millis): DraftSchedule {
  return draftFor(s.value, s.unit, choreDays, now)
}

/** An existing task's schedule, dated like the task editor: the next due date, or a finished one-off's date. */
export function draftFromTask(t: Task): DraftSchedule {
  return {
    kind: t.scheduleKind,
    value: t.intervalValue,
    unit: t.intervalUnit,
    date: startOfDay(isFinished(t) ? (t.anchorDate ?? t.nextDueAt) : t.nextDueAt),
    repeats: t.repeats,
    preferredDays: t.preferredDays,
  }
}

/**
 * Days never chosen by hand keep following the interval, so a yearly service doesn't get dragged
 * onto Saturdays just because the monthly chores are.
 */
export function adjustDraft(before: DraftSchedule, next: DraftSchedule, choreDays: string): DraftSchedule {
  const changed = before.kind !== next.kind || before.value !== next.value || before.unit !== next.unit
  const wasSuggested = next.preferredDays === choreDays || next.preferredDays === WEEKDAYS_ANY
  if (!changed || !wasSuggested) return next
  return { ...next, preferredDays: suggestedDays(Math.max(1, next.value), next.unit, next.kind, choreDays) }
}

export function describeDraft(d: DraftSchedule): string {
  return describe(d.value, d.unit, d.kind === 'fixedDate' ? d.date : null, d.repeats, d.preferredDays)
}

export function sameDraft(a: DraftSchedule, b: DraftSchedule): boolean {
  return a.kind === b.kind && a.value === b.value && a.unit === b.unit && a.date === b.date && a.repeats === b.repeats && a.preferredDays === b.preferredDays
}

/** The chore days a new task starts from: mine, or weekends when nobody is chosen. */
export function choreDaysOf(me: { choreDays: string } | undefined): string {
  return me?.choreDays ?? DEFAULT_CHORE_DAYS
}

/** Task data for a new task on `draft`. `lastDone` only applies to after-last-done schedules. */
function newTaskData(itemUid: string, title: string, draft: DraftSchedule, lastDone: Millis | null, assigneeUid: string, now: Millis): JsonObject {
  const fixed = draft.kind === 'fixedDate'
  return {
    itemUid,
    title: title.trim(),
    intervalValue: Math.max(1, draft.value),
    intervalUnit: draft.unit,
    scheduleKind: draft.kind,
    anchorDate: fixed ? encodeDate(startOfDay(draft.date)) : null,
    repeats: fixed ? draft.repeats : true,
    baselineDoneAt: !fixed && lastDone !== null ? encodeDate(lastDone) : null,
    preferredDays: draft.preferredDays,
    assigneeUid,
    createdAt: encodeDate(now),
  }
}

/** Rescheduling an existing task keeps its history, the same way saving the task editor does. */
function reschedulePatch(t: Task, draft: DraftSchedule): JsonObject {
  const patch: JsonObject = {
    intervalValue: Math.max(1, draft.value),
    intervalUnit: draft.unit,
    // Rescheduling replaces whatever a one-off move had done to the next occurrence.
    shiftedFrom: null,
    shiftedTo: null,
    preferredDays: draft.preferredDays,
  }
  // A done one-off that gets a new date or a repeating schedule is due again.
  if (isFinished(t) && (draft.kind !== 'fixedDate' || draft.repeats || t.anchorDate !== startOfDay(draft.date))) patch.isActive = true
  if (draft.kind === 'fixedDate') {
    patch.scheduleKind = 'fixedDate'
    patch.anchorDate = encodeDate(startOfDay(draft.date))
    patch.repeats = draft.repeats
  } else {
    patch.scheduleKind = 'interval'
  }
  return patch
}

export async function rescheduleTask(t: Task, draft: DraftSchedule, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(t.uid, reschedulePatch(t, draft)), now)
}

// MARK: Items

export interface ItemFields {
  name: string
  icon: IconKey
  color: TileColor
  room: string
  notes: string
}

export interface NewTask {
  title: string
  schedule: DraftSchedule
  assigneeUid: string
}

/**
 * Adds an item with its chosen routine. `startFresh` means "I just did these": the clock starts
 * now. Otherwise they come round on the next chore day.
 */
export async function addItem(fields: ItemFields, tasks: readonly NewTask[], startFresh: boolean, now: Millis = Date.now()): Promise<string> {
  return write(async (w) => {
    const uid = await w.create(HOME_ITEM, {
      name: fields.name.trim(),
      iconKey: fields.icon,
      colorKey: fields.color,
      room: fields.room.trim(),
      notes: fields.notes,
      createdAt: encodeDate(now),
    })
    for (const t of tasks) await w.create(TASK, newTaskData(uid, t.title, t.schedule, startFresh ? now : null, t.assigneeUid, now))
    return uid
  }, now)
}

export async function updateItem(uid: string, fields: ItemFields, now: Millis = Date.now()): Promise<void> {
  await write(
    (w) => w.update(uid, { name: fields.name.trim(), iconKey: fields.icon, colorKey: fields.color, room: fields.room.trim(), notes: fields.notes }),
    now,
  )
}

/** Deletes the item for everyone, with its tasks and their history. */
export async function deleteItem(uid: string, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.delete(uid), now)
}

/** Renames a room on every item in it; an empty name ungroups them. */
export async function renameRoom(items: readonly HomeItem[], from: string, to: string, now: Millis = Date.now()): Promise<void> {
  const name = to.trim()
  await write(async (w) => {
    for (const item of items) if (item.room === from) await w.update(item.uid, { room: name })
  }, now)
}

// MARK: Tasks

/** When an after-last-done task's clock starts, as the task editor asks it. */
export type StartMode = 'lastDone' | 'firstDue' | 'soon'

/** Everything the task editor edits (TaskEditorSheet on the Mac). */
export interface TaskForm {
  itemUid: string
  title: string
  value: number
  unit: IntervalUnit
  kind: ScheduleKind
  /** Fixed dates: when it's due. */
  fixedDate: Millis
  repeats: boolean
  startMode: StartMode
  /** Start of the day it was last done. */
  lastDone: Millis
  /** Start of the day it's first due. */
  startDate: Millis
  preferredDays: string
  isActive: boolean
  assigneeUid: string
}

/** A blank task for `itemUid`, landing on my chore days. */
export function newTaskForm(itemUid: string, choreDays: string, now: Millis): TaskForm {
  const today = startOfDay(now)
  return {
    itemUid,
    title: '',
    value: 1,
    unit: 'month',
    kind: 'interval',
    fixedDate: today,
    repeats: true,
    startMode: 'lastDone',
    lastDone: today,
    startDate: today,
    preferredDays: suggestedDays(1, 'month', 'interval', choreDays),
    isActive: true,
    assigneeUid: '',
  }
}

/** The editor filled in from an existing task. */
export function taskForm(t: Task, personExists: (uid: string) => boolean, now: Millis): TaskForm {
  const fixed = t.scheduleKind === 'fixedDate'
  let startMode: StartMode = 'lastDone'
  if (t.lastDoneAt === null) startMode = fixed || t.anchorDate === null ? 'soon' : 'firstDue'
  return {
    itemUid: t.itemUid,
    title: t.title,
    value: t.intervalValue,
    unit: t.intervalUnit,
    kind: t.scheduleKind,
    fixedDate: startOfDay(isFinished(t) ? (t.anchorDate ?? t.nextDueAt) : t.nextDueAt),
    repeats: t.repeats,
    startMode,
    lastDone: startOfDay(t.lastDoneAt ?? now),
    startDate: startOfDay(fixed ? t.nextDueAt : (t.anchorDate ?? t.nextDueAt)),
    preferredDays: t.preferredDays,
    isActive: t.isActive,
    assigneeUid: personExists(t.assigneeUid) ? t.assigneeUid : '',
  }
}

/**
 * A change of interval or kind: a day that was never chosen by hand keeps following the interval,
 * so a monthly chore lands on the household's chore days and a yearly service on whatever date it falls.
 */
export function adjustForm(before: TaskForm, next: TaskForm, choreDays: string, wasFixed: boolean): TaskForm {
  const form = { ...next }
  // Dates recur yearly far more often than monthly, so start from there.
  if (before.kind !== 'fixedDate' && form.kind === 'fixedDate' && !wasFixed && form.value === 1) form.unit = 'year'
  const scheduleChanged = before.kind !== form.kind || before.value !== form.value || before.unit !== form.unit
  const wasSuggested = form.preferredDays === choreDays || form.preferredDays === WEEKDAYS_ANY
  if (scheduleChanged && wasSuggested) form.preferredDays = suggestedDays(Math.max(1, form.value), form.unit, form.kind, choreDays)
  return form
}

/** "Last done" at the time it was really done when that's today, else the start of that day. */
function lastDoneMoment(day: Millis, now: Millis): Millis {
  return isSameDay(day, now) ? now : startOfDay(day)
}

/** The task data the editor would save, as a fresh task's fields (used for the preview too). */
function formData(form: TaskForm, now: Millis): JsonObject {
  const data: JsonObject = {
    title: form.title.trim(),
    intervalValue: Math.max(1, form.value),
    intervalUnit: form.unit,
    isActive: form.isActive,
    assigneeUid: form.assigneeUid,
    // Rescheduling replaces whatever a one-off move had done to the next occurrence.
    shiftedFrom: null,
    shiftedTo: null,
    preferredDays: form.preferredDays,
  }
  if (form.kind === 'fixedDate') {
    data.scheduleKind = 'fixedDate'
    data.anchorDate = encodeDate(startOfDay(form.fixedDate))
    data.repeats = form.repeats
  } else {
    data.scheduleKind = 'interval'
    // "Last done" moves the baseline; logged completions still count.
    data.baselineDoneAt = form.startMode === 'lastDone' ? encodeDate(lastDoneMoment(form.lastDone, now)) : null
    // A start date only decides the first one, so it stops mattering once there's a history.
    data.anchorDate = form.startMode === 'firstDue' ? encodeDate(startOfDay(form.startDate)) : null
  }
  return data
}

/** Adds a task, or saves the editor's changes to `existing`. Returns the task's uid. */
export async function saveTask(existing: Task | null, form: TaskForm, now: Millis = Date.now()): Promise<string> {
  const data = formData(form, now)
  if (!existing) {
    return write((w) => w.create(TASK, { ...data, itemUid: form.itemUid, createdAt: encodeDate(now) }), now)
  }
  // A done one-off that gets a new date or a repeating schedule is due again.
  if (isFinished(existing) && (form.kind !== 'fixedDate' || form.repeats || existing.anchorDate !== startOfDay(form.fixedDate))) {
    data.isActive = true
  }
  await write((w) => w.update(existing.uid, data), now)
  return existing.uid
}

/** Adds a task to the routine from a suggestion or a custom one. The clock starts today. */
export async function addRoutineTask(itemUid: string, title: string, draft: DraftSchedule, assigneeUid: string, now: Millis = Date.now()): Promise<string> {
  return write((w) => w.create(TASK, newTaskData(itemUid, title, draft, now, assigneeUid, now)), now)
}

export async function setTaskActive(t: Task, active: boolean, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(t.uid, { isActive: active }), now)
}

/** Who does it every time; a one-off hand-over of the next one stays as it is. */
export async function setAssignee(t: Task, uid: string, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(t.uid, { assigneeUid: uid }), now)
}

export async function snooze(t: Task, days: number, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(t.uid, { snoozedUntil: encodeDate(addDays(now, days)) }), now)
}

export async function stopSnoozing(t: Task, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(t.uid, { snoozedUntil: null }), now)
}

/** Deletes the task for everyone, with its history. */
export async function deleteTask(t: Task, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.delete(t.uid), now)
}

/**
 * Removes one history entry. A finished one-off comes back to life once nothing says it was done
 * (Docs/Sync.md › Remove a log).
 */
export async function removeLog(t: Task, logUid: string, now: Millis = Date.now()): Promise<void> {
  await write(async (w) => {
    await w.delete(logUid)
    const remaining = t.logs.filter((l) => l.uid !== logUid)
    if (isFinished(t) && lastDoneOf(t, remaining) === null) await w.update(t.uid, { isActive: true })
  }, now)
}

/**
 * When the editor's schedule would first be due. Exactly what saving would compute, so the preview
 * can't disagree with the task (like the Mac, it looks at the schedule alone, not the history).
 */
export function previewDue(form: TaskForm, now: Millis): Millis {
  if (form.kind === 'fixedDate') return startOfDay(form.fixedDate)
  const baseline = form.startMode === 'lastDone' ? lastDoneMoment(form.lastDone, now) : null
  const fields = {
    itemUid: form.itemUid,
    title: form.title,
    intervalValue: Math.max(1, form.value),
    intervalUnit: form.unit,
    scheduleKind: 'interval' as const,
    anchorDate: form.startMode === 'firstDue' ? startOfDay(form.startDate) : null,
    repeats: true,
    isActive: true,
    baselineDoneAt: baseline,
    snoozedUntil: null,
    preferredDays: form.preferredDays,
    shiftedFrom: null,
    shiftedTo: null,
    assigneeUid: '',
    onceAssigneeUid: null,
    onceAssigneeAfter: null,
    createdAt: null,
  }
  return nextDueOf(fields, [], baseline, now)
}
