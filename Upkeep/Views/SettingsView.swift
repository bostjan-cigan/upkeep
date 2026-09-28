import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Reminders", systemImage: "bell.badge") { RemindersSettings() }
            Tab("Household", systemImage: "person.2") {
                settingsForm {
                    HouseholdSettingsSection()
                    EraseEverythingSection()
                }
            }
            Tab("Phones", systemImage: "iphone") { settingsForm { PhonesSettingsSection() } }
            Tab("Backups", systemImage: "externaldrive") { BackupSettings() }
        }
        .frame(width: 520)
    }
}

/// A grouped form sized to its content, like System Settings panes.
func settingsForm<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    Form { content() }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
}

/// This person's reminder settings. They're part of the person, so they follow them to every device.
private struct RemindersSettings: View {
    @Environment(\.modelContext) private var context
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let nagger = Nagger.shared
        settingsForm {
            if let me = Household.shared.me {
                personSections(me)
            } else {
                Section {
                    Text("Choose who you are in Household to set your reminders.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if nagger.isSilenced, let until = nagger.silencedUntil {
                    LabeledContent("Silenced until", value: until.formatted(date: .abbreviated, time: .shortened))
                    Button("Resume Reminders") { nagger.unsilence() }
                } else {
                    HStack {
                        Text("Silence all reminders")
                        Spacer()
                        Button("1 Day") { nagger.silence(for: 1) }
                        Button("3 Days") { nagger.silence(for: 3) }
                        Button("1 Week") { nagger.silence(for: 7) }
                    }
                }
                notificationStatus(nagger)
            }

            Section {
                Toggle("Open Upkeep at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .task { await nagger.refreshAuthorization() }
    }

    @ViewBuilder private func personSections(_ me: Person) -> some View {
        @Bindable var me = me
        Section {
            Picker("Remind me every", selection: saving($me.nagHours)) {
                ForEach([1, 2, 3, 4, 6, 12], id: \.self) { h in
                    Text(h == 1 ? "hour" : "\(h) hours").tag(h)
                }
            }
            Picker("Starting at", selection: saving($me.activeStart)) {
                ForEach(5...13, id: \.self) { h in Text(hourLabel(h)).tag(h) }
            }
            Picker("Until", selection: saving($me.activeEnd)) {
                ForEach(15...23, id: \.self) { h in Text(hourLabel(h)).tag(h) }
            }
            LabeledContent("Remind on") {
                WeekdayPicker(selection: saving($me.remindDays))
            }
            LabeledContent("Chore days") {
                WeekdayPicker(selection: saving($me.choreDays))
            }
        } header: {
            Text("\(me.name)’s Reminders")
        } footer: {
            Text("Upkeep keeps reminding you about your tasks and everyone’s until they’re done, snoozed or silenced. New chores land on your chore days, unless they come round rarely enough that the date matters. These settings follow you to all your devices.")
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("Don't remind me at work", isOn: saving($me.workEnabled))
            if me.workEnabled {
                LabeledContent("Work days") {
                    WeekdayPicker(selection: saving($me.workDays))
                }
                Picker("Work starts", selection: saving($me.workStart)) {
                    ForEach(0...23, id: \.self) { h in Text(hourLabel(h)).tag(h) }
                }
                Picker("Work ends", selection: saving($me.workEnd)) {
                    ForEach(1...23, id: \.self) { h in Text(hourLabel(h)).tag(h) }
                }
            }
        } header: {
            Text("Work Schedule")
        } footer: {
            Text(me.workEnabled
                 ? "On work days, reminders from \(hourLabel(me.workStart)) until \(hourLabel(me.workEnd)) are skipped. Ones before and after work still arrive."
                 : "Skip reminders during your working hours, so they only come before or after work.")
                .foregroundStyle(.secondary)
        }
    }

    /// Saves and reschedules on every change.
    private func saving<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: {
            binding.wrappedValue = $0
            try? context.save()
            Nagger.shared.reschedule()
        })
    }

    @ViewBuilder private func notificationStatus(_ nagger: Nagger) -> some View {
        switch nagger.authorization {
        case .authorized, .provisional:
            LabeledContent("Notifications") { Label("On", systemImage: "bell.badge").foregroundStyle(.secondary) }
        default:
            LabeledContent("Notifications") {
                HStack {
                    Text("Off").foregroundStyle(.secondary)
                    Button("Open System Settings") { nagger.openSettings() }
                }
            }
        }
    }
}

private func hourLabel(_ h: Int) -> String {
    let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
}

private struct BackupSettings: View {
    @State private var exportDocument: BackupDocument?
    @State private var choosingRestoreFile = false
    @State private var pendingRestore: Snapshot?
    @State private var backupAlert: String?

