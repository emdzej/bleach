import Foundation

/// Attributes a candidate directory to an owner and records *why*.
///
/// There is no filesystem link from `~/Library/Application Support/Foo` back
/// to an app, so this is an evidence-gathering pass, not a lookup. Every
/// branch appends `Evidence` and the classifier decides what the pile means.
public struct Resolver: Sendable {
    let inventory: AppInventory
    let rules: Rules.Compiled
    let home: String

    public init(inventory: AppInventory, rules: Rules.Compiled, home: String = NSHomeDirectory()) {
        self.inventory = inventory
        self.rules = rules
        self.home = home
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"
    )

    public func resolve(_ input: Candidate) -> Candidate {
        var c = input
        let leaf = (c.name as NSString).lastPathComponent

        // --- UUID-named sandbox containers -------------------------------
        // Their metadata plist is entitlement-protected and unreadable, so we
        // can never establish an owner. Unknowable means untouchable.
        if c.kind == .container, Self.matchesUUID(leaf) {
            c.evidence.append(Evidence(.protectedPath,
                "UUID-named container; owner metadata is unreadable without entitlements",
                weight: 10))
            c.ownerKey = "uuid-container"
            return c
        }

        // --- 1. Alias table (highest-precedence identification) ----------
        if let aliased = rules.rules.aliases[c.name] ?? rules.rules.aliases[leaf] {
            c.evidence.append(Evidence(.aliasMatch, "alias -> \(aliased)", weight: 0))
            if let rec = inventory.record(bundleID: aliased) {
                attach(&c, rec, via: .aliasMatch, detail: "alias -> \(aliased)")
                return corroborate(c, bundleID: rec.bundleID ?? aliased)
            }
            c.ownerKey = aliased.lowercased()
            c.evidence.append(Evidence(.ownerMissingFromDisk,
                "alias resolves to \(aliased), which is not installed", weight: -4))
            return corroborate(c, bundleID: aliased)
        }

        // --- 2. Directory is literally a bundle identifier ---------------
        if Normalizer.looksLikeBundleID(leaf) {
            if let rec = inventory.record(bundleID: leaf) {
                attach(&c, rec, via: .bundleIDMatch, detail: "bundle ID \(leaf)")
                return corroborate(c, bundleID: leaf)
            }
            c.ownerKey = leaf.lowercased()
            c.evidence.append(Evidence(.noOwnerFound,
                "\(leaf) looks like a bundle ID but no installed app claims it", weight: -5))
            return corroborate(c, bundleID: leaf)
        }

        // --- 3. App Group container with a team-ID prefix ----------------
        if let (team, rest) = Normalizer.splitTeamPrefix(leaf) {
            if let rec = inventory.record(bundleID: rest) {
                attach(&c, rec, via: .bundleIDMatch, detail: "group container for \(rest)")
                return corroborate(c, bundleID: rest)
            }
            let byTeam = inventory.records(teamID: team).filter(\.existsOnDisk)
            if let rec = byTeam.first {
                attach(&c, rec, via: .teamIDMatch,
                       detail: "team \(team) -> \(rec.name ?? rec.bundleID ?? "?")")
                return corroborate(c, bundleID: rest)
            }
            c.ownerKey = rest.lowercased()
            c.evidence.append(Evidence(.noOwnerFound,
                "no installed app signed by team \(team)", weight: -5))
            return corroborate(c, bundleID: rest)
        }

        // --- 4. Exact canonical name match -------------------------------
        let canonical = Normalizer.canonical(leaf)
        let nameMatches = inventory.records(canonicalName: canonical)
        if let rec = bestMatch(nameMatches) {
            attach(&c, rec, via: .nameMatch, detail: "name \(leaf) -> \(rec.bundleID ?? rec.name ?? "?")")
            return corroborate(c, bundleID: rec.bundleID)
        }

        // --- 5. Version-stripped match: the app is installed, this is an
        //        older version's leftover state. ---------------------------
        let stripped = Normalizer.versionStripped(leaf)
        // A floor of 4 characters: shorter stems match far too much. Without
        // it, ".m2" reduces to "m" and cheerfully resolves to a Homebrew
        // formula named "m4".
        if stripped.count >= 4, stripped != canonical {
            let versionMatches = inventory.records(versionStripped: stripped)
            if let rec = bestMatch(versionMatches) {
                attach(&c, rec, via: .versionSibling,
                       detail: "versioned state for \(rec.name ?? rec.bundleID ?? stripped)")
                c.evidence.append(Evidence(.versionSibling,
                    "owner is installed but this directory is version-scoped", weight: -1))
                return corroborate(c, bundleID: rec.bundleID)
            }
        }

        // --- 6. Nothing matched ------------------------------------------
        c.ownerKey = canonical
        c.evidence.append(Evidence(.noOwnerFound,
            "no inventory source claims \"\(leaf)\"", weight: -4))
        return corroborate(c, bundleID: nil)
    }

