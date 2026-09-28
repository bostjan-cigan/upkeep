import AppKit
import CoreData
import Foundation
import SwiftData
import UserNotifications

/// Keeps pestering you about due tasks until they are done or silenced.
///
/// Reminders are plain local notifications scheduled ahead of time on a fixed clock grid
/// (e.g. 9:00, 12:00, 15:00, 18:00 with a 3-hour interval) within active hours, so they
/// arrive on time while the app sits in the menu bar. Only the current calendar week is queued,
/// so nothing waits days in macOS for a task someone may have done elsewhere by then; the next
/// week's come in with the first reschedule after it starts. Quitting clears them: a quit app stays
/// quiet. Days you turned reminders off and, if set,
/// your work hours on work days are skipped. Only tasks assigned to this device's person, or to
/// everyone, count, using that person's reminder settings (which sync with them). The schedule
/// is rebuilt whenever data changes, including changes merged in from the household.
@MainActor
@Observable
final class Nagger: NSObject {
    static let shared = Nagger()

    private(set) var dueCount = 0
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// Used only until this Mac knows who its person is.
    private var localSilencedUntil: Date?

    private var container: ModelContainer?
    private var rescheduleWork: Task<Void, Never>?
    private var timer: Timer?
    private var isStopped = false
    private let center = UNUserNotificationCenter.current()

    /// Weekday sets are stored as digit strings of `Calendar` weekdays (1 = Sunday … 7 = Saturday).
    enum Defaults {
        static let remindDays = "1234567"
        static let workDays = "23456"
        static let workStart = 9
        static let workEnd = 17
    }

    nonisolated static func weekdays(from string: String) -> Set<Int> { Weekdays.set(from: string) }

    nonisolated static func string(from weekdays: Set<Int>) -> String { Weekdays.string(from: weekdays) }

    enum Action {
        static let done = "DONE"
        static let snoozeTask = "SNOOZE_TASK_1D"
        static let silenceDay = "SILENCE_1D"
        static let silence3Days = "SILENCE_3D"
    }

    enum Category {
        static let single = "SINGLE_TASK"
        static let multiple = "MULTIPLE_TASKS"
    }

    private var me: Person? { Household.shared.me }

    var nagIntervalHours: Int { max(1, me?.nagHours ?? 3) }
    var activeStartHour: Int { me?.activeStart ?? 9 }
    var activeEndHour: Int { me?.activeEnd ?? 21 }
    var remindWeekdays: Set<Int> { Self.weekdays(from: me?.remindDays ?? Defaults.remindDays) }
    var workScheduleEnabled: Bool { me?.workEnabled ?? false }
    var workWeekdays: Set<Int> { Self.weekdays(from: me?.workDays ?? Defaults.workDays) }
    var workStartHour: Int { me?.workStart ?? Defaults.workStart }
    var workEndHour: Int { me?.workEnd ?? Defaults.workEnd }

    var silencedUntil: Date? { me.map(\.silencedUntil) ?? localSilencedUntil }
    var isSilenced: Bool { (silencedUntil ?? .distantPast) > Date() }

