// Fields shared by the item and task editors.
import { useState } from 'react'
import { SelectRow, SwitchRow, DateRow, WeekdayRow } from '../../../app/form'
import { useApp } from '../../../app/hooks'
import { ChevronRight } from '../../../app/icons'
import { Section, Segmented, Sheet } from '../../../app/ui'
import { INTERVAL_UNITS, ICON_KEYS, ROOM_SUGGESTIONS, type IconKey, type IntervalUnit } from '../catalog'
import { adjustDraft, choreDaysOf, describeDraft, sameDraft, type DraftSchedule } from '../editing'
import { compareTitles, snaps, unitLabel, type ScheduleKind } from '../schedule'
import type { TileColor } from '../../../core/people'
import { ItemTile } from '../tile'

const VALUES = Array.from({ length: 365 }, (_, i) => i + 1)

/** "Repeat every [3] [months]". */
export function IntervalRows({ value, unit, onChange }: { value: number; unit: IntervalUnit; onChange: (value: number, unit: IntervalUnit) => void }) {
  return (
    <div className="row">
      <span className="row-main">
        <span className="row-title">Repeat every</span>
      </span>
      <select className="inline" aria-label="How many" value={value} onChange={(e) => onChange(Number(e.target.value), unit)}>
        {VALUES.map((v) => (
          <option key={v} value={v}>
            {v}
          </option>
        ))}
      </select>
      <select className="inline" aria-label="Unit" value={unit} onChange={(e) => onChange(value, e.target.value as IntervalUnit)} style={{ flex: 'none' }}>
        {INTERVAL_UNITS.map((u) => (
          <option key={u} value={u}>
            {unitLabel(u, value)}
          </option>
        ))}
      </select>
    </div>
  )
}

/** Free text with the household's rooms and the usual ones offered, like the Mac's room combo box. */
export function RoomRow({ value, onChange }: { value: string; onChange: (room: string) => void }) {
  const { household } = useApp()
  const rooms = [...new Set([...household.items.map((i) => i.room.trim()).filter(Boolean), ...ROOM_SUGGESTIONS])].sort(compareTitles)
  return (
    <label className="row">
      <span className="row-title" style={{ flex: 'none', minWidth: 72 }}>Room</span>
      <input className="field" list="upkeep-rooms" value={value} placeholder="e.g. Kitchen — optional" aria-label="Room" onChange={(e) => onChange(e.target.value)} />
      <datalist id="upkeep-rooms">
        {rooms.map((r) => (
          <option key={r} value={r} />
        ))}
      </datalist>
    </label>
  )
}

export function IconPicker({ value, color, onChange }: { value: IconKey; color: TileColor; onChange: (icon: IconKey) => void }) {
  return (
    <div className="icon-grid" role="radiogroup" aria-label="Icon">
      {ICON_KEYS.map((key) => (
        <button key={key} type="button" role="radio" aria-checked={key === value} aria-label={key} className={key === value ? 'on' : ''} onClick={() => onChange(key)}>
          <ItemTile icon={key} color={key === value ? color : 'gray'} size={40} />
        </button>
      ))}
    </div>
  )
}

/** Who's responsible every time. Hidden while the household has no people. */
export function AssigneeRow({ value, onChange, title = 'Responsible' }: { value: string; onChange: (uid: string) => void; title?: string }) {
  const { household } = useApp()
  if (!household.people.length) return null
  return (
    <SelectRow
      title={title}
      value={value}
      options={[{ value: '', label: 'Everyone' }, ...household.people.map((p) => ({ value: p.uid, label: p.name || 'Unnamed' }))]}
      onChange={onChange}
    />
  )
}

/** A draft schedule's controls, as in the Mac's schedule popover. */
export function ScheduleFields({ value, onChange }: { value: DraftSchedule; onChange: (d: DraftSchedule) => void }) {
  const { me } = useApp()
  const choreDays = choreDaysOf(me)
  const set = (next: DraftSchedule) => onChange(adjustDraft(value, next, choreDays))
  return (
    <>
      <div className="row">
        <Segmented
          label="Schedule"
          value={value.kind}
          onChange={(kind: ScheduleKind) => set({ ...value, kind })}
          options={[
            { value: 'interval', label: 'After last done' },
            { value: 'fixedDate', label: 'On a date' },
          ]}
        />
      </div>
      {value.kind === 'fixedDate' && (
        <>
          <DateRow title="Due on" value={value.date} onChange={(date) => set({ ...value, date })} />
          <SwitchRow title="Repeats" on={value.repeats} onChange={(repeats) => set({ ...value, repeats })} />
        </>
      )}
      {(value.kind === 'interval' || value.repeats) && <IntervalRows value={value.value} unit={value.unit} onChange={(v, unit) => set({ ...value, value: v, unit })} />}
      {snaps(value.kind, value.value, value.unit) && (
        <WeekdayRow title="Do it on" value={value.preferredDays} onChange={(preferredDays) => onChange({ ...value, preferredDays })} />
      )}
    </>
  )
}

/** Shows a schedule as text; tapping it edits the schedule in a sheet. */
export function ScheduleButton({
  title,
  value,
  onChange,
  suggested,
  disabled,
}: {
  title: string
  value: DraftSchedule
  onChange: (d: DraftSchedule) => void
  /** The catalog default: a changed schedule stands out and can be reset to it. */
  suggested?: DraftSchedule
  disabled?: boolean
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(value)
  const changed = suggested ? !sameDraft(suggested, value) : false
  return (
    <>
      <button
        type="button"
        className={`schedule-button${changed ? ' changed' : ''}`}
        disabled={disabled}
        onClick={(e) => {
          e.stopPropagation()
          setDraft(value)
          setEditing(true)
        }}
        aria-label={`Change when “${title}” repeats: ${describeDraft(value)}`}
      >
        <span>{describeDraft(value)}</span>
        <ChevronRight />
      </button>
      {editing && (
        <Sheet
          title={title}
          onClose={() => setEditing(false)}
          left={<button className="bar-button" onClick={() => setEditing(false)}>Cancel</button>}
          right={
            <button
              className="bar-button bold"
              onClick={() => {
                onChange(draft)
                setEditing(false)
              }}
            >
              Done
            </button>
          }
          auto
        >
          <Section footer={describeDraft(draft)}>
            <ScheduleFields value={draft} onChange={setDraft} />
          </Section>
          {suggested && !sameDraft(suggested, draft) && (
            <button className="button wide tinted" onClick={() => setDraft(suggested)}>
              Use Suggested
            </button>
          )}
        </Sheet>
      )}
    </>
  )
}
