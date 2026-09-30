import { describe, expect, it } from 'vitest'
import {
  addCalendar,
  calendarDaysBetween,
  decodeDate,
  encodeDate,
  formatDate,
  formatDayMonth,
  localDay,
  normalizeDate,
  startOfDay,
} from '../src/core/dates'

const local = (y: number, m: number, d: number, h = 0, mi = 0) => new Date(y, m - 1, d, h, mi).getTime()
const parts = (ms: number) => {
  const d = new Date(ms)
  return [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes()]
}

describe('ISO dates', () => {
  it('encodes UTC with exactly three fractional digits', () => {
    expect(encodeDate(Date.UTC(2026, 8, 22, 10, 15, 0, 0))).toBe('2026-09-22T10:15:00.000Z')
    expect(encodeDate(Date.UTC(2026, 0, 2, 3, 4, 5, 67))).toBe('2026-01-02T03:04:05.067Z')
  })

  it('round-trips', () => {
    for (const s of ['2026-09-22T10:15:00.000Z', '1999-12-31T23:59:59.999Z', '2026-02-28T00:00:00.001Z']) {
      expect(encodeDate(decodeDate(s)!)).toBe(s)
    }
  })

  it('accepts dates without a fractional part', () => {
    expect(decodeDate('2026-09-22T10:15:00Z')).toBe(Date.UTC(2026, 8, 22, 10, 15))
    expect(normalizeDate('2026-09-22T10:15:00Z')).toBe('2026-09-22T10:15:00.000Z')
  })

  it('rounds sub-millisecond input instead of truncating', () => {
    expect(encodeDate(decodeDate('2026-09-22T10:15:00.1234Z')!)).toBe('2026-09-22T10:15:00.123Z')
    expect(encodeDate(decodeDate('2026-09-22T10:15:00.1235Z')!)).toBe('2026-09-22T10:15:00.124Z')
    expect(encodeDate(decodeDate('2026-09-22T10:15:59.9996Z')!)).toBe('2026-09-22T10:16:00.000Z')
    expect(encodeDate(1_000.6)).toBe('1970-01-01T00:00:01.001Z')
    expect(encodeDate(1_000.4)).toBe('1970-01-01T00:00:01.000Z')
    expect(decodeDate('2026-09-22T10:15:00.5Z')).toBe(Date.UTC(2026, 8, 22, 10, 15, 0, 500))
  })

  it('rejects anything else', () => {
    expect(decodeDate('2026-09-22')).toBeNull()
    expect(decodeDate('2026-09-22T10:15:00+02:00')).toBeNull()
    expect(decodeDate(null)).toBeNull()
    expect(decodeDate(12)).toBeNull()
  })
})

describe('calendar arithmetic', () => {
  it('clamps month ends like Foundation', () => {
    expect(parts(addCalendar(local(2026, 1, 31), 'month', 1))).toEqual([2026, 2, 28, 0, 0])
    expect(parts(addCalendar(local(2028, 1, 31), 'month', 1))).toEqual([2028, 2, 29, 0, 0])
    expect(parts(addCalendar(local(2026, 1, 31), 'month', 2))).toEqual([2026, 3, 31, 0, 0])
    expect(parts(addCalendar(local(2026, 3, 31), 'month', -1))).toEqual([2026, 2, 28, 0, 0])
    expect(parts(addCalendar(local(2026, 8, 31), 'month', 1))).toEqual([2026, 9, 30, 0, 0])
    expect(parts(addCalendar(local(2026, 12, 15), 'month', 1))).toEqual([2027, 1, 15, 0, 0])
    expect(parts(addCalendar(local(2026, 1, 15), 'month', -2))).toEqual([2025, 11, 15, 0, 0])
  })

  it('clamps leap days when adding years', () => {
    expect(parts(addCalendar(local(2028, 2, 29), 'year', 1))).toEqual([2029, 2, 28, 0, 0])
    expect(parts(addCalendar(local(2028, 2, 29), 'year', 4))).toEqual([2032, 2, 29, 0, 0])
  })

  it('adds calendar days across DST changes, keeping the wall-clock time', () => {
    // Europe/Ljubljana: clocks go forward on 29 Mar 2026 and back on 25 Oct 2026.
    const beforeSpring = local(2026, 3, 28)
    expect(parts(addCalendar(beforeSpring, 'day', 1))).toEqual([2026, 3, 29, 0, 0])
    expect(parts(addCalendar(beforeSpring, 'day', 2))).toEqual([2026, 3, 30, 0, 0])
    expect(addCalendar(beforeSpring, 'day', 2) - beforeSpring).toBe(47 * 3_600_000)
    const beforeAutumn = local(2026, 10, 24, 12, 30)
    expect(parts(addCalendar(beforeAutumn, 'day', 1))).toEqual([2026, 10, 25, 12, 30])
    expect(addCalendar(beforeAutumn, 'day', 1) - beforeAutumn).toBe(25 * 3_600_000)
    expect(parts(addCalendar(local(2026, 10, 20), 'week', 1))).toEqual([2026, 10, 27, 0, 0])
  })

  it('counts calendar days, not 24-hour periods', () => {
    expect(calendarDaysBetween(local(2026, 3, 28, 23, 0), local(2026, 3, 30, 0, 30))).toBe(2)
    expect(calendarDaysBetween(local(2026, 10, 25, 0, 0), local(2026, 10, 26, 0, 0))).toBe(1)
    expect(calendarDaysBetween(local(2026, 9, 22, 18), local(2026, 9, 20, 1))).toBe(-2)
  })

  it('finds the start of the local day', () => {
    expect(startOfDay(local(2026, 9, 22, 17, 45))).toBe(local(2026, 9, 22))
    expect(startOfDay(local(2026, 3, 29, 12))).toBe(localDay(2026, 2, 29))
  })

  it('formats like the Mac', () => {
    expect(formatDayMonth(local(2026, 9, 15))).toBe('15 Sep')
    expect(formatDate(local(2026, 9, 15))).toBe('15 Sep 2026')
  })
})
