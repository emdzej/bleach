import Foundation

/// Minimal ANSI styling. Hand-rolled rather than pulled in as a dependency:
/// the surface is small, and colour correctness matters enough to want it
/// explicit (respecting NO_COLOR and non-TTY output).
public enum ANSI {
    public static let isTTY = isatty(STDOUT_FILENO) == 1
    public static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isTTY
    }()

    static func wrap(_ code: String, _ s: String) -> String {
        enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s
    }

    public static func dim(_ s: String) -> String { wrap("2", s) }
    public static func bold(_ s: String) -> String { wrap("1", s) }
    public static func red(_ s: String) -> String { wrap("31", s) }
    public static func green(_ s: String) -> String { wrap("32", s) }
    public static func yellow(_ s: String) -> String { wrap("33", s) }
    public static func blue(_ s: String) -> String { wrap("34", s) }
    public static func magenta(_ s: String) -> String { wrap("35", s) }
    public static func cyan(_ s: String) -> String { wrap("36", s) }
    public static func grey(_ s: String) -> String { wrap("90", s) }
    public static func inverse(_ s: String) -> String { wrap("7", s) }

    // Screen control, used by the TUI.
    public static let clearScreen = "\u{1B}[2J"
    public static let clearLine = "\u{1B}[2K"
    public static let cursorHome = "\u{1B}[H"
    public static let hideCursor = "\u{1B}[?25l"
    public static let showCursor = "\u{1B}[?25h"
    public static let enterAltScreen = "\u{1B}[?1049h"
    public static let exitAltScreen = "\u{1B}[?1049l"

    public static func moveTo(row: Int, col: Int) -> String { "\u{1B}[\(row);\(col)H" }

    /// Truncate to a display width, adding an ellipsis. Keeps the *tail* of
    /// paths, which is the informative end.
    public static func truncateHead(_ s: String, to width: Int) -> String {
        guard s.count > width, width > 1 else { return s }
        return "…" + String(s.suffix(width - 1))
    }

    public static func truncateTail(_ s: String, to width: Int) -> String {
        guard s.count > width, width > 1 else { return s }
        return String(s.prefix(width - 1)) + "…"
    }

    public static func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }
}
