import SwiftData
import SwiftUI

struct MenuBarLabel: View {
    var body: some View {
        let nagger = Nagger.shared
        if nagger.isSilenced {
            Image(systemName: "moon.zzz.fill")
        } else if nagger.dueCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "house.fill")
                Text("\(nagger.dueCount)")
            }
        } else {
            Image(systemName: "house")
        }
    }
}

/// The menu bar tray: what's due now, one click to tick it off, and the silence switch.
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Query(filter: #Predicate<MaintenanceTask> { $0.isActive }, sort: \MaintenanceTask.nextDueAt)
    private var allTasks: [MaintenanceTask]
    @Query private var people: [Person]
    @AppStorage("menuBarScope") private var scope: TaskScope = .mine

    private var tasks: [MaintenanceTask] {
        scope == .mine && !people.isEmpty ? allTasks.filter(\.isMine) : allTasks
    }

    var body: some View {
        let nagger = Nagger.shared
        let due = tasks.filter(\.isDue)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Upkeep").font(.headline)
                if !people.isEmpty {
                    Picker("Show", selection: $scope) {
                        ForEach(TaskScope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                Spacer()
                if !due.isEmpty {
                    Text(due.count == 1 ? "1 task waiting" : "\(due.count) tasks waiting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if nagger.isSilenced, let until = nagger.silencedUntil {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                    Text("Silenced until \(until.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    Spacer()
                    Button("Resume") { nagger.unsilence() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }

            Divider()

            let upcoming = tasks.filter { !$0.isDue && isWithinWeek($0) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if tasks.isEmpty {
                        emptyState
                    } else if due.isEmpty {
                        caughtUp
                    } else {
                        trayHeader("Due Now")
                        ForEach(due) { task in
                            TaskRow(task: task, showsItem: true, compact: true)
                                .padding(.horizontal, 14)
                        }
                    }
                    if !upcoming.isEmpty {
                        trayHeader("Coming Up")
                        ForEach(upcoming.prefix(8)) { task in
                            TaskRow(task: task, showsItem: true, compact: true)
                                .padding(.horizontal, 14)
                        }
                        if upcoming.count > 8 {
                            Text("+ \(upcoming.count - 8) more this week")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Menu {
                    Button("For 1 Day") { nagger.silence(for: 1) }
                    Button("For 3 Days") { nagger.silence(for: 3) }
                    Button("For a Week") { nagger.silence(for: 7) }
                    if nagger.isSilenced {
                        Divider()
                        Button("Resume Reminders") { nagger.unsilence() }
                    }
                } label: {
                    Label("Silence Reminders", systemImage: "moon.zzz")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)

                MenuButton(title: "Open Upkeep", systemImage: "macwindow") {
                    NSApp.activate()
                    openWindow(id: AppState.mainWindowID)
                }
                if Household.shared.isJoined {
                    MenuButton(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        SyncManager.shared.syncNow()
                    }
                }
                MenuButton(title: "Back Up Now", systemImage: "icloud.and.arrow.up") {
                    BackupManager.shared.backUpNow()
                }
                MenuButton(title: "Settings…", systemImage: "gearshape") {
                    NSApp.activate()
                    openSettings()
                }
                MenuButton(title: "Quit Upkeep", systemImage: "power") {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 340)
        .onAppear {
            AppState.shared.openMainWindow = { [openWindow] in openWindow(id: AppState.mainWindowID) }
        }
    }

    private func isWithinWeek(_ task: MaintenanceTask) -> Bool {
        if case .soon = task.status { return true }
        return false
    }

    private func trayHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to look after yet.").font(.callout.weight(.semibold))
            Button("Add Your First Item…") {
                NSApp.activate()
                openWindow(id: AppState.mainWindowID)
                AppState.shared.showingAddItem = true
            }
        }
        .padding(14)
    }

    private var caughtUp: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(.green.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("All caught up").font(.callout.weight(.semibold))
                if let next = tasks.first(where: { !$0.isDue }), !isWithinWeek(next) {
                    Text("Next: \(next.item?.name ?? "") · \(next.title), \(next.status.text.lowercased())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
    }
}

private struct MenuButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
