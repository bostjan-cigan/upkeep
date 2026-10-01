import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings › Phones: serve the Upkeep web app to iPhones and iPads at home, pair them, and help
/// send the household's phones their reminders.
struct PhonesSettingsSection: View {
    @State private var pairing = false
    @State private var confirmingReset = false
    @State private var changingName = false
    @State private var showingNames = false
    @State private var confirmingHelp = false

    var body: some View {
        let server = PhoneServer.shared
        Section {
            Toggle("Serve Upkeep to phones and tablets", isOn: Binding(get: { server.isEnabled }, set: { server.isEnabled = $0 }))
            if server.isEnabled {
                LabeledContent("Status") { statusLabel(server.status) }
                LabeledContent("Address") {
                    HStack(spacing: 8) {
                        Text(server.appURL).textSelection(.enabled).foregroundStyle(.secondary)
                        if !PhoneServer.isDevBuild {
                            Button("Change…") { changingName = true }
                                .buttonStyle(.borderless)
                                .help("Choose the name phones reach this Mac at")
                        }
                    }
                }
                if PhoneServer.isDevBuild {
                    Label("Development build: it answers at a random name of its own, so it never stands in for the real Upkeep.",
                          systemImage: "hammer")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NameProblem(server: server)
                if let r = server.lastRejection, Date().timeIntervalSince(r.at) < 3600 {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("A device at \(r.client) turned down the certificate \(r.at.formatted(.relative(presentation: .named))).",
                              systemImage: "lock.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(r.explanation).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !server.hasWebApp {
                    Label("The web app isn't built. Run “npm run build” in Web/, or build with Tools/build-local.sh.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
                HStack {
                    Button("Pair a Phone…") {
                        server.newPairing()
                        pairing = true
                    }
                    Button("Test All") { Task { await WebPush.shared.sendTestToAll() } }
                        .disabled(pairedSubscriptions.isEmpty || WebPush.shared.isTestingAll)
                        .help(pairedSubscriptions.isEmpty
                              ? "No phone paired with this Mac has reminders turned on yet."
                              : "Send a test notification to every phone paired with this Mac.")
                    Spacer()
                    Button("New Certificate…") { confirmingReset = true }
                        .help("Make a new home certificate. Every phone has to install the profile again.")
                }
            }
        } header: {
            Text("Phones & Tablets")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("iPhones and iPads on your Wi-Fi install Upkeep from this Mac and sync with it automatically while at home. Away from home the app keeps working and syncs through Files.")
                if server.isEnabled && !PhoneServer.isDevBuild {
                    Text("Phones reach this Mac at “\(server.phoneHost)” — named after you, so it stays the same if the Mac is renamed, and another Mac in the household can serve its own phones too.")
                }
            }
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $pairing) { PairingSheet() }
        .sheet(isPresented: $changingName) { ChangePhoneNameSheet() }
        .confirmationDialog("Make a new certificate?", isPresented: $confirmingReset) {
            Button("New Certificate", role: .destructive) { server.resetCertificates() }
        } message: {
            Text("Paired phones will stop syncing until they install and trust the new profile (step 1).")
        }

        if server.isEnabled {
            Section {
                DisclosureGroup("Network Name", isExpanded: $showingNames) { networkNames(server) }
            }
        }

        remindersSection
            .sheet(isPresented: $confirmingHelp) { SendRemindersSheet() }

        if server.isEnabled && !(server.pairings.isEmpty && WebPush.shared.orphans.isEmpty) {
            Section {
                ForEach(server.pairings) { p in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name)
                            Text(p.lastSyncAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Waiting for first sync")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        pushStatus(p)
                        Button("Revoke", role: .destructive) {
                            if let id = p.deviceId { WebPush.shared.unsubscribe(deviceId: id) }
                            server.revoke(p)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                ForEach(WebPush.shared.orphans) { sub in
                    HStack {
                        Image(systemName: "iphone.slash").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Unpaired phone")
                            Text("Still set up for reminders, but its pairing is gone.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        testResult(sub.deviceId)
                        Button("Test") { Task { await WebPush.shared.sendTest(to: sub.deviceId) } }
                            .buttonStyle(.borderless)
                        Button("Remove", role: .destructive) { WebPush.shared.unsubscribe(deviceId: sub.deviceId) }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Paired with This Mac")
            } footer: {
                Text("Turn reminders on in the phone app’s Settings.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairedSubscriptions: [WebPush.Subscription] {
        WebPush.shared.subscriptions.filter { $0.pairedMacId == Household.shared.deviceId }
    }

    // MARK: Network name

    @ViewBuilder private func networkNames(_ server: PhoneServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let names = server.nameStates.keys.filter { $0 != server.phoneHost }.sorted()
            ForEach((server.nameStates[server.phoneHost] == nil ? [] : [server.phoneHost]) + names, id: \.self) { name in
                HStack {
                    Text(name).textSelection(.enabled)
                    if name == PhoneHostName.legacy, !server.legacyPhones.isEmpty {
                        Text("· \(server.legacyPhones.count) \(server.legacyPhones.count == 1 ? "phone" : "phones") set up with an older version")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    nameState(server.nameStates[name])
                }
                .font(.callout)
            }
            if !PhoneServer.isDevBuild {
                Toggle("Also answer at upkeep.local for phones set up with an older version",
                       isOn: Binding(get: { server.answersLegacyName }, set: { server.answersLegacyName = $0 }))
                Text(server.legacyPhones.isEmpty && server.answersLegacyName
                     ? "No phone paired with this Mac uses upkeep.local any more, so you can turn this off."
                     : "Phones set up before Upkeep named itself after you still look for upkeep.local. Keep this on until they’re paired again. Only one Mac on your network can answer at upkeep.local.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Reset Network Name") { server.resetNetworkName() }
                Spacer()
            }
            Text("Try this if phones can’t find this Mac, for example after changing Wi-Fi or if Upkeep was running twice. It doesn’t change the certificate, so phones don’t need setting up again.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    @ViewBuilder private func nameState(_ state: LocalHostname.State?) -> some View {
        switch state {
        case .announced?:
            Label("Announced", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(.taken)?:
            Label("Taken", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("Another device on this network answers at this name.")
        case .failed(.localNetworkOff)?:
            Label("Blocked", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                .help("Local Network access is off for Upkeep.")
        case .failed(.other(let code))?:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help("Error \(code)")
        case .announcing?, nil:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: Reminders to phones

    @ViewBuilder private var remindersSection: some View {
        let push = WebPush.shared
        Section {
            Toggle("Also send reminders when the usual Mac can’t", isOn: Binding(
                get: { push.sendsReminders },
                set: { on in if on { confirmingHelp = true } else { push.setSendsReminders(false) } }))
            ForEach(push.coverage) { c in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "iphone").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.phoneName)
                        Text(coverageText(c))
                            .font(.caption)
                            .foregroundStyle(c.backups.isEmpty && !c.backupIsThisMac ? Color.orange : Color.secondary)
                    }
                }
            }
        } header: {
            Text("Reminders to Phones")
        } footer: {
            Text("Each phone gets its person’s reminders from the Mac it paired with. When that Mac is asleep, off or offline, a Mac with this turned on sends them instead, a few minutes late. It works anywhere with internet — this Mac doesn’t need to be at home — but it has to be on and awake.")
                .foregroundStyle(.secondary)
        }
    }

    private func coverageText(_ c: WebPush.Coverage) -> String {
        let usual = c.usualIsThisMac ? "this Mac" : (c.usual ?? "a Mac that’s gone")
        var backups = c.backups
        if c.backupIsThisMac { backups.insert("this Mac", at: 0) }
        guard !backups.isEmpty else { return "From \(usual) · no backup — turn this on on another Mac" }
        return "From \(usual) · backup: \(backups.formatted(.list(type: .and)))"
    }

    /// A phone's reminder state: sending, the last test's result, or the resting bell — and
    /// for a phone that never turned reminders on, why there's nothing to test.
    @ViewBuilder private func pushStatus(_ p: PhoneServer.Pairing) -> some View {
        let push = WebPush.shared
        if let id = p.deviceId, push.subscriptions.contains(where: { $0.deviceId == id }) {
            if push.testStates[id] == nil {
                Image(systemName: push.errors[id] == nil ? "bell.badge" : "bell.slash")
                    .foregroundStyle(push.errors[id] == nil ? Color.secondary : Color.red)
                    .help(push.errors[id] ?? "Gets reminders")
            } else {
                testResult(id)
            }
            Button("Test") { Task { await push.sendTest(to: id) } }
                .buttonStyle(.borderless)
                .disabled(push.testStates[id] == .sending)
                .help("Send a test notification")
        } else {
            Text("Reminders off in the phone app")
                .font(.caption).foregroundStyle(.secondary)
                .help("On that phone: Upkeep › Settings › Reminders.")
        }
    }

    @ViewBuilder private func testResult(_ deviceId: String) -> some View {
        switch WebPush.shared.testStates[deviceId] {
        case .sending?:
            ProgressView().controlSize(.small)
        case .sent(let at)?:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.green)
                .help("Test sent \(at.formatted(.relative(presentation: .named)))")
        case .failed(let message)?:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.iconOnly).foregroundStyle(.red)
                .help(message)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder private func statusLabel(_ status: PhoneServer.Status) -> some View {
        switch status {
        case .off: Text("Off").foregroundStyle(.secondary)
        case .starting: ProgressView().controlSize(.small)
        case .running: Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let message): Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
        }
    }
}

/// Why this Mac's name isn't answering, in words, with the way out.
struct NameProblem: View {
    let server: PhoneServer

    var body: some View {
        if let failure = server.nameFailure {
            VStack(alignment: .leading, spacing: 6) {
                Label(message(failure), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if failure == .localNetworkOff {
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Text("Until then, new phones get this Mac’s own name, “\(Certificates.localHostName ?? "")”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ failure: LocalHostname.Failure) -> String {
        switch failure {
        case .localNetworkOff:
            "macOS isn’t letting Upkeep announce itself on your network. Turn on Upkeep in System Settings › Privacy & Security › Local Network."
        case .taken:
            "Another device on this network already uses “\(server.phoneHost)”. Change this Mac’s name, or wait a minute if it was this Mac a moment ago."
        case .other(let code):
            "“\(server.phoneHost)” couldn’t be announced on your network (error \(code)). Try Reset Network Name under Network Name."
        }
    }
}

/// Change…: the part of the name after “upkeep-”.
struct ChangePhoneNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = PhoneHostName.label(of: PhoneServer.shared.phoneHost)

    var body: some View {
        let server = PhoneServer.shared
        let preview = PhoneHostName.custom(label)
        VStack(alignment: .leading, spacing: 14) {
            Text("Phone Name").font(.title2.weight(.semibold))
            HStack(spacing: 2) {
                Text("upkeep-").foregroundStyle(.secondary)
                TextField("name", text: $label).textFieldStyle(.roundedBorder).frame(width: 180)
                Text(".local").foregroundStyle(.secondary)
            }
            Text(preview.map { "Phones will reach this Mac at “\($0)”." } ?? "Use letters and numbers.")
                .font(.callout).foregroundStyle(.secondary)
            if !server.pairings.isEmpty {
                Label("Phones paired with this Mac will need pairing again.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change") {
                    server.setPhoneHost(label)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil || preview == server.phoneHost)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

/// What helping with reminders means, before it's turned on.
struct SendRemindersSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Send reminders from this Mac too?", systemImage: "bell.badge")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                bullet("This Mac will send reminders to everyone’s phones in the household — not just yours — but only when the Mac a phone paired with hasn’t sent them.")
                bullet("Now and then a reminder may arrive twice, when the other Mac was just slow to report it had sent it.")
                bullet("To do this, a sending key is kept in your household folder in iCloud Drive. Anyone who shares the folder can send notifications to your household’s phones.")
                bullet("You can turn it off any time.")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Turn On") {
                    WebPush.shared.setSendsReminders(true)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Pairing, one step at a time: trust this Mac once (profile), then open and add the app.
/// Moves on by itself as the phone gets through each step; Continue works too.
struct PairingSheet: View {
    enum Step: Int, CaseIterable {
        case choose, profile, trust, open, code, done
    }

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step

    init(start: Step = .choose) {
        _step = State(initialValue: start)
    }

    var body: some View {
        let server = PhoneServer.shared
        VStack(alignment: .leading, spacing: 18) {
            header
            Group {
                switch step {
                case .choose: choose
                case .profile: profile(server)
                case .trust: trust(server)
                case .open: open(server)
                case .code: code(server)
                case .done: done(server)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            footer
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { server.resetSetupProgress() }
        .onChange(of: server.setupProgress) { _, progress in advance(progress) }
        .animation(.default, value: step)
    }

    // MARK: Steps

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let n = numbered {
                Text("Step \(n) of 3").font(.callout.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(title).font(.title2.weight(.semibold))
        }
    }

    private var numbered: Int? {
        switch step {
        case .profile: 1
        case .trust: 2
        case .open: 3
        default: nil
        }
    }

    private var title: String {
        switch step {
        case .choose: "Pair a Phone or Tablet"
        case .profile: "Open the setup page"
        case .trust: "Install and trust the profile"
        case .open: "Open Upkeep and add it to the Home Screen"
        case .code: "Enter the pairing code"
        case .done: "All set"
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The phone must be on the same Wi-Fi as this Mac.").foregroundStyle(.secondary)
            SetupChoice(title: "Set Up a New Phone",
                        detail: "Upkeep isn’t on it yet. Three short steps: trust this Mac, then add the app to the Home Screen.",
                        systemImage: "iphone.badge.play") { step = .profile }
            SetupChoice(title: "Upkeep Is Already on Its Home Screen",
                        detail: "It was set up before, but isn’t syncing with this Mac. Type a short code into it.",
                        systemImage: "number") { step = .code }
        }
    }

    private func profile(_ server: PhoneServer) -> some View {
        HStack(alignment: .top, spacing: 20) {
            QRCodeView(text: server.setupURL).frame(width: 200, height: 200)
            VStack(alignment: .leading, spacing: 10) {
                instructions([
                    "Point the iPhone’s Camera at the code and open the link in Safari.",
                    "Tap Download Profile, then Allow.",
                ])
                Spacer(minLength: 0)
                if server.setupProgress.downloadedProfile {
                    status("Profile downloaded", done: true)
                } else if server.setupProgress.client != nil {
                    status("Setup page open — waiting for the download…")
                } else {
                    status("Waiting for the phone…")
                }
                nameWarning(server)
            }
        }
    }

    private func trust(_ server: PhoneServer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            instructions([
                "On the phone, open Settings › General › VPN & Device Management › Upkeep, and tap Install.",
                "Then Settings › General › About › Certificate Trust Settings, and turn on “Upkeep Home CA”.",
                "Go back to Safari. The page checks by itself.",
            ])
            if server.setupProgress.trusts {
                status("The phone trusts this Mac", done: true)
            } else if let r = server.lastRejection, r.client == server.setupProgress.client,
                      Date().timeIntervalSince(r.at) < 600 {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not trusted yet", systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    Text(r.explanation).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                status("Waiting for the phone…")
            }
        }
    }

    private func open(_ server: PhoneServer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                QRCodeView(text: server.pairingURL ?? server.appURL).frame(width: 200, height: 200)
                VStack(alignment: .leading, spacing: 10) {
                    instructions([
                        "Scan this code and open the link in Safari.",
                        "Tap Share › Add to Home Screen (keep “Open as Web App” on).",
                        "Open Upkeep from its new icon.",
                    ])
                    Spacer(minLength: 0)
                    if server.setupProgress.openedApp {
                        status("Open in Safari — now add it to the Home Screen and open it from there…")
                    } else {
                        status("Waiting for the phone…")
                    }
                }
            }
            codeFallback(server)
        }
        .onAppear { if server.pendingCodeText == nil { server.newCode() } }
    }

    /// The Home Screen app sometimes opens without the pairing link; then it asks for this code.
    private func codeFallback(_ server: PhoneServer) -> some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            HStack {
                Text("Upkeep on the Home Screen asks for a code?").foregroundStyle(.secondary)
                Spacer()
                if let code = server.pendingCodeText {
                    Text(code).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                } else {
                    Button("New Code") { server.newCode() }
                }
            }
            .font(.callout)
            .padding(10)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func code(_ server: PhoneServer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            instructions([
                "Open Upkeep from the phone’s Home Screen.",
                "Go to Settings › Sync at Home and enter this code.",
            ])
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                HStack {
                    if let code = server.pendingCodeText {
                        Text(code)
                            .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                    } else {
                        Text("The code was used or expired.").foregroundStyle(.secondary)
                        Button("New Code") { server.newCode() }
                    }
                    Spacer()
                }
                .padding(14)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text("The code pairs one device, once, and expires after 15 minutes.")
                .font(.callout).foregroundStyle(.secondary)
            status("Waiting for the phone…")
        }
        .onAppear { if server.pendingCodeText == nil { server.newCode() } }
    }

    private func done(_ server: PhoneServer) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(server.setupProgress.pairedName ?? "The phone") is paired.").font(.headline)
                Text("It syncs with this Mac by itself whenever it’s on the home Wi-Fi. For reminders, turn them on in the phone app’s Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Parts

    private var footer: some View {
        HStack {
            switch step {
            case .choose, .done:
                EmptyView()
            case .profile:
                Button("Back") { step = .choose }
                Button("Already Trusts This Mac") { step = .open }
                    .help("This phone was set up before: skip to adding the app")
            case .trust, .open:
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .choose }
            case .code:
                Button("Back") { step = .choose }
            }
            Spacer()
            switch step {
            case .done:
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            case .profile, .trust:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .done }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func instructions(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Label {
                    Text(line).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "\(i + 1).circle.fill").foregroundStyle(.tint)
                }
            }
        }
    }

    private func status(_ text: String, done: Bool = false) -> some View {
        HStack(spacing: 8) {
            if done {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(text).foregroundStyle(done ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    /// Phones keep the address they were set up with; the Mac's own name can change on its own.
    @ViewBuilder private func nameWarning(_ server: PhoneServer) -> some View {
        if !server.isNameAnnounced {
            Label("“\(server.phoneHost)” isn’t answering on this network yet, so the code uses “\(server.host)”. If this Mac’s name changes later, the phone will need pairing again. Waiting a minute usually fixes it; Settings › Phones › Network Name says why.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func advance(_ progress: PhoneServer.SetupProgress) {
        if progress.pairedName != nil { step = .done; return }
        switch step {
        case .profile where progress.trusts: step = .open
        case .profile where progress.downloadedProfile: step = .trust
        case .trust where progress.trusts: step = .open
        default: break
        }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .help(text)
                .accessibilityLabel("QR code for \(text)")
        }
    }

    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
