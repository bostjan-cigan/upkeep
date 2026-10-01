import CryptoKit
import Foundation

// Checks for the pure sync core, scheduling and Web Push crypto. Run with Tools/test-core.sh.

var failures = 0
var passes = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition() { passes += 1 } else { failures += 1; print("FAIL \(line): \(message)") }
}

func date(_ s: String) -> Date { SyncCoding.parseDate(s)! }

func rec(_ kind: String, _ uid: String, _ at: String, by: String = "A", _ data: [String: JSONValue] = [:]) -> SyncRecord {
    SyncRecord(kind: kind, uid: uid, modifiedAt: date(at), modifiedBy: by, data: .object(data))
}

func tomb(_ uid: String, _ at: String, by: String = "A", kind: String = "task") -> SyncTombstone {
    SyncTombstone(kind: kind, uid: uid, deletedAt: date(at), deletedBy: by)
}

func normalized(_ r: MergeResult) -> String {
    let e = SyncCoding.encoder(pretty: false)
    let records = r.records.values.sorted { $0.uid < $1.uid }
    let tombs = r.tombstones.values.sorted { $0.uid < $1.uid }
    return String(decoding: (try! e.encode(records)) + (try! e.encode(tombs)), as: UTF8.self)
}

// MARK: Dates & JSON

