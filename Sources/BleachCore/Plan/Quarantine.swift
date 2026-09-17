import Foundation

/// Reversible removal.
///
/// Nothing is unlinked. Paths are *renamed* into a quarantine directory on the
/// same volume, which on APFS is an O(1) metadata operation — quarantining
/// 10 GB is instantaneous — and is trivially reversible because the bytes
/// never moved.
public struct Quarantine: Sendable {
    public let root: String
    let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.root = "\(home)/.local/state/bleach/quarantine"
    }

    public var journalPath: String { "\(home)/.local/state/bleach/journal.jsonl" }

    // MARK: - Batch records

    public struct Item: Codable, Sendable {
        public var originalPath: String
        public var storedName: String
        public var sizeBytes: Int64
        public var tier: Tier
        public var reasons: [String]
    }

    public struct Batch: Codable, Sendable {
        public var id: String
        public var createdAt: Date
        public var items: [Item]
        public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }

        public func directory(in root: String) -> String { "\(root)/\(id)" }
    }

    public struct Skip: Sendable {
        public var path: String
        public var reason: String
    }

    // MARK: - Apply

    /// Move each path into a new batch directory.
    ///
    /// `validate` is called immediately before each move and is the last line
    /// of defence: a plan may have been written hours ago, hand-edited, or
    /// copied from another machine, so entries are re-checked against live
    /// state rather than trusted.
    public func apply(
        _ plan: RemovalPlan,
        batchID: String,
        validate: (RemovalPlan.Entry) -> String?,
        onProgress: ((RemovalPlan.Entry) -> Void)? = nil
    ) throws -> (batch: Batch, skipped: [Skip]) {
        let fm = FileManager.default
        let batchDir = "\(root)/\(batchID)"
        try fm.createDirectory(atPath: batchDir, withIntermediateDirectories: true)

        var items: [Item] = []
        var skipped: [Skip] = []
        var usedNames = Set<String>()

        for entry in plan.entries {
            if let reason = validate(entry) {
                skipped.append(Skip(path: entry.path, reason: reason))
                continue
            }

            // Flatten the original path into a unique, readable storage name.
            var stored = storedName(for: entry.path)
            var suffix = 2
            while !usedNames.insert(stored).inserted {
                stored = storedName(for: entry.path) + "~\(suffix)"
                suffix += 1
            }

            let destination = "\(batchDir)/\(stored)"
            do {
                try fm.moveItem(atPath: entry.path, toPath: destination)
            } catch {
                // A cross-volume path, or one that vanished between validation
                // and the move. Either way: report, don't abort the batch.
                skipped.append(Skip(path: entry.path, reason: "move failed: \(error.localizedDescription)"))
                continue
            }
            items.append(Item(
                originalPath: entry.path,
                storedName: stored,
                sizeBytes: entry.sizeBytes,
                tier: entry.tier,
                reasons: entry.reasons
            ))
            onProgress?(entry)
        }

        let batch = Batch(id: batchID, createdAt: Date(), items: items)
        try writeManifest(batch)
        try appendJournal(batch)
        return (batch, skipped)
    }

    /// `~/Library/Caches/Foo` becomes `Library-Caches-Foo`, which keeps the
    /// quarantine browsable by hand.
    func storedName(for path: String) -> String {
        var relative = path
        if relative.hasPrefix(home + "/") { relative = String(relative.dropFirst(home.count + 1)) }
        return relative
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
    }

    // MARK: - Persistence

    func writeManifest(_ batch: Batch) throws {
        let data = try RemovalPlan.encoder().encode(batch)
        try data.write(to: URL(fileURLWithPath: "\(root)/\(batch.id)/manifest.json"), options: .atomic)
    }

    /// Append-only log across all batches, so there is a single place to read
    /// the full history of what this tool has ever moved.
    func appendJournal(_ batch: Batch) throws {
        let fm = FileManager.default
        let dir = (journalPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try encoder.encode(batch)
        line.append(0x0A)
        if let handle = FileHandle(forWritingAtPath: journalPath) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: URL(fileURLWithPath: journalPath), options: .atomic)
        }
    }

    // MARK: - Inspect

    public func batches() -> [Batch] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted().compactMap { id in
            guard let data = fm.contents(atPath: "\(root)/\(id)/manifest.json") else { return nil }
            return try? RemovalPlan.decoder().decode(Batch.self, from: data)
        }
    }

    public func batch(id: String) -> Batch? {
        batches().first { $0.id == id }
    }

    /// Bytes actually on disk in the quarantine right now.
    public func sizeOnDisk() -> Int64 {
        DirectoryWalker.stats(of: root, collectUserData: false).sizeBytes
    }

    // MARK: - Restore

    public func restore(batchID: String, only: Set<String>? = nil) throws -> (restored: [String], skipped: [Skip]) {
        guard let batch = batch(id: batchID) else { throw BleachError.notFound("batch \(batchID)") }
        let fm = FileManager.default
        var restored: [String] = []
        var skipped: [Skip] = []

        for item in batch.items {
            if let only, !only.contains(item.originalPath) { continue }
            let stored = "\(root)/\(batchID)/\(item.storedName)"
            guard fm.fileExists(atPath: stored) else {
                skipped.append(Skip(path: item.originalPath, reason: "no longer in quarantine"))
                continue
            }
            // Never clobber: if the app recreated its directory after the
            // removal, the user needs to decide which copy wins.
            if fm.fileExists(atPath: item.originalPath) {
                skipped.append(Skip(path: item.originalPath, reason: "destination already exists"))
                continue
            }
            let parent = (item.originalPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            do {
                try fm.moveItem(atPath: stored, toPath: item.originalPath)
                restored.append(item.originalPath)
            } catch {
                skipped.append(Skip(path: item.originalPath, reason: error.localizedDescription))
            }
        }
        return (restored, skipped)
    }

    // MARK: - Purge

    /// Permanently delete batches older than `days`. This is the only code
    /// path in bleach that destroys data, and it only ever touches paths
    /// inside its own quarantine directory.
    /// `days == nil` purges everything.
    public func purge(olderThanDays days: Int?) throws -> [Batch] {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86400) }
        var purged: [Batch] = []
        for batch in batches() where cutoff.map({ batch.createdAt < $0 }) ?? true {
            let dir = "\(root)/\(batch.id)"
            guard dir.hasPrefix(root + "/") else { continue }  // belt and braces
            try FileManager.default.removeItem(atPath: dir)
            purged.append(batch)
        }
        return purged
    }
}
