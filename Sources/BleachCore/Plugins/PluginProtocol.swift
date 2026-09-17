import Foundation

/// Wire format for plugins, version 1.
///
/// Plugins are plain executables in any language that speak JSON on stdio.
/// That keeps the contribution barrier at "write a 40-line script" rather
/// than "learn Swift and rebuild bleach".
///
/// The security model is deliberately narrow: a plugin **proposes** candidates
/// and evidence. It never deletes, never receives file contents, and cannot
/// weaken a core protection. Everything it returns is re-validated against
/// its declared scope and re-tiered through the normal classifier.
public enum PluginProtocolVersion {
    public static let current = 1
}

public struct PluginManifest: Codable, Sendable {
    public var protocolVersion: Int
    public var name: String
    public var description: String
    /// `enumerate`, `resolve`, or both.
    public var capabilities: [String]
    /// Path prefixes this plugin is allowed to speak about. `~` is expanded.
    /// Anything it returns outside these prefixes is discarded.
    public var owns: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case name, description, capabilities, owns
    }

    public var canEnumerate: Bool { capabilities.contains("enumerate") }
    public var canResolve: Bool { capabilities.contains("resolve") }

    public func expandedOwns(home: String) -> [String] {
        owns.map { path in
            path.hasPrefix("~")
                ? home + String(path.dropFirst())
                : path
        }
        .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

// MARK: - Requests

public struct PluginEnumerateRequest: Codable, Sendable {
    public var protocolVersion: Int = PluginProtocolVersion.current
    public var home: String
    public var staleDays: Int
    /// The subset of the plugin's `owns` prefixes that actually exist.
    public var scope: [String]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case home
        case staleDays = "stale_days"
        case scope
    }
}

public struct PluginResolveRequest: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public var path: String
        public var name: String
        public var rootID: String
        public var sizeBytes: Int64

        enum CodingKeys: String, CodingKey {
            case path, name
            case rootID = "root_id"
            case sizeBytes = "size_bytes"
        }
    }

    public var protocolVersion: Int = PluginProtocolVersion.current
    public var home: String
    public var staleDays: Int
    public var candidates: [Item]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case home
        case staleDays = "stale_days"
        case candidates
    }
}

// MARK: - Responses

public struct PluginEvidence: Codable, Sendable {
    public var kind: String
    public var detail: String
    public var weight: Double

    /// Map to a core evidence kind, falling back to a generic bucket so an
    /// unknown kind from a newer plugin degrades instead of failing.
    public func toEvidence(pluginName: String) -> Evidence {
        let mapped = Evidence.Kind(rawValue: kind) ?? .stale
        // Clamped so a plugin cannot overwhelm core scoring.
        let clamped = max(-10, min(10, weight))
        return Evidence(mapped, "[\(pluginName)] \(detail)", weight: clamped)
    }
}

public struct PluginCandidate: Codable, Sendable {
    public var path: String
    public var label: String?
    public var kind: String?
    public var tierHint: String?
    public var evidence: [PluginEvidence]?

    enum CodingKeys: String, CodingKey {
        case path, label, kind, evidence
        case tierHint = "tier_hint"
    }
}

public struct PluginEnumerateResponse: Codable, Sendable {
    public var protocolVersion: Int?
    public var candidates: [PluginCandidate]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case candidates
    }
}

public struct PluginResolution: Codable, Sendable {
    public var path: String
    public var ownerName: String?
    public var ownerBundleID: String?
    public var tierHint: String?
    public var evidence: [PluginEvidence]?

    enum CodingKeys: String, CodingKey {
        case path
        case ownerName = "owner_name"
        case ownerBundleID = "owner_bundle_id"
        case tierHint = "tier_hint"
        case evidence
    }
}

public struct PluginResolveResponse: Codable, Sendable {
    public var protocolVersion: Int?
    public var resolutions: [PluginResolution]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case resolutions
    }
}

extension Tier {
    /// Parse a plugin's tier hint. Unknown strings become `.unknown` (report
    /// only) rather than anything actionable.
    static func fromHint(_ s: String?) -> Tier? {
        switch s?.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "cache_safe", "cachesafe": return .cacheSafe
        case "orphan_likely", "orphanlikely", "orphan": return .orphanLikely
        case "review": return .review
        case "protected": return .protected
        case "unknown": return .unknown
        default: return nil
        }
    }
}
