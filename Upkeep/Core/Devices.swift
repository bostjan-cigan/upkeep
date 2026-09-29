// Which household members actually have a device, so Upkeep can offer the missing invitation.
import Foundation

enum HouseholdDevices {
    /// The union of everyone claimed by a device file, a phone pairing or a push subscription,
    /// plus whoever this Mac belongs to. Pure, so it can be tested without any of those.
    static func peopleWithDevices(peers: [String], subscriptions: [String],
                                  pairings: [String], me: String) -> Set<String> {
        var covered = Set(peers + subscriptions + pairings + [me])
        covered.remove("")
        return covered
    }

    /// Which of these device files a newer file for the same device supersedes. iOS "Save to
    /// Files" offers Keep Both, which leaves a stale second copy of a phone's file behind;
    /// both still merge, the stale one simply loses on `modifiedAt`.
    static func supersededCopies(_ files: [(deviceId: String, exportedAt: Date)]) -> Set<Int> {
        var newest: [String: Date] = [:]
        for file in files where !file.deviceId.isEmpty {
            newest[file.deviceId] = max(newest[file.deviceId] ?? .distantPast, file.exportedAt)
        }
        return Set(files.indices.filter { i in
            let file = files[i]
            guard !file.deviceId.isEmpty, let best = newest[file.deviceId] else { return false }
            return file.exportedAt < best
        })
    }
}
