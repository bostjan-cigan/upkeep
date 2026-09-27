import Foundation
import SwiftData

// Models follow the CloudKit-compatible SwiftData rules (every attribute has a default or is
// optional, relationships are optional, no unique constraints) so iCloud sync stays an option.

/// Something in the home that needs looking after: an appliance, a door, the floors…
@Model
final class HomeItem {
    /// Stable identity used by backups and restores.
    var uid: String = UUID().uuidString
    var name: String = ""
    var iconKey: String = IconKey.generic.rawValue
    var colorKey: String = TileColor.blue.rawValue
    var notes: String = ""
    /// Free-form group such as "Kitchen". Empty means ungrouped.
    var room: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    @Relationship(deleteRule: .cascade, inverse: \MaintenanceTask.item)
    var tasks: [MaintenanceTask]? = []

    init(name: String, icon: IconKey, color: TileColor, room: String = "") {
        self.uid = UUID().uuidString
        self.name = name
        self.room = room
        self.iconKey = icon.rawValue
        self.colorKey = color.rawValue
        self.createdAt = Date()
    }

    var icon: IconKey { IconKey(rawValue: iconKey) ?? .generic }
    var color: TileColor { TileColor(rawValue: colorKey) ?? .blue }

    var sortedTasks: [MaintenanceTask] {
        (tasks ?? []).filter(\.isActive).sorted { $0.nextDueAt < $1.nextDueAt }
    }

    var pausedTasks: [MaintenanceTask] {
        (tasks ?? []).filter { !$0.isActive }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Template suggestions for this kind of item that aren't part of its routine yet.
    var missingSuggestions: [TaskSuggestion] {
        let existing = Set((tasks ?? []).map { $0.title.lowercased() })
        var seen = Set<String>()
        return ItemTemplate.all.filter { $0.icon == icon }.flatMap(\.suggestions).filter {
            let key = $0.title.lowercased()
            return !existing.contains(key) && seen.insert(key).inserted
        }
    }

    var history: [MaintenanceLog] {
        (tasks ?? []).flatMap { $0.logs ?? [] }.sorted { $0.completedAt > $1.completedAt }
    }

    var dueTaskCount: Int { (tasks ?? []).filter(\.needsAttention).count }
    @MainActor var myDueTaskCount: Int { (tasks ?? []).filter { $0.needsAttention && $0.isMine }.count }
}

/// What a move applies to, the way a calendar asks it.
enum MoveScope: String, CaseIterable, Identifiable {
    case thisOnce, allFuture
    var id: String { rawValue }
}

enum Rooms {
    static let suggestions = ["Kitchen", "Bathroom", "Living Room", "Bedroom", "Hallway", "Balcony"]
    static let ungroupedTitle = "Other"

    /// Named rooms alphabetically, ungrouped last.
    static func grouped<T>(_ values: [T], by room: (T) -> String) -> [(room: String, values: [T])] {
        Dictionary(grouping: values, by: { room($0).trimmingCharacters(in: .whitespaces) })
            .map { (room: $0.key, values: $0.value) }
            .sorted { a, b in
                if a.room.isEmpty != b.room.isEmpty { return !a.room.isEmpty }
                return a.room.localizedStandardCompare(b.room) == .orderedAscending
            }
    }

    /// Ungrouped things read as "Home" until at least one room exists.
    static func title(_ room: String, hasRooms: Bool = true) -> String {
        room.isEmpty ? (hasRooms ? ungroupedTitle : "Home") : room
    }
}

/// A recurring chore that belongs to an item, e.g. "Clean the filter every month".
@Model
final class MaintenanceTask {
    var uid: String = UUID().uuidString
    var title: String = ""
    var intervalValue: Int = 1
    var intervalUnitRaw: String = IntervalUnit.month.rawValue
    var createdAt: Date = Date()
    /// "Last done" entered without a log, e.g. "I just did these". Synced.
    var baselineDoneAt: Date?
    /// Derived from `baselineDoneAt` and the logs by `refreshDerived()`; never synced.
    var lastDoneAt: Date?
    /// Derived by `refreshDerived()`; stored so it can be queried and sorted. Never synced.
    var nextDueAt: Date = Date()
    /// Per-task snooze. Nagging for this task resumes after this date.
    var snoozedUntil: Date?
    /// Days of the week this task prefers, as `Weekdays` digits. Empty means any day.
    var preferredDays: String = Weekdays.any
    /// A one-off move of a single occurrence: the due date it was made against, and where it went.
    /// The move is ignored once the task no longer falls on `shiftedFrom`, so it can't linger.
    var shiftedFrom: Date?
    var shiftedTo: Date?
    /// The responsible person's uid; empty means everyone.
    var assigneeUid: String = ""
    /// A one-off hand-over of the next occurrence ("" = everyone; nil = none), and the last completion
    /// it was made after. It only counts until the task is done again, so it can't linger.
    var onceAssigneeUid: String?
    var onceAssigneeAfter: Date?
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""
    /// Paused tasks keep their history but never show up as due or trigger reminders.
    var isActive: Bool = true
    var scheduleKindRaw: String = ScheduleKind.interval.rawValue
    /// Fixed-date tasks: the first due date; later ones follow every interval from it.
    var anchorDate: Date?
    /// Fixed-date tasks: false means a one-off that finishes once done.
    var repeats: Bool = true
    var item: HomeItem?

