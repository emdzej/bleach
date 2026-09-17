import XCTest
@testable import BleachCore

final class NormalizerTests: XCTestCase {
    func testCanonicalStripsPunctuationAndCase() {
        XCTAssertEqual(Normalizer.canonical("Code - Insiders"), "codeinsiders")
        XCTAssertEqual(Normalizer.canonical("Sublime Text 3"), "sublimetext3")
        XCTAssertEqual(Normalizer.canonical("com.raycast.macos"), "comraycastmacos")
    }

    func testVersionStrippedCollapsesSiblings() {
        // The property that makes version-retention work: two versions of the
        // same product must reduce to the same stem.
        XCTAssertEqual(
            Normalizer.versionStripped("IntelliJIdea2025.3"),
            Normalizer.versionStripped("IntelliJIdea2026.2"))
        XCTAssertEqual(Normalizer.versionStripped("BambuStudioBeta"), "bambustudio")
    }

    func testBundleIDDetectionRejectsVersionedNames() {
        XCTAssertTrue(Normalizer.looksLikeBundleID("com.raycast.macos"))
        XCTAssertTrue(Normalizer.looksLikeBundleID("app.freelens.Freelens"))
        // Would otherwise be read as a bundle ID because it contains a dot.
        XCTAssertFalse(Normalizer.looksLikeBundleID("IntelliJIdea2025.3"))
        XCTAssertFalse(Normalizer.looksLikeBundleID("Sublime Text"))
        XCTAssertFalse(Normalizer.looksLikeBundleID("com.foo"))
    }

    func testTeamPrefixSplit() {
        let split = Normalizer.splitTeamPrefix("2BUA8C4S2C.com.1password.browser-helper")
        XCTAssertEqual(split?.teamID, "2BUA8C4S2C")
        XCTAssertEqual(split?.rest, "com.1password.browser-helper")
        // Not a team ID: wrong length.
        XCTAssertNil(Normalizer.splitTeamPrefix("com.foo.bar"))
    }

    func testShortStemsDoNotMatch() {
        // Regression: ".m2" reduced to "m" and resolved to a Homebrew formula
        // called "m4". The resolver now requires a 4-character stem.
        XCTAssertTrue(Normalizer.versionStripped(".m2").count < 4)
    }
}
