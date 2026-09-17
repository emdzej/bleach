import Foundation

/// Homebrew casks and formulae. Casks map to `.app` bundles (already covered
/// by the bundle scan) but the Caskroom name is often the only thing that
/// matches a human-named support directory. Formulae matter because they own
/// large cache directories with no `.app` anywhere.
public enum Homebrew {
    public static let prefixes = ["/opt/homebrew", "/usr/local"]

    public static func load() -> [AppRecord] {
        var out: [AppRecord] = []
        let fm = FileManager.default
        for prefix in prefixes {
            for kind in ["Caskroom", "Cellar"] {
                let dir = "\(prefix)/\(kind)"
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for entry in entries where !entry.hasPrefix(".") {
                    out.append(AppRecord(
                        name: entry,
                        path: "\(dir)/\(entry)",
                        sources: [kind == "Caskroom" ? .homebrewCask : .toolManaged],
                        existsOnDisk: true
                    ))
                }
            }
        }
        return out
    }
}
