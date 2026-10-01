// The sync round the app and the service worker share (src/core/lanSync.ts), against a
// stubbed Mac. Also pins the contract for the file a phone exports into the shared folder.
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { db, getMeta, resetDatabase, setMeta, write } from '../src/core/db'
import { lanSyncOnce, ownSnapshot } from '../src/core/lanSync'
import { encodeSnapshot } from '../src/core/snapshot'
import { TASK } from '../src/modules/maintenance/schedule'

const NOW = Date.UTC(2026, 8, 22, 12)
const macSnapshot = readFileSync(join(__dirname, 'fixtures', 'deviceB.json'), 'utf8')

beforeEach(async () => {
  await resetDatabase()
  await setMeta('deviceId', 'D-TEST')
  await setMeta('deviceName', 'Ana’s iPhone')
  await setMeta('myPersonUid', 'person-ana')
  await setMeta('pairToken', 'T')
})

afterEach(() => {
  vi.unstubAllGlobals()
})

/** A Mac that answers with `status`, optionally running `onRequest` first. */
function stubMac(status: number, body = macSnapshot, onRequest?: () => Promise<void>) {
  const fetchMock = vi.fn(async () => {
    await onRequest?.()
    return new Response(body, { status })
  })
  vi.stubGlobal('fetch', fetchMock)
  return fetchMock
}

describe('ownSnapshot', () => {
  it('is this phone’s file for the household', async () => {
    const snapshot = await ownSnapshot(NOW)
    expect(snapshot.device.platform).toBe('web')
    expect(snapshot.device.id).toBe('D-TEST')
    expect(snapshot.device.name).toBe('Ana’s iPhone')
    expect(snapshot.device.personUid).toBe('person-ana')
    // Saved under this name, so it replaces the phone's previous file in devices/.
    expect(`${snapshot.device.id}.json`).toBe('D-TEST.json')
  })
})

describe('lanSyncOnce', () => {
  it('merges the Mac’s reply and clears the unsynced flag', async () => {
    await write((w) => w.create(TASK, { title: 'Descale' }), NOW)
    expect(await getMeta('firstUnsyncedChange')).toBeTruthy()

    stubMac(200)
    const outcome = await lanSyncOnce()

    expect(outcome.kind).toBe('ok')
    expect(await db.records.get('task-filter')).toBeTruthy()
    expect(await getMeta('firstUnsyncedChange')).toBe(0)
    expect(await getMeta('lastLanSync')).toBeTruthy()
  })

  it('keeps the unsynced flag when an edit lands mid-flight', async () => {
    stubMac(200, macSnapshot, async () => {
      // The user ticks something off while the request is in the air.
      await write((w) => w.create(TASK, { title: 'Mid-flight' }), NOW)
    })

    const outcome = await lanSyncOnce()

    expect(outcome.kind).toBe('ok')
    expect(await getMeta('firstUnsyncedChange')).toBeTruthy()
  })

  it('says so without a pairing, and never asks the Mac', async () => {
    await setMeta('pairToken', '')
    const fetchMock = stubMac(200)
    expect((await lanSyncOnce()).kind).toBe('notPaired')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  for (const [status, kind] of [
    [401, 'unauthorized'],
    [409, 'updateRequired'],
    [422, 'macNeedsUpdate'],
    [500, 'error'],
  ] as const) {
    it(`leaves the replica alone on ${status}`, async () => {
      await write((w) => w.create(TASK, { title: 'Descale' }), NOW)
      const before = await db.records.toArray()

      stubMac(status, '')
      expect((await lanSyncOnce()).kind).toBe(kind)

      expect(await db.records.toArray()).toEqual(before)
      expect(await getMeta('firstUnsyncedChange')).toBeTruthy()
      expect(await getMeta('lastLanSync')).toBeFalsy()
    })
  }

  it('is unreachable away from home', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => {
        throw new TypeError('Load failed')
      }),
    )
    await write((w) => w.create(TASK, { title: 'Descale' }), NOW)

    expect((await lanSyncOnce()).kind).toBe('unreachable')
    expect(await getMeta('firstUnsyncedChange')).toBeTruthy()
  })

  it('reports a damaged reply instead of throwing', async () => {
    stubMac(200, encodeSnapshot({ ...JSON.parse(macSnapshot), format: 'something.else' }, false))
    expect((await lanSyncOnce()).kind).toBe('error')
  })
})

describe('another household', () => {
  it('tells the phone it holds another household’s copy, and merges nothing', async () => {
    await write((w) => w.create(TASK, { title: 'Old task' }), NOW)
    const before = await db.records.count()
    stubMac(409, JSON.stringify({ error: 'otherHousehold', household: 'Bostjan’s MacBook Air' }))
    const outcome = await lanSyncOnce()
    expect(outcome).toEqual({ kind: 'otherHousehold', macName: 'Bostjan’s MacBook Air' })
    expect(await db.records.count()).toBe(before)
  })

  it('still reads a plain 409 as “update the phone app”', async () => {
    stubMac(409, JSON.stringify({ error: 'updateRequired', schemaVersion: 2 }))
    expect((await lanSyncOnce()).kind).toBe('updateRequired')
  })

  it('learns its household from the Mac, and says it from then on', async () => {
    const reply = JSON.parse(macSnapshot)
    reply.device.householdId = 'H-NEW'
    stubMac(200, JSON.stringify(reply))
    expect((await lanSyncOnce()).kind).toBe('ok')
    expect(await getMeta('householdId')).toBe('H-NEW')
    expect((await ownSnapshot(NOW)).device.householdId).toBe('H-NEW')
  })

  it('replacing the copy keeps the pairing and forgets the rest', async () => {
    await write((w) => w.create(TASK, { title: 'Old task' }), NOW)
    await setMeta('householdId', 'H-OLD')
    await setMeta('pushEnabled', true)
    const { resetReplica } = await import('../src/core/db')
    await resetReplica()
    expect(await db.records.count()).toBe(0)
    expect(await db.tombstones.count()).toBe(0)
    expect(await getMeta('myPersonUid')).toBeUndefined()
    expect(await getMeta('householdId')).toBeUndefined()
    expect(await getMeta('pushEnabled')).toBeUndefined()
    expect(await getMeta('pairToken')).toBe('T')
    expect(await getMeta('deviceId')).toBe('D-TEST')
    expect(await getMeta('deviceName')).toBe('Ana’s iPhone')
  })
})

describe('importing files', () => {
  it('skips a file from another household', async () => {
    const { FilesTransport } = await import('../src/core/sync')
    await setMeta('householdId', 'H-MINE')
    const other = JSON.parse(macSnapshot)
    other.device.householdId = 'H-OTHER'
    const result = await FilesTransport.importFiles([new File([JSON.stringify(other)], 'other.json')])
    expect(result.files).toEqual([{ name: 'other.json', ok: false, error: 'From another household — skipped' }])
    expect(await db.records.count()).toBe(0)
  })
})
