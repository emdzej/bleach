import XCTest
@testable import BleachCore

/// The plugin boundary is the one place third-party code influences what gets
/// removed. A plugin may only ever speak about paths inside the scope it
/// declared, and only ones that really exist.
final class PluginSecurityTests: XCTestCase {
    var home: String!
    var scope: String!
    var host: PluginHost!
    var plugin: PluginHost.Loaded!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "bleach-plugin-\(UUID().uuidString)"
        scope = "\(home!)/.tool"
        try FileManager.default.createDirectory(atPath: "\(scope!)/sessions/alive",
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: "\(home!)/Documents",
                                                withIntermediateDirectories: true)
        host = PluginHost(home: home)
        let manifest = PluginManifest(
            protocolVersion: 1, name: "test", description: "",
            capabilities: ["enumerate"], owns: ["~/.tool"])
        plugin = PluginHost.Loaded(
            manifest: manifest, executable: "/bin/true",
            ownsExpanded: manifest.expandedOwns(home: home))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    func testAcceptsPathInsideDeclaredScope() {
        XCTAssertEqual(host.validate("\(scope!)/sessions/alive", for: plugin),
                       "\(scope!)/sessions/alive")
    }

    func testRejectsPathOutsideDeclaredScope() {
        // Exists, inside home, but the plugin never claimed it.
        XCTAssertNil(host.validate("\(home!)/Documents", for: plugin))
    }

    func testRejectsPathOutsideHome() {
        XCTAssertNil(host.validate("/etc/hosts", for: plugin))
    }

    func testRejectsTraversal() {
        XCTAssertNil(host.validate("\(scope!)/../Documents", for: plugin))
        XCTAssertNil(host.validate("\(scope!)/sessions/../../Documents", for: plugin))
    }

    func testRejectsRelativePaths() {
        XCTAssertNil(host.validate(".tool/sessions", for: plugin))
    }

    func testRejectsNonexistentPaths() {
        XCTAssertNil(host.validate("\(scope!)/sessions/ghost", for: plugin))
    }

    func testRejectsSymlinks() throws {
        let link = "\(scope!)/sessions/link"
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "\(home!)/Documents")
        XCTAssertNil(host.validate(link, for: plugin))
    }

    func testEveryRejectionIsReported() {
        _ = host.validate("/etc/hosts", for: plugin)
        _ = host.validate("\(home!)/Documents", for: plugin)
        // Silent drops would make a misbehaving plugin invisible.
        XCTAssertEqual(host.warnings.count, 2)
    }

    func testEvidenceWeightsAreClamped() {
        // A plugin must not be able to swamp core scoring.
        let hot = PluginEvidence(kind: "stale", detail: "x", weight: 9_999)
        let cold = PluginEvidence(kind: "stale", detail: "x", weight: -9_999)
        XCTAssertEqual(hot.toEvidence(pluginName: "p").weight, 10)
        XCTAssertEqual(cold.toEvidence(pluginName: "p").weight, -10)
    }

    func testUnknownTierHintIsNotActionable() {
        XCTAssertNil(Tier.fromHint("delete-everything"))
        XCTAssertEqual(Tier.fromHint("orphan_likely"), .orphanLikely)
    }
}