    @Relationship(deleteRule: .cascade, inverse: \MaintenanceLog.task)
    var logs: [MaintenanceLog]? = []

    init(title: String, every value: Int, _ unit: IntervalUnit, lastDone: Date?) {
        self.uid = UUID().uuidString
        self.title = title
        self.intervalValue = max(1, value)
        self.intervalUnitRaw = unit.rawValue
        self.createdAt = Date()
        self.baselineDoneAt = lastDone
        self.nextDueAt = Date()
        refreshDerived()
    }

    var intervalUnit: IntervalUnit {
        get { IntervalUnit(rawValue: intervalUnitRaw) ?? .month }
        set { intervalUnitRaw = newValue.rawValue }
    }

    var scheduleKind: ScheduleKind {
        get { ScheduleKind(rawValue: scheduleKindRaw) ?? .interval }
        set { scheduleKindRaw = newValue.rawValue }
    }

    var isFixedDate: Bool { scheduleKind == .fixedDate }

    /// A pending one-off move, if one applies to the occurrence it was made for.
    var shift: (from: Date, to: Date)? {
        guard let shiftedFrom, let shiftedTo else { return nil }
        return (from: shiftedFrom, to: shiftedTo)
    }

    /// Whether a preferred day means anything for this schedule (see `Schedule.snaps`).
    var honoursPreferredDays: Bool {
        Schedule.snaps(kind: scheduleKind, value: intervalValue, unit: intervalUnit)
    }

    /// Whether a day of the week is the lasting way to move this task: one it already has, or one
    /// it would naturally take.
    var movesByWeekday: Bool {
        honoursPreferredDays
            && (!preferredDays.isEmpty || Schedule.prefersWeekday(kind: scheduleKind, value: intervalValue, unit: intervalUnit))
    }

    /// Whether "this and all future" can really change the series. A fixed date moves its dates and a
    /// task never done yet moves its start date; an after-last-done task only keeps a day of the week,
    /// so for a rare one — bleed the radiators once a year — there's nothing lasting to change.
    var canMoveSeries: Bool {
        if isFixedDate && anchorDate != nil { return true }
        if lastDoneAt == nil { return true }
        return movesByWeekday
    }

    /// A one-off fixed-date task that has been done (and so switched itself off).
    var isFinished: Bool { isFixedDate && !repeats && !isActive && lastDoneAt != nil }

    var intervalDescription: String {
        Self.describe(value: intervalValue, unit: intervalUnit, fixedDate: isFixedDate ? anchorDate : nil,
                      repeats: repeats, preferredDays: preferredDays)
    }

    /// "Every 3 months", "Every 2 weeks on Saturdays", "Every year on 15 Sep", "Once on 15 Sep 2026".
    /// A nil `fixedDate` means after last done.
    static func describe(value: Int, unit: IntervalUnit, fixedDate: Date?, repeats: Bool,
                         preferredDays: String = Weekdays.any) -> String {
        var every = value == 1 ? "Every \(unit.rawValue)" : "Every \(value) \(unit.label(value))"
        if fixedDate == nil, Schedule.snaps(kind: .interval, value: value, unit: unit),
           let days = Weekdays.label(preferredDays) {
            every += " on \(days)"
        }
        guard let fixedDate else { return every }
        if !repeats { return "Once on \(fixedDate.formatted(date: .abbreviated, time: .omitted))" }
        let day = fixedDate.formatted(.dateTime.month(.abbreviated).day())
        return unit == .year ? "\(every) on \(day)" : "\(every) from \(day)"
    }

    /// Makes this a fixed-date task first due on `date`; completions replay from there.
    func setFixedDate(_ date: Date, repeats: Bool) {
        scheduleKind = .fixedDate
        anchorDate = Calendar.current.startOfDay(for: date)
        self.repeats = repeats
        refreshDerived()
    }

    /// Recomputes `lastDoneAt` and `nextDueAt` from the synced fields and the logs (Docs/Sync.md).
    /// Every device runs the same calculation, so all of them agree on when a task is due.
    func refreshDerived(excluding removed: MaintenanceLog? = nil, now: Date = Date()) {
        let completions = (logs ?? []).filter { $0 !== removed }.map(\.completedAt)
        let (last, next) = Schedule.derive(kind: scheduleKind, anchorDate: anchorDate, repeats: repeats,
                                           value: intervalValue, unit: intervalUnit,
                                           baselineDoneAt: baselineDoneAt, completions: completions,
                                           preferredDays: preferredDays, shift: shift, now: now)
        // Only assign real changes, so recomputing doesn't dirty the store.
        if lastDoneAt != last { lastDoneAt = last }
        if nextDueAt != next { nextDueAt = next }
    }

