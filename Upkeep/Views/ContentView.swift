import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \HomeItem.name) private var items: [HomeItem]
    @State private var itemToDelete: HomeItem?
    @State private var roomToRename: String?
    @State private var newRoomName = ""
    /// Collapsed sidebar rooms, remembered between launches.
    @AppStorage("collapsedRooms") private var collapsedRoomsRaw = ""

    var body: some View {
        @Bindable var state = AppState.shared

        NavigationSplitView {
            List(selection: $state.selection) {
                Label("Up Next", systemImage: "checklist")
                    .badge(Nagger.shared.dueCount)
                    .tag(SidebarSelection.upNext)

                let groups = Rooms.grouped(items, by: \.room)
                ForEach(groups, id: \.room) { group in
                    Section(isExpanded: expandedBinding(group.room)) {
                        ForEach(group.values) { item in
                            sidebarRow(item)
                        }
                    } header: {
                        Text(Rooms.title(group.room, hasRooms: groups.count > 1))
                            .contextMenu {
                                if !group.room.isEmpty {
                                    Button("Rename Room…") {
                                        newRoomName = group.room
                                        roomToRename = group.room
                                    }
                                }
                            }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    SyncStatusView()
                    BackupStatusView()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        } detail: {
            detail
        }
        .sheet(isPresented: $state.showingAddItem) {
            AddItemSheet { item in
                state.selection = .item(item.persistentModelID)
            }
        }
        .confirmationDialog("Delete “\(itemToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { itemToDelete != nil }, set: { if !$0 { itemToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let item = itemToDelete {
                    if state.selection == .item(item.persistentModelID) { state.selection = .upNext }
                    SyncStore.delete(item, in: context)
                }
                itemToDelete = nil
            }
        } message: {
            Text("Its tasks and maintenance history will be removed for everyone in the household.")
        }
        .alert("Rename Room", isPresented: Binding(get: { roomToRename != nil }, set: { if !$0 { roomToRename = nil } })) {
            TextField("Room name", text: $newRoomName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { renameRoom() }
        }
        .sheet(isPresented: $state.showingSetup) {
            HouseholdSetupSheet()
        }
        .onAppear {
            AppState.shared.openMainWindow = { [openWindow] in openWindow(id: AppState.mainWindowID) }
            if Household.shared.needsSetup { state.showingSetup = true }
        }
    }

    private func sidebarRow(_ item: HomeItem) -> some View {
        HStack(spacing: 8) {
            ItemIconView(item: item, size: 22)
            Text(item.name).lineLimit(1)
        }
        .badge(item.myDueTaskCount)
        .tag(SidebarSelection.item(item.persistentModelID))
        .contextMenu {
            Button("Delete “\(item.name)”…", role: .destructive) { itemToDelete = item }
        }
    }

    @ViewBuilder private var detail: some View {
        switch AppState.shared.selection {
        case .item(let id):
            if let item = items.first(where: { $0.persistentModelID == id }) {
                ItemDetailView(item: item)
                    .id(id)
            } else {
                UpNextView()
            }
        default:
            UpNextView()
        }
    }

    private var collapsedRooms: Set<String> {
        Set(collapsedRoomsRaw.split(separator: "\u{1F}").map(String.init))
    }

    private func expandedBinding(_ room: String) -> Binding<Bool> {
        let key = room.isEmpty ? "\u{0}" : room
        return Binding(
            get: { !collapsedRooms.contains(key) },
            set: { expanded in
                var set = collapsedRooms
                if expanded { set.remove(key) } else { set.insert(key) }
                collapsedRoomsRaw = set.sorted().joined(separator: "\u{1F}")
            }
        )
    }

    private func renameRoom() {
        guard let old = roomToRename else { return }
        let new = newRoomName.trimmingCharacters(in: .whitespaces)
        for item in items where item.room == old { item.room = new }
        try? context.save()
        roomToRename = nil
    }
}