check(SyncCoding.dateString(date("2026-09-22T10:15:00Z")) == "2026-09-22T10:15:00.000Z", "ISO without fraction")
check(SyncCoding.dateString(Date(timeIntervalSince1970: 1.2345)) == "1970-01-01T00:00:01.235Z", "ms rounding")
check(SyncCoding.dateString(date("2026-09-22T10:15:00.123Z")) == "2026-09-22T10:15:00.123Z", "ms round trip")
check(JSONValue.object(["b": .number(3), "a": .array([.bool(true), .null]), "c": .string("x/y")]).canonical
      == #"{"a":[true,null],"b":3,"c":"x/y"}"#, "canonical JSON")
check(JSONValue.number(2.5).canonical == "2.5", "fractions kept")

// MARK: Merge

let A = [rec("task", "t1", "2026-01-01T00:00:01.000Z", by: "A", ["title": .string("A1")]),
         rec("person", "p1", "2026-01-01T00:00:00.000Z", by: "A", ["name": .string("Ana")]),
         rec("shoppingEntry", "s1", "2026-01-05T00:00:00.000Z", by: "A", ["text": .string("Milk"), "extra": .object(["q": .number(2)])])]
let B = [rec("task", "t1", "2026-01-01T00:00:02.000Z", by: "B", ["title": .string("B1")]),
         rec("task", "t2", "2026-01-01T00:00:00.000Z", by: "B", ["title": .string("gone")]),
         rec("taskLog", "l1", "2026-01-02T00:00:00.000Z", by: "B", ["taskUid": .string("t1")])]
let Bt = [tomb("t2", "2026-01-03T00:00:00.000Z", by: "B")]
let C = [rec("task", "t1", "2026-01-01T00:00:02.000Z", by: "C", ["title": .string("C1")]),
         rec("task", "t3", "2026-02-01T00:00:00.000Z", by: "C", ["title": .string("recreated")])]
let Ct = [tomb("t3", "2026-01-15T00:00:00.000Z", by: "A"), tomb("t2", "2026-01-02T00:00:00.000Z", by: "C")]

let ab = Merge.merge([(A, []), (B, Bt)])
let ba = Merge.merge([(B, Bt), (A, [])])
check(normalized(ab) == normalized(ba), "commutative")
check(normalized(Merge.merge([(A, []), (A, [])])) == normalized(Merge.merge([(A, [])])), "idempotent")
let abc1 = Merge.merge([(A, []), (B, Bt), (C, Ct)])
let abThenC = Merge.merge([(Array(ab.records.values), Array(ab.tombstones.values)), (C, Ct)])
let bcThenA = { () -> MergeResult in
    let bc = Merge.merge([(B, Bt), (C, Ct)])
    return Merge.merge([(A, []), (Array(bc.records.values), Array(bc.tombstones.values))])
}()
check(normalized(abc1) == normalized(abThenC) && normalized(abc1) == normalized(bcThenA), "associative")
check(abc1.records["t1"]?.data["title"]?.stringValue == "C1", "same time: greater modifiedBy wins")
check(ab.records["t1"]?.data["title"]?.stringValue == "B1", "later edit wins")
check(abc1.records["t2"] == nil, "tombstone deletes older record")
check(abc1.tombstones["t2"]?.deletedBy == "B", "newest tombstone kept")
check(abc1.records["t3"]?.data["title"]?.stringValue == "recreated", "record newer than tombstone survives")
check(abc1.tombstones["t3"] != nil, "tombstone kept after re-creation")
check(abc1.records["s1"]?.data == A[2].data, "unknown kind passes through verbatim")
check(abc1.records["l1"] != nil, "missing is not deleted")

// MARK: Snapshot

let device = DeviceInfo(id: "A", name: "Mac", platform: "mac", personUid: "p1", build: "1")
let snap = Snapshot(device: device, records: A, tombstones: [tomb("old", "2020-01-01T00:00:00.000Z"), tomb("t9", "2026-01-01T00:00:00.000Z")],
                    at: date("2026-06-01T00:00:00.000Z"))
check(snap.tombstones.map(\.uid) == ["t9"], "old tombstones dropped on export")
check(snap.records.map(\.uid) == ["p1", "s1", "t1"], "records sorted by kind, uid")
let decoded = try! Snapshot.decode(snap.encoded())
check(decoded.records == snap.records && decoded.tombstones == snap.tombstones, "snapshot round trip")
check(decoded.contentDigest == snap.contentDigest, "digest stable")
var newer = try! JSONSerialization.jsonObject(with: snap.encoded()) as! [String: Any]
newer["schemaVersion"] = 99
do { _ = try Snapshot.decode(JSONSerialization.data(withJSONObject: newer)); check(false, "newer rejected") }
catch SnapshotError.newerVersion(99) { passes += 1 } catch { check(false, "newer error kind") }
do { _ = try Snapshot.decode(Data(#"{"format":"x","schemaVersion":1}"#.utf8)); check(false, "foreign rejected") }
catch SnapshotError.notASnapshot { passes += 1 } catch { check(false, "foreign error kind") }

// MARK: Clock

let clock = HybridClock(inMemory: ())
clock.observe(date("2030-01-01T00:00:00.000Z"))
let t1 = clock.now(date("2026-01-01T00:00:00.000Z"))
let t2 = clock.now(date("2026-01-01T00:00:00.000Z"))
check(t1 > date("2030-01-01T00:00:00.000Z") && t2 > t1, "slow clock still stamps after what it has seen")
let t3 = clock.now(date("2031-01-01T00:00:00.000Z"))
check(t3 == date("2031-01-01T00:00:00.000Z"), "fast wall clock used as is")

// MARK: Schedule

var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "Europe/Ljubljana")!
func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

let jan31 = local(2026, 1, 31, 15)
check(Schedule.derive(kind: .interval, anchorDate: nil, repeats: true, value: 1, unit: .month, baselineDoneAt: jan31,
                      completions: [], calendar: cal).nextDueAt == local(2026, 2, 28), "month end clamps")
check(Schedule.derive(kind: .interval, anchorDate: nil, repeats: true, value: 1, unit: .day, baselineDoneAt: local(2026, 3, 28, 12),
                      completions: [], calendar: cal).nextDueAt == local(2026, 3, 29), "day across DST")
let interval = Schedule.derive(kind: .interval, anchorDate: nil, repeats: true, value: 2, unit: .week, baselineDoneAt: local(2026, 1, 1),
                               completions: [local(2026, 1, 10, 9)], calendar: cal)
check(interval.lastDoneAt == local(2026, 1, 10, 9) && interval.nextDueAt == local(2026, 1, 24), "interval from newest completion")
let never = Schedule.derive(kind: .interval, anchorDate: nil, repeats: true, value: 1, unit: .month, baselineDoneAt: nil,
                            completions: [], now: local(2026, 5, 5, 13), calendar: cal)
check(never.lastDoneAt == nil && never.nextDueAt == local(2026, 5, 5), "never done is due today")

let anchor = local(2026, 9, 15)
func yearly(_ completions: [Date]) -> Date {
    Schedule.derive(kind: .fixedDate, anchorDate: anchor, repeats: true, value: 1, unit: .year, baselineDoneAt: nil,
                    completions: completions, calendar: cal).nextDueAt
}
check(yearly([]) == anchor, "fixed: first due on anchor")
check(yearly([local(2026, 9, 1)]) == local(2027, 9, 15), "fixed: early completion covers the date")
check(yearly([local(2026, 11, 20)]) == local(2027, 9, 15), "fixed: late completion covers the date")
check(yearly([local(2026, 9, 10), local(2026, 9, 20)]) == local(2027, 9, 15), "fixed: doing it twice around one date does not skip a year")
check(yearly([local(2026, 9, 10), local(2027, 9, 12)]) == local(2028, 9, 15), "fixed: next year's completion counts for next year")
check(yearly([local(2026, 1, 10)]) == anchor, "fixed: completion long before anchor doesn't count")
check(yearly([local(2027, 6, 1)]) == local(2028, 9, 15), "fixed: nearest date wins")
let oneOff = Schedule.derive(kind: .fixedDate, anchorDate: anchor, repeats: false, value: 1, unit: .year, baselineDoneAt: nil,
                             completions: [local(2026, 9, 16)], calendar: cal)
check(oneOff.nextDueAt == anchor && oneOff.lastDoneAt == local(2026, 9, 16), "one-off keeps its date")

// MARK: Hand-overs

let handedAfter = Date(timeIntervalSince1970: 1_790_000_000.123_456)
func current(_ once: String?, after: Date?, lastDone: Date?) -> String {
    Schedule.currentAssignee(assigneeUid: "bo", onceAssigneeUid: once, onceAssigneeAfter: after, lastDoneAt: lastDone)
}
check(current("ana", after: handedAfter, lastDone: handedAfter) == "ana", "hand-over covers the next occurrence")
check(current("ana", after: SyncCoding.normalized(handedAfter), lastDone: handedAfter) == "ana", "hand-over survives the ms round trip")
check(current("ana", after: handedAfter, lastDone: handedAfter.addingTimeInterval(60)) == "bo", "a completion ends the hand-over")
check(current("", after: nil, lastDone: nil) == "", "never-done task handed to everyone")
check(current("", after: nil, lastDone: handedAfter) == "bo", "hand-over made before the first completion lapses")
check(current(nil, after: nil, lastDone: nil) == "bo", "no hand-over, usual person")

// MARK: Web Push (RFC 8291 appendix A)

do {
    let asPrivate = try P256.KeyAgreement.PrivateKey(rawRepresentation: base64URLDecode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))
    let uaPublic = try base64URLDecode("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
    let auth = try base64URLDecode("BTBZMqHH6r4Tts7J_aSIgg")
    let salt = try base64URLDecode("DGv6ra1nlYgDCS1FRnbzlw")
    let body = try WebPushCrypto.encrypt(Data("When I grow up, I want to be a watermelon".utf8), p256dh: uaPublic, auth: auth,
                                         ephemeral: asPrivate, salt: salt)
    check(base64URLEncode(body) == "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN",
          "RFC 8291 test vector")

    let key = P256.Signing.PrivateKey()
    let jwt = try WebPushCrypto.vapidToken(audience: "https://web.push.apple.com", subject: "https://example.com", key: key,
                                           now: Date(timeIntervalSince1970: 1_000_000))
    let parts = jwt.split(separator: ".").map(String.init)
    let sig = try P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
    check(parts.count == 3 && key.publicKey.isValidSignature(sig, for: Data("\(parts[0]).\(parts[1])".utf8)), "VAPID JWT verifies")
    let claims = try JSONSerialization.jsonObject(with: base64URLDecode(parts[1])) as! [String: Any]
    check(claims["aud"] as? String == "https://web.push.apple.com" && claims["exp"] as? Int == 1_000_000 + 43_200, "VAPID claims")
} catch {
    check(false, "web push threw \(error)")
}

// MARK: Shared fixtures with the PWA

let fixtures = URL(filePath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Web/test/fixtures")
if let a = try? Data(contentsOf: fixtures.appending(path: "deviceA.json")),
   let b = try? Data(contentsOf: fixtures.appending(path: "deviceB.json")),
   let expected = try? Data(contentsOf: fixtures.appending(path: "merged.expected.json")) {
    do {
        let sa = try Snapshot.decode(a), sb = try Snapshot.decode(b)
        let merged = Merge.merge([sa, sb])
        struct Expected: Decodable { var records: [SyncRecord]; var tombstones: [SyncTombstone] }
        let exp = try SyncCoding.decoder().decode(Expected.self, from: expected)
        let gotRecords = merged.records.values.sorted { ($0.kind, $0.uid) < ($1.kind, $1.uid) }
        let gotTombs = merged.tombstones.values.sorted { ($0.kind, $0.uid) < ($1.kind, $1.uid) }
        check(gotRecords == exp.records.sorted { ($0.kind, $0.uid) < ($1.kind, $1.uid) }, "fixtures: merged records match the PWA")
        check(gotTombs == exp.tombstones.sorted { ($0.kind, $0.uid) < ($1.kind, $1.uid) }, "fixtures: merged tombstones match the PWA")
        check(normalized(Merge.merge([sb, sa])) == normalized(merged), "fixtures: commutative")
    } catch {
        check(false, "fixtures: \(error)")
    }
} else {
    print("note: no shared fixtures at \(fixtures.path) yet")
}

// Scheduling cases shared with the PWA, so snapping and shifts can't drift between the two.
struct ScheduleCase: Decodable {
    var name: String
    var scheduleKind: String
    var intervalValue: Int
    var intervalUnit: String
    var repeats: Bool
    var anchorDate: String?
    var baselineDoneAt: String?
    var completions: [String]
    var preferredDays: String
    var shiftedFrom: String?
    var shiftedTo: String?
    var now: String
    var expectedDue: String
}
struct ScheduleCases: Decodable { var timeZone: String; var cases: [ScheduleCase] }

if let data = try? Data(contentsOf: fixtures.appending(path: "schedule.cases.json")) {
    do {
        let file = try JSONDecoder().decode(ScheduleCases.self, from: data)
        var caseCal = Calendar(identifier: .gregorian)
        caseCal.timeZone = TimeZone(identifier: file.timeZone)!
        /// "2026-09-22" or "2026-09-22 15:00", in the file's time zone.
        func localDate(_ s: String) -> Date? {
            let parts = s.split(separator: " ")
            let ymd = parts[0].split(separator: "-").compactMap { Int($0) }
            guard ymd.count == 3 else { return nil }
            let hm = parts.count > 1 ? parts[1].split(separator: ":").compactMap { Int($0) } : []
            return caseCal.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2],
                                                     hour: hm.first ?? 0, minute: hm.count > 1 ? hm[1] : 0))
        }
        for c in file.cases {
            guard let kind = ScheduleKind(rawValue: c.scheduleKind), let unit = IntervalUnit(rawValue: c.intervalUnit),
                  let now = localDate(c.now), let expected = localDate(c.expectedDue) else {
                check(false, "schedule case unreadable: \(c.name)")
                continue
            }
            var shift: (from: Date, to: Date)?
            if let from = c.shiftedFrom.flatMap(localDate), let to = c.shiftedTo.flatMap(localDate) {
                shift = (from: from, to: to)
            }
            let got = Schedule.derive(kind: kind, anchorDate: c.anchorDate.flatMap(localDate), repeats: c.repeats,
                                      value: c.intervalValue, unit: unit,
                                      baselineDoneAt: c.baselineDoneAt.flatMap(localDate),
                                      completions: c.completions.compactMap(localDate),
                                      preferredDays: c.preferredDays, shift: shift, now: now,
                                      calendar: caseCal).nextDueAt
            check(got == expected, "schedule case: \(c.name) — got \(got), wanted \(expected)")
        }
    } catch {
        check(false, "schedule cases: \(error)")
    }
} else {
    print("note: no shared schedule cases at \(fixtures.path) yet")
}

// MARK: Catalog shared with the PWA

// The phone adds items from the same catalog; Web/src/modules/maintenance/templates.json is its copy.
struct CatalogFile: Decodable {
    struct Template: Decodable { var id, name, icon, color, category, room: String; var suggestions: [[Suggestion]] }
    enum Suggestion: Decodable, Equatable {
        case text(String), number(Int)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
    }
    var categories: [[String]]
    var templates: [Template]
}
let catalogURL = fixtures.appending(path: "../../src/modules/maintenance/templates.json")
if let data = try? Data(contentsOf: catalogURL), let file = try? JSONDecoder().decode(CatalogFile.self, from: data) {
    let categoryKeys: [TemplateCategory: String] = [.kitchen: "kitchen", .laundry: "laundry", .bathroom: "bathroom", .living: "living",
                                                    .climate: "climate", .cleaning: "cleaning", .safety: "safety", .other: "other"]
    check(file.categories.map { $0[1] } == TemplateCategory.allCases.map(\.rawValue)
          && file.categories.map { $0[0] } == TemplateCategory.allCases.map { categoryKeys[$0] ?? "" }, "catalog: categories match the PWA")
    let mac = ItemTemplate.all.map { t in
        "\(t.id)|\(t.name)|\(t.icon.rawValue)|\(t.color.rawValue)|\(categoryKeys[t.category] ?? "")|\(t.room)|"
            + t.suggestions.map { "\($0.title):\($0.value):\($0.unit.rawValue)" }.joined(separator: ",")
    }
    let web = file.templates.map { t in
        "\(t.id)|\(t.name)|\(t.icon)|\(t.color)|\(t.category)|\(t.room)|" + t.suggestions.map { s in
            s.map { if case .text(let x) = $0 { x } else if case .number(let n) = $0 { String(n) } else { "" } }.joined(separator: ":")
        }.joined(separator: ",")
    }
    check(mac == web, "catalog: templates match the PWA (update templates.json when Catalog.swift changes)")
} else {
    check(false, "catalog: can't read \(catalogURL.path)")
}

// MARK: Phone host names — one name per person, never the real one from a dev build

check(PhoneHostName.slug("Boštjan") == "bostjan", "slug folds accents")
check(PhoneHostName.slug(" Tjaša ") == "tjasa", "slug trims")
check(PhoneHostName.slug("Ana Marie O'Neil") == "ana-marie-o-neil", "slug joins words with dashes")
check(PhoneHostName.slug("🙂") == nil && PhoneHostName.slug("") == nil, "nothing usable, no slug")
check(PhoneHostName.slug(String(repeating: "a", count: 60))?.count == PhoneHostName.maxSlugLength, "slug is capped")
let hostPeople = [(uid: "p1", name: "Boštjan"), (uid: "p2", name: "Tjaša"), (uid: "b", name: "Ana"), (uid: "a", name: "ana")]
check(PhoneHostName.forPerson(uid: "p1", among: hostPeople) == "upkeep-bostjan.local", "Boštjan's Mac")
check(PhoneHostName.forPerson(uid: "p2", among: hostPeople) == "upkeep-tjasa.local", "Tjaša's Mac")
check(PhoneHostName.forPerson(uid: "a", among: hostPeople) == "upkeep-ana.local"
      && PhoneHostName.forPerson(uid: "b", among: hostPeople) == "upkeep-ana-2.local", "two Anas, by uid")
check(PhoneHostName.forPerson(uid: "nobody", among: hostPeople) == nil, "no person, no name")
check(PhoneHostName.custom("Upkeep-Kitchen Mac.local") == "upkeep-kitchen-mac.local", "typed names are cleaned")
check(PhoneHostName.label(of: "upkeep-bostjan.local") == "bostjan", "label for Change…")
let devSuffix = PhoneHostName.randomDevSuffix()
check(devSuffix.count == 6 && devSuffix.allSatisfy(\.isHexDigit), "dev suffix is six hex")
check(PhoneHostName.isDev(PhoneHostName.dev(devSuffix)) && !PhoneHostName.isDev("upkeep-bostjan.local"), "dev names are told apart")

// MARK: Household check — a phone from another household is turned away, not merged

func decide(_ phone: String?, _ mac: String?, _ phoneUids: Set<String>, _ macUids: Set<String>) -> HouseholdCheck.Decision {
    HouseholdCheck.decide(phoneHousehold: phone, macHousehold: mac, phoneUids: phoneUids, macUids: macUids)
}
check(decide("H1", "H1", ["a"], ["b"]) == .merge, "same household merges")
check(decide("H0", "H1", ["old-bostjan"], ["new-bostjan"]) == .otherHousehold, "another household is turned away")
check(decide(nil, "H1", ["p1", "x"], ["p1", "y"]) == .merge, "an older phone sharing records merges")
check(decide(nil, "H1", ["old-bostjan"], ["new-bostjan"]) == .otherHousehold, "an older phone sharing nothing is turned away")
check(decide("H0", "H1", ["p1"], ["p1"]) == .merge, "a household whose id was made again still merges")
check(decide("H0", "H1", [], ["p1"]) == .merge, "an empty phone merges")
check(decide("H0", "H1", ["p1"], []) == .merge, "a Mac with nothing yet merges")
check(decide("H0", nil, ["p1"], ["p2"]) == .merge, "a Mac in no household merges")

// MARK: Push schedule — the usual Mac on time, a helping Mac only if nobody sent it

let slot9 = date("2026-09-27T07:00:00Z"), slot12 = date("2026-09-27T10:00:00Z")
let pushSlots = [slot9, slot12]
func at(_ s: Date, _ minutes: Double) -> Date { s.addingTimeInterval(minutes * 60) }
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 1), isPrimary: true, lastSent: slot9) == slot12, "usual Mac sends on time")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 1), isPrimary: false, lastSent: slot9) == nil, "helper waits for the grace")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 6), isPrimary: false, lastSent: slot9) == slot12, "helper sends after the grace")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 6), isPrimary: false, lastSent: slot12) == nil, "helper skips a slot already sent")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 11), isPrimary: true, lastSent: slot9) == nil, "usual Mac doesn't send late")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 14), isPrimary: false, lastSent: slot9) == slot12, "helper's window has the grace on top")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot12, 16), isPrimary: false, lastSent: slot9) == nil, "helper doesn't send too late either")
check(PushSchedule.slotToSend(slots: pushSlots, now: at(slot9, -1), isPrimary: true, lastSent: nil) == nil, "nothing before a slot")

