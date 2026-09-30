import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { HybridClock, nextStamp } from '../src/core/clock'
import { encodeDate } from '../src/core/dates'
import { merge, type RecordSet } from '../src/core/merge'
import {
  buildSnapshot,
  decodeSnapshot,
  encodeSnapshot,
  SnapshotError,
  sortKeysDeep,
  type Snapshot,
  type SyncRecord,
  type Tombstone,
} from '../src/core/snapshot'

const fixture = (name: string) => readFileSync(join(__dirname, 'fixtures', name), 'utf8')
const A = decodeSnapshot(fixture('deviceA.json'))
const B = decodeSnapshot(fixture('deviceB.json'))
const expected = JSON.parse(fixture('merged.expected.json')) as { records: SyncRecord[]; tombstones: Tombstone[] }

const plain = (set: RecordSet) => sortKeysDeep({ records: set.records, tombstones: set.tombstones })
const merged = (...sets: RecordSet[]) => plain(merge(sets))

const rec = (uid: string, modifiedAt: string, modifiedBy: string, data: SyncRecord['data'] = {}, kind = 'task'): SyncRecord => ({
  kind,
  uid,
  modifiedAt,
  modifiedBy,
  data,
})

// A third device for associativity: edits a task both others have, deletes a log, adds one of its own.
const C: RecordSet = {
  records: [
    rec('task-salt', '2026-09-22T12:10:00.000Z', 'C3333333-3333-4333-8333-333333333333', { title: 'Refill salt', intervalValue: 1 }),
    rec('log-c1', '2026-09-22T12:11:00.000Z', 'C3333333-3333-4333-8333-333333333333', { taskUid: 'task-salt' }, 'taskLog'),
  ],
  tombstones: [{ kind: 'taskLog', uid: 'log-b1', deletedAt: '2026-09-22T12:12:00.000Z', deletedBy: 'C3333333-3333-4333-8333-333333333333' }],
}

describe('fixtures', () => {
  it('are valid v1 snapshots', () => {
    expect(A.device.platform).toBe('web')
    expect(B.records.filter((r) => r.kind === 'person')).toHaveLength(2)
  })

  it('merge to merged.expected.json', () => {
    expect(merged(A, B)).toEqual(sortKeysDeep(expected))
  })
})

describe('merge', () => {
  it('is commutative', () => {
    expect(merged(A, B)).toEqual(merged(B, A))
    expect(merged(A, B, C)).toEqual(merged(C, B, A))
    expect(merged(A, C)).toEqual(merged(C, A))
  })

  it('is idempotent', () => {
    expect(merged(A, A)).toEqual(merged(A))
    const ab = merge([A, B])
    expect(merged(ab, ab)).toEqual(plain(ab))
    expect(merged(ab, A, B)).toEqual(plain(ab))
  })

  it('is associative', () => {
    const left = merge([merge([A, B]), C])
    const right = merge([A, merge([B, C])])
    expect(plain(left)).toEqual(plain(right))
    expect(plain(left)).toEqual(merged(A, B, C))
  })

  it('keeps the newer edit and breaks ties by modifiedBy', () => {
    const out = merge([A, B]).records
    expect(out.find((r) => r.uid === 'task-filter')?.data.title).toBe('Clean the filter & sump')
    expect(out.find((r) => r.uid === 'task-salt')?.modifiedBy).toBe(B.device.id)
    const x = rec('x', '2026-01-01T00:00:00.000Z', 'aaa', { v: 1 })
    const y = rec('x', '2026-01-01T00:00:00.000Z', 'aab', { v: 2 })
    expect(merge([{ records: [x], tombstones: [] }, { records: [y], tombstones: [] }]).records).toEqual([y])
    expect(merge([{ records: [y], tombstones: [] }, { records: [x], tombstones: [] }]).records).toEqual([y])
  })

  it('lets a tombstone delete older edits but not a later re-creation', () => {
    const old = rec('t', '2026-01-01T00:00:00.000Z', 'a')
    const same = rec('t', '2026-01-02T00:00:00.000Z', 'a')
    const newer = rec('t', '2026-01-03T00:00:00.000Z', 'a')
    const tomb: Tombstone = { kind: 'task', uid: 't', deletedAt: '2026-01-02T00:00:00.000Z', deletedBy: 'b' }
    expect(merge([{ records: [old], tombstones: [tomb] }]).records).toEqual([])
    expect(merge([{ records: [same], tombstones: [] }, { records: [], tombstones: [tomb] }]).records).toEqual([])
    const revived = merge([{ records: [newer], tombstones: [] }, { records: [old], tombstones: [tomb] }])
    expect(revived.records).toEqual([newer])
    expect(revived.tombstones).toEqual([tomb])
    // The fixture: B deleted the windows, A renamed them afterwards.
    const ab = merge([A, B])
    expect(ab.records.find((r) => r.uid === 'item-windows')?.data.name).toBe('Windows (upstairs)')
    expect(ab.tombstones.find((t) => t.uid === 'item-windows')).toBeDefined()
    expect(ab.records.find((r) => r.uid === 'task-rinse')).toBeUndefined()
    expect(ab.records.find((r) => r.uid === 'log-rinse')).toBeUndefined()
  })

  it('keeps the later of duplicate tombstones', () => {
    expect(merge([A, B]).tombstones.find((t) => t.uid === 'task-retired')?.deletedBy).toBe(B.device.id)
  })

  it('treats missing as not deleted', () => {
    const ab = merge([A, B])
    expect(ab.records.find((r) => r.uid === 'person-bostjan')).toBeDefined()
    expect(ab.records.find((r) => r.uid === 'shop-salt')).toBeDefined()
  })

  it('keeps unknown kinds and unknown fields verbatim through merge and re-export', () => {
    const original = A.records.find((r) => r.kind === 'shoppingEntry')!
    const ab = merge([A, B])
    const snapshot = buildSnapshot({ id: 'me', name: 'Me', platform: 'web', personUid: '', build: 'test' }, ab.records, ab.tombstones)
    const reread = decodeSnapshot(encodeSnapshot(snapshot))
    expect(reread.records.find((r) => r.uid === 'shop-salt')).toEqual(original)
    const raw = JSON.parse(fixture('deviceA.json')) as Snapshot
    expect(reread.records.find((r) => r.uid === 'shop-salt')).toEqual(raw.records.find((r) => r.uid === 'shop-salt'))
    expect(reread.records.find((r) => r.uid === 'task-filter')?.data.priority).toBe('high')
  })

  it('reports the greatest stamp seen', () => {
    expect(encodeDate(merge([A, B]).maxStamp)).toBe('2026-09-22T11:00:00.001Z')
  })
})

