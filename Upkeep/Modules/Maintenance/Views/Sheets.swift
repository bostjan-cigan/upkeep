import AppKit
import SwiftData
import SwiftUI

// MARK: Add item

/// Two steps: pick what it is, then confirm name, look and suggested routine.
struct AddItemSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    var onCreated: (HomeItem) -> Void

    @State private var template: ItemTemplate?
    @State private var name = ""
    @State private var icon: IconKey = .generic
    @State private var color: TileColor = .blue
    @State private var room = ""
    @State private var chosen: Set<UUID> = []
    /// Schedules the user changed from the suggested one, by suggestion.
    @State private var schedules: [UUID: DraftSchedule] = [:]
    /// Responsible person by suggestion; missing means everyone.
    @State private var assignees: [UUID: String] = [:]
    @State private var custom: [TaskSuggestion] = []
    @State private var newTaskTitle = ""
    @State private var newTaskValue = 1
    @State private var newTaskUnit: IntervalUnit = .month
    @State private var startFresh = true
    @State private var search = ""

    var body: some View {
        Group {
            if let template {
                details(template)
            } else {
                picker
            }
        }
        .frame(width: 620, height: 680)
        .toolbar { footer }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("What would you like to look after?")
                        .font(.title2.weight(.semibold))
                    Spacer()
                }
                SearchField(text: $search, prompt: "Search, e.g. robot vacuum")

                ForEach(TemplateCategory.allCases) { category in
                    let templates = filtered(category)
                    if !templates.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(category.rawValue)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 12) {
                                ForEach(templates) { t in templateButton(t) }
                            }
                        }
                    }
                }
                if TemplateCategory.allCases.allSatisfy({ filtered($0).isEmpty }) {
                    VStack(spacing: 10) {
                        Text("Nothing called “\(search)” yet.").foregroundStyle(.secondary)
                        Button("Add “\(search)” as a custom item") {
                            if let custom = ItemTemplate.all.first(where: { $0.id == "custom" }) {
                                choose(custom)
                                name = search
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                }
            }
            .padding(24)
        }
    }

    private func filtered(_ category: TemplateCategory) -> [ItemTemplate] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let list = ItemTemplate.inCategory(category)
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.suggestions.contains { $0.title.localizedCaseInsensitiveContains(query) }
        }
    }

    private func templateButton(_ t: ItemTemplate) -> some View {
        Button { choose(t) } label: {
            VStack(spacing: 7) {
                ItemIconView(icon: t.icon, color: t.color, size: 58)
                Text(t.name)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
    }

    private func details(_ t: ItemTemplate) -> some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ItemIconView(icon: icon, color: color, size: 72)
                    TextField("Name", text: $name, prompt: Text("e.g. Kitchen Dishwasher"))
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                }
                .padding(.vertical, 4)
                RoomField(room: $room)
                ColorSwatchPicker(selection: $color)
                DisclosureGroup("Icon") {
                    IconGridPicker(selection: $icon, color: color).padding(.vertical, 6)
                }
            }

            Section {
                ForEach(t.suggestions + custom) { s in
                    HStack {
                        Text(s.title)
                        Spacer()
                        ScheduleButton(schedule: schedule(for: s), suggested: DraftSchedule(s))
                            .disabled(!chosen.contains(s.id))
                        AssigneeButton(uid: Binding(get: { assignees[s.id] ?? "" }, set: { assignees[s.id] = $0 }))
                            .disabled(!chosen.contains(s.id))
                        Toggle(s.title, isOn: Binding(get: { chosen.contains(s.id) },
                                                      set: { if $0 { chosen.insert(s.id) } else { chosen.remove(s.id) } }))
                            .labelsHidden()
                    }
                }
            } header: {
                Text("Routine")
            } footer: {
                Text("Click a schedule to change how often it repeats, or a person to make them responsible. You can change or add tasks any time.")
                    .foregroundStyle(.secondary)
            }

            Section("Add your own task") {
                TextField("Task", text: $newTaskTitle, prompt: Text("e.g. Check the hoses"))
                    .onSubmit(addCustom)
                IntervalPicker(value: $newTaskValue, unit: $newTaskUnit)
                HStack {
                    Spacer()
                    Button("Add Task", action: addCustom)
                        .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section("Getting started") {
                Picker("", selection: $startFresh) {
                    Text("I just did these — start the clock today").tag(true)
                    Text(Weekdays.label(Household.shared.myChoreDays) == nil
                         ? "Not sure — remind me about them now"
                         : "Not sure — put them on my next chore day").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        }
        .formStyle(.grouped)
    }

    @ToolbarContentBuilder private var footer: some ToolbarContent {
        if template != nil {
            ToolbarItem(placement: .navigation) {
                Button("Back") { withAnimation(.snappy) { template = nil } }
            }
        }
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", role: .cancel) { dismiss() }
        }
        if template != nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add Item", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func choose(_ t: ItemTemplate) {
        withAnimation(.snappy) {
            template = t
            name = t.id == "custom" ? "" : t.name
            icon = t.icon
            color = t.color
            room = t.room
            chosen = Set(t.suggestions.map(\.id))
            schedules = [:]
            assignees = [:]
        }
    }

    private func schedule(for s: TaskSuggestion) -> Binding<DraftSchedule> {
        Binding(get: { schedules[s.id] ?? DraftSchedule(s) }, set: { schedules[s.id] = $0 })
    }

    private func addCustom() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        let s = TaskSuggestion(title, newTaskValue, newTaskUnit)
        custom.append(s)
        chosen.insert(s.id)
        newTaskTitle = ""
    }

    private func save() {
        guard let template else { return }
        let item = HomeItem(name: name.trimmingCharacters(in: .whitespaces), icon: icon, color: color,
                            room: room.trimmingCharacters(in: .whitespaces))
        context.insert(item)
        for s in (template.suggestions + custom) where chosen.contains(s.id) {
            let task = (schedules[s.id] ?? DraftSchedule(s)).makeTask(s.title, lastDone: startFresh ? Date() : nil)
            task.assigneeUid = assignees[s.id] ?? ""
            context.insert(task)
            task.item = item
        }
        try? context.save()
        onCreated(item)
        dismiss()
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverTile(isPressed: configuration.isPressed) { configuration.label }
    }
}

