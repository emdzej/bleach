import Foundation

/// How confident we are that a candidate directory can be removed.
///
/// Ordering matters: the classifier assigns the *most protective* tier that
/// applies, never the most aggressive one. A directory that looks like a
/// regenerable cache but also sits under a protected path stays `protected`.
public enum Tier: String, Codable, CaseIterable, Sendable {
    /// Never touch. System-owned, live process, credentials, iCloud mirrors.
    case protected
    /// Owner is installed and this path is a known-regenerable cache.
    case cacheSafe
    /// No owner found from any inventory source, and the contents are stale.
    case orphanLikely
    /// Ambiguous: unmatched but recently active, or contains user-data markers.
    case review
    /// Default. Reported, never acted on.
    case unknown

    /// Lower is more protective. Used to collapse multiple rule hits.
    public var protectiveRank: Int {
        switch self {
        case .protected: return 0
        case .unknown: return 1
        case .review: return 2
        case .orphanLikely: return 3
        case .cacheSafe: return 4
        }
    }

    /// Whether `plan` is allowed to propose removal for this tier without
    /// the user explicitly opting the path in by hand.
    public var isActionable: Bool {
        self == .cacheSafe || self == .orphanLikely
    }

    public var label: String {
        switch self {
        case .protected: return "PROTECTED"
        case .cacheSafe: return "CACHE-SAFE"
        case .orphanLikely: return "ORPHAN?"
        case .review: return "REVIEW"
        case .unknown: return "UNKNOWN"
        }
    }
}

extension Tier {
    /// Pick the more protective of two tiers.
    public static func mostProtective(_ a: Tier, _ b: Tier) -> Tier {
        a.protectiveRank <= b.protectiveRank ? a : b
    }
}
