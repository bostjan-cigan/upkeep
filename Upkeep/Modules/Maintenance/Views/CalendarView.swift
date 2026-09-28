import SwiftData
import SwiftUI

/// A task landing on a calendar day. Only the first occurrence is real; later ones are where the
/// task would fall if each one gets done on time.
struct CalendarOccurrence: Identifiable {
    let task: MaintenanceTask
    let day: Date
    let isProjected: Bool
    /// Overdue tasks are shown on today, since that's when they need doing.
    let isOverdue: Bool
    /// Who it's for: a one-off hand-over only covers the real occurrence, and repeats go to the usual person.
    var assigneeUid: String { isProjected ? task.assigneeUid : task.currentAssigneeUid }

    var id: String { "\(task.uid)-\(day.timeIntervalSinceReferenceDate)" }

    /// Occurrences of `tasks` on days in `range` (start-of-day dates).
    static func all(for tasks: [MaintenanceTask], in range: Range<Date>, now: Date = Date()) -> [Date: [CalendarOccurrence]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var result: [Date: [CalendarOccurrence]] = [:]

        for task in tasks where task.isActive {
            let due = cal.startOfDay(for: task.nextDueAt)
            let first = max(due, today)
            if range.contains(first) {
                result[first, default: []].append(CalendarOccurrence(task: task, day: first, isProjected: false, isOverdue: due < today))
            }
            guard !task.isFixedDate || task.repeats else { continue }

            // Fixed dates keep their own series; interval tasks restart from the day they get done.
            let base = task.isFixedDate ? due : first
            let step = max(1, task.intervalValue)
            for k in 1...1_000 {
                guard let day = cal.date(byAdding: task.intervalUnit.component, value: k * step, to: base) else { break }
                if day >= range.upperBound { break }
                guard day > first, range.contains(day) else { continue }
                result[day, default: []].append(CalendarOccurrence(task: task, day: day, isProjected: true, isOverdue: false))
            }
        }
        for key in result.keys {
            result[key]?.sort { a, b in
                if a.isProjected != b.isProjected { return !a.isProjected }
                return a.task.title.localizedStandardCompare(b.task.title) == .orderedAscending
            }
        }
        return result
    }
}

/// Month grid of upcoming tasks with item icons on each day; clicking a day lists its tasks.
struct TaskCalendarView: View {
    let tasks: [MaintenanceTask]
    /// Only occurrences that are mine, judged one at a time since a hand-over covers just the next one.
    var mineOnly = false
    var onEdit: ((MaintenanceTask) -> Void)?

    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDay = Calendar.current.startOfDay(for: Date())

    private var cal: Calendar { Calendar.current }

