import CryptoKit
import Foundation

// The household sync format and merge, independent of SwiftData so it can be tested on its own.
// The contract, shared with the PWA, is `Docs/Sync.md`.

// MARK: JSON

/// An arbitrary JSON value: record data is kept generic so kinds from newer builds survive untouched.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers are written without a fraction, like JavaScript does.
            if n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// Converts any Codable value (dates as sync date strings) to JSON.
    static func from<T: Encodable>(_ value: T) -> JSONValue {
        let data = (try? SyncCoding.encoder(pretty: false).encode(value)) ?? Data("null".utf8)
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    /// Decodes JSON into a Codable value (dates from sync date strings).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try SyncCoding.decoder().decode(T.self, from: data)
    }

    /// Stable text for change detection: sorted keys, no whitespace.
    var canonical: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var digest: String { SyncCoding.sha256(canonical) }
}

/// Typed access and construction for record data.
extension JSONValue {
    static func date(_ d: Date?) -> JSONValue { d.map { .string(SyncCoding.dateString($0)) } ?? .null }
    static func int(_ i: Int) -> JSONValue { .number(Double(i)) }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var dateValue: Date? { stringValue.flatMap(SyncCoding.parseDate) }
    var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    var intValue: Int? { if case .number(let n) = self, n.isFinite { Int(n) } else { nil } }
}

// MARK: Dates & coding

enum SyncCoding {
    /// UTC ISO 8601 with milliseconds ("2026-09-21T15:07:39.801Z"), rounded rather than
    /// truncated so a decoded date re-encodes to the same text.
    static func dateString(_ date: Date) -> String {
        var (seconds, millis) = Int64((date.timeIntervalSince1970 * 1000).rounded()).quotientAndRemainder(dividingBy: 1000)
        if millis < 0 { seconds -= 1; millis += 1000 }
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(.iso8601)
        return whole.dropLast() + String(format: ".%03lldZ", millis)
    }

    /// Accepts dates with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    /// Dates rounded to whole milliseconds, as they survive a round trip through the file.
    static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func encoder(pretty: Bool = true) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateString(date))
        }
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date: \(text)")
            }
            return date
        }
        return d
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Records

struct SyncRecord: Codable, Hashable, Sendable {
    var kind: String
    var uid: String
    var modifiedAt: Date
    var modifiedBy: String
    var data: JSONValue

    /// Whether this edit wins over `other` for the same uid.
    func wins(over other: SyncRecord) -> Bool {
        if modifiedAt != other.modifiedAt { return modifiedAt > other.modifiedAt }
        if modifiedBy != other.modifiedBy { return modifiedBy > other.modifiedBy }
        // Same stamp, different data (shouldn't happen): pick deterministically, whatever the order.
        return data.canonical > other.data.canonical
    }
}

struct SyncTombstone: Codable, Hashable, Sendable {
    var kind: String
    var uid: String
    var deletedAt: Date
    var deletedBy: String

    func wins(over other: SyncTombstone) -> Bool {
        if deletedAt != other.deletedAt { return deletedAt > other.deletedAt }
        return deletedBy > other.deletedBy
    }
}

struct DeviceInfo: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var platform: String
    var personUid: String
    var build: String
    /// The household this copy belongs to (`household.json`). Missing from older builds' files.
    var householdId: String? = nil
}

enum SnapshotError: LocalizedError {
    case notASnapshot, newerVersion(Int), damaged

    var errorDescription: String? {
        switch self {
        case .notASnapshot: "This file isn't an Upkeep household file."
        case .newerVersion(let v): "This file was made by a newer version of Upkeep (format \(v)). Update Upkeep on this device to read it."
        case .damaged: "This file is damaged and can't be read."
        }
    }
}

/// A device's whole replica: what goes into `devices/<deviceId>.json`, backups and `/api/sync`.
struct Snapshot: Codable, Sendable {
    static let formatID = "com.bostjancigan.upkeep.household"
    static let currentVersion = 1
    /// Tombstones older than this are dropped on export.
    static let tombstoneLifetime: TimeInterval = 365 * 24 * 3600

    var format = formatID
    var schemaVersion = currentVersion
    var exportedAt: Date
    var device: DeviceInfo
    var records: [SyncRecord]
    var tombstones: [SyncTombstone]

