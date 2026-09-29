import AppKit
import SwiftData
import SwiftUI

/// Whose tasks a list shows.
enum TaskScope: String, CaseIterable, Identifiable {
    case mine, everyone
    var id: String { rawValue }
    var title: String { self == .mine ? "Mine" : "Everyone" }
}

/// A person's initial on their color.
struct PersonBadge: View {
    let person: Person
    var size: CGFloat = 20

    var body: some View {
        Circle()
            .fill(person.color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(person.initial)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(person.color.onBase)
            }
            .accessibilityLabel(person.name)
    }
}

/// "Assign to" submenu for a task's context menu: who does it every time, and who does just the next one.
struct AssignMenu: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]
    let task: MaintenanceTask

    var body: some View {
        if !people.isEmpty {
            Menu("Responsible") {
                Section("Every Time") {
                    picker(Binding(get: { task.assigneeUid }, set: { uid in
                        task.assigneeUid = uid
                        try? context.save()
                    }))
                }
                if task.isActive {
                    // Picking the usual person here takes a hand-over back.
                    Section("Just This Time") {
                        picker(Binding(get: { task.currentAssigneeUid }, set: { uid in
                            task.assignOnce(uid)
                            try? context.save()
                        }))
                    }
                }
            }
        }
    }

    private func picker(_ selection: Binding<String>) -> some View {
        Picker("Responsible", selection: selection) {
            Text("Everyone").tag("")
            ForEach(people) { p in Text(p.name).tag(p.uid) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Compact "who's responsible" picker for task rows in forms: the person's badge, or a group icon for everyone.
/// Hidden while the household has no people.
struct AssigneeButton: View {
    @Binding var uid: String
    @Query(sort: \Person.name) private var people: [Person]

    var body: some View {
        if !people.isEmpty {
            let person = people.first { $0.uid == uid }
            Menu {
                Picker("Responsible", selection: $uid) {
                    Text("Everyone").tag("")
                    ForEach(people) { p in Text(p.name).tag(p.uid) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 3) {
                    if let person {
                        PersonBadge(person: person, size: 18)
                    } else {
                        Image(systemName: "person.2")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(person.map { "Responsible: \($0.name)" } ?? "Responsible: everyone")
        }
    }
}

/// Sidebar line under the item list: when this Mac last exchanged changes with the household.
struct SyncStatusView: View {
    var body: some View {
        let sync = SyncManager.shared
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 6) {
                    Image(systemName: sync.symbol)
                        .foregroundStyle(sync.lastError != nil ? .red : .secondary)
                        .symbolEffect(.rotate, isActive: sync.isSyncing)
                    Text(sync.title(now: context.date))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(sync.lastError ?? (Household.shared.folderURL?.path ?? "Set up a household in Settings"))
            .onTapGesture {
                if Household.shared.isJoined { sync.showInFinder() } else { AppState.shared.showingSetup = true }
            }
            Spacer(minLength: 4)
            if Household.shared.isJoined {
                Button { sync.syncNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(sync.isSyncing)
                    .help("Sync Now")
                    .accessibilityLabel("Sync Now")
            }
        }
        .font(.caption)
    }
}

// MARK: Setup

/// First run: start a household or join one shared with you, say who you are, then when you do chores.
struct HouseholdSetupSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var people: [Person]

    enum Step { case choose, who, when }
    /// Whether the shared folder has been read yet. Until it has, the people already in the
    /// household aren't on screen, and offering to add a name invites a second "Ana".
    enum Readiness { case reading, ready, timedOut }
    @State private var step: Step = Household.shared.isJoined ? .who : .choose
    @State private var newName = ""
    @State private var newColor: TileColor = .teal
    @State private var choreDays = Weekdays.weekend
    @State private var error: String?
    @State private var working = false
    @State private var readiness: Readiness = .ready
    @State private var addAnyway = false
    @State private var collision: Person?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case .choose: choose
            case .who: who
            case .when: when
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    /// Household folders to offer: every one in iCloud Drive except the one just left.
    private var candidates: [URL] {
        let left = AppState.shared.leftHousehold?.standardizedFileURL.path
        return Household.iCloudHouseholds.filter { $0.standardizedFileURL.path != left }
    }

    private var choose: some View {
        let switching = AppState.shared.leftHousehold != nil
        return VStack(alignment: .leading, spacing: 18) {
            Label(switching ? "Join another household" : "Set up your household", systemImage: "person.2.fill")
                .font(.title2.weight(.semibold))
            Text(switching
                 ? "Accept the invitation to the household you’re joining first — its folder then appears in your iCloud Drive."
                 : "Everyone in your home shares one folder in iCloud Drive. Each Mac and phone keeps a full copy and syncs through it — no accounts or servers.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if Household.iCloudDriveURL == nil {
                Label("iCloud Drive is off on this Mac. Turn it on in System Settings › your Apple Account › iCloud, or choose any folder your household already shares.",
                      systemImage: "icloud.slash")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(candidates, id: \.self) { folder in
                SetupChoice(title: "Join “\(folder.lastPathComponent)”",
                            detail: "In your iCloud Drive\(deviceCountText(folder)). This Mac joins it and everyone's changes come across.",
                            systemImage: "icloud.and.arrow.down") {
                    join(folder)
                }
            }
            SetupChoice(title: "Join a household shared with me",
                        detail: "Accept the invitation first, then choose the shared “\(Household.folderName)” folder.",
                        systemImage: "person.crop.circle.badge.plus") {
                chooseFolder()
            }
            SetupChoice(title: "Start a new household",
                        detail: candidates.isEmpty
                            ? "Creates “\(Household.newHouseholdFolder.lastPathComponent)” in \(Household.defaultFolder.deletingLastPathComponent().lastPathComponent). Invite others from Settings › Household."
                            : "Only if this is a different home — the folders above are already households. Creates “\(Household.newHouseholdFolder.lastPathComponent)”.",
                        systemImage: "plus.circle.fill") {
                working = true
                step = .who
                Task {
                    do { try await SyncManager.shared.createHousehold(at: Household.newHouseholdFolder) }
                    catch { self.error = error.localizedDescription }
                    working = false
                }
            }
            HStack {
                Spacer()
                Button("Not Now") {
                    Household.shared.skippedSetup = true
                    AppState.shared.leftHousehold = nil
                    dismiss()
                }
            }
        }
    }

    private var who: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Who are you?").font(.title2.weight(.semibold))
            Text("Reminders on this Mac are for tasks assigned to you or to everyone, with your reminder settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if working || readiness == .reading {
                ProgressView("Reading the household…").controlSize(.small)
            }
            if !people.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(people) { p in
                        Button {
                            Household.shared.myPersonUid = p.uid
                            askWhen()
                        } label: {
                            HStack(spacing: 10) {
                                PersonBadge(person: p, size: 26)
                                Text(p.name)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if readiness == .timedOut {
                Label("Upkeep hasn't been able to read the household folder yet. iCloud Drive may still be downloading it.",
                      systemImage: "icloud.and.arrow.down")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await readHousehold() } }
            }
            if canAddSelf {
                if !people.isEmpty {
                    Divider()
                    Text("Not listed? Add yourself").font(.headline)
                }
                HStack(spacing: 10) {
                    TextField("Your name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addMe)
                    Button("Continue", action: addMe)
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ColorSwatchPicker(selection: $newColor)
            } else {
                Button("I'm the first one here — add me") { addAnyway = true }
                    .buttonStyle(.link)
            }
        }
        .task(id: step) { if step == .who { await readHousehold() } }
        .confirmationDialog("There's already a “\(collision?.name ?? "")” in this household.",
                            isPresented: Binding(get: { collision != nil }, set: { if !$0 { collision = nil } })) {
            Button("That's Me") {
                if let twin = collision {
                    Household.shared.myPersonUid = twin.uid
                    collision = nil
                    askWhen()
                }
            }
            Button("Add Another “\(collision?.name ?? "")”") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                collision = nil
                insertMe(named: name)
            }
            Button("Cancel", role: .cancel) { collision = nil }
        } message: {
            Text("If that's you, pick the existing one — your tasks and your history stay together. A second person of the same name starts empty.")
        }
    }

    /// Adding a name is only safe once the household has been read, or the user insists.
    private var canAddSelf: Bool { addAnyway || readiness != .reading }

    /// Keeps asking for a round until the household is on screen. Reads the store directly:
    /// the `@Query` array captured by a running task never updates.
    private func readHousehold() async {
        guard Household.shared.isJoined else { readiness = .ready; return }
        if SyncManager.shared.hasReadHousehold && !peopleNow().isEmpty { readiness = .ready; return }
        readiness = .reading
        let deadline = Date().addingTimeInterval(20)
        while !Task.isCancelled {
            await SyncManager.shared.syncAndWait()
            if !peopleNow().isEmpty || SyncManager.shared.peerFilesSeen > 0 { readiness = .ready; return }
            if Date() >= deadline { readiness = .timedOut; return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func peopleNow() -> [Person] {
        (try? context.fetch(FetchDescriptor<Person>())) ?? []
    }

    private func deviceCountText(_ folder: URL) -> String {
        let devices = folder.appending(path: "devices", directoryHint: .isDirectory)
        let n = FileCoordination.names(in: devices, suffix: ".json").count
        return n > 0 ? " with \(n) device\(n == 1 ? "" : "s")" : ""
    }

    private var when: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("When do you get chores done?").font(.title2.weight(.semibold))
            Text("New chores land on these days, instead of whichever day you happened to add them. Anything rare enough that the date matters — servicing the AC, testing the smoke alarm — keeps its own date.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Self.chorePresets, id: \.days) { preset in
                    Button(preset.title) { choreDays = preset.days }
                        .buttonStyle(.bordered)
                        .tint(choreDays == preset.days ? .accentColor : nil)
                }
            }
            WeekdayPicker(selection: $choreDays)
            Text(Weekdays.label(choreDays).map { "Chores will land on \($0)." } ?? "Chores will be due as soon as they come round.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") {
                    Household.shared.me?.choreDays = choreDays
                    try? context.save()
                    finish()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private static let chorePresets: [(title: String, days: String)] = [
        ("Weekends", Weekdays.weekend), ("Saturdays", "7"), ("Sundays", "1"), ("Any day", Weekdays.any),
    ]

    /// The household is read before asking, so an existing person's answer is the one shown.
    private func askWhen() {
        Household.shared.refreshPeople()
        choreDays = Household.shared.me?.choreDays ?? Weekdays.weekend
        step = .when
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Join"
        panel.message = "Choose the “Upkeep Household” folder that was shared with you."
        panel.directoryURL = Household.defaultFolder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        join(url)
    }

    private func join(_ url: URL) {
        working = true
        step = .who
        Task {
            do { try await SyncManager.shared.joinHousehold(at: url) } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private func addMe() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let twin = people.first(where: { Names.sameName($0.name, name) }) {
            collision = twin
            return
        }
        insertMe(named: name)
    }

    private func insertMe(named name: String) {
        guard !name.isEmpty else { return }
        let person = Person(name: name, color: newColor)
        context.insert(person)
        try? context.save()
        Household.shared.myPersonUid = person.uid
        askWhen()
    }

    private func finish() {
        AppState.shared.leftHousehold = nil
        Household.shared.refreshPeople()
        Nagger.shared.reschedule()
        SyncManager.shared.syncNow()
        dismiss()
    }
}

struct SetupChoice: View {
    let title: String
    let detail: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SetupChoiceLabel(title: title, detail: detail, systemImage: systemImage)
        }
        .buttonStyle(.plain)
    }
}

/// The card inside a `SetupChoice`, on its own for things that bring their own button — a `ShareLink`.
struct SetupChoiceLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

// MARK: Settings

/// Settings › Household: people, the shared folder and the devices syncing through it.
struct HouseholdSettingsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Person.name) private var people: [Person]
    @State private var editing: Person?
    @State private var adding = false
    @State private var personToRemove: Person?
    @State private var mergeAlert: String?
    @State private var choosingMergeFile = false
    @State private var givingDevice: Person?
    @State private var switching = false

    var body: some View {
        let household = Household.shared
        let sync = SyncManager.shared
        Section {
            ForEach(people) { p in
                HStack(spacing: 10) {
                    PersonBadge(person: p, size: 22)
                    Text(p.name)
                    if p.uid == household.myPersonUid {
                        Text("You").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    } else if household.devicesKnown, !household.peopleWithDevices.contains(p.uid) {
                        Text("No device").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .help("Nobody has opened Upkeep as \(p.name) yet — invite them, or pair their phone.")
                    }
                    Spacer()
                    Menu {
                        Button("Invite…") { givingDevice = p }
                        Button("Pair a Phone…") { givingDevice = p }
                        Divider()
                        Button("Edit…") { editing = p }
                        if p.uid != household.myPersonUid {
                            Button("This Is Me") {
                                household.myPersonUid = p.uid
                                Nagger.shared.reschedule()
                            }
                        }
                        Divider()
                        Button("Remove…", role: .destructive) { personToRemove = p }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            Button("Add Person…", systemImage: "plus") { adding = true }
                .disabled(household.isJoined && !sync.hasReadHousehold)
                .help(household.isJoined && !sync.hasReadHousehold
                      ? "Waiting for the household folder to finish reading."
                      : "Add someone who lives here.")
        } header: {
            Text("People")
        } footer: {
            Text("Assign tasks to a person to make them responsible. Unassigned tasks remind everyone.")
                .foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { p in PersonEditorSheet(person: p) }
        .sheet(isPresented: $switching) { SwitchHouseholdSheet() }
        .sheet(isPresented: $adding) { PersonEditorSheet(person: nil) { givingDevice = $0 } }
        .sheet(item: $givingDevice) { p in AddedPersonSheet(person: p) }
        .confirmationDialog("Remove “\(personToRemove?.name ?? "")”?",
                            isPresented: Binding(get: { personToRemove != nil }, set: { if !$0 { personToRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let p = personToRemove {
                    if p.uid == household.myPersonUid { household.myPersonUid = "" }
                    SyncStore.delete(p, in: context)
                    Household.shared.refreshPeople()
                }
                personToRemove = nil
            }
        } message: {
            Text("Their tasks will be for everyone. Their history stays.")
        }

        Section {
            if let folder = household.folderURL {
                LabeledContent("Folder") {
                    Button(folder.lastPathComponent) { sync.showInFinder() }
                        .buttonStyle(.link)
                        .help(folder.path)
                }
                LabeledContent("Last sync") {
                    if let error = sync.lastError {
                        Label("Problem", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(error)
                    } else {
                        Text(sync.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                }
                if let summary = sync.lastSummary {
                    LabeledContent("Last changes", value: summary.text)
                }
                ForEach(sync.peers) { peer in
                    HStack {
                        Image(systemName: peerSymbol(peer))
                            .foregroundStyle(peer.error == nil ? Color.secondary : Color.red)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(peer.name)
                                if let owner = people.first(where: { $0.uid == peer.personUid }) {
                                    PersonBadge(person: owner, size: 14)
                                }
                                if peer.platform == "web" {
                                    Text("Phone file").font(.caption).foregroundStyle(.secondary)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .help("This phone isn't syncing over your Wi-Fi — it saves its own file into the shared folder.")
                                }
                                if peer.isSupersededCopy {
                                    Text("Older copy").font(.caption).foregroundStyle(.orange)
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .help("A newer file for this device is here too. Safe to forget.")
                                }
                            }
                            Text(peer.error ?? "Updated \(peer.exportedAt.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(peer.error == nil ? Color.secondary : Color.red)
                        }
                        Spacer()
                        Button("Forget") { sync.forget(peer) }
                            .buttonStyle(.borderless)
                            .help("Delete this device's file. Its changes stay here — but a phone that syncs through Files will have to export again.")
                    }
                }
                HStack {
                    ShareLink(item: folder) {
                        Label("Invite…", systemImage: "person.badge.plus")
                    }
                    .help("Share the household folder. Choose Collaborate so others can edit.")
                    Button("Switch Household…") { switching = true }
                        .help("Leave this household, without deleting anything in it, and join another.")
                    Spacer()
                    Button("Merge from File…") { choosingMergeFile = true }
                    Button("Sync Now") { sync.syncNow() }
                        .disabled(sync.isSyncing)
                }
            } else {
                Text("This Mac isn't in a household yet.").foregroundStyle(.secondary)
                Button("Set Up Household…") { AppState.shared.showingSetup = true; AppState.shared.openMainWindow?() }
            }
        } header: {
            Text("Household")
        } footer: {
            Text(household.isJoined
                 ? "To invite someone with a Mac: Invite… › Collaborate, or in Finder, Share the folder with their Apple ID and allow changes. They then choose Join in Upkeep. Phones paired over your Wi-Fi don't appear here — they're in Settings › Phones."
                 : "Share one iCloud Drive folder with everyone in your home. Each device keeps a full copy.")
                .foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosingMergeFile, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do {
                    let result = try await sync.merge(fileAt: url)
                    mergeAlert = "Merged: " + result.summary.text
                        + (result.otherHousehold ? "\n\nThis file came from another household, so its people and items now appear next to yours. Remove any doubles by hand." : "")
                }
                catch { mergeAlert = error.localizedDescription }
            }
        }
        .alert("Merge", isPresented: Binding(get: { mergeAlert != nil }, set: { if !$0 { mergeAlert = nil } })) {
            Button("OK") {}
        } message: { Text(mergeAlert ?? "") }
    }

    private func peerSymbol(_ peer: SyncManager.Peer) -> String {
        if peer.error != nil { return "questionmark.folder" }
        return peer.platform == "web" ? "iphone" : "laptopcomputer"
    }
}

struct PersonEditorSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Person.name) private var people: [Person]
    let person: Person?
    /// Called with a person who was just created, so the caller can offer them a device.
    var onCreated: ((Person) -> Void)? = nil
    @State private var name = ""
    @State private var color: TileColor = .teal

    /// Someone of this name is already here — adding another splits their tasks and history.
    private var twin: Person? {
        guard person == nil else { return nil }
        return people.first { Names.sameName($0.name, name) }
    }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            if let twin {
                Label("There's already a “\(twin.name)”. Adding another makes a second person, with their own tasks and history.",
                      systemImage: "person.2.badge.gearshape")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ColorSwatchPicker(selection: $color)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(person == nil ? (twin == nil ? "Add" : "Add Anyway") : "Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    var created: Person?
                    if let person {
                        person.name = trimmed
                        person.colorKey = color.rawValue
                    } else {
                        let new = Person(name: trimmed, color: color)
                        context.insert(new)
                        created = new
                    }
                    try? context.save()
                    Household.shared.refreshPeople()
                    dismiss()
                    if let created { onCreated?(created) }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            name = person?.name ?? ""
            color = person?.color ?? TileColor.allCases.randomElement() ?? .teal
        }
    }
}

/// Adding a person creates a name, not access. This is the step that was missing: give them
/// the shared folder (they have a Mac) or a pairing (they only have a phone).
struct AddedPersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let person: Person
    @State private var pairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                PersonBadge(person: person, size: 28)
                Text("How will \(person.name) see it?").font(.title2.weight(.semibold))
            }
            Text("\(person.name) is in the household — that's a name for assigning tasks. They still need Upkeep on a device of their own.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let folder = Household.shared.folderURL {
                ShareLink(item: folder) {
                    SetupChoiceLabel(title: "Invite…",
                                     detail: "\(person.name) has a Mac. Share the household folder with their Apple ID and allow changes — they choose Join in Upkeep.",
                                     systemImage: "person.badge.plus")
                }
                .buttonStyle(.plain)
            }

            SetupChoice(title: "Pair a Phone…",
                        detail: PhoneServer.shared.isEnabled
                            ? "\(person.name) only has a phone or tablet. It installs Upkeep from this Mac over your Wi-Fi."
                            : "\(person.name) only has a phone or tablet. This turns on serving to phones from this Mac.",
                        systemImage: "iphone.badge.play") {
                PhoneServer.shared.isEnabled = true
                PhoneServer.shared.newPairing()
                pairing = true
            }

            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
            }
        }
        .padding(28)
        .frame(width: 520)
        .sheet(isPresented: $pairing) { PairingSheet() }
    }
}

/// Leaving one household for another, with what happens to this Mac's copy spelled out first.
struct SwitchHouseholdSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bringAlong = false
    @State private var working = false

    var body: some View {
        let folder = Household.shared.folderURL?.lastPathComponent ?? Household.folderName
        let phones = PhoneServer.shared.pairings.count
        VStack(alignment: .leading, spacing: 16) {
            Label("Switch to another household?", systemImage: "arrow.left.arrow.right")
                .font(.title2.weight(.semibold))
            Text("This Mac leaves “\(folder)” and joins a household shared with you. Nothing is deleted there: the other devices keep everything, and this Mac’s file stays until someone forgets it.")
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $bringAlong) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start fresh — take the new household’s items").fontWeight(.medium)
                    Text("This Mac’s copy of “\(folder)” is cleared\(phones > 0 ? " and its \(phones == 1 ? "paired phone is" : "\(phones) paired phones are") unpaired" : ""), so none of it mixes into the new one. Your private backups still have it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring this household’s items along").fontWeight(.medium)
                    Text("Everything here — items, tasks, history and people — is merged into the new household. For a household that was only yours or a test. Someone may then appear twice in People.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text("Accept the invitation to the household you’re joining first. Upkeep then shows its folder to join. A backup of this Mac’s data is made before anything changes.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button("Switch Household") {
                    working = true
                    Task {
                        await SyncManager.shared.switchHousehold(bringAlong: bringAlong)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
