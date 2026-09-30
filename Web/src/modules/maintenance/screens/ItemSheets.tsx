import { useMemo, useState } from 'react'
import { ChoiceRows, ColorPicker, ConfirmSheet, Switch, TextAreaRow, TextRow } from '../../../app/form'
import { useApp } from '../../../app/hooks'
import { Avatar, Row, Section, Sheet } from '../../../app/ui'
import { Person } from '../../../app/icons'
import { weekdaysLabel } from '../schedule'
import {
  CUSTOM_TEMPLATE_ID,
  ITEM_TEMPLATES,
  searchTemplates,
  TEMPLATE_CATEGORIES,
  type IntervalUnit,
  type ItemTemplate,
  type TaskSuggestion,
} from '../catalog'
import { addItem, choreDaysOf, deleteItem, draftFor, draftFromSuggestion, updateItem, type DraftSchedule, type ItemFields } from '../editing'
import type { HomeItem } from '../schedule'
import { ItemTile } from '../tile'
import { IconPicker, IntervalRows, RoomRow, ScheduleButton } from './fields'

// MARK: Edit item

/** Name, room, look and notes — and deleting it, for everyone. */
export function ItemEditorSheet({ item, onClose, onDeleted }: { item: HomeItem; onClose: () => void; onDeleted: () => void }) {
  const { household, toast } = useApp()
  const [fields, setFields] = useState<ItemFields>({ name: item.name, icon: item.icon, color: item.color, room: item.room, notes: item.notes })
  const [confirmingDelete, setConfirmingDelete] = useState(false)
  const taskCount = household.tasksByItem.get(item.uid)?.length ?? 0
  const canSave = fields.name.trim() !== ''

  return (
    <Sheet
      title="Edit Item"
      onClose={onClose}
      left={<button className="bar-button" onClick={onClose}>Cancel</button>}
      right={
        <button className="bar-button bold" disabled={!canSave} onClick={() => void updateItem(item.uid, fields).then(onClose)}>
          Save
        </button>
      }
    >
      <ItemFieldsForm fields={fields} onChange={setFields} />
      <Section title="Notes">
        <TextAreaRow value={fields.notes} onChange={(notes) => setFields({ ...fields, notes })} placeholder="Model number, filter type, where the manual is…" />
      </Section>
      <Section>
        <Row className="destructive" title="Delete Item…" onClick={() => setConfirmingDelete(true)} />
      </Section>
      {confirmingDelete && (
        <ConfirmSheet
          title={`Delete “${item.name}”?`}
          message={`Its ${taskCount === 1 ? 'task' : `${taskCount} tasks`} and maintenance history will be removed for everyone in the household.`}
          confirm="Delete"
          destructive
          onConfirm={() =>
            void deleteItem(item.uid).then(() => {
              toast(`Deleted: ${item.name}`)
              onDeleted()
            })
          }
          onClose={() => setConfirmingDelete(false)}
        />
      )}
    </Sheet>
  )
}

/** Big tile and name, then room, color and icon (the icon grid opens on demand, as on the Mac). */
function ItemFieldsForm({ fields, onChange }: { fields: ItemFields; onChange: (f: ItemFields) => void }) {
  const [showIcons, setShowIcons] = useState(false)
  return (
    <>
      <div className="item-editor-head">
        <ItemTile icon={fields.icon} color={fields.color} size={72} />
        <input
          className="item-name"
          value={fields.name}
          placeholder="Name, e.g. Kitchen Dishwasher"
          aria-label="Name"
          onChange={(e) => onChange({ ...fields, name: e.target.value })}
        />
      </div>
      <Section>
        <RoomRow value={fields.room} onChange={(room) => onChange({ ...fields, room })} />
        <div className="row stacked">
          <span className="row-title">Color</span>
          <ColorPicker value={fields.color} onChange={(color) => onChange({ ...fields, color })} />
        </div>
        <Row
          title="Icon"
          trailing={<ItemTile icon={fields.icon} color={fields.color} size={28} />}
          chevron={!showIcons}
          onClick={() => setShowIcons(!showIcons)}
        />
        {showIcons && (
          <div className="row stacked" style={{ paddingTop: 0 }}>
            <IconPicker value={fields.icon} color={fields.color} onChange={(icon) => onChange({ ...fields, icon })} />
          </div>
        )}
      </Section>
    </>
  )
}

