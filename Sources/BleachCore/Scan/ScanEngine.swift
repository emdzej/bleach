import Foundation

public struct ScanOptions: Sendable {
    public var home: String
    public var roots: [ScanRoot]
    public var rulesPath: String?
    /// `lsregister -dump` costs several seconds. Skippable for fast reruns.
    public var includeLaunchServices: Bool
    public var userRulesOnly: Bool
    public var enablePlugins: Bool

    public init(
        home: String = NSHomeDirectory(),
        roots: [ScanRoot]? = nil,
        rulesPath: String? = nil,
        includeLaunchServices: Bool = true,
        userRulesOnly: Bool = false,
        enablePlugins: Bool = true
    ) {
        self.home = home
        self.roots = roots ?? ScanRoots.userDefaults(home: URL(fileURLWithPath: home))
        self.rulesPath = rulesPath
        self.includeLaunchServices = includeLaunchServices
        self.userRulesOnly = userRulesOnly
        self.enablePlugins = enablePlugins
    }
}

public struct ScanResult: Sendable {
    public var candidates: [Candidate]
    public var inventory: AppInventory
    public var rules: Rules
    public var accessDeniedCount: Int
    public var elapsed: TimeInterval
    public var loadedPlugins: [String] = []
    public var pluginWarnings: [PluginHost.Warning] = []

    /// Excludes candidates superseded by finer-grained children, so a byte
    /// is never counted twice.
    public var totalBytes: Int64 {
        candidates.lazy.filter { !$0.supersededByChildren }.reduce(0) { $0 + $1.sizeBytes }
    }

