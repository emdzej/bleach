import ArgumentParser
import BleachCore
import BleachTUI
import Foundation

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Move quarantined paths back where they came from."
    )

    @Argument(help: "Batch ID, as printed by `apply`. Omit to restore the most recent batch.")
    var batchID: String?

    @Option(name: .long, help: "Restore only this original path. Repeatable.")
    var path: [String] = []

    func run() throws {
        let quarantine = Quarantine()
        let batches = quarantine.batches()
        guard let target = batchID ?? batches.last?.id else {
            print("quarantine is empty.")
            return
        }
        let only = path.isEmpty ? nil : Set(path)
        let (restored, skipped) = try quarantine.restore(batchID: target, only: only)

        print("")
        print("  " + ANSI.green("restored \(restored.count) paths") + ANSI.grey(" from batch \(target)"))
        for p in restored.prefix(20) { print("    " + ANSI.truncateHead(p, to: 70)) }
        if restored.count > 20 { print("    " + ANSI.grey("… \(restored.count - 20) more")) }
        for skip in skipped {
            print("  " + ANSI.yellow("skip ") + ANSI.truncateHead(skip.path, to: 50)
                + " — " + ANSI.grey(skip.reason))
        }
        print("")
    }
}

struct QuarantineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quarantine",
        abstract: "List the quarantine, or permanently delete old batches."
    )

    @Flag(name: .long, help: "Permanently delete batches older than --older-than days.")
    var purge = false

    @Option(name: .long, help: "Age threshold in days for --purge. Default 30.")
    var olderThan: Int = 30

    @Flag(name: .long, help: "Purge every batch regardless of age.")
    var all = false

    @Flag(name: .long, help: "Required to actually purge.")
    var yes = false

    func run() throws {
        let quarantine = Quarantine()
        let batches = quarantine.batches()

        if purge {
            let threshold: Int? = all ? nil : olderThan
            let candidates = all ? batches : batches.filter {
                $0.createdAt < Date().addingTimeInterval(-Double(olderThan) * 86400)
            }
            guard !candidates.isEmpty else {
                print(all ? "quarantine is already empty."
                          : "nothing older than \(olderThan) days. Use --all to purge everything.")
                return
            }
            let bytes = candidates.reduce(Int64(0)) { $0 + $1.totalBytes }
            print("")
            for b in candidates {
                print("  " + ANSI.pad(b.id, to: 18)
                    + ANSI.pad(ByteFormat.short(b.totalBytes), to: 8)
                    + ANSI.grey("\(b.items.count) paths"))
            }
            print("")
            guard yes else {
                print("  " + ANSI.yellow("This permanently deletes \(ByteFormat.short(bytes).trimmingCharacters(in: .whitespaces)) and cannot be undone."))
                print("  " + ANSI.grey("Re-run with --yes to confirm."))
                print("")
                return
            }
            let purged = try quarantine.purge(olderThanDays: threshold)
            print("  purged \(purged.count) batches, "
                + ByteFormat.short(bytes).trimmingCharacters(in: .whitespaces) + " freed")
            print("")
            return
        }

        guard !batches.isEmpty else {
            print("quarantine is empty. (\(quarantine.root))")
            return
        }
        print("")
        print("  " + ANSI.bold("quarantine") + ANSI.grey("  \(quarantine.root)"))
        print("")
        for b in batches {
            print("  " + ANSI.bold(ANSI.pad(b.id, to: 18))
                + ANSI.pad(ByteFormat.short(b.totalBytes), to: 8)
                + ANSI.grey("\(b.items.count) paths · \(Apply.format(b.createdAt))"))
            for item in b.items.sorted(by: { $0.sizeBytes > $1.sizeBytes }).prefix(5) {
                print("      " + ANSI.grey(ANSI.pad(ByteFormat.short(item.sizeBytes), to: 8)
                    + ANSI.truncateHead(item.originalPath, to: 62)))
            }
            if b.items.count > 5 { print("      " + ANSI.grey("… \(b.items.count - 5) more")) }
        }
        print("")
        print("  " + ANSI.grey("restore: bleach restore <batch>   ·   commit: bleach quarantine --purge"))
        print("")
    }
}

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Print the effective rules, or write a starter overlay."
    )

    @Flag(name: .long, help: "Write the defaults to ~/.config/bleach/rules.yaml.")
    var initialize = false

    @Flag(name: .long, help: "List discovered plugins and any warnings.")
    var plugins = false

    func run() throws {
        if plugins {
            var host = PluginHost()
            host.discover()
            print("")
            if host.plugins.isEmpty {
                print("  no plugins found. Searched:")
                for p in PluginHost.searchPaths() { print("    " + ANSI.grey(p)) }
            } else {
                for p in host.plugins {
                    print("  " + ANSI.bold(p.manifest.name)
                        + ANSI.grey("  [\(p.manifest.capabilities.joined(separator: ", "))]"))
                    print("    " + ANSI.grey(p.manifest.description))
                    for own in p.manifest.owns { print("    owns " + ANSI.cyan(own)) }
                }
            }
            for warning in host.warnings {
                print("  " + ANSI.yellow("! \(warning.plugin): \(warning.message)"))
            }
            print("")
            return
        }

        if initialize {
            let path = Rules.userRulesPath
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: path) else {
                print("exists already: \(path)")
                return
            }
            try Rules.defaultYAML.write(toFile: path, atomically: true, encoding: .utf8)
            print("wrote \(path)")
            return
        }
        print(Rules.defaultYAML)
    }
}
