import { useState } from 'react'
import { Row, Section, Segmented, Sheet } from '../../../app/ui'
import { formatDate, localDay, startOfDay, weekday, type Millis } from '../../../core/dates'
import { moveOccurrence, type MoveScope } from '../actions'
import { canMoveSeries, intervalDescription, movesByWeekday, weekdaysLabel, weekdayString, type Task } from '../schedule'

/** The `<input type="date">` value for a local day. */
function dateInputValue(ms: Millis): string {
  const d = new Date(ms)
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

function parseDateInput(value: string): Millis | null {
  const [y, m, d] = value.split('-').map(Number)
  if (!y || !m || !d) return null
  return localDay(y, m - 1, d)
}

/**
 * Moves a task's next occurrence, asking what the move applies to the way a calendar does.
 */
export function MoveSheet({ task, onClose }: { task: Task; onClose: () => void }) {
  const [day, setDay] = useState(() => startOfDay(task.nextDueAt))
  const [scope, setScope] = useState<MoveScope>('thisOnce')
  const moved = day !== startOfDay(task.nextDueAt)
  const seriesMoves = canMoveSeries(task)

  const explanation = () => {
    if (!seriesMoves) {
      return `This one comes round ${intervalDescription(task).toLowerCase()} after it's done, so there's nothing lasting to move — only this one.`
    }
    if (scope === 'thisOnce') return 'Only this one moves. The one after it comes round as usual.'
    if (task.scheduleKind === 'fixedDate' && task.anchorDate !== null) {
      return task.repeats ? 'Every date in the series moves by the same number of days.' : 'This one-off moves to the new date.'
    }
    if (!movesByWeekday(task)) return 'It starts from the new date.'
    return `Every one after this lands on ${weekdaysLabel(weekdayString([weekday(day)])) ?? 'that day'} too.`
  }

  const save = () => {
    void moveOccurrence(task, day, scope).then(onClose)
  }

  return (
    <Sheet
      title="Move"
      onClose={onClose}
      left={<button className="bar-button" onClick={onClose}>Cancel</button>}
      right={<button className="bar-button bold" onClick={save} disabled={!moved}>Move</button>}
      auto
    >
      <Section title={task.title} footer={`Currently due ${formatDate(task.nextDueAt)}.`}>
        <Row
          title="Move to"
          trailing={
            <input
              className="inline"
              type="date"
              aria-label="Move to"
              value={dateInputValue(day)}
              onChange={(e) => {
                const parsed = parseDateInput(e.target.value)
                if (parsed !== null) setDay(parsed)
              }}
            />
          }
        />
      </Section>
      <Section footer={explanation()}>
        {seriesMoves ? (
          <Segmented
            label="What this move applies to"
            value={scope}
            onChange={setScope}
            options={[
              { value: 'thisOnce', label: 'This time' },
              { value: 'allFuture', label: 'All future' },
            ]}
          />
        ) : (
          <Row title="This time only" />
        )}
      </Section>
    </Sheet>
  )
}
