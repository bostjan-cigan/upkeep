import Foundation

/// The names phones reach a serving Mac at (Docs/Upkeep.md › Phones).
///
/// Each serving Mac is named after its person — `upkeep-bostjan.local`, `upkeep-tjasa.local` — so
/// several Macs in one household can serve their own phones without taking each other's name, and
/// the name survives the Mac being renamed. Development builds get a random name of their own, so a
/// test copy never answers in place of the real app.
enum PhoneHostName {
    /// What versions before per-person names used; phones set up then still look for it.
    static let legacy = "upkeep.local"
    static let prefix = "upkeep-"
    static let devPrefix = "upkeep-dev-"
    static let maxSlugLength = 40

    /// "Boštjan" → "bostjan", "Ana Marie" → "ana-marie"; nil when nothing usable is left.
    static func slug(_ text: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out = ""
        for scalar in folded.unicodeScalars {
            let isLetter = (97...122).contains(scalar.value) || (65...90).contains(scalar.value)
            let isDigit = (48...57).contains(scalar.value)
            if isLetter || isDigit {
                out.unicodeScalars.append(Unicode.Scalar(isLetter ? scalar.value | 0x20 : scalar.value)!)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
        }
        out = String(out.prefix(maxSlugLength))
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// `upkeep-<slug>.local` for a person. People whose names read the same get `-2`, `-3` in uid
    /// order, so every Mac works out the same name from the synced people.
    static func forPerson(uid: String, among people: [(uid: String, name: String)]) -> String? {
        guard let me = people.first(where: { $0.uid == uid }), let base = slug(me.name) else { return nil }
        let twins = people.filter { slug($0.name) == base }.map(\.uid).sorted()
        let n = (twins.firstIndex(of: uid) ?? 0) + 1
        return host(base + (n > 1 ? "-\(n)" : ""))
    }

    /// `upkeep-<label>.local`, from what someone typed in Change… (nil when nothing usable is left).
    static func custom(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasSuffix(".local") { text.removeLast(".local".count) }
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return slug(text).map(host)
    }

    /// The part a person can change: "bostjan" from "upkeep-bostjan.local".
    static func label(of host: String) -> String {
        var text = host
        if text.hasSuffix(".local") { text.removeLast(".local".count) }
        if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        return text
    }

    static func host(_ label: String) -> String { prefix + label + ".local" }

    /// A development build's own name: never a person's, never the old shared one.
    static func dev(_ suffix: String) -> String { devPrefix + suffix + ".local" }

    static func isDev(_ host: String) -> Bool { host.hasPrefix(devPrefix) }

    /// Six random hex characters, made once per development copy.
    static func randomDevSuffix() -> String {
        var bytes = [UInt8](repeating: 0, count: 3)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
