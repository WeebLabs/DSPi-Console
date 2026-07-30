import XCTest
@testable import DSPi_Console

/// Covers channel level matching.
///
/// Every rule here is a decision the user lives with: which channel becomes the
/// reference, which are quietly trimmed and which they are asked to go and fix
/// by hand, and what a subwoofer does instead of any of that.
///
/// See `Documentation/room_correction_level_calibration.md`.
final class ChannelLevelMatchTests: XCTestCase {

    private func level(_ speaker: Int, _ db: Double,
                       role: RoomCorrectionCore.SpeakerRole = .fullRange) -> ChannelLevel {
        ChannelLevel(speakerIndex: speaker,
                     levelDb: db,
                     role: role,
                     bandHz: role == .subwoofer
                        ? 20...80
                        : ChannelLevelMatch.fullRangeBand)
    }

    private func match(_ levels: [ChannelLevel],
                       hasCalibration: Bool = true) -> ChannelLevelMatch {
        ChannelLevelMatch(levels: levels, hasCalibration: hasCalibration)
    }

    // MARK: - Matching downward

    func testChannelsAreMatchedDownToTheQuietest() {
        // Every channel has already spent headroom on its correction, so asking
        // for gain on top risks exceeding what is available. Attenuation always
        // succeeds.
        let result = match([level(0, 72), level(1, 70), level(2, 71)])

        XCTAssertEqual(result.datumDb, 70, accuracy: 1e-9)
        XCTAssertEqual(result.offset(for: 0), -2, accuracy: 1e-9)
        XCTAssertEqual(result.offset(for: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(result.offset(for: 2), -1, accuracy: 1e-9)
    }

    func testNoOffsetIsEverPositive() {
        for db in [Double(60), 65, 70, 75, 80] {
            let result = match([level(0, db), level(1, 70), level(2, 71)])
            for offset in result.offsets {
                XCTAssertLessThanOrEqual(offset.offsetDb, 0,
                                         "matching must never ask for gain (\\(db) dB case)")
            }
        }
    }

    func testAlreadyMatchedChannelsAreLeftAlone() {
        let result = match([level(0, 70), level(1, 70), level(2, 70)])
        XCTAssertTrue(result.offsets.allSatisfy { $0.offsetDb == 0 })
        XCTAssertEqual(result.outputLostDb, 0, accuracy: 1e-9)
        XCTAssertTrue(result.isReady)
    }

    func testTheOutputGivenUpIsReported() {
        // A user with one quiet channel should learn why the system got
        // quieter rather than wondering.
        let result = match([level(0, 74), level(1, 72), level(2, 73)])
        XCTAssertEqual(result.outputLostDb, 1, accuracy: 1e-9,
                       "median 73, matched down to 72")
    }

    // MARK: - The datum

    func testTheDatumIsTheMedianRatherThanTheMean() {
        // One badly set channel must not drag the reference it is being judged
        // against, or it hides its own error.
        let result = match([level(0, 70), level(1, 70), level(2, 70), level(3, 40)])
        // The outlier is excluded, so the three sane channels still match.
        XCTAssertEqual(result.datumDb, 70, accuracy: 1e-9)
        XCTAssertEqual(result.offset(for: 3), 0,
                       "the outlier is not trimmed; it is sent for a gain change")
    }

    // MARK: - Out of range

    func testAChannelFarFromTheDatumIsSentForAPhysicalGainChange() {
        let result = match([level(0, 70), level(1, 70), level(2, 63.7)])

        XCTAssertFalse(result.isReady)
        XCTAssertEqual(result.outOfRange.map(\.speakerIndex), [2])
        XCTAssertTrue(result.offsets.first { $0.speakerIndex == 2 }?
                        .needsPhysicalGainChange ?? false)
    }

    func testAnOutOfRangeChannelDoesNotDragTheOthersDown() {
        // The whole point of asking the user to fix it: absorbing it digitally
        // would attenuate every other channel by the same amount, which is the
        // outcome they are being asked to prevent.
        let result = match([level(0, 70), level(1, 70), level(2, 58)])

        XCTAssertEqual(result.datumDb, 70, accuracy: 1e-9)
        XCTAssertEqual(result.offset(for: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(result.offset(for: 1), 0, accuracy: 1e-9)
    }

    func testTheWindowBoundaryIsInclusive() {
        let inside = match([level(0, 70), level(1, 70), level(2, 67)])
        XCTAssertTrue(inside.isReady, "exactly 3 dB out is still workable")

        let outside = match([level(0, 70), level(1, 70), level(2, 66.9)])
        XCTAssertFalse(outside.isReady)
    }

    func testGuidanceStatesTheCostOfIgnoringIt() {
        let result = match([level(0, 70), level(1, 70), level(2, 63.7)])
        let offset = result.offsets.first { $0.speakerIndex == 2 }
        let text = offset?.guidance(name: "Centre") ?? ""

        XCTAssertTrue(text.contains("6.3 dB below"), text)
        XCTAssertTrue(text.contains("Raise its gain control"), text)
        XCTAssertTrue(text.contains("attenuated by 6.3 dB"),
                      "the cost of ignoring it is the point: \\(text)")
    }

    func testAChannelThatIsTooLoudIsAlsoFlagged() {
        let result = match([level(0, 70), level(1, 70), level(2, 78)])
        let text = result.offsets.first { $0.speakerIndex == 2 }?
            .guidance(name: "Surround") ?? ""
        XCTAssertTrue(text.contains("above"), text)
        XCTAssertTrue(text.contains("Lower its gain control"), text)
    }

    func testAChannelInsideTheWindowHasNoGuidance() {
        let result = match([level(0, 70), level(1, 68)])
        XCTAssertNil(result.offsets.first { $0.speakerIndex == 1 }?
                        .guidance(name: "Right"))
    }

    // MARK: - The subwoofer

    func testASubwooferIsNeverTrimmedByMatching() {
        // It sits on its own datum, with its level inherited from whatever the
        // user set. Matching it in the full-range band is not possible and
        // matching the mains to it would be absurd.
        let result = match([level(0, 70), level(1, 70),
                            level(8, 64, role: .subwoofer)])

        XCTAssertEqual(result.offset(for: 8), 0, accuracy: 1e-9)
        XCTAssertTrue(result.offsets.first { $0.speakerIndex == 8 }?
                        .isSubwoofer ?? false)
    }

    func testAQuietSubwooferDoesNotAttenuateEveryOtherChannel() {
        // The failure this rule exists to prevent: trading a correct system for
        // a quiet one to satisfy an arithmetic rule.
        let result = match([level(0, 70), level(1, 70), level(2, 70),
                            level(8, 55, role: .subwoofer)])

        XCTAssertEqual(result.datumDb, 70, accuracy: 1e-9)
        XCTAssertEqual(result.outputLostDb, 0, accuracy: 1e-9)
        for speaker in [0, 1, 2] {
            XCTAssertEqual(result.offset(for: speaker), 0, accuracy: 1e-9)
        }
    }

    func testASubwooferIsNotAllowedToBecomeTheDatum() {
        // Even a single full-range channel outranks it, because they are not
        // comparable quantities to match against each other.
        let result = match([level(0, 70), level(8, 40, role: .subwoofer)])
        XCTAssertEqual(result.datumDb, 70, accuracy: 1e-9)
    }

    func testAnOutOfRangeSubwooferIsOfferedADifferentChoice() {
        // It never drags the others down, so the instruction offers continuing
        // knowingly rather than only a gain change.
        let result = match([level(0, 70), level(1, 70),
                            level(8, 63.7, role: .subwoofer)])
        let text = result.offsets.first { $0.speakerIndex == 8 }?
            .guidance(name: "Subwoofer") ?? ""

        XCTAssertTrue(text.contains("6.3 dB below"), text)
        XCTAssertTrue(text.contains("left uncalibrated"),
                      "continuing knowingly is a supported outcome: \\(text)")
        XCTAssertFalse(text.contains("every other channel"),
                       "nothing else is attenuated to meet a subwoofer: \\(text)")
    }

    // MARK: - Calibration

    func testASubwooferWithoutACalibrationFileIsFlagged() {
        // The chain gain is flat and cancels in any comparison; the microphone's
        // magnitude response does not, and only cancels within one band.
        // Comparing a subwoofer against the midband channels crosses bands.
        let withCal = match([level(0, 70), level(8, 68, role: .subwoofer)],
                            hasCalibration: true)
        XCTAssertFalse(withCal.subwooferAccuracyReduced)

        let without = match([level(0, 70), level(8, 68, role: .subwoofer)],
                            hasCalibration: false)
        XCTAssertTrue(without.subwooferAccuracyReduced)
    }

    func testWithoutASubwooferTheCalibrationFileDoesNotMatter() {
        // Full-range channels are compared within one band, where the
        // microphone's response cancels.
        let result = match([level(0, 70), level(1, 68)], hasCalibration: false)
        XCTAssertFalse(result.subwooferAccuracyReduced)
    }

    // MARK: - Degenerate input

    func testASingleChannelNeedsNoMatching() {
        let result = match([level(0, 70)])
        XCTAssertEqual(result.offset(for: 0), 0, accuracy: 1e-9)
        XCTAssertTrue(result.isReady)
    }

    func testNoChannelsAtAllIsHarmless() {
        let result = match([])
        XCTAssertTrue(result.offsets.isEmpty)
        XCTAssertTrue(result.isReady)
        XCTAssertEqual(result.outputLostDb, 0, accuracy: 1e-9)
    }

    func testASubwooferOnItsOwnDoesNotProduceANonsenseDatum() {
        let result = match([level(8, 65, role: .subwoofer)])
        XCTAssertEqual(result.offset(for: 8), 0, accuracy: 1e-9)
    }
}
