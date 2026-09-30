import { useState } from 'react'
import { ConfirmSheet, Switch, TextRow } from '../../../app/form'
import { useApp } from '../../../app/hooks'
import { Person, Trash } from '../../../app/icons'
import { Avatar, Row, Section, Sheet } from '../../../app/ui'
import { missingSuggestions, type IntervalUnit, type TaskSuggestion } from '../catalog'
import {
  addRoutineTask,
  choreDaysOf,
  deleteTask,
  draftFor,
  draftFromSuggestion,
  draftFromTask,
  rescheduleTask,
  setAssignee,
  setTaskActive,
  type DraftSchedule,
} from '../editing'
import { compareTitles, type HomeItem, type Task } from '../schedule'
import { ItemTile } from '../tile'
import { AssigneeRow, IntervalRows, ScheduleButton } from './fields'

/** One place to switch tasks on or off, delete them, and add suggested or custom ones. */
export function RoutineSheet({ item, onClose }: { item: HomeItem; onClose: () => void }) {
  const { household, me, now, toast } = useApp()
  const choreDays = choreDaysOf(me)
  const tasks = [...(household.tasksByItem.get(item.uid) ?? [])].sort((a, b) => compareTitles(a.title, b.title))
  const suggestions = missingSuggestions(item.icon, tasks.map((t) => t.title))
  const [schedules, setSchedules] = useState<Record<string, DraftSchedule>>({})
  const [assignees, setAssignees] = useState<Record<string, string>>({})
  const [toDelete, setToDelete] = useState<Task | null>(null)
  const [newTitle, setNewTitle] = useState('')
  const [newValue, setNewValue] = useState(1)
  const [newUnit, setNewUnit] = useState<IntervalUnit>('month')
  const [newAssignee, setNewAssignee] = useState('')
  const people = household.people

  const nextPerson = (uid: string) => {
    const order = ['', ...people.map((p) => p.uid)]
    return order[(order.indexOf(uid) + 1) % order.length] ?? ''
  }
  const personButton = (uid: string, title: string, onPick: (uid: string) => void) => {
    if (!people.length) return null
    const person = people.find((p) => p.uid === uid)
    return (
      <button type="button" className="who-button" aria-label={`Responsible for “${title}”: ${person?.name ?? 'everyone'}`} onClick={() => onPick(nextPerson(uid))}>
        {person ? <Avatar person={person} size={24} /> : <Person />}
      </button>
    )
  }
  const add = (s: TaskSuggestion, schedule: DraftSchedule, assigneeUid: string) => {
    void addRoutineTask(item.uid, s.title, schedule, assigneeUid).then(() => toast(`Added: ${s.title}`))
  }
  const addCustom = () => {
    const title = newTitle.trim()
    if (!title) return
    add({ title, value: newValue, unit: newUnit }, draftFor(newValue, newUnit, choreDays, now), newAssignee)
    setNewTitle('')
  }

  return (
    <Sheet title="Manage Routine" onClose={onClose}>
      <div className="item-editor-head" style={{ marginBottom: 14 }}>
        <ItemTile icon={item.icon} color={item.color} size={44} />
        <strong style={{ fontSize: 17 }}>{item.name}</strong>
      </div>

      <Section title="Tasks" footer="Tap a schedule to change it, or a person to make them responsible. Switched-off tasks keep their history but won’t remind you.">
        {tasks.length === 0 && <p className="empty-note">No tasks yet.</p>}
        {tasks.map((t) => (
          <div className="row routine-row" key={t.uid}>
            <span className="row-main">
              <span className="row-title" style={{ display: 'block' }}>{t.title}</span>
              <ScheduleButton title={t.title} value={draftFromTask(t)} onChange={(d) => void rescheduleTask(t, d)} />
            </span>
            {personButton(t.assigneeUid, t.title, (uid) => void setAssignee(t, uid))}
            <Switch on={t.isActive} onChange={(on) => void setTaskActive(t, on)} label={t.title} />
            <button type="button" className="trash-button" aria-label={`Delete “${t.title}”`} onClick={() => setToDelete(t)}>
              <Trash />
            </button>
          </div>
        ))}
      </Section>

      {suggestions.length > 0 && (
        <Section title="Suggested">
          {suggestions.map((s) => {
            const suggested = draftFromSuggestion(s, choreDays, now)
            const schedule = schedules[s.title] ?? suggested
            const assignee = assignees[s.title] ?? ''
            return (
              <div className="row routine-row" key={s.title}>
                <span className="row-main">
                  <span className="row-title" style={{ display: 'block' }}>{s.title}</span>
                  <ScheduleButton title={s.title} value={schedule} suggested={suggested} onChange={(d) => setSchedules({ ...schedules, [s.title]: d })} />
                </span>
                {personButton(assignee, s.title, (uid) => setAssignees({ ...assignees, [s.title]: uid }))}
                <button type="button" className="button small tinted" onClick={() => add(s, schedule, assignee)} aria-label={`Add “${s.title}” to the routine`}>
                  Add
                </button>
              </div>
            )
          })}
        </Section>
      )}

      <Section title="Custom task">
        <TextRow value={newTitle} onChange={setNewTitle} placeholder="Task, e.g. Check the hoses" onSubmit={addCustom} />
        <IntervalRows
          value={newValue}
          unit={newUnit}
          onChange={(v, u) => {
            setNewValue(v)
            setNewUnit(u)
          }}
        />
        <AssigneeRow value={newAssignee} onChange={setNewAssignee} />
        <Row className="action" title="Add Task" onClick={newTitle.trim() ? addCustom : undefined} />
      </Section>

      {toDelete && (
        <ConfirmSheet
          title={`Delete “${toDelete.title}”?`}
          message="Its history is deleted too. Switch it off instead to keep the history."
          confirm="Delete Task"
          destructive
          onConfirm={() =>
            void deleteTask(toDelete).then(() => {
              toast(`Deleted: ${toDelete.title}`)
              setToDelete(null)
            })
          }
          onClose={() => setToDelete(null)}
        />
      )}
    </Sheet>
  )
}
