import Foundation
import SwiftData

// Bridges SwiftData models and sync records. Modules register their models in `SyncRegistry.kinds`;
// everything else (stamping, export, merging, deletion) is generic.

/// A SwiftData model that syncs as one record kind.
@MainActor
protocol SyncableModel: PersistentModel {
    static var syncKind: String { get }
    var uid: String { get set }
    var modifiedAt: Date { get set }
    var modifiedBy: String { get set }
    /// Canonical data the record was last stamped or merged with (unknown keys from newer builds included).
    var syncRaw: String { get set }
    /// The fields this build knows. Relationships appear as uids.
    var knownSyncData: [String: JSONValue] { get }
    /// Sets fields from merged data, resolving related records by uid.
    func applySyncData(_ data: JSONValue, resolver: SyncResolver)
    /// Records that go when this one is deleted, e.g. an item's tasks.
    var syncChildren: [any SyncableModel] { get }
    static func makeForSync() -> Self
}

extension SyncableModel {
    /// The data last stamped or merged, as an object.
    var rawSyncObject: [String: JSONValue] {
        guard !syncRaw.isEmpty, case .object(let raw)? = try? JSONDecoder().decode(JSONValue.self, from: Data(syncRaw.utf8))
        else { return [:] }
        return raw
    }

    /// Known fields laid over whatever the last merged data held, so keys from newer builds survive.
    var syncData: JSONValue {
        var object = rawSyncObject
        for (k, v) in knownSyncData { object[k] = v }
        return .object(object)
    }

    var syncRecord: SyncRecord {
        SyncRecord(kind: Self.syncKind, uid: uid, modifiedAt: modifiedAt, modifiedBy: modifiedBy, data: syncData)
    }
}

enum SyncRegistry {
    /// In dependency order: a record's references are applied before it.
    @MainActor static let kinds: [any SyncableModel.Type] = [Person.self, HomeItem.self, MaintenanceTask.self, MaintenanceLog.self,
                                                             MacDevice.self, PushKey.self, PushSubscriptionRecord.self, PushDelivery.self]

    @MainActor static var schema: Schema {
        Schema(kinds.map { $0 as any PersistentModel.Type } + [TombstoneEntry.self, UnknownRecord.self])
    }

    @MainActor static func type(for kind: String) -> (any SyncableModel.Type)? {
        kinds.first { $0.syncKind == kind }
    }
}

/// A deletion, kept so it reaches every device.
@Model
final class TombstoneEntry {
    var uid: String = ""
    var kind: String = ""
    var deletedAt: Date = Date()
    var deletedBy: String = ""

    init(_ t: SyncTombstone) {
        uid = t.uid
        kind = t.kind
        deletedAt = t.deletedAt
        deletedBy = t.deletedBy
    }

    var tombstone: SyncTombstone { SyncTombstone(kind: kind, uid: uid, deletedAt: deletedAt, deletedBy: deletedBy) }
}

/// A record of a kind this build doesn't know (from a newer build), kept verbatim and passed on.
@Model
final class UnknownRecord {
    var uid: String = ""
    var kind: String = ""
    var modifiedAt: Date = Date()
    var modifiedBy: String = ""
    var dataJSON: String = "{}"

    init(_ r: SyncRecord) {
        uid = r.uid
        set(r)
    }

    func set(_ r: SyncRecord) {
        kind = r.kind
        modifiedAt = r.modifiedAt
        modifiedBy = r.modifiedBy
        dataJSON = r.data.canonical
    }

    var record: SyncRecord {
        let data = (try? JSONDecoder().decode(JSONValue.self, from: Data(dataJSON.utf8))) ?? .object([:])
        return SyncRecord(kind: kind, uid: uid, modifiedAt: modifiedAt, modifiedBy: modifiedBy, data: data)
    }
}

/// Finds local models by uid while merged records are applied.
@MainActor
final class SyncResolver {
    private var models: [String: any SyncableModel] = [:]

    init(context: ModelContext) {
        for type in SyncRegistry.kinds {
            for model in SyncStore.fetchAll(type, context) { models[model.uid] = model }
        }
    }

    func model<T: SyncableModel>(_ uid: String, as type: T.Type = T.self) -> T? {
        uid.isEmpty ? nil : models[uid] as? T
    }

    func any(_ uid: String) -> (any SyncableModel)? { models[uid] }

    func register(_ model: any SyncableModel) { models[model.uid] = model }
    func forget(_ uid: String) { models[uid] = nil }
}

/// What a merge changed locally, for status lines.
struct MergeSummary: Sendable {
    var inserted = 0
    var updated = 0
    var deleted = 0
    var isEmpty: Bool { inserted + updated + deleted == 0 }

    var text: String {
        if isEmpty { return "Already up to date" }
        var parts: [String] = []
        if inserted > 0 { parts.append("\(inserted) new") }
        if updated > 0 { parts.append("\(updated) updated") }
        if deleted > 0 { parts.append("\(deleted) removed") }
        return parts.joined(separator: ", ")
    }
}

