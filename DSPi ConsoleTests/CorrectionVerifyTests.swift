import XCTest
@testable import DSPi_Console

/// Covers what a verification result means.
///
/// The sweep itself is the measurement path, already covered elsewhere. What is
/// specific here is the judgement: whether the measured response agreeing with
/// the prediction is decided on shape rather than level, and whether a channel
/// that cannot honestly be compared says so instead of failing.
final class CorrectionVerifyTests: XCTestCase {

    private func result(worst: Double, rms: Double,
                        crossoverBypassed: Bool = false) -> VerificationResult {
        VerificationResult(speakerIndex: 0,
                           measuredDb: [], predictedDb: [], targetDb: [],
                           worstDeviationDb: worst,
                           rmsDeviationDb: rms,
                           crossoverWasBypassed: crossoverBypassed,
                           bandLevelDb: 70,
                           role: .fullRange)
    }

    private func levelled(_ speaker: Int, _ bandLevel: Double,
                          role: RoomCorrectionCore.SpeakerRole = .fullRange,
                          crossoverBypassed: Bool = false) -> VerificationResult {
        VerificationResult(speakerIndex: speaker,
                           measuredDb: [], predictedDb: [], targetDb: [],
                           worstDeviationDb: 0,
                           rmsDeviationDb: 0.5,
                           crossoverWasBypassed: crossoverBypassed,
                           bandLevelDb: bandLevel,
                           role: role)
    }

    func testACloseMatchAgreesWithThePrediction() {
        let value = result(worst: 2.5, rms: 0.9)
        XCTAssertTrue(value.agreesWithPrediction)
        XCTAssertTrue(value.summary.contains("matches"), value.summary)
        XCTAssertTrue(value.summary.contains("0.9"), value.summary)
    }

    func testALargeDisagreementPointsAtThePathRatherThanTheCorrection() {
        // A verification failure almost never means the filters are wrong. It
        // means the sweep did not go where it was supposed to, so the advice
        // has to send the user to the routing rather than back to the target.
        let value = result(worst: 12, rms: 6)
        XCTAssertFalse(value.agreesWithPrediction)
        XCTAssertTrue(value.summary.contains("routing"), value.summary)
    }

    func testTheThresholdIsOnTheRmsRatherThanTheWorstBin() {
        // One bin missing by a lot is a null moving a few centimetres. Judging
        // on the worst bin would fail almost every honest verification.
        let value = result(worst: 9, rms: 1.2)
        XCTAssertTrue(value.agreesWithPrediction,
                      "a single bad bin must not fail an otherwise good match")
    }

    func testABypassedCrossoverIsExplainedRatherThanFailed() {
        // Verification measures the real configuration with the crossover back
        // on, so it cannot match a prediction made without it. Reporting that
        // as a failure would blame the user for a choice the app offered them.
        let value = result(worst: 14, rms: 8, crossoverBypassed: true)
        XCTAssertTrue(value.summary.contains("crossover"), value.summary)
        XCTAssertFalse(value.summary.contains("routing"),
                       "it must not send the user chasing a routing problem")
    }

    func testTheBoundaryIsInclusive() {
        XCTAssertTrue(result(worst: 5, rms: 3.0).agreesWithPrediction)
        XCTAssertFalse(result(worst: 5, rms: 3.01).agreesWithPrediction)
    }

    // MARK: - Cross-channel level agreement

    func testChannelsWithinToleranceAgree() {
        let agreement = LevelAgreement(results: [levelled(0, 70.0),
                                                levelled(1, 70.3),
                                                levelled(2, 69.8)])
        XCTAssertTrue(agreement.passes)
        XCTAssertLessThanOrEqual(agreement.worstDeviationDb, 0.5)
        XCTAssertTrue(agreement.summary.contains("within"), agreement.summary)
    }

    func testASmallResidualIsRetryableOnce() {
        let agreement = LevelAgreement(results: [levelled(0, 70.0),
                                                levelled(1, 71.2),
                                                levelled(2, 70.0)])
        XCTAssertFalse(agreement.passes)
        XCTAssertTrue(agreement.isRetryable)
        // The offset closes the gap, so it has the opposite sign to the error.
        XCTAssertEqual(agreement.residualOffsets[1] ?? 0, -1.2, accuracy: 0.001)
        XCTAssertEqual(agreement.residualOffsets[0] ?? 99, 0, accuracy: 0.001)
    }

    func testALargeDisagreementIsNotRetried() {
        // Beyond a couple of decibels something physical changed, and applying
        // a residual would chase noise rather than converge.
        let agreement = LevelAgreement(results: [levelled(0, 70), levelled(1, 76)])
        XCTAssertFalse(agreement.passes)
        XCTAssertFalse(agreement.isRetryable)
        XCTAssertTrue(agreement.residualOffsets.isEmpty)
        XCTAssertTrue(agreement.summary.contains("nothing moved"), agreement.summary)
    }

    func testTheOutlierIsNamedRatherThanEveryOtherChannel() {
        // Measured against the median, so one stray channel does not shift the
        // reference and implicate the three that are correct.
        let agreement = LevelAgreement(results: [levelled(0, 70), levelled(1, 70),
                                                levelled(2, 70), levelled(3, 68)])
        let large = agreement.deviations.filter { abs($0.deviationDb) > 0.5 }
        XCTAssertEqual(large.map(\.speakerIndex), [3])
    }

    func testASubwooferIsExcludedFromTheComparison() {
        // It sits on its own datum, so comparing its level with the mains would
        // report a difference that is not an error.
        let agreement = LevelAgreement(results: [levelled(0, 70), levelled(1, 70),
                                                levelled(8, 55, role: .subwoofer)])
        XCTAssertTrue(agreement.passes)
        XCTAssertEqual(agreement.excluded, [8])
        XCTAssertFalse(agreement.deviations.contains { $0.speakerIndex == 8 })
    }

    func testABypassedCrossoverChannelIsExcluded() {
        // It was measured without its crossover and is now heard with it, so it
        // cannot be compared against a channel that never had one bypassed.
        let agreement = LevelAgreement(results: [levelled(0, 70), levelled(1, 70),
                                                levelled(2, 62,
                                                         crossoverBypassed: true)])
        XCTAssertTrue(agreement.passes)
        XCTAssertEqual(agreement.excluded, [2])
    }

    func testASingleComparableChannelReportsNoDisagreement() {
        // Nothing to compare against is not a failure.
        let agreement = LevelAgreement(results: [levelled(0, 70),
                                                levelled(8, 50, role: .subwoofer)])
        XCTAssertTrue(agreement.passes)
        XCTAssertEqual(agreement.worstDeviationDb, 0, accuracy: 1e-9)
        XCTAssertTrue(agreement.summary.contains("no level agreement"), agreement.summary)
    }

    func testNoResultsAtAllIsHarmless() {
        let agreement = LevelAgreement(results: [])
        XCTAssertTrue(agreement.passes)
        XCTAssertTrue(agreement.deviations.isEmpty)
    }

    func testTheToleranceBoundaryIsInclusive() {
        XCTAssertTrue(LevelAgreement(results: [levelled(0, 70), levelled(1, 70.5)])
                        .passes)
        XCTAssertFalse(LevelAgreement(results: [levelled(0, 70), levelled(1, 70.6)])
                        .passes)
    }
}
