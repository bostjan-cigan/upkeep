import AppKit
import SwiftData
import SwiftUI

// MARK: Icons

@MainActor
enum IconLibrary {
    private static var cache: [IconKey: NSImage] = [:]

    static func image(for key: IconKey) -> NSImage {
        if let cached = cache[key] { return cached }
        let url = Bundle.main.url(forResource: key.rawValue, withExtension: "svg")
            ?? Bundle.main.url(forResource: key.rawValue, withExtension: "svg", subdirectory: "Icons")
        let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage(systemSymbolName: "house.fill", accessibilityDescription: nil)!
        cache[key] = image
        return image
    }
}

/// App-icon style tile: colored gradient squircle with a white SVG glyph.
struct ItemIconView: View {
    let icon: IconKey
    let color: TileColor
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(color.gradient)
            .overlay {
                Image(nsImage: IconLibrary.image(for: icon))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.13)
            }
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 80))
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(size > 60 ? 0.18 : 0.12), radius: size * 0.06, y: size * 0.03)
            .accessibilityHidden(true)
    }
}

extension ItemIconView {
    init(item: HomeItem, size: CGFloat = 40) {
        self.init(icon: item.icon, color: item.color, size: size)
    }
}

// MARK: Status

extension DueStatus {
    var tint: Color {
        switch self {
        case .overdue: .red
        case .today: .orange
        case .soon: .secondary
        case .later: .secondary
        }
    }
}

// MARK: Task row

/// A single chore with a big friendly "done" button.
struct TaskRow: View {
    @Environment(\.modelContext) private var context
    let task: MaintenanceTask
    var showsItem = false
    var compact = false
    /// A receipt for something already done this week: struck through, with Undo instead of Done.
    var isDone = false
    var onEdit: ((MaintenanceTask) -> Void)?

