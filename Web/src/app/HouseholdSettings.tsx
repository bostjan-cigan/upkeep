// Settings › People and your reminders, as in the Mac's Settings › Household and Reminders.
import { useState } from 'react'
import { formatDateTime, formatTime } from '../core/dates'
import type { Person, Reminders, TileColor } from '../core/people'
import { TILE_COLORS } from '../core/people'
import { addPerson, removePerson, setChoreDays, silence, twinOf, unsilence, updatePerson, updateReminders } from '../core/peopleEditing'
import { setMyPerson } from '../core/push'
import { weekdaysLabel } from '../modules/maintenance/schedule'
import { ColorPicker, ConfirmSheet, SelectRow, SwitchRow, TextRow, WeekdayRow } from './form'
import { useApp } from './hooks'
import { Warning } from './icons'
import { Avatar, Row, Section, Sheet } from './ui'

function hourLabel(h: number): string {
  return formatTime(new Date(2000, 0, 1, h).getTime())
}
const hours = (from: number, to: number) => Array.from({ length: to - from + 1 }, (_, i) => ({ value: from + i, label: hourLabel(from + i) }))

// MARK: People

export function PeopleSection() {
  const { household, myUid, toast } = useApp()
  const [editing, setEditing] = useState<Person | 'new' | null>(null)
  const [menu, setMenu] = useState<Person | null>(null)
  const [removing, setRemoving] = useState<Person | null>(null)
  const people = household.people

  return (
    <>
      <Section title="People" footer="Assign tasks to a person to make them responsible. Unassigned tasks remind everyone.">
        {people.map((p) => (
          <Row
            key={p.uid}
            inset={56}
            leading={<Avatar person={p} size={30} />}
            title={p.name || 'Unnamed'}
            value={p.uid === myUid ? <span className="pill">You</span> : undefined}
            chevron
            onClick={() => setMenu(p)}
          />
        ))}
        <Row className="action" title="Add Person…" inset={56} onClick={() => setEditing('new')} />
      </Section>

      {menu && (
        <Sheet title={menu.name || 'Unnamed'} onClose={() => setMenu(null)} auto>
          <Section>
            <Row
              className="action"
              title="Edit…"
              onClick={() => {
                setEditing(menu)
                setMenu(null)
              }}
            />
            {menu.uid !== myUid && (
              <Row
                className="action"
                title="This Is Me"
                onClick={() => {
                  void setMyPerson(menu.uid)
                  toast(`You’re ${menu.name}`)
                  setMenu(null)
                }}
              />
            )}
            <Row
              className="destructive"
              title="Remove…"
              onClick={() => {
                setRemoving(menu)
                setMenu(null)
              }}
            />
          </Section>
        </Sheet>
      )}
      {editing && <PersonEditorSheet person={editing === 'new' ? undefined : editing} onClose={() => setEditing(null)} />}
      {removing && (
        <ConfirmSheet
          title={`Remove “${removing.name}”?`}
          message="Their tasks will be for everyone. Their history stays."
          confirm="Remove"
          destructive
          onConfirm={() =>
            void removePerson(removing.uid, myUid).then(() => {
              toast(`Removed: ${removing.name}`)
              setRemoving(null)
            })
          }
          onClose={() => setRemoving(null)}
        />
      )}
    </>
  )
}

