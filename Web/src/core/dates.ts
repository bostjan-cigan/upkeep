// Dates are handled as epoch milliseconds in memory and as ISO strings on the wire.
// Calendar arithmetic runs in the device's local time zone and mirrors Foundation's
// `Calendar.date(byAdding:value:to:)` (see Docs/Sync.md › Calendar arithmetic).

export type Millis = number

export const DAY_MS = 86_400_000

export type CalendarUnit = 'day' | 'week' | 'month' | 'year'

const ISO_RE = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$/

/** `2026-09-22T10:15:00.000Z`: UTC, exactly three fractional digits. Milliseconds are rounded. */
export function encodeDate(ms: Millis): string {
  const rounded = Math.round(ms)
  const d = new Date(rounded)
  const pad = (n: number, w = 2) => String(n).padStart(w, '0')
  const year = d.getUTCFullYear()
  const y = year >= 0 && year <= 9999 ? pad(year, 4) : (year < 0 ? '-' : '+') + pad(Math.abs(year), 6)
  return `${y}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}.${pad(d.getUTCMilliseconds(), 3)}Z`
}

/**
 * Parses a UTC ISO 8601 date with any number of fractional digits (or none), rounding to the
 * nearest millisecond. Returns null for anything else.
 */
export function decodeDate(value: unknown): Millis | null {
  if (typeof value !== 'string') return null
  const m = ISO_RE.exec(value)
  if (!m) return null
  const [, y, mo, d, h, mi, s, frac] = m
  const month = Number(mo), day = Number(d), hour = Number(h), minute = Number(mi), second = Number(s)
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null
  const base = Date.UTC(Number(y), month - 1, day, hour, minute, second)
  // Round the fraction to whole milliseconds without floating-point surprises ("0.0005" → 1 ms).
  let fracMs = 0
  if (frac) {
    const digits = (frac + '000').slice(0, 3)
    fracMs = Number(digits)
    const rest = frac.slice(3)
    if (rest.length > 0 && Number(rest[0]) >= 5) fracMs += 1
  }
  const ms = base + fracMs
  return Number.isFinite(ms) ? ms : null
}

/** Normalises an ISO date string to the canonical 3-digit form, or returns null if it isn't one. */
export function normalizeDate(value: unknown): string | null {
  const ms = decodeDate(value)
  return ms === null ? null : encodeDate(ms)
}

function local(ms: Millis) {
  const d = new Date(ms)
  return {
    y: d.getFullYear(),
    m: d.getMonth(),
    d: d.getDate(),
    h: d.getHours(),
    mi: d.getMinutes(),
    s: d.getSeconds(),
    ms: d.getMilliseconds(),
  }
}

/** Builds a local date without the two-digit-year quirk of the Date constructor. */
function makeLocal(y: number, m: number, d: number, h = 0, mi = 0, s = 0, ms = 0): Millis {
  const date = new Date(2000, 0, 1, h, mi, s, ms)
  date.setFullYear(y, m, d)
  date.setHours(h, mi, s, ms)
  return date.getTime()
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month + 1, 0)).getUTCDate()
}

/** Midnight at the start of the local day containing `ms`. */
export function startOfDay(ms: Millis): Millis {
  const c = local(ms)
  return makeLocal(c.y, c.m, c.d)
}

/** Calendar weekday of the local day containing `ms`: 1 = Sunday … 7 = Saturday, as Foundation numbers them. */
export function weekday(ms: Millis): number {
  return new Date(startOfDay(ms)).getDay() + 1
}

/** Local calendar date at midnight. `month` is 0-based. */
export function localDay(year: number, month: number, day: number): Millis {
  return makeLocal(year, month, day)
}

/**
 * Adds `value` calendar units in the local time zone, keeping the wall-clock time.
 * Months and years clamp to the last valid day (31 Jan + 1 month = 28/29 Feb); weeks are 7 days;
 * days are calendar days, so the result stays at the same local time across DST changes.
 */
export function addCalendar(ms: Millis, unit: CalendarUnit, value: number): Millis {
  const c = local(ms)
  switch (unit) {
    case 'day':
      return makeLocal(c.y, c.m, c.d + value, c.h, c.mi, c.s, c.ms)
    case 'week':
      return makeLocal(c.y, c.m, c.d + 7 * value, c.h, c.mi, c.s, c.ms)
    case 'month':
    case 'year': {
      const total = c.m + (unit === 'year' ? 12 * value : value)
      const y = c.y + Math.floor(total / 12)
      const m = ((total % 12) + 12) % 12
      const d = Math.min(c.d, daysInMonth(y, m))
      return makeLocal(y, m, d, c.h, c.mi, c.s, c.ms)
    }
  }
}

