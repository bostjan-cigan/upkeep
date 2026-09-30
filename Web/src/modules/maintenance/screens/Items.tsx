import { useState } from 'react'
import { TextRow } from '../../../app/form'
import { useApp } from '../../../app/hooks'
import { House } from '../../../app/icons'
import { Row, Section, Sheet } from '../../../app/ui'
import { renameRoom } from '../editing'
import { groupByRoom, needsAttention, roomTitle } from '../schedule'
import { ItemTile } from '../tile'

/** Everything in the home, grouped by room. */
export function Items({ onAdd }: { onAdd: () => void }) {
  const { household, now, openItem, toast } = useApp()
  const [renaming, setRenaming] = useState<string | null>(null)
  const [newName, setNewName] = useState('')
  if (!household.items.length) {
    return (
      <div className="empty-state">
        <House />
        <h2>Nothing to look after yet</h2>
        <p>Add your dishwasher, windows, floors or anything else that needs regular care.</p>
        <button className="button primary" onClick={onAdd}>
          Add Your First Item
        </button>
      </div>
    )
  }
  const groups = groupByRoom(household.items, (i) => i.room)
  const save = () => {
    if (renaming === null) return
    const from = renaming
    void renameRoom(household.items, from, newName).then(() => {
      toast(newName.trim() ? `Renamed to ${newName.trim()}` : `${from} ungrouped`)
      setRenaming(null)
    })
  }
  return (
    <>
      {groups.map((g) => (
        <Section
          key={g.room}
          title={roomTitle(g.room, groups.length > 1)}
          action={
            g.room ? (
              <button
                className="section-action"
                onClick={() => {
                  setNewName(g.room)
                  setRenaming(g.room)
                }}
              >
                Rename
              </button>
            ) : undefined
          }
        >
          {g.values.map((item) => {
            const tasks = household.tasksByItem.get(item.uid) ?? []
            const waiting = tasks.filter((t) => needsAttention(t, now)).length
            const parts = [tasks.length === 1 ? '1 task' : `${tasks.length} tasks`]
            if (waiting) parts.push(`${waiting} waiting`)
            return (
              <Row
                key={item.uid}
                inset={72}
                leading={<ItemTile icon={item.icon} color={item.color} size={44} />}
                title={item.name}
                subtitle={parts.join(' · ')}
                trailing={waiting > 0 ? <span className="count-badge">{waiting}</span> : undefined}
                chevron
                onClick={() => openItem(item.uid)}
              />
            )
          })}
        </Section>
      ))}
      {renaming !== null && (
        <Sheet
          title="Rename Room"
          onClose={() => setRenaming(null)}
          left={<button className="bar-button" onClick={() => setRenaming(null)}>Cancel</button>}
          right={
            <button className="bar-button bold" onClick={save}>
              Rename
            </button>
          }
          auto
        >
          <Section footer="Every item in the room moves with it. Leave it empty to ungroup them.">
            <TextRow value={newName} onChange={setNewName} placeholder="Room name" autoFocus onSubmit={save} />
          </Section>
        </Sheet>
      )}
    </>
  )
}
