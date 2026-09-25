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

    /// Regression: the home-confinement check was lexical, and the symlink
    /// check used lstat on the *leaf* only. So a path whose parent was a
    /// symlink out of the home directory passed both — and relocating
    /// `~/Library/Caches` to another volume is a routine disk-space move on
    /// the highest-traffic scan root there is.
    func testRefusesPathsEscapingHomeThroughASymlinkedParent() throws {
        let fm = FileManager.default
        let outside = NSTemporaryDirectory() + "bleach-outside-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: outside) }
        try fm.createDirectory(atPath: outside + "/victim", withIntermediateDirectories: true)
        fm.createFile(atPath: outside + "/victim/f.bin", contents: Data(count: 4096))

        try fm.createDirectory(atPath: "\(home!)/Library", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: "\(home!)/Library/Caches", withDestinationPath: outside)

        let path = "\(home!)/Library/Caches/victim"
        let measured = DirectoryWalker.stats(of: path, collectUserData: false).sizeBytes
        XCTAssertNotNil(validator().reasonToRefuse(entry(path, size: measured)),
                        "a symlinked parent must not be a way out of the home directory")
        XCTAssertTrue(fm.fileExists(atPath: outside + "/victim/f.bin"))
    }

    /// The same escape, closed at the plugin boundary too.
    func testPluginsCannotEscapeScopeThroughASymlinkedParent() throws {
        let fm = FileManager.default
        let outside = NSTemporaryDirectory() + "bleach-outside-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: outside) }
        try fm.createDirectory(atPath: outside + "/victim", withIntermediateDirectories: true)

        try fm.createDirectory(atPath: "\(home!)/.tool", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: "\(home!)/.tool/sessions", withDestinationPath: outside)

        var host = PluginHost(home: home)
        let manifest = PluginManifest(
            protocolVersion: 1, name: "probe", description: "",
            capabilities: ["enumerate"], owns: ["~/.tool"])
        let plugin = PluginHost.Loaded(manifest: manifest, executable: "/bin/true",
                                       ownsExpanded: manifest.expandedOwns(home: home))
        XCTAssertNil(host.validate("\(home!)/.tool/sessions/victim", for: plugin))
    }

    /// The path shape checks are shared by `apply` and `restore`, so they are
    /// worth pinning directly.
    func testSafePathComponentChecks() {
        XCTAssertTrue(SafePath.isSingleComponent("Library-Caches-Foo"))
        for bad in ["", ".", "..", "a/b", "/a", "a/"] {
            XCTAssertFalse(SafePath.isSingleComponent(bad), "\"\(bad)\" must be refused")
        }
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

    // MARK: - Version retention

    /// Version retention demotes "owner is installed, but this is an old
    /// version's leftovers". It must not touch a REVIEW verdict: REVIEW is a
    /// deliberate "a human needs to look at this", and `hardProtected` does
    /// not cover it because that flag marks only the tier-0 rules.
    func testVersionRetentionDoesNotPromoteAReviewVerdict() throws {
        let classifier = Classifier(rules: rules, inventory: AppInventory())
        func candidate(_ name: String, tier: Tier, daysOld: Double) -> Candidate {
            var c = Candidate(path: "\(home!)/\(name)", name: name, rootID: "r", kind: .state,
                              isDirectory: true, sizeBytes: 50 * 1024 * 1024, tier: tier)
            c.newestMTime = Date(timeIntervalSinceNow: -daysOld * 86400)
            return c
        }
        // Two versions of the same product; the older one is a REVIEW.
        let out = classifier.applyVersionRetention([
            candidate("IntelliJIdea2026.2", tier: .protected, daysOld: 1),
            candidate("IntelliJIdea2025.3", tier: .review, daysOld: 400),
        ])
        let older = try XCTUnwrap(out.first { $0.name == "IntelliJIdea2025.3" })
        XCTAssertEqual(older.tier, .review, "a REVIEW verdict must survive version retention")
        XCTAssertFalse(older.tier.isActionable)
    }

    func testVersionRetentionStillDemotesASoftProtectedSibling() throws {
        let classifier = Classifier(rules: rules, inventory: AppInventory())
        func candidate(_ name: String, daysOld: Double) -> Candidate {
            var c = Candidate(path: "\(home!)/\(name)", name: name, rootID: "r", kind: .state,
                              isDirectory: true, sizeBytes: 50 * 1024 * 1024, tier: .protected)
            c.newestMTime = Date(timeIntervalSinceNow: -daysOld * 86400)
            return c
        }
        let out = classifier.applyVersionRetention([
            candidate("IntelliJIdea2026.2", daysOld: 1),
            candidate("IntelliJIdea2025.3", daysOld: 400),
        ])
        let older = try XCTUnwrap(out.first { $0.name == "IntelliJIdea2025.3" })
        XCTAssertEqual(older.tier, .orphanLikely, "this is what version retention is for")
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
