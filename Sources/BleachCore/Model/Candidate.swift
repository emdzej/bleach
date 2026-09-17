import Foundation

/// One directory (or preference file) that bleach has measured, attributed to
/// an owner, and tiered. This is the unit the TUI lists and the plan file
/// records.
public struct Candidate: Codable, Sendable, Identifiable {
    public var id: String { path }

    public var path: String
    /// Leaf name, e.g. `IntelliJIdea2025.3` or `com.raycast.macos`.
    public var name: String
    /// Which `ScanRoot` this came from.
    public var rootID: String
    public var kind: ScanRootKind
    public var isDirectory: Bool

    public var sizeBytes: Int64
    public var fileCount: Int
    /// Newest mtime of anything *inside* the directory. The directory's own
    /// mtime is unreliable — it changes when unrelated metadata churns.
    public var newestMTime: Date?

    public var owner: AppRecord?
    /// Stable key used to group sibling directories belonging to one owner
    /// across App Support / Caches / Containers / Preferences / ...
    public var ownerKey: String?

    public var evidence: [Evidence]
    public var tier: Tier
    public var score: Double
    /// `true` when the tier came from an inviolable rule (live process,
    /// protected path, contains an installed app bundle) rather than from the
    /// soft "its owner happens to be installed" case. Only soft protections
    /// may be demoted by later passes such as version retention.
    public var hardProtected: Bool = false
    /// Tier a plugin asked for. Applied after core classification, and only
    /// when core did not *hard*-protect the path — so a plugin can sharpen a
    /// verdict but never override a real protection.
    public var pluginTierHint: Tier?
    /// Plugin that surfaced or annotated this candidate, for display.
    public var pluginName: String?
    /// True when another candidate lives inside this one — typically because
    /// a plugin split this directory into finer parts. Such a candidate is
    /// excluded from totals and from every actionable tier: its bytes are
    /// already counted by its children, and acting on the parent would
    /// silently take the children's protected siblings with it.
    public var supersededByChildren: Bool = false
    /// Lives outside `$HOME`. Reported for an honest total, never plannable.
    /// `ApplyValidator` independently refuses these, so this flag is about
    /// not *offering* the path rather than about preventing the action.
    public var requiresRoot: Bool = false

    public init(
        path: String,
        name: String,
        rootID: String,
        kind: ScanRootKind,
        isDirectory: Bool,
        sizeBytes: Int64 = 0,
        fileCount: Int = 0,
        newestMTime: Date? = nil,
        owner: AppRecord? = nil,
        ownerKey: String? = nil,
        evidence: [Evidence] = [],
        tier: Tier = .unknown,
        score: Double = 0,
        hardProtected: Bool = false,
        requiresRoot: Bool = false
    ) {
        self.path = path
        self.name = name
        self.rootID = rootID
        self.kind = kind
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.newestMTime = newestMTime
        self.owner = owner
        self.ownerKey = ownerKey
        self.evidence = evidence
        self.tier = tier
        self.score = score
        self.hardProtected = hardProtected
        self.requiresRoot = requiresRoot
    }

    public var daysSinceTouched: Int? {
        guard let m = newestMTime else { return nil }
        return Calendar.current.dateComponents([.day], from: m, to: Date()).day
    }
}

/// A set of candidates that all belong to one owner. Deleting the *set* is
/// what makes the reclaim worthwhile — and a set matching across several
/// locations is itself strong evidence the owner ID is right.
public struct CandidateGroup: Sendable, Identifiable {
    public var id: String { key }
    public var key: String
    public var displayName: String
    public var owner: AppRecord?
    public var candidates: [Candidate]

    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.sizeBytes } }
    /// The group inherits the most protective tier among its members, so a
    /// single protected path keeps the whole set out of the actionable list.
    public var tier: Tier {
        candidates.map(\.tier).reduce(Tier.cacheSafe, Tier.mostProtective)
    }

    public init(key: String, displayName: String, owner: AppRecord?, candidates: [Candidate]) {
        self.key = key
        self.displayName = displayName
        self.owner = owner
        self.candidates = candidates
    }
}
