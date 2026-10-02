#if DEBUG
import Foundation
import SwiftData

/// Two in-memory replicas exchanging snapshots through the real SwiftData sync path.
/// Run with `Upkeep -selftest`; prints results and exits with a failure count.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var passes = 0

    private static func check(_ ok: Bool, _ message: String, line: Int = #line) {
        if ok { passes += 1 } else { failures += 1; print("FAIL \(line): \(message)") }
    }

    @MainActor private final class Replica {
        let id: String
        let clock: HybridClock
        let container: ModelContainer
        var context: ModelContext { container.mainContext }

        init(_ id: String) {
            self.id = id
            // In memory, so a run leaves no settings behind.
            clock = HybridClock(inMemory: ())
            container = try! ModelContainer(for: SyncRegistry.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

        func act<T>(_ body: () throws -> T) rethrows -> T {
            SyncStore.deviceOverride = (id, clock)
            defer { SyncStore.deviceOverride = nil }
            return try body()
        }

        func snapshot() -> Snapshot { act { SyncStore.snapshot(of: context) } }
        @discardableResult func merge(_ others: Snapshot...) -> MergeSummary { act { SyncStore.merge(others, into: context) } }
        func stamp() -> Int { act { SyncStore.stampChanges(in: context) } }
        func items() -> [HomeItem] { (try? context.fetch(FetchDescriptor<HomeItem>(sortBy: [SortDescriptor(\.name)]))) ?? [] }
        func tasks() -> [MaintenanceTask] { (try? context.fetch(FetchDescriptor<MaintenanceTask>())) ?? [] }
        func logs() -> [MaintenanceLog] { (try? context.fetch(FetchDescriptor<MaintenanceLog>())) ?? [] }
        func people() -> [Person] { (try? context.fetch(FetchDescriptor<Person>())) ?? [] }
    }

    /// Record data by uid, ignoring who stamped it: two replicas agree when these match.
    private static func state(_ r: Replica) -> [String: String] {
        Dictionary(uniqueKeysWithValues: r.snapshot().records.map { ($0.uid, "\($0.kind)|\($0.data.canonical)|\(SyncCoding.dateString($0.modifiedAt))") })
    }

    static func run() -> Int32 {
        let a = Replica("device-A"), b = Replica("device-B")
        let day: TimeInterval = 86_400

        // A creates the household's first data.
        let ana = Person(name: "Ana", color: .pink)
        a.context.insert(ana)
        let dishwasher = HomeItem(name: "Dishwasher", icon: .dishwasher, color: .blue, room: "Kitchen")
        a.context.insert(dishwasher)
        let filter = MaintenanceTask(title: "Clean the filter", every: 1, .month, lastDone: Date().addingTimeInterval(-40 * day))
        a.context.insert(filter)
        filter.item = dishwasher
        filter.assigneeUid = ana.uid
        try? a.context.save()

        let first = b.merge(a.snapshot())
        check(first.inserted == 3, "B receives person, item, task (got \(first.text))")
        check(b.items().first?.name == "Dishwasher" && b.tasks().first?.item?.name == "Dishwasher", "relationships resolved")
        check(b.tasks().first?.assigneeUid == ana.uid, "assignee synced")
        check(b.tasks().first?.nextDueAt == a.tasks().first?.nextDueAt, "derived due date agrees")
        check(b.stamp() == 0 && a.stamp() == 0, "no re-stamping after merge")
        check(b.merge(a.snapshot()).isEmpty, "merging again changes nothing")

        // A hands just the next one to everyone; B sees it.
        a.tasks().first!.assignOnce("")
        try? a.context.save()
        _ = a.stamp()
        b.merge(a.snapshot())
        check(b.tasks().first?.currentAssigneeUid == "" && b.tasks().first?.assigneeUid == ana.uid, "hand-over synced")

        // Concurrent edits: B marks done and renames the item, A (later) renames the task. A's
        // record wins but still carries the hand-over, which B's completion must end anyway.
        let bTask = b.tasks().first!
        b.act { bTask.markDone(on: Date(), in: b.context) }
        b.items().first!.name = "Kitchen Dishwasher"
        try? b.context.save()
        _ = b.stamp()
        // "Later" has to be a later millisecond: in the same one, the tie goes to the greater
        // device id (B) by design, and the test would be about timing rather than merging.
        Thread.sleep(forTimeInterval: 0.01)
        a.tasks().first!.title = "Clean the filters"
        try? a.context.save()
        _ = a.stamp()

        let sa = a.snapshot(), sb = b.snapshot()
        a.merge(sb)
        b.merge(sa)
        check(state(a) == state(b), "replicas converge")
        check(a.tasks().first?.title == "Clean the filters" && a.items().first?.name == "Kitchen Dishwasher", "both edits kept")
        check(a.logs().count == 1 && a.tasks().first?.lastDoneAt != nil, "B's completion reached A")
        check(a.tasks().first?.nextDueAt == b.tasks().first?.nextDueAt, "due dates agree after completion")
        check(a.tasks().first!.nextDueAt > Date(), "completion moved the due date")
        check(a.tasks().first?.currentAssigneeUid == ana.uid && b.tasks().first?.currentAssigneeUid == ana.uid,
              "a completion elsewhere ends the hand-over")
        check(a.stamp() == 0 && b.stamp() == 0, "no ping-pong after convergence")

        // A deletes the item; B had meanwhile added a task to it.
        let late = MaintenanceTask(title: "Check the salt", every: 1, .month, lastDone: nil)
        b.context.insert(late)
        late.item = b.items().first
        try? b.context.save()
        _ = b.stamp()
        a.act { SyncStore.delete(a.items().first!, in: a.context) }
        check(a.items().isEmpty && a.tasks().isEmpty && a.logs().isEmpty, "delete cascades on A")
        let sa2 = a.snapshot(), sb2 = b.snapshot()
        b.merge(sa2)
        a.merge(sb2)
        b.merge(a.snapshot())
        check(b.items().isEmpty && b.tasks().isEmpty && b.logs().isEmpty, "deletion reaches B, incl. the task added meanwhile")
        check(a.tasks().isEmpty, "orphaned task doesn't come back to A")
        check(state(a) == state(b), "converged after delete")

        // A record kind from a newer build passes through untouched.
        var future = a.snapshot()
        let unknown = SyncRecord(kind: "shoppingEntry", uid: "s1", modifiedAt: Date(), modifiedBy: "device-C",
                                 data: .object(["text": .string("Milk"), "qty": .number(2)]))
        future.records.append(unknown)
        future.device.id = "device-C"
        b.merge(future)
        check(b.snapshot().records.contains(unknown), "unknown kind kept and re-exported")

        // Unknown keys inside a known kind survive too.
        var newerPerson = a.snapshot().records.first { $0.kind == "person" }!
        if case .object(var o) = newerPerson.data {
            o["pronouns"] = .string("she/her")
            newerPerson.data = .object(o)
        }
        newerPerson.modifiedAt = Date().addingTimeInterval(60)
        newerPerson.modifiedBy = "device-C"
        future.records = [newerPerson]
        future.tombstones = []
        b.merge(future)
        b.people().first!.nagHours = 4
        try? b.context.save()
        _ = b.stamp()
        let exported = b.snapshot().records.first { $0.kind == "person" }!
        check(exported.data["pronouns"]?.stringValue == "she/her" && exported.data["reminders"]?["nagHours"]?.intValue == 4,
              "unknown keys preserved through a local edit")

        // Restore: an old backup re-stamps and wins over newer replicas.
        let c = Replica("device-C2")
        let lamp = HomeItem(name: "Lamp", icon: .lamp, color: .yellow)
        c.context.insert(lamp)
        try? c.context.save()
        let backup = c.snapshot()
        c.act { SyncStore.delete(c.items().first!, in: c.context) }
        let d = Replica("device-D")
        d.merge(c.snapshot())
        check(d.items().isEmpty, "D sees the deletion")
        c.act { SyncStore.restore(backup, into: c.context) }
        check(c.items().map(\.name) == ["Lamp"], "restore brings the item back")
        d.merge(c.snapshot())
        check(d.items().map(\.name) == ["Lamp"], "restore reaches other devices")

        // Phone reminders from any Mac: the key, a phone's subscription and the last send reach
        // every Mac, and an unsubscribe removes it everywhere.
        let e = Replica("device-E"), f = Replica("device-F")
        let key = PushKey()
        key.privateKey = "K-E"
        let sub = PushSubscriptionRecord(uid: "phone-1")
        sub.personUid = "p1"
        sub.endpoint = "https://push.example/1"
        sub.pairedMacId = "device-E"
        let helper = MacDevice(uid: "device-F")
        helper.sendsReminders = true
        e.context.insert(key)
        e.context.insert(sub)
        f.context.insert(helper)
        try? e.context.save()
        try? f.context.save()
        f.merge(e.snapshot())
        e.merge(f.snapshot())
        let fKeys = (try? f.context.fetch(FetchDescriptor<PushKey>())) ?? []
        let fSubs = (try? f.context.fetch(FetchDescriptor<PushSubscriptionRecord>())) ?? []
        check(fKeys.map(\.privateKey) == ["K-E"], "the household key reaches the other Mac")
        check(fSubs.first?.pairedMacId == "device-E" && fSubs.first?.endpoint == "https://push.example/1", "the subscription reaches the other Mac")
        check(((try? e.context.fetch(FetchDescriptor<MacDevice>())) ?? []).first?.sendsReminders == true, "a helping Mac is known everywhere")

        let slot = Date(timeIntervalSince1970: 1_790_000_000)
        let delivery = PushDelivery(phone: "phone-1")
        delivery.lastSentSlot = slot
        delivery.sentBy = "device-E"
        e.context.insert(delivery)
        try? e.context.save()
        f.merge(e.snapshot())
        let fDelivery = ((try? f.context.fetch(FetchDescriptor<PushDelivery>())) ?? []).first
        check(fDelivery?.lastSentSlot == slot && fDelivery?.phoneId == "phone-1", "word of a sent reminder reaches the other Mac")
        check(PushSchedule.slotToSend(slots: [slot], now: slot.addingTimeInterval(6 * 60), isPrimary: false,
                                      lastSent: fDelivery?.lastSentSlot) == nil, "so the helping Mac doesn't send it again")

        e.act { SyncStore.delete(((try? e.context.fetch(FetchDescriptor<PushSubscriptionRecord>())) ?? []).first!, in: e.context) }
        f.merge(e.snapshot())
        check(((try? f.context.fetch(FetchDescriptor<PushSubscriptionRecord>())) ?? []).isEmpty, "an unsubscribe reaches every Mac")
        check(((try? f.context.fetch(FetchDescriptor<PushDelivery>())) ?? []).count == 1, "without touching another kind's record")

        // A Mac upgraded from before these kinds kept them verbatim; they become real records, once.
        let g = Replica("device-G")
        let kept = SyncRecord(kind: "pushKey", uid: PushKey.householdUid, modifiedAt: Date(), modifiedBy: "device-E",
                              data: .object(["privateKey": .string("K-OLD")]))
        g.context.insert(UnknownRecord(kept))
        try? g.context.save()
        g.merge(e.snapshot())
        let gRecords = g.snapshot().records.filter { $0.uid == PushKey.householdUid }
        check(gRecords.count == 1 && ((try? g.context.fetch(FetchDescriptor<UnknownRecord>())) ?? []).isEmpty,
              "a formerly unknown kind isn't exported twice")

        // Switching household, starting fresh: this Mac's copy is cleared without a single
        // tombstone, so the household it leaves loses nothing.
        let h = Replica("device-H"), i = Replica("device-I")
        h.context.insert(HomeItem(name: "Kettle", icon: .kettle, color: .green))
        try? h.context.save()
        i.merge(h.snapshot())
        i.act { SyncStore.clearLocal(in: i.context) }
        let cleared = i.snapshot()
        check(cleared.records.isEmpty && cleared.tombstones.isEmpty, "a fresh start leaves an empty copy and no tombstones")
        h.merge(cleared)
        check(h.items().map(\.name) == ["Kettle"], "the household left behind keeps everything")

        // A phone that kept an earlier household's copy doesn't get it merged into a new one.
        let old = Replica("device-OLD"), fresh = Replica("device-NEW"), phone = Replica("phone-P")
        old.context.insert(Person(name: "Bostjan"))
        try? old.context.save()
        phone.merge(old.snapshot())
        fresh.context.insert(Person(name: "Bostjan"))
        try? fresh.context.save()
        func uids(_ r: Replica) -> Set<String> { let s = r.snapshot(); return Set(s.records.map(\.uid)).union(s.tombstones.map(\.uid)) }
        check(HouseholdCheck.decide(phoneHousehold: nil, macHousehold: "NEW", phoneUids: uids(phone), macUids: uids(fresh)) == .otherHousehold,
              "an old household's phone is turned away by a new one")
        check(HouseholdCheck.decide(phoneHousehold: nil, macHousehold: "OLD", phoneUids: uids(phone), macUids: uids(old)) == .merge,
              "but still merges with its own")

        print("self-test: \(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
#endif
