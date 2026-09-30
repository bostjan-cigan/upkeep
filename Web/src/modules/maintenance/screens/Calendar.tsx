import { useMemo, useRef, useState, type TouchEvent } from 'react'
import { useApp, usePreference } from '../../../app/hooks'
import { ChevronLeft, ChevronRight } from '../../../app/icons'
import { Section, Segmented } from '../../../app/ui'
import { addCalendar, addDays, formatMonthYear, formatWeekdayDayMonth, startOfDay, startOfMonth, WEEKDAYS_SHORT, type Millis } from '../../../core/dates'
import { isMine } from '../../../core/people'
import { firstWeekday, gridDays, occurrences, type CalendarOccurrence } from '../calendar'
import { isDue } from '../schedule'
import { ItemTile } from '../tile'
import { TaskRow } from './TaskRow'

type Scope = 'mine' | 'everyone'
const MAX_ICONS = 3

/** Month grid of upcoming tasks with item icons on each day; tapping a day lists its tasks. */
export function Calendar() {
  const { household, myUid, now } = useApp()
  // Shared with Up Next.
  const [scope, setScope] = usePreference<Scope>('upNextScope', 'mine')
  const today = startOfDay(now)
  const [month, setMonth] = useState(() => startOfMonth(now))
  const [selected, setSelected] = useState(today)
  const weekStart = useMemo(() => firstWeekday(), [])
  const days = useMemo(() => gridDays(month, weekStart), [month, weekStart])

  const byDay = useMemo(() => {
    const all = occurrences(household.tasks, days[0]!, addDays(days[days.length - 1]!, 1), now)
    if (scope === 'everyone') return all
    // One at a time: a hand-over covers only the next occurrence, not the repeats after it.
    const mine = new Map<Millis, CalendarOccurrence[]>()
    for (const [day, list] of all) {
      const kept = list.filter((o) => isMine(o.assigneeUid, myUid, household.people))
      if (kept.length) mine.set(day, kept)
    }
    return mine
  }, [household, scope, myUid, days, now])

  const showMonth = (next: Millis) => {
    setMonth(next)
    // Keep the selection inside the visible month: today if it's there, else the 1st.
    setSelected(startOfMonth(today) === next ? today : next)
  }
  const shift = (delta: number) => showMonth(addCalendar(month, 'month', delta))
  const select = (day: Millis) => {
    setSelected(day)
    if (startOfMonth(day) !== month) setMonth(startOfMonth(day))
  }

  // Horizontal swipe on the grid changes month.
  const touch = useRef<{ x: number; y: number } | null>(null)
  const onTouchStart = (e: TouchEvent) => {
    const t = e.touches[0]
    touch.current = t ? { x: t.clientX, y: t.clientY } : null
  }
  const onTouchEnd = (e: TouchEvent) => {
    const start = touch.current
    const t = e.changedTouches[0]
    touch.current = null
    if (!start || !t) return
    const dx = t.clientX - start.x
    const dy = t.clientY - start.y
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) shift(dx < 0 ? 1 : -1)
  }

  const list = byDay.get(selected) ?? []
  const atToday = month === startOfMonth(today) && selected === today
  const dayTitle = selected === today ? 'Today' : selected === addDays(today, 1) ? 'Tomorrow' : formatWeekdayDayMonth(selected)
  const trailing = (o: CalendarOccurrence) => (o.isProjected ? 'projected' : isDue(o.task, now) ? 'done' : 'none')

  return (
    <>
      <div className="controls" style={{ maxWidth: 560, marginLeft: 'auto', marginRight: 'auto' }}>
        <Segmented
          label="Whose tasks"
          value={scope}
          onChange={setScope}
          options={[
            { value: 'mine', label: 'Mine' },
            { value: 'everyone', label: 'Everyone' },
          ]}
        />
      </div>
      <div className="cal" onTouchStart={onTouchStart} onTouchEnd={onTouchEnd}>
        <div className="cal-head">
          <h2>{formatMonthYear(month)}</h2>
          <button className="bar-button" onClick={() => select(today)} disabled={atToday}>
            Today
          </button>
          <button className="bar-button icon" onClick={() => shift(-1)} aria-label="Previous month">
            <ChevronLeft />
          </button>
          <button className="bar-button icon" onClick={() => shift(1)} aria-label="Next month">
            <ChevronRight />
          </button>
        </div>
        <div className="cal-week" aria-hidden="true">
          {Array.from({ length: 7 }, (_, i) => (
            <div key={i}>{WEEKDAYS_SHORT[(weekStart + i) % 7]}</div>
          ))}
        </div>
        <div className="cal-grid">
          {days.map((day) => {
            const occ = byDay.get(day) ?? []
            const shown = occ.slice(0, MAX_ICONS)
            const overflow = occ.length > shown.length
            const classes = ['cal-day']
            if (startOfMonth(day) !== month) classes.push('out')
            if (day === today) classes.push('today')
            if (day === selected) classes.push('selected')
            return (
              <button
                key={day}
                className={classes.join(' ')}
                onClick={() => select(day)}
                aria-pressed={day === selected}
                aria-label={`${formatWeekdayDayMonth(day)}, ${occ.length === 1 ? '1 task' : `${occ.length} tasks`}`}
              >
                <span className="num">
                  {new Date(day).getDate()}
                  {occ.some((o) => o.isOverdue) && <span className="overdue-dot" />}
                </span>
                <span className="cal-icons">
                  {shown.map((o) => {
                    const item = household.itemsByUid.get(o.task.itemUid)
                    return (
                      <span key={`${o.task.uid}-${o.day}`} className={o.isProjected ? 'dim' : undefined} style={{ display: 'flex' }}>
                        <ItemTile icon={item?.icon ?? 'generic'} color={item?.color ?? 'gray'} size={14} />
                      </span>
                    )
                  })}
                  {overflow && <span className="more">+{occ.length - shown.length}</span>}
                </span>
              </button>
            )
          })}
        </div>
      </div>

      <div className="day-list">
        <Section title={dayTitle} big action={list.length ? <span className="muted" style={{ fontSize: 15 }}>{list.length === 1 ? '1 task' : `${list.length} tasks`}</span> : undefined}>
          {list.length === 0 && <p className="empty-note">Nothing due on {formatWeekdayDayMonth(selected)}.</p>}
          {list.map((o) => (
            <TaskRow key={`${o.task.uid}-${o.day}`} task={o.task} showsItem trailing={trailing(o)} />
          ))}
        </Section>
      </div>
    </>
  )
}
