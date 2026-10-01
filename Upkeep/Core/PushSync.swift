import Foundation
import SwiftData

// What lets any Mac in the household send a phone its reminders (Docs/Sync.md › Phone
// notifications): the Macs themselves, the one sending key they share, each phone's subscription,
// and the last reminder sent to it. Record kinds `mac`, `pushKey`, `pushSubscription`, `pushDelivery`.

/// A Mac in the household, as it describes itself: who it belongs to, whether it serves phones
/// and at what name, and whether it helps send reminders. Only that Mac writes its record.
@Model
final class MacDevice {
    /// The Mac's device id.
    var uid: String = ""
    var name: String = ""
    var personUid: String = ""
    var servesPhones: Bool = false
    /// "upkeep-bostjan.local"; empty when it doesn't serve phones.
    var phoneHost: String = ""
    /// Sends reminders to phones paired with other Macs when those Macs haven't.
    var sendsReminders: Bool = false
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    init(uid: String) { self.uid = uid }
}

/// The household's one Web Push (VAPID) key. A phone's subscription only accepts pushes signed with
/// the key it was made for, so every Mac signs with this one. Anyone who shares the household
/// folder can read it.
@Model
final class PushKey {
    static let householdUid = "household"
    var uid: String = PushKey.householdUid
    /// Base64url of the raw P-256 private key.
    var privateKey: String = ""
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    init() {}
}

/// A phone that wants reminders: where to send them and whose they are.
@Model
final class PushSubscriptionRecord {
    /// The phone's device id.
    var uid: String = ""
    var phoneName: String = ""
    var personUid: String = ""
    var endpoint: String = ""
    var p256dh: String = ""
    var auth: String = ""
    /// The Mac the phone paired with, which sends on time; any other helping Mac is the backup.
    var pairedMacId: String = ""
    var createdAt: Date = Date()
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    init(uid: String) { self.uid = uid }
}

/// The last reminder slot sent to a phone, by whichever Mac sent it. Kept apart from the
/// subscription so sending never collides with a phone subscribing again.
@Model
final class PushDelivery {
    /// `sent-<phone device id>`: uids are unique across every kind, and the subscription has the plain id.
    var uid: String = ""
    var lastSentSlot: Date?
    var sentBy: String = ""
    var modifiedAt: Date = Date.distantPast
    var modifiedBy: String = ""
    var syncRaw: String = ""

    init(phone deviceId: String) { self.uid = Self.uid(for: deviceId) }

    static func uid(for phoneId: String) -> String { "sent-" + phoneId }

    /// The phone this is about.
    var phoneId: String { uid.hasPrefix("sent-") ? String(uid.dropFirst(5)) : uid }
}

extension MacDevice: SyncableModel {
    static var syncKind: String { "mac" }

    var knownSyncData: [String: JSONValue] {
        ["name": .string(name), "personUid": .string(personUid), "servesPhones": .bool(servesPhones),
         "phoneHost": .string(phoneHost), "sendsReminders": .bool(sendsReminders)]
    }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        name = data["name"]?.stringValue ?? ""
        personUid = data["personUid"]?.stringValue ?? ""
        servesPhones = data["servesPhones"]?.boolValue ?? false
        phoneHost = data["phoneHost"]?.stringValue ?? ""
        sendsReminders = data["sendsReminders"]?.boolValue ?? false
    }

    var syncChildren: [any SyncableModel] { [] }
    static func makeForSync() -> MacDevice { MacDevice(uid: "") }
}

extension PushKey: SyncableModel {
    static var syncKind: String { "pushKey" }

    var knownSyncData: [String: JSONValue] { ["privateKey": .string(privateKey)] }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        privateKey = data["privateKey"]?.stringValue ?? ""
    }

    var syncChildren: [any SyncableModel] { [] }
    static func makeForSync() -> PushKey { PushKey() }
}

extension PushSubscriptionRecord: SyncableModel {
    static var syncKind: String { "pushSubscription" }

    var knownSyncData: [String: JSONValue] {
        ["phoneName": .string(phoneName), "personUid": .string(personUid), "endpoint": .string(endpoint),
         "p256dh": .string(p256dh), "auth": .string(auth), "pairedMacId": .string(pairedMacId), "createdAt": .date(createdAt)]
    }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        phoneName = data["phoneName"]?.stringValue ?? ""
        personUid = data["personUid"]?.stringValue ?? ""
        endpoint = data["endpoint"]?.stringValue ?? ""
        p256dh = data["p256dh"]?.stringValue ?? ""
        auth = data["auth"]?.stringValue ?? ""
        pairedMacId = data["pairedMacId"]?.stringValue ?? ""
        createdAt = data["createdAt"]?.dateValue ?? createdAt
    }

    var syncChildren: [any SyncableModel] { [] }
    static func makeForSync() -> PushSubscriptionRecord { PushSubscriptionRecord(uid: "") }
}

extension PushDelivery: SyncableModel {
    static var syncKind: String { "pushDelivery" }

    var knownSyncData: [String: JSONValue] { ["lastSentSlot": .date(lastSentSlot), "sentBy": .string(sentBy)] }

    func applySyncData(_ data: JSONValue, resolver: SyncResolver) {
        lastSentSlot = data["lastSentSlot"]?.dateValue
        sentBy = data["sentBy"]?.stringValue ?? ""
    }

    var syncChildren: [any SyncableModel] { [] }
    static func makeForSync() -> PushDelivery { PushDelivery(phone: "") }
}