    @State private var justCompleted = false
    @State private var confirmingDelete = false
    @State private var moving = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            if showsItem, let item = task.item {
                ItemIconView(item: item, size: compact ? 28 : 36)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(compact ? .callout.weight(.medium) : .body.weight(.medium))
                    .strikethrough(justCompleted || isDone, color: .secondary)
                    .foregroundStyle(isDone ? .secondary : .primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let assignee {
                PersonBadge(person: assignee, size: compact ? 16 : 20)
                    .help(assigneeHelp)
            } else if task.isHandedOver {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
                    .help(assigneeHelp)
            }
            statusLabel
            if isDone {
                Button("Undo") { undo() }
                    .buttonStyle(.borderless)
                    .help("Take this back off the list — the history entry goes too")
            } else {
                Button(action: complete) {
                    Image(systemName: justCompleted ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(compact ? .title3 : .title2)
                        .foregroundStyle(justCompleted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .help("Mark as done")
                .disabled(justCompleted)
            }
        }
        .padding(.vertical, compact ? 4 : 6)
        .contentShape(Rectangle())
        .contextMenu {
            TaskMenuItems(task: task, onEdit: onEdit, onMove: { moving = true }) { confirmingDelete = true }
        }
        .confirmDeletion(of: task, isPresented: $confirmingDelete)
        .sheet(isPresented: $moving) { MoveOccurrenceSheet(task: task) }
    }

    @Query private var people: [Person]

    /// Whoever has the occurrence that's due next, which a hand-over may have changed.
    private var assignee: Person? {
        let uid = task.currentAssigneeUid
        return uid.isEmpty ? nil : people.first { $0.uid == uid }
    }

    /// "Assigned to Ana", or "Ana this time, usually Bo".
    private var assigneeHelp: String {
        let name = assignee?.name ?? "Everyone"
        guard task.isHandedOver else { return "Assigned to \(name)" }
        let usual = people.first { $0.uid == task.assigneeUid }?.name ?? "everyone"
        return "\(name) this time, usually \(usual)"
    }

    private var subtitle: String {
        if showsItem, let item = task.item { return "\(item.name) · \(task.intervalDescription)" }
        return task.intervalDescription
    }

    /// "Done today by Ana" — who cleared it, and when.
    private var doneText: String {
        guard let at = task.lastCompletedAt else { return "Done" }
        let cal = Calendar.current
        let when = cal.isDateInToday(at) ? "today"
            : cal.isDateInYesterday(at) ? "yesterday"
            : at.formatted(.dateTime.weekday(.wide))
        let log = (task.logs ?? []).max { $0.completedAt < $1.completedAt }
        let who = people.first { $0.uid == log?.completedByUid }
        return who.map { "Done \(when) by \($0.name)" } ?? "Done \(when)"
    }

    @ViewBuilder private var statusLabel: some View {
        if isDone {
            Text(doneText)
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
        } else if task.isSnoozed, let until = task.snoozedUntil {
            Label("Until \(until.formatted(.dateTime.weekday(.abbreviated)))", systemImage: "moon.zzz.fill")
                .font(compact ? .caption : .callout)
                .foregroundStyle(.secondary)
                .help("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
        } else {
            Text(task.status.text)
                .font(compact ? .caption : .callout)
                .foregroundStyle(task.status.tint)
                .monospacedDigit()
        }
    }

    /// Removes the newest completion, putting the task back where it was.
    private func undo() {
        guard let log = (task.logs ?? []).max(by: { $0.completedAt < $1.completedAt }) else { return }
        withAnimation(.snappy) {
            task.refreshFromLogs(excluding: log)
            SyncStore.delete(log, in: context)
            try? context.save()
        }
    }

    private func complete() {
        withAnimation(.snappy) { justCompleted = true }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.snappy) {
                task.markDone(in: context)
                try? context.save()
                justCompleted = false
            }
        }
    }
}

struct TaskMenuItems: View {
    @Environment(\.modelContext) private var context
    let task: MaintenanceTask
    var onEdit: ((MaintenanceTask) -> Void)?
    var onMove: (() -> Void)?
    var onDelete: () -> Void

    var body: some View {
        Button("Mark as Done", systemImage: "checkmark.circle") {
            task.markDone(in: context)
            try? context.save()
        }
        if let onMove {
            Button("Move…", systemImage: "calendar.badge.clock", action: onMove)
        }
        AssignMenu(task: task)
        Menu("Snooze") {
            ForEach([1, 3, 7], id: \.self) { days in
                Button(days == 1 ? "1 Day" : days == 7 ? "1 Week" : "\(days) Days") {
                    task.snoozedUntil = Calendar.current.date(byAdding: .day, value: days, to: Date())
                    try? context.save()
                }
            }
            if task.isSnoozed {
                Divider()
                Button("Stop Snoozing") {
                    task.snoozedUntil = nil
                    try? context.save()
                }
            }
        }
        if let onEdit {
            Divider()
            Button("Edit Task…", systemImage: "pencil") { onEdit(task) }
        }
        Button("Pause Task", systemImage: "pause.circle") {
            task.isActive = false
            try? context.save()
        }
        Divider()
        Button("Delete Task…", systemImage: "trash", role: .destructive, action: onDelete)
    }
}

extension View {
    /// Asks before deleting a task, since its history goes with it. `onFinished` runs after delete or pause.
    func confirmDeletion(of task: MaintenanceTask, isPresented: Binding<Bool>, onFinished: (() -> Void)? = nil) -> some View {
        modifier(DeleteTaskConfirmation(task: task, isPresented: isPresented, onFinished: onFinished))
    }
}

private struct DeleteTaskConfirmation: ViewModifier {
    @Environment(\.modelContext) private var context
    let task: MaintenanceTask
    @Binding var isPresented: Bool
    var onFinished: (() -> Void)?

    func body(content: Content) -> some View {
        content.confirmationDialog("Delete “\(task.title)”?", isPresented: $isPresented) {
            Button("Delete Task", role: .destructive) {
                SyncStore.delete(task, in: context)
                onFinished?()
            }
            if task.isActive {
                Button("Pause Instead") {
                    task.isActive = false
                    try? context.save()
                    onFinished?()
                }
            }
        } message: {
            let count = task.logs?.count ?? 0
            Text(count == 0 ? "This removes the task for everyone in the household."
                 : "This also removes its \(count) history \(count == 1 ? "entry" : "entries"). Pause it instead to keep the history.")
        }
    }
}

// MARK: Layout helpers

/// Toolbar button that opens the Add Item sheet.
struct AddItemButton: View {
    var body: some View {
        Button("Add Item", systemImage: "plus") { AppState.shared.showingAddItem = true }
            .help("Add something to look after")
    }
}

/// Grouped-form style card, like the sections in System Settings.
struct Card<Content: View>: View {
    /// Matches grouped `Form` sections on macOS 26, nested inside the window's rounder corners.
    static var cornerRadius: CGFloat { 12 }

    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quinary, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5)
            }
    }
}

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Picks a tile color.
struct ColorSwatchPicker: View {
    @Binding var selection: TileColor