    var body: some View {
        settingsForm { backupSection }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json,
                      defaultFilename: BackupManager.exportFileName()) { result in
            if case .failure(let error) = result { backupAlert = error.localizedDescription }
        }
        .fileImporter(isPresented: $choosingRestoreFile, allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                Task {
                    do { pendingRestore = try await BackupManager.load(from: url) }
                    catch { backupAlert = error.localizedDescription }
                }
            case .failure(let error):
                backupAlert = error.localizedDescription
            }
        }
        .fileDialogDefaultDirectory(BackupManager.shared.folder)
        .alert("Restore this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
               presenting: pendingRestore) { backup in
            Button("Replace for Everyone", role: .destructive) {
                Task { await BackupManager.shared.restore(backup) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { backup in
            Text("""
            The household’s data will be replaced with the backup from \
            \(backup.exportedAt.formatted(date: .long, time: .shortened)): \
            \(backup.count(of: HomeItem.syncKind)) items, \(backup.count(of: MaintenanceTask.syncKind)) tasks, \
            \(backup.count(of: MaintenanceLog.syncKind)) history entries, \(backup.count(of: Person.syncKind)) people. \
            This reaches every device in the household.

            Your current data is saved as a separate backup first. To add a file's data without replacing anything, use Household › Merge from File… instead.
            """)
        }
        .alert("Backup", isPresented: Binding(get: { backupAlert != nil }, set: { if !$0 { backupAlert = nil } })) {
            Button("OK") {}
        } message: {
            Text(backupAlert ?? "")
        }
    }

    private var backupSection: some View {
        let backup = BackupManager.shared
        return Section {
            LabeledContent("Last backup") {
                if backup.isWorking {
                    ProgressView().controlSize(.small)
                } else if let error = backup.lastError {
                    Label("Failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help(error)
                } else {
                    Text(backup.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Saved to") {
                Button(backup.locationDescription) { backup.showInFinder() }
                    .buttonStyle(.link)
                    .disabled(backup.folder == nil)
                    .help("Show in Finder")
            }
            HStack {
                Button("Back Up Now") { backup.backUpNow() }
                    .disabled(backup.isWorking)
                Spacer()
                Button("Export…") {
                    do { exportDocument = try backup.exportDocument() }
                    catch { backupAlert = error.localizedDescription }
                }
                Button("Restore…") { choosingRestoreFile = true }
            }
            .disabled(!backup.isEnabled)
        } header: {
            Text("Backups")
        } footer: {
            Text("Upkeep saves your own private copy of the whole household to iCloud Drive › Upkeep whenever it changes, one file per day, and keeps the last \(BackupManager.keepCount).")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Erase everything

/// The way back to a brand-new install, behind a confirmation that says exactly what goes.
private struct EraseEverythingSection: View {
    @State private var confirming = false

    var body: some View {
        if FactoryReset.isAvailable {
            Section {
                Button("Erase Everything…", role: .destructive) { confirming = true }
                    .foregroundStyle(.red)
            } header: {
                Text("Reset")
            } footer: {
                Text("Deletes the household from iCloud Drive and everything Upkeep keeps on this Mac, then starts over as if newly installed.")
                    .foregroundStyle(.secondary)
            }
            .sheet(isPresented: $confirming) { EraseEverythingSheet() }
        }
    }
}

private struct EraseEverythingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var understood = false
    @State private var erasing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Erase everything?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
            Text("This erases all data related to Upkeep and is a complete reset. It can't be undone.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("The household in iCloud Drive — every item, task, history entry and person, for everyone who shares it.")
                bullet("Your private backups in iCloud Drive.")
                bullet("Everything on this Mac: its copy of the household, who you are, reminder and phone settings.")
                bullet("Paired phones stop syncing and getting reminders. They'll need pairing again, and their certificate profile installing again.")
            }
            Text("Afterwards Upkeep opens as if newly installed: you'll set up a household and your chores from scratch. Other Macs in the household keep their own copy until they're reset too.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I understand this erases all Upkeep data and can't be undone", isOn: $understood)
                .toggleStyle(.checkbox)
            HStack {
                if erasing {
                    ProgressView().controlSize(.small)
                    Text("Erasing…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(erasing)
                Button("Erase Everything", role: .destructive) {
                    erasing = true
                    Task { await FactoryReset.eraseEverything() }
                }
                .disabled(!understood || erasing)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A row of toggleable weekday buttons, ordered from the locale's first weekday.
/// The selection is a digit string of `Calendar` weekdays, as stored by `Nagger`.
struct WeekdayPicker: View {
    @Binding var selection: String

    var body: some View {
        let cal = Calendar.current
        let selected = Nagger.weekdays(from: selection)
        HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { offset in
                let weekday = (cal.firstWeekday - 1 + offset) % 7 + 1
                let isOn = selected.contains(weekday)
                Button {
                    var days = selected
                    if isOn { days.remove(weekday) } else { days.insert(weekday) }
                    selection = Nagger.string(from: days)
                } label: {
                    Text(cal.veryShortWeekdaySymbols[weekday - 1])
                        .font(.callout.weight(isOn ? .semibold : .regular))
                        .frame(width: 22, height: 22)
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                        .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help(cal.weekdaySymbols[weekday - 1])
                .accessibilityLabel(cal.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}
