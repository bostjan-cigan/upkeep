import SwiftData
import SwiftUI

struct ItemDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var item: HomeItem

    @State private var editingTask: MaintenanceTask?
    @State private var addingTask = false
    @State private var editingItem = false
    @State private var managingRoutine = false
    @State private var showAllHistory = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                routine
                if !item.pausedTasks.isEmpty { paused }
                history
            }
            .padding(28)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(item.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit Item", systemImage: "pencil") { editingItem = true }
                    .help("Change name, icon or color")
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                AddItemButton()
            }
        }
        .sheet(item: $editingTask) { task in
            TaskEditorSheet(item: item, task: task)
        }
        .sheet(isPresented: $addingTask) {
            TaskEditorSheet(item: item, task: nil)
        }
        .sheet(isPresented: $editingItem) {
            ItemEditorSheet(item: item)
        }
        .sheet(isPresented: $managingRoutine) {
            RoutineManagerSheet(item: item)
        }
    }

    private var header: some View {
        HStack(spacing: 22) {
            ItemIconView(item: item, size: 112)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.largeTitle.weight(.bold))
                Text(summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if !item.notes.isEmpty {
                    Text(item.notes)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            Spacer()
        }
    }

    private var summary: String {
        let count = item.tasks?.count ?? 0
        let due = item.dueTaskCount
        var parts = [count == 1 ? "1 routine task" : "\(count) routine tasks"]
        if due > 0 { parts.append("\(due) waiting") }
        if !item.room.isEmpty { parts.insert(item.room, at: 0) }
        return parts.joined(separator: " · ")
    }

    private var routine: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Routine") {
                HStack(spacing: 14) {
                    Button("Manage", systemImage: "slider.horizontal.3") { managingRoutine = true }
                        .help("Turn tasks on or off, delete them, or add suggested ones")
                    Button("Add Task", systemImage: "plus") { addingTask = true }
                }
                .buttonStyle(.borderless)
            }
            Card {
                if item.sortedTasks.isEmpty {
                    Text("No tasks yet. Add one, like “Clean the filter every month”.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
                ForEach(Array(item.sortedTasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider() }
                    TaskRow(task: task) { editingTask = $0 }
                        .onTapGesture(count: 2) { editingTask = task }
                }
            }
        }
    }

    private var paused: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(item.pausedTasks.allSatisfy(\.isFinished) ? "Done" : "Paused")
            Card {
                ForEach(Array(item.pausedTasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Image(systemName: task.isFinished ? "checkmark.circle" : "pause.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                            Text(task.intervalDescription).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task.isFinished {
                            Text("Done").font(.callout)
                        } else {
                            Button("Resume") {
                                task.isActive = true
                                task.refreshDerived()
                                try? context.save()
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .foregroundStyle(.secondary)
                    .contextMenu {
                        Button("Edit Task…", systemImage: "pencil") { editingTask = task }
                    }
                }
            }
        }
    }

    private var history: some View {
        let logs = item.history
        let shown = showAllHistory ? logs : Array(logs.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "History") {
                if logs.count > 8 {
                    Button(showAllHistory ? "Show Less" : "Show All \(logs.count)") {
                        withAnimation(.snappy) { showAllHistory.toggle() }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Card {
                if logs.isEmpty {
                    Text("Completed tasks will show up here.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                }
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, log in
                    if index > 0 { Divider() }
                    HistoryRow(log: log)
                        .contextMenu {
                            Button("Remove from History", systemImage: "trash", role: .destructive) { remove(log) }
                        }
                }
            }
        }
    }

    private func remove(_ log: MaintenanceLog) {
        log.task?.refreshFromLogs(excluding: log)
        SyncStore.delete(log, in: context)
    }
}

private struct HistoryRow: View {
    let log: MaintenanceLog
    @Query private var people: [Person]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(log.task?.title ?? "Task")
            if let who = people.first(where: { $0.uid == log.completedByUid }) {
                Text("by \(who.name)").foregroundStyle(.secondary)
            }
            Spacer()
            Text(log.completedAt.formatted(date: .abbreviated, time: .omitted))
                .foregroundStyle(.secondary)
                .help(log.completedAt.formatted(date: .complete, time: .shortened))
        }
        .padding(.vertical, 7)
    }
}