    var body: some View {
        HStack(spacing: 8) {
            ForEach(TileColor.allCases) { color in
                Button { selection = color } label: {
                    Circle()
                        .fill(color.gradient)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if selection == color {
                                Circle().strokeBorder(.white, lineWidth: 2).padding(3)
                            }
                        }
                        .overlay { Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5) }
                }
                .buttonStyle(.plain)
                .help(color.rawValue.capitalized)
                .accessibilityLabel(color.rawValue.capitalized)
            }
        }
    }
}

/// Grid of all glyphs, previewed in the chosen color.
struct IconGridPicker: View {
    @Binding var selection: IconKey
    let color: TileColor

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
            ForEach(IconKey.allCases) { key in
                Button { selection = key } label: {
                    ItemIconView(icon: key, color: selection == key ? color : .gray, size: 38)
                        .opacity(selection == key ? 1 : 0.55)
                        .scaleEffect(selection == key ? 1.08 : 1)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.rawValue)
            }
        }
        .animation(.snappy, value: selection)
    }
}

/// A schedule chosen before its task exists, starting from a suggestion's default.
/// When an after-last-done task's clock starts, as the task editor asks it.
enum StartMode: String, CaseIterable, Identifiable {
    /// It has been done before, so the next one follows that.
    case lastDone
    /// It hasn't, and the first one belongs on a day the user picked.
    case firstDue
    /// It hasn't, and it should come round as soon as it can.
    case soon
    var id: String { rawValue }
}

struct DraftSchedule: Equatable {
    var kind: ScheduleKind = .interval
    var value = 1
    var unit: IntervalUnit = .month
    var date = Calendar.current.startOfDay(for: Date())
    var repeats = true
    /// The days of the week this should land on, as `Weekdays` digits. Empty means any day.
    var preferredDays = Weekdays.any

    init(value: Int, unit: IntervalUnit, choreDays: String = Weekdays.any) {
        self.value = value
        self.unit = unit
        preferredDays = Schedule.suggestedDays(value: value, unit: unit, kind: kind, choreDays: choreDays)
    }

    @MainActor init(_ suggestion: TaskSuggestion) {
        self.init(value: suggestion.value, unit: suggestion.unit, choreDays: Household.shared.myChoreDays)
    }

    /// An existing task's schedule, dated like the task editor: the next due date, or a finished one-off's date.
    init(_ task: MaintenanceTask) {
        self.init(value: task.intervalValue, unit: task.intervalUnit)
        kind = task.isFixedDate ? .fixedDate : .interval
        date = Calendar.current.startOfDay(for: task.isFinished ? (task.anchorDate ?? task.nextDueAt) : task.nextDueAt)
        repeats = task.repeats
        preferredDays = task.preferredDays
    }

    var text: String {
        MaintenanceTask.describe(value: value, unit: unit, fixedDate: kind == .fixedDate ? date : nil,
                                 repeats: repeats, preferredDays: preferredDays)
    }

    /// Whether a preferred day means anything here, so the picker can hide when it doesn't.
    var honoursPreferredDays: Bool { Schedule.snaps(kind: kind, value: value, unit: unit) }