    init(device: DeviceInfo, records: [SyncRecord], tombstones: [SyncTombstone], at date: Date = Date()) {
        exportedAt = date
        self.device = device
        self.records = records.sorted { ($0.kind, $0.uid) < ($1.kind, $1.uid) }
        let cutoff = date.addingTimeInterval(-Self.tombstoneLifetime)
        self.tombstones = tombstones.filter { $0.deletedAt >= cutoff }.sorted { ($0.kind, $0.uid) < ($1.kind, $1.uid) }
    }

    private struct Header: Decodable {
        var format: String?
        var schemaVersion: Int?
    }

    /// Reads the header before the body, so a newer or foreign file gets a clear error.
    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = SyncCoding.decoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == formatID,
              let version = header.schemaVersion else { throw SnapshotError.notASnapshot }
        guard version <= currentVersion else { throw SnapshotError.newerVersion(version) }
        do { return try decoder.decode(Snapshot.self, from: data) } catch { throw SnapshotError.damaged }
    }

    func encoded() throws -> Data { try SyncCoding.encoder().encode(self) }

    /// Hash of the data only (not who or when), used to skip rewriting identical files.
    var contentDigest: String {
        let e = SyncCoding.encoder(pretty: false)
        let r = (try? e.encode(records)) ?? Data()
        let t = (try? e.encode(tombstones)) ?? Data()
        return SyncCoding.sha256(String(decoding: r + t, as: UTF8.self))
    }

    func count(of kind: String) -> Int { records.filter { $0.kind == kind }.count }
}

// MARK: Merge

/// The result of merging replicas: every surviving record and every tombstone, by uid.
struct MergeResult: Sendable {
    var records: [String: SyncRecord] = [:]
    var tombstones: [String: SyncTombstone] = [:]

    /// Latest edit or deletion time seen, for the hybrid clock.
    var maxStamp: Date {
        let r = records.values.map(\.modifiedAt).max() ?? .distantPast
        let t = tombstones.values.map(\.deletedAt).max() ?? .distantPast
        return max(r, t)
    }
}

/// Last-writer-wins per record, tombstones as a union. Commutative, associative and idempotent,
/// so every device that has read the same files ends up with the same state.
enum Merge {
    static func merge(_ sets: [(records: [SyncRecord], tombstones: [SyncTombstone])]) -> MergeResult {
        var result = MergeResult()
        for set in sets {
            for t in set.tombstones {
                if let existing = result.tombstones[t.uid], !t.wins(over: existing) { continue }
                result.tombstones[t.uid] = t
            }
            for r in set.records {
                if let existing = result.records[r.uid], !r.wins(over: existing) { continue }
                result.records[r.uid] = r
            }
        }
        // A deletion removes every edit made before it; a later re-creation survives.
        for (uid, record) in result.records {
            if let t = result.tombstones[uid], t.deletedAt >= record.modifiedAt {
                result.records[uid] = nil
            }
        }
        return result
    }

    static func merge(_ snapshots: [Snapshot]) -> MergeResult {
        merge(snapshots.map { ($0.records, $0.tombstones) })
    }
}

// MARK: Clock

/// Hybrid logical clock: stamps never go below anything already seen, so a Mac whose clock
/// runs slow can't write an edit that loses to data it has already merged.
final class HybridClock: @unchecked Sendable {
    private let lock = NSLock()
    /// Nil for a clock that only lives in memory (tests), which leaves no settings behind.
    private let defaults: UserDefaults?
    private let key: String
    private var remembered = Date.distantPast

    init(defaults: UserDefaults = .standard, key: String = "syncClockMaxSeen") {
        self.defaults = defaults
        self.key = key
    }

    /// A clock that keeps what it has seen in memory only.
    init(inMemory: Void = ()) {
        defaults = nil
        key = ""
    }

    private var maxSeen: Date {
        get {
            guard let defaults else { return remembered }
            let v = defaults.double(forKey: key)
            return v > 0 ? Date(timeIntervalSince1970: v) : .distantPast
        }
        set {
            guard let defaults else { remembered = newValue; return }
            defaults.set(newValue.timeIntervalSince1970, forKey: key)
        }
    }

    func now(_ wall: Date = Date()) -> Date {
        lock.lock(); defer { lock.unlock() }
        let t = max(SyncCoding.normalized(wall), maxSeen.addingTimeInterval(0.001))
        maxSeen = SyncCoding.normalized(t)
        return maxSeen
    }

    func observe(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        if date > maxSeen { maxSeen = date }
    }
}

