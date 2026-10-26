import XCTest
@testable import BleachCore

/// Exercises the shipped `plugins/vscode-extensions` executable end to end.
///
/// The plugin's whole value is that it reads VS Code's own ledgers instead of
/// parsing versions out of directory names, so the fixtures here deliberately
/// use the version strings that defeat naive sorting: a date-stamped build
/// number (`0.45.2026092807`) that is numerically larger than its successor
/// (`0.46.0`), and a platform-suffixed version (`-darwin-arm64`).
final class VSCodeExtensionsPluginTests: XCTestCase {
    var home: String!
    var pluginDir: String!
    var extensionsDir: String!

    /// The plugin as shipped, located relative to this source file so the test
    /// cannot silently pass against a stale copy.
    private var shippedPlugin: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BleachCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("plugins/vscode-extensions")
            .path
    }

    override func setUpWithError() throws {
        let fm = FileManager.default
        home = NSTemporaryDirectory() + "bleach-vsx-\(UUID().uuidString)"
        pluginDir = "\(home!)/plugins"
        extensionsDir = "\(home!)/.vscode-insiders/extensions"
        try fm.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: extensionsDir, withIntermediateDirectories: true)

        let installed = "\(pluginDir!)/vscode-extensions"
        try fm.copyItem(atPath: shippedPlugin, toPath: installed)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installed)
        setenv("BLEACH_PLUGIN_PATH", pluginDir, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("BLEACH_PLUGIN_PATH")
        try? FileManager.default.removeItem(atPath: home)
    }

    /// Over the 10 MB `min_actionable_bytes` floor, so a correct verdict is
    /// not masked by the too-small-to-bother demotion.
    @discardableResult
    private func makeExtension(_ name: String) throws -> String {
        let path = "\(extensionsDir!)/\(name)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/extension.js",
                                       contents: Data(count: 11 * 1024 * 1024))
        return path
    }

    private func writeLedgers(installed: [(id: String, version: String, dir: String)],
                              obsolete: [String] = []) throws {
        let entries = installed.map { entry in
            """
            {"identifier":{"id":"\(entry.id)"},"version":"\(entry.version)",\
            "relativeLocation":"\(entry.dir)"}
            """
        }.joined(separator: ",")
        try "[\(entries)]".write(toFile: "\(extensionsDir!)/extensions.json",
                                atomically: true, encoding: .utf8)

        let marks = obsolete.map { "\"\($0)\":true" }.joined(separator: ",")
        try "{\(marks)}".write(toFile: "\(extensionsDir!)/.obsolete",
                               atomically: true, encoding: .utf8)
    }

    private func scan() throws -> [String: Candidate] {
        let result = try ScanEngine.run(options: ScanOptions(
            home: home, roots: [], rulesPath: "/nonexistent",
            includeLaunchServices: false, enablePlugins: true))
        XCTAssertEqual(result.loadedPlugins, ["vscode-extensions"],
                       "plugin did not load: \(result.pluginWarnings.map(\.message))")
        return Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.path, $0) })
    }

    // MARK: - The leak this exists to catch

    /// A build-dated version left behind after an update. `0.45.2026092807`
    /// sorts *above* `0.46.0` on any numeric reading of the trailing segment,
    /// so only the ledger can say which one the editor actually loads.
    func testSupersededVersionIsActionableAndNamesItsReplacement() throws {
        let stale = try makeExtension("vscjava.vscode-maven-0.45.2026092807")
        try makeExtension("vscjava.vscode-maven-0.46.0")
        try writeLedgers(installed: [("vscjava.vscode-maven", "0.46.0",
                                     "vscjava.vscode-maven-0.46.0")])

        let candidate = try XCTUnwrap(scan()[stale])
        XCTAssertEqual(candidate.tier, .orphanLikely)
        XCTAssertTrue(candidate.tier.isActionable)
        XCTAssertTrue(
            candidate.evidence.contains { $0.detail.contains("vscjava.vscode-maven-0.46.0") },
            "the surviving version belongs in the evidence trail")
    }

    /// The directory the ledger vouches for must never be proposed, even
    /// though its version string looks older than the stale sibling's.
    func testTheInstalledVersionIsNeverProposed() throws {
        try makeExtension("vscjava.vscode-maven-0.45.2026092807")
        let live = try makeExtension("vscjava.vscode-maven-0.46.0")
        try writeLedgers(installed: [("vscjava.vscode-maven", "0.46.0",
                                     "vscjava.vscode-maven-0.46.0")])

        if let candidate = scanIgnoringErrors()[live] {
            XCTAssertFalse(candidate.tier.isActionable,
                           "the installed extension must not be actionable")
        }
    }

    /// A platform triple after the version (`redhat.java-1.58.x-darwin-arm64`)
    /// must not be mistaken for an unreferenced directory.
    func testPlatformSuffixedInstalledVersionIsNotFlagged() throws {
        let live = try makeExtension("redhat.java-1.58.2026101608-darwin-arm64")
        try writeLedgers(installed: [("redhat.java", "1.58.2026101608",
                                     "redhat.java-1.58.2026101608-darwin-arm64")])

        if let candidate = scanIgnoringErrors()[live] {
            XCTAssertFalse(candidate.tier.isActionable)
        }
    }

    // MARK: - Safety

    /// An unreadable ledger must produce no opinion at all. Falling back to
    /// sorting directory names is how a cleanup tool uninstalls a working
    /// extension, so "report nothing" is the only acceptable degraded mode.
    func testACorruptLedgerProducesNoCandidates() throws {
        let stale = try makeExtension("vscjava.vscode-maven-0.45.2026092807")
        try makeExtension("vscjava.vscode-maven-0.46.0")
        try "not json {{{".write(toFile: "\(extensionsDir!)/extensions.json",
                                 atomically: true, encoding: .utf8)

        XCTAssertNil(scanIgnoringErrors()[stale],
                     "a corrupt ledger must not yield a guess")
    }

    /// Same, for a ledger that is simply absent.
    func testAMissingLedgerProducesNoCandidates() throws {
        let stale = try makeExtension("vscjava.vscode-maven-0.45.2026092807")
        try makeExtension("vscjava.vscode-maven-0.46.0")

        XCTAssertNil(scanIgnoringErrors()[stale],
                     "no ledger means no opinion")
    }

    /// Unreferenced, but with no surviving version and no delete marker: it
    /// might be mid-install or sideloaded from a VSIX. Report, do not propose.
    func testUnreferencedWithNoSuccessorIsReviewOnly() throws {
        let orphan = try makeExtension("mystery.sideloaded-9.9.9")
        try writeLedgers(installed: [("redhat.java", "1.0.0", "redhat.java-1.0.0")])

        let candidate = try XCTUnwrap(scan()[orphan])
        XCTAssertEqual(candidate.tier, .review)
        XCTAssertFalse(candidate.tier.isActionable)
    }

    /// `.obsolete` is the editor's own delete list, so it settles the question
    /// even when no successor survives to corroborate it.
    func testObsoleteMarkerIsActionableWithoutASurvivingSibling() throws {
        let marked = try makeExtension("github.copilot-1.303.0")
        try writeLedgers(installed: [("redhat.java", "1.0.0", "redhat.java-1.0.0")],
                         obsolete: ["github.copilot-1.303.0"])

        let candidate = try XCTUnwrap(scan()[marked])
        XCTAssertEqual(candidate.tier, .orphanLikely)
        XCTAssertTrue(candidate.evidence.contains { $0.detail.contains(".obsolete") })
    }

    private func scanIgnoringErrors() -> [String: Candidate] {
        (try? ScanEngine.run(options: ScanOptions(
            home: home, roots: [], rulesPath: "/nonexistent",
            includeLaunchServices: false, enablePlugins: true)))
            .map { Dictionary(uniqueKeysWithValues: $0.candidates.map { ($0.path, $0) }) } ?? [:]
    }
}
