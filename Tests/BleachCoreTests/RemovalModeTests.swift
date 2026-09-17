import XCTest
@testable import BleachCore

/// The destructive modes must be exactly as well guarded as the reversible
/// one. These tests exist to stop `delete` from ever becoming the fast path
/// that skips validation.
final class RemovalModeTests: XCTestCase {
    var home: String!
    var rules: Rules.Compiled!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "bleach-modes-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        rules = try Rules.load(userPath: "/nonexistent").compiled()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func makeDir(_ relative: String, bytes: Int = 4096) throws -> String {
        let path = "\(home!)/\(relative)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path + "/file.bin",
                                      contents: Data(count: bytes), attributes: nil)
        return path
    }

    /// Sizes are *measured*, not asserted: the validator compares the plan's
    /// figure against allocated size on disk, and APFS rounds a 2 KB file up
    /// to a 4 KB block. Hardcoding a size here would trip the drift check for
    /// reasons that have nothing to do with what the test is checking.
    private func entry(_ path: String, tier: Tier = .cacheSafe, size: Int64? = nil) -> RemovalPlan.Entry {
        let measured = size ?? DirectoryWalker.stats(of: path, collectUserData: false).sizeBytes
        return RemovalPlan.Entry(path: path, sizeBytes: measured, tier: tier,
                                 ownerLabel: nil, newestMTime: nil, reasons: [])
    }

    private func validator() -> ApplyValidator {
        ApplyValidator(home: home, rules: rules, inventory: AppInventory())
    }

    // MARK: - delete honours every refusal

    func testDeleteModeStillRefusesProtectedNames() throws {
        let victim = try makeDir(".ssh")
        let plan = RemovalPlan(home: home, entries: [entry(victim)])
        let v = validator()
        let report = try Remover(home: home).run(
            plan, mode: .delete, batchID: "test",
            validate: { v.reasonToRefuse($0) })

        XCTAssertEqual(report.removed.count, 0)
        XCTAssertEqual(report.skipped.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim),
                      "a protected path must survive delete mode")
    }

    func testDeleteModeStillRefusesPathsOutsideHome() throws {
        let plan = RemovalPlan(home: home, entries: [entry("/etc/hosts", size: 100)])
        let v = validator()
        let report = try Remover(home: home).run(
            plan, mode: .delete, batchID: "test",
            validate: { v.reasonToRefuse($0) })

        XCTAssertEqual(report.removed.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    func testDeleteModeStillRefusesSymlinks() throws {
        let real = try makeDir("real")
        let link = "\(home!)/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let plan = RemovalPlan(home: home, entries: [entry(link)])
        let v = validator()
        let report = try Remover(home: home).run(
            plan, mode: .delete, batchID: "test",
            validate: { v.reasonToRefuse($0) })

        XCTAssertEqual(report.removed.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real),
                      "the symlink target must be untouched")
    }

    func testDeleteModeRemovesAPermittedPath() throws {
        let victim = try makeDir("junk-cache")
        let plan = RemovalPlan(home: home, entries: [entry(victim)])
        let v = validator()
        let report = try Remover(home: home).run(
            plan, mode: .delete, batchID: "test",
            validate: { v.reasonToRefuse($0) })

        XCTAssertEqual(report.removed.count, 1)
        XCTAssertFalse(report.restorable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim))
    }

    // MARK: - Mode metadata

    func testOnlyDeleteIsIrreversible() {
        XCTAssertTrue(RemovalMode.quarantine.isReversible)
        XCTAssertTrue(RemovalMode.trash.isReversible)
        XCTAssertFalse(RemovalMode.delete.isReversible)
    }

    func testQuarantineIsTheDefaultOrdering() {
        // The TUI's mode cycle starts at the first case, so quarantine being
        // first is load-bearing, not cosmetic.
        XCTAssertEqual(RemovalMode.allCases.first, .quarantine)
        XCTAssertEqual(RemovalMode.allCases.last, .delete)
    }

    // MARK: - Quarantine round trip and purge

    func testQuarantineRoundTripRestoresContent() throws {
        let victim = try makeDir("restore-me", bytes: 2048)
        let plan = RemovalPlan(home: home, entries: [entry(victim)])
        let v = validator()
        let report = try Remover(home: home).run(
            plan, mode: .quarantine, batchID: "batch-1",
            validate: { v.reasonToRefuse($0) })

        XCTAssertEqual(report.removed.count, 1)
        XCTAssertTrue(report.restorable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim))

        let (restored, skipped) = try Quarantine(home: home).restore(batchID: "batch-1")
        XCTAssertEqual(restored, [victim])
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim + "/file.bin"))
    }

    func testPurgeAllRemovesEveryBatchRegardlessOfAge() throws {
        let quarantine = Quarantine(home: home)
        let v = validator()
        for i in 1...3 {
            let victim = try makeDir("junk-\(i)")
            _ = try Remover(home: home).run(
                RemovalPlan(home: home, entries: [entry(victim)]),
                mode: .quarantine, batchID: "batch-\(i)",
                validate: { v.reasonToRefuse($0) })
        }
        XCTAssertEqual(quarantine.batches().count, 3)

        // Age-based purge spares them: they were all created just now.
        XCTAssertEqual(try quarantine.purge(olderThanDays: 30).count, 0)
        XCTAssertEqual(quarantine.batches().count, 3)

        // nil means "everything".
        XCTAssertEqual(try quarantine.purge(olderThanDays: nil).count, 3)
        XCTAssertEqual(quarantine.batches().count, 0)
    }

    func testRestoreWillNotClobberARecreatedDirectory() throws {
        let victim = try makeDir("recreated")
        let v = validator()
        _ = try Remover(home: home).run(
            RemovalPlan(home: home, entries: [entry(victim)]),
            mode: .quarantine, batchID: "batch-x",
            validate: { v.reasonToRefuse($0) })

        // The app rebuilt its directory after the removal.
        _ = try makeDir("recreated")

        let (restored, skipped) = try Quarantine(home: home).restore(batchID: "batch-x")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertEqual(skipped.first?.reason, "destination already exists")
    }
}