    // MARK: - Helpers

    static func matchesUUID(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return uuidPattern.firstMatch(in: s.uppercased(), options: [], range: range) != nil
    }

    /// Prefer records we verified on disk, then by source confidence.
    private func bestMatch(_ records: [AppRecord]) -> AppRecord? {
        records.max { a, b in a.presenceConfidence < b.presenceConfidence }
            .flatMap { $0.presenceConfidence > 0.3 ? $0 : nil }
    }

    private func attach(_ c: inout Candidate, _ rec: AppRecord, via kind: Evidence.Kind, detail: String) {
        c.owner = rec
        c.ownerKey = (rec.bundleID ?? rec.name).map { $0.lowercased() }
        let sources = rec.sources.map(\.rawValue).sorted().joined(separator: "+")
        c.evidence.append(Evidence(kind, "\(detail) [\(sources)]",
                                   weight: 4 * rec.presenceConfidence))
        // A receipt-only or stale-registry record identifies the owner but is
        // not evidence it is installed. Slack is the canonical case: a pkg
        // receipt survives uninstallation, so without this the container
        // would look owned and be protected forever.
        if rec.presenceConfidence < 0.4 {
            let where_ = rec.path.map { "registry lists \($0) but it is gone from disk" }
                ?? "identified from \(sources) only, which does not imply it is installed"
            c.evidence.append(Evidence(.ownerMissingFromDisk, where_, weight: -5))
        }
    }

    /// Signals that don't depend on name matching at all. These are what let
    /// us act on a directory whose name resolved to nothing.
    private func corroborate(_ input: Candidate, bundleID: String?) -> Candidate {
        var c = input

        if inventory.hasRunningProcess(under: c.path) {
            c.evidence.append(Evidence(.runningProcess,
                "a live process is executing from this directory", weight: 20))
        }
        if inventory.containsAppBundle(under: c.path) {
            c.evidence.append(Evidence(.containsInstalledApp,
                "a registered .app bundle lives inside — this is a self-updater's real install",
                weight: 20))
        }

        if let id = bundleID {
            let fm = FileManager.default
            if fm.fileExists(atPath: "\(home)/Library/Preferences/\(id).plist") {
                c.evidence.append(Evidence(.preferencesPlist,
                    "\(id).plist present in Preferences", weight: 0.5))
            }
            if fm.fileExists(atPath: "\(home)/Library/Saved Application State/\(id).savedState") {
                c.evidence.append(Evidence(.savedState,
                    "saved window state exists, so the app has run", weight: 0.5))
            }
            if let job = inventory.launchJobs.first(where: { $0.label == id || $0.label.hasPrefix(id) }) {
                c.evidence.append(Evidence(.launchAgent,
                    job.programExists
                        ? "launchd job \(job.label) points at a live binary"
                        : "launchd job \(job.label) points at a missing binary",
                    weight: job.programExists ? 6 : -2))
            }
        }

        // Activity.
        if let days = c.daysSinceTouched {
            if days >= rules.rules.staleDays {
                c.evidence.append(Evidence(.stale,
                    "nothing modified inside for \(days) days", weight: -3))
            } else if days <= 14 {
                c.evidence.append(Evidence(.recentActivity,
                    "modified \(days) day(s) ago", weight: 5))
            }
        }

        if c.isDirectory, c.fileCount == 0 {
            c.evidence.append(Evidence(.emptyDirectory, "empty", weight: -1))
        }

        return c
    }
}
