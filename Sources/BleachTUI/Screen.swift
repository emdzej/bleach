import Foundation

/// A full-frame line buffer.
///
/// Rendering a whole frame and writing it in one syscall avoids the flicker
/// and partial-repaint artefacts you get from incremental cursor moves, and
/// it makes layout code straightforward: build strings, hand them over.
public struct Screen {
    public private(set) var lines: [String] = []
    public let rows: Int
    public let cols: Int

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }

    public mutating func put(_ line: String) {
        guard lines.count < rows else { return }
        lines.append(line)
    }

    public mutating func blank() { put("") }

    public mutating func fill(upTo row: Int) {
        while lines.count < row { lines.append("") }
    }

    /// One escape sequence, one write. Each line is cleared to end-of-line so
    /// stale content from a longer previous frame cannot linger.
    public func flush(to write: (String) -> Void) {
        var out = ANSI.cursorHome
        for (i, line) in lines.enumerated() {
            out += ANSI.moveTo(row: i + 1, col: 1) + ANSI.clearLine + line
        }
        for i in lines.count..<rows {
            out += ANSI.moveTo(row: i + 1, col: 1) + ANSI.clearLine
        }
        write(out)
    }

    /// Visible width, ignoring ANSI escape sequences. Needed because padding
    /// a coloured string by `count` over-counts by the escape bytes.
    public static func visibleWidth(_ s: String) -> Int {
        var width = 0
        var inEscape = false
        for ch in s {
            if ch == "\u{1B}" { inEscape = true; continue }
            if inEscape {
                if ch == "m" { inEscape = false }
                continue
            }
            width += 1
        }
        return width
    }

    public static func padVisible(_ s: String, to width: Int) -> String {
        let w = visibleWidth(s)
        return w >= width ? s : s + String(repeating: " ", count: width - w)
    }
}
