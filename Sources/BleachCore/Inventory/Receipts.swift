import Foundation

/// `/var/db/receipts/*.plist` — one per installer package ever run.
///
/// Weak presence evidence on purpose: receipts survive uninstallation, so a
/// receipt alone must never keep a directory alive. Its real value is
/// *identifying* an unmatched directory ("this belonged to Foo, which was
/// installed by pkg and is now gone") so we can report it confidently.
public enum Receipts {
    public static let directory = "/var/db/receipts"

    public static func load() -> [AppRecord] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var out: [AppRecord] = []
        for entry in entries where entry.hasSuffix(".plist") {
            let bundleID = String(entry.dropLast(".plist".count))
            guard bundleID.contains(".") else { continue }
            let info = Plist.read(atPath: "\(directory)/\(entry)")
            let installPath = Plist.string(info, "InstallPrefixPath")
            out.append(AppRecord(
                bundleID: bundleID,
                name: Plist.string(info, "PackageFileName").map {
                    $0.replacingOccurrences(of: ".pkg", with: "")
                },
                path: installPath.map { $0.hasPrefix("/") ? $0 : "/\($0)" },
                sources: [.installReceipt],
                existsOnDisk: false
            ))
        }
        return out
    }
}
