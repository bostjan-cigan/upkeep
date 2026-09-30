import type { ReactNode } from 'react'
import { useApp, usePreference } from '../../../app/hooks'
import { House, Seal } from '../../../app/icons'
import { CollapsibleHeader, Segmented } from '../../../app/ui'
import { isMine } from '../../../core/people'
import { firstWeekday } from '../calendar'
import { compareTitles, currentAssignee, groupByRoom, lastCompletedOf, isDue, needsAttention, roomTitle, upNextBucket, type Task } from '../schedule'
import { TaskRow } from './TaskRow'

type Scope = 'mine' | 'everyone'
type Mode = 'date' | 'room'

interface TaskSection {
  key: string
  title: string
  badge?: string
  tasks: Task[]
}

const BUCKETS = ['Overdue', 'Today', 'This Week', 'Done'] as const
const BUCKET_OF = { overdue: 'Overdue', today: 'Today', thisWeek: 'This Week', done: 'Done' } as const
const SEPARATOR = '|'

/** Everything across the home, grouped by when it's due or by room. */
export function UpNext({ banner, onAddItem }: { banner?: ReactNode; onAddItem: () => void }) {
  const { household, myUid, now } = useApp()
  const [scope, setScope] = usePreference<Scope>('upNextScope', 'mine')
  const [mode, setMode] = usePreference<Mode>('upNextMode', 'date')
  // Section keys the user collapsed.
  const [collapsedRaw, setCollapsedRaw] = usePreference<string>('collapsedUpNext', '')
  const collapsed = new Set(collapsedRaw.split(SEPARATOR).filter(Boolean))
  const toggle = (key: string) => {
    const next = new Set(collapsed)
    if (next.has(key)) next.delete(key)
    else next.add(key)
    setCollapsedRaw([...next].sort().join(SEPARATOR))
  }

  if (!household.items.length) {
    return (
      <>
        {banner}
        <div className="empty-state">
          <House />
          <h2>Nothing to look after yet</h2>
          <p>Add your dishwasher, windows, floors or anything else that needs regular care — or sync with your Mac at home.</p>
          <button className="button primary" onClick={onAddItem}>
            Add Your First Item
          </button>
        </div>
      </>
    )
  }

  // Paused and finished tasks come along in By Date: they may still be this week's receipts.
  const tasks = household.tasks
    .filter((t) => t.isActive || mode === 'date')
    .filter((t) => scope === 'everyone' || isMine(currentAssignee(t), myUid, household.people))
    .sort((a, b) => a.nextDueAt - b.nextDueAt || compareTitles(a.title, b.title))

  let sections: TaskSection[]
  if (mode === 'date') {
    const weekStart = firstWeekday()
    const buckets = new Map<string, Task[]>()
    for (const t of tasks) {
      const bucket = upNextBucket({ ...t, lastCompletedAt: lastCompletedOf(t) }, now, weekStart)
      if (bucket === 'hidden') continue
      buckets.set(BUCKET_OF[bucket], [...(buckets.get(BUCKET_OF[bucket]) ?? []), t])
    }
    sections = BUCKETS.flatMap((title) => {
      const list = buckets.get(title)
      if (!list) return []
      const sorted = title === 'Done' ? [...list].sort((a, b) => (lastCompletedOf(b) ?? 0) - (lastCompletedOf(a) ?? 0)) : list
      return [{ key: `date:${title}`, title, badge: String(list.length), tasks: sorted }]
    })
  } else {
    const groups = groupByRoom(tasks, (t) => household.itemsByUid.get(t.itemUid)?.room ?? '')
    sections = groups.map((g) => {
      const due = g.values.filter((t) => isDue(t, now)).length
      return { key: `room:${g.room}`, title: roomTitle(g.room, groups.length > 1), badge: due > 0 ? `${due} due` : undefined, tasks: g.values }
    })
  }

  return (
    <>
      {banner}
      <div className="controls">
        <Segmented
          label="Whose tasks"
          value={scope}
          onChange={setScope}
          options={[
            { value: 'mine', label: 'Mine' },
            { value: 'everyone', label: 'Everyone' },
          ]}
        />
        <Segmented
          label="Group"
          value={mode}
          onChange={setMode}
          options={[
            { value: 'date', label: 'By Date' },
            { value: 'room', label: 'By Room' },
          ]}
        />
      </div>
      {!tasks.some((t) => needsAttention(t, now)) && (
        <div className="hero">
          <Seal className="seal" />
          <div>
            <h3>All caught up</h3>
            <p>Nice. Nothing needs doing right now.</p>
          </div>
        </div>
      )}
      {sections.map((section) => {
        const open = !collapsed.has(section.key)
        return (
          <section className="section" key={section.key}>
            <CollapsibleHeader title={section.title} badge={section.badge} open={open} onToggle={() => toggle(section.key)} />
            {open && (
              <div className="card">
                {section.tasks.map((t) => (
                  <TaskRow key={t.uid} task={t} showsItem trailing={section.key === 'date:Done' ? 'undo' : 'done'} />
                ))}
              </div>
            )}
          </section>
        )
      })}
    </>
  )
}
