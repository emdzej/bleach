import Foundation

/// A single observation about a candidate directory.
///
/// Sign convention: `weight > 0` argues the directory is **in use** (keep),
/// `weight < 0` argues it is **abandoned** (clean). The classifier sums
/// weights into a score, but tiering is rule-driven first and score-driven
/// only as a tiebreak — we never let a pile of weak signals outvote a
/// protected-path match.
public struct Evidence: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        // --- ownership resolution ---
        case bundleIDMatch
        case nameMatch
        case aliasMatch
        case teamIDMatch
        case noOwnerFound
        case ownerMissingFromDisk

        // --- corroborating "this app is real / alive" ---
        case runningProcess
        case launchAgent
        case preferencesPlist
        case savedState
        case installReceipt
        case homebrewCask
        case siblingSet

        // --- activity ---
        case stale
        case recentActivity

        // --- content and rules ---
        case userDataMarker
        case protectedPath
        case containsInstalledApp
        case cacheRule
        case versionSibling
        case delegatedCleanup
        case emptyDirectory
    }

    public var kind: Kind
    public var detail: String
    public var weight: Double

    public init(_ kind: Kind, _ detail: String, weight: Double) {
        self.kind = kind
        self.detail = detail
        self.weight = weight
    }
}
