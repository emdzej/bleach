import BleachCore

/// One place where a tier's colour is decided, so the CLI table and the TUI
/// can never disagree about what "orange" means.
public enum TierStyle {
    public static func colored(_ tier: Tier) -> String {
        let label = ANSI.pad(tier.label, to: 10)
        switch tier {
        case .protected: return ANSI.grey(label)
        case .cacheSafe: return ANSI.green(label)
        case .orphanLikely: return ANSI.yellow(label)
        case .review: return ANSI.cyan(label)
        case .unknown: return ANSI.dim(label)
        }
    }

    public static func glyph(_ tier: Tier) -> String {
        switch tier {
        case .protected: return "lock"
        case .cacheSafe: return "safe"
        case .orphanLikely: return "orph"
        case .review: return "revw"
        case .unknown: return "  ? "
        }
    }
}
