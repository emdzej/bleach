import Foundation

/// One pass over a directory collecting everything the classifier needs:
/// allocated size, file count, and the newest mtime found *inside*.
public struct DirectoryStats: Sendable {
    public var sizeBytes: Int64 = 0
    public var fileCount: Int = 0
    public var newestMTime: Date?
    /// Set when the walk hit a permission denial, which on macOS usually means
    /// Full Disk Access has not been granted. Sizes are then undercounts and
    /// must not be presented as authoritative.
    public var accessDenied = false
    /// Relative paths of files matching user-data heuristics.
    public var userDataHits: [String] = []
    public var containsAppBundle = false
}

public enum DirectoryWalker {
    /// Filenames and extensions that suggest irreplaceable user content
    /// rather than regenerable state.
    static let userDataExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "realm", "pages", "numbers", "key",
        "docx", "xlsx", "pptx", "pdf", "psd", "sketch", "blend", "gcode",
        "3mf", "stl", "kdbx", "pem", "p12", "key", "ovpn", "mobileprovision",
    ]
    static let userDataNames: Set<String> = [
        "license.dat", "licence.dat", "license.key", "credentials",
        "token.json", "secrets.json", "keychain", "id_rsa", "id_ed25519",
        "cookies.sqlite",
    ]

    /// Filename fragments that mark a database as regenerable. Without this,
    /// every Chromium-based app trips the user-data heuristic on files like
    /// `icon-cache-v1.db` and `first_party_sets.db`, which pushes genuinely
    /// clearable caches into the review pile.
    static let regenerableFragments = [
        "cache", "index", "manifest", "tmp", "temp", "thumbnail",
        "first_party_sets", "quota", "shader",
    ]

    static func looksLikeUserData(_ filename: String, ext: String) -> Bool {
        let lower = filename.lowercased()
        if userDataNames.contains(lower) { return true }
        guard userDataExtensions.contains(ext) else { return false }
        // A bare `LICENSE` text file is legal boilerplate, not a licence key.
        if lower == "license" || lower == "licence" || lower == "license.txt" { return false }
        return !regenerableFragments.contains { lower.contains($0) }
    }

    /// Walk `path` without following symlinks. Hardlinked files are counted
    /// once per walk so totals line up with `du`.
    public static func stats(of path: String, collectUserData: Bool = true) -> DirectoryStats {
        var out = DirectoryStats()
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            .contentModificationDateKey, .linkCountKey,
        ]

        // Non-directories (preference plists) need no enumeration.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return out }
        if !isDir.boolValue {
            if let v = try? url.resourceValues(forKeys: Set(keys)) {
                out.sizeBytes = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                out.fileCount = 1
                out.newestMTime = v.contentModificationDate
            }
            return out
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [], // hidden files count too — dotfiles hold plenty of state
            errorHandler: { _, error in
                if (error as NSError).code == NSFileReadNoPermissionError { out.accessDenied = true }
                return true // keep going; a partial total beats no total
            }
        ) else {
            out.accessDenied = true
            return out
        }

        // Only hardlinked files need inode bookkeeping, which keeps the
        // common case allocation-free.
        var seenInodes = Set<UInt64>()
        while let item = enumerator.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }

            // Do NOT call skipDescendants() here: the enumerator already
            // refuses to traverse symlinks, and calling it on a non-directory
            // entry skips the remainder of the *current level*. That silently
            // undercounted Homebrew's cache by 11 GB, because its 600
            // symlinks precede the real `downloads/` directory.
            if v.isSymbolicLink == true { continue }
            if item.pathExtension == "app", v.isDirectory == true {
                out.containsAppBundle = true
            }
            guard v.isRegularFile == true else { continue }

            if (v.linkCount ?? 1) > 1 {
                var st = stat()
                if lstat(item.path, &st) == 0 {
                    if !seenInodes.insert(UInt64(st.st_ino)).inserted { continue }
                }
            }

            out.fileCount += 1
            out.sizeBytes += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if let m = v.contentModificationDate {
                if out.newestMTime == nil || m > out.newestMTime! { out.newestMTime = m }
            }

            if collectUserData, out.userDataHits.count < 8 {
                if looksLikeUserData(item.lastPathComponent,
                                     ext: item.pathExtension.lowercased()) {
                    out.userDataHits.append(item.lastPathComponent)
                }
            }
        }
        return out
    }
}
