import SwiftData
import SwiftUI

@main
struct UpkeepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-selftest") {
            exit(MainActor.assumeIsolated { SelfTest.run() })
        }
        #endif
        // Before any scene: the main window asks "does this Mac still need setting up?" as it
        // appears, which can be before the app delegate hears the launch has finished. Without the
        // store, "who am I" reads as nobody, and setup would open on every launch.
        MainActor.assumeIsolated { Household.shared.start(container: Persistence.shared) }
    }

    var body: some Scene {
        Window("Upkeep", id: AppState.mainWindowID) {
            ContentView()
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 940, height: 640)
        .modelContainer(Persistence.shared)
        .commands {
            AboutCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Item…") { AppState.shared.showingAddItem = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .saveItem) {
                Button("Sync Now") { SyncManager.shared.syncNow() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Back Up Now") { BackupManager.shared.backUpNow() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
            }
            #if DEBUG
            CommandMenu("Developer") {
                Button("Reset All Notifications") { Nagger.shared.resetAllNotifications() }
            }
            #endif
        }

        MenuBarExtra {
            MenuBarView()
                .modelContainer(Persistence.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("About Upkeep", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
                .modelContainer(Persistence.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            Nagger.shared.start(container: Persistence.shared)
            // Demo data lives in memory only and must never reach backups or the household.
            if !Persistence.isDemo {
                BackupManager.shared.start(container: Persistence.shared)
                SyncManager.shared.start(container: Persistence.shared)
                // Phones' reminders can come from any Mac in the household, serving or not.
                WebPush.shared.start(container: Persistence.shared)
                PhoneServer.shared.startIfEnabled()
            }
            #if DEBUG
            // Debug: `-demo -serve -pairtoken T` serves the demo data to phones with a known token.
            let args = ProcessInfo.processInfo.arguments
            if Persistence.isDemo, args.contains("-serve") {
                SyncManager.shared.start(container: Persistence.shared)
                WebPush.shared.start(container: Persistence.shared)
                if let i = args.firstIndex(of: "-pairtoken"), i + 1 < args.count { PhoneServer.shared.addDebugPairing(args[i + 1]) }
                if args.contains("-paircode") {
                    PhoneServer.shared.newPairing()
                    NSLog("pairing code: %@ qr: %@", PhoneServer.shared.pendingCodeText ?? "-", PhoneServer.shared.pendingToken ?? "-")
                }
                PhoneServer.shared.start()
            }
            #endif
        }
    }

    /// Quitting clears the queued reminders before letting go, so a quit Upkeep stays quiet, and
    /// withdraws this Mac's network names, so phones and other devices forget them at once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            PhoneServer.shared.stop()
            WebPush.shared.stop()
            Task {
                await Nagger.shared.stop()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Closing the window keeps Upkeep alive in the menu bar so it can keep nagging.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainActor.assumeIsolated { AppState.shared.openMainWindow?() }
        }
        return true
    }
}

enum SidebarSelection: Hashable {
    case upNext
    case item(PersistentIdentifier)
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()
    static let mainWindowID = "main"

    var selection: SidebarSelection? = .upNext
    var showingAddItem = false
    var showingSetup = false
    /// Set while switching households: the folder just left, so setup doesn't offer it again.
    var leftHousehold: URL?
    /// Captured from a view's `openWindow` so non-view code (notifications, dock) can bring the window back.
    var openMainWindow: (() -> Void)?
}

@MainActor
enum Persistence {
    private(set) static var isDemo = false

    static let shared: ModelContainer = {
        let schema = SyncRegistry.schema

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            let container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            DemoData.seed(container.mainContext)
            isDemo = true
            return container
        }
        #endif

        // Upkeep isn't sandboxed, so SwiftData's default location would be the shared
        // ~/Library/Application Support/default.store; keep our own file instead.
        let folder = URL.applicationSupportDirectory.appending(path: "Upkeep", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let config = ModelConfiguration(schema: schema, url: folder.appending(path: "Household.store"), cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: config)
    }()
}

#if DEBUG
@MainActor
enum DemoData {
    static func seed(_ ctx: ModelContext) {
        func ago(_ days: Int) -> Date { Calendar.current.date(byAdding: .day, value: -days, to: Date())! }
        let me = Person(name: "Me", color: .teal)
        let partner = Person(name: "Ana", color: .pink)
        ctx.insert(me)
        ctx.insert(partner)
        Household.shared.persists = false
        Household.shared.myPersonUid = me.uid
        let specs: [(String, IconKey, TileColor, String, [(String, Int, IntervalUnit, Int?)])] = [
            ("Dishwasher", .dishwasher, .blue, "Kitchen", [("Clean the filter", 1, .month, 35), ("Run a cleaning cycle", 1, .month, 12), ("Clean the spray arms", 3, .month, 40)]),
            ("Washing Machine", .washer, .teal, "Bathroom", [("Clean the drum", 1, .month, 29), ("Wipe the door seal", 2, .week, 3)]),
            ("Doors & Handles", .door, .green, "", [("Disinfect door handles", 1, .week, 9)]),
            ("Windows", .window, .indigo, "Living Room", [("Clean the glass", 3, .month, 60)]),
            ("Floors", .floor, .orange, "", [("Vacuum", 1, .week, 2), ("Mop", 2, .week, nil)]),
            ("Coffee Machine", .coffee, .brown, "Kitchen", [("Descale", 2, .month, 20)]),
            ("Robot Vacuum", .vacuum, .purple, "", [("Empty the dust bin", 3, .day, 2), ("Untangle the brushes", 2, .week, 10), ("Replace the filter", 3, .month, 88)]),
        ]
        for (name, icon, color, room, tasks) in specs {
            let item = HomeItem(name: name, icon: icon, color: color, room: room)
            ctx.insert(item)
            for (title, value, unit, daysAgo) in tasks {
                let task = MaintenanceTask(title: title, every: value, unit, lastDone: nil)
                ctx.insert(task)
                task.item = item
                if title == "Mop" || title == "Descale" { task.assigneeUid = partner.uid }
                if let daysAgo {
                    task.markDone(on: ago(daysAgo + 60), in: ctx)
                    task.markDone(on: ago(daysAgo), in: ctx)
                }
            }
        }
        let ac = HomeItem(name: "Air Conditioner", icon: .ac, color: .blue, room: "Living Room")
        ctx.insert(ac)
        let service = MaintenanceTask(title: "Service before winter", every: 1, .year, lastDone: nil)
        ctx.insert(service)
        service.item = ac
        let cal = Calendar.current
        let endOfSummer = cal.nextDate(after: Date(), matching: DateComponents(month: 9, day: 15), matchingPolicy: .nextTime) ?? Date()
        service.setFixedDate(endOfSummer, repeats: true)
        try? ctx.save()
    }
}
#endif
