import { decodeDate, encodeDate, type Millis } from './dates'

export const SNAPSHOT_FORMAT = 'com.bostjancigan.upkeep.household'
export const SCHEMA_VERSION = 1

export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue }
export type JsonObject = { [key: string]: JsonValue }

export interface SyncRecord {
  kind: string
  uid: string
  /** Canonical ISO ms date. */
  modifiedAt: string
  /** Device id of the writer. */
  modifiedBy: string
  data: JsonObject
}

export interface Tombstone {
  kind: string
  uid: string
  deletedAt: string
  deletedBy: string
}

export interface DeviceInfo {
  id: string
  name: string
  platform: string
  personUid: string
  build: string
  /** The household this copy belongs to (the id in its folder's household.json); older files lack it. */
  householdId?: string
}

export interface Snapshot {
  format: string
  schemaVersion: number
  exportedAt: string
  device: DeviceInfo
  records: SyncRecord[]
  tombstones: Tombstone[]
}

export type SnapshotErrorCode = 'notASnapshot' | 'newerVersion' | 'damaged'

export class SnapshotError extends Error {
  constructor(public readonly code: SnapshotErrorCode, detail?: string) {
    super(detail ? `${messageFor(code)} (${detail})` : messageFor(code))
    this.name = 'SnapshotError'
  }
}

function messageFor(code: SnapshotErrorCode): string {
  switch (code) {
    case 'notASnapshot': return 'This isn’t an Upkeep household file.'
    case 'newerVersion': return 'This file is from a newer version of Upkeep. Update the app to read it.'
    case 'damaged': return 'This household file is damaged and can’t be read.'
  }
}

// MARK: Canonical JSON

/** Plain string ordering by UTF-16 code units (not locale-aware), used for all sorting in the spec. */
export function compareStrings(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0
}

/** Deep copy with object keys sorted recursively. */
export function sortKeysDeep<T>(value: T): T {
  if (Array.isArray(value)) return value.map(sortKeysDeep) as T
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const key of Object.keys(value as object).sort(compareStrings)) {
      const v = (value as Record<string, unknown>)[key]
      if (v !== undefined) out[key] = sortKeysDeep(v)
    }
    return out as T
  }
  return value
}

/** Keys sorted recursively, no whitespace; whole numbers print without a fraction (JSON default). */
export function canonicalJSON(value: unknown): string {
  return JSON.stringify(sortKeysDeep(value))
}

export function sameData(a: JsonObject, b: JsonObject): boolean {
  return canonicalJSON(a) === canonicalJSON(b)
}

// MARK: Ordering

export function compareByKindUid(a: { kind: string; uid: string }, b: { kind: string; uid: string }): number {
  return compareStrings(a.kind, b.kind) || compareStrings(a.uid, b.uid)
}

export function stampMillis(value: string): Millis {
  return decodeDate(value) ?? Number.NEGATIVE_INFINITY
}

// MARK: Decode / validate

function isObject(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === 'object' && !Array.isArray(v)
}

function requireString(v: unknown, what: string): string {
  if (typeof v !== 'string') throw new SnapshotError('damaged', `${what} is not a string`)
  return v
}

function requireDate(v: unknown, what: string): string {
  const ms = decodeDate(v)
  if (ms === null) throw new SnapshotError('damaged', `${what} is not a date`)
  return encodeDate(ms)
}

/**
 * Validates a parsed snapshot. Envelope stamps (`modifiedAt`, `deletedAt`, `exportedAt`) are
 * normalised to the canonical ISO form; record `data` is kept exactly as it came in.
 */
export function validateSnapshot(json: unknown): Snapshot {
  if (!isObject(json) || json.format !== SNAPSHOT_FORMAT) throw new SnapshotError('notASnapshot')
  const version = json.schemaVersion
  // Like the Mac: a file without a readable header isn't ours.
  if (typeof version !== 'number' || !Number.isInteger(version)) throw new SnapshotError('notASnapshot', 'schemaVersion')
  if (version > SCHEMA_VERSION) throw new SnapshotError('newerVersion')

  const device = isObject(json.device) ? json.device : {}
  const info: DeviceInfo = {
    id: typeof device.id === 'string' ? device.id : '',
    name: typeof device.name === 'string' ? device.name : '',
    platform: typeof device.platform === 'string' ? device.platform : '',
    personUid: typeof device.personUid === 'string' ? device.personUid : '',
    build: typeof device.build === 'string' ? device.build : '',
    ...(typeof device.householdId === 'string' && device.householdId ? { householdId: device.householdId } : {}),
  }
  if (!Array.isArray(json.records)) throw new SnapshotError('damaged', 'records')
  const tombstonesIn = json.tombstones
  if (!Array.isArray(tombstonesIn)) throw new SnapshotError('damaged', 'tombstones')

  const records: SyncRecord[] = json.records.map((r, i) => {
    if (!isObject(r)) throw new SnapshotError('damaged', `record ${i}`)
    if (!isObject(r.data)) throw new SnapshotError('damaged', `record ${i} data`)
    return {
      kind: requireString(r.kind, `record ${i} kind`),
      uid: requireString(r.uid, `record ${i} uid`),
      modifiedAt: requireDate(r.modifiedAt, `record ${i} modifiedAt`),
      modifiedBy: requireString(r.modifiedBy, `record ${i} modifiedBy`),
      data: r.data as JsonObject,
    }
  })
  const tombstones: Tombstone[] = tombstonesIn.map((t, i) => {
    if (!isObject(t)) throw new SnapshotError('damaged', `tombstone ${i}`)
    return {
      kind: requireString(t.kind, `tombstone ${i} kind`),
      uid: requireString(t.uid, `tombstone ${i} uid`),
      deletedAt: requireDate(t.deletedAt, `tombstone ${i} deletedAt`),
      deletedBy: requireString(t.deletedBy, `tombstone ${i} deletedBy`),
    }
  })
  const exportedAt = decodeDate(json.exportedAt)
  return {
    format: SNAPSHOT_FORMAT,
    schemaVersion: version,
    exportedAt: exportedAt === null ? '' : encodeDate(exportedAt),
    device: info,
    records,
    tombstones,
  }
}

export function decodeSnapshot(text: string): Snapshot {
  let json: unknown
  try {
    json = JSON.parse(text)
  } catch {
    throw new SnapshotError('notASnapshot', 'not JSON')
  }
  return validateSnapshot(json)
}

// MARK: Encode

export const TOMBSTONE_RETENTION_MS = 365 * 86_400_000

export interface EncodeOptions {
  now?: Millis
  /** Drop tombstones older than 365 days (allowed on export). Default true. */
  pruneTombstones?: boolean
}

export function buildSnapshot(
  device: DeviceInfo,
  records: readonly SyncRecord[],
  tombstones: readonly Tombstone[],
  options: EncodeOptions = {},
): Snapshot {
  const now = options.now ?? Date.now()
  const prune = options.pruneTombstones ?? true
  const kept = prune ? tombstones.filter((t) => now - stampMillis(t.deletedAt) <= TOMBSTONE_RETENTION_MS) : tombstones
  return {
    format: SNAPSHOT_FORMAT,
    schemaVersion: SCHEMA_VERSION,
    exportedAt: encodeDate(now),
    device,
    records: [...records].sort(compareByKindUid),
    tombstones: [...kept].sort(compareByKindUid),
  }
}

/** Pretty-printed with sorted keys, so files are readable and diff cleanly. */
export function encodeSnapshot(snapshot: Snapshot, pretty = true): string {
  return JSON.stringify(sortKeysDeep(snapshot), null, pretty ? 2 : undefined) + (pretty ? '\n' : '')
}
