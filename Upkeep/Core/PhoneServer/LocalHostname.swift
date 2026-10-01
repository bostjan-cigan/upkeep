import Foundation
import Network
import OSLog
import dnssd

/// Answers this Mac's phone names — `upkeep-bostjan.local`, and `upkeep.local` for phones set up
/// with an older version — on the home network with this Mac's address (multicast DNS).
///
/// A fixed name keeps the phones' origin, and so their home-screen app and stored data, the same
/// even if this Mac is renamed or gets a new IP address. Re-registers on network changes. When a
/// name can't be claimed, `states` says why — another device has it, or macOS isn't letting Upkeep
/// use the local network — and it's tried again a minute later, since after a network change the
/// "other device" is often this Mac's own old record echoed back by the router. Stopping withdraws
/// every name, so other devices drop them at once.
final class LocalHostname: @unchecked Sendable {
    enum Failure: Equatable, Sendable {
        /// Another device on the network answers at this name.
        case taken
        /// macOS refused: Local Network access is off for Upkeep.
        case localNetworkOff
        case other(Int32)

        init(_ error: DNSServiceErrorType) {
            switch error {
            case DNSServiceErrorType(kDNSServiceErr_NameConflict): self = .taken
            case DNSServiceErrorType(kDNSServiceErr_PolicyDenied), DNSServiceErrorType(kDNSServiceErr_NoAuth): self = .localNetworkOff
            default: self = .other(error)
            }
        }
    }

    enum State: Equatable, Sendable {
        case announcing, announced, failed(Failure)
    }

    let names: [String]
    let ttl: UInt32
    private let queue = DispatchQueue(label: "upkeep.mdns")
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Upkeep", category: "mdns")
    private var connection: DNSServiceRef?
    private var registrations: [Registration] = []
    private var monitor: NWPathMonitor?
    private var addresses: [String] = []
    private var retry: DispatchWorkItem?
    static let retryDelay: TimeInterval = 60
    /// Per name, updated on `queue`; a copy goes to `onChange`.
    private var states: [String: State] = [:]
    var onChange: (@Sendable ([String: State]) -> Void)?

    /// Keeps the callback's context alive for as long as the record is registered.
    private final class Registration {
        weak var owner: LocalHostname?
        let name: String
        init(owner: LocalHostname, name: String) { self.owner = owner; self.name = name }
    }

    init(names: [String], ttl: UInt32 = 120) {
        self.names = names
        self.ttl = ttl
    }

    func start() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in self?.refresh() }
        monitor.start(queue: queue)
        self.monitor = monitor
        queue.async { self.refresh() }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        queue.sync {
            self.retry?.cancel()
            self.retry = nil
            self.teardown()
            self.log.notice("withdrew \(self.names.joined(separator: ", "), privacy: .public)")
        }
    }

    /// Withdraws every name and claims them again straight away, forgetting any "try again in a minute".
    func reset() {
        queue.async {
            self.retry?.cancel()
            self.retry = nil
            self.addresses = []
            self.teardown()
            self.log.notice("reset \(self.names.joined(separator: ", "), privacy: .public)")
            self.refresh()
        }
    }

    /// Deregistering sends a goodbye, so other devices drop the name at once rather than at its TTL.
    private func teardown() {
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
        registrations = []
    }

    private func publish() {
        let copy = states
        onChange?(copy)
    }

    private func refresh() {
        let current = Self.interfaceAddresses()
        let key = current.map { "\($0.index)=\($0.address)" }
        guard key != addresses || connection == nil else { return }
        addresses = key
        retry?.cancel()
        retry = nil
        teardown()
        states = Dictionary(uniqueKeysWithValues: names.map { ($0, State.announcing) })
        guard !current.isEmpty else { publish(); return }

        var ref: DNSServiceRef?
        let created = DNSServiceCreateConnection(&ref)
        guard created == kDNSServiceErr_NoError, let ref else {
            log.error("mDNS connection failed: \(created)")
            for name in names { states[name] = .failed(Failure(created)) }
            publish()
            return
        }
        DNSServiceSetDispatchQueue(ref, queue)
        connection = ref
        for name in names {
            let registration = Registration(owner: self, name: name)
            registrations.append(registration)
            let context = Unmanaged.passUnretained(registration).toOpaque()
            for entry in current {
                var addr = in_addr()
                guard inet_pton(AF_INET, entry.address, &addr) == 1 else { continue }
                var record: DNSRecordRef?
                let status = withUnsafeBytes(of: &addr) { bytes in
                    DNSServiceRegisterRecord(ref, &record, DNSServiceFlags(kDNSServiceFlagsUnique), entry.index,
                                             "\(name).", UInt16(kDNSServiceType_A), UInt16(kDNSServiceClass_IN),
                                             UInt16(bytes.count), bytes.baseAddress, ttl, { _, _, _, error, context in
                        guard let context else { return }
                        let registration = Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue()
                        registration.owner?.registered(registration.name, error: error)
                    }, context)
                }
                log.notice("register \(name, privacy: .public) -> \(entry.address, privacy: .public) on if \(entry.index): \(status)")
                if status != kDNSServiceErr_NoError { registered(name, error: status) }
            }
        }
        publish()
    }

    /// Runs on `queue`. One failure on any interface counts for the name.
    private func registered(_ name: String, error: DNSServiceErrorType) {
        if error == kDNSServiceErr_NoError {
            if states[name] == .announcing { states[name] = .announced }
            log.notice("\(name, privacy: .public) announced")
        } else {
            let failure = Failure(error)
            states[name] = .failed(failure)
            log.error("\(name, privacy: .public) couldn't be announced: \(error) (\(String(describing: failure), privacy: .public))")
            scheduleRetry()
        }
        publish()
    }

    /// Claims the names again later. Runs on `queue` (the callback's queue).
    private func scheduleRetry() {
        guard retry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.retry != nil else { return }
            self.retry = nil
            self.addresses = []
            self.refresh()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + Self.retryDelay, execute: work)
    }

    /// Active IPv4 addresses on Wi-Fi and Ethernet interfaces.
    private static func interfaceAddresses() -> [(index: UInt32, address: String)] {
        var result: [(UInt32, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let sa = entry.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((if_nametoindex(name), String(cString: host)))
        }
        return result
    }

    /// The first address, for display.
    var primaryAddress: String? {
        Self.interfaceAddresses().first?.address
    }
}