// MARK: Names — one household, one "Ana"

check(Names.sameName("Ana", "ana"), "case-insensitive")
check(Names.sameName(" Ana ", "Ana"), "trimmed")
check(Names.sameName("Aña", "Ana"), "diacritic-insensitive")
check(!Names.sameName("Ana", "Anna"), "different names stay different")
check(!Names.sameName("", ""), "empty matches nothing")
check(Names.firstMatch("ANA", in: ["Bo", "Ana"]) == 1, "firstMatch finds the twin")
check(Names.firstMatch("Cilka", in: ["Bo", "Ana"]) == nil, "firstMatch misses cleanly")

// MARK: File names — iCloud placeholders

check(FileNames.unwrapped([".A.json.icloud"], suffix: ".json") == ["A.json"], "placeholder unwrapped")
check(FileNames.unwrapped([".A.json.icloud", "A.json"], suffix: ".json") == ["A.json"], "placeholder and file are one name")
check(FileNames.unwrapped([".DS_Store", "A.json"], suffix: ".json") == ["A.json"], "dotfiles dropped")
check(FileNames.unwrapped(["A.txt"], suffix: ".json") == [], "suffix respected")
check(FileNames.unwrapped(["B.json", "A.json"], suffix: ".json") == ["A.json", "B.json"], "sorted")

