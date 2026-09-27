import Foundation

// Scheduling maths, kept free of SwiftData so it can be tested and matched line for line by the
// PWA (Docs/Sync.md › task › Derived).

enum IntervalUnit: String, CaseIterable, Identifiable, Codable {
    case day, week, month, year
    var id: String { rawValue }

    var component: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }

    func label(_ value: Int) -> String {
        let base = rawValue
        return value == 1 ? base : base + "s"
    }
}

/// Weekday sets, stored as digit strings of `Calendar` weekdays (1 = Sunday … 7 = Saturday).
/// Empty means "any day". Used for a person's reminder days and for a task's preferred days.
enum Weekdays {
    static let any = ""
    static let weekend = "17"
    static let everyDay = "1234567"
    static let workDays = "23456"

    static func set(from string: String) -> Set<Int> {
        Set(string.compactMap { $0.wholeNumberValue }.filter { (1...7).contains($0) })
    }

    static func string(from weekdays: Set<Int>) -> String {
        weekdays.sorted().map(String.init).joined()
    }

    /// "Saturdays", "weekends", "weekdays", "Mon & Thu" — nil when any day will do.
    static func label(_ digits: String, calendar cal: Calendar = .current) -> String? {
        let days = set(from: digits)
        if days.isEmpty || days.count == 7 { return nil }
        if days == [1, 7] { return "weekends" }
        if days == [2, 3, 4, 5, 6] { return "weekdays" }
        if days.count == 1, let day = days.first { return cal.weekdaySymbols[day - 1] + "s" }
        return days.sorted().map { cal.shortWeekdaySymbols[$0 - 1] }.joined(separator: " & ")
    }
}

/// How a task's due date moves forward when it's done.
enum ScheduleKind: String, CaseIterable, Identifiable, Codable {
    /// Due a set time after it was last done, e.g. every 3 months.
    case interval
    /// Due on calendar dates, e.g. every year on 1 September, however early or late it was done.
    case fixedDate
    var id: String { rawValue }
}

enum Schedule {
    /// `lastDoneAt` and `nextDueAt` from a task's synced fields and its completions.
    ///
    /// Three steps: work out the date the schedule puts it on, move that onto a preferred day, then
    /// apply a pending one-off shift. Every device runs this, so all of them agree on when a task is due.
    static func derive(kind: ScheduleKind, anchorDate: Date?, repeats: Bool, value: Int, unit: IntervalUnit,
                       baselineDoneAt: Date?, completions: [Date], preferredDays: String = Weekdays.any,
                       shift: (from: Date, to: Date)? = nil, now: Date = Date(),
                       calendar cal: Calendar = .current) -> (lastDoneAt: Date?, nextDueAt: Date) {
        let sorted = completions.sorted()
        let last = ([baselineDoneAt].compactMap { $0 } + sorted).max()
        var due: Date
        if kind == .fixedDate, let anchorDate {
            // Replay the history over the calendar dates so early and late completions both count.
            due = cal.startOfDay(for: anchorDate)
            if repeats {
                for date in sorted { due = fixedDue(after: date, current: due, value: value, unit: unit, calendar: cal) }
            }
        } else if let last {
            let base = cal.startOfDay(for: last)
            due = cal.date(byAdding: unit.component, value: value, to: base) ?? base
        } else {
            // Never done: the day the user chose to start, or today.
            due = cal.startOfDay(for: anchorDate ?? now)
        }
        due = snap(due, to: preferredDays, kind: kind, value: value, unit: unit, now: now, calendar: cal)
        if let shift, cal.startOfDay(for: shift.from) == due { due = cal.startOfDay(for: shift.to) }
        return (last, due)
    }

    /// Offsets tried when moving a due date onto a preferred day: nearest first, ties preferring the
    /// later day, and reaching far enough forward to find one even when the nearer days are past.
    private static let snapOffsets = [0, 1, -1, 2, -2, 3, -3, 4, 5, 6]

    /// Moves `due` onto the nearest preferred weekday, so a chore lands on the day the household
    /// actually does chores rather than wherever the interval happened to put it. A due date already
    /// in the past stays put: overdue is overdue, and nothing is ever pushed further away from today.
    static func snap(_ due: Date, to preferredDays: String, kind: ScheduleKind, value: Int, unit: IntervalUnit,
                     now: Date = Date(), calendar cal: Calendar = .current) -> Date {
        guard snaps(kind: kind, value: value, unit: unit) else { return due }
        let days = Weekdays.set(from: preferredDays)
        guard !days.isEmpty else { return due }
        let today = cal.startOfDay(for: now)
        guard due >= today else { return due }
        for offset in snapOffsets {
            guard let day = cal.date(byAdding: .day, value: offset, to: due), day >= today else { continue }
            if days.contains(cal.component(.weekday, from: day)) { return day }
        }
        return due
    }

