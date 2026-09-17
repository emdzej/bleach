import XCTest
@testable import BleachCore

/// Tests for the invariants that make the tool safe to run. These are the
/// ones that must never regress: everything else is a heuristic, but these
/// are promises.
final class SafetyTests: XCTestCase {
    var home: String!
    var rules: Rules.Compiled!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "bleach-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        rules = try Rules.load(userPath: "/nonexistent").compiled()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func makeDir(_ relative: String) throws -> String {
        let path = "\(home!)/\(relative)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/file.bin", contents: Data(count: 4096))
        return path
    }

    private func entry(_ path: String, tier: Tier = .cacheSafe, size: Int64 = 4096) -> RemovalPlan.Entry {
        RemovalPlan.Entry(path: path, sizeBytes: size, tier: tier,
                          ownerLabel: nil, newestMTime: nil, reasons: [])
    }

    private func validator(allowReview: Bool = false) -> ApplyValidator {
        ApplyValidator(home: home, rules: rules, inventory: AppInventory(),
                       allowNonActionableTiers: allowReview)
    }

    // MARK: - Path shape

    func testRefusesPathsOutsideHome() {
        XCTAssertNotNil(validator().reasonToRefuse(entry("/etc/hosts")))
        XCTAssertNotNil(validator().reasonToRefuse(entry("/tmp/whatever")))
    }

    func testRefusesHomeItself() {
        XCTAssertNotNil(validator().reasonToRefuse(entry(home)))
    }

    func testRefusesRelativeAndTraversalPaths() {
        XCTAssertNotNil(validator().reasonToRefuse(entry("relative/path")))
        XCTAssertNotNil(validator().reasonToRefuse(entry("\(home!)/a/../a")))
    }

    func testRefusesSymlinks() throws {
        let real = try makeDir("real")
        let link = "\(home!)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        XCTAssertNotNil(validator().reasonToRefuse(entry(link)))
    }

    func testRefusesMissingPaths() {
        XCTAssertNotNil(validator().reasonToRefuse(entry("\(home!)/never-existed")))
    }

    // MARK: - Rules

    func testRefusesProtectedNames() throws {
        for name in [".ssh", ".gnupg", ".aws", ".Trash"] {
            let path = try makeDir(name)
            XCTAssertNotNil(validator().reasonToRefuse(entry(path)),
                            "\(name) must be refused")
        }
    }

    func testRefusesProtectedPathSubstrings() throws {
        let path = try makeDir("Library/Application Support/MobileSync")
        XCTAssertNotNil(validator().reasonToRefuse(entry(path)),
                        "iOS backups must be refused")
    }

    // MARK: - Tiers

    func testRefusesNonActionableTiersUnlessOptedIn() throws {
        let path = try makeDir("some-cache")
        XCTAssertNotNil(validator().reasonToRefuse(entry(path, tier: .review)))
        XCTAssertNotNil(validator().reasonToRefuse(entry(path, tier: .protected)))
        XCTAssertNil(validator(allowReview: true).reasonToRefuse(entry(path, tier: .review)))
    }

    func testPermitsAPlainActionableDirectory() throws {
        let path = try makeDir("some-cache")
        XCTAssertNil(validator().reasonToRefuse(entry(path)))
    }

    // MARK: - Drift

    func testRefusesDirectoriesThatGrewSincePlanning() throws {
        let path = try makeDir("grown")
        // Plan claimed 100 bytes; on disk there are at least 4096.
        XCTAssertNotNil(validator().reasonToRefuse(entry(path, size: 100)))
    }

    // MARK: - Overlap

    func testAncestorsWithFinerCandidatesAreNotActionable() {
        var candidates = [
            Candidate(path: "/h/a", name: "a", rootID: "r", kind: .state,
                      isDirectory: true, sizeBytes: 900, tier: .cacheSafe),
            Candidate(path: "/h/a/b", name: "b", rootID: "r", kind: .state,
                      isDirectory: true, sizeBytes: 500, tier: .cacheSafe),
            Candidate(path: "/h/a/c", name: "c", rootID: "r", kind: .state,
                      isDirectory: true, sizeBytes: 400, tier: .cacheSafe),
            Candidate(path: "/h/z", name: "z", rootID: "r", kind: .state,
                      isDirectory: true, sizeBytes: 100, tier: .cacheSafe),
        ]
        ScanEngine.markOverlaps(&candidates)

        let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
        XCTAssertTrue(byPath["/h/a"]!.supersededByChildren)
        XCTAssertFalse(byPath["/h/a"]!.tier.isActionable, "parent must not be actionable")
        XCTAssertFalse(byPath["/h/a/b"]!.supersededByChildren)
        XCTAssertTrue(byPath["/h/a/b"]!.tier.isActionable)
        XCTAssertFalse(byPath["/h/z"]!.supersededByChildren, "sibling is unaffected")
    }

    func testTierMostProtectiveNeverWeakens() {
        XCTAssertEqual(Tier.mostProtective(.cacheSafe, .protected), .protected)
        XCTAssertEqual(Tier.mostProtective(.orphanLikely, .review), .review)
        XCTAssertEqual(Tier.mostProtective(.protected, .unknown), .protected)
    }
}

private extension FileManager {
    func createFile(atPath path: String, contents: Data) {
        createFile(atPath: path, contents: contents, attributes: nil)
    }
}
