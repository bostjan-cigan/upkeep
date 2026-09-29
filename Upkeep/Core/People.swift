import AppKit
import Foundation
import SwiftData
import SystemConfiguration

/// Someone in the household. Their reminder settings sync, so they follow them to every device.
@Model
final class Person {
    var uid: String = UUID().uuidString
    var name: String = ""
    var colorKey: String = TileColor.teal.rawValue
    var nagHours: Int = 3
    var activeStart: Int = 9
    var activeEnd: Int = 21
    /// `Calendar` weekdays (1 = Sunday … 7 = Saturday) as a digit string.
    var remindDays: String = "1234567"
    var workEnabled: Bool = false
    var workDays: String = "23456"
    var workStart: Int = 9
    var workEnd: Int = 17
    var silencedUntil: Date?
    /// The days this person usually gets chores done, as `Weekdays` digits. Empty means any day.
    /// New tasks start on these days instead of whenever they happen to be created.
    var choreDays: String = Weekdays.weekend
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    init(name: String, color: TileColor = .teal) {
        uid = UUID().uuidString
        self.name = name
        colorKey = color.rawValue
    }

    var color: TileColor { TileColor(rawValue: colorKey) ?? .teal }
    var initial: String { name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?" }
}

extension Person: SyncableModel {
    static var syncKind: String { "person" }

    var knownSyncData: [String: JSONValue] {
        // Keys a newer build added inside `reminders` are kept too.
        var reminders: [String: JSONValue] = [:]
        if case .object(let raw)? = rawSyncObject["reminders"] { reminders = raw }
        let known: [String: JSONValue] = [
            "nagHours": .int(nagHours), "activeStart": .int(activeStart), "activeEnd": .int(activeEnd),
            "remindDays": .string(remindDays), "workEnabled": .bool(workEnabled), "workDays": .string(workDays),
            "workStart": .int(workStart), "workEnd": .int(workEnd), "silencedUntil": .date(silencedUntil),
        ]
        reminders.merge(known) { $1 }
        return ["name": .string(name), "colorKey": .string(colorKey), "choreDays": .string(choreDays),
                "reminders": .object(reminders)]
    }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        name = data["name"]?.stringValue ?? ""
        colorKey = data["colorKey"]?.stringValue ?? TileColor.teal.rawValue
        choreDays = data["choreDays"]?.stringValue ?? Weekdays.weekend
        let r = data["reminders"]
        nagHours = r?["nagHours"]?.intValue ?? 3
        activeStart = r?["activeStart"]?.intValue ?? 9
        activeEnd = r?["activeEnd"]?.intValue ?? 21
        remindDays = r?["remindDays"]?.stringValue ?? "1234567"
        workEnabled = r?["workEnabled"]?.boolValue ?? false
        workDays = r?["workDays"]?.stringValue ?? "23456"
        workStart = r?["workStart"]?.intValue ?? 9
        workEnd = r?["workEnd"]?.intValue ?? 17
        silencedUntil = r?["silencedUntil"]?.dateValue
    }

    /// People have no children: their tasks fall back to "everyone".
    var syncChildren: [any SyncableModel] { [] }

    static func makeForSync() -> Person { Person(name: "") }
}

