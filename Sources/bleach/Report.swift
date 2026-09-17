import BleachCore
import BleachTUI
import Foundation

enum Report {
    static func render(
        _ result: ScanResult,
        tierFilter: Tier?,
        minSize: Int64,
        limit: Int,
        byOwner: Bool,
        explain: Bool
    ) {
        header(result)

        var rows = result.candidates.filter { $0.sizeBytes >= minSize }
        if let tierFilter { rows = rows.filter { $0.tier == tierFilter } }

        if byOwner {
            renderGroups(result, tierFilter: tierFilter, minSize: minSize, limit: limit)
        } else {
            renderRows(rows, limit: limit, explain: explain)
        }

        footer(result)
    }

    // MARK: - Header

    private static func header(_ result: ScanResult) {
        let inv = result.inventory
        print("")
        print(ANSI.bold("  bleach") + ANSI.grey("  ·  \(inv.summary)"))
        print(ANSI.grey("  scanned \(result.candidates.count) paths, "
            + "\(ByteFormat.short(result.totalBytes)) total, "
            + String(format: "%.1fs", result.elapsed)))
        print("")

        // Tier breakdown: the number that matters is reclaimable bytes, not
        // path counts, so lead with size.
        var parts: [String] = []
        for tier in [Tier.cacheSafe, .orphanLikely, .review, .protected, .unknown] {
            let items = result.candidates.filter { $0.tier == tier }
            guard !items.isEmpty else { continue }
            let bytes = items.reduce(Int64(0)) { $0 + $1.sizeBytes }
            parts.append("\(TierStyle.colored(tier).trimmingCharacters(in: .whitespaces)) "
                + ANSI.bold(ByteFormat.short(bytes).trimmingCharacters(in: .whitespaces))
                + ANSI.grey(" (\(items.count))"))
        }
        print("  " + parts.joined(separator: ANSI.grey("   ")))
        print("")

        if result.needsFullDiskAccess {
            print(ANSI.yellow("  ! \(result.accessDeniedCount) paths were unreadable — sizes are undercounts."))
            print(ANSI.grey("    Grant Full Disk Access to your terminal in"))
            print(ANSI.grey("    System Settings > Privacy & Security > Full Disk Access."))
            print("")
        }
    }

    // MARK: - Flat rows

    private static func renderRows(_ rows: [Candidate], limit: Int, explain: Bool) {
        guard !rows.isEmpty else {
            print(ANSI.grey("  nothing matched."))
            return
        }
        let shown = limit <= 0 ? rows : Array(rows.prefix(limit))
        let nameWidth = 38

        print(ANSI.grey("  " + ANSI.pad("TIER", to: 11) + ANSI.pad("SIZE", to: 7)
            + ANSI.pad("AGE", to: 7) + ANSI.pad("WHERE", to: 17)
            + ANSI.pad("NAME", to: nameWidth) + "OWNER"))

        for c in shown {
            let owner: String
            if let rec = c.owner {
                let label = rec.name ?? rec.bundleID ?? "?"
                owner = rec.existsOnDisk && rec.presenceConfidence >= 0.4
                    ? label
                    : ANSI.yellow(label + " (gone)")
            } else {
                owner = ANSI.grey("—")
            }
            print("  "
                + TierStyle.colored(c.tier) + " "
                + ANSI.pad(ByteFormat.short(c.sizeBytes), to: 7)
                + ANSI.pad(ByteFormat.age(c.newestMTime), to: 7)
                + ANSI.grey(ANSI.pad(c.rootID, to: 17))
                + ANSI.pad(ANSI.truncateTail((c.name as NSString).lastPathComponent, to: nameWidth - 1), to: nameWidth)
                + owner)

            if explain {
                for e in c.evidence where e.kind != .cacheRule || e.detail.hasPrefix("tiered") {
                    let sign = e.weight > 0 ? ANSI.green("keep") : (e.weight < 0 ? ANSI.yellow("clean") : ANSI.grey("info"))
                    print("      " + sign + " " + ANSI.grey("\(e.kind.rawValue): \(e.detail)"))
                }
                print("")
            }
        }

        if limit > 0, rows.count > limit {
            let hidden = rows.count - limit
            let hiddenBytes = rows.dropFirst(limit).reduce(Int64(0)) { $0 + $1.sizeBytes }
            print(ANSI.grey("  … \(hidden) more rows, \(ByteFormat.short(hiddenBytes)) — use --limit 0"))
        }
    }

