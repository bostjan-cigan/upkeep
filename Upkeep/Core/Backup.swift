import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum BackupError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable: "Backups are off in demo mode."
        }
    }
}

/// Plain JSON document for the Export… / Restore… file panels.
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw SnapshotError.damaged }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Keeps rolling private JSON snapshots of the whole household in iCloud Drive › Upkeep › Backups.
///
/// These are this person's own copies, separate from the shared household folder, so every
/// member has a full history of the household. One file per day, the newest `keepCount` kept,
/// written a few seconds after data changes (hourly check as a safety net). Without iCloud
/// Drive they go to Application Support instead. Restoring re-stamps the backup so it reaches
/// the whole household (see `SyncStore.restore`).
@MainActor
@Observable
final class BackupManager {
    static let shared = BackupManager()
    nonisolated static let keepCount = 30
    nonisolated private static let filePrefix = "Upkeep "

    enum Location { case iCloudDrive, thisMac }

    private(set) var lastBackupAt: Date?
    private(set) var lastError: String?
    private(set) var isWorking = false
    /// A change is waiting for its debounced backup.
    private(set) var isPending = false
    private(set) var folder: URL?
    private(set) var location: Location?

    private var container: ModelContainer?
    private var pending: Task<Void, Never>?
    private var timer: Timer?
    private let defaults = UserDefaults.standard
    /// Set for good by a factory reset, so no backup is written while it erases them.
    private var isStopped = false

