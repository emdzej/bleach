import ArgumentParser
import BleachCore

@main
struct Bleach: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bleach",
        abstract: "Find and safely reclaim orphaned app state on macOS.",
        discussion: """
        bleach measures ~/Library, attributes each directory to an installed \
        owner using several independent inventory sources, and tiers the \
        result by how safe removal is.

        Nothing is ever deleted outright: `apply` moves state into a \
        quarantine you can restore from. Scanning is always read-only.
        """,
        version: "0.1.0",
        subcommands: [Scan.self, TUI.self, Plan.self, Apply.self,
                      Restore.self, QuarantineCommand.self, RulesCommand.self],
        defaultSubcommand: Scan.self
    )
}

/// Flags shared by every command that scans.
struct ScanFlags: ParsableArguments {
    @Option(name: .long, help: "Path to a rules overlay (default: ~/.config/bleach/rules.yaml).")
    var rules: String?

    @Flag(name: .long, help: "Skip the lsregister dump. Faster, slightly less complete.")
    var fastInventory = false

    @Option(name: .long, help: "Only report candidates at or above this size, e.g. 100M.")
    var minSize: String?

    func options() -> ScanOptions {
        ScanOptions(rulesPath: rules, includeLaunchServices: !fastInventory)
    }

    /// Parse `500M` / `2G` / `1048576`.
    func minSizeBytes() -> Int64 {
        guard var s = minSize?.uppercased(), !s.isEmpty else { return 0 }
        let multipliers: [(String, Int64)] = [("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)]
        for (suffix, mult) in multipliers where s.hasSuffix(suffix) {
            s.removeLast()
            return Int64(Double(s) ?? 0) * mult
        }
        return Int64(s) ?? 0
    }
}
