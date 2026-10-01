import CryptoKit
import Foundation
import SwiftData

/// Sends reminder notifications to the household's phones with Web Push, straight from this Mac.
///
/// No server of our own: messages are encrypted for each phone (RFC 8291, `aes128gcm`), signed
/// with the household's VAPID key (RFC 8292) and posted to the phone's push endpoint (Apple's push
/// service), so they arrive wherever the phone — and this Mac — is. Each subscription belongs to a
/// person, and gets the same reminder slots that person's Mac would show, for their tasks.
///
/// Any Mac in the household can send (Docs/Sync.md › Phone notifications): subscriptions and the
/// key travel through the household folder. The Mac a phone paired with sends on time; a Mac that
/// helps with reminders sends a few minutes later, only if nobody has.
@MainActor
@Observable
final class WebPush {
    static let shared = WebPush()

    /// A phone's subscription, as read from the household.
    struct Subscription: Identifiable, Hashable, Sendable {
        var deviceId: String
        var phoneName: String
        var personUid: String
        var endpoint: String
        var p256dh: String
        var auth: String
        var pairedMacId: String
        var id: String { deviceId }
    }

    /// What came of the last test sent to a phone. Keyed by deviceId, so a subscription
    /// disappearing mid-flight (404/410) can't shift anyone else's result.
    enum TestState: Equatable { case sending, sent(Date), failed(String) }

    private(set) var subscriptions: [Subscription] = []

    /// A Mac in the household, as the settings show it.
    struct Mac: Identifiable, Hashable {
        var id: String
        var name: String
        var sendsReminders: Bool
    }

    /// The household's Macs, re-read with the subscriptions.
    private(set) var macs: [Mac] = []
    /// The last send's error per phone, on this Mac.
    private(set) var errors: [String: String] = [:]
    private(set) var testStates: [String: TestState] = [:]
    private(set) var isTestingAll = false
    private var timer: Timer?
    private var container: ModelContainer?
    private let defaults = UserDefaults.standard
    /// The newest slot this Mac has dealt with per phone, sent or not, so each is looked at once.
    private var handled: [String: Date] = [:]
    private static let handledKey = "webPushHandledSlots"
    /// Where versions before the household key kept subscriptions; moved into the household once.
    private static let legacySubscriptionsKey = "webPushSubscriptions"

    private init() {
        if let data = defaults.data(forKey: Self.handledKey),
           let map = try? SyncCoding.decoder().decode([String: Date].self, from: data) {
            handled = map
        }
    }

    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        migrateLegacySubscriptions()
        reload()
        NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var context: ModelContext? { container?.mainContext }
    private var me: String { Household.shared.deviceId }

    // MARK: This Mac in the household

