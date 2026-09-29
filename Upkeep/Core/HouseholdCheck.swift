import Foundation

/// Whether a phone's copy belongs to this Mac's household, before it's merged (Docs/Sync.md › LAN API).
///
/// A phone keeps its full copy of a household. When its Mac is reset or replaced by one in a
/// different household, merging would bring every old person, item and task in as a second copy,
/// since the new household's records all have new uids. So a phone from another household is
/// turned away, and asked to replace its copy instead.
enum HouseholdCheck {
    enum Decision: Equatable { case merge, otherHousehold }

    /// `phoneUids` and `macUids` are the record and tombstone uids each side holds.
    static func decide(phoneHousehold: String?, macHousehold: String?, phoneUids: Set<String>, macUids: Set<String>) -> Decision {
        // A Mac that isn't in a household has nothing to protect yet.
        guard let mac = macHousehold, !mac.isEmpty else { return .merge }
        if phoneHousehold == mac { return .merge }
        // A new phone, or a Mac with nothing yet: nothing can clash.
        if phoneUids.isEmpty || macUids.isEmpty { return .merge }
        // An older phone that doesn't say, or a household whose id was made again: sharing even one
        // record means the same household. Sharing none means another one.
        return phoneUids.isDisjoint(with: macUids) ? .otherHousehold : .merge
    }
}
