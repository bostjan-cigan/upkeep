// IndexedDB replica: one generic `records` table for every kind, tombstones, and per-device meta.
import Dexie, { type Table } from 'dexie'
import { nextStamp } from './clock'
import { encodeDate, type Millis } from './dates'
import { merge, summarize, type MergeSummary, type RecordSet } from './merge'
import { cascadeUids, withDefaults } from './registry'
import { sameData, stampMillis, type JsonObject, type SyncRecord, type Tombstone } from './snapshot'

export interface MetaRow {
  key: string
  value: unknown
}

/** Per-device values, never synced. */
export interface Meta {
  deviceId: string
  deviceName: string
  myPersonUid: string
  pairToken: string
  /** Greatest stamp merged or written (ms). */
  maxSeen: number
  lastLanSync: number
  lastImport: number
  lastExport: number
  /** Oldest local change not yet synced or exported (ms), 0 if none. */
  firstUnsyncedChange: number
  /** First-run flow finished or skipped. */
  onboarded: boolean
  /** Web Push subscription registered with the Mac. */
  pushEnabled: boolean
  /** Name of the Mac this device last synced with over the LAN. */
  macName: string
  /** This device is showing the sample household, not a real one. */
  demoMode: boolean
  /** The household this copy belongs to, learnt from the Mac on each sync. */
  householdId: string
}

export class UpkeepDB extends Dexie {
  records!: Table<SyncRecord, string>
  tombstones!: Table<Tombstone, string>
  meta!: Table<MetaRow, string>

  constructor(name = 'upkeep') {
    super(name)
    this.version(1).stores({
      records: 'uid, kind',
      tombstones: 'uid, kind',
      meta: 'key',
    })
  }
}

export const db = new UpkeepDB()

// MARK: Meta

export async function getMeta<K extends keyof Meta>(key: K): Promise<Meta[K] | undefined> {
  return (await db.meta.get(key))?.value as Meta[K] | undefined
}

export async function setMeta<K extends keyof Meta>(key: K, value: Meta[K]): Promise<void> {
  await db.meta.put({ key, value })
}

export async function allMeta(): Promise<Partial<Meta>> {
  const rows = await db.meta.toArray()
  return Object.fromEntries(rows.map((r) => [r.key, r.value])) as Partial<Meta>
}

