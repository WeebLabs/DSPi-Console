import XCTest
@testable import DSPi_Console

/// A channel whose audio stream has stopped keeps reporting its last levels
/// with an ever-growing age.  Past the threshold it must read as silence.
final class RtaStaleFrameTests: XCTestCase {
    private func frame(channel: UInt8, ageMs: UInt16, level: UInt8 = 200) -> RtaBandFrame {
        var f = RtaBandFrame()
        f.channel = channel
        f.nBands = 3
        f.ageMs = ageMs
        f.avg = Array(repeating: level, count: RTA_MAX_BANDS)
        f.peak = Array(repeating: level, count: RTA_MAX_BANDS)
        return f
    }

    func testOldFrameIsSilencedAndReported() {
        let result = RtaEngine.silencingStale([0: frame(channel: 0, ageMs: 900)], staleAfterMs: 500)
        XCTAssertEqual(result.stale, [0])
        let silent = try! XCTUnwrap(result.frames[0])
        XCTAssertTrue(silent.avg.allSatisfy { $0 == 0 })
        XCTAssertTrue(silent.peak.allSatisfy { $0 == 0 })
        // Still a published frame, so the views glide down rather than blank.
        XCTAssertTrue(silent.hasData)
        XCTAssertEqual(silent.nBands, 3)
    }

    func testFreshAndUnpublishedFramesAreUntouched() {
        let frames: [UInt8: RtaBandFrame] = [
            1: frame(channel: 1, ageMs: 40),
            2: frame(channel: 2, ageMs: 0xFFFF),   // never published
            3: frame(channel: 3, ageMs: 500),      // exactly at the threshold
        ]
        let result = RtaEngine.silencingStale(frames, staleAfterMs: 500)
        XCTAssertTrue(result.stale.isEmpty)
        XCTAssertEqual(result.frames, frames)
    }
}
