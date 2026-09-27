import SwiftData
import SwiftUI

/// Everything across the home, grouped by when it's due or by room.
struct UpNextView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case date = "By Date"
        case room = "By Room"
        case calendar = "Calendar"
        var id: String { rawValue }
    }

    /// Paused and finished tasks come along too: they may still be this week's "done" receipts.
    @Query(sort: \MaintenanceTask.nextDueAt) private var allTasks: [MaintenanceTask]
    @Query private var items: [HomeItem]
    @Query private var people: [Person]
    @AppStorage("upNextScope") private var scope: TaskScope = .mine

    private var isMineOnly: Bool { scope == .mine && !people.isEmpty }

    /// Mine (assigned to me or everyone) or the whole household's.
    private var tasks: [MaintenanceTask] {
        let mine = isMineOnly ? allTasks.filter(\.isMine) : allTasks
        return mode == .date ? mine : mine.filter(\.isActive)
    }
    @State private var editingTask: MaintenanceTask?
    @State private var addingTask = false
    @AppStorage("upNextMode") private var mode: Mode = .date
    /// Section keys the user collapsed.
    @AppStorage("collapsedUpNext") private var collapsedRaw = ""

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to look after yet", systemImage: "house")
                } description: {
                    Text("Add your dishwasher, windows, floors or anything else that needs regular care.")
                } actions: {
                    Button("Add Your First Item") { AppState.shared.showingAddItem = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SilenceBanner()
                        if mode == .calendar {
                            TaskCalendarView(tasks: allTasks, mineOnly: isMineOnly) { editingTask = $0 }
                        } else if !tasks.contains(where: \.needsAttention) {
                            allCaughtUp
                        }
                        ForEach(sections, id: \.key) { section in
                            CollapsibleCard(title: section.title,
                                            badge: section.badge,
                                            isExpanded: expandedBinding(section.key)) {
                                ForEach(Array(section.tasks.enumerated()), id: \.element.id) { index, task in
                                    if index > 0 { Divider() }
                                    TaskRow(task: task, showsItem: true, isDone: section.key == "date:Done") { editingTask = $0 }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Up Next")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !people.isEmpty {
                    Picker("Show", selection: $scope) {
                        ForEach(TaskScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .help("Show your tasks, or everyone's")
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("Group", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(items.isEmpty)
            }
            // Both "add" actions share one glass group.
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Task", systemImage: "checklist.unchecked") { addingTask = true }
                    .help("Add a custom task to any item")
                    .disabled(items.isEmpty)
                AddItemButton()
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorSheet(item: task.item, task: task)
        }
        .sheet(isPresented: $addingTask) {
            TaskEditorSheet(item: nil, task: nil)
        }
    }

    private var allCaughtUp: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("All caught up").font(.title3.weight(.semibold))
                Text("Nice. Nothing needs doing right now.").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private struct TaskSection {
        let key: String
        let title: String
        let badge: String?
        let tasks: [MaintenanceTask]
    }

    private var sections: [TaskSection] {
        switch mode {
        case .date:
            let now = Date()
            var buckets: [String: [MaintenanceTask]] = [:]
            for task in tasks {
                let title: String
                switch UpNextBucket.of(due: task.nextDueAt, lastCompletedAt: task.lastCompletedAt,
                                       isActive: task.isActive, now: now) {
                case .overdue: title = "Overdue"
                case .today: title = "Today"
                case .thisWeek: title = "This Week"
                case .done: title = "Done"
                case .hidden: continue
                }
                buckets[title, default: []].append(task)
            }
            return ["Overdue", "Today", "This Week", "Done"].compactMap { title in
                guard let list = buckets[title] else { return nil }
                let tasks = title == "Done" ? list.sorted { ($0.lastCompletedAt ?? .distantPast) > ($1.lastCompletedAt ?? .distantPast) } : list
                return TaskSection(key: "date:\(title)", title: title, badge: "\(list.count)", tasks: tasks)
            }
        case .room:
            let groups = Rooms.grouped(tasks, by: { $0.item?.room ?? "" })
            return groups.map { group in
                let due = group.values.filter(\.isDue).count
                return TaskSection(key: "room:\(group.room)", title: Rooms.title(group.room, hasRooms: groups.count > 1),
                                   badge: due > 0 ? "\(due) due" : nil, tasks: group.values)
            }
        case .calendar:
            return []
        }
    }

    private var collapsed: Set<String> {
        Set(collapsedRaw.split(separator: "\u{1F}").map(String.init))
    }

    private func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(key) },
            set: { expanded in
                var set = collapsed
                if expanded { set.remove(key) } else { set.insert(key) }
                collapsedRaw = set.sorted().joined(separator: "\u{1F}")
            }
        )
    }
}

/// Section header that folds its card away.
struct CollapsibleCard<Content: View>: View {
    let title: String
    var badge: String?
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title).font(.headline)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Card { content }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Shows when reminders are silenced, with a one-click way back.
struct SilenceBanner: View {
    var body: some View {
        let nagger = Nagger.shared
        if nagger.isSilenced, let until = nagger.silencedUntil {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                Text("Reminders are silenced until \(until.formatted(.dateTime.weekday(.wide).hour().minute())).")
                Spacer()
                Button("Resume") { nagger.unsilence() }
            }
            .padding(12)
            .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: Card<EmptyView>.cornerRadius, style: .continuous))
        }
    }
}
