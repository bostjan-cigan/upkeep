// Adding and editing household members and their reminder settings, as the Mac's Settings do
// (HouseholdViews.swift, SettingsView.swift). Reminder settings belong to the person, so a change
// here reaches the Mac that sends this person's reminders.
import { addDays, encodeDate, type Millis } from './dates'
import { setMeta, write } from './db'
import { PERSON, type Person, type Reminders, type TileColor } from './people'
import type { JsonObject, JsonValue } from './snapshot'

/** Trimmed, case- and diacritic-insensitive equality, like `Names.sameName`: "Ana" and " aña " are one person. */
export function sameName(a: string, b: string): boolean {
  const normalize = (s: string) => s.trim().normalize('NFKD').replace(/\p{M}/gu, '').toLocaleLowerCase()
  const left = normalize(a)
  return left !== '' && left === normalize(b)
}

/** Someone already here under this name — adding another splits their tasks and history. */
export function twinOf(name: string, people: readonly Person[]): Person | undefined {
  return people.find((p) => sameName(p.name, name))
}

export async function addPerson(name: string, color: TileColor, now: Millis = Date.now()): Promise<string> {
  return write((w) => w.create(PERSON, { name: name.trim(), colorKey: color }), now)
}

export async function updatePerson(uid: string, name: string, color: TileColor, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(uid, { name: name.trim(), colorKey: color }), now)
}

/** Removes them for everyone. Their tasks become everyone's; their history stays. */
export async function removePerson(uid: string, myPersonUid: string, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.delete(uid), now)
  if (uid === myPersonUid) await setMeta('myPersonUid', '')
}

export async function setChoreDays(uid: string, days: string, now: Millis = Date.now()): Promise<void> {
  await write((w) => w.update(uid, { choreDays: days }), now)
}

/** Overlays reminder settings, keeping any a newer build added. */
export async function updateReminders(uid: string, patch: Partial<Reminders>, now: Millis = Date.now()): Promise<void> {
  const encoded: JsonObject = {}
  for (const [key, value] of Object.entries(patch)) {
    encoded[key] = key === 'silencedUntil' ? (value === null ? null : encodeDate(value as Millis)) : (value as JsonValue)
  }
  await write(
    (w) =>
      w.update(uid, (data) => {
        const current = data.reminders && typeof data.reminders === 'object' && !Array.isArray(data.reminders) ? data.reminders : {}
        return { ...data, reminders: { ...current, ...encoded } }
      }),
    now,
  )
}

/** Silences all of this person's reminders, on every device, for a few days. */
export async function silence(uid: string, days: number, now: Millis = Date.now()): Promise<void> {
  await updateReminders(uid, { silencedUntil: addDays(now, days) }, now)
}

export async function unsilence(uid: string, now: Millis = Date.now()): Promise<void> {
  await updateReminders(uid, { silencedUntil: null }, now)
}