private struct HoverTile<Label: View>: View {
    let isPressed: Bool
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        label
            .background(.quaternary.opacity(hovering ? 0.6 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: isPressed)
            .onHover { hovering = $0 }
    }
}

/// The system search field, which follows the current OS look (Liquid Glass on macOS 26).
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        field.controlSize = .large
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            if let field = note.object as? NSSearchField { text.wrappedValue = field.stringValue }
        }
    }
}

// MARK: Edit item

struct ItemEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let item: HomeItem

    @State private var name = ""
    @State private var icon: IconKey = .generic
    @State private var color: TileColor = .blue
    @State private var notes = ""
    @State private var room = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    ItemIconView(icon: icon, color: color, size: 72)
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                }
                .padding(.vertical, 4)
                RoomField(room: $room)
                ColorSwatchPicker(selection: $color)
            }
            Section("Icon") {
                IconGridPicker(selection: $icon, color: color).padding(.vertical, 6)
            }
            Section("Notes") {
                TextField("Model number, filter type, where the manual is…", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                    .labelsHidden()
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    item.name = name.trimmingCharacters(in: .whitespaces)
                    item.iconKey = icon.rawValue
                    item.colorKey = color.rawValue
                    item.notes = notes
                    item.room = room.trimmingCharacters(in: .whitespaces)
                    try? context.save()
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            name = item.name
            icon = item.icon
            color = item.color
            notes = item.notes
            room = item.room
        }
    }
}

// MARK: Add / edit task

