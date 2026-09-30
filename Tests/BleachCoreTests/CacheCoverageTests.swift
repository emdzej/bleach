import XCTest
@testable import BleachCore

/// Coverage for the large, well-known developer caches, and for the one rule
/// that is allowed to step around a tier-0 protection.
final class CacheCoverageTests: XCTestCase {
    var home: String!
    var rules: Rules.Compiled!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "bleach-cov-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        rules = try Rules.load(userPath: "/nonexistent").compiled()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    // MARK: - Scan roots

    /// `~/Library` is scanned at named subdirectories, so anything not on the
    /// list is invisible no matter how large. These two were: 8.5 GB under
    /// Developer and 5.4 GB of pnpm store on the machine this was added for.
    func testDeveloperAndPnpmAreScanRoots() {
        let roots = ScanRoots.userDefaults(home: URL(fileURLWithPath: "/Users/someone"))
        let byID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })

        let developer = byID["developer"]
        XCTAssertEqual(developer?.path, "/Users/someone/Library/Developer")
        // Descends a level so DerivedData and iOS DeviceSupport are separate
        // candidates from Archives, which must never share their verdict.
        XCTAssertTrue(developer?.multiTenantChildren.contains("Xcode") == true)
        XCTAssertTrue(developer?.multiTenantChildren.contains("CoreSimulator") == true)

        let pnpm = byID["pnpm-store"]
        XCTAssertEqual(pnpm?.path, "/Users/someone/Library/pnpm")
        XCTAssertEqual(pnpm?.enumerateChildren, false)
    }

    /// Regression: `enumerateChildren` was declared and documented on
    /// `ScanRoot` but never read, so a root could only ever be a container of
    /// candidates. The pnpm store needs to be one itself — `store` and
    /// `global` are meaningless alone and match no cleanup rule.
    func testANonEnumeratedRootIsItsOwnCandidate() throws {
        let fm = FileManager.default
        let store = "\(home!)/Library/pnpm"
        try fm.createDirectory(atPath: "\(store)/store/v3", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(store)/global/5", withIntermediateDirectories: true)

        let root = ScanRoot(id: "pnpm-store", path: store, kind: .cache,
                            enumerateChildren: false)
        let found = CandidateScanner.enumerate(roots: [root])
        XCTAssertEqual(found.map(\.path), [store])
        XCTAssertEqual(found.first?.name, "pnpm")
    }

    func testAnEnumeratedRootStillYieldsChildren() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(home!)/Caches/one", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(home!)/Caches/two", withIntermediateDirectories: true)

        let root = ScanRoot(id: "caches", path: "\(home!)/Caches", kind: .cache)
        let found = CandidateScanner.enumerate(roots: [root])
        XCTAssertEqual(found.map(\.name).sorted(), ["one", "two"])
    }

    func testANonEnumeratedRootThatDoesNotExistIsSkipped() {
        let root = ScanRoot(id: "pnpm-store", path: "\(home!)/nope", kind: .cache,
                            enumerateChildren: false)
        XCTAssertTrue(CandidateScanner.enumerate(roots: [root]).isEmpty)
    }

    // MARK: - Rules for the developer caches

    func testDeviceSupportSymbolsAreRegenerable() {
        // The watchOS and tvOS variants share the suffix. Routinely the
        // largest thing under ~/Library/Developer — 5.3 GB on the machine this
        // was added against — and re-extracted on the next device attach.
        for name in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport"] {
            XCTAssertNotNil(rules.isRegenerable(name: name), "\(name) is re-extracted on attach")
        }
    }

    /// DerivedData is delegated rather than regenerable on purpose: it
    /// routinely contains a registered .app bundle, which the nested-app rule
    /// hard-protects, so a regenerable pattern gave CACHE-SAFE or PROTECTED
    /// depending on whether the build had ever been launched.
    func testDerivedDataIsDelegatedWithAPlainRemedy() {
        XCTAssertNil(rules.isRegenerable(name: "DerivedData"))
        let command = rules.rules.delegatedCleanups["DerivedData"]
        XCTAssertNotNil(command)
        XCTAssertTrue(command?.contains("DerivedData") == true)

        let c = Candidate(
            path: "\(home!)/Library/Developer/Xcode/DerivedData",
            name: "Xcode/DerivedData", rootID: "developer", kind: .state,
            isDirectory: true, sizeBytes: 500_000_000,
            evidence: [Evidence(.containsInstalledApp, "a build you launched", weight: 20)],
            tier: .unknown)
        let out = Classifier(rules: rules, inventory: AppInventory()).classify(c)
        XCTAssertEqual(out.tier, .review, "a registered build inside must not flip this to PROTECTED")
    }

    /// Archives hold shipped builds and their dSYMs — the only copy of the
    /// symbols for a version already in users' hands.
    func testXcodeArchivesAndUserDataAreProtected() {
        XCTAssertNotNil(rules.protectedPathReason(
            "/Users/someone/Library/Developer/Xcode/Archives"))
        XCTAssertNotNil(rules.protectedPathReason(
            "/Users/someone/Library/Developer/Xcode/Archives/2026-09-30/MyApp.xcarchive"))
        XCTAssertNotNil(rules.protectedPathReason(
            "/Users/someone/Library/Developer/Xcode/UserData"))
        // Path-scoped, so an unrelated directory of the same name is still
        // judged on its own evidence.
        XCTAssertNil(rules.protectedPathReason(
            "/Users/someone/Library/Caches/SomeTool/Archives"))
    }

    func testSimulatorsDelegateToSimctl() {
        // Matched on the first path component of the candidate name, which is
        // how every child of CoreSimulator delegates.
        XCTAssertEqual(rules.rules.delegatedCleanups["CoreSimulator"],
                       "xcrun simctl delete unavailable")
        XCTAssertEqual(rules.rules.delegatedCleanups["go-build"], "go clean -cache")
        XCTAssertEqual(rules.rules.delegatedCleanups["pnpm"], "pnpm store prune")
        XCTAssertNotNil(rules.rules.delegatedCleanups["ms-playwright"])
    }

    private func classify(name: String, path: String? = nil,
                          evidence: [Evidence] = []) -> Candidate {
        let c = Candidate(
            path: path ?? "\(home!)/Library/Caches/\(name)",
            name: name, rootID: "caches", kind: .cache, isDirectory: true,
            sizeBytes: 1_500_000_000, evidence: evidence, tier: .unknown)
        return Classifier(rules: rules, inventory: AppInventory()).classify(c)
    }

    func testCoreSimulatorChildrenAreDelegatedNotActionable() {
        let c = Candidate(
            path: "\(home!)/Library/Developer/CoreSimulator/Devices",
            name: "CoreSimulator/Devices", rootID: "developer", kind: .state,
            isDirectory: true, sizeBytes: 2_300_000_000, tier: .unknown)
        let out = Classifier(rules: rules, inventory: AppInventory()).classify(c)
        XCTAssertEqual(out.tier, .review, "deleting a device directory loses its apps and data")
        XCTAssertTrue(out.evidence.contains { $0.detail.contains("xcrun simctl delete unavailable") })
    }

    // MARK: - The bundle-prefix carve-out

    /// Regression: `com.microsoft.VSCodeInsiders.ShipIt` is a Squirrel.Mac
    /// update staging directory, but it inherits the `com.microsoft.VSCode`
    /// prefix that is protected because *workspace state* is not
    /// reconstructible. 1.4 GB of stale installer payload was therefore
    /// permanently PROTECTED and never proposed.
    func testAnUpdaterStagingDirectoryIsNotShieldedByItsVendorPrefix() {
        let out = classify(name: "com.microsoft.VSCodeInsiders.ShipIt")
        XCTAssertEqual(out.tier, .cacheSafe)
        XCTAssertFalse(out.hardProtected)
        XCTAssertTrue(
            out.evidence.contains { $0.detail.contains("marks this regenerable regardless") },
            "the bypass must be visible in the evidence trail")
    }

    /// The vendor's actual state is still hard-protected. This is the pairing
    /// that makes the carve-out safe to have at all.
    func testTheVendorsRealStateIsStillHardProtected() {
        let out = classify(name: "com.microsoft.VSCodeInsiders",
                           path: "\(home!)/Library/Application Support/com.microsoft.VSCodeInsiders")
        XCTAssertEqual(out.tier, .protected)
        XCTAssertTrue(out.hardProtected)
    }

    /// The carve-out is scoped to the bundle-prefix rule alone. Every other
    /// tier-0 protection still wins, even for an exempt name.
    func testTheCarveOutDoesNotBypassOtherProtections() {
        // A live process.
        let running = classify(
            name: "com.microsoft.VSCodeInsiders.ShipIt",
            evidence: [Evidence(.runningProcess, "live", weight: 20)])
        XCTAssertEqual(running.tier, .protected)
        XCTAssertTrue(running.hardProtected)

        // A protected path.
        let onProtectedPath = classify(
            name: "com.microsoft.VSCodeInsiders.ShipIt",
            path: "\(home!)/Library/Application Support/MobileSync/com.microsoft.VSCodeInsiders.ShipIt")
        XCTAssertEqual(onProtectedPath.tier, .protected)
        XCTAssertTrue(onProtectedPath.hardProtected)

        // A registered .app bundle living inside — a self-updater's real install.
        let holdsAnApp = classify(
            name: "com.microsoft.VSCodeInsiders.ShipIt",
            evidence: [Evidence(.containsInstalledApp, "an app lives inside", weight: 20)])
        XCTAssertEqual(holdsAnApp.tier, .protected)

        // User-data-shaped contents still demand a human.
        let holdsUserData = classify(
            name: "com.microsoft.VSCodeInsiders.ShipIt",
            evidence: [Evidence(.userDataMarker, "contains notes.sqlite", weight: 3)])
        XCTAssertEqual(holdsUserData.tier, .review)
    }

    /// Regression: a delegated-cleanup entry used to be consulted *after* the
    /// protected-bundle-prefix heuristic, so a generic leaf name that
    /// name-matched an Apple bundle ID was hard-protected and the curated
    /// cleanup advice never surfaced. `CoreSimulator/Devices` resolved to
    /// `com.apple.dt.Devices` this way, and the shipped `com.apple.dt.Xcode`
    /// entry had been unreachable since it was written.
    func testDelegationOutranksTheBundlePrefixHeuristic() {
        let owner = AppRecord(bundleID: "com.apple.dt.Devices", name: "Devices",
                              sources: [.spotlight], existsOnDisk: true)
        var c = Candidate(
            path: "\(home!)/Library/Developer/CoreSimulator/Devices",
            name: "CoreSimulator/Devices", rootID: "developer", kind: .state,
            isDirectory: true, sizeBytes: 2_300_000_000, tier: .unknown)
        c.owner = owner
        let out = Classifier(rules: rules, inventory: AppInventory()).classify(c)
        XCTAssertEqual(out.tier, .review)
        XCTAssertTrue(out.evidence.contains { $0.detail.contains("simctl delete unavailable") })

        // And the entry that was dead on arrival now resolves.
        let xcode = Candidate(
            path: "\(home!)/Library/Caches/com.apple.dt.Xcode",
            name: "com.apple.dt.Xcode", rootID: "caches", kind: .cache,
            isDirectory: true, sizeBytes: 900_000_000, tier: .unknown)
        let xcodeOut = Classifier(rules: rules, inventory: AppInventory()).classify(xcode)
        XCTAssertEqual(xcodeOut.tier, .review)
        XCTAssertFalse(xcodeOut.hardProtected)
    }

    /// The reorder must not have moved delegation ahead of the explicit data
    /// protections, only ahead of the vendor-prefix heuristic.
    func testDelegationDoesNotOutrankExplicitProtections() {
        // A live process beats a delegated cleanup — this is why Playwright
        // reads PROTECTED while a browser is running from it.
        let running = Candidate(
            path: "\(home!)/Library/Caches/ms-playwright",
            name: "ms-playwright", rootID: "caches", kind: .cache, isDirectory: true,
            sizeBytes: 2_500_000_000,
            evidence: [Evidence(.runningProcess, "a browser is running", weight: 20)],
            tier: .unknown)
        let out = Classifier(rules: rules, inventory: AppInventory()).classify(running)
        XCTAssertEqual(out.tier, .protected)
        XCTAssertTrue(out.hardProtected)

        // A protected path beats it too.
        let onProtectedPath = Candidate(
            path: "\(home!)/Library/Application Support/MobileSync/pnpm",
            name: "pnpm", rootID: "app-support", kind: .state, isDirectory: true,
            sizeBytes: 5_000_000_000, tier: .unknown)
        let pathOut = Classifier(rules: rules, inventory: AppInventory()).classify(onProtectedPath)
        XCTAssertEqual(pathOut.tier, .protected)
        XCTAssertTrue(pathOut.hardProtected)
    }

    func testTheCarveOutListIsDeliberatelyTiny() throws {
        // It is the only list that can step around a tier-0 protection, so a
        // growing one should be a conscious decision rather than a drift.
        let shipped = try Rules.load(userPath: "/nonexistent")
        XCTAssertEqual(shipped.regenerableDespiteBundlePrefix, ["\\.ShipIt$"])
    }

    func testCarveOutEntriesAreAlsoTreatedAsRegenerable() {
        // One source of truth: an entry does not need repeating in
        // `regenerable_patterns` to make the name regenerable.
        XCTAssertNotNil(rules.isRegenerable(name: "com.example.App.ShipIt"))
        XCTAssertNotNil(rules.isRegenerableDespiteBundlePrefix(name: "com.example.App.ShipIt"))
        XCTAssertNil(rules.isRegenerableDespiteBundlePrefix(name: "DerivedData"))
    }
}