    /// Who's responsible for the occurrence that's due next: a one-off hand-over made since the last
    /// completion, otherwise the usual person. The dates compare as they're stored, to the millisecond,
    /// so a hand-over made on one device still matches on another. A completion from anywhere ends it.
    static func currentAssignee(assigneeUid: String, onceAssigneeUid: String?, onceAssigneeAfter: Date?,
                                lastDoneAt: Date?) -> String {
        guard let onceAssigneeUid,
              onceAssigneeAfter.map(SyncCoding.dateString) == lastDoneAt.map(SyncCoding.dateString)
        else { return assigneeUid }
        return onceAssigneeUid
    }

    /// A preferred day only makes sense for work that comes round at least weekly. A fixed date is
    /// about the date itself, and a daily chore can't wait for Saturday.
    static func snaps(kind: ScheduleKind, value: Int, unit: IntervalUnit) -> Bool {
        if kind == .fixedDate { return false }
        if unit == .day && value < 7 { return false }
        return true
    }

    /// Whether a day of the week is the natural way to describe this schedule. True for ordinary
    /// chores, false for anything rare enough that the date matters more than the day.
    static func prefersWeekday(kind: ScheduleKind, value: Int, unit: IntervalUnit) -> Bool {
        !suggestedDays(value: value, unit: unit, kind: kind, choreDays: Weekdays.everyDay).isEmpty
    }

    /// The preferred days a new task starts with: the person's chore days for ordinary chores, none
    /// for anything rare enough that the date matters more than the day, such as a yearly AC service.
    static func suggestedDays(value: Int, unit: IntervalUnit, kind: ScheduleKind, choreDays: String) -> String {
        guard snaps(kind: kind, value: value, unit: unit) else { return Weekdays.any }
        switch unit {
        case .year: return Weekdays.any
        case .month where value >= 3: return Weekdays.any
        default: return choreDays
        }
    }

    /// Next fixed date after a completion on `done`, given the date that was due. A completion counts
    /// for the calendar date nearest to it, so doing the job a bit early or late doesn't skip or repeat a date.
    static func fixedDue(after done: Date, current due: Date, value: Int, unit: IntervalUnit,
                         calendar cal: Calendar = .current) -> Date {
        let day = cal.startOfDay(for: done)
        func date(_ k: Int) -> Date {
            cal.date(byAdding: unit.component, value: k * max(1, value), to: due) ?? due
        }
        var k = 0
        while date(k + 1) <= day, k < 10_000 { k += 1 }
        while date(k) > day, k > -10_000 { k -= 1 }
        // date(k) <= day < date(k + 1); pick the closer one.
        let covered = day.timeIntervalSince(date(k)) <= date(k + 1).timeIntervalSince(day) ? k : k + 1
        return covered < 0 ? due : date(covered + 1)
    }
}

/// Where a task belongs in Up Next's By Date list. The list is this week's work and nothing
/// else: anything further out lives in the calendar, the rooms and the items. A task ticked off
/// drops to `done` — it isn't due again this week, but it shouldn't just vanish either.
enum UpNextBucket: Equatable {
    case overdue, today, thisWeek, done, hidden

    /// The local calendar week containing `now`, starting on the locale's first weekday.
    static func weekStart(_ now: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    }

    /// `lastCompletedAt` is the newest ticked-off completion (a log), not "last done": a date
    /// entered as "I just did these" moves the schedule but isn't something anyone ticked off.
    static func of(due: Date, lastCompletedAt: Date?, isActive: Bool, now: Date,
                   calendar: Calendar = .current) -> UpNextBucket {
        let start = weekStart(now, calendar: calendar)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        let doneThisWeek = (lastCompletedAt ?? .distantPast) >= start
        // A paused task, or a one-off that switched itself off, is only here as today's receipt.
        guard isActive else { return doneThisWeek ? .done : .hidden }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: due)
        // Still actionable today, whatever was ticked off earlier.
        if day < today { return .overdue }
        if day == today { return .today }
        // Done this week and nothing more to do about it now — even a daily chore that comes
        // round again on Friday is finished as far as today is concerned.
        if doneThisWeek { return .done }
        return day < end ? .thisWeek : .hidden
    }
}

enum DueStatus: Comparable {
    case overdue(days: Int)
    case today
    case soon(days: Int)
    case later(days: Int)

    init(for due: Date, now: Date = Date()) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: due)).day ?? 0
        switch days {
        case ..<0: self = .overdue(days: -days)
        case 0: self = .today
        case 1...7: self = .soon(days: days)
        default: self = .later(days: days)
        }
    }

    var text: String {
        switch self {
        case .overdue(1): "1 day overdue"
        case .overdue(let d) where d >= 14: "\(d / 7) weeks overdue"
        case .overdue(let d): "\(d) days overdue"
        case .today: "Due today"
        case .soon(1): "Due tomorrow"
        case .soon(let d): "Due in \(d) days"
        case .later(let d) where d < 14: "In \(d) days"
        case .later(let d) where d < 60: "In \(d / 7) weeks"
        case .later(let d) where d < 700: "In \(d / 30) months"
        case .later(let d): "In \(d / 365) years"
        }
    }

    var isDue: Bool {
        switch self {
        case .overdue, .today: true
        default: false
        }
    }
}
