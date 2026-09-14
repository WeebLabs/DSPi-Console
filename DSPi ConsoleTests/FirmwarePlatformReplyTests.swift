import XCTest
@testable import DSPi_Console

/// REQ_GET_PLATFORM decoding.  The early 1.1.6 betas answer with the legacy
/// 4-byte reply, which carries no beta ordinal, so they must not be taken for
/// a final 1.1.6.
final class FirmwarePlatformReplyTests: XCTestCase {
    /// platform, major, (minor << 4 | patch), outputs, then optional
    /// full-width minor, patch and beta.
    private func reply(_ major: UInt8, _ minor: UInt8, _ patch: UInt8,
                       beta: UInt8? = nil, length: Int) -> [UInt8] {
        let full: [UInt8] = [1, major, (minor << 4) | patch, 9, minor, patch, beta ?? 0]
        return Array(full.prefix(length))
    }

    func testFullReplyCarriesTheOrdinal() {
        let decoded = FirmwareVersion.fromPlatformReply(reply(1, 1, 6, beta: 3, length: 7))
        XCTAssertEqual(decoded?.platform, 1)
        XCTAssertEqual(decoded?.version, FirmwareVersion(1, 1, 6, 3))
        XCTAssertEqual(FirmwareVersion.fromPlatformReply(reply(1, 1, 6, beta: 0, length: 7))?.version,
                       FirmwareVersion(1, 1, 6))
    }

    func testShortReplyAt116IsAnEarlyBetaNotAFinal() {
        let version = FirmwareVersion.fromPlatformReply(reply(1, 1, 6, length: 4))?.version
        XCTAssertEqual(version?.beta, FirmwareVersion.earlyBeta)
        XCTAssertNotEqual(version, FirmwareVersion(1, 1, 6))
    }

    func testShortReplyBelow116IsStillAFinal() {
        XCTAssertEqual(FirmwareVersion.fromPlatformReply(reply(1, 1, 5, length: 4))?.version,
                       FirmwareVersion(1, 1, 5))
        XCTAssertEqual(FirmwareVersion.fromPlatformReply(reply(1, 0, 9, length: 6))?.version,
                       FirmwareVersion(1, 0, 9))
    }

    func testTooShortReplyIsRejected() {
        XCTAssertNil(FirmwareVersion.fromPlatformReply([1, 1, 0x16]))
    }

    func testEarlyBetaSortsBelowEveryNumberedBetaAndTheFinal() {
        let early = FirmwareVersion(1, 1, 6, FirmwareVersion.earlyBeta)
        XCTAssertLessThan(early, FirmwareVersion(1, 1, 6, 1))
        XCTAssertLessThan(early, FirmwareVersion(1, 1, 6, 2))
        XCTAssertLessThan(early, FirmwareVersion(1, 1, 6))
        XCTAssertGreaterThan(early, FirmwareVersion(1, 1, 5))
    }

    func testEarlyBetaDescriptionAndTag() {
        let early = FirmwareVersion(1, 1, 6, FirmwareVersion.earlyBeta)
        XCTAssertEqual(early.description, "1.1.6 early beta")
        XCTAssertNil(early.tagSuffix)
        XCTAssertEqual(FirmwareVersion(1, 1, 6, 2).tagSuffix, "1.1.6-beta2")
    }
}
