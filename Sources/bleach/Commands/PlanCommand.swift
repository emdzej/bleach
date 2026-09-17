import ArgumentParser
import BleachCore
import BleachTUI
import Foundation

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Write a reviewable removal plan. Read-only.",
        discussion: """
        Produces a JSON plan you are expected to read and edit before running \
        `bleach apply`. By default only CACHE-SAFE and ORPHAN? entries are \
        included; everything else has to be added deliberately.
        """
    )

    @OptionGroup var flags: ScanFlags

    @Option(name: [.short, .long], help: "Where to write the plan.")
    var output: String = "bleach-plan.json"

    @Option(name: .long, help: "Tiers to include, comma-separated. Default: cache-safe,orphan.")
    var tiers: String = "cache-safe,orphan"

    @Flag(name: .long, help: "Print the plan to stdout instead of writing a file.")
    var stdout = false

    func run() throws {
        let requested = tiers.split(separator: ",").compactMap { Tier.parse(String($0)) }
        guard !requested.isEmpty else {
            throw ValidationError("no recognisable tiers in --tiers \(tiers)")
        }

        let showProgress = ANSI.isTTY && !stdout
        let result = try ScanEngine.run(options: flags.options()) { phase in
            if showProgress { Progress.render(phase) }
        }
        if showProgress { Progress.finish() }

        let minSize = flags.minSizeBytes()
        let chosen = result.candidates.filter {
            requested.contains($0.tier)
                && !$0.supersededByChildren
                && !$0.requiresRoot          // /Library needs root; never plannable
                && $0.sizeBytes >= minSize
        }

        guard !chosen.isEmpty else {
            print("Nothing to plan for tiers: \(requested.map(\.label).joined(separator: ", "))")
            return
        }

        let plan = RemovalPlan.from(candidates: chosen)
        if stdout {
            print(String(decoding: try RemovalPlan.encoder().encode(plan), as: UTF8.self))
            return
        }
        try plan.write(to: output)

        print("")
        print("  wrote " + ANSI.bold(output))
        print("  " + ANSI.pad("\(plan.entries.count) entries", to: 16)
            + ANSI.bold(ByteFormat.short(plan.totalBytes).trimmingCharacters(in: .whitespaces)))
        print("")
        for entry in plan.entries.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(12) {
            print("    " + ANSI.pad(ByteFormat.short(entry.sizeBytes), to: 8)
                + TierStyle.colored(entry.tier) + " "
                + ANSI.truncateHead(entry.path, to: 62))
        }
        if plan.entries.count > 12 {
            print("    " + ANSI.grey("… \(plan.entries.count - 12) more"))
        }
        print("")
        print("  " + ANSI.yellow("Read the plan before applying.") + " Then:")
        print("    bleach apply \(output) --dry-run")
        print("    bleach apply \(output)")
        print("")
    }
}
