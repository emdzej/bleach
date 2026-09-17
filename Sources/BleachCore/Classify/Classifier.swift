import Foundation

/// Turns evidence into a tier.
///
/// Rules run in a fixed, most-protective-first order. Score is only a
/// tiebreak inside a tier — a pile of weak "looks abandoned" signals must
/// never be able to outvote a single protected-path match.
public struct Classifier: Sendable {
    let rules: Rules.Compiled
    let inventory: AppInventory

    public init(rules: Rules.Compiled, inventory: AppInventory) {
        self.rules = rules
        self.inventory = inventory
    }

    public func classify(_ input: Candidate) -> Candidate {
        var c = input
        c.score = c.evidence.reduce(0) { $0 + $1.weight }
        let leaf = (c.name as NSString).lastPathComponent

        // ---- 0. Hard protections ------------------------------------------
        if c.evidence.contains(where: { $0.kind == .runningProcess }) {
            return finish(&c, .protected, "live process", hard: true)
        }
        if let reason = rules.protectedPathReason(c.path) {
            c.evidence.append(Evidence(.protectedPath, "path contains \"\(reason)\"", weight: 20))
            return finish(&c, .protected, "protected path", hard: true)
        }
        if rules.isProtectedName(leaf) {
            c.evidence.append(Evidence(.protectedPath, "\"\(leaf)\" is a protected name", weight: 20))
            return finish(&c, .protected, "protected name", hard: true)
        }
        if let id = c.owner?.bundleID ?? bundleIDGuess(c), let prefix = rules.isProtectedBundleID(id) {
            c.evidence.append(Evidence(.protectedPath,
                "bundle ID \(id) matches protected prefix \(prefix)", weight: 20))
            return finish(&c, .protected, "protected bundle prefix", hard: true)
        }
        // ---- 1. Delegated cleanups ----------------------------------------
        // Ahead of the nested-app rule on purpose: ms-playwright's browser
        // caches contain registered .app bundles but are fully reinstallable,
        // and REVIEW is non-actionable either way.
        if let command = rules.rules.delegatedCleanups[leaf]
            ?? rules.rules.delegatedCleanups[c.name.split(separator: "/").first.map(String.init) ?? ""] {
            c.evidence.append(Evidence(.delegatedCleanup,
                "owner ships its own cleanup: `\(command)`", weight: 0))
            return finish(&c, .review, "delegated")
        }

        // Self-updating apps (Raycast, many Electron apps) keep their real
        // binary under Application Support — deleting that uninstalls the app.
        if c.evidence.contains(where: { $0.kind == .containsInstalledApp }) {
            return finish(&c, .protected, "contains an installed app", hard: true)
        }
        // LaunchAgents are configuration, not bulk. Removing one changes
        // behaviour rather than reclaiming space, so it needs a human.
        if c.kind == .launchAgent {
            return finish(&c, .review, "launchd job")
        }

        let ownerPresent = (c.owner?.presenceConfidence ?? 0) >= 0.6
        let noOwner = c.evidence.contains { $0.kind == .noOwnerFound }
            || c.evidence.contains { $0.kind == .ownerMissingFromDisk }
        let hasUserData = c.evidence.contains { $0.kind == .userDataMarker }
        let isStale = c.evidence.contains { $0.kind == .stale }
        let recent = c.evidence.contains { $0.kind == .recentActivity }

        // ---- 2. Regenerable state -----------------------------------------
        // Safe for installed owners *and* orphans; the app rebuilds it.
        if let pattern = rules.isRegenerable(name: leaf) ?? (c.kind.regenerable ? "root:\(c.rootID)" : nil) {
            c.evidence.append(Evidence(.cacheRule,
                "matches regenerable rule \(pattern)", weight: 0))
            if hasUserData {
                return finish(&c, .review, "regenerable but holds user-data-shaped files")
            }
            return finish(&c, .cacheSafe, "regenerable")
        }

        // ---- 3. Orphans ----------------------------------------------------
        if noOwner && !recent {
            if hasUserData {
                return finish(&c, .review, "unowned but holds user-data-shaped files")
            }
            if isStale || c.fileCount == 0 {
                return finish(&c, .orphanLikely, "no owner and stale")
            }
            // Unowned but touched within the stale window: something is still
            // writing here, we just can't say what.
            return finish(&c, .review, "no owner but recently active")
        }

        // ---- 4. Version siblings of an installed owner ---------------------
        if ownerPresent, c.evidence.contains(where: { $0.kind == .versionSibling }), isStale, !hasUserData {
            return finish(&c, .orphanLikely, "stale version-scoped state of an installed app")
        }

        // ---- 5. Owner is installed: leave its state alone ------------------
        if ownerPresent {
            // Soft: the owner being installed is a reason to leave its state
            // alone by default, but not an inviolable one. Version retention
            // is allowed to demote this.
            return finish(&c, .protected, "owner installed", hard: false)
        }

        return finish(&c, .unknown, "insufficient evidence")
    }

    /// For unmatched directories, the leaf name itself may be the bundle ID.
    private func bundleIDGuess(_ c: Candidate) -> String? {
        let leaf = (c.name as NSString).lastPathComponent
        if Normalizer.looksLikeBundleID(leaf) { return leaf }
        if let (_, rest) = Normalizer.splitTeamPrefix(leaf) { return rest }
        return nil
    }

    private func finish(
        _ c: inout Candidate, _ tier: Tier, _ reason: String, hard: Bool = false
    ) -> Candidate {
        c.tier = tier
        c.hardProtected = hard
        c.score = c.evidence.reduce(0) { $0 + $1.weight }
        // Sub-threshold candidates are reported but never proposed, so a
        // 40 KB orphan can't clutter an actionable plan.
        if tier.isActionable, c.sizeBytes < rules.rules.minActionableBytes {
            c.tier = .unknown
        }
        c.evidence.append(Evidence(.cacheRule, "tiered \(c.tier.label): \(reason)", weight: 0))
        return c
    }

    /// Version-sibling retention: among candidates that reduce to the same
    /// version-stripped key, keep the newest `keepVersions` and mark the rest.
    /// Runs after classification because it needs the whole set.
    public func applyVersionRetention(_ candidates: [Candidate]) -> [Candidate] {
        var byKey: [String: [Int]] = [:]
        for (i, c) in candidates.enumerated() {
            let leaf = (c.name as NSString).lastPathComponent
            let stripped = Normalizer.versionStripped(leaf)
            guard stripped.count >= 3, stripped != Normalizer.canonical(leaf) else { continue }
            byKey["\(c.rootID)/\(stripped)", default: []].append(i)
        }

        var out = candidates
        for (_, indices) in byKey where indices.count > rules.rules.keepVersions {
            // Newest first by internal mtime.
            let ordered = indices.sorted {
                (candidates[$0].newestMTime ?? .distantPast) > (candidates[$1].newestMTime ?? .distantPast)
            }
            for (rank, idx) in ordered.enumerated() {
                if rank < rules.rules.keepVersions {
                    out[idx].evidence.append(Evidence(.versionSibling,
                        "newest of \(indices.count) versions — kept", weight: 5))
                    out[idx].tier = .mostProtective(out[idx].tier, .protected)
                } else if !out[idx].hardProtected {
                    out[idx].evidence.append(Evidence(.versionSibling,
                        "superseded: \(rank) newer version(s) of this state exist", weight: -6))
                    if out[idx].sizeBytes >= rules.rules.minActionableBytes,
                       !out[idx].evidence.contains(where: { $0.kind == .userDataMarker }) {
                        out[idx].tier = .orphanLikely
                    }
                }
            }
        }
        return out
    }
}