// MARK: Who has a device

do {
    let covered = HouseholdDevices.peopleWithDevices(peers: ["ana", ""], subscriptions: ["bo"],
                                                     pairings: ["cilka"], me: "me")
    check(covered == ["ana", "bo", "cilka", "me"], "every source counts")
    check(!covered.contains(""), "unclaimed devices don't cover a blank person")
    check(HouseholdDevices.peopleWithDevices(peers: [], subscriptions: [], pairings: [], me: "") == [],
          "nobody, not even a blank me")
}

// MARK: Superseded device files (an iOS "Keep Both" save)

do {
    let files: [(deviceId: String, exportedAt: Date)] = [
        ("phone", date("2026-09-20T10:00:00Z")),   // the stale "Keep Both" copy
        ("phone", date("2026-09-22T10:00:00Z")),
        ("mac", date("2026-09-19T10:00:00Z")),
        ("", date("2026-09-23T10:00:00Z")),        // an unreadable file
    ]
    check(HouseholdDevices.supersededCopies(files) == [0], "only the older copy of the same device")
}

// MARK: Push results

check(PushResult.from(nil) == .delivered, "nil is success")
check(PushResult.from("gone") == .gone, "404/410 means unsubscribed")
check(PushResult.from("Push service said 500") == .failed("Push service said 500"), "anything else carries its message")
check(PushResult.from(nil).testMessage == nil, "a delivered test says nothing")
check(PushResult.from("gone").testMessage?.isEmpty == false, "a gone test explains itself")

