import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Erases everything Upkeep has, here and in iCloud Drive, and starts again as if newly installed.
///
/// In three steps: stop everything that writes (sync, backups, serving phones, reminders); delete
/// Upkeep's own files from the shared household folder and the private backups in iCloud Drive;
/// then quit and let a small helper delete this Mac's store, phone certificates and settings once
/// the app is gone — a running app would write its settings back on the way out — and open
/// Upkeep again, fresh.
///
/// Only Upkeep's own files are deleted from the folders: a household can be any folder the user
/// picked, so a folder is removed only once nothing else is left in it.
@MainActor
enum FactoryReset {
    /// Never in demo mode, whose data is in memory and whose "me" isn't the real one.
    static var isAvailable: Bool { !Persistence.isDemo }

    static func eraseEverything() async {
        guard isAvailable else { return }

        // 1. Nothing may write while it's all being deleted.
        await SyncManager.shared.stop()
        await BackupManager.shared.stop()
        PhoneServer.shared.stop()
        WebPush.shared.stop()
        await Nagger.shared.stop()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        try? await SMAppService.mainApp.unregister()

        // 2. iCloud Drive: the shared household folder and the private backups.
        let household = Household.shared.folderURL
        let backups = BackupManager.backupFolder
        await Task.detached {
            if let household { eraseHouseholdFolder(household) }
            eraseBackups(in: backups)
        }.value

        // 3. This Mac, once the app has quit. Everything is already stopped and about to be
        // deleted, so it just exits: going through `terminate` would wait on the quit handler,
        // which needs the main actor this task is holding.
        launchCleanup()
        exit(0)
    }

    // MARK: iCloud Drive

    nonisolated private static func eraseHouseholdFolder(_ folder: URL) {
        let devices = folder.appending(path: "devices", directoryHint: .isDirectory)
        for name in FileCoordination.names(in: devices, suffix: ".json") {
            try? FileCoordination.delete(devices.appending(path: name))
        }
        removeIfEmpty(devices)
        removeIfEmpty(folder)
    }

    nonisolated private static func eraseBackups(in folder: URL) {
        for name in BackupManager.backupFiles(in: folder) {
            try? FileCoordination.delete(folder.appending(path: name))
        }
        removeIfEmpty(folder)
        // iCloud Drive › Upkeep holds nothing but the backups folder.
        removeIfEmpty(folder.deletingLastPathComponent())
    }

    /// Removes `folder` when nothing but Finder's own bookkeeping is left in it.
    nonisolated private static func removeIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path),
              names.allSatisfy({ $0 == ".DS_Store" || $0 == ".localized" }) else { return }
        try? FileCoordination.delete(folder)
    }

    // MARK: This Mac

    /// Everything this Mac keeps for Upkeep: the store and phone certificates (Application
    /// Support › Upkeep, backups too when iCloud Drive is off), window state and caches.
    private static var localPaths: [String] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library", directoryHint: .isDirectory)
        let id = Bundle.main.bundleIdentifier ?? "com.bostjancigan.Upkeep"
        return [
            URL.applicationSupportDirectory.appending(path: "Upkeep", directoryHint: .isDirectory).path,
            library.appending(path: "Saved Application State/\(id).savedState").path,
            library.appending(path: "Caches/\(id)").path,
            library.appending(path: "HTTPStorages/\(id)").path,
        ]
    }

    /// A helper that outlives the app: waits for it to quit, deletes its files and settings, and
    /// opens it again. Paths travel as arguments, never inside the script's text.
    private static func launchCleanup() {
        let script = """
        pid="$1"; bundle="$2"; app="$3"; shift 3
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        for path in "$@"; do rm -rf -- "$path"; done
        defaults delete "$bundle" >/dev/null 2>&1
        open -n "$app"
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "upkeep-reset",
                             String(ProcessInfo.processInfo.processIdentifier),
                             Bundle.main.bundleIdentifier ?? "com.bostjancigan.Upkeep",
                             Bundle.main.bundleURL.path] + localPaths
        try? process.run()
    }
}
