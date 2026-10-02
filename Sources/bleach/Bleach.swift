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
        version: "0.4.0",
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

    @Option(name: .long, help: "Only report candidates at or above this size, e.g. 100M or 2GB.")
    var minSize: String?

    @Flag(name: .long, help: "Do not discover or run plugins.")
    var noPlugins = false

    func options() -> ScanOptions {
        ScanOptions(
            rulesPath: rules,
            includeLaunchServices: !fastInventory,
            enablePlugins: !noPlugins
        )
    }

    /// Parse `500M` / `2GB` / `1048576`.
    ///
    /// Throws rather than defaulting to 0 on garbage. A silent 0 means "no
    /// minimum", so `--min-size 100MB` used to *widen* a plan to everything
    /// instead of narrowing it to large directories — the opposite of what
    /// was asked for, with no indication anything was wrong.
    func minSizeBytes() throws -> Int64 {
        guard var s = minSize?.trimmingCharacters(in: .whitespaces).uppercased(),
              !s.isEmpty else { return 0 }
        var multiplier: Int64 = 1
        if s.hasSuffix("B") { s.removeLast() }          // 2GB and 2G both work
        let units: [(Character, Int64)] = [
            ("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10),
        ]
        if let last = s.last, let unit = units.first(where: { $0.0 == last }) {
            multiplier = unit.1
            s.removeLast()
        }
        guard let value = Double(s), value >= 0, value.isFinite else {
            throw ValidationError(
                "could not read --min-size \"\(minSize!)\"; expected a number "
                + "with an optional K/M/G/T suffix, e.g. 100M")
        }
        return Int64(value * Double(multiplier))
    }
}
