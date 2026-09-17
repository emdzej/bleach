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

    /// Load defaults, then merge a user file over them if present. Lists are
    /// appended (so a user can only ever *add* protections) and scalars are
    /// replaced.
    public static func load(userPath: String? = nil) throws -> Rules {
        var rules = try YAMLDecoder().decode(Rules.self, from: defaultYAML)
        let path = userPath ?? userRulesPath
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return rules
        }
        let overlay = try YAMLDecoder().decode(Rules.self, from: text)
        rules.protectedBundlePrefixes += overlay.protectedBundlePrefixes
        rules.protectedPathContains += overlay.protectedPathContains
        rules.protectedNames += overlay.protectedNames
        rules.regenerablePatterns += overlay.regenerablePatterns
        rules.aliases.merge(overlay.aliases) { _, new in new }
        rules.delegatedCleanups.merge(overlay.delegatedCleanups) { _, new in new }
        if overlay.staleDays != Rules().staleDays { rules.staleDays = overlay.staleDays }
        if overlay.keepVersions != Rules().keepVersions { rules.keepVersions = overlay.keepVersions }
        if overlay.minActionableBytes != Rules().minActionableBytes {
            rules.minActionableBytes = overlay.minActionableBytes
        }
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
