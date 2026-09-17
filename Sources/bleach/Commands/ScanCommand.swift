import ArgumentParser
import BleachCore
import BleachTUI
import Foundation

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Measure and tier ~/Library. Read-only."
    )

    @OptionGroup var flags: ScanFlags

    @Option(name: .long, help: "Only show one tier: protected, cache-safe, orphan, review, unknown.")
    var tier: String?

    @Option(name: .long, help: "Rows to show (default 40, 0 for all).")
    var limit: Int = 40

    @Flag(name: .long, help: "Group rows by owner instead of listing paths.")
    var byOwner = false

    @Flag(name: .long, help: "Emit JSON instead of a table.")
    var json = false

    @Flag(name: .long, help: "Show the evidence trail for every row.")
    var explain = false

    @Flag(name: .long, help: "Suppress scan progress on stderr.")
    var quiet = false

    func run() throws {
        let showProgress = !quiet && !json && ANSI.isTTY
        let result = try ScanEngine.run(options: flags.options()) { phase in
            guard showProgress else { return }
            Progress.render(phase)
        }
        if showProgress { Progress.finish() }

        if json {
            try JSONOutput.emit(result, minSize: flags.minSizeBytes())
            return
        }
        Report.render(
            result,
            tierFilter: Tier.parse(tier),
            minSize: flags.minSizeBytes(),
            limit: limit,
            byOwner: byOwner,
            explain: explain
        )
    }
}

extension Tier {
    /// Lenient parsing so `--tier orphan` works as well as `orphan-likely`.
    static func parse(_ s: String?) -> Tier? {
        guard let s = s?.lowercased().replacingOccurrences(of: "_", with: "-") else { return nil }
        switch s {
        case "protected", "lock": return .protected
        case "cache-safe", "cache", "safe": return .cacheSafe
        case "orphan", "orphan-likely", "orphaned": return .orphanLikely
        case "review": return .review
        case "unknown": return .unknown
        default: return nil
        }
    }
}

/// Scan progress goes to stderr so `bleach scan | less` stays clean.
enum Progress {
    private static var lastPaint = Date.distantPast

    static func render(_ phase: ScanEngine.Phase) {
        // The measure callback fires thousands of times; repainting on each
        // one costs more than the walk it is reporting on.
        if case .measuring = phase {
            guard Date().timeIntervalSince(lastPaint) > 0.08 else { return }
        }
        lastPaint = Date()
        let text: String
        switch phase {
        case .loadingRules:
            text = "loading rules…"
        case .plugins(let names):
            text = names.isEmpty ? "no plugins" : "plugins: \(names.joined(separator: ", "))"
        case .inventory(let source, let count):
            text = "inventory: \(source) (\(count))"
        case .inventoryDone(let summary):
            text = "inventory: \(summary)"
        case .enumerating(let count):
            text = "found \(count) candidate paths"
        case .measuring(let p):
            let pct = p.total == 0 ? 0 : p.completed * 100 / p.total
            text = "measuring \(p.completed)/\(p.total) (\(pct)%) "
                + "\(ByteFormat.short(p.bytesSoFar)) — "
                + ANSI.truncateHead((p.currentPath as NSString).lastPathComponent, to: 28)
        case .classifying:
            text = "resolving owners…"
        case .done:
            return
        }
        let line = "  " + text
        FileHandle.standardError.write(Data(("\r" + ANSI.clearLine + line).utf8))
    }

    static func finish() {
        FileHandle.standardError.write(Data(("\r" + ANSI.clearLine).utf8))
    }
}