    // MARK: - Grouped by owner

    private static func renderGroups(_ result: ScanResult, tierFilter: Tier?, minSize: Int64, limit: Int) {
        var groups = result.groups
        if let tierFilter { groups = groups.filter { $0.tier == tierFilter } }
        groups = groups.filter { $0.totalBytes >= minSize }
        let shown = limit <= 0 ? groups : Array(groups.prefix(limit))

        for g in shown {
            let owner = g.owner
            let status = owner.map { rec -> String in
                rec.existsOnDisk
                    ? ANSI.green("installed")
                    : ANSI.yellow("not on disk")
            } ?? ANSI.red("unresolved")

            print("  " + TierStyle.colored(g.tier) + " "
                + ANSI.pad(ByteFormat.short(g.totalBytes), to: 8)
                + ANSI.bold(ANSI.pad(ANSI.truncateTail(g.displayName, to: 34), to: 36))
                + status)
            for c in g.candidates where c.sizeBytes > 0 {
                print("      " + ANSI.grey(ANSI.pad(ByteFormat.short(c.sizeBytes), to: 8)
                    + ANSI.pad(c.rootID, to: 18)
                    + ANSI.truncateTail((c.name as NSString).lastPathComponent, to: 44)))
            }
        }
        if limit > 0, groups.count > limit {
            print(ANSI.grey("  … \(groups.count - limit) more owners — use --limit 0"))
        }
    }

    /// Paths outside `$HOME`. Shown with their evidence so the total is
    /// honest, and with the command you would run yourself — bleach does not
    /// take root to do it for you.
    private static func renderSystemSection(_ result: ScanResult) {
        let system = result.candidates
            .filter { $0.requiresRoot && $0.tier.isActionable && !$0.supersededByChildren }
            .sorted { $0.sizeBytes > $1.sizeBytes }
        guard !system.isEmpty else { return }

        let bytes = system.reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print("  " + ANSI.bold("Outside your home — needs sudo, bleach will not touch these:")
            + ANSI.grey("  \(ByteFormat.short(bytes).trimmingCharacters(in: .whitespaces))"))
        for c in system.prefix(8) {
            print("    " + ANSI.pad(ByteFormat.short(c.sizeBytes), to: 8)
                + TierStyle.colored(c.tier) + " "
                + ANSI.truncateHead(c.path, to: 58))
        }
        if system.count > 8 {
            print("    " + ANSI.grey("… \(system.count - 8) more — bleach scan --tier orphan --limit 0"))
        }
        print("    " + ANSI.grey("sizes are undercounts without root; verify before removing"))
    }

    // MARK: - Footer

    private static func footer(_ result: ScanResult) {
        let delegated = result.candidates.compactMap { c -> (String, Int64, String)? in
            guard let e = c.evidence.first(where: { $0.kind == .delegatedCleanup }) else { return nil }
            let cmd = e.detail
                .replacingOccurrences(of: "owner ships its own cleanup: `", with: "")
                .replacingOccurrences(of: "`", with: "")
            return ((c.name as NSString).lastPathComponent, c.sizeBytes, cmd)
        }
        .sorted { $0.1 > $1.1 }

        if !delegated.isEmpty {
            print("")
            print(ANSI.bold("  Delegate these — the tool knows its own retention policy:"))
            for (name, bytes, cmd) in delegated.prefix(8) {
                print("    " + ANSI.pad(ByteFormat.short(bytes), to: 8)
                    + ANSI.pad(ANSI.truncateTail(name, to: 17), to: 19)
                    + ANSI.cyan(cmd))
            }
        }

        // System paths are reported above but excluded here: they are not
        // reclaimable *by bleach*, and quoting them in this figure would
        // promise something the tool deliberately cannot do.
        renderSystemSection(result)

        let reclaimable = result.candidates
            .filter { $0.tier.isActionable && !$0.requiresRoot && !$0.supersededByChildren }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        print("")
        print("  " + ANSI.bold(ByteFormat.short(reclaimable).trimmingCharacters(in: .whitespaces))
            + " in actionable tiers. "
            + ANSI.grey("Next: bleach tui, or bleach plan -o plan.json"))
        print("")
    }
}