    /// This Mac's own record, made on first use.
    private func myMac(in context: ModelContext) -> MacDevice {
        let uid = me
        if let existing = try? context.fetch(FetchDescriptor<MacDevice>(predicate: #Predicate { $0.uid == uid })).first {
            return existing
        }
        let mac = MacDevice(uid: uid)
        context.insert(mac)
        return mac
    }

    /// Keeps this Mac's record in step with its settings. Only real changes are assigned, so an
    /// unchanged Mac never re-stamps its record.
    func refreshMyMac() {
        guard let context else { return }
        let mac = myMac(in: context)
        let server = PhoneServer.shared
        let name = Household.shared.deviceName, person = Household.shared.myPersonUid
        let serves = server.isEnabled, host = serves ? server.phoneHost : ""
        if mac.name != name { mac.name = name }
        if mac.personUid != person { mac.personUid = person }
        if mac.servesPhones != serves { mac.servesPhones = serves }
        if mac.phoneHost != host { mac.phoneHost = host }
        if context.hasChanges { try? context.save() }
    }

    /// Whether this Mac sends reminders to phones paired with other Macs when those haven't.
    var sendsReminders: Bool { macs.first { $0.id == me }?.sendsReminders ?? false }

    func setSendsReminders(_ on: Bool) {
        guard let context else { return }
        myMac(in: context).sendsReminders = on
        try? context.save()
        if on { _ = try? signingKey() }
        SyncManager.shared.syncNow()
        tick()
    }

    /// Who sends a phone its reminders: the Mac it paired with, and the Macs that step in.
    struct Coverage: Identifiable {
        var id: String
        var phoneName: String
        var usual: String?
        var usualIsThisMac: Bool
        var backups: [String]
        var backupIsThisMac: Bool
    }

    var coverage: [Coverage] {
        let byId = Dictionary(macs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return subscriptions.map { sub in
            let helpers = macs.filter { $0.sendsReminders && $0.id != sub.pairedMacId }
            return Coverage(id: sub.deviceId, phoneName: sub.phoneName.isEmpty ? "Phone" : sub.phoneName,
                            usual: byId[sub.pairedMacId].map(\.name), usualIsThisMac: sub.pairedMacId == me,
                            backups: helpers.filter { $0.id != me }.map(\.name).sorted(),
                            backupIsThisMac: helpers.contains { $0.id == me })
        }
        .sorted { $0.phoneName.localizedStandardCompare($1.phoneName) == .orderedAscending }
    }

    // MARK: The household key

    /// The key every Mac signs with. The first Mac to need one publishes its own — for a Mac
    /// upgraded from before the household key, the one its phones already subscribed with.
    /// It waits until the household folder has been read, so it doesn't race a key already there.
    func signingKey() throws -> P256.Signing.PrivateKey {
        if let context, let record = try? context.fetch(FetchDescriptor<PushKey>()).first,
           let raw = try? base64URLDecode(record.privateKey), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = try VAPID.localSeed()
        let household = Household.shared
        if let context, !household.isJoined || SyncManager.shared.hasReadHousehold {
            let record = PushKey()
            record.privateKey = base64URLEncode(key.rawRepresentation)
            context.insert(record)
            try? context.save()
        }
        return key
    }

    // MARK: Subscriptions

    /// Re-reads the household's subscriptions, e.g. after a merge.
    private func reload() {
        guard let context else { return }
        let records = (try? context.fetch(FetchDescriptor<PushSubscriptionRecord>())) ?? []
        let list = records.map {
            Subscription(deviceId: $0.uid, phoneName: $0.phoneName, personUid: $0.personUid, endpoint: $0.endpoint,
                         p256dh: $0.p256dh, auth: $0.auth, pairedMacId: $0.pairedMacId)
        }
        .sorted { $0.deviceId < $1.deviceId }
        if list != subscriptions { subscriptions = list }
        let macList = ((try? context.fetch(FetchDescriptor<MacDevice>())) ?? [])
            .map { Mac(id: $0.uid, name: $0.name.isEmpty ? "Mac" : $0.name, sendsReminders: $0.sendsReminders) }
            .sorted { $0.id < $1.id }
        if macList != macs { macs = macList }
    }

    private func record(_ deviceId: String, in context: ModelContext) -> PushSubscriptionRecord? {
        try? context.fetch(FetchDescriptor<PushSubscriptionRecord>(predicate: #Predicate { $0.uid == deviceId })).first
    }

    /// A phone paired with this Mac turned reminders on (again): this Mac becomes its usual sender.
    func subscribe(deviceId: String, phoneName: String, personUid: String, endpoint: String, p256dh: String, auth: String) {
        guard let context else { return }
        let rec = record(deviceId, in: context) ?? {
            let new = PushSubscriptionRecord(uid: deviceId)
            context.insert(new)
            return new
        }()
        if rec.endpoint != endpoint { handled[deviceId] = nil }
        if rec.phoneName != phoneName, !phoneName.isEmpty { rec.phoneName = phoneName }
        if rec.personUid != personUid { rec.personUid = personUid }
        if rec.endpoint != endpoint { rec.endpoint = endpoint }
        if rec.p256dh != p256dh { rec.p256dh = p256dh }
        if rec.auth != auth { rec.auth = auth }
        if rec.pairedMacId != me { rec.pairedMacId = me }
        try? context.save()
        errors[deviceId] = nil
        reload()
        SyncManager.shared.syncNow()
    }

    /// Stops reminders to a phone on every Mac: the subscription is deleted with a tombstone.
    func unsubscribe(deviceId: String) {
        guard let context else { return }
        if let rec = record(deviceId, in: context) { SyncStore.delete(rec, in: context, save: false) }
        let deliveryUid = PushDelivery.uid(for: deviceId)
        if let delivery = try? context.fetch(FetchDescriptor<PushDelivery>(predicate: #Predicate { $0.uid == deliveryUid })).first {
            SyncStore.delete(delivery, in: context, save: false)
        }
        try? context.save()
        handled[deviceId] = nil
        errors[deviceId] = nil
        saveHandled()
        reload()
        SyncManager.shared.syncNow()
    }

    /// Versions before the household key kept this Mac's phones in its own settings.
    private func migrateLegacySubscriptions() {
        struct Legacy: Decodable { var deviceId, personUid, endpoint, p256dh, auth: String; var lastSentSlot: Date? }
        guard let context, let data = defaults.data(forKey: Self.legacySubscriptionsKey),
              let list = try? SyncCoding.decoder().decode([Legacy].self, from: data) else { return }
        let names = Dictionary(PhoneServer.shared.pairings.compactMap { p in p.deviceId.map { ($0, p.name) } },
                               uniquingKeysWith: { a, _ in a })
        for old in list where record(old.deviceId, in: context) == nil {
            let rec = PushSubscriptionRecord(uid: old.deviceId)
            rec.phoneName = names[old.deviceId] ?? ""
            rec.personUid = old.personUid
            rec.endpoint = old.endpoint
            rec.p256dh = old.p256dh
            rec.auth = old.auth
            rec.pairedMacId = me
            context.insert(rec)
            if let slot = old.lastSentSlot { handled[old.deviceId] = slot }
        }
        try? context.save()
        saveHandled()
        defaults.removeObject(forKey: Self.legacySubscriptionsKey)
    }

    private func saveHandled() {
        if let data = try? SyncCoding.encoder(pretty: false).encode(handled) { defaults.set(data, forKey: Self.handledKey) }
    }

    // MARK: Scheduling

    /// Once a minute: for each phone this Mac sends for, the newest reminder slot that's due now.
    private func tick(now: Date = Date()) {
        guard let context else { return }
        refreshMyMac()
        let serving = PhoneServer.shared.isEnabled
        let helps = sendsReminders
        guard serving || helps, !subscriptions.isEmpty else { return }

        let people = (try? context.fetch(FetchDescriptor<Person>())) ?? []
        let tasks = (try? context.fetch(FetchDescriptor<MaintenanceTask>(predicate: #Predicate { $0.isActive }))) ?? []
        let personUids = Set(people.map(\.uid))
        let deliveries = Dictionary(((try? context.fetch(FetchDescriptor<PushDelivery>())) ?? []).map { ($0.phoneId, $0) },
                                    uniquingKeysWith: { a, _ in a })
        guard let key = try? signingKey() else { return }
        var sent = false

        for sub in subscriptions {
            // On time for phones paired with this Mac while it serves them; otherwise only as a helper.
            let isUsual = sub.pairedMacId == me && serving
            guard isUsual || helps else { continue }
            let person = people.first { $0.uid == sub.personUid }
            if let until = person?.silencedUntil, until > now { continue }
            let slots = Nagger.nagSlots(after: now.addingTimeInterval(-PushSchedule.backupLateness - 60), for: .init(person), days: 2)
            let lastSent = [handled[sub.deviceId], deliveries[sub.deviceId]?.lastSentSlot].compactMap { $0 }.max()
            guard let slot = PushSchedule.slotToSend(slots: slots, now: now, isPrimary: isUsual, lastSent: lastSent) else { continue }
            handled[sub.deviceId] = slot

            let mine = tasks.filter {
                let uid = $0.currentAssigneeUid
                return uid.isEmpty || uid == sub.personUid || !personUids.contains(uid)
            }
            let due = Nagger.due(mine, at: slot)
            guard !due.isEmpty else { continue }
            let (title, body) = Nagger.message(for: due, at: slot)
            let badge = mine.filter { $0.needsAttention }.count
            send(["title": title, "body": body, "tag": "upkeep-nag", "url": "/", "badge": badge], to: sub, key: key)

            // Tell the household at once, so a helping Mac doesn't send it too.
            let delivery = deliveries[sub.deviceId] ?? {
                let new = PushDelivery(phone: sub.deviceId)
                context.insert(new)
                return new
            }()
            delivery.lastSentSlot = slot
            delivery.sentBy = me
            sent = true
        }
        saveHandled()
        if sent {
            try? context.save()
            SyncManager.shared.syncNow()
        }
    }

    // MARK: Testing, from Settings › Phones

    nonisolated private static let testPayload: [String: Any] =
        ["title": "Upkeep", "body": "Reminders from this Mac will look like this.", "tag": "upkeep-test", "url": "/"]

    /// Sends a test notification to one phone and records what came of it.
    func sendTest(to deviceId: String) async {
        guard let sub = subscriptions.first(where: { $0.deviceId == deviceId }), let key = try? signingKey() else { return }
        testStates[deviceId] = .sending
        apply(await Self.post(Self.testPayload, to: sub, key: key), for: deviceId, test: true)
    }

    /// Sends a test to every phone paired with this Mac at once — the way to check a household's
    /// phones after setting them up.
    func sendTestToAll() async {
        guard !isTestingAll, let key = try? signingKey() else { return }
        isTestingAll = true
        defer { isTestingAll = false }
        let targets = subscriptions.filter { $0.pairedMacId == me }
        for sub in targets { testStates[sub.deviceId] = .sending }
        await withTaskGroup(of: (String, String?).self) { group in
            for sub in targets {
                group.addTask { (sub.deviceId, await Self.post(Self.testPayload, to: sub, key: key)) }
            }
            for await (deviceId, result) in group { apply(result, for: deviceId, test: true) }
        }
    }

    /// Phones paired with this Mac that still get reminders though their pairing is gone.
    var orphans: [Subscription] {
        let paired = Set(PhoneServer.shared.pairings.compactMap(\.deviceId))
        return subscriptions.filter { $0.pairedMacId == me && !paired.contains($0.deviceId) }
    }

    private func send(_ payload: [String: Any], to sub: Subscription, key: P256.Signing.PrivateKey) {
        Task { apply(await Self.post(payload, to: sub, key: key), for: sub.deviceId, test: false) }
    }

    /// Where every push result lands. A subscription the push service no longer knows is removed
    /// for the whole household.
    private func apply(_ raw: String?, for deviceId: String, test: Bool) {
        let result = PushResult.from(raw)
        guard subscriptions.contains(where: { $0.deviceId == deviceId }) else {
            if test { testStates[deviceId] = .failed("This phone's subscription is gone.") }
            return
        }
        switch result {
        case .delivered: errors[deviceId] = nil
        case .gone: unsubscribe(deviceId: deviceId)
        case .failed(let message): errors[deviceId] = message
        }
        if test {
            testStates[deviceId] = result.testMessage.map { TestState.failed($0) } ?? .sent(Date())
        }
    }

    // MARK: Sending

    /// Returns nil on success, "gone" when the subscription no longer exists, or an error message.
    nonisolated private static func post(_ payload: [String: Any], to sub: Subscription, key: P256.Signing.PrivateKey) async -> String? {
        do {
            guard let endpoint = URL(string: sub.endpoint), let host = endpoint.host(), let scheme = endpoint.scheme else {
                return "Bad endpoint"
            }
            let json = try JSONSerialization.data(withJSONObject: payload)
            let body = try WebPushCrypto.encrypt(json, p256dh: try base64URLDecode(sub.p256dh), auth: try base64URLDecode(sub.auth))
            let jwt = try VAPID.token(audience: "\(scheme)://\(host)", key: key)

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("3600", forHTTPHeaderField: "TTL")
            request.setValue("normal", forHTTPHeaderField: "Urgency")
            request.setValue("upkeep-nag", forHTTPHeaderField: "Topic")
            request.setValue("vapid t=\(jwt), k=\(VAPID.publicKeyString(key))", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300: return nil
            case 404, 410: return "gone"
            default: return "Push service said \(status): \(String(decoding: data.prefix(200), as: UTF8.self))"
            }
        } catch {
            return error.localizedDescription
        }
    }
}

/// VAPID, which push services use to know who's sending. The household shares one key
/// (`WebPush.signingKey()`); this Mac's own file only seeds it.
enum VAPID {
    private static var url: URL { Certificates.folder.appending(path: "vapid.key") }
    /// Required by push services: a contact for the sender.
    static let subject = "https://bostjan-cigan.com/upkeep"

    /// This Mac's own key: the one older versions signed with, or a new one.
    static func localSeed() throws -> P256.Signing.PrivateKey {
        if let data = try? Data(contentsOf: url), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: Certificates.folder, withIntermediateDirectories: true)
        try key.rawRepresentation.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return key
    }

    static func publicKeyString(_ key: P256.Signing.PrivateKey) -> String {
        base64URLEncode(key.publicKey.x963Representation)
    }

    static func token(audience: String, key: P256.Signing.PrivateKey, now: Date = Date()) throws -> String {
        try WebPushCrypto.vapidToken(audience: audience, subject: subject, key: key, now: now)
    }
}
