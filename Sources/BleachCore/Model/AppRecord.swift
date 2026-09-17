import Foundation

/// Where a piece of ownership information came from. Each source carries a
/// different confidence: Spotlight finding a live `.app` bundle on disk is
/// strong; a stale pkg receipt only proves something was *once* installed.
public enum InventorySource: String, Codable, Sendable, CaseIterable {
    case spotlight
    case launchServices
    case filesystem
    case homebrewCask
    case installReceipt
    case launchAgent
    case runningProcess
    case toolManaged

    /// Confidence that this source implies the owner is *currently present*.
    public var presenceConfidence: Double {
        switch self {
        case .runningProcess: return 1.0
        case .filesystem, .spotlight: return 0.95
        case .homebrewCask: return 0.9
        case .toolManaged: return 0.85
        case .launchAgent: return 0.7
        case .launchServices: return 0.6   // registry keeps stale entries
        case .installReceipt: return 0.25  // survives uninstall
        }
    }
}

/// An installed owner of on-disk state. Usually an app bundle, but also
/// covers non-bundle owners (Homebrew formulae, JetBrains Toolbox, global
/// npm/cargo binaries) that own large Library directories.
public struct AppRecord: Sendable, Codable {
    public var bundleID: String?
    /// `CFBundleName`, falling back to the bundle filename without `.app`.
    public var name: String?
    public var executable: String?
    public var path: String?
    public var teamID: String?
    public var sources: Set<InventorySource>
    public var lastUsed: Date?
    /// Whether `path` resolves on disk right now. A LaunchServices entry with
    /// `existsOnDisk == false` is exactly the stale-registry case.
    public var existsOnDisk: Bool

    public init(
        bundleID: String? = nil,
        name: String? = nil,
        executable: String? = nil,
        path: String? = nil,
        teamID: String? = nil,
        sources: Set<InventorySource> = [],
        lastUsed: Date? = nil,
        existsOnDisk: Bool = false
    ) {
        self.bundleID = bundleID
        self.name = name
        self.executable = executable
        self.path = path
        self.teamID = teamID
        self.sources = sources
        self.lastUsed = lastUsed
        self.existsOnDisk = existsOnDisk
    }

    /// Best available confidence that this owner is currently installed.
    public var presenceConfidence: Double {
        guard let best = sources.map(\.presenceConfidence).max() else { return 0 }
        // A path we checked and found missing overrides optimistic sources.
        if path != nil && !existsOnDisk { return min(best, 0.2) }
        return best
    }

    /// Merge another record for the same owner, unioning sources and
    /// preferring non-nil / on-disk-verified fields.
    public mutating func merge(_ other: AppRecord) {
        bundleID = bundleID ?? other.bundleID
        name = name ?? other.name
        executable = executable ?? other.executable
        teamID = teamID ?? other.teamID
        if path == nil || (!existsOnDisk && other.existsOnDisk) {
            path = other.path ?? path
            existsOnDisk = existsOnDisk || other.existsOnDisk
        }
        sources.formUnion(other.sources)
        if let o = other.lastUsed {
            lastUsed = max(lastUsed ?? o, o)
        }
    }
}
