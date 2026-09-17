import Foundation

/// Re-checks a plan entry against live state immediately before it is moved.
///
/// A plan is a file: it can be hours old, hand-edited, or copied from another
/// machine. So `apply` trusts nothing in it except the path, and re-derives
/// every safety property from scratch. This is intentionally redundant with
/// the classifier — the classifier decides what to *propose*, this decides
/// what is *permitted*.
public struct ApplyValidator: Sendable {
    let home: String
    let rules: Rules.Compiled
    let inventory: AppInventory
    /// Allow tiers the classifier would not normally propose (REVIEW,
    /// UNKNOWN) when the user opted in explicitly.
    let allowNonActionableTiers: Bool
    /// How much a directory may have grown since the plan was written before
    /// we treat it as "something changed here, ask again".
    let growthTolerance: Double

    public init(
        home: String = NSHomeDirectory(),
        rules: Rules.Compiled,
        inventory: AppInventory,
        allowNonActionableTiers: Bool = false,
        growthTolerance: Double = 1.5
    ) {
        self.home = home
        self.rules = rules
        self.inventory = inventory
        self.allowNonActionableTiers = allowNonActionableTiers
        self.growthTolerance = growthTolerance
    }

    /// Returns a refusal reason, or nil if the entry may proceed.
    public func reasonToRefuse(_ entry: RemovalPlan.Entry) -> String? {
        let fm = FileManager.default
        let path = entry.path

        // --- shape -------------------------------------------------------
        guard path.hasPrefix("/") else { return "not an absolute path" }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { return "path is not standardised (possible traversal)" }
        guard path.hasPrefix(home + "/") else { return "outside your home directory" }
        guard path != home else { return "is your home directory" }

        // --- existence and type ------------------------------------------
        guard fm.fileExists(atPath: path) else { return "no longer exists" }
        if let attrs = try? fm.attributesOfItem(atPath: path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return "is a symlink"
        }

        // --- current protections -----------------------------------------
        if let reason = rules.protectedPathReason(path) {
            return "now matches protected path rule \"\(reason)\""
        }
        let leaf = (path as NSString).lastPathComponent
        if rules.isProtectedName(leaf) {
            return "\"\(leaf)\" is a protected name"
        }
        if Normalizer.looksLikeBundleID(leaf), let prefix = rules.isProtectedBundleID(leaf) {
            return "bundle ID matches protected prefix \(prefix)"
        }

        // --- live state ---------------------------------------------------
        if inventory.hasRunningProcess(under: path) {
            return "a process is running from this path"
        }
        if inventory.containsAppBundle(under: path) {
            return "an installed app bundle lives inside"
        }

        // --- tier ---------------------------------------------------------
        if !entry.tier.isActionable && !allowNonActionableTiers {
            return "tier \(entry.tier.label) needs --allow-review to apply"
        }

        // --- drift --------------------------------------------------------
        // Re-measuring is cheap relative to the cost of being wrong.
        let stats = DirectoryWalker.stats(of: path, collectUserData: false)
        if entry.sizeBytes > 0 {
            let ratio = Double(stats.sizeBytes) / Double(entry.sizeBytes)
            if ratio > growthTolerance {
                return String(format:
                    "grew %.1f× since the plan was written (%@ → %@); rescan first",
                    ratio,
                    ByteFormat.short(entry.sizeBytes).trimmingCharacters(in: .whitespaces),
                    ByteFormat.short(stats.sizeBytes).trimmingCharacters(in: .whitespaces))
            }
        }
        if stats.accessDenied {
            return "partially unreadable; grant Full Disk Access and rescan"
        }

        return nil
    }
}