    /// The days this schedule would pick on its own, used to follow the interval until it's overridden.
    @MainActor var suggestedDays: String {
        Schedule.suggestedDays(value: value, unit: unit, kind: kind, choreDays: Household.shared.myChoreDays)
    }

    /// `lastDone` only applies to after-last-done schedules; fixed dates are due on their date.
    func makeTask(_ title: String, lastDone: Date?) -> MaintenanceTask {
        let task = MaintenanceTask(title: title, every: value, unit, lastDone: kind == .interval ? lastDone : nil)
        task.preferredDays = preferredDays
        if kind == .fixedDate { task.setFixedDate(date, repeats: repeats) } else { task.refreshDerived() }
        return task
    }

    /// Reschedules an existing task, keeping its history, the same way saving the task editor does.
    func apply(to task: MaintenanceTask) {
        let wasFinished = task.isFinished
        task.intervalValue = max(1, value)
        task.intervalUnit = unit
        // A done one-off that gets a new date or a repeating schedule is due again.
        if wasFinished && (kind != .fixedDate || repeats || task.anchorDate != date) { task.isActive = true }
        // Rescheduling replaces whatever a one-off move had done to the next occurrence.
        task.clearShift()
        task.preferredDays = preferredDays
        if kind == .fixedDate {
            task.setFixedDate(date, repeats: repeats)
        } else {
            task.scheduleKind = .interval
            task.refreshDerived()
        }
    }
}

/// Shows a schedule as text; clicking it edits the schedule in a popover.
struct ScheduleButton: View {
    @Binding var schedule: DraftSchedule
    /// The catalog default, if any: a changed schedule stands out and can be reset to it.
    var suggested: DraftSchedule? = nil
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            HStack(spacing: 3) {
                Text(schedule.text)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .foregroundStyle(suggested.map { $0 != schedule } ?? false ? .primary : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Change when this repeats")
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Schedule", selection: $schedule.kind) {
                    Text("After last done").tag(ScheduleKind.interval)
                    Text("On a date").tag(ScheduleKind.fixedDate)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if schedule.kind == .interval {
                    IntervalPicker(value: $schedule.value, unit: $schedule.unit)
                } else {
                    DatePicker("Due on", selection: $schedule.date, displayedComponents: .date)
                    Toggle("Repeats", isOn: $schedule.repeats)
                    if schedule.repeats {
                        IntervalPicker(value: $schedule.value, unit: $schedule.unit)
                    }
                }
                if schedule.honoursPreferredDays {
                    HStack {
                        Text("Do it on")
                        Spacer()
                        WeekdayPicker(selection: $schedule.preferredDays)
                    }
                }
                HStack {
                    Text(schedule.text).foregroundStyle(.secondary)
                    Spacer()
                    if let suggested, schedule != suggested {
                        Button("Use Suggested") { schedule = suggested }
                    }
                }
                .font(.callout)
            }
            .padding(16)
            .frame(width: 340)
            .onChange(of: schedule.kind) { _, _ in followSuggestedDays() }
            .onChange(of: schedule.value) { _, _ in followSuggestedDays() }
            .onChange(of: schedule.unit) { _, _ in followSuggestedDays() }
        }
    }

    /// Days never chosen by hand keep following the interval, so a yearly service doesn't get
    /// dragged onto Saturdays just because the monthly chores are.
    private func followSuggestedDays() {
        let choreDays = Household.shared.myChoreDays
        guard schedule.preferredDays == choreDays || schedule.preferredDays == Weekdays.any else { return }
        schedule.preferredDays = schedule.suggestedDays
    }
}

/// Stepper + unit picker for "every N weeks".
struct IntervalPicker: View {
    @Binding var value: Int
    @Binding var unit: IntervalUnit

    var body: some View {
        HStack {
            Text("Repeat every")
            Spacer()
            TextField("", value: $value, format: .number)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
            Stepper("", value: $value, in: 1...365).labelsHidden()
            Picker("", selection: $unit) {
                ForEach(IntervalUnit.allCases) { u in Text(u.label(value)).tag(u) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .onChange(of: value) { _, new in if new < 1 { value = 1 } }
    }
}
