import Foundation

/// launchd agents and daemons. Two jobs here:
///
/// 1. A job whose `Program`/`ProgramArguments` binary still exists proves the
///    owner is alive even if no `.app` bundle exists.
/// 2. A job whose binary is *gone* is itself garbage worth reporting.
public enum LaunchDaemons {
    public static func directories(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
        ]
    }

    public struct Job: Sendable {
        public var label: String
        public var plistPath: String
        public var programPath: String?
        public var programExists: Bool
    }

    public static func load(home: String = NSHomeDirectory()) -> (records: [AppRecord], jobs: [Job]) {
        let fm = FileManager.default
        var records: [AppRecord] = []
        var jobs: [Job] = []
        for dir in directories(home: home) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".plist") {
                let plistPath = "\(dir)/\(entry)"
                let info = Plist.read(atPath: plistPath)
                let label = Plist.string(info, "Label") ?? String(entry.dropLast(6))
                let program = Plist.string(info, "Program")
                    ?? (info?["ProgramArguments"] as? [String])?.first
                let exists = program.map { fm.fileExists(atPath: $0) } ?? false
                jobs.append(Job(label: label, plistPath: plistPath,
                                programPath: program, programExists: exists))
                if exists, label.contains(".") {
                    records.append(AppRecord(
                        bundleID: label,
                        path: program,
                        sources: [.launchAgent],
                        existsOnDisk: true
                    ))
                }
            }
        }
        return (records, jobs)
    }
}
