// Kinds a module knows about. The core never needs to know them: merge and storage are generic,
// and unknown kinds pass through untouched. Modules (maintenance today; shopping lists or pantry
// later) register their kinds here to get defaults, cascading deletes and derived state.
import type { JsonObject, SyncRecord } from './snapshot'

export interface ChildRelation {
  /** Kind of the dependent records, e.g. `task` for a `homeItem`. */
  kind: string
  /** Field in the child's `data` that holds the parent uid. */
  foreignKey: string
}

export interface CollectionDef {
  kind: string
  /** Every key of the kind with its default value. Writers always emit all of them. */
  defaults: () => JsonObject
  /** Records deleted (and tombstoned) together with this one. */
  children?: ChildRelation[]
}

/** Recomputes a module's derived state from the full record set. */
export type DerivedHook<T = unknown> = (records: readonly SyncRecord[], now: number) => T

const collections = new Map<string, CollectionDef>()
const derivedHooks = new Map<string, DerivedHook>()

export function registerCollection(def: CollectionDef): void {
  collections.set(def.kind, def)
}

export function collection(kind: string): CollectionDef | undefined {
  return collections.get(kind)
}

export function registeredKinds(): string[] {
  return [...collections.keys()]
}

export function registerDerived<T>(name: string, hook: DerivedHook<T>): void {
  derivedHooks.set(name, hook as DerivedHook)
}

export function derived<T>(name: string, records: readonly SyncRecord[], now: number): T {
  const hook = derivedHooks.get(name)
  if (!hook) throw new Error(`No derived hook named ${name}`)
  return hook(records, now) as T
}

/** Full data for a new record: defaults for every key, then the given values. */
export function withDefaults(kind: string, data: JsonObject): JsonObject {
  const def = collections.get(kind)
  return { ...(def ? def.defaults() : {}), ...data }
}

/** Uids of everything that goes when `root` is deleted (not including `root`). */
export function cascadeUids(root: { kind: string; uid: string }, all: readonly SyncRecord[]): SyncRecord[] {
  const out: SyncRecord[] = []
  const queue = [root]
  const seen = new Set([root.uid])
  while (queue.length) {
    const parent = queue.shift()!
    for (const rel of collections.get(parent.kind)?.children ?? []) {
      for (const r of all) {
        if (r.kind === rel.kind && r.data[rel.foreignKey] === parent.uid && !seen.has(r.uid)) {
          seen.add(r.uid)
          out.push(r)
          queue.push(r)
        }
      }
    }
  }
  return out
}