struct TaskEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let item: HomeItem?
    let task: MaintenanceTask?

    @Query(sort: \HomeItem.name) private var allItems: [HomeItem]
    @State private var chosenItemID: PersistentIdentifier?
    @State private var title = ""
    @State private var value = 1
    @State private var unit: IntervalUnit = .month
    @State private var kind: ScheduleKind = .interval
    @State private var fixedDate = Date()
    @State private var repeats = true
    @State private var startMode: StartMode = .lastDone
    @State private var lastDone = Date()
    @State private var startDate = Calendar.current.startOfDay(for: Date())
    @State private var preferredDays = Weekdays.any
    @State private var isActive = true
    @State private var assigneeUid = ""
    @State private var confirmingDelete = false
    @Query(sort: \Person.name) private var people: [Person]

    var body: some View {
        Form {
            Section {
                if item == nil {
                    Picker("For", selection: $chosenItemID) {
                        Text("Choose…").tag(PersistentIdentifier?.none)
                        ForEach(Rooms.grouped(allItems, by: \.room), id: \.room) { group in
                            Section(Rooms.title(group.room)) {
                                ForEach(group.values) { i in
                                    Text(i.name).tag(Optional(i.persistentModelID))
                                }
                            }
                        }
                    }
                }
                TextField("Task", text: $title, prompt: Text("e.g. Clean the filter"))
                if !people.isEmpty {
                    Picker("Responsible", selection: $assigneeUid) {
                        Text("Everyone").tag("")
                        ForEach(people) { p in Text(p.name).tag(p.uid) }
                    }
                }
                if task != nil {
                    Toggle("Active", isOn: $isActive)
                }
            }
            Section {
                Picker("Schedule", selection: $kind) {
                    Text("After last done").tag(ScheduleKind.interval)
                    Text("On a date").tag(ScheduleKind.fixedDate)
                }
                .pickerStyle(.segmented)
                if kind == .interval {
                    IntervalPicker(value: $value, unit: $unit)
                    Picker("Starts", selection: $startMode) {
                        Text("It was last done on…").tag(StartMode.lastDone)
                        Text("First due on…").tag(StartMode.firstDue)
                        Text("As soon as possible").tag(StartMode.soon)
                    }
                    switch startMode {
                    case .lastDone:
                        DatePicker("Last done", selection: $lastDone, in: ...Date(), displayedComponents: .date)
                    case .firstDue:
                        DatePicker("First due", selection: $startDate, displayedComponents: .date)
                    case .soon:
                        EmptyView()
                    }
                    if Schedule.snaps(kind: .interval, value: value, unit: unit) {
                        LabeledContent("Do it on") { WeekdayPicker(selection: $preferredDays) }
                    }
                } else {
                    DatePicker("Due on", selection: $fixedDate, displayedComponents: .date)
                    Toggle("Repeats", isOn: $repeats)
                    if repeats {
                        IntervalPicker(value: $value, unit: $unit)
                    }
                }
            } footer: {
                Text(nextDueText).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: (item == nil ? 510 : 470) + (task == nil ? 0 : 30) + (people.isEmpty ? 0 : 30))
        .toolbar {
            if let task {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete Task…", role: .destructive) { confirmingDelete = true }
                        .confirmDeletion(of: task, isPresented: $confirmingDelete) { dismiss() }
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(task == nil ? "Add Task" : "Save", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || targetItem == nil)
            }
        }
        .onAppear {
            guard let task else {
                preferredDays = Schedule.suggestedDays(value: value, unit: unit, kind: kind,
                                                       choreDays: Household.shared.myChoreDays)
                return
            }
            title = task.title
            value = task.intervalValue
            unit = task.intervalUnit
            kind = task.isFixedDate ? .fixedDate : .interval
            fixedDate = task.isFinished ? (task.anchorDate ?? task.nextDueAt) : task.nextDueAt
            repeats = task.repeats
            if task.lastDoneAt != nil {
                startMode = .lastDone
            } else {
                startMode = task.isFixedDate ? .soon : (task.anchorDate == nil ? .soon : .firstDue)
            }
            lastDone = task.lastDoneAt ?? Date()
            startDate = Calendar.current.startOfDay(for: task.isFixedDate ? task.nextDueAt : (task.anchorDate ?? task.nextDueAt))
            preferredDays = task.preferredDays
            isActive = task.isActive
            assigneeUid = Household.shared.personExists(task.assigneeUid) ? task.assigneeUid : ""
        }
        .onChange(of: kind) { _, new in
            // Dates recur yearly far more often than monthly, so start from there.
            if new == .fixedDate, task?.isFixedDate != true, value == 1 { unit = .year }
            followSuggestedDays()
        }
        .onChange(of: value) { _, _ in followSuggestedDays() }
        .onChange(of: unit) { _, _ in followSuggestedDays() }
    }

    /// A day that was never chosen by hand keeps following the interval: a monthly chore lands on
    /// the household's chore days, a yearly service on whatever date it falls.
    private func followSuggestedDays() {
        let choreDays = Household.shared.myChoreDays
        let wasSuggested = preferredDays == choreDays || preferredDays == Weekdays.any
        guard wasSuggested else { return }
        preferredDays = Schedule.suggestedDays(value: max(1, value), unit: unit, kind: kind, choreDays: choreDays)
    }

    private var targetItem: HomeItem? {
        item ?? allItems.first { $0.persistentModelID == chosenItemID }
    }

    private var nextDueText: String {
        if kind == .fixedDate {
            let date = fixedDate.formatted(date: .long, time: .omitted)
            guard repeats else { return "Due on \(date), once." }
            let every = value == 1 ? "every \(unit.rawValue)" : "every \(value) \(unit.label(value))"
            return "Due on \(date), then \(every) from that date, however early or late it gets done."
        }
        // Exactly what saving would compute, so the preview can't disagree with the task.
        let (_, next) = Schedule.derive(kind: .interval, anchorDate: startMode == .firstDue ? startDate : nil,
                                        repeats: true, value: max(1, value), unit: unit,
                                        baselineDoneAt: startMode == .lastDone ? lastDone : nil,
                                        completions: [], preferredDays: preferredDays)
        let date = next.formatted(date: .long, time: .omitted)
        guard let days = Weekdays.label(preferredDays), Schedule.snaps(kind: .interval, value: value, unit: unit) else {
            return "Next due \(date)."
        }
        return "Next due \(date), then on \(days)."
    }

    private func save() {
        let target: MaintenanceTask
        if let task {
            target = task
        } else {
            target = MaintenanceTask(title: "", every: value, unit, lastDone: nil)
            context.insert(target)
            target.item = targetItem
        }
        let wasFinished = target.isFinished
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.intervalValue = max(1, value)
        target.intervalUnit = unit
        target.isActive = isActive
        target.assigneeUid = assigneeUid
        // A done one-off that gets a new date or a repeating schedule is due again.
        if wasFinished && (kind != .fixedDate || repeats || target.anchorDate != Calendar.current.startOfDay(for: fixedDate)) {
            target.isActive = true
        }
        // Rescheduling replaces whatever a one-off move had done to the next occurrence.
        target.clearShift()
        target.preferredDays = preferredDays
        if kind == .fixedDate {
            target.setFixedDate(fixedDate, repeats: repeats)
        } else {
            target.scheduleKind = .interval
            // "Last done" moves the baseline; logged completions still count.
            target.baselineDoneAt = startMode == .lastDone ? lastDone : nil
            // A start date only decides the first one, so it stops mattering once there's a history.
            target.anchorDate = startMode == .firstDue ? Calendar.current.startOfDay(for: startDate) : nil
            target.refreshDerived()
        }
        try? context.save()
        dismiss()
    }
}

