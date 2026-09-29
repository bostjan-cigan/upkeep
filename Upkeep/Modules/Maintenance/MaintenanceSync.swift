import Foundation
import SwiftData

// Record kinds of the maintenance module: `homeItem`, `task`, `taskLog` (Docs/Sync.md).

extension HomeItem: SyncableModel {
    static var syncKind: String { "homeItem" }

    var knownSyncData: [String: JSONValue] {
        ["name": .string(name), "iconKey": .string(iconKey), "colorKey": .string(colorKey),
         "notes": .string(notes), "room": .string(room), "createdAt": .date(createdAt)]
    }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        name = data["name"]?.stringValue ?? ""
        iconKey = data["iconKey"]?.stringValue ?? IconKey.generic.rawValue
        colorKey = data["colorKey"]?.stringValue ?? TileColor.blue.rawValue
        notes = data["notes"]?.stringValue ?? ""
        room = data["room"]?.stringValue ?? ""
        createdAt = data["createdAt"]?.dateValue ?? createdAt
    }

    var syncChildren: [any SyncableModel] { tasks ?? [] }

    static func makeForSync() -> HomeItem { HomeItem(name: "", icon: .generic, color: .blue) }
}

extension MaintenanceTask: SyncableModel {
    static var syncKind: String { "task" }

    var knownSyncData: [String: JSONValue] {
        ["itemUid": .string(item?.uid ?? ""), "title": .string(title),
         "intervalValue": .int(intervalValue), "intervalUnit": .string(intervalUnitRaw),
         "scheduleKind": .string(scheduleKindRaw), "anchorDate": .date(anchorDate), "repeats": .bool(repeats),
         "isActive": .bool(isActive), "baselineDoneAt": .date(baselineDoneAt), "snoozedUntil": .date(snoozedUntil),
         "preferredDays": .string(preferredDays), "shiftedFrom": .date(shiftedFrom), "shiftedTo": .date(shiftedTo),
         "assigneeUid": .string(assigneeUid), "onceAssigneeUid": onceAssigneeUid.map(JSONValue.string) ?? .null,
         "onceAssigneeAfter": .date(onceAssigneeAfter), "createdAt": .date(createdAt)]
    }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        let itemUid = data["itemUid"]?.stringValue ?? ""
        if item?.uid != itemUid { item = resolver.model(itemUid, as: HomeItem.self) }
        title = data["title"]?.stringValue ?? ""
        intervalValue = data["intervalValue"]?.intValue ?? 1
        intervalUnitRaw = data["intervalUnit"]?.stringValue ?? IntervalUnit.month.rawValue
        scheduleKindRaw = data["scheduleKind"]?.stringValue ?? ScheduleKind.interval.rawValue
        anchorDate = data["anchorDate"]?.dateValue
        repeats = data["repeats"]?.boolValue ?? true
        isActive = data["isActive"]?.boolValue ?? true
        baselineDoneAt = data["baselineDoneAt"]?.dateValue
        snoozedUntil = data["snoozedUntil"]?.dateValue
        preferredDays = data["preferredDays"]?.stringValue ?? Weekdays.any
        shiftedFrom = data["shiftedFrom"]?.dateValue
        shiftedTo = data["shiftedTo"]?.dateValue
        assigneeUid = data["assigneeUid"]?.stringValue ?? ""
        onceAssigneeUid = data["onceAssigneeUid"]?.stringValue
        onceAssigneeAfter = data["onceAssigneeAfter"]?.dateValue
        createdAt = data["createdAt"]?.dateValue ?? createdAt
    }

    var syncChildren: [any SyncableModel] { logs ?? [] }

    static func makeForSync() -> MaintenanceTask { MaintenanceTask(title: "", every: 1, .month, lastDone: nil) }
}

extension MaintenanceLog: SyncableModel {
    static var syncKind: String { "taskLog" }

    var knownSyncData: [String: JSONValue] {
        ["taskUid": .string(task?.uid ?? ""), "completedAt": .date(completedAt),
         "note": .string(note), "completedByUid": .string(completedByUid)]
    }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        let taskUid = data["taskUid"]?.stringValue ?? ""
        if task?.uid != taskUid { task = resolver.model(taskUid, as: MaintenanceTask.self) }
        completedAt = data["completedAt"]?.dateValue ?? completedAt
        note = data["note"]?.stringValue ?? ""
        completedByUid = data["completedByUid"]?.stringValue ?? ""
    }

    var syncChildren: [any SyncableModel] { [] }

    static func makeForSync() -> MaintenanceLog { MaintenanceLog(completedAt: Date()) }
}