export function addDays(ms: Millis, days: number): Millis {
  return addCalendar(ms, 'day', days)
}

/**
 * Start of the local calendar week containing `ms`. `weekStart` is a JS weekday (0 = Sunday),
 * as `firstWeekday()` reports it for the locale.
 */
export function startOfWeek(ms: Millis, weekStart: number): Millis {
  const day = startOfDay(ms)
  const offset = (((new Date(day).getDay() - weekStart) % 7) + 7) % 7
  return addDays(day, -offset)
}

/** Whole calendar days from the local day of `from` to the local day of `to` (DST-safe). */
export function calendarDaysBetween(from: Millis, to: Millis): number {
  const a = local(from), b = local(to)
  return Math.round((Date.UTC(b.y, b.m, b.d) - Date.UTC(a.y, a.m, a.d)) / DAY_MS)
}

export function isSameDay(a: Millis, b: Millis): boolean {
  return startOfDay(a) === startOfDay(b)
}

export function startOfMonth(ms: Millis): Millis {
  const c = local(ms)
  return makeLocal(c.y, c.m, 1)
}

// MARK: Formatting (en-GB style, like the Mac app: "15 Sep", "15 Sep 2026")

export const MONTHS_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
export const MONTHS_LONG = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
export const WEEKDAYS_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
export const WEEKDAYS_LONG = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']

/** "15 Sep" */
export function formatDayMonth(ms: Millis): string {
  const d = new Date(ms)
  return `${d.getDate()} ${MONTHS_SHORT[d.getMonth()]}`
}

/** "15 Sep 2026" */
export function formatDate(ms: Millis): string {
  const d = new Date(ms)
  return `${d.getDate()} ${MONTHS_SHORT[d.getMonth()]} ${d.getFullYear()}`
}

/** "15 September 2026" */
export function formatDateLong(ms: Millis): string {
  const d = new Date(ms)
  return `${d.getDate()} ${MONTHS_LONG[d.getMonth()]} ${d.getFullYear()}`
}

/** "Tuesday 15 September" */
export function formatWeekdayDayMonth(ms: Millis): string {
  const d = new Date(ms)
  return `${WEEKDAYS_LONG[d.getDay()]} ${d.getDate()} ${MONTHS_LONG[d.getMonth()]}`
}

/** "September 2026" */
export function formatMonthYear(ms: Millis): string {
  const d = new Date(ms)
  return `${MONTHS_LONG[d.getMonth()]} ${d.getFullYear()}`
}

/** "14:05" */
export function formatTime(ms: Millis): string {
  const d = new Date(ms)
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`
}

/** "15 Sep 2026, 14:05" */
export function formatDateTime(ms: Millis): string {
  return `${formatDate(ms)}, ${formatTime(ms)}`
}

/**
 * How long ago something happened, in words: "just now", "3 min ago", "today at 14:05",
 * "yesterday at 14:05", then the full date. Reads as a suffix ("Last synced just now").
 */
export function relativeTime(ms: Millis, now: Millis): string {
  // `now` is a ticking clock the screen holds, so it can lag a stamp by a few seconds: anything
  // in the future reads as "just now" rather than falling through to a date.
  const ago = Math.max(0, now - ms)
  if (ago < 60_000) return 'just now'
  if (ago < 3_600_000) return `${Math.round(ago / 60_000)} min ago`
  const days = calendarDaysBetween(ms, now)
  if (days === 0) return `today at ${formatTime(ms)}`
  if (days === 1) return `yesterday at ${formatTime(ms)}`
  return formatDateTime(ms)
}

/** "YYYY-MM-DD" in local time, for `<input type="date">`. */
export function toDateInput(ms: Millis): string {
  const d = new Date(ms)
  return `${String(d.getFullYear()).padStart(4, '0')}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`
}

/** Local midnight of a `YYYY-MM-DD` value, or null. */
export function fromDateInput(value: string): Millis | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value)
  if (!m) return null
  return localDay(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
}