@MainActor
enum SyncStore {
    static var clock = HybridClock()
    /// Who stamps edits. Tests swap it to act as several devices.
    static var deviceOverride: (id: String, clock: HybridClock)?
    static var deviceId: String { deviceOverride?.id ?? Household.shared.deviceId }
    private static var stampClock: HybridClock { deviceOverride?.clock ?? clock }

    static func fetchAll<T: SyncableModel>(_ type: T.Type, _ context: ModelContext) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    // MARK: Stamping

    /// Stamps every record whose data changed since it was last stamped or merged.
    /// Runs before each export, so edits anywhere in the app are picked up without per-view code.
    @discardableResult
    static func stampChanges(in context: ModelContext, now: Date = Date()) -> Int {
        var count = 0
        let device = deviceId
        let clock = self.stampClock
        for type in SyncRegistry.kinds {
            for model in fetchAll(type, context) {
                let canonical = model.syncData.canonical
                guard canonical != model.syncRaw else { continue }
                model.modifiedAt = clock.now(now)
                model.modifiedBy = device
                model.syncRaw = canonical
                count += 1
            }
        }
        if count > 0 { try? context.save() }
        return count
    }

    // MARK: Snapshot

    static func snapshot(of context: ModelContext, now: Date = Date()) -> Snapshot {
        stampChanges(in: context, now: now)
        var records: [SyncRecord] = []
        for type in SyncRegistry.kinds {
            records += fetchAll(type, context).map(\.syncRecord)
        }
        records += ((try? context.fetch(FetchDescriptor<UnknownRecord>())) ?? []).map(\.record)
        let tombstones = ((try? context.fetch(FetchDescriptor<TombstoneEntry>())) ?? []).map(\.tombstone)
        var device = Household.shared.deviceInfo
        device.id = deviceId
        return Snapshot(device: device, records: records, tombstones: tombstones, at: now)
    }

    // MARK: Deleting

    /// Deletes a record and everything that belongs to it, leaving tombstones so the deletion syncs.
    static func delete(_ model: any SyncableModel, in context: ModelContext, save: Bool = true) {
        let at = stampClock.now()
        func bury(_ m: any SyncableModel) {
            for child in m.syncChildren { bury(child) }
            upsertTombstone(SyncTombstone(kind: type(of: m).syncKind, uid: m.uid, deletedAt: at, deletedBy: deviceId), in: context)
            context.delete(m)
        }
        bury(model)
        if save { try? context.save() }
    }

