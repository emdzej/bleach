import Foundation

/// The merged "what is installed on this machine" view, indexed for the
/// resolver. Sources are collected concurrently because `lsregister -dump`
/// takes several seconds and everything else is nearly free.
public struct AppInventory: Sendable {
    public var records: [AppRecord] = []
    public var launchJobs: [LaunchDaemons.Job] = []
    /// Absolute executable paths of every live process.
    public var runningExecutables: [String] = []

    private var byBundleID: [String: AppRecord] = [:]
    private var byCanonicalName: [String: [AppRecord]] = [:]
    private var byVersionStripped: [String: [AppRecord]] = [:]
    private var byTeamID: [String: [AppRecord]] = [:]
    /// `.app` bundles that live *inside* `~/Library`. Self-updating apps
    /// (Raycast, many Electron apps) keep their real binary under
    /// Application Support — deleting that directory uninstalls the app.
    public private(set) var bundlesInsideLibrary: [String] = []

    public init() {}

    public struct Progress: Sendable {
        public var source: String
        public var count: Int
    }

    public static func collect(
        home: String = NSHomeDirectory(),
        includeLaunchServices: Bool = true,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) -> AppInventory {
        let lock = NSLock()
        var all: [AppRecord] = []
        var jobs: [LaunchDaemons.Job] = []
        var running: [String] = []

        func absorb(_ name: String, _ recs: [AppRecord]) {
            lock.lock()
            all.append(contentsOf: recs)
            lock.unlock()
            onProgress?(Progress(source: name, count: recs.count))
        }

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)

        group.enter()
        queue.async {
            absorb("spotlight", AppBundles.viaSpotlight())
            group.leave()
        }
        group.enter()
        queue.async {
            absorb("filesystem", AppBundles.viaFilesystem(home: home))
            group.leave()
        }
        group.enter()
        queue.async {
            absorb("receipts", Receipts.load())
            group.leave()
        }
        group.enter()
        queue.async {
            absorb("homebrew", Homebrew.load())
            group.leave()
        }
        group.enter()
        queue.async {
            let (recs, js) = LaunchDaemons.load(home: home)
            lock.lock(); jobs = js; lock.unlock()
            absorb("launchd", recs)
            group.leave()
        }
        group.enter()
        queue.async {
            let (recs, paths) = RunningProcesses.load()
            lock.lock(); running = paths; lock.unlock()
            absorb("processes", recs)
            group.leave()
        }
        if includeLaunchServices {
            group.enter()
            queue.async {
                absorb("launchservices", LaunchServicesDump.load())
                group.leave()
            }
        }
        group.wait()

        var inv = AppInventory()
        inv.launchJobs = jobs
        inv.runningExecutables = running
        inv.index(all, home: home)
        return inv
    }

    /// Merge duplicate records (same bundle ID) and build lookup tables.
    mutating func index(_ incoming: [AppRecord], home: String) {
        var merged: [String: AppRecord] = [:]
        var anonymous: [AppRecord] = []

        for rec in incoming {
            guard let id = rec.bundleID?.lowercased() else {
                anonymous.append(rec)
                continue
            }
            if var existing = merged[id] {
                existing.merge(rec)
                merged[id] = existing
            } else {
                merged[id] = rec
            }
        }

        records = Array(merged.values) + anonymous
        byBundleID = merged

        let libraryPrefix = "\(home)/Library/"
        for rec in records {
            if let name = rec.name {
                byCanonicalName[Normalizer.canonical(name), default: []].append(rec)
                byVersionStripped[Normalizer.versionStripped(name), default: []].append(rec)
            }
            if let id = rec.bundleID {
                // Also index bundle IDs by their canonical tail so a
                // human-named directory can match a bundle-only record.
                for key in Normalizer.keys(forBundleID: id) {
                    byCanonicalName[Normalizer.canonical(key), default: []].append(rec)
                }
            }
            if let team = rec.teamID {
                byTeamID[team, default: []].append(rec)
            }
            if let path = rec.path, path.hasPrefix(libraryPrefix), path.hasSuffix(".app") {
                bundlesInsideLibrary.append(path)
            }
        }
    }

    // MARK: - Lookups

    public func record(bundleID: String) -> AppRecord? {
        byBundleID[bundleID.lowercased()]
    }

    public func records(canonicalName: String) -> [AppRecord] {
        byCanonicalName[canonicalName] ?? []
    }

    public func records(versionStripped: String) -> [AppRecord] {
        byVersionStripped[versionStripped] ?? []
    }

    public func records(teamID: String) -> [AppRecord] {
        byTeamID[teamID] ?? []
    }

    /// Is a live process running out of this directory subtree?
    public func hasRunningProcess(under path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return runningExecutables.contains { $0 == path || $0.hasPrefix(prefix) }
    }

    /// Does an installed app bundle live inside this directory subtree?
    public func containsAppBundle(under path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return bundlesInsideLibrary.contains { $0.hasPrefix(prefix) }
    }

    public var summary: String {
        let withID = records.filter { $0.bundleID != nil }.count
        return "\(records.count) owners (\(withID) with bundle IDs), "
            + "\(launchJobs.count) launchd jobs, \(runningExecutables.count) live processes"
    }
}
