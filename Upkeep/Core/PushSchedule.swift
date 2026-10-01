import Foundation

/// When a Mac sends a phone its reminder for a slot (Docs/Sync.md › Phone notifications).
///
/// The Mac a phone paired with sends at the slot. Any other Mac that helps with reminders waits a
/// few minutes and sends only if the household hasn't heard that the slot was sent — so a phone
/// still gets its reminder when its usual Mac is asleep, off or away, and normally gets it once.
enum PushSchedule {
    /// How long a helping Mac waits for word that the usual Mac sent the slot.
    static let grace: TimeInterval = 5 * 60
    /// A slot is still sent if the Mac noticed it this late (e.g. a timer tick); older ones are skipped.
    static let lateness: TimeInterval = 10 * 60
    /// A helping Mac starts late by design, so it gets the grace on top.
    static let backupLateness: TimeInterval = lateness + grace

    /// The slot to send now, if any. `slots` are the person's reminder times around now, oldest
    /// first; `lastSent` is the newest slot already sent (by any Mac) or handled here.
    static func slotToSend(slots: [Date], now: Date, isPrimary: Bool, lastSent: Date?) -> Date? {
        let delay = isPrimary ? 0 : grace
        let window = isPrimary ? lateness : backupLateness
        guard let slot = slots.last(where: { $0.addingTimeInterval(delay) <= now && $0 >= now.addingTimeInterval(-window) })
        else { return nil }
        if let lastSent, lastSent >= slot { return nil }
        return slot
    }
}
