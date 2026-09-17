import ArgumentParser
import BleachCore
import BleachTUI
import Foundation

struct TUI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Browse the scan interactively, then write a plan or apply directly."
    )

    @OptionGroup var flags: ScanFlags

    @Option(name: [.short, .long], help: "Where to write a plan if you press `w`.")
    var output: String = "bleach-plan.json"

    @Flag(name: .long, help: "Permit selecting REVIEW and UNKNOWN rows when applying from the TUI.")
    var allowReview = false

    func run() throws {
        // Guarded: the measure callback fires once per candidate, so on a
        // redirected stderr this would emit hundreds of KB of progress lines.
        let showProgress = ANSI.isTTY
        let result = try ScanEngine.run(options: flags.options()) { phase in
            if showProgress { Progress.render(phase) }
        }
        if showProgress { Progress.finish() }

        switch BrowserApp(result: result).run() {
        case .quit:
            return

        case .writePlan(let paths):
            let plan = planFor(paths, in: result)
            try plan.write(to: output)
            print("")
            print("  wrote " + ANSI.bold(output)
                + ANSI.grey("  \(plan.entries.count) entries · ")
                + ANSI.bold(ByteFormat.short(plan.totalBytes).trimmingCharacters(in: .whitespaces)))
            print("  " + ANSI.grey("review it, then: bleach apply \(output)"))
            print("")

        case .apply(let paths, let mode):
            try applyDirectly(planFor(paths, in: result), mode: mode, result: result)
        }
    }

    private func planFor(_ paths: [String], in result: ScanResult) -> RemovalPlan {
        let chosen = Set(paths)
        return RemovalPlan.from(candidates: result.candidates.filter { chosen.contains($0.path) })
    }

    /// The TUI already showed the mode, its consequence, and the paths, and
    /// took a confirmation — but validation is not part of that consent. It
    /// runs here against live state, identically to `bleach apply`, because
    /// the scan behind this screen may be many minutes old.
    private func applyDirectly(_ plan: RemovalPlan, mode: RemovalMode, result: ScanResult) throws {
        let rules = try Rules.load().compiled()

        if ANSI.isTTY {
            FileHandle.standardError.write(Data("  re-checking live state…\r".utf8))
        }
        let inventory = AppInventory.collect(includeLaunchServices: !flags.fastInventory)
        if ANSI.isTTY {
            FileHandle.standardError.write(Data(("\r" + ANSI.clearLine).utf8))
        }

        let validator = ApplyValidator(
            rules: rules,
            inventory: inventory,
            allowNonActionableTiers: allowReview
        )

        var permitted: [RemovalPlan.Entry] = []
        var refused: [(RemovalPlan.Entry, String)] = []
        for entry in plan.entries {
            if let reason = validator.reasonToRefuse(entry) {
                refused.append((entry, reason))
            } else {
                permitted.append(entry)
            }
        }

        print("")
        print("  " + ANSI.grey("mode: ") + ANSI.bold(mode.label))
        for (entry, reason) in refused.prefix(15) {
            print("  " + ANSI.yellow("skip ") + ANSI.pad(ByteFormat.short(entry.sizeBytes), to: 8)
                + ANSI.truncateHead(entry.path, to: 44) + " — " + ANSI.grey(reason))
        }
        if refused.count > 15 { print("  " + ANSI.grey("… \(refused.count - 15) more refusals")) }

        guard !permitted.isEmpty else {
            print("  nothing permitted after re-validation.")
            print("")
            return
        }

        let report = try ApplyRunner.execute(
            entries: permitted, plan: plan, mode: mode, validator: validator)
        ApplyRunner.printOutcome(report)
    }
}