/** Name and color. A new person can become "me" straight away, for a phone set up before anyone was added. */
export function PersonEditorSheet({ person, onClose, onCreated }: { person?: Person; onClose: () => void; onCreated?: (uid: string) => void }) {
  const { household, toast } = useApp()
  const [name, setName] = useState(person?.name ?? '')
  const [color, setColor] = useState<TileColor>(() => person?.color ?? TILE_COLORS[Math.floor(Math.random() * TILE_COLORS.length)]!)
  const twin = person ? undefined : twinOf(name, household.people)
  const canSave = name.trim() !== ''
  const save = () => {
    if (!canSave) return
    if (person) {
      void updatePerson(person.uid, name, color).then(onClose)
      return
    }
    void addPerson(name, color).then((uid) => {
      toast(`Added: ${name.trim()}`)
      onClose()
      onCreated?.(uid)
    })
  }
  return (
    <Sheet
      title={person ? 'Edit Person' : 'Add Person'}
      onClose={onClose}
      left={<button className="bar-button" onClick={onClose}>Cancel</button>}
      right={
        <button className="bar-button bold" disabled={!canSave} onClick={save}>
          {person ? 'Save' : twin ? 'Add Anyway' : 'Add'}
        </button>
      }
      auto
    >
      <Section
        footer={
          twin ? (
            <span style={{ display: 'flex', gap: 6, color: 'var(--orange)' }}>
              <Warning width={16} height={16} style={{ flex: 'none' }} />
              There’s already a “{twin.name}”. Adding another makes a second person, with their own tasks and history.
            </span>
          ) : undefined
        }
      >
        <TextRow value={name} onChange={setName} placeholder="Name" autoFocus onSubmit={save} />
        <div className="row stacked">
          <span className="row-title">Color</span>
          <ColorPicker value={color} onChange={setColor} />
        </div>
      </Section>
    </Sheet>
  )
}

// MARK: Reminders

/** My reminder settings. They're part of the person, so they follow me to every device. */
export function RemindersSection({ me }: { me: Person }) {
  const { now } = useApp()
  const r = me.reminders
  const set = (patch: Partial<Reminders>) => void updateReminders(me.uid, patch)
  const silenced = r.silencedUntil !== null && r.silencedUntil > now
  return (
    <>
      <Section
        title={`${me.name}’s Reminders`}
        footer="Upkeep keeps reminding you about your tasks and everyone’s until they’re done, snoozed or silenced. New chores land on your chore days, unless they come round rarely enough that the date matters. These settings follow you to all your devices."
      >
        <SelectRow
          title="Remind me every"
          value={r.nagHours}
          options={[1, 2, 3, 4, 6, 12].map((h) => ({ value: h, label: h === 1 ? 'hour' : `${h} hours` }))}
          onChange={(nagHours) => set({ nagHours })}
        />
        <SelectRow title="Starting at" value={r.activeStart} options={hours(5, 13)} onChange={(activeStart) => set({ activeStart })} />
        <SelectRow title="Until" value={r.activeEnd} options={hours(15, 23)} onChange={(activeEnd) => set({ activeEnd })} />
        <WeekdayRow title="Remind on" value={r.remindDays} onChange={(remindDays) => set({ remindDays })} />
        <WeekdayRow title="Chore days" value={me.choreDays} onChange={(days) => void setChoreDays(me.uid, days)} />
        <Row title={<span className="muted" style={{ fontSize: 15 }}>{weekdaysLabel(me.choreDays) ? `Chores land on ${weekdaysLabel(me.choreDays)}.` : 'Chores are due as soon as they come round.'}</span>} />
      </Section>

      <Section
        title="Work Schedule"
        footer={
          r.workEnabled
            ? `On work days, reminders from ${hourLabel(r.workStart)} until ${hourLabel(r.workEnd)} are skipped. Ones before and after work still arrive.`
            : 'Skip reminders during your working hours, so they only come before or after work.'
        }
      >
        <SwitchRow title="Don’t remind me at work" on={r.workEnabled} onChange={(workEnabled) => set({ workEnabled })} />
        {r.workEnabled && (
          <>
            <WeekdayRow title="Work days" value={r.workDays} onChange={(workDays) => set({ workDays })} />
            <SelectRow title="Work starts" value={r.workStart} options={hours(0, 23)} onChange={(workStart) => set({ workStart })} />
            <SelectRow title="Work ends" value={r.workEnd} options={hours(1, 23)} onChange={(workEnd) => set({ workEnd })} />
          </>
        )}
      </Section>

      <Section title="Silence" footer="Silencing stops all your reminders, on every device, until then.">
        {silenced ? (
          <>
            <Row title="Silenced until" value={formatDateTime(r.silencedUntil!)} />
            <Row className="action" title="Resume Reminders" onClick={() => void unsilence(me.uid)} />
          </>
        ) : (
          [1, 3, 7].map((days) => (
            <Row key={days} className="action" title={`Silence for ${days === 1 ? '1 Day' : days === 7 ? '1 Week' : `${days} Days`}`} onClick={() => void silence(me.uid, days)} />
          ))
        )}
      </Section>
    </>
  )
}