// MARK: Move an occurrence

/// Moves a task's next occurrence, asking what the move applies to the way a calendar does.
struct MoveOccurrenceSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let task: MaintenanceTask

    @State private var date = Date()
    @State private var scope: MoveScope = .thisOnce

    var body: some View {
        Form {
            Section {
                LabeledContent("Currently due", value: task.nextDueAt.formatted(date: .long, time: .omitted))
                DatePicker("Move to", selection: $date, displayedComponents: .date)
            } header: {
                Text(task.title)
            }
            Section {
                if task.canMoveSeries {
                    Picker("", selection: $scope) {
                        Text("This time only").tag(MoveScope.thisOnce)
                        Text("This and all future times").tag(MoveScope.allFuture)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                } else {
                    Text("This time only").foregroundStyle(.secondary)
                }
            } footer: {
                Text(explanation).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Move", action: move).disabled(!hasMoved)
            }
        }
        .onAppear { date = task.nextDueAt }
    }

    private var hasMoved: Bool {
        let cal = Calendar.current
        return cal.startOfDay(for: date) != cal.startOfDay(for: task.nextDueAt)
    }

    private var explanation: String {
        guard task.canMoveSeries else {
            return "This one comes round \(task.intervalDescription.lowercased()) after it's done, so there's nothing lasting to move — only this one."
        }
        switch scope {
        case .thisOnce:
            return "Only this one moves. The one after it comes round as usual."
        case .allFuture:
            if task.isFixedDate && task.anchorDate != nil {
                return task.repeats ? "Every date in the series moves by the same number of days."
                                    : "This one-off moves to the new date."
            }
            let weekday = Calendar.current.weekdaySymbols[Calendar.current.component(.weekday, from: date) - 1]
            return task.movesByWeekday
                ? "Every one after this lands on \(weekday)s too."
                : "It starts from the new date."
        }
    }

    private func move() {
        task.move(to: date, scope: task.canMoveSeries ? scope : .thisOnce)
        try? context.save()
        dismiss()
    }
}

// MARK: Room field

/// Free text with a menu of existing and common rooms — a lightweight combo box.
struct RoomField: View {
    @Binding var room: String
    @Query private var items: [HomeItem]

