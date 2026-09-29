import AppKit
import Foundation
import SwiftData

/// Keeps this Mac's replica in step with the household folder (Docs/Sync.md).
///
/// Each device writes only `devices/<deviceId>.json`; this Mac reads everyone else's file,
/// merges them into its store, and rewrites its own file when anything changed. Runs on
/// launch, when the app becomes active, when the folder changes, after local edits and
/// every few minutes.
@MainActor
@Observable
final class SyncManager {
    static let shared = SyncManager()
    nonisolated static let interval: TimeInterval = 5 * 60

    struct Peer: Identifiable, Hashable {
        /// The file name: unique even when iOS saves a second copy of one device's file.
        var id: String { fileName }
        var deviceId: String
        var name: String
        var platform: String
        var personUid: String
        var exportedAt: Date
        var fileName: String
        var error: String?
        /// An older file for a device that also has a newer one — usually an iOS "Keep Both" save.
        var isSupersededCopy = false
    }

    private(set) var lastSyncAt: Date?
    private(set) var lastSummary: MergeSummary?
    private(set) var lastError: String?
    private(set) var peers: [Peer] = []
    /// Rounds that have finished since this Mac last pointed at a folder.
    private(set) var roundsCompleted = 0
    /// Device files seen in the folder on the last round (this Mac's own excluded).
    private(set) var peerFilesSeen = 0

    /// Merges nest: a phone can POST in the middle of a folder round. A depth counter means the
    /// inner merge can't clear the flag out from under the outer one.
    private var syncDepth = 0
    var isSyncing: Bool { syncDepth > 0 }
    /// True once at least one round has read the household folder.
    var hasReadHousehold: Bool { roundsCompleted > 0 }