describe('snapshot envelope', () => {
  it('rejects foreign, newer and damaged files', () => {
    const base = JSON.parse(fixture('deviceA.json')) as Record<string, unknown>
    const code = (value: unknown) => {
      try {
        decodeSnapshot(typeof value === 'string' ? value : JSON.stringify(value))
        return 'ok'
      } catch (e) {
        return (e as SnapshotError).code
      }
    }
    expect(code('not json')).toBe('notASnapshot')
    expect(code({ ...base, format: 'com.example.other' })).toBe('notASnapshot')
    expect(code({ ...base, schemaVersion: 2 })).toBe('newerVersion')
    expect(code({ ...base, records: 'nope' })).toBe('damaged')
    expect(code({ ...base, records: [{ kind: 'task', uid: 'x', modifiedAt: 'yesterday', modifiedBy: 'a', data: {} }] })).toBe('damaged')
    expect(code(base)).toBe('ok')
  })

  it('sorts by (kind, uid) and drops tombstones older than a year on export', () => {
    const now = Date.UTC(2026, 8, 22)
    const s = buildSnapshot(
      { id: 'd', name: '', platform: 'web', personUid: '', build: '' },
      [rec('b', '2026-01-01T00:00:00.000Z', 'd', {}, 'task'), rec('a', '2026-01-01T00:00:00.000Z', 'd', {}, 'task'), rec('z', '2026-01-01T00:00:00.000Z', 'd', {}, 'homeItem')],
      [
        { kind: 'task', uid: 'old', deletedAt: '2025-09-21T00:00:00.000Z', deletedBy: 'd' },
        { kind: 'task', uid: 'recent', deletedAt: '2025-09-23T00:00:00.000Z', deletedBy: 'd' },
      ],
      { now },
    )
    expect(s.records.map((r) => r.uid)).toEqual(['z', 'a', 'b'])
    expect(s.tombstones.map((t) => t.uid)).toEqual(['recent'])
  })

  it('normalises envelope stamps but never record data', () => {
    const s = decodeSnapshot(
      JSON.stringify({
        format: 'com.bostjancigan.upkeep.household',
        schemaVersion: 1,
        exportedAt: '2026-09-22T10:00:00Z',
        device: { id: 'd', name: '', platform: 'mac', personUid: '', build: '' },
        records: [rec('a', '2026-09-22T10:00:00Z', 'd', { createdAt: '2026-09-22T10:00:00Z', intervalValue: 1.5 })],
        tombstones: [],
      }),
    )
    expect(s.records[0]!.modifiedAt).toBe('2026-09-22T10:00:00.000Z')
    expect(s.records[0]!.data).toEqual({ createdAt: '2026-09-22T10:00:00Z', intervalValue: 1.5 })
  })
})

describe('hybrid clock', () => {
  it('stamps after everything seen even when the device clock is slow', () => {
    const seen = Date.UTC(2026, 8, 22, 12)
    const slowNow = Date.UTC(2026, 8, 20, 8) // two days behind
    expect(nextStamp(slowNow, seen)).toBe(seen + 1)
    const clock = new HybridClock(0, () => slowNow)
    clock.observe(merge([A, B]).maxStamp)
    const t1 = clock.stamp()
    const t2 = clock.stamp()
    expect(t1).toBeGreaterThan(merge([A, B]).maxStamp)
    expect(t2).toBe(t1 + 1)
    // A local edit stamped this way beats the data it was based on.
    const edit = rec('task-filter', encodeDate(t1), 'Z-slow-device', { title: 'Edited' })
    expect(merge([A, B, { records: [edit], tombstones: [] }]).records.find((r) => r.uid === 'task-filter')?.data.title).toBe('Edited')
  })

  it('uses the wall clock when it is ahead', () => {
    expect(nextStamp(Date.UTC(2026, 8, 22), Date.UTC(2026, 8, 1))).toBe(Date.UTC(2026, 8, 22))
  })
})