export function newUid(): string {
  const c = globalThis.crypto
  if (c && typeof c.randomUUID === 'function') return c.randomUUID().toUpperCase()
  const bytes = new Uint8Array(16)
  if (c && typeof c.getRandomValues === 'function') c.getRandomValues(bytes)
  else for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256)
  bytes[6] = (bytes[6]! & 0x0f) | 0x40
  bytes[8] = (bytes[8]! & 0x3f) | 0x80
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`.toUpperCase()
}

/** This device's stable id, created on first use. */
export async function deviceId(): Promise<string> {
  return db.transaction('rw', db.meta, async () => {
    const existing = await getMeta('deviceId')
    if (existing) return existing
    const id = newUid()
    await setMeta('deviceId', id)
    return id
  })
}

// MARK: Local changes

type Listener = () => void
const changeListeners = new Set<Listener>()

/** Called after every local change that stamped something (not after merges). */
export function onLocalChange(listener: Listener): () => void {
  changeListeners.add(listener)
  return () => changeListeners.delete(listener)
}

let localChangeCounter = 0
/** Increments with every local change; lets sync tell whether edits happened meanwhile. */
export function localChangeCount(): number {
  return localChangeCounter
}

/** Stamps and writes within one transaction. */
export class Writer {
  changed = false
  constructor(private readonly device: string, private maxSeen: Millis, private readonly now: Millis) {}

  private stamp(): string {
    const t = nextStamp(this.now, this.maxSeen)
    this.maxSeen = t
    this.changed = true
    return encodeDate(t)
  }

  get latest(): Millis {
    return this.maxSeen
  }

  /** Inserts a new record with every default key filled in. */
  async create(kind: string, data: JsonObject, uid: string = newUid()): Promise<string> {
    const record: SyncRecord = {
      kind,
      uid,
      modifiedAt: this.stamp(),
      modifiedBy: this.device,
      data: withDefaults(kind, data),
    }
    await db.records.put(record)
    return uid
  }

  /**
   * Overlays `patch` on the stored data (unknown keys survive) and stamps only if the canonical
   * data changed. Returns whether anything changed.
   */
  async update(uid: string, patch: JsonObject | ((data: JsonObject) => JsonObject)): Promise<boolean> {
    const existing = await db.records.get(uid)
    if (!existing) return false
    const next = typeof patch === 'function' ? patch(existing.data) : { ...existing.data, ...patch }
    if (sameData(existing.data, next)) return false
    await db.records.put({ ...existing, data: next, modifiedAt: this.stamp(), modifiedBy: this.device })
    return true
  }

  /** Deletes the record and everything that depends on it, writing a tombstone for each. */
  async delete(uid: string): Promise<number> {
    const root = await db.records.get(uid)
    if (!root) return 0
    const all = await db.records.toArray()
    const doomed = [root, ...cascadeUids(root, all)]
    for (const r of doomed) {
      await db.tombstones.put({ kind: r.kind, uid: r.uid, deletedAt: this.stamp(), deletedBy: this.device })
      await db.records.delete(r.uid)
    }
    return doomed.length
  }

  get(uid: string): Promise<SyncRecord | undefined> {
    return db.records.get(uid)
  }
}

/** Runs local mutations in one transaction, persisting the clock and flagging unsynced changes. */
export async function write<T>(fn: (w: Writer) => Promise<T>, now: Millis = Date.now()): Promise<T> {
  const device = await deviceId()
  let writer: Writer | undefined
  const result = await db.transaction('rw', db.records, db.tombstones, db.meta, async () => {
    const maxSeen = (await getMeta('maxSeen')) ?? 0
    writer = new Writer(device, maxSeen, now)
    const value = await fn(writer)
    if (writer.changed) {
      await setMeta('maxSeen', writer.latest)
      if (!(await getMeta('firstUnsyncedChange'))) await setMeta('firstUnsyncedChange', now)
    }
    return value
  })
  if (writer?.changed) {
    localChangeCounter += 1
    for (const l of changeListeners) l()
  }
  return result
}

// MARK: Merge into the replica

export async function localSet(): Promise<RecordSet> {
  const [records, tombstones] = await Promise.all([db.records.toArray(), db.tombstones.toArray()])
  return { records, tombstones }
}

/** Merges incoming snapshots into the replica without re-stamping anything. */
export async function applyMerge(incoming: RecordSet[]): Promise<MergeSummary> {
  return db.transaction('rw', db.records, db.tombstones, db.meta, async () => {
    const local = await localSet()
    const result = merge([local, ...incoming])
    const summary = summarize(local.records, result.records)

    const keep = new Set(result.records.map((r) => r.uid))
    const gone = local.records.filter((r) => !keep.has(r.uid)).map((r) => r.uid)
    const localByUid = new Map(local.records.map((r) => [r.uid, r]))
    const changed = result.records.filter((r) => {
      const old = localByUid.get(r.uid)
      return !old || old.modifiedAt !== r.modifiedAt || old.modifiedBy !== r.modifiedBy || !sameData(old.data, r.data)
    })
    const localTombs = new Map(local.tombstones.map((t) => [t.uid, t]))
    const newTombs = result.tombstones.filter((t) => {
      const old = localTombs.get(t.uid)
      return !old || old.deletedAt !== t.deletedAt || old.deletedBy !== t.deletedBy
    })

    if (gone.length) await db.records.bulkDelete(gone)
    if (changed.length) await db.records.bulkPut(changed)
    if (newTombs.length) await db.tombstones.bulkPut(newTombs)

    const maxSeen = (await getMeta('maxSeen')) ?? 0
    if (Number.isFinite(result.maxStamp) && result.maxStamp > maxSeen) await setMeta('maxSeen', result.maxStamp)
    return summary
  })
}

/** Greatest stamp in a record set (ms). */
export function maxStampOf(set: RecordSet): number {
  let max = Number.NEGATIVE_INFINITY
  for (const r of set.records) max = Math.max(max, stampMillis(r.modifiedAt))
  for (const t of set.tombstones) max = Math.max(max, stampMillis(t.deletedAt))
  return max
}

/** Wipes the replica and meta (dev tools and tests). */
/**
 * Empties this device's copy of the household for another one (its Mac was reset or replaced):
 * records, tombstones, who's using it and its reminders go; its device id, name and pairing stay,
 * so it syncs the new household straight away. Nothing is deleted anywhere else.
 */
export async function resetReplica(): Promise<void> {
  await db.transaction('rw', db.records, db.tombstones, db.meta, async () => {
    await Promise.all([db.records.clear(), db.tombstones.clear()])
    await db.meta.bulkDelete(['myPersonUid', 'householdId', 'pushEnabled', 'firstUnsyncedChange', 'lastLanSync', 'lastImport', 'lastExport'])
  })
}

export async function resetDatabase(): Promise<void> {
  await db.transaction('rw', db.records, db.tombstones, db.meta, async () => {
    await Promise.all([db.records.clear(), db.tombstones.clear(), db.meta.clear()])
  })
}
