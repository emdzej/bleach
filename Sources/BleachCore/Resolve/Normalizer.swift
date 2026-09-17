import Foundation

/// Name canonicalisation for the fuzzy half of owner resolution.
///
/// The hard cases on a real machine look like: `Code - Insiders` vs
/// `com.microsoft.VSCodeInsiders`, `BambuStudioBeta` vs `BambuStudio`,
/// `IntelliJIdea2025.3` vs `IntelliJ IDEA`. Normalisation gets us most of the
/// way; the alias table handles the rest.
public enum Normalizer {
    /// Lowercase, strip everything that isn't alphanumeric.
    public static func canonical(_ s: String) -> String {
        s.unicodeScalars.reduce(into: "") { acc, u in
            if CharacterSet.alphanumerics.contains(u) {
                acc.unicodeScalars.append(u)
            }
        }.lowercased()
    }

    /// Canonical form with a trailing version/edition suffix removed, so
    /// `IntelliJIdea2025.3` and `IntelliJIdea2026.2` both reduce to
    /// `intellijidea`. This is what makes version-sibling detection work.
    public static func versionStripped(_ s: String) -> String {
        var c = canonical(s)
        for suffix in ["beta", "alpha", "nightly", "canary", "dev", "insiders", "preview", "stable", "eap"] {
            if c.count > suffix.count + 2, c.hasSuffix(suffix) {
                c = String(c.dropLast(suffix.count))
            }
        }
        while let last = c.last, last.isNumber { c = String(c.dropLast()) }
        return c
    }

    /// Does this directory name look like a reverse-DNS bundle identifier?
    /// Requires at least two dots and a plausible TLD-ish first segment, which
    /// keeps `IntelliJIdea2025.3` out of the bundle-ID path.
    public static func looksLikeBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count >= 3 else { return false }
        guard let first = parts.first, first.count <= 5, first.allSatisfy(\.isLetter) else { return false }
        return !parts.contains { $0.allSatisfy(\.isNumber) }
    }

    /// Strip an App Group team-ID prefix, e.g.
    /// `2BUA8C4S2C.com.1password.browser-helper` -> team `2BUA8C4S2C`.
    /// Team IDs are exactly 10 uppercase alphanumerics.
    public static func splitTeamPrefix(_ s: String) -> (teamID: String, rest: String)? {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 10 else { return nil }
        let team = String(parts[0])
        guard team.allSatisfy({ $0.isUppercase || $0.isNumber }) else { return nil }
        return (team, String(parts[1]))
    }

    /// Keys a bundle ID can plausibly be matched by: the full ID, and the
    /// vendor+product tail (`com.raycast.macos` -> `raycast.macos`, `macos`).
    public static func keys(forBundleID id: String) -> [String] {
        var keys = [id.lowercased()]
        let parts = id.split(separator: ".")
        if parts.count >= 2 {
            keys.append(parts.dropFirst().joined(separator: ".").lowercased())
            keys.append(canonical(String(parts[parts.count - 1])))
        }
        return keys
    }
}
