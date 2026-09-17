import XCTest
@testable import BleachCore

final class LaunchServicesDumpTests: XCTestCase {
    /// Trimmed from real `lsregister -dump` output, including the trailing
    /// hex handles and the indented infoDictionary block that must be ignored.
    let sample = """
    --------------------------------------------------------------------------------
    bundle id:                  Raycast (0x814)
    path:                       /Applications/Raycast.app (0x1884)
    name:                       Raycast
    teamID:                     SY64MV22J9
    identifier:                 com.raycast.macos
    executable:                 Contents/MacOS/Raycast
    infoDictionary:             39 values (20676 (0x50c4))
                                {
                                    CFBundleIdentifier = "com.raycast.macos";
                                    identifier = "should.be.ignored";
                                }
    --------------------------------------------------------------------------------
    bundle id:                  NotAnApp (0x900)
    path:                       /System/Library/CoreServices/Thing.bundle (0x1900)
    identifier:                 com.apple.thing
    --------------------------------------------------------------------------------
    bundle id:                  NoIdentifier (0x901)
    path:                       /Applications/Mystery.app (0x1901)
    --------------------------------------------------------------------------------
    """

    func testParsesAppRecords() {
        let records = LaunchServicesDump.parse(sample)
        // Only the `.app` with an identifier qualifies.
        XCTAssertEqual(records.count, 1)
        let r = records[0]
        XCTAssertEqual(r.bundleID, "com.raycast.macos")
        XCTAssertEqual(r.path, "/Applications/Raycast.app")
        XCTAssertEqual(r.teamID, "SY64MV22J9")
        XCTAssertEqual(r.executable, "Raycast")
        XCTAssertEqual(r.sources, [.launchServices])
    }

    func testIndentedDictionaryKeysAreIgnored() {
        let records = LaunchServicesDump.parse(sample)
        // The nested `identifier = "should.be.ignored"` must not win.
        XCTAssertEqual(records.first?.bundleID, "com.raycast.macos")
    }

    func testNonAppBundlesAreSkipped() {
        let records = LaunchServicesDump.parse(sample)
        XCTAssertFalse(records.contains { $0.bundleID == "com.apple.thing" })
    }
}