    @MainActor func markDone(on date: Date = Date(), note: String = "", in context: ModelContext) {
        let log = MaintenanceLog(completedAt: date, note: note)
        log.completedByUid = Household.shared.myPersonUid
        context.insert(log)
        log.task = self
        snoozedUntil = nil
        clearShift()
        clearOnceAssignee()
        if isFixedDate && anchorDate != nil && !repeats { isActive = false }
        refreshDerived()
    }

    /// A one-off move belongs to the occurrence it was made for and goes with it.
    func clearShift() {
        if shiftedFrom != nil { shiftedFrom = nil }
        if shiftedTo != nil { shiftedTo = nil }
    }

    /// Who's responsible for the occurrence that's due next: a one-off hand-over, or the usual person.
    var currentAssigneeUid: String {
        Schedule.currentAssignee(assigneeUid: assigneeUid, onceAssigneeUid: onceAssigneeUid,
                                 onceAssigneeAfter: onceAssigneeAfter, lastDoneAt: lastDoneAt)
    }

    /// Whether the next occurrence has been handed to someone other than the usual person.
    var isHandedOver: Bool { currentAssigneeUid != assigneeUid }

    /// Hands just the next occurrence to `uid` ("" = everyone). Picking the usual person takes it back.
    func assignOnce(_ uid: String) {
        if uid == assigneeUid {
            clearOnceAssignee()
            return
        }
        onceAssigneeUid = uid
        onceAssigneeAfter = lastDoneAt
    }

    /// A hand-over belongs to the occurrence it was made for and goes with it.
    func clearOnceAssignee() {
        if onceAssigneeUid != nil { onceAssigneeUid = nil }
        if onceAssigneeAfter != nil { onceAssigneeAfter = nil }
    }

    /// Moves the next occurrence to `date`, either on its own or taking the rest of the series with it.
    func move(to date: Date, scope: MoveScope, now: Date = Date()) {
        let cal = Calendar.current
        let target = cal.startOfDay(for: date)
        let current = cal.startOfDay(for: nextDueAt)
        guard target != current else { return }
        switch scope {
        case .thisOnce:
            shiftedFrom = current
            shiftedTo = target
        case .allFuture:
            clearShift()
            if isFixedDate, let anchor = anchorDate {
                // The series is the dates themselves, so move every one of them by the same distance.
                let days = cal.dateComponents([.day], from: current, to: target).day ?? 0
                anchorDate = cal.date(byAdding: .day, value: days, to: anchor) ?? anchor
            } else {
                // An after-last-done task rebuilds itself from each completion, so what lasts is the
                // day of the week. A task never done yet also gets its start date moved.
                if movesByWeekday {
                    preferredDays = Weekdays.string(from: [cal.component(.weekday, from: target)])
                }
                if lastDoneAt == nil { anchorDate = target }
                refreshDerived(now: now)
                // A move of more than a few days lands further out than snapping can reach; the
                // occurrence on the calendar right now still needs carrying across.
                let landed = cal.startOfDay(for: nextDueAt)
                if landed != target {
                    shiftedFrom = landed
                    shiftedTo = target
                }
            }
        }
        refreshDerived(now: now)
    }

    /// Call when a log is being removed so the schedule reflects the remaining history.
    func refreshFromLogs(excluding removed: MaintenanceLog) {
        let wasFinished = isFinished
        refreshDerived(excluding: removed)
        if wasFinished && lastDoneAt == nil { isActive = true }
    }

    /// The newest ticked-off completion; unlike `lastDoneAt`, never a "last done" typed in.
    var lastCompletedAt: Date? { (logs ?? []).map(\.completedAt).max() }

    var isSnoozed: Bool { (snoozedUntil ?? .distantPast) > Date() }

    var isDue: Bool { nextDueAt <= Date() }

    /// Due and not snoozed: the things we nag about.
    var needsAttention: Bool { isActive && isDue && !isSnoozed }

    /// The next occurrence is assigned to me, or to everyone.
    @MainActor var isMine: Bool { Self.isMine(currentAssigneeUid) }

    /// Assigned to me, or to everyone (including a person who no longer exists).
    @MainActor static func isMine(_ uid: String) -> Bool {
        uid.isEmpty || uid == Household.shared.myPersonUid || !Household.shared.personExists(uid)
    }

    var status: DueStatus { DueStatus(for: nextDueAt) }
}

@Model
final class MaintenanceLog {
    var uid: String = UUID().uuidString
    var completedAt: Date = Date()
    var note: String = ""
    /// Who marked it done; empty if unknown.
    var completedByUid: String = ""
    var task: MaintenanceTask?
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    init(completedAt: Date, note: String = "") {
        self.uid = UUID().uuidString
        self.completedAt = completedAt
        self.note = note
    }
}
