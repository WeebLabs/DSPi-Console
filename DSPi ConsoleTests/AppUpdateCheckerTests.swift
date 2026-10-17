import XCTest
@testable import DSPi_Console

/// Which GitHub release the update check offers.  Betas are told apart by tag
/// alone, since the releases are not flagged as pre-releases.
final class AppUpdateCheckerTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false) -> AppUpdateChecker.Release {
        AppUpdateChecker.Release(tagName: tag,
                                 htmlURL: URL(string: "https://github.com/WeebLabs/DSPi-Console/releases/tag/\(tag)")!,
                                 draft: draft)
    }

    private func offered(_ tags: [String], over current: String) -> String? {
        AppUpdateChecker.newestUpdate(in: tags.map { release($0) },
                                      over: FirmwareVersion(current)!)?.tagName
    }

    func testFinalUserIsNotOfferedBetas() {
        XCTAssertNil(offered(["v1.1.6-beta4", "v1.1.5"], over: "1.1.5"))
        XCTAssertEqual(offered(["v1.1.7-beta1", "v1.1.6", "v1.1.5"], over: "1.1.5"), "v1.1.6")
    }

    func testBetaUserIsOfferedNewerBetasAndTheFinal() {
        XCTAssertEqual(offered(["v1.1.6-beta4", "v1.1.6-beta3"], over: "1.1.6-beta3"), "v1.1.6-beta4")
        XCTAssertEqual(offered(["v1.1.6", "v1.1.6-beta4"], over: "1.1.6-beta4"), "v1.1.6")
    }

    func testNothingNewerOffersNothing() {
        XCTAssertNil(offered(["v1.1.6-beta4", "v1.1.6-beta3", "v1.1.5"], over: "1.1.6-beta4"))
        XCTAssertNil(offered([], over: "1.1.6"))
    }

    func testDoubleDigitBetaSortsAboveSingleDigit() {
        XCTAssertEqual(offered(["v1.1.6-beta9", "v1.1.6-beta10"], over: "1.1.6-beta2"), "v1.1.6-beta10")
    }

    func testDraftsAndUnparseableTagsAreIgnored() {
        let releases = [release("v1.1.7", draft: true), release("nightly"), release("v1.1.6")]
        XCTAssertEqual(AppUpdateChecker.newestUpdate(in: releases, over: FirmwareVersion(1, 1, 5))?.tagName, "v1.1.6")
    }

    func testDecodesGitHubReleaseJSON() throws {
        let json = #"[{"tag_name":"v1.1.6-beta4","html_url":"https://github.com/WeebLabs/DSPi-Console/releases/tag/v1.1.6-beta4","draft":false,"prerelease":false,"assets":[{"name":"DSPi.Console.v1.1.6-beta4.zip","size":1,"browser_download_url":"https://github.com/WeebLabs/DSPi-Console/releases/download/v1.1.6-beta4/DSPi.Console.v1.1.6-beta4.zip"}]}]"#
        let decoded = try JSONDecoder().decode([AppUpdateChecker.Release].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.version, FirmwareVersion(1, 1, 6, 4))
        XCTAssertEqual(decoded.first?.assets.first?.name, "DSPi.Console.v1.1.6-beta4.zip")
        XCTAssertEqual(decoded.first?.assets.first?.url.lastPathComponent, "DSPi.Console.v1.1.6-beta4.zip")
    }
}
