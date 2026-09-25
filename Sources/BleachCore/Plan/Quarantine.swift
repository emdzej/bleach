import Foundation

/// Reversible removal.
///
/// Nothing is unlinked. Paths are *renamed* into a quarantine directory on the
/// same volume, which on APFS is an O(1) metadata operation — quarantining
/// 10 GB is instantaneous — and is trivially reversible because the bytes
/// never moved.
///
/// Everything read back out of the quarantine is treated as untrusted input.
/// A `manifest.json` is a file on disk: it can be hand-edited, corrupted, or
/// restored from a backup of another machine. So no path is ever built from a
/// manifest field without validating it first — the directory listing is
/// authoritative, not the JSON.
public struct Quarantine: Sendable {
    public let root: String
    let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.root = "\(home)/.local/state/bleach/quarantine"
    }

    public var journalPath: String { "\(home)/.local/state/bleach/journal.jsonl" }

    /// The manifest is stored alongside the payloads, so its name is reserved.
    static let manifestName = "manifest.json"

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

    // MARK: - Identifier validation

    /// A batch ID becomes a directory name, so it has to be a single, boring
    /// path component. Rejecting rather than sanitising: a batch ID that needs
    /// sanitising did not come from `apply`, and guessing what it meant is how
    /// a `..` ends up in a path passed to `removeItem`.
    public static func isValidBatchID(_ id: String) -> Bool {
        guard SafePath.isSingleComponent(id), id != manifestName else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// A stored name is resolved against a batch directory, so it must not be
    /// able to point outside it — nor at the manifest itself.
    static func isValidStoredName(_ name: String) -> Bool {
        SafePath.isSingleComponent(name) && name != manifestName
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
    ) throws -> (batch: Batch, skipped: [Skip], journalError: String?) {
        guard Self.isValidBatchID(batchID) else {
            throw BleachError.invalidBatchID(batchID)
        }
        let fm = FileManager.default
        let batchDir = "\(root)/\(batchID)"
        try fm.createDirectory(atPath: batchDir, withIntermediateDirectories: true)

        // A skeleton manifest up front, so a batch is discoverable by
        // `batches()` even if the process dies mid-move. Without it, a failure
        // after the first rename leaves the bytes safe but unreachable through
        // `restore`.
        try writeManifest(Batch(id: batchID, createdAt: Date(), items: []))

        var items: [Item] = []
        var skipped: [Skip] = []
        // Seeded with the manifest name so a candidate whose flattened name
        // collides with it gets suffixed instead of being overwritten by the
        // manifest write below. `~/manifest.json` flattens to exactly that.
        var usedNames: Set<String> = [Self.manifestName]

        for entry in plan.entries {
            if let reason = validate(entry) {
                skipped.append(Skip(path: entry.path, reason: reason))
                continue
            }

            // Flatten the original path into a unique, readable storage name.
            let base = storedName(for: entry.path)
            var stored = base
            var suffix = 2
            while !usedNames.insert(stored).inserted {
                stored = base + "~\(suffix)"
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
        // Journal first now: the paths have already moved, so the record of
        // where they went is more urgent than the manifest rewrite, and a
        // manifest failure must not cost us both.
        let journalError = appendJournal(batch)
        try writeManifest(batch)
        return (batch, skipped, journalError)
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
        guard Self.isValidBatchID(batch.id) else { throw BleachError.invalidBatchID(batch.id) }
        let data = try RemovalPlan.encoder().encode(batch)
        try data.write(to: URL(fileURLWithPath: "\(root)/\(batch.id)/\(Self.manifestName)"),
                       options: .atomic)
    }

    /// Append-only log across all batches, so there is a single place to read
    /// the full history of what this tool has ever moved.
    ///
    /// Returns a description of the failure rather than throwing: by the time
    /// this is called the files have already moved, so a journal problem is
    /// something to report alongside a successful batch, not a reason to fail
    /// one. Opened `O_APPEND` so concurrent runs cannot interleave a line.
    @discardableResult
    public func appendJournal(_ batch: Batch) -> String? {
        let dir = (journalPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return "could not create \(dir): \(error.localizedDescription)"
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line: Data
        do {
            line = try encoder.encode(batch)
        } catch {
            return "could not encode the batch record: \(error.localizedDescription)"
        }
        line.append(0x0A)

        let fd = open(journalPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            return "could not open \(journalPath): \(String(cString: strerror(errno)))"
        }
        defer { close(fd) }
        return line.withUnsafeBytes { buffer -> String? in
            var written = 0
            while written < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return "could not write \(journalPath): \(String(cString: strerror(errno)))"
                }
                written += n
            }
            return nil
        }
    }

    // MARK: - Inspect

    /// Batches are discovered by listing directories, and each batch's `id` is
    /// taken from its directory name. The manifest's own `id` field is data,
    /// and every path we later build — restore source, purge target — is built
    /// from the validated directory name instead.
    public func batches() -> [Batch] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries.sorted().compactMap { dirName in
            guard Self.isValidBatchID(dirName) else { return nil }
            guard let data = fm.contents(atPath: "\(root)/\(dirName)/\(Self.manifestName)"),
                  var batch = try? RemovalPlan.decoder().decode(Batch.self, from: data)
            else { return nil }
            batch.id = dirName
            return batch
        }
    }

    public func batch(id: String) -> Batch? {
        guard Self.isValidBatchID(id) else { return nil }
        return batches().first { $0.id == id }
    }

    /// Bytes actually on disk in the quarantine right now.
    public func sizeOnDisk() -> Int64 {
        DirectoryWalker.stats(of: root, collectUserData: false).sizeBytes
    }

    // MARK: - Restore

    /// Move quarantined paths back where they came from.
    ///
    /// Both halves of every item are validated: `storedName` must stay inside
    /// the batch directory, and `originalPath` gets the same shape checks
    /// `apply` uses, because a manifest is no more trustworthy than a plan.
    public func restore(batchID: String, only: Set<String>? = nil) throws -> (restored: [String], skipped: [Skip]) {
        guard let batch = batch(id: batchID) else { throw BleachError.notFound("batch \(batchID)") }
        let fm = FileManager.default
        var restored: [String] = []
        var skipped: [Skip] = []

        for item in batch.items {
            if let only, !only.contains(item.originalPath) { continue }

            guard Self.isValidStoredName(item.storedName) else {
                skipped.append(Skip(path: item.originalPath,
                                    reason: "manifest has an unsafe stored name \"\(item.storedName)\""))
                continue
            }
            if let reason = SafePath.shapeRefusal(item.originalPath, home: home) {
                skipped.append(Skip(path: item.originalPath,
                                    reason: "refusing to restore there: \(reason)"))
                continue
            }

            let stored = "\(root)/\(batch.id)/\(item.storedName)"
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
    /// inside its own quarantine directory: `id` comes from a directory name
    /// that passed `isValidBatchID`, so it cannot contain a separator or a
    /// `..` to climb out with.
    /// `days == nil` purges everything.
    public func purge(olderThanDays days: Int?) throws -> [Batch] {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86400) }
        var purged: [Batch] = []
        for batch in batches() where cutoff.map({ batch.createdAt < $0 }) ?? true {
            guard Self.isValidBatchID(batch.id) else { continue }
            let dir = "\(root)/\(batch.id)"
            guard dir.hasPrefix(root + "/") else { continue }  // belt and braces
            try FileManager.default.removeItem(atPath: dir)
            purged.append(batch)
        }
        return purged
    }
}
