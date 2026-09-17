import Foundation

public enum CandidateScanner {
    /// Enumerate candidate paths without touching their contents. Cheap, so
    /// the TUI can show the full work-list before any measuring starts.
    public static func enumerate(roots: [ScanRoot]) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            for entry in entries.sorted() {
                if entry == ".DS_Store" || entry == ".localized" { continue }
                if root.filter == .dotDirectoriesOnly && !entry.hasPrefix(".") { continue }
                if root.excludeChildren.contains(entry) { continue }
                let path = "\(root.path)/\(entry)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                // Dotfiles (.zshrc, .netrc) are configuration, not bulk.
                if root.filter == .dotDirectoriesOnly && !isDir.boolValue { continue }

                // Umbrella vendor directories become one candidate per tenant
                // so a stale per-version subdirectory is visible on its own.
                if isDir.boolValue, root.multiTenantChildren.contains(entry),
                   let children = try? fm.contentsOfDirectory(atPath: path), !children.isEmpty {
                    for child in children.sorted() where child != ".DS_Store" {
                        let childPath = "\(path)/\(child)"
                        var childIsDir: ObjCBool = false
                        guard fm.fileExists(atPath: childPath, isDirectory: &childIsDir) else { continue }
                        out.append(Candidate(
                            path: childPath,
                            name: "\(entry)/\(child)",
                            rootID: root.id,
                            kind: root.kind,
                            isDirectory: childIsDir.boolValue,
                            requiresRoot: root.requiresRoot
                        ))
                    }
                    continue
                }

                out.append(Candidate(
                    path: path,
                    name: entry,
                    rootID: root.id,
                    kind: root.kind,
                    isDirectory: isDir.boolValue,
                    requiresRoot: root.requiresRoot
                ))
            }
        }
        return out
    }

    public struct MeasureProgress: Sendable {
        public var completed: Int
        public var total: Int
        public var currentPath: String
        public var bytesSoFar: Int64
    }

    /// Fill in size / count / mtime for each candidate. Disk-bound, so we run
    /// a bounded number of walks concurrently; more than this thrashes.
    public static func measure(
        _ candidates: [Candidate],
        concurrency: Int = max(4, ProcessInfo.processInfo.activeProcessorCount),
        onProgress: (@Sendable (MeasureProgress) -> Void)? = nil
    ) -> (candidates: [Candidate], accessDenied: Int) {
        var results = candidates
        let lock = NSLock()
        var completed = 0
        var denied = 0
        var bytes: Int64 = 0

        let queue = DispatchQueue.global(qos: .userInitiated)
        let semaphore = DispatchSemaphore(value: concurrency)
        let group = DispatchGroup()

        for index in candidates.indices {
            semaphore.wait()
            group.enter()
            queue.async {
                defer { semaphore.signal(); group.leave() }
                let path = candidates[index].path
                let stats = DirectoryWalker.stats(of: path)

                lock.lock()
                results[index].sizeBytes = stats.sizeBytes
                results[index].fileCount = stats.fileCount
                results[index].newestMTime = stats.newestMTime
                if stats.accessDenied { denied += 1 }
                if !stats.userDataHits.isEmpty {
                    results[index].evidence.append(Evidence(
                        .userDataMarker,
                        "contains \(stats.userDataHits.prefix(3).joined(separator: ", "))",
                        weight: 3.0
                    ))
                }
                if stats.containsAppBundle {
                    // Soft signal only. Plenty of caches legitimately contain
                    // nested .app bundles (JetBrains ships one inside its
                    // plugin cache), so this must not hard-protect on its own
                    // — the inventory-verified check in Resolver does that.
                    results[index].evidence.append(Evidence(
                        .protectedPath,
                        "contains an unregistered .app bundle",
                        weight: 2.0
                    ))
                }
                completed += 1
                bytes += stats.sizeBytes
                let snapshot = MeasureProgress(
                    completed: completed, total: candidates.count,
                    currentPath: path, bytesSoFar: bytes
                )
                lock.unlock()
                onProgress?(snapshot)
            }
        }
        group.wait()
        return (results, denied)
    }
}
