import Foundation

/// Parses `lsregister -dump`, the LaunchServices database.
///
/// This is the most complete view of "apps macOS knows about" — it includes
/// bundles outside `/Applications` that Spotlight may skip. It also retains
/// entries for apps that no longer exist, so every record's `path` is
/// re-checked against the filesystem before we treat it as present.
public enum LaunchServicesDump {
    static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/"
        + "Frameworks/LaunchServices.framework/Support/lsregister"

    public static func load(timeout: TimeInterval = 90) -> [AppRecord] {
        let result = Shell.run(lsregisterPath, ["-dump"], timeout: timeout)
        guard result.ok || !result.stdout.isEmpty else { return [] }
        return parse(result.stdout)
    }

    /// Records are separated by long `---` rules; fields are `key: value` with
    /// the value padded out to a fixed column. We only keep records that have
    /// both a reverse-DNS `identifier` and a `path` ending in `.app`.
    public static func parse(_ dump: String) -> [AppRecord] {
        var records: [AppRecord] = []
        var current: [String: String] = [:]
        let fm = FileManager.default

        func flush() {
            defer { current = [:] }
            guard let id = current["identifier"], id.contains(".") else { return }
            guard let rawPath = current["path"] else { return }
            let path = stripTrailingHandle(rawPath)
            guard path.hasSuffix(".app") else { return }
            records.append(AppRecord(
                bundleID: id,
                name: current["name"] ?? current["displayName"],
                executable: current["executable"].map { ($0 as NSString).lastPathComponent },
                path: path,
                teamID: current["teamID"],
                sources: [.launchServices],
                existsOnDisk: fm.fileExists(atPath: path)
            ))
        }

        for line in dump.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("---") { flush(); continue }
            // Field lines are `key:` followed by whitespace padding. Indented
            // lines are continuations of infoDictionary blocks — skip them.
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            // First occurrence wins; nested dictionaries repeat key names.
            if current[key] == nil { current[key] = value }
        }
        flush()
        return records
    }

    /// `lsregister` appends an internal handle, e.g. `/path/Foo.app (0x1884)`.
    private static func stripTrailingHandle(_ s: String) -> String {
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return s }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        guard inner.hasPrefix("0x") else { return s }
        return String(s[s.startIndex..<open]).trimmingCharacters(in: .whitespaces)
    }
}