    public func candidates(tier: Tier) -> [Candidate] {
        candidates.filter { $0.tier == tier }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    public func bytes(tier: Tier) -> Int64 {
        candidates.lazy
            .filter { $0.tier == tier && !$0.supersededByChildren }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// Candidates grouped by owner, largest group first. Deleting the whole
    /// set for one owner is what makes the reclaim worthwhile.
    public var groups: [CandidateGroup] {
        var buckets: [String: [Candidate]] = [:]
        for c in candidates {
            buckets[c.ownerKey ?? "unresolved:\(c.name)", default: []].append(c)
        }
        return buckets.map { key, members in
            let owner = members.compactMap(\.owner).first
            let display = owner?.name
                ?? owner?.bundleID
                ?? members.first.map { ($0.name as NSString).lastPathComponent }
                ?? key
            return CandidateGroup(
                key: key, displayName: display, owner: owner,
                candidates: members.sorted { $0.sizeBytes > $1.sizeBytes }
            )
        }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// A denial count above zero means sizes are undercounts. Surfacing this
    /// matters more than the numbers: a silently partial scan reads as
    /// "nothing to clean here".
    public var needsFullDiskAccess: Bool { accessDeniedCount > 0 }
}

public enum ScanEngine {
    public enum Phase: Sendable {
        case loadingRules
        case plugins(names: [String])
        case inventory(source: String, count: Int)
        case inventoryDone(summary: String)
        case enumerating(count: Int)
        case measuring(CandidateScanner.MeasureProgress)
        case classifying
        case done(ScanResult)
    }

    /// Flag any candidate that is a strict ancestor of another. Done by
    /// sorting paths so each candidate only has to be compared against the
    /// ones that could contain it.
    static func markOverlaps(_ candidates: inout [Candidate]) {
        let order = candidates.indices.sorted { candidates[$0].path < candidates[$1].path }
        var stack: [Int] = []
        for idx in order {
            let path = candidates[idx].path
            while let top = stack.last, !path.hasPrefix(candidates[top].path + "/") {
                stack.removeLast()
            }
            if let parent = stack.last {
                candidates[parent].supersededByChildren = true
                candidates[parent].evidence.append(Evidence(.protectedPath,
                    "contains finer-grained candidates; act on those instead",
                    weight: 0))
            }
            stack.append(idx)
        }
        // Superseded parents are reported for context but never actionable.
        for i in candidates.indices where candidates[i].supersededByChildren {
            if candidates[i].tier.isActionable { candidates[i].tier = .unknown }
        }
    }

    public static func run(
        options: ScanOptions = ScanOptions(),
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) throws -> ScanResult {
        let start = Date()

        onPhase?(.loadingRules)
        let rules = try Rules.load(userPath: options.rulesPath)
        let compiled = rules.compiled()

        var host = PluginHost(home: options.home)
        if options.enablePlugins {
            host.discover()
            onPhase?(.plugins(names: host.plugins.map(\.manifest.name)))
        }

        let inventory = AppInventory.collect(
            home: options.home,
            includeLaunchServices: options.includeLaunchServices
        ) { progress in
            onPhase?(.inventory(source: progress.source, count: progress.count))
        }
        onPhase?(.inventoryDone(summary: inventory.summary))

        var enumerated = CandidateScanner.enumerate(roots: options.roots)

        // Plugins contribute candidates *inside* directories the core scan
        // treats as single opaque blobs — stale agent sessions, superseded
        // tool binaries. They are measured by bleach, never self-reported.
        if options.enablePlugins {
            let fromPlugins = host.enumerate(staleDays: rules.staleDays)
            let known = Set(enumerated.map(\.path))
            enumerated += fromPlugins.filter { !known.contains($0.path) }
        }
        onPhase?(.enumerating(count: enumerated.count))

        let (measured, denied) = CandidateScanner.measure(enumerated) { progress in
            onPhase?(.measuring(progress))
        }

        onPhase?(.classifying)

        // Plugin resolutions are gathered before classification so their
        // evidence participates in tiering rather than being bolted on after.
        var annotated = measured
        if options.enablePlugins {
            let resolutions = host.resolve(measured, staleDays: rules.staleDays)
            for i in annotated.indices {
                guard let (hint, evidence, ownerName, ownerBundleID) =
                    resolutions[annotated[i].path] else { continue }
                annotated[i].evidence += evidence
                annotated[i].pluginTierHint = hint
                if annotated[i].owner == nil, ownerName != nil || ownerBundleID != nil {
                    annotated[i].owner = AppRecord(
                        bundleID: ownerBundleID, name: ownerName,
                        sources: [.toolManaged], existsOnDisk: true)
                }
            }
        }
        // Candidates that arrived from `enumerate` already carry their hint in
        // `tier`; move it aside so classification can run normally.
        for i in annotated.indices where annotated[i].rootID.hasPrefix("plugin:") {
            if annotated[i].pluginTierHint == nil, annotated[i].tier != .unknown {
                annotated[i].pluginTierHint = annotated[i].tier
            }
            annotated[i].pluginName = String(annotated[i].rootID.dropFirst("plugin:".count))
        }

        let resolver = Resolver(inventory: inventory, rules: compiled, home: options.home)
        let classifier = Classifier(rules: compiled, inventory: inventory)
        let classified = annotated.map { classifier.classify(resolver.resolve($0)) }
        var finalized = classifier.applyVersionRetention(classified)

        // Apply plugin hints last. This is the invariant that makes
        // third-party plugins safe to run: a plugin can sharpen "unknown"
        // (which means "core reached no verdict") into "orphan", but it can
        // never talk core *out of* a verdict it did reach.
        //
        // The distinction matters because `hardProtected` marks only the five
        // tier-0 rules. Plenty of deliberate verdicts are soft — "owner is
        // installed", "holds user-data-shaped files", "owner ships its own
        // cleanup", "newest of N versions, kept" — and treating those as
        // overridable let a hint promote a live app's state directory
        // straight to CACHE-SAFE.
        //
        // Note `Tier.protectiveRank` deliberately ranks `unknown` as *more*
        // protective than `orphanLikely`, so `mostProtective` alone would
        // also block the sharpening case the plugin API exists for. Hence the
        // explicit split rather than a single collapse.
        for i in finalized.indices {
            guard let hint = finalized[i].pluginTierHint else { continue }
            let core = finalized[i].tier

            let resolved: Tier = core == .unknown && !finalized[i].hardProtected
                ? hint
                : Tier.mostProtective(core, hint)

            if resolved != hint {
                finalized[i].evidence.append(Evidence(.protectedPath,
                    "plugin suggested \(hint.label) but core tiered this \(core.label), which wins",
                    weight: 0))
            }
            finalized[i].tier = resolved
            if resolved.isActionable, finalized[i].sizeBytes < rules.minActionableBytes {
                finalized[i].tier = .unknown
            }
        }

        markOverlaps(&finalized)

        let result = ScanResult(
            candidates: finalized.sorted { $0.sizeBytes > $1.sizeBytes },
            inventory: inventory,
            rules: rules,
            accessDeniedCount: denied,
            elapsed: Date().timeIntervalSince(start),
            loadedPlugins: host.plugins.map(\.manifest.name),
            pluginWarnings: host.warnings
        )
        onPhase?(.done(result))
        return result
    }
}