    private enum Keys {
        static let lastBackupAt = "lastBackupAt"
        static let lastDigest = "lastBackupDigest"
    }

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        let stored = defaults.double(forKey: Keys.lastBackupAt)
        lastBackupAt = stored > 0 ? Date(timeIntervalSince1970: stored) : nil

        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleBackup(after: .seconds(5)) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backUp(force: false) }
        }
        let resolved = Self.resolveFolder()
        folder = resolved.url
        location = resolved.location
        // The iCloud Drive folder exists from the first launch, before any backup is written.
        try? FileManager.default.createDirectory(at: resolved.url, withIntermediateDirectories: true)
        scheduleBackup(after: .seconds(5))
    }

    func scheduleBackup(after delay: Duration) {
        guard !isStopped else { return }
        pending?.cancel()
        isPending = true
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await backUp(force: false)
            isPending = false
        }
    }

    /// Writes today's snapshot. Unless forced, skips when nothing changed since the last one.
    func backUp(force: Bool, suffix: String? = nil) async {
        guard let container, !isWorking, !isStopped else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let snapshot = SyncStore.snapshot(of: container.mainContext)
            // An empty store (e.g. a new Mac before joining its household) never produces a backup.
            guard !snapshot.records.isEmpty else { return }
            let digest = snapshot.contentDigest
            guard force || digest != defaults.string(forKey: Keys.lastDigest) else { return }

            let data = try snapshot.encoded()
            let name = Self.fileName(for: snapshot.exportedAt, suffix: suffix)
            let resolved = try await Task.detached { try Self.write(data, named: name, keep: Self.keepCount) }.value
            folder = resolved.url
            location = resolved.location
            lastBackupAt = snapshot.exportedAt
            lastError = nil
            defaults.set(snapshot.exportedAt.timeIntervalSince1970, forKey: Keys.lastBackupAt)
            defaults.set(digest, forKey: Keys.lastDigest)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Back Up Now": writes a snapshot even if nothing changed.
    func backUpNow() {
        pending?.cancel()
        isPending = false
        Task { await backUp(force: true) }
    }

    func exportDocument() throws -> BackupDocument {
        guard let container else { throw BackupError.unavailable }
        return BackupDocument(data: try SyncStore.snapshot(of: container.mainContext).encoded())
    }

    static func exportFileName(now: Date = Date()) -> String {
        "Upkeep Backup \(dayFormatter.string(from: now))"
    }

    /// Reads a backup chosen in an open panel (downloading it from iCloud first if needed).
    nonisolated static func load(from url: URL) async throws -> Snapshot {
        let data = try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try FileCoordination.read(url)
        }.value
        return try Snapshot.decode(data)
    }

    /// Saves the current data aside, then replaces it with `backup` for the whole household.
    func restore(_ backup: Snapshot) async {
        guard let container else { return }
        pending?.cancel()
        isPending = false
        await backUp(force: true, suffix: "before restore")
        SyncStore.restore(backup, into: container.mainContext)
        SyncManager.shared.scheduleSync(after: .milliseconds(200))
    }

    /// Stops backing up for good and waits for a backup already being written.
    func stop() async {
        isStopped = true
        pending?.cancel()
        isPending = false
        timer?.invalidate()
        while isWorking { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Where backups go: iCloud Drive › Upkeep › Backups, or this Mac when iCloud Drive is off.
    nonisolated static var backupFolder: URL { resolveFolder().url }

    /// This app's backup files in `folder`, by name (iCloud placeholders included).
    nonisolated static func backupFiles(in folder: URL) -> [String] { backupNames(in: folder) }

    func showInFinder() {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// False in demo mode, where there's nothing real to back up.
    var isEnabled: Bool { container != nil }

    var locationDescription: String {
        switch location {
        case .iCloudDrive: "iCloud Drive › Upkeep"
        case .thisMac: "This Mac only (iCloud Drive is off)"
        case nil: "—"
        }
    }

    // MARK: Status line

    var symbol: String {
        if lastError != nil { return "exclamationmark.icloud.fill" }
        if location != .iCloudDrive { return "icloud.slash.fill" }
        return lastBackupAt == nil ? "icloud" : "checkmark.icloud.fill"
    }

    var tint: Color {
        if lastError != nil || location != .iCloudDrive { return .red }
        return lastBackupAt == nil ? .secondary : .green
    }

    func title(now: Date = Date()) -> String {
        if lastError != nil { return "Backup failed" }
        if location != .iCloudDrive { return "Backed up on this Mac only" }
        if isWorking || (isPending && lastBackupAt == nil) { return "Backing up to iCloud Drive…" }
        guard let lastBackupAt else { return "Not backed up yet" }
        if now.timeIntervalSince(lastBackupAt) < 60 { return "Backed up just now" }
        return "Backed up \(lastBackupAt.formatted(.relative(presentation: .named)))"
    }

    var detail: String {
        if let lastError { return lastError }
        if location != .iCloudDrive { return "iCloud Drive isn't set up on this Mac, so backups stay in \(folder?.path ?? "Application Support")." }
        return "Saved to \(folder?.path ?? "iCloud Drive"). Changes are backed up a few seconds after you make them."
    }

    // MARK: Files (off the main thread)

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmm"
        return f
    }()

    /// One file per day, so names sort chronologically: "Upkeep 2026-09-21.json".
    private static func fileName(for date: Date, suffix: String?) -> String {
        var name = filePrefix + dayFormatter.string(from: date)
        if let suffix { name += " \(timeFormatter.string(from: date)) \(suffix)" }
        return name + ".json"
    }

    nonisolated private static func resolveFolder() -> (url: URL, location: Location) {
        if let iCloudDrive = Household.iCloudDriveURL {
            return (iCloudDrive.appending(path: "Upkeep/Backups", directoryHint: .isDirectory), .iCloudDrive)
        }
        return (URL.applicationSupportDirectory.appending(path: "Upkeep/Backups", directoryHint: .isDirectory), .thisMac)
    }

    nonisolated private static func write(_ data: Data, named name: String, keep: Int) throws -> (url: URL, location: Location) {
        let resolved = resolveFolder()
        try FileManager.default.createDirectory(at: resolved.url, withIntermediateDirectories: true)
        try FileCoordination.write(data, to: resolved.url.appending(path: name))
        prune(resolved.url, keep: keep)
        return resolved
    }

    /// Backup file names, newest first. Files evicted from this Mac by iCloud Drive may
    /// appear as ".Name.json.icloud" placeholders and count too.
    nonisolated private static func backupNames(in folder: URL) -> [String] {
        FileCoordination.names(in: folder, suffix: ".json").filter { $0.hasPrefix(filePrefix) }.sorted(by: >)
    }

    nonisolated private static func prune(_ folder: URL, keep: Int) {
        for name in backupNames(in: folder).dropFirst(keep) {
            try? FileCoordination.delete(folder.appending(path: name))
        }
    }
}

/// iCloud Drive files must be accessed through a file coordinator so the sync daemon sees consistent state.
enum FileCoordination {
    /// Names in `dir` ending in `suffix`, with iCloud placeholders unwrapped and de-duplicated.
    static func names(in dir: URL, suffix: String) -> [String] {
        FileNames.unwrapped((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [], suffix: suffix)
    }

    static func read(_ url: URL) throws -> Data {
        // Files evicted from this Mac are downloaded first; the coordinated read waits for them.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var data = Data()
        try coordinate(.read, url) { data = try Data(contentsOf: $0) }
        return data
    }

    static func write(_ data: Data, to url: URL) throws {
        try coordinate(.write, url) { try data.write(to: $0, options: .atomic) }
    }

    static func delete(_ url: URL) throws {
        try coordinate(.delete, url) { try FileManager.default.removeItem(at: $0) }
    }

    private enum Access { case read, write, delete }

    private static func coordinate(_ access: Access, _ url: URL, _ body: (URL) throws -> Void) throws {
        var coordinatorError: NSError?
        var bodyError: Error?
        let coordinator = NSFileCoordinator()
        switch access {
        case .read:
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { u in
                do { try body(u) } catch { bodyError = error }
            }
        case .write, .delete:
            coordinator.coordinate(writingItemAt: url, options: access == .write ? .forReplacing : .forDeleting,
                                   error: &coordinatorError) { u in
                do { try body(u) } catch { bodyError = error }
            }
        }
        if let bodyError { throw bodyError }
        if let coordinatorError { throw coordinatorError }
    }
}

/// Sidebar status line: green when the latest data is backed up to iCloud Drive, red when not.
/// Click the text to open the backups folder, or the button to back up right away.
struct BackupStatusView: View {
    var body: some View {
        let backup = BackupManager.shared
        HStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 6) {
                    Image(systemName: backup.symbol)
                        .foregroundStyle(backup.tint)
                        .symbolEffect(.pulse, isActive: backup.isWorking || backup.isPending)
                    Text(backup.title(now: context.date))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .help(backup.detail)
            .onTapGesture { backup.showInFinder() }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 4)

            Button {
                backup.backUpNow()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!backup.isEnabled || backup.isWorking)
            .help("Back Up Now")
            .accessibilityLabel("Back Up Now")
        }
        .font(.caption)
    }
}
