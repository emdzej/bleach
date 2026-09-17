import Foundation
import CoreServices

/// Reads `.app` bundles into `AppRecord`s, and finds them via Spotlight plus
/// a direct walk of the conventional install locations.
public enum AppBundles {
    public static let searchRoots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Library/Application Support/JetBrains/Toolbox/apps",
        "/opt/homebrew/Caskroom",
        "/usr/local/Caskroom",
    ]

    public static func userSearchRoots(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/Applications",
            "\(home)/Applications/Chrome Apps.localized",
            "\(home)/Library/Application Support/JetBrains/Toolbox/apps",
            "\(home)/Developer",
        ]
    }

    /// Spotlight query for app bundles. Effectively instant (the index is
    /// already built) and catches apps in unconventional locations.
    public static func viaSpotlight(timeout: TimeInterval = 30) -> [AppRecord] {
        let r = Shell.run("/usr/bin/mdfind",
                          ["kMDItemContentType == 'com.apple.application-bundle'"],
                          timeout: timeout)
        return r.stdout
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasSuffix(".app") }
            .compactMap { read(bundleAt: $0, source: .spotlight) }
    }

    /// Direct enumeration of the known install directories. Redundant with
    /// Spotlight by design — Spotlight can be disabled or stale, and this is
    /// the source we trust most for "the file is really there".
    public static func viaFilesystem(home: String = NSHomeDirectory()) -> [AppRecord] {
        let fm = FileManager.default
        var out: [AppRecord] = []
        for root in searchRoots + userSearchRoots(home: home) {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries {
                let full = "\(root)/\(entry)"
                if entry.hasSuffix(".app") {
                    if let rec = read(bundleAt: full, source: .filesystem) { out.append(rec) }
                } else if let nested = try? fm.contentsOfDirectory(atPath: full) {
                    // One level deeper: Caskroom/<cask>/<version>/Foo.app and
                    // Toolbox/apps/<ide>/<build>/Foo.app both nest.
                    for sub in nested where sub.hasSuffix(".app") {
                        if let rec = read(bundleAt: "\(full)/\(sub)", source: .filesystem) { out.append(rec) }
                    }
                }
            }
        }
        return out
    }

    public static func read(bundleAt path: String, source: InventorySource) -> AppRecord? {
        let info = Plist.read(atPath: "\(path)/Contents/Info.plist")
        let bundleID = Plist.string(info, "CFBundleIdentifier")
        let displayName = Plist.string(info, "CFBundleDisplayName")
            ?? Plist.string(info, "CFBundleName")
            ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        // A bundle with no identifier is still useful for name matching.
        return AppRecord(
            bundleID: bundleID,
            name: displayName,
            executable: Plist.string(info, "CFBundleExecutable"),
            path: path,
            sources: [source],
            lastUsed: spotlightLastUsed(path),
            existsOnDisk: FileManager.default.fileExists(atPath: path)
        )
    }

    /// `kMDItemLastUsedDate` is only present when Spotlight has indexed the
    /// bundle; absence is not evidence of disuse.
    private static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
