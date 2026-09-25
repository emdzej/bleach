import Foundation
import Yams

/// Rules are data, not code, so the risky knowledge (what must never be
/// touched, which directory belongs to which bundle ID) can be reviewed,
/// diffed, and extended by the user without a rebuild.
public struct Rules: Codable, Sendable {
    /// Bundle-ID prefixes that are always protected.
    public var protectedBundlePrefixes: [String] = []
    /// Case-insensitive substrings of a path that force `protected`.
    public var protectedPathContains: [String] = []
    /// Exact leaf names that are always protected.
    public var protectedNames: [String] = []
    /// Directory name -> bundle identifier, for names normalisation can't reach.
    public var aliases: [String: String] = [:]
    /// Regexes on the candidate name marking regenerable state, even when the
    /// owner is installed and running.
    public var regenerablePatterns: [String] = []
    /// Candidate name -> the tool's own cleanup command. Wrapping a correct
    /// command beats reimplementing its retention logic.
    public var delegatedCleanups: [String: String] = [:]
    /// Days without any internal file being modified before a directory
    /// counts as stale.
    public var staleDays: Int = 180
    /// How many versioned siblings to keep when the owner is still installed.
    public var keepVersions: Int = 1
    /// Candidates below this size are noise; still listed, never proposed.
    public var minActionableBytes: Int64 = 10 * 1024 * 1024

    enum CodingKeys: String, CodingKey {
        case protectedBundlePrefixes = "protected_bundle_prefixes"
        case protectedPathContains = "protected_path_contains"
        case protectedNames = "protected_names"
        case aliases
        case regenerablePatterns = "regenerable_patterns"
        case delegatedCleanups = "delegated_cleanups"
        case staleDays = "stale_days"
        case keepVersions = "keep_versions"
        case minActionableBytes = "min_actionable_bytes"
    }

    public static var userRulesPath: String {
        "\(NSHomeDirectory())/.config/bleach/rules.yaml"
    }

    /// A user's `rules.yaml`. Every field is optional, because an overlay is
    /// expected to be a handful of lines rather than a full copy of the
    /// defaults.
    ///
    /// This is a separate type rather than a second `Rules` on purpose.
    /// Swift's synthesised `Decodable` ignores property default values, so
    /// decoding an overlay as `Rules` threw `keyNotFound` on the first key the
    /// user had not written — including for the partial overlay the docs
    /// recommend. Optional fields also mean "absent" and "set to the same
    /// value as the default" are finally distinguishable, so
    /// `stale_days: 180` is now a no-op instead of being silently ignored.
    struct Overlay: Decodable {
        var protectedBundlePrefixes: [String]?
        var protectedPathContains: [String]?
        var protectedNames: [String]?
        var aliases: [String: String]?
        var regenerablePatterns: [String]?
        var delegatedCleanups: [String: String]?
        var staleDays: Int?
        var keepVersions: Int?
        var minActionableBytes: Int64?

        enum CodingKeys: String, CodingKey {
            case protectedBundlePrefixes = "protected_bundle_prefixes"
            case protectedPathContains = "protected_path_contains"
            case protectedNames = "protected_names"
            case aliases
            case regenerablePatterns = "regenerable_patterns"
            case delegatedCleanups = "delegated_cleanups"
            case staleDays = "stale_days"
            case keepVersions = "keep_versions"
            case minActionableBytes = "min_actionable_bytes"
        }
    }

    /// Load defaults, then merge a user file over them if present.
    ///
    /// The merge is asymmetric, but only for the three `protected_*` lists:
    /// entries are appended, so an overlay cannot delete a shipped
    /// protection. Everything else is the user's call —
    /// `regenerable_patterns` is appended but *adds* ways for a path to be
    /// judged safe, and the thresholds are replaced outright — so an overlay
    /// can make bleach more aggressive as well as more careful.
    public static func load(userPath: String? = nil) throws -> Rules {
        var rules = try YAMLDecoder().decode(Rules.self, from: defaultYAML)
        let path = userPath ?? userRulesPath
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return rules
        }
        // A file containing nothing but comments parses to a null document,
        // which the decoder reports as a type mismatch. That is not a broken
        // overlay, it is the same as not having one — as happens the moment
        // someone comments out their whole rules file to test something.
        guard try Yams.load(yaml: text) != nil else { return rules }
        let overlay = try YAMLDecoder().decode(Overlay.self, from: text)

        // Append-only: protections can grow, never shrink.
        rules.protectedBundlePrefixes += overlay.protectedBundlePrefixes ?? []
        rules.protectedPathContains += overlay.protectedPathContains ?? []
        rules.protectedNames += overlay.protectedNames ?? []
        rules.regenerablePatterns += overlay.regenerablePatterns ?? []

        if let aliases = overlay.aliases { rules.aliases.merge(aliases) { _, new in new } }
        if let cleanups = overlay.delegatedCleanups {
            rules.delegatedCleanups.merge(cleanups) { _, new in new }
        }
        if let v = overlay.staleDays { rules.staleDays = v }
        if let v = overlay.keepVersions { rules.keepVersions = v }
        if let v = overlay.minActionableBytes { rules.minActionableBytes = v }
        return rules
    }

    // MARK: - Compiled matchers

    /// Precompiled regexes. Built once per scan rather than per candidate.
    public final class Compiled: @unchecked Sendable {
        public let rules: Rules
        let regenerable: [NSRegularExpression]

        init(_ rules: Rules) {
            self.rules = rules
            self.regenerable = rules.regenerablePatterns.compactMap {
                try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
            }
        }

        public func isRegenerable(name: String) -> String? {
            let range = NSRange(name.startIndex..., in: name)
            for (i, re) in regenerable.enumerated() {
                if re.firstMatch(in: name, options: [], range: range) != nil {
                    return rules.regenerablePatterns[i]
                }
            }
            return nil
        }

        public func protectedPathReason(_ path: String) -> String? {
            let lower = path.lowercased()
            for needle in rules.protectedPathContains where lower.contains(needle.lowercased()) {
                return needle
            }
            return nil
        }

        public func isProtectedName(_ name: String) -> Bool {
            rules.protectedNames.contains(name)
        }

        public func isProtectedBundleID(_ id: String) -> String? {
            let lower = id.lowercased()
            return rules.protectedBundlePrefixes.first { lower.hasPrefix($0.lowercased()) }
        }
    }

    public func compiled() -> Compiled { Compiled(self) }
}
