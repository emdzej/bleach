import Foundation

/// Path-shape checks shared by every code path that is about to move, write,
/// or unlink something.
///
/// These live in one place on purpose. The original asymmetry — `apply`
/// validating thoroughly while `restore` validated nothing — was possible
/// because each side carried its own ad-hoc checks. Anything that touches the
/// filesystem on a path derived from a file on disk (a plan, a manifest, a
/// plugin's reply) goes through here.
public enum SafePath {
    /// A single, boring path component: no separators, no `.`/`..`, non-empty.
    /// Used for anything that will be interpolated into a path we build.
    public static func isSingleComponent(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\0")
    }

    /// Symlinks resolved on *both* sides, so `/var` vs `/private/var` (and any
    /// other legitimately symlinked ancestor of a home directory) compares
    /// equal instead of reading as an escape.
    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Returns a refusal reason, or nil if the path is shaped safely and stays
    /// inside `home`.
    ///
    /// The lexical checks come first so their messages stay specific, then the
    /// resolved check catches what lexical analysis cannot: a symlinked
    /// *parent* directory. `~/Library/Caches` pointed at another volume is a
    /// common disk-space move, and it is the highest-traffic scan root there
    /// is, so this is a routine case rather than an exotic one.
    public static func shapeRefusal(_ path: String, home: String) -> String? {
        guard path.hasPrefix("/") else { return "not an absolute path" }
        guard !path.contains("\0") else { return "path contains a null byte" }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { return "path is not standardised (possible traversal)" }
        guard path != home else { return "is your home directory" }
        guard path.hasPrefix(home + "/") else { return "outside your home directory" }

        let resolvedHome = resolve(home)
        let resolved = resolve(path)
        guard resolved != resolvedHome else { return "resolves to your home directory" }
        guard resolved.hasPrefix(resolvedHome + "/") else {
            return "resolves outside your home directory (symlinked parent directory)"
        }
        return nil
    }
}