    func start(container: ModelContainer) {
        self.container = container

        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.single, actions: [
                UNNotificationAction(identifier: Action.done, title: "Mark as Done"),
                UNNotificationAction(identifier: Action.snoozeTask, title: "Remind Me Tomorrow"),
                UNNotificationAction(identifier: Action.silence3Days, title: "Silence All for 3 Days"),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.multiple, actions: [
                UNNotificationAction(identifier: Action.silenceDay, title: "Remind Me Tomorrow"),
                UNNotificationAction(identifier: Action.silence3Days, title: "Silence for 3 Days"),
            ], intentIdentifiers: []),
        ])

        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorization = await center.notificationSettings().authorizationStatus
            reschedule()
        }

        // Local saves and iCloud imports both funnel into a debounced reschedule.
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setNeedsReschedule() }
        }
        NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setNeedsReschedule() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setNeedsReschedule() }
        }
        // Keeps the badge honest as tasks cross their due time while the app sits in the menu bar.
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.setNeedsReschedule() }
        }
        reschedule()
    }

    /// Quitting means "stop nagging": drops the reminders queued with macOS, which would
    /// otherwise keep arriving (and going stale) until the app runs again.
    func stop() async {
        isStopped = true
        rescheduleWork?.cancel()
        timer?.invalidate()
        center.removeAllPendingNotificationRequests()
        // The removal is fire-and-forget; reading the queue back waits until it has landed.
        _ = await center.pendingNotificationRequests()
    }

    #if DEBUG
    /// Developer menu: clears everything this app has queued or shown. The schedule comes back
    /// on the next reschedule (a data change, reactivation, or the 15-minute timer).
    func resetAllNotifications() {
        rescheduleWork?.cancel()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    #endif

    // MARK: Silence

    /// Silencing belongs to the person, so it applies on all of their devices.
    func silence(for days: Int) {
        setSilenced(Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date())
    }

    func unsilence() { setSilenced(nil) }

    private func setSilenced(_ until: Date?) {
        if let me {
            me.silencedUntil = until
            try? container?.mainContext.save()
        } else {
            localSilencedUntil = until
        }
        reschedule()
    }

    // MARK: Scheduling

    func setNeedsReschedule() {
        rescheduleWork?.cancel()
        rescheduleWork = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            reschedule()
        }
    }

    func reschedule() {
        guard let container, !isStopped else { return }
        let tasks = ((try? container.mainContext.fetch(FetchDescriptor<MaintenanceTask>(predicate: #Predicate { $0.isActive }))) ?? [])
            .filter(\.isMine)

        dueCount = tasks.filter(\.needsAttention).count
        NSApp?.dockTile.badgeLabel = dueCount > 0 ? "\(dueCount)" : nil

        center.removeAllPendingNotificationRequests()
        if dueCount == 0 { center.removeAllDeliveredNotifications() }
        guard authorization == .authorized || authorization == .provisional else { return }

        let now = Date()
        let start = max(now, silencedUntil ?? now)
        // This week only, the same week Up Next shows.
        let cal = Calendar.current
        let weekEnd = cal.date(byAdding: .day, value: 7, to: UpNextBucket.weekStart(now, calendar: cal)) ?? now
        var scheduled = 0
        for slot in nagSlots(after: start) {
            guard slot < weekEnd, scheduled < 48 else { break }
            let due = Self.due(tasks, at: slot)
            guard !due.isEmpty else { continue }
            center.add(request(for: due, at: slot))
            scheduled += 1
        }
    }

    private func nagSlots(after start: Date) -> [Date] {
        Self.nagSlots(after: start, for: ReminderPrefs(me))
    }

    /// A person's reminder settings, or the defaults when there's no person.
    struct ReminderPrefs {
        var nagHours = 3, activeStart = 9, activeEnd = 21
        var remindDays = Nagger.weekdays(from: Defaults.remindDays)
        var workEnabled = false
        var workDays = Nagger.weekdays(from: Defaults.workDays)
        var workStart = Defaults.workStart, workEnd = Defaults.workEnd

        init(_ person: Person?) {
            guard let p = person else { return }
            nagHours = max(1, p.nagHours)
            activeStart = p.activeStart
            activeEnd = p.activeEnd
            remindDays = Nagger.weekdays(from: p.remindDays)
            workEnabled = p.workEnabled
            workDays = Nagger.weekdays(from: p.workDays)
            workStart = p.workStart
            workEnd = p.workEnd
        }
    }

    /// Clock-aligned reminder times over the next week, within active hours on reminder days,
    /// skipping work hours on work days. Also used for phones' push reminders.
    static func nagSlots(after start: Date, for prefs: ReminderPrefs, days: Int = 8) -> [Date] {
        let cal = Calendar.current
        let step = max(1, prefs.nagHours)
        let endHour = max(prefs.activeEnd, prefs.activeStart + 1)
        let workDays = prefs.workEnabled ? prefs.workDays : []
        let workHours = prefs.workStart..<max(prefs.workEnd, prefs.workStart)
        var slots: [Date] = []
        for dayOffset in 0..<days {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: start)) else { continue }
            let weekday = cal.component(.weekday, from: day)
            guard prefs.remindDays.contains(weekday) else { continue }
            let isWorkDay = workDays.contains(weekday)
            var hour = prefs.activeStart
            while hour <= endHour {
                defer { hour += step }
                if isWorkDay && workHours.contains(hour) { continue }
                if let t = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day), t > start {
                    slots.append(t)
                }
            }
        }
        return slots
    }

    /// Tasks to nag about at `slot`: due by then and not snoozed past it.
    static func due(_ tasks: [MaintenanceTask], at slot: Date) -> [MaintenanceTask] {
        tasks.filter { $0.isActive && $0.nextDueAt <= slot && ($0.snoozedUntil ?? .distantPast) <= slot }
            .sorted { $0.nextDueAt < $1.nextDueAt }
    }

    /// Notification text for the tasks due at `date`.
    static func message(for due: [MaintenanceTask], at date: Date) -> (title: String, body: String) {
        if due.count == 1, let task = due.first {
            return (task.item?.name ?? "Maintenance", "\(task.title) — \(DueStatus(for: task.nextDueAt, now: date).text.lowercased())")
        }
        let names = due.prefix(3).map { "\($0.item?.name ?? ""): \($0.title)" }
        return ("\(due.count) maintenance tasks are waiting",
                names.joined(separator: "\n") + (due.count > 3 ? "\n+ \(due.count - 3) more" : ""))
    }

    /// The app icon as PNG bytes, rendered once. macOS draws the app's own icon on a
    /// notification, but a freshly built copy Launch Services hasn't caught up with shows a
    /// blank one; an attachment is drawn from the file, so a reminder always looks like Upkeep.
    private static let iconPNG: Data? = {
        // The bundle's own icon first (AppIcon.icns in a local build, the asset catalog in the
        // Xcode one); `applicationIconImage` only as a fallback, since it's the generic icon
        // itself whenever macOS couldn't work the app's out.
        let icon = Bundle.main.image(forResource: "AppIcon") ?? NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName)
        guard let icon else { return nil }
        // Straight from the largest representation the icon has: drawing it into a canvas of our
        // own would upscale whichever one matches `icon.size` (128 pt) and look soft.
        if let biggest = icon.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) as? NSBitmapImageRep,
           let png = biggest.representation(using: .png, properties: [:]) {
            return png
        }
        let size = NSSize(width: 512, height: 512)
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size))
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }()

    /// A fresh copy each time: the notification centre takes the file over, source and all.
    private static func iconAttachment() -> UNNotificationAttachment? {
        guard let png = iconPNG else { return nil }
        let url = FileManager.default.temporaryDirectory.appending(path: "upkeep-icon-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        guard let attachment = try? UNNotificationAttachment(identifier: "icon", url: url, options: nil) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return attachment
    }

    private func request(for due: [MaintenanceTask], at date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.threadIdentifier = "upkeep"
        if let icon = Self.iconAttachment() { content.attachments = [icon] }
        (content.title, content.body) = Self.message(for: due, at: date)
        if due.count == 1, let task = due.first {
            content.categoryIdentifier = Category.single
            content.userInfo = ["taskUID": task.uid]
        } else {
            content.categoryIdentifier = Category.multiple
        }
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(identifier: "nag-\(Int(date.timeIntervalSince1970))", content: content, trigger: trigger)
    }

    // MARK: Actions

    func task(withUID uid: String) -> MaintenanceTask? {
        guard let container else { return nil }
        var fd = FetchDescriptor<MaintenanceTask>(predicate: #Predicate { $0.uid == uid })
        fd.fetchLimit = 1
        return try? container.mainContext.fetch(fd).first
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        reschedule()
    }

    fileprivate func handle(action: String, taskUID: String?) {
        switch action {
        case Action.done:
            if let uid = taskUID, let task = task(withUID: uid), let ctx = container?.mainContext {
                task.markDone(in: ctx)
                try? ctx.save()
            }
        case Action.snoozeTask:
            if let uid = taskUID, let task = task(withUID: uid) {
                task.snoozedUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date())
                try? container?.mainContext.save()
            }
        case Action.silenceDay:
            silence(for: 1)
        case Action.silence3Days:
            silence(for: 3)
        default:
            NSApp.activate()
            AppState.shared.selection = .upNext
            AppState.shared.openMainWindow?()
        }
        reschedule()
    }
}

extension Nagger: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let uid = response.notification.request.content.userInfo["taskUID"] as? String
        await MainActor.run { handle(action: action, taskUID: uid) }
    }
}