    private var options: [String] {
        let existing = Set(items.map { $0.room.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return existing.union(Rooms.suggestions).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        HStack {
            TextField("Room", text: $room, prompt: Text("e.g. Kitchen — optional"))
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { room = option }
                }
                if !room.isEmpty {
                    Divider()
                    Button("No Room") { room = "" }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick a room")
        }
    }
}

// MARK: Manage routine

/// One place to switch tasks on or off, delete them, and add suggested or custom ones.
struct RoutineManagerSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let item: HomeItem

    @State private var taskToDelete: MaintenanceTask?
    @State private var newTitle = ""
    @State private var newValue = 1
    @State private var newUnit: IntervalUnit = .month
    @State private var newAssigneeUid = ""
    @State private var schedules: [UUID: DraftSchedule] = [:]
    @State private var assignees: [UUID: String] = [:]
    @Query(sort: \Person.name) private var people: [Person]

    private var allTasks: [MaintenanceTask] {
        (item.tasks ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ItemIconView(item: item, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Manage Routine").font(.headline)
                    Text(item.name).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)

            Form {
                Section {
                    if allTasks.isEmpty {
                        Text("No tasks yet.").foregroundStyle(.secondary)
                    }
                    ForEach(allTasks) { task in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                ScheduleButton(schedule: Binding(get: { DraftSchedule(task) }, set: { reschedule(task, $0) }))
                                    .font(.caption)
                            }
                            Spacer()
                            AssigneeButton(uid: Binding(get: { task.assigneeUid }, set: { assign(task, $0) }))
                            Toggle(task.title, isOn: Binding(get: { task.isActive }, set: { setActive(task, $0) }))
                                .toggleStyle(.switch)
                                .labelsHidden()
                            Button {
                                taskToDelete = task
                            } label: {
                                Image(systemName: "trash").foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete task")
                        }
                    }
                } header: {
                    Text("Tasks")
                } footer: {
                    Text("Click a schedule to change it, or a person to make them responsible. Switched-off tasks keep their history but won't remind you.")
                        .foregroundStyle(.secondary)
                }

                if !item.missingSuggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(item.missingSuggestions) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title)
                                    ScheduleButton(schedule: Binding(get: { schedules[s.id] ?? DraftSchedule(s) },
                                                                     set: { schedules[s.id] = $0 }),
                                                   suggested: DraftSchedule(s))
                                        .font(.caption)
                                }
                                Spacer()
                                AssigneeButton(uid: Binding(get: { assignees[s.id] ?? "" }, set: { assignees[s.id] = $0 }))
                                Button("Add", systemImage: "plus.circle.fill") {
                                    add(s.title, schedules[s.id] ?? DraftSchedule(s), assigneeUid: assignees[s.id] ?? "")
                                }
                                    .labelStyle(.iconOnly)
                                    .font(.title3)
                                    .buttonStyle(.borderless)
                                    .help("Add to routine")
                            }
                        }
                    }
                }

                Section("Custom task") {
                    TextField("Task", text: $newTitle, prompt: Text("e.g. Check the hoses"))
                        .onSubmit(addCustom)
                    IntervalPicker(value: $newValue, unit: $newUnit)
                    if !people.isEmpty {
                        Picker("Responsible", selection: $newAssigneeUid) {
                            Text("Everyone").tag("")
                            ForEach(people) { p in Text(p.name).tag(p.uid) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Add Task", action: addCustom)
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 500, height: 620)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Delete “\(taskToDelete?.title ?? "")”?",
                            isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } })) {
            Button("Delete Task", role: .destructive) {
                if let task = taskToDelete {
                    SyncStore.delete(task, in: context)
                }
                taskToDelete = nil
            }
        } message: {
            Text("Its history is deleted too. Switch it off instead to keep the history.")
        }
    }

    private func setActive(_ task: MaintenanceTask, _ active: Bool) {
        task.isActive = active
        try? context.save()
    }

    private func assign(_ task: MaintenanceTask, _ uid: String) {
        task.assigneeUid = uid
        try? context.save()
    }

    private func reschedule(_ task: MaintenanceTask, _ schedule: DraftSchedule) {
        schedule.apply(to: task)
        try? context.save()
    }

    /// New tasks start the clock today, like tasks added with a new item.
    private func add(_ title: String, _ schedule: DraftSchedule, assigneeUid: String) {
        let task = schedule.makeTask(title, lastDone: Date())
        task.assigneeUid = assigneeUid
        context.insert(task)
        task.item = item
        try? context.save()
    }

    private func addCustom() {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        add(title, DraftSchedule(value: newValue, unit: newUnit, choreDays: Household.shared.myChoreDays),
            assigneeUid: newAssigneeUid)
        newTitle = ""
    }
}