    private var container: ModelContainer?
    private var pending: Task<Void, Never>?
    /// Rounds run one at a time, in the order they were asked for.
    private var chain: Task<Void, Never> = Task {}
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var lastWrittenDigest: String?
    /// Set for good by a factory reset, so no round can write the household back.
    private var isStopped = false

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container

        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Saves made by the sync itself don't need another round.
                guard let self, !self.isSyncing else { return }
                self.scheduleSync(after: .seconds(2))
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync(after: .milliseconds(300)) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync(after: .zero) }
        }
        scheduleSync(after: .milliseconds(500))
    }

    func scheduleSync(after delay: Duration) {
        guard !isStopped else { return }
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await syncAndWait()
        }
    }

    /// Queues a round behind everything already queued and returns once it has finished, so a
    /// caller that just joined a folder is never told "done" by a round that started before it.
    func syncAndWait() async {
        let previous = chain
        let task = Task { @MainActor in
            await previous.value
            await self.round()
        }
        chain = task
        await task.value
    }

    func syncNow() { scheduleSync(after: .zero) }

    // MARK: Household folder

    /// Starts a new household in `folder` (created if needed), and reads it — the folder may already
    /// hold a household this Mac is only now pointing at.
    func createHousehold(at folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder.appending(path: "devices", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        _ = await Task.detached { Self.householdId(in: folder, create: true) }.value
        use(folder)
        await syncAndWait()
    }

    /// Joins the household in `folder`, e.g. one shared with you in iCloud Drive, and merges it right away.
    func joinHousehold(at folder: URL) async throws {
        var dir = folder
        // Accept the devices folder itself too.
        if dir.lastPathComponent == "devices" { dir = dir.deletingLastPathComponent() }
        try FileManager.default.createDirectory(at: dir.appending(path: "devices", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        use(dir)
        await syncAndWait()
    }

    /// Stops syncing for good and waits for a round already under way to finish.
    func stop() async {
        isStopped = true
        pending?.cancel()
        timer?.invalidate()
        stopWatching()
        await chain.value
    }

    /// Leaves this household without deleting anything in it, and opens setup to join another.
    /// Starting fresh clears this Mac's copy (no tombstones, so the household keeps everything),
    /// forgets who's using this Mac and unpairs its phones, so none of it mixes into the new
    /// household. Either way a backup is made first.
    func switchHousehold(bringAlong: Bool) async {
        guard let container else { return }
        await BackupManager.shared.backUp(force: true, suffix: "before switching household")
        pending?.cancel()
        await chain.value
        let left = Household.shared.folderURL
        leaveHousehold()
        Household.shared.householdId = nil
        lastSummary = nil
        lastError = nil
        if !bringAlong {
            SyncStore.clearLocal(in: container.mainContext)
            Household.shared.myPersonUid = ""
            PhoneServer.shared.revokeAll()
        }
        Household.shared.refreshPeople()
        Household.shared.skippedSetup = false
        Nagger.shared.reschedule()
        AppState.shared.leftHousehold = left
        AppState.shared.showingSetup = true
        AppState.shared.openMainWindow?()
    }

    func leaveHousehold() {
        Household.shared.folderPath = nil
        stopWatching()
        peers = []
        lastWrittenDigest = nil
    }

    private func use(_ folder: URL) {
        Household.shared.folderPath = folder.path
        // Learnt from the folder on the first round.
        Household.shared.householdId = nil
        lastWrittenDigest = nil
        roundsCompleted = 0
        peerFilesSeen = 0
        peers = []
        startWatching()
    }

    /// Deletes a device's file, e.g. an old Mac that's gone, and its `mac` record, so it no longer
    /// counts as a Mac that sends reminders. Its data stays merged here.
    func forget(_ peer: Peer) {
        guard let dir = Household.shared.devicesFolder else { return }
        try? FileCoordination.delete(dir.appending(path: peer.fileName))
        peers.removeAll { $0.id == peer.id }
        if let context = container?.mainContext, !peer.deviceId.isEmpty {
            let uid = peer.deviceId
            if let mac = try? context.fetch(FetchDescriptor<MacDevice>(predicate: #Predicate { $0.uid == uid })).first {
                SyncStore.delete(mac, in: context)
            }
        }
    }

    /// A Mac with no file in the household folder is gone (reset, replaced, or from a household
    /// before this one): its `mac` record goes, so it isn't offered as a Mac that sends reminders.
    /// Only after a round that read every file; a Mac that's still here writes its record again.
    private func forgetGoneMacs(present: Set<String>, in context: ModelContext) {
        let gone = ((try? context.fetch(FetchDescriptor<MacDevice>())) ?? []).filter { !present.contains($0.uid) }
        guard !gone.isEmpty else { return }
        for mac in gone { SyncStore.delete(mac, in: context, save: false) }
        try? context.save()
    }

    // MARK: Household identity

    /// The id in `<folder>/household.json`, written first if the folder (made by an older version) has none.
    nonisolated static func householdId(in folder: URL, create: Bool) -> String? {
        let url = folder.appending(path: "household.json")
        struct Marker: Codable { var id: String; var createdAt: String }
        if let data = try? FileCoordination.read(url), let marker = try? JSONDecoder().decode(Marker.self, from: data),
           !marker.id.isEmpty {
            return marker.id
        }
        guard create else { return nil }
        let marker = Marker(id: UUID().uuidString, createdAt: SyncCoding.dateString(Date()))
        guard let data = try? SyncCoding.encoder().encode(marker), (try? FileCoordination.write(data, to: url)) != nil else { return nil }
        return marker.id
    }

    /// Every uid this Mac's copy holds (records and tombstones), to tell a phone's household apart.
    func localUids() -> Set<String> {
        guard let context = container?.mainContext else { return [] }
        let snapshot = SyncStore.snapshot(of: context)
        return Set(snapshot.records.map(\.uid)).union(snapshot.tombstones.map(\.uid))
    }

    func showInFinder() {
        guard let url = Household.shared.folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Manual merge

    /// Merges a snapshot file chosen by hand (another device's file or a backup) without replacing
    /// anything. It's a deliberate act, so a file from another household is merged too — the result
    /// says so, since its people and items then sit next to this household's.
    func merge(fileAt url: URL) async throws -> (summary: MergeSummary, otherHousehold: Bool) {
        let snapshot = try await BackupManager.load(from: url)
        guard let container else { throw BackupError.unavailable }
        let theirs = snapshot.device.householdId, ours = Household.shared.householdId
        let other = theirs != nil && ours != nil && theirs != ours
        syncDepth += 1
        defer { syncDepth -= 1 }
        let summary = SyncStore.merge([snapshot], into: container.mainContext)
        lastSummary = summary
        scheduleSync(after: .milliseconds(200))
        return (summary, other)
    }

    // MARK: Phones

    /// Merges a phone's snapshot (from `/api/sync`) and returns the merged household to send back.
    func mergeFromPhone(_ snapshot: Snapshot) -> Snapshot? {
        guard let container else { return nil }
        syncDepth += 1
        defer { syncDepth -= 1 }
        let summary = SyncStore.merge([snapshot], into: container.mainContext)
        if !summary.isEmpty { lastSummary = summary }
        scheduleSync(after: .milliseconds(200))
        return SyncStore.snapshot(of: container.mainContext)
    }

    // MARK: The sync round

    /// One round: read everyone else's file, merge, write this Mac's own. Always go through
    /// `syncAndWait()` so rounds queue instead of dropping each other.
    private func round() async {
        guard let container, !isStopped else { return }
        guard let dir = Household.shared.devicesFolder else {
            // No household: nothing to exchange, but local edits still get stamped for later.
            syncDepth += 1
            SyncStore.stampChanges(in: container.mainContext)
            syncDepth -= 1
            return
        }
        if watchedPath != dir.path { startWatching() }
        syncDepth += 1
        defer {
            syncDepth -= 1
            roundsCompleted += 1
        }

        let me = Household.shared.deviceId
        // The household's identity, from its folder; a folder made by an older version gets one now.
        let folder = dir.deletingLastPathComponent()
        let household = await Task.detached { Self.householdId(in: folder, create: true) }.value
        if let household, Household.shared.householdId != household { Household.shared.householdId = household }
        let files = await Task.detached { Self.readPeerFiles(in: dir, except: me) }.value
        peerFilesSeen = files.count

        var snapshots: [Snapshot] = []
        var found: [Peer] = []
        for file in files {
            switch file.result {
            case .success(let s) where s.device.householdId != nil && household != nil && s.device.householdId != household:
                // A stray file from another household: merging it would bring every one of its
                // people and items in as second copies.
                found.append(Peer(deviceId: s.device.id, name: s.device.name, platform: s.device.platform,
                                  personUid: s.device.personUid, exportedAt: s.exportedAt, fileName: file.name,
                                  error: "From another household — not merged"))
            case .success(let s):
                snapshots.append(s)
                found.append(Peer(deviceId: s.device.id, name: s.device.name, platform: s.device.platform,
                                  personUid: s.device.personUid, exportedAt: s.exportedAt, fileName: file.name))
            case .failure(let error):
                found.append(Peer(deviceId: "", name: file.name, platform: "?", personUid: "",
                                  exportedAt: .distantPast, fileName: file.name, error: error.localizedDescription))
            }
        }
        peers = Self.markingSupersededCopies(found)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let context = container.mainContext
        let summary = SyncStore.merge(snapshots, into: context)
        if !summary.isEmpty { lastSummary = summary }
        if found.allSatisfy({ $0.error == nil }) { forgetGoneMacs(present: Set(found.map(\.deviceId)).union([me]), in: context) }

        let own = SyncStore.snapshot(of: context)
        let digest = own.contentDigest + own.device.personUid + (own.device.householdId ?? "")
        let url = dir.appending(path: "\(me).json")
        if digest != lastWrittenDigest || !FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try own.encoded()
                try await Task.detached { try FileCoordination.write(data, to: url) }.value
                lastWrittenDigest = digest
                lastError = nil
            } catch {
                lastError = "Couldn't write this Mac's file: \(error.localizedDescription)"
            }
        } else {
            lastError = found.compactMap(\.error).first.map { "A device file couldn't be read: \($0)" }
        }
        lastSyncAt = Date()
    }

    /// Flags every peer file that a newer file for the same device supersedes.
    nonisolated static func markingSupersededCopies(_ peers: [Peer]) -> [Peer] {
        let stale = HouseholdDevices.supersededCopies(peers.map { ($0.deviceId, $0.exportedAt) })
        return peers.indices.map { i in
            var peer = peers[i]
            peer.isSupersededCopy = stale.contains(i)
            return peer
        }
    }

    private struct PeerFile: Sendable {
        var name: String
        var result: Result<Snapshot, Error>
    }

    /// Every other device's file; iCloud placeholders (".x.json.icloud") are downloaded first.
    nonisolated private static func readPeerFiles(in dir: URL, except me: String) -> [PeerFile] {
        let files = FileCoordination.names(in: dir, suffix: ".json").filter { $0 != "\(me).json" }
        return files.map { name in
            let url = dir.appending(path: name)
            do {
                return PeerFile(name: name, result: .success(try Snapshot.decode(FileCoordination.read(url))))
            } catch {
                return PeerFile(name: name, result: .failure(error))
            }
        }
    }

    // MARK: Watching the folder

    private func startWatching() {
        stopWatching()
        guard let dir = Household.shared.devicesFolder else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleSync(after: .seconds(1)) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchedPath = dir.path
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
    }

    // MARK: Status line

    var symbol: String {
        if !Household.shared.isJoined { return "person.2.slash" }
        if lastError != nil { return "exclamationmark.arrow.triangle.2.circlepath" }
        return "arrow.triangle.2.circlepath"
    }

    func title(now: Date = Date()) -> String {
        guard Household.shared.isJoined else { return "Not in a household" }
        if lastError != nil { return "Sync problem" }
        if isSyncing && lastSyncAt == nil { return "Syncing…" }
        guard let lastSyncAt else { return "Not synced yet" }
        if now.timeIntervalSince(lastSyncAt) < 60 { return "Synced just now" }
        return "Synced \(lastSyncAt.formatted(.relative(presentation: .named)))"
    }
}
