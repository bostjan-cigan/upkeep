// Comparing people's names the way a person reads them, so a household never grows a second "Ana".
import Foundation

enum Names {
    /// Trimmed, case- and diacritic-insensitive equality: "Ana", "ana" and " Aña " are one person.
    static func sameName(_ a: String, _ b: String) -> Bool {
        let left = normalized(a)
        return !left.isEmpty && left == normalized(b)
    }

    /// The first name in `names` that reads as `name`, or nil.
    static func firstMatch(_ name: String, in names: [String]) -> Int? {
        names.firstIndex { sameName($0, name) }
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
