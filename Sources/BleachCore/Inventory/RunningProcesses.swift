import Foundation

/// Anything with a live process is untouchable, full stop. Deleting the state
/// of a running app is the single most damaging thing this tool could do, so
/// this source gets maximum confidence and is consulted again at apply time.
public enum RunningProcesses {
    public static func load() -> (records: [AppRecord], executablePaths: [String]) {
        let r = Shell.run("/bin/ps", ["-axo", "comm="], timeout: 20)
        let paths = r.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var records: [AppRecord] = []
        for path in paths {
            // /Applications/Foo.app/Contents/MacOS/Foo -> the bundle root
            guard let range = path.range(of: ".app/Contents/MacOS/") else { continue }
            let bundlePath = String(path[path.startIndex..<range.lowerBound]) + ".app"
            if var rec = AppBundles.read(bundleAt: bundlePath, source: .runningProcess) {
                rec.sources = [.runningProcess]
                records.append(rec)
            }
        }
        return (records, paths)
    }
}
