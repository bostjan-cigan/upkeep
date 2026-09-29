// Directory listings in an iCloud Drive folder: files this Mac has evicted appear as
// ".Name.json.icloud" placeholders, which name the same file.
import Foundation

enum FileNames {
    /// Raw directory names with iCloud placeholders unwrapped, dotfiles dropped, de-duplicated and sorted.
    static func unwrapped(_ raw: [String], suffix: String) -> [String] {
        let names = raw.map { name -> String in
            guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
            return String(name.dropFirst().dropLast(".icloud".count))
        }
        return Set(names.filter { !$0.hasPrefix(".") && $0.hasSuffix(suffix) }).sorted()
    }
}
