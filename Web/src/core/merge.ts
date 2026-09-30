// Kind-agnostic merge of any number of record/tombstone sets (Docs/Sync.md › Merge).
import { canonicalJSON, compareByKindUid, compareStrings, stampMillis, type SyncRecord, type Tombstone } from './snapshot'

export interface RecordSet {
  records: readonly SyncRecord[]
  tombstones: readonly Tombstone[]
}

export interface MergeResult {
  records: SyncRecord[]
  tombstones: Tombstone[]
  /** Greatest modifiedAt/deletedAt seen in the inputs (ms), for the hybrid clock. */
  maxStamp: number
}

/** > 0 when `a` wins over `b`. */
export function compareRecords(a: SyncRecord, b: SyncRecord): number {
  return stampMillis(a.modifiedAt) - stampMillis(b.modifiedAt) || compareStrings(a.modifiedBy, b.modifiedBy)
}

export function compareTombstones(a: Tombstone, b: Tombstone): number {
  return stampMillis(a.deletedAt) - stampMillis(b.deletedAt) || compareStrings(a.deletedBy, b.deletedBy)
}

/** True when the tombstone deletes the record (`deletedAt >= modifiedAt`). */
export function tombstoneCovers(t: Tombstone, r: SyncRecord): boolean {
  return stampMillis(t.deletedAt) >= stampMillis(r.modifiedAt)
}

export function merge(sets: readonly RecordSet[]): MergeResult {
  const tombstones = new Map<string, Tombstone>()
  const records = new Map<string, SyncRecord>()
  let maxStamp = Number.NEGATIVE_INFINITY

  for (const set of sets) {
    for (const t of set.tombstones) {
      maxStamp = Math.max(maxStamp, stampMillis(t.deletedAt))
      const current = tombstones.get(t.uid)
      if (!current || compareTombstones(t, current) > 0) tombstones.set(t.uid, t)
    }
    for (const r of set.records) {
      maxStamp = Math.max(maxStamp, stampMillis(r.modifiedAt))
      const current = records.get(r.uid)
      if (!current) { records.set(r.uid, r); continue }
      const order = compareRecords(r, current)
      // Same modifiedAt + modifiedBy is the same edit. Should the data ever differ anyway, the greater
      // canonical data wins so the result never depends on input order.
      if (order > 0 || (order === 0 && compareStrings(canonicalJSON(r.data), canonicalJSON(current.data)) > 0)) {
        records.set(r.uid, r)
      }
    }
  }

  const survivors: SyncRecord[] = []
  for (const r of records.values()) {
    const t = tombstones.get(r.uid)
    if (!t || !tombstoneCovers(t, r)) survivors.push(r)
  }
  return {
    records: survivors.sort(compareByKindUid),
    tombstones: [...tombstones.values()].sort(compareByKindUid),
    maxStamp,
  }
}

export interface MergeSummary {
  added: number
  updated: number
  removed: number
  /** Per kind: [added, updated, removed]. */
  byKind: Record<string, [number, number, number]>
}

/** What changed between two record sets, for the import summary. */
export function summarize(before: readonly SyncRecord[], after: readonly SyncRecord[]): MergeSummary {
  const prev = new Map(before.map((r) => [r.uid, r]))
  const next = new Map(after.map((r) => [r.uid, r]))
  const summary: MergeSummary = { added: 0, updated: 0, removed: 0, byKind: {} }
  const bump = (kind: string, i: 0 | 1 | 2) => {
    const row = (summary.byKind[kind] ??= [0, 0, 0])
    row[i] += 1
  }
  for (const r of after) {
    const old = prev.get(r.uid)
    if (!old) { summary.added += 1; bump(r.kind, 0) } else if (old.modifiedAt !== r.modifiedAt || old.modifiedBy !== r.modifiedBy) { summary.updated += 1; bump(r.kind, 1) }
  }
  for (const r of before) {
    if (!next.has(r.uid)) { summary.removed += 1; bump(r.kind, 2) }
  }
  return summary
}