    var body: some View {
        let days = gridDays
        let all = CalendarOccurrence.all(for: tasks, in: (days.first ?? month)..<(cal.date(byAdding: .day, value: 1, to: days.last ?? month) ?? month))
        let occurrences = mineOnly ? all.mapValues { $0.filter { MaintenanceTask.isMine($0.assigneeUid) } } : all

        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 10) {
                header
                weekdayRow
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        DayCell(day: day,
                                occurrences: occurrences[day] ?? [],
                                isInMonth: cal.isDate(day, equalTo: month, toGranularity: .month),
                                isToday: cal.isDateInToday(day),
                                isSelected: day == selectedDay)
                            .onTapGesture { select(day) }
                    }
                }
            }
            .padding(14)
            .background(.quinary, in: RoundedRectangle(cornerRadius: Card<EmptyView>.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Card<EmptyView>.cornerRadius, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5)
            }

            dayDetails(occurrences[selectedDay] ?? [])
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .font(.title3.weight(.semibold))
            Spacer()
            Button("Today") {
                withAnimation(.snappy) { select(cal.startOfDay(for: Date())) }
            }
            .disabled(cal.isDate(month, equalTo: Date(), toGranularity: .month) && cal.isDateInToday(selectedDay))
            ControlGroup {
                Button("Previous Month", systemImage: "chevron.left") { shiftMonth(-1) }
                Button("Next Month", systemImage: "chevron.right") { shiftMonth(1) }
            }
            .labelStyle(.iconOnly)
            .fixedSize()
        }
    }

    private var weekdayRow: some View {
        let symbols = cal.shortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 4) {
            ForEach(ordered, id: \.self) { symbol in
                Text(symbol.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Details

    private func dayDetails(_ list: [CalendarOccurrence]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: dayTitle) {
                if !list.isEmpty {
                    Text("\(list.count) \(list.count == 1 ? "task" : "tasks")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Card {
                if list.isEmpty {
                    Text(selectedDay < cal.startOfDay(for: Date()) ? "This day has passed." : "Nothing due this day.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, occurrence in
                        if index > 0 { Divider() }
                        if occurrence.isProjected {
                            ProjectedTaskRow(occurrence: occurrence, onEdit: onEdit)
                        } else {
                            TaskRow(task: occurrence.task, showsItem: true, onEdit: onEdit)
                        }
                    }
                }
            }
        }
    }

    private var dayTitle: String {
        if cal.isDateInToday(selectedDay) { return "Today" }
        if cal.isDateInTomorrow(selectedDay) { return "Tomorrow" }
        return selectedDay.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    // MARK: Dates

    /// Whole weeks covering the visible month.
    private var gridDays: [Date] {
        guard let interval = cal.dateInterval(of: .month, for: month),
              let firstWeek = cal.dateInterval(of: .weekOfYear, for: interval.start),
              let lastDay = cal.date(byAdding: .day, value: -1, to: interval.end),
              let lastWeek = cal.dateInterval(of: .weekOfYear, for: lastDay) else { return [] }
        var days: [Date] = []
        var day = firstWeek.start
        while day < lastWeek.end {
            days.append(day)
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }

    private func shiftMonth(_ delta: Int) {
        guard let new = cal.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.snappy) {
            month = new
            // Keep the selection inside the visible month: today if it's there, else the 1st.
            selectedDay = cal.isDate(Date(), equalTo: new, toGranularity: .month) ? cal.startOfDay(for: Date()) : new
        }
    }

    private func select(_ day: Date) {
        selectedDay = day
        if let start = cal.dateInterval(of: .month, for: day)?.start, start != month { month = start }
    }
}

/// One day in the month grid: the date and an icon per task due.
private struct DayCell: View {
    let day: Date
    let occurrences: [CalendarOccurrence]
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool

    private static let maxIcons = 6
    private static let iconSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isToday ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(isToday ? AnyShapeStyle(.white) : isInMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 22, minHeight: 22)
                .background { if isToday { Circle().fill(.tint) } }
            icons
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.tint, lineWidth: 2)
            }
        }
        .opacity(isInMonth ? 1 : 0.55)
        .contentShape(Rectangle())
        .help(occurrences.map { "\($0.task.item?.name ?? "") · \($0.task.title)" }.joined(separator: "\n"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(occurrences.count) tasks")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var icons: some View {
        let overflow = occurrences.count > Self.maxIcons
        let shown = overflow ? Array(occurrences.prefix(Self.maxIcons - 1)) : occurrences
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.iconSize), spacing: 3), count: 3),
                         alignment: .leading, spacing: 3) {
            ForEach(shown) { occurrence in
                ItemIconView(icon: occurrence.task.item?.icon ?? .generic,
                             color: occurrence.task.item?.color ?? .gray,
                             size: Self.iconSize)
                    .opacity(occurrence.isProjected ? 0.45 : 1)
                    .overlay(alignment: .topTrailing) {
                        if occurrence.isOverdue {
                            Circle().fill(.red).frame(width: 6, height: 6).offset(x: 2, y: -2)
                        }
                    }
            }
            if overflow {
                Text("+\(occurrences.count - shown.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.iconSize, height: Self.iconSize)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Self.iconSize * 0.225, style: .continuous))
            }
        }
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint.opacity(0.12)) }
        return occurrences.isEmpty ? AnyShapeStyle(.clear) : AnyShapeStyle(.background.opacity(0.6))
    }
}

/// A future repeat of a task: informational only, since it can't be done before the current one.
private struct ProjectedTaskRow: View {
    let occurrence: CalendarOccurrence
    var onEdit: ((MaintenanceTask) -> Void)?

    var body: some View {
        let task = occurrence.task
        HStack(spacing: 12) {
            if let item = task.item {
                ItemIconView(item: item, size: 36).opacity(0.6)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text([task.item?.name, task.intervalDescription].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Label("Repeat", systemImage: "arrow.trianglehead.2.clockwise")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(task.isFixedDate
                      ? "Next date in this task's schedule"
                      : "Expected date if the previous one is done on time")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if let onEdit {
                Button("Edit Task…", systemImage: "pencil") { onEdit(task) }
            }
        }
    }
}
