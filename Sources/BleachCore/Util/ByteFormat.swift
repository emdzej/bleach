import Foundation

public enum ByteFormat {
    /// Fixed-width binary units so columns line up in the TUI without a
    /// layout pass. `ByteCountFormatter` varies width and locale, which
    /// makes table alignment fragile.
    public static func short(_ bytes: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < units.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return String(format: "%4.0f%@", value, units[idx]) }
        return String(format: value >= 99.5 ? "%4.0f%@" : "%4.1f%@", value, units[idx])
    }

    public static func age(_ date: Date?) -> String {
        guard let date else { return "  —" }
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days < 1 { return "today" }
        if days < 100 { return "\(days)d" }
        let months = days / 30
        if months < 24 { return "\(months)mo" }
        return "\(days / 365)y"
    }
}
