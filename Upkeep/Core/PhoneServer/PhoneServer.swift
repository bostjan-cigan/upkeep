import AppKit
import Foundation
import Network
import SwiftData

/// Serves the Upkeep PWA and its sync API to phones and tablets on the home network.
///
/// - `http://upkeep-bostjan.local:8080/setup` — install steps and the home CA profile (no data).
/// - `https://upkeep-bostjan.local:8443/` — the PWA (bundled in `Resources/Web`) and `/api/sync`.
///
/// Each serving Mac answers at a name of its own (`PhoneHostName`), so several Macs in a household
/// can serve their own phones. It's a relay, not a master (Docs/Sync.md).
@MainActor
@Observable
final class PhoneServer {
    static let shared = PhoneServer()
    /// Launch arguments `-phoneHTTPSPort 9443 -phoneSetupPort 9080` override these, for testing
    /// next to a running copy. Phones' installed apps are tied to the port, so it's normally fixed.
    nonisolated static var httpsPort: UInt16 { port("phoneHTTPSPort", default: 8443) }
    nonisolated static var setupPort: UInt16 { port("phoneSetupPort", default: 8080) }

    nonisolated private static func port(_ key: String, default value: UInt16) -> UInt16 {
        let custom = UserDefaults.standard.integer(forKey: key)
        return (1...65535).contains(custom) ? UInt16(custom) : value
    }

    struct Pairing: Codable, Identifiable, Hashable {
        var token: String
        var name: String
        var createdAt: Date
        var lastSyncAt: Date?
        var deviceId: String?
        /// Who this phone says it belongs to, so the people list knows they have a device.
        var personUid: String?
        /// The name the phone reaches this Mac at, from its last sync. Pairings made by older
        /// versions haven't said yet; they use `upkeep.local`.
        var host: String?
        var id: String { token }

        /// Set up with a version before per-person names, so it looks for `upkeep.local`.
        var usesLegacyName: Bool { host == PhoneHostName.legacy || (host == nil && lastSyncAt != nil) }
    }

    enum Status: Equatable {
        case off, starting, running, failed(String)
    }

    private(set) var status: Status = .off

    /// The last device that turned down the certificate, to explain a phone's "not private" warning.
    struct Rejection: Equatable {
        var client: String
        var at: Date
        var status: OSStatus
        var explanation: String
    }
    private(set) var lastRejection: Rejection?
    private(set) var pairings: [Pairing] = []
    /// The token shown in the pairing QR code until it's used or replaced.
    private(set) var pendingToken: String?
    /// The short code shown next to the QR code, for an app already on the Home Screen (scanning a
    /// QR code always opens Safari, whose storage the installed app doesn't share).
    private(set) var pendingCode: String?
    private var pendingCodeExpires = Date.distantPast
    private var failedCodeAttempts = 0
    nonisolated static let codeLifetime: TimeInterval = 15 * 60
    nonisolated static let maxCodeAttempts = 10
    /// Each announced name and how it went, from `LocalHostname`.
    private(set) var nameStates: [String: LocalHostname.State] = [:]

    /// How far the phone being paired has got, so the pairing wizard can move on by itself.
    /// The phone is whichever device opens the setup page first after the wizard starts.
    struct SetupProgress: Equatable {
        var client: String?
        var downloadedProfile = false
        var trusts = false
        var openedApp = false
        /// The phone's name, once its first sync arrives.
        var pairedName: String?
    }
    private(set) var setupProgress = SetupProgress()
    /// The pairing made from the typed code, so the wizard notices its first sync too.
    private var codeToken: String?

