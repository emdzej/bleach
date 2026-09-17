import Foundation

public enum Plist {
    /// Read a plist (binary or XML) into a dictionary. Returns nil for
    /// unreadable files — several `~/Library` plists are SIP- or
    /// entitlement-protected and denial is an expected outcome, not an error.
    public static func read(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any]
    }

    public static func string(_ dict: [String: Any]?, _ key: String) -> String? {
        guard let v = dict?[key] as? String, !v.isEmpty else { return nil }
        return v
    }
}