    private static func upsertTombstone(_ t: SyncTombstone, in context: ModelContext) {
        let uid = t.uid
        let existing = try? context.fetch(FetchDescriptor<TombstoneEntry>(predicate: #Predicate { $0.uid == uid })).first
        if let existing {
            if t.wins(over: existing.tombstone) {
                existing.deletedAt = t.deletedAt
                existing.deletedBy = t.deletedBy
                existing.kind = t.kind
            }
        } else {
            context.insert(TombstoneEntry(t))
        }
    }

    // MARK: Merging

    /// Merges other replicas into this store: local edits are stamped first, then the merged
    /// result is applied without re-stamping, and derived fields are recomputed.
    @discardableResult
    static func merge(_ others: [Snapshot], into context: ModelContext) -> MergeSummary {
        let local = snapshot(of: context)
        let result = Merge.merge([local] + others)
        let summary = apply(result, local: local, to: context)
        stampClock.observe(result.maxStamp)
        return summary
    }

    private static func apply(_ result: MergeResult, local: Snapshot, to context: ModelContext) -> MergeSummary {
        var summary = MergeSummary()
        let resolver = SyncResolver(context: context)
        let localTombstones = Dictionary(local.tombstones.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        let unknown = Dictionary(((try? context.fetch(FetchDescriptor<UnknownRecord>())) ?? []).map { ($0.uid, $0) },
                                 uniquingKeysWith: { a, _ in a })

        // Deletions first, so a re-created record isn't removed afterwards.
        var buried = Set<String>()
        for (uid, t) in result.tombstones {
            if localTombstones[uid] != t { upsertTombstone(t, in: context) }
            if result.records[uid] != nil { continue }
            if let model = resolver.any(uid) {
                // Children the deleting device didn't know about go too, with tombstones of their own.
                for child in model.syncChildren where result.tombstones[child.uid] == nil {
                    for uid in descendants(of: child) { buried.insert(uid); resolver.forget(uid) }
                    delete(child, in: context, save: false)
                }
                context.delete(model)
                resolver.forget(uid)
                summary.deleted += 1
            } else if let u = unknown[uid] {
                context.delete(u)
                summary.deleted += 1
            }
        }

        // Records in dependency order; unknown kinds go last and are kept verbatim.
        let order = Dictionary(uniqueKeysWithValues: SyncRegistry.kinds.enumerated().map { ($1.syncKind, $0) })
        let records = result.records.values.sorted {
            (order[$0.kind] ?? Int.max, $0.uid) < (order[$1.kind] ?? Int.max, $1.uid)
        }
        for r in records where !buried.contains(r.uid) {
            if let type = SyncRegistry.type(for: r.kind) {
                // A kind an older build kept verbatim is known now: it becomes a real record, once.
                if let u = unknown[r.uid] { context.delete(u) }
                applyRecord(r, type: type, resolver: resolver, context: context, summary: &summary)
            } else if let u = unknown[r.uid] {
                if u.modifiedAt != r.modifiedAt || u.modifiedBy != r.modifiedBy { u.set(r); summary.updated += 1 }
            } else {
                context.insert(UnknownRecord(r))
                summary.inserted += 1
            }
        }

        removeOrphans(in: context)
        for task in fetchAll(MaintenanceTask.self, context) { task.refreshDerived() }
        try? context.save()
        return summary
    }

    private static func descendants(of model: any SyncableModel) -> [String] {
        [model.uid] + model.syncChildren.flatMap { descendants(of: $0) }
    }

    private static func applyRecord<T: SyncableModel>(_ r: SyncRecord, type: T.Type, resolver: SyncResolver,
                                                      context: ModelContext, summary: inout MergeSummary) {
        let model: T
        if let existing = resolver.model(r.uid, as: T.self) {
            guard existing.modifiedAt != r.modifiedAt || existing.modifiedBy != r.modifiedBy else { return }
            model = existing
            summary.updated += 1
        } else {
            model = T.makeForSync()
            model.uid = r.uid
            context.insert(model)
            resolver.register(model)
            summary.inserted += 1
        }
        model.applySyncData(r.data, resolver: resolver)
        model.modifiedAt = r.modifiedAt
        model.modifiedBy = r.modifiedBy
        model.syncRaw = r.data.canonical
    }

    /// A task added to an item another device deleted meanwhile (or a log on such a task) is deleted too.
    private static func removeOrphans(in context: ModelContext) {
        for task in fetchAll(MaintenanceTask.self, context) where task.item == nil {
            delete(task, in: context, save: false)
        }
        for log in fetchAll(MaintenanceLog.self, context) where log.task == nil {
            delete(log, in: context, save: false)
        }
    }

    // MARK: Clearing

    /// Empties this replica for a fresh start elsewhere: every record, tombstone and kept unknown
    /// record goes, and no tombstones are written, so nothing is deleted anywhere else.
    static func clearLocal(in context: ModelContext) {
        for type in SyncRegistry.kinds {
            for model in fetchAll(type, context) { context.delete(model) }
        }
        for t in (try? context.fetch(FetchDescriptor<TombstoneEntry>())) ?? [] { context.delete(t) }
        for u in (try? context.fetch(FetchDescriptor<UnknownRecord>())) ?? [] { context.delete(u) }
        try? context.save()
    }

    // MARK: Restoring

    /// Replaces this replica with a backup and re-stamps all of it, with tombstones for everything
    /// else, so the restore reaches the whole household instead of being overridden by newer copies.
    static func restore(_ backup: Snapshot, into context: ModelContext) {
        let now = Date()
        let keep = Set(backup.records.map(\.uid))
        for type in SyncRegistry.kinds {
            for model in fetchAll(type, context) where !keep.contains(model.uid) {
                upsertTombstone(SyncTombstone(kind: type.syncKind, uid: model.uid, deletedAt: stampClock.now(now),
                                              deletedBy: deviceId), in: context)
                context.delete(model)
            }
        }
        for u in (try? context.fetch(FetchDescriptor<UnknownRecord>())) ?? [] where !keep.contains(u.uid) {
            context.delete(u)
        }
        try? context.save()

        let device = deviceId
        let restamped = backup.records.map {
            SyncRecord(kind: $0.kind, uid: $0.uid, modifiedAt: stampClock.now(now), modifiedBy: device, data: $0.data)
        }
        // Tombstones for restored records must not win over the restore.
        let tombstones = backup.tombstones.filter { !keep.contains($0.uid) }
        let result = Merge.merge([(restamped, tombstones)])
        let resolver = SyncResolver(context: context)
        var summary = MergeSummary()
        for t in result.tombstones.values { upsertTombstone(t, in: context) }
        let order = Dictionary(uniqueKeysWithValues: SyncRegistry.kinds.enumerated().map { ($1.syncKind, $0) })
        for r in result.records.values.sorted(by: { (order[$0.kind] ?? Int.max, $0.uid) < (order[$1.kind] ?? Int.max, $1.uid) }) {
            if let type = SyncRegistry.type(for: r.kind) {
                applyRecord(r, type: type, resolver: resolver, context: context, summary: &summary)
            } else {
                let uid = r.uid
                if let u = try? context.fetch(FetchDescriptor<UnknownRecord>(predicate: #Predicate { $0.uid == uid })).first {
                    u.set(r)
                } else {
                    context.insert(UnknownRecord(r))
                }
            }
        }
        // Tombstones of restored uids would delete them on other devices only if newer; they aren't.
        for type in SyncRegistry.kinds {
            for model in fetchAll(type, context) where keep.contains(model.uid) {
                let uid = model.uid
                if let t = try? context.fetch(FetchDescriptor<TombstoneEntry>(predicate: #Predicate { $0.uid == uid })).first {
                    context.delete(t)
                }
            }
        }
        removeOrphans(in: context)
        for task in fetchAll(MaintenanceTask.self, context) { task.refreshDerived() }
        try? context.save()
    }
}