// MARK: Up Next buckets — this week's work, and what was ticked off

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Ljubljana")!
    cal.firstWeekday = 2                                  // Monday, as in most of Europe
    let wednesday = date("2026-09-23T09:00:00Z")          // the week runs Mon 21 → Sun 27
    func bucket(due: String, done: String? = nil, active: Bool = true) -> UpNextBucket {
        UpNextBucket.of(due: date(due), lastCompletedAt: done.map(date), isActive: active,
                        now: wednesday, calendar: cal)
    }

    check(UpNextBucket.weekStart(wednesday, calendar: cal) == date("2026-09-20T22:00:00Z"),
          "the week starts on Monday, local time")
    check(bucket(due: "2026-09-21T09:00:00Z") == .overdue, "earlier this week is overdue")
    check(bucket(due: "2026-09-23T20:00:00Z") == .today, "later today is still today")
    check(bucket(due: "2026-09-27T09:00:00Z") == .thisWeek, "Sunday is this week")
    check(bucket(due: "2026-09-28T09:00:00Z") == .hidden, "next Monday is out of sight")
    check(bucket(due: "2026-10-23T09:00:00Z") == .hidden, "a month out is out of sight")

    // Ticked off: due again beyond this week, so it drops below instead of vanishing.
    check(bucket(due: "2026-10-23T09:00:00Z", done: "2026-09-23T08:00:00Z") == .done, "done today")
    check(bucket(due: "2026-10-23T09:00:00Z", done: "2026-09-21T08:00:00Z") == .done, "done on Monday")
    check(bucket(due: "2026-10-23T09:00:00Z", done: "2026-09-19T08:00:00Z") == .hidden, "done last week is gone")
    // A daily chore done this morning comes round again tomorrow — but it's done for today.
    check(bucket(due: "2026-09-24T09:00:00Z", done: "2026-09-23T08:00:00Z") == .done, "done today, due again Thursday")
    // Done yesterday and due again today: there's something to do, so it's back on the list.
    check(bucket(due: "2026-09-23T09:00:00Z", done: "2026-09-22T08:00:00Z") == .today, "due again today wins")
    check(bucket(due: "2026-09-22T09:00:00Z", done: "2026-09-21T08:00:00Z") == .overdue, "overdue again wins")
    // A finished one-off, and a paused task.
    check(bucket(due: "2026-09-23T09:00:00Z", done: "2026-09-23T08:00:00Z", active: false) == .done, "finished today")
    check(bucket(due: "2026-09-23T09:00:00Z", done: "2026-08-01T08:00:00Z", active: false) == .hidden, "finished long ago")
    check(bucket(due: "2026-09-23T09:00:00Z", done: nil, active: false) == .hidden, "paused and never done")
    // "I just did these" leaves no completion, so a new item's tasks never show up as done.
    check(bucket(due: "2026-09-30T09:00:00Z", done: nil) == .hidden, "a typed-in last done isn't a tick")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