/// Who this device is and where the household lives. All of it stays on this device.
@MainActor
@Observable
final class Household {
    static let shared = Household()

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let deviceId = "syncDeviceId"
        static let myPersonUid = "myPersonUid"
        static let folderPath = "householdFolderPath"
        static let skippedSetup = "householdSetupSkipped"
        static let householdId = "householdId"
    }

    let deviceId: String
    /// Off in demo mode, so demo people never replace the real "who am I".
    var persists = true
    var myPersonUid: String { didSet { if persists { defaults.set(myPersonUid, forKey: Keys.myPersonUid) } } }
    var folderPath: String? { didSet { if persists { defaults.set(folderPath, forKey: Keys.folderPath) } } }
    var skippedSetup: Bool { didSet { if persists { defaults.set(skippedSetup, forKey: Keys.skippedSetup) } } }
    /// The household this Mac's copy belongs to: the id in its folder's `household.json`.
    var householdId: String? { didSet { if persists { defaults.set(householdId, forKey: Keys.householdId) } } }
    /// Person uids that exist, refreshed from the store; unknown assignees count as "everyone".
    private(set) var personUids: Set<String> = []
    private var container: ModelContainer?

    private init() {
        if let id = defaults.string(forKey: Keys.deviceId) {
            deviceId = id
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: Keys.deviceId)
        }
        myPersonUid = defaults.string(forKey: Keys.myPersonUid) ?? ""
        folderPath = defaults.string(forKey: Keys.folderPath)
        skippedSetup = defaults.bool(forKey: Keys.skippedSetup)
        householdId = defaults.string(forKey: Keys.householdId)
    }

    func start(container: ModelContainer) {
        self.container = container
        refreshPeople()
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshPeople() }
        }
    }

    func refreshPeople() {
        guard let container else { return }
        personUids = Set(((try? container.mainContext.fetch(FetchDescriptor<Person>())) ?? []).map(\.uid))
    }

    func personExists(_ uid: String) -> Bool { personUids.contains(uid) }

    /// The days new tasks should land on, from whoever this Mac belongs to.
    var myChoreDays: String { me?.choreDays ?? Weekdays.weekend }

    var me: Person? {
        guard let container, !myPersonUid.isEmpty else { return nil }
        let uid = myPersonUid
        return try? container.mainContext.fetch(FetchDescriptor<Person>(predicate: #Predicate { $0.uid == uid })).first
    }

    var folderURL: URL? { folderPath.map { URL(filePath: $0, directoryHint: .isDirectory) } }
    var devicesFolder: URL? { folderURL?.appending(path: "devices", directoryHint: .isDirectory) }
    var isJoined: Bool { folderURL != nil }
    var needsSetup: Bool { !Persistence.isDemo && !skippedSetup && (folderURL == nil || me == nil) }

    var deviceName: String { (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac" }

    var deviceInfo: DeviceInfo {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DeviceInfo(id: deviceId, name: deviceName, platform: "mac", personUid: myPersonUid, build: "\(v) (\(b))",
                          householdId: householdId)
    }

    nonisolated static let folderName = "Upkeep Household"

    /// iCloud Drive's folder on this Mac, or nil when iCloud Drive is off.
    nonisolated static var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Default location for a new household: iCloud Drive › Upkeep Household, or Documents without iCloud Drive.
    nonisolated static var defaultFolder: URL {
        (iCloudDriveURL ?? URL.documentsDirectory).appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Household folders in iCloud Drive — this Mac's, ones shared with you (macOS names a shared one
    /// "Upkeep Household 2" when you already have an "Upkeep Household"), or left by an earlier install.
    nonisolated static var iCloudHouseholds: [URL] {
        guard let base = iCloudDriveURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.filter { $0.hasPrefix(folderName) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { base.appending(path: $0, directoryHint: .isDirectory) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
    }

    nonisolated static var existingICloudHousehold: URL? { iCloudHouseholds.first }

    /// Where a new household goes: "Upkeep Household", or the first free "Upkeep Household 2"…, so
    /// starting one never lands in a folder that's already a household.
    nonisolated static var newHouseholdFolder: URL {
        let base = defaultFolder.deletingLastPathComponent()
        for n in 1...99 {
            let url = base.appending(path: n == 1 ? folderName : "\(folderName) \(n)", directoryHint: .isDirectory)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return defaultFolder
    }
}

extension Household {
    /// Person uids with at least one device: this Mac, another Mac, a phone paired over the Wi-Fi,
    /// a phone that exports its file into the folder, or a phone getting reminders.
    var peopleWithDevices: Set<String> {
        HouseholdDevices.peopleWithDevices(peers: SyncManager.shared.peers.map(\.personUid),
                                           subscriptions: WebPush.shared.subscriptions.map(\.personUid),
                                           pairings: PhoneServer.shared.pairings.compactMap(\.personUid),
                                           me: myPersonUid)
    }

    /// Only meaningful once the folder has been read — before that everyone looks device-less.
    var devicesKnown: Bool { !isJoined || SyncManager.shared.hasReadHousehold }
}