    private var https: HTTPServer?
    private var setup: HTTPServer?
    private var mdns: LocalHostname?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let enabled = "serveToPhones"
        static let pairings = "phonePairings"
        static let webRoot = "phoneWebRoot"
        static let phoneHost = "phoneHostName"
        static let devSuffix = "phoneDevHostSuffix"
        static let legacyName = "phoneAnswerLegacyName"
        /// Launch argument `-phoneHost name.local`, for a test copy.
        static let hostOverride = "phoneHost"
    }

    #if DEBUG
    nonisolated static let isDevBuild = true
    #else
    nonisolated static let isDevBuild = false
    #endif

    private init() {
        if let data = defaults.data(forKey: Keys.pairings),
           let list = try? SyncCoding.decoder().decode([Pairing].self, from: data) {
            pairings = list
        }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Keys.enabled) }
        set {
            defaults.set(newValue, forKey: Keys.enabled)
            if newValue { start() } else { stop() }
        }
    }

    func startIfEnabled() {
        if isEnabled { start() }
    }

    // MARK: Names

    /// The name phones reach this Mac at: its person's (`upkeep-bostjan.local`), fixed the first time
    /// it serves, or one chosen in Change…. A development build uses `upkeep-dev-<random>.local`, so
    /// it never answers in place of the real app. Before anyone is "me", the Mac's own name.
    var phoneHost: String {
        if let forced = defaults.string(forKey: Keys.hostOverride), forced.hasSuffix(".local") { return forced }
        if Self.isDevBuild { return PhoneHostName.dev(devSuffix) }
        if let fixed = defaults.string(forKey: Keys.phoneHost) { return fixed }
        return personHost ?? Certificates.localHostName ?? PhoneHostName.legacy
    }

    private var personHost: String? {
        let people = ((try? Persistence.shared.mainContext.fetch(FetchDescriptor<Person>())) ?? []).map { (uid: $0.uid, name: $0.name) }
        return PhoneHostName.forPerson(uid: Household.shared.myPersonUid, among: people)
    }

    private var devSuffix: String {
        if let suffix = defaults.string(forKey: Keys.devSuffix) { return suffix }
        let suffix = PhoneHostName.randomDevSuffix()
        defaults.set(suffix, forKey: Keys.devSuffix)
        return suffix
    }

    /// The first time this Mac serves with a person, their name becomes its name for good, so renaming
    /// them — or "This Is Me" — never strands a paired phone.
    private func fixPhoneHost() {
        guard !Self.isDevBuild, defaults.string(forKey: Keys.phoneHost) == nil, let host = personHost else { return }
        defaults.set(host, forKey: Keys.phoneHost)
    }

    /// Change…: a name of the user's choosing. Phones paired with this Mac have to pair again.
    @discardableResult
    func setPhoneHost(_ typed: String) -> Bool {
        guard !Self.isDevBuild, let host = PhoneHostName.custom(typed) else { return false }
        defaults.set(host, forKey: Keys.phoneHost)
        restart()
        WebPush.shared.refreshMyMac()
        return true
    }

    /// Phones set up with this Mac before it was named after its person.
    var legacyPhones: [Pairing] { pairings.filter(\.usesLegacyName) }

    /// Also answer at `upkeep.local`, for phones set up with an older version. On by default while
    /// there are any; never in a development build.
    var answersLegacyName: Bool {
        get {
            guard !Self.isDevBuild else { return false }
            if defaults.object(forKey: Keys.legacyName) != nil { return defaults.bool(forKey: Keys.legacyName) }
            return !legacyPhones.isEmpty
        }
        set {
            defaults.set(newValue, forKey: Keys.legacyName)
            restart()
        }
    }

    /// The names this Mac announces itself: the Mac's own Bonjour name answers by itself already.
    private var announcedNames: [String] {
        var names = [phoneHost]
        if answersLegacyName, !names.contains(PhoneHostName.legacy) { names.append(PhoneHostName.legacy) }
        return names.filter { $0 != Certificates.localHostName }
    }

    /// Whether this Mac's phone name is answering on the network.
    var isNameAnnounced: Bool { nameStates[phoneHost] == .announced || phoneHost == Certificates.localHostName }

    /// Why this Mac's phone name isn't answering, if it isn't.
    var nameFailure: LocalHostname.Failure? {
        if case .failed(let failure)? = nameStates[phoneHost] { return failure }
        return nil
    }

    /// Withdraws every name and announces them again straight away.
    func resetNetworkName() {
        mdns?.reset()
    }

    /// The name new phones use: this Mac's phone name once it answers, until then its Bonjour name.
    var host: String {
        isNameAnnounced ? phoneHost : (Certificates.localHostName ?? phoneHost)
    }

    var appURL: String { "https://\(host):\(Self.httpsPort)/" }
    var setupURL: String { "http://\(host):\(Self.setupPort)/setup" }
    var pairingURL: String? { pendingToken.map { "\(appURL)?pair=\($0)" } }

    /// "K7QM-3XTP" for display.
    var pendingCodeText: String? {
        guard let code = pendingCode, Date() < pendingCodeExpires else { return nil }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }

    // MARK: Lifecycle

    func start() {
        guard https == nil else { return }
        status = .starting
        fixPhoneHost()
        let hostNames = Certificates.hostNames(phoneHost: phoneHost, legacy: answersLegacyName)
        Task {
            do {
                let identity = try await Task.detached { try Certificates.prepareIdentity(hostNames: hostNames) }.value
                try launch(identity: identity)
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops serving and withdraws this Mac's names, so other devices forget them at once.
    func stop() {
        https?.stop()
        setup?.stop()
        mdns?.stop()
        https = nil
        setup = nil
        mdns = nil
        nameStates = [:]
        status = .off
    }

    /// For a change of names: the certificate and the announced names follow.
    private func restart() {
        guard isEnabled else { return }
        stop()
        start()
    }

    /// New CA and certificate: every phone has to install and trust the new profile.
    func resetCertificates() {
        stop()
        Certificates.reset()
        if isEnabled { start() }
    }

    private func launch(identity: SecIdentity) throws {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw Certificates.CertError.noIdentity(-1) }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let webRoot = Self.webRoot
        let secure = try HTTPServer(port: Self.httpsPort, tls: tls) { request in
            await PhoneServer.handleSecure(request, webRoot: webRoot)
        }
        let plain = try HTTPServer(port: Self.setupPort, tls: nil) { request in
            await PhoneServer.handleSetup(request)
        }
        secure.onStateChange = { state in
            Task { @MainActor in
                switch state {
                case .ready: PhoneServer.shared.status = .running
                case .failed(let error): PhoneServer.shared.status = .failed("Port \(PhoneServer.httpsPort): \(error.localizedDescription)")
                default: break
                }
            }
        }
        secure.onTLSFailure = { client, status in
            Task { @MainActor in PhoneServer.shared.noteRejection(client: client, status: status) }
        }
        secure.start()
        plain.start()
        https = secure
        setup = plain

        // Dev copies use a short TTL, so even one that crashed drops out of every cache within seconds.
        let mdns = LocalHostname(names: announcedNames, ttl: Self.isDevBuild ? 10 : 120)
        mdns.onChange = { states in
            Task { @MainActor in PhoneServer.shared.nameStates = states }
        }
        mdns.start()
        self.mdns = mdns
        WebPush.shared.refreshMyMac()
    }

    fileprivate func noteRejection(client: String, status: OSStatus) {
        // Local tools (curl, this Mac's own checks) aren't what the user is debugging.
        guard client != "127.0.0.1", client != "::1" else { return }
        let explanation: String
        switch status {
        case errSSLPeerUnknownCA, errSSLPeerCertUnknown, errSSLPeerBadCert, errSSLPeerCertRevoked, errSSLPeerCertExpired,
             errSSLPeerAccessDenied, errSSLPeerUnsupportedCert, errSSLPeerDecryptError:
            explanation = "It doesn’t trust this Mac’s certificate yet. On that device: install the profile from step 1, then turn on “Upkeep Home CA” in Settings › General › About › Certificate Trust Settings. If it’s already on there, the device has an older profile — remove it (Settings › General › VPN & Device Management) and install it again."
        case errSSLClosedAbort, errSSLClosedGraceful, errSSLClosedNoNotify:
            explanation = "It closed the connection during the secure handshake — usually because it doesn’t trust the certificate (see step 1), or Safari showed a warning page."
        default:
            explanation = "The secure connection failed (\(status))."
        }
        lastRejection = Rejection(client: client, at: Date(), status: status, explanation: explanation)
        #if DEBUG
        NSLog("phone server: %@ rejected TLS (%d)", client, status)
        #endif
    }

    // MARK: Pairing

    func resetSetupProgress() {
        setupProgress = SetupProgress()
    }

    fileprivate enum SetupEvent { case openedSetup, downloadedProfile, secureRequest, openedApp }

    fileprivate func note(_ event: SetupEvent, from client: String) {
        if event == .openedSetup, setupProgress.client == nil { setupProgress.client = client }
        // The app link carries the pairing token, so it identifies the phone even if its address differs.
        if event == .openedApp { setupProgress.client = client; setupProgress.openedApp = true; setupProgress.trusts = true }
        guard client == setupProgress.client else { return }
        switch event {
        case .openedSetup, .openedApp: break
        case .downloadedProfile: setupProgress.downloadedProfile = true
        case .secureRequest: setupProgress.trusts = true
        }
    }

    /// A fresh token for the pairing QR code, and a fresh typed code. Any unused previous token is dropped.
    func newPairing() {
        if let pending = pendingToken { pairings.removeAll { $0.token == pending && $0.lastSyncAt == nil } }
        let token = Self.makeToken()
        pairings.append(Pairing(token: token, name: "New phone", createdAt: Date()))
        pendingToken = token
        newCode()
        savePairings()
    }

    /// A new typed code, valid for 15 minutes. It's independent of the QR code: scanning the QR code
    /// pairs Safari, and the code then still pairs the app added to the Home Screen.
    func newCode() {
        // No 0/O, 1/I/L: easy to read off the screen and type.
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var codeBytes = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, codeBytes.count, &codeBytes)
        pendingCode = String(codeBytes.map { alphabet[Int($0) % alphabet.count] })
        pendingCodeExpires = Date().addingTimeInterval(Self.codeLifetime)
        failedCodeAttempts = 0
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    enum CodeResult { case token(String), wrong, expired, tooMany }

    /// Swaps the typed code for a pairing of its own, once. Too many wrong tries void the code.
    fileprivate func redeem(code: String) -> CodeResult {
        guard let pending = pendingCode, Date() < pendingCodeExpires else { return .expired }
        guard failedCodeAttempts < Self.maxCodeAttempts else { return .tooMany }
        let typed = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard typed == pending else {
            failedCodeAttempts += 1
            if failedCodeAttempts >= Self.maxCodeAttempts { pendingCode = nil }
            return .wrong
        }
        pendingCode = nil
        let token = Self.makeToken()
        codeToken = token
        pairings.append(Pairing(token: token, name: "New phone", createdAt: Date()))
        savePairings()
        return .token(token)
    }

    #if DEBUG
    func addDebugPairing(_ token: String) {
        if !pairings.contains(where: { $0.token == token }) {
            pairings.append(Pairing(token: token, name: "Debug", createdAt: Date()))
        }
    }
    #endif

    func revoke(_ pairing: Pairing) {
        pairings.removeAll { $0.token == pairing.token }
        if pendingToken == pairing.token { pendingToken = nil }
        savePairings()
    }

    /// Unpairs every phone, e.g. when this Mac starts over in another household.
    func revokeAll() {
        pairings = []
        pendingToken = nil
        codeToken = nil
        savePairings()
    }

    private func savePairings() {
        if let data = try? SyncCoding.encoder(pretty: false).encode(pairings) { defaults.set(data, forKey: Keys.pairings) }
    }

    fileprivate func authorize(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        return pairings.contains { $0.token == token }
    }

    /// `installed` is false for Safari, whose storage the Home Screen app doesn't share: the pairing
    /// isn't finished until the app itself has synced.
    fileprivate func noteSync(token: String, device: DeviceInfo, installed: Bool, host: String?) {
        guard let i = pairings.firstIndex(where: { $0.token == token }) else { return }
        if let host, !host.isEmpty { pairings[i].host = host }
        pairings[i].name = device.name.isEmpty ? "Phone" : device.name
        pairings[i].deviceId = device.id
        pairings[i].personUid = device.personUid.isEmpty ? nil : device.personUid
        pairings[i].lastSyncAt = Date()
        guard installed else { return }
        if token == pendingToken || token == codeToken { setupProgress.pairedName = pairings[i].name }
        if pendingToken == token { pendingToken = nil }
        if codeToken == token { codeToken = nil }
        savePairings()
    }

    // MARK: Files

    /// The built PWA: bundled in the app, or `Web/dist` next to the sources in development.
    nonisolated static var webRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: Keys.webRoot) { return URL(filePath: custom, directoryHint: .isDirectory) }
        if let bundled = Bundle.main.resourceURL?.appending(path: "Web", directoryHint: .isDirectory),
           FileManager.default.fileExists(atPath: bundled.appending(path: "index.html").path) {
            return bundled
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Web/dist", directoryHint: .isDirectory)
    }

    var hasWebApp: Bool {
        FileManager.default.fileExists(atPath: Self.webRoot.appending(path: "index.html").path)
    }

    // MARK: Requests

    nonisolated private static func handleSecure(_ request: HTTPServer.Request, webRoot: URL) async -> HTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/api/ping"):
            // The setup page's trust check: getting this far means the device trusts the certificate.
            let joined = await MainActor.run {
                PhoneServer.shared.note(.secureRequest, from: request.client)
                return Household.shared.isJoined
            }
            return .json(200, ["app": "upkeep", "schemaVersion": Snapshot.currentVersion, "household": joined])
        case ("POST", "/api/sync"):
            return await handleSync(request)
        case ("POST", "/api/pair"):
            return await handlePair(request)
        case ("GET", "/"), ("GET", "/index.html"):
            return await appShell(request, root: webRoot)
        case ("GET", "/api/push/key"), ("POST", "/api/push/subscribe"), ("POST", "/api/push/unsubscribe"):
            return await handlePush(request)
        case (_, "/api/sync"), (_, "/api/ping"), (_, "/api/push/key"), (_, "/api/push/subscribe"), (_, "/api/push/unsubscribe"):
            return .text(405, "Method not allowed")
        case ("GET", "/setup"), ("GET", "/upkeep.mobileconfig"):
            return await handleSetup(request)
        case ("GET", "/manifest.webmanifest") where request.query.contains("pair="):
            return await pairedManifest(request, root: webRoot)
        case ("GET", _), ("HEAD", _):
            return staticFile(request.path, root: webRoot)
        default:
            return .text(405, "Method not allowed")
        }
    }

    nonisolated private static func handleSync(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let token = bearer(request)
        guard await MainActor.run(body: { PhoneServer.shared.authorize(token) }), let token else {
            return .json(401, ["error": "unauthorized"])
        }
        struct Header: Decodable { var format: String?; var schemaVersion: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: request.body),
              header.format == Snapshot.formatID, let version = header.schemaVersion else {
            return .json(400, ["error": "notASnapshot"])
        }
        if version < Snapshot.currentVersion { return .json(409, ["error": "updateRequired", "schemaVersion": Snapshot.currentVersion]) }
        if version > Snapshot.currentVersion { return .json(422, ["error": "newerVersion", "schemaVersion": Snapshot.currentVersion]) }
        let snapshot: Snapshot
        do { snapshot = try Snapshot.decode(request.body) } catch { return .json(400, ["error": "damaged"]) }

        // A phone still holding another household's copy (its Mac was reset or replaced) is turned
        // away before anything merges; it asks its user to replace that copy (Docs/Sync.md).
        let otherHousehold: String? = await MainActor.run {
            let decision = HouseholdCheck.decide(
                phoneHousehold: snapshot.device.householdId, macHousehold: Household.shared.householdId,
                phoneUids: Set(snapshot.records.map(\.uid)).union(snapshot.tombstones.map(\.uid)),
                macUids: SyncManager.shared.localUids())
            return decision == .otherHousehold ? Household.shared.deviceName : nil
        }
        if let otherHousehold { return .json(409, ["error": "otherHousehold", "household": otherHousehold]) }

        let merged: Snapshot? = await MainActor.run {
            // Older phone apps don't say; count them as installed.
            PhoneServer.shared.noteSync(token: token, device: snapshot.device,
                                        installed: request.header("x-upkeep-display") != "browser",
                                        host: request.header("host")?.split(separator: ":").first.map(String.init)?.lowercased())
            return SyncManager.shared.mergeFromPhone(snapshot)
        }
        guard let merged, let data = try? merged.encoded() else { return .json(503, ["error": "unavailable"]) }
        return HTTPServer.Response(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
    }

    nonisolated private static func bearer(_ request: HTTPServer.Request) -> String? {
        let auth = request.header("authorization") ?? ""
        return auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : nil
    }

    nonisolated private static func handlePush(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        let token = bearer(request)
        guard await MainActor.run(body: { PhoneServer.shared.authorize(token) }) else {
            return .json(401, ["error": "unauthorized"])
        }
        switch request.path {
        case "/api/push/key":
            guard let key = await MainActor.run(body: { try? WebPush.shared.signingKey() }) else { return .json(503, ["error": "unavailable"]) }
            return .json(200, ["publicKey": VAPID.publicKeyString(key)])
        case "/api/push/subscribe":
            struct Body: Decodable {
                struct Sub: Decodable { struct Keys: Decodable { var p256dh: String; var auth: String }; var endpoint: String; var keys: Keys }
                var deviceId: String
                var personUid: String
                var subscription: Sub
            }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body),
                  URL(string: body.subscription.endpoint)?.scheme == "https" else {
                return .json(400, ["error": "badSubscription"])
            }
            await MainActor.run {
                let phoneName = PhoneServer.shared.pairings.first { $0.token == token }?.name ?? ""
                WebPush.shared.subscribe(deviceId: body.deviceId, phoneName: phoneName, personUid: body.personUid,
                                         endpoint: body.subscription.endpoint,
                                         p256dh: body.subscription.keys.p256dh, auth: body.subscription.keys.auth)
            }
            return HTTPServer.Response(status: 204)
        default:
            struct Body: Decodable { var deviceId: String }
            guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else { return .json(400, ["error": "badRequest"]) }
            await MainActor.run { WebPush.shared.unsubscribe(deviceId: body.deviceId) }
            return HTTPServer.Response(status: 204)
        }
    }

    nonisolated private static func handlePair(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        struct Body: Decodable { var code: String }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else { return .json(400, ["error": "badRequest"]) }
        switch await MainActor.run(body: { PhoneServer.shared.redeem(code: body.code) }) {
        case .token(let token): return HTTPServer.Response(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
                                                           body: (try? JSONSerialization.data(withJSONObject: ["token": token])) ?? Data())
        case .wrong, .expired: return .json(404, ["error": "unknownCode"])
        case .tooMany: return .json(429, ["error": "tooManyAttempts"])
        }
    }

    /// The app page. Opened from the pairing QR code (`/?pair=…`), its manifest link carries the
    /// token too, so "Add to Home Screen" installs an icon that opens already paired.
    nonisolated private static func appShell(_ request: HTTPServer.Request, root: URL) async -> HTTPServer.Response {
        var response = staticFile("/", root: root)
        let token = URLComponents(string: "/?\(request.query)")?.queryItems?.first { $0.name == "pair" }?.value
        guard response.status == 200, let token, await MainActor.run(body: { PhoneServer.shared.authorize(token) }),
              var html = String(data: response.body, encoding: .utf8) else { return response }
        await MainActor.run {
            if token == PhoneServer.shared.pendingToken { PhoneServer.shared.note(.openedApp, from: request.client) }
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        html = html.replacingOccurrences(of: "href=\"/manifest.webmanifest\"", with: "href=\"/manifest.webmanifest?pair=\(encoded)\"")
        response.body = Data(html.utf8)
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    /// The manifest with the pairing token in `start_url`, so the Home Screen icon opens already
    /// paired: iOS keeps an installed web app's storage separate from Safari's.
    nonisolated private static func pairedManifest(_ request: HTTPServer.Request, root: URL) async -> HTTPServer.Response {
        let token = URLComponents(string: "/?\(request.query)")?.queryItems?.first { $0.name == "pair" }?.value
        guard await MainActor.run(body: { PhoneServer.shared.authorize(token) }), let token,
              let data = try? Data(contentsOf: root.appending(path: "manifest.webmanifest")),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return staticFile(request.path, root: root)
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        manifest["id"] = manifest["id"] ?? "/"
        manifest["start_url"] = "/?pair=\(token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token)"
        let body = (try? JSONSerialization.data(withJSONObject: manifest, options: [.withoutEscapingSlashes])) ?? data
        return HTTPServer.Response(status: 200, headers: ["Content-Type": "application/manifest+json", "Cache-Control": "no-store"], body: body)
    }

    nonisolated private static func staticFile(_ path: String, root: URL) -> HTTPServer.Response {
        let clean = path.split(separator: "/").filter { $0 != ".." && $0 != "." && !$0.isEmpty }.joined(separator: "/")
        var url = clean.isEmpty ? root.appending(path: "index.html") : root.appending(path: clean)
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || isDir.boolValue {
            // App routes fall back to the app shell; missing assets are real 404s.
            guard !clean.contains(".") else { return .text(404, "Not found") }
            url = root.appending(path: "index.html")
        }
        guard url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: url) else {
            return .text(404, "Not found — build the web app (Web › npm run build).")
        }
        let name = url.lastPathComponent
        let cache = clean.hasPrefix("assets/") ? "public, max-age=31536000, immutable" : "no-cache"
        return HTTPServer.Response(status: 200, headers: ["Content-Type": contentType(name), "Cache-Control": cache], body: data)
    }

    nonisolated private static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": "text/html; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "json": "application/json"
        case "webmanifest": "application/manifest+json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "ico": "image/x-icon"
        case "woff2": "font/woff2"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    // MARK: Setup page

    nonisolated private static func handleSetup(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        switch request.path {
        case "/upkeep.mobileconfig":
            await MainActor.run { PhoneServer.shared.note(.downloadedProfile, from: request.client) }
            guard let data = try? Certificates.mobileConfig() else { return .text(503, "Certificate not ready") }
            return HTTPServer.Response(status: 200, headers: [
                "Content-Type": "application/x-apple-aspen-config",
                "Content-Disposition": "attachment; filename=\"Upkeep.mobileconfig\"",
            ], body: data)
        case "/setup":
            let appURL = await MainActor.run {
                PhoneServer.shared.note(.openedSetup, from: request.client)
                return PhoneServer.shared.appURL
            }
            return HTTPServer.Response(status: 200, headers: ["Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache"],
                                       body: Data(setupPage(appURL: appURL).utf8))
        default:
            return .redirect("/setup")
        }
    }

    nonisolated private static func setupPage(appURL: String) -> String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Set up Upkeep</title>
        <style>
        :root { color-scheme: light dark; --accent: #007AFF; }
        body { font: 17px/1.45 -apple-system, system-ui, sans-serif; margin: 0; padding: 24px 20px 48px; max-width: 560px; margin-inline: auto; }
        h1 { font-size: 28px; margin: 8px 0 4px; }
        p.lead { color: color-mix(in srgb, currentColor 60%, transparent); margin-top: 0; }
        ol { padding-left: 0; list-style: none; counter-reset: s; }
        li { counter-increment: s; position: relative; padding: 14px 16px 14px 56px; margin: 12px 0; border-radius: 14px;
             background: color-mix(in srgb, currentColor 6%, transparent); }
        li::before { content: counter(s); position: absolute; left: 16px; top: 14px; width: 28px; height: 28px; border-radius: 50%;
                     background: var(--accent); color: white; font-weight: 600; display: grid; place-items: center; font-size: 15px; }
        a.button { display: inline-block; margin-top: 8px; padding: 10px 16px; border-radius: 10px; background: var(--accent);
                   color: white; text-decoration: none; font-weight: 600; }
        code { font: 15px ui-monospace, monospace; }
        .status { margin-top: 10px; padding: 10px 12px; border-radius: 10px; font-weight: 600;
                  background: color-mix(in srgb, currentColor 8%, transparent); }
        .status.ok { background: #34C75926; color: #248A3D; }
        .status.bad { background: #FF950026; color: #C93400; }
        .status button { margin-left: 8px; font: inherit; font-weight: 400; color: var(--accent); background: none; border: 0; padding: 0; }
        </style></head><body>
        <h1>Set up Upkeep</h1>
        <p class="lead">Do this once on each iPhone or iPad, in Safari.</p>
        <ol>
        <li><strong>Download the profile.</strong> Safari asks to allow the download.<br>
            <a class="button" href="/upkeep.mobileconfig">Download Profile</a></li>
        <li><strong>Install it:</strong> Settings › General › VPN &amp; Device Management › <em>Upkeep</em> › Install.</li>
        <li><strong>Trust it:</strong> Settings › General › About › Certificate Trust Settings › turn on <em>Upkeep Home CA</em>.
            Installing alone isn’t enough — without this switch Safari says the connection isn’t private.
            <div id="trust" class="status">Checking…</div></li>
        <li><strong>Scan the next QR code</strong> the Mac shows (Upkeep moves on by itself once this device trusts it).
            It opens <code>\(appURL)</code> signed in.</li>
        <li><strong>Add to Home Screen:</strong> tap Share › Add to Home Screen (keep “Open as Web App” on), then open Upkeep from its icon. No address to type after that.</li>
        </ol>
        <script>
        // An https request from this http page only succeeds if the phone trusts the certificate.
        // (no-cors: we only care whether the TLS handshake works, not about the answer.)
        const box = document.getElementById('trust');
        async function check() {
          box.className = 'status'; box.textContent = 'Checking…';
          try {
            await fetch('\(appURL)api/ping?t=' + Date.now(), { mode: 'no-cors', cache: 'no-store' });
            box.className = 'status ok';
            box.textContent = '✓ This device trusts Upkeep. Go on with step 4 — the Mac shows the next QR code.';
          } catch (e) {
            box.className = 'status bad';
            // This page came from the Mac, so it's reachable: the secure connection is what failed.
            box.innerHTML = 'This device doesn’t trust Upkeep yet. Check: the profile is installed (step 2), and the ' +
              '“Upkeep Home CA” switch is on (step 3). If both are done, remove the profile and install it again — ' +
              'it may be from an older certificate. <button onclick="check()">Check again</button>';
          }
        }
        check();
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') check(); });
        </script>
        </body></html>
        """
    }
}
