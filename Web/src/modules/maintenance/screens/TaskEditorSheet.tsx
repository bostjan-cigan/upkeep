import { useState } from 'react'
import { ConfirmSheet, DateRow, SelectRow, SwitchRow, TextRow, WeekdayRow } from '../../../app/form'
import { useApp } from '../../../app/hooks'
import { Row, Section, Segmented, Sheet } from '../../../app/ui'
import { formatDateLong, formatWeekdayDayMonth, startOfDay } from '../../../core/dates'
import {
  adjustForm,
  choreDaysOf,
  deleteTask,
  newTaskForm,
  previewDue,
  saveTask,
  setTaskActive,
  snooze,
  stopSnoozing,
  taskForm,
  type StartMode,
  type TaskForm,
} from '../editing'
import { groupByRoom, isSnoozed, roomTitle, snaps, unitLabel, weekdaysLabel, type ScheduleKind, type Task } from '../schedule'
import { AssigneeRow, IntervalRows } from './fields'

/**
 * Adds a task or edits one, like the Mac's task editor: what it is, who does it, and when it comes
 * round. An existing task also offers snooze, pause and delete. Without `itemUid`, it asks which item.
 */
export function TaskEditorSheet({ task, itemUid, onClose }: { task?: Task; itemUid?: string; onClose: () => void }) {
  const { household, me, now, toast } = useApp()
  const choreDays = choreDaysOf(me)
  const personExists = (uid: string) => household.people.some((p) => p.uid === uid)
  const [form, setFormState] = useState<TaskForm>(() => (task ? taskForm(task, personExists, now) : newTaskForm(itemUid ?? '', choreDays, now)))
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const [busy, setBusy] = useState(false)
  const setForm = (next: TaskForm) => setFormState(adjustForm(form, next, choreDays, task?.scheduleKind === 'fixedDate'))

  const canSave = form.title.trim() !== '' && household.itemsByUid.has(form.itemUid)
  const save = () => {
    if (!canSave || busy) return
    setBusy(true)
    void saveTask(task ?? null, form).then(onClose)
  }

  const run = (action: Promise<void>, message: string) => {
    void action.then(() => {
      toast(message)
      onClose()
    })
  }

  const groups = groupByRoom(household.items, (i) => i.room)
  const today = startOfDay(now)

  return (
    <Sheet
      title={task ? 'Edit Task' : 'New Task'}
      onClose={onClose}
      left={<button className="bar-button" onClick={onClose}>Cancel</button>}
      right={
        <button className="bar-button bold" onClick={save} disabled={!canSave || busy}>
          {task ? 'Save' : 'Add'}
        </button>
      }
    >
      <Section>
        {!itemUid && !task && (
          <label className="row">
            <span className="row-main">
              <span className="row-title">For</span>
            </span>
            <select className="inline" aria-label="For" value={form.itemUid} onChange={(e) => setForm({ ...form, itemUid: e.target.value })}>
              <option value="">Choose…</option>
              {groups.map((g) => (
                <optgroup key={g.room} label={roomTitle(g.room, groups.length > 1)}>
                  {g.values.map((i) => (
                    <option key={i.uid} value={i.uid}>
                      {i.name}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          </label>
        )}
        <TextRow value={form.title} onChange={(title) => setForm({ ...form, title })} placeholder="Task, e.g. Clean the filter" autoFocus={!task} onSubmit={save} />
        <AssigneeRow value={form.assigneeUid} onChange={(assigneeUid) => setForm({ ...form, assigneeUid })} />
        {task && <SwitchRow title="Active" on={form.isActive} onChange={(isActive) => setForm({ ...form, isActive })} />}
      </Section>

      <Section footer={nextDueText(form, now)}>
        <div className="row">
          <Segmented
            label="Schedule"
            value={form.kind}
            onChange={(kind: ScheduleKind) => setForm({ ...form, kind })}
            options={[
              { value: 'interval', label: 'After last done' },
              { value: 'fixedDate', label: 'On a date' },
            ]}
          />
        </div>
        {form.kind === 'interval' ? (
          <>
            <IntervalRows value={form.value} unit={form.unit} onChange={(value, unit) => setForm({ ...form, value, unit })} />
            <SelectRow<StartMode>
              title="Starts"
              value={form.startMode}
              options={[
                { value: 'lastDone', label: 'It was last done on…' },
                { value: 'firstDue', label: 'First due on…' },
                { value: 'soon', label: 'As soon as possible' },
              ]}
              onChange={(startMode) => setForm({ ...form, startMode })}
            />
            {form.startMode === 'lastDone' && <DateRow title="Last done" value={form.lastDone} max={today} onChange={(lastDone) => setForm({ ...form, lastDone })} />}
            {form.startMode === 'firstDue' && <DateRow title="First due" value={form.startDate} onChange={(startDate) => setForm({ ...form, startDate })} />}
            {snaps('interval', form.value, form.unit) && (
              <WeekdayRow title="Do it on" value={form.preferredDays} onChange={(preferredDays) => setFormState({ ...form, preferredDays })} />
            )}
          </>
        ) : (
          <>
            <DateRow title="Due on" value={form.fixedDate} onChange={(fixedDate) => setForm({ ...form, fixedDate })} />
            <SwitchRow title="Repeats" on={form.repeats} onChange={(repeats) => setForm({ ...form, repeats })} />
            {form.repeats && <IntervalRows value={form.value} unit={form.unit} onChange={(value, unit) => setForm({ ...form, value, unit })} />}
          </>
        )}
      </Section>

      {task && task.isActive && (
        <Section title="Snooze" footer="Snoozing stops reminders for this task until then. It stays on the list.">
          {isSnoozed(task, now) && task.snoozedUntil !== null ? (
            <Row className="action" title="Stop Snoozing" value={`Until ${formatWeekdayDayMonth(task.snoozedUntil)}`} onClick={() => run(stopSnoozing(task), `Reminders are back on: ${task.title}`)} />
          ) : (
            [1, 3, 7].map((days) => (
              <Row
                key={days}
                className="action"
                title={days === 1 ? '1 Day' : days === 7 ? '1 Week' : `${days} Days`}
                onClick={() => run(snooze(task, days), `Snoozed: ${task.title}`)}
              />
            ))
          )}
        </Section>
      )}

      {task && (
        <Section>
          <Row className="destructive" title="Delete Task…" onClick={() => setConfirmingDelete(true)} />
        </Section>
      )}

      {task && confirmingDelete && (
        <ConfirmSheet
          title={`Delete “${task.title}”?`}
          message={
            task.logs.length === 0
              ? 'This removes the task for everyone in the household.'
              : `This also removes its ${task.logs.length} history ${task.logs.length === 1 ? 'entry' : 'entries'}. Pause it instead to keep the history.`
          }
          confirm="Delete Task"
          destructive
          onConfirm={() => run(deleteTask(task), `Deleted: ${task.title}`)}
          secondary={task.isActive ? { label: 'Pause Instead', run: () => run(setTaskActive(task, false), `Paused: ${task.title}`) } : undefined}
          onClose={() => setConfirmingDelete(false)}
        />
      )}
    </Sheet>
  )
}

/** "Next due 3 October, then on Saturdays." — what saving would give it. */
function nextDueText(form: TaskForm, now: number): string {
  const date = formatDateLong(previewDue(form, now))
  if (form.kind === 'fixedDate') {
    if (!form.repeats) return `Due on ${date}, once.`
    const every = form.value === 1 ? `every ${form.unit}` : `every ${form.value} ${unitLabel(form.unit, form.value)}`
    return `Due on ${date}, then ${every} from that date, however early or late it gets done.`
  }
  const days = snaps('interval', form.value, form.unit) ? weekdaysLabel(form.preferredDays) : null
  return days ? `Next due ${date}, then on ${days}.` : `Next due ${date}.`
}
