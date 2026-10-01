// Household members (`person` kind) and "who am I" on this device.
import { decodeDate, encodeDate, type Millis } from './dates'
import { registerCollection } from './registry'
import type { JsonObject, JsonValue, SyncRecord } from './snapshot'

export const PERSON = 'person'

export const TILE_COLORS = ['blue', 'teal', 'green', 'yellow', 'orange', 'red', 'pink', 'purple', 'indigo', 'brown', 'gray'] as const
export type TileColor = (typeof TILE_COLORS)[number]

/** Apple system colors. */
export const TILE_COLOR_HEX: Record<TileColor, string> = {
  blue: '#007AFF',
  teal: '#30B0C7',
  green: '#34C759',
  yellow: '#FFCC00',
  orange: '#FF9500',
  red: '#FF3B30',
  pink: '#FF2D55',
  purple: '#AF52DE',
  indigo: '#5856D6',
  brown: '#A2845E',
  gray: '#8E8E93',
}

/**
 * Colours a white mark washes out on: each of these falls below 3:1 against white, yellow
 * worst at 1.51. Kept in step with `TileColor.onBase` in the Mac app, so one person's badge
 * looks the same on both.
 */
const DARK_MARK: ReadonlySet<TileColor> = new Set<TileColor>(['teal', 'green', 'yellow', 'orange', 'gray'])

/** What to draw on top of a tile colour. White everywhere it stays legible. */
export function tileForeground(color: TileColor): string {
  return DARK_MARK.has(color) ? 'rgba(0, 0, 0, 0.8)' : '#fff'
}

export function tileColor(key: unknown): TileColor {
  return (TILE_COLORS as readonly string[]).includes(key as string) ? (key as TileColor) : 'blue'
}

export interface Reminders {
  nagHours: number
  activeStart: number
  activeEnd: number
  remindDays: string
  workEnabled: boolean
  workDays: string
  workStart: number
  workEnd: number
  silencedUntil: Millis | null
}

export const DEFAULT_REMINDERS: Reminders = {
  nagHours: 3,
  activeStart: 9,
  activeEnd: 21,
  remindDays: '1234567',
  workEnabled: false,
  workDays: '23456',
  workStart: 9,
  workEnd: 17,
  silencedUntil: null,
}

function remindersJSON(r: Reminders): JsonObject {
  return { ...r, silencedUntil: r.silencedUntil === null ? null : encodeDate(r.silencedUntil) }
}

/** Sunday and Saturday, as `Weekdays` digits. */
export const DEFAULT_CHORE_DAYS = '17'

registerCollection({
  kind: PERSON,
  defaults: () => ({ name: '', colorKey: 'blue', choreDays: DEFAULT_CHORE_DAYS, reminders: remindersJSON(DEFAULT_REMINDERS) }),
})

export interface Person {
  uid: string
  name: string
  color: TileColor
  /** The days this person usually gets chores done; new tasks start on them. */
  choreDays: string
  reminders: Reminders
}

const num = (v: JsonValue | undefined, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d)
const str = (v: JsonValue | undefined, d = '') => (typeof v === 'string' ? v : d)

export function personFrom(record: SyncRecord): Person {
  const data = record.data
  const r = (data.reminders && typeof data.reminders === 'object' && !Array.isArray(data.reminders) ? data.reminders : {}) as JsonObject
  return {
    uid: record.uid,
    name: str(data.name),
    color: tileColor(data.colorKey),
    choreDays: str(data.choreDays, DEFAULT_CHORE_DAYS),
    reminders: {
      nagHours: num(r.nagHours, DEFAULT_REMINDERS.nagHours),
      activeStart: num(r.activeStart, DEFAULT_REMINDERS.activeStart),
      activeEnd: num(r.activeEnd, DEFAULT_REMINDERS.activeEnd),
      remindDays: str(r.remindDays, DEFAULT_REMINDERS.remindDays),
      workEnabled: typeof r.workEnabled === 'boolean' ? r.workEnabled : DEFAULT_REMINDERS.workEnabled,
      workDays: str(r.workDays, DEFAULT_REMINDERS.workDays),
      workStart: num(r.workStart, DEFAULT_REMINDERS.workStart),
      workEnd: num(r.workEnd, DEFAULT_REMINDERS.workEnd),
      silencedUntil: decodeDate(r.silencedUntil),
    },
  }
}

export function peopleFrom(records: readonly SyncRecord[]): Person[] {
  return records
    .filter((r) => r.kind === PERSON)
    .map(personFrom)
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }) || (a.uid < b.uid ? -1 : 1))
}

/** An assignee that no longer exists counts as everyone (""). */
export function effectiveAssignee(assigneeUid: string, people: readonly Person[]): string {
  return assigneeUid && people.some((p) => p.uid === assigneeUid) ? assigneeUid : ''
}

/** A task is mine when it's assigned to me or to everyone. */
export function isMine(assigneeUid: string, myPersonUid: string, people: readonly Person[]): boolean {
  const who = effectiveAssignee(assigneeUid, people)
  return who === '' || who === myPersonUid
}
