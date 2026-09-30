import { useState } from 'react'
import { ConfirmSheet } from '../../../app/form'
import { useApp } from '../../../app/hooks'
import { CheckCircleFill, Pause, Plus, Sliders } from '../../../app/icons'
import { Section } from '../../../app/ui'
import { formatDate, formatDateTime } from '../../../core/dates'
import { removeLog, setTaskActive } from '../editing'
import { activeTasks, historyOf, intervalDescription, isFinished, needsAttention, pausedTasks, type Task, type TaskLog } from '../schedule'
import { ItemTile } from '../tile'
import { ItemEditorSheet } from './ItemSheets'
import { RoutineSheet } from './RoutineSheet'
import { TaskEditorSheet } from './TaskEditorSheet'
import { TaskRow } from './TaskRow'

/** One item: its routine, paused or finished tasks, and history — all editable, as on the Mac. */
export function ItemDetail({ uid, onDeleted }: { uid: string; onDeleted: () => void }) {
  const { household, now, toast } = useApp()
  const [showAll, setShowAll] = useState(false)
  const [editingItem, setEditingItem] = useState(false)
  const [managing, setManaging] = useState(false)
  const [editingTask, setEditingTask] = useState<Task | 'new' | null>(null)
  const [removing, setRemoving] = useState<{ log: TaskLog; task: Task } | null>(null)
  const item = household.itemsByUid.get(uid)
  if (!item) return <p className="empty-note">This item was removed.</p>

  const tasks = household.tasksByItem.get(uid) ?? []
  const routine = activeTasks(tasks)
  const paused = pausedTasks(tasks)
  const history = historyOf(tasks)
  const shown = showAll ? history : history.slice(0, 8)
  const waiting = tasks.filter((t) => needsAttention(t, now)).length
  const summary = [tasks.length === 1 ? '1 routine task' : `${tasks.length} routine tasks`]
  if (waiting) summary.push(`${waiting} waiting`)
  if (item.room) summary.unshift(item.room)
  const personName = (personUid: string) => household.people.find((p) => p.uid === personUid)?.name
  // The sheet keeps up with sync: edit the task as it is now, not as it was when opened.
  const liveTask = editingTask && editingTask !== 'new' ? household.tasksByUid.get(editingTask.uid) : undefined

  return (
    <>
      <div className="item-header">
        <ItemTile icon={item.icon} color={item.color} size={88} />
        <div style={{ minWidth: 0, flex: 1 }}>
          <h1>{item.name}</h1>
          <div className="summary">{summary.join(' · ')}</div>
          {item.notes && <div className="notes">{item.notes}</div>}
        </div>
      </div>
      <div className="item-actions">
        <button className="button small tinted" onClick={() => setEditingItem(true)}>
          Edit Item
        </button>
        <button className="button small tinted" onClick={() => setManaging(true)}>
          <Sliders width={16} height={16} /> Manage
        </button>
        <button className="button small tinted" onClick={() => setEditingTask('new')}>
          <Plus width={16} height={16} /> Add Task
        </button>
      </div>

      <Section title="Routine" big>
        {routine.length === 0 && <p className="empty-note">No tasks yet. Add one, like “Clean the filter every month”.</p>}
        {routine.map((t) => (
          <TaskRow key={t.uid} task={t} onOpen={() => setEditingTask(t)} />
        ))}
      </Section>

      {paused.length > 0 && (
        <Section title={paused.every(isFinished) ? 'Done' : 'Paused'} big>
          {paused.map((t) => (
            <div className="row" key={t.uid}>
              <button className="row-main row-open" onClick={() => setEditingTask(t)} aria-label={`Edit “${t.title}”`}>
                <span className="row-title muted" style={{ display: 'block' }}>
                  <span style={{ display: 'inline-flex', verticalAlign: '-4px', marginRight: 8 }}>
                    {isFinished(t) ? <CheckCircleFill width={20} height={20} /> : <Pause width={20} height={20} />}
                  </span>
                  {t.title}
                </span>
                <span className="row-sub" style={{ display: 'block' }}>{intervalDescription(t)}</span>
              </button>
              {isFinished(t) ? (
                <span className="row-value" style={{ fontSize: 15 }}>Done</span>
              ) : (
                <button className="button small tinted" onClick={() => void setTaskActive(t, true).then(() => toast(`Resumed: ${t.title}`))}>
                  Resume
                </button>
              )}
            </div>
          ))}
        </Section>
      )}

      <Section
        title="History"
        big
        action={
          history.length > 8 ? (
            <button className="section-action" onClick={() => setShowAll(!showAll)}>
              {showAll ? 'Show Less' : `Show All ${history.length}`}
            </button>
          ) : undefined
        }
      >
        {history.length === 0 && <p className="empty-note">Completed tasks will show up here.</p>}
        {shown.map(({ log, task }) => {
          const by = log.completedByUid ? personName(log.completedByUid) : undefined
          return (
            <button className="row" key={log.uid} title={formatDateTime(log.completedAt)} onClick={() => setRemoving({ log, task })}>
              <span style={{ display: 'flex', color: 'var(--green)' }}>
                <CheckCircleFill width={22} height={22} />
              </span>
              <span className="row-main">
                <span className="row-title" style={{ display: 'block' }}>{task.title}</span>
                {(by || log.note) && (
                  <span className="row-sub" style={{ display: 'block' }}>{[by && `by ${by}`, log.note].filter(Boolean).join(' · ')}</span>
                )}
              </span>
              <span className="row-value" style={{ fontSize: 15 }}>{formatDate(log.completedAt)}</span>
            </button>
          )
        })}
      </Section>

      {editingItem && <ItemEditorSheet item={item} onClose={() => setEditingItem(false)} onDeleted={onDeleted} />}
      {managing && <RoutineSheet item={item} onClose={() => setManaging(false)} />}
      {editingTask === 'new' && <TaskEditorSheet itemUid={item.uid} onClose={() => setEditingTask(null)} />}
      {liveTask && <TaskEditorSheet key={liveTask.uid} task={liveTask} onClose={() => setEditingTask(null)} />}
      {removing && (
        <ConfirmSheet
          title="Remove from History?"
          message={`“${removing.task.title}”, done ${formatDateTime(removing.log.completedAt)}${
            removing.log.completedByUid && personName(removing.log.completedByUid) ? ` by ${personName(removing.log.completedByUid)}` : ''
          }. Its schedule goes back to what the rest of the history says.`}
          confirm="Remove from History"
          destructive
          onConfirm={() =>
            void removeLog(removing.task, removing.log.uid).then(() => {
              toast('Removed from history')
              setRemoving(null)
            })
          }
          onClose={() => setRemoving(null)}
        />
      )}
    </>
  )
}
