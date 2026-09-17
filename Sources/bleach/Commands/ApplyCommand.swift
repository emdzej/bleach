import ArgumentParser
import BleachCore
import BleachTUI
import Foundation

struct Apply: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Move a plan's paths into a restorable quarantine.",
        discussion: """
        Every entry is re-validated against live state first: existence, \
        symlinks, current protection rules, running processes, and whether the \
        directory has grown since the plan was written. Paths are renamed \
        into ~/.local/state/bleach/quarantine, not deleted — use \
        `bleach restore` to undo, `bleach quarantine --purge` to commit.
        """
    )

    @Argument(help: "Plan file written by `bleach plan`.")
    var planPath: String

    @Flag(name: .long, help: "Show what would happen and exit. This is the default unless --yes is given.")
    var dryRun = false

    @Flag(name: .long, help: "Actually move the files.")
    var yes = false

    @Option(name: .long, help: "Disposal: quarantine (default, reversible), trash, or delete.")
    var mode: RemovalMode = .quarantine

    @Flag(name: .long, help: "Permit REVIEW and UNKNOWN tiers, which are refused by default.")
    var allowReview = false

    @Flag(name: .long, help: "Skip the lsregister dump when rebuilding the safety inventory.")
    var fastInventory = false

    func run() throws {
        let plan = try RemovalPlan.read(from: planPath)
        let rules = try Rules.load().compiled()

        // The validator needs live inventory — specifically running processes
        // and app bundles — so this is rebuilt even though it costs a moment.
        if ANSI.isTTY {
            FileHandle.standardError.write(Data("  checking live state…\r".utf8))
        }
        let inventory = AppInventory.collect(includeLaunchServices: !fastInventory)
        if ANSI.isTTY {
            FileHandle.standardError.write(Data(("\r" + ANSI.clearLine).utf8))
        }

        let validator = ApplyValidator(
            rules: rules,
            inventory: inventory,
            allowNonActionableTiers: allowReview
        )

        // Validate everything up front so the user sees the full picture
        // before anything moves.
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
        print("  plan: " + ANSI.bold(planPath)
            + ANSI.grey("  written \(Self.format(plan.createdAt))"))
        print("  " + ANSI.green("\(permitted.count) permitted")
            + ANSI.grey(" · ")
            + ANSI.bold(ByteFormat.short(permitted.reduce(0) { $0 + $1.sizeBytes }).trimmingCharacters(in: .whitespaces))
            + (refused.isEmpty ? "" : ANSI.grey(" · ") + ANSI.yellow("\(refused.count) refused")))
        print("")

        for (entry, reason) in refused.prefix(15) {
            print("  " + ANSI.yellow("skip ") + ANSI.pad(ByteFormat.short(entry.sizeBytes), to: 8)
                + ANSI.truncateHead(entry.path, to: 48) + " — " + ANSI.grey(reason))
        }
        if refused.count > 15 { print("  " + ANSI.grey("… \(refused.count - 15) more refusals")) }
        if !refused.isEmpty { print("") }

        guard !permitted.isEmpty else {
            print("  nothing to do.")
            print("")
            return
        }

        if !yes {
            print("  " + ANSI.grey("mode: ") + ANSI.bold(mode.label)
                + ANSI.grey(" — " + mode.summary))
            print("")
            for entry in permitted.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(20) {
                print("  " + ANSI.green("move ") + ANSI.pad(ByteFormat.short(entry.sizeBytes), to: 8)
                    + ANSI.truncateHead(entry.path, to: 62))
            }
            if permitted.count > 20 { print("  " + ANSI.grey("… \(permitted.count - 20) more")) }
            print("")
            print("  " + ANSI.grey("dry run — nothing changed. Re-run with --yes to proceed."))
            print("")
            return
        }

        // `delete` is the one mode with no way back, so --yes alone is not
        // enough: the user has to name the mode on an interactive terminal.
        if mode == .delete, ANSI.isTTY {
            print("  " + ANSI.red(ANSI.bold("This permanently deletes "
                + ByteFormat.short(permitted.reduce(0) { $0 + $1.sizeBytes })
                    .trimmingCharacters(in: .whitespaces)
                + " with no undo.")))
            print("  Type " + ANSI.bold("delete") + " to confirm: ", terminator: "")
            guard let typed = readLine(), typed == "delete" else {
                print("  aborted.")
                print("")
                return
            }
        }

        let report = try ApplyRunner.execute(
            entries: permitted,
            plan: plan,
            mode: mode,
            validator: validator
        )
        ApplyRunner.printOutcome(report)
    }

    static func batchID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }
}

extension RemovalMode: ExpressibleByArgument {}

/// Shared execution + reporting, used by both `bleach apply` and the TUI so
/// the destructive path exists exactly once.
enum ApplyRunner {
    static func execute(
        entries: [RemovalPlan.Entry],
        plan: RemovalPlan,
        mode: RemovalMode,
        validator: ApplyValidator
    ) throws -> Remover.Report {
        var done = 0
        let report = try Remover().run(
            RemovalPlan(createdAt: plan.createdAt, home: plan.home, entries: entries),
            mode: mode,
            batchID: Apply.batchID(),
            // Re-validated per entry, immediately before disposal, to close
            // the window between the summary the user read and the act.
            validate: { validator.reasonToRefuse($0) },
            onProgress: { _ in
                done += 1
                if ANSI.isTTY {
                    FileHandle.standardError.write(Data(
                        "\r\(ANSI.clearLine)  \(mode.rawValue) \(done)/\(entries.count)".utf8))
                }
            }
        )
        if ANSI.isTTY { FileHandle.standardError.write(Data(("\r" + ANSI.clearLine).utf8)) }
        return report
    }

    static func printOutcome(_ report: Remover.Report) {
        let verb = report.mode == .delete ? "deleted" :
            (report.mode == .trash ? "trashed" : "quarantined")
        print("  " + ANSI.green("\(verb) \(report.removed.count) paths")
            + ANSI.grey(" · ")
            + ANSI.bold(ByteFormat.short(report.bytes).trimmingCharacters(in: .whitespaces)))
        for skip in report.skipped {
            print("  " + ANSI.yellow("skip ") + ANSI.truncateHead(skip.path, to: 52)
                + " — " + ANSI.grey(skip.reason))
        }
        print("")
        if report.restorable {
            print("  batch " + ANSI.bold(report.batchID))
            print("  " + ANSI.grey("undo:    bleach restore \(report.batchID)"))
            print("  " + ANSI.grey("commit:  bleach quarantine --purge --all"))
        } else if report.mode == .trash {
            print("  " + ANSI.grey("in Finder's Trash — still using disk until you empty it"))
        } else {
            print("  " + ANSI.grey("gone. Recorded in ~/.local/state/bleach/journal.jsonl"))
        }
        print("")
    }
}