// MARK: Add item

interface Choice {
  key: string
  suggestion: TaskSuggestion
  suggested: DraftSchedule
  schedule: DraftSchedule
  assigneeUid: string
  chosen: boolean
}

/** Two steps, as on the Mac: pick what it is, then confirm name, look and suggested routine. */
export function AddItemSheet({ onClose, onCreated }: { onClose: () => void; onCreated: (uid: string) => void }) {
  const [template, setTemplate] = useState<ItemTemplate | null>(null)
  const [search, setSearch] = useState('')
  // Coming back from the details step swaps the sheet's contents rather than sliding a new one up.
  const [returning, setReturning] = useState(false)
  if (!template) {
    return (
      <Sheet title="Add Item" still={!!search || returning} onClose={onClose} left={<button className="bar-button" onClick={onClose}>Cancel</button>} right={<span />}>
        <TemplatePicker
          search={search}
          onSearch={setSearch}
          onPick={(t, name) => {
            setTemplate(name === undefined ? t : { ...t, name })
          }}
        />
      </Sheet>
    )
  }
  return (
    <ItemDetailsStep
      template={template}
      onBack={() => {
        setReturning(true)
        setTemplate(null)
      }}
      onClose={onClose}
      onCreated={onCreated}
    />
  )
}

function TemplatePicker({ search, onSearch, onPick }: { search: string; onSearch: (q: string) => void; onPick: (t: ItemTemplate, name?: string) => void }) {
  const found = useMemo(() => searchTemplates(search), [search])
  const custom = ITEM_TEMPLATES.find((t) => t.id === CUSTOM_TEMPLATE_ID)!
  return (
    <>
      <h2 className="sheet-heading">What would you like to look after?</h2>
      <input className="search" type="search" value={search} placeholder="Search, e.g. robot vacuum" aria-label="Search" onChange={(e) => onSearch(e.target.value)} />
      {TEMPLATE_CATEGORIES.map(([key, title]) => {
        const list = found.filter((t) => t.category === key)
        if (!list.length) return null
        return (
          <div key={key} className="template-group">
            <h3>{title}</h3>
            <div className="template-grid">
              {list.map((t) => (
                <button key={t.id} type="button" className="template" onClick={() => onPick(t)}>
                  <ItemTile icon={t.icon} color={t.color} size={56} />
                  <span>{t.name}</span>
                </button>
              ))}
            </div>
          </div>
        )
      })}
      {found.length === 0 && (
        <div className="empty-state" style={{ padding: '30px 12px' }}>
          <p>Nothing called “{search.trim()}” yet.</p>
          <button className="button tinted" onClick={() => onPick(custom, search.trim())}>
            Add “{search.trim()}” as a custom item
          </button>
        </div>
      )}
    </>
  )
}

