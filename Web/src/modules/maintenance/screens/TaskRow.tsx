import { useState } from 'react'
import { useApp } from '../../../app/hooks'
import { CalendarIcon, CheckCircle, CheckCircleFill, Moon, Person } from '../../../app/icons'
import { Avatar } from '../../../app/ui'
import { calendarDaysBetween, WEEKDAYS_LONG, WEEKDAYS_SHORT } from '../../../core/dates'
import { effectiveAssignee } from '../../../core/people'
import { markDone, undoLastDone, undoMarkDone } from '../actions'
import { currentAssignee, dueStatus, dueStatusText, intervalDescription, isSnoozed, type Task } from '../schedule'
import { ItemTile } from '../tile'
import { HandOffSheet } from './HandOffSheet'
import { MoveSheet } from './MoveSheet'

/** A single chore with a big friendly "done" button. Tapping the row opens its item, or `onOpen`. */
export function TaskRow({
  task,
  showsItem = false,
  trailing = 'done',
  onOpen,
}: {
  task: Task
  showsItem?: boolean
  /** Instead of opening the item — on the item's own screen, it edits the task. */
  onOpen?: () => void
  /** What sits at the end of the row: the Done button, Undo for something already done,
   * a "Projected" label, or nothing. */
  trailing?: 'done' | 'undo' | 'projected' | 'none'
}) {
  const { household, myUid, now, openItem, toast } = useApp()
  const [justCompleted, setJustCompleted] = useState(false)
  const [moving, setMoving] = useState(false)
  const [handingOff, setHandingOff] = useState(false)
  const item = household.itemsByUid.get(task.itemUid)
  const usualUid = effectiveAssignee(task.assigneeUid, household.people)
  // A hand-over covers the occurrence that's due next, not the repeats after it.
  const assigneeUid = trailing === 'projected' ? usualUid : effectiveAssignee(currentAssignee(task), household.people)
  const handedOver = assigneeUid !== usualUid
  const assignee = assigneeUid ? household.people.find((p) => p.uid === assigneeUid) : undefined
  const status = dueStatus(task.nextDueAt, now)
  const snoozed = isSnoozed(task, now)
  const subtitle = showsItem && item ? `${item.name} · ${intervalDescription(task)}` : intervalDescription(task)
  const doneBy = household.people.find((p) => p.uid === lastLog(task)?.completedByUid)

  const complete = () => {
    if (justCompleted) return
    setJustCompleted(true)
    navigator.vibrate?.(10)
    setTimeout(() => {
      void markDone(task, myUid).then((receipt) => {
        setJustCompleted(false)
        toast(`Done: ${task.title}`, { label: 'Undo', run: () => void undoMarkDone(receipt) })
      })
    }, 450)
  }

  const open = () => {
    if (onOpen) onOpen()
    else if (item) openItem(item.uid)
  }

  const undo = () => {
    void undoLastDone(task).then(() => toast(`Back on the list: ${task.title}`))
  }

  return (
    <div
      className={`task-row${justCompleted || trailing === 'undo' ? ' done' : ''}${showsItem ? '' : ' no-icon'}${
        trailing === 'projected' ? ' projected' : ''
      }`}
    >
      {/* A div, not a button: the Move control sits inside it, on the line that shows the due date. */}
      <div
        className="open"
        role="button"
        tabIndex={0}
        onClick={open}
        onKeyDown={(e) => {
          if (e.key !== 'Enter' && e.key !== ' ') return
          e.preventDefault()
          open()
        }}
        aria-label={onOpen ? `Edit “${task.title}”` : `${task.title}${item ? `, ${item.name}` : ''}`}
      >
        {showsItem && item && <ItemTile icon={item.icon} color={item.color} size={36} />}
        <span className="text">
          <span className="title" style={{ display: 'block' }}>{task.title}</span>
          <span className="sub" style={{ display: 'block' }}>{subtitle}</span>
          <span className="meta">
            {trailing === 'undo' ? (
              <span className="status">{doneText(task, now, doneBy?.name)}</span>
            ) : trailing === 'projected' ? null : snoozed && task.snoozedUntil !== null ? (
              <span className="status snoozed" title="Snoozed">
                <Moon /> Until {WEEKDAYS_SHORT[new Date(task.snoozedUntil).getDay()]}
              </span>
            ) : (
              <span className={`status ${status.kind}`}>{dueStatusText(status)}</span>
            )}
            {trailing === 'done' && (
              <button
                className="move"
                onClick={(e) => {
                  e.stopPropagation()
                  setMoving(true)
                }}
                aria-label={`Move “${task.title}” to another day`}
              >
                <CalendarIcon /> Move
              </button>
            )}
            {trailing === 'done' && household.people.length > 0 ? (
              <button
                className="who"
                onClick={(e) => {
                  e.stopPropagation()
                  setHandingOff(true)
                }}
                aria-label={`Who’s doing “${task.title}” this time: ${assignee?.name ?? 'everyone'}`}
              >
                {assignee ? <Avatar person={assignee} size={18} /> : <Person />}
                {/* A hand-over says so; the avatar already says who. */}
                {handedOver ? <span>This time</span> : assignee && <span>{assignee.name}</span>}
              </button>
            ) : (
              <>
                {assignee && <Avatar person={assignee} size={18} />}
                {handedOver ? <span className="muted">This time</span> : assignee && <span className="muted">{assignee.name}</span>}
              </>
            )}
          </span>
        </span>
      </div>
      {trailing === 'done' && (
        <button className="check" onClick={complete} disabled={justCompleted} aria-label={`Mark “${task.title}” as done`}>
          {justCompleted ? <CheckCircleFill /> : <CheckCircle />}
        </button>
      )}
      {trailing === 'undo' && (
        <button className="undo" onClick={undo} aria-label={`Put “${task.title}” back on the list`}>
          Undo
        </button>
      )}
      {trailing === 'projected' && <span className="projected-label">Projected</span>}
      {moving && <MoveSheet task={task} onClose={() => setMoving(false)} />}
      {handingOff && <HandOffSheet task={task} onClose={() => setHandingOff(false)} />}
    </div>
  )
}

function lastLog(task: Task) {
  return task.logs.reduce<Task['logs'][number] | undefined>((newest, log) => (!newest || log.completedAt > newest.completedAt ? log : newest), undefined)
}

/** "Done today by Ana" — who cleared it, and when. */
function doneText(task: Task, now: number, who?: string): string {
  const at = lastLog(task)?.completedAt
  if (at === undefined) return 'Done'
  const days = calendarDaysBetween(at, now)
  const when = days === 0 ? 'today' : days === 1 ? 'yesterday' : WEEKDAYS_LONG[new Date(at).getDay()]
  return who ? `Done ${when} by ${who}` : `Done ${when}`
}
