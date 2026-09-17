import Foundation

/// How a permitted path is disposed of.
public enum RemovalMode: String, Codable, Sendable, CaseIterable {
    /// Rename into bleach's own quarantine. Fully reversible with
    /// `bleach restore`, and O(1) on APFS. The default.
    case quarantine
    /// Hand to Finder's Trash. Reversible outside bleach, and survives
    /// `bleach quarantine --purge`, but counts against your disk until
    /// emptied.
    case trash
    /// Unlink immediately. Irreversible.
    case delete

    public var label: String {
        switch self {
        case .quarantine: return "quarantine"
        case .trash: return "Trash"
        case .delete: return "delete in place"
        }
    }

    public var isReversible: Bool { self != .delete }

    public var summary: String {
        switch self {
        case .quarantine:
            return "moved to ~/.local/state/bleach/quarantine — undo with `bleach restore`"
        case .trash:
            return "moved to Finder's Trash — undo from Finder, still using disk until emptied"
        case .delete:
            return "unlinked immediately — NO undo"
        }
    }
}

/// Executes a validated plan under a chosen mode.
///
/// All three modes share one code path up to the disposal call, so the
/// validation, journalling, and skip reporting cannot drift between them.
/// Every mode is journalled — including `delete`, so there is always a record
/// of what was removed even when the bytes are gone.
public struct Remover: Sendable {
    let home: String
    let quarantine: Quarantine

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        self.quarantine = Quarantine(home: home)
    }

    public struct Report: Sendable {
        public var mode: RemovalMode
        public var batchID: String
        public var removed: [Quarantine.Item]
        public var skipped: [Quarantine.Skip]
        public var bytes: Int64 { removed.reduce(0) { $0 + $1.sizeBytes } }
        /// Only populated for `.quarantine`; the other modes have nothing to
        /// restore from.
        public var restorable: Bool
    }

    public func run(
        _ plan: RemovalPlan,
        mode: RemovalMode,
        batchID: String,
        validate: (RemovalPlan.Entry) -> String?,
        onProgress: ((RemovalPlan.Entry) -> Void)? = nil
    ) throws -> Report {
        if mode == .quarantine {
            let (batch, skipped) = try quarantine.apply(
                plan, batchID: batchID, validate: validate, onProgress: onProgress)
            return Report(mode: mode, batchID: batchID, removed: batch.items,
                          skipped: skipped, restorable: true)
        }

        let fm = FileManager.default
        var removed: [Quarantine.Item] = []
        var skipped: [Quarantine.Skip] = []

        for entry in plan.entries {
            // Re-validated immediately before disposal, exactly as in the
            // quarantine path. Skipping this for the destructive modes would
            // invert the safety ordering.
            if let reason = validate(entry) {
                skipped.append(Quarantine.Skip(path: entry.path, reason: reason))
                continue
            }
            do {
                switch mode {
                case .trash:
                    var resulting: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: entry.path),
                                     resultingItemURL: &resulting)
                case .delete:
                    try fm.removeItem(atPath: entry.path)
                case .quarantine:
                    break // handled above
                }
            } catch {
                skipped.append(Quarantine.Skip(
                    path: entry.path,
                    reason: "\(mode.rawValue) failed: \(error.localizedDescription)"))
                continue
            }
            removed.append(Quarantine.Item(
                originalPath: entry.path,
                storedName: mode == .trash ? "<Trash>" : "<deleted>",
                sizeBytes: entry.sizeBytes,
                tier: entry.tier,
                reasons: entry.reasons
            ))
            onProgress?(entry)
        }

        // Journal even destructive modes: if someone later asks "what
        // happened to that directory", the answer should exist.
        let batch = Quarantine.Batch(id: batchID, createdAt: Date(), items: removed)
        try? quarantine.appendJournal(batch)

        return Report(mode: mode, batchID: batchID, removed: removed,
                      skipped: skipped, restorable: false)
    }
}
