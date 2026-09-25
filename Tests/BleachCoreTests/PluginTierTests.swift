import XCTest
@testable import BleachCore

/// The documented plugin invariant, exercised end to end through a real
/// plugin executable: a plugin may sharpen a verdict core did not reach, and
/// may make one more protective, but it can never talk core *out of* a verdict
/// it did reach.
///
/// `PluginSecurityTests` covers the path checks at the boundary. This covers
/// what happens to the tier afterwards, which is where a hint used to be able
/// to promote a REVIEW ("holds user-data-shaped files") straight to
/// CACHE-SAFE, because `hardProtected` marks only the five tier-0 rules.
final class PluginTierTests: XCTestCase {
    var home: String!
    var pluginDir: String!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "bleach-pt-\(UUID().uuidString)"
        pluginDir = "\(home!)/plugins"
        try FileManager.default.createDirectory(atPath: pluginDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("BLEACH_PLUGIN_PATH")
        try? FileManager.default.removeItem(atPath: home)
    }

    /// 11 MB: over the 10 MB `min_actionable_bytes` floor, so the tier under
    /// test is not demoted to UNKNOWN for being too small to bother with.
    private func makeCandidateDir(_ name: String, userData: Bool, stale: Bool) throws -> String {
        let fm = FileManager.default
        let path = "\(home!)/.tool/sessions/\(name)"
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        fm.createFile(atPath: path + "/blob.bin", contents: Data(count: 11 * 1024 * 1024),
                      attributes: nil)
        if userData {
            fm.createFile(atPath: path + "/notes.sqlite", contents: Data(count: 1024),
                          attributes: nil)
        }
        if stale {
            let old = Date(timeIntervalSinceNow: -400 * 86400)
            for child in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
                try? fm.setAttributes([.modificationDate: old],
                                      ofItemAtPath: path + "/" + child)
            }
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: path)
        }
        return path
    }

    /// A plugin is just an executable speaking JSON on stdio, so the most
    /// honest test of the boundary is a real one.
    private func installPlugin(hints: [(path: String, hint: String)]) throws {
        let candidates = hints.map {
            #"{"path":"\#($0.path)","tier_hint":"\#($0.hint)"}"#
        }.joined(separator: ",")
        let script = """
        #!/bin/sh
        case "$1" in
          manifest)
            printf '%s' '{"protocol":1,"name":"tier-probe","description":"probe",
        "capabilities":["enumerate"],"owns":["\(home!)/.tool"]}'
            ;;
          enumerate)
            cat > /dev/null
            printf '%s' '{"protocol":1,"candidates":[\(candidates)]}'
            ;;
          *) exit 2 ;;
        esac
        """
        let exe = "\(pluginDir!)/tier-probe"
        try script.write(toFile: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe)
        setenv("BLEACH_PLUGIN_PATH", pluginDir, 1)
    }

    /// Only the plugin contributes candidates, so the tier under test is
    /// unambiguously the plugin path's.
    private func scan() throws -> [String: Candidate] {
        let result = try ScanEngine.run(options: ScanOptions(
            home: home, roots: [], rulesPath: "/nonexistent",
            includeLaunchServices: false, enablePlugins: true))
        XCTAssertEqual(result.loadedPlugins, ["tier-probe"],
                       "plugin did not load: \(result.pluginWarnings.map(\.message))")
        return Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.path, $0) })
    }

    // MARK: - Sharpening is allowed

    /// The case the plugin API exists for: core reached no verdict, so the
    /// plugin's knowledge of its own tool's layout decides.
    func testAHintSharpensAnUnknownVerdict() throws {
        let path = try makeCandidateDir("fresh", userData: false, stale: false)
        try installPlugin(hints: [(path, "orphan_likely")])

        let candidate = try XCTUnwrap(scan()[path])
        XCTAssertEqual(candidate.tier, .orphanLikely)
        XCTAssertTrue(candidate.tier.isActionable)
    }

    // MARK: - Weakening is not

    /// Regression: core tiers this REVIEW because it holds user-data-shaped
    /// files. A `cache_safe` hint used to overwrite that outright and make it
    /// actionable, because the REVIEW was not `hardProtected`.
    func testAHintCannotWeakenAReviewVerdict() throws {
        let path = try makeCandidateDir("has-user-data", userData: true, stale: true)
        try installPlugin(hints: [(path, "cache_safe")])

        let candidate = try XCTUnwrap(scan()[path])
        XCTAssertEqual(candidate.tier, .review, "a plugin must not overrule a REVIEW verdict")
        XCTAssertFalse(candidate.tier.isActionable)
        XCTAssertTrue(
            candidate.evidence.contains { $0.detail.contains("core tiered this REVIEW, which wins") },
            "the refusal belongs in the evidence trail")
    }

    /// `protected` from a plugin is a *more* protective verdict than core's,
    /// so it is honoured.
    func testAHintMayStillMakeAVerdictMoreProtective() throws {
        let path = try makeCandidateDir("fresh-2", userData: false, stale: false)
        try installPlugin(hints: [(path, "protected")])

        let candidate = try XCTUnwrap(scan()[path])
        XCTAssertEqual(candidate.tier, .protected)
    }

    // MARK: - Discovery

    /// Regression: `searchPaths` included `./plugins` relative to the working
    /// directory, so `bleach scan` executed arbitrary files out of whatever
    /// directory it was invoked in. Cloning a repo shipping a `plugins/`
    /// directory was enough.
    func testDiscoveryIgnoresTheWorkingDirectory() {
        unsetenv("BLEACH_PLUGIN_PATH")
        let paths = PluginHost.searchPaths(home: home)
        XCTAssertEqual(paths, ["\(home!)/.config/bleach/plugins"])
        let cwd = FileManager.default.currentDirectoryPath
        XCTAssertFalse(paths.contains { $0.hasPrefix(cwd) },
                       "the working directory is not a trusted plugin source")
    }

    func testDiscoveryHonoursAnExplicitPluginPath() {
        setenv("BLEACH_PLUGIN_PATH", "/opt/one:/opt/two", 1)
        XCTAssertEqual(PluginHost.searchPaths(home: home),
                       ["\(home!)/.config/bleach/plugins", "/opt/one", "/opt/two"])
    }

    func testPluginsCanBeDisabledEntirely() throws {
        let path = try makeCandidateDir("fresh-3", userData: false, stale: false)
        try installPlugin(hints: [(path, "cache_safe")])

        let result = try ScanEngine.run(options: ScanOptions(
            home: home, roots: [], rulesPath: "/nonexistent",
            includeLaunchServices: false, enablePlugins: false))
        XCTAssertTrue(result.loadedPlugins.isEmpty)
        XCTAssertTrue(result.candidates.isEmpty)
    }
}
