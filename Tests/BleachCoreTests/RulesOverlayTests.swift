import XCTest
@testable import BleachCore

/// A user's `rules.yaml` is expected to be a handful of lines, not a full copy
/// of the shipped defaults.
///
/// Regression: the overlay was decoded as `Rules`, and Swift's synthesised
/// `Decodable` ignores property default values — so a partial overlay threw
/// `keyNotFound` on the first key the user had not written, and every scanning
/// command exited 1. The worked example in docs/guide/rules.md was itself
/// partial, so following the documentation broke the tool.
final class RulesOverlayTests: XCTestCase {
    var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "bleach-rules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func overlay(_ yaml: String) throws -> Rules {
        let path = "\(dir!)/rules.yaml"
        try yaml.write(toFile: path, atomically: true, encoding: .utf8)
        return try Rules.load(userPath: path)
    }

    func testTheDocumentedWorkedOverlayLoads() throws {
        // Verbatim from docs/guide/rules.md.
        let rules = try overlay("""
        # ~/.config/bleach/rules.yaml

        # Never touch my scratch dirs, whatever bleach thinks.
        protected_names:
          - .experiments
          - .localstack
        """)
        XCTAssertTrue(rules.protectedNames.contains(".experiments"))
        XCTAssertTrue(rules.protectedNames.contains(".localstack"))
        // Defaults survive alongside the additions.
        XCTAssertTrue(rules.protectedNames.contains(".ssh"))
        XCTAssertEqual(rules.staleDays, 180)
        XCTAssertFalse(rules.protectedBundlePrefixes.isEmpty)
        XCTAssertFalse(rules.aliases.isEmpty)
    }

    func testASingleScalarOverlayLoads() throws {
        XCTAssertEqual(try overlay("stale_days: 30").staleDays, 30)
    }

    func testAnEmptyOverlayIsIgnored() throws {
        XCTAssertEqual(try overlay("# nothing but a comment\n").staleDays, 180)
        XCTAssertEqual(try overlay("   \n\n").staleDays, 180)
    }

    /// Regression: presence was inferred by comparing against the default
    /// value, so writing a threshold that happened to equal the default was
    /// silently a no-op — and indistinguishable from a typo'd key.
    func testAScalarMayBeSetToTheSameValueAsTheDefault() throws {
        let rules = try overlay("stale_days: 180\nkeep_versions: 1\nmin_actionable_bytes: 10485760")
        XCTAssertEqual(rules.staleDays, 180)
        XCTAssertEqual(rules.keepVersions, 1)
        XCTAssertEqual(rules.minActionableBytes, 10_485_760)
    }

    func testProtectionListsCanOnlyGrow() throws {
        let defaults = try Rules.load(userPath: "/nonexistent")
        let rules = try overlay("""
        protected_names: []
        protected_path_contains: []
        protected_bundle_prefixes: []
        """)
        // An overlay writing empty lists cannot subtract from the defaults.
        XCTAssertEqual(rules.protectedNames.count, defaults.protectedNames.count)
        XCTAssertEqual(rules.protectedPathContains.count, defaults.protectedPathContains.count)
        XCTAssertEqual(rules.protectedBundlePrefixes.count, defaults.protectedBundlePrefixes.count)
    }

    func testMapsMergeWithTheUserWinning() throws {
        let rules = try overlay("""
        aliases:
          "Code": com.example.mine
          "MyThing": com.example.thing
        """)
        XCTAssertEqual(rules.aliases["Code"], "com.example.mine")
        XCTAssertEqual(rules.aliases["MyThing"], "com.example.thing")
        // Untouched defaults remain.
        XCTAssertEqual(rules.aliases["Raycast"], "com.raycast.macos")
    }

    func testAMalformedOverlayStillFails() throws {
        // Loudly, rather than silently falling back to defaults: a rules file
        // the user thinks is in effect but isn't is the worst outcome.
        let path = "\(dir!)/rules.yaml"
        try "stale_days: [this is not an int]".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Rules.load(userPath: path))
    }

    /// bleach's own quarantine must not be actionable, since it holds the undo
    /// history for everything the tool has ever moved.
    func testBleachOwnStateIsProtected() throws {
        let rules = try Rules.load(userPath: "/nonexistent").compiled()
        XCTAssertNotNil(rules.protectedPathReason("/Users/someone/.local/state/bleach"))
        XCTAssertNotNil(
            rules.protectedPathReason("/Users/someone/.local/state/bleach/quarantine/b1"))
    }

    func testTheQuarantineIsExcludedFromScanning() {
        let roots = ScanRoots.userDefaults(home: URL(fileURLWithPath: "/Users/someone"))
        let state = roots.first { $0.id == "xdg-state" }
        XCTAssertEqual(state?.path, "/Users/someone/.local/state")
        XCTAssertTrue(state?.excludeChildren.contains("bleach") == true,
                      "scanning its own quarantine let bleach plan the removal of its undo history")
    }
}
