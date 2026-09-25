import XCTest
@testable import BleachCore

/// The quarantine's *read* paths — `batches`, `restore`, `purge` — take their
/// input from `manifest.json` files on disk. A manifest is no more trustworthy
/// than a plan: it can be hand-edited, truncated, or restored from a backup of
/// another machine. These tests exist because `apply` used to validate
/// thoroughly while `restore` and `purge` validated nothing.
final class QuarantineIntegrityTests: XCTestCase {
    var home: String!
    var quarantine: Quarantine!

    override func setUpWithError() throws {
        home = NSTemporaryDirectory() + "bleach-qi-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        quarantine = Quarantine(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    @discardableResult
    private func writeBatch(dir: String, manifest: String) throws -> String {
        let path = "\(quarantine.root)/\(dir)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try manifest.write(toFile: path + "/manifest.json", atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - Batch IDs

    func testBatchIDValidationRejectsAnythingButOneComponent() {
        XCTAssertTrue(Quarantine.isValidBatchID("20250101-120000"))
        XCTAssertTrue(Quarantine.isValidBatchID("batch-1"))
        for bad in ["..", ".", "", "a/b", "../../etc", "a/../b", "manifest.json",
                    "with space", "semi;colon", "null\0byte"] {
            XCTAssertFalse(Quarantine.isValidBatchID(bad), "\"\(bad)\" must be refused")
        }
    }

    /// The directory name is authoritative. A manifest's own `id` field is
    /// data, and every path built later — purge target, restore source — comes
    /// from the validated directory name instead.
    func testBatchIDComesFromTheDirectoryNotTheManifest() throws {
        try writeBatch(dir: "20250101-000000", manifest: """
        {"id":"i-am-somewhere-else","createdAt":"2020-01-01T00:00:00Z","items":[]}
        """)
        XCTAssertEqual(quarantine.batches().map(\.id), ["20250101-000000"])
    }

    func testBatchesIgnoresDirectoriesThatAreNotValidBatchIDs() throws {
        try writeBatch(dir: "ok-1", manifest: #"{"id":"ok-1","createdAt":"2020-01-01T00:00:00Z","items":[]}"#)
        // A directory a user could plausibly create by hand in there.
        try writeBatch(dir: "my notes", manifest: #"{"id":"x","createdAt":"2020-01-01T00:00:00Z","items":[]}"#)
        XCTAssertEqual(quarantine.batches().map(\.id), ["ok-1"])
    }

    // MARK: - purge

    /// Regression: `purge` built its target as `root + "/" + batch.id` with a
    /// `hasPrefix(root)` guard. Since `id` came from the manifest, an id of
    /// `x/../../../../../PRECIOUS` passed the string check and had
    /// `removeItem` called on a path outside the quarantine — in the one code
    /// path the tool documents as irreversible.
    func testPurgeCannotEscapeTheQuarantineViaAManifestID() throws {
        let precious = "\(home!)/PRECIOUS"
        try FileManager.default.createDirectory(atPath: precious, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: precious + "/keep.txt",
                                       contents: Data("keep".utf8), attributes: nil)

        try writeBatch(dir: "evil", manifest: """
        {"id":"evil/../../../../../PRECIOUS","createdAt":"2020-01-01T00:00:00Z","items":[]}
        """)

        let purged = try quarantine.purge(olderThanDays: nil)
        XCTAssertEqual(purged.map(\.id), ["evil"], "only the real batch directory may be purged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious + "/keep.txt"),
                      "purge must never touch anything outside its own root")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(quarantine.root)/evil"))
    }

    // MARK: - restore

    /// Regression: `restore` used `item.originalPath` directly as a move
    /// destination with no validation at all, so a manifest could write
    /// anywhere the user could write.
    func testRestoreRefusesADestinationOutsideHome() throws {
        let escape = NSTemporaryDirectory() + "bleach-qi-escape-\(UUID().uuidString)/planted"
        defer { try? FileManager.default.removeItem(
            atPath: (escape as NSString).deletingLastPathComponent) }

        let dir = try writeBatch(dir: "b1", manifest: """
        {"id":"b1","createdAt":"2020-01-01T00:00:00Z","items":[
          {"originalPath":"\(escape)","storedName":"payload","sizeBytes":3,
           "tier":"cacheSafe","reasons":[]}
        ]}
        """)
        FileManager.default.createFile(atPath: dir + "/payload",
                                       contents: Data("pwn".utf8), attributes: nil)

        let (restored, skipped) = try quarantine.restore(batchID: "b1")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertTrue(skipped[0].reason.contains("refusing to restore there"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: escape),
                       "nothing may be written outside the home directory")
    }

    func testRestoreRefusesATraversingStoredName() throws {
        let target = "\(home!)/landing"
        try writeBatch(dir: "b2", manifest: """
        {"id":"b2","createdAt":"2020-01-01T00:00:00Z","items":[
          {"originalPath":"\(target)","storedName":"../../../../../../etc/hosts",
           "sizeBytes":3,"tier":"cacheSafe","reasons":[]}
        ]}
        """)
        let (restored, skipped) = try quarantine.restore(batchID: "b2")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertTrue(skipped[0].reason.contains("unsafe stored name"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testRestoreRefusesToReadTheManifestItself() throws {
        try writeBatch(dir: "b3", manifest: """
        {"id":"b3","createdAt":"2020-01-01T00:00:00Z","items":[
          {"originalPath":"\(home!)/stolen.json","storedName":"manifest.json",
           "sizeBytes":3,"tier":"cacheSafe","reasons":[]}
        ]}
        """)
        let (restored, skipped) = try quarantine.restore(batchID: "b3")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(skipped.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(home!)/stolen.json"))
    }

    func testRestoreRefusesHomeItself() throws {
        try writeBatch(dir: "b4", manifest: """
        {"id":"b4","createdAt":"2020-01-01T00:00:00Z","items":[
          {"originalPath":"\(home!)","storedName":"payload","sizeBytes":3,
           "tier":"cacheSafe","reasons":[]}
        ]}
        """)
        let (restored, skipped) = try quarantine.restore(batchID: "b4")
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(skipped.first?.reason.contains("is your home directory"), true)
    }

    func testRestoreRejectsAnUnsafeBatchID() {
        XCTAssertThrowsError(try quarantine.restore(batchID: "../../../etc"))
    }

    // MARK: - apply

    /// `~/manifest.json` flattens to exactly `manifest.json`, which the batch
    /// manifest then overwrote: the user's file was lost and the batch record
    /// was corrupted.
    func testAPathFlatteningToTheManifestNameIsStoredElsewhere() throws {
        let victim = "\(home!)/manifest.json"
        try "precious".write(toFile: victim, atomically: true, encoding: .utf8)
        XCTAssertEqual(quarantine.storedName(for: victim), "manifest.json")

        let entry = RemovalPlan.Entry(
            path: victim,
            sizeBytes: DirectoryWalker.stats(of: victim, collectUserData: false).sizeBytes,
            tier: .cacheSafe, ownerLabel: nil, newestMTime: nil, reasons: [])
        let (batch, skipped, journalError) = try quarantine.apply(
            RemovalPlan(home: home, entries: [entry]), batchID: "b5", validate: { _ in nil })

        XCTAssertTrue(skipped.isEmpty)
        XCTAssertNil(journalError)
        XCTAssertEqual(batch.items.count, 1)
        XCTAssertNotEqual(batch.items[0].storedName, "manifest.json")

        // The manifest still parses, and the payload still round-trips.
        XCTAssertEqual(quarantine.batches().map(\.id), ["b5"])
        let (restored, _) = try quarantine.restore(batchID: "b5")
        XCTAssertEqual(restored, [victim])
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "precious")
    }

    func testApplyRejectsAnUnsafeBatchID() {
        XCTAssertThrowsError(try quarantine.apply(
            RemovalPlan(home: home, entries: []), batchID: "../escape", validate: { _ in nil }))
    }

    /// A batch is discoverable even if the process dies after the first move:
    /// a skeleton manifest is written before anything is renamed.
    func testASkeletonManifestExistsBeforeTheFirstMove() throws {
        var seenDuringMove: [String] = []
        let victim = "\(home!)/junk"
        try FileManager.default.createDirectory(atPath: victim, withIntermediateDirectories: true)
        let entry = RemovalPlan.Entry(path: victim, sizeBytes: 0, tier: .cacheSafe,
                                      ownerLabel: nil, newestMTime: nil, reasons: [])
        _ = try quarantine.apply(
            RemovalPlan(home: home, entries: [entry]), batchID: "b6",
            validate: { _ in
                seenDuringMove = self.quarantine.batches().map(\.id)
                return nil
            })
        XCTAssertEqual(seenDuringMove, ["b6"],
                       "the batch must be listable before its first rename")
    }

    // MARK: - journal

    func testJournalAppendsRatherThanTruncating() throws {
        for i in 1...3 {
            let error = quarantine.appendJournal(
                Quarantine.Batch(id: "b\(i)", createdAt: Date(), items: []))
            XCTAssertNil(error)
        }
        let text = try String(contentsOfFile: quarantine.journalPath, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
        for i in 1...3 { XCTAssertTrue(text.contains("\"b\(i)\"")) }
    }

    func testJournalFailureIsReportedNotThrown() {
        // An unwritable journal location: a *file* where the parent dir goes.
        let blocked = Quarantine(home: "\(home!)/blocked")
        FileManager.default.createFile(atPath: "\(home!)/blocked",
                                       contents: Data(), attributes: nil)
        let error = blocked.appendJournal(
            Quarantine.Batch(id: "b1", createdAt: Date(), items: []))
        XCTAssertNotNil(error, "a journal failure must be reported, not swallowed")
    }
}