function ItemDetailsStep({ template, onBack, onClose, onCreated }: { template: ItemTemplate; onBack: () => void; onClose: () => void; onCreated: (uid: string) => void }) {
  const { household, me, now, toast } = useApp()
  const choreDays = choreDaysOf(me)
  const isCustom = template.id === CUSTOM_TEMPLATE_ID
  const [fields, setFields] = useState<ItemFields>({
    name: isCustom && template.name === ITEM_TEMPLATES.find((t) => t.id === CUSTOM_TEMPLATE_ID)!.name ? '' : template.name,
    icon: template.icon,
    color: template.color,
    room: template.room,
    notes: '',
  })
  const [choices, setChoices] = useState<Choice[]>(() =>
    template.suggestions.map((s, i) => {
      const draft = draftFromSuggestion(s, choreDays, now)
      return { key: `s${i}`, suggestion: s, suggested: draft, schedule: draft, assigneeUid: '', chosen: true }
    }),
  )
  const [newTitle, setNewTitle] = useState('')
  const [newValue, setNewValue] = useState(1)
  const [newUnit, setNewUnit] = useState<IntervalUnit>('month')
  const [startFresh, setStartFresh] = useState(true)
  const [busy, setBusy] = useState(false)
  const canSave = fields.name.trim() !== '' && !busy

  const update = (key: string, change: Partial<Choice>) => setChoices(choices.map((c) => (c.key === key ? { ...c, ...change } : c)))
  const addCustom = () => {
    const title = newTitle.trim()
    if (!title) return
    const draft = draftFor(newValue, newUnit, choreDays, now)
    setChoices([...choices, { key: `c${choices.length}-${Date.now()}`, suggestion: { title, value: newValue, unit: newUnit }, suggested: draft, schedule: draft, assigneeUid: '', chosen: true }])
    setNewTitle('')
  }
  const save = () => {
    if (!canSave) return
    setBusy(true)
    const tasks = choices.filter((c) => c.chosen).map((c) => ({ title: c.suggestion.title, schedule: c.schedule, assigneeUid: c.assigneeUid }))
    void addItem(fields, tasks, startFresh).then((uid) => {
      toast(`Added: ${fields.name.trim()}`)
      onCreated(uid)
    })
  }
  const people = household.people
  const nextPerson = (uid: string) => {
    // Tapping the person cycles through everyone, then each person.
    const order = ['', ...people.map((p) => p.uid)]
    return order[(order.indexOf(uid) + 1) % order.length] ?? ''
  }

  return (
    <Sheet
      still
      title={isCustom ? 'New Item' : template.name}
      onClose={onClose}
      left={<button className="bar-button" onClick={onBack}>Back</button>}
      right={
        <button className="bar-button bold" disabled={!canSave} onClick={save}>
          Add
        </button>
      }
    >
      <ItemFieldsForm fields={fields} onChange={setFields} />

      <Section title="Routine" footer="Tap a schedule to change how often it repeats, or a person to make them responsible. You can change or add tasks any time.">
        {choices.length === 0 && <p className="empty-note">No suggestions for this one. Add your own below.</p>}
        {choices.map((c) => {
          const person = people.find((p) => p.uid === c.assigneeUid)
          return (
            <div className="row routine-row" key={c.key}>
              <span className="row-main">
                <span className="row-title" style={{ display: 'block', opacity: c.chosen ? 1 : 0.5 }}>{c.suggestion.title}</span>
                <ScheduleButton title={c.suggestion.title} value={c.schedule} suggested={c.suggested} disabled={!c.chosen} onChange={(schedule) => update(c.key, { schedule })} />
              </span>
              {people.length > 0 && (
                <button
                  type="button"
                  className="who-button"
                  disabled={!c.chosen}
                  aria-label={`Responsible for “${c.suggestion.title}”: ${person?.name ?? 'everyone'}`}
                  onClick={() => update(c.key, { assigneeUid: nextPerson(c.assigneeUid) })}
                >
                  {person ? <Avatar person={person} size={24} /> : <Person />}
                </button>
              )}
              <Switch on={c.chosen} onChange={(chosen) => update(c.key, { chosen })} label={c.suggestion.title} />
            </div>
          )
        })}
      </Section>

      <Section title="Add your own task">
        <TextRow value={newTitle} onChange={setNewTitle} placeholder="Task, e.g. Check the hoses" onSubmit={addCustom} />
        <IntervalRows
          value={newValue}
          unit={newUnit}
          onChange={(v, u) => {
            setNewValue(v)
            setNewUnit(u)
          }}
        />
        <Row className="action" title="Add Task" onClick={newTitle.trim() ? addCustom : undefined} />
      </Section>

      <Section title="Getting started">
        <ChoiceRows
          value={startFresh ? 'fresh' : 'later'}
          onChange={(v) => setStartFresh(v === 'fresh')}
          options={[
            { value: 'fresh', label: 'I just did these — start the clock today' },
            {
              value: 'later',
              label: weekdaysLabel(choreDays) === null ? 'Not sure — remind me about them now' : 'Not sure — put them on my next chore day',
            },
          ]}
        />
      </Section>
    </Sheet>
  )
}
